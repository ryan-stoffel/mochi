import Foundation

/// The app's bundled files (web/): Mochi's pet page with its fonts and icons, and the providers' logos.
enum Web {

    /// Contents/Resources/web in the app (./build.sh puts it there), or the repo's web/ when run straight from
    /// `swift run`.
    static let dir: URL? = {
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent()   // Sources/Mochi/Support
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("web")
        return [Bundle.main.resourceURL?.appendingPathComponent("web"), source].compactMap { $0 }
            .first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("index.html").path) }
    }()
}
