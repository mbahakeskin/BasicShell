import AppKit
import Observation
import WebKit

// A download button over photos and videos, on the sites the person lists
// (Settings › General; none until they add one).
//
// On a listed site, a small button comes up in the corner of a photo or a
// video while the pointer is over it, and saves what is shown: the largest
// picture the page offers for it, or the video's own file. A script in a
// world of BasicShell's own does the watching, so the page can't see it, and
// it goes only into pages of the listed sites (and the frames inside them,
// where players mostly are), and no others. The file goes
// through the Downloads panel like any other, on the page's own session
// (its sign-ins), with the page as its referrer.
//
// Videos a site sends in pieces (a `blob:` address, as most social sites do)
// have no file to save, and the button says so rather than saving nothing.
@MainActor @Observable
final class MediaDownload: NSObject, WKScriptMessageHandler {
    static let shared = MediaDownload()
    static let world = WKContentWorld.world(name: "BasicShellMedia")
    static let name = "basicshellMedia"
    static let key = "mediadl.sites"

    /// The sites, as written down: no scheme, no www, no path, no port.
    private(set) var sites: [String] = UserDefaults.standard.stringArray(forKey: MediaDownload.key) ?? []

    /// "https://www.Example.com/a/b" and "example.com" are the same site.
    static func normalized(_ text: String) -> String? {
        var site = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let range = site.range(of: "://") { site = String(site[range.upperBound...]) }
        site = String(site.prefix { !"/?#:".contains($0) })   // no path, no port
        if site.hasPrefix("www.") { site = String(site.dropFirst(4)) }
        guard site.contains("."), !site.contains(" "), !site.hasPrefix("."), !site.hasSuffix(".") else { return nil }
        return site
    }

    @discardableResult
    func add(_ text: String) -> Bool {
        guard let site = MediaDownload.normalized(text) else { return false }
        if !sites.contains(site) {
            sites = (sites + [site]).sorted()
            save()
        }
        return true
    }

    func remove(_ site: String) {
        sites.removeAll { $0 == site }
        save()
    }

    private func save() {
        UserDefaults.standard.set(sites, forKey: MediaDownload.key)
        reapply()
    }

    /// Whether a page on this address is one of the listed sites, or a
    /// subdomain of one.
    func covers(_ url: URL?) -> Bool {
        guard !sites.isEmpty, let host = url?.host()?.lowercased(), ["http", "https"].contains(url?.scheme?.lowercased() ?? "") else { return false }
        return sites.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    // MARK: - in a tab

    /// The script that goes into `tab`'s next document, which comes from
    /// `url`: the one of the page up now taken out, and, on a listed site,
    /// the new one put in. No other page gets anything.
    func arm(_ tab: Tab, for url: URL?) {
        guard WKUserContentController.canRemoveScripts, let controller = tab.webView?.configuration.userContentController else { return }
        controller.removeUserScripts(in: MediaDownload.world)
        // What the page loads is watched only on the listed sites.
        tab.sniff(covers(url))
        guard covers(url) else { return }
        controller.addUserScript(WKUserScript(source: MediaDownload.script, injectionTime: .atDocumentEnd, forMainFrameOnly: false, in: MediaDownload.world))
    }

    /// The list changed: every tab's next page, and the page each shows now.
    func reapply() {
        for window in Windows.all {
            for tab in window.shell.allTabs {
                guard let web = tab.webView, !tab.isUnloaded else { continue }
                arm(tab, for: web.url)
                let script = covers(web.url) ? MediaDownload.script : "window.__basicshellMedia && window.__basicshellMedia.off()"
                web.evaluateJavaScript(script, in: nil, in: MediaDownload.world) { _ in }
            }
        }
    }

    // MARK: - saving

    nonisolated func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let said = message.body as? [String: Any] else { return }
        MainActor.assumeIsolated {
            guard let web = message.webView, covers(web.url),
                  let tab = Windows.all.lazy.compactMap({ $0.shell.allTabs.first { $0.webView === web } }).first
            else { return }
            let window = tab.host as? BrowserWindow
            if said["stream"] as? Bool == true {
                // Sent in pieces: what the page has been loading says where they are.
                if let plan = tab.sniffer?.plan() {
                    StreamSaver.save(plan, from: tab, in: window)
                } else {
                    window?.say("Play the video for a moment, then press the button again")
                }
                return
            }
            guard let text = said["url"] as? String, let url = URL(string: text),
                  ["http", "https"].contains(url.scheme?.lowercased() ?? "")
            else {
                window?.say("Nothing to save here")
                return
            }
            let framePage = (said["page"] as? String).flatMap(URL.init(string:)) ?? web.url
            // A video whose address is a playlist (WebKit plays those itself,
            // whatever the address ends in) is saved piece by piece, not as that text.
            if said["video"] as? Bool == true {
                Task { @MainActor in
                    if await StreamSaver.isPlaylist(url, page: framePage, in: tab) {
                        StreamSaver.save(.playlist(url, referer: framePage), from: tab, in: window)
                    } else {
                        self.download(url, page: framePage, in: web, window: window)
                    }
                }
                return
            }
            download(url, page: framePage, in: web, window: window)
        }
    }

    /// A file as it is, through the Downloads panel, on the page's own
    /// session, with the page it was in as its referrer.
    private func download(_ url: URL, page: URL?, in web: WKWebView, window: BrowserWindow?) {
        var request = URLRequest(url: url)
        if let page { request.setValue(page.absoluteString, forHTTPHeaderField: "Referer") }
        web.startDownload(using: request) { download in
            MainActor.assumeIsolated { Downloads.shared.adopt(download) }
        }
        window?.say("Saving \(url.lastPathComponent.isEmpty ? "the file" : url.lastPathComponent)")
    }

    // MARK: - the script

    static let script = #"""
    (function () {
      if (window.__basicshellMedia) return;
      // Players are mostly in a frame of their own (the page's, or another
      // site's): each frame watches its own document. A frame is often loaded
      // at no size at all (a player kept hidden behind an ad) and grows later,
      // so its size is looked at when the pointer is over something, not now.
      var post = function (m) { try { webkit.messageHandlers.basicshellMedia.postMessage(m); } catch (e) {} };
      var host = document.createElement('div');
      host.style.cssText = 'all:initial;position:fixed;top:0;left:0;width:0;height:0;z-index:2147483647;pointer-events:none';
      var root = host.attachShadow({ mode: 'closed' });
      root.innerHTML = '<style>'
        + 'button{all:initial;position:fixed;display:none;box-sizing:border-box;width:32px;height:32px;border-radius:16px;'
        + 'background:rgba(20,20,20,.72);cursor:pointer;pointer-events:auto;align-items:center;justify-content:center;'
        + 'box-shadow:0 1px 6px rgba(0,0,0,.35)}'
        + 'button:hover{background:rgba(0,0,0,.92)}'
        + 'svg{width:16px;height:16px;stroke:#fff;fill:none;stroke-width:1.8;stroke-linecap:round;stroke-linejoin:round}'
        + '</style><button type="button" aria-label="Download"><svg viewBox="0 0 16 16"><path d="M8 2v8M4.5 7 8 10.5 11.5 7M3 13h10"/></svg></button>';
      var button = root.querySelector('button');
      var attached = false;

      var current = null, over = false, hideTimer = 0, frame = 0, x = 0, y = 0, on = true;
      var big = function (el) { var r = el.getBoundingClientRect(); return r.width >= 120 && r.height >= 90; };
      var media = function (el) {
        if (el.tagName === 'IMG') return !!(el.currentSrc || el.src) && big(el);
        if (el.tagName === 'VIDEO') return big(el);
        return false;
      };
      // What is under the pointer, even beneath a transparent layer a site
      // puts over its pictures.
      var find = function (px, py) {
        var list = document.elementsFromPoint(px, py);
        for (var i = 0; i < list.length; i++) if (media(list[i])) return list[i];
        return null;
      };
      var place = function (el) {
        // Only now is there anything of ours in the page.
        if (!attached) { attached = true; document.documentElement.appendChild(host); }
        var r = el.getBoundingClientRect();
        button.style.left = Math.max(Math.min(r.right, innerWidth) - 40, 4) + 'px';
        button.style.top = (Math.max(r.top, 0) + 8) + 'px';
        button.style.display = 'flex';
      };
      var hide = function () {
        hideTimer = 0;
        if (over) return;
        current = null;
        button.style.display = 'none';
      };
      var move = function (e) {
        x = e.clientX; y = e.clientY;
        if (frame || !on) return;
        frame = requestAnimationFrame(function () {
          frame = 0;
          if (!on) return;
          var el = find(x, y);
          if (el) { clearTimeout(hideTimer); hideTimer = 0; current = el; place(el); }
          else if (!over && current && !hideTimer) hideTimer = setTimeout(hide, 250);
        });
      };
      var scrolled = function () { if (on && current) place(current); };
      button.addEventListener('pointerenter', function () { over = true; clearTimeout(hideTimer); hideTimer = 0; });
      button.addEventListener('pointerleave', function () { over = false; hideTimer = setTimeout(hide, 250); });

      var absolute = function (u) { try { return new URL(u, document.baseURI).href; } catch (e) { return ''; } };
      // The largest picture the page offers for an image: what a srcset
      // lists, or the file a link around it goes to, or what is shown.
      var largest = function (img) {
        var best = absolute(img.currentSrc || img.src), top = img.naturalWidth || 0;
        var a = img.closest('a[href]');
        if (a && /\.(jpe?g|png|webp|gif|avif)(\?|#|$)/i.test(a.href)) return a.href;
        var set = img.srcset || '';
        set.split(/,\s+/).forEach(function (part) {
          var bits = part.trim().split(/\s+/);
          if (!bits[0]) return;
          var d = bits[1] || '', n = parseFloat(d) || 0;
          var width = /w$/i.test(d) ? n : /x$/i.test(d) ? n * (img.getBoundingClientRect().width || 1) : 0;
          if (width > top) { top = width; best = absolute(bits[0]); }
        });
        return best;
      };
      button.addEventListener('click', function (e) {
        e.preventDefault(); e.stopPropagation();
        var el = current;
        if (!el) return;
        if (el.tagName === 'VIDEO') {
          var src = el.currentSrc || el.src || ((el.querySelector('source') || {}).src) || '';
          if (!src || src.indexOf('blob:') === 0) return post({ stream: true, page: location.href });
          return post({ url: absolute(src), page: location.href, video: true });
        }
        post({ url: largest(el), page: location.href });
      }, true);

      document.addEventListener('pointermove', move, { capture: true, passive: true });
      document.addEventListener('scroll', scrolled, { capture: true, passive: true });
      window.__basicshellMedia = {
        off: function () {
          on = false;
          document.removeEventListener('pointermove', move, true);
          document.removeEventListener('scroll', scrolled, true);
          host.remove();
          delete window.__basicshellMedia;
        }
      };
    })();
    """#
}

extension WKUserContentController {
    private static let removeWorld = NSSelectorFromString("_removeAllUserScriptsAssociatedWithContentWorld:")

    /// WebKit's private way to take one world's scripts out of a controller
    /// and no others (an extension's are among the others).
    static var canRemoveScripts: Bool { instancesRespond(to: removeWorld) }

    func removeUserScripts(in world: WKContentWorld) {
        guard responds(to: Self.removeWorld) else { return }
        _ = perform(Self.removeWorld, with: world)
    }
}
