import AppKit
import CryptoKit
import Observation
import WebKit

// Browser extensions, on WebKit's own extension engine (WKWebExtension, the
// one Safari uses), and nothing else: no emulation of Chrome APIs WebKit
// lacks. An extension that needs one of those won't work here.
//
// An extension comes from the Chrome Web Store (its link or id; the package's
// signature is checked against the id, see Crx.swift) or from a folder, and is
// copied into Application Support/BasicShell/Extensions/<id>. Adding it shows
// what it asks for; what you accept is granted again at every launch. Its
// pages are served from chrome-extension://<id>/, the address they have in
// Chrome, which some servers check. They work in private tabs too.
//
// The only change made to an extension's files is a line at the top of each
// script with two fixes for Chrome extensions (see `fixes` below).
@Observable
final class Extensions: NSObject, WKWebExtensionControllerDelegate {
    static let shared = Extensions()
    static let scheme = "chrome-extension"

    struct Installed: Codable {
        var id: String
        /// Where it came from: "store", "folder", or "safari".
        var source: String
        /// For a Safari extension: its .appex inside the app it came with.
        var bundle: String? = nil
    }

    /// A Safari web extension on this Mac, inside an app in Applications.
    struct SafariExtension: Identifiable {
        let url: URL
        let name: String
        let identifier: String
        /// Its id here: the bundle identifier made into the letters a Chrome
        /// id is written in, the same every time.
        var id: String { SafariExtension.id(for: identifier) }
        static func id(for identifier: String) -> String { Crx.letters(Array(SHA256.hash(data: Data(identifier.utf8)).prefix(16))) }
    }

    let controller: WKWebExtensionController
    private(set) var contexts: [WKWebExtensionContext] = []
    /// Bumped when an extension's button changes, so the top bar redraws.
    private(set) var actions = 0
    /// How many times WebKit has asked for a popup, for the debug log.
    @ObservationIgnored private(set) var popupsAsked = 0
    private var installed: [Installed] = Store.read("extensions.json", as: [Installed].self) ?? []

    private static var folder: URL { Store.folder.appendingPathComponent("Extensions", isDirectory: true) }
    private static func folder(for id: String) -> URL { folder.appendingPathComponent(id, isDirectory: true) }
    private static func grantedKey(_ id: String) -> String { "extensions.granted.\(id)" }

    override init() {
        WKWebExtension.MatchPattern.registerCustomURLScheme(Extensions.scheme)
        // An extension's pages get the tabs' user agent to the letter: WebKit
        // gives extension workers the user agent of the last page that loaded
        // and, when it differs, stops them, killing whatever they were doing
        // (Bitwarden's sign-in, half-way). They are told they run in Chrome
        // by the fixes below instead (navigator.userAgent). (Found by Search,
        // Office Commun.)
        let configuration = WKWebExtensionController.Configuration.default()
        let pages = configuration.webViewConfiguration ?? WKWebViewConfiguration()
        pages.applicationNameForUserAgent = Web.userAgentName
        configuration.webViewConfiguration = pages
        controller = WKWebExtensionController(configuration: configuration)
        super.init()
        controller.delegate = self
    }

    /// At launch: every extension added before, then the ad blocker (see
    /// below). `loaded` is called once those added before are in (or after
    /// three seconds at most), for the pages to open then: a page already
    /// open when an extension comes in doesn't get its scripts, and kept its
    /// ads.
    func start(loaded: @escaping () -> Void) {
        keepData()
        Extensions.forgetBlockLists()
        var called = false
        let once = {
            guard !called else { return }
            called = true
            loaded()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: once)
        Task {
            for item in installed {
                do { try await load(item.id) } catch {
                    Debug.log("extension", "\(item.id) didn't load: \(error.localizedDescription)")
                    NSLog("BasicShell: extension %@ didn't load: %@", item.id, error.localizedDescription)
                }
            }
            once()
            await addBlocker(asking: true)
        }
    }

    // MARK: - the ad blocker

    /// uBlock Origin Lite, the Safari extension inside its App Store app:
    /// made for WebKit, kept up to date by the App Store, and with its page
    /// scripts registered with WebKit, so a page loaded as BasicShell starts
    /// gets them without waiting for the extension's own code. The Chrome
    /// Web Store's is never used.
    static let blockerIdentifier = "net.raymondhill.uBlock-Origin-Lite.Extension"
    static let blockerID = SafariExtension.id(for: blockerIdentifier)
    static let blockerInStore = URL(string: "macappstore://apps.apple.com/app/id6745342698")!
    /// Whether BasicShell adds it when it is on this Mac: unset until the
    /// first launch without it asks, then the answer (Settings › Privacy).
    /// Removing it in Settings › Extensions turns this off.
    static let blockerWanted = "blocker.ubol"
    /// AdGuard AdBlocker, which BasicShell added by itself before; its
    /// fixes stay, for one added by hand.
    static let adGuard = "bgnkhhnnamicmpeenaelnjfhikgbkllg"

    var hasBlocker: Bool { contexts.contains { $0.uniqueIdentifier == Extensions.blockerID } }

    static func blockerOnThisMac() -> SafariExtension? {
        return safariExtensions().first { $0.identifier == blockerIdentifier }
    }

    /// uBlock Origin Lite had WebKit compile its 110,000 rules anew at every
    /// launch, rules unchanged: six seconds of work and a gigabyte at the
    /// peak. It turns its rule sets off and on again once a launch, for a
    /// Safari bug with private tab groups (WebKit 300236) that BasicShell,
    /// with one extension controller and private tabs in ordinary windows,
    /// doesn't have; and its session rules, gone at every quit, make the
    /// rules differ from the compiled ones WebKit kept. So it runs from a
    /// copy of its files with one module more, first among its background
    /// page's imports, that takes care of both (blockerFix). Copied again
    /// when the App Store brings a new version. (Its files are GPL; the copy
    /// stays on this Mac.)
    static func blockerCopy(of bundle: Bundle) throws -> URL {
        let files = FileManager.default
        guard let source = bundle.resourceURL else { throw Crx.Refused.unpack }
        let folder = Extensions.folder(for: blockerID)
        let stamp = folder.appendingPathComponent("basicshell-copy.txt")
        let version = (bundle.infoDictionary?["CFBundleVersion"] as? String ?? "") + " " + blockerFixMarker
        if (try? String(contentsOf: stamp, encoding: .utf8)) == version { return folder }
        try? files.removeItem(at: folder)
        try files.createDirectory(at: folder.deletingLastPathComponent(), withIntermediateDirectories: true)
        try files.copyItem(at: source, to: folder)
        let background = folder.appendingPathComponent("js/background.js")
        let text = try String(contentsOf: background, encoding: .utf8)
        try ("import './basicshell-fix.js';\n" + text).write(to: background, atomically: true, encoding: .utf8)
        try blockerFix.write(to: folder.appendingPathComponent("js/basicshell-fix.js"), atomically: true, encoding: .utf8)
        try version.write(to: stamp, atomically: true, encoding: .utf8)
        Debug.log("extension", "uBlock Origin Lite copied from its app (\(version))")
        return folder
    }

    private static let blockerFixMarker = "fix 4"
    private static let blockerFix = """
    // BasicShell (see Extensions.blockerCopy). WebKit compiles every rule
    // anew for any change, and keeps the compiled list for the next launch
    // only if the rules are the same then. So:
    // - a change to the rule sets that leaves the same ones on is skipped;
    // - session rules, gone at every quit and added again at every launch,
    //   are kept as dynamic rules numbered from a billion, hidden from
    //   uBlock's own, and written only when they differ from last time.
    // The namespace, which WebKit hands out anew on every read, is pinned,
    // so uBlock's own modules get the one changed here.
    const space = self.browser;
    const dnr = space && space.declarativeNetRequest;
    // uBlock's Safari code calls some of these with a callback, some
    // without: both are answered.
    const define = (name, fn) => {
      const value = (...args) => {
        const callback = typeof args[args.length - 1] === "function" ? args.pop() : null;
        const promise = fn(...args);
        if (!callback) return promise;
        promise.then((v) => callback(v), () => callback(undefined));
      };
      try { Object.defineProperty(dnr, name, { configurable: true, writable: true, value }); } catch (e) {}
    };
    if (dnr && typeof dnr.updateEnabledRulesets === "function" && typeof dnr.getEnabledRulesets === "function") {
      const update = dnr.updateEnabledRulesets.bind(dnr), enabled = dnr.getEnabledRulesets.bind(dnr);
      define("updateEnabledRulesets", async (options = {}) => {
        try {
          const on = new Set(await enabled());
          const next = new Set([...on].filter((id) => !(options.disableRulesetIds || []).includes(id)));
          for (const id of options.enableRulesetIds || []) next.add(id);
          if (next.size === on.size && [...next].every((id) => on.has(id))) return;
        } catch (e) {}
        return update(options);
      });
    }
    if (dnr && typeof dnr.getDynamicRules === "function" && typeof dnr.updateDynamicRules === "function" && space.storage && space.storage.local && space.storage.session) {
      const FIRST = 1000000000, KEY = "basicShell.sessionRules";
      const getDynamic = dnr.getDynamicRules.bind(dnr), setDynamic = dnr.updateDynamicRules.bind(dnr);
      const { local, session } = space.storage;
      const canon = (v) => Array.isArray(v) ? "[" + v.map(canon).join(",") + "]"
        : v && typeof v === "object" ? "{" + Object.keys(v).sort().map((k) => JSON.stringify(k) + ":" + canon(v[k])).join(",") + "}"
        : JSON.stringify(v);
      const keyOf = (rules) => rules.map(canon).sort().join("\\n");
      const kept = async () => (await getDynamic()).filter((r) => r.id >= FIRST);
      let rules = null, timer = null, chain = Promise.resolve();
      // A launch starts with none, as session rules do; a background page
      // started again within a launch finds the ones kept.
      const start = async () => {
        if (rules) return rules;
        let going = false;
        try { going = !!(await session.get(KEY))[KEY]; } catch (e) {}
        const found = going ? (await kept()).map((r) => ({ ...r, id: r.id - FIRST })) : [];
        if (!rules) rules = found;
        return rules;
      };
      // A rule WebKit refuses is left out, and remembered, so the same
      // rules next time still count as the same.
      const sync = async () => {
        const saved = (await local.get(KEY))[KEY] || {};
        const refused = new Set(saved.refused || []);
        let want = rules.filter((r) => !refused.has(canon(r)));
        const have = await kept();
        if (saved.key !== keyOf(want) || have.length !== want.length) {
          for (let tries = 0; ; tries++) {
            try {
              await setDynamic({ removeRuleIds: have.map((r) => r.id), addRules: want.map((r) => ({ ...r, id: r.id + FIRST })) });
              break;
            } catch (e) {
              const at = /rule at index (\\d+)/.exec(String(e && e.message));
              if (!at || tries >= 100 || +at[1] >= want.length) throw e;
              refused.add(canon(want[+at[1]]));
              want = want.filter((r, i) => i !== +at[1]);
            }
          }
          await local.set({ [KEY]: { key: keyOf(want), refused: [...refused] } });
        }
        await session.set({ [KEY]: true });
      };
      define("updateSessionRules", async (options = {}) => {
        await start();
        const add = Array.isArray(options.addRules) ? options.addRules : [];
        const gone = new Set([...(options.removeRuleIds || []), ...add.map((r) => r.id)]);
        rules = rules.filter((r) => !gone.has(r.id)).concat(add);
        clearTimeout(timer);
        timer = setTimeout(() => { chain = chain.then(sync).catch((e) => console.error("BasicShell: session rules not kept", e)); }, 1500);
      });
      define("getSessionRules", async (filter) => {
        await start();
        const ids = filter && Array.isArray(filter.ruleIds) ? filter.ruleIds : null;
        return rules.filter((r) => !ids || ids.includes(r.id)).map((r) => ({ ...r }));
      });
      define("getDynamicRules", async (filter) => (await (filter ? getDynamic(filter) : getDynamic())).filter((r) => r.id < FIRST));
    }
    if (dnr) try { Object.defineProperty(space, "declarativeNetRequest", { configurable: true, writable: true, enumerable: true, value: dnr }); } catch (e) {}
    """

    /// Adds uBlock Origin Lite if it is wanted (or not asked about yet) and
    /// on this Mac; else, the first time, asks whether to get it. At launch,
    /// and whenever BasicShell comes forward while it is wanted but not
    /// here (back from the App Store).
    func addBlocker(asking: Bool) async {
        let defaults = UserDefaults.standard
        let wanted = defaults.object(forKey: Extensions.blockerWanted) as? Bool
        // An older BasicShell on this Mac may have added AdGuard again.
        if hasBlocker { forgetFormerBlockers() }
        guard wanted != false, !hasBlocker || wanted == nil else { return }
        if let found = Extensions.blockerOnThisMac() {
            if !has(found) {
                do {
                    let result = try await add(safari: found, asking: false)
                    Debug.log("extension", "ad blocker: \(result)")
                    Windows.front?.say("uBlock Origin Lite added to block ads")
                } catch {
                    Debug.log("extension", "uBlock Origin Lite not added: \(error.localizedDescription)")
                    return
                }
            }
            defaults.set(true, forKey: Extensions.blockerWanted)
            forgetFormerBlockers()
        } else if wanted == nil, asking {
            askForBlocker()
        }
    }

    private func askForBlocker() {
        let alert = NSAlert()
        alert.messageText = "Block ads with uBlock Origin Lite?"
        alert.informativeText = "BasicShell blocks ads and trackers with uBlock Origin Lite, a free Safari extension that comes with its app from the App Store. Get it there, and BasicShell adds it as soon as it is on this Mac. You can change this in Settings › Privacy."
        alert.addButton(withTitle: "Get It from the App Store")
        alert.addButton(withTitle: "No Thanks")
        let answer = { (response: NSApplication.ModalResponse) in
            let yes = response == .alertFirstButtonReturn
            UserDefaults.standard.set(yes, forKey: Extensions.blockerWanted)
            Debug.log("extension", "uBlock Origin Lite \(yes ? "wanted; App Store opened" : "not wanted")")
            if yes { NSWorkspace.shared.open(Extensions.blockerInStore) }
        }
        if let window = Windows.front?.window { alert.beginSheetModal(for: window, completionHandler: answer) }
        else { answer(alert.runModal()) }
    }

    /// The blockers BasicShell added by itself before, once uBlock Origin
    /// Lite is in: two would do everything twice.
    private func forgetFormerBlockers() {
        let defaults = UserDefaults.standard
        for (key, id, name) in [("blocker.adguard", Extensions.adGuard, "AdGuard AdBlocker"),
                                ("blocker.added", "ddkjiahejlhfcafbddmgiahcphecmpfh", "uBlock Origin Lite from the Chrome Web Store")] {
            guard defaults.bool(forKey: key) else { continue }
            defaults.removeObject(forKey: key)
            if let old = contexts.first(where: { $0.uniqueIdentifier == id }) {
                remove(old)
                Debug.log("extension", "\(name) removed for uBlock Origin Lite")
            }
        }
        defaults.removeObject(forKey: "blocker.filters")
    }

    /// BasicShell once blocked ads with lists of its own; what they left on
    /// disk goes, once.
    private static func forgetBlockLists() {
        let key = "shield.forgotten"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        UserDefaults.standard.removeObject(forKey: "shield.paused")
        try? FileManager.default.removeItem(at: Store.folder.appendingPathComponent("Shield", isDirectory: true))
        let store = WKContentRuleListStore.default()
        store?.getAvailableContentRuleListIdentifiers { identifiers in
            for identifier in identifiers ?? [] where identifier.hasPrefix("shield-") {
                store?.removeContentRuleList(forIdentifier: identifier) { _ in }
            }
        }
    }

    /// Keeps WebKit's tracking prevention away from extensions' own data.
    /// It counts chrome-extension://<id> as a site like any other, and a
    /// site you have never clicked in has its storage, service worker
    /// included, deleted a few seconds after launch: the extension's worker
    /// is stopped mid-way while WebKit's extension code still takes it for
    /// running, so every event sent to it is lost until it is restarted.
    /// Exempting the extensions' addresses, with a private WebKit setting
    /// (`_persistedSites`, the list Safari exempts sites with), stops that.
    /// Other sites are left to tracking prevention as in Safari.
    private func keepData() {
        let store = WKWebsiteDataStore.default()
        let setter = NSSelectorFromString("_setPersistedSites:")
        guard store.responds(to: setter) else {
            Debug.log("extension", "this WebKit can't exempt extensions from tracking prevention")
            return
        }
        let sites = installed.compactMap { URL(string: "\(Extensions.scheme)://\($0.id)/") } as NSArray
        store.perform(setter, with: sites)
    }

    private func load(_ id: String) async throws {
        let found: WKWebExtension
        if let record = installed.first(where: { $0.id == id }), record.source == "safari", let path = record.bundle {
            // Made for WebKit already, and inside an app signed by its
            // maker: loaded as it is, without the fixes for Chrome ones.
            guard let bundle = Bundle(url: URL(fileURLWithPath: path)) else { throw Crx.Refused.unpack }
            if id == Extensions.blockerID, let copy = try? Extensions.blockerCopy(of: bundle) {
                found = try await WKWebExtension(resourceBaseURL: copy)
            } else {
                found = try await WKWebExtension(appExtensionBundle: bundle)
            }
        } else {
            let folder = Extensions.folder(for: id)
            try Extensions.patch(folder)
            found = try await WKWebExtension(resourceBaseURL: folder)
        }
        let context = WKWebExtensionContext(for: found)
        context.uniqueIdentifier = id
        if let base = URL(string: "\(Extensions.scheme)://\(id)/") { context.baseURL = base }
        context.isInspectable = true
        context.hasAccessToPrivateData = true
        for permission in found.requestedPermissions { context.setPermissionStatus(.grantedExplicitly, for: permission) }
        for pattern in found.allRequestedMatchPatterns { context.setPermissionStatus(.grantedExplicitly, for: pattern) }
        // What it was given later, when it asked (nativeMessaging, for
        // Bitwarden's Touch ID): WebKit forgets it at quit, so it is kept here.
        let optional = found.optionalPermissions
        for name in UserDefaults.standard.stringArray(forKey: Extensions.grantedKey(id)) ?? [] {
            let permission = WKWebExtension.Permission(rawValue: name)
            if optional.contains(permission) { context.setPermissionStatus(.grantedExplicitly, for: permission) }
        }
        for name in [WKWebExtensionContext.permissionsWereGrantedNotification, WKWebExtensionContext.grantedPermissionsWereRemovedNotification] {
            NotificationCenter.default.addObserver(forName: name, object: context, queue: .main) { _ in
                MainActor.assumeIsolated {
                    let kept = context.grantedPermissions.keys.filter { optional.contains($0) }.map(\.rawValue).sorted()
                    UserDefaults.standard.set(kept, forKey: Extensions.grantedKey(id))
                }
            }
        }
        try controller.load(context)
        contexts.append(context)
        Debug.log("extension", "loaded \(found.displayName ?? id) \(found.version ?? "")")
        for error in found.errors { Debug.log("extension", "\(found.displayName ?? id) manifest: \(error.localizedDescription)") }
        NotificationCenter.default.addObserver(forName: WKWebExtensionContext.errorsDidUpdateNotification, object: context, queue: .main) { [weak self, weak context] _ in
            MainActor.assumeIsolated {
                guard let context else { return }
                for error in context.errors.suffix(3) { Debug.log("extension", "\(found.displayName ?? id): \(error.localizedDescription)") }
                let failed = context.errors.contains {
                    let error = $0 as NSError
                    return error.domain == WKWebExtensionContext.errorDomain && error.code == WKWebExtensionContext.Error.backgroundContentFailedToLoad.rawValue
                }
                if failed { self?.restartBackground(context) }
            }
        }
        for window in Windows.all { context.didOpenWindow(window) }
    }

    // MARK: - adding and removing

    /// From a Chrome Web Store link or id.
    func add(fromStore text: String) async throws -> String {
        guard let id = Crx.id(in: text) else { throw Crx.Refused.notAnID }
        let zip = try Crx.verifiedZip(try await Crx.fetch(id), id: id)
        let staging = Extensions.folder.appendingPathComponent(".staging-\(id)", isDirectory: true)
        try Crx.unpack(zip, into: staging)
        return try await finish(staging, id: id, source: "store")
    }

    /// From an unpacked extension's folder, which is copied, not changed.
    func add(fromFolder source: URL) async throws -> String {
        guard FileManager.default.fileExists(atPath: source.appendingPathComponent("manifest.json").path) else {
            throw Crx.Refused.unpack
        }
        let id = Crx.letters(Array(UUID().uuidString.utf8.prefix(16)))
        let staging = Extensions.folder.appendingPathComponent(".staging-\(id)", isDirectory: true)
        try? FileManager.default.removeItem(at: staging)
        try FileManager.default.createDirectory(at: Extensions.folder, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source, to: staging)
        return try await finish(staging, id: id, source: "folder")
    }

    /// Safari web extensions the apps in Applications carry.
    static func safariExtensions() -> [SafariExtension] {
        let files = FileManager.default
        let places = [URL(fileURLWithPath: "/Applications"), files.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]
        var found: [SafariExtension] = []
        for place in places {
            let apps = (try? files.contentsOfDirectory(at: place, includingPropertiesForKeys: nil)) ?? []
            for app in apps where app.pathExtension == "app" {
                let plugIns = app.appendingPathComponent("Contents/PlugIns", isDirectory: true)
                for appex in (try? files.contentsOfDirectory(at: plugIns, includingPropertiesForKeys: nil)) ?? [] where appex.pathExtension == "appex" {
                    guard let info = Bundle(url: appex)?.infoDictionary,
                          let point = (info["NSExtension"] as? [String: Any])?["NSExtensionPointIdentifier"] as? String,
                          point == "com.apple.Safari.web-extension",
                          let identifier = info["CFBundleIdentifier"] as? String
                    else { continue }
                    let name = (info["CFBundleDisplayName"] as? String) ?? files.displayName(atPath: app.path)
                    found.append(SafariExtension(url: appex, name: name, identifier: identifier))
                }
            }
        }
        return found.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Whether this Safari extension is already added.
    func has(_ safari: SafariExtension) -> Bool { installed.contains { $0.id == safari.id } }

    /// A Safari web extension, loaded from inside its app where it is.
    func add(safari: SafariExtension, asking: Bool = true) async throws -> String {
        guard let bundle = Bundle(url: safari.url) else { throw Crx.Refused.unpack }
        let found = try await WKWebExtension(appExtensionBundle: bundle)
        guard !asking || confirm(found) else { return "Not added" }
        if let old = contexts.first(where: { $0.uniqueIdentifier == safari.id }) { unload(old) }
        installed.removeAll { $0.id == safari.id }
        installed.append(Installed(id: safari.id, source: "safari", bundle: safari.url.path))
        Store.write(installed, to: "extensions.json")
        do { try await load(safari.id) } catch {
            installed.removeAll { $0.id == safari.id }
            Store.write(installed, to: "extensions.json")
            throw error
        }
        keepData()
        Debug.log("extension", "added Safari extension \(safari.identifier) as \(safari.id)")
        return "Added \(found.displayName ?? safari.name)"
    }

    private func finish(_ staging: URL, id: String, source: String, asking: Bool = true) async throws -> String {
        let files = FileManager.default
        defer { try? files.removeItem(at: staging) }
        let found = try await WKWebExtension(resourceBaseURL: staging)
        guard !asking || confirm(found) else { return "Not added" }
        if let old = contexts.first(where: { $0.uniqueIdentifier == id }) { unload(old) }
        let target = Extensions.folder(for: id)
        try? files.removeItem(at: target)
        try files.moveItem(at: staging, to: target)
        try await load(id)
        installed.removeAll { $0.id == id }
        installed.append(Installed(id: id, source: source))
        Store.write(installed, to: "extensions.json")
        keepData()
        return "Added \(found.displayName ?? "the extension")"
    }

    /// What it asks for, said plainly, before anything is granted.
    private func confirm(_ found: WKWebExtension) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Add “\(found.displayName ?? "this extension")”?"
        var lines: [String] = []
        let sites = found.allRequestedMatchPatterns.map(\.string).sorted()
        if sites.contains(where: { $0.contains("<all_urls>") || $0.hasPrefix("*://*/") || $0 == "*://*/*" }) {
            lines.append("It can read and change every website you visit.")
        } else if !sites.isEmpty {
            lines.append("It can read and change: " + sites.prefix(6).joined(separator: ", ") + (sites.count > 6 ? "…" : ""))
        }
        let permissions = found.requestedPermissions.map(\.rawValue).sorted()
        if !permissions.isEmpty { lines.append("It asks for: " + permissions.joined(separator: ", ")) }
        alert.informativeText = lines.joined(separator: "\n\n")
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    func remove(_ context: WKWebExtensionContext) {
        let id = context.uniqueIdentifier
        // Removed by hand, the ad blocker stays removed.
        if id == Extensions.blockerID { UserDefaults.standard.set(false, forKey: Extensions.blockerWanted) }
        unload(context)
        controller.fetchDataRecord(ofTypes: WKWebExtensionController.allExtensionDataTypes, for: context) { [weak self] record in
            guard let record else { return }
            self?.controller.removeData(ofTypes: WKWebExtensionController.allExtensionDataTypes, from: [record]) {}
        }
        try? FileManager.default.removeItem(at: Extensions.folder(for: id))
        installed.removeAll { $0.id == id }
        Store.write(installed, to: "extensions.json")
        UserDefaults.standard.removeObject(forKey: Extensions.grantedKey(id))
        keepData()
    }

    private var restarted: [String: Date] = [:]

    /// The extension's background failed to load: started afresh, in a new
    /// process. When macOS ends an extension's process (one that holds too
    /// much memory), WebKit starts its background again in another one
    /// while it is still loaded, and there it fails ("Script error",
    /// `chrome` missing; Bitwarden's popup stays white); Reload, which
    /// reuses that process, fails too. Once that process has ended, it
    /// loads again (measured). So the process its background was given is
    /// ended, and a few seconds later the extension is loaded again.
    /// The process is found with WebKit's private `_backgroundWebView` and
    /// `_webProcessIdentifier`. At most once a minute per extension.
    private func restartBackground(_ context: WKWebExtensionContext) {
        let id = context.uniqueIdentifier
        let name = context.webExtension.displayName ?? id
        if let last = restarted[id], Date().timeIntervalSince(last) < 60 { return }
        restarted[id] = Date()
        var process: pid_t = 0
        let background = NSSelectorFromString("_backgroundWebView")
        if context.responds(to: background), let web = context.perform(background)?.takeUnretainedValue() as? WKWebView,
           web.responds(to: NSSelectorFromString("_webProcessIdentifier")),
           let number = web.value(forKey: "_webProcessIdentifier") as? NSNumber {
            process = number.int32Value
        }
        Debug.log("extension", "\(name): background failed to load; starting it afresh (process \(process))")
        if process > 0 { kill(process, SIGKILL) }
        // Its service worker runs in a process of its own, which keeps the
        // broken one; WebKit's private `_terminateServiceWorkers` ends it
        // (and any other running service worker, which starts again when
        // next needed).
        let terminate = NSSelectorFromString("_terminateServiceWorkers")
        if let pool = context.webViewConfiguration?.processPool, pool.responds(to: terminate) { pool.perform(terminate) }
        // WebKit has to see those end before a new one works.
        Task {
            try? await Task.sleep(for: .seconds(3))
            guard let current = contexts.first(where: { $0.uniqueIdentifier == id }) else { return }
            unload(current)
            do { try await load(id) } catch {
                Debug.log("extension", "\(name) didn't load again: \(error.localizedDescription)")
            }
        }
    }

    /// Unloads and loads it again from its folder, for one that has got
    /// itself stuck.
    func reload(_ context: WKWebExtensionContext) {
        let id = context.uniqueIdentifier
        Debug.log("extension", "reloading \(context.webExtension.displayName ?? id)")
        unload(context)
        Task {
            do { try await load(id) } catch {
                Debug.log("extension", "\(id) didn't load again: \(error.localizedDescription)")
            }
        }
    }

    private func unload(_ context: WKWebExtensionContext) {
        try? controller.unload(context)
        contexts.removeAll { $0 === context }
    }

    // MARK: - the changes made to an extension

    /// Put first in every script an extension ships: fixes for the places
    /// where WebKit differs from Chrome in ways a Chrome extension can't
    /// survive, each found with Bitwarden and the debug log:
    ///
    /// - Symbol.dispose and Symbol.asyncDispose, which this JavaScriptCore
    ///   lacks and code compiled from TypeScript's `using` checks for first.
    /// - navigator.userAgent says Chrome in the extension's own pages and
    ///   worker, which some choose their code by (see init for why the
    ///   views themselves can't).
    /// - chrome.scripting.ExecutionWorld, which WebKit doesn't define.
    /// - permissions.contains/request/remove with a permission WebKit doesn't
    ///   know: Chrome answers false, WebKit throws. Bitwarden's popup asks
    ///   about "privacy" as it opens and was left blank by the throw.
    /// - sender.origin on messages and ports, which Chrome gives and WebKit
    ///   doesn't; Bitwarden ignores a sender without one.
    /// - Late listeners. In the background worker, WebKit takes runtime
    ///   listeners only while the worker starts; Chrome takes them any time.
    ///   So one listener per event is given to WebKit at the start and the
    ///   extension's own are kept here; an event that comes before any
    ///   waits for the first.
    /// - A sleeping worker. WebKit stops an idle worker after half a minute
    ///   and wakes it for a message but not for a connection, which it
    ///   refuses ("No runtime.onConnect listeners found"). So a page's
    ///   connect first sends a wake-up message, then connects; what is
    ///   posted meanwhile waits.
    /// - chrome.privacy's password and autofill settings, which a password
    ///   manager turns off to take their place (iCloud Passwords stopped at
    ///   start without them). BasicShell keeps no passwords of its own, so
    ///   they read off, under the extension's control.
    /// - webNavigation's events WebKit lacks (onHistoryStateUpdated and
    ///   three more) exist, and never fire: iCloud Passwords stopped at
    ///   start reaching for one.
    /// - A rule WebKit can't take, in rules added while running: WebKit
    ///   refuses the whole list over it. Kinds of request it doesn't have
    ///   (object, csp_report, webtransport, webbundle) are taken out of a
    ///   rule, and a rule WebKit still refuses (a regular expression beyond
    ///   what it matches with) is left out and the rest given again.
    ///   AdGuard's filtering never started over one rule for "object"
    ///   (plug-ins, which WebKit hasn't), then over one regular expression.
    /// - declarativeNetRequest's names and numbers WebKit doesn't define
    ///   (RuleActionType, ResourceType and the other lists of values, the
    ///   ruleset ids, the separate limits) with Chrome's values, the limits
    ///   kept within WebKit's (dynamic and session rules share 30,000), and
    ///   getAvailableStaticRuleCount, which WebKit lacks: what is left of
    ///   the 150,000 rules a WebKit content blocker takes once the enabled
    ///   rulesets are counted. Without them AdGuard's filtering didn't
    ///   start, and its settings said every filter was over the limit.
    /// - runtime's events about the extension's own updates and suspension
    ///   (onUpdateAvailable and three more) exist, and never fire, and
    ///   requestUpdateCheck answers that there is none: AdGuard stopped
    ///   setting itself up at its first start, filters and all, reaching
    ///   for onUpdateAvailable.
    /// - No windows in the worker. WebKit gives a worker the windows of the
    ///   extension's pages (extension.getViews), and reading anything off
    ///   one from the worker crashes the extension's process (sampled:
    ///   Bitwarden checking every ten seconds whether its popup is open in
    ///   a tab). Chrome gives a worker none; runtime.getContexts, which
    ///   Chrome gives instead and WebKit lacks, is made from the tabs and
    ///   whether a popup is open.
    /// - WebKit compiles an extension's rules, all 150,000 of them, into one
    ///   list, again for every change (seconds), and keeps the last one on
    ///   disk for the next launch if the rules are the same then. A
    ///   rule-set change that changes nothing (AdGuard asked for one at every
    ///   launch) is skipped, and session rules are applied in the background,
    ///   in order, with getSessionRules waiting for them, so an extension
    ///   isn't held up for the compiling.
    /// - A worker's WebSocket is BasicShell's. WebKit runs an extension's
    ///   worker on its process's main thread, and a worker's WebSocket waits
    ///   for the main thread to open it: the process locks up for about a
    ///   minute, popup included (sampled). Bitwarden opens one for live sync
    ///   as soon as you are signed in. So one is opened by BasicShell and
    ///   carried over a native port (ExtensionSocket.swift), for a worker
    ///   that may talk to apps; any other has none.
    ///
    /// WebKit also hands out a new wrapper for `chrome.runtime` and its
    /// events on every read, so they are pinned to keep what is set on them.
    /// (After Search's ExtensionShims.swift, Office Commun, MIT.)
    /// Which version of the fixes a file carries; with the debug log on, a
    /// version that also reports to it (see Debug.swift).
    private static var marker: String { "/* BasicShell: extension fixes 22\(Debug.enabled ? " debug" : "") */" }
    /// One line, so a later version can take this one's place.
    private static var fixes: String { (marker + #"""
    (()=>{for(const n of["dispose","asyncDispose"]){if(typeof Symbol[n]!=="symbol")Object.defineProperty(Symbol,n,{value:Symbol.for("Symbol."+n)})}
    const pin=(o,k)=>{let v;try{v=o[k]}catch(e){return}if(v==null)return v;try{Object.defineProperty(o,k,{value:v,configurable:true,writable:true,enumerable:true})}catch(e){}return v};
    const mend=(sender)=>{if(!sender||typeof sender!=="object"||sender.origin||typeof sender.url!=="string")return sender;const m=/^([a-z][a-z0-9+.-]*:\/\/[^/?#]*)/i.exec(sender.url);if(!m)return sender;try{Object.defineProperty(sender,"origin",{value:m[1],configurable:true,enumerable:true})}catch(e){try{sender={...sender,origin:m[1]}}catch(e2){}}return sender};
    const mendArgs=(args,message)=>{if(message){args[1]=mend(args[1])}else{const port=args[0];if(port&&port.sender&&!port.sender.origin){const fixed=mend(port.sender);if(fixed!==port.sender)try{Object.defineProperty(port,"sender",{value:fixed,configurable:true})}catch(e){}}}return args};
    const DEBUG=__DEBUG__&&(!self.document||location.protocol==="chrome-extension:"||location.hostname==="127.0.0.1");const L=DEBUG?(...a)=>{try{fetch("http://127.0.0.1:__PORT__/log?c=ext&m="+encodeURIComponent((self.document?location.pathname:"worker")+" "+a.map(x=>{try{if(x&&typeof x==="object"&&("message" in x||x instanceof Error))return (x.name?x.name+": ":"")+x.message+(x.stack?" @"+String(x.stack).split("\n")[0]:"");return typeof x==="object"?JSON.stringify(x):String(x)}catch(e){return String(x)}}).join(" ").slice(0,500))).catch(()=>{})}catch(e){}}:()=>{};
    if(DEBUG&&!self.__basicShellDebug){Object.defineProperty(self,"__basicShellDebug",{value:true});self.addEventListener("error",e=>L("error",e.message,(e.filename||"")+":"+e.lineno));self.addEventListener("unhandledrejection",e=>L("unhandled rejection",e.reason));for(const lv of["error","warn"]){const o=console[lv];console[lv]=(...a)=>{L("console."+lv,...a);return o.apply(console,a)}}L("started")}
    for(const ns of["chrome","browser"]){const space=pin(self,ns);const scripting=space&&pin(space,"scripting");if(scripting&&!scripting.ExecutionWorld)try{Object.defineProperty(scripting,"ExecutionWorld",{value:Object.freeze({ISOLATED:"ISOLATED",MAIN:"MAIN"}),configurable:true})}catch(e){}}
    if((typeof ServiceWorkerGlobalScope!=="undefined"&&self instanceof ServiceWorkerGlobalScope)||location.protocol==="chrome-extension:"){try{const real=navigator.userAgent;if(!/ Chrome\//.test(real)){const ua=real.replace(/ Version\/[0-9.]+ Safari\//," Chrome/__CHROME__ Safari/");Object.defineProperty(navigator,"userAgent",{get:()=>ua,configurable:true});Object.defineProperty(navigator,"appVersion",{get:()=>ua.replace(/^Mozilla\//,""),configurable:true})}}catch(e){}}
    for(const ns of["chrome","browser"]){const space=pin(self,ns);const perms=space&&pin(space,"permissions");if(!perms||typeof perms.contains!=="function")continue;
    const unknown=e=>{const m=/'([^']+)' is not a valid permission/.exec(String(e&&e.message||e));return m?m[1]:null};
    const call=(name,absent)=>{const original=perms[name].bind(perms);return(...args)=>{const callback=typeof args[args.length-1]==="function"?args.pop():null;const query=args[0]&&typeof args[0]==="object"?{...args[0]}:args[0];
    const attempt=(q,tries)=>{let p;try{p=Promise.resolve(original(q))}catch(e){p=Promise.reject(e)}return p.catch(e=>{const bad=unknown(e);if(!bad||tries>8||!q||!Array.isArray(q.permissions))throw e;const left=q.permissions.filter(x=>x!==bad);if(name!=="remove"&&left.length<q.permissions.length)return absent;if(!left.length&&!(q.origins&&q.origins.length))return absent;return attempt({...q,permissions:left},tries+1)})};
    const result=attempt(query,0);if(!callback)return result;result.then(v=>callback(v),()=>callback(absent))}};
    try{Object.defineProperty(perms,"contains",{value:call("contains",false),configurable:true,writable:true});Object.defineProperty(perms,"request",{value:call("request",false),configurable:true,writable:true});Object.defineProperty(perms,"remove",{value:call("remove",false),configurable:true,writable:true})}catch(e){}}
    const worker=typeof ServiceWorkerGlobalScope!=="undefined"&&self instanceof ServiceWorkerGlobalScope;
    for(const ns of["chrome","browser"]){const space=pin(self,ns);if(!space||space.privacy)continue;const setting=(value)=>{let v=value;const ls=new Set();const answer=()=>({value:v,levelOfControl:"controlled_by_this_extension"});return{get:(d,cb)=>{const r=answer();if(typeof cb==="function"){cb(r);return}return Promise.resolve(r)},set:(d,cb)=>{if(d&&"value" in d){v=d.value;for(const f of[...ls])try{f(answer())}catch(e){}}if(typeof cb==="function"){cb();return}return Promise.resolve()},clear:(d,cb)=>{if(typeof cb==="function"){cb();return}return Promise.resolve()},onChange:{addListener:f=>{ls.add(f)},removeListener:f=>{ls.delete(f)},hasListener:f=>ls.has(f)}}};try{Object.defineProperty(space,"privacy",{configurable:true,writable:true,value:{services:{passwordSavingEnabled:setting(false),autofillEnabled:setting(false),autofillAddressEnabled:setting(false),autofillCreditCardEnabled:setting(false)},websites:{},network:{}}})}catch(e){}}
    for(const ns of["chrome","browser"]){const space=pin(self,ns);const nav=space&&pin(space,"webNavigation");if(!nav)continue;for(const name of["onHistoryStateUpdated","onReferenceFragmentUpdated","onCreatedNavigationTarget","onTabReplaced"]){if(nav[name])continue;const ls=new Set();try{Object.defineProperty(nav,name,{value:{addListener:f=>{ls.add(f)},removeListener:f=>{ls.delete(f)},hasListener:f=>ls.has(f),hasListeners:()=>ls.size>0},configurable:true,writable:true})}catch(e){}}}
    for(const ns of["chrome","browser"]){const space=pin(self,ns);const dnr=space&&pin(space,"declarativeNetRequest");if(!dnr)continue;const put=(k,v)=>{if(dnr[k]===undefined)try{Object.defineProperty(dnr,k,{value:v,configurable:true,writable:true})}catch(e){}};const en=Object.freeze;put("RuleActionType",en({BLOCK:"block",REDIRECT:"redirect",ALLOW:"allow",UPGRADE_SCHEME:"upgradeScheme",MODIFY_HEADERS:"modifyHeaders",ALLOW_ALL_REQUESTS:"allowAllRequests"}));put("ResourceType",en({MAIN_FRAME:"main_frame",SUB_FRAME:"sub_frame",STYLESHEET:"stylesheet",SCRIPT:"script",IMAGE:"image",FONT:"font",OBJECT:"object",XMLHTTPREQUEST:"xmlhttprequest",PING:"ping",CSP_REPORT:"csp_report",MEDIA:"media",WEBSOCKET:"websocket",WEBTRANSPORT:"webtransport",WEBBUNDLE:"webbundle",OTHER:"other"}));put("DomainType",en({FIRST_PARTY:"firstParty",THIRD_PARTY:"thirdParty"}));put("HeaderOperation",en({APPEND:"append",SET:"set",REMOVE:"remove"}));put("RequestMethod",en({CONNECT:"connect",DELETE:"delete",GET:"get",HEAD:"head",OPTIONS:"options",PATCH:"patch",POST:"post",PUT:"put",OTHER:"other"}));put("UnsupportedRegexReason",en({SYNTAX_ERROR:"syntaxError",MEMORY_LIMIT_EXCEEDED:"memoryLimitExceeded"}));put("DYNAMIC_RULESET_ID","_dynamic");put("SESSION_RULESET_ID","_session");const shared=dnr.MAX_NUMBER_OF_DYNAMIC_AND_SESSION_RULES||30000;put("MAX_NUMBER_OF_SESSION_RULES",5000);put("MAX_NUMBER_OF_DYNAMIC_RULES",shared-5000);put("MAX_NUMBER_OF_UNSAFE_SESSION_RULES",5000);put("MAX_NUMBER_OF_UNSAFE_DYNAMIC_RULES",5000);put("MAX_NUMBER_OF_REGEX_RULES",1000);put("GUARANTEED_MINIMUM_STATIC_RULES",150000);
    if(typeof dnr.getAvailableStaticRuleCount!=="function"){const counts=new Map();const count=async(id)=>{if(counts.has(id))return counts.get(id);let n=0;try{const rr=((space.runtime.getManifest().declarative_net_request||{}).rule_resources||[]).find(r=>r.id===id);if(rr){const list=await(await fetch(space.runtime.getURL(rr.path))).json();n=Array.isArray(list)?list.length:0}}catch(e){}counts.set(id,n);return n};put("getAvailableStaticRuleCount",async(callback)=>{let used=0;try{for(const id of await dnr.getEnabledRulesets())used+=await count(id)}catch(e){}const left=Math.max(0,150000-used);if(typeof callback==="function"){callback(left);return}return left})}
    if(typeof dnr.updateEnabledRulesets==="function"&&typeof dnr.getEnabledRulesets==="function"){const real=dnr.updateEnabledRulesets.bind(dnr),enabled=dnr.getEnabledRulesets.bind(dnr);const update=async(options)=>{const o=options||{};try{const on=new Set(await enabled());if((o.enableRulesetIds||[]).every(id=>on.has(id))&&(o.disableRulesetIds||[]).every(id=>!on.has(id)))return}catch(e){}return real(options)};try{Object.defineProperty(dnr,"updateEnabledRulesets",{value:(options,callback)=>{const p=update(options);if(typeof callback!=="function")return p;p.then(()=>callback(),()=>callback())},configurable:true,writable:true})}catch(e){}}
    const unknown=new Set(["object","csp_report","webtransport","webbundle"]);const clean=(rules)=>Array.isArray(rules)?rules.flatMap(r=>{const c=r&&r.condition;if(!c)return[r];const k={...c};if(Array.isArray(c.resourceTypes)){k.resourceTypes=c.resourceTypes.filter(t=>!unknown.has(t));if(!k.resourceTypes.length)return[]}if(Array.isArray(c.excludedResourceTypes)){k.excludedResourceTypes=c.excludedResourceTypes.filter(t=>!unknown.has(t));if(!k.excludedResourceTypes.length)delete k.excludedResourceTypes}return[{...r,condition:k}]}):rules;let sessionQueue=Promise.resolve();for(const name of["updateSessionRules","updateDynamicRules"]){if(typeof dnr[name]!=="function")continue;const real=dnr[name].bind(dnr);const update=async(options)=>{let o=options&&Array.isArray(options.addRules)?{...options,addRules:clean(options.addRules)}:options;for(let tries=0;;tries++){try{return await real(o)}catch(e){const m=/rule at index (\d+)/.exec(String(e&&e.message));if(!m||tries>=1000||!o||!Array.isArray(o.addRules)||+m[1]>=o.addRules.length)throw e;const i=+m[1];L("rule left out",JSON.stringify(o.addRules[i]).slice(0,200),String(e.message).split(": ").pop());o={...o,addRules:o.addRules.filter((r,j)=>j!==i)}}}};try{Object.defineProperty(dnr,name,{value:(options,callback)=>{let p;if(name==="updateSessionRules"){const job=sessionQueue.then(()=>update(options));sessionQueue=job.catch(e=>L("session rules refused",e&&e.message));p=Promise.resolve()}else p=update(options);if(typeof callback!=="function")return p;p.then(()=>callback(),()=>callback())},configurable:true,writable:true})}catch(e){}}if(typeof dnr.getSessionRules==="function"){const get=dnr.getSessionRules.bind(dnr);try{Object.defineProperty(dnr,"getSessionRules",{value:(...a)=>{const callback=typeof a[a.length-1]==="function"?a.pop():null;const p=sessionQueue.then(()=>get(...a));if(!callback)return p;p.then(v=>callback(v),()=>callback([]))},configurable:true,writable:true})}catch(e){}}
    }
    for(const ns of["chrome","browser"]){const space=pin(self,ns);const runtime=space&&pin(space,"runtime");if(!runtime)continue;for(const name of["onUpdateAvailable","onRestartRequired","onSuspend","onSuspendCanceled"]){if(runtime[name])continue;const ls=new Set();try{Object.defineProperty(runtime,name,{value:{addListener:f=>{ls.add(f)},removeListener:f=>{ls.delete(f)},hasListener:f=>ls.has(f),hasListeners:()=>ls.size>0},configurable:true,writable:true})}catch(e){}}if(typeof runtime.requestUpdateCheck!=="function")try{Object.defineProperty(runtime,"requestUpdateCheck",{value:(cb)=>{const r={status:"no_update"};if(typeof cb==="function"){cb(r.status,{});return}return Promise.resolve(r)},configurable:true,writable:true})}catch(e){}}
    if(worker)for(const ns of["chrome","browser"]){const space=pin(self,ns);const runtime=space&&pin(space,"runtime");const ext=space&&pin(space,"extension");const tabs=space&&pin(space,"tabs");if(!runtime)continue;const views=ext&&typeof ext.getViews==="function"?ext.getViews.bind(ext):null;if(views)try{Object.defineProperty(ext,"getViews",{value:()=>[],configurable:true,writable:true})}catch(e){}if(typeof runtime.getContexts!=="function")try{Object.defineProperty(runtime,"getContexts",{configurable:true,writable:true,value:async(filter)=>{const base=runtime.getURL("");const origin=base.replace(/\/$/,"");const out=[{contextType:"BACKGROUND",contextId:"background",tabId:-1,windowId:-1,frameId:-1,documentUrl:self.location.href,documentOrigin:origin,incognito:false}];try{if(views&&views({type:"popup"}).length>0)out.push({contextType:"POPUP",contextId:"popup",tabId:-1,windowId:-1,frameId:-1,documentUrl:base,documentOrigin:origin,incognito:false})}catch(e){}try{if(tabs)for(const t of await tabs.query({}))if(t.url&&t.url.startsWith(base))out.push({contextType:"TAB",contextId:"tab-"+t.id,tabId:t.id,windowId:t.windowId,frameId:0,documentUrl:t.url,documentOrigin:origin,incognito:!!t.incognito})}catch(e){}const f=filter||{};const has=(k,v)=>!Array.isArray(f[k])||f[k].includes(v);return out.filter(c=>has("contextTypes",c.contextType)&&has("contextIds",c.contextId)&&has("tabIds",c.tabId)&&has("windowIds",c.windowId)&&has("frameIds",c.frameId)&&has("documentUrls",c.documentUrl)&&has("documentOrigins",c.documentOrigin)&&(f.incognito===undefined||f.incognito===c.incognito))}})}catch(e){}}
    if(worker&&typeof self.WebSocket!=="undefined"){const rt=pin(pin(self,"chrome")||{},"runtime");if(rt&&typeof rt.connectNative==="function"){const connectNative=rt.connectNative.bind(rt);
    const enc=(b)=>{let s="";for(let i=0;i<b.length;i+=0x8000)s+=String.fromCharCode.apply(null,b.subarray(i,i+0x8000));return btoa(s)};const dec=(t)=>{const s=atob(t),b=new Uint8Array(s.length);for(let i=0;i<s.length;i++)b[i]=s.charCodeAt(i);return b.buffer};
    class WebSocket extends EventTarget{#port;#state=0;#queue=Promise.resolve();#origin;#hello;
    constructor(url,protocols){super();let u;try{u=new URL(url,location.href)}catch(e){throw new DOMException("The URL '"+url+"' is invalid.","SyntaxError")}if(u.protocol==="http:")u.protocol="ws:";if(u.protocol==="https:")u.protocol="wss:";if(!/^wss?:$/.test(u.protocol)||u.hash)throw new DOMException("The URL '"+url+"' is invalid.","SyntaxError");const list=protocols===undefined?[]:(Array.isArray(protocols)?protocols:[protocols]).map(String);Object.defineProperty(this,"url",{value:u.href,enumerable:true});this.#origin=u.origin;this.protocol="";this.extensions="";this.binaryType="blob";this.bufferedAmount=0;this.onopen=null;this.onmessage=null;this.onerror=null;this.onclose=null;this.#hello={open:this.url,protocols:list,userAgent:navigator.userAgent};this.#connect()}
    #connect(){const port=connectNative("basicshell.socket");let ready=false,tries=0;this.#port=port;const again=()=>{if(ready||this.#state===3)return;if(tries++>=20){this.#fire("error");this.#closed(1006,"",false);return}try{port.postMessage(this.#hello)}catch(e){}setTimeout(again,100*Math.min(tries,5))};port.onMessage.addListener(m=>{ready=true;if(m&&m.ready===true)return;this.#take(m)});port.onDisconnect.addListener(()=>{if(this.#state===3)return;this.#fire("error");this.#closed(1006,"",false)});again()}
    get readyState(){return this.#state}
    #fire(type,init){let ev;if(type==="message")ev=new MessageEvent("message",init);else if(type==="close"&&typeof CloseEvent==="function")ev=new CloseEvent("close",init);else{ev=new Event(type);if(init)for(const k in init)Object.defineProperty(ev,k,{value:init[k]})}const h=this["on"+type];if(typeof h==="function"){try{h.call(this,ev)}catch(e){setTimeout(()=>{throw e})}}this.dispatchEvent(ev)}
    #closed(code,reason,wasClean){this.#state=3;try{this.#port.disconnect()}catch(e){}this.#fire("close",{code,reason,wasClean})}
    #take(m){if(!m||this.#state===3)return;if("opened" in m){this.protocol=m.opened;this.#state=1;this.#fire("open")}else if("text" in m)this.#fire("message",{data:m.text,origin:this.#origin});else if("binary" in m){const buf=dec(m.binary);this.#fire("message",{data:this.binaryType==="arraybuffer"?buf:new Blob([buf]),origin:this.#origin})}else if("failed" in m)this.#fire("error");else if("closed" in m)this.#closed(m.closed,m.reason||"",!!m.clean)}
    send(data){if(this.#state===0)throw new DOMException("WebSocket is still in CONNECTING state.","InvalidStateError");if(this.#state!==1)return;const post=(msg)=>{try{this.#port.postMessage(msg)}catch(e){}};if(typeof data==="string"){this.#queue=this.#queue.then(()=>post({send:data}));return}const bytes=data instanceof ArrayBuffer?Promise.resolve(new Uint8Array(data)):ArrayBuffer.isView(data)?Promise.resolve(new Uint8Array(data.buffer,data.byteOffset,data.byteLength)):data instanceof Blob?data.arrayBuffer().then(b=>new Uint8Array(b)):Promise.resolve(null);this.#queue=this.#queue.then(()=>bytes).then(b=>b?post({sendBinary:enc(b)}):post({send:String(data)}))}
    close(code,reason){if(code!==undefined&&code!==1000&&!(code>=3000&&code<=4999))throw new DOMException("The close code must be either 1000, or between 3000 and 4999. "+code+" is neither.","InvalidAccessError");if(this.#state>=2)return;this.#state=2;const msg={close:code===undefined?1000:code,reason:reason===undefined?"":String(reason)};this.#queue=this.#queue.then(()=>{try{this.#port.postMessage(msg)}catch(e){}})}}
    for(const[k,v]of Object.entries({CONNECTING:0,OPEN:1,CLOSING:2,CLOSED:3})){Object.defineProperty(WebSocket,k,{value:v});Object.defineProperty(WebSocket.prototype,k,{value:v})}
    try{Object.defineProperty(self,"WebSocket",{value:WebSocket,configurable:true,writable:true})}catch(e){}}else{try{Object.defineProperty(self,"WebSocket",{value:undefined,configurable:true,writable:true})}catch(e){}}}
    if(!worker){for(const ns of["chrome","browser"]){const space=pin(self,ns);const runtime=space&&pin(space,"runtime");if(!runtime)continue;for(const name of["onMessage","onConnect"]){const event=pin(runtime,name);if(!event||typeof event.addListener!=="function")continue;const add=event.addListener.bind(event),remove=event.removeListener.bind(event),wrapped=new Map(),message=name==="onMessage";try{Object.defineProperty(event,"addListener",{value:l=>{const w=(...args)=>{if(DEBUG&&message)L("got",args[0]&&(args[0].command||args[0].type||Object.keys(args[0]).join(",")));return l(...mendArgs(args,message))};wrapped.set(l,w);return add(w)},configurable:true,writable:true});Object.defineProperty(event,"removeListener",{value:l=>{const w=wrapped.get(l);wrapped.delete(l);return remove(w||l)},configurable:true,writable:true});Object.defineProperty(event,"hasListener",{value:l=>wrapped.has(l),configurable:true,writable:true})}catch(e){}}}}
    if(!worker)for(const ns of["chrome","browser"]){const space=pin(self,ns);const runtime=space&&pin(space,"runtime");if(!runtime||typeof runtime.connect!=="function"||typeof runtime.sendMessage!=="function")continue;const real=runtime.connect.bind(runtime),send=runtime.sendMessage.bind(runtime);const ev=()=>{const ls=new Set();return{addListener:f=>{ls.add(f)},removeListener:f=>{ls.delete(f)},hasListener:f=>ls.has(f),hasListeners:()=>ls.size>0,ls}};
    try{Object.defineProperty(runtime,"connect",{configurable:true,writable:true,value:(...args)=>{const info=args.find(a=>a&&typeof a==="object")||{};const port={name:info.name||"",sender:undefined,onMessage:ev(),onDisconnect:ev()};let target=null,closed=false;const queue=[];
    port.postMessage=m=>{if(DEBUG)L("post",port.name,m&&(m.command||m.type));if(closed)throw new Error("Attempting to use a disconnected port object");if(target)target.postMessage(m);else queue.push(m)};
    port.disconnect=()=>{if(closed)return;closed=true;if(target)try{target.disconnect()}catch(e){}};
    const attach=()=>{if(closed)return;let p;try{p=real(...args)}catch(e){closed=true;for(const f of[...port.onDisconnect.ls])try{f(port)}catch(e2){}return}p.onMessage.addListener(m=>{if(DEBUG)L("port",port.name,m&&(m.command||m.type));for(const f of[...port.onMessage.ls])try{f(m,port)}catch(e){console.error(e)}});p.onDisconnect.addListener(()=>{if(closed)return;closed=true;for(const f of[...port.onDisconnect.ls])try{f(port)}catch(e){console.error(e)}});target=p;for(const m of queue.splice(0))try{p.postMessage(m)}catch(e){}};
    let wakeup;try{wakeup=Promise.resolve(send({__basicShellWake:true})).catch(()=>{})}catch(e){wakeup=Promise.resolve()}Promise.race([wakeup,new Promise(r=>setTimeout(r,2000))]).then(attach);return port}})}catch(e){}}
    if(!worker&&DEBUG){try{const rt=pin(pin(self,"chrome"),"runtime");const sm=rt.sendMessage.bind(rt);Object.defineProperty(rt,"sendMessage",{value:(...a)=>{const m=a.find(x=>x&&typeof x==="object");if(!(m&&m.__basicShellWake))L("send",m&&(m.command||m.type));const r=sm(...a);if(r&&typeof r.then==="function")r.catch(e=>L("send failed",m&&m.command,e));return r},configurable:true,writable:true})}catch(e){L("wrapfail",e.message)}try{const rt=pin(pin(self,"chrome"),"runtime");const cn=rt.connect.bind(rt);Object.defineProperty(rt,"connect",{value:(...a)=>{const p=cn(...a);L("connect",a);try{p.onDisconnect.addListener(()=>L("disconnected",a,chrome.runtime.lastError&&chrome.runtime.lastError.message))}catch(e){}return p},configurable:true,writable:true})}catch(e){L("wrapfail",e.message)}}
    if(!worker||self.__basicShellLate)return;Object.defineProperty(self,"__basicShellLate",{value:true});
    for(const ns of["chrome","browser"]){const space=pin(self,ns);const runtime=space&&pin(space,"runtime");if(!runtime)continue;
    for(const name of["onMessage","onConnect","onMessageExternal","onConnectExternal"]){const event=pin(runtime,name);if(!event||typeof event.addListener!=="function")continue;
    const listeners=new Set(),waiting=[],message=name.startsWith("onMessage");
    const deliver=(l,args)=>{try{return l(...mendArgs(args,message))}catch(e){console.error(e)}};
    const dispatch=(...args)=>{if(message&&args[0]&&args[0].__basicShellWake===true){try{args[2](true)}catch(e){}return false}if(!message)L(ns+".runtime."+name,"port",args[0]&&args[0].name,"to",listeners.size,"listeners");if(!listeners.size){if(message){waiting.push(args);setTimeout(()=>{const i=waiting.indexOf(args);if(i>=0){waiting.splice(i,1);try{args[2](undefined)}catch(e){}}},15000);return true}waiting.push(args);return}
    if(!message){for(const l of[...listeners])deliver(l,args);return}
    let keep=false;for(const l of[...listeners]){const r=deliver(l,args);if(r===true)keep=true;else if(r&&typeof r.then==="function"){keep=true;r.then(v=>{try{args[2](v)}catch(e){}},()=>{try{args[2](undefined)}catch(e){}})}}return keep};
    event.addListener(dispatch);
    const set=(k,v)=>{try{Object.defineProperty(event,k,{value:v,configurable:true,writable:true})}catch(e){}};
    set("addListener",l=>{listeners.add(l);if(listeners.size===1&&waiting.length)for(const args of waiting.splice(0)){const r=deliver(l,args);if(message&&r&&typeof r.then==="function")r.then(v=>{try{args[2](v)}catch(e){}},()=>{})}});
    set("removeListener",l=>{listeners.delete(l)});set("hasListener",l=>listeners.has(l));set("hasListeners",()=>listeners.size>0)}}})();
    """#).replacingOccurrences(of: "\n", with: "")
        .replacingOccurrences(of: "__DEBUG__", with: Debug.enabled ? "true" : "false")
        .replacingOccurrences(of: "__PORT__", with: String(Debug.port))
        .replacingOccurrences(of: "__CHROME__", with: Crx.chromeVersion) + "\n" }

    /// Puts the fixes first in every script the extension ships, replacing
    /// an older version of them.
    static func patch(_ folder: URL) throws {
        let files = FileManager.default
        guard let walker = files.enumerator(at: folder, includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey]) else { return }
        for case let file as URL in walker where ["js", "mjs"].contains(file.pathExtension.lowercased()) {
            let values = try? file.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
            guard values?.isRegularFile == true, values?.isSymbolicLink != true,
                  var text = try? String(contentsOf: file, encoding: .utf8),
                  !text.hasPrefix(marker)
            else { continue }
            // An older version: everything up to the end of its first line.
            if text.hasPrefix("/* BasicShell:"), let end = text.firstIndex(of: "\n") {
                text = String(text[text.index(after: end)...])
            }
            text = fixes + text
            try text.write(to: file, atomically: true, encoding: .utf8)
        }
    }

    /// How to make a view that shows one of an extension's pages, for a
    /// tab that opens it (a popup popped out, an options page); nil for any
    /// other address.
    func configuration(for url: URL) -> WKWebViewConfiguration? {
        guard url.scheme?.lowercased() == Extensions.scheme else { return nil }
        return controller.extensionContext(for: url)?.webViewConfiguration
    }

    // MARK: - telling WebKit what the browser is doing

    // Private tabs included: extensions work in them too (each is given
    // access to private data as it loads). WebKit knows privacy by window,
    // and private tabs here share windows with ordinary ones, so to an
    // extension they look like any other tab.
    func opened(_ tab: Tab) { controller.didOpenTab(tab) }
    func closed(_ tab: Tab, windowClosing: Bool = false) { controller.didCloseTab(tab, windowIsClosing: windowClosing) }
    func activated(_ tab: Tab?, previous: Tab?) {
        guard let tab else { return }
        controller.didActivateTab(tab, previousActiveTab: previous)
    }
    func changed(_ tab: Tab, _ properties: WKWebExtension.TabChangedProperties) {
        controller.didChangeTabProperties(properties, for: tab)
    }

    // MARK: - WKWebExtensionControllerDelegate

    func webExtensionController(_ controller: WKWebExtensionController, openWindowsFor extensionContext: WKWebExtensionContext) -> [any WKWebExtensionWindow] {
        let ordered = NSApp.orderedWindows.compactMap { $0.windowController as? BrowserWindow }
        return ordered.isEmpty ? Windows.all : ordered
    }

    func webExtensionController(_ controller: WKWebExtensionController, focusedWindowFor extensionContext: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        Windows.front
    }

    func webExtensionController(_ controller: WKWebExtensionController, openNewTabUsing configuration: WKWebExtension.TabConfiguration, for extensionContext: WKWebExtensionContext, completionHandler: @escaping ((any WKWebExtensionTab)?, (any Error)?) -> Void) {
        // The page AdGuard opens once installed waits for its engine, then
        // goes to a thank-you page on adguard.com; here it never got there
        // and stayed at "Loading extension...". BasicShell added AdGuard
        // itself, so it isn't opened.
        if extensionContext.uniqueIdentifier == Extensions.adGuard, configuration.url?.path == "/pages/post-install.html" {
            Debug.log("extension", "AdGuard's after-install page not opened")
            completionHandler(nil, nil)
            return
        }
        let window = (configuration.window as? BrowserWindow) ?? Windows.front ?? Windows.open(empty: true)
        let tab = Tab(privately: false, opening: configuration.url)
        tab.pinned = configuration.shouldBePinned
        window.insert(tab, after: configuration.parentTab as? Tab, select: configuration.shouldBeActive)
        if let url = configuration.url { tab.load(url) }
        completionHandler(tab, nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController, openNewWindowUsing configuration: WKWebExtension.WindowConfiguration, for extensionContext: WKWebExtensionContext, completionHandler: @escaping ((any WKWebExtensionWindow)?, (any Error)?) -> Void) {
        let window = Windows.open(empty: true)
        for url in configuration.tabURLs { window.open(url, select: true) }
        if configuration.frame != .zero { window.window?.setFrame(configuration.frame, display: true) }
        completionHandler(window, nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController, openOptionsPageFor extensionContext: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        if let url = extensionContext.optionsPageURL {
            let window = Windows.front ?? Windows.open(empty: true)
            window.open(url, select: true)
        }
        completionHandler(nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController, promptForPermissions permissions: Set<WKWebExtension.Permission>, in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext, completionHandler: @escaping (Set<WKWebExtension.Permission>, Date?) -> Void) {
        let name = extensionContext.webExtension.displayName ?? "An extension"
        Debug.log("extension", "\(name) asks for permissions: \(permissions.map(\.rawValue).sorted())")
        let granted = ask("\(name) asks for more access", permissions.map(\.rawValue).sorted().joined(separator: ", "))
        completionHandler(granted ? permissions : [], nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController, promptForPermissionToAccess urls: Set<URL>, in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext, completionHandler: @escaping (Set<URL>, Date?) -> Void) {
        let name = extensionContext.webExtension.displayName ?? "An extension"
        let hosts = Set(urls.compactMap { $0.host() }).sorted().joined(separator: ", ")
        completionHandler(ask("Let \(name) read and change \(hosts)?", "") ? urls : [], nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController, promptForPermissionMatchPatterns matchPatterns: Set<WKWebExtension.MatchPattern>, in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext, completionHandler: @escaping (Set<WKWebExtension.MatchPattern>, Date?) -> Void) {
        let name = extensionContext.webExtension.displayName ?? "An extension"
        let sites = matchPatterns.map(\.string).sorted().joined(separator: ", ")
        completionHandler(ask("Let \(name) read and change these sites?", sites) ? matchPatterns : [], nil)
    }

    private func ask(_ title: String, _ detail: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Don't Allow")
        return alert.runModal() == .alertFirstButtonReturn
    }

    // MARK: - apps on this Mac (see NativeMessaging.swift)

    /// A Safari extension talks to the app it came in through that app's own
    /// extension, which WebKit reaches by itself, but only while this
    /// delegate doesn't answer for native messages. So it answers only while
    /// a Chrome extension that may use them is installed.
    nonisolated override func responds(to selector: Selector!) -> Bool {
        let native = [
            #selector(webExtensionController(_:connectUsing:for:completionHandler:)),
            #selector(webExtensionController(_:sendMessage:toApplicationWithIdentifier:for:replyHandler:)),
        ]
        guard native.contains(selector) else { return super.responds(to: selector) }
        // WebKit asks on the main thread, as it sends.
        guard Thread.isMainThread else { return true }
        return MainActor.assumeIsolated { answersNativeMessages }
    }

    private var answersNativeMessages: Bool {
        contexts.contains { context in
            installed.first(where: { $0.id == context.uniqueIdentifier })?.source != "safari"
                && (context.webExtension.requestedPermissions.contains(.nativeMessaging)
                    || context.webExtension.optionalPermissions.contains(.nativeMessaging))
        }
    }

    /// Open connections, kept until either side closes them.
    private var native: [ObjectIdentifier: NativeConnection] = [:]

    func webExtensionController(_ controller: WKWebExtensionController, connectUsing port: WKWebExtension.MessagePort, for extensionContext: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        if port.applicationIdentifier == ExtensionSocket.name {
            ExtensionSocket.connect(port, for: extensionContext)
            return completionHandler(nil)
        }
        do {
            let connection = try NativeHosts.open(port.applicationIdentifier ?? "", for: extensionContext)
            let key = ObjectIdentifier(connection)
            native[key] = connection
            connection.onMessage = { message in port.sendMessage(message, completionHandler: nil) }
            connection.onClose = { [weak self] in
                self?.native[key] = nil
                if !port.isDisconnected { port.disconnect() }
            }
            port.messageHandler = { message, _ in
                MainActor.assumeIsolated { if let message { connection.send(message) } }
            }
            port.disconnectHandler = { _ in MainActor.assumeIsolated { connection.close() } }
            completionHandler(nil)
        } catch {
            completionHandler(error)
        }
    }

    func webExtensionController(_ controller: WKWebExtensionController, sendMessage message: Any, toApplicationWithIdentifier applicationIdentifier: String?, for extensionContext: WKWebExtensionContext, replyHandler: @escaping (Any?, (any Error)?) -> Void) {
        do {
            let connection = try NativeHosts.open(applicationIdentifier ?? "", for: extensionContext)
            let key = ObjectIdentifier(connection)
            native[key] = connection
            var answered = false
            connection.onMessage = { reply in
                guard !answered else { return }
                answered = true
                replyHandler(reply, nil)
                connection.close()
            }
            connection.onClose = { [weak self] in
                self?.native[key] = nil
                if !answered { answered = true; replyHandler(nil, NativeHosts.Refused.failed("\(applicationIdentifier ?? "The app") closed without answering")) }
            }
            connection.send(message)
        } catch {
            replyHandler(nil, error)
        }
    }

    func webExtensionController(_ controller: WKWebExtensionController, didUpdate action: WKWebExtension.Action, forExtensionContext context: WKWebExtensionContext) {
        actions += 1
    }

    func webExtensionController(_ controller: WKWebExtensionController, presentActionPopup action: WKWebExtension.Action, for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        let name = context.webExtension.displayName ?? "extension"
        popupsAsked += 1
        guard let popover = action.popupPopover, let window = Windows.front else {
            Debug.log("extension", "\(name): popup asked for but \(action.popupPopover == nil ? "WebKit gave no popover" : "no window")")
            // An error, so WebKit doesn't take the popup for open and refuse
            // to show it again.
            return completionHandler(NSError(domain: WKWebExtension.Action.self.description(), code: 1))
        }
        Debug.log("extension", "\(name): showing popup (already shown: \(popover.isShown))")
        window.present(popover, for: context)
        completionHandler(nil)
    }
}

// MARK: - tabs and windows, as extensions see them

extension Tab: WKWebExtensionTab {
    private var browser: BrowserWindow? { host as? BrowserWindow }

    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? { browser }
    func indexInWindow(for context: WKWebExtensionContext) -> Int {
        browser?.shell.tabs.firstIndex(of: self) ?? NSNotFound
    }
    func parentTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? { opener }
    /// None while frozen: WebKit's extension code would run scripts in it,
    /// and a frozen view throws (see Freeze).
    func webView(for context: WKWebExtensionContext) -> WKWebView? { isFrozen ? nil : webView }
    func title(for context: WKWebExtensionContext) -> String? { title }
    func url(for context: WKWebExtensionContext) -> URL? { url }
    func isPinned(for context: WKWebExtensionContext) -> Bool { pinned }
    func isSelected(for context: WKWebExtensionContext) -> Bool { browser?.shell.selected === self }
    func isLoadingComplete(for context: WKWebExtensionContext) -> Bool { !isLoading }
    func isPlayingAudio(for context: WKWebExtensionContext) -> Bool { false }
    func zoomFactor(for context: WKWebExtensionContext) -> Double { Double(webView?.pageZoom ?? 1) }

    func activate(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        browser?.select(self)
        browser?.window?.makeKeyAndOrderFront(nil)
        completionHandler(nil)
    }

    func loadURL(_ url: URL, for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        Freeze.thaw(self)
        load(url)
        completionHandler(nil)
    }

    func reload(fromOrigin: Bool, for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        Freeze.thaw(self)
        if fromOrigin { webView?.reloadFromOrigin() } else { webView?.reload() }
        completionHandler(nil)
    }

    func goBack(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        Freeze.thaw(self)
        webView?.goBack()
        completionHandler(nil)
    }

    func goForward(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        Freeze.thaw(self)
        webView?.goForward()
        completionHandler(nil)
    }

    func close(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        browser?.close(self)
        completionHandler(nil)
    }

    func setPinned(_ pinned: Bool, for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        browser?.setPinned(self, pinned)
        completionHandler(nil)
    }
}

extension BrowserWindow: WKWebExtensionWindow {
    func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] { shell.tabs }
    func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? {
        shell.selected
    }
    func windowType(for context: WKWebExtensionContext) -> WKWebExtension.WindowType { .normal }
    func windowState(for context: WKWebExtensionContext) -> WKWebExtension.WindowState {
        guard let window else { return .normal }
        if window.isMiniaturized { return .minimized }
        if shell.fullScreen || window.styleMask.contains(.fullScreen) { return .fullscreen }
        return window.isZoomed ? .maximized : .normal
    }
    func isPrivate(for context: WKWebExtensionContext) -> Bool { false }
    func frame(for context: WKWebExtensionContext) -> CGRect { window?.frame ?? .zero }
    func screenFrame(for context: WKWebExtensionContext) -> CGRect { window?.screen?.frame ?? .zero }

    func focus(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        window?.makeKeyAndOrderFront(nil)
        completionHandler(nil)
    }

    func close(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        window?.performClose(nil)
        completionHandler(nil)
    }
}
