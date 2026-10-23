import AppKit
import Combine
import SwiftUI
import MochiCore

/// What Settings reads and changes: the usage service, the agents hub, and the pet (through `PetControls`). It
/// republishes whenever any of them changes, so every pane stays live while it's open.
@MainActor
final class SettingsModel: ObservableObject {
    let usage: UsageService
    let agents: Agents
    weak var pet: PetControls?
    let onDisplayModeChange: (DisplayMode) -> Void
    let onRunWizard: () -> Void
    /// Said under the hook rows after connecting one, e.g. that Codex wants the hook approved.
    @Published var note: String?
    @Published var error: String?
    private var bag: Set<AnyCancellable> = []

    init(usage: UsageService, agents: Agents, pet: PetControls?,
         onDisplayModeChange: @escaping (DisplayMode) -> Void, onRunWizard: @escaping () -> Void) {
        self.usage = usage
        self.agents = agents
        self.pet = pet
        self.onDisplayModeChange = onDisplayModeChange
        self.onRunWizard = onRunWizard
        usage.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &bag)
        NotificationCenter.default.publisher(for: .agentsChanged).sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &bag)
    }

    // MARK: The pet

    func pet<T>(_ key: String, _ fallback: T) -> T { pet?.petState()[key] as? T ?? fallback }

    func setPet(_ key: String, _ value: String) {
        objectWillChange.send()
        pet?.setPet(key, value)
    }

    func petToggle(_ key: String, default on: Bool = true) -> Binding<Bool> {
        Binding(get: { self.pet(key, on) }, set: { self.setPet(key, String($0)) })
    }

    // MARK: Agents

    func setConfig(_ change: (inout MinisConfig) -> Void) {
        objectWillChange.send()
        var c = agents.config
        change(&c)
        agents.config = c
    }

    func setHook(_ id: String, _ on: Bool) {
        objectWillChange.send()
        do {
            try agents.setInstalled(id, on)
            error = nil
            note = on ? agents.followUp(id).map { "\(Provider.byID(id)?.name ?? id): \($0)" } : nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    var openAtLogin: Binding<Bool> {
        Binding(get: { self.pet("login", Settings.shared.launchAtLogin) }, set: { self.setPet("login", String($0)) })
    }
}

extension Notification.Name {
    /// The agents hub has news: a session started, a hook was connected.
    static let agentsChanged = Notification.Name("com.joey.mochi.agentsChanged")
}

// MARK: - Panes

enum SettingsPane: String, CaseIterable {
    case general, usage, agents, alerts, mochi, about

    var title: String {
        switch self {
        case .general: return "General"
        case .usage: return "Usage"
        case .agents: return "Agents"
        case .alerts: return "Alerts"
        case .mochi: return "Mochi"
        case .about: return "About"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .usage: return "chart.bar"
        case .agents: return "sparkles"
        case .alerts: return "bell.badge"
        case .mochi: return "pawprint"
        case .about: return "info.circle"
        }
    }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    let pane: SettingsPane

    var body: some View {
        Group {
            switch pane {
            case .general: GeneralPane(model: model)
            case .usage: UsagePane(model: model)
            case .agents: AgentsPane(model: model)
            case .alerts: AlertsPane(model: model)
            case .mochi: MochiPane(model: model)
            case .about: AboutPane(model: model)
            }
        }
        .formStyle(.grouped)
        .frame(width: 560)
        .frame(minHeight: 300, idealHeight: 460)
    }
}

private struct GeneralPane: View {
    @ObservedObject var model: SettingsModel
    @State private var mode = Settings.shared.displayMode

    var body: some View {
        Form {
            Section {
                Picker("Show usage in", selection: $mode) {
                    Text("Menu bar").tag(DisplayMode.tray)
                    Text("Notch").tag(DisplayMode.notch).disabled(!NotchGeometry.hasHardwareNotch)
                }
                .pickerStyle(.radioGroup)
                .onChange(of: mode) { m in
                    Settings.shared.displayMode = m
                    model.onDisplayModeChange(m)
                }
            } footer: {
                Text(NotchGeometry.hasHardwareNotch
                     ? "The notch shows your usage beside the camera. Rest the pointer on it for every limit."
                     : "The notch option needs a Mac with a notch.")
                    .foregroundStyle(.secondary).multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
            }
            Section {
                Toggle("Open at login", isOn: model.openAtLogin)
                LabeledContent("Setup") {
                    Button("Run Setup Again…") { model.onRunWizard() }
                }
            }
        }
    }
}

/// A provider's logo, name and status line, the start of every provider row.
private struct ProviderLabel: View {
    let provider: Provider
    let line: String
    var tone: UsageService.Tone = .plain

    var body: some View {
        HStack(spacing: 10) {
            ProviderLogo(id: provider.id, size: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(provider.name)
                Text(line).font(.caption).foregroundStyle(color).lineLimit(2)
            }
        }
    }

    private var color: Color {
        switch tone {
        case .plain: return .secondary
        case .good: return .green
        case .warning: return .orange
        case .bad: return .red
        }
    }
}

private struct UsagePane: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section {
                ForEach(Provider.all) { p in
                    let on = Settings.shared.isEnabled(p.id)
                    let line = model.usage.statusLine(p.id)
                    HStack {
                        ProviderLabel(provider: p, line: line.text, tone: line.tone)
                        Spacer()
                        if on, let blocker = model.usage.blocker(p.id), let fix = blocker.fix, fix != .settings {
                            Button(fix.title) { model.usage.perform(fix, for: p.id) }.controlSize(.small)
                        }
                        Toggle("", isOn: Binding(get: { on }, set: { v in Task { await model.usage.setProviderEnabled(p.id, v) } }))
                            .toggleStyle(.switch).labelsHidden().controlSize(.small)
                    }
                    .opacity(on ? 1 : 0.6)
                }
            } header: {
                Text("Providers")
            } footer: {
                Text("Mochi reads each plan with the sign-in its tool already has on this Mac. Turning one off stops checking it.")
                    .foregroundStyle(.secondary).multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

private struct AgentsPane: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        let a = model.agents, c = a.config
        Form {
            Section {
                ForEach(Provider.all) { p in
                    let on = a.installed[p.id] == true
                    HStack {
                        ProviderLabel(provider: p, line: line(p, on: on), tone: on ? .good : .plain)
                        Spacer()
                        if on { Button("Test") { a.test(p.id) }.controlSize(.small) }
                        if on || a.canInstall(p.id) {
                            Button(on ? "Disconnect" : "Connect") { model.setHook(p.id, !on) }.controlSize(.small)
                        }
                        Toggle("Alerts", isOn: Binding(get: { c.providerOn(p.id) }, set: { v in model.setConfig { $0.providers[p.id] = v } }))
                            .toggleStyle(.switch).labelsHidden().controlSize(.small)
                            .help("Alerts from \(p.name)")
                    }
                }
            } header: {
                Text("Connected tools")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("A hook in each tool tells Mochi what its sessions are doing, for alerts and for the pet. Nothing leaves your Mac. The switch turns that tool's alerts on or off.")
                        .foregroundStyle(.secondary)
                    if !a.listening { Text("Can't listen on port \(Agents.port). Is another copy of Mochi running?").foregroundStyle(.red) }
                    if let n = model.note { Text(n).foregroundStyle(.orange) }
                    if let e = model.error { Text(e).foregroundStyle(.red) }
                }
                .multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
            }
            Section {
                Picker("Forget idle sessions after", selection: Binding(get: { c.idleMinutes }, set: { v in model.setConfig { $0.idleMinutes = v } })) {
                    ForEach([5.0, 10, 20, 60, 240], id: \.self) { m in Text(m < 60 ? "\(Int(m)) minutes" : "\(Int(m / 60)) hour\(m > 60 ? "s" : "")").tag(m) }
                }
            } footer: {
                Text("Sessions waiting on you always stay.").foregroundStyle(.secondary).multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func line(_ p: Provider, on: Bool) -> String {
        guard on else { return model.agents.canInstall(p.id) ? "Not connected" : "Run \(p.name) on this Mac first" }
        let live = model.agents.sessions.filter { $0.provider == p.id }.count
        return live > 0 ? "Connected, \(live) session\(live == 1 ? "" : "s") open" : "Connected"
    }
}

private struct AlertsPane: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        let c = model.agents.config
        Form {
            Section {
                ForEach(AlertKind.allCases, id: \.self) { kind in
                    HStack {
                        Text(title(kind))
                        Spacer()
                        Picker("Sound", selection: Binding(get: { c.sound(kind) }, set: { v in model.setConfig { $0.sounds[kind.rawValue] = v } })) {
                            ForEach(MinisConfig.soundChoices, id: \.self) { Text($0).tag($0) }
                        }
                        .labelsHidden().fixedSize().disabled(!c.alerts(kind))
                        Button { model.agents.previewSound(kind) } label: { Image(systemName: "speaker.wave.2") }
                            .buttonStyle(.borderless).disabled(!c.alerts(kind) || c.sound(kind) == "None")
                            .help("Play the sound")
                        Toggle(title(kind), isOn: Binding(get: { c.alerts(kind) }, set: { v in model.setConfig { $0.alertOn[kind.rawValue] = v } }))
                            .toggleStyle(.switch).labelsHidden().controlSize(.small).padding(.leading, 6)
                    }
                }
            } header: {
                Text("Alert me when an agent")
            }
            Section {
                Picker("Repeat the sound", selection: Binding(get: { c.repeatSeconds }, set: { v in model.setConfig { $0.repeatSeconds = v } })) {
                    Text("Never").tag(0.0)
                    ForEach([15.0, 30, 60, 300], id: \.self) { s in Text(s < 60 ? "Every \(Int(s)) seconds" : "Every \(Int(s / 60)) minute\(s > 60 ? "s" : "")").tag(s) }
                }
                LabeledContent("Volume") {
                    Slider(value: Binding(get: { c.volume }, set: { v in model.setConfig { $0.volume = v } }), in: 0...1)
                        .frame(width: 180)
                }
                Toggle("Show notifications", isOn: Binding(get: { c.notifications }, set: { v in model.setConfig { $0.notifications = v } }))
                LabeledContent("") {
                    Button("Notification Settings…") {
                        let id = Bundle.main.bundleIdentifier ?? "com.joey.mochi"
                        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)") { NSWorkspace.shared.open(url) }
                    }
                }
            } footer: {
                Text("An alert stays until you answer that session, click the notification, or click OK in Mochi's bubble.")
                    .foregroundStyle(.secondary).multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func title(_ kind: AlertKind) -> String {
        switch kind {
        case .done: return "Finishes a turn"
        case .needsInput: return "Needs you"
        case .failed: return "Fails"
        }
    }
}

private struct MochiPane: View {
    @ObservedObject var model: SettingsModel

    private static let costumes = [("wizard", "Wizard"), ("detective", "Sleuth"), ("chef", "Chef"), ("focus", "DJ"),
                                   ("shades", "Shades"), ("tv", "TV"), ("party", "Party")]
    private static let reminders = [("waterReminders", "Drink water"), ("walkReminders", "Get up and walk"),
                                    ("stretchReminders", "Stretches and eye breaks"), ("lunchReminders", "Lunch"),
                                    ("coffeeReminders", "Coffee"), ("bedtimeReminders", "Bedtime"), ("cheers", "Cheer me on")]

    var body: some View {
        let on = model.pet("visible", false)
        Form {
            Section {
                Toggle(isOn: model.petToggle("visible", default: false)) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Show Mochi on your desktop")
                        Text("A pixel pet that acts out your agent's sessions and says when it needs you.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
            }
            if on {
                Section {
                    Picker("Follows", selection: Binding(get: { model.pet("provider", "claude") }, set: { model.setPet("provider", $0) })) {
                        ForEach(["claude", "codex"], id: \.self) { id in
                            Label { Text(Provider.byID(id)?.name ?? id) } icon: { ProviderLogo(id: id, size: 14) }.tag(id)
                        }
                    }
                    .pickerStyle(.segmented)
                    Toggle("Act out what it's doing", isOn: model.petToggle("follow"))
                    Toggle("Say what it's doing", isOn: model.petToggle("narrate"))
                    Toggle("Come find me when it needs me", isOn: model.petToggle("claudeFetch"))
                }
                Section {
                    Picker("Size", selection: Binding(get: { model.pet("scale", 3.0) }, set: { model.setPet("scale", String($0)) })) {
                        Text("Small").tag(2.0)
                        Text("Medium").tag(3.0)
                        Text("Large").tag(4.0)
                        Text("Extra Large").tag(6.0)
                    }
                    Toggle("Wander around", isOn: model.petToggle("roam"))
                    Toggle("React to apps and calls", isOn: model.petToggle("appAware"))
                    Toggle("Use emoji in its bubble", isOn: model.petToggle("emoji", default: false))
                    Toggle("Quiet for an hour", isOn: model.petToggle("quiet", default: false))
                    LabeledContent("Dress up") {
                        Menu("Try On") {
                            ForEach(Self.costumes, id: \.0) { id, name in Button(name) { model.setPet("wear", id) } }
                            Divider()
                            Button("Take It Off") { model.setPet("wear", "none") }
                        }
                        .fixedSize()
                    }
                    LabeledContent("Lost it?") {
                        Button("Move to Corner") { model.setPet("corner", "1") }
                    }
                }
                Section("Reminders") {
                    ForEach(Self.reminders, id: \.0) { key, title in Toggle(title, isOn: model.petToggle(key)) }
                }
            }
        }
    }
}

private struct AboutPane: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 96, height: 96)
            Text("Mochi").font(.title2.weight(.semibold))
            Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
                .foregroundStyle(.secondary)
            Text("Your plan limits for Claude, Codex, Antigravity and Cursor, in the menu bar or the notch. With a pixel pet, if you like.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 360)
            HStack {
                Button("Show Data Folder") {
                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: Settings.supportDirectory.path)
                }
                Button("Quit Mochi") { NSApp.terminate(nil) }
            }
            .padding(.top, 6)
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
