#if AGENT
import AppKit
import WebKit

// The agent's clicks and keys (see Agent.swift).
//
// They are made as AppKit's own events and handed straight to the page's
// view, as the window would hand it the person's: the page takes them for
// real ones (`isTrusted`), where a click made by script is one a page can
// tell and may ignore. Nothing goes through the screen: the pointer stays
// where the person has it, and it works in a tab behind the one shown.
enum AgentInput {
    private static var number = 0

    /// A point in the view's own points, from its top left, as one in its window.
    private static func inWindow(_ point: CGPoint, _ web: WKWebView) -> NSPoint {
        web.convert(NSPoint(x: point.x, y: web.isFlipped ? point.y : web.bounds.height - point.y), to: nil)
    }

    private static func mouse(_ type: NSEvent.EventType, _ web: WKWebView, at point: CGPoint, count: Int, modifiers: NSEvent.ModifierFlags) -> NSEvent? {
        number += 1
        return NSEvent.mouseEvent(with: type, location: inWindow(point, web), modifierFlags: modifiers,
                                  timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: web.window?.windowNumber ?? 0,
                                  context: nil, eventNumber: number, clickCount: count, pressure: type == .leftMouseUp || type == .rightMouseUp ? 0 : 1)
    }

    static func move(_ web: WKWebView, to point: CGPoint) {
        guard let event = mouse(.mouseMoved, web, at: point, count: 0, modifiers: []) else { return }
        web.mouseMoved(with: event)
    }

    static func click(_ web: WKWebView, at point: CGPoint, right: Bool, count: Int, modifiers: NSEvent.ModifierFlags) {
        move(web, to: point)
        for click in 1...max(count, 1) {
            guard let down = mouse(right ? .rightMouseDown : .leftMouseDown, web, at: point, count: click, modifiers: modifiers),
                  let up = mouse(right ? .rightMouseUp : .leftMouseUp, web, at: point, count: click, modifiers: modifiers)
            else { return }
            if right {
                web.rightMouseDown(with: down)
                web.rightMouseUp(with: up)
            } else {
                web.mouseDown(with: down)
                web.mouseUp(with: up)
            }
        }
    }

    /// The left button pressed at one place, the pointer taken to another in
    /// small steps, and let go there.
    static func drag(_ web: WKWebView, from: CGPoint, to: CGPoint, modifiers: NSEvent.ModifierFlags) async {
        move(web, to: from)
        guard let down = mouse(.leftMouseDown, web, at: from, count: 1, modifiers: modifiers) else { return }
        web.mouseDown(with: down)
        try? await Task.sleep(for: .milliseconds(40))
        let steps = max(8, min(40, Int(hypot(to.x - from.x, to.y - from.y) / 12)))
        for step in 1...steps {
            let t = CGFloat(step) / CGFloat(steps)
            let point = CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t)
            if let event = mouse(.leftMouseDragged, web, at: point, count: 1, modifiers: modifiers) { web.mouseDragged(with: event) }
            try? await Task.sleep(for: .milliseconds(16))
        }
        try? await Task.sleep(for: .milliseconds(40))
        if let up = mouse(.leftMouseUp, web, at: to, count: 1, modifiers: modifiers) { web.mouseUp(with: up) }
    }

    /// Text into whatever has the keyboard in the page, as the input method
    /// would put it: for a field the page's own script couldn't reach
    /// (another site's frame).
    static func insert(_ text: String, in web: WKWebView) {
        // NSTextInputClient's, which WKWebView answers without saying so.
        let selector = NSSelectorFromString("insertText:replacementRange:")
        guard web.responds(to: selector), let method = class_getMethodImplementation(type(of: web), selector) else { return }
        typealias Insert = @convention(c) (AnyObject, Selector, AnyObject, NSRange) -> Void
        unsafeBitCast(method, to: Insert.self)(web, selector, text as NSString, NSRange(location: NSNotFound, length: 0))
    }

    private static let named: [String: (code: UInt16, characters: String)] = [
        "enter": (36, "\r"), "return": (36, "\r"), "tab": (48, "\t"), "space": (49, " "), "escape": (53, "\u{1B}"), "esc": (53, "\u{1B}"),
        "backspace": (51, "\u{7F}"), "delete": (117, "\u{F728}"),
        "arrowup": (126, "\u{F700}"), "arrowdown": (125, "\u{F701}"), "arrowleft": (123, "\u{F702}"), "arrowright": (124, "\u{F703}"),
        "up": (126, "\u{F700}"), "down": (125, "\u{F701}"), "left": (123, "\u{F702}"), "right": (124, "\u{F703}"),
        "home": (115, "\u{F729}"), "end": (119, "\u{F72B}"), "pageup": (116, "\u{F72C}"), "pagedown": (121, "\u{F72D}"),
    ]

    /// Where each character's key is on a US keyboard.
    private static let codes: [Character: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
        "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33,
        "i": 34, "p": 35, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, "`": 50,
    ]

    /// One key, with what is held: "Enter", "cmd+a", "shift+Tab", "x".
    /// False for a key BasicShell has no name for.
    @discardableResult
    static func press(_ key: String, in web: WKWebView) -> Bool {
        var parts = key.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        // "+" itself, alone or last ("cmd++").
        if key == "+" { parts = ["+"] } else if key.hasSuffix("++") { parts = Array(parts.dropLast(2)) + ["+"] }
        guard let last = parts.last, !last.isEmpty else { return false }
        var flags: NSEvent.ModifierFlags = []
        for held in parts.dropLast() {
            switch held.lowercased() {
            case "cmd", "command", "meta": flags.insert(.command)
            case "shift": flags.insert(.shift)
            case "alt", "option", "opt": flags.insert(.option)
            case "ctrl", "control": flags.insert(.control)
            default: return false
            }
        }
        let code: UInt16
        var characters: String
        if let known = named[last.lowercased()] {
            (code, characters) = known
            if [123, 124, 125, 126, 115, 116, 119, 121, 117].contains(code) { flags.insert(.function) }
        } else if last.count == 1, let character = last.lowercased().first {
            code = codes[character] ?? (character == "+" ? 24 : 0)
            characters = flags.contains(.shift) ? last.uppercased() : last
        } else {
            return false
        }
        let plain = characters.lowercased()
        if flags.contains(.shift), code == 48 { characters = "\u{19}" }
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                               windowNumber: web.window?.windowNumber ?? 0, context: nil, characters: characters,
                                               charactersIgnoringModifiers: plain, isARepeat: false, keyCode: code)
            else { return false }
            if type == .keyDown { web.keyDown(with: event) } else { web.keyUp(with: event) }
        }
        return true
    }
}
#endif
