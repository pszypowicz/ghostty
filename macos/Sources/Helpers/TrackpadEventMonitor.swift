import AppKit

/// App-level trackpad gesture acquisition and routing.
///
/// AppKit routes touch events to the view under the pointer and cuts or
/// re-routes delivery when window topology changes mid-sequence: a
/// gesture-driven tab switch hides the window that owned the sequence, its
/// remaining touch events never arrive, and the still-down fingers are
/// re-delivered to the revealed view as a fresh sequence. Per-view touch
/// handling therefore cannot observe one physical gesture continuously and
/// needs defensive repair logic for every topology change its own actions
/// cause.
///
/// A local event monitor observes events before dispatch, independent of
/// window topology, so the single recognizer here spans each physical
/// sequence by construction: one landing, one commit, one action, one
/// drain - regardless of what the action did to the windows. Verified
/// empirically: `.gesture` events carry the full indirect-touch stream and
/// keep flowing across `makeKeyAndOrderFront` mid-sequence, including
/// complete ended frames addressed to non-key windows.
///
/// Routing is explicit and sticky: when a sequence begins, the target
/// surface is resolved once (the surface under the pointer, falling back to
/// the window's focused surface when the pointer is over chrome like the
/// tab bar) and receives every event of that gesture.
///
/// Set GHOSTTY_TRACKPAD_DEBUG to trace frames and recognizer state to
/// stderr.
final class TrackpadEventMonitor {
    static let debug = ProcessInfo.processInfo.environment["GHOSTTY_TRACKPAD_DEBUG"] != nil

    private let recognizer = TrackpadGestureRecognizer()
    private var monitor: Any?
    private var touchIds: [NSObject: Int] = [:]
    private var nextTouchId: Int = 1
    private var tickTimer: Timer?
    private var touchMods: NSEvent.ModifierFlags = []
    private weak var target: Ghostty.SurfaceView?

    init() {
        recognizer.onGesture = { [weak self] event in
            guard let self, let target = self.target else { return }
            target.handleTrackpadGesture(event, mods: self.touchMods)
        }
        if Self.debug {
            recognizer.onStateChange = { state in
                Self.trace("state -> \(state.label)")
            }
        }
    }

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .gesture) { [weak self] event in
            self?.observe(event)
            return event
        }
    }

    func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    deinit {
        tickTimer?.invalidate()
        stop()
    }

    private func observe(_ event: NSEvent) {
        let touches = event.allTouches().filter { $0.type == .indirect }
        guard !touches.isEmpty else { return }
        touchMods = event.modifierFlags

        // A frame arriving while the recognizer is idle starts a new
        // physical sequence: resolve the routing target once, sticky for
        // the sequence's lifetime.
        if recognizer.state == .idle {
            target = Self.resolveTarget(for: event)
        }

        var deviceSize = CGSize(width: 1, height: 1)
        var samples: [TouchSample] = []
        for touch in touches {
            deviceSize = touch.deviceSize
            // identity is stable across the touch's lifetime and adopts
            // NSCopying; copies compare equal to the original, so lookups
            // use the identity directly and only stored keys are copied
            // (the sanctioned way to retain an identity beyond the event).
            guard let key = touch.identity as? NSObject else { continue }
            let id: Int
            if let known = touchIds[key] {
                id = known
            } else {
                id = nextTouchId
                nextTouchId += 1
                touchIds[(key.copy() as? NSObject) ?? key] = id
            }
            let phase = Self.touchPhase(touch.phase)
            if phase == .ended || phase == .cancelled {
                touchIds.removeValue(forKey: key)
            }
            let p = touch.normalizedPosition
            samples.append(TouchSample(id: id, x: p.x, y: p.y, phase: phase))
        }

        if Self.debug {
            let phases = samples.map { $0.phase.rawValue }.joined(separator: ",")
            Self.trace("frame [\(phases)] win=\(event.windowNumber)")
        }

        recognizer.process(TouchFrame(
            t: event.timestamp,
            w: deviceSize.width,
            h: deviceSize.height,
            touches: samples))
        syncTickTimer()
    }

    /// The surface a beginning sequence should act on: the surface under
    /// the pointer, or the window's focused surface when the pointer is
    /// over non-surface chrome, so gestures work anywhere over the window.
    private static func resolveTarget(for event: NSEvent) -> Ghostty.SurfaceView? {
        guard let window = event.window ?? NSApp.window(withWindowNumber: event.windowNumber)
        else { return NSApp.keyWindow?.firstResponder as? Ghostty.SurfaceView }

        if let frameView = window.contentView?.superview {
            var view = frameView.hitTest(event.locationInWindow)
            while let current = view {
                if let surface = current as? Ghostty.SurfaceView { return surface }
                view = current.superview
            }
        }
        return window.firstResponder as? Ghostty.SurfaceView
    }

    private static func touchPhase(_ phase: NSTouch.Phase) -> TouchPhase {
        if phase.contains(.began) { return .began }
        if phase.contains(.moved) { return .moved }
        if phase.contains(.ended) { return .ended }
        if phase.contains(.cancelled) { return .cancelled }
        return .stationary
    }

    /// Stationary fingers stop producing touch events, but the recognizer's
    /// settle and stale-frame timers still need a clock. NSEvent.timestamp
    /// and systemUptime share one.
    private func syncTickTimer() {
        let active = recognizer.state != .idle
        if active && tickTimer == nil {
            tickTimer = Timer.scheduledTimer(
                withTimeInterval: 1.0 / 120.0,
                repeats: true
            ) { [weak self] timer in
                guard let self else {
                    timer.invalidate()
                    return
                }
                self.recognizer.tick(now: ProcessInfo.processInfo.systemUptime)
                self.syncTickTimer()
            }
        } else if !active, let timer = tickTimer {
            timer.invalidate()
            tickTimer = nil
            touchIds.removeAll()
        }
    }

    private static func trace(_ message: String) {
        // stderr: stdout is fully buffered when piped, and these traces
        // must survive the process being killed.
        FileHandle.standardError.write(Data("trackpad-monitor: \(message)\n".utf8))
    }
}
