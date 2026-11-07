import AppKit
import WebKit

// How a page is shown, for trying a layout: the size of the frame it stands in
// (the window keeps its own, see Stage.swift), the way the browser introduces itself to sites, and
// the light or dark look the page is told of. The Develop menu and the agent's
// `resize` both do it here.
//
// WebKit has no touch or screen emulation, so a phone is its width, its user
// agent, and nothing else.
enum Viewport {
    enum Preset: String {
        case mobile, tablet, desktop

        var size: CGSize? {
            switch self {
            case .mobile: CGSize(width: 390, height: 844)
            case .tablet: CGSize(width: 820, height: 1180)
            case .desktop: nil
            }
        }

        var agent: String? {
            switch self {
            case .mobile: Agents.iPhone
            case .tablet: Agents.iPad
            case .desktop: nil
            }
        }

        /// How it is said in a sentence.
        var device: String { self == .mobile ? "an iPhone" : "an iPad" }
    }

    /// What the Develop menu offers besides the browser's own; the browser's
    /// own is `nil`. Versions are examples: what a site tells browsers apart
    /// by is the engine's name and the platform.
    enum Agents {
        static let iPhone = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
        static let iPad = "Mozilla/5.0 (iPad; CPU OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
        static let chrome = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36"
        static let firefox = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10.15; rv:142.0) Gecko/20100101 Firefox/142.0"

        static let presets: [(title: String, agent: String?)] = [
            ("Default", nil),
            ("Safari — iPhone", iPhone),
            ("Safari — iPad", iPad),
            ("Google Chrome — macOS", chrome),
            ("Firefox — macOS", firefox),
        ]

        private static let customKey = "develop.agents"

        /// The ones typed in by the person, newest first (the last five).
        static var custom: [String] { UserDefaults.standard.stringArray(forKey: customKey) ?? [] }

        /// Everything the User Agent menu lists, in order.
        static var all: [(title: String, agent: String?)] {
            presets + custom.map { (String($0.prefix(64)), $0) }
        }

        static func remember(_ agent: String) {
            UserDefaults.standard.set(Array(([agent] + custom.filter { $0 != agent }).prefix(5)), forKey: customKey)
        }

        static func forget() { UserDefaults.standard.removeObject(forKey: customKey) }
    }

    struct Refused: Error {
        let message: String
    }

    /// The window a tab's window is, when it is one of the browser's.
    private static func browser(_ window: NSWindow) -> BrowserWindow? { window.windowController as? BrowserWindow }

    /// Whether the page is shown in a frame of another size (see Stage.swift).
    static func isResized(_ window: NSWindow) -> Bool { browser(window)?.stage.size != nil }

    /// The page filling the window again, if it was in a frame.
    @discardableResult
    static func restore(_ window: NSWindow) -> Bool {
        guard let shell = browser(window), shell.shell.selected?.stageSize != nil else { return false }
        shell.setStage(nil)
        return true
    }

    /// The page shown in a frame where it is told it is `size`; said back in
    /// words, with a note where the window has no room for it that large.
    static func resize(_ web: WKWebView, in window: NSWindow, to size: CGSize) async throws -> String {
        guard size.width >= 200, size.height >= 200, size.width <= 6000, size.height <= 6000 else {
            throw Refused(message: "A page size between 200 and 6000 points each way.")
        }
        guard let shell = browser(window) else { throw Refused(message: "That tab is in no browser window.") }
        shell.setStage(size, for: shell.shell.allTabs.first { $0.webView === web })
        try? await Task.sleep(for: .milliseconds(150))
        let scale = shell.stage.scale
        return "the page is told it is \(Int(size.width))×\(Int(size.height)) points, in a frame in the window"
            + (scale < 0.995 ? ", drawn at \(Int((scale * 100).rounded()))% to fit (screenshots are smaller than that size)" : "")
    }

    /// The way the tab introduces itself to sites, kept across an unload;
    /// `nil` is the browser's own. Sites are told once the page loads again.
    static func setAgent(_ agent: String?, for tab: Tab) {
        tab.userAgent = agent
        tab.webView?.customUserAgent = agent
        SiteDevelop.shared.changed(tab)
    }

    /// The look the page is told of (`prefers-color-scheme`); `nil` is the
    /// system's.
    static func setLook(_ look: NSAppearance.Name?, for tab: Tab) {
        tab.look = look
        tab.webView?.appearance = look.flatMap { NSAppearance(named: $0) }
        SiteDevelop.shared.changed(tab)
    }

    /// Put on a web view when it is made, for what the tab was set to.
    static func apply(to tab: Tab, _ web: WKWebView) {
        if let agent = tab.userAgent { web.customUserAgent = agent }
        if let look = tab.look { web.appearance = NSAppearance(named: look) }
    }
}
