local function online_lobby_text(key, fallback, ...)
	local value = fallback or key
	if THEME and THEME.HasString and THEME:HasString("ScreenOnlineLobbies", key) then
		value = THEME:GetString("ScreenOnlineLobbies", key)
	end
	if select("#", ...) > 0 then
		local ok, formatted = pcall(string.format, value, ...)
		if ok then return formatted end
	end
	return value
end

-- Screen state
-- -----------------------------------------------------------------------

local active_index = 3
local list_selected = false
local options = {
	online_lobby_text("AvailableLobbies", "Available lobbies"),
	online_lobby_text("OnlinePlayers", "Online players"),
	online_lobby_text("Refresh", "Refresh"),
	online_lobby_text("CreateLobby", "Create lobby"),
	online_lobby_text("Back", "Back"),
}
local t = nil
local connected = false
local has_error = false
local input_added = false

local holding = {
	["MenuRight"]=false,
	["MenuLeft"]=false,
}

local candidates = {}
local online_users = {}
local lobby_view = "lobbies"
local online_player_index = 1
local showing_player_action_menu = false
local player_action_index = 1
local player_action_options = {}
local player_action_user = nil
local showing_transfer_manager_confirm = false
local transfer_manager_confirm_index = 0
local transfer_manager_confirm_user = nil
local transfer_manager_confirm_action = "transfer_manager"
local showing_private_join_prompt = false
local private_join_prompt_index = 1
local private_join_request = nil
local private_join_prompt_kind = "join_request"
local private_prompt_queue = {}
local private_prompt_keys = {}
local MAX_PRIVATE_PROMPTS = 16
local showing_pack_choice_menu = false
local pack_choice_index = 1
local pack_choice_candidates = {}
local pack_choice_song_info = nil
local pack_choice_message = nil
local pack_choice_last_candidates = {}
local pack_choice_last_song_info = nil
local pack_choice_last_selected_pack_id = nil
local pack_choice_all_candidates_exhausted = false
local pack_choice_browse_only = false
local pack_choice_download_key = nil
local private_join_options = {
	{label=online_lobby_text("Accept", "Accept"), accept=true, reason=""},
	{label=online_lobby_text("Decline", "Decline"), accept=false, reason=""},
	{label=online_lobby_text("Busy", "Busy"), accept=false, reason=online_lobby_text("BusyReason", "Busy right now.")},
	{label=online_lobby_text("Later", "Later"), accept=false, reason=online_lobby_text("LaterReason", "Later.")},
}

local function private_prompt_key(params, kind)
	local payload = type(params) == "table" and params[kind == "invitation" and "invitation" or "join_request"] or nil
	return kind .. ":" .. tostring(type(payload) == "table" and payload.id or "")
end

local function display_private_prompt(actor, params, kind)
	private_join_request = params
	private_join_prompt_kind = kind
	private_join_prompt_index = 1
	showing_private_join_prompt = true
	local prompt = actor:GetChild("PrivateJoinPrompt")
	if prompt then prompt:visible(true) end
	actor:queuecommand("UpdatePrivateJoinPrompt")
end

local function enqueue_private_prompt(actor, params, kind)
	local key = private_prompt_key(params, kind)
	if key:sub(-1) == ":" or private_prompt_keys[key] then return false end
	private_prompt_keys[key] = true
	if not showing_private_join_prompt then
		display_private_prompt(actor, params, kind)
		return true
	end
	if #private_prompt_queue >= MAX_PRIVATE_PROMPTS then
		private_prompt_keys[key] = nil
		lobby_flow_trace("private_prompt_rejected reason=queue_full kind=" .. tostring(kind))
		return false
	end
	private_prompt_queue[#private_prompt_queue + 1] = { params = params, kind = kind, key = key }
	return true
end

local function finish_private_prompt(actor)
	private_prompt_keys[private_prompt_key(private_join_request, private_join_prompt_kind)] = nil
	showing_private_join_prompt = false
	private_join_request = nil
	local prompt = actor:GetChild("PrivateJoinPrompt")
	if prompt then prompt:visible(false) end
	local nextPrompt = table.remove(private_prompt_queue, 1)
	if nextPrompt then display_private_prompt(actor, nextPrompt.params, nextPrompt.kind) end
end

local room_invitation_options = {
	{label=online_lobby_text("AcceptInvitation", "Accept invitation"), accept=true},
	{label=online_lobby_text("DeclineInvitation", "Decline invitation"), accept=false},
	{label=online_lobby_text("Close", "Close"), dismiss=true},
}
local pending_join_action_id = 0
local pending_join_deadline = 0
local pending_create_action_id = 0
local pending_create_deadline = 0
local lobby_search_ui_pending = false
local lobby_ui_update_pending = false
local lobby_ui_update_reason = ""
local request_lobby_refresh = nil
local request_lobby_ui_repaint = nil
local lobby_trace_state = {
	lastOnlineLobbyStateSignature = "",
	lastOnlineLobbyStateSignatureAt = 0,
	lastPackSyncLocalStatusSignature = "",
	lastPackSyncLocalStatusAt = 0,
	lastStartVisibilityDebugKey = "",
	lastSelectSongVisibilityDebugKey = "",
	lastAutoStartFocusKey = "",
	lastAutoStartRequestKey = "",
	lastOnlineMissingSongSignature = "",
	lastOnlineMissingSongSignatureAt = 0,
	onlineMissingSongDuplicateWindow = 3.0,
	joinedPreviewPlaybackKey = "",
	seen = {},
	order = {},
	maxSignatures = 512,
}
local online_warning_countdown_last_second = {}

local mode = "browse"
local joined_active_index = 1
local joined_is_manager = false
local joined_phase = nil
local joined_local_returned_to_lobby_after_results = false
local joined_lobby_code = ""
local joined_lobby_players = {}
local joined_player_index = 1
local joined_players_selected = false
local joined_manager_user_id = nil
local joined_song_preview = nil
local joined_song_confirmed = false
local joined_song_selected_key = ""
local joined_song_transition_notice_at = 0
local joined_missing_song = false
local joined_missing_song_info = nil
local joined_can_download_pack = false
local joined_missing_song_reason = nil
local joined_preview_unknown_pack = false
local leaving_lobby = false
local showing_leave_confirm = false
local leave_confirm_index = 0
local leave_confirm_mode = "leave_lobby"
local showing_browse_pack_download_confirm = false
local browse_pack_download_confirm_index = 0
local browse_pack_download_song_info = nil
local showing_global_options_menu = false
local global_options_index = 1
local joined_global_options = { scoreMode="itg", musicRate=1.0 }
local global_options_choices = {}
local input_quiet_until = 0
local joined_focus_initialized = false
local joined_user_moved_focus = false

local join_lobby_code = ""

SL.Global.Online = SL.Global.Online or {}
SL.Global.Online.ScreenOnlineLobbiesInputHandlers = SL.Global.Online.ScreenOnlineLobbiesInputHandlers or {}
SL.Global.Online.ScreenOnlineLobbiesInputDedup = SL.Global.Online.ScreenOnlineLobbiesInputDedup or {
	key = "",
	at = 0,
}
SL.Global.Online.ScreenOnlineLobbiesLeaveFinishedAt = SL.Global.Online.ScreenOnlineLobbiesLeaveFinishedAt or -999
local overlay_instance_id = tostring({})
local lobby_flow_trace

local function is_active_lobby_overlay()
	return SL
		and SL.Global
		and SL.Global.Online
		and SL.Global.Online.ScreenOnlineLobbiesActiveInstance == overlay_instance_id
end

local function stable_scalar(value)
	if value == nil then return "" end
	return tostring(value)
end

-- Stable lobby view models
-- -----------------------------------------------------------------------

local function realtime_health_snapshot()
	if ITGOnline and ITGOnline.RealtimeHealthSnapshot then
		return ITGOnline:RealtimeHealthSnapshot()
	end
	return {
		state = "offline",
		label = online_lobby_text("HttpOnly", "HTTP ONLY"),
		color = {0.55, 0.55, 0.55, 0.90},
		age = 999,
		connected = false,
		connecting = false,
		socket = false,
	}
end

local function player_state_signature(player)
	player = type(player) == "table" and player or {}
	local user = type(player.user) == "table" and player.user or {}
	return table.concat({
		stable_scalar(player.id or player.user_id or user.id),
		stable_scalar(user.display_name or user.displayName or user.name or player.name),
		stable_scalar(player.status or player.play_state or player.state),
		stable_scalar(player.ready_state or player.readyState),
		stable_scalar(player.is_ready or player.ready),
		stable_scalar(player.song_available or player.songAvailable),
		stable_scalar(player.missing_song or player.missingSong),
		stable_scalar(player.pack_sync_status or player.packSyncStatus),
		stable_scalar(player.pack_sync_sequence or player.packSyncSequence),
		stable_scalar(player.download_progress or player.downloadProgress),
		stable_scalar(player.pack_sync_download_deadline_ms or player.packSyncDownloadDeadlineMs),
	}, ":")
end

local function joined_player_stable_key(player)
	if type(player) ~= "table" then return "" end
	local user = type(player.user) == "table" and player.user or {}
	local key = player.playerId or player.id or player.user_id or user.id
	if key ~= nil and tostring(key) ~= "" then
		return "id:" .. tostring(key)
	end
	key = player.profileName or player.displayName or player.name or user.display_name or user.displayName or user.name
	if key ~= nil and tostring(key) ~= "" then
		return "name:" .. tostring(key)
	end
	return ""
end

local function joined_player_index_for_key(players, key, fallback)
	if key == nil or tostring(key) == "" then
		return fallback or 1
	end
	for index, player in ipairs(players or {}) do
		if joined_player_stable_key(player) == key then
			return index
		end
	end
	return fallback or 1
end

local function joined_players_order_signature(players)
	local parts = {}
	for index, player in ipairs(players or {}) do
		parts[#parts + 1] = tostring(index) .. "=" .. tostring(joined_player_stable_key(player))
	end
	return table.concat(parts, ",")
end

local function merge_joined_players_preserving_visual_order(currentPlayers, incomingPlayers)
	currentPlayers = type(currentPlayers) == "table" and currentPlayers or {}
	incomingPlayers = type(incomingPlayers) == "table" and incomingPlayers or {}

	local incomingByKey = {}
	local incomingKeys = {}
	local anonymousIncoming = {}
	for _, player in ipairs(incomingPlayers) do
		local key = joined_player_stable_key(player)
		if key ~= "" then
			incomingByKey[key] = player
			incomingKeys[#incomingKeys + 1] = key
		else
			anonymousIncoming[#anonymousIncoming + 1] = player
		end
	end

	local merged = {}
	local consumed = {}
	for _, current in ipairs(currentPlayers) do
		local key = joined_player_stable_key(current)
		local incoming = key ~= "" and incomingByKey[key] or nil
		if incoming ~= nil then
			merged[#merged + 1] = incoming
			consumed[key] = true
		end
	end

	for _, key in ipairs(incomingKeys) do
		if not consumed[key] then
			merged[#merged + 1] = incomingByKey[key]
			consumed[key] = true
		end
	end

	for _, player in ipairs(anonymousIncoming) do
		merged[#merged + 1] = player
	end

	if lobby_flow_trace then
		lobby_flow_trace("joined_players_merge"
			.. " currentCount=" .. tostring(#currentPlayers)
			.. " incomingCount=" .. tostring(#incomingPlayers)
			.. " mergedCount=" .. tostring(#merged)
			.. " currentOrder=" .. tostring(joined_players_order_signature(currentPlayers))
			.. " incomingOrder=" .. tostring(joined_players_order_signature(incomingPlayers))
			.. " mergedOrder=" .. tostring(joined_players_order_signature(merged)))
	end

	return merged
end

local function online_lobby_state_signature(params)
	params = type(params) == "table" and params or {}
	local players = {}
	for index, player in ipairs(params.players or {}) do
		players[#players + 1] = player_state_signature(player) .. "#" .. tostring(index)
	end
	table.sort(players)
	local songInfo = type(params.songInfo) == "table" and params.songInfo or {}
	local playState = type(params.playState) == "table" and params.playState or {}
	local playSessions = {}
	for index, session in ipairs(playState.sessions or {}) do
		session = type(session) == "table" and session or {}
		local user = type(session.user) == "table" and session.user or {}
		playSessions[#playSessions + 1] = table.concat({
			stable_scalar(session.user_id or user.id),
			stable_scalar(session.state),
			stable_scalar(session.returned_to_lobby_at),
			stable_scalar(session.finished_at),
			stable_scalar(session.failed_at),
			stable_scalar(session.disconnected_at),
			tostring(index),
		}, ":")
	end
	table.sort(playSessions)
	local globalOptions = type(params.globalOptions) == "table" and params.globalOptions or {}
	local manager = type(params.manager) == "table" and params.manager or {}
	return table.concat({
		stable_scalar(params.roomId or params.id),
		stable_scalar(params.code),
		stable_scalar(params.phase or params.status or params.readyPhase),
		stable_scalar(params.isManager),
		stable_scalar(manager.id),
		stable_scalar(songInfo.selectedAt or songInfo.selected_at),
		stable_scalar(songInfo.song_hash or songInfo.songHash),
		stable_scalar(songInfo.chart_hash or songInfo.chartHash),
		stable_scalar(songInfo.pack),
		stable_scalar(globalOptions.scoreMode),
		stable_scalar(globalOptions.musicRate),
		stable_scalar(playState.submitted_scores and #playState.submitted_scores),
		stable_scalar(playState.final_results and #playState.final_results),
		table.concat(playSessions, "|"),
		table.concat(players, "|"),
	}, "||")
end

local function pack_sync_local_status_signature(params)
	params = type(params) == "table" and params or {}
	local contextCode = joined_lobby_code
	if tostring(contextCode or "") == "" then
		contextCode = params.room_id or params.roomId or (ITGOnline and ITGOnline.currentRoomId) or ""
	end
	local contextPhase = joined_phase
	if tostring(contextPhase or "") == "" then
		contextPhase = params.room_phase or params.roomPhase or (ITGOnline and ITGOnline.currentRoom and ITGOnline.currentRoom.phase) or ""
	end
	return table.concat({
		stable_scalar(contextCode),
		stable_scalar(contextPhase),
		stable_scalar(params.userId or params.user_id),
		stable_scalar(params.status),
		stable_scalar(params.message),
		stable_scalar(params.download_progress or params.progress),
		stable_scalar(params.selected_at or params.selectedAt),
	}, "||")
end

function play_online_sound_once(screenName, soundName, minInterval)
	SL.Global.Online.ScreenOnlineLobbiesSoundLastPlayedAt =
		SL.Global.Online.ScreenOnlineLobbiesSoundLastPlayedAt or {}

	local online_sound_last_played_at = SL.Global.Online.ScreenOnlineLobbiesSoundLastPlayedAt
	local now = GetTimeSinceStart()
	local key = tostring(screenName) .. ":" .. tostring(soundName)
	local interval = tonumber(minInterval) or 0.08

	if online_sound_last_played_at[key] and now - online_sound_last_played_at[key] < interval then
		return
	end

	online_sound_last_played_at[key] = now
	SOUND:PlayOnce(THEME:GetPathS(screenName, soundName))
end

local function play_online_warning_countdown_tick(countdownKey, remainingSeconds)
	local second = tonumber(remainingSeconds)
	if not second then return end
	second = math.ceil(second)
	countdownKey = tostring(countdownKey or "")
	if countdownKey == "" then return end

	if second < 1 or second > 5 then
		online_warning_countdown_last_second[countdownKey] = nil
		return
	end
	if online_warning_countdown_last_second[countdownKey] == second then
		return
	end

	online_warning_countdown_last_second[countdownKey] = second
	if lobby_flow_trace then
		lobby_flow_trace("warning_countdown_tick source=pack_sync_kick"
			.. " key=" .. tostring(countdownKey)
			.. " remaining=" .. tostring(second)
			.. " room=" .. tostring(ITGOnline and ITGOnline.currentRoomId or "nil"))
	end
	SOUND:PlayOnce(THEME:GetPathS("MenuTimer", "tick"))
end

function ScreenOnlineLobbiesApplyCurrentRoomSnapshot(root, reason)
	if not root or not ITGOnline or not ITGOnline.currentRoom or not ITGOnline.LobbyStatePayload then
		return false
	end
	if not ITGOnline.currentRoomId then
		return false
	end

	lobby_flow_trace("apply_current_room_snapshot reason=" .. tostring(reason or "unknown")
		.. " room=" .. tostring(ITGOnline.currentRoomId)
		.. " phase=" .. tostring(ITGOnline.currentRoom.phase or "nil"))
	MESSAGEMAN:Broadcast("OnlineLobbyState", ITGOnline:LobbyStatePayload(ITGOnline.currentRoom))
	return true
end

function ScreenOnlineLobbiesRemoveLobbyCandidateByCode(code)
	code = tostring(code or "")
	if code == "" or type(candidates) ~= "table" then
		return false
	end

	local filtered = {}
	local removed = false
	for _, room in ipairs(candidates) do
		local roomCode = tostring(room and (room.code or room.id) or "")
		if roomCode == code then
			removed = true
		else
			filtered[#filtered + 1] = room
		end
	end

	if removed then
		candidates = filtered
	end

	return removed
end

local function mark_recently_left_lobby_code(code, reason)
	code = tostring(code or "")
	if code == "" then
		return
	end

	SL.Global.Online = SL.Global.Online or {}
	SL.Global.Online.ScreenOnlineLobbiesRecentlyLeftCodes = SL.Global.Online.ScreenOnlineLobbiesRecentlyLeftCodes or {}
	SL.Global.Online.ScreenOnlineLobbiesRecentlyLeftCodes[code] = GetTimeSinceStart() + 12
	lobby_flow_trace("recently_left_lobby_code_marked"
		.. " code=" .. tostring(code)
		.. " reason=" .. tostring(reason or "unknown"))
end

local function is_recently_left_lobby_code(code)
	code = tostring(code or "")
	if code == "" then
		return false
	end

	local recentlyLeft = SL.Global.Online and SL.Global.Online.ScreenOnlineLobbiesRecentlyLeftCodes or nil
	if type(recentlyLeft) ~= "table" then
		return false
	end

	local expiresAt = tonumber(recentlyLeft[code]) or 0
	if expiresAt <= 0 then
		return false
	end

	if GetTimeSinceStart() >= expiresAt then
		recentlyLeft[code] = nil
		lobby_flow_trace("recently_left_lobby_code_expired code=" .. tostring(code))
		return false
	end

	return true
end

local function filter_recently_left_lobby_candidates(incoming, reason)
	if type(incoming) ~= "table" then
		return {}
	end

	local filtered = {}
	local restored = 0
	for _, room in ipairs(incoming) do
		local code = tostring(room and (room.code or room.roomId or room.id) or "")
		if is_recently_left_lobby_code(code) then
			if SL.Global.Online and type(SL.Global.Online.ScreenOnlineLobbiesRecentlyLeftCodes) == "table" then
				SL.Global.Online.ScreenOnlineLobbiesRecentlyLeftCodes[code] = nil
			end
			restored = restored + 1
		end
		filtered[#filtered + 1] = room
	end

	if restored > 0 then
		lobby_flow_trace("LobbySearched_restored_recently_left"
			.. " restored=" .. tostring(restored)
			.. " remaining=" .. tostring(#filtered)
			.. " reason=" .. tostring(reason or "unknown"))
	end

	return filtered
end

SL.Global.Online.PackChoiceRecovery = SL.Global.Online.PackChoiceRecovery or {}
if type(SL.Global.Online.PackChoiceRecovery.candidates) == "table" then
	pack_choice_last_candidates = SL.Global.Online.PackChoiceRecovery.candidates
	pack_choice_last_song_info = SL.Global.Online.PackChoiceRecovery.songInfo
	pack_choice_last_selected_pack_id = SL.Global.Online.PackChoiceRecovery.selectedPackId
	pack_choice_download_key = SL.Global.Online.PackChoiceRecovery.downloadKey
end

local function clear_pack_choice_recovery()
	pack_choice_last_candidates = {}
	pack_choice_last_song_info = nil
	pack_choice_last_selected_pack_id = nil
	pack_choice_all_candidates_exhausted = false
	pack_choice_download_key = nil
	if SL and SL.Global and SL.Global.Online then
		SL.Global.Online.PackChoiceRecovery = {}
	end
end

local joined_any_player_missing_song
local joined_all_players_ready
local network_status_clear_at = 0
local pack_sync_busy
local clear_pending_join
local clear_pending_create

local function network_status_has_active_transient()
	return network_status_clear_at > 0 and GetTimeSinceStart() + 0.05 < network_status_clear_at
end

local function hide_network_status_if_idle(actor)
	if not actor or network_status_has_active_transient() then return end
	local status = actor:GetChild("NetworkStatus")
	if status then status:visible(false) end
end

local lobby_layout = {
	browseLobbyX = -205,
	browsePlayersX = 35,
	browseButtonX = 245,
	browsePanelY = -20,
	browsePanelWidth = 230,
	browsePanelHeight = 340,
	browseButtonWidth = 145,
	browseButtonHeight = 34,
	browseButtonSpacing = 12,
}

local function browse_button_y(idx)
	local first = 3
	local offset = idx - first
	return -62 + offset * (lobby_layout.browseButtonHeight + lobby_layout.browseButtonSpacing)
end

local function online_menu_button(button)
	if button == "MenuUp" then return "MenuLeft" end
	if button == "MenuDown" then return "MenuRight" end
	return button
end

local function reset_browse_focus()
	active_index = 3
	list_selected = false
	lobby_view = "lobbies"
end

-- Joined-room lifecycle
-- -----------------------------------------------------------------------

local function reset_joined_lobby_state()
	clear_pack_choice_recovery()
	joined_active_index = 1
		joined_is_manager = false
		joined_phase = nil
		joined_local_returned_to_lobby_after_results = false
		joined_lobby_code = ""
	joined_lobby_players = {}
	joined_player_index = 1
	joined_players_selected = false
	joined_manager_user_id = nil
	joined_song_preview = nil
	joined_song_confirmed = false
	joined_song_selected_key = ""
	joined_missing_song = false
	joined_missing_song_info = nil
	joined_can_download_pack = false
	joined_missing_song_reason = nil
	joined_preview_unknown_pack = false
	lobby_trace_state.joinedPreviewPlaybackKey = ""
	showing_global_options_menu = false
	joined_global_options = { scoreMode="itg", musicRate=1.0 }
	joined_focus_initialized = false
	joined_user_moved_focus = false
end

local function open_leave_confirm(mode_name)
	leave_confirm_mode = mode_name or "leave_lobby"
	leave_confirm_index = 0
	showing_leave_confirm = true
	lobby_flow_trace("leave_confirm_open mode=" .. tostring(leave_confirm_mode)
		.. " joined_code=" .. tostring(joined_lobby_code)
		.. " currentRoomId=" .. tostring(ITGOnline and ITGOnline.currentRoomId or "nil")
		.. " leaving=" .. tostring(leaving_lobby == true)
		.. " joined_phase=" .. tostring(joined_phase))
	if t then
		local prompt = t:GetChild("LeaveConfirmPrompt")
		if prompt then
			prompt:visible(true)
			prompt:playcommand("SyncMode")
			prompt:playcommand("Hover")
		end
	end
end

local function close_leave_confirm()
	lobby_flow_trace("leave_confirm_close mode=" .. tostring(leave_confirm_mode)
		.. " index=" .. tostring(leave_confirm_index)
		.. " joined_code=" .. tostring(joined_lobby_code)
		.. " currentRoomId=" .. tostring(ITGOnline and ITGOnline.currentRoomId or "nil")
		.. " leaving=" .. tostring(leaving_lobby == true))
	showing_leave_confirm = false
	if t then
		local prompt = t:GetChild("LeaveConfirmPrompt")
		if prompt then prompt:visible(false) end
	end
end

local function close_transient_joined_ui()
	if showing_pack_choice_menu
		and ITGOnline
		and ITGOnline.PackSync
		and ITGOnline.PackSync.CancelPendingPackChoice then
		ITGOnline.PackSync:CancelPendingPackChoice("transient_ui_closed")
		clear_pack_choice_recovery()
	end
	close_leave_confirm()
	showing_player_action_menu = false
	player_action_user = nil
	player_action_options = {}
	showing_transfer_manager_confirm = false
	transfer_manager_confirm_index = 0
	transfer_manager_confirm_user = nil
	transfer_manager_confirm_action = "transfer_manager"
	showing_private_join_prompt = false
	private_join_request = nil
	showing_pack_choice_menu = false
	pack_choice_candidates = {}
	pack_choice_song_info = nil
	pack_choice_message = nil
	showing_browse_pack_download_confirm = false
	browse_pack_download_song_info = nil
	showing_global_options_menu = false
	joined_players_selected = false

	if not t then return end
	local names = {
		"PlayerActionMenu",
		"TransferManagerConfirmPrompt",
		"PrivateJoinPrompt",
		"PackChoiceMenu",
		"BrowsePackDownloadConfirmPrompt",
		"GlobalOptionsMenu",
		"LeaveConfirmPrompt",
	}
	for _, name in ipairs(names) do
		local child = t:GetChild(name)
		if child then child:visible(false) end
	end
end

local function stop_lobby_overlay_timers(root)
	if not root then
		lobby_flow_trace("stop_lobby_overlay_timers skipped reason=no_root")
		return
	end
	lobby_flow_trace("stop_lobby_overlay_timers begin")
	local timerNames = {
		"JoinTimeoutTimer",
		"CreateTimeoutTimer",
		"NetworkStatusClearTimer",
		"LobbySearchStabilizationTimer",
	}
	for _, name in ipairs(timerNames) do
		local timer = root:GetChild(name)
		if timer then
			lobby_flow_trace("stop_lobby_overlay_timer name=" .. tostring(name))
			timer:stoptweening()
		else
			lobby_flow_trace("stop_lobby_overlay_timer_missing name=" .. tostring(name))
		end
	end
	lobby_search_ui_pending = false
	network_status_clear_at = 0
	lobby_flow_trace("stop_lobby_overlay_timers end pending=false network_status_clear_at=0")
end

local function current_joined_room_phase()
	local phase = normalized_online_phase(joined_phase)
	if phase == "" and ITGOnline and ITGOnline.currentRoom then
		phase = normalized_online_phase(ITGOnline.currentRoom.phase)
	end
	return phase
end

local function joined_room_phase_allows_manual_leave()
	local phase = current_joined_room_phase()
	if phase ~= "starting" and phase ~= "playing" then
		return true
	end

	local playState = ""
	if ITGOnline and ITGOnline.CurrentUserPlayState then
		playState = tostring(ITGOnline:CurrentUserPlayState(ITGOnline.currentRoom) or "")
	end
	local localTerminal = ITGOnline
		and ITGOnline.IsTerminalPlayState
		and ITGOnline:IsTerminalPlayState(playState)
	lobby_flow_trace("manual_leave_phase_guard"
		.. " phase=" .. tostring(phase)
		.. " playState=" .. tostring(playState)
		.. " localTerminal=" .. tostring(localTerminal == true)
		.. " joined_code=" .. tostring(joined_lobby_code)
		.. " currentRoomId=" .. tostring(ITGOnline and ITGOnline.currentRoomId or "nil"))
	return localTerminal == true
end

local function restore_joined_after_blocked_leave(root, reason, message)
	lobby_flow_trace("restore_joined_after_blocked_leave reason=" .. tostring(reason or "unknown")
		.. " phase=" .. tostring(current_joined_room_phase())
		.. " joined_code=" .. tostring(joined_lobby_code)
		.. " currentRoomId=" .. tostring(ITGOnline and ITGOnline.currentRoomId or "nil")
		.. " leaving_lobby=" .. tostring(leaving_lobby == true))
	leaving_lobby = false
	showing_leave_confirm = false
	input_quiet_until = GetTimeSinceStart() + 0.15
	mode = "joined"
	list_selected = false
	reset_browse_focus()
	if root then
		local joinedContent = root:GetChild("JoinedLobbyContent")
		if joinedContent then joinedContent:visible(true) end
		local lobbyContent = root:GetChild("LobbyContent")
		if lobbyContent then lobbyContent:visible(false) end
		local onlinePlayersContent = root:GetChild("OnlinePlayersContent")
		if onlinePlayersContent then onlinePlayersContent:visible(false) end
		root:playcommand("SetStatus", {
			text=message or "La manche se termine. Sortie disponible apres les resultats.",
			showSpinner=false,
			showPrompt=false,
			duration=2.0
		})
		request_lobby_ui_repaint(root, "blocked_leave_restore")
		root:queuecommand("UpdateJoinedLobbyText")
	end
	if ITGOnline and ITGOnline.FetchRoom and ITGOnline.LobbyStatePayload then
		ITGOnline:FetchRoom(nil, function(ok, decoded)
			lobby_flow_trace("restore_joined_after_blocked_leave_fetch_result ok=" .. tostring(ok == true)
				.. " hasRoom=" .. tostring(decoded and decoded.room ~= nil)
				.. " phase=" .. tostring(decoded and decoded.room and decoded.room.phase or "nil"))
			if ok and decoded and decoded.room and is_active_lobby_overlay() then
				MESSAGEMAN:Broadcast("OnlineLobbyState", ITGOnline:LobbyStatePayload(decoded.room))
			end
		end)
	end
end

	local function begin_leave_lobby(root)
		if leaving_lobby then
			lobby_flow_trace("begin_leave_lobby_skipped reason=already_leaving joined_code=" .. tostring(joined_lobby_code))
			return false
		end
		if not joined_room_phase_allows_manual_leave() then
			lobby_flow_trace("begin_leave_lobby_blocked reason=phase_not_leaveable"
				.. " phase=" .. tostring(current_joined_room_phase())
				.. " joined_code=" .. tostring(joined_lobby_code)
				.. " currentRoomId=" .. tostring(ITGOnline and ITGOnline.currentRoomId or "nil"))
			restore_joined_after_blocked_leave(root, "phase_not_leaveable")
			return false
		end
		SL.Global.Online.ScreenOnlineLobbiesLeaveRequestCode = tostring(joined_lobby_code or "")
		SL.Global.Online.ScreenOnlineLobbiesLeaveRequestRoomId = tostring(ITGOnline and ITGOnline.currentRoomId or "")
		SL.Global.Online.ScreenOnlineLobbiesLeaveRequestGeneration =
			(tonumber(SL.Global.Online.ScreenOnlineLobbiesLeaveRequestGeneration) or 0) + 1
		SL.Global.Online.ScreenOnlineLobbiesLeaveWatchdogCount = 0
		lobby_flow_trace(
			"begin_leave_lobby mode=" .. tostring(leave_confirm_mode) ..
			" joined_code=" .. tostring(joined_lobby_code) ..
			" request_code=" .. tostring(SL.Global.Online.ScreenOnlineLobbiesLeaveRequestCode) ..
			" request_room_id=" .. tostring(SL.Global.Online.ScreenOnlineLobbiesLeaveRequestRoomId) ..
			" generation=" .. tostring(SL.Global.Online.ScreenOnlineLobbiesLeaveRequestGeneration) ..
			" phase=" .. tostring(joined_phase) ..
			" has_root=" .. tostring(root ~= nil))
		leaving_lobby = true
		input_quiet_until = GetTimeSinceStart() + 0.35
		mode = "browse"
	list_selected = false
	reset_browse_focus()
	close_transient_joined_ui()
		if root then
			local joinedContent = root:GetChild("JoinedLobbyContent")
			if joinedContent then joinedContent:visible(false) end
			request_lobby_ui_repaint(root, "begin_leave_lobby")
			root:sleep(4.0):queuecommand("LeaveLobbyWatchdog")
			root:playcommand("SetStatus", {
				text=online_lobby_text("LeavingLobby", "Leaving lobby..."),
				showSpinner=true,
				showPrompt=false
			})
		end
		lobby_flow_trace("begin_leave_lobby_end joined_code=" .. tostring(joined_lobby_code))
		return true
	end

	local function finish_leave_lobby(root, requestedLobbyCode)
		local now = GetTimeSinceStart()
		local departed_lobby_code = tostring(requestedLobbyCode or SL.Global.Online.ScreenOnlineLobbiesLeaveRequestCode or joined_lobby_code or "")
		SL.Global.Online = SL.Global.Online or {}
		local lastFinishedAt = tonumber(SL.Global.Online.ScreenOnlineLobbiesLeaveFinishedAt) or -999
		if now - lastFinishedAt < 0.5 then
			lobby_flow_trace(
				"finish_leave_lobby_skipped reason=dedupe delta=" ..
				string.format("%.3f", now - lastFinishedAt))
			return
		end
		lobby_flow_trace(
			"finish_leave_lobby_begin joined_code=" .. tostring(joined_lobby_code) ..
			" request_code=" .. tostring(SL.Global.Online.ScreenOnlineLobbiesLeaveRequestCode) ..
			" departed_code=" .. tostring(departed_lobby_code) ..
			" phase=" .. tostring(joined_phase) ..
			" players=" .. tostring(type(joined_lobby_players) == "table" and #joined_lobby_players or 0) ..
			" leaving_lobby=" .. tostring(leaving_lobby) ..
			" has_root=" .. tostring(root ~= nil))
		SL.Global.Online.ScreenOnlineLobbiesLeaveFinishedAt = now
		input_quiet_until = now + 0.12
		leaving_lobby = false
		SL.Global.Online.ScreenOnlineLobbiesLeaveRequestCode = nil
		SL.Global.Online.ScreenOnlineLobbiesLeaveRequestRoomId = nil
		SL.Global.Online.ScreenOnlineLobbiesLeaveWatchdogCount = 0
	mode = "browse"
	list_selected = false
	holding.MenuLeft = false
	holding.MenuRight = false
	reset_browse_focus()
		clear_pending_join()
		clear_pending_create()
		stop_lobby_overlay_timers(root)
		close_transient_joined_ui()
		reset_joined_lobby_state()
		if ITGOnline and ITGOnline.PackSync and ITGOnline.PackSync.ResetLocalState then
			lobby_flow_trace("finish_leave_lobby_packsync_reset_begin")
			ITGOnline.PackSync:ResetLocalState("lobby_left")
			lobby_flow_trace("finish_leave_lobby_packsync_reset_end")
		end
		mark_recently_left_lobby_code(departed_lobby_code, "finish_leave_lobby")
		if root then
			lobby_flow_trace("finish_leave_lobby_ui_update_begin")
			local joinedContent = root:GetChild("JoinedLobbyContent")
			if joinedContent then joinedContent:visible(false) end
			if ScreenOnlineLobbiesRemoveLobbyCandidateByCode(departed_lobby_code) then
				lobby_flow_trace("finish_leave_lobby_removed_stale_candidate code=" .. tostring(departed_lobby_code))
			end
			request_lobby_ui_repaint(root, "finish_leave_lobby")
			lobby_flow_trace("finish_leave_lobby_refresh_requested reason=post_room_exit")
			request_lobby_refresh("overlay_finish_leave_lobby", {
				immediate = true,
				forceFresh = true,
				ignoreSuppression = true,
			}, root)
		local status = root:GetChild("NetworkStatus")
		if status then status:visible(false) end
		lobby_flow_trace("finish_leave_lobby_status_suppressed message=Salon quitte.")
			root:playcommand("Hover")
			lobby_flow_trace("finish_leave_lobby_ui_update_end")
		end
		lobby_flow_trace("finish_leave_lobby_end")
	end

	local function leave_lobby_stabilization_remaining()
		SL.Global.Online = SL.Global.Online or {}
		local lastFinishedAt = tonumber(SL.Global.Online.ScreenOnlineLobbiesLeaveFinishedAt) or -999
		local elapsed = GetTimeSinceStart() - lastFinishedAt
		return math.max(0, 0.15 - elapsed)
	end

	local function recently_left_lobby(seconds)
		SL.Global.Online = SL.Global.Online or {}
		local lastFinishedAt = tonumber(SL.Global.Online.ScreenOnlineLobbiesLeaveFinishedAt) or -999
		return GetTimeSinceStart() - lastFinishedAt < (tonumber(seconds) or 4.0)
	end

	request_lobby_refresh = function(reason, options, root)
		local source = tostring(reason or "unknown")
		options = type(options) == "table" and options or {}
		local hasScheduler = ITGOnline
			and ITGOnline.HasLobbyRefreshScheduler
			and ITGOnline:HasLobbyRefreshScheduler()
		if hasScheduler then
			lobby_flow_trace("request_lobby_refresh delegated=client reason=" .. source
				.. " immediate=" .. tostring(options.immediate == true)
				.. " delay=" .. tostring(options.delay or "nil"))
			return ITGOnline:RequestLobbyRefresh(source, options)
		end

		if root and options.retryLegacy ~= true then
			SL.Global.Online = SL.Global.Online or {}
			local previousPending = SL.Global.Online.ScreenOnlineLobbiesPendingRefresh
			local previousOptions = type(previousPending) == "table" and type(previousPending.options) == "table"
				and previousPending.options or {}
			local previousDelay = tonumber(previousOptions.delay)
			local nextDelay = tonumber(options.delay)
			local mergedDelay = nextDelay
			if previousDelay and nextDelay then
				mergedDelay = math.min(previousDelay, nextDelay)
			elseif previousDelay then
				mergedDelay = previousDelay
			end
			local mergedReason = source
			if type(previousPending) == "table"
				and tostring(previousPending.reason or "") ~= ""
				and tostring(previousPending.reason or "") ~= source then
				mergedReason = tostring(previousPending.reason) .. "+" .. source
			end
			SL.Global.Online.ScreenOnlineLobbiesPendingRefresh = {
				reason = mergedReason,
				options = {
					immediate = previousOptions.immediate == true or options.immediate == true,
					delay = mergedDelay,
					retryLegacy = true,
				},
			}
			lobby_flow_trace("request_lobby_refresh retry_before_legacy reason=" .. source
				.. " mergedReason=" .. tostring(mergedReason)
				.. " mergedImmediate=" .. tostring(previousOptions.immediate == true or options.immediate == true)
				.. " mergedDelay=" .. tostring(mergedDelay or "nil")
				.. " hasITGOnline=" .. tostring(ITGOnline ~= nil)
				.. " hasSchedulerContract=" .. tostring(ITGOnline and ITGOnline.HasLobbyRefreshScheduler ~= nil))
			if SL.Global.Online.ScreenOnlineLobbiesPendingRefreshRetryScheduled == true then
				lobby_flow_trace("request_lobby_refresh_retry_already_scheduled reason=" .. source)
				return true
			end
			SL.Global.Online.ScreenOnlineLobbiesPendingRefreshRetryScheduled = true
			root:sleep(0.10):queuecommand("RetryLobbyRefresh")
			return true
		end

		lobby_flow_trace("request_lobby_refresh delegated=legacy_event reason=" .. source
			.. " hasITGOnline=" .. tostring(ITGOnline ~= nil)
			.. " hasSchedulerContract=" .. tostring(ITGOnline and ITGOnline.HasLobbyRefreshScheduler ~= nil)
			.. " immediate=" .. tostring(options.immediate == true)
			.. " delay=" .. tostring(options.delay or "nil"))
		MESSAGEMAN:Broadcast("SearchLobby", {
			reason = source,
			force = options.immediate == true,
			minInterval = options.immediate == true and 0 or nil,
		})
		return true
	end

	local function refresh_joined_room_snapshot(reason, root)
		local source = tostring(reason or "unknown")
		local roomId = ITGOnline and ITGOnline.currentRoomId or nil
		if ITGOnline and ITGOnline.FetchRoom and roomId then
			lobby_flow_trace("joined_room_snapshot_refresh_begin reason=" .. source
				.. " room=" .. tostring(roomId)
				.. " phase=" .. tostring(joined_phase)
				.. " hasPreview=" .. tostring(joined_song_preview ~= nil))
			ITGOnline:FetchRoom(roomId, function(ok, decoded)
				lobby_flow_trace("joined_room_snapshot_refresh_result reason=" .. source
					.. " ok=" .. tostring(ok == true)
					.. " hasRoom=" .. tostring(decoded and decoded.room ~= nil)
					.. " room=" .. tostring(decoded and decoded.room and decoded.room.id or "nil")
					.. " phase=" .. tostring(decoded and decoded.room and decoded.room.phase or "nil")
					.. " hasSong=" .. tostring(decoded and decoded.room and decoded.room.selected_song ~= nil))
				if ok and decoded and decoded.room and ITGOnline and ITGOnline.LobbyStatePayload then
					MESSAGEMAN:Broadcast("OnlineLobbyState", ITGOnline:LobbyStatePayload(decoded.room))
				elseif root then
					request_lobby_refresh(source .. "_fallback", { immediate=true, delay=0 }, root)
				end
			end)
			return true
		end

		lobby_flow_trace("joined_room_snapshot_refresh_fallback reason=" .. source
			.. " hasClient=" .. tostring(ITGOnline ~= nil)
			.. " hasFetch=" .. tostring(ITGOnline and ITGOnline.FetchRoom ~= nil)
			.. " room=" .. tostring(roomId or "nil"))
		return request_lobby_refresh(source .. "_fallback", { immediate=true, delay=0 }, root)
	end

	local function schedule_lobby_search_ui_apply(root, delay, reason)
		if not root then return false end
		local timer = root:GetChild("LobbySearchStabilizationTimer")
		if not timer then
			lobby_flow_trace("lobby_search_ui_defer_failed reason=no_timer source=" .. tostring(reason or "unknown"))
			return false
		end
		lobby_search_ui_pending = true
		timer:stoptweening()
		timer:sleep(math.max(0.05, tonumber(delay) or 0.05))
		timer:queuecommand("Apply")
		lobby_flow_trace(
			"lobby_search_ui_deferred delay=" .. tostring(delay) ..
			" reason=" .. tostring(reason or "unknown"))
		return true
	end

	local function queue_lobby_ui_update(root, reason)
		if not root then return false end
		local source = tostring(reason or "unknown")
		local recentLeaveFinish = SL.Global and SL.Global.Online
			and tonumber(SL.Global.Online.ScreenOnlineLobbiesLeaveFinishedAt)
			and (GetTimeSinceStart() - tonumber(SL.Global.Online.ScreenOnlineLobbiesLeaveFinishedAt)) <= 0.75
		local forceImmediate = source == "finish_leave_lobby"
			or (recentLeaveFinish and source:find("lobby_search:", 1, true) ~= nil)
		if forceImmediate then
			lobby_ui_update_pending = false
			lobby_ui_update_reason = ""
			local timer = root:GetChild("LobbyUiUpdateTimer")
			if timer then timer:stoptweening() end
			lobby_flow_trace("lobby_ui_update_apply_now reason=" .. source
				.. " mode=" .. tostring(mode)
				.. " candidates=" .. tostring(type(candidates) == "table" and #candidates or 0)
				.. " onlinePlayers=" .. tostring(type(online_users) == "table" and #online_users or 0)
				.. " joinedCode=" .. tostring(joined_lobby_code or "")
				.. " currentRoomId=" .. tostring(ITGOnline and ITGOnline.currentRoomId or "nil"))
			root:playcommand("UpdateLobbyView")
			root:playcommand("Hover")
			return true
		end

		if lobby_ui_update_pending then
			lobby_flow_trace(
				"lobby_ui_update_coalesced reason=" .. source ..
				" pendingReason=" .. tostring(lobby_ui_update_reason)
				.. " mode=" .. tostring(mode)
				.. " candidates=" .. tostring(type(candidates) == "table" and #candidates or 0)
				.. " onlinePlayers=" .. tostring(type(online_users) == "table" and #online_users or 0)
				.. " joinedCode=" .. tostring(joined_lobby_code or "")
				.. " currentRoomId=" .. tostring(ITGOnline and ITGOnline.currentRoomId or "nil"))
			return true
		end

		lobby_ui_update_pending = true
		lobby_ui_update_reason = source
		local timer = root:GetChild("LobbyUiUpdateTimer")
		if timer then
			timer:stoptweening()
			timer:sleep(0.02)
			timer:queuecommand("Apply")
		else
			root:queuecommand("ApplyQueuedLobbyUiUpdate")
		end
		lobby_flow_trace("lobby_ui_update_queued reason=" .. source
			.. " mode=" .. tostring(mode)
			.. " candidates=" .. tostring(type(candidates) == "table" and #candidates or 0)
			.. " onlinePlayers=" .. tostring(type(online_users) == "table" and #online_users or 0)
			.. " joinedCode=" .. tostring(joined_lobby_code or "")
			.. " currentRoomId=" .. tostring(ITGOnline and ITGOnline.currentRoomId or "nil"))
		return true
	end

	request_lobby_ui_repaint = function(root, reason)
		lobby_flow_trace("lobby_ui_repaint_requested reason=" .. tostring(reason or "unknown")
			.. " hasRoot=" .. tostring(root ~= nil)
			.. " mode=" .. tostring(mode)
			.. " listSelected=" .. tostring(list_selected == true)
			.. " lobbyView=" .. tostring(lobby_view)
			.. " activeIndex=" .. tostring(active_index)
			.. " candidates=" .. tostring(type(candidates) == "table" and #candidates or 0)
			.. " onlinePlayers=" .. tostring(type(online_users) == "table" and #online_users or 0))
		return queue_lobby_ui_update(root, "repaint:" .. tostring(reason or "unknown"))
	end

	local function apply_lobby_search_to_ui(root, reason)
		if not root or not is_active_lobby_overlay() then
			lobby_flow_trace("lobby_search_ui_skipped reason=inactive source=" .. tostring(reason or "unknown"))
			return false
		end

		local remaining = leave_lobby_stabilization_remaining()
		if remaining > 0 then
			schedule_lobby_search_ui_apply(root, remaining + 0.05, "leave_stabilizing")
			return false
		end

		lobby_search_ui_pending = false
		lobby_flow_trace(
			"lobby_search_ui_apply_begin source=" .. tostring(reason or "unknown") ..
			" lobbies=" .. tostring(type(candidates) == "table" and #candidates or 0) ..
			" onlineUsers=" .. tostring(type(online_users) == "table" and #online_users or 0) ..
			" mode=" .. tostring(mode))

		local lobbyContent = root:GetChild("LobbyContent")
		if lobbyContent then
			local lobbyList = lobbyContent:GetChild("LobbyList")
			if lobbyList then
				lobbyList:playcommand("UpdateData", {data=candidates})
				if list_selected and lobby_view == "lobbies" and lobbyList.hasSelectableRoom ~= true then
					list_selected = false
					lobbyList:playcommand("LoseFocus")
					lobby_flow_trace("lobby_search_focus_released reason=no_selectable_room")
				end
			end

			local emptyText = lobbyContent:GetChild("EmptyStateText")
			if emptyText then
				emptyText:visible(#candidates == 0)
			end
		end

		if not pack_sync_busy() then
			hide_network_status_if_idle(root)
		end
		local joinedContent = root:GetChild("JoinedLobbyContent")
		if joinedContent then joinedContent:visible(mode == "joined") end
		request_lobby_ui_repaint(root, "lobby_search:" .. tostring(reason or "unknown"))
		lobby_flow_trace("lobby_search_ui_apply_end source=" .. tostring(reason or "unknown"))
		return true
	end

function duplicate_first_press(event)
	if not event or event.type ~= "InputEventType_FirstPress" then
		return false
	end
	local now = GetTimeSinceStart()
	local key = tostring(event.GameButton or "") .. "|" .. tostring(event.PlayerNumber or "")
	SL.Global.Online = SL.Global.Online or {}
	local dedup = SL.Global.Online.ScreenOnlineLobbiesInputDedup
	if type(dedup) ~= "table" then
		dedup = { key = "", at = 0 }
		SL.Global.Online.ScreenOnlineLobbiesInputDedup = dedup
	end
	if dedup.key == key and now - (tonumber(dedup.at) or 0) < 0.12 then
		return true
	end
	dedup.key = key
	dedup.at = now
	return false
end

function focus_selected_browse_list(root)
	if not root then return end
	if lobby_view == "players" then
		local players = root:GetChild("OnlinePlayersContent")
		local border = players and players:GetChild("OnlinePlayersBorder")
		if border then border:playcommand("GainFocus") end
	else
		local lobby = root:GetChild("LobbyContent")
		local list = lobby and lobby:GetChild("LobbyList")
		if list then list:playcommand("GainFocus") end
	end
end

function lobby_debug_enabled()
	return type(online_logs_enabled) == "function" and online_logs_enabled() == true
end

function lobby_debug(message)
	if not lobby_debug_enabled() then return end
	if type(online_trace) == "function" then
		online_trace("lobby " .. tostring(message or ""))
	end
end

lobby_flow_trace = function(message)
		if type(online_logs_enabled) == "function" and not online_logs_enabled() then
			return
		end
		local normalizedMessage = tostring(message or "")
		if lobby_trace_state.seen[normalizedMessage] then
			return
		end
		lobby_trace_state.seen[normalizedMessage] = true
		lobby_trace_state.order[#lobby_trace_state.order + 1] = normalizedMessage
		if #lobby_trace_state.order > lobby_trace_state.maxSignatures then
			local oldest = table.remove(lobby_trace_state.order, 1)
			lobby_trace_state.seen[oldest] = nil
		end
		if type(online_flow_trace) == "function" then
			online_flow_trace("lobby_ui " .. normalizedMessage)
		end
end

function lobby_count(value)
	return type(value) == "table" and #value or 0
end

-- Lobby and player presentation
-- -----------------------------------------------------------------------

local function lobby_local_user_id()
	if ITGOnline and ITGOnline.LocalUserId then
		local ok, id = pcall(function() return ITGOnline:LocalUserId() end)
		if ok and id ~= nil and tostring(id) ~= "" then return tostring(id) end
	end
	return tostring(ITGOnline and ITGOnline.user and ITGOnline.user.id or "")
end

local function lobby_player_user_id(player)
	player = type(player) == "table" and player or {}
	local user = type(player.user) == "table" and player.user or {}
	return tostring(player.user_id or player.userId or player.playerId or player.id or user.id or "")
end

local function apply_optimistic_config_ready_to_players(players, room, source)
	if not (ITGOnline and ITGOnline.CurrentUserHasOptimisticConfigReady and ITGOnline:CurrentUserHasOptimisticConfigReady(room)) then
		return players
	end
	if tostring(room and room.phase or "") ~= "config" then return players end
	local localUserId = lobby_local_user_id()
	if localUserId == "" then return players end
	local applied = false
	for _, player in ipairs(players or {}) do
		if type(player) == "table" and lobby_player_user_id(player) == localUserId then
			if player.ready ~= true and player.is_ready ~= true then
				player.ready = true
				player.is_ready = true
				player.readyPendingServer = true
				applied = true
			end
			break
		end
	end
	if applied then
		lobby_flow_trace("optimistic_config_ready_applied_to_players"
			.. " source=" .. tostring(source or "unknown")
			.. " userId=" .. tostring(localUserId)
			.. " room=" .. tostring(room and (room.id or room.room_id) or "nil")
			.. " phase=" .. tostring(room and room.phase or "nil"))
	end
	return players
end

function lobby_room_summary(prefix, params)
	params = type(params) == "table" and params or {}
	local players = params.players or params.members or {}
	local readyStates = params.readyStates or params.ready_states or {}
	local payloadSong = params.songInfo
		or params.song_info
		or params.songPreview
		or params.song_preview
		or params.selectedSong
		or params.selected_song
		or params.song
		or {}
	local readyParts = {}
	local readyPlayers = 0
	for _, player in pairs(players or {}) do
		if type(player) == "table" then
			local ready = player.ready == true or player.is_ready == true
			if ready then readyPlayers = readyPlayers + 1 end
			readyParts[#readyParts + 1] = tostring(player.profileName or player.name or player.displayName or player.playerId or "?")
				.. ":" .. tostring(player.playerId or player.id or player.user_id or "?")
				.. "=" .. tostring(ready and "1" or player.readyPendingServer and "pending" or "0")
		end
	end
	local rawReadyStatesCount = lobby_count(readyStates)
	local effectiveReadyStatesCount = rawReadyStatesCount > 0 and rawReadyStatesCount or readyPlayers
	local readyStatesSource = rawReadyStatesCount > 0 and "payload_ready_states" or "players_ready_flags"
	local payloadSongPresent = type(payloadSong) == "table" and next(payloadSong) ~= nil
	local uiPreviewPresent = type(joined_song_preview) == "table" and next(joined_song_preview) ~= nil
	local songTitle = payloadSong.title
		or payloadSong.name
		or payloadSong.folder_name
		or payloadSong.song_hash
		or (joined_song_preview and (joined_song_preview.title or joined_song_preview.name or joined_song_preview.folder_name or joined_song_preview.song_hash))
		or "none"
	local songConfirmedFlag = params.songConfirmed == true
		or params.song_confirmed == true
		or payloadSongPresent
	lobby_flow_trace(tostring(prefix or "room_state")
		.. " mode=" .. tostring(mode)
		.. " joined_code=" .. tostring(joined_lobby_code)
		.. " params_code=" .. tostring(params.code or params.roomCode or params.room_id or params.id or "")
		.. " currentRoomId=" .. tostring(ITGOnline and ITGOnline.currentRoomId or "nil")
		.. " phase=" .. tostring(params.phase or params.roomPhase or "")
		.. " players=" .. tostring(lobby_count(players))
		.. " readyStatesRaw=" .. tostring(rawReadyStatesCount)
		.. " readyStatesEffective=" .. tostring(effectiveReadyStatesCount)
		.. " readyStatesSource=" .. tostring(readyStatesSource)
		.. " readyPlayers=" .. tostring(readyPlayers) .. "/" .. tostring(lobby_count(players))
		.. " ready={" .. table.concat(readyParts, ",") .. "}"
		.. " payloadSongPresent=" .. tostring(payloadSongPresent == true)
		.. " uiPreviewPresent=" .. tostring(uiPreviewPresent == true)
		.. " songConfirmedFlag=" .. tostring(songConfirmedFlag == true)
		.. " currentJoinedSongConfirmed=" .. tostring(joined_song_confirmed == true)
		.. " songTitle=" .. tostring(songTitle)
		.. " leaving=" .. tostring(leaving_lobby == true)
		.. " screenGeneration=" .. tostring(ITGOnline and ITGOnline.screenGeneration or "nil"))
end

function ready_summary()
	local parts = {}
	for _, player in pairs(joined_lobby_players or {}) do
		if type(player) == "table" then
			parts[#parts + 1] = tostring(player.profileName or "?")
				.. ":" .. tostring(player.playerId or "?")
				.. "=" .. tostring(player.ready and "1" or player.readyPendingServer and "pending" or "0")
		end
	end
	return table.concat(parts, ",")
end

function normalize_global_options(options)
	options = type(options) == "table" and options or {}
	local scoreMode = tostring(options.scoreMode or options.score_mode or "itg"):lower()
	if scoreMode ~= "ex" and scoreMode ~= "hardex" then
		scoreMode = "itg"
	end
	local musicRate = tonumber(options.musicRate or options.music_rate) or 1.0
	musicRate = math.max(0.25, math.min(3.0, musicRate))
	return { scoreMode=scoreMode, score_mode=scoreMode, musicRate=musicRate, music_rate=musicRate }
end

function global_score_label(mode)
	mode = tostring(mode or "itg"):lower()
	if mode == "hardex" then return "HardEX" end
	if mode == "ex" then return "EX" end
	return "ITG"
end

function global_options_mode_label()
	local options = normalize_global_options(joined_global_options)
	return "(" .. global_score_label(options.scoreMode) .. "/" .. string.format("%.2f", options.musicRate) .. ")"
end

function rebuild_global_options_choices()
	global_options_choices = {
		{ label=online_lobby_text("ScoreOption", "Score: %s", "ITG"), scoreMode="itg" },
		{ label=online_lobby_text("ScoreOption", "Score: %s", "EX"), scoreMode="ex" },
		{ label=online_lobby_text("ScoreOption", "Score: %s", "HardEX"), scoreMode="hardex" },
		{ label=online_lobby_text("RateOption", "Rate: %s", "0.75x"), musicRate=0.75 },
		{ label=online_lobby_text("RateOption", "Rate: %s", "1.00x"), musicRate=1.0 },
		{ label=online_lobby_text("RateOption", "Rate: %s", "1.10x"), musicRate=1.1 },
		{ label=online_lobby_text("RateOption", "Rate: %s", "1.20x"), musicRate=1.2 },
		{ label=online_lobby_text("RateOption", "Rate: %s", "1.50x"), musicRate=1.5 },
	}
	global_options_index = math.min(math.max(1, global_options_index), #global_options_choices)
end

function select_current_global_score_choice()
	local current = normalize_global_options(joined_global_options)
	for i, choice in ipairs(global_options_choices) do
		if choice.scoreMode and choice.scoreMode == current.scoreMode then
			global_options_index = i
			return
		end
	end
	global_options_index = math.min(math.max(1, global_options_index), #global_options_choices)
end

function open_global_options_menu()
	lobby_flow_trace("open_global_options_menu"
		.. " joined_code=" .. tostring(joined_lobby_code)
		.. " phase=" .. tostring(joined_phase)
		.. " isManager=" .. tostring(joined_is_manager == true)
		.. " currentScoreMode=" .. tostring(joined_global_options and joined_global_options.scoreMode or "nil")
		.. " currentRate=" .. tostring(joined_global_options and joined_global_options.musicRate or "nil"))
	rebuild_global_options_choices()
	select_current_global_score_choice()
	showing_global_options_menu = true
	if t then
		local menu = t:GetChild("GlobalOptionsMenu")
		if menu then menu:visible(true) end
		t:queuecommand("UpdateGlobalOptionsMenu")
	end
end

function close_global_options_menu()
	showing_global_options_menu = false
	if t then
		local menu = t:GetChild("GlobalOptionsMenu")
		if menu then menu:visible(false) end
	end
end

function move_global_options_choice(delta)
	if #global_options_choices == 0 then rebuild_global_options_choices() end
	global_options_index = global_options_index + delta
	if global_options_index < 1 then global_options_index = #global_options_choices end
	if global_options_index > #global_options_choices then global_options_index = 1 end
	if t then t:queuecommand("UpdateGlobalOptionsMenu") end
end

function apply_global_options_choice()
	local choice = global_options_choices[global_options_index]
	lobby_flow_trace("apply_global_options_choice_begin"
		.. " index=" .. tostring(global_options_index)
		.. " hasChoice=" .. tostring(choice ~= nil)
		.. " joined_code=" .. tostring(joined_lobby_code)
		.. " phase=" .. tostring(joined_phase)
		.. " isManager=" .. tostring(joined_is_manager == true))
	if ITGOnline and ITGOnline.TraceOnlineState then
		ITGOnline:TraceOnlineState("ui_global_options_apply_begin", {
			source = "ScreenOnlineLobbies",
			optionIndex = global_options_index,
			hasChoice = choice ~= nil,
			joinedCode = joined_lobby_code,
			joinedPhase = joined_phase,
			isManager = joined_is_manager == true,
		})
	end
	if not choice or not ITGOnline or not ITGOnline.UpdateGlobalOptions then
		lobby_flow_trace("apply_global_options_choice_skipped reason=missing_context")
		return
	end
	local current = normalize_global_options(joined_global_options)
	local payload = {
		score_mode = choice.scoreMode or current.scoreMode,
		music_rate = choice.musicRate or current.musicRate,
	}
	ITGOnline:UpdateGlobalOptions(payload, function(ok)
		if ITGOnline and ITGOnline.TraceOnlineState then
			ITGOnline:TraceOnlineState("ui_global_options_apply_response", {
				source = "ScreenOnlineLobbies",
				ok = ok == true,
				scoreMode = payload.score_mode or "",
				musicRate = payload.music_rate or "",
				joinedCode = joined_lobby_code,
			})
		end
		lobby_flow_trace("apply_global_options_choice_response ok=" .. tostring(ok == true)
			.. " scoreMode=" .. tostring(payload.score_mode or "")
			.. " musicRate=" .. tostring(payload.music_rate or "")
			.. " joined_code=" .. tostring(joined_lobby_code))
		if ok then
			joined_global_options = normalize_global_options(payload)
			close_global_options_menu()
			if t then
				t:queuecommand("UpdateJoinedLobbyText")
				t:queuecommand("Hover")
			end
		end
	end)
end

function text_or_empty(value)
	return tostring(value or "")
end

function trim_text(value)
	return text_or_empty(value):gsub("^%s+", ""):gsub("%s+$", "")
end

function online_utf8_length(value)
	value = text_or_empty(value)
	if value.utf8len then
		local ok, length = pcall(function() return value:utf8len() end)
		if ok and type(length) == "number" then return length end
	end
	return #value
end

function clamp_text(value, maxLen)
	value = text_or_empty(value)
	maxLen = math.max(1, tonumber(maxLen) or 1)
	if online_utf8_length(value) <= maxLen then return value end
	if maxLen <= 1 then return "…" end
	if value.utf8sub then return value:utf8sub(1, maxLen - 1) .. "…" end
	return value:sub(1, maxLen - 1) .. "…"
end

function song_info_path(songInfo)
	return trim_text(songInfo and (songInfo.songPath or songInfo.folder_name or songInfo.folderName or songInfo.path))
end

function song_info_pack(songInfo)
	local pack = trim_text(songInfo and (songInfo.pack or songInfo.group or songInfo.group_name or songInfo.groupName))
	if pack ~= "" then return pack end

	local path = song_info_path(songInfo)
	return trim_text(path:match("^([^/]+)"))
end

function song_info_title(songInfo)
	local title = trim_text(songInfo and (songInfo.title or songInfo.name or songInfo.songName or songInfo.song_title or songInfo.songTitle))
	if title ~= "" then return title end

	local path = song_info_path(songInfo)
	return trim_text(path:match("^[^/]+/(.+)$") or path)
end

function song_info_artist(songInfo)
	return trim_text(songInfo and (songInfo.artist or songInfo.artistName or songInfo.song_artist or songInfo.songArtist))
end

function normalize_online_song_info(songInfo)
	if type(songInfo) ~= "table" then return nil end

	local title = song_info_title(songInfo)
	local artist = song_info_artist(songInfo)
	local pack = song_info_pack(songInfo)
	local path = song_info_path(songInfo)
	if title == "" and artist == "" and pack == "" and path == "" then return nil end

	songInfo.title = title
	songInfo.artist = artist
	songInfo.pack = pack
	if songInfo.songPath == nil or trim_text(songInfo.songPath) == "" then
		songInfo.songPath = path
	end
	return songInfo
end

function find_online_song(songInfo)
	if not SONGMAN or not SONGMAN.FindSong or type(songInfo) ~= "table" then return nil end
	local songPath = song_info_path(songInfo)
	local song = songPath ~= "" and SONGMAN:FindSong(songPath) or nil
	if song then return song end
	local relative = songPath:match("^[^/]+/(.+)$")
	return relative and SONGMAN:FindSong(relative) or nil
end

function update_joined_song_card(joinedContent)
	if not joinedContent then return end
	local roomSongInfo = ITGOnline and ITGOnline.currentRoom and ITGOnline.currentRoom.selected_song or nil
	local songInfo = normalize_online_song_info(joined_missing_song_info or joined_song_preview or roomSongInfo)
	local hasSong = type(songInfo) == "table"
	local card = joinedContent:GetChild("JoinedSongCard")
	if card then card:visible(hasSong) end

	local title = joinedContent:GetChild("JoinedSongTitle")
	if title then
		local titleText = hasSong and song_info_title(songInfo) or ""
		title:visible(hasSong)
		title:settext(hasSong and clamp_text(titleText ~= "" and titleText or online_lobby_text("UnknownSong", "Unknown song"), 58) or "")
	end

	local artist = joinedContent:GetChild("JoinedSongArtist")
	if artist then
		local artistText = hasSong and song_info_artist(songInfo) or ""
		artist:visible(hasSong)
		artist:settext(online_lobby_text("ArtistValue", "Artist: %s",
			artistText ~= "" and clamp_text(artistText, 44) or online_lobby_text("UnknownArtist", "Unknown artist")))
	end

	local pack = joinedContent:GetChild("JoinedSongPack")
	if pack then
		local packText = hasSong and song_info_pack(songInfo) or ""
		pack:visible(hasSong and packText ~= "")
		pack:settext(packText ~= "" and online_lobby_text("PackValue", "Pack: %s", clamp_text(packText, 46)) or "")
	end

	local banner = joinedContent:GetChild("JoinedSongBanner")
	local bannerFallback = joinedContent:GetChild("JoinedSongBannerFallback")
	local bannerLabel = joinedContent:GetChild("JoinedSongBannerLabel")
	local confirmedCheck = joinedContent:GetChild("JoinedSongConfirmedCheck")
	local bannerLoaded = false
	if banner then
		banner:visible(false)
		if hasSong then
			local song = find_online_song(songInfo)
			if song and song.HasBanner and song:HasBanner() and song.GetBannerPath and song:GetBannerPath() then
				banner:LoadFromCachedBanner(song:GetBannerPath())
				banner:visible(true)
				bannerLoaded = true
			end
		end
	end
	if bannerFallback then bannerFallback:visible(hasSong and not bannerLoaded) end
	if bannerLabel then bannerLabel:visible(hasSong and not bannerLoaded) end
	if confirmedCheck then confirmedCheck:visible(hasSong and joined_song_confirmed == true) end
end

function abbreviate_stepchart(value)
	local chart = trim_text(value)
	if chart == "" then return "" end

	chart = chart:gsub("^dance%-single", "DS")
	chart = chart:gsub("^dance%-double", "DD")
	chart = chart:gsub("^dance%-solo", "DSo")
	chart = chart:gsub("^dance%-couple", "DC")
	chart = chart:gsub("^pump%-single", "PS")
	chart = chart:gsub("^pump%-double", "PD")

	chart = chart:gsub("/Beginner", "/Beg")
	chart = chart:gsub("/Easy", "/Ez")
	chart = chart:gsub("/Medium", "/Med")
	chart = chart:gsub("/Hard", "/Hd")
	chart = chart:gsub("/Challenge", "/Chal")
	chart = chart:gsub("/Edit", "/Ed")

	chart = chart:gsub("%s+", " ")
	chart = chart:gsub("%s*/%s*", "/")
	chart = chart:gsub("%s(%d+)$", "%1")

	return chart
end

function pack_sync_display_text(status)
	status = trim_text(status)
	if status == "" or status == "unknown" or status == "idle" then return "" end
	if ITGOnline and ITGOnline.PackSync and ITGOnline.PackSync.DisplayText then
		return ITGOnline.PackSync:DisplayText(status)
	end
	return status:gsub("_", " ")
end

pack_sync_busy = function()
	if not (ITGOnline and ITGOnline.PackSync) then return false end
	if trim_text(ITGOnline.PackSync.downloadInFlightKey) ~= "" then return true end
	if ITGOnline.PackSync.activeBrowseOnlyDownload == true then return true end
	if ITGOnline.PackSync.pendingPostReloadSongInfo ~= nil then return true end
	local status = trim_text(ITGOnline.PackSync.currentStatus)
	return status == "download_requested"
		or status == "download_in_progress"
		or status == "reloading_songs"
		or status == "validating_download"
end

local function lobby_song_selected_at(songInfo)
	return trim_text(songInfo and (songInfo.selectedAt or songInfo.selected_at))
end

local function current_room_selected_song_info()
	return ITGOnline and ITGOnline.currentRoom and ITGOnline.currentRoom.selected_song or nil
end

local function song_info_matches_current_room_selection(songInfo)
	local songSelectedAt = lobby_song_selected_at(songInfo)
	local roomSelectedAt = lobby_song_selected_at(current_room_selected_song_info())
	if songSelectedAt == "" or roomSelectedAt == "" then
		return false
	end
	return songSelectedAt == roomSelectedAt
end

function can_download_browsed_pack()
	local joinedPhase = normalized_online_phase and normalized_online_phase(joined_phase) or tostring(joined_phase or "")
	local roomPhase = ITGOnline and ITGOnline.currentRoom and normalized_online_phase and normalized_online_phase(ITGOnline.currentRoom.phase) or ""
	if joinedPhase == "results" then
		lobby_flow_trace("can_download_browsed_pack false reason=joined_results"
			.. " joinedPhase=" .. tostring(joined_phase)
			.. " roomPhase=" .. tostring(roomPhase))
		return false
	end
	if roomPhase == "results" then
		lobby_flow_trace("can_download_browsed_pack false reason=room_results"
			.. " joinedPhase=" .. tostring(joined_phase)
			.. " roomPhase=" .. tostring(roomPhase))
		return false
	end
	if pack_sync_busy() then
		lobby_flow_trace("can_download_browsed_pack false reason=pack_sync_busy"
			.. " status=" .. tostring(ITGOnline and ITGOnline.PackSync and ITGOnline.PackSync.currentStatus or "nil")
			.. " key=" .. tostring(ITGOnline and ITGOnline.PackSync and ITGOnline.PackSync.downloadInFlightKey or "nil"))
		return false
	end
	local result = joined_preview_unknown_pack
		and not joined_song_confirmed
		and not joined_missing_song
		and joined_song_preview ~= nil
	lobby_flow_trace("can_download_browsed_pack result=" .. tostring(result == true)
		.. " unknownPack=" .. tostring(joined_preview_unknown_pack == true)
		.. " songConfirmed=" .. tostring(joined_song_confirmed == true)
		.. " missingSong=" .. tostring(joined_missing_song == true)
		.. " hasPreview=" .. tostring(joined_song_preview ~= nil)
		.. " packSyncBusy=" .. tostring(pack_sync_busy() == true)
		.. " joinedPhase=" .. tostring(joined_phase)
		.. " roomPhase=" .. tostring(roomPhase))
	return result
end

function show_pack_download_button()
	local joinedPhase = normalized_online_phase and normalized_online_phase(joined_phase) or tostring(joined_phase or "")
	local roomPhase = ITGOnline and ITGOnline.currentRoom and normalized_online_phase and normalized_online_phase(ITGOnline.currentRoom.phase) or ""
	if joinedPhase == "results" then
		lobby_flow_trace("show_pack_download_button false reason=joined_results")
		return false
	end
	if roomPhase == "results" then
		lobby_flow_trace("show_pack_download_button false reason=room_results")
		return false
	end
	local busy = pack_sync_busy()
	local canDownloadBrowse = busy and false or can_download_browsed_pack()
	local result = joined_missing_song or canDownloadBrowse or busy
	lobby_flow_trace("show_pack_download_button result=" .. tostring(result == true)
		.. " missingSong=" .. tostring(joined_missing_song == true)
		.. " canDownloadBrowse=" .. tostring(canDownloadBrowse == true)
		.. " packSyncBusy=" .. tostring(busy == true)
		.. " canDownloadPack=" .. tostring(joined_can_download_pack == true)
		.. " reason=" .. tostring(joined_missing_song_reason or "nil")
		.. " selectedKey=" .. tostring(joined_song_selected_key or "")
		.. " phase=" .. tostring(joined_phase))
	return result
end

function pack_sync_status_for_joined_song()
	if not (ITGOnline and ITGOnline.PackSync) then return "" end
	if not joined_song_confirmed or joined_song_selected_key == "" then return "" end

	local packSync = ITGOnline.PackSync
	local songInfo = packSync.currentSongInfo
	if type(songInfo) ~= "table" then return "" end

	local selectedAt = trim_text(songInfo.selectedAt or songInfo.selected_at)
	if selectedAt == "" or selectedAt ~= joined_song_selected_key then return "" end

	return trim_text(packSync.currentStatus)
end

function pack_sync_confirms_joined_song()
	local status = pack_sync_status_for_joined_song()
	return status == "local_chart_match_found"
		or status == "ready"
		or status == "downloaded_ok"
end

function pack_sync_is_checking_joined_song()
	local status = pack_sync_status_for_joined_song()
	return status == "searching_local_charts"
		or status == "local_chart_match_found"
		or status == "download_requested"
		or status == "download_in_progress"
		or status == "reloading_songs"
		or status == "validating_download"
		or status == "downloaded_ok"
		or status == "ready"
end

local function pack_sync_status_blocks_missing_verdict(status)
	status = trim_text(status)
	return status == "searching_local_charts"
		or status == "download_requested"
		or status == "download_in_progress"
		or status == "reloading_songs"
		or status == "validating_download"
		or status == "downloaded_ok"
		or status == "local_chart_match_found"
		or status == "ready"
end

function can_download_pack_for_reason(reason)
	reason = trim_text(reason)
	return reason == "missing_local_song"
		or reason == "no_compatible_chart_found"
		or reason == "local_payload_unavailable"
		or reason == "song_hash_mismatch"
		or reason == "chart_hash_mismatch"
end

function pack_sync_countdown_seconds_for_player(player)
	if not (ITGOnline and ITGOnline.currentRoom) then return nil end
	local currentUserId = tostring(ITGOnline and ITGOnline.user and ITGOnline.user.id or "")
	if currentUserId ~= ""
		and tostring(player and player.playerId or "") == currentUserId
		and pack_sync_is_checking_joined_song()
	then
		-- The room snapshot can trail the local download by one request/response
		-- cycle.  Never resurrect the missing-pack deadline while this client is
		-- downloading, reloading SongManager, or validating the new chart.
		return nil
	end
	local phase = normalized_online_phase(ITGOnline.currentRoom.phase)
	local selectedSong = ITGOnline.currentRoom.selected_song
	if type(selectedSong) ~= "table"
		or (phase ~= "lobby_ready" and phase ~= "config" and phase ~= "starting") then
		return nil
	end
	if joined_manager_user_id ~= nil and tostring(player and player.playerId or "") == tostring(joined_manager_user_id) then return nil end
	local deadlineMs = tonumber(player and player.packSyncDownloadDeadlineMs)
	if not deadlineMs or deadlineMs <= 0 then return nil end

	local estimatedServerTimeMs = ITGOnline.EstimatedServerTimeMilliseconds
		and ITGOnline:EstimatedServerTimeMilliseconds() or nil
	local remaining = estimatedServerTimeMs and (deadlineMs - estimatedServerTimeMs) / 1000 or nil
	if remaining == nil then
		lobby_flow_trace("pack_sync_kick_warning_waiting_for_clock deadlineMs=" .. tostring(deadlineMs)
			.. " player=" .. tostring(player and player.playerId or "nil"))
		return 1
	end

	-- Keep the warning visible until the server removes the deadline or ejects
	-- the member. A delayed timeout worker must never hide this safety message.
	return math.max(1, math.ceil(remaining))
end

function joined_missing_song_countdown_seconds()
	local currentUserId = tostring(ITGOnline and ITGOnline.user and ITGOnline.user.id or "")
	if currentUserId == "" then return nil end
	for _, player in ipairs(joined_lobby_players or {}) do
		if tostring(player.playerId or "") == currentUserId then
			return pack_sync_countdown_seconds_for_player(player)
		end
	end
	return nil
end

local function joined_download_kick_warning_text()
	local remaining = joined_missing_song_countdown_seconds()
	if remaining == nil then return "" end
	play_online_warning_countdown_tick("pack_sync_kick:download_button", remaining)
	return online_lobby_text("PackKickCountdown", "Removal in %d s: download the pack", math.ceil(remaining))
end

local function joined_inactivity_warning_text()
	local currentUserId = tostring(ITGOnline and ITGOnline.user and ITGOnline.user.id or "")
	if currentUserId == "" then return "" end
	for _, player in ipairs(joined_lobby_players or {}) do
		if tostring(player.playerId or "") == currentUserId then
			local deadlineMs = tonumber(player.inactivityDeadlineMs)
			local serverTimeMs = ITGOnline and ITGOnline.EstimatedServerTimeMilliseconds
				and ITGOnline:EstimatedServerTimeMilliseconds()
			if deadlineMs and serverTimeMs and deadlineMs > serverTimeMs then
				local remaining = math.ceil((deadlineMs - serverTimeMs) / 1000)
				local warningSeconds = tonumber(ITGOnline and ITGOnline.currentRoom and ITGOnline.currentRoom.inactivity_warning_seconds) or 300
				if remaining <= warningSeconds then
					return online_lobby_text("InactivityKickCountdown", "Removal for inactivity in %d min",
						math.max(1, math.ceil(remaining / 60)))
				end
			end
		end
	end
	return ""
end

local function update_joined_download_kick_warning(root)
	if not root then return end
	local joinedContent = root:GetChild("JoinedLobbyContent")
	local warningText = mode == "joined" and joined_download_kick_warning_text() or ""
	if warningText == "" and mode == "joined" then warningText = joined_inactivity_warning_text() end
	local warning = joinedContent and joinedContent:GetChild("PackSyncKickWarning")
	if warning then
		warning:settext(warningText)
		warning:visible(warningText ~= "")
	end
	local warningTraceKey = table.concat({
		tostring(overlay_instance_id or "none"),
		tostring(ITGOnline and ITGOnline.currentRoomId or "no-room"),
		tostring(mode),
		tostring(warningText),
		tostring(showing_pack_choice_menu == true),
	}, "|")
	SL.Global.Online = SL.Global.Online or {}
	if warningTraceKey ~= tostring(SL.Global.Online.ScreenOnlineLobbiesPackSyncWarningTraceKey or "") then
		SL.Global.Online.ScreenOnlineLobbiesPackSyncWarningTraceKey = warningTraceKey
		lobby_flow_trace("pack_sync_warning_render visible=" .. tostring(warningText ~= "")
			.. " modalVisible=" .. tostring(showing_pack_choice_menu == true and warningText ~= "")
			.. " text=" .. tostring(warningText))
	end

	local packChoiceMenu = root:GetChild("PackChoiceMenu")
	local modalWarning = packChoiceMenu and packChoiceMenu:GetChild("PackChoiceKickWarning")
	if modalWarning then
		modalWarning:settext(warningText)
		modalWarning:visible(showing_pack_choice_menu and warningText ~= "")
	end
end

function local_pack_exists(songInfo)
	local pack = trim_text(songInfo and songInfo.pack)
	if pack == "" then return false end
	if ITGOnline and ITGOnline.PackSync and ITGOnline.PackSync.PackExists then
		return ITGOnline.PackSync:PackExists(pack)
	end
	return SONGMAN and SONGMAN.DoesSongGroupExist and SONGMAN:DoesSongGroupExist(pack)
end

function normalized_online_phase(value)
	return tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", ""):lower()
end

function play_joined_song_preview(preview, source)
	if not (preview and play_online_preview_music_normal_rate) then return false end
	local playbackKey = table.concat({
		tostring(ITGOnline and ITGOnline.currentRoomId or joined_lobby_code or ""),
		trim_text(preview.preview_session_id or preview.previewSessionId),
		trim_text(song_info_pack(preview)),
		trim_text(preview.songPath or preview.song_path or preview.folder_name or preview.title),
	}, "|")
	if playbackKey == lobby_trace_state.joinedPreviewPlaybackKey then
		lobby_flow_trace("song_preview_playback_skipped reason=already_playing"
			.. " source=" .. tostring(source or "unknown")
			.. " key=" .. tostring(playbackKey))
		return true
	end
	local played = play_online_preview_music_normal_rate(preview, source or "online_lobby_preview") == true
	if played then
		lobby_trace_state.joinedPreviewPlaybackKey = playbackKey
	else
		lobby_trace_state.joinedPreviewPlaybackKey = ""
	end
	return played
end

local function reset_joined_transient_song_state(reason, options)
	options = options or {}
	local clearPreview = options.clearPreview ~= false
	local resetPackSync = options.resetPackSync ~= false
	local previousPreview = joined_song_preview and (joined_song_preview.title or joined_song_preview.folder_name or joined_song_preview.song_hash) or "none"
	lobby_flow_trace("joined_transient_song_reset reason=" .. tostring(reason or "unknown")
		.. " clearPreview=" .. tostring(clearPreview == true)
		.. " resetPackSync=" .. tostring(resetPackSync == true)
		.. " previousPhase=" .. tostring(joined_phase)
		.. " previousPreview=" .. tostring(previousPreview)
		.. " previousConfirmed=" .. tostring(joined_song_confirmed == true)
		.. " previousMissing=" .. tostring(joined_missing_song == true)
		.. " previousCanDownload=" .. tostring(joined_can_download_pack == true)
		.. " previousUnknownPack=" .. tostring(joined_preview_unknown_pack == true))
	if clearPreview then
		joined_song_preview = nil
		lobby_trace_state.joinedPreviewPlaybackKey = ""
	end
	joined_song_confirmed = false
	joined_song_selected_key = ""
	joined_missing_song = false
	joined_missing_song_info = nil
	joined_can_download_pack = false
	joined_missing_song_reason = nil
	joined_preview_unknown_pack = false
	clear_pack_choice_recovery()
	pack_choice_last_candidates = {}
	pack_choice_last_song_info = nil
	pack_choice_all_candidates_exhausted = false
	showing_browse_pack_download_confirm = false
	browse_pack_download_confirm_index = 0
	browse_pack_download_song_info = nil
	if resetPackSync and ITGOnline and ITGOnline.PackSync and ITGOnline.PackSync.ResetLocalState then
		ITGOnline.PackSync:ResetLocalState(tostring(reason or "joined_transient_song_reset"))
	end
end

local function restore_active_song_preview(root, source)
	if not (ITGOnline and ITGOnline.GetActiveSongPreview) then return false end
	local preview = normalize_online_song_info(ITGOnline:GetActiveSongPreview())
	if not preview then return false end
	local phase = normalized_online_phase(ITGOnline.currentRoom and ITGOnline.currentRoom.phase or joined_phase)
	if phase ~= "lobby" or (ITGOnline.currentRoom and ITGOnline.currentRoom.selected_song ~= nil) then
		return false
	end

	reset_joined_transient_song_state("restore_active_preview:" .. tostring(source or "unknown"), {
		clearPreview = false,
		resetPackSync = false,
	})
	joined_song_preview = preview
	joined_song_confirmed = false
	joined_song_selected_key = ""
	joined_preview_unknown_pack = not local_pack_exists(preview)
	lobby_flow_trace("active_song_preview_restored source=" .. tostring(source or "unknown")
		.. " room=" .. tostring(ITGOnline.currentRoomId or "nil")
		.. " session=" .. tostring(preview.preview_session_id or preview.previewSessionId or "nil")
		.. " pack=" .. tostring(song_info_pack(preview))
		.. " title=" .. tostring(preview.title or preview.folder_name or "nil")
		.. " unknownPack=" .. tostring(joined_preview_unknown_pack == true))
	if ITGOnline.PackSync and ITGOnline.PackSync.ManagerBrowsingPreview then
		ITGOnline.PackSync:ManagerBrowsingPreview(preview)
	end
	if joined_preview_unknown_pack then
		lobby_trace_state.joinedPreviewPlaybackKey = ""
		if stop_music then stop_music() end
	else
		play_joined_song_preview(preview, "online_lobby_restore_after_reload")
	end
	if root then
		root:queuecommand("UpdateJoinedLobbyText")
		request_lobby_ui_repaint(root, "restore_active_song_preview")
	end
	return true
end

function joined_phase_allows_song_selection()
	local phase = normalized_online_phase(joined_phase)
	if phase == "" and ITGOnline and ITGOnline.currentRoom then
		phase = normalized_online_phase(ITGOnline.currentRoom.phase)
	end
	return phase == "lobby"
		or phase == "lobby_ready"
		or phase == "config"
		or (phase == "results" and joined_local_returned_to_lobby_after_results == true)
end

local function local_client_has_returned_to_lobby_for_current_round()
	if not ITGOnline then
		return false, "no_client"
	end

	local currentRoomId = tostring(ITGOnline.currentRoomId or "")
	local localReturnRoomId = tostring(ITGOnline.onlineGameplayReturnedLocalRoomId or "")
	if currentRoomId ~= "" and localReturnRoomId == currentRoomId then
		return true, "local_room_return"
	end

	if not (ITGOnline.PlayStateKey and ITGOnline.PlayStateKeyIsValid) then
		return false, "no_play_state_key_api"
	end
	local key = ITGOnline:PlayStateKey()
	if not ITGOnline:PlayStateKeyIsValid(key) then
		return false, "invalid_play_state_key"
	end
	if tostring(ITGOnline.onlineGameplayReturnedKey or "") == key then
		return true, "returned_key"
	end
	if tostring(ITGOnline.onlineGameplayReturnedInFlightKey or "") == key then
		return true, "returned_in_flight_key"
	end
	return false, "not_returned"
end

function joined_phase_allows_start()
	return joined_phase == "config"
end

function joined_room_can_start()
	return joined_is_manager
		and joined_song_confirmed
		and joined_phase_allows_start()
		and joined_all_players_ready()
		and not joined_any_player_missing_song()
end

function joined_can_cancel_song_selection()
	return joined_is_manager
		and joined_song_confirmed
		and joined_phase_allows_song_selection()
		and not (ITGOnline and ITGOnline.IsSongSelectionTransitionLocked and ITGOnline:IsSongSelectionTransitionLocked("cancel"))
end

function joined_button_indices()
	local indices = {}
	if joined_is_manager and #joined_lobby_players > 1 then
		indices[#indices + 1] = 8
	end
	indices[#indices + 1] = 1
	if joined_is_manager and joined_phase_allows_song_selection() then
		indices[#indices + 1] = 2
	end
	if joined_is_manager and joined_phase_allows_song_selection() then
		indices[#indices + 1] = 4
	end
	if show_pack_download_button() then
		indices[#indices + 1] = 3
	end
	if joined_room_can_start() then
		indices[#indices + 1] = 7
	end
	return indices
end

function joined_active_index_is_available()
	for index in ivalues(joined_button_indices()) do
		if joined_active_index == index then return true end
	end
	return false
end

function joined_all_players_ready()
	-- Server-authoritative helper: a local optimistic ready can be displayed,
	-- but it must not unlock Start before the server confirms it.
	if #joined_lobby_players == 0 then return false end
	for player in ivalues(joined_lobby_players) do
		if not player.ready or player.readyPendingServer then
			return false
		end
	end
	return true
end

-- Selected-song availability
-- -----------------------------------------------------------------------

local function sync_local_missing_song_from_joined_players()
	if not joined_lobby_players or not ITGOnline or not ITGOnline.user then
		lobby_flow_trace("sync_local_missing_song skipped reason=missing_context"
			.. " hasPlayers=" .. tostring(joined_lobby_players ~= nil)
			.. " hasClient=" .. tostring(ITGOnline ~= nil)
			.. " hasUser=" .. tostring(ITGOnline and ITGOnline.user ~= nil))
		return
	end
	if joined_phase == "results" then
		lobby_flow_trace("sync_local_missing_song clear reason=results_phase"
			.. " previousMissing=" .. tostring(joined_missing_song == true)
			.. " previousReason=" .. tostring(joined_missing_song_reason or "nil"))
		joined_missing_song = false
		joined_missing_song_info = nil
		joined_can_download_pack = false
		joined_missing_song_reason = nil
		return
	end

	local selfId = tostring(ITGOnline.user.id or "")
	if selfId == "" then
		lobby_flow_trace("sync_local_missing_song skipped reason=empty_self_id")
		return
	end

	for _, player in ipairs(joined_lobby_players) do
		if tostring(player and player.playerId or "") == selfId then
			lobby_flow_trace("sync_local_missing_song self_player"
				.. " player=" .. tostring(player.profileName or player.playerId or "?")
				.. " missing=" .. tostring(player.missingSong == true)
				.. " available=" .. tostring(player.songAvailable == true)
				.. " reason=" .. tostring(player.missingSongReason or "nil")
				.. " packStatus=" .. tostring(player.packSyncStatus or "nil")
				.. " checking=" .. tostring(pack_sync_is_checking_joined_song() == true)
				.. " confirms=" .. tostring(pack_sync_confirms_joined_song() == true)
				.. " manager=" .. tostring(joined_manager_user_id ~= nil and tostring(joined_manager_user_id) == selfId))
			if joined_manager_user_id ~= nil and tostring(joined_manager_user_id) == selfId then
				joined_missing_song = false
				joined_missing_song_info = nil
				joined_can_download_pack = false
				joined_missing_song_reason = nil
				return
			end
			local selfMissing = player.missingSong == true
			local playerPackStatus = trim_text(player.packSyncStatus)
			if pack_sync_confirms_joined_song() then
				player.missingSong = false
				player.missingSongReason = nil
				joined_missing_song = false
				joined_missing_song_info = nil
				joined_can_download_pack = false
				joined_missing_song_reason = nil
			elseif (selfMissing or joined_missing_song)
				and (pack_sync_status_blocks_missing_verdict(playerPackStatus) or pack_sync_is_checking_joined_song())
			then
				lobby_flow_trace("sync_local_missing_song preserve reason=missing_verdict_waiting_positive_status"
					.. " status=" .. tostring(playerPackStatus)
					.. " previousPlayerMissing=" .. tostring(selfMissing)
					.. " previousJoinedMissing=" .. tostring(joined_missing_song == true))
				player.missingSong = true
				player.missingSongReason = player.missingSongReason or joined_missing_song_reason or "missing_local_song"
				joined_missing_song = true
				joined_missing_song_reason = player.missingSongReason
				if joined_missing_song_info == nil then
					joined_missing_song_info = joined_song_preview
				end
				joined_can_download_pack = joined_can_download_pack or can_download_pack_for_reason(joined_missing_song_reason)
			elseif pack_sync_status_blocks_missing_verdict(playerPackStatus) or pack_sync_is_checking_joined_song() then
				lobby_flow_trace("sync_local_missing_song provisional reason=no_missing_verdict_yet"
					.. " status=" .. tostring(playerPackStatus))
			elseif selfMissing and not pack_sync_is_checking_joined_song() then
				joined_missing_song = true
				joined_missing_song_reason = player.missingSongReason or joined_missing_song_reason or "missing_local_song"
				if joined_missing_song_info == nil then
					joined_missing_song_info = joined_song_preview
				end
				joined_can_download_pack = joined_can_download_pack or can_download_pack_for_reason(joined_missing_song_reason)
			elseif joined_missing_song and (player.songAvailable == true or pack_sync_is_checking_joined_song()) then
				joined_missing_song = false
				joined_missing_song_info = nil
				joined_can_download_pack = false
				joined_missing_song_reason = nil
			end
			return
		end
	end
	lobby_flow_trace("sync_local_missing_song skipped reason=self_not_found selfId=" .. tostring(selfId)
		.. " players=" .. tostring(#joined_lobby_players))
end

local function player_is_current_user(player)
	if not (ITGOnline and ITGOnline.user) then return false end
	return tostring(player and player.playerId or "") == tostring(ITGOnline.user.id or "")
end

local function apply_local_pack_sync_status_to_joined_player(params)
	if not (params and ITGOnline and ITGOnline.user) then
		lobby_flow_trace("apply_local_pack_sync_status skipped reason=missing_context"
			.. " hasParams=" .. tostring(params ~= nil)
			.. " hasClient=" .. tostring(ITGOnline ~= nil)
			.. " hasUser=" .. tostring(ITGOnline and ITGOnline.user ~= nil))
		return false
	end
	local currentUserId = tostring(ITGOnline.user.id or "")
	if currentUserId == "" then
		lobby_flow_trace("apply_local_pack_sync_status skipped reason=empty_user_id")
		return false
	end
	for _, player in ipairs(joined_lobby_players or {}) do
		if tostring(player and player.playerId or "") == currentUserId then
			local status = trim_text(params.status)
			lobby_flow_trace("apply_local_pack_sync_status player=" .. tostring(player.profileName or player.playerId or "?")
				.. " status=" .. tostring(status)
				.. " message=" .. tostring(params.message or "nil")
				.. " progress=" .. tostring(params.download_progress or "nil")
				.. " previousStatus=" .. tostring(player.packSyncStatus or "nil")
				.. " previousMissing=" .. tostring(player.missingSong == true)
				.. " previousAvailable=" .. tostring(player.songAvailable == true))
			if status ~= "" then player.packSyncStatus = status end
			player.packSyncMessage = params.message
			if params.download_progress ~= nil then
				player.packSyncDownloadProgress = params.download_progress
			elseif status ~= "download_in_progress" and status ~= "download_requested" then
				player.packSyncDownloadProgress = nil
			end
			if status == "ready" or status == "local_chart_match_found" then
				lobby_flow_trace("apply_local_pack_sync_status_decision verdict=available"
					.. " status=" .. tostring(status)
					.. " reason=positive_status"
					.. " previousMissing=" .. tostring(player.missingSong == true))
				player.missingSong = false
				player.missingSongReason = nil
				player.songAvailable = joined_song_confirmed and true or player.songAvailable
			elseif status == "downloaded_ok" then
				lobby_flow_trace("apply_local_pack_sync_status_decision verdict=provisional"
					.. " status=" .. tostring(status)
					.. " reason=download_complete_waiting_scan"
					.. " previousMissing=" .. tostring(player.missingSong == true))
				player.missingSong = false
				player.missingSongReason = nil
			elseif pack_sync_status_blocks_missing_verdict(status) then
				lobby_flow_trace("apply_local_pack_sync_status_decision verdict=preserve_missing_until_positive"
					.. " status=" .. tostring(status)
					.. " reason=blocks_missing_verdict"
					.. " previousMissing=" .. tostring(player.missingSong == true))
				if player.missingSong == true then
					player.missingSongReason = player.missingSongReason or joined_missing_song_reason or "missing_local_song"
				end
			elseif status == "manager_browsing_unknown_pack" then
				lobby_flow_trace("apply_local_pack_sync_status_decision verdict=preview_unknown_pack"
					.. " status=" .. tostring(status))
				player.songAvailable = false
			end
			lobby_flow_trace("apply_local_pack_sync_status_applied player=" .. tostring(player.profileName or player.playerId or "?")
				.. " status=" .. tostring(player.packSyncStatus or "nil")
				.. " missing=" .. tostring(player.missingSong == true)
				.. " available=" .. tostring(player.songAvailable == true)
				.. " progress=" .. tostring(player.packSyncDownloadProgress or "nil"))
			return true
		end
	end
	lobby_flow_trace("apply_local_pack_sync_status skipped reason=self_not_found userId=" .. tostring(currentUserId)
		.. " players=" .. tostring(#(joined_lobby_players or {})))
	return false
end

local function player_missing_song_for_ui(player)
	if joined_phase == "results" then return false end
	if joined_manager_user_id ~= nil and tostring(player and player.playerId or "") == tostring(joined_manager_user_id) then return false end
	return player and player.missingSong == true or false
end

local function player_is_manager(player)
	return joined_manager_user_id ~= nil and tostring(player and player.playerId or "") == tostring(joined_manager_user_id)
end

local function selected_joined_player()
	if #joined_lobby_players == 0 then return nil end
	joined_player_index = math.max(1, math.min(joined_player_index, #joined_lobby_players))
	return joined_lobby_players[joined_player_index]
end

local function joined_player_can_receive_manager(player)
	if not joined_is_manager or not player then return false end
	if player_is_manager(player) then return false end
	if tostring(player.playerId or "") == "" then return false end
	return true
end

local function joined_player_action_user(player)
	if type(player) ~= "table" then return nil end
	local user = {}
	for key, value in pairs(player) do
		user[key] = value
	end
	user.actionContext = "joined_manager_transfer"
	user.id = user.playerId or user.id
	return user
end

local function focus_joined_players()
	if not joined_is_manager or #joined_lobby_players <= 1 then return false end
	joined_player_index = math.max(1, math.min(joined_player_index, #joined_lobby_players))
	if player_is_manager(joined_lobby_players[joined_player_index]) then
		for i, player in ipairs(joined_lobby_players) do
			if joined_player_can_receive_manager(player) then
				joined_player_index = i
				break
			end
		end
	end
	joined_players_selected = joined_player_can_receive_manager(joined_lobby_players[joined_player_index])
	return joined_players_selected
end

local function open_transfer_manager_confirm(player, action)
	if not joined_player_can_receive_manager(player) then
		lobby_flow_trace("transfer_manager_confirm_open_blocked reason=invalid_player"
			.. " player=" .. tostring(player and (player.playerId or player.profileName or player.name) or "nil"))
		return false
	end
	transfer_manager_confirm_user = player
	transfer_manager_confirm_action = action == "exclude_player" and "exclude_player" or "transfer_manager"
	transfer_manager_confirm_index = 0
	showing_transfer_manager_confirm = true
	if t then
		local prompt = t:GetChild("TransferManagerConfirmPrompt")
		if prompt then prompt:visible(true) end
		t:queuecommand("UpdateTransferManagerConfirmPrompt")
		t:queuecommand("Hover")
	end
	lobby_flow_trace("transfer_manager_confirm_open player=" .. tostring(player.playerId or player.profileName or player.name or "nil")
		.. " action=" .. tostring(transfer_manager_confirm_action))
	return true
end

local function close_transfer_manager_confirm()
	showing_transfer_manager_confirm = false
	transfer_manager_confirm_index = 0
	transfer_manager_confirm_user = nil
	transfer_manager_confirm_action = "transfer_manager"
	if t then
		local prompt = t:GetChild("TransferManagerConfirmPrompt")
		if prompt then prompt:visible(false) end
		t:queuecommand("Hover")
	end
end

function ScreenOnlineLobbiesPackSyncDisplayLine(player, status, display, reason)
	SL.Global.Online = SL.Global.Online or {}
	local traceByPlayer = SL.Global.Online.ScreenOnlineLobbiesPackSyncDisplayTrace or {}
	SL.Global.Online.ScreenOnlineLobbiesPackSyncDisplayTrace = traceByPlayer
	local playerId = table.concat({
		tostring(overlay_instance_id or "none"),
		tostring(ITGOnline and ITGOnline.currentRoomId or "no-room"),
		tostring(player and player.playerId or "unknown"),
	}, "|")
	local signature = table.concat({ tostring(status or ""), tostring(display or ""), tostring(reason or "") }, "|")
	if traceByPlayer[playerId] ~= signature then
		traceByPlayer[playerId] = signature
		lobby_flow_trace("pack_sync_display player=" .. playerId
			.. " status=" .. tostring(status or "")
			.. " display=" .. tostring(display or "")
			.. " reason=" .. tostring(reason or ""))
	end
	return display
end

local function pack_sync_line_for_player(player)
	if not player or player_is_manager(player) or joined_phase == "results" then return "" end
	if joined_song_preview == nil and not (ITGOnline and ITGOnline.currentRoom and ITGOnline.currentRoom.selected_song) then return "" end

	local status = trim_text(player.packSyncStatus)
	local message = trim_text(player.packSyncMessage)
	local reason = trim_text(player.missingSongReason)
	local songAvailable = player.songAvailable == true
	local previewOnly = joined_song_preview ~= nil and not joined_song_confirmed
	local isCurrentUser = ITGOnline and ITGOnline.user
		and tostring(player.playerId or "") == tostring(ITGOnline.user.id or "")
	if isCurrentUser and pack_sync_is_checking_joined_song() then
		local localStatus = trim_text(ITGOnline.PackSync.currentStatus)
		if localStatus ~= "" then
			status = localStatus
			message = trim_text(ITGOnline.PackSync.currentStatusMessage)
			player.packSyncStatus = localStatus
			player.packSyncMessage = ITGOnline.PackSync.currentStatusMessage
			if localStatus == "download_in_progress" or localStatus == "download_requested" then
				player.packSyncDownloadProgress = tonumber(ITGOnline.PackSync.currentStatusProgress)
			end
		end
	end

	if status == "download_in_progress" then
		-- Only the downloading player needs the byte-level progress.  Everyone
		-- else merely needs to know that this member is still synchronising.
		local progress = isCurrentUser and tonumber(player.packSyncDownloadProgress) or nil
		local suffix = progress and (" " .. tostring(math.floor(progress)) .. "%") or ""
		return ScreenOnlineLobbiesPackSyncDisplayLine(player, status,
			online_lobby_text("PackDownloading", "Downloading") .. suffix,
			isCurrentUser and "local_progress" or "remote_progress_hidden")
	end
	if status == "download_requested" or status == "reloading_songs" or status == "validating_download" then
		return ScreenOnlineLobbiesPackSyncDisplayLine(player, status,
			online_lobby_text("PackDownloading", "Downloading"), "transient_download")
	end
	if status == "searching_local_charts" then
		if not isCurrentUser then
			return ScreenOnlineLobbiesPackSyncDisplayLine(player, status,
				online_lobby_text("PackDownloading", "Downloading"), "remote_scan_hidden")
		end
		return ScreenOnlineLobbiesPackSyncDisplayLine(player, status,
			message ~= "" and message or pack_sync_display_text(status), "local_scan")
	end
	if status == "downloaded_ok" then
		return ScreenOnlineLobbiesPackSyncDisplayLine(player, status, "", "download_complete_hidden")
	end

	if previewOnly then
		if status == "download_failed" then
			return message ~= "" and message or pack_sync_display_text(status)
		end
		if status == "manager_browsing_unknown_pack" then
			return online_lobby_text("UnknownPack", "Unknown pack")
		end
		return ""
	end

	if player_missing_song_for_ui(player) then
		if status == "local_chart_match_found" or songAvailable then
			return online_lobby_text("CompatibleChartFound", "Pack missing / compatible chart found")
		end
		local remaining = pack_sync_countdown_seconds_for_player(player)
		if remaining ~= nil then
			return ""
		end
			if reason == "missing_local_song"
				or reason == "no_compatible_chart_found"
				or reason == "chart_hash_mismatch"
				or reason == "song_hash_mismatch"
				or reason == "hash_mismatch"
				or status == "no_compatible_chart_found"
				or status == "chart_mismatch" then
				return online_lobby_text("NoCompatibleChartFound", "Pack missing / no compatible chart found")
			end
		end

	if songAvailable or status == "ready" or status == "local_chart_match_found" then
		return ScreenOnlineLobbiesPackSyncDisplayLine(player, status, "", "available_hidden")
	end

	if status ~= "" and status ~= "unknown" and status ~= "idle" then
		return pack_sync_display_text(status)
	end

	return ScreenOnlineLobbiesPackSyncDisplayLine(player, status, "", "no_display_status")
end

joined_any_player_missing_song = function()
	if joined_phase == "results" then return false end
	for player in ivalues(joined_lobby_players) do
		if player_missing_song_for_ui(player) then return true end
	end
	return false
end

local function normalize_joined_active_index()
	local indices = joined_button_indices()
	for index in ivalues(indices) do
		if joined_active_index == index then
			return false
		end
	end
	local previous = joined_active_index
	joined_active_index = indices[1] or 1
	joined_user_moved_focus = false
	lobby_trace_state.lastAutoStartFocusKey = ""
	lobby_flow_trace("joined_active_index_normalized previous=" .. tostring(previous)
		.. " next=" .. tostring(joined_active_index)
		.. " indices=" .. table.concat(indices, ",")
		.. " phase=" .. tostring(joined_phase)
		.. " isManager=" .. tostring(joined_is_manager))
	return true
end

local function move_joined_button(delta)
	local indices = joined_button_indices()
	local current = 1
	for i, index in ipairs(indices) do
		if joined_active_index == index then
			current = i
			break
		end
	end

	local nextIndex = current + delta
	if nextIndex < 1 then nextIndex = #indices end
	if nextIndex > #indices then nextIndex = 1 end
	local previous = joined_active_index
	joined_active_index = indices[nextIndex] or 1
	joined_user_moved_focus = true
	lobby_flow_trace("joined_button_focus_moved previous=" .. tostring(previous)
		.. " next=" .. tostring(joined_active_index)
		.. " delta=" .. tostring(delta)
		.. " currentSlot=" .. tostring(current)
		.. " nextSlot=" .. tostring(nextIndex)
		.. " indices=" .. table.concat(indices, ",")
		.. " phase=" .. tostring(joined_phase)
		.. " playersSelected=" .. tostring(joined_players_selected == true))
end

local function set_joined_default_active_index(force)
	local indices = joined_button_indices()
	if not force then
		for _, index in ipairs(indices) do
			if joined_active_index == index then
				return
			end
		end
	end
	local previous = joined_active_index
	joined_active_index = indices[1] or 1
	joined_user_moved_focus = false
	lobby_trace_state.lastAutoStartFocusKey = ""
	lobby_flow_trace("joined_default_focus_set previous=" .. tostring(previous)
		.. " next=" .. tostring(joined_active_index)
		.. " force=" .. tostring(force == true)
		.. " indices=" .. table.concat(indices, ",")
		.. " phase=" .. tostring(joined_phase)
		.. " isManager=" .. tostring(joined_is_manager))
end

local function transition_to_online_song_reload()
	local topScreen = SCREENMAN:GetTopScreen()
	if not topScreen then return false end
	local ok, err = pcall(function()
		topScreen:SetNextScreenName("ScreenReloadSongsOnline")
		topScreen:StartTransitioningScreen("SM_GoToNextScreen")
	end)
	if not ok then
		lobby_flow_trace("song_reload_transition_failed error=" .. tostring(err or "unknown"))
		return false
	end
	SL.Global.Online = SL.Global.Online or {}
	SL.Global.Online.ReturnToLobbyAfterSongReload = true
	return true
end

local function room_accepts_new_members(room)
	if not room then return false end
	if room.acceptsNewMembers ~= nil then return room.acceptsNewMembers == true end
	if room.accepts_new_members ~= nil then return room.accepts_new_members == true end
	local phase = normalized_online_phase(room.phase)
	return phase == "lobby" or phase == "results"
end

local function selected_online_user()
	if #online_users == 0 then return nil end
	online_player_index = math.max(1, math.min(online_player_index, #online_users))
	return online_users[online_player_index]
end

local function build_player_action_options(user)
	if not user then return {} end
	if user.actionContext == "joined_manager_transfer" then
		if not joined_player_can_receive_manager(user) then
			return {
				{label=online_lobby_text("TransferUnavailable", "Transfer unavailable"), action="cancel"},
				{label=online_lobby_text("Cancel", "Cancel"), action="cancel"},
			}
		end
		return {
			{label=online_lobby_text("TransferManager", "Transfer manager"), action="transfer_manager"},
			{label=online_lobby_text("RemoveFromLobby", "Remove from lobby"), action="exclude_player_confirm"},
			{label=online_lobby_text("Cancel", "Cancel"), action="cancel"},
		}
	end
	if user.isSelf then
		return {
			{label=online_lobby_text("ThisIsYou", "This is you"), action="cancel"},
			{label=online_lobby_text("Cancel", "Cancel"), action="cancel"},
		}
	end
	if user.isLocalCompanion then
		return {
			{label=online_lobby_text("AlreadyWithYou", "Already with you"), action="cancel"},
			{label=online_lobby_text("Cancel", "Cancel"), action="cancel"},
		}
	end
	if user.room and user.room.visibility == "public" then
		if not room_accepts_new_members(user.room) then
			return {
				{label=online_lobby_text("PublicLobbyUnavailable", "Public lobby unavailable"), action="cancel"},
				{label=online_lobby_text("Cancel", "Cancel"), action="cancel"},
			}
		end
		if user.room.id then
			return {
				{label=online_lobby_text("JoinPublicLobby", "Join public lobby"), action="join_public_room", room_id=user.room.id},
				{label=online_lobby_text("Cancel", "Cancel"), action="cancel"},
			}
		end

		return {
			{label=online_lobby_text("JoinPublicLobby", "Join public lobby"), action="join_user_room"},
			{label=online_lobby_text("Cancel", "Cancel"), action="cancel"},
		}
	end
	if user.room and user.room.visibility == "private" then
		return {
			{label=online_lobby_text("RequestPrivateLobbyAccess", "Request access to private lobby"), action="join_user_room"},
			{label=online_lobby_text("Cancel", "Cancel"), action="cancel"},
		}
	end
	return {
		{label=online_lobby_text("InviteToPrivateLobby", "Invite to private lobby"), action="invite_private"},
		{label=online_lobby_text("InviteToPublicLobby", "Invite to public lobby"), action="invite_public"},
		{label=online_lobby_text("Cancel", "Cancel"), action="cancel"},
	}
end

local function active_private_prompt_options()
	if private_join_prompt_kind == "invitation" then
		return room_invitation_options
	end
	return private_join_options
end

	clear_pending_join = function()
		lobby_flow_trace("clear_pending_join actionId=" .. tostring(pending_join_action_id)
			.. " deadline=" .. tostring(pending_join_deadline))
		pending_join_action_id = 0
		pending_join_deadline = 0
	end

clear_pending_create = function()
	lobby_flow_trace("clear_pending_create actionId=" .. tostring(pending_create_action_id)
		.. " deadline=" .. tostring(pending_create_deadline))
	pending_create_action_id = 0
	pending_create_deadline = 0
end

local function begin_create_timeout(actor, seconds)
	seconds = tonumber(seconds) or 30
	pending_create_action_id = pending_create_action_id + 1
	pending_create_deadline = GetTimeSinceStart() + seconds
	local timer = actor and actor:GetChild("CreateTimeoutTimer")
	lobby_flow_trace("begin_create_timeout actionId=" .. tostring(pending_create_action_id)
		.. " seconds=" .. tostring(seconds)
		.. " deadline=" .. tostring(pending_create_deadline)
		.. " hasTimer=" .. tostring(timer ~= nil))
	if timer then
		timer:stoptweening()
		timer:sleep(seconds):queuecommand("CheckCreateTimeout")
	end
end

local function cancel_pending_create(message)
	lobby_flow_trace("cancel_pending_create message=" .. tostring(message or "")
		.. " actionId=" .. tostring(pending_create_action_id)
		.. " deadline=" .. tostring(pending_create_deadline))
	clear_pending_create()
	mode = "browse"
	if t then
		t:GetChild("JoinedLobbyContent"):visible(false)
		request_lobby_ui_repaint(t, "connection_cancel_pending_create")
		t:playcommand("SetStatus", {
			text=message or online_lobby_text("CreateLobbyTimeout", "Lobby creation timed out. Check the connection and try again."),
			showSpinner=false,
			showPrompt=true
		})
	end
end

local function begin_join_timeout(actor, seconds)
	seconds = tonumber(seconds) or 20
	pending_join_action_id = pending_join_action_id + 1
	pending_join_deadline = GetTimeSinceStart() + seconds
	local timer = actor and actor:GetChild("JoinTimeoutTimer")
	lobby_flow_trace("begin_join_timeout actionId=" .. tostring(pending_join_action_id)
		.. " seconds=" .. tostring(seconds)
		.. " deadline=" .. tostring(pending_join_deadline)
		.. " hasTimer=" .. tostring(timer ~= nil))
	if timer then
		timer:stoptweening()
		timer:sleep(seconds):queuecommand("CheckJoinTimeout")
	end
end

	local function cancel_pending_join(message)
		local onlineHandler = GetOnlineHandlerInstance()
		lobby_flow_trace("cancel_pending_join message=" .. tostring(message or "")
			.. " actionId=" .. tostring(pending_join_action_id)
			.. " deadline=" .. tostring(pending_join_deadline)
			.. " hasHandler=" .. tostring(onlineHandler ~= nil)
			.. " connected=" .. tostring(onlineHandler and onlineHandler.connected or false)
			.. " pendingJoinRequestId=" .. tostring(onlineHandler and onlineHandler.pendingJoinRequestId or "nil"))
		if onlineHandler and onlineHandler.connected and onlineHandler.pendingJoinRequestId then
			onlineHandler:CancelJoinRequest()
		end

		clear_pending_join()
		mode = "browse"
		showing_player_action_menu = false

	if t then
		t:GetChild("PlayerActionMenu"):visible(false)
		t:GetChild("JoinedLobbyContent"):visible(false)
		request_lobby_ui_repaint(t, "join_request_timeout")
		t:playcommand("SetStatus", {
			text=message or online_lobby_text("JoinLobbyTimeout", "The attempt to join the lobby timed out. Refreshing..."),
			showSpinner=false,
			showPrompt=false
		})
		request_lobby_refresh("join_request_timeout", { immediate=true }, t)
		t:queuecommand("Hover")
	end
end

local function execute_player_action(option, user)
	lobby_flow_trace("execute_player_action_begin"
		.. " action=" .. tostring(option and option.action or "nil")
		.. " targetUser=" .. tostring(user and (user.playerId or user.id) or "nil")
		.. " joined_code=" .. tostring(joined_lobby_code)
		.. " phase=" .. tostring(joined_phase)
		.. " isManager=" .. tostring(joined_is_manager == true))
	if not option or not user then
		lobby_flow_trace("execute_player_action_skipped reason=missing_option_or_user")
		return
	end
	if not t then
		lobby_flow_trace("execute_player_action_skipped reason=no_overlay_root")
		return
	end
	showing_player_action_menu = false
	t:GetChild("PlayerActionMenu"):visible(false)

	if option.action == "exclude_player_confirm" then
		open_transfer_manager_confirm(user, "exclude_player")
		return
	end

	if option.action == "transfer_manager" then
		local targetUserId = user.playerId or user.id
		if not joined_player_can_receive_manager(user) or not ITGOnline or not ITGOnline.TransferRoomManager then
			t:playcommand("SetStatus", {
				text=online_lobby_text("TransferManagerPlayerUnavailable", "The manager role cannot be transferred to this player."),
				showSpinner=false,
				showPrompt=true
			})
			return
		end
		t:playcommand("SetStatus", {
			text=online_lobby_text("TransferringManager", "Transferring manager role..."),
			showSpinner=true,
			showPrompt=false
		})
		ITGOnline:TransferRoomManager(targetUserId, function(ok, decoded, response)
			lobby_flow_trace("transfer_manager_response ok=" .. tostring(ok == true)
				.. " targetUser=" .. tostring(targetUserId or "nil")
				.. " status=" .. tostring(response and response.statusCode or "nil")
				.. " hasRoom=" .. tostring(decoded and decoded.room ~= nil))
			if ok then
				joined_players_selected = false
				if t then
					t:playcommand("SetStatus", {
						text=online_lobby_text("ManagerTransferred", "Manager role transferred."),
						showSpinner=false,
						showPrompt=false
					})
					t:queuecommand("UpdateJoinedLobbyText")
					t:queuecommand("Hover")
				end
			elseif t then
				local message = online_lobby_text("TransferManagerFailed", "Could not transfer the manager role.")
				if response and response.errorMessage then message = response.errorMessage end
				if decoded and decoded.message then message = decoded.message end
				t:playcommand("SetStatus", {
					text=message,
					showSpinner=false,
					showPrompt=true
				})
			end
		end)
	elseif option.action == "exclude_player" then
		local targetUserId = user.playerId or user.id
		if not joined_player_can_receive_manager(user) or not ITGOnline or not ITGOnline.KickRoomMember then
			t:playcommand("SetStatus", {
				text=online_lobby_text("RemovePlayerUnavailable", "This player cannot be removed from the lobby."),
				showSpinner=false,
				showPrompt=true
			})
			return
		end
		t:playcommand("SetStatus", {
			text=online_lobby_text("RemovingPlayer", "Removing player..."),
			showSpinner=true,
			showPrompt=false
		})
		ITGOnline:KickRoomMember(targetUserId, function(ok, decoded, response)
			lobby_flow_trace("kick_player_response ok=" .. tostring(ok == true)
				.. " targetUser=" .. tostring(targetUserId or "nil")
				.. " status=" .. tostring(response and response.statusCode or "nil")
				.. " hasRoom=" .. tostring(decoded and decoded.room ~= nil))
			if ok then
				joined_players_selected = false
				if t then
					t:playcommand("SetStatus", {
						text=online_lobby_text("PlayerRemoved", "Player removed from lobby."),
						showSpinner=false,
						showPrompt=false
					})
					t:queuecommand("UpdateJoinedLobbyText")
					t:queuecommand("Hover")
				end
			elseif t then
				local message = online_lobby_text("RemovePlayerFailed", "Could not remove this player.")
				if response and response.errorMessage then message = response.errorMessage end
				if decoded and decoded.message then message = decoded.message end
				t:playcommand("SetStatus", {
					text=message,
					showSpinner=false,
					showPrompt=true
				})
			end
		end)
	elseif option.action == "invite_private" then
		t:GetChild("LobbyContent"):visible(false)
		t:GetChild("OnlinePlayersContent"):visible(false)
			t:playcommand("SetStatus", {text=online_lobby_text("CreatingPrivateLobbyInvite", "Creating private lobby and sending invitation..."), showSpinner=true, showPrompt=false})
		MESSAGEMAN:Broadcast("InviteOnlinePlayer", {user_id=user.id, visibility="private"})
	elseif option.action == "invite_public" then
		t:GetChild("LobbyContent"):visible(false)
		t:GetChild("OnlinePlayersContent"):visible(false)
			t:playcommand("SetStatus", {text=online_lobby_text("CreatingPublicLobbyInvite", "Creating public lobby and sending invitation..."), showSpinner=true, showPrompt=false})
		MESSAGEMAN:Broadcast("InviteOnlinePlayer", {user_id=user.id, visibility="public"})
	elseif option.action == "join_user_room" then
		t:GetChild("LobbyContent"):visible(false)
		t:GetChild("OnlinePlayersContent"):visible(false)
			t:playcommand("SetStatus", {text=online_lobby_text("ContactingPlayerLobby", "Contacting the player's lobby..."), showSpinner=true, showPrompt=false})
		begin_join_timeout(t)
		MESSAGEMAN:Broadcast("JoinOnlinePlayerRoom", {user_id=user.id})
	elseif option.action == "join_public_room" and option.room_id then
		t:GetChild("LobbyContent"):visible(false)
		t:GetChild("OnlinePlayersContent"):visible(false)
			t:playcommand("SetStatus", {text=online_lobby_text("JoiningPublicLobby", "Joining public lobby..."), showSpinner=true, showPrompt=false})
		begin_join_timeout(t)
		MESSAGEMAN:Broadcast("JoinLobby", {code=option.room_id})
	end
end

local function pack_choice_requires_selection()
	return showing_pack_choice_menu
		and pack_choice_browse_only ~= true
		and joined_song_confirmed == true
end

local function close_pack_choice_menu(cancelPackChoice)
	lobby_flow_trace("pack_choice_menu_close begin cancelPackChoice=" .. tostring(cancelPackChoice == true)
		.. " showing=" .. tostring(showing_pack_choice_menu == true)
		.. " index=" .. tostring(pack_choice_index)
		.. " candidates=" .. tostring(#pack_choice_candidates)
		.. " browseOnly=" .. tostring(pack_choice_browse_only == true)
		.. " downloadKey=" .. tostring(pack_choice_download_key or "")
		.. " selectedCandidate=" .. tostring(pack_choice_candidates[pack_choice_index] and pack_choice_candidates[pack_choice_index].id or "nil"))
	if cancelPackChoice == true
		and ITGOnline
		and ITGOnline.PackSync
		and ITGOnline.PackSync.CancelPendingPackChoice then
		ITGOnline.PackSync:CancelPendingPackChoice("pack_choice_menu_closed")
	end
	if cancelPackChoice == true then
		clear_pack_choice_recovery()
	end
	showing_pack_choice_menu = false
	pack_choice_index = 1
	pack_choice_candidates = {}
	pack_choice_song_info = nil
	pack_choice_message = nil
	pack_choice_browse_only = false
	pack_choice_download_key = nil
	if t then
		local menu = t:GetChild("PackChoiceMenu")
		if menu then menu:visible(false) end
	end
	lobby_flow_trace("pack_choice_menu_close end cancelPackChoice=" .. tostring(cancelPackChoice == true)
		.. " showing=" .. tostring(showing_pack_choice_menu == true))
end

local function update_pack_choice_menu()
	if not t then
		lobby_flow_trace("pack_choice_menu_update skipped reason=no_root")
		return
	end
	local menu = t:GetChild("PackChoiceMenu")
	if not menu then
		lobby_flow_trace("pack_choice_menu_update skipped reason=no_menu")
		return
	end
	lobby_flow_trace("pack_choice_menu_update index=" .. tostring(pack_choice_index)
		.. " candidates=" .. tostring(#pack_choice_candidates)
		.. " browseOnly=" .. tostring(pack_choice_browse_only == true)
		.. " requiresSelection=" .. tostring(pack_choice_requires_selection())
		.. " message=" .. tostring(pack_choice_message or "nil"))
		local title = menu:GetChild("PackChoiceTitle")
		local hint = menu:GetChild("PackChoiceHint")
		local options = menu:GetChild("PackChoiceOptions")
		if title then title:settext(online_lobby_text("ChoosePackToDownload", "Choose a pack to download")) end
		if hint then
			hint:settext(pack_choice_requires_selection()
				and online_lobby_text("PackChoiceRequiredHint", "&MENULEFT;/&MENURIGHT; choose | &START; download | choice required")
				or online_lobby_text("PackChoiceOptionalHint", "&MENULEFT;/&MENURIGHT; choose | &START; download | &SELECT; cancel"))
		end
	if options then
		local lines = {}
		if pack_choice_message and trim_text(pack_choice_message) ~= "" then
			lines[#lines + 1] = tostring(pack_choice_message)
			lines[#lines + 1] = ""
		end
		for i, candidate in ipairs(pack_choice_candidates) do
			local prefix = (i == pack_choice_index) and "> " or "  "
			local songsCount = tonumber(candidate.songs_count) or 0
				lines[#lines + 1] = prefix .. tostring(candidate.name or ("Pack " .. tostring(candidate.id)))
					.. " " .. online_lobby_text("SongCount", "(%d songs)", songsCount)
		end
		lines[#lines + 1] = ""
		if pack_choice_requires_selection() then
			lines[#lines + 1] = online_lobby_text("PackChoiceRequiredHelp", "Left/Right to choose, START to download. A choice is required before removal.")
		else
			lines[#lines + 1] = online_lobby_text("PackChoiceOptionalHelp", "Left/Right to choose, START to download, Select to cancel.")
		end
		options:settext(table.concat(lines, "\n"))
		end
		menu:visible(true)
		update_joined_download_kick_warning(t)
	end

-- Pack choice and download prompts
-- -----------------------------------------------------------------------

local function open_pack_choice_menu(songInfo, candidates, message, browseOnly)
	if type(candidates) ~= "table" or #candidates == 0 then
		lobby_flow_trace("pack_choice_menu_open skipped reason=no_candidates"
			.. " hasSongInfo=" .. tostring(songInfo ~= nil)
			.. " message=" .. tostring(message or "nil")
			.. " browseOnly=" .. tostring(browseOnly == true))
		return false
	end
	lobby_flow_trace("pack_choice_menu_open begin candidates=" .. tostring(#candidates)
		.. " browseOnly=" .. tostring(browseOnly == true)
		.. " song=" .. tostring(songInfo and (songInfo.title or songInfo.folder_name or songInfo.song_hash) or "nil")
		.. " message=" .. tostring(message or "nil"))
	showing_player_action_menu = false
	if t then
		local playerMenu = t:GetChild("PlayerActionMenu")
		if playerMenu then playerMenu:visible(false) end
	end
	pack_choice_song_info = songInfo
	pack_choice_candidates = candidates
	pack_choice_browse_only = browseOnly == true
	pack_choice_download_key = nil
	pack_choice_last_song_info = songInfo
	pack_choice_last_candidates = candidates
	SL.Global.Online.PackChoiceRecovery = {
		songInfo = songInfo,
		candidates = candidates,
		selectedPackId = pack_choice_last_selected_pack_id,
		downloadKey = pack_choice_download_key,
	}
	pack_choice_index = 1
	pack_choice_message = message
	pack_choice_all_candidates_exhausted = false
	showing_pack_choice_menu = true
	update_pack_choice_menu()
	if t and message then
		local networkStatus = t:GetChild("NetworkStatus")
		if networkStatus then networkStatus:visible(false) end
	end
	lobby_flow_trace("pack_choice_menu_open end showing=" .. tostring(showing_pack_choice_menu == true)
		.. " recoveryCandidates=" .. tostring(SL and SL.Global and SL.Global.Online and SL.Global.Online.PackChoiceRecovery and SL.Global.Online.PackChoiceRecovery.candidates and #SL.Global.Online.PackChoiceRecovery.candidates or 0))
	return true
end

local function close_browse_pack_download_confirm()
	lobby_flow_trace("browse_pack_download_confirm_close showing=" .. tostring(showing_browse_pack_download_confirm == true)
		.. " index=" .. tostring(browse_pack_download_confirm_index)
		.. " song=" .. tostring(browse_pack_download_song_info and (browse_pack_download_song_info.title or browse_pack_download_song_info.folder_name or browse_pack_download_song_info.song_hash) or "nil"))
	showing_browse_pack_download_confirm = false
	browse_pack_download_confirm_index = 0
	browse_pack_download_song_info = nil
	if t then
		local prompt = t:GetChild("BrowsePackDownloadConfirmPrompt")
		if prompt then prompt:visible(false) end
	end
end

local function open_browse_pack_download_confirm(songInfo)
	if not songInfo or pack_sync_busy() then
		lobby_flow_trace("browse_pack_download_confirm_open skipped"
			.. " hasSongInfo=" .. tostring(songInfo ~= nil)
			.. " packSyncBusy=" .. tostring(pack_sync_busy() == true)
			.. " currentStatus=" .. tostring(ITGOnline and ITGOnline.PackSync and ITGOnline.PackSync.currentStatus or "nil")
			.. " key=" .. tostring(ITGOnline and ITGOnline.PackSync and ITGOnline.PackSync.downloadInFlightKey or "nil"))
		return false
	end
	lobby_flow_trace("browse_pack_download_confirm_open song="
		.. tostring(songInfo and (songInfo.title or songInfo.folder_name or songInfo.song_hash) or "nil")
		.. " pack=" .. tostring(song_info_pack(songInfo)))
	browse_pack_download_song_info = songInfo
	browse_pack_download_confirm_index = 0
	showing_browse_pack_download_confirm = true
	if t then
		local prompt = t:GetChild("BrowsePackDownloadConfirmPrompt")
		if prompt then
			prompt:visible(true)
			prompt:playcommand("Hover")
		end
	end
	return true
end

local function start_browse_pack_download(songInfo)
	if not songInfo then
		lobby_flow_trace("browse_pack_download_start skipped reason=no_song_info")
		return
	end
	if ITGOnline and ITGOnline.TraceOnlineState then
		ITGOnline:TraceOnlineState("ui_browse_pack_download_start", {
			source = "ScreenOnlineLobbies",
			title = songInfo and (songInfo.title or songInfo.folder_name or songInfo.song_hash) or "nil",
			pack = song_info_pack(songInfo),
			uiMode = mode,
			joinedPhase = joined_phase,
			activeIndex = joined_active_index,
		})
	end
	lobby_flow_trace("browse_pack_download_start song="
		.. tostring(songInfo and (songInfo.title or songInfo.folder_name or songInfo.song_hash) or "nil")
		.. " pack=" .. tostring(song_info_pack(songInfo))
		.. " room=" .. tostring(ITGOnline and ITGOnline.currentRoomId or "nil")
		.. " phase=" .. tostring(joined_phase))
	if not (ITGOnline and ITGOnline.PackSync and ITGOnline.PackSync.DownloadBrowsingPack) then
		lobby_flow_trace("browse_pack_download_start blocked reason=no_download_api")
		if t then
			t:playcommand("SetStatus", {
				text=online_lobby_text("EarlyPackDownloadUnavailable", "Early pack download is unavailable."),
				showSpinner=false,
				showPrompt=true
			})
		end
		return
	end
	refresh_joined_room_snapshot("browse_pack_download_start", t)
	ITGOnline.PackSync:DownloadBrowsingPack(songInfo, function(ok, message)
		if ITGOnline and ITGOnline.TraceOnlineState then
			ITGOnline:TraceOnlineState("ui_browse_pack_download_response", {
				source = "ScreenOnlineLobbies",
				ok = ok == true,
				messageType = type(message),
				kind = type(message) == "table" and message.kind or "nil",
				candidates = type(message) == "table" and message.candidates and #message.candidates or 0,
				pack = song_info_pack(songInfo),
				uiMode = mode,
			})
		end
		lobby_flow_trace("browse_pack_download_callback ok=" .. tostring(ok == true)
			.. " messageType=" .. tostring(type(message))
			.. " kind=" .. tostring(type(message) == "table" and message.kind or "nil")
			.. " candidates=" .. tostring(type(message) == "table" and message.candidates and #message.candidates or 0))
		refresh_joined_room_snapshot("browse_pack_download_callback", t)
		if ok and type(message) == "table" and message.kind == "pack_candidates" then
			open_pack_choice_menu(
				songInfo,
				message.candidates,
				message.message or online_lobby_text("MultiplePacksFound", "Several packs match. Choose one."),
				true
			)
			pack_choice_download_key = message.downloadKey
			if SL and SL.Global and SL.Global.Online then
				SL.Global.Online.PackChoiceRecovery.downloadKey = pack_choice_download_key
			end
			return
		end
		if not ok and t then
			t:playcommand("SetStatus", {
				text=message or online_lobby_text("PackDownloadFailedRetry", "Pack download failed.\nTry again or install the pack manually."),
				showSpinner=false,
				showPrompt=true
			})
		end
	end, {
		autoStartSingleCandidate = true,
		browseOnly = true,
	})
end

-- Input routing
-- -----------------------------------------------------------------------

local function handle_leave_confirm_input(event)
	if event.GameButton == "MenuRight" or event.GameButton == "MenuLeft" then
		leave_confirm_index = (leave_confirm_index + (event.GameButton=="MenuRight" and 1 or -1)) % 2
		lobby_flow_trace("leave_confirm_move button=" .. tostring(event.GameButton)
			.. " index=" .. tostring(leave_confirm_index)
			.. " mode=" .. tostring(leave_confirm_mode))
		play_online_sound_once("ScreenSelectMaster", "change")
		t:GetChild("LeaveConfirmPrompt"):playcommand("Hover")
	elseif event.GameButton == "Start" then
		lobby_flow_trace("leave_confirm_start index=" .. tostring(leave_confirm_index)
			.. " mode=" .. tostring(leave_confirm_mode)
			.. " joined_code=" .. tostring(joined_lobby_code)
			.. " currentRoomId=" .. tostring(ITGOnline and ITGOnline.currentRoomId or "nil")
			.. " leaving=" .. tostring(leaving_lobby == true))
		if ITGOnline and ITGOnline.TraceOnlineState then
			ITGOnline:TraceOnlineState("ui_leave_confirm_start", {
				source = "ScreenOnlineLobbies",
				confirmIndex = leave_confirm_index,
				leaveMode = leave_confirm_mode,
				joinedCode = joined_lobby_code,
				leaving = leaving_lobby == true,
			})
		end
		if leave_confirm_index == 1 then
			play_online_sound_once("Common", "Start")
			close_leave_confirm()
			if leave_confirm_mode == "exit_online" then
				lobby_flow_trace("leave_confirm_confirm_exit_online")
				local topScreen = SCREENMAN:GetTopScreen()
				if topScreen then
					topScreen:SetNextScreenName("ScreenTitleMenu")
					topScreen:StartTransitioningScreen("SM_GoToNextScreen")
				end
			else
				lobby_flow_trace("leave_confirm_confirm_leave_lobby")
				if begin_leave_lobby(t) then
					MESSAGEMAN:Broadcast("LeaveLobby", {
						roomId=SL.Global.Online.ScreenOnlineLobbiesLeaveRequestCode,
						generation=SL.Global.Online.ScreenOnlineLobbiesLeaveRequestGeneration,
					})
				else
					lobby_flow_trace("leave_confirm_leave_lobby_broadcast_skipped reason=begin_rejected")
				end
			end
		else
			play_online_sound_once("Common", "Cancel")
			lobby_flow_trace("leave_confirm_cancelled_by_start mode=" .. tostring(leave_confirm_mode))
			close_leave_confirm()
		end
	elseif event.GameButton == "Select" or event.GameButton == "Back" then
		play_online_sound_once("Common", "Cancel")
		lobby_flow_trace("leave_confirm_cancelled_by_button button=" .. tostring(event.GameButton)
			.. " mode=" .. tostring(leave_confirm_mode))
		close_leave_confirm()
	end
	return false
end

local function handle_browse_pack_download_confirm_input(event)
	if event.GameButton == "MenuRight" or event.GameButton == "MenuLeft" then
		lobby_flow_trace("input_browse_pack_download_confirm_move button=" .. tostring(event.GameButton)
			.. " index_before=" .. tostring(browse_pack_download_confirm_index))
		browse_pack_download_confirm_index = (browse_pack_download_confirm_index + (event.GameButton=="MenuRight" and 1 or -1)) % 2
		play_online_sound_once("ScreenSelectMaster", "change")
		t:GetChild("BrowsePackDownloadConfirmPrompt"):playcommand("Hover")
	elseif event.GameButton == "Start" then
		lobby_flow_trace("input_browse_pack_download_confirm_start index=" .. tostring(browse_pack_download_confirm_index)
			.. " song=" .. tostring(browse_pack_download_song_info and (browse_pack_download_song_info.title or browse_pack_download_song_info.folder_name or browse_pack_download_song_info.song_hash) or "nil"))
		if ITGOnline and ITGOnline.TraceOnlineState then
			ITGOnline:TraceOnlineState("ui_browse_pack_download_confirm_start", {
				source = "ScreenOnlineLobbies",
				confirmIndex = browse_pack_download_confirm_index,
				title = browse_pack_download_song_info and (browse_pack_download_song_info.title or browse_pack_download_song_info.folder_name or browse_pack_download_song_info.song_hash) or "nil",
				pack = song_info_pack(browse_pack_download_song_info),
			})
		end
		if browse_pack_download_confirm_index == 1 then
			local songInfo = browse_pack_download_song_info
			play_online_sound_once("Common", "Start")
			close_browse_pack_download_confirm()
			start_browse_pack_download(songInfo)
		else
			play_online_sound_once("Common", "Cancel")
			close_browse_pack_download_confirm()
		end
	elseif event.GameButton == "Select" or event.GameButton == "Back" then
		lobby_flow_trace("input_browse_pack_download_confirm_cancel button=" .. tostring(event.GameButton))
		play_online_sound_once("Common", "Cancel")
		close_browse_pack_download_confirm()
	end
	return false
end

local function handle_private_join_prompt_input(event)
	local promptOptions = active_private_prompt_options()
	lobby_flow_trace("input_private_join_prompt button=" .. tostring(event.GameButton)
		.. " kind=" .. tostring(private_join_prompt_kind)
		.. " index=" .. tostring(private_join_prompt_index)
		.. " options=" .. tostring(#promptOptions))
	if event.GameButton == "MenuRight" or event.GameButton == "MenuLeft" then
		private_join_prompt_index = ((private_join_prompt_index - 1 + (event.GameButton=="MenuRight" and 1 or -1)) % #promptOptions) + 1
		play_online_sound_once("ScreenSelectMaster", "change")
		t:queuecommand("UpdatePrivateJoinPrompt")
	elseif event.GameButton == "Start" then
		local option = promptOptions[private_join_prompt_index]
		if private_join_prompt_kind == "invitation" then
			local invitation = private_join_request and private_join_request.invitation
			if option and option.dismiss then
				finish_private_prompt(t)
				play_online_sound_once("Common", "Cancel")
			elseif option and invitation and invitation.id then
				finish_private_prompt(t)
				MESSAGEMAN:Broadcast("AnswerRoomInvitation", {
					invitation_id=invitation.id,
					accept=option.accept,
					localPlayer=private_join_request and private_join_request.localPlayer or "P1",
				})
				play_online_sound_once("Common", "Start")
			end
		else
			local request = private_join_request and private_join_request.join_request
			if option and request and request.id then
				finish_private_prompt(t)
				MESSAGEMAN:Broadcast("AnswerPrivateJoinRequest", {
					join_request_id=request.id,
					accept=option.accept,
					reason=option.reason,
				})
				play_online_sound_once("Common", "Start")
			end
		end
	elseif event.GameButton == "Select" or event.GameButton == "Back" then
		finish_private_prompt(t)
		play_online_sound_once("Common", "Cancel")
	end
	return false
end

local function handle_player_action_menu_input(event)
	lobby_flow_trace("input_player_action_menu button=" .. tostring(event.GameButton)
		.. " index=" .. tostring(player_action_index)
		.. " options=" .. tostring(#player_action_options)
		.. " user=" .. tostring(player_action_user and (player_action_user.playerId or player_action_user.id or player_action_user.name) or "nil"))
	if event.GameButton == "MenuRight" or event.GameButton == "MenuLeft" then
		player_action_index = ((player_action_index - 1 + (event.GameButton=="MenuRight" and 1 or -1)) % #player_action_options) + 1
		play_online_sound_once("ScreenSelectMaster", "change")
		t:queuecommand("UpdatePlayerActionMenu")
	elseif event.GameButton == "Start" then
		play_online_sound_once("Common", "Start")
		execute_player_action(player_action_options[player_action_index], player_action_user)
	elseif event.GameButton == "Select" or event.GameButton == "Back" then
		showing_player_action_menu = false
		t:GetChild("PlayerActionMenu"):visible(false)
		play_online_sound_once("Common", "Cancel")
	end
	return false
end

local function handle_pack_choice_menu_input(event)
	lobby_flow_trace("input_pack_choice_menu button=" .. tostring(event.GameButton)
		.. " index=" .. tostring(pack_choice_index)
		.. " candidates=" .. tostring(#pack_choice_candidates)
		.. " browseOnly=" .. tostring(pack_choice_browse_only == true)
		.. " downloadKey=" .. tostring(pack_choice_download_key or ""))
	if event.GameButton == "MenuRight" or event.GameButton == "MenuLeft" then
		pack_choice_index = ((pack_choice_index - 1 + (event.GameButton=="MenuRight" and 1 or -1)) % #pack_choice_candidates) + 1
		play_online_sound_once("ScreenSelectMaster", "change")
		update_pack_choice_menu()
	elseif event.GameButton == "Start" then
		local candidate = pack_choice_candidates[pack_choice_index]
		if candidate and ITGOnline and ITGOnline.PackSync and ITGOnline.PackSync.DownloadPackByCandidate then
			if ITGOnline and ITGOnline.TraceOnlineState then
				ITGOnline:TraceOnlineState("ui_pack_choice_download_start", {
					source = "ScreenOnlineLobbies",
					candidateIndex = pack_choice_index,
					candidateCount = #pack_choice_candidates,
					packId = candidate.id or "nil",
					packName = candidate.name or candidate.title or "",
					browseOnly = pack_choice_browse_only == true,
					downloadKey = pack_choice_download_key or "",
				})
			end
			play_online_sound_once("Common", "Start")
			pack_choice_last_selected_pack_id = tonumber(candidate.id)
			local browseOnly = pack_choice_browse_only
			if SL and SL.Global and SL.Global.Online then
				SL.Global.Online.PackChoiceRecovery = {
					songInfo = pack_choice_last_song_info or pack_choice_song_info,
					candidates = pack_choice_last_candidates,
					selectedPackId = pack_choice_last_selected_pack_id,
					downloadKey = pack_choice_download_key,
				}
			end
			local downloadKey = pack_choice_download_key
			local songInfo = pack_choice_song_info or joined_missing_song_info or joined_song_preview
			close_pack_choice_menu()
			refresh_joined_room_snapshot("pack_choice_download_start", t)
			ITGOnline.PackSync:DownloadPackByCandidate(songInfo, candidate, function(ok, message)
				if ITGOnline and ITGOnline.TraceOnlineState then
					ITGOnline:TraceOnlineState("ui_pack_choice_download_response", {
						source = "ScreenOnlineLobbies",
						ok = ok == true,
						messageType = type(message),
						packId = candidate.id or "nil",
						packName = candidate.name or candidate.title or "",
						browseOnly = browseOnly == true,
						downloadKey = downloadKey or "",
					})
				end
				refresh_joined_room_snapshot("pack_choice_download_callback", t)
				if not ok and t then
					t:playcommand("SetStatus", {
						text=message or online_lobby_text("PackDownloadFailedRetry", "Pack download failed.\nTry again or install the pack manually."),
						showSpinner=false,
						showPrompt=true
					})
				end
			end, { browseOnly = browseOnly, allowExistingDownloadKey = downloadKey })
		end
	elseif event.GameButton == "Select" or event.GameButton == "Back" then
		if pack_choice_requires_selection() then
			lobby_flow_trace("input_pack_choice_menu_cancel_blocked reason=confirmed_selection_requires_choice"
				.. " button=" .. tostring(event.GameButton)
				.. " candidates=" .. tostring(#pack_choice_candidates)
				.. " downloadKey=" .. tostring(pack_choice_download_key or ""))
			play_online_sound_once("Common", "invalid")
			update_pack_choice_menu()
		else
			play_online_sound_once("Common", "Cancel")
			close_pack_choice_menu(true)
		end
	end
	return false
end

local function handle_global_options_menu_input(event)
	lobby_flow_trace("input_global_options_menu button=" .. tostring(event.GameButton)
		.. " index=" .. tostring(global_options_index)
		.. " mode=" .. tostring(global_options_mode_label())
		.. " joined_phase=" .. tostring(joined_phase))
	if event.GameButton == "MenuRight" or event.GameButton == "MenuLeft" then
		move_global_options_choice(event.GameButton == "MenuRight" and 1 or -1)
		play_online_sound_once("ScreenSelectMaster", "change")
	elseif event.GameButton == "Start" then
		play_online_sound_once("Common", "Start")
		apply_global_options_choice()
	elseif event.GameButton == "Select" or event.GameButton == "Back" then
		play_online_sound_once("Common", "Cancel")
		close_global_options_menu()
	end
	return false
end

local function handle_transfer_manager_confirm_input(event)
	lobby_flow_trace("input_transfer_manager_confirm button=" .. tostring(event.GameButton)
		.. " index=" .. tostring(transfer_manager_confirm_index)
		.. " target=" .. tostring(transfer_manager_confirm_user and (transfer_manager_confirm_user.playerId or transfer_manager_confirm_user.profileName or transfer_manager_confirm_user.name) or "nil"))
	if event.GameButton == "MenuRight" or event.GameButton == "MenuLeft" then
		transfer_manager_confirm_index = transfer_manager_confirm_index == 0 and 1 or 0
		play_online_sound_once("ScreenSelectMaster", "change")
		if t then t:queuecommand("Hover") end
	elseif event.GameButton == "Start" then
		play_online_sound_once("Common", "Start")
		if transfer_manager_confirm_index == 1 and transfer_manager_confirm_user then
			local user = transfer_manager_confirm_user
			local action = transfer_manager_confirm_action
			close_transfer_manager_confirm()
			execute_player_action({
				label=action == "exclude_player"
					and online_lobby_text("RemoveFromLobby", "Remove from lobby")
					or online_lobby_text("TransferManager", "Transfer manager"),
				action=action,
			}, user)
		else
			close_transfer_manager_confirm()
		end
	elseif event.GameButton == "Select" or event.GameButton == "Back" then
		play_online_sound_once("Common", "Cancel")
		close_transfer_manager_confirm()
	end
	return false
end

local function handle_joined_mode_input(event)
	lobby_flow_trace("input_joined_mode button=" .. tostring(event.GameButton)
		.. " activeIndex=" .. tostring(joined_active_index)
		.. " playersSelected=" .. tostring(joined_players_selected == true)
		.. " phase=" .. tostring(joined_phase)
		.. " isManager=" .. tostring(joined_is_manager)
		.. " players=" .. tostring(#joined_lobby_players)
		.. " leaving=" .. tostring(leaving_lobby == true)
		.. " ready={" .. tostring(ready_summary()) .. "}")
	if leaving_lobby then
		lobby_flow_trace("input_joined_mode_ignored reason=leaving_lobby button=" .. tostring(event.GameButton))
		return false
	end

	if joined_players_selected then
		if event.GameButton == "MenuRight" or event.GameButton == "MenuLeft" then
			if #joined_lobby_players > 0 then
				local delta = event.GameButton == "MenuRight" and 1 or -1
				for _ = 1, #joined_lobby_players do
					joined_player_index = ((joined_player_index - 1 + delta) % #joined_lobby_players) + 1
					if joined_player_can_receive_manager(joined_lobby_players[joined_player_index]) then
						break
					end
				end
				play_online_sound_once("ScreenSelectMaster", "change")
				t:queuecommand("UpdateJoinedLobbyText")
			end
			return false
		elseif event.GameButton == "Start" then
			local player = selected_joined_player()
			lobby_flow_trace("input_joined_player_action_start player=" .. tostring(player and (player.playerId or player.id or player.profileName) or "nil")
				.. " canReceiveManager=" .. tostring(joined_player_can_receive_manager(player) == true))
			if joined_player_can_receive_manager(player) then
				player_action_user = joined_player_action_user(player)
				player_action_options = build_player_action_options(player_action_user)
				player_action_index = 1
				showing_player_action_menu = #player_action_options > 0
				local menu = t and t:GetChild("PlayerActionMenu")
				if menu then
					menu:visible(showing_player_action_menu)
					t:queuecommand("UpdatePlayerActionMenu")
				end
				play_online_sound_once("Common", "Start")
			else
				play_online_sound_once("Common", "Cancel")
			end
			return false
		elseif event.GameButton == "Select" or event.GameButton == "Back" then
			joined_players_selected = false
			play_online_sound_once("Common", "Cancel")
			t:queuecommand("UpdateJoinedLobbyText")
			return false
		end
	end

		if event.GameButton == "Back" then
		lobby_flow_trace("input_joined_back_open_leave_confirm")
		play_online_sound_once("Common", "Start")
		normalize_joined_active_index()
		joined_active_index = 1
		lobby_flow_trace("input_joined_action_resolved action=open_leave_confirm trigger=back activeIndex=" .. tostring(joined_active_index))
		open_leave_confirm("leave_lobby")
		return false
	end

	if event.GameButton == "MenuRight" or event.GameButton == "MenuLeft" then
		move_joined_button(event.GameButton == "MenuRight" and 1 or -1)
		play_online_sound_once("ScreenSelectMaster", "change")
		t:queuecommand("Hover")
	elseif event.GameButton == "Start" then
		normalize_joined_active_index()
		play_online_sound_once("Common", "Start")
		lobby_flow_trace("input_joined_start activeIndex=" .. tostring(joined_active_index)
			.. " phase=" .. tostring(joined_phase)
			.. " isManager=" .. tostring(joined_is_manager)
			.. " roomCanStart=" .. tostring(joined_room_can_start() == true)
			.. " missingSong=" .. tostring(joined_any_player_missing_song() == true)
			.. " canCancelSelection=" .. tostring(joined_can_cancel_song_selection() == true)
			.. " songTransitionLocked=" .. tostring(ITGOnline and ITGOnline.IsSongSelectionTransitionLocked and ITGOnline:IsSongSelectionTransitionLocked("ui") or false)
			.. " canDownload=" .. tostring(joined_can_download_pack == true or can_download_browsed_pack() == true))
		if joined_active_index == 1 then
			if ITGOnline and ITGOnline.TraceOnlineState then
				ITGOnline:TraceOnlineState("ui_joined_leave_pressed", {
					source = "ScreenOnlineLobbies",
					activeIndex = joined_active_index,
					uiMode = mode,
					joinedPhase = joined_phase,
				})
			end
			lobby_flow_trace("input_joined_leave_confirm strict_index=1")
			lobby_flow_trace("input_joined_action_resolved action=open_leave_confirm trigger=start activeIndex=" .. tostring(joined_active_index))
			open_leave_confirm("leave_lobby")
		elseif joined_active_index == 2 and joined_is_manager then
			if ITGOnline and ITGOnline.IsSongSelectionTransitionLocked and ITGOnline:IsSongSelectionTransitionLocked("joined_action") then
				local now = GetTimeSinceStart()
				if now - joined_song_transition_notice_at > 0.75 then
					joined_song_transition_notice_at = now
					lobby_flow_trace("input_joined_song_action_blocked reason=transition_inflight")
					t:playcommand("SetStatus", {
						text=online_lobby_text("SongSelectionUpdating", "Updating song selection..."),
						showSpinner=true,
						showPrompt=false,
						duration=1.5
					})
				end
				return false
			end
			if joined_can_cancel_song_selection() then
				if ITGOnline and ITGOnline.CancelSongSelection then
					if ITGOnline and ITGOnline.TraceOnlineState then
						ITGOnline:TraceOnlineState("ui_joined_cancel_song_pressed", {
							source = "ScreenOnlineLobbies",
							activeIndex = joined_active_index,
							uiMode = mode,
							joinedPhase = joined_phase,
							songTransitionLocked = ITGOnline.IsSongSelectionTransitionLocked and ITGOnline:IsSongSelectionTransitionLocked("ui") or false,
						})
					end
					lobby_flow_trace("input_joined_cancel_song_selection_request shared_index=2")
					lobby_flow_trace("input_joined_action_resolved action=cancel_song_selection activeIndex=" .. tostring(joined_active_index))
					t:playcommand("SetStatus", {
						text=online_lobby_text("CancellingSongSelection", "Cancelling song selection..."),
						showSpinner=true,
						showPrompt=false
					})
					ITGOnline:CancelSongSelection(function(ok, decoded, response)
						if ITGOnline and ITGOnline.TraceOnlineState then
							ITGOnline:TraceOnlineState("ui_joined_cancel_song_response", {
								source = "ScreenOnlineLobbies",
								roomSnapshot = decoded and decoded.room or nil,
								ok = ok == true,
								status = response and response.statusCode or "nil",
								hasRoom = decoded and decoded.room ~= nil,
							})
						end
						lobby_flow_trace("input_joined_cancel_song_selection_response ok=" .. tostring(ok == true)
							.. " status=" .. tostring(response and response.statusCode or "nil")
							.. " hasRoom=" .. tostring(decoded and decoded.room ~= nil))
						if not ok and t then
							t:playcommand("SetStatus", {
								text=(response and response.errorMessage) or (decoded and decoded.message)
									or online_lobby_text("CancelSongSelectionFailed", "Could not cancel the song selection."),
								showSpinner=false,
								showPrompt=true,
								duration=4
							})
						end
					end)
				else
					t:playcommand("SetStatus", {
						text=online_lobby_text("CancelSelectionUnavailable", "Cancelling the selection is unavailable in this version."),
						showSpinner=false,
						showPrompt=true,
						duration=4
					})
				end
				return false
			end
			if not joined_phase_allows_song_selection() then
				t:playcommand("SetStatus", {
					text=online_lobby_text("RoundStillFinishing", "The current round is still finishing. Wait for the results before choosing another song."),
					showSpinner=false,
					showPrompt=true
				})
				return false
			end
			local topScreen = SCREENMAN:GetTopScreen()
			if topScreen then
				if ITGOnline and ITGOnline.TraceOnlineState then
					ITGOnline:TraceOnlineState("ui_joined_select_music_transition", {
						source = "ScreenOnlineLobbies",
						screenFrom = topScreen:GetName(),
						screenTo = "ScreenSelectMusic",
						activeIndex = joined_active_index,
						joinedPhase = joined_phase,
					})
				end
				lobby_flow_trace("input_joined_select_music_transition")
				lobby_flow_trace("input_joined_action_resolved action=select_music activeIndex=" .. tostring(joined_active_index))
				topScreen:SetNextScreenName("ScreenSelectMusic")
				topScreen:StartTransitioningScreen("SM_GoToNextScreen")
			end
		elseif joined_active_index == 3 and show_pack_download_button() then
			if pack_sync_busy() then
				lobby_flow_trace("input_joined_download_pack_blocked reason=pack_sync_busy"
					.. " status=" .. tostring(ITGOnline and ITGOnline.PackSync and ITGOnline.PackSync.currentStatus or "nil")
					.. " key=" .. tostring(ITGOnline and ITGOnline.PackSync and ITGOnline.PackSync.downloadInFlightKey or "nil"))
				t:playcommand("SetStatus", {
					text=online_lobby_text("PackDownloadInProgress", "Pack download in progress..."),
					showSpinner=true,
					showPrompt=false
				})
				return false
			elseif can_download_browsed_pack() then
				lobby_flow_trace("input_joined_action_resolved action=open_browse_pack_download_confirm activeIndex=" .. tostring(joined_active_index))
				open_browse_pack_download_confirm(joined_song_preview)
			elseif joined_can_download_pack and ITGOnline and ITGOnline.PackSync and ITGOnline.PackSync.DownloadSelectedPack then
				if ITGOnline and ITGOnline.TraceOnlineState then
					ITGOnline:TraceOnlineState("ui_joined_download_selected_pack_start", {
						source = "ScreenOnlineLobbies",
						activeIndex = joined_active_index,
						joinedPhase = joined_phase,
						missingSong = joined_any_player_missing_song() == true,
						pack = song_info_pack(joined_missing_song_info or joined_song_preview),
					})
				end
				ITGOnline.PackSync:DownloadSelectedPack(joined_missing_song_info or joined_song_preview, function(ok, message)
					if ITGOnline and ITGOnline.TraceOnlineState then
						ITGOnline:TraceOnlineState("ui_joined_download_selected_pack_response", {
							source = "ScreenOnlineLobbies",
							ok = ok == true,
							messageType = type(message),
							kind = type(message) == "table" and message.kind or "nil",
							candidates = type(message) == "table" and message.candidates and #message.candidates or 0,
							pack = song_info_pack(joined_missing_song_info or joined_song_preview),
						})
					end
					lobby_flow_trace("input_joined_download_selected_pack_callback ok=" .. tostring(ok == true)
						.. " messageType=" .. tostring(type(message)))
					if ok and type(message) == "table" and message.kind == "pack_candidates" then
						open_pack_choice_menu(
							joined_missing_song_info or joined_song_preview,
							message.candidates,
							message.message or online_lobby_text("MultiplePacksFound", "Several packs match. Choose one.")
						)
						pack_choice_download_key = message.downloadKey
						if SL and SL.Global and SL.Global.Online then
							SL.Global.Online.PackChoiceRecovery.downloadKey = pack_choice_download_key
						end
						return
					end
					if not ok and t then
						t:playcommand("SetStatus", {
							text=message or online_lobby_text("PackDownloadFailedRetry", "Pack download failed.\nTry again or install the pack manually."),
							showSpinner=false,
							showPrompt=true
						})
					end
				end)
			else
				lobby_flow_trace("input_joined_action_resolved action=reload_songs activeIndex=" .. tostring(joined_active_index))
				transition_to_online_song_reload()
			end
		elseif joined_active_index == 4 and joined_is_manager then
			if joined_phase_allows_song_selection() then
				lobby_flow_trace("input_joined_action_resolved action=open_global_options activeIndex=" .. tostring(joined_active_index))
				open_global_options_menu()
			else
				t:playcommand("SetStatus", {
					text=online_lobby_text("GlobalOptionsLocked", "Global options cannot be changed during the round."),
					showSpinner=false,
					showPrompt=true
				})
			end
		elseif joined_active_index == 8 and joined_is_manager then
			if focus_joined_players() then
				lobby_flow_trace("input_joined_players_frame_start")
				lobby_flow_trace("input_joined_action_resolved action=focus_players activeIndex=" .. tostring(joined_active_index))
				t:queuecommand("UpdateJoinedLobbyText")
			else
				lobby_flow_trace("input_joined_players_frame_start_blocked")
				play_online_sound_once("Common", "Cancel")
			end
		elseif joined_active_index == 7 and joined_is_manager then
			if joined_room_can_start() then
				if ITGOnline and ITGOnline.TraceOnlineState then
					ITGOnline:TraceOnlineState("ui_joined_start_room_pressed", {
						source = "ScreenOnlineLobbies",
						activeIndex = joined_active_index,
						joinedPhase = joined_phase,
						roomCanStart = joined_room_can_start() == true,
						ready = ready_summary(),
					})
				end
				lobby_flow_trace("input_joined_start_room_broadcast")
				lobby_flow_trace("input_joined_action_resolved action=start_room activeIndex=" .. tostring(joined_active_index))
				MESSAGEMAN:Broadcast("StartOnlineRoom")
			else
				lobby_flow_trace("input_joined_start_room_blocked missingSong=" .. tostring(joined_any_player_missing_song() == true)
					.. " ready={" .. tostring(ready_summary()) .. "}")
				t:playcommand("SetStatus", {
					text=joined_any_player_missing_song() and "Impossible de lancer. Un joueur n'a pas confirme la chanson selectionnee." or "Impossible de lancer. Choisissez une chanson et attendez que chaque joueur soit pret.",
					showSpinner=false,
					showPrompt=true
				})
			end
		end
	end
	return false
end

local function handle_browse_mode_input(event)
	lobby_flow_trace("input_browse_mode button=" .. tostring(event.GameButton)
		.. " activeIndex=" .. tostring(active_index)
		.. " lobbyView=" .. tostring(lobby_view)
		.. " listSelected=" .. tostring(list_selected == true)
		.. " candidates=" .. tostring(#candidates)
		.. " onlinePlayers=" .. tostring(#online_users)
		.. " selectedLobbyIndex=" .. tostring(selected_lobby_index)
		.. " onlinePlayerIndex=" .. tostring(online_player_index)
		.. " connected=" .. tostring(connected == true))
	if event.GameButton == "MenuRight" or event.GameButton == "MenuLeft" then
		holding[event.GameButton] = true
		if holding[event.GameButton == "MenuRight" and "MenuLeft" or "MenuRight"] then
			if list_selected then
				list_selected = false
				play_online_sound_once("Common", "Cancel")
				lobby_flow_trace("input_browse_dual_direction_cancel_focus"
					.. " button=" .. tostring(event.GameButton)
					.. " lobbyView=" .. tostring(lobby_view)
					.. " activeIndex=" .. tostring(active_index)
					.. " onlinePlayerIndex=" .. tostring(online_player_index)
					.. " selectedLobbyIndex=" .. tostring(selected_lobby_index))
				t:queuecommand("LoseFocus")
				request_lobby_ui_repaint(t, "browse_cancel_dual_direction")
				t:queuecommand("Hover")
			end
		else
			if not list_selected then
				local previousIndex = active_index
				active_index = (active_index + (event.GameButton=="MenuRight" and 1 or -1)) % #options
				play_online_sound_once("ScreenSelectMaster", "change")
				lobby_flow_trace("input_browse_option_changed"
					.. " button=" .. tostring(event.GameButton)
					.. " previousIndex=" .. tostring(previousIndex)
					.. " nextIndex=" .. tostring(active_index)
					.. " options=" .. tostring(#options)
					.. " mode=" .. tostring(mode)
					.. " candidates=" .. tostring(#candidates)
					.. " onlinePlayers=" .. tostring(#online_users))
				request_lobby_ui_repaint(t, "browse_option_changed")
				t:queuecommand("Hover")
			else
				if lobby_view == "players" then
					if #online_users > 0 then
						local previousPlayerIndex = online_player_index
						online_player_index = ((online_player_index - 1 + (event.GameButton=="MenuRight" and 1 or -1)) % #online_users) + 1
						play_online_sound_once("ScreenSelectMaster", "change")
						lobby_flow_trace("input_browse_player_selection_changed"
							.. " button=" .. tostring(event.GameButton)
							.. " previousIndex=" .. tostring(previousPlayerIndex)
							.. " nextIndex=" .. tostring(online_player_index)
							.. " onlinePlayers=" .. tostring(#online_users))
						request_lobby_ui_repaint(t, "browse_player_selection_changed")
					else
						lobby_flow_trace("input_browse_player_selection_ignored reason=no_online_players"
							.. " button=" .. tostring(event.GameButton))
					end
				else
					lobby_flow_trace("input_browse_lobby_selection_navigate"
						.. " button=" .. tostring(event.GameButton)
						.. " candidates=" .. tostring(#candidates)
						.. " selectedLobbyIndex=" .. tostring(selected_lobby_index))
					if event.GameButton == "MenuRight" then
						t:queuecommand("NextLobby")
					else
						t:queuecommand("PrevLobby")
					end
				end
			end
		end
	elseif event.GameButton == "Start" then
		if list_selected then
			if lobby_view == "players" then
				if selected_online_user() then
					if ITGOnline and ITGOnline.TraceOnlineState then
						local user = selected_online_user()
						ITGOnline:TraceOnlineState("ui_browse_player_action_open", {
							source = "ScreenOnlineLobbies",
							lobbyView = lobby_view,
							onlinePlayerIndex = online_player_index,
							onlinePlayers = #online_users,
							targetUser = user and (user.id or user.playerId or user.name) or "nil",
						})
					end
					play_online_sound_once("Common", "Start")
					t:queuecommand("OpenPlayerActionMenu")
				else
					play_online_sound_once("Common", "Cancel")
				end
			else
				local lobbyList = t:GetChild("LobbyContent") and t:GetChild("LobbyContent"):GetChild("LobbyList")
				if lobbyList then
					if ITGOnline and ITGOnline.TraceOnlineState then
						ITGOnline:TraceOnlineState("ui_browse_lobby_select", {
							source = "ScreenOnlineLobbies",
							lobbyView = lobby_view,
							selectedLobbyIndex = selected_lobby_index,
							candidates = #candidates,
						})
					end
					play_online_sound_once("Common", "Start")
					lobbyList:playcommand("SelectLobby")
				else
					play_online_sound_once("Common", "Cancel")
				end
			end
			return false
		end

		if active_index == 0 or active_index == 1 then
			lobby_view = active_index == 1 and "players" or "lobbies"
			lobby_flow_trace("input_browse_start_focus_list lobbyView=" .. tostring(lobby_view)
				.. " candidates=" .. tostring(#candidates)
				.. " onlinePlayers=" .. tostring(#online_users))
			if ITGOnline and ITGOnline.TraceOnlineState then
				ITGOnline:TraceOnlineState("ui_browse_focus_list_start", {
					source = "ScreenOnlineLobbies",
					lobbyView = lobby_view,
					activeIndex = active_index,
					candidates = #candidates,
					onlinePlayers = #online_users,
					listSelected = list_selected == true,
				})
			end
			local lobbyList = t:GetChild("LobbyContent") and t:GetChild("LobbyContent"):GetChild("LobbyList")
			local lobbyHasSelectableRoom = lobbyList and lobbyList.hasSelectableRoom == true
			if (lobby_view == "lobbies" and lobbyHasSelectableRoom) or (lobby_view == "players" and #online_users > 0) then
				list_selected = true
				play_online_sound_once("Common", "Start")
				lobby_flow_trace("input_browse_focus_list_applied"
					.. " lobbyView=" .. tostring(lobby_view)
					.. " candidates=" .. tostring(#candidates)
					.. " onlinePlayers=" .. tostring(#online_users)
					.. " selectedLobbyIndex=" .. tostring(selected_lobby_index)
					.. " onlinePlayerIndex=" .. tostring(online_player_index))
				focus_selected_browse_list(t)
				request_lobby_ui_repaint(t, "browse_focus_list")
			else
				lobby_flow_trace("input_browse_focus_list_rejected"
					.. " lobbyView=" .. tostring(lobby_view)
					.. " candidates=" .. tostring(#candidates)
					.. " onlinePlayers=" .. tostring(#online_users)
					.. " activeIndex=" .. tostring(active_index))
				play_online_sound_once("Common", "Cancel")
			end
		elseif active_index == 2 then
			play_online_sound_once("Common", "Start")
			local onlineHandler = GetOnlineHandlerInstance()
			if onlineHandler and onlineHandler.connected then
				lobby_flow_trace("input_browse_refresh_requested")
				if ITGOnline and ITGOnline.TraceOnlineState then
					ITGOnline:TraceOnlineState("ui_browse_manual_refresh", {
						source = "ScreenOnlineLobbies",
						connected = true,
						candidates = #candidates,
						onlinePlayers = #online_users,
						lobbyView = lobby_view,
					})
				end
				t:playcommand("SetStatus", {
					text=online_lobby_text("SearchingLobbies", "Searching for lobbies..."),
					showSpinner=true,
					showPrompt=false
				})
				request_lobby_refresh("browse_manual_refresh", { immediate=true }, t)
			else
				lobby_flow_trace("input_browse_refresh_reconnect")
				if ITGOnline and ITGOnline.TraceOnlineState then
					ITGOnline:TraceOnlineState("ui_browse_refresh_reconnect", {
						source = "ScreenOnlineLobbies",
						connected = false,
						hasError = has_error == true,
						attempted = attempted == true,
					})
				end
				connected = false
				has_error = false
				attempted = false
				wait_time = 0
				t:GetChild("LobbyContent"):visible(false)
				t:GetChild("OnlinePlayersContent"):visible(false)
				t:playcommand("SetStatus", {
					text=online_lobby_text("RefreshingLobbies", "Refreshing lobby list..."),
					showSpinner=true,
					showPrompt=false
				})
				t:queuecommand("CheckConnect")
			end
		elseif active_index == 4 then
			lobby_flow_trace("input_browse_exit_to_title")
			play_online_sound_once("Common", "Start")
			local topScreen = SCREENMAN:GetTopScreen()
			if topScreen then
				topScreen:SetNextScreenName("ScreenTitleMenu")
				topScreen:StartTransitioningScreen("SM_GoToNextScreen")
			end
		elseif active_index == 3 then
			play_online_sound_once("Common", "Start")
			local onlineHandler = GetOnlineHandlerInstance()
			if not (onlineHandler and onlineHandler.connected and onlineHandler.socket ~= nil) then
				lobby_flow_trace("input_browse_create_blocked reason=not_connected")
				t:playcommand("SetStatus", {
					text=online_lobby_text("ServiceConnectingRetry", "Connecting to the online service. Try again in a moment."),
					showSpinner=false,
					showPrompt=true
				})
				t:queuecommand("CheckConnect")
				return false
			end
			t:GetChild("LobbyContent"):visible(false)
			t:GetChild("OnlinePlayersContent"):visible(false)
			t:playcommand("SetStatus", {
				text=online_lobby_text("CreatingLobby", "Creating lobby..."),
				showSpinner=true,
				showPrompt=false
			})
			begin_create_timeout(t)
			lobby_flow_trace("input_browse_create_broadcast")
			MESSAGEMAN:Broadcast("CreateLobby", {})
		end
	elseif event.GameButton == "Select" or event.GameButton == "Back" then
		if list_selected then
			lobby_flow_trace("input_browse_unfocus_list button=" .. tostring(event.GameButton))
			list_selected = false
			play_online_sound_once("Common", "Cancel")
			t:queuecommand("LoseFocus")
			t:queuecommand("Hover")
		elseif event.GameButton == "Back" then
			lobby_flow_trace("input_browse_back_open_exit_confirm")
			play_online_sound_once("Common", "Start")
			open_leave_confirm("exit_online")
		end
	end
	return false
end

local function handle_first_press_input(event)
	lobby_flow_trace("input_first_press_route button=" .. tostring(event.GameButton)
		.. " mode=" .. tostring(mode)
		.. " connected=" .. tostring(connected == true)
		.. " hasError=" .. tostring(has_error == true)
		.. " leaveConfirm=" .. tostring(showing_leave_confirm == true)
		.. " browsePackConfirm=" .. tostring(showing_browse_pack_download_confirm == true)
		.. " privatePrompt=" .. tostring(showing_private_join_prompt == true)
		.. " transferManagerConfirm=" .. tostring(showing_transfer_manager_confirm == true)
		.. " playerAction=" .. tostring(showing_player_action_menu == true)
		.. " packChoice=" .. tostring(showing_pack_choice_menu == true)
		.. " globalOptions=" .. tostring(showing_global_options_menu == true)
		.. " pendingJoinActionId=" .. tostring(pending_join_action_id))
	if showing_leave_confirm then return handle_leave_confirm_input(event) end
	if showing_browse_pack_download_confirm then return handle_browse_pack_download_confirm_input(event) end
	if showing_transfer_manager_confirm then return handle_transfer_manager_confirm_input(event) end
	if showing_private_join_prompt then return handle_private_join_prompt_input(event) end
	if showing_player_action_menu then return handle_player_action_menu_input(event) end

	if has_error and event.GameButton == "Start" then
		lobby_flow_trace("input_first_press_error_start_exit")
		local topScreen = SCREENMAN:GetTopScreen()
		if topScreen then
			topScreen:SetNextScreenName("ScreenTitleMenu")
			topScreen:StartTransitioningScreen("SM_GoToNextScreen")
		end
		return false
	end

	if showing_pack_choice_menu then return handle_pack_choice_menu_input(event) end
	if not connected then
		lobby_flow_trace("input_first_press_ignored reason=not_connected button=" .. tostring(event.GameButton))
		return false
	end

	if pending_join_action_id > 0 and (event.GameButton == "Select" or event.GameButton == "Back") then
		lobby_flow_trace("input_first_press_cancel_pending_join button=" .. tostring(event.GameButton)
			.. " pendingJoinActionId=" .. tostring(pending_join_action_id))
		play_online_sound_once("Common", "Cancel")
		cancel_pending_join(online_lobby_text("JoinCancelledRefreshing", "Connection cancelled. Refreshing lobbies..."))
		return false
	end

	if showing_global_options_menu then return handle_global_options_menu_input(event) end
	if mode == "joined" then return handle_joined_mode_input(event) end
	return handle_browse_mode_input(event)
end

local function should_suppress_input_during_quiet_window(event)
	local now = GetTimeSinceStart()
	if now >= input_quiet_until then return false end
	if mode == "browse"
		and event
		and (event.GameButton == "MenuRight" or event.GameButton == "MenuLeft") then
		lobby_flow_trace("quiet_window_input_allowed reason=browse_navigation"
			.. " button=" .. tostring(event.GameButton)
			.. " remaining=" .. tostring(input_quiet_until - now))
		return false
	end
	lobby_flow_trace("quiet_window_input_blocked reason=protected_action"
		.. " button=" .. tostring(event and event.GameButton or "nil")
		.. " type=" .. tostring(event and event.type or "nil")
		.. " mode=" .. tostring(mode)
		.. " remaining=" .. tostring(input_quiet_until - now))
	return true
end

local InputHandler = function(event)
	local inputType = tostring(event and event.type or "")
	if (inputType == "InputEventType_FirstPress" or inputType == "FirstPress")
		and ITGOnline and ITGOnline.MarkUserActivity then
		-- Activity is transport-level, not UI-level.  Even an unmapped key or a
		-- key consumed by a modal proves that the player is still present.
		ITGOnline:MarkUserActivity("lobby_input:" .. tostring(event and (event.GameButton or event.button) or "unknown"))
	end
	if not event or not event.PlayerNumber or not event.button then return false end
	if not t then return false end
	if ITGOnline
		and ITGOnline.CanLocalPlayerControlOnlineRoom
		and not ITGOnline:CanLocalPlayerControlOnlineRoom(event.PlayerNumber)
	then
		lobby_flow_trace("input_ignored reason=local_companion_read_only"
			.. " player=" .. tostring(event.PlayerNumber)
			.. " type=" .. tostring(event.type)
			.. " button=" .. tostring(event.GameButton or event.button)
			.. " mode=" .. tostring(mode)
			.. " room=" .. tostring(ITGOnline.currentRoomId or "nil"))
		return true
	end
	if not is_active_lobby_overlay() then
		lobby_flow_trace("input_ignored reason=inactive_overlay type=" .. tostring(event.type)
			.. " button=" .. tostring(event.GameButton or event.button))
		return false
	end
	event.GameButton = online_menu_button(event.GameButton)
	lobby_flow_trace("input_dispatch"
		.. " type=" .. tostring(event.type)
		.. " button=" .. tostring(event.GameButton)
		.. " rawButton=" .. tostring(event.button)
		.. " player=" .. tostring(event.PlayerNumber)
		.. " mode=" .. tostring(mode)
		.. " joinedCode=" .. tostring(joined_lobby_code or "")
		.. " currentRoomId=" .. tostring(ITGOnline and ITGOnline.currentRoomId or "nil")
		.. " showingLeaveConfirm=" .. tostring(showing_leave_confirm == true)
		.. " showingPackConfirm=" .. tostring(showing_browse_pack_download_confirm == true)
		.. " showingPlayerAction=" .. tostring(showing_player_action_menu == true)
		.. " showingPackChoice=" .. tostring(showing_pack_choice_menu == true)
		.. " showingGlobalOptions=" .. tostring(showing_global_options_menu == true)
		.. " listSelected=" .. tostring(list_selected == true)
		.. " lobbyView=" .. tostring(lobby_view)
		.. " activeIndex=" .. tostring(active_index)
		.. " joinedActiveIndex=" .. tostring(joined_active_index)
		.. " joinedPlayersSelected=" .. tostring(joined_players_selected == true)
		.. " joinedPlayerIndex=" .. tostring(joined_player_index)
		.. " joinedPhase=" .. tostring(joined_phase)
		.. " joinedIsManager=" .. tostring(joined_is_manager == true)
		.. " joinedSongConfirmed=" .. tostring(joined_song_confirmed == true)
		.. " joinedMissingSong=" .. tostring(joined_missing_song == true)
		.. " joinedCanDownload=" .. tostring(joined_can_download_pack == true)
		.. " packBusy=" .. tostring(pack_sync_busy() == true)
		.. " canDownloadBrowsedPack=" .. tostring(can_download_browsed_pack() == true))

	if should_suppress_input_during_quiet_window(event) then
		lobby_flow_trace("input_ignored reason=quiet_window type=" .. tostring(event.type)
			.. " button=" .. tostring(event.GameButton)
			.. " until=" .. tostring(input_quiet_until))
		if event.type == "InputEventType_Release"
			and (event.GameButton == "MenuRight" or event.GameButton == "MenuLeft") then
			holding[event.GameButton] = false
		end
		return true
	end

	if duplicate_first_press(event) then
		lobby_flow_trace("input_ignored reason=duplicate_first_press button=" .. tostring(event.GameButton)
			.. " player=" .. tostring(event.PlayerNumber))
		return true
	end

	if event.type == "InputEventType_FirstPress" then
		lobby_flow_trace("input_first_press button=" .. tostring(event.GameButton)
			.. " player=" .. tostring(event.PlayerNumber)
			.. " mode=" .. tostring(mode)
			.. " activeIndex=" .. tostring(active_index)
			.. " joinedActiveIndex=" .. tostring(joined_active_index))
		handle_first_press_input(event)
		return true
	elseif event.type == "InputEventType_Release" then
		lobby_flow_trace("input_release button=" .. tostring(event.GameButton)
			.. " player=" .. tostring(event.PlayerNumber))
		if event.GameButton == "MenuRight" or event.GameButton == "MenuLeft" then
			holding[event.GameButton] = false
		end
		return true
	end
	return true
end

local wait_time = 0
local attempted = false
local input_screen = nil

local function registered_lobby_input_handlers()
	SL.Global.Online = SL.Global.Online or {}
	local handlers = SL.Global.Online.ScreenOnlineLobbiesInputHandlers
	if type(handlers) ~= "table" then
		handlers = {}
		SL.Global.Online.ScreenOnlineLobbiesInputHandlers = handlers
	end
	return handlers
end

local function remove_registered_lobby_input_callbacks()
	local handlers = registered_lobby_input_handlers()
	for _, entry in ipairs(handlers) do
		if entry and entry.handler then
			local screen = entry.screen or SCREENMAN:GetTopScreen()
			if screen and screen.RemoveInputCallback then
				pcall(function() screen:RemoveInputCallback(entry.handler) end)
			end
			if screen and screen.SetInputCallbacksHandleBeforeScreen then
				pcall(function() screen:SetInputCallbacksHandleBeforeScreen(false) end)
			end
		end
	end
	for i=#handlers, 1, -1 do
		handlers[i] = nil
	end
	input_screen = nil
	input_added = false
end

local function install_lobby_input_callback(screen)
	if not screen then return end
	remove_registered_lobby_input_callbacks()
	if screen.SetInputCallbacksHandleBeforeScreen then
		pcall(function() screen:SetInputCallbacksHandleBeforeScreen(true) end)
	end
	if screen.RemoveInputCallback then
		pcall(function() screen:RemoveInputCallback(InputHandler) end)
	end
	screen:AddInputCallback(InputHandler)
	input_screen = screen
	input_added = true
	local handlers = registered_lobby_input_handlers()
	handlers[#handlers + 1] = { screen = screen, handler = InputHandler }
end

-- Actor tree
-- -----------------------------------------------------------------------

local af = Def.ActorFrame{
	OnCommand=function(self)
		t=self
		SL.Global.Online = SL.Global.Online or {}
		SL.Global.Online.ScreenOnlineLobbiesActiveInstance = overlay_instance_id
		lobby_flow_trace("overlay_on instance=" .. tostring(overlay_instance_id)
			.. " mode=" .. tostring(mode)
			.. " currentRoomId=" .. tostring(ITGOnline and ITGOnline.currentRoomId or "nil")
			.. " currentPhase=" .. tostring(ITGOnline and ITGOnline.currentRoom and ITGOnline.currentRoom.phase or "nil")
			.. " screenGeneration=" .. tostring(ITGOnline and ITGOnline.screenGeneration or "nil"))
		reset_browse_focus()
		leave_confirm_mode = "leave_lobby"
		showing_leave_confirm = false
		holding.MenuLeft = false
		holding.MenuRight = false
		self:Center()
		local screen = SCREENMAN:GetTopScreen()
		install_lobby_input_callback(screen)
		self:playcommand("SetStatus", {
			text=online_lobby_text("InitializingOnlineConnection", "Initializing online connection..."),
				showSpinner=true
			})
		self:queuecommand("RefreshCurrentRoomSnapshot")
		self:queuecommand("RestoreActiveSongPreview")
		self:queuecommand("CheckConnect")
	end,
	RestoreActiveSongPreviewCommand=function(self)
		restore_active_song_preview(self, "lobby_overlay_on")
	end,
	OffCommand=function(self)
			lobby_flow_trace("overlay_off instance=" .. tostring(overlay_instance_id)
				.. " active=" .. tostring(is_active_lobby_overlay() == true)
				.. " mode=" .. tostring(mode)
				.. " leaving=" .. tostring(leaving_lobby == true)
				.. " currentRoomId=" .. tostring(ITGOnline and ITGOnline.currentRoomId or "nil"))
			if is_active_lobby_overlay() then
				SL.Global.Online.ScreenOnlineLobbiesActiveInstance = nil
			end
			remove_registered_lobby_input_callbacks()
			holding.MenuLeft = false
			holding.MenuRight = false
			t = nil
			local onlineHandler = GetOnlineHandlerInstance()
			if onlineHandler and onlineHandler.connected and not onlineHandler.inLobby then
				MESSAGEMAN:Broadcast("DisconnectOnline")
		end
	end,
	Def.Actor{
		Name="PackSyncCountdownTimer",
		OnCommand=function(self)
			self:queuecommand("Tick")
		end,
		TickCommand=function(self)
			if is_active_lobby_overlay() and mode == "joined"
				and joined_missing_song_countdown_seconds() ~= nil then
				local root = self:GetParent()
				if root then
					root:queuecommand("UpdateJoinedLobbyText")
				end
			end
			self:sleep(1):queuecommand("Tick")
		end,
	},
	Def.Actor{
		Name="JoinTimeoutTimer",
		CheckJoinTimeoutCommand=function(self)
			lobby_flow_trace("join_timeout_check actionId=" .. tostring(pending_join_action_id)
				.. " now=" .. tostring(GetTimeSinceStart())
				.. " deadline=" .. tostring(pending_join_deadline))
			if pending_join_action_id > 0 and GetTimeSinceStart() >= pending_join_deadline then
					cancel_pending_join(online_lobby_text("JoinLobbyTimeout", "The attempt to join the lobby timed out. Refreshing..."))
			else
				lobby_flow_trace("join_timeout_check_ok actionId=" .. tostring(pending_join_action_id))
			end
		end
	},
		Def.Actor{
			Name="CreateTimeoutTimer",
			CheckCreateTimeoutCommand=function(self)
				lobby_flow_trace("create_timeout_check actionId=" .. tostring(pending_create_action_id)
					.. " now=" .. tostring(GetTimeSinceStart())
					.. " deadline=" .. tostring(pending_create_deadline))
				if pending_create_action_id > 0 and GetTimeSinceStart() >= pending_create_deadline then
					cancel_pending_create(online_lobby_text("CreateLobbyTimeout", "Lobby creation timed out. Check the connection and try again."))
				else
					lobby_flow_trace("create_timeout_check_ok actionId=" .. tostring(pending_create_action_id))
				end
			end
		},
			Def.Actor{
				Name="NetworkStatusClearTimer",
				FireCommand=function(self)
					lobby_flow_trace("network_status_clear_timer_fire now=" .. tostring(GetTimeSinceStart())
						.. " clearAt=" .. tostring(network_status_clear_at))
					local parent = self:GetParent()
					if parent then parent:playcommand("ClearTransientStatus") end
				end
			},
			Def.Actor{
				Name="LobbySearchStabilizationTimer",
				ApplyCommand=function(self)
					lobby_flow_trace("lobby_search_stabilization_timer_apply pending=" .. tostring(lobby_search_ui_pending == true))
					local parent = self:GetParent()
					if parent then parent:playcommand("ApplyDeferredLobbySearch") end
				end
			},
			Def.Actor{
				Name="LobbyUiUpdateTimer",
				ApplyCommand=function(self)
					lobby_flow_trace("lobby_ui_update_timer_apply pending=" .. tostring(lobby_ui_update_pending == true))
					local parent = self:GetParent()
					if parent then parent:playcommand("ApplyQueuedLobbyUiUpdate") end
				end
			},
			Def.Actor{
				Name="RealtimeIndicatorTimer",
				OnCommand=function(self)
					self:sleep(0.5):queuecommand("Fire")
				end,
				FireCommand=function(self)
					local parent = self:GetParent()
					if parent then parent:playcommand("UpdateRealtimeIndicator") end
					self:sleep(0.5):queuecommand("Fire")
				end
			},
			Def.Actor{
				Name="PackSyncKickWarningTimer",
				OnCommand=function(self)
					self:sleep(0.5):queuecommand("Refresh")
				end,
				RefreshCommand=function(self)
					local parent = self:GetParent()
					if parent then parent:playcommand("UpdatePackSyncKickWarning") end
					self:sleep(0.5):queuecommand("Refresh")
				end
			},
		HoverCommand=function(self)
			self:GetChild("LobbyContent"):playcommand("Hover")
			self:GetChild("OnlinePlayersContent"):playcommand("Hover")
			self:GetChild("JoinedLobbyContent"):playcommand("Hover")
			local transferPrompt = self:GetChild("TransferManagerConfirmPrompt")
			if transferPrompt then transferPrompt:playcommand("Hover") end
		end,
		UpdateRealtimeIndicatorCommand=function(self)
			if ITGOnline and ITGOnline.BroadcastRealtimeHealth then
				ITGOnline:BroadcastRealtimeHealth("screen_indicator")
			end
			local indicator = self:GetChild("RealtimeIndicator")
			if indicator then
				indicator:playcommand("Set", realtime_health_snapshot())
			end
		end,
		UpdatePackSyncKickWarningCommand=function(self)
			update_joined_download_kick_warning(self)
		end,
		OnlineRealtimeHealthMessageCommand=function(self, params)
			local indicator = self:GetChild("RealtimeIndicator")
			if indicator then
				indicator:playcommand("Set", params or realtime_health_snapshot())
			end
		end,
		ApplyQueuedLobbyUiUpdateCommand=function(self)
			local reason = lobby_ui_update_reason
			lobby_ui_update_pending = false
			lobby_ui_update_reason = ""

			if not is_active_lobby_overlay() then
				lobby_flow_trace("lobby_ui_update_skipped reason=inactive pendingReason=" .. tostring(reason))
				return
			end

			lobby_flow_trace("lobby_ui_update_apply reason=" .. tostring(reason))
			self:playcommand("UpdateLobbyView")
			self:playcommand("Hover")
		end,
	UpdateOnlinePlayersCommand=function(self)
		local playersContent = self:GetChild("OnlinePlayersContent")
		if not playersContent then
			lobby_flow_trace("UpdateOnlinePlayers_aborted reason=no_players_content")
			return
		end
		lobby_flow_trace("UpdateOnlinePlayers_begin onlinePlayers=" .. tostring(#online_users)
			.. " selectedIndex=" .. tostring(online_player_index)
			.. " lobbyView=" .. tostring(lobby_view)
			.. " listSelected=" .. tostring(list_selected == true)
			.. " mode=" .. tostring(mode))

		if #online_users == 0 then
			online_player_index = 1
		else
			online_player_index = math.max(1, math.min(online_player_index, #online_users))
		end

		local lines = {}
		local renderParts = {}
		local selected_start = nil
		local selected_length = nil
		local text_length = 0
		for i, user in ipairs(online_users) do
			local selected = (list_selected and lobby_view == "players" and i == online_player_index) and "> " or "  "
			local roomLabel = user.room and ITGOnlineProtocol and ITGOnlineProtocol.online_player_room_label
				and ITGOnlineProtocol.online_player_room_label(user.room, {
					private=THEME:GetString("ScreenOnlineLobbies", "PrivateLobby"),
					public=THEME:GetString("ScreenOnlineLobbies", "PublicLobby"),
					generic=THEME:GetString("ScreenOnlineLobbies", "Lobby"),
				})
				or ""
			local room = roomLabel ~= "" and (" " .. roomLabel) or ""
			local status = user.status and (" [" .. tostring(user.status) .. "]") or ""
			local unknownPlayer = online_lobby_text("UnknownPlayer", "Player")
			local display_name = ITGOnline and ITGOnline.UserDisplayName and ITGOnline:UserDisplayName(user, unknownPlayer)
				or tostring(user.display_name or user.displayName or user.name or unknownPlayer)
			local partyLabel = ""
			if user.isLocalCompanion then
				partyLabel = " " .. online_lobby_text("WithYou", "(with you)")
			elseif tostring(user.partyCompanionName or "") ~= "" then
				partyLabel = " " .. online_lobby_text(
					"WithPlayer",
					"(with %s)",
					clamp_text(tostring(user.partyCompanionName), 24)
				)
			end
			-- Keep the room suffix intact: it carries the room number required to
			-- identify private rooms. The actor's maxwidth handles final scaling.
			local line = selected .. i .. ". " .. clamp_text(display_name, 24) .. partyLabel .. status .. room
			if list_selected and lobby_view == "players" and i == online_player_index then
				selected_start = text_length
				selected_length = online_utf8_length(line)
			end
			lines[#lines + 1] = line
			text_length = text_length + online_utf8_length(line) + 1
		end

		local playersList = playersContent:GetChild("OnlinePlayersList")
		if playersList then
			playersList:settext(#lines > 0 and table.concat(lines, "\n")
				or online_lobby_text("NoOnlinePlayers", "No online players found."))
			playersList:ClearAttributes()
			if selected_start and selected_length and selected_length > 0 then
				playersList:AddAttribute(selected_start, {Length=selected_length, Diffuse={0,1,0,1}})
			end
		end

		local playerCount = playersContent:GetChild("OnlinePlayersCount")
		if playerCount then
			playerCount:settext(tostring(#online_users))
		end
		lobby_flow_trace("UpdateOnlinePlayers_end onlinePlayers=" .. tostring(#online_users)
			.. " selectedIndex=" .. tostring(online_player_index)
			.. " renderedLines=" .. tostring(#lines))
	end,
	UpdateLobbyViewCommand=function(self)
		lobby_flow_trace("UpdateLobbyView_begin mode=" .. tostring(mode)
			.. " candidates=" .. tostring(#candidates)
			.. " onlinePlayers=" .. tostring(#online_users)
			.. " selectedLobbyIndex=" .. tostring(selected_lobby_index)
			.. " joined_code=" .. tostring(joined_lobby_code)
			.. " currentRoomId=" .. tostring(ITGOnline and ITGOnline.currentRoomId or "nil"))
		local lobbyContent = self:GetChild("LobbyContent")
		local playersContent = self:GetChild("OnlinePlayersContent")
		if lobbyContent then
			lobbyContent:visible(mode ~= "joined")
			local lobbyList = lobbyContent:GetChild("LobbyList")
			if lobbyList then lobbyList:visible(true) end
		end
		if playersContent then playersContent:visible(mode ~= "joined") end

		local emptyText = lobbyContent and lobbyContent:GetChild("EmptyStateText")
		if emptyText then
			emptyText:visible(#candidates == 0)
		end

		self:playcommand("UpdateOnlinePlayers")
		lobby_flow_trace("UpdateLobbyView_end lobbyVisible=" .. tostring(mode ~= "joined")
			.. " empty=" .. tostring(#candidates == 0)
			.. " appliedUpdateOnlinePlayers=true")
	end,
	OpenPlayerActionMenuCommand=function(self)
		player_action_user = selected_online_user()
		player_action_options = build_player_action_options(player_action_user)
		player_action_index = 1
		showing_player_action_menu = player_action_user ~= nil and #player_action_options > 0
		local menu = self:GetChild("PlayerActionMenu")
		if menu then
			menu:visible(showing_player_action_menu)
			self:queuecommand("UpdatePlayerActionMenu")
		end
	end,
	UpdatePlayerActionMenuCommand=function(self)
		local menu = self:GetChild("PlayerActionMenu")
		if not menu then return end
		local title = menu:GetChild("PlayerActionTitle")
		if title then
			local display_name = online_lobby_text("UnknownPlayer", "Player")
			if player_action_user then
				display_name = ITGOnline and ITGOnline.UserDisplayName
					and ITGOnline:UserDisplayName(player_action_user, player_action_user.profileName or display_name)
					or tostring(player_action_user.display_name or player_action_user.displayName or player_action_user.name or player_action_user.profileName or display_name)
			end
			title:settext(display_name)
		end
		local body = {}
		for i, option in ipairs(player_action_options) do
			body[#body + 1] = (i == player_action_index and "> " or "  ") .. tostring(option.label)
		end
		local text = menu:GetChild("PlayerActionOptions")
		if text then text:settext(table.concat(body, "\n")) end
	end,
	UpdateTransferManagerConfirmPromptCommand=function(self)
		local prompt = self:GetChild("TransferManagerConfirmPrompt")
		if not prompt then return end
		local detail = prompt:GetChild("PromptDetail")
		if detail then
			local title = prompt:GetChild("PromptTitle")
			local displayName = online_lobby_text("ThisPlayer", "this player")
			if transfer_manager_confirm_user then
				displayName = trim_text(transfer_manager_confirm_user.profileName
					or transfer_manager_confirm_user.display_name
					or transfer_manager_confirm_user.displayName
					or transfer_manager_confirm_user.name
					or transfer_manager_confirm_user.playerId
					or online_lobby_text("ThisPlayer", "this player"))
			end
			if transfer_manager_confirm_action == "exclude_player" then
				if title then title:settext(online_lobby_text("RemovePlayerConfirmTitle", "Remove this player?")) end
				detail:settext(online_lobby_text("RemovePlayerConfirmBody", "Do you really want to remove %s from the lobby?", displayName))
			else
				if title then title:settext(online_lobby_text("TransferManagerConfirmTitle", "Transfer manager role?")) end
				detail:settext(online_lobby_text("TransferManagerConfirmBody", "Do you really want to transfer the manager role to %s?", displayName))
			end
		end
		prompt:playcommand("Hover")
	end,
	UpdateGlobalOptionsMenuCommand=function(self)
		local menu = self:GetChild("GlobalOptionsMenu")
		if not menu then return end
		rebuild_global_options_choices()
		local title = menu:GetChild("GlobalOptionsTitle")
		if title then title:settext(online_lobby_text("GlobalOptions", "Global options")) end
		local detail = menu:GetChild("GlobalOptionsDetail")
		if detail then
			detail:settext(online_lobby_text("GlobalOptionsDescription", "Applies to the whole lobby: leaderboard score and music rate."))
		end
		local lines = {}
		for i, choice in ipairs(global_options_choices) do
			local selected = i == global_options_index
			local current = normalize_global_options(joined_global_options)
			local active = (choice.scoreMode ~= nil and choice.scoreMode == current.scoreMode)
				or (choice.musicRate ~= nil and math.abs((tonumber(choice.musicRate) or 0) - current.musicRate) < 0.001)
			lines[#lines + 1] = (selected and "> " or "  ")
				.. tostring(choice.label)
				.. (active and "  *" or "")
		end
		local text = menu:GetChild("GlobalOptionsChoices")
		if text then text:settext(table.concat(lines, "\n")) end
	end,
	UpdatePrivateJoinPromptCommand=function(self)
		local prompt = self:GetChild("PrivateJoinPrompt")
		if not prompt then return end
		local requester = private_join_request and private_join_request.requester or {}
		local inviter = private_join_request and private_join_request.inviter or {}
		local room = private_join_request and private_join_request.room or {}
		local title = prompt:GetChild("PrivateJoinTitle")
		if title then
			if private_join_prompt_kind == "invitation" then
				title:settext(online_lobby_text("PlayerInvitesYou", "%s invites you",
					tostring(inviter.name or online_lobby_text("UnknownPlayer", "Player"))))
			else
				title:settext(online_lobby_text("PlayerWantsToJoin", "%s wants to join",
					tostring(requester.name or online_lobby_text("UnknownPlayer", "Player"))))
			end
		end
		local detail = prompt:GetChild("PrivateJoinDetail")
		if detail then
			local roomType = room.visibility == "private"
				and online_lobby_text("PrivateLobby", "Private lobby")
				or online_lobby_text("Lobby", "Lobby")
			detail:settext(online_lobby_text("LobbyNameValue", "%s: %s", roomType,
				tostring(room.name or online_lobby_text("Lobby", "Lobby"))))
		end
		local lines = {}
		for i, option in ipairs(active_private_prompt_options()) do
			lines[#lines + 1] = (i == private_join_prompt_index and "> " or "  ") .. option.label
		end
		local optionsText = prompt:GetChild("PrivateJoinOptions")
		if optionsText then optionsText:settext(table.concat(lines, "\n")) end
	end,
	UpdateJoinedLobbyTextCommand=function(self)
		lobby_flow_trace("UpdateJoinedLobbyText_begin code=" .. tostring(joined_lobby_code)
			.. " phase=" .. tostring(joined_phase)
			.. " players=" .. tostring(#joined_lobby_players)
			.. " isManager=" .. tostring(joined_is_manager)
			.. " managerUserId=" .. tostring(joined_manager_user_id)
			.. " songConfirmed=" .. tostring(joined_song_confirmed == true)
			.. " missingSong=" .. tostring(joined_missing_song == true)
			.. " canDownload=" .. tostring(joined_can_download_pack == true)
			.. " packBusy=" .. tostring(pack_sync_busy() == true)
			.. " ready={" .. tostring(ready_summary()) .. "}")
		local displayPhase = normalized_online_phase(joined_phase)
		local roomPhase = normalized_online_phase(ITGOnline and ITGOnline.currentRoom and ITGOnline.currentRoom.phase or "")
		if displayPhase == "results" or roomPhase == "results" then
			if joined_song_preview ~= nil or joined_song_confirmed or joined_missing_song or joined_can_download_pack or joined_preview_unknown_pack then
				reset_joined_transient_song_state("update_joined_text_results_guard", { clearPreview = true, resetPackSync = false })
			end
		end
		sync_local_missing_song_from_joined_players()
		local joinedContent = self:GetChild("JoinedLobbyContent")
		if not joinedContent then
			lobby_flow_trace("UpdateJoinedLobbyText_aborted reason=no_joined_content")
			return
		end
		local codeValue = joinedContent:GetChild("JoinedLobbyCodeValue")
		if codeValue then
			codeValue:settext(joined_lobby_code ~= "" and joined_lobby_code
				or online_lobby_text("Pending", "(pending)"))
		end

		local lines = {}
		local renderParts = {}
		local selected_start = nil
		local selected_length = nil
		local text_length = 0
		if #joined_lobby_players == 0 then
			joined_player_index = 1
			joined_players_selected = false
		else
			joined_player_index = math.max(1, math.min(joined_player_index, #joined_lobby_players))
			if joined_players_selected and not joined_player_can_receive_manager(joined_lobby_players[joined_player_index]) then
				joined_players_selected = focus_joined_players()
			end
		end
		for i, player in ipairs(joined_lobby_players) do
			local profile = trim_text(player.profileName or player.name or player.playerId
				or online_lobby_text("PlayerNumber", "Player %d", i))
			if tostring(player.playerId or "") == tostring(joined_manager_user_id or "") then
				profile = "[M] " .. profile
			end
			local ready = player.ready and " ✔" or ""
			local missing = ""
			local packSyncText = pack_sync_line_for_player(player)
			local playerScreenName = trim_text(player.screenName or player.screen or player.currentScreen)
			renderParts[#renderParts + 1] = table.concat({
				tostring(i),
				tostring(player.playerId or ""),
				tostring(profile),
				tostring(player.ready == true),
				tostring(player.readyPendingServer == true),
				tostring(playerScreenName),
				tostring(player.playState or player.play_state or ""),
				tostring(player.packSyncStatus or player.pack_sync_status or ""),
				tostring(player.songAvailable),
				tostring(packSyncText),
			}, ":")
			if packSyncText ~= "" then
				missing = " · " .. packSyncText
			end
			if not player.ready and playerScreenName:find("ScreenPlayerOptions", 1, true) == 1 then
				missing = " · " .. online_lobby_text("OptionsScreen", "Options screen")
					.. (player.readyPendingServer and " ..." or "")
			elseif player.readyPendingServer and missing == "" then
				missing = " ..."
			end
			local optionParts = {}
			local phaseShowsCurrentOptions = joined_song_confirmed
				and (joined_phase == "config" or joined_phase == "starting" or joined_phase == "playing")
			if phaseShowsCurrentOptions then
				local speedMod = trim_text(player.speedMod)
				if speedMod ~= "" then optionParts[#optionParts+1] = speedMod end
				local stepchart = abbreviate_stepchart(player.stepchart)
				if stepchart ~= "" then optionParts[#optionParts+1] = stepchart end
			end
			-- A background download leaves a short-lived downloaded_ok/ready status
			-- while the manager is still browsing. songAvailable can still describe
			-- the previous preview, so do not show a phantom active selection.
			local status = trim_text(player.packSyncStatus or player.pack_sync_status)
			local syncCompleted = status == "downloaded_ok" or status == "ready"
			if missing == "" and joined_song_preview ~= nil and player.songAvailable == false
				and not syncCompleted and player_is_manager(player) and not player_is_current_user(player) then
				missing = " - " .. online_lobby_text("SelectionInProgress", "selecting")
			end
			local maxLineLen = 88
			local selectedPrefix = joined_players_selected and i == joined_player_index and "> " or "  "
			local lineHead = selectedPrefix..i..". "..profile
			local lineTail = ready .. missing
			local optionsText = table.concat(optionParts, " | ")
			local options = ""
			if optionsText ~= "" then
				local remaining = maxLineLen - online_utf8_length(lineHead) - online_utf8_length(lineTail)
				if remaining >= 8 then
					local optionsBudget = remaining - 3 -- " [" + "]"
					options = " [" .. clamp_text(optionsText, optionsBudget) .. "]"
				end
			end
			local line = clamp_text(lineHead..options..lineTail, maxLineLen)
			if joined_players_selected and i == joined_player_index then
				selected_start = text_length
				selected_length = online_utf8_length(line)
			end
			lines[#lines+1] = line
			text_length = text_length + online_utf8_length(line) + 1
		end
		lobby_flow_trace("joined_players_render rows=" .. table.concat(renderParts, ",")
			.. " selectedIndex=" .. tostring(joined_player_index)
			.. " selectedStart=" .. tostring(selected_start or "nil")
			.. " selectedLength=" .. tostring(selected_length or "nil")
			.. " playersSelected=" .. tostring(joined_players_selected == true)
			.. " activeIndex=" .. tostring(joined_active_index)
			.. " manager=" .. tostring(joined_manager_user_id or "nil"))
		local playersText = joinedContent:GetChild("JoinedLobbyPlayers")
		if playersText then
			playersText:settext(#lines > 0 and table.concat(lines, "\n")
				or online_lobby_text("WaitingForPlayers", "Waiting for players..."))
			playersText:ClearAttributes()
			if selected_start and selected_length and selected_length > 0 then
				playersText:AddAttribute(selected_start, {Length=selected_length, Diffuse={0,1,0,1}})
			end
		end
		local playersFrame = joinedContent:GetChild("JoinedLobbyPlayersFrame")
		if playersFrame then
			playersFrame:playcommand("Hover")
		end
		update_joined_song_card(joinedContent)

			local codeLabel = joinedContent and joinedContent:GetChild("JoinedLobbyCodeLabel")
			if joinedContent then
				local function get_zoomed_width(actor)
					if not actor then return 0 end
					return actor:GetWidth() * actor:GetZoomX()
				end

				local function place_label_left_if_needed(labelActor, valueActor, defaultLabelX, valueX)
					if not labelActor or not valueActor then return end
					local valueWidth = get_zoomed_width(valueActor)
					local valueLeftEdge = valueX - valueWidth
					local gap = 12
					local desiredLabelX = math.min(defaultLabelX, valueLeftEdge - gap)
					local minLabelX = -285
					labelActor:x(math.max(minLabelX, desiredLabelX))
				end

				place_label_left_if_needed(codeLabel, codeValue, -10, 50)
			end

		local cancelChoiceVisible = joined_can_cancel_song_selection()
		local selectSongButton = joinedContent and joinedContent:GetChild("SelectSongButton")
		if selectSongButton then
			local allowSelection = joined_phase_allows_song_selection()
			local visible = joined_is_manager and allowSelection and not cancelChoiceVisible
			selectSongButton:visible(visible)

			local currentPhase = normalized_online_phase(joined_phase)
			local roomPhase = normalized_online_phase(ITGOnline and ITGOnline.currentRoom and ITGOnline.currentRoom.phase or "")
			local visibilityKey = table.concat({
				tostring(joined_lobby_code or ""),
				tostring(currentPhase),
				tostring(roomPhase),
				joined_is_manager and "1" or "0",
				allowSelection and "1" or "0",
				visible and "1" or "0",
				tostring(#joined_lobby_players),
			}, "|")
			if visibilityKey ~= lobby_trace_state.lastSelectSongVisibilityDebugKey then
				lobby_trace_state.lastSelectSongVisibilityDebugKey = visibilityKey
				lobby_flow_trace("select_music_button visible=" .. tostring(visible)
					.. " allowSelection=" .. tostring(allowSelection)
					.. " joinedPhase=" .. tostring(currentPhase)
					.. " roomPhase=" .. tostring(roomPhase)
					.. " isManager=" .. tostring(joined_is_manager)
					.. " players=" .. tostring(#joined_lobby_players)
					.. " room=" .. tostring(ITGOnline and ITGOnline.currentRoomId or "nil"))
			end
		end

		local reloadSongsButton = joinedContent and joinedContent:GetChild("ReloadSongsButton")
		if reloadSongsButton then
			local canDownloadBrowsePack = can_download_browsed_pack()
			local syncBusy = pack_sync_busy()
			local reloadVisible = show_pack_download_button()
				reloadSongsButton:visible(reloadVisible)
				local label = reloadSongsButton:GetChild("ReloadSongsLabel")
				local labelText = ""
			if label then
				if syncBusy then
					labelText = online_lobby_text("Downloading", "Downloading...")
				else
					labelText = (joined_can_download_pack or canDownloadBrowsePack)
						and online_lobby_text("DownloadPack", "Download pack")
						or online_lobby_text("ReloadSongs", "Reload songs")
				end
				label:settext(labelText)
			end
			update_joined_download_kick_warning(self)
			lobby_flow_trace("reload_download_button_state visible=" .. tostring(reloadVisible == true)
				.. " label=" .. tostring(labelText)
				.. " syncBusy=" .. tostring(syncBusy == true)
				.. " canDownloadPack=" .. tostring(joined_can_download_pack == true)
				.. " canDownloadBrowsePack=" .. tostring(canDownloadBrowsePack == true)
				.. " missingSong=" .. tostring(joined_missing_song == true)
				.. " missingReason=" .. tostring(joined_missing_song_reason or "nil")
				.. " previewUnknownPack=" .. tostring(joined_preview_unknown_pack == true)
				.. " selectedKey=" .. tostring(joined_song_selected_key or "")
				.. " activeIndex=" .. tostring(joined_active_index))
			reloadSongsButton:playcommand("Hover")
		end

		local globalOptionsButton = joinedContent and joinedContent:GetChild("GlobalOptionsButton")
		if globalOptionsButton then
			local visible = joined_is_manager and joined_phase_allows_song_selection()
			globalOptionsButton:visible(visible)
			lobby_flow_trace("global_options_button_state visible=" .. tostring(visible == true)
				.. " isManager=" .. tostring(joined_is_manager == true)
				.. " phaseAllowsSelection=" .. tostring(joined_phase_allows_song_selection() == true)
				.. " phase=" .. tostring(joined_phase)
				.. " roomPhase=" .. tostring(ITGOnline and ITGOnline.currentRoom and ITGOnline.currentRoom.phase or "nil"))
			local label = globalOptionsButton:GetChild("GlobalOptionsLabel")
			if label then
				label:settext(online_lobby_text("GlobalOptions", "Global options"))
			end
			local modeLabel = globalOptionsButton:GetChild("GlobalOptionsModeLabel")
			if modeLabel then
				modeLabel:settext(global_options_mode_label())
			end
		end

		local cancelChoiceButton = joinedContent and joinedContent:GetChild("CancelChoiceButton")
		if cancelChoiceButton then
			cancelChoiceButton:visible(cancelChoiceVisible)
			cancelChoiceButton:playcommand("Hover")
			lobby_flow_trace("cancel_choice_button_state visible=" .. tostring(cancelChoiceVisible == true)
				.. " activeIndex=" .. tostring(joined_active_index)
				.. " phase=" .. tostring(joined_phase)
				.. " isManager=" .. tostring(joined_is_manager)
				.. " transitionLocked=" .. tostring(ITGOnline and ITGOnline.IsSongSelectionTransitionLocked and ITGOnline:IsSongSelectionTransitionLocked("ui") or false))
		end

		local startRoomButton = joinedContent and joinedContent:GetChild("StartRoomButton")
		if startRoomButton then
			local everyoneReady = joined_all_players_ready()
			local hasMissingSong = joined_any_player_missing_song()
			local visible = joined_room_can_start()
			startRoomButton:visible(visible)

			local debugKey = table.concat({
				tostring(joined_lobby_code or ""),
				tostring(joined_phase or ""),
				joined_is_manager and "1" or "0",
				tostring(joined_manager_user_id or "nil"),
				tostring(#joined_lobby_players),
				everyoneReady and "1" or "0",
				hasMissingSong and "1" or "0",
				visible and "1" or "0",
				ready_summary(),
			}, "|")
			if debugKey ~= lobby_trace_state.lastStartVisibilityDebugKey then
				lobby_trace_state.lastStartVisibilityDebugKey = debugKey
				lobby_debug("start_button visible=" .. tostring(visible)
					.. " phase=" .. tostring(joined_phase)
					.. " isManager=" .. tostring(joined_is_manager)
					.. " managerUserId=" .. tostring(joined_manager_user_id)
					.. " players=" .. tostring(#joined_lobby_players)
					.. " everyoneReady=" .. tostring(everyoneReady)
					.. " missingSong=" .. tostring(hasMissingSong)
					.. " readyStates=[" .. ready_summary() .. "]")
			end

				if visible then
					local focusKey = table.concat({
						tostring(joined_lobby_code or ""),
						tostring(joined_phase or ""),
						tostring(joined_song_selected_key or ""),
						ready_summary(),
						hasMissingSong and "1" or "0",
					}, "|")
					local currentFocusStillAvailable = joined_active_index_is_available()
					if focusKey ~= lobby_trace_state.lastAutoStartFocusKey then
						lobby_trace_state.lastAutoStartFocusKey = focusKey
						joined_active_index = 7
						joined_user_moved_focus = false
						lobby_flow_trace("start_button_focus_forced reason=start_button_became_available"
							.. " canStart=" .. tostring(visible)
							.. " readyStates=[" .. ready_summary() .. "]"
							.. " focusKey=" .. tostring(focusKey))
						self:queuecommand("Hover")
					end
					if not currentFocusStillAvailable then
						joined_active_index = 7
						joined_user_moved_focus = false
						lobby_flow_trace("start_button_focus_kept_safe reason=current_focus_unavailable canStart=" .. tostring(visible)
							.. " readyStates=[" .. ready_summary() .. "]")
						self:queuecommand("Hover")
					end
					lobby_trace_state.lastAutoStartRequestKey = ""
				else
					lobby_trace_state.lastAutoStartFocusKey = ""
					lobby_trace_state.lastAutoStartRequestKey = ""
				end
			end
			local function joined_actor_visible(actor)
				if not actor or not actor.GetVisible then return "nil" end
				local ok, value = pcall(function() return actor:GetVisible() end)
				if not ok then return "unknown" end
				return tostring(value == true)
			end
			lobby_flow_trace("joined_button_visibility_summary"
				.. " leave=true"
				.. " selectMusic=" .. joined_actor_visible(selectSongButton)
				.. " reload=" .. joined_actor_visible(reloadSongsButton)
				.. " globalOptions=" .. joined_actor_visible(globalOptionsButton)
				.. " cancelChoice=" .. joined_actor_visible(cancelChoiceButton)
				.. " start=" .. joined_actor_visible(startRoomButton)
				.. " activeIndex=" .. tostring(joined_active_index)
				.. " indices=" .. table.concat(joined_button_indices(), ",")
				.. " phase=" .. tostring(joined_phase)
				.. " ready={" .. tostring(ready_summary()) .. "}")
			lobby_flow_trace("UpdateJoinedLobbyText_end code=" .. tostring(joined_lobby_code)
				.. " phase=" .. tostring(joined_phase)
				.. " players=" .. tostring(#joined_lobby_players)
				.. " selectedPlayerIndex=" .. tostring(joined_player_index)
				.. " activeIndex=" .. tostring(joined_active_index)
				.. " songConfirmed=" .. tostring(joined_song_confirmed == true)
				.. " preview=" .. tostring(joined_song_preview and (joined_song_preview.title or joined_song_preview.folder_name or joined_song_preview.song_hash) or "none")
				.. " canDownload=" .. tostring(joined_can_download_pack == true)
				.. " missingSong=" .. tostring(joined_missing_song == true)
				.. " ready={" .. tostring(ready_summary()) .. "}")
		end,
		SetStatusCommand=function(self, params)
			lobby_flow_trace("SetStatus_received text=" .. tostring(params and params.text or "")
				.. " showSpinner=" .. tostring(params and params.showSpinner == true)
				.. " showPrompt=" .. tostring(params and params.showPrompt == true)
				.. " force=" .. tostring(params and params.force == true)
				.. " critical=" .. tostring(params and params.critical == true)
				.. " duration=" .. tostring(params and params.duration or "nil")
				.. " mode=" .. tostring(mode)
				.. " joined_code=" .. tostring(joined_lobby_code)
				.. " showingPackChoice=" .. tostring(showing_pack_choice_menu == true)
				.. " currentRoomId=" .. tostring(ITGOnline and ITGOnline.currentRoomId or "nil"))
			local statusText = tostring(params and params.text or "")
			if statusText == "Synchronisation de l'etat en ligne..."
				and not (params and (params.force == true or params.critical == true))
			then
				lobby_flow_trace("SetStatus_ignored reason=passive_sync_status"
					.. " mode=" .. tostring(mode)
					.. " joined_code=" .. tostring(joined_lobby_code)
					.. " currentRoomId=" .. tostring(ITGOnline and ITGOnline.currentRoomId or "nil"))
				return
			end
			if showing_pack_choice_menu then
				if params and (params.force == true or params.critical == true) then
					lobby_flow_trace("SetStatus_closing_transient_ui reason=force_or_critical")
					if ITGOnline
						and ITGOnline.PackSync
						and ITGOnline.PackSync.CancelPendingPackChoice then
						ITGOnline.PackSync:CancelPendingPackChoice("status_force_close")
					end
					close_transient_joined_ui()
				else
					lobby_flow_trace("SetStatus_ignored reason=pack_choice_menu_open")
					return
				end
			end
			network_status_clear_at = 0
			self:GetChild("NetworkStatus"):visible(true)
			self:GetChild("NetworkStatus"):playcommand("Set", params)
			local duration = tonumber(params and params.duration)
			if duration and duration > 0 then
				network_status_clear_at = GetTimeSinceStart() + duration
				lobby_flow_trace("SetStatus_auto_clear_scheduled at=" .. tostring(network_status_clear_at))
				local timer = self:GetChild("NetworkStatusClearTimer")
				if timer then
					timer:stoptweening()
					timer:sleep(duration):queuecommand("Fire")
				end
			end
		end,
		ClearTransientStatusCommand=function(self)
			if network_status_clear_at <= 0 then return end
			if GetTimeSinceStart() + 0.05 < network_status_clear_at then return end
			network_status_clear_at = 0
			local status = self:GetChild("NetworkStatus")
			if status then status:visible(false) end
		end,
		CheckConnectCommand=function(self)
			lobby_flow_trace("CheckConnect_begin attempted=" .. tostring(attempted)
				.. " connected=" .. tostring(GetOnlineHandlerInstance() and GetOnlineHandlerInstance().connected or false)
				.. " wait_time=" .. tostring(wait_time)
				.. " mode=" .. tostring(mode)
				.. " joined_code=" .. tostring(joined_lobby_code)
				.. " currentRoomId=" .. tostring(ITGOnline and ITGOnline.currentRoomId or "nil"))
			if mode == "browse"
				and joined_lobby_code == ""
				and not (ITGOnline and ITGOnline.currentRoomId)
				and recently_left_lobby(5.0) then
				lobby_flow_trace("CheckConnect_recent_leave_no_room_continue")
			end
			local onlineHandler = GetOnlineHandlerInstance()
			if onlineHandler then
				-- If no connection exists, first (re)establish the connection.
				-- Only try once per screen load to avoid infinite loops of trying to connect.
				if not attempted and (not onlineHandler.socket or onlineHandler.errorMsg ~= nil) then
					self:playcommand("SetStatus", {
						text=online_lobby_text("ConnectingService", "Connecting to online service..."),
						showSpinner=true
					})
					lobby_flow_trace("CheckConnect_connect_broadcast attempted=" .. tostring(attempted)
						.. " hasSocket=" .. tostring(onlineHandler.socket ~= nil)
						.. " error=" .. tostring(onlineHandler.errorMsg))
					MESSAGEMAN:Broadcast("ConnectOnline")
					attempted = true
				end

				if not onlineHandler.connected and onlineHandler.errorMsg == nil then
					wait_time = wait_time + 1
					lobby_flow_trace("CheckConnect_waiting wait_time=" .. tostring(wait_time)
						.. " hasSocket=" .. tostring(onlineHandler.socket ~= nil))
					self:playcommand("SetStatus", {
						text=online_lobby_text("ConnectingServiceRetry", "Connecting to online service... (%ds)", wait_time),
						showSpinner=true
					})
					self:sleep(1):queuecommand("CheckConnect")
				else
					lobby_flow_trace("CheckConnect_display connected=" .. tostring(onlineHandler.connected)
						.. " error=" .. tostring(onlineHandler.errorMsg))
					self:queuecommand("Display")
				end
			else
				lobby_flow_trace("CheckConnect_no_handler")
				self:playcommand("SetStatus", {
					text=online_lobby_text("InitializingOnlineManager", "Initializing online manager..."),
					showSpinner=true
				})
				self:sleep(0.25):queuecommand("CheckConnect")
			end
		end,
		DisplayCommand=function(self)
			lobby_flow_trace("Display_begin mode=" .. tostring(mode)
				.. " joined_code=" .. tostring(joined_lobby_code)
				.. " currentRoomId=" .. tostring(ITGOnline and ITGOnline.currentRoomId or "nil")
				.. " connected=" .. tostring(connected == true)
				.. " leaving=" .. tostring(leaving_lobby == true)
				.. " recentLeave=" .. tostring(recently_left_lobby(5.0) == true))
			if mode == "browse"
				and joined_lobby_code == ""
				and not (ITGOnline and ITGOnline.currentRoomId)
				and recently_left_lobby(5.0) then
				lobby_flow_trace("Display_recent_leave_no_room_continue")
			end
			local onlineHandler = GetOnlineHandlerInstance()
			if onlineHandler then
				if onlineHandler.connected then
					connected = true
					has_error = false
					reset_browse_focus()
					self:playcommand("SetStatus", {
						text=online_lobby_text("ConnectedService", "Connected to online service."),
						showSpinner=false,
						showPrompt=false
					})
					self:GetChild("NetworkStatus"):visible(false)
					ScreenOnlineLobbiesApplyCurrentRoomSnapshot(self, "display")
					if ITGOnline and ITGOnline.Sync then
						lobby_flow_trace("Display_sync_requested")
						ITGOnline:Sync(function(ok, decoded)
							lobby_flow_trace("Display_sync_result ok=" .. tostring(ok == true)
								.. " hasRoom=" .. tostring(decoded and decoded.current_room ~= nil)
								.. " lobbyCount=" .. tostring(decoded and decoded.visible_rooms and #decoded.visible_rooms or 0))
							if not ok or not decoded then
								request_lobby_refresh("display_sync_failed", { immediate=true }, self)
							end
						end)
					elseif ITGOnline and ITGOnline.currentRoomId then
						lobby_flow_trace("Display_fetch_current_room_by_id room=" .. tostring(ITGOnline.currentRoomId))
						self:playcommand("SetStatus", {
							text=online_lobby_text("RestoringCurrentLobby", "Restoring current lobby..."),
							showSpinner=true,
							showPrompt=false
						})
						ITGOnline:FetchRoom(ITGOnline.currentRoomId, function(ok, decoded)
							if ITGOnline and ITGOnline.TraceOnlineState then
								ITGOnline:TraceOnlineState("ui_display_fetch_current_room_response", {
									source = "ScreenOnlineLobbies.Display",
									roomSnapshot = decoded and decoded.room or nil,
									ok = ok == true,
									hasRoom = decoded and decoded.room ~= nil,
									reason = "restore_current_room_by_id",
								})
							end
							lobby_flow_trace("Display_fetch_room_result ok=" .. tostring(ok == true)
								.. " hasRoom=" .. tostring(decoded and decoded.room ~= nil)
								.. " phase=" .. tostring(decoded and decoded.room and decoded.room.phase or "nil"))
							if ok and decoded and decoded.room then
								MESSAGEMAN:Broadcast("OnlineLobbyState", ITGOnline:LobbyStatePayload(decoded.room))
							else
								request_lobby_refresh("display_fetch_room_failed", { immediate=true }, self)
							end
						end)
					elseif ITGOnline and ITGOnline.FetchCurrentRoom then
						lobby_flow_trace("Display_fetch_current_room")
						self:playcommand("SetStatus", {
							text=online_lobby_text("RestoringCurrentLobby", "Restoring current lobby..."),
							showSpinner=true,
							showPrompt=false
						})
						ITGOnline:FetchCurrentRoom(function(ok, decoded)
							lobby_flow_trace("Display_fetch_current_room_result ok=" .. tostring(ok == true)
								.. " hasRoom=" .. tostring(decoded and decoded.room ~= nil)
								.. " phase=" .. tostring(decoded and decoded.room and decoded.room.phase or "nil"))
							if ok and decoded and decoded.room then
								MESSAGEMAN:Broadcast("OnlineLobbyState", ITGOnline:LobbyStatePayload(decoded.room))
							else
								request_lobby_refresh("display_fetch_current_room_failed", { immediate=true }, self)
							end
						end)
					else
						lobby_flow_trace("Display_search_lobby_fallback")
						request_lobby_ui_repaint(self, "display_no_room_fallback")
						request_lobby_refresh("display_no_room_fallback", { immediate=true }, self)
					end
					self:queuecommand("Hover")
				end

				if onlineHandler.errorMsg ~= nil then
					connected = false
					has_error = true
					self:playcommand("SetStatus", {
						text=online_lobby_text("ConnectionErrorValue", "Online service connection error:\n%s", onlineHandler.errorMsg),
						showSpinner=false,
						showPrompt=true,
						promptText=online_lobby_text("ReturnMainMenuPrompt", "Press &START; to return to the main menu.")
					})
					self:GetChild("LobbyContent"):visible(false)
					self:GetChild("OnlinePlayersContent"):visible(false)
				end
			end
		end,
				RefreshCurrentRoomSnapshotCommand=function(self)
					if ITGOnline and ITGOnline.TraceOnlineState then
						ITGOnline:TraceOnlineState("ui_refresh_current_room_snapshot_command", {
							source = "ScreenOnlineLobbies",
							uiMode = mode,
							joinedCode = joined_lobby_code,
							leaving = leaving_lobby == true,
							reason = "command",
						})
					end
					lobby_flow_trace("refresh_current_room_snapshot_command currentRoomId=" .. tostring(ITGOnline and ITGOnline.currentRoomId or "nil")
						.. " mode=" .. tostring(mode)
						.. " joined_code=" .. tostring(joined_lobby_code)
						.. " leaving=" .. tostring(leaving_lobby == true))
					ScreenOnlineLobbiesApplyCurrentRoomSnapshot(self, "screen_online_lobbies_refresh")
				end,
				RefreshLobbyAfterLeaveCommand=function(self)
					if not is_active_lobby_overlay() then
						if ITGOnline and ITGOnline.TraceOnlineState then
							ITGOnline:TraceOnlineState("ui_refresh_lobby_after_leave_skipped", {
								source = "ScreenOnlineLobbies",
								reason = "inactive_overlay",
							})
						end
						lobby_flow_trace("refresh_lobby_after_leave_skipped reason=inactive_overlay")
						return
					end
					if leaving_lobby then
						if ITGOnline and ITGOnline.TraceOnlineState then
							ITGOnline:TraceOnlineState("ui_refresh_lobby_after_leave_skipped", {
								source = "ScreenOnlineLobbies",
								reason = "leave_in_progress",
								leaving = true,
							})
						end
						lobby_flow_trace("refresh_lobby_after_leave_skipped reason=leave_in_progress")
						return
					end
					if ITGOnline and ITGOnline.currentRoomId then
						if ITGOnline and ITGOnline.TraceOnlineState then
							ITGOnline:TraceOnlineState("ui_refresh_lobby_after_leave_skipped", {
								source = "ScreenOnlineLobbies",
								reason = "still_in_room",
								currentRoom = ITGOnline.currentRoomId,
							})
						end
						lobby_flow_trace("refresh_lobby_after_leave_skipped reason=still_in_room room=" .. tostring(ITGOnline.currentRoomId))
						return
					end
					if ITGOnline and ITGOnline.TraceOnlineState then
						ITGOnline:TraceOnlineState("ui_refresh_lobby_after_leave_requested", {
							source = "ScreenOnlineLobbies",
							reason = "overlay_post_leave_command",
						})
					end
					lobby_flow_trace("refresh_lobby_after_leave delegated=request_helper")
					request_lobby_refresh("overlay_post_leave_command", {
						immediate=true,
						delay=0.20,
						forceFresh=true,
						ignoreSuppression=true,
					}, self)
				end,
				RetryLobbyRefreshCommand=function(self)
					SL.Global.Online = SL.Global.Online or {}
					SL.Global.Online.ScreenOnlineLobbiesPendingRefreshRetryScheduled = false
					if not is_active_lobby_overlay() then
						SL.Global.Online.ScreenOnlineLobbiesPendingRefresh = nil
						lobby_flow_trace("retry_lobby_refresh_dropped reason=inactive_overlay")
						return
					end
					local pending = SL.Global.Online.ScreenOnlineLobbiesPendingRefresh
					SL.Global.Online.ScreenOnlineLobbiesPendingRefresh = nil
					if type(pending) ~= "table" then
						lobby_flow_trace("retry_lobby_refresh_skipped reason=no_pending_refresh")
						return
					end
					lobby_flow_trace("retry_lobby_refresh reason=" .. tostring(pending.reason or "unknown"))
					request_lobby_refresh(pending.reason, pending.options, self)
				end,
				LeaveLobbyWatchdogCommand=function(self)
					if not is_active_lobby_overlay() then return end
					if not leaving_lobby then return end
					if not joined_room_phase_allows_manual_leave() then
						lobby_flow_trace("leave_lobby_watchdog_stopped reason=phase_not_leaveable"
							.. " phase=" .. tostring(current_joined_room_phase())
							.. " request_code=" .. tostring(SL.Global.Online.ScreenOnlineLobbiesLeaveRequestCode)
							.. " request_room_id=" .. tostring(SL.Global.Online.ScreenOnlineLobbiesLeaveRequestRoomId))
						restore_joined_after_blocked_leave(self, "watchdog_phase_not_leaveable")
						return
					end
					SL.Global.Online.ScreenOnlineLobbiesLeaveWatchdogCount =
						(tonumber(SL.Global.Online.ScreenOnlineLobbiesLeaveWatchdogCount) or 0) + 1
					lobby_flow_trace(
						"leave_lobby_watchdog leaving=true count=" ..
						tostring(SL.Global.Online.ScreenOnlineLobbiesLeaveWatchdogCount) ..
						" request_code=" .. tostring(SL.Global.Online.ScreenOnlineLobbiesLeaveRequestCode) ..
						" request_room_id=" .. tostring(SL.Global.Online.ScreenOnlineLobbiesLeaveRequestRoomId) ..
						" currentRoomId=" .. tostring(ITGOnline and ITGOnline.currentRoomId))
					if not (ITGOnline and ITGOnline.currentRoomId) then
						finish_leave_lobby(self, SL.Global.Online.ScreenOnlineLobbiesLeaveRequestCode)
						return
					end
					MESSAGEMAN:Broadcast("LeaveLobby", {
						roomId=SL.Global.Online.ScreenOnlineLobbiesLeaveRequestRoomId,
						lobbyCode=SL.Global.Online.ScreenOnlineLobbiesLeaveRequestCode,
						generation=SL.Global.Online.ScreenOnlineLobbiesLeaveRequestGeneration,
						source="watchdog",
					})
					self:sleep(4.0):queuecommand("LeaveLobbyWatchdog")
				end,
				ApplyDeferredLobbySearchCommand=function(self)
					lobby_flow_trace("apply_deferred_lobby_search_command"
						.. " candidates=" .. tostring(candidates and #candidates or 0)
						.. " onlinePlayers=" .. tostring(online_users and #online_users or 0)
						.. " mode=" .. tostring(mode)
						.. " pending=" .. tostring(lobby_search_ui_pending == true))
					lobby_search_ui_pending = false
					apply_lobby_search_to_ui(self, "deferred")
				end,
				LobbySearchedMessageCommand=function(self, params)
					if not is_active_lobby_overlay() then
						lobby_flow_trace("LobbySearched_ignored reason=inactive_overlay")
						return
					end
					candidates = filter_recently_left_lobby_candidates(params and params.lobbies or {}, "LobbySearched")
				online_users = params and params.onlinePlayers or {}
				lobby_flow_trace("LobbySearched_received lobbies=" .. tostring(#candidates)
					.. " onlinePlayers=" .. tostring(#online_users)
					.. " mode=" .. tostring(mode)
					.. " joined_code=" .. tostring(joined_lobby_code)
					.. " currentRoomId=" .. tostring(ITGOnline and ITGOnline.currentRoomId or "nil")
					.. " force=" .. tostring(params and params.force == true))
				if #online_users == 0 then
					online_player_index = 1
				else
					online_player_index = math.max(1, math.min(online_player_index, #online_users))
				end
				if mode == "joined" and not (params and params.force == true) then
					lobby_flow_trace("LobbySearched_cached_without_repaint reason=joined_mode"
						.. " lobbies=" .. tostring(#candidates)
						.. " onlinePlayers=" .. tostring(#online_users)
						.. " joined_code=" .. tostring(joined_lobby_code)
						.. " currentRoomId=" .. tostring(ITGOnline and ITGOnline.currentRoomId or "nil"))
					return
				end
				apply_lobby_search_to_ui(self, "LobbySearched")
				lobby_flow_trace("LobbySearched_applied lobbies=" .. tostring(#candidates)
					.. " onlinePlayers=" .. tostring(#online_users)
					.. " selectedLobbyIndex=" .. tostring(selected_lobby_index)
					.. " onlinePlayerIndex=" .. tostring(online_player_index)
					.. " mode=" .. tostring(mode)
					.. " joined_code=" .. tostring(joined_lobby_code))
			end,
			OnlineLobbyStateMessageCommand=function(self, params)
				if not is_active_lobby_overlay() then
					lobby_room_summary("OnlineLobbyState_ignored_inactive", params)
					return
				end
				lobby_room_summary("OnlineLobbyState_received", params)
				if leaving_lobby then
				lobby_flow_trace("ignored_online_lobby_state reason=leaving_lobby code=" .. tostring(params and params.code or ""))
				return
			end
			local incomingSignature = online_lobby_state_signature(params)
			if mode == "joined"
				and tostring(joined_lobby_code or "") == tostring(params and params.code or "")
				and incomingSignature ~= ""
				and incomingSignature == lobby_trace_state.lastOnlineLobbyStateSignature
			then
				lobby_trace_state.lastOnlineLobbyStateSignatureAt = GetTimeSinceStart()
				lobby_flow_trace("OnlineLobbyState_duplicate_no_repaint reason=same_signature_already_applied"
					.. " code=" .. tostring(params and params.code or "")
					.. " phase=" .. tostring(params and params.phase or "nil")
					.. " players=" .. tostring(params and params.players and #params.players or 0)
					.. " songConfirmed=" .. tostring(joined_song_confirmed == true)
					.. " selectedKey=" .. tostring(joined_song_selected_key or "")
					.. " snapshotSource=" .. tostring(params and params.snapshotSource or "nil"))
				return
			end
			local previousLobbyCode = joined_lobby_code
			local previousJoinedPhase = joined_phase
			local previousSongConfirmed = joined_song_confirmed
			lobby_flow_trace("OnlineLobbyState_before_apply previous_code=" .. tostring(previousLobbyCode)
				.. " previous_phase=" .. tostring(previousJoinedPhase)
				.. " previous_song_confirmed=" .. tostring(previousSongConfirmed == true)
				.. " incoming_room_id=" .. tostring(params and params.roomId or "nil")
				.. " incoming_code=" .. tostring(params and params.code or "")
				.. " incoming_phase=" .. tostring(params and params.phase or "nil")
				.. " incoming_players=" .. tostring(params and params.players and #params.players or 0)
				.. " snapshotSource=" .. tostring(params and params.snapshotSource or "nil")
				.. " previous_ready={" .. tostring(ready_summary()) .. "}")
			local previousIsManager = joined_is_manager
			clear_pending_join()
			clear_pending_create()
			if mode ~= "joined" then
				lobby_flow_trace("mode_autoswitch_to_joined reason=online_lobby_state previous_mode=" .. tostring(mode)
					.. " roomId=" .. tostring(params and params.roomId or "nil")
					.. " code=" .. tostring(params and params.code or "")
					.. " phase=" .. tostring(params and params.phase or "nil"))
			end
			mode = "joined"
			leaving_lobby = false
			showing_leave_confirm = false
			list_selected = false
			join_lobby_code = ""
			local previousSelectedPlayerKey = joined_player_stable_key(joined_lobby_players and joined_lobby_players[joined_player_index])
			joined_lobby_code = params and params.code or ""
			if joined_lobby_code ~= previousLobbyCode then
				lobby_trace_state.lastOnlineLobbyStateSignature = ""
				lobby_trace_state.lastOnlineLobbyStateSignatureAt = 0
				lobby_trace_state.lastPackSyncLocalStatusSignature = ""
				lobby_trace_state.lastPackSyncLocalStatusAt = 0
				joined_focus_initialized = false
				joined_player_index = 1
				joined_players_selected = false
				joined_song_preview = nil
				joined_song_confirmed = false
				joined_song_selected_key = ""
				joined_missing_song = false
				joined_missing_song_info = nil
				joined_can_download_pack = false
				joined_missing_song_reason = nil
				joined_preview_unknown_pack = false
				previousSelectedPlayerKey = ""
			end
			joined_lobby_players = merge_joined_players_preserving_visual_order(joined_lobby_players, params and params.players or {})
			joined_is_manager = params and params.isManager or false
			joined_manager_user_id = params and params.manager and params.manager.id or nil
			if previousLobbyCode ~= "" and previousLobbyCode == joined_lobby_code and not previousIsManager and joined_is_manager then
				self:playcommand("SetStatus", {
					text=online_lobby_text("YouAreManager", "You are now the lobby manager."),
					showSpinner=false,
					showPrompt=false,
					duration=5
				})
			end
			if not joined_is_manager then
				joined_players_selected = false
			end
			joined_player_index = joined_player_index_for_key(joined_lobby_players, previousSelectedPlayerKey, joined_player_index)
			joined_player_index = math.max(1, math.min(joined_player_index, math.max(1, #joined_lobby_players)))
			lobby_flow_trace("joined_player_focus_after_snapshot"
				.. " previousSelectedKey=" .. tostring(previousSelectedPlayerKey)
				.. " selectedIndex=" .. tostring(joined_player_index)
				.. " selectedKey=" .. tostring(joined_player_stable_key(joined_lobby_players and joined_lobby_players[joined_player_index]))
				.. " players=" .. tostring(#joined_lobby_players)
				.. " order=" .. tostring(joined_players_order_signature(joined_lobby_players))
				.. " source=" .. tostring(params and params.snapshotSource or "nil"))
			joined_phase = params and params.phase or nil
			local currentPlayState = ITGOnline and ITGOnline.CurrentUserPlayState and ITGOnline:CurrentUserPlayState(ITGOnline.currentRoom) or nil
			local localReturnKeyActive, localReturnReason = local_client_has_returned_to_lobby_for_current_round()
			local incomingPhase = normalized_online_phase(joined_phase)
			joined_local_returned_to_lobby_after_results = incomingPhase == "results"
				and (tostring(currentPlayState or "") == "returned_to_lobby" or localReturnKeyActive)
			lobby_flow_trace("joined_local_results_return_state"
				.. " phase=" .. tostring(joined_phase)
				.. " currentPlayState=" .. tostring(currentPlayState or "nil")
				.. " localReturnKeyActive=" .. tostring(localReturnKeyActive == true)
				.. " localReturnReason=" .. tostring(localReturnReason or "nil")
				.. " localReturnRoomId=" .. tostring(ITGOnline and ITGOnline.onlineGameplayReturnedLocalRoomId or "nil")
				.. " currentRoomId=" .. tostring(ITGOnline and ITGOnline.currentRoomId or "nil")
				.. " localReturned=" .. tostring(joined_local_returned_to_lobby_after_results == true)
				.. " isManager=" .. tostring(joined_is_manager == true))
			joined_global_options = normalize_global_options(params and params.globalOptions or nil)
			if joined_phase == "results" then
				local selectedSongInfo = normalize_online_song_info(params and params.songInfo or nil)
				if selectedSongInfo then
					joined_song_preview = selectedSongInfo
					joined_song_confirmed = true
					joined_song_selected_key = tostring(selectedSongInfo.selectedAt or selectedSongInfo.selected_at or joined_song_selected_key or "")
					lobby_flow_trace("OnlineLobbyState_results_preserve_song"
						.. " title=" .. tostring(selectedSongInfo.title or selectedSongInfo.songTitle or "")
						.. " selectedAt=" .. tostring(joined_song_selected_key or ""))
				else
					lobby_flow_trace("OnlineLobbyState_results_preserve_existing_song"
						.. " hasPreview=" .. tostring(joined_song_preview ~= nil)
						.. " selectedKey=" .. tostring(joined_song_selected_key or ""))
				end
			else
				local previousSelectedKey = joined_song_selected_key
				local snapshotSource = tostring(params and params.snapshotSource or "")
				local selectedSongInfo = normalize_online_song_info(params and params.songInfo or nil)
				local packSyncResetBySnapshotClear = false
				local stalePostResultsSong = selectedSongInfo ~= nil
					and previousJoinedPhase == "results"
					and joined_phase == "lobby"
					and snapshotSource:find("room.results_ready", 1, true) ~= nil
				if stalePostResultsSong then
					lobby_flow_trace("OnlineLobbyState_drop_stale_post_results_song source=" .. tostring(snapshotSource)
						.. " selectedAt=" .. tostring(selectedSongInfo.selectedAt or selectedSongInfo.selected_at or "")
						.. " song=" .. tostring(selectedSongInfo.title or selectedSongInfo.songTitle or ""))
					selectedSongInfo = nil
				end
				if selectedSongInfo then
					joined_song_preview = selectedSongInfo
					joined_song_confirmed = true
					joined_song_selected_key = tostring(selectedSongInfo.selectedAt or selectedSongInfo.selected_at or "")
				else
					local shouldClearPreview = (previousJoinedPhase == "results" and joined_phase == "lobby")
						or (previousSongConfirmed and joined_phase == "lobby")
						or snapshotSource:find("song_selection_cancel", 1, true) ~= nil
						or snapshotSource:find("room.play_state_reset_to_lobby", 1, true) ~= nil
					if shouldClearPreview then
						reset_joined_transient_song_state("online_lobby_state_clear_unconfirmed_preview", { clearPreview = true, resetPackSync = true })
						packSyncResetBySnapshotClear = true
					end
					joined_song_confirmed = false
					joined_song_selected_key = ""
				end
				if not selectedSongInfo and joined_song_preview == nil then
					restore_active_song_preview(self, "online_lobby_state")
				end
				joined_preview_unknown_pack = joined_song_preview ~= nil and not local_pack_exists(joined_song_preview)
				if selectedSongInfo and joined_song_selected_key ~= previousSelectedKey then
					joined_missing_song = false
					joined_missing_song_info = nil
					joined_can_download_pack = false
					joined_missing_song_reason = nil
				end
			end
			if not joined_song_confirmed then
				joined_song_selected_key = ""
				joined_missing_song = false
				joined_missing_song_info = nil
				joined_can_download_pack = false
				joined_missing_song_reason = nil
				if joined_phase ~= "results"
					and ITGOnline and ITGOnline.PackSync and ITGOnline.PackSync.ResetLocalState then
					if packSyncResetBySnapshotClear then
						lobby_flow_trace("PackSync_reset_skipped reason=no_song_confirmed_already_reset_by_snapshot_clear"
							.. " phase=" .. tostring(joined_phase)
							.. " previousPhase=" .. tostring(previousJoinedPhase)
							.. " snapshotSource=" .. tostring(params and params.snapshotSource or ""))
					else
						ITGOnline.PackSync:ResetLocalState("no_song_confirmed")
					end
				end
				if joined_song_preview and ITGOnline and ITGOnline.PackSync and ITGOnline.PackSync.ManagerBrowsingPreview then
					ITGOnline.PackSync:ManagerBrowsingPreview(joined_song_preview)
				end
			end
			joined_lobby_players = apply_optimistic_config_ready_to_players(
				joined_lobby_players,
				ITGOnline and ITGOnline.currentRoom or nil,
				"online_lobby_state"
			)
			sync_local_missing_song_from_joined_players()
			set_joined_default_active_index(not joined_focus_initialized)
			joined_focus_initialized = true
			lobby_debug("lobby_state room=" .. tostring(joined_lobby_code)
				.. " phase=" .. tostring(joined_phase)
				.. " isManager=" .. tostring(joined_is_manager)
				.. " managerUserId=" .. tostring(joined_manager_user_id)
				.. " players=" .. tostring(#joined_lobby_players)
				.. " readyStates=[" .. ready_summary() .. "]")
				lobby_flow_trace("OnlineLobbyState_applied previous_code=" .. tostring(previousLobbyCode)
				.. " current_code=" .. tostring(joined_lobby_code)
				.. " previous_phase=" .. tostring(previousJoinedPhase)
				.. " current_phase=" .. tostring(joined_phase)
				.. " roomId=" .. tostring(params and params.roomId or "nil")
				.. " snapshotSource=" .. tostring(params and params.snapshotSource or "nil")
				.. " isManager=" .. tostring(joined_is_manager)
				.. " managerUserId=" .. tostring(joined_manager_user_id)
				.. " players=" .. tostring(#joined_lobby_players)
				.. " songConfirmed=" .. tostring(joined_song_confirmed == true)
				.. " preview=" .. tostring(joined_song_preview and (joined_song_preview.title or joined_song_preview.folder_name or joined_song_preview.song_hash) or "none")
				.. " missingSong=" .. tostring(joined_missing_song == true)
				.. " ready={" .. tostring(ready_summary()) .. "}")

			lobby_trace_state.lastOnlineLobbyStateSignature = incomingSignature
			lobby_trace_state.lastOnlineLobbyStateSignatureAt = GetTimeSinceStart()
			self:queuecommand("UpdateJoinedLobbyText")

			if not pack_sync_busy() then
				hide_network_status_if_idle(self)
			end
			self:GetChild("LobbyContent"):visible(false)
			self:GetChild("OnlinePlayersContent"):visible(false)
			self:GetChild("JoinedLobbyContent"):visible(true)
			normalize_joined_active_index()
			self:queuecommand("Hover")
		end,
			OnlineMissingSongMessageCommand=function(self, params)
				if not is_active_lobby_overlay() then
					lobby_flow_trace("OnlineMissingSong_ignored reason=inactive_overlay"
						.. " reasonParam=" .. tostring(params and params.reason or "nil"))
					return
				end
				if mode ~= "joined" or trim_text(joined_lobby_code) == "" then
					lobby_flow_trace("OnlineMissingSong_ignored reason=not_joined_mode"
						.. " mode=" .. tostring(mode)
						.. " joined_code=" .. tostring(joined_lobby_code)
						.. " reasonParam=" .. tostring(params and params.reason or "nil"))
					return
				end
				local incomingSongInfo = params and params.songInfo or joined_song_preview
				if not song_info_matches_current_room_selection(incomingSongInfo) then
					lobby_flow_trace("OnlineMissingSong_ignored reason=stale_or_no_active_selection"
						.. " reasonParam=" .. tostring(params and params.reason or "nil")
						.. " incomingSelectedAt=" .. tostring(lobby_song_selected_at(incomingSongInfo))
						.. " roomSelectedAt=" .. tostring(lobby_song_selected_at(current_room_selected_song_info()))
						.. " incomingPack=" .. tostring(incomingSongInfo and song_info_pack(incomingSongInfo) or "")
						.. " roomPack=" .. tostring(current_room_selected_song_info() and song_info_pack(current_room_selected_song_info()) or "")
						.. " phase=" .. tostring(joined_phase))
					return
				end
				if normalized_online_phase(joined_phase) == "results"
					or (ITGOnline and ITGOnline.currentRoom and normalized_online_phase(ITGOnline.currentRoom.phase) == "results") then
					lobby_flow_trace("OnlineMissingSong_ignored reason=results_phase"
						.. " reasonParam=" .. tostring(params and params.reason or "nil")
						.. " joinedPhase=" .. tostring(joined_phase)
						.. " roomPhase=" .. tostring(ITGOnline and ITGOnline.currentRoom and ITGOnline.currentRoom.phase or "nil")
						.. " currentPreviewPack=" .. tostring(joined_song_preview and song_info_pack(joined_song_preview) or ""))
					reset_joined_transient_song_state("missing_song_ignored_results_phase", { clearPreview = true, resetPackSync = false })
					self:queuecommand("UpdateJoinedLobbyText")
					return
				end
				local missingReason = params and params.reason or "missing_local_song"
				local missingSignature = table.concat({
					tostring(joined_lobby_code or ""),
					tostring(lobby_song_selected_at(incomingSongInfo)),
					tostring(missingReason),
					tostring(params and params.noCompatibleChart == true),
					tostring(params and params.chartMismatch == true),
				}, "|")
				local now = GetTimeSinceStart and GetTimeSinceStart() or 0
				if missingSignature ~= ""
					and missingSignature == tostring(lobby_trace_state.lastOnlineMissingSongSignature or "")
					and (now - (tonumber(lobby_trace_state.lastOnlineMissingSongSignatureAt) or 0)) < lobby_trace_state.onlineMissingSongDuplicateWindow then
					lobby_flow_trace("OnlineMissingSong_ignored reason=duplicate_signature"
						.. " signature=" .. tostring(missingSignature)
						.. " age=" .. string.format("%.3f", now - (tonumber(lobby_trace_state.lastOnlineMissingSongSignatureAt) or 0)))
					return
				end
				lobby_trace_state.lastOnlineMissingSongSignature = missingSignature
				lobby_trace_state.lastOnlineMissingSongSignatureAt = now
				lobby_flow_trace("OnlineMissingSong_received reason=" .. tostring(params and params.reason or "missing_local_song")
					.. " hasSongInfo=" .. tostring(params and params.songInfo ~= nil)
					.. " noCompatibleChart=" .. tostring(params and params.noCompatibleChart == true)
					.. " currentPreviewPack=" .. tostring(joined_song_preview and song_info_pack(joined_song_preview) or "")
					.. " mode=" .. tostring(mode)
					.. " joined_code=" .. tostring(joined_lobby_code)
					.. " phase=" .. tostring(joined_phase))
				joined_missing_song = true
			joined_missing_song_info = incomingSongInfo
			joined_missing_song_reason = missingReason
			joined_can_download_pack = params and (
				params.noCompatibleChart == true
				or can_download_pack_for_reason(params.reason)
			) or false
			lobby_flow_trace("OnlineMissingSong_state missing=true canDownload=" .. tostring(joined_can_download_pack)
				.. " selectedKey=" .. tostring(joined_song_selected_key)
				.. " confirmed=" .. tostring(joined_song_confirmed))
			if ITGOnline and ITGOnline.ReportSongAvailability then
				lobby_flow_trace("OnlineMissingSong_report_availability missing=true reason=" .. tostring(params and params.reason or "missing_local_song"))
				ITGOnline:ReportSongAvailability(true, params and params.reason or "missing_local_song")
			end
			if params and params.songInfo then
				joined_song_preview = params.songInfo
				joined_song_confirmed = true
				lobby_flow_trace("OnlineMissingSong_preview_promoted pack=" .. tostring(song_info_pack(params.songInfo))
					.. " song=" .. tostring(params.songInfo.song or params.songInfo.title or ""))
			end
			local reason = missingReason
			if reason == "download_failed" and not (params and params.downloadAttemptFailed == true) then
				lobby_flow_trace("OnlineMissingSong_download_failed candidates=" .. tostring(type(pack_choice_last_candidates) == "table" and #pack_choice_last_candidates or 0)
					.. " selectedPackId=" .. tostring(pack_choice_last_selected_pack_id))
				if (#pack_choice_last_candidates == 0) and SL and SL.Global and SL.Global.Online and type(SL.Global.Online.PackChoiceRecovery.candidates) == "table" then
					pack_choice_last_candidates = SL.Global.Online.PackChoiceRecovery.candidates
					pack_choice_last_song_info = SL.Global.Online.PackChoiceRecovery.songInfo
					pack_choice_last_selected_pack_id = SL.Global.Online.PackChoiceRecovery.selectedPackId
					lobby_flow_trace("OnlineMissingSong_recovered_pack_choice candidates=" .. tostring(#pack_choice_last_candidates)
						.. " selectedPackId=" .. tostring(pack_choice_last_selected_pack_id))
				end
				local reopened = false
				if type(pack_choice_last_candidates) == "table" and #pack_choice_last_candidates > 1 then
					local alternatives = {}
					local lastId = tonumber(pack_choice_last_selected_pack_id)
					for _, candidate in ipairs(pack_choice_last_candidates) do
						local candidateId = tonumber(candidate and candidate.id)
						if not lastId or not candidateId or candidateId ~= lastId then
							alternatives[#alternatives + 1] = candidate
						end
					end
					if #alternatives > 0 then
						lobby_flow_trace("OnlineMissingSong_reopen_pack_choice alternatives=" .. tostring(#alternatives))
						reopened = open_pack_choice_menu(
							pack_choice_last_song_info or joined_missing_song_info or joined_song_preview,
							alternatives,
							online_lobby_text("ChosenPackMissingChart", "The selected pack did not provide the expected chart. Choose another pack.")
						)
					end
				end
				if not reopened then
					lobby_flow_trace("OnlineMissingSong_pack_choice_exhausted")
					pack_choice_all_candidates_exhausted = true
					self:playcommand("SetStatus", {
						text=online_lobby_text("NoCandidateContainsChart", "None of the tested packs contains the expected chart.\nManual installation is required for this song."),
						showSpinner=false,
						showPrompt=true
					})
				end
			elseif reason == "download_failed" then
				lobby_flow_trace("OnlineMissingSong_download_attempt_failed message=" .. tostring(params and params.message or "nil"))
				self:playcommand("SetStatus", {
					text = tostring(params and params.message or "Le téléchargement du pack a échoué. Vous pouvez réessayer."),
					showSpinner = false,
					showPrompt = true,
				})
			end
			set_joined_default_active_index()
			lobby_flow_trace("OnlineMissingSong_update_ui")
			self:queuecommand("UpdateJoinedLobbyText")
			self:queuecommand("Hover")
		end,
			OnlineSongAvailableMessageCommand=function(self, params)
				if not is_active_lobby_overlay() then
					lobby_flow_trace("OnlineSongAvailable_ignored reason=inactive_overlay")
					return
				end
				if mode ~= "joined" or trim_text(joined_lobby_code) == "" then
					lobby_flow_trace("OnlineSongAvailable_ignored reason=not_joined_mode"
						.. " mode=" .. tostring(mode)
						.. " joined_code=" .. tostring(joined_lobby_code)
						.. " incomingSelectedAt=" .. tostring(lobby_song_selected_at(params and params.songInfo or nil))
						.. " roomSelectedAt=" .. tostring(lobby_song_selected_at(current_room_selected_song_info())))
					return
				end
				local wasMissing = joined_missing_song
				local availabilitySongInfo = params and params.songInfo or joined_missing_song_info or joined_song_preview
				local canReportAvailability = song_info_matches_current_room_selection(availabilitySongInfo)
			lobby_flow_trace("OnlineSongAvailable_received wasMissing=" .. tostring(wasMissing)
				.. " mode=" .. tostring(mode)
				.. " joined_code=" .. tostring(joined_lobby_code)
				.. " phase=" .. tostring(joined_phase)
				.. " currentPreviewPack=" .. tostring(joined_song_preview and song_info_pack(joined_song_preview) or "")
				.. " incomingSelectedAt=" .. tostring(lobby_song_selected_at(availabilitySongInfo))
				.. " roomSelectedAt=" .. tostring(lobby_song_selected_at(current_room_selected_song_info()))
				.. " canReportAvailability=" .. tostring(canReportAvailability == true))
			joined_missing_song = false
			joined_missing_song_info = nil
			joined_can_download_pack = false
			joined_missing_song_reason = nil
			lobby_trace_state.lastOnlineMissingSongSignature = ""
			lobby_trace_state.lastOnlineMissingSongSignatureAt = 0
			if wasMissing and canReportAvailability and ITGOnline and ITGOnline.ReportSongAvailability then
				lobby_flow_trace("OnlineSongAvailable_report_availability missing=false reason=reloaded")
				ITGOnline:ReportSongAvailability(false, "reloaded")
			elseif wasMissing and not canReportAvailability then
				lobby_flow_trace("OnlineSongAvailable_report_skipped reason=stale_or_no_active_selection")
			end
			normalize_joined_active_index()
			lobby_flow_trace("OnlineSongAvailable_update_ui")
			self:queuecommand("UpdateJoinedLobbyText")
			self:queuecommand("Hover")
		end,
		OnlineLobbyJoinSelectedMessageCommand=function(self, params)
			if not is_active_lobby_overlay() then
			lobby_flow_trace("OnlineLobbyJoinSelected_ignored reason=inactive_overlay code=" .. tostring(params and params.code or "nil"))
			return
		end
		if not params or not params.code then
			lobby_flow_trace("OnlineLobbyJoinSelected_ignored reason=missing_code")
			play_online_sound_once("Common", "Cancel")
			return
		end
		lobby_flow_trace("OnlineLobbyJoinSelected_received code=" .. tostring(params.code)
			.. " visibility=" .. tostring(params.visibility or "public")
			.. " acceptsNewMembers=" .. tostring(params.acceptsNewMembers)
			.. " acceptsJoinRequests=" .. tostring(params.acceptsJoinRequests)
			.. " joinMode=" .. tostring(params.joinMode)
			.. " phase=" .. tostring(params.phase)
			.. " mode=" .. tostring(mode)
			.. " currentRoomId=" .. tostring(ITGOnline and ITGOnline.currentRoomId or "nil"))
		-- The lobby list is only a cache.  RequestJoinRoom performs a mandatory
		-- FetchLobby preflight immediately before POST /join, so a stale config
		-- snapshot must never reject a room that has just returned to lobby.
		local cachedAcceptsJoin = tostring(params.visibility or "public") == "private"
			and params.acceptsJoinRequests or params.acceptsNewMembers
		if cachedAcceptsJoin == false then
			lobby_flow_trace("OnlineLobbyJoinSelected_stale_non_joinable_hint_ignored code=" .. tostring(params.code)
				.. " cachedPhase=" .. tostring(params.phase)
				.. " action=refresh_then_server_authoritative_join")
		end

		join_lobby_code = params.code
		self:GetChild("LobbyContent"):visible(false)
		self:GetChild("OnlinePlayersContent"):visible(false)
		self:playcommand("SetStatus", {
			text=online_lobby_text("JoiningLobby", "Joining lobby..."),
			showSpinner=true,
			showPrompt=false
		})
		begin_join_timeout(self)
		lobby_flow_trace("OnlineLobbyJoinSelected_broadcast_join code=" .. tostring(params.code))
		MESSAGEMAN:Broadcast("JoinLobby", {
			code=params.code,
			visibility=params.visibility,
		})
	end,
		OnlineLobbyLeftMessageCommand=function(self, params)
			if not is_active_lobby_overlay() then
				lobby_flow_trace("OnlineLobbyLeftMessage_ignored reason=inactive_overlay")
				return
			end
			local eventLobbyCode = params and (params.lobbyCode or params.code or params.roomCode or params.roomId) or nil
			eventLobbyCode = eventLobbyCode and tostring(eventLobbyCode) or nil
			if eventLobbyCode ~= nil and eventLobbyCode ~= "" then
				local activeLobbyCode = tostring(joined_lobby_code or "")
				local pendingLobbyCode = tostring(SL.Global.Online.ScreenOnlineLobbiesLeaveRequestCode or "")
				local pendingRoomId = tostring(SL.Global.Online.ScreenOnlineLobbiesLeaveRequestRoomId or "")
				local activeRoomId = tostring(ITGOnline and ITGOnline.currentRoomId or "")
				if activeLobbyCode ~= eventLobbyCode and pendingLobbyCode ~= eventLobbyCode and pendingRoomId ~= eventLobbyCode and activeRoomId ~= eventLobbyCode then
					lobby_flow_trace(
						"OnlineLobbyLeftMessage_ignored reason=room_mismatch event_code=" .. tostring(eventLobbyCode) ..
						" joined_code=" .. tostring(joined_lobby_code) ..
						" request_code=" .. tostring(SL.Global.Online.ScreenOnlineLobbiesLeaveRequestCode) ..
						" request_room_id=" .. tostring(SL.Global.Online.ScreenOnlineLobbiesLeaveRequestRoomId) ..
						" currentRoomId=" .. tostring(ITGOnline and ITGOnline.currentRoomId))
					return
				end
			end
			lobby_flow_trace(
				"OnlineLobbyLeftMessage_begin left=" .. tostring(params and params.left) ..
				" leaving_lobby=" .. tostring(leaving_lobby) ..
				" joined_code=" .. tostring(joined_lobby_code) ..
				" event_code=" .. tostring(eventLobbyCode) ..
				" currentRoomId=" .. tostring(ITGOnline and ITGOnline.currentRoomId or "nil") ..
				" mode=" .. tostring(mode))
			if params == nil or params.left == nil or params.left then
				clear_pending_join()
				clear_pending_create()
				finish_leave_lobby(self, eventLobbyCode)
			end
			lobby_flow_trace("OnlineLobbyLeftMessage_end")
		end,
	OnlinePrivateJoinRequestMessageCommand=function(self, params)
		if not is_active_lobby_overlay() then
			lobby_flow_trace("OnlinePrivateJoinRequest_ignored reason=inactive_overlay")
			return
		end
		if leaving_lobby then
			lobby_flow_trace("OnlinePrivateJoinRequest_ignored reason=leaving_lobby")
			return
		end
	if not params or not params.join_request then
		lobby_flow_trace("OnlinePrivateJoinRequest_ignored reason=missing_join_request")
		return
	end
	lobby_flow_trace("OnlinePrivateJoinRequest_received requester=" .. tostring(params.join_request.user_id or params.join_request.player_id or "")
		.. " room=" .. tostring(params.join_request.room_id or "")
		.. " mode=" .. tostring(mode)
		.. " joined_code=" .. tostring(joined_lobby_code)
		.. " currentRoomId=" .. tostring(ITGOnline and ITGOnline.currentRoomId or "nil"))
	enqueue_private_prompt(self, params, "join_request")
end,
	OnlinePrivateJoinRequestCancelledMessageCommand=function(self, params)
		if not is_active_lobby_overlay() then
			lobby_flow_trace("OnlinePrivateJoinRequestCancelled_ignored reason=inactive_overlay")
			return
		end
		local joinRequestId = params and (params.join_request_id or params.joinRequestId) or nil
		local requestId = tostring(joinRequestId or "")
		local promptKey = "join_request:" .. requestId
		local filtered = {}
		local removed = false
		if requestId ~= "" then
			for _, queued in ipairs(private_prompt_queue) do
				if queued.key == promptKey then
					private_prompt_keys[queued.key] = nil
					removed = true
				else
					filtered[#filtered + 1] = queued
				end
			end
			private_prompt_queue = filtered
			local activeRequest = private_join_prompt_kind == "join_request"
				and private_join_request
				and private_join_request.join_request
			if activeRequest and tostring(activeRequest.id or "") == requestId then
				finish_private_prompt(self)
				removed = true
			end
			private_prompt_keys[promptKey] = nil
		end
		lobby_flow_trace("OnlinePrivateJoinRequestCancelled_apply joinRequestId=" .. tostring(joinRequestId or "nil")
			.. " removed=" .. tostring(removed == true)
			.. " reason=" .. tostring(params and params.reason or "nil"))
	end,
	OnlineRoomInvitationMessageCommand=function(self, params)
		if not is_active_lobby_overlay() then
			lobby_flow_trace("OnlineRoomInvitation_ignored reason=inactive_overlay")
			return
		end
		if leaving_lobby then
			lobby_flow_trace("OnlineRoomInvitation_ignored reason=leaving_lobby")
			return
		end
	if not params or not params.invitation then
		lobby_flow_trace("OnlineRoomInvitation_ignored reason=missing_invitation")
		return
	end
	lobby_flow_trace("OnlineRoomInvitation_received inviter=" .. tostring(params.invitation.inviter_user_id or params.invitation.inviter_id or params.invitation.user_id or "")
		.. " room=" .. tostring(params.invitation.room_id or "")
		.. " mode=" .. tostring(mode)
		.. " joined_code=" .. tostring(joined_lobby_code)
		.. " currentRoomId=" .. tostring(ITGOnline and ITGOnline.currentRoomId or "nil"))
	enqueue_private_prompt(self, params, "invitation")
	end,
			OnlineSongPreviewMessageCommand=function(self, params)
				if not is_active_lobby_overlay() then
					lobby_flow_trace("OnlineSongPreview_ignored reason=inactive_overlay")
					return
				end
				if leaving_lobby then
					lobby_flow_trace("OnlineSongPreview_ignored reason=leaving_lobby")
					return
				end
				if normalized_online_phase(joined_phase) == "results"
					or (ITGOnline and ITGOnline.currentRoom and normalized_online_phase(ITGOnline.currentRoom.phase) == "results") then
					lobby_flow_trace("OnlineSongPreview_ignored reason=results_phase"
						.. " joinedPhase=" .. tostring(joined_phase)
						.. " roomPhase=" .. tostring(ITGOnline and ITGOnline.currentRoom and ITGOnline.currentRoom.phase or "nil")
						.. " joined_code=" .. tostring(joined_lobby_code)
						.. " currentRoomId=" .. tostring(ITGOnline and ITGOnline.currentRoomId or "nil"))
					reset_joined_transient_song_state("song_preview_ignored_results_phase", { clearPreview = true, resetPackSync = false })
					self:queuecommand("UpdateJoinedLobbyText")
					return
				end
			local preview = normalize_online_song_info(params)
		if preview then
			lobby_flow_trace("OnlineSongPreview_received pack=" .. tostring(song_info_pack(preview))
				.. " song=" .. tostring(preview.song or preview.title or "")
				.. " mode=" .. tostring(mode)
				.. " joined_code=" .. tostring(joined_lobby_code)
				.. " phase=" .. tostring(joined_phase)
				.. " currentRoomId=" .. tostring(ITGOnline and ITGOnline.currentRoomId or "nil"))
			reset_joined_transient_song_state("song_preview_received", { clearPreview = false, resetPackSync = false })
			joined_song_preview = preview
			joined_song_confirmed = false
			joined_song_selected_key = ""
			joined_preview_unknown_pack = not local_pack_exists(preview)
			lobby_flow_trace("OnlineSongPreview_state confirmed=false unknownPack=" .. tostring(joined_preview_unknown_pack)
				.. " selectedKeyCleared=true")
			if ITGOnline and ITGOnline.PackSync and ITGOnline.PackSync.ManagerBrowsingPreview then
				lobby_flow_trace("OnlineSongPreview_manager_browsing_preview")
				ITGOnline.PackSync:ManagerBrowsingPreview(preview)
			end
			if joined_preview_unknown_pack then
				lobby_trace_state.joinedPreviewPlaybackKey = ""
				if stop_music then
					lobby_flow_trace("OnlineSongPreview_stop_music reason=unknown_local_pack"
						.. " pack=" .. tostring(song_info_pack(preview))
						.. " song=" .. tostring(preview.song or preview.title or ""))
					stop_music()
				end
			else
				play_joined_song_preview(preview, "online_lobby_song_preview")
			end
			self:queuecommand("UpdateJoinedLobbyText")
		else
			lobby_trace_state.joinedPreviewPlaybackKey = ""
			if stop_music then
				lobby_flow_trace("OnlineSongPreview_stop_music reason=normalize_failed")
				stop_music()
			end
			lobby_flow_trace("OnlineSongPreview_ignored reason=normalize_failed")
		end
	end,
	OnlineSongPreviewClearedMessageCommand=function(self, params)
		if not is_active_lobby_overlay() then
			lobby_flow_trace("OnlineSongPreviewCleared_ignored reason=inactive_overlay")
			return
		end
		local requestedSession = trim_text(params and (params.preview_session_id or params.previewSessionId))
		local activeSession = trim_text(joined_song_preview and (joined_song_preview.preview_session_id or joined_song_preview.previewSessionId))
		if requestedSession ~= "" and activeSession ~= "" and requestedSession ~= activeSession then
			lobby_flow_trace("OnlineSongPreviewCleared_ignored reason=session_mismatch"
				.. " requestedSession=" .. tostring(requestedSession)
				.. " activeSession=" .. tostring(activeSession))
			return
		end
		lobby_flow_trace("OnlineSongPreviewCleared_received room=" .. tostring(params and (params.room_id or params.roomId) or "nil")
			.. " session=" .. tostring(requestedSession)
			.. " activeSession=" .. tostring(activeSession))
		reset_joined_transient_song_state("song_preview_cleared", { clearPreview = true, resetPackSync = true })
		if stop_music then stop_music() end
		self:queuecommand("UpdateJoinedLobbyText")
		request_lobby_ui_repaint(self, "song_preview_cleared")
		self:queuecommand("Hover")
	end,
	OnlineSongReloadCompletedMessageCommand=function(self)
		if not is_active_lobby_overlay() or leaving_lobby then return end
		lobby_flow_trace("OnlineSongReloadCompleted_received restoring_active_preview=true")
		restore_active_song_preview(self, "song_reload_completed")
	end,
		OnlinePackSyncReloadSongsMessageCommand=function(self)
			if not is_active_lobby_overlay() then
				lobby_flow_trace("OnlinePackSyncReloadSongs_ignored reason=inactive_overlay")
				return
			end
			if leaving_lobby then
				lobby_flow_trace("OnlinePackSyncReloadSongs_ignored reason=leaving_lobby")
				return
			end
		lobby_flow_trace("OnlinePackSyncReloadSongs_received mode=" .. tostring(mode)
			.. " joined_code=" .. tostring(joined_lobby_code)
			.. " currentRoomId=" .. tostring(ITGOnline and ITGOnline.currentRoomId or "nil"))
		transition_to_online_song_reload()
	end,
		OnlinePackSyncLocalStatusMessageCommand=function(self, params)
			if not is_active_lobby_overlay() then
				lobby_flow_trace("OnlinePackSyncLocalStatus_ignored reason=inactive_overlay")
				return
			end
				if leaving_lobby then
					lobby_flow_trace("OnlinePackSyncLocalStatus_ignored reason=leaving_lobby")
					return
				end
				if normalized_online_phase(joined_phase) == "results"
					or (ITGOnline and ITGOnline.currentRoom and normalized_online_phase(ITGOnline.currentRoom.phase) == "results") then
					lobby_flow_trace("OnlinePackSyncLocalStatus_ignored reason=results_phase status=" .. tostring(params and params.status or "")
						.. " progress=" .. tostring(params and params.progress or "")
						.. " joinedPhase=" .. tostring(joined_phase)
						.. " roomPhase=" .. tostring(ITGOnline and ITGOnline.currentRoom and ITGOnline.currentRoom.phase or "nil"))
					reset_joined_transient_song_state("pack_sync_status_ignored_results_phase", { clearPreview = true, resetPackSync = false })
					self:queuecommand("UpdateJoinedLobbyText")
					return
				end
		local localStatusSignature = pack_sync_local_status_signature(params)
		if localStatusSignature ~= ""
			and localStatusSignature == lobby_trace_state.lastPackSyncLocalStatusSignature
		then
			lobby_trace_state.lastPackSyncLocalStatusAt = GetTimeSinceStart()
			lobby_flow_trace("OnlinePackSyncLocalStatus_ignored reason=duplicate_signature status=" .. tostring(params and params.status or "")
				.. " progress=" .. tostring(params and (params.download_progress or params.progress) or "")
				.. " joined_code=" .. tostring(joined_lobby_code)
				.. " phase=" .. tostring(joined_phase))
			return
		end
		local effectiveMode = tostring(params and params.mode or mode or "")
		local effectiveJoinedCode = tostring(joined_lobby_code or "")
		if effectiveJoinedCode == "" then
			effectiveJoinedCode = tostring(params and (params.room_id or params.roomId) or ITGOnline and ITGOnline.currentRoomId or "")
		end
		if effectiveJoinedCode ~= "" then
			effectiveMode = "joined"
		end
		lobby_flow_trace("OnlinePackSyncLocalStatus_received status=" .. tostring(params and params.status or "")
			.. " progress=" .. tostring(params and params.progress or "")
			.. " userId=" .. tostring(params and params.userId or params and params.user_id or "")
			.. " mode=" .. tostring(effectiveMode)
			.. " joined_code=" .. tostring(effectiveJoinedCode)
			.. " ui_mode=" .. tostring(mode)
			.. " ui_joined_code=" .. tostring(joined_lobby_code))
		apply_local_pack_sync_status_to_joined_player(params)
		lobby_trace_state.lastPackSyncLocalStatusSignature = localStatusSignature
		lobby_trace_state.lastPackSyncLocalStatusAt = GetTimeSinceStart()
		normalize_joined_active_index()
		self:queuecommand("UpdateJoinedLobbyText")
		self:queuecommand("Hover")
	end,
		OnlinePackDownloadedMessageCommand=function(self, params)
			if not is_active_lobby_overlay() then
				lobby_flow_trace("OnlinePackDownloaded_ignored reason=inactive_overlay")
				return
			end
			if leaving_lobby then
				lobby_flow_trace("OnlinePackDownloaded_ignored reason=leaving_lobby")
				return
			end
		lobby_flow_trace("OnlinePackDownloaded_received pack=" .. tostring(params and params.songInfo and song_info_pack(params.songInfo) or "")
			.. " currentPreviewPack=" .. tostring(joined_song_preview and song_info_pack(joined_song_preview) or "")
			.. " mode=" .. tostring(mode)
			.. " currentRoomId=" .. tostring(ITGOnline and ITGOnline.currentRoomId or "nil"))
		if params and params.songInfo and ITGOnline and ITGOnline.PackSync and ITGOnline.PackSync.MarkPackInstalled then
			lobby_flow_trace("OnlinePackDownloaded_mark_installed pack=" .. tostring(song_info_pack(params.songInfo)))
			ITGOnline.PackSync:MarkPackInstalled(song_info_pack(params.songInfo))
		end
		if joined_song_preview == nil then
			restore_active_song_preview(self, "online_pack_downloaded")
		end
		if params and params.songInfo and joined_song_preview and song_info_pack(params.songInfo) == song_info_pack(joined_song_preview) then
			joined_preview_unknown_pack = false
			lobby_flow_trace("OnlinePackDownloaded_matches_preview refreshing_joined_ui pack=" .. tostring(song_info_pack(params.songInfo)))
			if ITGOnline and ITGOnline.PackSync and ITGOnline.PackSync.ManagerBrowsingPreview then
				lobby_flow_trace("OnlinePackDownloaded_recheck_manager_preview")
				ITGOnline.PackSync:ManagerBrowsingPreview(joined_song_preview)
			end
			play_joined_song_preview(joined_song_preview, "online_pack_downloaded_resume_preview")
			normalize_joined_active_index()
			self:queuecommand("UpdateJoinedLobbyText")
			request_lobby_ui_repaint(self, "online_pack_downloaded")
			self:queuecommand("Hover")
		end
		refresh_joined_room_snapshot("online_pack_downloaded", self)
	end,
	ITGOnlineSessionInvalidatedMessageCommand=function(self, params)
		params = type(params) == "table" and params or {}
		local message = tostring(params.message or "")
		if message == "" then
			message = online_lobby_text("SessionOpenedElsewhere", "This session was opened elsewhere. Reconnect this player with a different account.")
		end
		lobby_flow_trace("session_invalidated_received reason=" .. tostring(params.reason or "nil")
			.. " message=" .. tostring(message)
			.. " mode=" .. tostring(mode)
			.. " joined_code=" .. tostring(joined_lobby_code)
			.. " currentRoomId=" .. tostring(ITGOnline and ITGOnline.currentRoomId or "nil")
			.. " leaving=" .. tostring(leaving_lobby == true))
		connected = false
		has_error = true
		leaving_lobby = false
		mode = "browse"
		list_selected = false
		holding.MenuLeft = false
		holding.MenuRight = false
		clear_pending_join()
		clear_pending_create()
		stop_lobby_overlay_timers(self)
		close_transient_joined_ui()
		reset_joined_lobby_state()
		reset_browse_focus()
		candidates = {}
		online_users = {}
		lobby_trace_state.lastOnlineLobbyStateSignature = ""
		lobby_trace_state.lastOnlineLobbyStateSignatureAt = 0
		request_lobby_ui_repaint(self, "session_invalidated")
		self:playcommand("SetStatus", {
			text=message,
			showSpinner=false,
			showPrompt=true,
			force=true,
			critical=true,
		})
	end,
			OnlineResponseStatusMessageCommand=function(self, params)
				if not is_active_lobby_overlay() then
					lobby_flow_trace("OnlineResponseStatus_ignored reason=inactive_overlay event=" .. tostring(params and params.event or "nil"))
					return
				end
				lobby_flow_trace("OnlineResponseStatus_received event=" .. tostring(params and params.event or "nil")
					.. " success=" .. tostring(params and params.success == true)
					.. " critical=" .. tostring(params and params.critical == true)
					.. " errorCode=" .. tostring(params and (params.errorCode or params.error_code) or "nil")
					.. " message=" .. tostring(params and params.message or "nil"))
				if params and params.event == "createLobby" and params.success == false then
				lobby_flow_trace("OnlineResponseStatus_apply event=createLobby success=false action=restore_browse")
				clear_pending_create()
				mode = "browse"
				self:GetChild("JoinedLobbyContent"):visible(false)
				request_lobby_ui_repaint(self, "online_response_create_failed")
		elseif params and params.event == "joinLobby" and params.success == true then
			lobby_flow_trace("OnlineResponseStatus_apply event=joinLobby success=true action=begin_join_timeout")
			begin_join_timeout(self, 60)
		elseif params and params.event == "joinLobby" and params.success == false then
			if ITGOnline and ITGOnline.currentRoomId ~= nil then
				lobby_flow_trace("OnlineResponseStatus_ignored event=joinLobby success=false reason=current_room_active"
					.. " currentRoomId=" .. tostring(ITGOnline.currentRoomId)
					.. " roomId=" .. tostring(params.roomId or "nil")
					.. " joinRequestId=" .. tostring(params.joinRequestId or "nil"))
				return
			end
			lobby_flow_trace("OnlineResponseStatus_apply event=joinLobby success=false action=restore_browse")
			clear_pending_join()
			mode = "browse"
			self:GetChild("JoinedLobbyContent"):visible(false)
			request_lobby_ui_repaint(self, "online_response_join_failed")
			local errorCode = tostring(params.errorCode or params.error_code or "")
			local message = tostring(params.message
				or online_lobby_text("JoinLobbyFailed", "Could not join the lobby."))
			local retryAfterSeconds = math.max(0, math.ceil(tonumber(params.retryAfterSeconds or params.retry_after_seconds) or 30))
			local localizationKey = nil
			if errorCode == "room_join_request_declined" then
				localizationKey = "JoinRequestDeclined"
			elseif errorCode == "room_join_request_retry_cooldown" then
				localizationKey = "JoinRequestRetryCooldown"
			elseif errorCode == "room_join_request_expired" then
				localizationKey = "JoinRequestExpired"
			elseif errorCode == "room_join_request_cancelled" then
				localizationKey = "JoinRequestCancelled"
			end
			if localizationKey and THEME:HasString("ScreenOnlineLobbies", localizationKey) then
				message = THEME:GetString("ScreenOnlineLobbies", localizationKey)
				if localizationKey == "JoinRequestDeclined" or localizationKey == "JoinRequestRetryCooldown" then
					local formatted, localizedMessage = pcall(string.format, message, retryAfterSeconds)
					if formatted then message = localizedMessage end
				end
			end
			if errorCode == "room_join_request_declined" and params.reason and tostring(params.reason) ~= "" then
				message = message .. " " .. tostring(params.reason)
			end
			lobby_flow_trace("OnlineResponseStatus_displayed event=joinLobby success=false"
				.. " errorCode=" .. tostring(errorCode ~= "" and errorCode or "unspecified")
				.. " roomId=" .. tostring(params.roomId or "nil")
				.. " joinRequestId=" .. tostring(params.joinRequestId or "nil")
				.. " retryAfterSeconds=" .. tostring(retryAfterSeconds)
				.. " localizationKey=" .. tostring(localizationKey or "none")
				.. " duration=8")
			self:playcommand("SetStatus", {
				text=message,
				showSpinner=false,
				showPrompt=true,
				duration=8,
			})
			elseif params and params.event == "leaveLobby" and params.success == false then
				lobby_flow_trace("OnlineResponseStatus_apply event=leaveLobby success=false action=restore_joined"
					.. " errorCode=" .. tostring(params.errorCode or params.error_code or "nil"))
				restore_joined_after_blocked_leave(self, tostring(params.errorCode or params.error_code or "leave_failed"), params.message)
		elseif params and params.event == "invitePlayer" then
				if params.success then
				else
					mode = "browse"
					self:GetChild("JoinedLobbyContent"):visible(false)
					request_lobby_ui_repaint(self, "online_response_invite_failed")
				end
		elseif params and params.event == "privateJoinAnswer" then
		elseif params and params.event == "roomInvitationAnswer" then
			elseif params and params.event == "cancelSongSelection" then
			elseif params and params.message then
			end
		end,
		OnlineOptionsRedirectWaitMessageCommand=function(self, params)
			local show = params and params.show == true
			lobby_flow_trace("OnlineOptionsRedirectWait show=" .. tostring(show)
				.. " reason=" .. tostring(params and params.reason or "nil")
				.. " roomId=" .. tostring(params and params.roomId or ITGOnline and ITGOnline.currentRoomId or "nil")
				.. " phase=" .. tostring(joined_phase)
				.. " mode=" .. tostring(mode))
			if show then
				self:playcommand("SetStatus", {
					text=online_lobby_text("WaitingOptionsRedirect", "Waiting to be redirected to the options screen."),
					showSpinner=true,
					showPrompt=false,
					force=true,
					critical=true,
				})
				return
			end
			network_status_clear_at = 0
			local status = self:GetChild("NetworkStatus")
			if status then
				status:visible(false)
			end
		end,

	Def.ActorFrame{
		Name="LobbyContent",
		InitCommand=function(self)
			self:visible(false)
		end,
  
			Def.ActorFrame{
				Name="LobbyList",
			InitCommand=function(self)
				self:x(lobby_layout.browseLobbyX)
				self.idx = 0
			end,
			OnCommand=function(self)
				self:playcommand("UpdateData", {data=candidates})
			end,

			Def.Quad{
				InitCommand=function(self)
					self:zoomto(lobby_layout.browsePanelWidth,lobby_layout.browsePanelHeight):y(lobby_layout.browsePanelY):diffuse(Color.White)
				end,
				HoverCommand=function(self)
					if list_selected and lobby_view == "lobbies" then
						self:diffuse(Color.Green)
					elseif not list_selected then
						self:diffuse(active_index == self:GetParent().idx and Color.Yellow or Color.White)
					end
				end,
				SelectedCommand=function(self)
					if (list_selected and lobby_view == "lobbies") or active_index == self:GetParent().idx then
						self:diffuse(Color.Green)
					else
						self:diffuse(Color.White)
					end
				end
			},

			Def.Quad{
				InitCommand=function(self)
					self:zoomto(lobby_layout.browsePanelWidth-2,lobby_layout.browsePanelHeight-2):y(lobby_layout.browsePanelY):diffuse(Color.Black)
				end
			},

			Def.Quad{
				InitCommand=function(self)
					self:zoomto(lobby_layout.browsePanelWidth-10, 1):y(-150):diffuse(Color.White)
				end
			},

			LoadFont("Common Bold")..{
					Text=online_lobby_text("AvailableLobbies", "Available lobbies"),
				InitCommand=function(self)
					self:horizalign(left):x(-(lobby_layout.browsePanelWidth/2)+8):y(-170):zoom(0.42)
				end,
				HoverCommand=function(self)
					self:diffuse(active_index == self:GetParent().idx and GetHexColor(SL.Global.ActiveColorIndex) or Color.White)
				end
			},

			LoadFont("Common Normal")..{
				Name="LobbyCount",
				Text="0/0",
				InitCommand=function(self)
					self:horizalign(right):x((lobby_layout.browsePanelWidth/2)-8):y(-170):zoom(0.58)
				end,
				UpdateIndexCommand=function(self, params)
					self:settext(params.idx .. "/" .. params.total)
				end
			},

			LoadActor("LobbyInfo.lua")
		},

		LoadFont("Common Normal")..{
			Name="EmptyStateText",
				Text=online_lobby_text("NoLobbies", "No lobbies found."),
			InitCommand=function(self)
				self:horizalign(center):xy(lobby_layout.browseLobbyX, -118):zoom(0.72):diffuse(Color.White):visible(false)
			end
		},

		Def.ActorFrame{
			Name="OnlinePlayersButton",
			InitCommand=function(self)
				self:visible(false)
				self.idx = 1
			end,
			Def.Quad{
				InitCommand=function(self)
					self:zoomto(200, 40):diffuse(Color.White)
				end,
				HoverCommand=function(self)
					self:diffuse(active_index == self:GetParent().idx and Color.Yellow or Color.White)
				end,
				SelectedCommand=function(self)
					self:diffuse(active_index == self:GetParent().idx and Color.Green or Color.White)
				end
			},

			Def.Quad{
				InitCommand=function(self)
					self:zoomto(198, 38):diffuse(Color.Black)
				end
			},

			LoadFont("Common Bold")..{
				Name="OnlinePlayersButtonText",
					Text=online_lobby_text("OnlinePlayers", "Online players"),
				InitCommand=function(self)
					self:zoom(0.5)
				end,
				HoverCommand=function(self)
					self:diffuse(active_index == self:GetParent().idx and GetHexColor(SL.Global.ActiveColorIndex) or Color.White)
				end
			},
			Def.Quad{
				InitCommand=function(self)
					self:zoomto(200, 40):diffuse(color("#424242")):diffusealpha(0)
				end,
				SelectedCommand=function(self)
					if active_index ~= self:GetParent().idx then
						-- Gray out the button if it's not selected, since it won't do anything.
						self:diffusealpha(0.70)
					else
						self:diffusealpha(0)
					end
				end,
				LoseFocusCommand=function(self)
					self:diffusealpha(0)
				end
			},
		},

		Def.ActorFrame{
			InitCommand=function(self)
				local idx = 3
				self:y(browse_button_y(idx))
				self:x(lobby_layout.browseButtonX)
				self.idx = idx - 1
			end,

			Def.Quad{
				InitCommand=function(self)
					self:zoomto(lobby_layout.browseButtonWidth, lobby_layout.browseButtonHeight):diffuse(Color.White)
				end,
				HoverCommand=function(self)
					self:diffuse(active_index == self:GetParent().idx and Color.Yellow or Color.White)
				end,
				SelectedCommand=function(self)
					self:diffuse(active_index == self:GetParent().idx and Color.Green or Color.White)
				end
			},

			Def.Quad{
				InitCommand=function(self)
					self:zoomto(lobby_layout.browseButtonWidth-2, lobby_layout.browseButtonHeight-2):diffuse(Color.Black)
				end
			},

			LoadFont("Common Bold")..{
					Text=online_lobby_text("Refresh", "Refresh"),
				InitCommand=function(self)
					self:zoom(0.42)
				end,
				HoverCommand=function(self)
					self:diffuse(active_index == self:GetParent().idx and GetHexColor(SL.Global.ActiveColorIndex) or Color.White)
				end
			},
			Def.Quad{
				InitCommand=function(self)
					self:zoomto(lobby_layout.browseButtonWidth, lobby_layout.browseButtonHeight):diffuse(color("#424242")):diffusealpha(0)
				end,
				SelectedCommand=function(self)
					if active_index ~= self:GetParent().idx then
						-- Gray out the button if it's not selected, since it won't do anything.
						self:diffusealpha(0.70)
					else
						self:diffusealpha(0)
					end
				end,
				LoseFocusCommand=function(self)
					self:diffusealpha(0)
				end
			},
		},

		Def.ActorFrame{
			InitCommand=function(self)
				local idx = 4
				self:y(browse_button_y(idx))
				self:x(lobby_layout.browseButtonX)
				self.idx = idx - 1
			end,

			Def.Quad{
				InitCommand=function(self)
					self:zoomto(lobby_layout.browseButtonWidth, lobby_layout.browseButtonHeight):diffuse(Color.White)
				end,
				HoverCommand=function(self)
					self:diffuse(active_index == self:GetParent().idx and Color.Yellow or Color.White)
				end,
				SelectedCommand=function(self)
					self:diffuse(active_index == self:GetParent().idx and Color.Green or Color.White)
				end
			},

			Def.Quad{
				InitCommand=function(self)
					self:zoomto(lobby_layout.browseButtonWidth-2, lobby_layout.browseButtonHeight-2):diffuse(Color.Black)
				end
			},

			LoadFont("Common Bold")..{
					Text=online_lobby_text("CreateLobby", "Create lobby"),
				InitCommand=function(self)
					self:zoom(0.38)
				end,
				HoverCommand=function(self)
					self:diffuse(active_index == self:GetParent().idx and GetHexColor(SL.Global.ActiveColorIndex) or Color.White)
				end
			},
			Def.Quad{
				InitCommand=function(self)
					self:zoomto(lobby_layout.browseButtonWidth, lobby_layout.browseButtonHeight):diffuse(color("#424242")):diffusealpha(0)
				end,
				SelectedCommand=function(self)
					if active_index ~= self:GetParent().idx then
						-- Gray out the button if it's not selected, since it won't do anything.
						self:diffusealpha(0.70)
					else
						self:diffusealpha(0)
					end
				end,
				LoseFocusCommand=function(self)
					self:diffusealpha(0)
				end
			},
		},

		Def.ActorFrame{
			InitCommand=function(self)
				local idx = 5
				self:y(browse_button_y(idx))
				self:x(lobby_layout.browseButtonX)
				self.idx = idx - 1
			end,

			Def.Quad{
				InitCommand=function(self)
					self:zoomto(lobby_layout.browseButtonWidth, lobby_layout.browseButtonHeight):diffuse(Color.White)
				end,
				HoverCommand=function(self)
					self:diffuse(active_index == self:GetParent().idx and Color.Yellow or Color.White)
				end,
				SelectedCommand=function(self)
					self:diffuse(active_index == self:GetParent().idx and Color.Green or Color.White)
				end
			},

			Def.Quad{
				InitCommand=function(self)
					self:zoomto(lobby_layout.browseButtonWidth-2, lobby_layout.browseButtonHeight-2):diffuse(Color.Black)
				end
			},

			LoadFont("Common Bold")..{
					Text=online_lobby_text("Back", "Back"),
				InitCommand=function(self)
					self:zoom(0.42)
				end,
				HoverCommand=function(self)
					self:diffuse(active_index == self:GetParent().idx and GetHexColor(SL.Global.ActiveColorIndex) or Color.White)
				end
			},
			Def.Quad{
				InitCommand=function(self)
					self:zoomto(lobby_layout.browseButtonWidth, lobby_layout.browseButtonHeight):diffuse(color("#424242")):diffusealpha(0)
				end,
				SelectedCommand=function(self)
					if active_index ~= self:GetParent().idx then
						self:diffusealpha(0.70)
					else
						self:diffusealpha(0)
					end
				end,
				LoseFocusCommand=function(self)
					self:diffusealpha(0)
				end
			},
		},
	},

	Def.ActorFrame{
		Name="OnlinePlayersContent",
		InitCommand=function(self)
			self:visible(false)
		end,
		HoverCommand=function(self) end,

			Def.Quad{
				Name="OnlinePlayersBorder",
			InitCommand=function(self)
				self:zoomto(lobby_layout.browsePanelWidth,lobby_layout.browsePanelHeight):x(lobby_layout.browsePlayersX):y(lobby_layout.browsePanelY):diffuse(Color.White)
			end,
			HoverCommand=function(self)
				if list_selected and lobby_view == "players" then
					self:diffuse(Color.Green)
				elseif active_index == 1 then
					self:diffuse(Color.Yellow)
				else
					self:diffuse(Color.White)
				end
			end,
			SelectedCommand=function(self)
				self:diffuse(list_selected and lobby_view == "players" and Color.Green or Color.White)
			end,
			GainFocusCommand=function(self)
				self:diffuse(Color.Green)
			end,
			LoseFocusCommand=function(self)
				self:diffuse(Color.White)
			end
		},
		Def.Quad{
			InitCommand=function(self)
				self:zoomto(lobby_layout.browsePanelWidth-2,lobby_layout.browsePanelHeight-2):x(lobby_layout.browsePlayersX):y(lobby_layout.browsePanelY):diffuse(Color.Black)
			end
		},
		Def.Quad{
			InitCommand=function(self)
				self:zoomto(lobby_layout.browsePanelWidth-10, 1):x(lobby_layout.browsePlayersX):y(-150):diffuse(Color.White)
			end
		},
		LoadFont("Common Bold")..{
				Text=online_lobby_text("OnlinePlayers", "Online players"),
			InitCommand=function(self)
				self:horizalign(left):x(lobby_layout.browsePlayersX-(lobby_layout.browsePanelWidth/2)+8):y(-170):zoom(0.42)
			end
		},
		LoadFont("Common Normal")..{
			Name="OnlinePlayersCount",
			Text="0",
			InitCommand=function(self)
				self:horizalign(right):x(lobby_layout.browsePlayersX+(lobby_layout.browsePanelWidth/2)-8):y(-170):zoom(0.58)
			end
		},
		LoadFont("Common Normal")..{
			Name="OnlinePlayersList",
				Text=online_lobby_text("NoOnlinePlayers", "No online players found."),
			InitCommand=function(self)
				self:horizalign(left):vertalign(top):xy(lobby_layout.browsePlayersX-(lobby_layout.browsePanelWidth/2)+10, -132):zoom(0.48):maxwidth(420)
			end
		},
		Def.ActorFrame{
			Name="AvailableLobbiesButton",
			InitCommand=function(self)
				self:visible(false)
				local idx = 2
				self.idx = idx - 1
			end,
			Def.Quad{
				InitCommand=function(self)
					self:zoomto(200, 40):diffuse(Color.White)
				end,
				HoverCommand=function(self)
					self:diffuse(active_index == self:GetParent().idx and Color.Yellow or Color.White)
				end,
				SelectedCommand=function(self)
					self:diffuse(active_index == self:GetParent().idx and Color.Green or Color.White)
				end
			},
			Def.Quad{
				InitCommand=function(self)
					self:zoomto(198, 38):diffuse(Color.Black)
				end
			},
			LoadFont("Common Bold")..{
					Text=online_lobby_text("AvailableLobbies", "Available lobbies"),
				InitCommand=function(self)
					self:zoom(0.5)
				end,
				HoverCommand=function(self)
					self:diffuse(active_index == self:GetParent().idx and GetHexColor(SL.Global.ActiveColorIndex) or Color.White)
				end
			},
			Def.Quad{
				InitCommand=function(self)
					self:zoomto(200, 40):diffuse(color("#424242")):diffusealpha(0)
				end,
				SelectedCommand=function(self)
					if active_index ~= self:GetParent().idx then
						self:diffusealpha(0.70)
					else
						self:diffusealpha(0)
					end
				end,
				LoseFocusCommand=function(self)
					self:diffusealpha(0)
				end
			},
		},
		Def.ActorFrame{
			Name="OnlinePlayersRefreshButton",
			InitCommand=function(self)
				self:visible(false)
				self.idx = 2
			end,
			Def.Quad{
				InitCommand=function(self)
					self:zoomto(200, 40):diffuse(Color.White)
				end,
				HoverCommand=function(self)
					self:diffuse(active_index == self:GetParent().idx and Color.Yellow or Color.White)
				end,
				SelectedCommand=function(self)
					self:diffuse(active_index == self:GetParent().idx and Color.Green or Color.White)
				end
			},
			Def.Quad{
				InitCommand=function(self)
					self:zoomto(198, 38):diffuse(Color.Black)
				end
			},
			LoadFont("Common Bold")..{
					Text=online_lobby_text("Refresh", "Refresh"),
				InitCommand=function(self)
					self:zoom(0.5)
				end,
				HoverCommand=function(self)
					self:diffuse(active_index == self:GetParent().idx and GetHexColor(SL.Global.ActiveColorIndex) or Color.White)
				end
			},
			Def.Quad{
				InitCommand=function(self)
					self:zoomto(200, 40):diffuse(color("#424242")):diffusealpha(0)
				end,
				SelectedCommand=function(self)
					self:diffusealpha(active_index ~= self:GetParent().idx and 0.70 or 0)
				end,
				LoseFocusCommand=function(self)
					self:diffusealpha(0)
				end
			},
		},
		Def.ActorFrame{
			Name="OnlinePlayersCreateButton",
			InitCommand=function(self)
				self:visible(false)
				self.idx = 3
			end,
			Def.Quad{
				InitCommand=function(self)
					self:zoomto(200, 40):diffuse(Color.White)
				end,
				HoverCommand=function(self)
					self:diffuse(active_index == self:GetParent().idx and Color.Yellow or Color.White)
				end,
				SelectedCommand=function(self)
					self:diffuse(active_index == self:GetParent().idx and Color.Green or Color.White)
				end
			},
			Def.Quad{
				InitCommand=function(self)
					self:zoomto(198, 38):diffuse(Color.Black)
				end
			},
			LoadFont("Common Bold")..{
					Text=online_lobby_text("CreateLobby", "Create lobby"),
				InitCommand=function(self)
					self:zoom(0.5)
				end,
				HoverCommand=function(self)
					self:diffuse(active_index == self:GetParent().idx and GetHexColor(SL.Global.ActiveColorIndex) or Color.White)
				end
			},
			Def.Quad{
				InitCommand=function(self)
					self:zoomto(200, 40):diffuse(color("#424242")):diffusealpha(0)
				end,
				SelectedCommand=function(self)
					self:diffusealpha(active_index ~= self:GetParent().idx and 0.70 or 0)
				end,
				LoseFocusCommand=function(self)
					self:diffusealpha(0)
				end
			},
		},
		Def.ActorFrame{
			Name="OnlinePlayersBackButton",
			InitCommand=function(self)
				self:visible(false)
				self.idx = 4
			end,
			Def.Quad{
				InitCommand=function(self)
					self:zoomto(200, 40):diffuse(Color.White)
				end,
				HoverCommand=function(self)
					self:diffuse(active_index == self:GetParent().idx and Color.Yellow or Color.White)
				end,
				SelectedCommand=function(self)
					self:diffuse(active_index == self:GetParent().idx and Color.Green or Color.White)
				end
			},
			Def.Quad{
				InitCommand=function(self)
					self:zoomto(198, 38):diffuse(Color.Black)
				end
			},
			LoadFont("Common Bold")..{
					Text=online_lobby_text("Back", "Back"),
				InitCommand=function(self)
					self:zoom(0.5)
				end,
				HoverCommand=function(self)
					self:diffuse(active_index == self:GetParent().idx and GetHexColor(SL.Global.ActiveColorIndex) or Color.White)
				end
			},
			Def.Quad{
				InitCommand=function(self)
					self:zoomto(200, 40):diffuse(color("#424242")):diffusealpha(0)
				end,
				SelectedCommand=function(self)
					self:diffusealpha(active_index ~= self:GetParent().idx and 0.70 or 0)
				end,
				LoseFocusCommand=function(self)
					self:diffusealpha(0)
				end
			},
		},
	},

	Def.ActorFrame{
		Name="JoinedLobbyContent",
		InitCommand=function(self)
			self:visible(false)
		end,
		HoverCommand=function(self)
			local playersFrame = self:GetChild("JoinedLobbyPlayersFrame")
			if playersFrame then playersFrame:playcommand("Hover") end
			for _, name in ipairs({
				"SelectSongButton",
				"ReloadSongsButton",
				"GlobalOptionsButton",
				"CancelChoiceButton",
				"StartRoomButton",
			}) do
				local child = self:GetChild(name)
				if child then child:playcommand("Hover") end
			end
		end,

		Def.Quad{
			InitCommand=function(self)
				self:zoomto(360,340):x(-120):y(-20):diffuse(Color.White)
			end
		},
		Def.Quad{
			InitCommand=function(self)
				self:zoomto(358,338):x(-120):y(-20):diffuse(Color.Black)
			end
		},
		Def.Quad{
			InitCommand=function(self)
				self:zoomto(350, 1):x(-120):y(-150):diffuse(Color.White)
			end
		},
		LoadFont("Common Bold")..{
				Text=online_lobby_text("JoinedLobby", "Joined lobby"),
			InitCommand=function(self)
				self:horizalign(left):x(-290):y(-170):zoom(0.40)
			end
		},
		LoadFont("Common Normal")..{
			Name="JoinedLobbyCodeLabel",
				Text=online_lobby_text("LobbyCode", "Lobby code:"),
			InitCommand=function(self)
				self:horizalign(right):x(-10):y(-170):zoom(0.72)
			end
		},
		LoadFont("Common Bold")..{
			Name="JoinedLobbyCodeValue",
				Text=online_lobby_text("Pending", "(pending)"),
			InitCommand=function(self)
				self:horizalign(right):x(50):y(-170):zoom(0.42)
			end
		},
		LoadFont("Common Bold")..{
			Name="PackSyncKickWarning",
			Text="",
			InitCommand=function(self)
				-- Keep timeout warnings below the player table and above the
				-- controls drawn later in this ActorFrame.
				self:horizalign(center):xy(-120, 188):zoom(0.55):maxwidth(620):draworder(100)
					:diffuse(color("#FFDD55")):strokecolor(Color.Black):visible(false)
			end
		},
		Def.ActorFrame{
			Name="JoinedLobbyPlayersFrame",
			InitCommand=function(self)
				self:xy(-120, -20):visible(false)
			end,
			HoverCommand=function(self)
				local focusable = joined_is_manager and #joined_lobby_players > 1
				local focused = joined_active_index == 8 or joined_players_selected
				lobby_flow_trace("players_frame_focus_state focusable=" .. tostring(focusable == true)
					.. " focused=" .. tostring(focused == true)
					.. " activeIndex=" .. tostring(joined_active_index)
					.. " playersSelected=" .. tostring(joined_players_selected == true)
					.. " playerIndex=" .. tostring(joined_player_index)
					.. " players=" .. tostring(#joined_lobby_players)
					.. " manager=" .. tostring(joined_is_manager == true))
				self:visible(focusable)
				self:playcommand(focused and "GainFocus" or "LoseFocus")
			end,
			GainFocusCommand=function(self)
				self:stoptweening():diffuse(Color.Yellow):diffusealpha(0.74)
			end,
			LoseFocusCommand=function(self)
				self:stoptweening():diffuse(0.72,0.72,0.72,1):diffusealpha(0.34)
			end,
			Def.Quad{
				InitCommand=function(self)
					self:xy(0, -170):zoomto(360, 2)
				end
			},
			Def.Quad{
				InitCommand=function(self)
					self:xy(0, 170):zoomto(360, 2)
				end
			},
			Def.Quad{
				InitCommand=function(self)
					self:xy(-180, 0):zoomto(2, 340)
				end
			},
			Def.Quad{
				InitCommand=function(self)
					self:xy(180, 0):zoomto(2, 340)
				end
			},
		},
		LoadFont("Common Normal")..{
			Name="JoinedLobbyPlayers",
				Text=online_lobby_text("WaitingForPlayers", "Waiting for players..."),
			InitCommand=function(self)
				self:horizalign(left):x(-290):y(-112):zoom(0.84):maxwidth(405)
			end
		},
		Def.Quad{
			Name="JoinedSongCard",
			InitCommand=function(self)
				self:xy(230, -116):zoomto(330, 92):diffuse(0,0,0,0.82):visible(false)
			end
		},
		Def.Quad{
			Name="JoinedSongBannerFallback",
			InitCommand=function(self)
				self:xy(116, -110):zoomto(72, 40):diffuse(0.08,0.08,0.08,1):visible(false)
			end
		},
		LoadFont("Common Bold")..{
			Name="JoinedSongBannerLabel",
			Text=online_lobby_text("Banner", "BANNER"),
			InitCommand=function(self)
				self:xy(116, -105):zoom(0.18):diffuse(Color.White):visible(false)
			end
		},
		Def.Banner{
			Name="JoinedSongBanner",
			InitCommand=function(self)
				self:xy(116, -105):scaletoclipped(72, 40):visible(false)
			end
		},
		LoadFont("Common Bold")..{
			Name="JoinedSongConfirmedCheck",
			Text="✔",
			InitCommand=function(self)
				self:xy(72, -105):zoom(1.15):diffuse(Color.Green):strokecolor(color("#001900")):shadowlength(1):visible(false)
			end
		},
		LoadFont("Common Normal")..{
			Name="JoinedSongPack",
			Text="",
			InitCommand=function(self)
				self:horizalign(left):xy(96, -148):zoom(0.46):maxwidth(560):diffuse(0.85,0.85,0.85,1)
			end
		},
		LoadFont("Common Bold")..{
			Name="JoinedSongTitle",
			Text="",
			InitCommand=function(self)
				self:horizalign(left):xy(160, -119):zoom(WideScale(0.30, 0.32)):maxwidth(600)
			end
		},
		LoadFont("Common Normal")..{
			Name="JoinedSongArtist",
			Text="",
			InitCommand=function(self)
				self:horizalign(left):xy(160, -94):zoom(WideScale(0.46, 0.48)):maxwidth(420)
			end
		},
		Def.ActorFrame{
			InitCommand=function(self)
				self:xy(180, -18)
				self.idx = 1
			end,
			Def.Quad{
				InitCommand=function(self)
					self:zoomto(180, 36):diffuse(Color.White)
				end,
				HoverCommand=function(self)
					self:diffuse(joined_active_index == self:GetParent().idx and Color.Yellow or Color.White)
				end
			},
			Def.Quad{
				InitCommand=function(self)
					self:zoomto(178, 34):diffuse(Color.Black)
				end
			},
			LoadFont("Common Bold")..{
					Text=online_lobby_text("LeaveLobby", "Leave lobby"),
				InitCommand=function(self)
					self:zoom(0.38)
				end,
				HoverCommand=function(self)
					self:diffuse(joined_active_index == self:GetParent().idx and GetHexColor(SL.Global.ActiveColorIndex) or Color.White)
				end
			}
		},

			Def.ActorFrame{
				Name="SelectSongButton",
				InitCommand=function(self)
					self:xy(180, 34)
					self.idx = 2
			end,
				Def.Quad{
					InitCommand=function(self)
						self:zoomto(180, 36):diffuse(Color.White)
					end,
					HoverCommand=function(self)
						self:diffuse(joined_active_index == self:GetParent().idx and Color.Yellow or Color.White)
					end
				},
			Def.Quad{
				InitCommand=function(self)
					self:zoomto(178, 34):diffuse(Color.Black)
				end
			},
			LoadFont("Common Bold")..{
					Text=online_lobby_text("ChooseMusic", "Choose music"),
				InitCommand=function(self)
					self:zoom(0.38)
				end,
				HoverCommand=function(self)
					self:diffuse(joined_active_index == self:GetParent().idx and GetHexColor(SL.Global.ActiveColorIndex) or Color.White)
				end
				}
			},

			Def.ActorFrame{
				Name="ReloadSongsButton",
				InitCommand=function(self)
					self:xy(180, 138)
					self.idx = 3
					self:visible(false)
				end,
					Def.Quad{
						InitCommand=function(self)
							self:zoomto(180, 36):diffuse(Color.White)
						end,
						HoverCommand=function(self)
							if pack_sync_busy() then
								self:diffuse(color("#777777"))
							else
								self:diffuse(joined_active_index == self:GetParent().idx and Color.Yellow or Color.White)
							end
						end
					},
				Def.Quad{
					InitCommand=function(self)
						self:zoomto(178, 34):diffuse(Color.Black)
					end
				},
				LoadFont("Common Bold")..{
					Name="ReloadSongsLabel",
						Text=online_lobby_text("DownloadPack", "Download pack"),
						InitCommand=function(self)
							self:zoom(0.36)
						end,
						HoverCommand=function(self)
							if pack_sync_busy() then
								self:diffuse(color("#999999"))
							else
								self:diffuse(joined_active_index == self:GetParent().idx and GetHexColor(SL.Global.ActiveColorIndex) or Color.White)
							end
						end
					},
				},

				Def.ActorFrame{
					Name="GlobalOptionsButton",
					InitCommand=function(self)
						self:xy(180, 86)
					self.idx = 4
					self:visible(false)
				end,
				Def.Quad{
					InitCommand=function(self)
						self:zoomto(180, 38):diffuse(Color.White)
					end,
					HoverCommand=function(self)
						self:diffuse(joined_active_index == self:GetParent().idx and Color.Yellow or Color.White)
					end
				},
				Def.Quad{
					InitCommand=function(self)
						self:zoomto(178, 36):diffuse(Color.Black)
					end
				},
				LoadFont("Common Bold")..{
					Name="GlobalOptionsLabel",
					Text=online_lobby_text("GlobalOptions", "Global options"),
					InitCommand=function(self)
						self:y(-5):zoom(WideScale(0.25, 0.27)):vertspacing(-34):maxwidth(640)
					end,
					HoverCommand=function(self)
						self:diffuse(joined_active_index == self:GetParent().idx and GetHexColor(SL.Global.ActiveColorIndex) or Color.White)
					end
				},
				LoadFont("Common Bold")..{
					Name="GlobalOptionsModeLabel",
					Text="(ITG/1.00)",
					InitCommand=function(self)
						self:y(10):zoom(WideScale(0.22, 0.24)):diffuse(1,0.28,0.72,1)
					end,
					HoverCommand=function(self)
						self:diffuse(1,0.28,0.72,1)
					end
					}
				},

				Def.ActorFrame{
					Name="CancelChoiceButton",
					InitCommand=function(self)
						self:xy(180, 34)
						self.idx = 2
						self:visible(false)
					end,
					Def.Quad{
						InitCommand=function(self)
							self:zoomto(180, 36):diffuse(Color.White)
						end,
						HoverCommand=function(self)
							self:diffuse(joined_active_index == self:GetParent().idx and Color.Yellow or Color.White)
						end
					},
					Def.Quad{
						InitCommand=function(self)
							self:zoomto(178, 34):diffuse(Color.Black)
						end
					},
					LoadFont("Common Bold")..{
						Text=online_lobby_text("CancelSelection", "Cancel selection"),
						InitCommand=function(self)
							self:zoom(0.36)
						end,
						HoverCommand=function(self)
							self:diffuse(joined_active_index == self:GetParent().idx and GetHexColor(SL.Global.ActiveColorIndex) or Color.White)
						end
					}
				},

				Def.ActorFrame{
					Name="StartRoomButton",
				InitCommand=function(self)
					self:xy(180, 190)
					self.idx = 7
					self:visible(false)
				end,
				Def.Quad{
					InitCommand=function(self)
						self:zoomto(180, 36):diffuse(Color.White)
					end,
					HoverCommand=function(self)
						self:diffuse(joined_active_index == self:GetParent().idx and Color.Yellow or Color.White)
					end
				},
				Def.Quad{
					InitCommand=function(self)
						self:zoomto(178, 34):diffuse(Color.Black)
					end
				},
				LoadFont("Common Bold")..{
						Text=online_lobby_text("Start", "START"),
					InitCommand=function(self)
						self:zoom(0.40)
					end,
					HoverCommand=function(self)
						self:diffuse(joined_active_index == self:GetParent().idx and GetHexColor(SL.Global.ActiveColorIndex) or Color.White)
					end
				}
			},
		},

	Def.ActorFrame{
		Name="LeaveConfirmPrompt",
		InitCommand=function(self)
			self:visible(false)
		end,
		SyncModeCommand=function(self)
			local title = self:GetChild("PromptTitle")
			local cancelLabel = self:GetChild("CancelButton") and self:GetChild("CancelButton"):GetChild("CancelLabel")
			local confirmLabel = self:GetChild("ConfirmButton") and self:GetChild("ConfirmButton"):GetChild("ConfirmLabel")
			if title then
				if leave_confirm_mode == "exit_online" then
					title:settext(online_lobby_text("ExitOnlineConfirm", "Are you sure you want to leave online mode?"))
				else
					title:settext(online_lobby_text("DisconnectLobbyConfirm", "Leave the lobby?"))
				end
			end
			if cancelLabel then
				cancelLabel:settext(leave_confirm_mode == "exit_online"
					and online_lobby_text("No", "No") or online_lobby_text("Cancel", "Cancel"))
			end
			if confirmLabel then
				confirmLabel:settext(leave_confirm_mode == "exit_online"
					and online_lobby_text("Yes", "Yes") or online_lobby_text("LeaveLobby", "Leave lobby"))
			end
		end,
		HoverCommand=function(self)
			self:GetChild("CancelButton"):playcommand("Hover")
			self:GetChild("ConfirmButton"):playcommand("Hover")
		end,

		Def.Quad{
			InitCommand=function(self)
				self:zoomto(SCREEN_WIDTH, SCREEN_HEIGHT):diffuse(0,0,0,0.6)
			end
		},
		Def.Quad{
			InitCommand=function(self)
				self:zoomto(500, 180):diffuse(0,0,0,0.9)
			end
		},
		LoadFont("Common Normal")..{
			Name="PromptTitle",
				Text=online_lobby_text("DisconnectLobbyConfirm", "Leave the lobby?"),
			InitCommand=function(self)
				self:y(-42):zoom(1)
			end
		},

		Def.ActorFrame{
			Name="CancelButton",
			InitCommand=function(self)
				self:x(-90):y(30)
			end,
			Def.Quad{
				InitCommand=function(self)
					self:zoomto(150, 40):diffuse(Color.White)
				end,
				HoverCommand=function(self)
					self:diffuse(leave_confirm_index == 0 and Color.Yellow or Color.White)
				end
			},
			Def.Quad{
				InitCommand=function(self)
					self:zoomto(148, 38):diffuse(Color.Black)
				end
			},
			LoadFont("Common Bold")..{
				Name="CancelLabel",
					Text=online_lobby_text("Cancel", "Cancel"),
				InitCommand=function(self)
					self:zoom(0.5):maxwidth(280)
				end,
				HoverCommand=function(self)
					self:diffuse(leave_confirm_index == 0 and GetHexColor(SL.Global.ActiveColorIndex) or Color.White)
				end
			}
		},

		Def.ActorFrame{
			Name="ConfirmButton",
			InitCommand=function(self)
				self:x(90):y(30)
			end,
			Def.Quad{
				InitCommand=function(self)
					self:zoomto(150, 40):diffuse(Color.White)
				end,
				HoverCommand=function(self)
					self:diffuse(leave_confirm_index == 1 and Color.Yellow or Color.White)
				end
			},
			Def.Quad{
				InitCommand=function(self)
					self:zoomto(148, 38):diffuse(Color.Black)
				end
			},
			LoadFont("Common Bold")..{
				Name="ConfirmLabel",
					Text=online_lobby_text("LeaveLobby", "Leave lobby"),
				InitCommand=function(self)
					self:zoom(0.5):maxwidth(280)
				end,
				HoverCommand=function(self)
					self:diffuse(leave_confirm_index == 1 and GetHexColor(SL.Global.ActiveColorIndex) or Color.White)
				end
			}
		}
	},

	Def.ActorFrame{
		Name="BrowsePackDownloadConfirmPrompt",
		InitCommand=function(self)
			self:visible(false)
		end,
		HoverCommand=function(self)
			self:GetChild("CancelButton"):playcommand("Hover")
			self:GetChild("ConfirmButton"):playcommand("Hover")
		end,

		Def.Quad{
			InitCommand=function(self)
				self:zoomto(SCREEN_WIDTH, SCREEN_HEIGHT):diffuse(0,0,0,0.62)
			end
		},
		Def.Quad{
			InitCommand=function(self)
				self:zoomto(560, 230):diffuse(0,0,0,0.92)
			end
		},
		Def.Quad{
			InitCommand=function(self)
				self:zoomto(562, 232):diffuse(Color.White):diffusealpha(0.20)
			end
		},
		LoadFont("Common Bold")..{
			Text=online_lobby_text("DownloadThisPack", "Download this pack?"),
			InitCommand=function(self)
				self:y(-82):zoom(0.72):diffuse(Color.White)
			end
		},
		LoadFont("Common Normal")..{
			Text=online_lobby_text("BrowsePackDownloadWarning", "The manager is browsing this pack but has not selected a song yet.\nDownloading now may take time and disk space."),
			InitCommand=function(self)
				self:y(-28):zoom(0.48):maxwidth(980):diffuse(0.88,0.88,0.88,1)
			end
		},

		Def.ActorFrame{
			Name="CancelButton",
			InitCommand=function(self)
				self:x(-100):y(62)
			end,
			Def.Quad{
				InitCommand=function(self)
					self:zoomto(160, 42):diffuse(Color.White)
				end,
				HoverCommand=function(self)
					self:diffuse(browse_pack_download_confirm_index == 0 and Color.Yellow or Color.White)
				end
			},
			Def.Quad{
				InitCommand=function(self)
					self:zoomto(158, 40):diffuse(Color.Black)
				end
			},
			LoadFont("Common Bold")..{
				Text=online_lobby_text("Cancel", "Cancel"),
				InitCommand=function(self)
					self:zoom(0.5)
				end,
				HoverCommand=function(self)
					self:diffuse(browse_pack_download_confirm_index == 0 and GetHexColor(SL.Global.ActiveColorIndex) or Color.White)
				end
			}
		},

		Def.ActorFrame{
			Name="ConfirmButton",
			InitCommand=function(self)
				self:x(100):y(62)
			end,
			Def.Quad{
				InitCommand=function(self)
					self:zoomto(160, 42):diffuse(Color.White)
				end,
				HoverCommand=function(self)
					self:diffuse(browse_pack_download_confirm_index == 1 and Color.Yellow or Color.White)
				end
			},
			Def.Quad{
				InitCommand=function(self)
					self:zoomto(158, 40):diffuse(Color.Black)
				end
			},
			LoadFont("Common Bold")..{
				Text=online_lobby_text("Download", "Download"),
				InitCommand=function(self)
					self:zoom(0.5)
				end,
				HoverCommand=function(self)
					self:diffuse(browse_pack_download_confirm_index == 1 and GetHexColor(SL.Global.ActiveColorIndex) or Color.White)
				end
			}
		}
	},

	Def.ActorFrame{
		Name="TransferManagerConfirmPrompt",
		InitCommand=function(self)
			self:visible(false)
		end,
		HoverCommand=function(self)
			self:GetChild("CancelButton"):playcommand("Hover")
			self:GetChild("ConfirmButton"):playcommand("Hover")
		end,

		Def.Quad{
			InitCommand=function(self)
				self:zoomto(SCREEN_WIDTH, SCREEN_HEIGHT):diffuse(0,0,0,0.62)
			end
		},
		Def.Quad{
			InitCommand=function(self)
				self:zoomto(560, 210):diffuse(0,0,0,0.92)
			end
		},
		Def.Quad{
			InitCommand=function(self)
				self:zoomto(562, 212):diffuse(Color.White):diffusealpha(0.20)
			end
		},
		LoadFont("Common Bold")..{
			Name="PromptTitle",
			Text=online_lobby_text("TransferManagerConfirmTitle", "Transfer manager role?"),
			InitCommand=function(self)
				self:y(-72):zoom(0.70):diffuse(Color.White)
			end
		},
		LoadFont("Common Normal")..{
			Name="PromptDetail",
			Text="",
			InitCommand=function(self)
				self:y(-24):zoom(0.50):maxwidth(980):diffuse(0.88,0.88,0.88,1)
			end
		},

		Def.ActorFrame{
			Name="CancelButton",
			InitCommand=function(self)
				self:x(-100):y(58)
			end,
			Def.Quad{
				InitCommand=function(self)
					self:zoomto(160, 42):diffuse(Color.White)
				end,
				HoverCommand=function(self)
					self:diffuse(transfer_manager_confirm_index == 0 and Color.Yellow or Color.White)
				end
			},
			Def.Quad{
				InitCommand=function(self)
					self:zoomto(158, 40):diffuse(Color.Black)
				end
			},
			LoadFont("Common Bold")..{
				Text=online_lobby_text("No", "No"),
				InitCommand=function(self)
					self:zoom(0.5)
				end,
				HoverCommand=function(self)
					self:diffuse(transfer_manager_confirm_index == 0 and GetHexColor(SL.Global.ActiveColorIndex) or Color.White)
				end
			}
		},

		Def.ActorFrame{
			Name="ConfirmButton",
			InitCommand=function(self)
				self:x(100):y(58)
			end,
			Def.Quad{
				InitCommand=function(self)
					self:zoomto(160, 42):diffuse(Color.White)
				end,
				HoverCommand=function(self)
					self:diffuse(transfer_manager_confirm_index == 1 and Color.Yellow or Color.White)
				end
			},
			Def.Quad{
				InitCommand=function(self)
					self:zoomto(158, 40):diffuse(Color.Black)
				end
			},
			LoadFont("Common Bold")..{
				Text=online_lobby_text("Yes", "Yes"),
				InitCommand=function(self)
					self:zoom(0.5)
				end,
				HoverCommand=function(self)
					self:diffuse(transfer_manager_confirm_index == 1 and GetHexColor(SL.Global.ActiveColorIndex) or Color.White)
				end
			}
		}
	},

	-- Rendered late on purpose so this modal always sits above lobby panes/buttons.
	LoadActor("PlayerActionMenu.lua"),
	LoadActor("PackChoiceMenu.lua"),

	Def.ActorFrame{
		Name="GlobalOptionsMenu",
		InitCommand=function(self)
			self:visible(false)
		end,
		Def.Quad{
			InitCommand=function(self)
				self:zoomto(SCREEN_WIDTH, SCREEN_HEIGHT):diffuse(0,0,0,0.62)
			end
		},
		Def.Quad{
			InitCommand=function(self)
				self:zoomto(520, 330):diffuse(0,0,0,0.88)
			end
		},
		Def.Quad{
			InitCommand=function(self)
				self:zoomto(522, 332):diffuse(Color.White):diffusealpha(0.22)
			end
		},
		LoadFont("Common Bold")..{
			Name="GlobalOptionsTitle",
			Text=online_lobby_text("GlobalOptions", "Global options"),
			InitCommand=function(self)
				self:xy(0, -130):zoom(0.7):diffuse(Color.White)
			end
		},
		LoadFont("Common Normal")..{
			Name="GlobalOptionsDetail",
			Text="",
			InitCommand=function(self)
				self:xy(0, -96):zoom(0.45):maxwidth(940):diffuse(0.85,0.85,0.85,1)
			end
		},
		LoadFont("Common Normal")..{
			Name="GlobalOptionsChoices",
			Text="",
			InitCommand=function(self)
				self:xy(-180, -48):horizalign(left):vertalign(top):zoom(0.55):maxwidth(680):diffuse(Color.White)
			end
		},
		LoadFont("Common Normal")..{
			Text=online_lobby_text("GlobalOptionsHelp", "Left/Right: choose   Start: apply   Back: close"),
			InitCommand=function(self)
				self:xy(0, 135):zoom(0.38):maxwidth(1180):diffuse(0.7,0.7,0.7,1)
			end
		}
	},



		LoadFont("Common Normal")..{
			Name="ITGOnlineBuildMarker",
			Text=online_lobby_text("ClientTitle", "ITG Online client"),
			InitCommand=function(self)
				self:xy(_screen.w - 12, _screen.h - 18):horizalign(right):zoom(0.32):diffuse(0.75,0.75,0.75,0.85)
			end
		},

		Def.ActorFrame{
			Name="RealtimeIndicator",
			InitCommand=function(self)
				self:xy(_screen.w - 18, 22):visible(false)
			end,
			SetCommand=function(self, params)
				params = params or realtime_health_snapshot()
				local label = tostring(params.label or "HTTP ONLY")
				local age = tonumber(params.age) or 999
				local color = params.color or {0.55, 0.55, 0.55, 0.90}
				local text = label
				if age < 900 then
					text = text .. " " .. tostring(math.floor(age)) .. "s"
				end
				self:visible(true)
				self:GetChild("Dot"):diffuse(color[1] or 1, color[2] or 1, color[3] or 1, color[4] or 1)
				self:GetChild("Label"):settext(text):diffuse(color[1] or 1, color[2] or 1, color[3] or 1, color[4] or 1)
				local width = math.min(math.max(self:GetChild("Label"):GetWidth() + 44, 150), 260)
				self:GetChild("Background"):zoomto(width, 26)
				self:GetChild("Dot"):x(-width + 24)
				self:GetChild("Label"):x(-12)
			end,
			Def.Quad{
				Name="Background",
				InitCommand=function(self)
					self:horizalign(right):zoomto(150, 26):diffuse(0,0,0,0.72)
				end
			},
			Def.Quad{
				Name="Dot",
				InitCommand=function(self)
					self:zoomto(10, 10):diffuse(0.55,0.55,0.55,0.90)
				end
			},
			LoadFont("Common Normal")..{
				Name="Label",
				Text=online_lobby_text("HttpOnly", "HTTP ONLY"),
				InitCommand=function(self)
					self:horizalign(right):zoom(0.36):maxwidth(240):diffuse(0.55,0.55,0.55,0.90)
				end
			}
		},

		-- Keep this on top of everything else so that it doesn't get covered up by any other elements.
		Def.ActorFrame{
			Name="NetworkStatus",
		InitCommand=function(self)
			self:y(-130)
		end,
		SetCommand=function(self, params)
			if not params then return end
			local showPrompt = params.showPrompt == true
			self:GetChild("Spinner"):visible(params.showSpinner == true)
			self:GetChild("StatusText"):settext(params.text or "")
			self:GetChild("PromptText"):visible(showPrompt)
			self:GetChild("PromptText"):settext(showPrompt and (params.promptText or "") or "")

			local statusWidth = self:GetChild("StatusText"):GetWidth()
			local promptWidth = showPrompt and self:GetChild("PromptText"):GetWidth() or 0
			local width = math.min(math.max(math.max(statusWidth, promptWidth) + 50, 360), 620)
			local height = showPrompt and 78 or 52
			self:GetChild("Background"):zoomto(width, height)
			self:GetChild("Spinner"):x(-width/2 + 22)
		end,

		Def.Quad{
			Name="Background",
			InitCommand=function(self)
				self:zoomto(280, 44):diffuse(0,0,0,0.75)
			end
		},
		Def.Sprite{
			Name="Spinner",
			Texture=THEME:GetPathG("", "LoadingSpinner 10x3.png"),
			Frames=Sprite.LinearFrames(30,1),
			InitCommand=function(self)
				self:x(-118):zoom(0.14):diffuse(GetHexColor(SL.Global.ActiveColorIndex, true)):visible(false)
			end,
			VisualStyleSelectedMessageCommand=function(self)
				self:diffuse(GetHexColor(SL.Global.ActiveColorIndex, true))
			end
		},
		LoadFont("Common Normal")..{
			Name="StatusText",
			Text="",
			InitCommand=function(self)
				self:maxwidth(560):zoom(0.82):diffuse(Color.White):y(-10)
			end
		},
		LoadFont("Common Normal")..{
			Name="PromptText",
			Text="",
			InitCommand=function(self)
				self:maxwidth(560):zoom(0.95):diffuse(Color.White):y(18):visible(false)
			end
		}
	},

	LoadActor("PrivateJoinPrompt.lua"),
}

return af
