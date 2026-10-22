// Mochi's panel: what opens when you right-click Mochi. A dark card split into tabs so nothing is a wall of menu items:
// Claude (usage, sessions), Today (your stats, quick logging), Play (things Mochi can do, costumes) and Settings.
import AppKit
import SwiftUI

// MARK: - Look

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255, opacity: alpha)
    }
}

/// Warm neutrals with Claude's orange as the one accent.
enum PanelTheme {
    static let bg = Color(hex: 0x1A1918)
    static let raised = Color(hex: 0x252422)
    static let hover = Color(hex: 0x2E2D2A)
    static let selected = Color(hex: 0x3A3835)
    static let hairline = Color.white.opacity(0.07)
    static let track = Color.white.opacity(0.08)
    static let text = Color(hex: 0xEEECE6)
    static let secondary = Color(hex: 0xA6A39B)
    static let tertiary = Color(hex: 0x6F6C66)
    static let accent = Color(hex: 0xD97757)
    static let mochi = Color(hex: 0xE5714B)
    static let yellow = Color(hex: 0xE0B25B)
    static let red = Color(hex: 0xE5664F)
    static let green = Color(hex: 0x6CC08B)
    static let radius: CGFloat = 14

    /// Usage colour: Claude's own until you're getting close, then a warning.
    static func tier(_ pct: Double) -> Color { pct >= 90 ? red : pct >= 70 ? yellow : accent }
}

// MARK: - What the panel shows, and what it can ask for

struct PanelSession: Identifiable {
    let id: String
    let project: String
    let line: String
    let needsYou: Bool
    let busy: Bool
}

struct PanelState {
    var mood = "chilling"
    var stats: [String: Any] = [:]
    var visible = true
    var quiet = false
    var roam = true
    var appAware = true
    var emoji = false
    var water = true
    var login = false
    var scale: Double = 3
    var follow = true
    var narrate = true
    var checkUsage = true
    var canCheck = true
    var connected = false
    var listening = true
    var five: UsageWindow?
    var week: UsageWindow?
    var usageAt: Date?
    var sessions: [PanelSession] = []
}

enum PanelAction {
    case pet(String), size(Double), roam, appAware, emoji, water, quiet, login, corner, visible
    case connect, follow, narrate, checkUsage, refreshUsage, focus(String), quit, close
}

final class PanelModel: ObservableObject {
    @Published var s = PanelState()
    @Published var tab = UserDefaults.standard.string(forKey: "panelTab") ?? "claude" {
        didSet { UserDefaults.standard.set(tab, forKey: "panelTab"); resized() }
    }
    var act: (PanelAction) -> Void = { _ in }
    var resized: () -> Void = {}
}

// MARK: - The panel

struct PanelView: View {
    @ObservedObject var model: PanelModel
    @Namespace private var tabPill
    private var s: PanelState { model.s }

    static let tabs: [(id: String, title: String)] = [("claude", "Claude"), ("today", "Today"), ("play", "Play"), ("settings", "Settings")]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            tabBar
            Group {
                switch model.tab {
                case "today": TodayTab(model: model)
                case "play": PlayTab(model: model)
                case "settings": SettingsTab(model: model)
                default: ClaudeTab(model: model)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
        .frame(width: 340)
        .background(PanelTheme.bg)
        .foregroundStyle(PanelTheme.text)
        .clipShape(RoundedRectangle(cornerRadius: PanelTheme.radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: PanelTheme.radius, style: .continuous).strokeBorder(Color.white.opacity(0.09), lineWidth: 1))
    }

    private var header: some View {
        HStack(spacing: 10) {
            MochiGlyph().frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text("Mochi").font(.system(size: 13, weight: .semibold))
                Text(s.mood.prefix(1).uppercased() + s.mood.dropFirst()).font(.system(size: 11.5)).foregroundStyle(PanelTheme.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            IconButton(systemName: s.visible ? "eye" : "eye.slash") { model.act(.visible) }
                .help(s.visible ? "Hide Mochi" : "Show Mochi")
            IconButton(systemName: "xmark") { model.act(.close) }.help("Close")
        }
        .padding(.leading, 16)
        .padding(.trailing, 10)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(Self.tabs, id: \.id) { t in
                let on = model.tab == t.id
                Button {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) { model.tab = t.id }
                } label: {
                    HStack(spacing: 5) {
                        if t.id == "claude" { ClaudeLogo().fill(on ? PanelTheme.accent : PanelTheme.secondary).frame(width: 11, height: 11) }
                        Text(t.title).font(.system(size: 12, weight: .medium))
                        if t.id == "claude", let dot = claudeDot { Circle().fill(dot).frame(width: 5, height: 5) }
                    }
                    .foregroundStyle(on ? PanelTheme.text : PanelTheme.secondary)
                    .frame(maxWidth: .infinity, minHeight: 26)
                    .background {
                        if on {
                            RoundedRectangle(cornerRadius: 7, style: .continuous).fill(PanelTheme.selected)
                                .shadow(color: .black.opacity(0.25), radius: 1, y: 1)
                                .matchedGeometryEffect(id: "pill", in: tabPill)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(PanelTheme.raised))
        .padding(.horizontal, 16)
    }

    /// A dot on the Claude tab: red when a session needs you, orange while one is working.
    private var claudeDot: Color? {
        if s.sessions.contains(where: \.needsYou) { return PanelTheme.red }
        if s.sessions.contains(where: \.busy) { return PanelTheme.accent }
        return nil
    }
}

// MARK: - Claude

struct ClaudeTab: View {
    @ObservedObject var model: PanelModel
    private var s: PanelState { model.s }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !s.connected && s.five == nil && !(s.checkUsage && s.canCheck) {
                EmptyState(title: "Connect Claude Code",
                           hint: "Mochi acts out what Claude is doing, and your plan's usage shows up here.",
                           action: ("Connect", { model.act(.connect) }))
            } else {
                PanelSection(title: "Usage", trailing: { usageFooter }) {
                    if s.five != nil || s.week != nil {
                        Card {
                            VStack(spacing: 16) {
                                if let w = s.five { UsageMeter(label: "5-hour limit", window: w) }
                                if let w = s.week { UsageMeter(label: "Weekly limit", window: w) }
                            }
                            .padding(14)
                        }
                    } else {
                        Card {
                            Text(s.checkUsage && s.canCheck ? "Checking your usage…" : "Your usage shows up after your next Claude Code message.")
                                .font(.system(size: 12)).foregroundStyle(PanelTheme.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(14)
                        }
                    }
                }
                PanelSection(title: "Sessions", trailing: {
                    let busy = s.sessions.filter { $0.busy || $0.needsYou }.count
                    if busy > 0 { Text("\(busy) active").font(.system(size: 11)).foregroundStyle(PanelTheme.tertiary) }
                }) {
                    if s.sessions.isEmpty {
                        Card {
                            HStack {
                                Text(s.connected ? "No Claude Code sessions right now." : "Connect to follow your sessions.")
                                    .font(.system(size: 12)).foregroundStyle(PanelTheme.secondary)
                                Spacer(minLength: 8)
                                if !s.connected { Button("Connect") { model.act(.connect) }.buttonStyle(PillButtonStyle(prominent: true)) }
                            }
                            .padding(.horizontal, 14)
                            .frame(minHeight: 44)
                        }
                    } else {
                        Card {
                            VStack(spacing: 0) {
                                ForEach(s.sessions) { session in
                                    if session.id != s.sessions.first?.id { Hairline(inset: 30) }
                                    Button { model.act(.focus(session.id)) } label: { SessionRow(session: session) }
                                        .buttonStyle(.plain)
                                        .help("Switch to this session")
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private var usageFooter: some View {
        HStack(spacing: 6) {
            if let at = s.usageAt {
                Text(Self.updated(at)).font(.system(size: 11)).foregroundStyle(PanelTheme.tertiary)
            }
            if s.canCheck {
                Button { model.act(.refreshUsage) } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 10, weight: .semibold)).foregroundStyle(PanelTheme.secondary)
                        .frame(width: 18, height: 18).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Check now")
            }
        }
    }

    /// "Updated just now", "Updated 4 min. ago".
    static func updated(_ at: Date) -> String {
        if Date().timeIntervalSince(at) < 60 { return "Updated just now" }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return "Updated " + f.localizedString(for: at, relativeTo: Date())
    }
}

struct SessionRow: View {
    let session: PanelSession
    @State private var hover = false

    var body: some View {
        let active = session.busy || session.needsYou
        HStack(spacing: 10) {
            Circle().fill(session.needsYou ? PanelTheme.red : session.busy ? PanelTheme.accent : PanelTheme.track)
                .frame(width: 6, height: 6)
                .frame(width: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.project).font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(active ? PanelTheme.text : PanelTheme.secondary).lineLimit(1).truncationMode(.middle)
                Text(session.line).font(.system(size: 11.5))
                    .foregroundStyle(session.needsYou ? PanelTheme.red : active ? PanelTheme.secondary : PanelTheme.tertiary)
                    .lineLimit(1).truncationMode(.tail)
            }
            Spacer(minLength: 0)
            Image(systemName: "arrow.up.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(PanelTheme.secondary).opacity(hover ? 1 : 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(hover ? PanelTheme.hover : .clear)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
    }
}

/// One usage window: what it is and how much is used, a bar, when it resets.
struct UsageMeter: View {
    let label: String
    let window: UsageWindow

    var body: some View {
        let pct = min(max(window.pct, 0), 100)
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text(label).font(.system(size: 12.5, weight: .medium))
                Spacer(minLength: 8)
                Text("\(Int(pct.rounded()))%").font(.system(size: 12.5, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(pct >= 70 ? PanelTheme.tier(pct) : PanelTheme.text)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(PanelTheme.track)
                    Capsule().fill(PanelTheme.tier(pct)).frame(width: max(6, geo.size.width * pct / 100))
                }
            }
            .frame(height: 6)
            if let r = window.resets {
                Text("Resets \(PanelView.when(r))").font(.system(size: 11)).foregroundStyle(PanelTheme.tertiary)
            }
        }
    }
}

extension PanelView {
    /// "3:10 PM" today, "Fri 9:00 AM" further out.
    static func when(_ d: Date) -> String {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate(d.timeIntervalSinceNow < 20 * 3600 ? "jmm" : "EEE jmm")
        return f.string(from: d)
    }
}

// MARK: - Today

struct TodayTab: View {
    @ObservedObject var model: PanelModel

    var body: some View {
        let st = model.s.stats
        VStack(alignment: .leading, spacing: 0) {
            PanelSection(title: "Today") {
                Card {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .leading), count: 3), alignment: .leading, spacing: 14) {
                        Stat(label: "At the computer", value: "\(st["active"] ?? "–")")
                        Stat(label: "Sitting for", value: "\(st["sitting"] ?? "–")")
                        Stat(label: "Breaks", value: "\(st["breaks"] ?? 0)")
                        Stat(label: "Water", value: "\(st["water"] ?? 0)")
                        Stat(label: "Coffee", value: "\(st["coffee"] ?? 0)")
                        Stat(label: "Energy drinks", value: "\(st["energy"] ?? 0)")
                    }
                    .padding(14)
                }
            }
            PanelSection(title: "Log") {
                TileGrid {
                    Tile(icon: "drop", title: "Water") { model.act(.pet("water")) }
                    Tile(icon: "cup.and.saucer", title: "Coffee") { model.act(.pet("coffee")) }
                    Tile(icon: "bolt", title: "Energy drink") { model.act(.pet("energy")) }
                    Tile(icon: "figure.walk", title: "Going for a walk") { model.act(.pet("walk")) }
                }
            }
        }
    }
}

struct Stat: View {
    let label: String
    let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value).font(.system(size: 17, weight: .semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
            Text(label).font(.system(size: 11)).foregroundStyle(PanelTheme.tertiary).lineLimit(1).minimumScaleFactor(0.85)
        }
    }
}

// MARK: - Play

struct PlayTab: View {
    @ObservedObject var model: PanelModel
    // short names first: they share the row of four
    static let costumes: [(String, String)] = [("Wizard", "wizard"), ("Chef", "chef"), ("TV head", "tv"), ("Party", "party"),
                                               ("Detective", "detective"), ("Headphones", "focus"), ("Sunglasses", "shades")]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PanelSection(title: "Mochi, please") {
                TileGrid {
                    Tile(icon: "hands.clap", title: "Cheer me on") { model.act(.pet("cheer")) }
                    Tile(icon: "chart.bar", title: "How am I doing?") { model.act(.pet("stats")) }
                    Tile(icon: "soccerball", title: "Play ball") { model.act(.pet("ball")) }
                    Tile(icon: "leaf", title: "Water the plant") { model.act(.pet("plant")) }
                    Tile(icon: "macwindow", title: "Sit on my window") { model.act(.pet("perch")) }
                    Tile(icon: "map", title: "Go explore") { model.act(.pet("explore")) }
                }
            }
            PanelSection(title: "Dress up") {
                // four over three, so no costume sits alone on a row
                VStack(spacing: 8) {
                    ForEach([Self.costumes.prefix(4), Self.costumes.dropFirst(4)], id: \.startIndex) { row in
                        HStack(spacing: 8) {
                            ForEach(Array(row), id: \.1) { title, id in
                                Button(title) { model.act(.pet("wear:" + id)) }.buttonStyle(ChipButtonStyle())
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Settings

struct SettingsTab: View {
    @ObservedObject var model: PanelModel
    private var s: PanelState { model.s }
    static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PanelSection(title: "Mochi") {
                Card {
                    VStack(spacing: 0) {
                        Row("Size") {
                            Segmented(options: [("S", 2), ("M", 3), ("L", 4), ("XL", 6)].map { ($0.0, "\($0.1)") }, selected: "\(Int(s.scale))") {
                                model.act(.size(Double($0) ?? 3))
                            }
                        }
                        Hairline()
                        ToggleRow("Roam around", on: s.roam) { model.act(.roam) }
                        Hairline()
                        ToggleRow("React to apps & calls", on: s.appAware) { model.act(.appAware) }
                        Hairline()
                        ToggleRow("Water reminders", on: s.water) { model.act(.water) }
                        Hairline()
                        ToggleRow("Use emoji", on: s.emoji) { model.act(.emoji) }
                        Hairline()
                        ToggleRow("Quiet for an hour", on: s.quiet) { model.act(.quiet) }
                        Hairline()
                        ToggleRow("Open at login", on: s.login) { model.act(.login) }
                        Hairline()
                        Row("Lost Mochi?") { Button("Move to corner") { model.act(.corner) }.buttonStyle(PillButtonStyle()) }
                    }
                }
            }
            PanelSection(title: "Claude Code") {
                Card {
                    VStack(spacing: 0) {
                        Row(s.connected ? "Connected" : s.listening ? "Not connected" : "Can't listen on port \(ClaudeCode.port)",
                            dot: s.connected ? PanelTheme.green : PanelTheme.tertiary) {
                            Button(s.connected ? "Disconnect" : "Connect") { model.act(.connect) }.buttonStyle(PillButtonStyle(prominent: !s.connected))
                        }
                        Hairline()
                        ToggleRow("Act out what Claude is doing", on: s.follow) { model.act(.follow) }
                        Hairline()
                        ToggleRow("Say what Claude is doing", on: s.narrate) { model.act(.narrate) }
                        if s.canCheck {
                            Hairline()
                            ToggleRow("Check usage every 5 minutes", on: s.checkUsage) { model.act(.checkUsage) }
                        }
                    }
                }
            }
            HStack {
                if let v = Self.version { Text("Mochi \(v)").font(.system(size: 11)).foregroundStyle(PanelTheme.tertiary) }
                Spacer()
                Button("Quit Mochi") { model.act(.quit) }.buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(PanelTheme.red)
            }
            .padding(.horizontal, 4)
            .padding(.top, 16)
        }
    }
}

// MARK: - Pieces

/// A titled group: small caps label, an optional accessory on the right, then the content.
struct PanelSection<Content: View, Trailing: View>: View {
    let title: String
    let trailing: Trailing
    let content: Content
    init(title: String, @ViewBuilder trailing: () -> Trailing, @ViewBuilder content: () -> Content) {
        self.title = title
        self.trailing = trailing()
        self.content = content()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center) {
                Text(title.uppercased()).font(.system(size: 10.5, weight: .semibold)).tracking(0.6).foregroundStyle(PanelTheme.tertiary)
                Spacer(minLength: 8)
                trailing
            }
            .frame(minHeight: 18)
            .padding(.horizontal, 4)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 16)
    }
}

extension PanelSection where Trailing == EmptyView {
    init(title: String, @ViewBuilder content: () -> Content) { self.init(title: title, trailing: { EmptyView() }, content: content) }
}

/// A raised rounded surface that groups rows.
struct Card<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(PanelTheme.raised)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// A separator between rows in a card, inset to line up with the row text.
struct Hairline: View {
    var inset: CGFloat = 12
    var body: some View { Rectangle().fill(PanelTheme.hairline).frame(height: 1).padding(.leading, inset) }
}

struct Row<Trailing: View>: View {
    let title: String
    var dot: Color?
    @ViewBuilder let trailing: Trailing
    init(_ title: String, dot: Color? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.dot = dot
        self.trailing = trailing()
    }
    var body: some View {
        HStack(spacing: 8) {
            if let dot { Circle().fill(dot).frame(width: 6, height: 6) }
            Text(title).font(.system(size: 12.5)).lineLimit(1)
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 38)
    }
}

struct ToggleRow: View {
    let title: String
    let on: Bool
    let flip: () -> Void
    init(_ title: String, on: Bool, flip: @escaping () -> Void) {
        self.title = title
        self.on = on
        self.flip = flip
    }
    var body: some View {
        Button(action: flip) {
            Row(title) { Switch(on: on) }.contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct Switch: View {
    let on: Bool
    var body: some View {
        ZStack(alignment: on ? .trailing : .leading) {
            Capsule().fill(on ? PanelTheme.accent : Color.white.opacity(0.14)).frame(width: 30, height: 18)
            Circle().fill(Color.white).frame(width: 14, height: 14).shadow(color: .black.opacity(0.25), radius: 1, y: 0.5).padding(2)
        }
        .animation(.easeOut(duration: 0.15), value: on)
    }
}

struct Segmented: View {
    let options: [(String, String)]
    let selected: String
    let pick: (String) -> Void
    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.1) { title, value in
                Button { pick(value) } label: {
                    Text(title).font(.system(size: 11, weight: .medium))
                        .foregroundStyle(selected == value ? PanelTheme.text : PanelTheme.secondary)
                        .frame(minWidth: 26)
                        .padding(.horizontal, 5).padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(selected == value ? PanelTheme.selected : .clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.white.opacity(0.05)))
    }
}

struct TileGrid<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 2), spacing: 8) { content }
    }
}

/// A button with an icon and a label, two to a row.
struct Tile: View {
    let icon: String
    let title: String
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: icon).font(.system(size: 12, weight: .medium)).foregroundStyle(PanelTheme.accent).frame(width: 16)
                Text(title).font(.system(size: 12)).lineLimit(1).minimumScaleFactor(0.85)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .frame(height: 38)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(hover ? PanelTheme.hover : PanelTheme.raised))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .onHover { hover = $0 }
    }
}

struct EmptyState: View {
    let title: String
    var hint: String?
    var action: (String, () -> Void)?
    var body: some View {
        VStack(spacing: 8) {
            ClaudeLogo().fill(PanelTheme.accent).frame(width: 26, height: 26).padding(.bottom, 4)
            Text(title).font(.system(size: 13, weight: .semibold))
            if let hint {
                Text(hint).font(.system(size: 12)).foregroundStyle(PanelTheme.secondary).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }
            if let action {
                Button(action.0, action: action.1).buttonStyle(PillButtonStyle(prominent: true)).padding(.top, 6)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
        .padding(.top, 30)
        .padding(.bottom, 14)
    }
}

struct IconButton: View {
    let systemName: String
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Image(systemName: systemName).font(.system(size: 11.5, weight: .medium)).foregroundStyle(hover ? PanelTheme.text : PanelTheme.secondary)
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(hover ? PanelTheme.raised : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

/// Dims a little while held.
struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.7 : 1)
    }
}

struct PillButtonStyle: ButtonStyle {
    var prominent = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(prominent ? Color.white : PanelTheme.text)
            .padding(.horizontal, 11)
            .frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(prominent ? PanelTheme.accent : Color.white.opacity(0.08)))
            .opacity(configuration.isPressed ? 0.75 : 1)
            .contentShape(Rectangle())
    }
}

struct ChipButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(maxWidth: .infinity)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(configuration.isPressed ? PanelTheme.hover : PanelTheme.raised))
            .contentShape(Rectangle())
    }
}

/// Mochi in pixels, for the panel's header.
struct MochiGlyph: View {
    static let rows = ["..........", ".########.", "##########", "##e####e##", "##e####e##", "##########", "##########", ".########.", ".#.#..#.#.", ".#.#..#.#."]
    var body: some View {
        Canvas { ctx, size in
            let px = min(size.width, size.height) / 10
            for (y, row) in Self.rows.enumerated() {
                for (x, c) in row.enumerated() where c != "." {
                    ctx.fill(Path(CGRect(x: CGFloat(x) * px, y: CGFloat(y) * px, width: px, height: px)), with: .color(c == "e" ? Color(hex: 0x1F1A1C) : PanelTheme.mochi))
                }
            }
        }
    }
}

/// Claude's logo, from its SVG (viewBox 0 0 256 257), scaled to fit.
struct ClaudeLogo: Shape {
    static let d = "m50.228 170.321 50.357-28.257.843-2.463-.843-1.361h-2.462l-8.426-.518-28.775-.778-24.952-1.037-24.175-1.296-6.092-1.297L0 125.796l.583-3.759 5.12-3.434 7.324.648 16.202 1.101 24.304 1.685 17.629 1.037 26.118 2.722h4.148l.583-1.685-1.426-1.037-1.101-1.037-25.147-17.045-27.22-18.017-14.258-10.37-7.713-5.25-3.888-4.925-1.685-10.758 7-7.713 9.397.649 2.398.648 9.527 7.323 20.35 15.75L94.817 91.9l3.889 3.24 1.555-1.102.195-.777-1.75-2.917-14.453-26.118-15.425-26.572-6.87-11.018-1.814-6.61c-.648-2.723-1.102-4.991-1.102-7.778l7.972-10.823L71.42 0 82.05 1.426l4.472 3.888 6.61 15.101 10.694 23.786 16.591 32.34 4.861 9.592 2.592 8.879.973 2.722h1.685v-1.556l1.36-18.211 2.528-22.36 2.463-28.776.843-8.1 4.018-9.722 7.971-5.25 6.222 2.981 5.12 7.324-.713 4.73-3.046 19.768-5.962 30.98-3.889 20.739h2.268l2.593-2.593 10.499-13.934 17.628-22.036 7.778-8.749 9.073-9.657 5.833-4.601h11.018l8.1 12.055-3.628 12.443-11.342 14.388-9.398 12.184-13.48 18.147-8.426 14.518.778 1.166 2.01-.194 30.46-6.481 16.462-2.982 19.637-3.37 8.88 4.148.971 4.213-3.5 8.62-20.998 5.184-24.628 4.926-36.682 8.685-.454.324.519.648 16.526 1.555 7.065.389h17.304l32.21 2.398 8.426 5.574 5.055 6.805-.843 5.184-12.962 6.611-17.498-4.148-40.83-9.721-14-3.5h-1.944v1.167l11.666 11.406 21.387 19.314 26.767 24.887 1.36 6.157-3.434 4.86-3.63-.518-23.526-17.693-9.073-7.972-20.545-17.304h-1.36v1.814l4.73 6.935 25.017 37.59 1.296 11.536-1.814 3.76-6.481 2.268-7.13-1.297-14.647-20.544-15.1-23.138-12.185-20.739-1.49.843-7.194 77.448-3.37 3.953-7.778 2.981-6.48-4.925-3.436-7.972 3.435-15.749 4.148-20.544 3.37-16.333 3.046-20.285 1.815-6.74-.13-.454-1.49.194-15.295 20.999-23.267 31.433-18.406 19.702-4.407 1.75-7.648-3.954.713-7.064 4.277-6.286 25.47-32.405 15.36-20.092 9.917-11.6-.065-1.686h-.583L44.07 198.125l-12.055 1.555-5.185-4.86.648-7.972 2.463-2.593 20.35-13.999-.064.065Z"
    static let shape = parse(d)

    func path(in rect: CGRect) -> Path {
        let k = min(rect.width / 256, rect.height / 257)
        let t = CGAffineTransform(translationX: rect.midX - 128 * k, y: rect.midY - 128.5 * k).scaledBy(x: k, y: k)
        return Self.shape.applying(t)
    }

    /// Just enough of SVG path syntax for this logo: M L H V C Z, absolute and relative, with implicit repeats.
    static func parse(_ d: String) -> Path {
        let re = try! NSRegularExpression(pattern: #"[MmLlHhVvCcZz]|-?(?:\d+\.?\d*|\.\d+)"#)
        let toks = re.matches(in: d, range: NSRange(d.startIndex..., in: d)).map { String(d[Range($0.range, in: d)!]) }
        var p = Path(), i = 0, cmd: Character = "M", cur = CGPoint.zero, start = CGPoint.zero
        func num() -> CGFloat { defer { i += 1 }; return CGFloat(Double(toks[i]) ?? 0) }
        while i < toks.count {
            if let c = toks[i].first, c.isLetter {
                cmd = c
                i += 1
                if c == "z" || c == "Z" { p.closeSubpath(); cur = start; continue }
            }
            let rel = cmd.isLowercase
            func pt() -> CGPoint { let x = num(), y = num(); return rel ? CGPoint(x: cur.x + x, y: cur.y + y) : CGPoint(x: x, y: y) }
            switch cmd.lowercased() {
            case "m": cur = pt(); start = cur; p.move(to: cur); cmd = rel ? "l" : "L"   // further pairs are lines
            case "l": cur = pt(); p.addLine(to: cur)
            case "h": let x = num(); cur.x = rel ? cur.x + x : x; p.addLine(to: cur)
            case "v": let y = num(); cur.y = rel ? cur.y + y : y; p.addLine(to: cur)
            case "c": let c1 = pt(), c2 = pt(), end = pt(); p.addCurve(to: end, control1: c1, control2: c2); cur = end
            default: i += 1
            }
        }
        return p
    }
}

// MARK: - The window it lives in

/// A borderless floating panel, not an NSPopover or NSMenu: no system chrome, no arrow, just the card.
final class PanelController {
    let model = PanelModel()
    private var window: NSPanel?
    private var host: NSHostingView<PanelView>?
    private var monitors: [Any] = []
    private var timer: Timer?
    var refresh: () -> PanelState = { PanelState() }
    var isOpen: Bool { window?.isVisible == true }

    /// Opens next to a point (where you right-clicked Mochi), kept on that screen.
    func show(at point: NSPoint) {
        close()
        model.s = refresh()
        let host = NSHostingView(rootView: PanelView(model: model))
        let size = host.fittingSize
        host.frame = NSRect(origin: .zero, size: size)
        let w = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        w.contentView = host
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = true
        w.level = .statusBar
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        w.setFrameOrigin(origin(size, point))
        w.alphaValue = 0
        w.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            w.animator().alphaValue = 1
        }
        window = w
        self.host = host
        model.resized = { [weak self] in self?.fit() }

        // nothing closes a borderless panel by itself: a click anywhere else does
        let outside: (NSEvent) -> Void = { [weak self] e in
            guard let self, e.window !== self.window else { return }
            self.close()
        }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: outside) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { outside($0); return $0 }) { monitors.append(m) }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.update() }
    }

    /// New numbers, and maybe a new height.
    func update() {
        guard window != nil else { return }
        model.s = refresh()
        fit()
    }

    /// Grows or shrinks to fit what's showing, keeping the top edge where it is.
    func fit() {
        DispatchQueue.main.async { [weak self] in
            guard let w = self?.window, let host = self?.host else { return }
            let size = host.fittingSize
            guard abs(size.height - w.frame.height) > 0.5 else { return }
            w.setFrame(NSRect(x: w.frame.minX, y: w.frame.maxY - size.height, width: size.width, height: size.height), display: true)
            w.invalidateShadow()
        }
    }

    func close() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        timer?.invalidate()
        timer = nil
        window?.orderOut(nil)
        window = nil
        host = nil
    }

    private func origin(_ size: NSSize, _ at: NSPoint) -> NSPoint {
        var p = NSPoint(x: at.x + 8, y: at.y - size.height + 20)
        if let v = (NSScreen.screens.first { $0.frame.contains(at) } ?? NSScreen.main)?.visibleFrame {
            p.x = min(max(p.x, v.minX + 8), v.maxX - size.width - 8)
            p.y = min(max(p.y, v.minY + 8), v.maxY - size.height - 8)
        }
        return p
    }
}
