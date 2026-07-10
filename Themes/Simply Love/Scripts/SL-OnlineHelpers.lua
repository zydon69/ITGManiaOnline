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
local onlineOptionsRedirectedSelectionKey = ""
local onlineOptionsRedirectedAt = 0
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
local onlineHandlerShuttingDown = false
local onlineOperationToken = 0
local evaluationExitTransitionRequestedAt = 0
local evaluationExitTransitionRoomId = ""
local lastGameplayResultsForceKey = ""
UnlockOnlineInput = nil
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

DisplayLobbyState = nil

function online_logs_enabled(category)
	category = tostring(category or "network")
	if category == "layout" then
		return type(IsOnlineGameplayLayoutLoggingEnabled) == "function"
			and IsOnlineGameplayLayoutLoggingEnabled() == true
	elseif category == "auth" then
		return type(IsOnlineAuthLoggingEnabled) == "function"
			and IsOnlineAuthLoggingEnabled() == true
	elseif category == "score" then
		return type(IsOnlineScoreLoggingEnabled) == "function"
			and IsOnlineScoreLoggingEnabled() == true
	end
	return type(IsOnlineNetworkLoggingEnabled) == "function"
		and IsOnlineNetworkLoggingEnabled() == true
end

function online_trace(message, category)
	category = tostring(category or "network")
	local enabled = ITGOnline and (
		(category == "score" and ITGOnline.debugScoreTrace == true)
		or (category == "auth" and ITGOnline.debugAuthTrace == true)
		or (category == "ready" and ITGOnline.debugReadyFlow == true)
		or (category == "network" and ITGOnline.debugOnlineTrace == true)
	)
	if not enabled then return end
	local safeMessage = tostring(message or ""):gsub("[%c]", " ")
	if #safeMessage > 4096 then safeMessage = safeMessage:sub(1, 4096) .. "...[truncated]" end
	local sessionId = tostring(ITGOnline and ITGOnline.logSessionId or "none"):gsub("[%c]", " "):sub(1, 64)
	if Trace then
		Trace("ITG Online: session=" .. sessionId .. " " .. safeMessage)
	elseif Warn then
		Warn("ITG Online: session=" .. sessionId .. " " .. safeMessage)
	end
end

function is_evaluation_screen(screenName)
	return evaluationScreens[tostring(screenName or "")] == true
end

function remove_online_input_callbacks()
	for key, callback in pairs(onlineInputCallbacks) do
		if callback and callback.screen and callback.handler and callback.screen.RemoveInputCallback then
			pcall(function() callback.screen:RemoveInputCallback(callback.handler) end)
		end
		onlineInputCallbacks[key] = nil
	end
end

function replace_online_input_callback(screen, key, handler)
	if not screen or not handler then return end
	local callback = onlineInputCallbacks[key]
	if callback and callback.screen and callback.handler and callback.screen.RemoveInputCallback then
		pcall(function() callback.screen:RemoveInputCallback(callback.handler) end)
	end
	screen:AddInputCallback(handler)
	onlineInputCallbacks[key] = { screen = screen, handler = handler }
end

function ready_debug_enabled()
	if type(online_logs_enabled) == "function" and not online_logs_enabled() then
		return false
	end
	if ITGOnline and ITGOnline.debugReadyFlow ~= nil then
		return ITGOnline.debugReadyFlow == true
	end
	return false
end

function ready_debug(message)
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
function online_flow_trace(message)
	if type(online_logs_enabled) == "function" and not online_logs_enabled() then
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

local online_flow_trace_throttle_last_at = {}
function online_flow_trace_throttled(key, intervalSeconds, message)
	local throttleKey = tostring(key or "default")
	local interval = tonumber(intervalSeconds) or 1.0
	local now = GetTimeSinceStart()
	local lastAt = tonumber(online_flow_trace_throttle_last_at[throttleKey]) or -9999
	if now - lastAt < interval then
		return
	end
	online_flow_trace_throttle_last_at[throttleKey] = now
	online_flow_trace(message)
end

function report_online_error(context, err)
	local message = "ITG Online " .. tostring(context or "operation") .. " failed: " .. tostring(err or "unknown")
	if lua and lua.ReportScriptError then
		lua.ReportScriptError(message)
	elseif Warn then
		Warn(message)
	elseif Trace then
		Trace(message)
	end
end

function safe_online_call(context, fn)
	if type(fn) ~= "function" then return false end
	local ok, result = pcall(fn)
	if not ok then
		report_online_error(context, result)
		return false
	end
	return true, result
end

function safe_broadcast(message, params)
	if not (MESSAGEMAN and MESSAGEMAN.Broadcast) then return false end
	return safe_online_call("broadcast " .. tostring(message), function()
		MESSAGEMAN:Broadcast(message, params)
	end)
end

function current_top_screen()
	if not (SCREENMAN and SCREENMAN.GetTopScreen) then return nil end
	local ok, screen = safe_online_call("get top screen", function()
		return SCREENMAN:GetTopScreen()
	end)
	return ok and screen or nil
end

function screen_name(screen)
	if not (screen and screen.GetName) then return "NoScreen" end
	local ok, name = safe_online_call("get screen name", function()
		return screen:GetName()
	end)
	return ok and tostring(name or "NoScreen") or "NoScreen"
end

	function screen_can_transition(screen)
		return screen and screen.SetNextScreenName and screen.StartTransitioningScreen
	end

	local function online_selected_song_field(song, snakeKey, camelKey)
		if type(song) ~= "table" then return "" end
		local value = song[snakeKey]
		if value == nil and camelKey then value = song[camelKey] end
		return tostring(value or "")
	end

	local function current_online_options_redirect_key()
		local room = ITGOnline and ITGOnline.currentRoom or nil
		local selectedSong = room and room.selected_song or ITGOnline and ITGOnline.currentSongPayload or nil
		local roomId = tostring(ITGOnline and ITGOnline.currentRoomId or room and room.id or "")
		local selectedAt = online_selected_song_field(selectedSong, "selected_at", "selectedAt")
		local selectionId = tostring(room and (room.current_selection_id or room.currentSelectionId) or "")
		local songHash = online_selected_song_field(selectedSong, "song_hash", "songHash")
		local chartHash = online_selected_song_field(selectedSong, "chart_hash", "chartHash")
		local title = online_selected_song_field(selectedSong, "title")
		local key = table.concat({ roomId, selectionId, selectedAt, songHash, chartHash }, "|")
		local valid = roomId ~= "" and type(selectedSong) == "table" and (
			selectionId ~= "" or selectedAt ~= "" or songHash ~= "" or chartHash ~= ""
		)
		return key, valid, selectedSong, title
	end

	local function reset_online_options_redirect_guard(reason)
		if onlineOptionsRedirectedSelectionKey ~= "" then
			online_flow_trace("transition_to_options_guard_reset reason=" .. tostring(reason or "unknown")
				.. " previousKey=" .. tostring(onlineOptionsRedirectedSelectionKey)
				.. " age=" .. tostring(GetTimeSinceStart() - (tonumber(onlineOptionsRedirectedAt) or 0)))
		end
		onlineOptionsRedirectedSelectionKey = ""
		onlineOptionsRedirectedAt = 0
	end

	function transition_screen(screen, nextScreen, message, context)
	if not screen_can_transition(screen) then
		online_flow_trace("transition_skipped reason=screen_cannot_transition context="
			.. tostring(context or "unknown")
			.. " screen=" .. tostring(screen_name(screen))
			.. " next=" .. tostring(nextScreen))
		return false
	end
	return safe_online_call("transition " .. tostring(context or nextScreen), function()
		screen:SetNextScreenName(nextScreen)
		screen:StartTransitioningScreen(message or "SM_GoToNextScreen")
	end)
end

local function direct_set_screen(nextScreen, context)
	if not (SCREENMAN and SCREENMAN.SetNewScreen) then
		online_flow_trace("direct_set_screen_skipped reason=no_screenman_set_new_screen"
			.. " context=" .. tostring(context or "unknown")
			.. " next=" .. tostring(nextScreen))
		return false
	end

	return safe_online_call("direct set screen " .. tostring(context or nextScreen), function()
		SCREENMAN:SetNewScreen(nextScreen)
	end)
end

local function transition_evaluation_to_lobby(topScreen, reason)
	local fromScreen = screen_name(topScreen)
	local roomId = tostring(ITGOnline and ITGOnline.currentRoomId or "")
	local phase = tostring(ITGOnline and ITGOnline.currentRoom and ITGOnline.currentRoom.phase or ITGOnline and ITGOnline.currentRoomPhase or "nil")
	local now = GetTimeSinceStart()

	if evaluationExitTransitionRoomId == roomId and (now - (tonumber(evaluationExitTransitionRequestedAt) or 0)) < 1.0 then
		online_flow_trace("evaluation_exit_transition_skip reason=already_requested"
			.. " room=" .. tostring(roomId)
			.. " from=" .. tostring(fromScreen)
			.. " phase=" .. tostring(phase)
			.. " source=" .. tostring(reason or "input"))
		return true
	end

	evaluationExitTransitionRoomId = roomId
	evaluationExitTransitionRequestedAt = now

	if ITGOnline then
		ITGOnline.onlineEvaluationExitRequested = true
		ITGOnline.onlineEvaluationExitRequestedAt = now
	end
	local summary = ITGOnline and ITGOnline.PlayStateSummary and ITGOnline:PlayStateSummary(ITGOnline.currentRoom) or nil
	local cache = ITGOnline and ITGOnline.GetFinalLeaderboardCache and ITGOnline:GetFinalLeaderboardCache(roomId) or nil

	online_flow_trace("evaluation_exit_transition_begin"
		.. " room=" .. tostring(roomId)
		.. " from=" .. tostring(fromScreen)
		.. " to=ScreenOnlineLobbies"
		.. " phase=" .. tostring(phase)
		.. " players=" .. tostring(summary and summary.players or "nil")
		.. " terminal=" .. tostring(summary and summary.terminal or "nil")
		.. " finalResults=" .. tostring(summary and summary.finalResults or "nil")
		.. " finalResultsReady=" .. tostring(summary and summary.finalResultsReady == true)
		.. " cacheRows=" .. tostring(cache and cache.rows and #cache.rows or 0)
		.. " cacheSource=" .. tostring(cache and cache.source or "nil")
		.. " source=" .. tostring(reason or "input"))

	-- For online evaluation, direct navigation is intentional. The normal
	-- ScreenEvaluation timer/branch path is guarded to prevent automatic exits;
	-- relying on the same SM_GoToNextScreen animation path for a manual exit can
	-- leave the screen in an OffCommand state without ever reaching the lobby.
	local ok = direct_set_screen("ScreenOnlineLobbies", "evaluation_to_lobby")
	if ok then
		online_flow_trace("evaluation_exit_transition_sent"
			.. " method=SCREENMAN.SetNewScreen"
			.. " room=" .. tostring(roomId)
			.. " from=" .. tostring(fromScreen)
			.. " to=ScreenOnlineLobbies"
			.. " source=" .. tostring(reason or "input"))
		return true
	end

	online_flow_trace("evaluation_exit_transition_fallback"
		.. " method=StartTransitioningScreen"
		.. " room=" .. tostring(roomId)
		.. " from=" .. tostring(fromScreen)
		.. " to=ScreenOnlineLobbies"
		.. " source=" .. tostring(reason or "input"))
	return transition_screen(topScreen, "ScreenOnlineLobbies", "SM_GoToNextScreen", "evaluation_to_lobby_fallback")
end

function room_id_from(value)
	if type(value) ~= "table" then return "" end
	return tostring(value.roomId or value.room_id or value.id or "")
end

function current_room_id()
	if ITGOnline and ITGOnline.RoomKey then
		return tostring(ITGOnline:RoomKey(ITGOnline.currentRoomId) or "")
	end
	return tostring(ITGOnline and ITGOnline.currentRoomId or "")
end

function online_room_ids_match(left, right)
	if ITGOnline and ITGOnline.RoomMatchesId then
		return ITGOnline:RoomMatchesId({ id = left }, right)
	end
	left = tostring(left or "")
	right = tostring(right or "")
	return left ~= "" and left == right
end

local function protocol_sort_key(value)
	value = tostring(value or "")
	if value:match("^%d+$") then
		value = value:gsub("^0+", "")
		return value == "" and "0" or value
	end
	return value
end

local function protocol_sort_key_less(left, right)
	left = protocol_sort_key(left)
	right = protocol_sort_key(right)
	local leftNumeric = left:match("^%d+$") ~= nil
	local rightNumeric = right:match("^%d+$") ~= nil
	if leftNumeric and rightNumeric and #left ~= #right then return #left < #right end
	return left < right
end

function normalize_room_phase(phase)
	if ITGOnline and ITGOnline.NormalizeRoomPhase then
		return ITGOnline:NormalizeRoomPhase(phase)
	end
	return tostring(phase or ""):lower()
end

function current_user_id()
	return tostring(ITGOnline and ITGOnline.user and ITGOnline.user.id or "")
end

function user_is_member_of_room(room, userId)
	userId = tostring(userId or "")
	if userId == "" or type(room) ~= "table" then return false end
	for member in ivalues(room.members or {}) do
		local user = type(member and member.user) == "table" and member.user or nil
		if tostring(member and (member.user_id or member.userId or member.playerId or member.id) or "") == userId
			or tostring(user and user.id or "") == userId then
			return true
		end
	end
	return false
end

function current_room_is_active(options)
	options = type(options) == "table" and options or {}
	if not (ITGOnline and ITGOnline.currentRoomId and ITGOnline.currentRoom) then
		return false, nil, "missing_room"
	end

	local room = ITGOnline.currentRoom
	local roomId = current_room_id()
	if roomId == "" or not online_room_ids_match(room.id or room.room_id or room.roomId, roomId) then
		return false, room, "room_id_mismatch"
	end

	local userId = current_user_id()
	if options.requireUser ~= false and userId == "" then
		return false, room, "missing_user"
	end
	if options.requireMember ~= false and userId ~= "" and not user_is_member_of_room(room, userId) then
		return false, room, "user_not_in_room"
	end

	if options.payload then
		local payloadRoomId = room_id_from(options.payload)
		if payloadRoomId == "" or not online_room_ids_match(payloadRoomId, roomId) then
			return false, room, "payload_room_mismatch"
		end
	end

	if options.phase then
		local currentPhase = normalize_room_phase(room.phase)
		local phases = type(options.phase) == "table" and options.phase or { options.phase }
		local phaseOk = false
		for _, phase in ipairs(phases) do
			if currentPhase == tostring(phase) then
				phaseOk = true
				break
			end
		end
		if not phaseOk then
			return false, room, "phase_mismatch"
		end
	end

	return true, room, nil
end

function room_context_token(kind)
	onlineOperationToken = onlineOperationToken + 1
	return {
		kind = tostring(kind or "operation"),
		serial = onlineOperationToken,
		roomId = current_room_id(),
	}
end

function room_context_still_active(token, options)
	if onlineHandlerShuttingDown then return false end
	if token and token.roomId and token.roomId ~= "" and token.roomId ~= current_room_id() then
		return false
	end
	return current_room_is_active(options)
end

function clear_pending_room_state()
	songSelected = false
	lastSongPreviewSentAt = 0
	lastSongPreviewKey = ""
	pendingOnlineSongSelectionKey = ""
	pendingOnlineSongSelectionAt = 0
	pendingOnlineSongSelectionToken = pendingOnlineSongSelectionToken + 1
end

function begin_actor_operation(actor, key)
	if not actor then return nil end
	onlineOperationToken = onlineOperationToken + 1
	actor.onlineOperationTokens = actor.onlineOperationTokens or {}
	actor.onlineOperationTokens[key] = onlineOperationToken
	return onlineOperationToken
end

function actor_operation_is_current(actor, key, token)
	return not onlineHandlerShuttingDown
		and actor ~= nil
		and token ~= nil
		and actor.onlineOperationTokens ~= nil
		and actor.onlineOperationTokens[key] == token
end

function build_lobby_payload(room)
	if not (ITGOnline and ITGOnline.LobbyStatePayload and type(room) == "table") then
		return nil
	end
	local ok, payload = safe_online_call("build lobby payload", function()
		return ITGOnline:LobbyStatePayload(room)
	end)
	return ok and payload or nil
end

function maybe_set_lobby_ready(reason, callback)
	if not (ITGOnline and ITGOnline.SetReady) then
		online_flow_trace("lobby_ready_skipped reason=" .. tostring(reason or "unknown")
			.. " cause=no_set_ready_api"
			.. " room=" .. tostring(ITGOnline and ITGOnline.currentRoomId or "nil"))
		if callback then callback(false) end
		return
	end

	local active, room, inactiveReason = current_room_is_active({ phase = { "lobby", "lobby_ready" } })
	local phase = tostring(room and room.phase or "")
	if not active then
		online_flow_trace("lobby_ready_skipped reason=" .. tostring(reason or "unknown")
			.. " cause=" .. tostring(inactiveReason)
			.. " room=" .. current_room_id()
			.. " phase=" .. tostring(phase)
			.. " members=" .. tostring(room and room.members and #room.members or 0))
		if callback then callback(false, { room = room, skipped = true, reason = inactiveReason }) end
		return
	end

	if phase ~= "lobby" and phase ~= "lobby_ready" then
		online_flow_trace("lobby_ready_skipped reason=" .. tostring(reason or "unknown")
			.. " cause=invalid_phase"
			.. " room=" .. tostring(ITGOnline.currentRoomId or "nil")
			.. " phase=" .. tostring(phase)
			.. " members=" .. tostring(room and room.members and #room.members or 0))
		ready_debug("skip lobby_ready reason=" .. tostring(reason or "unknown")
			.. " phase=" .. tostring(phase))
		if callback then callback(true, { room = room, skipped = true }) end
		return
	end

	local function send_lobby_ready(verifiedRoom)
		local verifiedPhase = tostring(verifiedRoom and verifiedRoom.phase or phase)
		if verifiedPhase ~= "lobby" and verifiedPhase ~= "lobby_ready" then
			online_flow_trace("lobby_ready_skipped reason=" .. tostring(reason or "unknown")
				.. " cause=server_phase_changed"
				.. " room=" .. tostring(ITGOnline.currentRoomId or "nil")
				.. " localPhase=" .. tostring(phase)
				.. " serverPhase=" .. tostring(verifiedPhase))
			if verifiedRoom and ITGOnline.ApplyRoomSnapshot then
				ITGOnline:ApplyRoomSnapshot(verifiedRoom, "lobby_ready_server_phase_changed")
			end
			if ITGOnline.EnforceRoomPhaseScreen then ITGOnline:EnforceRoomPhaseScreen() end
			if callback then callback(true, { room = verifiedRoom or room, skipped = true, reason = "server_phase_changed" }) end
			return
		end

		online_flow_trace("lobby_ready_request reason=" .. tostring(reason or "unknown")
			.. " room=" .. tostring(ITGOnline.currentRoomId or "nil")
			.. " phase=" .. tostring(verifiedPhase)
			.. " verified=" .. tostring(verifiedRoom ~= nil))
		ITGOnline:SetReady("lobby_ready", true, callback)
	end

	if ITGOnline.IsCurrentUserReadyInRoom and ITGOnline:IsCurrentUserReadyInRoom(room) then
		online_flow_trace("lobby_ready_skipped reason=" .. tostring(reason or "unknown")
			.. " cause=already_ready"
			.. " room=" .. tostring(ITGOnline.currentRoomId or "nil")
			.. " phase=" .. tostring(phase))
		ready_debug("skip lobby_ready reason=" .. tostring(reason or "unknown")
			.. " already_ready=1")
		if callback then callback(true, { room = room, skipped = true }) end
		return
	end

	if ITGOnline.FetchRoom and ITGOnline.currentRoomId then
		local verifyRoomId = ITGOnline.currentRoomId
		online_flow_trace("lobby_ready_verify_server_phase reason=" .. tostring(reason or "unknown")
			.. " room=" .. tostring(verifyRoomId)
			.. " localPhase=" .. tostring(phase))
		ITGOnline:FetchRoom(verifyRoomId, function(ok, decoded)
			if not online_room_ids_match(ITGOnline and ITGOnline.currentRoomId, verifyRoomId) then
				online_flow_trace("lobby_ready_verify_ignored reason=room_changed"
					.. " expected=" .. tostring(verifyRoomId)
					.. " current=" .. tostring(ITGOnline and ITGOnline.currentRoomId or "nil"))
				if callback then callback(false, { skipped = true, reason = "room_changed" }) end
				return
			end
			if ok and decoded and decoded.room then
				send_lobby_ready(decoded.room)
				return
			end
			online_flow_trace("lobby_ready_verify_failed reason=" .. tostring(reason or "unknown")
				.. " room=" .. tostring(verifyRoomId)
				.. " localPhase=" .. tostring(phase))
			send_lobby_ready(nil)
		end)
		return
	end

	send_lobby_ready(nil)
end

function maybe_preview_current_online_song(force)
	if not (ITGOnline
		and ITGOnline.PreviewSong
		and ITGOnline.currentRoomId
		and ITGOnline.currentRoom
		and ITGOnline.user) then
		online_flow_trace("song_preview_skipped cause=missing_context"
			.. " hasClient=" .. tostring(ITGOnline ~= nil)
			.. " hasPreviewApi=" .. tostring(ITGOnline and ITGOnline.PreviewSong ~= nil)
			.. " room=" .. tostring(ITGOnline and ITGOnline.currentRoomId or "nil")
			.. " hasRoom=" .. tostring(ITGOnline and ITGOnline.currentRoom ~= nil)
			.. " hasUser=" .. tostring(ITGOnline and ITGOnline.user ~= nil))
		return
	end

	local active, room, inactiveReason = current_room_is_active({ phase = "lobby" })
	local phase = normalize_room_phase(room and room.phase)
	if not active then
		online_flow_trace("song_preview_skipped cause=invalid_phase"
			.. " room=" .. tostring(ITGOnline.currentRoomId or "nil")
			.. " phase=" .. tostring(phase)
			.. " reason=" .. tostring(inactiveReason))
		return
	end

	if room.selected_song ~= nil then
		online_flow_trace("song_preview_skipped cause=selected_song_exists"
			.. " room=" .. tostring(ITGOnline.currentRoomId or "nil"))
		return
	end

	local manager = room.manager
	if not manager or tonumber(manager.id) ~= tonumber(ITGOnline.user.id) then
		online_flow_trace("song_preview_skipped cause=not_manager"
			.. " room=" .. tostring(ITGOnline.currentRoomId or "nil")
			.. " manager=" .. tostring(manager and manager.id or "nil")
			.. " user=" .. tostring(ITGOnline.user and ITGOnline.user.id or "nil"))
		return
	end

	if not GAMESTATE then
		online_flow_trace("song_preview_skipped cause=no_gamestate")
		return
	end
	local song = GAMESTATE:GetCurrentSong()
	if not song then
		online_flow_trace("song_preview_skipped cause=no_current_song"
			.. " room=" .. tostring(ITGOnline.currentRoomId or "nil"))
		return
	end

	local now = GetTimeSinceStart()
	local key = song:GetSongDir() or song:GetDisplayFullTitle() or ""
	if not force and key == lastSongPreviewKey and now - lastSongPreviewSentAt < 1.5 then
		online_flow_trace("song_preview_skipped cause=debounced"
			.. " room=" .. tostring(ITGOnline.currentRoomId or "nil")
			.. " key=" .. tostring(key)
			.. " age=" .. tostring(now - lastSongPreviewSentAt))
		return
	end

	online_flow_trace("song_preview_request room=" .. tostring(ITGOnline.currentRoomId or "nil")
		.. " key=" .. tostring(key)
		.. " force=" .. tostring(force == true))
	local token = room_context_token("song_preview")
	ITGOnline:PreviewSong(function(ok)
		if not room_context_still_active(token, { phase = "lobby" }) then
			online_flow_trace("song_preview_response_ignored reason=stale_context"
				.. " key=" .. tostring(key))
			return
		end
		online_flow_trace("song_preview_response room=" .. tostring(ITGOnline.currentRoomId or "nil")
			.. " key=" .. tostring(key)
			.. " ok=" .. tostring(ok == true))
		if ok then
			lastSongPreviewKey = key
			lastSongPreviewSentAt = now
		else
			lastSongPreviewKey = ""
			lastSongPreviewSentAt = 0
		end
	end)
end

function split_online_song_path(path)
	path = tostring(path or "")
	local pack, song = path:match("^([^/]+)/(.+)$")
	if pack then
		return pack, song
	end
	return path, nil
end

OnlineStartCountdownText = function()
	if not (ITGOnline and ITGOnline.SecondsUntilScheduledStart) then return nil end

	local seconds = ITGOnline.VisibleSecondsUntilScheduledStart
		and ITGOnline:VisibleSecondsUntilScheduledStart()
		or ITGOnline:SecondsUntilScheduledStart()
	if not seconds then return nil end

	if seconds > 0 then
		return "La chanson demarre dans " .. tostring(math.ceil(seconds)) .. "..."
	end

	return "Chanson demarree. Synchronisation audio..."
end

OnlinePlayingSpinner = function()
	local frames = { "|", "/", "-", "\\" }
	return frames[(math.floor(GetTimeSinceStart() * 6) % #frames) + 1]
end

FormatRemainingSeconds = function(value)
	local seconds = math.max(0, math.ceil(tonumber(value) or 0))
	local minutes = math.floor(seconds / 60)
	local remainder = seconds % 60
	return string.format("%d:%02d", minutes, remainder)
end

OnlineRemainingText = function(data)
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

QueueOnlineGameplayStartRelease = function(actor)
	if actor and actor.sleep and actor.queuecommand and not actor.onlineStartReleaseQueued then
		actor.onlineStartReleaseQueued = true
		actor:sleep(0.05):queuecommand("ReleaseOnlineGameplayAtStart")
	end
end

local lastGameplayPauseScreen = nil
local lastGameplayPauseState = nil
SetGameplayPaused = function(screen, paused)
	if not screen then return end

	local screenName = screen.GetName and screen:GetName() or ""
	local isGameplay = gameplayScreens[screenName] == true
	local screenKey = tostring(screen)
	paused = paused == true

	if isGameplay and lastGameplayPauseScreen == screenKey and lastGameplayPauseState == paused then
		return
	end

	if not screen.PauseGame then
		online_flow_trace("gameplay_pause_skipped reason=no_pause_method"
			.. " screen=" .. tostring(screenName)
			.. " paused=" .. tostring(paused))
		return
	end
	if not safe_online_call("pause gameplay", function() screen:PauseGame(paused) end) then
		return
	end
	if isGameplay then
		lastGameplayPauseScreen = screenKey
		lastGameplayPauseState = paused
	else
		lastGameplayPauseScreen = nil
		lastGameplayPauseState = nil
	end
end

ReleaseOnlineGameplay = function(screen, secondsUntilStart)
	local lateBy = secondsUntilStart and math.max(0, -secondsUntilStart) or 0
	if online_trace then
		online_trace("FLOW release_gameplay screen=" .. tostring(screen and screen:GetName() or "nil")
			.. " secondsUntilStart=" .. tostring(secondsUntilStart)
			.. " lateBy=" .. tostring(lateBy)
			.. " phase=" .. tostring(ITGOnline and ITGOnline.currentRoom and ITGOnline.currentRoom.phase or "no-room"))
	end
	if screen and lateBy > 0.03 and screen.SeekMusicSeconds then
		safe_online_call("seek online gameplay", function()
			screen:SeekMusicSeconds(lateBy)
		end)
	end

	UnlockOnlineInput()
	SetGameplayPaused(screen, false)
	if ITGOnline and ITGOnline.Heartbeat then ITGOnline:Heartbeat("playing") end
end

-- This input handler is used to lock input while we're waiting on the server to tell us to proceed.
-- It does nothing, but it's necessary to prevent the player from interacting with the screen
-- until everyone is ready.
-- Holding Start for 5 seconds will disconnect from the lobby.
InputHandler = function(event)
	if not event then return false end
	local topScreen = current_top_screen()
	if topScreen and isWaiting and event.PlayerNumber then
		local pn = ToEnumShortString(event.PlayerNumber)
		if event.type == "InputEventType_FirstPress" and event.GameButton == "Back" then
			if ITGOnline and ITGOnline.ShouldBlockEvaluationExit and ITGOnline:ShouldBlockEvaluationExit("sync_input_back") then
				if online_trace then
					online_trace("FLOW sync_input_back_blocked reason=awaiting_results_ready"
						.. " screen=" .. tostring(topScreen:GetName())
						.. " phase=" .. tostring(ITGOnline.currentRoom and ITGOnline.currentRoom.phase or ITGOnline.currentRoomPhase))
				end
				return true
			end
			isWaiting = false
			UnlockOnlineInput()
			if ITGOnline and ITGOnline.MarkReturnedToLobby then
				ITGOnline:MarkReturnedToLobby()
			end
			if topScreen:GetName() ~= "ScreenOnlineLobbies" then
				transition_screen(topScreen, "ScreenOnlineLobbies", "SM_GoToNextScreen", "sync_input_back")
			end
			return true
		elseif event.type == "InputEventType_FirstPress" and event.GameButton == "Start" then
			startHoldTime[pn] = GetTimeSinceStart()
			lastDisconnectCountdown = nil
			if topScreen:GetName() == "ScreenGameplay" then
				readyState[pn] = true
				safe_broadcast("UpdateMachineState")
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
						local topScreen = current_top_screen()
						if topScreen and topScreen:GetName() == "ScreenGameplay" then
							SetGameplayPaused(topScreen, false)
						end
						if ITGOnline and ITGOnline.MarkReturnedToLobby then
							ITGOnline:MarkReturnedToLobby()
						end
						safe_broadcast("DisconnectOnline", {leaveRoom=true})
					end
			end
		elseif event.type == "InputEventType_Release" and event.GameButton == "Start" then
			startHoldTime[pn] = 0
			lastDisconnectCountdown = nil
		end
	end

	return false
end

OnlineOptionsInputHandler = function(event)
	if not current_room_is_active({ requireMember = false }) then return false end
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
	if not (SCREENMAN and SCREENMAN.set_input_redirected) then return end
	for player in ivalues(PlayerNumber) do
		SCREENMAN:set_input_redirected(player, false)
	end
end

OnlineGameplayScreen = function()
	if not GAMESTATE then return "ScreenGameplay" end
	local style = GAMESTATE:GetCurrentStyle() and GAMESTATE:GetCurrentStyle():GetName() or ""
	return style == "routine" and "ScreenGameplayShared" or "ScreenGameplay"
end

OnlineSongKey = function(data)
	if not data or not data.songInfo then return "" end
	return tostring(data.roomId or data.code or "")
		.. "|" .. tostring(data.songInfo.roundId or "")
		.. "|" .. tostring(data.songInfo.songHash or "")
		.. "|" .. tostring(data.songInfo.chartHash or data.songInfo.songPath or "")
		.. "|" .. tostring(data.songInfo.selectedAt or "")
end

CurrentUserInLobbyState = function(data)
	if not (data and data.players and ITGOnline and ITGOnline.user) then return false end
	if not current_room_is_active({ payload = data }) then return false end
	local selfId = tostring(ITGOnline.user.id or "")
	if selfId == "" then return false end
	for _, player in ipairs(data.players) do
		if tostring(player and player.playerId or "") == selfId then
			return true
		end
	end
	return false
end

ApplyOnlineSongSelection = function(songInfo)
	if not songInfo or not songInfo.songPath then return false end
	if ITGOnline and ITGOnline.PackSync and ITGOnline.PackSync.ApplySelectedChart then
		online_flow_trace("pack_sync_apply_selected_chart title=" .. tostring(songInfo.title or songInfo.name or "")
			.. " pack=" .. tostring(songInfo.pack or "")
			.. " path=" .. tostring(songInfo.songPath or songInfo.folder_name or "")
			.. " selected_at=" .. tostring(songInfo.selectedAt or songInfo.selected_at or "")
			.. " chart_hash=" .. tostring(songInfo.chartHash or songInfo.chart_hash or ""):sub(1, 12))
		return ITGOnline.PackSync:ApplySelectedChart(songInfo)
	end

	if not (GAMESTATE and SONGMAN) then
		online_flow_trace("legacy_apply_song_selection_missing_runtime"
			.. " hasGameState=" .. tostring(GAMESTATE ~= nil)
			.. " hasSongMan=" .. tostring(SONGMAN ~= nil))
		return false
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
		safe_broadcast("OnlineMissingSong", {songInfo=songInfo})
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
		safe_broadcast("OnlineMissingSong", {songInfo=songInfo, reason="chart_hash_mismatch"})
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

	if not matchedSteps then
		online_flow_trace("legacy_apply_song_selection_no_playable_steps path=" .. tostring(songInfo.songPath))
		SM("Aucun chart jouable trouve pour : " .. tostring(songInfo.songPath))
		safe_broadcast("OnlineMissingSong", {songInfo=songInfo, reason="no_playable_steps"})
		restorePreviousSelection()
		return false
	end

	local localPayload = nil
	if ITGOnline and ITGOnline.BuildSongPayloadFor then
		local ok, payload = safe_online_call("build online song payload", function()
			return ITGOnline:BuildSongPayloadFor(song, matchedSteps)
		end)
		localPayload = ok and payload or nil
	elseif ITGOnline and ITGOnline.BuildSongPayload then
		local ok, payload = safe_online_call("build legacy online song payload", function()
			GAMESTATE:SetCurrentSong(song)
			for player in ivalues(GAMESTATE:GetEnabledPlayers()) do
				GAMESTATE:SetCurrentSteps(player, matchedSteps)
			end
			return ITGOnline:BuildSongPayload()
		end)
		restorePreviousSelection()
		localPayload = ok and payload or nil
	end

	local requiresHashVerification = (songInfo.songHash and songInfo.songHash ~= "")
		or (songInfo.chartHash and songInfo.chartHash ~= "")
	if requiresHashVerification and not localPayload then
		online_flow_trace("legacy_apply_song_selection_payload_unavailable path=" .. tostring(songInfo.songPath))
		SM("Chanson online impossible a verifier localement : " .. tostring(songInfo.songPath))
		safe_broadcast("OnlineMissingSong", {songInfo=songInfo, reason="local_payload_unavailable"})
		restorePreviousSelection()
		return false
	end

	if localPayload then
		if songInfo.songHash and songInfo.songHash ~= "" and localPayload.song_hash ~= songInfo.songHash then
			online_flow_trace("legacy_apply_song_selection_song_hash_mismatch path=" .. tostring(songInfo.songPath)
				.. " expected=" .. tostring(songInfo.songHash):sub(1, 12)
				.. " local=" .. tostring(localPayload.song_hash):sub(1, 12))
			SM("Hash audio online different pour : " .. tostring(songInfo.songPath))
			safe_broadcast("OnlineMissingSong", {songInfo=songInfo, reason="hash_mismatch"})
			restorePreviousSelection()
			return false
		end
		if songInfo.chartHash and songInfo.chartHash ~= "" and localPayload.chart_hash ~= songInfo.chartHash then
			online_flow_trace("legacy_apply_song_selection_chart_hash_mismatch path=" .. tostring(songInfo.songPath)
				.. " expected=" .. tostring(songInfo.chartHash):sub(1, 12)
				.. " local=" .. tostring(localPayload.chart_hash):sub(1, 12))
			SM("Hash chart online different pour : " .. tostring(songInfo.songPath))
			safe_broadcast("OnlineMissingSong", {songInfo=songInfo, reason="hash_mismatch"})
			restorePreviousSelection()
			return false
		end
	end

	local applyOk = safe_online_call("apply online song selection", function()
		GAMESTATE:SetCurrentSong(song)
		for player in ivalues(GAMESTATE:GetEnabledPlayers()) do
			GAMESTATE:SetCurrentSteps(player, matchedSteps)
		end
	end)
	if not applyOk then
		restorePreviousSelection()
		return false
	end

	safe_broadcast("OnlineSongAvailable", {songInfo=songInfo})
	online_flow_trace("legacy_apply_song_selection_success path=" .. tostring(songInfo.songPath))
	return true
end

	TransitionToOnlineOptions = function()
		local topScreen = current_top_screen()
		if not topScreen then
			online_flow_trace("transition_to_options_skipped reason=no_top_screen")
			return
		end

		local roomPhase = ITGOnline and ITGOnline.currentRoom and ITGOnline.currentRoom.phase or "no-room"
		local redirectSelectionKey, redirectSelectionKeyValid, selectedSong, selectedTitle = current_online_options_redirect_key()
		local screenName = topScreen:GetName()
		online_flow_trace("transition_to_options_decision_begin"
			.. " from=" .. tostring(screenName)
			.. " phase=" .. tostring(roomPhase)
			.. " room=" .. tostring(ITGOnline and ITGOnline.currentRoomId or "nil")
			.. " key=" .. tostring(redirectSelectionKey)
			.. " keyValid=" .. tostring(redirectSelectionKeyValid == true)
			.. " previousRedirectKey=" .. tostring(onlineOptionsRedirectedSelectionKey or "")
			.. " hasSelectedSong=" .. tostring(type(selectedSong) == "table")
			.. " title=" .. tostring(selectedTitle or ""))
		if not current_room_is_active({ phase = "config" }) then
			if online_trace then
				online_trace("FLOW transition_to_options_skipped reason=phase_not_config"
					.. " from=" .. tostring(screenName)
					.. " phase=" .. tostring(roomPhase)
					.. " key=" .. tostring(redirectSelectionKey))
			end
			return
		end
	if ITGOnline
		and ITGOnline.currentRoom
		and ITGOnline.IsCurrentUserReadyInRoom
		and ITGOnline:IsCurrentUserReadyInRoom(ITGOnline.currentRoom, "config_ready") then
			if online_trace then
				online_trace("FLOW transition_to_options_skipped reason=current_user_already_config_ready"
					.. " phase=" .. tostring(roomPhase)
					.. " room=" .. tostring(ITGOnline.currentRoomId or "nil")
					.. " key=" .. tostring(redirectSelectionKey))
			end
			return
		end

		if screenName == "ScreenPlayerOptions"
			or screenName == "ScreenPlayerOptions2"
			or screenName == "ScreenPlayerOptions3"
			or screenName == "ScreenGameplay"
			or screenName == "ScreenGameplayShared" then
			online_flow_trace("transition_to_options_skipped reason=already_on_blocked_screen"
				.. " screen=" .. tostring(screenName)
				.. " phase=" .. tostring(roomPhase)
				.. " key=" .. tostring(redirectSelectionKey))
			return
		end

		if is_evaluation_screen(screenName) then
			if ITGOnline then
				ITGOnline.onlineEvaluationExitRequested = true
				ITGOnline.onlineEvaluationExitRequestedAt = GetTimeSinceStart()
				if ITGOnline.ClearFinalLeaderboardCache then
					ITGOnline:ClearFinalLeaderboardCache("new_song_options_redirect_from_evaluation", ITGOnline.currentRoomId)
				end
			end
			if online_trace then
				online_trace("FLOW evaluation_forced_exit_to_options reason=new_song_selected_while_in_evaluation"
					.. " screen=" .. tostring(screenName)
					.. " phase=" .. tostring(ITGOnline and ITGOnline.currentRoom and ITGOnline.currentRoom.phase or "no-room")
					.. " room=" .. tostring(ITGOnline and ITGOnline.currentRoomId or "nil")
					.. " key=" .. tostring(redirectSelectionKey))
			end
		end

		if not redirectSelectionKeyValid then
			online_flow_trace("transition_to_options_skipped reason=invalid_selection_key"
				.. " from=" .. tostring(screenName)
				.. " phase=" .. tostring(roomPhase)
				.. " key=" .. tostring(redirectSelectionKey)
				.. " hasSelectedSong=" .. tostring(type(selectedSong) == "table"))
			return
		end

		if redirectSelectionKey == onlineOptionsRedirectedSelectionKey then
			if online_trace then
				online_trace("FLOW transition_to_options_skipped reason=selection_already_redirected"
					.. " from=" .. tostring(screenName)
					.. " phase=" .. tostring(roomPhase)
					.. " key=" .. tostring(redirectSelectionKey)
					.. " age=" .. tostring(GetTimeSinceStart() - (tonumber(onlineOptionsRedirectedAt) or 0)))
			end
			return
		end

		if online_trace then
			online_trace("FLOW transition_to_options from=" .. tostring(screenName)
				.. " phase=" .. tostring(roomPhase)
				.. " key=" .. tostring(redirectSelectionKey))
		end
	if ITGOnline and ITGOnline.TraceOnlineState then
		ITGOnline:TraceOnlineState("screen_transition_to_options", {
			source = "TransitionToOnlineOptions",
			screenFrom = screenName,
			screenTo = "ScreenPlayerOptions",
			reason = "manager_selected_song",
		})
	end
	if not (topScreen.SetNextScreenName and topScreen.StartTransitioningScreen) then
		if online_trace then
			online_trace("FLOW transition_to_options_skipped reason=screen_cannot_transition"
				.. " screen=" .. tostring(screenName))
		end
		return
	end
		safe_broadcast("OnlineOptionsRedirectWait", {
			show=false,
			reason="transition_to_options",
			screen=screenName,
			phase=roomPhase,
		})
		onlineOptionsRedirectedSelectionKey = redirectSelectionKey
		onlineOptionsRedirectedAt = GetTimeSinceStart()
		online_flow_trace("transition_to_options_guard_set"
			.. " key=" .. tostring(onlineOptionsRedirectedSelectionKey)
			.. " from=" .. tostring(screenName)
			.. " target=ScreenPlayerOptions")
		transition_screen(topScreen, "ScreenPlayerOptions", "SM_GoToNextScreen", "online_options")
	end

OnlineDeferredReplayBlockedScreen = function(screenName)
	screenName = tostring(screenName or "")
	return screenName == "ScreenReloadSongsOnline"
		or screenName == "ScreenReloadSongs"
		or screenName == "ScreenReloadSSM"
		or screenName:find("ReloadSongs", 1, true) ~= nil
end

OnlinePayloadMatchesActiveRoom = function(payload)
	return current_room_is_active({ payload = payload })
end

CurrentOnlineSelectionKey = function()
	if not current_room_is_active() then return "" end
	if not GAMESTATE then return "" end

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

local onlineSongSelectionAllowedPhases = { "lobby", "lobby_ready", "config", "results" }

SelectOnlineSongAsManager = function(actor)
	local active, activeRoom, inactiveReason = current_room_is_active({ phase = onlineSongSelectionAllowedPhases })
	if not active then
		online_flow_trace("song_selected_ignored reason=no_room"
			.. " inactiveReason=" .. tostring(inactiveReason or "nil")
			.. " room=" .. tostring(ITGOnline and ITGOnline.currentRoomId or "nil")
			.. " phase=" .. tostring(activeRoom and activeRoom.phase or ITGOnline and ITGOnline.currentRoom and ITGOnline.currentRoom.phase or "nil"))
		return
	end

	local selectionKey = CurrentOnlineSelectionKey()
	if selectionKey == "" then
		online_flow_trace("song_selected_ignored reason=empty_selection_key")
		return
	end
	local now = GetTimeSinceStart()
	online_flow_trace("song_selected_attempt room=" .. tostring(ITGOnline.currentRoomId or "nil")
		.. " key=" .. tostring(selectionKey)
		.. " pendingKey=" .. tostring(pendingOnlineSongSelectionKey or "")
		.. " pendingAge=" .. tostring(now - (tonumber(pendingOnlineSongSelectionAt) or 0))
		.. " hasActor=" .. tostring(actor ~= nil))
	if pendingOnlineSongSelectionKey == selectionKey and (now - pendingOnlineSongSelectionAt) < 12 then
		online_flow_trace("song_selected_ignored reason=selection_inflight key=" .. tostring(selectionKey))
		return
	end
	pendingOnlineSongSelectionKey = selectionKey
	pendingOnlineSongSelectionAt = now
	pendingOnlineSongSelectionToken = pendingOnlineSongSelectionToken + 1
	local selectionToken = pendingOnlineSongSelectionToken
	local selectionContext = room_context_token("select_song")

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

		if not room_context_still_active(selectionContext, { phase = onlineSongSelectionAllowedPhases }) then
			clearPendingSelection()
			online_flow_trace("song_selected_ignored reason=stale_room_after_room_sync key=" .. tostring(selectionKey))
			return
		end

		if not online_room_ids_match(room and (room.id or room.room_id or room.roomId), current_room_id()) then
			clearPendingSelection()
			online_flow_trace("song_selected_ignored reason=synced_room_mismatch key=" .. tostring(selectionKey)
				.. " room=" .. tostring(room and room.id or "nil")
				.. " current=" .. current_room_id())
			return
		end

		if not ITGOnline.user then
			clearPendingSelection()
			online_flow_trace("song_selected_ignored reason=no_user_after_room_sync room=" .. tostring(ITGOnline.currentRoomId))
			safe_broadcast("OnlineResponseStatus", {
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
		safe_broadcast("OnlineOptionsRedirectWait", {
			show=true,
			reason="manager_song_selected",
			roomId=ITGOnline.currentRoomId,
			selectionKey=selectionKey,
		})

		ITGOnline:SelectSongAndMarkLobbyReady(function(ok, decoded, response)
			if not room_context_still_active(selectionContext, { phase = onlineSongSelectionAllowedPhases }) then
				clearPendingSelection()
				online_flow_trace("song_selected_callback_ignored reason=stale_room key=" .. tostring(selectionKey))
				return
			end
			if pendingOnlineSongSelectionKey == selectionKey and pendingOnlineSongSelectionToken == selectionToken then
				pendingOnlineSongSelectionKey = ""
			end

			if ok then
				online_flow_trace("song_selected_handler_ok transition=options")
				TransitionToOnlineOptions()
				return
			end

			safe_broadcast("OnlineOptionsRedirectWait", {
				show=false,
				reason="song_selection_failed",
				roomId=ITGOnline and ITGOnline.currentRoomId or nil,
				selectionKey=selectionKey,
			})
			online_flow_trace("song_selected_handler_failed status=" .. tostring(response and response.statusCode or "nil")
				.. " error=" .. tostring(decoded and decoded.error_code or response and response.error or "nil"))
			safe_broadcast("OnlineResponseStatus", {
				event="selectSong",
				success=false,
				message=(decoded and decoded.message) or (response and response.errorMessage) or "Echec de selection de la chanson."
			})
		end)
	end

	if ITGOnline.EnsureCurrentRoom then
		online_flow_trace("song_selected_sync_room_begin room=" .. tostring(ITGOnline.currentRoomId or "nil")
			.. " key=" .. tostring(selectionKey))
		ITGOnline:EnsureCurrentRoom(function(ok, room, response)
			if not room_context_still_active(selectionContext, { phase = onlineSongSelectionAllowedPhases }) then
				clearPendingSelection()
				online_flow_trace("song_selected_sync_room_ignored reason=stale_context key=" .. tostring(selectionKey))
				return
			end
			online_flow_trace("song_selected_sync_room_response room=" .. tostring(ITGOnline and ITGOnline.currentRoomId or "nil")
				.. " key=" .. tostring(selectionKey)
				.. " ok=" .. tostring(ok == true)
				.. " status=" .. tostring(response and response.statusCode or "nil")
				.. " phase=" .. tostring(room and room.phase or "nil"))
			if ok and room then
				finishSelection(room)
				return
			end

			clearPendingSelection()
			online_flow_trace("song_selected_ignored reason=room_sync_failed status=" .. tostring(response and response.statusCode or "nil"))
			safe_broadcast("OnlineResponseStatus", {
				event="selectSong",
				success=false,
				message=(response and response.errorMessage) or "Impossible de recuperer l'etat du salon."
			})
		end)
		return
	end

	finishSelection(ITGOnline.currentRoom)
end

TransitionToOnlineGameplay = function()
	if not current_room_is_active({ phase = "starting" }) then
		online_flow_trace("transition_to_gameplay_skipped reason=inactive_room")
		return
	end

	local topScreen = current_top_screen()
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
	if ITGOnline and ITGOnline.TraceOnlineState then
		ITGOnline:TraceOnlineState("screen_transition_to_gameplay", {
			source = "TransitionToOnlineGameplay",
			screenFrom = screenName,
			screenTo = OnlineGameplayScreen(),
			pendingRoom = pendingOnlineStartRoomId or "nil",
		})
	end
	SL.Global.Online = SL.Global.Online or {}
	SL.Global.Online.GameplayLayoutActive = true
	transition_screen(topScreen, OnlineGameplayScreen(), "SM_GoToNextScreen", "online_gameplay")
end

ReturnToOnlineLobbyFromMusicSelect = function()
	local topScreen = current_top_screen()
	if not topScreen or topScreen:GetName() ~= "ScreenSelectMusic" then return false end
	if not current_room_is_active({ requireMember = false, requireUser = false }) then return false end

	UnlockOnlineInput()
	if topScreen.ReturnToOnlineLobbyFromMusicSelect then
		if ITGOnline and ITGOnline.TraceOnlineState then
			ITGOnline:TraceOnlineState("screen_transition_music_select_to_lobby_delegate", {
				source = "ReturnToOnlineLobbyFromMusicSelect",
				screenFrom = topScreen:GetName(),
				screenTo = "ScreenOnlineLobbies",
				delegate = true,
			})
		end
		topScreen:ReturnToOnlineLobbyFromMusicSelect()
		return true
	end

	if ITGOnline and ITGOnline.TraceOnlineState then
		ITGOnline:TraceOnlineState("screen_transition_music_select_to_lobby", {
			source = "ReturnToOnlineLobbyFromMusicSelect",
			screenFrom = topScreen:GetName(),
			screenTo = "ScreenOnlineLobbies",
			delegate = false,
		})
	end
	transition_screen(topScreen, "ScreenOnlineLobbies", "SM_GoToNextScreen", "music_select_to_lobby")
	return true
end

PollOnlineStart = function(actor, roomId)
	if not actor or not roomId or not (ITGOnline and ITGOnline.FetchRoom) then return end
	if not online_room_ids_match(roomId, current_room_id()) then
		online_flow_trace("poll_online_start_skipped reason=stale_room"
			.. " requested=" .. tostring(roomId)
			.. " current=" .. current_room_id())
		return
	end

	local timer = actor:GetChild("OnlineStartPollTimer")
	if not timer then return end

	actor.onlineStartPollCount = (tonumber(actor.onlineStartPollCount) or 0) + 1
	if actor.onlineStartPollCount > 60 then
		online_flow_trace("poll_online_start_aborted reason=budget_exhausted room=" .. tostring(roomId))
		pendingOnlineStartRoomId = nil
		actor.onlineStartPollCount = 0
		return
	end

	pendingOnlineStartRoomId = roomId
	timer:stoptweening()
	timer:sleep(1):queuecommand("Poll")
end

SelectMusicInputHandler = function(event)
	if not event or event.type ~= "InputEventType_FirstPress" then return false end

	local deviceButton = ""
	if event.DeviceInput and event.DeviceInput.button then
		deviceButton = string.lower(tostring(event.DeviceInput.button))
	end

	if event.GameButton == "Back" or string.find(deviceButton, "backspace", 1, true) then
		if SOUND and THEME and THEME.GetPathS then
			safe_online_call("play online cancel sound", function()
				SOUND:PlayOnce(THEME:GetPathS("Common", "Cancel"))
			end)
		end
		return ReturnToOnlineLobbyFromMusicSelect()
	end

	return false
end

ReturnToOnlineLobbyFromEvaluation = function(reason)
	local topScreen = current_top_screen()
	if not topScreen then
		if online_trace then online_trace("FLOW evaluation_exit_skipped reason=no_top_screen source=" .. tostring(reason or "input")) end
		return false
	end
	if not evaluationScreens[topScreen:GetName()] then
		if online_trace then
			online_trace("FLOW evaluation_exit_skipped reason=not_evaluation_screen source=" .. tostring(reason or "input")
				.. " screen=" .. tostring(topScreen:GetName()))
		end
		return false
	end
	if not current_room_is_active({ requireMember = false, requireUser = false }) then
		if online_trace then
			online_trace("FLOW evaluation_exit_skipped reason=no_current_room source=" .. tostring(reason or "input")
				.. " screen=" .. tostring(topScreen:GetName()))
		end
		return false
	end
	if ITGOnline.ShouldBlockEvaluationExit and ITGOnline:ShouldBlockEvaluationExit(reason) then
		if online_trace then
			online_trace("FLOW evaluation_exit_blocked reason=awaiting_results_ready source=" .. tostring(reason or "input")
				.. " screen=" .. tostring(topScreen:GetName())
				.. " phase=" .. tostring(ITGOnline.currentRoom and ITGOnline.currentRoom.phase or ITGOnline.currentRoomPhase))
		end
		return true
	end

	UnlockOnlineInput()
	if ITGOnline then
		ITGOnline.onlineEvaluationExitRequested = true
		ITGOnline.onlineEvaluationExitRequestedAt = GetTimeSinceStart()
	end
	if online_trace then
		local summary = ITGOnline and ITGOnline.PlayStateSummary and ITGOnline:PlayStateSummary(ITGOnline.currentRoom) or nil
		local cache = ITGOnline and ITGOnline.GetFinalLeaderboardCache and ITGOnline:GetFinalLeaderboardCache(ITGOnline.currentRoomId) or nil
		online_trace("FLOW evaluation_exit_requested reason=" .. tostring(reason or "input")
			.. " screen=" .. tostring(topScreen:GetName())
			.. " phase=" .. tostring(ITGOnline.currentRoom and ITGOnline.currentRoom.phase or ITGOnline.currentRoomPhase)
			.. " players=" .. tostring(summary and summary.players or "nil")
			.. " terminal=" .. tostring(summary and summary.terminal or "nil")
			.. " finalResults=" .. tostring(summary and summary.finalResults or "nil")
			.. " finalResultsReady=" .. tostring(summary and summary.finalResultsReady == true)
			.. " cacheRows=" .. tostring(cache and cache.rows and #cache.rows or 0)
			.. " cacheSource=" .. tostring(cache and cache.source or "nil"))
	end
	if ITGOnline and ITGOnline.TraceOnlineState then
		ITGOnline:TraceOnlineState("screen_transition_evaluation_to_lobby", {
			source = "ReturnToOnlineLobbyFromEvaluation",
			screenFrom = topScreen:GetName(),
			screenTo = "ScreenOnlineLobbies",
			reason = reason or "input",
		})
	end
	return transition_evaluation_to_lobby(topScreen, reason)
end

ITGOnlineReturnToLobbyFromEvaluation = ReturnToOnlineLobbyFromEvaluation

EvaluationInputHandler = function(event)
	if not event or event.type ~= "InputEventType_FirstPress" then return false end
	if online_trace then
		online_trace("FLOW evaluation_input button=" .. tostring(event.GameButton or "")
			.. " device=" .. tostring(event.DeviceInput and event.DeviceInput.button or "nil")
			.. " room=" .. tostring(ITGOnline and ITGOnline.currentRoomId or "nil")
			.. " phase=" .. tostring(ITGOnline and ITGOnline.currentRoom and ITGOnline.currentRoom.phase or "nil"))
	end
	if not current_room_is_active({ requireMember = false, requireUser = false }) then
		if online_trace then online_trace("FLOW evaluation_input_ignored reason=no_current_room") end
		return false
	end

	local deviceButton = ""
	if event.DeviceInput and event.DeviceInput.button then
		deviceButton = string.lower(tostring(event.DeviceInput.button))
	end

	local isEscape = string.find(deviceButton, "escape", 1, true)
		or string.find(deviceButton, "backspace", 1, true)
	local isConfirm = event.GameButton == "Start"
		or string.find(deviceButton, "enter", 1, true)
		or string.find(deviceButton, "return", 1, true)
		or deviceButton == "devicebutton_z"
		or deviceButton == "z"
	local isBack = event.GameButton == "Back"
	if online_trace then
		local topScreen = current_top_screen()
		online_trace("FLOW evaluation_input_decoded button=" .. tostring(event.GameButton or "")
			.. " device=" .. tostring(deviceButton)
			.. " topScreen=" .. tostring(screen_name(topScreen))
			.. " isConfirm=" .. tostring(isConfirm == true)
			.. " isBack=" .. tostring(isBack == true)
			.. " isEscape=" .. tostring(isEscape and true or false)
			.. " exitRequested=" .. tostring(ITGOnline and ITGOnline.onlineEvaluationExitRequested == true)
			.. " returnedKey=" .. tostring(ITGOnline and ITGOnline.onlineGameplayEvaluationReturnedKey or ""))
	end

	if isConfirm or isBack or isEscape then
		return ReturnToOnlineLobbyFromEvaluation("evaluation_input")
	end

	return true
end

RestoreCurrentRoom = function(actor, callback)
	if not (actor and ITGOnline and ITGOnline.FetchCurrentRoom) then
		if online_trace then online_trace("FLOW restore_current_room skipped reason=no_fetch_current_room") end
		if callback then callback(false) end
		return
	end

	if online_trace then
		online_trace("FLOW restore_current_room begin inLobby=" .. tostring(actor and actor.inLobby == true)
			.. " currentRoomId=" .. tostring(ITGOnline and ITGOnline.currentRoomId or "nil"))
	end
	ITGOnline:FetchCurrentRoom(function(ok, decoded, response)
		if online_trace then
			online_trace("FLOW restore_current_room result ok=" .. tostring(ok == true)
				.. " status=" .. tostring(response and response.statusCode or "nil")
				.. " hasRoom=" .. tostring(decoded and decoded.room ~= nil)
				.. " room=" .. tostring(decoded and decoded.room and decoded.room.id or "nil")
				.. " phase=" .. tostring(decoded and decoded.room and decoded.room.phase or "nil"))
		end
		if ok and decoded and decoded.room then
			if room_id_from(decoded.room) == "" then
				if callback then callback(false) end
				return
			end
			actor.inLobby = true
			local payload = build_lobby_payload(decoded.room)
			DisplayLobbyState(payload, actor)
			safe_broadcast("OnlineLobbyState", payload)
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

OrderPlayers = function(data, localScreenName)
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
	if type(data) ~= "table" then return updatedData end
	updatedData.songInfo = type(data.songInfo) == "table" and data.songInfo or nil

	-- Use the current screen as the baseline to prevent
	-- incorrectly reporting all players as synchronized.
	local firstScreen = localScreenName
	-- Process the scoreScreens first so we can sort the players by score.
	for rawPlayer in ivalues(type(data.players) == "table" and data.players or {}) do
		local player = type(rawPlayer) == "table" and rawPlayer or {}
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
		if aScore ~= bScore then
			return aScore > bScore
		end
		local aUser = type(a.user) == "table" and a.user or {}
		local bUser = type(b.user) == "table" and b.user or {}
			local aRankKey = protocol_sort_key(a.rank or a.sort_index or a.sortIndex or a.user_id or aUser.id or a.id)
			local bRankKey = protocol_sort_key(b.rank or b.sort_index or b.sortIndex or b.user_id or bUser.id or b.id)
			if aRankKey ~= bRankKey then
				return protocol_sort_key_less(aRankKey, bRankKey)
		end
		return tostring(a.name or aUser.name or "") < tostring(b.name or bUser.name or "")
	end)

	-- Then add all the other players in other screens below.
	for rawPlayer in ivalues(type(data.players) == "table" and data.players or {}) do
		local player = type(rawPlayer) == "table" and rawPlayer or {}
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
	if not actor or not actor.GetChild then
		if online_trace then online_trace("FLOW display_lobby skipped reason=no_actor") end
		online_flow_trace("display_lobby_state_skipped reason=no_actor"
			.. " hasData=" .. tostring(data ~= nil))
		return
	end
	if type(data) ~= "table" then
		online_flow_trace("display_lobby_state_skipped reason=invalid_payload")
		return
	end
	if not OnlinePayloadMatchesActiveRoom(data) then
		online_flow_trace("display_lobby_state_skipped reason=inactive_room"
			.. " payloadRoomId=" .. tostring(room_id_from(data))
			.. " currentRoomId=" .. current_room_id())
		return
	end
	if ITGOnline and ITGOnline.StoreFinalLeaderboardFromRoom then
		ITGOnline:StoreFinalLeaderboardFromRoom(data, "display_lobby_state")
	end
	-- Keep in mind that SCREENMAN:GetTopScreen() might return nil while screens transition.
	local screen = current_top_screen()
	local screenName = screen and screen:GetName() or "NoScreen"
	local flowContext = screenName == "ScreenOnlineLobbies" and "display_lobby" or "apply_room_state"
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
		local summary = ITGOnline and ITGOnline.PlayStateSummary and ITGOnline:PlayStateSummary(ITGOnline.currentRoom) or nil
		local cache = ITGOnline and ITGOnline.GetFinalLeaderboardCache and ITGOnline:GetFinalLeaderboardCache(data and data.roomId) or nil
		online_flow_trace(flowContext .. "_state_begin"
			.. " roomId=" .. tostring(data and data.roomId or "nil")
			.. " code=" .. tostring(data and data.code or "nil")
			.. " phase=" .. tostring(data and data.phase or "nil")
			.. " screen=" .. tostring(screenName)
			.. " players=" .. tostring(data and data.players and #data.players or 0)
			.. " sessions=" .. tostring(data and data.playState and #(data.playState.sessions or {}) or 0)
			.. " finalResults=" .. tostring(data and data.finalResults and #data.finalResults or 0)
			.. " currentSummaryPlayers=" .. tostring(summary and summary.players or "nil")
			.. " currentSummaryTerminal=" .. tostring(summary and summary.terminal or "nil")
			.. " currentSummaryFinalResults=" .. tostring(summary and summary.finalResults or "nil")
			.. " currentSummaryFinalReady=" .. tostring(summary and summary.finalResultsReady == true)
			.. " cacheRows=" .. tostring(cache and cache.rows and #cache.rows or 0)
			.. " cacheSource=" .. tostring(cache and cache.source or "nil")
			.. " hasSongInfo=" .. tostring(data and data.songInfo ~= nil)
			.. " isManager=" .. tostring(data and data.isManager == true)
			.. " actorInLobby=" .. tostring(actor.inLobby == true))
		if online_trace then
			online_trace("FLOW " .. flowContext .. " room=" .. tostring(data and data.roomId or "")
				.. " phase=" .. tostring(data and data.phase or "")
				.. " screen=" .. tostring(screenName)
				.. " startAt=" .. tostring(data and data.startAt or "")
				.. " startedAt=" .. tostring(data and data.startedAt or "")
				.. " sessions=" .. tostring(data and data.playState and #(data.playState.sessions or {}) or 0)
				.. " finalResults=" .. tostring(data and data.finalResults and #data.finalResults or 0))
		end
	end

	local updatedData = OrderPlayers(data, screenName)
	local orderedParts = {}
	for index, player in ipairs(updatedData and updatedData.players or {}) do
		orderedParts[#orderedParts + 1] = table.concat({
			tostring(index),
			tostring(player.playerId or player.userId or player.id or ""),
			tostring(player.profileName or player.name or ""),
			tostring(player.ready == true),
			tostring(player.readyPendingServer == true),
			tostring(player.screen or player.currentScreen or ""),
			tostring(player.playState or player.play_state or ""),
			tostring(player.packSyncStatus or player.pack_sync_status or ""),
			tostring(player.songAvailable),
		}, ":")
	end
	online_flow_trace(flowContext .. "_state_ordered"
		.. " roomId=" .. tostring(data and data.roomId or "nil")
		.. " phase=" .. tostring(data and data.phase or "nil")
		.. " screen=" .. tostring(screenName)
		.. " inputPlayers=" .. tostring(data and data.players and #data.players or 0)
		.. " orderedPlayers=" .. tostring(updatedData and updatedData.players and #updatedData.players or 0)
		.. " isManager=" .. tostring(data and data.isManager == true)
		.. " song=" .. tostring(data and data.songInfo and (data.songInfo.title or data.songInfo.songHash) or "none")
		.. " rows=" .. table.concat(orderedParts, ","))
	if online_trace then
		online_trace("FLOW " .. flowContext .. "_ordered room=" .. tostring(data and data.roomId or "")
			.. " phase=" .. tostring(data and data.phase or "")
			.. " screen=" .. tostring(screenName)
			.. " inputPlayers=" .. tostring(data and data.players and #data.players or 0)
			.. " orderedPlayers=" .. tostring(updatedData and updatedData.players and #updatedData.players or 0)
			.. " isManager=" .. tostring(data and data.isManager == true)
			.. " song=" .. tostring(data and data.songInfo and (data.songInfo.title or data.songInfo.songHash) or "none"))
	end

	local lines = {}

	if screenName == "ScreenOnlineLobbies" and isWaiting then
		isWaiting = false
			for player in ivalues(PlayerNumber) do
				SCREENMAN:set_input_redirected(player, false)
			end
		if online_trace then
			online_trace("FLOW lobby_sync_lock_released room=" .. tostring(data and data.roomId or "")
				.. " phase=" .. tostring(data and data.phase or "")
				.. " players=" .. tostring(updatedData and updatedData.players and #updatedData.players or 0))
		end
	elseif evaluationScreens[screenName] and isWaiting then
		isWaiting = false
			for player in ivalues(PlayerNumber) do
				SCREENMAN:set_input_redirected(player, false)
			end
		if online_trace then
			online_trace("FLOW evaluation_sync_lock_released room=" .. tostring(data and data.roomId or "")
				.. " screen=" .. tostring(screenName)
				.. " phase=" .. tostring(data and data.phase or "")
				.. " players=" .. tostring(updatedData and updatedData.players and #updatedData.players or 0)
				.. " anyInGameplay=" .. tostring(updatedData and updatedData.aux and updatedData.aux.anyInGameplay or false))
		end
	end

	if isWaiting then
		local readyToUnlock = false
		local playerCount = #updatedData.players
		if gameplayScreens[screenName] then
			-- Gameplay no longer uses manual ready-up; we only wait for screen synchronization.
			readyToUnlock = updatedData.aux.allInSameScreen or playerCount <= 1
		elseif evaluationScreens[screenName] then
			-- Evaluation may show input again only once the authoritative
			-- server results are ready. Failed rounds can have no active
			-- gameplay left while the server is still waiting for final failed
			-- scores, so "no one is playing" is not enough.
			readyToUnlock = not (ITGOnline and ITGOnline.ShouldBlockEvaluationExit and ITGOnline:ShouldBlockEvaluationExit("evaluation_sync_unlock"))
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
					UnlockOnlineInput()

					if gameplayScreens[screenName] then
						local topScreen = current_top_screen()
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
					UnlockOnlineInput()
					local topScreen = current_top_screen()
					SetGameplayPaused(topScreen, false)
					if ITGOnline and ITGOnline.MarkPlayEntered then ITGOnline:MarkPlayEntered() end
				elseif gameplayScreens[screenName] and data.phase == "results" then
					UnlockOnlineInput()
					local topScreen = current_top_screen()
					SetGameplayPaused(topScreen, false)
					local summary = ITGOnline and ITGOnline.PlayStateSummary and ITGOnline:PlayStateSummary(ITGOnline.currentRoom) or nil
					local forceKey = table.concat({
						tostring(data and data.roomId or ""),
						tostring(data and data.startAt or ""),
						tostring(data and data.startedAt or ""),
						tostring(summary and summary.finalResults or 0),
						tostring(summary and summary.finalResultsReady == true),
					}, "|")
					if forceKey ~= lastGameplayResultsForceKey then
						lastGameplayResultsForceKey = forceKey
						online_flow_trace("gameplay_results_authoritative_transition_check"
							.. " room=" .. tostring(data and data.roomId or "nil")
							.. " screen=" .. tostring(screenName)
							.. " players=" .. tostring(summary and summary.players or "nil")
							.. " terminal=" .. tostring(summary and summary.terminal or "nil")
							.. " finalResults=" .. tostring(summary and summary.finalResults or "nil")
							.. " finalResultsReady=" .. tostring(summary and summary.finalResultsReady == true))
					end
					if ITGOnline and ITGOnline.ForceGameplayEvaluationIfResultsReady then
						ITGOnline:ForceGameplayEvaluationIfResultsReady("display_lobby_state_results_phase")
					end
					if ITGOnline and ITGOnline.EnforceRoomPhaseScreen then
						ITGOnline:EnforceRoomPhaseScreen(screenName)
					end
				elseif gameplayScreens[screenName] and (data.phase == "config" or data.phase == "lobby_ready" or data.phase == "lobby") then
					UnlockOnlineInput()
					local topScreen = current_top_screen()
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
			if (data.phase == "playing" or data.phase == "results") and player.playState and player.playState ~= "playing" then
				if data.phase == "results" and player.waitingOnEvaluation == true then
					if player.playState == "failed" then
						stateText = " - evaluation [F]"
					elseif player.playState == "disconnected" then
						stateText = " - evaluation [X]"
					else
						stateText = " - evaluation [OK]"
					end
				elseif player.playState == "finished" then
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
			local playerName = tostring(player.profileName or player.displayName or player.name or "Joueur")
			local playerAndScreen = tostring(i)..'. '..playerName..playingText..readyText..stateText
			if screenName ~= player.screenName then
				playerAndScreen = playerAndScreen.." - in "..displayedScreen
			end

			lines[#lines+1] = playerAndScreen
			for scoreScreen in ivalues(scoreScreens) do
				if player.screenName == scoreScreen then
					-- Display canonical competition score (aligned with in-game online score),
					-- and keep accuracy as secondary diagnostic info when it differs.
					local score = tonumber(player.score) or tonumber(player.exScore) or 0
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
			local scorePercent = tonumber(result.displayed_percent or result.displayedPercent or result.score_percent)
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
					local redirectKey, redirectKeyValid = current_online_options_redirect_key()
					if redirectKeyValid and redirectKey ~= onlineOptionsRedirectedSelectionKey then
						reset_online_options_redirect_guard("display_lobby_new_selection")
					end
					online_flow_trace("song_selection_apply_decision"
						.. " screen=" .. tostring(screenName)
						.. " phase=" .. tostring(data.phase)
						.. " songKey=" .. tostring(songKey)
						.. " lastOptionsSongKey=" .. tostring(lastOnlineOptionsSongKey)
						.. " redirectKey=" .. tostring(redirectKey)
						.. " redirectKeyValid=" .. tostring(redirectKeyValid == true)
						.. " redirectedKey=" .. tostring(onlineOptionsRedirectedSelectionKey)
						.. " shouldApplyInLobby=" .. tostring(shouldApplyInLobby == true))
					if is_evaluation_screen(screenName) then
					online_flow_trace("song_selection_apply_from_evaluation"
						.. " screen=" .. tostring(screenName)
						.. " phase=" .. tostring(data.phase)
						.. " key=" .. tostring(songKey))
					if ApplyOnlineSongSelection(data.songInfo) then
						if data.phase == "lobby_ready" then
							online_flow_trace("transition_to_options_deferred reason=evaluation_lobby_ready_waiting_for_config"
								.. " key=" .. tostring(songKey)
								.. " room=" .. tostring(data.roomId or data.id or "nil"))
								local availabilityContext = room_context_token("evaluation_song_available")
								if ITGOnline.ConfirmSelectedSongAvailability then
									ITGOnline:ConfirmSelectedSongAvailability("evaluation_local_song_available", function(ok)
										if not room_context_still_active(availabilityContext, { phase = { "lobby_ready", "config" }, payload = data }) then
											online_flow_trace("song_availability_callback_ignored reason=stale_context key=" .. tostring(songKey))
											return
										end
										if ok then
											maybe_set_lobby_ready("evaluation_local_song_available")
											if ITGOnline and ITGOnline.EnforceRoomPhaseScreen then
											ITGOnline:EnforceRoomPhaseScreen(screenName)
										end
									end
								end)
							else
								maybe_set_lobby_ready("evaluation_local_song_available")
								if ITGOnline and ITGOnline.EnforceRoomPhaseScreen then
									ITGOnline:EnforceRoomPhaseScreen(screenName)
								end
							end
						else
							lastOnlineOptionsSongKey = songKey
							if ITGOnline and ITGOnline.EnforceRoomPhaseScreen then
								ITGOnline:EnforceRoomPhaseScreen(screenName)
							end
						end
					else
						online_flow_trace("song_selection_apply_deferred reason=evaluation_missing_or_downloading"
							.. " screen=" .. tostring(screenName)
							.. " phase=" .. tostring(data.phase)
							.. " key=" .. tostring(songKey))
					end
				elseif ApplyOnlineSongSelection(data.songInfo) then
					if data.phase == "lobby_ready" then
						online_flow_trace("transition_to_options_deferred reason=lobby_ready_waiting_for_config"
							.. " key=" .. tostring(songKey)
							.. " room=" .. tostring(data.roomId or data.id or "nil"))
							local availabilityContext = room_context_token("local_song_available")
							if ITGOnline.ConfirmSelectedSongAvailability then
								ITGOnline:ConfirmSelectedSongAvailability("local_song_available", function(ok)
									if not room_context_still_active(availabilityContext, { phase = { "lobby_ready", "config" }, payload = data }) then
										online_flow_trace("song_availability_callback_ignored reason=stale_context key=" .. tostring(songKey))
										return
									end
									if ok then
										maybe_set_lobby_ready("local_song_available")
									end
							end)
						else
							maybe_set_lobby_ready("local_song_available")
						end
					else
						lastOnlineOptionsSongKey = songKey
						TransitionToOnlineOptions()
					end
				end
			end

		if not songSelected then
			local topScreen = current_top_screen()
			if topScreen and topScreen:GetName() == "ScreenSelectMusic" then
				local song = SONGMAN and SONGMAN:FindSong(data.songInfo.songPath) or nil
				local wheel = topScreen:GetMusicWheel()
				local _, songFolder = split_online_song_path(data.songInfo.songPath)
				if not song and songFolder and SONGMAN then
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
					actor.onlineStartPollCount = 0
					UnlockOnlineInput()
					TransitionToOnlineGameplay()
				end
			elseif data.phase == "playing" then
				-- Never auto-transition to gameplay while a room is already in playing phase.
				-- Players who are not already in-song must stay in lobby (countdown/results view)
				-- to avoid involuntary replay loops after reconnect/crash/end-of-song races.
				pendingOnlineStartRoomId = nil
			end

	local display = actor:GetChild("Display")
	if display and display.playcommand then
		display:playcommand("UpdateText", {text=table.concat(lines, "\n")})
	end
end

HandleResponse = function(response, actor)
	if type(response) ~= "table" then return end
	local event = response.event
	local data = response.data

	if event == "lobbyState" then
		if OnlinePayloadMatchesActiveRoom(data) then
			actor.inLobby = true
			DisplayLobbyState(data, actor)
			safe_broadcast("OnlineLobbyState", data or {})
		end
	elseif event == "lobbySearched" then
		safe_broadcast("LobbySearched", {
			lobbies = data and data.lobbies or {}
		})
	elseif event == "lobbyLeft" then
		actor.inLobby = false
		safe_broadcast("OnlineLobbyLeft", data or {})
	elseif event == "clientDisconnected" then
		actor.inLobby = false
		safe_broadcast("OnlineClientDisconnected", data or {})
	elseif event == "responseStatus" then
		safe_broadcast("OnlineResponseStatus", data or {})
	end
end

-- Only allow one instance of the online handler at a time.
-- Things can get a bit convoluted if we have many handlers trying to manage
-- multiple connections.
local onlineHandler = nil
local onlineHandlerInstance = nil
local onlineConnectionTimerNames = {
	"RealtimeDeadmanTimer",
	"OnlineHeartbeatTimer",
	"ReconnectTimer",
	"DeferredLobbyRefreshTimer",
}
local onlineRoomTimerNames = {
	"OnlinePlayingCountdownTimer",
	"OnlineGameplayStartTimer",
	"PreviewInitialSongTimer",
	"ReplayDeferredLobbyStateTimer",
	"ManagerAutoReadyRetryTimer",
}

function stop_named_timers(actor, names)
	if not actor then return end
	for _, name in ipairs(names) do
		local timer = actor:GetChild(name)
		if timer then
			if online_trace then online_trace("FLOW timer_stop name=" .. tostring(name)) end
			timer:stoptweening()
		end
	end
end

function schedule_named_timer(actor, name, delay, command)
	if not actor or onlineHandlerShuttingDown then
		if online_trace then
			online_trace("FLOW timer_schedule_skipped name=" .. tostring(name)
				.. " reason=" .. (not actor and "no_actor" or "handler_shutting_down")
				.. " delay=" .. tostring(delay)
				.. " command=" .. tostring(command))
		end
		return
	end
	local timer = actor:GetChild(name)
	delay = tonumber(delay) or 0
	if online_trace then
		online_trace("FLOW timer_schedule name=" .. tostring(name)
			.. " delay=" .. tostring(delay)
			.. " command=" .. tostring(command)
			.. " dedicatedTimer=" .. tostring(timer ~= nil))
	end
	if timer then
		timer:stoptweening()
		timer:sleep(math.max(0, delay)):queuecommand(command)
	else
		actor:sleep(math.max(0, delay)):queuecommand(command)
	end
end

function normalized_room_phase_for_runtime()
	if ITGOnline and ITGOnline.NormalizeRoomPhase then
		return ITGOnline:NormalizeRoomPhase(ITGOnline.currentRoom and ITGOnline.currentRoom.phase or nil)
	end
	return tostring(ITGOnline and ITGOnline.currentRoom and ITGOnline.currentRoom.phase or ""):lower()
end

function current_online_screen_name()
	local screen = SCREENMAN and SCREENMAN:GetTopScreen() or nil
	return screen and screen:GetName() or "NoScreen"
end

function room_runtime_should_run()
	local phase = normalized_room_phase_for_runtime()
	return phase == "starting" or phase == "playing"
end

function room_fast_runtime_should_run()
	if not room_runtime_should_run() then
		return false
	end

	local screenName = current_online_screen_name()
	return not is_evaluation_screen(screenName) and screenName ~= "ScreenOnlineLobbies"
end

function room_gameplay_runtime_should_run()
	return room_runtime_should_run() and gameplayScreens[current_online_screen_name()] == true
end

function live_score_finalized_for_runtime()
	return ITGOnline and ITGOnline.IsLiveScoreFinalizedForCurrentRound
		and ITGOnline:IsLiveScoreFinalizedForCurrentRound("online_helpers_runtime")
end

function start_connection_timers(actor)
	if not actor or onlineHandlerShuttingDown then
		if online_trace then online_trace("FLOW connection_timers_start_skipped") end
		return
	end
	if online_trace then online_trace("FLOW connection_timers_start") end
	schedule_named_timer(actor, "RealtimeDeadmanTimer", 1, "Fire")
	schedule_named_timer(actor, "OnlineHeartbeatTimer", 5, "Fire")
end

function stop_connection_timers(actor)
	if online_trace then online_trace("FLOW connection_timers_stop") end
	stop_named_timers(actor, onlineConnectionTimerNames)
end

local stop_room_timers

function start_room_timers(actor, reason)
	if not actor or onlineHandlerShuttingDown then
		if online_trace then
			online_trace("FLOW room_timers_start_skipped reason="
				.. (not actor and "no_actor" or "handler_shutting_down"))
		end
		return
	end

	local phase = normalized_room_phase_for_runtime()
	if not room_fast_runtime_should_run() then
		if actor.roomTimersActive then
			stop_room_timers(actor)
		end
		if online_trace then
			online_trace("FLOW room_timers_start_skipped reason=inactive_runtime phase=" .. tostring(phase)
				.. " screen=" .. tostring(current_online_screen_name())
				.. " source=" .. tostring(reason or "unknown"))
		end
		return
	end

	if actor.roomTimersActive then
		if online_trace then
			online_trace("FLOW room_timers_start_skipped reason=already_active phase=" .. tostring(phase)
				.. " source=" .. tostring(reason or "unknown"))
		end
		return
	end

	actor.roomTimersActive = true
	if online_trace then online_trace("FLOW room_timers_start phase=" .. tostring(phase)
		.. " screen=" .. tostring(current_online_screen_name())
		.. " source=" .. tostring(reason or "unknown")) end
	schedule_named_timer(actor, "OnlinePlayingCountdownTimer", 0.25, "Fire")
end

stop_room_timers = function(actor, reason)
	if not actor then return end
	actor.roomTimersActive = false
	if online_trace then online_trace("FLOW room_timers_stop reason=" .. tostring(reason or "unknown")
		.. " phase=" .. tostring(normalized_room_phase_for_runtime())
		.. " screen=" .. tostring(current_online_screen_name())) end
	stop_named_timers(actor, onlineRoomTimerNames)
end

	local function clear_room_async_state(actor)
		if online_trace then
			online_trace(
				"FLOW clear_room_async_state_begin actor=" .. tostring(actor ~= nil) ..
				" pendingConfigReady=" .. tostring(pendingConfigReady ~= nil) ..
				" pendingOnlineStartRoomId=" .. tostring(pendingOnlineStartRoomId) ..
				" lastOnlineGameplayRoomId=" .. tostring(lastOnlineGameplayRoomId) ..
				" lastOnlineOptionsSongKey=" .. tostring(lastOnlineOptionsSongKey))
		end
		stop_room_timers(actor, "clear_room_async_state")
		stop_named_timers(actor, { "ConfigReadyRetryTimer" })
		pendingConfigReady = nil
		pendingManagerAutoReadyRetryKey = ""
	pendingManagerAutoReadyRetryPhase = ""
	pendingOnlineStartRoomId = nil
	lastOnlineGameplayRoomId = nil
		lastOnlineOptionsSongKey = ""
	reset_online_options_redirect_guard("clear_room_async_state")
	replayDeferredLobbyStateQueued = false
	replayDeferredLobbyStateRunning = false
	clear_pending_room_state()
	if actor then
			actor.lastLobbyStatePayload = nil
			actor.onlineStartReleaseQueued = false
			actor.onlineStartPollCount = 0
		end
		if online_trace then
			online_trace("FLOW clear_room_async_state_end")
		end
	end

function clear_room_input_state(reason)
	isWaiting = false
	remove_online_input_callbacks()
	UnlockOnlineInput()
	startHoldTime = { ["P1"] = 0, ["P2"] = 0 }
	lastDisconnectCountdown = nil
	if online_trace then
		online_trace("FLOW room_input_state_cleared reason=" .. tostring(reason or "unknown"))
	end
end

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
				if online_trace then online_trace("FLOW online_handler_init") end
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
						self.roomTimersActive = false
		      end,
					OnCommand=function(self)
						if online_trace then online_trace("FLOW online_handler_on") end
						start_connection_timers(self)
					end,
				OffCommand=function(self)
					if online_trace then
						online_trace("FLOW online_handler_off connected=" .. tostring(self.connected == true)
							.. " socket=" .. tostring(self.socket ~= nil)
							.. " inLobby=" .. tostring(self.inLobby == true)
							.. " currentRoomId=" .. tostring(ITGOnline and ITGOnline.currentRoomId or "nil"))
					end
					onlineHandlerShuttingDown = true
					clear_room_async_state(self)
					stop_connection_timers(self)
					remove_online_input_callbacks()
					if ITGOnline and ITGOnline.Disconnect then
						ITGOnline:Disconnect()
					end
				self.socket = nil
				self.connected = false
				self.connecting = false
				self.inLobby = false
					self.errorMsg = nil
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
						startHoldTime = { ["P1"] = 0, ["P2"] = 0 }
					lastDisconnectCountdown = nil
					self.joinLobbyBusy = false
					self.createLobbyBusy = false
					self.startRoomBusy = false
					self.invitePlayerBusy = false
					self.joinPlayerBusy = false
					self.privateJoinAnswerBusy = false
					self.roomInvitationAnswerBusy = false
					self.searchLobbyBusy = false
					self.leaveLobbyBusy = false
				end,
	      ConnectOnlineMessageCommand=function(self)
	        if self.connecting then
						if online_trace then online_trace("FLOW connect_online_skipped reason=already_connecting") end
						return
					end
					local resumedAfterShutdown = onlineHandlerShuttingDown == true
					onlineHandlerShuttingDown = false
					if resumedAfterShutdown then
						self.joinLobbyBusy = false
						self.createLobbyBusy = false
						self.startRoomBusy = false
						self.invitePlayerBusy = false
						self.joinPlayerBusy = false
						self.privateJoinAnswerBusy = false
						self.roomInvitationAnswerBusy = false
						self.searchLobbyBusy = false
						self.leaveLobbyBusy = false
						online_flow_trace("connect_online_resume_after_shutdown restarting_connection_timers=true busy_flags_cleared=true")
						start_connection_timers(self)
					end
					if online_trace then
						online_trace("FLOW connect_online_begin connected=" .. tostring(self.connected == true)
							.. " socket=" .. tostring(self.socket ~= nil)
							.. " hasClientSocket=" .. tostring(ITGOnline and ITGOnline.socket ~= nil)
							.. " realtimeConnected=" .. tostring(ITGOnline and ITGOnline.realtimeConnected == true)
							.. " error=" .. tostring(self.errorMsg or "nil"))
					end
					if ITGOnline and ITGOnline.socket and ITGOnline.realtimeConnected and self.errorMsg == nil then
						online_trace("FLOW connect_online_reused_existing_socket")
						self.socket = ITGOnline.socket
						self.connected = true
						self.connecting = false
						self.reconnectDelay = 1
						self.inLobby = ITGOnline.currentRoomId ~= nil
						self.errorMsg = nil
						self:GetChild("Display"):visible(false)
						if ITGOnline and ITGOnline.ForceLobbyPresenceHeartbeat then
							online_trace("FLOW connect_online_presence_heartbeat_request source=reused_socket")
							ITGOnline:ForceLobbyPresenceHeartbeat("connect_online_reused_socket")
						else
							online_trace("FLOW connect_online_initial_lobby_snapshot_request source=reused_socket fallback=no_presence_heartbeat")
							safe_broadcast("SearchLobby", {
								force=true,
								minInterval=0,
								reason="connect_online_reused_socket_initial_snapshot",
							})
						end
						return
					end
	        if (self.socket == nil or self.errorMsg ~= nil) and ITGOnline and ITGOnline.Connect then
						self.connecting = true
					onlineHandlerShuttingDown = false
					self.errorMsg = nil
					ITGOnline:Connect({
							open=function()
								if onlineHandlerShuttingDown then return end
								if online_trace then
									online_trace("FLOW connect_online_open room=" .. tostring(ITGOnline and ITGOnline.currentRoomId or "nil"))
								end
								self.connecting = false
								self.socket = ITGOnline.socket
								self.connected = true
								self.reconnectDelay = 1
								self.inLobby = ITGOnline.currentRoomId ~= nil
								self.errorMsg = nil
									self:GetChild("Display"):visible(false)
									if ITGOnline and ITGOnline.ForceLobbyPresenceHeartbeat then
										online_trace("FLOW connect_online_presence_heartbeat_request source=open")
										ITGOnline:ForceLobbyPresenceHeartbeat("connect_online_open")
									else
										online_trace("FLOW connect_online_initial_lobby_snapshot_request source=open fallback=no_presence_heartbeat")
										safe_broadcast("SearchLobby", {
											force=true,
											minInterval=0,
											reason="connect_online_open_initial_snapshot",
										})
									end
							end,
						error=function(message)
							if onlineHandlerShuttingDown then return end
							if online_trace then online_trace("FLOW connect_online_error message=" .. tostring(message or "nil")) end
							self.connecting = false
							self.inLobby = false
							self.connected = false
							self.errorMsg = message or "Connexion echouee"
							self:GetChild("Display"):GetChild("Text"):settext("")
							self:GetChild("Display"):visible(false)
						end,
							close=function()
								if onlineHandlerShuttingDown then return end
								if online_trace then
									online_trace("FLOW connect_online_close disconnecting=" .. tostring(ITGOnline and ITGOnline.disconnecting == true)
										.. " reconnectDelay=" .. tostring(self.reconnectDelay or 1))
								end
								self.connecting = false
								self.connected = false
								self.socket = nil
									self:GetChild("Display"):GetChild("Text"):settext("")
									self:GetChild("Display"):visible(false)
									if not (ITGOnline and ITGOnline.disconnecting) then
										schedule_named_timer(self, "ReconnectTimer", self.reconnectDelay or 1, "Fire")
										self.reconnectDelay = math.min(30, (self.reconnectDelay or 1) * 2)
									end
							end,
						})
	        end
	      end,
					ReconnectOnlineCommand=function(self)
						if onlineHandlerShuttingDown
							or (ITGOnline and ITGOnline.disconnecting)
							or self.connected
							or self.socket ~= nil
							or self.connecting then
							if online_trace then
								online_trace("FLOW reconnect_online_skipped shuttingDown=" .. tostring(onlineHandlerShuttingDown == true)
									.. " disconnecting=" .. tostring(ITGOnline and ITGOnline.disconnecting == true)
									.. " connected=" .. tostring(self.connected == true)
									.. " socket=" .. tostring(self.socket ~= nil)
									.. " connecting=" .. tostring(self.connecting == true))
							end
							return
						end
						if online_trace then online_trace("FLOW reconnect_online_broadcast_connect") end
						safe_broadcast("ConnectOnline")
					end,
						ITGOnlineLobbyRefreshDeferredMessageCommand=function(self, params)
							if onlineHandlerShuttingDown or not self.connected then return end
							local reason = tostring(params and params.reason or "unknown")
							if ITGOnline
								and ITGOnline.IsAutomaticLobbyRefreshSuppressed
								and ITGOnline:IsAutomaticLobbyRefreshSuppressed()
								and reason:sub(1, 11) ~= "post_leave:" then
								online_trace(
									"FLOW lobby_refresh_deferred_ignored reason=post_leave_auto_suppressed source=" ..
									tostring(reason))
								return
							end
							local delay = tonumber(params and params.delay) or 0.25
							if ITGOnline then
								ITGOnline.deferredLobbyRefreshReason = reason
								ITGOnline.deferredLobbyRefreshRoomUiGeneration = tonumber(params and params.roomUiGeneration)
							end
							online_trace(
								"FLOW lobby_refresh_deferred delay=" .. tostring(delay) ..
								" reason=" .. tostring(reason)
								.. " roomUiGeneration=" .. tostring(params and params.roomUiGeneration or "nil"))
							schedule_named_timer(self, "DeferredLobbyRefreshTimer", math.max(0.05, delay), "Fire")
						end,
						DeferredLobbyRefreshCommand=function(self)
							if onlineHandlerShuttingDown or not self.connected then
								online_flow_trace("lobby_refresh_deferred_ignored reason=handler_unavailable"
									.. " shuttingDown=" .. tostring(onlineHandlerShuttingDown == true)
									.. " connected=" .. tostring(self.connected == true)
									.. " socket=" .. tostring(self.socket ~= nil)
									.. " deferredReason=" .. tostring(ITGOnline and ITGOnline.deferredLobbyRefreshReason or "nil"))
								return
							end
							if ITGOnline
								and ITGOnline.IsAutomaticLobbyRefreshSuppressed
								and ITGOnline:IsAutomaticLobbyRefreshSuppressed() then
								local delay = math.max(0.05, (tonumber(ITGOnline.lobbyRefreshDropUntil) or 0) - GetTimeSinceStart() + 0.05)
								online_trace("FLOW lobby_refresh_deferred_rescheduled reason=post_leave_auto_suppressed delay=" .. tostring(delay))
								schedule_named_timer(self, "DeferredLobbyRefreshTimer", delay, "Fire")
								return
							end
							if ITGOnline and ITGOnline.IsLobbyRefreshSuppressed and ITGOnline:IsLobbyRefreshSuppressed() then
							local delay = math.max(0.05, (ITGOnline.LobbyRefreshSuppressionRemaining and ITGOnline:LobbyRefreshSuppressionRemaining() or 0.1) + 0.05)
							online_trace("FLOW lobby_refresh_deferred_rescheduled delay=" .. tostring(delay))
							schedule_named_timer(self, "DeferredLobbyRefreshTimer", delay, "Fire")
							return
							end
							if ITGOnline and ITGOnline.QueueLobbyRefresh then
								local deferredReason = tostring(ITGOnline.deferredLobbyRefreshReason or "")
								local deferredRoomUiGeneration = tonumber(ITGOnline.deferredLobbyRefreshRoomUiGeneration)
								local currentRoomUiGeneration = tonumber(ITGOnline.roomUiLobbyRefreshGeneration) or 0
								if deferredReason:sub(1, 16) == "room_ui_refresh:"
									and deferredRoomUiGeneration ~= nil
									and deferredRoomUiGeneration ~= currentRoomUiGeneration then
									online_trace("FLOW lobby_refresh_deferred_ignored reason=stale_room_ui_refresh"
										.. " source=" .. tostring(deferredReason)
										.. " scheduledGeneration=" .. tostring(deferredRoomUiGeneration)
										.. " currentGeneration=" .. tostring(currentRoomUiGeneration))
									ITGOnline.lobbyRefreshQueued = false
									ITGOnline.lobbyRefreshDeferredScheduled = false
									ITGOnline.roomUiLobbyRefreshDeferredScheduled = false
									ITGOnline.deferredLobbyRefreshReason = ""
									ITGOnline.deferredLobbyRefreshRoomUiGeneration = nil
									return
								end
								local fireReason = tostring(ITGOnline.deferredLobbyRefreshReason or "deferred_lobby_refresh")
								online_flow_trace("lobby_refresh_deferred_fire"
									.. " reason=" .. tostring(fireReason)
									.. " roomUiGeneration=" .. tostring(ITGOnline.deferredLobbyRefreshRoomUiGeneration or "nil")
									.. " currentRoomUiGeneration=" .. tostring(ITGOnline.roomUiLobbyRefreshGeneration or "nil")
									.. " currentRoomId=" .. tostring(ITGOnline.currentRoomId or "nil")
									.. " inFlight=" .. tostring(ITGOnline.lobbyRefreshInFlight == true)
									.. " queued=" .. tostring(ITGOnline.lobbyRefreshQueued == true)
									.. " screen=" .. tostring(ITGOnline.currentScreenName or "nil"))
								ITGOnline.lobbyRefreshQueued = false
								ITGOnline.lobbyRefreshDeferredScheduled = false
								ITGOnline.roomUiLobbyRefreshDeferredScheduled = false
								ITGOnline.deferredLobbyRefreshReason = ""
								ITGOnline.deferredLobbyRefreshRoomUiGeneration = nil
								ITGOnline:QueueLobbyRefresh({
									reason = fireReason,
									forceFresh = fireReason:match("^post_room_exit:") ~= nil,
									ignoreSuppression = fireReason:match("^post_room_exit:") ~= nil,
								})
							end
						end,
						RealtimeDeadmanCommand=function(self)
						if onlineHandlerShuttingDown then
							if online_trace then online_trace("FLOW realtime_deadman_skipped reason=handler_shutting_down") end
							return
						end

					if self.connected and self.socket ~= nil and ITGOnline and ITGOnline.lastRealtimeMessageAt then
						local idle = GetTimeSinceStart() - ITGOnline.lastRealtimeMessageAt
						online_flow_trace_throttled("realtime_deadman_tick", 10.0,
							"realtime_deadman_tick idle=" .. tostring(idle)
							.. " timeout=" .. tostring(self.deadmanTimeoutSeconds or 75)
							.. " connected=" .. tostring(self.connected == true)
							.. " socket=" .. tostring(self.socket ~= nil))
						if idle > (self.deadmanTimeoutSeconds or 75) then
							if online_trace then
								online_trace("FLOW realtime_deadman_timeout idle=" .. tostring(idle)
									.. " timeout=" .. tostring(self.deadmanTimeoutSeconds or 75))
							end
							if ITGOnline and ITGOnline.ForceRealtimeReconnect then
								ITGOnline:ForceRealtimeReconnect("handler_deadman_timeout")
							else
								self.connected = false
								if ITGOnline and ITGOnline.socket then
									ITGOnline.socket:Close()
								end
								self.socket = nil
							end
							safe_broadcast("OnlineResponseStatus", {
								event="websocket",
								success=false,
								message="Realtime connection timed out. Reconnecting..."
								})
								self:playcommand("ReconnectOnline")
							end
						end

					if ITGOnline and ITGOnline.MaintainRealtimeAndRoomSync then
						ITGOnline:MaintainRealtimeAndRoomSync("realtime_deadman_tick")
					end

							schedule_named_timer(self, "RealtimeDeadmanTimer", 1, "Fire")
						end,
					OnlineHeartbeatTickCommand=function(self)
						if onlineHandlerShuttingDown then return end
						if ITGOnline and ITGOnline.RefreshDebugFlags then
							ITGOnline:RefreshDebugFlags(false)
						end

							if self.connected and self.socket ~= nil and ITGOnline and ITGOnline.Heartbeat then
								local screen = current_top_screen()
								local screenName = screen_name(screen)
								local phase = ITGOnline.currentRoom and ITGOnline.currentRoom.phase or nil
								local status = "available"
								if ITGOnline.currentRoomId then
									status = (phase == "playing" or screenName == "ScreenGameplay" or screenName == "ScreenGameplayShared") and "playing" or "in_room"
								end
								online_flow_trace("heartbeat_tick status=" .. tostring(status)
									.. " screen=" .. tostring(screenName)
									.. " room=" .. tostring(ITGOnline.currentRoomId or "nil")
									.. " phase=" .. tostring(phase or "nil")
									.. " connected=" .. tostring(self.connected == true)
									.. " socket=" .. tostring(self.socket ~= nil)
									.. " inLobby=" .. tostring(self.inLobby == true))
								ITGOnline:Heartbeat(status)
							else
								online_flow_trace("heartbeat_tick_skipped connected=" .. tostring(self.connected == true)
									.. " socket=" .. tostring(self.socket ~= nil)
									.. " hasClient=" .. tostring(ITGOnline ~= nil))
							end

							schedule_named_timer(self, "OnlineHeartbeatTimer", 30, "Fire")
						end,
						OnlinePlayingCountdownTickCommand=function(self)
							if onlineHandlerShuttingDown or not self.roomTimersActive then
								online_flow_trace_throttled("online_playing_countdown_skipped", 2.0,
									"online_playing_countdown_skipped shuttingDown=" .. tostring(onlineHandlerShuttingDown == true)
									.. " roomTimersActive=" .. tostring(self.roomTimersActive == true)
									.. " room=" .. tostring(ITGOnline and ITGOnline.currentRoomId or "nil"))
								return
							end
							if not room_fast_runtime_should_run() then
								local phase = normalized_room_phase_for_runtime()
								online_flow_trace("online_playing_countdown_stop reason=inactive_runtime"
									.. " phase=" .. tostring(phase)
									.. " screen=" .. tostring(current_online_screen_name())
									.. " room=" .. tostring(ITGOnline and ITGOnline.currentRoomId or "nil"))
								stop_room_timers(self, "online_playing_countdown_inactive_runtime")
								if ITGOnline and ITGOnline.StopLiveScoreFlush then
									ITGOnline:StopLiveScoreFlush("room_runtime_inactive:" .. tostring(phase) .. ":" .. tostring(current_online_screen_name()))
								end
								return
							end
							online_flow_trace_throttled("online_playing_countdown_tick", 1.0,
								"online_playing_countdown_tick room=" .. tostring(ITGOnline and ITGOnline.currentRoomId or "nil")
								.. " phase=" .. tostring(ITGOnline and ITGOnline.currentRoom and ITGOnline.currentRoom.phase or "nil")
								.. " screen=" .. tostring(current_online_screen_name())
								.. " secondsUntilStart=" .. tostring(ITGOnline and ITGOnline.SecondsUntilScheduledStart and ITGOnline:SecondsUntilScheduledStart() or "nil"))
							if ITGOnline and ITGOnline.PackSync and ITGOnline.PackSync.WatchdogTick then
								ITGOnline.PackSync:WatchdogTick()
							end
							if not onlineHandlerShuttingDown and self.inLobby and self.lastLobbyStatePayload then
								local screen = current_top_screen()
								local screenName = screen_name(screen)
								if screenName == "ScreenOnlineLobbies" and tostring(self.lastLobbyStatePayload.phase or "") == "playing" then
									DisplayLobbyState(self.lastLobbyStatePayload, self)
								end
							end
							if ITGOnline and ITGOnline.FlushLiveScore
								and room_gameplay_runtime_should_run()
								and not live_score_finalized_for_runtime() then
								ITGOnline:FlushLiveScore()
							end
							schedule_named_timer(self, "OnlinePlayingCountdownTimer", 0.25, "Fire")
						end,
					OnlineScoreSnapshotMessageCommand=function(self, params)
						if onlineHandlerShuttingDown then
							online_flow_trace("score_snapshot_ignored reason=handler_shutting_down")
							return
						end
						if not (ITGOnline and ITGOnline.RememberLiveScoreSnapshot and ITGOnline.currentRoomId and ITGOnline.currentRoom and current_room_is_active()) then
							online_flow_trace("score_snapshot_ignored reason=missing_context"
								.. " hasClient=" .. tostring(ITGOnline ~= nil)
								.. " hasRememberApi=" .. tostring(ITGOnline and ITGOnline.RememberLiveScoreSnapshot ~= nil)
								.. " room=" .. tostring(ITGOnline and ITGOnline.currentRoomId or "nil")
								.. " hasRoom=" .. tostring(ITGOnline and ITGOnline.currentRoom ~= nil))
							return
						end
						if not GAMESTATE then return end
						local enabled = GAMESTATE:GetEnabledPlayers()
						local primary = enabled and enabled[1] or nil
						if not (params and primary and params.Player == primary) then
							online_flow_trace("score_snapshot_ignored reason=non_primary_or_missing_params"
								.. " hasParams=" .. tostring(params ~= nil)
								.. " player=" .. tostring(params and params.Player or "nil")
								.. " primary=" .. tostring(primary or "nil"))
							return
						end

						online_flow_trace("score_snapshot_remember room=" .. tostring(ITGOnline.currentRoomId or "nil")
							.. " phase=" .. tostring(ITGOnline.currentRoom and ITGOnline.currentRoom.phase or "nil")
							.. " player=" .. tostring(params.Player)
							.. " score=" .. tostring(params.ScorePercent or "nil")
							.. " ex=" .. tostring(params.ExScorePercent or "nil")
							.. " hardex=" .. tostring(params.HardExScorePercent or "nil")
							.. " displayed=" .. tostring(params.DisplayedPercent or "nil")
							.. " combo=" .. tostring(params.Combo or "nil"))
						ITGOnline:RememberLiveScoreSnapshot({
							scorePercent = params.ScorePercent,
							exScorePercent = params.ExScorePercent,
							hardExScorePercent = params.HardExScorePercent,
							displayedPercent = params.DisplayedPercent,
							scoreMode = params.ScoreMode,
							combo = params.Combo,
						})
					end,
					OnlineSongReloadCompletedMessageCommand=function(self)
						online_flow_trace("song_reload_completed_message"
							.. " room=" .. tostring(ITGOnline and ITGOnline.currentRoomId or "nil")
							.. " phase=" .. tostring(ITGOnline and ITGOnline.currentRoom and ITGOnline.currentRoom.phase or "nil")
							.. " screen=" .. tostring(screen_name(current_top_screen()))
							.. " lastOptionsSongKey=" .. tostring(lastOnlineOptionsSongKey or ""))
						local phase = ITGOnline and ITGOnline.NormalizeRoomPhase and ITGOnline:NormalizeRoomPhase(ITGOnline.currentRoom and ITGOnline.currentRoom.phase) or tostring(ITGOnline and ITGOnline.currentRoom and ITGOnline.currentRoom.phase or "")
						if phase == "config" then
							online_flow_trace("song_reload_completed_keep_options_key reason=config_phase"
								.. " key=" .. tostring(lastOnlineOptionsSongKey or ""))
						else
							lastOnlineOptionsSongKey = ""
						end
					end,
					ReleaseOnlineGameplayAtStartCommand=function(self)
						self.onlineStartReleaseQueued = false
						if onlineHandlerShuttingDown or not (ITGOnline and ITGOnline.currentRoom) then
							online_flow_trace("release_online_gameplay_skipped reason=missing_context"
								.. " shuttingDown=" .. tostring(onlineHandlerShuttingDown == true)
								.. " hasRoom=" .. tostring(ITGOnline and ITGOnline.currentRoom ~= nil))
							return
						end

						if not current_room_is_active({ phase = { "starting", "playing" } }) then
							online_flow_trace("release_online_gameplay_skipped reason=inactive_room")
							return
						end

						local screen = current_top_screen()
						local screenName = screen_name(screen)
						if screenName ~= "ScreenGameplay" and screenName ~= "ScreenGameplayShared" then
							online_flow_trace("release_online_gameplay_skipped reason=not_gameplay screen=" .. tostring(screenName))
							return
						end

							if ITGOnline.currentRoom.phase == "playing" then
								local seconds = ITGOnline.SecondsUntilScheduledStart and ITGOnline:SecondsUntilScheduledStart() or nil
								online_flow_trace("release_online_gameplay_now reason=already_playing seconds=" .. tostring(seconds or "nil"))
								ReleaseOnlineGameplay(screen, seconds)
								return
							end

						if ITGOnline.currentRoom.phase ~= "starting" then
							online_flow_trace("release_online_gameplay_skipped reason=phase_not_starting phase=" .. tostring(ITGOnline.currentRoom.phase or "nil"))
							return
						end

							local seconds = ITGOnline.SecondsUntilScheduledStart and ITGOnline:SecondsUntilScheduledStart() or nil
							if seconds ~= nil and seconds <= 0.03 then
								online_flow_trace("release_online_gameplay_now reason=start_time_reached seconds=" .. tostring(seconds))
								ReleaseOnlineGameplay(screen, seconds)
								return
							end

							self.onlineStartReleaseQueued = true
							online_flow_trace("release_online_gameplay_rescheduled seconds=" .. tostring(seconds or "nil"))
							schedule_named_timer(self, "OnlineGameplayStartTimer", seconds and math.min(math.max(seconds, 0.05), 0.25) or 0.25, "Fire")
						end,
	      ScreenChangedMessageCommand=function(self)
					local screen = current_top_screen()
					local screenName = screen_name(screen)
					local wsConnected = self.connected and self.socket ~= nil
					online_flow_trace("screen_changed_message top=" .. tostring(screenName)
						.. " currentScreenName=" .. tostring(ITGOnline and ITGOnline.currentScreenName or "nil")
						.. " inLobby=" .. tostring(screenName == "ScreenOnlineLobbies")
						.. " connected=" .. tostring(self.connected == true)
						.. " wsConnected=" .. tostring(wsConnected == true)
						.. " isWaiting=" .. tostring(isWaiting == true)
						.. " room=" .. tostring(ITGOnline and ITGOnline.currentRoomId or "nil")
						.. " phase=" .. tostring(ITGOnline and ITGOnline.currentRoom and ITGOnline.currentRoom.phase or "nil")
						.. " pendingOnlineStartRoomId=" .. tostring(pendingOnlineStartRoomId or "nil")
						.. " pendingConfigReady=" .. tostring(pendingConfigReady ~= nil))
					remove_online_input_callbacks()
					if screenName ~= "ScreenEvaluationStage"
						and screenName ~= "ScreenEvaluationNonstop"
						and screenName ~= "ScreenEvaluationSummary" then
						evaluationExitTransitionRequestedAt = 0
						evaluationExitTransitionRoomId = ""
						if ITGOnline then
							ITGOnline.onlineEvaluationExitRequested = false
							ITGOnline.onlineEvaluationExitRequestedAt = nil
						end
					end

					if ITGOnline and ITGOnline.NoteScreenChanged then
						ITGOnline:NoteScreenChanged(screenName)
						if ITGOnline.ConsumeNeedsSyncAfterScreenCancel and ITGOnline:ConsumeNeedsSyncAfterScreenCancel() and ITGOnline.Sync then
							ITGOnline:Sync()
						end
						if screenName == "ScreenOnlineLobbies"
							and ITGOnline.postRoomExitLobbyRefreshPending == true
							and ITGOnline.currentRoomId == nil
							and ITGOnline.QueuePostRoomExitLobbyRefresh then
							online_flow_trace("screen_changed_post_room_exit_refresh"
								.. " reason=" .. tostring(ITGOnline.postRoomExitLobbyRefreshReason or "unknown")
								.. " inFlight=" .. tostring(ITGOnline.lobbyRefreshInFlight == true)
								.. " queued=" .. tostring(ITGOnline.lobbyRefreshQueued == true))
							ITGOnline:QueuePostRoomExitLobbyRefresh(
								ITGOnline.postRoomExitLobbyRefreshReason or "screen_changed_to_lobby",
								0.12)
						end
					end
					startHoldTime = { ["P1"] = 0, ["P2"] = 0 }
					lastDisconnectCountdown = nil

					if not self.inLobby then
						return
					end

					if knownDisconnectScreens[screenName] then
						safe_broadcast("DisconnectOnline", {leaveRoom=true})
						return
					end

					if screenName == "ScreenSelectMusic" then
						UnlockOnlineInput()
						replace_online_input_callback(screen, "select_music", SelectMusicInputHandler)
					end
					if screenName == "ScreenOnlineLobbies" then
						isWaiting = false
						UnlockOnlineInput()
						if pendingConfigReady and ITGOnline and ITGOnline.RememberPendingConfigReadyIntent then
							local intentRemembered = ITGOnline:RememberPendingConfigReadyIntent("options_export_completed") == true
							online_flow_trace("options_confirmed lobby_resume persistent_intent=" .. tostring(intentRemembered)
								.. " key=" .. tostring(pendingConfigReady))
							if intentRemembered then
								-- ScreenPlayerOptions has finished SaveSelections at this point, so
								-- GAMESTATE now contains the chart that may safely be sent.
								schedule_named_timer(self, "ConfigReadyRetryTimer", 0.05, "Fire")
							end
						end
						if not room_runtime_should_run() then
							stop_room_timers(self, "screen_online_lobbies_no_fast_runtime")
						end
						if online_trace then
							online_trace("FLOW lobby_screen_unlocked screen=" .. tostring(screenName)
								.. " room=" .. tostring(ITGOnline and ITGOnline.currentRoomId or "nil")
								.. " phase=" .. tostring(ITGOnline and ITGOnline.currentRoom and ITGOnline.currentRoom.phase or "nil"))
						end
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
						isWaiting = false
						UnlockOnlineInput()
						local summary = ITGOnline and ITGOnline.PlayStateSummary and ITGOnline:PlayStateSummary(ITGOnline.currentRoom) or nil
						local cache = ITGOnline and ITGOnline.GetFinalLeaderboardCache and ITGOnline:GetFinalLeaderboardCache(ITGOnline.currentRoomId) or nil
						if online_trace then
							online_trace("FLOW evaluation_screen_unlocked screen=" .. tostring(screenName)
								.. " room=" .. tostring(ITGOnline and ITGOnline.currentRoomId or "nil")
								.. " phase=" .. tostring(ITGOnline and ITGOnline.currentRoom and ITGOnline.currentRoom.phase or "nil")
								.. " players=" .. tostring(summary and summary.players or "nil")
								.. " terminal=" .. tostring(summary and summary.terminal or "nil")
								.. " finalResults=" .. tostring(summary and summary.finalResults or "nil")
								.. " finalResultsReady=" .. tostring(summary and summary.finalResultsReady == true)
								.. " cacheRows=" .. tostring(cache and cache.rows and #cache.rows or 0)
								.. " cacheSource=" .. tostring(cache and cache.source or "nil"))
						end
						replace_online_input_callback(screen, "evaluation", EvaluationInputHandler)
					end

					if syncLockScreens[screenName] then
						isWaiting = true
						if SCREENMAN and SCREENMAN.set_input_redirected then
							for player in ivalues(PlayerNumber) do
								SCREENMAN:set_input_redirected(player, true)
							end
						end
					end

					if autoReadyScreens[screenName] and not (evaluationScreens[screenName] and ITGOnline and ITGOnline.currentRoom and ITGOnline.currentRoom.phase == "playing") then
						if GAMESTATE then
							for player in ivalues(GAMESTATE:GetEnabledPlayers()) do
								local pn = ToEnumShortString(player)
								readyState[pn] = true
							end
						end
					end

					if screenName == "ScreenGameplay" or screenName == "ScreenGameplayShared" then
						if GAMESTATE then
							for player in ivalues(GAMESTATE:GetEnabledPlayers()) do
								local pn = ToEnumShortString(player)
								readyState[pn] = false
							end
						end
							replace_online_input_callback(screen, "gameplay_wait", InputHandler)
							if ITGOnline and ITGOnline.currentRoom and ITGOnline.currentRoom.phase == "playing" then
								UnlockOnlineInput()
								SetGameplayPaused(screen, false)
							elseif ITGOnline and ITGOnline.currentRoom and ITGOnline.currentRoom.phase == "starting" then
								SetGameplayPaused(screen, true)
								if ITGOnline.MarkSongLoaded then
									local songLoadedContext = room_context_token("mark_song_loaded")
									ITGOnline:MarkSongLoaded(function(ok, decoded, response)
										if not room_context_still_active(songLoadedContext, { phase = "starting" }) then
											online_flow_trace("mark_song_loaded_callback_ignored reason=stale_context")
											return
										end
										if not ok then
											UnlockOnlineInput()
											if current_top_screen() == screen then
												SetGameplayPaused(screen, false)
												transition_screen(screen, "ScreenOnlineLobbies", "SM_GoToNextScreen", "song_loaded_failed")
											end
										safe_broadcast("OnlineResponseStatus", {
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
						online_flow_trace("heartbeat_screen_update status=" .. tostring(status)
							.. " screen=" .. tostring(screenName)
							.. " room=" .. tostring(ITGOnline.currentRoomId or "nil")
							.. " phase=" .. tostring(ITGOnline.currentRoom and ITGOnline.currentRoom.phase or "nil")
							.. " wsConnected=" .. tostring(wsConnected == true))
						ITGOnline:Heartbeat(status)
					elseif wsConnected
						and ITGOnline
						and ITGOnline.ForceLobbyPresenceHeartbeat
						and screenName == "ScreenOnlineLobbies" then
						online_flow_trace("heartbeat_screen_update status=available"
							.. " screen=" .. tostring(screenName)
							.. " room=nil"
							.. " wsConnected=" .. tostring(wsConnected == true))
						ITGOnline:ForceLobbyPresenceHeartbeat("screen_online_lobbies_no_room")
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
							schedule_named_timer(self, "PreviewInitialSongTimer", 0.25, "Fire")
						end
						if not replayDeferredLobbyStateQueued then
							replayDeferredLobbyStateQueued = true
							schedule_named_timer(self, "ReplayDeferredLobbyStateTimer", 0.05, "Fire")
						end
					safe_broadcast("UpdateMachineState")
		      end,
					ReplayDeferredLobbyStateCommand=function(self)
						replayDeferredLobbyStateQueued = false
						if replayDeferredLobbyStateRunning then return end
						if not (self.inLobby and self.lastLobbyStatePayload) then return end
						local screen = current_top_screen()
						local screenName = screen_name(screen)
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
						local screen = current_top_screen()
						if screen and screen:GetName() ~= "ScreenSelectMusic" then
							online_flow_trace("preview_initial_online_song_skipped reason=not_select_music screen="
								.. tostring(screen_name(screen)))
							return
						end
						online_flow_trace("preview_initial_online_song_fire"
							.. " room=" .. tostring(ITGOnline and ITGOnline.currentRoomId or "nil")
							.. " phase=" .. tostring(ITGOnline and ITGOnline.currentRoom and ITGOnline.currentRoom.phase or "nil"))
						maybe_preview_current_online_song(true)
					end,
	      PlayerJoinedMessageCommand=function(self)
					if self.connected and self.socket ~= nil and self.inLobby and ITGOnline and ITGOnline.Heartbeat then
	          online_flow_trace("heartbeat_forced source=PlayerJoined room=" .. tostring(ITGOnline and ITGOnline.currentRoomId or "nil"))
	          ITGOnline:Heartbeat("in_room", true)
	        end
	      end,
	      PlayerUnjoinedMessageCommand=function(self)
					if self.connected and self.socket ~= nil and self.inLobby and ITGOnline and ITGOnline.Heartbeat then
	          online_flow_trace("heartbeat_forced source=PlayerUnjoined room=" .. tostring(ITGOnline and ITGOnline.currentRoomId or "nil"))
	          ITGOnline:Heartbeat("in_room", true)
	        end
	      end,
			UpdateMachineStateMessageCommand=function(self)
					if self.connected and self.socket ~= nil and self.inLobby and ITGOnline and ITGOnline.Heartbeat then
	          online_flow_trace("heartbeat_forced source=UpdateMachineState room=" .. tostring(ITGOnline and ITGOnline.currentRoomId or "nil"))
	          ITGOnline:Heartbeat("in_room", true)
	        end
	      end,
			      OnlineConfigReadyMessageCommand=function(self)
							if not (self.connected and self.socket ~= nil and current_room_is_active({ phase = { "config", "lobby_ready", "lobby" } })) then
								online_flow_trace("options_confirmed ignored reason=missing_context"
									.. " connected=" .. tostring(self.connected == true)
									.. " hasSocket=" .. tostring(self.socket ~= nil)
									.. " room=" .. tostring(ITGOnline and ITGOnline.currentRoomId or "nil"))
								return
							end

						self.inLobby = true
						local configReadyKey = ITGOnline.PlayStateKey and ITGOnline:PlayStateKey()
							or (tostring(ITGOnline.currentRoomId) .. "|" .. tostring(ITGOnline.currentSongPayload and ITGOnline.currentSongPayload.chart_hash or ""))
						pendingConfigReady = configReadyKey
						self.configReadyRetryKey = configReadyKey
						self.configReadyRoomToken = room_context_token("config_ready")
						self.configReadyRetryCount = 0
						self.configReadyRetryStartedAt = GetTimeSinceStart and GetTimeSinceStart() or 0
						if ITGOnline.SetOptimisticConfigReady then
							ITGOnline:SetOptimisticConfigReady("options_confirmed")
						end
						if ITGOnline.MarkConfigReady then
							online_flow_trace("options_confirmed queue config_ready key=" .. tostring(configReadyKey))
						else
							online_flow_trace("options_confirmed queue legacy_config_ready key=" .. tostring(configReadyKey))
						end
						if online_flow_trace then
							online_flow_trace("options_confirmed dispatch_deferred config_ready key=" .. tostring(configReadyKey)
								.. " delay=0.20")
						end
						-- Let ScreenPlayerOptions finish SaveSelections first. The Stepchart
						-- option updates GAMESTATE:SetCurrentSteps() during that save pass; if
						-- we send config_ready synchronously here, the payload can still contain
						-- the previous song's chart. The explicit remembered-step cache in
						-- ITGOnline covers the immediate case; this delay is a second guard for
						-- engine-side GAMESTATE propagation.
						schedule_named_timer(self, "ConfigReadyRetryTimer", 0.20, "Fire")
		      end,
			      OnlineConfigReadyConfirmedMessageCommand=function(self, params)
							if not pendingConfigReady then
								online_flow_trace("options_confirmed realtime_ignored reason=no_pending"
									.. " key=" .. tostring(params and params.key or "nil"))
								return
							end
							if not (params and params.authoritative == true) then
								online_flow_trace("options_confirmed realtime_ignored reason=not_authoritative"
									.. " pending=" .. tostring(pendingConfigReady)
									.. " key=" .. tostring(params and params.key or "nil")
									.. " source=" .. tostring(params and params.source or "nil"))
								return
							end

							local expectedConfigReadyKey = ITGOnline.PlayStateKey and ITGOnline:PlayStateKey()
								or (tostring(ITGOnline.currentRoomId) .. "|" .. tostring(ITGOnline.currentSongPayload and ITGOnline.currentSongPayload.chart_hash or ""))
							local confirmedKey = params and params.key or expectedConfigReadyKey
							online_flow_trace("options_confirmed authoritative_confirm_received pending=" .. tostring(pendingConfigReady)
								.. " confirmed=" .. tostring(confirmedKey)
								.. " expected=" .. tostring(expectedConfigReadyKey))
							if pendingConfigReady == confirmedKey or pendingConfigReady == expectedConfigReadyKey then
								online_flow_trace("options_confirmed server_confirmed config_ready key=" .. tostring(confirmedKey))
								pendingConfigReady = nil
								self.configReadyRetryKey = nil
								self.configReadyRetryCount = 0
								self.configReadyRetryStartedAt = 0
								if ITGOnline.ClearOptimisticConfigReady then
									ITGOnline:ClearOptimisticConfigReady("config_ready_confirmed")
								end
							else
								online_flow_trace("options_confirmed realtime_ignored reason=key_mismatch pending="
									.. tostring(pendingConfigReady)
									.. " confirmed=" .. tostring(confirmedKey)
									.. " expected=" .. tostring(expectedConfigReadyKey))
							end
						end,
			      RetryOnlineConfigReadyCommand=function(self)
							local configReadyToken = self.configReadyRoomToken or room_context_token("config_ready_retry")
							if not pendingConfigReady
								or not room_context_still_active(configReadyToken, { phase = { "config", "lobby", "lobby_ready" } }) then
								online_flow_trace("options_confirmed retry_ignored reason=missing_pending_or_room"
									.. " pending=" .. tostring(pendingConfigReady or "nil")
									.. " room=" .. tostring(ITGOnline and ITGOnline.currentRoomId or "nil"))
								return
							end
								local expectedConfigReadyKey = ITGOnline.PlayStateKey and ITGOnline:PlayStateKey()
									or (tostring(ITGOnline.currentRoomId) .. "|" .. tostring(ITGOnline.currentSongPayload and ITGOnline.currentSongPayload.chart_hash or ""))
							if pendingConfigReady ~= expectedConfigReadyKey then
								online_flow_trace("options_confirmed retry_ignored reason=key_mismatch pending="
									.. tostring(pendingConfigReady)
									.. " expected=" .. tostring(expectedConfigReadyKey)
									.. " room=" .. tostring(ITGOnline.currentRoomId or "nil"))
								return
							end

							if self.configReadyRetryKey ~= expectedConfigReadyKey then
								self.configReadyRetryKey = expectedConfigReadyKey
								self.configReadyRetryCount = 0
								self.configReadyRetryStartedAt = GetTimeSinceStart and GetTimeSinceStart() or 0
							end
							self.configReadyRetryCount = (tonumber(self.configReadyRetryCount) or 0) + 1
							local retryStartedAt = tonumber(self.configReadyRetryStartedAt) or (GetTimeSinceStart and GetTimeSinceStart() or 0)
							local retryAge = (GetTimeSinceStart and GetTimeSinceStart() or retryStartedAt) - retryStartedAt
							if self.configReadyRetryCount > 8 or retryAge > 12 then
								online_flow_trace("options_confirmed retry_aborted reason=retry_budget_exhausted key="
									.. tostring(expectedConfigReadyKey)
									.. " attempts=" .. tostring(self.configReadyRetryCount)
									.. " age=" .. string.format("%.3f", retryAge))
								if pendingConfigReady == expectedConfigReadyKey then pendingConfigReady = nil end
								self.configReadyRetryKey = nil
								self.configReadyRoomToken = nil
								self.configReadyRetryCount = 0
								self.configReadyRetryStartedAt = 0
								if ITGOnline.ClearOptimisticConfigReady then
									ITGOnline:ClearOptimisticConfigReady("config_ready_retry_budget_exhausted")
								end
								safe_broadcast("OnlineResponseStatus", {
									event="ready",
									success=false,
									message="Echec de synchronisation de l'etat pret."
								})
								return
							end

							if ITGOnline.MarkConfigReady then
								online_flow_trace("options_confirmed mark_config_ready_begin key=" .. tostring(expectedConfigReadyKey)
									.. " room=" .. tostring(ITGOnline.currentRoomId or "nil")
									.. " rememberedStepSource=" .. tostring(ITGOnline.pendingOnlineOptionStepsSource or "nil")
									.. " rememberedStepAge=" .. tostring((GetTimeSinceStart and GetTimeSinceStart() or 0) - (tonumber(ITGOnline.pendingOnlineOptionStepsAt) or 0)))
								ITGOnline:MarkConfigReady(function(ok, decoded, response)
									if not room_context_still_active(configReadyToken, { phase = { "config", "lobby", "lobby_ready" } }) then
										online_flow_trace("options_confirmed mark_config_ready_ignored reason=stale_context key=" .. tostring(expectedConfigReadyKey))
										return
									end
									online_flow_trace("options_confirmed mark_config_ready_response key=" .. tostring(expectedConfigReadyKey)
										.. " ok=" .. tostring(ok == true)
										.. " status=" .. tostring(response and response.statusCode or "nil")
										.. " retryAfter=" .. tostring(response and response.retryAfter or "nil")
										.. " error=" .. tostring(decoded and decoded.error_code or response and response.error or "nil")
										.. " serverRoomPhase=" .. tostring(decoded and decoded.room and decoded.room.phase or "nil")
										.. " serverReadyStates=" .. tostring(decoded and decoded.room and decoded.room.ready_states and #decoded.room.ready_states or "nil"))
									if ok then
										if pendingConfigReady == expectedConfigReadyKey then pendingConfigReady = nil end
										self.configReadyRetryKey = nil
										self.configReadyRoomToken = nil
										self.configReadyRetryCount = 0
										self.configReadyRetryStartedAt = 0
										return
										end

										if response and response.retryAfter then
											local retryAfter = tonumber(response.retryAfter) or 0.5
											retryAfter = math.max(0.1, math.min(retryAfter, 2.0))
											online_flow_trace("options_confirmed mark_config_ready_retry_scheduled key="
												.. tostring(expectedConfigReadyKey)
												.. " retryAfter=" .. tostring(retryAfter)
												.. " attempts=" .. tostring(self.configReadyRetryCount))
											schedule_named_timer(self, "ConfigReadyRetryTimer", retryAfter, "Fire")
											return
										end

								if pendingConfigReady == expectedConfigReadyKey then pendingConfigReady = nil end
								self.configReadyRetryKey = nil
								self.configReadyRoomToken = nil
								self.configReadyRetryCount = 0
								self.configReadyRetryStartedAt = 0
								if ITGOnline.ClearOptimisticConfigReady then
									ITGOnline:ClearOptimisticConfigReady("config_ready_failed")
								end
								safe_broadcast("OnlineResponseStatus", {
								event="ready",
								success=false,
								message=(decoded and decoded.message) or (response and response.errorMessage) or "Echec de synchronisation de l'etat pret."
							})
						end)
						return
					end

							local fetchRoomId = ITGOnline.currentRoomId
							ITGOnline:FetchRoom(fetchRoomId, function(ok, decoded)
									if not room_context_still_active(configReadyToken, { phase = { "config", "lobby", "lobby_ready" } }) then
										online_flow_trace("options_confirmed legacy_fetch_room_ignored reason=stale_context key=" .. tostring(expectedConfigReadyKey))
										return
									end
									if not ok or not decoded or not decoded.room then
										online_flow_trace("options_confirmed legacy_fetch_room_retry key=" .. tostring(expectedConfigReadyKey)
											.. " ok=" .. tostring(ok == true)
											.. " hasDecoded=" .. tostring(decoded ~= nil)
											.. " hasRoom=" .. tostring(decoded and decoded.room ~= nil)
											.. " attempts=" .. tostring(self.configReadyRetryCount))
										schedule_named_timer(self, "ConfigReadyRetryTimer", 1, "Fire")
										return
								end
								if not online_room_ids_match(decoded.room.id or decoded.room.room_id or decoded.room.roomId, fetchRoomId) then
									online_flow_trace("options_confirmed legacy_fetch_room_ignored reason=room_mismatch key=" .. tostring(expectedConfigReadyKey))
									return
								end

							local phase = decoded.room.phase
							online_flow_trace("options_confirmed legacy_fetch_room_ok key=" .. tostring(expectedConfigReadyKey)
								.. " room=" .. tostring(ITGOnline.currentRoomId or "nil")
								.. " phase=" .. tostring(phase)
								.. " hasSelectedSong=" .. tostring(decoded.room.selected_song ~= nil))
								if not decoded.room.selected_song then
									online_flow_trace("options_confirmed legacy_select_song_begin key=" .. tostring(expectedConfigReadyKey)
										.. " room=" .. tostring(ITGOnline.currentRoomId or "nil"))
									ITGOnline:SelectSong(function(selectOk, selectDecoded, selectResponse)
											if not room_context_still_active(configReadyToken, { phase = { "config", "lobby", "lobby_ready" } }) then
												online_flow_trace("options_confirmed legacy_select_song_ignored reason=stale_context key=" .. tostring(expectedConfigReadyKey))
												return
											end
											if selectOk then
												online_flow_trace("options_confirmed legacy_select_song_ok key=" .. tostring(expectedConfigReadyKey))
												schedule_named_timer(self, "ConfigReadyRetryTimer", 0.25, "Fire")
											else
											online_flow_trace("options_confirmed legacy_select_song_failed key=" .. tostring(expectedConfigReadyKey)
												.. " status=" .. tostring(selectResponse and selectResponse.statusCode or "nil")
												.. " error=" .. tostring(selectDecoded and selectDecoded.error_code or selectResponse and selectResponse.error or "nil"))
											if pendingConfigReady == expectedConfigReadyKey then pendingConfigReady = nil end
											if ITGOnline.ClearOptimisticConfigReady then
												ITGOnline:ClearOptimisticConfigReady("config_ready_select_song_failed")
										end
									safe_broadcast("OnlineResponseStatus", {
										event="selectSong",
										success=false,
											message=(selectDecoded and selectDecoded.message) or (selectResponse and selectResponse.errorMessage) or "Echec de selection de la chanson."
									})
								end
							end)
							return
						end

								if phase == "starting" or phase == "playing" or phase == "results" then
									online_flow_trace("options_confirmed legacy_stop reason=phase_" .. tostring(phase)
										.. " key=" .. tostring(expectedConfigReadyKey))
									if pendingConfigReady == expectedConfigReadyKey then pendingConfigReady = nil end
									if ITGOnline.ClearOptimisticConfigReady then
										ITGOnline:ClearOptimisticConfigReady("config_ready_phase_" .. tostring(phase))
									end
								elseif phase == "config" then
									online_flow_trace("options_confirmed legacy_set_config_ready key=" .. tostring(expectedConfigReadyKey)
										.. " room=" .. tostring(ITGOnline.currentRoomId or "nil"))
									ITGOnline:SetReady("config_ready", true, function()
										if pendingConfigReady == expectedConfigReadyKey then pendingConfigReady = nil end
									ITGOnline:FetchRoom(ITGOnline.currentRoomId, function(fetchOk, fetchDecoded)
									if fetchOk and fetchDecoded and fetchDecoded.room then
									safe_broadcast("OnlineLobbyState", build_lobby_payload(fetchDecoded.room))
									end
								end)
							end)
								elseif phase == "lobby" or phase == "lobby_ready" then
									online_flow_trace("options_confirmed legacy_set_lobby_ready_before_retry key=" .. tostring(expectedConfigReadyKey)
										.. " phase=" .. tostring(phase))
									maybe_set_lobby_ready("options_confirmed_legacy_retry", function()
										schedule_named_timer(self, "ConfigReadyRetryTimer", 0.5, "Fire")
									end)
							else
								online_flow_trace("options_confirmed legacy_stop reason=unexpected_phase key="
									.. tostring(expectedConfigReadyKey)
									.. " phase=" .. tostring(phase))
								if pendingConfigReady == expectedConfigReadyKey then pendingConfigReady = nil end
							end
					end)
	      end,
					OnlineSessionExpiredMessageCommand=function(self)
						self.connected = false
						self.inLobby = false
						self.lastLobbyStateSignature = ""
						clear_room_async_state(self)
						clear_room_input_state("session_expired")
						self.socket = nil
						safe_broadcast("OnlineResponseStatus", {
							event="sessionExpired",
							success=false,
							message="Online session expired. Please reconnect."
						})
					end,
					OnlineLobbyStateMessageCommand=function(self, params)
						if online_trace then
							online_trace(
								"FLOW OnlineLobbyStateMessage begin connected=" .. tostring(self.connected) ..
								" roomId=" .. tostring(params and params.roomId) ..
								" phase=" .. tostring(params and (params.phase or params.status or params.readyPhase)))
						end
							if self.connected and params and params.roomId and OnlinePayloadMatchesActiveRoom(params) then
							local playerParts = {}
								for index, rawPlayer in ipairs(params.players or {}) do
									local player = type(rawPlayer) == "table" and rawPlayer or {}
								local user = type(player.user) == "table" and player.user or {}
								playerParts[#playerParts + 1] = table.concat({
									tostring(index),
									tostring(player.id or player.user_id or user.id or ""),
									tostring(player.status or player.play_state or player.state or ""),
									tostring(player.ready_state or player.readyState or ""),
									tostring(player.is_ready or player.ready or ""),
									tostring(player.song_available or player.songAvailable or ""),
									tostring(player.pack_sync_status or player.packSyncStatus or ""),
									tostring(player.pack_sync_sequence or player.packSyncSequence or ""),
									tostring(player.download_progress or player.downloadProgress or ""),
								}, ":")
							end
							table.sort(playerParts)
							local songInfo = type(params.songInfo) == "table" and params.songInfo or {}
							local playState = type(params.playState) == "table" and params.playState or {}
							local manager = type(params.manager) == "table" and params.manager or {}
							local stateSignature = table.concat({
								tostring(params.roomId or ""),
								tostring(params.code or ""),
								tostring(params.phase or params.status or params.readyPhase or ""),
								tostring(params.isManager or ""),
								tostring(manager.id or ""),
								tostring(songInfo.selectedAt or songInfo.selected_at or ""),
								tostring(songInfo.song_hash or songInfo.songHash or ""),
								tostring(songInfo.chart_hash or songInfo.chartHash or ""),
								tostring(playState.submitted_scores and #playState.submitted_scores or ""),
								tostring(playState.final_results and #playState.final_results or ""),
								table.concat(playerParts, "|"),
							}, "||")
							if ITGOnline and ITGOnline.StoreFinalLeaderboardFromRoom then
								ITGOnline:StoreFinalLeaderboardFromRoom(params, "online_lobby_state_message")
							elseif params and (params.phase or params.status or params.readyPhase) == "results" then
								online_flow_trace("final_leaderboard_cache unavailable source=online_lobby_state_message room="
									.. tostring(params.roomId or params.code or "nil")
									.. " finalResults=" .. tostring(params.finalResults and #params.finalResults or 0))
							end
							if ITGOnline and ITGOnline.ForceGameplayEvaluationIfResultsReady then
								ITGOnline:ForceGameplayEvaluationIfResultsReady("online_lobby_state_message_before_duplicate_guard")
							end
							if stateSignature ~= "" and stateSignature == tostring(self.lastLobbyStateSignature or "") then
								online_flow_trace("online_lobby_state_apply_skipped reason=duplicate_signature"
									.. " roomId=" .. tostring(params.roomId or "nil")
									.. " phase=" .. tostring(params.phase or params.status or params.readyPhase or "nil")
									.. " players=" .. tostring(params.players and #params.players or 0)
									.. " source=" .. tostring(params.snapshotSource or "nil"))
								return
							end
							online_flow_trace("online_lobby_state_apply_begin"
								.. " roomId=" .. tostring(params.roomId or "nil")
								.. " code=" .. tostring(params.code or "nil")
								.. " phase=" .. tostring(params.phase or params.status or params.readyPhase or "nil")
								.. " players=" .. tostring(params.players and #params.players or 0)
								.. " inLobbyBefore=" .. tostring(self.inLobby == true)
								.. " currentRoomId=" .. tostring(ITGOnline and ITGOnline.currentRoomId or "nil")
								.. " screen=" .. tostring(SCREENMAN and SCREENMAN:GetTopScreen() and SCREENMAN:GetTopScreen():GetName() or "nil"))
							self.inLobby = true
							start_room_timers(self, "online_lobby_state_apply")
							if ITGOnline and ITGOnline.Heartbeat then
								ITGOnline:Heartbeat("in_room")
							end
							params.__receivedLocalTime = GetTimeSinceStart()
							self.lastLobbyStatePayload = params
							self.lastLobbyStateSignature = stateSignature
							if online_trace then
								local screenName = SCREENMAN and SCREENMAN:GetTopScreen() and SCREENMAN:GetTopScreen():GetName() or "nil"
								local flowContext = screenName == "ScreenOnlineLobbies" and "display_lobby" or "apply_room_state"
								online_trace("FLOW OnlineLobbyStateMessage " .. flowContext .. "_begin roomId=" .. tostring(params.roomId)
									.. " screen=" .. tostring(screenName))
							end
							DisplayLobbyState(params, self)
							if ITGOnline and ITGOnline.ForceGameplayEvaluationIfResultsReady then
								ITGOnline:ForceGameplayEvaluationIfResultsReady("online_lobby_state_message_after_display")
							end
							if ITGOnline and ITGOnline.EnforceCurrentRoomScreenAfterStateUpdate then
								ITGOnline:EnforceCurrentRoomScreenAfterStateUpdate("online_lobby_state_message")
							end
							if online_trace then
								local screenName = SCREENMAN and SCREENMAN:GetTopScreen() and SCREENMAN:GetTopScreen():GetName() or "nil"
								local flowContext = screenName == "ScreenOnlineLobbies" and "display_lobby" or "apply_room_state"
								online_trace("FLOW OnlineLobbyStateMessage " .. flowContext .. "_end roomId=" .. tostring(params.roomId)
									.. " screen=" .. tostring(screenName))
							end
							online_flow_trace("online_lobby_state_apply_end"
								.. " roomId=" .. tostring(params.roomId or "nil")
								.. " phase=" .. tostring(params.phase or params.status or params.readyPhase or "nil")
								.. " inLobbyAfter=" .. tostring(self.inLobby == true)
								.. " lastPayloadRoomId=" .. tostring(self.lastLobbyStatePayload and self.lastLobbyStatePayload.roomId or "nil"))
							elseif online_trace then
								online_trace("FLOW OnlineLobbyStateMessage ignored")
							online_flow_trace("online_lobby_state_ignored"
								.. " connected=" .. tostring(self.connected == true)
								.. " hasParams=" .. tostring(params ~= nil)
								.. " roomId=" .. tostring(params and params.roomId or "nil")
								.. " inLobby=" .. tostring(self.inLobby == true))
						end
					end,
					OnlineLobbyLeftMessageCommand=function(self)
						self.lastLobbyStateSignature = ""
						if online_trace then
							online_trace(
								"FLOW OnlineLobbyLeftMessage handler_begin inLobby=" .. tostring(self.inLobby) ..
								" connected=" .. tostring(self.connected) ..
								" currentRoomId=" .. tostring(ITGOnline and ITGOnline.currentRoomId))
						end
						online_flow_trace("online_lobby_left_apply_begin"
							.. " inLobbyBefore=" .. tostring(self.inLobby == true)
							.. " connected=" .. tostring(self.connected == true)
							.. " lastPayloadRoomId=" .. tostring(self.lastLobbyStatePayload and self.lastLobbyStatePayload.roomId or "nil")
							.. " currentRoomId=" .. tostring(ITGOnline and ITGOnline.currentRoomId or "nil")
							.. " screen=" .. tostring(SCREENMAN and SCREENMAN:GetTopScreen() and SCREENMAN:GetTopScreen():GetName() or "nil"))
						self.inLobby = false
						clear_room_async_state(self)
						clear_room_input_state("lobby_left")
						if ITGOnline and ITGOnline.QueuePostRoomExitLobbyRefresh then
							ITGOnline:QueuePostRoomExitLobbyRefresh("online_lobby_left_message", 0.20)
						end
						if online_trace then
							online_trace("FLOW OnlineLobbyLeftMessage handler_end")
						end
						online_flow_trace("online_lobby_left_apply_end"
							.. " inLobbyAfter=" .. tostring(self.inLobby == true)
							.. " lastPayloadRoomId=" .. tostring(self.lastLobbyStatePayload and self.lastLobbyStatePayload.roomId or "nil"))
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
						schedule_named_timer(self, "ManagerAutoReadyRetryTimer", retryAfter, "Fire")
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
		        online_trace("FLOW JoinLobbyMessage received connected=" .. tostring(self.connected)
							.. " socket=" .. tostring(self.socket ~= nil)
							.. " busy=" .. tostring(self.joinLobbyBusy == true)
							.. " inLobby=" .. tostring(self.inLobby == true)
							.. " code=" .. tostring(params and params.code or "nil")
							.. " currentRoomId=" .. tostring(ITGOnline and ITGOnline.currentRoomId or "nil"))
		        if self.connected and self.socket ~= nil and ITGOnline and ITGOnline.RequestJoinRoom and params and params.code then
						if self.joinLobbyBusy then
							online_trace("FLOW JoinLobbyMessage skipped reason=busy code=" .. tostring(params and params.code or "nil"))
							return
						end
						self.joinLobbyBusy = true
						self.inLobby = false
						local joinToken = begin_actor_operation(self, "join_lobby")
		          ITGOnline:RequestJoinRoom(params.code, function(ok, decoded, response)
								if not actor_operation_is_current(self, "join_lobby", joinToken) then
									self.joinLobbyBusy = false
									online_flow_trace("join_lobby_callback_ignored reason=stale_operation busy_cleared=true")
									return
								end
								self.joinLobbyBusy = false
								online_trace("FLOW JoinLobbyMessage result ok=" .. tostring(ok == true)
									.. " status=" .. tostring(response and response.statusCode or "nil")
									.. " hasRoom=" .. tostring(decoded and decoded.room ~= nil)
									.. " error=" .. tostring(decoded and decoded.error_code or response and response.errorMessage or "nil")
									.. " currentRoomId=" .. tostring(ITGOnline and ITGOnline.currentRoomId or "nil"))
								if ok and decoded and decoded.room then
									self.inLobby = true
									DisplayLobbyState(build_lobby_payload(decoded.room), self)
									safe_broadcast("OnlineLobbyState", build_lobby_payload(decoded.room))
								elseif ok then
									safe_broadcast("OnlineResponseStatus", {
										event="joinLobby",
										success=true,
										message="Demande envoyee. En attente du manager du salon."
									})
								elseif decoded and (decoded.error_code == "already_in_room" or decoded.message == "You are already in this room.") and params and params.code then
								online_trace("FLOW JoinLobbyMessage restore_existing_room code=" .. tostring(params.code))
								ITGOnline:FetchRoom(params.code, function(fetchOk, fetchDecoded, fetchResponse)
									if not actor_operation_is_current(self, "join_lobby", joinToken) then
										online_flow_trace("join_lobby_restore_callback_ignored reason=stale_operation")
										return
									end
									online_trace("FLOW JoinLobbyMessage restore_result ok=" .. tostring(fetchOk == true)
										.. " status=" .. tostring(fetchResponse and fetchResponse.statusCode or "nil")
										.. " hasRoom=" .. tostring(fetchDecoded and fetchDecoded.room ~= nil)
										.. " phase=" .. tostring(fetchDecoded and fetchDecoded.room and fetchDecoded.room.phase or "nil"))
									if fetchOk and fetchDecoded and fetchDecoded.room then
										self.inLobby = true
										DisplayLobbyState(build_lobby_payload(fetchDecoded.room), self)
										safe_broadcast("OnlineLobbyState", build_lobby_payload(fetchDecoded.room))
									else
										safe_broadcast("OnlineResponseStatus", {
											event="joinLobby",
											success=false,
											message=(fetchDecoded and fetchDecoded.message) or (fetchResponse and fetchResponse.errorMessage) or "Impossible de restaurer l'etat du salon."
										})
									end
								end)
							else
								safe_broadcast("OnlineResponseStatus", {
									event="joinLobby",
									success=false,
									message=(decoded and decoded.message) or (response and response.errorMessage) or "Echec de connexion au salon."
								})
							end
						end)
	        else
						online_trace("FLOW JoinLobbyMessage skipped reason=not_connected_or_no_socket")
	        end
	      end,
		      CreateLobbyMessageCommand=function(self, params)
		        online_trace("FLOW CreateLobbyMessage received connected=" .. tostring(self.connected)
							.. " socket=" .. tostring(self.socket ~= nil)
							.. " busy=" .. tostring(self.createLobbyBusy == true)
							.. " inLobby=" .. tostring(self.inLobby == true)
							.. " visibility=" .. tostring(params and params.visibility or "public")
							.. " currentRoomId=" .. tostring(ITGOnline and ITGOnline.currentRoomId or "nil"))
		        if self.connected and self.socket ~= nil and ITGOnline and ITGOnline.CreateRoom then
						if self.createLobbyBusy then
							online_trace("FLOW CreateLobbyMessage skipped reason=busy")
							safe_broadcast("OnlineResponseStatus", {
								event="createLobby",
								success=false,
								message="Une creation de salon est deja en cours."
							})
							return
						end
						self.createLobbyBusy = true
						self.inLobby = false
						local createToken = begin_actor_operation(self, "create_lobby")
		          ITGOnline:CreateRoom(function(ok, decoded, response)
								if not actor_operation_is_current(self, "create_lobby", createToken) then
									self.createLobbyBusy = false
									online_flow_trace("create_lobby_callback_ignored reason=stale_operation busy_cleared=true")
									return
								end
								self.createLobbyBusy = false
								online_trace("FLOW CreateLobbyMessage result ok=" .. tostring(ok == true)
									.. " status=" .. tostring(response and response.statusCode or "nil")
									.. " hasRoom=" .. tostring(decoded and decoded.room ~= nil)
									.. " room=" .. tostring(decoded and decoded.room and decoded.room.id or "nil")
									.. " error=" .. tostring(decoded and decoded.error_code or response and response.errorMessage or "nil"))
								if ok and decoded and decoded.room then
								self.inLobby = true
								DisplayLobbyState(build_lobby_payload(decoded.room), self)
								safe_broadcast("OnlineLobbyState", build_lobby_payload(decoded.room))
								elseif decoded and (decoded.error_code == "already_in_open_room" or decoded.message == "User is already in an open room.") then
								online_trace("FLOW CreateLobbyMessage restore_current_room reason=already_in_open_room")
								RestoreCurrentRoom(self, function(restored)
									if not actor_operation_is_current(self, "create_lobby", createToken) then
										online_flow_trace("create_lobby_restore_callback_ignored reason=stale_operation")
										return
									end
									online_trace("FLOW CreateLobbyMessage restore_current_room_result restored=" .. tostring(restored == true))
									if not restored then
										safe_broadcast("OnlineResponseStatus", {
											event="createLobby",
											success=false,
									message="Echec de creation du salon : l'utilisateur est deja dans un salon ouvert."
										})
									end
								end)
							else
								safe_broadcast("OnlineResponseStatus", {
									event="createLobby",
									success=false,
								message=(decoded and decoded.message) or (response and response.errorMessage) or "Echec de creation du salon."
								})
							end
						end, params and params.visibility or "public")
	        else
						online_trace("FLOW CreateLobbyMessage skipped reason=not_connected_or_no_socket")
						safe_broadcast("OnlineResponseStatus", {
							event="createLobby",
							success=false,
							message="Le service en ligne n'est pas encore connecte. Reessayez dans un instant."
						})
	        end
	      end,
	      StartOnlineRoomMessageCommand=function(self)
					online_trace("FLOW StartOnlineRoomMessage received connected=" .. tostring(self.connected)
						.. " socket=" .. tostring(self.socket ~= nil)
						.. " inLobby=" .. tostring(self.inLobby == true)
						.. " busy=" .. tostring(self.startRoomBusy == true)
						.. " room=" .. tostring(ITGOnline and ITGOnline.currentRoomId or "nil")
						.. " phase=" .. tostring(ITGOnline and ITGOnline.currentRoom and ITGOnline.currentRoom.phase or "nil"))
					if self.connected and self.socket ~= nil and self.inLobby and ITGOnline and ITGOnline.StartRoom then
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
							safe_broadcast("OnlineResponseStatus", {
								event="startRoom",
								success=false,
								message="Le salon n'est pas encore pret a demarrer."
							})
							return
						end

						local attemptStart = function()
							self.startRoomBusy = true
							local startToken = begin_actor_operation(self, "start_room")
							if online_trace then
								online_trace("FLOW start_room request room=" .. tostring(ITGOnline.currentRoomId or "nil")
									.. " phase=" .. tostring(ITGOnline.currentRoom and ITGOnline.currentRoom.phase or "nil"))
							end
							ITGOnline:StartRoom(function(ok, decoded, response)
								if not actor_operation_is_current(self, "start_room", startToken) then
									self.startRoomBusy = false
									online_flow_trace("start_room_callback_ignored reason=stale_operation busy_cleared=true")
									return
								end
								self.startRoomBusy = false
								if ok and decoded and decoded.room then
									if online_trace then
										online_trace("FLOW start_room ok room=" .. tostring(decoded.room.id or ITGOnline.currentRoomId or "nil")
											.. " phase=" .. tostring(decoded.room.phase or "nil"))
									end
									local payload = build_lobby_payload(decoded.room)
									DisplayLobbyState(payload, self)
									safe_broadcast("OnlineLobbyState", payload)
								else
									if online_trace then
										online_trace("FLOW start_room failed room=" .. tostring(ITGOnline.currentRoomId or "nil")
											.. " phase=" .. tostring(ITGOnline.currentRoom and ITGOnline.currentRoom.phase or "nil")
											.. " error=" .. tostring((decoded and decoded.error_code) or (response and response.errorMessage) or "unknown"))
									end
									safe_broadcast("OnlineResponseStatus", {
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
							safe_broadcast("OnlineResponseStatus", {
								event="startRoom",
								success=false,
								message="Le salon n'est pas encore pret a demarrer."
						})
					else
						online_trace("FLOW StartOnlineRoomMessage skipped reason=not_ready connected=" .. tostring(self.connected)
							.. " socket=" .. tostring(self.socket ~= nil)
							.. " inLobby=" .. tostring(self.inLobby == true))
        end
      end,
	      InviteOnlinePlayerMessageCommand=function(self, params)
	        online_flow_trace("invite_online_player_received connected=" .. tostring(self.connected == true)
						.. " socket=" .. tostring(self.socket ~= nil)
						.. " busy=" .. tostring(self.invitePlayerBusy == true)
						.. " userId=" .. tostring(params and params.user_id or "nil")
						.. " visibility=" .. tostring(params and params.visibility or "private")
						.. " currentRoomId=" .. tostring(ITGOnline and ITGOnline.currentRoomId or "nil"))
	        if self.connected and self.socket ~= nil and ITGOnline and ITGOnline.InviteUserToNewRoom and params and params.user_id then
						if self.invitePlayerBusy then
							online_flow_trace("invite_online_player_skipped reason=busy userId=" .. tostring(params.user_id))
							return
						end
						self.invitePlayerBusy = true
						self.inLobby = false
						local visibility = params.visibility or "private"
						local inviteToken = begin_actor_operation(self, "invite_player")
		          ITGOnline:InviteUserToNewRoom(params.user_id, visibility, function(ok, decoded, response)
							if not actor_operation_is_current(self, "invite_player", inviteToken) then
								self.invitePlayerBusy = false
								online_flow_trace("invite_online_player_callback_ignored reason=stale_operation busy_cleared=true")
								return
							end
							self.invitePlayerBusy = false
							online_flow_trace("invite_online_player_result ok=" .. tostring(ok == true)
								.. " status=" .. tostring(response and response.statusCode or "nil")
								.. " userId=" .. tostring(params.user_id)
								.. " hasRoom=" .. tostring(decoded and decoded.room ~= nil)
								.. " currentRoomId=" .. tostring(ITGOnline and ITGOnline.currentRoomId or "nil")
								.. " error=" .. tostring(decoded and decoded.error_code or response and response.errorMessage or "nil"))
							if ok then
							self.inLobby = true
							if ITGOnline.currentRoom then
								DisplayLobbyState(build_lobby_payload(ITGOnline.currentRoom), self)
								safe_broadcast("OnlineLobbyState", build_lobby_payload(ITGOnline.currentRoom))
							end
							safe_broadcast("OnlineResponseStatus", {
								event="invitePlayer",
								success=true,
								message="Invitation sent."
							})
						else
							safe_broadcast("OnlineResponseStatus", {
								event="invitePlayer",
								success=false,
								message=(decoded and decoded.message) or (response and response.errorMessage) or "Invitation failed."
							})
						end
					end)
	        else
						online_flow_trace("invite_online_player_skipped reason=missing_context"
							.. " connected=" .. tostring(self.connected == true)
							.. " socket=" .. tostring(self.socket ~= nil)
							.. " hasParams=" .. tostring(params ~= nil)
							.. " userId=" .. tostring(params and params.user_id or "nil"))
        end
      end,
	      JoinOnlinePlayerRoomMessageCommand=function(self, params)
	        online_flow_trace("join_online_player_room_received connected=" .. tostring(self.connected == true)
						.. " socket=" .. tostring(self.socket ~= nil)
						.. " busy=" .. tostring(self.joinPlayerBusy == true)
						.. " userId=" .. tostring(params and params.user_id or "nil")
						.. " currentRoomId=" .. tostring(ITGOnline and ITGOnline.currentRoomId or "nil"))
	        if self.connected and self.socket ~= nil and ITGOnline and ITGOnline.RequestJoinUserRoom and params and params.user_id then
						if self.joinPlayerBusy then
							online_flow_trace("join_online_player_room_skipped reason=busy userId=" .. tostring(params.user_id))
							return
						end
						self.joinPlayerBusy = true
						self.inLobby = false
						local joinPlayerToken = begin_actor_operation(self, "join_player_room")
		          ITGOnline:RequestJoinUserRoom(params.user_id, function(ok, decoded, response)
							if not actor_operation_is_current(self, "join_player_room", joinPlayerToken) then
								self.joinPlayerBusy = false
								online_flow_trace("join_online_player_room_callback_ignored reason=stale_operation busy_cleared=true")
								return
							end
							self.joinPlayerBusy = false
							online_flow_trace("join_online_player_room_result ok=" .. tostring(ok == true)
								.. " status=" .. tostring(response and response.statusCode or "nil")
								.. " userId=" .. tostring(params.user_id)
								.. " hasRoom=" .. tostring(decoded and decoded.room ~= nil)
								.. " hasJoinRequest=" .. tostring(decoded and decoded.join_request ~= nil)
								.. " pendingJoinRoomId=" .. tostring(ITGOnline and ITGOnline.pendingJoinRoomId or "nil")
								.. " currentRoomId=" .. tostring(ITGOnline and ITGOnline.currentRoomId or "nil")
								.. " error=" .. tostring(decoded and decoded.error_code or response and response.errorMessage or "nil"))
							if ok and decoded and decoded.room then
								self.inLobby = true
								DisplayLobbyState(build_lobby_payload(decoded.room), self)
								safe_broadcast("OnlineLobbyState", build_lobby_payload(decoded.room))
							elseif ok then
								safe_broadcast("OnlineResponseStatus", {
									event="joinLobby",
									success=true,
									message="Demande envoyee. En attente d'approbation."
								})
						else
							safe_broadcast("OnlineResponseStatus", {
								event="joinLobby",
								success=false,
									message=(decoded and decoded.message) or (response and response.errorMessage) or "Echec de la demande de connexion."
							})
						end
					end)
	        else
						online_flow_trace("join_online_player_room_skipped reason=missing_context"
							.. " connected=" .. tostring(self.connected == true)
							.. " socket=" .. tostring(self.socket ~= nil)
							.. " hasParams=" .. tostring(params ~= nil)
							.. " userId=" .. tostring(params and params.user_id or "nil"))
        end
      end,
	      AnswerPrivateJoinRequestMessageCommand=function(self, params)
	        online_flow_trace("answer_private_join_request_received connected=" .. tostring(self.connected == true)
						.. " socket=" .. tostring(self.socket ~= nil)
						.. " busy=" .. tostring(self.privateJoinAnswerBusy == true)
						.. " requestId=" .. tostring(params and params.join_request_id or "nil")
						.. " accept=" .. tostring(params and params.accept == true))
	        if self.connected and self.socket ~= nil and ITGOnline and params and params.join_request_id then
						if self.privateJoinAnswerBusy then
							online_flow_trace("answer_private_join_request_skipped reason=busy requestId=" .. tostring(params.join_request_id))
							return
						end
						self.privateJoinAnswerBusy = true
						local answerToken = begin_actor_operation(self, "private_join_answer")
						if params.accept then
							if not ITGOnline.AcceptJoinRequest then self.privateJoinAnswerBusy = false return end
							ITGOnline:AcceptJoinRequest(params.join_request_id, function(ok, decoded, response)
								if not actor_operation_is_current(self, "private_join_answer", answerToken) then
									self.privateJoinAnswerBusy = false
									online_flow_trace("answer_private_join_request_callback_ignored reason=stale_operation busy_cleared=true")
									return
								end
								self.privateJoinAnswerBusy = false
								online_flow_trace("answer_private_join_request_accept_result ok=" .. tostring(ok == true)
									.. " status=" .. tostring(response and response.statusCode or "nil")
									.. " requestId=" .. tostring(params.join_request_id)
									.. " hasRoom=" .. tostring(decoded and decoded.room ~= nil)
									.. " error=" .. tostring(decoded and decoded.error_code or response and response.errorMessage or "nil"))
								if ok and decoded and decoded.room then
								DisplayLobbyState(build_lobby_payload(decoded.room), self)
								safe_broadcast("OnlineLobbyState", build_lobby_payload(decoded.room))
							end
							safe_broadcast("OnlineResponseStatus", {
								event="privateJoinAnswer",
								success=ok and true or false,
									message=ok and "Demande acceptee." or ((decoded and decoded.message) or (response and response.errorMessage) or "Impossible de repondre a la demande.")
							})
						end)
						else
							if not ITGOnline.DeclineJoinRequest then self.privateJoinAnswerBusy = false return end
							ITGOnline:DeclineJoinRequest(params.join_request_id, params.reason or "", function(ok, decoded, response)
								if not actor_operation_is_current(self, "private_join_answer", answerToken) then
									self.privateJoinAnswerBusy = false
									online_flow_trace("answer_private_join_request_callback_ignored reason=stale_operation busy_cleared=true")
									return
								end
								self.privateJoinAnswerBusy = false
								online_flow_trace("answer_private_join_request_decline_result ok=" .. tostring(ok == true)
									.. " status=" .. tostring(response and response.statusCode or "nil")
									.. " requestId=" .. tostring(params.join_request_id)
									.. " reason=" .. tostring(params.reason or "")
									.. " error=" .. tostring(decoded and decoded.error_code or response and response.errorMessage or "nil"))
								safe_broadcast("OnlineResponseStatus", {
								event="privateJoinAnswer",
								success=ok and true or false,
									message=ok and "Demande refusee." or ((decoded and decoded.message) or (response and response.errorMessage) or "Impossible de repondre a la demande.")
							})
						end)
						end
	        else
						online_flow_trace("answer_private_join_request_skipped reason=missing_context"
							.. " connected=" .. tostring(self.connected == true)
							.. " socket=" .. tostring(self.socket ~= nil)
							.. " hasParams=" .. tostring(params ~= nil)
							.. " requestId=" .. tostring(params and params.join_request_id or "nil"))
        end
      end,
	      AnswerRoomInvitationMessageCommand=function(self, params)
	        online_flow_trace("answer_room_invitation_received connected=" .. tostring(self.connected == true)
						.. " socket=" .. tostring(self.socket ~= nil)
						.. " busy=" .. tostring(self.roomInvitationAnswerBusy == true)
						.. " invitationId=" .. tostring(params and params.invitation_id or "nil")
						.. " accept=" .. tostring(params and params.accept == true))
	        if self.connected and self.socket ~= nil and ITGOnline and params and params.invitation_id then
						if self.roomInvitationAnswerBusy then
							online_flow_trace("answer_room_invitation_skipped reason=busy invitationId=" .. tostring(params.invitation_id))
							return
						end
						self.roomInvitationAnswerBusy = true
						local invitationToken = begin_actor_operation(self, "room_invitation_answer")
						if params.accept then
							if not ITGOnline.AcceptInvitation then self.roomInvitationAnswerBusy = false return end
							ITGOnline:AcceptInvitation(params.invitation_id, function(ok, decoded, response)
								if not actor_operation_is_current(self, "room_invitation_answer", invitationToken) then
									self.roomInvitationAnswerBusy = false
									online_flow_trace("answer_room_invitation_callback_ignored reason=stale_operation busy_cleared=true")
									return
								end
								self.roomInvitationAnswerBusy = false
								online_flow_trace("answer_room_invitation_accept_result ok=" .. tostring(ok == true)
									.. " status=" .. tostring(response and response.statusCode or "nil")
									.. " invitationId=" .. tostring(params.invitation_id)
									.. " hasRoom=" .. tostring(decoded and decoded.room ~= nil)
									.. " currentRoomId=" .. tostring(ITGOnline and ITGOnline.currentRoomId or "nil")
									.. " error=" .. tostring(decoded and decoded.error_code or response and response.errorMessage or "nil"))
								if ok and decoded and decoded.room then
									DisplayLobbyState(build_lobby_payload(decoded.room), self)
									safe_broadcast("OnlineLobbyState", build_lobby_payload(decoded.room))
								end
								safe_broadcast("OnlineResponseStatus", {
									event="roomInvitationAnswer",
									success=ok and true or false,
										message=ok and "Invitation acceptee." or ((decoded and decoded.message) or (response and response.errorMessage) or "Impossible de repondre a l'invitation.")
								})
							end)
						else
							if not ITGOnline.DeclineInvitation then self.roomInvitationAnswerBusy = false return end
							ITGOnline:DeclineInvitation(params.invitation_id, function(ok, decoded, response)
								if not actor_operation_is_current(self, "room_invitation_answer", invitationToken) then
									self.roomInvitationAnswerBusy = false
									online_flow_trace("answer_room_invitation_callback_ignored reason=stale_operation busy_cleared=true")
									return
								end
								self.roomInvitationAnswerBusy = false
								online_flow_trace("answer_room_invitation_decline_result ok=" .. tostring(ok == true)
									.. " status=" .. tostring(response and response.statusCode or "nil")
									.. " invitationId=" .. tostring(params.invitation_id)
									.. " error=" .. tostring(decoded and decoded.error_code or response and response.errorMessage or "nil"))
								safe_broadcast("OnlineResponseStatus", {
									event="roomInvitationAnswer",
									success=ok and true or false,
										message=ok and "Invitation refusee." or ((decoded and decoded.message) or (response and response.errorMessage) or "Impossible de repondre a l'invitation.")
								})
							end)
						end
	        else
						online_flow_trace("answer_room_invitation_skipped reason=missing_context"
							.. " connected=" .. tostring(self.connected == true)
							.. " socket=" .. tostring(self.socket ~= nil)
							.. " hasParams=" .. tostring(params ~= nil)
							.. " invitationId=" .. tostring(params and params.invitation_id or "nil"))
        end
      end,
				SearchLobbyMessageCommand=function(self, params)
					online_trace("FLOW SearchLobbyMessage received connected=" .. tostring(self.connected)
						.. " socket=" .. tostring(self.socket ~= nil)
						.. " busy=" .. tostring(self.searchLobbyBusy == true)
						.. " force=" .. tostring(params and params.force == true)
						.. " minInterval=" .. tostring(params and params.minInterval or "nil"))
					if self.connected and self.socket ~= nil and ITGOnline and ITGOnline.FetchLobby then
						local now = GetTimeSinceStart()
						local force = params and params.force == true
						local minInterval = tonumber(params and params.minInterval) or 0.75
						if self.searchLobbyBusy then
							online_trace("FLOW SearchLobbyMessage skipped reason=busy")
							return
						end
						if not force
							and self.searchLobbyLastRequestAt
							and now - self.searchLobbyLastRequestAt < minInterval then
							online_trace(
								"FLOW search_lobby_skipped reason=debounce elapsed=" ..
								tostring(now - self.searchLobbyLastRequestAt))
							return
						end
						self.searchLobbyBusy = true
						self.searchLobbyLastRequestAt = now
						local searchToken = begin_actor_operation(self, "search_lobby")
						ITGOnline:FetchLobby(function(ok, decoded, response)
							if not actor_operation_is_current(self, "search_lobby", searchToken) then
								self.searchLobbyBusy = false
								online_flow_trace("search_lobby_callback_ignored reason=stale_operation busy_cleared=true")
								return
							end
							self.searchLobbyBusy = false
							online_trace("FLOW SearchLobbyMessage result ok=" .. tostring(ok == true)
								.. " status=" .. tostring(response and response.statusCode or "nil")
								.. " publicRooms=" .. tostring(decoded and decoded.public_rooms and #decoded.public_rooms or decoded and decoded.lobbies and #decoded.lobbies or 0)
								.. " onlineUsers=" .. tostring(decoded and decoded.online_users and #decoded.online_users or decoded and decoded.onlinePlayers and #decoded.onlinePlayers or 0)
								.. " error=" .. tostring(decoded and decoded.message or response and response.errorMessage or "nil"))
							if ok then
							safe_broadcast("LobbySearched", ITGOnline:LobbySearchPayload(decoded))
						else
							safe_broadcast("OnlineResponseStatus", {
								event="searchLobby",
								success=false,
									message=(decoded and decoded.message) or (response and response.errorMessage) or "Echec de recherche des salons."
							})
						end
					end)
				else
					online_trace("FLOW SearchLobbyMessage skipped reason=not_connected_or_no_socket")
				end
			end,
						LeaveLobbyMessageCommand=function(self)
							if online_trace then
								online_trace(
									"FLOW LeaveLobbyMessage begin connected=" .. tostring(self.connected) ..
									" socket=" .. tostring(self.socket ~= nil) ..
									" busy=" .. tostring(self.leaveLobbyBusy) ..
									" inLobby=" .. tostring(self.inLobby) ..
									" currentRoomId=" .. tostring(ITGOnline and ITGOnline.currentRoomId))
							end
							if not self.connected or self.socket == nil or not (ITGOnline and ITGOnline.LeaveRoom) then
								if online_trace then
									online_trace("FLOW LeaveLobbyMessage skipped reason=not_connected_or_no_socket")
								end
								return
							end
							if self.leaveLobbyBusy then
								if online_trace then
									online_trace("FLOW LeaveLobbyMessage skipped reason=busy")
								end
								return
							end
							local currentRoom = ITGOnline and ITGOnline.currentRoom or nil
							local currentPhase = ITGOnline and ITGOnline.NormalizeRoomPhase
								and ITGOnline:NormalizeRoomPhase(currentRoom and currentRoom.phase or ITGOnline.currentRoomPhase)
								or tostring(currentRoom and currentRoom.phase or "")
							if currentPhase == "starting" or currentPhase == "playing" then
								if online_trace then
									online_trace("FLOW LeaveLobbyMessage blocked reason=phase_not_leaveable"
										.. " roomId=" .. tostring(ITGOnline and ITGOnline.currentRoomId or "nil")
										.. " phase=" .. tostring(currentPhase))
								end
								safe_broadcast("OnlineResponseStatus", {
									event="leaveLobby",
									success=false,
									errorCode="phase_not_leaveable",
									message="La manche se termine. Sortie disponible apres les resultats."
								})
								return
							end
								self.leaveLobbyBusy = true
								clear_room_input_state("leave_lobby_request")
								local leaveRoomId = ITGOnline and ITGOnline.currentRoomId or nil
								local leaveRoomCode = ITGOnline and ITGOnline.currentRoom
									and (ITGOnline.currentRoom.code or ITGOnline.currentRoom.room_code or ITGOnline.currentRoom.roomCode)
									or nil
								if online_trace then
									online_trace("FLOW LeaveLobbyMessage request roomId=" .. tostring(leaveRoomId)
										.. " lobbyCode=" .. tostring(leaveRoomCode)
										.. " phase=" .. tostring(ITGOnline and ITGOnline.currentRoom and ITGOnline.currentRoom.phase or "nil")
										.. " inLobby=" .. tostring(self.inLobby == true))
								end
								local leaveToken = begin_actor_operation(self, "leave_lobby")
								ITGOnline:LeaveRoom(function(ok, decoded, response)
									if not actor_operation_is_current(self, "leave_lobby", leaveToken) then
										self.leaveLobbyBusy = false
										online_flow_trace("leave_lobby_callback_ignored reason=stale_operation busy_cleared=true")
										return
									end
									local alreadyLeftHandled = self.inLobby == false
										and ITGOnline
										and ITGOnline.currentRoomId == nil
									if online_trace then
										online_trace(
											"FLOW LeaveLobbyMessage callback_begin ok=" .. tostring(ok) ..
											" status=" .. tostring(response and response.status) ..
											" statusCode=" .. tostring(response and response.statusCode) ..
											" currentRoomId=" .. tostring(ITGOnline and ITGOnline.currentRoomId) ..
											" leaveRoomId=" .. tostring(leaveRoomId) ..
											" leaveRoomCode=" .. tostring(leaveRoomCode) ..
											" alreadyLeftHandled=" .. tostring(alreadyLeftHandled))
									end
									self.leaveLobbyBusy = false
									if ok then
										self.inLobby = false
										clear_room_async_state(self)
										clear_room_input_state("leave_lobby_confirmed")
										if ITGOnline and ITGOnline.QueuePostRoomExitLobbyRefresh then
											ITGOnline:QueuePostRoomExitLobbyRefresh("leave_lobby_confirmed_callback", 0.20)
										end
										if alreadyLeftHandled then
											if online_trace then
												online_trace("FLOW LeaveLobbyMessage broadcast_OnlineLobbyLeft_skipped reason=already_left")
											end
										else
											if online_trace then
												online_trace("FLOW LeaveLobbyMessage broadcast_OnlineLobbyLeft_begin")
											end
											safe_broadcast("OnlineLobbyLeft", {
												left=true,
												roomId=leaveRoomId,
												lobbyCode=leaveRoomCode,
												source="leave_callback",
											})
											if online_trace then
												online_trace("FLOW LeaveLobbyMessage broadcast_OnlineLobbyLeft_end")
											end
										end
									else
									self.inLobby = true
									if online_trace then
										online_trace("FLOW LeaveLobbyMessage failed_broadcast_status")
									end
									safe_broadcast("OnlineResponseStatus", {
										event="leaveLobby",
										success=false,
										errorCode=(decoded and (decoded.error_code or decoded.errorCode)) or (response and response.errorCode) or nil,
										message=(decoded and decoded.message) or (response and response.errorMessage) or "Echec de sortie du salon."
									})
								end
								if online_trace then
									online_trace("FLOW LeaveLobbyMessage callback_end")
								end
							end)
						end,
		      DisconnectOnlineMessageCommand=function(self, params)
						if online_trace then
							online_trace("FLOW DisconnectOnlineMessage received leaveRoom=" .. tostring(not (params and params.leaveRoom == false))
								.. " connected=" .. tostring(self.connected == true)
								.. " socket=" .. tostring(self.socket ~= nil)
								.. " inLobby=" .. tostring(self.inLobby == true)
								.. " currentRoomId=" .. tostring(ITGOnline and ITGOnline.currentRoomId or "nil"))
						end
						onlineHandlerShuttingDown = true
						clear_room_async_state(self)
						stop_connection_timers(self)
						isWaiting = false
						if ITGOnline and ITGOnline.Disconnect then
							ITGOnline:Disconnect({ leaveRoom = not (params and params.leaveRoom == false) })
						end
						UnlockOnlineInput()
						self.connected = false
						self.inLobby = false
						self.socket = nil
						self:GetChild("Display"):GetChild("Text"):settext("")
						self:GetChild("Display"):visible(false)
					end,

					Def.Actor{
						Name="RealtimeDeadmanTimer",
						FireCommand=function(self) self:GetParent():playcommand("RealtimeDeadman") end,
					},
					Def.Actor{
						Name="OnlineHeartbeatTimer",
						FireCommand=function(self) self:GetParent():playcommand("OnlineHeartbeatTick") end,
					},
					Def.Actor{
						Name="ReconnectTimer",
						FireCommand=function(self) self:GetParent():playcommand("ReconnectOnline") end,
					},
					Def.Actor{
						Name="DeferredLobbyRefreshTimer",
						FireCommand=function(self) self:GetParent():playcommand("DeferredLobbyRefresh") end,
					},
					Def.Actor{
						Name="OnlinePlayingCountdownTimer",
						FireCommand=function(self) self:GetParent():playcommand("OnlinePlayingCountdownTick") end,
					},
					Def.Actor{
						Name="OnlineGameplayStartTimer",
						FireCommand=function(self) self:GetParent():playcommand("ReleaseOnlineGameplayAtStart") end,
					},
					Def.Actor{
						Name="PreviewInitialSongTimer",
						FireCommand=function(self) self:GetParent():playcommand("PreviewInitialOnlineSong") end,
					},
					Def.Actor{
						Name="ReplayDeferredLobbyStateTimer",
						FireCommand=function(self) self:GetParent():playcommand("ReplayDeferredLobbyState") end,
					},
					Def.Actor{
						Name="ConfigReadyRetryTimer",
						FireCommand=function(self) self:GetParent():playcommand("RetryOnlineConfigReady") end,
					},
					Def.Actor{
						Name="ManagerAutoReadyRetryTimer",
						FireCommand=function(self) self:GetParent():playcommand("RetryOnlineManagerAutoReady") end,
					},

			      Def.Actor{
			        Name="OnlineStartPollTimer",
	        PollCommand=function(self)
						local actor = self:GetParent()
						local roomId = pendingOnlineStartRoomId
						if not roomId or not (ITGOnline and ITGOnline.FetchRoom) then
							return
						end

							ITGOnline:FetchRoom(roomId, function(ok, decoded)
								if not online_room_ids_match(roomId, current_room_id()) then
									online_flow_trace("online_start_poll_ignored reason=stale_room requested=" .. tostring(roomId)
										.. " current=" .. current_room_id())
									return
								end
								if not ok or not decoded or not decoded.room then
									PollOnlineStart(actor, roomId)
									return
								end
								if not online_room_ids_match(decoded.room.id or decoded.room.room_id or decoded.room.roomId, roomId) then
									online_flow_trace("online_start_poll_ignored reason=room_mismatch requested=" .. tostring(roomId)
										.. " decoded=" .. tostring(decoded.room.id or "nil"))
									return
								end

								local payload = build_lobby_payload(decoded.room)
							DisplayLobbyState(payload, actor)
							safe_broadcast("OnlineLobbyState", payload)

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
	          local screen = current_top_screen()
          local screenName = screen_name(screen)

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
            local p1Joined = GAMESTATE and GAMESTATE:IsSideJoined("PlayerNumber_P1") or false
            local p2Joined = GAMESTATE and GAMESTATE:IsSideJoined("PlayerNumber_P2") or false

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
