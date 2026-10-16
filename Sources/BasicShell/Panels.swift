import SwiftUI
import UniformTypeIdentifiers

/// The lists that open over the page: each a glass card with a search field,
/// put away with Esc or a click outside.
enum Panel: String, CaseIterable {
    case history, bookmarks, downloads, archive

    var title: String {
        switch self {
        case .history: "History"
        case .bookmarks: "Bookmarks"
        case .downloads: "Downloads"
        case .archive: "Archived Tabs"
        }
    }
}

struct PanelView: View {
    let shell: Shell
    let window: BrowserWindow
    // `@State` is a macro in the macOS 27 SDK whose plugin ships only with
    // Xcode, so the State it would expand to is stored by hand.
    private var _query = State(initialValue: "")
    private var query: String {
        get { _query.wrappedValue }
        nonmutating set { _query.wrappedValue = newValue }
    }
    @FocusState private var focused: Bool

    var body: some View {
        ZStack {
            Color.black.opacity(0.12)
                .contentShape(Rectangle())
                .onTapGesture { window.closePanel() }
            if let panel = shell.panel {
                card(panel)
            }
        }
        .onAppear { focused = true }
    }

    private func card(_ panel: Panel) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(panel.title).font(.system(size: 15, weight: .semibold))
                Spacer()
                actions(panel)
            }
            .padding(.horizontal, 18)
            .frame(height: 46)
            if panel != .downloads {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search \(panel.title.lowercased())", text: _query.projectedValue)
                        .textFieldStyle(.plain)
                        .focused($focused)
                }
                .font(.system(size: 14))
                .padding(.horizontal, 12)
                .frame(height: 32)
                .background(RoundedRectangle(cornerRadius: 9).fill(Color.primary.opacity(0.06)))
                .padding(.horizontal, 14)
                .padding(.bottom, 8)
            }
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    content(panel)
                }
                .padding(8)
            }
        }
        .frame(width: 660, height: 540)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }

    @ViewBuilder private func actions(_ panel: Panel) -> some View {
        switch panel {
        case .history:
            Button("Clear History…") { window.confirmClearHistory() }.buttonStyle(.borderless)
        case .downloads:
            Button("Show in Finder") {
                NSWorkspace.shared.open(FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0])
            }
            .buttonStyle(.borderless)
            Button("Clear") { Downloads.shared.clearFinished() }
                .buttonStyle(.borderless)
                .disabled(!Downloads.shared.items.contains { !$0.isActive })
        case .archive:
            Button("Clear") { Archive.shared.clear() }.buttonStyle(.borderless)
        case .bookmarks:
            EmptyView()
        }
    }

    @ViewBuilder private func content(_ panel: Panel) -> some View {
        switch panel {
        case .history:
            let visits = History.shared.search(query)
            if visits.isEmpty { empty("No history") }
            ForEach(Array(days(visits).enumerated()), id: \.offset) { _, day in
                Text(day.title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.top, 10)
                    .padding(.bottom, 2)
                ForEach(day.visits) { visit in
                    PanelRow(title: visit.title, url: visit.url, detail: visit.date.formatted(date: .omitted, time: .shortened)) {
                        window.openFromPanel(visit.url)
                    } remove: {
                        History.shared.remove([visit.id])
                    }
                }
            }
        case .bookmarks:
            let marks = Bookmarks.shared.search(query)
            if marks.isEmpty { empty(query.isEmpty ? "No bookmarks yet. ⌘D keeps the page you are on." : "Nothing matches") }
            ForEach(marks) { mark in
                PanelRow(title: mark.title, url: mark.url, detail: nil) {
                    window.openFromPanel(mark.url)
                } remove: {
                    Bookmarks.shared.remove([mark.id])
                }
            }
        case .archive:
            let entries = Archive.shared.search(query)
            if entries.isEmpty { empty(query.isEmpty ? "Tabs you haven't looked at for a while are put here." : "Nothing matches") }
            ForEach(entries) { entry in
                PanelRow(title: entry.tab.title, url: entry.tab.url ?? URL(string: "about:blank")!,
                         detail: entry.date.formatted(.relative(presentation: .named))) {
                    window.restoreArchived(entry.id)
                } remove: {
                    Archive.shared.remove([entry.id])
                }
            }
        case .downloads:
            let items = Downloads.shared.items
            if items.isEmpty { empty("No downloads") }
            ForEach(items) { DownloadRow(item: $0) }
        }
    }

    private func empty(_ words: String) -> some View {
        Text(words)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.top, 40)
    }

    private struct Day { let title: String; let visits: [History.Visit] }

    private func days(_ visits: [History.Visit]) -> [Day] {
        let calendar = Calendar.current
        var result: [Day] = []
        for visit in visits {
            let title: String
            if calendar.isDateInToday(visit.date) { title = "Today" }
            else if calendar.isDateInYesterday(visit.date) { title = "Yesterday" }
            else { title = visit.date.formatted(date: .complete, time: .omitted) }
            if result.last?.title == title {
                result[result.count - 1] = Day(title: title, visits: result[result.count - 1].visits + [visit])
            } else {
                result.append(Day(title: title, visits: [visit]))
            }
        }
        return result
    }
}

struct PanelRow: View {
    let title: String
    let url: URL
    let detail: String?
    let open: () -> Void
    let remove: () -> Void
    private var _hovering = State(initialValue: false)
    private var hovering: Bool {
        get { _hovering.wrappedValue }
        nonmutating set { _hovering.wrappedValue = newValue }
    }

    init(title: String, url: URL, detail: String?, open: @escaping () -> Void, remove: @escaping () -> Void) {
        self.title = title
        self.url = url
        self.detail = detail
        self.open = open
        self.remove = remove
    }

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title.isEmpty ? Address.pretty(url) : title).lineLimit(1)
                Text(Address.pretty(url)).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            if hovering {
                Button(action: remove) { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)) }
                    .buttonStyle(.borderless)
                    .help("Remove")
            } else if let detail {
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 10)
        .frame(height: 40)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(hovering ? 0.07 : 0)))
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .onHover { hovering = $0 }
    }
}

/// One download, in the panel and under the top bar's button: its icon, name,
/// how far along it is and what is left to do with it.
struct DownloadRow: View {
    let item: Downloads.Item
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var _hovering = State(initialValue: false)
    private var hovering: Bool {
        get { _hovering.wrappedValue }
        nonmutating set { _hovering.wrappedValue = newValue }
    }

    init(item: Downloads.Item) { self.item = item }

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: icon)
                .resizable()
                .frame(width: 28, height: 28)
                .opacity(item.state == .paused || item.state == .cancelled || item.missing ? 0.55 : 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(item.missing || item.state == .cancelled ? .secondary : .primary)
                if item.isActive { DownloadBar(item: item) }
                Text(item.statusText)
                    .font(.system(size: 11))
                    .foregroundStyle(item.state == .failed ? Color.red : Color.secondary)
                    .lineLimit(item.state == .failed ? 2 : 1)
                    .truncationMode(.tail)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(item.name)
            .accessibilityValue(item.statusText)
            Spacer(minLength: 8)
            HStack(spacing: 2) { buttons }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(minHeight: 48)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(hovering ? 0.06 : 0)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) {
            if item.state == .finished, !item.missing, let file = item.file { NSWorkspace.shared.open(file) }
        }
        .contextMenu { menu }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: item.state)
    }

    private var icon: NSImage {
        if item.state == .finished, !item.missing, let file = item.file { return NSWorkspace.shared.icon(forFile: file.path) }
        let type = UTType(filenameExtension: (item.name as NSString).pathExtension) ?? .data
        return NSWorkspace.shared.icon(for: type)
    }

    @ViewBuilder private var buttons: some View {
        switch item.state {
        case .running:
            RowButton(symbol: "pause.circle.fill", title: "Pause", subject: item.name) { Downloads.shared.pause(item) }
            RowButton(symbol: "xmark.circle.fill", title: "Cancel", subject: item.name) { Downloads.shared.cancel(item) }
        case .paused:
            RowButton(symbol: "play.circle.fill", title: "Resume", subject: item.name) { Downloads.shared.resume(item) }
            RowButton(symbol: "xmark.circle.fill", title: "Cancel", subject: item.name) { Downloads.shared.cancel(item) }
        case .failed, .cancelled:
            if item.canResume {
                RowButton(symbol: "play.circle.fill", title: "Resume", subject: item.name) { Downloads.shared.resume(item) }
            }
            if item.canRetry {
                RowButton(symbol: "arrow.clockwise.circle.fill", title: item.restartOnly ? "Restart" : "Retry", subject: item.name) { Downloads.shared.retry(item) }
            }
        case .finished:
            if let file = item.file, !item.missing {
                RowButton(symbol: "magnifyingglass.circle.fill", title: "Show in Finder", subject: item.name) {
                    NSWorkspace.shared.activateFileViewerSelecting([file])
                }
            }
        }
    }

    @ViewBuilder private var menu: some View {
        switch item.state {
        case .running:
            Button("Pause") { Downloads.shared.pause(item) }
            Button("Cancel") { Downloads.shared.cancel(item) }
        case .paused:
            Button("Resume") { Downloads.shared.resume(item) }
            Button("Cancel") { Downloads.shared.cancel(item) }
        case .failed, .cancelled:
            if item.canResume { Button("Resume") { Downloads.shared.resume(item) } }
            if item.canRetry { Button(item.restartOnly ? "Restart" : "Retry") { Downloads.shared.retry(item) } }
        case .finished:
            if let file = item.file, !item.missing {
                Button("Open") { NSWorkspace.shared.open(file) }
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file]) }
            }
        }
        if let source = item.source {
            Button("Copy Link Address") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(source.absoluteString, forType: .string)
            }
        }
        if !item.isActive {
            Divider()
            Button("Remove from List") { Downloads.shared.remove(item) }
        }
    }
}

/// How far along it is: grey while paused, so it does not look like a
/// download that is going.
struct DownloadBar: View {
    let item: Downloads.Item
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if item.total > 0 {
            Capsule()
                .fill(Color.primary.opacity(0.12))
                .frame(height: 4)
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(item.state == .paused ? Color.secondary : Color.accentColor)
                        .scaleEffect(x: max(item.fraction, 0.02), y: 1, anchor: .leading)
                        .animation(reduceMotion ? nil : .linear(duration: 0.25), value: item.fraction)
                }
                .accessibilityHidden(true)
        } else if item.state == .running {
            // The site did not say how large it is.
            ProgressView().progressViewStyle(.linear).controlSize(.small).accessibilityHidden(true)
        }
    }
}

/// A round button at a row's right end: grey, darker with a circle behind it
/// when the pointer is on it.
private struct RowButton: View {
    let symbol: String
    let title: String
    let subject: String
    let action: () -> Void
    private var _hovering = State(initialValue: false)
    private var hovering: Bool {
        get { _hovering.wrappedValue }
        nonmutating set { _hovering.wrappedValue = newValue }
    }

    init(symbol: String, title: String, subject: String, action: @escaping () -> Void) {
        self.symbol = symbol
        self.title = title
        self.subject = subject
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .symbolRenderingMode(.hierarchical)
                .font(.system(size: 17))
                .foregroundStyle(hovering ? Color.primary : Color.secondary)
                .frame(width: 26, height: 26)
                .background(Circle().fill(Color.primary.opacity(hovering ? 0.08 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.borderless)
        .onHover { hovering = $0 }
        .help(title)
        .accessibilityLabel("\(title) \(subject)")
    }
}
