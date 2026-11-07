import AppKit
import SwiftUI
import WebKit

// A window an extension asks for as a popup (Bitwarden's "pop out", say): it
// is not a macOS window of its own but a panel over the page, as Settings
// and History are, put away by a click outside it. To the extension it is a
// window of one tab (`PopoutWindow`), which is closed with it.

final class PopoutWindow: NSObject, WKWebExtensionWindow {
    let tab: Tab
    let size: CGSize
    weak var owner: BrowserWindow?

    init(tab: Tab, size: CGSize, owner: BrowserWindow) {
        self.tab = tab
        self.size = size
        self.owner = owner
        super.init()
    }

    func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] { [tab] }
    func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? { tab }
    func windowType(for context: WKWebExtensionContext) -> WKWebExtension.WindowType { .popup }
    func windowState(for context: WKWebExtensionContext) -> WKWebExtension.WindowState { .normal }
    func isPrivate(for context: WKWebExtensionContext) -> Bool { false }
    func frame(for context: WKWebExtensionContext) -> CGRect { CGRect(origin: .zero, size: size) }
    func screenFrame(for context: WKWebExtensionContext) -> CGRect { owner?.window?.screen?.frame ?? .zero }

    func focus(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        completionHandler(nil)
    }

    func close(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        owner?.closePopout()
        completionHandler(nil)
    }
}

extension BrowserWindow {
    /// The page the extension asked a window for, in a panel; `size` is what
    /// it asked for, kept within the window.
    func openPopout(urls: [URL], size asked: CGSize) -> PopoutWindow {
        endPopout()
        let room = window?.contentView?.bounds.size ?? CGSize(width: 900, height: 700)
        let size = CGSize(width: min(max(asked.width > 0 ? asked.width : 380, 280), min(760, room.width - 40)),
                          height: min(max(asked.height > 0 ? asked.height : 600, 240), min(900, room.height - 60)))
        let tab = Tab(privately: false, opening: urls.first)
        tab.host = self
        let popout = PopoutWindow(tab: tab, size: size, owner: self)
        tab.popout = popout
        tab.makeWebView().isHidden = false
        shell.popout = popout
        Extensions.shared.controller.didOpenWindow(popout)
        Extensions.shared.opened(tab)
        if let url = urls.first { tab.load(url) }
        showPanel(.popout)
        return popout
    }

    /// Puts it away, wherever the request came from.
    func closePopout() {
        if shell.panel == .popout { closePanel() } else { endPopout() }
    }

    /// The popup's page and window let go, the extension told.
    func endPopout() {
        guard let popout = shell.popout else { return }
        shell.popout = nil
        Extensions.shared.closed(popout.tab, windowClosing: true)
        Extensions.shared.controller.didCloseWindow(popout)
        popout.tab.popout = nil
        popout.tab.discard()
    }
}

/// The popup's page, as a view for the panel.
struct PopoutHolder: NSViewRepresentable {
    let web: WKWebView

    func makeNSView(context: Context) -> NSView { web }
    func updateNSView(_ view: NSView, context: Context) {}
}
