import AppKit
import SwiftUI
import WebKit

// Trying a layout at another size. The window keeps its own: the page is put
// in a frame of the size asked for (a phone's, a tablet's, or any), standing
// on a ground of the browser's own colour with a strip of controls under it.
// When the frame is larger than the room there is, the page is shown smaller
// (its zoom) while it is still told the size asked for, and the strip says so.
//
// The window lays it out (BrowserWindow.layout); Viewport.swift is how the
// Develop menu and the agent get here.

@MainActor
final class Stage: ObservableObject {
    /// The size the page is told it has; `nil` while the page fills the window.
    @Published var size: CGSize?
    /// How much smaller than that it is drawn, to fit.
    @Published var scale: CGFloat = 1
    /// Where it stands on the ground (the top left is the origin).
    @Published var device: CGRect = .zero

    static let radius: CGFloat = 18
    /// The window's own gray, the one a page that hasn't drawn yet shows.
    static let ground = Color(nsColor: .windowBackgroundColor)

    /// Where a page of `size` stands in a ground of `ground`, and how it is
    /// scaled to fit. The room above is for the top bar when it is out, the
    /// room below for the strip.
    static func fit(_ size: CGSize, in ground: CGSize) -> (rect: CGRect, scale: CGFloat) {
        let top: CGFloat = 56, bottom: CGFloat = 84, side: CGFloat = 28
        let room = CGSize(width: max(80, ground.width - side * 2), height: max(80, ground.height - top - bottom))
        let fit = min(1, room.width / size.width, room.height / size.height)
        let width = (size.width * fit).rounded()
        let height = (size.height * fit).rounded()
        let x = ((ground.width - width) / 2).rounded()
        let y = (top + (room.height - height) / 2).rounded()
        // The scale that makes the page's width exactly the size asked for.
        return (CGRect(x: x, y: y, width: width, height: height), width / size.width)
    }
}

extension BrowserWindow {
    /// The page of `tab` (the one shown, if none is named) shown at `size`
    /// in its frame, or filling the window again. A frame belongs to its tab.
    func setStage(_ size: CGSize?, for tab: Tab? = nil) {
        guard let tab = tab ?? shell.selected else { return }
        tab.stageSize = size
        if tab === shell.selected { syncStage() }
    }

    /// The frame follows the tab shown: there for one that has a size, gone
    /// for one that has none, and for no tab at all.
    func syncStage() {
        let size = shell.selected?.stageSize
        stage.size = size
        if size != nil, stageHost == nil {
            let host = NSHostingView(rootView: StageView(stage: stage, window: self))
            host.sizingOptions = []
            host.safeAreaRegions = []
            root.addSubview(host, positioned: .below, relativeTo: pageView)
            stageHost = host
        } else if size == nil, let host = stageHost {
            host.removeFromSuperview()
            stageHost = nil
        }
        layout(animated: false)
    }

/// A phone's or a tablet's frame and way of introducing itself, or back.
    func applyDesign(_ preset: Viewport.Preset) {
        setStage(preset.size)
        guard let tab = shell.selected else { return }
        Viewport.setAgent(preset.agent, for: tab)
        tab.webView?.reload()
    }

    /// The zoom the person set for the page, without the frame's scale in it.
    func userZoom(of web: WKWebView) -> Double {
        if stage.size != nil, web === shell.selected?.webView, let zoom = stagedZoom[ObjectIdentifier(web)] { return Double(zoom) }
        return Double(web.pageZoom)
    }

    /// Sets the person's zoom; in a frame it rides on the frame's scale.
    func setUserZoom(_ level: Double, on web: WKWebView) {
        if stage.size != nil, web === shell.selected?.webView {
            stagedZoom[ObjectIdentifier(web)] = CGFloat(level)
            applyStageZoom()
        } else {
            web.pageZoom = level
        }
    }

    /// The page shown drawn at the scale its frame needs; every other put
    /// back as it was. Run by every layout.
    func applyStageZoom() {
        let shown = shell.selected?.webView
        for web in pageView.subviews.compactMap({ $0 as? WKWebView }) {
            let key = ObjectIdentifier(web)
            if stage.size != nil, web === shown {
                if stagedZoom[key] == nil { stagedZoom[key] = web.pageZoom }
                // The frame's scale and the zoom the person set (⌘+, ⌘−) together.
                let target = stage.scale * (stagedZoom[key] ?? 1)
                if abs(web.pageZoom - target) > 0.0005 { web.pageZoom = target }
            } else if let zoom = stagedZoom.removeValue(forKey: key) {
                web.pageZoom = zoom
            }
        }
    }
}

/// A soft light, white and faint, behind what is in front: the backlight.
struct Backlit: View {
    var center = UnitPoint.center
    var radius: CGFloat = 520
    var strength = 0.07

    var body: some View {
        RadialGradient(colors: [Color.white.opacity(strength), .clear], center: center, startRadius: 0, endRadius: radius)
            .allowsHitTesting(false)
    }
}

/// The ground, the frame's edge, and the controls.
/// Where a drag of the frame's edge began.
final class StageDrag: ObservableObject {
    var start: CGSize?
    var scale: CGFloat = 1
}

struct StageView: View {
    @ObservedObject var stage: Stage
    unowned let window: BrowserWindow
    @StateObject private var drag = StageDrag()

    /// A grip on the frame's edge: dragged, it sets the size the page is told,
    /// the frame following the pointer (`dx`, `dy` say which way it grows).
    private func grip(_ size: CGSize, at point: CGPoint, dx: CGFloat, dy: CGFloat, style: PointerStyle) -> some View {
        Capsule()
            .fill(Color.primary.opacity(0.35))
            .frame(width: size.width, height: size.height)
            .padding(10)
            .contentShape(Rectangle())
            .pointerStyle(style)
            .position(point)
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named("stage"))
                    .onChanged { value in
                        guard let current = stage.size else { return }
                        if drag.start == nil {
                            drag.start = current
                            drag.scale = max(stage.scale, 0.05)
                        }
                        guard let start = drag.start else { return }
                        let width = start.width + dx * value.translation.width / drag.scale
                        let height = start.height + dy * value.translation.height / drag.scale
                        window.setStage(CGSize(width: min(max(width.rounded(), 200), 6000), height: min(max(height.rounded(), 200), 6000)))
                    }
                    .onEnded { _ in drag.start = nil }
            )
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            // The page is lit from behind: a halo round it, a bright edge at its top.
            let reach = max(stage.device.height, stage.device.width) * 0.85
            Backlit(radius: reach, strength: 0.16)
                .frame(width: reach * 2, height: reach * 2)
                .position(x: stage.device.midX, y: stage.device.midY)
            RoundedRectangle(cornerRadius: Stage.radius)
                .fill(Color.black)
                .shadow(color: .black.opacity(0.3), radius: 24, y: 6)
                .overlay {
                    RoundedRectangle(cornerRadius: Stage.radius)
                        .strokeBorder(LinearGradient(colors: [Color.white.opacity(0.38), Color.white.opacity(0.08)], startPoint: .top, endPoint: .bottom), lineWidth: 1)
                }
                .frame(width: stage.device.width, height: stage.device.height)
                .offset(x: stage.device.minX, y: stage.device.minY)
            grip(CGSize(width: 5, height: 44), at: CGPoint(x: stage.device.maxX + 14, y: stage.device.midY), dx: 2, dy: 0, style: .columnResize)
            grip(CGSize(width: 44, height: 5), at: CGPoint(x: stage.device.midX, y: stage.device.maxY + 14), dx: 0, dy: 2, style: .rowResize)
            grip(CGSize(width: 12, height: 12), at: CGPoint(x: stage.device.maxX + 14, y: stage.device.maxY + 14), dx: 2, dy: 2, style: .frameResize(position: .bottomTrailing))
            StageStrip(stage: stage, window: window)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, 22)
        }
        .coordinateSpace(.named("stage"))
        .ignoresSafeArea()
    }
}

struct StageStrip: View {
    @ObservedObject var stage: Stage
    unowned let window: BrowserWindow
    // `@State` is a macro whose plugin ships only with Xcode: stored by hand.
    private var _width = State(initialValue: "")
    private var _height = State(initialValue: "")
    private var width: String {
        get { _width.wrappedValue }
        nonmutating set { _width.wrappedValue = newValue }
    }
    private var height: String {
        get { _height.wrappedValue }
        nonmutating set { _height.wrappedValue = newValue }
    }
    private var widthText: Binding<String> { _width.projectedValue }
    private var heightText: Binding<String> { _height.projectedValue }

    var body: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) {
                HStack(spacing: 2) {
                    chip("iPhone", .mobile)
                    chip("iPad", .tablet)
                    chip("Full", .desktop)
                }
                .padding(4)
                .glassEffect(.regular, in: .capsule)

                HStack(spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        field(widthText)
                        Text("×").foregroundStyle(.secondary)
                        field(heightText)
                    }
                    Button(action: rotate) {
                        Image(systemName: "rotate.right").font(.system(size: 12, weight: .medium))
                    }
                    .buttonStyle(.borderless)
                    .help("Turn it on its side")
                }
                .padding(.horizontal, 14)
                .frame(height: 36)
                .glassEffect(.regular, in: .capsule)

            }
        }
        .onAppear(perform: sync)
        .onChange(of: stage.size) { sync() }
    }

    private func chip(_ title: String, _ preset: Viewport.Preset) -> some View {
        let on = preset.size.map { matches($0) } ?? false
        return Button { window.applyDesign(preset) } label: {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 12)
                .frame(height: 28)
                .background(Capsule().fill(Color.white.opacity(on ? 0.16 : 0)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func matches(_ preset: CGSize) -> Bool {
        guard let size = stage.size else { return false }
        return size == preset || (size.width == preset.height && size.height == preset.width)
    }

    private func field(_ text: Binding<String>) -> some View {
        TextField("", text: text)
            .textFieldStyle(.plain)
            .multilineTextAlignment(.center)
            .font(.system(size: 12, weight: .medium).monospacedDigit())
            .frame(width: 42)
            .onSubmit(apply)
    }

    private func sync() {
        guard let size = stage.size else { return }
        width = String(Int(size.width))
        height = String(Int(size.height))
    }

    private func apply() {
        guard let w = Int(width.trimmingCharacters(in: .whitespaces)), let h = Int(height.trimmingCharacters(in: .whitespaces)) else { return sync() }
        window.setStage(CGSize(width: min(max(w, 200), 6000), height: min(max(h, 200), 6000)))
        sync()
    }

    private func rotate() {
        guard let size = stage.size else { return }
        window.setStage(CGSize(width: size.height, height: size.width))
    }
}
