import AppKit
import Observation
import WebKit

/// What a tab needs from the window it lives in.
protocol TabHost: AnyObject {
    func insert(_ tab: Tab, after opener: Tab?, select: Bool)
    func close(_ tab: Tab)
    func open(_ url: URL, from tab: Tab?, select: Bool)
    func retitled(_ tab: Tab)
    func painted(_ tab: Tab)
}

/// One page. Its web view is built only when first needed, so a tab that has
/// never been looked at costs no web content process.
@Observable
final class Tab: NSObject, Identifiable {
    let id = UUID()
    let isPrivate: Bool

    @ObservationIgnored weak var host: TabHost?
    /// The tab a link in which opened this one.
    @ObservationIgnored weak var opener: Tab?

    private(set) var title = ""
    private(set) var url: URL?
    private(set) var isLoading = false
    private(set) var progress = 0.0
    private(set) var canGoBack = false
    private(set) var canGoForward = false
    var icon: NSImage?
    var pinned = false
    /// Its page was let go to give the memory back (see Sleep.swift); it
    /// comes back where it was when the tab is next shown.
    private(set) var isUnloaded = false

    /// Location answers given in this tab, by site (see Permissions.swift).
    @ObservationIgnored var locationAnswers: [String: Bool] = [:]
    /// Its page is suspended (see Freeze in Sleep.swift).
    @ObservationIgnored var isFrozen = false
    /// When it was last on screen.
    @ObservationIgnored var lastSeen = Date()
    /// Whether the page, when it was last on screen, held something typed and not sent.
    @ObservationIgnored var hasTypedInput = false
    /// What the page looked like when it was last on screen, as a JPEG, shown
    /// while an unloaded tab loads again.
    @ObservationIgnored var snapshot: Data?
    /// Where the page was scrolled to when it was last on screen. WebKit's
    /// saved state doesn't carry it for the page being shown, so an unloaded
    /// tab scrolls back here itself once it has loaded.
    @ObservationIgnored var scrolled: CGPoint?
    @ObservationIgnored private var scrollBack: CGPoint?

    @ObservationIgnored private(set) var webView: WKWebView?
    @ObservationIgnored private var configuration: WKWebViewConfiguration?
    /// The cookie jar it was made with, kept across an unload.
    @ObservationIgnored private var store: WKWebsiteDataStore?
    /// Its back-forward list and scroll position, kept across an unload.
    @ObservationIgnored private var savedState: Any?
    @ObservationIgnored private var watching: [NSKeyValueObservation] = []
    /// When its web process last ended, for telling a crash loop apart.
    @ObservationIgnored private var crashes: [Date] = []

    /// A new, empty tab. A private one shares the private tabs' cookie jar,
    /// which lives in memory and goes when the app quits (see Web.swift).
    /// Given the address it is about to open, its view is made for that
    /// address: an extension's page needs a view of that extension's kind.
    init(privately: Bool, opening address: URL? = nil) {
        isPrivate = privately
        url = address
        super.init()
    }

    /// A tab a page asked for, sharing that page's configuration.
    init(configuration: WKWebViewConfiguration) {
        isPrivate = !configuration.websiteDataStore.isPersistent
        self.configuration = configuration
        super.init()
        _ = makeWebView()
    }

    /// What the sidebar and the top bar call it.
    var name: String {
        if !title.isEmpty { return title }
        if let url { return Address.pretty(url) }
        return isPrivate ? "Private Tab" : "New Tab"
    }

    // MARK: - the web view

    func makeWebView() -> WKWebView {
        if let webView { return webView }
        // An extension's page is shown only by a view made the way that
        // extension's own are; any other page, the usual configuration.
        let config = configuration
            ?? (isPrivate ? nil : url.flatMap { Extensions.shared.configuration(for: $0) })
            ?? Web.configuration(privately: isPrivate, store: store)
        store = config.websiteDataStore
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = self
        web.uiDelegate = self
        web.allowsBackForwardNavigationGestures = true
        web.allowsMagnification = true
        web.isInspectable = true
        webView = web
        watch(web)
        if let savedState {
            web.interactionState = savedState
            self.savedState = nil
            scrollBack = scrolled
        } else if isUnloaded, let url {
            // Restored without its history: the page it was on, at least.
            web.load(URLRequest(url: url))
            scrollBack = scrolled
        }
        isUnloaded = false
        return web
    }

    /// Its back-forward list, to be written down (see Session.swift).
    var historyState: Data? {
        (webView?.interactionState ?? savedState) as? Data
    }

    /// Made from a saved session: unloaded, with what it takes to come back.
    func restore(url: URL?, title: String, state: Data?) {
        self.url = url
        self.title = title
        savedState = state
        isUnloaded = true
    }

    private func watch(_ web: WKWebView) {
        watching = [
            web.observe(\.title) { [weak self] web, _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.title = web.title ?? ""
                    self.host?.retitled(self)
                    Extensions.shared.changed(self, .title)
                    if !self.isPrivate, let url = web.url { History.shared.retitle(url, self.title) }
                }
            },
            web.observe(\.url) { [weak self] web, _ in
                MainActor.assumeIsolated {
                    guard let self, let url = web.url else { return }
                    if url.host() != self.url?.host() { self.icon = nil }
                    self.url = url
                    if !self.isPrivate { Session.touch() }
                    Extensions.shared.changed(self, .URL)
                }
            },
            web.observe(\.isLoading) { [weak self] web, _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.isLoading = web.isLoading
                    Extensions.shared.changed(self, .loading)
                }
            },
            web.observe(\.estimatedProgress) { [weak self] web, _ in
                MainActor.assumeIsolated { self?.progress = web.estimatedProgress }
            },
            web.observe(\.canGoBack) { [weak self] web, _ in
                MainActor.assumeIsolated { self?.canGoBack = web.canGoBack }
            },
            web.observe(\.canGoForward) { [weak self] web, _ in
                MainActor.assumeIsolated { self?.canGoForward = web.canGoForward }
            },
        ]
    }

    func load(_ url: URL) {
        self.url = url
        let web = makeWebView()
        if url.isFileURL {
            // A file may read only what sits beside it.
            web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            web.load(URLRequest(url: url))
        }
    }

    /// Lets the page go but keeps what it takes to bring it back: its history,
    /// its scroll position and its cookie jar.
    func unload() {
        Freeze.thaw(self)
        guard let web = webView, !isUnloaded else { return }
        savedState = web.interactionState
        configuration = nil
        discard()
        isUnloaded = true
    }

    /// Lets the page go: its process ends.
    func discard() {
        watching = []
        // A frozen view throws on stopLoading (see Freeze).
        Freeze.thaw(self)
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView?.uiDelegate = nil
        webView?.removeFromSuperview()
        webView = nil
    }
}

// MARK: - navigation

extension Tab: WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, preferences: WKWebpagePreferences, decisionHandler: @escaping @MainActor (WKNavigationActionPolicy, WKWebpagePreferences) -> Void) {
        if action.shouldPerformDownload {
            decisionHandler(.download, preferences)
            return
        }
        guard let url = action.request.url else {
            decisionHandler(.allow, preferences)
            return
        }
        let scheme = url.scheme?.lowercased() ?? ""
        // An extension's own pages: its inline menu in a page's frame, its
        // popup popped out into a tab. WebKit's extension engine decides what
        // a page may load from it; a private tab has no extensions.
        if scheme == Extensions.scheme {
            decisionHandler(webView.configuration.webExtensionController == nil ? .cancel : .allow, preferences)
            return
        }
        guard Web.inline.contains(scheme) else {
            decisionHandler(.cancel, preferences)
            handOff(url, action: action)
            return
        }
        // ⌘-click opens beside this tab and stays here; ⇧⌘-click goes with it.
        if action.navigationType == .linkActivated, ["http", "https"].contains(scheme),
           action.modifierFlags.contains(.command) {
            decisionHandler(.cancel, preferences)
            host?.open(url, from: self, select: action.modifierFlags.contains(.shift))
            return
        }
        if action.targetFrame?.isMainFrame ?? true {
            Shield.shared.tune(webView.configuration.userContentController, for: url.host())
        }
        decisionHandler(.allow, preferences)
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse, decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void) {
        let attachment = (response.response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Content-Disposition")?.lowercased().hasPrefix("attachment") ?? false
        decisionHandler(response.canShowMIMEType && !attachment ? .allow : .download)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        Downloads.shared.adopt(download)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        Downloads.shared.adopt(download)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // A frozen page still reports a load that finished as it froze; no
        // script may reach it until it is woken (see Freeze).
        if !isFrozen, let spot = scrollBack {
            scrollBack = nil
            // Twice: once now, once after late images and fonts have moved things.
            let script = "window.scrollTo(\(spot.x), \(spot.y))"
            webView.evaluateJavaScript(script) { _, _ in }
            // The tab may have been left, and frozen, by then (see Freeze).
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                guard let self, self.webView === webView, !self.isFrozen else { return }
                webView.evaluateJavaScript(script) { _, _ in }
            }
        }
        host?.painted(self)
        if !isPrivate, let url = webView.url { History.shared.record(url, title: webView.title ?? "") }
        Favicons.fetch(for: self)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        // macOS may end a frozen page's process; wake the view before reloading it.
        Freeze.thaw(self)
        // A page whose process keeps dying is not reloaded into another
        // crash: after the third in a minute it is left for a manual reload.
        let now = Date()
        crashes = crashes.filter { now.timeIntervalSince($0) < 60 } + [now]
        Debug.log("tab", "\(name): its web process ended (\(crashes.count) in the last minute)")
        guard crashes.count < 3 else {
            (host as? BrowserWindow)?.say("\(name) keeps crashing; reload it to try again")
            return
        }
        webView.reload()
    }

    /// An address for another app (mail, a call, a meeting link). Only a
    /// click, or the page itself, may ask, and the other app opens only once
    /// you say so, except a mail or phone link you just clicked.
    private func handOff(_ url: URL, action: WKNavigationAction) {
        let clicked = action.navigationType == .linkActivated
        guard clicked || action.targetFrame?.isMainFrame ?? true,
              let app = NSWorkspace.shared.urlForApplication(toOpen: url)
        else { return }
        let scheme = url.scheme?.lowercased() ?? ""
        if clicked, ["mailto", "tel"].contains(scheme) {
            NSWorkspace.shared.open(url)
            return
        }
        let alert = NSAlert()
        let name = FileManager.default.displayName(atPath: app.path)
        alert.messageText = "Open \(name)?"
        alert.informativeText = "\(url.host() ?? "This page") wants to open \(name)."
        alert.addButton(withTitle: "Open")
        alert.addButton(withTitle: "Cancel")
        guard let web = webView else { return }
        Dialogs.show(alert, over: web) { answer in
            if answer == .alertFirstButtonReturn { NSWorkspace.shared.open(url) }
        }
    }
}
