#if AGENT
import AppKit
import Observation
import WebKit

// The agent, in this browser.
//
// Anthropic's own extension, Claude in Chrome, drives pages through Chrome's
// debugger, which WebKit's extensions don't have. So BasicShell offers the
// same things itself, as tools Claude Code and the Claude app can call (the
// Model Context Protocol): the tabs, a page's text and what is on it, a
// picture of it, clicks and typing, and a few things an extension can't
// have, such as the history and a page's own dialogs.
//
// How it reaches the browser: the agent starts BasicShell's own program with
// `--mcp` (AgentBridge), which speaks the protocol on its standard input
// and output and passes each call, a line of JSON, over a socket in
// BasicShell's folder to the running app (AgentListener, here), where it is
// carried out (AgentTools).
//
// All of it is in the build only when that is asked for (`./build.sh
// agent`, which defines AGENT): without it BasicShell has none of this.
//
// What keeps it yours (AgentAccess):
// - Off unless turned on in Settings › Agents.
// - A private tab is never listed, read or touched.
// - Each site is asked about, once to read it and once to click and type
//   there; an answer can be kept, and is then in Settings.
// - What is in a password or card field is never given, and nothing is
//   typed into one.
// - A tab the agent works in is marked in the sidebar, and framed while it is
//   the one shown, with a button that stops everything.
// - The socket is the user's alone (its mode, and the caller's user id).
//
// Settings › Agents can turn the asking off ("Bypass permissions"), for work
// you are watching: every site is then open to it and files go unasked,
// except the sites you said no to; the rest above stays as it is.

/// What the agent may do beyond reading and clicking on the sites it is let
/// into: each its own switch in Settings › Agents, each off until turned on,
/// and all of them on while "Bypass permissions" is.
enum AgentPower: String, CaseIterable, Identifiable {
    case tabs, history, clipboard, extensions, developer, bodies, storage, features

    var id: String { rawValue }

    /// The UserDefaults key (the first two are older than this list).
    var key: String {
        switch self {
        case .history: AgentAccess.historyKey
        case .developer: AgentAccess.developerKey
        default: "agent.\(rawValue)"
        }
    }

    /// The power it is part of: it is on only while that one is.
    var parent: AgentPower? { self == .bodies || self == .storage || self == .features ? .developer : nil }

    var isOn: Bool { AgentAccess.bypass || (UserDefaults.standard.bool(forKey: key) && (parent?.isOn ?? true)) }

    var title: String {
        switch self {
        case .tabs: "Arrange my tabs"
        case .history: "History, bookmarks and downloads"
        case .clipboard: "The clipboard"
        case .extensions: "Extensions"
        case .developer: "Developer tools"
        case .bodies: "Request and response bodies"
        case .storage: "Cookies and site storage"
        case .features: "WebKit features"
        }
    }

    var detail: String {
        switch self {
        case .tabs: "Pin and unpin tabs, make a copy of one, put one to sleep, move one to another place or a new window. Nothing on a page is read for this."
        case .history: "Search the pages you have visited and your bookmarks, and see what was downloaded this session. To find a page you were on, or a file you saved."
        case .clipboard: "Read what you last copied, and put text on it. What you copied may be a password from a password manager, so it is off until you say."
        case .extensions: "List the extensions installed in BasicShell, see the problems WebKit reports for them (and, with Developer tools on, what their background pages write to the console), and reload one that has got stuck. It can't add, remove or change them."
        case .developer: "A page's console and network requests, scripts of the agent's own in a page, a look at an element's styles, load timings, blocking some requests, a tab with JavaScript, images or styles switched off, and a page's source as the site sent it. A script reaches everything on the page, password fields too. Pages opened from now on are watched."
        case .bodies: "With the network requests, what was sent and what came back, for the page's own fetch and XHR calls. Passwords, tokens, keys and cookies in them are replaced by [hidden]. Pages opened from now on."
        case .storage: "List a site's cookies, local and session storage and databases, and clear them (you are asked first). A cookie's value is shown only when the agent asks for values, never an HttpOnly one's, and tokens and passwords stay hidden."
        case .features: "List WebKit's experimental and debugging features and switch them, to try a page with one on or off. A change lasts only while the agent is connected, and what touches privacy or security (tracking prevention, cookies, sandboxing, camera and microphone) stays yours, in the Develop and Debug menus."
        }
    }

    var tools: [String] {
        switch self {
        case .tabs: ["arrange"]
        case .history: ["history", "bookmarks", "downloads"]
        case .clipboard: ["clipboard"]
        case .extensions: ["extensions"]
        case .developer: ["console", "network", "evaluate", "inspect", "performance", "block", "render", "source"]
        case .bodies: ["network"]
        case .storage: ["storage"]
        case .features: ["features"]
        }
    }
}

/// What the person may say about a site, as Settings shows it.
enum AgentSitePolicy: String, CaseIterable, Identifiable {
    case ask, readAsk, readOnly, readAct, never

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ask: "Ask each time"
        case .readAsk: "Read; ask before clicking"
        case .readOnly: "Read only"
        case .readAct: "Read, click and type"
        case .never: "Never"
        }
    }
}

/// One thing the agent did, for the list in Settings.
struct AgentActivity: Identifiable {
    let id = UUID()
    let date: Date
    let client: String
    let tool: String
    let site: String?
    let failed: Bool
    /// How long the call took, in milliseconds.
    var took = 0
    /// What the agent said the call was for, when it said (the `summary` argument).
    var summary: String?
}

/// Who may, and what is going on.
@Observable
final class AgentAccess {
    static let shared = AgentAccess()

    static let enabledKey = "agent.enabled"
    static let historyKey = "agent.history"
    static let developerKey = "agent.developer"
    static let bypassKey = "agent.bypass"

    static var enabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }
    /// The history, the bookmarks and the downloads may be searched.
    static var history: Bool { AgentPower.history.isOn }
    /// The console, the network and scripts of the agent's own in a page.
    static var developer: Bool { AgentPower.developer.isOn }
    /// What the network log keeps of a request: bodies too.
    static var bodies: Bool { AgentPower.bodies.isOn }
    /// Nothing is asked: every site but those refused for good is open.
    static var bypass: Bool { UserDefaults.standard.bool(forKey: bypassKey) }

    /// The line around a tab an agent works in: the system's own accent, so
    /// it looks like the Mac, not like any agent.
    static var color: NSColor { .controlAccentColor }

    /// What an earlier version kept under "claude." is kept under "agent.":
    /// copied once, the old left where it is.
    static func migrateSettings() {
        let defaults = UserDefaults.standard
        for (key, value) in defaults.dictionaryRepresentation() where key.hasPrefix("claude.") {
            let renamed = "agent." + key.dropFirst("claude.".count)
            if defaults.object(forKey: renamed) == nil { defaults.set(value, forKey: renamed) }
        }
        if defaults.string(forKey: "settings.tab") == "claude" { defaults.set("agent", forKey: "settings.tab") }
        // The socket an earlier version listened on.
        unlink(Store.folder.appendingPathComponent("claude.sock").path)
    }

    /// The socket, in BasicShell's own folder, so a test copy has its own.
    static var socket: String { Store.folder.appendingPathComponent("agent.sock").path }

    enum Kind: String { case read, act }

    /// Site to what was answered for good: "read" and "act", each allowed or not.
    private(set) var sites: [String: [String: Bool]] = UserDefaults.standard.dictionary(forKey: "agent.sites") as? [String: [String: Bool]] ?? [:]
    /// Answers given without "Remember", until the agent goes or is stopped.
    @ObservationIgnored private var once: [String: [String: Bool]] = [:]
    /// The tabs the agent works in.
    private(set) var held: Set<UUID> = []
    /// What the person is shown of the agent in a tab: at work, or (for a moment, once it has been
    /// quiet) finished. Not the same as being held: a tab is held, so that it isn't put to sleep
    /// under the agent, for longer than it is shown.
    enum Presence { case working, finished }
    private(set) var presence: [UUID: Presence] = [:]
    /// Calls on a tab that have begun and not ended: it is not finished while one is.
    @ObservationIgnored private var calls: [UUID: Int] = [:]
    /// The tab's three moments to come, each one timer set when the last call ended (and none polling):
    /// shown finished, no longer shown, let go.
    @ObservationIgnored private var due: [UUID: [DispatchWorkItem]] = [:]
    /// Quiet for this long after a call, the agent looks to be done (a model thinks for seconds between calls).
    static let quietFor: TimeInterval = 10
    /// How long "finished" stays up.
    static let finishedShown: TimeInterval = 3
    /// A tab no call has touched for this long is let go (it may then sleep as any other).
    static let letGoAfter: TimeInterval = 120
    /// Who is connected, by the name each gave.
    private(set) var clients: [String] = []
    /// Stopped from the page's frame: nothing more until the person says so.
    private(set) var stopped = false
    @ObservationIgnored private var askedToResume = Date.distantPast
    @ObservationIgnored private var asking: [String: Task<Bool, Never>] = [:]
    @ObservationIgnored private var listener: AgentListener?

    /// What every `file:` address is, to the asking: one site, so that the
    /// person says once whether the agent may open files on this Mac.
    static let filesSite = "files on this Mac"

    static func site(_ url: URL?) -> String? {
        if let url, url.isFileURL { return filesSite }
        guard let url, ["http", "https"].contains(url.scheme?.lowercased() ?? ""), let host = url.host()?.lowercased(), !host.isEmpty else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    // MARK: - on and off

    /// At launch, and when the switch in Settings changes.
    func start() {
        guard AgentAccess.enabled else { return stop(listening: true) }
        guard listener == nil else { return }
        try? FileManager.default.createDirectory(at: Store.folder, withIntermediateDirectories: true)
        listener = AgentListener(path: AgentAccess.socket) { data, connection in
            DispatchQueue.main.async { MainActor.assumeIsolated { AgentAccess.shared.received(data, from: connection) } }
        } closed: { connection in
            DispatchQueue.main.async { MainActor.assumeIsolated { AgentAccess.shared.gone(connection) } }
        }
        if listener == nil { Debug.log("agent", "couldn't listen at \(AgentAccess.socket)") }
    }

    private func stop(listening: Bool, announce: Bool = false) {
        // WebKit's features the agent switched go back, whenever it is let go.
        Features.clearTransient()
        if listening {
            listener?.close()
            listener = nil
            connections = [:]
            clients = []
        }
        once = [:]
        for id in held { release(id, announce: announce) }
    }

    /// The button on the page's frame: everything let go, and nothing more
    /// done until the person lets it carry on.
    func stopNow() {
        stopped = true
        askedToResume = Date()
        stop(listening: false)
        Windows.front?.say("Agent stopped")
        Debug.log("agent", "stopped by the person")
    }

    func resume() { stopped = false }

    // MARK: - connections

    @ObservationIgnored private var connections: [ObjectIdentifier: String] = [:]

    private func received(_ data: Data, from connection: AgentConnection) {
        guard let message = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        let key = ObjectIdentifier(connection)
        let client = message["client"] as? String ?? "An agent"
        if connections[key] != client {
            connections[key] = client
            clients = connections.values.sorted()
            Debug.log("agent", "\(client) connected")
        }
        guard let id = message["id"], let tool = message["tool"] as? String else { return }
        let arguments = message["args"] as? [String: Any] ?? [:]
        Task {
            // Turned off while it was connected: nothing more.
            let reply = AgentAccess.enabled ? await AgentTools.run(tool, arguments, for: client)
                : .failure("The agent was turned off in BasicShell's Settings › Agents. Tell the person; don't try another way.")
            // Written down and sent on another thread: a picture is hundreds of kilobytes of text,
            // and the main thread is the person's.
            let answer = AgentAnswer(value: ["id": id, "content": reply.parts, "error": reply.failed])
            DispatchQueue.global(qos: .utility).async {
                if let data = try? JSONSerialization.data(withJSONObject: answer.value) { connection.send(data) }
            }
        }
    }

    private func gone(_ connection: AgentConnection) {
        guard let client = connections.removeValue(forKey: ObjectIdentifier(connection)) else { return }
        clients = connections.values.sorted()
        Debug.log("agent", "\(client) disconnected")
        if connections.isEmpty { stop(listening: false, announce: true) }
    }

    // MARK: - the tabs it works in

    func holds(_ tab: Tab) -> Bool { held.contains(tab.id) }

    /// A tab opened for one job and closed after it: no longer held.
    func forget(_ tab: Tab) {
        held.remove(tab.id)
        cancelDue(tab.id)
        calls[tab.id] = nil
        showing(nil, tab.id)
    }

    /// The tab's page kept going, in its window, for the agent to work in; and shown so.
    func hold(_ tab: Tab) {
        tab.lastSeen = Date()
        (tab.host as? BrowserWindow)?.keepRunning(tab)
        let first = held.insert(tab.id).inserted
        showing(.working, tab.id)
        if first { Windows.all.forEach { $0.agentChanged() } }
        // Between calls the clock runs; while one is on it doesn't.
        if (calls[tab.id] ?? 0) == 0 { setClock(tab.id) }
    }

    /// A call on the tab begins: it is not finished meanwhile.
    func began(_ tab: Tab) {
        calls[tab.id, default: 0] += 1
        cancelDue(tab.id)
    }

    /// The call is over: from now on the tab is quiet, and goes from working to finished to let go.
    func ended(_ tab: Tab) {
        calls[tab.id] = max(0, (calls[tab.id] ?? 1) - 1)
        if held.contains(tab.id), (calls[tab.id] ?? 0) == 0 { setClock(tab.id) }
    }

    private func showing(_ state: Presence?, _ id: UUID) {
        guard presence[id] != state else { return }
        presence[id] = state
        Windows.all.forEach { $0.agentChanged() }
    }

    private func cancelDue(_ id: UUID) {
        due.removeValue(forKey: id)?.forEach { $0.cancel() }
    }

    private func setClock(_ id: UUID) {
        cancelDue(id)
        func later(_ seconds: TimeInterval, _ work: @escaping @MainActor () -> Void) -> DispatchWorkItem {
            let item = DispatchWorkItem { MainActor.assumeIsolated { work() } }
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
            return item
        }
        due[id] = [
            later(AgentAccess.quietFor) { [weak self] in self?.showing(.finished, id) },
            later(AgentAccess.quietFor + AgentAccess.finishedShown) { [weak self] in self?.showing(nil, id) },
            later(AgentAccess.letGoAfter) { [weak self] in self?.release(id) },
        ]
    }

    /// `announce`: the agent has gone of itself (its program ended): "finished" is shown for a moment
    /// first. Stopped by the person, or switched off, it is gone at once.
    private func release(_ id: UUID, announce: Bool = false) {
        held.remove(id)
        cancelDue(id)
        calls[id] = nil
        if announce, presence[id] == .working {
            showing(.finished, id)
            let item = DispatchWorkItem { MainActor.assumeIsolated { [weak self] in self?.showing(nil, id) } }
            due[id] = [item]
            DispatchQueue.main.asyncAfter(deadline: .now() + AgentAccess.finishedShown, execute: item)
        } else {
            presence[id] = nil
        }
        for window in Windows.all {
            if let tab = window.shell.tabs.first(where: { $0.id == id }) {
                AgentRecorder.stop(tab)
                // Whatever it switched off to look at the page is back on.
                if tab.agentRendered { tab.agentRendered = false; Develop.restoreRendering(tab) }
                window.letRest(tab)
            }
            window.agentChanged()
        }
    }


    // MARK: - asking

    struct Refusal: Error { let message: String }

    /// Whether the agent may, in this tab as it is now: throws what to tell it
    /// when it may not.
    func permit(_ kind: Kind, in tab: Tab, for client: String) async throws {
        guard !tab.isPrivate else { throw Refusal(message: "That is a private tab, which BasicShell keeps from the agent.") }
        guard let site = AgentAccess.site(tab.url) else {
            throw Refusal(message: "BasicShell lets the agent into web pages (http and https) and files on this Mac (file) only; this tab shows \(tab.url?.scheme ?? "nothing").")
        }
        try await permit(kind, site: site, for: client, over: (tab.host as? BrowserWindow)?.window)
    }

    func permit(_ kind: Kind, site: String, for client: String, over window: NSWindow?) async throws {
        try await carryOn(over: window)
        switch answer(kind, site) {
        case true?: return
        case false?: throw Refusal(message: denied(kind, site))
        case nil: if AgentAccess.bypass { return }
        }
        let key = "\(kind.rawValue) \(site)"
        let task = asking[key] ?? Task { await self.ask(kind, site: site, for: client, over: window) }
        asking[key] = task
        let allowed = await task.value
        asking[key] = nil
        if !allowed { throw Refusal(message: denied(kind, site)) }
    }

    private func denied(_ kind: Kind, _ site: String) -> String {
        "The person hasn't allowed the agent to \(kind == .read ? "read" : "click and type on") \(site) in BasicShell. Don't try another way in; tell them, and carry on only if they change it (Settings › Agents)."
    }

    /// What is already known: allowed to act is allowed to read, and not
    /// allowed to read is not allowed to act.
    private func answer(_ kind: Kind, _ site: String) -> Bool? {
        let known = { (kind: Kind) in self.once[site]?[kind.rawValue] ?? self.sites[site]?[kind.rawValue] }
        switch kind {
        case .read: return known(.act) == true ? true : known(.read)
        case .act: return known(.read) == false ? false : known(.act)
        }
    }

    private func ask(_ kind: Kind, site: String, for client: String, over window: NSWindow?) async -> Bool {
        let alert = NSAlert()
        switch kind {
        case .read where site == AgentAccess.filesSite:
            alert.messageText = "Let an agent open files on this Mac?"
            alert.informativeText = "\(client) is asking. It would open any file on this Mac that it names (a page, a text file, a PDF, a picture) in a tab and see it as you do. Whatever it opens is shown to the agent."
        case .act where site == AgentAccess.filesSite:
            alert.messageText = "Let an agent click and type in files on this Mac?"
            alert.informativeText = "\(client) is asking. It would click, type and fill in forms in pages that are files on this Mac, and read them."
        case .read:
            alert.messageText = "Let an agent read \(site)?"
            alert.informativeText = "\(client) is asking. It would see this site's pages as you do, signed in as you: their text, what is on them and how they look."
        case .act:
            alert.messageText = "Let an agent click and type on \(site)?"
            alert.informativeText = "\(client) is asking. It would click, type, scroll and fill in forms there as you, and read the pages. It can't see or fill password and card fields."
        }
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Don't Allow")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Remember for this site"
        // Ticked unless you untick it: an answer not kept was asked again
        // at every new chat.
        alert.suppressionButton?.state = .on
        Debug.log("agent", "\(site): asking you whether \(client) may \(kind.rawValue)")
        let response = await AgentAccess.show(alert, over: window)
        // Not answered in time: not allowed now, asked again next time.
        guard let response else { return false }
        let allowed = response == .alertFirstButtonReturn
        Debug.log("agent", "\(site): you said \(allowed ? "allow" : "don't allow") (\(kind.rawValue))")
        if alert.suppressionButton?.state == .on {
            set(site, kind, allowed)
        } else {
            once[site, default: [:]][kind.rawValue] = allowed
        }
        return allowed
    }

    /// Stopped: asked once whether it may carry on, then not again for a minute.
    func carryOn(over window: NSWindow?) async throws {
        guard stopped else { return }
        let refusal = Refusal(message: "The person stopped the agent in BasicShell. Don't retry; tell them, and wait until they ask you to go on.")
        guard Date().timeIntervalSince(askedToResume) > 5 else { throw refusal }
        askedToResume = Date().addingTimeInterval(55)
        let alert = NSAlert()
        alert.messageText = "Let an agent carry on?"
        alert.informativeText = "You stopped it; it is asking to use this browser again."
        alert.addButton(withTitle: "Carry On")
        alert.addButton(withTitle: "Keep It Stopped")
        guard await AgentAccess.show(alert, over: window) == .alertFirstButtonReturn else { throw refusal }
        stopped = false
    }

    /// A question as a sheet on the window, the Dock icon bouncing if
    /// BasicShell isn't in front; nil when a minute and a half passes
    /// unanswered.
    static func show(_ alert: NSAlert, over window: NSWindow?) async -> NSApplication.ModalResponse? {
        guard let window = window ?? Windows.front?.window else { return nil }
        if !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
        return await withCheckedContinuation { continuation in
            var answered = false
            alert.beginSheetModal(for: window) { response in
                guard !answered else { return }
                answered = true
                continuation.resume(returning: response == .abort ? nil : response)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 90) {
                guard !answered else { return }
                window.endSheet(alert.window, returnCode: .abort)
            }
        }
    }

    // MARK: - what was answered for good (Settings › Agents)

    func set(_ site: String, _ kind: Kind, _ allowed: Bool?) {
        var answers = sites[site] ?? [:]
        answers[kind.rawValue] = allowed
        sites[site] = answers.isEmpty ? nil : answers
        once[site]?[kind.rawValue] = nil
        UserDefaults.standard.set(sites, forKey: "agent.sites")
    }

    func forget(_ site: String) {
        sites[site] = nil
        once[site] = nil
        UserDefaults.standard.set(sites, forKey: "agent.sites")
    }

    func policy(for site: String) -> AgentSitePolicy {
        let answers = sites[site] ?? [:]
        if answers["read"] == false { return .never }
        if answers["act"] == true { return .readAct }
        if answers["act"] == false { return .readOnly }
        return answers["read"] == true ? .readAsk : .ask
    }

    func setPolicy(_ policy: AgentSitePolicy, for site: String) {
        once[site] = nil
        switch policy {
        case .ask: sites[site] = nil
        case .readAsk: sites[site] = ["read": true]
        case .readOnly: sites[site] = ["read": true, "act": false]
        case .readAct: sites[site] = ["read": true, "act": true]
        case .never: sites[site] = ["read": false]
        }
        UserDefaults.standard.set(sites, forKey: "agent.sites")
    }

    // MARK: - what it did

    /// The last of what the agent did, newest first, for Settings. Kept in
    /// memory only, and gone when BasicShell quits.
    private(set) var activity: [AgentActivity] = []

    func note(_ tool: String, site: String?, client: String, failed: Bool, took: Int = 0, summary: String? = nil) {
        activity.insert(AgentActivity(date: Date(), client: client, tool: tool, site: site, failed: failed, took: took, summary: (summary?.isEmpty ?? true) ? nil : String(summary!.prefix(120))), at: 0)
        if activity.count > 100 { activity.removeLast(activity.count - 100) }
    }

    func clearActivity() { activity = [] }

    // MARK: - the powers

    /// Throws what to tell the agent when the person hasn't turned this on.
    static func need(_ power: AgentPower) throws {
        if let parent = power.parent, !parent.isOn {
            throw Refusal(message: "\(parent.title) are off: the person turns them on in BasicShell's Settings › Agents. Tell them; don't try another way.")
        }
        guard power.isOn else {
            throw Refusal(message: "\(power.title) is kept from the agent: the person turns it on in BasicShell's Settings › Agents. Tell them; don't try another way.")
        }
    }
}

// MARK: - WebKit's features, as the agent switches them

extension Features {
    /// Switched for as long as the agent is let in; what each was before is
    /// kept to put back.
    private static var before: [String: Bool] = [:]

    static func setTransient(_ on: Bool, _ feature: NSObject) {
        let name = key(of: feature)
        if before[name] == nil { before[name] = isOn(feature) }
        transient[name] = on
        forEachPage { write(on, feature, in: $0) }
    }

    /// Everything the agent switched, as it was.
    static func clearTransient() {
        guard !transient.isEmpty else { return }
        let was = before
        let kept = saved
        transient = [:]
        before = [:]
        forEachPage { preferences in
            for (name, value) in was {
                if let feature = feature(name) { write(kept[name] ?? value, feature, in: preferences) }
            }
        }
    }
}

// MARK: - the socket

/// Lines of JSON between the program the agent starts and the running app.
nonisolated enum AgentWire {
    static func address(_ path: String) -> sockaddr_un? {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let room = MemoryLayout.size(ofValue: address.sun_path)
        guard bytes.count < room else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            for (index, byte) in bytes.enumerated() { buffer[index] = byte }
        }
        return address
    }

    /// A socket that doesn't end the program when the other end has gone.
    static func socket() -> Int32 {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        widen(fd)
        return fd
    }

    /// A buffer of a megabyte each way, where the default is a few kilobytes: an answer with a
    /// picture in it goes in a few writes and reads, not in hundreds that each wait for the other end.
    static func widen(_ fd: Int32) {
        var size: Int32 = 1 << 20
        setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &size, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &size, socklen_t(MemoryLayout<Int32>.size))
    }

    static func write(_ data: Data, to fd: Int32) -> Bool {
        var line = data
        line.append(0x0A)
        return line.withUnsafeBytes { buffer in
            var sent = 0
            while sent < buffer.count {
                let n = Darwin.write(fd, buffer.baseAddress! + sent, buffer.count - sent)
                if n <= 0 { return false }
                sent += n
            }
            return true
        }
    }

    /// The next line, waiting for it; nil once the other end has gone.
    static func line(from fd: Int32, pending: inout Data) -> Data? {
        while true {
            if let end = pending.firstIndex(of: 0x0A) {
                let line = pending[pending.startIndex..<end]
                pending = Data(pending[(end + 1)...])
                return Data(line)
            }
            var chunk = [UInt8](repeating: 0, count: 65536)
            let n = Darwin.read(fd, &chunk, chunk.count)
            if n <= 0 { return nil }
            pending.append(chunk, count: n)
        }
    }
}

/// An answer on its way to the socket: nobody changes it meanwhile.
nonisolated struct AgentAnswer: @unchecked Sendable { let value: [String: Any] }

nonisolated final class AgentConnection: @unchecked Sendable {
    fileprivate let fd: Int32
    private let lock = NSLock()

    fileprivate init(fd: Int32) { self.fd = fd }

    func send(_ data: Data) {
        lock.lock()
        _ = AgentWire.write(data, to: fd)
        lock.unlock()
    }
}

nonisolated final class AgentListener: @unchecked Sendable {
    private let fd: Int32
    private let path: String

    init?(path: String, received: @escaping @Sendable (Data, AgentConnection) -> Void, closed: @escaping @Sendable (AgentConnection) -> Void) {
        guard var address = AgentWire.address(path) else { return nil }
        unlink(path)
        let fd = AgentWire.socket()
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        // The user's alone.
        guard bound == 0, chmod(path, 0o600) == 0, listen(fd, 8) == 0 else {
            Darwin.close(fd)
            return nil
        }
        self.fd = fd
        self.path = path
        Thread.detachNewThread {
            while true {
                let client = accept(fd, nil, nil)
                guard client >= 0 else { return }
                var user: uid_t = 0, group: gid_t = 0
                guard getpeereid(client, &user, &group) == 0, user == getuid() else {
                    Darwin.close(client)
                    continue
                }
                var on: Int32 = 1
                setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
                AgentWire.widen(client)
                let connection = AgentConnection(fd: client)
                Thread.detachNewThread {
                    var pending = Data()
                    while let line = AgentWire.line(from: client, pending: &pending) { received(line, connection) }
                    closed(connection)
                    Darwin.close(client)
                }
            }
        }
    }

    func close() {
        Darwin.close(fd)
        unlink(path)
    }
}
#endif
