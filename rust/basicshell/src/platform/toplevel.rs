use std::cell::RefCell;

use glib::prelude::*;
use glib::subclass::prelude::*;
use wpe_platform::prelude::*;
use wpe_platform::subclass::prelude::*;

use super::display::Display;

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

    fn shared(&self) -> std::rc::Rc<super::wayland::Shared> {
        self.display().and_downcast::<Display>().expect("BasicShell's display").shared()
    }
}
