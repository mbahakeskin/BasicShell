#if AGENT
import AppKit
import CryptoKit
import Observation

// Updates. A release is BasicShell built with the agent tools (`./build.sh agent`) and put on GitHub as a zip; this checks
// the latest release and, if its version is newer than the one running, downloads it, checks it, and puts it in place of
// this app (see `install`). It is in the build with the agent tools alone, because that is the build the releases are: a
// plain build made from the source would otherwise be turned into one with them.
//
// Which is newer is decided by the version number (0.6.0 against 0.5.3, part by part), not by when either was built: a
// build made on this Mac from the source has its own time, and a release has the time it was made on another.
//
// What is trusted: the release is on github.com (https), and the zip must match the SHA-256 that GitHub gives for the
// file; the app in it must have this app's identifier and the version the release says, and its signature must hold
// together (it is self-signed, so that says nothing of who signed it, only that nothing was changed after).
@Observable
final class Updater: NSObject {
    static let shared = Updater()

    static let checkKey = "update.check"
    static let skipKey = "update.skip"
    static let lastKey = "update.last"
    static let installedKey = "update.installed"
    /// Where the latest release is asked for. Another address (any http or https one) is for trying the updater.
    static let feedKey = "update.feed"
    static let feed = "https://api.github.com/repos/mbahakeskin/BasicShell/releases/latest"

    struct Release {
        let version: String
        let notes: String
        let asset: URL
        let size: Int
        let sha256: String
        let page: URL
    }

    enum State {
        case idle
        case checking
        case upToDate
        case available(Release)
        case downloading(String)
        case failed(String)
    }

    private(set) var state = State.idle

    var current: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }

    var automatic: Bool {
        get { UserDefaults.standard.object(forKey: Updater.checkKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Updater.checkKey) }
    }

    /// What Settings says under the version.
    var status: String {
        switch state {
        case .idle: return ""
        case .checking: return "Checking…"
        case .upToDate: return "BasicShell is up to date."
        case .available(let release): return "\(release.version) is available."
        case .downloading(let version): return "Downloading \(version)…"
        case .failed(let message): return message
        }
    }

    var busy: Bool {
        switch state {
        case .checking, .downloading: return true
        default: return false
        }
    }

    // MARK: - when

    private var timer: Timer?

    /// At launch: a check if one is due (once a day), and the next look is set for when it will be.
    func start() {
        guard automatic else { return }
        let last = UserDefaults.standard.object(forKey: Updater.lastKey) as? Date ?? .distantPast
        let due = last.addingTimeInterval(20 * 3600)
        if due <= Date() {
            Task { await check(manually: false) }
        }
        timer?.invalidate()
        // A day is the grain: this is not a wait for anything. If the Mac was asleep, the next run finds it due.
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.automatic, !self.busy else { return }
                let last = UserDefaults.standard.object(forKey: Updater.lastKey) as? Date ?? .distantPast
                if last.addingTimeInterval(20 * 3600) <= Date() { Task { await self.check(manually: false) } }
            }
        }
    }

    /// Once the windows are back (see AppDelegate.extensionsLoaded): the first run after an update says so.
    func announceIfUpdated() {
        let defaults = UserDefaults.standard
        guard let installed = defaults.string(forKey: Updater.installedKey) else { return }
        defaults.removeObject(forKey: Updater.installedKey)
        if installed == current { Windows.front?.say("Updated to \(installed)") }
    }

    // MARK: - looking

    /// Asks GitHub for the latest release. A person's own request (Check for Updates…) is answered whatever comes; an
    /// automatic one says something only if there is a version newer than the one running, that the person has not
    /// skipped.
    func check(manually: Bool) async {
        guard !busy else { return }
        state = .checking
        do {
            let release = try await Updater.fetch()
            UserDefaults.standard.set(Date(), forKey: Updater.lastKey)
            guard let release, Updater.newer(release.version, than: current) else {
                state = .upToDate
                if manually { Updater.say("BasicShell is up to date", "You have \(current), the latest there is.") }
                return
            }
            state = .available(release)
            let skipped = UserDefaults.standard.string(forKey: Updater.skipKey) == release.version
            if manually || !skipped { offer(release, manually: manually) }
        } catch {
            state = .failed("Couldn't look for an update: \((error as? Failure)?.message ?? error.localizedDescription)")
            if manually { Updater.say("Couldn't look for an update", (error as? Failure)?.message ?? error.localizedDescription) }
        }
    }

    struct Failure: Error { let message: String }

    private static func fetch() async throws -> Release? {
        let override = UserDefaults.standard.string(forKey: feedKey)
        guard let url = URL(string: override ?? feed), url.scheme == "https" || override != nil else { throw Failure(message: "the address is wrong.") }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("BasicShell/\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] ?? "")", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw Failure(message: "GitHub answered \((response as? HTTPURLResponse)?.statusCode ?? 0).")
        }
        return try parse(data)
    }

    /// The latest release's JSON as a Release; nil for one with nothing of ours in it.
    static func parse(_ data: Data) throws -> Release? {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any], let tag = json["tag_name"] as? String else {
            throw Failure(message: "what came back isn't a release.")
        }
        if json["draft"] as? Bool == true || json["prerelease"] as? Bool == true { return nil }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let notes = json["body"] as? String ?? ""
        let assets = json["assets"] as? [[String: Any]] ?? []
        guard let asset = assets.first(where: { ($0["name"] as? String).map { $0.hasPrefix("BasicShell") && $0.hasSuffix(".zip") } == true }),
              let name = asset["name"] as? String, let link = (asset["browser_download_url"] as? String).flatMap(URL.init(string:)) else { return nil }
        // GitHub gives each file's checksum ("sha256:…"); the release's notes may name it too.
        var sum = (asset["digest"] as? String).flatMap { $0.hasPrefix("sha256:") ? String($0.dropFirst(7)) : nil }
        if sum == nil {
            for line in notes.split(separator: "\n") where line.contains(name) || line.lowercased().contains("sha") {
                if let found = line.range(of: "[0-9a-fA-F]{64}", options: .regularExpression) { sum = String(line[found]); break }
            }
        }
        guard let sum, sum.count == 64 else { throw Failure(message: "the release has no checksum to check the file by.") }
        let page = (json["html_url"] as? String).flatMap(URL.init(string:)) ?? URL(string: "https://github.com/mbahakeskin/BasicShell/releases")!
        return Release(version: version, notes: notes, asset: link, size: asset["size"] as? Int ?? 0, sha256: sum.lowercased(), page: page)
    }

    /// 0.6.0 is newer than 0.5.3 and than 0.5.10's neighbour 0.5.9; "0.6" is 0.6.0.
    static func newer(_ a: String, than b: String) -> Bool {
        func parts(_ v: String) -> [Int] { v.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 } }
        let x = parts(a), y = parts(b)
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }

    // MARK: - asking

    private func offer(_ release: Release, manually: Bool) {
        let alert = NSAlert()
        alert.messageText = "BasicShell \(release.version) is available"
        let notes = Updater.excerpt(release.notes)
        alert.informativeText = "You have \(current)." + (notes.isEmpty ? "" : "\n\n" + notes)
        alert.addButton(withTitle: "Update and Restart")
        alert.addButton(withTitle: "Later")
        alert.addButton(withTitle: "Skip This Version")
        alert.addButton(withTitle: "Release Notes")
        NSApp.activate()
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            Task { await install(release) }
        case .alertThirdButtonReturn:
            UserDefaults.standard.set(release.version, forKey: Updater.skipKey)
        case NSApplication.ModalResponse(rawValue: NSApplication.ModalResponse.alertFirstButtonReturn.rawValue + 3):
            NSWorkspace.shared.open(release.page)
        default:
            break
        }
    }

    /// The first of what the release says, without the markup.
    private static func excerpt(_ notes: String) -> String {
        let lines = notes.split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "") }
            .filter { !$0.lowercased().contains("self-signed") && !$0.lowercased().contains("sha-256") && !$0.hasPrefix("**Download") && !$0.hasPrefix("Download") }
        let text = lines.prefix(8).joined(separator: "\n")
        return text.count > 700 ? String(text.prefix(700)) + "…" : text
    }

    static func say(_ message: String, _ detail: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail.prefix(1).uppercased() + detail.dropFirst()
        alert.addButton(withTitle: "OK")
        NSApp.activate()
        alert.runModal()
    }

    // MARK: - putting it in place

    /// Downloads the release, checks it, and then quits this app, which a script (waiting for it to be gone) replaces with
    /// the new one and opens. The old one goes to the Trash, so that it can be put back.
    func install(_ release: Release) async {
        state = .downloading(release.version)
        Windows.front?.say("Downloading \(release.version)…")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("BasicShellUpdate-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let (file, response) = try await URLSession.shared.download(from: release.asset)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Failure(message: "the download answered \((response as? HTTPURLResponse)?.statusCode ?? 0).") }
            let zip = folder.appendingPathComponent("update.zip")
            try FileManager.default.moveItem(at: file, to: zip)
            let new = try await Task.detached(priority: .userInitiated) { try Updater.unpack(zip, in: folder, expecting: release) }.value
            try hand(over: new, folder: folder, version: release.version)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            let message = (error as? Failure)?.message ?? error.localizedDescription
            state = .failed("Couldn't update: \(message)")
            Updater.say("Couldn't update", message + "\n\nBasicShell has been left as it was.")
        }
    }

    /// The zip checked against its checksum, opened, and the app in it checked.
    nonisolated private static func unpack(_ zip: URL, in folder: URL, expecting release: Release) throws -> URL {
        let data = try Data(contentsOf: zip, options: .mappedIfSafe)
        let sum = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard sum == release.sha256 else { throw Failure(message: "the file is not the one the release names (its checksum differs).") }
        let out = folder.appendingPathComponent("unpacked", isDirectory: true)
        try run("/usr/bin/ditto", ["-x", "-k", zip.path, out.path], failure: "the file couldn't be opened.")
        guard let app = try FileManager.default.contentsOfDirectory(at: out, includingPropertiesForKeys: nil).first(where: { $0.pathExtension == "app" }),
              let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) else { throw Failure(message: "there is no app in the file.") }
        guard info["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier else { throw Failure(message: "the app in it is not BasicShell.") }
        guard info["CFBundleShortVersionString"] as? String == release.version else { throw Failure(message: "the app in it is not version \(release.version).") }
        try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path], failure: "the app in it has been changed since it was signed.")
        return app
    }

    nonisolated private static func run(_ tool: String, _ arguments: [String], failure: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw Failure(message: failure) }
    }

    /// Leaves the swap to a script, which waits until this app's process is gone (nothing tells a child that its parent has
    /// quit, so it looks for the process: the one place here that does), puts the old app in the Trash, the new one where it
    /// was, and opens it; if it can't, the old one is put back.
    private func hand(over new: URL, folder: URL, version: String) throws {
        let old = Bundle.main.bundleURL
        guard FileManager.default.isWritableFile(atPath: old.deletingLastPathComponent().path) else {
            NSWorkspace.shared.activateFileViewerSelecting([new])
            throw Failure(message: "BasicShell can't replace itself where it is (\(old.deletingLastPathComponent().path)). The new one is open in Finder: move it over the old one yourself.")
        }
        let script = folder.appendingPathComponent("swap.sh")
        let text = """
        #!/bin/sh
        PID="$1"; OLD="$2"; NEW="$3"; WORK="$4"
        while kill -0 "$PID" 2>/dev/null; do sleep 0.2; done
        BACK="$HOME/.Trash/BasicShell-before-update-$(date +%Y%m%d%H%M%S).app"
        if mv "$OLD" "$BACK"; then
          if mv "$NEW" "$OLD"; then
            xattr -dr com.apple.quarantine "$OLD" 2>/dev/null
            rm -rf "$WORK"
          else
            mv "$BACK" "$OLD"
          fi
        fi
        open "$OLD"
        """
        try text.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [script.path, String(ProcessInfo.processInfo.processIdentifier), old.path, new.path, folder.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        UserDefaults.standard.set(version, forKey: Updater.installedKey)
        NSApp.terminate(nil)
    }
}

#endif
