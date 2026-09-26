import AppKit

// The traffic lights, centred in the top bar and shown only while it is.
//
// There is no NSToolbar: on macOS 26 and later a toolbar also rounds the
// window's corners much more. So the buttons are placed by hand, and put back
// every time AppKit lays the title bar out again. Adapted from Search's
// Lights.swift (Office Commun, MIT).
final class Lights: NSObject {
    /// The close button's centre, from the window's top-left: the middle of
    /// the top bar's height, a bar's inset in from the edge.
    static let centre = CGPoint(x: Metrics.inset + 20, y: Metrics.inset + Metrics.bar / 2)

    private weak var window: NSWindow?
    private var placing = false
    /// AppKit's own spacing between the buttons, read once from its first
    /// layout; read later it can be caught mid-relayout.
    private let spacing: CGFloat
    private(set) var visible = true

    init(_ window: NSWindow) {
        self.window = window
        let row = [NSWindow.ButtonType.closeButton, .miniaturizeButton].compactMap { window.standardWindowButton($0) }
        let measured = row.count == 2 ? row[1].frame.minX - row[0].frame.minX : 0
        spacing = (16...32).contains(measured) ? measured : 20
        super.init()
        let centre = NotificationCenter.default
        for name in [
            NSWindow.didResizeNotification, NSWindow.didEndLiveResizeNotification,
            NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
            NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification,
            NSWindow.didChangeScreenNotification,
        ] {
            centre.addObserver(self, selector: #selector(relaid), name: name, object: window)
        }
        if let bar = buttons.first?.superview, let container = bar.superview {
            for view in [container, bar] + buttons {
                view.postsFrameChangedNotifications = true
                centre.addObserver(self, selector: #selector(relaid), name: NSView.frameDidChangeNotification, object: view)
            }
        }
        place()
    }

    private var buttons: [NSButton] {
        [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap { window?.standardWindowButton($0) }
    }

    private var container: NSView? { buttons.first?.superview?.superview }

    private var fullScreen: Bool { window?.styleMask.contains(.fullScreen) ?? false }

    func show(_ visible: Bool, animated: Bool) {
        self.visible = visible
        guard let container, !fullScreen else { return }
        if visible { container.isHidden = false }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = animated ? Motion.reveal : 0
            container.animator().alphaValue = visible ? 1 : 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                if self?.visible == false { container.isHidden = true }
            }
        }
    }

    /// AppKit laid the title bar out again. It sometimes moves a button while
    /// the others are being placed (a new window title does it), so the
    /// buttons are placed now and once more after AppKit has finished.
    @objc private func relaid() {
        place()
        DispatchQueue.main.async { [weak self] in self?.place() }
    }

    private func place() {
        guard !placing, let window else { return }
        // Full screen keeps the title bar in a window of its own that macOS
        // may never bring down; the top bar draws its own lights there
        // (FullScreenLights in TopBar.swift), so these stay out of the way.
        // That window stays over the top of the screen even while it is up
        // out of sight, and would take the clicks meant for the top bar.
        if fullScreen {
            container?.isHidden = true
            // Only once the title bar has moved to that window: mid-way
            // through the transition it is still in this one.
            if let strip = container?.window, strip !== window { strip.ignoresMouseEvents = true }
            return
        }
        let buttons = self.buttons
        guard buttons.count == 3, let bar = buttons[0].superview, let container = bar.superview else { return }
        placing = true
        defer { placing = false }

        let height = Metrics.inset * 2 + Metrics.bar
        var frame = container.frame
        if frame.height != height || frame.maxY != window.frame.height {
            frame.size.height = height
            frame.origin.y = window.frame.height - height
            container.frame = frame
        }
        for (index, button) in buttons.enumerated() {
            let size = button.frame.size
            let origin = NSPoint(
                x: Lights.centre.x - size.width / 2 + CGFloat(index) * spacing,
                y: bar.bounds.height - Lights.centre.y - size.height / 2
            )
            if button.frame.origin != origin { button.setFrameOrigin(origin) }
        }
        container.isHidden = !visible
        container.alphaValue = visible ? 1 : 0
    }
}
