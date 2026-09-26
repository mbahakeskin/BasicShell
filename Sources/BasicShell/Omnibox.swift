import SwiftUI

/// The field in the middle of the window, over the page, for a new tab.
/// Nothing is created until an address or a search is entered; Esc or a
/// click outside puts it away.
struct OmniboxView: View {
    let shell: Shell
    let window: BrowserWindow
    private var _text = State(initialValue: "")
    private var text: String {
        get { _text.wrappedValue }
        nonmutating set { _text.wrappedValue = newValue }
    }
    @FocusState private var focused: Bool

    private var privately: Bool { shell.asking == .newTab(privately: true) }

    private var hint: (symbol: String, words: String)? {
        let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty else { return nil }
        if let url = Address.url(from: typed) {
            return ("arrow.up.right", "Go to \(Address.pretty(url))")
        }
        return ("magnifyingglass", "Search \(Engine.current.title) for “\(typed)”")
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
                        .onSubmit { window.commit(text) }
                        .onExitCommand { window.dismissOmnibox() }
                }
                .padding(.horizontal, 18)
                .frame(height: 56)

                if let hint {
                    Divider().padding(.horizontal, 12)
                    Button { window.commit(text) } label: {
                        HStack(spacing: 10) {
                            Image(systemName: hint.symbol).frame(width: 18)
                            Text(hint.words).lineLimit(1).truncationMode(.tail)
                            Spacer()
                            Text("↩").foregroundStyle(.secondary)
                        }
                        .font(.system(size: 14))
                        .padding(.horizontal, 18)
                        .frame(height: 40)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(width: 620)
            .glassEffect(.regular, in: .rect(cornerRadius: 18))
            .padding(.top, 150)
        }
        .onAppear { focused = true }
    }
}

/// What a window with no tabs shows.
struct EmptyPage: View {
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
