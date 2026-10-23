import SwiftUI
import MochiCore
import AppKit

/// The fan's geometry. Layers stack outward from the hub as a chain: each layer's inner radius is the previous one's
/// outer edge plus a margin, so growing one (a bigger hub, a thicker band) re-flows everything outside it instead of
/// letting layers overlap.
struct RingGeometry {
    /// Gap between consecutive layers (and between the hub and the first layer).
    static let layerMargin: CGFloat = 8

    // The full 180° (nearly edge to edge), so every layer gets as much angular room per item as possible.
    static let arcStart: Double = 3
    static let arcEnd: Double = 177
    static let gapDeg: Double = 4
    static let selectedWidthDeg: Double = 48
    /// Caps how wide a lone unselected wedge can balloon in a small fan (Antigravity's two stats).
    static let maxUnselectedWidthDeg: Double = 55

    // MARK: Hub
    static let hubRadius: CGFloat = 35

    // MARK: Layer 1 — the provider ring, revealed by resting on the hub
    static let providerLayerThickness: CGFloat = 46
    static var providerRInner: CGFloat { hubRadius + layerMargin }
    static var providerROuter: CGFloat { providerRInner + providerLayerThickness }

    // MARK: Layer 2 — the active provider's stats, the selected one taller to show its value
    static let statsLayerThickness: CGFloat = 50
    static let statsSelectedExtra: CGFloat = 16
    static var rInner: CGFloat { providerROuter + layerMargin }
    static var rOuter: CGFloat { rInner + statsLayerThickness }
    static var rOuterSelected: CGFloat { rOuter + statsSelectedExtra }

    // Each stat's usage meter: a band of 20 blocks just outside its wedge.
    static let meterGap: CGFloat = 3
    static let meterThickness: CGFloat = 8

    // MARK: Layer 3 — the selected stat's detail (reset time, spend...), flared out past its meter
    static let infoLayerThickness: CGFloat = 30
    static var infoRInner: CGFloat { rOuterSelected + meterGap + meterThickness + 6 }
    static var infoROuter: CGFloat { infoRInner + infoLayerThickness }

    /// Derived from the outermost layer, so the panel (`NotchGeometry.expandedSize`) always has room for the chain:
    /// the fan's lowest point is straight below the hub, `infoROuter` down, plus its pixel shadow.
    static var width: CGFloat { (infoROuter + 20) * 2 }
    static var height: CGFloat { infoROuter + 8 }
}

struct WedgeLayout: Identifiable {
    let bubble: Bubble
    let index: Int
    let isSelected: Bool
    let startDeg: Double
    let endDeg: Double
    let rInner: CGFloat
    let rOuter: CGFloat
    var id: String { bubble.id }

    /// `radiusFraction` picks where between `rInner` (0) and `rOuter` (1)
    /// the content sits. Defaults to the middle, but selected stat wedges
    /// pull this in toward the inner edge — their curved label lives out
    /// near `rOuter`, so the icon+value block needs to stay well clear of
    /// it instead of both fighting over the same middle ground.
    func contentPos(cx: CGFloat, cy: CGFloat, radiusFraction: CGFloat = 0.5) -> CGPoint {
        let r = rInner + (rOuter - rInner) * radiusFraction
        return .onArc(cx: cx, cy: cy, r: r, deg: (startDeg + endDeg) / 2)
    }

    /// Same tangent-orientation convention `CurvedText` uses for its
    /// middle character (see its own doc comment: "up" points inward,
    /// toward the hub, which is what keeps text right-side up along the
    /// bottom half of the circle) — so an icon tilts to match the curved
    /// label sitting right next to it instead of standing flat against it.
    var tangentRotationDeg: Double { (startDeg + endDeg) / 2 - 90 }

    /// The widest a label can be before it would start overlapping a
    /// neighboring wedge — the chord length at the *outer* radius (the
    /// widest point of the slice), so text sizes to its own wedge
    /// regardless of how many items are sharing the arc or how tight the
    /// spacing gets.
    var labelMaxWidth: CGFloat {
        let halfAngleRad = (endDeg - startDeg) / 2 * .pi / 180
        return 2 * rOuter * sin(halfAngleRad)
    }

    /// How much room a curved line of text has at radius `r` before it runs into the next wedge.
    func arcLength(at r: CGFloat, inset: CGFloat = 8) -> CGFloat {
        max(0, r * CGFloat((endDeg - startDeg) * .pi / 180) - inset)
    }
}

func buildWedges(bubbles: [Bubble], selectedIdx: Int, rInner: CGFloat, rOuterBase: CGFloat, rOuterSelected: CGFloat) -> [WedgeLayout] {
    let g = RingGeometry.self
    let n = Double(bubbles.count)
    guard n > 0 else { return [] }
    let span = g.arcEnd - g.arcStart
    let hasSelection = rOuterSelected > rOuterBase

    guard hasSelection else {
        // No highlighted member (the provider ring) — every item just
        // divides the entire span evenly. Always exactly 3 items in
        // practice, so this always fills the arc.
        let evenWidth = (span - g.gapDeg * (n - 1)) / n
        var cursor = g.arcStart
        return bubbles.enumerated().map { i, b in
            let start = cursor
            let end = start + evenWidth
            cursor = end + g.gapDeg
            return WedgeLayout(bubble: b, index: i, isSelected: false, startDeg: start, endDeg: end,
                                rInner: rInner, rOuter: rOuterBase)
        }
    }

    // With a highlighted member, the selected wedge is anchored to the
    // arc's exact center angle — not "whichever array index happens to be
    // in the middle" — so it stays visually centered whether the fan has
    // an even or odd item count. An odd count with the selected item at
    // the true middle index (Claude's 5-stat fan) makes those two things
    // coincide, which is why that layout is unchanged from before; an even
    // count (Antigravity's 2 stats) has no middle index at all, so
    // centering "the whole block" like before left the selection off to
    // one side instead of centered.
    let selWidth = g.selectedWidthDeg
    // Capped so a small fan's leftover space can't balloon a single
    // unselected wedge (Claude's fan never hits this cap). A hair under
    // the true max (half the arc, minus half the selected wedge and one
    // gap) so a lone neighbor can't overshoot the arc's edge.
    let naturalEvenWidth = n > 1 ? (span - selWidth - g.gapDeg * (n - 1)) / (n - 1) : span
    let evenWidth = min(naturalEvenWidth, g.maxUnselectedWidthDeg)

    let centerDeg = (g.arcStart + g.arcEnd) / 2
    var spans = [Int: (Double, Double)]()
    spans[selectedIdx] = (centerDeg - selWidth / 2, centerDeg + selWidth / 2)

    var leftCursor = centerDeg - selWidth / 2 - g.gapDeg
    if selectedIdx > 0 {
        for i in stride(from: selectedIdx - 1, through: 0, by: -1) {
            let end = leftCursor
            let start = end - evenWidth
            spans[i] = (start, end)
            leftCursor = start - g.gapDeg
        }
    }

    var rightCursor = centerDeg + selWidth / 2 + g.gapDeg
    let lastIdx = Int(n) - 1
    if selectedIdx < lastIdx {
        for i in (selectedIdx + 1)...lastIdx {
            let start = rightCursor
            let end = start + evenWidth
            spans[i] = (start, end)
            rightCursor = end + g.gapDeg
        }
    }

    return bubbles.enumerated().map { i, b in
        let isSelected = i == selectedIdx
        let (start, end) = spans[i]!
        return WedgeLayout(bubble: b, index: i, isSelected: isSelected, startDeg: start, endDeg: end,
                            rInner: rInner, rOuter: isSelected ? rOuterSelected : rOuterBase)
    }
}


/// The hub and the wedge fan hanging from the notch, drawn like Mochi's panels: paper and ink, hard pixel shadows,
/// 20-block meters, Jersey 15. `cy` is the bar's bottom edge, so the hub's top half tucks up into the bar.
///
/// Click the hub to refresh, rest on it to switch providers (`ringOpen`, decided by `NotchHover`), click a stat to
/// turn the wheel to it, right-click the hub for the usage dropdown.
struct RingView: View {
    @ObservedObject var usage: UsageService
    let ringOpen: Bool
    @Binding var currentProviderIdx: Int
    let onSync: () -> Void

    // By id, not index: the fan reorders (the selected stat turns to the middle) and its length changes with
    // whichever stats have data. Nil until you pick one: then it's the provider's headline stat.
    @State private var pickedStatID: String?

    private var activeProvider: Provider { Provider.all[currentProviderIdx] }
    private var activeStatus: ProviderStatus { usage.status(activeProvider.id) }
    private let cx: CGFloat = RingGeometry.width / 2
    private let cy: CGFloat = 0

    /// The active provider's stats, if it has any yet. One that doesn't gets a single wedge saying why instead.
    private var outerBubbles: [Bubble] {
        var metrics: [Bubble]
        switch activeProvider.id {
        case "claude":
            metrics = Bubble.claudeMetrics(usage.claude)
        case "antigravity" where activeStatus.state == .loggedIn:
            metrics = usage.antigravity.map { Bubble.antigravityMetrics($0, color: activeProvider.color) } ?? []
        case "codex" where activeStatus.state == .loggedIn:
            metrics = usage.codex.map { Bubble.codexMetrics($0, color: activeProvider.color) } ?? []
        case "cursor" where activeStatus.state == .loggedIn:
            metrics = usage.cursor.map { Bubble.cursorMetrics($0, color: activeProvider.color) } ?? []
        default:
            metrics = []
        }
        // Claude with nothing fetched yet has two empty stats; show why there's nothing instead.
        guard metrics.contains(where: { $0.pct != nil }) else { return [] }
        // Keep the fan odd-sized, so there's always one middle wedge to centre the selection on.
        if metrics.count % 2 == 0 {
            metrics.append(Bubble.syncedBubble(lastRefreshed: usage.lastRefreshed, color: activeProvider.color))
        }
        return centeredOrder(metrics, selected: selectedID(in: metrics))
    }

    /// The stat in the middle: the one you picked, else the provider's headline (each provider lists it first:
    /// Claude's session, Codex's and Antigravity's 5-hour, Cursor's included).
    private func selectedID(in metrics: [Bubble]) -> String? {
        pickedStatID.flatMap { id in metrics.contains { $0.id == id } ? id : nil } ?? metrics.first?.id
    }

    /// Each provider's stats in a fixed circular order, so every stat keeps the same neighbours whichever is centred.
    /// [farRight, ..., farLeft], the order `buildWedges` lays them out in.
    private var activeStatOrder: [String] {
        switch activeProvider.id {
        case "claude": return ["stats", "credits", "session", "weekly", "skills", "synced"]
        case "antigravity": return ["fiveHour", "weekly", "synced"]
        case "codex": return ["fiveHour", "weekly", "monthly", "synced"]
        case "cursor": return ["included", "auto", "api", "synced"]
        default: return []
        }
    }

    /// Turns the wheel so the selected stat sits in the middle slot. Stats the order doesn't know (a Cursor plan with
    /// other categories) still get a slot, at the end.
    private func centeredOrder(_ bubbles: [Bubble], selected: String?) -> [Bubble] {
        let byID = Dictionary(bubbles.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let known = activeStatOrder.filter { byID[$0] != nil }
        let available = known + bubbles.map(\.id).filter { !known.contains($0) }
        guard !available.isEmpty else { return [] }
        let n = available.count
        let centerSlot = (n - 1) / 2
        let selIdx = selected.flatMap { available.firstIndex(of: $0) } ?? centerSlot
        return (0..<n).map { offset in byID[available[((selIdx - centerSlot + offset) % n + n) % n]]! }
    }

    var body: some View {
        let g = RingGeometry.self
        let allProviderBubbles = Bubble.providers(claude: usage.claude, providerStatus: usage.providers,
                                                  antigravity: usage.antigravity, codex: usage.codex, cursor: usage.cursor)
        let outer = outerBubbles
        let hasStats = !outer.isEmpty
        let outerSelectedIdx = (outer.count - 1) / 2
        let outerWedges: [WedgeLayout] = hasStats
            ? buildWedges(bubbles: outer, selectedIdx: outerSelectedIdx,
                          rInner: g.rInner, rOuterBase: g.rOuter, rOuterSelected: g.rOuterSelected)
            : [centeredWedge(allProviderBubbles[currentProviderIdx], rInner: g.rInner, rOuter: g.rOuterSelected)]

        // The selected stat's detail, sharing its wedge's angles so it reads as that wedge flaring further out.
        let infoWedge: WedgeLayout? = hasStats
            ? outerWedges.first(where: { $0.isSelected && $0.bubble.sub != nil }).map {
                WedgeLayout(bubble: $0.bubble, index: $0.index, isSelected: true, startDeg: $0.startDeg, endDeg: $0.endDeg,
                            rInner: g.infoRInner, rOuter: g.infoROuter)
            }
            : nil

        let innerWedges = ringOpen
            ? buildWedges(bubbles: allProviderBubbles.enumerated().filter { $0.offset != currentProviderIdx }.map(\.element),
                          selectedIdx: -1, rInner: g.providerRInner, rOuterBase: g.providerROuter, rOuterSelected: g.providerROuter)
            : []

        ZStack {
            ForEach(outerWedges) { w in
                wedgeShape(w, meter: hasStats)
                    .onTapGesture { if hasStats { selectOuter(w) } else { handleStatusTap() } }
                    .help(hasStats ? "" : activeStatus.message(installHint: activeProvider.hint))
                    .transition(.scale(scale: 0.7, anchor: .top).combined(with: .opacity))
            }

            if hasStats {
                ForEach(outerWedges) { w in
                    wedgeIcon(w)
                        .position(w.contentPos(cx: cx, cy: cy, radiusFraction: 0.22))
                        .onTapGesture { selectOuter(w) }
                }
                // value, curved, bigger on the selected wedge
                ForEach(outerWedges) { w in
                    let r = w.rInner + (w.rOuter - w.rInner) * 0.58
                    CurvedText(text: w.bubble.big, radius: r, centerDeg: (w.startDeg + w.endDeg) / 2,
                               fontSize: w.isSelected ? 15 : 10.5, color: Theme.inkTier(w.bubble.pct ?? 0),
                               maxWidth: w.arcLength(at: r))
                        .position(x: cx, y: cy)
                        .allowsHitTesting(false)
                }
                // name, along the wedge's outer edge
                ForEach(outerWedges) { w in
                    let r = w.rOuter - 7
                    CurvedText(text: w.bubble.label.lowercased(), radius: r, centerDeg: (w.startDeg + w.endDeg) / 2,
                               fontSize: w.isSelected ? 9.5 : 8, color: w.isSelected ? Theme.ink : Theme.muted,
                               maxWidth: w.arcLength(at: r))
                        .position(x: cx, y: cy)
                        .allowsHitTesting(false)
                }
                if let info = infoWedge, let sub = info.bubble.sub {
                    let r = (info.rInner + info.rOuter) / 2
                    infoWedgeShape(info)
                        .transition(.opacity)
                    CurvedText(text: sub.lowercased(), radius: r, centerDeg: (info.startDeg + info.endDeg) / 2,
                               fontSize: 9, color: Theme.ink, maxWidth: info.arcLength(at: r, inset: 12))
                        .position(x: cx, y: cy)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            } else {
                ForEach(outerWedges) { w in statusAction(w) }
            }

            providerCluster(innerWedges: innerWedges)
        }
        .frame(width: g.width, height: g.height)
        .animation(.spring(response: 0.3, dampingFraction: 0.86), value: outer.count)
        .animation(.spring(response: 0.3, dampingFraction: 0.86), value: ringOpen)
        // the wheel turning: every wedge's angle shifts at once when the selected stat changes
        .animation(.spring(response: 0.34, dampingFraction: 0.86), value: pickedStatID)
        .animation(.spring(response: 0.3, dampingFraction: 0.86), value: currentProviderIdx)
    }

    /// With the provider ring hidden, the hub grows out to fill the ring's space rather than leaving a hole.
    private var hubRadius: CGFloat { ringOpen ? RingGeometry.hubRadius : RingGeometry.providerROuter }

    @ViewBuilder
    private func providerCluster(innerWedges: [WedgeLayout]) -> some View {
        ZStack {
            ForEach(innerWedges) { w in
                wedgeShape(w, meter: false)
                    .onTapGesture { pickProvider(w.index) }
                    .transition(.scale(scale: 0.7, anchor: .top).combined(with: .opacity))
            }
            ForEach(innerWedges) { w in
                providerIcon(w)
                    .position(w.contentPos(cx: cx, cy: cy, radiusFraction: 0.42))
                    .onTapGesture { pickProvider(w.index) }
            }
            // each provider's usage at a glance, along its wedge's outer edge
            ForEach(innerWedges) { w in
                if let pct = w.bubble.pct {
                    CurvedText(text: "\(pct)%", radius: w.rOuter - 6, centerDeg: (w.startDeg + w.endDeg) / 2,
                               fontSize: 7, color: Theme.inkTier(pct))
                        .position(x: cx, y: cy)
                        .allowsHitTesting(false)
                }
            }
            hub.position(x: cx, y: cy)
        }
        .frame(width: RingGeometry.width, height: RingGeometry.height)
    }

    private func selectOuter(_ w: WedgeLayout) {
        if !w.isSelected { pickedStatID = w.bubble.id }
    }

    private func pickProvider(_ filteredIndex: Int) {
        // the ring leaves out the current provider, so its index is into that shorter list
        let others = Provider.all.indices.filter { $0 != currentProviderIdx }
        guard filteredIndex < others.count else { return }
        currentProviderIdx = others[filteredIndex]
        pickedStatID = nil
    }

    /// A wedge on Mochi's paper: filled in when selected, soft otherwise, an ink outline and a hard pixel shadow like
    /// every panel. With `meter`, its usage runs along the outside as a 20-block meter in an ink frame.
    private func wedgeShape(_ w: WedgeLayout, meter: Bool) -> some View {
        let g = RingGeometry.self
        let shape = WedgeShape(cx: cx, cy: cy, rInner: w.rInner, rOuter: w.rOuter, startDeg: w.startDeg, endDeg: w.endDeg)
        let r0 = w.rOuter + g.meterGap, r1 = r0 + g.meterThickness
        let track = WedgeShape(cx: cx, cy: cy, rInner: r0, rOuter: r1, startDeg: w.startDeg, endDeg: w.endDeg)
        return ZStack {
            shape
                .fill(w.isSelected ? Theme.paper : Theme.soft)
                .shadow(color: Theme.ink.opacity(0.16), radius: 0, x: 0, y: 3)
                .overlay(shape.stroke(Theme.ink, style: StrokeStyle(lineWidth: w.isSelected ? 2.5 : 2, lineJoin: .miter)))
            if meter, let pct = w.bubble.pct {
                let lit = pct <= 0 ? 0 : max(1, Int((Double(min(pct, 100)) / 5).rounded()))
                track.fill(Theme.soft).overlay(track.stroke(Theme.ink, lineWidth: 1.5))
                ArcBlocks(cx: cx, cy: cy, rInner: r0 + 2, rOuter: r1 - 2, startDeg: w.startDeg + 0.6, endDeg: w.endDeg - 0.6, lit: lit)
                    .fill(Theme.fillTier(pct, accent: w.bubble.color))
            }
        }
        .contentShape(shape)
    }

    /// The detail band: the same paper, quieter (a thinner outline, no meter).
    private func infoWedgeShape(_ w: WedgeLayout) -> some View {
        let shape = WedgeShape(cx: cx, cy: cy, rInner: w.rInner, rOuter: w.rOuter, startDeg: w.startDeg, endDeg: w.endDeg)
        return shape
            .fill(Theme.paper)
            .shadow(color: Theme.ink.opacity(0.16), radius: 0, x: 0, y: 2)
            .overlay(shape.stroke(Theme.ink, lineWidth: 1.5))
            .allowsHitTesting(false)
    }

    /// Each other provider's critter, as big as its wedge allows, standing upright.
    private func providerIcon(_ w: WedgeLayout) -> some View {
        iconView(w.bubble.icon, height: max(min(w.labelMaxWidth, w.rOuter - w.rInner) * 0.5, 1))
    }

    /// A single wedge centred on the fan, for a provider with nothing to show yet.
    private func centeredWedge(_ bubble: Bubble, rInner: CGFloat, rOuter: CGFloat, widthDeg: Double = 72) -> WedgeLayout {
        let g = RingGeometry.self
        let centerDeg = (g.arcStart + g.arcEnd) / 2
        return WedgeLayout(bubble: bubble, index: 0, isSelected: true, startDeg: centerDeg - widthDeg / 2,
                           endDeg: centerDeg + widthDeg / 2, rInner: rInner, rOuter: rOuter)
    }

    /// Why there's nothing to show, in a word, with the icon for what clicking does. The whole sentence is the wedge's
    /// tooltip.
    private func statusAction(_ w: WedgeLayout) -> some View {
        let (icon, word): (String, String)
        switch activeStatus.state {
        case .checking: (icon, word) = ("clock", "checking")
        case .notInstalled: (icon, word) = ("gear", "install")
        case .installed: (icon, word) = ("hand", "sign in")
        case .error: (icon, word) = ("bang", "retry")
        case .disabled: (icon, word) = ("cross", "turned off")
        case .loggedIn: (icon, word) = ("refresh", usage.isRefreshing ? "fetching" : "no data yet")
        }
        return VStack(spacing: 5) {
            PixelIcon(name: icon, height: 14)
            Text(word).font(PixelFont.font(17)).foregroundColor(Theme.ink).fixedSize()
        }
        .rotationEffect(.degrees(w.tangentRotationDeg))
        .position(w.contentPos(cx: cx, cy: cy, radiusFraction: 0.55))
        .allowsHitTesting(false)
    }

    /// Not installed: run its install command in Terminal (or open its install page). Signed out or failing: run its
    /// login command, since those are interactive. Turned off: open Settings.
    private func handleStatusTap() {
        switch activeStatus.state {
        case .checking, .loggedIn:
            break
        case .disabled:
            NotificationCenter.default.post(name: .openSettingsRequested, object: nil)
        case .notInstalled:
            if let command = activeProvider.installCommand {
                TerminalLauncher.run(command)
            } else if let url = activeProvider.installURL.flatMap(URL.init(string:)) {
                NSWorkspace.shared.open(url)
            }
        case .installed, .error:
            if let command = activeProvider.loginCommand { TerminalLauncher.run(command) }
        }
    }

    /// A stat's icon in its own inner band, clear of the value and name further out, tilted to match them.
    private func wedgeIcon(_ w: WedgeLayout) -> some View {
        iconView(w.bubble.icon, height: w.isSelected ? 14 : 11)
            .rotationEffect(.degrees(w.tangentRotationDeg))
            .frame(width: max(w.labelMaxWidth, 1))
    }

    @ViewBuilder private func iconView(_ icon: IconKind, height: CGFloat) -> some View {
        switch icon {
        case .critter(let id): PixelCritter(provider: id, height: height)
        case .pixel(let name): PixelIcon(name: name, height: height)
        }
    }

    /// The active provider's critter on a paper disc. Click to refresh; it squints while a refresh runs.
    private var hub: some View {
        let scale = hubRadius / RingGeometry.hubRadius
        return Button(action: onSync) {
            ZStack {
                Circle().fill(Theme.paper)
                    .shadow(color: Theme.ink.opacity(0.16), radius: 0, x: 0, y: 3)
                    .overlay(Circle().stroke(Theme.ink, lineWidth: 2.5))
                // the disc's top half is under the bar, so the critter sits in the visible bottom half
                PixelCritter(provider: activeProvider.id, height: 18 * min(scale, 1.6), busy: usage.isRefreshing)
                    .offset(y: hubRadius * 0.45)
            }
            .frame(width: hubRadius * 2, height: hubRadius * 2)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("click to refresh · rest here to switch provider · right-click for the menu")
        // Notch mode has no menu bar icon, so right-clicking here opens the same dropdown, hanging from the notch.
        // Closing first, so the fan isn't left open behind it.
        .overlay(RightClick {
            NotificationCenter.default.post(name: .panelShouldCollapse, object: nil)
            NotificationCenter.default.post(name: .usageMenuRequested, object: nil)
        })
    }
}
