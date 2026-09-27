import AppKit
import Observation
import WebKit

// Browser extensions, on WebKit's own extension engine (WKWebExtension, the
// one Safari uses), and nothing else: no emulation of Chrome APIs WebKit
// lacks. An extension that needs one of those won't work here.
//
// An extension comes from the Chrome Web Store (its link or id; the package's
// signature is checked against the id, see Crx.swift) or from a folder, and is
// copied into Application Support/BasicShell/Extensions/<id>. Adding it shows
// what it asks for; what you accept is granted again at every launch. Its
// pages are served from chrome-extension://<id>/, the address they have in
// Chrome, which some servers check. Private tabs never see extensions.
//
// The only change made to an extension's files is a line at the top of each
// script with two fixes for Chrome extensions (see `fixes` below).
@Observable
final class Extensions: NSObject, WKWebExtensionControllerDelegate {
    static let shared = Extensions()
    static let scheme = "chrome-extension"

    struct Installed: Codable {
        var id: String
        /// Where it came from: "store", or "folder".
        var source: String
    }

    let controller: WKWebExtensionController
    private(set) var contexts: [WKWebExtensionContext] = []
    /// Bumped when an extension's button changes, so the top bar redraws.
    private(set) var actions = 0
    private var installed: [Installed] = Store.read("extensions.json", as: [Installed].self) ?? []

    private static var folder: URL { Store.folder.appendingPathComponent("Extensions", isDirectory: true) }
    private static func folder(for id: String) -> URL { folder.appendingPathComponent(id, isDirectory: true) }

    override init() {
        WKWebExtension.MatchPattern.registerCustomURLScheme(Extensions.scheme)
        // An extension's own pages (popup, background, options) say they are
        // Chrome: these are Chrome builds, and some decide which browser's
        // code to run from the user agent. Without a browser in it Bitwarden
        // stops before drawing anything; as Safari it would ask a Safari app
        // for the clipboard. Web pages still see Safari (Web.swift).
        let configuration = WKWebExtensionController.Configuration.default()
        let pages = configuration.webViewConfiguration ?? WKWebViewConfiguration()
        pages.applicationNameForUserAgent = "Chrome/\(Crx.chromeVersion) \(Web.userAgentName)"
        configuration.webViewConfiguration = pages
        controller = WKWebExtensionController(configuration: configuration)
        super.init()
        controller.delegate = self
    }

    /// At launch: every extension added before.
    func start() {
        Task {
            for item in installed {
                do { try await load(item.id) } catch {
                    Debug.log("extension", "\(item.id) didn't load: \(error.localizedDescription)")
                    NSLog("BasicShell: extension %@ didn't load: %@", item.id, error.localizedDescription)
                }
            }
        }
    }

    private func load(_ id: String) async throws {
        let folder = Extensions.folder(for: id)
        try Extensions.patch(folder)
        let found = try await WKWebExtension(resourceBaseURL: folder)
        let context = WKWebExtensionContext(for: found)
        context.uniqueIdentifier = id
        if let base = URL(string: "\(Extensions.scheme)://\(id)/") { context.baseURL = base }
        context.isInspectable = true
        for permission in found.requestedPermissions { context.setPermissionStatus(.grantedExplicitly, for: permission) }
        for pattern in found.allRequestedMatchPatterns { context.setPermissionStatus(.grantedExplicitly, for: pattern) }
        try controller.load(context)
        contexts.append(context)
        Debug.log("extension", "loaded \(found.displayName ?? id) \(found.version ?? "")")
        for error in found.errors { Debug.log("extension", "\(found.displayName ?? id) manifest: \(error.localizedDescription)") }
        NotificationCenter.default.addObserver(forName: WKWebExtensionContext.errorsDidUpdateNotification, object: context, queue: .main) { _ in
            MainActor.assumeIsolated {
                for error in context.errors.suffix(3) { Debug.log("extension", "\(found.displayName ?? id): \(error.localizedDescription)") }
            }
        }
        for window in Windows.all { context.didOpenWindow(window) }
    }

    // MARK: - adding and removing

    /// From a Chrome Web Store link or id.
    func add(fromStore text: String) async throws -> String {
        guard let id = Crx.id(in: text) else { throw Crx.Refused.notAnID }
        let zip = try Crx.verifiedZip(try await Crx.fetch(id), id: id)
        let staging = Extensions.folder.appendingPathComponent(".staging-\(id)", isDirectory: true)
        try Crx.unpack(zip, into: staging)
        return try await finish(staging, id: id, source: "store")
    }

    /// From an unpacked extension's folder, which is copied, not changed.
    func add(fromFolder source: URL) async throws -> String {
        guard FileManager.default.fileExists(atPath: source.appendingPathComponent("manifest.json").path) else {
            throw Crx.Refused.unpack
        }
        let id = Crx.letters(Array(UUID().uuidString.utf8.prefix(16)))
        let staging = Extensions.folder.appendingPathComponent(".staging-\(id)", isDirectory: true)
        try? FileManager.default.removeItem(at: staging)
        try FileManager.default.createDirectory(at: Extensions.folder, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source, to: staging)
        return try await finish(staging, id: id, source: "folder")
    }

    private func finish(_ staging: URL, id: String, source: String) async throws -> String {
        let files = FileManager.default
        defer { try? files.removeItem(at: staging) }
        let found = try await WKWebExtension(resourceBaseURL: staging)
        guard confirm(found) else { return "Not added" }
        if let old = contexts.first(where: { $0.uniqueIdentifier == id }) { unload(old) }
        let target = Extensions.folder(for: id)
        try? files.removeItem(at: target)
        try files.moveItem(at: staging, to: target)
        try await load(id)
        installed.removeAll { $0.id == id }
        installed.append(Installed(id: id, source: source))
        Store.write(installed, to: "extensions.json")
        return "Added \(found.displayName ?? "the extension")"
    }

    /// What it asks for, said plainly, before anything is granted.
    private func confirm(_ found: WKWebExtension) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Add “\(found.displayName ?? "this extension")”?"
        var lines: [String] = []
        let sites = found.allRequestedMatchPatterns.map(\.string).sorted()
        if sites.contains(where: { $0.contains("<all_urls>") || $0.hasPrefix("*://*/") || $0 == "*://*/*" }) {
            lines.append("It can read and change every website you visit.")
        } else if !sites.isEmpty {
            lines.append("It can read and change: " + sites.prefix(6).joined(separator: ", ") + (sites.count > 6 ? "…" : ""))
        }
        let permissions = found.requestedPermissions.map(\.rawValue).sorted()
        if !permissions.isEmpty { lines.append("It asks for: " + permissions.joined(separator: ", ")) }
        alert.informativeText = lines.joined(separator: "\n\n")
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    func remove(_ context: WKWebExtensionContext) {
        let id = context.uniqueIdentifier
        unload(context)
        controller.fetchDataRecord(ofTypes: WKWebExtensionController.allExtensionDataTypes, for: context) { [weak self] record in
            guard let record else { return }
            self?.controller.removeData(ofTypes: WKWebExtensionController.allExtensionDataTypes, from: [record]) {}
        }
        try? FileManager.default.removeItem(at: Extensions.folder(for: id))
        installed.removeAll { $0.id == id }
        Store.write(installed, to: "extensions.json")
    }

    private func unload(_ context: WKWebExtensionContext) {
        try? controller.unload(context)
        contexts.removeAll { $0 === context }
    }

    // MARK: - the changes made to an extension

    /// Put first in every script an extension ships: fixes for the places
    /// where WebKit differs from Chrome in ways a Chrome extension can't
    /// survive, each found with Bitwarden and the debug log:
    ///
    /// - Symbol.dispose and Symbol.asyncDispose, which this JavaScriptCore
    ///   lacks and code compiled from TypeScript's `using` checks for first.
    /// - chrome.scripting.ExecutionWorld, which WebKit doesn't define.
    /// - sender.origin on messages and ports, which Chrome gives and WebKit
    ///   doesn't; Bitwarden ignores a sender without one.
    /// - Late listeners. In the background worker, WebKit takes runtime
    ///   listeners only while the worker starts; Chrome takes them any time.
    ///   So one listener per event is given to WebKit at the start and the
    ///   extension's own are kept here; an event that comes before any
    ///   waits for the first.
    /// - A sleeping worker. WebKit stops an idle worker after half a minute
    ///   and wakes it for a message but not for a connection, which it
    ///   refuses ("No runtime.onConnect listeners found"). So a page's
    ///   connect first sends a wake-up message, then connects; what is
    ///   posted meanwhile waits.
    ///
    /// WebKit also hands out a new wrapper for `chrome.runtime` and its
    /// events on every read, so they are pinned to keep what is set on them.
    /// (After Search's ExtensionShims.swift, Office Commun, MIT.)
    /// Which version of the fixes a file carries; with the debug log on, a
    /// version that also reports to it (see Debug.swift).
    private static var marker: String { "/* BasicShell: extension fixes 8\(Debug.enabled ? " debug" : "") */" }
    /// One line, so a later version can take this one's place.
    private static var fixes: String { (marker + #"""
    (()=>{for(const n of["dispose","asyncDispose"]){if(typeof Symbol[n]!=="symbol")Object.defineProperty(Symbol,n,{value:Symbol.for("Symbol."+n)})}
    const pin=(o,k)=>{let v;try{v=o[k]}catch(e){return}if(v==null)return v;try{Object.defineProperty(o,k,{value:v,configurable:true,writable:true,enumerable:true})}catch(e){}return v};
    const mend=(sender)=>{if(!sender||typeof sender!=="object"||sender.origin||typeof sender.url!=="string")return sender;const m=/^([a-z][a-z0-9+.-]*:\/\/[^/?#]*)/i.exec(sender.url);if(!m)return sender;try{Object.defineProperty(sender,"origin",{value:m[1],configurable:true,enumerable:true})}catch(e){try{sender={...sender,origin:m[1]}}catch(e2){}}return sender};
    const mendArgs=(args,message)=>{if(message){args[1]=mend(args[1])}else{const port=args[0];if(port&&port.sender&&!port.sender.origin){const fixed=mend(port.sender);if(fixed!==port.sender)try{Object.defineProperty(port,"sender",{value:fixed,configurable:true})}catch(e){}}}return args};
    const DEBUG=__DEBUG__&&(!self.document||location.protocol==="chrome-extension:");const L=DEBUG?(...a)=>{try{fetch("http://127.0.0.1:__PORT__/log?c=ext&m="+encodeURIComponent((self.document?location.pathname:"worker")+" "+a.map(x=>{try{if(x&&typeof x==="object"&&("message" in x||x instanceof Error))return (x.name?x.name+": ":"")+x.message+(x.stack?" @"+String(x.stack).split("\n")[0]:"");return typeof x==="object"?JSON.stringify(x):String(x)}catch(e){return String(x)}}).join(" ").slice(0,500))).catch(()=>{})}catch(e){}}:()=>{};
    if(DEBUG&&!self.__basicShellDebug){Object.defineProperty(self,"__basicShellDebug",{value:true});self.addEventListener("error",e=>L("error",e.message,(e.filename||"")+":"+e.lineno));self.addEventListener("unhandledrejection",e=>L("unhandled rejection",e.reason));for(const lv of["error","warn"]){const o=console[lv];console[lv]=(...a)=>{L("console."+lv,...a);return o.apply(console,a)}}L("started")}
    for(const ns of["chrome","browser"]){const space=pin(self,ns);const scripting=space&&pin(space,"scripting");if(scripting&&!scripting.ExecutionWorld)try{Object.defineProperty(scripting,"ExecutionWorld",{value:Object.freeze({ISOLATED:"ISOLATED",MAIN:"MAIN"}),configurable:true})}catch(e){}}
    const worker=typeof ServiceWorkerGlobalScope!=="undefined"&&self instanceof ServiceWorkerGlobalScope;
    if(!worker){for(const ns of["chrome","browser"]){const space=pin(self,ns);const runtime=space&&pin(space,"runtime");if(!runtime)continue;for(const name of["onMessage","onConnect"]){const event=pin(runtime,name);if(!event||typeof event.addListener!=="function")continue;const add=event.addListener.bind(event),remove=event.removeListener.bind(event),wrapped=new Map(),message=name==="onMessage";try{Object.defineProperty(event,"addListener",{value:l=>{const w=(...args)=>l(...mendArgs(args,message));wrapped.set(l,w);return add(w)},configurable:true,writable:true});Object.defineProperty(event,"removeListener",{value:l=>{const w=wrapped.get(l);wrapped.delete(l);return remove(w||l)},configurable:true,writable:true});Object.defineProperty(event,"hasListener",{value:l=>wrapped.has(l),configurable:true,writable:true})}catch(e){}}}}
    if(!worker)for(const ns of["chrome","browser"]){const space=pin(self,ns);const runtime=space&&pin(space,"runtime");if(!runtime||typeof runtime.connect!=="function"||typeof runtime.sendMessage!=="function")continue;const real=runtime.connect.bind(runtime),send=runtime.sendMessage.bind(runtime);const ev=()=>{const ls=new Set();return{addListener:f=>{ls.add(f)},removeListener:f=>{ls.delete(f)},hasListener:f=>ls.has(f),hasListeners:()=>ls.size>0,ls}};
    try{Object.defineProperty(runtime,"connect",{configurable:true,writable:true,value:(...args)=>{const info=args.find(a=>a&&typeof a==="object")||{};const port={name:info.name||"",sender:undefined,onMessage:ev(),onDisconnect:ev()};let target=null,closed=false;const queue=[];
    port.postMessage=m=>{if(closed)throw new Error("Attempting to use a disconnected port object");if(target)target.postMessage(m);else queue.push(m)};
    port.disconnect=()=>{if(closed)return;closed=true;if(target)try{target.disconnect()}catch(e){}};
    const attach=()=>{if(closed)return;let p;try{p=real(...args)}catch(e){closed=true;for(const f of[...port.onDisconnect.ls])try{f(port)}catch(e2){}return}p.onMessage.addListener(m=>{for(const f of[...port.onMessage.ls])try{f(m,port)}catch(e){console.error(e)}});p.onDisconnect.addListener(()=>{if(closed)return;closed=true;for(const f of[...port.onDisconnect.ls])try{f(port)}catch(e){console.error(e)}});target=p;for(const m of queue.splice(0))try{p.postMessage(m)}catch(e){}};
    let wakeup;try{wakeup=Promise.resolve(send({__basicShellWake:true})).catch(()=>{})}catch(e){wakeup=Promise.resolve()}Promise.race([wakeup,new Promise(r=>setTimeout(r,2000))]).then(attach);return port}})}catch(e){}}
    if(!worker&&DEBUG){try{const rt=pin(pin(self,"chrome"),"runtime");const cn=rt.connect.bind(rt);Object.defineProperty(rt,"connect",{value:(...a)=>{const p=cn(...a);L("connect",a);try{p.onDisconnect.addListener(()=>L("disconnected",a,chrome.runtime.lastError&&chrome.runtime.lastError.message))}catch(e){}return p},configurable:true,writable:true})}catch(e){L("wrapfail",e.message)}}
    if(!worker||self.__basicShellLate)return;Object.defineProperty(self,"__basicShellLate",{value:true});
    for(const ns of["chrome","browser"]){const space=pin(self,ns);const runtime=space&&pin(space,"runtime");if(!runtime)continue;
    for(const name of["onMessage","onConnect","onMessageExternal","onConnectExternal"]){const event=pin(runtime,name);if(!event||typeof event.addListener!=="function")continue;
    const listeners=new Set(),waiting=[],message=name.startsWith("onMessage");
    const deliver=(l,args)=>{try{return l(...mendArgs(args,message))}catch(e){console.error(e)}};
    const dispatch=(...args)=>{if(message&&args[0]&&args[0].__basicShellWake===true){try{args[2](true)}catch(e){}return false}if(!message)L(ns+".runtime."+name,"port",args[0]&&args[0].name,"to",listeners.size,"listeners");if(!listeners.size){if(message){waiting.push(args);setTimeout(()=>{const i=waiting.indexOf(args);if(i>=0){waiting.splice(i,1);try{args[2](undefined)}catch(e){}}},15000);return true}waiting.push(args);return}
    if(!message){for(const l of[...listeners])deliver(l,args);return}
    let keep=false;for(const l of[...listeners]){const r=deliver(l,args);if(r===true)keep=true;else if(r&&typeof r.then==="function"){keep=true;r.then(v=>{try{args[2](v)}catch(e){}},()=>{try{args[2](undefined)}catch(e){}})}}return keep};
    event.addListener(dispatch);
    const set=(k,v)=>{try{Object.defineProperty(event,k,{value:v,configurable:true,writable:true})}catch(e){}};
    set("addListener",l=>{listeners.add(l);if(listeners.size===1&&waiting.length)for(const args of waiting.splice(0)){const r=deliver(l,args);if(message&&r&&typeof r.then==="function")r.then(v=>{try{args[2](v)}catch(e){}},()=>{})}});
    set("removeListener",l=>{listeners.delete(l)});set("hasListener",l=>listeners.has(l));set("hasListeners",()=>listeners.size>0)}}})();
    """#).replacingOccurrences(of: "\n", with: "")
        .replacingOccurrences(of: "__DEBUG__", with: Debug.enabled ? "true" : "false")
        .replacingOccurrences(of: "__PORT__", with: String(Debug.port)) + "\n" }

    /// Puts the fixes first in every script the extension ships, replacing
    /// an older version of them.
    static func patch(_ folder: URL) throws {
        let files = FileManager.default
        guard let walker = files.enumerator(at: folder, includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey]) else { return }
        for case let file as URL in walker where ["js", "mjs"].contains(file.pathExtension.lowercased()) {
            let values = try? file.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
            guard values?.isRegularFile == true, values?.isSymbolicLink != true,
                  var text = try? String(contentsOf: file, encoding: .utf8),
                  !text.hasPrefix(marker)
            else { continue }
            // An older version: everything up to the end of its first line.
            if text.hasPrefix("/* BasicShell:"), let end = text.firstIndex(of: "\n") {
                text = String(text[text.index(after: end)...])
            }
            text = fixes + text
            try text.write(to: file, atomically: true, encoding: .utf8)
        }
    }

    // MARK: - telling WebKit what the browser is doing

    func opened(_ tab: Tab) { if !tab.isPrivate { controller.didOpenTab(tab) } }
    func closed(_ tab: Tab, windowClosing: Bool = false) { if !tab.isPrivate { controller.didCloseTab(tab, windowIsClosing: windowClosing) } }
    func activated(_ tab: Tab?, previous: Tab?) {
        guard let tab, !tab.isPrivate else { return }
        controller.didActivateTab(tab, previousActiveTab: previous?.isPrivate == false ? previous : nil)
    }
    func changed(_ tab: Tab, _ properties: WKWebExtension.TabChangedProperties) {
        if !tab.isPrivate { controller.didChangeTabProperties(properties, for: tab) }
    }

    // MARK: - WKWebExtensionControllerDelegate

    func webExtensionController(_ controller: WKWebExtensionController, openWindowsFor extensionContext: WKWebExtensionContext) -> [any WKWebExtensionWindow] {
        let ordered = NSApp.orderedWindows.compactMap { $0.windowController as? BrowserWindow }
        return ordered.isEmpty ? Windows.all : ordered
    }

    func webExtensionController(_ controller: WKWebExtensionController, focusedWindowFor extensionContext: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        Windows.front
    }

    func webExtensionController(_ controller: WKWebExtensionController, openNewTabUsing configuration: WKWebExtension.TabConfiguration, for extensionContext: WKWebExtensionContext, completionHandler: @escaping ((any WKWebExtensionTab)?, (any Error)?) -> Void) {
        let window = (configuration.window as? BrowserWindow) ?? Windows.front ?? Windows.open(empty: true)
        let tab = Tab(privately: false)
        tab.pinned = configuration.shouldBePinned
        window.insert(tab, after: configuration.parentTab as? Tab, select: configuration.shouldBeActive)
        if let url = configuration.url { tab.load(url) }
        completionHandler(tab, nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController, openNewWindowUsing configuration: WKWebExtension.WindowConfiguration, for extensionContext: WKWebExtensionContext, completionHandler: @escaping ((any WKWebExtensionWindow)?, (any Error)?) -> Void) {
        let window = Windows.open(empty: true)
        for url in configuration.tabURLs { window.open(url, select: true) }
        if configuration.frame != .zero { window.window?.setFrame(configuration.frame, display: true) }
        completionHandler(window, nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController, openOptionsPageFor extensionContext: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        if let url = extensionContext.optionsPageURL {
            let window = Windows.front ?? Windows.open(empty: true)
            window.open(url, select: true)
        }
        completionHandler(nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController, promptForPermissions permissions: Set<WKWebExtension.Permission>, in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext, completionHandler: @escaping (Set<WKWebExtension.Permission>, Date?) -> Void) {
        let name = extensionContext.webExtension.displayName ?? "An extension"
        Debug.log("extension", "\(name) asks for permissions: \(permissions.map(\.rawValue).sorted())")
        let granted = ask("\(name) asks for more access", permissions.map(\.rawValue).sorted().joined(separator: ", "))
        completionHandler(granted ? permissions : [], nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController, promptForPermissionToAccess urls: Set<URL>, in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext, completionHandler: @escaping (Set<URL>, Date?) -> Void) {
        let name = extensionContext.webExtension.displayName ?? "An extension"
        let hosts = Set(urls.compactMap { $0.host() }).sorted().joined(separator: ", ")
        completionHandler(ask("Let \(name) read and change \(hosts)?", "") ? urls : [], nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController, promptForPermissionMatchPatterns matchPatterns: Set<WKWebExtension.MatchPattern>, in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext, completionHandler: @escaping (Set<WKWebExtension.MatchPattern>, Date?) -> Void) {
        let name = extensionContext.webExtension.displayName ?? "An extension"
        let sites = matchPatterns.map(\.string).sorted().joined(separator: ", ")
        completionHandler(ask("Let \(name) read and change these sites?", sites) ? matchPatterns : [], nil)
    }

    private func ask(_ title: String, _ detail: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Don't Allow")
        return alert.runModal() == .alertFirstButtonReturn
    }

    func webExtensionController(_ controller: WKWebExtensionController, didUpdate action: WKWebExtension.Action, forExtensionContext context: WKWebExtensionContext) {
        actions += 1
    }

    func webExtensionController(_ controller: WKWebExtensionController, presentActionPopup action: WKWebExtension.Action, for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        let name = context.webExtension.displayName ?? "extension"
        guard let popover = action.popupPopover, let window = Windows.front else {
            Debug.log("extension", "\(name): popup asked for but \(action.popupPopover == nil ? "WebKit gave no popover" : "no window")")
            return completionHandler(nil)
        }
        Debug.log("extension", "\(name): showing popup (already shown: \(popover.isShown))")
        window.present(popover, for: context)
        completionHandler(nil)
    }
}

// MARK: - tabs and windows, as extensions see them

extension Tab: WKWebExtensionTab {
    private var browser: BrowserWindow? { host as? BrowserWindow }

    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? { browser }
    func indexInWindow(for context: WKWebExtensionContext) -> Int {
        browser?.shell.tabs.filter { !$0.isPrivate }.firstIndex(of: self) ?? NSNotFound
    }
    func parentTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? { opener }
    func webView(for context: WKWebExtensionContext) -> WKWebView? { webView }
    func title(for context: WKWebExtensionContext) -> String? { title }
    func url(for context: WKWebExtensionContext) -> URL? { url }
    func isPinned(for context: WKWebExtensionContext) -> Bool { pinned }
    func isSelected(for context: WKWebExtensionContext) -> Bool { browser?.shell.selected === self }
    func isLoadingComplete(for context: WKWebExtensionContext) -> Bool { !isLoading }
    func isPlayingAudio(for context: WKWebExtensionContext) -> Bool { false }
    func zoomFactor(for context: WKWebExtensionContext) -> Double { Double(webView?.pageZoom ?? 1) }

    func activate(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        browser?.select(self)
        browser?.window?.makeKeyAndOrderFront(nil)
        completionHandler(nil)
    }

    func loadURL(_ url: URL, for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        load(url)
        completionHandler(nil)
    }

    func reload(fromOrigin: Bool, for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        if fromOrigin { webView?.reloadFromOrigin() } else { webView?.reload() }
        completionHandler(nil)
    }

    func goBack(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        webView?.goBack()
        completionHandler(nil)
    }

    func goForward(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        webView?.goForward()
        completionHandler(nil)
    }

    func close(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        browser?.close(self)
        completionHandler(nil)
    }

    func setPinned(_ pinned: Bool, for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        browser?.setPinned(self, pinned)
        completionHandler(nil)
    }
}

extension BrowserWindow: WKWebExtensionWindow {
    func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] { shell.tabs.filter { !$0.isPrivate } }
    func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? {
        shell.selected?.isPrivate == false ? shell.selected : nil
    }
    func windowType(for context: WKWebExtensionContext) -> WKWebExtension.WindowType { .normal }
    func windowState(for context: WKWebExtensionContext) -> WKWebExtension.WindowState {
        guard let window else { return .normal }
        if window.isMiniaturized { return .minimized }
        if window.styleMask.contains(.fullScreen) { return .fullscreen }
        return window.isZoomed ? .maximized : .normal
    }
    func isPrivate(for context: WKWebExtensionContext) -> Bool { false }
    func frame(for context: WKWebExtensionContext) -> CGRect { window?.frame ?? .zero }
    func screenFrame(for context: WKWebExtensionContext) -> CGRect { window?.screen?.frame ?? .zero }

    func focus(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        window?.makeKeyAndOrderFront(nil)
        completionHandler(nil)
    }

    func close(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        window?.performClose(nil)
        completionHandler(nil)
    }
}
