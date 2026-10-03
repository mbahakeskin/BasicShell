import SwiftUI
import WebKit

/// Back, forward, the address with reload in it, and the traffic lights at its left
/// end, on glass along the top; in BasicShell's own full screen, on either
/// side of the notch.
struct TopBarView: View {
    let shell: Shell
    let window: BrowserWindow
    private var _text = State(initialValue: "")
    private var text: String {
        get { _text.wrappedValue }
        nonmutating set { _text.wrappedValue = newValue }
    }
    @FocusState private var focused: Bool

    private var tab: Tab? { shell.selected }

    var body: some View {
        Group {
            if let notch = shell.notch {
                // Beside the notch, in the strip the menu bar would have:
                // the buttons to its left, the address to its right.
                HStack(spacing: 0) {
                    HStack(spacing: 2) {
                        FullScreenLights(window: window).padding(.horizontal, 8)
                        navigation
                        Spacer(minLength: 8)
                        tools
                    }
                    .padding(.horizontal, 4)
                    .frame(width: notch.leftWidth, height: notch.height)
                    .glassEffect(.regular, in: .rect(cornerRadius: min(Metrics.radius, notch.height / 2)))
                    Spacer(minLength: 0)
                    address
                        .padding(.horizontal, 3)
                        .frame(width: notch.rightWidth, height: notch.height)
                        .glassEffect(.regular, in: .rect(cornerRadius: min(Metrics.radius, notch.height / 2)))
                }
                .padding(.horizontal, Metrics.inset)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 2) {
                    // Where the traffic lights sit (see Lights.swift); in full
                    // screen the bar draws its own.
                    if shell.fullScreen {
                        FullScreenLights(window: window).padding(.horizontal, 8)
                    } else {
                        Color.clear.frame(width: 68, height: 1)
                    }
                    IconButton(symbol: "chevron.left", enabled: tab?.canGoBack ?? false) { window.goBack(nil) }
                    IconButton(symbol: "chevron.right", enabled: tab?.canGoForward ?? false) { window.goForward(nil) }
                    Spacer(minLength: 12)
                    address.frame(maxWidth: 640)
                    Spacer(minLength: 12)
                    tools
                }
                .padding(.horizontal, 6)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background {
                    Color.clear
                        .contentShape(Rectangle())
                        .gesture(WindowDragGesture())
                        .onTapGesture(count: 2) { window.window?.performZoom(nil) }
                }
                .glassEffect(.regular, in: .rect(cornerRadius: Metrics.radius))
            }
        }
        .coordinateSpace(.named("bar"))
        .onChange(of: shell.editingAddress) { _, editing in
            if editing { text = tab?.url?.absoluteString ?? "" }
            focused = editing
        }
        .onChange(of: focused) { _, now in
            if !now { shell.editingAddress = false }
        }
    }

    @ViewBuilder private var navigation: some View {
        IconButton(symbol: "chevron.left", enabled: tab?.canGoBack ?? false) { window.goBack(nil) }
        IconButton(symbol: "chevron.right", enabled: tab?.canGoForward ?? false) { window.goForward(nil) }
    }

    private var reload: some View {
        IconButton(symbol: tab?.isLoading == true ? "xmark" : "arrow.clockwise", enabled: tab?.url != nil) { window.reload(nil) }
            .help(tab?.isLoading == true ? "Stop Loading" : "Reload This Page (⌘R)")
    }

    /// The site's own: kept awake, its extensions, downloads, the bookmark.
    @ViewBuilder private var tools: some View {
        if tab?.url?.host() != nil {
            let awake = Awake.shared.contains(tab?.url)
            IconButton(symbol: awake ? "sun.max.fill" : "moon.zzz") { window.toggleAwake(nil) }
                .foregroundStyle(awake ? Color.orange : Color.primary)
                .help(awake ? "Let This Site Sleep" : "Keep This Site Awake")
        }
        ForEach(Extensions.shared.contexts, id: \.uniqueIdentifier) { context in
            ExtensionButton(context: context, tab: tab, shell: shell)
        }
        if !Downloads.shared.items.isEmpty || shell.downloadsOpen {
            DownloadsButton(shell: shell, window: window)
        }
        if tab?.url != nil {
            let kept = Bookmarks.shared.contains(tab?.url)
            IconButton(symbol: kept ? "star.fill" : "star") { window.bookmarkPage(nil) }
                .foregroundStyle(kept ? Color.yellow : Color.primary)
                .help(kept ? "Remove Bookmark (⌘D)" : "Bookmark This Page (⌘D)")
        }
    }

    @ViewBuilder private var address: some View {
        if shell.editingAddress {
            TextField("Search or enter address", text: _text.projectedValue)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($focused)
                .onSubmit { window.go(text) }
                .onExitCommand { shell.editingAddress = false }
                .padding(.horizontal, 12)
                .frame(height: 28)
                .background(Capsule().fill(Color.primary.opacity(0.08)))
        } else {
            // Reload at the right end, inside; as much room at the left, so
            // the address stays in the middle.
            HStack(spacing: 0) {
                Color.clear.frame(width: 28, height: 1)
                Button { shell.editingAddress = true } label: {
                    HStack(spacing: 6) {
                        if let url = tab?.url {
                            if url.scheme == "https" {
                                Image(systemName: "lock.fill").font(.system(size: 9)).foregroundStyle(.secondary)
                            }
                            Text(Address.pretty(url)).lineLimit(1).truncationMode(.middle)
                        } else {
                            Text("Search or enter address").foregroundStyle(.secondary)
                        }
                    }
                    .font(.system(size: 13))
                    .frame(maxWidth: .infinity)
                    .frame(height: 28)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                reload
            }
            .background(Capsule().fill(Color.primary.opacity(0.05)))
        }
    }
}

/// The traffic lights in full screen, where macOS keeps the real ones in a
/// title bar it does not always bring down. Close, the one that can't be used
/// in full screen, and leave full screen.
struct FullScreenLights: View {
    let window: BrowserWindow
    private var _hovering = State(initialValue: false)
    private var hovering: Bool {
        get { _hovering.wrappedValue }
        nonmutating set { _hovering.wrappedValue = newValue }
    }

    var body: some View {
        HStack(spacing: 8) {
            light(Color(red: 1, green: 0.37, blue: 0.34), glyph: "xmark") { window.window?.performClose(nil) }
            light(Color.gray.opacity(0.45), glyph: nil, action: nil)
            light(Color(red: 0.16, green: 0.78, blue: 0.25), glyph: "arrow.down.forward.and.arrow.up.backward") { window.window?.toggleFullScreen(nil) }
        }
        .onHover { hovering = $0 }
    }

    private func light(_ color: Color, glyph: String?, action: (() -> Void)?) -> some View {
        Button { action?() } label: {
            Circle()
                .fill(color)
                .frame(width: 12, height: 12)
                .overlay {
                    if hovering, let glyph {
                        Image(systemName: glyph)
                            .font(.system(size: 6.5, weight: .heavy))
                            .foregroundStyle(.black.opacity(0.55))
                    }
                }
        }
        .buttonStyle(.plain)
        .disabled(action == nil)
    }
}

/// This session's downloads, under a button that fills a ring as they come
/// in; it shows once something has been downloaded, as in Safari.
struct DownloadsButton: View {
    let shell: Shell
    let window: BrowserWindow

    var body: some View {
        let running = Downloads.shared.items.filter { $0.state == .running }
        let fraction = running.isEmpty ? 0 : running.map(\.fraction).reduce(0, +) / Double(running.count)
        let open = Binding(get: { shell.downloadsOpen }, set: { showing in
            shell.downloadsOpen = showing
            window.layout(animated: true)
        })
        Button { open.wrappedValue.toggle() } label: {
            ZStack {
                if !running.isEmpty {
                    Circle().stroke(Color.primary.opacity(0.15), lineWidth: 2)
                    Circle().trim(from: 0, to: max(0.03, fraction))
                        .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.linear(duration: 0.2), value: fraction)
                }
                Image(systemName: running.isEmpty ? "arrow.down.circle" : "arrow.down")
                    .font(.system(size: running.isEmpty ? 13 : 9, weight: running.isEmpty ? .medium : .bold))
            }
            .frame(width: 18, height: 18)
            .frame(width: 28, height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help("Downloads")
        .popover(isPresented: open, arrowEdge: .bottom) { DownloadsPopover() }
    }
}

/// The downloads under the top bar's button: this session's, newest first.
struct DownloadsPopover: View {
    var body: some View {
        let items = Downloads.shared.items
        VStack(spacing: 0) {
            if items.isEmpty {
                Text("No downloads").foregroundStyle(.secondary).frame(height: 60)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) { ForEach(items) { DownloadRow(item: $0) } }
                        .padding(.vertical, 4)
                }
                .frame(height: min(CGFloat(items.count) * 48 + 8, 300))
            }
            Divider()
            HStack {
                Button("Clear") { Downloads.shared.clearFinished() }
                    .disabled(!items.contains { $0.state != .running })
                Spacer()
                Button("Show in Finder") {
                    NSWorkspace.shared.open(FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0])
                }
            }
            .buttonStyle(.borderless)
            .font(.system(size: 12))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .frame(width: 320)
    }
}

/// An extension's button: its icon, its badge, and its popup when pressed.
struct ExtensionButton: View {
    let context: WKWebExtensionContext
    let tab: Tab?
    let shell: Shell

    var body: some View {
        // Read so the button redraws when the extension changes it.
        let _ = Extensions.shared.actions
        let target = tab?.isPrivate == false ? tab : nil
        let action = context.action(for: target)
        let icon = action?.icon(for: CGSize(width: 16, height: 16)) ?? context.webExtension.icon(for: CGSize(width: 16, height: 16))
        Button {
            // Nothing here may read the action's popup web view or popover:
            // reading either makes WebKit load the popup page, and a popup
            // already loaded is never shown when asked for.
            let name = context.webExtension.displayName ?? "extension"
            Debug.log("extension", "\(name) button pressed; popup: \(action?.presentsPopup == true ? "yes" : "no"), enabled: \(action?.isEnabled ?? false)")
            let asked = Extensions.shared.popupsAsked
            context.performAction(for: target)
            if action?.presentsPopup == true {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    if Extensions.shared.popupsAsked == asked { Debug.log("extension", "\(name): WebKit never asked for the popup") }
                }
            }
        } label: {
            Group {
                if let icon { Image(nsImage: icon).resizable().frame(width: 16, height: 16) }
                else { Image(systemName: "puzzlepiece.extension") }
            }
            .frame(width: 28, height: 28)
            .overlay(alignment: .topTrailing) {
                if let badge = action?.badgeText, !badge.isEmpty {
                    Text(badge)
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 3)
                        .background(Capsule().fill(Color.red))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(action?.label ?? context.webExtension.displayName ?? "Extension")
        .background {
            GeometryReader { geometry in
                Color.clear
                    .onAppear { shell.extensionButtons[context.uniqueIdentifier] = geometry.frame(in: .named("bar")) }
                    .onChange(of: geometry.frame(in: .named("bar"))) { _, frame in
                        shell.extensionButtons[context.uniqueIdentifier] = frame
                    }
            }
        }
    }
}
