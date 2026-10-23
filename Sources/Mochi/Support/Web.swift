import AppKit
import WebKit

/// The app's pages (web/): every surface is one, in Mochi's pixel look, so they all share one stylesheet.
enum Web {

    /// The pages' folder: Contents/Resources/web in the app (./build.sh puts it there), or the repo's web/ when run
    /// straight from `swift run`.
    static let dir: URL? = {
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent()   // Sources/Mochi/Support
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("web")
        return [Bundle.main.resourceURL?.appendingPathComponent("web"), source].compactMap { $0 }
            .first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("ui.css").path) }
    }()

    static func load(_ page: String, in web: WKWebView) {
        guard let dir else { return NSLog("[web] pages not found") }
        web.loadFileURL(dir.appendingPathComponent(page), allowingReadAccessTo: dir)
    }

    static func json(_ obj: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: obj), let s = String(data: data, encoding: .utf8) else { return "{}" }
        return s
    }

    /// Takes the first click even when its window isn't key, so a page in a non-activating panel answers at once.
    final class View: WKWebView {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }

    /// WKUserContentController holds its handlers strongly; this breaks the cycle.
    final class WeakHandler: NSObject, WKScriptMessageHandler {
        weak var target: (WKScriptMessageHandler & AnyObject)?
        init(_ target: WKScriptMessageHandler & AnyObject) { self.target = target }
        func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
            target?.userContentController(c, didReceive: message)
        }
    }
}
