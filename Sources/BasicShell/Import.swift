import AppKit
import CommonCrypto
import SQLite3
import Observation
import SwiftUI

// Bookmarks, history and a file of passwords from the browsers already on this
// Mac: Chrome and the ones built on it (Brave, Edge, Arc, Vivaldi, Opera,
// Chromium), Safari and Firefox. Settings › Import. Read-only: the other
// browser's files are copied to a temporary folder first (they are locked
// while it runs) and never written to.
//
// Bookmark folders are flattened into the title ("Work / Reports"), as
// bookmarks.json is one list. All of the history is taken (History keeps up to 100,000 pages).
// Cookies are not moved. Passwords go into a plain CSV file the person
// chooses a place for, in the shape Chrome writes (name,url,username,
// password,note), which password managers read; there is no vault here.

struct ImportSource: Identifiable, Hashable {
    enum Kind: Hashable { case chromium(Vendor), safari, firefox }

    struct Vendor: Hashable {
        let name: String
        /// Under ~/Library/Application Support.
        let folder: String
        /// The Keychain item that holds the key to the stored passwords.
        let keychain: String
    }

    let id: String
    let name: String
    let kind: Kind
    let folder: URL

    nonisolated static let vendors = [
        Vendor(name: "Chrome", folder: "Google/Chrome", keychain: "Chrome"),
        Vendor(name: "Brave", folder: "BraveSoftware/Brave-Browser", keychain: "Brave"),
        Vendor(name: "Edge", folder: "Microsoft Edge", keychain: "Microsoft Edge"),
        Vendor(name: "Arc", folder: "Arc/User Data", keychain: "Arc"),
        Vendor(name: "Vivaldi", folder: "Vivaldi", keychain: "Vivaldi"),
        Vendor(name: "Opera", folder: "com.operasoftware.Opera", keychain: "Opera"),
        Vendor(name: "Chromium", folder: "Chromium", keychain: "Chromium"),
    ]

    /// Every browser profile that is here to read.
    nonisolated static func found() -> [ImportSource] {
        let fileManager = FileManager.default
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        var sources: [ImportSource] = []
        for vendor in vendors {
            let root = support.appendingPathComponent(vendor.folder, isDirectory: true)
            guard let names = try? fileManager.contentsOfDirectory(atPath: root.path) else { continue }
            let shownNames = profileNames(in: root)
            for name in names.sorted() where name == "Default" || name.hasPrefix("Profile ") || name == "Guest Profile" {
                let folder = root.appendingPathComponent(name, isDirectory: true)
                guard fileManager.fileExists(atPath: folder.appendingPathComponent("Bookmarks").path)
                        || fileManager.fileExists(atPath: folder.appendingPathComponent("History").path) else { continue }
                let shown = shownNames[name].map { $0 == vendor.name ? $0 : "\(vendor.name): \($0)" } ?? "\(vendor.name): \(name)"
                sources.append(ImportSource(id: "\(vendor.name)/\(name)", name: shown, kind: .chromium(vendor), folder: folder))
            }
            // Opera keeps one profile in the folder itself.
            if names.contains("Bookmarks") || names.contains("History") {
                sources.append(ImportSource(id: "\(vendor.name)/.", name: vendor.name, kind: .chromium(vendor), folder: root))
            }
        }
        let safari = fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Safari", isDirectory: true)
        if fileManager.fileExists(atPath: safari.appendingPathComponent("Bookmarks.plist").path) {
            sources.append(ImportSource(id: "Safari", name: "Safari", kind: .safari, folder: safari))
        }
        let firefox = support.appendingPathComponent("Firefox/Profiles", isDirectory: true)
        for name in ((try? fileManager.contentsOfDirectory(atPath: firefox.path)) ?? []).sorted() {
            let folder = firefox.appendingPathComponent(name, isDirectory: true)
            guard fileManager.fileExists(atPath: folder.appendingPathComponent("places.sqlite").path) else { continue }
            let label = name.split(separator: ".", maxSplits: 1).last.map(String.init) ?? name
            sources.append(ImportSource(id: "Firefox/\(name)", name: "Firefox: \(label)", kind: .firefox, folder: folder))
        }
        return sources
    }

    /// The names people gave their Chrome profiles, from its "Local State".
    private nonisolated static func profileNames(in root: URL) -> [String: String] {
        guard let data = try? Data(contentsOf: root.appendingPathComponent("Local State")),
              let state = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let cache = (state["profile"] as? [String: Any])?["info_cache"] as? [String: [String: Any]]
        else { return [:] }
        return cache.compactMapValues { $0["name"] as? String }
    }
}

struct Imported {
    var bookmarks: [(title: String, url: URL)] = []
    var visits: [(url: URL, title: String, date: Date)] = []
}

enum Importer {
    struct Failure: LocalizedError {
        let message: String
        /// Safari's files, which macOS keeps from an app without Full Disk Access.
        var diskAccess = false
        var errorDescription: String? { message }
    }

    // MARK: - reading

    nonisolated static func read(_ source: ImportSource, bookmarks: Bool, history: Bool) throws -> Imported {
        var result = Imported()
        switch source.kind {
        case .chromium:
            if bookmarks { result.bookmarks = try chromiumBookmarks(source.folder) }
            if history { result.visits = try chromiumHistory(source.folder) }
        case .safari:
            if bookmarks { result.bookmarks = try safariBookmarks(source.folder) }
            if history { result.visits = try safariHistory(source.folder) }
        case .firefox:
            if bookmarks { result.bookmarks = try firefoxBookmarks(source.folder) }
            if history { result.visits = try firefoxHistory(source.folder) }
        }
        return result
    }

    private nonisolated static func web(_ text: String?) -> URL? {
        guard let text, let url = URL(string: text), ["http", "https"].contains(url.scheme ?? "") else { return nil }
        return url
    }

    
    // Chrome and the browsers built on it.

    private nonisolated static func chromiumBookmarks(_ folder: URL) throws -> [(title: String, url: URL)] {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("Bookmarks")),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let roots = root["roots"] as? [String: Any]
        else { return [] }
        var found: [(title: String, url: URL)] = []
        // Each root (bookmark bar, other, mobile) is a folder whose name isn't kept.
        for key in ["bookmark_bar", "other", "synced"] {
            guard let node = roots[key] as? [String: Any] else { continue }
            for child in node["children"] as? [[String: Any]] ?? [] { visit(child, [], &found) }
        }
        return found
    }

    private nonisolated static func visit(_ node: [String: Any], _ path: [String], _ found: inout [(title: String, url: URL)]) {
        if node["type"] as? String == "url" {
            guard let url = web(node["url"] as? String) else { return }
            let name = (node["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (url.host() ?? url.absoluteString)
            found.append((title: (path + [name]).joined(separator: " / "), url: url))
        } else if node["type"] as? String == "folder" {
            let name = node["name"] as? String ?? ""
            for child in node["children"] as? [[String: Any]] ?? [] { visit(child, name.isEmpty ? path : path + [name], &found) }
        }
    }

    private nonisolated static func chromiumHistory(_ folder: URL) throws -> [(url: URL, title: String, date: Date)] {
        let file = folder.appendingPathComponent("History")
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        let rows = try SQLite.rows(of: file, "SELECT url, title, last_visit_time FROM urls WHERE last_visit_time > 0 ORDER BY last_visit_time DESC")
        return rows.compactMap { row in
            guard let url = web(row[0] as? String), let time = row[2] as? Int64 else { return nil }
            return (url, row[1] as? String ?? "", Date(timeIntervalSince1970: Double(time) / 1_000_000 - 11_644_473_600))
        }
    }

    // Safari. Its folder is closed to apps without Full Disk Access.

    private nonisolated static func safariBookmarks(_ folder: URL) throws -> [(title: String, url: URL)] {
        let file = folder.appendingPathComponent("Bookmarks.plist")
        guard let data = try? Data(contentsOf: file) else { throw Failure(message: SQLite.safariClosed, diskAccess: true) }
        guard let root = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] else { return [] }
        var found: [(title: String, url: URL)] = []
        func walk(_ node: [String: Any], _ path: [String]) {
            let type = node["WebBookmarkType"] as? String
            if type == "WebBookmarkTypeLeaf" {
                guard let url = web(node["URLString"] as? String) else { return }
                let title = ((node["URIDictionary"] as? [String: Any])?["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (url.host() ?? url.absoluteString)
                found.append((title: (path + [title]).joined(separator: " / "), url: url))
            } else if type == "WebBookmarkTypeList" {
                let title = node["Title"] as? String ?? ""
                // Reading List is not bookmarks; the bar and the menu are roots, not folders.
                if title == "com.apple.ReadingList" { return }
                let root = ["BookmarksBar", "BookmarksMenu"].contains(title)
                for child in node["Children"] as? [[String: Any]] ?? [] { walk(child, root || title.isEmpty ? path : path + [title]) }
            }
        }
        walk(root, [])
        return found
    }

    private nonisolated static func safariHistory(_ folder: URL) throws -> [(url: URL, title: String, date: Date)] {
        let file = folder.appendingPathComponent("History.db")
        guard FileManager.default.isReadableFile(atPath: file.path) else { throw Failure(message: SQLite.safariClosed, diskAccess: true) }
        let rows: [[Any?]]
        do { rows = try SQLite.rows(of: file, """
            SELECT i.url, v.title, MAX(v.visit_time) FROM history_items i JOIN history_visits v ON v.history_item = i.id
            GROUP BY i.id ORDER BY MAX(v.visit_time) DESC
            """) } catch { throw Failure(message: SQLite.safariClosed, diskAccess: true) }
        return rows.compactMap { row in
            guard let url = web(row[0] as? String), let time = (row[2] as? Double) ?? (row[2] as? Int64).map(Double.init) else { return nil }
            return (url, row[1] as? String ?? "", Date(timeIntervalSinceReferenceDate: time))
        }
    }

    // Firefox.

    private nonisolated static func firefoxBookmarks(_ folder: URL) throws -> [(title: String, url: URL)] {
        let file = folder.appendingPathComponent("places.sqlite")
        let folders = try SQLite.rows(of: file, "SELECT id, parent, title FROM moz_bookmarks WHERE type = 2")
        var names: [Int64: (parent: Int64, title: String)] = [:]
        for row in folders { if let id = row[0] as? Int64, let parent = row[1] as? Int64 { names[id] = (parent, row[2] as? String ?? "") } }
        func path(of parent: Int64) -> [String] {
            var parts: [String] = []
            var current = parent
            // The places root and its four folders (menu, toolbar, unfiled, mobile) aren't kept.
            while let node = names[current], node.parent != 0, node.parent != 1 {
                if !node.title.isEmpty { parts.insert(node.title, at: 0) }
                current = node.parent
            }
            return parts
        }
        let rows = try SQLite.rows(of: file, """
            SELECT b.parent, b.title, p.url, p.title FROM moz_bookmarks b JOIN moz_places p ON b.fk = p.id WHERE b.type = 1
            """)
        return rows.compactMap { row in
            guard let parent = row[0] as? Int64, let url = web(row[2] as? String) else { return nil }
            let name = [row[1] as? String, row[3] as? String].compactMap { $0 }.first { !$0.isEmpty } ?? (url.host() ?? url.absoluteString)
            return (title: (path(of: parent) + [name]).joined(separator: " / "), url: url)
        }
    }

    private nonisolated static func firefoxHistory(_ folder: URL) throws -> [(url: URL, title: String, date: Date)] {
        let rows = try SQLite.rows(of: folder.appendingPathComponent("places.sqlite"),
                                   "SELECT url, title, last_visit_date FROM moz_places WHERE last_visit_date > 0 ORDER BY last_visit_date DESC")
        return rows.compactMap { row in
            guard let url = web(row[0] as? String), let time = row[2] as? Int64 else { return nil }
            return (url, row[1] as? String ?? "", Date(timeIntervalSince1970: Double(time) / 1_000_000))
        }
    }

    // MARK: - passwords

    /// What Chrome and its kin saved, as the CSV they themselves would write.
    /// Asks the Keychain for the browser's key, which macOS makes the person
    /// allow.
    nonisolated static func passwordsCSV(_ source: ImportSource) throws -> (csv: String, count: Int) {
        guard case .chromium(let vendor) = source.kind else { throw Failure(message: "Passwords can only be read from Chrome and the browsers built on it.") }
        let key = try chromiumKey(vendor)
        let file = source.folder.appendingPathComponent("Login Data")
        guard FileManager.default.fileExists(atPath: file.path) else { throw Failure(message: "\(source.name) has no saved passwords here.") }
        let rows = try SQLite.rows(of: file, "SELECT origin_url, username_value, password_value FROM logins WHERE blacklisted_by_user = 0")
        var lines = ["name,url,username,password,note"]
        for row in rows {
            guard let address = row[0] as? String, let user = row[1] as? String, let blob = row[2] as? Data,
                  let password = decrypt(blob, key: key), !password.isEmpty
            else { continue }
            let host = URL(string: address)?.host() ?? address
            lines.append([host, address, user, password, ""].map(quote).joined(separator: ","))
        }
        return (lines.joined(separator: "\n") + "\n", lines.count - 1)
    }

    private nonisolated static func quote(_ field: String) -> String {
        field.contains(where: { ",\"\n\r".contains($0) }) ? "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : field
    }

    private nonisolated static func chromiumKey(_ vendor: ImportSource.Vendor) throws -> [UInt8] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-w", "-s", "\(vendor.keychain) Safe Storage", "-a", vendor.keychain]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { throw Failure(message: "The Keychain couldn't be asked.") }
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let secret = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0, !secret.isEmpty else {
            throw Failure(message: "The Keychain didn't give \(vendor.name)'s key (allow it when macOS asks).")
        }
        var key = [UInt8](repeating: 0, count: kCCKeySizeAES128)
        let salt = Array("saltysalt".utf8)
        let status = CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), secret, secret.utf8.count, salt, salt.count,
                                          CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003, &key, key.count)
        guard status == kCCSuccess else { throw Failure(message: "The key couldn't be made.") }
        return key
    }

    private nonisolated static func decrypt(_ blob: Data, key: [UInt8]) -> String? {
        guard blob.count > 3, blob.prefix(3) == Data("v10".utf8) else { return nil }
        let payload = [UInt8](blob.dropFirst(3))
        let iv = [UInt8](repeating: 0x20, count: kCCBlockSizeAES128)
        var out = [UInt8](repeating: 0, count: payload.count + kCCBlockSizeAES128)
        var written = 0
        let status = CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                             key, key.count, iv, payload, payload.count, &out, out.count, &written)
        guard status == kCCSuccess else { return nil }
        let plain = Data(out.prefix(written))
        if let text = String(data: plain, encoding: .utf8) { return text }
        // Newer versions put a 32-byte hash of the site in front.
        return String(data: plain.dropFirst(32), encoding: .utf8)
    }
}

/// A just-in-time read of someone else's SQLite file: copied (with its
/// journal) beside nothing else, opened read-only.
enum SQLite {
    nonisolated static let safariClosed = "Safari's files need Full Disk Access for BasicShell."

    nonisolated static func rows(of file: URL, _ sql: String) throws -> [[Any?]] {
        let fileManager = FileManager.default
        let folder = fileManager.temporaryDirectory.appendingPathComponent("basicshell-import-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: folder) }
        let copy = folder.appendingPathComponent("copy.sqlite")
        do { try fileManager.copyItem(at: file, to: copy) } catch { throw Importer.Failure(message: "\(file.lastPathComponent) couldn't be read.") }
        for suffix in ["-wal", "-shm"] {
            try? fileManager.copyItem(at: URL(fileURLWithPath: file.path + suffix), to: URL(fileURLWithPath: copy.path + suffix))
        }
        var database: OpaquePointer?
        guard sqlite3_open_v2(copy.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let database else {
            throw Importer.Failure(message: "\(file.lastPathComponent) isn't a database BasicShell can open.")
        }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw Importer.Failure(message: "\(file.lastPathComponent) isn't laid out as expected.")
        }
        defer { sqlite3_finalize(statement) }
        var rows: [[Any?]] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            var row: [Any?] = []
            for column in 0..<sqlite3_column_count(statement) {
                switch sqlite3_column_type(statement, column) {
                case SQLITE_INTEGER: row.append(sqlite3_column_int64(statement, column))
                case SQLITE_FLOAT: row.append(sqlite3_column_double(statement, column))
                case SQLITE_TEXT: row.append(String(cString: sqlite3_column_text(statement, column)))
                case SQLITE_BLOB:
                    let count = Int(sqlite3_column_bytes(statement, column))
                    row.append(sqlite3_column_blob(statement, column).map { Data(bytes: $0, count: count) } ?? Data())
                default: row.append(nil)
                }
            }
            rows.append(row)
        }
        return rows
    }
}

// MARK: - what is added

extension Bookmarks {
    /// Bookmarks from another browser; addresses already kept are skipped.
    @discardableResult
    func add(_ found: [(title: String, url: URL)]) -> Int {
        var known = Set(marks.map(\.url))
        var added = 0
        for item in found where known.insert(item.url).inserted {
            appendImported(Mark(url: item.url, title: item.title))
            added += 1
        }
        saveImported()
        return added
    }
}

extension History {
    /// Visits from another browser, merged in by date; a page already visited
    /// at the same moment (or imported before) isn't added twice.
    @discardableResult
    func add(_ found: [(url: URL, title: String, date: Date)]) -> Int {
        var seen = Set(visits.map { "\($0.url.absoluteString)|\(Int($0.date.timeIntervalSince1970 / 60))" })
        var fresh: [Visit] = []
        for item in found where seen.insert("\(item.url.absoluteString)|\(Int(item.date.timeIntervalSince1970 / 60))").inserted {
            fresh.append(Visit(url: item.url, title: item.title, date: item.date))
        }
        mergeImported(fresh)
        return fresh.count
    }
}

// MARK: - Settings › Import

/// What the Import pane shows and is doing, kept here so it outlives the view.
@Observable
final class ImportModel {
    static let shared = ImportModel()

    var sources: [ImportSource] = []
    var chosen = ""
    var bookmarks = true
    var history = true
    var status = ""
    var working = false

    var current: ImportSource? { sources.first { $0.id == chosen } }

    func load() async {
        sources = await Task.detached { ImportSource.found() }.value
        if current == nil { chosen = sources.first?.id ?? "" }
    }

    func run() {
        guard let source = current else { return }
        let wantBookmarks = bookmarks, wantHistory = history
        // Into the profile that is shown now, whatever is shown when it is done.
        let profile = Profiles.active
        working = true
        status = ""
        Task {
            let outcome = await Task.detached { Result { try Importer.read(source, bookmarks: wantBookmarks, history: wantHistory) } }.value
            working = false
            switch outcome {
            case .success(let found):
                let marks = profile.bookmarks.add(found.bookmarks)
                let visits = profile.history.add(found.visits)
                var parts: [String] = []
                if wantBookmarks { parts.append("\(marks) bookmarks") }
                if wantHistory { parts.append("\(visits) pages of history") }
                status = "Added \(parts.joined(separator: " and ")) from \(source.name)\(Profiles.shared.list.count > 1 ? " to the profile \"\(profile.name)\"" : "")."
            case .failure(let error):
                status = error.localizedDescription
                if (error as? Importer.Failure)?.diskAccess == true { askForDiskAccess() }
            }
        }
    }

    /// Safari's files are closed to apps without Full Disk Access, which only
    /// the person can give in System Settings: say so, and take them there.
    private func askForDiskAccess() {
        let alert = NSAlert()
        alert.messageText = "Safari's data needs Full Disk Access"
        alert.informativeText = "macOS keeps Safari's bookmarks and history closed to apps. In System Settings › Privacy & Security › Full Disk Access, add BasicShell and turn it on; then quit and reopen BasicShell and import again."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Show BasicShell in Finder")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") { NSWorkspace.shared.open(url) }
        case .alertSecondButtonReturn:
            NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
        default: break
        }
    }

    func exportPasswords() {
        guard let source = current else { return }
        let alert = NSAlert()
        alert.messageText = "Save \(source.name)'s passwords as a file?"
        alert.informativeText = "The file holds every password in plain text. Anyone who can open it can read them. Import it into your password manager, then delete it."
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        working = true
        status = ""
        Task {
            let outcome = await Task.detached { Result { try Importer.passwordsCSV(source) } }.value
            working = false
            switch outcome {
            case .failure(let error): status = error.localizedDescription
            case .success(let made):
                let panel = NSSavePanel()
                panel.nameFieldStringValue = "Passwords.csv"
                panel.allowedContentTypes = [.commaSeparatedText]
                panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
                panel.message = "Plain text, with every password in it."
                guard panel.runModal() == .OK, let url = panel.url else { status = "Not saved."; return }
                do {
                    // Made readable by its owner alone from the start, not tightened after.
                    try? FileManager.default.removeItem(at: url)
                    guard FileManager.default.createFile(atPath: url.path, contents: Data(made.csv.utf8), attributes: [.posixPermissions: 0o600]) else {
                        throw Importer.Failure(message: "The file couldn't be made.")
                    }
                    status = "Saved \(made.count) passwords to \(url.lastPathComponent). Delete it after importing."
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } catch {
                    status = "The file couldn't be written: \(error.localizedDescription)"
                }
            }
        }
    }
}

struct ImportSettings: View {
    @Bindable private var model = ImportModel.shared

    var body: some View {
        Form {
            Section {
                if model.sources.isEmpty {
                    Text("No other browser found on this Mac.").foregroundStyle(.secondary)
                } else {
                    Picker("From", selection: $model.chosen) {
                        ForEach(model.sources) { Text($0.name).tag($0.id) }
                    }
                    if Profiles.shared.list.count > 1 {
                        LabeledContent("Into the profile", value: Profiles.active.name)
                    }
                    Toggle("Bookmarks", isOn: $model.bookmarks)
                    Toggle("History", isOn: $model.history)
                    HStack {
                        Button("Import") { model.run() }.disabled(model.working || (!model.bookmarks && !model.history))
                        if model.working { ProgressView().controlSize(.small) }
                    }
                }
            } header: {
                Text("Bookmarks and history")
            } footer: {
                Text("Chrome, Brave, Edge, Arc, Vivaldi, Opera, Chromium, Safari and Firefox. Folders become a prefix of the title (Work / Reports). Pages already here aren't added again. Nothing is changed in the other browser.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let source = model.current, case .chromium = source.kind {
                Section {
                    Button("Save a Password File…") { model.exportPasswords() }.disabled(model.working)
                } header: {
                    Text("Passwords")
                } footer: {
                    Text("Writes the passwords \(source.name) has saved to a CSV file you choose a place for, which password managers can import. macOS asks you to allow reading the key. The file is plain text: delete it once it's imported.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else if model.current?.kind == .safari {
                Section {
                    Text("Safari's passwords are in the Passwords app: File › Export All Passwords there gives the same kind of file.").foregroundStyle(.secondary)
                } header: {
                    Text("Passwords")
                }
            }
            if !model.status.isEmpty {
                Section { Text(model.status).font(.callout) }
            }
        }
        .formStyle(.grouped)
        .task { await model.load() }
    }
}
