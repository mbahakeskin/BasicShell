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

    var sidebarOut: Bool { sidebarPinned || sidebarShown }
    var topBarOut: Bool { topBarPinned || topBarShown || editingAddress }
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
    private var omnibox: NSHostingView<OmniboxView>?
    private var toastView: NSHostingView<ToastView>?
    private var lights: Lights?
    private var monitors: [Any] = []
    private var closed: [URL] = []

    private enum Edge { case side, top }
    private var revealing: [Edge: Timer] = [:]
    private var hiding: [Edge: Timer] = [:]

    init() {
        let window = NSWindow(
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

        empty = hosting(EmptyPage(window: self))
        empty.frame = page.bounds
        empty.autoresizingMask = [.width, .height]
        page.addSubview(empty)

        sidebar = hosting(SidebarView(shell: shell, window: self))
        topBar = hosting(TopBarView(shell: shell, window: self))
        root.addSubview(sidebar)
        root.addSubview(topBar)
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

        let change = {
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
        toastView?.frame = NSRect(x: 0, y: bounds.maxY - 120, width: bounds.width, height: 60)
        lights?.show(shell.topBarOut, animated: animated)
    }

    /// In full screen on a Mac without a notch the menu bar comes down over
    /// the top of the window; the bar goes below it.
    private var menuBarAllowance: CGFloat {
        guard shell.fullScreen, let screen = window?.screen, screen.safeAreaInsets.top == 0 else { return 0 }
        return NSApp.mainMenu?.menuBarHeight ?? 24
    }

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
        // Esc puts the address fields away. A text field hands Esc to
        // completion before SwiftUI's onExitCommand sees it, so it is caught
        // here first.
        let escape = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let self, event.window === self.window else { return false }
                return self.escape()
            }
            return handled ? nil : event
        }
        monitors = [pointer, escape].compactMap { $0 }
    }

    /// Esc: the field over the page, else the address being edited.
    private func escape() -> Bool {
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
            if bounds.maxY - point.y <= Metrics.edge + menuBarAllowance, !shell.topBarShown { arm(.top) } else { disarm(.top) }
            if shell.topBarShown {
                if point.y < topBar.frame.minY - Metrics.slack { linger(.top) } else { stay(.top) }
            }
        }
    }

    private func pointerLeft() {
        if shell.sidebarShown { linger(.side) }
        if shell.topBarShown { linger(.top) }
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
        case .top: return root.bounds.maxY - point.y <= Metrics.edge + menuBarAllowance && point.x >= 0 && point.x <= root.bounds.maxX
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
        if select { self.select(tab) }
    }

    func open(_ url: URL, from tab: Tab?, select: Bool) {
        let new = Tab(privately: tab?.isPrivate ?? false)
        insert(new, after: tab, select: select)
        new.load(url)
    }

    /// Opens a link from outside (another app, the Dock).
    func open(_ url: URL, select: Bool) {
        open(url, from: nil, select: select)
    }

    func select(_ tab: Tab?) {
        guard let window else { return }
        if let current = shell.selected, current !== tab {
            current.webView?.removeFromSuperview()
        }
        shell.selected = tab
        guard let tab else {
            empty.isHidden = false
            window.title = "BasicShell"
            return
        }
        empty.isHidden = true
        let web = tab.makeWebView()
        if web.superview !== page {
            web.frame = page.bounds
            web.autoresizingMask = [.width, .height]
            page.addSubview(web)
        }
        window.title = tab.name
        if omnibox == nil { window.makeFirstResponder(web) }
    }

    func close(_ tab: Tab) {
        guard let index = shell.tabs.firstIndex(of: tab) else { return }
        if !tab.isPrivate, let url = tab.url { closed.append(url) }
        shell.tabs.remove(at: index)
        if shell.selected === tab {
            let next = shell.tabs.indices.contains(index) ? shell.tabs[index] : shell.tabs.last
            select(next)
        }
        tab.discard()
    }

    /// The window's title is the page's, for the Window menu and Mission Control.
    func retitled(_ tab: Tab) {
        if tab === shell.selected { window?.title = tab.name }
    }

    func move(from source: IndexSet, to destination: Int) {
        shell.tabs.move(fromOffsets: source, toOffset: destination)
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

    @objc func reopenTab(_ sender: Any?) {
        guard let url = closed.popLast() else { return }
        open(url, from: nil, select: true)
    }

    @objc func copyAddress(_ sender: Any?) {
        guard let url = shell.selected?.url else { return }
        let board = NSPasteboard.general
        board.clearContents()
        board.writeObjects([url as NSURL])
        board.setString(url.absoluteString, forType: .string)
        say("Link copied")
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
             #selector(actualSize(_:)), #selector(zoomIn(_:)), #selector(zoomOut(_:)):
            return tab?.url != nil
        case #selector(reopenTab(_:)): return !closed.isEmpty
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

    func windowWillEnterFullScreen(_ notification: Notification) {
        shell.fullScreen = true
        layout(animated: false)
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        shell.fullScreen = false
        layout(animated: false)
    }

    func windowDidResignKey(_ notification: Notification) {
        guard !shell.editingAddress else { return }
        shell.sidebarShown = false
        shell.topBarShown = false
        layout(animated: true)
    }

    func windowWillClose(_ notification: Notification) {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        for tab in shell.tabs { tab.discard() }
        shell.tabs = []
        Windows.closed(self)
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
