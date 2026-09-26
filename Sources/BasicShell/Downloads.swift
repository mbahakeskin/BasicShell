import AppKit
import WebKit

// Downloads go to ~/Downloads under the name the site gave, never over an
// existing file. The list and its panel come later; for now a finished file
// bounces the Downloads stack in the Dock.
final class Downloads: NSObject, WKDownloadDelegate {
    static let shared = Downloads()

    private var active: [WKDownload: URL] = [:]

    func adopt(_ download: WKDownload) {
        download.delegate = self
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String, completionHandler: @escaping @MainActor (URL?) -> Void) {
        let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let destination = Downloads.free(in: folder, named: suggestedFilename)
        active[download] = destination
        completionHandler(destination)
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let file = active.removeValue(forKey: download) else { return }
        DistributedNotificationCenter.default().post(name: .init("com.apple.DownloadFileFinished"), object: file.path)
    }

    func download(_ download: WKDownload, didFailWithError error: any Error, resumeData: Data?) {
        active.removeValue(forKey: download)
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
