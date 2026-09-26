import AppKit
import WebKit

// A tab's icon: the page's own <link rel=icon>, else /favicon.ico. Fetched
// without cookies, kept in memory by address for the life of the app.
enum Favicons {
    private static var cache: [URL: NSImage] = [:]
    private static let session = URLSession(configuration: .ephemeral)

    private static let find = """
    (() => {
      const links = [...document.querySelectorAll('link[rel~="icon"], link[rel="apple-touch-icon"]')];
      const score = l => { const s = parseInt((l.sizes && l.sizes.value || '').split('x')[0]) || 16; return Math.abs(s - 32); };
      links.sort((a, b) => score(a) - score(b));
      return links.map(l => l.href).filter(h => h.startsWith('http'))[0] || null;
    })()
    """

    static func fetch(for tab: Tab) {
        guard let web = tab.webView, let page = web.url, ["http", "https"].contains(page.scheme) else { return }
        web.evaluateJavaScript(find) { result, _ in
            let found = (result as? String).flatMap(URL.init(string:))
            let fallback = URL(string: "/favicon.ico", relativeTo: page)?.absoluteURL
            guard let address = found ?? fallback else { return }
            if let known = cache[address] {
                tab.icon = known
                return
            }
            Task {
                guard let (data, response) = try? await session.data(from: address),
                      (response as? HTTPURLResponse)?.statusCode == 200,
                      let image = NSImage(data: data), image.isValid
                else { return }
                cache[address] = image
                if tab.url?.host() == page.host() { tab.icon = image }
            }
        }
    }
}
