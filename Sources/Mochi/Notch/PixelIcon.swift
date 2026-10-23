import AppKit
import SwiftUI

/// The few pixel icons the fan uses, copied from web/icons.js with their colours from web/pet.js, so the notch speaks
/// the same little picture language as the panels and the speech bubble.
struct PixelIcon: View {
    let name: String
    var height: CGFloat = 12

    var body: some View {
        if let image = Self.image(name) {
            Image(decorative: image, scale: 1)
                .resizable()
                .interpolation(.none)   // crisp pixels, no smoothing
                .frame(width: height * CGFloat(image.width) / CGFloat(image.height), height: height)
        }
    }

    private static let sprites: [String: [String]] = [
        "bolt": ["...zz", "..zz.", ".zzzz", "..zz.", ".zz..", "zz..."],
        "clock": [".ggggg.", "gwwGwwg", "gwwGwwg", "gwwGGwg", "gwwwwwg", ".ggggg."],
        "moon": ["..zzz.", ".zz...", "zz....", "zz....", ".zz...", "..zzz."],
        "star": ["...z...", "..zzz..", "zzzzzzz", ".zzzzz.", ".zz.zz.", "z.....z"],
        "sparkle": ["..z..", "..z..", "zzwzz", "..z..", "..z.."],
        "battery": ["GGGGGGG.", "GRR...GG", "GRR...GG", "GGGGGGG."],
        "check": ["......M", ".....MM", "M...MM.", "MM.MM..", ".MMM...", "..M...."],
        "cross": ["c....c", "cc..cc", ".cccc.", ".cccc.", "cc..cc", "c....c"],
        "hand": [".b.b.b.", ".b.b.b.", ".bbbbbb", "bbbbbbb", ".bbbbb.", "..bbb.."],
        "bang": ["RR", "RR", "RR", "RR", "..", "RR"],
        "gear": ["...kkk...", ".kkkqkkk.", ".kqqqqqk.", "kkqqkqqkk", "kqqk.kqqk", "kkqqkqqkk", ".kqqqqqk.", ".kkkqkkk.", "...kkk..."],
        "refresh": ["..GGG.G", ".G...GG", "G...GGG", "G......", "G.....G", ".G...G.", "..GGG.."],
    ]

    private static let palette: [Character: String] = [
        "z": "#FFD54A", "w": "#FFFFFF", "g": "#A2A2AE", "G": "#6E6E7A", "k": "#26252B", "q": "#D7D7DE",
        "M": "#3F9A4C", "c": "#C23B39", "R": "#EF5350", "b": "#E5714B",
    ]

    private static var cache: [String: CGImage] = [:]

    static func image(_ name: String) -> CGImage? {
        if let hit = cache[name] { return hit }
        guard let rows = sprites[name] else { return nil }
        let w = rows.map(\.count).max() ?? 1, h = rows.count
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        for (j, row) in rows.enumerated() {
            for (i, ch) in row.enumerated() {
                guard let hex = palette[ch] else { continue }
                ctx.setFillColor(NSColor(hex: hex).cgColor)
                ctx.fill(CGRect(x: i, y: h - 1 - j, width: 1, height: 1))   // CG's origin is bottom-left
            }
        }
        let image = ctx.makeImage()
        cache[name] = image
        return image
    }
}
