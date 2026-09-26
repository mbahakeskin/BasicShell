import Foundation
import Observation

/// Every page an ordinary tab has shown, newest first, for the History panel
/// and for finishing addresses in the new-tab field. Private tabs leave no
/// trace here. Kept for 90 days in history.json.
@Observable
final class History {
    static let shared = History()

    struct Visit: Codable, Identifiable, Hashable {
        var id = UUID()
        var url: URL
        var title: String
        var date: Date
    }

    private(set) var visits: [Visit]
    @ObservationIgnored private lazy var saver = Store.Debounced(after: 5) { [weak self] in
        guard let self else { return }
        Store.write(self.visits, to: "history.json")
    }

    private init() {
        let cutoff = Date().addingTimeInterval(-90 * 86400)
        visits = (Store.read("history.json", as: [Visit].self) ?? []).filter { $0.date > cutoff }
    }

    /// A page finished loading in an ordinary tab. The same address again
    /// within half an hour is the same visit.
    func record(_ url: URL, title: String) {
        guard ["http", "https"].contains(url.scheme ?? "") else { return }
        if let first = visits.first, first.url == url, Date().timeIntervalSince(first.date) < 1800 {
            visits[0].title = title.isEmpty ? first.title : title
            visits[0].date = Date()
        } else {
            visits.insert(Visit(url: url, title: title, date: Date()), at: 0)
            if visits.count > 20000 { visits.removeLast(visits.count - 20000) }
        }
        saver.poke()
    }

    /// The page's title arrived after it loaded.
    func retitle(_ url: URL, _ title: String) {
        guard !title.isEmpty, let index = visits.prefix(20).firstIndex(where: { $0.url == url }),
              visits[index].title != title
        else { return }
        visits[index].title = title
        saver.poke()
    }

    func remove(_ ids: Set<UUID>) {
        visits.removeAll { ids.contains($0.id) }
        saver.poke()
    }

    func clear() {
        visits = []
        saver.flush()
    }

    /// Before quitting: whatever is waiting to be written, now.
    func flushAll() {
        saver.flush()
        Archive.shared.flush()
    }

    func search(_ query: String) -> [Visit] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return Array(visits.prefix(500)) }
        return Array(visits.lazy.filter { matches(trimmed, title: $0.title, url: $0.url) }.prefix(500))
    }

    /// Places to offer under the new-tab field: each address once, ones whose
    /// host starts with what was typed first, then the most visited.
    func suggestions(for typed: String, limit: Int = 6) -> [Visit] {
        let query = typed.trimmingCharacters(in: .whitespaces).lowercased()
        guard query.count >= 1 else { return [] }
        var counts: [URL: Int] = [:]
        var latest: [URL: Visit] = [:]
        for visit in visits where matches(query, title: visit.title, url: visit.url) {
            counts[visit.url, default: 0] += 1
            if latest[visit.url] == nil { latest[visit.url] = visit }
        }
        func starts(_ visit: Visit) -> Bool {
            let host = visit.url.host()?.lowercased() ?? ""
            return host.hasPrefix(query) || host.hasPrefix("www." + query)
        }
        return latest.values.sorted { a, b in
            if starts(a) != starts(b) { return starts(a) }
            return (counts[a.url] ?? 0, a.date) > (counts[b.url] ?? 0, b.date)
        }
        .prefix(limit)
        .map { $0 }
    }
}
