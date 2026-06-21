# KeepCursor

**Stop World of Warcraft (and other macOS games) from losing your mouse cursor when you Command-Tab.**

A tiny, free menu-bar app for macOS. When you alt-tab out of WoW and back, the in-game cursor often vanishes — you have to wiggle the mouse, right-click, or do the awkward "hold both mouse buttons" trick to get it back. KeepCursor fixes that automatically.

![macOS 13+](https://img.shields.io/badge/macOS-13%2B-blue) ![Universal](https://img.shields.io/badge/arch-Apple%20Silicon%20%2B%20Intel-green) ![Notarized](https://img.shields.io/badge/Apple-Notarized-success)

## Download

Grab the latest **[KeepCursor.zip](https://github.com/danielalanbates/keepcursor/releases/latest)**, unzip, drag `KeepCursor.app` to `/Applications`, and open it. It's Apple-notarized, so it just runs — no Gatekeeper warnings, no right-click-to-open.

A cursor icon appears in your menu bar. That's it. WoW will keep its cursor from now on.

## Why the old fixes don't work well

The macOS cursor disappearing bug is actually three problems at once:

1. **The hide/show counter goes negative.** macOS tracks cursor visibility with a per-app counter. When WoW grabs and releases the cursor across an app switch, the counter can be driven below zero — so a single `CGDisplayShowCursor()` (what most naive tools do) isn't enough to bring it back.
2. **The mouse gets "disassociated" from the cursor** after a camera grab.
3. **The hardware cursor sprite isn't repainted**, so even a balanced counter shows nothing until the cursor physically moves.

A dumb once-per-second `CGDisplayShowCursor` loop misses all three. KeepCursor fixes all three, **exactly on the alt-tab event**:

- Calls `CGDisplayShowCursor` repeatedly to unwind the negative counter.
- Calls `CGAssociateMouseAndMouseCursorPosition(true)` to re-link the mouse.
- Nudges the cursor 1px and back to force WindowServer to repaint it.

It hooks `NSWorkspace.didActivateApplicationNotification`, so the fix fires the instant WoW comes back to the front (plus a light safety re-check while WoW is frontmost, to catch the in-game-alert case).

## Features

- **Zero config** — install, open, done.
- **Only touches the cursor while a game is frontmost** — leaves your normal cursor and accessibility settings completely alone the rest of the time.
- **Global hotkey ⌥⌘C** — force-restore the cursor any time.
- **Launch at login** toggle (built in, via `SMAppService`).
- **"Watch all games"** mode for non-WoW full-screen games.
- **No special permissions** — no Accessibility, no Input Monitoring.
- Universal binary (Apple Silicon + Intel), Apple-notarized.

## Build from source

```bash
git clone https://github.com/danielalanbates/keepcursor
cd keepcursor
./build.sh                 # produces /tmp/keepcursor-build/KeepCursor.app (ad-hoc signed)
# or, for a notarized release build (requires a Developer ID + notary profile):
./release.sh
```

Requires the Xcode command-line tools (`swiftc`). Single Swift file, no dependencies.

## License

MIT — see [LICENSE](LICENSE). Made by [Bates LLC](https://batesai.org).
