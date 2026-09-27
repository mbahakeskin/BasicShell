import AppKit
import WebKit

// Chrome's native messaging: an extension talks to an app on this Mac
// (Bitwarden to Bitwarden's desktop app, for Touch ID) through a helper the
// app installs and names in a small manifest. The helper is started with
// the extension's address as its argument and speaks JSON on its standard
// input and output, each message preceded by its length in four bytes.
//
// The manifest is looked for where Chrome keeps them, so an app that set
// itself up for Chrome works here too, and in BasicShell's own folder. It is
// used only if it names the extension among its allowed origins, and the
// helper runs only once you have said it may, the first time.
enum NativeHosts {
    struct Manifest: Decodable {
        let name: String
        let path: String
        let type: String
        let allowed_origins: [String]?
    }

    enum Refused: LocalizedError {
        case notFound(String), notAllowed(String), failed(String)
        var errorDescription: String? {
            switch self {
            case .notFound(let name): "No app on this Mac answers to \(name)"
            case .notAllowed(let name): "Talking to \(name) wasn't allowed"
            case .failed(let why): why
            }
        }
    }

    private static var folders: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            Store.folder.appendingPathComponent("NativeMessagingHosts", isDirectory: true),
            home.appendingPathComponent("Library/Application Support/Google/Chrome/NativeMessagingHosts", isDirectory: true),
            URL(fileURLWithPath: "/Library/Google/Chrome/NativeMessagingHosts", isDirectory: true),
        ]
    }

    /// The manifest for `name` that lets `origin` in, if any.
    static func manifest(_ name: String, for origin: String) -> Manifest? {
        // Chrome's rule for host names; it also keeps the name to one file.
        guard name.range(of: #"^[a-z0-9_]+(\.[a-z0-9_]+)*$"#, options: .regularExpression) != nil else { return nil }
        for folder in folders {
            let file = folder.appendingPathComponent("\(name).json")
            guard let data = try? Data(contentsOf: file),
                  let found = try? JSONDecoder().decode(Manifest.self, from: data),
                  found.name == name, found.type == "stdio", found.path.hasPrefix("/"),
                  found.allowed_origins?.contains(origin) == true,
                  FileManager.default.isExecutableFile(atPath: found.path)
            else { continue }
            return found
        }
        return nil
    }

    /// Opens a connection for an extension, asking the first time.
    static func open(_ name: String, for context: WKWebExtensionContext) throws -> NativeConnection {
        let origin = context.baseURL.absoluteString
        guard let found = manifest(name, for: origin) else {
            Debug.log("native", "\(name): no manifest lets \(origin) in")
            throw Refused.notFound(name)
        }
        let key = "\(origin) \(found.path)"
        var allowed = Set(UserDefaults.standard.stringArray(forKey: "native.allowed") ?? [])
        if !allowed.contains(key) {
            let app = appName(for: found.path)
            let alert = NSAlert()
            alert.messageText = "\(context.webExtension.displayName ?? "An extension") wants to talk to \(app)"
            alert.informativeText = "It would start \(found.path) and exchange messages with it, as it does in Chrome."
            alert.addButton(withTitle: "Allow")
            alert.addButton(withTitle: "Don't Allow")
            guard alert.runModal() == .alertFirstButtonReturn else {
                Debug.log("native", "\(name): not allowed")
                throw Refused.notAllowed(name)
            }
            allowed.insert(key)
            UserDefaults.standard.set(Array(allowed).sorted(), forKey: "native.allowed")
        }
        return try NativeConnection(name: name, path: found.path, origin: origin)
    }

    /// "Bitwarden" for /Applications/Bitwarden.app/Contents/MacOS/desktop_proxy.
    private static func appName(for path: String) -> String {
        var url = URL(fileURLWithPath: path)
        while url.path != "/" {
            if url.pathExtension == "app" { return FileManager.default.displayName(atPath: url.path) }
            url.deleteLastPathComponent()
        }
        return (path as NSString).lastPathComponent
    }
}

/// One running helper and the pipes to it.
final class NativeConnection {
    let name: String
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    var onMessage: ((Any) -> Void)?
    var onClose: (() -> Void)?
    private var closed = false

    init(name: String, path: String, origin: String) throws {
        self.name = name
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = [origin]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch {
            throw NativeHosts.Refused.failed("\(name) didn't start: \(error.localizedDescription)")
        }
        Debug.log("native", "\(name): started")
        let reader = output.fileHandleForReading
        // Blocking reads, off the main thread: a length, then that much JSON.
        Thread.detachNewThread { [weak self] in
            while true {
                let head = reader.readData(ofLength: 4)
                guard head.count == 4 else { break }
                let length = head.withUnsafeBytes { Int(UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self))) }
                guard length <= 64 << 20 else { break }
                let body = reader.readData(ofLength: length)
                guard body.count == length else { break }
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.received(body) } }
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.close() } }
        }
    }

    private func received(_ body: Data) {
        guard !closed, let message = try? JSONSerialization.jsonObject(with: body, options: [.fragmentsAllowed]) else { return }
        onMessage?(message)
    }

    func send(_ message: Any) {
        guard !closed, let body = try? JSONSerialization.data(withJSONObject: message, options: [.fragmentsAllowed]) else { return }
        var length = UInt32(body.count).littleEndian
        let head = Data(bytes: &length, count: 4)
        do {
            try input.fileHandleForWriting.write(contentsOf: head + body)
        } catch {
            Debug.log("native", "\(name): couldn't write: \(error.localizedDescription)")
            close()
        }
    }

    func close() {
        guard !closed else { return }
        closed = true
        Debug.log("native", "\(name): closed")
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
        onClose?()
    }
}
