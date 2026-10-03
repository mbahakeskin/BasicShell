import AppKit

@main
enum Main {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { app.run() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Debug.start()
        LocationAccess.start()
        WebNotifications.start()
        Freeze.guardScripts()
        Sleep.start()
        NSApp.mainMenu = Menus.build()
        // Pages open once the extensions are in (see Extensions.start).
        Extensions.shared.start { [weak self] in self?.extensionsLoaded() }
    }

    private var ready = false
    private var waiting: [URL] = []

    private func extensionsLoaded() {
        ready = true
        if !Session.restored { Session.restore() }
        if Windows.all.isEmpty, waiting.isEmpty { Windows.open() }
        if !waiting.isEmpty { open(waiting) }
        waiting = []
        ExtensionMenuBar.update()
        NSApp.activate()
    }

    /// Back from the App Store with uBlock Origin Lite, perhaps.
    func applicationDidBecomeActive(_ notification: Notification) {
        guard ready, UserDefaults.standard.object(forKey: Extensions.blockerWanted) as? Bool == true,
              !Extensions.shared.hasBlocker else { return }
        Task { await Extensions.shared.addBlocker(asking: false) }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Session.saveBeforeQuitting { NSApp.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if ready, !hasVisibleWindows { Windows.open() }
        return true
    }

    /// Links from other apps, and files dropped on the Dock icon.
    func application(_ application: NSApplication, open urls: [URL]) {
        // A link that launched the app waits for the extensions.
        guard ready else { return waiting += urls }
        open(urls)
    }

    private func open(_ urls: [URL]) {
        if !Session.restored { Session.restore() }
        let window = Windows.front ?? Windows.open(empty: true)
        for url in urls { window.open(url, select: true) }
        window.window?.makeKeyAndOrderFront(nil)
    }

    // MARK: - menu actions that need no window

    @objc func newWindow(_ sender: Any?) { Windows.open() }
    @objc func newTab(_ sender: Any?) { Windows.open() }
    @objc func newPrivateTab(_ sender: Any?) { Windows.open(privately: true) }

    /// The standard panel, with who made it and where it lives.
    @objc func showAbout(_ sender: Any?) {
        let credits = NSMutableAttributedString(string: "Made by Mehmet Baha Keskin\n", attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize), .foregroundColor: NSColor.labelColor,
        ])
        credits.append(NSAttributedString(string: "github.com/mbahakeskin/BasicShell", attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .link: URL(string: "https://github.com/mbahakeskin/BasicShell")!,
        ]))
        let centered = NSMutableParagraphStyle()
        centered.alignment = .center
        credits.addAttribute(.paragraphStyle, value: centered, range: NSRange(location: 0, length: credits.length))
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
        NSApp.activate()
    }

    @objc func showSettings(_ sender: Any?) { SettingsWindow.show() }
    @objc func showDebugLog(_ sender: Any?) { DebugWindow.show() }

    @objc func reopenTab(_ sender: Any?) {
        guard let last = Closed.tabs.popLast() else { return NSSound.beep() }
        open(last.url)
    }

    /// A bookmark or a recently closed tab from the menu bar.
    @objc func openMenuPage(_ sender: NSMenuItem) {
        if let url = sender.representedObject as? URL { open(url) }
    }

    private func open(_ url: URL) {
        let window = Windows.front ?? Windows.open(empty: true)
        window.open(url, select: true)
        window.window?.makeKeyAndOrderFront(nil)
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(reopenTab(_:)) { return !Closed.tabs.isEmpty }
        return true
    }

}

/// Every open browser window, front to back as AppKit orders them.
enum Windows {
    static var all: [BrowserWindow] = []

    static var front: BrowserWindow? {
        NSApp.orderedWindows.lazy.compactMap { $0.windowController as? BrowserWindow }.first
            ?? all.last
    }

    /// A new window. Unless `empty`, it opens with the address field up,
    /// the way a new tab does.
    @discardableResult
    static func open(empty: Bool = false, privately: Bool = false) -> BrowserWindow {
        let window = BrowserWindow()
        all.append(window)
        Extensions.shared.controller.didOpenWindow(window)
        window.showWindow(nil)
        if !empty { window.ask(.newTab(privately: privately)) }
        return window
    }

    static func closed(_ window: BrowserWindow) {
        all.removeAll { $0 === window }
        Extensions.shared.controller.didCloseWindow(window)
    }
}
