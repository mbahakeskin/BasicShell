use glib::translate::*;

use crate::ContextMenuItem;

impl ContextMenuItem {
    /// What choosing the item does, as an action (gir leaves this out: it
    /// is a GAction). WebKit's own items do their work when it is activated
    /// with the item's target, once the menu has been handled.
    pub fn gaction(&self) -> Option<gio::Action> {
        unsafe { from_glib_none(ffi::webkit_context_menu_item_get_gaction(self.to_glib_none().0)) }
    }
}
