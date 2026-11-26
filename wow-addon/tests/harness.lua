date = os.date
local T, cx, cy, ddx, ddy = 0, 500, 400, 0, 0
local looking, buttons, cine, steerKey, cursorItem = false, {}, false, nil, nil
local calls, prints, timers = {}, {}, {}
function GetTime() return T end
function GetCursorPosition() return cx, cy end
function GetCursorDelta() return ddx, ddy end
function IsMouselooking() return looking end
function IsMouseButtonDown(b) return buttons[b] or false end
function IsKeyDown(k) return steerKey ~= nil and k == steerKey end
local binds = { ["ALT-CTRL-SHIFT-F12"] = nil }
local saved, combat = 0, false
function GetBindingKey(a) if a == "MOVEANDSTEER" then return "SHIFT-E" end; for k, v in pairs(binds) do if v == a then return k end end end
function GetBindingAction(k) return binds[k] or "" end
function SetBinding(k, a) binds[k] = a; return true end
function SaveBindings() saved = saved + 1 end
function GetCurrentBindingSet() return 1 end
function InCombatLockdown() return combat end
function SpellIsTargeting() return false end
function GetCursorInfo() return cursorItem end
function MouselookStart() table.insert(calls, "start"); looking = true end
function MouselookStop() table.insert(calls, "stop"); looking = false end
C_Timer = { After = function(_, f) table.insert(timers, f) end }
UIParent = { GetEffectiveScale = function() return 1 end }
function GetScreenWidth() return 1229 end
function GetScreenHeight() return 768 end
CinematicFrame = { IsShown = function() return cine end }
DEFAULT_CHAT_FRAME = { AddMessage = function(_, m) table.insert(prints, m) end }
SlashCmdList = {}
strlower, strtrim = string.lower, function(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end
local frame
function CreateFrame() frame = { scripts = {}, RegisterEvent = function() end, UnregisterEvent = function() end,
  SetScript = function(self, k, f) self.scripts[k] = f end }; return frame end
dofile(arg[1])
frame.scripts.OnEvent(frame, "ADDON_LOADED", "KeepCursor")
-- 0 auto-bind: in combat defers, after combat binds the free key once and saves
combat = true; frame.scripts.OnEvent(frame, "PLAYER_LOGIN")
assert(binds["ALT-CTRL-SHIFT-F12"] == nil and saved == 0, "no bind in combat")
combat = false; frame.scripts.OnEvent(frame, "PLAYER_REGEN_ENABLED")
assert(binds["ALT-CTRL-SHIFT-F12"] == "KEEPCURSOR_MACUNLOCK" and saved == 1, "bound after combat")
frame.scripts.OnEvent(frame, "PLAYER_LOGIN"); assert(saved == 1, "idempotent")
print("PASS auto-bind ALT-CTRL-SHIFT-F12 (deferred out of combat, idempotent)")
-- 0b never steal an existing binding
binds["ALT-CTRL-SHIFT-F12"] = "TOGGLEWORLDMAP"; frame.scripts.OnEvent(frame, "PLAYER_LOGIN")
assert(binds["ALT-CTRL-SHIFT-F12"] == "TOGGLEWORLDMAP" and saved == 1, "existing binding kept")
print("PASS existing binding is never replaced")
binds["ALT-CTRL-SHIFT-F12"] = "KEEPCURSOR_MACUNLOCK"
local dt = 1/60
local function step(d) T = T + d; local ts = timers; timers = {}; for _, t in ipairs(ts) do t() end; frame.scripts.OnUpdate(frame, d) end
local function run(sec, f) for _ = 1, math.floor(sec / dt + 0.5) do if f then f() end; step(dt) end end
local function hints() local n = 0; for _, p in ipairs(prints) do if p:match("looks frozen") then n = n + 1 end end; return n end
local function check(name, cond) print((cond and "PASS " or "FAIL ") .. name .. "  calls=" .. table.concat(calls, ",") .. " hints=" .. hints()); if not cond then os.exit(1) end end
local function clear() calls = {}; prints = {}; ddx, ddy = 0, 0 end
local function camturn(btn) buttons[btn] = true; if btn == "RightButton" then looking = true end; run(0.5, function() ddx = 5 end); buttons[btn] = nil; looking = false; ddx = 0 end
local function later(s) T = T + s end

-- 1 normal movement only
clear(); run(2, function() ddx = 3; cx = cx + 3 end); check("normal movement: nothing", #calls == 0 and hints() == 0)
-- 2 slow retina-speed movement, pointer creeping < 0.5/frame, no prior hold (review risk 1)
clear(); run(3, function() ddx = 0.5; cx = cx + 0.3 end); check("slow creep, not armed: nothing", hints() == 0)
-- 3 frozen pointer with deltas but never armed (background / outside window, review risk 2)
clear(); run(3, function() ddx = 6 end); check("frozen but not armed: nothing", hints() == 0)
-- 4 right-drag, release, pointer follows mouse again: nothing
clear(); camturn("RightButton"); run(1, function() ddx = 4; cx = cx + 4 end); check("normal release: nothing", hints() == 0)
-- 5 right-drag, release, then slow creep (moves >1 over time): disarms, nothing
clear(); later(40); camturn("RightButton"); run(2, function() ddx = 0.5; cx = cx + 0.3 end); check("release + slow creep: disarmed", hints() == 0)
-- 6 right-drag, release, pointer FROZEN with deltas: hint (default auto off), no reset sent
clear(); later(40); camturn("RightButton"); run(0.5, function() ddx = 4 end); check("stuck after release: not before settle+0.4s", hints() == 0); run(0.2, function() ddx = 4 end); check("stuck after release: one hint, no reset", hints() == 1 and #calls == 0)
-- 7 hint cooldown 30s
clear(); run(5, function() ddx = 4 end); check("hint cooldown", hints() == 0)
-- 8 hitch: one 0.6s frame with big delta after arming (review risk 3)
clear(); later(40); camturn("LeftButton"); step(0.2); ddx = 40; step(0.6); ddx = 0; step(dt); check("single hitch frame: nothing", hints() == 0)
-- 9 left-drag then frozen at screen edge: nothing
clear(); later(40); cx = 1228; camturn("LeftButton"); run(1, function() ddx = 4 end); cx = 500; check("frozen at edge: nothing", hints() == 0)
-- 10 item on cursor: nothing
clear(); later(40); cursorItem = "item"; camturn("LeftButton"); run(1, function() ddx = 4 end); cursorItem = nil; check("item on cursor: nothing", hints() == 0)
-- 11 loading screen: nothing
clear(); later(40); camturn("LeftButton"); frame.scripts.OnEvent(frame, "LOADING_SCREEN_ENABLED"); run(1, function() ddx = 4 end); frame.scripts.OnEvent(frame, "LOADING_SCREEN_DISABLED"); check("loading screen: nothing", hints() == 0)
-- 12 stuck mouselook with no button (mode b): hint after >= 1s
clear(); later(40); looking = true; run(0.8, function() ddx = 4 end); check("mode b not before 1s", hints() == 0)
run(0.4, function() ddx = 4 end); looking = false; check("mode b hint", hints() == 1)
-- 13 steer key held (SHIFT-E -> E): nothing
clear(); later(40); looking = true; steerKey = "E"; run(2, function() ddx = 4 end); steerKey = nil; looking = false; check("steer key held: nothing", hints() == 0)
-- 14 auto mode: stuck after release -> reset; reset frees -> message
clear(); later(40); SlashCmdList.KEEPCURSOR("auto"); camturn("RightButton"); run(0.7, function() ddx = 4 end)
check("auto: reset sent", #calls == 2 and calls[1] == "start" and calls[2] == "stop")
run(0.2, function() ddx = 4; cx = cx + 4 end); check("auto: freed message", prints[#prints]:match("unlocked"))
-- 15 auto backoff: resets that do not free double the cooldown (5,10,20...)
clear(); later(40); camturn("RightButton"); local fires = {}
for _ = 1, 60 * 40 do ddx = 4; local n = #calls; step(dt); if #calls > n and calls[#calls] == "start" then fires[#fires+1] = T end end
local gaps = {}; for i = 2, #fires do gaps[#gaps+1] = string.format("%.1f", fires[i] - fires[i-1]) end
print("   auto fire gaps while still frozen: " .. table.concat(gaps, ", "))
check("auto backoff grows", #fires >= 3 and (fires[3] - fires[2]) > (fires[2] - fires[1]) + 1)
SlashCmdList.KEEPCURSOR("auto")
-- 16 manual /kc
clear(); later(40); SlashCmdList.KEEPCURSOR(""); step(dt); step(dt); check("manual /kc: start then stop", #calls == 2)
SlashCmdList.KEEPCURSOR("stats"); print("   " .. prints[#prints])
-- mac key while NOT mouselooking (the proven bug): reset sent, quiet until freed
clear(); later(40); KeepCursor_MacUnlock(); step(dt); step(dt); check("mac key: start then stop", #calls == 2 and calls[1] == "start")
run(0.1, function() cx = cx + 3 end); check("mac key: freed message", prints[#prints]:match("unlocked"))
-- mac key during intentional mouselook / held button: ignored
clear(); steerKey = "E"; looking = true; KeepCursor_MacUnlock(); step(dt); KeepCursor_MacUnlock(); step(dt); looking = false; steerKey = nil; check("mac key ignored while steer key held", #calls == 0)
clear(); later(40); looking = true; KeepCursor_MacUnlock(); step(dt); check("stuck mouselook: first mac key deferred", #calls == 0)
later(12); KeepCursor_MacUnlock(); step(dt); step(dt); looking = false; check("stuck mouselook: repeat mac key resets", #calls >= 1 and calls[#calls] == "stop")
clear(); later(400); looking = true; KeepCursor_MacUnlock(); step(dt); looking = false; check("old deferral expired: deferred again", #calls == 0)
clear(); buttons.RightButton = true; KeepCursor_MacUnlock(); step(dt); buttons.RightButton = nil; check("mac key ignored with button held", #calls == 0)
SlashCmdList.KEEPCURSOR("stats"); print("   " .. prints[#prints])
