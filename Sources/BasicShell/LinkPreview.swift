import AppKit
import WebKit

// ⌘ held over a link for a moment shows the page it goes to, small, beside
// the link, as Safari does. It lasts while ⌘ is held and the pointer stays on
// the link; it takes no clicks, so ⌘-click still opens the link in a tab
// behind this one.
//
// A script in a world of BasicShell's own (the page can't see or fake it)
// watches the pointer and ⌘ and says which link and where it is; the preview
// is a second, separate web view in a window beside the page: no cookies, no
// extensions, no sound, no windows, no permissions. Off with
// `defaults write … preview.links -bool false`.
@MainActor
final class LinkPreview: NSObject, WKScriptMessageHandler {
    static let shared = LinkPreview()
    private static let world = WKContentWorld.world(name: "BasicShellPreview")
    private static let name = "basicShellPreview"
    private static let size = NSSize(width: 520, height: 340)
    private static let zoom: CGFloat = 0.5

    private var panel: NSPanel?
    private var web: WKWebView?
    private var monitor: Any?
    private var lasts: Task<Void, Never>?

    private static var enabled: Bool { UserDefaults.standard.object(forKey: "preview.links") as? Bool ?? true }

    static func attach(to config: WKWebViewConfiguration) {
        guard enabled else { return }
        config.userContentController.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: world))
        config.userContentController.add(shared, contentWorld: world, name: name)
    }

    private static let script = """
    (() => {
      let link = null, timer = null, shown = false, meta = false;
      const post = m => { try { webkit.messageHandlers.\(name).postMessage(m); } catch (e) {} };
      const hide = () => { clearTimeout(timer); timer = null; if (shown) { shown = false; post({ close: true }); } };
      const arm = () => {
        clearTimeout(timer);
        if (!link || !meta || shown) return;
        timer = setTimeout(() => {
          if (!link || !meta) return;
          const r = link.getBoundingClientRect();
          shown = true;
          post({ href: link.href, x: r.left, y: r.top, w: r.width, h: r.height });
        }, 600);
      };
      const seen = e => {
        meta = e.metaKey;
        const a = e.target && e.target.closest ? e.target.closest('a[href]') : null;
        const next = a && /^https?:/.test(a.href) ? a : null;
        if (next !== link) { hide(); link = next; }
        if (meta) arm(); else hide();
      };
      addEventListener('mousemove', seen, true);
      addEventListener('keydown', e => { if (e.key === 'Meta') { meta = true; arm(); } }, true);
      addEventListener('keyup', e => { if (e.key === 'Meta') { meta = false; hide(); } }, true);
      for (const type of ['click', 'wheel', 'scroll', 'blur', 'mouseleave']) addEventListener(type, hide, true);
    })();
    """

    nonisolated func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        MainActor.assumeIsolated {
            if body["close"] != nil { close(); return }
            guard let href = body["href"] as? String, let url = URL(string: href), ["http", "https"].contains(url.scheme ?? ""),
                  let page = message.webView, page.window?.isKeyWindow == true,
                  let x = body["x"] as? Double, let y = body["y"] as? Double, let w = body["w"] as? Double, let h = body["h"] as? Double
            else { return }
            show(url, over: page, link: CGRect(x: x, y: y, width: w, height: h))
        }
    }

    private func show(_ url: URL, over page: WKWebView, link: CGRect) {
        close()
        guard let window = page.window else { return }
        let zoom = page.pageZoom
        let inView = NSRect(x: link.minX * zoom, y: link.minY * zoom, width: link.width * zoom, height: link.height * zoom)
        let onScreen = window.convertToScreen(page.convert(inView, to: nil))
        let visible = (window.screen ?? NSScreen.main)?.visibleFrame ?? .zero
        let size = Self.size
        var origin = NSPoint(x: min(max(onScreen.minX, visible.minX + 8), visible.maxX - size.width - 8), y: onScreen.minY - 10 - size.height)
        if origin.y < visible.minY + 8 { origin.y = min(onScreen.maxY + 10, visible.maxY - size.height - 8) }

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.applicationNameForUserAgent = Web.userAgentName
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        let preview = WKWebView(frame: NSRect(origin: .zero, size: size), configuration: configuration)
        preview.pageZoom = Self.zoom
        preview.allowsBackForwardNavigationGestures = false
        preview.uiDelegate = Quiet.shared
        Tab.drawsBackground(preview, false)
        preview.load(URLRequest(url: url))

        let holder = NSView(frame: NSRect(origin: .zero, size: size))
        holder.wantsLayer = true
        holder.layer?.cornerRadius = 12
        holder.layer?.masksToBounds = true
        holder.layer?.borderWidth = 1
        holder.layer?.borderColor = NSColor.separatorColor.cgColor
        holder.layer?.backgroundColor = NSColor.white.cgColor
        holder.addSubview(preview)

        let made = NSPanel(contentRect: NSRect(origin: origin, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        made.isOpaque = false
        made.backgroundColor = .clear
        made.hasShadow = true
        made.ignoresMouseEvents = true
        made.isReleasedWhenClosed = false
        made.contentView = holder
        window.addChildWindow(made, ordered: .above)
        panel = made
        web = preview
        // ⌘ let go anywhere, or ten seconds of it: gone.
        monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            if !event.modifierFlags.contains(.command) { MainActor.assumeIsolated { self?.close() } }
            return event
        }
        lasts = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            if !Task.isCancelled { self?.close() }
        }
    }

    func close() {
        lasts?.cancel()
        lasts = nil
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        web?.stopLoading()
        web = nil
        if let panel {
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
        }
        panel = nil
    }

    /// What the preview's page may do: nothing that asks.
    private final class Quiet: NSObject, WKUIDelegate {
        static let shared = Quiet()
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? { nil }
        func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType, decisionHandler: @escaping @MainActor (WKPermissionDecision) -> Void) { decisionHandler(.deny) }
        func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor () -> Void) { completionHandler() }
        func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor (Bool) -> Void) { completionHandler(false) }
        func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor (String?) -> Void) { completionHandler(nil) }
    }
}
