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
        for tab in Windows.all.flatMap({ $0.shell.tabs }) where tab !== editing {
            guard let url = tab.url, tab.isPrivate == privately, matches(typed, title: tab.title, url: url), seen.insert(url).inserted else { continue }
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

/// A word of confirmation near the top, gone after a moment.
struct ToastView: View {
    let shell: Shell

    var body: some View {
        ZStack {
            if let toast = shell.toast {
                Text(toast)
                    .font(.system(size: 13, weight: .medium))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .glassEffect(.regular, in: .capsule)
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
        .animation(.easeOut(duration: 0.18), value: shell.toast)
    }
}
