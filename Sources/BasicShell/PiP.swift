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
    fileprivate static var automatic: Set<ObjectIdentifier> = []

    /// Turns WebKit's Picture in Picture on for a new web view's
    /// configuration, and has its pages say when a video goes in and out.
    static func allow(in config: WKWebViewConfiguration) {
        let setter = NSSelectorFromString("_setAllowsPictureInPictureMediaPlayback:")
        if config.preferences.responds(to: setter), let method = class_getMethodImplementation(WKPreferences.self, setter) {
            typealias SetBool = @convention(c) (AnyObject, Selector, Bool) -> Void
            unsafeBitCast(method, to: SetBool.self)(config.preferences, setter, true)
        }
        config.userContentController.addUserScript(watch)
        if Debug.enabled { config.userContentController.addUserScript(captionReport) }
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
      // Whether the video goes on: its window's button back to the page
      // leaves it playing; closing the window pauses it.
      addEventListener("leavepictureinpicture", (e) => { try { webkit.messageHandlers.basicShellPiP.postMessage({ inside: false, playing: !!(e.target && !e.target.paused && !e.target.ended) }); } catch (x) {} }, true);
      // A site may swap the video's source while it is in Picture in
      // Picture (YouTube going to the next video), which ends it without
      // that event; so whenever a video starts loading, where things stand.
      for (const name of ["loadstart", "emptied", "loadedmetadata", "playing"]) addEventListener(name, () => say(!!document.pictureInPictureElement), true);
      // A site that writes captions into a track from its script (YouTube)
      // keeps the same track for the next video and leaves the last line
      // of the old one in it; Picture in Picture shows that line until a
      // new one comes. So when a video's source changes, lines in tracks
      // the page's script made (not ones a <track> element loads) go.
      const clear = (e) => {
        const video = e.target;
        if (!(video instanceof HTMLMediaElement) || !video.textTracks) return;
        const loaded = new Set([...video.querySelectorAll("track")].map((t) => t.track));
        for (const track of video.textTracks) {
          if (loaded.has(track) || !track.cues) continue;
          // Emptied, not removed: YouTube keeps one cue and rewrites it.
          for (const cue of [...track.cues]) { try { if ("text" in cue) cue.text = ""; } catch (x) {} }
        }
      };
      addEventListener("loadstart", clear, true);
      addEventListener("emptied", clear, true);
      // YouTube makes its caption track twice as a page loads, turning the
      // first off; now and then it goes on writing lines into that first
      // one, which Picture in Picture doesn't show, and stays blank until
      // the video starts again. While a video is in Picture in Picture, a
      // line written into a track the page's script made and turned off
      // goes to the one of the same name that is on.
      try {
        const add = TextTrack.prototype.addCue, remove = TextTrack.prototype.removeCue;
        const twin = (track) => {
          const video = document.pictureInPictureElement;
          if (track.mode !== "disabled" || !video || !video.textTracks || ![...video.textTracks].includes(track)) return null;
          return [...video.textTracks].find((t) => t !== track && t.mode === "showing" && t.label === track.label && t.kind === track.kind) || null;
        };
        TextTrack.prototype.addCue = function (cue) {
          const other = twin(this);
          if (other) { self.__basicShellMoved = (self.__basicShellMoved || 0) + 1; return add.call(other, cue); }
          return add.call(this, cue);
        };
        TextTrack.prototype.removeCue = function (cue) {
          if (cue && cue.track && cue.track !== this && twin(this) === cue.track) return remove.call(cue.track, cue);
          return remove.call(this, cue);
        };
      } catch (x) {}
    })();
    """, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page)

    /// With the debug log on: every few seconds while a video is in
    /// Picture in Picture, what the caption tracks the page's script made
    /// hold, to tell a site that wrote no line from WebKit not showing one.
    private static let captionReport = WKUserScript(source: """
    (() => {
      const report = (video, why) => {
        const loaded = new Set([...video.querySelectorAll("track")].map((t) => t.track));
        const tracks = [...(video.textTracks || [])].filter((t) => !loaded.has(t));
        const line = tracks.map((t) => `${t.kind} "${t.label}" ${t.mode} cues ${t.cues ? t.cues.length : "-"} showing ${t.activeCues ? t.activeCues.length : "-"}`).join("; ");
        const cc = document.querySelector(".ytp-subtitles-button");
        const button = cc ? `, CC button ${cc.getAttribute("aria-pressed") === "true" ? "on" : "off"}` : "";
        try { webkit.messageHandlers.basicShellPiP.postMessage({ tracks: `${why} at ${Math.round(video.currentTime)} s${button}${video.paused ? " paused" : ""}${self.__basicShellMoved ? `, ${self.__basicShellMoved} lines moved` : ""}: ${line || "none"}` }); } catch (x) {}
      };
      addEventListener("enterpictureinpicture", (e) => report(e.target, "in"), true);
      setInterval(() => { const v = document.pictureInPictureElement; if (v) report(v, "captions"); }, 5000);
    })();
    """, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page)

    private final class Watcher: NSObject, WKScriptMessageHandler {
        static let shared = Watcher()
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let web = message.webView, let tab = web.navigationDelegate as? Tab else { return }
            let body = message.body as? [String: Any]
            if let tracks = body?["tracks"] as? String { return Debug.log("pip", "\(tab.name): tracks \(tracks)") }
            guard let inside = (message.body as? Bool) ?? (body?["inside"] as? Bool) else { return }
            let was = tab.inPictureInPicture
            tab.inPictureInPicture = inside
            PiP.keepAwake(web, inside)
            guard !inside else { return }
            let key = ObjectIdentifier(tab)
            PiP.automatic.remove(key)
            let ours = PiP.leaving.remove(key) != nil
            guard was else { return }
            if !ours, body?["playing"] as? Bool == true {
                // Its window's button back to the page: to the page, as in
                // Arc, on whatever desktop it is.
                (tab.host as? BrowserWindow)?.show(tab)
            } else {
                (tab.host as? BrowserWindow)?.leftPictureInPicture(tab)
            }
        }
    }

    /// A page whose video is in Picture in Picture stays awake although it
    /// is out of sight: YouTube writes the captions shown there from the
    /// page's script, which WebKit slows to a stop on a page it thinks
    /// hidden, and they froze (in Safari too) while the video went on. So
    /// the tab's view stays in the window, behind the one shown (see
    /// BrowserWindow.select), and WebKit's private
    /// `_setWindowOcclusionDetectionEnabled:` keeps a window on another
    /// desktop, or covered, from counting as hidden for it.
    static func keepAwake(_ web: WKWebView, _ awake: Bool) {
        let setter = NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")
        guard web.responds(to: setter), let method = class_getMethodImplementation(WKWebView.self, setter) else { return }
        typealias SetBool = @convention(c) (AnyObject, Selector, Bool) -> Void
        unsafeBitCast(method, to: SetBool.self)(web, setter, !awake)
    }

    /// Whether it is there, or on its way there by itself.
    static func holds(_ tab: Tab) -> Bool { automatic.contains(ObjectIdentifier(tab)) || isActive(tab) }

    /// ⇧⌘P: the page's video into Picture in Picture, or back, as the page
    /// says it is now (what BasicShell last heard can be out of date).
    static func toggle(_ tab: Tab) {
        guard let web = tab.webView else { return }
        call(web, "return !!document.pictureInPictureElement;", [:]) { result, _ in
            if (result as? Bool) == true {
                automatic.remove(ObjectIdentifier(tab))
                leave(tab)
            } else {
                tab.inPictureInPicture = false
                enter(tab, playingOnly: false, automatic: false)
            }
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
            if answer == "in" || answer == "already" { tab.inPictureInPicture = true }
            if answer != "in" && answer != "already" {
                automatic.remove(key)
                if !byItself { (tab.host as? BrowserWindow)?.say("No video to put in Picture in Picture") }
            }
        }
    }

    /// Tabs whose video BasicShell is bringing back itself.
    fileprivate static var leaving: Set<ObjectIdentifier> = []

    private static func leave(_ tab: Tab) {
        guard let web = tab.webView else { return }
        leaving.insert(ObjectIdentifier(tab))
        call(web, "if (document.pictureInPictureElement) await document.exitPictureInPicture(); return \"out\";", [:]) { result, error in
            let answer = (result as? String) ?? error?.localizedDescription ?? "?"
            Debug.log("pip", "\(tab.name): back: \(answer)")
            if answer == "out" { tab.inPictureInPicture = false }
            // Its event, if any, came before this answer.
            leaving.remove(ObjectIdentifier(tab))
        }
    }

    /// Runs a function body in the page as though the person had clicked.
    /// In the page's own world, not one of its own: YouTube puts its
    /// captions into Picture in Picture from there, and run apart, they
    /// didn't show.
    private static func call(_ web: WKWebView, _ body: String, _ arguments: [String: Any], _ done: @escaping (Any?, (any Error)?) -> Void) {
        let selector = NSSelectorFromString("_callAsyncJavaScript:arguments:inFrame:inContentWorld:withUserGesture:completionHandler:")
        guard web.responds(to: selector), let method = class_getMethodImplementation(WKWebView.self, selector) else {
            return done(nil, nil)
        }
        typealias Call = @convention(c) (AnyObject, Selector, AnyObject?, AnyObject?, AnyObject?, AnyObject?, Bool, AnyObject?) -> Void
        let completion: @convention(block) (AnyObject?, NSError?) -> Void = { result, error in
            MainActor.assumeIsolated { done(result, error) }
        }
        unsafeBitCast(method, to: Call.self)(web, selector, body as NSString, arguments as NSDictionary, nil, WKContentWorld.page, true, completion as AnyObject)
    }
}
