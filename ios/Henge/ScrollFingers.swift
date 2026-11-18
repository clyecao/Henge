import Foundation

enum TrackpadScrollSettings {
    static let key = "henge.trackpad.scrollSpeed"
    static let defaultValue = 0.3

    static func usesFingers(vendorName: String?) -> Bool {
        // GameController exposes both as GCMouse. These are the names reported
        // by Apple's pads; an unknown device keeps the existing wheel behavior.
        let name = vendorName?.lowercased() ?? ""
        return name.contains("magic keyboard") || name.contains("magic trackpad")
    }
}

/// Adapted from Leviidev/Henge PR #167 (e158322564d5): replay hardware scroll
/// as two contacts on the guest's Magic Trackpad 2, letting macOS do pixel
/// scrolling and momentum. Only one hardware pad owns these IDs at a time.
final class ScrollFingers {
    enum Phase: Int32 { case down, move, up }
    typealias Report = (Int32, Phase, Int32, Int32, Int32, UInt32) -> Bool
    typealias Schedule = (TimeInterval, DispatchWorkItem) -> Void
    private let report: Report
    private let onEnd: (Int, Int) -> Void
    private let now: () -> TimeInterval
    private let schedule: Schedule

    private var firstID: Int32 = 14
    private static let minX = 8134.0 * 0.12, maxX = 8134.0 * 0.88
    private static let minY = 5206.0 * 0.15, maxY = 5206.0 * 0.70
    private static let spread = 1100.0
    private static let mergeDelay = 0.003, idleLift = 0.12
    // Allow a zero between adjacent ~8 ms trackpad reports without lifting.
    private static let releaseDelay = 0.016
    private static let maxStep = 900.0

    private var down = false
    private var x = 0.0, y = 0.0
    private var lastSample: TimeInterval?
    private var sampleStart: TimeInterval?
    private var travelLimit = 0.0
    private var zeroTime: TimeInterval?
    private var pendingX = 0.0, pendingY = 0.0
    private var pendingTime: TimeInterval?
    private var quietEdge = false
    private var regrips = 0, skipped = 0
    private var needsPlacement = false
    private var flushWork: DispatchWorkItem?, idleWork: DispatchWorkItem?
    private var generation: UInt64 = 0

    init(report: @escaping Report, onEnd: @escaping (Int, Int) -> Void = { _, _ in },
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         schedule: @escaping Schedule = { delay, work in
             DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
         }) {
        self.report = report
        self.onEnd = onEnd
        self.now = now
        self.schedule = schedule
    }

    deinit { flushWork?.cancel(); idleWork?.cancel() }

    func scroll(first: Float, second: Float, sensitivity: Double, reversed: Bool,
                sampleTimestamp: TimeInterval? = nil) {
        let arrival = now()
        let time = sampleTimestamp.flatMap { $0.isFinite && $0 > 0 && abs($0 - arrival) < 1 ? $0 : nil } ?? arrival
        guard first.isFinite, second.isFinite, time.isFinite, time >= 0, time < 1e12 else { return }
        guard lastSample.map({ time >= $0 }) ?? true else { return }
        if let zero = zeroTime, time - zero >= Self.releaseDelay {
            end() // a new report arrived before the main queue ran the lift timer
        }
        lastSample = time
        let scale = ScrollSensitivity.clamped(sensitivity) / 0.3
        let newSample = sampleStart.map { time - $0 >= Self.mergeDelay } ?? true
        // A busy main queue can deliver several hardware samples before the
        // merge timer runs. Commit the preceding one at its own timestamp.
        if newSample {
            if flushWork != nil {
                flushWork?.cancel()
                flushWork = nil
                flush()
            }
            // The captured 120 Hz input reached 51 points per sample. Cap
            // virtual finger speed to avoid crossing the pad in a few frames.
            let interval = sampleStart.map { min(time - $0, 1.0 / 30) } ?? 1.0 / 120
            travelLimit = min(Self.maxStep, 7200 * scale * interval)
            sampleStart = time
        }
        if first == 0 && second == 0 {
            // A split release can briefly carry the previous sample's other
            // axis. Once a gesture is down, its final snapshot replaces that
            // partial report. Preserve a quick initial movement before lift.
            if !newSample && down {
                pendingX = 0; pendingY = 0; pendingTime = nil
                flushWork?.cancel()
                flushWork = nil
            }
            if zeroTime == nil && (down || pendingTime != nil || needsPlacement) {
                zeroTime = time
                armLift(after: Self.releaseDelay)
            }
            return
        }
        // Each callback carries the current two-axis snapshot. Replace a split
        // update before flushing, retaining a steady axis in the next sample.
        // A late duplicate of an already committed report has no pending frame.
        guard newSample || pendingTime != nil || zeroTime != nil || !down else { return }
        zeroTime = nil
        // The fingers move opposite to GameController's content direction.
        // Keep PR #167's calibration: 40 sensor units/point at sensitivity 0.3.
        let gain = (reversed ? 1.0 : -1.0) * 40 * scale
        (pendingX, pendingY) = Self.bounded(Double(second) * gain, Double(first) * gain, limit: travelLimit)
        pendingTime = time
        if flushWork == nil {
            let token = generation
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.generation == token else { return }
                self.flushWork = nil
                self.flush()
            }
            flushWork = work
            schedule(Self.mergeDelay, work)
        }
        armLift(after: Self.idleLift)
    }

    private func armLift(after delay: TimeInterval) {
        idleWork?.cancel()
        let token = generation
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.generation == token else { return }
            self.end()
        }
        idleWork = work
        schedule(delay, work)
    }

    /// A normal lift may hand momentum to macOS; edge backlog is never replayed.
    func end() {
        cancelWork()
        if !needsPlacement && !quietEdge { flush() }
        lift(at: zeroTime ?? now())
        clearMotion()
    }

    /// Session/device/input-owner teardown discards even the unflushed sample.
    func cancel() {
        cancelWork()
        lift(at: now())
        clearMotion()
    }

    private func cancelWork() {
        generation &+= 1
        flushWork?.cancel()
        idleWork?.cancel()
        flushWork = nil
        idleWork = nil
    }

    private func clearMotion() {
        pendingX = 0; pendingY = 0; pendingTime = nil
        if regrips > 0 || skipped > 0 { onEnd(regrips, skipped) }
        regrips = 0; skipped = 0
        quietEdge = false
        needsPlacement = false
        lastSample = nil
        sampleStart = nil; zeroTime = nil
    }

    private static func bounded(_ dx: Double, _ dy: Double, limit: Double) -> (Double, Double) {
        let factor = max(1, max(abs(dx), abs(dy)) / limit)
        return (dx / factor, dy / factor)
    }

    private func flush() {
        guard let time = pendingTime else { return }
        let dx = pendingX, dy = pendingY
        pendingX = 0; pendingY = 0; pendingTime = nil
        guard dx != 0 || dy != 0 else { return }

        let minX = Self.minX + Self.spread / 2, maxX = Self.maxX - Self.spread / 2
        let horizontal = abs(dx) > abs(dy)
        if !down {
            x = (minX + maxX) / 2
            y = (Self.minY + Self.maxY) / 2
            if needsPlacement {
                // Leave a little room for an immediate reversal after a regrip.
                if horizontal { x += (dx > 0 ? -0.4 : 0.4) * (maxX - minX) }
                else { y += (dy > 0 ? -0.4 : 0.4) * (Self.maxY - Self.minY) }
            }
            let placement = needsPlacement ? time : max(0.001, time - 0.008)
            guard send(.down, x: x, y: y, at: placement) else { return }
            down = true
            if needsPlacement { needsPlacement = false; return }
        }

        // Ease the last few samples towards the edge. One stationary sample
        // gives macOS a low release velocity. A reversal can move away at once.
        let distance = horizontal ? (dx > 0 ? maxX - x : x - minX)
                                  : (dy > 0 ? Self.maxY - y : y - Self.minY)
        if distance <= 1 {
            if quietEdge {
                lift(at: time)
                needsPlacement = true
                regrips += 1
            } else {
                quietEdge = send(.move, x: x, y: y, at: time)
            }
            return
        }
        let fraction = min(1, max(1, distance / 2) / max(abs(dx), abs(dy)))
        let nx = min(max(x + dx * fraction, minX), maxX)
        let ny = min(max(y + dy * fraction, Self.minY), Self.maxY)
        if send(.move, x: nx, y: ny, at: time) {
            x = nx; y = ny
            quietEdge = false
        }
    }

    private static func ms(_ time: TimeInterval) -> UInt32 {
        // Wrap like the native timestamp without trapping after a long uptime.
        guard time.isFinite, time >= 0, time < 1e12 else { return 0 }
        return UInt32((time * 1000).truncatingRemainder(dividingBy: 4294967296))
    }

    private func send(_ phase: Phase, x: Double, y: Double, at time: TimeInterval) -> Bool {
        let accepted = report(firstID, phase, Int32(x - Self.spread / 2), Int32(x + Self.spread / 2),
                              Int32(y), Self.ms(time))
        if !accepted { skipped += 1 }
        return accepted
    }

    private func lift(at time: TimeInterval) {
        guard down else { return }
        _ = send(.up, x: x, y: y, at: time)
        down = false
        quietEdge = false
        firstID = firstID == 14 ? 12 : 14
    }
}
