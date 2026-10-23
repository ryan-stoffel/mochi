import CoreGraphics
import Foundation

/// Whether the notch is open, from nothing but where the pointer is and for how long. `NotchController` feeds it the
/// pointer 30 times a second; it has no timers or views of its own, so the same input always gives the same answer.
///
/// - Opens once the pointer has rested on the pill (the bar beside the notch) for `openDwell`, so flicking past it on
///   the way to a menu doesn't pop it open.
/// - Stays open anywhere over the bar or the island, and closes `closeGrace` after the pointer leaves, so grazing an
///   edge doesn't close it.
/// - After `close()` (a click elsewhere) it won't reopen until the pointer has left the pill.
struct NotchHover {
    enum Spot: Equatable { case away, bar, island }

    /// The notch's shapes, in the panel's own coordinates (y down from the top of the screen).
    struct Layout {
        var bar: CGRect      // the pill: notch plus the two flanks, full menu bar height
        var island: CGRect   // the open island, bar included
    }

    static let openDwell = 0.06
    static let closeGrace = 0.22

    private(set) var open = false
    private var armed = true
    private var spot = Spot.away
    private var since = 0.0

    /// Where `p` is, given what's showing. The island only counts while it's open.
    static func spot(of p: CGPoint, in l: Layout, open: Bool) -> Spot {
        if l.bar.contains(p) { return .bar }
        return open && l.island.contains(p) ? .island : .away
    }

    mutating func update(_ new: Spot, at now: Double) {
        if new != spot { spot = new; since = now }
        let held = now - since
        if new == .away { armed = true }
        if !open {
            if new == .bar, armed, held >= Self.openDwell { open = true }
        } else if new == .away, held >= Self.closeGrace {
            open = false
        }
    }

    /// Closes now, and stays closed until the pointer has moved off the pill.
    mutating func close() {
        open = false
        armed = false
    }
}
