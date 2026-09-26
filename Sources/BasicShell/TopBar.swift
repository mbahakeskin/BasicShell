import SwiftUI

/// Back, forward, reload, the address, and the traffic lights at its left
/// end, on glass along the top.
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
        HStack(spacing: 2) {
            // Where the traffic lights sit (see Lights.swift); in full screen
            // the bar draws its own.
            if shell.fullScreen {
                FullScreenLights(window: window).padding(.horizontal, 8)
            } else {
                Color.clear.frame(width: 68, height: 1)
            }
            IconButton(symbol: "chevron.left", enabled: tab?.canGoBack ?? false) { window.goBack(nil) }
            IconButton(symbol: "chevron.right", enabled: tab?.canGoForward ?? false) { window.goForward(nil) }
            IconButton(symbol: tab?.isLoading == true ? "xmark" : "arrow.clockwise", enabled: tab?.url != nil) { window.reload(nil) }
            Spacer(minLength: 12)
            address.frame(maxWidth: 640)
            Spacer(minLength: 12)
            if let host = tab?.url?.host() {
                let off = Shield.shared.isPaused(on: host)
                IconButton(symbol: off ? "shield.slash" : "shield") { window.toggleShield(nil) }
                    .foregroundStyle(off ? Color.secondary : Color.primary)
                    .help(off ? "Block Ads on This Site" : "Allow Ads on This Site")
            }
            if tab?.url?.host() != nil {
                let awake = Awake.shared.contains(tab?.url)
                IconButton(symbol: awake ? "sun.max.fill" : "moon.zzz") { window.toggleAwake(nil) }
                    .foregroundStyle(awake ? Color.orange : Color.primary)
                    .help(awake ? "Let This Site Sleep" : "Keep This Site Awake")
            }
            IconButton(symbol: "link", enabled: tab?.url != nil) { window.copyAddress(nil) }
                .help("Copy Address (⇧⌘C)")
            IconButton(symbol: "plus") { window.ask(.newTab(privately: false)) }
                .help("New Tab")
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
        .onChange(of: shell.editingAddress) { _, editing in
            if editing { text = tab?.url?.absoluteString ?? "" }
            focused = editing
        }
        .onChange(of: focused) { _, now in
            if !now { shell.editingAddress = false }
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
                .background(Capsule().fill(Color.primary.opacity(0.05)))
                .overlay(alignment: .bottom) {
                    if let tab, tab.isLoading {
                        GeometryReader { geo in
                            Capsule().fill(Color.accentColor)
                                .frame(width: geo.size.width * tab.progress, height: 2)
                        }
                        .frame(height: 2)
                        .padding(.horizontal, 10)
                    }
                }
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
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
