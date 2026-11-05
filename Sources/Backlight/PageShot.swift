import AppKit
import ImageIO
import UniformTypeIdentifiers
import WebKit

// ⇧⌘R: the whole page, from its top to its bottom, as one picture on the clipboard.
//
// WebKit pictures only the view, so the page is asked for as it prints: `createPDF` gives all of it as one page,
// drawn as it is on screen, and that is drawn into a bitmap. A page whose pictures wait to be scrolled into view
// would come out with holes, so they are asked for first (`loadEverything`), and the page is put back where it was.
// The drawing and the PNG are the long part and run off the main thread at utility priority.
enum PageShot {
    nonisolated struct Taken {
        let png: Data
        let width: Int
        let height: Int
        /// Drawn at less than the screen's own density (a very long page).
        let reduced: Bool
    }

    /// What crosses to the other thread: a PDF nobody changes meanwhile.
    private nonisolated struct Carried<T>: @unchecked Sendable { let value: T }

    /// Pixels at most in the picture: a base M1 MacBook Air has none to spare for a screenshot.
    private nonisolated static let budget = 40_000_000.0
    private nonisolated static let longest = 30_000.0

    /// Nil when the page couldn't be pictured.
    static func take(of web: WKWebView) async -> Taken? {
        await loadEverything(in: web)
        let data: Data? = await withCheckedContinuation { continuation in
            var answered = false
            web.createPDF(configuration: WKPDFConfiguration()) { result in
                guard !answered else { return }
                answered = true
                continuation.resume(returning: try? result.get())
            }
            // The page that never answers.
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
                guard !answered else { return }
                answered = true
                continuation.resume(returning: nil)
            }
        }
        guard let data else { return nil }
        let carried = Carried(value: data)
        return await Task.detached(priority: .utility) { render(carried.value) }.value
    }

    /// Lazy pictures asked for, by their own loading and by walking the page once for the ones that wait to be seen;
    /// the scroll position put back. Ends when the pictures have loaded (or failed), not after a guessed time: the
    /// watchdogs are only for a picture that never answers.
    private static func loadEverything(in web: WKWebView) async {
        let script = """
        const waiting = () => [...document.images].filter((i) => !i.complete && i.src);
        const arrived = (list, ms) => new Promise((resolve) => {
          let left = list.length;
          if (!left) return resolve();
          const done = () => { if (--left <= 0) { clearTimeout(timer); resolve(); } };
          const timer = setTimeout(resolve, ms);
          for (const i of list) { i.addEventListener("load", done, { once: true }); i.addEventListener("error", done, { once: true }); }
        });
        const lazy = [...document.images].filter((i) => i.loading === "lazy" || i.dataset.src || i.dataset.lazySrc || i.dataset.srcset || i.dataset.original);
        if (!lazy.length && !waiting().length) return true;
        for (const i of document.images) if (i.loading === "lazy") i.loading = "eager";
        // Pictures that load when they come into view: the page is walked once, a view at a time.
        const home = [scrollX, scrollY], view = Math.max(innerHeight, 400);
        const total = Math.max(document.documentElement.scrollHeight, document.body ? document.body.scrollHeight : 0);
        if (lazy.some((i) => i.dataset.src || i.dataset.lazySrc || i.dataset.srcset || i.dataset.original)) {
          const stop = performance.now() + 8000;
          for (let y = 0; y < total && performance.now() < stop; y += view * 0.9) {
            scrollTo(0, y);
            // The page's own observers run with the next frame; a covered window gets none, so this is only a watchdog.
            await new Promise((r) => { const t = setTimeout(r, 120); requestAnimationFrame(() => requestAnimationFrame(() => { clearTimeout(t); r(); })); });
            await arrived(waiting().filter((i) => { const b = i.getBoundingClientRect(); return b.bottom > 0 && b.top < innerHeight; }), 1500);
          }
          scrollTo(home[0], home[1]);
        }
        await arrived(waiting(), 4000);
        return true;
        """
        _ = try? await web.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: .defaultClient)
    }

    nonisolated private static func render(_ data: Data) -> Taken? {
        guard let provider = CGDataProvider(data: data as CFData), let pdf = CGPDFDocument(provider), let page = pdf.page(at: 1) else { return nil }
        let box = page.getBoxRect(.mediaBox)
        guard box.width >= 1, box.height >= 1 else { return nil }
        // Twice the points on a Retina screen, less when the picture would be too large to hold.
        let density = NSScreen.main?.backingScaleFactor ?? 2
        var scale = min(density, (budget / (box.width * box.height)).squareRoot(), longest / box.height)
        let reduced = scale < min(density, 1)
        scale = max(scale, 0.1)
        let wide = max(Int((box.width * scale).rounded()), 1), high = max(Int((box.height * scale).rounded()), 1)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let cg = CGContext(data: nil, width: wide, height: high, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                 bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        cg.interpolationQuality = .high
        // A page with no background of its own is white, as it is on screen.
        cg.setFillColor(CGColor(gray: 1, alpha: 1))
        cg.fill(CGRect(x: 0, y: 0, width: wide, height: high))
        cg.scaleBy(x: CGFloat(wide) / box.width, y: CGFloat(high) / box.height)
        cg.translateBy(x: -box.minX, y: -box.minY)
        cg.drawPDFPage(page)
        guard let image = cg.makeImage() else { return nil }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return Taken(png: out as Data, width: wide, height: high, reduced: reduced)
    }

    /// On the clipboard as the PNG it is, which every app that takes a picture from it understands.
    static func copy(_ taken: Taken) {
        let board = NSPasteboard.general
        board.clearContents()
        board.setData(taken.png, forType: .png)
    }
}
