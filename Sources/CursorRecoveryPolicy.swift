// All rights reserved. Copyright (c) 2026 Bates LLC / Daniel Bates.

/// Pure input safety policy; no cursor or window APIs are called here.
enum CursorReconnectResult {
    case deferred, succeeded, failed
}

/// A user-requested rescue is independent of automatic game recovery. It waits
/// for a stable foreground application and released physical/session buttons.
struct ExplicitCursorRescue {
    private(set) var pending = false
    private(set) var state = "idle"
    private(set) var attempts = 0
    private var expiresAt = 0.0
    private var frontPID: Int32?
    private var frontSince = 0.0
    private var releasedSince: Double?

    mutating func request(now: Double) {
        pending = true
        state = "requested"
        expiresAt = now + 60
        frontPID = nil
        releasedSince = nil
    }

    mutating func service(frontPID currentPID: Int32?, eventButtons: Int,
                          hidButtons: UInt64, sessionButtons: UInt64, now: Double,
                          rescue: (Int32) -> CursorReconnectResult) -> CursorReconnectResult? {
        guard pending else { return nil }
        guard now <= expiresAt else {
            pending = false
            state = "expired"
            return nil
        }
        guard let currentPID else {
            frontPID = nil
            releasedSince = nil
            state = "waiting_for_foreground"
            return nil
        }
        if frontPID != currentPID {
            frontPID = currentPID
            frontSince = now
            releasedSince = nil
        }
        guard eventButtons == 0, hidButtons == 0, sessionButtons == 0 else {
            releasedSince = nil
            state = "waiting_for_button_release"
            return nil
        }
        if releasedSince == nil { releasedSince = now }
        guard now - frontSince >= 0.25,
              now - (releasedSince ?? now) >= 0.25 else {
            state = "waiting_for_stable_release"
            return nil
        }
        let result = rescue(currentPID)
        if result == .deferred {
            releasedSince = nil
            frontSince = now
            state = "deferred_by_live_input_check"
        } else {
            attempts += 1
            pending = false
            state = result == .succeeded ? "api_accepted" : "api_rejected"
        }
        return result
    }
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
    private var hiddenReleasedSince: Double?

    mutating func reset() {
        idleSince = nil
        hiddenReleasedSince = nil
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

    /// The backup pointer stays hidden while the game's own cursor (WoW's
    /// gauntlet) is on screen. It appears only after the native cursor has been
    /// hidden with every button released for `overlayRevealDelay`, so camera
    /// turns and the frame or two WoW takes to redraw its cursor after release
    /// never flash it. A visible native cursor or any held button hides it at once.
    static let overlayRevealDelay = 0.3
    static let ownRepairBlip = 0.15

    mutating func shouldShowOverlay(
        enabled: Bool, isTarget: Bool, overlayEnabled: Bool, buttons: Int,
        cursorVisible: Bool, now: Double
    ) -> Bool {
        // KeepCursor's own once-a-second visibility repair can flip the global
        // flag for a frame before WoW hides its cursor again; ignore that blip so
        // the backup pointer does not blink.
        let visible = cursorVisible && now - lastRecovery >= Self.ownRepairBlip
        guard enabled, isTarget, overlayEnabled, buttons == 0, !visible else {
            hiddenReleasedSince = nil
            return false
        }
        if hiddenReleasedSince == nil { hiddenReleasedSince = now }
        return now - (hiddenReleasedSince ?? now) >= Self.overlayRevealDelay
    }
}

/// Detects WoW leaving the OS pointer captured: WoW frontmost, every button up
/// (so never an intentional right-drag mouselook), real mouse deltas arriving,
/// yet the pointer position does not change. The Mac app answers a detection by
/// pressing the addon's hidden unlock key; the addon itself ignores it while WoW
/// is intentionally mouselooking. Pure: no cursor, window or event APIs here.
struct CapturedPointerDetector {
    enum Action: Equatable { case none, fire, freed, verifyFailed }

    static let releaseSettle = 0.25
    static let stallSeconds = 0.4
    static let minDistance = 20.0
    static let minEvents = 3
    static let gapReset = 0.2
    static let baseCooldown = 5.0
    static let maxCooldown = 120.0
    static let verifyWindow = 2.0

    private(set) var fired = 0
    private(set) var freed = 0
    private(set) var failed = 0
    private(set) var misses = 0
    private var wasTarget = false
    private var releasedSince: Double?
    private var lastLocation: (x: Double, y: Double)?
    private var stallSince: Double?
    private var stallDistance = 0.0
    private var stallEvents = 0
    private var lastMotion = -Double.infinity
    private var lastFire = -Double.infinity
    private var verify: (x: Double, y: Double, deadline: Double)?

    var cooldown: Double { min(Self.baseCooldown * pow2(misses), Self.maxCooldown) }
    var verifying: Bool { verify != nil }

    private func pow2(_ n: Int) -> Double { Double(1 << min(n, 20)) }

    private mutating func resetStall() {
        stallSince = nil
        stallDistance = 0
        stallEvents = 0
    }

    /// One physical mouse-motion event. `delta` is the device delta (pixels);
    /// `x`,`y` the OS pointer position after the event.
    mutating func motion(isTarget: Bool, buttons: Int, x: Double, y: Double,
                         delta: Double, atScreenEdge: Bool, now: Double) -> Action {
        defer { lastLocation = (x, y); wasTarget = isTarget }
        let moved = lastLocation.map { $0.x != x || $0.y != y } ?? true
        if let v = verify, isTarget, buttons == 0, v.x != x || v.y != y {
            verify = nil
            freed += 1
            misses = 0
            resetStall()
            return .freed
        }
        guard isTarget else {
            releasedSince = nil
            resetStall()
            return .none
        }
        if !wasTarget { releasedSince = nil }
        guard buttons == 0 else {
            releasedSince = nil
            resetStall()
            return .none
        }
        if releasedSince == nil { releasedSince = now }
        guard !moved, !atScreenEdge else {
            resetStall()
            return .none
        }
        guard delta > 0 else { return .none }
        if now - lastMotion > Self.gapReset { resetStall() }
        if stallSince == nil { stallSince = now }
        stallDistance += delta
        stallEvents += 1
        lastMotion = now
        guard verify == nil,
              let releasedSince, now - releasedSince >= Self.releaseSettle,
              let stallSince, now - stallSince >= Self.stallSeconds,
              stallDistance >= Self.minDistance, stallEvents >= Self.minEvents,
              now - lastFire >= cooldown else { return .none }
        lastFire = now
        fired += 1
        verify = (x, y, now + Self.verifyWindow)
        resetStall()
        return .fire
    }

    /// The posted unlock could not be delivered (no permission, focus changed).
    mutating func fireNotDelivered() {
        verify = nil
        misses = min(misses + 1, 10)
    }

    /// Periodic tick: expires an unverified unlock and backs off.
    mutating func tick(now: Double) -> Action {
        guard let v = verify, now > v.deadline else { return .none }
        verify = nil
        failed += 1
        misses = min(misses + 1, 10)
        return .verifyFailed
    }
}
