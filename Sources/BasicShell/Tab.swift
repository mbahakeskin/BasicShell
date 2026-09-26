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
    /// A private tab's cookie jar, kept across an unload so it stays signed in.
    @ObservationIgnored private var store: WKWebsiteDataStore?
    /// Its back-forward list and scroll position, kept across an unload.
    @ObservationIgnored private var savedState: Any?
    @ObservationIgnored private var watching: [NSKeyValueObservation] = []

    /// A new, empty tab. A private one gets a cookie jar of its own that goes
    /// when the tab does.
    init(privately: Bool) {
        isPrivate = privately
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
        let config = configuration ?? Web.configuration(privately: isPrivate, store: store)
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
                }
            },
            web.observe(\.url) { [weak self] web, _ in
                MainActor.assumeIsolated {
                    guard let self, let url = web.url else { return }
                    if url.host() != self.url?.host() { self.icon = nil }
                    self.url = url
                    if !self.isPrivate { Session.touch() }
                }
            },
            web.observe(\.isLoading) { [weak self] web, _ in
                MainActor.assumeIsolated { self?.isLoading = web.isLoading }
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
        makeWebView().load(URLRequest(url: url))
    }

    /// Lets the page go but keeps what it takes to bring it back: its history,
    /// its scroll position and, for a private tab, its cookie jar.
    func unload() {
        guard let web = webView, !isUnloaded else { return }
        savedState = web.interactionState
        configuration = nil
        discard()
        isUnloaded = true
    }

    /// Lets the page go: its process ends and its private data, if any, with it.
    func discard() {
        watching = []
        isFrozen = false
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
        if let spot = scrollBack {
            scrollBack = nil
            // Twice: once now, once after late images and fonts have moved things.
            let script = "window.scrollTo(\(spot.x), \(spot.y))"
            webView.evaluateJavaScript(script) { _, _ in }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { webView.evaluateJavaScript(script) { _, _ in } }
        }
        host?.painted(self)
        Favicons.fetch(for: self)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
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
