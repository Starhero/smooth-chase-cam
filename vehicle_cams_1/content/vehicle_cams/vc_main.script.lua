-- Vehicle Cams: game-script side (guiUpdate every frame + guiHandleEvent for the card).
-- The vehicle-window card runs in a DIFFERENT Lua state, so card and this script talk only by events:
--   card -> here : api.gui.fireGuiScriptEvent("vehicle_cams", name, param)   (we subscribe to each name in handleEvent)
--   here -> card : api.gui.fireReactEvent("vc_state", state)
--
-- CHASE camera. The game's own follow camera (followEntity) owns the camera centre (smooth); every frame we only
-- rewrite distance / heading / pitch on top of it (verified: the game does not fight this).
-- Camera angle a looks along (-cos a, -sin a) in map coordinates (MEASURED in game), so to look along the
-- vehicle direction (dx,dy): a = atan2(-dy, -dx).
-- If the player orbits with the mouse during a chase, the change is absorbed into the profile (saved).
-- NOTE: the mouse WHEEL does not register while we control the camera (verified: the camera data never changes), so zoom is the Distance slider.
local vc = nil
do
	local ok, m = pcall(ug_require, "vehicle_cams_1::/vehicle_cams/vc_shared.lua")
	if ok and type(m) == "table" then vc = m end
end

local atan2 = math.atan2 or math.atan
local TWO_PI = 2 * math.pi
local DEG = math.pi / 180

local function log(msg) if vc then vc.log(msg) else pcall(print, "[VehicleCams] " .. tostring(msg)) end end

-- ---------------------------------------------------------------- profile + persistence
local profile = nil          -- {sway, dist, pitch(deg), yaw(deg)}; loaded lazily
local dirtySince = nil       -- time of the last unsaved change
local SAVE_DELAY = 1.0       -- s of quiet before writing the file
local saveWarned = false
local saveLogged = false

-- The game's script environment has no `io`; since game build 40420 app.saveUserdata only accepts three folders
-- (heightmaps, mod_presets, towns_industries). towns_industries is the least visible one (same choice as tf3_dashboard_export).
local DIR = "towns_industries"
local FILE = "vehicle_cams_settings"

local function loadProfile()
	local p = nil
	pcall(function()
		-- loadUserdata logs a warning for a missing file, so look first
		local names = app.getAllUserdata(DIR)
		local found = false
		for _, n in ipairs(names or {}) do
			if n == FILE or n == FILE .. ".lua" then found = true break end
		end
		if found then
			local d = app.loadUserdata(DIR, FILE)
			if type(d) == "table" then p = d end
		end
	end)
	profile = vc.sanitize(p)
	profile.open = (p ~= nil and p.open == true)     -- "Advanced chase control" section unfolded? (shared by all vehicles)
	log(string.format("profile %s: sway=%.2f dist=%.0f pitch=%.0f yaw=%.0f open=%s", p and "loaded from file" or "default (no file)",
		profile.sway, profile.dist, profile.pitch, profile.yaw, tostring(profile.open)))
end

local function saveProfile()
	local okAll, err = pcall(function()
		app.saveUserdata(DIR, FILE, { sway = profile.sway, dist = profile.dist, pitch = profile.pitch, yaw = profile.yaw, open = profile.open == true })
	end)
	if okAll then
		if not saveLogged then saveLogged = true; log("settings saved to " .. DIR .. "/" .. FILE) end
	elseif not saveWarned then
		saveWarned = true
		log("could not save settings (they will not persist this session): " .. tostring(err))
	end
end

-- ---------------------------------------------------------------- camera mode
local cam = nil              -- nil = off. { e, lastTime, a, d, p, settled, lastA, lastD, lastP, frames }
local adjustingUntil = 0     -- while now < this, the card shows "saving your camera change"
local lastPush = -1
local pushDirty = true
local diagLeft = 10          -- log lines still allowed about the game clamping/moving distance or pitch (to learn its limits)
local stopInfo = nil         -- { e = vehicle, text = why } after the camera switched itself off (shown on the card)

local ENTER_TAU = 0.6        -- s, ease-in when the mode starts (no snap)
local DP_TAU = 0.6           -- s, smoothing of distance / pitch changes made with the sliders
local GRACE_FRAMES = 20      -- frames after followEntity during which the game may still be settling

local function angDelta(a, b)
	local d = (b - a) % TWO_PI
	if d > math.pi then d = d - TWO_PI end
	return d
end

local function followedEntity()
	local ok, f = pcall(api.gui.camera.getFollowEntity)
	if ok and type(f) == "table" then return f[1] end
	return nil
end

local function pushState(now)
	pcall(function()
		api.gui.fireReactEvent("vc_state", {
			profile = { sway = profile.sway, dist = profile.dist, pitch = profile.pitch, yaw = profile.yaw },
			open = profile.open == true,
			active = cam and cam.e or -1,
			adjusting = now < adjustingUntil,
			stopped = stopInfo,
		})
	end)
	lastPush = now
	pushDirty = false
end

local function stopCam(reason, friendly)
	if cam then
		log("camera mode stopped: " .. tostring(reason))
		-- friendly = text for the card when WE did not ask for the stop (the player must see why the green light went out)
		stopInfo = friendly and { e = cam.e, text = friendly } or nil
		cam = nil
		pushDirty = true
	end
end

-- returns heading-angle, or nil+reason, or false (direction undefined: keep old heading)
local function vehicleHeading(e)
	local okE, exists = pcall(api.engine.entityExists, e)
	if not (okE and exists) then return nil, "vehicle gone" end
	local okT, tv = pcall(api.engine.getComponent, e, api.type.ComponentType.TRANSPORT_VEHICLE)
	if not (okT and tv) then return nil, "no transport component" end
	local inDepot = false
	pcall(function() inDepot = (tv.state == api.type["enum"].TransportVehicleState.IN_DEPOT) end)
	if inDepot then return nil, "vehicle in depot" end
	local okD, dir = pcall(api.engine.util.vehicle.getDirection, e)
	if not (okD and dir) then return nil, "no direction" end
	local dx, dy = dir.x or dir[1], dir.y or dir[2]
	if type(dx) ~= "number" or type(dy) ~= "number" then return nil, "bad direction" end
	if math.sqrt(dx * dx + dy * dy) < 0.05 then return false end
	return atan2(-dy, -dx)
end

local function chaseTick(now)
	local c = cam
	local dt = math.max(0, math.min(0.25, now - c.lastTime))
	c.lastTime = now
	c.frames = c.frames + 1

	local heading, why = vehicleHeading(c.e)
	if heading == nil then return stopCam(why, "Camera turned off: " .. tostring(why) .. ".") end

	-- the game must still be following OUR vehicle (Esc / another camera / panning away ends it)
	if c.frames > GRACE_FRAMES and followedEntity() ~= c.e then
		return stopCam("game no longer follows the vehicle",
			"Camera turned off: you moved the camera away, pressed Esc or picked another camera. Press Chase camera to resume.")
	end

	local cur = api.gui.camera.getCameraData()
	if c.a == nil then c.a, c.d, c.p = cur.w, cur.z, cur.q end   -- start exactly where the camera is: no jump

	-- player input (middle-mouse orbit): the camera is not where we left it.
	-- Absorb it into the profile instead of fighting it, and keep our filter state in sync so nothing snaps.
	-- This also picks up the game's own limits (it clamps what we write): the profile then holds the clamped value.
	if c.lastA and c.frames > GRACE_FRAMES then
		local dA = angDelta(c.lastA, cur.w)
		local dD = cur.z - c.lastD
		local dP = cur.q - c.lastP
		if math.abs(dA) > 1e-3 or math.abs(dD) > 0.002 or math.abs(dP) > 1e-3 then
			if diagLeft > 0 and (math.abs(dD) > 0.002 or math.abs(dP) > 1e-3) then
				diagLeft = diagLeft - 1
				log(string.format("camera moved away from what we wrote: dDist=%.4f dPitch=%.4f -> dist %.2f m, pitch %.1f deg", dD, dP, cur.z, cur.q / DEG))
			end
			c.a, c.d, c.p = cur.w, cur.z, cur.q
			local r = vc.RANGES
			profile.yaw = angDelta(0, profile.yaw * DEG + dA) / DEG
			profile.dist = vc.clamp(cur.z, r.dist.min, r.dist.max)
			profile.pitch = vc.clamp(cur.q / DEG, r.pitch.min, r.pitch.max)
			adjustingUntil = now + 1.0
			dirtySince = now
			pushDirty = true
		end
	end

	-- heading: filtered by the looseness (sway) setting; shortest-angle wrap
	if heading then
		local target = heading + profile.yaw * DEG
		local tau = profile.sway
		if not c.settled then tau = math.max(tau, ENTER_TAU) end
		if tau <= 0 then
			c.a = target
		else
			c.a = c.a + angDelta(c.a, target) * (1 - math.exp(-dt / tau))
		end
		if not c.settled and math.abs(angDelta(c.a, target)) < 0.01 then c.settled = true end
	end
	local kd = 1 - math.exp(-dt / DP_TAU)
	c.d = c.d + (profile.dist - c.d) * kd
	c.p = c.p + (profile.pitch * DEG - c.p) * kd

	api.gui.camera.setCameraData(api.type.Vec5f.new(cur.x, cur.y, c.d, c.a, c.p))
	c.lastA, c.lastD, c.lastP = c.a, c.d, c.p
end

local function guiUpdate(userParams, state, guiState)
	local ok, err = pcall(function()
		if not vc then return end
		local now = api.util.getApplicationTime()
		if not profile then loadProfile(); pushDirty = true end
		if cam then
			local okC, errC = pcall(chaseTick, now)
			if not okC then stopCam("error: " .. tostring(errC), "Camera turned off after an error (see the game log).") end
		end
		-- "saving your change" indicator ends
		if adjustingUntil > 0 and now >= adjustingUntil then adjustingUntil = 0; pushDirty = true end
		-- debounced save
		if dirtySince and now - dirtySince >= SAVE_DELAY then dirtySince = nil; saveProfile() end
		-- tell the card: on change (max 5/s) and as a 1 s heartbeat (a freshly opened card gets the profile within a second)
		if (pushDirty and now - lastPush >= 0.2) or now - lastPush >= 1.0 or lastPush < 0 then pushState(now) end
	end)
	if not ok then pcall(print, "[VehicleCams] guiUpdate error: " .. tostring(err)) end
end

local function guiHandleEvent(userParams, state, guiState, src, id, name, param)
	if id ~= "vehicle_cams" then return end
	local ok, err = pcall(function()
		if not vc then return end
		if not profile then loadProfile() end
		local now = api.util.getApplicationTime()
		if name == "stop" then
			stopCam("Stop button")
		elseif name == "set" and type(param) == "table" then
			local wasOpen = profile.open
			profile = vc.sanitize(param)
			profile.open = wasOpen
			dirtySince = now
			pushDirty = true
		elseif name == "fold" and type(param) == "table" then
			profile.open = (param.open == true)
			dirtySince = now
		elseif name == "chase" then
			local e = type(param) == "table" and param.entity or nil
			if not e then return end
			local h, why = vehicleHeading(e)
			if h == nil then log("cannot start chase: " .. tostring(why)); return end
			cam = nil
			stopInfo = nil
			-- the game's follow camera owns the centre; jump=false lets it glide there (no snap)
			api.gui.camera.followEntity(e, false)
			cam = { e = e, lastTime = now, settled = false, frames = 0 }
			pushDirty = true
			log("chase started")
		end
	end)
	if not ok then pcall(print, "[VehicleCams] guiHandleEvent error: " .. tostring(err)) end
end

-- Engine side: events only reach guiHandleEvent if the game script subscribes to their NAME (verified).
local EVENT_NAMES = { "chase", "stop", "set", "fold" }
local function handleEvent(userParams, state, src, id, name, param)
	if id == "" then
		for _, ev in ipairs(EVENT_NAMES) do pcall(function() state:subscribeToEvent(ev) end) end
	end
end

function data()
	return {
		handleEvent = handleEvent,
		guiUpdate = guiUpdate,
		guiHandleEvent = guiHandleEvent,
	}
end
