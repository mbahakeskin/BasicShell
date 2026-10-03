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
          if (loaded.has(track) || !track.cues || track.label === "BasicShell Captions") continue;
          // Emptied, not removed: YouTube keeps one cue and rewrites it.
          for (const cue of [...track.cues]) { try { if ("text" in cue) cue.text = ""; } catch (x) {} }
        }
      };
      addEventListener("loadstart", clear, true);
      addEventListener("emptied", clear, true);
      // YouTube's own captions in Picture in Picture can't be counted on:
      // its one line, rewritten from its script, froze when the page was
      // out of sight, and for some page loads was never written. Its
      // captions come down whole, with their times, when they are turned on
      // (/api/timedtext); a copy is kept as they arrive, and shown in
      // Picture in Picture from a track of BasicShell's (below).
      if (/(^|\\.)youtube\\.com$/.test(location.hostname)) {
        const captions = new Map();
        const take = (address, text) => {
          try {
            const url = new URL(address, location.href);
            if (!url.pathname.endsWith("/api/timedtext") || !text) return;
            const data = JSON.parse(text);
            const cues = [];
            for (const event of data.events || []) {
              if (!event.segs || event.aAppend) continue;
              const line = event.segs.map((s) => s.utf8 || "").join("").trim();
              if (!line) continue;
              const start = (event.tStartMs || 0) / 1000;
              cues.push([start, start + (event.dDurationMs || 2000) / 1000, line]);
            }
            if (cues.length) {
              captions.set(url.searchParams.get("v"), { cues, version: Date.now() });
              try { webkit.messageHandlers.basicShellPiP.postMessage({ tracks: `captions kept: ${cues.length} lines (${url.searchParams.get("lang") || "?"}${url.searchParams.get("tlang") ? " → " + url.searchParams.get("tlang") : ""})` }); } catch (x) {}
            }
          } catch (x) {}
        };
        const fetching = window.fetch;
        window.fetch = function (input, init) {
          const answer = fetching.apply(this, arguments);
          try {
            const address = typeof input === "string" ? input : input && input.url;
            if (address && String(address).includes("/api/timedtext")) answer.then((r) => r.clone().text()).then((t) => take(address, t)).catch(() => {});
          } catch (x) {}
          return answer;
        };
        const opening = XMLHttpRequest.prototype.open, sending = XMLHttpRequest.prototype.send;
        XMLHttpRequest.prototype.open = function (method, address) { this.__basicShellAddress = address; return opening.apply(this, arguments); };
        XMLHttpRequest.prototype.send = function () {
          const address = this.__basicShellAddress;
          if (address && String(address).includes("/api/timedtext")) {
            this.addEventListener("load", () => {
              try { take(address, this.responseType === "" || this.responseType === "text" ? this.responseText : JSON.stringify(this.response)); } catch (x) {}
            });
          }
          return sending.apply(this, arguments);
        };
        // In Picture in Picture, with the caption button on and the video's
        // captions kept, BasicShell's track is the one shown and YouTube's is
        // kept hidden (YouTube turns it on again; a hidden one it stays). Its
        // lines carry their times, so WebKit shows each in step with the
        // video, page script or not: YouTube's one line, rewritten from its
        // script, froze when the page was out of sight and at times was
        // never written at all for a page load.
        const ours = new WeakMap();
        const videoId = () => {
          try { const player = document.getElementById("movie_player"); const id = player && player.getVideoData && player.getVideoData().video_id; if (id) return id; } catch (x) {}
          return new URL(location.href).searchParams.get("v");
        };
        const current = (video) => {
          if (document.pictureInPictureElement !== video) return null;
          const button = document.querySelector(".ytp-subtitles-button");
          if (button && button.getAttribute("aria-pressed") !== "true") return null;
          return captions.get(videoId()) || null;
        };
        const modes = Object.getOwnPropertyDescriptor(TextTrack.prototype, "mode");
        Object.defineProperty(TextTrack.prototype, "mode", {
          configurable: true, enumerable: modes.enumerable, get: modes.get,
          set: function (value) {
            if (this.label === "YouTube Captions") {
              // What YouTube wants, given back when Picture in Picture ends.
              this.__basicShellWanted = value;
              const video = document.pictureInPictureElement;
              if (value === "showing" && video && [...video.textTracks].includes(this) && current(video)) value = "hidden";
            }
            return modes.set.call(this, value);
          },
        });
        let bridging = null;
        const bridge = () => {
          const video = document.pictureInPictureElement;
          if (!video || !video.textTracks) { clearInterval(bridging); bridging = null; return; }
          const found = current(video);
          const state = ours.get(video) || { track: null, version: 0 };
          ours.set(video, state);
          if (!found) { if (state.track) modes.set.call(state.track, "disabled"); return; }
          if (!state.track) state.track = video.addTextTrack("captions", "BasicShell Captions", document.documentElement.lang || "");
          if (state.version !== found.version) {
            modes.set.call(state.track, "hidden");
            for (const cue of [...(state.track.cues || [])]) { try { state.track.removeCue(cue); } catch (x) {} }
            for (const [start, end, line] of found.cues) { try { state.track.addCue(new VTTCue(start, end, line)); } catch (x) {} }
            state.version = found.version;
          }
          for (const track of video.textTracks) {
            if (track.label !== "YouTube Captions" || track.mode !== "showing") continue;
            if (track.__basicShellWanted === undefined) track.__basicShellWanted = "showing";
            modes.set.call(track, "hidden");
          }
          if (state.track.mode !== "showing") modes.set.call(state.track, "showing");
        };
        addEventListener("enterpictureinpicture", () => { bridge(); if (!bridging) bridging = setInterval(bridge, 250); }, true);
        // Out of Picture in Picture: YouTube's tracks as YouTube left them.
        // Kept hidden, YouTube took its captions for on and drew none on the
        // page, until the caption button was pressed twice.
        addEventListener("leavepictureinpicture", (e) => {
          const state = ours.get(e.target);
          if (state && state.track) modes.set.call(state.track, "disabled");
          for (const track of e.target.textTracks || []) {
            if (track.label !== "YouTube Captions" || track.__basicShellWanted === undefined) continue;
            if (track.mode !== track.__basicShellWanted) modes.set.call(track, track.__basicShellWanted);
          }
        }, true);
        addEventListener("loadstart", (e) => { const state = ours.get(e.target); if (state) state.version = 0; }, true);
      }
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
    /// `slide`: the window went to another desktop, -1 if the desktop now
    /// shown is to the left (so the window's went off to the right), 1 to
    /// the right. The video is moved first, out of sight, by a screen's
    /// width the way its desktop went, so the system brings it into its
    /// floating window from that side, as if it had come along; 0 leaves it
    /// where it is.
    static func follow(_ tab: Tab, slide: Int = 0) {
        let key = ObjectIdentifier(tab)
        guard !isActive(tab), !automatic.contains(key), !tab.isFrozen, let web = tab.webView else { return }
        // Not while the page is in (or has just left) its own full screen:
        // asked then, the video element was left "processing" a request for
        // good and refused every one after it, until the page was reloaded;
        // and leaving full screen stuck halfway. Asked again once it settles,
        // if the video is still out of sight.
        guard web.fullscreenState == .notInFullscreen else { return }
        let settle = 0.5 - Date().timeIntervalSince(tab.fullscreenChanged)
        if settle > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + settle) {
                guard let window = tab.host as? BrowserWindow, window.outOfSight(tab) else { return }
                follow(tab, slide: slide)
            }
            return
        }
        enter(tab, playingOnly: true, automatic: true, slide: slide)
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
    // The window went to another desktop: the video, unseen, is moved a
    // screen's width the way the desktop went, where the system's animation
    // starts from. Put back once it is in.
    if (slide) {
      const style = video.style, kept = [style.transform, style.transition];
      style.transition = "none";
      style.transform = `translateX(${-slide * screen.width}px)`;
      let restored = false;
      const restore = () => { if (restored) return; restored = true; [style.transform, style.transition] = kept; };
      video.addEventListener("enterpictureinpicture", () => setTimeout(restore, 100), { once: true });
      setTimeout(restore, 2500);
    }
    try {
      await video.requestPictureInPicture();
      return "in";
    } catch (e) {
      return "refused: " + (e && e.name) + ": " + (e && e.message);
    }
    """

    private static func enter(_ tab: Tab, playingOnly: Bool, automatic byItself: Bool, slide: Int = 0) {
        guard let web = tab.webView else { return }
        let key = ObjectIdentifier(tab)
        if byItself { automatic.insert(key) }
        call(web, request, ["playingOnly": playingOnly, "slide": slide]) { result, error in
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
