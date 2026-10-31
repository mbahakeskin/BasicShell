import AppKit
import NaturalLanguage
import SwiftUI
import Translation
import WebKit

// Translating a page, on this Mac, with the system's own translation
// (Translation framework; nothing is sent to a server of ours or a page's).
// Pressed from the address field or the page's menu, never by itself.
//
// The page's text is found and changed in a script world of BasicShell's own
// (the page can't see it, and its scripts can't undo it), text node by text
// node, so the layout stays as it was. Pressed again, the page's own text
// goes back. A tab the agent works in is put back the same way first: an
// agent reads what the page says, not a translation of it.
//
// The system translates a sentence in about a quarter of a second on this
// Mac (measured: 250 ms each, however they are sent, 16 or 400 at a time) and
// the Mac works hard while it does. A whole shop page is thousands of strings:
// minutes, with the Mac at full tilt. So only what is on the screen and a
// screen below it is translated, the nearest first, and the rest when the
// page is scrolled to it or adds it (the script tells when). Each text once;
// text already in the language wanted is left; short ones go several to a
// request, which the model does faster (measured: 100 ms each).
//
// Or online, the way Chrome and Arc do it (Settings › General › Translate
// pages with, Google's by default): the page's texts go to Google's translation
// service in batches of a hundred, about 12 ms a text, with the Mac idle. That
// is the endpoint Chrome's own translation talks to, without a key of ours;
// Google can change or refuse it, and then the button says so.
//
// A language the Mac hasn't downloaded yet is not fetched from here: the
// person is told where macOS keeps that (System Settings › General ›
// Language & Region › Translation Languages).
nonisolated enum TranslateEngine: String, Sendable {
    case online, device

    static var current: TranslateEngine { TranslateEngine(rawValue: UserDefaults.standard.string(forKey: "translate.engine") ?? "") ?? .online }
}

@MainActor
enum Translate {
    private static let world = WKContentWorld.world(name: "BasicShellTranslate")
    private static var busy = Set<UUID>()
    /// Bumped each time a tab's translation is undone, so one still being made notices and stops.
    private static var epochs: [UUID: Int] = [:]
    private static var jobs: [UUID: Task<Void, Never>] = [:]

    /// Starts watching a page's text: the text nodes found so far, and the ones added later; wakes a waiting
    /// `__bsNext` when the page is scrolled or changes.
    private static let start = #"""
    if (window.__bsTranslate && window.__bsTranslate.live) return 1;
    const skip = new Set(['SCRIPT','STYLE','NOSCRIPT','CODE','PRE','TEXTAREA','INPUT','SVG','MATH','KBD','SAMP']);
    const st = { nodes: [], originals: [], given: [], live: true, wake: null, timer: null, seen: new WeakSet() };
    const accept = (node) => {
      const text = node.nodeValue;
      if (!text || text.trim().length < 2 || !/\p{L}/u.test(text)) return false;
      for (let e = node.parentElement; e; e = e.parentElement) {
        if (skip.has(e.tagName.toUpperCase()) || e.isContentEditable || e.getAttribute('translate') === 'no' || e.classList.contains('notranslate')) return false;
      }
      return true;
    };
    const scan = (root) => {
      const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
      for (let node = root.nodeType === 3 ? root : walker.nextNode(); node; node = root.nodeType === 3 ? null : walker.nextNode()) {
        if (st.seen.has(node)) continue;
        st.seen.add(node);
        if (!accept(node)) continue;
        st.nodes.push(node); st.originals.push(node.nodeValue); st.given.push(false);
      }
    };
    const poke = () => {
      clearTimeout(st.timer);
      st.timer = setTimeout(() => { const w = st.wake; st.wake = null; if (w) w(); }, 250);
    };
    scan(document.body);
    st.onscroll = poke;
    addEventListener('scroll', st.onscroll, { passive: true, capture: true });
    addEventListener('resize', st.onscroll);
    st.observer = new MutationObserver((records) => {
      for (const record of records) for (const added of record.addedNodes) if (added.nodeType === 1 || added.nodeType === 3) scan(added);
      poke();
    });
    st.observer.observe(document.body, { childList: true, subtree: true });
    window.__bsTranslate = st;
    return 1;
    """#

    /// The texts not yet given out that are on the screen or a screen below it, nearest first, at most `limit`;
    /// with `wait`, when there are none the call waits for the page to be scrolled or changed. Null once undone.
    private static let next = #"""
    const reach = innerHeight * 1.1;
    const more = () => {
      const st = window.__bsTranslate;
      if (!st || !st.live) return null;
      const found = [];
      for (let i = 0; i < st.nodes.length; i++) {
        if (st.given[i]) continue;
        const node = st.nodes[i];
        if (!node.isConnected) { st.given[i] = true; continue; }
        let top = 1e9;
        try {
          const range = document.createRange(); range.selectNodeContents(node);
          const r = range.getBoundingClientRect();
          if ((r.width > 0 || r.height > 0) && r.bottom > -100 && r.top < reach) top = Math.max(r.top, 0);
        } catch (e) {}
        if (top < 1e9) found.push([top, i]);
      }
      found.sort((a, b) => a[0] - b[0]);
      const chosen = found.slice(0, limit).map((pair) => pair[1]);
      for (const i of chosen) st.given[i] = true;
      return { indices: chosen, texts: chosen.map((i) => st.originals[i]), lang: document.documentElement.lang || '' };
    };
    let result = more();
    while (wait && result && result.indices.length === 0) {
      await new Promise((resolve) => { window.__bsTranslate.wake = resolve; });
      result = more();
    }
    return result;
    """#

    private static let apply = #"""
    const state = window.__bsTranslate;
    if (!state) return 0;
    for (let k = 0; k < indices.length; k++) {
      const i = indices[k];
      const node = state.nodes[i], original = state.originals[i];
      if (!node || !node.isConnected) continue;
      const lead = original.match(/^\s*/)[0], tail = original.match(/\s*$/)[0];
      node.nodeValue = lead + translated[k].trim() + tail;
    }
    return state.nodes.length;
    """#

    private static let restore = #"""
    const state = window.__bsTranslate;
    if (!state) return 0;
    state.live = false;
    clearTimeout(state.timer);
    try { state.observer.disconnect(); } catch (e) {}
    removeEventListener('scroll', state.onscroll, { capture: true });
    removeEventListener('resize', state.onscroll);
    for (let i = 0; i < state.nodes.length; i++) if (state.nodes[i].isConnected && state.given[i]) state.nodes[i].nodeValue = state.originals[i];
    const wake = state.wake; state.wake = null;
    window.__bsTranslate = null;
    if (wake) wake();
    return 1;
    """#

    /// The language to translate into: the Mac's first.
    private static var target: Locale.Language {
        Locale.preferredLanguages.first.map { Locale.Language(identifier: $0) } ?? Locale.current.language ?? Locale.Language(identifier: "en")
    }

    /// Translates the page, or puts its own text back.
    static func toggle(_ tab: Tab, in window: BrowserWindow) {
        if tab.isTranslated || tab.isTranslating { undo(tab) } else { translate(tab, in: window) }
    }

    /// The agent's reads see the page's own text: whatever was translated is put back.
    static func undo(_ tab: Tab) {
        guard tab.isTranslated || tab.isTranslating || jobs[tab.id] != nil, let web = tab.webView else { return }
        epochs[tab.id, default: 0] += 1
        jobs[tab.id]?.cancel()
        tab.isTranslated = false
        tab.isTranslating = false
        // Sent now, not from a task, so whatever the agent asks next is behind it.
        web.callAsyncJavaScript(restore, arguments: [:], in: nil, in: world, completionHandler: { _ in })
    }

    private static func translate(_ tab: Tab, in window: BrowserWindow) {
        guard let web = tab.webView, !tab.isFrozen, !busy.contains(tab.id) else { return }
        busy.insert(tab.id)
        tab.isTranslating = true
        let epoch = epochs[tab.id] ?? 0
        let engine = TranslateEngine.current
        jobs[tab.id] = Task {
            defer {
                if (epochs[tab.id] ?? 0) == epoch { tab.isTranslating = false }
                busy.remove(tab.id)
                jobs[tab.id] = nil
            }
            do {
                _ = try await web.callAsyncJavaScript(start, arguments: [:], in: nil, contentWorld: world)
                guard let first = try await web.callAsyncJavaScript(next, arguments: ["limit": 14, "wait": false], in: nil, contentWorld: world) as? [String: Any],
                      let texts = first["texts"] as? [String]
                else { return }
                guard !texts.isEmpty else { return tell("There's no text on this page to translate.", window) }
                let source = language(of: texts, declared: first["lang"] as? String ?? "")
                guard let source else { return tell("The page's language couldn't be told.", window) }
                let goal = target
                if source.minimalIdentifier == goal.minimalIdentifier {
                    _ = try? await web.callAsyncJavaScript(restore, arguments: [:], in: nil, contentWorld: world)
                    return tell("The page is already in \(name(of: goal)).", window)
                }
                switch engine == .online ? .installed : await LanguageAvailability().status(from: source, to: goal) {
                case .installed: break
                case .supported:
                    _ = try? await web.callAsyncJavaScript(restore, arguments: [:], in: nil, contentWorld: world)
                    return needsDownload(from: source, to: goal, window)
                default:
                    _ = try? await web.callAsyncJavaScript(restore, arguments: [:], in: nil, contentWorld: world)
                    return tell("\(name(of: source)) to \(name(of: goal)) isn't something the system can translate.", window)
                }
                nonisolated(unsafe) let page = web
                nonisolated(unsafe) let held = tab
                // Pieces come from the page as it is scrolled; the first piece is already out.
                let pending = Pending(indices: (first["indices"] as? [Int]) ?? [], texts: texts)
                let more: @Sendable () async throws -> ([Int], [String])? = {
                    if let ready = pending.take() { return ready }
                    guard await live(held, page, epoch) else { return nil }
                    guard let near = try await fetch(page, limit: engine == .online ? 160 : 40, wait: false) else { return nil }
                    if !near.0.isEmpty { return near }
                    // Nothing left near the screen: rest (the button stops spinning) until the page is scrolled or changes.
                    await rest(held, true)
                    defer { Task { await rest(held, false, epoch: epoch) } }
                    return try await fetch(page, limit: engine == .online ? 160 : 40, wait: true)
                }
                let delivered: @Sendable ([Int], [String]) async -> Bool = { indices, out in
                    await MainActor.run {
                        guard held.webView === page, (epochs[held.id] ?? 0) == epoch else { return false }
                        page.callAsyncJavaScript(apply, arguments: ["indices": indices, "translated": out], in: nil, in: world, completionHandler: { _ in })
                        held.isTranslated = true
                        return true
                    }
                }
                try await pump(from: source, to: goal, engine: engine, more: more, deliver: delivered)
            } catch is CancellationError {
            } catch let error as OnlineTranslate.Failure {
                Debug.log("translate", "\(tab.name): online: \(error.message)")
                if (epochs[tab.id] ?? 0) == epoch {
                    tell("Google's translation didn't answer (\(error.message)). Settings › General › Translate pages with can use this Mac's instead.", window)
                }
            } catch {
                // A page that went away under the script is the end of it, not an error to show.
                if (error as NSError).domain != WKError.errorDomain { Debug.log("translate", "\(tab.name): \(error)") }
            }
        }
    }

    private static func live(_ tab: Tab, _ page: WKWebView, _ epoch: Int) -> Bool { tab.webView === page && (epochs[tab.id] ?? 0) == epoch }

    /// The button spins while there is something to translate and rests while the loop waits for the page.
    private static func rest(_ tab: Tab, _ resting: Bool, epoch: Int? = nil) {
        if let epoch, (epochs[tab.id] ?? 0) != epoch { return }
        tab.isTranslating = !resting
    }

    /// The next texts from the page, as plain arrays.
    private static func fetch(_ page: WKWebView, limit: Int, wait: Bool) async throws -> ([Int], [String])? {
        guard let result = try await page.callAsyncJavaScript(next, arguments: ["limit": limit, "wait": wait], in: nil, contentWorld: world) as? [String: Any] else { return nil }
        return ((result["indices"] as? [Int]) ?? [], (result["texts"] as? [String]) ?? [])
    }

    /// What the page gave out first, kept for the loop to take.
    private nonisolated final class Pending: @unchecked Sendable {
        private var indices: [Int]?
        private var texts: [String]?
        init(indices: [Int], texts: [String]) { self.indices = indices; self.texts = texts }
        func take() -> ([Int], [String])? {
            guard let indices, let texts else { return nil }
            self.indices = nil
            self.texts = nil
            return (indices, texts)
        }
    }

    /// Off the main actor, one session for as long as the page is being translated (the session and its requests
    /// don't cross the actor; making one per piece loaded the language model again each time).
    private nonisolated static func pump(from source: Locale.Language, to goal: Locale.Language, engine: TranslateEngine,
                                         more: @Sendable () async throws -> ([Int], [String])?,
                                         deliver: @Sendable ([Int], [String]) async -> Bool) async throws {
        let session: TranslationSession? = engine == .device ? TranslationSession(installedSource: source, target: goal) : nil
        let wanted = goal.minimalIdentifier
        var done: [String: String] = [:]
        while let (indices, texts) = try await more() {
            try Task.checkCancellation()
            // What to translate: each text once, not what is already in the language wanted.
            var todo: [String] = []
            for text in texts where done[text] == nil && !todo.contains(text) {
                if text.count >= 12, language(of: text) == wanted { done[text] = text } else { todo.append(text) }
            }
            var sent = Set<Int>()
            // Out as each group is done, so the page changes as it goes.
            func flush() async -> Bool {
                let ready = texts.indices.filter { !sent.contains($0) && done[texts[$0]] != nil }
                guard !ready.isEmpty else { return true }
                sent.formUnion(ready)
                return await deliver(ready.map { indices[$0] }, ready.map { done[texts[$0]] ?? texts[$0] })
            }
            if !(await flush()) { return }
            // On this Mac a few short ones to a request; online a hundred.
            var at = 0
            while at < todo.count {
                var group: [String] = [], length = 0
                let most = session == nil ? 100 : 8, longest = session == nil ? 12000 : 500
                while at < todo.count, group.count < most, length + todo[at].count < longest {
                    group.append(todo[at]); length += todo[at].count; at += 1
                }
                if group.isEmpty { group = [todo[at]]; at += 1 }
                let result: [String]
                if let session { result = try await translateGroup(group, with: session) } else { result = try await OnlineTranslate.translate(group, to: goal) }
                for (text, answer) in zip(group, result) { done[text] = answer }
                if !(await flush()) { return }
            }
        }
    }

    private nonisolated static func translateGroup(_ group: [String], with session: TranslationSession) async throws -> [String] {
        guard group.count > 1, !group.contains(where: { $0.contains("|") }) else {
            var out: [String] = []
            for text in group { out.append(try await session.translate(text).targetText) }
            return out
        }
        let joined = try await session.translate(group.joined(separator: " | ")).targetText
        let parts = joined.components(separatedBy: " | ")
        if parts.count == group.count { return parts }
        // The separators didn't survive: one by one.
        var out: [String] = []
        for text in group { out.append(try await session.translate(text).targetText) }
        return out
    }

    private nonisolated static func language(of text: String) -> String? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let best = recognizer.dominantLanguage, (recognizer.languageHypotheses(withMaximum: 1)[best] ?? 0) > 0.9 else { return nil }
        return Locale.Language(identifier: best.rawValue).minimalIdentifier
    }

    private static func language(of texts: [String], declared: String) -> Locale.Language? {
        // What the page says it is in, when it says: the first few strings can be a menu of brand names.
        if !declared.isEmpty { return Locale.Language(identifier: declared) }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(texts.joined(separator: " ").prefix(4000)))
        return recognizer.dominantLanguage.map { Locale.Language(identifier: $0.rawValue) }
    }

    private static func name(of language: Locale.Language) -> String {
        Locale.current.localizedString(forLanguageCode: language.minimalIdentifier) ?? language.minimalIdentifier
    }

    private static func tell(_ message: String, _ window: BrowserWindow) { window.say(message) }

    private static func needsDownload(from source: Locale.Language, to goal: Locale.Language, _ window: BrowserWindow) {
        let alert = NSAlert()
        alert.messageText = "Download \(name(of: source)) first"
        alert.informativeText = "Translating \(name(of: source)) into \(name(of: goal)) needs the language on this Mac. macOS downloads it under System Settings › General › Language & Region › Translation Languages; then press the button again."
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.Localization-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// Google's translation service, as Chrome calls it: texts in, texts out, in one request.
nonisolated enum OnlineTranslate {
    struct Failure: Error {
        let message: String
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.httpMaximumConnectionsPerHost = 4
        return URLSession(configuration: configuration)
    }()

    /// Google's code for a language: Chinese by script, the rest as the Mac names it.
    private static func code(_ language: Locale.Language) -> String {
        if language.languageCode?.identifier == "zh" { return language.script?.identifier == "Hant" ? "zh-TW" : "zh-CN" }
        return language.languageCode?.identifier ?? language.minimalIdentifier
    }

    static func translate(_ texts: [String], to goal: Locale.Language) async throws -> [String] {
        var parts = URLComponents(string: "https://translate.googleapis.com/translate_a/t")!
        parts.queryItems = [URLQueryItem(name: "client", value: "gtx"), URLQueryItem(name: "sl", value: "auto"),
                            URLQueryItem(name: "tl", value: code(goal)), URLQueryItem(name: "format", value: "text")]
        var request = URLRequest(url: parts.url!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        request.httpBody = texts.map { "q=" + ($0.addingPercentEncoding(withAllowedCharacters: allowed) ?? "") }.joined(separator: "&").data(using: .utf8)
        let (data, response): (Data, URLResponse)
        do { (data, response) = try await session.data(for: request) } catch is CancellationError { throw CancellationError() } catch { throw Failure(message: error.localizedDescription) }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw Failure(message: "answer \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        guard let list = (try? JSONSerialization.jsonObject(with: data)) as? [Any], list.count == texts.count else {
            throw Failure(message: "an answer it couldn't read")
        }
        // Each is the text, or the text and the language it was taken to be in.
        return list.enumerated().map { index, item in
            if let text = item as? String { return text }
            if let pair = item as? [Any], let text = pair.first as? String { return text }
            return texts[index]
        }
    }
}

/// The button in the address field: lit while the page is translated.
struct TranslateButton: View {
    let tab: Tab?
    let window: BrowserWindow

    var body: some View {
        if let tab, let url = tab.url, ["http", "https"].contains(url.scheme ?? "") {
            Button { Translate.toggle(tab, in: window) } label: {
                Group {
                    if tab.isTranslating {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: NSImage(systemSymbolName: "translate", accessibilityDescription: nil) == nil ? "globe" : "translate")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(tab.isTranslated ? Color.accentColor : Color.primary)
                    }
                }
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help(tab.isTranslated ? "Show the Original Page" : "Translate This Page")
        }
    }
}
