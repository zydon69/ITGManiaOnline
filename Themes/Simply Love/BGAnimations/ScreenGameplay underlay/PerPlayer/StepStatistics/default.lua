local player = ...
local pn = ToEnumShortString(player)
local ar = GetScreenAspectRatio()
local IsUltraWide = (GetScreenAspectRatio() > 21/9)
local NoteFieldIsCentered = (GetNotefieldX(player) == _screen.cx)
local OnlineCompactLayout = IsUsingOnlineGameplayColumns and IsUsingOnlineGameplayColumns()
local OnlineGameplay = IsOnlineGameplaySessionActive and IsOnlineGameplaySessionActive()

-- -----------------------------------------------------------------------
-- if the conditions aren't right, don't bother

local stylename = GAMESTATE:GetCurrentStyle():GetName()

if SL[pn].ActiveModifiers.DataVisualizations ~= "Step Statistics" then return end

-- The online leaderboard is the single source of live score information.
-- Step Statistics duplicates its judgment counters in the same central area,
-- which makes a player's local option leak into the shared online layout.
if OnlineGameplay then return end

if (not IsUltraWide and stylename == "versus")
	or (not ThemePrefs.Get("EnableTournamentMode") and
	    SL[pn].ActiveModifiers.DataVisualizations ~= "Step Statistics")
	or (ThemePrefs.Get("EnableTournamentMode") and ThemePrefs.Get("StepStats") == "Hide")
	or (SL.Global.GameMode == "Casual")
	or (GetNotefieldWidth() > _screen.w/2 and stylename ~= "double")
	or (NoteFieldIsCentered and not IsUsingWideScreen())
	or (not IsUltraWide and stylename ~= "single" and stylename ~= "double")
	or (    IsUltraWide and not (stylename == "single" or stylename == "versus"))
then
	return
end

-- -----------------------------------------------------------------------
-- positioning and sizing of side pane

local header_height   = 80
local notefield_width = GetNotefieldWidth()
local density_graph_width = nil
local density_graph_start_offset = nil
local online_content_offset_x = nil
local sidepane_width  = _screen.w/2
local sidepane_background_width = sidepane_width
local sidepane_pos_x  = _screen.w * (player==PLAYER_1 and 0.75 or 0.25)

if not IsUltraWide then
	if NoteFieldIsCentered and IsUsingWideScreen() then
		sidepane_width = (_screen.w - GetNotefieldWidth()) / 2

		if player==PLAYER_1 then
			sidepane_pos_x = _screen.cx + notefield_width + (sidepane_width-notefield_width)/2
		else
			sidepane_pos_x = _screen.cx - notefield_width - (sidepane_width-notefield_width)/2
		end

		if stylename == "double" then sidepane_pos_x = _screen.cx; end
	end

-- ultrawide or wider
else
	if #GAMESTATE:GetHumanPlayers() > 1 then
		sidepane_width = _screen.w/5
		if player==PLAYER_1 then
			sidepane_pos_x = sidepane_width/2
		else
			sidepane_pos_x = _screen.w - (sidepane_width/2)
		end
	end
end

if OnlineCompactLayout and stylename == "single" then
	sidepane_background_width = GetOnlineGameplayPanelWidth and GetOnlineGameplayPanelWidth("side") or sidepane_width
	sidepane_width = sidepane_background_width
	sidepane_pos_x = GetOnlineGameplayColumnX(GetOnlineGameplayStatsColumn(player))
	density_graph_width = sidepane_background_width
	density_graph_start_offset = -sidepane_background_width / 2
	online_content_offset_x = -sidepane_width / 2
end

local function online_stats_payload(p)
	return {
		player = p,
		panel_width = sidepane_background_width,
	}
end

-- -----------------------------------------------------------------------

local af = Def.ActorFrame{}

af.Name="StepStatsPane"..pn
af.InitCommand=function(self)
	if Trace then
		Trace("SL_STEP_STATS_LAYOUT player=" .. tostring(pn)
			.. " online_compact=" .. tostring(OnlineCompactLayout == true)
			.. " style=" .. tostring(stylename)
			.. " is_ultrawide=" .. tostring(IsUltraWide)
			.. " note_field_centered=" .. tostring(NoteFieldIsCentered)
			.. " screen_w=" .. tostring(_screen.w)
			.. " screen_h=" .. tostring(_screen.h)
			.. " screen_cx=" .. tostring(_screen.cx)
			.. " screen_cy=" .. tostring(_screen.cy)
			.. " header_height=" .. tostring(header_height)
			.. " notefield_width=" .. tostring(notefield_width)
			.. " notefield_x=" .. tostring(GetNotefieldX(player))
			.. " base_notefield_x=" .. tostring(GetBaseNotefieldX and GetBaseNotefieldX(player) or "nil")
			.. " sidepane_x=" .. tostring(sidepane_pos_x)
			.. " sidepane_width=" .. tostring(sidepane_width)
			.. " sidepane_background_width=" .. tostring(sidepane_background_width)
			.. " density_graph_width=" .. tostring(density_graph_width)
			.. " density_graph_start_offset=" .. tostring(density_graph_start_offset)
			.. " online_content_offset_x=" .. tostring(online_content_offset_x)
			.. " aspect=" .. tostring(GetScreenAspectRatio()))
	end
	self:x(sidepane_pos_x):y(_screen.cy + header_height)
end

af[#af+1] = LoadActor("./DarkBackground.lua", {player, header_height, sidepane_background_width})

-- banner, judgment labels, and judgment numbers will be collectively shrunk
-- if Center1Player is enabled to accommodate the smaller space
	af[#af+1] = Def.ActorFrame{
		Name="BannerAndData",
		InitCommand=function(self)
			local zoomfactor = {
					ultrawide    = 0.725,
					sixteen_ten  = 0.825,
					sixteen_nine = 0.925
				}

			if OnlineCompactLayout and stylename == "single" then
				self:x(online_content_offset_x or 0):zoom(1)
				if Trace then
					Trace("SL_STEP_STATS_BANNER_AND_DATA"
						.. " player=" .. tostring(pn)
						.. " branch=online"
						.. " x=" .. tostring(online_content_offset_x or 0)
						.. " y=" .. tostring(self:GetY())
						.. " zoom=1")
				end
				return
			end

			if not IsUltraWide then
				if (NoteFieldIsCentered and IsUsingWideScreen()) then
					local zoom = scale(GetScreenAspectRatio(), 16/10, 16/9, zoomfactor.sixteen_ten, zoomfactor.sixteen_nine)
					self:zoom( zoom )
					if Trace then
						Trace("SL_STEP_STATS_BANNER_AND_DATA"
							.. " player=" .. tostring(pn)
							.. " branch=wide_centered"
							.. " zoom=" .. tostring(zoom))
					end
				end
			else
				if #GAMESTATE:GetHumanPlayers() > 1 then
					self:zoom(zoomfactor.ultrawide):addy(-55)
					if Trace then
						Trace("SL_STEP_STATS_BANNER_AND_DATA"
							.. " player=" .. tostring(pn)
							.. " branch=legacy_ultrawide"
							.. " zoom=" .. tostring(zoomfactor.ultrawide)
							.. " addy=-55")
					end
				end
			end
			end,

		LoadActor("./Banner.lua", online_stats_payload(player)),
		LoadActor("./TapNoteJudgments.lua", online_stats_payload(player), true), -- second argument is if it has labels or not
		LoadActor("./HoldsMinesRolls.lua", online_stats_payload(player)),
		LoadActor("./TeejusbFsrBars.lua", online_stats_payload(player)),
		LoadActor("./Time.lua", online_stats_payload(player)),
		LoadActor("./Scorebox.lua", player),
	}	

	af[#af+1] = LoadActor("./DensityGraph.lua", {player, density_graph_width or sidepane_width, density_graph_start_offset, header_height})

return af
