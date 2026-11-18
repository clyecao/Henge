import Foundation

@main
struct PhysicalMouseScrollTests {
    static var checks = 0
    static var sampleTime: TimeInterval = 0

    // Isolate conversion/axis tests from the rate limit. Timed traces below test
    // sustained input and callback bursts with explicit sample timestamps.
    static func tick() -> TimeInterval {
        sampleTime += 1
        return sampleTime
    }

    static func check(_ condition: Bool, _ message: String) {
        checks += 1
        guard condition else { fatalError(message) }
    }

    static func checkDelta(_ actual: (dx: Int32, dy: Int32), _ dx: Int32, _ dy: Int32, _ message: String) {
        check(actual.dx == dx && actual.dy == dy, "\(message): got \(actual), expected \(dx), \(dy)")
    }

    static func main() {
        // Small movements must accumulate rather than each becoming a wheel click.
        // Zero reports between movements must not discard sub-detent motion.
        var fine = WheelScroll()
        for _ in 0..<3 {
            check(fine.units(for: 0.25, sensitivity: 0.5) == 0, "tiny movement must not jump")
            check(fine.units(for: 0, sensitivity: 0.5) == 0, "zero must not emit motion")
        }
        check(fine.units(for: 0.25, sensitivity: 0.5) == 1, "fractions must eventually make a detent")
        check(fine.units(for: -0.5, sensitivity: 0.5) == 0, "negative fraction must wait")
        check(fine.units(for: -0.5, sensitivity: 0.5) == -1, "negative fractions must accumulate")

        // Same path as HardwareMouse: a recorded fast swipe formerly generated
        // tens of detents per callback. Replay its actual sample intervals too.
        var recorded = PhysicalMouseScroll()
        let samples: [Float] = [0.017333984, 9.184784, 36.241714, 51.288696, 0]
        let times: [TimeInterval] = [0, 0.02443, 0.04816, 0.07292, 0.28139]
        let expected: [Int32] = [-1, -2, -1, -1, 0]
        for i in samples.indices {
            checkDelta(recorded.consume(first: samples[i], second: 0, sensitivity: 0.3,
                                        reversed: false, timestamp: times[i]),
                       0, expected[i], "captured vertical swipe")
        }

        // A sample can arrive in two callbacks, with the other axis unchanged.
        // Diagonal motion must not replay that stale axis or swap X and Y.
        var axes = PhysicalMouseScroll()
        checkDelta(axes.consume(first: 2, second: 0, sensitivity: 0.5, reversed: false, timestamp: tick()), 0, -2, "vertical axis")
        checkDelta(axes.consume(first: 2, second: 2, sensitivity: 0.5, reversed: false, timestamp: tick()), 2, 0, "stale vertical")
        checkDelta(axes.consume(first: 2, second: 2, sensitivity: 0.5, reversed: false, timestamp: sampleTime), 0, 0, "duplicate callback")
        checkDelta(axes.consume(first: 0, second: 2, sensitivity: 0.5, reversed: false, timestamp: tick()), 0, 0, "vertical reset")
        checkDelta(axes.consume(first: 0, second: 0, sensitivity: 0.5, reversed: false, timestamp: tick()), 0, 0, "horizontal reset")
        checkDelta(axes.consume(first: -2, second: -2, sensitivity: 0.5, reversed: false, timestamp: tick()), -2, 2, "negative diagonal")
        axes = PhysicalMouseScroll()
        checkDelta(axes.consume(first: 4, second: 1, sensitivity: 0.5, reversed: false, timestamp: tick()), 0, -4, "sideways drift filter")
        axes = PhysicalMouseScroll()
        checkDelta(axes.consume(first: 1, second: 4, sensitivity: 0.5, reversed: false, timestamp: tick()), 4, 0, "vertical drift filter")

        var forward = PhysicalMouseScroll(), reverse = PhysicalMouseScroll()
        for sample in samples {
            let a = forward.consume(first: sample, second: 0, sensitivity: 0.3, reversed: false, timestamp: tick())
            let b = reverse.consume(first: sample, second: 0, sensitivity: 0.3, reversed: true, timestamp: tick())
            checkDelta(b, -a.dx, -a.dy, "reverse scrolling must preserve distance")
        }

        // Disconnected devices/sessions start with fresh state. Two simultaneously
        // attached devices must not share the previous axis value or fractions.
        var deviceA = PhysicalMouseScroll(), deviceB = PhysicalMouseScroll()
        _ = deviceA.consume(first: 1, second: 0, sensitivity: 0.5, reversed: false, timestamp: 0)
        _ = deviceB.consume(first: 1, second: 0, sensitivity: 0.5, reversed: false, timestamp: 0)
        checkDelta(deviceA.consume(first: 0.5, second: 0, sensitivity: 0.5, reversed: false, timestamp: 0.01), 0, 0, "device A fraction")
        checkDelta(deviceB.consume(first: 0.5, second: 0, sensitivity: 0.5, reversed: false, timestamp: 0.01), 0, 0, "device B independent")
        _ = deviceA.consume(first: 0, second: 0, sensitivity: 0.5, reversed: false, timestamp: 0.015)
        checkDelta(deviceA.consume(first: 0.5, second: 0, sensitivity: 0.5, reversed: false, timestamp: 0.02), 0, -1, "device A retained fraction")
        deviceA = PhysicalMouseScroll()
        checkDelta(deviceA.consume(first: 0.5, second: 0, sensitivity: 0.5, reversed: false, timestamp: 0.02), 0, -1, "first detent after reconnect")
        checkDelta(deviceA.consume(first: 0.5, second: 0, sensitivity: 0.5, reversed: false, timestamp: 0.03), 0, 0, "reconnect reset remainder")

        // Invalid input must not poison the last valid axis state or the remainder.
        var invalid = PhysicalMouseScroll()
        _ = invalid.consume(first: 1, second: 0, sensitivity: 0.5, reversed: false, timestamp: 0)
        checkDelta(invalid.consume(first: 0.5, second: 0, sensitivity: 0.5, reversed: false, timestamp: 0.01), 0, 0, "fraction before invalid input")
        for bad in [Float.nan, .infinity, -.infinity] {
            checkDelta(invalid.consume(first: bad, second: 2, sensitivity: 0.5, reversed: false, timestamp: 0.02), 0, 0, "invalid first axis")
            checkDelta(invalid.consume(first: 2, second: bad, sensitivity: 0.5, reversed: false, timestamp: 0.02), 0, 0, "invalid second axis")
        }
        checkDelta(invalid.consume(first: 0.75, second: 0, sensitivity: 0.5, reversed: false, timestamp: 0.03), 0, -1, "recover after invalid input")
        check(ScrollSensitivity.clamped(.nan) == 0.3, "NaN setting must use default")
        check(ScrollSensitivity.clamped(.infinity) == 0.3, "infinite setting must use default")
        check(ScrollSensitivity.clamped(-1) == 0.05, "negative setting must use minimum")
        check(ScrollSensitivity.clamped(99) == 1.5, "large setting must use maximum")
        var changingSpeed = WheelScroll()
        check(changingSpeed.units(for: 1, sensitivity: 0.125) == 0, "low speed remainder")
        check(changingSpeed.units(for: 1, sensitivity: 0.5) == 1, "speed changes take effect on the next sample")

        // Long streams conserve fractional motion within one detent. Bursts at
        // every supported sensitivity stay bounded, including finite Float extremes.
        for sensitivity in [0.05, 0.1, 0.3, 0.5, 1.5] {
            for value in [Float(0.017333984), 0.25, 1, 4, 51.288696, .greatestFiniteMagnitude] {
                var positive = WheelScroll(), negative = WheelScroll()
                var total = 0
                for _ in 0..<100 {
                    let a = positive.units(for: value, sensitivity: sensitivity)
                    let b = negative.units(for: -value, sensitivity: sensitivity)
                    check(a == -b, "signed motion must be symmetric")
                    check(a >= 0 && a <= Int32(ceil(8 * sensitivity)), "per-event sensitivity bound")
                    total += Int(a)
                }
                let distance = min(Double(value), 4) * 2 * sensitivity * 100
                check(abs(Double(total) - distance) < 1.000001, "long stream must conserve fractions")
            }
        }
        testSlowWheel()
        testMagicKeyboardSwipe()
        testSustainedScrolling()
        testBurstsAndClock()
        print("PASS: physical mouse scrolling, \(checks) checks; slow detents and sustained rate")
    }

    static func testSlowWheel() {
        var wheel = PhysicalMouseScroll()
        for i in 0..<8 {
            let time = Double(i) * 0.25
            let raw: Float = i < 4 ? 0.02 : -0.02
            let expected: Int32 = i < 4 ? -1 : 1
            checkDelta(wheel.consume(first: raw, second: 0, sensitivity: 0.05, reversed: false, timestamp: time),
                       0, expected, "each isolated wheel notch must reach the guest at minimum speed")
            checkDelta(wheel.consume(first: raw, second: 0, sensitivity: 0.05, reversed: false, timestamp: time + 0.0001),
                       0, 0, "same report must not double a slow detent")
            if i.isMultiple(of: 2) {
                checkDelta(wheel.consume(first: 0, second: 0, sensitivity: 0.05, reversed: false, timestamp: time + 0.22),
                           0, 0, "late reset must not use the next isolated step")
            }
        }
        var fine = PhysicalMouseScroll()
        var detents: Int32 = 0
        for i in 0..<40 {
            detents += fine.consume(first: 0, second: 0.02, sensitivity: 0.05, reversed: false,
                                    timestamp: Double(i) * 0.025).dx
        }
        check((5...6).contains(detents), "a second of fine wheel motion must keep moving at minimum speed")
    }

    static func testMagicKeyboardSwipe() {
        // 115 ms of vertical scrolling on an iPad14,6. GameController reports
        // the second axis separately while repeating the first axis's value.
        let samples: [(ms: Double, first: Float, second: Float)] = [
            (0.00, 0.042037964, 0),       (6.03, 0.45173645, 0),
            (14.37, 1.5735626, 0),        (24.11, 1.397522, 0),
            (32.35, 0.86273193, 0),       (39.52, 1.4241333, 0),
            (47.66, 1.8645935, 0),        (47.73, 1.8645935, 0.08061218),
            (56.20, 1.2787476, 0.08061218), (56.25, 1.2787476, 0.14537048),
            (64.52, 1.0619354, 0.14537048), (64.56, 1.0619354, 0.11050415),
            (72.91, 1.6313477, 0.11050415), (72.95, 1.6313477, 0.16104126),
            (81.21, 1.43396, 0.16104126), (81.25, 1.43396, 0),
            (89.60, 1.4440155, 0),        (89.64, 1.4440155, 0.12904358),
            (97.98, 1.4630127, 0.12904358), (98.03, 1.4630127, 0.11172485),
            (105.94, 1.0835876, 0.11172485), (105.98, 1.0835876, 0),
            (114.52, 0.9919281, 0),       (114.57, 0.9919281, 0.15281677),
        ]
        for (speed, steps) in [(0.3, [0, 2, 3, 5, 8, 16]), (0.05, [0])] {
            var scroll = PhysicalMouseScroll()
            for (i, sample) in samples.enumerated() {
                let delta = scroll.consume(first: sample.first, second: sample.second, sensitivity: speed,
                                           reversed: false, timestamp: sample.ms / 1000)
                checkDelta(delta, 0, steps.contains(i) ? -1 : 0, "Magic Keyboard callback \(i) at \(speed)")
            }
            checkDelta(scroll.consume(first: 0, second: 0, sensitivity: speed, reversed: false, timestamp: 1),
                       0, 0, "lifting fingers must not replay clipped wheel movement")
        }
    }

    static func testSustainedScrolling() {
        // The reported regression: at 0.05 a short swipe is fine, but a long
        // 125 Hz swipe still emits about 50 detents/second without a time limit.
        // Check ten seconds at multiple callback rates and at every slider setting.
        for hz in [30, 60, 125, 1000] {
            for sensitivity in [0.05, 0.1, 0.3, 0.5, 1.5] {
                var scroll = PhysicalMouseScroll()
                var total = 0, firstHalf = 0
                let rate = 120 * sensitivity
                let burst = max(1, ceil(8 * sensitivity))
                for i in 0..<(hz * 10) {
                    let time = Double(i) / Double(hz)
                    // Alternating raw values reflect separate changed-axis samples.
                    let raw: Float = i.isMultiple(of: 2) ? 4 : 5
                    let result = scroll.consume(first: raw, second: 0, sensitivity: sensitivity,
                                                reversed: false, timestamp: time)
                    check(result.dx == 0 && result.dy <= 0, "long swipe must keep its axis and direction")
                    total += Int(-result.dy)
                    check(Double(total) <= burst + rate * time + 0.000001,
                          "total output must obey elapsed time, not callback count")
                    if i == hz * 5 - 1 { firstHalf = total }
                }
                check(total > Int(rate * 7), "rate limit must not stall sustained input")
                check(total - firstHalf <= firstHalf + Int(burst), "a longer swipe must not ramp up its rate")
                if sensitivity == 0.05 {
                    check(total <= 61, "minimum setting: at most one initial detent plus six per second")
                }
                // No replay of clipped whole detents on release or during idle.
                checkDelta(scroll.consume(first: 0, second: 0, sensitivity: sensitivity,
                                          reversed: false, timestamp: 10), 0, 0, "release without queued motion")
                checkDelta(scroll.consume(first: 0, second: 0, sensitivity: sensitivity,
                                          reversed: false, timestamp: 100), 0, 0, "idle without queued motion")
            }
        }
        // Horizontal scrolling and rapidly changing direction use the same limit.
        var horizontal = PhysicalMouseScroll()
        var total = 0
        for i in 0..<1000 {
            let raw: Float = i.isMultiple(of: 2) ? 4 : -4
            let result = horizontal.consume(first: 0, second: raw, sensitivity: 0.5,
                                            reversed: false, timestamp: Double(i) / 1000)
            check(result.dy == 0 && (result.dx == 0 || (result.dx > 0) == (raw > 0)), "horizontal direction")
            total += Int(abs(result.dx))
        }
        check(total <= 64, "direction changes must not reset the rate budget")
    }

    static func testBurstsAndClock() {
        var scroll = PhysicalMouseScroll()
        var total: Int32 = 0
        // Main-thread callbacks arriving together must not create a guest burst.
        for i in 0..<100 {
            let raw: Float = i.isMultiple(of: 2) ? 4 : 5
            total -= scroll.consume(first: raw, second: 0, sensitivity: 0.5,
                                    reversed: false, timestamp: 1).dy
        }
        check(total == 4, "same-time callbacks may only spend the initial burst allowance")
        for time in [Double.nan, .infinity, -1, 0.5] {
            checkDelta(scroll.consume(first: 9, second: 0, sensitivity: 0.5,
                                      reversed: false, timestamp: time), 0, 0, "invalid/backward clock")
        }
        checkDelta(scroll.consume(first: 9, second: 0, sensitivity: 0.5,
                                  reversed: false, timestamp: 2), 0, -4, "clock errors must not poison axis state")
        checkDelta(scroll.consume(first: 0, second: 0, sensitivity: 0.5,
                                  reversed: false, timestamp: 1000), 0, 0, "long idle must not replay clipped input")
        checkDelta(scroll.consume(first: -4, second: 0, sensitivity: 0.5,
                                  reversed: false, timestamp: 1000), 0, 4, "new gesture responds after idle")

        // Lowering the slider must also lower any stored burst allowance.
        scroll = PhysicalMouseScroll()
        _ = scroll.consume(first: 0, second: 0, sensitivity: 1.5, reversed: false, timestamp: 0)
        total = 0
        for i in 0..<100 {
            let raw: Float = i.isMultiple(of: 2) ? 4 : 5
            total -= scroll.consume(first: raw, second: 0, sensitivity: 0.05,
                                    reversed: false, timestamp: 0).dy
        }
        check(total == 1, "speed decrease must take effect immediately, including saved credit")
    }
}
