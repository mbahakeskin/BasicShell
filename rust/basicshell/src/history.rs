//! Every page an ordinary tab has shown, newest first, for finishing
//! addresses in the field in the middle of the window (the macOS app's
//! History.swift). Private tabs leave no trace here. Kept for 90 days in
//! history.json in the data folder, written five seconds after a change.

use std::cell::RefCell;
use std::collections::HashMap;
use std::rc::{Rc, Weak};

use serde_json::{json, Value};

use crate::folder;

const DAYS: i64 = 90;
const MOST: usize = 20000;
/// The same address again within this many seconds is the same visit.
const SAME_VISIT: i64 = 1800;

#[derive(Clone)]
pub struct Visit {
    pub uri: String,
    pub title: String,
    /// Seconds since 1970.
    pub date: i64,
}

pub struct History {
    me: Weak<History>,
    visits: RefCell<Vec<Visit>>,
    saving: RefCell<Option<glib::SourceId>>,
}

fn now() -> i64 {
    glib::real_time() / 1_000_000
}

fn path() -> std::path::PathBuf {
    folder::data_dir().join("history.json")
}

impl History {
    pub fn load() -> Rc<History> {
        let cutoff = now() - DAYS * 86400;
        let visits = std::fs::read_to_string(path())
            .ok()
            .and_then(|text| serde_json::from_str::<Value>(&text).ok())
            .and_then(|value| value.as_array().cloned())
            .unwrap_or_default()
            .iter()
            .filter_map(|v| {
                Some(Visit { uri: v["uri"].as_str()?.to_owned(), title: v["title"].as_str().unwrap_or_default().to_owned(), date: v["date"].as_i64()? })
            })
            .filter(|v| v.date > cutoff)
            .collect();
        Rc::new_cyclic(|me| History { me: me.clone(), visits: RefCell::new(visits), saving: RefCell::default() })
    }

    /// A page finished loading in an ordinary tab.
    pub fn record(&self, uri: &str, title: &str) {
        if !(uri.starts_with("http://") || uri.starts_with("https://")) {
            return;
        }
        {
            let mut visits = self.visits.borrow_mut();
            match visits.first_mut() {
                Some(first) if first.uri == uri && now() - first.date < SAME_VISIT => {
                    if !title.is_empty() {
                        first.title = title.to_owned();
                    }
                    first.date = now();
                }
                _ => {
                    visits.insert(0, Visit { uri: uri.to_owned(), title: title.to_owned(), date: now() });
                    visits.truncate(MOST);
                }
            }
        }
        self.save_soon();
    }

    /// The page's title arrived after it loaded.
    pub fn retitle(&self, uri: &str, title: &str) {
        if title.is_empty() {
            return;
        }
        let changed = {
            let mut visits = self.visits.borrow_mut();
            match visits.iter_mut().take(20).find(|v| v.uri == uri) {
                Some(visit) if visit.title != title => {
                    visit.title = title.to_owned();
                    true
                }
                _ => false,
            }
        };
        if changed {
            self.save_soon();
        }
    }

    /// The pages that match what was typed, best first: those whose site
    /// starts with it, then the most visited, then the latest. Every word
    /// typed has to be in the title or the address.
    pub fn suggestions(&self, typed: &str, limit: usize) -> Vec<Visit> {
        let query = typed.trim().to_lowercase();
        let words: Vec<&str> = query.split_whitespace().collect();
        if words.is_empty() {
            return Vec::new();
        }
        let mut counts: HashMap<&str, usize> = HashMap::new();
        let mut latest: Vec<&Visit> = Vec::new();
        let visits = self.visits.borrow();
        for visit in visits.iter() {
            let haystack = format!("{} {}", visit.title.to_lowercase(), visit.uri.to_lowercase());
            if !words.iter().all(|w| haystack.contains(w)) {
                continue;
            }
            let count = counts.entry(visit.uri.as_str()).or_insert(0);
            if *count == 0 {
                latest.push(visit);
            }
            *count += 1;
        }
        let starts = |v: &Visit| {
            let host = v.uri.split("://").nth(1).unwrap_or_default().to_lowercase();
            host.starts_with(&query) || host.starts_with(&format!("www.{query}"))
        };
        latest.sort_by(|a, b| {
            starts(b).cmp(&starts(a)).then(counts[b.uri.as_str()].cmp(&counts[a.uri.as_str()])).then(b.date.cmp(&a.date))
        });
        latest.into_iter().take(limit).cloned().collect()
    }

    fn save_soon(&self) {
        if let Some(source) = self.saving.take() {
            source.remove();
        }
        let me = self.me.clone();
        let source = glib::timeout_add_seconds_local_once(5, move || {
            if let Some(history) = me.upgrade() {
                history.saving.take();
                history.save();
            }
        });
        *self.saving.borrow_mut() = Some(source);
    }

    pub fn save(&self) {
        let value: Vec<Value> = self.visits.borrow().iter().map(|v| json!({ "uri": v.uri, "title": v.title, "date": v.date })).collect();
        let path = path();
        if let Some(dir) = path.parent() {
            let _ = std::fs::create_dir_all(dir);
        }
        let partial = path.with_extension("json.partial");
        if let Err(e) = std::fs::write(&partial, Value::Array(value).to_string()).and_then(|_| std::fs::rename(&partial, &path)) {
            eprintln!("basicshell: couldn't save the history: {e}");
        }
    }
}
