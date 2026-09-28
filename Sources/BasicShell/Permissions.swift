import AppKit
import CoreLocation
import Observation
import WebKit

// Where you are, for the sites you allow.
//
// A page asks, you answer (once for the site if you like, kept in the
// defaults, never for a private tab), and macOS is asked, once, whether
// BasicShell may use Location Services at all.
//
// The position itself comes from CoreLocation through a bridge of our own
// (Geolocation, below), not from WebKit: measured on macOS 27, WebKit asks
// the page's permission and then never delivers a position to this app, while
// CoreLocation answers it within seconds. So navigator.geolocation is
// replaced, before any page script runs, with the same three calls answered
// here. Which site is asking comes from WebKit (the frame's security origin),
// never from the page.
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
    /// WKUIDelegate's, for a page that reached WebKit's own geolocation
    /// despite the bridge. Its Swift name has to match exactly
    /// (`initiatedByFrame`): a near miss compiles, and WebKit, finding no
    /// answer, denies every page.
    @objc func webView(_ webView: WKWebView, requestGeolocationPermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo, decisionHandler: @escaping @MainActor (WKPermissionDecision) -> Void) {
        decideLocation(origin: origin, frame: frame, in: webView) { decisionHandler($0 ? .grant : .deny) }
    }

    /// Whether this site may have your location: remembered, answered
    /// earlier in this tab, or asked now; then macOS's own permission.
    func decideLocation(origin: WKSecurityOrigin, frame: WKFrameInfo, in webView: WKWebView, _ done: @escaping (Bool) -> Void) {
        let site = origin.host.isEmpty ? "this page" : origin.host
        Debug.log("location", "\(site) asks (\(frame.isMainFrame ? "main frame" : "frame inside \(webView.url?.host() ?? "?")")); macOS: \(CLLocationStatus.describe())")
        let then: (Bool) -> Void = { allowed in
            guard allowed else {
                Debug.log("location", "\(site): denied")
                return done(false)
            }
            LocationAccess.ensure { granted in
                Debug.log("location", "\(site): \(granted ? "granted" : "denied by macOS")")
                done(granted)
            }
        }
        if !isPrivate, let known = Permissions.shared.location[site] {
            Debug.log("location", "\(site): remembered \(known ? "allow" : "deny")")
            return then(known)
        }
        if let answered = locationAnswers[site] { return then(answered) }
        let alert = NSAlert()
        alert.messageText = "Allow \(site) to use your location?"
        alert.informativeText = frame.isMainFrame ? "" : "A part of the page from \(site) is asking, inside \(webView.url?.host() ?? "this page")."
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Don't Allow")
        if !isPrivate {
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = "Remember for this site"
        }
        Debug.log("location", "\(site): asking you")
        Dialogs.show(alert, over: webView) { [weak self] answer in
            let allowed = answer == .alertFirstButtonReturn
            Debug.log("location", "\(site): you said \(allowed ? "allow" : "don't allow")")
            self?.locationAnswers[site] = allowed
            if self?.isPrivate == false, alert.suppressionButton?.state == .on { Permissions.shared.set(site, allowed) }
            then(allowed)
        }
    }
}

// MARK: - the bridge

enum Geolocation {
    static let handlerName = "basicShellLocation"

    /// Replaces navigator.geolocation in every frame, before the page runs.
    /// Permission is asked once per call to getCurrentPosition or
    /// watchPosition (the app remembers answers); a timeout counts from
    /// then, as the specification has it.
    static let script = WKUserScript(source: """
    (() => {
      const bridge = window.webkit && webkit.messageHandlers && webkit.messageHandlers.\(handlerName);
      const geo = navigator.geolocation;
      if (!bridge || !geo) return;
      // Objects of the page's own kinds, so a check like
      // `position instanceof GeolocationPosition` holds; their own fields
      // stand in front of the native getters, which would refuse them.
      // Every field the kind has (WebKit's coordinates also have floorLevel)
      // is given, null where there is nothing to say: one left to the native
      // getter throws, and MapKit, reading floorLevel, gave up on the fix.
      const make = (kind, fields) => {
        const proto = kind && kind.prototype ? kind.prototype : Object.prototype;
        const made = Object.create(proto);
        for (const key of Object.getOwnPropertyNames(proto)) {
          const d = Object.getOwnPropertyDescriptor(proto, key);
          if (d && d.get && !(key in fields)) Object.defineProperty(made, key, { value: null, enumerable: true });
        }
        for (const [key, value] of Object.entries(fields)) Object.defineProperty(made, key, { value, enumerable: key !== "toJSON" });
        return made;
      };
      const error = (code, message) => make(window.GeolocationPositionError,
        { code, message, PERMISSION_DENIED: 1, POSITION_UNAVAILABLE: 2, TIMEOUT: 3 });
      const position = (r) => {
        const fields = { latitude: r.lat, longitude: r.lon, accuracy: r.acc, altitude: r.alt ?? null,
          altitudeAccuracy: r.altAcc ?? null, heading: r.heading ?? null, speed: r.speed ?? null };
        const coords = make(window.GeolocationCoordinates, { ...fields, toJSON: () => ({ ...fields }) });
        return make(window.GeolocationPosition, { coords, timestamp: r.ts, toJSON: () => ({ coords: { ...fields }, timestamp: r.ts }) });
      };
      const once = (ok, fail, options, permitted) => {
        const permit = permitted ? Promise.resolve({ allowed: true }) : bridge.postMessage({ op: "permit" });
        return permit.then((p) => {
          if (!p || !p.allowed) { fail && fail(error(1, "User denied Geolocation")); return false; }
          let settled = false, timer = null;
          const timeout = options && typeof options.timeout === "number" && isFinite(options.timeout) ? Math.max(0, options.timeout) : null;
          if (timeout !== null) timer = setTimeout(() => { if (!settled) { settled = true; fail && fail(error(3, "Timeout expired")); } }, timeout);
          return bridge.postMessage({ op: "position", highAccuracy: !!(options && options.enableHighAccuracy),
            maximumAge: options && typeof options.maximumAge === "number" ? options.maximumAge : 0 }).then((r) => {
            if (settled) return true;
            settled = true; if (timer) clearTimeout(timer);
            if (!r || r.error) fail && fail(error(r ? r.error : 2, r ? r.message : "Position unavailable"));
            else ok && ok(position(r));
            return true;
          });
        }, () => { fail && fail(error(2, "Position unavailable")); return false; });
      };
      let next = 1;
      const watches = new Map();
      const define = (name, value) => Object.defineProperty(geo, name, { value, configurable: true, writable: true });
      define("getCurrentPosition", (ok, fail, options) => { once(ok, fail, options, false); });
      define("watchPosition", (ok, fail, options) => {
        const id = next++;
        watches.set(id, true);
        let last = null;
        const loop = (permitted) => {
          if (!watches.has(id)) return;
          // A watch hears of a position once, and again only when a newer one comes.
          const fresh = (p) => { if (!watches.has(id) || (last !== null && p.timestamp === last)) return; last = p.timestamp; ok && ok(p); };
          once(fresh, (e) => watches.has(id) && fail && fail(e), options, permitted).then((allowed) => {
            if (allowed && watches.has(id)) setTimeout(() => loop(true), 5000);
          });
        };
        loop(false);
        return id;
      });
      define("clearWatch", (id) => { watches.delete(id); });
    })();
    """, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page)

    final class Handler: NSObject, WKScriptMessageHandlerWithReply {
        static let shared = Handler()

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage, replyHandler: @escaping @MainActor (Any?, String?) -> Void) {
            guard let web = message.webView, let tab = web.navigationDelegate as? Tab,
                  let body = message.body as? [String: Any], let op = body["op"] as? String
            else { return replyHandler(nil, "unavailable") }
            let frame = message.frameInfo
            switch op {
            case "permit":
                tab.decideLocation(origin: frame.securityOrigin, frame: frame, in: web) { replyHandler(["allowed": $0], nil) }
            case "position":
                // Only for a site already allowed in this tab or for good.
                let site = frame.securityOrigin.host.isEmpty ? "this page" : frame.securityOrigin.host
                let allowed = tab.locationAnswers[site] ?? (tab.isPrivate ? nil : Permissions.shared.location[site]) ?? false
                guard allowed else { return replyHandler(["error": 1, "message": "User denied Geolocation"], nil) }
                let maximumAge = (body["maximumAge"] as? Double).map { $0 / 1000 } ?? 0
                LocationAccess.current(maximumAge: maximumAge) { result in
                    switch result {
                    case .success(let location):
                        Debug.log("location", "\(site): position ±\(Int(location.horizontalAccuracy)) m")
                        let stamp: Double = location.timestamp.timeIntervalSince1970 * 1000
                        let reply: [String: Any] = [
                            "lat": location.coordinate.latitude, "lon": location.coordinate.longitude,
                            "acc": location.horizontalAccuracy,
                            "alt": location.verticalAccuracy >= 0 ? location.altitude : NSNull(),
                            "altAcc": location.verticalAccuracy >= 0 ? location.verticalAccuracy : NSNull(),
                            "heading": location.course >= 0 ? location.course : NSNull(),
                            "speed": location.speed >= 0 ? location.speed : NSNull(),
                            "ts": stamp,
                        ]
                        replyHandler(reply, nil)
                    case .failure(let error):
                        Debug.log("location", "\(site): no position: \(error.localizedDescription)")
                        replyHandler(["error": 2, "message": "Position unavailable"], nil)
                    }
                }
            default:
                replyHandler(nil, "unknown")
            }
        }
    }

    static func attach(to config: WKWebViewConfiguration) {
        config.userContentController.addUserScript(script)
        config.userContentController.addScriptMessageHandler(Handler.shared, contentWorld: .page, name: handlerName)
    }
}

// MARK: - macOS's side

/// Location Services for BasicShell: macOS's permission, asked the first
/// time a site you allowed wants your location, and positions.
///
/// While pages keep asking (a map following you asks every few seconds),
/// Location Services keep running and each question is answered from the
/// latest fix; fifteen seconds after the last question they stop. Asking
/// macOS for a fresh fix every time instead scans for Wi-Fi networks each
/// time, which is slow and costly.
final class LocationAccess: NSObject, CLLocationManagerDelegate {
    private static let shared = LocationAccess()
    private let manager = CLLocationManager()
    private var waiting: [(Bool) -> Void] = []
    private var fixes: [(Result<CLLocation, any Error>) -> Void] = []
    private var running = false
    private var lastAsked = Date.distantPast

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
    }

    /// At launch, so macOS's answer is known before a page asks.
    static func start() { _ = shared }

    /// macOS's answer as this app's own manager knows it; a new manager
    /// says "not determined" until macOS has told it.
    static var authorization: CLAuthorizationStatus { shared.manager.authorizationStatus }

    static func ensure(_ done: @escaping (Bool) -> Void) {
        shared.ensure(done)
    }

    /// A position no older than `maximumAge` seconds (at least a few, so a
    /// page polling doesn't wake Location Services each time).
    static func current(maximumAge: TimeInterval, _ done: @escaping (Result<CLLocation, any Error>) -> Void) {
        shared.current(maximumAge: max(maximumAge, 4), done)
    }

    private func ensure(_ done: @escaping (Bool) -> Void) {
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorized: done(true)
        case .notDetermined:
            waiting.append(done)
            guard waiting.count == 1 else { return }
            Debug.log("location", "asking macOS for Location Services")
            manager.requestWhenInUseAuthorization()
            // macOS may already have an answer it hasn't told this manager
            // yet, and then never calls back; look again.
            for delay in [0.5, 1.5, 4.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.settle() }
            }
        default:
            done(false)
            LocationAccess.explainDenied()
        }
    }

    /// Answers those waiting for macOS's permission, once macOS has decided.
    private func settle() {
        guard manager.authorizationStatus != .notDetermined, !waiting.isEmpty else { return }
        let allowed = [.authorizedAlways, .authorized].contains(manager.authorizationStatus)
        let callbacks = waiting
        waiting = []
        callbacks.forEach { $0(allowed) }
        if !allowed { LocationAccess.explainDenied() }
    }

    private func current(maximumAge: TimeInterval, _ done: @escaping (Result<CLLocation, any Error>) -> Void) {
        lastAsked = Date()
        // Already following, the latest fix is where you are: macOS sends a
        // new one only when that changes.
        let following = running
        keepRunning()
        if let last = manager.location, following || -last.timestamp.timeIntervalSinceNow <= maximumAge {
            return done(.success(last))
        }
        fixes.append(done)
        guard fixes.count == 1 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
            guard let self, !self.fixes.isEmpty else { return }
            self.deliver(.failure(CLError(.locationUnknown)))
        }
    }

    /// Location Services on while pages ask, off fifteen seconds after.
    private func keepRunning() {
        if !running {
            running = true
            Debug.log("location", "following position")
            manager.startUpdatingLocation()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 15.5) { [weak self] in
            guard let self, self.running, Date().timeIntervalSince(self.lastAsked) >= 15 else { return }
            self.running = false
            Debug.log("location", "no page asking; position no longer followed")
            self.manager.stopUpdatingLocation()
        }
    }

    private func deliver(_ result: Result<CLLocation, any Error>) {
        let callbacks = fixes
        fixes = []
        callbacks.forEach { $0(result) }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        if let location = locations.last { deliver(.success(location)) }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {
        // While following, a passing failure (no fix yet) is not an answer.
        if (error as? CLError)?.code == .locationUnknown, running { return }
        deliver(.failure(error))
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Debug.log("location", "macOS permission changed: \(CLLocationStatus.describe())")
        settle()
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
