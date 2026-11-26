-- KeepCursor (WoW side). All rights reserved. Copyright (c) 2026 Bates LLC / Daniel Bates.
--
-- On macOS, if WoW leaves camera mode while it is in the background, the OS
-- keeps the pointer captured: the gauntlet disappears and the pointer will not
-- move, while WoW thinks it is not in mouselook. Starting mouselook and stopping
-- it on the next frame, while WoW is in front, makes the client release the
-- capture properly (the same reset CombatMode ships for this bug, PR #179).
--
-- /kc sends that reset. Detection only arms right after a camera turn or drag
-- ends, and disarms the moment the pointer moves, so slow mouse moves and
-- background movement cannot trigger it. By default a detection prints a hint;
-- `/kc auto` lets it send the reset itself (MouselookStart briefly turns the
-- character to face the camera, so that is opt-in until proven on a real freeze).

KeepCursorDB = KeepCursorDB or {}
local db

BINDING_HEADER_KEEPCURSOR = "KeepCursor"
BINDING_NAME_KEEPCURSOR_UNLOCK = "Unlock frozen mouse pointer"
BINDING_NAME_KEEPCURSOR_MACUNLOCK = "Unlock (pressed by the KeepCursor Mac app)"

-- The KeepCursor Mac app presses this when it sees WoW holding the pointer
-- captured with every button up. Bound automatically, only if both the action
-- and the key are free; an existing binding is never replaced.
KEEPCURSOR_MAC_KEY = "ALT-CTRL-SHIFT-F12"

local PREFIX = "|cffffd11aKeepCursor:|r "
local SETTLE = 0.15                 -- after release, let the client restore the pointer
local STALL_SECONDS = 0.4           -- frozen pointer with real movement before acting
local STALL_SECONDS_MOUSELOOK = 1.0 -- stuck mouselook with no button held
local STALL_FRAMES = 12             -- one long hitch frame can never satisfy the wait
local STALL_DISTANCE = 20           -- accumulated GetCursorDelta movement
local GAP_RESET = 0.2               -- a pause in movement restarts the count
local AUTO_COOLDOWN = 5             -- doubles after each reset that did not free the pointer
local HINT_COOLDOWN = 30
local VERIFY_WINDOW = 2

local armed, armAt, ax, ay, wasHeld = false, 0, 0, 0, false
local stallTime, stallDist, stallFrames, stallMode, lastMotion = 0, 0, 0, nil, -math.huge
local lastAuto, lastHint, miss = -math.huge, -math.huge, 0
local loading = false
local verifyUntil, verifySource, verifyX, verifyY

local function Print(msg) DEFAULT_CHAT_FRAME:AddMessage(PREFIX .. msg) end

local function Log(event)
	db.log = db.log or {}
	table.insert(db.log, date("%Y-%m-%d %H:%M:%S") .. " " .. event)
	while #db.log > 30 do table.remove(db.log, 1) end
end

local function AnyButtonDown()
	return IsMouseButtonDown("LeftButton") or IsMouseButtonDown("RightButton")
		or IsMouseButtonDown("MiddleButton") or IsMouseButtonDown("Button4")
		or IsMouseButtonDown("Button5")
end

local function KeyHeld(binding)
	if not binding or not IsKeyDown then return false end
	return IsKeyDown(binding:match("^.*%-(.+)$") or binding) and true or false
end

local function SteerKeyDown()
	local k1, k2 = GetBindingKey("MOVEANDSTEER")
	return KeyHeld(k1) or KeyHeld(k2)
end

local function Busy()
	return loading or (SpellIsTargeting and SpellIsTargeting()) or (GetCursorInfo and GetCursorInfo() ~= nil)
		or (CinematicFrame and CinematicFrame:IsShown()) or (MovieFrame and MovieFrame:IsShown())
end

local function AtScreenEdge(x, y)
	local scale = UIParent:GetEffectiveScale()
	local w, h = GetScreenWidth() * scale, GetScreenHeight() * scale
	return x <= 2 or y <= 2 or x >= w - 2 or y >= h - 2
end

local function ResetStall(mode)
	stallTime, stallDist, stallFrames, stallMode = 0, 0, 0, mode
end

function KeepCursor_Unlock(source)
	if not db then return end
	source = source or "manual"
	MouselookStart()
	C_Timer.After(0, function() MouselookStop() end)
	db.stats[source] = (db.stats[source] or 0) + 1
	verifyUntil, verifySource = GetTime() + VERIFY_WINDOW, source
	verifyX, verifyY = GetCursorPosition()
	Log(source .. " unlock")
	if source ~= "auto" and source ~= "mac" then Print("pointer reset sent.") end
end

-- Called by the Mac app's hidden key. WoW knows when mouselook is intentional
-- (a held button, a steer key, a combat-mode addon), so it is left alone then:
-- only the proven bug (pointer captured while WoW is NOT mouselooking) is reset.
function KeepCursor_MacUnlock()
	if not db then return end
	if IsMouselooking() or AnyButtonDown() or Busy() then
		db.stats.mac_ignored = (db.stats.mac_ignored or 0) + 1
		Log("mac unlock ignored (mouselook/button/busy)")
		return
	end
	KeepCursor_Unlock("mac")
end

local bindPending = false
local function EnsureMacBinding()
	if not (GetBindingKey and SetBinding and SaveBindings and GetCurrentBindingSet) then return end
	if GetBindingKey("KEEPCURSOR_MACUNLOCK") then bindPending = false; return end
	if InCombatLockdown and InCombatLockdown() then bindPending = true; return end
	bindPending = false
	local existing = GetBindingAction and GetBindingAction(KEEPCURSOR_MAC_KEY) or ""
	if existing ~= "" and existing ~= "KEEPCURSOR_MACUNLOCK" then
		if not db.bindConflictLogged then
			db.bindConflictLogged = true
			Log(KEEPCURSOR_MAC_KEY .. " already bound to " .. existing .. "; Mac auto-unlock key not set")
			Print(KEEPCURSOR_MAC_KEY .. " is already used by " .. existing .. ", so the Mac app cannot auto-unlock. /kc still works.")
		end
		return
	end
	if SetBinding(KEEPCURSOR_MAC_KEY, "KEEPCURSOR_MACUNLOCK") then
		SaveBindings(GetCurrentBindingSet())
		Log("bound " .. KEEPCURSOR_MAC_KEY .. " for the Mac app")
	end
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("LOADING_SCREEN_ENABLED")
frame:RegisterEvent("LOADING_SCREEN_DISABLED")
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("PLAYER_REGEN_ENABLED")
frame:SetScript("OnEvent", function(self, event, name)
	if event == "PLAYER_LOGIN" then if db then EnsureMacBinding() end; return end
	if event == "PLAYER_REGEN_ENABLED" then if db and bindPending then EnsureMacBinding() end; return end
	if event == "LOADING_SCREEN_ENABLED" then loading = true; armed = false; return end
	if event == "LOADING_SCREEN_DISABLED" then loading = false; armed = false; return end
	if name ~= "KeepCursor" then return end
	self:UnregisterEvent("ADDON_LOADED")
	db = KeepCursorDB
	db.stats = db.stats or {}
	if db.auto == nil then db.auto = false end
	if not db.welcomed then
		db.welcomed = true
		Print("loaded. If the gauntlet vanishes and the mouse is frozen, type /kc (or bind a key: Key Bindings > AddOns > KeepCursor).")
	end
end)

frame:SetScript("OnUpdate", function(_, elapsed)
	if not db then return end
	local now = GetTime()
	local x, y = GetCursorPosition()

	if verifyUntil then
		if math.abs(x - verifyX) > 1 or math.abs(y - verifyY) > 1 then
			db.stats[verifySource .. "_freed"] = (db.stats[verifySource .. "_freed"] or 0) + 1
			Log(verifySource .. " unlock: pointer moving again")
			if verifySource == "auto" then miss = 0 end
			if verifySource == "auto" or verifySource == "mac" then Print("mouse was frozen; unlocked it.") end
			verifyUntil = nil
		elseif now > verifyUntil then
			Log(verifySource .. " unlock: pointer did not move within " .. VERIFY_WINDOW .. "s")
			if verifySource == "auto" then miss = math.min(miss + 1, 4) end
			verifyUntil = nil
		end
	end

	-- Arm only when a camera turn / button hold ends; disarm once the pointer moves.
	local looking = IsMouselooking()
	local buttons = AnyButtonDown()
	local held = looking or buttons
	if held then
		armed = false
	elseif wasHeld then
		armed, armAt, ax, ay = true, now, x, y
	end
	wasHeld = held
	if armed then
		if now - armAt < SETTLE then
			ax, ay = x, y
		elseif math.abs(x - ax) > 1 or math.abs(y - ay) > 1 then
			armed = false
		end
	end

	-- Mode "a": pointer captured though WoW is not in mouselook.
	-- Mode "b": WoW stuck in mouselook with no mouse button or steer key held.
	local mode
	if not Busy() then
		if looking then
			if not buttons and not SteerKeyDown() then mode = "b" end
		elseif armed and now - armAt >= SETTLE and not AtScreenEdge(x, y) then
			mode = "a"
		end
	end
	if mode ~= stallMode then ResetStall(mode) end
	if not mode or not GetCursorDelta then return end

	local dx, dy = GetCursorDelta()
	local delta = math.abs(dx or 0) + math.abs(dy or 0)
	if now - lastMotion > GAP_RESET then ResetStall(mode) end
	if delta == 0 then return end
	lastMotion = now
	stallTime = stallTime + math.min(elapsed, 1 / 30)
	stallFrames = stallFrames + 1
	stallDist = stallDist + delta
	local needed = mode == "b" and STALL_SECONDS_MOUSELOOK or STALL_SECONDS
	if stallTime < needed or stallFrames < STALL_FRAMES or stallDist < STALL_DISTANCE then return end
	ResetStall(mode)

	if db.auto then
		if now - lastAuto < math.min(AUTO_COOLDOWN * 2 ^ miss, 60) then return end
		lastAuto = now
		Log("detected frozen pointer (mode " .. mode .. "), auto reset")
		KeepCursor_Unlock("auto")
	elseif now - lastHint >= HINT_COOLDOWN then
		lastHint = now
		db.stats.detected = (db.stats.detected or 0) + 1
		Log("detected frozen pointer (mode " .. mode .. "), hint shown")
		Print("your mouse looks frozen. Type /kc (or press your KeepCursor key) to unlock it.")
	end
end)

SLASH_KEEPCURSOR1 = "/kc"
SLASH_KEEPCURSOR2 = "/keepcursor"
SlashCmdList.KEEPCURSOR = function(msg)
	msg = strlower(strtrim(msg or ""))
	if msg == "bind" then
		db.bindConflictLogged = nil
		EnsureMacBinding()
		Print("Mac unlock key: " .. (GetBindingKey("KEEPCURSOR_MACUNLOCK") or "not bound"))
	elseif msg == "auto" then
		db.auto = not db.auto
		Print("auto-unlock " .. (db.auto and "on: a detected freeze is reset automatically." or "off: a detected freeze prints a hint."))
	elseif msg == "stats" then
		local s = db.stats
		Print(string.format("detected %d | manual %d (freed %d) | key %d (freed %d) | mac %d (freed %d, ignored %d) | auto %d (freed %d) | auto-unlock %s | mac key %s",
			s.detected or 0, s.manual or 0, s.manual_freed or 0, s.key or 0, s.key_freed or 0,
			s.mac or 0, s.mac_freed or 0, s.mac_ignored or 0,
			s.auto or 0, s.auto_freed or 0, db.auto and "on" or "off",
			GetBindingKey("KEEPCURSOR_MACUNLOCK") or "unbound"))
	else
		KeepCursor_Unlock("manual")
	end
end
