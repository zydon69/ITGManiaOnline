local selected_sensor = 1
local selected_device = 1
local device_ports = {}
local last_port_scan = -100
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
	return tostring(port or ""):gsub("^/dev/", "")
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

local function find_port_index(port)
	if not port or port == "" then return nil end
	for i, candidate in ipairs(device_ports) do
		if candidate == port then return i end
	end
	return nil
end

local function rescan_ports(force)
	local manager = get_manager()
	if not manager then
		device_ports = {}
		selected_device = 1
		return
	end

	local now = GetTimeSinceStart and GetTimeSinceStart() or 0
	if not force and now - last_port_scan < 1 then return end
	last_port_scan = now

	device_ports = manager:GetDevicePorts() or {}
	if #device_ports == 0 then
		selected_device = 1
		return
	end

	local current_index = find_port_index(snapshot.port)
	if current_index then
		selected_device = current_index
	else
		selected_device = clamp(selected_device, 1, #device_ports)
	end
end

local function refresh_snapshot()
	local manager = get_manager()
	if not manager then return snapshot end
	snapshot = manager:Poll() or snapshot
	rescan_ports(false)
	return snapshot
end

local function update_threshold(sensor, delta)
	local manager = get_manager()
	if not manager then return end
	local thresholds = snapshot.thresholds or {}
	local current = thresholds[sensor] or 1000
	local next_value = clamp(current + delta, 0, 1023)
	manager:SetThreshold(sensor, next_value)
	snapshot.thresholds[sensor] = next_value
	MESSAGEMAN:Broadcast("TeejusbFsrUpdated")
end

local function connect_selected_device()
	local manager = get_manager()
	if not manager then return end

	rescan_ports(true)
	if #device_ports == 0 then
		manager:Disconnect()
		snapshot = manager:GetSnapshot() or snapshot
		MESSAGEMAN:Broadcast("TeejusbFsrUpdated")
		return
	end

	selected_device = clamp(selected_device, 1, #device_ports)
	manager:Connect(device_ports[selected_device])
	manager:RequestThresholds()
	snapshot = manager:GetSnapshot() or snapshot
	MESSAGEMAN:Broadcast("TeejusbFsrUpdated")
end

local function cycle_device(delta)
	rescan_ports(true)
	if #device_ports == 0 then
		connect_selected_device()
		return
	end

	selected_device = ((selected_device - 1 + delta) % #device_ports) + 1
	connect_selected_device()
end

local InputHandler = function(event)
	if not event or event.type ~= "InputEventType_FirstPress" then return false end

	if event.GameButton == "MenuLeft" then
		selected_sensor = ((selected_sensor + 2) % 4) + 1
		MESSAGEMAN:Broadcast("TeejusbFsrUpdated")
		return true
	elseif event.GameButton == "MenuRight" then
		selected_sensor = (selected_sensor % 4) + 1
		MESSAGEMAN:Broadcast("TeejusbFsrUpdated")
		return true
	elseif event.GameButton == "MenuUp" then
		update_threshold(selected_sensor, 5)
		return true
	elseif event.GameButton == "MenuDown" then
		update_threshold(selected_sensor, -5)
		return true
	elseif event.GameButton == "Start" then
		local manager = get_manager()
		if manager then manager:SaveThresholds() end
		return true
	elseif event.GameButton == "Select" then
		cycle_device(1)
		return true
	elseif event.GameButton == "Back" then
		local top = SCREENMAN:GetTopScreen()
		if top then top:Cancel() end
		return true
	end

	return false
end

local function make_sensor(index, x)
	local bar_w = 72
	local bar_h = 250

	return Def.ActorFrame{
		Name = "Sensor" .. index,
		InitCommand=function(self)
			self:xy(x, _screen.cy + 26)
		end,

		TeejusbFsrUpdatedMessageCommand=function(self)
			local is_selected = selected_sensor == index
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

local af = Def.ActorFrame{
	OnCommand=function(self)
		local top = SCREENMAN:GetTopScreen()
		if top then
			top:SetInputCallbacksHandleBeforeScreen(true)
			top:AddInputCallback(InputHandler)
		end
		connect_selected_device()
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
			self:xy(_screen.cx, _screen.cy - 205):zoom(0.9):diffuse(Color.White)
		end,
	},

	Def.ActorFrame{
		Name = "DeviceSelector",
		InitCommand=function(self)
			self:xy(_screen.cx, _screen.cy - 170)
		end,
		TeejusbFsrUpdatedMessageCommand=function(self)
			local ports_count = #device_ports
			local label = self:GetChild("Label")
			local status = self:GetChild("Status")
			if not label or not status then return end

			if ports_count == 0 then
				label:settext("<  no pad detected  >")
			else
				local port = device_ports[selected_device] or snapshot.port or ""
				label:settext(("<  Controller %d/%d  %s  >"):format(selected_device, ports_count, display_port_name(port)))
			end
			status:settext(snapshot.status or "Unknown")
		end,

		Def.Quad{
			InitCommand=function(self)
				self:zoomto(WideScale(260, 340), 30):diffuse(color("#FFFFFF")):diffusealpha(0.08)
			end,
		},

		LoadFont("Common Normal")..{
			Name = "Label",
			InitCommand=function(self)
				self:y(-4):zoom(0.58):diffuse(Color.White):maxwidth(WideScale(500, 620))
			end,
		},

		LoadFont("Common Normal")..{
			Name = "Status",
			InitCommand=function(self)
				self:y(10):zoom(0.26):diffuse(color("#B8C2CC")):maxwidth(WideScale(500, 620))
			end,
		},
	},

	LoadFont("Common Normal")..{
		Text = "Select: controller  Left/Right: pad  Up/Down: threshold  Start: save  Back: exit",
		InitCommand=function(self)
			self:xy(_screen.cx, _screen.cy + 224):zoom(0.45):diffuse(color("#B8C2CC"))
		end,
	},
}

local spacing = WideScale(110, 140)
for i = 1, 4 do
	af[#af+1] = make_sensor(i, _screen.cx + (i - 2.5) * spacing)
end

return af
