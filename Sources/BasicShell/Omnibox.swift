import SwiftUI

/// The field in the middle of the window, over the page, for a new tab (or,
/// in the sidebar-only layout, for the tab's own address).
/// Nothing is created until an address or a search is entered; Esc or a
/// click outside puts it away. Under it: what was typed, then open tabs,
/// bookmarks and history that match, walked with the arrow keys.
struct OmniboxView: View {
    let shell: Shell
    let window: BrowserWindow
    // `@State` is a macro in the macOS 27 SDK whose plugin ships only with
    // Xcode, so the State it would expand to is stored by hand.
    private var _text = State(initialValue: "")
    private var text: String {
        get { _text.wrappedValue }
        nonmutating set { _text.wrappedValue = newValue }
    }
    private var _chosen = State(initialValue: 0)
    private var chosen: Int {
        get { _chosen.wrappedValue }
        nonmutating set { _chosen.wrappedValue = newValue }
    }
    @FocusState private var focused: Bool

    private var privately: Bool {
        shell.asking == .newTab(privately: true) || (shell.asking == .address && shell.selected?.isPrivate == true)
    }

    enum Suggestion {
        case typed(String)
        case tab(Tab)
        case page(URL, String, symbol: String)
    }

    private var suggestions: [Suggestion] {
        let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty else { return [] }
        var list: [Suggestion] = [.typed(typed)]
        var seen: Set<URL> = []
        // Not the tab whose own address this is.
        let editing = shell.asking == .address ? shell.selected : nil
        let open = Windows.all.flatMap { $0.shell.tabs }.filter { $0 !== editing && $0.isPrivate == privately }
        for tab in Fuzzy.ranked(open, typed, title: \.title, url: \.url) {
            guard let url = tab.url, seen.insert(url).inserted else { continue }
            list.append(.tab(tab))
            if list.count >= 3 { break }
        }
        // A private tab's field doesn't search what ordinary browsing kept.
        guard !privately else { return list }
        for mark in Bookmarks.shared.search(typed).prefix(3) where seen.insert(mark.url).inserted {
            list.append(.page(mark.url, mark.title, symbol: "star"))
        }
        for visit in History.shared.suggestions(for: typed) where seen.insert(visit.url).inserted {
            list.append(.page(visit.url, visit.title, symbol: "clock"))
            if list.count >= 9 { break }
        }
        return list
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.12)
                .contentShape(Rectangle())
                .onTapGesture { window.dismissOmnibox() }

            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) {
                    Image(systemName: privately ? "eyeglasses" : "magnifyingglass")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(.secondary)
                    TextField(privately ? "Private tab: search or enter address" : "Search or enter address", text: _text.projectedValue)
                        .textFieldStyle(.plain)
                        .font(.system(size: 20))
                        .focused($focused)
                        .onSubmit { pick(chosen) }
                        .onKeyPress(.downArrow) {
                            chosen = min(chosen + 1, max(0, suggestions.count - 1))
                            return .handled
                        }
                        .onKeyPress(.upArrow) {
                            chosen = max(chosen - 1, 0)
                            return .handled
                        }
                        .onChange(of: text) { _, _ in chosen = 0 }
                }
                .padding(.horizontal, 18)
                .frame(height: 56)

                let list = suggestions
                if !list.isEmpty {
                    Divider().padding(.horizontal, 12)
                    VStack(spacing: 0) {
                        ForEach(Array(list.enumerated()), id: \.offset) { index, suggestion in
                            row(suggestion, chosen: index == chosen)
                                .contentShape(Rectangle())
                                .onTapGesture { pick(index) }
                        }
                    }
                    .padding(6)
                }
            }
            .frame(width: 640)
            .glassEffect(.regular, in: .rect(cornerRadius: 18))
            .padding(.top, 150)
        }
        .onAppear {
            // The tab's own address, to change.
            if shell.asking == .address, let url = shell.selected?.url { text = url.absoluteString }
            focused = true
        }
    }

    private func row(_ suggestion: Suggestion, chosen: Bool) -> some View {
        let (symbol, title, detail): (String, String, String?) = switch suggestion {
        case .typed(let typed):
            if let url = Address.url(from: typed) { ("arrow.up.right", "Go to \(Address.pretty(url))", nil) }
            else { ("magnifyingglass", "Search \(Engine.current.title) for “\(typed)”", nil) }
        case .tab(let tab): ("square.on.square", tab.name, "Switch to Tab")
        case .page(let url, let title, let symbol): (symbol, title.isEmpty ? Address.pretty(url) : title, Address.pretty(url))
        }
        return HStack(spacing: 10) {
            Image(systemName: symbol).frame(width: 18).foregroundStyle(.secondary)
            Text(title).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 8)
            if let detail { Text(detail).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
            if chosen { Text("↩").foregroundStyle(.secondary) }
        }
        .font(.system(size: 14))
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(chosen ? 0.1 : 0)))
    }

    private func pick(_ index: Int) {
        let list = suggestions
        guard list.indices.contains(index) else { return window.commit(text) }
        switch list[index] {
        case .typed(let typed): window.commit(typed)
        case .tab(let tab): window.switchTo(tab)
        case .page(let url, _, _): window.commit(url.absoluteString)
        }
    }
}

/// What a window with no tabs shows.
struct EmptyPage: View {
    let shell: Shell
    let window: BrowserWindow

    var body: some View {
        Button { window.ask(.newTab(privately: false)) } label: {
            Label("New Tab", systemImage: "plus").padding(.horizontal, 8)
        }
        .buttonStyle(.glass)
        .controlSize(.large)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A word near the top of the window, and what can be done about it there
/// while it shows (most have nothing).
struct Toast: Equatable {
    struct Action {
        let title: String
        let symbol: String
        /// The tooltip, and what VoiceOver says the button does.
        let help: String
        let label: String
        let run: () -> Void
    }

    /// Each word said is a new toast, even the same word again.
    let id = UUID()
    let text: String
    var actions: [Action] = []

    static func == (a: Toast, b: Toast) -> Bool { a.id == b.id }
}

/// A word of confirmation near the top, gone after a moment; with actions,
/// a pill that stays while the pointer or the keyboard is on it.
struct ToastView: View {
    let shell: Shell
    let window: BrowserWindow

    var body: some View {
        let still = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        ZStack {
            if let toast = shell.toast {
                if toast.actions.isEmpty {
                    Text(toast.text)
                        .font(.system(size: 13, weight: .medium))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .glassEffect(.regular, in: .capsule)
                        .allowsHitTesting(false)
                        .transition(still ? .identity : .opacity.combined(with: .scale(scale: 0.95)))
                } else {
                    pill(toast)
                        .transition(still ? .identity : .opacity.combined(with: .scale(scale: 0.95)))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(still ? nil : .easeOut(duration: 0.18), value: shell.toast)
    }

    private func pill(_ toast: Toast) -> some View {
        GlassEffectContainer(spacing: 6) {
            HStack(spacing: 6) {
                Text(toast.text)
                    .font(.system(size: 13, weight: .medium))
                    .padding(.leading, 10)
                    .padding(.trailing, 4)
                    .accessibilityAddTraits(.isStaticText)
                ForEach(toast.actions.indices, id: \.self) { index in
                    ToastButton(action: toast.actions[index], focused: shell.toastFocus == index) {
                        window.runToastAction(index)
                    }
                }
            }
            .padding(5)
            .glassEffect(.regular, in: .capsule)
        }
        .fixedSize()
        .onHover { window.toastHovered($0) }
        // Where the pill is, so that only it takes clicks (ToastHost) and the
        // QR card can point at it.
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { shell.toastPill = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(toast.text)
    }
}

/// One of a toast's actions: a small glass button, its symbol and a word.
private struct ToastButton: View {
    let action: Toast.Action
    /// Tab brought the keyboard here (the window handles the keys: see
    /// ToastHost).
    let focused: Bool
    let run: () -> Void

    var body: some View {
        Button(action: run) {
            Label(action.title, systemImage: action.symbol)
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 2)
        }
        .buttonStyle(.glass)
        .controlSize(.small)
        .overlay {
            Capsule().strokeBorder(Color.accentColor, lineWidth: 2).padding(-2).opacity(focused ? 1 : 0)
        }
        .help(action.help)
        .accessibilityLabel(action.label)
    }
}
