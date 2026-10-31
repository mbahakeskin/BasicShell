import AppKit
import SwiftUI
import WebKit

/// BasicShell › Settings (⌘,): one window, a few plain choices.
enum SettingsWindow {
    private static var window: NSWindow?

    static func show(_ tab: String? = nil) {
        if let tab { UserDefaults.standard.set(tab, forKey: "settings.tab") }
        if window == nil {
            let made = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 680, height: 520),
                styleMask: [.titled, .closable, .fullSizeContentView],
                backing: .buffered, defer: false
            )
            made.title = "Settings"
            made.titlebarAppearsTransparent = true
            made.isReleasedWhenClosed = false
            made.contentView = NSHostingView(rootView: SettingsView())
            made.center()
            window = made
        }
        window?.makeKeyAndOrderFront(nil)
    }
}

struct SettingsView: View {
    @AppStorage("settings.tab") private var tab = "general"

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }.tag("general")
            ImportSettings().tabItem { Label("Import", systemImage: "square.and.arrow.down") }.tag("import")
            TabSettings().tabItem { Label("Tabs", systemImage: "square.on.square") }.tag("tabs")
            PrivacySettings().tabItem { Label("Privacy", systemImage: "hand.raised") }.tag("privacy")
            ExtensionSettings().tabItem { Label("Extensions", systemImage: "puzzlepiece.extension") }.tag("extensions")
            #if AGENT
            AgentSettings().tabItem { Label("Agents", systemImage: "cursorarrow.rays") }.tag("agent")
            #endif
        }
        .padding(.top, 28)
        .frame(width: 680, height: 520)
    }
}

private struct GeneralSettings: View {
    @AppStorage("engine") private var engine = Engine.google.rawValue
    @AppStorage("engine.region") private var region = true
    @AppStorage("debug.enabled") private var debug = false
    @AppStorage("fullscreen.notch") private var notch = true
    @AppStorage("layout.sidebarOnly") private var sidebarOnly = false
    @AppStorage("translate.engine") private var translateEngine = TranslateEngine.online.rawValue
    @AppStorage(Develop.developKey) private var develop = false
    @AppStorage(Develop.debugKey) private var debugMenu = false

    var body: some View {
        Form {
            Picker("Layout", selection: $sidebarOnly) {
                Text("Top bar and sidebar").tag(false)
                Text("Sidebar only").tag(true)
            }
            .onChange(of: sidebarOnly) { _, only in Windows.all.forEach { $0.setSidebarOnly(only) } }
            Picker("Translate pages with", selection: $translateEngine) {
                Text("Google (fast, online)").tag(TranslateEngine.online.rawValue)
                Text("This Mac (slow, nothing sent)").tag(TranslateEngine.device.rawValue)
            }
            Picker("Search with", selection: $engine) {
                ForEach(Engine.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
            }
            Toggle(isOn: $region) {
                Text("Search Google in this Mac's language and region")
                Text("Adds hl=\(Engine.language)\(Engine.region.map { ", gl=\($0)" } ?? "") to Google searches, so results don't follow a VPN's country.")
            }
            .disabled(engine != Engine.google.rawValue)
            Section {
                Toggle(isOn: $notch) {
                    Text("Full screen uses the space beside the notch")
                    Text("The page goes up to the top of the screen, with a clock beside the notch. Off, full screen gets a desktop of its own, as elsewhere in macOS, and the strip beside the notch stays black.")
                }
            }
            Section {
                Toggle(isOn: $develop) {
                    Text("Show the Develop menu")
                    Text("In the menu bar, as in Safari: the Web Inspector and its console, a page's source, the extensions' background pages, the way a tab introduces itself, its size and look, tabs without JavaScript, images or styles, and WebKit's experimental features.")
                }
                .onChange(of: develop) { _, _ in Menus.showDeveloperMenus() }
                Toggle(isOn: $debugMenu) {
                    Text("Show the Debug menu")
                    Text("WebKit's internal debugging features (compositing borders, repaint counters, the resource usage overlay), and the web process: its number, and crashing it. What is switched there can break pages; the last item puts them all back.")
                }
                .onChange(of: debugMenu) { _, _ in Menus.showDeveloperMenus() }
            }
            Section {
                Toggle(isOn: $debug) {
                    Text("Debug logging")
                    Text("Keeps a log of location requests, extension popups and what pages and extensions report. Takes full effect after reopening BasicShell.")
                }
                Button("Open Debug Log") { DebugWindow.show() }
            }
            #if AGENT
            UpdateSection()
            #endif
            Section {
                Button("Make BasicShell the Default Browser") {
                    let app = Bundle.main.bundleURL
                    NSWorkspace.shared.setDefaultApplication(at: app, toOpenURLsWithScheme: "http") { _ in
                        NSWorkspace.shared.setDefaultApplication(at: app, toOpenURLsWithScheme: "https") { _ in }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct TabSettings: View {
    @AppStorage("sleep.unloadHours") private var unload = 6.0
    @AppStorage("archive.hours") private var archive = 12.0
    @AppStorage("sleep.freeze") private var freeze = true
    @AppStorage("sleep.freezeAfter") private var freezeAfter = 0.0

    private let freezeChoices: [(String, Double)] = [("Right away", 0), ("30 seconds", 30), ("1 minute", 60), ("5 minutes", 300), ("15 minutes", 900), ("1 hour", 3600)]
    private let unloadChoices: [(String, Double)] = [("1 hour", 1), ("2 hours", 2), ("6 hours", 6), ("12 hours", 12), ("1 day", 24), ("Never", 0)]
    private let archiveChoices: [(String, Double)] = [("6 hours", 6), ("12 hours", 12), ("1 day", 24), ("3 days", 72), ("1 week", 168), ("Never", 0)]

    var body: some View {
        Form {
            Section {
                Picker("Put tabs to sleep after", selection: $freezeAfter) {
                    ForEach(freezeChoices, id: \.1) { Text($0.0).tag($0.1) }
                }
                .disabled(!freeze)
                Picker("Unload tabs unseen for", selection: $unload) {
                    ForEach(unloadChoices, id: \.1) { Text($0.0).tag($0.1) }
                }
                Picker("Archive tabs unseen for", selection: $archive) {
                    ForEach(archiveChoices, id: \.1) { Text($0.0).tag($0.1) }
                }
            } footer: {
                Text("A tab you leave is put to sleep (frozen) after the first wait: right away is the lightest on the Mac, a longer wait keeps a page you flip back to running as you left it. Unloaded tabs give their memory back and reload where they were; archived tabs leave the sidebar for Tab › Show Archived Tabs. Pinned tabs are never archived, and nothing holding unsent typing is unloaded.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle(isOn: $freeze) {
                    Text("Freeze tabs off screen")
                    Text("Stops them completely instead of slowing them down, with a private WebKit feature.")
                }
            }
            Section("Sites kept awake") {
                SiteList(sites: Awake.shared.sites.sorted(), empty: "None. The sun in the top bar keeps a site's tabs awake.") {
                    Awake.shared.remove(site: $0)
                }
            }
            Section("Sites muted") {
                SiteList(sites: MutedSites.shared.sites.sorted(), empty: "None. Right-click a tab, or use the Tab menu, to mute a site's sound for good.") {
                    MutedSites.shared.remove(site: $0)
                }
            }
            Section("Sites with developer settings") {
                SiteList(sites: SiteDevelop.shared.sites.keys.sorted(), empty: "None. Develop › Keep These Settings for This Site keeps a site's user agent, colour scheme and switches.", detail: {
                    SiteDevelop.shared.sites[$0]?.summary
                }) {
                    SiteDevelop.shared.save(nil, for: $0)
                }
            }
            Section("Sites with their own zoom") {
                SiteList(sites: SiteZoom.shared.levels.keys.sorted(), empty: "None. ⌘+ and ⌘− set a site's zoom, and so does the lock in its address.", detail: {
                    SiteZoom.shared.level(for: $0).map { "\(Int(($0 * 100).rounded()))%" }
                }) {
                    SiteZoom.shared.set(nil, for: $0)
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct PrivacySettings: View {
    @AppStorage(Extensions.blockerWanted) private var blocker = false
    @AppStorage(DiskUse.limitKey) private var cacheLimit = 250
    // `@State` is a macro in the macOS 27 SDK whose plugin ships only with
    // Xcode, so the State it would expand to is stored by hand.
    private var _cacheSize = State<Int64?>(initialValue: nil)
    private var cacheSize: Int64? {
        get { _cacheSize.wrappedValue }
        nonmutating set { _cacheSize.wrappedValue = newValue }
    }

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $blocker) {
                    Text("Block ads with uBlock Origin Lite")
                    Text("The Safari extension that comes with its app from the App Store; BasicShell adds it whenever it is on this Mac.")
                }
                .onChange(of: blocker) { _, on in
                    guard on else { return }
                    Task { await Extensions.shared.addBlocker(asking: false) }
                }
                if blocker, !Extensions.shared.hasBlocker, Extensions.blockerOnThisMac() == nil {
                    Button("Get It from the App Store") { NSWorkspace.shared.open(Extensions.blockerInStore) }
                }
            } header: {
                Text("Ad and tracker blocking")
            } footer: {
                Text("Its button in the top bar turns it off for a site; Settings › Extensions removes it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Location") {
                let sites = Permissions.shared.location.sorted { $0.key < $1.key }
                if sites.isEmpty {
                    Text("No site has a remembered answer.").foregroundStyle(.secondary)
                }
                ForEach(sites, id: \.key) { site, allowed in
                    HStack {
                        Text(site)
                        Spacer()
                        Text(allowed ? "Allowed" : "Denied").foregroundStyle(.secondary)
                        Button { Permissions.shared.set(site, nil) } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.borderless)
                    }
                }
            }
            Section("Notifications") {
                let sites = Permissions.shared.notifications.sorted { $0.key < $1.key }
                if sites.isEmpty {
                    Text("No site has asked to show notifications.").foregroundStyle(.secondary)
                }
                ForEach(sites, id: \.key) { site, allowed in
                    HStack {
                        Text(site)
                        Spacer()
                        Text(allowed ? "Allowed" : "Denied").foregroundStyle(.secondary)
                        Button {
                            Permissions.shared.setNotifications(site, nil)
                            WebNotifications.tell(site, "default")
                        } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.borderless)
                    }
                }
            }
            Section("Web cache") {
                Picker(selection: $cacheLimit) {
                    Text("100 MB").tag(100)
                    Text("250 MB").tag(250)
                    Text("500 MB").tag(500)
                    Text("1 GB").tag(1024)
                    Text("No limit").tag(0)
                } label: {
                    Text("Keep it under")
                    Text("Pages' files, kept to load them faster next time. Over the limit all of it is deleted, and pages load from the network once.")
                }
                .onChange(of: cacheLimit) { _, _ in
                    DiskUse.enforce()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { measureCache() }
                }
                LabeledContent("On disk now") {
                    HStack(spacing: 12) {
                        Text(cacheSize.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "…")
                            .foregroundStyle(.secondary)
                        Button("Empty Now") {
                            DiskUse.clearCache { measureCache() }
                        }
                    }
                }
                .onAppear { measureCache() }
            }
            Section("Browsing data") {
                Button("Clear History…") { confirm("Clear all history?", "Every page in History is forgotten.") { History.shared.clear() } }
                Button("Remove All Website Data…") {
                    confirm("Remove all website data?", "Cookies, caches and site storage go, so you will be signed out of every site. History and bookmarks stay.") {
                        let store = WKWebsiteDataStore.default()
                        store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) {}
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func measureCache() {
        DiskUse.cacheSize { cacheSize = $0 }
    }

    private func confirm(_ title: String, _ detail: String, then action: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { action() }
    }
}

private struct SiteList: View {
    let sites: [String]
    let empty: String
    var detail: (String) -> String? = { _ in nil }
    let remove: (String) -> Void

    var body: some View {
        if sites.isEmpty {
            Text(empty).foregroundStyle(.secondary)
        }
        ForEach(sites, id: \.self) { site in
            HStack {
                Text(site)
                Spacer()
                if let detail = detail(site) { Text(detail).foregroundStyle(.secondary) }
                Button { remove(site) } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .help("Remove")
            }
        }
    }
}

private struct ExtensionSettings: View {
    // `@State` is a macro in the macOS 27 SDK whose plugin ships only with
    // Xcode, so the State it would expand to is stored by hand.
    private var _link = State(initialValue: "")
    private var link: String {
        get { _link.wrappedValue }
        nonmutating set { _link.wrappedValue = newValue }
    }
    private var _status = State(initialValue: "")
    private var status: String {
        get { _status.wrappedValue }
        nonmutating set { _status.wrappedValue = newValue }
    }

    var body: some View {
        Form {
            Section {
                HStack {
                    TextField("Extension", text: _link.projectedValue, prompt: Text("Chrome Web Store link or extension id"))
                        .labelsHidden()
                    Button("Add") { add { try await Extensions.shared.add(fromStore: link) } }
                        .disabled(link.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Menu("Add Safari Extension") {
                    let found = Extensions.safariExtensions()
                    if found.isEmpty { Text("No Safari extensions on this Mac") }
                    ForEach(found) { safari in
                        Button(safari.name + (Extensions.shared.has(safari) ? " (added)" : "")) {
                            add { try await Extensions.shared.add(safari: safari) }
                        }
                        .disabled(Extensions.shared.has(safari))
                    }
                }
                .fixedSize()
                Button("Add Unpacked Extension…") {
                    let panel = NSOpenPanel()
                    panel.canChooseFiles = false
                    panel.canChooseDirectories = true
                    panel.message = "Choose the folder with the extension's manifest.json"
                    guard panel.runModal() == .OK, let folder = panel.url else { return }
                    add { try await Extensions.shared.add(fromFolder: folder) }
                }
                if !status.isEmpty { Text(status).font(.caption).foregroundStyle(.secondary) }
            } footer: {
                Text("Extensions run on WebKit's own extension engine, as in Safari. A Safari extension, made for it, is loaded from inside its app; one from the Chrome Web Store that needs a Chrome API WebKit lacks won't work. They work in private tabs too.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Installed") {
                if Extensions.shared.contexts.isEmpty {
                    Text("None yet.").foregroundStyle(.secondary)
                }
                ForEach(Extensions.shared.contexts, id: \.uniqueIdentifier) { context in
                    HStack {
                        if let icon = context.webExtension.icon(for: CGSize(width: 20, height: 20)) {
                            Image(nsImage: icon).resizable().frame(width: 20, height: 20)
                        }
                        VStack(alignment: .leading) {
                            Text(context.webExtension.displayName ?? "Extension")
                            Text(context.webExtension.version ?? "").font(.caption).foregroundStyle(.secondary)
                            ForEach(Array((context.errors + context.webExtension.errors).prefix(3).enumerated()), id: \.offset) { _, error in
                                Text(error.localizedDescription).font(.caption).foregroundStyle(.orange).lineLimit(2)
                            }
                        }
                        Spacer()
                        if context.optionsPageURL != nil {
                            Button("Options") {
                                if let url = context.optionsPageURL { (Windows.front ?? Windows.open(empty: true)).open(url, select: true) }
                            }
                        }
                        Button("Reload") { Extensions.shared.reload(context) }
                            .help("Start the extension afresh, as if BasicShell had just opened")
                        Button("Remove") { Extensions.shared.remove(context) }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func add(_ work: @escaping () async throws -> String) {
        status = "Adding…"
        Task {
            do {
                status = try await work()
                link = ""
            } catch {
                status = error.localizedDescription
            }
        }
    }
}

#if AGENT
/// Version, and looking for a newer one (see Update.swift).
private struct UpdateSection: View {
    var body: some View {
        let updater = Updater.shared
        Section {
            Toggle(isOn: Binding(get: { updater.automatic }, set: { updater.automatic = $0 })) {
                Text("Look for updates by itself")
                Text("Once a day, BasicShell asks github.com for the latest release, which sends nothing of yours but the address of the request. A newer one is offered, never put in without your say.")
            }
            LabeledContent {
                HStack {
                    if case .available = updater.state {
                        Button("Update…") { Task { await updater.check(manually: true) } }
                    }
                    Button("Check Now") { Task { await updater.check(manually: true) } }.disabled(updater.busy)
                }
            } label: {
                Text("Version \(updater.current)")
                if !updater.status.isEmpty { Text(updater.status) }
            }
        }
    }
}
#endif
