// All rights reserved. Copyright (c) 2026 Bates LLC / Daniel Bates.

/// Pure input safety policy; no cursor or window APIs are called here.
enum CursorReconnectResult {
    case deferred, succeeded, failed
}

struct CursorRecoveryPolicy {
    static let releaseGracePeriod = 0.25
    static let recoveryInterval = 1.0
    private var idleSince: Double?
    private var lastRecovery = -Double.infinity
    private var pendingReconnect = false
    private var lastReconnect = -Double.infinity
    private var stallSince: Double?
    private var lastMotion = -Double.infinity
    private var stallEvents = 0
    private var stallDistance = 0.0
    private var stallConsumed = false

    mutating func reset() {
        idleSince = nil
        pendingReconnect = false
        nativePointerMoved()
    }

    mutating func requestReconnect() {
        pendingReconnect = true
    }

    mutating func cancelReconnectRequest() {
        pendingReconnect = false
    }

    mutating func nativePointerMoved() {
        stallSince = nil
        stallEvents = 0
        stallDistance = 0
        stallConsumed = false
    }

    /// Evidence comes from real movement events, never from an idle stationary pointer.
    mutating func recordMotion(cursorMoved: Bool, deltaDistance: Double,
                               atScreenEdge: Bool, buttons: Int, now: Double) {
        observe(buttons: buttons, now: now)
        guard buttons == 0, !cursorMoved, !atScreenEdge else {
            nativePointerMoved()
            return
        }
        guard deltaDistance > 0 else { return }
        if now - lastMotion > 0.2 {
            stallSince = nil
            stallEvents = 0
            stallDistance = 0
        }
        if stallSince == nil { stallSince = now }
        stallEvents += 1
        stallDistance += deltaDistance
        lastMotion = now
    }

    /// One explicit request or one evidenced stall episode can reconnect input.
    /// Errors consume the attempt too; a failing API must never become a 60 Hz loop.
    mutating func attemptReconnect(enabled: Bool, isTarget: Bool, buttons: Int,
                                   now: Double, reconnect: () -> CursorReconnectResult) -> Bool {
        guard enabled, isTarget, buttons == 0,
              let idleSince, now - idleSince >= Self.releaseGracePeriod,
              now - lastReconnect >= 2 else { return false }
        let stalled = !stallConsumed && stallSince.map { now - $0 >= 0.25 } == true
            && stallEvents >= 3 && stallDistance >= 12 && now - lastMotion <= 0.2
        guard pendingReconnect || stalled else { return false }
        let result = reconnect()
        guard result != .deferred else { return false }
        pendingReconnect = false
        stallConsumed = true
        lastReconnect = now
        return result == .succeeded
    }

    mutating func observe(buttons: Int, now: Double) {
        if buttons != 0 {
            idleSince = nil
            nativePointerMoved()
        } else if idleSince == nil {
            idleSince = now
        }
    }

    /// The callback is invoked only when the current focus and buttons allow it.
    /// A failed final live-input check does not consume the retry interval.
    mutating func attemptRestore(
        enabled: Bool, isTarget: Bool, buttons: Int, cursorVisible: Bool,
        now: Double, manual: Bool = false, restore: () -> Bool
    ) -> Bool {
        guard enabled, isTarget, buttons == 0 else { return false }
        if !manual {
            guard let idleSince, now - idleSince >= Self.releaseGracePeriod,
                  !cursorVisible, now - lastRecovery >= Self.recoveryInterval else { return false }
        }
        guard restore() else { return false }
        lastRecovery = now
        return true
    }

    static func shouldShowOverlay(
        enabled: Bool, isTarget: Bool, overlayEnabled: Bool, buttons: Int
    ) -> Bool {
        enabled && isTarget && overlayEnabled && buttons == 0
    }
}
