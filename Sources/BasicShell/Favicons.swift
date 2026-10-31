import AppKit
import WebKit

// A tab's icon: the page's own <link rel=icon>, else /favicon.ico. Fetched
// without cookies, kept in memory by address for the life of the app.
//
// The page's links are tried best first until one gives a picture with
// something in it. SVGs come last: AppKit draws a page's SVG icon blank when
// it leans on the page's own styles (chatgpt.com's, measured: 32 × 32 pixels,
// every one transparent), and a PNG beside it is always better than that.
enum Favicons {
    private static var cache: [URL: NSImage] = [:]
    private static let session = URLSession(configuration: .ephemeral)

    private static let find = """
    (() => {
      const links = [...document.querySelectorAll('link[rel~="icon"], link[rel="apple-touch-icon"]')];
      const vector = l => /svg/.test(l.type || '') || /\\.svg(\\?|$)/.test(l.href);
      const score = l => { const s = parseInt((l.sizes && l.sizes.value || '').split('x')[0]) || 16; return Math.abs(s - 32) + (vector(l) ? 1000 : 0); };
      links.sort((a, b) => score(a) - score(b));
      return links.map(l => l.href).filter(h => h.startsWith('http'));
    })()
    """

    static func fetch(for tab: Tab) {
        guard !tab.isFrozen, let web = tab.webView, let page = web.url, ["http", "https"].contains(page.scheme) else { return }
        web.evaluateJavaScript(find) { result, _ in
            let found = (result as? [String])?.compactMap(URL.init(string:)) ?? []
            let candidates = found + [URL(string: "/favicon.ico", relativeTo: page)?.absoluteURL].compactMap { $0 }
            if let known = candidates.lazy.compactMap({ cache[$0] }).first {
                tab.icon = known
                return
            }
            Task {
                for address in candidates {
                    guard let (data, response) = try? await session.data(from: address),
                          (response as? HTTPURLResponse)?.statusCode == 200,
                          let image = NSImage(data: data), image.isValid, !isBlank(image)
                    else { continue }
                    let shown = legible(image)
                    cache[address] = shown
                    if tab.url?.host() == page.host() { tab.icon = shown }
                    return
                }
            }
        }
    }

    /// The icon's pixels at 32 × 32, and how many of them have anything in them.
    private static func pixels(_ image: NSImage) -> (covered: Double, light: Double)? {
        let side = 32
        guard let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let data = context.data
        else { return nil }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))
        let bytes = data.bindMemory(to: UInt8.self, capacity: side * side * 4)
        var covered = 0.0, light = 0.0, weight = 0.0
        for index in 0..<side * side {
            let alpha = Double(bytes[index * 4 + 3]) / 255
            guard alpha > 0.05 else { continue }
            covered += 1
            // Premultiplied: undo it to read the colour the icon draws.
            let red = Double(bytes[index * 4]) / 255 / alpha, green = Double(bytes[index * 4 + 1]) / 255 / alpha, blue = Double(bytes[index * 4 + 2]) / 255 / alpha
            light += (0.299 * red + 0.587 * green + 0.114 * blue) * alpha
            weight += alpha
        }
        return (covered / Double(side * side), weight > 0 ? light / weight : 0)
    }

    static func isBlank(_ image: NSImage) -> Bool {
        guard let seen = pixels(image) else { return false }
        return seen.covered < 0.01
    }

    /// An icon that draws dark on a dark sidebar (or light on a light one)
    /// and leaves its background clear is put on a plate of the other kind.
    private static func legible(_ image: NSImage) -> NSImage {
        guard let seen = pixels(image), seen.covered < 0.9 else { return image }
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        guard dark ? seen.light < 0.3 : seen.light > 0.8 else { return image }
        let side: CGFloat = 32
        return NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            (dark ? NSColor(white: 0.92, alpha: 1) : NSColor(white: 0.12, alpha: 1)).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7).fill()
            image.draw(in: rect.insetBy(dx: 4, dy: 4))
            return true
        }
    }
}
