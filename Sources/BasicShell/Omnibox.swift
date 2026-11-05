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
    // The site whose chip is in the field: what is typed searches it.
    private var _chip = State<Keyword?>(initialValue: nil)
    private var chip: Keyword? {
        get { _chip.wrappedValue }
        nonmutating set { _chip.wrappedValue = newValue }
    }
    // What was typed to get the chip ("claude"), so Backspace can give it back.
    private var _word = State(initialValue: "")
    private var word: String {
        get { _word.wrappedValue }
        nonmutating set { _word.wrappedValue = newValue }
    }
    // Keywords are off for what is in the field: the person went to the plain
    // search row, or took the chip off, and means a search of the engine.
    private var _plain = State(initialValue: false)
    private var plain: Bool {
        get { _plain.wrappedValue }
        nonmutating set { _plain.wrappedValue = newValue }
    }
    // The menu bar's items, read once as the field opens.
    private var _commands = State<[Command]>(initialValue: [])
    private var commands: [Command] {
        get { _commands.wrappedValue }
        nonmutating set { _commands.wrappedValue = newValue }
    }
    // Watches for Backspace in an empty field: the field handles that key
    // itself before a key handler of the view would see it.
    private final class KeyWatch { var monitor: Any? }
    private var _watch = State(initialValue: KeyWatch())
    @FocusState private var focused: Bool

    private var privately: Bool {
        shell.asking == .newTab(privately: true) || (shell.asking == .address && shell.selected?.isPrivate == true)
    }

    enum Suggestion {
        case typed(String)
        case tab(Tab)
        case page(URL, String, symbol: String)
        /// A site's keyword typed whole: its front page, or a search of it.
        case keyword(Keyword, words: String)
        /// A keyword nearly typed: Enter or Tab puts its chip in the field.
        case keywordHint(Keyword)
        case command(Command)
    }

    private var suggestions: [Suggestion] {
        let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty else { return [] }
        if let chip { return [.keyword(chip, words: typed)] }

        // ">" asks for commands alone.
        if typed.hasPrefix(">") {
            let query = String(typed.dropFirst())
            return Commands.matching(query, in: commands, limit: 9).map { .command($0) }
        }

        var list: [Suggestion] = []
        let exact = plain ? nil : Keywords.exact(typed)
        if let exact { list.append(.keyword(exact.keyword, words: exact.words)) }
        list.append(.typed(typed))
        if exact == nil, !plain, !typed.contains(" ") {
            for keyword in Keywords.similar(typed) { list.append(.keywordHint(keyword)) }
        }
        if typed.count >= 2 {
            for command in Commands.matching(typed, in: commands, limit: 3) { list.append(.command(command)) }
        }

        var seen: Set<URL> = []
        // Not the tab whose own address this is.
        let editing = shell.asking == .address ? shell.selected : nil
        let open = Windows.all.flatMap { $0.shell.tabs }.filter { $0 !== editing && $0.isPrivate == privately }
        var tabs = 0
        for tab in Fuzzy.ranked(open, typed, title: \.title, url: \.url) {
            guard let url = tab.url, seen.insert(url).inserted else { continue }
            list.append(.tab(tab))
            tabs += 1
            if tabs >= 3 { break }
        }
        // A private tab's field doesn't search what ordinary browsing kept.
        guard !privately else { return list }
        for mark in Bookmarks.shared.search(typed).prefix(3) where seen.insert(mark.url).inserted {
            list.append(.page(mark.url, mark.title, symbol: "star"))
        }
        for visit in History.shared.suggestions(for: typed) where seen.insert(visit.url).inserted {
            list.append(.page(visit.url, visit.title, symbol: "clock"))
            if list.count >= 12 { break }
        }
        return list
    }

    /// The tint of what Enter would do now: a site's colour, faintly.
    private var tint: Color? {
        if let chip { return chip.tint }
        let list = suggestions
        guard list.indices.contains(chosen) else { return nil }
        switch list[chosen] {
        case .keyword(let keyword, _), .keywordHint(let keyword): return keyword.tint
        default: return nil
        }
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
                    if let chip {
                        Text(chip.name)
                            .font(.system(size: 14, weight: .medium))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(Capsule().fill((chip.tint ?? .secondary).opacity(0.22)))
                            .transition(.opacity)
                    }
                    TextField(prompt, text: _text.projectedValue)
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
                        .onKeyPress(.tab) { tabPressed() }
                        .onChange(of: text) { old, now in
                            // Going off the keyword's row and then typing on:
                            // "claude xyz" is a search of the engine.
                            if chip == nil, chosen != 0, Keywords.exact(old) != nil { plain = true }
                            chosen = 0
                            if now.isEmpty { plain = false }
                            // "yt " is the keyword, then a space: its chip.
                            guard chip == nil, !plain, now.count > 1, now.hasSuffix(" "), !now.dropLast().contains(" "),
                                  let hit = Keywords.exact(now), hit.words.isEmpty else { return }
                            put(hit.keyword, typed: String(now.dropLast()))
                            text = ""
                        }
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
            // The site's colour, barely there.
            .overlay(RoundedRectangle(cornerRadius: 18).fill((tint ?? .clear).opacity(0.07)).allowsHitTesting(false))
            .animation(.easeOut(duration: 0.2), value: tint)
            .padding(.top, 150)
        }
        .onAppear {
            // The tab's own address, to change.
            if shell.asking == .address, let url = shell.selected?.url { text = url.absoluteString }
            commands = Commands.all(for: window.window) + Commands.extras(for: window)
            focused = true
            // Backspace in an empty field takes the chip off, leaving its
            // keyword to edit.
            _watch.wrappedValue.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                guard event.keyCode == 51, event.modifierFlags.isDisjoint(with: [.command, .option, .control]),
                      let chip = self.chip, self.text.isEmpty else { return event }
                self.chip = nil
                self.plain = true
                self.text = self.word.isEmpty ? chip.key : self.word
                return nil
            }
        }
        .onDisappear {
            if let monitor = _watch.wrappedValue.monitor { NSEvent.removeMonitor(monitor) }
            _watch.wrappedValue.monitor = nil
        }
    }

    private var prompt: String {
        if let chip { return "Search \(chip.name)" }
        return privately ? "Private tab: search, enter address or run a command" : "Search, enter address or run a command"
    }

    /// Tab: the keyword typed (or nearly) becomes its chip; with one already
    /// there, Tab stays in the field.
    private func tabPressed() -> KeyPress.Result {
        guard chip == nil else { return .handled }
        guard !plain else { return .ignored }
        let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let hit = Keywords.exact(typed) {
            put(hit.keyword, typed: String(typed.split(separator: " ").first ?? ""))
            text = hit.words
            return .handled
        }
        if !typed.contains(" "), let keyword = Keywords.similar(typed, limit: 1).first {
            put(keyword, typed: typed)
            text = ""
            return .handled
        }
        return .ignored
    }

    private func put(_ keyword: Keyword, typed: String) {
        word = typed
        plain = false
        chip = keyword
    }

    private func row(_ suggestion: Suggestion, chosen: Bool) -> some View {
        let tint: Color? = switch suggestion {
        case .keyword(let keyword, _), .keywordHint(let keyword): keyword.tint
        default: nil
        }
        let (symbol, title, detail): (String, String, String?) = switch suggestion {
        case .typed(let typed):
            if let url = Address.url(from: typed) { ("arrow.up.right", "Go to \(Address.pretty(url))", nil) }
            else { ("magnifyingglass", "Search \(Engine.current.title) for “\(typed)”", nil) }
        case .tab(let tab): ("square.on.square", tab.name, "Switch to Tab")
        case .page(let url, let title, let symbol): (symbol, title.isEmpty ? Address.pretty(url) : title, Address.pretty(url))
        case .keyword(let keyword, let words):
            if words.isEmpty { ("arrow.up.right", "Open \(keyword.name)", keyword.homeURL.map { Address.pretty($0) }) }
            else { ("magnifyingglass", "Search \(keyword.name) for “\(words)”", nil) }
        case .keywordHint(let keyword):
            ("arrow.right.to.line", keyword.name, "Tab to search")
        case .command(let command): ("command", command.title, command.shortcut.isEmpty ? command.path : command.shortcut)
        }
        return HStack(spacing: 10) {
            Image(systemName: symbol).frame(width: 18).foregroundStyle(tint ?? .secondary)
            Text(title).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 8)
            if let detail { Text(detail).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
            if chosen { Text("↩").foregroundStyle(.secondary) }
        }
        .font(.system(size: 14))
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background(RoundedRectangle(cornerRadius: 8).fill((tint ?? .primary).opacity(chosen ? (tint == nil ? 0.1 : 0.16) : 0)))
    }

    private func pick(_ index: Int) {
        let list = suggestions
        guard list.indices.contains(index) else { return window.commit(text, keywords: !plain) }
        switch list[index] {
        case .typed(let typed): window.commit(typed, keywords: !plain)
        case .tab(let tab): window.switchTo(tab)
        case .page(let url, _, _): window.commit(url.absoluteString)
        case .keyword(let keyword, let words):
            guard let url = keyword.url(for: words) else { return }
            window.commit(url.absoluteString)
        case .keywordHint(let keyword):
            put(keyword, typed: text.trimmingCharacters(in: .whitespacesAndNewlines))
            text = ""
        case .command(let command):
            window.dismissOmnibox()
            // After the field is gone, so the page has the keyboard again.
            DispatchQueue.main.async { command.run() }
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
        // The pill is measured in this space, the host's own (its top left is the host's), so that ToastHost can tell
        // where a click is; `.global` is the window's, which is not where the host is.
        .coordinateSpace(.named("toast"))
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
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("toast")) } action: { shell.toastPill = $0 }
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
