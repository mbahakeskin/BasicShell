import AppKit
import WebKit

// What comes back at launch: every window where it was, with its tabs, their
// history and scroll position, which ones were pinned and which was in front.
//
// Kept in Application Support as session.json, written two seconds after
// anything changes and again on quitting, so a crash loses seconds at most.
// Private tabs are never written down. A restored tab costs nothing until it
// is shown: it comes back the way an unloaded one does (see Sleep.swift).
enum Session {
    struct SavedTab: Codable {
        var url: URL?
        var title: String
        var pinned: Bool
        /// WKWebView.interactionState: the tab's back-forward list.
        var state: Data?
        var scroll: [Double]?
        /// The favicon as a small PNG, so the sidebar has it before the page loads.
        var icon: Data?
        /// When it was last on screen, for archiving.
        var seen: Date?
        /// The index, in the same window, of the tab it was opened from.
        var opener: Int?
        /// The group it is in (Groups.swift).
        var group: SavedGroup?
    }

    struct SavedGroup: Codable {
        var id: String
        var name: String
        var color: Int
        var collapsed: Bool
    }

    /// The tabs of a profile that wasn't shown (Profiles.swift).
    struct SavedProfile: Codable {
        var id: String
        var tabs: [SavedTab]
        var selected: Int?
    }

    struct SavedWindow: Codable {
        var frame: String
        var tabs: [SavedTab]
        var selected: Int?
        /// The profile `tabs` belong to; none in a session from before profiles (the main one).
        var profile: String?
        var others: [SavedProfile]?
    }

    struct Saved: Codable {
        var windows: [SavedWindow]
    }

    private static var file: URL { Store.folder.appendingPathComponent("session.json") }

    // MARK: - writing

    private static var pending: DispatchWorkItem?

    /// Something changed: written down shortly, once things settle.
    static func touch() {
        guard restored else { return }
        pending?.cancel()
        let work = DispatchWorkItem { MainActor.assumeIsolated { save() } }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    static func save() {
        pending?.cancel()
        pending = nil
        // Nothing to write before the last session is back (quitting while
        // the extensions load): it would be written over with nothing.
        guard restored else { return }
        // Front to back as AppKit orders them; restored back to front, so the
        // front one ends up in front again.
        let ordered = NSApp.orderedWindows.compactMap { $0.windowController as? BrowserWindow }
        let rest = Windows.all.filter { window in !ordered.contains { $0 === window } }
        let windows: [SavedWindow] = (ordered + rest).compactMap { window in
            let tabs = window.shell.tabs.filter { !$0.isPrivate && $0.url != nil }
            let others: [SavedProfile] = window.shell.parked.compactMap { id, parked in
                let kept = parked.tabs.filter { !$0.isPrivate && $0.url != nil }
                guard !kept.isEmpty else { return nil }
                return SavedProfile(id: id.uuidString, tabs: kept.map { savedTab($0, among: kept) },
                                    selected: parked.selected.flatMap { selected in kept.firstIndex { $0 === selected } })
            }
            guard !(tabs.isEmpty && others.isEmpty), let frame = window.restingFrame else { return nil }
            return SavedWindow(
                frame: NSStringFromRect(frame),
                tabs: tabs.map { savedTab($0, among: tabs) },
                selected: window.shell.selected.flatMap { selected in tabs.firstIndex { $0 === selected } },
                profile: window.shell.profile.id.uuidString,
                others: others.isEmpty ? nil : others
            )
        }
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(Saved(windows: windows))
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
        } catch {
            NSLog("BasicShell: couldn't save the session: %@", error.localizedDescription)
        }
    }

    private static func savedTab(_ tab: Tab, among tabs: [Tab]) -> SavedTab {
        var saved = snapshot(of: tab)
        saved.opener = tab.opener.flatMap { opener in tabs.firstIndex { $0 === opener } }
        return saved
    }

    /// A tab as it can be written down and brought back.
    static func snapshot(of tab: Tab) -> SavedTab {
        SavedTab(
            url: tab.url,
            title: tab.title,
            pinned: tab.pinned,
            state: tab.historyState,
            scroll: tab.scrolled.map { [$0.x, $0.y] },
            icon: tab.icon.flatMap(png),
            seen: tab.lastSeen,
            group: tab.group.map { SavedGroup(id: $0.id.uuidString, name: $0.name, color: $0.color, collapsed: $0.collapsed) }
        )
    }

    /// An icon at 32 pixels, as PNG.
    private static func png(_ image: NSImage) -> Data? {
        let size = NSSize(width: 32, height: 32)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }

    // MARK: - quitting

    /// Before quitting, the tabs on screen say where they are scrolled to
    /// (the others noted it as they left the screen); a page that doesn't
    /// answer within a second is saved without it.
    static func saveBeforeQuitting(then done: @escaping () -> Void) {
        let showing = Windows.all.compactMap { $0.shell.selected }.filter { !$0.isPrivate && $0.webView != nil }
        guard !showing.isEmpty else {
            save()
            History.shared.flushAll()
            return done()
        }
        var left = showing.count
        var finished = false
        let finish = {
            guard !finished else { return }
            finished = true
            save()
            done()
        }
        History.shared.flushAll()
        for tab in showing {
            tab.webView?.evaluateJavaScript("[scrollX, scrollY]") { result, _ in
                MainActor.assumeIsolated {
                    if let point = result as? [Double], point.count == 2 {
                        tab.scrolled = CGPoint(x: point[0], y: point[1])
                    }
                    left -= 1
                    if left == 0 { finish() }
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { finish() }
    }

    // MARK: - reading

    /// Set once the session has been read, so nothing overwrites it before then.
    private(set) static var restored = false

    /// Opens the windows saved last time; false when there were none.
    @discardableResult
    static func restore() -> Bool {
        defer { restored = true }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: file),
              let saved = try? decoder.decode(Saved.self, from: data),
              !saved.windows.isEmpty
        else { return false }
        for savedWindow in saved.windows.reversed() {
            let window = Windows.open(empty: true)
            let frame = NSRectFromString(savedWindow.frame)
            if frame.width > 100, frame.height > 100 { window.window?.setFrame(frame, display: false) }
            window.shell.profile = Profiles.shared.profile(id: savedWindow.profile.flatMap(UUID.init(uuidString:))) ?? Profiles.main
            var groups: [String: TabGroup] = [:]
            for savedTab in savedWindow.tabs {
                let tab = Tab(restoring: savedTab, groups: &groups)
                window.insert(tab, after: nil, select: false)
            }
            let tabs = window.shell.tabs
            for (tab, savedTab) in zip(tabs, savedWindow.tabs) {
                if let index = savedTab.opener, tabs.indices.contains(index), tabs[index] !== tab { tab.opener = tabs[index] }
            }
            // The profiles that weren't shown: parked, as they were left.
            for other in savedWindow.others ?? [] {
                guard let profile = Profiles.shared.profile(id: UUID(uuidString: other.id)), profile !== window.shell.profile else { continue }
                var parkedGroups: [String: TabGroup] = [:]
                let parkedTabs = other.tabs.map { saved -> Tab in
                    let tab = Tab(restoring: saved, groups: &parkedGroups)
                    tab.host = window
                    tab.profile = profile
                    return tab
                }
                for (tab, saved) in zip(parkedTabs, other.tabs) {
                    if let index = saved.opener, parkedTabs.indices.contains(index), parkedTabs[index] !== tab { tab.opener = parkedTabs[index] }
                }
                window.shell.parked[profile.id] = ParkedTabs(tabs: parkedTabs, selected: other.selected.flatMap { parkedTabs.indices.contains($0) ? parkedTabs[$0] : nil })
            }
            let index = savedWindow.selected.flatMap { tabs.indices.contains($0) ? $0 : nil } ?? tabs.indices.last
            window.select(index.map { tabs[$0] })
        }
        return true
    }
}

extension Tab {
    /// A tab as it was saved: not loaded until it is shown.
    /// From the archive: not in a group.
    convenience init(restoring saved: Session.SavedTab) {
        var none: [String: TabGroup] = [:]
        var plain = saved
        plain.group = nil
        self.init(restoring: plain, groups: &none)
    }

    convenience init(restoring saved: Session.SavedTab, groups: inout [String: TabGroup]) {
        self.init(privately: false)
        if let saved = saved.group {
            let known = groups[saved.id] ?? TabGroup(id: UUID(uuidString: saved.id) ?? UUID(), name: saved.name, color: saved.color, collapsed: saved.collapsed)
            groups[saved.id] = known
            group = known
        }
        restore(url: saved.url, title: saved.title, state: saved.state)
        pinned = saved.pinned
        if let scroll = saved.scroll, scroll.count == 2 { scrolled = CGPoint(x: scroll[0], y: scroll[1]) }
        // A blank one (saved before blank icons were told apart) is let go: the letter shows until the page's own comes.
        icon = saved.icon.flatMap(NSImage.init(data:)).flatMap { Favicons.isBlank($0) ? nil : $0 }
        if let seen = saved.seen { lastSeen = seen }
    }
}
