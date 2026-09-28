import AppKit
import WebKit

// How every page is set up.
enum Web {
    /// Appended to WebKit's user agent so pages see exactly what Safari sends.
    /// Without "Version/… Safari/…" some sites treat the browser as an
    /// unknown embedded view and serve a lesser page.
    static let userAgentName = "Version/\(safariVersion) Safari/605.1.15"

    private static var safariVersion: String {
        for path in ["/System/Cryptexes/App/System/Applications/Safari.app", "/Applications/Safari.app"] {
            if let version = Bundle(path: path)?.infoDictionary?["CFBundleShortVersionString"] as? String {
                return version
            }
        }
        return "27.0"
    }

    /// Schemes a tab loads itself. Anything else belongs to another app.
    static let inline: Set<String> = ["http", "https", "file", "about", "data", "blob"]

    /// The cookie jar every private tab shares: in memory only, never on
    /// disk, gone when the app quits. Shared, so that a site (Google behind a
    /// VPN, say) that wants proof you are a person asks once, not per tab.
    private static var privateStore: WKWebsiteDataStore?

    static func configuration(privately: Bool, store: WKWebsiteDataStore? = nil) -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        if privately, store == nil, privateStore == nil { privateStore = .nonPersistent() }
        config.websiteDataStore = store ?? (privately ? privateStore! : .default())
        // A page off screen is frozen: no script, no layout, no timers, but
        // everything it holds stays as it was (see Sleep.swift).
        config.preferences.inactiveSchedulingPolicy = .suspend
        config.applicationNameForUserAgent = userAgentName
        config.preferences.isElementFullscreenEnabled = true
        config.allowsAirPlayForMediaPlayback = true
        config.userContentController.addUserScript(Sleep.typingWatch)
        Geolocation.attach(to: config)
        Debug.attach(to: config)
        // Extensions see ordinary tabs only.
        if !privately, store == nil || store?.isPersistent == true {
            config.webExtensionController = Extensions.shared.controller
        }
        return config
    }
}

// MARK: - questions a page may ask

/// WebKit does nothing with alert(), confirm(), prompt() or a file input
/// unless somebody answers; each is the system's own sheet on the page's window.
enum Dialogs {
    static func alert(from frame: WKFrameInfo, saying message: String) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = frame.securityOrigin.host.isEmpty ? "This page says" : "\(frame.securityOrigin.host) says"
        alert.informativeText = message
        return alert
    }

    static func show(_ alert: NSAlert, over webView: WKWebView, answered: @escaping (NSApplication.ModalResponse) -> Void) {
        if let window = webView.window {
            alert.beginSheetModal(for: window, completionHandler: answered)
        } else {
            answered(alert.runModal())
        }
    }
}

extension Tab: WKUIDelegate {
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor () -> Void) {
        let alert = Dialogs.alert(from: frame, saying: message)
        alert.addButton(withTitle: "OK")
        Dialogs.show(alert, over: webView) { _ in completionHandler() }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor (Bool) -> Void) {
        let alert = Dialogs.alert(from: frame, saying: message)
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        Dialogs.show(alert, over: webView) { completionHandler($0 == .alertFirstButtonReturn) }
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor (String?) -> Void) {
        let alert = Dialogs.alert(from: frame, saying: prompt)
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: defaultText ?? "")
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        Dialogs.show(alert, over: webView) { completionHandler($0 == .alertFirstButtonReturn ? field.stringValue : nil) }
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        let finish: (NSApplication.ModalResponse) -> Void = { completionHandler($0 == .OK ? panel.urls : nil) }
        if let window = webView.window {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(panel.runModal())
        }
    }

    /// window.open and target=_blank: a new tab beside this one, built from
    /// the configuration WebKit hands over so the two pages can talk.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard let host else { return nil }
        let tab = Tab(configuration: configuration)
        let foreground = !(action.modifierFlags.contains(.command) && !action.modifierFlags.contains(.shift))
        host.insert(tab, after: self, select: foreground)
        return tab.webView
    }

    func webViewDidClose(_ webView: WKWebView) {
        host?.close(self)
    }
}
