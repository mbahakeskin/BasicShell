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
        }
        .padding(.top, 28)
        .frame(width: 580, height: 520)
    }
}

private struct GeneralSettings: View {
    @AppStorage("engine") private var engine = Engine.google.rawValue
    @AppStorage("engine.region") private var region = true

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
                Text("Tabs off screen are always frozen. Unloaded tabs give their memory back and reload where they were; archived tabs leave the sidebar for Tab › Show Archived Tabs. Pinned tabs are never archived, and nothing holding unsent typing is unloaded.")
                    .font(.caption).foregroundStyle(.secondary)
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
