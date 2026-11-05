import AppKit
import SwiftUI

// Backlight menu › Keyboard Shortcuts…: every key the menus answer to,
// read off the menus as they are (so the list can't be out of date), and the
// few things the pointer does with a key held, which no menu has.
enum ShortcutsWindow {
    private static var window: NSWindow?

    static func show() {
        // Made again each time: the menus may have changed (Develop and Debug come and go).
        window?.close()
        let made = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 640),
                            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        made.title = "Keyboard Shortcuts"
        made.isReleasedWhenClosed = false
        made.contentView = NSHostingView(rootView: ShortcutsView(sections: Shortcuts.sections()))
        made.center()
        window = made
        made.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}

struct ShortcutSection: Identifiable {
    struct Row: Identifiable {
        let id = UUID()
        let title: String
        let keys: String
    }
    let id = UUID()
    let title: String
    let rows: [Row]
}

enum Shortcuts {
    /// Each menu's items that have a key, and what the pointer does with one held.
    @MainActor static func sections() -> [ShortcutSection] {
        var sections: [ShortcutSection] = []
        for top in NSApp.mainMenu?.items ?? [] {
            guard let menu = top.submenu, !top.isHidden else { continue }
            var rows: [ShortcutSection.Row] = []
            collect(menu, into: &rows)
            if !rows.isEmpty { sections.append(ShortcutSection(title: menu.title, rows: rows)) }
        }
        sections.append(ShortcutSection(title: "With the pointer", rows: [
            .init(title: "Open a link in a tab behind this one", keys: "⌘ click"),
            .init(title: "Open a link in a new tab and go to it", keys: "⇧⌘ click"),
            .init(title: "Peek at a link over this page", keys: "⇧ click"),
            .init(title: "Preview a link", keys: "hold ⌘ over it"),
            .init(title: "Close Find, Peek, the Reader or the address field", keys: "⎋"),
        ]))
        return sections
    }

    @MainActor private static func collect(_ menu: NSMenu, into rows: inout [ShortcutSection.Row]) {
        for item in menu.items where !item.isSeparatorItem && !item.isHidden {
            if let sub = item.submenu { collect(sub, into: &rows); continue }
            let keys = glyphs(item)
            guard !keys.isEmpty else { continue }
            // "Zoom In (120%)": the zoom it is at is not part of its name.
            let title = item.title.replacingOccurrences(of: #" \(\d+%\)$"#, with: "", options: .regularExpression)
            rows.append(.init(title: title, keys: keys))
        }
    }

    /// ⌃⌥⇧⌘ and the key, as the menu bar draws them.
    static func glyphs(_ item: NSMenuItem) -> String {
        let key = item.keyEquivalent
        guard !key.isEmpty else { return "" }
        var text = ""
        let mods = item.keyEquivalentModifierMask
        if mods.contains(.control) { text += "⌃" }
        if mods.contains(.option) { text += "⌥" }
        if mods.contains(.shift) { text += "⇧" }
        if mods.contains(.command) { text += "⌘" }
        let named: [String: String] = ["\t": "⇥", "\r": "↩", " ": "Space", "\u{1b}": "⎋", "\u{7f}": "⌫",
                                       String(UnicodeScalar(NSUpArrowFunctionKey)!): "↑", String(UnicodeScalar(NSDownArrowFunctionKey)!): "↓",
                                       String(UnicodeScalar(NSLeftArrowFunctionKey)!): "←", String(UnicodeScalar(NSRightArrowFunctionKey)!): "→"]
        return text + (named[key] ?? key.uppercased())
    }
}

struct ShortcutsView: View {
    let sections: [ShortcutSection]
    // `@State` is a macro in the macOS 27 SDK whose plugin ships only with
    // Xcode, so the State it would expand to is stored by hand.
    private var _filter = State(initialValue: "")
    private var filter: String {
        get { _filter.wrappedValue }
        nonmutating set { _filter.wrappedValue = newValue }
    }

    init(sections: [ShortcutSection]) { self.sections = sections }

    private var shown: [ShortcutSection] {
        let words = filter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !words.isEmpty else { return sections }
        return sections.compactMap { section in
            let rows = section.rows.filter { $0.title.lowercased().contains(words) || $0.keys.lowercased().contains(words) }
            return rows.isEmpty ? nil : ShortcutSection(title: section.title, rows: rows)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField("Search shortcuts", text: _filter.projectedValue)
                .textFieldStyle(.roundedBorder)
                .padding(12)
            Form {
                ForEach(shown) { section in
                    Section(section.title) {
                        ForEach(section.rows) { row in
                            HStack {
                                Text(row.title)
                                Spacer()
                                Text(row.keys)
                                    .font(.system(size: 13, weight: .medium, design: .rounded))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)
        }
        .frame(minWidth: 420, minHeight: 360)
    }
}
