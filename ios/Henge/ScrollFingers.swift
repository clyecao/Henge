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
    typealias Touch = (Int32, Int32, Int32, Int32, UInt32) -> Void
    typealias Schedule = (TimeInterval, DispatchWorkItem) -> Void
    private let touch: Touch
    private let commitFrame: (UInt32) -> Void
    private let now: () -> TimeInterval
    private let schedule: Schedule

    private static let pairs: [(Int32, Int32)] = [(14, 15), (12, 13)]
    private static let minX = 8134.0 * 0.12, maxX = 8134.0 * 0.88
    private static let minY = 5206.0 * 0.15, maxY = 5206.0 * 0.70
    private static let spread = 1100.0
    private static let mergeDelay = 0.003, idleLift = 0.12, rest = 0.05
    // A malformed/very large delta must not leave the pad permanently at an
    // edge. Also bound held motion so long swipes cannot build an unbounded debt.
    private static let maxStep = 900.0, maxBacklog = 1800.0

    private var pair = 0
    private var ids: (Int32, Int32) { Self.pairs[pair] }
    private var down = false
    private var x = 0.0, y = 0.0
    private var lastFirst: Float = 0, lastSecond: Float = 0
    private var lastSample: TimeInterval?
    private var pendingX = 0.0, pendingY = 0.0
    private var pendingTime: TimeInterval?
    private var backlogX = 0.0, backlogY = 0.0
    private var restingUntil: TimeInterval?
    private var needsPlacement = false
    private var flushWork: DispatchWorkItem?, idleWork: DispatchWorkItem?
    private var generation: UInt64 = 0

    init(touch: @escaping Touch, frame: @escaping (UInt32) -> Void,
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         schedule: @escaping Schedule = { delay, work in
             DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
         }) {
        self.touch = touch
        self.commitFrame = frame
        self.now = now
        self.schedule = schedule
    }

    deinit { flushWork?.cancel(); idleWork?.cancel() }

    func scroll(first: Float, second: Float, sensitivity: Double, reversed: Bool) {
        let time = now()
        guard first.isFinite, second.isFinite, time.isFinite, time >= 0, time < 1e12 else { return }
        guard lastSample.map({ time >= $0 }) ?? true else { return }
        lastSample = time
        let verticalChanged = first != lastFirst, horizontalChanged = second != lastSecond
        lastFirst = first
        lastSecond = second
        if first == 0 && second == 0 {
            end()
            return
        }
        guard verticalChanged || horizontalChanged else { return }
        // The fingers move opposite to GameController's content direction.
        // Keep PR #167's calibration: 40 sensor units/point at sensitivity 0.3.
        let gain = (reversed ? 1.0 : -1.0) * 40 * ScrollSensitivity.clamped(sensitivity) / 0.3
        let dx = horizontalChanged ? Double(second) * gain : 0
        let dy = verticalChanged ? Double(first) * gain : 0
        if dx * backlogX < 0 { backlogX = 0 }
        if dy * backlogY < 0 { backlogY = 0 }
        (pendingX, pendingY) = Self.bounded(pendingX + dx, pendingY + dy, limit: Self.maxStep)
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
        idleWork?.cancel()
        let token = generation
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.generation == token else { return }
            self.end()
        }
        idleWork = work
        schedule(Self.idleLift, work)
    }

    /// A normal lift may hand momentum to macOS; edge backlog is never replayed.
    func end() {
        cancelWork()
        if restingUntil == nil && !needsPlacement { flush() }
        clearMotion()
        lift(at: now())
    }

    /// Session/device/input-owner teardown discards even the unflushed sample.
    func cancel() {
        cancelWork()
        clearMotion()
        lift(at: now())
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
        backlogX = 0; backlogY = 0
        restingUntil = nil
        needsPlacement = false
        lastFirst = 0; lastSecond = 0; lastSample = nil
    }

    private static func bounded(_ dx: Double, _ dy: Double, limit: Double) -> (Double, Double) {
        let factor = max(1, max(abs(dx), abs(dy)) / limit)
        return (dx / factor, dy / factor)
    }

    private func hold(_ dx: Double, _ dy: Double) {
        (backlogX, backlogY) = Self.bounded(backlogX + dx, backlogY + dy, limit: Self.maxBacklog)
    }

    private func flush() {
        var dx = pendingX, dy = pendingY
        let time = pendingTime ?? now()
        pendingX = 0; pendingY = 0; pendingTime = nil
        guard dx != 0 || dy != 0 || restingUntil != nil else { return }
        if needsPlacement {
            hold(dx, dy)
            place(towardX: backlogX, towardY: backlogY, at: time)
            needsPlacement = false
            return // move on the next sample, not at the instant of contact
        }
        if let until = restingUntil {
            hold(dx, dy)
            frame(at: time) // same position: let the guest observe zero velocity
            if now() >= until {
                lift(at: time)
                restingUntil = nil
                needsPlacement = true
            }
            return
        }
        // Pay held motion out gradually, within the same per-frame bound.
        let shareX = backlogX * 0.35, shareY = backlogY * 0.35
        backlogX -= shareX; backlogY -= shareY
        if abs(backlogX) < 1 && abs(backlogY) < 1 { backlogX = 0; backlogY = 0 }
        (dx, dy) = Self.bounded(dx + shareX, dy + shareY, limit: Self.maxStep)
        guard dx != 0 || dy != 0 else { return }
        if !down {
            // Leave a sample interval between initial contact and movement.
            place(towardX: dx, towardY: dy, at: max(0.001, time - 0.008))
        }
        let nx = x + dx, ny = y + dy
        if nx - Self.spread / 2 < Self.minX || nx + Self.spread / 2 > Self.maxX || ny < Self.minY || ny > Self.maxY {
            restingUntil = now() + Self.rest
            hold(dx, dy)
            frame(at: time)
            return
        }
        x = nx; y = ny
        frame(at: time)
    }

    private static func ms(_ time: TimeInterval) -> UInt32 {
        // Wrap like the native timestamp without trapping after a long uptime.
        guard time.isFinite, time >= 0, time < 1e12 else { return 0 }
        return UInt32((time * 1000).truncatingRemainder(dividingBy: 4294967296))
    }

    private func frame(at time: TimeInterval) {
        guard down else { return }
        let ts = Self.ms(time)
        touch(ids.0, 1, Int32(x - Self.spread / 2), Int32(y), ts)
        touch(ids.1, 1, Int32(x + Self.spread / 2), Int32(y), ts)
        commitFrame(ts)
    }

    private func place(towardX: Double, towardY: Double, at time: TimeInterval) {
        if abs(towardY) >= abs(towardX) {
            x = 8134 / 2
            y = towardY > 0 ? Self.minY : Self.maxY
        } else {
            x = towardX > 0 ? Self.minX + Self.spread / 2 : Self.maxX - Self.spread / 2
            y = 5206 / 2
        }
        let ts = Self.ms(time)
        touch(ids.0, 0, Int32(x - Self.spread / 2), Int32(y), ts)
        touch(ids.1, 0, Int32(x + Self.spread / 2), Int32(y), ts)
        down = true
    }

    private func lift(at time: TimeInterval) {
        guard down else { return }
        let ts = Self.ms(time)
        touch(ids.0, 2, 0, 0, ts)
        touch(ids.1, 2, 0, 0, ts)
        down = false
        pair = (pair + 1) % Self.pairs.count
    }
}
