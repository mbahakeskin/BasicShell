import SwiftUI

/// The tabs, down the left, on glass.
struct SidebarView: View {
    let shell: Shell
    let window: BrowserWindow

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 2) {
                IconButton(symbol: "plus") { window.ask(.newTab(privately: false)) }
                    .help("New Tab")
                IconButton(symbol: "eyeglasses") { window.ask(.newTab(privately: true)) }
                    .help("New Private Tab")
                Spacer()
                IconButton(symbol: shell.sidebarPinned ? "sidebar.left" : "pin") { window.toggleSidebarPinned(nil) }
                    .help(shell.sidebarPinned ? "Hide Sidebar When Not in Use" : "Keep Sidebar Open")
            }
            .padding(.horizontal, 4)

            // Pinned tabs: three to a row, each a tile with its icon.
            let pinned = shell.tabs.filter(\.pinned)
            if !pinned.isEmpty {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                    ForEach(pinned) { tab in
                        PinnedTile(tab: tab, selected: tab === shell.selected, window: window)
                            .draggable(tab.id.uuidString)
                            .dropDestination(for: String.self) { ids, _ in
                                guard let id = ids.first.flatMap(UUID.init(uuidString:)) else { return false }
                                window.movePinned(id, before: tab)
                                return true
                            }
                    }
                }
                .padding(.horizontal, 2)
                Divider().padding(.horizontal, 6).padding(.vertical, 2)
            }

            List {
                let others = shell.tabs.filter { !$0.pinned }
                newTabRow
                ForEach(others) { row($0, in: others) }
                    .onMove { window.move(from: $0, to: $1, pinned: false) }
                if !others.isEmpty { newTabRow }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .glassEffect(.regular, in: .rect(cornerRadius: Metrics.radius))
    }

    /// How far in a tab sits: one step under the tab a link in it came from,
    /// as long as the two are together in the list; two at most.
    private func depth(of tab: Tab, in group: [Tab], limit: Int = 2) -> Int {
        guard limit > 0, let opener = tab.opener, let index = group.firstIndex(of: tab) else { return 0 }
        var above = index - 1
        while above >= 0 {
            let candidate = group[above]
            if candidate === opener { return 1 + depth(of: opener, in: group, limit: limit - 1) }
            // Siblings and their own children may sit between a tab and its opener.
            guard candidate.opener === opener || isDescendant(candidate, of: opener) else { return 0 }
            above -= 1
        }
        return 0
    }

    private func isDescendant(_ tab: Tab, of ancestor: Tab) -> Bool {
        var current = tab.opener
        var steps = 0
        while let node = current, steps < 8 {
            if node === ancestor { return true }
            current = node.opener
            steps += 1
        }
        return false
    }

    /// A New Tab button shaped like a row, above the tabs and below them.
    private var newTabRow: some View {
        NewTabRow { window.ask(.newTab(privately: false)) }
            .listRowInsets(EdgeInsets(top: 1, leading: 0, bottom: 1, trailing: 0))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .moveDisabled(true)
    }

    private func row(_ tab: Tab, in group: [Tab]) -> some View {
        TabRow(tab: tab, selected: tab === shell.selected, depth: depth(of: tab, in: group), window: window)
            .listRowInsets(EdgeInsets(top: 1, leading: 0, bottom: 1, trailing: 0))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }
}

struct NewTabRow: View {
    let action: () -> Void
    // `@State` is a macro in the macOS 27 SDK whose plugin ships only with
    // Xcode, so the State it would expand to is stored by hand.
    private var _hovering = State(initialValue: false)
    private var hovering: Bool {
        get { _hovering.wrappedValue }
        nonmutating set { _hovering.wrappedValue = newValue }
    }

    init(action: @escaping () -> Void) { self.action = action }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "plus")
                .font(.system(size: 12, weight: .medium))
                .frame(width: 16, height: 16)
            Text("New Tab").font(.system(size: 13))
            Spacer(minLength: 0)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .frame(height: 32)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.primary.opacity(hovering ? 0.06 : 0))
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .onHover { hovering = $0 }
        .help("New Tab (⌘T)")
    }
}

/// A pinned tab as a tile: its icon, its title on hover.
struct PinnedTile: View {
    let tab: Tab
    let selected: Bool
    let window: BrowserWindow
    // `@State` is a macro in the macOS 27 SDK whose plugin ships only with
    // Xcode, so the State it would expand to is stored by hand.
    private var _hovering = State(initialValue: false)
    private var hovering: Bool {
        get { _hovering.wrappedValue }
        nonmutating set { _hovering.wrappedValue = newValue }
    }

    var body: some View {
        Favicon(tab: tab)
            .scaleEffect(1.25)
            .frame(maxWidth: .infinity)
            .frame(height: 40)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(selected ? 0.16 : hovering ? 0.1 : 0.06))
            )
            .overlay(alignment: .bottom) {
                if tab.isLoading {
                    Capsule().fill(Color.accentColor).frame(width: 14, height: 2).padding(.bottom, 4)
                }
            }
            .opacity(tab.isUnloaded ? 0.55 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 10))
            .onTapGesture { window.select(tab) }
            .onHover { hovering = $0 }
            .help(tab.name)
            .contextMenu { TabMenu(tab: tab, selected: selected, window: window) }
    }
}

/// What a tab's right click offers, as a row or a tile.
struct TabMenu: View {
    let tab: Tab
    let selected: Bool
    let window: BrowserWindow

    var body: some View {
        Button("Copy Address") {
            guard let url = tab.url else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url.absoluteString, forType: .string)
        }
        .disabled(tab.url == nil)
        Button(tab.pinned ? "Unpin Tab" : "Pin Tab") { window.setPinned(tab, !tab.pinned) }
        Button("Archive Tab") { window.archive(tab) }
            .disabled(tab.isPrivate || tab.url == nil)
        Button("Unload Tab") { window.unload(tab) }
            .disabled(selected || tab.webView == nil)
        Divider()
        Button("Close Tab") { window.close(tab) }
    }
}

struct TabRow: View {
    let tab: Tab
    let selected: Bool
    let depth: Int
    let window: BrowserWindow
    // `@State` is a macro in the macOS 27 SDK whose plugin ships only with
    // Xcode, so the State it would expand to is stored by hand.
    private var _hovering = State(initialValue: false)
    private var hovering: Bool {
        get { _hovering.wrappedValue }
        nonmutating set { _hovering.wrappedValue = newValue }
    }

    var body: some View {
        HStack(spacing: 8) {
            Favicon(tab: tab)
            Text(tab.name)
                .font(.system(size: 13))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            if tab.pinned && !hovering {
                Image(systemName: "pin.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
            if tab.isPrivate {
                Image(systemName: "eyeglasses")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            if hovering {
                Button { window.close(tab) } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 32)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.primary.opacity(selected ? 0.13 : hovering ? 0.06 : 0))
        )
        // Opened from the tab above: set in, with a line back to it.
        .padding(.leading, CGFloat(depth) * 14)
        .overlay(alignment: .leading) {
            if depth > 0 {
                Capsule()
                    .fill(Color.primary.opacity(0.18))
                    .frame(width: 2, height: 22)
                    .padding(.leading, CGFloat(depth) * 14 - 7)
            }
        }
        .opacity(tab.isUnloaded ? 0.55 : 1)
        .contentShape(Rectangle())
        .onTapGesture { window.select(tab) }
        .onHover { hovering = $0 }
        .contextMenu { TabMenu(tab: tab, selected: selected, window: window) }
    }
}
