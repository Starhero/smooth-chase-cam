-- Vehicle Cams: card shown in the vehicle window ("Advanced Chase Control").
-- Start/stop the chase camera and edit the profile (looseness, distance, pitch, angle). The profile is ONE shared setting
-- for every vehicle and is saved to disk by vc_main.script. The card cannot move the camera itself (different Lua state):
--   card -> script : api.gui.fireGuiScriptEvent("vehicle_cams", "chase" | "stop" | "set" | "fold", {...})
--   script -> card : react event "vc_state" {profile, open, active, adjusting, stopped}
local react = ug_require("::/gui/main/react.lua")
local builtin = ug_require("::/gui/main/builtin.lua")
local content_card = ug_require("::/gui/main/content_card.tl")
local button_react_util = ug_require("::/gui/main/button_react_util.tl")
local styleutil = ug_require("::/gui/main/styleutil.tl")
local vc = ug_require("vehicle_cams_1::/vehicle_cams/vc_shared.lua")

-- Styles are built on first use, NOT when this file loads: the mod validator loads the file in a bare Lua environment
-- where styleutil.makeStyle does not work yet ("attempt to index field 'StyleSheet'"), which made validation fail.
local styleCache = nil
local function styles()
	if not styleCache then
		styleCache = {
			slider = styleutil.makeStyle { size = { 300, 24 } },
			green = styleutil.makeStyle { backgroundColor = { 0.12, 0.62, 0.22, 1.0 } },
			white = styleutil.makeStyle { color = { 1, 1, 1, 1 } },
			orange = styleutil.makeStyle { color = { 1.0, 0.72, 0.25, 1.0 } },
		}
	end
	return styleCache
end

-- Last state seen by any card in this Lua state. A card for the next vehicle starts from it, so the window does not
-- flicker back to defaults while waiting for the script's first update.
local cache = nil

local function send(name, param)
	local ok, err = pcall(function() api.gui.fireGuiScriptEvent("vehicle_cams", name, param) end)
	if not ok then vc.log("send(" .. tostring(name) .. ") ERROR: " .. tostring(err)) end
end

local function copyProfile(p)
	return { sway = p.sway, dist = p.dist, pitch = p.pitch, yaw = p.yaw }
end

local function sameProfile(a, b)
	for k in pairs(vc.RANGES) do
		if math.abs((a[k] or 0) - (b[k] or 0)) > 1e-6 then return false end
	end
	return true
end

local function newState(s, over)
	local n = { profile = s.profile, open = s.open, active = s.active, adjusting = s.adjusting, synced = s.synced, rev = s.rev, stopped = s.stopped }
	for k, v in pairs(over) do n[k] = v end
	cache = n
	return n
end

-- looseness is shown as a percentage of its allowed range (0.3 s .. 4.3 s), with the seconds next to it
local function swayToPercent(sw) local r = vc.RANGES.sway; return (sw - r.min) / (r.max - r.min) * 100 end
local function percentToSway(pc) local r = vc.RANGES.sway; return r.min + pc / 100 * (r.max - r.min) end

local VcCardContent = react.RegisterRecipe("VcCardContent", function(params)
	local e = params.vehicleEntity
	local st = react.useState(cache or { profile = copyProfile(vc.DEFAULT), open = false, active = -1, adjusting = false, synced = false, rev = 0, stopped = nil })

	react.onEvent("vc_state", function(_id, value)
		pcall(function()
			if type(value) ~= "table" or type(value.profile) ~= "table" then return end
			local s = st:old()
			local over = { active = value.active or -1, adjusting = value.adjusting == true, synced = true,
				stopped = type(value.stopped) == "table" and value.stopped or nil }
			-- Take the script's values on first contact and while the mouse is changing the view (so the sliders follow).
			-- At any other time the card's own values rule, so a slider being dragged never jumps back.
			if not s.synced then over.open = (value.open == true) end
			if not s.synced or value.adjusting or s.adjusting then
				local incoming = vc.sanitize(value.profile)
				if not sameProfile(incoming, s.profile) then over.profile = incoming; over.rev = s.rev + 1 end
			end
			st:set(newState(s, over))
		end)
	end)

	local s = st:old()
	local P = s.profile
	local isActive = (s.active == e)

	-- one slider changed: update our copy, tell the script. Ignore calls that change nothing
	-- (a slider may report its initial value when it is created; that must never overwrite the saved profile).
	local function change(key, v)
		pcall(function()
			local cur = st:old()
			if not cur.synced then return end
			local np = copyProfile(cur.profile)
			np[key] = vc.clamp(v, vc.RANGES[key].min, vc.RANGES[key].max)
			if math.abs(np[key] - cur.profile[key]) < 1e-6 then return end
			st:set(newState(cur, { profile = np }))
			send("set", np)
		end)
	end

	-- slider values are whole numbers (step 1, wheel notch 1), converted to/from the profile value
	local function sliderRow(key, label, toSlider, fromSlider, maxSlider, tip)
		return builtin.BoxLayout{
			orientation = builtin.type.Orientation.Vertical,
			children = {
				builtin.TextView{ meta = { class = "font-scale-body" }, text = label },
				builtin.Slider{
					meta = { localKey = "vc-" .. key .. "-" .. tostring(s.rev), tooltip = tip, styleSheet = styles().slider },
					min = 0, max = maxSlider, step = 1, pageStep = 1,
					horizontal = true,
					value = math.floor(toSlider(P[key]) + 0.5),
					onValueChange = function(v) change(key, fromSlider(tonumber(v) or 0)) end,
				},
			},
		}
	end

	-- line 1: one short line
	local statusText
	if isActive then
		statusText = s.adjusting and "Saving your view..." or "ON - orbit with the middle mouse to change your view."
	elseif s.active ~= -1 then
		statusText = "Chase camera is on for another vehicle."
	else
		statusText = "Follows this vehicle from behind."
	end

	local children = { builtin.TextView{ meta = { class = "font-scale-body" }, text = statusText } }

	-- why the camera switched itself off (only on the vehicle it was following)
	if not isActive and s.stopped and s.stopped.e == e and type(s.stopped.text) == "string" then
		children[#children + 1] = builtin.TextView{ meta = { styleSheet = styles().orange }, text = s.stopped.text }
	end

	-- line 2: green "ON" button while the camera is under our control, plain button otherwise; Reset
	children[#children + 1] = builtin.BoxLayout{
		orientation = builtin.type.Orientation.Horizontal,
		children = {
			isActive
				and builtin.Button{
					meta = { tooltip = "The chase camera is ON (green). Click to return to the game's normal camera.", styleSheet = styles().green },
					content = builtin.TextView{ meta = { styleSheet = styles().white }, text = "Camera ON - click to stop" },
					onClick = function() send("stop", { entity = e }) end,
				}
				or button_react_util.makeTextButton("primary", "Chase camera", function() send("chase", { entity = e }) end,
					"Follow this vehicle from behind with the advanced settings.", false),
			button_react_util.makeTextButton("primary", "Reset", function()
				pcall(function()
					local cur = st:old()
					st:set(newState(cur, { profile = copyProfile(vc.DEFAULT), adjusting = false, rev = cur.rev + 1 }))
					send("set", copyProfile(vc.DEFAULT))
				end)
			end, "Back to the default settings.", false),
		},
	}

	-- fold-out section; open/closed is remembered for every vehicle and between sessions (stored by the script)
	children[#children + 1] = button_react_util.makeTextButton("primary",
		(s.open and "[-] " or "[+] ") .. "Advanced chase control",
		function()
			pcall(function()
				local cur = st:old()
				st:set(newState(cur, { open = not cur.open }))
				send("fold", { open = not cur.open })
			end)
		end, "Show or hide the chase camera settings.", false)

	if s.open then
		local R = vc.RANGES
		children[#children + 1] = sliderRow("sway",
			string.format("Looseness: %d%% (%.1f s)", math.floor(swayToPercent(P.sway) + 0.5), P.sway),
			swayToPercent, percentToSway, 100,
			"How much the camera lags behind the vehicle's heading. Low = tight, high = loose and gradual.")
		children[#children + 1] = sliderRow("dist", string.format("Distance: %d m", math.floor(P.dist + 0.5)),
			function(v) return v - R.dist.min end, function(sv) return sv + R.dist.min end, R.dist.max - R.dist.min,
			"Distance from the vehicle (use this to zoom: the mouse wheel does not work while the camera is on).")
		children[#children + 1] = sliderRow("pitch", string.format("Pitch: %d deg", math.floor(P.pitch + 0.5)),
			function(v) return v end, function(sv) return sv end, R.pitch.max,
			"Low = nearly level with the vehicle, high = looking down from above. The game will not go lower than 2 degrees.")
		children[#children + 1] = sliderRow("yaw", string.format("Angle: %d deg", math.floor(P.yaw + 0.5)),
			function(v) return v + 180 end, function(sv) return sv - 180 end, 360,
			"0 = straight behind. Moves the camera round to one side or the other.")

		-- quick angle buttons: set the Angle slider to a standard view (sliders are rebuilt via rev so they show the new value)
		local function setYaw(deg)
			pcall(function()
				local cur = st:old()
				if not cur.synced then return end
				local np = copyProfile(cur.profile)
				np.yaw = deg
				st:set(newState(cur, { profile = np, rev = cur.rev + 1 }))
				send("set", np)
			end)
		end
		children[#children + 1] = builtin.BoxLayout{
			orientation = builtin.type.Orientation.Horizontal,
			children = {
				button_react_util.makeTextButton("primary", "Behind", function() setYaw(0) end, "Straight behind the vehicle.", false),
				button_react_util.makeTextButton("primary", "Left", function() setYaw(-90) end, "From the vehicle's left side.", false),
				button_react_util.makeTextButton("primary", "Right", function() setYaw(90) end, "From the vehicle's right side.", false),
				button_react_util.makeTextButton("primary", "Front", function() setYaw(180) end, "In front of the vehicle, looking back at it.", false),
			},
		}
	end

	return builtin.BoxLayout{
		orientation = builtin.type.Orientation.Vertical,
		children = children,
	}
end)

local VcCardPlugin = react.RegisterPluginRecipe(
	ug_require("::/gui/entity_window/vehicle/vehicle_eow.script.tl").VehicleEowExtensionPoint, "VcCardPlugin", function(params)
	return builtin.BoxLayout{
		child = content_card.ContentCard{
			meta = { localKey = "vehicleCams" },
			title = "Advanced Chase Control",
			initialCalloutTextPermanent = "",
			recipeAndParamPermanent = content_card.makeRecipeAndParam(VcCardContent, { vehicleEntity = params.entityId }),
			hasPermanentFocusables = true,
			gameCtx = params.gameCtx,
			showOnRightSide = params.showCalloutOnRightSide,
		}
	}
end)

function data()
	return {
		VcCardPlugin = VcCardPlugin,
	}
end
