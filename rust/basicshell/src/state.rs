//! What BasicShell keeps between runs, in `state.json` in its data folder
//! (the macOS app keeps the same in its user defaults).

use serde_json::{json, Value};

use crate::folder;

#[derive(Default)]
pub struct State {
    /// The sidebar stays out, the page beside it.
    pub sidebar_pinned: bool,
}

fn path() -> std::path::PathBuf {
    folder::data_dir().join("state.json")
}

/// What was saved; nothing saved (or unreadable) is the defaults.
pub fn load() -> State {
    let Ok(text) = std::fs::read_to_string(path()) else { return State::default() };
    let Ok(value) = serde_json::from_str::<Value>(&text) else { return State::default() };
    State { sidebar_pinned: value["sidebarPinned"].as_bool().unwrap_or(false) }
}

pub fn save(state: &State) {
    let value = json!({ "sidebarPinned": state.sidebar_pinned });
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
