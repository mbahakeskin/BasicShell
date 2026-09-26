import AppKit
import WebKit

// A video that keeps playing in a small window above everything, other apps
// included (View › Picture in Picture, ⇧⌘P).
//
// WebKit's own picture-in-picture is unavailable to this app: its item in the
// video menu stays disabled, and a page script can't ask for it without a
// real click. So, as Search does, the engine isn't asked. The page itself
// moves: everything but the video is hidden, the video fills the page, and
// the web view is lifted into a floating panel. It is the same page, so the
// video never stops; closing the panel puts it back in its tab.
final class Float: NSObject, NSWindowDelegate {
    static let shared = Float()

    private var panel: NSPanel?
    private(set) weak var tab: Tab?
    private weak var home: BrowserWindow?

    /// Marks the video and hides the rest. Answers with the video's size, or
    /// nothing when the page has no video.
    private static let lift = """
    (() => {
      const videos = [...document.querySelectorAll('video')];
      if (!videos.length) return null;
      const video = videos.find(v => !v.paused) || videos.sort((a, b) => b.clientWidth * b.clientHeight - a.clientWidth * a.clientHeight)[0];
      video.setAttribute('data-basicshell-float', '');
      const style = document.createElement('style');
      style.id = 'basicshell-float';
      style.textContent = `
        html, body { background: #000 !important; overflow: hidden !important; }
        body * { visibility: hidden !important; }
        video[data-basicshell-float] {
          visibility: visible !important; position: fixed !important; inset: 0 !important;
          width: 100vw !important; height: 100vh !important; max-width: none !important; max-height: none !important;
          object-fit: contain !important; z-index: 2147483647 !important; background: #000 !important; transform: none !important;
        }`;
      document.documentElement.appendChild(style);
      return [video.videoWidth || 16, video.videoHeight || 9];
    })()
    """

    private static let drop = """
    (() => {
      document.getElementById('basicshell-float')?.remove();
      document.querySelector('video[data-basicshell-float]')?.removeAttribute('data-basicshell-float');
    })()
    """

    func isFloating(_ tab: Tab) -> Bool { self.tab === tab }

    /// Lifts the tab's video out, or puts it back if it is already out.
    func toggle(_ tab: Tab, in window: BrowserWindow) {
        if self.tab === tab { return land() }
        land()
        guard let web = tab.webView else { return }
        web.evaluateJavaScript(Float.lift) { [weak self] result, _ in
            guard let self, let size = result as? [Double], size.count == 2 else {
                window.say("No video on this page")
                return
            }
            self.open(web, tab: tab, window: window, aspect: NSSize(width: size[0], height: size[1]))
        }
    }

    private func open(_ web: WKWebView, tab: Tab, window: BrowserWindow, aspect: NSSize) {
        let width: CGFloat = 420
        let height = (width * aspect.height / max(aspect.width, 1)).rounded()
        let screen = window.window?.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let frame = NSRect(x: screen.maxX - width - 20, y: screen.minY + 20, width: width, height: height)
        let panel = NSPanel(contentRect: frame, styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = tab.name
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.contentAspectRatio = aspect
        panel.delegate = self
        web.removeFromSuperview()
        web.frame = panel.contentView?.bounds ?? .zero
        web.autoresizingMask = [.width, .height]
        panel.contentView?.addSubview(web)
        panel.orderFrontRegardless()
        // WebKit leaves the video's picture where it was drawn in the old
        // window until the view changes size; a nudge puts it in place.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak panel] in
            guard let panel else { return }
            var frame = panel.frame
            frame.size.width += 1
            panel.setFrame(frame, display: true)
            frame.size.width -= 1
            panel.setFrame(frame, display: true)
        }
        self.panel = panel
        self.tab = tab
        self.home = window
        window.floated(tab)
    }

    /// Puts the video back in its tab.
    func land() {
        guard let panel, let tab else { return }
        let window = home
        self.panel = nil
        self.tab = nil
        panel.delegate = nil
        tab.webView?.removeFromSuperview()
        tab.webView?.evaluateJavaScript(Float.drop) { _, _ in }
        panel.close()
        window?.landed(tab)
    }

    func windowWillClose(_ notification: Notification) {
        land()
    }
}
