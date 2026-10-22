//! What BasicShell keeps between runs, in `state.json` in its data folder
//! (the macOS app keeps the same in its user defaults).

use serde_json::{json, Value};

use crate::folder;

#[derive(Default, Clone, Copy, PartialEq)]
pub struct State {
    /// The sidebar stays out, the page beside it.
    pub sidebar_pinned: bool,
    /// The window's size when it was last neither maximized nor full screen
    /// (Wayland leaves where it goes to the compositor).
    pub window: Option<(i32, i32)>,
    pub maximized: bool,
}

fn path() -> std::path::PathBuf {
    folder::data_dir().join("state.json")
}

/// What was saved; nothing saved (or unreadable) is the defaults.
pub fn load() -> State {
    let Ok(text) = std::fs::read_to_string(path()) else { return State::default() };
    let Ok(value) = serde_json::from_str::<Value>(&text) else { return State::default() };
    let size = |v: &Value| v.as_i64().filter(|&n| (100..=20000).contains(&n)).map(|n| n as i32);
    State {
        sidebar_pinned: value["sidebarPinned"].as_bool().unwrap_or(false),
        window: size(&value["window"][0]).zip(size(&value["window"][1])),
        maximized: value["maximized"].as_bool().unwrap_or(false),
    }
}

pub fn save(state: &State) {
    let value = json!({
        "sidebarPinned": state.sidebar_pinned,
        "window": state.window.map(|(w, h)| [w, h]),
        "maximized": state.maximized,
    });
    let path = path();
    if let Some(dir) = path.parent() {
        let _ = std::fs::create_dir_all(dir);
    }
    // Written beside it and renamed over it: never half a file.
    let partial = path.with_extension("json.partial");
    if std::fs::write(&partial, value.to_string()).is_ok() {
        let _ = std::fs::rename(&partial, &path);
    }
}
