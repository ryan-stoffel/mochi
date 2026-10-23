import AppKit
import MochiCore

/// The Settings window: a native settings window (title bar, toolbar of panes) with each pane drawn by settings.html
/// on Mochi's paper. General · Mochi · Usage · Agents · Alerts · About. The window fits each pane's height.
@MainActor
final class SettingsPage: NSObject, NSToolbarDelegate {

    private let usage: UsageService
    private let agents: SettingsAgents
    private weak var pet: PetControls?
    private let onDisplayModeChange: (DisplayMode) -> Void
    private let onRunWizard: () -> Void
    private var page: PageWindow?
    private var pane = UserDefaults.standard.string(forKey: "settingsPane") ?? "general"
    /// Said under the hook rows after connecting one, e.g. that Codex wants the hook approved.
    private var note: String?
    private var error: String?

    private static let panes: [(id: String, title: String, symbol: String)] = [
        ("general", "General", "gearshape"), ("mochi", "Mochi", "pawprint"), ("usage", "Usage", "chart.bar"),
        ("agents", "Agents", "sparkles"), ("alerts", "Alerts", "bell"), ("about", "About", "info.circle"),
    ]

    init(usage: UsageService, agents: SettingsAgents, pet: PetControls?,
         onDisplayModeChange: @escaping (DisplayMode) -> Void, onRunWizard: @escaping () -> Void) {
        self.usage = usage
        self.agents = agents
        self.pet = pet
        self.onDisplayModeChange = onDisplayModeChange
        self.onRunWizard = onRunWizard
    }

    func show() {
        if let page { return page.show() }
        if !Self.panes.contains(where: { $0.id == pane }) { pane = "general" }
        let p = PageWindow(page: "settings.html", title: "Mochi Settings", size: NSSize(width: 540, height: 420), fullSize: false)
        p.fitsContent = true
        p.state = { [weak self] in self?.state() ?? [:] }
        p.act = { [weak self] name, arg in self?.act(name, arg) }
        let toolbar = NSToolbar(identifier: "settings")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = false
        p.window.toolbar = toolbar
        p.window.toolbarStyle = .preference
        toolbar.selectedItemIdentifier = .init(pane)
        p.window.title = title(pane)
        page = p
        p.show()
    }

    private func title(_ id: String) -> String { Self.panes.first { $0.id == id }?.title ?? "Settings" }

    // MARK: - Toolbar

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { Self.panes.map { .init($0.id) } }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { Self.panes.map { .init($0.id) } }
    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { Self.panes.map { .init($0.id) } }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard let p = Self.panes.first(where: { $0.id == id.rawValue }) else { return nil }
        let item = NSToolbarItem(itemIdentifier: id)
        item.label = p.title
        item.image = NSImage(systemSymbolName: p.symbol, accessibilityDescription: p.title)
        item.target = self
        item.action = #selector(pick(_:))
        return item
    }

    @objc private func pick(_ item: NSToolbarItem) { select(item.itemIdentifier.rawValue) }

    private func select(_ id: String) {
        guard Self.panes.contains(where: { $0.id == id }), id != pane else { return }
        pane = id
        UserDefaults.standard.set(id, forKey: "settingsPane")
        page?.window.toolbar?.selectedItemIdentifier = .init(id)
        page?.window.title = title(id)
        page?.update()
    }

    // MARK: - State

    private func state() -> [String: Any] {
        let c = agents.config
        var s: [String: Any] = [
            "pane": pane,
            "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
            "displayMode": Settings.shared.displayMode.rawValue,
            "hasNotch": NotchGeometry.hasHardwareNotch,
            "launchAtLogin": Settings.shared.launchAtLogin,
            "providers": Provider.all.map { p -> [String: Any] in
                let on = Settings.shared.isEnabled(p.id)
                let status = usage.status(p.id)
                var row: [String: Any] = ["id": p.id, "name": p.name.lowercased(), "enabled": on,
                                          "status": statusText(p, status, on: on), "tone": tone(status, on: on)]
                if on, let a = primaryAction(p, status) { row["action"] = a.title }
                return row
            },
            "agents": [
                "listening": agents.listening, "port": Int(Agents.port),
                "hooks": Provider.all.map { p -> [String: Any] in
                    ["id": p.id, "name": p.name.lowercased(), "installed": agents.installed[p.id] == true,
                     "canInstall": agents.canInstall(p.id), "alertsOn": c.providerOn(p.id),
                     "live": agents.sessions.filter { $0.provider == p.id }.count]
                },
                "note": note ?? "", "error": error ?? "", "idleMinutes": c.idleMinutes,
                "alerts": Dictionary(uniqueKeysWithValues: AlertKind.allCases.map {
                    ($0.rawValue, ["on": c.alerts($0), "sound": c.sound($0)] as [String: Any])
                }),
                "repeatSeconds": c.repeatSeconds, "volume": c.volume, "notifications": c.notifications,
                "sounds": MinisConfig.soundChoices,
            ] as [String: Any],
        ]
        if let pet { s["pet"] = pet.petState() }
        return s
    }

    private func statusText(_ p: Provider, _ status: ProviderStatus, on: Bool) -> String {
        guard on else { return "turned off." }
        switch status.state {
        case .checking: return "checking…"
        case .notInstalled: return status.message?.lowercased() ?? "not installed."
        case .installed: return status.message?.lowercased() ?? "installed, not signed in."
        case .loggedIn:
            if let m = status.message { return "signed in (\(m.lowercased()))" }
            return usage.primaryPct(p.id).map { "signed in. \($0)% used." } ?? "signed in."
        case .error(let message): return (status.message ?? message).lowercased()
        case .disabled: return "turned off."
        }
    }

    private func tone(_ status: ProviderStatus, on: Bool) -> String {
        guard on else { return "" }
        switch status.state {
        case .loggedIn: return status.message == nil ? "ok" : "warn"
        case .error: return "error"
        default: return ""
        }
    }

    /// Install beats log-in beats nothing: whichever one actually unblocks you from here.
    private func primaryAction(_ p: Provider, _ status: ProviderStatus) -> (title: String, run: () -> Void)? {
        switch status.state {
        case .notInstalled:
            if let command = p.installCommand { return ("install", { TerminalLauncher.run(command) }) }
            if let s = p.installURL, let url = URL(string: s) { return ("docs", { NSWorkspace.shared.open(url) }) }
            return nil
        case .installed, .error:
            return p.loginCommand.map { cmd in ("log in", { TerminalLauncher.run(cmd) }) }
        default:
            return nil
        }
    }

    // MARK: - Actions

    /// `arg` is a provider id, or `key=value`.
    private func act(_ name: String, _ arg: String?) {
        let (key, value) = Self.split(arg)
        switch name {
        case "pane":
            select(arg ?? "")
        case "displayMode":
            guard let mode = DisplayMode(rawValue: arg ?? ""), mode == .tray || NotchGeometry.hasHardwareNotch else { return }
            Settings.shared.displayMode = mode
            onDisplayModeChange(mode)
        case "enable":
            guard Provider.byID(key) != nil else { return }
            Task { await usage.setProviderEnabled(key, value == "true") }
        case "providerAction":
            guard let p = Provider.byID(arg ?? ""), let a = primaryAction(p, usage.status(p.id)) else { return }
            a.run()
        case "hook":
            guard let p = Provider.byID(key) else { return }
            let on = value == "true"
            do {
                try agents.setInstalled(key, on)
                error = nil
                note = on ? agents.followUp(key).map { "\(p.name.lowercased()): \($0.lowercased())" } : nil
            } catch {
                self.error = error.localizedDescription
            }
        case "test":
            if Provider.byID(arg ?? "") != nil { agents.test(arg!) }
        case "preview":
            if let kind = AlertKind(rawValue: arg ?? "") { agents.previewSound(kind) }
        case "set":
            set(key, value)
        case "pet":
            pet?.setPet(key, value)
        case "openNotifications":
            let id = Bundle.main.bundleIdentifier ?? "com.joey.mochi"
            if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)") {
                NSWorkspace.shared.open(url)
            }
        case "login":
            // the pet owns open-at-login when it's there; this is for the usage side on its own
            if let pet { pet.setPet("login", arg ?? "false"); break }
            let on = arg == "true"
            Settings.shared.launchAtLogin = on
            LoginItem.setEnabled(on)
        case "wizard":
            onRunWizard()
        case "reveal":
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: Settings.supportDirectory.path)
        case "quit":
            NSApp.terminate(nil)
        default:
            break
        }
    }

    /// One of the agents' settings, as `key=value`; anything unrecognised is ignored.
    private func set(_ key: String, _ value: String) {
        var c = agents.config
        switch key {
        case "idleMinutes": if let v = Double(value), v > 0 { c.idleMinutes = v }
        case "repeatSeconds": if let v = Double(value), v >= 0 { c.repeatSeconds = v }
        case "volume": if let v = Double(value), (0...1).contains(v) { c.volume = v }
        case "notifications": c.notifications = value == "true"
        default:
            let parts = key.split(separator: ".", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return }
            switch parts[0] {
            case "alert": if let k = AlertKind(rawValue: parts[1]) { c.alertOn[k.rawValue] = value == "true" }
            case "sound": if AlertKind(rawValue: parts[1]) != nil, MinisConfig.soundChoices.contains(value) { c.sounds[parts[1]] = value }
            case "alerts": if Provider.byID(parts[1]) != nil { c.providers[parts[1]] = value == "true" }
            default: return
            }
        }
        agents.config = c
    }

    private static func split(_ arg: String?) -> (String, String) {
        guard let arg, let eq = arg.firstIndex(of: "=") else { return (arg ?? "", "") }
        return (String(arg[..<eq]), String(arg[arg.index(after: eq)...]))
    }
}
