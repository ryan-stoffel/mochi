import AppKit
import SwiftUI

/// A dropdown hanging from the menu bar, like the ones Control Center and Wi-Fi open: a rounded panel of Liquid Glass
/// (a popover material before macOS 26) under its anchor, sized to its SwiftUI content. A click anywhere else or
/// Escape closes it.
@MainActor
final class MenuPanel<Content: View>: NSObject {

    /// Takes key focus without activating the app, so Escape and ⌘-shortcuts reach the content.
    private final class Panel: NSPanel {
        var onCancel: () -> Void = {}
        override var canBecomeKey: Bool { true }
        override func cancelOperation(_ sender: Any?) { onCancel() }
    }

    private let panel: Panel
    private var monitor: Any?
    private var anchor = CGPoint.zero
    var isOpen: Bool { panel.isVisible }
    var onClose: () -> Void = {}

    static var cornerRadius: CGFloat { 14 }

    init(@ViewBuilder content: () -> Content) {
        panel = Panel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
                      styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        super.init()
        let host = NSHostingView(rootView: content()
            .background(GeometryReader { g in Color.clear.preference(key: SizeKey.self, value: g.size) })
            .onPreferenceChange(SizeKey.self) { [weak self] size in MainActor.assumeIsolated { self?.resize(size) } })
        panel.contentView = Self.background(host)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .transient]
        panel.isReleasedWhenClosed = false
        panel.onCancel = { [weak self] in self?.close() }
    }

    /// Glass on macOS 26 and later; the popover material before it.
    private static func background(_ host: NSView) -> NSView {
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = cornerRadius
            glass.contentView = host
            return glass
        }
        let v = NSVisualEffectView()
        v.material = .popover
        v.state = .active
        v.blendingMode = .behindWindow
        v.wantsLayer = true
        v.layer?.cornerRadius = cornerRadius
        v.layer?.masksToBounds = true
        host.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: v.leadingAnchor), host.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            host.topAnchor.constraint(equalTo: v.topAnchor), host.bottomAnchor.constraint(equalTo: v.bottomAnchor),
        ])
        return v
    }

    /// Opens with its top-middle at `anchor` (screen coordinates), slid sideways to stay on screen. Open, it closes.
    func toggle(at anchor: CGPoint) {
        if isOpen { return close() }
        self.anchor = anchor
        place(panel.frame.size)
        panel.orderFrontRegardless()
        panel.makeKey()
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
    }

    func close() {
        guard isOpen else { return }
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        panel.orderOut(nil)
        onClose()
    }

    private func resize(_ size: CGSize) {
        guard size.width > 0, size.height > 0, size != panel.frame.size else { return }
        place(size)
    }

    private func place(_ size: CGSize) {
        let screen = NSScreen.screens.first { $0.frame.contains(CGPoint(x: anchor.x, y: anchor.y - 1)) } ?? NSScreen.main ?? NSScreen.screens[0]
        let v = screen.visibleFrame
        let x = min(max(anchor.x - size.width / 2, v.minX + 6), v.maxX - size.width - 6)
        panel.setFrame(NSRect(x: x.rounded(), y: (anchor.y - size.height).rounded(), width: size.width, height: size.height), display: true)
    }
}

private struct SizeKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}
