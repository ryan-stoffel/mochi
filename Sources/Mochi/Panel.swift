// Mochi's panel: what opens when you right-click Mochi. A big pixel speech bubble (web/panel.html) in a `BubblePanel`,
// its tail pointing at Mochi. App decides what's in it (`panelState`) and does what you click (`perform`).
import Foundation

/// Something you clicked in the panel.
enum PanelAction {
    case pet(String), size(Double), toggle(String), focus(String), provider(String), roam, appAware, emoji, quiet, login,
         corner, visible, connect, follow, narrate, refreshUsage, settings, quit

    init?(name: String, arg: String?) {
        switch name {
        case "pet": guard let arg else { return nil }; self = .pet(arg)
        case "size": guard let s = arg.flatMap(Double.init) else { return nil }; self = .size(s)
        case "toggle": guard let arg else { return nil }; self = .toggle(arg)
        case "focus": guard let arg else { return nil }; self = .focus(arg)
        case "provider": guard let arg else { return nil }; self = .provider(arg)
        case "roam": self = .roam
        case "appAware": self = .appAware
        case "emoji": self = .emoji
        case "quiet": self = .quiet
        case "login": self = .login
        case "corner": self = .corner
        case "visible": self = .visible
        case "connect": self = .connect
        case "follow": self = .follow
        case "narrate": self = .narrate
        case "refreshUsage": self = .refreshUsage
        case "settings": self = .settings
        case "quit": self = .quit
        default: return nil
        }
    }
}

/// "3:10 PM" today, "Fri 9:00 AM" further out.
func panelTime(_ d: Date) -> String {
    let f = DateFormatter()
    f.setLocalizedDateFormatFromTemplate(d.timeIntervalSinceNow < 20 * 3600 ? "jmm" : "EEE jmm")
    return f.string(from: d)
}
