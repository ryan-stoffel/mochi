import CoreGraphics
import Foundation

/// Whether the notch is open, and whether its provider ring is showing, from nothing but where the pointer is and for
/// how long. `NotchController` feeds it the pointer 30 times a second; it has no timers or views of its own, so the
/// same input always gives the same answer.
///
/// - Opens once the pointer has rested on the pill (the bar beside the notch) for `openDwell`, so flicking past it on
///   the way to a menu doesn't pop it open.
/// - Stays open anywhere over the bar or the fan, gaps between wedges included, and closes `closeGrace` after the
///   pointer leaves, so grazing an edge doesn't close it.
/// - Shows the provider ring once the pointer has rested on the hub (stayed within a few points) for `ringDwell`, so
///   crossing the hub on the way down to a stat, however slowly, doesn't flash it. Keeps it while the pointer is
///   anywhere over the ring.
/// - After `close()` (a click elsewhere, the dropdown opening) it won't reopen until the pointer has left the pill.
struct NotchHover {
    enum Spot: Equatable { case away, bar, fan, hub }

    /// The notch's shapes, in the panel's own coordinates (y down from the top of the screen).
    struct Layout {
        var bar: CGRect             // the pill: notch plus the two flanks, full menu bar height
        var hub: CGPoint            // the hub's centre, on the bar's bottom edge
        var hubRadius: CGFloat      // the hub at rest
        var ringRadius: CGFloat     // the provider ring's outer edge
        var fanRadius: CGFloat      // the fan's outer edge, detail band included
    }

    static let openDwell = 0.06
    static let closeGrace = 0.22
    static let ringDwell = 0.25
    static let ringGrace = 0.15

    private(set) var open = false
    private(set) var ring = false
    private var armed = true
    private var spot = Spot.away
    private var since = 0.0
    private var restAt = CGPoint(x: -1e6, y: -1e6)
    private var restSince = 0.0

    /// Where `p` is, given what's showing. The fan only counts while it's open, and only below the bar: the menu bar
    /// beside the pill belongs to other menus.
    static func spot(of p: CGPoint, in l: Layout, open: Bool, ring: Bool) -> Spot {
        if l.bar.contains(p) { return .bar }
        guard open, p.y >= l.bar.maxY - 1 else { return .away }
        let d = hypot(p.x - l.hub.x, p.y - l.hub.y)
        // Once the ring shows, the whole ring counts as the hub; before that, only the hub's middle does.
        if d <= (ring ? l.ringRadius + 4 : l.hubRadius * 0.7) { return .hub }
        return d <= l.fanRadius ? .fan : .away
    }

    mutating func update(_ new: Spot, at now: Double, point p: CGPoint) {
        if new != spot { spot = new; since = now }
        if hypot(p.x - restAt.x, p.y - restAt.y) > 6 { restAt = p; restSince = now }
        let held = now - since
        if new == .away { armed = true }
        if !open {
            if new == .bar, armed, held >= Self.openDwell { open = true }
        } else if new == .away, held >= Self.closeGrace {
            open = false
            ring = false
        }
        guard open else { return }
        if new == .hub {
            if !ring, now - restSince >= Self.ringDwell { ring = true }
        } else if ring, held >= Self.ringGrace {
            ring = false
        }
    }

    /// Closes now, and stays closed until the pointer has moved off the pill.
    mutating func close() {
        open = false
        ring = false
        armed = false
    }
}
