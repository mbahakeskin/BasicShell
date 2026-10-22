//! The Wayland side of BasicShell's platform: the connection, read on GLib's
//! main loop; the window, and a subsurface in it for each view, placed,
//! stacked and shown as BasicShell says; the frames WebKit renders, put on
//! those surfaces; and the pointer and keyboard, turned into WebKit's events
//! for the view under the pointer or with the focus.
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
use smithay_client_toolkit::reexports::protocols::xdg::shell::client::xdg_toplevel::ResizeEdge;
use smithay_client_toolkit::{
    compositor::{CompositorHandler, CompositorState, FrameCallbackData, Region},
    data_device_manager::{
        data_device::{DataDevice, DataDeviceHandler},
        data_offer::{DataOfferHandler, DragOffer},
        data_source::{CopyPasteSource, DataSourceHandler},
        DataDeviceManagerState, WritePipe,
    },
    delegate_registry,
    output::{OutputHandler, OutputState},
    registry::{ProvidesRegistryState, RegistryState},
    registry_handlers,
    seat::{
        keyboard::{KeyEvent, KeyboardHandler, Keysym, Modifiers, RawModifiers, RepeatInfo},
        pointer::{CursorIcon, PointerEvent, PointerEventKind, PointerHandler, ThemeSpec, ThemedPointer},
        Capability, SeatHandler, SeatState,
    },
    shell::{
        xdg::{
            window::{DecorationMode, Window, WindowConfigure, WindowDecorations, WindowHandler},
            XdgShell,
        },
        WaylandSurface,
    },
    shm::{slot::SlotPool, Shm, ShmHandler},
    subcompositor::SubcompositorState,
};
use wayland_client::{
    globals::registry_queue_init,
    protocol::{wl_data_device, wl_data_device_manager::DndAction, wl_data_source, wl_keyboard, wl_output, wl_pointer, wl_seat, wl_shm, wl_subsurface, wl_surface},
    Connection, EventQueue, QueueHandle,
};
use wpe_platform::prelude::*;
use wpe_platform::{EventType, InputSource, Modifiers as WpeModifiers};

use super::clipboard::Clipboard;
use super::toplevel::Toplevel;

const APP_ID: &str = "org.basicshell.BasicShell";

/// The window's own colour, behind and around the views: macOS's window
/// background, in its light appearance (bytes of ARGB8888, little-endian).
const BACKGROUND: [u8; 4] = [0xec, 0xec, 0xec, 0xff];

/// How near the window's edge a press resizes it, where the compositor
/// draws no frame for it (GNOME's doesn't).
const RESIZE_BORDER: f64 = 5.0;

/// A rectangle in the window: x, y, width, height.
pub type Rect = (i32, i32, i32, i32);

/// One view's place in the window: a subsurface of the window's surface.
struct Slot {
    view: glib::WeakRef<wpe_platform::View>,
    surface: wl_surface::WlSurface,
    subsurface: wl_subsurface::WlSubsurface,
    /// Where it is; None: the whole window.
    place: Option<Rect>,
    visible: bool,
    /// The size WebKit was last told.
    told: (i32, i32),
    /// The frame attached and waiting for the compositor's frame callback.
    shown: Option<wpe_platform::Buffer>,
    /// The pointer's shape over it, as WebKit last said.
    cursor: CursorIcon,
    /// What it was copied into; kept until the next, so the pool doesn't
    /// reuse it, and put back when a hidden view is shown again, until WebKit
    /// draws it anew.
    attached: Option<smithay_client_toolkit::shm::slot::Buffer>,
}

impl Slot {
    fn rect(&self, window: (i32, i32)) -> Rect {
        self.place.unwrap_or((0, 0, window.0, window.1))
    }
}

/// What WebKit is told once the state isn't borrowed.
enum Tell {
    Event(wpe_platform::View, wpe_platform::Event),
    ViewResized(wpe_platform::View, i32, i32),
    ToplevelResized(Toplevel, i32, i32),
    ToplevelState(Toplevel, wpe_platform::ToplevelState),
    Map(wpe_platform::View),
    Unmap(wpe_platform::View),
    Rendered(wpe_platform::View, wpe_platform::Buffer),
    Released(wpe_platform::View, wpe_platform::Buffer),
    FocusIn(wpe_platform::View),
    FocusOut(wpe_platform::View),
    Close(Toplevel),
    /// For BasicShell: the pointer over a view, in the window's coordinates,
    /// or gone from it.
    Pointer(wpe_platform::View, Option<(f64, f64)>),
    /// For BasicShell: the window's new size.
    WindowResized(i32, i32),
    /// A key held down repeats (its code and symbol), or none does.
    Repeat(Option<(u32, u32)>),
    /// Another program's clipboard content, in these formats (none: empty).
    Selection(Option<Vec<String>>),
    /// Another program pastes what WebKit copied, in this format, through this pipe.
    Send(String, WritePipe),
    /// A key, first for BasicShell's shortcuts, then for the view if not taken.
    Key { view: wpe_platform::View, event: wpe_platform::Event, keysym: u32, modifiers: WpeModifiers, pressed: bool },
}

type PointerHook = Box<dyn Fn(&wpe_platform::View, Option<(f64, f64)>)>;
type KeyHook = Box<dyn Fn(u32, WpeModifiers, bool) -> bool>;
type ResizedHook = Box<dyn Fn(i32, i32)>;

/// What BasicShell itself wants to hear about.
#[derive(Default)]
struct Hooks {
    pointer: Option<PointerHook>,
    key: Option<KeyHook>,
    resized: Option<ResizedHook>,
}

pub struct Shared {
    me: std::rc::Weak<Shared>,
    conn: Connection,
    /// The key held down repeating: its timer.
    repeating: RefCell<Option<glib::SourceId>>,
    clipboard: RefCell<glib::WeakRef<Clipboard>>,
    queue: RefCell<EventQueue<State>>,
    state: RefCell<State>,
    hooks: RefCell<Hooks>,
}

pub struct State {
    registry: RegistryState,
    seat_state: SeatState,
    output: OutputState,
    compositor: CompositorState,
    subcompositor: SubcompositorState,
    xdg: XdgShell,
    shm: Shm,
    pool: SlotPool,
    /// The clipboard's protocol, where the compositor has it.
    data_manager: Option<DataDeviceManagerState>,
    data_device: Option<DataDevice>,
    /// What WebKit copied, offered to other programs.
    source: Option<CopyPasteSource>,
    /// The last press of a key or button, which taking the clipboard needs.
    input_serial: u32,
    qh: QueueHandle<State>,

    window: Option<Window>,
    toplevel: glib::WeakRef<Toplevel>,
    size: (i32, i32),
    requested: (i32, i32),
    configured: bool,
    /// The window's own surface's buffer, its colour.
    background: Option<smithay_client_toolkit::shm::slot::Buffer>,
    /// No frame from the compositor: BasicShell's to move and resize.
    client_side: bool,
    /// Maximized, full screen or tiled: no resizing from the edges.
    fixed: bool,
    maximized: bool,
    fullscreen: bool,
    /// In stacking order, the bottom one first.
    slots: Vec<Slot>,

    seat: Option<wl_seat::WlSeat>,
    keyboard: Option<wl_keyboard::WlKeyboard>,
    pointer: Option<ThemedPointer>,
    /// The pointer's shape now.
    cursor: Option<CursorIcon>,
    /// The view with the keyboard.
    focused: Option<wpe_platform::View>,
    keys: WpeModifiers,
    buttons: WpeModifiers,
    press_count: u32,
    /// The last press's serial, for moving the window from it.
    press_serial: u32,
    /// A press went to resizing the window: its release goes nowhere.
    grabbed: bool,
    /// Held keys repeat at this rate (per second) after this delay (ms).
    repeat: Option<(u32, u32)>,
    /// The key repeating, by its code.
    repeating: Option<u32>,
    /// The view under the pointer, and where in it.
    under: Option<(wpe_platform::View, (f64, f64))>,
    /// The pointer is where a press resizes the window.
    on_resize_edge: bool,

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
        let data_manager = DataDeviceManagerState::bind(&globals, &qh).ok();
        let mut state = State {
            registry: RegistryState::new(&globals),
            seat_state: SeatState::new(&globals, &qh),
            output: OutputState::new(&globals, &qh),
            compositor,
            subcompositor,
            xdg,
            shm,
            pool,
            data_manager,
            data_device: None,
            source: None,
            input_serial: 0,
            qh,
            window: None,
            toplevel: glib::WeakRef::new(),
            size: (0, 0),
            requested: (1280, 800),
            configured: false,
            background: None,
            client_side: true,
            fixed: false,
            maximized: false,
            fullscreen: false,
            slots: Vec::new(),
            seat: None,
            keyboard: None,
            pointer: None,
            cursor: None,
            focused: None,
            keys: WpeModifiers::empty(),
            buttons: WpeModifiers::empty(),
            press_count: 0,
            press_serial: 0,
            grabbed: false,
            repeat: Some((25, 600)),
            repeating: None,
            under: None,
            on_resize_edge: false,
            tell: Vec::new(),
        };
        queue.roundtrip(&mut state).map_err(|e| e.to_string())?;

        let shared = Rc::new_cyclic(|me| Shared {
            me: me.clone(),
            conn,
            repeating: RefCell::default(),
            clipboard: RefCell::default(),
            queue: RefCell::new(queue),
            state: RefCell::new(state),
            hooks: RefCell::default(),
        });
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
                    Tell::Unmap(view) => view.unmap(),
                    Tell::Rendered(view, buffer) => view.buffer_rendered(&buffer),
                    Tell::Released(view, buffer) => view.buffer_released(&buffer),
                    Tell::FocusIn(view) => view.focus_in(),
                    Tell::FocusOut(view) => view.focus_out(),
                    Tell::Close(toplevel) => toplevel.close_requested(),
                    Tell::Pointer(view, at) => {
                        if let Some(hook) = &self.hooks.borrow().pointer {
                            hook(&view, at);
                        }
                    }
                    Tell::WindowResized(w, h) => {
                        if let Some(hook) = &self.hooks.borrow().resized {
                            hook(w, h);
                        }
                    }
                    Tell::Repeat(key) => self.repeat(key),
                    Tell::Selection(formats) => {
                        if let Some(clipboard) = self.clipboard.borrow().upgrade() {
                            clipboard.remote_changed(formats);
                        }
                    }
                    Tell::Send(format, pipe) => {
                        let data = self.clipboard.borrow().upgrade().and_then(|c| c.serialize(&format));
                        // Written beside the main loop: the reader takes it at its own pace.
                        std::thread::spawn(move || {
                            let mut pipe = pipe;
                            if let Some(data) = data {
                                let _ = std::io::Write::write_all(&mut pipe, &data);
                            }
                        });
                    }
                    Tell::Key { view, event, keysym, modifiers, pressed } => {
                        let taken = self.hooks.borrow().key.as_ref().is_some_and(|hook| hook(keysym, modifiers, pressed));
                        if !taken {
                            view.event(&event);
                        }
                    }
                }
            }
        }
    }

    /// The clipboard WebKit asked for (on its first copy or paste): told
    /// what is on the system's clipboard already.
    pub fn set_clipboard(&self, clipboard: &Clipboard) {
        *self.clipboard.borrow_mut() = clipboard.downgrade();
        let formats = self.state.borrow().remote_formats();
        if formats.is_some() {
            clipboard.remote_changed(formats);
        }
    }

    /// What another program put on the clipboard, in `format`: asked for, and
    /// read as it sends it (WebKit waits for it, as its own platform does).
    pub fn read_selection(&self, format: &str) -> Option<Vec<u8>> {
        let mut pipe = {
            let st = self.state.borrow();
            let offer = st.data_device.as_ref()?.data().selection_offer()?;
            offer.receive(format.to_owned()).ok()?
        };
        self.flush();
        let mut data = Vec::new();
        std::io::Read::read_to_end(&mut pipe, &mut data).ok()?;
        Some(data)
    }

    /// WebKit copied something, in these formats: the clipboard is ours.
    pub fn offer_selection(&self, formats: Vec<String>) {
        self.with_state(|st| {
            let (Some(manager), Some(device)) = (&st.data_manager, &st.data_device) else { return };
            let source = manager.create_copy_paste_source(&st.qh, formats.iter());
            source.set_selection(device, st.input_serial);
            st.source = Some(source);
        });
    }

    /// The key held down sent again and again, after the compositor's delay
    /// at its rate (Wayland leaves repeating keys to the client).
    fn repeat(&self, key: Option<(u32, u32)>) {
        if let Some(source) = self.repeating.take() {
            source.remove();
        }
        let Some((code, keysym)) = key else { return };
        let Some((rate, delay)) = self.state.borrow().repeat else { return };
        let me = self.me.clone();
        let source = glib::timeout_add_local_once(std::time::Duration::from_millis(delay as u64), move || {
            let Some(shared) = me.upgrade() else { return };
            let me = shared.me.clone();
            let interval = std::time::Duration::from_micros(1_000_000 / rate.max(1) as u64);
            let source = glib::timeout_add_local(interval, move || {
                let Some(shared) = me.upgrade() else { return glib::ControlFlow::Break };
                shared.with_state(|st| st.key_event(EventType::KeyboardKeyDown, code, keysym, now_ms()));
                glib::ControlFlow::Continue
            });
            *shared.repeating.borrow_mut() = Some(source);
            shared.with_state(|st| st.key_event(EventType::KeyboardKeyDown, code, keysym, now_ms()));
        });
        *self.repeating.borrow_mut() = Some(source);
    }

    /// Runs `f` on the state, then tells WebKit what it gave rise to and
    /// sends what it asked of the compositor.
    fn with_state(&self, f: impl FnOnce(&mut State)) {
        {
            let mut st = self.state.borrow_mut();
            f(&mut st);
        }
        self.tell_webkit();
        self.flush();
    }

    pub fn create_window(&self, toplevel: &Toplevel) {
        self.with_state(|st| {
            let surface = st.compositor.create_surface(&st.qh);
            // The compositor's frame where it has one; GNOME's has none, and
            // BASICSHELL_CLIENT_DECORATIONS=1 asks for none anywhere (BasicShell
            // then moves and resizes the window itself, as there).
            let decorations = if std::env::var_os("BASICSHELL_CLIENT_DECORATIONS").is_some_and(|v| v == "1") {
                WindowDecorations::RequestClient
            } else {
                WindowDecorations::RequestServer
            };
            let window = st.xdg.create_window(surface, decorations, &st.qh);
            window.set_app_id(APP_ID);
            window.set_title("BasicShell");
            window.set_min_size(Some((480, 320)));
            window.commit();
            st.window = Some(window);
            st.toplevel = toplevel.downgrade();
        });
    }

    pub fn attach_view(&self, view: &wpe_platform::View, _toplevel: &Toplevel) {
        self.with_state(|st| {
            if st.index(view).is_some() {
                return;
            }
            let Some(window) = &st.window else { return };
            let (subsurface, surface) = st.subcompositor.create_subsurface(window.wl_surface().clone(), &st.qh);
            subsurface.set_desync();
            // A new subsurface goes on top of the others.
            st.slots.push(Slot {
                view: view.downgrade(),
                surface,
                subsurface,
                place: None,
                visible: true,
                told: (0, 0),
                cursor: CursorIcon::Default,
                shown: None,
                attached: None,
            });
            if st.focused.is_none() {
                st.focused = Some(view.clone());
            }
            let index = st.slots.len() - 1;
            st.relayout(index);
            if st.configured {
                st.tell.push(Tell::Map(view.clone()));
            }
            st.commit_window();
        });
    }

    pub fn detach_view(&self, view: &wpe_platform::View) {
        let Ok(mut st) = self.state.try_borrow_mut() else { return };
        st.slots.retain(|slot| {
            let gone = slot.view.upgrade().is_none_or(|v| &v == view);
            if gone {
                slot.subsurface.destroy();
                slot.surface.destroy();
            }
            !gone
        });
        if st.focused.as_ref() == Some(view) {
            st.focused = None;
        }
        drop(st);
        self.flush();
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
            let index = st.index(view).ok_or_else(|| failed("a view not in the window"))?;
            if !st.slots[index].visible {
                // Not on show: done with at once.
                st.tell.push(Tell::Rendered(view.clone(), buffer.clone()));
                st.tell.push(Tell::Released(view.clone(), buffer.clone()));
            } else {
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
        }
        self.tell_webkit();
        self.flush();
        Ok(())
    }

    /// Where a view takes the pointer (rectangles in its own coordinates):
    /// elsewhere it goes to what is under it.
    pub fn set_input_region(&self, view: &wpe_platform::View, rects: &[Rect]) {
        self.with_state(|st| {
            let Some(index) = st.index(view) else { return };
            let Ok(region) = Region::new(&st.compositor) else { return };
            for &(x, y, w, h) in rects {
                region.add(x, y, w, h);
            }
            let slot = &st.slots[index];
            slot.surface.set_input_region(Some(region.wl_region()));
            slot.surface.commit();
        });
    }

    /// Puts a view at `place` in the window (None: all of it).
    pub fn place(&self, view: &wpe_platform::View, place: Option<Rect>) {
        self.with_state(|st| {
            let Some(index) = st.index(view) else { return };
            st.slots[index].place = place;
            st.relayout(index);
            st.commit_window();
        });
    }

    /// Shows or hides a view; WebKit is told, and stops drawing a hidden one.
    pub fn set_visible(&self, view: &wpe_platform::View, visible: bool) {
        self.with_state(|st| {
            let Some(index) = st.index(view) else { return };
            let configured = st.configured;
            let slot = &mut st.slots[index];
            if slot.visible == visible {
                return;
            }
            slot.visible = visible;
            if visible {
                if let Some(buffer) = &slot.attached {
                    if buffer.attach_to(&slot.surface).is_ok() {
                        slot.surface.damage_buffer(0, 0, i32::MAX, i32::MAX);
                        slot.surface.commit();
                    }
                }
            } else {
                slot.surface.attach(None, 0, 0);
                slot.surface.commit();
                if let Some(previous) = slot.shown.take() {
                    st.tell.push(Tell::Rendered(view.clone(), previous.clone()));
                    st.tell.push(Tell::Released(view.clone(), previous));
                }
            }
            if configured {
                st.tell.push(if visible { Tell::Map(view.clone()) } else { Tell::Unmap(view.clone()) });
            }
        });
    }

    /// Puts a view over every other.
    pub fn raise(&self, view: &wpe_platform::View) {
        self.with_state(|st| {
            let Some(index) = st.index(view) else { return };
            if index + 1 == st.slots.len() {
                return;
            }
            let slot = st.slots.remove(index);
            if let Some(top) = st.slots.last() {
                slot.subsurface.place_above(&top.surface);
            }
            st.slots.push(slot);
            st.commit_window();
        });
    }

    /// Gives a view the keyboard.
    pub fn focus(&self, view: &wpe_platform::View) {
        self.with_state(|st| st.move_focus(view));
    }

    /// The window follows the pointer, from the press just made. The
    /// compositor has the button's release now: the view is told it was let go.
    pub fn start_move(&self) {
        self.with_state(|st| {
            let (Some(window), Some(seat)) = (&st.window, &st.seat) else { return };
            window.move_(seat, st.press_serial);
            if let Some((view, (x, y))) = st.under.clone() {
                if st.buttons.contains(WpeModifiers::POINTER_BUTTON1) {
                    st.buttons.remove(WpeModifiers::POINTER_BUTTON1);
                    let ptr = unsafe {
                        wpe_platform::ffi::wpe_event_pointer_button_new(
                            EventType::PointerUp.into_glib(),
                            view.to_glib_none().0,
                            InputSource::Mouse.into_glib(),
                            0,
                            st.modifiers().into_glib(),
                            wpe_platform::ffi::WPE_BUTTON_PRIMARY as u32,
                            x,
                            y,
                            0,
                        )
                    };
                    if let Some(event) = unsafe { wpe_event(ptr) } {
                        st.tell.push(Tell::Event(view, event));
                    }
                }
            }
        });
    }

    pub fn size(&self) -> (i32, i32) {
        self.state.borrow().size
    }

    pub fn is_maximized(&self) -> bool {
        self.state.borrow().maximized
    }

    pub fn is_fullscreen(&self) -> bool {
        self.state.borrow().fullscreen
    }

    pub fn connect_pointer(&self, f: impl Fn(&wpe_platform::View, Option<(f64, f64)>) + 'static) {
        self.hooks.borrow_mut().pointer = Some(Box::new(f));
    }

    pub fn connect_key(&self, f: impl Fn(u32, WpeModifiers, bool) -> bool + 'static) {
        self.hooks.borrow_mut().key = Some(Box::new(f));
    }

    pub fn connect_resized(&self, f: impl Fn(i32, i32) + 'static) {
        self.hooks.borrow_mut().resized = Some(Box::new(f));
    }

    /// The pointer's shape over `view`, by its CSS name.
    pub fn set_cursor(&self, view: &wpe_platform::View, name: &str) {
        let icon = name.parse::<CursorIcon>().unwrap_or(CursorIcon::Default);
        let mut st = self.state.borrow_mut();
        let Some(index) = st.index(view) else { return };
        st.slots[index].cursor = icon;
        if st.under.as_ref().is_some_and(|(v, _)| v == view) && !st.on_resize_edge {
            st.show_cursor(&self.conn, icon);
        }
        drop(st);
        self.flush();
    }

    pub fn set_title(&self, title: &str) {
        self.with_state(|st| {
            if let Some(window) = &st.window {
                window.set_title(title);
            }
        });
    }

    pub fn request_size(&self, width: i32, height: i32) {
        self.state.borrow_mut().requested = (width, height);
    }

    pub fn set_fullscreen(&self, fullscreen: bool) {
        self.with_state(|st| {
            if let Some(window) = &st.window {
                if fullscreen { window.set_fullscreen(None) } else { window.unset_fullscreen() }
            }
        });
    }

    pub fn set_maximized(&self, maximized: bool) {
        self.with_state(|st| {
            if let Some(window) = &st.window {
                if maximized { window.set_maximized() } else { window.unset_maximized() }
            }
        });
    }

    pub fn set_minimized(&self) {
        self.with_state(|st| {
            if let Some(window) = &st.window {
                window.set_minimized();
            }
        });
    }
}

impl State {
    fn index(&self, view: &wpe_platform::View) -> Option<usize> {
        self.slots.iter().position(|s| s.view.upgrade().as_ref() == Some(view))
    }

    /// Puts a slot where it goes, and tells WebKit its size if that changed.
    fn relayout(&mut self, index: usize) {
        let (x, y, w, h) = self.slots[index].rect(self.size);
        let slot = &mut self.slots[index];
        slot.subsurface.set_position(x, y);
        if w > 0 && h > 0 && slot.told != (w, h) {
            slot.told = (w, h);
            if let Some(view) = slot.view.upgrade() {
                self.tell.push(Tell::ViewResized(view, w, h));
            }
        }
    }

    /// Where subsurfaces are and how they are stacked takes effect with the
    /// window surface's next commit.
    fn commit_window(&self) {
        if let Some(window) = &self.window {
            window.wl_surface().commit();
        }
    }

    /// The window's own surface, in its colour, at its size.
    fn paint_background(&mut self) {
        let (width, height) = self.size;
        let Some(window) = &self.window else { return };
        let Ok((buffer, canvas)) = self.pool.create_buffer(width, height, width * 4, wl_shm::Format::Argb8888) else { return };
        for pixel in canvas.chunks_exact_mut(4) {
            pixel.copy_from_slice(&BACKGROUND);
        }
        let surface = window.wl_surface();
        if buffer.attach_to(surface).is_ok() {
            surface.damage_buffer(0, 0, width, height);
            surface.commit();
            self.background = Some(buffer);
        }
    }

    /// The formats another program's clipboard content is in; none while
    /// the content is WebKit's own, or there is none.
    fn remote_formats(&self) -> Option<Vec<String>> {
        if self.source.is_some() {
            return None;
        }
        self.data_device.as_ref().and_then(|d| d.data().selection_offer()).map(|o| o.with_mime_types(|m| m.to_vec()))
    }

    fn modifiers(&self) -> WpeModifiers {
        self.keys | self.buttons
    }

    fn move_focus(&mut self, view: &wpe_platform::View) {
        if self.focused.as_ref() == Some(view) {
            return;
        }
        if let Some(old) = self.focused.take() {
            self.tell.push(Tell::FocusOut(old));
        }
        self.focused = Some(view.clone());
        self.tell.push(Tell::FocusIn(view.clone()));
    }

    fn show_cursor(&mut self, conn: &Connection, icon: CursorIcon) {
        if self.cursor == Some(icon) {
            return;
        }
        if let Some(pointer) = &self.pointer {
            if pointer.set_cursor(conn, icon).is_ok() {
                self.cursor = Some(icon);
            }
        }
    }

    /// The shape for resizing from an edge, or for what is under the pointer.
    fn point(&mut self, conn: &Connection, in_window: (f64, f64), shape: CursorIcon) {
        let edge = self.resize_edge(in_window);
        self.on_resize_edge = edge.is_some();
        let icon = match edge {
            Some(ResizeEdge::Left | ResizeEdge::Right) => CursorIcon::EwResize,
            Some(ResizeEdge::Top | ResizeEdge::Bottom) => CursorIcon::NsResize,
            Some(ResizeEdge::TopLeft | ResizeEdge::BottomRight) => CursorIcon::NwseResize,
            Some(ResizeEdge::TopRight | ResizeEdge::BottomLeft) => CursorIcon::NeswResize,
            _ => shape,
        };
        self.show_cursor(conn, icon);
    }

    /// Which edges of the window a point is on, for resizing from there.
    fn resize_edge(&self, (x, y): (f64, f64)) -> Option<ResizeEdge> {
        if !self.client_side || self.fixed {
            return None;
        }
        let (w, h) = (self.size.0 as f64, self.size.1 as f64);
        let left = x <= RESIZE_BORDER;
        let right = x >= w - RESIZE_BORDER;
        let top = y <= RESIZE_BORDER;
        let bottom = y >= h - RESIZE_BORDER;
        Some(match (left, right, top, bottom) {
            (true, _, true, _) => ResizeEdge::TopLeft,
            (true, _, _, true) => ResizeEdge::BottomLeft,
            (_, true, true, _) => ResizeEdge::TopRight,
            (_, true, _, true) => ResizeEdge::BottomRight,
            (true, ..) => ResizeEdge::Left,
            (_, true, ..) => ResizeEdge::Right,
            (_, _, true, _) => ResizeEdge::Top,
            (.., true) => ResizeEdge::Bottom,
            _ => return None,
        })
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
        self.client_side = configure.decoration_mode == DecorationMode::Client;
        self.maximized = configure.state.contains(WindowState::MAXIMIZED);
        self.fullscreen = configure.state.contains(WindowState::FULLSCREEN);
        self.fixed = configure.state.intersects(
            WindowState::MAXIMIZED | WindowState::FULLSCREEN | WindowState::TILED_LEFT | WindowState::TILED_RIGHT | WindowState::TILED_TOP | WindowState::TILED_BOTTOM,
        );
        if (width, height) != self.size {
            self.size = (width, height);
            self.tell.push(Tell::ToplevelResized(toplevel.clone(), width, height));
            for index in 0..self.slots.len() {
                self.relayout(index);
            }
            self.tell.push(Tell::WindowResized(width, height));
        }
        // Painted on every configure: a commit answers it.
        self.paint_background();
        let mut state = wpe_platform::ToplevelState::empty();
        if self.maximized {
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
            for view in self.slots.iter().filter(|s| s.visible).filter_map(|s| s.view.upgrade()) {
                self.tell.push(Tell::Map(view));
            }
        }
    }
}

impl SeatHandler for State {
    fn seat_state(&mut self) -> &mut SeatState {
        &mut self.seat_state
    }

    fn new_seat(&mut self, _: &Connection, _: &QueueHandle<Self>, _: wl_seat::WlSeat) {}

    fn new_capability(&mut self, _: &Connection, qh: &QueueHandle<Self>, seat: wl_seat::WlSeat, capability: Capability) {
        if capability == Capability::Keyboard && self.keyboard.is_none() {
            self.keyboard = self.seat_state.get_keyboard(qh, &seat, None).ok();
        }
        if capability == Capability::Pointer && self.pointer.is_none() {
            // The compositor's own shapes where it has them (cursor-shape-v1),
            // else the system's cursor theme.
            let surface = self.compositor.create_surface(qh);
            self.pointer = self.seat_state.get_pointer_with_theme::<State, ()>(qh, &seat, self.shm.wl_shm(), surface, ThemeSpec::default()).ok();
        }
        if self.data_device.is_none() {
            self.data_device = self.data_manager.as_ref().map(|m| m.get_data_device(qh, &seat));
        }
        self.seat = Some(seat);
    }

    fn remove_capability(&mut self, _: &Connection, _: &QueueHandle<Self>, _: wl_seat::WlSeat, capability: Capability) {
        if capability == Capability::Keyboard {
            if let Some(keyboard) = self.keyboard.take() {
                keyboard.release();
            }
        }
        if capability == Capability::Pointer {
            if let Some(pointer) = self.pointer.take() {
                pointer.pointer().release();
            }
            self.cursor = None;
        }
    }

    fn remove_seat(&mut self, _: &Connection, _: &QueueHandle<Self>, _: wl_seat::WlSeat) {}
}

/// Milliseconds on the monotonic clock, as event times are.
fn now_ms() -> u32 {
    (glib::monotonic_time() / 1000) as u32
}

/// Modifiers and locks don't repeat.
fn repeats(keysym: u32) -> bool {
    !matches!(keysym, 0xffe1..=0xffee | 0xfe01..=0xfe13 | 0xff7f | 0xff14)
}

impl State {
    fn key(&mut self, kind: EventType, key: &KeyEvent) {
        let (code, keysym) = (key.raw_code, key.keysym.raw());
        if kind == EventType::KeyboardKeyDown && repeats(keysym) {
            self.repeating = Some(code);
            self.tell.push(Tell::Repeat(Some((code, keysym))));
        } else if kind == EventType::KeyboardKeyUp && self.repeating == Some(code) {
            self.stop_repeating();
        }
        self.key_event(kind, code, keysym, key.time);
    }

    fn stop_repeating(&mut self) {
        if self.repeating.take().is_some() {
            self.tell.push(Tell::Repeat(None));
        }
    }

    fn key_event(&mut self, kind: EventType, code: u32, keysym: u32, time: u32) {
        let Some(view) = self.focused.clone() else { return };
        let ptr = unsafe {
            wpe_platform::ffi::wpe_event_keyboard_new(
                kind.into_glib(),
                view.to_glib_none().0,
                InputSource::Keyboard.into_glib(),
                time,
                self.modifiers().into_glib(),
                code + 8,
                keysym,
            )
        };
        if let Some(event) = unsafe { wpe_event(ptr) } {
            let pressed = kind == EventType::KeyboardKeyDown;
            self.tell.push(Tell::Key { view, event, keysym, modifiers: self.modifiers(), pressed });
        }
    }
}

impl KeyboardHandler for State {
    fn enter(&mut self, _: &Connection, _: &QueueHandle<Self>, _: &wl_keyboard::WlKeyboard, _: &wl_surface::WlSurface, _: u32, _: &[u32], _: &[Keysym]) {
        if let Some(view) = self.focused.clone() {
            self.tell.push(Tell::FocusIn(view));
        }
    }

    fn leave(&mut self, _: &Connection, _: &QueueHandle<Self>, _: &wl_keyboard::WlKeyboard, _: &wl_surface::WlSurface, _: u32) {
        self.stop_repeating();
        if let Some(view) = self.focused.clone() {
            self.tell.push(Tell::FocusOut(view));
        }
    }

    fn press_key(&mut self, _: &Connection, _: &QueueHandle<Self>, _: &wl_keyboard::WlKeyboard, serial: u32, event: KeyEvent) {
        self.input_serial = serial;
        self.key(EventType::KeyboardKeyDown, &event);
    }

    fn repeat_key(&mut self, _: &Connection, _: &QueueHandle<Self>, _: &wl_keyboard::WlKeyboard, _: u32, event: KeyEvent) {
        self.key(EventType::KeyboardKeyDown, &event);
    }

    fn release_key(&mut self, _: &Connection, _: &QueueHandle<Self>, _: &wl_keyboard::WlKeyboard, _: u32, event: KeyEvent) {
        self.key(EventType::KeyboardKeyUp, &event);
    }

    fn update_repeat_info(&mut self, _: &Connection, _: &QueueHandle<Self>, _: &wl_keyboard::WlKeyboard, info: RepeatInfo) {
        self.repeat = match info {
            RepeatInfo::Repeat { rate, delay } => Some((rate.get(), delay)),
            RepeatInfo::Disable => None,
        };
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
    fn pointer_frame(&mut self, conn: &Connection, _: &QueueHandle<Self>, _: &wl_pointer::WlPointer, events: &[PointerEvent]) {
        for e in events {
            // A new enter needs the shape set again.
            if matches!(e.kind, PointerEventKind::Enter { .. }) {
                self.cursor = None;
            }
            // Between the views, on the window's own surface: only resizing from its edges.
            if self.window.as_ref().is_some_and(|w| w.wl_surface() == &e.surface) {
                if matches!(e.kind, PointerEventKind::Enter { .. } | PointerEventKind::Motion { .. }) {
                    self.point(conn, e.position, CursorIcon::Default);
                }
                if let PointerEventKind::Press { serial, .. } = e.kind {
                    if let (Some(edge), Some(window), Some(seat)) = (self.resize_edge(e.position), &self.window, &self.seat) {
                        window.resize(seat, serial, edge);
                    }
                }
                continue;
            }
            let Some(index) = self.slots.iter().position(|s| s.surface == e.surface) else { continue };
            let Some(view) = self.slots[index].view.upgrade() else { continue };
            let (left, top, ..) = self.slots[index].rect(self.size);
            let in_window = (e.position.0 + left as f64, e.position.1 + top as f64);
            // BasicShell hears where the pointer is (its panels come out at the edges).
            match e.kind {
                PointerEventKind::Enter { .. } | PointerEventKind::Motion { .. } => {
                    let shape = self.slots[index].cursor;
                    self.point(conn, in_window, shape);
                    self.under = Some((view.clone(), e.position));
                    self.tell.push(Tell::Pointer(view.clone(), Some(in_window)));
                }
                PointerEventKind::Leave { .. } => {
                    self.under = None;
                    self.tell.push(Tell::Pointer(view.clone(), None));
                }
                _ => {}
            }
            match e.kind {
                PointerEventKind::Press { serial, .. } => {
                    self.press_serial = serial;
                    self.input_serial = serial;
                    // At the window's edge, where there is no frame: resizing it.
                    if let Some(edge) = self.resize_edge(in_window) {
                        if let (Some(window), Some(seat)) = (&self.window, &self.seat) {
                            window.resize(seat, serial, edge);
                            self.grabbed = true;
                            continue;
                        }
                    }
                    // A click gives the view it lands in the keyboard.
                    self.move_focus(&view);
                }
                PointerEventKind::Release { .. } if self.grabbed => {
                    self.grabbed = false;
                    continue;
                }
                _ => {}
            }
            // WebKit keeps what was under the pointer hovered after a leave;
            // a move to outside the view first ends that.
            let (x, y) = if matches!(e.kind, PointerEventKind::Leave { .. }) { (-1.0, -1.0) } else { e.position };
            let modifiers = self.modifiers();
            let view_ptr = view.to_glib_none().0;
            let ptr = match e.kind {
                PointerEventKind::Enter { .. } | PointerEventKind::Leave { .. } | PointerEventKind::Motion { .. } => {
                    let (kind, time) = match e.kind {
                        PointerEventKind::Enter { .. } => (EventType::PointerEnter, 0),
                        PointerEventKind::Leave { .. } => {
                            let moved = unsafe {
                                wpe_platform::ffi::wpe_event_pointer_move_new(EventType::PointerMove.into_glib(), view_ptr, InputSource::Mouse.into_glib(), 0, modifiers.into_glib(), x, y, 0.0, 0.0)
                            };
                            if let Some(event) = unsafe { wpe_event(moved) } {
                                self.tell.push(Tell::Event(view.clone(), event));
                            }
                            (EventType::PointerLeave, 0)
                        }
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

impl DataDeviceHandler for State {
    fn enter(&mut self, _: &Connection, _: &QueueHandle<Self>, _: &wl_data_device::WlDataDevice, _: f64, _: f64, _: &wl_surface::WlSurface) {}
    fn leave(&mut self, _: &Connection, _: &QueueHandle<Self>, _: &wl_data_device::WlDataDevice) {}
    fn motion(&mut self, _: &Connection, _: &QueueHandle<Self>, _: &wl_data_device::WlDataDevice, _: f64, _: f64) {}
    fn drop_performed(&mut self, _: &Connection, _: &QueueHandle<Self>, _: &wl_data_device::WlDataDevice) {}

    /// What is on the clipboard changed; while it is WebKit's own, WebKit knows.
    fn selection(&mut self, _: &Connection, _: &QueueHandle<Self>, _: &wl_data_device::WlDataDevice) {
        if self.source.is_some() {
            return;
        }
        let formats = self.remote_formats();
        self.tell.push(Tell::Selection(formats));
    }
}

impl DataOfferHandler for State {
    fn source_actions(&mut self, _: &Connection, _: &QueueHandle<Self>, _: &mut DragOffer, _: DndAction) {}
    fn selected_action(&mut self, _: &Connection, _: &QueueHandle<Self>, _: &mut DragOffer, _: DndAction) {}
}

impl DataSourceHandler for State {
    fn accept_mime(&mut self, _: &Connection, _: &QueueHandle<Self>, _: &wl_data_source::WlDataSource, _: Option<String>) {}

    fn send_request(&mut self, _: &Connection, _: &QueueHandle<Self>, source: &wl_data_source::WlDataSource, mime: String, fd: WritePipe) {
        if self.source.as_ref().is_some_and(|s| s.inner() == source) {
            self.tell.push(Tell::Send(mime, fd));
        }
    }

    /// Another program took the clipboard.
    fn cancelled(&mut self, _: &Connection, _: &QueueHandle<Self>, source: &wl_data_source::WlDataSource) {
        if self.source.as_ref().is_some_and(|s| s.inner() == source) {
            self.source = None;
            self.tell.push(Tell::Selection(None));
        }
    }

    fn dnd_dropped(&mut self, _: &Connection, _: &QueueHandle<Self>, _: &wl_data_source::WlDataSource) {}
    fn dnd_finished(&mut self, _: &Connection, _: &QueueHandle<Self>, _: &wl_data_source::WlDataSource) {}
    fn action(&mut self, _: &Connection, _: &QueueHandle<Self>, _: &wl_data_source::WlDataSource, _: DndAction) {}
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
