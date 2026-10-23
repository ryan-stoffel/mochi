import AppKit
import MochiCore

/// Draws the menu bar icon: the selected provider's logo with its usage beside it in the menu bar's own font. A
/// template image, so macOS tints it like every other icon up there, light bar or dark.
enum TrayIconRenderer {

    private static let logoSize: CGFloat = 15

    /// `pct` nil shows "–" while there's nothing to show yet, or "!" when the provider is failing.
    static func icon(provider: String, pct: Int?, failing: Bool) -> NSImage {
        let label = pct.map { "\($0)%" } ?? (failing ? "!" : "–")
        let font = menuBarFont
        let text = NSAttributedString(string: label, attributes: [.font: font, .foregroundColor: NSColor.black])
        let gap: CGFloat = 5
        let height = NSStatusBar.system.thickness
        let size = NSSize(width: (logoSize + gap + text.size().width).rounded(.up), height: height)
        let logo = Logo.image(provider, template: true)

        let image = NSImage(size: size, flipped: false) { _ in
            let s = logoSize * Logo.scale(provider)
            let box = NSRect(x: (logoSize - s) / 2, y: ((height - s) / 2 * 2).rounded() / 2, width: s, height: s)
            if let logo {
                // the shape alone: a template's colour is ignored, only its coverage counts
                logo.draw(in: aspectFit(logo.size, in: box), from: .zero, operation: .sourceOver, fraction: 1)
            }
            // Centre the digits' cap height on the bar, like the clock and the battery percentage.
            let baseline = ((height - font.capHeight) / 2 * 2).rounded() / 2
            text.draw(at: NSPoint(x: logoSize + gap, y: baseline + font.descender))
            return true
        }
        image.isTemplate = true
        return image
    }

    private static func aspectFit(_ size: NSSize, in box: NSRect) -> NSRect {
        guard size.width > 0, size.height > 0 else { return box }
        let k = min(box.width / size.width, box.height / size.height)
        let w = size.width * k, h = size.height * k
        return NSRect(x: box.midX - w / 2, y: box.midY - h / 2, width: w, height: h)
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
}
