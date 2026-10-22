//! Subclassing WPEPlatform's classes from Rust: a platform of one's own is a
//! Display, a View and a Toplevel whose virtual methods it implements.

pub mod display;
pub mod toplevel;
pub mod view;

pub mod prelude {
    pub use super::display::DisplayImpl;
    pub use super::toplevel::ToplevelImpl;
    pub use super::view::ViewImpl;
    pub use glib::subclass::prelude::*;
}
