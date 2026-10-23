import AppKit
import MochiCore
import SwiftUI

/// Borderless, transparent panel at the notch, fused with the menu bar.
///
/// It is always the full open size (`NotchGeometry.expandedSize`) and never resizes: a window resizing under the
/// pointer is what made the old hover tracking see the pointer leave and come back, which closed the notch as it
/// opened. Instead it lets clicks straight through everywhere except the pill (and, while open, the island), so its
/// transparent area never blocks the desktop or the menu bar.
///
/// Whether it's open comes from one place, `NotchHover`, fed the pointer position 30 times a second. Nothing else
/// (SwiftUI hover, tracking areas, the click-outside monitor) decides it on its own, so they can't disagree.
///
/// `level` is `.mainMenu + 3`, like Atoll's notch window: `.floating` sits below the menu bar's own window, which
/// would draw the pill underneath the real menu bar instead of flush with the notch.
final class NotchPanel: NSPanel {}

/// What the views show: open or not. `NotchController` sets it from `NotchHover`; nothing else should.
@MainActor
final class NotchState: ObservableObject {
    @Published var open = false
}

@MainActor
final class NotchController: NSObject {
    private var panel: NotchPanel?
    /// Injected rather than created here: both shells observe the one shared service.
    private let usage: UsageService
    private let state = NotchState()
    private var hover = NotchHover()
    private var layout: NotchHover.Layout?
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var clickMonitor: Any?

    init(usage: UsageService) {
        self.usage = usage
        super.init()
    }

    func show() {
        if let panel { return panel.orderFrontRegardless() }
        let panel = NotchPanel(contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .mainMenu + 3
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.isMovable = false
        panel.contentView = NSHostingView(rootView: IslandShellView(usage: usage, state: state))
        self.panel = panel
        place()
        panel.orderFrontRegardless()

        // ponytail: a 30 Hz poll of the pointer, not event monitors. Mouse-moved events only reach the app the
        // pointer's over, so monitors miss some; reading the position always works and costs next to nothing.
        let t = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.track() } }
        RunLoop.main.add(t, forMode: .common)   // .common: keep tracking while a menu is open elsewhere
        timer = t

        // A click anywhere else closes it at once, rather than after the pointer's grace period.
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
        let nc = NotificationCenter.default
        observers = [
            nc.addObserver(forName: .panelShouldCollapse, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.close() }
            },
            nc.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.place() }
            },
        ]
    }

    /// Tears the panel down: switching back to the menu bar icon stops the notch drawing without a restart.
    func hide() {
        timer?.invalidate()
        timer = nil
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        panel?.orderOut(nil)
        panel = nil
        hover = NotchHover()
        apply()
    }

    /// Top-centre of the notch's screen, at the full open size. Again whenever screens change.
    private func place() {
        guard let panel else { return }
        let screen = NotchGeometry.notchScreen
        let size = NotchGeometry.expandedSize(for: screen)
        let origin = NotchGeometry.topCenterOrigin(for: size, on: screen)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        let bar = NotchGeometry.compactSize(for: screen), island = NotchGeometry.islandSize(for: screen)
        layout = NotchHover.Layout(
            bar: CGRect(x: (size.width - bar.width) / 2, y: 0, width: bar.width, height: bar.height),
            island: CGRect(x: (size.width - island.width) / 2, y: 0, width: island.width, height: island.height))
    }

    private func track() {
        guard let panel, let layout else { return }
        let m = NSEvent.mouseLocation, f = panel.frame
        let p = CGPoint(x: m.x - f.minX, y: f.maxY - m.y)
        let spot = NotchHover.spot(of: p, in: layout, open: hover.open)
        hover.update(spot, at: CACurrentMediaTime())
        apply()
        // Take clicks only over what's showing; everywhere else they go to whatever is underneath.
        let live = hover.open ? spot != .away : spot == .bar
        if panel.ignoresMouseEvents == live { panel.ignoresMouseEvents = !live }
    }

    private func close() {
        guard hover.open else { return }
        hover.close()
        apply()
    }

    private func apply() {
        if state.open != hover.open { state.open = hover.open }
    }
}

extension Notification.Name {
    static let panelShouldCollapse = Notification.Name("panelShouldCollapse")
}
