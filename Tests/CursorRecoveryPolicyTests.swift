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

        var overlay = CursorRecoveryPolicy()
        func show(_ now: Double, buttons: Int = 0, visible: Bool = false, enabled: Bool = true,
                  target: Bool = true, overlayEnabled: Bool = true) -> Bool {
            overlay.shouldShowOverlay(enabled: enabled, isTarget: target,
                                      overlayEnabled: overlayEnabled, buttons: buttons,
                                      cursorVisible: visible, now: now)
        }
        // Game cursor (gauntlet) on screen: backup pointer stays hidden.
        precondition(!show(0, visible: true))
        precondition(!show(5, visible: true))
        // Camera turn hides the native cursor while a button is held: never shown.
        precondition(!show(5.1, buttons: 2))
        precondition(!show(6.0, buttons: 2))
        // Release while WoW redraws its cursor a moment later: no flash.
        precondition(!show(6.02))
        precondition(!show(6.05, visible: true))
        // Native cursor gone with every button released: shown after the delay.
        precondition(!show(7.0))
        precondition(!show(7.29))
        precondition(show(7.31))
        precondition(show(9.0))
        // Gauntlet returns or a button goes down: hidden at once, delay restarts.
        precondition(!show(9.01, visible: true))
        precondition(!show(9.02))
        precondition(show(9.33))
        for buttons in [1, 2, 3, 4, 16] {
            precondition(!show(9.4, buttons: buttons))
        }
        precondition(!show(9.5) && !show(9.79) && show(9.81))
        precondition(!show(10, enabled: false))
        precondition(!show(20, target: false))
        precondition(!show(30, overlayEnabled: false))
        precondition(!show(30.1) && show(30.41))
        // A visible reading right after KeepCursor's own repair is ignored.
        precondition(!show(39.9, visible: true) && !show(40) && show(40.31))
        precondition(overlay.attemptRestore(enabled: true, isTarget: true, buttons: 0,
                                            cursorVisible: false, now: 40.4, manual: true) { true })
        precondition(show(40.45, visible: true))
        precondition(!show(40.6, visible: true))
        precondition(!show(41) && show(41.31))
        overlay.reset() // Focus change restarts the delay.
        precondition(!show(41.32) && show(41.63))
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
        // Captured-pointer detector (WoW left the OS pointer captured).
        var cap = CapturedPointerDetector()
        func mv(_ now: Double, target: Bool = true, buttons: Int = 0, x: Double = 640,
                y: Double = 400, d: Double = 4, edge: Bool = false) -> CapturedPointerDetector.Action {
            cap.motion(isTarget: target, buttons: buttons, x: x, y: y, delta: d, atScreenEdge: edge, now: now)
        }
        func feed(_ from: Double, _ to: Double, target: Bool = true, buttons: Int = 0,
                  x: Double = 640, d: Double = 4, edge: Bool = false, moving: Bool = false) -> [Double] {
            var fires: [Double] = []
            var t = from, px = x
            while t < to - 1e-9 {
                if moving { px += 3 }
                _ = cap.tick(now: t)
                if mv(t, target: target, buttons: buttons, x: px, d: d, edge: edge) == .fire { fires.append(t) }
                t += 1.0 / 60
            }
            return fires
        }
        // Normal movement: pointer follows the mouse.
        precondition(feed(0, 3, moving: true).isEmpty)
        // Right-drag mouselook (button held, pointer frozen): never.
        precondition(feed(3, 6, buttons: 2).isEmpty)
        // WoW not frontmost: never.
        precondition(feed(6, 9, target: false).isEmpty)
        // Frozen at a screen edge (normal clamp): never.
        precondition(feed(9, 12, edge: true).isEmpty)
        // Sub-threshold: tiny deltas totalling < 20 px.
        precondition(feed(12, 12.6, d: 0.2).isEmpty)
        // Pauses longer than 0.2 s restart the count.
        cap = CapturedPointerDetector()
        _ = mv(20); _ = mv(20.3); _ = mv(20.6); _ = mv(20.9); _ = mv(21.2)
        precondition(cap.fired == 0)
        // Captured: frozen with real deltas after release -> fires once ~0.4 s in.
        cap = CapturedPointerDetector()
        _ = feed(29, 30, buttons: 1) // left button held
        var f = feed(30, 31)
        precondition(f.count == 1 && f[0] >= 30.4 && f[0] < 30.5, "fires after 0.4 s stall")
        // Verify: pointer moves -> freed, misses reset.
        precondition(mv(31.1, x: 700) == .freed && cap.freed == 1 && cap.misses == 0)
        // Unverified unlocks back off: 10, 20, 40 s (base 5 s doubles per miss).
        cap = CapturedPointerDetector()
        f = feed(40, 120)
        precondition(f.count >= 4)
        let gaps = zip(f.dropFirst(), f).map { $0 - $1 }
        precondition(gaps[0] >= 10 && gaps[0] < 11, "first gap \(gaps)")
        precondition(gaps[1] > gaps[0] + 3 && gaps[2] > gaps[1] + 6, "backoff \(gaps)")
        precondition(cap.failed >= 3 && cap.misses >= 3)
        // Verify timeout via tick.
        cap = CapturedPointerDetector()
        _ = feed(300, 300.5)
        precondition(cap.fired == 1 && cap.verifying)
        precondition(cap.tick(now: 301) == .none && cap.tick(now: 302.6) == .verifyFailed && cap.misses == 1)
        // Focus regained: needs a fresh release settle.
        cap = CapturedPointerDetector()
        _ = feed(400, 401, target: false)
        f = feed(401, 402)
        precondition(f.count == 1 && f[0] >= 401.4)
        // Undelivered fire backs off too.
        cap.fireNotDelivered()
        precondition(!cap.verifying && cap.misses == 1 && cap.cooldown == 10)
        print("Cursor recovery policy passed (captured-pointer detector too): holds, release settling, throttling, focus, pause, manual, overlay, explicit/stalled reconnect, failed API consumption, edge/subpixel rejection, explicit foreground rescue and one-attempt consumption, backup pointer only while the native cursor is hidden.")
    }
}
