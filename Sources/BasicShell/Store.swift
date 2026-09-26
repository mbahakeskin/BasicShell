import Foundation

/// The app's own files: small JSON documents in
/// ~/Library/Application Support/BasicShell, each written whole and atomically.
enum Store {
    static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BasicShell", isDirectory: true)
    }

    static func read<T: Decodable>(_ name: String, as type: T.Type) -> T? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(name)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(type, from: data)
    }

    static func write<T: Encodable>(_ value: T, to name: String) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try encoder.encode(value).write(to: folder.appendingPathComponent(name), options: .atomic)
        } catch {
            NSLog("BasicShell: couldn't write %@: %@", name, error.localizedDescription)
        }
    }

    /// Writes once things have been quiet for a moment, rather than on every change.
    final class Debounced {
        private var pending: DispatchWorkItem?
        private let delay: TimeInterval
        private let action: () -> Void

        init(after delay: TimeInterval = 2, _ action: @escaping () -> Void) {
            self.delay = delay
            self.action = action
        }

        func poke() {
            pending?.cancel()
            let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.flush() } }
            pending = work
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }

        func flush() {
            pending?.cancel()
            pending = nil
            action()
        }
    }
}

/// Matches what was typed against a title and an address: every word has to
/// appear in one or the other, in any order, ignoring case and accents.
func matches(_ query: String, title: String, url: URL) -> Bool {
    let words = query.split(separator: " ").map(String.init)
    guard !words.isEmpty else { return true }
    let haystack = (title + " " + url.absoluteString)
    return words.allSatisfy { haystack.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
}
