//! What comes back at launch: the tabs, their history, which one was in
//! front, and which tab each was opened from (the macOS app's Session.swift).
//!
//! Kept in the data folder as session.json, written two seconds after
//! anything changes and again on quitting. Private tabs are never written
//! down. A tab brought back costs nothing until it is shown.

use serde_json::{json, Value};

use crate::folder;
use crate::icon::Icon;

pub struct SavedTab {
    pub uri: String,
    pub title: String,
    /// WebKit's session state: the tab's back-forward list.
    pub history: Option<Vec<u8>>,
    /// Its icon, for the sidebar before the page loads.
    pub icon: Option<Icon>,
    /// The index of the tab it was opened from.
    pub opener: Option<usize>,
}

#[derive(Default)]
pub struct Session {
    pub tabs: Vec<SavedTab>,
    pub selected: Option<usize>,
}

fn path() -> std::path::PathBuf {
    folder::data_dir().join("session.json")
}

/// The last session; nothing saved (or unreadable) is none.
pub fn load() -> Session {
    let Ok(text) = std::fs::read_to_string(path()) else { return Session::default() };
    let Ok(value) = serde_json::from_str::<Value>(&text) else { return Session::default() };
    let index = |v: &Value| v.as_u64().map(|i| i as usize);
    let tabs = value["tabs"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|tab| {
            Some(SavedTab {
                uri: tab["uri"].as_str()?.to_owned(),
                title: tab["title"].as_str().unwrap_or_default().to_owned(),
                history: tab["history"].as_str().map(|b| glib::base64_decode(b).to_vec()),
                icon: icon_from(&tab["icon"]),
                opener: index(&tab["opener"]),
            })
        })
        .collect::<Vec<_>>();
    let selected = index(&value["selected"]).filter(|&i| i < tabs.len());
    Session { tabs, selected }
}

fn icon_from(value: &Value) -> Option<Icon> {
    let width = value["width"].as_i64()? as i32;
    let height = value["height"].as_i64()? as i32;
    let rgba = glib::base64_decode(value["rgba"].as_str()?).to_vec();
    (width > 0 && height > 0 && rgba.len() == (width * height * 4) as usize).then_some(Icon { width, height, rgba })
}

pub fn save(session: &Session) {
    let tabs: Vec<Value> = session
        .tabs
        .iter()
        .map(|tab| {
            json!({
                "uri": tab.uri,
                "title": tab.title,
                "history": tab.history.as_deref().map(|h| glib::base64_encode(h).to_string()),
                "icon": tab.icon.as_ref().map(|i| json!({ "width": i.width, "height": i.height, "rgba": glib::base64_encode(&i.rgba).as_str() })),
                "opener": tab.opener,
            })
        })
        .collect();
    let value = json!({ "tabs": tabs, "selected": session.selected });
    let path = path();
    if let Some(dir) = path.parent() {
        let _ = std::fs::create_dir_all(dir);
    }
    // Written beside it and renamed over it: never half a file.
    let partial = path.with_extension("json.partial");
    match std::fs::write(&partial, value.to_string()).and_then(|_| std::fs::rename(&partial, &path)) {
        Ok(()) => {}
        Err(e) => eprintln!("basicshell: couldn't save the session: {e}"),
    }
}
