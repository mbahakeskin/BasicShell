import AppKit
import Observation
import WebKit

// Tabs you aren't looking at, in two steps.
//
// Frozen: a tab leaves the screen and its web view leaves the window, and the
// page is suspended: no script, no layout, no timers, no CPU. Nothing is lost:
// scroll position, what was typed, a video's place, an open menu. Coming back
// is instant. The suspension is WebKit's own, but private (Freeze, below): the
// public WKPreferences.inactiveSchedulingPolicy = .suspend, also set, was
// measured on macOS 27 to only throttle a page (timers about once a second).
// A tab playing sound or using the camera or microphone is not frozen.
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
    /// `sleep.unloadHours` in the defaults.
    static var unloadAfter: TimeInterval {
        let hours = UserDefaults.standard.double(forKey: "sleep.unloadHours")
        return (hours > 0 ? hours : 6) * 3600
    }

    static func keepsAwake(_ url: URL?) -> Bool { Awake.shared.contains(url) }

    // MARK: - watching the clock and the memory

    private static var timer: Timer?
    private static var pressure: DispatchSourceMemoryPressure?

    /// Started once, at launch.
    static func start() {
        let every: TimeInterval = min(300, unloadAfter / 4)
        timer = Timer.scheduledTimer(withTimeInterval: every, repeats: true) { _ in
            MainActor.assumeIsolated {
                unloadIdle(olderThan: unloadAfter)
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
        guard let web = tab.webView, !tab.hasTypedInput, !keepsAwake(tab.url),
              web.cameraCaptureState == .none, web.microphoneCaptureState == .none
        else { return }
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
        guard let web = tab.webView, !tab.isFrozen, !tab.isOnScreen, !keepsAwake(tab.url),
              web.cameraCaptureState == .none, web.microphoneCaptureState == .none
        else { return }
        var answered = false
        web.requestMediaPlaybackState { state in
            MainActor.assumeIsolated {
                guard !answered else { return }
                answered = true
                if state != .playing, tab.webView === web, !tab.isOnScreen { Freeze.freeze(tab) }
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
enum Freeze {
    private static let suspend = NSSelectorFromString("_suspendPage:")
    private static let resume = NSSelectorFromString("_resumePage:")

    static let available = WKWebView.instancesRespond(to: suspend) && WKWebView.instancesRespond(to: resume)

    static func freeze(_ tab: Tab) {
        guard available, let web = tab.webView, !tab.isFrozen else { return }
        tab.isFrozen = true
        let done: @convention(block) (Bool) -> Void = { [weak tab] worked in
            MainActor.assumeIsolated { if !worked { tab?.isFrozen = false } }
        }
        web.perform(suspend, with: done)
    }

    /// Called as the tab comes back on screen.
    static func thaw(_ tab: Tab) {
        guard tab.isFrozen, let web = tab.webView else { return }
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

    private static func site(_ host: String) -> String {
        host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

extension Tab {
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: finish)
    }
}
