use glib::translate::*;

glib::wrapper! {
    /// An input event from the platform: a key, the pointer, a touch.
    #[derive(Debug)]
    pub struct Event(Shared<ffi::WPEEvent>);

    match fn {
        ref => |ptr| ffi::wpe_event_ref(ptr),
        unref => |ptr| ffi::wpe_event_unref(ptr),
        type_ => || ffi::wpe_event_get_type(),
    }
}

impl Event {
    pub fn event_type(&self) -> crate::EventType {
        unsafe { from_glib(ffi::wpe_event_get_event_type(self.to_glib_none().0)) }
    }
}
