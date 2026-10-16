import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

/// Sharing the page from the "Link copied" pill: a QR code of its address,
/// or AirDrop.
enum Share {
    static func actions(_ url: URL, title: String?, in window: BrowserWindow) -> [Toast.Action] {
        // Weak: the toast is the window's, and holds these.
        [
            Toast.Action(title: "QR Code", symbol: "qrcode", help: "Show a QR code of this address",
                         label: "Show QR code") { [weak window] in
                if let window { QRCard.show(url, title: title, from: window) }
            },
            Toast.Action(title: "AirDrop", symbol: "airdrop", help: "Send this address with AirDrop",
                         label: "Send with AirDrop") { [weak window] in
                if let window { AirDrop.send(url, from: window) }
            },
        ]
    }
}

// MARK: - the code

/// A QR code, black modules on white, one pixel each, its quiet zone
/// included.
struct QRCode: @unchecked Sendable {
    let image: CGImage
    /// Across, quiet zone included.
    let modules: Int

    /// The white margin the standard asks for, in modules on each side.
    nonisolated static let quiet = 4
    /// How wide the code is on the card at most, in points.
    nonisolated static let side: CGFloat = 240

    private nonisolated(unsafe) static let context = CIContext()

    /// Points per module at `side` on a Retina screen, whole pixels each.
    nonisolated static func module(_ modules: Int, scale: CGFloat = 2) -> CGFloat {
        (side * scale / CGFloat(modules)).rounded(.down) / scale
    }

    /// The code for this text, with as much error correction as keeps its
    /// modules at 3 points; with the least, at 2. Finer than that a phone
    /// can't read it off a screen, and there is no code (nil).
    nonisolated static func make(_ text: String) -> QRCode? {
        let data = Data(text.utf8)
        var fallback: QRCode?
        for level in ["Q", "M", "L"] {
            guard let code = generate(data, level: level) else { continue }
            if module(code.modules) >= 3 { return code }
            if level == "L", module(code.modules) >= 2 { fallback = code }
        }
        return fallback
    }

    private nonisolated static func generate(_ data: Data, level: String) -> QRCode? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = data
        filter.correctionLevel = level
        // Core Image gives the code with a margin of one module.
        guard let output = filter.outputImage, let drawn = context.createCGImage(output, from: output.extent) else { return nil }
        let inner = drawn.width - 2
        let modules = inner + 2 * quiet
        guard let bitmap = CGContext(data: nil, width: modules, height: modules, bitsPerComponent: 8, bytesPerRow: 0,
                                     space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }
        bitmap.setFillColor(gray: 1, alpha: 1)
        bitmap.fill(CGRect(x: 0, y: 0, width: modules, height: modules))
        bitmap.interpolationQuality = .none
        bitmap.draw(drawn, in: CGRect(x: quiet - 1, y: quiet - 1, width: drawn.width, height: drawn.height))
        guard let image = bitmap.makeImage() else { return nil }
        return QRCode(image: image, modules: modules)
    }

    /// The code as a PNG for the clipboard, so many pixels a module that it
    /// stays sharp wherever it is pasted.
    nonisolated func png(pixelsPerModule: Int = 12) -> Data? {
        let size = modules * pixelsPerModule
        guard let bitmap = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                     space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }
        bitmap.interpolationQuality = .none
        bitmap.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
        guard let scaled = bitmap.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: scaled).representation(using: .png, properties: [:])
    }
}

// MARK: - the card

/// The QR code of the page's address in a card under the pill, closed by a
/// click outside it or Esc.
enum QRCard {
    private static var shown: NSPopover?

    static func show(_ url: URL, title: String?, from window: BrowserWindow) {
        let text = url.absoluteString
        // Where the pill is now: it is put away as the button is pressed, and its place with it.
        let anchor = window.toastAnchor
        Task {
            let code = await Task.detached(priority: .userInitiated) { QRCode.make(text) }.value
            present(url, title: title, code: code, anchor: anchor, from: window)
        }
    }

    private static func present(_ url: URL, title: String?, code: QRCode?, anchor: (view: NSView, rect: NSRect)?, from window: BrowserWindow) {
        guard let anchor, anchor.view.window?.isVisible == true else { return }
        shown?.close()
        let popover = NSPopover()
        let card = QRCardView(url: url, title: title, code: code) { [weak window, weak popover] in
            popover?.close()
            if let window { AirDrop.send(url, from: window) }
        }
        popover.contentViewController = CardController(rootView: card)
        popover.behavior = .transient
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let root = window.root
        popover.show(relativeTo: root.convert(anchor.rect, from: anchor.view), of: root, preferredEdge: root.isFlipped ? .maxY : .minY)
        // Key, so that Esc reaches it.
        popover.contentViewController?.view.window?.makeKey()
        shown = popover
    }

    /// Esc closes the card.
    private final class CardController: NSHostingController<QRCardView> {
        override func cancelOperation(_ sender: Any?) {
            QRCard.shown?.close()
        }

        override func viewDidDisappear() {
            super.viewDidDisappear()
            if QRCard.shown?.contentViewController === self { QRCard.shown = nil }
        }
    }
}

struct QRCardView: View {
    let url: URL
    let title: String?
    let code: QRCode?
    let airDrop: () -> Void

    @Environment(\.displayScale) private var scale
    // `@State` is a macro in the macOS 27 SDK whose plugin ships only with
    // Xcode, so the State it would expand to is stored by hand.
    private var _copied = State(initialValue: false)
    private var copied: Bool {
        get { _copied.wrappedValue }
        nonmutating set { _copied.wrappedValue = newValue }
    }

    init(url: URL, title: String?, code: QRCode?, airDrop: @escaping () -> Void) {
        self.url = url
        self.title = title
        self.code = code
        self.airDrop = airDrop
    }

    var body: some View {
        VStack(spacing: 14) {
            if let code {
                picture(code)
            } else {
                tooLong
            }
            VStack(spacing: 3) {
                if let title, !title.isEmpty {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                }
                Text(Address.site(url))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity)
            if let code {
                Button { copy(code) } label: {
                    Label(copied ? "Copied" : "Copy Image", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .contentTransition(.symbolEffect(.replace))
                        .padding(.horizontal, 4)
                }
                .buttonStyle(.glass)
                .help("Copy the QR code as an image")
            } else {
                Button(action: airDrop) {
                    Label("AirDrop", systemImage: "airdrop").padding(.horizontal, 4)
                }
                .buttonStyle(.glass)
                .help("Send this address with AirDrop")
                .accessibilityLabel("Send with AirDrop")
            }
        }
        .padding(20)
        .frame(width: QRCode.side + 40)
    }

    /// Whole pixels a module, nearest neighbour, on its own white so the
    /// quiet zone is there in dark appearance too.
    private func picture(_ code: QRCode) -> some View {
        let side = CGFloat(code.modules) * QRCode.module(code.modules, scale: scale)
        return Image(decorative: code.image, scale: 1)
            .resizable()
            .interpolation(.none)
            .antialiased(false)
            .frame(width: side, height: side)
            .background(Color.white)
            .clipShape(.rect(cornerRadius: 10, style: .continuous))
            .accessibilityElement()
            .accessibilityLabel("QR code of \(url.absoluteString)")
            .accessibilityAddTraits(.isImage)
    }

    private var tooLong: some View {
        VStack(spacing: 8) {
            Image(systemName: "qrcode")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.tertiary)
                .padding(.bottom, 2)
            Text("Too long for a QR code")
                .font(.system(size: 13, weight: .semibold))
            Text("This address has \(url.absoluteString.utf8.count) characters; a code for it would be too fine to scan from the screen. Send it with AirDrop, or paste the link.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 6)
    }

    private func copy(_ code: QRCode) {
        guard let png = code.png() else { return }
        let item = NSPasteboardItem()
        item.setData(png, forType: .png)
        if let tiff = NSImage(data: png)?.tiffRepresentation { item.setData(tiff, forType: .tiff) }
        let board = NSPasteboard.general
        board.clearContents()
        board.writeObjects([item])
        copied = true
    }
}

// MARK: - AirDrop

/// The address sent with AirDrop: the system's picker over the window, and
/// a word when it went or could not.
final class AirDrop: NSObject, NSSharingServiceDelegate {
    /// Kept until the service says how it went: it holds its delegate weakly.
    private static var sending: Set<AirDrop> = []
    private weak var window: BrowserWindow?
    /// Where the pill was, on the screen, when the button was pressed.
    private let source: NSRect

    private init(window: BrowserWindow, source: NSRect) {
        self.window = window
        self.source = source
    }

    static func send(_ url: URL, from window: BrowserWindow) {
        guard let service = NSSharingService(named: .sendViaAirDrop), service.canPerform(withItems: [url]) else {
            Debug.log("share", "AirDrop unavailable")
            window.say("AirDrop is unavailable; check Wi-Fi and Bluetooth")
            return
        }
        var source = NSRect.zero
        if let anchor = window.toastAnchor, let host = anchor.view.window {
            source = host.convertToScreen(anchor.view.convert(anchor.rect, to: nil))
        }
        let share = AirDrop(window: window, source: source)
        service.delegate = share
        sending.insert(share)
        service.perform(withItems: [url])
    }

    func sharingService(_ sharingService: NSSharingService, sourceWindowForShareItems items: [Any],
                        sharingContentScope: UnsafeMutablePointer<NSSharingService.SharingContentScope>) -> NSWindow? {
        window?.window
    }

    /// The picker grows out of the pill.
    func sharingService(_ sharingService: NSSharingService, sourceFrameOnScreenForShareItem item: Any) -> NSRect {
        source
    }

    func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {
        Debug.log("share", "AirDrop sent")
        window?.say("Sent with AirDrop")
        AirDrop.sending.remove(self)
    }

    func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any], error: any Error) {
        let error = error as NSError
        Debug.log("share", "AirDrop not sent: \(error.domain) \(error.code)")
        if !(error.domain == NSCocoaErrorDomain && error.code == NSUserCancelledError) {
            window?.say("AirDrop didn't send the link")
        }
        AirDrop.sending.remove(self)
    }
}
