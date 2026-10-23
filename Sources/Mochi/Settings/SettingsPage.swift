import AppKit
import SwiftUI
import MochiCore

/// The Settings window: a toolbar of panes (General · Usage · Agents · Alerts · Mochi · About), each a grouped
/// SwiftUI form (`SettingsView`).
@MainActor
final class SettingsPage: NSObject, NSToolbarDelegate, NSWindowDelegate {

    private let model: SettingsModel
    private var window: NSWindow?
    private var host: NSHostingView<SettingsView>?
    private var pane = SettingsPane(rawValue: UserDefaults.standard.string(forKey: "settingsPane") ?? "") ?? .general

    init(model: SettingsModel) {
        self.model = model
    }

    func show(_ pane: SettingsPane? = nil) {
        if let pane { select(pane) }
        if window == nil { build() }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func build() {
        let host = NSHostingView(rootView: SettingsView(model: model, pane: pane))
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 480),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        w.contentView = host
        w.contentMinSize = NSSize(width: 560, height: 320)
        w.contentMaxSize = NSSize(width: 560, height: 1200)
        w.isReleasedWhenClosed = false
        w.delegate = self
        let toolbar = NSToolbar(identifier: "settings")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = false
        toolbar.selectedItemIdentifier = .init(pane.rawValue)
        w.toolbar = toolbar
        w.toolbarStyle = .preference
        w.title = pane.title
        w.center()
        w.setFrameAutosaveName("MochiSettings")
        self.host = host
        window = w
    }

    // MARK: - Toolbar

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { SettingsPane.allCases.map { .init($0.rawValue) } }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { SettingsPane.allCases.map { .init($0.rawValue) } }
    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { SettingsPane.allCases.map { .init($0.rawValue) } }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard let p = SettingsPane(rawValue: id.rawValue) else { return nil }
        let item = NSToolbarItem(itemIdentifier: id)
        item.label = p.title
        item.image = NSImage(systemSymbolName: p.symbol, accessibilityDescription: p.title)
        item.target = self
        item.action = #selector(pick(_:))
        return item
    }

    @objc private func pick(_ item: NSToolbarItem) {
        if let p = SettingsPane(rawValue: item.itemIdentifier.rawValue) { select(p) }
    }

    private func select(_ p: SettingsPane) {
        pane = p
        UserDefaults.standard.set(p.rawValue, forKey: "settingsPane")
        window?.toolbar?.selectedItemIdentifier = .init(p.rawValue)
        window?.title = p.title
        host?.rootView = SettingsView(model: model, pane: p)
    }
}
