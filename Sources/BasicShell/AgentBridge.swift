#if AGENT
import Foundation

// BasicShell started with `--mcp`: not the browser, but the program the agent
// talks to (see Agent.swift). It speaks the Model Context Protocol on its
// standard input and output, a line of JSON for each message, says which
// tools there are, and passes each call to the running browser over its
// socket, one at a time, waiting for the answer.
enum AgentBridge {
    private static var client = "An agent"

    /// Never returns.
    static func run() -> Never {
        signal(SIGPIPE, SIG_IGN)
        // Read here, on the main thread: the calls themselves run on others.
        let socketPath = AgentAccess.socket
        let appPath = Bundle.main.bundleURL.path
        while let line = readLine(strippingNewline: true) {
            guard let data = line.data(using: .utf8),
                  let message = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let method = message["method"] as? String
            else { continue }
            // Without an id it is a notice, and wants no answer.
            guard let id = message["id"] else { continue }
            let parameters = message["params"] as? [String: Any] ?? [:]
            switch method {
            case "initialize":
                if let name = (parameters["clientInfo"] as? [String: Any])?["name"] as? String { client = pretty(name) }
                let asked = parameters["protocolVersion"] as? String ?? ""
                let known = ["2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25"]
                answer(id, [
                    "protocolVersion": known.contains(asked) ? asked : "2025-06-18",
                    "capabilities": ["tools": [String: Any]()],
                    "serverInfo": ["name": "basicshell", "title": "BasicShell",
                                   "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"],
                    "instructions": AgentTools.instructions,
                ])
            case "ping":
                answer(id, [:])
            case "tools/list":
                answer(id, ["tools": AgentTools.catalogue])
            case "tools/call":
                let name = parameters["name"] as? String ?? ""
                let arguments = parameters["arguments"] as? [String: Any] ?? [:]
                let enabled = AgentAccess.enabled, who = client
                // Not waited for here: the next line may be another call, to run beside it.
                AgentLink.start(id: id, tool: name, arguments: arguments, enabled: enabled, client: who, socketPath: socketPath, appPath: appPath)
            default:
                AgentLink.emit(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "BasicShell has no \(method)"]])
            }
        }
        exit(0)
    }

    private static func pretty(_ name: String) -> String {
        switch name.lowercased() {
        case "claude-code": return "Claude Code"
        case "claude-ai", "claude-desktop", "claude": return "Claude"
        case "agy", "antigravity", "antigravity-cli": return "Antigravity"
        case "gemini-cli": return "Gemini CLI"
        default:
            // The Claude app's agent mode names itself after the server.
            return name.lowercased().hasPrefix("local-agent-mode") ? "Claude app" : name
        }
    }

    private static func answer(_ id: Any, _ result: [String: Any]) {
        AgentLink.emit(["jsonrpc": "2.0", "id": id, "result": result])
    }
}

// MARK: - to the browser

/// The calls, several at a time when the agent sends them so (more tool calls in one turn): each
/// is written to the socket as it comes and answered by its id, by one thread that reads the
/// socket; none of it touches the main thread.
nonisolated enum AgentLink {
    private nonisolated(unsafe) static var lock = NSLock()
    private nonisolated(unsafe) static var connecting = NSLock()
    private nonisolated(unsafe) static var writing = NSLock()
    private nonisolated(unsafe) static var printing = NSLock()
    private nonisolated(unsafe) static var gate = DispatchSemaphore(value: 16)
    private nonisolated(unsafe) static var socket: Int32 = -1
    private nonisolated(unsafe) static var next = 1
    private nonisolated(unsafe) static var open: Set<Int32> = []

    private final class Waiter: @unchecked Sendable {
        let semaphore = DispatchSemaphore(value: 0)
        let fd: Int32
        var reply: [String: Any]?
        init(fd: Int32) { self.fd = fd }
    }
    private nonisolated(unsafe) static var waiting: [Int: Waiter] = [:]

    private struct Carried: @unchecked Sendable { let id: Any; let arguments: [String: Any] }

    /// Sends one line to the agent.
    static func emit(_ message: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: message, options: [.withoutEscapingSlashes]) else { return }
        data.append(0x0A)
        printing.lock()
        FileHandle.standardOutput.write(data)
        printing.unlock()
    }

    /// A call, run on a thread of its own (sixteen at most at once), answered when done.
    static func start(id: Any, tool: String, arguments: [String: Any], enabled: Bool, client: String, socketPath: String, appPath: String) {
        let carried = Carried(id: id, arguments: arguments)
        gate.wait()
        DispatchQueue.global().async {
            let reply = call(tool, carried.arguments, enabled: enabled, client: client, socketPath: socketPath, appPath: appPath)
            emit(["jsonrpc": "2.0", "id": carried.id, "result": ["content": reply.parts, "isError": reply.failed]])
            gate.signal()
        }
    }

    private static func failure(_ text: String) -> (parts: [[String: Any]], failed: Bool) {
        ([["type": "text", "text": text]], true)
    }

    private static func call(_ tool: String, _ arguments: [String: Any], enabled: Bool, client: String, socketPath: String, appPath: String) -> (parts: [[String: Any]], failed: Bool) {
        guard enabled else {
            return failure("The agent isn't let into BasicShell: the person turns that on in BasicShell's Settings › Agents. Tell them; don't try another way.")
        }
        // Once more if the browser went away in between (quit and reopened).
        for attempt in 0..<2 {
            guard connect(launching: attempt == 0, socketPath: socketPath, appPath: appPath) else { break }
            lock.lock()
            let id = next
            next += 1
            let fd = socket
            let waiter = Waiter(fd: fd)
            waiting[id] = waiter
            lock.unlock()
            let request: [String: Any] = ["id": id, "tool": tool, "args": arguments, "client": client]
            guard let data = try? JSONSerialization.data(withJSONObject: request) else {
                lock.lock(); waiting[id] = nil; lock.unlock()
                return failure("That call couldn't be written down.")
            }
            writing.lock()
            let sent = AgentWire.write(data, to: fd)
            writing.unlock()
            if sent {
                waiter.semaphore.wait()
                if let reply = waiter.reply {
                    return (reply["content"] as? [[String: Any]] ?? [], reply["error"] as? Bool ?? false)
                }
            } else {
                lock.lock(); waiting[id] = nil; lock.unlock()
            }
            drop(fd)
        }
        return failure("BasicShell isn't answering. It may not be open, or the agent may have just been turned off in its Settings › Agents.")
    }

    /// The socket given up, and every call waiting on it let go to try again.
    private static func drop(_ fd: Int32) {
        lock.lock()
        // Closed once only, by whichever of the threads gets here first: a number closed
        // twice may by then be another socket's.
        let mine = open.remove(fd) != nil
        if socket == fd { socket = -1 }
        let stuck = waiting.filter { $0.value.fd == fd }
        for (id, waiter) in stuck { waiting[id] = nil; waiter.semaphore.signal() }
        lock.unlock()
        if mine { Darwin.close(fd) }
    }

    /// Connected to the running browser, opening it (behind everything)
    /// when it isn't running. One thread at a time does it.
    private static func connect(launching: Bool, socketPath: String, appPath: String) -> Bool {
        connecting.lock()
        defer { connecting.unlock() }
        lock.lock()
        let there = socket >= 0
        lock.unlock()
        if there { return true }
        if reach(socketPath) { return true }
        guard launching else { return false }
        let launcher = Process()
        launcher.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        launcher.arguments = ["-g", appPath]
        guard (try? launcher.run()) != nil else { return false }
        for _ in 0..<40 {
            usleep(500_000)
            if reach(socketPath) { return true }
        }
        return false
    }

    private static func reach(_ path: String) -> Bool {
        guard var address = AgentWire.address(path) else { return false }
        let fd = AgentWire.socket()
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else {
            Darwin.close(fd)
            return false
        }
        lock.lock()
        socket = fd
        open.insert(fd)
        lock.unlock()
        // The answers come back on this thread, each to the call that has its id.
        Thread.detachNewThread {
            var pending = Data()
            while let line = AgentWire.line(from: fd, pending: &pending) {
                guard let reply = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any], let id = reply["id"] as? Int else { continue }
                lock.lock()
                let waiter = waiting.removeValue(forKey: id)
                lock.unlock()
                waiter?.reply = reply
                waiter?.semaphore.signal()
            }
            drop(fd)
        }
        return true
    }
}
#endif
