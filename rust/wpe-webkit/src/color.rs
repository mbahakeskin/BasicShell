use glib::translate::*;

use crate::Color;

impl Color {
    /// A colour from its components, each from 0 to 1.
    pub fn rgba(red: f64, green: f64, blue: f64, alpha: f64) -> Color {
        let color = ffi::WebKitColor { red, green, blue, alpha };
        unsafe { from_glib_none(&color as *const ffi::WebKitColor) }
    }
}
