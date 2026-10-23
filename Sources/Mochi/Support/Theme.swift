import SwiftUI
import MochiCore

extension Color {
    init(hex: String) {
        var h = hex
        if h.hasPrefix("#") { h.removeFirst() }
        var v: UInt64 = 0
        Scanner(string: h).scanHexInt64(&v)
        self.init(
            red: Double((v >> 16) & 0xFF) / 255,
            green: Double((v >> 8) & 0xFF) / 255,
            blue: Double(v & 0xFF) / 255)
    }
}

extension Provider {
    var color: Color { Color(hex: colorHex) }
}

extension View {
    /// No focus ring on whatever takes focus first when a panel opens; the keyboard still works.
    @ViewBuilder func noFocusRings() -> some View {
        if #available(macOS 14.0, *) { focusEffectDisabled() } else { self }
    }
}

enum Theme {
    /// A usage bar or ring: the provider's colour while there's room, orange from 75%, red from 90%.
    static func tint(_ pct: Int, _ provider: Provider) -> Color {
        pct >= 90 ? .red : pct >= 75 ? .orange : provider.color
    }
}

enum Format {

    /// "just now", "5 min ago", "3 hr ago".
    static func ago(_ date: Date?) -> String {
        guard let date else { return "never" }
        let minutes = Int(Date().timeIntervalSince(date) / 60)
        if minutes < 1 { return "just now" }
        if minutes < 60 { return "\(minutes) min ago" }
        return "\(minutes / 60) hr ago"
    }

    /// When a limit starts over, the way claude.ai says it: "Resets at 9:10 AM" today, "Resets Sunday 12:00 PM" this
    /// week, "Resets Nov 17" further out. Falls back to the text a CLI printed when there's no date.
    static func resets(_ date: Date?, text: String? = nil, now: Date = Date()) -> String? {
        guard let date else { return reset(text).map { "Resets " + $0 } }
        let d = Date(timeIntervalSinceReferenceDate: (date.timeIntervalSinceReferenceDate / 60).rounded() * 60)
        let f = DateFormatter()
        if Calendar.current.isDate(d, inSameDayAs: now) {
            f.timeStyle = .short
            return "Resets at " + f.string(from: d)
        }
        f.setLocalizedDateFormatFromTemplate(d.timeIntervalSince(now) < 6 * 86400 ? "EEEE jmm" : "MMM d")
        return "Resets " + f.string(from: d)
    }

    /// Tidies a CLI's own reset string: drops the parenthesised timezone and repairs the TUI's column packing
    /// ("Mar5,8pm" → "Mar 5, 8pm").
    static func reset(_ s: String?) -> String? {
        guard let s, !s.isEmpty else { return nil }
        var out = Pattern(#"\s*\([^)]*\)"#).replacingAll(in: s, with: "")
        out = Pattern(#"([A-Za-z])(\d)"#).replacingAll(in: out, with: "$1 $2")
        out = Pattern(#",(\S)"#).replacingAll(in: out, with: ", $1")
        return out.trimmingCharacters(in: .whitespaces)
    }

    static func pct(_ value: Int?) -> String {
        value.map { "\($0)" } ?? "—"
    }
}
