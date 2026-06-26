local selected_player = 1
local selected_sensor = 1
local selected_device = 1
local selected_focus = 1
local selected_action = 1
local action_feedback = ""

local focus_names = { "Player", "Controller", "Sensor", "Action" }
local action_names = { "charger", "enregistrer" }
local device_snapshots = {}
local snapshot = {
	connected = false,
	port = "",
	status = "Not connected",
	values = {0, 0, 0, 0},
	thresholds = {1000, 1000, 1000, 1000},
}

local function clamp(value, low, high)
	return math.max(low, math.min(high, value))
end

local function get_manager()
	return TEEJUSBFSR
end

local function short_port_name(port)
	return tostring(port or ""):gsub("^/dev/", ""):gsub("^\\\\%.\\", "")
end

local function display_port_name(port)
	local name = short_port_name(port)
	name = name:gsub("^cu%.usbmodem", "")
	name = name:gsub("^tty%.usbmodem", "")
	if name == "" then name = short_port_name(port) end
	if #name > 14 then
		name = "..." .. name:sub(-11)
	end
	return name
end

local function find_device_index(port)
	if not port or port == "" then return nil end
	for i, device in ipairs(device_snapshots) do
		if device.port == port then return i end
	end
	return nil
end

local function assigned_port()
	local manager = get_manager()
	if not manager then return "" end
	return manager:GetAssignedPort(selected_player) or ""
end

local function sync_selected_device_to_assignment()
	local index = find_device_index(assigned_port())
	if index then
		selected_device = index
	elseif #device_snapshots > 0 then
		selected_device = clamp(selected_device, 1, #device_snapshots)
	else
		selected_device = 1
	end
end

local function refresh_snapshot()
	local manager = get_manager()
	if not manager then return snapshot end
	device_snapshots = manager:PollAll() or {}
	sync_selected_device_to_assignment()
	snapshot = manager:GetSnapshotForPlayer(selected_player) or snapshot
	return snapshot
end

local function assign_selected_controller()
	local manager = get_manager()
	if not manager then return end
	if #device_snapshots == 0 then
		manager:AssignPlayer(selected_player, "")
		snapshot = manager:GetSnapshotForPlayer(selected_player) or snapshot
		MESSAGEMAN:Broadcast("TeejusbFsrUpdated")
		return
	end

	selected_device = clamp(selected_device, 1, #device_snapshots)
	local port = device_snapshots[selected_device].port or ""
	manager:AssignPlayer(selected_player, port)
	manager:RequestThresholdsForPort(port)
	snapshot = manager:GetSnapshotForPlayer(selected_player) or snapshot
	MESSAGEMAN:Broadcast("TeejusbFsrUpdated")
end

local function cycle_player(delta)
	selected_player = ((selected_player - 1 + delta) % 4) + 1
	sync_selected_device_to_assignment()
	snapshot = get_manager() and get_manager():GetSnapshotForPlayer(selected_player) or snapshot
	MESSAGEMAN:Broadcast("TeejusbFsrUpdated")
end

local function cycle_controller(delta)
	if #device_snapshots == 0 then return end
	selected_device = ((selected_device - 1 + delta) % #device_snapshots) + 1
	assign_selected_controller()
end

local function cycle_sensor(delta)
	selected_sensor = ((selected_sensor - 1 + delta) % 4) + 1
	MESSAGEMAN:Broadcast("TeejusbFsrUpdated")
end

local function update_threshold(delta)
	local manager = get_manager()
	local port = assigned_port()
	if not manager or port == "" then return end

	local thresholds = snapshot.thresholds or {}
	local current = thresholds[selected_sensor] or 1000
	local next_value = clamp(current + delta, 0, 1023)
	manager:SetThresholdForPort(port, selected_sensor, next_value)
	snapshot.thresholds[selected_sensor] = next_value
	action_feedback = ""
	MESSAGEMAN:Broadcast("TeejusbFsrUpdated")
end

local function save_thresholds()
	local manager = get_manager()
	local port = assigned_port()
	if manager and port ~= "" then
		local ok = manager:SaveThresholdsForPort(port)
		action_feedback = ok and "enregistrement envoye" or "enregistrement impossible"
		MESSAGEMAN:Broadcast("TeejusbFsrUpdated")
	end
end

local function load_thresholds()
	local manager = get_manager()
	local port = assigned_port()
	if manager and port ~= "" then
		local ok = manager:LoadThresholdsForPort(port)
		action_feedback = ok and "chargement envoye" or "chargement impossible"
		MESSAGEMAN:Broadcast("TeejusbFsrUpdated")
	end
end

local function run_selected_action()
	if selected_action == 1 then
		load_thresholds()
	else
		save_thresholds()
	end
end

local InputHandler = function(event)
	if not event or event.type == "InputEventType_Release" then return false end

	local is_first_press = event.type == "InputEventType_FirstPress"
	local is_repeat = event.type == "InputEventType_Repeat"
	if not is_first_press and not is_repeat then return false end

	if event.GameButton == "MenuUp" then
		update_threshold(is_repeat and 25 or 5)
		return true
	elseif event.GameButton == "MenuDown" then
		update_threshold(is_repeat and -25 or -5)
		return true
	end

	if not is_first_press then return false end

	if event.GameButton == "Select" then
		selected_focus = (selected_focus % #focus_names) + 1
		MESSAGEMAN:Broadcast("TeejusbFsrUpdated")
		return true
	elseif event.GameButton == "MenuLeft" then
		if selected_focus == 1 then
			cycle_player(-1)
		elseif selected_focus == 2 then
			cycle_controller(-1)
		elseif selected_focus == 3 then
			cycle_sensor(-1)
		else
			selected_action = ((selected_action - 2) % #action_names) + 1
			MESSAGEMAN:Broadcast("TeejusbFsrUpdated")
		end
		return true
	elseif event.GameButton == "MenuRight" then
		if selected_focus == 1 then
			cycle_player(1)
		elseif selected_focus == 2 then
			cycle_controller(1)
		elseif selected_focus == 3 then
			cycle_sensor(1)
		else
			selected_action = (selected_action % #action_names) + 1
			MESSAGEMAN:Broadcast("TeejusbFsrUpdated")
		end
		return true
	elseif event.GameButton == "Start" then
		run_selected_action()
		return true
	elseif event.GameButton == "Back" then
		local top = SCREENMAN:GetTopScreen()
		if top then top:Cancel() end
		return true
	end

	return false
end

local function make_action_button(index, x)
	return Def.ActorFrame{
		Name = "Action" .. index,
		InitCommand=function(self)
			self:xy(_screen.cx + x, _screen.cy + 235)
		end,
		TeejusbFsrUpdatedMessageCommand=function(self)
			local active = selected_focus == 4 and selected_action == index
			self:GetChild("Frame"):diffuse(active and color("#66CCFF") or color("#FFFFFF"))
			self:GetChild("Frame"):diffusealpha(active and 0.28 or 0.1)
			self:GetChild("Label"):diffuse(active and Color.White or color("#B8C2CC"))
		end,

		Def.Quad{
			Name = "Frame",
			InitCommand=function(self)
				self:zoomto(132, 28):diffuse(color("#FFFFFF")):diffusealpha(0.1)
			end,
		},

		LoadFont("Common Normal")..{
			Name = "Label",
			Text = action_names[index],
			InitCommand=function(self)
				self:zoom(0.44):diffuse(color("#B8C2CC")):maxwidth(220)
			end,
		},
	}
end

local function make_sensor(index, x)
	local bar_w = 72
	local bar_h = 250

	return Def.ActorFrame{
		Name = "Sensor" .. index,
		InitCommand=function(self)
			self:xy(x, _screen.cy + 30)
		end,

		TeejusbFsrUpdatedMessageCommand=function(self)
			local is_selected = selected_focus == 3 and selected_sensor == index
			self:GetChild("Selected"):visible(is_selected)

			local values = snapshot.values or {}
			local thresholds = snapshot.thresholds or {}
			local value = clamp(values[index] or 0, 0, 1023)
			local threshold = clamp(thresholds[index] or 0, 0, 1023)
			local fill_h = math.max(1, bar_h * value / 1023)
			local threshold_y = bar_h / 2 - (bar_h * threshold / 1023)

			self:GetChild("Fill"):zoomto(bar_w - 4, fill_h)
			self:GetChild("Fill"):y(bar_h / 2 - fill_h / 2)
			self:GetChild("Threshold"):y(threshold_y)
			self:GetChild("Value"):settext(value)
			self:GetChild("ThresholdText"):settext(threshold)
			self:GetChild("State"):settext(value >= threshold and "ON" or "OFF")
			self:GetChild("State"):diffuse(value >= threshold and color("#66FF88") or color("#DDDDDD"))
		end,

		LoadFont("Common Bold")..{
			Text = "Pad " .. index,
			InitCommand=function(self)
				self:y(-bar_h / 2 - 38):zoom(0.7):diffuse(Color.White)
			end,
		},

		Def.Quad{
			Name = "Selected",
			InitCommand=function(self)
				self:zoomto(bar_w + 18, bar_h + 22):diffuse(color("#66CCFF")):diffusealpha(0.18)
			end,
		},

		Def.Quad{
			InitCommand=function(self)
				self:zoomto(bar_w, bar_h):diffuse(color("#111111")):diffusealpha(0.85)
			end,
		},

		Def.Quad{
			Name = "Fill",
			InitCommand=function(self)
				self:y(bar_h / 2):zoomto(bar_w - 4, 1):diffuse(color("#45D66F"))
			end,
		},

		Def.Quad{
			InitCommand=function(self)
				self:zoomto(bar_w, bar_h):diffuse(color("#FFFFFF")):diffusealpha(0.08)
			end,
		},

		Def.Quad{
			Name = "Threshold",
			InitCommand=function(self)
				self:zoomto(bar_w + 14, 3):diffuse(color("#FF6633"))
			end,
		},

		LoadFont("Common Bold")..{
			Name = "State",
			Text = "OFF",
			InitCommand=function(self)
				self:y(-bar_h / 2 + 22):zoom(0.62):diffuse(Color.White)
			end,
		},

		LoadFont("Common Normal")..{
			Name = "Value",
			Text = "0",
			InitCommand=function(self)
				self:y(bar_h / 2 + 28):zoom(0.7):diffuse(Color.White)
			end,
		},

		LoadFont("Common Normal")..{
			Name = "ThresholdText",
			Text = "1000",
			InitCommand=function(self)
				self:y(bar_h / 2 + 52):zoom(0.5):diffuse(color("#FFAA88"))
			end,
		},
	}
end

local function make_selector(name, y, text_fn)
	return Def.ActorFrame{
		Name = name,
		InitCommand=function(self)
			self:xy(_screen.cx, y)
		end,
		TeejusbFsrUpdatedMessageCommand=function(self)
			local active = focus_names[selected_focus] == name
			self:GetChild("Frame"):diffusealpha(active and 0.18 or 0.08)
			self:GetChild("Label"):settext(text_fn())
		end,
		Def.Quad{
			Name = "Frame",
			InitCommand=function(self)
				self:zoomto(WideScale(250, 330), 30):diffuse(color("#FFFFFF")):diffusealpha(0.08)
			end,
		},
		LoadFont("Common Normal")..{
			Name = "Label",
			InitCommand=function(self)
				self:zoom(0.48):diffuse(Color.White):maxwidth(WideScale(480, 620))
			end,
		},
	}
end

local af = Def.ActorFrame{
	OnCommand=function(self)
		local top = SCREENMAN:GetTopScreen()
		if top then
			top:SetInputCallbacksHandleBeforeScreen(true)
			top:AddInputCallback(InputHandler)
		end
		refresh_snapshot()
		self:SetUpdateFunction(function()
			refresh_snapshot()
			MESSAGEMAN:Broadcast("TeejusbFsrUpdated")
		end)
	end,

	OffCommand=function(self)
		local top = SCREENMAN:GetTopScreen()
		if top then
			top:RemoveInputCallback(InputHandler)
			top:SetInputCallbacksHandleBeforeScreen(false)
		end
	end,

	Def.Quad{
		InitCommand=function(self)
			self:FullScreen():diffuse(color("#101418")):diffusealpha(0.92)
		end,
	},

	LoadFont("Common Bold")..{
		Text = "teejusb-fsr",
		InitCommand=function(self)
			self:xy(_screen.cx, _screen.cy - 210):zoom(0.86):diffuse(Color.White)
		end,
	},

	make_selector("Player", _screen.cy - 176, function()
		return ("<  Player %d  >"):format(selected_player)
	end),

	make_selector("Controller", _screen.cy - 140, function()
		if #device_snapshots == 0 then
			return "<  no pad detected  >"
		end

		local port = assigned_port()
		local index = find_device_index(port)
		if not index then
			return "<  unassigned  >"
		end

		return ("<  Controller %d/%d  %s  >"):format(index, #device_snapshots, display_port_name(port))
	end),

	LoadFont("Common Normal")..{
		Name = "Status",
		InitCommand=function(self)
			self:xy(_screen.cx, _screen.cy - 115):zoom(0.32):diffuse(color("#B8C2CC")):maxwidth(WideScale(500, 620))
		end,
		TeejusbFsrUpdatedMessageCommand=function(self)
			local focus = focus_names[selected_focus] or "Player"
			local status = snapshot.status or "Unknown"
			if action_feedback ~= "" then
				status = status .. " - " .. action_feedback
			end
			self:settext(("%s focus - %s"):format(focus, status))
		end,
	},

	LoadFont("Common Normal")..{
		Text = "Select: focus  Left/Right: change  Up/Down: threshold  Start: valider  Back: quitter",
		InitCommand=function(self)
			self:xy(_screen.cx, _screen.cy + 270):zoom(0.42):diffuse(color("#B8C2CC"))
		end,
	},
}

af[#af+1] = make_action_button(1, -76)
af[#af+1] = make_action_button(2, 76)

local spacing = WideScale(110, 140)
for i = 1, 4 do
	af[#af+1] = make_sensor(i, _screen.cx + (i - 2.5) * spacing)
end

return af
