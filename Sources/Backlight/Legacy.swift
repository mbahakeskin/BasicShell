import AppKit

// Backlight was called BasicShell until 0.9.0, and then had another bundle
// identifier (com.mbahakeskin.basicshell). What the old one left on this Mac
// is brought along at the first launch of the new one, and only copied: the
// old app and its data stay as they were, so going back loses nothing.
//
//   preferences      ~/Library/Preferences/<id>.plist           (settings, keywords, per-site choices)
//   app folder       ~/Library/Application Support/BasicShell    (session, history, bookmarks, extensions' files)
//   web data         ~/Library/WebKit/<id>                       (sign-ins, site storage, extensions' storage)
//   network data     ~/Library/HTTPStorages/<id> and <id>.binarycookies
//
// A copy on APFS shares the disk blocks until one side changes, so it costs
// next to nothing. What macOS keeps by identifier and cannot be copied (what
// pages and the app were allowed: location, camera, microphone, notifications;
// the default browser) is asked again.
nonisolated enum Legacy {
    static let oldIdentifier = "com.mbahakeskin.basicshell"
    static let identifier = "com.mbahakeskin.backlight"
    static let oldName = "BasicShell"
    static let name = "Backlight"
    /// Written (in the new preferences) once everything has been copied.
    static let doneKey = "legacy.brought"

    /// Old place, new place, under a home folder.
    static func pairs(home: URL) -> [(from: URL, to: URL)] {
        let library = home.appendingPathComponent("Library", isDirectory: true)
        func at(_ path: String, _ id: String) -> URL { library.appendingPathComponent(path.replacingOccurrences(of: "<id>", with: id)) }
        return [
            (library.appendingPathComponent("Application Support/\(oldName)", isDirectory: true), library.appendingPathComponent("Application Support/\(name)", isDirectory: true)),
            (at("WebKit/<id>", oldIdentifier), at("WebKit/<id>", identifier)),
            (at("HTTPStorages/<id>", oldIdentifier), at("HTTPStorages/<id>", identifier)),
            (at("HTTPStorages/<id>.binarycookies", oldIdentifier), at("HTTPStorages/<id>.binarycookies", identifier)),
        ]
    }

    /// Copies what exists and has no copy yet. Each goes to a name of its own
    /// first and is renamed when whole, so an interrupted copy is started
    /// again rather than taken for the real thing. Returns what it did, for
    /// the log.
    static func copyAcross(home: URL, files: FileManager = .default) -> [String] {
        var said: [String] = []
        for (from, to) in pairs(home: home) {
            guard files.fileExists(atPath: from.path), !files.fileExists(atPath: to.path) else { continue }
            let partial = to.deletingLastPathComponent().appendingPathComponent(to.lastPathComponent + ".copying")
            try? files.removeItem(at: partial)
            do {
                try files.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
                try copyTree(from, to: partial, files: files)
                try files.moveItem(at: partial, to: to)
                said.append("copied \(from.lastPathComponent)")
            } catch {
                try? files.removeItem(at: partial)
                said.append("couldn't copy \(from.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return said
    }

    /// A folder copied piece by piece, each file as a clone. FileManager.copyItem gives up on the whole folder at
    /// a socket, and the app's folder has one: the agent's, which an app that quit leaves behind. So what is
    /// neither a file, a folder nor a link is left out.
    static func copyTree(_ from: URL, to: URL, files: FileManager = .default) throws {
        let kind = try from.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey])
        if kind.isSymbolicLink == true {
            try files.copyItem(at: from, to: to)
        } else if kind.isDirectory == true {
            try files.createDirectory(at: to, withIntermediateDirectories: false)
            for child in try files.contentsOfDirectory(at: from, includingPropertiesForKeys: nil, options: []) {
                try copyTree(child, to: to.appendingPathComponent(child.lastPathComponent), files: files)
            }
            if let permissions = (try? files.attributesOfItem(atPath: from.path))?[.posixPermissions] {
                try? files.setAttributes([.posixPermissions: permissions], ofItemAtPath: to.path)
            }
        } else if kind.isRegularFile == true {
            try files.copyItem(at: from, to: to)
        }
    }

    /// The old preferences, key by key, wherever the new ones don't have the key.
    static func copyPreferences(_ old: [String: Any]?, into defaults: UserDefaults) -> Int {
        var count = 0
        for (key, value) in old ?? [:] where defaults.object(forKey: key) == nil {
            defaults.set(value, forKey: key)
            count += 1
        }
        return count
    }

    /// At the start of the real app's first launch (not a test copy's, which has
    /// identifiers of its own): the old app's things are copied across, before
    /// anything has read the new ones. The old app must have quit, or what it
    /// keeps open would be copied half written.
    @MainActor static func bringAlong() {
        guard Bundle.main.bundleIdentifier == identifier, UserDefaults.standard.object(forKey: doneKey) == nil else { return }
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: oldIdentifier)
        if !running.isEmpty {
            NSApplication.shared.activate()
            let alert = NSAlert()
            alert.messageText = "\(oldName) is still open"
            alert.informativeText = "\(name) brings over your tabs, sign-ins and settings from \(oldName), and that has to wait until \(oldName) has quit. Quit it, then open \(name) again."
            alert.addButton(withTitle: "Quit \(oldName)")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn { running.forEach { $0.terminate() } }
            exit(0)
        }
        let old = UserDefaults.standard.persistentDomain(forName: oldIdentifier)
        let preferences = copyPreferences(old, into: .standard)
        let said = copyAcross(home: home)
        UserDefaults.standard.set(true, forKey: doneKey)
        NSLog("Backlight: brought over %d preferences; %@", preferences, said.joined(separator: "; "))
    }

    /// The skill the app used to write for Claude Code, taken away when it is
    /// still the one the app wrote (a file someone else made is left).
    static func removeOldSkill(home: URL = URL(fileURLWithPath: NSHomeDirectory()), files: FileManager = .default) {
        let folder = home.appendingPathComponent(".claude/skills/basicshell", isDirectory: true)
        let file = folder.appendingPathComponent("SKILL.md")
        guard let text = try? String(contentsOf: file, encoding: .utf8), text.contains("name: basicshell"), text.contains("the person's own web browser") else { return }
        try? files.removeItem(at: folder)
    }

    /// An agent's list of MCP servers with the entry the app used to add taken
    /// out: the one named "basicshell" that runs this program (or its old one).
    static func dropOldServer(_ servers: inout [String: Any]) {
        guard let entry = servers["basicshell"] as? [String: Any], let command = entry["command"] as? String,
              command.hasSuffix("/BasicShell") || command.hasSuffix("/Backlight") || command.contains("BasicShell.app") || command.contains("Backlight.app")
        else { return }
        servers.removeValue(forKey: "basicshell")
    }
}
