import Foundation

// An address with what only follows the person who followed it taken off:
// the parameters a link picks up when it is shared or clicked from an ad,
// an email or another site (utm_*, fbclid, gclid and the like). The page the
// address names is the same without them. ⇧⌘C and Copy Address use it unless
// Settings › Privacy says not to; ⌥⇧⌘C copies the address as it is.
//
// Only what is known to be tracking only: a parameter a page needs to be
// itself (a search's q, a video's t, a product's id) is never touched, so a
// few that are tracking on one site and not on another are listed by site.
enum LinkCleaner {
    static let key = "copy.clean"

    /// Settings › Privacy; on unless turned off.
    static var enabled: Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? true }

    /// On every site.
    private static let everywhere: Set<String> = [
        "fbclid", "gclid", "gclsrc", "dclid", "gbraid", "wbraid", "msclkid", "twclid", "ttclid", "li_fat_id", "yclid",
        "igshid", "igsh", "mc_cid", "mc_eid", "mkt_tok", "_ga", "_gl", "_hsenc", "_hsmi", "vero_id", "vero_conv",
        "oly_enc_id", "oly_anon_id", "rb_clickid", "s_cid", "sc_cid", "ref_src", "ref_url", "trk", "trkinfo",
        "mibextid", "fb_action_ids", "fb_action_types", "fb_source", "wickedid", "cmpid", "irclickid", "_openstat",
    ]

    /// Starts of names that are all tracking (utm_source, utm_medium…).
    private static let prefixes = ["utm_", "mtm_", "pk_", "hsa_", "ga_", "oly_"]

    /// On these sites (and their subdomains) as well.
    private static let bySite: [String: Set<String>] = [
        "x.com": ["s", "t"],
        "twitter.com": ["s", "t"],
        "youtube.com": ["si", "feature", "pp"],
        "youtu.be": ["si", "feature", "pp"],
        "spotify.com": ["si", "context", "nd", "dlsi"],
        "amazon.com": ["tag", "linkcode", "linkid", "ref", "ref_", "pd_rd_r", "pd_rd_w", "pd_rd_wg", "pf_rd_r", "pf_rd_p", "pf_rd_s", "pf_rd_t", "pf_rd_i", "pf_rd_m", "content-id"],
        "linkedin.com": ["trackingid", "refid", "originalsubdomain", "lipi", "licu", "trk"],
        "reddit.com": ["share_id", "ref", "ref_source"],
        "medium.com": ["source"],
        "facebook.com": ["__cft__[0]", "__tn__", "rdid", "share_url"],
        "instagram.com": ["igsh", "igshid", "utm_source"],
        "tiktok.com": ["_r", "_t", "is_from_webapp", "sender_device", "sender_web_id", "web_id", "share_app_id", "share_link_id", "share_author_id"],
    ]

    /// The address without its tracking, and how many parameters that took off.
    static func clean(_ url: URL) -> (url: URL, removed: Int) {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              var parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = parts.queryItems, !items.isEmpty
        else { return (url, 0) }
        let host = url.host()?.lowercased() ?? ""
        var site: Set<String> = []
        for (name, names) in bySite where host == name || host.hasSuffix("." + name) { site.formUnion(names) }
        // Amazon's shops are on a domain of each country.
        if host.hasPrefix("amazon.") || host.contains(".amazon.") { site.formUnion(bySite["amazon.com"] ?? []) }
        let kept = items.filter { item in
            let name = item.name.lowercased()
            return !(everywhere.contains(name) || site.contains(name) || prefixes.contains { name.hasPrefix($0) })
        }
        let removed = items.count - kept.count
        guard removed > 0 else { return (url, 0) }
        parts.queryItems = kept.isEmpty ? nil : kept
        return (parts.url ?? url, removed)
    }
}
