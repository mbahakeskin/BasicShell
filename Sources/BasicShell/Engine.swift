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
        return parts.url
    }
}
