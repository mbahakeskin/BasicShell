import SwiftUI

// Dragging tabs in the sidebar, by the app's own gesture rather than the
// system's drag and drop: macOS's drag session gave the list's table view a
// say in where a drop went (a drop on a row's middle was taken for between
// rows), made the picture freeze when let go, and could only be tried by hand.
// Here each row and square says where it is (in the sidebar's own space), the
// gesture follows the pointer, and what is under it decides: on a row, its top
// third puts the tab before it, its bottom third after it, its middle makes
// the two a group (or joins the row's group); on a pinned square, the tab takes that square's
// place (from the side it came from), and a tab from the list becomes a pin there. The list scrolls itself while the pointer is held
// near its edge.

@Observable
final class TabDragModel {
    enum Kind {
        case tile
        case row
        case header(TabGroup)
        /// The New Tab rows above and below the tabs: a tab carried onto one goes to that end of the list.
        case end(top: Bool)
    }

    static let topEnd = UUID()
    static let bottomEnd = UUID()

    /// The tab being dragged, and where the pointer is, in the sidebar's space.
    var dragging: UUID?
    var pointer = CGPoint.zero
    /// Where in the picked-up row the pointer took hold of it, so the picture stays under the hand as it was.
    var grab = CGPoint.zero
    /// -1 while the list should scroll up, 1 down.
    var scrolling = 0

    @ObservationIgnored var frames: [UUID: (rect: CGRect, kind: Kind)] = [:]
    @ObservationIgnored var list = CGRect.zero
    /// What is on show in the sidebar as a drag begins: a row hidden since (in a folded group) may still have a frame here.
    @ObservationIgnored private var shown = Set<UUID>()
    @ObservationIgnored private var target: (id: UUID, zone: DropZone, kind: Kind)?

    static let space = "sidebarDrag"

    /// What the pointer is over: a square (both ways), or a row or header by height.
    private func find(_ point: CGPoint, excluding id: UUID, order: [UUID: Int], from group: TabGroup?) -> (id: UUID, zone: DropZone, kind: Kind)? {
        for (key, entry) in frames where key != id && shown.contains(key) {
            guard case .tile = entry.kind, entry.rect.insetBy(dx: -3, dy: -3).contains(point) else { continue }
            // Onto a square: the tab takes its place, from the side it came from (left to right goes after it).
            return (key, (order[id] ?? 0) < (order[key] ?? 0) ? .after : .before, entry.kind)
        }
        for (key, entry) in frames where key != id && shown.contains(key) {
            if case .tile = entry.kind { continue }
            guard point.y >= entry.rect.minY - 1, point.y <= entry.rect.maxY + 1,
                  point.x >= entry.rect.minX - 8, point.x <= entry.rect.maxX + 8
            else { continue }
            let at = (point.y - entry.rect.minY) / max(1, entry.rect.height)
            // On its own group's title a tab leaves the group (shown as the bar before it), on another's it joins.
            if case .header(let own) = entry.kind { return (key, at < 0.5 || own === group ? .before : .onto, entry.kind) }
            // The New Tab rows: a tab dropped on the one above the list lands just under it, on the one below just over it.
            if case .end(let top) = entry.kind { return (key, top ? .after : .before, entry.kind) }
            return (key, at < 0.3 ? .before : at > 0.7 ? .after : .onto, entry.kind)
        }
        return nil
    }

    func update(_ tab: Tab, to point: CGPoint, from start: CGPoint, in window: BrowserWindow) {
        if dragging != tab.id {
            shown = Set(window.shell.tabs.filter(\.pinned).map(\.id))
            for item in window.shell.sidebarItems() {
                switch item {
                case .tab(let shownTab): shown.insert(shownTab.id)
                case .header(let group): shown.insert(group.id)
                case .newTab(let top): shown.insert(top ? Self.topEnd : Self.bottomEnd)
                }
            }
            dragging = tab.id
            if let rect = frames[tab.id]?.rect { grab = CGPoint(x: start.x - rect.minX, y: start.y - rect.minY) } else { grab = .zero }
        }
        pointer = point
        target = find(point, excluding: tab.id, order: Dictionary(window.shell.tabs.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first }), from: tab.group)
        if let target { window.shell.mark(target.id, target.zone) } else { window.shell.dropMark = nil }
        let direction = list.height > 0 && point.x >= list.minX && point.x <= list.maxX
            ? (point.y < list.minY + 36 ? -1 : point.y > list.maxY - 36 ? 1 : 0)
            : 0
        if scrolling != direction { scrolling = direction }
    }

    func finish(_ tab: Tab, in window: BrowserWindow) {
        let landing = target
        dragging = nil
        target = nil
        scrolling = 0
        window.shell.dropMark = nil
        guard let landing else { return }
        switch landing.kind {
        case .tile:
            window.placePinned(tab.id, relativeTo: window.shell.tabs.first { $0.id == landing.id }, after: landing.zone == .after)
        case .row:
            guard let other = window.shell.tabs.first(where: { $0.id == landing.id }) else { return }
            switch landing.zone {
            case .before: window.reorder(tab.id, relativeTo: other, after: false)
            case .after: window.reorder(tab.id, relativeTo: other, after: true)
            default: _ = window.drop(tab.id, onto: other)
            }
        case .header(let group):
            // A tab of the group dropped on its title leaves the group; one from elsewhere joins it (top half: just before it).
            if landing.zone == .before || tab.group === group { window.moveBefore(group, tab.id) } else { window.joinStart(group, tab.id) }
        case .end(let top):
            window.moveToEnd(tab.id, top: top)
        }
    }
}

extension View {
    /// Says where this view is, for the pointer to be matched against.
    func dragTarget(_ id: UUID, _ kind: TabDragModel.Kind, in shell: Shell) -> some View {
        onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named(TabDragModel.space)) }) { shell.drag.frames[id] = ($0, kind) }
    }

    /// A tab that can be picked up and carried to another place in the sidebar.
    func carriedTab(_ tab: Tab, in window: BrowserWindow) -> some View {
        simultaneousGesture(
            DragGesture(minimumDistance: 6, coordinateSpace: .named(TabDragModel.space))
                .onChanged { window.shell.drag.update(tab, to: $0.location, from: $0.startLocation, in: window) }
                .onEnded { _ in window.shell.drag.finish(tab, in: window) }
        )
    }
}

/// The carried tab's picture, in a view of its own: the pointer moves it a hundred times a second, and only
/// this view may be drawn again for that, not the whole sidebar (which made carrying a pin stall).
struct DragOverlay: View {
    let shell: Shell

    var body: some View {
        if let id = shell.drag.dragging, let tab = shell.tabs.first(where: { $0.id == id }) {
            // Its place is known; if it isn't (a row that was drawn again and said nothing), the size it usually has.
            let rect = shell.drag.frames[id]?.rect ?? CGRect(x: 0, y: 0, width: tab.pinned ? 78 : max(120, shell.drag.list.width), height: tab.pinned ? 40 : 32)
            TabDragPicture(tab: tab, tile: tab.pinned, size: rect.size)
                .position(x: shell.drag.pointer.x - shell.drag.grab.x + rect.width / 2, y: shell.drag.pointer.y - shell.drag.grab.y + rect.height / 2)
        }
    }
}

/// The tab as it is carried: the row (or square) lifted, the same size and look, held where it was taken hold of.
struct TabDragPicture: View {
    let tab: Tab
    let tile: Bool
    let size: CGSize

    var body: some View {
        Group {
            if tile {
                Favicon(tab: tab).scaleEffect(1.25)
            } else {
                HStack(spacing: 8) {
                    Favicon(tab: tab)
                    Text(tab.name).font(.system(size: 13)).lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8)
            }
        }
        .frame(width: size.width, height: size.height)
        .background(RoundedRectangle(cornerRadius: tile ? 10 : 9, style: .continuous).fill(Color.primary.opacity(0.2)))
        .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
        .allowsHitTesting(false)
    }
}

/// Where a carried tab would land: a thin white bar in the gap (with a dot at its start), or a frame round the row;
/// in the colour of the group when the tab would join one.
extension View {
    func dropMarks(_ zone: DropZone, tile: Bool = false, corner: CGFloat = 9, tint: Color = .white) -> some View {
        overlay(alignment: tile ? .leading : .top) {
            if zone == .before { DropBar(vertical: tile, tint: tint).offset(x: tile ? -5 : 0, y: tile ? 0 : -2) }
        }
        .overlay(alignment: tile ? .trailing : .bottom) {
            if zone == .after { DropBar(vertical: tile, tint: tint).offset(x: tile ? 5 : 0, y: tile ? 0 : 2) }
        }
        .overlay {
            if zone == .onto {
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .fill(tint.opacity(0.2))
                    .overlay(RoundedRectangle(cornerRadius: corner, style: .continuous).stroke(tint, lineWidth: 2))
            }
        }
    }
}

struct DropBar: View {
    let vertical: Bool
    let tint: Color

    var body: some View {
        ZStack(alignment: vertical ? .top : .leading) {
            Capsule().fill(tint).frame(width: vertical ? 2 : nil, height: vertical ? nil : 2)
            Circle().fill(tint).frame(width: 7, height: 7).offset(x: vertical ? 0 : -2, y: vertical ? -2 : 0)
        }
        .shadow(color: .black.opacity(0.45), radius: 1.5)
        .frame(maxWidth: vertical ? 7 : .infinity, maxHeight: vertical ? .infinity : 7)
    }
}

enum DropZone { case none, before, onto, after }

struct DropMark: Equatable {
    var id: UUID
    var zone: DropZone
}
