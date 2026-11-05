import AppKit
import Observation
import SwiftUI
import WebKit

// Find in the page (⌘F): a small field at the page's top right, the matches
// marked on the page and counted, ⌘G and ⇧⌘G (or Return and ⇧Return) for the
// next and the one before, Esc to put it away.
//
// WebKit's public `find(_:configuration:)` finds one match at a time and
// says nothing of how many there are. Safari's finding is private:
// `_findString:options:maxCount:` marks every match, shows which one is
// current, and reports to a `_findDelegate` how many there are and which
// this is; `_hideFindUI` takes the marks away. Used where WebKit has them,
// the public one otherwise.

/// What the field shows, for one window.
@Observable
final class FindState {
    var text = ""
    /// How many matches, when WebKit has said.
    var matches: Int?
    /// Which of them is current, from zero.
    var index: Int?
    var notFound = false
    /// Raised to put the keyboard in the field again.
    var focus = 0
}

/// The finding itself, in whichever page a window shows.
final class PageFinder: NSObject {
    private let state: FindState

    init(state: FindState) { self.state = state }

    // WebKit's _WKFindOptions.
    private static let caseInsensitive: UInt = 1 << 0
    private static let backwards: UInt = 1 << 3
    private static let wrapAround: UInt = 1 << 4
    private static let showFindIndicator: UInt = 1 << 6
    private static let showHighlight: UInt = 1 << 7
    private static let determineMatchIndex: UInt = 1 << 9

    private static let findString = NSSelectorFromString("_findString:options:maxCount:")
    private static let setDelegate = NSSelectorFromString("_setFindDelegate:")
    private static let hide = NSSelectorFromString("_hideFindUI")

    /// As the text is typed: from where the match so far begins, so one
    /// more letter keeps it rather than going on to the next (WebKit looks
    /// on from the end of what is selected).
    func searchAsTyped(_ text: String, in web: WKWebView) {
        guard !text.isEmpty else { return clear(web) }
        web.evaluateJavaScript("(() => { const s = getSelection(); if (s && s.rangeCount) s.collapseToStart(); })()") { [weak self, weak web] _, _ in
            MainActor.assumeIsolated {
                guard let self, let web, text == self.state.text else { return }
                self.search(text, in: web)
            }
        }
    }

    func search(_ text: String, in web: WKWebView, backwards: Bool = false) {
        guard !text.isEmpty else { return clear(web) }
        guard web.responds(to: PageFinder.findString), web.responds(to: PageFinder.setDelegate),
              let method = class_getInstanceMethod(WKWebView.self, PageFinder.findString)
        else {
            let configuration = WKFindConfiguration()
            configuration.backwards = backwards
            configuration.caseSensitive = false
            configuration.wraps = true
            web.find(text, configuration: configuration) { [state] result in
                MainActor.assumeIsolated {
                    state.matches = nil
                    state.index = nil
                    state.notFound = !result.matchFound
                }
            }
            return
        }
        web.perform(PageFinder.setDelegate, with: self)
        typealias Find = @convention(c) (AnyObject, Selector, NSString, UInt, UInt) -> Void
        var options = PageFinder.caseInsensitive | PageFinder.wrapAround | PageFinder.showFindIndicator
            | PageFinder.showHighlight | PageFinder.determineMatchIndex
        if backwards { options |= PageFinder.backwards }
        unsafeBitCast(method_getImplementation(method), to: Find.self)(web, PageFinder.findString, text as NSString, options, 1000)
    }

    /// The marks off the page.
    func clear(_ web: WKWebView?) {
        state.matches = nil
        state.index = nil
        state.notFound = false
        guard let web, web.responds(to: PageFinder.hide) else { return }
        web.perform(PageFinder.hide)
    }

    // MARK: - what WebKit reports (its private _WKFindDelegate)

    @objc(_webView:didFindMatches:forString:withMatchIndex:)
    func found(_ web: WKWebView, _ matches: UInt, _ string: String, _ index: Int) {
        guard string == state.text else { return }
        state.matches = Int(matches)
        state.index = index >= 0 && index < Int(matches) ? index : nil
        state.notFound = matches == 0
    }

    @objc(_webView:didCountMatches:forString:)
    func counted(_ web: WKWebView, _ matches: UInt, _ string: String) {
        guard string == state.text else { return }
        state.matches = Int(matches)
        state.notFound = matches == 0
    }

    @objc(_webView:didFailToFindString:)
    func failed(_ web: WKWebView, _ string: String) {
        guard string == state.text else { return }
        state.matches = 0
        state.index = nil
        state.notFound = true
    }
}

/// The field, on glass.
struct FindBarView: View {
    let state: FindState
    let window: BrowserWindow
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            TextField("Find in page", text: Binding(get: { state.text }, set: { state.text = $0 }))
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($focused)
                .onSubmit { window.findNext(nil) }
                .onKeyPress(keys: [.return]) { press in
                    guard press.modifiers.contains(.shift) else { return .ignored }
                    window.findPrevious(nil)
                    return .handled
                }
            Text(status)
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(state.notFound ? Color.red : Color.secondary)
                .lineLimit(1)
                .fixedSize()
            IconButton(symbol: "chevron.up", enabled: !state.text.isEmpty && !state.notFound) { window.findPrevious(nil) }
                .help("Previous Match (⇧⌘G)")
            IconButton(symbol: "chevron.down", enabled: !state.text.isEmpty && !state.notFound) { window.findNext(nil) }
                .help("Next Match (⌘G)")
            IconButton(symbol: "xmark") { window.closeFind() }
                .help("Done (Esc)")
        }
        .padding(.leading, 12)
        .padding(.trailing, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .glassEffect(.regular, in: .rect(cornerRadius: Metrics.radius))
        .onAppear { focused = true }
        .onChange(of: state.focus) { _, _ in focused = true }
        .onChange(of: state.text) { _, _ in window.findChanged() }
    }

    private var status: String {
        if state.text.isEmpty { return "" }
        if state.notFound { return "Not found" }
        guard let matches = state.matches else { return "" }
        if let index = state.index { return "\(index + 1) of \(matches)" }
        return matches == 1 ? "1 match" : "\(matches) matches"
    }
}
