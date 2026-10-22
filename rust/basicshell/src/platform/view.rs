use glib::prelude::*;
use glib::subclass::prelude::*;
use wpe_platform::prelude::*;
use wpe_platform::subclass::prelude::*;

use super::display::Display;
use super::toplevel::Toplevel;

mod imp {
    use super::*;

    #[derive(Default)]
    pub struct View {}

    #[glib::object_subclass]
    impl ObjectSubclass for View {
        const NAME: &'static str = "BasicShellView";
        type Type = super::View;
        type ParentType = wpe_platform::View;
    }

    impl ObjectImpl for View {
        fn constructed(&self) {
            self.parent_constructed();
            // Given to a window (or taken from one): it gets a surface there.
            self.obj().connect_notify_local(Some("toplevel"), |view, _| {
                let shared = view.shared();
                match view.toplevel().and_downcast::<Toplevel>() {
                    Some(toplevel) => shared.attach_view(view.upcast_ref(), &toplevel),
                    None => shared.detach_view(view.upcast_ref()),
                }
            });
        }

        fn dispose(&self) {
            if let Some(display) = self.obj().display().and_downcast::<Display>() {
                display.shared().detach_view(self.obj().upcast_ref());
            }
        }
    }

    impl ViewImpl for View {
        fn render_buffer(&self, buffer: &wpe_platform::Buffer, damage: &[wpe_platform::ffi::WPERectangle]) -> Result<(), glib::Error> {
            self.obj().shared().render(self.obj().upcast_ref(), buffer, damage)
        }

        fn set_cursor_from_name(&self, name: &str) {
            self.obj().shared().set_cursor(self.obj().upcast_ref(), name);
        }
    }
}

glib::wrapper! {
    /// Where WebKit draws one web view: a surface in BasicShell's window.
    pub struct View(ObjectSubclass<imp::View>) @extends wpe_platform::View;
}

impl View {
    fn shared(&self) -> std::rc::Rc<super::wayland::Shared> {
        self.display().and_downcast::<Display>().expect("BasicShell's display").shared()
    }
}
