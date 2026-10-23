import Combine
import Foundation

/// The single owner of every fetch: the menu bar, the notch and the pet all observe this one instance.
///
/// Each provider refreshes on its own, from the best source that answers (`UsageFetcher`), and shows its numbers
/// the moment they land: one slow CLI never holds up the others. Numbers that stop updating aren't blanked; they
/// stay, with what went wrong as the status message, and they're kept across restarts. A window whose reset time
/// has passed shows as started over.
@MainActor
public final class UsageService: ObservableObject {

    @Published public private(set) var claude: ClaudeUsage = .empty
    @Published public private(set) var antigravity: GeminiUsage?
    @Published public private(set) var codex: CodexUsage?
    @Published public private(set) var cursor: CursorUsage?
    @Published public private(set) var providers: [String: ProviderStatus] = [:]
    @Published public private(set) var isRefreshing = false

    /// When the last refresh cycle finished, whichever providers it had news for.
    @Published public private(set) var lastRefreshed: Date?

    /// Bumped whenever settings change in a way the shells should redraw for.
    @Published public private(set) var settingsRevision = 0

    /// Providers known to be signed out (or, for agy, not set up). Launching a signed-out CLI isn't harmless: it
    /// opens a sign-in tab in your browser, every poll. So the poll leaves their CLI alone; a manual refresh (the
    /// Refresh button, Retry, the wizard's Recheck, switching it back on) looks again.
    private var signedOut: Set<String> = []
    /// When each provider's CLI screen was last read. It takes seconds and a whole CLI, so the poll reads it at most
    /// every `cliInterval`; the APIs are cheap and go every poll.
    private var cliAt: [String: Date] = [:]
    /// Rate-limited providers, and when to ask again.
    private var backoff: [String: Date] = [:]
    /// When each provider was last asked, so each keeps to its own pace (`pollEvery`).
    private var checkedAt: [String: Date] = [:]
    private var inFlight: Set<String> = []

    private var timer: Timer?
    private var clock: Timer?

    public static let pollInterval: TimeInterval = 2 * 60

    /// How often the poll asks each provider. Claude's usage endpoint rate-limits a sign-in after a few calls, so
    /// it's asked least; while you use Claude Code its status line keeps the numbers fresh anyway.
    static func pollEvery(_ id: String) -> TimeInterval { id == "claude" ? 5 * 60 : pollInterval }
    static let cliInterval: TimeInterval = 15 * 60
    static let backoffInterval: TimeInterval = 10 * 60

    public init() {
        loadCache()
        Task { await refresh(manual: false) }
        timer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh(manual: false) }
        }
        clock = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.expireResets() }
        }
    }

    deinit {
        timer?.invalidate()
        clock?.invalidate()
    }

    // MARK: - Refresh

    /// Looks at every enabled provider, all at once. `manual` is someone asking (they may have just signed in, so
    /// every source is tried); otherwise it's the poll, which respects `signedOut`, `cliInterval` and `backoff`.
    public func refresh(manual: Bool = true) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer {
            isRefreshing = false
            lastRefreshed = Date()
        }
        applyDetection(await Self.run { Self.detect() })
        let now = Date()
        await withTaskGroup(of: Void.self) { group in
            for id in Provider.ids where Settings.shared.isEnabled(id) && providers[id]?.state != .notInstalled {
                if !manual, let until = backoff[id], until > now { continue }
                if !manual, let at = checkedAt[id], now.timeIntervalSince(at) < Self.pollEvery(id) - 5 { continue }
                let cliDue = cliAt[id].map { now.timeIntervalSince($0) > Self.cliInterval } ?? true
                let allowCLI = manual || (!signedOut.contains(id) && cliDue)
                group.addTask { await self.refreshOne(id, allowCLI: allowCLI) }
            }
        }
    }

    /// Refreshes exactly one provider, every source allowed: when it's switched back on in Settings, or retried.
    public func refreshProvider(_ id: String) async {
        guard Settings.shared.isEnabled(id) else { return }
        applyDetection(await Self.run { Self.detect() })
        await refreshOne(id, allowCLI: true)
        lastRefreshed = Date()
    }

    private func refreshOne(_ id: String, allowCLI: Bool) async {
        guard !inFlight.contains(id), providers[id]?.state != .notInstalled else { return }
        inFlight.insert(id)
        checkedAt[id] = Date()
        defer { inFlight.remove(id) }
        switch id {
        case "claude":
            let r = await Self.run { UsageFetcher.claude(allowCLI: allowCLI) }
            noteCLI(id, allowCLI, source: r.source)
            applyClaude(r)
        case "codex":
            let r = await Self.run { UsageFetcher.codex(allowCLI: allowCLI) }
            noteCLI(id, allowCLI, source: r.source)
            apply(id, r, hasData: !(codex?.limits?.isEmpty ?? true)) { u in
                codex = u
                let pct = { (needle: String) in u.limits?.first { $0.name.lowercased().contains(needle) }?.pctUsed }
                HistoryStore.shared.record(provider: id, session: pct("h limit"), weekly: pct("weekly"))
            }
        case "cursor":
            let r = await Self.run { UsageFetcher.cursor(allowCLI: allowCLI) }
            noteCLI(id, allowCLI, source: r.source)
            apply(id, r, hasData: !(cursor?.rows?.isEmpty ?? true)) { u in
                cursor = u
                HistoryStore.shared.record(provider: id, session: u.primaryPct, weekly: nil)
            }
        case "antigravity":
            let r = await Self.run { UsageFetcher.antigravity(allowCLI: allowCLI) }
            noteCLI(id, allowCLI, source: r.source)
            apply(id, r, hasData: antigravity?.fiveHourPct != nil || antigravity?.weeklyPct != nil) { u in
                antigravity = u
                HistoryStore.shared.record(provider: id, session: u.fiveHourPct, weekly: u.weeklyPct)
            }
        default:
            break
        }
        expireResets()
        saveCache()
    }

    /// Starts the CLI's cooldown when this round may have read its screen (anything but an API or log answer).
    private func noteCLI(_ id: String, _ allowCLI: Bool, source: String?) {
        if allowCLI && source != UsageSource.api && source != UsageSource.logs { cliAt[id] = Date() }
    }

    // MARK: - Applying results

    private func applyClaude(_ r: UsageFetcher.Fetched<ClaudeUsage>) {
        let hasData = claude.session != nil || claude.weekly != nil
        if case .data(let u) = r {
            claude = u
            HistoryStore.shared.record(provider: "claude", session: u.session, weekly: u.weekly)
        } else {
            // Keep the numbers; say what went wrong alongside them.
            switch r {
            case .offline: claude.error = "You're offline."; claude.errorType = "offline"
            case .signedOut(let m): claude.error = m ?? "Not logged in. Run claude in a terminal to log in."; claude.errorType = "auth"
            // being told to slow down isn't a problem worth a banner while there are numbers: they just age
            case .rateLimited: if !hasData { claude.error = "Asked too often; trying again in a few minutes."; claude.errorType = nil }
            case .failed(let m): claude.error = m; claude.errorType = nil
            case .data: break
            }
        }
        settle("claude", r, hasData: hasData)
    }

    private func apply<T>(_ id: String, _ r: UsageFetcher.Fetched<T>, hasData: Bool, store: (T) -> Void) {
        if case .data(let u) = r { store(u) }
        settle(id, r, hasData: hasData)
    }

    /// What a result means for a provider's status. Numbers already showing stay `.loggedIn`, with the problem as
    /// the message (a "last known" banner) rather than being swapped for an error screen.
    private func settle<T>(_ id: String, _ r: UsageFetcher.Fetched<T>, hasData: Bool) {
        func keep(_ message: String) -> ProviderStatus {
            hasData ? ProviderStatus(state: .loggedIn, message: message) : ProviderStatus(state: .error(message), message: message)
        }
        switch r {
        case .data:
            providers[id] = ProviderStatus(state: .loggedIn)
            signedOut.remove(id)
            backoff[id] = nil
        case .signedOut(let message):
            providers[id] = ProviderStatus(state: .installed, message: message)
            signedOut.insert(id)
        case .offline:
            providers[id] = keep("You're offline; showing the last numbers.")
        case .rateLimited:
            backoff[id] = Date().addingTimeInterval(Self.backoffInterval)
            providers[id] = hasData ? ProviderStatus(state: .loggedIn) : keep("Asked too often; trying again in a few minutes.")
        case .failed(let message):
            providers[id] = keep(message)
        }
    }

    // MARK: - Claude Code's status line

    /// Claude Code's status line, as the pet's hook server receives it: `rate_limits` with `five_hour` and
    /// `seven_day`, each `used_percentage` and `resets_at`. The freshest source there is while you use Claude Code,
    /// and free. Each update is the whole picture: a window it leaves out has reset.
    public func applyClaudeStatusLine(_ rateLimits: [String: Any]) {
        guard Settings.shared.isEnabled("claude"), let p = ClaudeAPI.parseStatusLine(rateLimits) else { return }
        let now = Date()
        var u = claude
        u.session = p.session?.0 ?? 0
        u.sessionResetsAt = p.session?.1
        u.sessionReset = p.session?.1.map { UsageDates.resetText($0, now: now) }
        u.weekly = p.week?.0 ?? 0
        u.weeklyResetsAt = p.week?.1
        u.weeklyReset = p.week?.1.map { UsageDates.resetText($0, now: now) }
        // It redraws constantly; only take news, or a heartbeat once a minute.
        if u.session == claude.session, u.weekly == claude.weekly, u.sessionResetsAt == claude.sessionResetsAt,
           claude.source == UsageSource.statusLine, claude.error == nil,
           let at = claude.lastUpdated, now.timeIntervalSince(at) < 60 { return }
        u.source = UsageSource.statusLine
        u.lastUpdated = now
        u.error = nil
        u.errorType = nil
        applyClaude(.data(u))
        saveCache()
    }

    // MARK: - Resets

    /// A window whose reset time has passed has started over: show it at 0 until the next reading says otherwise.
    func expireResets(now: Date = Date()) {
        let c = UsageExpiry.claude(claude, now: now)
        if c != claude { claude = c }
        if let x = codex.map({ UsageExpiry.codex($0, now: now) }), x != codex { codex = x }
        if let x = cursor.map({ UsageExpiry.cursor($0, now: now) }), x != cursor { cursor = x }
        if let x = antigravity.map({ UsageExpiry.antigravity($0, now: now) }), x != antigravity { antigravity = x }
    }

    // MARK: - Detection

    /// Whether each provider is on this Mac at all: its CLI, or for Cursor its editor, or a sign-in a source can use.
    nonisolated private static func detect() -> [String: ProviderStatus] {
        var result: [String: ProviderStatus] = [:]
        for p in Provider.all {
            guard Settings.shared.isEnabled(p.id) else {
                result[p.id] = ProviderStatus(state: .disabled)
                continue
            }
            result[p.id] = isPresent(p.id) ? ProviderStatus(state: .checking) : ProviderStatus(state: .notInstalled, message: p.hint)
        }
        return result
    }

    nonisolated static func isPresent(_ id: String) -> Bool {
        switch id {
        case "claude": return CLILocator.isInstalled("claude") || Keychain.exists(service: "Claude Code-credentials")
        case "codex": return CLILocator.isInstalled("codex") || CodexAPI.credentials() != nil
        case "cursor": return CLILocator.isInstalled("cursor-agent") || FileManager.default.fileExists(atPath: CursorAPI.editorState.path)
        case "antigravity": return CLILocator.isInstalled("agy")
        default: return false
        }
    }

    /// Detection settles "not installed" and "off"; for one that's there, it only fills in "checking" until its
    /// first answer, and never covers up what a fetch already said.
    private func applyDetection(_ detected: [String: ProviderStatus]) {
        for (id, d) in detected {
            switch d.state {
            case .disabled, .notInstalled:
                providers[id] = d
            default:
                switch providers[id]?.state {
                case nil, .notInstalled, .disabled: providers[id] = d
                default: break
                }
            }
        }
    }

    // MARK: - Off-main plumbing

    /// Every source blocks (a request, a keychain read, a CLI run), so none of it runs on the main actor.
    nonisolated private static func run<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async { continuation.resume(returning: work()) }
        }
    }

    // MARK: - Last known numbers, across restarts

    private struct Cache: Codable {
        var claude: ClaudeUsage?
        var antigravity: GeminiUsage?
        var codex: CodexUsage?
        var cursor: CursorUsage?
    }

    private static var cacheURL: URL { Settings.supportDirectory.appendingPathComponent("usage.json") }

    private func loadCache() {
        guard let data = try? Data(contentsOf: Self.cacheURL),
              let c = try? JSONDecoder().decode(Cache.self, from: data) else { return }
        if let x = c.claude { claude = x }
        antigravity = c.antigravity
        codex = c.codex
        cursor = c.cursor
        // Shown straight away, as last known, until each provider's first refresh lands.
        for (id, has) in [("claude", c.claude?.session != nil || c.claude?.weekly != nil),
                          ("antigravity", c.antigravity?.fiveHourPct != nil || c.antigravity?.weeklyPct != nil),
                          ("codex", !(c.codex?.limits?.isEmpty ?? true)), ("cursor", !(c.cursor?.rows?.isEmpty ?? true))]
        where has && Settings.shared.isEnabled(id) {
            providers[id] = ProviderStatus(state: .loggedIn)
        }
        expireResets()
    }

    private func saveCache() {
        let c = Cache(claude: claude, antigravity: antigravity, codex: codex, cursor: cursor)
        guard let data = try? JSONEncoder().encode(c) else { return }
        try? data.write(to: Self.cacheURL, options: .atomic)
    }

    // MARK: - Settings changes

    /// Toggling a provider takes effect immediately rather than at the next poll.
    public func setProviderEnabled(_ id: String, _ enabled: Bool) async {
        Settings.shared.setEnabled(id, enabled)
        settingsRevision += 1

        if enabled {
            await refreshProvider(id)
        } else {
            providers[id] = ProviderStatus(state: .disabled)
            switch id {
            case "antigravity": antigravity = nil
            case "codex": codex = nil
            case "cursor": cursor = nil
            case "claude": claude = .empty
            default: break
            }
            saveCache()
        }
    }

    // MARK: - Convenience for the shells

    public func status(_ id: String) -> ProviderStatus {
        providers[id] ?? ProviderStatus(state: .checking)
    }

    /// The one figure that best represents "quota right now" for a provider, or `nil` when there isn't one yet.
    public func primaryPct(_ id: String) -> Int? {
        switch id {
        case "claude": return claude.session ?? claude.weekly
        case "antigravity": return status(id).state == .loggedIn ? antigravity?.primaryPct : nil
        case "codex": return status(id).state == .loggedIn ? codex?.primaryPct : nil
        case "cursor": return status(id).state == .loggedIn ? cursor?.primaryPct : nil
        default: return nil
        }
    }

    public func lastUpdated(_ id: String) -> Date? {
        switch id {
        case "claude": return claude.lastUpdated
        case "antigravity": return antigravity?.lastUpdated
        case "codex": return codex?.lastUpdated
        case "cursor": return cursor?.lastUpdated
        default: return nil
        }
    }

    /// Where a provider's numbers came from (`UsageSource`), for showing or debugging.
    public func source(_ id: String) -> String? {
        switch id {
        case "claude": return claude.source
        case "antigravity": return antigravity?.source
        case "codex": return codex?.source
        case "cursor": return cursor?.source
        default: return nil
        }
    }
}

extension UsageFetcher.Fetched {
    /// The source of the numbers, when there are some.
    var source: String? {
        guard case .data(let u) = self else { return nil }
        switch u {
        case let x as ClaudeUsage: return x.source
        case let x as CodexUsage: return x.source
        case let x as CursorUsage: return x.source
        case let x as GeminiUsage: return x.source
        default: return nil
        }
    }
}

/// Windows whose reset time has passed, started over. Pure, so the rule is tested on its own.
enum UsageExpiry {
    static func claude(_ u: ClaudeUsage, now: Date) -> ClaudeUsage {
        var c = u
        if let r = c.sessionResetsAt, r <= now { c.session = 0; c.sessionResetsAt = nil; c.sessionReset = nil }
        if let r = c.weeklyResetsAt, r <= now { c.weekly = 0; c.weeklyResetsAt = nil; c.weeklyReset = nil }
        return c
    }

    static func codex(_ u: CodexUsage, now: Date) -> CodexUsage {
        var x = u
        x.limits = u.limits?.map { l in
            guard let r = l.resetsAt, r <= now else { return l }
            return CodexLimit(name: l.name, pctUsed: 0)
        }
        return x
    }

    static func cursor(_ u: CursorUsage, now: Date) -> CursorUsage {
        guard let r = u.resetsAt, r <= now else { return u }
        var x = u
        x.rows = u.rows?.map { CursorUsageRow(name: $0.name, pctUsed: 0) }
        x.resetsAt = nil
        x.reset = nil
        return x
    }

    static func antigravity(_ u: GeminiUsage, now: Date) -> GeminiUsage {
        var g = u
        if let r = g.fiveHourResetsAt, r <= now { g.fiveHourPct = 0; g.fiveHourResetsAt = nil; g.fiveHourReset = nil }
        if let r = g.weeklyResetsAt, r <= now { g.weeklyPct = 0; g.weeklyResetsAt = nil; g.weeklyReset = nil }
        return g
    }
}
