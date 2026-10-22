//! The Wayland side of BasicShell's platform: the connection, read on GLib's
//! main loop; the window and a surface for each view in it; the frames WebKit
//! renders, put on those surfaces; and the pointer and keyboard, turned into
//! WebKit's events for the view under the pointer or with the focus.
//!
//! Wayland's events are handled with the state borrowed, and what WebKit is to
//! be told is kept (`Tell`) until the borrow is over: WebKit can call back into
//! the platform from what it is told.

use std::cell::RefCell;
use std::os::fd::AsRawFd;
use std::rc::Rc;

use glib::prelude::*;
use glib::translate::*;
use smithay_client_toolkit::reexports::csd_frame::WindowState;
use smithay_client_toolkit::{
    compositor::{CompositorHandler, CompositorState, FrameCallbackData},
    delegate_registry,
    output::{OutputHandler, OutputState},
    registry::{ProvidesRegistryState, RegistryState},
    registry_handlers,
    seat::{
        keyboard::{KeyEvent, KeyboardHandler, Keysym, Modifiers, RawModifiers},
        pointer::{PointerEvent, PointerEventKind, PointerHandler},
        Capability, SeatHandler, SeatState,
    },
    shell::{
        xdg::{
            window::{Window, WindowConfigure, WindowDecorations, WindowHandler},
            XdgShell,
        },
        WaylandSurface,
    },
    shm::{slot::SlotPool, Shm, ShmHandler},
    subcompositor::SubcompositorState,
};
use wayland_client::{
    globals::registry_queue_init,
    protocol::{wl_keyboard, wl_output, wl_pointer, wl_seat, wl_shm, wl_subsurface, wl_surface},
    Connection, EventQueue, QueueHandle,
};
use wpe_platform::prelude::*;
use wpe_platform::{EventType, InputSource, Modifiers as WpeModifiers};

use super::toplevel::Toplevel;

const APP_ID: &str = "org.basicshell.BasicShell";

/// One view's place in the window.
struct Slot {
    view: glib::WeakRef<wpe_platform::View>,
    surface: wl_surface::WlSurface,
    /// None for the first view, which is the window's own surface.
    subsurface: Option<wl_subsurface::WlSubsurface>,
    /// The frame attached and waiting for the compositor's frame callback.
    shown: Option<wpe_platform::Buffer>,
    /// What it was copied into; kept until the next, so the pool doesn't reuse it.
    attached: Option<smithay_client_toolkit::shm::slot::Buffer>,
}

/// What WebKit is told once the state isn't borrowed.
enum Tell {
    Event(wpe_platform::View, wpe_platform::Event),
    ViewResized(wpe_platform::View, i32, i32),
    ToplevelResized(Toplevel, i32, i32),
    ToplevelState(Toplevel, wpe_platform::ToplevelState),
    Map(wpe_platform::View),
    Rendered(wpe_platform::View, wpe_platform::Buffer),
    Released(wpe_platform::View, wpe_platform::Buffer),
    FocusIn(wpe_platform::View),
    FocusOut(wpe_platform::View),
    Close(Toplevel),
}

pub struct Shared {
    conn: Connection,
    queue: RefCell<EventQueue<State>>,
    state: RefCell<State>,
}

pub struct State {
    registry: RegistryState,
    seat: SeatState,
    output: OutputState,
    compositor: CompositorState,
    subcompositor: SubcompositorState,
    xdg: XdgShell,
    shm: Shm,
    pool: SlotPool,
    qh: QueueHandle<State>,

    window: Option<Window>,
    toplevel: glib::WeakRef<Toplevel>,
    size: (i32, i32),
    requested: (i32, i32),
    configured: bool,
    slots: Vec<Slot>,

    keyboard: Option<wl_keyboard::WlKeyboard>,
    pointer: Option<wl_pointer::WlPointer>,
    /// Which slot has the keyboard: the page, until BasicShell says otherwise.
    focused: usize,
    keys: WpeModifiers,
    buttons: WpeModifiers,
    press_count: u32,

    tell: Vec<Tell>,
}

impl Shared {
    pub fn connect() -> Result<Rc<Shared>, String> {
        let conn = Connection::connect_to_env().map_err(|e| format!("no Wayland display: {e}"))?;
        let (globals, mut queue) = registry_queue_init::<State>(&conn).map_err(|e| e.to_string())?;
        let qh = queue.handle();
        let compositor = CompositorState::bind(&globals, &qh).map_err(|e| format!("wl_compositor: {e}"))?;
        let subcompositor = SubcompositorState::bind(compositor.wl_compositor().clone(), &globals, &qh)
            .map_err(|e| format!("wl_subcompositor: {e}"))?;
        let xdg = XdgShell::bind(&globals, &qh).map_err(|e| format!("xdg_wm_base: {e}"))?;
        let shm = Shm::bind(&globals, &qh).map_err(|e| format!("wl_shm: {e}"))?;
        let pool = SlotPool::new(1280 * 800 * 4, &shm).map_err(|e| e.to_string())?;
        let mut state = State {
            registry: RegistryState::new(&globals),
            seat: SeatState::new(&globals, &qh),
            output: OutputState::new(&globals, &qh),
            compositor,
            subcompositor,
            xdg,
            shm,
            pool,
            qh,
            window: None,
            toplevel: glib::WeakRef::new(),
            size: (0, 0),
            requested: (1280, 800),
            configured: false,
            slots: Vec::new(),
            keyboard: None,
            pointer: None,
            focused: 0,
            keys: WpeModifiers::empty(),
            buttons: WpeModifiers::empty(),
            press_count: 0,
            tell: Vec::new(),
        };
        queue.roundtrip(&mut state).map_err(|e| e.to_string())?;

        let shared = Rc::new(Shared { conn, queue: RefCell::new(queue), state: RefCell::new(state) });
        let fd = shared.conn.backend().poll_fd().as_raw_fd();
        let weak = Rc::downgrade(&shared);
        glib_unix::unix_fd_add_local(fd, glib::IOCondition::IN | glib::IOCondition::ERR | glib::IOCondition::HUP, move |_, condition| {
            let Some(shared) = weak.upgrade() else { return glib::ControlFlow::Break };
            if condition.intersects(glib::IOCondition::ERR | glib::IOCondition::HUP) {
                eprintln!("basicshell: the compositor went away");
                std::process::exit(1);
            }
            shared.dispatch();
            glib::ControlFlow::Continue
        });
        Ok(shared)
    }

    /// Reads what the compositor sent, handles it, and tells WebKit.
    fn dispatch(&self) {
        {
            let mut queue = self.queue.borrow_mut();
            if let Some(guard) = queue.prepare_read() {
                let _ = guard.read();
            }
            let mut state = self.state.borrow_mut();
            if let Err(e) = queue.dispatch_pending(&mut state) {
                eprintln!("basicshell: Wayland: {e}");
            }
        }
        self.tell_webkit();
        self.flush();
    }

    fn flush(&self) {
        let _ = self.conn.flush();
    }

    fn tell_webkit(&self) {
        loop {
            let tells = std::mem::take(&mut self.state.borrow_mut().tell);
            if tells.is_empty() {
                return;
            }
            for tell in tells {
                match tell {
                    Tell::Event(view, event) => view.event(&event),
                    Tell::ViewResized(view, w, h) => view.resized(w, h),
                    Tell::ToplevelResized(toplevel, w, h) => toplevel.resized(w, h),
                    Tell::ToplevelState(toplevel, state) => toplevel.state_changed(state),
                    Tell::Map(view) => view.map(),
                    Tell::Rendered(view, buffer) => view.buffer_rendered(&buffer),
                    Tell::Released(view, buffer) => view.buffer_released(&buffer),
                    Tell::FocusIn(view) => view.focus_in(),
                    Tell::FocusOut(view) => view.focus_out(),
                    Tell::Close(toplevel) => toplevel.close_requested(),
                }
            }
        }
    }

    pub fn create_window(&self, toplevel: &Toplevel) {
        {
            let mut st = self.state.borrow_mut();
            let surface = st.compositor.create_surface(&st.qh);
            let window = st.xdg.create_window(surface, WindowDecorations::RequestServer, &st.qh);
            window.set_app_id(APP_ID);
            window.set_title("BasicShell");
            window.set_min_size(Some((360, 240)));
            window.commit();
            st.window = Some(window);
            st.toplevel = toplevel.downgrade();
        }
        self.flush();
    }

    pub fn attach_view(&self, view: &wpe_platform::View, _toplevel: &Toplevel) {
        {
            let mut st = self.state.borrow_mut();
            let st = &mut *st;
            if st.slots.iter().any(|s| s.view.upgrade().as_ref() == Some(view)) {
                return;
            }
            let Some(window) = &st.window else { return };
            let window_surface = window.wl_surface().clone();
            let (surface, subsurface) = if st.slots.is_empty() {
                (window_surface, None)
            } else {
                let (subsurface, surface) = st.subcompositor.create_subsurface(window_surface, &st.qh);
                subsurface.set_desync();
                subsurface.set_position(0, 0);
                (surface, Some(subsurface))
            };
            st.slots.push(Slot { view: view.downgrade(), surface, subsurface, shown: None, attached: None });
            if st.configured {
                st.tell.push(Tell::ViewResized(view.clone(), st.size.0, st.size.1));
                st.tell.push(Tell::Map(view.clone()));
            }
        }
        self.tell_webkit();
        self.flush();
    }

    pub fn detach_view(&self, view: &wpe_platform::View) {
        let Ok(mut st) = self.state.try_borrow_mut() else { return };
        st.slots.retain(|slot| {
            let gone = slot.view.upgrade().map_or(true, |v| &v == view);
            if gone {
                if let Some(subsurface) = &slot.subsurface {
                    subsurface.destroy();
                    slot.surface.destroy();
                }
            }
            !gone
        });
    }

    /// A frame from WebKit: copied into shared memory the compositor reads,
    /// and put on the view's surface.
    pub fn render(&self, view: &wpe_platform::View, buffer: &wpe_platform::Buffer, _damage: &[wpe_platform::ffi::WPERectangle]) -> Result<(), glib::Error> {
        let failed = |message: &str| glib::Error::new(wpe_platform::ViewError::Failed, message);
        let shm = buffer
            .downcast_ref::<wpe_platform::BufferSHM>()
            .ok_or_else(|| failed("only shared-memory buffers for now"))?;
        let (width, height) = (buffer.width(), buffer.height());
        let stride = shm.stride() as usize;
        let data = shm.data().ok_or_else(|| failed("a buffer without its pixels"))?;
        {
            let mut st = self.state.borrow_mut();
            let st = &mut *st;
            let index = st
                .slots
                .iter()
                .position(|s| s.view.upgrade().as_ref() == Some(view))
                .ok_or_else(|| failed("a view not in the window"))?;
            let row = width as usize * 4;
            let (wl_buffer, canvas) = st
                .pool
                .create_buffer(width, height, row as i32, wl_shm::Format::Argb8888)
                .map_err(|e| failed(&e.to_string()))?;
            for (y, out) in canvas.chunks_exact_mut(row).enumerate().take(height as usize) {
                let start = y * stride;
                out.copy_from_slice(&data[start..start + row]);
            }
            let qh = st.qh.clone();
            let slot = &mut st.slots[index];
            wl_buffer.attach_to(&slot.surface).map_err(|e| failed(&e.to_string()))?;
            slot.surface.damage_buffer(0, 0, width, height);
            slot.surface.frame(&qh, FrameCallbackData(slot.surface.clone()));
            slot.surface.commit();
            slot.attached = Some(wl_buffer);
            if let Some(previous) = slot.shown.replace(buffer.clone()) {
                // Replaced before the compositor showed it: done with it all the same.
                st.tell.push(Tell::Rendered(view.clone(), previous.clone()));
                st.tell.push(Tell::Released(view.clone(), previous));
            }
        }
        self.tell_webkit();
        self.flush();
        Ok(())
    }

    pub fn set_cursor(&self, _name: &str) {
        // The compositor's default cursor, until a cursor theme is loaded.
    }

    pub fn set_title(&self, title: &str) {
        if let Some(window) = &self.state.borrow().window {
            window.set_title(title);
        }
        self.flush();
    }

    pub fn request_size(&self, width: i32, height: i32) {
        self.state.borrow_mut().requested = (width, height);
    }

    pub fn set_fullscreen(&self, fullscreen: bool) {
        if let Some(window) = &self.state.borrow().window {
            if fullscreen { window.set_fullscreen(None) } else { window.unset_fullscreen() }
        }
        self.flush();
    }

    pub fn set_maximized(&self, maximized: bool) {
        if let Some(window) = &self.state.borrow().window {
            if maximized { window.set_maximized() } else { window.unset_maximized() }
        }
        self.flush();
    }

    pub fn set_minimized(&self) {
        if let Some(window) = &self.state.borrow().window {
            window.set_minimized();
        }
        self.flush();
    }
}

impl State {
    fn slot_view(&self, surface: &wl_surface::WlSurface) -> Option<wpe_platform::View> {
        self.slots.iter().find(|s| &s.surface == surface).and_then(|s| s.view.upgrade())
    }

    fn focused_view(&self) -> Option<wpe_platform::View> {
        self.slots.get(self.focused).and_then(|s| s.view.upgrade())
    }

    fn modifiers(&self) -> WpeModifiers {
        self.keys | self.buttons
    }
}

fn wpe_button(button: u32) -> (u32, WpeModifiers) {
    // Linux's input codes: BTN_LEFT, BTN_RIGHT, BTN_MIDDLE.
    match button {
        0x110 => (wpe_platform::ffi::WPE_BUTTON_PRIMARY as u32, WpeModifiers::POINTER_BUTTON1),
        0x111 => (wpe_platform::ffi::WPE_BUTTON_SECONDARY as u32, WpeModifiers::POINTER_BUTTON3),
        0x112 => (wpe_platform::ffi::WPE_BUTTON_MIDDLE as u32, WpeModifiers::POINTER_BUTTON2),
        other => (other.saturating_sub(0x110) + 1, WpeModifiers::empty()),
    }
}

/// An event WebKit made; None where it refused the arguments (and said why
/// on standard error).
unsafe fn wpe_event(ptr: *mut wpe_platform::ffi::WPEEvent) -> Option<wpe_platform::Event> {
    if ptr.is_null() { None } else { Some(unsafe { from_glib_full(ptr) }) }
}

impl CompositorHandler for State {
    fn scale_factor_changed(&mut self, _: &Connection, _: &QueueHandle<Self>, _: &wl_surface::WlSurface, _: i32) {}
    fn transform_changed(&mut self, _: &Connection, _: &QueueHandle<Self>, _: &wl_surface::WlSurface, _: wl_output::Transform) {}

    fn frame(&mut self, _: &Connection, _: &QueueHandle<Self>, surface: &wl_surface::WlSurface, _time: u32) {
        if let Some(slot) = self.slots.iter_mut().find(|s| &s.surface == surface) {
            if let (Some(view), Some(buffer)) = (slot.view.upgrade(), slot.shown.take()) {
                self.tell.push(Tell::Rendered(view.clone(), buffer.clone()));
                self.tell.push(Tell::Released(view, buffer));
            }
        }
    }

    fn surface_enter(&mut self, _: &Connection, _: &QueueHandle<Self>, _: &wl_surface::WlSurface, _: &wl_output::WlOutput) {}
    fn surface_leave(&mut self, _: &Connection, _: &QueueHandle<Self>, _: &wl_surface::WlSurface, _: &wl_output::WlOutput) {}
}

impl WindowHandler for State {
    fn request_close(&mut self, _: &Connection, _: &QueueHandle<Self>, _: &Window) {
        if let Some(toplevel) = self.toplevel.upgrade() {
            self.tell.push(Tell::Close(toplevel));
        }
    }

    fn configure(&mut self, _: &Connection, _: &QueueHandle<Self>, _: &Window, configure: WindowConfigure, _serial: u32) {
        let width = configure.new_size.0.map_or(self.requested.0, |v| v.get() as i32);
        let height = configure.new_size.1.map_or(self.requested.1, |v| v.get() as i32);
        let Some(toplevel) = self.toplevel.upgrade() else { return };
        if (width, height) != self.size {
            self.size = (width, height);
            self.tell.push(Tell::ToplevelResized(toplevel.clone(), width, height));
            for view in self.slots.iter().filter_map(|s| s.view.upgrade()) {
                self.tell.push(Tell::ViewResized(view, width, height));
            }
        }
        let mut state = wpe_platform::ToplevelState::empty();
        if configure.state.contains(WindowState::MAXIMIZED) {
            state |= wpe_platform::ToplevelState::MAXIMIZED;
        }
        if configure.state.contains(WindowState::FULLSCREEN) {
            state |= wpe_platform::ToplevelState::FULLSCREEN;
        }
        if configure.state.contains(WindowState::ACTIVATED) {
            state |= wpe_platform::ToplevelState::ACTIVE;
        }
        self.tell.push(Tell::ToplevelState(toplevel, state));
        if !self.configured {
            self.configured = true;
            for view in self.slots.iter().filter_map(|s| s.view.upgrade()) {
                self.tell.push(Tell::Map(view));
            }
        }
    }
}

impl SeatHandler for State {
    fn seat_state(&mut self) -> &mut SeatState {
        &mut self.seat
    }

    fn new_seat(&mut self, _: &Connection, _: &QueueHandle<Self>, _: wl_seat::WlSeat) {}

    fn new_capability(&mut self, _: &Connection, qh: &QueueHandle<Self>, seat: wl_seat::WlSeat, capability: Capability) {
        if capability == Capability::Keyboard && self.keyboard.is_none() {
            self.keyboard = self.seat.get_keyboard(qh, &seat, None).ok();
        }
        if capability == Capability::Pointer && self.pointer.is_none() {
            self.pointer = self.seat.get_pointer(qh, &seat).ok();
        }
    }

    fn remove_capability(&mut self, _: &Connection, _: &QueueHandle<Self>, _: wl_seat::WlSeat, capability: Capability) {
        if capability == Capability::Keyboard {
            if let Some(keyboard) = self.keyboard.take() {
                keyboard.release();
            }
        }
        if capability == Capability::Pointer {
            if let Some(pointer) = self.pointer.take() {
                pointer.release();
            }
        }
    }

    fn remove_seat(&mut self, _: &Connection, _: &QueueHandle<Self>, _: wl_seat::WlSeat) {}
}

impl State {
    fn key(&mut self, kind: EventType, event: &KeyEvent) {
        let Some(view) = self.focused_view() else { return };
        let ptr = unsafe {
            wpe_platform::ffi::wpe_event_keyboard_new(
                kind.into_glib(),
                view.to_glib_none().0,
                InputSource::Keyboard.into_glib(),
                event.time,
                self.modifiers().into_glib(),
                event.raw_code + 8,
                event.keysym.raw(),
            )
        };
        if let Some(event) = unsafe { wpe_event(ptr) } {
            self.tell.push(Tell::Event(view, event));
        }
    }
}

impl KeyboardHandler for State {
    fn enter(&mut self, _: &Connection, _: &QueueHandle<Self>, _: &wl_keyboard::WlKeyboard, _: &wl_surface::WlSurface, _: u32, _: &[u32], _: &[Keysym]) {
        if let Some(view) = self.focused_view() {
            self.tell.push(Tell::FocusIn(view));
        }
    }

    fn leave(&mut self, _: &Connection, _: &QueueHandle<Self>, _: &wl_keyboard::WlKeyboard, _: &wl_surface::WlSurface, _: u32) {
        if let Some(view) = self.focused_view() {
            self.tell.push(Tell::FocusOut(view));
        }
    }

    fn press_key(&mut self, _: &Connection, _: &QueueHandle<Self>, _: &wl_keyboard::WlKeyboard, _: u32, event: KeyEvent) {
        self.key(EventType::KeyboardKeyDown, &event);
    }

    fn repeat_key(&mut self, _: &Connection, _: &QueueHandle<Self>, _: &wl_keyboard::WlKeyboard, _: u32, event: KeyEvent) {
        self.key(EventType::KeyboardKeyDown, &event);
    }

    fn release_key(&mut self, _: &Connection, _: &QueueHandle<Self>, _: &wl_keyboard::WlKeyboard, _: u32, event: KeyEvent) {
        self.key(EventType::KeyboardKeyUp, &event);
    }

    fn update_modifiers(&mut self, _: &Connection, _: &QueueHandle<Self>, _: &wl_keyboard::WlKeyboard, _: u32, modifiers: Modifiers, _: RawModifiers, _: u32) {
        let mut keys = WpeModifiers::empty();
        if modifiers.ctrl {
            keys |= WpeModifiers::KEYBOARD_CONTROL;
        }
        if modifiers.shift {
            keys |= WpeModifiers::KEYBOARD_SHIFT;
        }
        if modifiers.alt {
            keys |= WpeModifiers::KEYBOARD_ALT;
        }
        if modifiers.logo {
            keys |= WpeModifiers::KEYBOARD_META;
        }
        if modifiers.caps_lock {
            keys |= WpeModifiers::KEYBOARD_CAPS_LOCK;
        }
        self.keys = keys;
    }
}

impl PointerHandler for State {
    fn pointer_frame(&mut self, _: &Connection, _: &QueueHandle<Self>, _: &wl_pointer::WlPointer, events: &[PointerEvent]) {
        for e in events {
            let Some(view) = self.slot_view(&e.surface) else { continue };
            let (x, y) = e.position;
            let modifiers = self.modifiers();
            let view_ptr = view.to_glib_none().0;
            let ptr = match e.kind {
                PointerEventKind::Enter { .. } | PointerEventKind::Leave { .. } | PointerEventKind::Motion { .. } => {
                    let (kind, time) = match e.kind {
                        PointerEventKind::Enter { .. } => (EventType::PointerEnter, 0),
                        PointerEventKind::Leave { .. } => (EventType::PointerLeave, 0),
                        PointerEventKind::Motion { time } => (EventType::PointerMove, time),
                        _ => unreachable!(),
                    };
                    unsafe {
                        wpe_platform::ffi::wpe_event_pointer_move_new(kind.into_glib(), view_ptr, InputSource::Mouse.into_glib(), time, modifiers.into_glib(), x, y, 0.0, 0.0)
                    }
                }
                PointerEventKind::Press { time, button, .. } => {
                    let (button, mask) = wpe_button(button);
                    self.press_count = unsafe { wpe_platform::ffi::wpe_view_compute_press_count(view_ptr, x, y, button, time) };
                    self.buttons |= mask;
                    unsafe {
                        wpe_platform::ffi::wpe_event_pointer_button_new(EventType::PointerDown.into_glib(), view_ptr, InputSource::Mouse.into_glib(), time, modifiers.into_glib(), button, x, y, self.press_count)
                    }
                }
                PointerEventKind::Release { time, button, .. } => {
                    let (button, mask) = wpe_button(button);
                    self.buttons.remove(mask);
                    unsafe {
                        // A release carries no press count: WebKit asks for 0.
                        wpe_platform::ffi::wpe_event_pointer_button_new(EventType::PointerUp.into_glib(), view_ptr, InputSource::Mouse.into_glib(), time, self.modifiers().into_glib(), button, x, y, 0)
                    }
                }
                PointerEventKind::Axis { time, horizontal, vertical, source } => {
                    let input = match source {
                        Some(wl_pointer::AxisSource::Finger) => InputSource::Touchpad,
                        Some(wl_pointer::AxisSource::Continuous) => InputSource::Trackpoint,
                        _ => InputSource::Mouse,
                    };
                    // Wheel clicks as steps; a touchpad's movement as pixels.
                    let (dx, dy, precise) = if horizontal.discrete != 0 || vertical.discrete != 0 {
                        (-(horizontal.discrete as f64), -(vertical.discrete as f64), false)
                    } else {
                        (-horizontal.absolute, -vertical.absolute, true)
                    };
                    let stop = horizontal.stop && vertical.stop;
                    unsafe {
                        wpe_platform::ffi::wpe_event_scroll_new(view_ptr, input.into_glib(), time, modifiers.into_glib(), dx, dy, precise.into_glib(), stop.into_glib(), x, y)
                    }
                }
            };
            if let Some(event) = unsafe { wpe_event(ptr) } {
            self.tell.push(Tell::Event(view, event));
        }
        }
    }
}

impl OutputHandler for State {
    fn output_state(&mut self) -> &mut OutputState {
        &mut self.output
    }
    fn new_output(&mut self, _: &Connection, _: &QueueHandle<Self>, _: wl_output::WlOutput) {}
    fn update_output(&mut self, _: &Connection, _: &QueueHandle<Self>, _: wl_output::WlOutput) {}
    fn output_destroyed(&mut self, _: &Connection, _: &QueueHandle<Self>, _: wl_output::WlOutput) {}
}

impl ShmHandler for State {
    fn shm_state(&mut self) -> &mut Shm {
        &mut self.shm
    }
}

delegate_registry!(State);

impl ProvidesRegistryState for State {
    fn registry(&mut self) -> &mut RegistryState {
        &mut self.registry
    }
    registry_handlers![OutputState, SeatState];
}

smithay_client_toolkit::delegate_dispatch2!(State);
