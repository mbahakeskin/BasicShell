import AppKit
import Observation
import WebKit

// Downloads go to ~/Downloads under the name the site gave, never over an
// existing file. The Downloads panel lists this session's, with their
// progress; a finished file bounces the Downloads stack in the Dock.
@Observable
final class Downloads: NSObject, WKDownloadDelegate {
    static let shared = Downloads()

    @Observable
    final class Item: Identifiable {
        enum State { case running, finished, failed, cancelled }
        let id = UUID()
        let source: URL?
        var file: URL?
        var name: String
        var fraction: Double = 0
        var state: State = .running
        @ObservationIgnored weak var download: WKDownload?
        @ObservationIgnored var watching: NSKeyValueObservation?

        init(source: URL?, name: String) {
            self.source = source
            self.name = name
        }
    }

    private(set) var items: [Item] = []

    var running: Int { items.filter { $0.state == .running }.count }

    func adopt(_ download: WKDownload) {
        download.delegate = self
        let item = Item(source: download.originalRequest?.url, name: download.originalRequest?.url?.lastPathComponent ?? "Download")
        item.download = download
        item.watching = download.progress.observe(\.fractionCompleted) { progress, _ in
            let value = progress.fractionCompleted
            DispatchQueue.main.async { item.fraction = value }
        }
        items.insert(item, at: 0)
    }

    private func item(for download: WKDownload) -> Item? {
        items.first { $0.download === download }
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String, completionHandler: @escaping @MainActor (URL?) -> Void) {
        let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let destination = Downloads.free(in: folder, named: suggestedFilename)
        if let item = item(for: download) {
            item.file = destination
            item.name = destination.lastPathComponent
        }
        completionHandler(destination)
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let item = item(for: download) else { return }
        item.state = .finished
        item.fraction = 1
        item.watching = nil
        if let file = item.file {
            DistributedNotificationCenter.default().post(name: .init("com.apple.DownloadFileFinished"), object: file.path)
        }
    }

    func download(_ download: WKDownload, didFailWithError error: any Error, resumeData: Data?) {
        guard let item = item(for: download) else { return }
        if item.state == .running { item.state = (error as NSError).code == NSURLErrorCancelled ? .cancelled : .failed }
        item.watching = nil
    }

    func cancel(_ item: Item) {
        item.state = .cancelled
        item.download?.cancel { _ in }
    }

    func clearFinished() {
        items.removeAll { $0.state != .running }
    }

    /// "report.pdf", then "report 2.pdf", "report 3.pdf"…
    private static func free(in folder: URL, named name: String) -> URL {
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
