#if AGENT
import AppKit
import Observation
import WebKit

// How the agent's tools know that what a click or a key started is over (see Call.effectsOver).
//
// Three ways, chosen in Settings › Agents, or by the agent with `settle`:
//   tracker   (the default) a small script in the page's own world, wrapping its timers, frames and requests (AgentPage.tracker);
//   inspector nothing in the page: a hidden Web Inspector is connected to it, and what WebKit's own instruments say (timers
//             set and fired, frames asked for, requests, layout and paint) is read from the inspector's page, which is
//             BasicShell's own. It costs a web process for the inspector's page, about 130 MB for each tab worked in,
//             and 0.2 s when a tab is first worked in; the connection is closed a few seconds after the last action and
//             WebKit gives the process back within a minute;
//   window    the oldest: 150 ms without a change.
//
// The inspector's frontend is a page of WebKit's (`inspector-resource:///Main.html`) with `WI`, its model, in it. A hook on
// the connection its targets talk through (`dispatch`) takes the Timeline and Network messages before the frontend does,
// keeps what the decision needs (pending timers up to the cap, frames, requests) and tells BasicShell only when it has
// decided; the frontend itself is left recording nothing. The debugger is switched off, so that a page's own `debugger;`
// statement stops nothing. The page can tell it is being inspected, as it can with Safari's inspector open.

enum QuietMode: String, CaseIterable, Identifiable {
    case tracker, inspector, window
    var id: String { rawValue }

    var title: String {
        switch self {
        case .tracker: "A script in the page"
        case .inspector: "The Web Inspector"
        case .window: "A pause of 150 ms"
        }
    }
}

@Observable
final class AgentQuiet {
    static let shared = AgentQuiet()
    static let key = "agent.quietMode"

    /// What is in use: the person's choice, or an agent's, which lasts until BasicShell quits.
    private(set) var mode: QuietMode
    /// An agent chose it, and it is not kept.
    private(set) var byAgent = false

    private init() {
        let defaults = UserDefaults.standard
        if let raw = defaults.string(forKey: AgentQuiet.key), let stored = QuietMode(rawValue: raw) {
            mode = stored
        } else {
            // Before this setting there was a switch for the script alone.
            mode = defaults.object(forKey: "agent.quietTracker") as? Bool == false ? .window : .tracker
        }
    }

    /// The person's choice: kept.
    func choose(_ mode: QuietMode) {
        self.mode = mode
        byAgent = false
        UserDefaults.standard.set(mode.rawValue, forKey: AgentQuiet.key)
    }

    /// An agent's: until BasicShell quits, or the person chooses.
    func set(byAgent mode: QuietMode) {
        self.mode = mode
        byAgent = true
    }
}

/// One tab's connected inspector.
@MainActor
final class InspectorWatch: NSObject, WKScriptMessageHandler {
    private static var watches: [UUID: InspectorWatch] = [:]

    /// The tab's, if it has one for the page it shows now.
    static func existing(_ tab: Tab) -> InspectorWatch? {
        guard let watch = watches[tab.id] else { return nil }
        guard watch.web === tab.webView else {
            watch.detach()
            return nil
        }
        return watch
    }

    /// Connects an inspector to the tab's page, if there isn't one, and says it is ready. Nil where it can't be done
    /// (the person has the inspector open, WebKit has none) and the script is used instead.
    static func attach(to tab: Tab, _ web: WKWebView) async -> InspectorWatch? {
        if let watch = existing(tab) {
            watch.touch()
            return watch
        }
        let connect = NSSelectorFromString("connect")
        guard web.responds(to: NSSelectorFromString("_inspector")), let inspector = web.value(forKey: "_inspector") as? NSObject,
              inspector.responds(to: connect), inspector.value(forKey: "isConnected") as? Bool != true else { return nil }
        let watch = InspectorWatch(tab: tab, web: web, inspector: inspector)
        watches[tab.id] = watch
        inspector.perform(connect)
        guard await watch.prepare() else {
            watch.detach()
            return nil
        }
        watch.touch()
        return watch
    }

    private let tabID: UUID
    fileprivate weak var web: WKWebView?
    private let inspector: NSObject
    private var frontend: WKWebView?
    private var decided = 0
    private var serial = 0
    private let decision = Waiters()
    private var lease: Task<Void, Never>?
    private var loading: NSKeyValueObservation?

    private init(tab: Tab, web: WKWebView, inspector: NSObject) {
        tabID = tab.id
        self.web = web
        self.inspector = inspector
    }

    /// The frontend loaded, its model up, the hook in and the Timeline recording.
    private func prepare() async -> Bool {
        guard let page = inspector.value(forKey: "inspectorWebView") as? WKWebView else { return false }
        frontend = page
        // Its page has loaded when it says so; that its model has its targets, nothing says, so that is asked inside it
        // (once, for a tenth of a second), with a watchdog for the frontend that never gets there.
        if page.isLoading || page.url == nil {
            let loaded = Waiters()
            loading = page.observe(\.isLoading, options: [.new]) { page, _ in
                MainActor.assumeIsolated { if !page.isLoading, page.url != nil { loaded.wake() } }
            }
            // The watchdog is for a frontend that never loads.
            await loaded.wait(atMost: 4)
            loading = nil
        }
        page.configuration.userContentController.add(self, name: "bsQuiet")
        let result = try? await page.callAsyncJavaScript(InspectorWatch.hook, arguments: [:], in: nil, contentWorld: .page)
        Debug.log("agent", "inspector for the tab: \(String(describing: result))")
        return result as? String == "ready"
    }

    /// The Web Inspector's own page, run in it. `WI` is its model; the hook sits on the connection its targets use.
    private static let hook = #"""
    const ready = () => !!(window.WI && WI.targets && WI.targets.length && (WI.pageTarget || WI.mainTarget));
    // A tenth of a second at most in practice; the frontend's page is BasicShell's own and idle meanwhile.
    for (let i = 0; i < 400 && !ready(); i++) await new Promise((r) => setTimeout(r, 10));
    if (!ready()) return "no model";
    if (window.__bsQuiet) return "ready";
    const post = (m) => { try { webkit.messageHandlers.bsQuiet.postMessage(m); } catch (e) {} };
    const target = WI.pageTarget || WI.mainTarget;
    const protos = new Set();
    for (const t of WI.targets) {
      let p = Object.getPrototypeOf(t.connection);
      while (p && p !== Object.prototype) { if (Object.prototype.hasOwnProperty.call(p, "dispatch")) { protos.add(p); break; } p = Object.getPrototypeOf(p); }
    }
    if (!protos.size) return "no connection";
    const S = { timers: new Map(), rafs: new Set(), net: new Map(), bgTimers: new Set(), bgRafs: new Set(), bgNet: new Set(),
                last: Date.now(), clearAt: 0, probing: false, want: null, wake: null };
    const now = () => Date.now();
    const WORK = new Set(["EvaluateScript", "FunctionCall", "TimerFire", "FireAnimationFrame", "EventDispatch", "ObserverCallback",
                          "Layout", "Paint", "RecalculateStyles", "Composite"]);
    const NETMAX = 400;
    // A reaction's own work moves `last`; the page's background (a repeating timer, what was going on before the action,
    // and what those start) does not.
    const note = (rec, background) => {
      const d = rec.data || {};
      const id = d.timerId !== undefined ? d.timerId : d.id;
      switch (rec.type) {
        case "TimerInstall": S.timers.set(id, { delay: d.timeout, once: !!d.singleShot }); if (background) S.bgTimers.add(id); break;
        case "TimerRemove": S.timers.delete(id); break;
        case "TimerFire": { const t = S.timers.get(id); if (t && t.once) S.timers.delete(id); break; }
        case "RequestAnimationFrame": S.rafs.add(id); if (background) S.bgRafs.add(id); break;
        case "FireAnimationFrame": case "CancelAnimationFrame": S.rafs.delete(id); break;
      }
      if (!background && WORK.has(rec.type)) S.last = now();
      for (const c of rec.children || []) note(c, background);
    };
    const isBackground = (rec) => {
      const d = rec.data || {};
      if (rec.type === "TimerFire") { const t = S.timers.get(d.timerId); return !t || !t.once || S.bgTimers.has(d.timerId); }
      if (rec.type === "FireAnimationFrame") return S.bgRafs.has(d.id);
      return false;
    };
    const waiting = (cap) => {
      let n = 0;
      for (const [id, t] of S.timers) if (t.once && t.delay <= cap && !S.bgTimers.has(id)) n++;
      for (const id of S.rafs) if (!S.bgRafs.has(id)) n++;
      const t = now();
      for (const [id, at] of S.net) if (!S.bgNet.has(id) && t - at < NETMAX) n++;
      return n;
    };
    // A CSS transition or animation sets no timer and no request, and a covered window paints nothing to see it by: the
    // page is asked, as the inspector's console would, whether a finite animation is running. That reads and writes nothing.
    const animating = async () => {
      try {
        const r = await target.RuntimeAgent.evaluate.invoke({
          expression: "document.getAnimations().some((a) => { const t = a.effect && a.effect.getComputedTiming(); return a.playState === 'running' && t && isFinite(t.endTime); })",
          returnByValue: true, doNotPauseOnExceptionsAndMuteConsole: true, objectGroup: "bsQuiet" });
        return !!(r && r.result && r.result.value);
      } catch (e) { return false; }
    };
    const check = () => {
      const w = S.want;
      if (!w) return;
      const t = now();
      let why = null;
      if (t - w.started >= w.cap) why = "cap";
      else if (waiting(w.cap) === 0 && t - S.last >= w.settle) {
        if (S.clearAt >= S.last) why = "idle";
        else if (!S.probing) {
          S.probing = true;
          animating().then((running) => { S.probing = false; if (running) S.last = now(); else S.clearAt = now(); check(); });
        }
      }
      if (why) { S.want = null; post({ k: "quiet", id: w.id, why, ms: t - w.started }); return; }
      clearTimeout(S.wake);
      S.wake = setTimeout(check, 10);
    };
    for (const p of protos) {
      const orig = p.dispatch;
      p.dispatch = function (message) {
        const o = typeof message === "string" ? JSON.parse(message) : message;
        const method = o && o.method;
        if (method && method.startsWith("Timeline.")) {
          if (method === "Timeline.eventRecorded") { note(o.params.record, isBackground(o.params.record)); check(); }
          return;
        }
        if (method === "Network.requestWillBeSent") { S.net.set(o.params.requestId, now()); S.last = now(); }
        else if (method === "Network.loadingFinished" || method === "Network.loadingFailed") { S.net.delete(o.params.requestId); S.last = now(); check(); }
        else if (method === "Page.frameNavigated" && !o.params.frame.parentId) {
          S.timers.clear(); S.rafs.clear(); S.net.clear(); S.bgTimers.clear(); S.bgRafs.clear(); S.bgNet.clear(); S.last = now();
        }
        return orig.call(this, message);
      };
    }
    // Before an action: what is going on now is the page's background.
    window.__bsBegin = () => {
      S.bgTimers = new Set(S.timers.keys()); S.bgRafs = new Set(S.rafs); S.bgNet = new Set(S.net.keys());
      S.last = now(); S.want = null; return true;
    };
    window.__bsSettle = (id, settle, cap) => { S.want = { id, settle, cap, started: now() }; check(); return true; };
    await target.TimelineAgent.setInstruments(["Timeline"]);
    await target.TimelineAgent.start(0);
    // A `debugger;` statement in the page stops nothing.
    await target.DebuggerAgent.disable();
    window.__bsQuiet = true;
    return "ready";
    """#

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], body["k"] as? String == "quiet", let id = body["id"] as? Int else { return }
        decided = max(decided, id)
        decision.wake()
    }

    /// Before an action: what is going on in the page now is its background.
    func begin() async {
        touch()
        _ = try? await frontend?.callAsyncJavaScript("return window.__bsBegin();", arguments: [:], in: nil, contentWorld: .page)
    }

    /// Until nothing the action started is pending (a timer up to the cap, a frame, a request) and nothing has
    /// been done for `margin` ms, or `cap` ms have passed. False when the inspector could not be asked.
    func settled(cap: Int, margin: Int) async -> Bool {
        guard let frontend else { return false }
        touch()
        serial += 1
        let id = serial
        let asked = try? await frontend.callAsyncJavaScript("return window.__bsSettle(id, margin, cap);",
                                                            arguments: ["id": id, "margin": max(margin, 40), "cap": cap], in: nil, contentWorld: .page)
        guard asked != nil else { return false }
        // The decision may have come while it was being asked for.
        if decided < id { await decision.wait(atMost: Double(cap) / 1000 + 0.4) }
        return true
    }

    /// The connection is kept for a few seconds after the last use, then closed (WebKit gives the inspector's process back
    /// within a minute): a lease on memory, not a wait for anything.
    private func touch() {
        lease?.cancel()
        lease = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            self?.detach()
        }
    }

    func detach() {
        lease?.cancel()
        lease = nil
        frontend?.configuration.userContentController.removeScriptMessageHandler(forName: "bsQuiet")
        frontend = nil
        inspector.perform(NSSelectorFromString("close"))
        InspectorWatch.watches[tabID] = nil
        decision.wake()
    }
}
#endif
