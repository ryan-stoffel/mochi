import AppKit
import WebKit

/// A regular window (Settings, the setup wizard) showing one of the app's pages on Mochi's paper.
///
/// The app hands the page its state with `page.update(state)`; the page posts `{type: 'ready'}` once loaded,
/// `{type: 'act', name, arg}` for clicks, `{type: 'size', h}` when its content changes height, and `{type: 'close'}`.
/// The window only appears once the page has drawn, so it never flashes blank or stale.
@MainActor
final class PageWindow: NSObject, WKScriptMessageHandler, NSWindowDelegate {

    let window: NSWindow
    private let web: Web.View
    private var loaded = false
    private var shown = false
    private var timer: Timer?
    var state: () -> [String: Any] = { [:] }
    /// You clicked something: an action name and its argument.
    var act: (String, String?) -> Void = { _, _ in }
    var closed: () -> Void = {}
    /// Grow and shrink the window to the page's height (Settings' panes), up to what fits on screen.
    var fitsContent = false

    /// The paper the pages are printed on (pet.css's --paper), so the title bar and any overscroll match.
    static let paper = NSColor(red: 1, green: 0.98, blue: 0.953, alpha: 1)

    init(page: String, title: String, size: NSSize, fullSize: Bool = true) {
        let cfg = WKWebViewConfiguration()
        web = Web.View(frame: NSRect(origin: .zero, size: size), configuration: cfg)
        var style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable]
        if fullSize { style.insert(.fullSizeContentView) }
        window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: style, backing: .buffered, defer: false)
        super.init()
        cfg.userContentController.add(Web.WeakHandler(self), name: "page")
        web.setValue(false, forKey: "drawsBackground")
        Web.load(page, in: web)
        window.title = title
        window.titleVisibility = fullSize ? .hidden : .visible
        window.titlebarAppearsTransparent = true
        window.backgroundColor = Self.paper
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = web
        // An accessory-policy app has no Dock icon to restore a window from, so a released window would be
        // unreachable: keep it and reuse it.
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
    }

    /// Brings the window up, once the page has drawn its state (straight away if it already has).
    func show() {
        shown = true
        guard loaded else { return }   // "ready" brings it up
        if window.isVisible { return front() }
        draw { [weak self] in self?.front() }
    }

    /// New state for the page; it only redraws what changed.
    func update() {
        guard loaded, window.isVisible else { return }
        draw()
    }

    func close() { window.close() }

    private func draw(then: (() -> Void)? = nil) {
        web.evaluateJavaScript("page.update(\(Web.json(state())))") { [weak self] result, _ in
            MainActor.assumeIsolated {
                if let h = (result as? [String: Any])?["h"] as? Double { self?.fit(h) }
                then?()
            }
        }
    }

    private func front() {
        guard shown else { return }
        // A menu-bar app isn't frontmost, and macOS may decline to activate it, so bring the window up regardless.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        window.makeFirstResponder(web)
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
    }

    /// Resizes to `h` points of page, keeping the title bar where it is; past the screen's height the page scrolls.
    private func fit(_ h: Double) {
        guard fitsContent, h > 0, let visible = (window.screen ?? NSScreen.main)?.visibleFrame else { return }
        let chrome = window.frame.height - window.contentLayoutRect.height
        let height = min(CGFloat(h).rounded(.up), visible.height - chrome - 40)
        guard abs(height - window.contentLayoutRect.height) > 0.5 else { return }
        var f = window.frame
        let newHeight = height + chrome
        f.origin.y += f.height - newHeight
        f.size.height = newHeight
        // growing downwards mustn't push the bottom off the screen
        if f.minY < visible.minY + 20 { f.origin.y = visible.minY + 20 }
        window.setFrame(f, display: true, animate: window.isVisible)
    }

    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        switch body["type"] as? String {
        case "ready":
            loaded = true
            if shown { shown = false; show() }
        case "act":
            if let name = body["name"] as? String { act(name, body["arg"] as? String) }
            update()
        case "size":
            if let h = body["h"] as? Double { fit(h) }
        case "close":
            close()
        default:
            break
        }
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated {
            shown = false
            timer?.invalidate()
            timer = nil
            closed()
        }
    }
}
