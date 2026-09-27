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
        Freeze.guardScripts()
        Shield.shared.start()
        Sleep.start()
        NSApp.mainMenu = Menus.build()
        if !Session.restored { Session.restore() }
        if Windows.all.isEmpty { Windows.open() }
        Extensions.shared.start()
        NSApp.activate()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Session.saveBeforeQuitting { NSApp.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { Windows.open() }
        return true
    }

    /// Links from other apps, and files dropped on the Dock icon.
    func application(_ application: NSApplication, open urls: [URL]) {
        // A link that launched the app comes before the last session is back.
        if !Session.restored { Session.restore() }
        let window = Windows.front ?? Windows.open(empty: true)
        for url in urls { window.open(url, select: true) }
        window.window?.makeKeyAndOrderFront(nil)
    }

    // MARK: - menu actions that need no window

    @objc func newWindow(_ sender: Any?) { Windows.open() }
    @objc func newTab(_ sender: Any?) { Windows.open() }
    @objc func newPrivateTab(_ sender: Any?) { Windows.open(privately: true) }

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

    @objc func updateBlockLists(_ sender: Any?) {
        Task {
            let result = await Shield.shared.update()
            if let window = Windows.front { window.say(result) } else { NSSound.beep() }
        }
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
