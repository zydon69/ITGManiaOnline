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
local last_online_options_timer_trace_key = ""
local last_online_options_deadline_begin_key = ""
local last_online_options_deadline_active_key = ""
local last_online_options_preview_key = ""

local function online_options_trace(message)
	if type(online_logs_enabled) == "function" and not online_logs_enabled() then return end
	if type(online_flow_trace) == "function" then
		online_flow_trace("options_flow " .. tostring(message or ""))
	end
end

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
	if type(online_flow_trace) == "function" then
		online_flow_trace("options_ready_warning_tick remaining=" .. tostring(second)
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

local function online_options_deadline_key()
	if ITGOnline and ITGOnline.OnlineOptionsReadyKey then
		local ok, key = pcall(function() return ITGOnline:OnlineOptionsReadyKey() end)
		if ok then
			return tostring(key or "")
		end
	end
	return table.concat({
		tostring(ITGOnline and ITGOnline.currentRoomId or ""),
		tostring(ITGOnline and ITGOnline.currentRoom and ITGOnline.currentRoom.phase or ""),
		tostring(ITGOnline and ITGOnline.currentRoom and ITGOnline.currentRoom.selected_song and (
			ITGOnline.currentRoom.selected_song.selected_at
				or ITGOnline.currentRoom.selected_song.selectedAt
				or ITGOnline.currentRoom.selected_song.song_hash
				or ITGOnline.currentRoom.selected_song.songHash
				or ""
		) or "")
	}, "|")
end

local function reset_online_options_deadline_trace_state()
	last_online_options_deadline_begin_key = ""
	last_online_options_deadline_active_key = ""
end

local function begin_online_options_ready_deadline(actor, source)
	if not (ITGOnline and ITGOnline.BeginOnlineOptionsReadyDeadline and online_options_timeout_active()) then
		reset_online_options_deadline_trace_state()
		return nil
	end

	local key = online_options_deadline_key()
	local wasActive = key ~= "" and tostring(ITGOnline.onlineOptionsReadyDeadlineKey or "") == key
	local remaining = ITGOnline:BeginOnlineOptionsReadyDeadline(OPTIONS_READY_TIMEOUT_SECONDS, source)
	if remaining == nil then
		reset_online_options_deadline_trace_state()
		return nil
	end

	local traceKey = tostring(source or "unknown") .. "|" .. tostring(key)
	if not wasActive then
		last_online_options_deadline_begin_key = traceKey
		last_online_options_deadline_active_key = ""
		online_options_trace("ready_deadline_begin source=" .. tostring(source or "unknown")
			.. " seconds=" .. tostring(OPTIONS_READY_TIMEOUT_SECONDS)
			.. " room=" .. tostring(ITGOnline.currentRoomId or "nil")
			.. " key=" .. tostring(key ~= "" and key or "nil")
			.. " remaining=" .. tostring(math.ceil(remaining)))
	elseif last_online_options_deadline_active_key ~= traceKey then
		last_online_options_deadline_active_key = traceKey
		online_options_trace("ready_deadline_already_active source=" .. tostring(source or "unknown")
			.. " room=" .. tostring(ITGOnline.currentRoomId or "nil")
			.. " key=" .. tostring(key ~= "" and key or "nil")
			.. " remaining=" .. tostring(math.ceil(remaining)))
	end

	if actor then
		actor:queuecommand("UpdateOptionsReadyTimer")
	end
	return remaining
end

local function return_to_online_lobby()
	local screen = SCREENMAN:GetTopScreen()
	if not screen then return end
	screen:SetNextScreenName("ScreenOnlineLobbies")
	screen:StartTransitioningScreen("SM_GoToNextScreen")
end

local function play_online_options_preview_music(source, force)
	if not (ITGOnline and ITGOnline.currentRoom and play_online_preview_music_normal_rate) then
		online_options_trace("preview_skipped reason=missing_context source=" .. tostring(source or "nil")
			.. " hasClient=" .. tostring(ITGOnline ~= nil)
			.. " hasRoom=" .. tostring(ITGOnline and ITGOnline.currentRoom ~= nil)
			.. " hasPreviewApi=" .. tostring(play_online_preview_music_normal_rate ~= nil))
		return
	end
	local phase = ITGOnline.NormalizeRoomPhase and ITGOnline:NormalizeRoomPhase(ITGOnline.currentRoom.phase) or tostring(ITGOnline.currentRoom.phase or "")
	if phase ~= "config" then
		online_options_trace("preview_skipped reason=phase source=" .. tostring(source or "nil")
			.. " phase=" .. tostring(phase)
			.. " room=" .. tostring(ITGOnline.currentRoomId or "nil"))
		return
	end
	local songInfo = ITGOnline.currentRoom.selected_song or ITGOnline.currentSongPayload
	if type(songInfo) ~= "table" then
		online_options_trace("preview_skipped reason=no_song source=" .. tostring(source or "nil")
			.. " phase=" .. tostring(phase)
			.. " room=" .. tostring(ITGOnline.currentRoomId or "nil"))
		return
	end
	local previewKey = table.concat({
		tostring(ITGOnline.currentRoomId or ""),
		tostring(songInfo.selected_at or songInfo.selectedAt or ""),
		tostring(songInfo.song_hash or songInfo.songHash or songInfo.folder_name or ""),
	}, "|")
	if force ~= true and previewKey ~= "" and previewKey == last_online_options_preview_key then
		online_options_trace("preview_skipped reason=already_playing source=" .. tostring(source or "nil")
			.. " key=" .. tostring(previewKey))
		return
	end
	online_options_trace("preview_play source=" .. tostring(source or "nil")
		.. " phase=" .. tostring(phase)
		.. " room=" .. tostring(ITGOnline.currentRoomId or "nil")
		.. " title=" .. tostring(songInfo.title or songInfo.song_title or songInfo.folder_name or "nil")
		.. " pack=" .. tostring(songInfo.pack_name or songInfo.group_name or "nil")
		.. " rate=" .. tostring(ITGOnline.currentRoom.music_rate or ITGOnline.currentRoom.rate or "nil"))
	if play_online_preview_music_normal_rate(songInfo, source or "screen_player_options") then
		last_online_options_preview_key = previewKey
	else
		last_online_options_preview_key = ""
	end
end

local af = Def.ActorFrame{
	OnCommand=function(self)
		local screen = SCREENMAN:GetTopScreen()
		online_options_screen_name = screen and screen:GetName() or nil
		online_options_trace("screen_on screen=" .. tostring(online_options_screen_name or "nil")
			.. " room=" .. tostring(ITGOnline and ITGOnline.currentRoomId or "nil")
			.. " phase=" .. tostring(ITGOnline and ITGOnline.currentRoom and ITGOnline.currentRoom.phase or "nil")
			.. " timeoutActive=" .. tostring(online_options_timeout_active() == true)
			.. " afterP1=" .. tostring(SL.Global.ScreenAfter.PlayerOptions or "nil")
			.. " afterP2=" .. tostring(SL.Global.ScreenAfter.PlayerOptions2 or "nil")
			.. " afterP3=" .. tostring(SL.Global.ScreenAfter.PlayerOptions3 or "nil"))
		if ITGOnline and ITGOnline.currentRoomId then
			SL.Global.ScreenAfter.PlayerOptions = "ScreenOnlineLobbies"
			SL.Global.ScreenAfter.PlayerOptions2 = "ScreenOnlineLobbies"
			SL.Global.ScreenAfter.PlayerOptions3 = "ScreenOnlineLobbies"
		end
		if ITGOnline and ITGOnline.BeginOnlineOptionsReadyDeadline and online_options_timeout_active() then
			last_online_options_warning_second = nil
			begin_online_options_ready_deadline(self, "screen_player_options")
		end
		play_online_options_preview_music("screen_player_options_on", true)
	end,
	OnlineLobbyStateMessageCommand=function(self)
		online_options_trace("lobby_state_received screen=" .. tostring(online_options_screen_name or "nil")
			.. " room=" .. tostring(ITGOnline and ITGOnline.currentRoomId or "nil")
			.. " phase=" .. tostring(ITGOnline and ITGOnline.currentRoom and ITGOnline.currentRoom.phase or "nil")
			.. " timeoutActive=" .. tostring(online_options_timeout_active() == true)
			.. " ready=" .. tostring(ITGOnline and ITGOnline.currentRoom and ITGOnline.IsCurrentUserReadyInRoom and ITGOnline:IsCurrentUserReadyInRoom(ITGOnline.currentRoom) == true))
		begin_online_options_ready_deadline(self, "screen_player_options_state")
		play_online_options_preview_music("screen_player_options_state")
	end,
	OffCommand=function(self)
		last_online_options_preview_key = ""
		if not (ITGOnline and ITGOnline.currentRoomId) then
			online_options_trace("screen_off_skipped reason=no_room")
			return
		end
		if ITGOnline.ShouldSuppressOnlineConfigReadyOnOptionsExit
			and ITGOnline:ShouldSuppressOnlineConfigReadyOnOptionsExit() then
			online_options_trace("screen_off_skipped reason=suppress_config_ready_after_timeout"
				.. " room=" .. tostring(ITGOnline.currentRoomId or "nil")
				.. " phase=" .. tostring(ITGOnline.currentRoom and ITGOnline.currentRoom.phase or "nil"))
			return
		end

		local screen = SCREENMAN:GetTopScreen()
		local screenName = online_options_screen_name or (screen and screen:GetName()) or ""
		if online_next_screen_for_options(screenName) ~= "ScreenOnlineLobbies" then
			online_options_trace("screen_off_skipped reason=next_screen_not_lobby"
				.. " screen=" .. tostring(screenName)
				.. " next=" .. tostring(online_next_screen_for_options(screenName) or "nil"))
			return
		end
		local phase = ITGOnline.NormalizeRoomPhase and ITGOnline:NormalizeRoomPhase(ITGOnline.currentRoom and ITGOnline.currentRoom.phase) or tostring(ITGOnline.currentRoom and ITGOnline.currentRoom.phase or "")
		if phase ~= "config" then
			online_options_trace("screen_off_skipped reason=phase_not_config"
				.. " screen=" .. tostring(screenName)
				.. " room=" .. tostring(ITGOnline.currentRoomId or "nil")
				.. " phase=" .. tostring(ITGOnline.currentRoom and ITGOnline.currentRoom.phase or "nil"))
			return
		end
		if ITGOnline.IsCurrentUserReadyInRoom
			and ITGOnline:IsCurrentUserReadyInRoom(ITGOnline.currentRoom, "config_ready") then
			online_options_trace("screen_off_skipped reason=already_config_ready"
				.. " screen=" .. tostring(screenName)
				.. " room=" .. tostring(ITGOnline.currentRoomId or "nil")
				.. " phase=" .. tostring(ITGOnline.currentRoom and ITGOnline.currentRoom.phase or "nil"))
			return
		end

		online_options_trace("screen_off_config_ready_broadcast screen=" .. tostring(screenName)
			.. " room=" .. tostring(ITGOnline.currentRoomId or "nil")
			.. " phase=" .. tostring(ITGOnline.currentRoom and ITGOnline.currentRoom.phase or "nil"))
		MESSAGEMAN:Broadcast("OnlineConfigReady")
	end,

	UpdateOptionsReadyTimerCommand=function(self)
		local timer = self:GetChild("OnlineOptionsReadyTimer")
		if not timer then
			online_options_trace("timer_skipped reason=missing_actor")
			return
		end

		if not (ITGOnline and ITGOnline.OnlineOptionsReadyRemaining and online_options_timeout_active()) then
			last_online_options_warning_second = nil
			reset_online_options_deadline_trace_state()
			if last_online_options_timer_trace_key ~= "inactive" then
				last_online_options_timer_trace_key = "inactive"
				online_options_trace("timer_hidden reason=inactive"
					.. " room=" .. tostring(ITGOnline and ITGOnline.currentRoomId or "nil")
					.. " phase=" .. tostring(ITGOnline and ITGOnline.currentRoom and ITGOnline.currentRoom.phase or "nil"))
			end
			timer:visible(false)
			return
		end

		local remaining = ITGOnline:OnlineOptionsReadyRemaining()
		if remaining == nil then
			last_online_options_warning_second = nil
			reset_online_options_deadline_trace_state()
			if last_online_options_timer_trace_key ~= "nil_remaining" then
				last_online_options_timer_trace_key = "nil_remaining"
				online_options_trace("timer_hidden reason=nil_remaining room=" .. tostring(ITGOnline.currentRoomId or "nil"))
			end
			timer:visible(false)
			return
		end

		if remaining <= 0 then
			last_online_options_warning_second = nil
			reset_online_options_deadline_trace_state()
			online_options_trace("timer_expired room=" .. tostring(ITGOnline.currentRoomId or "nil")
				.. " phase=" .. tostring(ITGOnline.currentRoom and ITGOnline.currentRoom.phase or "nil"))
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
		local secondKey = tostring(math.ceil(remaining))
		if last_online_options_timer_trace_key ~= secondKey then
			last_online_options_timer_trace_key = secondKey
			online_options_trace("timer_visible remaining=" .. tostring(secondKey)
				.. " room=" .. tostring(ITGOnline.currentRoomId or "nil")
				.. " phase=" .. tostring(ITGOnline.currentRoom and ITGOnline.currentRoom.phase or "nil"))
		end
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
