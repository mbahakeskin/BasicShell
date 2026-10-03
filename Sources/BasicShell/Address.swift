import Foundation

// What was typed in the address field: a place to go, or words to search for.
// Adapted from Search's Address.swift (Office Commun, MIT).
enum Address {
    /// Schemes a tab shows itself. Anything else with a scheme typed in is
    /// treated as a search rather than handed to another app.
    private static let ours: Set<String> = ["http", "https", "file", "about", "data"]

    /// A URL for what was typed, or a search for it when it isn't one.
    static func resolve(_ typed: String) -> URL? {
        let text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return url(from: text) ?? Engine.current.search(text)
    }

    static func url(from typed: String) -> URL? {
        let text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains(" ") else { return nil }

        if let split = text.range(of: "://") {
            let scheme = text[..<split.lowerBound].lowercased()
            guard ours.contains(scheme) else { return nil }
            return URL(string: text)
        }
        let lower = text.lowercased()
        if lower.hasPrefix("about:") || lower.hasPrefix("data:") {
            return URL(string: text)
        }

        // It has to look like a host before it gets a scheme in front of it.
        let head = text.prefix { $0 != "/" && $0 != "?" && $0 != "#" }
        guard !head.contains("@") else { return nil }
        let host = head.split(separator: ":").first.map(String.init) ?? String(head)
        guard looksLikeHost(host) else { return nil }

        // A local server rarely has a certificate.
        let local = host == "localhost"
            || host.hasSuffix(".localhost")
            || host.hasSuffix(".test")
            || host == "127.0.0.1"
            || host == "0.0.0.0"
            || host.hasPrefix("192.168.")
            || host.hasPrefix("10.")
        return URL(string: (local ? "http://" : "https://") + text)
    }

    private static func looksLikeHost(_ host: String) -> Bool {
        if host == "localhost" { return true }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        if labels.count == 4, labels.allSatisfy({ UInt8($0) != nil }) { return true }
        guard labels.count >= 2 else { return false }
        guard labels.allSatisfy({ label in
            !label.isEmpty
                && !label.hasPrefix("-")
                && !label.hasSuffix("-")
                && label.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
        }) else { return false }
        // Ending in letters is a domain; ending in digits is a version number.
        let tld = labels[labels.count - 1]
        return tld.count >= 2 && tld.allSatisfy { $0.isLetter }
    }

    /// The address as a person reads it: no scheme, no "www.".
    static func pretty(_ url: URL) -> String {
        guard let host = url.host() else { return url.absoluteString }
        let bare = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        let path = url.path()
        return path.isEmpty || path == "/" ? bare : bare + path
    }

    /// The site alone: its host, without "www.".
    static func site(_ url: URL) -> String {
        guard let host = url.host() else { return url.absoluteString }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}
