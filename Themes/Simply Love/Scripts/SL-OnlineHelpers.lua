-- -----------------------------------------------------------------------
-- ALL ONLINE PLAY SOCKET STUFF

local isWaiting = false
local readyState = {
	["P1"] = true,
	["P2"] = true
}
local songSelected = false
-- Track Start button hold time for disconnect
local startHoldTime = {
	["P1"] = 0,
	["P2"] = 0
}
local lastDisconnectCountdown = nil
local lastSongPreviewSentAt = 0
local lastSongPreviewKey = ""
local lastOnlineOptionsSongKey = ""
local lastOnlineGameplayRoomId = nil
local pendingOnlineStartRoomId = nil
local pendingConfigReady = nil
local pendingOnlineSongSelectionKey = ""
local pendingOnlineSongSelectionAt = 0
local pendingOnlineSongSelectionToken = 0
local pendingManagerAutoReadyRetryKey = ""
local pendingManagerAutoReadyRetryPhase = ""
local lastWaitingDebugKey = ""
local lastFlowLobbyKey = ""
local replayDeferredLobbyStateQueued = false
local replayDeferredLobbyStateRunning = false
local UnlockOnlineInput
local onlineInputCallbacks = {}
-- These screens are the ones we want to display the player's scores for.
local scoreScreens = {"ScreenGameplay", "ScreenGameplayShared", "ScreenEvaluationStage", "ScreenEvaluationNonstop", "ScreenEvaluationSummary"}
local gameplayScreens = {
	["ScreenGameplay"] = true,
	["ScreenGameplayShared"] = true,
}
local evaluationScreens = {
	["ScreenEvaluationStage"] = true,
	["ScreenEvaluationNonstop"] = true,
	["ScreenEvaluationSummary"] = true,
}

local syncLockScreens = {
	["ScreenGameplay"] = true,
	["ScreenGameplayShared"] = true,
	["ScreenEvaluationStage"] = true,
	["ScreenEvaluationNonstop"] = true,
	["ScreenEvaluationSummary"] = true,
}

local autoReadyScreens = {
	["ScreenSelectMusic"] = true,
	["ScreenEvaluationStage"] = true,
	["ScreenEvaluationNonstop"] = true,
	["ScreenEvaluationSummary"] = true,
}

local knownDisconnectScreens = {
  ["ScreenTitleMenu"] = true,
  ["ScreenGameOver"] = true,
  ["ScreenNameEntryTraditional"] = true,
  ["ScreenOptionsService"] = true,
}

local DisplayLobbyState

local function is_evaluation_screen(screenName)
	return evaluationScreens[tostring(screenName or "")] == true
end

local function remove_online_input_callbacks()
	for key, callback in pairs(onlineInputCallbacks) do
		if callback and callback.screen and callback.handler and callback.screen.RemoveInputCallback then
			pcall(function() callback.screen:RemoveInputCallback(callback.handler) end)
		end
		onlineInputCallbacks[key] = nil
	end
end

local function replace_online_input_callback(screen, key, handler)
	if not screen or not handler then return end
	local callback = onlineInputCallbacks[key]
	if callback and callback.screen and callback.handler and callback.screen.RemoveInputCallback then
		pcall(function() callback.screen:RemoveInputCallback(callback.handler) end)
	end
	screen:AddInputCallback(handler)
	onlineInputCallbacks[key] = { screen = screen, handler = handler }
end

local function ready_debug_enabled()
	if ITGOnline and ITGOnline.debugReadyFlow ~= nil then
		return ITGOnline.debugReadyFlow == true
	end
	return false
end

local function ready_debug(message)
	if not ready_debug_enabled() then return end
	local line = "ITG Online ReadyFlow: " .. tostring(message or "")
	if online_trace then
		online_trace(line)
	elseif Warn then
		Warn(line)
	elseif Trace then
		Trace(line)
	end
end

-- Keep flow tracing safe in all contexts; never allow a missing logger
-- to break lobby state processing.
local function online_flow_trace(message)
	if not (ITGOnline and (ITGOnline.debugOnlineTrace == true or ITGOnline.debugReadyFlow == true)) then
		return
	end
	local line = tostring(message or "")
	if online_trace then
		online_trace("FLOW " .. line)
	elseif Trace then
		Trace("ITG Online FLOW: " .. line)
	elseif Warn then
		Warn("ITG Online FLOW: " .. line)
	end
end

local function maybe_set_lobby_ready(reason, callback)
	if not (ITGOnline and ITGOnline.SetReady) then
		if callback then callback(false) end
		return
	end

	local room = ITGOnline.currentRoom
	local phase = tostring(room and room.phase or "")
	if phase ~= "lobby" and phase ~= "lobby_ready" then
		ready_debug("skip lobby_ready reason=" .. tostring(reason or "unknown")
			.. " phase=" .. tostring(phase))
		if callback then callback(true, { room = room, skipped = true }) end
		return
	end

	if ITGOnline.IsCurrentUserReadyInRoom and ITGOnline:IsCurrentUserReadyInRoom(room) then
		ready_debug("skip lobby_ready reason=" .. tostring(reason or "unknown")
			.. " already_ready=1")
		if callback then callback(true, { room = room, skipped = true }) end
		return
	end

	ITGOnline:SetReady("lobby_ready", true, callback)
end

local function maybe_preview_current_online_song(force)
	if not (ITGOnline
		and ITGOnline.PreviewSong
		and ITGOnline.currentRoomId
		and ITGOnline.currentRoom
		and ITGOnline.user) then
		return
	end

	local phase = ITGOnline.NormalizeRoomPhase and ITGOnline:NormalizeRoomPhase(ITGOnline.currentRoom.phase) or tostring(ITGOnline.currentRoom.phase or "")
	if phase ~= "lobby" then
		return
	end

	if ITGOnline.currentRoom.selected_song ~= nil then
		return
	end

	local manager = ITGOnline.currentRoom.manager
	if not manager or tonumber(manager.id) ~= tonumber(ITGOnline.user.id) then
		return
	end

	local song = GAMESTATE:GetCurrentSong()
	if not song then return end

	local now = GetTimeSinceStart()
	local key = song:GetSongDir() or song:GetDisplayFullTitle() or ""
	if not force and key == lastSongPreviewKey and now - lastSongPreviewSentAt < 1.5 then
		return
	end

	ITGOnline:PreviewSong(function(ok)
		if ok then
			lastSongPreviewKey = key
			lastSongPreviewSentAt = now
		end
	end)
end

local function split_online_song_path(path)
	path = tostring(path or "")
	local pack, song = path:match("^([^/]+)/(.+)$")
	if pack then
		return pack, song
	end
	return path, nil
end

local OnlineStartCountdownText = function()
	if not (ITGOnline and ITGOnline.SecondsUntilScheduledStart) then return nil end

	local seconds = ITGOnline:SecondsUntilScheduledStart()
	if not seconds then return nil end

	if seconds > 0 then
		return "La chanson demarre dans " .. tostring(math.ceil(seconds)) .. "..."
	end

	return "Chanson demarree. Synchronisation audio..."
end

local OnlinePlayingSpinner = function()
	local frames = { "|", "/", "-", "\\" }
	return frames[(math.floor(GetTimeSinceStart() * 6) % #frames) + 1]
end

local FormatRemainingSeconds = function(value)
	local seconds = math.max(0, math.ceil(tonumber(value) or 0))
	local minutes = math.floor(seconds / 60)
	local remainder = seconds % 60
	return string.format("%d:%02d", minutes, remainder)
end

local OnlineRemainingText = function(data)
	if not data then return nil end

	local remaining = nil
	local estimatedEndAtMs = tonumber(data.estimatedEndAtMs)
	if estimatedEndAtMs then
		local estimatedServerNowMs = nil
		if ITGOnline and ITGOnline.serverClockOffsetSeconds ~= nil then
			estimatedServerNowMs = (GetTimeSinceStart() + tonumber(ITGOnline.serverClockOffsetSeconds)) * 1000
		end

		if estimatedServerNowMs then
			remaining = math.max(0, (estimatedEndAtMs - estimatedServerNowMs) / 1000)
		end
	end

	if remaining == nil then
		local snapshotRemaining = tonumber(data.remainingSeconds)
		if snapshotRemaining ~= nil then
			local receivedAt = tonumber(data.__receivedLocalTime)
			if receivedAt ~= nil then
				remaining = math.max(0, snapshotRemaining - (GetTimeSinceStart() - receivedAt))
			else
				remaining = snapshotRemaining
			end
		end
	end

	if remaining == nil then return nil end
	return "Joueurs encore en chanson : " .. FormatRemainingSeconds(remaining) .. " restantes"
end

local QueueOnlineGameplayStartRelease = function(actor)
	if actor and not actor.onlineStartReleaseQueued then
		actor.onlineStartReleaseQueued = true
		actor:sleep(0.05):queuecommand("ReleaseOnlineGameplayAtStart")
	end
end

local lastGameplayPauseScreen = nil
local lastGameplayPauseState = nil
local SetGameplayPaused = function(screen, paused)
	if not screen then return end

	local screenName = screen.GetName and screen:GetName() or ""
	local isGameplay = gameplayScreens[screenName] == true
	local screenKey = tostring(screen)
	paused = paused == true

	if isGameplay and lastGameplayPauseScreen == screenKey and lastGameplayPauseState == paused then
		return
	end

	screen:PauseGame(paused)
	if isGameplay then
		lastGameplayPauseScreen = screenKey
		lastGameplayPauseState = paused
	else
		lastGameplayPauseScreen = nil
		lastGameplayPauseState = nil
	end
end

local ReleaseOnlineGameplay = function(screen, secondsUntilStart)
	local lateBy = secondsUntilStart and math.max(0, -secondsUntilStart) or 0
	if online_trace then
		online_trace("FLOW release_gameplay screen=" .. tostring(screen and screen:GetName() or "nil")
			.. " secondsUntilStart=" .. tostring(secondsUntilStart)
			.. " lateBy=" .. tostring(lateBy)
			.. " phase=" .. tostring(ITGOnline and ITGOnline.currentRoom and ITGOnline.currentRoom.phase or "no-room"))
	end
	if screen and lateBy > 0.03 and screen.SeekMusicSeconds then
		screen:SeekMusicSeconds(lateBy)
	end

	UnlockOnlineInput()
	SetGameplayPaused(screen, false)
	if ITGOnline and ITGOnline.Heartbeat then ITGOnline:Heartbeat("playing") end
end

-- This input handler is used to lock input while we're waiting on the server to tell us to proceed.
-- It does nothing, but it's necessary to prevent the player from interacting with the screen
-- until everyone is ready.
-- Holding Start for 5 seconds will disconnect from the lobby.
local InputHandler = function(event)
	local topScreen = SCREENMAN:GetTopScreen()
	if topScreen and isWaiting and event.PlayerNumber then
		local pn = ToEnumShortString(event.PlayerNumber)
		if event.type == "InputEventType_FirstPress" and event.GameButton == "Back" then
			isWaiting = false
			UnlockOnlineInput()
			if ITGOnline and ITGOnline.MarkReturnedToLobby then
				ITGOnline:MarkReturnedToLobby()
			end
			if topScreen:GetName() ~= "ScreenOnlineLobbies" then
				topScreen:SetNextScreenName("ScreenOnlineLobbies")
				topScreen:StartTransitioningScreen("SM_GoToNextScreen")
			end
			return true
		elseif event.type == "InputEventType_FirstPress" and event.GameButton == "Start" then
			startHoldTime[pn] = GetTimeSinceStart()
			lastDisconnectCountdown = nil
			if topScreen:GetName() == "ScreenGameplay" then
				readyState[pn] = true
				MESSAGEMAN:Broadcast("UpdateMachineState")
			end
		elseif event.type == "InputEventType_Repeat" and event.GameButton == "Start" then
			-- Check if Start has been held for 5 seconds
			if startHoldTime[pn] > 0 then
				local holdDuration = GetTimeSinceStart() - startHoldTime[pn]
				local remainingSeconds = math.max(0, 5 - math.floor(holdDuration))
				if remainingSeconds ~= lastDisconnectCountdown then
					SM("Maintenez &START; encore " .. remainingSeconds .. " secondes pour vous deconnecter...")
					lastDisconnectCountdown = remainingSeconds
				end
					if holdDuration >= 5.0 then
					SM("Deconnecte du salon.")
					startHoldTime[pn] = 0
					lastDisconnectCountdown = nil
						isWaiting = false
						local topScreen = SCREENMAN:GetTopScreen()
						if topScreen and topScreen:GetName() == "ScreenGameplay" then
							SetGameplayPaused(topScreen, false)
						end
						if ITGOnline and ITGOnline.MarkReturnedToLobby then
							ITGOnline:MarkReturnedToLobby()
						end
						MESSAGEMAN:Broadcast("DisconnectOnline", {leaveRoom=true})
					end
			end
		elseif event.type == "InputEventType_Release" and event.GameButton == "Start" then
			startHoldTime[pn] = 0
			lastDisconnectCountdown = nil
		end
	end

	return false
end

local OnlineOptionsInputHandler = function(event)
	if not (ITGOnline and ITGOnline.currentRoomId) then return false end
	if not event or event.type ~= "InputEventType_FirstPress" then return false end

	local deviceButton = ""
	if event.DeviceInput and event.DeviceInput.button then
		deviceButton = string.lower(tostring(event.DeviceInput.button))
	end

	local isBack = event.GameButton == "Back" or string.find(deviceButton, "backspace", 1, true) ~= nil
	local isEscape = string.find(deviceButton, "escape", 1, true) ~= nil
	if isBack or isEscape then
		if online_trace then
			online_trace("FLOW online_options_back_blocked room=" .. tostring(ITGOnline.currentRoomId)
				.. " phase=" .. tostring(ITGOnline.currentRoom and ITGOnline.currentRoom.phase or "no-room")
				.. " button=" .. tostring(event.GameButton or "")
				.. " device=" .. tostring(deviceButton))
		end
		return true
	end

	return false
end

UnlockOnlineInput = function()
	isWaiting = false
	for player in ivalues(PlayerNumber) do
		SCREENMAN:set_input_redirected(player, false)
	end
end

local OnlineGameplayScreen = function()
	local style = GAMESTATE:GetCurrentStyle() and GAMESTATE:GetCurrentStyle():GetName() or ""
	return style == "routine" and "ScreenGameplayShared" or "ScreenGameplay"
end

local OnlineSongKey = function(data)
	if not data or not data.songInfo then return "" end
	return tostring(data.roomId or data.code or "")
		.. "|" .. tostring(data.songInfo.roundId or "")
		.. "|" .. tostring(data.songInfo.songHash or "")
		.. "|" .. tostring(data.songInfo.chartHash or data.songInfo.songPath or "")
		.. "|" .. tostring(data.songInfo.selectedAt or "")
end

local CurrentUserInLobbyState = function(data)
	if not (data and data.players and ITGOnline and ITGOnline.user) then return false end
	local selfId = tostring(ITGOnline.user.id or "")
	if selfId == "" then return false end
	for _, player in ipairs(data.players) do
		if tostring(player and player.playerId or "") == selfId then
			return true
		end
	end
	return false
end

local ApplyOnlineSongSelection = function(songInfo)
	if not songInfo or not songInfo.songPath then return false end
	if ITGOnline and ITGOnline.PackSync and ITGOnline.PackSync.ApplySelectedChart then
		online_flow_trace("pack_sync_apply_selected_chart title=" .. tostring(songInfo.title or songInfo.name or "")
			.. " pack=" .. tostring(songInfo.pack or "")
			.. " path=" .. tostring(songInfo.songPath or songInfo.folder_name or "")
			.. " selected_at=" .. tostring(songInfo.selectedAt or songInfo.selected_at or "")
			.. " chart_hash=" .. tostring(songInfo.chartHash or songInfo.chart_hash or ""):sub(1, 12))
		return ITGOnline.PackSync:ApplySelectedChart(songInfo)
	end

	online_flow_trace("legacy_apply_song_selection title=" .. tostring(songInfo.title or songInfo.name or "")
		.. " pack=" .. tostring(songInfo.pack or "")
		.. " path=" .. tostring(songInfo.songPath or songInfo.folder_name or ""))
	local previousSong = GAMESTATE:GetCurrentSong()
	local previousSteps = {}
	for player in ivalues(GAMESTATE:GetEnabledPlayers()) do
		previousSteps[player] = GAMESTATE:GetCurrentSteps(player)
	end
	local restorePreviousSelection = function()
		GAMESTATE:SetCurrentSong(previousSong)
		for player, steps in pairs(previousSteps) do
			GAMESTATE:SetCurrentSteps(player, steps)
		end
	end

	local song = SONGMAN:FindSong(songInfo.songPath)
	local _, songFolder = split_online_song_path(songInfo.songPath)
	if not song and songFolder then
		song = SONGMAN:FindSong(songFolder)
	end
	if not song then
		online_flow_trace("legacy_apply_song_selection_missing_song path=" .. tostring(songInfo.songPath))
		SM("Chanson online introuvable localement : " .. tostring(songInfo.songPath))
		MESSAGEMAN:Broadcast("OnlineMissingSong", {songInfo=songInfo})
		return false
	end

	local stepsType = GAMESTATE:GetCurrentStyle() and GAMESTATE:GetCurrentStyle():GetStepsType() or nil
	local matchedSteps = nil
	local requiresExactChartHash = stepsType and songInfo.chartHash and songInfo.chartHash ~= "" and ITGOnline and ITGOnline.ChartHashForSteps
	if requiresExactChartHash then
		for steps in ivalues(song:GetStepsByStepsType(stepsType)) do
			if ITGOnline:ChartHashForSteps(steps) == songInfo.chartHash then
				matchedSteps = steps
				break
			end
		end
	end

	if requiresExactChartHash and not matchedSteps then
		online_flow_trace("legacy_apply_song_selection_chart_hash_missing path=" .. tostring(songInfo.songPath)
			.. " chart_hash=" .. tostring(songInfo.chartHash or ""):sub(1, 12))
		SM("Chart online introuvable localement pour : " .. tostring(songInfo.songPath))
		MESSAGEMAN:Broadcast("OnlineMissingSong", {songInfo=songInfo, reason="chart_hash_mismatch"})
		restorePreviousSelection()
		return false
	end

	if stepsType and not requiresExactChartHash then
		for steps in ivalues(song:GetStepsByStepsType(stepsType)) do
			if matchedSteps then break end
			local difficultyMatches = songInfo.difficulty == nil or songInfo.difficulty == "" or ToEnumShortString(steps:GetDifficulty()) == songInfo.difficulty
			local meterMatches = songInfo.meter == nil or tonumber(songInfo.meter) == nil or steps:GetMeter() == tonumber(songInfo.meter)
			if difficultyMatches and meterMatches then
				matchedSteps = steps
				break
			end
		end
	end

	if not matchedSteps then
		for steps in ivalues(SongUtil.GetPlayableSteps(song)) do
			matchedSteps = steps
			break
		end
	end

	local localPayload = nil
	if ITGOnline and ITGOnline.BuildSongPayloadFor then
		localPayload = ITGOnline:BuildSongPayloadFor(song, matchedSteps)
	elseif ITGOnline and ITGOnline.BuildSongPayload then
		GAMESTATE:SetCurrentSong(song)
		if matchedSteps then
			for player in ivalues(GAMESTATE:GetEnabledPlayers()) do
				GAMESTATE:SetCurrentSteps(player, matchedSteps)
			end
		end
		localPayload = ITGOnline:BuildSongPayload()
		restorePreviousSelection()
	end

	local requiresHashVerification = (songInfo.songHash and songInfo.songHash ~= "")
		or (songInfo.chartHash and songInfo.chartHash ~= "")
	if requiresHashVerification and not localPayload then
		online_flow_trace("legacy_apply_song_selection_payload_unavailable path=" .. tostring(songInfo.songPath))
		SM("Chanson online impossible a verifier localement : " .. tostring(songInfo.songPath))
		MESSAGEMAN:Broadcast("OnlineMissingSong", {songInfo=songInfo, reason="local_payload_unavailable"})
		restorePreviousSelection()
		return false
	end

	if localPayload then
		if songInfo.songHash and songInfo.songHash ~= "" and localPayload.song_hash ~= songInfo.songHash then
			online_flow_trace("legacy_apply_song_selection_song_hash_mismatch path=" .. tostring(songInfo.songPath)
				.. " expected=" .. tostring(songInfo.songHash):sub(1, 12)
				.. " local=" .. tostring(localPayload.song_hash):sub(1, 12))
			SM("Hash audio online different pour : " .. tostring(songInfo.songPath))
			MESSAGEMAN:Broadcast("OnlineMissingSong", {songInfo=songInfo, reason="hash_mismatch"})
			restorePreviousSelection()
			return false
		end
		if songInfo.chartHash and songInfo.chartHash ~= "" and localPayload.chart_hash ~= songInfo.chartHash then
			online_flow_trace("legacy_apply_song_selection_chart_hash_mismatch path=" .. tostring(songInfo.songPath)
				.. " expected=" .. tostring(songInfo.chartHash):sub(1, 12)
				.. " local=" .. tostring(localPayload.chart_hash):sub(1, 12))
			SM("Hash chart online different pour : " .. tostring(songInfo.songPath))
			MESSAGEMAN:Broadcast("OnlineMissingSong", {songInfo=songInfo, reason="hash_mismatch"})
			restorePreviousSelection()
			return false
		end
	end

	GAMESTATE:SetCurrentSong(song)
	if matchedSteps then
		for player in ivalues(GAMESTATE:GetEnabledPlayers()) do
			GAMESTATE:SetCurrentSteps(player, matchedSteps)
		end
	end

	MESSAGEMAN:Broadcast("OnlineSongAvailable", {songInfo=songInfo})
	online_flow_trace("legacy_apply_song_selection_success path=" .. tostring(songInfo.songPath))
	return true
end

local TransitionToOnlineOptions = function()
	local topScreen = SCREENMAN:GetTopScreen()
	if not topScreen then return end

	local screenName = topScreen:GetName()
	if screenName == "ScreenPlayerOptions"
		or screenName == "ScreenPlayerOptions2"
		or screenName == "ScreenPlayerOptions3"
		or screenName == "ScreenGameplay"
		or screenName == "ScreenGameplayShared" then
		return
	end

	if is_evaluation_screen(screenName) then
		if online_trace then
			online_trace("FLOW transition_to_options_deferred reason=evaluation_screen"
				.. " screen=" .. tostring(screenName)
				.. " phase=" .. tostring(ITGOnline and ITGOnline.currentRoom and ITGOnline.currentRoom.phase or "no-room"))
		end
		return
	end

	if online_trace then
		online_trace("FLOW transition_to_options from=" .. tostring(screenName)
			.. " phase=" .. tostring(ITGOnline and ITGOnline.currentRoom and ITGOnline.currentRoom.phase or "no-room"))
	end
	if not (topScreen.SetNextScreenName and topScreen.StartTransitioningScreen) then
		if online_trace then
			online_trace("FLOW transition_to_options_skipped reason=screen_cannot_transition"
				.. " screen=" .. tostring(screenName))
		end
		return
	end
	topScreen:SetNextScreenName("ScreenPlayerOptions")
	topScreen:StartTransitioningScreen("SM_GoToNextScreen")
end

local OnlineDeferredReplayBlockedScreen = function(screenName)
	screenName = tostring(screenName or "")
	return screenName == "ScreenReloadSongsOnline"
		or screenName == "ScreenReloadSongs"
		or screenName == "ScreenReloadSSM"
		or screenName:find("ReloadSongs", 1, true) ~= nil
end

local OnlinePayloadMatchesActiveRoom = function(payload)
	if not (payload and ITGOnline and ITGOnline.currentRoomId and ITGOnline.currentRoom and ITGOnline.user) then
		return false
	end

	local payloadRoomId = tostring(payload.roomId or payload.room_id or payload.id or "")
	if payloadRoomId == "" or payloadRoomId ~= tostring(ITGOnline.currentRoomId or "") then
		return false
	end
	if tostring(ITGOnline.currentRoom.id or "") ~= tostring(ITGOnline.currentRoomId or "") then
		return false
	end

	local currentUserId = tostring(ITGOnline.user.id or "")
	if currentUserId == "" then return false end
	for member in ivalues(ITGOnline.currentRoom.members or {}) do
		local user = member and member.user or nil
		if tostring(member and (member.user_id or member.userId) or "") == currentUserId
			or tostring(user and user.id or "") == currentUserId then
			return true
		end
	end
	return false
end

local CurrentOnlineSelectionKey = function()
	if not (ITGOnline and ITGOnline.currentRoomId) then return "" end

	local song = GAMESTATE:GetCurrentSong()
	local songKey = song and (song:GetSongDir() or song:GetDisplayFullTitle()) or "no-song"
	local stepsHash = "no-steps"
	local enabled = GAMESTATE:GetEnabledPlayers()
	local player = enabled and enabled[1] or nil
	local steps = player and GAMESTATE:GetCurrentSteps(player) or nil
	if steps then
		if ITGOnline.ChartHashForSteps then
			stepsHash = ITGOnline:ChartHashForSteps(steps)
		else
			stepsHash = tostring(steps.GetHash and steps:GetHash() or "steps")
		end
	end

	local rate = 1
	if ITGOnline.CurrentGlobalOptions then
		local options = ITGOnline:CurrentGlobalOptions()
		rate = tonumber(options and options.music_rate) or rate
	end

	return tostring(ITGOnline.currentRoomId) .. "|" .. tostring(songKey) .. "|" .. tostring(stepsHash) .. "|" .. tostring(rate)
end

local SelectOnlineSongAsManager = function(actor)
	if not (ITGOnline and ITGOnline.currentRoomId) then
		online_flow_trace("song_selected_ignored reason=no_room")
		return
	end

	local selectionKey = CurrentOnlineSelectionKey()
	local now = GetTimeSinceStart()
	if pendingOnlineSongSelectionKey == selectionKey and (now - pendingOnlineSongSelectionAt) < 12 then
		online_flow_trace("song_selected_ignored reason=selection_inflight key=" .. tostring(selectionKey))
		return
	end
	pendingOnlineSongSelectionKey = selectionKey
	pendingOnlineSongSelectionAt = now
	pendingOnlineSongSelectionToken = pendingOnlineSongSelectionToken + 1
	local selectionToken = pendingOnlineSongSelectionToken

	local clearPendingSelection = function()
		if pendingOnlineSongSelectionKey == selectionKey and pendingOnlineSongSelectionToken == selectionToken then
			pendingOnlineSongSelectionKey = ""
		end
	end

	local finishSelection = function(room)
		if pendingOnlineSongSelectionKey ~= selectionKey or pendingOnlineSongSelectionToken ~= selectionToken then
			online_flow_trace("song_selected_ignored reason=stale_selection_callback key=" .. tostring(selectionKey))
			return
		end

		if not (ITGOnline and ITGOnline.currentRoomId) then
			clearPendingSelection()
			return
		end

		if not ITGOnline.user then
			clearPendingSelection()
			online_flow_trace("song_selected_ignored reason=no_user_after_room_sync room=" .. tostring(ITGOnline.currentRoomId))
			MESSAGEMAN:Broadcast("OnlineResponseStatus", {
				event="selectSong",
				success=false,
				message="Session online indisponible. Reconnecte-toi au mode online."
			})
			return
		end

		if not (ITGOnline.IsCurrentUserRoomManager and ITGOnline:IsCurrentUserRoomManager(room)) then
			clearPendingSelection()
			online_flow_trace("song_selected_ignored reason=not_manager room=" .. tostring(ITGOnline.currentRoomId))
			return
		end

		if not ITGOnline.SelectSongAndMarkLobbyReady then
			clearPendingSelection()
			online_flow_trace("song_selected_ignored reason=no_selection_api room=" .. tostring(ITGOnline.currentRoomId))
			return
		end

		pendingOnlineSongSelectionAt = GetTimeSinceStart()
		if actor then actor.inLobby = true end
		online_flow_trace("song_selected_handler room=" .. tostring(ITGOnline.currentRoomId)
			.. " socket=" .. tostring(actor and actor.socket ~= nil)
			.. " phase=" .. tostring(room and room.phase or "no-room")
			.. " key=" .. tostring(selectionKey))

		ITGOnline:SelectSongAndMarkLobbyReady(function(ok, decoded, response)
			if pendingOnlineSongSelectionKey == selectionKey and pendingOnlineSongSelectionToken == selectionToken then
				pendingOnlineSongSelectionKey = ""
			end

			if ok then
				online_flow_trace("song_selected_handler_ok transition=options")
				TransitionToOnlineOptions()
				return
			end

			online_flow_trace("song_selected_handler_failed status=" .. tostring(response and response.statusCode or "nil")
				.. " error=" .. tostring(decoded and decoded.error_code or response and response.error or "nil"))
			MESSAGEMAN:Broadcast("OnlineResponseStatus", {
				event="selectSong",
				success=false,
				message=(decoded and decoded.message) or (response and response.errorMessage) or "Echec de selection de la chanson."
			})
		end)
	end

	if ITGOnline.EnsureCurrentRoom then
		ITGOnline:EnsureCurrentRoom(function(ok, room, response)
			if ok and room then
				finishSelection(room)
				return
			end

			clearPendingSelection()
			online_flow_trace("song_selected_ignored reason=room_sync_failed status=" .. tostring(response and response.statusCode or "nil"))
			MESSAGEMAN:Broadcast("OnlineResponseStatus", {
				event="selectSong",
				success=false,
				message=(response and response.errorMessage) or "Impossible de recuperer l'etat du salon."
			})
		end)
		return
	end

	finishSelection(ITGOnline.currentRoom)
end

local TransitionToOnlineGameplay = function()
	local topScreen = SCREENMAN:GetTopScreen()
	if not topScreen then return end

	local screenName = topScreen:GetName()
	if screenName == "ScreenGameplay" or screenName == "ScreenGameplayShared" then
		SL.Global.Online = SL.Global.Online or {}
		SL.Global.Online.GameplayLayoutActive = true
		return
	end

	if online_trace then
		online_trace("FLOW transition_to_gameplay from=" .. tostring(screenName)
			.. " phase=" .. tostring(ITGOnline and ITGOnline.currentRoom and ITGOnline.currentRoom.phase or "no-room")
			.. " pendingRoom=" .. tostring(pendingOnlineStartRoomId))
	end
	SL.Global.Online = SL.Global.Online or {}
	SL.Global.Online.GameplayLayoutActive = true
	topScreen:SetNextScreenName(OnlineGameplayScreen())
	topScreen:StartTransitioningScreen("SM_GoToNextScreen")
end

local ReturnToOnlineLobbyFromMusicSelect = function()
	local topScreen = SCREENMAN:GetTopScreen()
	if not topScreen or topScreen:GetName() ~= "ScreenSelectMusic" then return false end
	if not (ITGOnline and ITGOnline.currentRoomId) then return false end

	UnlockOnlineInput()
	if topScreen.ReturnToOnlineLobbyFromMusicSelect then
		topScreen:ReturnToOnlineLobbyFromMusicSelect()
		return true
	end

	topScreen:SetNextScreenName("ScreenOnlineLobbies")
	topScreen:StartTransitioningScreen("SM_GoToNextScreen")
	return true
end

local PollOnlineStart = function(actor, roomId)
	if not actor or not roomId or not (ITGOnline and ITGOnline.FetchRoom) then return end

	local timer = actor:GetChild("OnlineStartPollTimer")
	if not timer then return end

	pendingOnlineStartRoomId = roomId
	timer:stoptweening()
	timer:sleep(1):queuecommand("Poll")
end

local SelectMusicInputHandler = function(event)
	if not event or event.type ~= "InputEventType_FirstPress" then return false end

	local deviceButton = ""
	if event.DeviceInput and event.DeviceInput.button then
		deviceButton = string.lower(tostring(event.DeviceInput.button))
	end

	if event.GameButton == "Back" or string.find(deviceButton, "backspace", 1, true) then
		SOUND:PlayOnce(THEME:GetPathS("Common", "Cancel"))
		return ReturnToOnlineLobbyFromMusicSelect()
	end

	return false
end

local ReturnToOnlineLobbyFromEvaluation = function(reason)
	local topScreen = SCREENMAN:GetTopScreen()
	if not topScreen then return false end
	if not evaluationScreens[topScreen:GetName()] then return false end
	if not (ITGOnline and ITGOnline.currentRoomId) then return false end

	UnlockOnlineInput()
	ITGOnline.onlineEvaluationExitRequested = true
	if online_trace then
		online_trace("FLOW evaluation_exit_requested reason=" .. tostring(reason or "input")
			.. " screen=" .. tostring(topScreen:GetName())
			.. " phase=" .. tostring(ITGOnline.currentRoom and ITGOnline.currentRoom.phase or ITGOnline.currentRoomPhase))
	end
	topScreen:SetNextScreenName("ScreenOnlineLobbies")
	topScreen:StartTransitioningScreen("SM_GoToNextScreen")
	return true
end

ITGOnlineReturnToLobbyFromEvaluation = ReturnToOnlineLobbyFromEvaluation

local EvaluationInputHandler = function(event)
	if not event or event.type ~= "InputEventType_FirstPress" then return false end
	if not (ITGOnline and ITGOnline.currentRoomId) then return false end

	local deviceButton = ""
	if event.DeviceInput and event.DeviceInput.button then
		deviceButton = string.lower(tostring(event.DeviceInput.button))
	end

	local isEscape = string.find(deviceButton, "escape", 1, true)
		or string.find(deviceButton, "backspace", 1, true)
	local isConfirm = event.GameButton == "Start"
	local isBack = event.GameButton == "Back"

	if isConfirm or isBack or isEscape then
		return ReturnToOnlineLobbyFromEvaluation("evaluation_input")
	end

	return false
end

local RestoreCurrentRoom = function(actor, callback)
	if not (ITGOnline and ITGOnline.FetchCurrentRoom) then
		if callback then callback(false) end
		return
	end

	ITGOnline:FetchCurrentRoom(function(ok, decoded, response)
		if ok and decoded and decoded.room then
			actor.inLobby = true
			local payload = ITGOnline:LobbyStatePayload(decoded.room)
			DisplayLobbyState(payload, actor)
			MESSAGEMAN:Broadcast("OnlineLobbyState", payload)
			ITGOnline:Heartbeat("in_room")
			if callback then callback(true) end
			return
		end

		if ITGOnline.CurrentRoomConflictCode then
			local conflictCode = ITGOnline:CurrentRoomConflictCode(decoded, response)
			if conflictCode ~= "" then
				actor.inLobby = false
				if callback then callback(false) end
				return
			end
		end

		actor.inLobby = false
		ITGOnline:Heartbeat("available")
		if callback then callback(false) end
	end)
end

local OrderPlayers = function(data, localScreenName)
	local updatedData = {
		players = {},

		-- Additional data that we can pre-calculate.
		aux = {
			-- Used to give input back to the players if we're waiting.
			allInSameScreen = true,
			-- Evaluation should stay locked only while any player is still in gameplay.
			anyInGameplay = false,
			-- Used to determine when to display the Ready/Not Ready state for players.
			allPlayersReady = true,
		}
	}

	--  Copy over the song info, if any.
	updatedData.songInfo = data.songInfo

	-- Use the current screen as the baseline to prevent
	-- incorrectly reporting all players as synchronized.
	local firstScreen = localScreenName
	-- Process the scoreScreens first so we can sort the players by score.
	for player in ivalues(data.players) do
		if firstScreen == nil then
			firstScreen = player.screenName
		end

		if player.screenName ~= firstScreen then
			updatedData.aux.allInSameScreen = false
		end

		if gameplayScreens[player.screenName] then
			updatedData.aux.anyInGameplay = true
		end

		if not player.ready then
			updatedData.aux.allPlayersReady = false
		end

		for screen in ivalues(scoreScreens) do
			if player.screenName == screen then
				updatedData.players[#updatedData.players+1] = player
				break
			end
		end
	end

	-- Sort by the same canonical percentage displayed in the online leaderboard.
	table.sort(updatedData.players, function(a, b)
		local aScore = tonumber(a.score)
		local bScore = tonumber(b.score)
		if aScore == nil then aScore = tonumber(a.exScore) end
		if bScore == nil then bScore = tonumber(b.exScore) end
		if aScore == nil then
			return false
		end
		if bScore == nil then
			return true
		end
		return aScore > bScore
	end)

	-- Then add all the other players in other screens below.
	for player in ivalues(data.players) do
		if firstScreen == nil then
			firstScreen = player.screenName
		end

		if player.screenName ~= firstScreen then
			updatedData.aux.allInSameScreen = false
		end

		if gameplayScreens[player.screenName] then
			updatedData.aux.anyInGameplay = true
		end

		if not player.ready then
			updatedData.aux.allPlayersReady = false
		end

		local inScoreScreen = false
		for screen in ivalues(scoreScreens) do
			if player.screenName == screen then
				inScoreScreen = true
				break
			end
		end

		if not inScoreScreen then
			updatedData.players[#updatedData.players+1] = player
		end
	end

	return updatedData
end

DisplayLobbyState = function(data, actor)
	if not actor or not actor.GetChild then return end
	-- Keep in mind that SCREENMAN:GetTopScreen() might return nil while screens transition.
	local screen = SCREENMAN:GetTopScreen()
	local screenName = screen and screen:GetName() or "NoScreen"
	startHoldTime = { ["P1"] = 0, ["P2"] = 0 }
	lastDisconnectCountdown = nil
	local flowLobbyKey = table.concat({
		tostring(data and data.roomId or ""),
		tostring(data and data.phase or ""),
		tostring(screenName),
		tostring(data and data.startAt or ""),
		tostring(data and data.startedAt or ""),
		tostring(data and data.playState and #(data.playState.sessions or {}) or 0),
		tostring(data and data.finalResults and #data.finalResults or 0),
	}, "|")
	if flowLobbyKey ~= lastFlowLobbyKey then
		lastFlowLobbyKey = flowLobbyKey
		if online_trace then
			online_trace("FLOW display_lobby room=" .. tostring(data and data.roomId or "")
				.. " phase=" .. tostring(data and data.phase or "")
				.. " screen=" .. tostring(screenName)
				.. " startAt=" .. tostring(data and data.startAt or "")
				.. " startedAt=" .. tostring(data and data.startedAt or "")
				.. " sessions=" .. tostring(data and data.playState and #(data.playState.sessions or {}) or 0)
				.. " finalResults=" .. tostring(data and data.finalResults and #data.finalResults or 0))
		end
	end

	local updatedData = OrderPlayers(data, screenName)

	local lines = {}

	if isWaiting then
		local readyToUnlock = false
		local playerCount = #updatedData.players
		if gameplayScreens[screenName] then
			-- Gameplay no longer uses manual ready-up; we only wait for screen synchronization.
			readyToUnlock = updatedData.aux.allInSameScreen or playerCount <= 1
		elseif evaluationScreens[screenName] then
			-- Evaluation should only be blocked while someone is still playing.
			readyToUnlock = not updatedData.aux.anyInGameplay
		elseif autoReadyScreens[screenName] then
			-- Other auto-ready screens require everyone to arrive at the same screen.
			readyToUnlock = updatedData.aux.allInSameScreen
		else
			readyToUnlock = updatedData.aux.allPlayersReady
		end

		if screenName == "ScreenSelectMusic" and data.songInfo ~= nil then
			-- If we're navigating back to screen select music (say from options),
			-- then don't lock input as we will have already synced before.
			-- In this case a song will have been selected already.
			-- However, if someone is still in EvaluationStage, we are transitioning
			-- eval -> music and should keep input locked until everyone arrives.
			local anyInEval = false
			for _, player in ipairs(updatedData.players or {}) do
				if type(player) == "table" and evaluationScreens[player.screenName] then
					anyInEval = true
					break
				end
			end
			if not anyInEval then
				readyToUnlock = true
			end
			end

			if readyToUnlock and gameplayScreens[screenName] and data.phase == "starting" then
				QueueOnlineGameplayStartRelease(actor)
			elseif readyToUnlock then
			isWaiting = false
			-- Lift the lock.
			-- SCREENMAN:GetTopScreen():RemoveInputCallback(InputHandler)

				-- The below does work, but it's currently possible that other screens are resetting this early.
				for player in ivalues(PlayerNumber) do
					SCREENMAN:set_input_redirected(player, false)
				end

				if gameplayScreens[screenName] then
					local topScreen = SCREENMAN:GetTopScreen()
					SetGameplayPaused(topScreen, false)
				end
			else
			lines[#lines+1] = "Synchronisation des ecrans des joueurs...\n"
			local readyStates = {}
			for _, player in ivalues(updatedData.players or {}) do
				if type(player) == "table" then
					readyStates[#readyStates + 1] = tostring(player.profileName or "?") .. "=" .. tostring(player.ready and "1" or "0")
				end
			end
			local debugKey = table.concat({
				tostring(data and data.roomId or ""),
				tostring(screenName),
				tostring(data and data.phase or ""),
				tostring(playerCount),
				updatedData.aux.allInSameScreen and "1" or "0",
				updatedData.aux.allPlayersReady and "1" or "0",
				updatedData.aux.anyInGameplay and "1" or "0",
				readyToUnlock and "1" or "0",
				table.concat(readyStates, ","),
			}, "|")
			if debugKey ~= lastWaitingDebugKey then
				lastWaitingDebugKey = debugKey
				ready_debug("waiting room=" .. tostring(data and data.roomId or "")
					.. " screen=" .. tostring(screenName)
					.. " phase=" .. tostring(data and data.phase or "")
					.. " players=" .. tostring(playerCount)
					.. " allInSameScreen=" .. tostring(updatedData.aux.allInSameScreen)
					.. " allPlayersReady=" .. tostring(updatedData.aux.allPlayersReady)
					.. " anyInGameplay=" .. tostring(updatedData.aux.anyInGameplay)
					.. " readyToUnlock=" .. tostring(readyToUnlock)
					.. " readyStates=[" .. table.concat(readyStates, ",") .. "]")
			end
		end
	end

		if gameplayScreens[screenName] and data.phase == "starting" then
			local countdown = OnlineStartCountdownText()
			if countdown then
				lines[#lines+1] = countdown .. "\n"
			else
				lines[#lines+1] = "Chargement de la chanson par tous les joueurs...\n"
			end
			QueueOnlineGameplayStartRelease(actor)
			elseif gameplayScreens[screenName] and data.phase == "playing" then
				isWaiting = false
				for player in ivalues(PlayerNumber) do
					SCREENMAN:set_input_redirected(player, false)
				end
				local topScreen = SCREENMAN:GetTopScreen()
				SetGameplayPaused(topScreen, false)
				if ITGOnline and ITGOnline.MarkPlayEntered then ITGOnline:MarkPlayEntered() end
			elseif gameplayScreens[screenName] and data.phase == "results" then
				UnlockOnlineInput()
				local topScreen = SCREENMAN:GetTopScreen()
				SetGameplayPaused(topScreen, false)
				if ITGOnline and ITGOnline.EnforceRoomPhaseScreen then
					ITGOnline:EnforceRoomPhaseScreen(screenName)
				end
			elseif gameplayScreens[screenName] and (data.phase == "config" or data.phase == "lobby_ready" or data.phase == "lobby") then
				UnlockOnlineInput()
				local topScreen = SCREENMAN:GetTopScreen()
				SetGameplayPaused(topScreen, false)
				if ITGOnline and ITGOnline.EnforceRoomPhaseScreen then
					ITGOnline:EnforceRoomPhaseScreen(screenName)
				end
		end

	if screenName == "ScreenOnlineLobbies" and data.phase == "playing" then
		local remainingText = OnlineRemainingText(data)
		if remainingText then
			lines[#lines+1] = remainingText
			lines[#lines+1] = ""
		end
	end

	for i, player in ipairs(updatedData.players or {}) do
		if type(player) ~= "table" then
			lines[#lines+1] = tostring(i)..". Unknown player"
			lines[#lines+1] = ""
		else
				local displayedScreen = player.screenName ~= "NoScreen" and player.screenName:gsub("Screen", "") or "Transition"
			local readyText = ""
			if (data.phase == "lobby" or data.phase == "lobby_ready" or data.phase == "config")
				and not updatedData.aux.allPlayersReady then
					readyText =" ["..(player.ready and "OK" or "ATTENTE").."]"
			end

			-- Only display the screen name of the players that are on a different
			-- screen than we are.
			local playingText = player.isPlayingSong and (" " .. OnlinePlayingSpinner()) or ""
			local stateText = ""
			if data.phase == "playing" and player.playState and player.playState ~= "playing" then
				if player.playState == "finished" then
						stateText = " - termine [OK]"
					elseif player.playState == "failed" then
						stateText = " - echoue [F]"
				elseif player.playState == "returned_to_lobby" then
					stateText = " - a quitte la chanson [X]"
				elseif player.playState == "disconnected" then
						stateText = " - deconnecte [X]"
				else
					stateText = " - " .. tostring(player.playState)
				end
			end
			local playerAndScreen = i..'. '..player.profileName..playingText..readyText..stateText
			if screenName ~= player.screenName then
				playerAndScreen = playerAndScreen.." - in "..displayedScreen
			end

			lines[#lines+1] = playerAndScreen
			for scoreScreen in ivalues(scoreScreens) do
				if player.screenName == scoreScreen then
					-- Display canonical competition score (aligned with in-game online score),
					-- and keep accuracy as secondary diagnostic info when it differs.
					local score = (player.score ~= nil and player.score) or 0
					local accuracy = (player.accuracy ~= nil and player.accuracy) or nil
					local scoreStr = string.format("%.2f", score).."%"
					if accuracy ~= nil and math.abs((tonumber(accuracy) or 0) - (tonumber(score) or 0)) > 0.05 then
						lines[#lines+1] = "    "..scoreStr.." (acc "..string.format("%.2f", accuracy).."%)"
					else
						lines[#lines+1] = "    "..scoreStr
					end
					break
				end
			end

			-- Add a new line between players.
			lines[#lines+1] = ""
		end
	end

	if screenName == "ScreenOnlineLobbies" and data.finalResults and #data.finalResults > 0 then
			lines[#lines+1] = "Resultats de la derniere partie"
		for result in ivalues(data.finalResults) do
			local user = result.user or {}
			local score = math.floor(tonumber(result.score) or 0)
			local scorePercent = tonumber(result.score_percent)
			local accuracy = tonumber(result.accuracy) or 0
				local failedText = result.failed and " echoue [F]" or ""
			local scoreText = scorePercent ~= nil
				and (string.format("%.2f", scorePercent) .. "% (" .. tostring(score) .. " pts)")
				or (tostring(score) .. " pts")
			local displayName = ITGOnline and ITGOnline.UserDisplayName and ITGOnline:UserDisplayName(user, "Joueur") or tostring(user.display_name or user.displayName or user.name or "Joueur")
			lines[#lines+1] = tostring(result.rank or "?")
					.. ". " .. tostring(displayName)
				.. " - " .. scoreText
					.. " precision " .. string.format("%.2f", accuracy) .. "%"
				.. failedText
		end
		lines[#lines+1] = ""
	end

		if data.songInfo ~= nil then
			local songKey = OnlineSongKey(data)
			local shouldApplyInLobby = (data.phase == "lobby_ready" or data.phase == "config")
				and CurrentUserInLobbyState(data)
			if shouldApplyInLobby and songKey ~= "" and songKey ~= lastOnlineOptionsSongKey then
				if is_evaluation_screen(screenName) then
					online_flow_trace("song_selection_apply_deferred reason=evaluation_screen"
						.. " screen=" .. tostring(screenName)
						.. " phase=" .. tostring(data.phase)
						.. " key=" .. tostring(songKey))
				elseif ApplyOnlineSongSelection(data.songInfo) then
					lastOnlineOptionsSongKey = songKey
					if data.phase == "lobby_ready" then
						if ITGOnline.ConfirmSelectedSongAvailability then
							ITGOnline:ConfirmSelectedSongAvailability("local_song_available", function(ok)
								if ok then
									maybe_set_lobby_ready("local_song_available")
								end
							end)
						else
							maybe_set_lobby_ready("local_song_available")
						end
					end
					TransitionToOnlineOptions()
				end
			end

		if not songSelected then
			local topScreen = SCREENMAN:GetTopScreen()
			if topScreen and topScreen:GetName() == "ScreenSelectMusic" then
				local song = SONGMAN:FindSong(data.songInfo.songPath)
				local wheel = topScreen:GetMusicWheel()
				local _, songFolder = split_online_song_path(data.songInfo.songPath)
				if not song and songFolder then
					song = SONGMAN:FindSong(songFolder)
				end
				if song and wheel then
					wheel:SelectSong(song)
					wheel:Move(1)
					wheel:Move(-1)
					wheel:Move(0)
				end
			end
		else
      -- Only display the song in ScreenSelectMusic so that players know
      -- which songs they may need to navigate to.
      if screenName == "ScreenSelectMusic" then
        -- Split the song path into pack and song name for easier reading.
        -- It looks like "<pack>/<song>" so we can just split on the first "/"
        local pack, song = split_online_song_path(data.songInfo.songPath)
        pack = pack or "Inconnu"
        song = song or "Inconnue"

        -- Sometimes the pack or song can get quite long, so add ... if it's too long.
        local maxLength = 30
        if #pack > maxLength then
          pack = string.sub(pack, 1, maxLength) .. "..."
        end
        if #song > maxLength then
          song = string.sub(song, 1, maxLength) .. "..."
        end

        lines[#lines+1] = "Pack : "..pack
        lines[#lines+1] = "Chanson : "..song
      end
		end
	end

	-- This gets cleared out by the server when every player has arrived at the song selection screen.
	songSelected = (data.songInfo ~= nil)

			local gameplaySongKey = OnlineSongKey(data)
			if data.phase == "starting" and data.roomId and CurrentUserInLobbyState(data) and gameplaySongKey ~= "" and lastOnlineGameplayRoomId ~= gameplaySongKey then
				if ApplyOnlineSongSelection(data.songInfo) then
					if online_trace then
						online_trace("FLOW schedule_gameplay_start room=" .. tostring(data.roomId)
							.. " key=" .. tostring(gameplaySongKey)
							.. " previousKey=" .. tostring(lastOnlineGameplayRoomId)
							.. " screen=" .. tostring(screenName))
					end
					lines[#lines+1] = OnlineStartCountdownText() or "Demarrage de la chanson..."
					pendingOnlineStartRoomId = data.roomId
					lastOnlineGameplayRoomId = gameplaySongKey
					UnlockOnlineInput()
					TransitionToOnlineGameplay()
				end
			elseif data.phase == "playing" then
				-- Never auto-transition to gameplay while a room is already in playing phase.
				-- Players who are not already in-song must stay in lobby (countdown/results view)
				-- to avoid involuntary replay loops after reconnect/crash/end-of-song races.
				pendingOnlineStartRoomId = nil
			end

	actor:GetChild("Display"):playcommand("UpdateText", {text=table.concat(lines, "\n")})
end

local HandleResponse = function(response, actor)
	local event = response.event
	local data = response.data

	if event == "lobbyState" then
		actor.inLobby = true
		DisplayLobbyState(data, actor)
		MESSAGEMAN:Broadcast("OnlineLobbyState", data or {})
	elseif event == "lobbySearched" then
		MESSAGEMAN:Broadcast("LobbySearched", {
			lobbies = data and data.lobbies or {}
		})
	elseif event == "lobbyLeft" then
		actor.inLobby = false
		MESSAGEMAN:Broadcast("OnlineLobbyLeft", data or {})
	elseif event == "clientDisconnected" then
		actor.inLobby = false
		MESSAGEMAN:Broadcast("OnlineClientDisconnected", data or {})
	elseif event == "responseStatus" then
		MESSAGEMAN:Broadcast("OnlineResponseStatus", data or {})
	end
end

-- Only allow one instance of the online handler at a time.
-- Things can get a bit convoluted if we have many handlers trying to manage
-- multiple connections.
local onlineHandler = nil
local onlineHandlerInstance = nil
local onlineHandlerShuttingDown = false

GetOnlineHandlerInstance = function()
	return onlineHandlerInstance
end

CreateOnlineHandler = function() 
  if onlineHandler == nil then
    onlineHandler = Def.ActorFrame{
      Name="OnlineWebsocketHandler",
	      InitCommand=function(self)
				onlineHandlerInstance = self
				onlineHandlerShuttingDown = false
				if ITGOnline and ITGOnline.RefreshDebugFlags then
					ITGOnline:RefreshDebugFlags(true)
				end
	        self.socket = nil
	        self.connected = false
					self.connecting = false
					self.inLobby = false
					self.errorMsg = nil
					self.reconnectDelay = 1
					self.deadmanTimeoutSeconds = 75
					self.lastLobbyStatePayload = nil
	      end,
				OnCommand=function(self)
					self:sleep(1):queuecommand("RealtimeDeadman")
					self:sleep(5):queuecommand("OnlineHeartbeatTick")
					self:sleep(0.25):queuecommand("OnlinePlayingCountdownTick")
				end,
			OffCommand=function(self)
				onlineHandlerShuttingDown = true
				remove_online_input_callbacks()
				ITGOnline:Disconnect()
				self.socket = nil
				self.connected = false
				self.connecting = false
				self.inLobby = false
				self.errorMsg = nil
				replayDeferredLobbyStateQueued = false
				replayDeferredLobbyStateRunning = false
				local display = self:GetChild("Display")
				if display then
					display:GetChild("Text"):settext("")
				end
					if onlineHandlerInstance == self then
						onlineHandlerInstance = nil
					end
					lastSongPreviewSentAt = 0
					lastSongPreviewKey = ""
					lastOnlineOptionsSongKey = ""
					lastOnlineGameplayRoomId = nil
					pendingOnlineStartRoomId = nil
					pendingConfigReady = nil
					self.lastLobbyStatePayload = nil
					startHoldTime = { ["P1"] = 0, ["P2"] = 0 }
					lastDisconnectCountdown = nil
					self.joinLobbyBusy = false
					self.createLobbyBusy = false
					self.startRoomBusy = false
					self.invitePlayerBusy = false
					self.joinPlayerBusy = false
					self.privateJoinAnswerBusy = false
					self.searchLobbyBusy = false
					self.leaveLobbyBusy = false
				end,
	      ConnectOnlineMessageCommand=function(self)
	        if self.connecting then return end
	        if self.socket == nil or self.errorMsg ~= nil then
					self.connecting = true
					onlineHandlerShuttingDown = false
					self.errorMsg = nil
					ITGOnline:Connect({
							open=function()
								if onlineHandlerShuttingDown then return end
								self.connecting = false
								self.socket = ITGOnline.socket
								self.connected = true
								self.reconnectDelay = 1
								self.inLobby = ITGOnline.currentRoomId ~= nil
								self.errorMsg = nil
									self:GetChild("Display"):visible(false)
								if ITGOnline.Sync then
									ITGOnline:Sync(function(ok, decoded)
										if ok and decoded and decoded.current_room then
											self.inLobby = true
											ITGOnline:Heartbeat("in_room")
										elseif ITGOnline.CurrentRoomConflictCode
											and ITGOnline:CurrentRoomConflictCode(decoded, nil) ~= "" then
											self.inLobby = false
										else
											RestoreCurrentRoom(self)
										end
									end)
								else
									RestoreCurrentRoom(self)
								end
						end,
						error=function(message)
							if onlineHandlerShuttingDown then return end
							self.connecting = false
							self.inLobby = false
							self.connected = false
							self.errorMsg = message or "Connexion echouee"
							self:GetChild("Display"):GetChild("Text"):settext("")
							self:GetChild("Display"):visible(false)
						end,
							close=function()
								if onlineHandlerShuttingDown then return end
								self.connecting = false
								self.connected = false
								self.socket = nil
								self:GetChild("Display"):GetChild("Text"):settext("")
								self:GetChild("Display"):visible(false)
								if not ITGOnline.disconnecting then
									self:stoptweening()
									self:sleep(self.reconnectDelay or 1):queuecommand("ReconnectOnline")
									self.reconnectDelay = math.min(30, (self.reconnectDelay or 1) * 2)
								end
							end,
						})
	        end
	      end,
				ReconnectOnlineCommand=function(self)
					if onlineHandlerShuttingDown or ITGOnline.disconnecting or self.connected or self.socket ~= nil or self.connecting then
						return
					end
					MESSAGEMAN:Broadcast("ConnectOnline")
				end,
					RealtimeDeadmanCommand=function(self)
					if onlineHandlerShuttingDown then return end

					if self.connected and self.socket ~= nil and ITGOnline and ITGOnline.lastRealtimeMessageAt then
						local idle = GetTimeSinceStart() - ITGOnline.lastRealtimeMessageAt
						if idle > (self.deadmanTimeoutSeconds or 75) then
							self.connected = false
							if ITGOnline.socket then
								ITGOnline.socket:Close()
							end
							self.socket = nil
							MESSAGEMAN:Broadcast("OnlineResponseStatus", {
								event="websocket",
								success=false,
								message="Realtime connection timed out. Reconnecting..."
							})
							self:queuecommand("ReconnectOnline")
						end
					end

						self:sleep(1):queuecommand("RealtimeDeadman")
					end,
					OnlineHeartbeatTickCommand=function(self)
						if onlineHandlerShuttingDown then return end
						if ITGOnline and ITGOnline.RefreshDebugFlags then
							ITGOnline:RefreshDebugFlags(false)
						end

							if self.connected and self.socket ~= nil and ITGOnline and ITGOnline.Heartbeat then
								local screen = SCREENMAN:GetTopScreen()
								local screenName = screen and screen:GetName() or "NoScreen"
								local phase = ITGOnline.currentRoom and ITGOnline.currentRoom.phase or nil
								local status = "available"
								if ITGOnline.currentRoomId then
									status = (phase == "playing" or screenName == "ScreenGameplay" or screenName == "ScreenGameplayShared") and "playing" or "in_room"
								end
								ITGOnline:Heartbeat(status)
							end

						self:sleep(30):queuecommand("OnlineHeartbeatTick")
					end,
					OnlinePlayingCountdownTickCommand=function(self)
						if ITGOnline and ITGOnline.PackSync and ITGOnline.PackSync.WatchdogTick then
							ITGOnline.PackSync:WatchdogTick()
						end
						if not onlineHandlerShuttingDown and self.inLobby and self.lastLobbyStatePayload then
							local screen = SCREENMAN:GetTopScreen()
							local screenName = screen and screen:GetName() or "NoScreen"
							if screenName == "ScreenOnlineLobbies" and tostring(self.lastLobbyStatePayload.phase or "") == "playing" then
								DisplayLobbyState(self.lastLobbyStatePayload, self)
							end
						end
						if ITGOnline and ITGOnline.FlushLiveScore then
							ITGOnline:FlushLiveScore()
						end
						self:sleep(0.25):queuecommand("OnlinePlayingCountdownTick")
					end,
					OnlineScoreSnapshotMessageCommand=function(self, params)
						if onlineHandlerShuttingDown then return end
						if not (ITGOnline and ITGOnline.RememberLiveScoreSnapshot and ITGOnline.currentRoomId and ITGOnline.currentRoom) then return end
						local enabled = GAMESTATE:GetEnabledPlayers()
						local primary = enabled and enabled[1] or nil
						if not (params and primary and params.Player == primary) then return end

						ITGOnline:RememberLiveScoreSnapshot({
							scorePercent = params.ScorePercent,
							exScorePercent = params.ExScorePercent,
							displayedPercent = params.DisplayedPercent,
							combo = params.Combo,
						})
					end,
					OnlineSongReloadCompletedMessageCommand=function(self)
						lastOnlineOptionsSongKey = ""
					end,
					ReleaseOnlineGameplayAtStartCommand=function(self)
						self.onlineStartReleaseQueued = false
						if onlineHandlerShuttingDown or not (ITGOnline and ITGOnline.currentRoom) then return end

						local screen = SCREENMAN:GetTopScreen()
						local screenName = screen and screen:GetName() or "NoScreen"
						if screenName ~= "ScreenGameplay" and screenName ~= "ScreenGameplayShared" then
							return
						end

							if ITGOnline.currentRoom.phase == "playing" then
								local seconds = ITGOnline.SecondsUntilScheduledStart and ITGOnline:SecondsUntilScheduledStart() or nil
								ReleaseOnlineGameplay(screen, seconds)
								return
							end

						if ITGOnline.currentRoom.phase ~= "starting" then
							return
						end

							local seconds = ITGOnline.SecondsUntilScheduledStart and ITGOnline:SecondsUntilScheduledStart() or nil
							if seconds ~= nil and seconds <= 0.03 then
								ReleaseOnlineGameplay(screen, seconds)
								return
							end

						self.onlineStartReleaseQueued = true
						self:sleep(seconds and math.min(math.max(seconds, 0.05), 0.25) or 0.25):queuecommand("ReleaseOnlineGameplayAtStart")
					end,
	      ScreenChangedMessageCommand=function(self)
					local screen = SCREENMAN:GetTopScreen()
					local screenName = screen and screen:GetName() or "NoScreen"
					local wsConnected = self.connected and self.socket ~= nil
					remove_online_input_callbacks()

					if ITGOnline and ITGOnline.NoteScreenChanged then
						ITGOnline:NoteScreenChanged(screenName)
						if ITGOnline.ConsumeNeedsSyncAfterScreenCancel and ITGOnline:ConsumeNeedsSyncAfterScreenCancel() and ITGOnline.Sync then
							ITGOnline:Sync()
						end
					end
					startHoldTime = { ["P1"] = 0, ["P2"] = 0 }
					lastDisconnectCountdown = nil

					if not self.inLobby then
						return
					end

					if knownDisconnectScreens[screenName] then
						MESSAGEMAN:Broadcast("DisconnectOnline", {leaveRoom=true})
						return
					end

					if screenName == "ScreenSelectMusic" then
						UnlockOnlineInput()
						replace_online_input_callback(screen, "select_music", SelectMusicInputHandler)
					end
					if ITGOnline and ITGOnline.IsOnlineOptionsScreen and ITGOnline:IsOnlineOptionsScreen(screenName) then
						replace_online_input_callback(screen, "online_options", OnlineOptionsInputHandler)
					end
					if ITGOnline and ITGOnline.currentRoomId then
						-- Keep online flow deterministic: finishing options returns to the room lobby.
						SL.Global.ScreenAfter.PlayerOptions = "ScreenOnlineLobbies"
						SL.Global.ScreenAfter.PlayerOptions2 = "ScreenOnlineLobbies"
						SL.Global.ScreenAfter.PlayerOptions3 = "ScreenOnlineLobbies"
					end
					if evaluationScreens[screenName] and screen then
						replace_online_input_callback(screen, "evaluation", EvaluationInputHandler)
					end

					if syncLockScreens[screenName] then
						isWaiting = true
						for player in ivalues(PlayerNumber) do
							SCREENMAN:set_input_redirected(player, true)
						end
					end

					if autoReadyScreens[screenName] and not (evaluationScreens[screenName] and ITGOnline.currentRoom and ITGOnline.currentRoom.phase == "playing") then
						for player in ivalues(GAMESTATE:GetEnabledPlayers()) do
							local pn = ToEnumShortString(player)
							readyState[pn] = true
						end
					end

					if screenName == "ScreenGameplay" or screenName == "ScreenGameplayShared" then
						for player in ivalues(GAMESTATE:GetEnabledPlayers()) do
							local pn = ToEnumShortString(player)
							readyState[pn] = false
						end
							replace_online_input_callback(screen, "gameplay_wait", InputHandler)
							if ITGOnline.currentRoom and ITGOnline.currentRoom.phase == "playing" then
								UnlockOnlineInput()
								SetGameplayPaused(screen, false)
							elseif ITGOnline.currentRoom and ITGOnline.currentRoom.phase == "starting" then
								SetGameplayPaused(screen, true)
								if ITGOnline.MarkSongLoaded then
									ITGOnline:MarkSongLoaded(function(ok, decoded, response)
										if not ok then
											UnlockOnlineInput()
											if screen then
												SetGameplayPaused(screen, false)
												screen:SetNextScreenName("ScreenOnlineLobbies")
												screen:StartTransitioningScreen("SM_GoToNextScreen")
											end
										MESSAGEMAN:Broadcast("OnlineResponseStatus", {
											event="songLoaded",
											success=false,
											message=(decoded and decoded.message) or (response and response.errorMessage) or "Impossible de confirmer le chargement de la chanson."
										})
									end
								end)
								end
								QueueOnlineGameplayStartRelease(self)
							else
								SetGameplayPaused(screen, false)
								if ITGOnline and ITGOnline.EnforceRoomPhaseScreen then
									ITGOnline:EnforceRoomPhaseScreen(screenName)
								end
						end
					elseif isWaiting then
						replace_online_input_callback(screen, "wait", InputHandler)
					end

					if wsConnected and ITGOnline and ITGOnline.currentRoomId then
						local status = (gameplayScreens[screenName] and ITGOnline.currentRoom and ITGOnline.currentRoom.phase == "playing") and "playing" or "in_room"
						ITGOnline:Heartbeat(status)
					end
						if evaluationScreens[screenName]
							and ITGOnline
							and ITGOnline.MarkGameplayCompleteForEvaluation then
							ITGOnline:MarkGameplayCompleteForEvaluation("evaluation_screen")
						end
						if screenName == "ScreenSelectMusic"
							and ITGOnline.currentSongPayload
							and ITGOnline.currentRoom
							and tostring(ITGOnline.currentRoom.phase or "") == "lobby_ready" then
							maybe_set_lobby_ready("screen_select_music")
						end
					if screenName == "ScreenSelectMusic" then
						self:sleep(0.25):queuecommand("PreviewInitialOnlineSong")
					end
					if not replayDeferredLobbyStateQueued then
						replayDeferredLobbyStateQueued = true
						self:sleep(0.05):queuecommand("ReplayDeferredLobbyState")
					end
					MESSAGEMAN:Broadcast("UpdateMachineState")
		      end,
					ReplayDeferredLobbyStateCommand=function(self)
						replayDeferredLobbyStateQueued = false
						if replayDeferredLobbyStateRunning then return end
						if not (self.inLobby and self.lastLobbyStatePayload) then return end
						local screen = SCREENMAN:GetTopScreen()
						local screenName = screen and screen:GetName() or "NoScreen"
						if is_evaluation_screen(screenName) then return end
						if gameplayScreens[screenName] then return end
						if OnlineDeferredReplayBlockedScreen(screenName) then return end
						if ITGOnline and ITGOnline.IsOnlineOptionsScreen and ITGOnline:IsOnlineOptionsScreen(screenName) then return end
						if not OnlinePayloadMatchesActiveRoom(self.lastLobbyStatePayload) then
							if online_trace then
								online_trace("replay_deferred_lobby_state_cleared reason=inactive_room"
									.. " screen=" .. tostring(screenName)
									.. " payloadRoomId=" .. tostring(self.lastLobbyStatePayload.roomId or self.lastLobbyStatePayload.room_id or ""))
							end
							self.lastLobbyStatePayload = nil
							return
						end
						local phase = tostring(self.lastLobbyStatePayload.phase or "")
						if (phase == "lobby_ready" or phase == "config") and self.lastLobbyStatePayload.songInfo ~= nil then
							online_flow_trace("replay_deferred_lobby_state"
								.. " screen=" .. tostring(screenName)
								.. " phase=" .. tostring(phase))
							replayDeferredLobbyStateRunning = true
							local ok, err = pcall(function()
								DisplayLobbyState(self.lastLobbyStatePayload, self)
							end)
							replayDeferredLobbyStateRunning = false
							if not ok then
								lua.ReportScriptError("ReplayDeferredLobbyState failed: " .. tostring(err))
							end
						end
					end,
					PreviewInitialOnlineSongCommand=function(self)
						if SCREENMAN:GetTopScreen() and SCREENMAN:GetTopScreen():GetName() ~= "ScreenSelectMusic" then
							return
						end
						maybe_preview_current_online_song(true)
					end,
	      PlayerJoinedMessageCommand=function(self)
					if self.connected and self.socket ~= nil and self.inLobby then
	          ITGOnline:Heartbeat("in_room", true)
	        end
	      end,
	      PlayerUnjoinedMessageCommand=function(self)
					if self.connected and self.socket ~= nil and self.inLobby then
	          ITGOnline:Heartbeat("in_room", true)
	        end
	      end,
			UpdateMachineStateMessageCommand=function(self)
					if self.connected and self.socket ~= nil and self.inLobby then
	          ITGOnline:Heartbeat("in_room", true)
	        end
	      end,
		      OnlineConfigReadyMessageCommand=function(self)
						if not (self.connected and self.socket ~= nil and ITGOnline.currentRoomId) then
							return
						end

						self.inLobby = true
						local configReadyKey = ITGOnline.PlayStateKey and ITGOnline:PlayStateKey()
							or (tostring(ITGOnline.currentRoomId) .. "|" .. tostring(ITGOnline.currentSongPayload and ITGOnline.currentSongPayload.chart_hash or ""))
						pendingConfigReady = configReadyKey
						if ITGOnline.SetOptimisticConfigReady then
							ITGOnline:SetOptimisticConfigReady("options_confirmed")
						end
						if ITGOnline.MarkConfigReady then
							Trace("[ITGOnline] options_confirmed queue config_ready key=" .. tostring(configReadyKey))
						else
							Trace("[ITGOnline] options_confirmed queue legacy_config_ready key=" .. tostring(configReadyKey))
						end
						if online_flow_trace then
							online_flow_trace("options_confirmed dispatch_immediate config_ready key=" .. tostring(configReadyKey))
						end
						self:playcommand("RetryOnlineConfigReady")
		      end,
		      OnlineConfigReadyConfirmedMessageCommand=function(self, params)
						if not pendingConfigReady then
							return
						end

						local expectedConfigReadyKey = ITGOnline.PlayStateKey and ITGOnline:PlayStateKey()
							or (tostring(ITGOnline.currentRoomId) .. "|" .. tostring(ITGOnline.currentSongPayload and ITGOnline.currentSongPayload.chart_hash or ""))
						local confirmedKey = params and params.key or expectedConfigReadyKey
						if pendingConfigReady == confirmedKey or pendingConfigReady == expectedConfigReadyKey then
							Trace("[ITGOnline] options_confirmed realtime config_ready key=" .. tostring(confirmedKey))
							pendingConfigReady = nil
							if ITGOnline.ClearOptimisticConfigReady then
								ITGOnline:ClearOptimisticConfigReady("config_ready_confirmed")
							end
						end
					end,
		      RetryOnlineConfigReadyCommand=function(self)
						if not pendingConfigReady or not ITGOnline.currentRoomId then
							return
						end
							local expectedConfigReadyKey = ITGOnline.PlayStateKey and ITGOnline:PlayStateKey()
								or (tostring(ITGOnline.currentRoomId) .. "|" .. tostring(ITGOnline.currentSongPayload and ITGOnline.currentSongPayload.chart_hash or ""))
						if pendingConfigReady ~= expectedConfigReadyKey then
							return
						end

						if ITGOnline.MarkConfigReady then
							ITGOnline:MarkConfigReady(function(ok, decoded, response)
								if ok then
									if pendingConfigReady == expectedConfigReadyKey then pendingConfigReady = nil end
									return
								end

								if response and response.retryAfter then
									self:sleep(response.retryAfter):queuecommand("RetryOnlineConfigReady")
									return
								end

								if pendingConfigReady == expectedConfigReadyKey then pendingConfigReady = nil end
								if ITGOnline.ClearOptimisticConfigReady then
									ITGOnline:ClearOptimisticConfigReady("config_ready_failed")
								end
								MESSAGEMAN:Broadcast("OnlineResponseStatus", {
								event="ready",
								success=false,
								message=(decoded and decoded.message) or (response and response.errorMessage) or "Echec de synchronisation de l'etat pret."
							})
						end)
						return
					end

					ITGOnline:FetchRoom(ITGOnline.currentRoomId, function(ok, decoded)
							if not ok or not decoded or not decoded.room then
								self:sleep(1):queuecommand("RetryOnlineConfigReady")
								return
						end

						local phase = decoded.room.phase
						if not decoded.room.selected_song then
							ITGOnline:SelectSong(function(selectOk, selectDecoded, selectResponse)
									if selectOk then
										self:sleep(0.25):queuecommand("RetryOnlineConfigReady")
									else
										if pendingConfigReady == expectedConfigReadyKey then pendingConfigReady = nil end
										if ITGOnline.ClearOptimisticConfigReady then
											ITGOnline:ClearOptimisticConfigReady("config_ready_select_song_failed")
										end
									MESSAGEMAN:Broadcast("OnlineResponseStatus", {
										event="selectSong",
										success=false,
											message=(selectDecoded and selectDecoded.message) or (selectResponse and selectResponse.errorMessage) or "Echec de selection de la chanson."
									})
								end
							end)
							return
						end

							if phase == "starting" or phase == "playing" or phase == "results" then
								if pendingConfigReady == expectedConfigReadyKey then pendingConfigReady = nil end
								if ITGOnline.ClearOptimisticConfigReady then
									ITGOnline:ClearOptimisticConfigReady("config_ready_phase_" .. tostring(phase))
								end
							elseif phase == "config" then
								ITGOnline:SetReady("config_ready", true, function()
									if pendingConfigReady == expectedConfigReadyKey then pendingConfigReady = nil end
								ITGOnline:FetchRoom(ITGOnline.currentRoomId, function(fetchOk, fetchDecoded)
									if fetchOk and fetchDecoded and fetchDecoded.room then
									MESSAGEMAN:Broadcast("OnlineLobbyState", ITGOnline:LobbyStatePayload(fetchDecoded.room))
									end
								end)
							end)
						elseif phase == "lobby" or phase == "lobby_ready" then
							ITGOnline:SetReady("lobby_ready", true, function()
								self:sleep(0.5):queuecommand("RetryOnlineConfigReady")
							end)
						else
							if pendingConfigReady == expectedConfigReadyKey then pendingConfigReady = nil end
						end
					end)
	      end,
					OnlineSessionExpiredMessageCommand=function(self)
						self.connected = false
					self.inLobby = false
					self.socket = nil
					isWaiting = false
					for player in ivalues(PlayerNumber) do
						SCREENMAN:set_input_redirected(player, false)
					end
					MESSAGEMAN:Broadcast("OnlineResponseStatus", {
						event="sessionExpired",
						success=false,
						message="Online session expired. Please reconnect."
					})
				end,
				OnlineLobbyStateMessageCommand=function(self, params)
					if self.connected and params and params.roomId then
						self.inLobby = true
						params.__receivedLocalTime = GetTimeSinceStart()
						self.lastLobbyStatePayload = params
						DisplayLobbyState(params, self)
					end
				end,
				OnlineLobbyLeftMessageCommand=function(self)
					self.inLobby = false
					self.lastLobbyStatePayload = nil
					replayDeferredLobbyStateQueued = false
					replayDeferredLobbyStateRunning = false
				end,
				SongSelectedMessageCommand=function(self)
					SelectOnlineSongAsManager(self)
				end,
				OnlineManagerAutoReadyRetryRequestedMessageCommand=function(self, params)
					if not (params and params.key) then return end
					local key = tostring(params.key or "")
					local readyPhase = tostring(params.readyPhase or params.ready_phase or "lobby_ready")
					if key == "" then return end

					local retryAfter = tonumber(params.retryAfter or params.retry_after) or 0.25
					retryAfter = math.min(math.max(retryAfter + 0.05, 0.05), 5)
					pendingManagerAutoReadyRetryKey = key
					pendingManagerAutoReadyRetryPhase = readyPhase
					online_flow_trace("manager_auto_ready_retry_scheduled key=" .. tostring(key)
						.. " phase=" .. tostring(readyPhase)
						.. " retry_after=" .. tostring(retryAfter))
					self:sleep(retryAfter):queuecommand("RetryOnlineManagerAutoReady")
				end,
				RetryOnlineManagerAutoReadyCommand=function(self)
					local key = pendingManagerAutoReadyRetryKey
					local readyPhase = pendingManagerAutoReadyRetryPhase ~= "" and pendingManagerAutoReadyRetryPhase or "lobby_ready"
					if key == "" then return end
					if not (ITGOnline and ITGOnline.currentRoom and ITGOnline.ManagerAutoReadyKey and ITGOnline.MaybeAutoReadyManager) then
						pendingManagerAutoReadyRetryKey = ""
						pendingManagerAutoReadyRetryPhase = ""
						return
					end

					local currentKey = ITGOnline:ManagerAutoReadyKey(ITGOnline.currentRoom, readyPhase)
					if currentKey ~= key then
						online_flow_trace("manager_auto_ready_retry_ignored reason=stale_key expected=" .. tostring(key)
							.. " current=" .. tostring(currentKey))
						pendingManagerAutoReadyRetryKey = ""
						pendingManagerAutoReadyRetryPhase = ""
						return
					end

					pendingManagerAutoReadyRetryKey = ""
					pendingManagerAutoReadyRetryPhase = ""
					online_flow_trace("manager_auto_ready_retry key=" .. tostring(key))
					ITGOnline:MaybeAutoReadyManager(ITGOnline.currentRoom)
				end,
		      CurrentSongChangedMessageCommand=function(self)
					if self.connected and self.socket ~= nil then
						maybe_preview_current_online_song(false)
					end
		      end,
		      JoinLobbyMessageCommand=function(self, params)
		        if self.connected and self.socket ~= nil then
						if self.joinLobbyBusy then return end
						self.joinLobbyBusy = true
						self.inLobby = false
		          ITGOnline:RequestJoinRoom(params.code, function(ok, decoded, response)
								self.joinLobbyBusy = false
								if ok and decoded and decoded.room then
									self.inLobby = true
									DisplayLobbyState(ITGOnline:LobbyStatePayload(decoded.room), self)
									MESSAGEMAN:Broadcast("OnlineLobbyState", ITGOnline:LobbyStatePayload(decoded.room))
								elseif ok then
									MESSAGEMAN:Broadcast("OnlineResponseStatus", {
										event="joinLobby",
										success=true,
										message="Demande envoyee. En attente du manager du salon."
									})
								elseif decoded and (decoded.error_code == "already_in_room" or decoded.message == "You are already in this room.") and params and params.code then
								ITGOnline:FetchRoom(params.code, function(fetchOk, fetchDecoded, fetchResponse)
									if fetchOk and fetchDecoded and fetchDecoded.room then
										self.inLobby = true
										DisplayLobbyState(ITGOnline:LobbyStatePayload(fetchDecoded.room), self)
										MESSAGEMAN:Broadcast("OnlineLobbyState", ITGOnline:LobbyStatePayload(fetchDecoded.room))
									else
										MESSAGEMAN:Broadcast("OnlineResponseStatus", {
											event="joinLobby",
											success=false,
											message=(fetchDecoded and fetchDecoded.message) or (fetchResponse and fetchResponse.errorMessage) or "Impossible de restaurer l'etat du salon."
										})
									end
								end)
							else
								MESSAGEMAN:Broadcast("OnlineResponseStatus", {
									event="joinLobby",
									success=false,
									message=(decoded and decoded.message) or (response and response.errorMessage) or "Echec de connexion au salon."
								})
							end
						end)
	        end
	      end,
		      CreateLobbyMessageCommand=function(self, params)
		        if self.connected and self.socket ~= nil then
						if self.createLobbyBusy then
							MESSAGEMAN:Broadcast("OnlineResponseStatus", {
								event="createLobby",
								success=false,
								message="Une creation de salon est deja en cours."
							})
							return
						end
						self.createLobbyBusy = true
						self.inLobby = false
		          ITGOnline:CreateRoom(function(ok, decoded, response)
								self.createLobbyBusy = false
								if ok and decoded and decoded.room then
								self.inLobby = true
								DisplayLobbyState(ITGOnline:LobbyStatePayload(decoded.room), self)
								MESSAGEMAN:Broadcast("OnlineLobbyState", ITGOnline:LobbyStatePayload(decoded.room))
								elseif decoded and (decoded.error_code == "already_in_open_room" or decoded.message == "User is already in an open room.") then
								RestoreCurrentRoom(self, function(restored)
									if not restored then
										MESSAGEMAN:Broadcast("OnlineResponseStatus", {
											event="createLobby",
											success=false,
									message="Echec de creation du salon : l'utilisateur est deja dans un salon ouvert."
										})
									end
								end)
							else
								MESSAGEMAN:Broadcast("OnlineResponseStatus", {
									event="createLobby",
									success=false,
								message=(decoded and decoded.message) or (response and response.errorMessage) or "Echec de creation du salon."
								})
							end
						end, params and params.visibility or "public")
	        else
						MESSAGEMAN:Broadcast("OnlineResponseStatus", {
							event="createLobby",
							success=false,
							message="Le service en ligne n'est pas encore connecte. Reessayez dans un instant."
						})
	        end
	      end,
	      StartOnlineRoomMessageCommand=function(self)
					if self.connected and self.socket ~= nil and self.inLobby then
						if self.startRoomBusy then
							if online_trace then
								online_trace("FLOW start_room ignored reason=busy room=" .. tostring(ITGOnline and ITGOnline.currentRoomId or "nil"))
							end
							return
						end
						if not ITGOnline.currentRoom then
							if online_trace then
								online_trace("FLOW start_room rejected reason=no_current_room")
							end
							MESSAGEMAN:Broadcast("OnlineResponseStatus", {
								event="startRoom",
								success=false,
								message="Le salon n'est pas encore pret a demarrer."
							})
							return
						end

						local attemptStart = function()
							self.startRoomBusy = true
							if online_trace then
								online_trace("FLOW start_room request room=" .. tostring(ITGOnline.currentRoomId or "nil")
									.. " phase=" .. tostring(ITGOnline.currentRoom and ITGOnline.currentRoom.phase or "nil"))
							end
							ITGOnline:StartRoom(function(ok, decoded, response)
								self.startRoomBusy = false
								if ok and decoded and decoded.room then
									if online_trace then
										online_trace("FLOW start_room ok room=" .. tostring(decoded.room.id or ITGOnline.currentRoomId or "nil")
											.. " phase=" .. tostring(decoded.room.phase or "nil"))
									end
									local payload = ITGOnline:LobbyStatePayload(decoded.room)
									DisplayLobbyState(payload, self)
									MESSAGEMAN:Broadcast("OnlineLobbyState", payload)
								else
									if online_trace then
										online_trace("FLOW start_room failed room=" .. tostring(ITGOnline.currentRoomId or "nil")
											.. " phase=" .. tostring(ITGOnline.currentRoom and ITGOnline.currentRoom.phase or "nil")
											.. " error=" .. tostring((decoded and decoded.error_code) or (response and response.errorMessage) or "unknown"))
									end
									MESSAGEMAN:Broadcast("OnlineResponseStatus", {
										event="startRoom",
											success=false,
											message=(decoded and decoded.message) or (response and response.errorMessage) or "Echec du lancement."
									})
								end
							end)
						end

						local phase = tostring(ITGOnline.currentRoom.phase or "")
						if phase == "config" or phase == "lobby_ready" then
							attemptStart()
							return
						end

							if online_trace then
								online_trace("FLOW start_room rejected reason=phase_not_ready room=" .. tostring(ITGOnline.currentRoomId or "nil")
									.. " phase=" .. tostring(phase))
							end
							MESSAGEMAN:Broadcast("OnlineResponseStatus", {
								event="startRoom",
								success=false,
								message="Le salon n'est pas encore pret a demarrer."
						})
        end
      end,
	      InviteOnlinePlayerMessageCommand=function(self, params)
	        if self.connected and self.socket ~= nil and params and params.user_id then
						if self.invitePlayerBusy then return end
						self.invitePlayerBusy = true
						self.inLobby = false
						local visibility = params.visibility or "private"
	          ITGOnline:InviteUserToNewRoom(params.user_id, visibility, function(ok, decoded, response)
							self.invitePlayerBusy = false
							if ok then
							self.inLobby = true
							if ITGOnline.currentRoom then
								DisplayLobbyState(ITGOnline:LobbyStatePayload(ITGOnline.currentRoom), self)
								MESSAGEMAN:Broadcast("OnlineLobbyState", ITGOnline:LobbyStatePayload(ITGOnline.currentRoom))
							end
							MESSAGEMAN:Broadcast("OnlineResponseStatus", {
								event="invitePlayer",
								success=true,
								message="Invitation sent."
							})
						else
							MESSAGEMAN:Broadcast("OnlineResponseStatus", {
								event="invitePlayer",
								success=false,
								message=(decoded and decoded.message) or (response and response.errorMessage) or "Invitation failed."
							})
						end
					end)
        end
      end,
	      JoinOnlinePlayerRoomMessageCommand=function(self, params)
	        if self.connected and self.socket ~= nil and params and params.user_id then
						if self.joinPlayerBusy then return end
						self.joinPlayerBusy = true
						self.inLobby = false
	          ITGOnline:RequestJoinUserRoom(params.user_id, function(ok, decoded, response)
							self.joinPlayerBusy = false
							if ok and decoded and decoded.room then
								self.inLobby = true
								DisplayLobbyState(ITGOnline:LobbyStatePayload(decoded.room), self)
								MESSAGEMAN:Broadcast("OnlineLobbyState", ITGOnline:LobbyStatePayload(decoded.room))
							elseif ok then
								MESSAGEMAN:Broadcast("OnlineResponseStatus", {
									event="joinLobby",
									success=true,
									message="Demande envoyee. En attente d'approbation."
								})
						else
							MESSAGEMAN:Broadcast("OnlineResponseStatus", {
								event="joinLobby",
								success=false,
									message=(decoded and decoded.message) or (response and response.errorMessage) or "Echec de la demande de connexion."
							})
						end
					end)
        end
      end,
	      AnswerPrivateJoinRequestMessageCommand=function(self, params)
	        if self.connected and self.socket ~= nil and params and params.join_request_id then
						if self.privateJoinAnswerBusy then return end
						self.privateJoinAnswerBusy = true
						if params.accept then
							ITGOnline:AcceptJoinRequest(params.join_request_id, function(ok, decoded, response)
								self.privateJoinAnswerBusy = false
								if ok and decoded and decoded.room then
								DisplayLobbyState(ITGOnline:LobbyStatePayload(decoded.room), self)
								MESSAGEMAN:Broadcast("OnlineLobbyState", ITGOnline:LobbyStatePayload(decoded.room))
							end
							MESSAGEMAN:Broadcast("OnlineResponseStatus", {
								event="privateJoinAnswer",
								success=ok and true or false,
									message=ok and "Demande acceptee." or ((decoded and decoded.message) or (response and response.errorMessage) or "Impossible de repondre a la demande.")
							})
						end)
						else
							ITGOnline:DeclineJoinRequest(params.join_request_id, params.reason or "", function(ok, decoded, response)
								self.privateJoinAnswerBusy = false
								MESSAGEMAN:Broadcast("OnlineResponseStatus", {
								event="privateJoinAnswer",
								success=ok and true or false,
									message=ok and "Demande refusee." or ((decoded and decoded.message) or (response and response.errorMessage) or "Impossible de repondre a la demande.")
							})
						end)
					end
        end
      end,
	      AnswerRoomInvitationMessageCommand=function(self, params)
	        if self.connected and self.socket ~= nil and params and params.invitation_id then
						if self.roomInvitationAnswerBusy then return end
						self.roomInvitationAnswerBusy = true
						if params.accept then
							ITGOnline:AcceptInvitation(params.invitation_id, function(ok, decoded, response)
								self.roomInvitationAnswerBusy = false
								if ok and decoded and decoded.room then
									DisplayLobbyState(ITGOnline:LobbyStatePayload(decoded.room), self)
									MESSAGEMAN:Broadcast("OnlineLobbyState", ITGOnline:LobbyStatePayload(decoded.room))
								end
								MESSAGEMAN:Broadcast("OnlineResponseStatus", {
									event="roomInvitationAnswer",
									success=ok and true or false,
										message=ok and "Invitation acceptee." or ((decoded and decoded.message) or (response and response.errorMessage) or "Impossible de repondre a l'invitation.")
								})
							end)
						else
							ITGOnline:DeclineInvitation(params.invitation_id, function(ok, decoded, response)
								self.roomInvitationAnswerBusy = false
								MESSAGEMAN:Broadcast("OnlineResponseStatus", {
									event="roomInvitationAnswer",
									success=ok and true or false,
										message=ok and "Invitation refusee." or ((decoded and decoded.message) or (response and response.errorMessage) or "Impossible de repondre a l'invitation.")
								})
							end)
						end
        end
      end,
				SearchLobbyMessageCommand=function(self)
					if self.connected and self.socket ~= nil then
						if self.searchLobbyBusy then return end
						self.searchLobbyBusy = true
						ITGOnline:FetchLobby(function(ok, decoded, response)
							self.searchLobbyBusy = false
							if ok then
							MESSAGEMAN:Broadcast("LobbySearched", ITGOnline:LobbySearchPayload(decoded))
						else
							MESSAGEMAN:Broadcast("OnlineResponseStatus", {
								event="searchLobby",
								success=false,
									message=(decoded and decoded.message) or (response and response.errorMessage) or "Echec de recherche des salons."
							})
						end
					end)
				end
			end,
				LeaveLobbyMessageCommand=function(self)
					if self.connected and self.socket ~= nil then
						if self.leaveLobbyBusy then return end
						self.leaveLobbyBusy = true
						ITGOnline:LeaveRoom(function(ok, decoded, response)
							self.leaveLobbyBusy = false
							if ok then
							self.inLobby = false
							MESSAGEMAN:Broadcast("OnlineLobbyLeft", {left=true})
						else
							MESSAGEMAN:Broadcast("OnlineResponseStatus", {
								event="leaveLobby",
								success=false,
								message=(decoded and decoded.message) or (response and response.errorMessage) or "Echec de sortie du salon."
							})
						end
					end)
				end
			end,
	      DisconnectOnlineMessageCommand=function(self, params)
				local shouldLeaveRoom = params and params.leaveRoom and self.inLobby
				local finalize = function()
					onlineHandlerShuttingDown = true
					isWaiting = false
					ITGOnline:Disconnect()
					for player in ivalues(PlayerNumber) do
						SCREENMAN:set_input_redirected(player, false)
					end
					self.connected = false
					self.inLobby = false
					self.socket = nil
					replayDeferredLobbyStateQueued = false
					replayDeferredLobbyStateRunning = false
					self:GetChild("Display"):GetChild("Text"):settext("")
					self:GetChild("Display"):visible(false)
				end

				if shouldLeaveRoom then
					ITGOnline:LeaveRoom(function()
						finalize()
					end)
					return
				end

					finalize()
	      end,

		      Def.Actor{
		        Name="OnlineStartPollTimer",
	        PollCommand=function(self)
						local actor = self:GetParent()
						local roomId = pendingOnlineStartRoomId
						if not roomId or not (ITGOnline and ITGOnline.FetchRoom) then
							return
						end

						ITGOnline:FetchRoom(roomId, function(ok, decoded)
							if not ok or not decoded or not decoded.room then
								PollOnlineStart(actor, roomId)
								return
							end

							local payload = ITGOnline:LobbyStatePayload(decoded.room)
							DisplayLobbyState(payload, actor)
							MESSAGEMAN:Broadcast("OnlineLobbyState", payload)

							if decoded.room.phase == "starting" then
								PollOnlineStart(actor, roomId)
							end
						end)
	        end,
	      },

		      Def.ActorFrame{
		        Name="Display",
	        InitCommand=function(self)
	          self:visible(false)

					local width = 200
					local LEFT = width/2
					self:xy(LEFT, _screen.cy)
        end,
	        UpdateTextCommand=function(self, params)
						self:visible(false)
	          local screen = SCREENMAN:GetTopScreen()
          local screenName = screen and screen:GetName() or "NoScreen"

          local bg = self:GetChild("Background")
          local width = 200
          local height = SCREEN_HEIGHT

          -- Some generic constants for easy positioning.
          local LEFT = width/2
          local RIGHT = SCREEN_WIDTH - width/2
          local CENTER = _screen.cx

          -- If we're on a different screen, we'll just retain the last position.
          if screenName == "ScreenSelectMusic" then
            self:xy(LEFT, _screen.cy)
            bg:zoomto(width, height)
          elseif evaluationScreens[screenName] or gameplayScreens[screenName] then
            local p1Joined = GAMESTATE:IsSideJoined("PlayerNumber_P1")
            local p2Joined = GAMESTATE:IsSideJoined("PlayerNumber_P2")

            if p1Joined and p2Joined then
              self:xy(CENTER, _screen.cy)
              bg:zoomto(width, height)
            elseif p1Joined then
              self:xy(RIGHT, _screen.cy)
              bg:zoomto(width, height)
            elseif p2Joined then
              self:xy(LEFT, _screen.cy)
              bg:zoomto(width, height)
            end
          end

          self:GetChild("Text"):playcommand("Resize", {width=width, height=height, text=params.text})
        end,

        Def.Quad{
          Name="Background",
          InitCommand=function(self)
            self:zoomto(SCREEN_WIDTH / 3, SCREEN_HEIGHT):diffuse(0, 0, 0, 0.5)
          end,
        },

        LoadFont("Common Normal").. {
          Name="Text",
          Text="",
          InitCommand=function(self)
            self:diffuse(Color.Yellow)
          end,
          ResizeCommand=function(self, params)
            self:settext(params.text)
            DiffuseEmojis(self)
            -- We don't want text to be cut off.
            -- Incrementally adjust the zoom while checking the width until it fits.
            -- Not the prettiest solution but it works.
            for zoomVal=1.0, 0.1, -0.05 do
              self:zoom(zoomVal)
              self:settext(params.text)
              if self:GetWidth() * zoomVal <= params.width then
                break
              end
            end
          end
        },
      },
    }
  end

  return onlineHandler
end
