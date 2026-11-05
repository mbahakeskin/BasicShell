import AppKit
import SwiftUI

/// A site the address field can search directly: type its keyword ("yt"),
/// then Tab or a space, then the words. Chrome calls these site search
/// shortcuts, Vivaldi nicknames.
struct Keyword: Codable, Identifiable, Hashable {
    var id = UUID()
    /// What is typed: "yt".
    var key: String
    /// What it is called; typing it whole works too: "YouTube".
    var name: String
    /// The search address, with %s where the words go.
    var template: String
    /// Where the bare keyword goes. Empty: the site's front page.
    var home: String = ""
    /// The site's colour, "#RRGGBB", shown faintly. Nil: none.
    var colour: String?

    var homeURL: URL? {
        if !home.isEmpty { return URL(string: home) }
        guard let host = URL(string: template.replacingOccurrences(of: "%s", with: "x"))?.host() else { return nil }
        return URL(string: "https://\(host)/")
    }

    /// The search for these words; the front page when there are none.
    func url(for words: String) -> URL? {
        let text = words.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return homeURL }
        guard let encoded = text.addingPercentEncoding(withAllowedCharacters: Keyword.unreserved) else { return nil }
        return URL(string: template.replacingOccurrences(of: "%s", with: encoded))
    }

    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    var nsColour: NSColor? { colour.flatMap { NSColor(hex: $0) } }
    var tint: Color? { nsColour.map { Color(nsColor: $0) } }
}

enum Keywords {
    static let key = "keywords"

    struct Hit {
        let keyword: Keyword
        /// What came after the keyword.
        let words: String
    }

    // MARK: Stored in Settings

    private static var cached: (raw: String, list: [Keyword])?

    /// The list as it is kept: JSON in the defaults, so Settings can edit it
    /// in place. Never written, it is the built-in list.
    static var all: [Keyword] {
        get {
            let raw = UserDefaults.standard.string(forKey: key) ?? ""
            if let cached, cached.raw == raw { return cached.list }
            let list = raw.isEmpty ? defaults : decode(raw)
            cached = (raw, list)
            return list
        }
        set { UserDefaults.standard.set(encode(newValue), forKey: key) }
    }

    static func decode(_ raw: String) -> [Keyword] {
        if raw.isEmpty { return defaults }
        return (try? JSONDecoder().decode([Keyword].self, from: Data(raw.utf8))) ?? []
    }

    static func encode(_ list: [Keyword]) -> String {
        (try? JSONEncoder().encode(list)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
    }

    static func restoreDefaults() { UserDefaults.standard.removeObject(forKey: key) }

    static var defaults: [Keyword] {
        let language = Engine.language
        return [
            Keyword(key: "yt", name: "YouTube", template: "https://www.youtube.com/results?search_query=%s", home: "https://www.youtube.com/", colour: "#FF0033"),
            Keyword(key: "cl", name: "Claude", template: "https://claude.ai/new?q=%s", home: "https://claude.ai/new", colour: "#D97757"),
            Keyword(key: "gpt", name: "ChatGPT", template: "https://chatgpt.com/?q=%s", home: "https://chatgpt.com/", colour: "#10A37F"),
            Keyword(key: "gh", name: "GitHub", template: "https://github.com/search?q=%s", colour: "#6E7681"),
            Keyword(key: "wiki", name: "Wikipedia", template: "https://\(language).wikipedia.org/w/index.php?search=%s", home: "https://\(language).wikipedia.org/", colour: "#8A8D91"),
            Keyword(key: "map", name: "Maps", template: "https://www.google.com/maps/search/%s", home: "https://www.google.com/maps", colour: "#34A853"),
            Keyword(key: "rd", name: "Reddit", template: "https://www.reddit.com/search/?q=%s", colour: "#FF4500"),
            Keyword(key: "tl", name: "Translate", template: "https://translate.google.com/?sl=auto&tl=\(language)&text=%s&op=translate", home: "https://translate.google.com/", colour: "#4285F4"),
        ]
    }

    static func add(_ keyword: Keyword) {
        var list = all.filter { $0.key.caseInsensitiveCompare(keyword.key) != .orderedSame }
        list.append(keyword)
        all = list
    }

    // MARK: Matching

    /// The first word is a keyword, whole (its key, or its name). A single
    /// letter alone is not: someone searching for "w" shouldn't land on
    /// Wikipedia's front page.
    static func exact(_ typed: String) -> Hit? {
        let text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = text.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard let first = parts.first else { return nil }
        let word = Loose.fold(String(first))
        let rest = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespaces) : ""
        guard let found = all.first(where: { Loose.fold($0.key) == word || Loose.fold($0.name) == word }) else { return nil }
        if rest.isEmpty, word.count < 2 { return nil }
        return Hit(keyword: found, words: rest)
    }

    /// Keywords a typed word nearly is ("yout", "yt" for YouTube), best first.
    static func similar(_ word: String, limit: Int = 2) -> [Keyword] {
        guard word.count >= 2 else { return [] }
        let ranked = all.compactMap { keyword -> (Keyword, Int)? in
            let scores = [Loose.score(word, keyword.key), Loose.score(word, keyword.name)].compactMap { $0 }
            return scores.max().map { (keyword, $0) }
        }
        return ranked.sorted { $0.1 > $1.1 }.prefix(limit).map(\.0)
    }
}

/// Letters found in order, as fzf does: "yt" is in "YouTube". Nil when they
/// are not there; higher is better.
enum Loose {
    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    static func score(_ query: String, _ text: String) -> Int? {
        let words = fold(query).split(separator: " ").map(Array.init)
        guard !words.isEmpty else { return 0 }
        let haystack = Array(fold(text))
        var total = 0
        for word in words {
            guard let one = score(word: word, in: haystack) else { return nil }
            total += one
        }
        return total
    }

    private static func score(word: [Character], in text: [Character]) -> Int? {
        guard !word.isEmpty, text.count >= word.count else { return nil }
        // Whole, best at the start of the text or of a word.
        if let at = find(word, in: text) {
            let startsWord = at == 0 || !text[at - 1].isLetter && !text[at - 1].isNumber
            return 2000 - at * 10 + (startsWord ? 300 : 0) + (word.count == text.count ? 500 : 0)
        }
        // Letter by letter, from the first one found.
        var next = 0, first = -1, last = -1, starts = 0
        for (index, letter) in text.enumerated() where next < word.count && letter == word[next] {
            if first < 0 { first = index }
            last = index
            if index == 0 || !text[index - 1].isLetter && !text[index - 1].isNumber { starts += 1 }
            next += 1
        }
        guard next == word.count else { return nil }
        let span = last - first + 1
        // Spread over too much of the text is a coincidence.
        guard span <= word.count * 3 + 2 else { return nil }
        return 1000 - span * 10 - first + starts * 30
    }

    private static func find(_ word: [Character], in text: [Character]) -> Int? {
        guard text.count >= word.count else { return nil }
        for start in 0...(text.count - word.count) where text[start] == word[0] {
            if Array(text[start..<start + word.count]) == word { return start }
        }
        return nil
    }
}

// MARK: Colours

extension NSColor {
    convenience init?(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("#") { text.removeFirst() }
        if text.count == 3 { text = text.map { "\($0)\($0)" }.joined() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        self.init(srgbRed: CGFloat((value >> 16) & 255) / 255, green: CGFloat((value >> 8) & 255) / 255, blue: CGFloat(value & 255) / 255, alpha: 1)
    }

    /// "#RRGGBB" in sRGB.
    var hex: String? {
        guard let rgb = usingColorSpace(.sRGB) else { return nil }
        return String(format: "#%02X%02X%02X", Int((rgb.redComponent * 255).rounded()), Int((rgb.greenComponent * 255).rounded()), Int((rgb.blueComponent * 255).rounded()))
    }

    /// A page's `theme-color`: #rgb, #rrggbb or rgb(r, g, b).
    static func css(_ text: String) -> NSColor? {
        let value = text.trimmingCharacters(in: .whitespaces).lowercased()
        if value.hasPrefix("#") { return NSColor(hex: value) }
        guard value.hasPrefix("rgb") else { return nil }
        let numbers = value.split(whereSeparator: { !"0123456789.".contains($0) }).compactMap { Double($0) }
        guard numbers.count >= 3 else { return nil }
        return NSColor(srgbRed: numbers[0] / 255, green: numbers[1] / 255, blue: numbers[2] / 255, alpha: 1)
    }

    /// The colour an icon is mostly made of: its pixels, those with more
    /// colour in them counting for more. Nil for a grey or empty one.
    static func dominant(in image: NSImage) -> NSColor? {
        let side = 16
        guard let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let data = context.data
        else { return nil }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))
        let bytes = data.bindMemory(to: UInt8.self, capacity: side * side * 4)
        var red = 0.0, green = 0.0, blue = 0.0, weight = 0.0
        for index in 0..<side * side {
            let alpha = Double(bytes[index * 4 + 3]) / 255
            guard alpha > 0.5 else { continue }
            let r = Double(bytes[index * 4]) / 255 / alpha, g = Double(bytes[index * 4 + 1]) / 255 / alpha, b = Double(bytes[index * 4 + 2]) / 255 / alpha
            let colour = max(r, g, b) - min(r, g, b)
            let w = colour * colour
            red += r * w; green += g * w; blue += b * w; weight += w
        }
        guard weight > 1 else { return nil }
        return NSColor(srgbRed: red / weight, green: green / weight, blue: blue / weight, alpha: 1)
    }
}

/// The macOS eyedropper, kept alive while it is open.
enum Dropper {
    private static var sampler: NSColorSampler?

    static func pick(_ done: @escaping (NSColor) -> Void) {
        let made = NSColorSampler()
        sampler = made
        made.show { colour in
            sampler = nil
            if let colour { done(colour) }
        }
    }
}
