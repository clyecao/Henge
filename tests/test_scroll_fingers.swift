import Foundation

@main
struct ScrollFingersTests {
    static var checks = 0
    static func check(_ condition: Bool, _ message: String) {
        checks += 1
        guard condition else { fatalError(message) }
    }

    struct Contact: Equatable { var x: Int32; var y: Int32 }
    struct Event { var id: Int32; var phase: Int32; var point: Contact; var time: Double; var ts: UInt32 }
    struct Frame { var contacts: [Int32: Contact]; var time: Double; var ts: UInt32 }

    final class Pad {
        var time = 100.0
        var work: [(Double, DispatchWorkItem)] = []
        var events: [Event] = []
        var frames: [Frame] = []
        var contacts: [Int32: Contact] = [:]
        lazy var fingers = ScrollFingers(
            touch: { [unowned self] id, phase, x, y, ts in
                let point = Contact(x: x, y: y)
                ScrollFingersTests.check((12...15).contains(id), "hardware IDs must not collide with touchscreen IDs")
                if phase == 0 {
                    ScrollFingersTests.check(self.contacts[id] == nil, "down must not duplicate an active ID")
                    self.contacts[id] = point
                } else if phase == 1 {
                    ScrollFingersTests.check(self.contacts[id] != nil, "move needs a live contact")
                    self.contacts[id] = point
                } else {
                    ScrollFingersTests.check(self.contacts.removeValue(forKey: id) != nil, "lift needs a live contact")
                }
                ScrollFingersTests.check(self.contacts.count <= 2, "at most one hardware pair may be active")
                self.events.append(Event(id: id, phase: phase, point: point, time: self.time, ts: ts))
            },
            frame: { [unowned self] ts in
                ScrollFingersTests.check(self.contacts.count == 2, "both fingers must move in one frame")
                let points = self.contacts.values.sorted { $0.x < $1.x }
                ScrollFingersTests.check(points[1].x - points[0].x == 1100 && points[1].y == points[0].y,
                      "scroll must not become pinch or rotation")
                for p in points {
                    ScrollFingersTests.check(p.x >= 976 && p.x <= 7158 && p.y >= 780 && p.y <= 3645,
                          "contacts must stay clear of edges and the thumb zone")
                }
                self.frames.append(Frame(contacts: self.contacts, time: self.time, ts: ts))
            },
            now: { [unowned self] in self.time },
            schedule: { [unowned self] delay, item in self.work.append((self.time + delay, item)) })

        func send(_ first: Float, _ second: Float = 0, speed: Double = 0.3, reverse: Bool = false) {
            fingers.scroll(first: first, second: second, sensitivity: speed, reversed: reverse)
        }

        func advance(_ delta: Double) {
            let end = time + delta
            while let index = work.indices.min(by: { work[$0].0 < work[$1].0 }), work[index].0 <= end {
                let (due, item) = work.remove(at: index)
                time = max(time, due)
                if !item.isCancelled { item.perform() }
            }
            time = end
        }

        func movement(_ frame: Frame) -> (Int32, Int32) {
            let id = frame.contacts.keys.min()!
            let start = events.last { $0.id == id && $0.phase == 0 && $0.ts <= frame.ts }!
            return (frame.contacts[id]!.x - start.point.x, frame.contacts[id]!.y - start.point.y)
        }
    }

    static func main() {
        check(TrackpadScrollSettings.usesFingers(vendorName: "Magic Keyboard"), "user's keyboard must use contacts")
        check(TrackpadScrollSettings.usesFingers(vendorName: "Apple Magic Trackpad 2"), "Apple trackpad must use contacts")
        check(TrackpadScrollSettings.usesFingers(vendorName: "magic keyboard for iPad Pro"), "case-insensitive keyboard name")
        let wheelNames: [String?] = [nil, "", "Bluetooth Mouse M558", "Magic Mouse", "USB Mouse"]
        for name in wheelNames {
            check(!TrackpadScrollSettings.usesFingers(vendorName: name), "mouse/unknown device must keep wheel path")
        }
        check(TrackpadScrollSettings.key != ScrollSensitivity.key, "trackpad speed must not overwrite mouse speed")
        testMergeAndEnd()
        testLightSteadySwipe()
        testCapturedMagicKeyboardSwipe()
        testCancellation()
        testSensitivity()
        testLongSwipes()
        print("PASS: smooth trackpad, \(checks) checks (routing, frames, idle, cancellation, edges, direction and bounds)")
    }

    static func testMergeAndEnd() {
        let pad = Pad()
        pad.send(1)
        pad.advance(0.001)
        pad.send(1, 0.5) // same sample's second callback: stale vertical axis
        pad.send(1, 0.5) // duplicate within the same sample
        check(pad.events.isEmpty, "callbacks must merge before reporting")
        pad.advance(0.003)
        check(pad.frames.count == 1, "one merged frame per sample")
        let motion = pad.movement(pad.frames[0])
        check(motion.0 == -20 && motion.1 == -40, "stale axis must not double movement")
        pad.send(0, 0.5) // the vertical reset still carries stale horizontal motion
        pad.advance(0.0001)
        pad.send(0, 0)
        pad.advance(0.017)
        check(pad.contacts.isEmpty, "confirmed zero sample must lift both fingers")
        check(pad.frames.count == 1, "a split release must not add a sideways frame")
        let count = pad.events.count
        pad.advance(0.3)
        check(pad.events.count == count, "ended gesture must not fire delayed work")

        let quick = Pad()
        quick.send(1)
        quick.advance(0.001)
        quick.send(0)
        quick.advance(0.017)
        check(quick.frames.count == 1 && quick.contacts.isEmpty, "quick release must flush one pending move then lift")
        quick.advance(0.3)
        check(quick.frames.count == 1, "quick release must cancel scheduled flush")

        let idle = Pad()
        idle.send(1)
        idle.advance(0.119)
        check(idle.contacts.count == 2, "do not lift early")
        idle.advance(0.002)
        check(idle.contacts.isEmpty, "missing zero sample must idle-lift")
        idle.send(1) // same value must work after idle; no stale previous-axis state
        idle.advance(0.004)
        check(Set(idle.contacts.keys) == Set([Int32(12), 13]), "next gesture must use the other ID pair")
        idle.fingers.cancel()

        let delayed = Pad()
        delayed.send(1)
        delayed.time += 0.05 // simulate a busy main queue before the scheduled flush
        delayed.advance(0)
        check(delayed.frames[0].ts == 100000, "a delayed flush must retain the captured sample time")
        delayed.fingers.cancel()
    }

    static func testCapturedMagicKeyboardSwipe() {
        // Complete snapshots from the first 97 ms of the iPad14,6 trace.
        // GC sends the new vertical value first, then updates the horizontal
        // value within the same report. The previous converter stopped at
        // y=1532 while seven more nonzero reports arrived.
        let samples: [(Double, Float, Float)] = [
            (0, 0.37573242, 0), (5.24, 3.45047, 1.3325806), (13.60, 6.53685, 2.2505646),
            (21.91, 7.853821, 1.9752197), (30.29, 10.31604, 2.230957), (38.83, 11.545212, 2.0889893),
            (46.91, 21.690735, 2.4911194), (55.39, 18.991852, 1.7157288), (63.66, 42.80809, 1.7824097),
            (71.95, 28.758423, 0.8491211), (80.29, 51.26082, 0.11061096), (88.69, 27.390167, 0),
            (96.97, 31.784698, 0)
        ]
        let pad = Pad()
        let start = pad.time
        var previousX: Float = 0
        for (ms, vertical, horizontal) in samples {
            pad.advance(max(0, start + ms / 1000 - pad.time))
            pad.send(vertical, previousX)
            if horizontal != previousX {
                pad.advance(0.0001)
                pad.send(vertical, horizontal)
            }
            previousX = horizontal
        }
        pad.advance(0.004)
        check(pad.frames.count == samples.count, "each captured sample must reach the guest as one frame")
        var lastY = pad.events.first!.point.y
        for frame in pad.frames {
            guard let point = frame.contacts[14] else { fatalError("short swipe should not need a regrip") }
            check(point.y < lastY, "ongoing input must advance both contacts throughout the captured swipe")
            lastY = point.y
        }
        pad.fingers.cancel()
    }

    static func testLightSteadySwipe() {
        for horizontal in [true, false] {
            let pad = Pad()
            for _ in 0..<24 {
                let value: Float = 0.0625
                pad.send(horizontal ? 0 : value, horizontal ? value : 0, speed: 0.05)
                pad.advance(0.008)
            }
            check(pad.frames.count == 24, "equal deltas across independent reports must keep moving")
            check(pad.events.filter { $0.phase == 0 }.count == 2, "steady input must keep a single pair down")
            let (dx, dy) = pad.movement(pad.frames.last!)
            check(abs(Double(horizontal ? dx : dy) + 10) <= 1, "sub-unit motion must add up at minimum speed")
            pad.send(0)
            pad.advance(0.008)
            pad.send(horizontal ? 0 : -1, horizontal ? -1 : 0)
            pad.advance(0.008)
            check(pad.events.allSatisfy { $0.phase != 2 }, "one zero between moving samples must not split a swipe")
            let previous = pad.frames[23].contacts[14]!, current = pad.frames.last!.contacts[14]!
            check(horizontal ? current.x > previous.x : current.y > previous.y, "small reversal must move immediately")
            pad.fingers.cancel()
        }

        let drift = Pad()
        for i in 0..<24 {
            drift.send(0.25, i.isMultiple(of: 2) ? 0.01 : 0.02)
            drift.advance(0.008)
        }
        check(drift.movement(drift.frames.last!).1 == -240,
              "a jittering lateral axis must not cancel steady vertical travel")
        drift.fingers.cancel()

        let delayed = Pad()
        for i in 0..<4 {
            let timestamp = delayed.time - 0.032 + Double(i) * 0.008
            delayed.fingers.scroll(first: 0.5, second: 0, sensitivity: 0.3, reversed: false, sampleTimestamp: timestamp)
        }
        delayed.advance(0.004)
        check(delayed.frames.count == 4 && delayed.movement(delayed.frames.last!).1 == -80,
              "queued reports with distinct hardware timestamps must retain distance and individual frames")
        delayed.fingers.cancel()
    }

    static func testCancellation() {
        let pad = Pad()
        pad.send(1)
        pad.advance(0.001)
        pad.fingers.cancel()
        pad.send(2)
        pad.advance(0.0025)
        check(pad.frames.isEmpty, "old timer must not flush the new gesture early")
        pad.advance(0.001)
        check(pad.frames.count == 1, "new gesture must have its own timer")
        pad.send(3)
        pad.fingers.cancel()
        check(pad.contacts.isEmpty, "disconnect/session stop must lift both contacts")
        let count = pad.events.count
        pad.advance(1)
        check(pad.events.count == count, "cancel must discard pending motion and idle work")
        pad.fingers.cancel()
        check(pad.events.count == count, "repeated cleanup must be idempotent")
    }

    static func testSensitivity() {
        for reverse in [false, true] {
            for speed in [0.05, 0.3, 1.5] {
                let pad = Pad()
                pad.send(1, speed: speed, reverse: reverse)
                pad.advance(0.004)
                let delta = pad.movement(pad.frames[0]).1
                check((delta > 0) == reverse, "reverse setting must reverse contact travel")
                check(abs(Double(abs(delta)) - 40 * speed / 0.3) <= 1, "speed must scale physical travel")
                pad.fingers.cancel()
            }
        }
        let invalid = Pad()
        invalid.send(.nan)
        invalid.send(1, .infinity)
        invalid.advance(0.004)
        check(invalid.events.isEmpty, "invalid values must not create contacts")
        invalid.send(1, speed: .nan)
        invalid.advance(0.004)
        check(invalid.movement(invalid.frames[0]).1 == -40, "invalid speed must use default")
        invalid.fingers.cancel()
    }

    static func testLongSwipes() {
        for extreme in [false, true] {
            let pad = Pad()
            for i in 0..<300 {
                let raw: Float = extreme ? (i.isMultiple(of: 2) ? .greatestFiniteMagnitude : .greatestFiniteMagnitude / 2)
                                        : (i.isMultiple(of: 2) ? 6 : 7)
                pad.send(raw)
                pad.advance(0.008)
            }
            let lifts = pad.events.filter { $0.phase == 2 }
            check(lifts.count >= 4, "long swipe must regrip and keep moving")
            for event in lifts {
                let preceding = pad.frames.filter { $0.time <= event.time && $0.contacts[event.id] != nil }
                guard let last = preceding.last else { fatalError("lift without a frame") }
                let stationary = preceding.reversed().prefix { $0.contacts == last.contacts }
                check(last.time - stationary.last!.time >= 0.049,
                      "edge lift must follow at least 50 ms of stationary frames")
            }
            let count = pad.frames.count
            for i in 0..<40 {
                pad.send(i.isMultiple(of: 2) ? -6 : -7)
                pad.advance(0.008)
            }
            let reversed = pad.frames.dropFirst(count).prefix(15)
            check(zip(reversed, reversed.dropFirst()).contains { before, after in
                guard let id = before.contacts.keys.min(), let next = after.contacts[id] else { return false }
                return next.y > before.contacts[id]!.y
            }, "direction change must move a live pair back within one edge rest and regrip")
            pad.send(0)
            pad.advance(0.017)
            check(pad.contacts.isEmpty, "long-swipe release must lift contacts")
            let eventCount = pad.events.count
            pad.advance(1)
            check(pad.events.count == eventCount, "edge backlog must not replay after release")
        }
    }
}
