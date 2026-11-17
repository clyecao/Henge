import Foundation

enum ScrollSensitivity {
    static let key = "henge.mouse.scrollSpeed"
    static let defaultValue = 0.3
    static let range = 0.05...1.5

    static func clamped(_ value: Double) -> Double {
        guard value.isFinite else { return defaultValue }
        return min(max(value, range.lowerBound), range.upperBound)
    }
}

// Fractional wheel conversion adapted from upstream PR #98, commit bd5236963fcf.
// A raw trackpad delta is not a wheel detent: the old 22 * scale * sqrt(delta)
// mapping amplified tiny movements and emitted up to 32 detents per callback.
struct WheelScroll {
    private var remainder = 0.0

    mutating func units(for value: Float, sensitivity: Double) -> Int32 {
        guard value.isFinite, value != 0 else { return 0 }
        // Bound bursts before scaling, so even fast swipes respect the slider.
        let bounded = min(max(Double(value), -4), 4)
        remainder += bounded * 2 * ScrollSensitivity.clamped(sensitivity)
        let whole = remainder.rounded(.towardZero)
        remainder -= whole
        return Int32(whole)
    }
}

/// Limit sustained wheel output as well as individual callbacks. A 125 Hz pad
/// could otherwise deliver 50 detents/second even at the minimum sensitivity.
/// There is no pending queue: excess whole detents are discarded immediately.
private struct ScrollRateLimit {
    private var credit: Double?

    mutating func apply(_ amount: Int32, sensitivity: Double, elapsed: TimeInterval) -> Int32 {
        let scale = ScrollSensitivity.clamped(sensitivity)
        // Preserve a short gesture's initial response. Refilling depends on time,
        // not callback count: at 0.05, allow one initial detent then 6 per second.
        let burst = max(1, (8 * scale).rounded(.up))
        let available = min(burst, (credit ?? burst) + min(elapsed, 1) * 120 * scale)
        let sent = min(abs(Double(amount)), available.rounded(.down))
        credit = available - sent
        return amount < 0 ? -Int32(sent) : Int32(sent)
    }
}

/// One hardware device's axis state and fractional motion. GameController sends
/// both axis values when either changes; forwarding the stale axis doubles motion.
struct PhysicalMouseScroll {
    private var lastFirst: Float = 0, lastSecond: Float = 0
    private var lastTimestamp: TimeInterval?
    private var horizontal = WheelScroll()
    private var vertical = WheelScroll()
    private var horizontalRate = ScrollRateLimit()
    private var verticalRate = ScrollRateLimit()

    mutating func consume(first: Float, second: Float, sensitivity: Double,
                          reversed: Bool, timestamp: TimeInterval) -> (dx: Int32, dy: Int32) {
        guard first.isFinite, second.isFinite, timestamp.isFinite, timestamp >= 0 else { return (0, 0) }
        let elapsed = lastTimestamp.map { timestamp - $0 } ?? 0
        guard elapsed >= 0 else { return (0, 0) }
        lastTimestamp = timestamp
        let verticalChanged = first != lastFirst
        let horizontalChanged = second != lastSecond
        lastFirst = first
        lastSecond = second
        // Retain the existing dominant-axis filter for slight sideways finger drift.
        let mostlyVertical = abs(Double(first)) > 2 * abs(Double(second))
        let mostlyHorizontal = abs(Double(second)) > 2 * abs(Double(first))
        let verticalRaw = verticalChanged && !mostlyHorizontal ? -first : 0
        let horizontalRaw = horizontalChanged && !mostlyVertical ? second : 0
        let way: Int32 = reversed ? -1 : 1
        let dx = horizontal.units(for: horizontalRaw, sensitivity: sensitivity)
        let dy = vertical.units(for: verticalRaw, sensitivity: sensitivity)
        return (way * horizontalRate.apply(dx, sensitivity: sensitivity, elapsed: elapsed),
                way * verticalRate.apply(dy, sensitivity: sensitivity, elapsed: elapsed))
    }
}
