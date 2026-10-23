import Foundation

// Where each provider's usage comes from, other than its CLI's own screen.
//
// Every source here reads the sign-in the provider's CLI or app already keeps on this Mac and asks the provider's
// own usage endpoint, the same one its app shows. Read-only: a token is used as found and never refreshed here.
// Refreshing would rotate it out from under the CLI and sign you out of it; an expired token just means trying the
// next source until the CLI refreshes its own next time it runs (agy is run to do it, since that costs nothing).
// Tokens never leave the request they're used in.

/// What one source made of a provider.
public enum SourceResult<T> {
    case ok(T)
    /// Nothing to read with: the provider isn't signed in on this Mac (or not in a way this source can use).
    case signedOut
    /// The request couldn't reach the provider at all.
    case offline
    /// Asked too often; back off.
    case rateLimited
    /// Signed in, but this source didn't work this time (expired token, server error, unexpected answer).
    case failed(String)
}

// MARK: - Shell, keychain, HTTP

enum Shell {
    /// Runs a tool and returns its stdout when it exits 0 within `timeout`. Blocking; call off the main thread.
    static func run(_ path: String, _ args: [String], timeout: TimeInterval = 5) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        var data = Data()
        let read = DispatchQueue(label: "mochi.shell.read")
        let done = DispatchSemaphore(value: 0)
        read.async { data = out.fileHandleForReading.readDataToEndOfFile(); done.signal() }
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < deadline { usleep(20_000) }
        if p.isRunning { p.terminate() }
        _ = done.wait(timeout: .now() + 1)
        guard p.terminationReason == .exit, p.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}

enum Keychain {
    /// A generic password from the login keychain. Read with /usr/bin/security because each CLI saves its sign-in
    /// through that same tool, so the item already trusts it and macOS doesn't ask.
    static func password(service: String, account: String? = nil) -> String? {
        var args = ["find-generic-password", "-s", service]
        if let account { args += ["-a", account] }
        let s = Shell.run("/usr/bin/security", args + ["-w"])?.trimmingCharacters(in: .whitespacesAndNewlines)
        return s?.isEmpty == false ? s : nil
    }

    /// Whether the item is there at all, without reading its secret.
    static func exists(service: String, account: String? = nil) -> Bool {
        var args = ["find-generic-password", "-s", service]
        if let account { args += ["-a", account] }
        return Shell.run("/usr/bin/security", args) != nil
    }
}

enum HTTP {
    struct Response { let status: Int; let body: Data }

    /// One request, waited for (call off the main thread). Throws `SourceError` for the cases callers tell apart.
    static func send(_ request: URLRequest) -> Result<Response, SourceError> {
        var req = request
        req.timeoutInterval = 10
        if req.value(forHTTPHeaderField: "User-Agent") == nil { req.setValue("Mochi", forHTTPHeaderField: "User-Agent") }
        var result: Result<Response, SourceError> = .failure(.other("No response."))
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { data, response, error in
            if let e = error as? URLError {
                switch e.code {
                case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost,
                     .dnsLookupFailed, .timedOut, .internationalRoamingOff, .dataNotAllowed:
                    result = .failure(.offline)
                default:
                    result = .failure(.other(e.localizedDescription))
                }
            } else if let error {
                result = .failure(.other(error.localizedDescription))
            } else {
                result = .success(Response(status: (response as? HTTPURLResponse)?.statusCode ?? 0, body: data ?? Data()))
            }
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 15)
        return result
    }

    enum SourceError: Error { case offline, other(String) }

    /// Maps an HTTP answer onto a `SourceResult`, parsing a 200 with `parse`.
    static func result<T>(_ r: Result<Response, SourceError>, parse: (Data) -> T?) -> SourceResult<T> {
        switch r {
        case .failure(.offline): return .offline
        case .failure(.other(let msg)): return .failed(msg)
        case .success(let resp):
            switch resp.status {
            case 200: return parse(resp.body).map(SourceResult.ok) ?? .failed("Unexpected answer from the usage endpoint.")
            case 401, 403: return .failed("Sign-in expired; it refreshes next time you use the CLI.")
            case 429: return .rateLimited
            default: return .failed("Usage endpoint returned \(resp.status).")
            }
        }
    }
}

// MARK: - Dates and reset text

enum UsageDates {
    /// "2026-10-23T06:10:00.326450+00:00": ISO 8601 with any number of fraction digits (Foundation's formatter
    /// only takes milliseconds), or seconds/milliseconds since 1970 as a number or a string.
    static func parse(_ any: Any?) -> Date? {
        if let n = (any as? NSNumber)?.doubleValue ?? (any as? String).flatMap(Double.init), n > 0 {
            return Date(timeIntervalSince1970: n > 1e12 ? n / 1000 : n)
        }
        guard var s = any as? String, !s.isEmpty else { return nil }
        s = s.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    /// How the dropdown says when a window starts over, matching what the CLIs print: "11:10pm" today,
    /// "Oct 25, 12pm" further out.
    static func resetText(_ date: Date, now: Date = Date()) -> String {
        // to the nearest minute: a reset at 11:59:59.4 is noon
        let date = Date(timeIntervalSinceReferenceDate: (date.timeIntervalSinceReferenceDate / 60).rounded() * 60)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        let minutes = Calendar.current.component(.minute, from: date)
        let time = minutes == 0 ? "ha" : "h:mma"
        f.dateFormat = date.timeIntervalSince(now) < 20 * 3600 && Calendar.current.isDate(date, inSameDayAs: now)
            ? time : "MMM d, " + time
        return f.string(from: date).replacingOccurrences(of: "AM", with: "am").replacingOccurrences(of: "PM", with: "pm")
    }
}

// MARK: - Claude

/// Claude's usage endpoint, with Claude Code's own sign-in from the keychain. The same numbers as Settings → Usage on
/// claude.ai: the 5-hour session and the all-models week.
enum ClaudeAPI {
    static func fetch(now: Date = Date()) -> SourceResult<ClaudeUsage> {
        guard let raw = Keychain.password(service: "Claude Code-credentials"),
              let creds = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
              let oauth = creds["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty else { return .signedOut }
        if let exp = (oauth["expiresAt"] as? NSNumber)?.doubleValue, exp / 1000 < now.timeIntervalSince1970 {
            return .failed("Sign-in expired; it refreshes next time you use Claude Code.")
        }
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        req.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        return HTTP.result(HTTP.send(req)) { parse($0, now: now) }
    }

    static func parse(_ data: Data, now: Date = Date()) -> ClaudeUsage? {
        guard let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        // `limits` lists every window by kind; the older top-level fields say the same for the two that matter.
        let limits = j["limits"] as? [[String: Any]] ?? []
        func window(_ key: String, kind: String) -> (pct: Int, resets: Date?)? {
            if let w = j[key] as? [String: Any], let u = (w["utilization"] as? NSNumber)?.doubleValue {
                return (Int(u.rounded()), UsageDates.parse(w["resets_at"]))
            }
            if let l = limits.first(where: { $0["kind"] as? String == kind }), let p = (l["percent"] as? NSNumber)?.doubleValue {
                return (Int(p.rounded()), UsageDates.parse(l["resets_at"]))
            }
            return nil
        }
        let session = window("five_hour", kind: "session"), week = window("seven_day", kind: "weekly_all")
        guard session != nil || week != nil else { return nil }
        var u = ClaudeUsage()
        u.session = session?.pct
        u.sessionResetsAt = session?.resets
        u.sessionReset = session?.resets.map { UsageDates.resetText($0, now: now) }
        u.weekly = week?.pct
        u.weeklyResetsAt = week?.resets
        u.weeklyReset = week?.resets.map { UsageDates.resetText($0, now: now) }
        // Extra usage: pay-as-you-go credits past the plan, shown only when it's switched on.
        if let x = j["extra_usage"] as? [String: Any], x["is_enabled"] as? Bool == true {
            let spent = (x["used_credits"] as? NSNumber)?.doubleValue, total = (x["monthly_limit"] as? NSNumber)?.doubleValue
            let pct = (x["utilization"] as? NSNumber)?.doubleValue ?? (spent.flatMap { s in total.map { $0 > 0 ? s / $0 * 100 : 0 } })
            u.credits = Credits(pct: pct.map { Int($0.rounded()) }, spent: spent, total: total)
        }
        u.source = UsageSource.api
        u.lastUpdated = now
        return u
    }

    /// Claude Code's status line hands over `rate_limits` while you use it: `five_hour` and `seven_day`, each with
    /// `used_percentage` and `resets_at`. Nil when there's nothing usable in it.
    static func parseStatusLine(_ r: [String: Any], now: Date = Date()) -> (session: (Int, Date?)?, week: (Int, Date?)?)? {
        func window(_ any: Any?) -> (Int, Date?)? {
            guard let w = any as? [String: Any], let p = (w["used_percentage"] as? NSNumber)?.doubleValue else { return nil }
            return (Int(p.rounded()), UsageDates.parse(w["resets_at"]))
        }
        let s = window(r["five_hour"]), w = window(r["seven_day"])
        return s == nil && w == nil ? nil : (s, w)
    }
}

// MARK: - Codex

/// ChatGPT's usage endpoint for Codex, with the sign-in Codex keeps in ~/.codex/auth.json.
enum CodexAPI {
    static var authFile: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/auth.json") }

    /// Whether Codex is signed in with a ChatGPT account (the kind that has plan limits).
    static func credentials() -> (token: String, account: String?)? {
        guard let data = try? Data(contentsOf: authFile),
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let t = j["tokens"] as? [String: Any], let token = t["access_token"] as? String, !token.isEmpty else { return nil }
        return (token, t["account_id"] as? String)
    }

    static func fetch(now: Date = Date()) -> SourceResult<CodexUsage> {
        guard let creds = credentials() else { return .signedOut }
        var req = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!)
        req.setValue("Bearer " + creds.token, forHTTPHeaderField: "Authorization")
        if let a = creds.account { req.setValue(a, forHTTPHeaderField: "ChatGPT-Account-Id") }
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        return HTTP.result(HTTP.send(req)) { parse($0, now: now) }
    }

    static func parse(_ data: Data, now: Date = Date()) -> CodexUsage? {
        guard let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let r = j["rate_limit"] as? [String: Any] else { return nil }
        let limits = [r["primary_window"], r["secondary_window"]].compactMap { w -> CodexLimit? in
            guard let w = w as? [String: Any], let used = (w["used_percent"] as? NSNumber)?.doubleValue else { return nil }
            let seconds = (w["limit_window_seconds"] as? NSNumber)?.doubleValue ?? 0
            let resets = UsageDates.parse(w["reset_at"])
                ?? (w["reset_after_seconds"] as? NSNumber).map { now.addingTimeInterval($0.doubleValue) }
            return CodexLimit(name: windowName(minutes: seconds / 60), pctUsed: Int(used.rounded()),
                              reset: resets.map { UsageDates.resetText($0, now: now) }, resetsAt: resets)
        }
        guard !limits.isEmpty else { return nil }
        var u = CodexUsage(signedIn: true, plan: (j["plan_type"] as? String).map(\.capitalized), limits: limits)
        u.source = UsageSource.api
        u.lastUpdated = now
        return u
    }

    /// "5h limit", "Weekly limit": named the way Codex's own /status names them, which the UI keys off.
    static func windowName(minutes: Double) -> String {
        switch minutes {
        case 0: return "Limit"
        case 10000...: return "Weekly limit"
        case 1440...: return "\(Int((minutes / 1440).rounded()))d limit"
        default: return "\(Int((minutes / 60).rounded()))h limit"
        }
    }
}

/// The rate limits Codex itself last saw, from its own session logs (~/.codex/sessions/**/rollout-*.jsonl). No
/// network, so it works offline and when the token has expired; as fresh as your last Codex turn.
enum CodexLogs {
    static var sessions: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions") }

    static func latest(now: Date = Date()) -> SourceResult<CodexUsage> {
        let fm = FileManager.default
        // Days are folders (YYYY/MM/DD), so the newest file is in the last folder by name.
        func newest(_ dir: URL, depth: Int) -> [URL] {
            let items = ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
                .sorted { $0.lastPathComponent > $1.lastPathComponent }
            if depth == 0 { return items.filter { $0.lastPathComponent.hasPrefix("rollout-") && $0.pathExtension == "jsonl" } }
            for d in items where (try? d.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                let found = newest(d, depth: depth - 1)
                if !found.isEmpty { return found }
            }
            return []
        }
        let files = newest(sessions, depth: 3)
            .sorted { (mtime($0) ?? .distantPast) > (mtime($1) ?? .distantPast) }
        guard !files.isEmpty else { return .signedOut }
        for file in files.prefix(5) {
            if var u = parse(tail(of: file), now: now) {
                u.lastUpdated = mtime(file)
                return .ok(u)
            }
        }
        return .failed("Codex's session logs have no rate limits yet.")
    }

    /// The last `rate_limits` in a log's text.
    static func parse(_ text: String, now: Date = Date()) -> CodexUsage? {
        for line in text.split(separator: "\n").reversed() where line.contains("\"rate_limits\"") {
            guard let j = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let payload = j["payload"] as? [String: Any],
                  let r = payload["rate_limits"] as? [String: Any] else { continue }
            let limits = [r["primary"], r["secondary"]].compactMap { w -> CodexLimit? in
                guard let w = w as? [String: Any], let used = (w["used_percent"] as? NSNumber)?.doubleValue else { return nil }
                let resets = UsageDates.parse(w["resets_at"])
                return CodexLimit(name: CodexAPI.windowName(minutes: (w["window_minutes"] as? NSNumber)?.doubleValue ?? 0),
                                  pctUsed: Int(used.rounded()), reset: resets.map { UsageDates.resetText($0, now: now) },
                                  resetsAt: resets)
            }
            guard !limits.isEmpty else { continue }
            var u = CodexUsage(signedIn: true, limits: limits)
            u.source = UsageSource.logs
            return u
        }
        return nil
    }

    private static func mtime(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    /// The last 512 KB: plenty for the latest turns, without reading a long session's whole history.
    private static func tail(of url: URL) -> String {
        guard let h = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        try? h.seek(toOffset: size > 512_000 ? size - 512_000 : 0)
        return String(decoding: h.readDataToEndOfFile(), as: UTF8.self)
    }
}

// MARK: - Cursor

/// Cursor's dashboard service, the one its editor's usage meter reads, with the sign-in cursor-agent keeps in the
/// keychain or, failing that, the Cursor editor's own.
enum CursorAPI {
    static var editorState: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
    }

    /// Every access token on this Mac, cursor-agent's first.
    static func tokens() -> [String] {
        var out: [String] = []
        if let t = Keychain.password(service: "cursor-access-token") { out.append(t) }
        if let t = editorValue("cursorAuth/accessToken"), !out.contains(t) { out.append(t) }
        return out
    }

    /// Whether either cursor-agent or the editor is signed in, without reading a token.
    static var signedIn: Bool {
        Keychain.exists(service: "cursor-access-token") || editorValue("cursorAuth/accessToken") != nil
    }

    private static func editorValue(_ key: String) -> String? {
        guard FileManager.default.fileExists(atPath: editorState.path) else { return nil }
        let s = Shell.run("/usr/bin/sqlite3", ["-readonly", editorState.path,
                                               "select value from ItemTable where key='\(key)'"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return s?.isEmpty == false ? s : nil
    }

    static func fetch(now: Date = Date()) -> SourceResult<CursorUsage> {
        let all = tokens()
        guard !all.isEmpty else { return .signedOut }
        var last: SourceResult<CursorUsage> = .failed("No usable Cursor sign-in.")
        for token in all {
            let usage = HTTP.result(HTTP.send(rpc("GetCurrentPeriodUsage", token))) { parse($0, now: now) }
            guard case .ok(var u) = usage else {
                if case .offline = usage { return .offline }
                last = usage
                continue
            }
            if case .ok(let plan) = HTTP.result(HTTP.send(rpc("GetPlanInfo", token)), parse: parsePlan) { u.plan = plan }
            return .ok(u)
        }
        return last
    }

    private static func rpc(_ method: String, _ token: String) -> URLRequest {
        var req = URLRequest(url: URL(string: "https://api2.cursor.sh/aiserver.v1.DashboardService/\(method)")!)
        req.httpMethod = "POST"
        req.httpBody = Data("{}".utf8)
        req.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        return req
    }

    /// Included = everything this cycle, then the Auto and API pools it's split into, as the editor and
    /// cursor-agent's /usage show them.
    static func parse(_ data: Data, now: Date = Date()) -> CursorUsage? {
        guard let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let p = j["planUsage"] as? [String: Any] else { return nil }
        let rows = [("Included", "totalPercentUsed"), ("Auto", "autoPercentUsed"), ("API", "apiPercentUsed")]
            .compactMap { name, key in (p[key] as? NSNumber).map { CursorUsageRow(name: name, pctUsed: Int($0.doubleValue.rounded())) } }
        guard !rows.isEmpty else { return nil }
        let end = UsageDates.parse(j["billingCycleEnd"])
        var u = CursorUsage(signedIn: true, reset: end.map { UsageDates.resetText($0, now: now) }, rows: rows)
        u.resetsAt = end
        u.source = UsageSource.api
        u.lastUpdated = now
        return u
    }

    static func parsePlan(_ data: Data) -> String? {
        ((try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["planInfo"] as? [String: Any])?["planName"] as? String
    }
}

// MARK: - Antigravity

/// Cloud Code's quota summary, the one agy's /usage screen draws, with the Google sign-in agy keeps in the keychain.
enum AntigravityAPI {
    static var signedIn: Bool { Keychain.exists(service: "gemini", account: "antigravity") }

    /// agy's access token and when it expires. go-keyring saves it as "go-keyring-base64:" and base64 JSON.
    static func token() -> (access: String, expiry: Date?)? {
        guard var raw = Keychain.password(service: "gemini", account: "antigravity") else { return nil }
        let prefix = "go-keyring-base64:"
        var data = Data(raw.utf8)
        if raw.hasPrefix(prefix) {
            raw.removeFirst(prefix.count)
            guard let d = Data(base64Encoded: raw + String(repeating: "=", count: (4 - raw.count % 4) % 4)) else { return nil }
            data = d
        }
        guard let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let t = j["token"] as? [String: Any],
              let access = t["access_token"] as? String, !access.isEmpty else { return nil }
        return (access, UsageDates.parse(t["expiry"]))
    }

    static func fetch(now: Date = Date()) -> SourceResult<GeminiUsage> {
        guard let agy = CLILocator.find("agy"), var t = token() else { return .signedOut }
        if let exp = t.expiry, exp < now.addingTimeInterval(60) {
            // agy renews its own sign-in whenever it runs, and `agy models` runs without a prompt or any quota.
            _ = Shell.run(agy, ["models"], timeout: 30)
            guard let fresh = token(), fresh.expiry.map({ $0 > now }) ?? true else {
                return .failed("Sign-in expired; run agy once to renew it.")
            }
            t = fresh
        }
        var req = URLRequest(url: URL(string: "https://daily-cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary")!)
        req.httpMethod = "POST"
        req.httpBody = Data("{}".utf8)
        req.setValue("Bearer " + t.access, forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // The endpoint only answers agy itself (403 otherwise).
        let version = Shell.run(agy, ["--version"])?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "1"
        req.setValue("antigravity/\(version) darwin/\(arm64 ? "arm64" : "x86_64")", forHTTPHeaderField: "User-Agent")
        return HTTP.result(HTTP.send(req)) { parse($0, now: now) }
    }

    private static var arm64: Bool {
        #if arch(arm64)
        true
        #else
        false
        #endif
    }

    /// Every model group has a weekly and a 5-hour window; the dropdown shows the most used group in each. An unused
    /// window's reset is just "5 hours from now", so it's left out, as agy's screen does.
    static func parse(_ data: Data, now: Date = Date()) -> GeminiUsage? {
        guard let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let groups = j["groups"] as? [[String: Any]] else { return nil }
        let buckets = groups.flatMap { $0["buckets"] as? [[String: Any]] ?? [] }.filter { $0["disabled"] as? Bool != true }
        func most(_ window: String) -> (pct: Int, reset: Date?)? {
            buckets.filter { $0["window"] as? String == window }
                .compactMap { b -> (pct: Int, reset: Date?)? in
                    guard let left = (b["remainingFraction"] as? NSNumber)?.doubleValue else { return nil }
                    let pct = Int(((1 - left) * 100).rounded())
                    return (pct, pct > 0 ? UsageDates.parse(b["resetTime"]) : nil)
                }
                .max { $0.pct < $1.pct }
        }
        let week = most("weekly"), five = most("5h")
        guard week != nil || five != nil else { return nil }
        var u = GeminiUsage(signedIn: true, weeklyPct: week?.pct, fiveHourPct: five?.pct,
                            weeklyReset: week?.reset.map { UsageDates.resetText($0, now: now) },
                            fiveHourReset: five?.reset.map { UsageDates.resetText($0, now: now) }, lastUpdated: now)
        u.weeklyResetsAt = week?.reset
        u.fiveHourResetsAt = five?.reset
        u.source = UsageSource.api
        return u
    }
}
