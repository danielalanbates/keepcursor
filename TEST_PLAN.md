# KeepCursor 2.2.0 — Live WoW Verification Plan

The 2.2.0 restore counter makes efficacy visible: the menu's status line now
shows `restored N×` every time a real restore fires.

## Setup
1. Launch KeepCursor 2.2.0 (menu bar icon: cursor with rays).
2. Open the menu — status should read "Watching for WoW…", no counter yet.
3. Launch World of Warcraft. Status should flip to "Active — WoW running".

## Test 1 — alt-tab restore (the core fix)
1. In WoW, Cmd-Tab to another app, then Cmd-Tab back to WoW.
2. Expected: cursor visible immediately; menu status shows `restored 1×`
   (each switch-back counts once).

## Test 2 — no jitter while playing (the 2.2.0 fix)
1. Stay in WoW and play normally for 2–3 minutes, including sustained
   right-button camera turns and aiming.
2. Expected: NO cursor stutter or 1px hops. (2.1.0 warped the cursor every
   second while WoW was frontmost; 2.2.0 only does silent maintenance unless
   the cursor is actually lost, and never warps while a mouse button is held.)
3. The counter should NOT climb while you simply play with a visible cursor.

## Test 3 — in-game alert case (safety timer)
1. Trigger anything that hides/steals the cursor without leaving WoW
   (e.g. an OS notification popping over full-screen WoW).
2. Expected: cursor returns within ~1 s and the counter increments.

## Test 4 — manual restore
1. Press ⌥⌘C (or menu → Restore cursor now).
2. Expected: icon flashes, counter increments.

## Test 5 — cursor size pinning
1. Set the slider to 3.0×, launch/quit WoW (display-mode change).
2. Expected: cursor size stays 3.0× after the game resets the display.

## Pass criteria
Tests 1, 2, 4 pass = ship. Test 3 is best-effort (depends on reproducing the
alert). Record results here:

- [ ] Test 1: 
- [ ] Test 2: 
- [ ] Test 3: 
- [ ] Test 4: 
- [ ] Test 5: 
