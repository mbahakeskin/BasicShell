import Foundation
import WebKit

// What BasicShell keeps on disk beyond what is yours, kept in check.
//
// The web cache (pages' files, kept to load them faster next time) is
// WebKit's, and WebKit lets it grow with the disk's free space: it had come
// to 900 MB. There is a limit now (Settings › Privacy, 250 MB unless
// changed): over it, the cache is emptied. WebKit offers no way to drop only
// the oldest of it, so all of it goes; pages load from the network once and
// are kept again.
//
// And what an extension stored stays in WebKit's folders after the extension
// is removed (see Extensions.remove), so what is there for an extension no
// longer installed is deleted: at launch, and when one is removed. That is
// in two places: a folder of its own, and, for what its pages kept in
// databases, a folder among the sites', under its chrome-extension address.
// Both are BasicShell's own: other browsers keep theirs elsewhere.
enum DiskUse {
    static let limitKey = "cache.limit"
    /// In megabytes; 0 for none.
    static var limit: Int { UserDefaults.standard.object(forKey: limitKey) as? Int ?? 250 }

    private static var bundle: String { Bundle.main.bundleIdentifier ?? "com.mbahakeskin.basicshell" }
    private static var library: URL { FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0] }

    /// Where WebKit keeps the web cache of the default (not private) store.
    static var cacheFolder: URL {
        library.appendingPathComponent("Caches/\(bundle)/WebKit/NetworkCache", isDirectory: true)
    }

    /// Where WebKit keeps what extensions store, a folder for each.
    private static var extensionsFolder: URL {
        library.appendingPathComponent("WebKit/\(bundle)/WebExtensions/Default", isDirectory: true)
    }

    /// Where WebKit keeps what sites store: a folder for each, inside one
    /// for the site it was shown in.
    private static var sitesFolder: URL {
        library.appendingPathComponent("WebKit/\(bundle)/WebsiteData/Default", isDirectory: true)
    }

    private static var timer: Timer?

    /// A little after launch, then every hour.
    static func start() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { MainActor.assumeIsolated { enforce() } }
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { _ in
            MainActor.assumeIsolated { enforce() }
        }
    }

    /// The cache emptied if it is over the limit.
    static func enforce() {
        let limit = limit
        guard limit > 0 else { return }
        cacheSize { bytes in
            guard bytes > Int64(limit) << 20 else { return }
            Debug.log("storage", "web cache at \(bytes >> 20) MB, over the \(limit) MB limit: emptied")
            clearCache {}
        }
    }

    /// The web cache's size, measured off the main thread.
    static func cacheSize(_ done: @escaping @MainActor (Int64) -> Void) {
        let folder = cacheFolder
        DispatchQueue.global(qos: .utility).async {
            let bytes = size(of: folder)
            DispatchQueue.main.async { MainActor.assumeIsolated { done(bytes) } }
        }
    }

    static func clearCache(_ done: @escaping @MainActor () -> Void) {
        WKWebsiteDataStore.default().removeData(ofTypes: [WKWebsiteDataTypeDiskCache], modifiedSince: .distantPast) {
            MainActor.assumeIsolated { done() }
        }
    }

    /// What WebKit kept for extensions that are no longer installed, deleted.
    /// `scheme` is the one their pages are served from.
    static func sweepExtensions(keeping installed: Set<String>, scheme: String) {
        let folder = extensionsFolder
        let sites = sitesFolder
        DispatchQueue.global(qos: .utility).async {
            let files = FileManager.default
            let removed = { (bytes: Int64, what: String) in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { Debug.log("storage", "removed \(bytes >> 20) MB \(what)") }
                }
            }
            for item in (try? files.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
            where !installed.contains(item.lastPathComponent) {
                guard (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
                let bytes = size(of: item)
                guard (try? files.removeItem(at: item)) != nil else { continue }
                removed(bytes, "left by an extension no longer installed (\(item.lastPathComponent))")
            }
            // Among the sites: AdGuard's databases, 145 MB, were still
            // there after its own folder had gone (measured).
            for outer in (try? files.contentsOfDirectory(at: sites, includingPropertiesForKeys: nil)) ?? [] {
                for inner in (try? files.contentsOfDirectory(at: outer, includingPropertiesForKeys: nil)) ?? [] {
                    guard let origin = try? Data(contentsOf: inner.appendingPathComponent("origin")),
                          let gone = hosts(of: scheme, in: origin).first(where: { !installed.contains($0) })
                    else { continue }
                    let bytes = size(of: inner)
                    guard (try? files.removeItem(at: inner)) != nil else { continue }
                    if (try? files.contentsOfDirectory(atPath: outer.path))?.isEmpty == true { try? files.removeItem(at: outer) }
                    removed(bytes, "of databases left by an extension no longer installed (\(gone))")
                }
            }
        }
    }

    /// The hosts with this scheme in a site folder's "origin" file. WebKit
    /// writes there the site and the one it was shown in, each as scheme,
    /// host and port: a text is its length in four bytes, a byte that is 1
    /// when a letter takes one byte and 0 when two, then the letters; the
    /// port is a 0 for none, or a 1 and two bytes. Read otherwise than
    /// that, nothing is returned and the folder stays.
    private nonisolated static func hosts(of scheme: String, in origin: Data) -> [String] {
        let bytes = [UInt8](origin)
        var at = 0
        func text() -> String? {
            guard at + 5 <= bytes.count, bytes[at + 4] <= 1 else { return nil }
            let narrow = bytes[at + 4] == 1
            let letters = Int(bytes[at]) | Int(bytes[at + 1]) << 8 | Int(bytes[at + 2]) << 16 | Int(bytes[at + 3]) << 24
            let start = at + 5, end = start + (narrow ? letters : letters * 2)
            guard letters < 4096, end <= bytes.count else { return nil }
            at = end
            return String(bytes: bytes[start..<end], encoding: narrow ? .isoLatin1 : .utf16LittleEndian)
        }
        var found: [String] = []
        while at < bytes.count {
            guard let itsScheme = text(), let host = text(), at < bytes.count, bytes[at] <= 1 else { return [] }
            at += bytes[at] == 0 ? 1 : 3
            if itsScheme == scheme { found.append(host) }
        }
        return at == bytes.count ? found : []
    }

    /// What the folder holds, each file counted once: WebKit's cache keeps
    /// one file under two names (hard links), and counted by name it came to
    /// twice what the disk gives up (measured).
    private nonisolated static func size(of folder: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .isRegularFileKey, .fileResourceIdentifierKey]
        guard let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: Array(keys)) else { return 0 }
        var total: Int64 = 0
        var counted = Set<AnyHashable>()
        for case let file as URL in files {
            guard let values = try? file.resourceValues(forKeys: keys), values.isRegularFile == true else { continue }
            if let identity = values.fileResourceIdentifier as? AnyHashable, !counted.insert(identity).inserted { continue }
            total += Int64(values.totalFileAllocatedSize ?? 0)
        }
        return total
    }
}
