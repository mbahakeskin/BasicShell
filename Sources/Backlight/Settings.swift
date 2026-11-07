import AppKit
import SwiftUI
import WebKit

/// Backlight › Settings (⌘,): a panel over the page, as History and
/// Downloads are, a few plain choices on a few tabs.
enum SettingsWindow {
    /// Brings the panel up in the front window (a new one if there is none),
    /// on `tab` if one is named; one already up stays.
    @MainActor static func show(_ tab: String? = nil) {
        if let tab { UserDefaults.standard.set(tab, forKey: "settings.tab") }
        let window = Windows.front ?? Windows.open(empty: true)
        if window.shell.panel != .settings { window.showPanel(.settings) }
    }

    static let tabs: [(id: String, title: String)] = {
        var list = [("general", "General"), ("search", "Search"), ("import", "Import"), ("tabs", "Tabs"),
                    ("privacy", "Privacy"), ("extensions", "Extensions")]
        #if AGENT
        list.append(("agent", "Agents"))
        #endif
        return list
    }()
}

/// The panel's top row: where the title is in the other panels.
struct SettingsTabs: View {
    @Binding var tab: String

    var body: some View {
        HStack(spacing: 2) {
            ForEach(SettingsWindow.tabs, id: \.id) { entry in
                Button { tab = entry.id } label: {
                    Text(entry.title)
                        .font(.system(size: 13, weight: .medium))
                        .padding(.horizontal, 12)
                        .frame(height: 28)
                        .background(Capsule().fill(Color.primary.opacity(tab == entry.id ? 0.12 : 0)))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .foregroundStyle(tab == entry.id ? .primary : .secondary)
            }
        }
    }
}

/// What the chosen tab shows.
struct SettingsContent: View {
    let tab: String

    var body: some View {
        switch tab {
        case "search": KeywordSettings()
        case "import": ImportSettings()
        case "tabs": TabSettings()
        case "privacy": PrivacySettings()
        case "extensions": ExtensionSettings()
        #if AGENT
        case "agent": AgentSettings()
        #endif
        default: GeneralSettings()
        }
    }
}

private struct GeneralSettings: View {
    @AppStorage("engine") private var engine = Engine.google.rawValue
    @AppStorage("engine.region") private var region = true
    @AppStorage("debug.enabled") private var debug = false
    @AppStorage("fullscreen.notch") private var notch = true
    @AppStorage(Features.highRefreshKey) private var highRefresh = true
    @AppStorage(Dusk.onKey) private var dusk = false
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
                Text("Adds hl=\(Engine.language)\(Engine.region.map { ", gl=\($0)" } ?? "") so a VPN doesn't change the results.")
            }
            .disabled(engine != Engine.google.rawValue)
            Toggle(isOn: $highRefresh) {
                Text("Let pages draw as fast as the screen")
                Text("WebKit caps animations at 60 frames a second. Off, they are capped again and the battery lasts longer.")
            }
            .onChange(of: highRefresh) { _, _ in Features.forEachPage { Features.applyRefresh(to: $0) } }
            if Dusk.available {
                Toggle(isOn: $dusk) {
                    Text("Darken light pages")
                    Text("White pages get dark colours while macOS is dark. ⇧⌘D turns it off for a site, ⌥⇧⌘D for all.")
                }
                .onChange(of: dusk) { _, _ in Dusk.shared.changed() }
            }
            if Dusk.available, !Dusk.shared.sites.isEmpty {
                Section("Dark pages set by hand") {
                    SiteList(sites: Dusk.shared.sites.keys.sorted(), empty: "", detail: {
                        Dusk.shared.sites[$0] == true ? "Darkened" : "Left as it is"
                    }) {
                        Dusk.shared.forget($0)
                    }
                }
            }
            MediaDownloadSettings()
            Section {
                Toggle(isOn: $notch) {
                    Text("Full screen uses the space beside the notch")
                    Text("The page goes to the top of the screen. Off, full screen is a desktop of its own.")
                }
            }
            Section {
                Toggle(isOn: $develop) {
                    Text("Show the Develop menu")
                    Text("The Web Inspector, page source, user agent, page size and more, as in Safari.")
                }
                .onChange(of: develop) { _, _ in Menus.showDeveloperMenus() }
                Toggle(isOn: $debugMenu) {
                    Text("Show the Debug menu")
                    Text("WebKit's internal switches. They can break pages; the last item puts them back.")
                }
                .onChange(of: debugMenu) { _, _ in Menus.showDeveloperMenus() }
            }
            Section {
                Toggle(isOn: $debug) {
                    Text("Debug logging")
                    Text("A log of location requests, extension popups and what pages report. Reopen Backlight to apply.")
                }
                Button("Open Debug Log") { DebugWindow.show() }
            }
            #if AGENT
            UpdateSection()
            #endif
            Section {
                Button("Make Backlight the Default Browser") {
                    let app = Bundle.main.bundleURL
                    NSWorkspace.shared.setDefaultApplication(at: app, toOpenURLsWithScheme: "http") { _ in
                        NSWorkspace.shared.setDefaultApplication(at: app, toOpenURLsWithScheme: "https") { _ in }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
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
                Text("Sleeping tabs stop; unloaded ones give back their memory and reload where they were; archived ones leave the sidebar (Tab › Show Archived Tabs). Pinned tabs stay.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle(isOn: $freeze) {
                    Text("Freeze tabs off screen")
                    Text("Stops them completely instead of slowing them.")
                }
            }
            Section("Sites kept awake") {
                SiteList(sites: Awake.shared.sites.sorted(), empty: "None. The sun in the top bar keeps a site awake.") {
                    Awake.shared.remove(site: $0)
                }
            }
            Section("Sites muted") {
                SiteList(sites: MutedSites.shared.sites.sorted(), empty: "None. Right-click a tab to mute its site.") {
                    MutedSites.shared.remove(site: $0)
                }
            }
            Section("Sites with developer settings") {
                SiteList(sites: SiteDevelop.shared.sites.keys.sorted(), empty: "None. Develop › Keep These Settings for This Site.", detail: {
                    SiteDevelop.shared.sites[$0]?.summary
                }) {
                    SiteDevelop.shared.save(nil, for: $0)
                }
            }
            Section("Sites with their own zoom") {
                SiteList(sites: SiteZoom.shared.levels.keys.sorted(), empty: "None. ⌘+ and ⌘− set a site's zoom.", detail: {
                    SiteZoom.shared.level(for: $0).map { "\(Int(($0 * 100).rounded()))%" }
                }) {
                    SiteZoom.shared.set(nil, for: $0)
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}

private struct PrivacySettings: View {
    @AppStorage(Extensions.blockerWanted) private var blocker = false
    @AppStorage(DiskUse.limitKey) private var cacheLimit = 250
    @AppStorage(LinkCleaner.key) private var cleanLinks = true
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
                    Text("The Safari extension from its App Store app.")
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
                Text("Its top bar button turns it off for a site.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle(isOn: $cleanLinks) {
                    Text("Copy addresses without tracking")
                    Text("⇧⌘C drops utm_, fbclid and the like. ⌥⇧⌘C copies the address as it is.")
                }
            } header: {
                Text("Copied links")
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
                    Text("Over the limit, the cache is emptied.")
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
        .scrollContentBackground(.hidden)
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

/// The sites that get a download button over their photos and videos.
private struct MediaDownloadSettings: View {
    // `@State` is a macro in the macOS 27 SDK whose plugin ships only with
    // Xcode, so the State it would expand to is stored by hand.
    private var _site = State(initialValue: "")
    private var site: String {
        get { _site.wrappedValue }
        nonmutating set { _site.wrappedValue = newValue }
    }

    private func add() {
        if MediaDownload.shared.add(site) { site = "" }
    }

    var body: some View {
        Section("Download button on photos and videos") {
            Text("A site listed here shows a save button over its photos and videos.")
                .foregroundStyle(.secondary)
            HStack {
                TextField("Site", text: _site.projectedValue, prompt: Text("example.com"))
                    .labelsHidden()
                    .onSubmit { add() }
                Button("Add") { add() }
                    .disabled(MediaDownload.normalized(site) == nil)
            }
            SiteList(sites: MediaDownload.shared.sites, empty: "None.") { MediaDownload.shared.remove($0) }
        }
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
                Text("They run on WebKit's extension engine, as in Safari. A Chrome extension that needs a Chrome-only API won't work.")
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
                            .help("Start the extension afresh, as if Backlight had just opened")
                        Button("Remove") { Extensions.shared.remove(context) }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
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
                Text("Once a day it asks github.com for the latest release. Nothing is installed without your say.")
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

/// Sites the address field searches by a keyword: "yt lofi", "cl write a poem".
private struct KeywordSettings: View {
    @AppStorage(Keywords.key) private var stored = ""

    private var items: Binding<[Keyword]> {
        Binding(get: { Keywords.decode(stored) }, set: { stored = Keywords.encode($0) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Search a site from the address field").font(.headline)
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(items) { $item in
                        HStack(spacing: 8) {
                            Button {
                                Dropper.pick { item.colour = $0.hex }
                            } label: {
                                ZStack {
                                    Circle().fill(item.tint ?? Color.clear)
                                    Circle().strokeBorder(Color.secondary.opacity(0.5), lineWidth: 1)
                                    if item.colour == nil { Image(systemName: "eyedropper").font(.system(size: 9)).foregroundStyle(.secondary) }
                                }
                                .frame(width: 20, height: 20)
                            }
                            .buttonStyle(.plain)
                            .help("Pick the site's color from anywhere on the screen")
                            .contextMenu { Button("Remove Color") { item.colour = nil } }
                            TextField("", text: $item.key, prompt: Text("key")).frame(width: 60)
                            TextField("", text: $item.name, prompt: Text("name")).frame(width: 110)
                            TextField("", text: $item.template, prompt: Text("https://…/search?q=%s")).frame(maxWidth: .infinity)
                            Button {
                                items.wrappedValue.removeAll { $0.id == item.id }
                            } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                        }
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.leading)
                    }
                }
                .padding(.trailing, 4)
            }
            HStack {
                Button("Add") { items.wrappedValue.append(Keyword(key: "", name: "", template: "https://")) }
                Button("Restore Built-in List") { Keywords.restoreDefaults(); stored = "" }
            }
            Text("Type a key and a space, then the words: “yt lofi”. %s is where the words go. A site's search box can be added from its right-click menu. The dot is the site's colour.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 16)
    }
}
