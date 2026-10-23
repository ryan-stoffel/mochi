import AppKit
import MochiCore

/// Real notch geometry via the same public API Atoll uses
/// (`auxiliaryTopLeftArea`/`auxiliaryTopRightArea`, `safeAreaInsets`) rather
/// than guessing a notch width like the Electron version had to.
enum NotchGeometry {
    struct Info {
        var hasNotch: Bool
        var notchWidth: CGFloat
        var reservedTopHeight: CGFloat // menu bar (+ notch) height to sit flush under
    }

    /// Whether *any* attached display actually has a hardware notch.
    ///
    /// Gates the notch display mode in Settings: the shell fuses to the
    /// physical cutout rather than floating near it, so on a Mac mini, a Studio
    /// Display, or any external monitor there is nothing for it to fuse to and
    /// the pill would hang in dead space. Checks every screen, not just the
    /// main one, so plugging into an external display doesn't make the option
    /// vanish on a MacBook that does have a notch.
    static var hasHardwareNotch: Bool {
        NSScreen.screens.contains { $0.safeAreaInsets.top > 0 }
    }

    /// The screen the notch shell should live on — the first one with a real
    /// notch, falling back to main so callers always get something usable.
    static var notchScreen: NSScreen {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 }
            ?? NSScreen.main
            ?? NSScreen.screens[0]
    }

    static func info(for screen: NSScreen = notchScreen) -> Info {
        let hasNotch = screen.safeAreaInsets.top > 0
        var notchWidth: CGFloat = 200 // reasonable fallback on non-notched Macs
        if let left = screen.auxiliaryTopLeftArea?.width,
           let right = screen.auxiliaryTopRightArea?.width {
            notchWidth = screen.frame.width - left - right
        }
        let reservedTop = hasNotch ? screen.safeAreaInsets.top : NSStatusBar.system.thickness
        return Info(hasNotch: hasNotch, notchWidth: notchWidth, reservedTopHeight: reservedTop)
    }

    /// Top-left origin (AppKit/Cocoa y-up coordinates) to center a window of
    /// `size` horizontally on `screen`, with its *top* edge flush against
    /// the very top of the screen — i.e. occupying the same rows of pixels
    /// as the real menu bar, so our content reads as living in the bar
    /// itself rather than as a pill hanging below it. Growing `size.height`
    /// (compact → expanded) extends the window straight down from that same
    /// fixed top edge.
    static func topCenterOrigin(for size: CGSize, on screen: NSScreen = notchScreen) -> CGPoint {
        let x = screen.frame.midX - size.width / 2
        let y = screen.frame.maxY - size.height
        return CGPoint(x: x, y: y)
    }

    /// Fixed layout constants shared by the pill and the island.
    enum Layout {
        static let flankWidth: CGFloat = 64        // logo/percentage slot, each side of the notch
        static let islandWidth: CGFloat = 420
        static let islandContentHeight: CGFloat = 160   // below the bar
        static let shadowMargin: CGFloat = 24
    }

    /// Panel size for the rest (flanking) state — just tall enough for the
    /// menu-bar sliver, wide enough for notch + both flanking slots.
    static func compactSize(for screen: NSScreen = notchScreen) -> CGSize {
        let i = info(for: screen)
        return CGSize(width: i.notchWidth + Layout.flankWidth * 2, height: i.reservedTopHeight)
    }

    /// The open island, bar included.
    static func islandSize(for screen: NSScreen = notchScreen) -> CGSize {
        let i = info(for: screen)
        return CGSize(width: max(Layout.islandWidth, compactSize(for: screen).width + 40),
                      height: i.reservedTopHeight + Layout.islandContentHeight)
    }

    /// The panel's one size: the island plus room for its shadow, so the window never resizes under the pointer.
    /// It lets clicks through everywhere but the pill (or the open island); see `NotchController`.
    static func expandedSize(for screen: NSScreen = notchScreen) -> CGSize {
        let island = islandSize(for: screen)
        return CGSize(width: island.width + Layout.shadowMargin * 2, height: island.height + Layout.shadowMargin)
    }

    /// The real hardware notch's rect in the *panel's local* coordinate
    /// space (SwiftUI y-down), for a panel of `panelSize` centered over it.
    static func notchLocalRect(panelSize: CGSize, for screen: NSScreen = notchScreen) -> CGRect {
        let i = info(for: screen)
        let x = (panelSize.width - i.notchWidth) / 2
        return CGRect(x: x, y: 0, width: i.notchWidth, height: i.reservedTopHeight)
    }
}
