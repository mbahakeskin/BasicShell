import AppKit
import WebKit

// A peek at a link, Arc's way: Shift-click a link (or "Peek at Link" in its
// menu) and its page opens in a panel over the one you are reading, which stays
// where it was underneath. Esc, ⌘W, a click beside the panel or its cross puts
// it away; its other button keeps it, as a tab beside this one, loaded as it is.
//
// The page is a tab of its own, only not in the list: keeping it is putting it
// there, with nothing loaded twice. It uses the window's profile, so it is
// signed in where the page behind it is. Links inside it open in it; a window
// it opens by script becomes a tab as anywhere.

/// The panel over the page: the page dimmed around it, and the card.
final class PeekView: NSView {
    let tab: Tab
    var onClose: (() -> Void)?
    var onKeep: (() -> Void)?

    private let card = NSView()
    private let bar = NSView()
    private let name = NSTextField(labelWithString: "")
    private let web: WKWebView
    private var titleWatch: NSKeyValueObservation?
    private var addressWatch: NSKeyValueObservation?

    init(tab: Tab, web: WKWebView) {
        self.tab = tab
        self.web = web
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.38).cgColor

        card.wantsLayer = true
        card.layer?.cornerRadius = 14
        card.layer?.masksToBounds = true
        card.layer?.borderWidth = 1
        card.layer?.borderColor = NSColor.separatorColor.cgColor
        card.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        addSubview(card)

        bar.wantsLayer = true
        bar.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        card.addSubview(bar)
        name.font = .systemFont(ofSize: 12, weight: .medium)
        name.lineBreakMode = .byTruncatingTail
        name.alignment = .center
        bar.addSubview(name)
        bar.addSubview(button("arrow.up.left.and.arrow.down.right", #selector(keep), "Open as a Tab"))
        bar.addSubview(button("xmark", #selector(close), "Close (Esc)"))

        web.autoresizingMask = []
        card.addSubview(web)
        titleWatch = web.observe(\.title) { [weak self] _, _ in MainActor.assumeIsolated { self?.retitle() } }
        addressWatch = web.observe(\.url) { [weak self] _, _ in MainActor.assumeIsolated { self?.retitle() } }
        retitle()
    }

    required init?(coder: NSCoder) { nil }

    private func button(_ symbol: String, _ action: Selector, _ help: String) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: help) ?? NSImage(), target: self, action: action)
        button.isBordered = false
        button.toolTip = help
        button.tag = symbol == "xmark" ? 2 : 1
        return button
    }

    private func retitle() {
        let title = web.title ?? ""
        name.stringValue = title.isEmpty ? (web.url?.host() ?? "Loading…") : title
    }

    @objc private func keep() { onKeep?() }
    @objc private func close() { onClose?() }

    override func layout() {
        super.layout()
        let inset = NSSize(width: max(24, bounds.width * 0.08), height: max(18, bounds.height * 0.06))
        card.frame = bounds.insetBy(dx: inset.width, dy: inset.height)
        let barHeight: CGFloat = 34
        bar.frame = NSRect(x: 0, y: card.bounds.height - barHeight, width: card.bounds.width, height: barHeight)
        web.frame = NSRect(x: 0, y: 0, width: card.bounds.width, height: card.bounds.height - barHeight)
        for case let button as NSButton in bar.subviews {
            // The cross at the right end, the expand button beside it.
            let slot: CGFloat = button.tag == 2 ? 1 : 2
            button.frame = NSRect(x: bar.bounds.width - 30 * slot - 6, y: 5, width: 26, height: 24)
        }
        name.frame = NSRect(x: 70, y: 8, width: max(0, bar.bounds.width - 140), height: 18)
    }

    /// A click beside the card puts the peek away; inside it goes to the page.
    override func mouseDown(with event: NSEvent) {
        if !card.frame.contains(convert(event.locationInWindow, from: nil)) { onClose?() }
    }
}

extension BrowserWindow {
    /// The page at `url` over this one.
    func peek(_ url: URL, from opener: Tab?) {
        closePeek()
        guard let host = pageView.superview else { return }
        let tab = Tab(privately: opener?.isPrivate ?? shell.selected?.isPrivate ?? false, opening: url)
        tab.host = self
        tab.profile = shell.profile
        let web = tab.makeWebView()
        let view = PeekView(tab: tab, web: web)
        view.onClose = { [weak self] in self?.closePeek() }
        view.onKeep = { [weak self] in self?.keepPeek() }
        view.frame = pageView.frame
        host.addSubview(view, positioned: .above, relativeTo: pageView)
        peekView = view
        peekOpener = opener ?? shell.selected
        view.needsLayout = true
        tab.load(url)
        window?.makeFirstResponder(web)
    }

    /// Puts the peek away, with its page.
    func closePeek() {
        guard let view = peekView else { return }
        peekView = nil
        view.removeFromSuperview()
        view.tab.discard()
        if let web = shell.selected?.webView { window?.makeFirstResponder(web) }
    }

    /// Keeps it: the page becomes a tab beside the one it was opened from, and is shown.
    func keepPeek() {
        guard let view = peekView else { return }
        peekView = nil
        let tab = view.tab
        let opener = peekOpener
        tab.webView?.removeFromSuperview()
        view.removeFromSuperview()
        insert(tab, after: opener, select: true)
    }
}
