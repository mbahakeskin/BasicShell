import AppKit
import CoreLocation
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
    /// WKUIDelegate's. Its Swift name has to match exactly (`initiatedByFrame`):
    /// a near miss compiles, and WebKit, finding no answer, denies every page.
    @objc func webView(_ webView: WKWebView, requestGeolocationPermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo, decisionHandler: @escaping @MainActor (WKPermissionDecision) -> Void) {
        let site = origin.host.isEmpty ? "this page" : origin.host
        if !isPrivate, let known = Permissions.shared.location[site] {
            return known ? LocationAccess.ensure { decisionHandler($0 ? .grant : .deny) } : decisionHandler(.deny)
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
            guard allowed else { return decisionHandler(.deny) }
            LocationAccess.ensure { decisionHandler($0 ? .grant : .deny) }
        }
    }
}

/// Whether macOS lets BasicShell use Location Services, asked the first time
/// a site you allowed wants your location. WebKit only waits for this answer
/// if the app asks; a page otherwise hangs on "locating".
final class LocationAccess: NSObject, CLLocationManagerDelegate {
    private static let shared = LocationAccess()
    private let manager = CLLocationManager()
    private var waiting: [(Bool) -> Void] = []

    override init() {
        super.init()
        manager.delegate = self
    }

    static func ensure(_ done: @escaping (Bool) -> Void) {
        shared.ensure(done)
    }

    private func ensure(_ done: @escaping (Bool) -> Void) {
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorized: done(true)
        case .notDetermined:
            waiting.append(done)
            if waiting.count == 1 { manager.requestWhenInUseAuthorization() }
        default:
            done(false)
            LocationAccess.explainDenied()
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard manager.authorizationStatus != .notDetermined else { return }
        let allowed = [.authorizedAlways, .authorized].contains(manager.authorizationStatus)
        let callbacks = waiting
        waiting = []
        callbacks.forEach { $0(allowed) }
        if !allowed, !callbacks.isEmpty { LocationAccess.explainDenied() }
    }

    private static func explainDenied() {
        let alert = NSAlert()
        alert.messageText = "BasicShell can't use your location"
        alert.informativeText = "Location Services are off for BasicShell. Turn them on in System Settings › Privacy & Security › Location Services, then reload the page."
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Not Now")
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices") {
            NSWorkspace.shared.open(url)
        }
    }
}
