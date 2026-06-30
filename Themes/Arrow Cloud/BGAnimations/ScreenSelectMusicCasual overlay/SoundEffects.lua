local af = Def.ActorFrame{}
af.PlaySFXMessageCommand=function(self, params)
	if type(params) ~= "table" or type(params.Action) ~= "string" then return end

	local ok, actor = pcall(function() return self:GetChild(params.Action) end)
	if not ok then return end
	if actor then
		if params.Player and GAMESTATE and GAMESTATE.IsHumanPlayer and GAMESTATE:IsHumanPlayer(params.Player) then
			pcall(function() actor:playforplayer(params.Player) end)
		else
			pcall(function() actor:play() end)
		end
	end
end

-- when a Sound's IsAction attribute is true, machine operators can mute that sound
-- by setting MuteActions=1 in Preferences.ini (F3+A to quickly toggle)
af[#af+1] = Def.Sound{ Name="ChangeGroup", IsAction=true, File=THEME:GetPathS("ScreenSelectMaster", "change") }
af[#af+1] = Def.Sound{ Name="ChangeSong",  IsAction=true, File=THEME:GetPathS("MusicWheel", "change") }
af[#af+1] = Def.Sound{ Name="Start",       IsAction=true, File=THEME:GetPathS("Common", "Start") }

return af
