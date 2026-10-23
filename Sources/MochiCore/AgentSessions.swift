import Foundation

/// Why a session is asking for you. Each has its own sound.
public enum AlertKind: String, Codable, Sendable, CaseIterable {
    case done, needsInput, failed

    public var title: String {
        switch self {
        case .done: return "Finished"
        case .needsInput: return "Needs input"
        case .failed: return "Failed"
        }
    }
}

/// One running session of one provider's CLI: a terminal tab, an editor panel, a desktop app chat.
public struct AgentSession: Identifiable, Equatable, Sendable {
    public var id: String { Self.key(provider, sessionID) }
    public let provider: String
    public let sessionID: String
    public var cwd = ""
    /// The process that ran the hook, for finding the app the session lives in.
    public var pid: Int32 = 0

    public var busy = false
    public var busySince: Date?
    /// What it's doing right now, and the tool and file/command it's on.
    public var activity: AgentActivity?
    public var toolName = ""
    public var detail = ""
    /// Tools started and not finished yet.
    public var running = 0
    /// A tool that has finished still shows for a moment, so quick calls don't flicker back to "thinking".
    public var toolUntil = Date.distantPast
    /// Waiting on you, and for what.
    public var need: AgentEvent.Need?
    public var needTool = ""
    public var needAt = Date.distantPast
    public var errorUntil = Date.distantPast
    public var errorDetail = ""
    public var doneUntil = Date.distantPast
    public var greetUntil = Date.distantPast
    public var compactAt: Date?
    /// Helper agents working, by id → when one was last heard from; and helpers started by a tool call.
    public var agents: [String: Date] = [:]
    public var spawns = 0
    /// To-do list progress: [done, total].
    public var todos: [Int]?
    /// How full its context window is, %, from Claude Code's status line.
    public var contextPct: Double?

    /// Held until you respond in the session or acknowledge it (click Mochi, the session, or the notification).
    public var alert: AlertKind?
    public var alertDetail = ""
    public var alertAt = Date.distantPast
    public let startedAt: Date
    public var lastEvent: Date

    public init(provider: String, sessionID: String, now: Date) {
        self.provider = provider
        self.sessionID = sessionID
        self.startedAt = now
        self.lastEvent = now
    }

    public static func key(_ provider: String, _ sessionID: String) -> String { provider + ":" + sessionID }

    public var helpers: Int { max(agents.count, spawns) }

    /// The folder's name. Folders named by an ID, like the per-chat worktrees some apps make, are skipped for the
    /// project they belong to: ".../worktrees/mochi-54f25aee/01a1616b-ad6d-..." → "mochi".
    public var project: String {
        guard !cwd.isEmpty else { return "" }
        var parts = (cwd as NSString).pathComponents
        let isID = { (s: String) in s.range(of: #"^[0-9a-f]{8}-[0-9a-f]{4}-"#, options: .regularExpression) != nil }
        guard parts.count > 2, let last = parts.last, isID(last) else { return parts.last ?? cwd }
        while parts.count > 2, let l = parts.last, isID(l) { parts.removeLast() }
        return parts.last!.replacingOccurrences(of: #"-[0-9a-f]{6,}$"#, with: "", options: .regularExpression)
    }

    /// Working on a tool right now, or just finished one.
    func onTool(_ now: Date) -> Bool { activity != nil && (running > 0 || now < toolUntil) }

    /// The state Mochi acts out for this session, most urgent first. Empty when there's nothing to show.
    public func state(_ now: Date) -> String {
        if need != nil || alert == .needsInput { return "waiting" }
        if now < errorUntil || alert == .failed { return "error" }
        if let c = compactAt, now.timeIntervalSince(c) < 90 { return "compacting" }
        if busy && helpers > 0 { return "agents" }
        if onTool(now), let a = activity { return a.pose }
        if busy { return (contextPct ?? 0) >= 85 ? "contextFull" : "thinking" }
        if now < doneUntil || alert == .done { return "done" }
        if now < greetUntil { return "hello" }
        return ""
    }

    /// One line on what it's up to, for its row in a panel.
    public func describe(_ now: Date) -> String {
        if need == .question { return "has a question for you" }
        if need != nil || alert == .needsInput { return needTool.isEmpty ? "needs your ok" : "needs your ok to use \(needTool)" }
        if now < errorUntil || alert == .failed { return errorDetail.isEmpty ? "hit an error" : "hit an error: \(errorDetail)" }
        if busy && helpers > 0 { return helpers == 1 ? "running a helper" : "running \(helpers) helpers" }
        if onTool(now), let a = activity {
            let verb: [AgentActivity: String] = [.reading: "reading", .editing: toolName == "Write" ? "writing" : "editing",
                                                 .searching: "searching", .browsing: "searching the web", .testing: "running tests",
                                                 .committing: "committing", .server: "starting a server", .planning: "updating the plan",
                                                 .compacting: "tidying up its memory"]
            if let v = verb[a] { return detail.isEmpty || [.testing, .committing, .planning].contains(a) ? v : "\(v) \(detail)" }
            return detail.isEmpty ? "working" : detail
        }
        if busy { return "thinking" }
        if alert == .done || now < doneUntil { return "done, your turn" }
        return "idle"
    }
}

/// Every live session, and the rules for how hook events move them along.
///
/// Pure state (no timers, sounds or windows), so what Mochi shows and the alert rules ("stays until you respond or
/// look at it") are testable on their own.
public struct AgentSessionStore: Sendable {
    public private(set) var sessions: [String: AgentSession] = [:]

    public init() {}

    public enum Change: Equatable, Sendable {
        case none
        case updated
        case spawned
        case removed
        /// An alert went up: play it.
        case alerted(AlertKind)
        /// You responded in the session, so its alert came down.
        case answered
    }

    @discardableResult
    public mutating func apply(_ e: AgentEvent, pid: Int32 = 0, now: Date = Date()) -> Change {
        let key = AgentSession.key(e.provider, e.sessionID)
        if e.kind == .sessionEnd {
            return sessions.removeValue(forKey: key) == nil ? .none : .removed
        }
        let isNew = sessions[key] == nil
        var s = sessions[key] ?? AgentSession(provider: e.provider, sessionID: e.sessionID, now: now)
        s.lastEvent = now
        if !e.cwd.isEmpty { s.cwd = e.cwd }
        if s.pid == 0, pid > 0 { s.pid = pid }

        // A helper agent's events only say it's still at it.
        switch e.kind {
        case .subagentActivity, .subagentStart:
            if !e.agentID.isEmpty { s.agents[e.agentID] = now }
            sessions[key] = s
            return isNew ? .spawned : .updated
        case .subagentStop:
            if !e.agentID.isEmpty { s.agents[e.agentID] = nil }
            s.spawns = max(0, s.spawns - 1)
            sessions[key] = s
            return isNew ? .spawned : .updated
        default:
            break
        }

        let hadAlert = s.alert != nil
        var change: Change = isNew ? .spawned : .updated
        if e.kind != .needsInput { s.need = nil }
        if e.kind != .compact { s.compactAt = nil }
        let spawning = ["Task", "Agent"].contains(e.toolName) || e.activity == .delegating

        switch e.kind {
        case .sessionStart:
            s.greetUntil = e.greet ? now.addingTimeInterval(5) : .distantPast
        case .prompt, .thought:
            if !s.busy { s.busySince = now }
            s.busy = true
            s.alert = nil
            if e.kind == .prompt { s.doneUntil = .distantPast; s.errorUntil = .distantPast }
        case .toolStart:
            if !s.busy { s.busySince = now }
            s.busy = true
            s.alert = nil
            s.running += 1
            s.activity = e.activity ?? .tool
            s.toolName = e.toolName
            s.detail = e.detail
            s.toolUntil = .distantFuture
            if spawning { s.spawns += 1 }
            if let t = e.todos { s.todos = t }
        case .toolEnd:
            s.busy = true
            s.alert = nil
            s.running = max(0, s.running - 1)
            if let a = e.activity { s.activity = a; s.detail = e.detail; s.toolName = e.toolName }
            s.toolUntil = now.addingTimeInterval(2.5)
            if spawning { s.spawns = max(0, s.spawns - 1) }
        case .toolFailed:
            s.alert = nil
            s.running = max(0, s.running - 1)
            s.toolUntil = now.addingTimeInterval(2.5)
            s.errorUntil = now.addingTimeInterval(4)
            s.errorDetail = e.detail
            if spawning { s.spawns = max(0, s.spawns - 1) }
        case .compact:
            s.compactAt = now
        case .compactEnd:
            break
        case .needsInput:
            s.need = e.need
            s.needTool = e.toolName
            s.needAt = now
            s.alert = .needsInput
            s.alertDetail = e.need == .question ? "has a question" : e.toolName
            s.alertAt = now
            change = .alerted(.needsInput)
        case .done, .failed:
            Self.stop(&s)
            let kind: AlertKind = e.kind == .done ? .done : .failed
            if kind == .done { s.doneUntil = now.addingTimeInterval(6) } else { s.errorUntil = now.addingTimeInterval(6); s.errorDetail = "" }
            s.alert = kind
            s.alertDetail = ""
            s.alertAt = now
            change = .alerted(kind)
        case .interrupted:
            Self.stop(&s)
            s.alert = nil
        case .sessionEnd, .subagentActivity, .subagentStart, .subagentStop:
            break
        }

        if hadAlert && s.alert == nil, case .updated = change { change = .answered }
        sessions[key] = s
        return change
    }

    private static func stop(_ s: inout AgentSession) {
        s.busy = false
        s.busySince = nil
        s.running = 0
        s.spawns = 0
        s.agents = [:]
        s.toolUntil = .distantPast
        s.need = nil
    }

    /// What Claude Code's status line says about a session: how full its context window is.
    public mutating func applyStatus(provider: String, sessionID: String, contextPct: Double?) {
        guard var s = sessions[AgentSession.key(provider, sessionID)] else { return }
        s.contextPct = contextPct
        sessions[s.id] = s
    }

    /// You looked at it: clicked Mochi, the session, or the notification.
    @discardableResult
    public mutating func acknowledge(_ id: String) -> Bool {
        guard sessions[id]?.alert != nil else { return false }
        sessions[id]?.alert = nil
        sessions[id]?.need = nil
        return true
    }

    public mutating func remove(_ id: String) {
        sessions[id] = nil
    }

    /// Lets go of sessions that went quiet (a closed terminal never says goodbye), and of work that never reported
    /// finishing. A session holding an alert stays: that's the point of it.
    /// - Returns: the ids that were removed.
    @discardableResult
    public mutating func prune(now: Date = Date(), idleTimeout: TimeInterval) -> [String] {
        var removed: [String] = []
        for (id, var s) in sessions {
            let quiet = now.timeIntervalSince(s.lastEvent)
            if s.alert == nil, quiet > 3 * 3600 || (!s.busy && quiet > idleTimeout) {
                sessions[id] = nil
                removed.append(id)
                continue
            }
            if s.busy, quiet > (s.running > 0 ? 30 * 60 : 10 * 60) { Self.stop(&s) }
            if s.need != nil, now.timeIntervalSince(s.needAt) > 30 * 60 { s.need = nil }
            s.agents = s.agents.filter { now.timeIntervalSince($0.value) < 3 * 60 }
            sessions[id] = s
        }
        return removed
    }

    /// One provider's sessions, most recently active first.
    public func sessions(of provider: String) -> [AgentSession] {
        sessions.values.filter { $0.provider == provider }.sorted { $0.lastEvent > $1.lastEvent }
    }

    /// The session Mochi shows for a provider, and the state it acts out: whatever needs you most (waiting on you,
    /// then an error, then work in progress), else something that just finished or started.
    public func summary(for provider: String, now: Date = Date()) -> (state: String, session: AgentSession?) {
        let mine = sessions(of: provider)
        let order = ["waiting", "error", "compacting", "agents"]
        let states = mine.map { ($0, $0.state(now)) }
        if let s = states.filter({ $0.1 == "waiting" }).max(by: { $0.0.needAt < $1.0.needAt }) { return ("waiting", s.0) }
        for st in order.dropFirst() { if let s = states.first(where: { $0.1 == st }) { return (st, s.0) } }
        let late = ["done", "hello", ""]
        if let s = states.first(where: { !late.contains($0.1) }) { return (s.1, s.0) }   // working: a tool, or thinking
        if let s = states.filter({ $0.1 == "done" }).max(by: { $0.0.alertAt < $1.0.alertAt }) { return ("done", s.0) }
        if let s = states.first(where: { $0.1 == "hello" }) { return ("hello", s.0) }
        return ("", nil)
    }

    /// The session Mochi shows for a provider (see `summary`).
    public func shown(for provider: String, now: Date = Date()) -> AgentSession? {
        summary(for: provider, now: now).session ?? sessions(of: provider).first
    }

    /// What Mochi's page gets about one provider's sessions: enough to act it out and say a word about it.
    public func payload(for provider: String, name: String, now: Date = Date()) -> [String: Any] {
        let mine = sessions(of: provider)
        let (state, s) = summary(for: provider, now: now)
        var d: [String: Any] = ["state": state, "agent": name, "sessions": mine.count, "busy": mine.filter { $0.busy }.count]
        if let s {
            d["id"] = s.id
            d["project"] = s.project
            d["tool"] = s.toolName
            d["detail"] = state == "error" ? s.errorDetail : s.detail
            d["need"] = s.need?.rawValue ?? (s.alert == .needsInput ? "permission" : "")
            d["needTool"] = s.needTool
            d["helpers"] = s.helpers
            d["alert"] = s.alert?.rawValue ?? ""
            if let t = s.todos { d["todo"] = t }
            if let c = s.contextPct { d["ctx"] = c }
        }
        return d
    }

    public var alerting: [AgentSession] {
        sessions.values.filter { $0.alert != nil }.sorted { $0.alertAt < $1.alertAt }
    }

    /// Stable order for listing: by provider, then by age.
    public var ordered: [AgentSession] {
        let order = Provider.ids
        return sessions.values.sorted {
            let a = order.firstIndex(of: $0.provider) ?? 99, b = order.firstIndex(of: $1.provider) ?? 99
            return a != b ? a < b : $0.startedAt < $1.startedAt
        }
    }
}
