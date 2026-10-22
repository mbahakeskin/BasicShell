use glib::prelude::*;
use glib::subclass::prelude::*;
use glib::translate::*;

use crate::{Clipboard, ClipboardContent};

/// The formats a clipboard's content is in (MIME types): WebKit's array of
/// interned strings, ending with a null.
pub struct Formats {
    array: *mut glib::ffi::GPtrArray,
    owned: bool,
}

impl Formats {
    /// An array of these formats, to give WebKit.
    pub fn new<S: AsRef<str>>(formats: &[S]) -> Formats {
        unsafe {
            let array = glib::ffi::g_ptr_array_new();
            for format in formats {
                let interned = glib::ffi::g_intern_string(format.as_ref().to_glib_none().0);
                glib::ffi::g_ptr_array_add(array, interned as glib::ffi::gpointer);
            }
            glib::ffi::g_ptr_array_add(array, std::ptr::null_mut());
            Formats { array, owned: true }
        }
    }

    unsafe fn borrowed(array: *mut glib::ffi::GPtrArray) -> Formats {
        Formats { array, owned: false }
    }

    pub fn to_vec(&self) -> Vec<String> {
        if self.array.is_null() {
            return Vec::new();
        }
        unsafe {
            let array = &*self.array;
            (0..array.len as usize)
                .map(|i| *array.pdata.add(i))
                .take_while(|p| !p.is_null())
                .map(|p| std::ffi::CStr::from_ptr(p as *const std::ffi::c_char).to_string_lossy().into_owned())
                .collect()
        }
    }

    fn as_ptr(&self) -> *mut glib::ffi::GPtrArray {
        self.array
    }
}

impl Drop for Formats {
    fn drop(&mut self) {
        if self.owned && !self.array.is_null() {
            unsafe { glib::ffi::g_ptr_array_unref(self.array) };
        }
    }
}

/// A platform's clipboard: reading what another program put on it, and
/// hearing that what is on it changed (WebKit put something there, or
/// another program did).
pub trait ClipboardImpl: ObjectImpl + ObjectSubclass<Type: IsA<Clipboard>> {
    /// What is on the clipboard in `format`, when another program put it there.
    fn read(&self, _format: &str) -> Option<glib::Bytes> {
        None
    }

    /// The content changed: `is_local` when WebKit set it (`content`), else
    /// another program did, in `formats` (none: nothing is there).
    fn changed(&self, formats: Option<&Formats>, is_local: bool, content: Option<&ClipboardContent>) {
        self.parent_changed(formats, is_local, content)
    }
}

pub trait ClipboardImplExt: ClipboardImpl {
    /// WPEPlatform's own handling: it takes the formats and the content and
    /// counts the change.
    fn parent_changed(&self, formats: Option<&Formats>, is_local: bool, content: Option<&ClipboardContent>) {
        unsafe {
            let data = Self::type_data();
            let parent = data.as_ref().parent_class() as *mut ffi::WPEClipboardClass;
            if let Some(f) = (*parent).changed {
                f(
                    self.obj().unsafe_cast_ref::<Clipboard>().to_glib_none().0,
                    formats.map_or(std::ptr::null_mut(), |f| f.as_ptr()),
                    is_local.into_glib(),
                    content.to_glib_none().0,
                );
            }
        }
    }
}

impl<T: ClipboardImpl> ClipboardImplExt for T {}

unsafe impl<T: ClipboardImpl> IsSubclassable<T> for Clipboard {
    fn class_init(class: &mut glib::Class<Self>) {
        Self::parent_class_init::<T>(class);
        let klass = class.as_mut();
        klass.read = Some(read::<T>);
        klass.changed = Some(changed::<T>);
    }
}

unsafe fn imp<'a, T: ClipboardImpl>(ptr: *mut ffi::WPEClipboard) -> &'a T {
    unsafe { (&*(ptr as *mut T::Instance)).imp() }
}

// Transfer full.
unsafe extern "C" fn read<T: ClipboardImpl>(ptr: *mut ffi::WPEClipboard, format: *const std::ffi::c_char) -> *mut glib::ffi::GBytes {
    let format: glib::GString = unsafe { from_glib_none(format) };
    unsafe { imp::<T>(ptr) }.read(&format).into_glib_ptr()
}

unsafe extern "C" fn changed<T: ClipboardImpl>(
    ptr: *mut ffi::WPEClipboard,
    formats: *mut glib::ffi::GPtrArray,
    is_local: glib::ffi::gboolean,
    content: *mut ffi::WPEClipboardContent,
) {
    let formats = (!formats.is_null()).then(|| unsafe { Formats::borrowed(formats) });
    let content: Option<ClipboardContent> = unsafe { from_glib_none(content) };
    unsafe { imp::<T>(ptr) }.changed(formats.as_ref(), from_glib(is_local), content.as_ref());
}

/// The content in `format`, as WPEPlatform writes it (gir can't bind this:
/// it takes a GOutputStream).
pub fn serialize(content: &ClipboardContent, format: &str) -> Option<Vec<u8>> {
    let stream = gio::MemoryOutputStream::new_resizable();
    let written: bool = unsafe {
        from_glib(ffi::wpe_clipboard_content_serialize(
            content.to_glib_none().0,
            format.to_glib_none().0,
            stream.upcast_ref::<gio::OutputStream>().to_glib_none().0,
        ))
    };
    if !written {
        return None;
    }
    use gio::prelude::*;
    stream.close(None::<&gio::Cancellable>).ok()?;
    Some(stream.steal_as_bytes().to_vec())
}
