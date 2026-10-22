//! Downloads (the macOS app's Downloads.swift, its first part): they go to
//! the Downloads folder under the name the site gave, never over a file
//! that is there, and the sidebar lists them with their progress.

use std::cell::{Cell, RefCell};
use std::path::{Path, PathBuf};
use std::rc::{Rc, Weak};

use serde_json::{json, Value};

#[derive(Clone, Copy, PartialEq)]
enum State {
    Running,
    Finished,
    Failed,
    Cancelled,
}

struct Item {
    id: u64,
    download: wpe_webkit::Download,
    name: RefCell<String>,
    file: RefCell<Option<PathBuf>>,
    state: Cell<State>,
    /// Why it stopped, in words, when it failed.
    problem: RefCell<Option<String>>,
    /// The site it came from.
    source: String,
}

pub struct Downloads {
    me: Weak<Downloads>,
    items: RefCell<Vec<Rc<Item>>>,
    next_id: Cell<u64>,
    changed: Box<dyn Fn()>,
}

impl Downloads {
    pub fn new(changed: impl Fn() + 'static) -> Rc<Downloads> {
        Rc::new_cyclic(|me| Downloads { me: me.clone(), items: RefCell::default(), next_id: Cell::new(1), changed: Box::new(changed) })
    }

    /// Downloads started in `session` are listed here.
    pub fn watch(&self, session: &wpe_webkit::NetworkSession) {
        let me = self.me.clone();
        session.connect_download_started(move |_, download| {
            if let Some(downloads) = me.upgrade() {
                downloads.adopt(download);
            }
        });
    }

    fn adopt(&self, download: &wpe_webkit::Download) {
        let id = self.next_id.get();
        self.next_id.set(id + 1);
        let source = download
            .request()
            .and_then(|r| r.uri())
            .and_then(|u| glib::Uri::parse(&u, glib::UriFlags::NONE).ok())
            .and_then(|u| u.host())
            .map(|h| h.to_string())
            .unwrap_or_default();
        let item = Rc::new(Item {
            id,
            download: download.clone(),
            name: RefCell::new(String::new()),
            file: RefCell::default(),
            state: Cell::new(State::Running),
            problem: RefCell::default(),
            source,
        });
        self.items.borrow_mut().insert(0, item.clone());

        let weak = Rc::downgrade(&item);
        download.connect_decide_destination(move |download, suggested| {
            let Some(item) = weak.upgrade() else { return false };
            let file = free(&downloads_folder(), suggested);
            *item.name.borrow_mut() = file.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
            download.set_destination(&file.to_string_lossy());
            *item.file.borrow_mut() = Some(file);
            true
        });
        let me = self.me.clone();
        let changed = move || {
            if let Some(downloads) = me.upgrade() {
                (downloads.changed)();
            }
        };
        let changed_now = changed.clone();
        download.connect_estimated_progress_notify(move |_| changed_now());
        let (weak, changed_now) = (Rc::downgrade(&item), changed.clone());
        download.connect_failed(move |_, error| {
            let Some(item) = weak.upgrade() else { return };
            if error.matches(wpe_webkit::DownloadError::CancelledByUser) {
                item.state.set(State::Cancelled);
            } else {
                item.state.set(State::Failed);
                *item.problem.borrow_mut() = Some(error.message().to_owned());
            }
            changed_now();
        });
        // Also after a failure, which has said so already.
        let weak = Rc::downgrade(&item);
        download.connect_finished(move |_| {
            let Some(item) = weak.upgrade() else { return };
            if item.state.get() == State::Running {
                item.state.set(State::Finished);
            }
            changed();
        });
        (self.changed)();
    }

    fn item(&self, id: u64) -> Option<Rc<Item>> {
        self.items.borrow().iter().find(|i| i.id == id).cloned()
    }

    pub fn cancel(&self, id: u64) {
        if let Some(item) = self.item(id).filter(|i| i.state.get() == State::Running) {
            item.download.cancel();
        }
    }

    /// The file, opened in the program the system has for it.
    pub fn open(&self, id: u64) {
        if let Some(file) = self.item(id).and_then(|i| i.file.borrow().clone()).filter(|f| f.exists()) {
            launch(&file);
        }
    }

    /// The folder it is in.
    pub fn show(&self, id: u64) {
        if let Some(folder) = self.item(id).and_then(|i| i.file.borrow().as_ref().and_then(|f| f.parent().map(Path::to_path_buf))) {
            launch(&folder);
        }
    }

    /// The finished, failed and cancelled ones off the list.
    pub fn clear(&self) {
        self.items.borrow_mut().retain(|i| i.state.get() == State::Running);
        (self.changed)();
    }

    /// The list, for the interface.
    pub fn state(&self) -> Value {
        let items: Vec<Value> = self
            .items
            .borrow()
            .iter()
            .map(|item| {
                let total = item.download.response().map(|r| r.content_length()).unwrap_or(0);
                let state = match item.state.get() {
                    State::Running => "running",
                    State::Finished => "finished",
                    State::Failed => "failed",
                    State::Cancelled => "cancelled",
                };
                let name = item.name.borrow().clone();
                json!({
                    "id": item.id,
                    "name": if name.is_empty() { "Download".to_owned() } else { name },
                    "state": state,
                    "received": item.download.received_data_length(),
                    "total": total,
                    "progress": item.download.estimated_progress(),
                    "source": item.source,
                    "problem": *item.problem.borrow(),
                    "missing": item.state.get() == State::Finished && item.file.borrow().as_ref().is_some_and(|f| !f.exists()),
                })
            })
            .collect();
        Value::Array(items)
    }
}

/// The system's Downloads folder; where it names none, ~/Downloads, made
/// if it isn't there.
fn downloads_folder() -> PathBuf {
    let folder = glib::user_special_dir(glib::UserDirectory::Downloads).unwrap_or_else(|| glib::home_dir().join("Downloads"));
    let _ = std::fs::create_dir_all(&folder);
    folder
}

/// A name in `folder` nothing has yet: the one given, else with " 2", " 3"
/// before its extension (the macOS app's Downloads.free).
fn free(folder: &Path, name: &str) -> PathBuf {
    let safe = name.replace(['/', ':'], "-");
    let safe = if safe.trim().is_empty() { "download".to_owned() } else { safe };
    let (base, ext) = match safe.rsplit_once('.') {
        Some((b, e)) if !b.is_empty() => (b.to_owned(), Some(e.to_owned())),
        _ => (safe.clone(), None),
    };
    let mut candidate = folder.join(&safe);
    let mut n = 2;
    while candidate.exists() {
        candidate = folder.join(match &ext {
            Some(ext) => format!("{base} {n}.{ext}"),
            None => format!("{base} {n}"),
        });
        n += 1;
    }
    candidate
}

/// Opens a file or folder in the program the system has for it.
fn launch(path: &Path) {
    let uri = glib::filename_to_uri(path, None).map(|u| u.to_string()).unwrap_or_default();
    if let Err(e) = wpe_webkit::gio::AppInfo::launch_default_for_uri(&uri, None::<&wpe_webkit::gio::AppLaunchContext>) {
        eprintln!("basicshell: couldn't open {}: {e}", path.display());
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn free_names() {
        let dir = std::env::temp_dir().join(format!("basicshell-test-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        assert_eq!(free(&dir, "a.zip"), dir.join("a.zip"));
        std::fs::write(dir.join("a.zip"), b"").unwrap();
        assert_eq!(free(&dir, "a.zip"), dir.join("a 2.zip"));
        std::fs::write(dir.join("a 2.zip"), b"").unwrap();
        assert_eq!(free(&dir, "a.zip"), dir.join("a 3.zip"));
        assert_eq!(free(&dir, "x/y:z"), dir.join("x-y-z"));
        assert_eq!(free(&dir, ".bashrc"), dir.join(".bashrc"));
        std::fs::remove_dir_all(&dir).unwrap();
    }
}
