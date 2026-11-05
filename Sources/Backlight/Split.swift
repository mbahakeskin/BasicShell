import AppKit
import Observation
import SwiftUI

// Split view: two tabs side by side in the window, a divider between them
// to drag, a thin frame in the accent colour round the one that has the
// keyboard. That one is the tab shown as far as everything else goes: the
// address field, Find, zoom, reload, Picture in Picture and the agent's tools
// act on it; a click in the other half moves the keyboard there.
//
// It is a state of the window, not a kind of tab: going to any other tab
// (or closing one of the two) ends it, and the two tabs go on as they were.

final class SplitPair {
    let first: Tab
    let second: Tab
    var ratio: CGFloat = 0.5

    init(first: Tab, second: Tab) {
        self.first = first
        self.second = second
    }

    func contains(_ tab: Tab) -> Bool { tab === first || tab === second }
    func other(than tab: Tab) -> Tab { tab === first ? second : first }
}

extension Shell {
    /// The tab beside the one with the keyboard, while the window is split.
    var partner: Tab? { selected.flatMap { split?.contains($0) == true ? split?.other(than: $0) : nil } }
}

/// The bar between the halves: dragged, it moves them.
final class SplitDivider: NSView {
    var dragged: ((CGFloat) -> Void)?

    override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }

    override func mouseDown(with event: NSEvent) {}

    override func mouseDragged(with event: NSEvent) {
        guard let page = superview else { return }
        dragged?(page.convert(event.locationInWindow, from: nil).x / max(1, page.bounds.width))
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.withAlphaComponent(0.6).setFill()
        NSBezierPath(roundedRect: NSRect(x: bounds.midX - 1.5, y: bounds.midY - 22, width: 3, height: 44), xRadius: 1.5, yRadius: 1.5).fill()
    }
}

/// The frame round the half that has the keyboard; takes no clicks.
final class SplitFocusFrame: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.borderWidth = 2
        layer?.cornerRadius = 8
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func updateLayer() { layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.8).cgColor }
    override var wantsUpdateLayer: Bool { true }
}

extension BrowserWindow {
    private static let gap: CGFloat = 8

    /// The tab beside the one shown, the new tab on its right.
    func splitWith(_ tab: Tab) {
        guard let current = shell.selected, tab !== current, shell.tabs.contains(tab), !tab.isPrivate || current.isPrivate else { return }
        endSplit()
        shell.split = SplitPair(first: current, second: tab)
        Freeze.thaw(tab)
        let web = tab.makeWebView()
        web.isHidden = false
        if web.superview !== pageView { pageView.addSubview(web) }
        tab.lastSeen = Date()
        if splitDivider == nil {
            let divider = SplitDivider()
            divider.dragged = { [weak self] ratio in
                guard let self, let split = self.shell.split else { return }
                split.ratio = min(0.8, max(0.2, ratio))
                self.applySplit()
            }
            let focus = SplitFocusFrame(frame: .zero)
            pageView.addSubview(divider, positioned: .above, relativeTo: nil)
            pageView.addSubview(focus, positioned: .above, relativeTo: nil)
            splitDivider = divider
            splitFocus = focus
        }
        // A click in the half without the keyboard gives it the keyboard.
        splitMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            MainActor.assumeIsolated {
                if let self, event.window === self.window, let partner = self.shell.partner, let web = partner.webView, web.window != nil,
                   web.bounds.contains(web.convert(event.locationInWindow, from: nil)) {
                    self.select(partner)
                }
            }
            return event
        }
        applySplit()
        Session.touch()
    }

    /// A link opened in a tab of its own, beside this one.
    func openSideBySide(_ url: URL, from tab: Tab?) {
        let new = Tab(privately: tab?.isPrivate ?? false, opening: url)
        insert(new, after: tab, select: false)
        new.load(url)
        splitWith(new)
    }

    /// Back to the one page: the other half goes out of sight like any tab left.
    func endSplit() {
        guard let split = shell.split else { return }
        let gone = shell.selected.map { split.other(than: $0) } ?? split.second
        shell.split = nil
        if let monitor = splitMonitor { NSEvent.removeMonitor(monitor) }
        splitMonitor = nil
        splitDivider?.removeFromSuperview()
        splitFocus?.removeFromSuperview()
        splitDivider = nil
        splitFocus = nil
        if let web = shell.selected?.webView {
            web.frame = pageView.bounds
            web.autoresizingMask = [.width, .height]
        }
        guard let web = gone.webView, gone !== shell.selected else { return }
        gone.leavingScreen { [weak self, weak gone] in
            guard let self, let gone, gone !== self.shell.selected, gone.webView === web, self.shell.split?.contains(gone) != true else { return }
            if PiP.holds(gone) || gone.isWorkedIn {
                self.pageView.addSubview(web, positioned: .below, relativeTo: nil)
                web.autoresizingMask = [.width, .height]
                web.frame = self.pageView.bounds
            } else if Sleep.keepsAwake(gone.url) {
                web.isHidden = true
            } else {
                web.removeFromSuperview()
                Sleep.freezeIfIdle(gone)
            }
        }
        Session.touch()
    }

    /// Both halves where they go: on every layout, and when the divider moves
    /// or the keyboard does.
    func applySplit() {
        guard let split = shell.split else { return }
        guard shell.tabs.contains(split.first), shell.tabs.contains(split.second),
              let left = split.first.webView, let right = split.second.webView
        else { return endSplit() }
        let bounds = pageView.bounds
        let gap = Self.gap
        let leftWidth = ((bounds.width - gap) * split.ratio).rounded()
        left.autoresizingMask = []
        right.autoresizingMask = []
        left.frame = NSRect(x: 0, y: 0, width: leftWidth, height: bounds.height)
        right.frame = NSRect(x: leftWidth + gap, y: 0, width: bounds.width - leftWidth - gap, height: bounds.height)
        splitDivider?.frame = NSRect(x: leftWidth, y: 0, width: gap, height: bounds.height)
        splitDivider?.window?.invalidateCursorRects(for: splitDivider!)
        splitDivider?.needsDisplay = true
        if let focused = shell.selected?.webView {
            splitFocus?.frame = focused.frame.insetBy(dx: 0.5, dy: 0.5)
        }
        pageView.addSubview(left, positioned: .below, relativeTo: splitDivider)
        pageView.addSubview(right, positioned: .below, relativeTo: splitDivider)
    }

    /// The keyboard moved to the other half (a click, or its row in the sidebar).
    func focusSplit(on tab: Tab) {
        guard let window, shell.split?.contains(tab) == true, tab !== shell.selected else { return }
        let previous = shell.selected
        shell.selected = tab
        recordSeen(tab)
        self.window?.title = tab.name
        Extensions.shared.activated(tab, previous: previous)
        tab.refreshAudio()
        if let web = tab.webView { window.makeFirstResponder(web) }
        if shell.finding, let web = tab.webView {
            finder.clear(previous?.webView)
            finder.search(shell.find.text, in: web)
        }
        applySplit()
        Session.touch()
    }
}
