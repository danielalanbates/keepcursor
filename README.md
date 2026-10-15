# KeepCursor

Keep the cursor visible in World of Warcraft on macOS after Command-Tab or a cursor visibility glitch.

A small menu-bar helper from [Bates LLC](https://batesai.org). Contact: [help@batesai.org](mailto:help@batesai.org).

## Local beta: 2.3.0b3

This beta fixes gameplay interference from the previous cursor recovery implementation. That implementation repeatedly reconnected the mouse to the cursor, tracked a separate virtual pointer, and warped the real pointer after mouse-button release. Those operations could interfere with WoW's relative mouse capture and make the overlay appear disconnected from actual clicks.

The beta keeps cursor recovery enabled:

- Accepts an explicit one-shot rescue for the current foreground application, including the desktop. It waits for the same foreground PID and released AppKit/HID/session mouse buttons to remain stable for 250 ms, rechecks immediately before the API call, and consumes that attempt even on error.
- Keeps automatic game recovery scoped to WoW (or the existing opt-in watch-all-games setting). Its stall recovery requires physical movement evidence; explicit rescue does not depend on receiving movement-monitor events.
- Restores native cursor **visibility** when WoW is frontmost and the cursor is hidden, after all mouse buttons have been released for 250 ms.
- Limits automatic visibility repairs to once per second. A failed final input check does not suppress the next safe retry.
- Displays a click-through fallback pointer at the actual macOS cursor position. The fallback hides during camera turns, clicks, and drags, and returns on release.
- Uses a classic arrow by default; saved overlay styles and colors are preserved. The menu can select an arrow, ring, or dot.
- Rechecks focus and button state before repairs. Delayed activation callbacks are canceled by focus changes or pausing.
- Leaves normal relative movement, button events, and cursor position under the game's control. A reconnect requires settled released buttons, current target focus, and a final live input check.

The stall detector requires at least three real movement events, at least 12 points of cumulative movement, and 250 ms of unchanged native cursor position with no mouse button held. It ignores screen-edge clamping and subpixel movement. It tries once per stall episode, rearms only after native movement or a new mouse-button hold, and spaces attempts by at least two seconds. Failed API calls consume their attempt too.

**Option-Command-C** or a left click on the menu-bar icon requests one reconnect plus visibility recovery for the current foreground app. This explicit action also works while automatic game recovery is paused. If focus changes before the attempt, it waits for the new foreground application and released buttons to settle again. A final input-check deferral restarts the full 250 ms grace period. Unserviced requests expire after 60 seconds.

For one explicitly requested rescue on a new app launch, use `--rescue-cursor-now`. An optional `--diagnostics-output /absolute/path/rescue-diagnostics.json` writes one bounded local snapshot, overwritten at most once per second plus state changes. It includes foreground app name/PID, button masks, request/attempt/result state, timer and motion counts, and hotkey registration return codes. It records no coordinates or input text; keep the file outside Git. Start only one app instance. The older `--recover-pointer-once` remains game-scoped.

Recovery is best effort: Apple's cursor APIs are documented for foreground callers, and macOS may ignore or reject a background helper's repair. An API success does not prove that game input recovered. The app logs the reconnect return code and can passively observe subsequent native pointer movement; it never changes app focus automatically. If input remains stuck, switch away from WoW and back, then press and release each mouse button normally to let the game reset its input state. The overlay always uses the actual click position.

The local beta has passed compilation, signature verification, and input safety regression tests. Live WoW verification is pending; see [TEST_PLAN.md](TEST_PLAN.md). It has not been published as a public release or notarized.

## Controls

| Action | Control |
| --- | --- |
| Restore visibility now | **Option-Command-C**, or left-click the menu-bar icon |
| Open settings | Right-click or Control-click the menu-bar icon |
| Pause automatic game recovery and hide the fallback | **Pause KeepCursor** in the menu |
| Select pointer appearance | **Cursor Overlay Style** and **Cursor Color** |
| Keep a larger cursor | **Keep cursor size** and its slider |

The restore shortcut requests a single input reconnect and visibility repair for the current foreground app. It waits for stable focus and released buttons. Settings and rescue requests do not bring an application to the front.

## Download

Published, notarized builds are available from [GitHub Releases](https://github.com/danielalanbates/keepcursor/releases/latest). The 2.3.0b3 beta source is being validated before a new public release. Do not treat an older release as containing this fix.

## Build and verify

Requires macOS 13+ and the Xcode command-line tools (`swiftc`). Two Swift source files, no third-party dependencies. `build.sh` builds for the current Mac's architecture and applies an ad-hoc signature.

```bash
git clone https://github.com/danielalanbates/keepcursor
cd keepcursor
BUILD_DIR="$HOME/Downloads/keepcursor-build" ./build.sh

swiftc Sources/CursorRecoveryPolicy.swift Tests/CursorRecoveryPolicyTests.swift \
  -o "$HOME/Downloads/keepcursor-policy-tests"
"$HOME/Downloads/keepcursor-policy-tests"
```

The policy tests do not launch an app or change the real mouse. `release.sh` is a separate, explicit notarized release workflow; run it only after live verification. Installing a local beta does not require running it.

## Implementation notes

`Sources/CursorRecoveryPolicy.swift` contains the testable release settling, retry interval, focus, pause, and overlay policy. `Sources/main.swift` owns the menu-bar UI, native-position overlay, and visibility APIs. The final visibility operation checks live focus and buttons again, because the input may change after an activation callback was queued.

An inactive WoW process does not make another foreground application a game-recovery target. The diagnostics distinguish the actual foreground application from a running background game. The helper passively observes mouse movement for stall evidence. It does not post mouse events, install an event tap, accumulate a separate virtual pointer, or warp the cursor. Mouse association changes are confined to the guarded single-request/single-stall recovery path. Overlay windows ignore mouse events. Appearance changes invalidate the view immediately.

[Apple's CGDisplayShowCursor documentation](https://developer.apple.com/documentation/coregraphics/cgdisplayshowcursor(_:)) explains the cursor hide count and foreground-app limitation. [Apple's cursor-control guide](https://developer.apple.com/library/archive/documentation/GraphicsImaging/Conceptual/QuartzDisplayServicesConceptual/Articles/MouseCursor.html) documents the foreground requirement for mouse association. The optional SkyLight visibility and cursor-size APIs are private and may be unavailable on future macOS versions; missing visibility queries fail toward quiet behavior rather than repeated repairs.

## License

All rights reserved. Copyright (c) 2026 Bates LLC / Daniel Bates. See [LICENSE](LICENSE) for the existing PolyForm Noncommercial terms and the commercial revenue-sharing rider.
