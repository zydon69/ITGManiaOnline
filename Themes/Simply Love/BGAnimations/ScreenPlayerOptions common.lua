local function online_next_screen_for_options(screenName)
	if screenName == "ScreenPlayerOptions" then
		return SL.Global.ScreenAfter.PlayerOptions
	elseif screenName == "ScreenPlayerOptions2" then
		return SL.Global.ScreenAfter.PlayerOptions2
	elseif screenName == "ScreenPlayerOptions3" then
		return SL.Global.ScreenAfter.PlayerOptions3
	end

	return nil
end

local af = Def.ActorFrame{
	OffCommand=function(self)
		if not (ITGOnline and ITGOnline.currentRoomId) then
			return
		end

		local screen = SCREENMAN:GetTopScreen()
		local screenName = screen and screen:GetName() or ""
		if online_next_screen_for_options(screenName) ~= "ScreenOnlineLobbies" then
			return
		end

		Trace("[ITGOnline] options_screen_off confirmed screen=" .. tostring(screenName))
		MESSAGEMAN:Broadcast("OnlineConfigReady")
	end,
}

-- this is broadcast from [OptionRow] TitleGainFocusCommand in metrics.ini
-- we use it to color the active OptionRow's title appropriately by PlayerColor()
af.OptionRowChangedMessageCommand=function(self, params)
	local CurrentRowIndex = {"P1", "P2"}

	-- There is always the possibility that a diffuseshift is still active;
	-- cancel it now (and re-apply below, if applicable).
	params.Title:stopeffect()

	-- get the index of PLAYER_1's current row
	if GAMESTATE:IsPlayerEnabled(PLAYER_1) then
		CurrentRowIndex.P1 = SCREENMAN:GetTopScreen():GetCurrentRowIndex(PLAYER_1)
	end

	-- get the index of PLAYER_2's current row
	if GAMESTATE:IsPlayerEnabled(PLAYER_2) then
		CurrentRowIndex.P2 = SCREENMAN:GetTopScreen():GetCurrentRowIndex(PLAYER_2)
	end

	local optionRow = params.Title:GetParent():GetParent()

	-- color the active optionrow's title appropriately
	if optionRow:HasFocus(PLAYER_1) then
		params.Title:diffuse(PlayerColor(PLAYER_1))
	end

	if optionRow:HasFocus(PLAYER_2) then
		params.Title:diffuse(PlayerColor(PLAYER_2))
	end

	if CurrentRowIndex.P1 and CurrentRowIndex.P2 then
		if CurrentRowIndex.P1 == CurrentRowIndex.P2 then
			params.Title:diffuseshift()
			params.Title:effectcolor1(PlayerColor(PLAYER_1))
			params.Title:effectcolor2(PlayerColor(PLAYER_2))
		end
	end

end

return af
