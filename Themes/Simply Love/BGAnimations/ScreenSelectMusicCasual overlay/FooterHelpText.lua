local function CancelText()
	if PREFSMAN and PREFSMAN.GetPreference and PREFSMAN:GetPreference("ThreeKeyNavigation") then
		return THEME:GetString("ScreenSelectMusicCasual", "FooterTextSingleSong3Key")
	end
	return THEME:GetString("ScreenSelectMusicCasual", "FooterTextSingleSong")
end

return LoadFont("Common Normal")..{
	InitCommand=function(self) self:xy(_screen.cx, _screen.h - 16):zoom(0.7):diffusealpha(0) end,
	SwitchFocusToGroupsMessageCommand=function(self)
		self:diffusealpha(0):settext(THEME:GetString("ScreenSelectMusicCasual", "FooterTextGroups")):linear(0.15):diffusealpha(1)
	end,
	SwitchFocusToSongsMessageCommand=function(self)
		self:diffusealpha(0):settext(THEME:GetString("ScreenSelectMusicCasual", "FooterTextSongs")):linear(0.15):diffusealpha(1)
	end,
	SwitchFocusToSingleSongMessageCommand=function(self)
		self:diffusealpha(0):settext( CancelText() ):linear(0.15):diffusealpha(1)
	end,
}
