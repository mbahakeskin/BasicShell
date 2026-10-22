//! BasicShell's own WPEPlatform: the Display, Toplevel and View WebKit draws
//! into, on a Wayland connection of BasicShell's (wayland.rs). One window
//! holds several views: the first is the window's own surface, every other
//! one a subsurface over it, placed where BasicShell says, so the browser's
//! own interface can sit over the page (WebKit's Wayland platform can't place
//! its views).

mod display;
mod toplevel;
mod view;
mod wayland;

pub use display::Display;
pub use toplevel::Toplevel;
