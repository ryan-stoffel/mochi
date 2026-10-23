import AppKit
import MochiCore

/// One usage limit the way every surface shows it: the dropdown's bars, the notch's rings, Settings' status lines.
struct Meter: Identifiable, Equatable {
    let id: String
    let label: String
    let pct: Int
    var resets: String?
    var note: String?
}

/// Why a provider has no numbers yet, and what fixes it.
struct Blocker: Equatable {
    enum Fix { case install, logIn, retry, settings }
    let title: String
    var detail: String?
    var fix: Fix?
    var isError = false
    var symbol = "chart.bar"
}

extension Blocker.Fix {
    var title: String {
        switch self {
        case .install: return "Install"
        case .logIn: return "Sign In"
        case .retry: return "Try Again"
        case .settings: return "Open Settings"
        }
    }
}

/// What each provider's numbers mean on screen, worked out once for every surface.
@MainActor
extension UsageService {

    /// A provider's limits, its headline first.
    func meters(_ id: String) -> [Meter] {
        switch id {
        case "claude":
            let c = claude
            var out: [Meter] = []
            if let s = c.session { out.append(Meter(id: "session", label: "Session", pct: s, resets: Format.resets(c.sessionResetsAt, text: c.sessionReset))) }
            if let w = c.weekly { out.append(Meter(id: "weekly", label: "Weekly", pct: w, resets: Format.resets(c.weeklyResetsAt, text: c.weeklyReset))) }
            if let cr = c.credits, let pct = cr.pct {
                out.append(Meter(id: "credits", label: "Credits", pct: pct, resets: Format.resets(nil, text: cr.reset),
                                 note: cr.spent.map { String(format: "$%.2f of $%.2f", $0, cr.total ?? 0) }))
            }
            return out
        case "codex":
            guard status(id).state == .loggedIn else { return [] }
            return (codex?.limits ?? []).map { l in
                Meter(id: l.name, label: Self.limitName(l.name), pct: l.pctUsed, resets: Format.resets(l.resetsAt, text: l.reset))
            }
        case "cursor":
            guard status(id).state == .loggedIn, let c = cursor else { return [] }
            let rows = c.rows ?? []
            let idle = rows.allSatisfy { $0.pctUsed == 0 } ? "None used yet" : nil
            return rows.enumerated().map { i, r in
                Meter(id: r.name, label: r.name, pct: r.pctUsed, resets: Format.resets(c.resetsAt, text: c.reset),
                      note: i == 0 ? idle : nil)
            }
        case "antigravity":
            guard status(id).state == .loggedIn, let g = antigravity else { return [] }
            var out: [Meter] = []
            if let p = g.fiveHourPct { out.append(Meter(id: "fiveHour", label: "5-Hour", pct: p, resets: Format.resets(g.fiveHourResetsAt, text: g.fiveHourReset))) }
            if let p = g.weeklyPct { out.append(Meter(id: "weekly", label: "Weekly", pct: p, resets: Format.resets(g.weeklyResetsAt, text: g.weeklyReset))) }
            return out
        default:
            return []
        }
    }

    /// "5h limit" → "5-Hour", "Weekly limit" → "Weekly": Codex's own names, without the word "limit".
    nonisolated static func limitName(_ name: String) -> String {
        let base = Pattern(#"\s*limit$"#, options: .caseInsensitive).replacingFirst(in: name, with: "")
        if base.isEmpty { return "Limit" }
        if let h = Int(base.dropLast()), base.lowercased().hasSuffix("h") { return "\(h)-Hour" }
        if let d = Int(base.dropLast()), base.lowercased().hasSuffix("d") { return "\(d)-Day" }
        return base.prefix(1).uppercased() + base.dropFirst()
    }

    /// The plan, when the provider says: Codex's "Plus", Cursor's "Free".
    func plan(_ id: String) -> String? {
        switch id {
        case "codex": return codex?.plan.map { $0.prefix(1).uppercased() + $0.dropFirst() }
        case "cursor": return cursor?.plan
        default: return nil
        }
    }

    /// Nil while there are numbers to show.
    func blocker(_ id: String) -> Blocker? {
        guard meters(id).isEmpty, let p = Provider.byID(id) else { return nil }
        let status = status(id)
        if id == "claude", status.state != .disabled, status.state != .notInstalled {
            switch claude.errorType {
            case "offline": return Blocker(title: "You're offline", detail: "Waiting for a connection…", symbol: "wifi.slash")
            case "auth": return Blocker(title: "Not signed in to Claude Code", detail: status.message ?? p.hint, fix: .logIn, symbol: "person.crop.circle.badge.questionmark")
            default:
                if let e = claude.error { return Blocker(title: "Couldn't read Claude's usage", detail: e, fix: .retry, isError: true, symbol: "exclamationmark.triangle") }
            }
        }
        switch status.state {
        case .checking:
            return Blocker(title: "Checking \(p.name)…", symbol: "hourglass")
        case .notInstalled:
            return Blocker(title: "\(p.name) isn't installed", detail: status.message ?? p.installCommand ?? p.hint,
                           fix: p.installCommand != nil || p.installURL != nil ? .install : nil, symbol: "arrow.down.circle")
        case .installed:
            return Blocker(title: status.message ?? "Not signed in to \(p.name)", detail: status.message == nil ? p.hint : nil,
                           fix: p.loginCommand != nil ? .logIn : nil, symbol: "person.crop.circle.badge.questionmark")
        case .error(let message):
            return Blocker(title: "Couldn't read \(p.name)'s usage", detail: status.message ?? message, fix: .retry, isError: true,
                           symbol: "exclamationmark.triangle")
        case .disabled:
            return Blocker(title: "\(p.name) is turned off", detail: "Turn it back on in Settings.", fix: .settings, symbol: "pause.circle")
        case .loggedIn:
            return Blocker(title: isRefreshing ? "Fetching \(p.name) usage…" : "No usage yet", detail: status.message, symbol: "chart.bar")
        }
    }

    /// A problem worth saying while the last numbers still show ("You're offline"), or nil.
    func banner(_ id: String) -> String? {
        guard !meters(id).isEmpty else { return nil }
        if id == "claude", let e = claude.error { return claude.errorType == "offline" ? "Offline: showing the last numbers" : e }
        return status(id).message
    }

    /// "Updated 2 min ago", and where the numbers came from when it isn't the provider's own usage endpoint.
    func freshness(_ id: String) -> String {
        if isRefreshing { return "Checking…" }
        guard let at = lastUpdated(id) else { return "Not checked yet" }
        var s = "Updated " + Format.ago(at)
        switch source(id) {
        case UsageSource.statusLine?: s += " from Claude Code"
        case UsageSource.logs?: s += " from Codex's logs"
        case UsageSource.cli?: s += " from the CLI"
        default: break
        }
        return s
    }

    /// Three missed polls: something's stuck.
    func isStale(_ id: String) -> Bool {
        guard !isRefreshing, let at = lastUpdated(id) else { return false }
        return Date().timeIntervalSince(at) > 3 * UsageService.pollInterval
    }

    /// A provider's status in a few words, for Settings and setup: "Signed in, 14% used".
    func statusLine(_ id: String) -> (text: String, tone: Tone) {
        guard Settings.shared.isEnabled(id) else { return ("Turned off", .plain) }
        let status = status(id)
        switch status.state {
        case .checking: return ("Checking…", .plain)
        case .notInstalled: return (status.message ?? "Not installed", .plain)
        case .installed: return (status.message ?? "Installed, not signed in", .warning)
        case .loggedIn:
            if let m = status.message { return ("Signed in. \(m)", .warning) }
            return (primaryPct(id).map { "Signed in, \($0)% used" } ?? "Signed in", .good)
        case .error(let message): return (status.message ?? message, .bad)
        case .disabled: return ("Turned off", .plain)
        }
    }

    enum Tone { case plain, good, warning, bad }

    /// Does what a `Blocker` offers: install in Terminal, sign in in Terminal, ask again, or open Settings.
    func perform(_ fix: Blocker.Fix, for id: String) {
        guard let p = Provider.byID(id) else { return }
        switch fix {
        case .install:
            if let command = p.installCommand { TerminalLauncher.run(command) }
            else if let url = p.installURL.flatMap(URL.init(string:)) { NSWorkspace.shared.open(url) }
        case .logIn:
            if let command = p.loginCommand { TerminalLauncher.run(command) }
        case .retry:
            Task { await refreshProvider(id) }
        case .settings:
            NotificationCenter.default.post(name: .openSettingsRequested, object: nil)
        }
    }
}
