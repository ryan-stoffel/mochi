import AppKit
import Combine
import MochiCore

/// Owns the menu-bar status item — the tray shell.
///
/// The icon is the selected provider's logo with its usage beside it (`TrayIconRenderer`), monochrome like the
/// rest of the menu bar. Clicking it opens the `UsageMenu` dropdown hanging from the bar. One of the two shells
/// `UsageShell` switches between; it holds no data of its own and observes the shared `UsageService`.
@MainActor
final class StatusItemController {

    private var statusItem: NSStatusItem?
    private var cancellables = Set<AnyCancellable>()

    private let usage: UsageService
    private let menu: UsageMenu

    init(usage: UsageService, menu: UsageMenu) {
        self.usage = usage
        self.menu = menu
    }

    // MARK: - Lifecycle

    func install() {
        guard statusItem == nil else { return }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item
        if let button = item.button {
            // VoiceOver presses the button itself; the mouse goes to the catcher on top of it, so the button never
            // gets a mouse-down and never draws the pressed capsule.
            button.target = self
            button.action = #selector(open)
            let catcher = ClickCatcher(frame: button.bounds)
            catcher.autoresizingMask = [.width, .height]
            catcher.onClick = { [weak self] in self?.open() }
            button.addSubview(catcher)
        }

        // Redraw the icon whenever anything it reflects changes. Cheap enough to recompute on every publish.
        usage.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                // objectWillChange fires before the new values land; read them on the next turn.
                DispatchQueue.main.async { self?.updateIcon() }
            }
            .store(in: &cancellables)

        menu.onSelect = { [weak self] in self?.updateIcon() }
        updateIcon()
    }

    func remove() {
        menu.close()
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
        }
        statusItem = nil
        cancellables.removeAll()
    }

    // MARK: - Icon

    private func updateIcon() {
        guard let button = statusItem?.button else { return }
        let provider = UsageMenu.selected
        let status = usage.status(provider.id)
        var failing = false
        if case .error = status.state { failing = true }
        let pct = usage.primaryPct(provider.id)
        button.image = TrayIconRenderer.icon(provider: provider.id, pct: pct, failing: failing)
        let tip = tooltip(for: provider, status: status)
        button.toolTip = tip
        button.setAccessibilityLabel(pct.map { "\(provider.name), \($0) percent used" } ?? "Mochi")
        button.setAccessibilityHelp(tip)
    }

    private func tooltip(for provider: Provider, status: ProviderStatus) -> String {
        switch provider.id {
        case "claude":
            let d = usage.claude
            guard d.session != nil || d.weekly != nil else {
                return d.error.map { "Mochi — \($0)" } ?? "Mochi — checking Claude…"
            }
            let base = "Claude — session \(Format.pct(d.session))%, week \(Format.pct(d.weekly))%"
            return d.error.map { "\(base) (\($0))" } ?? base
        case "antigravity":
            guard status.state == .loggedIn, let g = usage.antigravity else { break }
            return "Antigravity — 5 hours \(Format.pct(g.fiveHourPct))%, week \(Format.pct(g.weeklyPct))%"
        case "codex":
            guard status.state == .loggedIn, let c = usage.codex else { break }
            return "Codex\(c.plan.map { " (\($0))" } ?? "") — \(Format.pct(c.primaryPct))%"
        case "cursor":
            guard status.state == .loggedIn, let c = usage.cursor else { break }
            return "Cursor\(c.plan.map { " (\($0))" } ?? "") — \(Format.pct(c.primaryPct))%"
        default:
            break
        }
        return "\(provider.name): \(status.message(installHint: provider.hint))"
    }

    // MARK: - Dropdown

    /// Either button: the dropdown has everything a right-click menu would.
    @objc private func open() {
        guard let button = statusItem?.button, let window = button.window else { return }
        let r = window.convertToScreen(button.convert(button.bounds, to: nil))
        menu.toggle(at: CGPoint(x: r.midX, y: r.minY - 5))
    }
}

/// Sits over the status item's button and takes its clicks on mouse-down, like a native menu opening.
private final class ClickCatcher: NSView {
    var onClick: () -> Void = {}
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onClick() }
    override func rightMouseDown(with event: NSEvent) { onClick() }
    override func otherMouseDown(with event: NSEvent) { onClick() }
}
