import AppKit
import Observation
import WebKit

// The extensions' buttons in the menu bar, in the sidebar-only layout (see
// Settings › General): the sidebar is narrow, and there is no top bar. Each
// is a status item with the extension's icon and its badge, for the tab in
// front; its popup opens under it (see BrowserWindow.present(_:for:)).
//
// They are put back whenever what they show may have changed: the
// extensions, what an extension says of its button, the tab in front, the
// layout. Observation tells of the first three as they happen; a window
// coming to the front, and the layout, call update() themselves.
@MainActor
enum ExtensionMenuBar {
    private static var items: [String: NSStatusItem] = [:]
    private static var watching = false

    /// The status item's button for an extension, when it has one.
    static func button(for context: WKWebExtensionContext) -> NSStatusBarButton? {
        items[context.uniqueIdentifier]?.button
    }

    static func update() {
        if !watching {
            watching = true
            watch()
        } else {
            place()
        }
    }

    private static func watch() {
        withObservationTracking { place() } onChange: {
            DispatchQueue.main.async { MainActor.assumeIsolated { watch() } }
        }
    }

    private static func place() {
        let front = Windows.front
        let wanted = front?.shell.sidebarOnly ?? UserDefaults.standard.bool(forKey: "layout.sidebarOnly")
        let contexts = wanted ? Extensions.shared.contexts : []
        _ = Extensions.shared.actions
        let tab = front?.shell.selected
        let target = tab?.isPrivate == false ? tab : nil

        let ids = Set(contexts.map(\.uniqueIdentifier))
        for (id, item) in items where !ids.contains(id) {
            NSStatusBar.system.removeStatusItem(item)
            items[id] = nil
        }
        for context in contexts {
            let id = context.uniqueIdentifier
            let item = items[id] ?? {
                let made = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
                made.autosaveName = "extension.\(id)"
                made.button?.target = Clicks.shared
                made.button?.action = #selector(Clicks.clicked(_:))
                made.button?.identifier = NSUserInterfaceItemIdentifier(id)
                made.button?.imagePosition = .imageLeading
                items[id] = made
                return made
            }()
            let action = context.action(for: target)
            let icon = action?.icon(for: CGSize(width: 18, height: 18)) ?? context.webExtension.icon(for: CGSize(width: 18, height: 18))
            icon?.size = CGSize(width: 18, height: 18)
            item.button?.image = icon ?? NSImage(systemSymbolName: "puzzlepiece.extension", accessibilityDescription: nil)
            let badge = action?.badgeText ?? ""
            item.button?.title = badge
            item.button?.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
            item.button?.toolTip = action?.label ?? context.webExtension.displayName
            item.button?.appearsDisabled = action?.isEnabled == false
        }
    }

    /// A status item pressed: its extension's action, for the tab in front.
    final class Clicks: NSObject {
        static let shared = Clicks()

        @objc func clicked(_ sender: NSStatusBarButton) {
            guard let id = sender.identifier?.rawValue,
                  let context = Extensions.shared.contexts.first(where: { $0.uniqueIdentifier == id })
            else { return }
            let tab = Windows.front?.shell.selected
            let target = tab?.isPrivate == false ? tab : nil
            Debug.log("extension", "\(context.webExtension.displayName ?? "extension") pressed in the menu bar")
            context.performAction(for: target)
        }
    }
}
