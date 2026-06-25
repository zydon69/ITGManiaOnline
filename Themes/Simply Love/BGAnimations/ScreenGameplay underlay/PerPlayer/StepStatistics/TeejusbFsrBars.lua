local arg = ...
local player = type(arg) == "table" and (arg.player or arg[1]) or arg
local online_panel_width = (type(arg) == "table" and arg.panel_width) or nil

local pn = ToEnumShortString(player)
local player_index = tonumber(tostring(pn):match("%d+")) or (player == PLAYER_1 and 1 or 2)
local IsUltraWide = (GetScreenAspectRatio() > 21/9)
local NoteFieldIsCentered = (GetNotefieldX(player) == _screen.cx)
local OnlineCompactLayout = IsUsingOnlineGameplayColumns and IsUsingOnlineGameplayColumns()
local style = GAMESTATE:GetCurrentStyle():GetName()

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

local function has_assignment()
	return snapshot and snapshot.port and snapshot.port ~= ""
end

local function get_online_frame_x()
	if not (OnlineCompactLayout and style == "single") then return nil end
	local panel = tonumber(online_panel_width) or GetNotefieldWidth() or 256
	local right_pad = clamp(panel * 0.035, 8, 18)
	return panel - right_pad
end

local function refresh_snapshot()
	if not TEEJUSBFSR then return end
	TEEJUSBFSR:PollAll()
	snapshot = TEEJUSBFSR:GetSnapshotForPlayer(player_index) or snapshot
end

local af = Def.ActorFrame{ Name = "TeejusbFsrBars" }

af.InitCommand=function(self)
	if style ~= "double" then
		self:x(player==PLAYER_1 and 95 or -145)
		self:y(-16)
		if OnlineCompactLayout and style == "single" then
			self:x((get_online_frame_x() or 220) - 60)
			self:y(74)
			self:zoom(0.76)
		end

		if NoteFieldIsCentered and IsUsingWideScreen() then
			self:x(player==PLAYER_1 and 95 or -148)
			if OnlineCompactLayout and style == "single" then
				self:x((get_online_frame_x() or 220) - 60)
				self:y(74)
				self:zoom(0.76)
			end
		end

		if IsUltraWide and #GAMESTATE:GetHumanPlayers() > 1 and not (OnlineCompactLayout and style == "single") then
			self:x(player==PLAYER_1 and -46 or -10)
		end
	else
		self:x(-GetNotefieldWidth() + 152):y(112):zoom(0.8)
	end
end

af.OnCommand=function(self)
	refresh_snapshot()
	self:SetUpdateFunction(function()
		refresh_snapshot()
		self:playcommand("UpdateFsr")
	end)
end

af[#af+1] = LoadFont("Common Normal")..{
	Name = "Missing",
	Text = "no fsr pad",
	InitCommand=function(self)
		self:y(8):zoom(0.42):diffuse(color("#B8C2CC"))
	end,
	UpdateFsrCommand=function(self)
		self:visible(not has_assignment())
	end,
}

local bar_w = 18
local bar_h = 76
local spacing = 28

for i = 1, 4 do
	af[#af+1] = Def.ActorFrame{
		Name = "FsrBar" .. i,
		InitCommand=function(self)
			self:x((i - 2.5) * spacing)
		end,
		UpdateFsrCommand=function(self)
			local visible = has_assignment()
			self:visible(visible)
			if not visible then return end

			local values = snapshot.values or {}
			local thresholds = snapshot.thresholds or {}
			local value = clamp(values[i] or 0, 0, 1023)
			local threshold = clamp(thresholds[i] or 0, 0, 1023)
			local fill_h = math.max(1, bar_h * value / 1023)
			local threshold_y = bar_h / 2 - (bar_h * threshold / 1023)

			self:GetChild("Fill"):zoomto(bar_w, fill_h)
			self:GetChild("Fill"):y(bar_h / 2 - fill_h / 2)
			self:GetChild("Threshold"):y(threshold_y)
			self:GetChild("Label"):diffuse(value >= threshold and color("#66FF88") or color("#B8C2CC"))
		end,
		Def.Quad{
			InitCommand=function(self)
				self:zoomto(bar_w, bar_h):diffuse(color("#FFFFFF")):diffusealpha(0.09)
			end,
		},
		Def.Quad{
			Name = "Fill",
			InitCommand=function(self)
				self:y(bar_h / 2):zoomto(bar_w, 1):diffuse(color("#45D66F"))
			end,
		},
		Def.Quad{
			Name = "Threshold",
			InitCommand=function(self)
				self:zoomto(bar_w + 6, 2):diffuse(color("#FF6633"))
			end,
		},
		LoadFont("Common Normal")..{
			Name = "Label",
			Text = tostring(i),
			InitCommand=function(self)
				self:y(bar_h / 2 + 10):zoom(0.32):diffuse(color("#B8C2CC"))
			end,
		},
	}
end

return af
