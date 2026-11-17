import Foundation

@main
struct PhysicalMouseScrollTests {
    static var checks = 0

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
        // tens of detents per callback. At the default setting it now totals seven.
        var recorded = PhysicalMouseScroll()
        let samples: [Float] = [0.017333984, 9.184784, 36.241714, 51.288696, 0]
        let expected: [Int32] = [0, -2, -2, -3, 0]
        for (sample, dy) in zip(samples, expected) {
            checkDelta(recorded.consume(first: sample, second: 0, sensitivity: 0.3, reversed: false),
                       0, dy, "captured vertical swipe")
        }

        // A sample can arrive in two callbacks, with the other axis unchanged.
        // Diagonal motion must not replay that stale axis or swap X and Y.
        var axes = PhysicalMouseScroll()
        checkDelta(axes.consume(first: 2, second: 0, sensitivity: 0.5, reversed: false), 0, -2, "vertical axis")
        checkDelta(axes.consume(first: 2, second: 2, sensitivity: 0.5, reversed: false), 2, 0, "stale vertical")
        checkDelta(axes.consume(first: 2, second: 2, sensitivity: 0.5, reversed: false), 0, 0, "duplicate callback")
        checkDelta(axes.consume(first: 0, second: 2, sensitivity: 0.5, reversed: false), 0, 0, "vertical reset")
        checkDelta(axes.consume(first: 0, second: 0, sensitivity: 0.5, reversed: false), 0, 0, "horizontal reset")
        checkDelta(axes.consume(first: -2, second: -2, sensitivity: 0.5, reversed: false), -2, 2, "negative diagonal")
        axes = PhysicalMouseScroll()
        checkDelta(axes.consume(first: 4, second: 1, sensitivity: 0.5, reversed: false), 0, -4, "sideways drift filter")
        axes = PhysicalMouseScroll()
        checkDelta(axes.consume(first: 1, second: 4, sensitivity: 0.5, reversed: false), 4, 0, "vertical drift filter")

        var forward = PhysicalMouseScroll(), reverse = PhysicalMouseScroll()
        for sample in samples {
            let a = forward.consume(first: sample, second: 0, sensitivity: 0.3, reversed: false)
            let b = reverse.consume(first: sample, second: 0, sensitivity: 0.3, reversed: true)
            checkDelta(b, -a.dx, -a.dy, "reverse scrolling must preserve distance")
        }

        // Disconnected devices/sessions start with fresh state. Two simultaneously
        // attached devices must not share the previous axis value or fractions.
        var deviceA = PhysicalMouseScroll(), deviceB = PhysicalMouseScroll()
        checkDelta(deviceA.consume(first: 0.5, second: 0, sensitivity: 0.5, reversed: false), 0, 0, "device A fraction")
        checkDelta(deviceB.consume(first: 0.5, second: 0, sensitivity: 0.5, reversed: false), 0, 0, "device B independent")
        _ = deviceA.consume(first: 0, second: 0, sensitivity: 0.5, reversed: false)
        checkDelta(deviceA.consume(first: 0.5, second: 0, sensitivity: 0.5, reversed: false), 0, -1, "device A retained fraction")
        deviceA = PhysicalMouseScroll()
        checkDelta(deviceA.consume(first: 0.5, second: 0, sensitivity: 0.5, reversed: false), 0, 0, "reconnect reset")

        // Invalid input must not poison the last valid axis state or the remainder.
        var invalid = PhysicalMouseScroll()
        checkDelta(invalid.consume(first: 0.5, second: 0, sensitivity: 0.5, reversed: false), 0, 0, "fraction before invalid input")
        for bad in [Float.nan, .infinity, -.infinity] {
            checkDelta(invalid.consume(first: bad, second: 2, sensitivity: 0.5, reversed: false), 0, 0, "invalid first axis")
            checkDelta(invalid.consume(first: 2, second: bad, sensitivity: 0.5, reversed: false), 0, 0, "invalid second axis")
        }
        checkDelta(invalid.consume(first: 0.75, second: 0, sensitivity: 0.5, reversed: false), 0, -1, "recover after invalid input")
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
        print("PASS: physical mouse scrolling, \(checks) checks; captured swipe = 7 detents")
    }
}
