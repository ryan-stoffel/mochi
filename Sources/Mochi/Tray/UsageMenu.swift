import AppKit
import Combine
import MochiCore

/// The usage dropdown (`UsageMenuView` in a `MenuPanel`): the menu bar icon opens it under itself. Picking another
/// provider's tab makes it the one the menu bar shows.
@MainActor
final class UsageMenu {

    private let usage: UsageService
    private let onOpenSettings: () -> Void
    private let state = MenuState(provider: UsageMenu.selected.id)
    private lazy var panel = MenuPanel {
        UsageMenuView(usage: usage, state: state, onSettings: { [weak self] in
            self?.close()
            self?.onOpenSettings()
        })
    }
    private var picked: AnyCancellable?
    /// You picked another provider's tab.
    var onSelect: () -> Void = {}

    init(usage: UsageService, onOpenSettings: @escaping () -> Void) {
        self.usage = usage
        self.onOpenSettings = onOpenSettings
        picked = state.$provider.dropFirst().removeDuplicates().sink { [weak self] id in
            Settings.shared.selectedProvider = id
            self?.onSelect()
            Task { await self?.usage.freshen(id) }
        }
    }

    /// Opens with its top-middle at `anchor`, asking the shown provider for new numbers. Open, it closes.
    func toggle(at anchor: CGPoint) {
        if !panel.isOpen { state.provider = Self.selected.id }
        panel.toggle(at: anchor)
        if panel.isOpen { Task { await usage.freshen(state.provider) } }
    }

    func close() { panel.close() }

    /// The selected provider, or the first still-enabled one if it was just switched off.
    static var selected: Provider {
        let s = Settings.shared.selectedProvider
        let id = Settings.shared.isEnabled(s) ? s : Settings.shared.firstEnabledProvider()
        return Provider.byID(id) ?? Provider.all[0]
    }
}
