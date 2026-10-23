import AppKit
import SwiftUI
import MochiCore

/// The usage side of Mochi: the one `UsageService`, where usage shows (the menu bar icon and its dropdown, or the
/// notch), and the Settings and setup windows. `App` (main.swift) owns one and starts it.
///
/// Switching between the menu bar and the notch is an in-process view swap. Both observe the same service, so
/// switching never re-fetches and never shows one stale data the other already has.
@MainActor
final class UsageShell: NSObject {

    let usage = UsageService()
    private let agents: Agents
    private weak var pet: PetControls?

    init(agents: Agents, pet: PetControls) {
        self.agents = agents
        self.pet = pet
    }

    /// The usage dropdown, shared: the menu bar icon opens it, and so does right-clicking the notch.
    private lazy var menu = UsageMenu(usage: usage, onOpenSettings: { [weak self] in self?.openSettings() })

    private lazy var statusItem = StatusItemController(usage: usage, menu: menu)

    private lazy var panel = NotchController(usage: usage)

    private lazy var settings = SettingsPage(
        usage: usage, agents: agents, pet: pet,
        onDisplayModeChange: { [weak self] mode in self?.apply(mode: mode) },
        onRunWizard: { [weak self] in self?.openWizard() })

    private lazy var wizard = WizardPage(
        usage: usage,
        onDisplayModeChange: { [weak self] mode in self?.apply(mode: mode) },
        onFinish: {})

    private var currentMode: DisplayMode?

    func start() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(openSettings),
            name: .openSettingsRequested, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(openWizard),
            name: .openWizardRequested, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(openMenuUnderNotch),
            name: .usageMenuRequested, object: nil)

        apply(mode: resolvedMode())

        if !Settings.shared.setupComplete {
            openWizard()
        }
    }

    func stop() {
        // Anything mid-flight is a `ptydrive` child holding a CLI's process
        // group open. `Process` termination on our side is what lets the
        // helper's own cleanup run, so give it an explicit chance rather than
        // letting the app exit out from under it.
        statusItem.remove()
        panel.hide()
    }

    // MARK: - Display mode

    /// The notch shell can't render on a display with no notch, so a settings
    /// file carried over from a MacBook to a Mac mini falls back rather than
    /// leaving the user with no UI at all.
    private func resolvedMode() -> DisplayMode {
        let stored = Settings.shared.displayMode
        if stored == .notch && !NotchGeometry.hasHardwareNotch { return .tray }
        return stored
    }

    func apply(mode: DisplayMode) {
        guard mode != currentMode else { return }
        currentMode = mode

        switch mode {
        case .tray:
            panel.hide()
            statusItem.install()
        case .notch:
            statusItem.remove()
            panel.show()
        }
    }

    /// Mochi follows another provider now: so does the menu bar.
    func providerChanged() {
        Settings.shared.selectedProvider = agents.config.provider
        usage.objectWillChange.send()
    }

    // MARK: - Windows

    @objc func openSettings() { settings.show() }

    @objc func openWizard() { wizard.show() }

    /// Notch mode has no menu bar icon, so right-clicking the notch opens the dropdown hanging from it instead.
    @objc func openMenuUnderNotch() {
        let screen = NotchGeometry.notchScreen
        let feet = screen.frame.maxY - NotchGeometry.info(for: screen).reservedTopHeight
        menu.show(x: screen.frame.midX, top: screen.frame.maxY, feet: feet - 2)
    }
}
