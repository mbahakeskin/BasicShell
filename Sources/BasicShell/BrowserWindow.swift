import AppKit
import Observation
import SwiftUI
import WebKit

/// What the address field in the middle of the window is up for.
enum Ask: Equatable {
    case newTab(privately: Bool)
    /// The tab's own address, edited over the page (the sidebar-only layout).
    case address
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
    /// An extension's popup is open under its button in the top bar.
    var popupOpen = false
    /// The downloads under their button in the top bar are showing.
    var downloadsOpen = false
    /// Where each extension's button is in the top bar, for its popup.
    var extensionButtons: [String: CGRect] = [:]
    /// In BasicShell's own full screen on a screen with a notch, the room on
    /// either side of it, where the top bar goes.
    var notch: Notch?

    /// No top bar: what it has is at the top of the sidebar (Settings ›
    /// General).
    var sidebarOnly = UserDefaults.standard.bool(forKey: "layout.sidebarOnly")

    var sidebarOut: Bool { sidebarPinned || sidebarShown || (sidebarOnly && (popupOpen || downloadsOpen)) }
    var topBarKept: Bool { topBarPinned && !sidebarOnly }
    var topBarOut: Bool { !sidebarOnly && (topBarPinned || topBarShown || editingAddress || popupOpen || downloadsOpen) }
}

/// The top bar's two halves beside the notch: their widths, and their height
/// in the strip the menu bar would have.
struct Notch: Equatable {
    var leftWidth: CGFloat
    var rightWidth: CGFloat
    var height: CGFloat
}

/// A browser window: its tabs, the page on show, and the two panels that
/// come out from the left and top edges when the pointer goes there.
final class BrowserWindow: NSWindowController, NSWindowDelegate, NSMenuItemValidation, TabHost {
    let shell = Shell()

    private let root = RootView()
    private let page = NSView()
    private var empty: NSHostingView<EmptyPage>!
    private var loading: LoadingHost!
    private var sidebar: NSHostingView<SidebarView>!
    private var topBar: NSHostingView<TopBarView>!
    /// The time, beside the notch, while full screen hides the menu bar.
    private let clock = ClockHost(rootView: MenuBarClock())
    private var omnibox: NSHostingView<OmniboxView>?
    private var panelHost: NSHostingView<PanelView>?
    private var toastView: ToastHost?
    /// A picture of an unloaded page, over it while it loads again.
    private var cover: NSImageView?
    private var popupWatch: (any NSObjectProtocol)?
    private var lights: Lights?
    private var monitors: [Any] = []
    private var menuObservers: [NSObjectProtocol] = []

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
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(spaceChanged(_:)),
                                                          name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
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
        root.onMoveInBackground = { [weak self] point in self?.pointer(at: point) }

        page.wantsLayer = true
        page.layer?.masksToBounds = true
        root.addSubview(page)
        loading = LoadingHost(rootView: LoadingLine(shell: shell))
        loading.sizingOptions = []
        loading.safeAreaRegions = []

        empty = hosting(EmptyPage(shell: shell, window: self))
        empty.frame = page.bounds
        empty.autoresizingMask = [.width, .height]
        page.addSubview(empty)

        sidebar = hosting(SidebarView(shell: shell, window: self))
        topBar = hosting(TopBarView(shell: shell, window: self))
        root.addSubview(sidebar)
        root.addSubview(topBar)
        root.addSubview(loading)
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
    func layout(animated: Bool) {
        let bounds = root.bounds
        let inset = Metrics.inset
        let top = menuBarAllowance
        let notch = notchRoom
        if shell.notch != notch { shell.notch = notch }
        let barY: CGFloat
        let barFrame: NSRect
        if notch != nil {
            // The whole strip beside the notch, its halves drawn inside;
            // below the menu bar while that is down.
            barY = bounds.maxY - top - (menuBarDown ? top : 0)
            barFrame = NSRect(x: 0, y: shell.topBarOut ? barY : bounds.maxY + inset, width: bounds.width, height: top)
        } else {
            barY = bounds.maxY - top - inset - Metrics.bar
            barFrame = NSRect(
                x: inset, y: shell.topBarOut ? barY : bounds.maxY + inset,
                width: bounds.width - inset * 2, height: Metrics.bar
            )
        }
        // In BasicShell's own full screen the strip beside the notch is free
        // until the menu bar is asked for, so the sidebar alone goes up to
        // the top; under the top bar when that is out.
        let sideTop = shell.topBarOut ? barY - inset : bounds.maxY - (edgeToEdge ? (menuBarDown ? top : 0) : top) - inset
        let sideFrame = NSRect(
            x: shell.sidebarOut ? inset : -Metrics.sidebar - inset,
            y: inset, width: Metrics.sidebar, height: max(0, sideTop - inset)
        )

        var pageFrame = bounds
        let framed = shell.sidebarPinned || shell.topBarKept
        if framed {
            pageFrame = bounds.insetBy(dx: inset, dy: inset)
            if shell.sidebarPinned {
                pageFrame.origin.x = sideFrame.maxX + inset
                pageFrame.size.width = bounds.maxX - inset - pageFrame.minX
            }
            if shell.topBarKept {
                pageFrame.size.height = barY - inset - pageFrame.minY
            }
        }

        let strip = menuBarAllowance
        let lineWidth: CGFloat = 160
        loading.frame = NSRect(x: (bounds.width - lineWidth) / 2, y: bounds.maxY - top - 4.5, width: lineWidth, height: 3)
        // The window's own gray behind a page that hasn't drawn yet (see Tab).
        root.effectiveAppearance.performAsCurrentDrawingAppearance {
            self.page.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        }
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
        lights?.show(shell.sidebarOnly ? shell.sidebarOut : shell.topBarOut, animated: animated)
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

    /// The room beside the notch in BasicShell's own full screen, from what
    /// the screen says of the areas left and right of it; the halves keep
    /// 8 points from it and the bar's inset from the screen's edges.
    private var notchRoom: Notch? {
        guard edgeToEdge, let screen = window?.screen, screen.safeAreaInsets.top > 0,
              let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea
        else { return nil }
        let gap: CGFloat = 8
        return Notch(leftWidth: max(0, left.width - Metrics.inset - 4 - gap),
                     rightWidth: max(0, right.width - Metrics.inset - 4 - gap),
                     height: max(28, screen.safeAreaInsets.top - 4))
    }

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
        // A click anywhere but the top bar ends the address being edited.
        // SwiftUI doesn't always hear that its field lost focus to the page
        // (an AppKit view), and the bar then stayed out for good.
        let clicks = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, event.window === self.window, self.shell.editingAddress else { return }
                let point = self.root.convert(event.locationInWindow, from: nil)
                guard !self.topBar.frame.contains(point) else { return }
                self.shell.editingAddress = false
                self.layout(animated: true)
            }
            return event
        }
        monitors = [pointer, keys, clicks].compactMap { $0 }
        let centre = NotificationCenter.default
        let began = centre.addObserver(forName: NSMenu.didBeginTrackingNotification, object: NSApp.mainMenu, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.menuOpen = true }
        }
        let ended = centre.addObserver(forName: NSMenu.didEndTrackingNotification, object: NSApp.mainMenu, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.menuOpen = false }
        }
        menuObservers = [began, ended]
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
        reach(point)
        if !shell.sidebarPinned {
            if point.x <= Metrics.edge, !shell.sidebarShown { arm(.side) } else { disarm(.side) }
            if shell.sidebarShown {
                if point.x > sidebar.frame.maxX + Metrics.slack { linger(.side) } else { stay(.side) }
            }
        }
        if !shell.topBarKept, !shell.sidebarOnly {
            if bounds.maxY - point.y <= topReach, !shell.topBarShown { arm(.top) } else { disarm(.top) }
            if shell.topBarShown {
                if point.y < topBar.frame.minY - Metrics.slack { linger(.top) } else { stay(.top) }
            }
        }
    }

    /// The menu bar and the Dock within reach (see hiddenOptions).
    private var reachable = false
    private var reaching: Timer?
    /// A menu of the menu bar is open: the menu bar stays for it.
    private var menuOpen = false

    /// In BasicShell's own full screen: the Dock as soon as the pointer
    /// reaches the bottom edge, as before; the menu bar only once it has
    /// rested against the top for a moment, the top bar having come out
    /// first. Both go away again once the pointer is back on the page.
    private func reach(_ point: NSPoint) {
        guard edgeToEdge, NSApp.isActive else { return }
        let bounds = root.bounds
        if point.y <= 1 {
            setReachable(true)
        } else if bounds.maxY - point.y <= 1 {
            guard !reachable, reaching == nil else { return }
            reaching = Timer.scheduledTimer(withTimeInterval: Motion.menuBar, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.reaching = nil
                    guard let screen = self.window?.screen, NSEvent.mouseLocation.y >= screen.frame.maxY - 2 else { return }
                    self.setReachable(true)
                }
            }
        } else {
            reaching?.invalidate()
            reaching = nil
            let clear = bounds.maxY - point.y > menuBarAllowance + 40 && point.y > 160
            if reachable, clear, !menuOpen { setReachable(false) }
        }
    }

    private func setReachable(_ now: Bool) {
        guard reachable != now, edgeToEdge else { return }
        reachable = now
        NSApp.presentationOptions = now ? BrowserWindow.reachOptions : BrowserWindow.hiddenOptions
        menuBarWatch?.invalidate()
        menuBarWatch = nil
        if now {
            menuBarWatch = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.menuBarMoved() }
            }
        } else if menuBarDown {
            menuBarDown = false
            layout(animated: true)
        }
    }

    /// Hidden again, with nothing left watching: full screen begun, ended,
    /// or the window back in front.
    private func resetReach() {
        reachable = false
        reaching?.invalidate()
        reaching = nil
        menuBarWatch?.invalidate()
        menuBarWatch = nil
        menuBarDown = false
        menuBarWasDown = false
    }

    /// The menu bar is down over the strip beside the notch: the top bar
    /// makes way, below it.
    private var menuBarDown = false
    private var menuBarWatch: Timer?
    /// The menu bar has been down since the top bar came out: once it has
    /// gone back up, the top bar, back beside the notch, stays a little
    /// longer after the pointer leaves it, to be reached again.
    private var menuBarWasDown = false

    /// Checked while the menu bar is within reach: macOS says nothing when
    /// it comes down or goes up. `menuBarVisible()` turns false as soon as
    /// the pointer leaves it, though it stays down a while longer (measured),
    /// so its window is looked at instead: the Window Server's, at the main
    /// menu's level, more than half of it on the screen.
    private func menuBarMoved() {
        guard let screen = window?.screen else { return }
        let level = Int(CGWindowLevelForKey(.mainMenuWindow))
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        // Quartz measures down from the top of the first screen.
        let screenTop = (NSScreen.screens.first?.frame.maxY ?? screen.frame.maxY) - screen.frame.maxY
        let down = windows.contains { info in
            guard info[kCGWindowOwnerName as String] as? String == "Window Server",
                  info[kCGWindowLayer as String] as? Int == level,
                  let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = bounds["X"], let y = bounds["Y"], let height = bounds["Height"], height > 0,
                  x >= screen.frame.minX - 1, x < screen.frame.maxX, y < screenTop + height
            else { return false }
            return y > screenTop - height / 2
        }
        guard down != menuBarDown else { return }
        menuBarDown = down
        if down { menuBarWasDown = true }
        layout(animated: true)
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
        let wait = edge == .top && menuBarWasDown ? Motion.afterMenuBar : Motion.linger
        hiding[edge] = Timer.scheduledTimer(withTimeInterval: wait, repeats: false) { [weak self] _ in
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
            if !shown { menuBarWasDown = false }
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

    /// A link opened in a private tab, beside the one it came from.
    func openPrivately(_ url: URL) {
        let new = Tab(privately: true, opening: url)
        insert(new, after: shell.selected, select: true)
        new.load(url)
    }

    /// Opens a link from outside (another app, the Dock, the menu bar). The
    /// field a new window opens with goes: the link is what was wanted, and
    /// the field stayed over its page.
    func open(_ url: URL, select: Bool) {
        if select, omnibox != nil { dismissOmnibox() }
        open(url, from: nil, select: select)
    }

    /// The window and the tab in front, the app too.
    func show(_ tab: Tab) {
        // Asked from Picture in Picture's own window, which belongs to
        // another process: macOS lets that request for activation go
        // unanswered, and the window stayed on its desktop. Opening the app
        // through Launch Services brings it forward, desktop and all, as
        // clicking it in the Dock would.
        NSApp.activate()
        let open = NSWorkspace.OpenConfiguration()
        open.activates = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: open)
        window?.makeKeyAndOrderFront(nil)
        if tab !== shell.selected { select(tab) }
    }

    /// A tab not shown whose video came back from Picture in Picture: its
    /// page leaves the window as any other tab's does.
    func leftPictureInPicture(_ tab: Tab) {
        guard tab !== shell.selected, let web = tab.webView, web.superview === page else { return }
        if Sleep.keepsAwake(tab.url) { web.isHidden = true } else { web.removeFromSuperview() }
    }

    func select(_ tab: Tab?) {
        guard let window else { return }
        let previous = shell.selected
        defer { if previous !== tab { Extensions.shared.activated(tab, previous: previous) } }
        if let current = shell.selected, current !== tab {
            // A video playing in it goes into Picture in Picture (PiP.swift).
            PiP.follow(current)
            // Out of the window, WebKit freezes the page (see Sleep.swift); a
            // site kept awake, or one whose video is in Picture in Picture,
            // stays in it, hidden, and is only throttled. The page leaves once
            // its picture is taken, under the new one.
            let web = current.webView
            current.leavingScreen { [weak self, weak current] in
                guard let self, let current, let web, current !== self.shell.selected, current.webView === web else { return }
                if PiP.holds(current) {
                    // Its video is in Picture in Picture: behind the one shown,
                    // not hidden, so the page goes on (see PiP.keepAwake).
                    self.page.addSubview(web, positioned: .below, relativeTo: nil)
                } else if Sleep.keepsAwake(current.url) {
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
        PiP.bringBack(tab)
        empty.isHidden = true
        // Woken first: a frozen page whose process ended is let go here, and
        // a new view made for it below.
        Freeze.thaw(tab)
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
        PiP.forget(tab)
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
        if shell.asking == .address, let tab = shell.selected {
            dismissOmnibox()
            tab.load(url)
            return
        }
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

    /// The layout changed in Settings: the top bar, or everything in the
    /// sidebar.
    func setSidebarOnly(_ only: Bool) {
        shell.sidebarOnly = only
        shell.topBarShown = false
        shell.editingAddress = false
        layout(animated: true)
    }

    /// An extension's popup, under its button (beside it, in the sidebar);
    /// the bar it is in stays out while it is open.
    func present(_ popover: NSPopover, for context: WKWebExtensionContext) {
        if shell.sidebarOnly {
            window?.makeKeyAndOrderFront(nil)
            return presentFromMenu(popover)
        }
        shell.popupOpen = true
        layout(animated: true)
        window?.makeKeyAndOrderFront(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + Motion.reveal) { [weak self] in
            guard let self else { return }
            let side = self.shell.sidebarOnly
            let bar: NSView = side ? self.sidebar : self.topBar
            var rect = self.shell.extensionButtons[context.uniqueIdentifier]
                ?? NSRect(x: bar.bounds.maxX - 60, y: 6, width: 28, height: 28)
            if !bar.isFlipped { rect.origin.y = bar.bounds.height - rect.maxY }
            // In the sidebar, out past its edge, level with the button.
            if side { rect = NSRect(x: bar.bounds.maxX - 1, y: rect.minY, width: 1, height: rect.height) }
            popover.behavior = .transient
            popover.show(relativeTo: rect, of: bar, preferredEdge: side ? .maxX : bar.isFlipped ? .maxY : .minY)
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
            let host = ToastHost(rootView: ToastView(shell: shell))
            host.sizingOptions = []
            host.safeAreaRegions = []
            root.addSubview(host, positioned: .above, relativeTo: nil)
            toastView = host
            layout(animated: false)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in
            guard let self, self.shell.toast == message else { return }
            self.shell.toast = nil
        }
    }

    /// An extension's popup in the sidebar-only layout, chosen from the
    /// Extensions menu: at the top of the window, under where it was
    /// chosen (below the strip beside the notch in BasicShell's own full
    /// screen).
    private func presentFromMenu(_ popover: NSPopover) {
        let bounds = root.bounds
        let chosen = ExtensionsMenu.chosenAt.map { $0.x - (window?.frame.minX ?? 0) } ?? bounds.maxX - 200
        let x = min(max(chosen, 24), bounds.maxX - 24)
        let top = edgeToEdge ? menuBarAllowance : 0
        let y = root.isFlipped ? top + 1 : bounds.maxY - top - 2
        popover.behavior = .transient
        popover.show(relativeTo: NSRect(x: x, y: y, width: 1, height: 1), of: root, preferredEdge: root.isFlipped ? .maxY : .minY)
        Debug.log("extension", "popup on screen under the Extensions menu: \(popover.isShown)")
    }

    // MARK: - menu actions

    @objc func newTab(_ sender: Any?) { ask(.newTab(privately: false)) }
    @objc func newPrivateTab(_ sender: Any?) { ask(.newTab(privately: true)) }

    @objc func openLocation(_ sender: Any?) {
        guard shell.selected != nil else { return ask(.newTab(privately: false)) }
        if shell.sidebarOnly { return ask(.address) }
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

    /// This site's tabs never sleep, or sleep again.
    @objc func toggleAwake(_ sender: Any?) {
        guard let url = shell.selected?.url else { return }
        let on = !Awake.shared.contains(url)
        Awake.shared.set(url, on)
        say(on ? "\(url.host() ?? "This site") stays awake" : "\(url.host() ?? "This site") can sleep")
    }

    @objc func reload(_ sender: Any?) {
        guard let tab = shell.selected, let web = tab.webView else { return }
        if web.isLoading { web.stopLoading() }
        // Nothing shown yet (its first address never came): that address again.
        else if web.url == nil, let url = tab.url { tab.load(url) }
        else { web.reload() }
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
        guard let tab = shell.selected else { return }
        PiP.toggle(tab)
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
            item.title = tab.map(PiP.isActive) == true ? "Exit Picture in Picture" : "Picture in Picture"
            return tab?.url != nil
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
        case #selector(nextTab(_:)), #selector(previousTab(_:)): return shell.tabs.count > 1
        case #selector(toggleSidebarPinned(_:)):
            item.state = shell.sidebarPinned ? .on : .off
            return true
        case #selector(toggleTopBarPinned(_:)):
            item.state = shell.topBarKept ? .on : .off
            return !shell.sidebarOnly
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
            resetReach()
            NSApp.presentationOptions = []
            window.isMovable = true
            if let frame = windowedFrame { window.setFrame(frame, display: true, animate: true) }
            windowedFrame = nil
        } else {
            guard let screen = window.screen ?? NSScreen.main else { return }
            windowedFrame = window.frame
            window.edgeToEdge = true
            shell.fullScreen = true
            resetReach()
            NSApp.presentationOptions = BrowserWindow.hiddenOptions
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

    /// Out of sight (another desktop, minimized, covered): a video playing
    /// goes into Picture in Picture; back in sight, it comes back.
    ///
    /// Back in sight on another desktop only once macOS has finished moving
    /// there: a swipe toward this desktop shows the window from its first
    /// moment, and a swipe let go before halfway goes back. The video came
    /// back as the swipe began and stayed back when it didn't happen.
    func windowDidChangeOcclusionState(_ notification: Notification) {
        guard let window, let tab = shell.selected else { return }
        if window.occlusionState.contains(.visible) {
            if window.isOnActiveSpace { bringBackOnceSeen(tab) }
        } else if !window.isOnActiveSpace {
            PiP.follow(tab, slide: Spaces.direction(from: window))
        } else if window.isMiniaturized {
            PiP.follow(tab)
        } else {
            // Covered on this desktop, or the move to another not yet
            // registered: looked at again every 50 ms for up to 300, and
            // gone with as soon as the desktop has changed, the animation
            // as early as it can be.
            watchForMove(tab, tries: 6)
        }
    }

    private func watchForMove(_ tab: Tab, tries: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self, weak tab] in
            guard let self, let window = self.window, let tab, tab === self.shell.selected,
                  !window.occlusionState.contains(.visible) else { return }
            if !window.isOnActiveSpace { return PiP.follow(tab, slide: Spaces.direction(from: window)) }
            if tries > 1 { return self.watchForMove(tab, tries: tries - 1) }
            PiP.follow(tab)
        }
    }

    /// A move to another desktop is over (see windowDidChangeOcclusionState).
    @objc private func spaceChanged(_ notification: Notification) {
        guard let window, let tab = shell.selected else { return }
        if window.isOnActiveSpace {
            if window.occlusionState.contains(.visible) { bringBackOnceSeen(tab) }
        } else {
            PiP.follow(tab, slide: Spaces.direction(from: window))
        }
    }

    /// Back from Picture in Picture, but not while Mission Control shows the
    /// window small: the video grew to fill the screen on its way into it,
    /// then shrank. Once Mission Control closes, if it is still in sight;
    /// three seconds at most, so a video is never left out.
    private func bringBackOnceSeen(_ tab: Tab, tries: Int = 30) {
        guard Spaces.missionControl, tries > 0 else { return PiP.bringBack(tab) }
        if tries == 30 { Debug.log("pip", "\(tab.name): back once Mission Control is closed") }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self, weak tab] in
            guard let self, let window = self.window, let tab, tab === self.shell.selected,
                  window.isOnActiveSpace, window.occlusionState.contains(.visible) else { return }
            self.bringBackOnceSeen(tab, tries: tries - 1)
        }
    }

    /// Whether this tab's page is out of sight: not the one shown, or its
    /// window not seen.
    func outOfSight(_ tab: Tab) -> Bool {
        tab !== shell.selected || !(window?.occlusionState.contains(.visible) ?? false) || !(window?.isOnActiveSpace ?? false)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        Extensions.shared.controller.didFocusWindow(self)
        // The menu bar and the Dock hide for a window in BasicShell's full
        // screen only. Only what it set is taken back: macOS's own full
        // screen sets these options itself, and clearing them there left the
        // menu bar a black strip with nothing in it (measured).
        if edgeToEdge {
            resetReach()
            NSApp.presentationOptions = BrowserWindow.hiddenOptions
        } else if [BrowserWindow.hiddenOptions, BrowserWindow.reachOptions].contains(NSApp.presentationOptions) {
            NSApp.presentationOptions = []
        }
    }

    /// In BasicShell's own full screen the menu bar and the Dock are put
    /// away outright, so the top bar has the strip beside the notch to
    /// itself; pressed against their edge they come within reach, as macOS's
    /// auto-hiding ones (see reach(_:)). macOS hides the menu bar only with
    /// the Dock.
    private static let hiddenOptions: NSApplication.PresentationOptions = [.hideMenuBar, .hideDock]
    private static let reachOptions: NSApplication.PresentationOptions = [.autoHideMenuBar, .autoHideDock]

    func windowWillClose(_ notification: Notification) {
        if edgeToEdge { NSApp.presentationOptions = [] }
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        menuObservers.forEach(NotificationCenter.default.removeObserver)
        menuObservers = []
        reaching?.invalidate()
        menuBarWatch?.invalidate()
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
    /// The pointer moved while BasicShell isn't the app in front: the event
    /// monitor hears only what comes to the active app, and the sidebar
    /// waited for a click.
    var onMoveInBackground: ((NSPoint) -> Void)?

    override func layout() {
        super.layout()
        onLayout?()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        guard !NSApp.isActive else { return }
        onMoveInBackground?(convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        onExit?()
    }
}

/// The browser's window: its full screen may be BasicShell's own (see
/// BrowserWindow.coversNotch), which covers the menu bar's place.
final class ShellWindow: NSWindow {
    var edgeToEdge = false {
        didSet { if edgeToEdge != oldValue { squareCorners(edgeToEdge) } }
    }

    /// In BasicShell's own full screen the window has square corners: the
    /// screen's own curve at the top, square at the bottom, as the screen
    /// is. AppKit rounds a titled window's corners whatever it is told
    /// (its private radius, set or overridden, changed nothing: measured),
    /// so the window leaves its title bar off meanwhile; the top bar draws
    /// its own traffic lights there anyway.
    private var titledStyle: NSWindow.StyleMask?

    private func squareCorners(_ square: Bool) {
        // Changing the style hands the keyboard back to the window itself.
        let responder = firstResponder
        defer { if let responder, responder !== firstResponder { makeFirstResponder(responder) } }
        if square {
            titledStyle = styleMask
            // Not resizable either: at the screen's edges the pointer
            // turned into a resize arrow.
            styleMask.remove([.titled, .resizable])
            // Nor a shadow: its 1-point outline ran round the screen's edges.
            hasShadow = false
        } else if let titledStyle {
            styleMask = titledStyle
            hasShadow = true
            self.titledStyle = nil
        }
    }

    // Without a title bar a window would no longer take the keyboard.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    /// Without a title bar there is no close button, and AppKit would only
    /// beep.
    override func performClose(_ sender: Any?) {
        guard !styleMask.contains(.titled) else { return super.performClose(sender) }
        if delegate?.windowShouldClose?(self) ?? true { close() }
    }

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

/// Shows a message but lets every click through to what is under it. It
/// stays once made, a band across the window's width, and took the clicks
/// there: the lower half of the top bar in full screen, the first tabs in
/// the sidebar, the page (SwiftUI's allowsHitTesting doesn't stop the
/// hosting view itself from taking them).
final class ToastHost: NSHostingView<ToastView> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The loading line under the notch: seen, never in the way of a click.
final class LoadingHost: NSHostingView<LoadingLine> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// How far the page on show has loaded, in a short line at the top middle
/// of the window (under the notch in full screen, above the top bar).
struct LoadingLine: View {
    let shell: Shell

    var body: some View {
        let tab = shell.selected
        let showing = tab?.isLoading == true
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.2))
                Capsule().fill(Color.white)
                    .frame(width: geo.size.width * max(0.06, min(1, tab?.progress ?? 0)))
                    .animation(.linear(duration: 0.15), value: tab?.progress ?? 0)
            }
        }
        // Seen on a white page too.
        .shadow(color: .black.opacity(0.35), radius: 1.5)
        .opacity(showing ? 1 : 0)
        .animation(.easeOut(duration: 0.25), value: showing)
    }
}
