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
            if editable, link == nil, ["http", "https"].contains(url?.scheme ?? "") {
                menu.addItem(.separator())
                menu.addItem(action("Add as Search Engine…") { [weak self] in self?.addSearchEngine() })
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

    /// The field that was right-clicked is the one with the keyboard: its
    /// form's address, with this field's place marked %s, becomes a keyword.
    private static let searchForm = """
    (() => {
      const field = document.activeElement;
      if (!field || !['INPUT', 'TEXTAREA'].includes(field.tagName) || field.type === 'password' || !field.form || !field.name) return null;
      const form = field.form;
      if ((form.getAttribute('method') || 'get').toLowerCase() !== 'get') return null;
      const address = new URL(form.getAttribute('action') || location.href, location.href);
      address.search = '';
      for (const f of form.elements) {
        if (f === field || !f.name || f.disabled || ['submit', 'button', 'file', 'password', 'image', 'reset'].includes(f.type)) continue;
        if (['checkbox', 'radio'].includes(f.type) && !f.checked) continue;
        address.searchParams.append(f.name, f.value);
      }
      address.searchParams.append(field.name, '__WORDS__');
      return { url: address.href.replace('__WORDS__', '%s'), host: location.hostname, title: document.title,
               theme: (document.querySelector('meta[name=theme-color]') || {}).content || '' };
    })()
    """

    private func addSearchEngine() {
        webView?.evaluateJavaScript(Tab.searchForm) { [weak self] result, _ in
            guard let self, let window = self.host as? BrowserWindow else { return }
            guard let found = result as? [String: Any], let template = found["url"] as? String, template.contains("%s") else {
                window.say("That isn't a search box this can use.")
                return
            }
            let host = (found["host"] as? String) ?? ""
            let bare = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
            let site = bare.split(separator: ".").dropLast().last.map(String.init) ?? bare
            var keyword = Keyword(key: String(site.prefix(2)).lowercased(), name: site.prefix(1).uppercased() + site.dropFirst(), template: template)
            keyword.colour = (NSColor.css(found["theme"] as? String ?? "") ?? self.icon.flatMap { NSColor.dominant(in: $0) })?.hex

            let name = NSTextField(string: keyword.name)
            let key = NSTextField(string: keyword.key)
            name.frame = NSRect(x: 60, y: 28, width: 200, height: 22)
            key.frame = NSRect(x: 60, y: 0, width: 80, height: 22)
            let labels = [("Name", 28), ("Key", 0)].map { text, y -> NSTextField in
                let label = NSTextField(labelWithString: text)
                label.frame = NSRect(x: 0, y: y + 2, width: 56, height: 17)
                return label
            }
            let form = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 52))
            ([name, key] + labels).forEach(form.addSubview)

            let alert = NSAlert()
            alert.messageText = "Add \(bare) as a Search Engine"
            alert.informativeText = "Type the key and a space in the address field, then the words to search for."
            alert.accessoryView = form
            alert.addButton(withTitle: "Add")
            alert.addButton(withTitle: "Cancel")
            alert.window.initialFirstResponder = key
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            keyword.name = name.stringValue.trimmingCharacters(in: .whitespaces)
            keyword.key = key.stringValue.trimmingCharacters(in: .whitespaces)
            guard !keyword.name.isEmpty, !keyword.key.isEmpty, !keyword.key.contains(" ") else {
                window.say("It needs a name and a key without spaces.")
                return
            }
            Keywords.add(keyword)
            window.say("“\(keyword.key)” now searches \(keyword.name).")
        }
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
        let zoom = owner.shell.selected?.webView.map { owner.userZoom(of: $0) } ?? 1
        percent.stringValue = "\(Int((zoom * 100).rounded()))%"
    }

    @objc private func smaller() { owner.zoomOut(nil); refresh() }
    @objc private func larger() { owner.zoomIn(nil); refresh() }
}
