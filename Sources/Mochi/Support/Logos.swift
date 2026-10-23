import AppKit
import SwiftUI

/// Each provider's own logo (web/logos). Claude's and Gemini's keep their colours; OpenAI's (Codex) and Cursor's are
/// one-colour marks that take the colour of the text around them. Antigravity runs on Gemini, so it wears Gemini's.
enum Logo {
    private static var images: [String: NSImage] = [:]

    /// Gemini's colour version is a PNG: NSImage leaves out its SVG's blurs, which are most of its gradient.
    private static func file(_ id: String, template: Bool) -> String {
        switch id {
        case "antigravity": return template ? "gemini.svg" : "gemini.png"
        default: return id + ".svg"
        }
    }

    static func isColored(_ id: String) -> Bool { id == "claude" || id == "antigravity" }

    /// How much bigger to draw it than its box: OpenAI's SVG has a wide margin built in, the others are edge to edge.
    static func scale(_ id: String) -> CGFloat { id == "codex" ? 1.42 : 1 }

    static func image(_ id: String, template: Bool = false) -> NSImage? {
        let name = file(id, template: template)
        if let hit = images[name] { return hit }
        guard let dir = Web.dir, let img = NSImage(contentsOf: dir.appendingPathComponent("logos/" + name)) else { return nil }
        images[name] = img
        return img
    }
}

/// A provider's logo, `size` points square.
struct ProviderLogo: View {
    let id: String
    var size: CGFloat = 16

    var body: some View {
        Group {
            if let image = Logo.image(id) {
                if Logo.isColored(id) {
                    Image(nsImage: image).resizable().interpolation(.high)
                } else {
                    Image(nsImage: image).renderingMode(.template).resizable().interpolation(.high)
                }
            } else {
                Image(systemName: "sparkle").resizable()
            }
        }
        .aspectRatio(contentMode: .fit)
        .scaleEffect(Logo.scale(id))
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
