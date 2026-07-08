local t = Def.ActorFrame{
	Name="Text",
	OnCommand=function(self) self:queuecommand("Show") end,
	EditCommand=function(self) self:playcommand("Show") end,

	PlayingCommand=function(self) self:playcommand("Hide") end,
	RecordCommand=function(self) self:playcommand("Hide") end,
	RecordPausedCommand=function(self) self:playcommand("Hide") end,

	-- Info
	Def.ActorFrame{
		InitCommand=function(self) self:xy(_screen.w, 10) end,
		ShowCommand=function(self) self:visible(true) end,
		HideCommand=function(self) self:visible(false) end,

		Def.Quad{ InitCommand=function(self) self:zoomto(30,1):horizalign(right) end },

		LoadFont("Common Bold") .. {
			Name="InfoText",
			Text="PRACTICE MODE",
			InitCommand=function(self) self:zoom(0.265):horizalign(right):x(-35):diffuse(PlayerColor(PLAYER_1)) end,
		}
	}
}

local players = GAMESTATE:GetHumanPlayers()
local is43 = GetScreenAspectRatio() <= 1.4
local style = GAMESTATE:GetCurrentStyle()
local style_name = style and style:GetName() or ""

local graph_width = _screen.h - 100
local graph_height = 50
local graph_y = 80
local graph_x = GetNotefieldWidth() / 1.30

if style_name ~= "versus" and style_name ~= "single" then
	graph_x = GetNotefieldWidth() / 2.2
end

if is43 then
	graph_height = 25
	graph_x = (GetNotefieldWidth() / 1.50) - 1
	if style_name ~= "versus" and style_name ~= "single" then
		graph_width = _screen.h - 200
		graph_x = GetNotefieldWidth() / 2.7
		graph_y = 180
	end
end

graph_x = graph_x + (_screen.w / 2) - graph_height

local nps_graph_drawn = false

for player in ivalues(players) do
	local backgroundFilter = LoadActor("ScreenGameplay underlay/PerPlayer/BackgroundFilter.lua", player)

	if backgroundFilter then
		t[#t+1] = backgroundFilter..{
			ShowCommand=function(self) self:visible(false) end,
			PlayingCommand=function(self) self:visible(true) end
		}
	end

	t[#t+1] = LoadActor("ScreenGameplay underlay/PerPlayer/NoteField/default.lua", player)..{
		ShowCommand=function(self) self:visible(false) end,
		PlayingCommand=function(self) self:visible(true) end,
	}

	t[#t+1] = Def.ActorProxy{
		Name="NoteFieldContainer"..ToEnumShortString(player),
		OnCommand=function(self)
			self:SetTarget(GetPlayerAF(ToEnumShortString(player)))
		end,
		ShowCommand=function(self) self:visible(false) end,
		PlayingCommand=function(self) self:visible(true) end,
	}

	if not nps_graph_drawn then
		t[#t+1] = NPS_Histogram_With_Position_Line(player, graph_width, graph_height)..{
			OnCommand=function(self)
				self:xy(graph_x, graph_y)
					:rotationz(90)
				self:queuecommand("Redraw")
			end,
			ShowCommand=function(self)
				self:queuecommand("ScrollSong")
				self:visible(true)
			end,
			PlayingCommand=function(self) self:visible(false) end,
		}
		nps_graph_drawn = true
	end
end

return t
