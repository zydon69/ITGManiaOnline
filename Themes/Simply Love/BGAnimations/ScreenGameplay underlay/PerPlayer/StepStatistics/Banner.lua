local arg = ...
local player = type(arg) == "table" and (arg.player or arg[1]) or arg
local online_panel_width = (type(arg) == "table" and arg.panel_width) or nil

local NoteFieldIsCentered = (GetNotefieldX(player) == _screen.cx)
local IsUltraWide = (GetScreenAspectRatio() > 21/9)
local OnlineCompactLayout = IsUsingOnlineGameplayColumns and IsUsingOnlineGameplayColumns()

local style = GAMESTATE:GetCurrentStyle():GetName()

local function OnlineBannerAnchorX()
	if not OnlineCompactLayout or style ~= "single" then
		return 70 * (player==PLAYER_1 and 1 or -1)
	end

	local panel = tonumber(online_panel_width) or 410
	return panel / 2
end

local function OnlineBannerY()
	return -(_screen.h * 0.415)
end

return Def.Banner{
	CurrentSongChangedMessageCommand=function(self)
	self:LoadFromSong( GAMESTATE:GetCurrentSong() )
	self:setsize(418,164):zoom(0.4)
	if OnlineCompactLayout and style == "single" then
		self:setsize(410,160):zoom(0.40)
	end

	local banner_x = OnlineBannerAnchorX()
	local banner_y = OnlineCompactLayout and style == "single" and OnlineBannerY() or -200
	if Trace then
		Trace("SL_STEP_STATS_BANNER"
			.. " player=" .. tostring(ToEnumShortString(player))
			.. " online_compact=" .. tostring(OnlineCompactLayout == true)
			.. " style=" .. tostring(style)
			.. " panel_width=" .. tostring(online_panel_width)
			.. " banner_x=" .. tostring(banner_x)
			.. " banner_y=" .. tostring(banner_y)
			.. " zoom=" .. tostring(self:GetZoom())
			.. " width=" .. tostring(self:GetWidth())
			.. " height=" .. tostring(self:GetHeight())
			.. " is_ultrawide=" .. tostring(IsUltraWide)
			.. " note_field_centered=" .. tostring(NoteFieldIsCentered))
	end
		
	if style ~= "double" then
		self:xy(70 * (player==PLAYER_1 and 1 or -1), -200)
		if OnlineCompactLayout and style == "single" then
			self:xy(banner_x, banner_y)
		end

			self:SetDecodeMovie(ThemePrefs.Get("AnimateBanners"))

		-- offset a bit more when NoteFieldIsCentered
		if NoteFieldIsCentered and IsUsingWideScreen() then
			self:x( 72 * (player==PLAYER_1 and 1 or -1) )
			if OnlineCompactLayout and style == "single" then
				self:xy(banner_x, banner_y)
			end
		end

			-- ultrawide and both players joined
			if IsUltraWide and #GAMESTATE:GetHumanPlayers() > 1 and not (OnlineCompactLayout and style == "single") then
				self:x(self:GetX() * -1)
			end
		else
			self:xy(GetNotefieldWidth() - 140, -200)
		end
	end
}
