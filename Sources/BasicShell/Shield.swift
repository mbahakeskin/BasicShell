import CryptoKit
import Observation
import WebKit

// The ad and tracker blocker: WebKit content rule lists, enforced inside
// WebKit's networking before a request is made, so it costs nothing while
// pages run.
//
// The rules are EasyList and EasyPrivacy, converted to WebKit's format
// (Tools/BlockLists.swift) and published, LZFSE-compressed and signed, as the
// "blocklists" release of this app's repository (publish-lists.sh). They are
// not in the app, which keeps it small: the first time it runs it fetches them
// once, checks the signature against the key below and every file against the
// hash the signed manifest gives, and keeps them in Application Support.
// Nothing unsigned is ever used. Until they arrive, and if they never do, a
// short built-in list of ad and tracking networks stands in. Newer lists come
// only when asked for (BasicShell › Update Block Lists).
//
// WebKit compiles each list once and keeps it in its own store; later launches
// look it up. Adapted from Search's Shield.swift (Office Commun, MIT).
@Observable
final class Shield {
    static let shared = Shield()

    static let feed = URL(string: "https://github.com/mbahakeskin/BasicShell/releases/download/blocklists/")!
    /// The public half of the key publish-lists.sh signs with (Ed25519).
    static let publicKey = "742kI0mdY5wFePDPZ9KZ50UHMTLG5zgTzt6I/UgqTvg="

    @ObservationIgnored private(set) var lists: [WKContentRuleList] = []
    /// Every page's controller, so new lists reach pages already open.
    @ObservationIgnored private let controllers = NSHashTable<WKUserContentController>.weakObjects()
    /// The version of the lists in use; nil while it is the built-in one.
    private(set) var version: String?
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
        lists.forEach(controller.remove)
        if !isPaused(on: host) { lists.forEach(controller.add) }
    }

    /// Every page's controller comes through here once.
    func protect(_ controller: WKUserContentController) {
        controllers.add(controller)
        lists.forEach(controller.add)
    }

    // MARK: - lists

    private static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BasicShell/Shield", isDirectory: true)
    }

    /// At launch: the lists fetched before, else the built-in one and a fetch.
    func start() {
        Task {
            if let saved = Shield.saved() {
                await use(saved.sources, version: saved.version)
            } else {
                await use([("builtin", Shield.builtin())], version: nil)
                _ = await fetch()
            }
        }
    }

    /// From the menu: what happened, in a few words.
    func update() async -> String {
        await fetch()
    }

    private struct Manifest {
        let version: String
        let files: [(name: String, sha256: String, size: Int)]
    }

    /// The manifest, if the signature over exactly these bytes is good.
    private static func verified(_ manifest: Data, signature: Data) -> Manifest? {
        guard let raw = Data(base64Encoded: publicKey),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw),
              key.isValidSignature(signature, for: manifest),
              let object = try? JSONSerialization.jsonObject(with: manifest) as? [String: Any],
              let version = object["version"] as? String,
              let files = object["files"] as? [[String: Any]]
        else { return nil }
        // Plain names only: nothing in a manifest can point outside the folder.
        let plain = /^[a-z0-9-]+\.json\.lzfse$/
        let parsed = files.compactMap { file -> (String, String, Int)? in
            guard let name = file["name"] as? String, name.wholeMatch(of: plain) != nil,
                  let hash = file["sha256"] as? String, let size = file["size"] as? Int
            else { return nil }
            return (name, hash, size)
        }
        guard parsed.count == files.count, !parsed.isEmpty else { return nil }
        return Manifest(version: version, files: parsed)
    }

    private static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// A packed list as the JSON WebKit takes, with the name it goes by.
    private static func unpack(_ name: String, _ packed: Data) -> (String, String)? {
        guard let json = try? (packed as NSData).decompressed(using: .lzfse) else { return nil }
        return (name.replacingOccurrences(of: ".json.lzfse", with: ""), String(decoding: json as Data, as: UTF8.self))
    }

    /// The lists kept from last time, checked again as if just downloaded.
    private static func saved() -> (version: String, sources: [(String, String)])? {
        guard let manifest = try? Data(contentsOf: folder.appendingPathComponent("lists.json")),
              let signature = try? Data(contentsOf: folder.appendingPathComponent("lists.json.sig")),
              let parsed = verified(manifest, signature: signature)
        else { return nil }
        var sources: [(String, String)] = []
        for file in parsed.files {
            guard let data = try? Data(contentsOf: folder.appendingPathComponent(file.name)),
                  hash(data) == file.sha256, let source = unpack(file.name, data)
            else { return nil }
            sources.append(source)
        }
        return (parsed.version, sources)
    }

    private func fetch() async -> String {
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        func get(_ name: String) async throws -> Data {
            let (data, response) = try await session.data(from: Shield.feed.appendingPathComponent(name))
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            return data
        }
        do {
            let manifest = try await get("lists.json")
            let signature = try await get("lists.json.sig")
            guard let parsed = Shield.verified(manifest, signature: signature) else {
                trouble = "The block lists' signature didn't check out"
                return "Block lists not updated: bad signature"
            }
            if parsed.version == version { return "Block lists are up to date" }
            var blobs: [(String, Data)] = []
            var sources: [(String, String)] = []
            for file in parsed.files {
                let data = try await get(file.name)
                guard data.count == file.size, Shield.hash(data) == file.sha256,
                      let source = Shield.unpack(file.name, data)
                else {
                    trouble = "\(file.name) didn't match its signed hash"
                    return "Block lists not updated: a file didn't match"
                }
                blobs.append((file.name, data))
                sources.append(source)
            }
            // Written only once everything checked out; the manifest last.
            let files = FileManager.default
            try files.createDirectory(at: Shield.folder, withIntermediateDirectories: true)
            for old in (try? files.contentsOfDirectory(atPath: Shield.folder.path)) ?? [] where !parsed.files.contains(where: { $0.name == old }) {
                try? files.removeItem(at: Shield.folder.appendingPathComponent(old))
            }
            for (name, data) in blobs { try data.write(to: Shield.folder.appendingPathComponent(name), options: .atomic) }
            try signature.write(to: Shield.folder.appendingPathComponent("lists.json.sig"), options: .atomic)
            try manifest.write(to: Shield.folder.appendingPathComponent("lists.json"), options: .atomic)
            await use(sources, version: parsed.version)
            trouble = nil
            return "Block lists updated"
        } catch {
            trouble = "Couldn't fetch the block lists: \(error.localizedDescription)"
            return "Couldn't reach GitHub for the block lists"
        }
    }

    /// Compiles (or finds already compiled) and puts in front of every page.
    private func use(_ sources: [(String, String)], version: String?) async {
        guard let store = WKContentRuleListStore.default() else { return }
        var compiled: [WKContentRuleList] = []
        var keep: Set<String> = []
        for (name, json) in sources {
            let id = "shield-\(name)-" + Shield.hash(Data(json.utf8)).prefix(12)
            keep.insert(id)
            if let found = try? await store.contentRuleList(forIdentifier: id) {
                compiled.append(found)
            } else if let list = try? await store.compileContentRuleList(forIdentifier: id, encodedContentRuleList: json) {
                compiled.append(list)
            } else {
                trouble = "WebKit couldn't compile \(name)"
            }
        }
        guard !compiled.isEmpty else { return }
        for controller in controllers.allObjects {
            lists.forEach(controller.remove)
            compiled.forEach(controller.add)
        }
        lists = compiled
        self.version = version
        for old in await store.availableIdentifiers() ?? [] where old.hasPrefix("shield-") && !keep.contains(old) {
            try? await store.removeContentRuleList(forIdentifier: old)
        }
    }

    /// Third parties whose only job is to watch or to sell, blocked until
    /// the real lists are in.
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
