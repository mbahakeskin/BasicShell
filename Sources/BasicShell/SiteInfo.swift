import AppKit
import Observation
import SecurityInterface
import SwiftUI
import WebKit

// What the lock at the left of the address brings up: how the page was
// fetched and by whose word, what the site has been allowed, what it keeps on
// this Mac, and the zoom it is given.

/// The zoom a site was given, kept by its host: ⌘+, ⌘− and the panel's own
/// buttons set it, and it comes back whenever a tab goes to the site. Never
/// set from a private tab.
@Observable
final class SiteZoom {
    static let shared = SiteZoom()
    private static let key = "site.zoom"

    private(set) var levels: [String: Double] = UserDefaults.standard.dictionary(forKey: SiteZoom.key) as? [String: Double] ?? [:]

    func level(for site: String) -> Double? { levels[site] }

    func set(_ level: Double?, for site: String) {
        levels[site] = level
        UserDefaults.standard.set(levels, forKey: SiteZoom.key)
    }
}

extension BrowserWindow {
    /// The page's zoom, and the site's from now on.
    func zoom(to level: Double) {
        guard let tab = shell.selected, let web = tab.webView else { return }
        let level = min(3, max(0.3, (level * 100).rounded() / 100))
        web.pageZoom = level
        if !tab.isPrivate, let site = tab.url?.host() { SiteZoom.shared.set(level == 1 ? nil : level, for: site) }
    }

    func zoom(by step: Double) {
        guard let web = shell.selected?.webView else { return }
        zoom(to: Double(web.pageZoom) + step)
    }
}

/// The lock (or an "i", where the page isn't secure) in the address field.
struct SiteInfoButton: View {
    let shell: Shell
    let window: BrowserWindow
    /// Which side of the button the panel opens on.
    var edge: Edge = .bottom

    var body: some View {
        let tab = shell.selected
        if let url = tab?.url, ["http", "https"].contains(url.scheme ?? ""), url.host() != nil {
            let open = Binding(get: { shell.siteInfoOpen }, set: { showing in
                shell.siteInfoOpen = showing
                window.layout(animated: true)
            })
            Button { open.wrappedValue.toggle() } label: {
                Image(systemName: url.scheme == "https" ? "lock.fill" : "info.circle")
                    .font(.system(size: url.scheme == "https" ? 9 : 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Site Information")
            .popover(isPresented: open, arrowEdge: edge) {
                if let tab { SiteInfoView(tab: tab, window: window) { open.wrappedValue = false } }
            }
        } else {
            Color.clear.frame(width: 28, height: 1)
        }
    }
}

struct SiteInfoView: View {
    let tab: Tab
    let window: BrowserWindow
    let close: () -> Void

    // `@State` is a macro in the macOS 27 SDK whose plugin ships only with
    // Xcode, so the State it would expand to is stored by hand.
    private var _cookies = State<Int?>(initialValue: nil)
    private var cookies: Int? {
        get { _cookies.wrappedValue }
        nonmutating set { _cookies.wrappedValue = newValue }
    }
    private var _zoom = State(initialValue: 1.0)
    private var zoom: Double {
        get { _zoom.wrappedValue }
        nonmutating set { _zoom.wrappedValue = newValue }
    }

    init(tab: Tab, window: BrowserWindow, close: @escaping () -> Void) {
        self.tab = tab
        self.window = window
        self.close = close
        _zoom = State(initialValue: Double(tab.webView?.pageZoom ?? 1))
    }

    private var site: String { tab.url?.host() ?? "" }
    private var secure: Bool { tab.url?.scheme == "https" }
    private var trust: SecTrust? { tab.webView?.serverTrust }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if secure, let trust, let certificate = Certificate(trust) {
                Divider()
                certificateSection(certificate, trust)
            }
            if !tab.isPrivate {
                Divider()
                permissions
            }
            Divider()
            data
            Divider()
            zoomSection
        }
        .frame(width: 300)
        .task { await countCookies() }
    }

    // MARK: connection

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: secure ? "lock.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 18))
                .foregroundStyle(secure && tab.webView?.hasOnlySecureContent != false ? Color.green : Color.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(site).font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                Text(connection).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
    }

    private var connection: String {
        if !secure { return "Not secure: anyone on the way can read what you send and get" }
        if tab.webView?.hasOnlySecureContent == false { return "Secure, but parts of the page are not" }
        return trust == nil ? "Secure connection" : "Secure connection, verified"
    }

    private func certificateSection(_ certificate: Certificate, _ trust: SecTrust) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            row("Issued to", certificate.subject)
            row("Issued by", certificate.issuer ?? "—")
            if let expires = certificate.expires {
                row("Expires", expires.formatted(date: .abbreviated, time: .omitted))
            }
            Button("Show Certificate…") {
                close()
                guard let sheet = window.window else { return }
                SFCertificatePanel.shared().beginSheet(for: sheet, modalDelegate: nil, didEnd: nil, contextInfo: nil, trust: trust, showGroup: true)
            }
            .buttonStyle(.link)
            .font(.system(size: 12))
        }
        .padding(12)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary).frame(width: 70, alignment: .leading)
            Text(value).lineLimit(2).truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .font(.system(size: 12))
    }

    // MARK: what the site was allowed

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Allowed here").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            answer("Location", Permissions.shared.location[site]) { Permissions.shared.set(site, nil) }
            answer("Notifications", Permissions.shared.notifications[site]) {
                Permissions.shared.setNotifications(site, nil)
                WebNotifications.tell(site, "default")
            }
        }
        .padding(12)
    }

    private func answer(_ name: String, _ allowed: Bool?, reset: @escaping () -> Void) -> some View {
        HStack {
            Text(name)
            Spacer()
            Text(allowed == nil ? "Asks" : allowed == true ? "Allowed" : "Not allowed").foregroundStyle(.secondary)
            Button { reset() } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.borderless)
                .opacity(allowed == nil ? 0 : 1)
                .disabled(allowed == nil)
                .help("Ask again")
        }
        .font(.system(size: 12))
    }

    // MARK: what it keeps

    private var data: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Kept on this Mac").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Text(cookies.map { "\($0) cookie\($0 == 1 ? "" : "s") and stored data" } ?? "…")
                    .font(.system(size: 12))
            }
            Spacer()
            Button("Remove…") { removeData() }
                .font(.system(size: 12))
        }
        .padding(12)
    }

    private func countCookies() async {
        guard let store = tab.webView?.configuration.websiteDataStore else { return }
        let all = await store.httpCookieStore.allCookies()
        cookies = all.filter { SiteInfoView.matches($0.domain, site) }.count
    }

    /// Whether a cookie's or a record's domain is the site or above it.
    static func matches(_ domain: String, _ host: String) -> Bool {
        let bare = domain.hasPrefix(".") ? String(domain.dropFirst()) : domain
        return host == bare || host.hasSuffix("." + bare)
    }

    private func removeData() {
        close()
        let alert = NSAlert()
        alert.messageText = "Remove what \(site) keeps on this Mac?"
        alert.informativeText = "Its cookies, caches and stored data go, so you will be signed out of it. The page is loaded again."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn, let web = tab.webView else { return }
        let store = web.configuration.websiteDataStore
        let site = site
        store.fetchDataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes()) { records in
            let mine = records.filter { SiteInfoView.matches($0.displayName, site) }
            store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: mine) {
                MainActor.assumeIsolated { _ = web.reload() }
            }
        }
    }

    // MARK: zoom

    private var zoomSection: some View {
        HStack {
            Text("Zoom").font(.system(size: 12))
            Spacer()
            Button { change(to: zoom - 0.1) } label: { Image(systemName: "minus") }
            Text("\(Int((zoom * 100).rounded()))%")
                .font(.system(size: 12).monospacedDigit())
                .frame(width: 44)
            Button { change(to: zoom + 0.1) } label: { Image(systemName: "plus") }
            Button("Reset") { change(to: 1) }
                .disabled(zoom == 1)
        }
        .buttonStyle(.borderless)
        .padding(12)
    }

    private func change(to level: Double) {
        window.zoom(to: level)
        zoom = Double(tab.webView?.pageZoom ?? 1)
    }

    // MARK: the certificate

    /// What the panel says of the certificate the site showed.
    struct Certificate {
        let subject: String
        let issuer: String?
        let expires: Date?

        init?(_ trust: SecTrust) {
            guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first,
                  let subject = SecCertificateCopySubjectSummary(leaf) as String?
            else { return nil }
            self.subject = subject
            issuer = chain.count > 1 ? SecCertificateCopySubjectSummary(chain[1]) as String? : nil
            let key = kSecOIDX509V1ValidityNotAfter
            var date: Date?
            if let values = SecCertificateCopyValues(leaf, [key] as CFArray, nil) as? [CFString: Any],
               let entry = values[key] as? [CFString: Any], let value = entry[kSecPropertyKeyValue] {
                if let found = value as? Date { date = found }
                else if let seconds = value as? NSNumber { date = Date(timeIntervalSinceReferenceDate: seconds.doubleValue) }
            }
            expires = date
        }
    }
}
