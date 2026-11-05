import AppKit
import Observation
import WebKit

// Muting a tab, or a site, and the speaker that shows which tab is making sound.
//
// WebKit's own pair does it, both private and each used only where WebKit has it: `_setPageMuted:` (its argument is
// `_WKMediaMutedState`, bit 0 being the page's audio) and `_playingAudio`, a property that says whether the page is making
// sound and is observed by key (it announces itself as `_isPlayingAudio`), so nothing is looked at every so often. A tab is muted by its own say (a click on its
// speaker, or Mute Tab) or else by its site's (Mute Site, kept in the defaults, as the sites kept awake are).

/// Sites muted for good.
@Observable
final class MutedSites {
    static let shared = MutedSites()
    private(set) var sites: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "mute.sites") ?? [])

    func contains(_ url: URL?) -> Bool {
        guard let host = url?.host() else { return false }
        return sites.contains(MutedSites.site(host))
    }

    func set(_ url: URL?, _ on: Bool) {
        guard let host = url?.host() else { return }
        if on { sites.insert(MutedSites.site(host)) } else { sites.remove(MutedSites.site(host)) }
        save()
    }

    func remove(site: String) {
        sites.remove(site)
        save()
    }

    private func save() {
        UserDefaults.standard.set(sites.sorted(), forKey: "mute.sites")
        // The tabs of every window take it up at once.
        for window in Windows.all { for tab in window.shell.allTabs { tab.applyMute() } }
    }

    private static func site(_ host: String) -> String {
        host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

extension Tab {
    /// Whether its sound is off: by its own say if it has one, else by its site's.
    var isMuted: Bool { muteSaid ?? MutedSites.shared.contains(url) }

    /// The tab's own say, kept apart from its site's so that a click on the speaker of a tab on a muted site turns it on for that tab.
    func setMuted(_ muted: Bool?) {
        muteSaid = muted
        applyMute()
    }

    /// The speaker's click, and Mute Tab.
    func toggleMute() { setMuted(!isMuted) }

    /// What WebKit is told, whenever what decides it may have changed: a page made, an address that went to another site, a site muted.
    func applyMute() {
        guard let web = webView else { return }
        Tab.mute(web, isMuted)
    }

    /// WebKit's `_setPageMuted:`, audio only.
    private static func mute(_ web: WKWebView, _ on: Bool) {
        let set = NSSelectorFromString("_setPageMuted:")
        guard web.responds(to: set), let method = class_getMethodImplementation(WKWebView.self, set) else { return }
        typealias SetMuted = @convention(c) (AnyObject, Selector, UInt) -> Void
        unsafeBitCast(method, to: SetMuted.self)(web, set, on ? 1 : 0)
    }

    /// Begins telling `isPlayingAudio` from the page (see AudioWatch); the page's earlier watch ends.
    func watchAudio(_ web: WKWebView) {
        audioWatch?.stop()
        audioWatch = web.responds(to: NSSelectorFromString("_isPlayingAudio")) ? AudioWatch(self, web) : nil
        applyMute()
    }

    func stopWatchingAudio() {
        audioWatch?.stop()
        audioWatch = nil
        audioQuiet?.cancel()
        isPlayingAudio = false
    }

    /// What WebKit says now, for a page that was already making sound when it was looked at (a load finished, the tab
    /// shown). Only once the page has a process: before that there is nothing to ask.
    func refreshAudio() {
        guard let web = webView, audioWatch != nil, web.url != nil else { return }
        let key = "_isPlayingAudio"
        guard web.responds(to: NSSelectorFromString(key)), let playing = web.value(forKey: key) as? Bool else { return }
        audioChanged(playing)
    }

    fileprivate func audioChanged(_ playing: Bool) {
        Debug.log("mute", "audio \(playing ? "on" : "off") in \(title)")
        audioQuiet?.cancel()
        if playing {
            if !isPlayingAudio { isPlayingAudio = true }
        } else if isPlayingAudio {
            // A lease on the speaker, not a wait for anything: it goes two seconds after the sound did.
            audioQuiet = Task { [weak self] in
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                self?.isPlayingAudio = false
            }
        }
    }
}

/// Tells a tab when its page starts or stops making sound: WebKit's `_isPlayingAudio`, observed by its key.
final class AudioWatch: NSObject {
    private weak var tab: Tab?
    private weak var web: WKWebView?
    private var watching = true

    init(_ tab: Tab, _ web: WKWebView) {
        self.tab = tab
        self.web = web
        super.init()
        web.addObserver(self, forKeyPath: AudioWatch.key, options: [.new], context: nil)
    }

    func stop() {
        guard watching else { return }
        watching = false
        web?.removeObserver(self, forKeyPath: AudioWatch.key)
    }

    deinit { if watching { web?.removeObserver(self, forKeyPath: AudioWatch.key) } }

    /// The key WebKit announces a change of under (measured: `_isPlayingAudio`, not the property's own name). The value is not read
    /// when the watch begins: the page has no process yet, and asking it then crashed.
    nonisolated private static let key = "_isPlayingAudio"

    nonisolated override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        guard keyPath == AudioWatch.key else { return }
        let playing = (change?[.newKey] as? NSNumber)?.boolValue ?? false
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.tab?.audioChanged(playing) }
        }
    }
}
