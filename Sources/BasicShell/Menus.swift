import AppKit

// The menu bar. Actions travel the responder chain: the page for editing, the
// window controller for tabs, the app delegate when no window is open.
enum Menus {
    static func build() -> NSMenu {
        let main = NSMenu()
        for menu in [app(), file(), edit(), view(), history(), bookmarks(), tab(), ExtensionsMenu.build(), window()] {
            let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
            item.submenu = menu
            main.addItem(item)
        }
        return main
    }

    fileprivate static func item(_ title: String, _ action: Selector?, _ key: String = "", _ mods: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = key.isEmpty ? [] : mods
        return item
    }

    private static func app() -> NSMenu {
        let menu = NSMenu(title: "BasicShell")
        menu.addItem(item("About BasicShell", #selector(AppDelegate.showAbout(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Settings…", #selector(AppDelegate.showSettings(_:)), ","))
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
        menu.addItem(.separator())
        menu.addItem(item("Open Location…", #selector(BrowserWindow.openLocation(_:)), "l"))
        menu.addItem(item("Open File…", #selector(BrowserWindow.openFile(_:)), "o"))
        menu.addItem(.separator())
        menu.addItem(item("Close Tab", #selector(BrowserWindow.closeTab(_:)), "w"))
        menu.addItem(item("Close Window", #selector(NSWindow.performClose(_:)), "w", [.command, .shift]))
        menu.addItem(item("Reopen Closed Tab", #selector(AppDelegate.reopenTab(_:)), "t", [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(item("Print…", #selector(BrowserWindow.printPage(_:)), "p"))
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
        let entries: [(String, String, NSEvent.ModifierFlags, NSTextFinder.Action)] = [
            ("Find…", "f", .command, .showFindInterface),
            ("Find Next", "g", .command, .nextMatch),
            ("Find Previous", "g", [.command, .shift], .previousMatch),
            ("Use Selection for Find", "e", .command, .setSearchString),
        ]
        for (title, key, mods, action) in entries {
            let entry = item(title, #selector(NSResponder.performTextFinderAction(_:)), key, mods)
            entry.tag = action.rawValue
            sub.addItem(entry)
        }
        find.submenu = sub
        menu.addItem(find)
        menu.addItem(.separator())
        menu.addItem(item("Emoji & Symbols", #selector(NSApplication.orderFrontCharacterPalette(_:)), " ", [.command, .control]))
        return menu
    }

    private static func view() -> NSMenu {
        let menu = NSMenu(title: "View")
        menu.addItem(item("Reload Page", #selector(BrowserWindow.reload(_:)), "r"))
        menu.addItem(item("Stop", #selector(BrowserWindow.stopLoading(_:)), "."))
        menu.addItem(.separator())
        menu.addItem(item("Actual Size", #selector(BrowserWindow.actualSize(_:)), "0"))
        menu.addItem(item("Zoom In", #selector(BrowserWindow.zoomIn(_:)), "+"))
        // ⌘= as well, where + needs Shift.
        let zoomIn = item("Zoom In", #selector(BrowserWindow.zoomIn(_:)), "=")
        zoomIn.isHidden = true
        zoomIn.allowsKeyEquivalentWhenHidden = true
        menu.addItem(zoomIn)
        menu.addItem(item("Zoom Out", #selector(BrowserWindow.zoomOut(_:)), "-"))
        menu.addItem(.separator())
        menu.addItem(item("Keep Sidebar Open", #selector(BrowserWindow.toggleSidebarPinned(_:)), "s", [.command, .control]))
        menu.addItem(item("Keep Top Bar Open", #selector(BrowserWindow.toggleTopBarPinned(_:)), "b", [.command, .control]))
        menu.addItem(.separator())
        menu.addItem(item("Picture in Picture", #selector(BrowserWindow.pictureInPicture(_:)), "p", [.command, .shift]))
        menu.addItem(item("Downloads", #selector(BrowserWindow.showDownloads(_:)), "l", [.command, .option]))
        menu.addItem(item("Debug Log", #selector(AppDelegate.showDebugLog(_:)), "d", [.command, .option]))
        menu.addItem(.separator())
        menu.addItem(item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]))
        return menu
    }

    private static func history() -> NSMenu {
        let menu = NSMenu(title: "History")
        menu.addItem(item("Back", #selector(BrowserWindow.goBack(_:)), "["))
        menu.addItem(item("Forward", #selector(BrowserWindow.goForward(_:)), "]"))
        menu.addItem(.separator())
        menu.addItem(item("Show All History", #selector(BrowserWindow.showHistory(_:)), "y"))
        let recent = item("Recently Closed", nil)
        let sub = NSMenu(title: "Recently Closed")
        sub.delegate = Dynamic.shared
        recent.submenu = sub
        menu.addItem(recent)
        menu.addItem(.separator())
        menu.addItem(item("Clear History…", #selector(BrowserWindow.clearHistory(_:))))
        return menu
    }

    private static func bookmarks() -> NSMenu {
        let menu = NSMenu(title: "Bookmarks")
        menu.delegate = Dynamic.shared
        return menu
    }

    private static func tab() -> NSMenu {
        let menu = NSMenu(title: "Tab")
        menu.addItem(item("Pin Tab", #selector(BrowserWindow.togglePin(_:))))
        menu.addItem(item("Duplicate Tab", #selector(BrowserWindow.duplicateTab(_:))))
        menu.addItem(item("Move Tab to New Window", #selector(BrowserWindow.moveTabToNewWindow(_:))))
        menu.addItem(item("Archive Tab", #selector(BrowserWindow.archiveTab(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Keep This Site Awake", #selector(BrowserWindow.toggleAwake(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Next Tab", #selector(BrowserWindow.nextTab(_:)), "\t", .control))
        menu.addItem(item("Previous Tab", #selector(BrowserWindow.previousTab(_:)), "\t", [.control, .shift]))
        menu.addItem(.separator())
        menu.addItem(item("Show Archived Tabs", #selector(BrowserWindow.showArchive(_:)), "a", [.command, .option]))
        return menu
    }

    private static func window() -> NSMenu {
        let menu = NSMenu(title: "Window")
        menu.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"))
        menu.addItem(item("Zoom", #selector(NSWindow.performZoom(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))))
        NSApp.windowsMenu = menu
        return menu
    }

    /// Fills the menus whose items change: bookmarks and recently closed tabs.
    final class Dynamic: NSObject, NSMenuDelegate {
        static let shared = Dynamic()

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            if menu.title == "Bookmarks" {
                menu.addItem(Menus.item("Bookmark This Page", #selector(BrowserWindow.bookmarkPage(_:)), "d"))
                menu.addItem(Menus.item("Show Bookmarks", #selector(BrowserWindow.showBookmarks(_:)), "b", [.command, .option]))
                let marks = Bookmarks.shared.marks
                if !marks.isEmpty { menu.addItem(.separator()) }
                for mark in marks.prefix(40) { menu.addItem(page(mark.title, mark.url)) }
            } else {
                let closed = Closed.tabs.reversed()
                if closed.isEmpty {
                    let none = Menus.item("No Recently Closed Tabs", nil)
                    none.isEnabled = false
                    menu.addItem(none)
                }
                for entry in closed.prefix(20) { menu.addItem(page(entry.title, entry.url)) }
            }
        }

        private func page(_ title: String, _ url: URL) -> NSMenuItem {
            let entry = NSMenuItem(title: title.isEmpty ? Address.pretty(url) : title, action: #selector(AppDelegate.openMenuPage(_:)), keyEquivalent: "")
            entry.representedObject = url
            entry.toolTip = url.absoluteString
            return entry
        }
    }
}

/// Tabs closed this session, across windows, newest last.
enum Closed {
    static var tabs: [(url: URL, title: String)] = []

    static func add(_ tab: Tab) {
        guard !tab.isPrivate, let url = tab.url else { return }
        tabs.append((url, tab.title))
        if tabs.count > 50 { tabs.removeFirst() }
    }
}
