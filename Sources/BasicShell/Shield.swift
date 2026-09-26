import WebKit

// The ad and tracker blocker: a WKContentRuleList compiled once at launch and
// enforced inside WebKit's networking, before a request is made. It costs
// nothing while pages run. Adapted from Search's Shield.swift (Office Commun, MIT).
final class Shield {
    static let shared = Shield()

    private(set) var list: WKContentRuleList?
    private var waiting: [WKUserContentController] = []
    private(set) var trouble: String?

    /// Sites it is switched off for, because it broke them.
    private(set) var paused: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "shield.paused") ?? [])

    func isPaused(on host: String?) -> Bool {
        guard let host else { return false }
        return paused.contains(host)
    }

    func pause(_ host: String, _ off: Bool) {
        if off { paused.insert(host) } else { paused.remove(host) }
        UserDefaults.standard.set(paused.sorted(), forKey: "shield.paused")
    }

    /// Before each main-frame navigation: on or off for where it is going.
    func tune(_ controller: WKUserContentController, for host: String?) {
        guard let list else { return }
        controller.remove(list)
        if !isPaused(on: host) { controller.add(list) }
    }

    /// Third parties whose only job is to watch or to sell. First-party
    /// requests are left alone.
    private static let unwanted = [
        "doubleclick.net", "googlesyndication.com", "googleadservices.com",
        "googletagservices.com", "google-analytics.com", "googletagmanager.com",
        "adservice.google.com", "amazon-adsystem.com", "adnxs.com", "adsrvr.org",
        "criteo.com", "criteo.net", "taboola.com", "outbrain.com",
        "rubiconproject.com", "pubmatic.com", "openx.net", "casalemedia.com",
        "smartadserver.com", "sharethrough.com", "indexww.com", "bidswitch.net",
        "33across.com", "teads.tv", "moatads.com", "adroll.com",
        "scorecardresearch.com", "quantserve.com", "chartbeat.com",
        "hotjar.com", "mouseflow.com", "fullstory.com", "clarity.ms",
        "mixpanel.com", "amplitude.com", "segment.com", "segment.io",
        "branch.io", "appsflyer.com", "adjust.com", "analytics.tiktok.com",
        "connect.facebook.net", "ads-twitter.com", "analytics.twitter.com",
    ]

    /// Element slots that are reliably an ad and nothing else. Kept short: a
    /// generous cosmetic list is how a blocker starts eating the page.
    private static let slots = [
        ".adsbygoogle", "ins.adsbygoogle", "[id^=\"google_ads_\"]",
        "[id^=\"div-gpt-ad\"]", "[id^=\"taboola-\"]", "#taboola-below-article",
        "iframe[src*=\"doubleclick.net\"]", "iframe[src*=\"googlesyndication\"]",
        "iframe[src*=\"amazon-adsystem\"]",
    ]

    func compile() {
        guard list == nil else { return }
        var rules: [[String: Any]] = Shield.unwanted.map { domain in
            let escaped = domain.replacingOccurrences(of: ".", with: "\\.")
            return [
                "trigger": ["url-filter": "^https?://([^/]+\\.)?\(escaped)", "load-type": ["third-party"]],
                "action": ["type": "block"],
            ]
        }
        rules.append([
            "trigger": ["url-filter": ".*"],
            "action": ["type": "css-display-none", "selector": Shield.slots.joined(separator: ", ")],
        ])
        guard let data = try? JSONSerialization.data(withJSONObject: rules),
              let json = String(data: data, encoding: .utf8),
              let store = WKContentRuleListStore.default()
        else {
            trouble = "Couldn't build the block list"
            return
        }
        store.compileContentRuleList(forIdentifier: "shield", encodedContentRuleList: json) { [weak self] compiled, error in
            guard let self else { return }
            guard let compiled else {
                self.trouble = error?.localizedDescription ?? "Compiling the block list failed"
                return
            }
            self.list = compiled
            self.waiting.forEach { $0.add(compiled) }
            self.waiting = []
        }
    }

    /// Every tab asks; whoever asks before it is compiled gets it when it is.
    func protect(_ controller: WKUserContentController) {
        if let list { controller.add(list) } else { waiting.append(controller) }
    }
}
