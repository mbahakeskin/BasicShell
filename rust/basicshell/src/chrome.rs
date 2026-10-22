//! BasicShell's interface: `ui/chrome.html` in a view of its own over the
//! tabs, transparent, taking the pointer only where something of it shows.
//! It tells BasicShell what was asked for through the "basicshell" script
//! message handler (JSON); BasicShell tells it how things are through
//! `window.BasicShell`.

use std::cell::Cell;
use std::rc::Rc;

use glib::prelude::*;
use serde_json::Value;
use wpe_webkit::prelude::*;

use crate::platform::{Display, Toplevel};

const HTML: &str = include_str!("../ui/chrome.html");

pub struct Chrome {
    view: wpe_webkit::WebView,
    ready: Rc<Cell<bool>>,
}

impl Chrome {
    /// The interface, in `toplevel`, each message it sends given to
    /// `received`; "ready" once it can be told things.
    pub fn new(display: &Display, toplevel: &Toplevel, received: impl Fn(Value) + 'static) -> Option<Chrome> {
        let content = wpe_webkit::UserContentManager::new();
        content.register_script_message_handler("basicshell", None);
        let settings = wpe_webkit::Settings::new();
        settings.set_enable_developer_extras(true);
        // It loads nothing, keeps nothing: a session of its own, in memory.
        let view: wpe_webkit::WebView = glib::Object::builder()
            .property("display", display.upcast_ref::<wpe_platform::Display>())
            .property("network-session", wpe_webkit::NetworkSession::new_ephemeral())
            .property("user-content-manager", &content)
            .property("settings", &settings)
            .build();
        view.set_background_color(&wpe_webkit::Color::rgba(0.0, 0.0, 0.0, 0.0));
        let wpe_view = view.wpe_view()?;
        wpe_view.set_toplevel(Some(toplevel.upcast_ref::<wpe_platform::Toplevel>()));
        // Nothing of it takes the pointer until it says where it does.
        toplevel.set_input_region(&wpe_view, &[]);

        let ready = Rc::new(Cell::new(false));
        let ready_now = ready.clone();
        content.connect_script_message_received(Some("basicshell"), move |_, value| {
            let Ok(message) = serde_json::from_str::<Value>(&value.to_str()) else { return };
            if message["type"] == "ready" {
                ready_now.set(true);
            }
            received(message);
        });
        view.load_html(HTML, None);
        Some(Chrome { view, ready })
    }

    pub fn wpe_view(&self) -> Option<wpe_platform::View> {
        self.view.wpe_view()
    }

    /// Runs `script` in the interface, once it is there.
    pub fn run(&self, script: &str) {
        if !self.ready.get() {
            return;
        }
        self.view.evaluate_javascript(script, None, None, None::<&wpe_webkit::gio::Cancellable>, |result| {
            if let Err(e) = result {
                eprintln!("basicshell: the interface: {e}");
            }
        });
    }
}
