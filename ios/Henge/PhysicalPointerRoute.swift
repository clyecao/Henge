import Foundation

enum PhysicalPointerRoute {
    case inactive, relative, absolute

    init(active: Bool, locked: Bool, localDisplay: Bool) {
        if !active { self = .inactive }
        else if locked || !localDisplay { self = .relative }
        else { self = .absolute }
    }

    /// Both rectangles and event locations are in the input surface's points, including when zoomed.
    /// Project the letterbox onto the nearest desktop edge. The last host point must reach the last guest pixel.
    static func position(_ p: CGPoint, in screen: CGRect) -> CGPoint? {
        guard screen.width > 1, screen.height > 1, p.x.isFinite, p.y.isFinite else { return nil }
        return CGPoint(x: min(1, max(0, (p.x - screen.minX) / (screen.width - 1))),
                       y: min(1, max(0, (p.y - screen.minY) / (screen.height - 1))))
    }
}
