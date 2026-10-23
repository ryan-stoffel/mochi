import SwiftUI
import MochiCore

/// The notch, both states in one view: at rest a black bar fused with the notch, the selected provider's logo on its
/// left and its usage on its right; open, the bar grows into an island under the notch with that provider's limits
/// as rings and a tab for each provider. `NotchController` decides when it's open (`NotchState`); this only animates.
struct IslandShellView: View {
    @ObservedObject var usage: UsageService
    @ObservedObject var state: NotchState

    /// The same provider the menu bar icon and its dropdown show.
    @State private var provider = UsageMenu.selected.id

    var body: some View {
        let panel = NotchGeometry.expandedSize(), bar = NotchGeometry.compactSize(), island = NotchGeometry.islandSize()
        let open = state.open
        ZStack(alignment: .top) {
            BumpShape(topCornerRadius: open ? 14 : 6, bottomCornerRadius: open ? 28 : bar.height / 2)
                .fill(Color.black)
                .frame(width: open ? island.width : bar.width, height: open ? island.height : bar.height)
                .shadow(color: .black.opacity(open ? 0.4 : 0), radius: 14, y: 6)

            Flanks(usage: usage, provider: provider)
                .frame(width: bar.width, height: bar.height)
                .opacity(open ? 0 : 1)
                .scaleEffect(open ? 0.8 : 1)

            if open {
                IslandContent(usage: usage, provider: $provider)
                    .padding(.top, bar.height + 8)
                    .padding(.horizontal, 30)
                    .frame(width: island.width, height: island.height, alignment: .top)
                    .transition(.opacity.combined(with: .scale(scale: 0.92, anchor: .top)))
            }
        }
        .frame(width: panel.width, height: panel.height, alignment: .top)
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .animation(.island(open: open), value: open)
        .contextMenu {
            Button("Refresh") { Task { await usage.refresh() } }
            Button("Settings…") { NotificationCenter.default.post(name: .openSettingsRequested, object: nil) }
            Divider()
            Button("Quit Mochi") { NSApp.terminate(nil) }
        }
        .onChange(of: provider) { id in
            Settings.shared.selectedProvider = id
            Task { await usage.freshen(id) }
        }
        .onChange(of: state.open) { open in
            guard open else { return }
            provider = UsageMenu.selected.id
            Task { await usage.freshen(provider) }
        }
    }
}

/// At rest: the logo beside the notch on the left, the headline % on the right.
private struct Flanks: View {
    @ObservedObject var usage: UsageService
    let provider: String

    var body: some View {
        HStack {
            ProviderLogo(id: provider, size: 15)
            Spacer()
            label
        }
        .padding(.horizontal, 20)
    }

    @ViewBuilder private var label: some View {
        if let pct = usage.primaryPct(provider), usage.status(provider).state == .loggedIn || provider == "claude" {
            Text("\(pct)%")
                .font(.system(size: 13, weight: .semibold, design: .rounded)).monospacedDigit()
                .foregroundStyle(pct >= 90 ? Color.red : pct >= 75 ? .orange : .white)
        } else {
            Text(usage.status(provider).shortLabel)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.55))
        }
    }
}

/// Open: the provider and how fresh its numbers are, a ring for each limit, and the provider tabs.
private struct IslandContent: View {
    @ObservedObject var usage: UsageService
    @Binding var provider: String

    private var p: Provider { Provider.byID(provider) ?? Provider.all[0] }

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 7) {
                ProviderLogo(id: p.id, size: 16)
                Text(p.name).font(.system(size: 13, weight: .semibold))
                if let plan = usage.plan(p.id) {
                    Text(plan).font(.system(size: 10, weight: .medium)).foregroundStyle(.white.opacity(0.6))
                }
                Spacer()
                Text(usage.freshness(p.id)).font(.system(size: 10)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
            }
            Group {
                if let blocker = usage.blocker(p.id) {
                    HStack(spacing: 10) {
                        Image(systemName: blocker.symbol).font(.system(size: 20)).foregroundStyle(blocker.isError ? Color.red : .white.opacity(0.6))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(blocker.title).font(.system(size: 12, weight: .semibold))
                            if let d = blocker.detail { Text(d).font(.system(size: 10)).foregroundStyle(.white.opacity(0.55)).lineLimit(2) }
                        }
                        Spacer()
                        if let fix = blocker.fix { Button(fix.title) { usage.perform(fix, for: p.id) }.controlSize(.small) }
                    }
                } else {
                    HStack(alignment: .top, spacing: 14) {
                        ForEach(usage.meters(p.id).prefix(4)) { m in RingMeter(meter: m, provider: p).frame(maxWidth: .infinity) }
                    }
                }
            }
            .frame(height: 82)
            HStack(spacing: 4) {
                ForEach(Provider.all.filter { Settings.shared.isEnabled($0.id) }) { other in
                    Button { provider = other.id } label: {
                        ProviderLogo(id: other.id, size: 14)
                            .frame(width: 34, height: 22)
                            .background(provider == other.id ? Color.white.opacity(0.16) : .clear, in: Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help(other.name)
                }
                Spacer()
                Button { Task { await usage.refreshProvider(p.id) } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain).help("Check now")
                Button { NotificationCenter.default.post(name: .openSettingsRequested, object: nil) } label: { Image(systemName: "gearshape") }
                    .buttonStyle(.plain).help("Settings")
                    .padding(.leading, 8)
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.white.opacity(0.75))
        }
    }
}

/// One limit as a ring: % inside, its name and when it resets under it.
private struct RingMeter: View {
    let meter: Meter
    let provider: Provider

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                Circle().stroke(Color.white.opacity(0.14), lineWidth: 5)
                Circle()
                    .trim(from: 0, to: CGFloat(min(meter.pct, 100)) / 100)
                    .stroke(Theme.tint(meter.pct, provider), style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("\(meter.pct)%").font(.system(size: 12, weight: .semibold, design: .rounded)).monospacedDigit()
            }
            .frame(width: 44, height: 44)
            .animation(.easeOut(duration: 0.4), value: meter.pct)
            Text(meter.label).font(.system(size: 11, weight: .medium))
            if let r = meter.resets {
                Text(r.replacingOccurrences(of: "Resets ", with: "").replacingOccurrences(of: "at ", with: ""))
                    .font(.system(size: 9.5)).foregroundStyle(.white.opacity(0.5)).lineLimit(1).minimumScaleFactor(0.8)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
