use glib::prelude::*;
use glib::subclass::prelude::*;
use wpe_platform::prelude::*;
use wpe_platform::subclass::clipboard::{serialize, Formats};
use wpe_platform::subclass::prelude::*;

use super::display::Display;

mod imp {
    use super::*;

    #[derive(Default)]
    pub struct Clipboard {}

    #[glib::object_subclass]
    impl ObjectSubclass for Clipboard {
        const NAME: &'static str = "BasicShellClipboard";
        type Type = super::Clipboard;
        type ParentType = wpe_platform::Clipboard;
    }

    impl ObjectImpl for Clipboard {}

    impl ClipboardImpl for Clipboard {
        fn read(&self, format: &str) -> Option<glib::Bytes> {
            self.obj().shared()?.read_selection(format).map(glib::Bytes::from_owned)
        }

        fn changed(&self, formats: Option<&Formats>, is_local: bool, content: Option<&wpe_platform::ClipboardContent>) {
            // WebKit copied something: the system's clipboard offers it.
            if is_local {
                if let Some(shared) = self.obj().shared() {
                    shared.offer_selection(formats.map(|f| f.to_vec()).unwrap_or_default());
                }
            }
            self.parent_changed(formats, is_local, content);
        }
    }
}

glib::wrapper! {
    /// The system's clipboard (wl_data_device), for WebKit's copy and paste.
    pub struct Clipboard(ObjectSubclass<imp::Clipboard>) @extends wpe_platform::Clipboard;
}

impl Clipboard {
    pub fn new(display: &Display) -> Self {
        glib::Object::builder().property("display", display.upcast_ref::<wpe_platform::Display>()).build()
    }

    fn shared(&self) -> Option<std::rc::Rc<super::wayland::Shared>> {
        Some(self.display()?.downcast::<Display>().ok()?.shared())
    }

    /// Another program put something on the clipboard, in these formats
    /// (none: the clipboard is empty).
    pub(super) fn remote_changed(&self, formats: Option<Vec<String>>) {
        let formats = formats.map(|f| Formats::new(&f));
        self.imp().parent_changed(formats.as_ref(), false, None);
    }

    /// What WebKit copied, in `format`, for the program pasting it.
    pub(super) fn serialize(&self, format: &str) -> Option<Vec<u8>> {
        serialize(&self.content()?, format)
    }
}
