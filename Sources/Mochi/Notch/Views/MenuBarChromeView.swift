import SwiftUI
import MochiCore

/// The rest state: one solid black bar fused with the notch (drawing black over the camera housing is harmless), the
/// active provider's critter on its left and its usage on its right. On a display without a notch, this bar stands in
/// for one.
///
/// The bar never moves. Opening shrinks it to just the notch's width while the critter and number fly into the notch.
/// The flank positions are a fixed offset from the centre, so they're right the instant `isExpanded` flips.
struct MenuBarChromeView: View {
    @ObservedObject var usage: UsageService
    let currentProviderIdx: Int
    let panelSize: CGSize
    let isExpanded: Bool

    private var provider: Provider { Provider.all[currentProviderIdx] }
    private var status: ProviderStatus { usage.status(provider.id) }

    private var info: NotchGeometry.Info { NotchGeometry.info() }
    private var notchRect: CGRect { NotchGeometry.notchLocalRect(panelSize: panelSize) }
    private var barCenterX: CGFloat { panelSize.width / 2 }
    private var barWidth: CGFloat { isExpanded ? notchRect.width : NotchGeometry.compactSize().width }
    private var flankOffset: CGFloat { info.notchWidth / 2 + NotchGeometry.Layout.flankWidth / 2 }

    var body: some View {
        let barHeight = info.reservedTopHeight
        ZStack {
            // Fully merged into a real notch, the bar has nothing to add, and its rounded corners would show as a seam
            // under the camera housing. Without a notch it stays: it's the only thing standing in for one.
            BumpShape(topCornerRadius: 6, bottomCornerRadius: barHeight / 2)
                .fill(Color.black)
                .frame(width: barWidth, height: barHeight)
                .position(x: barCenterX, y: barHeight / 2)
                .opacity(isExpanded && info.hasNotch ? 0 : 1)

            PixelCritter(provider: provider.id, height: 17, busy: usage.isRefreshing)
                .position(x: isExpanded ? notchRect.midX : barCenterX - flankOffset, y: barHeight / 2)
                .scaleEffect(isExpanded ? 0.3 : 1)
                .opacity(isExpanded ? 0 : 1)

            label
                .position(x: isExpanded ? notchRect.midX : barCenterX + flankOffset, y: barHeight / 2)
                .scaleEffect(isExpanded ? 0.3 : 1)
                .opacity(isExpanded ? 0 : 1)
        }
        .frame(width: panelSize.width, height: barHeight, alignment: .top)
        .animation(.island(open: isExpanded), value: isExpanded)
    }

    @ViewBuilder private var label: some View {
        if let pct = usage.primaryPct(provider.id) {
            Text("\(pct)%")
                .font(PixelFont.font(19))
                .foregroundColor(Format.statusColor(pct))
                .fixedSize()
        } else {
            Text(placeholder)
                .font(PixelFont.font(15))
                .foregroundColor(.white.opacity(0.5))
                .fixedSize()
        }
    }

    /// A word for when there's no number: why not, in as few letters as fit beside the notch.
    private var placeholder: String {
        if provider.id == "claude" {
            switch usage.claude.errorType {
            case "offline": return "offline"
            case "auth": return "sign in"
            default: break
            }
        }
        return status.shortLabel
    }
}
