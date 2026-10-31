import AppKit
import Observation
import SwiftUI
import WebKit

// Profiles: separate sets of cookies and site data (two accounts on one
// site at once), each with its own tabs, pinned tabs, groups, history and
// bookmarks. The first one, "Main", is the browser as it always was; the
// others have a data store of their own (WKWebsiteDataStore(forIdentifier:)),
// kept on disk. Extensions, zoom and the sites' permissions are shared.
//
// A window shows one profile at a time. The tabs of the others are parked in
// the window, off screen and frozen like any tab out of sight, and come back
// as they were when the profile is chosen again. The agent sees only the
// profile shown.

@Observable
final class Profile: Identifiable {
    let id: UUID
    var name: String
    var color: Int
    let isMain: Bool

    @ObservationIgnored lazy var history = History(file: isMain ? "history.json" : "history-\(id.uuidString).json")
    @ObservationIgnored lazy var bookmarks = Bookmarks(file: isMain ? "bookmarks.json" : "bookmarks-\(id.uuidString).json")

    init(id: UUID = UUID(), name: String, color: Int, isMain: Bool = false) {
        self.id = id
        self.name = name
        self.color = color
        self.isMain = isMain
    }

    var tint: Color { GroupColors.all[color % GroupColors.all.count] }

    /// nil for the main profile, which uses the browser's own.
    var dataStore: WKWebsiteDataStore? { isMain ? nil : WKWebsiteDataStore(forIdentifier: id) }
}

@Observable
final class Profiles {
    static let shared = Profiles()

    private struct Saved: Codable {
        var id: UUID
        var name: String
        var color: Int
        var main: Bool
    }

    private(set) var list: [Profile]

    private init() {
        let saved = Store.read("profiles.json", as: [Saved].self) ?? []
        var found = saved.map { Profile(id: $0.id, name: $0.name, color: $0.color, isMain: $0.main) }
        if !found.contains(where: \.isMain) { found.insert(Profile(name: "Main", color: 0, isMain: true), at: 0) }
        // The main one always first.
        found.sort { $0.isMain && !$1.isMain }
        list = found
    }

    static var main: Profile { shared.list[0] }

    /// The profile of the window in front.
    static var active: Profile { Windows.front?.shell.profile ?? main }

    func profile(id: UUID?) -> Profile? { id.flatMap { id in list.first { $0.id == id } } }

    private func save() {
        Store.write(list.map { Saved(id: $0.id, name: $0.name, color: $0.color, main: $0.isMain) }, to: "profiles.json")
    }

    func add(name: String) -> Profile {
        let used = Set(list.map(\.color))
        let color = (0..<GroupColors.all.count).first { !used.contains($0) } ?? list.count
        let made = Profile(name: name, color: color)
        list.append(made)
        save()
        return made
    }

    func changed() { save() }

    func remove(_ profile: Profile) {
        guard !profile.isMain else { return }
        list.removeAll { $0 === profile }
        save()
        let id = profile.id
        profile.history.discard()
        try? FileManager.default.removeItem(at: Store.folder.appendingPathComponent("bookmarks-\(id.uuidString).json"))
        var pending = UserDefaults.standard.stringArray(forKey: Self.pendingKey) ?? []
        pending.append(id.uuidString)
        UserDefaults.standard.set(pending, forKey: Self.pendingKey)
        removeStore(id, attempt: 0)
    }

    /// Profiles whose data store couldn't be removed yet, tried again at launch.
    private static let pendingKey = "profiles.removeStores"

    /// WebKit won't remove a data store while a web view still uses it (the
    /// closed tabs' views go a moment later): tried again a few times, and at
    /// the next launch if need be.
    private func removeStore(_ id: UUID, attempt: Int) {
        WKWebsiteDataStore.remove(forIdentifier: id) { [weak self] error in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if error == nil {
                        var pending = UserDefaults.standard.stringArray(forKey: Self.pendingKey) ?? []
                        pending.removeAll { $0 == id.uuidString }
                        UserDefaults.standard.set(pending, forKey: Self.pendingKey)
                    } else if attempt < 5 {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { MainActor.assumeIsolated { self?.removeStore(id, attempt: attempt + 1) } }
                    }
                }
            }
        }
    }

    /// At launch: stores left over from profiles deleted last time.
    func removePendingStores() {
        for text in UserDefaults.standard.stringArray(forKey: Self.pendingKey) ?? [] {
            if let id = UUID(uuidString: text) { removeStore(id, attempt: 0) }
        }
    }
}

/// The tabs of a profile that is not the one shown.
final class ParkedTabs {
    var tabs: [Tab]
    var selected: Tab?
    init(tabs: [Tab], selected: Tab?) {
        self.tabs = tabs
        self.selected = selected
    }
}

extension Shell {
    /// Every tab of the window, those of the profiles not shown too.
    var allTabs: [Tab] { tabs + parked.values.flatMap(\.tabs) }
}

extension BrowserWindow {
    func switchProfile(to profile: Profile) {
        guard profile !== shell.profile else { return }
        endSplit()
        // What is shown goes out of sight first.
        let leaving = shell.tabs
        shell.parked[shell.profile.id] = ParkedTabs(tabs: leaving, selected: shell.selected)
        select(nil)
        let coming = shell.parked.removeValue(forKey: profile.id)
        shell.profile = profile
        shell.tabs = coming?.tabs ?? []
        for tab in leaving { Sleep.freezeIfIdle(tab) }
        select(coming?.selected ?? shell.tabs.last)
        Session.touch()
    }

    func newProfile() {
        let alert = NSAlert()
        alert.messageText = "Name the new profile"
        alert.informativeText = "A profile has its own cookies and sign-ins, tabs, history and bookmarks."
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: "")
        field.placeholderString = "Work"
        field.frame = NSRect(x: 0, y: 0, width: 240, height: 24)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] answer in
            let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard answer == .alertFirstButtonReturn, !text.isEmpty else { return }
            self?.switchProfile(to: Profiles.shared.add(name: text))
        }
        if let window { alert.beginSheetModal(for: window, completionHandler: finish) } else { finish(alert.runModal()) }
    }

    func renameProfile(_ profile: Profile) {
        let alert = NSAlert()
        alert.messageText = "Rename the profile"
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: profile.name)
        field.frame = NSRect(x: 0, y: 0, width: 240, height: 24)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        let finish: (NSApplication.ModalResponse) -> Void = { answer in
            let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if answer == .alertFirstButtonReturn, !text.isEmpty { profile.name = text; Profiles.shared.changed() }
        }
        if let window { alert.beginSheetModal(for: window, completionHandler: finish) } else { finish(alert.runModal()) }
    }

    func recolor(_ profile: Profile, _ color: Int) {
        profile.color = color
        Profiles.shared.changed()
    }

    /// Deletes the profile with its cookies, tabs, history and bookmarks.
    func deleteProfile(_ profile: Profile) {
        guard !profile.isMain else { return }
        let alert = NSAlert()
        alert.messageText = "Delete \"\(profile.name)\"?"
        alert.informativeText = "Its tabs, history, bookmarks, cookies and sign-ins go with it. This can't be undone."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if shell.profile === profile { switchProfile(to: Profiles.main) }
        for other in Windows.all {
            if let parked = other.shell.parked.removeValue(forKey: profile.id) { for tab in parked.tabs { tab.discard() } }
            if other.shell.profile === profile { other.switchProfile(to: Profiles.main) }
        }
        Profiles.shared.remove(profile)
    }
}

/// The thin strip of coloured dots above the pinned tabs: one per profile, the
/// one shown ringed; a click chooses it.
struct ProfileStrip: View {
    let shell: Shell
    let window: BrowserWindow

    var body: some View {
        HStack(spacing: 7) {
            ForEach(Profiles.shared.list) { profile in
                let current = profile === shell.profile
                Circle()
                    .fill(profile.tint.opacity(current ? 1 : 0.55))
                    .frame(width: 9, height: 9)
                    .overlay(Circle().stroke(Color.primary.opacity(current ? 0.7 : 0), lineWidth: 1.5).padding(-3))
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
                    .onTapGesture { window.switchProfile(to: profile) }
                    .help(profile.name)
                    .contextMenu {
                        Button("Rename Profile…") { window.renameProfile(profile) }
                        Menu("Color") {
                            ForEach(Array(GroupColors.names.enumerated()), id: \.offset) { index, name in
                                Button(name) { window.recolor(profile, index) }
                            }
                        }
                        if !profile.isMain {
                            Divider()
                            Button("Delete Profile…") { window.deleteProfile(profile) }
                        }
                    }
            }
            Button { window.newProfile() } label: {
                Image(systemName: "plus").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary).frame(width: 16, height: 16)
            }
            .buttonStyle(.plain)
            .help("New Profile")
            Spacer(minLength: 0)
            if shell.profile !== Profiles.main {
                Text(shell.profile.name).font(.system(size: 10, weight: .medium)).foregroundStyle(shell.profile.tint).lineLimit(1)
            }
        }
        .padding(.horizontal, 6)
        .frame(height: 18)
    }
}
