import AppKit
import Observation
import WebKit

// Tabs you aren't looking at, in two steps.
//
// Frozen: a tab leaves the screen and its web view leaves the window, and the
// page is suspended with WebKit's private page suspension (Freeze, below): no
// script, no layout, no timers, no CPU, nothing lost, back instantly. With it
// turned off (Settings › Tabs) WebKit only slows such a page down
// (inactiveSchedulingPolicy, measured: timers about once a second).
//
// Unloaded: after six hours off screen, or at once when macOS says memory is
// critically short, the page is let go and its memory with it. Its history is
// kept (WKWebView.interactionState), its scroll position is noted as it leaves
// the screen and restored, and a picture of it is shown while it loads again.
// A tab is never unloaded while it holds something typed and not sent, uses the
// camera or microphone, or plays sound.
//
// A site can be kept awake (the sun in the top bar): its tabs stay in the
// window, hidden, and are neither frozen nor unloaded. That is for mail and
// chat, which should keep notifying.
enum Sleep {
    /// How long a tab stays off screen before it is unloaded. Six hours, or
    /// `sleep.unloadHours` in the defaults; 0 means never.
    static var unloadAfter: TimeInterval? {
        let hours = UserDefaults.standard.object(forKey: "sleep.unloadHours") as? Double ?? 6
        return hours > 0 ? hours * 3600 : nil
    }

    static func keepsAwake(_ url: URL?) -> Bool { Awake.shared.contains(url) }

    // MARK: - watching the clock and the memory

    private static var timer: Timer?
    private static var pressure: DispatchSourceMemoryPressure?

    /// Started once, at launch.
    static func start() {
        let every: TimeInterval = min(300, (unloadAfter ?? 1200) / 4, (Archive.after ?? 1200) / 4)
        timer = Timer.scheduledTimer(withTimeInterval: every, repeats: true) { _ in
            MainActor.assumeIsolated {
                archiveIdle()
                if let after = unloadAfter { unloadIdle(olderThan: after) }
                // Tabs left running because they were playing: frozen once they stop.
                for window in Windows.all {
                    for tab in window.shell.tabs where tab !== window.shell.selected && !tab.isOnScreen {
                        freezeIfIdle(tab)
                    }
                }
            }
        }
        timer?.tolerance = every / 4
        let source = DispatchSource.makeMemoryPressureSource(eventMask: .critical, queue: .main)
        source.setEventHandler {
            MainActor.assumeIsolated { unloadIdle(olderThan: 60) }
        }
        source.resume()
        pressure = source
    }

    /// Tabs unseen for longer than Archive.after go to the archive; pinned
    /// ones, private ones and ones holding something typed never do.
    static func archiveIdle() {
        guard let after = Archive.after else { return }
        let now = Date()
        for window in Windows.all {
            for tab in window.shell.tabs where tab !== window.shell.selected && !tab.pinned && !tab.isPrivate
                && !tab.hasTypedInput && !keepsAwake(tab.url) && now.timeIntervalSince(tab.lastSeen) > after {
                window.archive(tab)
            }
        }
    }

    /// Every tab in every window off screen for longer than `age`, oldest first.
    static func unloadIdle(olderThan age: TimeInterval) {
        let now = Date()
        let tabs = Windows.all.flatMap { window in
            window.shell.tabs.filter { $0 !== window.shell.selected }
        }
        .filter { $0.webView != nil && now.timeIntervalSince($0.lastSeen) > age }
        .sorted { $0.lastSeen < $1.lastSeen }
        for tab in tabs { unloadIfSafe(tab) }
    }

    /// Unloads a tab unless it holds something that can't be brought back.
    static func unloadIfSafe(_ tab: Tab) {
        guard let web = tab.webView, !tab.hasTypedInput, !keepsAwake(tab.url) else { return }
        // A frozen page plays nothing and uses no camera (those are never
        // frozen), and asking it would throw.
        if tab.isFrozen { return tab.unload() }
        guard web.cameraCaptureState == .none, web.microphoneCaptureState == .none else { return }
        // A page that doesn't answer in a second is frozen, so not playing.
        var answered = false
        let finish: (Bool) -> Void = { playing in
            guard !answered else { return }
            answered = true
            if !playing, tab.webView === web, !tab.isOnScreen { tab.unload() }
        }
        web.requestMediaPlaybackState { state in
            MainActor.assumeIsolated { finish(state == .playing) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { finish(false) }
    }

    /// Freezes a tab that is off screen, unless it is kept awake, playing, or
    /// using the camera or microphone. A page that doesn't say whether it is
    /// playing is left running rather than risk stopping it mid-song.
    static func freezeIfIdle(_ tab: Tab) {
        // Never mid-load: the page would still report its loads, frozen.
        guard Freeze.enabled, let web = tab.webView, !tab.isFrozen, !tab.isOnScreen, !web.isLoading, !keepsAwake(tab.url),
              web.cameraCaptureState == .none, web.microphoneCaptureState == .none
        else { return }
        var answered = false
        web.requestMediaPlaybackState { state in
            MainActor.assumeIsolated {
                guard !answered else { return }
                answered = true
                if state != .playing, tab.webView === web, !tab.isOnScreen, !web.isLoading { Freeze.freeze(tab) }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { answered = true }
    }

    // MARK: - leaving the screen

    /// Put in every page at its start, in a script world of the browser's own
    /// that the page can neither see nor change: remembers the fields the
    /// person (not the page's own script) has typed into, forgotten again
    /// when the form is sent.
    static let typingWatch = WKUserScript(source: """
    (() => {
      const touched = new Set();
      const note = e => { if (e.isTrusted && e.target) touched.add(e.target); };
      addEventListener('input', note, true);
      addEventListener('change', note, true);
      addEventListener('submit', () => touched.clear(), true);
      globalThis.typedAndNotSent = () => {
        for (const el of touched) {
          if (!el.isConnected) continue;
          if (el.isContentEditable) { if (el.innerText.trim() !== '') return true; continue; }
          if (el.type === 'checkbox' || el.type === 'radio') { if (el.checked !== el.defaultChecked) return true; continue; }
          if (el.tagName === 'SELECT') { if ([...el.options].some(o => o.selected !== o.defaultSelected)) return true; continue; }
          if ('value' in el && el.value !== el.defaultValue && el.value.trim() !== '') return true;
        }
        return false;
      };
    })();
    """, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .defaultClient)

    /// Where the page is scrolled to, and whether it holds anything typed and not sent.
    static let leaving = "({ typed: typeof typedAndNotSent === 'function' && typedAndNotSent(), x: scrollX, y: scrollY })"
}

/// WebKit's own page suspension. WKWebView has it only as private methods,
/// `_suspendPage:` and `_resumePage:`, each answering with whether it worked;
/// they are used only when this WebKit has them. If a page doesn't come back
/// from it, it is loaded again rather than left blank.
///
/// A suspended web view throws on nearly everything done to it — load,
/// reload, stop, go back, zoom, run script, take a picture, ask about media
/// (measured, macOS 27: "The WKWebView is suspended") — and an uncaught
/// exception ends the app. So a frozen tab is woken before anything here
/// touches it, extensions are not given its web view, and WebKit's own
/// extension code, which runs scripts in any tab it holds (Bitwarden's
/// sign-out ran one in every tab and brought BasicShell down), goes through a
/// guard that wakes the page first (`guardScripts`, verified against the
/// exact call that crashed).
enum Freeze {
    private static let suspend = NSSelectorFromString("_suspendPage:")
    private static let resume = NSSelectorFromString("_resumePage:")

    static let available = WKWebView.instancesRespond(to: suspend) && WKWebView.instancesRespond(to: resume)

    /// On unless turned off in Settings › Tabs.
    static var enabled: Bool { available && (UserDefaults.standard.object(forKey: "sleep.freeze") as? Bool ?? true) }

    /// Wraps the methods that reach into a page and throw on a frozen one,
    /// so the page is woken first instead. They are the ones WebKit's
    /// extension code calls on a tab (scripting.executeScript runs through
    /// the private `_evaluateJavaScript:…withUserGesture:` and
    /// `_callAsyncJavaScript:…withUserGesture:`, tabs.captureVisibleTab
    /// through `takeSnapshotWithConfiguration:`), which can land after the
    /// tab was frozen: WebKit asks for the tab's frames first and runs the
    /// script when they arrive. The public and private variants of the
    /// script methods are wrapped as well. Installed once at launch; a
    /// method this WebKit lacks is skipped. A tab woken this way is frozen
    /// again by Sleep's next round.
    static func guardScripts() {
        typealias Two = @convention(c) (AnyObject, Selector, AnyObject?, AnyObject?) -> Void
        typealias Four = @convention(c) (AnyObject, Selector, AnyObject?, AnyObject?, AnyObject?, AnyObject?) -> Void
        typealias Five = @convention(c) (AnyObject, Selector, AnyObject?, AnyObject?, AnyObject?, AnyObject?, AnyObject?) -> Void
        typealias FourFlag = @convention(c) (AnyObject, Selector, AnyObject?, AnyObject?, AnyObject?, AnyObject?, Bool, AnyObject?) -> Void

        func method(_ name: String) -> (Method, Selector)? {
            let selector = NSSelectorFromString(name)
            return class_getInstanceMethod(WKWebView.self, selector).map { ($0, selector) }
        }
        for name in ["evaluateJavaScript:completionHandler:", "_evaluateJavaScriptWithoutUserGesture:completionHandler:",
                     "takeSnapshotWithConfiguration:completionHandler:"] {
            guard let (found, selector) = method(name) else { continue }
            let original = unsafeBitCast(method_getImplementation(found), to: Two.self)
            let wrapper: @convention(block) (AnyObject, AnyObject?, AnyObject?) -> Void = { view, a, b in
                wake(view, for: name)
                original(view, selector, a, b)
            }
            method_setImplementation(found, imp_implementationWithBlock(wrapper))
        }
        for name in ["evaluateJavaScript:inFrame:inContentWorld:completionHandler:", "_evaluateJavaScript:inFrame:inContentWorld:completionHandler:"] {
            guard let (found, selector) = method(name) else { continue }
            let original = unsafeBitCast(method_getImplementation(found), to: Four.self)
            let wrapper: @convention(block) (AnyObject, AnyObject?, AnyObject?, AnyObject?, AnyObject?) -> Void = { view, a, b, c, d in
                wake(view, for: name)
                original(view, selector, a, b, c, d)
            }
            method_setImplementation(found, imp_implementationWithBlock(wrapper))
        }
        for name in ["callAsyncJavaScript:arguments:inFrame:inContentWorld:completionHandler:",
                     "_callAsyncJavaScript:arguments:inFrame:inContentWorld:completionHandler:",
                     "_evaluateJavaScript:withSourceURL:inFrame:inContentWorld:completionHandler:"] {
            guard let (found, selector) = method(name) else { continue }
            let original = unsafeBitCast(method_getImplementation(found), to: Five.self)
            let wrapper: @convention(block) (AnyObject, AnyObject?, AnyObject?, AnyObject?, AnyObject?, AnyObject?) -> Void = { view, a, b, c, d, e in
                wake(view, for: name)
                original(view, selector, a, b, c, d, e)
            }
            method_setImplementation(found, imp_implementationWithBlock(wrapper))
        }
        for name in ["_evaluateJavaScript:withSourceURL:inFrame:inContentWorld:withUserGesture:completionHandler:",
                     "_callAsyncJavaScript:arguments:inFrame:inContentWorld:withUserGesture:completionHandler:"] {
            guard let (found, selector) = method(name) else { continue }
            let original = unsafeBitCast(method_getImplementation(found), to: FourFlag.self)
            let wrapper: @convention(block) (AnyObject, AnyObject?, AnyObject?, AnyObject?, AnyObject?, Bool, AnyObject?) -> Void = { view, a, b, c, d, flag, e in
                wake(view, for: name)
                original(view, selector, a, b, c, d, flag, e)
            }
            method_setImplementation(found, imp_implementationWithBlock(wrapper))
        }
    }

    /// Wakes whichever tab this frozen view belongs to.
    private static func wake(_ view: AnyObject, for reason: String) {
        guard let web = view as? WKWebView else { return }
        MainActor.assumeIsolated {
            for window in Windows.all {
                for tab in window.shell.tabs where tab.isFrozen && tab.webView === web {
                    Debug.log("sleep", "waking \(tab.name) for \(reason)")
                    thaw(tab)
                }
            }
        }
    }

    static func freeze(_ tab: Tab) {
        guard enabled, let web = tab.webView, !tab.isFrozen else { return }
        Debug.log("sleep", "freezing \(tab.name)")
        tab.isFrozen = true
        let done: @convention(block) (Bool) -> Void = { [weak tab] worked in
            MainActor.assumeIsolated { if !worked { tab?.isFrozen = false } }
        }
        web.perform(suspend, with: done)
    }

    /// Called as the tab comes back on screen, and before anything is done
    /// to a frozen tab's web view. The view can be used as soon as this
    /// returns (measured).
    static func thaw(_ tab: Tab) {
        guard tab.isFrozen, let web = tab.webView else { return }
        Debug.log("sleep", "waking \(tab.name)")
        tab.isFrozen = false
        var answered = false
        let recover = {
            guard tab.webView === web else { return }
            if web.url != nil { web.reload() }
        }
        let done: @convention(block) (Bool) -> Void = { worked in
            MainActor.assumeIsolated {
                guard !answered else { return }
                answered = true
                if !worked { recover() }
            }
        }
        web.perform(resume, with: done)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            guard !answered else { return }
            answered = true
            recover()
        }
    }
}

/// Sites whose tabs never sleep, kept in the defaults.
@Observable
final class Awake {
    static let shared = Awake()
    private(set) var sites: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "sleep.awake") ?? [])

    func contains(_ url: URL?) -> Bool {
        guard let host = url?.host() else { return false }
        return sites.contains(Awake.site(host))
    }

    func set(_ url: URL?, _ on: Bool) {
        guard let host = url?.host() else { return }
        if on { sites.insert(Awake.site(host)) } else { sites.remove(Awake.site(host)) }
        UserDefaults.standard.set(sites.sorted(), forKey: "sleep.awake")
    }

    func remove(site: String) {
        sites.remove(site)
        UserDefaults.standard.set(sites.sorted(), forKey: "sleep.awake")
    }

    private static func site(_ host: String) -> String {
        host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

extension Tab {
    /// In its window, or floating in Picture in Picture.
    var isOnScreen: Bool { webView?.window != nil && webView?.isHidden == false }

    /// The tab is going off screen: note what it was holding, where it was
    /// scrolled to and what it looked like, while the page can still answer.
    /// `done` runs once the picture is taken (or couldn't be), because WebKit
    /// can only take it while the page is still in the window.
    func leavingScreen(done: @escaping () -> Void) {
        lastSeen = Date()
        guard let web = webView else { return done() }
        web.evaluateJavaScript(Sleep.leaving, in: nil, in: .defaultClient) { [weak self] result in
            MainActor.assumeIsolated {
                guard let self, case .success(let value) = result, let state = value as? [String: Any] else { return }
                self.hasTypedInput = (state["typed"] as? Bool) ?? false
                if let x = state["x"] as? Double, let y = state["y"] as? Double {
                    self.scrolled = CGPoint(x: x, y: y)
                }
            }
        }
        // Kept as a small JPEG: a full-size bitmap per tab would cost more
        // than unloading saves.
        let config = WKSnapshotConfiguration()
        config.afterScreenUpdates = false
        config.snapshotWidth = NSNumber(value: min(Double(web.bounds.width), 1440))
        var finished = false
        let finish = {
            guard !finished else { return }
            finished = true
            done()
        }
        web.takeSnapshot(with: config) { [weak self] image, _ in
            MainActor.assumeIsolated { finish() }
            guard let cg = image?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
            Task.detached(priority: .utility) {
                let data = NSBitmapImageRep(cgImage: cg).representation(using: .jpeg, properties: [.compressionFactor: 0.6])
                await MainActor.run { self?.snapshot = data }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { finish() }
    }
}
