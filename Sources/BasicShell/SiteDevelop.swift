import AppKit
import Observation
import WebKit

// The Develop menu's settings, kept for a site: its user agent, colour scheme,
// and whether JavaScript, images, styles and the cross-origin and local-file
// restrictions are off. Chosen with Develop › Keep These Settings for This Site,
// they are put on a tab as it goes to that site (and taken off again as it goes
// to another), and follow what is changed in the menu while the tab is there.
// Settings › Tabs lists the sites. Not for private tabs, and the window's
// size (Responsive Design) is the window's, not a site's.

struct DevelopSettings: Codable, Equatable {
    var userAgent: String?
    var look: String?
    var javaScriptOff = false
    var imagesOff = false
    var stylesOff = false
    var crossOriginOff = false
    var localFilesOff = false

    /// In words, for Settings.
    var summary: String {
        var parts: [String] = []
        if let userAgent {
            parts.append(Viewport.Agents.all.first { $0.agent == userAgent }?.title ?? "custom user agent")
        }
        if let look { parts.append(look.contains("Dark") ? "dark" : "light") }
        if javaScriptOff { parts.append("no JavaScript") }
        if imagesOff { parts.append("no images") }
        if stylesOff { parts.append("no styles") }
        if crossOriginOff { parts.append("cross-origin open") }
        if localFilesOff { parts.append("local files open") }
        return parts.isEmpty ? "nothing changed" : parts.joined(separator: ", ")
    }
}

@Observable
final class SiteDevelop {
    static let shared = SiteDevelop()
    private static let key = "site.develop"

    private(set) var sites: [String: DevelopSettings]
    /// Putting a site's settings on a tab calls the setters that would save them: not then.
    @ObservationIgnored private var applying = false

    private init() {
        sites = (UserDefaults.standard.data(forKey: Self.key)).flatMap { try? JSONDecoder().decode([String: DevelopSettings].self, from: $0) } ?? [:]
    }

    func save(_ settings: DevelopSettings?, for site: String) {
        sites[site] = settings
        if let data = try? JSONEncoder().encode(sites) { UserDefaults.standard.set(data, forKey: Self.key) }
    }

    /// A tab is about to go to `host` (decided on before its request is made, so the settings reach it).
    @MainActor
    func prepare(_ tab: Tab, for host: String) {
        guard !tab.isPrivate, tab.developHost != host else { return }
        if let saved = sites[host] {
            tab.developHost = host
            apply(saved, to: tab)
        } else if tab.developHost != nil {
            // From a site that had its own settings to one that has none: plain again.
            tab.developHost = nil
            apply(DevelopSettings(), to: tab)
        }
    }

    /// Something in the Develop menu changed on this tab: the site it is on, if it has settings, keeps up.
    @MainActor
    func changed(_ tab: Tab) {
        // A site taken out of Settings' list is not put back by the tab that still follows it.
        guard !applying, let host = tab.developHost, sites[host] != nil else { return }
        save(tab.developSettings, for: host)
    }

    @MainActor
    private func apply(_ settings: DevelopSettings, to tab: Tab) {
        applying = true
        defer { applying = false }
        tab.javaScriptOff = settings.javaScriptOff
        Viewport.setAgent(settings.userAgent, for: tab)
        Viewport.setLook(settings.look.map(NSAppearance.Name.init(rawValue:)), for: tab)
        if let web = tab.webView {
            if tab.imagesOff != settings.imagesOff { Develop.setImages(!settings.imagesOff, web) }
            if tab.stylesOff != settings.stylesOff { Develop.setStyles(!settings.stylesOff, web) }
            if tab.crossOriginOff != settings.crossOriginOff { Develop.setCrossOriginRestrictions(!settings.crossOriginOff, web) }
            if tab.localFilesOff != settings.localFilesOff { Develop.setLocalFileRestrictions(!settings.localFilesOff, web) }
        }
        tab.imagesOff = settings.imagesOff
        tab.stylesOff = settings.stylesOff
        tab.crossOriginOff = settings.crossOriginOff
        tab.localFilesOff = settings.localFilesOff
    }
}

extension Tab {
    /// What the Develop menu has set on this tab.
    var developSettings: DevelopSettings {
        DevelopSettings(userAgent: userAgent, look: look?.rawValue, javaScriptOff: javaScriptOff, imagesOff: imagesOff,
                        stylesOff: stylesOff, crossOriginOff: crossOriginOff, localFilesOff: localFilesOff)
    }
}

extension BrowserWindow {
    /// Develop › Keep These Settings for This Site: what the menu has set here is kept for the site, or let go.
    @objc func toggleKeepDevelop(_ sender: Any?) {
        guard let tab = shell.selected, !tab.isPrivate, let host = tab.url?.host() else { return }
        if tab.developHost == host {
            SiteDevelop.shared.save(nil, for: host)
            tab.developHost = nil
            say("\(host) no longer keeps developer settings")
        } else {
            tab.developHost = host
            SiteDevelop.shared.save(tab.developSettings, for: host)
            say("\(host) keeps these settings")
        }
    }
}
