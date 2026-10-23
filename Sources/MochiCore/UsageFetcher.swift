import Foundation

/// Gets each provider's usage from the best source that answers (see the chains under "Each provider's sources").
///
/// The last resort is the provider's CLI, run in a hidden terminal by the `ptydrive` helper with its screen parsed.
/// Its timeout ladder matters: the helper's own cap must expire *before* the watchdog here kills it, so the
/// helper's graceful path, which prints whatever it captured, gets to run instead of being killed mid-capture.
public enum UsageFetcher {

    /// Watchdog per provider, in seconds. Each sits above the corresponding
    /// `PTYSession.DriveSpec.totalTimeout` with room to spare.
    private static func watchdog(for provider: String) -> TimeInterval {
        switch provider {
        case "claude": return 23        // spec cap 20
        case "antigravity": return 62   // spec cap 55
        case "codex": return 28         // spec cap 20
        case "cursor": return 32        // spec cap 25
        default: return 30
        }
    }

    /// Where the helper binary lives. In a packaged `.app` it sits next to the
    /// executable in `Contents/MacOS`; under `swift run` it's beside the app
    /// binary in the build directory. Both are just "next to me", which keeps
    /// this a one-liner in either case — with a couple of explicit fallbacks
    /// for a build laid out differently.
    public static var helperURL: URL? {
        let fm = FileManager.default
        var candidates: [URL] = []

        let exe = Bundle.main.executableURL?.resolvingSymlinksInPath()
        if let dir = exe?.deletingLastPathComponent() {
            candidates.append(dir.appendingPathComponent("ptydrive"))
        }
        if let resources = Bundle.main.resourceURL {
            candidates.append(resources.appendingPathComponent("ptydrive"))
        }
        // `swift test` and other hosts where Bundle.main isn't the app.
        let cwd = URL(fileURLWithPath: fm.currentDirectoryPath)
        candidates.append(cwd.appendingPathComponent(".build/debug/ptydrive"))
        candidates.append(cwd.appendingPathComponent(".build/release/ptydrive"))

        return candidates.first { fm.isExecutableFile(atPath: $0.path) }
    }

    public enum FetchError: Error, CustomStringConvertible {
        case helperMissing
        case binaryMissing(String)
        case launchFailed(String)
        case timedOut

        public var description: String {
            switch self {
            case .helperMissing:
                return "The ptydrive helper is missing from this build."
            case .binaryMissing(let bin):
                return "Couldn't find \(bin) on your PATH."
            case .launchFailed(let msg):
                return "Process error: \(msg)"
            case .timedOut:
                return "Timed out."
            }
        }
    }

    /// Drives `provider` and returns the raw captured screen.
    ///
    /// Blocking by design — callers run it off the main actor. The watchdog
    /// terminates the helper rather than abandoning it, so a slow CLI can't
    /// leave a PTY subtree running after we've stopped caring about it.
    public static func capture(provider: String, command: String? = nil) throws -> String {
        guard let helper = helperURL else { throw FetchError.helperMissing }
        guard let providerMeta = Provider.byID(provider) else {
            throw FetchError.binaryMissing(provider)
        }
        guard let binary = CLILocator.find(providerMeta.binary) else {
            throw FetchError.binaryMissing(providerMeta.binary)
        }

        let process = Process()
        process.executableURL = helper
        process.arguments = [provider, binary] + (command.map { [$0] } ?? [])
        process.environment = CLILocator.augmentedEnvironment()

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
        } catch {
            throw FetchError.launchFailed(error.localizedDescription)
        }

        // Read on a background queue so a helper that fills the 64KB pipe
        // buffer can't deadlock against our own wait.
        var captured = Data()
        let readQueue = DispatchQueue(label: "mochi.fetch.read")
        let readDone = DispatchSemaphore(value: 0)
        readQueue.async {
            captured = outPipe.fileHandleForReading.readDataToEndOfFile()
            readDone.signal()
        }

        let deadline = Date().addingTimeInterval(watchdog(for: provider))
        while process.isRunning && Date() < deadline {
            usleep(50_000)
        }
        if process.isRunning {
            // SIGTERM, not SIGKILL: the helper catches it and still prints its
            // buffer, and its own cleanup reaps the CLI's process group.
            process.terminate()
            // Give it a moment to flush before we give up on the pipe.
            let hardDeadline = Date().addingTimeInterval(3)
            while process.isRunning && Date() < hardDeadline { usleep(50_000) }
        }

        _ = readDone.wait(timeout: .now() + 5)
        errPipe.fileHandleForReading.closeFile()

        return String(decoding: captured, as: UTF8.self)
    }

    // MARK: - Each provider's sources, best first

    /// What a provider's sources came to, together.
    public enum Fetched<T: Sendable>: Sendable {
        /// Fresh numbers (or the newest ones there are: Codex's logs date from its last turn).
        case data(T)
        /// There, but not signed in; the message says what to do about it.
        case signedOut(String?)
        case offline
        case rateLimited
        /// Signed in, but nothing answered this time.
        case failed(String)
    }

    /// The order every provider's sources go in: its API; then its local record, if it has one; then, when
    /// `allowCLI`, its CLI's own screen. Offline or rate limited stops before the CLI. Signed out stops right
    /// away unless `cliWhenSignedOut`: launching a signed-out codex, cursor-agent or agy opens a sign-in tab.
    static func chain<T>(api: () -> SourceResult<T>, local: (() -> SourceResult<T>)? = nil,
                         cli: () -> Fetched<T>, allowCLI: Bool, cliWhenSignedOut: Bool = false) -> Fetched<T> {
        let a = api()
        if case .ok(let v) = a { return .data(v) }
        if case .signedOut = a, !cliWhenSignedOut { return .signedOut(nil) }
        if let local, case .ok(let v) = local() { return .data(v) }
        if case .offline = a { return .offline }
        // Rate limited: the CLI's own screen asks the same service (Claude's /usage does), so leave it be too.
        if case .rateLimited = a { return .rateLimited }
        return allowCLI ? cli() : fallback(a)
    }

    /// Claude: its usage endpoint, then Claude Code's /usage screen. The status line, the third source, arrives on
    /// its own through `UsageService.applyClaudeStatusLine`. A signed-out Claude Code only shows its welcome screen,
    /// so it's still asked: that's how it says it's signed out.
    public static func claude(allowCLI: Bool) -> Fetched<ClaudeUsage> {
        chain(api: { ClaudeAPI.fetch() }, cli: {
            guard CLILocator.isInstalled("claude") else { return .signedOut(nil) }
            let u = cliClaude()
            if u.errorType == "auth" { return .signedOut("Run claude in a terminal to sign in.") }
            if let error = u.error { return u.errorType == "offline" ? .offline : .failed(error) }
            return .data(u)
        }, allowCLI: allowCLI, cliWhenSignedOut: true)
    }

    /// Codex: ChatGPT's usage endpoint, then the rate limits in Codex's own session logs, then its /status screen.
    public static func codex(allowCLI: Bool) -> Fetched<CodexUsage> {
        chain(api: { CodexAPI.fetch() }, local: { CodexLogs.latest() }, cli: {
            guard CLILocator.isInstalled("codex") else { return .failed("Couldn't read Codex's usage.") }
            return cliResult(fetchCodex(), signedIn: { $0.signedIn }, error: { $0.error }) { $0.source = UsageSource.cli; $0.lastUpdated = Date() }
        }, allowCLI: allowCLI)
    }

    /// Cursor: its dashboard service (with cursor-agent's sign-in, then the editor's), then cursor-agent's /usage.
    public static func cursor(allowCLI: Bool) -> Fetched<CursorUsage> {
        chain(api: { CursorAPI.fetch() }, cli: {
            guard CLILocator.isInstalled("cursor-agent") else { return .failed("Couldn't read Cursor's usage.") }
            return cliResult(fetchCursor(), signedIn: { $0.signedIn }, error: { $0.error }) { $0.source = UsageSource.cli; $0.lastUpdated = Date() }
        }, allowCLI: allowCLI)
    }

    private static func cliResult<T>(_ u: T, signedIn: (T) -> Bool?, error: (T) -> String?, stamp: (inout T) -> Void) -> Fetched<T> {
        if signedIn(u) == false { return .signedOut(nil) }
        if let e = error(u) { return .failed(e) }
        var out = u
        stamp(&out)
        return .data(out)
    }

    /// Antigravity: agy's /usage screen is the only source (its sign-in is encrypted), so it's only read when
    /// `allowCLI`, and never while agy is signed out (that would open a sign-in tab). Nil: nothing new this time.
    public static func antigravity(allowCLI: Bool) -> Fetched<GeminiUsage>? {
        guard AntigravityAuth.signedIn else { return .signedOut(nil) }
        guard allowCLI else { return nil }
        let u = fetchAntigravity()
        if u.needsSetup == true { return .signedOut("Finish agy's first-run setup: run agy once in a terminal.") }
        if u.signedIn == false { return .signedOut(nil) }
        if let error = u.error { return .failed(error) }
        var out = u
        out.source = UsageSource.cli
        out.lastUpdated = Date()
        return .data(out)
    }

    private static func fallback<T>(_ r: SourceResult<T>) -> Fetched<T> {
        switch r {
        case .ok(let v): return .data(v)
        case .signedOut: return .signedOut(nil)
        case .offline: return .offline
        case .rateLimited: return .rateLimited
        case .failed(let msg): return .failed(msg)
        }
    }

    // MARK: - The CLIs' own screens (last resort)

    /// Claude Code's /usage screen. (Its /stats screen used to come along too; it's not usage, so it doesn't.)
    public static func cliClaude() -> ClaudeUsage {
        guard Reachability.isOnline() else {
            var offline = ClaudeUsage()
            offline.error = "You're offline."
            offline.errorType = "offline"
            return offline
        }
        var usage = withRetryOnError({ () -> ClaudeUsage in
            do {
                let raw = try capture(provider: "claude", command: "/usage")
                var parsed = UsageParser.parseUsage(raw)
                if !parsed.hasAnyData {
                    let classified = UsageParser.classifyNoDataError(raw)
                    parsed.error = classified.error
                    parsed.errorType = classified.errorType
                }
                return parsed
            } catch {
                var failed = ClaudeUsage()
                failed.error = String(describing: error)
                return failed
            }
        }, errorOf: { $0.error })
        if usage.hasAnyData {
            usage.lastUpdated = Date()
            usage.source = UsageSource.cli
        }
        return usage
    }

    public static func fetchAntigravity() -> GeminiUsage {
        // An unfinished setup comes back the same every time: no point in a second 55-second try.
        withRetryOnError({ () -> GeminiUsage in
            do { return ProviderParsers.parseAgy(try capture(provider: "antigravity")) }
            catch { return GeminiUsage(error: String(describing: error)) }
        }, errorOf: { $0.needsSetup == true ? nil : $0.error })
    }

    public static func fetchCodex() -> CodexUsage {
        withRetryOnError({ () -> CodexUsage in
            do { return ProviderParsers.parseCodex(try capture(provider: "codex")) }
            catch { return CodexUsage(error: String(describing: error)) }
        }, errorOf: { $0.error })
    }

    public static func fetchCursor() -> CursorUsage {
        withRetryOnError({ () -> CursorUsage in
            do { return ProviderParsers.parseCursor(try capture(provider: "cursor")) }
            catch { return CursorUsage(error: String(describing: error)) }
        }, errorOf: { $0.error })
    }

    /// The PTY-driven providers time their own input off idle-detection
    /// heuristics against a real interactive CLI — a slow machine, a cold-start
    /// network round-trip, or a redraw landing at the wrong moment can race
    /// that into a genuine parse/timeout error even though the CLI is
    /// installed and signed in fine. That's different from "not installed" /
    /// "not signed in", which come back with no error at all and are never
    /// retried here; only a real error gets one automatic second attempt
    /// before it's believed.
    static func withRetryOnError<T>(_ fetch: () -> T, errorOf: (T) -> String?) -> T {
        let first = fetch()
        guard errorOf(first) != nil else { return first }
        let second = fetch()
        return errorOf(second) == nil ? second : first
    }
}
