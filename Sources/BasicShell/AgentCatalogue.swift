#if AGENT
import Foundation

// What the agent is handed of each tool is short: its name, a line, its
// parameters and their types. Each tool's whole description (what the
// parameters mean, the cases, the limits) is in `full` (AgentTools.swift),
// and `help` says it when it is wanted. The list went from about 33,000
// characters, which the agent reads at every start and in every turn, to
// about 16,500 (with four more tools).
extension AgentTools {
    /// A line for each tool.
    static let lines: [String: String] = [
        "tabs": "List open tabs: number, title, address, state. Filter: from_tab to_tab, yours, query, window. No private ones.",
        "open": "Open address in a new background tab, wait, list its controls. http, https, file.",
        "close": "Close a tab.",
        "select": "Show a tab to the person.",
        "navigate": "Go to an address, or back, forward, reload, hard_reload. Lists the page's controls.",
        "read_text": "The page's text. Long page: offset. selector or main for a part; structured for products (name, price, stock).",
        "read_page": "The page's controls with refs, to click or fill by ref. filter all: text too. since_last: only what changed.",
        "find": "Controls or text by words, with refs; `queries` looks up several at once.",
        "screenshot": "Picture of the tab. max_width, quality, region or ref, marks (refs drawn on it), full_page with tile or overview.",
        "click": "Click a ref, a label (what it says), a selector, or x y in a screenshot. Says what changed; expect checks the result.",
        "hover": "Pointer over a ref, label, selector or x y. Says what appeared.",
        "drag": "Drag from ref, label, selector or x y to to_ref, to_label, to_selector or to_x to_y.",
        "type": "Type text where the keyboard is, or into a ref, label or selector. submit: Enter after.",
        "key": "Press keys, space-separated (Enter Tab cmd+a). repeat.",
        "scroll": "Scroll the page, or bring a ref, label or selector into view.",
        "fill": "Set a field by ref, label or selector: text, choice, or true false.",
        "fill_form": "Fill many fields [{ref or label, value}] in one call, then submit (Enter, or click submit_ref or submit_label).",
        "search": "Search the site: finds its search field, types the query, Enter.",
        "read_pages": "Read up to 25 addresses in one call: each page's text, links optional.",
        "upload": "Give files (full paths) to a file field ref. The person is asked.",
        "dialog": "Answer the page's alert, confirm or prompt.",
        "wait": "Wait seconds, or until text, gone, selector, url_contains or network_idle.",
        "console": "The page's console lines. Developer tools.",
        "network": "The page's requests; show N for one's details. Developer tools.",
        "api": "The page's own fetch/XHR calls (list), or what one returns: JSON shape and sample, or path + fields as rows. Developer tools.",
        "evaluate": "Run JavaScript in the page (async function body, return the answer; values in args). Developer tools.",
        "history": "Visited pages found by words. Switch: history.",
        "bookmarks": "Bookmarks found by words. Switch: history.",
        "downloads": "Downloads, running, paused and finished. Switch: history.",
        "save_page": "Save the page as pdf or webarchive in Downloads.",
        "record": "Record the tab as a GIF: start, stop.",
        "resize": "Window size, preset (mobile tablet desktop), user_agent, color_scheme, zoom.",
        "selection": "The text the person selected.",
        "arrange": "Pin, unpin, duplicate, sleep, move or new_window a tab. Switch: tabs.",
        "clipboard": "Read or write the clipboard text. Switch: clipboard.",
        "extensions": "List, errors, console or reload extensions. Switch: extensions.",
        "download": "Save the file at an address into Downloads.",
        "inspect": "An element's styles, box, html by ref. Developer tools.",
        "performance": "Load timings, paints, slowest requests. Developer tools.",
        "block": "Block requests with these words in the address, or clear. Developer tools.",
        "render": "Tab without javascript, images or styles (false = off); reloads. Developer tools.",
        "source": "The page's source as the site sent it. Developer tools.",
        "site_info": "Connection security, certificate, permissions, cookie count, zoom, how the tab is set.",
        "features": "List, set or reset WebKit features (not privacy or security). Switch: WebKit features.",
        "settle": "How a click's effects are known to be over: tracker (script in the page), inspector (nothing in the page, ~130 MB a tab) or window. No mode: which is in use.",
        "storage": "Cookies, local or session storage, databases: read, delete, clear. Switch: storage.",
        "batch": "Run up to 20 {name, input, optional, repeat} tools in order; stops at the first that fails (unless optional). repeat: until it fails.",
        "help": "The whole description of a tool (what its parameters mean, limits, cases); no tool: the list.",
    ]

    /// What a parameter says where its name doesn't.
    private static let hints: [String: String] = [
        "x": "px in the last screenshot", "y": "px in the last screenshot",
        "to_x": "px in the last screenshot", "to_y": "px in the last screenshot",
        "region": "[left, top, right, bottom] px of the last whole-view screenshot",
        "observe": "changes (default): what changed after; none",
        "keys": "space-separated, e.g. Enter Tab cmd+a",
        "modifiers": "cmd shift alt ctrl joined by +",
        "code": "async function body; return the answer",
        "paths": "full file paths",
        "label": "what it says (name or text), instead of ref",
        "selector": "CSS selector, instead of ref",
        "role": "with label or selector: button, link, textbox…",
        "nth": "which of several matches, 1 = first",
        "picture": "number a region or tile screenshot gave, for x y in it",
        "expect": "{text, gone, selector, url_contains, seconds}: fails if the page isn't so",
        "args": "values for the code, read there as args.name",
        "main": "only the main area, without menu and footer",
        "structured": "products the page declares: name, brand, price, stock",
        "from_tab": "first tab number", "to_tab": "last tab number",
        "yours": "only tabs the agent opened",
        "to_label": "where to let go: what it says", "to_selector": "where to let go: CSS selector",
        "submit_label": "name of the button to click after",
        "full_urls": "addresses whole, not cut",
        "request": "number of a call in the api list",
        "path": "place in the JSON: data.items[*].name",
        "fields": "what to take from each item: [name, price]",
        "since_last": "only what changed since your last read_page of this page",
    ]

    private static func terse(_ schema: Any, _ key: String? = nil) -> Any {
        guard var dict = schema as? [String: Any] else { return schema }
        dict.removeValue(forKey: "description")
        if let key, let hint = hints[key] {
            // `observe` says one thing for the tools that act and another for those that open a page.
            let page = (dict["enum"] as? [String])?.contains("page") == true
            dict["description"] = key == "observe" && page ? "page (default): list the page's controls; none" : hint
        }
        // What an object takes is in its hint, and in `help`.
        if key == "expect" { dict.removeValue(forKey: "properties") }
        if let properties = dict["properties"] as? [String: Any] {
            var kept: [String: Any] = [:]
            for (name, value) in properties { kept[name] = terse(value, name) }
            dict["properties"] = kept
        }
        if let items = dict["items"] { dict["items"] = terse(items) }
        return dict
    }

    /// The short list the agent is handed.
    static let catalogue: [[String: Any]] = {
        var short: [[String: Any]] = full.map { tool in
            var out = tool
            let name = tool["name"] as? String ?? ""
            out["description"] = lines[name] ?? String((tool["description"] as? String ?? "").split(separator: ".").first ?? "")
            if let schema = tool["inputSchema"] { out["inputSchema"] = terse(schema) }
            return out
        }
        short.append([
            "name": "help", "description": lines["help"] ?? "",
            "inputSchema": ["type": "object", "properties": ["tool": ["type": "string"]], "required": []] as [String: Any],
            "annotations": ["readOnlyHint": true, "openWorldHint": false] as [String: Any],
        ])
        return short
    }()

    /// The whole description of one tool, or the list of them.
    static func help(_ arguments: [String: Any]) -> Reply {
        let wanted = (arguments["tool"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty else {
            let names = full.compactMap { $0["name"] as? String } + ["help"]
            return .text(names.map { "\($0): \(lines[$0] ?? "")" }.joined(separator: "\n") + "\n\n`tab` (any tool that takes one): the number from `tabs`; left out, the tab shown in the front window. `help` with `tool` gives one's whole description.")
        }
        guard let tool = full.first(where: { ($0["name"] as? String) == wanted }) else {
            return .failure("No tool is called \(wanted). `help` lists them.")
        }
        var out = wanted + ": " + (tool["description"] as? String ?? "")
        let schema = tool["inputSchema"] as? [String: Any] ?? [:]
        let properties = schema["properties"] as? [String: Any] ?? [:]
        let required = Set(schema["required"] as? [String] ?? [])
        if !properties.isEmpty { out += "\n\nParameters:" }
        for name in properties.keys.sorted() {
            guard let property = properties[name] as? [String: Any] else { continue }
            var kind = property["type"] as? String ?? "any"
            if let items = property["items"] as? [String: Any], let inner = items["type"] as? String { kind += " of " + inner }
            if let choices = property["enum"] as? [String] { kind += ": " + choices.joined(separator: " | ") }
            out += "\n  \(name) (\(kind)\(required.contains(name) ? ", required" : "")): \(property["description"] as? String ?? "")"
            if let items = property["items"] as? [String: Any], let inner = items["properties"] as? [String: Any] {
                for key in inner.keys.sorted() {
                    out += "\n    \(key): \((inner[key] as? [String: Any])?["description"] as? String ?? "")"
                }
            }
        }
        return .text(out)
    }
}
#endif
