local args = ...
local player = args.Player or GAMESTATE:GetMasterPlayerNumber()
local show_menu_buttons = args.ShowMenuButtons
local show_player_label = args.ShowPlayerLabel

-- ScreenTestInput can instantiate this module for both sides even when only one
-- human player is joined. Skip building actors for inactive sides.
if player and not GAMESTATE:IsHumanPlayer(player) then
	return Def.ActorFrame{}
end

local af = Def.ActorFrame{}
local pad_img = GAMESTATE:GetCurrentGame():GetName()
local player_reverse = PlayerNumber:Reverse()
local controller_reverse = GameController:Reverse()

if pad_img == "dance" and ThemePrefs.Get("AllowDanceSolo") then
	local style = GAMESTATE:GetCurrentStyle()
	-- style will be nil in ScreenTestInput within the operator menu
	if style==nil or style:GetName()=="solo" then
		pad_img = "dance-solo"
	end
end

local Highlights = {
	UpLeft={    x=-67, y=-148, rotationz=0, zoom=0.8, graphic="highlight.png" },
	Up={        x=0,   y=-148, rotationz=0, zoom=0.8, graphic="highlight.png" },
	UpRight={   x=67,  y=-148, rotationz=0, zoom=0.8, graphic="highlight.png" },

	Left={      x=-67, y=-80,  rotationz=0, zoom=0.8, graphic="highlight.png" },
	Center={    x=0,   y=-80,  rotationz=0, zoom=0.8, graphic="highlight.png" },
	Right={     x=67,  y=-80,  rotationz=0, zoom=0.8, graphic="highlight.png" },

	DownLeft={  x=-67, y=-12,  rotationz=0, zoom=0.8, graphic="highlight.png" },
	Down={      x=0,   y=-12,  rotationz=0, zoom=0.8, graphic="highlight.png" },
	DownRight={ x=67,  y=-12,  rotationz=0, zoom=0.8, graphic="highlight.png" }
}

if show_menu_buttons then
	Highlights.Start={     x=0,   y=66, rotationz=0,   zoom=0.5, graphic="highlightgreen.png" }
	Highlights.Select={    x=0,   y=95, rotationz=180, zoom=0.5, graphic="highlightred.png" }
	Highlights.MenuRight={ x=37,  y=80, rotationz=0,   zoom=0.5, graphic="highlightarrow.png" }
	Highlights.MenuLeft={  x=-37, y=80, rotationz=180, zoom=0.5, graphic="highlightarrow.png" }
end


local pad = Def.ActorFrame{}
local highlight_source_names = {}

for _, values in pairs(Highlights) do
	local source_name = "HighlightSource_" .. values.graphic:gsub("[^%w]", "_")
	if not highlight_source_names[source_name] then
		highlight_source_names[source_name] = values.graphic
		pad[#pad+1] = LoadActor(values.graphic)..{
			Name=source_name,
			InitCommand=function(self) self:visible(false) end
		}
	end
end

if show_player_label then
	pad[#pad+1] = LoadFont("Common Bold")..{
		Text=("%s %i"):format(THEME:GetString("ScreenTestInput", "Player"), PlayerNumber:Reverse()[player]+1),
		InitCommand=function(self) self:y(-210):zoom(0.7):visible(false) end,
		OnCommand=function(self)
			local screenname =  SCREENMAN:GetTopScreen():GetName()
			local screenclass = THEME:GetMetric(screenname, "Class")
			self:visible( screenclass == "ScreenTestInput" )
		end
	}
end

pad[#pad+1] = LoadActor(pad_img..".png")..{  InitCommand=function(self) self:y(-80):zoom(0.8) end }

if show_menu_buttons then
	pad[#pad+1] = LoadActor("buttons.png")..{
		InitCommand=function(self) self:y(80):zoom(0.5) end
	}
end

for panel, values in pairs(Highlights) do
	pad[#pad+1] = Def.ActorProxy{
		InitCommand=function(self)
			local source_name = "HighlightSource_" .. values.graphic:gsub("[^%w]", "_")
			local source = self:GetParent():GetChild(source_name)
			if source then self:SetTarget(source) end
			self:xy(values.x, values.y):rotationz(values.rotationz):zoom(values.zoom):visible(false)
		end,
		TestInputEventMessageCommand=function(self, event)
			local style = GAMESTATE:GetCurrentStyle()
			local styletype = style and style:GetStyleType() or nil

			-- if double or routine
			if styletype == "StyleType_OnePlayerTwoSides" or styletype == "StyleType_TwoPlayersSharedSides" then

				-- in double, we can't rely on checking the input event's "PlayerNumber" key (only one human player is joined)
				-- so instead, compared the input event's "controller" key from the engine's GameController enum
				-- "GameController_1" is indexed at 0, and "GameController_2" is indexed at 1, conveniently just like how
				--  "PlayerNumber_P1" is indexed at 0, and  "PlayerNumber_P2" is indexed at 1
				if controller_reverse[event.controller] == player_reverse[player]
				and event.button == panel then
					self:visible(event.type == "InputEventType_FirstPress")
				end

			-- else single or versus (or style is nil because we're actually on ScreenTestInput)
			else
				if event.PlayerNumber == player and event.button == panel then
					self:visible(event.type == "InputEventType_FirstPress")
				end
			end
		end
	}
end

af[#af+1] = pad

return af
