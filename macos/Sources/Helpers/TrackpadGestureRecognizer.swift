// TrackpadGestureRecognizer
//
// A raw-NSTouch trackpad gesture recognizer, self-contained on purpose:
// it depends only on Foundation and CoreGraphics, never sees NSTouch or
// NSEvent, and is driven entirely by TouchFrame values. That keeps it
// replayable from disk and portable across a C boundary into another
// apprt without changes.
//
// This file is kept identical with the standalone prototyping harness the
// recognizer is developed and tuned in, whose live overlay and record and
// replay tooling consume the DebugSnapshot API; hosts that don't visualize
// simply don't call it.
//
// Model (mirrors Apple's LightTable/DualTouchTracker sample, not
// NSGestureRecognizer - gesture recognizers do not receive trackpad
// touches):
//
//   idle -> settling -> locked(N fingers) -> committed(swipe|pinch) -> idle
//                                 \-> awaitingLift (drain) -----------/
//
// - settling: touches are landing; every added finger restarts a short
//   settle timer so staggered landings still lock the intended count.
//   Early motion locks immediately (a moving hand is done landing).
// - locked: finger count is fixed. Both signals are measured from the
//   lock baseline: centroid translation (swipe) and mean distance from
//   centroid (pinch spread). Whichever crosses its threshold first,
//   with a dominance margin as hysteresis, captures the gesture for its
//   whole lifetime (commit-and-lock mutual exclusion).
// - committed: only the committed measure is reported. A lifted finger
//   ends the gesture (with fling velocity from the recent history); an
//   added finger cancels it. Either way we drain until all fingers are
//   up before recognizing anything new.
//
// Units: positions are normalizedPosition * deviceSize, i.e. device
// points (1/72 in), so thresholds are trackpad-size independent.

import Foundation
import CoreGraphics

// MARK: - Input

public enum TouchPhase: String, Codable {
    case began, moved, stationary, ended, cancelled
}

/// One finger in one frame. x/y are normalized trackpad coordinates
/// (0...1, origin bottom-left, y grows upward).
public struct TouchSample: Codable {
    public var id: Int
    public var x: Double
    public var y: Double
    public var phase: TouchPhase

    public init(id: Int, x: Double, y: Double, phase: TouchPhase) {
        self.id = id
        self.x = x
        self.y = y
        self.phase = phase
    }
}

/// Everything the trackpad reports at one instant, including touches
/// that end in this frame. t is an arbitrary monotonic clock (NSEvent
/// timestamps live; recorded values on replay) - only deltas matter.
/// w/h are NSTouch.deviceSize in points.
public struct TouchFrame: Codable {
    public var t: TimeInterval
    public var w: Double
    public var h: Double
    public var touches: [TouchSample]

    public init(t: TimeInterval, w: Double, h: Double, touches: [TouchSample]) {
        self.t = t
        self.w = w
        self.h = h
        self.touches = touches
    }
}

// MARK: - Output

/// Normalized gesture output, shaped to cross a C boundary untouched.
public struct GestureEvent {
    public enum Kind: String { case swipe, pinch }
    public enum Direction: String { case left, right, up, down, none }
    public enum Phase: String { case began, changed, ended, cancelled }

    public var kind: Kind
    public var direction: Direction
    public var fingerCount: Int
    /// swipe: device points travelled along the committed axis, positive
    /// in the committed direction (goes negative if the hand backtracks).
    /// pinch: scale relative to the spread at lock (1.0 = unchanged).
    public var magnitude: Double
    /// swipe: device points/second along the axis. pinch: scale/second.
    /// On .ended this is the fling velocity at lift (0 after a pause).
    public var velocity: Double
    public var phase: Phase
}

// MARK: - Recognizer

public final class TrackpadGestureRecognizer {

    public struct Config {
        /// Quiet time after the last finger lands before the count locks.
        public var settleInterval: TimeInterval = 0.06
        /// Centroid motion (device pt) during settling that locks the
        /// count immediately - a moving hand is done landing fingers.
        public var motionLockThreshold: Double = 2.0
        /// Centroid translation (device pt) that commits a swipe.
        public var swipeCommitThreshold: Double = 10.0
        /// Mean-distance-from-centroid change (device pt) that commits a
        /// pinch. For two fingers this is half the inter-finger change.
        public var pinchCommitThreshold: Double = 8.0
        /// Hysteresis: when both signals are near their thresholds, the
        /// winner's threshold-relative ratio must exceed the loser's by
        /// this factor, otherwise we stay in the deadzone and wait for a
        /// less ambiguous frame. This is the main feel knob against
        /// misclassifying a sloppy diagonal pinch/swipe.
        public var dominanceMargin: Double = 1.25
        /// Window for velocity estimation (and fling at lift).
        public var velocityWindow: TimeInterval = 0.1
        /// Finger counts allowed to commit each gesture. 1 never locks.
        public var swipeFingerCounts: ClosedRange<Int> = 2...4
        public var pinchFingerCounts: ClosedRange<Int> = 2...2

        /// If no touch frame arrives for this long while a sequence is
        /// active, the sequence is treated as abandoned and the recognizer
        /// resets (emitting cancelled if a gesture was committed). This
        /// recovers from hosts that stop delivering touch events
        /// mid-sequence - e.g. when the gesture's own action switched the
        /// view's window away and the remaining ended events never arrive.
        public var staleFrameTimeout: TimeInterval = 0.4

        public init() {}
    }

    public enum State: Equatable {
        case idle
        case settling
        case locked(fingers: Int)
        case committed(kind: GestureEvent.Kind, fingers: Int)
        case awaitingLift

        public var label: String {
            switch self {
            case .idle: return "idle"
            case .settling: return "settling"
            case .locked(let n): return "locked(\(n))"
            case .committed(let k, let n): return "committed(\(k.rawValue), \(n))"
            case .awaitingLift: return "awaitingLift"
            }
        }
    }

    public var config = Config()
    public var onGesture: ((GestureEvent) -> Void)?
    public var onStateChange: ((State) -> Void)?
    public private(set) var state: State = .idle
    public private(set) var lastEvent: GestureEvent?

    // Active touches, device points and normalized (normalized kept only
    // for visualization).
    private var devicePoints: [Int: CGPoint] = [:]
    private var normalizedPoints: [Int: CGPoint] = [:]
    private var deviceSize = CGSize(width: 1, height: 1)
    private var lastCount = 0
    private var lastFrameTime: TimeInterval = 0

    // Settling
    private var settleDeadline: TimeInterval = 0
    private var settleCount = 0
    private var settleBaseline = CGPoint.zero

    // Lock baseline
    private var baselineCentroid = CGPoint.zero
    private var baselineSpread: Double = 0
    private var lockTime: TimeInterval = 0

    // Committed gesture
    private var committedDirection: GestureEvent.Direction = .none
    private var committedSign = CGVector.zero

    // Histories for velocity estimation. centroidHistory runs whenever
    // touches are down (also feeds the overlay's velocity arrow);
    // spreadHistory runs while locked so a fast pinch has pre-commit
    // samples; measureHistory tracks the committed measure.
    private var centroidHistory: [(t: TimeInterval, v: CGPoint)] = []
    private var spreadHistory: [(t: TimeInterval, v: Double)] = []
    private var measureHistory: [(t: TimeInterval, v: Double)] = []

    public init() {}

    // MARK: Driving

    /// Feed one frame. Frames must arrive in timestamp order.
    public func process(_ frame: TouchFrame) {
        lastFrameTime = frame.t
        deviceSize = CGSize(width: frame.w, height: frame.h)
        for s in frame.touches {
            switch s.phase {
            case .ended, .cancelled:
                devicePoints.removeValue(forKey: s.id)
                normalizedPoints.removeValue(forKey: s.id)
            default:
                devicePoints[s.id] = CGPoint(x: s.x * frame.w, y: s.y * frame.h)
                normalizedPoints[s.id] = CGPoint(x: s.x, y: s.y)
            }
        }
        if !devicePoints.isEmpty {
            centroidHistory.append((frame.t, centroid()))
            trim(&centroidHistory, now: frame.t)
        }
        advance(now: frame.t)
    }

    /// Drive time forward between frames. Live, call this from a timer
    /// while touches are down (stationary fingers stop producing touch
    /// events, but the settle timer still has to fire); on replay, step
    /// it synthetically between frames.
    public func tick(now: TimeInterval) {
        if state != .idle, now - lastFrameTime > config.staleFrameTimeout {
            if case .committed(let kind, let fingers) = state {
                emitFinal(kind: kind, fingers: fingers, phase: .cancelled, now: now)
            }
            reset()
            return
        }
        if case .settling = state { advance(now: now) }
    }

    public func reset() {
        devicePoints.removeAll()
        normalizedPoints.removeAll()
        clearGestureState()
        lastCount = 0
        setState(.idle)
    }

    // MARK: State machine

    private func advance(now: TimeInterval) {
        let count = devicePoints.count
        defer { lastCount = count }

        if count == 0 {
            if case .committed(let kind, let fingers) = state {
                emitFinal(kind: kind, fingers: fingers, phase: .ended, now: now)
            }
            clearGestureState()
            if state != .idle { setState(.idle) }
            return
        }

        switch state {
        case .idle:
            settleCount = count
            settleDeadline = now + config.settleInterval
            settleBaseline = centroid()
            setState(.settling)

        case .settling:
            if count > settleCount {
                settleCount = count
                settleDeadline = now + config.settleInterval
                settleBaseline = centroid()
                return
            }
            if count < settleCount {
                // A finger lifted before lock (tap or aborted landing) -
                // drain rather than guess at intent.
                setState(.awaitingLift)
                return
            }
            let moved = distance(centroid(), settleBaseline)
            if now >= settleDeadline || moved >= config.motionLockThreshold {
                lock(now: now, count: count)
            }

        case .locked(let fingers):
            if count != fingers {
                setState(.awaitingLift)
                return
            }
            evaluateCommit(now: now, fingers: fingers)

        case .committed(let kind, let fingers):
            if count > fingers {
                emitFinal(kind: kind, fingers: fingers, phase: .cancelled, now: now)
                setState(.awaitingLift)
            } else if count < fingers {
                emitFinal(kind: kind, fingers: fingers, phase: .ended, now: now)
                setState(.awaitingLift)
            } else {
                updateCommitted(kind: kind, fingers: fingers, now: now)
            }

        case .awaitingLift:
            break
        }
    }

    private func lock(now: TimeInterval, count: Int) {
        let c = centroid()
        let s = spread(around: c)
        let canSwipe = config.swipeFingerCounts.contains(count)
        let canPinch = config.pinchFingerCounts.contains(count) && s > 1
        guard canSwipe || canPinch else {
            // A count that can't form any gesture (e.g. a single resting or
            // moving finger) keeps settling rather than draining: a finger
            // that lands later can still start a valid gesture, so this
            // tolerates rest-then-add and landings staggered slower than
            // the settle interval.
            settleCount = count
            settleDeadline = now + config.settleInterval
            settleBaseline = c
            return
        }
        baselineCentroid = c
        baselineSpread = s
        lockTime = now
        spreadHistory = [(now, s)]
        setState(.locked(fingers: count))
    }

    private func evaluateCommit(now: TimeInterval, fingers: Int) {
        let t = translation()
        let s = spread(around: centroid())
        spreadHistory.append((now, s))
        trim(&spreadHistory, now: now)

        let canSwipe = config.swipeFingerCounts.contains(fingers)
        let canPinch = config.pinchFingerCounts.contains(fingers) && baselineSpread > 1
        let swipeSignal = max(abs(t.dx), abs(t.dy))
        let spreadDelta = abs(s - baselineSpread)
        let swipeRatio = canSwipe ? swipeSignal / config.swipeCommitThreshold : 0
        let pinchRatio = canPinch ? spreadDelta / config.pinchCommitThreshold : 0

        guard max(swipeRatio, pinchRatio) >= 1 else { return }
        if swipeRatio >= pinchRatio {
            if swipeRatio >= pinchRatio * config.dominanceMargin {
                commitSwipe(now: now, translation: t, fingers: fingers)
            }
        } else {
            if pinchRatio >= swipeRatio * config.dominanceMargin {
                commitPinch(now: now, spread: s, fingers: fingers)
            }
        }
    }

    private func commitSwipe(now: TimeInterval, translation t: CGVector, fingers: Int) {
        if abs(t.dx) >= abs(t.dy) {
            committedDirection = t.dx >= 0 ? .right : .left
            committedSign = CGVector(dx: t.dx >= 0 ? 1 : -1, dy: 0)
        } else {
            committedDirection = t.dy >= 0 ? .up : .down
            committedSign = CGVector(dx: 0, dy: t.dy >= 0 ? 1 : -1)
        }
        // Seed the measure history from the centroid track since lock, so
        // a fast flick that commits and lifts within a few frames still
        // gets a real fling velocity.
        measureHistory = centroidHistory
            .filter { $0.t >= lockTime }
            .map { ($0.t, project($0.v)) }
        let magnitude = project(centroid())
        setState(.committed(kind: .swipe, fingers: fingers))
        emit(kind: .swipe, fingers: fingers, phase: .began,
             magnitude: magnitude, velocity: measureVelocity(now: now))
    }

    private func commitPinch(now: TimeInterval, spread s: Double, fingers: Int) {
        committedDirection = .none
        measureHistory = spreadHistory.map { ($0.t, $0.v / baselineSpread) }
        setState(.committed(kind: .pinch, fingers: fingers))
        emit(kind: .pinch, fingers: fingers, phase: .began,
             magnitude: s / baselineSpread, velocity: measureVelocity(now: now))
    }

    private func updateCommitted(kind: GestureEvent.Kind, fingers: Int, now: TimeInterval) {
        let value: Double
        switch kind {
        case .swipe:
            value = project(centroid())
        case .pinch:
            value = spread(around: centroid()) / baselineSpread
        }
        measureHistory.append((now, value))
        trim(&measureHistory, now: now)
        emit(kind: kind, fingers: fingers, phase: .changed,
             magnitude: value, velocity: measureVelocity(now: now))
    }

    private func emitFinal(kind: GestureEvent.Kind, fingers: Int,
                           phase: GestureEvent.Phase, now: TimeInterval) {
        // The lifting frame already lost a finger, so recomputing the
        // measure from live touches would be wrong - report the last
        // full-count value instead.
        let magnitude = measureHistory.last?.v ?? 0
        emit(kind: kind, fingers: fingers, phase: phase,
             magnitude: magnitude, velocity: measureVelocity(now: now))
    }

    private func emit(kind: GestureEvent.Kind, fingers: Int, phase: GestureEvent.Phase,
                      magnitude: Double, velocity: Double) {
        let event = GestureEvent(kind: kind, direction: committedDirection,
                                 fingerCount: fingers, magnitude: magnitude,
                                 velocity: velocity, phase: phase)
        lastEvent = event
        onGesture?(event)
    }

    private func setState(_ new: State) {
        guard new != state else { return }
        state = new
        onStateChange?(new)
    }

    private func clearGestureState() {
        centroidHistory.removeAll()
        spreadHistory.removeAll()
        measureHistory.removeAll()
        committedDirection = .none
        committedSign = .zero
        baselineSpread = 0
    }

    // MARK: Geometry

    private func centroid() -> CGPoint {
        let pts = devicePoints.values
        guard !pts.isEmpty else { return .zero }
        var x = 0.0, y = 0.0
        for p in pts { x += p.x; y += p.y }
        return CGPoint(x: x / Double(pts.count), y: y / Double(pts.count))
    }

    /// Mean distance of the touches from their centroid. Works for any
    /// finger count; for two fingers it is half the inter-finger
    /// distance.
    private func spread(around c: CGPoint) -> Double {
        let pts = devicePoints.values
        guard pts.count >= 2 else { return 0 }
        var total = 0.0
        for p in pts { total += distance(p, c) }
        return total / Double(pts.count)
    }

    private func translation() -> CGVector {
        let c = centroid()
        return CGVector(dx: c.x - baselineCentroid.x, dy: c.y - baselineCentroid.y)
    }

    /// Signed distance of a centroid along the committed swipe direction.
    private func project(_ p: CGPoint) -> Double {
        (p.x - baselineCentroid.x) * committedSign.dx
            + (p.y - baselineCentroid.y) * committedSign.dy
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> Double {
        let dx = a.x - b.x, dy = a.y - b.y
        return (dx * dx + dy * dy).squareRoot()
    }

    private func measureVelocity(now: TimeInterval) -> Double {
        let cutoff = now - config.velocityWindow
        let recent = measureHistory.filter { $0.t >= cutoff }
        guard let first = recent.first, let last = recent.last, last.t > first.t else { return 0 }
        return (last.v - first.v) / (last.t - first.t)
    }

    private func centroidVelocity(now: TimeInterval) -> CGVector {
        let cutoff = now - config.velocityWindow
        let recent = centroidHistory.filter { $0.t >= cutoff }
        guard let first = recent.first, let last = recent.last, last.t > first.t else { return .zero }
        let dt = last.t - first.t
        return CGVector(dx: (last.v.x - first.v.x) / dt, dy: (last.v.y - first.v.y) / dt)
    }

    private func trim<T>(_ history: inout [(t: TimeInterval, v: T)], now: TimeInterval) {
        let cutoff = now - max(0.5, config.velocityWindow)
        if let idx = history.firstIndex(where: { $0.t >= cutoff }), idx > 0 {
            history.removeFirst(idx)
        }
    }

    // MARK: Debug snapshot (overlay support)

    public struct TouchDot {
        public var id: Int
        public var normalized: CGPoint
        public var device: CGPoint
    }

    public struct DebugSnapshot {
        public var state: State
        public var touches: [TouchDot]
        public var lockedCount: Int?
        public var committedKind: GestureEvent.Kind?
        public var committedDirection: GestureEvent.Direction
        public var translation: CGVector
        public var swipeSignal: Double
        public var spreadDelta: Double
        public var scale: Double
        public var centroidNormalized: CGPoint?
        public var velocity: CGVector
        public var deviceSize: CGSize
        public var lastEvent: GestureEvent?
    }

    public func snapshot(now: TimeInterval) -> DebugSnapshot {
        let dots = devicePoints.keys.sorted().map {
            TouchDot(id: $0, normalized: normalizedPoints[$0] ?? .zero,
                     device: devicePoints[$0] ?? .zero)
        }
        var lockedCount: Int?
        var committedKind: GestureEvent.Kind?
        switch state {
        case .locked(let n): lockedCount = n
        case .committed(let k, let n): lockedCount = n; committedKind = k
        default: break
        }
        var t = CGVector.zero
        var swipeSignal = 0.0
        var spreadDelta = 0.0
        var scale = 1.0
        if lockedCount != nil {
            t = translation()
            swipeSignal = max(abs(t.dx), abs(t.dy))
            let s = spread(around: centroid())
            spreadDelta = s - baselineSpread
            if baselineSpread > 1 { scale = s / baselineSpread }
        }
        var centroidNormalized: CGPoint?
        if !devicePoints.isEmpty, deviceSize.width > 0, deviceSize.height > 0 {
            let c = centroid()
            centroidNormalized = CGPoint(x: c.x / deviceSize.width, y: c.y / deviceSize.height)
        }
        return DebugSnapshot(state: state, touches: dots, lockedCount: lockedCount,
                             committedKind: committedKind, committedDirection: committedDirection,
                             translation: t, swipeSignal: swipeSignal, spreadDelta: spreadDelta,
                             scale: scale, centroidNormalized: centroidNormalized,
                             velocity: centroidVelocity(now: now), deviceSize: deviceSize,
                             lastEvent: lastEvent)
    }
}
