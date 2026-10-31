#if AGENT
import AppKit
import SwiftUI

// What you see of the agent in BasicShell (see Agent.swift): the frame around
// a page it works in, and its page in Settings.

/// Beside a tab the agent works in, in the sidebar.
struct AgentMark: View {
    let tab: Tab
    let size: CGFloat

    var body: some View {
        // Shown while the agent is at work in the tab, and for a moment after it has finished.
        switch AgentAccess.shared.presence[tab.id] {
        case .working:
            Image(systemName: "cursorarrow.rays")
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(Color(nsColor: AgentAccess.color))
                .help("Agent at work here")
        case .finished:
            Image(systemName: "checkmark.circle")
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(.secondary)
                .help("Agent finished here")
        case nil:
            EmptyView()
        }
    }
}

/// Around the page while the tab shown is one the agent works in: a line in
/// the agent's colour, and at the bottom what is going on, with the button
/// that stops it.
struct AgentFrame: View {
    var radius: CGFloat = 0
    /// The tab shown: what is said depends on what the agent is doing in it.
    var tab: Tab?
    static let pill = CGSize(width: 190, height: 32)
    static let lift: CGFloat = 14

    var body: some View {
        let color = Color(nsColor: AgentAccess.color)
        let finished = tab.flatMap { AgentAccess.shared.presence[$0.id] } == .finished
        ZStack(alignment: .bottom) {
            // The line goes quiet once the agent has.
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(color.opacity(finished ? 0.3 : 1), lineWidth: finished ? 1 : 2)
            HStack(spacing: 8) {
                Image(systemName: finished ? "checkmark.circle" : "cursorarrow.rays")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(finished ? Color.secondary : color)
                // Short enough to be read whole; "unasked" is the one thing worth the room (bypass).
                Text(finished ? "Agent done" : (AgentAccess.bypass ? "Agent at work · unasked" : "Agent at work"))
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .fixedSize()
                Spacer(minLength: 0)
                if !finished {
                    Button("Stop") { AgentAccess.shared.stopNow() }
                        .buttonStyle(.borderless)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(color)
                        .help("Stops the agent here, and in every other tab, until you let it carry on")
                }
            }
            .padding(.horizontal, 12)
            .frame(width: AgentAccess.bypass && !finished ? 250 : AgentFrame.pill.width, height: AgentFrame.pill.height)
            .glassEffect(.regular, in: .capsule)
            .padding(.bottom, AgentFrame.lift)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Shows the frame but lets every click through to the page, except on the
/// pill at the bottom.
final class AgentFrameHost: NSHostingView<AgentFrame> {
    override func hitTest(_ point: NSPoint) -> NSView? {
        let here = convert(point, from: superview)
        let fromBottom = isFlipped ? bounds.maxY - here.y : here.y - bounds.minY
        let pill = AgentFrame.pill
        guard abs(here.x - bounds.midX) <= pill.width / 2, fromBottom >= AgentFrame.lift, fromBottom <= AgentFrame.lift + pill.height else { return nil }
        return super.hitTest(point)
    }
}

/// One of the switches for what the agent may do beyond pages: what it is in
/// plain words, and the tools it turns on.
private struct PowerToggle: View {
    let power: AgentPower
    var indented = false
    var enabled = true
    @AppStorage private var on: Bool
    @AppStorage(AgentAccess.bypassKey) private var bypass = false

    init(_ power: AgentPower, indented: Bool = false, enabled: Bool = true) {
        self.power = power
        self.indented = indented
        self.enabled = enabled
        _on = AppStorage(wrappedValue: false, power.key)
    }

    var body: some View {
        // While bypass is on every switch is on, and can't be changed.
        Toggle(isOn: Binding(get: { on || bypass }, set: { on = $0 })) {
            VStack(alignment: .leading, spacing: 3) {
                Text(power.title)
                Text(power.detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text("Tools: " + power.tools.joined(separator: ", "))
                    .font(.caption.monospaced()).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .disabled(!enabled || bypass)
        .padding(.leading, indented ? 22 : 0)
    }
}

/// What the agent can do on a page once the site allows it, said once, in words.
private struct Ability: View {
    let title: String
    let detail: String
    let tools: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
            Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("Tools: " + tools.joined(separator: ", "))
                .font(.caption.monospaced()).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Settings › Agents.
struct AgentSettings: View {
    @AppStorage(AgentAccess.enabledKey) private var enabled = false
    @AppStorage(AgentAccess.bypassKey) private var bypass = false
    @AppStorage(AgentAccess.profileKey) private var agentProfile = "choose"
    // `@State` is a macro in the macOS 27 SDK whose plugin ships only with
    // Xcode, so the State it would expand to is stored by hand.
    private var _status = State(initialValue: "")
    private var status: String {
        get { _status.wrappedValue }
        nonmutating set { _status.wrappedValue = newValue }
    }
    private var _newSite = State(initialValue: "")
    private var newSite: String {
        get { _newSite.wrappedValue }
        nonmutating set { _newSite.wrappedValue = newValue }
    }
    private var _newPolicy = State(initialValue: AgentSitePolicy.readOnly)
    private var newPolicy: AgentSitePolicy {
        get { _newPolicy.wrappedValue }
        nonmutating set { _newPolicy.wrappedValue = newValue }
    }
    private var _siteProblem = State(initialValue: "")
    private var siteProblem: String {
        get { _siteProblem.wrappedValue }
        nonmutating set { _siteProblem.wrappedValue = newValue }
    }

    var body: some View {
        let access = AgentAccess.shared
        let developer = AgentPower.developer.isOn
        Form {
            Section {
                Toggle(isOn: $enabled) {
                    Text("Let an agent use this browser")
                    Text("AI agents (Claude Code, Codex, the Claude app, Antigravity, or any other that speaks the Model Context Protocol) get tools for BasicShell: they can see your tabs, read pages and act in them, as you and signed in as you. Nothing is on until you say so here, and what is allowed is chosen below.")
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
                Text("A page can try to talk the agent into things with text you don't see. Asking per site, the frame around a tab it is using and its Stop button are there for that; keep it to sites you trust.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if enabled {
                Section {
                    LabeledContent {
                        HStack {
                            Button("Copy Command") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(AgentConnect.command, forType: .string)
                                status = "Copied. Paste it into a terminal."
                            }
                            Button("Add") { status = "Adding…"; AgentConnect.addToCode { status = $0 } }
                                .disabled(AgentConnect.code == nil)
                        }
                    } label: {
                        Text("Claude Code")
                        Text(AgentConnect.code == nil ? "Not found on this Mac; the command adds it wherever it is." : "For every project. Sessions started after have it.")
                    }
                    LabeledContent {
                        Button("Add") { status = "Adding…"; AgentConnect.addToCodex { status = $0 } }
                            .disabled(AgentConnect.codex == nil)
                    } label: {
                        Text("Codex")
                        Text(AgentConnect.codex == nil ? "Not found on this Mac." : "The Codex command line and app. Written into ~/.codex/config.toml; start a new session after.")
                    }
                    LabeledContent {
                        Button("Add") { status = AgentConnect.addToApp() }
                            .disabled(!AgentConnect.appIsHere)
                    } label: {
                        Text("Claude app")
                        Text(AgentConnect.appIsHere ? "Written into the app's own settings; quit and reopen Claude after." : "Not found on this Mac.")
                    }
                    LabeledContent {
                        Button("Add") { status = AgentConnect.addToAntigravity() }
                    } label: {
                        Text("Antigravity")
                        Text("The agy command line and the editor. Written into ~/.gemini/config/mcp_config.json; restart it after.")
                    }
                    LabeledContent {
                        Button("Add") { status = AgentConnect.addSkill() }
                    } label: {
                        Text("Skill for Claude Code")
                        Text("How to use these tools without wasting turns. Written into ~/.claude/skills/basicshell.")
                    }
                    LabeledContent {
                        Button("Copy Config") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(AgentConnect.config, forType: .string)
                            status = "Copied. Put it in the agent's list of MCP servers."
                        }
                    } label: {
                        Text("Any other agent")
                        Text("A server for the Model Context Protocol, started by the agent with its program and `--mcp`.")
                    }
                    if !status.isEmpty { Text(status).font(.caption).foregroundStyle(.secondary) }
                } header: {
                    Text("Connect")
                } footer: {
                    Text("Added once, it stays: a new chat has BasicShell's tools without adding it again. After BasicShell is updated, quit and reopen it, and start a new chat, to get new tools.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section {
                    Picker("Pages the agent opens go in", selection: $agentProfile) {
                        Text("Whatever the agent decides, task by task").tag("choose")
                        Text("Always the profile shown, with your sign-ins").tag("shown")
                        Text("Always a profile of its own, “Agent”, with none").tag("own")
                    }
                } footer: {
                    Text("Left to the agent it uses your sign-ins when the task needs them, and the signed-out “Agent” profile for reading public pages. Either way its tabs stay open when it is done unless it closes them, and it can look at a tab of yours that you ask it to.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("On a web page") {
                    Ability(title: "Read it",
                            detail: "A page's text, what is on it, a picture of it (the view, a part, or the whole page), what you have selected there, how its connection and certificate stand and what you have allowed the site, saving it as a PDF, recording it as a GIF, opening and closing tabs, reading many pages in one go, and opening files on this Mac (all of them are one site, \"files on this Mac\"). Needs your \"read\" for the site.",
                            tools: ["open", "close", "select", "navigate", "read_text", "read_page", "find", "screenshot", "selection", "pick", "site_info", "wait", "save_page", "record", "read_pages"])
                    Ability(title: "Click and type in it",
                            detail: "Click, drag, type, press keys, scroll, fill in forms (a whole form, or the site's search, in one call), answer the page's alerts, change the window's size, look and user agent to try a layout, download a file into Downloads (asked each time) or give the page a file from this Mac (asked each time). Needs your \"click and type\" for the site, which includes reading.",
                            tools: ["click", "hover", "drag", "type", "key", "scroll", "fill", "fill_form", "search", "dialog", "resize", "upload", "download", "batch"])
                    Text("Never, whatever is set: private tabs, and what is in password, card and one-time-code fields. The agent can't see them or fill them; signing in and paying stay yours.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section {
                    Toggle(isOn: $bypass) {
                        Text("Bypass permissions")
                        Text("Stop asking, and open everything. The agent may read, click and type on any site and open any file on this Mac without a question, give pages files from this Mac, download files and clear cookies and storage; what a page it works in asks (your location, to show notifications, to open another app) is answered no, unasked; and every switch below is on: the clipboard, tabs, extensions, history, developer tools, WebKit features and storage. For work you are watching.")
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Still in force with it on").font(.callout.weight(.medium))
                        Text("Sites you set to Never. Private tabs, and password and card fields. The Stop button on the page's frame. Turn bypass off and the switches below are as you left them.")
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                } header: {
                    Text("Asking")
                } footer: {
                    Text("Without it, BasicShell asks the first time the agent wants to read a site and again before it clicks or types there; \"Remember for this site\" keeps the answer (see Sites). With it on, a page that talks the agent into something meets nothing in its way.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section {
                    PowerToggle(.tabs)
                    PowerToggle(.history)
                    PowerToggle(.clipboard)
                    PowerToggle(.extensions)
                } header: {
                    Text("Beyond web pages")
                } footer: {
                    Text("Each is off until you turn it on, and all are on while Bypass permissions is.").font(.caption).foregroundStyle(.secondary)
                }

                Section {
                    let quiet = AgentQuiet.shared
                    Picker(selection: Binding(get: { quiet.mode }, set: { quiet.choose($0) })) {
                        ForEach(QuietMode.allCases) { Text($0.title).tag($0) }
                    } label: {
                        Text("Knowing a click is done")
                        Text(quiet.byAgent ? "An agent switched this for now; choosing here keeps your choice." : "How the tools tell that what a click or a key started is over.")
                    }
                } header: {
                    Text("Waiting")
                } footer: {
                    Text("A script in the page is the quickest and costs no memory, but it is code in the page. The Web Inspector puts none there: it reads what WebKit knows of the page's timers, frames and requests, at about 130 MB for each tab the agent works in while it works there, which is given back a minute after. The agent can switch to it by itself if an action seems to come back too early or late.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section {
                    PowerToggle(.developer)
                    PowerToggle(.bodies, indented: true, enabled: developer)
                    PowerToggle(.storage, indented: true, enabled: developer)
                    PowerToggle(.features, indented: true, enabled: developer)
                } header: {
                    Text("For developers")
                } footer: {
                    Text("A page opened before you turn these on isn't watched: reload it. The last three work only while Developer tools are on (or bypass is).")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Set a site")
                        Text(siteProblem.isEmpty ? "Decide for a site before the agent asks." : siteProblem)
                            .font(.callout)
                            .foregroundStyle(siteProblem.isEmpty ? Color.secondary : Color.red)
                        HStack {
                            TextField("example.com", text: Binding(get: { newSite }, set: { newSite = $0; siteProblem = "" }))
                                .textFieldStyle(.roundedBorder)
                                .onSubmit(addSite)
                            Picker("", selection: Binding(get: { newPolicy }, set: { newPolicy = $0 })) {
                                ForEach(AgentSitePolicy.allCases) { Text($0.title).tag($0) }
                            }
                            .labelsHidden()
                            .fixedSize()
                            Button("Add", action: addSite).disabled(newSite.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }
                    let sites = access.sites.sorted { $0.key < $1.key }
                    if sites.isEmpty {
                        Text("No site has an answer yet. Each is asked about when the agent first wants it.").foregroundStyle(.secondary)
                    }
                    ForEach(sites, id: \.key) { site, _ in
                        HStack {
                            Text(site)
                            Spacer()
                            Picker("", selection: Binding(get: { access.policy(for: site) }, set: { access.setPolicy($0, for: site) })) {
                                ForEach(AgentSitePolicy.allCases) { Text($0.title).tag($0) }
                            }
                            .labelsHidden()
                            .fixedSize()
                            Button { access.forget(site) } label: { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(.borderless)
                                .help("Forget, and ask again")
                        }
                    }
                } header: {
                    Text("Sites")
                } footer: {
                    Text("\"Never\" keeps the agent out of a site even with bypass on. \"Ask each time\" is the default and is not listed.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section {
                    if access.activity.isEmpty {
                        Text("Nothing yet.").foregroundStyle(.secondary)
                    }
                    ForEach(access.activity.prefix(25)) { entry in
                        HStack(spacing: 8) {
                            Text(entry.date, format: .dateTime.hour().minute().second())
                                .font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                            Text(entry.tool).font(.callout.monospaced())
                            if let site = entry.site { Text(site).foregroundStyle(.secondary) }
                            if let summary = entry.summary { Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                            Spacer()
                            if entry.took > 0 {
                                Text(entry.took >= 1000 ? String(format: "%.1f s", Double(entry.took) / 1000) : "\(entry.took) ms")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(entry.took >= 3000 ? Color.orange : Color.secondary)
                            }
                            if entry.failed { Text("refused or failed").font(.caption).foregroundStyle(.red) }
                            Text(entry.client).font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                    if !access.activity.isEmpty {
                        Button("Clear") { access.clearActivity() }
                    }
                } header: {
                    Text("Recent activity")
                } footer: {
                    Text("What the agent has done since BasicShell opened, newest first, and how long each call took (a slow one in orange). Kept in memory only.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func addSite() {
        let text = newSite.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        let files = ["file", "files", "file://", "files on this mac"].contains(text.lowercased())
        guard let site = files ? AgentAccess.filesSite : AgentAccess.site(URL(string: text.contains("://") ? text : "https://" + text)) else {
            siteProblem = "That isn't a site's name."
            return
        }
        AgentAccess.shared.setPolicy(newPolicy, for: site)
        newSite = ""
        siteProblem = ""
    }
}

/// Telling the agent where BasicShell is.
enum AgentConnect {
    private static var program: String { Bundle.main.executablePath ?? "" }

    static var command: String { "claude mcp add --scope user basicshell -- \"\(program)\" --mcp" }

    /// Claude Code's own program, where its installers put it.
    static var code: String? {
        let home = NSHomeDirectory()
        return ["\(home)/.local/bin/claude", "\(home)/.claude/local/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Codex's own program, where its installers put it.
    static var codex: String? {
        let home = NSHomeDirectory()
        return ["/opt/homebrew/bin/codex", "/usr/local/bin/codex", "\(home)/.local/bin/codex", "\(home)/.npm-global/bin/codex", "\(home)/.bun/bin/codex"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Asks Claude Code to add it (taking out an older entry first, which
    /// may point at where BasicShell used to be).
    static func addToCode(_ done: @escaping @MainActor (String) -> Void) {
        addThroughCommandLine(code, name: "Claude Code", added: "Added to Claude Code. Sessions started from now on have BasicShell's tools.", done)
    }

    /// The same for Codex, whose `mcp` commands take the same words.
    static func addToCodex(_ done: @escaping @MainActor (String) -> Void) {
        addThroughCommandLine(codex, name: "Codex", added: "Added to Codex. Sessions started from now on have BasicShell's tools.", done)
    }

    private static func addThroughCommandLine(_ tool: String?, name: String, added: String, _ done: @escaping @MainActor (String) -> Void) {
        guard let tool else { return done("\(name) wasn't found.") }
        let program = program
        DispatchQueue.global(qos: .userInitiated).async {
            func run(_ arguments: [String]) -> (Int32, String) {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: tool)
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
            // Claude Code takes the scope; Codex has one list and no such flag.
            let scope = name == "Claude Code" ? ["--scope", "user"] : []
            _ = run(["mcp", "remove"] + scope + ["basicshell"])
            let (status, said) = run(["mcp", "add"] + scope + ["basicshell", "--", program, "--mcp"])
            let message = status == 0 ? added : "\(name) said: \(said.suffix(200))"
            DispatchQueue.main.async { MainActor.assumeIsolated { done(message) } }
        }
    }

    private static var appFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Claude", isDirectory: true)
    }

    static var appIsHere: Bool { FileManager.default.fileExists(atPath: appFolder.path) }

    /// The entry any agent's list of MCP servers takes.
    static var config: String {
        let entry: [String: Any] = ["mcpServers": ["basicshell": ["command": program, "args": ["--mcp"]]]]
        let data = (try? JSONSerialization.data(withJSONObject: entry, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// Written into Antigravity's list of MCP servers (the command line's
    /// and the editor's share it), the rest of the file left as it is.
    static func addToAntigravity() -> String {
        let folder = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".gemini/config", isDirectory: true)
        let file = folder.appendingPathComponent("mcp_config.json")
        var settings: [String: Any] = [:]
        if let data = try? Data(contentsOf: file) {
            guard let read = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                return "Antigravity's file couldn't be read, so it was left alone."
            }
            settings = read
        }
        var servers = settings["mcpServers"] as? [String: Any] ?? [:]
        servers["basicshell"] = ["command": program, "args": ["--mcp"]]
        settings["mcpServers"] = servers
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard let data = try? JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              (try? data.write(to: file, options: .atomic)) != nil
        else { return "Antigravity's file couldn't be written." }
        return "Added to Antigravity. Restart it (or run /mcp there) to finish."
    }

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
#endif
