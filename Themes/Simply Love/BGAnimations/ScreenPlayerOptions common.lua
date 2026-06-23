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

local OPTIONS_READY_TIMEOUT_SECONDS = 30
local online_options_screen_name = nil
local last_online_options_warning_second = nil

local function play_online_options_warning_tick(remaining)
	local second = tonumber(remaining)
	if not second then return end
	second = math.ceil(second)

	if second < 1 or second > 5 then
		last_online_options_warning_second = nil
		return
	end
	if last_online_options_warning_second == second then
		return
	end

	last_online_options_warning_second = second
	if Trace then
		Trace("[ITGOnline] options_ready_warning_tick remaining=" .. tostring(second)
			.. " room=" .. tostring(ITGOnline and ITGOnline.currentRoomId or "nil"))
	end
	SOUND:PlayOnce(THEME:GetPathS("MenuTimer", "tick"))
end

local function online_options_timeout_active()
	return ITGOnline
		and ITGOnline.currentRoomId
		and ITGOnline.currentRoom
		and ITGOnline.NormalizeRoomPhase
		and ITGOnline:NormalizeRoomPhase(ITGOnline.currentRoom.phase) == "config"
		and not ITGOnline:IsCurrentUserReadyInRoom(ITGOnline.currentRoom)
end

local function return_to_online_lobby()
	local screen = SCREENMAN:GetTopScreen()
	if not screen then return end
	screen:SetNextScreenName("ScreenOnlineLobbies")
	screen:StartTransitioningScreen("SM_GoToNextScreen")
end

local function play_online_options_preview_music(source)
	if not (ITGOnline and ITGOnline.currentRoom and play_online_preview_music_normal_rate) then
		return
	end
	local phase = ITGOnline.NormalizeRoomPhase and ITGOnline:NormalizeRoomPhase(ITGOnline.currentRoom.phase) or tostring(ITGOnline.currentRoom.phase or "")
	if phase ~= "config" and phase ~= "lobby_ready" then
		return
	end
	local songInfo = ITGOnline.currentRoom.selected_song or ITGOnline.currentSongPayload
	if type(songInfo) ~= "table" then
		return
	end
	play_online_preview_music_normal_rate(songInfo, source or "screen_player_options")
end

local af = Def.ActorFrame{
	OnCommand=function(self)
		local screen = SCREENMAN:GetTopScreen()
		online_options_screen_name = screen and screen:GetName() or nil
		if ITGOnline and ITGOnline.currentRoomId then
			SL.Global.ScreenAfter.PlayerOptions = "ScreenOnlineLobbies"
			SL.Global.ScreenAfter.PlayerOptions2 = "ScreenOnlineLobbies"
			SL.Global.ScreenAfter.PlayerOptions3 = "ScreenOnlineLobbies"
		end
		if ITGOnline and ITGOnline.BeginOnlineOptionsReadyDeadline and online_options_timeout_active() then
			last_online_options_warning_second = nil
			ITGOnline:BeginOnlineOptionsReadyDeadline(OPTIONS_READY_TIMEOUT_SECONDS, "screen_player_options")
			self:queuecommand("UpdateOptionsReadyTimer")
		end
		play_online_options_preview_music("screen_player_options_on")
	end,
	OnlineLobbyStateMessageCommand=function(self)
		if ITGOnline and ITGOnline.BeginOnlineOptionsReadyDeadline and online_options_timeout_active() then
			ITGOnline:BeginOnlineOptionsReadyDeadline(OPTIONS_READY_TIMEOUT_SECONDS, "screen_player_options_state")
			self:queuecommand("UpdateOptionsReadyTimer")
		end
		play_online_options_preview_music("screen_player_options_state")
	end,
	OffCommand=function(self)
		if not (ITGOnline and ITGOnline.currentRoomId) then
			return
		end
		if ITGOnline.ShouldSuppressOnlineConfigReadyOnOptionsExit
			and ITGOnline:ShouldSuppressOnlineConfigReadyOnOptionsExit() then
			Trace("[ITGOnline] options_screen_off skipped config_ready after timeout")
			return
		end

		local screen = SCREENMAN:GetTopScreen()
		local screenName = online_options_screen_name or (screen and screen:GetName()) or ""
		if online_next_screen_for_options(screenName) ~= "ScreenOnlineLobbies" then
			return
		end

		Trace("[ITGOnline] options_screen_off confirmed screen=" .. tostring(screenName))
		MESSAGEMAN:Broadcast("OnlineConfigReady")
	end,

	UpdateOptionsReadyTimerCommand=function(self)
		local timer = self:GetChild("OnlineOptionsReadyTimer")
		if not timer then return end

		if not (ITGOnline and ITGOnline.OnlineOptionsReadyRemaining and online_options_timeout_active()) then
			last_online_options_warning_second = nil
			timer:visible(false)
			return
		end

		local remaining = ITGOnline:OnlineOptionsReadyRemaining()
		if remaining == nil then
			last_online_options_warning_second = nil
			timer:visible(false)
			return
		end

		if remaining <= 0 then
			last_online_options_warning_second = nil
			timer:visible(true)
			timer:settext("Options timeout")
			if ITGOnline.ExpireOnlineOptionsReady then
				ITGOnline:ExpireOnlineOptionsReady("screen_player_options", function()
					return_to_online_lobby()
				end)
			else
				return_to_online_lobby()
			end
			return
		end

		timer:visible(true)
		play_online_options_warning_tick(remaining)
		timer:settext(("Ready in %02ds or leave lobby"):format(math.ceil(remaining)))
		self:sleep(0.25):queuecommand("UpdateOptionsReadyTimer")
	end,

	LoadFont("Common Bold")..{
		Name="OnlineOptionsReadyTimer",
		InitCommand=function(self)
			self:xy(0, _screen.h - 38)
			self:zoom(0.45)
			self:shadowlength(1)
			self:diffuse(color("#FFDD55"))
			self:visible(false)
		end,
	}
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
