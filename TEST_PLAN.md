# KeepCursor 2.3.0b1 verification

## Completed without GUI control

- [x] Optimized native Apple Silicon build succeeds with the Xcode command-line tools.
- [x] Input safety policy regression executable passes: right/both/other-button holds, release settling, retry interval, visible cursor, pause, focus loss, manual restore, failed final input check, and overlay suppression.
- [x] `codesign --verify --deep --strict` passes for the build and installed beta.
- [x] Installed executable matches the validated build; previous app archived before replacement.
- [x] Source review confirms no mouse association changes, warps, input posting, virtual pointer deltas, event taps, or global mouse monitors.
- [x] Independent source review covers delayed callback cancellation, live input recheck, arrow hotspot, and appearance repainting.

## Live WoW checks: pending

Use one KeepCursor instance. These are manual checks during normal play; do not automate game input or repeatedly launch the app.

| Scenario | Expected behavior | Result |
| --- | --- | --- |
| Move the mouse with no buttons held | Fallback arrow follows the actual pointer; clicks land at its hotspot | Pending |
| Hold right button and move | Camera turns normally; overlay hides; no pointer warp | Pending |
| Hold left button, then both buttons | Normal game behavior and movement; overlay stays hidden | Pending |
| Release both buttons | Normal game input returns immediately; overlay returns at actual pointer position | Pending |
| Command-Tab away and back | Hidden native cursor receives a visibility-only repair after the release grace period | Pending |
| Switch away before a delayed repair | No repair affects the other application | Pending |
| Pause KeepCursor before a delayed repair | Fallback hides and repairs stop | Pending |
| Option-Command-C | Repairs visibility only while target is frontmost, unpaused, with no held buttons | Pending |
| Change style/color | Appearance repaints immediately, including when mouse buttons remain released | Pending |
| Keep a saved ring preference | Existing preference remains selected; new installations default to arrow | Pending |

A hidden cursor is different from stuck game input capture. If the real pointer is frozen even after all buttons are released, this beta intentionally avoids reconnecting mouse input or inventing a separate click position. Switch away and back and release both buttons normally. Record such cases before considering further changes.

## Release gate and future work

Keep the installed `.app` as the local beta. Publish a notarized public release only after the live checks pass. Record macOS/WoW versions and observed results without private account data.

If visibility-only repair is insufficient, first collect read-only evidence of visibility, actual pointer movement, focus, and button state. Investigate a game-supported reset or user-requested recovery. Do not reintroduce periodic association changes, cursor warps, or synthetic button releases as an automatic watchdog.
