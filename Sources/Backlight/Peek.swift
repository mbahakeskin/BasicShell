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

/// Keeps its one subview, a single line of text, in the middle (the glass it
/// sits in sizes it, but a label draws at the top of whatever height it is given).
private final class CenteredBox: NSView {
    override func layout() {
        super.layout()
        guard let label = subviews.first else { return }
        let height: CGFloat = 16
        label.frame = NSRect(x: 12, y: (bounds.height - height) / 2, width: max(0, bounds.width - 24), height: height)
    }
}

/// The panel over the page: the page dimmed around it, and the card.
final class PeekView: NSView {
    let tab: Tab
    var onClose: (() -> Void)?
    var onKeep: (() -> Void)?

    private let card = NSView()
    // The title and the two buttons float over the dimmed page above the card,
    // each on a piece of glass, as the rest of the window is: no bar across the page.
    private let titlePill = NSGlassEffectView()
    private let controlsPill = NSGlassEffectView()
    private let controls = NSView()
    private let titleBox = CenteredBox()
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

        name.font = .systemFont(ofSize: 12, weight: .medium)
        name.lineBreakMode = .byTruncatingTail
        name.alignment = .center
        name.textColor = .labelColor
        titlePill.cornerRadius = Self.pillHeight / 2
        titleBox.addSubview(name)
        titlePill.contentView = titleBox
        addSubview(titlePill)
        controls.addSubview(button("arrow.up.left.and.arrow.down.right", #selector(keep), "Open as a Tab"))
        controls.addSubview(button("xmark", #selector(close), "Close (Esc)"))
        controlsPill.cornerRadius = Self.pillHeight / 2
        controlsPill.contentView = controls
        addSubview(controlsPill)

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

    private static let pillHeight: CGFloat = 28

    private func retitle() {
        let title = web.title ?? ""
        name.stringValue = title.isEmpty ? (web.url?.host() ?? "Loading…") : title
        needsLayout = true
    }

    @objc private func keep() { onKeep?() }
    @objc private func close() { onClose?() }

    override func layout() {
        super.layout()
        let inset = NSSize(width: max(24, bounds.width * 0.08), height: max(18, bounds.height * 0.06))
        let band = Self.pillHeight + 8
        // The page takes the whole card; the pills sit in the dimmed band above it.
        card.frame = NSRect(x: inset.width, y: inset.height, width: bounds.width - 2 * inset.width,
                            height: bounds.height - 2 * inset.height - band)
        web.frame = card.bounds
        let y = card.frame.maxY + 8
        // The two buttons at the card's right end.
        let controlsWidth: CGFloat = 2 * 28 + 8
        controlsPill.frame = NSRect(x: card.frame.maxX - controlsWidth, y: y, width: controlsWidth, height: Self.pillHeight)
        controls.frame = controlsPill.bounds
        for case let button as NSButton in controls.subviews {
            button.frame = NSRect(x: button.tag == 2 ? controls.bounds.width - 32 : 4, y: 2, width: 28, height: Self.pillHeight - 4)
        }
        // The title, as wide as it is, centred over the card, never into the buttons.
        let room = max(0, card.frame.width - 2 * (controlsWidth + 12))
        let wanted = name.attributedStringValue.size().width + 32
        let width = min(max(120, wanted), room)
        titlePill.frame = NSRect(x: card.frame.midX - width / 2, y: y, width: width, height: Self.pillHeight)
    }

    /// A click beside the card puts the peek away; inside it goes to the page.
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if !card.frame.contains(point), !titlePill.frame.contains(point), !controlsPill.frame.contains(point) { onClose?() }
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
