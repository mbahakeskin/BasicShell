import AVFoundation
import AppKit
import CommonCrypto
import WebKit

// Saves a video a site sends in pieces, from what MediaSniffer saw it load:
// a playlist (HLS) is read and its pieces fetched, put end to end, and
// the sound that comes apart from the picture is put back with it; files
// (the picture's and the sound's, as most sites that stream keep them) are
// fetched whole and joined the same way. The Mac does the joining
// (AVFoundation, no copy of the data: a track of one file is put beside a
// track of the other), so nothing is installed.
//
// It fetches as the page would, on its own session: the page's cookies, its
// referrer and its user agent. What is protected by DRM isn't touched, and
// neither is a stream that has no end (a live one).
@MainActor
final class StreamSaver {
    enum Failure: Error, LocalizedError {
        case nothing, live, drm, parts, cancelled, format(String)

        var errorDescription: String? {
            switch self {
            case .nothing: "Nothing to save yet: play the video for a moment, then try again"
            case .live: "A live stream has no end to save"
            case .drm: "This video is protected and can't be saved"
            case .parts: "Some of the video's pieces couldn't be fetched"
            case .cancelled: "Cancelled"
            case .format(let why): "Couldn't put the video together (\(why))"
            }
        }
    }

    private let web: WKWebView
    private let page: URL?
    private let name: String
    private let isPrivate: Bool
    private let directory: URL
    private var headers: [String: String] = [:]
    private let session = URLSession(configuration: .ephemeral)
    private var item: Downloads.Item?
    private var received: Int64 = 0

    private init(web: WKWebView, page: URL?, name: String, isPrivate: Bool) {
        self.web = web
        self.page = page
        self.name = name
        self.isPrivate = isPrivate
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("BasicShellStream-\(UUID().uuidString)", isDirectory: true)
    }

    /// From the click on the button: the plan MediaSniffer has, carried out,
    /// with a row in the Downloads panel and a word when it is done.
    static func save(_ plan: MediaSniffer.Plan, from tab: Tab, in window: BrowserWindow?) {
        guard let web = tab.webView else { return }
        let referer: URL?
        switch plan {
        case .playlist(_, let r), .files(_, let r): referer = r
        }
        let saver = StreamSaver(web: web, page: referer ?? web.url, name: Self.fileName(for: tab), isPrivate: tab.isPrivate)
        let item = Downloads.shared.track(name: saver.name, source: web.url, isPrivate: tab.isPrivate)
        saver.item = item
        let task = Task { @MainActor in
            do {
                let file = try await saver.run(plan)
                Downloads.shared.finish(item, file: file)
                window?.say("Saved \(file.lastPathComponent)", actions: [
                    Toast.Action(title: "Show", symbol: "magnifyingglass", help: "Show in Finder", label: "Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([file])
                    }
                ])
            } catch {
                let cancelled = error is CancellationError || (error as? Failure).map { if case .cancelled = $0 { true } else { false } } == true
                Downloads.shared.fail(item, problem: cancelled ? nil : error.localizedDescription)
                if !cancelled { window?.say(error.localizedDescription) }
            }
            try? FileManager.default.removeItem(at: saver.directory)
        }
        item.onCancel = { task.cancel() }
        window?.say("Saving the video…")
    }

    /// Whether an address, though it has no ".m3u8" and isn't a blob, is an HLS
    /// playlist: players hand a `<video>` such an address, which WebKit plays
    /// itself. The first bytes say.
    static func isPlaylist(_ url: URL, page: URL?, in tab: Tab) async -> Bool {
        guard let web = tab.webView else { return false }
        let probe = StreamSaver(web: web, page: page ?? web.url, name: "", isPrivate: tab.isPrivate)
        let agent = (try? await web.evaluateJavaScript("navigator.userAgent")) as? String
        probe.headers["User-Agent"] = agent ?? ""
        if let page = probe.page { probe.headers["Referer"] = page.absoluteString }
        guard let (data, response) = try? await probe.session.data(for: await probe.request(url, range: (0, 511))),
              (response as? HTTPURLResponse).map({ [200, 206].contains($0.statusCode) }) ?? true
        else { return false }
        return String(decoding: data.prefix(64), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines.union(.init(charactersIn: "\u{FEFF}"))).hasPrefix("#EXTM3U")
    }

    private static func fileName(for tab: Tab) -> String {
        let bad = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters)
        let title = tab.title.components(separatedBy: bad).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return title.isEmpty ? "Video" : String(title.prefix(80))
    }

    // MARK: - doing it

    private func run(_ plan: MediaSniffer.Plan) async throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let agent = (try? await web.evaluateJavaScript("navigator.userAgent")) as? String
        headers["User-Agent"] = agent ?? ""
        if let page { headers["Referer"] = page.absoluteString }
        let files: [URL]
        switch plan {
        case .playlist(let url, _): files = try await fetchPlaylist(url)
        case .files(let urls, _): files = try await fetchFiles(urls)
        }
        try Task.checkCancellation()
        let output = try await Mux.join(files, in: directory)
        let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let destination = Downloads.free(in: folder, named: "\(name).\(output.pathExtension)")
        try FileManager.default.moveItem(at: output, to: destination)
        return destination
    }

    /// A request as the page would make it: its cookies for that address, its
    /// referrer, its user agent.
    private func request(_ url: URL, range: (Int64, Int64?)? = nil) async -> URLRequest {
        var request = URLRequest(url: url)
        for (key, value) in headers where !value.isEmpty { request.setValue(value, forHTTPHeaderField: key) }
        let cookies = await web.configuration.websiteDataStore.httpCookieStore.allCookies().filter { cookie in
            guard let host = url.host()?.lowercased() else { return false }
            let domain = cookie.domain.lowercased().drop { $0 == "." }
            return host == domain || host.hasSuffix("." + domain)
        }
        for (key, value) in HTTPCookie.requestHeaderFields(with: cookies) { request.setValue(value, forHTTPHeaderField: key) }
        if let range { request.setValue("bytes=\(range.0)-\(range.1.map(String.init) ?? "")", forHTTPHeaderField: "Range") }
        return request
    }

    private func progress(_ bytes: Int64, total: Int64? = nil) {
        received += bytes
        guard let item else { return }
        if let total, total > item.total { item.total = total }
        item.received = received
        if item.total < received { item.total = 0 }
        Downloads.shared.touch()
    }

    private func get(_ url: URL, range: (Int64, Int64?)? = nil) async throws -> Data {
        try Task.checkCancellation()
        var last: Error = Failure.parts
        for attempt in 0..<3 {
            do {
                let (data, response) = try await session.data(for: await request(url, range: range))
                if let http = response as? HTTPURLResponse, ![200, 206].contains(http.statusCode) { throw Failure.parts }
                return data
            } catch {
                last = error
                try Task.checkCancellation()
                try? await Task.sleep(for: .milliseconds(400 * (attempt + 1)))
            }
        }
        throw last
    }

    /// A whole file, to disk, with how far it has got.
    private func download(_ url: URL, as file: URL) async throws {
        try Task.checkCancellation()
        let req = await request(url)
        let box = TaskBox()
        let watcher = Watcher { [weak self] bytes in DispatchQueue.main.async { MainActor.assumeIsolated { self?.progress(bytes) } } }
        defer { watcher.stop() }
        let temporary: URL = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = session.downloadTask(with: req) { location, response, error in
                    if let error { return continuation.resume(throwing: error) }
                    guard let location, (response as? HTTPURLResponse).map({ [200, 206].contains($0.statusCode) }) ?? true else {
                        return continuation.resume(throwing: Failure.parts)
                    }
                    // The system removes it when this returns.
                    let kept = location.deletingLastPathComponent().appendingPathComponent("kept-\(UUID().uuidString)")
                    do { try FileManager.default.moveItem(at: location, to: kept); continuation.resume(returning: kept) }
                    catch { continuation.resume(throwing: error) }
                }
                box.task = task
                watcher.start(task.progress)
                task.resume()
            }
        } onCancel: { box.task?.cancel() }
        try? FileManager.default.removeItem(at: file)
        try FileManager.default.moveItem(at: temporary, to: file)
    }

    // MARK: files

    private func fetchFiles(_ urls: [URL]) async throws -> [URL] {
        var done: [URL] = []
        for (index, url) in urls.enumerated() {
            let ext = url.pathExtension.isEmpty ? "mp4" : url.pathExtension.lowercased()
            let file = directory.appendingPathComponent("file-\(index).\(ext)")
            do { try await download(url, as: file); done.append(file) }
            catch is CancellationError { throw CancellationError() }
            catch { if index == 0 { throw error } }
        }
        return done
    }

    // MARK: playlists

    private func fetchPlaylist(_ url: URL) async throws -> [URL] {
        var playlist = HLS.parse(String(decoding: try await get(url), as: UTF8.self), at: url)
        var audio: HLS.Media?
        if playlist.isMaster {
            guard let best = playlist.variants.max(by: { $0.bandwidth < $1.bandwidth }) else { throw Failure.nothing }
            if let group = best.audio {
                let options = playlist.media.filter { $0.type == "AUDIO" && $0.group == group && $0.url != nil }
                audio = options.first(where: \.isDefault) ?? options.first
            }
            playlist = HLS.parse(String(decoding: try await get(best.url), as: UTF8.self), at: best.url)
            if let total = playlist.duration as Double?, total > 0, let item { item.total = Int64(Double(best.bandwidth) / 8 * total) }
        }
        guard playlist.ended else { throw Failure.live }
        if playlist.encrypted { throw Failure.drm }
        var files = [try await fetchPieces(playlist, as: "video")]
        if let audio, let url = audio.url {
            let list = HLS.parse(String(decoding: try await get(url), as: UTF8.self), at: url)
            if list.ended, !list.encrypted { files.append(try await fetchPieces(list, as: "audio")) }
        }
        return files
    }

    /// The pieces of a media playlist, fetched a few at a time, put end to end in one file.
    private func fetchPieces(_ playlist: HLS.Playlist, as name: String) async throws -> URL {
        let folder = directory.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var fetched: [URL: Data] = [:]
        for key in Set(playlist.segments.compactMap(\.key?.url)) { fetched[key] = try await get(key) }
        let keys = fetched
        var init_: Data?
        if let map = playlist.map { init_ = try await get(map.url, range: map.range) }
        let total = playlist.segments.count
        let segments = playlist.segments
        let slots = 6
        var start = 0
        // A few at a time, each on disk as it comes, so a long video isn't all held at once.
        while start < total {
            let end = min(start + slots, total)
            let tasks = (start..<end).map { index in
                Task { @MainActor in
                    let segment = segments[index]
                    var data = try await self.get(segment.url, range: segment.range)
                    if let key = segment.key, let material = keys[key.url] {
                        data = try Self.decrypt(data, key: material, iv: key.iv ?? Self.iv(segment.sequence))
                    }
                    try data.write(to: folder.appendingPathComponent("piece-\(index)"))
                    return data.count
                }
            }
            do {
                for task in tasks {
                    let size = try await task.value
                    try Task.checkCancellation()
                    progress(Int64(size))
                }
            } catch {
                for task in tasks { task.cancel() }
                throw error
            }
            start = end
        }
        let ext = playlist.map == nil ? "ts" : "mp4"
        let file = folder.appendingPathComponent("\(name).\(ext)")
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        if let init_ { try handle.write(contentsOf: init_) }
        for index in 0..<total {
            let piece = folder.appendingPathComponent("piece-\(index)")
            try handle.write(contentsOf: try Data(contentsOf: piece, options: .mappedIfSafe))
            try? FileManager.default.removeItem(at: piece)
        }
        return file
    }

    private static func iv(_ sequence: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: 16)
        var n = UInt64(sequence)
        for i in stride(from: 15, through: 8, by: -1) { bytes[i] = UInt8(n & 0xff); n >>= 8 }
        return Data(bytes)
    }

    private static func decrypt(_ data: Data, key: Data, iv: Data) throws -> Data {
        var out = Data(count: data.count + kCCBlockSizeAES128)
        var moved = 0
        let status = out.withUnsafeMutableBytes { outBytes in
            data.withUnsafeBytes { inBytes in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                                keyBytes.baseAddress, key.count, ivBytes.baseAddress,
                                inBytes.baseAddress, data.count, outBytes.baseAddress, outBytes.count, &moved)
                    }
                }
            }
        }
        guard status == kCCSuccess else { throw Failure.format("decrypting") }
        return out.prefix(moved)
    }
}

/// A download task, held where the cancel handler can reach it.
private nonisolated final class TaskBox: @unchecked Sendable { var task: URLSessionTask? }

/// Tells how many bytes a download task has taken, as they come.
private nonisolated final class Watcher: @unchecked Sendable {
    private var observation: NSKeyValueObservation?
    private var last: Int64 = 0
    private let report: @Sendable (Int64) -> Void
    init(_ report: @escaping @Sendable (Int64) -> Void) { self.report = report }
    func start(_ progress: Progress) {
        observation = progress.observe(\.completedUnitCount) { [weak self] progress, _ in
            guard let self else { return }
            let now = progress.completedUnitCount
            self.report(now - self.last)
            self.last = now
        }
    }
    func stop() { observation = nil }
}

// MARK: - HLS playlists

enum HLS {
    struct Key { let url: URL; let iv: Data? }
    struct Segment {
        let url: URL
        let range: (Int64, Int64?)?
        let key: Key?
        let sequence: Int
        let duration: Double
    }
    struct Variant { let url: URL; let bandwidth: Int; let audio: String? }
    struct Media {
        let type: String
        let group: String
        let url: URL?
        let isDefault: Bool
    }
    struct Playlist {
        var variants: [Variant] = []
        var media: [Media] = []
        var segments: [Segment] = []
        var map: (url: URL, range: (Int64, Int64?)?)?
        var ended = false
        var encrypted = false
        var isMaster: Bool { !variants.isEmpty }
        var duration: Double { segments.reduce(0) { $0 + $1.duration } }
    }

    /// "KEY=value,KEY2="quoted, value"" as a dictionary.
    static func attributes(_ text: Substring) -> [String: String] {
        var result: [String: String] = [:]
        var key = "", value = "", inKey = true, quoted = false
        func flush() { if !key.isEmpty { result[key.trimmingCharacters(in: .whitespaces)] = value }; key = ""; value = ""; inKey = true }
        for character in text {
            if inKey { if character == "=" { inKey = false } else { key.append(character) } }
            else if character == "\"" { quoted.toggle() }
            else if character == ",", !quoted { flush() }
            else { value.append(character) }
        }
        flush()
        return result
    }

    static func parse(_ text: String, at base: URL) -> Playlist {
        var playlist = Playlist()
        var pending: (bandwidth: Int, audio: String?)?
        var duration = 0.0
        var sequence = 0
        var key: Key?
        var range: (Int64, Int64?)?
        var lastEnd: Int64 = 0
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("#") {
                if line.hasPrefix("#EXT-X-STREAM-INF:") {
                    let a = attributes(line.dropFirst("#EXT-X-STREAM-INF:".count))
                    pending = (Int(a["BANDWIDTH"] ?? "") ?? 0, a["AUDIO"])
                } else if line.hasPrefix("#EXT-X-MEDIA:") {
                    let a = attributes(line.dropFirst("#EXT-X-MEDIA:".count))
                    playlist.media.append(Media(type: a["TYPE"] ?? "", group: a["GROUP-ID"] ?? "", url: a["URI"].flatMap { URL(string: $0, relativeTo: base)?.absoluteURL }, isDefault: a["DEFAULT"] == "YES"))
                } else if line.hasPrefix("#EXT-X-MEDIA-SEQUENCE:") {
                    sequence = Int(line.dropFirst("#EXT-X-MEDIA-SEQUENCE:".count)) ?? 0
                } else if line.hasPrefix("#EXTINF:") {
                    duration = Double(line.dropFirst("#EXTINF:".count).split(separator: ",").first ?? "") ?? 0
                } else if line.hasPrefix("#EXT-X-KEY:") {
                    let a = attributes(line.dropFirst("#EXT-X-KEY:".count))
                    switch a["METHOD"] ?? "NONE" {
                    case "NONE": key = nil
                    case "AES-128":
                        if let uri = a["URI"], let url = URL(string: uri, relativeTo: base)?.absoluteURL {
                            key = Key(url: url, iv: a["IV"].flatMap(hex))
                        }
                    default: playlist.encrypted = true
                    }
                } else if line.hasPrefix("#EXT-X-MAP:") {
                    let a = attributes(line.dropFirst("#EXT-X-MAP:".count))
                    if let uri = a["URI"], let url = URL(string: uri, relativeTo: base)?.absoluteURL {
                        playlist.map = (url, a["BYTERANGE"].flatMap { byteRange($0, previous: 0) })
                    }
                } else if line.hasPrefix("#EXT-X-BYTERANGE:") {
                    range = byteRange(String(line.dropFirst("#EXT-X-BYTERANGE:".count)), previous: lastEnd)
                } else if line == "#EXT-X-ENDLIST" {
                    playlist.ended = true
                }
                continue
            }
            guard let url = URL(string: line, relativeTo: base)?.absoluteURL else { continue }
            if let pending {
                playlist.variants.append(Variant(url: url, bandwidth: pending.bandwidth, audio: pending.audio))
            } else {
                playlist.segments.append(Segment(url: url, range: range, key: key, sequence: sequence, duration: duration))
                if let range, let end = range.1 { lastEnd = range.0 + end - 1 + 1 }
                sequence += 1
            }
            pending = nil
            range = nil
        }
        return playlist
    }

    /// "length@offset" (the offset left out: where the last one ended).
    private static func byteRange(_ text: String, previous: Int64 = 0) -> (Int64, Int64?)? {
        let parts = text.split(separator: "@")
        guard let length = Int64(parts.first ?? "") else { return nil }
        let offset = parts.count > 1 ? Int64(parts[1]) ?? previous : previous
        return (offset, offset + length - 1)
    }

    private static func hex(_ text: String) -> Data? {
        var digits = text.lowercased()
        if digits.hasPrefix("0x") { digits = String(digits.dropFirst(2)) }
        guard digits.count % 2 == 0 else { return nil }
        var data = Data()
        var index = digits.startIndex
        while index < digits.endIndex {
            let next = digits.index(index, offsetBy: 2)
            guard let byte = UInt8(digits[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        return data
    }
}

// MARK: - putting the picture and the sound together

enum Mux {
    /// One file out of those given: the picture's (and its sound if it has
    /// one) with the sound of another where it hasn't. A transport stream
    /// is turned into an mp4 on the way.
    static func join(_ files: [URL], in directory: URL) async throws -> URL {
        var video: (url: URL, asset: AVURLAsset, hasAudio: Bool, size: Int64)?
        var audio: (url: URL, asset: AVURLAsset, size: Int64)?
        for url in files {
            let asset = AVURLAsset(url: url)
            let videos = (try? await asset.loadTracks(withMediaType: .video)) ?? []
            let sounds = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
            if !videos.isEmpty {
                if video == nil || size > video!.size { video = (url, asset, !sounds.isEmpty, size) }
            } else if !sounds.isEmpty {
                if audio == nil || size > audio!.size { audio = (url, asset, size) }
            }
        }
        guard video != nil || audio != nil else { throw StreamSaver.Failure.format("nothing playable was fetched") }
        let output = directory.appendingPathComponent("joined.mp4")
        try? FileManager.default.removeItem(at: output)
        // A picture with its sound already in it, and in a form that is an mp4: as it is.
        if let video, video.hasAudio || audio == nil, video.url.pathExtension.lowercased() == "mp4" {
            return video.url
        }
        if video == nil, let audio {
            // Sound alone: as it came, with the name it should have.
            let ext = audio.url.pathExtension.lowercased() == "mp4" ? "m4a" : audio.url.pathExtension
            let kept = directory.appendingPathComponent("joined.\(ext)")
            try FileManager.default.moveItem(at: audio.url, to: kept)
            return kept
        }
        guard let video else { throw StreamSaver.Failure.format("no picture") }
        let composition = AVMutableComposition()
        func add(_ asset: AVURLAsset, _ type: AVMediaType) async throws {
            guard let source = try await asset.loadTracks(withMediaType: type).first,
                  let track = composition.addMutableTrack(withMediaType: type, preferredTrackID: kCMPersistentTrackID_Invalid)
            else { return }
            let range = try await source.load(.timeRange)
            try track.insertTimeRange(range, of: source, at: .zero)
            if type == .video { track.preferredTransform = try await source.load(.preferredTransform) }
        }
        try await add(video.asset, .video)
        if video.hasAudio { try await add(video.asset, .audio) }
        else if let audio { try await add(audio.asset, .audio) }
        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            throw StreamSaver.Failure.format("the Mac can't write this kind of video")
        }
        do { try await export.export(to: output, as: .mp4) }
        catch {
            // A transport stream the Mac won't turn into an mp4 stays what it is.
            if video.url.pathExtension.lowercased() == "ts", audio == nil {
                let kept = directory.appendingPathComponent("joined.ts")
                try FileManager.default.moveItem(at: video.url, to: kept)
                return kept
            }
            throw StreamSaver.Failure.format(error.localizedDescription)
        }
        return output
    }
}
