import AppKit
import WebKit

// Picture in Picture: WebKit's own, in the system's floating window, with
// the rest of the page staying where it is (View › Picture in Picture, ⇧⌘P).
//
// WebKit has it off for apps unless a private preference turns it on
// (`_setAllowsPictureInPictureMediaPlayback:`), and a page may ask for it
// only in answer to a click, so BasicShell asks the way a click would
// (`_callAsyncJavaScript:…withUserGesture:`, the route WebKit's own
// extension code uses).
//
// It also comes by itself, as in Arc: a video playing in a tab you leave
// (another tab, another desktop, the window covered or minimized) goes into
// Picture in Picture, and comes back when you do. Only one it moved by
// itself; one you moved stays until you bring it back.
enum PiP {
    /// Tabs whose video BasicShell moved by itself, to bring back on return.
    private static var automatic: Set<ObjectIdentifier> = []

    /// Turns WebKit's Picture in Picture on for a new web view's
    /// configuration, and has its pages say when a video goes in and out.
    static func allow(in config: WKWebViewConfiguration) {
        let setter = NSSelectorFromString("_setAllowsPictureInPictureMediaPlayback:")
        if config.preferences.responds(to: setter), let method = class_getMethodImplementation(WKPreferences.self, setter) {
            typealias SetBool = @convention(c) (AnyObject, Selector, Bool) -> Void
            unsafeBitCast(method, to: SetBool.self)(config.preferences, setter, true)
        }
        config.userContentController.addUserScript(watch)
        config.userContentController.add(Watcher.shared, contentWorld: .page, name: "basicShellPiP")
    }

    /// Whether this tab's video is in Picture in Picture now, as its page
    /// said. (WebKit's own `_isPictureInPictureActive` answers no even then.)
    static func isActive(_ tab: Tab) -> Bool { tab.inPictureInPicture }

    /// The page's own events, however the video went in or came out (the
    /// window's buttons included).
    private static let watch = WKUserScript(source: """
    (() => {
      const say = (inside) => { try { webkit.messageHandlers.basicShellPiP.postMessage(inside); } catch (e) {} };
      addEventListener("enterpictureinpicture", () => say(true), true);
      addEventListener("leavepictureinpicture", () => say(false), true);
    })();
    """, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page)

    private final class Watcher: NSObject, WKScriptMessageHandler {
        static let shared = Watcher()
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let tab = message.webView?.navigationDelegate as? Tab, let inside = message.body as? Bool else { return }
            tab.inPictureInPicture = inside
            if !inside { PiP.automatic.remove(ObjectIdentifier(tab)) }
        }
    }

    /// Whether it is there, or on its way there by itself.
    static func holds(_ tab: Tab) -> Bool { automatic.contains(ObjectIdentifier(tab)) || isActive(tab) }

    /// ⇧⌘P: the page's video into Picture in Picture, or back.
    static func toggle(_ tab: Tab) {
        if isActive(tab) {
            automatic.remove(ObjectIdentifier(tab))
            leave(tab)
        } else {
            enter(tab, playingOnly: false, automatic: false)
        }
    }

    /// The video playing in a tab going out of sight, into Picture in Picture.
    static func follow(_ tab: Tab) {
        guard !isActive(tab), !tab.isFrozen, tab.webView != nil else { return }
        enter(tab, playingOnly: true, automatic: true)
    }

    /// The tab is in sight again: a video moved by itself comes back.
    static func bringBack(_ tab: Tab) {
        guard automatic.remove(ObjectIdentifier(tab)) != nil else { return }
        leave(tab)
    }

    static func forget(_ tab: Tab) { automatic.remove(ObjectIdentifier(tab)) }

    // MARK: -

    /// The video playing, else (when asked by hand) the largest one ready.
    private static let request = """
    const videos = [...document.querySelectorAll("video")].filter((v) => v.readyState > 0 && !v.disablePictureInPicture);
    const playing = videos.find((v) => !v.paused && !v.ended);
    const video = playing || (playingOnly ? null : videos.sort((a, b) => b.clientWidth * b.clientHeight - a.clientWidth * a.clientHeight)[0]);
    if (!video) return "no video";
    if (document.pictureInPictureElement === video) return "already";
    try {
      await video.requestPictureInPicture();
      return "in";
    } catch (e) {
      return "refused: " + (e && e.name) + ": " + (e && e.message);
    }
    """

    private static func enter(_ tab: Tab, playingOnly: Bool, automatic byItself: Bool) {
        guard let web = tab.webView else { return }
        let key = ObjectIdentifier(tab)
        if byItself { automatic.insert(key) }
        call(web, request, ["playingOnly": playingOnly]) { result, error in
            let answer = (result as? String) ?? error?.localizedDescription ?? "?"
            Debug.log("pip", "\(tab.name): \(byItself ? "by itself" : "asked"): \(answer)")
            if answer != "in" && answer != "already" {
                automatic.remove(key)
                if !byItself { (tab.host as? BrowserWindow)?.say("No video to put in Picture in Picture") }
            }
        }
    }

    private static func leave(_ tab: Tab) {
        guard let web = tab.webView else { return }
        call(web, "if (document.pictureInPictureElement) await document.exitPictureInPicture(); return \"out\";", [:]) { result, error in
            Debug.log("pip", "\(tab.name): back: \((result as? String) ?? error?.localizedDescription ?? "?")")
        }
    }

    /// Runs a function body on the page as though the person had clicked,
    /// in a script world of its own: the page's scripts (and ones a blocker
    /// adds to it) can't change what it calls there. Run in the page's own
    /// world it sometimes threw on YouTube, or answered with something that
    /// wasn't a string.
    private static func call(_ web: WKWebView, _ body: String, _ arguments: [String: Any], _ done: @escaping (Any?, (any Error)?) -> Void) {
        let selector = NSSelectorFromString("_callAsyncJavaScript:arguments:inFrame:inContentWorld:withUserGesture:completionHandler:")
        guard web.responds(to: selector), let method = class_getMethodImplementation(WKWebView.self, selector) else {
            return done(nil, nil)
        }
        typealias Call = @convention(c) (AnyObject, Selector, AnyObject?, AnyObject?, AnyObject?, AnyObject?, Bool, AnyObject?) -> Void
        let completion: @convention(block) (AnyObject?, NSError?) -> Void = { result, error in
            MainActor.assumeIsolated { done(result, error) }
        }
        unsafeBitCast(method, to: Call.self)(web, selector, body as NSString, arguments as NSDictionary, nil, WKContentWorld.defaultClient, true, completion as AnyObject)
    }
}
