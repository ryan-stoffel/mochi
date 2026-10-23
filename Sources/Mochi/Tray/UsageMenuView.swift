import Charts
import SwiftUI
import MochiCore

/// What the dropdown is showing: which provider's tab, and whether its history is open.
@MainActor
final class MenuState: ObservableObject {
    @Published var provider: String
    @Published var details = false
    @Published var chart: ChartMode = .session

    init(provider: String) { self.provider = provider }
}

/// The usage dropdown: the provider you picked, its limits as bars, a tab for each provider, and Settings and Quit
/// at the bottom like any menu.
struct UsageMenuView: View {
    @ObservedObject var usage: UsageService
    @ObservedObject var state: MenuState
    let onSettings: () -> Void

    private var provider: Provider { Provider.byID(state.provider) ?? Provider.all[0] }
    private var tabs: [Provider] { Provider.all.filter { Settings.shared.isEnabled($0.id) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                header
                if tabs.count > 1 { ProviderTabs(usage: usage, providers: tabs, selected: $state.provider) }
                content
            }
            .padding(14)
            Divider().padding(.horizontal, 14)
            VStack(spacing: 0) {
                MenuRow(title: "Settings…", shortcut: ",", action: onSettings)
                MenuRow(title: "Quit Mochi", shortcut: "q") { NSApp.terminate(nil) }
            }
            .padding(5)
        }
        .frame(width: 320)
        .fixedSize(horizontal: false, vertical: true)
        .noFocusRings()
        .animation(.easeOut(duration: 0.18), value: state.provider)
        .animation(.easeOut(duration: 0.18), value: state.details)
    }

    private var header: some View {
        HStack(spacing: 10) {
            ProviderLogo(id: provider.id, size: 26)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(provider.name).font(.system(size: 14, weight: .semibold))
                    if let plan = usage.plan(provider.id) {
                        Text(plan).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                    }
                }
                Text(usage.freshness(provider.id))
                    .font(.system(size: 11))
                    .foregroundStyle(usage.isStale(provider.id) ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    .help(usage.isStale(provider.id) ? "These numbers haven't refreshed in a while." : "")
            }
            Spacer(minLength: 0)
            Button { Task { await usage.refreshProvider(provider.id) } } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .semibold))
                    .rotationEffect(.degrees(usage.isRefreshing ? 360 : 0))
                    .animation(usage.isRefreshing ? .linear(duration: 0.9).repeatForever(autoreverses: false) : .default, value: usage.isRefreshing)
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help("Check now")
        }
    }

    @ViewBuilder private var content: some View {
        let meters = usage.meters(provider.id)
        if let blocker = usage.blocker(provider.id) {
            BlockerView(blocker: blocker) { usage.perform($0, for: provider.id) }
        } else {
            VStack(alignment: .leading, spacing: 12) {
                if let banner = usage.banner(provider.id) {
                    Label(banner, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11)).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(meters) { MeterRow(meter: $0, provider: provider) }
                DisclosureButton(open: $state.details)
                if state.details { details }
            }
        }
    }

    @ViewBuilder private var details: some View {
        VStack(alignment: .leading, spacing: 10) {
            HistoryChart(provider: provider, mode: $state.chart)
            if provider.id == "claude" { ClaudeExtras(usage: usage.claude) }
        }
        .transition(.opacity)
    }
}

/// A tab per provider: its logo, and a dot for how it's doing.
private struct ProviderTabs: View {
    @ObservedObject var usage: UsageService
    let providers: [Provider]
    @Binding var selected: String

    var body: some View {
        HStack(spacing: 2) {
            ForEach(providers) { p in
                Button { selected = p.id } label: {
                    HStack(spacing: 5) {
                        ProviderLogo(id: p.id, size: 15)
                        if let pct = usage.primaryPct(p.id), usage.status(p.id).state == .loggedIn {
                            Text("\(pct)%").font(.system(size: 11, weight: .medium)).monospacedDigit()
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 28)
                    .background(selected == p.id ? AnyShapeStyle(.background.opacity(0.9)) : AnyShapeStyle(.clear),
                                in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .shadow(color: .black.opacity(selected == p.id ? 0.12 : 0), radius: 1, y: 0.5)
                    .overlay(alignment: .topTrailing) { dot(p).offset(x: -5, y: 5) }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(p.name)
                .accessibilityLabel(p.name)
            }
        }
        .padding(2)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    @ViewBuilder private func dot(_ p: Provider) -> some View {
        let s = usage.status(p.id).state
        if case .error = s {
            Circle().fill(.red).frame(width: 5, height: 5)
        } else if let pct = usage.primaryPct(p.id), pct >= 75, s == .loggedIn {
            Circle().fill(pct >= 90 ? Color.red : .orange).frame(width: 5, height: 5)
        }
    }
}

/// One limit: its name and %, a bar, when it resets.
struct MeterRow: View {
    let meter: Meter
    let provider: Provider

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(meter.label).font(.system(size: 12, weight: .medium))
                Spacer()
                Text("\(meter.pct)%").font(.system(size: 12, weight: .semibold)).monospacedDigit()
            }
            UsageBar(pct: meter.pct, tint: Theme.tint(meter.pct, provider))
            if meter.resets != nil || meter.note != nil {
                HStack {
                    if let r = meter.resets { Text(r) }
                    Spacer()
                    if let n = meter.note { Text(n) }
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct UsageBar: View {
    let pct: Int
    let tint: Color

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(tint).frame(width: pct > 0 ? max(6, g.size.width * CGFloat(min(pct, 100)) / 100) : 0)
            }
        }
        .frame(height: 6)
        .animation(.easeOut(duration: 0.3), value: pct)
    }
}

private struct BlockerView: View {
    let blocker: Blocker
    let perform: (Blocker.Fix) -> Void

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: blocker.symbol)
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(blocker.isError ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                .padding(.bottom, 2)
            Text(blocker.title).font(.system(size: 13, weight: .semibold)).multilineTextAlignment(.center)
            if let d = blocker.detail {
                Text(d).font(.system(size: 11)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            if let fix = blocker.fix {
                Button(fix.title) { perform(fix) }.controlSize(.small).padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
    }
}

private struct DisclosureButton: View {
    @Binding var open: Bool

    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: 4) {
                Text(open ? "Hide History" : "Show History")
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).rotationEffect(.degrees(open ? 90 : 0))
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// The last day (or week) in 24 slices, the highest reading in each.
private struct HistoryChart: View {
    let provider: Provider
    @Binding var mode: ChartMode

    var body: some View {
        let bars = points()
        VStack(alignment: .leading, spacing: 6) {
            Picker("", selection: $mode) {
                ForEach(ChartMode.allCases, id: \.self) { Text($0 == .session ? "Last Day" : "Last Week").tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            if bars.allSatisfy({ $0.value == nil }) {
                Text("No history yet. It fills in as Mochi checks.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 64)
            } else {
                Chart(bars, id: \.index) { b in
                    BarMark(x: .value("Time", b.index), y: .value("Used", b.value ?? 0), width: .ratio(0.7))
                        .foregroundStyle(Theme.tint(b.value ?? 0, provider))
                        .cornerRadius(2)
                }
                .chartYScale(domain: 0...100)
                .chartXAxis(.hidden)
                .chartYAxis {
                    AxisMarks(values: [0, 50, 100]) { v in
                        AxisGridLine()
                        AxisValueLabel { Text("\(v.as(Int.self) ?? 0)%").font(.system(size: 9)) }
                    }
                }
                .frame(height: 72)
            }
        }
    }

    private func points() -> [(index: Int, value: Int?)] {
        let now = Date(), window = mode.window, slice = window / 24
        var bars = [Int?](repeating: nil, count: 24)
        for p in HistoryStore.shared.points(for: provider.id, within: window, now: now) {
            guard let v = mode.value(p) else { continue }
            let i = min(23, max(0, Int((window - now.timeIntervalSince(p.timestamp)) / slice)))
            bars[i] = max(bars[i] ?? 0, v)
        }
        return bars.enumerated().map { ($0.offset, $0.element) }
    }
}

/// What Claude Code's own screens add, when it was read from them: a promotion, skill and MCP usage, all-time stats.
private struct ClaudeExtras: View {
    let usage: ClaudeUsage

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let promo = usage.weeklyPromo { Label(promo, systemImage: "gift").font(.system(size: 11)).foregroundStyle(.secondary) }
            ForEach(rows, id: \.0) { name, value in
                HStack {
                    Text(name).foregroundStyle(.secondary)
                    Spacer()
                    Text(value).monospacedDigit()
                }
                .font(.system(size: 11))
            }
        }
    }

    private var rows: [(String, String)] {
        var out: [(String, String)] = []
        for s in usage.skills ?? [] { out.append(("Skill: \(s.name)", "\(s.pct)%")) }
        for m in usage.mcpServers ?? [] { out.append(("MCP: \(m.name)", "\(m.pct)%")) }
        if let st = usage.stats {
            if let v = st.favoriteModel { out.append(("Favorite model", v)) }
            if let v = st.totalTokens { out.append(("Total tokens", v)) }
            if let v = st.sessions { out.append(("Sessions", "\(v)")) }
            if let v = st.activeDays { out.append(("Active days", "\(v) of \(st.totalDays ?? 0)")) }
            if let v = st.currentStreak { out.append(("Current streak", v)) }
        }
        return out
    }
}

/// A row like a menu item's: highlights in the accent colour under the pointer, with its shortcut on the right.
private struct MenuRow: View {
    let title: String
    let shortcut: Character
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title)
                Spacer()
                Text("⌘\(String(shortcut).uppercased())").foregroundStyle(hover ? AnyShapeStyle(.white.opacity(0.8)) : AnyShapeStyle(.tertiary))
            }
            .font(.system(size: 13))
            .foregroundStyle(hover ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .padding(.horizontal, 9)
            .frame(height: 24)
            .background(hover ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(KeyEquivalent(shortcut), modifiers: .command)
        .onHover { hover = $0 }
    }
}
