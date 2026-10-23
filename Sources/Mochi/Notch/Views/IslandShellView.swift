import SwiftUI
import MochiCore

/// One persistent view for both states: the pill beside the notch at rest, and the hub and fan hanging from it when
/// open. It never resizes or tracks the pointer itself; `NotchController` decides open/ring (`NotchState`) and this
/// only animates between them inside a canvas that's always the full open size.
struct IslandShellView: View {
    @ObservedObject var usage: UsageService
    @ObservedObject var state: NotchState

    /// The same provider the menu bar icon and its dropdown show, so switching here switches there too.
    @State private var currentProviderIdx = Provider.all.firstIndex { $0.id == Settings.shared.selectedProvider } ?? 0

    var body: some View {
        let size = NotchGeometry.expandedSize()
        let barHeight = NotchGeometry.info().reservedTopHeight
        ZStack(alignment: .top) {
            MenuBarChromeView(usage: usage, currentProviderIdx: currentProviderIdx, panelSize: size, isExpanded: state.open)

            // The hub (drawn by RingView with its centre on the bar's bottom edge) is the only thing that appears, its
            // top half tucked up into the bar for the fused look.
            if state.open {
                RingView(usage: usage, ringOpen: state.ring, currentProviderIdx: $currentProviderIdx) {
                    Task { await usage.refresh() }
                }
                .position(x: size.width / 2, y: barHeight + RingGeometry.height / 2)
                .transition(.opacity.combined(with: .scale(scale: 0.6, anchor: .top)))
            }
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .animation(.island(open: state.open), value: state.open)
        .onChange(of: currentProviderIdx) { Settings.shared.selectedProvider = Provider.all[$0].id }
        // the dropdown (right-click the hub) can switch providers too: pick that up each time it opens
        .onChange(of: state.open) { open in
            if open, let i = Provider.all.firstIndex(where: { $0.id == Settings.shared.selectedProvider }) { currentProviderIdx = i }
        }
    }
}
