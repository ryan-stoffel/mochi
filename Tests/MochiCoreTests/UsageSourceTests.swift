import XCTest
@testable import MochiCore

/// Each usage source's parser against an answer captured from the real endpoint (identifiers redacted), the order
/// sources are tried in, and the rule that a window whose reset has passed starts over.
final class UsageSourceTests: XCTestCase {

    private func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil), "missing fixture \(name)")
        return try Data(contentsOf: url)
    }

    private let now = Date(timeIntervalSince1970: 1_792_730_000)   // 2026-10-22, before every reset in the fixtures

    // MARK: - Claude

    func testClaudeAPIReadsSessionAndTheAllModelsWeek() throws {
        let u = try XCTUnwrap(ClaudeAPI.parse(try fixture("claude-oauth-usage.json"), now: now))
        XCTAssertEqual(u.session, 19)
        // The all-models week, not the 0% per-model ("Fable") week listed after it.
        XCTAssertEqual(u.weekly, 49)
        XCTAssertEqual(u.weeklyResetsAt, UsageDates.parse("2026-10-25T19:00:00Z"))
        XCTAssertNotNil(u.sessionReset)
        XCTAssertNil(u.credits)   // extra usage is switched off
        XCTAssertEqual(u.source, UsageSource.api)
    }

    func testClaudeAPIFallsBackToTheLimitsList() throws {
        let body = #"{"limits":[{"kind":"session","percent":7,"resets_at":"2026-10-23T06:10:00Z"},{"kind":"weekly_all","percent":31}]}"#
        let u = try XCTUnwrap(ClaudeAPI.parse(Data(body.utf8), now: now))
        XCTAssertEqual(u.session, 7)
        XCTAssertEqual(u.weekly, 31)
        XCTAssertNil(ClaudeAPI.parse(Data(#"{"error":"nope"}"#.utf8)))
    }

    func testClaudeStatusLine() {
        let r: [String: Any] = ["five_hour": ["used_percentage": 16.4, "resets_at": 1_792_744_200],
                                "seven_day": ["used_percentage": 48, "resets_at": 1_793_041_200_000]]
        let p = ClaudeAPI.parseStatusLine(r)
        XCTAssertEqual(p?.session?.0, 16)
        XCTAssertEqual(p?.week?.0, 48)
        XCTAssertEqual(p?.week?.1, Date(timeIntervalSince1970: 1_793_041_200))   // milliseconds read as such
        XCTAssertNil(ClaudeAPI.parseStatusLine([:]))
    }

    /// The CLI screen lists a per-model week after the all-models one; only the all-models week is the limit.
    func testClaudeScreenIgnoresPerModelWeeks() {
        let screen = """
        Current session
        16% used
        Resets 11:10pm (America/Los_Angeles)
        Current week (all models)
        48% used
        Resets Oct 25 at 12pm (America/Los_Angeles)
        Current week (Fable)
        0% used
        Resets Oct 25 at 12pm (America/Los_Angeles)
        """
        let u = UsageParser.parseUsage(screen)
        XCTAssertEqual(u.session, 16)
        XCTAssertEqual(u.weekly, 48)
        XCTAssertEqual(u.weeklyReset, "Oct 25 at 12pm (America/Los_Angeles)")
    }

    // MARK: - Codex

    func testCodexAPI() throws {
        let u = try XCTUnwrap(CodexAPI.parse(try fixture("codex-wham-usage.json"), now: now))
        XCTAssertEqual(u.plan, "Plus")
        XCTAssertEqual(u.limits?.map(\.name), ["5h limit", "Weekly limit"])
        XCTAssertEqual(u.limits?.map(\.pctUsed), [12, 3])
        XCTAssertEqual(u.limits?.first?.resetsAt, Date(timeIntervalSince1970: 1_792_751_060))
        XCTAssertEqual(u.primaryPct, 12)
    }

    func testCodexLogsTakeTheLastRateLimits() throws {
        let text = String(decoding: try fixture("codex-rollout-tail.jsonl"), as: UTF8.self)
        let u = try XCTUnwrap(CodexLogs.parse(text, now: now))
        XCTAssertEqual(u.limits?.map(\.pctUsed), [3, 1])
        XCTAssertEqual(u.limits?.map(\.name), ["5h limit", "Weekly limit"])
        XCTAssertEqual(u.source, UsageSource.logs)
        XCTAssertNil(CodexLogs.parse("{\"type\":\"session_meta\"}"))
    }

    // MARK: - Cursor

    func testCursorAPI() throws {
        let u = try XCTUnwrap(CursorAPI.parse(try fixture("cursor-period-usage.json"), now: now))
        XCTAssertEqual(u.rows?.map(\.name), ["Included", "Auto", "API"])
        XCTAssertEqual(u.rows?.map(\.pctUsed), [26, 12, 40])
        XCTAssertEqual(u.primaryPct, 26)
        XCTAssertEqual(u.resetsAt, Date(timeIntervalSince1970: 1_794_926_593.444))
        XCTAssertEqual(CursorAPI.parsePlan(try fixture("cursor-plan-info.json")), "Free")
    }

    // MARK: - Antigravity

    /// The real answer's shape, with a second group and some use added: each window shows its most used group.
    func testAntigravityAPI() throws {
        let u = try XCTUnwrap(AntigravityAPI.parse(try fixture("antigravity-quota-summary.json"), now: now))
        XCTAssertEqual(u.fiveHourPct, 38)
        XCTAssertEqual(u.weeklyPct, 12)
        XCTAssertEqual(u.fiveHourResetsAt, UsageDates.parse("2026-10-23T19:32:09Z"))
        XCTAssertEqual(u.weeklyResetsAt, UsageDates.parse("2026-10-30T14:32:09Z"))
        XCTAssertEqual(u.source, UsageSource.api)
        let later = UsageExpiry.antigravity(u, now: try XCTUnwrap(u.fiveHourResetsAt))
        XCTAssertEqual(later.fiveHourPct, 0)
        XCTAssertEqual(later.weeklyPct, 12)
    }

    /// agy's first-run setup, captured from a real run: no numbers, and a clear reason rather than "signed out".
    func testAntigravitySetupScreenIsRecognised() throws {
        let raw = String(decoding: try fixture("antigravity-setup.ansi"), as: UTF8.self)
        let u = ProviderParsers.parseAgy(raw)
        XCTAssertEqual(u.needsSetup, true)
        XCTAssertEqual(u.signedIn, true)
        XCTAssertNil(u.error)
    }

    // MARK: - Timing

    /// Claude's week ends at 18:59:59.42 UTC; Claude shows that as noon, and so does Mochi.
    func testResetTimesRoundToTheMinute() throws {
        let d = try XCTUnwrap(Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 25, hour: 11, minute: 59, second: 59)))
        XCTAssertEqual(UsageDates.resetText(d.addingTimeInterval(0.4), now: d.addingTimeInterval(-3 * 86400)), "Oct 25, 12pm")
    }

    func testRateLimitBackoffDoublesToTenMinutes() {
        XCTAssertEqual((1...5).map { UsageService.backoff(after: $0) }, [90, 180, 360, 600, 600])
    }

    // MARK: - Fallback order

    func testSourcesAreTriedInOrder() {
        var calls: [String] = []
        func api(_ r: SourceResult<Int>) -> () -> SourceResult<Int> { { calls.append("api"); return r } }
        func local(_ r: SourceResult<Int>) -> () -> SourceResult<Int> { { calls.append("local"); return r } }
        let cli: () -> UsageFetcher.Fetched<Int> = { calls.append("cli"); return .data(3) }
        func value(_ f: UsageFetcher.Fetched<Int>) -> Int? { if case .data(let v) = f { return v }; return nil }

        XCTAssertEqual(value(UsageFetcher.chain(api: api(.ok(1)), local: local(.ok(2)), cli: cli, allowCLI: true)), 1)
        XCTAssertEqual(calls, ["api"])

        calls = []
        XCTAssertEqual(value(UsageFetcher.chain(api: api(.failed("x")), local: local(.ok(2)), cli: cli, allowCLI: true)), 2)
        XCTAssertEqual(calls, ["api", "local"])

        calls = []
        XCTAssertEqual(value(UsageFetcher.chain(api: api(.failed("x")), local: local(.failed("y")), cli: cli, allowCLI: true)), 3)
        XCTAssertEqual(calls, ["api", "local", "cli"])

        // The poll between CLI reads: no CLI, and the API's reason comes back.
        calls = []
        if case .failed(let m) = UsageFetcher.chain(api: api(.failed("x")), cli: cli, allowCLI: false) { XCTAssertEqual(m, "x") } else { XCTFail() }
        XCTAssertEqual(calls, ["api"])

        // Offline: local records still count, the CLI is skipped.
        calls = []
        if case .offline = UsageFetcher.chain(api: api(.offline), cli: cli, allowCLI: true) {} else { XCTFail() }
        XCTAssertEqual(calls, ["api"])

        calls = []
        if case .rateLimited = UsageFetcher.chain(api: api(.rateLimited), cli: cli, allowCLI: true) {} else { XCTFail() }
        XCTAssertEqual(calls, ["api"])

        // Signed out: never launch the CLI (it would open a sign-in tab), unless the provider says it's safe.
        calls = []
        if case .signedOut = UsageFetcher.chain(api: api(.signedOut), local: local(.ok(2)), cli: cli, allowCLI: true) {} else { XCTFail() }
        XCTAssertEqual(calls, ["api"])
        calls = []
        XCTAssertEqual(value(UsageFetcher.chain(api: api(.signedOut), cli: cli, allowCLI: true, cliWhenSignedOut: true)), 3)
        XCTAssertEqual(calls, ["api", "cli"])
    }

    // MARK: - Resets

    func testPassedResetsStartOver() {
        var c = ClaudeUsage()
        c.session = 80; c.sessionResetsAt = now.addingTimeInterval(-1); c.sessionReset = "9pm"
        c.weekly = 40; c.weeklyResetsAt = now.addingTimeInterval(3600)
        let e = UsageExpiry.claude(c, now: now)
        XCTAssertEqual(e.session, 0)
        XCTAssertNil(e.sessionReset)
        XCTAssertEqual(e.weekly, 40)

        let x = UsageExpiry.codex(CodexUsage(limits: [CodexLimit(name: "5h limit", pctUsed: 90, resetsAt: now),
                                                      CodexLimit(name: "Weekly limit", pctUsed: 20, resetsAt: now.addingTimeInterval(9))]), now: now)
        XCTAssertEqual(x.limits?.map(\.pctUsed), [0, 20])

        var cur = CursorUsage(rows: [CursorUsageRow(name: "Included", pctUsed: 70)])
        cur.resetsAt = now.addingTimeInterval(-60)
        XCTAssertEqual(UsageExpiry.cursor(cur, now: now).rows?.first?.pctUsed, 0)
    }

    func testDatesAndResetText() {
        XCTAssertEqual(UsageDates.parse("2026-10-23T06:10:00.326450+00:00"), Date(timeIntervalSince1970: 1_792_735_800))
        XCTAssertEqual(UsageDates.parse("1794926593444"), Date(timeIntervalSince1970: 1_794_926_593.444))
        XCTAssertNil(UsageDates.parse(nil))
        let cal = Calendar.current
        let today = cal.date(bySettingHour: 23, minute: 10, second: 0, of: now)!
        XCTAssertEqual(UsageDates.resetText(today, now: cal.date(bySettingHour: 20, minute: 0, second: 0, of: now)!), "11:10pm")
        XCTAssertTrue(UsageDates.resetText(today.addingTimeInterval(3 * 86400), now: now).contains(","))
    }

    // MARK: - History

    func testHistoryKeepsProvidersApart() {
        let p = HistoryPoint(timestamp: now, session: 1, weekly: 2)
        XCTAssertEqual(p.providerID, "claude")   // samples saved before providers were recorded were Claude's
        XCTAssertEqual(HistoryPoint(timestamp: now, session: 1, weekly: 2, provider: "codex").providerID, "codex")
    }
}
