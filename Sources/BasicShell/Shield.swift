import CryptoKit
import Observation
import WebKit

// The ad and tracker blocker: WebKit content rule lists, enforced inside
// WebKit's networking before a request is made, so it costs nothing while
// pages run.
//
// The rules are EasyList and EasyPrivacy, converted at build time
// (Tools/BlockLists.swift) and shipped in the app as Resources/Shield/*.json.lzfse.
// Each is compiled by WebKit once, the first time the app sees that version,
// and looked up from WebKit's own store after that. Without them, a short
// built-in list of ad and tracking networks is used. Adapted from Search's
// Shield.swift (Office Commun, MIT).
@Observable
final class Shield {
    static let shared = Shield()

    @ObservationIgnored private(set) var lists: [WKContentRuleList] = []
    @ObservationIgnored private var waiting: [WKUserContentController] = []
    private(set) var ready = false
    private(set) var trouble: String?

    /// Sites it is switched off for, because it broke them.
    private(set) var paused: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "shield.paused") ?? [])

    func isPaused(on host: String?) -> Bool {
        guard let host else { return false }
        return paused.contains(Shield.site(host))
    }

    func pause(_ host: String, _ off: Bool) {
        let site = Shield.site(host)
        if off { paused.insert(site) } else { paused.remove(site) }
        UserDefaults.standard.set(paused.sorted(), forKey: "shield.paused")
    }

    /// "www.example.com" and "example.com" are the same site to a person.
    private static func site(_ host: String) -> String {
        host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// Before each main-frame navigation: on or off for where it is going.
    func tune(_ controller: WKUserContentController, for host: String?) {
        guard ready else { return }
        lists.forEach(controller.remove)
        if !isPaused(on: host) { lists.forEach(controller.add) }
    }

    /// Every tab asks; whoever asks before the lists are ready gets them when they are.
    func protect(_ controller: WKUserContentController) {
        if ready { lists.forEach(controller.add) } else { waiting.append(controller) }
    }

    // MARK: - compiling

    func compile() {
        guard !ready, let store = WKContentRuleListStore.default() else { return }
        Task {
            var sources = Shield.bundled()
            if sources.isEmpty { sources = [("builtin", Shield.builtin())] }
            var compiled: [WKContentRuleList] = []
            var keep: Set<String> = []
            for (name, json) in sources {
                let id = "shield-\(name)-" + SHA256.hash(data: Data(json.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
                keep.insert(id)
                if let found = try? await store.contentRuleList(forIdentifier: id) {
                    compiled.append(found)
                    continue
                }
                do {
                    if let list = try await store.compileContentRuleList(forIdentifier: id, encodedContentRuleList: json) {
                        compiled.append(list)
                    }
                } catch {
                    trouble = "\(name): \(error.localizedDescription)"
                }
            }
            // Versions of the lists this app no longer ships.
            for old in await store.availableIdentifiers() ?? [] where old.hasPrefix("shield-") && !keep.contains(old) {
                try? await store.removeContentRuleList(forIdentifier: old)
            }
            lists = compiled
            ready = true
            waiting.forEach { controller in compiled.forEach(controller.add) }
            waiting = []
        }
    }

    private static func bundled() -> [(String, String)] {
        guard let folder = Bundle.main.resourceURL?.appendingPathComponent("Shield"),
              let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        else { return [] }
        return files.filter { $0.lastPathComponent.hasSuffix(".json.lzfse") }.sorted { $0.path < $1.path }.compactMap { file in
            guard let packed = try? Data(contentsOf: file),
                  let json = try? (packed as NSData).decompressed(using: .lzfse)
            else { return nil }
            let name = file.lastPathComponent.replacingOccurrences(of: ".json.lzfse", with: "")
            return (name, String(decoding: json as Data, as: UTF8.self))
        }
    }

    /// Third parties whose only job is to watch or to sell, for a build made
    /// without the filter lists.
    private static let unwanted = [
        "doubleclick.net", "googlesyndication.com", "googleadservices.com",
        "googletagservices.com", "google-analytics.com", "googletagmanager.com",
        "adservice.google.com", "amazon-adsystem.com", "adnxs.com", "adsrvr.org",
        "criteo.com", "criteo.net", "taboola.com", "outbrain.com",
        "rubiconproject.com", "pubmatic.com", "openx.net", "casalemedia.com",
        "smartadserver.com", "sharethrough.com", "indexww.com", "bidswitch.net",
        "33across.com", "teads.tv", "moatads.com", "adroll.com",
        "scorecardresearch.com", "quantserve.com", "chartbeat.com",
        "hotjar.com", "mouseflow.com", "fullstory.com", "clarity.ms",
        "mixpanel.com", "amplitude.com", "segment.com", "segment.io",
        "branch.io", "appsflyer.com", "adjust.com", "analytics.tiktok.com",
        "connect.facebook.net", "ads-twitter.com", "analytics.twitter.com",
    ]

    private static func builtin() -> String {
        let rules: [[String: Any]] = unwanted.map { domain in
            let escaped = domain.replacingOccurrences(of: ".", with: "\\.")
            return [
                "trigger": ["url-filter": "^https?://([^/]+\\.)?\(escaped)", "load-type": ["third-party"]],
                "action": ["type": "block"],
            ]
        }
        let data = (try? JSONSerialization.data(withJSONObject: rules)) ?? Data("[]".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}

private extension WKContentRuleListStore {
    func availableIdentifiers() async -> [String]? {
        await withCheckedContinuation { done in
            getAvailableContentRuleListIdentifiers { done.resume(returning: $0) }
        }
    }
}
