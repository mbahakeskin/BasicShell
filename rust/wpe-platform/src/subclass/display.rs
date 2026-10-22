use glib::prelude::*;
use glib::subclass::prelude::*;
use glib::translate::*;

use crate::{Display, Keymap, Toplevel, View};

/// What a platform's display does: connect to whatever shows its windows, and
/// make the views and toplevels WebKit asks for.
pub trait DisplayImpl: ObjectImpl + ObjectSubclass<Type: IsA<Display>> {
    fn connect(&self) -> Result<(), glib::Error> {
        Ok(())
    }

    fn create_view(&self) -> Option<View> {
        None
    }

    fn create_toplevel(&self, _max_views: u32) -> Option<Toplevel> {
        None
    }

    fn keymap(&self) -> Option<Keymap> {
        None
    }
}

unsafe impl<T: DisplayImpl> IsSubclassable<T> for Display {
    fn class_init(class: &mut glib::Class<Self>) {
        Self::parent_class_init::<T>(class);
        let klass = class.as_mut();
        klass.connect = Some(connect::<T>);
        klass.create_view = Some(create_view::<T>);
        klass.create_toplevel = Some(create_toplevel::<T>);
        klass.get_keymap = Some(keymap::<T>);
    }
}

unsafe fn imp<'a, T: DisplayImpl>(ptr: *mut ffi::WPEDisplay) -> &'a T {
    unsafe { (&*(ptr as *mut T::Instance)).imp() }
}

unsafe extern "C" fn connect<T: DisplayImpl>(ptr: *mut ffi::WPEDisplay, error: *mut *mut glib::ffi::GError) -> glib::ffi::gboolean {
    match unsafe { imp::<T>(ptr) }.connect() {
        Ok(()) => true.into_glib(),
        Err(e) => {
            if !error.is_null() {
                unsafe { *error = e.into_glib_ptr() };
            }
            false.into_glib()
        }
    }
}

// Transfer full, as WebKit takes them.
unsafe extern "C" fn create_view<T: DisplayImpl>(ptr: *mut ffi::WPEDisplay) -> *mut ffi::WPEView {
    unsafe { imp::<T>(ptr) }.create_view().into_glib_ptr()
}

unsafe extern "C" fn create_toplevel<T: DisplayImpl>(ptr: *mut ffi::WPEDisplay, max_views: u32) -> *mut ffi::WPEToplevel {
    unsafe { imp::<T>(ptr) }.create_toplevel(max_views).into_glib_ptr()
}

// Transfer none: the display keeps it.
unsafe extern "C" fn keymap<T: DisplayImpl>(ptr: *mut ffi::WPEDisplay) -> *mut ffi::WPEKeymap {
    let keymap = unsafe { imp::<T>(ptr) }.keymap();
    keymap.as_ref().map(|k| k.as_ptr()).unwrap_or(std::ptr::null_mut())
}
