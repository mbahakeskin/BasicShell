import AppKit
import Observation
import SwiftUI
import WebKit

/// What the address field in the middle of the window is up for.
enum Ask: Equatable {
    case newTab(privately: Bool)
}

/// One window's state, which its SwiftUI parts draw from.
@Observable
final class Shell {
    var tabs: [Tab] = []
    var selected: Tab?
    /// Out because the pointer brought them out.
    var sidebarShown = false
    var topBarShown = false
    /// Out for good, and the page moved aside for them.
    var sidebarPinned = UserDefaults.standard.bool(forKey: "sidebar.pinned")
    var topBarPinned = UserDefaults.standard.bool(forKey: "topbar.pinned")
    var asking: Ask?
    var editingAddress = false
    var fullScreen = false
    var toast: String?
    var panel: Panel?
    /// A tab whose video is out in the floating window (Float.swift).
    var floating: Tab?
    /// An extension's popup is open under its button in the top bar.
    var popupOpen = false
    /// Where each extension's button is in the top bar, for its popup.
    var extensionButtons: [String: CGRect] = [:]

    var sidebarOut: Bool { sidebarPinned || sidebarShown }
    var topBarOut: Bool { topBarPinned || topBarShown || editingAddress || popupOpen }
}

/// A browser window: its tabs, the page on show, and the two panels that
/// come out from the left and top edges when the pointer goes there.
final class BrowserWindow: NSWindowController, NSWindowDelegate, NSMenuItemValidation, TabHost {
    let shell = Shell()

    private let root = RootView()
    private let page = NSView()
    private var empty: NSHostingView<EmptyPage>!
    private var sidebar: NSHostingView<SidebarView>!
    private var topBar: NSHostingView<TopBarView>!
    /// The time, beside the notch, while full screen hides the menu bar.
    private let clock = ClockHost(rootView: MenuBarClock())
    private var omnibox: NSHostingView<OmniboxView>?
    private var panelHost: NSHostingView<PanelView>?
    private var toastView: NSHostingView<ToastView>?
    /// A picture of an unloaded page, over it while it loads again.
    private var cover: NSImageView?
    private var popupWatch: (any NSObjectProtocol)?
    private var lights: Lights?
    private var monitors: [Any] = []

    private enum Edge { case side, top }
    private var revealing: [Edge: Timer] = [:]
    private var hiding: [Edge: Timer] = [:]

    init() {
        let window = ShellWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = false
        window.tabbingMode = .disallowed
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.minSize = NSSize(width: 480, height: 320)
        window.isReleasedWhenClosed = false
        window.acceptsMouseMovedEvents = true
        window.backgroundColor = .windowBackgroundColor
        super.init(window: window)
        window.delegate = self
        window.onFullScreen = { [weak self] in self?.fullScreenRequested() ?? false }
        build(in: window)
        place(window)
        lights = Lights(window)
        layout(animated: false)
        watchPointer()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func place(_ window: NSWindow) {
        if let front = Windows.front?.window, front.isVisible {
            window.setFrame(front.frame, display: false)
            window.setFrameTopLeftPoint(window.cascadeTopLeft(from: NSPoint(x: front.frame.minX, y: front.frame.maxY)))
        } else if !window.setFrameUsingName("BasicShell") {
            window.center()
        }
        window.setFrameAutosaveName(Windows.all.isEmpty ? "BasicShell" : "")
    }

    private func build(in window: NSWindow) {
        window.contentView = root
        root.onLayout = { [weak self] in self?.layout(animated: false) }
        root.onExit = { [weak self] in self?.pointerLeft() }

        page.wantsLayer = true
        page.layer?.masksToBounds = true
        root.addSubview(page)

        empty = hosting(EmptyPage(shell: shell, window: self))
        empty.frame = page.bounds
        empty.autoresizingMask = [.width, .height]
        page.addSubview(empty)

        sidebar = hosting(SidebarView(shell: shell, window: self))
        topBar = hosting(TopBarView(shell: shell, window: self))
        root.addSubview(sidebar)
        root.addSubview(topBar)
        clock.sizingOptions = []
        clock.safeAreaRegions = []
        clock.alphaValue = 0
        root.addSubview(clock)
    }

    private func hosting<V: View>(_ view: V) -> NSHostingView<V> {
        let host = NSHostingView(rootView: view)
        host.sizingOptions = []
        host.safeAreaRegions = []
        return host
    }

    // MARK: - layout

    /// Where everything goes for the current state. The panels float over the
    /// page unless pinned, in which case the page makes room for them.
    private func layout(animated: Bool) {
        let bounds = root.bounds
        let inset = Metrics.inset
        let top = menuBarAllowance
        let barY = bounds.maxY - top - inset - Metrics.bar
        let barFrame = NSRect(
            x: inset, y: shell.topBarOut ? barY : bounds.maxY + inset,
            width: bounds.width - inset * 2, height: Metrics.bar
        )
        let sideTop = shell.topBarOut ? barY - inset : bounds.maxY - top - inset
        let sideFrame = NSRect(
            x: shell.sidebarOut ? inset : -Metrics.sidebar - inset,
            y: inset, width: Metrics.sidebar, height: max(0, sideTop - inset)
        )

        var pageFrame = bounds
        let framed = shell.sidebarPinned || shell.topBarPinned
        if framed {
            pageFrame = bounds.insetBy(dx: inset, dy: inset)
            if shell.sidebarPinned {
                pageFrame.origin.x = sideFrame.maxX + inset
                pageFrame.size.width = bounds.maxX - inset - pageFrame.minX
            }
            if shell.topBarPinned {
                pageFrame.size.height = barY - inset - pageFrame.minY
            }
        }

        let strip = menuBarAllowance
        let clockWidth: CGFloat = 64
        clock.frame = NSRect(x: bounds.maxX - clockWidth - 10, y: bounds.maxY - strip, width: clockWidth, height: strip)
        let change = {
            self.clock.alphaValue = self.edgeToEdge && !self.shell.topBarOut ? 1 : 0
            self.topBar.frame = barFrame
            self.topBar.alphaValue = self.shell.topBarOut ? 1 : 0
            self.sidebar.frame = sideFrame
            self.sidebar.alphaValue = self.shell.sidebarOut ? 1 : 0
            self.page.frame = pageFrame
        }
        page.layer?.cornerRadius = framed ? 10 : 0
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Motion.reveal
                context.allowsImplicitAnimation = true
                change()
            }
        } else {
            change()
        }
        omnibox?.frame = bounds
        panelHost?.frame = bounds
        toastView?.frame = NSRect(x: 0, y: bounds.maxY - 120, width: bounds.width, height: 60)
        lights?.show(shell.topBarOut, animated: animated)
    }

    /// In full screen the menu bar comes down over the top of the window
    /// (on a Mac with a notch, the strip beside it); the bar goes below it.
    private var menuBarAllowance: CGFloat {
        guard shell.fullScreen, let screen = window?.screen else { return 0 }
        if edgeToEdge { return screen.safeAreaInsets.top > 0 ? screen.safeAreaInsets.top : (NSApp.mainMenu?.menuBarHeight ?? 24) }
        // macOS's own full screen: below the notch already; without one the
        // menu bar comes down over the window.
        return screen.safeAreaInsets.top > 0 ? 0 : (NSApp.mainMenu?.menuBarHeight ?? 24)
    }

    private var edgeToEdge: Bool { (window as? ShellWindow)?.edgeToEdge == true }

    /// How far down from the top the pointer brings the bar out: in full
    /// screen only the very top, where the menu bar comes down too, so the
    /// page beside the notch stays the page's.
    private var topReach: CGFloat { edgeToEdge ? Metrics.edge : Metrics.edge + menuBarAllowance }

    // MARK: - the pointer at the edges

    private func watchPointer() {
        let pointer = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] event in
            MainActor.assumeIsolated {
                if let self, event.window === self.window {
                    self.pointer(at: self.root.convert(event.locationInWindow, from: nil))
                }
            }
            return event
        }
        // Esc puts the address fields away: a text field hands Esc to
        // completion before SwiftUI's onExitCommand sees it. ⌃Tab walks the
        // tabs: the page would otherwise take it before the menu does.
        let keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let tab = event.keyCode == 48 && event.modifierFlags.contains(.control)
            guard event.keyCode == 53 || tab else { return event }
            let back = event.modifierFlags.contains(.shift)
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let self, event.window === self.window else { return false }
                if tab {
                    self.step(back ? -1 : 1)
                    return true
                }
                return self.escape()
            }
            return handled ? nil : event
        }
        monitors = [pointer, keys].compactMap { $0 }
    }

    /// Esc: the field over the page, else the address being edited.
    private func escape() -> Bool {
        if panelHost != nil {
            closePanel()
            return true
        }
        if omnibox != nil {
            dismissOmnibox()
            return true
        }
        if shell.editingAddress {
            shell.editingAddress = false
            if let web = shell.selected?.webView { window?.makeFirstResponder(web) }
            layout(animated: true)
            return true
        }
        return false
    }

    private func pointer(at point: NSPoint) {
        let bounds = root.bounds
        if !shell.sidebarPinned {
            if point.x <= Metrics.edge, !shell.sidebarShown { arm(.side) } else { disarm(.side) }
            if shell.sidebarShown {
                if point.x > sidebar.frame.maxX + Metrics.slack { linger(.side) } else { stay(.side) }
            }
        }
        if !shell.topBarPinned {
            if bounds.maxY - point.y <= topReach, !shell.topBarShown { arm(.top) } else { disarm(.top) }
            if shell.topBarShown {
                if point.y < topBar.frame.minY - Metrics.slack { linger(.top) } else { stay(.top) }
            }
        }
    }

    private func pointerLeft() {
        if shell.sidebarShown { linger(.side) }
        // In full screen the pointer leaves for the menu bar above the bar;
        // the bar stays for it to come back down.
        if shell.topBarShown, !overMenuBar { linger(.top) }
    }

    private var overMenuBar: Bool {
        guard shell.fullScreen, let screen = window?.screen else { return false }
        return NSEvent.mouseLocation.y >= screen.frame.maxY - menuBarAllowance - Metrics.edge
    }

    /// The pointer reached an edge: the panel comes out if it rests there.
    private func arm(_ edge: Edge) {
        guard revealing[edge] == nil else { return }
        revealing[edge] = Timer.scheduledTimer(withTimeInterval: Motion.dwell, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.revealing[edge] = nil
                guard self.atEdge(edge) else { return }
                self.set(edge, shown: true)
            }
        }
    }

    private func disarm(_ edge: Edge) {
        revealing.removeValue(forKey: edge)?.invalidate()
    }

    /// The pointer wandered off a panel: it goes unless it comes back.
    private func linger(_ edge: Edge) {
        guard hiding[edge] == nil else { return }
        hiding[edge] = Timer.scheduledTimer(withTimeInterval: Motion.linger, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.hiding[edge] = nil
                guard !self.kept(edge) else { return }
                self.set(edge, shown: false)
            }
        }
    }

    private func stay(_ edge: Edge) {
        hiding.removeValue(forKey: edge)?.invalidate()
    }

    private func atEdge(_ edge: Edge) -> Bool {
        guard let window else { return false }
        let point = root.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        switch edge {
        case .side: return point.x <= Metrics.edge && root.bounds.contains(point)
        case .top: return root.bounds.maxY - point.y <= max(topReach, menuBarAllowance) && point.x >= 0 && point.x <= root.bounds.maxX
        }
    }

    /// Whether a panel has reason to stay although the pointer left it.
    private func kept(_ edge: Edge) -> Bool {
        guard let window else { return false }
        let point = root.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        let inside = root.bounds.contains(point)
        switch edge {
        case .side: return inside && point.x <= sidebar.frame.maxX + Metrics.slack
        case .top: return shell.editingAddress || (inside && point.y >= topBar.frame.minY - Metrics.slack)
        }
    }

    private func set(_ edge: Edge, shown: Bool) {
        switch edge {
        case .side:
            guard shell.sidebarShown != shown else { return }
            shell.sidebarShown = shown
        case .top:
            guard shell.topBarShown != shown else { return }
            shell.topBarShown = shown
        }
        layout(animated: true)
    }

    // MARK: - tabs

    func insert(_ tab: Tab, after opener: Tab?, select: Bool) {
        tab.host = self
        tab.opener = opener
        if let opener, let at = shell.tabs.firstIndex(of: opener) {
            // After the opener and whatever it already opened, in order.
            var index = at + 1
            while index < shell.tabs.count, shell.tabs[index].opener === opener { index += 1 }
            shell.tabs.insert(tab, at: index)
        } else {
            shell.tabs.append(tab)
        }
        Extensions.shared.opened(tab)
        if select { self.select(tab) }
        Session.touch()
    }

    func open(_ url: URL, from tab: Tab?, select: Bool) {
        let new = Tab(privately: tab?.isPrivate ?? false, opening: url)
        insert(new, after: tab, select: select)
        new.load(url)
    }

    /// Opens a link from outside (another app, the Dock).
    func open(_ url: URL, select: Bool) {
        open(url, from: nil, select: select)
    }

    func select(_ tab: Tab?) {
        guard let window else { return }
        let previous = shell.selected
        defer { if previous !== tab { Extensions.shared.activated(tab, previous: previous) } }
        if let current = shell.selected, current !== tab, !Float.shared.isFloating(current) {
            // Out of the window, WebKit freezes the page (see Sleep.swift); a
            // site kept awake stays in it, hidden, and is only throttled. The
            // page leaves once its picture is taken, under the new one.
            let web = current.webView
            current.leavingScreen { [weak self, weak current] in
                guard let self, let current, let web, current !== self.shell.selected, current.webView === web else { return }
                if Sleep.keepsAwake(current.url) {
                    web.isHidden = true
                } else {
                    web.removeFromSuperview()
                    Sleep.freezeIfIdle(current)
                }
            }
        }
        shell.selected = tab
        cover?.removeFromSuperview()
        cover = nil
        guard let tab else {
            empty.isHidden = false
            window.title = "BasicShell"
            return
        }
        if Float.shared.isFloating(tab) {
            // Its page is in the floating window; the tab says so.
            empty.isHidden = false
            window.title = tab.name
            return
        }
        empty.isHidden = true
        let wasUnloaded = tab.isUnloaded
        let web = tab.makeWebView()
        web.isHidden = false
        if web.superview !== page {
            web.frame = page.bounds
            web.autoresizingMask = [.width, .height]
            page.addSubview(web)
        } else {
            page.addSubview(web, positioned: .above, relativeTo: nil)
        }
        Freeze.thaw(tab)
        // An unloaded page loads again under a picture of how it was left.
        if wasUnloaded, let data = tab.snapshot, let picture = NSImage(data: data) {
            let view = NSImageView(image: picture)
            view.imageScaling = .scaleAxesIndependently
            view.frame = page.bounds
            view.autoresizingMask = [.width, .height]
            page.addSubview(view, positioned: .above, relativeTo: web)
            cover = view
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self, weak view] in
                if let view, self?.cover === view { self?.uncover() }
            }
        }
        tab.lastSeen = Date()
        Session.touch()
        window.title = tab.name
        if omnibox == nil { window.makeFirstResponder(web) }
    }

    /// The page under the picture has drawn itself.
    func painted(_ tab: Tab) {
        if tab === shell.selected, cover != nil { uncover() }
    }

    private func uncover() {
        guard let view = cover else { return }
        cover = nil
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Motion.reveal
            view.animator().alphaValue = 0
        } completionHandler: {
            MainActor.assumeIsolated { view.removeFromSuperview() }
        }
    }

    func setPinned(_ tab: Tab, _ pinned: Bool) {
        guard tab.pinned != pinned, let index = shell.tabs.firstIndex(of: tab) else { return }
        shell.tabs.remove(at: index)
        tab.pinned = pinned
        // Pinned tabs come first; a tab pinned goes to the end of them, one
        // unpinned to the start of the rest.
        let boundary = shell.tabs.firstIndex { !$0.pinned } ?? shell.tabs.count
        shell.tabs.insert(tab, at: boundary)
        Session.touch()
    }

    /// Unload now, from the sidebar's menu.
    func unload(_ tab: Tab) {
        guard tab !== shell.selected else { return }
        tab.unload()
    }

    func close(_ tab: Tab) {
        guard let index = shell.tabs.firstIndex(of: tab) else { return }
        if Float.shared.isFloating(tab) { Float.shared.land() }
        Extensions.shared.closed(tab)
        Closed.add(tab)
        shell.tabs.remove(at: index)
        if shell.selected === tab {
            let next = shell.tabs.indices.contains(index) ? shell.tabs[index] : shell.tabs.last
            select(next)
        }
        tab.discard()
        Session.touch()
    }

    /// Puts a tab away in the archive, from where it comes back as it was.
    func archive(_ tab: Tab) {
        guard !tab.isPrivate, let index = shell.tabs.firstIndex(of: tab) else { return }
        Archive.shared.add(tab)
        shell.tabs.remove(at: index)
        if shell.selected === tab {
            select(shell.tabs.indices.contains(index) ? shell.tabs[index] : shell.tabs.last)
        }
        tab.discard()
        Session.touch()
    }

    func restoreArchived(_ id: UUID) {
        closePanel()
        guard let saved = Archive.shared.take(id) else { return }
        insert(Tab(restoring: saved), after: nil, select: true)
    }

    /// Takes a tab out of this window without closing it, to go to another.
    func detach(_ tab: Tab) {
        guard let index = shell.tabs.firstIndex(of: tab) else { return }
        shell.tabs.remove(at: index)
        if shell.selected === tab {
            tab.webView?.removeFromSuperview()
            shell.selected = nil
            select(shell.tabs.indices.contains(index) ? shell.tabs[index] : shell.tabs.last)
        }
        tab.webView?.removeFromSuperview()
        Session.touch()
    }

    /// A tab from the new-tab field's list, in whichever window it is.
    func switchTo(_ tab: Tab) {
        dismissOmnibox()
        guard let owner = Windows.all.first(where: { $0.shell.tabs.contains(tab) }) else { return }
        owner.select(tab)
        owner.window?.makeKeyAndOrderFront(nil)
    }

    /// The window's title is the page's, for the Window menu and Mission Control.
    func retitled(_ tab: Tab) {
        if tab === shell.selected { window?.title = tab.name }
    }

    /// A pinned tile dropped on another: it goes before that one.
    func movePinned(_ id: UUID, before target: Tab) {
        guard let moving = shell.tabs.first(where: { $0.id == id }), moving !== target, moving.pinned else { return }
        shell.tabs.removeAll { $0 === moving }
        let index = shell.tabs.firstIndex(of: target) ?? 0
        shell.tabs.insert(moving, at: index)
        Session.touch()
    }

    /// A drag within the pinned tabs or within the rest; `pinned` says which,
    /// and the offsets are within that group.
    func move(from source: IndexSet, to destination: Int, pinned: Bool) {
        var group = shell.tabs.filter { $0.pinned == pinned }
        group.move(fromOffsets: source, toOffset: destination)
        let other = shell.tabs.filter { $0.pinned != pinned }
        shell.tabs = pinned ? group + other : other + group
        Session.touch()
    }

    // MARK: - the address field

    /// The field in the middle of the window, over the page. A tab is made
    /// only once something is typed and Return pressed.
    func ask(_ ask: Ask) {
        shell.asking = ask
        if omnibox == nil {
            let host = hosting(OmniboxView(shell: shell, window: self))
            host.frame = root.bounds
            root.addSubview(host, positioned: .above, relativeTo: nil)
            omnibox = host
        }
        window?.makeKeyAndOrderFront(nil)
    }

    func dismissOmnibox() {
        omnibox?.removeFromSuperview()
        omnibox = nil
        shell.asking = nil
        if let web = shell.selected?.webView { window?.makeFirstResponder(web) }
    }

    func commit(_ typed: String) {
        guard let url = Address.resolve(typed) else { return }
        let privately = if case .newTab(let p)? = shell.asking { p } else { false }
        dismissOmnibox()
        let tab = Tab(privately: privately)
        insert(tab, after: nil, select: true)
        tab.load(url)
    }

    /// Return in the top bar's address field: this tab goes there.
    func go(_ typed: String) {
        shell.editingAddress = false
        layout(animated: true)
        guard let url = Address.resolve(typed) else { return }
        if let tab = shell.selected { tab.load(url) } else { open(url, from: nil, select: true) }
        if let web = shell.selected?.webView { window?.makeFirstResponder(web) }
    }

    // MARK: - extensions

    /// An extension's popup, under its button; the top bar stays out while it is open.
    func present(_ popover: NSPopover, for context: WKWebExtensionContext) {
        shell.popupOpen = true
        layout(animated: true)
        window?.makeKeyAndOrderFront(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + Motion.reveal) { [weak self] in
            guard let self else { return }
            let bar = self.topBar!
            var rect = self.shell.extensionButtons[context.uniqueIdentifier]
                ?? NSRect(x: bar.bounds.maxX - 60, y: 6, width: 28, height: 28)
            if !bar.isFlipped { rect.origin.y = bar.bounds.height - rect.maxY }
            popover.behavior = .transient
            popover.show(relativeTo: rect, of: bar, preferredEdge: bar.isFlipped ? .maxY : .minY)
            Debug.log("extension", "popup on screen: \(popover.isShown), size \(Int(popover.contentSize.width))×\(Int(popover.contentSize.height))")
            if let old = self.popupWatch { NotificationCenter.default.removeObserver(old) }
            self.popupWatch = NotificationCenter.default.addObserver(forName: NSPopover.didCloseNotification, object: popover, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    Debug.log("extension", "popup closed")
                    if let watch = self.popupWatch { NotificationCenter.default.removeObserver(watch) }
                    self.popupWatch = nil
                    self.shell.popupOpen = false
                    self.layout(animated: true)
                }
            }
        }
    }

    // MARK: - panels

    func showPanel(_ panel: Panel) {
        if omnibox != nil { dismissOmnibox() }
        if shell.panel == panel, panelHost != nil { return closePanel() }
        shell.panel = panel
        panelHost?.removeFromSuperview()
        let host = hosting(PanelView(shell: shell, window: self))
        host.frame = root.bounds
        root.addSubview(host, positioned: .above, relativeTo: nil)
        panelHost = host
        window?.makeKeyAndOrderFront(nil)
    }

    func closePanel() {
        panelHost?.removeFromSuperview()
        panelHost = nil
        shell.panel = nil
        if let web = shell.selected?.webView { window?.makeFirstResponder(web) }
    }

    func openFromPanel(_ url: URL) {
        closePanel()
        open(url, from: nil, select: true)
    }

    @objc func clearHistory(_ sender: Any?) { confirmClearHistory() }

    func confirmClearHistory() {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Clear all history?"
        alert.informativeText = "Every page in History is forgotten. Open tabs, bookmarks and website data stay."
        alert.addButton(withTitle: "Clear History")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { answer in
            if answer == .alertFirstButtonReturn { History.shared.clear() }
        }
    }

    func say(_ message: String) {
        shell.toast = message
        if toastView == nil {
            let host = hosting(ToastView(shell: shell))
            root.addSubview(host, positioned: .above, relativeTo: nil)
            toastView = host
            layout(animated: false)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in
            guard let self, self.shell.toast == message else { return }
            self.shell.toast = nil
        }
    }

    // MARK: - menu actions

    @objc func newTab(_ sender: Any?) { ask(.newTab(privately: false)) }
    @objc func newPrivateTab(_ sender: Any?) { ask(.newTab(privately: true)) }

    @objc func openLocation(_ sender: Any?) {
        guard shell.selected != nil else { return ask(.newTab(privately: false)) }
        shell.editingAddress = true
        layout(animated: true)
    }

    @objc func closeTab(_ sender: Any?) {
        if omnibox != nil { return dismissOmnibox() }
        if let tab = shell.selected { close(tab) } else { window?.performClose(nil) }
    }

    @objc func copyAddress(_ sender: Any?) {
        guard let url = shell.selected?.url else { return }
        let board = NSPasteboard.general
        board.clearContents()
        board.writeObjects([url as NSURL])
        board.setString(url.absoluteString, forType: .string)
        say("Link copied")
    }

    /// The blocker off, or back on, for this tab's site, and the page again
    /// so it takes effect.
    @objc func toggleShield(_ sender: Any?) {
        guard let web = shell.selected?.webView, let host = web.url?.host() else { return }
        Shield.shared.pause(host, !Shield.shared.isPaused(on: host))
        Shield.shared.tune(web.configuration.userContentController, for: host)
        web.reload()
    }

    /// This site's tabs never sleep, or sleep again.
    @objc func toggleAwake(_ sender: Any?) {
        guard let url = shell.selected?.url else { return }
        let on = !Awake.shared.contains(url)
        Awake.shared.set(url, on)
        say(on ? "\(url.host() ?? "This site") stays awake" : "\(url.host() ?? "This site") can sleep")
    }

    @objc func reload(_ sender: Any?) {
        guard let web = shell.selected?.webView else { return }
        if web.isLoading { web.stopLoading() } else { web.reload() }
    }

    @objc func goBack(_ sender: Any?) { shell.selected?.webView?.goBack() }
    @objc func goForward(_ sender: Any?) { shell.selected?.webView?.goForward() }

    @objc func actualSize(_ sender: Any?) { shell.selected?.webView?.pageZoom = 1 }
    @objc func zoomIn(_ sender: Any?) { shell.selected?.webView.map { $0.pageZoom = min(3, $0.pageZoom + 0.1) } }
    @objc func zoomOut(_ sender: Any?) { shell.selected?.webView.map { $0.pageZoom = max(0.3, $0.pageZoom - 0.1) } }

    @objc func showHistory(_ sender: Any?) { showPanel(.history) }
    @objc func showBookmarks(_ sender: Any?) { showPanel(.bookmarks) }
    @objc func showDownloads(_ sender: Any?) { showPanel(.downloads) }
    @objc func showArchive(_ sender: Any?) { showPanel(.archive) }

    @objc func bookmarkPage(_ sender: Any?) {
        guard let tab = shell.selected, let url = tab.url else { return }
        say(Bookmarks.shared.toggle(url, title: tab.title) ? "Bookmarked" : "Bookmark removed")
    }

    @objc func togglePin(_ sender: Any?) {
        guard let tab = shell.selected else { return }
        setPinned(tab, !tab.pinned)
    }

    @objc func duplicateTab(_ sender: Any?) {
        guard let tab = shell.selected, let url = tab.url else { return }
        let copy = Tab(privately: tab.isPrivate)
        copy.restore(url: url, title: tab.title, state: tab.historyState)
        insert(copy, after: tab, select: true)
    }

    @objc func moveTabToNewWindow(_ sender: Any?) {
        guard let tab = shell.selected, shell.tabs.count > 1 else { return }
        detach(tab)
        let other = Windows.open(empty: true)
        other.insert(tab, after: nil, select: true)
    }

    @objc func archiveTab(_ sender: Any?) {
        if let tab = shell.selected { archive(tab) }
    }

    @objc func stopLoading(_ sender: Any?) { shell.selected?.webView?.stopLoading() }

    @objc func printPage(_ sender: Any?) {
        guard let web = shell.selected?.webView, let window else { return }
        let operation = web.printOperation(with: NSPrintInfo.shared)
        operation.view?.frame = web.bounds
        operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
    }

    @objc func openFile(_ sender: Any?) {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.html, .pdf, .image, .plainText, .svg, .webArchive]
        panel.beginSheetModal(for: window) { [weak self] answer in
            guard answer == .OK, let url = panel.url else { return }
            self?.open(url, from: nil, select: true)
        }
    }

    @objc func pictureInPicture(_ sender: Any?) {
        if let floating = shell.floating { return Float.shared.toggle(floating, in: self) }
        guard let tab = shell.selected else { return }
        Float.shared.toggle(tab, in: self)
    }

    /// The tab's page went into the floating window.
    func floated(_ tab: Tab) {
        shell.floating = tab
        if shell.selected === tab { empty.isHidden = false }
    }

    /// And came back.
    func landed(_ tab: Tab) {
        shell.floating = nil
        if shell.selected === tab { select(tab) }
    }

    @objc func nextTab(_ sender: Any?) { step(1) }
    @objc func previousTab(_ sender: Any?) { step(-1) }

    private func step(_ by: Int) {
        guard !shell.tabs.isEmpty else { return }
        let index = shell.selected.flatMap { shell.tabs.firstIndex(of: $0) } ?? 0
        select(shell.tabs[(index + by + shell.tabs.count) % shell.tabs.count])
    }

    @objc func toggleSidebarPinned(_ sender: Any?) {
        shell.sidebarPinned.toggle()
        shell.sidebarShown = false
        UserDefaults.standard.set(shell.sidebarPinned, forKey: "sidebar.pinned")
        layout(animated: true)
    }

    @objc func toggleTopBarPinned(_ sender: Any?) {
        shell.topBarPinned.toggle()
        shell.topBarShown = false
        UserDefaults.standard.set(shell.topBarPinned, forKey: "topbar.pinned")
        layout(animated: true)
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let tab = shell.selected
        switch item.action {
        case #selector(goBack(_:)): return tab?.canGoBack ?? false
        case #selector(goForward(_:)): return tab?.canGoForward ?? false
        case #selector(copyAddress(_:)), #selector(reload(_:)),
             #selector(actualSize(_:)), #selector(zoomIn(_:)), #selector(zoomOut(_:)),
             #selector(duplicateTab(_:)), #selector(printPage(_:)):
            return tab?.url != nil
        case #selector(pictureInPicture(_:)):
            item.title = shell.floating != nil ? "Exit Picture in Picture" : "Picture in Picture"
            return tab?.url != nil || shell.floating != nil
        case #selector(bookmarkPage(_:)):
            item.title = Bookmarks.shared.contains(tab?.url) ? "Remove Bookmark" : "Bookmark This Page"
            return tab?.url != nil
        case #selector(togglePin(_:)):
            item.title = tab?.pinned == true ? "Unpin Tab" : "Pin Tab"
            return tab != nil
        case #selector(archiveTab(_:)): return tab?.url != nil && tab?.isPrivate == false
        case #selector(moveTabToNewWindow(_:)): return shell.tabs.count > 1
        case #selector(stopLoading(_:)): return tab?.isLoading == true
        case #selector(toggleAwake(_:)):
            item.title = Awake.shared.contains(tab?.url) ? "Let This Site Sleep" : "Keep This Site Awake"
            return tab?.url?.host() != nil
        case #selector(toggleShield(_:)):
            item.title = Shield.shared.isPaused(on: tab?.url?.host()) ? "Block Ads on This Site" : "Allow Ads on This Site"
            return tab?.url?.host() != nil
        case #selector(nextTab(_:)), #selector(previousTab(_:)): return shell.tabs.count > 1
        case #selector(toggleSidebarPinned(_:)):
            item.state = shell.sidebarPinned ? .on : .off
            return true
        case #selector(toggleTopBarPinned(_:)):
            item.state = shell.topBarPinned ? .on : .off
            return true
        default: return true
        }
    }

    // MARK: - window

    /// Full screen. macOS's own gives the window a desktop of its own but
    /// keeps it below the notch, and puts it back there if it is made
    /// taller (measured). So on a screen with a notch, unless turned off in
    /// Settings › General, full screen is BasicShell's own: the window
    /// covers the whole screen on the desktop it is on, the menu bar and
    /// the Dock hide until the pointer asks for them, and a clock stands in
    /// for the menu bar's meanwhile.
    static var coversNotch: Bool { UserDefaults.standard.object(forKey: "fullscreen.notch") as? Bool ?? true }

    /// Which full screen ⌃⌘F, the green light and the menu bring.
    private func fullScreenRequested() -> Bool {
        if edgeToEdge { toggleEdgeToEdge(); return true }
        guard BrowserWindow.coversNotch, let screen = window?.screen, screen.safeAreaInsets.top > 0,
              window?.styleMask.contains(.fullScreen) == false else { return false }
        toggleEdgeToEdge()
        return true
    }

    private var windowedFrame: NSRect?

    /// The frame to remember: the window's own, not the screen's.
    var restingFrame: NSRect? { windowedFrame ?? window?.frame }

    func toggleEdgeToEdge() {
        guard let window = window as? ShellWindow else { return }
        if window.edgeToEdge {
            window.edgeToEdge = false
            shell.fullScreen = false
            NSApp.presentationOptions = []
            window.isMovable = true
            if let frame = windowedFrame { window.setFrame(frame, display: true, animate: true) }
            windowedFrame = nil
        } else {
            guard let screen = window.screen ?? NSScreen.main else { return }
            windowedFrame = window.frame
            window.edgeToEdge = true
            shell.fullScreen = true
            NSApp.presentationOptions = [.autoHideMenuBar, .autoHideDock]
            window.isMovable = false
            window.setFrame(screen.frame, display: true, animate: true)
        }
        shell.topBarShown = false
        shell.sidebarShown = false
        lights?.refresh()
        layout(animated: false)
        Session.touch()
    }

    func windowWillEnterFullScreen(_ notification: Notification) {
        shell.fullScreen = true
        shell.topBarShown = false
        shell.sidebarShown = false
        layout(animated: false)
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        shell.fullScreen = false
        layout(animated: false)
    }

    func windowDidMove(_ notification: Notification) { Session.touch() }
    func windowDidEndLiveResize(_ notification: Notification) { Session.touch() }

    func windowDidResignKey(_ notification: Notification) {
        guard !shell.editingAddress else { return }
        shell.sidebarShown = false
        shell.topBarShown = false
        layout(animated: true)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        Extensions.shared.controller.didFocusWindow(self)
        // The menu bar and the Dock hide for a window in full screen only.
        NSApp.presentationOptions = edgeToEdge ? [.autoHideMenuBar, .autoHideDock] : []
    }

    func windowWillClose(_ notification: Notification) {
        if edgeToEdge { NSApp.presentationOptions = [] }
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        for tab in shell.tabs {
            Extensions.shared.closed(tab, windowClosing: true)
            tab.discard()
        }
        shell.tabs = []
        Windows.closed(self)
        Session.touch()
    }
}

/// The window's content view: lays its children out when resized and says
/// when the pointer leaves the window.
final class RootView: NSView {
    var onLayout: (() -> Void)?
    var onExit: (() -> Void)?

    override func layout() {
        super.layout()
        onLayout?()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseExited(with event: NSEvent) {
        onExit?()
    }
}

/// The browser's window: its full screen may be BasicShell's own (see
/// BrowserWindow.coversNotch), which covers the menu bar's place.
final class ShellWindow: NSWindow {
    var edgeToEdge = false
    /// Takes the request and answers whether it did; otherwise macOS's own.
    var onFullScreen: (() -> Bool)?

    override func toggleFullScreen(_ sender: Any?) {
        if onFullScreen?() != true { super.toggleFullScreen(sender) }
    }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        edgeToEdge ? frameRect : super.constrainFrameRect(frameRect, to: screen)
    }

    override func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(toggleFullScreen(_:)) {
            item.title = edgeToEdge || styleMask.contains(.fullScreen) ? "Exit Full Screen" : "Enter Full Screen"
            return true
        }
        return super.validateMenuItem(item)
    }
}

/// The clock that stands in for the menu bar's while full screen hides it.
struct MenuBarClock: View {
    var body: some View {
        TimelineView(.everyMinute) { context in
            Text(context.date, format: .dateTime.hour().minute())
                .font(.system(size: 13, weight: .medium))
                .monospacedDigit()
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .glassEffect(.regular, in: .capsule)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
    }
}

/// Shows the clock but lets every click through to the page under it.
final class ClockHost: NSHostingView<MenuBarClock> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
