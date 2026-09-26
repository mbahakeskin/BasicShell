import AppKit

// The menu bar. Actions travel the responder chain: the page for editing, the
// window controller for tabs, the app delegate when no window is open.
enum Menus {
    static func build() -> NSMenu {
        let main = NSMenu()
        main.addItem(submenu(app()))
        main.addItem(submenu(file()))
        main.addItem(submenu(edit()))
        main.addItem(submenu(view()))
        main.addItem(submenu(history()))
        let window = window()
        main.addItem(submenu(window))
        NSApp.windowsMenu = window
        return main
    }

    private static func submenu(_ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    private static func item(_ title: String, _ action: Selector?, _ key: String = "", _ mods: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = key.isEmpty ? [] : mods
        return item
    }

    private static func app() -> NSMenu {
        let menu = NSMenu(title: "BasicShell")
        menu.addItem(item("About BasicShell", #selector(NSApplication.orderFrontStandardAboutPanel(_:))))
        menu.addItem(.separator())
        let services = item("Services", nil)
        services.submenu = NSMenu(title: "Services")
        NSApp.servicesMenu = services.submenu
        menu.addItem(services)
        menu.addItem(.separator())
        menu.addItem(item("Hide BasicShell", #selector(NSApplication.hide(_:)), "h"))
        menu.addItem(item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]))
        menu.addItem(item("Show All", #selector(NSApplication.unhideAllApplications(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Quit BasicShell", #selector(NSApplication.terminate(_:)), "q"))
        return menu
    }

    private static func file() -> NSMenu {
        let menu = NSMenu(title: "File")
        menu.addItem(item("New Tab", #selector(AppDelegate.newTab(_:)), "t"))
        menu.addItem(item("New Private Tab", #selector(AppDelegate.newPrivateTab(_:)), "n", [.command, .shift]))
        menu.addItem(item("New Window", #selector(AppDelegate.newWindow(_:)), "n"))
        menu.addItem(item("Open Location…", #selector(BrowserWindow.openLocation(_:)), "l"))
        menu.addItem(.separator())
        menu.addItem(item("Close Tab", #selector(BrowserWindow.closeTab(_:)), "w"))
        menu.addItem(item("Close Window", #selector(NSWindow.performClose(_:)), "w", [.command, .shift]))
        menu.addItem(item("Reopen Closed Tab", #selector(BrowserWindow.reopenTab(_:)), "t", [.command, .shift]))
        return menu
    }

    private static func edit() -> NSMenu {
        let menu = NSMenu(title: "Edit")
        menu.addItem(item("Undo", Selector(("undo:")), "z"))
        menu.addItem(item("Redo", Selector(("redo:")), "z", [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(item("Cut", #selector(NSText.cut(_:)), "x"))
        menu.addItem(item("Copy", #selector(NSText.copy(_:)), "c"))
        menu.addItem(item("Paste", #selector(NSText.paste(_:)), "v"))
        menu.addItem(item("Paste and Match Style", #selector(NSTextView.pasteAsPlainText(_:)), "v", [.command, .option, .shift]))
        menu.addItem(item("Select All", #selector(NSText.selectAll(_:)), "a"))
        menu.addItem(.separator())
        menu.addItem(item("Copy Address", #selector(BrowserWindow.copyAddress(_:)), "c", [.command, .shift]))
        menu.addItem(.separator())
        let find = item("Find", nil)
        let sub = NSMenu(title: "Find")
        let findItem = item("Find…", #selector(NSResponder.performTextFinderAction(_:)), "f")
        findItem.tag = NSTextFinder.Action.showFindInterface.rawValue
        let next = item("Find Next", #selector(NSResponder.performTextFinderAction(_:)), "g")
        next.tag = NSTextFinder.Action.nextMatch.rawValue
        let previous = item("Find Previous", #selector(NSResponder.performTextFinderAction(_:)), "g", [.command, .shift])
        previous.tag = NSTextFinder.Action.previousMatch.rawValue
        sub.items = [findItem, next, previous]
        find.submenu = sub
        menu.addItem(find)
        return menu
    }

    private static func view() -> NSMenu {
        let menu = NSMenu(title: "View")
        menu.addItem(item("Reload Page", #selector(BrowserWindow.reload(_:)), "r"))
        menu.addItem(.separator())
        menu.addItem(item("Actual Size", #selector(BrowserWindow.actualSize(_:)), "0"))
        menu.addItem(item("Zoom In", #selector(BrowserWindow.zoomIn(_:)), "+"))
        menu.addItem(item("Zoom Out", #selector(BrowserWindow.zoomOut(_:)), "-"))
        menu.addItem(.separator())
        menu.addItem(item("Keep Sidebar Open", #selector(BrowserWindow.toggleSidebarPinned(_:)), "s", [.command, .control]))
        menu.addItem(item("Keep Top Bar Open", #selector(BrowserWindow.toggleTopBarPinned(_:)), "b", [.command, .control]))
        menu.addItem(.separator())
        menu.addItem(item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]))
        return menu
    }

    private static func history() -> NSMenu {
        let menu = NSMenu(title: "History")
        menu.addItem(item("Back", #selector(BrowserWindow.goBack(_:)), "["))
        menu.addItem(item("Forward", #selector(BrowserWindow.goForward(_:)), "]"))
        return menu
    }

    private static func window() -> NSMenu {
        let menu = NSMenu(title: "Window")
        menu.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"))
        menu.addItem(item("Zoom", #selector(NSWindow.performZoom(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Next Tab", #selector(BrowserWindow.nextTab(_:)), "\t", .control))
        menu.addItem(item("Previous Tab", #selector(BrowserWindow.previousTab(_:)), "\t", [.control, .shift]))
        menu.addItem(.separator())
        menu.addItem(item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))))
        return menu
    }
}
