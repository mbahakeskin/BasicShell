use std::cell::RefCell;

use glib::prelude::*;
use glib::subclass::prelude::*;
use wpe_platform::prelude::*;
use wpe_platform::subclass::prelude::*;

use super::display::Display;
use super::wayland::Rect;

mod imp {
    use super::*;

    #[derive(Default)]
    pub struct Toplevel {
        pub on_close: RefCell<Option<Box<dyn Fn()>>>,
    }

    #[glib::object_subclass]
    impl ObjectSubclass for Toplevel {
        const NAME: &'static str = "BasicShellToplevel";
        type Type = super::Toplevel;
        type ParentType = wpe_platform::Toplevel;
    }

    impl ObjectImpl for Toplevel {
        fn constructed(&self) {
            self.parent_constructed();
            let obj = self.obj();
            obj.shared().create_window(&obj);
        }
    }

    impl ToplevelImpl for Toplevel {
        fn set_title(&self, title: Option<&str>) {
            self.obj().shared().set_title(title.unwrap_or(""));
        }

        fn resize(&self, width: i32, height: i32) -> bool {
            self.obj().shared().request_size(width, height);
            true
        }

        fn set_fullscreen(&self, fullscreen: bool) -> bool {
            self.obj().shared().set_fullscreen(fullscreen);
            true
        }

        fn set_maximized(&self, maximized: bool) -> bool {
            self.obj().shared().set_maximized(maximized);
            true
        }

        fn set_minimized(&self) -> bool {
            self.obj().shared().set_minimized();
            true
        }
    }
}

glib::wrapper! {
    /// BasicShell's window: an xdg toplevel holding every view given to it.
    pub struct Toplevel(ObjectSubclass<imp::Toplevel>) @extends wpe_platform::Toplevel;
}

impl Toplevel {
    pub fn new(display: &Display) -> Self {
        glib::Object::builder()
            .property("display", display.upcast_ref::<wpe_platform::Display>())
            .property("max-views", 0u32)
            .build()
    }

    /// Called when the compositor asks the window to close.
    pub fn connect_close(&self, f: impl Fn() + 'static) {
        *self.imp().on_close.borrow_mut() = Some(Box::new(f));
    }

    pub(super) fn close_requested(&self) {
        if let Some(f) = self.imp().on_close.borrow().as_ref() {
            f();
        }
    }

    /// Where `view` takes the pointer, in its own coordinates; elsewhere the
    /// pointer goes to what is under it.
    pub fn set_input_region(&self, view: &impl IsA<wpe_platform::View>, rects: &[Rect]) {
        self.shared().set_input_region(view.upcast_ref(), rects);
    }

    /// Puts `view` at `place` in the window; None: all of it.
    pub fn place(&self, view: &impl IsA<wpe_platform::View>, place: Option<Rect>) {
        self.shared().place(view.upcast_ref(), place);
    }

    pub fn set_visible(&self, view: &impl IsA<wpe_platform::View>, visible: bool) {
        self.shared().set_visible(view.upcast_ref(), visible);
    }

    /// Puts `view` over the window's other views.
    pub fn raise(&self, view: &impl IsA<wpe_platform::View>) {
        self.shared().raise(view.upcast_ref());
    }

    /// Gives `view` the keyboard (a click in a view gives it too).
    pub fn focus(&self, view: &impl IsA<wpe_platform::View>) {
        self.shared().focus(view.upcast_ref());
    }

    /// The window follows the pointer, from the button just pressed.
    pub fn start_move(&self) {
        self.shared().start_move();
    }

    pub fn is_maximized(&self) -> bool {
        self.shared().is_maximized()
    }

    pub fn is_fullscreen(&self) -> bool {
        self.shared().is_fullscreen()
    }

    pub fn toggle_maximized(&self) {
        let shared = self.shared();
        shared.set_maximized(!shared.is_maximized());
    }

    pub fn minimize(&self) {
        self.shared().set_minimized();
    }

    /// The window's size.
    pub fn size(&self) -> (i32, i32) {
        self.shared().size()
    }

    /// The pointer over a view, in the window's coordinates, or None when it
    /// has left the view.
    pub fn connect_pointer(&self, f: impl Fn(&wpe_platform::View, Option<(f64, f64)>) + 'static) {
        self.shared().connect_pointer(f);
    }

    /// Every key, before the view with the keyboard gets it: true keeps it.
    pub fn connect_key(&self, f: impl Fn(u32, wpe_platform::Modifiers, bool) -> bool + 'static) {
        self.shared().connect_key(f);
    }

    /// The window's new size, after the views not placed have been given it.
    pub fn connect_resized(&self, f: impl Fn(i32, i32) + 'static) {
        self.shared().connect_resized(f);
    }

    fn shared(&self) -> std::rc::Rc<super::wayland::Shared> {
        self.display().and_downcast::<Display>().expect("BasicShell's display").shared()
    }
}
