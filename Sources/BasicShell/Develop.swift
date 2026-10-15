import AppKit
import ObjectiveC
import UniformTypeIdentifiers
import WebKit

// The Develop and Debug menus in the menu bar, as in Safari: out of sight until
// turned on in Settings › General.
//
// Everything in them is WebKit's own, reached through its private API where
// WebKit has it and left out where it hasn't:
//
// - Develop: the Web Inspector, its console, a page's source, and picking an
//   element (`WKWebView._inspector`); the inspector of an extension's
//   background page (`WKWebExtensionContext._backgroundWebView`); the way the
//   tab introduces itself, its size and its look (Viewport.swift); a tab
//   without JavaScript, images or styles; emptying the caches; WebKit's
//   experimental features (`WKPreferences._experimentalFeatures`).
// - Debug: WebKit's internal debugging features (`_internalDebugFeatures`:
//   compositing borders, repaint counters, the resource usage overlay…), the
//   web process (crash it, copy its number), the page as a web archive.
//
// Safari's own Debug menu has more (iCloud, CloudKit, AutoFill metadata); that
// is Safari's, not WebKit's.
enum Develop {
    static let developKey = "develop.menu"
    static let debugKey = "develop.debugMenu"

    static var showsDevelop: Bool { UserDefaults.standard.bool(forKey: developKey) }
    static var showsDebug: Bool { UserDefaults.standard.bool(forKey: debugKey) }

    /// What a tab was set to, put on its web view when that is made.
    static func apply(to tab: Tab, _ web: WKWebView) {
        tab.zoomedFor = nil
        if tab.stylesOff { setStyles(false, web) }
        if tab.imagesOff { setImages(false, web) }
        if tab.crossOriginOff { setCrossOriginRestrictions(false, web) }
        if tab.localFilesOff { setLocalFileRestrictions(false, web) }
    }

    // MARK: - the inspector

    /// WebKit's `_WKInspector` of a page, which shows its own window.
    static func inspector(of web: WKWebView?) -> NSObject? {
        guard let web, web.responds(to: NSSelectorFromString("_inspector")) else { return nil }
        return web.value(forKey: "_inspector") as? NSObject
    }

    @discardableResult
    static func show(_ part: String, of web: WKWebView?) -> Bool {
        guard let inspector = inspector(of: web), inspector.responds(to: NSSelectorFromString(part)) else { return false }
        _ = inspector.perform(NSSelectorFromString(part))
        return true
    }

    /// The page's own source, in the inspector's Sources tab.
    static func showSource(of web: WKWebView?) -> Bool {
        guard let web, let inspector = inspector(of: web) else { return false }
        _ = inspector.perform(NSSelectorFromString("show"))
        let main = NSSelectorFromString("showMainResourceForFrame:")
        // `_mainFrame` is the frame's `_WKFrameHandle`, which is what it asks for.
        guard inspector.responds(to: main), web.responds(to: NSSelectorFromString("_mainFrame")),
              let frame = web.value(forKey: "_mainFrame") as? NSObject
        else { return true }
        _ = inspector.perform(main, with: frame)
        return true
    }

    // MARK: - a tab without images or styles

    private static var imageRules: WKContentRuleList?

    /// Images are not loaded for the tab, or are again.
    static func setImages(_ on: Bool, _ web: WKWebView) {
        let controller = web.configuration.userContentController
        if on {
            if let list = imageRules { controller.remove(list) }
            return
        }
        Task {
            if imageRules == nil {
                let rules = #"[{"trigger":{"url-filter":".*","resource-type":["image"]},"action":{"type":"block"}}]"#
                imageRules = try? await WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "BasicShellNoImages", encodedContentRuleList: rules)
            }
            if let list = imageRules { controller.add(list) }
        }
    }

    /// The page's own styles (and the user's) are used, or are not.
    static func setStyles(_ on: Bool, _ web: WKWebView) {
        let set = NSSelectorFromString("_setAuthorAndUserStylesEnabled:")
        let preferences = web.configuration.preferences
        guard preferences.responds(to: set), let method = class_getMethodImplementation(WKPreferences.self, set) else { return }
        typealias SetBool = @convention(c) (AnyObject, Selector, Bool) -> Void
        unsafeBitCast(method, to: SetBool.self)(preferences, set, on)
    }

    /// JavaScript, images and styles on again, and the page loaded afresh.
    static func restoreRendering(_ tab: Tab) {
        guard tab.javaScriptOff || tab.imagesOff || tab.stylesOff else { return }
        tab.javaScriptOff = false
        tab.imagesOff = false
        tab.stylesOff = false
        guard let web = tab.webView else { return }
        setImages(true, web)
        setStyles(true, web)
        web.reload()
    }

    // MARK: - a tab without the same-origin policy or the file: restrictions

    /// WebKit's own switches, set on the tab's page only: `WebSecurityEnabled`
    /// off lets the page's scripts read other sites; the other two let a page
    /// opened from a file read other files. For a page of the person's own.
    private static func write(_ settings: [String: Bool], _ web: WKWebView) {
        let preferences = web.configuration.preferences
        for (key, on) in settings {
            if let feature = Features.feature(key) { Features.write(on, feature, in: preferences) }
        }
    }

    static func setCrossOriginRestrictions(_ on: Bool, _ web: WKWebView) {
        write(["WebSecurityEnabled": on], web)
    }

    static func setLocalFileRestrictions(_ on: Bool, _ web: WKWebView) {
        write(["AllowFileAccessFromFileURLs": !on, "AllowUniversalAccessFromFileURLs": !on], web)
    }

    // MARK: - the web process

    static func processID(of web: WKWebView?) -> Int32? {
        guard let web, web.responds(to: NSSelectorFromString("_webProcessIdentifier")),
              let number = web.value(forKey: "_webProcessIdentifier") as? NSNumber, number.int32Value > 0
        else { return nil }
        return number.int32Value
    }

    static func crash(_ web: WKWebView?) -> Bool {
        guard let web, web.responds(to: NSSelectorFromString("_killWebContentProcess")) else { return false }
        _ = web.perform(NSSelectorFromString("_killWebContentProcess"))
        return true
    }
}

// MARK: - WebKit's features

/// WebKit's own switches: the experimental features Safari lists under
/// Develop, and the internal debugging features of its Debug menu. Each is
/// a `_WKFeature`, with a key, a name, a category and a default. What is
/// changed is kept (in the defaults) and put on every page opened after.
enum Features {
    enum Kind {
        case experimental, debugging

        var list: String { self == .experimental ? "_experimentalFeatures" : "_internalDebugFeatures" }
    }

    static let savedKey = "develop.features"

    /// Feature key to what the agent switched it to: put on pages like what
    /// was chosen, but never kept, and taken back when the agent goes (see
    /// Agent.swift).
    static var transient: [String: Bool] = [:]

    /// Feature key to what the person chose.
    static var saved: [String: Bool] {
        UserDefaults.standard.dictionary(forKey: savedKey) as? [String: Bool] ?? [:]
    }

    static let categories = [0: "Other", 1: "Animation", 2: "CSS", 3: "DOM", 4: "JavaScript", 5: "Media", 6: "Networking", 7: "Privacy", 8: "Security", 9: "HTML"]

    private static func features(_ list: String) -> [NSObject] {
        let selector = NSSelectorFromString(list)
        guard let meta = object_getClass(WKPreferences.self), class_respondsToSelector(meta, selector) else { return [] }
        return (WKPreferences.self as AnyObject).perform(selector)?.takeUnretainedValue() as? [NSObject] ?? []
    }

    static func all(_ kind: Kind) -> [NSObject] {
        features(kind.list).filter { ($0.value(forKey: "isHidden") as? Bool) != true }
    }

    private static let byKey: [String: NSObject] = {
        var found: [String: NSObject] = [:]
        for feature in features("_features") {
            if let key = feature.value(forKey: "key") as? String { found[key] = feature }
        }
        return found
    }()

    static func feature(_ key: String) -> NSObject? { byKey[key] }

    static func key(of feature: NSObject) -> String { feature.value(forKey: "key") as? String ?? "" }
    static func name(of feature: NSObject) -> String { feature.value(forKey: "name") as? String ?? key(of: feature) }
    static func category(of feature: NSObject) -> Int { (feature.value(forKey: "category") as? NSNumber)?.intValue ?? 0 }

    private typealias Reader = @convention(c) (AnyObject, Selector, AnyObject) -> Bool
    private typealias Writer = @convention(c) (AnyObject, Selector, Bool, AnyObject) -> Void

    static func read(_ feature: NSObject, in preferences: WKPreferences) -> Bool {
        let selector = NSSelectorFromString("_isEnabledForFeature:")
        guard preferences.responds(to: selector), let method = class_getMethodImplementation(WKPreferences.self, selector) else {
            return (feature.value(forKey: "defaultValue") as? Bool) ?? false
        }
        return unsafeBitCast(method, to: Reader.self)(preferences, selector, feature)
    }

    static func write(_ on: Bool, _ feature: NSObject, in preferences: WKPreferences) {
        let selector = NSSelectorFromString("_setEnabled:forFeature:")
        guard preferences.responds(to: selector), let method = class_getMethodImplementation(WKPreferences.self, selector) else { return }
        unsafeBitCast(method, to: Writer.self)(preferences, selector, on, feature)
    }

    /// What the person chose, on a page's preferences.
    static func applySaved(to preferences: WKPreferences) {
        for (key, on) in saved.merging(transient, uniquingKeysWith: { _, chosen in chosen }) {
            if let feature = byKey[key] { write(on, feature, in: preferences) }
        }
    }

    /// Whether it is on now, as a page in front has it, or as chosen.
    static func isOn(_ feature: NSObject) -> Bool {
        if let on = transient[key(of: feature)] ?? saved[key(of: feature)] { return on }
        if let preferences = Windows.front?.shell.selected?.webView?.configuration.preferences { return read(feature, in: preferences) }
        return (feature.value(forKey: "defaultValue") as? Bool) ?? false
    }

    /// Chosen: kept, and put on the pages open now.
    static func set(_ on: Bool, _ feature: NSObject) {
        var kept = saved
        kept[key(of: feature)] = on
        UserDefaults.standard.set(kept, forKey: savedKey)
        forEachPage { write(on, feature, in: $0) }
    }

    /// Every choice taken back: the pages go back to WebKit's own defaults
    /// (and BasicShell's few), and the next ones too.
    static func reset() {
        let chosen = saved.merging(transient, uniquingKeysWith: { first, _ in first })
        UserDefaults.standard.removeObject(forKey: savedKey)
        transient = [:]
        forEachPage { preferences in
            for key in chosen.keys {
                if let feature = byKey[key] { write((feature.value(forKey: "defaultValue") as? Bool) ?? false, feature, in: preferences) }
            }
        }
    }

    static func forEachPage(_ body: (WKPreferences) -> Void) {
        for window in Windows.all {
            for tab in window.shell.tabs {
                if let web = tab.webView { body(web.configuration.preferences) }
            }
        }
    }
}

// MARK: - the menus

extension Menus {
    static func develop() -> NSMenu {
        let menu = NSMenu(title: "Develop")
        let option: NSEvent.ModifierFlags = [.command, .option]
        menu.addItem(item("Show Web Inspector", #selector(BrowserWindow.showWebInspector(_:)), "i", option))
        menu.addItem(item("Show JavaScript Console", #selector(BrowserWindow.showJavaScriptConsole(_:)), "c", option))
        menu.addItem(item("Show Page Source", #selector(BrowserWindow.showPageSource(_:)), "u", option))
        menu.addItem(item("Show Page Resources", #selector(BrowserWindow.showPageResources(_:))))
        menu.addItem(item("Select Element", #selector(BrowserWindow.selectElement(_:))))
        menu.addItem(item("Start Timeline Recording", #selector(BrowserWindow.toggleTimelineRecording(_:)), "t", [.command, .option, .shift]))
        menu.addItem(.separator())
        menu.addItem(submenu("Extension Background Pages", Develop.Filler.backgrounds))
        menu.addItem(.separator())

        menu.addItem(submenu("User Agent", Develop.Filler.agents))

        let design = NSMenu(title: "Responsive Design")
        for (index, title) in ["iPhone (390 × 844)", "iPad (820 × 1180)"].enumerated() {
            let size = item(title, #selector(BrowserWindow.chooseDesign(_:)))
            size.tag = index
            design.addItem(size)
        }
        design.addItem(item("Custom Size…", #selector(BrowserWindow.chooseCustomSize(_:))))
        design.addItem(.separator())
        let back = item("Back to the Window's Size", #selector(BrowserWindow.chooseDesign(_:)))
        back.tag = 2
        design.addItem(back)
        let designItem = NSMenuItem(title: "Responsive Design", action: nil, keyEquivalent: "")
        designItem.submenu = design
        menu.addItem(designItem)

        let looks = NSMenu(title: "Color Scheme")
        for (index, title) in ["Automatic", "Light", "Dark"].enumerated() {
            let look = item(title, #selector(BrowserWindow.chooseLook(_:)))
            look.tag = index
            looks.addItem(look)
        }
        let lookItem = NSMenuItem(title: "Color Scheme", action: nil, keyEquivalent: "")
        lookItem.submenu = looks
        menu.addItem(lookItem)
        menu.addItem(.separator())

        menu.addItem(item("Disable JavaScript", #selector(BrowserWindow.toggleJavaScript(_:))))
        menu.addItem(item("Disable Images", #selector(BrowserWindow.toggleImages(_:))))
        menu.addItem(item("Disable Styles", #selector(BrowserWindow.toggleStyles(_:))))
        menu.addItem(item("Disable Cross-Origin Restrictions", #selector(BrowserWindow.toggleCrossOrigin(_:))))
        menu.addItem(item("Disable Local File Restrictions", #selector(BrowserWindow.toggleLocalFiles(_:))))
        menu.addItem(item("Empty Caches", #selector(BrowserWindow.emptyCaches(_:)), "e", option))
        menu.addItem(.separator())
        menu.addItem(submenu("Experimental Features", Develop.Filler.experimental))
        menu.addItem(.separator())
        menu.addItem(item("Debug Log", #selector(AppDelegate.showDebugLog(_:)), "d", option))
        return menu
    }

    static func debug() -> NSMenu {
        let menu = NSMenu(title: "Debug")
        let overlay = item("Resource Usage Overlay", #selector(Develop.Filler.toggleFeature(_:)))
        overlay.target = Develop.Filler.shared
        overlay.representedObject = "ResourceUsageOverlayVisible"
        overlay.identifier = NSUserInterfaceItemIdentifier("feature")
        menu.addItem(overlay)
        menu.addItem(submenu("Drawing and Compositing Flags", Develop.Filler.drawing))
        menu.addItem(submenu("WebKit Internal Features", Develop.Filler.debugging))
        menu.addItem(.separator())
        menu.addItem(item("Copy Web Process ID", #selector(BrowserWindow.copyProcessID(_:))))
        menu.addItem(item("Crash Web Process", #selector(BrowserWindow.crashWebProcess(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Save Page as Web Archive…", #selector(BrowserWindow.saveWebArchive(_:))))
        menu.addItem(.separator())
        let reset = item("Reset All WebKit Features to Defaults", #selector(Develop.Filler.resetFeatures(_:)))
        reset.target = Develop.Filler.shared
        menu.addItem(reset)
        return menu
    }

    private static func submenu(_ title: String, _ name: String) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: name)
        menu.delegate = Develop.Filler.shared
        entry.submenu = menu
        return entry
    }

    /// The two menus are shown or hidden as Settings says.
    static func showDeveloperMenus() {
        developItem?.isHidden = !Develop.showsDevelop
        debugItem?.isHidden = !Develop.showsDebug
    }
}

extension Develop {
    /// Fills the menus whose items come from what is running or from WebKit,
    /// when they are opened; and answers the choices made in them that belong
    /// to no window.
    final class Filler: NSObject, NSMenuDelegate, NSMenuItemValidation {
        static let shared = Filler()

        static let backgrounds = "Extension Background Pages"
        static let agents = "User Agent"
        static let experimental = "Experimental Features"
        static let debugging = "WebKit Internal Features"
        static let drawing = "Drawing and Compositing Flags"

        /// The flags that show what the engine draws, as Safari groups them.
        private static let drawingKeys = [
            "CompositingBordersVisible", "CompositingRepaintCountersVisible", "TiledScrollingIndicatorVisible",
            "SlowFrameIndicatorVisible", "ShowFrameProcessBordersEnabled", "AcceleratedDrawingEnabled",
            "AcceleratedFiltersEnabled", "UseGPUProcessForWebGLEnabled", "LayerBasedSVGEngineEnabled",
        ]

        func menuNeedsUpdate(_ menu: NSMenu) {
            switch menu.title {
            case Filler.backgrounds: fillBackgrounds(menu)
            case Filler.agents: fillAgents(menu)
            case Filler.experimental: fillFeatures(menu, .experimental)
            case Filler.debugging: fillFeatures(menu, .debugging)
            case Filler.drawing:
                menu.removeAllItems()
                for key in Filler.drawingKeys {
                    if let feature = Features.feature(key) { menu.addItem(toggle(feature)) }
                }
            default: break
            }
        }

        /// The Debug menu's own Resource Usage Overlay checks itself here.
        func validateMenuItem(_ item: NSMenuItem) -> Bool {
            if let key = item.representedObject as? String, let feature = Features.feature(key) {
                item.state = Features.isOn(feature) ? .on : .off
            }
            return true
        }

        private func toggle(_ feature: NSObject) -> NSMenuItem {
            let entry = NSMenuItem(title: Features.name(of: feature), action: #selector(toggleFeature(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = Features.key(of: feature)
            entry.state = Features.isOn(feature) ? .on : .off
            entry.toolTip = feature.value(forKey: "details") as? String
            return entry
        }

        private func fillFeatures(_ menu: NSMenu, _ kind: Features.Kind) {
            menu.removeAllItems()
            let features = Features.all(kind)
            if features.isEmpty {
                let none = NSMenuItem(title: "WebKit has none here", action: nil, keyEquivalent: "")
                none.isEnabled = false
                menu.addItem(none)
                return
            }
            let note = NSMenuItem(title: "Changes reach pages opened or reloaded after", action: nil, keyEquivalent: "")
            note.isEnabled = false
            menu.addItem(note)
            menu.addItem(.separator())
            let grouped = Dictionary(grouping: features, by: Features.category(of:))
            for category in grouped.keys.sorted() {
                let parent = NSMenuItem(title: Features.categories[category] ?? "Other", action: nil, keyEquivalent: "")
                let inner = NSMenu(title: parent.title)
                for feature in grouped[category]!.sorted(by: { Features.name(of: $0).localizedCaseInsensitiveCompare(Features.name(of: $1)) == .orderedAscending }) {
                    inner.addItem(toggle(feature))
                }
                parent.submenu = inner
                menu.addItem(parent)
            }
        }

        @objc func toggleFeature(_ item: NSMenuItem) {
            guard let key = item.representedObject as? String, let feature = Features.feature(key) else { return }
            Features.set(!Features.isOn(feature), feature)
        }

        @objc func resetFeatures(_ item: NSMenuItem) {
            Features.reset()
            Windows.front?.say("WebKit's features are back at their defaults")
        }

        // MARK: user agents

        private func fillAgents(_ menu: NSMenu) {
            menu.removeAllItems()
            for (index, entry) in Viewport.Agents.all.enumerated() {
                if index == Viewport.Agents.presets.count { menu.addItem(.separator()) }
                let agent = NSMenuItem(title: entry.title, action: #selector(BrowserWindow.chooseUserAgent(_:)), keyEquivalent: "")
                agent.tag = index
                agent.toolTip = entry.agent
                menu.addItem(agent)
            }
            menu.addItem(.separator())
            menu.addItem(Menus.item("Other…", #selector(BrowserWindow.chooseCustomUserAgent(_:))))
            if !Viewport.Agents.custom.isEmpty {
                let forget = NSMenuItem(title: "Forget Custom User Agents", action: #selector(forgetAgents(_:)), keyEquivalent: "")
                forget.target = self
                menu.addItem(forget)
            }
        }

        @objc func forgetAgents(_ item: NSMenuItem) { Viewport.Agents.forget() }

        // MARK: extension backgrounds

        private func fillBackgrounds(_ menu: NSMenu) {
            menu.removeAllItems()
            let contexts = Extensions.shared.contexts
            if contexts.isEmpty {
                let none = NSMenuItem(title: "No extensions", action: nil, keyEquivalent: "")
                none.isEnabled = false
                menu.addItem(none)
            }
            for context in contexts {
                let name = context.webExtension.displayName ?? "Extension"
                let running = Filler.background(of: context) != nil
                let entry = NSMenuItem(title: running ? name : name + " (not running)", action: #selector(inspectBackground(_:)), keyEquivalent: "")
                entry.target = self
                entry.representedObject = context.uniqueIdentifier
                entry.isEnabled = running
                menu.addItem(entry)
            }
        }

        /// The web view an extension's background runs in, if it is running
        /// (WebKit's private `_backgroundWebView`, as Extensions.swift uses).
        static func background(of context: WKWebExtensionContext) -> WKWebView? {
            let selector = NSSelectorFromString("_backgroundWebView")
            guard context.responds(to: selector) else { return nil }
            return context.perform(selector)?.takeUnretainedValue() as? WKWebView
        }

        @objc func inspectBackground(_ item: NSMenuItem) {
            guard let id = item.representedObject as? String,
                  let context = Extensions.shared.contexts.first(where: { $0.uniqueIdentifier == id }),
                  let web = Filler.background(of: context)
            else { return NSSound.beep() }
            // Its page was made by WebKit, without Inspect Element; and it is in
            // no window to dock the inspector to.
            Web.enableDeveloperExtras(in: web.configuration.preferences)
            Develop.show("detach", of: web)
            if !Develop.show("show", of: web) { NSSound.beep() }
        }
    }
}

// MARK: - what the menus do

extension BrowserWindow {
    private var page: WKWebView? { shell.selected?.webView }

    /// What the Responsive Design and Color Scheme menus' items stand for.
    fileprivate static let designs: [Viewport.Preset] = [.mobile, .tablet, .desktop]
    fileprivate static let looks: [NSAppearance.Name?] = [nil, .aqua, .darkAqua]

    @objc func showWebInspector(_ sender: Any?) {
        if !Develop.show("show", of: page) { NSSound.beep() }
    }

    @objc func showJavaScriptConsole(_ sender: Any?) {
        if !Develop.show("showConsole", of: page) { NSSound.beep() }
    }

    @objc func showPageSource(_ sender: Any?) {
        if !Develop.showSource(of: page) { NSSound.beep() }
    }

    @objc func selectElement(_ sender: Any?) {
        guard Develop.show("show", of: page) else { return NSSound.beep() }
        Develop.show("toggleElementSelection", of: page)
    }

    @objc func showPageResources(_ sender: Any?) {
        if !Develop.show("showResources", of: page) { NSSound.beep() }
    }

    /// Records what the page does (the inspector's Timelines), until asked to stop.
    @objc func toggleTimelineRecording(_ sender: Any?) {
        guard let web = page, Develop.show("show", of: web), Develop.show("togglePageProfiling", of: web) else { return NSSound.beep() }
    }

    /// Asks for a user agent to introduce this tab with.
    @objc func chooseCustomUserAgent(_ sender: Any?) {
        guard let tab = shell.selected, let web = tab.webView else { return }
        let alert = NSAlert()
        alert.messageText = "Custom User Agent"
        alert.informativeText = "How this tab introduces itself to sites. Sites are told when the page loads again."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 460, height: 24))
        field.placeholderString = "Mozilla/5.0 …"
        field.stringValue = tab.userAgent ?? (web.value(forKey: "_userAgent") as? String ?? "")
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.addButton(withTitle: "Use")
        alert.addButton(withTitle: "Cancel")
        Dialogs.show(alert, over: web) { [weak self] answer in
            let agent = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard answer == .alertFirstButtonReturn, !agent.isEmpty else { return }
            Viewport.Agents.remember(agent)
            Viewport.setAgent(agent, for: tab)
            tab.webView?.reload()
            self?.say("User agent changed")
        }
    }

    /// Asks for a width and a height for the page's view.
    @objc func chooseCustomSize(_ sender: Any?) {
        guard let tab = shell.selected, let web = tab.webView, let window else { return }
        let alert = NSAlert()
        alert.messageText = "Custom Size"
        alert.informativeText = "The page's view, in points, between 200 and 6000 each way. The window grows or shrinks to fit."
        let key = "develop.customSize"
        let last = (UserDefaults.standard.string(forKey: key) ?? "").split(separator: "x").compactMap { Int($0) }
        let width = NSTextField(string: String(last.count == 2 ? last[0] : Int(web.bounds.width)))
        let height = NSTextField(string: String(last.count == 2 ? last[1] : Int(web.bounds.height)))
        for field in [width, height] {
            field.alignment = .right
            field.widthAnchor.constraint(equalToConstant: 80).isActive = true
        }
        let times = NSTextField(labelWithString: "×")
        let row = NSStackView(views: [width, times, height])
        row.spacing = 8
        row.frame.size = NSSize(width: 190, height: 24)
        alert.accessoryView = row
        alert.window.initialFirstResponder = width
        alert.addButton(withTitle: "Resize")
        alert.addButton(withTitle: "Cancel")
        Dialogs.show(alert, over: web) { [weak self] answer in
            guard answer == .alertFirstButtonReturn else { return }
            guard let w = Int(width.stringValue.trimmingCharacters(in: .whitespaces)), let h = Int(height.stringValue.trimmingCharacters(in: .whitespaces)) else {
                return self?.say("A width and a height, in numbers") ?? ()
            }
            Task {
                do {
                    _ = try await Viewport.resize(web, in: window, to: CGSize(width: w, height: h))
                    UserDefaults.standard.set("\(w)x\(h)", forKey: key)
                } catch {
                    self?.say((error as? Viewport.Refused)?.message ?? error.localizedDescription)
                }
            }
        }
    }

    @objc func chooseUserAgent(_ item: NSMenuItem) {
        guard let tab = shell.selected, Viewport.Agents.all.indices.contains(item.tag) else { return }
        Viewport.setAgent(Viewport.Agents.all[item.tag].agent, for: tab)
        tab.webView?.reload()
    }

    /// A phone's or a tablet's size and way of introducing itself, or back.
    @objc func chooseDesign(_ item: NSMenuItem) {
        guard let tab = shell.selected, let web = tab.webView, let window else { return }
        let preset = BrowserWindow.designs[min(max(item.tag, 0), 2)]
        Task {
            do {
                if let size = preset.size { _ = try await Viewport.resize(web, in: window, to: size) } else { Viewport.restore(window) }
            } catch {
                return say((error as? Viewport.Refused)?.message ?? error.localizedDescription)
            }
            Viewport.setAgent(preset.agent, for: tab)
            web.reload()
        }
    }

    @objc func chooseLook(_ item: NSMenuItem) {
        guard let tab = shell.selected else { return }
        Viewport.setLook(BrowserWindow.looks[min(max(item.tag, 0), 2)], for: tab)
    }

    @objc func toggleJavaScript(_ sender: Any?) {
        guard let tab = shell.selected else { return }
        tab.javaScriptOff.toggle()
        tab.webView?.reload()
    }

    @objc func toggleImages(_ sender: Any?) {
        guard let tab = shell.selected, let web = tab.webView else { return }
        tab.imagesOff.toggle()
        Develop.setImages(!tab.imagesOff, web)
        web.reload()
    }

    @objc func toggleStyles(_ sender: Any?) {
        guard let tab = shell.selected, let web = tab.webView else { return }
        tab.stylesOff.toggle()
        Develop.setStyles(!tab.stylesOff, web)
        web.reload()
    }

    @objc func toggleCrossOrigin(_ sender: Any?) {
        guard let tab = shell.selected, let web = tab.webView else { return }
        tab.crossOriginOff.toggle()
        Develop.setCrossOriginRestrictions(!tab.crossOriginOff, web)
        web.reload()
    }

    @objc func toggleLocalFiles(_ sender: Any?) {
        guard let tab = shell.selected, let web = tab.webView else { return }
        tab.localFilesOff.toggle()
        Develop.setLocalFileRestrictions(!tab.localFilesOff, web)
        // A file is loaded with a right to read only the folder it sits in
        // (Tab.load); with the restrictions off, anything on this Mac.
        if let url = web.url, url.isFileURL {
            web.loadFileURL(url, allowingReadAccessTo: tab.localFilesOff ? URL(fileURLWithPath: "/") : url.deletingLastPathComponent())
        } else {
            web.reload()
        }
    }

    @objc func emptyCaches(_ sender: Any?) {
        guard let store = page?.configuration.websiteDataStore else { return }
        store.removeData(ofTypes: [WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache], modifiedSince: .distantPast) { [weak self] in
            MainActor.assumeIsolated { self?.say("Caches emptied") }
        }
    }

    @objc func copyProcessID(_ sender: Any?) {
        guard let id = Develop.processID(of: page) else { return NSSound.beep() }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(String(id), forType: .string)
        say("Web process \(id) copied")
    }

    @objc func crashWebProcess(_ sender: Any?) {
        if !Develop.crash(page) { NSSound.beep() }
    }

    @objc func saveWebArchive(_ sender: Any?) {
        guard let web = page, let window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.webArchive]
        panel.nameFieldStringValue = (shell.selected?.name ?? "Page") + ".webarchive"
        panel.beginSheetModal(for: window) { answer in
            guard answer == .OK, let url = panel.url else { return }
            web.createWebArchiveData { result in
                if case .success(let data) = result { try? data.write(to: url) }
            }
        }
    }

    /// The Develop and Debug menus' items, which the window answers for
    /// (`validateMenuItem` asks first); `nil` for any other.
    func validateDevelop(_ item: NSMenuItem) -> Bool? {
        let tab = shell.selected
        let loaded = tab?.webView != nil
        switch item.action {
        case #selector(showWebInspector(_:)), #selector(showJavaScriptConsole(_:)), #selector(showPageSource(_:)),
             #selector(selectElement(_:)), #selector(emptyCaches(_:)), #selector(copyProcessID(_:)),
             #selector(crashWebProcess(_:)), #selector(saveWebArchive(_:)), #selector(showPageResources(_:)),
             #selector(chooseCustomUserAgent(_:)), #selector(chooseCustomSize(_:)):
            return loaded
        case #selector(toggleTimelineRecording(_:)):
            let recording = (page?.value(forKey: "_inspector") as? NSObject)?.value(forKey: "isProfilingPage") as? Bool ?? false
            item.title = recording ? "Stop Timeline Recording" : "Start Timeline Recording"
            return loaded
        case #selector(chooseUserAgent(_:)):
            item.state = Viewport.Agents.all.indices.contains(item.tag) && tab?.userAgent == Viewport.Agents.all[item.tag].agent ? .on : .off
            return loaded
        case #selector(chooseDesign(_:)):
            if item.tag == 2 { return loaded && (window.map(Viewport.isResized) ?? false) }
            return loaded
        case #selector(chooseLook(_:)):
            let current: NSAppearance.Name? = tab?.look
            item.state = BrowserWindow.looks[min(max(item.tag, 0), 2)] == current ? .on : .off
            return loaded
        case #selector(toggleJavaScript(_:)):
            item.state = tab?.javaScriptOff == true ? .on : .off
            return loaded
        case #selector(toggleImages(_:)):
            item.state = tab?.imagesOff == true ? .on : .off
            return loaded
        case #selector(toggleStyles(_:)):
            item.state = tab?.stylesOff == true ? .on : .off
            return loaded
        case #selector(toggleCrossOrigin(_:)):
            item.state = tab?.crossOriginOff == true ? .on : .off
            return loaded
        case #selector(toggleLocalFiles(_:)):
            item.state = tab?.localFilesOff == true ? .on : .off
            return loaded
        default: return nil
        }
    }
}
