-- Vehicle Cams: tiny helpers usable from both Lua states (window card and game script).
-- (State is NOT shared between the two; they talk by events. See vc_main.script.lua.)
local M = {}

function M.log(msg)
	pcall(print, "[VehicleCams] " .. tostring(msg))
end

-- Allowed ranges (the UI sliders and the loader/clamp use the same table).
-- pitch and yaw are stored in DEGREES in the profile; the camera script converts to radians.
M.RANGES = {
	sway  = { min = 0.3, max = 4.3, step = 0.01 }, -- seconds of lag; below 0.3 the camera snaps in turns (user-tested), so 0.3 is the floor
	dist  = { min = 16, max = 300, step = 1 },     -- metres from the vehicle (the game's follow camera cannot go closer than ~15.85 m)
	pitch = { min = 2,  max = 85,  step = 1 },     -- degrees above the horizon (the game's follow camera will not go flatter than ~1.7 deg)
	yaw   = { min = -180, max = 180, step = 1 },   -- degrees away from "straight behind"
}

-- out-of-the-box view (set by the author after play-testing): tight and low, 0.5 s lag (= 5 % on the Looseness slider)
M.DEFAULT = { sway = 0.5, dist = 16, pitch = 2, yaw = 0 }

function M.clamp(v, lo, hi)
	if v < lo then return lo elseif v > hi then return hi end
	return v
end

-- returns a clean profile table from anything (bad values fall back to defaults)
function M.sanitize(p)
	local out = {}
	for k, r in pairs(M.RANGES) do
		local v = type(p) == "table" and tonumber(p[k]) or nil
		if v ~= v then v = nil end   -- NaN
		if v == nil then v = M.DEFAULT[k] end
		out[k] = M.clamp(v, r.min, r.max)
	end
	return out
end

return M
