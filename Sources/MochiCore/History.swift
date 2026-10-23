import Foundation

/// One sampled reading, timestamped. `session` is the provider's short window (Claude's 5 hours, Codex's 5h,
/// Cursor's billing cycle), `weekly` its long one.
public struct HistoryPoint: Codable, Equatable, Sendable {
    public var timestamp: Date
    public var session: Int?
    public var weekly: Int?
    /// Which provider it's for; nil in samples saved before every provider kept a history, which were all Claude's.
    public var provider: String?

    public init(timestamp: Date, session: Int?, weekly: Int?, provider: String? = nil) {
        self.timestamp = timestamp
        self.session = session
        self.weekly = weekly
        self.provider = provider
    }

    var providerID: String { provider ?? "claude" }
}

/// The usage history behind the sparkline.
///
/// In os-menu this lived in the renderer's `localStorage`, which meant only the
/// popup could ever see it. Moving it into the shared core is what lets the
/// notch draw the same chart from the same samples.
public final class HistoryStore: @unchecked Sendable {

    public static let shared = HistoryStore()

    /// ~7 days of 5-minute samples for each of the four providers, generously rounded up.
    private static let maxPoints = 8800

    private let queue = DispatchQueue(label: "mochi.history")
    private var points: [HistoryPoint] = []

    private static var fileURL: URL {
        Settings.supportDirectory.appendingPathComponent("history.json")
    }

    private init() {
        if let data = try? Data(contentsOf: Self.fileURL),
           let decoded = try? JSONDecoder().decode([HistoryPoint].self, from: data) {
            points = decoded
        }
    }

    public var all: [HistoryPoint] {
        queue.sync { points }
    }

    /// Claude's points inside a trailing window, oldest first.
    public func points(within window: TimeInterval, now: Date = Date()) -> [HistoryPoint] {
        points(for: "claude", within: window, now: now)
    }

    /// One provider's points inside a trailing window, oldest first.
    public func points(for provider: String, within window: TimeInterval, now: Date = Date()) -> [HistoryPoint] {
        let cutoff = now.addingTimeInterval(-window)
        return queue.sync { points.filter { $0.timestamp >= cutoff && $0.providerID == provider } }
    }

    /// Records a reading.
    ///
    /// A manual-refresh burst (or the automatic retry) can produce several
    /// fetches seconds apart with an identical reading — storing each as its
    /// own point wastes the window's budget on redundant samples. Those get
    /// collapsed into the existing last point by bumping its timestamp; a real
    /// change, or enough time passing, still always gets its own point.
    public func record(provider: String = "claude", session: Int?, weekly: Int?, now: Date = Date()) {
        guard session != nil || weekly != nil else { return }
        queue.sync {
            if let i = points.lastIndex(where: { $0.providerID == provider }),
               points[i].session == session, points[i].weekly == weekly,
               now.timeIntervalSince(points[i].timestamp) < 4 * 60 {
                points[i].timestamp = now
            } else {
                points.append(HistoryPoint(timestamp: now, session: session, weekly: weekly, provider: provider))
            }
            if points.count > Self.maxPoints {
                points.removeFirst(points.count - Self.maxPoints)
            }
            persist()
        }
    }

    private func persist() {
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(points) else { return }
        try? data.write(to: Self.fileURL, options: .atomic)
    }
}

/// The window each chart mode covers. Session resets every ~5h and weekly
/// every 7 days, so each gets a window sized to its own cycle rather than
/// "however many refreshes happened to fit in the last N samples".
public enum ChartMode: String, CaseIterable {
    case session
    case weekly

    public var title: String {
        switch self {
        case .session: return "Session"
        case .weekly: return "Week"
        }
    }

    public var window: TimeInterval {
        switch self {
        case .session: return 24 * 60 * 60
        case .weekly: return 7 * 24 * 60 * 60
        }
    }

    public func value(_ p: HistoryPoint) -> Int? {
        switch self {
        case .session: return p.session
        case .weekly: return p.weekly
        }
    }
}
