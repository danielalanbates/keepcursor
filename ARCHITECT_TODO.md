# Current update — 2026-10-15

2.3.0b2 supersedes the historical implementation notes below. The cursor visibility goal remains active. The first visibility-only beta did not repair Daniel's frozen in-game pointer. The current beta adds a single explicit reconnect and a passive physical-motion stall detector, guarded by focus, released-button settling, per-episode consumption, and a minimum retry interval. It keeps visibility repair and a native-position fallback. The previous continuous watchdog and mouse-release warps interfered with WoW input.

See `README.md`, `Sources/CursorRecoveryPolicy.swift`, and `TEST_PLAN.md` for the current design, regression checks, limitations, live verification gate, and next investigation paths. The local beta is compiled, policy tested, independently reviewed, and signature verified. Actual API acceptance and live WoW pointer/button behavior require verification; foreground restrictions may prevent a background helper from repairing game capture. No new public release was made because live WoW checks remain pending. Retired source is preserved in Git history at `7815333`.

---

# ARCHITECT_TODO — keep-cursor
_Head Architect review 2026-07-02. Full context: `Code/_ARCHITECT_REVIEW_2026-07-02/`._
_Worker rules: NEVER delete source code (only venv/node_modules/target/.build/__pycache__/dist and compiled artifacts). Move whole projects to `Code/Archived_Projects/<name>/` with WHY_ARCHIVED.md. Before moving a folder, run: grep -rl "keep-cursor" ~/Library/LaunchAgents/ "$HOME/Library/Application Support/BatesAI/" — if anything matches, STOP and report. Secrets (*.p8, *.p12, .env, keys) go to ~/Library/Application Support/BatesAI/keys/ chmod 600. Do ONE step at a time; verify; report._

**Verdict:** ACTIVE — needs live verification
**What this is:** Menu-bar app fixing WoW cursor loss on alt-tab. Notarized, on GitHub + batesai.org. Efficacy vs live WoW UNVERIFIED.

## Steps
1. Add a restore-counter to the menu bar ('restored 14× this session'; increment where the restore burst fires). Build/type-check only — do NOT install or relaunch.
2. Delete git-hook *.sample files and the stray .zip.
3. Write `TEST_PLAN.md`: exact manual steps for Daniel to verify in WoW using the new counter.

## CODE REVIEW FINDINGS (2026-07-02, actual source read — Sources/main.swift, 488 lines)
Quality: HIGH. Well-commented, correct use of SkyLight private API with graceful availability checks.
1. **Potential gameplay issue:** the 1s safety timer calls `restoreBurst()` whenever WoW is frontmost, and every burst warps the cursor 1px and back (`CGWarpMouseCursorPosition`). While actually playing, that's a warp every second — possible micro-jitter/aim interference and could look like input automation. Fix idea: in the timer path, skip the warp (steps 1–2 only) or skip the whole burst if a mouse button is down (`CGEventSource.buttonState`). Keep the full burst for activation events + hotkey.
2. **'Watch all games' is mislabeled:** `looksLikeFullscreenGame()` only matches Blizzard/Steam bundle ids — the fullscreen heuristic described in its comment is not implemented. Either implement the fullscreen check or rename the menu item 'Watch Blizzard/Steam games'.
3. **Launch-at-login drift:** state is a UserDefaults bool + hand-written LaunchAgent plist; if the user deletes the plist the menu still shows enabled. Modern fix: `SMAppService.mainApp.register()` (macOS 13+) — also removes the hardcoded /Applications path assumption. `import ServiceManagement` is already there but unused.
4. The restore-counter task (step 1 in the TODO above) doubles as the live-WoW verification instrument — do it first.
