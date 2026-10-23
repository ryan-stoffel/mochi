import AppKit
import MochiCore

/// Draws the menu bar icon: the selected provider's critter as a pixel silhouette, with its usage beside it in the
/// menu bar's own font. A template image, so macOS tints it like every other icon up there, light bar or dark.
enum TrayIconRenderer {

    enum Mood { case fine, busy, error }

    /// The critter stands at most about this tall, in whole device pixels; short critters get chunkier pixels.
    private static let critterHeight: CGFloat = 18

    /// `pct` nil shows "–" while there's nothing to show yet, or "!" when the provider is failing.
    static func icon(provider: String, pct: Int?, mood: Mood) -> NSImage {
        let rows = silhouette(provider, mood: mood)
        let cols = rows.first?.count ?? 0
        // Whole device pixels on a 2x screen (1, 1.5, 2...), and never under 1pt so tall critters stay legible.
        let px = max(1, (critterHeight * 2 / CGFloat(max(rows.count, 1))).rounded(.down) / 2)
        let critter = NSSize(width: CGFloat(cols) * px, height: CGFloat(rows.count) * px)

        let label = pct.map { "\($0)%" } ?? (mood == .error ? "!" : "–")
        let font = menuBarFont
        let text = NSAttributedString(string: label, attributes: [.font: font, .foregroundColor: NSColor.black])
        let gap: CGFloat = 4
        let height = NSStatusBar.system.thickness
        let size = NSSize(width: (critter.width + gap + text.size().width).rounded(.up), height: height)

        let image = NSImage(size: size, flipped: false) { _ in
            NSColor.black.setFill()
            let bottom = ((height - critter.height) / 2 * 2).rounded() / 2
            for (j, row) in rows.enumerated() {
                for (i, ch) in row.enumerated() where ch == "#" {
                    NSRect(x: CGFloat(i) * px, y: bottom + CGFloat(rows.count - 1 - j) * px, width: px, height: px).fill()
                }
            }
            // Centre the digits' cap height on the bar, like the clock and the battery percentage.
            let baseline = ((height - font.capHeight) / 2 * 2).rounded() / 2
            text.draw(at: NSPoint(x: critter.width + gap, y: baseline + font.descender))
            return true
        }
        image.isTemplate = true
        return image
    }

    /// The menu bar's font with digits that don't jiggle as the number changes.
    private static let menuBarFont: NSFont = {
        let base = NSFont.menuBarFont(ofSize: 0)
        let descriptor = base.fontDescriptor.addingAttributes([.featureSettings: [[
            NSFontDescriptor.FeatureKey.typeIdentifier: kNumberSpacingType,
            NSFontDescriptor.FeatureKey.selectorIdentifier: kMonospacedNumbersSelector,
        ]]])
        return NSFont(descriptor: descriptor, size: base.pointSize) ?? base
    }()

    /// The critter as `#` (filled) and `.` (clear) rows, its eyes (or face screen) punched out so it still has a face
    /// in one colour. Drawn by scripts/tray-sprites.js from the critter itself.
    static func silhouette(_ provider: String, mood: Mood) -> [String] {
        (TraySprites.all[provider] ?? TraySprites.all["claude"]!).template
    }
}

extension NSColor {
    convenience init(hex: String) {
        var v: UInt64 = 0
        Scanner(string: hex.hasPrefix("#") ? String(hex.dropFirst()) : hex).scanHexInt64(&v)
        self.init(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                  blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }
}
