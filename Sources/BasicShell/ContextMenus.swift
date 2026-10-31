import AppKit
import WebKit

// What a right click on a page offers, by what is under the pointer, as in
// Safari. WebKit's own menu gave little on a page (Back, Forward, Reload),
// "in New Window" for links and images in a browser of tabs, and "Search With
// Google" in whatever browser the Mac sends searches to.
//
// WebKit hands the menu over before showing it, with what was clicked, to a
// delegate that answers its private `_webView:contextMenu:forElement:`; the
// items it already has (download, copy image, share, look up, translate,
// Inspect Element) are kept and found by their identifiers.
extension Tab {
    @objc(_webView:contextMenu:forElement:)
    func contextMenu(_ webView: WKWebView, _ proposed: NSMenu, _ element: NSObject) -> NSMenu {
        let hit = element.value(forKey: "hitTestResult") as? NSObject
        let link = hit?.value(forKey: "absoluteLinkURL") as? URL
        let image = hit?.value(forKey: "absoluteImageURL") as? URL
        let media = hit?.value(forKey: "absoluteMediaURL") as? URL
        let editable = hit?.value(forKey: "isContentEditable") as? Bool ?? false
        let selected = hit?.value(forKey: "isSelected") as? Bool ?? false

        let webKit = proposed.items
        func kept(_ name: String) -> NSMenuItem? {
            guard let item = webKit.first(where: { $0.identifier?.rawValue.hasSuffix(name) == true }) else { return nil }
            proposed.removeItem(item)
            return item
        }
        let inspect = kept("InspectElement")

        // Typing, a video, or chosen text: WebKit's menu (spelling, paste,
        // controls, look up, translate…), without what doesn't fit here.
        if link == nil, image == nil, editable || media != nil || selected {
            let menu = NSMenu()
            for item in proposed.items {
                let name = item.identifier?.rawValue ?? ""
                if name.hasSuffix("InNewWindow") { continue }
                if name.hasSuffix("SearchWeb") {
                    menu.addItem(searchItem())
                    continue
                }
                proposed.removeItem(item)
                menu.addItem(item)
            }
            if let inspect { menu.addItem(.separator()); menu.addItem(inspect) }
            return tidy(menu)
        }

        let menu = NSMenu()
        if let link {
            menu.addItem(action("Open Link in New Tab") { [weak self] in self?.host?.open(link, from: self, select: true) })
            menu.addItem(action("Open Link in Background Tab") { [weak self] in self?.host?.open(link, from: self, select: false) })
            if let window = host as? BrowserWindow {
                menu.addItem(action("Peek at Link") { [weak self] in window.peek(link, from: self) })
            }
            if let window = host as? BrowserWindow, !isPrivate {
                menu.addItem(action("Open Link Side by Side") { [weak self] in window.openSideBySide(link, from: self) })
            }
            if !isPrivate {
                menu.addItem(action("Open Link in Private Tab") { [weak self] in (self?.host as? BrowserWindow)?.openPrivately(link) })
            }
            menu.addItem(.separator())
            if let download = kept("DownloadLinkedFile") { menu.addItem(download) }
            menu.addItem(action("Copy Link") { Tab.copy(link.absoluteString) })
            if let share = kept("ShareMenu") { menu.addItem(.separator()); menu.addItem(share) }
        }
        if let image {
            menu.addItem(.separator())
            menu.addItem(action("Open Image in New Tab") { [weak self] in self?.host?.open(image, from: self, select: true) })
            if let copy = kept("CopyImage") { menu.addItem(copy) }
            menu.addItem(action("Copy Image Address") { Tab.copy(image.absoluteString) })
            if let download = kept("DownloadImage") {
                download.title = "Save Image to Downloads"
                menu.addItem(download)
            }
        }
        if link == nil, image == nil {
            let window = host as? BrowserWindow
            let back = action("Back") { webView.goBack() }
            back.isEnabled = webView.canGoBack
            let forward = action("Forward") { webView.goForward() }
            forward.isEnabled = webView.canGoForward
            menu.addItem(back)
            menu.addItem(forward)
            menu.addItem(action(isLoading ? "Stop" : "Reload") { window?.reload(nil) })
            if url != nil {
                if let window {
                    menu.addItem(.separator())
                    let row = NSMenuItem()
                    row.view = ZoomRow(window: window)
                    menu.addItem(row)
                    menu.addItem(action("Actual Size") { window.actualSize(nil) })
                    if ["http", "https"].contains(url?.scheme ?? "") {
                        menu.addItem(action(isTranslated ? "Show Original Page" : "Translate Page") { window.translatePage(nil) })
                    }
                }
                menu.addItem(.separator())
                menu.addItem(action("Copy Address") { window?.copyAddress(nil) })
                if !isPrivate {
                    let kept = Bookmarks.shared.contains(url)
                    menu.addItem(action(kept ? "Remove Bookmark" : "Add Bookmark") { window?.bookmarkPage(nil) })
                }
                if url?.host() != nil {
                    let awake = Awake.shared.contains(url)
                    menu.addItem(action(awake ? "Let This Site Sleep" : "Keep This Site Awake") { window?.toggleAwake(nil) })
                }
            }
        }
        #if AGENT
        if AgentAccess.enabled, url != nil {
            menu.addItem(.separator())
            menu.addItem(action("Pick Element for the Agent") { [weak self] in if let self { AgentPick.ask(self) } })
        }
        #endif
        if let inspect { menu.addItem(.separator()); menu.addItem(inspect) }
        return tidy(menu)
    }

    /// The text chosen on the page, searched for in a new tab with the
    /// search engine set in Settings.
    private func searchItem() -> NSMenuItem {
        action("Search in New Tab") { [weak self] in
            self?.webView?.evaluateJavaScript("String(getSelection())") { result, _ in
                guard let self, let text = (result as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !text.isEmpty, let url = Address.resolve(text) else { return }
                self.host?.open(url, from: self, select: true)
            }
        }
    }

    private static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func action(_ title: String, _ run: @escaping () -> Void) -> NSMenuItem {
        let action = MenuAction(run)
        let item = NSMenuItem(title: title, action: #selector(MenuAction.fire), keyEquivalent: "")
        item.target = action
        item.representedObject = action
        return item
    }

    /// No separator first, last, or twice.
    private func tidy(_ menu: NSMenu) -> NSMenu {
        var previousWasSeparator = true
        for item in menu.items {
            if item.isSeparatorItem, previousWasSeparator { menu.removeItem(item) } else { previousWasSeparator = item.isSeparatorItem }
        }
        if let last = menu.items.last, last.isSeparatorItem { menu.removeItem(last) }
        return menu
    }
}

/// What a menu item made here runs; kept alive as the item's represented
/// object.
final class MenuAction: NSObject {
    private let run: () -> Void
    init(_ run: @escaping () -> Void) { self.run = run }
    @objc func fire() { run() }
}

/// "Zoom  −  120%  +" as one row of a page's menu. Its buttons don't close the
/// menu, so the percentage follows each press.
final class ZoomRow: NSView {
    private let owner: BrowserWindow
    private let percent = NSTextField(labelWithString: "")

    init(window: BrowserWindow) {
        owner = window
        super.init(frame: NSRect(x: 0, y: 0, width: 220, height: 28))
        let title = NSTextField(labelWithString: "Zoom")
        title.font = .menuFont(ofSize: 0)
        title.frame = NSRect(x: 14, y: 5, width: 60, height: 17)
        percent.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        percent.alignment = .center
        percent.frame = NSRect(x: 112, y: 5, width: 54, height: 17)
        addSubview(title)
        addSubview(percent)
        addSubview(button("minus", #selector(smaller), x: 84, help: "Zoom Out"))
        addSubview(button("plus", #selector(larger), x: 170, help: "Zoom In"))
        refresh()
    }

    required init?(coder: NSCoder) { nil }

    private func button(_ symbol: String, _ action: Selector, x: CGFloat, help: String) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: help) ?? NSImage(), target: self, action: action)
        button.isBordered = false
        button.toolTip = help
        button.frame = NSRect(x: x, y: 2, width: 28, height: 24)
        return button
    }

    private func refresh() {
        let zoom = owner.shell.selected?.webView?.pageZoom ?? 1
        percent.stringValue = "\(Int((zoom * 100).rounded()))%"
    }

    @objc private func smaller() { owner.zoomOut(nil); refresh() }
    @objc private func larger() { owner.zoomIn(nil); refresh() }
}
