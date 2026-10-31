import SwiftUI

/// The tabs, down the left, on glass.
struct SidebarView: View {
    let shell: Shell
    let window: BrowserWindow

    var body: some View {
        VStack(spacing: 4) {
            if shell.sidebarOnly {
                controls
            } else {
                HStack(spacing: 2) {
                    newTabButtons
                    Spacer()
                    pinButton
                }
                .padding(.horizontal, 4)
            }

            ProfileStrip(shell: shell, window: window)

            // Pinned tabs: three to a row, each a tile with its icon.
            let pinned = shell.tabs.filter(\.pinned)
            if !pinned.isEmpty {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                    ForEach(pinned) { tab in
                        PinnedTile(tab: tab, selected: tab === shell.selected, window: window)
                    }
                }
                .padding(.horizontal, 2)
                Divider().padding(.horizontal, 6).padding(.vertical, 2)
            }

            let items = shell.sidebarItems()
            let others = shell.tabs.filter { !$0.pinned }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(items) { item in
                            switch item {
                            case .newTab(let top): newTabRow(atTop: top).id(item.id)
                            case .header(let group):
                                GroupHeader(group: group, count: others.filter { $0.group === group }.count, window: window)
                                    .dragTarget(group.id, .header(group), in: shell)
                                    .padding(.top, 2)
                                    .id(item.id)
                            case .tab(let tab): row(tab, in: others).id(item.id)
                            }
                        }
                    }
                }
                .scrollIndicators(.never)
                .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named(TabDragModel.space)) }) { shell.drag.list = $0 }
                // The list goes on while the pointer is held near its top or bottom edge.
                .task(id: shell.drag.scrolling) {
                    let direction = shell.drag.scrolling
                    guard direction != 0 else { return }
                    while !Task.isCancelled {
                        let ids = items.map(\.id)
                        let shown = ids.indices.filter { index in
                            guard let frame = frameOf(items[index]) else { return false }
                            return frame.maxY > shell.drag.list.minY && frame.minY < shell.drag.list.maxY
                        }
                        if let edge = direction < 0 ? shown.first : shown.last {
                            let next = min(max(edge + direction, 0), ids.count - 1)
                            proxy.scrollTo(ids[next], anchor: direction < 0 ? .top : .bottom)
                        }
                        try? await Task.sleep(for: .milliseconds(70))
                    }
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
        // In the sidebar-only layout the traffic lights sit in its first
        // row, centred where Lights puts them.
        .padding(.top, shell.sidebarOnly ? 6 : 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .overlay(alignment: .topLeading) { DragOverlay(shell: shell) }
        .coordinateSpace(.named(TabDragModel.space))
        .glassEffect(.regular, in: .rect(cornerRadius: Metrics.radius))
        .coordinateSpace(.named("bar"))
    }

    /// Where an item of the list is now, in the sidebar's space (for scrolling it by).
    private func frameOf(_ item: SidebarItem) -> CGRect? {
        switch item {
        case .tab(let tab): shell.drag.frames[tab.id]?.rect
        case .header(let group): shell.drag.frames[group.id]?.rect
        case .newTab: nil
        }
    }

    private var newTabButtons: some View {
        Group {
            IconButton(symbol: "plus") { window.ask(.newTab(privately: false)) }
                .help("New Tab")
            IconButton(symbol: "eyeglasses") { window.ask(.newTab(privately: true)) }
                .help("New Private Tab")
        }
    }

    private var pinButton: some View {
        IconButton(symbol: shell.sidebarPinned ? "sidebar.left" : "pin") { window.toggleSidebarPinned(nil) }
            .help(shell.sidebarPinned ? "Hide Sidebar When Not in Use" : "Keep Sidebar Open")
    }

    /// What the top bar has, when there is none (Settings › General): the
    /// traffic lights, back and forward, and the window is dragged from
    /// there; the site, reload in it; the site's own buttons.
    @ViewBuilder private var controls: some View {
        let tab = shell.selected
        HStack(spacing: 2) {
            if shell.fullScreen {
                FullScreenLights(window: window).padding(.horizontal, 6)
            } else {
                Color.clear.frame(width: 64, height: 1)
            }
            IconButton(symbol: "chevron.left", enabled: tab?.canGoBack ?? false) { window.goBack(nil) }
            IconButton(symbol: "chevron.right", enabled: tab?.canGoForward ?? false) { window.goForward(nil) }
            Spacer()
            pinButton
        }
        .padding(.horizontal, 4)
        .background {
            Color.clear
                .contentShape(Rectangle())
                .gesture(WindowDragGesture())
                .onTapGesture(count: 2) { window.window?.performZoom(nil) }
        }
        SiteField(shell: shell, window: window)
            .padding(.vertical, 2)
        HStack(spacing: 2) {
            newTabButtons
            Spacer(minLength: 4)
            // The extensions are in the Extensions menu (ExtensionsMenu).
            SiteTools(shell: shell, window: window, downloadsEdge: .trailing, extensions: false)
        }
        .padding(.horizontal, 4)
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
    private func newTabRow(atTop: Bool) -> some View {
        let mark = atTop ? TabDragModel.topEnd : TabDragModel.bottomEnd
        return NewTabRow { window.ask(.newTab(privately: false), atTop: atTop) }
            .padding(.vertical, 1)
            .dropMarks(shell.dropMark?.id == mark ? shell.dropMark?.zone ?? .none : .none)
            .dragTarget(atTop ? TabDragModel.topEnd : TabDragModel.bottomEnd, .end(top: atTop), in: shell)
    }

    private func row(_ tab: Tab, in group: [Tab]) -> some View {
        TabRow(tab: tab, selected: tab === shell.selected, inSplit: shell.split?.contains(tab) == true, depth: tab.group == nil ? depth(of: tab, in: group) : 0, window: window)
            .padding(.vertical, 1)
            .dragTarget(tab.id, .row, in: shell)
            .carriedTab(tab, in: window)
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

    private var zone: DropZone { window.shell.dropMark?.id == tab.id ? window.shell.dropMark?.zone ?? .none : .none }

    init(tab: Tab, selected: Bool, window: BrowserWindow) {
        self.tab = tab
        self.selected = selected
        self.window = window
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
            .overlay(alignment: .bottomTrailing) {
                if tab.isPlayingAudio || tab.muteSaid == true { SpeakerButton(tab: tab, size: 12).padding(2) }
            }
            #if AGENT
            .overlay(alignment: .topTrailing) { AgentMark(tab: tab, size: 8).padding(4) }
            #endif
            .opacity(tab.isUnloaded ? 0.55 : 1)
            .dropMarks(zone, tile: true, corner: 10)
            .opacity(window.shell.drag.dragging == tab.id ? 0.25 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 10))
            .onTapGesture { window.select(tab) }
            .onHover { hovering = $0 }
            .dragTarget(tab.id, .tile, in: window.shell)
            .carriedTab(tab, in: window)
            .help(tab.name)
            .contextMenu { TabMenu(tab: tab, selected: selected, window: window) }
    }
}

/// The speaker of a tab that is making sound or has been muted: a click mutes it or lets it sound again.
struct SpeakerButton: View {
    let tab: Tab
    let size: CGFloat

    var body: some View {
        Button { tab.toggleMute() } label: {
            Image(systemName: tab.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(tab.isMuted ? Color.secondary : Color.primary)
                .frame(width: size + 7, height: size + 7)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(tab.isMuted ? "Unmute Tab" : "Mute Tab")
        .accessibilityLabel(tab.isMuted ? "Unmute tab" : "Mute tab")
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
        if !tab.pinned {
            Menu("Add to Group") {
                Button("New Group") { window.addToNewGroup(tab) }
                ForEach(window.shell.groups.filter { $0 !== tab.group }) { group in
                    Button(group.name) { window.add(tab, to: group) }
                }
            }
            if tab.group != nil { Button("Remove from Group") { window.removeFromGroup(tab) } }
        }
        Button("Open Side by Side") { window.splitWith(tab) }
            .disabled(selected || tab.url == nil || tab.profile !== window.shell.profile)
        if window.shell.split != nil { Button("Close Split View") { window.endSplit() } }
        Button("Archive Tab") { window.archive(tab) }
            .disabled(tab.isPrivate || tab.url == nil)
        Button("Unload Tab") { window.unload(tab) }
            .disabled(selected || tab.webView == nil)
        Divider()
        Button(tab.isMuted ? "Unmute Tab" : "Mute Tab") { tab.toggleMute() }
            .disabled(tab.url == nil)
        Button(MutedSites.shared.contains(tab.url) ? "Unmute This Site" : "Mute This Site") {
            MutedSites.shared.set(tab.url, !MutedSites.shared.contains(tab.url))
            tab.setMuted(nil)
        }
        .disabled(tab.isPrivate || tab.url?.host() == nil)
        Divider()
        Button("Close Tab") { window.close(tab) }
    }
}

struct TabRow: View {
    let tab: Tab
    let selected: Bool
    var inSplit = false
    let depth: Int
    let window: BrowserWindow
    // `@State` is a macro in the macOS 27 SDK whose plugin ships only with
    // Xcode, so the State it would expand to is stored by hand.
    private var _hovering = State(initialValue: false)
    private var hovering: Bool {
        get { _hovering.wrappedValue }
        nonmutating set { _hovering.wrappedValue = newValue }
    }
    /// Where on the row a dragged tab is held (see TabDrop).
    private var zone: DropZone { window.shell.dropMark?.id == tab.id ? window.shell.dropMark?.zone ?? .none : .none }

    init(tab: Tab, selected: Bool, inSplit: Bool = false, depth: Int, window: BrowserWindow) {
        self.tab = tab
        self.selected = selected
        self.inSplit = inSplit
        self.depth = depth
        self.window = window
    }

    var body: some View {
        HStack(spacing: 8) {
            Favicon(tab: tab)
            Text(tab.name)
                .font(.system(size: 13))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            if inSplit {
                Image(systemName: "rectangle.split.2x1")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.accentColor)
                    .help("In split view")
            }
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
            if tab.isPlayingAudio || tab.muteSaid == true { SpeakerButton(tab: tab, size: 11) }
            #if AGENT
            AgentMark(tab: tab, size: 10)
            #endif
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
        .frame(height: tab.group == nil ? 32 : 28)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.primary.opacity(selected ? 0.13 : hovering ? 0.06 : 0))
        )
        // In a group: set in a little, with the group's line down the left.
        .padding(.leading, tab.group == nil ? 0 : 8)
        .overlay(alignment: .leading) {
            if let group = tab.group {
                Capsule().fill(group.tint).frame(width: 2, height: 22).padding(.leading, 1)
            }
        }
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
        .opacity(window.shell.drag.dragging == tab.id ? 0.25 : tab.isUnloaded ? 0.55 : 1)
        .dropMarks(zone, tint: tab.group?.tint ?? .white)
        .contentShape(Rectangle())
        .onTapGesture { window.select(tab) }
        .onHover { hovering = $0 }
        .contextMenu { TabMenu(tab: tab, selected: selected, window: window) }
    }
}
