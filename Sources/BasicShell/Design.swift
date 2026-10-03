import SwiftUI

enum Metrics {
    /// The gap between a floating panel and the window's edge.
    static let inset: CGFloat = 6
    static let bar: CGFloat = 40
    static let sidebar: CGFloat = 250
    static let radius: CGFloat = 14
    /// How close to an edge the pointer has to be to bring its panel out.
    static let edge: CGFloat = 6
    /// How far past a panel the pointer can stray before it goes away.
    static let slack: CGFloat = 24
}

enum Motion {
    static let reveal: TimeInterval = 0.18
    /// How long the pointer rests at an edge before the panel comes out, so
    /// crossing the edge on the way into the window doesn't open it.
    static let dwell: TimeInterval = 0.12
    static let linger: TimeInterval = 0.12
    /// How long the pointer rests against the top in BasicShell's own full
    /// screen before the menu bar comes down over the top bar.
    static let menuBar: TimeInterval = 0.6
}

/// A small icon button for the bars.
struct IconButton: View {
    let symbol: String
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .disabled(!enabled)
    }
}

/// A tab's icon, or its first letter until there is one.
struct Favicon: View {
    let tab: Tab

    var body: some View {
        Group {
            if let icon = tab.icon {
                Image(nsImage: icon).resizable().interpolation(.high)
            } else {
                Text(String(tab.name.prefix(1)).uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 16, height: 16)
                    .background(Circle().fill(Color.primary.opacity(0.12)))
            }
        }
        .frame(width: 16, height: 16)
    }
}
