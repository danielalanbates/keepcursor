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
        var reconnectPolicy = CursorRecoveryPolicy()
        var reconnectCalls = 0
        func reconnect(_ now: Double, buttons: Int = 0,
                       result: CursorReconnectResult = .succeeded) -> Bool {
            reconnectPolicy.observe(buttons: buttons, now: now)
            return reconnectPolicy.attemptReconnect(enabled: true, isTarget: true,
                                                      buttons: buttons, now: now) {
                reconnectCalls += 1
                return result
            }
        }
        reconnectPolicy.requestReconnect()
        precondition(!reconnect(0, buttons: 3))
        precondition(!reconnect(0.5))
        precondition(!reconnect(0.74))
        precondition(reconnect(0.75)) // Explicit recovery once, after released buttons settle.
        precondition(!reconnect(4)) // Pending request was consumed.
        precondition(reconnectCalls == 1)

        reconnectPolicy.requestReconnect()
        precondition(!reconnect(4.1, result: .failed))
        precondition(!reconnect(4.2))
        precondition(!reconnect(7)) // Failed API must not become an automatic retry loop.
        precondition(reconnectCalls == 2)

        reconnectPolicy.requestReconnect()
        precondition(!reconnect(7.1, result: .deferred)) // Final input guard changed.
        precondition(reconnect(7.2)) // Deferred guard did not consume the explicit request.
        reconnectPolicy.requestReconnect()
        reconnectPolicy.reset() // Focus loss/pause cancels a bound request.
        precondition(!reconnect(10))
        precondition(!reconnect(10.3))

        for time in [11.0, 11.1, 11.2, 11.3] {
            reconnectPolicy.recordMotion(cursorMoved: false, deltaDistance: 4,
                                         atScreenEdge: false, buttons: 0, now: time)
        }
        precondition(reconnect(11.3)) // Real deltas with fixed native position establish a stall.
        let afterStall = reconnectCalls
        for time in [13.0, 13.1, 13.2, 13.3] {
            reconnectPolicy.recordMotion(cursorMoved: false, deltaDistance: 4,
                                         atScreenEdge: false, buttons: 0, now: time)
        }
        precondition(!reconnect(13.3)) // A persistent stall is single-use, even after cooldown.
        precondition(reconnectCalls == afterStall)
        reconnectPolicy.nativePointerMoved() // Only actual movement or a held-button episode rearms.
        for time in [14.0, 14.1, 14.2, 14.3] {
            reconnectPolicy.recordMotion(cursorMoved: false, deltaDistance: 4,
                                         atScreenEdge: true, buttons: 0, now: time)
        }
        precondition(!reconnect(14.3)) // Normal screen-edge clamp is not a stalled pointer.
        reconnectPolicy.nativePointerMoved()
        for time in [15.0, 15.1, 15.2, 15.3] {
            reconnectPolicy.recordMotion(cursorMoved: false, deltaDistance: 0.1,
                                         atScreenEdge: false, buttons: 0, now: time)
        }
        precondition(!reconnect(15.3)) // Subpixel rounding is not evidence of a stalled cursor.
        var explicit = ExplicitCursorRescue()
        var explicitCalls = 0
        func rescue(_ now: Double, pid: Int32? = 59662, event: Int = 0,
                    hid: UInt64 = 0, session: UInt64 = 0,
                    result: CursorReconnectResult = .succeeded) -> CursorReconnectResult? {
            explicit.service(frontPID: pid, eventButtons: event, hidButtons: hid,
                             sessionButtons: session, now: now) { observedPID in
                precondition(observedPID == pid)
                explicitCalls += 1
                return result
            }
        }
        explicit.request(now: 0)
        precondition(rescue(0) == nil)
        precondition(rescue(0.1, event: 1) == nil)
        precondition(rescue(0.2, hid: 2) == nil)
        precondition(rescue(0.3, session: 3) == nil)
        precondition(rescue(0.4) == nil)
        precondition(rescue(0.64) == nil)
        precondition(rescue(0.65) == .succeeded) // Current foreground can be Terminal, not a game.
        precondition(rescue(5) == nil && explicitCalls == 1) // Exactly one API attempt.
        explicit.request(now: 6)
        precondition(rescue(6) == nil)
        precondition(rescue(6.25, result: .failed) == .failed)
        precondition(rescue(7) == nil && explicitCalls == 2) // Error consumes the request.
        explicit.request(now: 8)
        precondition(rescue(8) == nil)
        precondition(rescue(8.2, pid: 37122) == nil) // New foreground resets settling.
        precondition(rescue(8.44, pid: 37122) == nil)
        precondition(rescue(8.45, pid: 37122, result: .deferred) == .deferred)
        precondition(explicit.pending)
        precondition(rescue(8.46, pid: 37122) == nil)
        precondition(rescue(8.70, pid: 37122) == nil)
        precondition(rescue(8.72, pid: 37122) == .succeeded)
        explicit.request(now: 10)
        precondition(rescue(70.1) == nil && explicit.state == "expired")
        precondition(!explicit.pending)
        print("Cursor recovery policy passed: holds, release settling, throttling, focus, pause, manual, overlay, explicit/stalled reconnect, failed API consumption, edge/subpixel rejection, explicit foreground rescue and one-attempt consumption.")
    }
}
