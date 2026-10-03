import AppKit

// Which way the desktop now shown lies from a window's, so a video leaving
// for Picture in Picture can leave the way that desktop went (see PiP).
//
// macOS keeps no public record of the order of desktops; its private
// SkyLight functions `CGSCopyManagedDisplaySpaces` (each display's desktops
// in Mission Control's order, and the one shown) and
// `CGSCopySpacesForWindows` (a window's desktop) have it. Looked up when
// needed; without them the answer is "don't know".
enum Spaces {
    private typealias MainConnection = @convention(c) () -> Int32
    private typealias CopyManaged = @convention(c) (Int32) -> Unmanaged<CFArray>?
    private typealias CopyForWindows = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?

    private static let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)

    private static func function<T>(_ name: String, as type: T.Type) -> T? {
        guard let skyLight, let found = dlsym(skyLight, name) else { return nil }
        return unsafeBitCast(found, to: type)
    }

    private static func id(_ space: [String: Any]) -> UInt64? {
        ((space["ManagedSpaceID"] ?? space["id64"]) as? NSNumber)?.uint64Value
    }

    /// -1 when the desktop shown now is to the left of `window`'s, 1 when to
    /// the right, 0 when it is the same one or there's no telling.
    static func direction(from window: NSWindow) -> Int {
        guard let connection = function("CGSMainConnectionID", as: MainConnection.self),
              let copyManaged = function("CGSCopyManagedDisplaySpaces", as: CopyManaged.self),
              let copyForWindows = function("CGSCopySpacesForWindows", as: CopyForWindows.self)
        else { return 0 }
        let cid = connection()
        guard let mine = (copyForWindows(cid, 0x7, [window.windowNumber] as CFArray)?.takeRetainedValue() as? [NSNumber])?.first?.uint64Value,
              let displays = copyManaged(cid)?.takeRetainedValue() as? [[String: Any]]
        else { return 0 }
        for display in displays {
            let order = ((display["Spaces"] as? [[String: Any]]) ?? []).compactMap(id)
            guard let from = order.firstIndex(of: mine) else { continue }
            guard let shown = (display["Current Space"] as? [String: Any]).flatMap(id),
                  let to = order.firstIndex(of: shown), to != from
            else { return 0 }
            return to < from ? -1 : 1
        }
        return 0
    }
}
