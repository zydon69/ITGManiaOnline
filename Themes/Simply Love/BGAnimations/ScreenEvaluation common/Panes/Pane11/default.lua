-- Pane11 displays timing scatter plots colored by column and stream foot.

if SL.Global.GameMode == "Casual" or GAMESTATE:IsCourseMode() then return end

local player = unpack(...)
local pn = ToEnumShortString(player)
local storage = SL[pn].Stages.Stats[SL.Global.Stages.PlayedThisGame + 1]
local sequential_offsets = storage and storage.sequential_offsets
if type(sequential_offsets) ~= "table" or #sequential_offsets == 0 then return end

local pane_width, pane_height = 300, 180
local plot_width, plot_height = 280, 58
local worst_window = GetTimingWindow(storage.worst_window or 3)
local steps = GAMESTATE:GetCurrentSteps(player)
local song = GAMESTATE:GetCurrentSong()
if not (steps and song) then return end

local timing_data = steps:GetTimingData()
local first_second = math.min(timing_data:GetElapsedTimeFromBeat(0), 0)
local last_second = song:GetLastSecond()
local music_rate = SL.Global.ActiveModifiers.MusicRate
local death_second = storage.DeathSecond

local column_colors = { Color.Red, Color.Blue, Color.Green, Color.Yellow }
local foot_colors = { color("#ff7373"), color("#73a8ff") }

local pane_title = THEME:GetString("ScreenEvaluation", "ScatterDetails")
local column_title = THEME:GetString("ScreenEvaluation", "ColumnTiming")
local foot_title = THEME:GetString("ScreenEvaluation", "StreamFootTiming")

local function AddPoint(verts, x, y, color, alpha)
	local r, g, b = color[1], color[2], color[3]
	local size = 1.45
	verts[#verts+1] = {{x, y, 0}, {r, g, b, alpha}}
	verts[#verts+1] = {{x + size, y, 0}, {r, g, b, alpha}}
	verts[#verts+1] = {{x + size, y + size, 0}, {r, g, b, alpha}}
	verts[#verts+1] = {{x, y + size, 0}, {r, g, b, alpha}}
end

local function BuildVerts(mode)
	local verts = {}

	for entry in ivalues(sequential_offsets) do
		local current_second = entry[1]
		local offset = entry[2]
		local direction = tonumber(entry[3])
		local is_stream = entry[4]
		local foot = entry[5]
		local early_hit = entry[6]
		local early_offset = entry[7]
		local held_miss = entry[8]

		if offset ~= "Miss" then
			current_second = current_second - offset
		else
			current_second = current_second - worst_window
		end

		local x = scale(current_second, first_second, last_second + 0.05, 0, plot_width)
		local color_value = Color.White
		if mode == "column" then
			color_value = column_colors[direction] or Color.White
		elseif is_stream then
			color_value = foot and foot_colors[1] or foot_colors[2]
		else
			color_value = color("#444444")
		end

		local alpha = (death_second ~= nil and current_second / music_rate > death_second) and 0.25 or 0.72
		if offset ~= "Miss" then
			local y = scale(offset, worst_window, -worst_window, 0, plot_height)
			AddPoint(verts, x, y, color_value, alpha)

			if early_hit and early_offset then
				local early_y = scale(early_offset, worst_window, -worst_window, 0, plot_height)
				AddPoint(verts, x, early_y, color_value, alpha * 0.45)
			end
		else
			local y = held_miss and plot_height * 0.25 or plot_height * 0.65
			AddPoint(verts, x, y, color_value, alpha)
		end
	end

	return verts
end

local function MakePlot(label, mode, y)
	return Def.ActorFrame{
		InitCommand=function(self)
			self:xy(-plot_width * 0.5, y)
		end,
		Def.Quad{
			InitCommand=function(self)
				self:xy(plot_width * 0.5, plot_height * 0.5):zoomto(plot_width, plot_height)
					:diffuse(color("#101519")):diffusealpha(0.95)
			end
		},
		Def.Quad{
			InitCommand=function(self)
				self:xy(plot_width * 0.5, plot_height * 0.5):zoomto(plot_width, 1)
					:diffuse(Color.White):diffusealpha(0.16)
			end
		},
		LoadFont("Common Normal")..{
			Text=label,
			InitCommand=function(self)
				self:xy(0, -14):zoom(0.55):horizalign(left):diffuse(Color.White)
			end
		},
		Def.ActorMultiVertex{
			InitCommand=function(self)
				self:SetDrawState({Mode="DrawMode_Quads"})
				self:SetVertices(BuildVerts(mode))
			end
		}
	}
end

return Def.ActorFrame{
	InitCommand=function(self)
		self:xy(0, pane_height * 1.44)
	end,
	Def.Sprite{
		Texture=THEME:GetPathG("", "feet-diagram.png"),
		InitCommand=function(self)
			self:xy(pane_width * 0.34, -62):zoom(0.34):diffusealpha(0.16)
		end
	},
	LoadFont("Common Bold")..{
		Text=pane_title,
		InitCommand=function(self)
			self:xy(-pane_width * 0.5, -62):zoom(0.75):horizalign(left):diffuse(Color.White)
		end
	},
	MakePlot(column_title, "column", -18),
	MakePlot(foot_title, "foot", 72),
}
