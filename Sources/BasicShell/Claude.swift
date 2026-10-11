#if CLAUDE
import AppKit
import Observation
import WebKit

// Claude, in this browser.
//
// Anthropic's own extension, Claude in Chrome, drives pages through Chrome's
// debugger, which WebKit's extensions don't have. So BasicShell offers the
// same things itself, as tools Claude Code and the Claude app can call (the
// Model Context Protocol): the tabs, a page's text and what is on it, a
// picture of it, clicks and typing, and a few things an extension can't
// have, such as the history and a page's own dialogs.
//
// How it reaches the browser: Claude starts BasicShell's own program with
// `--mcp` (ClaudeBridge), which speaks the protocol on its standard input
// and output and passes each call, a line of JSON, over a socket in
// BasicShell's folder to the running app (ClaudeListener, here), where it is
// carried out (ClaudeTools).
//
// All of it is in the build only when that is asked for (`./build.sh
// claude`, which defines CLAUDE): without it BasicShell has none of this.
//
// What keeps it yours (ClaudeAccess):
// - Off unless turned on in Settings › Claude.
// - A private tab is never listed, read or touched.
// - Each site is asked about, once to read it and once to click and type
//   there; an answer can be kept, and is then in Settings.
// - What is in a password or card field is never given, and nothing is
//   typed into one.
// - A tab Claude works in is marked in the sidebar, and framed while it is
//   the one shown, with a button that stops everything.
// - The socket is the user's alone (its mode, and the caller's user id).
//
// Settings › Claude can turn the asking off ("Bypass permissions"), for work
// you are watching: every site is then open to it and files go unasked,
// except the sites you said no to; the rest above stays as it is.

/// Who may, and what is going on.
@Observable
final class ClaudeAccess {
    static let shared = ClaudeAccess()

    static let enabledKey = "claude.enabled"
    static let historyKey = "claude.history"
    static let developerKey = "claude.developer"
    static let bypassKey = "claude.bypass"

    static var enabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }
    /// The history, the bookmarks and the downloads may be searched.
    static var history: Bool { UserDefaults.standard.bool(forKey: historyKey) }
    /// The console, the network and scripts of Claude's own in a page.
    static var developer: Bool { UserDefaults.standard.bool(forKey: developerKey) }
    /// Nothing is asked: every site but those refused for good is open.
    static var bypass: Bool { UserDefaults.standard.bool(forKey: bypassKey) }

    static let color = NSColor(srgbRed: 0.85, green: 0.47, blue: 0.34, alpha: 1)

    /// The socket, in BasicShell's own folder, so a test copy has its own.
    static var socket: String { Store.folder.appendingPathComponent("claude.sock").path }

    enum Kind: String { case read, act }

    /// Site to what was answered for good: "read" and "act", each allowed or not.
    private(set) var sites: [String: [String: Bool]] = UserDefaults.standard.dictionary(forKey: "claude.sites") as? [String: [String: Bool]] ?? [:]
    /// Answers given without "Remember", until Claude goes or is stopped.
    @ObservationIgnored private var once: [String: [String: Bool]] = [:]
    /// The tabs Claude works in.
    private(set) var held: Set<UUID> = []
    @ObservationIgnored private var lastUsed: [UUID: Date] = [:]
    /// Who is connected, by the name each gave.
    private(set) var clients: [String] = []
    /// Stopped from the page's frame: nothing more until the person says so.
    private(set) var stopped = false
    @ObservationIgnored private var askedToResume = Date.distantPast
    @ObservationIgnored private var asking: [String: Task<Bool, Never>] = [:]
    @ObservationIgnored private var listener: ClaudeListener?
    @ObservationIgnored private var timer: Timer?

    static func site(_ url: URL?) -> String? {
        guard let url, ["http", "https"].contains(url.scheme?.lowercased() ?? ""), let host = url.host()?.lowercased(), !host.isEmpty else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    // MARK: - on and off

    /// At launch, and when the switch in Settings changes.
    func start() {
        guard ClaudeAccess.enabled else { return stop(listening: true) }
        guard listener == nil else { return }
        try? FileManager.default.createDirectory(at: Store.folder, withIntermediateDirectories: true)
        listener = ClaudeListener(path: ClaudeAccess.socket) { data, connection in
            DispatchQueue.main.async { MainActor.assumeIsolated { ClaudeAccess.shared.received(data, from: connection) } }
        } closed: { connection in
            DispatchQueue.main.async { MainActor.assumeIsolated { ClaudeAccess.shared.gone(connection) } }
        }
        if listener == nil { Debug.log("claude", "couldn't listen at \(ClaudeAccess.socket)") }
        // A tab Claude hasn't touched for ten minutes is let go.
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            MainActor.assumeIsolated { ClaudeAccess.shared.releaseIdle() }
        }
    }

    private func stop(listening: Bool) {
        if listening {
            listener?.close()
            listener = nil
            timer?.invalidate()
            timer = nil
            connections = [:]
            clients = []
        }
        once = [:]
        for id in held { release(id) }
    }

    /// The button on the page's frame: everything let go, and nothing more
    /// done until the person lets it carry on.
    func stopNow() {
        stopped = true
        askedToResume = Date()
        stop(listening: false)
        Windows.front?.say("Claude stopped")
        Debug.log("claude", "stopped by the person")
    }

    func resume() { stopped = false }

    // MARK: - connections

    @ObservationIgnored private var connections: [ObjectIdentifier: String] = [:]

    private func received(_ data: Data, from connection: ClaudeConnection) {
        guard let message = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        let key = ObjectIdentifier(connection)
        let client = message["client"] as? String ?? "Claude"
        if connections[key] != client {
            connections[key] = client
            clients = connections.values.sorted()
            Debug.log("claude", "\(client) connected")
        }
        guard let id = message["id"], let tool = message["tool"] as? String else { return }
        let arguments = message["args"] as? [String: Any] ?? [:]
        Task {
            // Turned off while it was connected: nothing more.
            let reply = ClaudeAccess.enabled ? await ClaudeTools.run(tool, arguments, for: client)
                : .failure("Claude was turned off in BasicShell's Settings › Claude. Tell the person; don't try another way.")
            let answer: [String: Any] = ["id": id, "content": reply.parts, "error": reply.failed]
            if let data = try? JSONSerialization.data(withJSONObject: answer) { connection.send(data) }
        }
    }

    private func gone(_ connection: ClaudeConnection) {
        guard let client = connections.removeValue(forKey: ObjectIdentifier(connection)) else { return }
        clients = connections.values.sorted()
        Debug.log("claude", "\(client) disconnected")
        if connections.isEmpty { stop(listening: false) }
    }

    // MARK: - the tabs it works in

    func holds(_ tab: Tab) -> Bool { held.contains(tab.id) }

    /// The tab's page kept going, in its window, for Claude to work in.
    func hold(_ tab: Tab) {
        lastUsed[tab.id] = Date()
        tab.lastSeen = Date()
        (tab.host as? BrowserWindow)?.keepRunning(tab)
        guard !held.contains(tab.id) else { return }
        held.insert(tab.id)
        Windows.all.forEach { $0.claudeChanged() }
    }

    private func release(_ id: UUID) {
        held.remove(id)
        lastUsed[id] = nil
        for window in Windows.all {
            if let tab = window.shell.tabs.first(where: { $0.id == id }) {
                ClaudeRecorder.stop(tab)
                window.letRest(tab)
            }
            window.claudeChanged()
        }
    }

    private func releaseIdle() {
        let now = Date()
        for id in held where now.timeIntervalSince(lastUsed[id] ?? .distantPast) > 600 { release(id) }
    }

    // MARK: - asking

    struct Refusal: Error { let message: String }

    /// Whether Claude may, in this tab as it is now: throws what to tell it
    /// when it may not.
    func permit(_ kind: Kind, in tab: Tab, for client: String) async throws {
        guard !tab.isPrivate else { throw Refusal(message: "That is a private tab, which BasicShell keeps from Claude.") }
        guard let site = ClaudeAccess.site(tab.url) else {
            throw Refusal(message: "BasicShell lets Claude into web pages (http and https) only; this tab shows \(tab.url?.scheme ?? "nothing").")
        }
        try await permit(kind, site: site, for: client, over: (tab.host as? BrowserWindow)?.window)
    }

    func permit(_ kind: Kind, site: String, for client: String, over window: NSWindow?) async throws {
        try await carryOn(over: window)
        switch answer(kind, site) {
        case true?: return
        case false?: throw Refusal(message: denied(kind, site))
        case nil: if ClaudeAccess.bypass { return }
        }
        let key = "\(kind.rawValue) \(site)"
        let task = asking[key] ?? Task { await self.ask(kind, site: site, for: client, over: window) }
        asking[key] = task
        let allowed = await task.value
        asking[key] = nil
        if !allowed { throw Refusal(message: denied(kind, site)) }
    }

    private func denied(_ kind: Kind, _ site: String) -> String {
        "The person hasn't allowed Claude to \(kind == .read ? "read" : "click and type on") \(site) in BasicShell. Don't try another way in; tell them, and carry on only if they change it (Settings › Claude)."
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
        case .read:
            alert.messageText = "Let Claude read \(site)?"
            alert.informativeText = "\(client) is asking. It would see this site's pages as you do, signed in as you: their text, what is on them and how they look."
        case .act:
            alert.messageText = "Let Claude click and type on \(site)?"
            alert.informativeText = "\(client) is asking. It would click, type, scroll and fill in forms there as you, and read the pages. It can't see or fill password and card fields."
        }
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Don't Allow")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Remember for this site"
        Debug.log("claude", "\(site): asking you whether \(client) may \(kind.rawValue)")
        let response = await ClaudeAccess.show(alert, over: window)
        // Not answered in time: not allowed now, asked again next time.
        guard let response else { return false }
        let allowed = response == .alertFirstButtonReturn
        Debug.log("claude", "\(site): you said \(allowed ? "allow" : "don't allow") (\(kind.rawValue))")
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
        let refusal = Refusal(message: "The person stopped Claude in BasicShell. Don't retry; tell them, and wait until they ask you to go on.")
        guard Date().timeIntervalSince(askedToResume) > 5 else { throw refusal }
        askedToResume = Date().addingTimeInterval(55)
        let alert = NSAlert()
        alert.messageText = "Let Claude carry on?"
        alert.informativeText = "You stopped it; it is asking to use this browser again."
        alert.addButton(withTitle: "Carry On")
        alert.addButton(withTitle: "Keep It Stopped")
        guard await ClaudeAccess.show(alert, over: window) == .alertFirstButtonReturn else { throw refusal }
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

    // MARK: - what was answered for good (Settings › Claude)

    func set(_ site: String, _ kind: Kind, _ allowed: Bool?) {
        var answers = sites[site] ?? [:]
        answers[kind.rawValue] = allowed
        sites[site] = answers.isEmpty ? nil : answers
        once[site]?[kind.rawValue] = nil
        UserDefaults.standard.set(sites, forKey: "claude.sites")
    }

    func forget(_ site: String) {
        sites[site] = nil
        once[site] = nil
        UserDefaults.standard.set(sites, forKey: "claude.sites")
    }
}

// MARK: - the socket

/// Lines of JSON between the program Claude starts and the running app.
nonisolated enum ClaudeWire {
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
        return fd
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

nonisolated final class ClaudeConnection: @unchecked Sendable {
    fileprivate let fd: Int32
    private let lock = NSLock()

    fileprivate init(fd: Int32) { self.fd = fd }

    func send(_ data: Data) {
        lock.lock()
        _ = ClaudeWire.write(data, to: fd)
        lock.unlock()
    }
}

nonisolated final class ClaudeListener: @unchecked Sendable {
    private let fd: Int32
    private let path: String

    init?(path: String, received: @escaping @Sendable (Data, ClaudeConnection) -> Void, closed: @escaping @Sendable (ClaudeConnection) -> Void) {
        guard var address = ClaudeWire.address(path) else { return nil }
        unlink(path)
        let fd = ClaudeWire.socket()
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
                let connection = ClaudeConnection(fd: client)
                Thread.detachNewThread {
                    var pending = Data()
                    while let line = ClaudeWire.line(from: client, pending: &pending) { received(line, connection) }
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
