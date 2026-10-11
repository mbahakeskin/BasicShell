import AppKit
import SwiftUI

// What you see of Claude in BasicShell (see Claude.swift): the frame around
// a page it works in, and its page in Settings.

/// Around the page while the tab shown is one Claude works in: a line in
/// Claude's colour, and at the bottom what is going on, with the button
/// that stops it.
struct ClaudeFrame: View {
    var radius: CGFloat = 0
    static let pill = CGSize(width: 270, height: 32)
    static let lift: CGFloat = 14

    var body: some View {
        let color = Color(nsColor: ClaudeAccess.color)
        ZStack(alignment: .bottom) {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(color, lineWidth: 2)
            HStack(spacing: 8) {
                Image(systemName: "sparkle")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(color)
                Text("Claude is using this tab")
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 0)
                Button("Stop") { ClaudeAccess.shared.stopNow() }
                    .buttonStyle(.borderless)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(color)
                    .help("Stops Claude here, and in every other tab, until you let it carry on")
            }
            .padding(.horizontal, 12)
            .frame(width: ClaudeFrame.pill.width, height: ClaudeFrame.pill.height)
            .glassEffect(.regular, in: .capsule)
            .padding(.bottom, ClaudeFrame.lift)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Shows the frame but lets every click through to the page, except on the
/// pill at the bottom.
final class ClaudeFrameHost: NSHostingView<ClaudeFrame> {
    override func hitTest(_ point: NSPoint) -> NSView? {
        let here = convert(point, from: superview)
        let fromBottom = isFlipped ? bounds.maxY - here.y : here.y - bounds.minY
        let pill = ClaudeFrame.pill
        guard abs(here.x - bounds.midX) <= pill.width / 2, fromBottom >= ClaudeFrame.lift, fromBottom <= ClaudeFrame.lift + pill.height else { return nil }
        return super.hitTest(point)
    }
}

/// Settings › Claude.
struct ClaudeSettings: View {
    @AppStorage(ClaudeAccess.enabledKey) private var enabled = false
    @AppStorage(ClaudeAccess.historyKey) private var history = false
    @AppStorage(ClaudeAccess.developerKey) private var developer = false
    // `@State` is a macro in the macOS 27 SDK whose plugin ships only with
    // Xcode, so the State it would expand to is stored by hand.
    private var _status = State(initialValue: "")
    private var status: String {
        get { _status.wrappedValue }
        nonmutating set { _status.wrappedValue = newValue }
    }

    var body: some View {
        let access = ClaudeAccess.shared
        Form {
            Section {
                Toggle(isOn: $enabled) {
                    Text("Let Claude use this browser")
                    Text("Claude Code and the Claude app get tools for it: your tabs, reading a page, clicking and typing in it, as you and signed in as you. You are asked about each site first. Private tabs are kept from it, and so is what is in password and card fields.")
                }
                .onChange(of: enabled) { _, _ in access.start() }
                if enabled {
                    LabeledContent("Connected now") {
                        Text(access.clients.isEmpty ? "Nobody" : access.clients.joined(separator: ", ")).foregroundStyle(.secondary)
                    }
                    if access.stopped {
                        LabeledContent("You stopped it") {
                            Button("Let It Carry On") { access.resume() }
                        }
                    }
                }
            } footer: {
                Text("A page can try to talk Claude into things with text you don't see. Asking per site, the frame around a tab it is using and its Stop button are there for that; keep it to sites you trust.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if enabled {
                Section("Connect") {
                    LabeledContent {
                        HStack {
                            Button("Copy Command") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(ClaudeConnect.command, forType: .string)
                                status = "Copied. Paste it into a terminal."
                            }
                            Button("Add") { status = "Adding…"; ClaudeConnect.addToCode { status = $0 } }
                                .disabled(ClaudeConnect.code == nil)
                        }
                    } label: {
                        Text("Claude Code")
                        Text(ClaudeConnect.code == nil ? "Not found on this Mac; the command adds it wherever it is." : "For every project. Sessions started after have it.")
                    }
                    LabeledContent {
                        Button("Add") { status = ClaudeConnect.addToApp() }
                            .disabled(!ClaudeConnect.appIsHere)
                    } label: {
                        Text("Claude app")
                        Text(ClaudeConnect.appIsHere ? "Written into the app's own settings; quit and reopen Claude after." : "Not found on this Mac.")
                    }
                    if !status.isEmpty { Text(status).font(.caption).foregroundStyle(.secondary) }
                }
                Section("It may also have") {
                    Toggle(isOn: $history) {
                        Text("History, bookmarks and downloads")
                        Text("To find a page you were on, or a file you downloaded.")
                    }
                    Toggle(isOn: $developer) {
                        Text("Developer tools")
                        Text("A page's console and network requests, and scripts of Claude's own in a page. A script reaches everything on the page, password fields too. Pages opened from now on are watched.")
                    }
                }
                Section("Sites") {
                    let sites = access.sites.sorted { $0.key < $1.key }
                    if sites.isEmpty {
                        Text("No site has a remembered answer.").foregroundStyle(.secondary)
                    }
                    ForEach(sites, id: \.key) { site, answers in
                        HStack {
                            Text(site)
                            Spacer()
                            Text(ClaudeSettings.describe(answers)).foregroundStyle(.secondary)
                            Button { access.forget(site) } label: { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(.borderless)
                                .help("Forget, and ask again")
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private static func describe(_ answers: [String: Bool]) -> String {
        if answers["read"] == false { return "Not allowed" }
        if answers["act"] == true { return "Read, click and type" }
        if answers["act"] == false { return answers["read"] == true ? "Read only" : "No clicking or typing" }
        return "Read"
    }
}

/// Telling Claude where BasicShell is.
enum ClaudeConnect {
    private static var program: String { Bundle.main.executablePath ?? "" }

    static var command: String { "claude mcp add --scope user basicshell -- \"\(program)\" --mcp" }

    /// Claude Code's own program, where its installers put it.
    static var code: String? {
        let home = NSHomeDirectory()
        return ["\(home)/.local/bin/claude", "\(home)/.claude/local/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Asks Claude Code to add it (taking out an older entry first, which
    /// may point at where BasicShell used to be).
    static func addToCode(_ done: @escaping @MainActor (String) -> Void) {
        guard let code else { return done("Claude Code wasn't found.") }
        let program = program
        DispatchQueue.global(qos: .userInitiated).async {
            func run(_ arguments: [String]) -> (Int32, String) {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: code)
                process.arguments = arguments
                var environment = ProcessInfo.processInfo.environment
                environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (environment["PATH"] ?? "")
                process.environment = environment
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe
                process.standardInput = FileHandle.nullDevice
                guard (try? process.run()) != nil else { return (-1, "couldn't be started") }
                let output = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                return (process.terminationStatus, String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
            }
            _ = run(["mcp", "remove", "--scope", "user", "basicshell"])
            let (status, said) = run(["mcp", "add", "--scope", "user", "basicshell", "--", program, "--mcp"])
            let message = status == 0 ? "Added to Claude Code. Sessions started from now on have BasicShell's tools." : "Claude Code said: \(said.suffix(200))"
            DispatchQueue.main.async { MainActor.assumeIsolated { done(message) } }
        }
    }

    private static var appFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Claude", isDirectory: true)
    }

    static var appIsHere: Bool { FileManager.default.fileExists(atPath: appFolder.path) }

    /// Written into the Claude app's list of local tools, the rest of its
    /// settings left as they are.
    static func addToApp() -> String {
        let file = appFolder.appendingPathComponent("claude_desktop_config.json")
        var settings: [String: Any] = [:]
        if let data = try? Data(contentsOf: file) {
            guard let read = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                return "The Claude app's settings file couldn't be read, so it was left alone."
            }
            settings = read
        }
        var servers = settings["mcpServers"] as? [String: Any] ?? [:]
        servers["basicshell"] = ["command": program, "args": ["--mcp"]]
        settings["mcpServers"] = servers
        guard let data = try? JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              (try? data.write(to: file, options: .atomic)) != nil
        else { return "The Claude app's settings file couldn't be written." }
        return "Added to the Claude app. Quit and reopen Claude to finish."
    }
}
