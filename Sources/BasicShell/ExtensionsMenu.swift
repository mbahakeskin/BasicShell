import AppKit
import WebKit

// The Extensions menu in the menu bar, as in Arc: each extension with its
// icon, chosen for the tab in front, then adding and managing them. In the
// sidebar-only layout it is where the extensions are (the sidebar has no
// room for their buttons); the popup opens at the top of the window, under
// where it was chosen (BrowserWindow.present(_:for:)).
@MainActor
enum ExtensionsMenu {
    /// Where on the screen an extension was last chosen, for its popup.
    private(set) static var chosenAt: NSPoint?

    static func build() -> NSMenu {
        let menu = NSMenu(title: "Extensions")
        menu.delegate = Filler.shared
        return menu
    }

    final class Filler: NSObject, NSMenuDelegate {
        static let shared = Filler()

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            let tab = Windows.front?.shell.selected
            let target = tab?.isPrivate == false ? tab : nil
            for context in Extensions.shared.contexts {
                let action = context.action(for: target)
                let item = NSMenuItem(title: context.webExtension.displayName ?? "Extension", action: #selector(chosen(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = context.uniqueIdentifier
                let icon = action?.icon(for: CGSize(width: 16, height: 16)) ?? context.webExtension.icon(for: CGSize(width: 16, height: 16))
                    ?? NSImage(systemSymbolName: "puzzlepiece.extension", accessibilityDescription: nil)
                // The icon in the title: set as the item's image, the menu
                // bar's menus leave it out (measured).
                if let icon {
                    let attachment = NSTextAttachment()
                    attachment.image = icon
                    attachment.bounds = CGRect(x: 0, y: -3, width: 16, height: 16)
                    let title = NSMutableAttributedString(attachment: attachment)
                    title.append(NSAttributedString(string: "  " + item.title, attributes: [.font: NSFont.menuFont(ofSize: 0)]))
                    item.attributedTitle = title
                }
                if let badge = action?.badgeText, !badge.isEmpty { item.badge = NSMenuItemBadge(string: badge) }
                item.isEnabled = action?.isEnabled ?? true
                menu.addItem(item)
            }
            if !Extensions.shared.contexts.isEmpty { menu.addItem(.separator()) }
            let add = NSMenuItem(title: "Add Extension…", action: #selector(manage(_:)), keyEquivalent: "")
            add.target = self
            menu.addItem(add)
            let manage = NSMenuItem(title: "Manage Extensions…", action: #selector(manage(_:)), keyEquivalent: "")
            manage.target = self
            menu.addItem(manage)
        }

        @objc func chosen(_ item: NSMenuItem) {
            guard let id = item.representedObject as? String,
                  let context = Extensions.shared.contexts.first(where: { $0.uniqueIdentifier == id })
            else { return }
            ExtensionsMenu.chosenAt = NSEvent.mouseLocation
            let tab = Windows.front?.shell.selected
            Debug.log("extension", "\(context.webExtension.displayName ?? "extension") chosen from the Extensions menu")
            context.performAction(for: tab?.isPrivate == false ? tab : nil)
        }

        @objc func manage(_ item: NSMenuItem) {
            SettingsWindow.show("extensions")
        }
    }
}
