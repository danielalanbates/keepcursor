// All rights reserved. Copyright (c) 2026 Bates LLC / Daniel Bates.

/// Pure input safety policy; no cursor or window APIs are called here.
struct CursorRecoveryPolicy {
    static let releaseGracePeriod = 0.25
    static let recoveryInterval = 1.0
    private var idleSince: Double?
    private var lastRecovery = -Double.infinity

    mutating func reset() {
        idleSince = nil
    }

    mutating func observe(buttons: Int, now: Double) {
        if buttons != 0 {
            idleSince = nil
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
