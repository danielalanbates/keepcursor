// All rights reserved. Copyright (c) 2026 Bates LLC / Daniel Bates.
// Run with swiftc Sources/CursorRecoveryPolicy.swift Tests/CursorRecoveryPolicyTests.swift -o <output>.

@main
enum CursorRecoveryPolicyTests {
    static func main() {
        var policy = CursorRecoveryPolicy()
        var repairs = 0
        func attempt(_ now: Double, buttons: Int = 0, enabled: Bool = true,
                     target: Bool = true, visible: Bool = false, manual: Bool = false,
                     operationSucceeds: Bool = true) -> Bool {
            policy.observe(buttons: buttons, now: now)
            return policy.attemptRestore(enabled: enabled, isTarget: target, buttons: buttons,
                                         cursorVisible: visible, now: now, manual: manual) {
                repairs += 1
                return operationSucceeds
            }
        }

        precondition(!attempt(0)) // Allow the game to finish establishing focus/capture.
        precondition(!attempt(0.1, buttons: 2)) // Right camera hold.
        precondition(!attempt(0.4, buttons: 3, manual: true)) // Both held, even on hotkey.
        precondition(!attempt(0.5)) // Release just happened.
        precondition(!attempt(0.74))
        precondition(attempt(0.75)) // Hidden cursor after a settled release.
        precondition(repairs == 1)
        precondition(!attempt(1.0)) // No 60 Hz repair storm.
        precondition(!attempt(1.8, visible: true)) // Normal cursor needs no repair.
        precondition(!attempt(1.8, enabled: false)) // Paused delayed callback.
        precondition(!attempt(1.8, target: false)) // Focus switched before callback.
        precondition(repairs == 1)
        precondition(attempt(1.8)) // Retry persistent visibility loss, with no input mutation.
        precondition(attempt(1.81, visible: true, manual: true)) // Explicit restore bypasses throttle.

        policy.reset() // New focus generation cannot use an old release timestamp.
        precondition(!attempt(4.0))
        precondition(!attempt(4.25, operationSucceeds: false)) // Final live check rejected repair.
        precondition(attempt(4.26)) // Failed operation must not suppress the next safe retry.

        precondition(CursorRecoveryPolicy.shouldShowOverlay(enabled: true, isTarget: true,
                                                             overlayEnabled: true, buttons: 0))
        for buttons in [1, 2, 3, 4, 16] {
            precondition(!CursorRecoveryPolicy.shouldShowOverlay(enabled: true, isTarget: true,
                                                                  overlayEnabled: true, buttons: buttons))
        }
        precondition(!CursorRecoveryPolicy.shouldShowOverlay(enabled: false, isTarget: true,
                                                              overlayEnabled: true, buttons: 0))
        precondition(!CursorRecoveryPolicy.shouldShowOverlay(enabled: true, isTarget: false,
                                                              overlayEnabled: true, buttons: 0))
        print("Cursor recovery policy passed: holds, release settling, throttling, focus, pause, manual, overlay.")
    }
}
