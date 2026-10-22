//! A window of tabs with the sidebar over them: the macOS app's sidebar-only
//! layout (Settings › General › Layout there). No top bar; what it would
//! have is at the top of the sidebar, which comes out from the left edge,
//! or stays out, the page moved aside for it.

use std::cell::{Cell, OnceCell, RefCell};
use std::rc::{Rc, Weak};

use glib::prelude::*;
use serde_json::{json, Value};
use wpe_webkit::prelude::*;

use crate::address;
use crate::chrome::Chrome;
use crate::downloads::Downloads;
use crate::icon::{self, Icon};
use crate::platform::{Display, Rect, Toplevel};
use crate::state;

/// The gap between the sidebar and the window's edges (macOS's Metrics).
const INSET: i32 = 6;
const SIDEBAR: i32 = 250;
/// How close to the left edge the pointer brings the sidebar out.
const EDGE: f64 = 6.0;
/// How far past the sidebar the pointer can stray before it goes away.
const SLACK: f64 = 24.0;

// Keys, as XKB names them.
mod key {
    pub const TAB: u32 = 0xff09;
    pub const ISO_LEFT_TAB: u32 = 0xfe20;
    pub const LEFT: u32 = 0xff51;
    pub const RIGHT: u32 = 0xff53;
    pub const F5: u32 = 0xffc2;
    pub const F6: u32 = 0xffc3;
    pub const PERIOD: u32 = 0x2e;
    pub const BRACKET_LEFT: u32 = 0x5b;
    pub const BRACKET_RIGHT: u32 = 0x5d;
    pub const PLUS: u32 = 0x2b;
    pub const EQUAL: u32 = 0x3d;
    pub const MINUS: u32 = 0x2d;
    pub const KP_ADD: u32 = 0xffab;
    pub const KP_SUBTRACT: u32 = 0xffad;
}

pub struct Tab {
    id: u64,
    private: bool,
    /// The tab a link in it came from.
    opener: Cell<Option<u64>>,
    /// A tile above the list; pinned tabs come first.
    pinned: Cell<bool>,
    /// Its page; none while it hasn't been shown since it was brought back.
    view: RefCell<Option<wpe_webkit::WebView>>,
    /// What a tab brought back was, until it has its page.
    saved: RefCell<Saved>,
    icon: RefCell<Option<Icon>>,
}

#[derive(Default)]
struct Saved {
    uri: String,
    title: String,
    history: Option<Vec<u8>>,
}

impl Tab {
    fn view(&self) -> Option<wpe_webkit::WebView> {
        self.view.borrow().clone()
    }

    fn uri(&self) -> String {
        match self.view() {
            Some(view) => view.uri().map(|u| u.to_string()).unwrap_or_default(),
            None => self.saved.borrow().uri.clone(),
        }
    }

    fn title(&self) -> String {
        match self.view() {
            Some(view) => view.title().map(|t| t.to_string()).unwrap_or_default(),
            None => self.saved.borrow().title.clone(),
        }
    }

    fn name(&self) -> String {
        let title = self.title();
        if !title.is_empty() {
            return title;
        }
        let uri = self.uri();
        if !uri.is_empty() {
            address::pretty(&uri)
        } else if self.private {
            "Private Tab".to_owned()
        } else {
            "New Tab".to_owned()
        }
    }

    fn loading(&self) -> bool {
        self.view().is_some_and(|v| v.is_loading())
    }

    /// Its back-forward list, as WebKit writes it down.
    fn history(&self) -> Option<Vec<u8>> {
        match self.view() {
            Some(view) => view.session_state().and_then(|s| s.serialize()).map(|b| b.to_vec()),
            None => self.saved.borrow().history.clone(),
        }
    }
}

/// Where the pointer is over the page, for the sidebar.
#[derive(Clone, Copy, PartialEq)]
enum Zone {
    /// Not over a page: over the interface, or out of the window.
    Away,
    /// Against the left edge.
    Edge,
    /// Within reach of the sidebar.
    Near,
    Far,
}

pub struct Browser {
    me: Weak<Browser>,
    display: Display,
    toplevel: Toplevel,
    session: wpe_webkit::NetworkSession,
    private_session: OnceCell<wpe_webkit::NetworkSession>,
    settings: wpe_webkit::Settings,
    chrome: OnceCell<Chrome>,
    tabs: RefCell<Vec<Rc<Tab>>>,
    selected: RefCell<Option<Rc<Tab>>>,
    /// The tabs selected, the latest last: where closing one goes back to.
    recent: RefCell<Vec<u64>>,
    /// The addresses of tabs closed, the latest last.
    closed: RefCell<Vec<String>>,
    next_id: Cell<u64>,
    /// The sidebar stays out, the page beside it.
    pinned: Cell<bool>,
    /// What is kept in state.json, as last written.
    kept: Cell<state::State>,
    zone: Cell<Zone>,
    update_queued: Cell<bool>,
    /// The field asked for before the interface was there to show it.
    pending_ask: RefCell<Option<String>>,
    /// The session is written down this long after a change.
    saving: RefCell<Option<glib::SourceId>>,
    downloads: OnceCell<Rc<Downloads>>,
    /// The page's right-click menu on show: what each of its items does.
    page_menu: RefCell<Vec<(wpe_webkit::gio::Action, Option<glib::Variant>)>>,
    quit: Box<dyn Fn()>,
}

impl Browser {
    pub fn new(display: &Display, toplevel: &Toplevel, session: wpe_webkit::NetworkSession, quit: impl Fn() + 'static) -> Option<Rc<Browser>> {
        let settings = wpe_webkit::Settings::new();
        settings.set_enable_developer_extras(true);
        if let Some(data) = session.website_data_manager() {
            data.set_favicons_enabled(true);
        }
        let kept = state::load();
        // The size it had, before the compositor first says one.
        if let Some((w, h)) = kept.window {
            toplevel.resize(w, h);
        }
        if kept.maximized {
            toplevel.maximize();
        }
        let browser = Rc::new_cyclic(|me: &Weak<Browser>| Browser {
            me: me.clone(),
            display: display.clone(),
            toplevel: toplevel.clone(),
            session,
            private_session: OnceCell::new(),
            settings,
            chrome: OnceCell::new(),
            tabs: RefCell::default(),
            selected: RefCell::default(),
            recent: RefCell::default(),
            closed: RefCell::default(),
            next_id: Cell::new(1),
            pinned: Cell::new(kept.sidebar_pinned),
            kept: Cell::new(kept),
            zone: Cell::new(Zone::Away),
            update_queued: Cell::new(false),
            pending_ask: RefCell::default(),
            saving: RefCell::default(),
            page_menu: RefCell::default(),
            downloads: OnceCell::new(),
            quit: Box::new(quit),
        });

        let me = browser.me.clone();
        let downloads = Downloads::new(move || {
            if let Some(browser) = me.upgrade() {
                browser.update();
            }
        });
        downloads.watch(&browser.session);
        let _ = browser.downloads.set(downloads);

        let me = browser.me.clone();
        let chrome = Chrome::new(display, toplevel, move |message| {
            if let Some(browser) = me.upgrade() {
                browser.received(&message);
            }
        })?;
        let _ = browser.chrome.set(chrome);

        let me = browser.me.clone();
        toplevel.connect_resized(move |_, _| {
            if let Some(browser) = me.upgrade() {
                browser.layout();
                browser.keep_window();
            }
        });
        let me = browser.me.clone();
        toplevel.connect_pointer(move |view, at| {
            if let Some(browser) = me.upgrade() {
                browser.pointer(view, at);
            }
        });
        let me = browser.me.clone();
        toplevel.connect_key(move |key, modifiers, pressed| me.upgrade().is_some_and(|b| b.shortcut(key, modifiers, pressed)));
        browser.layout();
        Some(browser)
    }

    fn downloads(&self) -> &Rc<Downloads> {
        self.downloads.get().expect("the downloads are made with the browser")
    }

    fn chrome(&self) -> &Chrome {
        self.chrome.get().expect("the interface is made with the browser")
    }

    // MARK: - tabs

    fn make_view(&self, private: bool) -> wpe_webkit::WebView {
        let session = if private {
            self.private_session
                .get_or_init(|| {
                    let session = wpe_webkit::NetworkSession::new_ephemeral();
                    // Kept in memory only, as all of an ephemeral session is.
                    if let Some(data) = session.website_data_manager() {
                        data.set_favicons_enabled(true);
                    }
                    self.downloads().watch(&session);
                    session
                })
                .clone()
        } else {
            self.session.clone()
        };
        glib::Object::builder()
            .property("display", self.display.upcast_ref::<wpe_platform::Display>())
            .property("network-session", &session)
            .property("settings", &self.settings)
            .build()
    }

    fn new_tab(&self, private: bool, opener: Option<u64>, saved: Saved) -> Rc<Tab> {
        let id = self.next_id.get();
        self.next_id.set(id + 1);
        Rc::new(Tab {
            id,
            private,
            opener: Cell::new(opener),
            pinned: Cell::new(false),
            view: RefCell::default(),
            saved: RefCell::new(saved),
            icon: RefCell::default(),
        })
    }

    /// A new tab at `uri`, after the tab it came from (or at the end).
    pub fn open(&self, uri: &str, private: bool, opener: Option<u64>) -> Rc<Tab> {
        let view = self.make_view(private);
        let tab = self.adopt(view.clone(), private, opener, false);
        view.load_uri(uri);
        tab
    }

    /// A web view made for a tab, put in the window and the list.
    fn adopt(&self, view: wpe_webkit::WebView, private: bool, opener: Option<u64>, at_top: bool) -> Rc<Tab> {
        let tab = self.new_tab(private, opener, Saved::default());
        self.install(&tab, view);
        self.insert(&tab, at_top);
        self.select(Some(&tab));
        tab
    }

    /// The tabs of the last session, none of them loaded until shown.
    pub fn restore(&self, session: crate::session::Session) {
        let mut made: Vec<Rc<Tab>> = Vec::new();
        for saved in session.tabs {
            let opener = saved.opener.and_then(|i| made.get(i)).map(|t| t.id);
            let tab = self.new_tab(false, opener, Saved { uri: saved.uri, title: saved.title, history: saved.history });
            *tab.icon.borrow_mut() = saved.icon;
            tab.pinned.set(saved.pinned);
            self.tabs.borrow_mut().push(tab.clone());
            made.push(tab);
        }
        if let Some(tab) = session.selected.and_then(|i| made.get(i)) {
            self.select(Some(tab));
        }
        self.update();
    }

    /// A tab's page given its place in the window.
    fn install(&self, tab: &Rc<Tab>, view: wpe_webkit::WebView) {
        *tab.view.borrow_mut() = Some(view.clone());
        if let Some(wpe_view) = view.wpe_view() {
            wpe_view.set_toplevel(Some(self.toplevel.upcast_ref::<wpe_platform::Toplevel>()));
            // Hidden until selected; the interface stays over it.
            self.toplevel.set_visible(&wpe_view, false);
            self.toplevel.place(&wpe_view, self.page_place());
            if let Some(chrome) = self.chrome().wpe_view() {
                self.toplevel.raise(&chrome);
            }
        }
        self.watch(tab, &view);
    }

    /// A tab brought back, shown for the first time: its page, where it was.
    fn load(&self, tab: &Rc<Tab>) {
        let view = self.make_view(tab.private);
        self.install(tab, view.clone());
        let saved = std::mem::take(&mut *tab.saved.borrow_mut());
        if let Some(history) = saved.history {
            view.restore_session_state(&wpe_webkit::WebViewSessionState::new(&glib::Bytes::from_owned(history)));
            if let Some(item) = view.back_forward_list().and_then(|list| list.current_item()) {
                view.go_to_back_forward_list_item(&item);
                return;
            }
        }
        if !saved.uri.is_empty() {
            view.load_uri(&saved.uri);
        }
    }

    fn insert(&self, tab: &Rc<Tab>, at_top: bool) {
        let opener = tab.opener.get();
        let mut tabs = self.tabs.borrow_mut();
        let index = match opener.and_then(|o| tabs.iter().position(|t| t.id == o)) {
            // After the opener and whatever it already opened, in order.
            Some(at) => {
                let mut index = at + 1;
                while index < tabs.len() && tabs[index].opener.get() == opener {
                    index += 1;
                }
                index
            }
            // First of the tabs in the list; the pinned ones are tiles above it.
            None if at_top => tabs.iter().position(|t| !t.pinned.get()).unwrap_or(tabs.len()),
            None => tabs.len(),
        };
        tabs.insert(index, tab.clone());
    }

    /// Pinned tabs come first; a tab pinned goes to the end of them, one
    /// unpinned to the start of the rest.
    fn set_tab_pinned(&self, id: u64, pinned: bool) {
        {
            let mut tabs = self.tabs.borrow_mut();
            let Some(index) = tabs.iter().position(|t| t.id == id) else { return };
            if tabs[index].pinned.get() == pinned {
                return;
            }
            let tab = tabs.remove(index);
            tab.pinned.set(pinned);
            let boundary = tabs.iter().position(|t| !t.pinned.get()).unwrap_or(tabs.len());
            tabs.insert(boundary, tab);
        }
        self.update();
    }

    /// A tab dragged in the sidebar: put before `before` (none: at the end
    /// of its group), staying with the pinned tabs or the rest.
    fn reorder(&self, id: u64, before: Option<u64>) {
        {
            let mut tabs = self.tabs.borrow_mut();
            let Some(index) = tabs.iter().position(|t| t.id == id) else { return };
            let tab = tabs.remove(index);
            let pinned = tab.pinned.get();
            let at = match before.and_then(|b| tabs.iter().position(|t| t.id == b)) {
                Some(at) if tabs[at].pinned.get() == pinned => at,
                _ if pinned => tabs.iter().position(|t| !t.pinned.get()).unwrap_or(tabs.len()),
                _ => tabs.len(),
            };
            tabs.insert(at, tab);
        }
        self.update();
    }

    /// The tab's address on the clipboard.
    fn copy_address(&self, id: u64) {
        let Some(tab) = self.tab(id) else { return };
        let uri = tab.uri();
        if uri.is_empty() {
            return;
        }
        let display = self.display.upcast_ref::<wpe_platform::Display>();
        if let Some(clipboard) = wpe_platform::prelude::DisplayExt::clipboard(display) {
            let content = wpe_platform::ClipboardContent::new();
            content.set_text(&uri);
            wpe_platform::prelude::ClipboardExt::set_content(&clipboard, Some(&content));
        }
    }

    fn watch(&self, tab: &Rc<Tab>, view: &wpe_webkit::WebView) {
        let me = self.me.clone();
        let update = move |_: &wpe_webkit::WebView| {
            if let Some(browser) = me.upgrade() {
                browser.update();
            }
        };
        view.connect_uri_notify(update.clone());
        view.connect_title_notify(update.clone());
        view.connect_estimated_load_progress_notify(update.clone());
        view.connect_is_loading_notify(update.clone());
        let (me, id) = (self.me.clone(), tab.id);
        view.connect_load_changed(move |view, event| {
            update(view);
            // The page's icon, once it has loaded, and again a little later
            // for one that comes after.
            if event == wpe_webkit::LoadEvent::Finished {
                if let Some(browser) = me.upgrade() {
                    browser.fetch_icon(id);
                }
                let me = me.clone();
                glib::timeout_add_seconds_local_once(2, move || {
                    if let Some(browser) = me.upgrade() {
                        browser.fetch_icon(id);
                    }
                });
            }
        });

        // A link opened in a new tab or window: a tab after this one.
        let (me, id, private) = (self.me.clone(), tab.id, tab.private);
        view.connect_create(move |view, _| {
            // Its display, session and process are the related view's.
            let new: wpe_webkit::WebView = glib::Object::builder()
                .property("related-view", view)
                .property("settings", view.settings().as_ref())
                .build();
            if let Some(browser) = me.upgrade() {
                browser.adopt(new.clone(), private, Some(id), false);
            }
            new
        });
        // The page's right-click menu, drawn by the interface.
        let (me, id) = (self.me.clone(), tab.id);
        view.connect_context_menu(move |_, menu, _| me.upgrade().is_some_and(|b| b.show_page_menu(id, menu)));
        // The page closed itself (window.close()).
        let (me, id) = (self.me.clone(), tab.id);
        view.connect_close(move |_| {
            if let Some(browser) = me.upgrade() {
                browser.close(id);
            }
        });
    }

    /// WebKit's menu for where the page was right-clicked, shown by the
    /// interface; true: it is shown, and WebKit does what an item chosen
    /// says once its action is activated.
    fn show_page_menu(&self, id: u64, menu: &wpe_webkit::ContextMenu) -> bool {
        use wpe_webkit::gio::prelude::*;
        let mut actions = Vec::new();
        let mut items: Vec<Value> = Vec::new();
        for item in menu.items() {
            if item.is_separator() {
                if items.last().is_some_and(|i| i["separator"] != true) {
                    items.push(json!({ "separator": true }));
                }
                continue;
            }
            // Submenus (input methods, Unicode) are left out.
            if item.submenu().is_some() {
                continue;
            }
            let Some(action) = item.gaction() else { continue };
            let title = match item.stock_action() {
                // The Web Inspector has nowhere to show yet.
                wpe_webkit::ContextMenuAction::InspectElement => continue,
                // A new window here is a new tab.
                wpe_webkit::ContextMenuAction::OpenLinkInNewWindow => "Open Link in New Tab".to_owned(),
                // WebKit's titles carry GTK's mnemonic marks.
                _ => item.title().map(|t| t.replace('_', "")).unwrap_or_default(),
            };
            if title.is_empty() {
                continue;
            }
            items.push(json!({ "title": title, "enabled": action.is_enabled(), "index": actions.len() }));
            actions.push((action, item.gaction_target()));
        }
        if items.last().is_some_and(|i| i["separator"] == true) {
            items.pop();
        }
        if items.is_empty() || self.selected.borrow().as_ref().is_none_or(|t| t.id != id) {
            return false;
        }
        // Where it was asked for, in the window.
        let (x, y) = menu.position().unwrap_or((0, 0));
        let (left, top) = self.page_place().map_or((0, 0), |(l, t, ..)| (l, t));
        *self.page_menu.borrow_mut() = actions;
        self.chrome().run(&format!("BasicShell.pageMenu({}, {}, {})", x + left, y + top, Value::Array(items)));
        true
    }

    fn fetch_icon(&self, id: u64) {
        let Some(view) = self.tab(id).and_then(|t| t.view()) else { return };
        let me = self.me.clone();
        icon::fetch(&view, move |icon| {
            let Some(browser) = me.upgrade() else { return };
            let Some(tab) = browser.tab(id) else { return };
            let same = tab.icon.borrow().as_ref().is_some_and(|old| old.rgba == icon.rgba);
            if !same {
                *tab.icon.borrow_mut() = Some(icon);
                browser.send_icon(&tab);
                browser.save_soon();
            }
        });
    }

    /// Gives the interface a tab's icon (or tells it there is none).
    fn send_icon(&self, tab: &Tab) {
        let script = match tab.icon.borrow().as_ref() {
            Some(icon) => format!("BasicShell.icon({}, {}, {}, {})", tab.id, icon.width, icon.height, json!(glib::base64_encode(&icon.rgba).as_str())),
            None => format!("BasicShell.icon({}, 0, 0, null)", tab.id),
        };
        self.chrome().run(&script);
    }

    fn tab(&self, id: u64) -> Option<Rc<Tab>> {
        self.tabs.borrow().iter().find(|t| t.id == id).cloned()
    }

    fn select(&self, tab: Option<&Rc<Tab>>) {
        let previous = self.selected.replace(tab.cloned());
        if let Some(previous) = previous.as_ref().filter(|p| Some(p.id) != tab.map(|t| t.id)) {
            if let Some(view) = previous.view().and_then(|v| v.wpe_view()) {
                self.toplevel.set_visible(&view, false);
            }
        }
        if let Some(tab) = tab {
            if tab.view.borrow().is_none() {
                self.load(tab);
            }
            if let Some(view) = tab.view().and_then(|v| v.wpe_view()) {
                self.toplevel.set_visible(&view, true);
                self.toplevel.focus(&view);
            }
            let mut recent = self.recent.borrow_mut();
            recent.retain(|&id| id != tab.id);
            recent.push(tab.id);
        }
        self.update();
    }

    pub fn close(&self, id: u64) {
        let Some(index) = self.tabs.borrow().iter().position(|t| t.id == id) else { return };
        let tab = self.tabs.borrow_mut().remove(index);
        self.recent.borrow_mut().retain(|&r| r != id);
        let uri = tab.uri();
        if !uri.is_empty() && !tab.private {
            self.closed.borrow_mut().push(uri);
        }
        if self.selected.borrow().as_ref().is_some_and(|s| s.id == id) {
            // Back to the tab selected before it; else the one now in its place.
            let next = {
                let tabs = self.tabs.borrow();
                let recent = self.recent.borrow();
                recent
                    .iter()
                    .rev()
                    .find_map(|r| tabs.iter().find(|t| t.id == *r).cloned())
                    .or_else(|| tabs.get(index).or(tabs.last()).cloned())
            };
            self.selected.replace(None);
            self.select(next.as_ref());
            if next.is_none() {
                if let Some(chrome) = self.chrome().wpe_view() {
                    self.toplevel.focus(&chrome);
                }
            }
        }
        if let Some(view) = tab.view().and_then(|v| v.wpe_view()) {
            view.set_toplevel(None::<&wpe_platform::Toplevel>);
        }
        self.update();
    }

    fn reopen_closed(&self) {
        let uri = self.closed.borrow_mut().pop();
        if let Some(uri) = uri {
            self.open(&uri, false, None);
        }
    }

    /// The next or previous tab in the list, round.
    fn cycle(&self, step: isize) {
        let next = {
            let tabs = self.tabs.borrow();
            if tabs.is_empty() {
                return;
            }
            let at = self.selected.borrow().as_ref().and_then(|s| tabs.iter().position(|t| t.id == s.id)).unwrap_or(0) as isize;
            tabs[(at + step).rem_euclid(tabs.len() as isize) as usize].clone()
        };
        self.select(Some(&next));
    }

    /// Does `f` to the selected tab's page, if there is one.
    fn on_page(&self, f: impl FnOnce(&wpe_webkit::WebView)) {
        if let Some(view) = self.selected_view() {
            f(&view);
        }
    }

    fn selected_view(&self) -> Option<wpe_webkit::WebView> {
        self.selected.borrow().as_ref().and_then(|t| t.view())
    }

    // MARK: - layout

    /// Where the pages go: beside the sidebar while it stays out, else all
    /// the window.
    fn page_place(&self) -> Option<Rect> {
        if !self.pinned.get() {
            return None;
        }
        let (w, h) = self.toplevel.size();
        let x = INSET + SIDEBAR + INSET;
        Some((x, INSET, (w - x - INSET).max(1), (h - 2 * INSET).max(1)))
    }

    fn layout(&self) {
        let place = self.page_place();
        for tab in self.tabs.borrow().iter() {
            if let Some(view) = tab.view().and_then(|v| v.wpe_view()) {
                self.toplevel.place(&view, place);
            }
        }
    }

    fn set_pinned(&self, pinned: bool) {
        self.pinned.set(pinned);
        self.keep(state::State { sidebar_pinned: pinned, ..self.kept.get() });
        self.layout();
        self.update();
    }

    /// The window's size and whether it is maximized, kept for next time.
    fn keep_window(&self) {
        let maximized = self.toplevel.is_maximized();
        let mut kept = self.kept.get();
        kept.maximized = maximized;
        if !maximized && !self.toplevel.is_fullscreen() {
            kept.window = Some(self.toplevel.size());
        }
        self.keep(kept);
    }

    fn keep(&self, kept: state::State) {
        if kept != self.kept.replace(kept) {
            state::save(&kept);
        }
    }

    // MARK: - the interface

    /// Tells the interface how things are, once the current events are handled.
    fn update(&self) {
        self.save_soon();
        if self.update_queued.replace(true) {
            return;
        }
        let me = self.me.clone();
        glib::idle_add_local_once(move || {
            if let Some(browser) = me.upgrade() {
                browser.update_queued.set(false);
                browser.push_state();
            }
        });
    }

    /// The session written down two seconds after the last change.
    fn save_soon(&self) {
        if let Some(source) = self.saving.take() {
            source.remove();
        }
        let me = self.me.clone();
        let source = glib::timeout_add_seconds_local_once(2, move || {
            if let Some(browser) = me.upgrade() {
                browser.saving.take();
                browser.save();
            }
        });
        *self.saving.borrow_mut() = Some(source);
    }

    /// Writes the session down now: every tab but the private ones.
    pub fn save(&self) {
        let tabs = self.tabs.borrow();
        let kept: Vec<&Rc<Tab>> = tabs.iter().filter(|t| !t.private && !t.uri().is_empty()).collect();
        let position = |id: u64| kept.iter().position(|t| t.id == id);
        let session = crate::session::Session {
            tabs: kept
                .iter()
                .map(|t| crate::session::SavedTab {
                    uri: t.uri(),
                    title: t.title(),
                    history: t.history(),
                    icon: t.icon.borrow().clone(),
                    pinned: t.pinned.get(),
                    opener: t.opener.get().and_then(position),
                })
                .collect(),
            selected: self.selected.borrow().as_ref().and_then(|t| position(t.id)),
        };
        crate::session::save(&session);
    }

    fn push_state(&self) {
        let tabs = self.tabs.borrow();
        let selected = self.selected.borrow().clone();
        let others: Vec<Rc<Tab>> = tabs.iter().filter(|t| !t.pinned.get()).cloned().collect();
        let list: Vec<Value> = tabs
            .iter()
            .map(|t| {
                json!({
                    "id": t.id,
                    "name": t.name(),
                    "uri": t.uri(),
                    "loading": t.loading(),
                    "private": t.private,
                    "pinned": t.pinned.get(),
                    "depth": if t.pinned.get() { 0 } else { depth(t, &others, 2) },
                })
            })
            .collect();
        let page = selected.as_ref().map(|t| {
            let view = t.view();
            json!({
                "id": t.id,
                "uri": t.uri(),
                "private": t.private,
                "loading": t.loading(),
                "progress": view.as_ref().map_or(1.0, |v| v.estimated_load_progress()),
                "back": view.as_ref().is_some_and(|v| v.can_go_back()),
                "forward": view.as_ref().is_some_and(|v| v.can_go_forward()),
            })
        });
        let state = json!({ "tabs": list, "page": page, "pinned": self.pinned.get(), "downloads": self.downloads().state() });
        self.chrome().run(&format!("BasicShell.update({state})"));
        let title = selected.map(|t| t.name()).unwrap_or_else(|| "BasicShell".to_owned());
        self.toplevel.set_title(Some(&title));
    }

    fn received(&self, message: &Value) {
        let id = message["id"].as_u64();
        match message["type"].as_str().unwrap_or_default() {
            "ready" => {
                self.push_state();
                for tab in self.tabs.borrow().iter().filter(|t| t.icon.borrow().is_some()) {
                    self.send_icon(tab);
                }
                if let Some(what) = self.pending_ask.take() {
                    self.ask(&what);
                }
            }
            "regions" => {
                let rects: Vec<Rect> = message["rects"]
                    .as_array()
                    .into_iter()
                    .flatten()
                    .filter_map(|r| {
                        let n = |i: usize| r.get(i).and_then(Value::as_f64).map(|v| v.round() as i32);
                        Some((n(0)?, n(1)?, n(2)?, n(3)?))
                    })
                    .collect();
                if let Some(view) = self.chrome().wpe_view() {
                    self.toplevel.set_input_region(&view, &rects);
                }
            }
            // What was typed in the field in the middle of the window.
            "commit" => {
                let Some(uri) = message["text"].as_str().and_then(address::resolve) else { return };
                match message["ask"].as_str() {
                    Some("address") if self.selected.borrow().is_some() => {
                        if let Some(view) = self.selected_view() {
                            view.load_uri(&uri);
                        }
                        self.focus_page();
                    }
                    ask => {
                        let tab = self.open(&uri, ask == Some("private"), None);
                        if message["atTop"].as_bool() == Some(true) {
                            let mut tabs = self.tabs.borrow_mut();
                            tabs.retain(|t| t.id != tab.id);
                            tabs.insert(0, tab);
                        }
                        self.update();
                    }
                }
            }
            "select" => {
                if let Some(tab) = id.and_then(|id| self.tab(id)) {
                    self.select(Some(&tab));
                }
            }
            "close" => {
                if let Some(id) = id {
                    self.close(id);
                }
            }
            "back" => self.on_page(|v| v.go_back()),
            "forward" => self.on_page(|v| v.go_forward()),
            "reload" => self.on_page(|v| v.reload()),
            "stop" => self.on_page(|v| v.stop_loading()),
            "pin" => self.set_pinned(!self.pinned.get()),
            "pin-tab" => {
                if let Some(tab) = id.and_then(|id| self.tab(id)) {
                    self.set_tab_pinned(tab.id, !tab.pinned.get());
                }
            }
            "page-menu" => {
                use wpe_webkit::gio::prelude::*;
                let chosen = message["index"].as_u64().and_then(|i| self.page_menu.borrow().get(i as usize).cloned());
                self.page_menu.borrow_mut().clear();
                self.focus_page();
                if let Some((action, target)) = chosen {
                    action.activate(target.as_ref());
                }
            }
            "page-menu-closed" => {
                self.page_menu.borrow_mut().clear();
                self.focus_page();
            }
            "download-cancel" => id.into_iter().for_each(|id| self.downloads().cancel(id)),
            "download-open" => id.into_iter().for_each(|id| self.downloads().open(id)),
            "download-show" => id.into_iter().for_each(|id| self.downloads().show(id)),
            "downloads-clear" => self.downloads().clear(),
            "copy-address" => {
                if let Some(id) = id {
                    self.copy_address(id);
                }
            }
            "reorder" => {
                if let Some(id) = id {
                    self.reorder(id, message["before"].as_u64());
                }
            }
            "focus-page" => self.focus_page(),
            "focus-interface" => self.focus_chrome(),
            "move" => self.toplevel.start_move(),
            "maximize" => self.toplevel.toggle_maximized(),
            "minimize" => self.toplevel.minimize(),
            "quit" => (self.quit)(),
            _ => {}
        }
    }

    fn focus_page(&self) {
        if let Some(view) = self.selected_view().and_then(|v| v.wpe_view()) {
            self.toplevel.focus(&view);
        }
    }

    fn focus_chrome(&self) {
        if let Some(view) = self.chrome().wpe_view() {
            self.toplevel.focus(&view);
        }
    }

    /// `ask`, once the interface has loaded.
    pub fn ask_when_ready(&self, what: &str) {
        *self.pending_ask.borrow_mut() = Some(what.to_owned());
    }

    /// The field in the middle of the window, for "new", "private" or the
    /// tab's own "address".
    fn ask(&self, what: &str) {
        self.focus_chrome();
        self.chrome().run(&format!("BasicShell.ask({})", json!(what)));
    }

    /// The pointer over a page: the sidebar comes out at the left edge, and
    /// goes once the pointer is well past it.
    fn pointer(&self, view: &wpe_platform::View, at: Option<(f64, f64)>) {
        if self.chrome().wpe_view().as_ref() == Some(view) {
            return;
        }
        let zone = match at {
            None => Zone::Away,
            Some((x, _)) if x <= EDGE => Zone::Edge,
            Some((x, _)) if x <= (INSET + SIDEBAR) as f64 + SLACK => Zone::Near,
            Some(_) => Zone::Far,
        };
        if self.zone.replace(zone) == zone || self.pinned.get() {
            return;
        }
        let name = match zone {
            Zone::Away => return,
            Zone::Edge => "edge",
            Zone::Near => "near",
            Zone::Far => "far",
        };
        self.chrome().run(&format!("BasicShell.pointer({})", json!(name)));
    }

    /// The browser's own keys, wherever the keyboard is: true keeps the key
    /// from the view (its release too). Control where the macOS app has
    /// Command, as browsers on Linux have it.
    fn shortcut(&self, key: u32, modifiers: wpe_platform::Modifiers, pressed: bool) -> bool {
        use wpe_platform::Modifiers as M;
        let held = modifiers & (M::KEYBOARD_CONTROL | M::KEYBOARD_ALT | M::KEYBOARD_SHIFT | M::KEYBOARD_META);
        let ctrl = M::KEYBOARD_CONTROL;
        let ctrl_shift = M::KEYBOARD_CONTROL | M::KEYBOARD_SHIFT;
        let alt = M::KEYBOARD_ALT;
        let none = M::empty();
        // Letters as lower case, whatever Shift made of them.
        let key = if (0x41..=0x5a).contains(&key) { key + 0x20 } else { key };
        let action: Box<dyn Fn(&Self)> = match (held, key) {
            (h, 0x74) if h == ctrl => Box::new(|b| b.ask("new")),
            (h, 0x6e) if h == ctrl_shift => Box::new(|b| b.ask("private")),
            (h, 0x6c) if h == ctrl => Box::new(|b| b.ask("address")),
            (h, 0x64) if h == alt => Box::new(|b| b.ask("address")),
            (h, key::F6) if h == none => Box::new(|b| b.ask("address")),
            (h, 0x77) if h == ctrl => Box::new(|b| {
                let id = b.selected.borrow().as_ref().map(|t| t.id);
                if let Some(id) = id {
                    b.close(id);
                }
            }),
            (h, 0x74) if h == ctrl_shift => Box::new(|b| b.reopen_closed()),
            (h, 0x77) if h == ctrl_shift => Box::new(|b| (b.quit)()),
            (h, 0x71) if h == ctrl => Box::new(|b| (b.quit)()),
            (h, 0x72) if h == ctrl => Box::new(|b| b.on_page(|v| v.reload())),
            (h, key::F5) if h == none => Box::new(|b| b.on_page(|v| v.reload())),
            (h, key::LEFT) if h == alt => Box::new(|b| b.on_page(|v| v.go_back())),
            (h, key::RIGHT) if h == alt => Box::new(|b| b.on_page(|v| v.go_forward())),
            (h, key::BRACKET_LEFT) if h == ctrl => Box::new(|b| b.on_page(|v| v.go_back())),
            (h, key::BRACKET_RIGHT) if h == ctrl => Box::new(|b| b.on_page(|v| v.go_forward())),
            (h, key::TAB) if h == ctrl => Box::new(|b| b.cycle(1)),
            (h, key::TAB | key::ISO_LEFT_TAB) if h == ctrl_shift => Box::new(|b| b.cycle(-1)),
            (h, 0x31..=0x39) if h == ctrl => Box::new(move |b| {
                let tab = {
                    let tabs = b.tabs.borrow();
                    // Control-9 is the last tab, as in other browsers.
                    if key == 0x39 { tabs.last().cloned() } else { tabs.get((key - 0x31) as usize).cloned() }
                };
                if let Some(tab) = tab {
                    b.select(Some(&tab));
                }
            }),
            (h, 0x73) if h == ctrl_shift => Box::new(|b| b.set_pinned(!b.pinned.get())),
            (h, 0x30) if h == ctrl => Box::new(|b| b.on_page(|v| v.set_zoom_level(1.0))),
            (h, key::PLUS | key::EQUAL | key::KP_ADD) if h == ctrl || h == ctrl_shift => Box::new(|b| b.zoom(1)),
            (h, key::MINUS | key::KP_SUBTRACT) if h == ctrl => Box::new(|b| b.zoom(-1)),
            (h, key::PERIOD) if h == ctrl => Box::new(|b| b.on_page(|v| v.stop_loading())),
            _ => return false,
        };
        if pressed {
            action(self);
        }
        true
    }

    /// One step in or out, through the zoom levels Safari has.
    fn zoom(&self, step: i32) {
        const LEVELS: [f64; 13] = [0.5, 0.67, 0.75, 0.8, 0.9, 1.0, 1.1, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0];
        let Some(view) = self.selected_view() else { return };
        let now = view.zoom_level();
        let level = if step > 0 {
            LEVELS.iter().copied().find(|&l| l > now + 0.001).unwrap_or(LEVELS[LEVELS.len() - 1])
        } else {
            LEVELS.iter().rev().copied().find(|&l| l < now - 0.001).unwrap_or(LEVELS[0])
        };
        view.set_zoom_level(level);
    }
}

/// How far in a tab sits: one step under the tab a link in it came from, as
/// long as the two are together in the list; `limit` at most (the macOS
/// app's sidebar).
fn depth(tab: &Tab, tabs: &[Rc<Tab>], limit: usize) -> usize {
    let (Some(opener), Some(index)) = (tab.opener.get(), tabs.iter().position(|t| t.id == tab.id)) else { return 0 };
    if limit == 0 {
        return 0;
    }
    let descends = |candidate: &Tab| {
        let mut current = candidate.opener.get();
        for _ in 0..8 {
            match current {
                Some(id) if id == opener => return true,
                Some(id) => current = tabs.iter().find(|t| t.id == id).and_then(|t| t.opener.get()),
                None => return false,
            }
        }
        false
    };
    for candidate in tabs[..index].iter().rev() {
        if candidate.id == opener {
            return 1 + depth(candidate, tabs, limit - 1);
        }
        // Siblings and their own children may sit between a tab and its opener.
        if candidate.opener.get() != Some(opener) && !descends(candidate) {
            return 0;
        }
    }
    0
}
