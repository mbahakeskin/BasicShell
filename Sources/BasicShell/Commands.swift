import AppKit

/// What the address field can run: the menu bar's own items, read as the
/// field opens. A new menu item is a new command with nothing else to write.
struct Command {
    let title: String
    /// The menu it is in: "View", "Tab", "History › Recently Closed".
    let path: String
    let shortcut: String
    /// Other names it answers to: "split view" for a side by side.
    var aliases = ""
    private let action: () -> Void

    init(title: String, path: String, shortcut: String = "", aliases: String = "", action: @escaping () -> Void) {
        self.title = title
        self.path = path
        self.shortcut = shortcut
        self.aliases = aliases
        self.action = action
    }

    func run() { action() }

    /// How well the typed words fit, nil for not at all.
    func score(_ query: String) -> Int? {
        let found: Int?
        if let direct = [Loose.score(query, title), aliases.isEmpty ? nil : Loose.score(query, aliases)].compactMap({ $0 }).max() {
            found = direct * 2
        } else {
            // "tab mute", "view reader": the menu's name counts too, but only
            // whole: letters spread over a menu's name and a title are chance.
            let words = Loose.fold(query).split(separator: " ")
            let text = Loose.fold(path + " " + title + " " + aliases)
            found = words.allSatisfy { text.contains($0) } ? 500 : nil
        }
        // The Develop and Debug menus have dozens of items that are rarely
        // what is wanted: they come after anything else that fits.
        let rare = path.hasPrefix("Develop") || path.hasPrefix("Debug")
        return rare ? found.map { $0 / 4 } : found
    }
}

enum Commands {
    /// Whole menus that are not commands: text editing, the window list,
    /// the extensions' own entries.
    private static let skippedMenus: Set<String> = ["Edit", "Window", "Extensions"]

    private static var skippedActions: [Selector] {
        [#selector(NSApplication.hide(_:)), #selector(NSApplication.hideOtherApplications(_:)),
         #selector(NSApplication.unhideAllApplications(_:)), #selector(NSApplication.terminate(_:)),
         // A bookmark or a closed tab, one to a menu item: the field finds those itself.
         #selector(AppDelegate.openMenuPage(_:))]
    }

    /// The commands that apply to `window` as it is now.
    static func all(for window: NSWindow?) -> [Command] {
        guard let main = NSApp.mainMenu else { return [] }
        var found: [Command] = []
        for top in main.items where !top.isHidden {
            guard let menu = top.submenu, !skippedMenus.contains(menu.title) else { continue }
            walk(menu, path: menu.title, window: window, into: &found)
        }
        return found
    }

    private static func walk(_ menu: NSMenu, path: String, window: NSWindow?, into found: inout [Command]) {
        for item in menu.items where !item.isSeparatorItem && !item.isHidden && !item.isAlternate && !item.title.isEmpty {
            if let sub = item.submenu {
                if item.title != "Services" { walk(sub, path: path + " › " + item.title, window: window, into: &found) }
                continue
            }
            guard let action = item.action, !skippedActions.contains(action),
                  let target = item.target ?? responder(for: action, from: window)
            else { continue }
            // The menu bar asks the same thing when it opens (and may retitle
            // the item: "Pin Tab", "Unpin Tab"). Asked here, it doesn't depend
            // on which app is in front.
            if let validator = target as? NSMenuItemValidation, !validator.validateMenuItem(item) { continue }
            found.append(Command(title: item.title, path: path, shortcut: shortcut(item)) {
                NSApp.sendAction(action, to: item.target, from: item)
            })
        }
    }

    /// What an action with no target goes to: the window's first responder
    /// and those after it, the window and what runs it, then the app.
    private static func responder(for action: Selector, from window: NSWindow?) -> AnyObject? {
        var chain: [AnyObject] = []
        var next = window?.firstResponder
        while let current = next { chain.append(current); next = current.nextResponder }
        if let window { chain.append(window) }
        if let controller = window?.windowController { chain.append(controller) }
        if let delegate = window?.delegate { chain.append(delegate as AnyObject) }
        chain.append(NSApp)
        if let delegate = NSApp.delegate { chain.append(delegate as AnyObject) }
        return chain.first { $0.responds(to: action) }
    }

    /// What the menu bar has no item for: a side by side with each other tab.
    static func extras(for window: BrowserWindow) -> [Command] {
        let shell = window.shell
        guard shell.split == nil, let current = shell.selected else { return [] }
        return shell.tabs.compactMap { tab in
            guard tab !== current, tab.url != nil, tab.profile === shell.profile, !tab.isPrivate || current.isPrivate else { return nil }
            return Command(title: "Open Side by Side with \(tab.name)", path: "Tab", aliases: "split view") { [weak window, weak tab] in
                if let window, let tab { window.splitWith(tab) }
            }
        }
    }

    /// Up to `limit` commands for what was typed, best first.
    static func matching(_ query: String, in all: [Command], limit: Int) -> [Command] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return Array(all.prefix(limit)) }
        let ranked = all.compactMap { command in command.score(text).map { (command, $0) } }
        return ranked.sorted { $0.1 > $1.1 }.prefix(limit).map(\.0)
    }

    private static func shortcut(_ item: NSMenuItem) -> String {
        guard !item.keyEquivalent.isEmpty else { return "" }
        let mods = item.keyEquivalentModifierMask
        var text = ""
        if mods.contains(.control) { text += "⌃" }
        if mods.contains(.option) { text += "⌥" }
        if mods.contains(.shift) { text += "⇧" }
        if mods.contains(.command) { text += "⌘" }
        switch item.keyEquivalent {
        case "\t": text += "⇥"
        case " ": text += "Space"
        case "\r": text += "↩"
        case let key: text += key.uppercased()
        }
        return text
    }
}
