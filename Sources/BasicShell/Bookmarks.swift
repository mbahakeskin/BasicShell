import Foundation
import Observation

/// Pages kept on purpose: one flat list, in the order you keep it, in
/// bookmarks.json. ⌘D keeps the page you are on, or lets it go again.
@Observable
final class Bookmarks {
    static let shared = Bookmarks()

    struct Mark: Codable, Identifiable, Hashable {
        var id = UUID()
        var url: URL
        var title: String
        var added = Date()
    }

    private(set) var marks: [Mark] = Store.read("bookmarks.json", as: [Mark].self) ?? []

    private func save() { Store.write(marks, to: "bookmarks.json") }

    func contains(_ url: URL?) -> Bool {
        guard let url else { return false }
        return marks.contains { $0.url == url }
    }

    /// Keeps the page, or lets it go if it was kept. True when it is now kept.
    @discardableResult
    func toggle(_ url: URL, title: String) -> Bool {
        if let index = marks.firstIndex(where: { $0.url == url }) {
            marks.remove(at: index)
            save()
            return false
        }
        marks.append(Mark(url: url, title: title.isEmpty ? Address.pretty(url) : title))
        save()
        return true
    }

    func remove(_ ids: Set<UUID>) {
        marks.removeAll { ids.contains($0.id) }
        save()
    }

    func move(from source: IndexSet, to destination: Int) {
        marks.move(fromOffsets: source, toOffset: destination)
        save()
    }

    func search(_ query: String) -> [Mark] {
        marks.filter { matches(query, title: $0.title, url: $0.url) }
    }
}

/// Tabs put away (by hand, or by themselves after a while unseen): kept with
/// their history and scroll position, searchable, and brought back as they
/// were. 30 days, 1,000 at most, in archive.json.
@Observable
final class Archive {
    static let shared = Archive()

    struct Entry: Codable, Identifiable {
        var id = UUID()
        var tab: Session.SavedTab
        var date = Date()
    }

    private(set) var entries: [Entry]
    @ObservationIgnored private lazy var saver = Store.Debounced { [weak self] in
        guard let self else { return }
        Store.write(self.entries, to: "archive.json")
    }

    private init() {
        let cutoff = Date().addingTimeInterval(-30 * 86400)
        entries = (Store.read("archive.json", as: [Entry].self) ?? []).filter { $0.date > cutoff }
    }

    /// How long a tab goes unseen before it is archived. Twelve hours, or
    /// `archive.hours` in the defaults; 0 means never.
    static var after: TimeInterval? {
        let set = UserDefaults.standard.object(forKey: "archive.hours") as? Double ?? 12
        return set > 0 ? set * 3600 : nil
    }

    func add(_ tab: Tab) {
        guard !tab.isPrivate, tab.url != nil else { return }
        entries.insert(Entry(tab: Session.snapshot(of: tab)), at: 0)
        if entries.count > 1000 { entries.removeLast(entries.count - 1000) }
        saver.poke()
    }

    /// Takes an entry out, to be opened again.
    func take(_ id: UUID) -> Session.SavedTab? {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return nil }
        let entry = entries.remove(at: index)
        saver.poke()
        return entry.tab
    }

    func remove(_ ids: Set<UUID>) {
        entries.removeAll { ids.contains($0.id) }
        saver.poke()
    }

    func clear() {
        entries = []
        saver.flush()
    }

    func search(_ query: String) -> [Entry] {
        entries.filter { entry in
            guard let url = entry.tab.url else { return false }
            return matches(query, title: entry.tab.title, url: url)
        }
    }

    func flush() { saver.flush() }
}
