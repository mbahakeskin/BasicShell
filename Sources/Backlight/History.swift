import Foundation
import Observation

/// Every page an ordinary tab has shown, newest first, for the History panel
/// and for finishing addresses in the new-tab field. Private tabs leave no
/// trace here. Kept in history.json without an age limit, up to 100,000 pages
/// (the oldest go first), so what is imported from another browser stays.
@Observable
final class History {
    /// The history of the profile in front.
    static var shared: History { Profiles.active.history }

    struct Visit: Codable, Identifiable, Hashable {
        var id = UUID()
        var url: URL
        var title: String
        var date: Date
    }

    private(set) var visits: [Visit]
    @ObservationIgnored fileprivate lazy var saver = Store.Debounced(after: 5) { [weak self] in
        self?.save(waiting: false)
    }
    /// The file is written one at a time, off the main thread: a long history
    /// is megabytes of JSON, and a page loading shouldn't wait for it.
    @ObservationIgnored private let writer = DispatchQueue(label: "history.write", qos: .utility)
    /// A deleted profile's history is never written again.
    @ObservationIgnored private var discarded = false

    private func save(waiting: Bool) {
        guard !discarded else { return }
        let snapshot = visits
        let file = file
        if waiting { writer.sync { Store.write(snapshot, to: file) } } else { writer.async { Store.write(snapshot, to: file) } }
    }

    /// The profile is gone: nothing more is written, and what was is removed.
    func discard() {
        discarded = true
        searching?.cancel()
        let file = file
        writer.async { try? FileManager.default.removeItem(at: Store.folder.appendingPathComponent(file)) }
    }

    private static let limit = 100_000
    @ObservationIgnored private let file: String

    init(file: String) {
        self.file = file
        visits = Store.read(file, as: [Visit].self) ?? []
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
            if visits.count > Self.limit { visits.removeLast(visits.count - Self.limit) }
        }
        forgetPlaces()
        saver.poke()
    }

    /// The page's title arrived after it loaded.
    func retitle(_ url: URL, _ title: String) {
        guard !title.isEmpty, let index = visits.prefix(20).firstIndex(where: { $0.url == url }),
              visits[index].title != title
        else { return }
        visits[index].title = title
        forgetPlaces()
        saver.poke()
    }

    /// Visits from elsewhere, put among the others by date.
    func mergeImported(_ fresh: [Visit]) {
        guard !fresh.isEmpty else { return }
        visits = (visits + fresh).sorted { $0.date > $1.date }
        if visits.count > Self.limit { visits.removeLast(visits.count - Self.limit) }
        forgetPlaces()
        saver.flush()
    }

    func remove(_ ids: Set<UUID>) {
        visits.removeAll { ids.contains($0.id) }
        forgetPlaces()
        saver.poke()
    }

    func clear() {
        visits = []
        forgetPlaces()
        saver.flush()
    }

    /// Before quitting: whatever is waiting to be written, now.
    func flushAll() {
        // Waited for: the app is quitting.
        for profile in Profiles.shared.list { profile.history.save(waiting: true) }
        Archive.shared.flush()
    }

    func search(_ query: String) -> [Visit] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return Array(visits.prefix(500)) }
        return Fuzzy.ranked(visits, trimmed, limit: 500, title: \.title, url: \.url)
    }

    /// Places to offer under the new-tab field: each address once, ones whose
    /// host starts with what was typed first, then the most visited.
    /// Each address once, with its latest visit and how often it was visited,
    /// kept until the history changes: the new-tab field asks on every key
    /// and the list is long (an import can make it 100,000 pages).
    private struct Place {
        let visit: Visit
        let count: Int
        let host: String
    }

    @ObservationIgnored private var places: [Place]?
    /// What the last finished search asked and what fitted it: a longer
    /// question that starts the same way can only fit among those, so typing
    /// narrows instead of searching everything again.
    @ObservationIgnored private var fittedFor = ""
    @ObservationIgnored private var fitted: [Int] = []
    /// The search being made, and what it is for.
    @ObservationIgnored private var searching: Task<Void, Never>?
    @ObservationIgnored private var searchingFor = ""
    @ObservationIgnored private var searchFlag = CancelFlag()
    /// The answer to a question, there when its search has finished (and
    /// what the page showed before until then). Watched, so the field
    /// redraws when it arrives.
    private var answer: (query: String, visits: [Visit]) = ("", [])

    private func forgetPlaces() {
        places = nil
        searching?.cancel()
        searching = nil
        searchingFor = ""
        fittedFor = ""
        fitted = []
        answer = ("", [])
    }

    private func listPlaces() -> [Place] {
        if let places { return places }
        var counts: [URL: Int] = [:]
        for visit in visits { counts[visit.url, default: 0] += 1 }
        var seen = Set<URL>()
        // `visits` is newest first, so the first of an address is its latest.
        let made = visits.compactMap { visit -> Place? in
            guard seen.insert(visit.url).inserted else { return nil }
            return Place(visit: visit, count: counts[visit.url] ?? 1, host: visit.url.host()?.lowercased() ?? "")
        }
        places = made
        return made
    }

    /// What a search needs of an address, and no more: it runs away from the
    /// main thread.
    private nonisolated struct Candidate: Sendable {
        let title: String
        let url: URL
        let host: String
        let count: Int
        let date: Date
    }

    /// Answered at once with what there is: the answer to this question if its
    /// search has finished, else the one before it, while the search (a pass
    /// over a long list, off the main thread, narrowing the last one's) runs
    /// and the field is redrawn with its result.
    func suggestions(for typed: String, limit: Int = 6) -> [Visit] {
        let query = typed.trimmingCharacters(in: .whitespaces).lowercased()
        guard query.count >= 1 else { return [] }
        if answer.query == query { return Array(answer.visits.prefix(limit)) }
        if searchingFor != query { startSearch(query) }
        return Array(answer.visits.prefix(limit))
    }

    private func startSearch(_ query: String) {
        searching?.cancel()
        // The scan runs in a task of its own, which cancelling this one doesn't reach: it is told by a flag.
        searchFlag.set()
        let flag = CancelFlag()
        searchFlag = flag
        searchingFor = query
        let all = listPlaces()
        let narrowed = !fittedFor.isEmpty && query.hasPrefix(fittedFor)
        let pool: [Int] = narrowed ? fitted : Array(all.indices)
        let candidates = pool.map { index -> (Int, Candidate) in
            let place = all[index]
            return (index, Candidate(title: place.visit.title, url: place.visit.url, host: place.host, count: place.count, date: place.visit.date))
        }
        searching = Task { [weak self] in
            let (fits, top) = await Task.detached(priority: .userInitiated) { History.find(query, in: candidates, cancelled: flag) }.value
            guard !Task.isCancelled, let self, self.searchingFor == query, let places = self.places else { return }
            self.fittedFor = query
            self.fitted = fits
            self.answer = (query, top.compactMap { places.indices.contains($0) ? places[$0].visit : nil })
            self.searching = nil
        }
    }

    /// Which of the addresses fit the question (for the next, longer one to
    /// start from) and the first ten of them in the order to offer.
    private nonisolated static func find(_ query: String, in candidates: [(Int, Candidate)], cancelled: CancelFlag) -> ([Int], [Int]) {
        // Found letter by letter rather than whole (see Fuzzy): after the rest.
        let whole = Fuzzy.whole * query.split(separator: " ").count
        var found: [(index: Int, candidate: Candidate, loose: Bool)] = []
        for (count, (index, candidate)) in candidates.enumerated() {
            if count % 256 == 0, cancelled.isSet { return ([], []) }
            if let score = Fuzzy.score(query, title: candidate.title, url: candidate.url) {
                found.append((index, candidate, score < whole))
            }
        }
        let www = "www." + query
        let ranked = found.map { ($0, $0.candidate.host.hasPrefix(query) || $0.candidate.host.hasPrefix(www)) }
            .sorted { a, b in
                if a.1 != b.1 { return a.1 }
                if a.0.loose != b.0.loose { return b.0.loose }
                return (a.0.candidate.count, a.0.candidate.date) > (b.0.candidate.count, b.0.candidate.date)
            }
        return (found.map(\.index), ranked.prefix(10).map { $0.0.index })
    }
}

/// Told to a scan running off the main thread that its answer isn't wanted.
nonisolated final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set() {
        lock.lock()
        value = true
        lock.unlock()
    }
}
