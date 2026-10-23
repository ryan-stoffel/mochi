// Your coding agents (Claude Code, Codex, Cursor, Antigravity): what each session is doing, from the CLIs' hooks,
// and the alerts that wait for you when one finishes or needs you. Each CLI runs a tiny shell script on every event,
// which hands it to Mochi over 127.0.0.1, so nothing leaves your Mac. Claude Code's status line also reports your
// plan's limits and each session's context, which go to `UsageService`.
import AppKit
import JavaScriptCore
import MochiCore
import Network

@MainActor
final class Agents {
    static let port: UInt16 = HookInstaller.port

    private(set) var store = AgentSessionStore()
    private(set) var listening = false
    private(set) var installed: [String: Bool] = [:]
    /// Alerts (sounds, repeats, notifications) and which provider's critter Mochi is. Saved in settings.json.
    var config: MinisConfig {
        didSet {
            guard config != oldValue else { return }
            Settings.shared.minis = config
            if config.providers != oldValue.providers {
                for s in store.sessions.values where !config.providerOn(s.provider) { store.remove(s.id); alerts.clear(s.id) }
            }
            changed()
        }
    }
    /// Something about the sessions changed: what Mochi acts out, its panel, Settings.
    var onChange: () -> Void = {}
    /// Claude Code's status line reported your plan's limits (`rate_limits`).
    var onClaudeLimits: ([String: Any]) -> Void = { _ in }

    private let dataDir: URL
    private var listener: NWListener?
    private let alerts = AlertCenter()
    /// Sessions that are only an app reading usage off a CLI, not anyone working.
    private var ignored: Set<String> = []

    init(dataDir: URL) {
        self.dataDir = dataDir
        config = Settings.shared.minis
        refreshInstalled()
    }

    var sessions: [AgentSession] { store.ordered }

    func start() {
        HookInstaller.refreshScripts()
        if claudeConnected { try? writeClaudeScripts() }   // keep the scripts current after an update
        alerts.onResponse = { [weak self] id, focus in
            self?.acknowledge(id)
            if focus { self?.focus(id) }
        }
        alerts.start()
        listen()
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func tick() {
        for id in store.prune(idleTimeout: config.idleMinutes * 60) { alerts.clear(id) }
        alerts.tick(waiting: store.alerting.filter { config.providerOn($0.provider) }, config: config)
        onChange()
    }

    private func changed() { onChange() }

    // MARK: - What Mochi shows

    /// For Mochi's page: what the sessions of the provider Mochi follows are up to.
    func payload() -> [String: Any] {
        let p = config.provider
        return store.payload(for: p, name: Provider.byID(p)?.name ?? p)
    }

    func summary() -> (state: String, session: AgentSession?) { store.summary(for: config.provider) }

    // MARK: - Acting on sessions

    /// You looked at it: clicked Mochi, the session in a panel, or its notification.
    func acknowledge(_ id: String) {
        guard store.acknowledge(id) else { return }
        alerts.clear(id)
        changed()
    }

    /// Answers whatever Mochi is showing: clears its alert and brings its window forward.
    func answerShown() {
        guard let s = store.shown(for: config.provider) else { return }
        acknowledge(s.id)
        focus(s.id)
    }

    /// Brings the app a session runs in (terminal, editor, desktop app) to the front.
    func focus(_ id: String) {
        guard let pid = store.sessions[id]?.pid, pid > 0, let app = Self.app(owning: pid) else { return }
        app.activate()
    }

    /// A pretend session, to see Mochi act it out and hear its alert.
    func test(_ provider: String) {
        let id = "test-\(Int(Date().timeIntervalSince1970))"
        let cwd = NSHomeDirectory() + "/Example"
        apply(AgentEvent(provider: provider, sessionID: id, kind: .toolStart, activity: .editing, detail: "example.swift", cwd: cwd), pid: 0)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, self.store.sessions[AgentSession.key(provider, id)] != nil else { return }
            self.apply(AgentEvent(provider: provider, sessionID: id, kind: .done, cwd: cwd), pid: 0)
        }
    }

    func previewSound(_ kind: AlertKind) {
        alerts.play(config.sound(kind), volume: config.volume)
    }

    private func apply(_ e: AgentEvent, pid: Int32) {
        guard config.providerOn(e.provider) else { return }
        let key = AgentSession.key(e.provider, e.sessionID)
        switch store.apply(e, pid: pid) {
        case .alerted(let kind):
            // an alert you turned off doesn't hold Mochi either
            if !config.alerts(kind) { store.acknowledge(key) } else if let s = store.sessions[key] { alerts.raise(s, config: config) }
        case .answered, .removed:
            alerts.clear(key)
        default:
            break
        }
        changed()
    }

    // MARK: - Listening

    private func listen() {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: Self.port)!)
        guard let l = try? NWListener(using: params) else { return NSLog("[mochi] agents: could not listen on %d", Self.port) }
        l.newConnectionHandler = { [weak self] c in
            MainActor.assumeIsolated { self?.accept(c) }
        }
        l.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                switch state {
                case .ready: self?.listening = true
                case .failed(let e): self?.listening = false; NSLog("[mochi] agents: listener failed: %@", "\(e)")
                default: break
                }
                self?.changed()
            }
        }
        l.start(queue: .main)
        listener = l
    }

    /// A tiny HTTP server: one POST per connection, from the hook scripts. `/hook` and `/status` are Claude Code's
    /// (its hook and status line), `/hook/<provider>` the other CLIs'.
    private func accept(_ c: NWConnection) {
        c.start(queue: .main)
        var buf = Data()
        func done(_ ok: Bool) {
            let reply = ok ? "HTTP/1.1 204 No Content\r\nConnection: close\r\n\r\n" : "HTTP/1.1 400 Bad Request\r\nConnection: close\r\n\r\n"
            c.send(content: Data(reply.utf8), completion: .contentProcessed { _ in c.cancel() })
        }
        func read() {
            c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] chunk, _, finished, error in
                MainActor.assumeIsolated {
                    guard let self else { return c.cancel() }
                    if let chunk { buf.append(chunk) }
                    if buf.count > 32 << 20 || error != nil { return c.cancel() }
                    if let head = buf.range(of: Data("\r\n\r\n".utf8)) {
                        let lines = String(decoding: buf[..<head.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
                        var fields: [String: String] = [:]
                        for line in lines.dropFirst() {
                            guard let i = line.firstIndex(of: ":") else { continue }
                            fields[line[..<i].lowercased()] = line[line.index(after: i)...].trimmingCharacters(in: .whitespaces)
                        }
                        let length = Int(fields["content-length"] ?? "") ?? 0
                        let body = buf[head.upperBound...]
                        if body.count >= length {
                            // the custom header means a web page can't post here: browsers won't send it cross-site
                            // without asking first, and nothing here answers that
                            guard fields["x-mochi"] == "1", let path = lines.first?.split(separator: " ").dropFirst().first
                            else { return done(false) }
                            let json = (try? JSONSerialization.jsonObject(with: Data(body.prefix(length)))) as? [String: Any] ?? [:]
                            let pid = Int32(fields["x-claude-pid"] ?? fields["x-pid"] ?? "") ?? 0
                            let header = { (k: String) in fields[k].flatMap { $0.isEmpty ? nil : $0 } }
                            switch path {
                            case "/hook": self.hook("claude", event: nil, session: nil, json: json, pid: pid)
                            case "/status": self.status(json)
                            case "/ping": break
                            default:
                                guard path.hasPrefix("/hook/") else { return done(false) }
                                self.hook(String(path.dropFirst("/hook/".count)), event: header("x-event"),
                                          session: header("x-session"), json: json, pid: pid)
                            }
                            return done(true)
                        }
                    }
                    if finished { return c.cancel() }
                    read()
                }
            }
        }
        read()
    }

    private func hook(_ provider: String, event: String?, session: String?, json: [String: Any], pid: Int32) {
        guard Provider.byID(provider) != nil else { return }
        var session = session
        // Antigravity names no session; one agy process is one session.
        if provider == "antigravity", session == nil, pid > 0 { session = "pid\(pid)" }
        guard let e = HookNormalizer.normalize(provider: provider, event: event, session: session, json: json) else { return }
        let key = AgentSession.key(provider, e.sessionID)
        // An app (Mochi included) reading usage off a CLI: no one is working in that session.
        if e.cwd == dataDir.path || ignored.contains(key) { return }
        let known = store.sessions[key]?.pid ?? 0
        if known == 0, pid > 0, Self.isUsageCheck(pid) { ignored.insert(key); return }
        // remember the app it runs in (Terminal, VS Code, Cursor...) once, for jumping to it
        apply(e, pid: known > 0 ? known : pid > 0 ? (Self.app(owning: pid)?.processIdentifier ?? pid) : 0)
    }

    private func status(_ j: [String: Any]) {
        if let r = j["rate_limits"] as? [String: Any] { onClaudeLimits(r) }
        if let id = j["session_id"] as? String {
            store.applyStatus(provider: "claude", sessionID: id,
                              contextPct: (j["context_window"] as? [String: Any])?["used_percentage"] as? Double)
        }
        changed()
    }

    // MARK: - Which process is which

    private static func parent(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let p = info.kp_eproc.e_ppid
        return p > 1 ? p : nil
    }

    /// The command line a process was started with.
    private static func arguments(of pid: pid_t) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return [] }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0 else { return [] }
        let argc = Int(buf.withUnsafeBytes { $0.load(as: Int32.self) })
        // after argc: the executable path, padding, then argc NUL-separated arguments
        let parts = buf[4..<size].split(separator: 0, omittingEmptySubsequences: true).map { String(decoding: $0, as: UTF8.self) }
        return Array(parts.dropFirst().prefix(argc))
    }

    /// Whether a hook came from a CLI being run just to read a screen, like `claude /usage`, which is one of the ways
    /// usage gets read. Those aren't sessions anyone is working in.
    static func isUsageCheck(_ pid: pid_t) -> Bool {
        let peek: Set<String> = ["/usage", "/stats", "/status", "/cost"]
        var p: pid_t? = pid
        for _ in 0..<6 {
            guard let cur = p else { break }
            let args = arguments(of: cur)
            if args.contains(where: peek.contains) { return true }
            if args.contains(where: { ($0 as NSString).lastPathComponent == "ptydrive" }) { return true }   // Mochi's own helper
            p = parent(of: cur)
        }
        return false
    }

    /// The app a process belongs to: walk up its parents until one is an app with a window.
    static func app(owning pid: pid_t) -> NSRunningApplication? {
        var p: pid_t? = pid
        for _ in 0..<40 {
            guard let cur = p else { break }
            if let a = NSRunningApplication(processIdentifier: cur), a.activationPolicy == .regular { return a }
            p = parent(of: cur)
        }
        return nil
    }

    // MARK: - Connecting the CLIs

    func refreshInstalled() {
        installed = Dictionary(uniqueKeysWithValues: Provider.ids.map { ($0, $0 == "claude" ? claudeConnected : HookInstaller.isInstalled($0)) })
    }

    func canInstall(_ provider: String) -> Bool {
        provider == "claude" ? hasClaudeCode : HookInstaller.canInstall(provider)
    }

    func followUp(_ provider: String) -> String? {
        provider == "claude" ? "Restart running Claude Code sessions to pick it up." : HookInstaller.targets[provider]?.followUp
    }

    func setInstalled(_ provider: String, _ on: Bool) throws {
        defer { refreshInstalled(); changed() }
        if provider == "claude" { try connectClaude(on) } else { try HookInstaller.setInstalled(provider, on) }
    }

    // Claude Code connects through its own settings: hooks plus Mochi's status line, which passes your own status
    // line through. Kept where Mochi has always kept it, so an existing connection keeps working.

    private lazy var claudeSettings = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
    private var hookScript: URL { dataDir.appendingPathComponent("claude-hook.sh") }
    private var statusScript: URL { dataDir.appendingPathComponent("claude-status.sh") }
    private var originalStatus: URL { dataDir.appendingPathComponent("claude-status-original.json") }
    var hasClaudeCode: Bool { FileManager.default.fileExists(atPath: claudeSettings.deletingLastPathComponent().path) }

    var claudeConnected: Bool {
        (try? String(contentsOf: claudeSettings, encoding: .utf8))?.contains("Mochi/claude-hook.sh") ?? false
    }

    static let claudeEvents = ["SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure",
                               "PermissionRequest", "Notification", "Stop", "StopFailure", "SubagentStart", "SubagentStop", "PreCompact", "PostCompact"]

    private static func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// Adds Mochi's hooks and status line to Claude Code's settings, or takes them out again. Everything else is left
    /// alone, in the same order, and the file is backed up first. A status line you already had keeps showing.
    private func connectClaude(_ on: Bool) throws {
        let fm = FileManager.default
        let text = (try? String(contentsOf: claudeSettings, encoding: .utf8)) ?? "{}"
        if on { try writeClaudeScripts() }
        // done in JavaScript so the file keeps its key order and formatting
        let ctx = JSContext()!
        ctx.evaluateScript(Self.configureJS)
        let original = (try? String(contentsOf: originalStatus, encoding: .utf8)) ?? ""
        let r = ctx.objectForKeyedSubscript("configure").call(withArguments: [text, on, Self.quote(hookScript.path),
                                                                              Self.quote(statusScript.path), Self.claudeEvents, original])
        if let err = ctx.exception?.toString() ?? r?.objectForKeyedSubscript("error")?.toString(), err != "undefined" {
            throw NSError(domain: "Mochi", code: 1, userInfo: [NSLocalizedDescriptionKey: err])
        }
        guard let out = r?.objectForKeyedSubscript("text")?.toString() else { return }
        try fm.createDirectory(at: claudeSettings.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: claudeSettings.path) {
            let backup = claudeSettings.deletingLastPathComponent().appendingPathComponent("settings.json.mochi-backup")
            try? fm.removeItem(at: backup)
            try fm.copyItem(at: claudeSettings, to: backup)
        }
        try out.write(to: claudeSettings, atomically: true, encoding: .utf8)
        if on, let saved = r?.objectForKeyedSubscript("original")?.toString(), saved != "undefined", !saved.isEmpty {
            try saved.write(to: originalStatus, atomically: true, encoding: .utf8)
        }
        if !on { try? fm.removeItem(at: originalStatus) }
    }

    private func writeClaudeScripts() throws {
        let url = "http://127.0.0.1:\(Self.port)"
        let hook = """
        #!/bin/sh
        # Mochi's Claude Code hook: hands each event to Mochi, on this Mac only. Never slows down or fails Claude.
        [ -n "$MOCHI_USAGE_CHECK$AIUSAGE_PROBE" ] && exit 0   # Mochi itself reading your usage: nothing to act out
        curl -s -m 2 -o /dev/null -H 'X-Mochi: 1' -H "X-Claude-Pid: $PPID" -H 'Content-Type: application/json' --data-binary @- \(url)/hook 2>/dev/null
        exit 0

        """
        let status = """
        #!/bin/sh
        # Mochi's Claude Code status line: tells Mochi your usage limits, then shows your own status line if you had one.
        input=$(cat)
        printf '%s' "$input" | curl -s -m 1 -o /dev/null -H 'X-Mochi: 1' -H 'Content-Type: application/json' --data-binary @- \(url)/status 2>/dev/null
        cmd=$(/usr/bin/plutil -extract command raw -o - \(Self.quote(originalStatus.path)) 2>/dev/null)
        [ -n "$cmd" ] && printf '%s' "$input" | /bin/sh -c "$cmd"
        exit 0

        """
        for (script, text) in [(hookScript, hook), (statusScript, status)] {
            try text.write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        }
    }

    private static let configureJS = #"""
    function configure(text, on, hook, status, events, original) {
      var s = text.trim() ? JSON.parse(text) : {};
      if (!s || typeof s !== 'object' || Array.isArray(s)) return { error: 'Claude Code settings must be a JSON object.' };
      // ours, and AI Usage's before it
      var mine = function (h) { return h && typeof h.command === 'string' && /Mochi\/claude-|aiusage-minis\.sh/.test(h.command); };
      var hooks = s.hooks && typeof s.hooks === 'object' ? s.hooks : {};
      Object.keys(hooks).concat(events).forEach(function (ev) {
        if (hooks[ev] && !Array.isArray(hooks[ev])) return;
        var groups = (hooks[ev] || []).map(function (g) { return Object.assign({}, g, { hooks: (g.hooks || []).filter(function (h) { return !mine(h); }) }); })
          .filter(function (g) { return g.hooks.length; });
        if (on && events.indexOf(ev) !== -1) groups.push({ hooks: [{ type: 'command', command: hook, async: true }] });
        if (groups.length) hooks[ev] = groups; else delete hooks[ev];
      });
      if (Object.keys(hooks).length) s.hooks = hooks; else delete s.hooks;
      var saved;
      if (on) {
        if (s.statusLine && !mine(s.statusLine)) saved = JSON.stringify(s.statusLine);
        var line = Object.assign({}, s.statusLine && !mine(s.statusLine) ? s.statusLine : (original ? JSON.parse(original) : {}), { type: 'command', command: status });
        s.statusLine = line;
      } else if (mine(s.statusLine)) {
        if (original) s.statusLine = JSON.parse(original); else delete s.statusLine;
      }
      return { text: JSON.stringify(s, null, 2) + '\n', original: saved };
    }
    """#
}
