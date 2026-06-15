local player = ...
local NoteFieldIsCentered = (GetNotefieldX(player) == _screen.cx)
local IsUltraWide = (GetScreenAspectRatio() > 21/9)
local OnlineCompactLayout = ITGOnline and ITGOnline.currentRoomId ~= nil

local style = GAMESTATE:GetCurrentStyle():GetName()

return Def.Banner{
	CurrentSongChangedMessageCommand=function(self)
		self:LoadFromSong( GAMESTATE:GetCurrentSong() )
		self:setsize(418,164):zoom(0.4)
		if OnlineCompactLayout and style == "single" then
			self:setsize(410,160):zoom(0.48)
		end
		
		if style ~= "double" then
			self:xy(70 * (player==PLAYER_1 and 1 or -1), -200)
			if OnlineCompactLayout and style == "single" then
				self:xy(164, -248)
			end

			self:SetDecodeMovie(ThemePrefs.Get("AnimateBanners"))

			-- offset a bit more when NoteFieldIsCentered
			if NoteFieldIsCentered and IsUsingWideScreen() then
				self:x( 72 * (player==PLAYER_1 and 1 or -1) )
				if OnlineCompactLayout and style == "single" then
					self:xy(164, -248)
				end
			end

			-- ultrawide and both players joined
			if IsUltraWide and #GAMESTATE:GetHumanPlayers() > 1 then
				self:x(self:GetX() * -1)
			end
		else
			self:xy(GetNotefieldWidth() - 140, -200)
		end
	end
}
