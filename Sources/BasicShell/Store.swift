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
    Fuzzy.score(query, title: title, url: url) != nil
}

/// How well what was typed fits a title and an address, for the new-tab
/// field and the panels: as `matches` always did, each word in one or the
/// other; and now a word also fits when its letters are there in order with
/// little between them ("gthub" for GitHub, "gh bs" for GitHub – BasicShell),
/// counted for less than a word found whole.
enum Fuzzy {
    /// What a word found whole counts for; anything under it was found
    /// letter by letter.
    static let whole = 1000

    /// Nil when a word fits nowhere; higher is better.
    static func score(_ query: String, title: String, url: URL) -> Int? {
        let words = query.split(separator: " ").map { folded(String($0)).map(lowered) }
        guard !words.isEmpty else { return 0 }
        let titleLetters = folded(title, limit: 300)
        let titleLow = titleLetters.map(lowered)
        let address = folded(url.absoluteString, limit: 600).map(lowered)
        var place: (letters: [UInt32], low: [UInt32])?
        var total = 0
        for word in words {
            if let at = index(of: word, in: titleLow) {
                total += whole + (at == 0 ? 20 : 0)
            } else if index(of: word, in: address) != nil {
                total += whole
            } else {
                // Letter by letter, against the address without its scheme
                // and query.
                if place == nil {
                    let letters = folded((url.host() ?? "") + url.path(), limit: 160)
                    place = (letters, letters.map(lowered))
                }
                let inTitle = letters(word, in: Array(titleLetters.prefix(160)), lowered: Array(titleLow.prefix(160)))
                let inPlace = letters(word, in: place!.letters, lowered: place!.low)
                guard let loose = [inTitle, inPlace].compactMap({ $0 }).max() else { return nil }
                total += loose
            }
        }
        return total
    }

    /// Where the word is in the text, whole.
    private static func index(of word: [UInt32], in text: [UInt32]) -> Int? {
        let n = word.count, m = text.count
        guard n > 0, m >= n else { return nil }
        let first = word[0]
        var j = 0
        while j <= m - n {
            if text[j] == first {
                var k = 1
                while k < n, text[j + k] == word[k] { k += 1 }
                if k == n { return j }
            }
            j += 1
        }
        return nil
    }

    /// The items that fit, those found whole first and in the order they
    /// came, then the ones found letter by letter, best first.
    static func ranked<T>(_ items: some Sequence<T>, _ query: String, limit: Int = .max, title: (T) -> String, url: (T) -> URL?) -> [T] {
        let words = query.split(separator: " ").count
        guard words > 0 else { return Array(items.prefix(limit)) }
        var exact: [T] = []
        var loose: [(T, Int)] = []
        for item in items {
            guard let url = url(item), let score = score(query, title: title(item), url: url) else { continue }
            if score >= whole * words { exact.append(item) } else { loose.append((item, score)) }
        }
        loose.sort { $0.1 > $1.1 }
        return Array((exact + loose.map(\.0)).prefix(limit))
    }

    /// The word's letters in order in the text, scored: letters that start a
    /// word or follow the one before count for more, what is skipped between
    /// them for less. Nil when they aren't there, or are too scattered to
    /// have been meant; two letters only as the starts of two words.
    static func letters(_ word: String, in text: String) -> Int? {
        let original = folded(text, limit: 160)
        return letters(folded(word).map(lowered), in: original, lowered: original.map(lowered))
    }

    private static func letters(_ needle: [UInt32], in original: [UInt32], lowered hay: [UInt32]) -> Int? {
        let n = needle.count, m = original.count
        guard n >= 2, m >= n else { return nil }
        // Cheap first: are the letters there in order at all?
        var next = 0
        for c in hay where c == needle[next] {
            next += 1
            if next == n { break }
        }
        guard next == n else { return nil }

        var starts = [Bool](repeating: false, count: m)
        for j in 0..<m {
            starts[j] = j == 0 || !isWordLetter(original[j - 1]) || (isLower(original[j - 1]) && isUpper(original[j]))
        }
        let initials = n == 2
        let none = Int.min / 2
        // ending[j]: the best score with the letters so far, the last at j.
        var ending = [Int](repeating: none, count: m)
        var current = [Int](repeating: none, count: m)
        for j in 0..<m where hay[j] == needle[0] && (!initials || starts[j]) { ending[j] = 10 + (starts[j] ? 8 : 0) }
        for i in 1..<n {
            for j in 0..<m { current[j] = none }
            var carried = none  // the best earlier ending, less what was skipped since
            for j in i..<m {
                if j >= 2, ending[j - 2] > none { carried = max(carried - 1, ending[j - 2] - 4) } else if carried > none { carried -= 1 }
                guard hay[j] == needle[i], !initials || starts[j] else { continue }
                var best = carried
                if ending[j - 1] > none { best = max(best, ending[j - 1] + 6) }
                if best > none { current[j] = best + 10 + (starts[j] ? 8 : 0) }
            }
            swap(&ending, &current)
        }
        guard let best = ending.max(), best > none else { return nil }
        let perfect = 10 * n + 8 + 6 * (n - 1)
        return best * 100 >= perfect * 55 ? best : nil
    }

    // Letters as numbers, accents off: plain ASCII, most of what there is,
    // without going through String's own folding.
    private static func folded(_ text: String, limit: Int = .max) -> [UInt32] {
        var out: [UInt32] = []
        out.reserveCapacity(min(limit, text.utf8.count))
        var ascii = true
        for byte in text.utf8 {
            if byte >= 0x80 { ascii = false; break }
            if out.count == limit { return out }
            out.append(UInt32(byte))
        }
        if ascii { return out }
        return String(text.prefix(limit)).folding(options: [.diacriticInsensitive], locale: nil).unicodeScalars.prefix(limit).map(\.value)
    }

    private static func lowered(_ c: UInt32) -> UInt32 {
        if c < 0x80 { return c >= 65 && c <= 90 ? c + 32 : c }
        guard let scalar = Unicode.Scalar(c) else { return c }
        return scalar.properties.lowercaseMapping.unicodeScalars.first?.value ?? c
    }

    private static func isWordLetter(_ c: UInt32) -> Bool {
        if c < 0x80 { return (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122) }
        guard let scalar = Unicode.Scalar(c) else { return false }
        return scalar.properties.isAlphabetic || scalar.properties.numericType != nil
    }

    private static func isLower(_ c: UInt32) -> Bool {
        if c < 0x80 { return c >= 97 && c <= 122 }
        return Unicode.Scalar(c)?.properties.isLowercase ?? false
    }

    private static func isUpper(_ c: UInt32) -> Bool {
        if c < 0x80 { return c >= 65 && c <= 90 }
        return Unicode.Scalar(c)?.properties.isUppercase ?? false
    }
}
