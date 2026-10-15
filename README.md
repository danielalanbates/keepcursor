# KeepCursor

Keep the cursor visible in World of Warcraft on macOS after Command-Tab or a cursor visibility glitch.

A small menu-bar helper from [Bates LLC](https://batesai.org). Contact: [help@batesai.org](mailto:help@batesai.org).

## Local beta: 2.3.0b1

This beta fixes gameplay interference from the previous cursor recovery implementation. That implementation repeatedly reconnected the mouse to the cursor, tracked a separate virtual pointer, and warped the real pointer after mouse-button release. Those operations could interfere with WoW's relative mouse capture and make the overlay appear disconnected from actual clicks.

The beta keeps cursor recovery enabled:

- Restores native cursor **visibility** when WoW is frontmost and the cursor is hidden, after all mouse buttons have been released for 250 ms.
- Limits automatic visibility repairs to once per second. A failed final input check does not suppress the next safe retry.
- Displays a click-through fallback pointer at the actual macOS cursor position. The fallback hides during camera turns, clicks, and drags, and returns on release.
- Uses a classic arrow by default; saved overlay styles and colors are preserved. The menu can select an arrow, ring, or dot.
- Rechecks focus and button state before repairs. Delayed activation callbacks are canceled by focus changes or pausing.
- Leaves mouse association, relative movement, button events, and cursor position under the game's control.

Native visibility recovery is best effort: macOS may ignore a background helper's show-cursor request. The overlay supplies a visible fallback when native repainting fails. If the game itself has stuck input capture and its real cursor coordinates stop moving, a display-only overlay cannot repair that state or move the game's click location. Switch away from WoW and back, then press and release each mouse button normally to let the game reset its input state.

The local beta has passed compilation, signature verification, and input safety regression tests. Live WoW verification is pending; see [TEST_PLAN.md](TEST_PLAN.md). It has not been published as a public release or notarized.

## Controls

| Action | Control |
| --- | --- |
| Restore visibility now | **Option-Command-C**, or left-click the menu-bar icon |
| Open settings | Right-click or Control-click the menu-bar icon |
| Pause all repairs and hide the fallback | **Pause KeepCursor** in the menu |
| Select pointer appearance | **Cursor Overlay Style** and **Cursor Color** |
| Keep a larger cursor | **Keep cursor size** and its slider |

The restore shortcut respects pause, current game focus, and held mouse buttons. Settings do not automatically bring a game to the front.

## Download

Published, notarized builds are available from [GitHub Releases](https://github.com/danielalanbates/keepcursor/releases/latest). The 2.3.0b1 beta source is being validated before a new public release. Do not treat an older release as containing this fix.

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

The helper does not post mouse events, install an event tap, accumulate virtual pointer deltas, warp the cursor, or change mouse association. Overlay windows ignore mouse events. Appearance changes invalidate the view immediately.

[Apple's CGDisplayShowCursor documentation](https://developer.apple.com/documentation/coregraphics/cgdisplayshowcursor(_:)) explains the cursor hide count and foreground-app limitation. The optional SkyLight visibility and cursor-size APIs are private and may be unavailable on future macOS versions; missing visibility queries fail toward quiet behavior rather than repeated repairs.

## License

All rights reserved. Copyright (c) 2026 Bates LLC / Daniel Bates. See [LICENSE](LICENSE) for the existing PolyForm Noncommercial terms and the commercial revenue-sharing rider.
