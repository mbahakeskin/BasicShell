import SwiftUI

/// The tabs, down the left, on glass.
struct SidebarView: View {
    let shell: Shell
    let window: BrowserWindow

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 2) {
                IconButton(symbol: "plus") { window.ask(.newTab(privately: false)) }
                    .help("New Tab")
                IconButton(symbol: "eyeglasses") { window.ask(.newTab(privately: true)) }
                    .help("New Private Tab")
                Spacer()
                IconButton(symbol: shell.sidebarPinned ? "sidebar.left" : "pin") { window.toggleSidebarPinned(nil) }
                    .help(shell.sidebarPinned ? "Hide Sidebar When Not in Use" : "Keep Sidebar Open")
            }
            .padding(.horizontal, 4)

            List {
                let pinned = shell.tabs.filter(\.pinned)
                if !pinned.isEmpty {
                    ForEach(pinned) { row($0) }
                        .onMove { window.move(from: $0, to: $1, pinned: true) }
                    Divider()
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .padding(.horizontal, 6)
                }
                ForEach(shell.tabs.filter { !$0.pinned }) { row($0) }
                    .onMove { window.move(from: $0, to: $1, pinned: false) }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .glassEffect(.regular, in: .rect(cornerRadius: Metrics.radius))
    }

    private func row(_ tab: Tab) -> some View {
        TabRow(tab: tab, selected: tab === shell.selected, window: window)
            .listRowInsets(EdgeInsets(top: 1, leading: 0, bottom: 1, trailing: 0))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }
}

struct TabRow: View {
    let tab: Tab
    let selected: Bool
    let window: BrowserWindow
    // `@State` is a macro in the macOS 27 SDK whose plugin ships only with
    // Xcode, so the State it would expand to is stored by hand.
    private var _hovering = State(initialValue: false)
    private var hovering: Bool {
        get { _hovering.wrappedValue }
        nonmutating set { _hovering.wrappedValue = newValue }
    }

    var body: some View {
        HStack(spacing: 8) {
            Favicon(tab: tab)
            Text(tab.name)
                .font(.system(size: 13))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            if tab.pinned && !hovering {
                Image(systemName: "pin.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
            if tab.isPrivate {
                Image(systemName: "eyeglasses")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            if hovering {
                Button { window.close(tab) } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 32)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.primary.opacity(selected ? 0.13 : hovering ? 0.06 : 0))
        )
        .opacity(tab.isUnloaded ? 0.55 : 1)
        .contentShape(Rectangle())
        .onTapGesture { window.select(tab) }
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Copy Address") {
                guard let url = tab.url else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url.absoluteString, forType: .string)
            }
            .disabled(tab.url == nil)
            Button(tab.pinned ? "Unpin Tab" : "Pin Tab") { window.setPinned(tab, !tab.pinned) }
            Button("Unload Tab") { window.unload(tab) }
                .disabled(selected || tab.webView == nil)
            Divider()
            Button("Close Tab") { window.close(tab) }
        }
    }
}
