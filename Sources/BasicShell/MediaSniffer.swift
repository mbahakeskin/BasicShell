import AppKit
import WebKit

// What a page loaded that looks like a video, for the download button on a
// site that sends its videos in pieces (a `blob:` address: nothing to save in
// the page itself).
//
// WebKit has no webRequest, as Chrome's extensions have; its private
// `_resourceLoadDelegate` reports every request a page makes, and what came
// back, without anything put into the page. Kept per tab, and only for the
// sites listed in Settings (MediaDownload.swift), since it makes WebKit tell
// us about every load. What it keeps is only the address, the kind of file,
// its size and who asked, of what looks like video or audio: playlists
// (HLS's .m3u8, DASH's .mpd) and media files, however they are asked for, in
// ranges or whole. Nothing is read of what came back.
@MainActor
final class MediaSniffer: NSObject {
    struct Seen {
        let url: URL
        /// The address with what picks a piece of the file (bytestart, range…) taken off: the whole file.
        let whole: URL
        let mime: String
        /// The size of the whole file, when the answer said it.
        let size: Int64
        let referer: URL?
        let at: Date
        var isPlaylist: Bool { mime.contains("mpegurl") || url.pathExtension.lowercased() == "m3u8" }
        var isManifest: Bool { mime.contains("dash+xml") || url.pathExtension.lowercased() == "mpd" }
    }

    private(set) var seen: [Seen] = []
    private var requests: [UInt64: URLRequest] = [:]
    private static let limit = 200

    /// Query items that pick a part of a file: what is left names the file.
    private static let pieces: Set<String> = ["bytestart", "byteend", "range", "rn", "rbuf", "start", "end", "offset"]
    private static let extensions: Set<String> = ["m3u8", "mpd", "mp4", "m4v", "m4a", "webm", "mov", "mkv"]

    // MARK: - WebKit's calls

    @objc(webView:resourceLoad:didSendRequest:)
    nonisolated func webView(_ web: WKWebView, resourceLoad info: AnyObject, didSendRequest request: URLRequest) {
        guard let id = (info.value(forKey: "resourceLoadID") as? NSNumber)?.uint64Value else { return }
        DispatchQueue.main.async { [self] in MainActor.assumeIsolated {
            // Only what could be a video is kept at all.
            guard let url = request.url, ["http", "https"].contains(url.scheme ?? "") else { return }
            requests[id] = request
            if requests.count > 400 { requests.removeAll(keepingCapacity: true) }
        } }
    }

    @objc(webView:resourceLoad:didReceiveResponse:)
    nonisolated func webView(_ web: WKWebView, resourceLoad info: AnyObject, didReceiveResponse response: URLResponse) {
        let id = (info.value(forKey: "resourceLoadID") as? NSNumber)?.uint64Value
        DispatchQueue.main.async { [self] in MainActor.assumeIsolated {
            let request = id.flatMap { requests.removeValue(forKey: $0) }
            guard let http = response as? HTTPURLResponse, [200, 206].contains(http.statusCode), let url = http.url else { return }
            let mime = (http.mimeType ?? "").lowercased()
            let ext = url.pathExtension.lowercased()
            let media = mime.hasPrefix("video/") || mime.hasPrefix("audio/") || mime.contains("mpegurl") || mime.contains("dash+xml")
            guard media || MediaSniffer.extensions.contains(ext) else { return }
            // Segments of a playlist are what the playlist is for; a few
            // kilobytes of anything else is an icon or a probe.
            if ["ts", "m4s", "aac", "mp3"].contains(ext) { return }
            let playlist = mime.contains("mpegurl") || mime.contains("dash+xml") || ["m3u8", "mpd"].contains(ext)
            var size = http.expectedContentLength
            if let range = http.value(forHTTPHeaderField: "Content-Range"), let total = range.split(separator: "/").last, let n = Int64(total) { size = n }
            if !playlist, size >= 0, size < 50_000 { return }
            let referer = request?.value(forHTTPHeaderField: "Referer").flatMap(URL.init(string:))
            seen.append(Seen(url: url, whole: MediaSniffer.whole(url), mime: mime, size: size, referer: referer, at: Date()))
            if seen.count > MediaSniffer.limit { seen.removeFirst(seen.count - MediaSniffer.limit) }
        } }
    }

    static func whole(_ url: URL) -> URL {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false), let items = parts.queryItems else { return url }
        let kept = items.filter { !pieces.contains($0.name.lowercased()) }
        parts.queryItems = kept.isEmpty ? nil : kept
        return parts.url ?? url
    }

    // MARK: - what to save

    enum Plan {
        /// A playlist (HLS) to read and download piece by piece.
        case playlist(URL, referer: URL?)
        /// Files that are the video and the sound, or one of them, or both in one.
        case files([URL], referer: URL?)
    }

    func forget() { seen.removeAll(); requests.removeAll() }

    /// What the page last asked for that could be saved: its latest playlist,
    /// or the files it has been reading lately (a video's and a sound's, which
    /// come apart on most sites that stream), whichever is newer.
    func plan() -> Plan? {
        let recent = seen.filter { Date().timeIntervalSince($0.at) < 20 * 60 }
        guard let last = recent.last(where: { !$0.isManifest }) else { return nil }
        if last.isPlaylist {
            // The first of the playlists asked for in the last couple of minutes: the master, with every
            // quality in it, rather than the one the player went on to ask for.
            let first = recent.first { $0.isPlaylist && last.at.timeIntervalSince($0.at) < 120 } ?? last
            return .playlist(first.url, referer: first.referer)
        }
        // The files read in the minute around the last one, each once: the
        // video's and the sound's. The biggest come first.
        let near = recent.filter { !$0.isPlaylist && !$0.isManifest && abs($0.at.timeIntervalSince(last.at)) < 60 }
        var files: [Seen] = []
        for item in near.reversed() where !files.contains(where: { $0.whole == item.whole }) { files.append(item) }
        let chosen = files.sorted { $0.size > $1.size }.prefix(4).map(\.whole)
        return chosen.isEmpty ? nil : .files(Array(chosen), referer: last.referer)
    }
}

extension Tab {
    /// Watches what the page loads, or stops: only on the sites listed for
    /// the download button (see MediaDownload.arm).
    func sniff(_ on: Bool) {
        guard let web = webView else { return }
        let set = NSSelectorFromString("_setResourceLoadDelegate:")
        guard web.responds(to: set) else { return }
        if on {
            guard sniffer == nil else { return }
            let sniffer = MediaSniffer()
            self.sniffer = sniffer
            _ = web.perform(set, with: sniffer)
        } else if sniffer != nil {
            _ = web.perform(set, with: nil)
            sniffer = nil
        }
    }
}
