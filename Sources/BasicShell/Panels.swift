import SwiftUI

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
            Button("Clear") { Downloads.shared.clearFinished() }.buttonStyle(.borderless)
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
            if items.isEmpty { empty("Nothing downloaded since BasicShell opened.") }
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

struct DownloadRow: View {
    let item: Downloads.Item

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: item.file.map { NSWorkspace.shared.icon(forFile: $0.path) } ?? NSImage(systemSymbolName: "arrow.down.circle", accessibilityDescription: nil)!)
                .resizable()
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name).lineLimit(1)
                switch item.state {
                case .running: ProgressView(value: item.fraction).controlSize(.small)
                case .finished: Text("Done").font(.system(size: 11)).foregroundStyle(.secondary)
                case .failed: Text("Failed").font(.system(size: 11)).foregroundStyle(.red)
                case .cancelled: Text("Cancelled").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if item.state == .running {
                Button { Downloads.shared.cancel(item) } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .help("Cancel")
            } else if item.state == .finished, let file = item.file {
                Button { NSWorkspace.shared.activateFileViewerSelecting([file]) } label: { Image(systemName: "magnifyingglass") }
                    .buttonStyle(.borderless)
                    .help("Show in Finder")
            }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 10)
        .frame(height: 48)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            if item.state == .finished, let file = item.file { NSWorkspace.shared.open(file) }
        }
    }
}
