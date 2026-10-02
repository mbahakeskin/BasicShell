import AppKit
import CoreLocation
import Network
import Observation
import SwiftUI
import WebKit

// A log of what happened, for finding out why something didn't: location
// requests and answers, extension popups, prompts shown and not shown, and
// what pages and extensions themselves report. Off unless turned on in
// Settings › General; while on, every entry also goes to
// ~/Library/Application Support/BasicShell/debug.log.
//
// Pages report through a script message handler; an extension's background
// worker has no such thing, so while logging is on a listener on
// 127.0.0.1:47831 takes its reports (Debug.Receiver).
@Observable
final class Debug {
    static let shared = Debug()
    static let port: UInt16 = 47831

    struct Entry: Identifiable {
        let id = UUID()
        let date: Date
        let category: String
        let message: String
    }

    private(set) var entries: [Entry] = []

    static var enabled: Bool { UserDefaults.standard.bool(forKey: "debug.enabled") }

    static var file: URL { Store.folder.appendingPathComponent("debug.log") }

    static func log(_ category: String, _ message: String) {
        guard enabled else { return }
        shared.add(category, message)
    }

    private func add(_ category: String, _ message: String) {
        let entry = Entry(date: Date(), category: category, message: message)
        entries.append(entry)
        if entries.count > 3000 { entries.removeFirst(entries.count - 3000) }
        let line = "\(Debug.stamp.string(from: entry.date)) [\(category)] \(message)\n"
        if let handle = try? FileHandle(forWritingTo: Debug.file) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? FileManager.default.createDirectory(at: Store.folder, withIntermediateDirectories: true)
            try? Data(line.utf8).write(to: Debug.file)
        }
    }

    func clear() {
        entries = []
        try? FileManager.default.removeItem(at: Debug.file)
    }

    static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    /// At launch, when logging is on.
    static func start() {
        guard enabled else { return }
        log("app", "BasicShell \(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "") started; location services \(CLLocationStatus.describe())")
        Receiver.shared.start()
    }

    // MARK: - pages

    /// Put in ordinary pages while logging is on: what they ask of
    /// geolocation and what they get back. In the page's own world, since
    /// that is where the page's navigator is.
    static let pageScript = WKUserScript(source: """
    (() => {
      const post = (m) => { try { webkit.messageHandlers.basicShellDebug.postMessage(String(m)); } catch (e) {} };
      const geo = navigator.geolocation;
      const wrap = (name) => {
        if (!geo) return;
        const original = geo[name].bind(geo);
        geo[name] = (ok, fail, options) => {
          post(location.host + " " + name + " " + JSON.stringify(options || {}));
          return original(
            (p) => { post(location.host + " " + name + " → position ±" + Math.round(p.coords.accuracy) + "m"); ok && ok(p); },
            (e) => { post(location.host + " " + name + " → error " + e.code + " " + e.message); fail && fail(e); },
            options);
        };
      };
      wrap("getCurrentPosition");
      wrap("watchPosition");
      // The page's own errors, the first fifty.
      let left = 50;
      const report = (kind, text) => { if (left-- > 0) post(location.host + " " + kind + ": " + String(text).slice(0, 300)); };
      addEventListener("error", (e) => {
        // A script, style or image that failed to load says nothing but its element.
        const t = e.target;
        if (t && t !== window && (t.src || t.href)) return report("couldn't load", (t.tagName || "") + " " + String(t.src || t.href).split("?")[0]);
        report("error", (e.message || e) + " @" + (e.filename || "").split("?")[0] + ":" + e.lineno);
      }, true);
      const describe = (x) => x && typeof x === "object" ? (x.name || "") + ": " + (x.message || JSON.stringify(x)) + " @" + String(x.stack || "").split("\\n")[0] : String(x);
      addEventListener("unhandledrejection", (e) => report("unhandled rejection", describe(e.reason)));
      const original = console.error.bind(console);
      console.error = (...a) => { report("console.error", a.map((x) => x && x.message ? x.message : String(x)).join(" ")); return original(...a); };
    })();
    """, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page)

    final class Handler: NSObject, WKScriptMessageHandler {
        static let shared = Handler()
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            Debug.log("page", String(describing: message.body))
        }
    }

    /// Adds the page script and its handler to a configuration, if logging is on.
    static func attach(to config: WKWebViewConfiguration) {
        guard enabled else { return }
        config.userContentController.addUserScript(pageScript)
        config.userContentController.add(Handler.shared, contentWorld: .page, name: "basicShellDebug")
    }

    // MARK: - extensions' reports

    /// A local listener, 127.0.0.1 only, that takes GET /log?c=<category>&m=<message>.
    final class Receiver {
        static let shared = Receiver()
        private var listener: NWListener?

        func start() {
            guard listener == nil else { return }
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: Debug.port)!)
            guard let made = try? NWListener(using: parameters) else {
                Debug.log("debug", "couldn't listen on 127.0.0.1:\(Debug.port)")
                return
            }
            made.newConnectionHandler = { connection in
                connection.start(queue: .main)
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, _ in
                    if let data, let text = String(data: data, encoding: .utf8),
                       let line = text.split(separator: "\r\n").first,
                       let path = line.split(separator: " ").dropFirst().first,
                       let parts = URLComponents(string: String(path)) {
                        let category = parts.queryItems?.first { $0.name == "c" }?.value ?? "ext"
                        let message = parts.queryItems?.first { $0.name == "m" }?.value ?? ""
                        DispatchQueue.main.async { MainActor.assumeIsolated { Debug.log(category, message) } }
                    }
                    let reply = "HTTP/1.1 204 No Content\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n"
                    connection.send(content: Data(reply.utf8), completion: .contentProcessed { _ in connection.cancel() })
                }
            }
            made.start(queue: .main)
            listener = made
        }
    }
}

/// CoreLocation's answer for this app, in words.
enum CLLocationStatus {
    static func describe() -> String {
        let status: String = switch LocationAccess.authorization {
        case .notDetermined: "not asked yet"
        case .restricted: "restricted"
        case .denied: "denied"
        case .authorizedAlways: "allowed"
        @unknown default: "unknown"
        }
        return "\(status), system-wide \(CLLocationManager.locationServicesEnabled() ? "on" : "off")"
    }
}

// MARK: - the window

enum DebugWindow {
    private static var window: NSWindow?

    static func show() {
        if window == nil {
            let made = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 560),
                                styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
            made.title = "Debug Log"
            made.isReleasedWhenClosed = false
            made.contentView = NSHostingView(rootView: DebugView())
            made.center()
            window = made
        }
        window?.makeKeyAndOrderFront(nil)
    }
}

struct DebugView: View {
    @AppStorage("debug.enabled") private var enabled = false
    // `@State` is a macro in the macOS 27 SDK whose plugin ships only with
    // Xcode, so the State it would expand to is stored by hand.
    private var _filter = State(initialValue: "")
    private var filter: String {
        get { _filter.wrappedValue }
        nonmutating set { _filter.wrappedValue = newValue }
    }

    private var shown: [Debug.Entry] {
        let query = filter.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return Debug.shared.entries }
        return Debug.shared.entries.filter {
            $0.category.localizedCaseInsensitiveContains(query) || $0.message.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Toggle("Logging", isOn: $enabled)
                    .toggleStyle(.switch)
                    .onChange(of: enabled) { _, on in
                        if on { Debug.start() }
                    }
                TextField("Filter (category or text)", text: _filter.projectedValue)
                    .textFieldStyle(.roundedBorder)
                Button("Copy All") {
                    let text = shown.map { "\(Debug.stamp.string(from: $0.date)) [\($0.category)] \($0.message)" }.joined(separator: "\n")
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
                Button("Clear") { Debug.shared.clear() }
                Button("Show File") { NSWorkspace.shared.activateFileViewerSelecting([Debug.file]) }
            }
            .padding(10)
            if !enabled {
                Text("Logging is off. Turn it on, then quit and reopen BasicShell so pages and extensions report too.")
                    .font(.caption).foregroundStyle(.secondary).padding(.bottom, 6)
            }
            Divider()
            ScrollViewReader { scroller in
                List(shown) { entry in
                    HStack(alignment: .top, spacing: 8) {
                        Text(Debug.stamp.string(from: entry.date)).foregroundStyle(.secondary)
                        Text(entry.category).foregroundStyle(.orange).frame(width: 70, alignment: .leading)
                        Text(entry.message).textSelection(.enabled)
                    }
                    .font(.system(size: 11, design: .monospaced))
                    .id(entry.id)
                }
                .onChange(of: Debug.shared.entries.count) { _, _ in
                    if let last = shown.last { scroller.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
        .frame(minWidth: 600, minHeight: 300)
    }
}
