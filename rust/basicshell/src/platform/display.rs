use std::cell::OnceCell;
use std::rc::Rc;

use glib::prelude::*;
use glib::subclass::prelude::*;
use wpe_platform::subclass::prelude::*;

use super::wayland::Shared;

mod imp {
    use super::*;

    #[derive(Default)]
    pub struct Display {
        pub shared: OnceCell<Rc<Shared>>,
        pub keymap: OnceCell<wpe_platform::Keymap>,
    }

    #[glib::object_subclass]
    impl ObjectSubclass for Display {
        const NAME: &'static str = "BasicShellDisplay";
        type Type = super::Display;
        type ParentType = wpe_platform::Display;
    }

    impl ObjectImpl for Display {}

    impl DisplayImpl for Display {
        fn connect(&self) -> Result<(), glib::Error> {
            let shared = Shared::connect().map_err(|e| glib::Error::new(wpe_platform::DisplayError::ConnectionFailed, &e))?;
            let _ = self.shared.set(shared);
            Ok(())
        }

        fn create_view(&self) -> Option<wpe_platform::View> {
            let view: super::super::view::View = glib::Object::builder().property("display", self.obj().as_ref()).build();
            Some(view.upcast())
        }

        // Toplevels are BasicShell's to make (Toplevel::new); WebKit's own,
        // one per view, are not wanted.
        fn create_toplevel(&self, _max_views: u32) -> Option<wpe_platform::Toplevel> {
            None
        }

        fn keymap(&self) -> Option<wpe_platform::Keymap> {
            Some(self.keymap.get_or_init(|| wpe_platform::KeymapXKB::new().upcast()).clone())
        }
    }
}

glib::wrapper! {
    /// The connection to the compositor, and what WebKit's views are made by.
    pub struct Display(ObjectSubclass<imp::Display>) @extends wpe_platform::Display;
}

impl Display {
    pub fn new() -> Self {
        glib::Object::new()
    }

    pub(super) fn shared(&self) -> Rc<Shared> {
        self.imp().shared.get().expect("the display is connected first").clone()
    }
}

impl Default for Display {
    fn default() -> Self {
        Self::new()
    }
}
