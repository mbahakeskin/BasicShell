use glib::prelude::*;
use glib::subclass::prelude::*;
use glib::translate::*;

use crate::Toplevel;

/// What a platform's toplevel does: the window the views are in.
pub trait ToplevelImpl: ObjectImpl + ObjectSubclass<Type: IsA<Toplevel>> {
    fn set_title(&self, _title: Option<&str>) {}

    fn resize(&self, _width: i32, _height: i32) -> bool {
        false
    }

    fn set_fullscreen(&self, _fullscreen: bool) -> bool {
        false
    }

    fn set_maximized(&self, _maximized: bool) -> bool {
        false
    }

    fn set_minimized(&self) -> bool {
        false
    }
}

unsafe impl<T: ToplevelImpl> IsSubclassable<T> for Toplevel {
    fn class_init(class: &mut glib::Class<Self>) {
        Self::parent_class_init::<T>(class);
        let klass = class.as_mut();
        klass.set_title = Some(set_title::<T>);
        klass.resize = Some(resize::<T>);
        klass.set_fullscreen = Some(set_fullscreen::<T>);
        klass.set_maximized = Some(set_maximized::<T>);
        klass.set_minimized = Some(set_minimized::<T>);
    }
}

unsafe fn imp<'a, T: ToplevelImpl>(ptr: *mut ffi::WPEToplevel) -> &'a T {
    unsafe { (&*(ptr as *mut T::Instance)).imp() }
}

unsafe extern "C" fn set_title<T: ToplevelImpl>(ptr: *mut ffi::WPEToplevel, title: *const std::ffi::c_char) {
    let title: Option<glib::GString> = unsafe { from_glib_none(title) };
    unsafe { imp::<T>(ptr) }.set_title(title.as_deref());
}

unsafe extern "C" fn resize<T: ToplevelImpl>(ptr: *mut ffi::WPEToplevel, width: i32, height: i32) -> glib::ffi::gboolean {
    unsafe { imp::<T>(ptr) }.resize(width, height).into_glib()
}

unsafe extern "C" fn set_fullscreen<T: ToplevelImpl>(ptr: *mut ffi::WPEToplevel, fullscreen: glib::ffi::gboolean) -> glib::ffi::gboolean {
    unsafe { imp::<T>(ptr) }.set_fullscreen(from_glib(fullscreen)).into_glib()
}

unsafe extern "C" fn set_maximized<T: ToplevelImpl>(ptr: *mut ffi::WPEToplevel, maximized: glib::ffi::gboolean) -> glib::ffi::gboolean {
    unsafe { imp::<T>(ptr) }.set_maximized(from_glib(maximized)).into_glib()
}

unsafe extern "C" fn set_minimized<T: ToplevelImpl>(ptr: *mut ffi::WPEToplevel) -> glib::ffi::gboolean {
    unsafe { imp::<T>(ptr) }.set_minimized().into_glib()
}
