import AppKit
import Observation
import WebKit

/// What sites may know where you are. A page asks, you answer once for the
/// site if you like, and the answer is kept in the defaults (never for a
/// private tab). macOS then asks, once, whether BasicShell may use Location
/// Services at all.
@Observable
final class Permissions {
    static let shared = Permissions()

    /// Site to whether it may.
    private(set) var location: [String: Bool] = UserDefaults.standard.dictionary(forKey: "permissions.location") as? [String: Bool] ?? [:]

    func set(_ site: String, _ allowed: Bool?) {
        location[site] = allowed
        UserDefaults.standard.set(location, forKey: "permissions.location")
    }
}

extension Tab {
    func webView(_ webView: WKWebView, requestGeolocationPermissionFor origin: WKSecurityOrigin, initiatedBy frame: WKFrameInfo, decisionHandler: @escaping @MainActor (WKPermissionDecision) -> Void) {
        let site = origin.host.isEmpty ? "this page" : origin.host
        if !isPrivate, let known = Permissions.shared.location[site] {
            return decisionHandler(known ? .grant : .deny)
        }
        let alert = NSAlert()
        alert.messageText = "Allow \(site) to use your location?"
        alert.informativeText = frame.isMainFrame ? "" : "A part of the page from \(site) is asking, inside \(webView.url?.host() ?? "this page")."
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Don't Allow")
        if !isPrivate {
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = "Remember for this site"
        }
        Dialogs.show(alert, over: webView) { [weak self] answer in
            let allowed = answer == .alertFirstButtonReturn
            if self?.isPrivate == false, alert.suppressionButton?.state == .on { Permissions.shared.set(site, allowed) }
            decisionHandler(allowed ? .grant : .deny)
        }
    }
}
