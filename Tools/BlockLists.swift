// Turns Adblock Plus filter lists (EasyList, EasyPrivacy) into WebKit content
// rule lists. Run by build.sh; the app never reads the original lists.
//
//   BlockLists <input.txt> <output.json.lzfse>
//
// The JSON is written LZFSE-compressed: it is about ten times smaller that
// way, and the app only reads it the once WebKit compiles it.
//
// Only what WebKit can express faithfully is converted. A rule that would need
// a regular expression WebKit lacks, a redirect, a CSP header, or an extended
// selector is dropped: a missed ad is better than a broken page.
//
// Rule order matters to WebKit, because "ignore-previous-rules" only cancels
// rules above it:
//   1. generic element hiding
//   2. $generichide / $elemhide exceptions      (cancel 1 on those sites)
//   3. site-specific element hiding
//   4. network blocking
//   5. network exceptions (@@)
//   6. $document exceptions                     (cancel everything on those sites)

import Foundation

typealias Rule = [String: Any]

let arguments = CommandLine.arguments
guard arguments.count == 3, let text = try? String(contentsOfFile: arguments[1], encoding: .utf8) else {
    FileHandle.standardError.write(Data("usage: BlockLists <list.txt> <out.json.lzfse>\n".utf8))
    exit(1)
}

// MARK: - reading the list

var genericSelectors: [String] = []
var genericExceptions: [String: [String]] = [:]    // selector -> sites where it must not apply
var siteSelectors: [String: [String]] = [:]        // "if|a.com,b.com" or "unless|…" -> selectors
var hideExceptions: [Rule] = []
var blocks: [Rule] = []
var exceptions: [Rule] = []
var documentExceptions: [Rule] = []
var dropped = 0

let resourceTypes: [String: [String]] = [
    "script": ["script"], "image": ["image"], "stylesheet": ["style-sheet"],
    "font": ["font"], "media": ["media"], "popup": ["popup"],
    "xmlhttprequest": ["raw"], "websocket": ["raw"], "ping": ["raw"], "other": ["raw"],
    "subdocument": ["document"], "document": ["document"],
]
let allTypes = ["document", "image", "style-sheet", "script", "font", "raw", "svg-document", "media"]
let ignoredOptions: Set<String> = ["important", "match-case"]

/// A host name WebKit accepts in if-domain: lowercase ASCII letters, digits, dots and dashes.
func host(_ name: String) -> String? {
    let lower = name.lowercased()
    guard !lower.isEmpty, lower.allSatisfy({ ($0.isASCII && ($0.isLetter || $0.isNumber)) || $0 == "." || $0 == "-" }),
          !lower.hasPrefix("."), lower.contains(".") || lower == "localhost"
    else { return nil }
    return lower
}

/// "a.com|~b.com" -> ("if", ["*a.com"]) or ("unless", ["*b.com"]); nil when mixed or unreadable.
func domains(_ list: String, separator: Character) -> (kind: String, names: [String])? {
    var yes: [String] = [], no: [String] = []
    for part in list.split(separator: separator) {
        let item = part.trimmingCharacters(in: .whitespaces)
        if item.hasPrefix("~") {
            guard let name = host(String(item.dropFirst())) else { return nil }
            no.append("*" + name)
        } else {
            guard let name = host(item) else { return nil }
            yes.append("*" + name)
        }
    }
    if !yes.isEmpty && !no.isEmpty { return nil }
    if !yes.isEmpty { return ("if-domain", yes) }
    if !no.isEmpty { return ("unless-domain", no) }
    return nil
}

/// An Adblock Plus address pattern as a WebKit url-filter, or nil.
func urlFilter(_ pattern: String) -> String? {
    guard pattern.allSatisfy({ $0.isASCII && !$0.isWhitespace }) else { return nil }
    var rest = Substring(pattern)
    var out = ""
    var afterDomainAnchor = false
    if rest.hasPrefix("||") {
        out = "^[^:]+://+([^:/]+\\.)?"
        rest = rest.dropFirst(2)
        afterDomainAnchor = true
    } else if rest.hasPrefix("|") {
        out = "^"
        rest = rest.dropFirst()
    }
    var endAnchor = false
    if rest.hasSuffix("|") {
        endAnchor = true
        rest = rest.dropLast()
    }
    while rest.hasPrefix("*") { rest = rest.dropFirst() }
    while rest.hasSuffix("*") { rest = rest.dropLast() }
    guard !rest.isEmpty || !out.isEmpty else { return ".*" }

    let special: Set<Character> = [".", "+", "?", "$", "(", ")", "[", "]", "{", "}", "\\", "|"]
    var sawSlash = false
    for ch in rest {
        switch ch {
        case "*": out += ".*"
        case "^":
            // Right after the host the next character is always ":" or "/".
            out += (afterDomainAnchor && !sawSlash) ? "[/:]" : "[^a-zA-Z0-9_.%-]"
        default:
            if ch == "/" { sawSlash = true }
            if special.contains(ch) { out += "\\" }
            out.append(ch)
        }
    }
    if endAnchor { out += "$" }
    return out
}

/// A network rule's trigger, or nil when it can't be expressed.
func trigger(_ body: String) -> (trigger: Rule, document: Bool, hides: Bool)? {
    var pattern = body
    var options: [String] = []
    if let dollar = body.lastIndex(of: "$"), !body.hasPrefix("/") {
        pattern = String(body[..<dollar])
        options = body[body.index(after: dollar)...].split(separator: ",").map(String.init)
    }
    // Regular expressions: WebKit's are a much smaller language.
    if pattern.hasPrefix("/") && pattern.hasSuffix("/") && pattern.count > 1 { return nil }
    guard let filter = urlFilter(pattern) else { return nil }

    var trigger: Rule = ["url-filter": filter]
    var types: [String] = []
    var notTypes: [String] = []
    var document = false
    var hides = false
    for option in options {
        let (name, value) = option.contains("=")
            ? (String(option.prefix { $0 != "=" }), String(option.drop { $0 != "=" }.dropFirst()))
            : (option, "")
        switch name {
        case "third-party", "3p": trigger["load-type"] = ["third-party"]
        case "~third-party", "1p", "first-party": trigger["load-type"] = ["first-party"]
        case "domain":
            guard let (kind, names) = domains(value, separator: "|") else { return nil }
            trigger[kind] = names
        case "generichide", "elemhide", "ghide", "ehide": hides = true
        case "document", "doc":
            document = true
            types.append("document")
        case "match-case": trigger["url-filter-is-case-sensitive"] = true
        case _ where ignoredOptions.contains(name): break
        case _ where name.hasPrefix("~"):
            guard let mapped = resourceTypes[String(name.dropFirst())] else { return nil }
            notTypes += mapped
        default:
            guard let mapped = resourceTypes[name] else { return nil }
            types += mapped
            if name == "subdocument" { trigger["load-context"] = ["child-frame"] }
        }
    }
    if !notTypes.isEmpty {
        guard types.isEmpty else { return nil }
        types = allTypes.filter { !notTypes.contains($0) }
    }
    if !types.isEmpty { trigger["resource-type"] = Array(Set(types)).sorted() }
    return (trigger, document, hides)
}

/// Selectors WebKit's CSS parser takes; extended syntax from other blockers is left out.
func plainSelector(_ selector: String) -> Bool {
    guard !selector.isEmpty, selector.allSatisfy({ $0.isASCII }) else { return false }
    for extended in [":-abp-", ":has-text", ":contains", ":xpath", ":matches-css", ":upward",
                     ":remove", ":style", ":min-text-length", ":watch-attr", ":others", ":if", ":nth-ancestor"] {
        if selector.contains(extended) { return false }
    }
    return !selector.contains("{") && !selector.contains("}")
}

for raw in text.split(whereSeparator: \.isNewline) {
    let line = raw.trimmingCharacters(in: .whitespaces)
    if line.isEmpty || line.hasPrefix("!") || line.hasPrefix("[") { continue }

    // Element hiding.
    if let range = line.range(of: "#@#") ?? line.range(of: "##") {
        let exception = line[range] == "#@#"
        let sites = String(line[..<range.lowerBound])
        let selector = String(line[range.upperBound...])
        guard !line.contains("#?#"), !line.contains("#$#"), plainSelector(selector) else { dropped += 1; continue }
        if exception {
            guard let (kind, names) = domains(sites, separator: ","), kind == "if-domain" else { dropped += 1; continue }
            genericExceptions[selector, default: []] += names
        } else if sites.isEmpty {
            genericSelectors.append(selector)
        } else {
            guard let (kind, names) = domains(sites, separator: ",") else { dropped += 1; continue }
            siteSelectors[kind + "|" + names.sorted().joined(separator: ","), default: []].append(selector)
        }
        continue
    }
    if line.contains("#?#") || line.contains("#$#") || line.contains("#%#") { dropped += 1; continue }

    // Network rules.
    let isException = line.hasPrefix("@@")
    let body = isException ? String(line.dropFirst(2)) : line
    guard let (trig, document, hides) = trigger(body) else { dropped += 1; continue }
    if isException {
        if hides || document {
            // The whole page, or its element hiding: keyed by the site, not the address.
            let pattern = body.split(separator: "$", maxSplits: 1).first.map(String.init) ?? ""
            let site = pattern.trimmingCharacters(in: CharacterSet(charactersIn: "|^*/"))
            guard let name = host(site) else { dropped += 1; continue }
            let rule: Rule = ["trigger": ["url-filter": ".*", "if-domain": ["*" + name]], "action": ["type": "ignore-previous-rules"]]
            if document { documentExceptions.append(rule) } else { hideExceptions.append(rule) }
        } else {
            exceptions.append(["trigger": trig, "action": ["type": "ignore-previous-rules"]])
        }
    } else {
        guard !hides else { dropped += 1; continue }
        blocks.append(["trigger": trig, "action": ["type": "block"]])
    }
}

// MARK: - writing the rules

var rules: [Rule] = []
func hide(_ selectors: [String], _ extra: Rule = [:]) {
    var start = 0
    while start < selectors.count {
        let chunk = selectors[start..<min(start + 500, selectors.count)]
        var trigger: Rule = ["url-filter": ".*"]
        trigger.merge(extra) { $1 }
        rules.append(["trigger": trigger, "action": ["type": "css-display-none", "selector": chunk.joined(separator: ", ")]])
        start += 500
    }
}

// Generic selectors, minus those some site asks to keep; those get a rule
// that skips exactly those sites.
var excepted: [String: [String]] = [:]
for selector in genericSelectors {
    if let sites = genericExceptions[selector] {
        excepted[Array(Set(sites)).sorted().joined(separator: ","), default: []].append(selector)
    }
}
hide(genericSelectors.filter { genericExceptions[$0] == nil })
for (sites, selectors) in excepted.sorted(by: { $0.key < $1.key }) {
    hide(selectors, ["unless-domain": sites.split(separator: ",").map(String.init)])
}
rules += hideExceptions
for (key, selectors) in siteSelectors.sorted(by: { $0.key < $1.key }) {
    let parts = key.split(separator: "|", maxSplits: 1)
    hide(selectors, [String(parts[0]): parts[1].split(separator: ",").map(String.init)])
}
rules += blocks
rules += exceptions
rules += documentExceptions

// WebKit refuses a list of more than 150,000 rules outright.
let limit = 150_000
if rules.count > limit {
    FileHandle.standardError.write(Data("\(rules.count) rules, keeping the first \(limit)\n".utf8))
    rules = Array(rules.prefix(limit))
}

let data = try JSONSerialization.data(withJSONObject: rules, options: [.sortedKeys])
try (data as NSData).compressed(using: .lzfse).write(to: URL(fileURLWithPath: arguments[2]))
print("\(URL(fileURLWithPath: arguments[1]).lastPathComponent): \(rules.count) rules, \(dropped) dropped")
