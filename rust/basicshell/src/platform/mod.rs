//! BasicShell's own WPEPlatform: the Display, Toplevel and View WebKit draws
//! into, on a Wayland connection of BasicShell's (wayland.rs). One window
//! holds several views, each a subsurface of it, placed, stacked, shown and
//! hidden as BasicShell says: its tabs, and its own interface over them
//! (WebKit's Wayland platform can't place its views).

mod display;
mod toplevel;
mod view;
mod wayland;

pub use display::Display;
pub use toplevel::Toplevel;
pub use wayland::Rect;
