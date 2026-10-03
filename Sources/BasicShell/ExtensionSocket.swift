import Foundation
import WebKit

// A WebSocket for an extension's worker.
//
// WebKit runs an extension's service worker on the main thread of its web
// process, and a worker's WebSocket waits there, synchronously, for the main
// thread to set up its channel: the worker waits on itself, and the process
// locks up for about a minute, popup included. Bitwarden opens one for live
// sync as soon as you are signed in.
//
// So in a worker the fixes' WebSocket (see Extensions.fixes) is made here
// instead, with URLSession, and its frames carried over a native port: text
// as it is, binary as base64. The Origin is the extension's, the user agent
// the one its worker reports.
//
// After Search's ExtensionSocket.swift (Office Commun, MIT).
enum ExtensionSocket {
    /// The native application the fixes connect to for a socket.
    static let name = "basicshell.socket"

    /// One session for every socket; each task has its connection as its
    /// own delegate.
    private static let session = URLSession(configuration: .default, delegate: nil, delegateQueue: .main)
    /// Held from the port's opening until either end lets go.
    private static var open: [ObjectIdentifier: Connection] = [:]

    static func connect(_ port: WKWebExtension.MessagePort, for context: WKWebExtensionContext) {
        let connection = Connection(port: port, origin: context.baseURL.absoluteString.trimmingCharacters(in: ["/"]),
                                    name: context.webExtension.displayName ?? context.uniqueIdentifier)
        let key = ObjectIdentifier(connection)
        open[key] = connection
        connection.onEnd = { open[key] = nil }
    }

    @MainActor
    final class Connection: NSObject, URLSessionWebSocketDelegate {
        private let port: WKWebExtension.MessagePort
        private let origin: String
        private let name: String
        private var task: URLSessionWebSocketTask?
        private var ended = false
        var onEnd: (() -> Void)?

        init(port: WKWebExtension.MessagePort, origin: String, name: String) {
            self.port = port
            self.origin = origin
            self.name = name
            super.init()
            port.messageHandler = { [weak self] message, _ in
                MainActor.assumeIsolated { self?.take(message) }
            }
            port.disconnectHandler = { [weak self] _ in
                MainActor.assumeIsolated { self?.end(tellingPort: false) }
            }
            // WebKit loses what goes over a port a worker has only just
            // opened; the fixes take any answer for the sign it arrived.
            post(["ready": true])
        }

        private func take(_ message: Any?) {
            guard let message = message as? [String: Any] else { return }
            if let address = message["open"] as? String {
                // The worker says "open" until it hears back: a repeat is
                // only answered.
                post(["ready": true])
                guard task == nil else { return }
                start(address, protocols: message["protocols"] as? [String] ?? [], userAgent: message["userAgent"] as? String)
            } else if let text = message["send"] as? String {
                task?.send(.string(text)) { _ in }
            } else if let encoded = message["sendBinary"] as? String, let data = Data(base64Encoded: encoded) {
                task?.send(.data(data)) { _ in }
            } else if message["close"] != nil {
                let code = (message["close"] as? Int).flatMap(URLSessionWebSocketTask.CloseCode.init(rawValue:)) ?? .normalClosure
                task?.cancel(with: code, reason: (message["reason"] as? String).map { Data($0.utf8) })
            }
        }

        private func start(_ address: String, protocols: [String], userAgent: String?) {
            guard task == nil, let url = URL(string: address), ["ws", "wss"].contains(url.scheme?.lowercased()) else {
                return fail()
            }
            var request = URLRequest(url: url)
            request.setValue(origin, forHTTPHeaderField: "Origin")
            if let userAgent { request.setValue(userAgent, forHTTPHeaderField: "User-Agent") }
            if !protocols.isEmpty {
                request.setValue(protocols.joined(separator: ", "), forHTTPHeaderField: "Sec-WebSocket-Protocol")
            }
            // The host only: the address may carry a sign-in token.
            Debug.log("extension", "\(name): socket to \(url.host() ?? "?")")
            let task = ExtensionSocket.session.webSocketTask(with: request)
            task.delegate = self
            self.task = task
            task.resume()
        }

        /// Frames as they come, until the socket ends; how it ended is the
        /// delegate's to say.
        private func receive(from task: URLSessionWebSocketTask) {
            Task { [weak self] in
                while let message = try? await task.receive() {
                    guard let self, !self.ended else { return }
                    switch message {
                    case .string(let text): self.post(["text": text])
                    case .data(let data): self.post(["binary": data.base64EncodedString()])
                    @unknown default: break
                    }
                }
            }
        }

        private func post(_ message: [String: Any]) {
            guard !port.isDisconnected else { return }
            port.sendMessage(message, completionHandler: nil)
        }

        private func fail() {
            post(["failed": true])
            post(["closed": 1006, "reason": "", "clean": false])
            end(tellingPort: true)
        }

        private func end(tellingPort: Bool) {
            guard !ended else { return }
            ended = true
            task?.cancel(with: .goingAway, reason: nil)
            if tellingPort, !port.isDisconnected { port.disconnect() }
            onEnd?()
        }

        nonisolated func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol chosen: String?) {
            MainActor.assumeIsolated {
                post(["opened": chosen ?? ""])
                receive(from: webSocketTask)
            }
        }

        nonisolated func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
            MainActor.assumeIsolated {
                post(["closed": closeCode.rawValue, "reason": reason.map { String(decoding: $0, as: UTF8.self) } ?? "", "clean": true])
                end(tellingPort: true)
            }
        }

        nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
            MainActor.assumeIsolated {
                guard !ended else { return }
                if let error {
                    Debug.log("extension", "\(name): socket failed: \(error.localizedDescription)")
                    fail()
                } else {
                    post(["closed": 1005, "reason": "", "clean": true])
                    end(tellingPort: true)
                }
            }
        }
    }
}
