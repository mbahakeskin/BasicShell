use glib::prelude::*;
use glib::subclass::prelude::*;
use glib::translate::*;

use crate::{Buffer, View};

/// What a platform's view does: show the buffers WebKit renders, and set the
/// pointer's cursor.
pub trait ViewImpl: ObjectImpl + ObjectSubclass<Type: IsA<View>> {
    /// A frame to show. Once it is on screen, `buffer_rendered`; once the
    /// platform no longer reads it, `buffer_released`.
    fn render_buffer(&self, buffer: &Buffer, damage: &[ffi::WPERectangle]) -> Result<(), glib::Error>;

    fn set_cursor_from_name(&self, _name: &str) {}
}

unsafe impl<T: ViewImpl> IsSubclassable<T> for View {
    fn class_init(class: &mut glib::Class<Self>) {
        Self::parent_class_init::<T>(class);
        let klass = class.as_mut();
        klass.render_buffer = Some(render_buffer::<T>);
        klass.set_cursor_from_name = Some(set_cursor_from_name::<T>);
    }
}

unsafe fn imp<'a, T: ViewImpl>(ptr: *mut ffi::WPEView) -> &'a T {
    unsafe { (&*(ptr as *mut T::Instance)).imp() }
}

unsafe extern "C" fn render_buffer<T: ViewImpl>(
    ptr: *mut ffi::WPEView,
    buffer: *mut ffi::WPEBuffer,
    rects: *const ffi::WPERectangle,
    n_rects: u32,
    error: *mut *mut glib::ffi::GError,
) -> glib::ffi::gboolean {
    let buffer: Borrowed<Buffer> = unsafe { from_glib_borrow(buffer) };
    let damage = if rects.is_null() || n_rects == 0 {
        &[][..]
    } else {
        unsafe { std::slice::from_raw_parts(rects, n_rects as usize) }
    };
    match unsafe { imp::<T>(ptr) }.render_buffer(&buffer, damage) {
        Ok(()) => true.into_glib(),
        Err(e) => {
            if !error.is_null() {
                unsafe { *error = e.into_glib_ptr() };
            }
            false.into_glib()
        }
    }
}

unsafe extern "C" fn set_cursor_from_name<T: ViewImpl>(ptr: *mut ffi::WPEView, name: *const std::ffi::c_char) {
    let name: Borrowed<glib::GString> = unsafe { from_glib_borrow(name) };
    unsafe { imp::<T>(ptr) }.set_cursor_from_name(name.as_str());
}
