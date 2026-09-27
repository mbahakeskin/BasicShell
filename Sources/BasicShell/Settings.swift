import AppKit
import SwiftUI
import WebKit

/// BasicShell › Settings (⌘,): one window, a few plain choices.
enum SettingsWindow {
    private static var window: NSWindow?

    static func show() {
        if window == nil {
            let made = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 580, height: 520),
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
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            TabSettings().tabItem { Label("Tabs", systemImage: "square.on.square") }
            PrivacySettings().tabItem { Label("Privacy", systemImage: "hand.raised") }
            ExtensionSettings().tabItem { Label("Extensions", systemImage: "puzzlepiece.extension") }
        }
        .padding(.top, 28)
        .frame(width: 580, height: 520)
    }
}

private struct GeneralSettings: View {
    @AppStorage("engine") private var engine = Engine.google.rawValue
    @AppStorage("engine.region") private var region = true
    @AppStorage("debug.enabled") private var debug = false

    var body: some View {
        Form {
            Picker("Search with", selection: $engine) {
                ForEach(Engine.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
            }
            Toggle(isOn: $region) {
                Text("Search Google in this Mac's language and region")
                Text("Adds hl=\(Engine.language)\(Engine.region.map { ", gl=\($0)" } ?? "") to Google searches, so results don't follow a VPN's country.")
            }
            .disabled(engine != Engine.google.rawValue)
            Section {
                Toggle(isOn: $debug) {
                    Text("Debug logging")
                    Text("Keeps a log of location requests, extension popups and what pages and extensions report. Takes full effect after reopening BasicShell.")
                }
                Button("Open Debug Log") { DebugWindow.show() }
            }
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

    private let unloadChoices: [(String, Double)] = [("1 hour", 1), ("2 hours", 2), ("6 hours", 6), ("12 hours", 12), ("1 day", 24), ("Never", 0)]
    private let archiveChoices: [(String, Double)] = [("6 hours", 6), ("12 hours", 12), ("1 day", 24), ("3 days", 72), ("1 week", 168), ("Never", 0)]

    var body: some View {
        Form {
            Section {
                Picker("Unload tabs unseen for", selection: $unload) {
                    ForEach(unloadChoices, id: \.1) { Text($0.0).tag($0.1) }
                }
                Picker("Archive tabs unseen for", selection: $archive) {
                    ForEach(archiveChoices, id: \.1) { Text($0.0).tag($0.1) }
                }
            } footer: {
                Text("Unloaded tabs give their memory back and reload where they were; archived tabs leave the sidebar for Tab › Show Archived Tabs. Pinned tabs are never archived, and nothing holding unsent typing is unloaded.")
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
        }
        .formStyle(.grouped)
    }
}

private struct PrivacySettings: View {
    var body: some View {
        Form {
            Section("Ad and tracker blocking") {
                LabeledContent("Block lists", value: Shield.shared.version.map { "EasyList and EasyPrivacy, \($0)" } ?? "Built-in list")
                if let trouble = Shield.shared.trouble {
                    Text(trouble).font(.caption).foregroundStyle(.red)
                }
                Button("Update Block Lists") {
                    Task {
                        let result = await Shield.shared.update()
                        Windows.front?.say(result)
                    }
                }
            }
            Section("Sites where ads are allowed") {
                SiteList(sites: Shield.shared.paused.sorted(), empty: "None. The shield in the top bar allows them on one site.") {
                    Shield.shared.pause($0, false)
                }
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
    let remove: (String) -> Void

    var body: some View {
        if sites.isEmpty {
            Text(empty).foregroundStyle(.secondary)
        }
        ForEach(sites, id: \.self) { site in
            HStack {
                Text(site)
                Spacer()
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
                Text("Extensions run on WebKit's own extension engine, as in Safari. One that needs a Chrome API WebKit lacks won't work. They never see private tabs.")
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
