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
// And what an extension stored stays in WebKit's folder after the extension
// is removed (see Extensions.remove), so what is there for an extension no
// longer installed is deleted: at launch, and when one is removed.
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
    static func sweepExtensions(keeping installed: Set<String>) {
        let folder = extensionsFolder
        DispatchQueue.global(qos: .utility).async {
            guard let found = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey]) else { return }
            for item in found where !installed.contains(item.lastPathComponent) {
                guard (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
                let bytes = size(of: item)
                guard (try? FileManager.default.removeItem(at: item)) != nil else { continue }
                let name = item.lastPathComponent
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { Debug.log("storage", "removed \(bytes >> 20) MB left by an extension no longer installed (\(name))") }
                }
            }
        }
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
