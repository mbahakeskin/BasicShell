import AppKit
import Observation
import os
import WebKit

// Downloads go to ~/Downloads under the name the site gave, never over an
// existing file. The Downloads panel lists them with their progress; a
// finished file bounces the Downloads stack in the Dock.
//
// A download can be paused: WebKit hands back resume data and the partial
// file stays where it is, so it can go on from there, also after BasicShell
// has been quit (downloads.json keeps the paused ones and the last hundred
// finished). A server that cannot go on from the middle gives a plain message
// and a Restart.
@Observable
final class Downloads: NSObject, WKDownloadDelegate {
    static let shared = Downloads()

    @Observable
    final class Item: Identifiable {
        enum State { case running, paused, finished, failed, cancelled }
        /// What the person asked of a running download, so that the delegate
        /// can tell a pause from a failure when WebKit reports it ended.
        enum Intent { case none, pause, cancel, quit }

        let id: UUID
        let source: URL?
        var file: URL?
        var name: String
        var state: State = .running
        var date = Date()
        /// Bytes on disk, and in all (0 when the site did not say).
        var received: Int64 = 0
        var total: Int64 = 0
        /// Bytes a second, smoothed; 0 until there are samples enough to say.
        var speed: Double = 0
        /// Why it stopped, for a failed row, in words.
        var problem: String?
        /// A finished file that is no longer where it was put.
        var missing = false
        /// The site cannot go on from the middle: only a Restart is left.
        var restartOnly = false
        /// From a private tab: never written down.
        let isPrivate: Bool

        @ObservationIgnored weak var download: WKDownload?
        /// The view that started it, to go on in the same session.
        @ObservationIgnored weak var web: WKWebView?
        @ObservationIgnored var request: URLRequest?
        @ObservationIgnored var resumeData: Data?
        @ObservationIgnored var intent: Intent = .none
        /// Resumed, and nothing has arrived yet: a failure now is the site
        /// refusing to go on from the middle.
        @ObservationIgnored var resumed = false
        /// Woken when it is no longer running or paused (the agent's `download` waits for that).
        @ObservationIgnored let ended = Waiters()
        @ObservationIgnored var watching: [NSKeyValueObservation] = []
        @ObservationIgnored var sampled: (at: UInt64, bytes: Int64)?
        @ObservationIgnored var sampledFor = 0.0

        init(id: UUID = UUID(), source: URL?, name: String, isPrivate: Bool) {
            self.id = id
            self.source = source
            self.name = name
            self.isPrivate = isPrivate
        }

        var fraction: Double { total > 0 ? min(1, Double(received) / Double(total)) : 0 }
        var isActive: Bool { state == .running || state == .paused }
        /// Something to go on from: Resume rather than Retry.
        var canResume: Bool { resumeData != nil && (state == .paused || state == .failed) }
        /// A restart from the beginning is possible.
        var canRetry: Bool { source != nil && (state == .failed || state == .cancelled || (state == .paused && resumeData == nil)) }
    }

    private(set) var items: [Item] = []

    var running: Int { items.filter { $0.state == .running }.count }
    var paused: Int { items.filter { $0.state == .paused }.count }

    /// How far along the downloads in hand are, together: by bytes when every
    /// one says its size, else the mean of their fractions. Nil when none.
    var aggregate: (fraction: Double, running: Bool)? {
        let active = items.filter(\.isActive)
        guard !active.isEmpty else { return nil }
        let fraction: Double
        if active.allSatisfy({ $0.total > 0 }) {
            fraction = Double(active.reduce(0) { $0 + $1.received }) / Double(active.reduce(0) { $0 + $1.total })
        } else {
            fraction = active.map(\.fraction).reduce(0, +) / Double(active.count)
        }
        return (min(1, fraction), active.contains { $0.state == .running })
    }

    @ObservationIgnored private lazy var saver = Store.Debounced(after: 1) { [weak self] in
        self?.writeRecords()
    }

    private override init() {
        super.init()
        items = (Store.read("downloads.json", as: [Record].self) ?? []).prefix(Downloads.kept + 20).map(\.item)
        // Off the main thread: a file on a drive that is gone can stall.
        let finished = items.filter { $0.state == .finished }
        let paths = finished.compactMap { item in item.file.map { (item.id, $0.path) } }
        DispatchQueue.global(qos: .utility).async {
            let gone = Set(paths.filter { !FileManager.default.fileExists(atPath: $0.1) }.map(\.0))
            guard !gone.isEmpty else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { for item in Downloads.shared.items where gone.contains(item.id) { item.missing = true } } }
        }
    }

    // MARK: - starting

    /// A download the page or the agent started; the delegate is set here.
    func adopt(_ download: WKDownload) {
        download.delegate = self
        let source = download.originalRequest?.url
        let item = Item(source: source, name: source?.lastPathComponent ?? "Download",
                        isPrivate: download.webView.map { !$0.configuration.websiteDataStore.isPersistent } ?? false)
        item.request = download.originalRequest
        item.web = download.webView
        attach(download, to: item)
        items.insert(item, at: 0)
        Dock.update()
    }

    private func attach(_ download: WKDownload, to item: Item) {
        item.download = download
        item.sampled = nil
        item.sampledFor = 0
        item.speed = 0
        item.watching = Downloads.watch(download.progress, id: item.id)
    }

    /// Progress arrives from WebKit as often as data does; what the rows and
    /// the Dock need is a few times a second, so the rest is dropped before
    /// it costs a hop to the main thread.
    nonisolated private static func watch(_ progress: Progress, id: UUID) -> [NSKeyValueObservation] {
        let last = OSAllocatedUnfairLock(initialState: UInt64(0))
        let take = { (progress: Progress) in
            let now = DispatchTime.now().uptimeNanoseconds
            let due = last.withLock { at in
                guard now &- at >= 250_000_000 else { return false }
                at = now
                return true
            }
            guard due else { return }
            let bytes = progress.completedUnitCount, total = progress.totalUnitCount
            DispatchQueue.main.async { MainActor.assumeIsolated { Downloads.shared.sample(id, bytes: bytes, total: total, at: now) } }
        }
        return [progress.observe(\.completedUnitCount) { progress, _ in take(progress) }]
    }

    /// Bytes and time make a rate; it is smoothed over about three seconds so
    /// that a stall or a burst does not make the figure jump.
    private func sample(_ id: UUID, bytes: Int64, total: Int64, at now: UInt64) {
        guard let item = items.first(where: { $0.id == id }), item.state == .running, item.download != nil else { return }
        if item.resumed, bytes > item.received { item.resumed = false }
        if total > 0 { item.total = total }
        if let previous = item.sampled, now > previous.at, bytes >= previous.bytes {
            let seconds = Double(now - previous.at) / 1e9
            let rate = Double(bytes - previous.bytes) / seconds
            let blend = item.speed == 0 ? 1 : 1 - exp(-seconds / 3)
            item.speed += blend * (rate - item.speed)
            item.sampledFor += seconds
        }
        item.sampled = (now, bytes)
        item.received = bytes
        Dock.update()
    }

    private func item(for download: WKDownload) -> Item? {
        items.first { $0.download === download }
    }

    // MARK: - WKDownloadDelegate

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String, completionHandler: @escaping @MainActor (URL?) -> Void) {
        let item = item(for: download)
        Debug.log("download", "destination asked for \(suggestedFilename); the item has \(item?.file?.path ?? "none")")
        // Going on from where it stopped: the same file, not a second one.
        if let item, let file = item.file {
            return completionHandler(file)
        }
        let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let destination = Downloads.free(in: folder, named: suggestedFilename)
        if let item {
            item.file = destination
            item.name = destination.lastPathComponent
            let length = response.expectedContentLength
            if length > 0 { item.total = length }
        }
        completionHandler(destination)
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let item = item(for: download) else { return }
        Debug.log("download", "finished \(item.name)")
        item.watching = []
        item.state = .finished
        item.resumeData = nil
        item.resumed = false
        item.speed = 0
        item.date = Date()
        if let file = item.file {
            let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int64) ?? nil
            if let size { item.received = size; item.total = size }
            else { item.received = max(item.received, item.total) }
            DistributedNotificationCenter.default().post(name: .init("com.apple.DownloadFileFinished"), object: file.path)
        }
        item.ended.wake()
        changed()
    }

    func download(_ download: WKDownload, didFailWithError error: any Error, resumeData: Data?) {
        guard let item = item(for: download) else { return }
        let code = (error as NSError).code
        Debug.log("download", "\(item.name) ended with \(error.localizedDescription) (\((error as NSError).domain) \(code)); resume data \(resumeData.map { "\($0.count) bytes" } ?? "none"); intent \(item.intent)")
        guard item.download === download else { return }
        item.watching = []
        item.speed = 0
        switch item.intent {
        case .pause, .quit:
            // The cancel's own completion handler settles it.
            if item.state == .running { settle(item, paused: resumeData) }
        case .cancel:
            if item.state == .running { discard(resumeData ?? item.resumeData, of: item) }
        case .none:
            guard item.state == .running else { break }
            let refused = item.resumed && resumeData == nil
            item.resumeData = resumeData
            item.state = code == NSURLErrorCancelled ? .cancelled : .failed
            item.problem = refused ? Downloads.cannotGoOn : Downloads.explain(error)
            item.restartOnly = refused
            if refused || resumeData == nil { Downloads.removeLeftovers(of: item, resumeData: nil) }
            item.ended.wake()
        }
        item.download = nil
        changed()
    }

    // MARK: - pause, resume, cancel, retry

    func pause(_ item: Item) {
        guard item.state == .running, let download = item.download else { return }
        item.intent = .pause
        Debug.log("download", "pause \(item.name) at \(item.received)")
        download.cancel { [weak self, weak item] data in
            guard let self, let item, item.intent == .pause else { return }
            self.settle(item, paused: data)
        }
    }

    /// Stopped by a pause (or a quit): kept if WebKit gave something to go on
    /// from, otherwise said plainly to be unable to.
    private func settle(_ item: Item, paused data: Data?) {
        guard item.state == .running else { return }
        item.intent = .none
        item.download = nil
        item.watching = []
        item.speed = 0
        if let data {
            item.resumeData = data
            item.state = .paused
            item.problem = nil
            Debug.log("download", "paused \(item.name): resume data \(data.count) bytes; \(Downloads.describe(data))")
        } else {
            item.resumeData = nil
            item.state = .failed
            item.problem = Downloads.cannotGoOn
            item.restartOnly = true
            Downloads.removeLeftovers(of: item, resumeData: nil)
            item.ended.wake()
        }
        changed()
    }

    func resume(_ item: Item) {
        guard item.canResume, let data = item.resumeData else { return }
        item.state = .running
        item.problem = nil
        item.restartOnly = false
        item.intent = .none
        item.resumed = true
        item.speed = 0
        item.sampled = nil
        Debug.log("download", "resume \(item.name) from \(item.received)")
        let host = web(for: item)
        Debug.log("download", "resuming on \(host.url?.absoluteString ?? "a blank view"), in a window: \(host.window != nil), private store: \(!host.configuration.websiteDataStore.isPersistent)")
        host.resumeDownload(fromResumeData: data) { [weak self, weak item] download in
            guard let self, let item else { return }
            download.delegate = self
            self.attach(download, to: item)
            Debug.log("download", "resumed \(item.name); progress \(download.progress.completedUnitCount) of \(download.progress.totalUnitCount)")
        }
        changed()
    }

    func cancel(_ item: Item) {
        switch item.state {
        case .running:
            guard let download = item.download else { return }
            item.intent = .cancel
            download.cancel { [weak self, weak item] data in
                guard let self, let item, item.intent == .cancel, item.state == .running else { return }
                self.discard(data ?? item.resumeData, of: item)
                self.changed()
            }
        case .paused:
            discard(item.resumeData, of: item)
            changed()
        default:
            break
        }
    }

    /// The partial file goes with it.
    private func discard(_ data: Data?, of item: Item) {
        Downloads.removeLeftovers(of: item, resumeData: data)
        item.intent = .none
        item.download = nil
        item.watching = []
        item.resumeData = nil
        item.speed = 0
        item.state = .cancelled
        item.problem = nil
        item.ended.wake()
    }

    /// From the beginning, on the page's own session where it is still there.
    func retry(_ item: Item) {
        guard item.canRetry, let source = item.source else { return }
        Downloads.removeLeftovers(of: item, resumeData: item.resumeData)
        let request = item.request ?? URLRequest(url: source)
        item.resumeData = nil
        item.file = nil
        item.received = 0
        item.total = 0
        item.speed = 0
        item.problem = nil
        item.restartOnly = false
        item.intent = .none
        item.resumed = false
        item.state = .running
        item.date = Date()
        let host = web(for: item)
        host.startDownload(using: request) { [weak self, weak item] download in
            guard let self, let item else { return }
            download.delegate = self
            self.attach(download, to: item)
            if item.web == nil { item.web = download.webView }
        }
        changed()
    }

    /// Before quitting: what is running is paused, so it can go on next time.
    /// `done` is called when WebKit has answered, or after a second if it has not.
    func pauseForQuit(then done: @escaping () -> Void) {
        let running = items.filter { $0.state == .running && $0.download != nil && !$0.isPrivate }
        guard !running.isEmpty else { flush(); return done() }
        var left = running.count
        var finished = false
        let finish = { [self] in
            guard !finished else { return }
            finished = true
            flush()
            done()
        }
        for item in running {
            item.intent = .quit
            item.download?.cancel { [weak self, weak item] data in
                MainActor.assumeIsolated {
                    if let self, let item, item.intent == .quit { self.settle(item, paused: data) }
                    left -= 1
                    if left == 0 { finish() }
                }
            }
        }
        // WebKit is meant to answer; if it never does, quitting still must.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { finish() }
    }

    func remove(_ item: Item) {
        if item.isActive { cancel(item) }
        items.removeAll { $0 === item }
        changed()
    }

    /// Everything that is not running or paused leaves the list.
    func clearFinished() {
        items.removeAll { !$0.isActive }
        changed()
    }

    // MARK: - the web view to go on with

    /// The view that started it if it is still there; else one of the same
    /// kind of session (a private tab's own store, or the ordinary one); else
    /// a blank one made for the purpose.
    private func web(for item: Item) -> WKWebView {
        if let web = item.web { return web }
        let persistent = !item.isPrivate
        func fits(_ web: WKWebView) -> Bool { web.configuration.websiteDataStore.isPersistent == persistent }
        let windows = (Windows.front.map { [$0] } ?? []) + Windows.all
        for window in windows {
            for tab in [window.shell.selected].compactMap({ $0 }) + window.shell.tabs {
                if let web = tab.webView, tab.isPrivate == item.isPrivate, fits(web) { item.web = web; return web }
            }
        }
        if let host = hosts[item.isPrivate] { return host }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = persistent ? .default() : (Web.privateStore ?? .nonPersistent())
        config.applicationNameForUserAgent = Web.userAgentName
        let host = WKWebView(frame: .zero, configuration: config)
        hosts[item.isPrivate] = host
        return host
    }

    /// Blank views made when no tab could go on with a download; let go once
    /// nothing is running.
    @ObservationIgnored private var hosts: [Bool: WKWebView] = [:]

    // MARK: - keeping

    /// Something about a download changed that is worth writing down and
    /// showing on the Dock tile.
    private func changed() {
        if !hosts.isEmpty, running == 0 { hosts = [:] }
        saver.poke()
        Dock.update()
    }

    func flush() { saver.flush() }

    /// The last hundred finished, with the paused ones (and those with
    /// something to go on from) kept as they are.
    static let kept = 100

    private struct Record: Codable {
        var id: UUID
        var source: URL?
        var name: String
        var file: String?
        var date: Date
        var paused: Bool
        var resumeData: Data?
        var received: Int64
        var total: Int64

        init(_ item: Item) {
            id = item.id
            source = item.source
            name = item.name
            file = item.file?.path
            date = item.date
            paused = item.state != .finished
            resumeData = item.resumeData
            received = item.received
            total = item.total
        }

        var item: Item {
            let item = Item(id: id, source: source, name: name, isPrivate: false)
            item.file = file.map { URL(fileURLWithPath: $0) }
            item.date = date
            item.received = received
            item.total = total
            item.state = paused ? .paused : .finished
            item.resumeData = resumeData
            return item
        }
    }

    private func writeRecords() {
        var finished = 0
        let records = items.compactMap { item -> Record? in
            guard !item.isPrivate else { return nil }
            switch item.state {
            case .paused where item.resumeData != nil, .failed where item.resumeData != nil: return Record(item)
            case .finished:
                finished += 1
                return finished <= Downloads.kept ? Record(item) : nil
            default: return nil
            }
        }
        Store.write(records, to: "downloads.json")
    }

    // MARK: - words and files

    static let cannotGoOn = "This site can't continue a download. Restart begins it again."

    /// A failure in plain words.
    static func explain(_ error: any Error) -> String {
        switch (error as NSError).code {
        case NSURLErrorNotConnectedToInternet, NSURLErrorDataNotAllowed: return "There is no internet connection."
        case NSURLErrorTimedOut: return "The site took too long to answer."
        case NSURLErrorNetworkConnectionLost: return "The connection was lost."
        case NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost, NSURLErrorDNSLookupFailed: return "The site could not be reached."
        case NSURLErrorFileDoesNotExist, NSURLErrorResourceUnavailable: return "The file is no longer there."
        case NSURLErrorUserAuthenticationRequired, NSURLErrorNoPermissionsToReadFile: return "The site would not give the file."
        case NSURLErrorCannotWriteToFile, NSURLErrorCannotCreateFile: return "The file could not be written."
        default: return "The download did not finish."
        }
    }

    /// What WebKit keeps for a paused download: the resume data is a property
    /// list naming the partial file.
    static func describe(_ data: Data) -> String {
        guard let plist = parse(data) else { return "not a property list" }
        return plist.map { key, value in
            let text = value is Data ? "(\((value as! Data).count) bytes)" : "\(value)".prefix(160)
            return "\(key)=\(text)"
        }.sorted().joined(separator: "; ")
    }

    private static func parse(_ data: Data) -> [String: Any]? {
        if let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] {
            return plist
        }
        return nil
    }

    /// Files WebKit left for this download: the partial file the resume data
    /// points at, and the placeholder at the destination.
    static func removeLeftovers(of item: Item, resumeData: Data?) {
        var paths: Set<String> = []
        if let data = resumeData ?? item.resumeData, let plist = parse(data) {
            for key in ["NSURLSessionResumeInfoLocalPath", "NSURLSessionResumeInfoTempFileName"] {
                if let path = plist[key] as? String, path.hasPrefix("/") { paths.insert(path) }
            }
        }
        if let file = item.file, item.state != .finished { paths.insert(file.path) }
        for path in paths {
            Debug.log("download", "removing \(path)")
            try? FileManager.default.removeItem(atPath: path)
        }
    }

    /// "report.pdf", then "report 2.pdf", "report 3.pdf"…
    static func free(in folder: URL, named name: String) -> URL {
        let safe = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let base = (safe as NSString).deletingPathExtension
        let ext = (safe as NSString).pathExtension
        var candidate = folder.appendingPathComponent(safe.isEmpty ? "download" : safe)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            n += 1
        }
        return candidate
    }
}

// MARK: - how a download is described

extension Downloads.Item {
    private static let sizes: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    static func bytes(_ count: Int64) -> String { sizes.string(fromByteCount: count) }

    /// "42 MB of 200 MB", or "42 MB" when the site did not say how large it is.
    var sizeText: String? {
        if total > 0, isActive { return "\(Downloads.Item.bytes(received)) of \(Downloads.Item.bytes(total))" }
        if received > 0, isActive { return Downloads.Item.bytes(received) }
        if total > 0 { return Downloads.Item.bytes(total) }
        return nil
    }

    /// "1 min left": rounded up, so it never says less than it takes.
    static func timeLeft(_ seconds: Double) -> String {
        if seconds < 10 { return "a few seconds left" }
        if seconds < 60 { return "\(Int((seconds / 5).rounded(.up)) * 5) sec left" }
        let minutes = Int((seconds / 60).rounded(.up))
        if minutes < 60 { return "\(minutes) min left" }
        return minutes % 60 == 0 ? "\(minutes / 60) hr left" : "\(minutes / 60) hr \(minutes % 60) min left"
    }

    /// Speed and time left, once a few seconds of samples say something steady.
    var paceText: String? {
        guard state == .running, speed > 1, sampledFor >= 1 else { return nil }
        var text = "\(Downloads.Item.bytes(Int64(speed)))/s"
        if total > received, sampledFor >= 2 { text += " · " + Downloads.Item.timeLeft(Double(total - received) / speed) }
        return text
    }

    /// Where it came from, short.
    var sourceText: String? {
        guard let source else { return nil }
        return source.host() ?? source.scheme
    }

    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()

    private static let day: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .none
        formatter.dateStyle = .medium
        return formatter
    }()

    var dateText: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return Downloads.Item.clock.string(from: date) }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        return Downloads.Item.day.string(from: date)
    }

    /// The line under the name, in the panel and the popover.
    var statusText: String {
        switch state {
        case .running:
            if let pace = paceText { return [sizeText, pace].compactMap { $0 }.joined(separator: " · ") }
            return sizeText ?? "Starting"
        case .paused:
            return ["Paused", sizeText].compactMap { $0 }.joined(separator: " · ")
        case .finished:
            return [missing ? "Moved or deleted" : sizeText, sourceText, dateText].compactMap { $0 }.joined(separator: " · ")
        case .failed:
            return problem ?? "The download did not finish."
        case .cancelled:
            return "Cancelled"
        }
    }
}

// MARK: - the Dock tile

/// While downloads run, the Dock icon carries a bar for how far along they are
/// together. Redrawn only when the whole percent changes.
enum Dock {
    private static var view: ProgressTile?
    private static var shown = -1

    static func update() {
        let running = Downloads.shared.running > 0 ? Downloads.shared.aggregate : nil
        guard let running else {
            guard view != nil else { return }
            view = nil
            shown = -1
            NSApp.dockTile.contentView = nil
            NSApp.dockTile.display()
            return
        }
        let percent = Int(running.fraction * 100)
        guard percent != shown else { return }
        shown = percent
        if view == nil {
            let tile = ProgressTile(frame: NSRect(origin: .zero, size: NSApp.dockTile.size))
            view = tile
            NSApp.dockTile.contentView = tile
        }
        view?.fraction = running.fraction
        NSApp.dockTile.display()
    }

    final class ProgressTile: NSView {
        var fraction = 0.0

        override func draw(_ dirtyRect: NSRect) {
            NSApp.applicationIconImage.draw(in: bounds)
            let width = bounds.width * 0.74, height = max(6, bounds.height * 0.085)
            let track = NSRect(x: (bounds.width - width) / 2, y: bounds.height * 0.07, width: width, height: height)
            NSColor.black.withAlphaComponent(0.55).setFill()
            NSBezierPath(roundedRect: track, xRadius: height / 2, yRadius: height / 2).fill()
            let filled = NSRect(x: track.minX + 1, y: track.minY + 1, width: max(height - 2, (width - 2) * fraction), height: height - 2)
            NSColor.white.setFill()
            NSBezierPath(roundedRect: filled, xRadius: (height - 2) / 2, yRadius: (height - 2) / 2).fill()
        }
    }
}
