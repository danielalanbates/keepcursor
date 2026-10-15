# KeepCursor 2.3.0b2 verification

## Completed without GUI control

- [x] Optimized native Apple Silicon build succeeds with the Xcode command-line tools.
- [x] Input safety policy regression executable passes: right/both/other-button holds, release settling, retry interval, visible cursor, pause, focus loss, manual restore, failed final input check, and overlay suppression.
- [x] `codesign --verify --deep --strict` passes for the build and installed beta.
- [x] Installed executable matches the validated build; previous app archived before replacement.
- [x] Source review confirms no cursor warps, input posting, virtual pointer deltas, or event taps. The passive mouse monitor only collects stall evidence.
- [x] Guarded reconnect policy regression checks pass: explicit queued request, release settling, failed-attempt consumption, deferred live guard, focus/pause reset, single-use persistent stall, screen-edge and subpixel rejection.
- [x] Independent startup lifecycle review verifies a request survives first-target activation, binds to its PID, cancels on later focus loss/pause, and expires after 60 seconds without leaving a queued reconnect.
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
| Option-Command-C | Requests one reconnect and visibility repair after 250 ms released, with target frontmost and unpaused | Pending |
| Frozen real pointer with physical movement | One reconnect after >=3 real events, >=12 points of deltas, >=250 ms unchanged native position; no repeated repair while that stall persists | Pending |
| Explicit `--recover-pointer-once` launch | Waits for first target focus (up to 60 s), repairs once after release settling, cancels if bound target loses focus | Pending |
| Reconnect API rejected by macOS | Logs return code and consumes attempt; normal pointer observation continues | Pending |
| Change style/color | Appearance repaints immediately, including when mouse buttons remain released | Pending |
| Keep a saved ring preference | Existing preference remains selected; new installations default to arrow | Pending |

A hidden cursor is different from stuck game input capture. The beta has separate visibility-only recovery and a guarded one-shot reconnect. A native API return code of success is acceptance of the request, not proof that WoW input recovered. Verify actual pointer movement and clicks. Apple's APIs may reject or ignore an accessory helper's background reconnect, and passive monitors may receive no events in some game raw-input modes. If input remains stuck, switch away and back and release both buttons normally; record the result. A separate virtual pointer must not imply that game clicks land at invented coordinates.

## Release gate and future work

Keep the installed `.app` as the local beta. Publish a notarized public release only after the live checks pass. Record macOS/WoW versions and observed results without private account data.

If visibility-only repair is insufficient, first collect read-only evidence of visibility, actual pointer movement, focus, and button state. Investigate a game-supported reset if the guarded reconnect is rejected or ineffective. Preserve the single-attempt policy; do not reintroduce periodic association changes, cursor warps, or synthetic button releases as an automatic watchdog.
