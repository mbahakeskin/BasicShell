import AppKit
import Observation
import SwiftUI

// Tab groups: tabs that belong together, kept side by side in the sidebar
// under a coloured name with a line of the same colour down their left.
// A group is whatever its tabs say they are in (`Tab.group`); the tabs of one
// group are always next to each other in the list, and a group with no tabs
// left is gone. Groups come back with the session.

@Observable
final class TabGroup: Identifiable {
    let id: UUID
    var name: String
    var color: Int
    var collapsed: Bool

    init(id: UUID = UUID(), name: String, color: Int, collapsed: Bool = false) {
        self.id = id
        self.name = name
        self.color = color
        self.collapsed = collapsed
    }

    var tint: Color { GroupColors.all[color % GroupColors.all.count] }
}

/// The colours a group or a profile can have, in the order they are given out.
enum GroupColors {
    /// Soft ones: a group's name and line and a profile's dot are small and
    /// stay in the corner of the eye.
    static let all: [Color] = [
        Color(red: 0.55, green: 0.71, blue: 0.96),  // blue
        Color(red: 0.96, green: 0.62, blue: 0.64),  // red
        Color(red: 0.60, green: 0.83, blue: 0.66),  // green
        Color(red: 0.98, green: 0.74, blue: 0.52),  // orange
        Color(red: 0.74, green: 0.65, blue: 0.93),  // purple
        Color(red: 0.96, green: 0.70, blue: 0.83),  // pink
        Color(red: 0.52, green: 0.81, blue: 0.81),  // teal
        Color(red: 0.96, green: 0.85, blue: 0.55),  // yellow
    ]
    static let names = ["Blue", "Red", "Green", "Orange", "Purple", "Pink", "Teal", "Yellow"]
}

/// What a row of the sidebar's list is.
enum SidebarItem: Identifiable {
    case newTab(atTop: Bool)
    case header(TabGroup)
    case tab(Tab)

    var id: String {
        switch self {
        case .newTab(let top): top ? "new-top" : "new-bottom"
        case .header(let group): "header-\(group.id)"
        case .tab(let tab): "tab-\(tab.id)"
        }
    }
}

extension Shell {
    /// The sidebar's list: the unpinned tabs, a header before each group's
    /// tabs and a new-tab row after them. A collapsed group shows its header
    /// (and the tab shown, so the page you're on never vanishes from the list).
    func sidebarItems() -> [SidebarItem] {
        let others = tabs.filter { !$0.pinned }
        var items: [SidebarItem] = [.newTab(atTop: true)]
        var current: TabGroup?
        for tab in others {
            if tab.group !== current {
                current = tab.group
                if let started = current { items.append(.header(started)) }
            }
            if let group = tab.group, group.collapsed, tab !== selected { continue }
            items.append(.tab(tab))
        }
        if !others.isEmpty { items.append(.newTab(atTop: false)) }
        return items
    }

    /// Every group, in the order of its first tab.
    var groups: [TabGroup] {
        var found: [TabGroup] = []
        for tab in tabs { if let group = tab.group, !found.contains(where: { $0 === group }) { found.append(group) } }
        return found
    }
}

extension BrowserWindow {
    /// The tab beside the group's others, at the end of them.
    private func place(_ tab: Tab, in group: TabGroup?) {
        guard let from = shell.tabs.firstIndex(of: tab) else { return }
        shell.tabs.remove(at: from)
        tab.group = group
        if let group, let last = shell.tabs.lastIndex(where: { $0.group === group }) {
            shell.tabs.insert(tab, at: last + 1)
        } else if let group {
            _ = group
            shell.tabs.insert(tab, at: min(from, shell.tabs.count))
        } else {
            shell.tabs.insert(tab, at: min(from, shell.tabs.count))
        }
        Session.touch()
    }

    /// A new group with this tab in it, once it has a name: Cancel makes none.
    func addToNewGroup(_ tab: Tab) {
        guard !tab.pinned else { return }
        askGroupName(initial: "Group \(shell.groups.count + 1)", title: "Name the new group") { [weak self] name in
            guard let self, self.shell.tabs.contains(tab) else { return }
            tab.group = self.makeGroup(named: name, color: nil)
            Session.touch()
        }
    }

    /// A group made by name, without asking (the agent's).
    func makeGroup(named name: String, color: Int?) -> TabGroup {
        let used = Set(shell.groups.map(\.color))
        let pick = color ?? (0..<GroupColors.all.count).first { !used.contains($0) } ?? shell.groups.count
        return TabGroup(name: name, color: pick)
    }

    func add(_ tab: Tab, to group: TabGroup) {
        guard !tab.pinned, tab.group !== group else { return }
        place(tab, in: group)
    }

    /// Out of its group, to just after it.
    func removeFromGroup(_ tab: Tab) {
        guard let old = tab.group else { return }
        let others = shell.tabs.filter { $0.group === old && $0 !== tab }
        guard let from = shell.tabs.firstIndex(of: tab), let last = others.last.flatMap({ shell.tabs.firstIndex(of: $0) }) else {
            tab.group = nil
            Session.touch()
            return
        }
        shell.tabs.remove(at: from)
        tab.group = nil
        // `last` was counted with the tab still in the list.
        shell.tabs.insert(tab, at: last >= from ? last : last + 1)
        Session.touch()
    }

    func ungroup(_ group: TabGroup) {
        for tab in shell.tabs where tab.group === group { tab.group = nil }
        Session.touch()
    }

    func closeTabs(of group: TabGroup) {
        for tab in shell.tabs where tab.group === group { close(tab) }
    }

    func recolor(_ group: TabGroup, _ color: Int) {
        group.color = color
        Session.touch()
    }

    func toggle(_ group: TabGroup) {
        group.collapsed.toggle()
        Session.touch()
    }

    func renameGroup(_ group: TabGroup) {
        askGroupName(initial: group.name, title: "Name this group") { name in
            group.name = name
            Session.touch()
        }
    }

    /// The sheet that asks for a group's name; `done` runs only on OK.
    private func askGroupName(initial: String, title: String, done: @escaping (String) -> Void) {
        let alert = NSAlert()
        alert.messageText = title
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: initial)
        field.frame = NSRect(x: 0, y: 0, width: 240, height: 24)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        let finish: (NSApplication.ModalResponse) -> Void = { answer in
            let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if answer == .alertFirstButtonReturn, !text.isEmpty { done(text) }
        }
        if let window { alert.beginSheetModal(for: window, completionHandler: finish) } else { finish(alert.runModal()) }
    }

    /// A tab dropped on another: with the other in a group it joins it, right
    /// after it; else the two make a new group.
    func drop(_ id: UUID, onto target: Tab) -> Bool {
        guard let tab = shell.tabs.first(where: { $0.id == id }), tab !== target, !target.pinned else { return false }
        // A pin dropped on the list stops being one.
        if tab.pinned { setPinned(tab, false) }
        if let group = target.group {
            shell.tabs.removeAll { $0 === tab }
            tab.group = group
            let at = shell.tabs.firstIndex(of: target).map { $0 + 1 } ?? shell.tabs.count
            shell.tabs.insert(tab, at: at)
            Session.touch()
        } else {
            // Two tabs become a group once it has a name; Cancel leaves everything where it was.
            askGroupName(initial: "Group \(shell.groups.count + 1)", title: "Name the new group") { [weak self] name in
                guard let self, self.shell.tabs.contains(tab), self.shell.tabs.contains(target) else { return }
                let group = self.makeGroup(named: name, color: nil)
                self.shell.tabs.removeAll { $0 === tab }
                target.group = group
                tab.group = group
                let at = self.shell.tabs.firstIndex(of: target).map { $0 + 1 } ?? self.shell.tabs.count
                self.shell.tabs.insert(tab, at: at)
                Session.touch()
            }
        }
        return true
    }

    /// A tab dropped at the top or bottom of another: put there, in that tab's group if it has one (so
    /// between a group's title and its first tab is in the group); out of a group by the row beside it.
    func reorder(_ id: UUID, relativeTo target: Tab, after: Bool) {
        guard let tab = shell.tabs.first(where: { $0.id == id }), tab !== target, !target.pinned else { return }
        if tab.pinned { setPinned(tab, false) }
        shell.tabs.removeAll { $0 === tab }
        tab.group = target.group
        let at = shell.tabs.firstIndex(of: target).map { after ? $0 + 1 : $0 } ?? shell.tabs.count
        shell.tabs.insert(tab, at: at)
        Session.touch()
    }

    /// A tab carried onto a New Tab row: to the top or the end of the list, outside any group.
    func moveToEnd(_ id: UUID, top: Bool) {
        guard let tab = shell.tabs.first(where: { $0.id == id }) else { return }
        if tab.pinned { setPinned(tab, false) }
        shell.tabs.removeAll { $0 === tab }
        tab.group = nil
        let at = top ? (shell.tabs.firstIndex { !$0.pinned } ?? shell.tabs.count) : shell.tabs.count
        shell.tabs.insert(tab, at: at)
        Session.touch()
    }

    /// A tab put among the pins, before or after one: a pin moved there, or a
    /// tab from the list that becomes one.
    func placePinned(_ id: UUID, relativeTo target: Tab?, after: Bool) {
        guard let target else { return }
        guard let tab = shell.tabs.first(where: { $0.id == id }), tab !== target, target.pinned else { return }
        if !tab.pinned { setPinned(tab, true) }
        shell.tabs.removeAll { $0 === tab }
        let at = shell.tabs.firstIndex(of: target).map { after ? $0 + 1 : $0 } ?? 0
        shell.tabs.insert(tab, at: at)
        Session.touch()
    }

    /// A tab carried to the top half of a group's header: before the group, outside it.
    func moveBefore(_ group: TabGroup, _ id: UUID) {
        guard let first = shell.tabs.first(where: { $0.group === group }), let tab = shell.tabs.first(where: { $0.id == id }) else { return }
        // The group's own first tab is already there: it only leaves the group.
        if tab === first { tab.group = nil; Session.touch(); return }
        if tab.pinned { setPinned(tab, false) }
        shell.tabs.removeAll { $0 === tab }
        tab.group = nil
        shell.tabs.insert(tab, at: shell.tabs.firstIndex(of: first) ?? shell.tabs.count)
        Session.touch()
    }

    /// A tab carried onto a group's header: first among its tabs.
    func joinStart(_ group: TabGroup, _ id: UUID) {
        guard let tab = shell.tabs.first(where: { $0.id == id }), tab.group !== group, let first = shell.tabs.first(where: { $0.group === group }) else { return }
        if tab.pinned { setPinned(tab, false) }
        shell.tabs.removeAll { $0 === tab }
        tab.group = group
        shell.tabs.insert(tab, at: shell.tabs.firstIndex(of: first) ?? shell.tabs.count)
        Session.touch()
    }

    /// A new tab that joins the group (the "+" in its header).
    func newTab(in group: TabGroup) {
        pendingGroup = group
        ask(.newTab(privately: false))
    }
}

// MARK: - the sidebar's pieces

struct GroupHeader: View {
    let group: TabGroup
    let count: Int
    let window: BrowserWindow
    private var _hovering = State(initialValue: false)
    private var hovering: Bool {
        get { _hovering.wrappedValue }
        nonmutating set { _hovering.wrappedValue = newValue }
    }

    init(group: TabGroup, count: Int, window: BrowserWindow) {
        self.group = group
        self.count = count
        self.window = window
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: group.collapsed ? "chevron.right" : "chevron.down")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(group.tint)
                .frame(width: 10)
            Text(group.name)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(group.tint)
                .lineLimit(1)
            if group.collapsed {
                Text("\(count)").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button { window.newTab(in: group) } label: {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(group.tint)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("New Tab in \(group.name)")
        }
        .padding(.horizontal, 8)
        .frame(height: 20)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(group.tint.opacity(hovering ? 0.16 : 0.08)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        // A single tap only: waiting to tell it from a double tap made it slow.
        .onTapGesture { window.toggle(group) }
        .contextMenu {
            Button("Rename Group…") { window.renameGroup(group) }
            Menu("Color") {
                ForEach(Array(GroupColors.names.enumerated()), id: \.offset) { index, name in
                    Button(name) { window.recolor(group, index) }
                }
            }
            Divider()
            Button("Ungroup") { window.ungroup(group) }
            Button("Close Group") { window.closeTabs(of: group) }
        }
        .dropMarks(window.shell.dropMark?.id == group.id ? window.shell.dropMark?.zone ?? .none : .none, corner: 6, tint: window.shell.dropMark?.zone == .onto ? group.tint : .white)
        .help(group.collapsed ? "Show the tabs" : "Hide the tabs")
    }
}
