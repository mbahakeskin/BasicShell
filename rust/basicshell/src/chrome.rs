//! BasicShell's interface: `ui/chrome.html` in a view of its own over the
//! page, transparent, taking the pointer only where something of it shows.
//! It tells BasicShell what was asked for through the "basicshell" script
//! message handler; BasicShell tells it how the page is through
//! `window.BasicShell`.

use std::cell::Cell;
use std::rc::Rc;

use glib::prelude::*;
use serde_json::{json, Value};
use wpe_webkit::prelude::*;

use crate::address;
use crate::platform::{Display, Toplevel};

const HTML: &str = include_str!("../ui/chrome.html");

// Keys, as XKB names them.
const KEY_D: u32 = 0x0064;
const KEY_L: u32 = 0x006c;
const KEY_R: u32 = 0x0072;
const KEY_LEFT: u32 = 0xff51;
const KEY_RIGHT: u32 = 0xff53;
const KEY_F5: u32 = 0xffc2;
const KEY_F6: u32 = 0xffc3;

/// How close to the top of the page the pointer brings the bar out.
const EDGE: f64 = 3.0;

pub struct Chrome {
    view: wpe_webkit::WebView,
    page: wpe_webkit::WebView,
    toplevel: Toplevel,
    ready: Cell<bool>,
    pointer: Cell<Pointer>,
}

/// Where the pointer is, as far as the page can tell.
#[derive(Clone, Copy, PartialEq)]
enum Pointer {
    /// Not on the page: on the interface, or out of the window.
    Away,
    /// At the page's top edge, where the bar comes out.
    Edge,
    Page,
}

impl Chrome {
    /// The interface over `page`, which is already in `toplevel`.
    pub fn new(display: &Display, toplevel: &Toplevel, page: &wpe_webkit::WebView) -> Option<Rc<Chrome>> {
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
        view.wpe_view()?.set_toplevel(Some(toplevel.upcast_ref::<wpe_platform::Toplevel>()));

        let chrome = Rc::new(Chrome {
            view,
            page: page.clone(),
            toplevel: toplevel.clone(),
            ready: Cell::new(false),
            pointer: Cell::new(Pointer::Away),
        });

        let weak = Rc::downgrade(&chrome);
        content.connect_script_message_received(Some("basicshell"), move |_, value| {
            if let Some(chrome) = weak.upgrade() {
                chrome.received(&value.to_str());
            }
        });

        let weak = Rc::downgrade(&chrome);
        let update = move |_: &wpe_webkit::WebView| {
            if let Some(chrome) = weak.upgrade() {
                chrome.update();
            }
        };
        page.connect_uri_notify(update.clone());
        page.connect_title_notify(update.clone());
        page.connect_estimated_load_progress_notify(update.clone());
        page.connect_is_loading_notify(update.clone());
        page.connect_load_changed(move |page, _| update(page));

        let weak = Rc::downgrade(&chrome);
        page.wpe_view()?.connect_has_focus_notify(move |view| {
            if let Some(chrome) = weak.upgrade().filter(|_| view.has_focus()) {
                chrome.run("BasicShell.pageFocused()");
            }
        });

        let weak = Rc::downgrade(&chrome);
        toplevel.connect_page_pointer(move |at| {
            let Some(chrome) = weak.upgrade() else { return };
            let pointer = match at {
                None => Pointer::Away,
                Some((_, y)) if y <= EDGE => Pointer::Edge,
                Some(_) => Pointer::Page,
            };
            if chrome.pointer.replace(pointer) != pointer {
                match pointer {
                    Pointer::Edge => chrome.run("BasicShell.reveal()"),
                    // Off the bar (WebKit doesn't say when the pointer leaves a view).
                    Pointer::Page => chrome.run("BasicShell.pointerOnPage()"),
                    Pointer::Away => {}
                }
            }
        });

        let weak = Rc::downgrade(&chrome);
        toplevel.connect_key(move |key, modifiers, pressed| {
            weak.upgrade().is_some_and(|chrome| chrome.shortcut(key, modifiers, pressed))
        });

        chrome.view.load_html(HTML, None);
        Some(chrome)
    }

    fn received(&self, message: &str) {
        let Ok(message) = serde_json::from_str::<Value>(message) else { return };
        match message["type"].as_str().unwrap_or_default() {
            "ready" => {
                self.ready.set(true);
                self.update();
            }
            "regions" => {
                let rects: Vec<(i32, i32, i32, i32)> = message["rects"]
                    .as_array()
                    .into_iter()
                    .flatten()
                    .filter_map(|r| {
                        let n = |i: usize| r.get(i).and_then(Value::as_f64).map(|v| v.round() as i32);
                        Some((n(0)?, n(1)?, n(2)?, n(3)?))
                    })
                    .collect();
                if let Some(view) = self.view.wpe_view() {
                    self.toplevel.set_input_region(&view, &rects);
                }
            }
            "navigate" => {
                if let Some(address) = message["text"].as_str().and_then(address::resolve) {
                    self.page.load_uri(&address);
                }
            }
            "back" => self.page.go_back(),
            "forward" => self.page.go_forward(),
            "reload" => self.page.reload(),
            "stop" => self.page.stop_loading(),
            "focus-page" => self.focus_page(),
            _ => {}
        }
    }

    /// Tells the interface how the page is.
    fn update(&self) {
        if !self.ready.get() {
            return;
        }
        let page = &self.page;
        let state = json!({
            "uri": page.uri().as_deref().unwrap_or(""),
            "title": page.title().as_deref().unwrap_or(""),
            "progress": page.estimated_load_progress(),
            "loading": page.is_loading(),
            "back": page.can_go_back(),
            "forward": page.can_go_forward(),
        });
        self.run(&format!("BasicShell.update({state})"));
    }

    /// The browser's own keys, wherever the keyboard is: true keeps the key
    /// from the view (its release too).
    fn shortcut(&self, key: u32, modifiers: wpe_platform::Modifiers, pressed: bool) -> bool {
        use wpe_platform::Modifiers as M;
        let held = modifiers & (M::KEYBOARD_CONTROL | M::KEYBOARD_ALT | M::KEYBOARD_SHIFT | M::KEYBOARD_META);
        let key = if (0x41..=0x5a).contains(&key) { key + 0x20 } else { key };
        let action: fn(&Self) = match (held, key) {
            (M::KEYBOARD_CONTROL, KEY_L) | (M::KEYBOARD_ALT, KEY_D) => Self::edit_address,
            (h, KEY_F6) if h.is_empty() => Self::edit_address,
            (M::KEYBOARD_ALT, KEY_LEFT) => |c| c.page.go_back(),
            (M::KEYBOARD_ALT, KEY_RIGHT) => |c| c.page.go_forward(),
            (M::KEYBOARD_CONTROL, KEY_R) => |c| c.page.reload(),
            (h, KEY_F5) if h.is_empty() => |c| c.page.reload(),
            _ => return false,
        };
        if pressed {
            action(self);
        }
        true
    }

    fn edit_address(&self) {
        if let Some(view) = self.view.wpe_view() {
            self.toplevel.focus(&view);
        }
        self.run("BasicShell.editAddress()");
    }

    fn focus_page(&self) {
        if let Some(view) = self.page.wpe_view() {
            self.toplevel.focus(&view);
        }
    }

    fn run(&self, script: &str) {
        self.view.evaluate_javascript(script, None, None, None::<&wpe_webkit::gio::Cancellable>, |result| {
            if let Err(e) = result {
                eprintln!("basicshell: the interface: {e}");
            }
        });
    }
}
