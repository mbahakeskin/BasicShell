import Foundation

// BasicShell started with `--mcp`: not the browser, but the program Claude
// talks to (see Claude.swift). It speaks the Model Context Protocol on its
// standard input and output, a line of JSON for each message, says which
// tools there are, and passes each call to the running browser over its
// socket, one at a time, waiting for the answer.
enum ClaudeBridge {
    private static var socket: Int32 = -1
    private static var pending = Data()
    private static var client = "Claude"
    private static var next = 1

    /// Never returns.
    static func run() -> Never {
        signal(SIGPIPE, SIG_IGN)
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
                    "instructions": ClaudeTools.instructions,
                ])
            case "ping":
                answer(id, [:])
            case "tools/list":
                answer(id, ["tools": ClaudeTools.catalogue])
            case "tools/call":
                let name = parameters["name"] as? String ?? ""
                let reply = call(name, parameters["arguments"] as? [String: Any] ?? [:])
                answer(id, ["content": reply.parts, "isError": reply.failed])
            default:
                send(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "BasicShell has no \(method)"]])
            }
        }
        exit(0)
    }

    private static func pretty(_ name: String) -> String {
        switch name.lowercased() {
        case "claude-code": return "Claude Code"
        case "claude-ai", "claude-desktop", "claude": return "Claude"
        default: return name
        }
    }

    private static func answer(_ id: Any, _ result: [String: Any]) {
        send(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private static func send(_ message: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: message, options: [.withoutEscapingSlashes]) else { return }
        data.append(0x0A)
        FileHandle.standardOutput.write(data)
    }

    // MARK: - to the browser

    private static func call(_ tool: String, _ arguments: [String: Any]) -> ClaudeTools.Reply {
        guard ClaudeAccess.enabled else {
            return .failure("Claude isn't let into BasicShell: the person turns that on in BasicShell's Settings › Claude. Tell them; don't try another way.")
        }
        let id = next
        next += 1
        let request: [String: Any] = ["id": id, "tool": tool, "args": arguments, "client": client]
        guard let data = try? JSONSerialization.data(withJSONObject: request) else { return .failure("That call couldn't be written down.") }
        // Once more if the browser went away in between (quit and reopened).
        for attempt in 0..<2 {
            guard connect(launching: attempt == 0) else { break }
            if ClaudeWire.write(data, to: socket) {
                while let line = ClaudeWire.line(from: socket, pending: &pending) {
                    guard let reply = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                          (reply["id"] as? Int) == id else { continue }
                    return ClaudeTools.Reply(parts: reply["content"] as? [[String: Any]] ?? [], failed: reply["error"] as? Bool ?? false)
                }
            }
            Darwin.close(socket)
            socket = -1
            pending = Data()
        }
        return .failure("BasicShell isn't answering. It may not be open, or Claude may have just been turned off in its Settings › Claude.")
    }

    /// Connected to the running browser, opening it (behind everything)
    /// when it isn't running.
    private static func connect(launching: Bool) -> Bool {
        if socket >= 0 { return true }
        if reach() { return true }
        guard launching else { return false }
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = ["-g", Bundle.main.bundleURL.path]
        guard (try? open.run()) != nil else { return false }
        for _ in 0..<40 {
            usleep(500_000)
            if reach() { return true }
        }
        return false
    }

    private static func reach() -> Bool {
        guard var address = ClaudeWire.address(ClaudeAccess.socket) else { return false }
        let fd = ClaudeWire.socket()
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else {
            Darwin.close(fd)
            return false
        }
        socket = fd
        pending = Data()
        return true
    }
}
