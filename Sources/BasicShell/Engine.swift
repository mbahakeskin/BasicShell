import Foundation

enum Engine: String, CaseIterable {
    case google, duckduckgo, kagi, bing

    static var current: Engine {
        UserDefaults.standard.string(forKey: "engine").flatMap(Engine.init) ?? .google
    }

    var title: String {
        switch self {
        case .google: "Google"
        case .duckduckgo: "DuckDuckGo"
        case .kagi: "Kagi"
        case .bing: "Bing"
        }
    }

    func search(_ words: String) -> URL? {
        var parts: URLComponents
        switch self {
        case .google: parts = URLComponents(string: "https://www.google.com/search")!
        case .duckduckgo: parts = URLComponents(string: "https://duckduckgo.com/")!
        case .kagi: parts = URLComponents(string: "https://kagi.com/search")!
        case .bing: parts = URLComponents(string: "https://www.bing.com/search")!
        }
        parts.queryItems = [URLQueryItem(name: "q", value: words)]
        // Google picks the language and country of its results from the
        // address it sees the search coming from; behind a VPN that can be
        // another country entirely. Saying them outright keeps results in
        // the Mac's own language and region.
        if self == .google, Engine.tellsRegion {
            parts.queryItems! += [URLQueryItem(name: "hl", value: Engine.language)]
            if let region = Engine.region { parts.queryItems!.append(URLQueryItem(name: "gl", value: region)) }
        }
        return parts.url
    }

    /// On unless turned off in Settings.
    static var tellsRegion: Bool {
        UserDefaults.standard.object(forKey: "engine.region") as? Bool ?? true
    }

    /// The Mac's first preferred language, as Google writes it ("tr", "en", "pt-BR").
    static var language: String {
        let first = Locale(identifier: Locale.preferredLanguages.first ?? "en")
        let code = first.language.languageCode?.identifier ?? "en"
        if ["pt", "zh"].contains(code), let region = first.region?.identifier { return "\(code)-\(region)" }
        return code
    }

    /// The Mac's region ("TR"), from Language & Region settings.
    static var region: String? { Locale.current.region?.identifier }
}
