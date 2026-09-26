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

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Shield.shared.compile()
        NSApp.mainMenu = Menus.build()
        if Windows.all.isEmpty { Windows.open() }
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { Windows.open() }
        return true
    }

    /// Links from other apps, and files dropped on the Dock icon.
    func application(_ application: NSApplication, open urls: [URL]) {
        let window = Windows.front ?? Windows.open(empty: true)
        for url in urls { window.open(url, select: true) }
        window.window?.makeKeyAndOrderFront(nil)
    }

    // MARK: - menu actions that need no window

    @objc func newWindow(_ sender: Any?) { Windows.open() }
    @objc func newTab(_ sender: Any?) { Windows.open() }
    @objc func newPrivateTab(_ sender: Any?) { Windows.open(privately: true) }
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
        window.showWindow(nil)
        if !empty { window.ask(.newTab(privately: privately)) }
        return window
    }

    static func closed(_ window: BrowserWindow) {
        all.removeAll { $0 === window }
    }
}
