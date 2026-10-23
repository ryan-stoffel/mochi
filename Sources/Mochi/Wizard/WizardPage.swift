import AppKit
import SwiftUI
import MochiCore

/// First-run setup: welcome → your tools → where usage shows (only with a notch) → Mochi the pet and open at login.
@MainActor
final class WizardPage: NSObject, NSWindowDelegate {
    private let model: SettingsModel
    private var window: NSWindow?

    init(model: SettingsModel) {
        self.model = model
    }

    func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 460),
                             styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.contentView = NSHostingView(rootView: WizardView(model: model, finish: { [weak self] in self?.finish() }))
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func finish() {
        Settings.shared.setupComplete = true
        window?.close()
    }

    func windowWillClose(_ notification: Notification) { window = nil }
}

private struct WizardView: View {
    @ObservedObject var model: SettingsModel
    let finish: () -> Void
    @State private var step = 0
    @State private var mode = Settings.shared.displayMode

    private enum Step { case welcome, tools, place, mochi }
    private var steps: [Step] { NotchGeometry.hasHardwareNotch ? [.welcome, .tools, .place, .mochi] : [.welcome, .tools, .mochi] }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch steps[step] {
                case .welcome: welcome
                case .tools: tools
                case .place: place
                case .mochi: mochi
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.horizontal, 32)
            .padding(.top, 44)
            footer
        }
        .frame(width: 480, height: 460)
        .background(.background)
    }

    private var footer: some View {
        HStack {
            HStack(spacing: 6) {
                ForEach(steps.indices, id: \.self) { i in
                    Circle().fill(i == step ? AnyShapeStyle(.primary) : AnyShapeStyle(.quaternary)).frame(width: 6, height: 6)
                }
            }
            Spacer()
            if step > 0 { Button("Back") { step -= 1 } }
            Button(step == steps.count - 1 ? "Done" : "Continue") {
                if step == steps.count - 1 { finish() } else { step += 1 }
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding(20)
    }

    private func title(_ t: String, _ sub: String) -> some View {
        VStack(spacing: 6) {
            Text(t).font(.title2.weight(.semibold))
            Text(sub).foregroundStyle(.secondary).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var welcome: some View {
        VStack(spacing: 28) {
            HStack(spacing: 22) { ForEach(Provider.all) { ProviderLogo(id: $0.id, size: 44) } }
                .padding(.top, 30)
            title("Welcome to Mochi",
                  "Your Claude, Codex, Antigravity and Cursor limits, in the menu bar. Mochi reads them with the sign-ins those tools already have. Nothing leaves your Mac.")
        }
    }

    private var tools: some View {
        VStack(spacing: 18) {
            title("Your tools", "Anything that isn't installed is skipped. You can add it later in Settings.")
            VStack(spacing: 0) {
                ForEach(Provider.all) { p in
                    let line = model.usage.statusLine(p.id)
                    HStack(spacing: 10) {
                        ProviderLogo(id: p.id, size: 22)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(p.name)
                            Text(line.text).font(.caption).foregroundStyle(color(line.tone)).lineLimit(2)
                        }
                        Spacer()
                        if let fix = model.usage.blocker(p.id)?.fix, fix == .install || fix == .logIn {
                            Button(fix.title) { model.usage.perform(fix, for: p.id) }.controlSize(.small)
                        } else if line.tone == .good {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        }
                    }
                    .padding(.vertical, 9).padding(.horizontal, 12)
                    if p.id != Provider.all.last?.id { Divider().padding(.leading, 44) }
                }
            }
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            Button("Check Again") { Task { await model.usage.refresh() } }.controlSize(.small)
        }
    }

    private var place: some View {
        VStack(spacing: 22) {
            title("Where should it live?", "You can change this any time in Settings.")
            HStack(spacing: 14) {
                option(.tray, "Menu Bar", "menubar.rectangle", "An icon with your usage, next to the clock.")
                option(.notch, "Notch", "macbook", "Beside the camera. Rest the pointer on it for every limit.")
            }
        }
    }

    private func option(_ m: DisplayMode, _ name: String, _ symbol: String, _ line: String) -> some View {
        Button {
            mode = m
            Settings.shared.displayMode = m
            model.onDisplayModeChange(m)
        } label: {
            VStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 34, weight: .light)).frame(height: 44)
                Text(name).font(.headline)
                Text(line).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 150)
            .background(.quaternary.opacity(mode == m ? 0.9 : 0.35), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(mode == m ? Color.accentColor : .clear, lineWidth: 2))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var mochi: some View {
        VStack(spacing: 22) {
            title("Almost done", "Mochi can also live on your desktop as a pixel pet: it acts out what your agent is doing and tells you when it needs you.")
            Form {
                Toggle("Show Mochi on my desktop", isOn: model.petToggle("visible", default: false))
                if model.pet("visible", false) {
                    Picker("Follows", selection: Binding(get: { model.pet("provider", "claude") }, set: { model.setPet("provider", $0) })) {
                        Text("Claude").tag("claude")
                        Text("Codex").tag("codex")
                    }
                    .pickerStyle(.segmented)
                }
                Toggle("Open Mochi at login", isOn: model.openAtLogin)
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .scrollDisabled(true)
            .frame(height: 170)
        }
    }

    private func color(_ tone: UsageService.Tone) -> Color {
        switch tone {
        case .plain: return .secondary
        case .good: return .green
        case .warning: return .orange
        case .bad: return .red
        }
    }
}
