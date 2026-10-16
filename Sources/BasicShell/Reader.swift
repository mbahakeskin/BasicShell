import AppKit
import Observation
import SwiftUI
import WebKit

// Reader (⌥⌘R): the article of the page on its own, in a page of BasicShell's making.
//
// The page is read, never touched. A script of BasicShell's own runs in an isolated world of the page (its globals are
// not the page's and the page cannot see them) and only reads: it finds the article, walks it, and hands back text made
// of a short list of tags, none of the page's scripts, styles, frames, forms or classes among them. That text is shown
// in a second web view laid over the first, a page BasicShell writes itself: no JavaScript runs in it, and a content
// security policy lets nothing in but its images. So the clean view is clean by construction, and the page under it is
// the one that was there, as it was. Closing the reader takes the second view away.
//
// Whether a page has an article is asked once, when it has loaded, by the same script run for a count only.
enum Reader {
    /// The isolated world the reading script runs in.
    static let world = WKContentWorld.world(name: "BasicShellReader")

    struct Article {
        var title: String
        var byline: String?
        var site: String
        var date: Date?
        var lang: String
        var rtl: Bool
        var html: String
        var words: Int
        var paragraphs: Int
        var images: Int
        var url: URL
        /// How long reading the page took, in the page's process, in milliseconds.
        var took: Double
        /// What the page had, for the log's comparison.
        var page: [String: Int] = [:]
    }

    /// The script. `probe` set: only whether there is an article, and how long it is. It reads the page's DOM and
    /// computed styles and changes nothing; it returns null for what is not an article.
    private static let script = #"""
    const started = performance.now();
    const doc = document;
    if (!doc.body || !/html/.test(doc.contentType)) return null;
    const text = (e) => (e.textContent || "").replace(/\s+/g, " ").trim();
    const linkLength = (e) => { let n = 0; for (const a of e.querySelectorAll("a")) n += text(a).length; return n; };
    const density = (e) => { const t = text(e).length; return t ? linkLength(e) / t : 1; };
    const tokens = (e) => ((e.id || "") + " " + (typeof e.className === "string" ? e.className : "")).toLowerCase().split(/[^a-z0-9]+/).filter(Boolean);
    const NEG = new Set(["comment", "comments", "disqus", "sidebar", "footer", "nav", "navigation", "navbox", "menu", "masthead", "related",
      "recommended", "promo", "promoted", "advert", "advertisement", "ad", "ads", "sponsor", "sponsored", "banner", "cookie", "cookies",
      "consent", "social", "share", "sharing", "newsletter", "subscribe", "signup", "popup", "modal", "toolbar", "breadcrumb", "breadcrumbs",
      "pagination", "widget", "outbrain", "taboola", "teaser", "trending", "paywall", "toc", "editsection", "metadata", "catlinks",
      "printfooter", "skiplink", "noprint", "screenreader", "infobox", "ambox", "mbox", "hatnote", "shortdescription", "thumbcaption-hidden"]);
    const POS = new Set(["article", "body", "content", "entry", "post", "story", "text", "main", "prose", "markdown", "page"]);
    const junk = (e) => tokens(e).some((t) => NEG.has(t));
    const BAD_IMG = new Set(["icon", "icons", "logo", "avatar", "emoji", "sprite", "pixel", "tracking", "badge", "spacer", "blank"]);

    // The text blocks, and where they sit: a container earns what its paragraphs hold.
    const score = new Map();
    const base = (e) => {
      let w = 0;
      const t = tokens(e);
      if (t.some((x) => NEG.has(x))) w -= 25;
      if (t.some((x) => POS.has(x))) w += 8;
      const tag = e.tagName;
      if (tag === "ARTICLE") w += 12;
      if (tag === "MAIN" || e.getAttribute("role") === "main") w += 6;
      if (e.getAttribute("itemprop") === "articleBody") w += 40;
      if (tag === "ASIDE" || tag === "NAV" || tag === "FOOTER" || tag === "FORM") w -= 40;
      return w;
    };
    const bump = (e, n) => {
      if (!e || e === doc.body || e === doc.documentElement) return;
      if (!score.has(e)) score.set(e, base(e));
      score.set(e, score.get(e) + n);
    };
    let paragraphs = 0;
    const items = [];
    for (const p of doc.querySelectorAll("p, pre")) {
      if (p.closest("nav, aside, footer, header, form, [hidden], [aria-hidden=true]")) continue;
      const t = text(p);
      if (t.length < 50) continue;
      if (linkLength(p) / t.length > 0.5) continue;
      paragraphs++;
      const pts = 1 + Math.min(3, Math.floor(t.length / 100)) + (t.match(/[,;:.!?]/g) || []).length * 0.15;
      items.push({ el: p, pts });
      const up = p.parentElement;
      bump(up, pts);
      if (up) { bump(up.parentElement, pts / 2); if (up.parentElement) bump(up.parentElement.parentElement, pts / 4); }
    }
    // Older pages break paragraphs with <br><br> inside a container: text held directly by a box counts as well.
    for (const d of doc.querySelectorAll("div, td, section, font, article, main")) {
      if (d.closest("nav, aside, footer, header, form, [hidden], [aria-hidden=true]")) continue;
      let direct = 0;
      for (const c of d.childNodes) if (c.nodeType === 3) direct += c.nodeValue.trim().length;
      if (direct < 200) continue;
      const pts = 1 + Math.min(3, Math.floor(direct / 100));
      paragraphs += 1 + (d.querySelectorAll(":scope > br").length >> 1);
      items.push({ el: d, pts });
      bump(d, pts);
      bump(d.parentElement, pts / 2);
    }
    if (paragraphs < 2) return null;
    let top = null, best = -1;
    for (const [e, s] of score) {
      const adjusted = s * (1 - Math.min(0.9, density(e)));
      if (adjusted > best) { best = adjusted; top = e; }
    }
    if (!top) return null;
    // A page whose text is split into many boxes (sections of a document): the box that holds most of it, not the best of the parts.
    const total = items.reduce((n, i) => n + i.pts, 0);
    const share = (a) => items.reduce((n, i) => n + (a.contains(i.el) ? i.pts : 0), 0);
    if (share(top) < total * 0.5) {
      for (let up = top.parentElement; up && up !== doc.body; up = up.parentElement) {
        if (share(up) >= total * 0.7 && density(up) < 0.35) { top = up; break; }
      }
    }
    // An <article> round it, when it holds little more than what was found; a container just above, when it earned
    // nearly as much (the article split over a few blocks).
    const topLength = text(top).length;
    for (let up = top.parentElement, n = 0; up && up !== doc.body && n < 4; up = up.parentElement, n++) {
      const t = text(up).length;
      if (up.tagName === "ARTICLE" && t <= topLength * 1.6 && density(up) < 0.35) top = up;
      else if (score.has(up) && score.get(up) >= score.get(top) * 0.75 && t <= topLength * 1.8 && density(up) < 0.35 && !junk(up)) top = up;
    }

    // What is shown: the tags kept, nothing of the page's own markup.
    const esc = (s) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
    const attr = (s) => esc(s).replace(/"/g, "&quot;");
    const DROP = new Set(["SCRIPT", "STYLE", "NOSCRIPT", "TEMPLATE", "IFRAME", "OBJECT", "EMBED", "FORM", "INPUT", "BUTTON", "SELECT", "TEXTAREA",
      "LABEL", "NAV", "ASIDE", "FOOTER", "HEADER", "DIALOG", "CANVAS", "AUDIO", "VIDEO", "SVG", "svg", "MAP", "LINK", "META", "HEAD", "SOURCE", "TRACK"]);
    const INLINE = new Set(["EM", "STRONG", "B", "I", "U", "SUB", "SUP", "CODE", "KBD", "MARK", "S", "Q", "ABBR", "CITE", "SMALL", "DEL", "INS", "VAR", "SAMP"]);
    const TEXTBLOCK = new Set(["P", "H1", "H2", "H3", "H4", "H5", "H6", "LI", "TD", "TH", "FIGCAPTION", "CAPTION", "DT", "DD", "SUMMARY"]);
    const KEEP = new Set(["UL", "OL", "BLOCKQUOTE", "FIGURE", "TABLE", "THEAD", "TBODY", "TFOOT", "TR", "DL", "PRE", "HR", "BR"]);
    let images = 0, links = 0;
    const absolute = (u) => { try { const x = new URL(u, doc.baseURI); return /^(https?|mailto):$/.test(x.protocol) ? x.href : null; } catch (e) { return null; } };
    const largest = (set) => {
      let pick = null, width = -1;
      for (const part of set.split(",")) {
        const [u, d] = part.trim().split(/\s+/);
        const w = d ? parseFloat(d) : 1;
        if (u && w > width) { pick = u; width = w; }
      }
      return pick;
    };
    const picture = (img) => {
      let u = img.currentSrc || img.getAttribute("src");
      for (const k of ["data-src", "data-lazy-src", "data-original", "data-hi-res-src"]) { const v = img.getAttribute(k); if (v && (!u || /^data:|placeholder|blank|spacer/.test(u))) u = v; }
      if (!u || /^data:/.test(u)) { const set = img.getAttribute("data-srcset") || img.getAttribute("srcset"); if (set) u = largest(set) || u; }
      if (!u || /^data:image\/(gif|svg)/.test(u)) return "";
      if (tokens(img).some((t) => BAD_IMG.has(t))) return "";
      if (img.naturalWidth && img.complete && Math.max(img.naturalWidth, img.naturalHeight) < 80) return "";
      const w = parseFloat(img.getAttribute("width") || "0"), h = parseFloat(img.getAttribute("height") || "0");
      if ((w && w < 60) || (h && h < 60)) return "";
      const src = absolute(u);
      if (!src || !/^https?:/.test(src)) return "";
      images++;
      return '<img src="' + attr(src) + '" alt="' + attr(img.getAttribute("alt") || "") + '">';
    };
    const hidden = (e) => {
      if (e.hidden || e.getAttribute("aria-hidden") === "true") return true;
      const s = getComputedStyle(e);
      return s.display === "none" || s.visibility === "hidden";
    };
    // The children of `node` as markup. In `flow` (a container), loose text and inline things are gathered into paragraphs.
    const children = (node, flow) => {
      let out = "", run = "";
      const flush = () => {
        const words = run.replace(/<[^>]*>|&nbsp;|\s/g, "");
        // Pictures standing alone are figures; with words round them, a paragraph.
        if (words) { for (const part of run.trim().split(/(?:<br>\s*){2,}/)) if (part.replace(/<[^>]*>|&nbsp;|\s/g, "")) out += "<p>" + part.trim() + "</p>"; } else if (run.includes("<img")) out += "<figure>" + run.trim() + "</figure>";
        run = "";
      };
      for (const c of node.childNodes) {
        if (c.nodeType === 3) { run += esc(c.nodeValue.replace(/\s+/g, " ")); continue; }
        if (c.nodeType !== 1) continue;
        const piece = element(c);
        if (!piece) continue;
        if (piece.block) {
          if (flow) flush(); else { out += run; run = ""; }
          out += piece.html;
        } else run += piece.html;
      }
      if (flow) flush(); else out += run;
      return out;
    };
    // `block` says the result stands on lines of its own.
    const element = (e) => {
      const tag = e.tagName;
      if (DROP.has(tag)) return null;
      if (hidden(e)) return null;
      if (tag === "IMG") { const h = picture(e); return h ? { html: h, block: false } : null; }
      if (tag === "PICTURE") { const img = e.querySelector("img"); const h = img ? picture(img) : ""; return h ? { html: h, block: false } : null; }
      if (tag === "BR") return { html: "<br>", block: false };
      if (tag === "HR") return { html: "<hr>", block: true };
      // Named as furniture (a share bar, a comment box) it goes, unless it is the better part of the page.
      const tl = text(e).length;
      if (junk(e) && (tl < 600 || density(e) > 0.25)) return null;
      if (tag === "A") {
        const href = e.getAttribute("href") || "";
        const inner = children(e, false);
        if (!inner.replace(/<[^>]*>|\s/g, "") && !inner.includes("<img")) return null;
        const url = href && href[0] !== "#" ? absolute(href) : null;
        if (!url) return { html: inner, block: false };
        links++;
        return { html: '<a href="' + attr(url) + '">' + inner + "</a>", block: false };
      }
      if (INLINE.has(tag)) {
        const inner = children(e, false);
        if (!inner.replace(/<[^>]*>|\s/g, "")) return null;
        const name = tag.toLowerCase();
        return { html: "<" + name + ">" + inner + "</" + name + ">", block: false };
      }
      // Lists, boxes and the like made mostly of links are the page's furniture.
      if (tag === "UL" || tag === "OL" || tag === "DL" || tag === "DIV" || tag === "SECTION" || tag === "TABLE") {
        if (tl < 400 && density(e) > 0.6) return null;
      }
      if (/^H[1-6]$/.test(tag)) {
        const inner = children(e, false);
        if (!inner.replace(/<[^>]*>|\s/g, "")) return null;
        const level = tag === "H1" ? "h2" : tag.toLowerCase();
        return { html: "<" + level + ">" + inner + "</" + level + ">", block: true };
      }
      if (tag === "P") {
        const inner = children(e, false);
        if (!inner.replace(/<[^>]*>|&nbsp;|\s/g, "") && !inner.includes("<img")) return null;
        return { html: "<p>" + inner.trim() + "</p>", block: true };
      }
      if (tag === "PRE") {
        const code = e.textContent.replace(/\n+$/, "");
        if (!code.trim()) return null;
        return { html: "<pre>" + esc(code) + "</pre>", block: true };
      }
      if (tag === "FIGURE") {
        const inner = children(e, true);
        if (!inner.replace(/<[^>]*>|\s/g, "") && !inner.includes("<img")) return null;
        return { html: "<figure>" + inner + "</figure>", block: true };
      }
      if (tag === "TABLE") {
        // A little table with no headings is a caption or a box, not data.
        if (tl < 120 && !e.querySelector("th")) return null;
        return { html: "<table>" + children(e, false) + "</table>", block: true };
      }
      if (tag === "LI" || tag === "TD" || tag === "TH" || tag === "DT" || tag === "DD" || tag === "FIGCAPTION" || tag === "CAPTION" || tag === "SUMMARY") {
        const inner = children(e, false);
        if (!inner.replace(/<[^>]*>|&nbsp;|\s/g, "") && !inner.includes("<img")) return tag === "TD" || tag === "TH" ? { html: "<td></td>", block: true } : null;
        const name = tag === "SUMMARY" ? "p" : tag.toLowerCase();
        return { html: "<" + name + ">" + inner.trim() + "</" + name + ">", block: true };
      }
      if (KEEP.has(tag)) {
        const inner = children(e, false);
        if (!inner.replace(/<[^>]*>|\s/g, "") && !inner.includes("<img")) return null;
        const name = tag.toLowerCase();
        return { html: "<" + name + ">" + inner + "</" + name + ">", block: true };
      }
      // Anything else (div, section, span, article, font, centre…) is only a container: its content stays, it goes.
      // A span laid out as a box (a byline over a place, a date over a time) is a block, as the page shows it.
      const inlineTag = ["SPAN", "FONT", "LABEL", "SMALL", "BDI", "BDO", "TIME", "DATA"].includes(tag);
      const flow = !inlineTag || !getComputedStyle(e).display.startsWith("inline");
      const inner = children(e, flow);
      if (!inner) return null;
      return { html: inner, block: flow };
    };
    let html = children(top, true);
    // Parsed in a document of its own that has no page and so loads nothing: its pictures are not fetched twice.
    const kept = doc.implementation.createHTMLDocument("").createElement("div");
    kept.innerHTML = html;
    const words = (kept.textContent.match(/\S+/g) || []).length;
    const keptLinks = kept.querySelectorAll("a").length;
    const keptParagraphs = kept.querySelectorAll("p").length;
    const keptText = kept.textContent.replace(/\s+/g, " ").trim().length;
    const keptLinkLength = [...kept.querySelectorAll("a")].reduce((n, a) => n + a.textContent.length, 0);
    const meta = (n) => { const m = doc.querySelector('meta[property="' + n + '"], meta[name="' + n + '"]'); return m ? (m.getAttribute("content") || "").trim() : ""; };
    const ld = [...doc.querySelectorAll('script[type="application/ld+json"]')].some((s) => /"@type"\s*:\s*\[?\s*"(News|Blog|Tech|Scholarly)?Article"|"BlogPosting"|"Report"/.test(s.textContent || ""));
    const signal = /article/i.test(meta("og:type")) || ld || !!doc.querySelector("article, [itemprop=articleBody]");
    const home = location.pathname === "/" || location.pathname === "";
    const readable = words >= 120 && keptParagraphs >= 3 && keptText > 0 && keptLinkLength / keptText < 0.35 && !(home && !signal);
    if (probe) return { ok: readable, words: words, ms: performance.now() - started,
      why: top.tagName.toLowerCase() + (top.id ? "#" + top.id : "") + " p" + keptParagraphs + " links " + Math.round(100 * keptLinkLength / Math.max(1, keptText)) + "% home " + home + " signal " + signal };
    if (!readable) return null;

    let title = "";
    const heading = top.querySelector("h1") || doc.querySelector("h1");
    const clean = (s) => s.replace(/\s+/g, " ").trim();
    const site = meta("og:site_name") || location.hostname.replace(/^www\./, "");
    if (heading && text(heading).length > 8 && text(heading).length < 220) title = text(heading);
    if (!title) title = clean(meta("og:title") || meta("twitter:title") || doc.title || "").replace(/\s+[|–—-]\s+[^|–—-]{2,40}$/, "");
    // The first heading of the text is the title again.
    if (title) {
      const first = kept.querySelector("h2");
      if (first && clean(first.textContent) === title) { first.remove(); html = kept.innerHTML; }
    }
    let byline = clean(meta("author") || meta("article:author") || "");
    if (!byline || /^https?:/.test(byline)) {
      const b = doc.querySelector('[rel="author"], [itemprop="author"], .byline, .author, [class*="byline"]');
      byline = b ? clean(b.textContent) : "";
    }
    byline = byline.replace(/^by\s*/i, "");
    if (byline.length > 100 || byline.length < 3) byline = "";
    const t = doc.querySelector("time[datetime]");
    const date = meta("article:published_time") || meta("date") || (t ? t.getAttribute("datetime") : "") || "";
    const dir = (doc.documentElement.dir || getComputedStyle(doc.body).direction || "ltr").toLowerCase();
    return { title, byline, site, date, lang: doc.documentElement.lang || "", rtl: dir === "rtl", html: kept.innerHTML,
             words: words, paragraphs: keptParagraphs, images: images, links: keptLinks, ms: performance.now() - started, url: location.href,
             page: { elements: doc.getElementsByTagName("*").length, scripts: doc.scripts.length, frames: doc.querySelectorAll("iframe, frame, object, embed").length,
                     forms: doc.forms.length, chars: (doc.body.innerText || "").length } };
    """#

    /// The same page, whatever the fragment says.
    static func same(_ a: URL, _ b: URL) -> Bool {
        var x = URLComponents(url: a, resolvingAgainstBaseURL: false), y = URLComponents(url: b, resolvingAgainstBaseURL: false)
        x?.fragment = nil
        y?.fragment = nil
        return x?.string == y?.string
    }

    /// Asks the page's own process: the article, or nil if it has none.
    static func read(_ web: WKWebView, probe: Bool) async -> [String: Any]? {
        do {
            let result = try await web.callAsyncJavaScript(script, arguments: ["probe": probe], in: nil, contentWorld: world)
            if !(result is [String: Any]) { Debug.log("reader", "the script answered \(String(describing: result).prefix(200))") }
            return result as? [String: Any]
        } catch {
            Debug.log("reader", "the script failed: \(error.localizedDescription)")
            return nil
        }
    }

    static func article(_ web: WKWebView) async -> Article? {
        guard let found = await read(web, probe: false) else {
            Debug.log("reader", "the page gave no article")
            return nil
        }
        guard let html = found["html"] as? String, let title = found["title"] as? String else {
            Debug.log("reader", "the answer lacks text: \(found.keys.sorted())")
            return nil
        }
        let url = (found["url"] as? String).flatMap(URL.init(string:)) ?? web.url ?? URL(string: "about:blank")!
        var date: Date?
        if let text = found["date"] as? String, !text.isEmpty {
            date = ISO8601DateFormatter().date(from: text) ?? {
                let full = ISO8601DateFormatter()
                full.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                return full.date(from: text) ?? ISO8601DateFormatter().date(from: text + "T00:00:00Z")
            }()
        }
        return Article(title: title, byline: (found["byline"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                       site: found["site"] as? String ?? url.host() ?? "", date: date, lang: found["lang"] as? String ?? "",
                       rtl: found["rtl"] as? Bool ?? false, html: html, words: found["words"] as? Int ?? 0,
                       paragraphs: found["paragraphs"] as? Int ?? 0, images: found["images"] as? Int ?? 0, url: url,
                       took: found["ms"] as? Double ?? 0, page: found["page"] as? [String: Int] ?? [:])
    }
}

// MARK: - how it looks

/// What the person chose: kept for every page.
@Observable
final class ReaderPrefs {
    static let shared = ReaderPrefs()
    static let changed = Notification.Name("BasicShell.ReaderPrefsChanged")

    enum Theme: String, CaseIterable { case auto, light, sepia, dark }
    enum Face: String, CaseIterable { case serif, sans }
    enum Measure: String, CaseIterable { case narrow, medium, wide }

    /// Text sizes in points, and where the middle is.
    static let sizes: [Double] = [15, 17, 19, 21, 24, 28, 33]

    var theme: Theme { didSet { save("reader.theme", theme.rawValue) } }
    var face: Face { didSet { save("reader.face", face.rawValue) } }
    var measure: Measure { didSet { save("reader.measure", measure.rawValue) } }
    var size: Int { didSet { size = min(max(size, 0), ReaderPrefs.sizes.count - 1); save("reader.size", size) } }

    private init() {
        let defaults = UserDefaults.standard
        theme = Theme(rawValue: defaults.string(forKey: "reader.theme") ?? "") ?? .auto
        face = Face(rawValue: defaults.string(forKey: "reader.face") ?? "") ?? .serif
        measure = Measure(rawValue: defaults.string(forKey: "reader.measure") ?? "") ?? .medium
        size = defaults.object(forKey: "reader.size") as? Int ?? 2
    }

    private func save(_ key: String, _ value: Any) {
        UserDefaults.standard.set(value, forKey: key)
        NotificationCenter.default.post(name: ReaderPrefs.changed, object: nil)
    }

    /// The script that puts these on the page shown.
    var script: String {
        let width = ["narrow": "560px", "medium": "680px", "wide": "820px"][measure.rawValue] ?? "680px"
        let font = face == .serif ? #""New York", "Iowan Old Style", Georgia, "Times New Roman", serif"# : #"-apple-system, "SF Pro Text", "Helvetica Neue", sans-serif"#
        return """
        const root = document.documentElement;
        root.dataset.theme = "\(theme.rawValue)";
        root.style.setProperty("--size", "\(ReaderPrefs.sizes[size])px");
        root.style.setProperty("--measure", "\(width)");
        root.style.setProperty("--font", '\(font.replacingOccurrences(of: "'", with: "\\'"))');
        """
    }
}

/// The page BasicShell writes round the article.
enum ReaderPage {
    static func html(_ article: Reader.Article, prefs: ReaderPrefs) -> String {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        }
        var meta: [String] = []
        if let byline = article.byline { meta.append(esc(byline)) }
        if let date = article.date { meta.append(esc(date.formatted(date: .long, time: .omitted))) }
        let minutes = max(1, Int((Double(article.words) / 230).rounded()))
        meta.append("\(minutes) min read")
        let lang = article.lang.isEmpty ? "" : " lang=\"\(esc(article.lang))\""
        return """
        <!doctype html><html\(lang) dir="\(article.rtl ? "rtl" : "ltr")"><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src https: data:; style-src 'unsafe-inline'">
        <meta name="viewport" content="width=device-width, initial-scale=1"><meta name="color-scheme" content="light dark">
        <title>\(esc(article.title))</title><style>\(css)</style></head>
        <body><main><header><p class="site">\(esc(article.site))</p><h1>\(esc(article.title))</h1>
        <p class="meta">\(meta.joined(separator: " · "))</p></header><article>\(article.html)</article></main></body></html>
        """
    }

    private static let css = """
    :root { --bg: #ffffff; --fg: #1d1d1f; --muted: #6e6e73; --rule: rgba(0,0,0,.12); --tint: rgba(0,0,0,.05); --link: #0a58d0;
            --size: 19px; --measure: 680px; --font: "New York", Georgia, serif; }
    @media (prefers-color-scheme: dark) { :root { --bg: #1c1c1e; --fg: #e8e8ea; --muted: #98989f; --rule: rgba(255,255,255,.16); --tint: rgba(255,255,255,.07); --link: #6cb0ff; } }
    :root[data-theme="light"] { --bg: #ffffff; --fg: #1d1d1f; --muted: #6e6e73; --rule: rgba(0,0,0,.12); --tint: rgba(0,0,0,.05); --link: #0a58d0; color-scheme: light; }
    :root[data-theme="sepia"] { --bg: #f4ecd8; --fg: #3f3224; --muted: #7b6a55; --rule: rgba(63,50,36,.2); --tint: rgba(63,50,36,.07); --link: #8a4b12; color-scheme: light; }
    :root[data-theme="dark"] { --bg: #1c1c1e; --fg: #e8e8ea; --muted: #98989f; --rule: rgba(255,255,255,.16); --tint: rgba(255,255,255,.07); --link: #6cb0ff; color-scheme: dark; }
    * { box-sizing: border-box; }
    html { background: var(--bg); color: var(--fg); -webkit-text-size-adjust: none; }
    body { margin: 0; font: var(--size)/1.6 var(--font); text-rendering: optimizeLegibility; overflow-wrap: break-word; }
    main { max-width: var(--measure); margin: 0 auto; padding: 64px 28px 96px; }
    header { margin-bottom: 2em; }
    .site { font: 600 .62em/1 -apple-system, sans-serif; letter-spacing: .08em; text-transform: uppercase; color: var(--muted); margin: 0 0 1.1em; }
    h1 { font-size: 1.9em; line-height: 1.18; margin: 0 0 .5em; letter-spacing: -.01em; }
    .meta { font: .72em/1.4 -apple-system, sans-serif; color: var(--muted); margin: 0; }
    article > :first-child { margin-top: 0; }
    p { margin: 0 0 1.05em; }
    h2, h3, h4, h5, h6 { line-height: 1.25; margin: 1.8em 0 .5em; }
    h2 { font-size: 1.4em; } h3 { font-size: 1.2em; } h4, h5, h6 { font-size: 1em; }
    a { color: var(--link); text-decoration: none; border-bottom: 1px solid color-mix(in srgb, var(--link) 35%, transparent); }
    img { display: block; max-width: 100%; height: auto; margin: 1.4em auto; border-radius: 6px; }
    p img, li img, td img { display: inline; margin: 0; }
    figure { margin: 1.6em 0; } figure img { margin: 0 auto; }
    figcaption { font: .72em/1.45 -apple-system, sans-serif; color: var(--muted); margin-top: .7em; text-align: center; }
    blockquote { margin: 1.4em 0; padding: .1em 0 .1em 1.1em; border-inline-start: 3px solid var(--rule); color: var(--muted); }
    ul, ol { padding-inline-start: 1.4em; margin: 0 0 1.05em; } li { margin: .3em 0; }
    hr { border: 0; border-top: 1px solid var(--rule); margin: 2em 0; }
    pre { font: .8em/1.5 ui-monospace, "SF Mono", Menlo, monospace; background: var(--tint); padding: .9em 1em; border-radius: 8px; overflow-x: auto; white-space: pre; }
    code, kbd, samp { font: .86em ui-monospace, "SF Mono", Menlo, monospace; background: var(--tint); padding: .08em .3em; border-radius: 4px; }
    table { display: block; overflow-x: auto; border-collapse: collapse; margin: 1.4em 0; font: .8em/1.45 -apple-system, sans-serif; }
    td, th { border: 1px solid var(--rule); padding: .4em .7em; text-align: start; vertical-align: top; }
    th { background: var(--tint); }
    sup, sub { line-height: 0; }
    ::selection { background: color-mix(in srgb, var(--link) 30%, transparent); }
    """
}

// MARK: - the view

/// The article over the page: a web view of BasicShell's own page, and a small bar at its top right.
final class ReaderView: NSView, WKNavigationDelegate, WKUIDelegate {
    let web: WKWebView
    let article: Reader.Article
    private weak var tab: Tab?
    private let controls: NSHostingView<ReaderBar>
    private var watching: NSObjectProtocol?

    init(article: Reader.Article, tab: Tab, close: @escaping () -> Void) {
        self.article = article
        self.tab = tab
        let config = WKWebViewConfiguration()
        // The page's own session, so a picture behind a sign-in is still there; a private tab's own private store.
        if let store = tab.webView?.configuration.websiteDataStore { config.websiteDataStore = store }
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.mediaTypesRequiringUserActionForPlayback = .all
        web = WKWebView(frame: .zero, configuration: config)
        var options: () -> Void = {}
        controls = NSHostingView(rootView: ReaderBar(appearance: { options() }, close: close))
        super.init(frame: .zero)
        options = { [weak self] in self?.showOptions() }
        autoresizingMask = [.width, .height]
        web.navigationDelegate = self
        web.uiDelegate = self
        web.autoresizingMask = [.width, .height]
        web.allowsLinkPreview = false
        addSubview(web)
        controls.sizingOptions = []
        controls.safeAreaRegions = []
        addSubview(controls, positioned: .above, relativeTo: web)
        web.loadHTMLString(ReaderPage.html(article, prefs: .shared), baseURL: article.url)
        watching = NotificationCenter.default.addObserver(forName: ReaderPrefs.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.apply() }
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    private var popover: NSPopover?

    /// "Aa": how the article looks, in a popover under the bar (a window of its own, so that it is not cut off at the page's edge).
    private func showOptions() {
        if let popover, popover.isShown { return popover.close() }
        let popover = NSPopover()
        popover.contentViewController = NSHostingController(rootView: ReaderOptions(prefs: .shared))
        popover.behavior = .transient
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        popover.show(relativeTo: controls.bounds, of: controls, preferredEdge: .minY)
        self.popover = popover
    }

    /// The reader is closed: it no longer listens.
    func stop() {
        if let watching { NotificationCenter.default.removeObserver(watching) }
        watching = nil
        popover?.close()
        web.stopLoading()
        web.navigationDelegate = nil
        web.uiDelegate = nil
    }

    override func layout() {
        super.layout()
        web.frame = bounds
        let size = NSSize(width: 92, height: 34)
        controls.frame = NSRect(x: bounds.maxX - size.width - 18, y: isFlipped ? 14 : bounds.maxY - size.height - 14,
                                width: size.width, height: size.height)
    }

    /// The chosen look, put on the page (BasicShell's own: the script is the app's, run in the app's world).
    func apply() {
        let script = ReaderPrefs.shared.script
        Task { [web] in _ = try? await web.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: .defaultClient) }
        let colors: [ReaderPrefs.Theme: NSColor] = [.light: .white, .sepia: NSColor(srgbRed: 0.957, green: 0.925, blue: 0.847, alpha: 1),
                                                    .dark: NSColor(srgbRed: 0.11, green: 0.11, blue: 0.118, alpha: 1)]
        web.underPageBackgroundColor = colors[ReaderPrefs.shared.theme] ?? .windowBackgroundColor
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        apply()
        if Debug.enabled { audit() }
    }

    /// For the log, what the article page holds: counted, to show that nothing of the site came with it.
    private func audit() {
        let script = """
        const all = [...document.querySelectorAll("*")], tags = {};
        for (const e of all) tags[e.tagName] = (tags[e.tagName] || 0) + 1;
        const hosts = new Set([...document.images].map((i) => { try { return new URL(i.src).host; } catch (e) { return "?"; } }));
        return JSON.stringify({ elements: all.length, scripts: tags.SCRIPT || 0, frames: (tags.IFRAME || 0) + (tags.FRAME || 0) + (tags.OBJECT || 0) + (tags.EMBED || 0),
          forms: (tags.FORM || 0) + (tags.INPUT || 0) + (tags.BUTTON || 0) + (tags.SELECT || 0) + (tags.TEXTAREA || 0),
          withClass: all.filter((e) => e.hasAttribute("class") && !e.closest("head")).length, withStyle: all.filter((e) => e.hasAttribute("style")).length,
          handlers: all.filter((e) => [...e.attributes].some((a) => a.name.startsWith("on"))).length,
          images: document.images.length, imageHosts: [...hosts], chars: document.body.innerText.length });
        """
        let article = article
        Task { [web] in
            let found = try? await web.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: .defaultClient)
            Debug.log("reader", "audit \(article.url.host() ?? ""): reader \(found as? String ?? "?") | page \(article.page)")
        }
    }

    /// The article's own links lead away from it, to the tab (⌘-click: a new one); nothing else is let load.
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        guard action.navigationType == .linkActivated, let url = action.request.url else {
            return decisionHandler(action.navigationType == .other ? .allow : .cancel)
        }
        decisionHandler(.cancel)
        guard let tab else { return }
        let background = action.modifierFlags.contains(.command)
        if background {
            tab.host?.open(url, from: tab, select: false)
        } else {
            (tab.host as? BrowserWindow)?.closeReader(of: tab)
            tab.load(url)
        }
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = action.request.url, let tab { tab.host?.open(url, from: tab, select: true) }
        return nil
    }
}

/// "Aa" for how it looks, and a cross to close it.
struct ReaderBar: View {
    let appearance: () -> Void
    let close: () -> Void

    var body: some View {
        HStack(spacing: 2) {
            Button(action: appearance) {
                Text("Aa").font(.system(size: 13, weight: .semibold)).frame(width: 36, height: 28).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Text size, font, colors")
            .accessibilityLabel("Reader appearance")
            Button(action: close) {
                Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).frame(width: 30, height: 28).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close Reader (Esc)")
            .accessibilityLabel("Close Reader")
        }
        .padding(.horizontal, 4)
        .glassEffect(.regular, in: .capsule)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ReaderOptions: View {
    let prefs: ReaderPrefs

    var body: some View {
        @Bindable var prefs = prefs
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Button { prefs.size -= 1 } label: { Text("A").font(.system(size: 12, weight: .medium)).frame(maxWidth: .infinity) }
                    .disabled(prefs.size == 0)
                    .accessibilityLabel("Smaller text")
                Button { prefs.size += 1 } label: { Text("A").font(.system(size: 20, weight: .medium)).frame(maxWidth: .infinity) }
                    .disabled(prefs.size == ReaderPrefs.sizes.count - 1)
                    .accessibilityLabel("Larger text")
            }
            .buttonStyle(.glass)
            Picker("Font", selection: $prefs.face) {
                Text("Serif").tag(ReaderPrefs.Face.serif)
                Text("Sans").tag(ReaderPrefs.Face.sans)
            }
            .pickerStyle(.segmented)
            Picker("Colors", selection: $prefs.theme) {
                Text("Auto").tag(ReaderPrefs.Theme.auto)
                Text("Light").tag(ReaderPrefs.Theme.light)
                Text("Sepia").tag(ReaderPrefs.Theme.sepia)
                Text("Dark").tag(ReaderPrefs.Theme.dark)
            }
            .pickerStyle(.segmented)
            Picker("Width", selection: $prefs.measure) {
                Text("Narrow").tag(ReaderPrefs.Measure.narrow)
                Text("Medium").tag(ReaderPrefs.Measure.medium)
                Text("Wide").tag(ReaderPrefs.Measure.wide)
            }
            .pickerStyle(.segmented)
        }
        .labelsHidden()
        .padding(16)
        .frame(width: 270)
    }
}

// MARK: - the tab and the window

extension Tab {
    /// Whether the page has an article to show: asked once the page has loaded.
    var hasArticle: Bool { readerState.available }
    var isReading: Bool { readerState.view != nil }

    /// The page just began a new document: what was read of the last is no longer true.
    func readerPageChanged() {
        readerState.available = false
        readerState.probed = false
        readerState.probing = false
        if readerState.view != nil { (host as? BrowserWindow)?.closeReader(of: self) }
    }

    /// Asks the finished page whether it has an article; once per page, and only for the tab on show.
    func probeReader() {
        guard !readerState.probed, !readerState.probing, !isFrozen, !isUnloaded, let web = webView, !web.isLoading,
              let url = web.url, url.scheme == "http" || url.scheme == "https" else { return }
        readerState.probing = true
        Task { [weak self, weak web] in
            guard let web else { return }
            let found = await Reader.read(web, probe: true)
            guard let self, self.webView === web else { return }
            self.readerState.probing = false
            self.readerState.probed = true
            self.readerState.available = found?["ok"] as? Bool ?? false
            if let found { Debug.log("reader", "probe \(url.host() ?? ""): \(found["ok"] as? Bool ?? false) \(found["words"] ?? 0) words in \(String(format: "%.1f", found["ms"] as? Double ?? 0)) ms (\(found["why"] ?? ""))") }
        }
    }
}

/// What a tab keeps of Reader. Observed, so that the top bar's button follows it.
@Observable
final class ReaderState {
    var available = false
    @ObservationIgnored var probed = false
    @ObservationIgnored var probing = false
    @ObservationIgnored var view: ReaderView?
}

extension BrowserWindow {
    @objc func toggleReader(_ sender: Any?) {
        guard let tab = shell.selected else { return }
        if tab.isReading { return closeReader(of: tab) }
        guard tab.hasArticle || !tab.readerState.probed else { return say("There is no article to show here") }
        openReader(of: tab)
    }

    func openReader(of tab: Tab) {
        guard tab.readerState.view == nil, let web = tab.webView else { return }
        Task { [weak self, weak tab, weak web] in
            guard let web, let article = await Reader.article(web), let self, let tab, tab.webView === web, tab.readerState.view == nil else {
                Debug.log("reader", "no article when opened")
                self?.say("There is no article to show here")
                tab?.readerState.available = false
                return
            }
            let view = ReaderView(article: article, tab: tab) { [weak self, weak tab] in
                if let tab { self?.closeReader(of: tab) }
            }
            tab.readerState.view = view
            tab.readerState.available = true
            Debug.log("reader", "opened \(article.url.host() ?? ""): \(article.words) words, \(article.paragraphs) paragraphs, \(article.images) images; read in \(String(format: "%.1f", article.took)) ms")
            if tab === self.shell.selected { self.showReader(of: tab) }
        }
    }

    /// The reader of the tab shown goes over its page, the others' are out of the window.
    func showReader(of tab: Tab) {
        guard let view = tab.readerState.view, let web = tab.webView, web.superview != nil else { return }
        view.frame = web.superview?.bounds ?? .zero
        web.superview?.addSubview(view, positioned: .above, relativeTo: nil)
        // Hidden under the article: VoiceOver would otherwise read both, and a hidden page costs nothing to draw.
        web.isHidden = true
        view.needsLayout = true
        view.apply()
        window?.makeFirstResponder(view.web)
        if shell.finding { findChanged() }
    }

    func closeReader(of tab: Tab) {
        guard let view = tab.readerState.view else { return }
        if shell.finding, tab === shell.selected { finder.clear(view.web) }
        view.removeFromSuperview()
        view.stop()
        tab.readerState.view = nil
        tab.webView?.isHidden = false
        if tab === shell.selected, let web = tab.webView {
            window?.makeFirstResponder(web)
            if shell.finding { findChanged() }
        }
    }

    /// Where Find, the screenshot and the like look: the article when it is over the page.
    var shownWeb: WKWebView? { shell.selected?.readerState.view?.web ?? shell.selected?.webView }
}
