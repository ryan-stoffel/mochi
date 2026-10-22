// Mochi's panel: what opens when you right-click Mochi. A big pixel speech bubble (web/panel.html, the same look as
// the one Mochi talks in) in its own floating window, with its tail pointing at Mochi. This file is the window and
// the messages to and from the page; App decides what's in it and does what you click.
import AppKit
import WebKit

/// Something you clicked in the panel.
enum PanelAction {
    case pet(String), size(Double), toggle(String), project(String), roam, appAware, emoji, quiet, login, corner, visible
    case connect, follow, narrate, checkUsage, refreshUsage, quit

    init?(name: String, arg: String?) {
        switch name {
        case "pet": guard let arg else { return nil }; self = .pet(arg)
        case "size": guard let s = arg.flatMap(Double.init) else { return nil }; self = .size(s)
        case "roam": self = .roam
        case "appAware": self = .appAware
        case "emoji": self = .emoji
        case "toggle": guard let arg else { return nil }; self = .toggle(arg)
        case "project": guard let arg else { return nil }; self = .project(arg)
        case "quiet": self = .quiet
        case "login": self = .login
        case "corner": self = .corner
        case "visible": self = .visible
        case "connect": self = .connect
        case "follow": self = .follow
        case "narrate": self = .narrate
        case "checkUsage": self = .checkUsage
        case "refreshUsage": self = .refreshUsage
        case "quit": self = .quit
        default: return nil
        }
    }
}

/// Takes key focus without activating Mochi, so Escape reaches the page.
final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

final class PanelController: NSObject, WKScriptMessageHandler {
    private let window: KeyPanel
    private let web: PetWebView
    private var monitors: [Any] = []
    private var timer: Timer?
    private var size = NSSize(width: 340, height: 300)   // the page reports its real size
    private var mochi = (x: CGFloat(0), top: CGFloat(0), feet: CGFloat(0))
    private var below = false
    var state: () -> [String: Any] = { [:] }
    var act: (PanelAction) -> Void = { _ in }
    var opened: (Bool) -> Void = { _ in }   // Mochi holds up a gear while it's open
    var isOpen: Bool { window.isVisible }

    init(webDir: URL) {
        let cfg = WKWebViewConfiguration()
        web = PetWebView(frame: NSRect(origin: .zero, size: size), configuration: cfg)
        web.setValue(false, forKey: "drawsBackground")
        window = KeyPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        super.init()
        cfg.userContentController.add(self, name: "panel")
        web.loadFileURL(webDir.appendingPathComponent("panel.html"), allowingReadAccessTo: webDir)
        window.contentView = web
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false   // the bubble draws its own pixel shadow
        window.level = .statusBar
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
    }

    /// Opens pointing at Mochi: `x` its middle, `top` just over its head, `feet` under it (screen coordinates).
    /// Right-clicking Mochi again closes it.
    func show(x: CGFloat, top: CGFloat, feet: CGFloat) {
        if isOpen { return close() }
        mochi = (x, top, feet)
        below = !fitsAbove(size.height)
        place()
        window.orderFrontRegardless()
        window.makeKey()
        window.makeFirstResponder(web)   // before the page draws, so it can put focus on the card itself
        web.evaluateJavaScript("panel.show(\(Self.json(state())), \(below))")
        opened(true)

        // nothing closes a borderless panel by itself: a click anywhere else does
        let outside: (NSEvent) -> Void = { [weak self] e in
            guard let self, e.window !== self.window else { return }
            self.close()
        }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: outside) { monitors.append(m) }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.update() }
    }

    /// New numbers for the page; it only redraws when something changed.
    func update() {
        guard isOpen else { return }
        web.evaluateJavaScript("panel.update(\(Self.json(state())))")
    }

    func close() {
        guard isOpen else { return }
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        timer?.invalidate()
        timer = nil
        window.orderOut(nil)
        opened(false)
    }

    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        switch body["type"] as? String {
        case "size":
            size = NSSize(width: body["w"] as? Double ?? size.width, height: body["h"] as? Double ?? size.height)
            if isOpen { place() }
        case "act":
            if let name = body["name"] as? String, let a = PanelAction(name: name, arg: body["arg"] as? String) { act(a) }
        case "tab":
            UserDefaults.standard.set(body["tab"] as? String, forKey: "panelTab")
        case "close":
            close()
        default:
            break
        }
    }

    private func screen() -> NSRect {
        let p = NSPoint(x: mochi.x, y: mochi.feet + 1)
        return (NSScreen.screens.first { $0.frame.contains(p) } ?? NSScreen.main ?? NSScreen.screens[0]).visibleFrame
    }

    private func fitsAbove(_ h: CGFloat) -> Bool { mochi.top + h <= screen().maxY }

    /// Above Mochi's head if there's room, under its feet if not; slid sideways to stay on screen, tail on Mochi.
    private func place() {
        let v = screen()
        let x = min(max(mochi.x - size.width / 2, v.minX + 4), v.maxX - size.width - 4)
        let y = min(max(below ? mochi.feet - size.height : mochi.top, v.minY), v.maxY - size.height)
        let tail = min(max(mochi.x - x, 28), size.width - 28)
        web.evaluateJavaScript("panel.place(\(Int(tail)), \(below))")
        window.setFrame(NSRect(x: x.rounded(), y: y.rounded(), width: size.width, height: size.height), display: true)
    }

    private static func json(_ obj: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: obj), let s = String(data: data, encoding: .utf8) else { return "{}" }
        return s
    }

    /// "3:10 PM" today, "Fri 9:00 AM" further out.
    static func when(_ d: Date) -> String {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate(d.timeIntervalSinceNow < 20 * 3600 ? "jmm" : "EEE jmm")
        return f.string(from: d)
    }
}
