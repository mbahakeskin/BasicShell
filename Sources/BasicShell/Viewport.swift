import AppKit
import WebKit

// How a page is shown, for trying a layout: the size of the window (the page's
// view is then that size), the way the browser introduces itself to sites, and
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

    /// A window's frame from before its size was changed here, to put back.
    private static var windowed: [ObjectIdentifier: NSRect] = [:]

    static func isResized(_ window: NSWindow) -> Bool { windowed[ObjectIdentifier(window)] != nil }

    /// The window as it was, if its size was changed here.
    @discardableResult
    static func restore(_ window: NSWindow) -> Bool {
        guard let frame = windowed.removeValue(forKey: ObjectIdentifier(window)) else { return false }
        window.setFrame(frame, display: true, animate: false)
        return true
    }

    /// The window made as large as it takes for the page's view to be `size`;
    /// said back in words, with a note where the screen wouldn't allow it.
    static func resize(_ web: WKWebView, in window: NSWindow, to size: CGSize) async throws -> String {
        guard !window.styleMask.contains(.fullScreen) else {
            throw Refused(message: "The window is full screen, which has a size of its own; it has to be left first.")
        }
        guard size.width >= 200, size.height >= 200, size.width <= 6000, size.height <= 6000 else {
            throw Refused(message: "A page view between 200 and 6000 points each way.")
        }
        let key = ObjectIdentifier(window)
        if windowed[key] == nil { windowed[key] = window.frame }
        // The window grows by what the view is short of.
        var frame = window.frame
        frame.size.width += size.width - web.bounds.width
        frame.size.height += size.height - web.bounds.height
        frame.origin.y -= frame.size.height - window.frame.size.height
        if let area = (window.screen ?? NSScreen.main)?.visibleFrame {
            frame.size.width = min(frame.size.width, area.width)
            frame.size.height = min(frame.size.height, area.height)
            frame.origin.x = min(max(frame.origin.x, area.minX), area.maxX - frame.size.width)
            frame.origin.y = min(max(frame.origin.y, area.minY), area.maxY - frame.size.height)
        }
        window.setFrame(frame, display: true, animate: false)
        try? await Task.sleep(for: .milliseconds(250))
        let exact = Int(web.bounds.width) == Int(size.width) && Int(web.bounds.height) == Int(size.height)
        return "the page view is \(Int(web.bounds.width))×\(Int(web.bounds.height)) points" + (exact ? "" : " (the window or the screen wouldn't give more or less)")
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
