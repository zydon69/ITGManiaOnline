local active_index = 3
local list_selected = false
local options = { "Salons disponibles", "Joueurs en ligne", "Rafraichir", "Creer un salon", "Retour" }
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
local showing_private_join_prompt = false
local private_join_prompt_index = 1
local private_join_request = nil
local private_join_prompt_kind = "join_request"
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
	{label="Accepter", accept=true, reason=""},
	{label="Refuser", accept=false, reason=""},
	{label="Occupe", accept=false, reason="Occupe pour le moment."},
	{label="Plus tard", accept=false, reason="Plus tard."},
}
local room_invitation_options = {
	{label="Accepter l'invitation", accept=true},
	{label="Refuser l'invitation", accept=false},
	{label="Fermer", dismiss=true},
}
local pending_join_action_id = 0
local pending_join_deadline = 0
local pending_create_action_id = 0
local pending_create_deadline = 0
local lobby_search_ui_pending = false

local mode = "browse"
local joined_active_index = 1
local joined_is_manager = false
local joined_phase = nil
local joined_lobby_code = ""
local joined_lobby_players = {}
local joined_player_index = 1
local joined_players_selected = false
local joined_manager_user_id = nil
local joined_song_preview = nil
local joined_song_confirmed = false
local joined_song_selected_key = ""
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
local last_start_visibility_debug_key = ""
local last_select_song_visibility_debug_key = ""
local last_auto_start_focus_key = ""
local last_auto_start_request_key = ""
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

local browse_lobby_x = -205
local browse_players_x = 35
local browse_button_x = 245
local browse_panel_y = -20
local browse_panel_width = 230
local browse_panel_height = 340
local browse_button_width = 145
local browse_button_height = 34
local browse_button_spacing = 12

local function browse_button_y(idx)
	local first = 3
	local offset = idx - first
	return -62 + offset * (browse_button_height + browse_button_spacing)
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

local function reset_joined_lobby_state()
	clear_pack_choice_recovery()
	joined_active_index = 1
	joined_is_manager = false
	joined_phase = nil
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

	local function begin_leave_lobby(root)
		if leaving_lobby then
			lobby_flow_trace("begin_leave_lobby_skipped reason=already_leaving joined_code=" .. tostring(joined_lobby_code))
			return
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
			root:queuecommand("UpdateLobbyView")
			root:sleep(4.0):queuecommand("LeaveLobbyWatchdog")
			root:playcommand("SetStatus", {
			text="Sortie du salon...",
			showSpinner=true,
				showPrompt=false
			})
		end
		lobby_flow_trace("begin_leave_lobby_end joined_code=" .. tostring(joined_lobby_code))
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
		input_quiet_until = now + 0.75
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
		if root then
			lobby_flow_trace("finish_leave_lobby_ui_update_begin")
			local joinedContent = root:GetChild("JoinedLobbyContent")
			if joinedContent then joinedContent:visible(false) end
			if ScreenOnlineLobbiesRemoveLobbyCandidateByCode(departed_lobby_code) then
				lobby_flow_trace("finish_leave_lobby_removed_stale_candidate code=" .. tostring(departed_lobby_code))
			end
			root:queuecommand("UpdateLobbyView")
		root:queuecommand("UpdateOnlinePlayers")
			root:sleep(0.8):queuecommand("RefreshLobbyAfterLeave")
		local status = root:GetChild("NetworkStatus")
		if status then status:visible(false) end
		root:playcommand("SetStatus", {
			text="Salon quitte.",
			showSpinner=false,
			showPrompt=false,
			duration=3
			})
			root:queuecommand("Hover")
			lobby_flow_trace("finish_leave_lobby_ui_update_end")
		end
		lobby_flow_trace("finish_leave_lobby_end")
	end

	local function leave_lobby_stabilization_remaining()
		SL.Global.Online = SL.Global.Online or {}
		local lastFinishedAt = tonumber(SL.Global.Online.ScreenOnlineLobbiesLeaveFinishedAt) or -999
		local elapsed = GetTimeSinceStart() - lastFinishedAt
		return math.max(0, 2.0 - elapsed)
	end

	local function recently_left_lobby(seconds)
		SL.Global.Online = SL.Global.Online or {}
		local lastFinishedAt = tonumber(SL.Global.Online.ScreenOnlineLobbiesLeaveFinishedAt) or -999
		return GetTimeSinceStart() - lastFinishedAt < (tonumber(seconds) or 4.0)
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
			end

			local lobbyCount = lobbyContent:GetChild("LobbyCount")
			if lobbyCount then
				local total = #candidates
				lobbyCount:settext(total > 0 and ("1/"..total) or "0/0")
			end

			local emptyText = lobbyContent:GetChild("EmptyStateText")
			if emptyText then
				emptyText:visible(#candidates == 0)
			end
		end

		if not pack_sync_busy() then
			hide_network_status_if_idle(root)
		end
		root:queuecommand("UpdateLobbyView")
		root:queuecommand("UpdateOnlinePlayers")
		local joinedContent = root:GetChild("JoinedLobbyContent")
		if joinedContent then joinedContent:visible(mode == "joined") end
		root:queuecommand("Hover")
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
	if ITGOnline and ITGOnline.debugReadyFlow ~= nil then
		return ITGOnline.debugReadyFlow == true
	end
	return false
end

function lobby_debug(message)
	if not lobby_debug_enabled() then return end
	local line = "ITG Online Lobby: " .. tostring(message or "")
	if Trace then Trace(line) elseif Warn then Warn(line) end
end

lobby_flow_trace = function(message)
		if not (ITGOnline and (ITGOnline.debugOnlineTrace == true or ITGOnline.debugReadyFlow == true)) then
			return
		end
		local line = "ITG Online: FLOW lobby_ui " .. tostring(message or "")
		if Trace then Trace(line) elseif Warn then Warn(line) end
		if Flush then Flush() end
end

function lobby_count(value)
	return type(value) == "table" and #value or 0
end

function lobby_room_summary(prefix, params)
	params = type(params) == "table" and params or {}
	local players = params.players or params.members or {}
	local readyStates = params.readyStates or params.ready_states or {}
	local song = params.song or params.selectedSong or params.selected_song or {}
	lobby_flow_trace(tostring(prefix or "room_state")
		.. " mode=" .. tostring(mode)
		.. " joined_code=" .. tostring(joined_lobby_code)
		.. " params_code=" .. tostring(params.code or params.roomCode or params.room_id or params.id or "")
		.. " currentRoomId=" .. tostring(ITGOnline and ITGOnline.currentRoomId or "nil")
		.. " phase=" .. tostring(params.phase or params.roomPhase or "")
		.. " players=" .. tostring(lobby_count(players))
		.. " readyStates=" .. tostring(lobby_count(readyStates))
		.. " song=" .. tostring(song.title or song.folder_name or song.song_hash or "none")
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

function global_options_summary()
	local options = normalize_global_options(joined_global_options)
	return global_score_label(options.scoreMode) .. " / " .. string.format("%.2fx", options.musicRate)
end

function global_options_mode_label()
	local options = normalize_global_options(joined_global_options)
	return "(" .. global_score_label(options.scoreMode) .. "/" .. string.format("%.2f", options.musicRate) .. ")"
end

function rebuild_global_options_choices()
	global_options_choices = {
		{ label="Score: ITG", scoreMode="itg" },
		{ label="Score: EX", scoreMode="ex" },
		{ label="Score: HardEX", scoreMode="hardex" },
		{ label="Rate: 0.75x", musicRate=0.75 },
		{ label="Rate: 1.00x", musicRate=1.0 },
		{ label="Rate: 1.10x", musicRate=1.1 },
		{ label="Rate: 1.20x", musicRate=1.2 },
		{ label="Rate: 1.50x", musicRate=1.5 },
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
	if not choice or not ITGOnline or not ITGOnline.UpdateGlobalOptions then return end
	local current = normalize_global_options(joined_global_options)
	local payload = {
		score_mode = choice.scoreMode or current.scoreMode,
		music_rate = choice.musicRate or current.musicRate,
	}
	ITGOnline:UpdateGlobalOptions(payload, function(ok)
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

function clamp_text(value, maxLen)
	value = text_or_empty(value)
	maxLen = math.max(1, tonumber(maxLen) or 1)
	if #value <= maxLen then return value end
	if maxLen <= 1 then return "…" end
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
		title:settext(hasSong and clamp_text(titleText ~= "" and titleText or "Chanson inconnue", 58) or "")
	end

	local artist = joinedContent:GetChild("JoinedSongArtist")
	if artist then
		local artistText = hasSong and song_info_artist(songInfo) or ""
		artist:visible(hasSong)
		artist:settext("Artiste : " .. (artistText ~= "" and clamp_text(artistText, 44) or "Artiste inconnu"))
	end

	local pack = joinedContent:GetChild("JoinedSongPack")
	if pack then
		local packText = hasSong and song_info_pack(songInfo) or ""
		pack:visible(hasSong and packText ~= "")
		pack:settext(packText ~= "" and ("Pack : " .. clamp_text(packText, 46)) or "")
	end

	local banner = joinedContent:GetChild("JoinedSongBanner")
	local bannerFallback = joinedContent:GetChild("JoinedSongBannerFallback")
	local bannerLabel = joinedContent:GetChild("JoinedSongBannerLabel")
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
	if status == "" or status == "unknown" then return "" end
	if ITGOnline and ITGOnline.PackSync and ITGOnline.PackSync.statusText then
		return ITGOnline.PackSync.statusText[status] or status
	end
	return status:gsub("_", " ")
end

pack_sync_busy = function()
	if not (ITGOnline and ITGOnline.PackSync) then return false end
	if trim_text(ITGOnline.PackSync.downloadInFlightKey) ~= "" then return true end
	local status = trim_text(ITGOnline.PackSync.currentStatus)
	return status == "download_requested" or status == "download_in_progress" or status == "reloading_songs"
end

function can_download_browsed_pack()
	return joined_preview_unknown_pack
		and not joined_song_confirmed
		and not joined_missing_song
		and joined_song_preview ~= nil
		and not pack_sync_busy()
end

function show_pack_download_button()
	return joined_missing_song or can_download_browsed_pack() or pack_sync_busy()
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
		or status == "downloaded_ok"
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
	local roomTimeMs = nil
	if ITGOnline.serverClockOffsetSeconds then
		roomTimeMs = math.floor((GetTimeSinceStart() + tonumber(ITGOnline.serverClockOffsetSeconds)) * 1000)
	else
		roomTimeMs = tonumber(ITGOnline.currentRoom.server_time_ms)
	end
	if not roomTimeMs then return nil end
	if joined_manager_user_id ~= nil and tostring(player and player.playerId or "") == tostring(joined_manager_user_id) then return nil end
	local deadlineMs = tonumber(player and player.packSyncDownloadDeadlineMs)
	if deadlineMs and deadlineMs > roomTimeMs then
		return math.max(1, math.ceil((deadlineMs - roomTimeMs) / 1000))
	end
	return nil
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

function joined_phase_allows_song_selection()
	local phase = normalized_online_phase(joined_phase)
	if phase == "" and ITGOnline and ITGOnline.currentRoom then
		phase = normalized_online_phase(ITGOnline.currentRoom.phase)
	end
	return phase == "lobby"
		or phase == "lobby_ready"
		or phase == "config"
		or phase == "results"
end

function joined_phase_allows_start()
	return joined_phase == "config" or joined_phase == "lobby_ready"
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
end

function joined_button_indices()
	local indices = {1}
	if joined_is_manager and joined_phase_allows_song_selection() then
		indices[#indices + 1] = 2
	end
	if joined_is_manager and joined_phase_allows_song_selection() then
		indices[#indices + 1] = 4
	end
	if not pack_sync_busy() and (joined_missing_song or can_download_browsed_pack()) then
		indices[#indices + 1] = 3
	end
	if joined_can_cancel_song_selection() then
		indices[#indices + 1] = 6
	end
	if joined_room_can_start() then
		indices[#indices + 1] = 5
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

local function joined_not_ready_player_names()
	local names = {}
	for _, player in ipairs(joined_lobby_players or {}) do
		local isManagerPlayer = joined_manager_user_id ~= nil and tostring(player.playerId or "") == tostring(joined_manager_user_id)
		local skipSoloManager = joined_is_manager and isManagerPlayer and #joined_lobby_players == 1
		if not player.ready and not skipSoloManager then
			names[#names + 1] = trim_text(player.profileName or player.name or player.playerId or "Unknown")
		end
	end
	return names
end

local function sync_local_missing_song_from_joined_players()
	if not joined_lobby_players or not ITGOnline or not ITGOnline.user then return end
	if joined_phase == "results" then
		joined_missing_song = false
		joined_missing_song_info = nil
		joined_can_download_pack = false
		joined_missing_song_reason = nil
		return
	end

	local selfId = tostring(ITGOnline.user.id or "")
	if selfId == "" then return end

	for _, player in ipairs(joined_lobby_players) do
		if tostring(player and player.playerId or "") == selfId then
			if joined_manager_user_id ~= nil and tostring(joined_manager_user_id) == selfId then
				joined_missing_song = false
				joined_missing_song_info = nil
				joined_can_download_pack = false
				joined_missing_song_reason = nil
				return
			end
			local selfMissing = player.missingSong == true
			if pack_sync_confirms_joined_song() then
				joined_missing_song = false
				joined_missing_song_info = nil
				joined_can_download_pack = false
				joined_missing_song_reason = nil
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
end

local function player_is_current_user(player)
	if not (ITGOnline and ITGOnline.user) then return false end
	return tostring(player and player.playerId or "") == tostring(ITGOnline.user.id or "")
end

local function apply_local_pack_sync_status_to_joined_player(params)
	if not (params and ITGOnline and ITGOnline.user) then return false end
	local currentUserId = tostring(ITGOnline.user.id or "")
	if currentUserId == "" then return false end
	for _, player in ipairs(joined_lobby_players or {}) do
		if tostring(player and player.playerId or "") == currentUserId then
			local status = trim_text(params.status)
			if status ~= "" then player.packSyncStatus = status end
			player.packSyncMessage = params.message
			if params.download_progress ~= nil then
				player.packSyncDownloadProgress = params.download_progress
			elseif status ~= "download_in_progress" and status ~= "download_requested" then
				player.packSyncDownloadProgress = nil
			end
			if status == "ready" or status == "local_chart_match_found" then
				player.missingSong = false
				player.songAvailable = joined_song_confirmed and true or player.songAvailable
			elseif status == "downloaded_ok" then
				player.missingSong = false
			elseif status == "manager_browsing_unknown_pack" then
				player.songAvailable = false
			end
			return true
		end
	end
	return false
end

local function player_missing_song_for_ui(player)
	if joined_phase == "results" then return false end
	if joined_manager_user_id ~= nil and tostring(player and player.playerId or "") == tostring(joined_manager_user_id) then return false end
	if player_is_current_user(player) and pack_sync_is_checking_joined_song() then
		return false
	end
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

local function pack_sync_line_for_player(player)
	if not player or player_is_manager(player) or joined_phase == "results" then return "" end
	if joined_song_preview == nil and not (ITGOnline and ITGOnline.currentRoom and ITGOnline.currentRoom.selected_song) then return "" end

	local status = trim_text(player.packSyncStatus)
	local message = trim_text(player.packSyncMessage)
	local reason = trim_text(player.missingSongReason)
	local songAvailable = player.songAvailable == true
	local previewOnly = joined_song_preview ~= nil and not joined_song_confirmed

	if status == "download_in_progress" then
		local progress = tonumber(player.packSyncDownloadProgress)
		local suffix = progress and (" " .. tostring(math.floor(progress)) .. "%") or ""
		return "Telechargement en cours" .. suffix
	end
	if status == "download_requested" or status == "reloading_songs" then
		return message ~= "" and message or pack_sync_display_text(status)
	end

	if previewOnly then
		if status == "manager_browsing_unknown_pack" then
			return "Pack inconnu"
		end
		if status == "download_failed"
			or status == "downloaded_ok" then
			return message ~= "" and message or pack_sync_display_text(status)
		end
		return ""
	end

	if player_missing_song_for_ui(player) then
		if status == "local_chart_match_found" or songAvailable then
			return "Pack KO / chart compatible trouvée"
		end
			if reason == "missing_local_song"
				or reason == "no_compatible_chart_found"
				or reason == "chart_hash_mismatch"
				or reason == "song_hash_mismatch"
				or reason == "hash_mismatch"
				or status == "no_compatible_chart_found"
				or status == "chart_mismatch" then
				local countdown = pack_sync_countdown_seconds_for_player(player)
				local suffix = countdown and (" - expulsion dans " .. tostring(countdown) .. "s") or ""
				return "Pack KO / aucune chart compatible trouvée" .. suffix
			end
		end

	if songAvailable or status == "ready" or status == "local_chart_match_found" then
		if message == "Pack KO / chart compatible trouvée" then return message end
		if message == "Pack+chart trouvées" then return message end
		return "Pack+chart trouvées"
	end

	if status ~= "" and status ~= "unknown" then
		return pack_sync_display_text(status)
	end

	return ""
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
	joined_active_index = indices[1] or 1
	joined_user_moved_focus = false
	last_auto_start_focus_key = ""
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
	joined_active_index = indices[nextIndex] or 1
	joined_user_moved_focus = true
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
	if joined_is_manager and joined_phase_allows_song_selection() then
		for _, index in ipairs(indices) do
			if index == 2 then
				joined_active_index = 2
				joined_user_moved_focus = false
				last_auto_start_focus_key = ""
				return
			end
		end
	end
	joined_active_index = indices[1] or 1
	joined_user_moved_focus = false
	last_auto_start_focus_key = ""
end

local function transition_to_online_song_reload()
	SL.Global.Online = SL.Global.Online or {}
	SL.Global.Online.ReturnToLobbyAfterSongReload = true

	local topScreen = SCREENMAN:GetTopScreen()
	if topScreen then
		topScreen:SetNextScreenName("ScreenReloadSongsOnline")
		topScreen:StartTransitioningScreen("SM_GoToNextScreen")
	end
end

local function room_visibility_label(room)
	if not room then return "" end
	if room.visibility == "private" then return "[PRV]" end
	if room.visibility == "public" then return "[PUB]" end
	return "[ROOM]"
end

local function room_accepts_new_members(room)
	if not room then return false end
	if room.acceptsNewMembers ~= nil then return room.acceptsNewMembers == true end
	if room.accepts_new_members ~= nil then return room.accepts_new_members == true end
	return normalized_online_phase(room.phase) == "lobby"
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
			return {{label="Transfert impossible", action="cancel"}, {label="Annuler", action="cancel"}}
		end
		return {
			{label="Transferer manager", action="transfer_manager"},
			{label="Annuler", action="cancel"},
		}
	end
	if user.isSelf then
		return {{label="C'est vous", action="cancel"}, {label="Annuler", action="cancel"}}
	end
	if user.room and user.room.visibility == "public" then
		if not room_accepts_new_members(user.room) then
			return {{label="Salon public non joignable", action="cancel"}, {label="Annuler", action="cancel"}}
		end
		if user.room.id then
			return {{label="Rejoindre le salon public", action="join_public_room", room_id=user.room.id}, {label="Annuler", action="cancel"}}
		end

		return {{label="Rejoindre le salon public", action="join_user_room"}, {label="Annuler", action="cancel"}}
	end
	if user.room and user.room.visibility == "private" then
		return {{label="Demander a rejoindre le salon prive", action="join_user_room"}, {label="Annuler", action="cancel"}}
	end
	return {
		{label="Inviter dans un salon prive", action="invite_private"},
		{label="Inviter dans un salon public", action="invite_public"},
		{label="Annuler", action="cancel"},
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
		t:queuecommand("UpdateLobbyView")
		t:playcommand("SetStatus", {
			text=message or "La creation du salon a expire. Verifiez la connexion puis reessayez.",
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
		t:queuecommand("UpdateLobbyView")
		t:playcommand("SetStatus", {
			text=message or "La tentative de rejoindre le salon a expire. Rafraichissement...",
			showSpinner=false,
			showPrompt=false
		})
		MESSAGEMAN:Broadcast("SearchLobby")
		t:queuecommand("Hover")
	end
end

local function execute_player_action(option, user)
	if not option or not user then return end
	if not t then return end
	showing_player_action_menu = false
	t:GetChild("PlayerActionMenu"):visible(false)

	if option.action == "transfer_manager" then
		local targetUserId = user.playerId or user.id
		if not joined_player_can_receive_manager(user) or not ITGOnline or not ITGOnline.TransferRoomManager then
			t:playcommand("SetStatus", {
				text="Impossible de transferer le role manager a ce joueur.",
				showSpinner=false,
				showPrompt=true
			})
			return
		end
		t:playcommand("SetStatus", {
			text="Transfert du role manager...",
			showSpinner=true,
			showPrompt=false
		})
		ITGOnline:TransferRoomManager(targetUserId, function(ok, decoded, response)
			if ok then
				joined_players_selected = false
				if t then
					t:playcommand("SetStatus", {
						text="Role manager transfere.",
						showSpinner=false,
						showPrompt=false
					})
					t:queuecommand("UpdateJoinedLobbyText")
					t:queuecommand("Hover")
				end
			elseif t then
				local message = "Impossible de transferer le role manager."
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
			t:playcommand("SetStatus", {text="Creation du salon prive et envoi de l'invitation...", showSpinner=true, showPrompt=false})
		MESSAGEMAN:Broadcast("InviteOnlinePlayer", {user_id=user.id, visibility="private"})
	elseif option.action == "invite_public" then
		t:GetChild("LobbyContent"):visible(false)
		t:GetChild("OnlinePlayersContent"):visible(false)
			t:playcommand("SetStatus", {text="Creation du salon public et envoi de l'invitation...", showSpinner=true, showPrompt=false})
		MESSAGEMAN:Broadcast("InviteOnlinePlayer", {user_id=user.id, visibility="public"})
	elseif option.action == "join_user_room" then
		t:GetChild("LobbyContent"):visible(false)
		t:GetChild("OnlinePlayersContent"):visible(false)
			t:playcommand("SetStatus", {text="Contact du salon du joueur...", showSpinner=true, showPrompt=false})
		begin_join_timeout(t)
		MESSAGEMAN:Broadcast("JoinOnlinePlayerRoom", {user_id=user.id})
	elseif option.action == "join_public_room" and option.room_id then
		t:GetChild("LobbyContent"):visible(false)
		t:GetChild("OnlinePlayersContent"):visible(false)
			t:playcommand("SetStatus", {text="Connexion au salon public...", showSpinner=true, showPrompt=false})
		begin_join_timeout(t)
		MESSAGEMAN:Broadcast("JoinLobby", {code=option.room_id})
	end
end

local function close_pack_choice_menu(cancelPackChoice)
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
end

local function update_pack_choice_menu()
	if not t then return end
	local menu = t:GetChild("PackChoiceMenu")
	if not menu then return end
	local title = menu:GetChild("PackChoiceTitle")
	local options = menu:GetChild("PackChoiceOptions")
		if title then title:settext("Choisir le pack a telecharger") end
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
					.. " (" .. tostring(songsCount) .. " chansons)"
		end
		lines[#lines + 1] = ""
			lines[#lines + 1] = "Gauche/Droite pour choisir, START pour telecharger, Select pour annuler."
		options:settext(table.concat(lines, "\n"))
	end
	menu:visible(true)
end

local function open_pack_choice_menu(songInfo, candidates, message, browseOnly)
	if type(candidates) ~= "table" or #candidates == 0 then return false end
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
	return true
end

local function close_browse_pack_download_confirm()
	showing_browse_pack_download_confirm = false
	browse_pack_download_confirm_index = 0
	browse_pack_download_song_info = nil
	if t then
		local prompt = t:GetChild("BrowsePackDownloadConfirmPrompt")
		if prompt then prompt:visible(false) end
	end
end

local function open_browse_pack_download_confirm(songInfo)
	if not songInfo or pack_sync_busy() then return false end
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
	if not songInfo then return end
	if not (ITGOnline and ITGOnline.PackSync and ITGOnline.PackSync.DownloadBrowsingPack) then
		if t then
			t:playcommand("SetStatus", {
				text="Le telechargement anticipe du pack n'est pas disponible.",
				showSpinner=false,
				showPrompt=true
			})
		end
		return
	end
	ITGOnline.PackSync:DownloadBrowsingPack(songInfo, function(ok, message)
		if not ok and type(message) == "table" and message.kind == "pack_candidates" then
			open_pack_choice_menu(
				songInfo,
				message.candidates,
				message.message or "Plusieurs packs correspondent. Choisissez-en un.",
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
				text=message or "Le téléchargement du pack a échoué.\nVeuillez réessayer ou installer le pack manuellement.",
				showSpinner=false,
				showPrompt=true
			})
		end
	end)
end

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
				begin_leave_lobby(t)
				MESSAGEMAN:Broadcast("LeaveLobby", {
					roomId=SL.Global.Online.ScreenOnlineLobbiesLeaveRequestCode,
					generation=SL.Global.Online.ScreenOnlineLobbiesLeaveRequestGeneration,
				})
			end
		else
			play_online_sound_once("Common", "Cancel")
			lobby_flow_trace("leave_confirm_cancelled_by_start mode=" .. tostring(leave_confirm_mode))
			close_leave_confirm()
		end
	elseif event.GameButton == "Select" or event.GameButton == "Back" then
		play_online_sound_once("Common", "Cancel")
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
				showing_private_join_prompt = false
				t:GetChild("PrivateJoinPrompt"):visible(false)
				play_online_sound_once("Common", "Cancel")
			elseif option and invitation and invitation.id then
				showing_private_join_prompt = false
				t:GetChild("PrivateJoinPrompt"):visible(false)
				MESSAGEMAN:Broadcast("AnswerRoomInvitation", {
					invitation_id=invitation.id,
					accept=option.accept,
				})
				play_online_sound_once("Common", "Start")
			end
		else
			local request = private_join_request and private_join_request.join_request
			if option and request and request.id then
				showing_private_join_prompt = false
				t:GetChild("PrivateJoinPrompt"):visible(false)
				MESSAGEMAN:Broadcast("AnswerPrivateJoinRequest", {
					join_request_id=request.id,
					accept=option.accept,
					reason=option.reason,
				})
				play_online_sound_once("Common", "Start")
			end
		end
	elseif event.GameButton == "Select" or event.GameButton == "Back" then
		showing_private_join_prompt = false
		t:GetChild("PrivateJoinPrompt"):visible(false)
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
			ITGOnline.PackSync:DownloadPackByCandidate(songInfo, candidate, function(ok, message)
				if not ok and t then
					t:playcommand("SetStatus", {
						text=message or "Le téléchargement du pack a échoué.\nVeuillez réessayer ou installer le pack manuellement.",
						showSpinner=false,
						showPrompt=true
					})
				end
			end, { browseOnly = browseOnly, allowExistingDownloadKey = downloadKey })
		end
	elseif event.GameButton == "Select" or event.GameButton == "Back" then
		play_online_sound_once("Common", "Cancel")
		close_pack_choice_menu(true)
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
				player.actionContext = "joined_manager_transfer"
				player_action_user = player
				player_action_options = build_player_action_options(player_action_user)
				player_action_index = 1
				showing_player_action_menu = #player_action_options > 0
				local menu = t:GetChild("PlayerActionMenu")
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
			.. " canDownload=" .. tostring(joined_can_download_pack == true or can_download_browsed_pack() == true))
		if joined_active_index == 1 then
			open_leave_confirm("leave_lobby")
		elseif joined_active_index == 2 and joined_is_manager then
			if not joined_phase_allows_song_selection() then
				t:playcommand("SetStatus", {
					text="La manche actuelle se termine encore. Attendez les resultats avant de choisir une autre chanson.",
					showSpinner=false,
					showPrompt=true
				})
				return false
			end
			local topScreen = SCREENMAN:GetTopScreen()
			if topScreen then
				lobby_flow_trace("input_joined_select_music_transition")
				topScreen:SetNextScreenName("ScreenSelectMusic")
				topScreen:StartTransitioningScreen("SM_GoToNextScreen")
			end
		elseif joined_active_index == 3 and (joined_missing_song or can_download_browsed_pack()) then
			if can_download_browsed_pack() then
				open_browse_pack_download_confirm(joined_song_preview)
			elseif joined_can_download_pack and ITGOnline and ITGOnline.PackSync and ITGOnline.PackSync.DownloadSelectedPack then
				ITGOnline.PackSync:DownloadSelectedPack(joined_missing_song_info or joined_song_preview, function(ok, message)
					lobby_flow_trace("input_joined_download_selected_pack_callback ok=" .. tostring(ok == true)
						.. " messageType=" .. tostring(type(message)))
					if not ok and type(message) == "table" and message.kind == "pack_candidates" then
						open_pack_choice_menu(
							joined_missing_song_info or joined_song_preview,
							message.candidates,
							message.message or "Plusieurs packs correspondent. Choisissez-en un."
						)
						pack_choice_download_key = message.downloadKey
						if SL and SL.Global and SL.Global.Online then
							SL.Global.Online.PackChoiceRecovery.downloadKey = pack_choice_download_key
						end
						return
					end
					if not ok and t then
						t:playcommand("SetStatus", {
							text=message or "Le téléchargement du pack a échoué.\nVeuillez réessayer ou installer le pack manuellement.",
							showSpinner=false,
							showPrompt=true
						})
					end
				end)
			else
				transition_to_online_song_reload()
			end
		elseif joined_active_index == 4 and joined_is_manager then
			if joined_phase_allows_song_selection() then
				open_global_options_menu()
			else
				t:playcommand("SetStatus", {
					text="Les options globales ne peuvent pas changer pendant la manche.",
					showSpinner=false,
					showPrompt=true
				})
			end
		elseif joined_active_index == 6 and joined_can_cancel_song_selection() then
			if ITGOnline and ITGOnline.CancelSongSelection then
				lobby_flow_trace("input_joined_cancel_song_selection_request")
				t:playcommand("SetStatus", {
					text="Annulation du choix de chanson...",
					showSpinner=true,
					showPrompt=false
				})
				ITGOnline:CancelSongSelection(function(ok, decoded, response)
					lobby_flow_trace("input_joined_cancel_song_selection_response ok=" .. tostring(ok == true)
						.. " status=" .. tostring(response and response.statusCode or "nil")
						.. " hasRoom=" .. tostring(decoded and decoded.room ~= nil))
					if not ok and t then
						t:playcommand("SetStatus", {
							text=(response and response.errorMessage) or (decoded and decoded.message) or "Impossible d'annuler le choix de chanson.",
							showSpinner=false,
							showPrompt=true,
							duration=4
						})
					end
				end)
			else
				t:playcommand("SetStatus", {
					text="Annulation du choix indisponible dans cette version.",
					showSpinner=false,
					showPrompt=true,
					duration=4
				})
			end
		elseif joined_active_index == 5 and joined_is_manager then
			if joined_room_can_start() then
				lobby_flow_trace("input_joined_start_room_broadcast")
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
	elseif event.GameButton == "Select" then
		if focus_joined_players() then
			lobby_flow_trace("input_joined_focus_players")
			play_online_sound_once("Common", "Start")
			t:queuecommand("UpdateJoinedLobbyText")
		else
			lobby_flow_trace("input_joined_focus_players_blocked")
			play_online_sound_once("Common", "Cancel")
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
				t:queuecommand("LoseFocus")
				t:queuecommand("Hover")
			end
		else
			if not list_selected then
				active_index = (active_index + (event.GameButton=="MenuRight" and 1 or -1)) % #options
				play_online_sound_once("ScreenSelectMaster", "change")
				t:queuecommand("Hover")
			else
				if lobby_view == "players" then
					if #online_users > 0 then
						online_player_index = ((online_player_index - 1 + (event.GameButton=="MenuRight" and 1 or -1)) % #online_users) + 1
						play_online_sound_once("ScreenSelectMaster", "change")
						t:queuecommand("UpdateOnlinePlayers")
					end
				else
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
					play_online_sound_once("Common", "Start")
					t:queuecommand("OpenPlayerActionMenu")
				else
					play_online_sound_once("Common", "Cancel")
				end
			else
				local lobbyList = t:GetChild("LobbyContent") and t:GetChild("LobbyContent"):GetChild("LobbyList")
				if lobbyList then
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
			if (lobby_view == "lobbies" and #candidates > 0) or (lobby_view == "players" and #online_users > 0) then
				list_selected = true
				play_online_sound_once("Common", "Start")
				focus_selected_browse_list(t)
				t:queuecommand("UpdateOnlinePlayers")
			else
				play_online_sound_once("Common", "Cancel")
			end
		elseif active_index == 2 then
			play_online_sound_once("Common", "Start")
			local onlineHandler = GetOnlineHandlerInstance()
			if onlineHandler and onlineHandler.connected then
				lobby_flow_trace("input_browse_refresh_search_broadcast")
				t:playcommand("SetStatus", {
					text="Recherche des salons...",
					showSpinner=true,
					showPrompt=false
				})
				MESSAGEMAN:Broadcast("SearchLobby")
			else
				lobby_flow_trace("input_browse_refresh_reconnect")
				connected = false
				has_error = false
				attempted = false
				wait_time = 0
				t:GetChild("LobbyContent"):visible(false)
				t:GetChild("OnlinePlayersContent"):visible(false)
				t:playcommand("SetStatus", {
					text="Rafraichissement de la liste des salons...",
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
					text="Connexion au service en ligne en cours. Reessayez dans un instant.",
					showSpinner=false,
					showPrompt=true
				})
				t:queuecommand("CheckConnect")
				return false
			end
			t:GetChild("LobbyContent"):visible(false)
			t:GetChild("OnlinePlayersContent"):visible(false)
			t:playcommand("SetStatus", {
				text="Creation du salon...",
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
		.. " playerAction=" .. tostring(showing_player_action_menu == true)
		.. " packChoice=" .. tostring(showing_pack_choice_menu == true)
		.. " globalOptions=" .. tostring(showing_global_options_menu == true)
		.. " pendingJoinActionId=" .. tostring(pending_join_action_id))
	if showing_leave_confirm then return handle_leave_confirm_input(event) end
	if showing_browse_pack_download_confirm then return handle_browse_pack_download_confirm_input(event) end
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
		cancel_pending_join("Connexion annulee. Rafraichissement des salons...")
		return false
	end

	if showing_global_options_menu then return handle_global_options_menu_input(event) end
	if mode == "joined" then return handle_joined_mode_input(event) end
	return handle_browse_mode_input(event)
end

local InputHandler = function(event)
	if not event.PlayerNumber or not event.button then return false end
	if not t then return false end
	if not is_active_lobby_overlay() then
		lobby_flow_trace("input_ignored reason=inactive_overlay type=" .. tostring(event.type)
			.. " button=" .. tostring(event.GameButton or event.button))
		return false
	end
	event.GameButton = online_menu_button(event.GameButton)

	if GetTimeSinceStart() < input_quiet_until then
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
			text="Initialisation de la connexion en ligne...",
				showSpinner=true
			})
		self:queuecommand("RefreshCurrentRoomSnapshot")
		self:queuecommand("CheckConnect")
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
		Name="JoinTimeoutTimer",
		CheckJoinTimeoutCommand=function(self)
			lobby_flow_trace("join_timeout_check actionId=" .. tostring(pending_join_action_id)
				.. " now=" .. tostring(GetTimeSinceStart())
				.. " deadline=" .. tostring(pending_join_deadline))
			if pending_join_action_id > 0 and GetTimeSinceStart() >= pending_join_deadline then
					cancel_pending_join("La tentative de rejoindre le salon a expire. Rafraichissement...")
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
					cancel_pending_create("La creation du salon a expire. Verifiez la connexion puis reessayez.")
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
		HoverCommand=function(self)
			self:GetChild("LobbyContent"):playcommand("Hover")
			self:GetChild("OnlinePlayersContent"):playcommand("Hover")
			self:GetChild("JoinedLobbyContent"):playcommand("Hover")
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
		local selected_start = nil
		local selected_length = nil
		local text_length = 0
		for i, user in ipairs(online_users) do
			local selected = (list_selected and lobby_view == "players" and i == online_player_index) and "> " or "  "
			local room = user.room and user.room.name and (" " .. room_visibility_label(user.room) .. " " .. tostring(user.room.name)) or ""
			local status = user.status and (" [" .. tostring(user.status) .. "]") or ""
			local display_name = ITGOnline and ITGOnline.UserDisplayName and ITGOnline:UserDisplayName(user, "Joueur") or tostring(user.display_name or user.displayName or user.name or "Joueur")
			local line = clamp_text(selected .. i .. ". " .. display_name .. status .. room, 44)
			if list_selected and lobby_view == "players" and i == online_player_index then
				selected_start = text_length
				selected_length = #line
			end
			lines[#lines + 1] = line
			text_length = text_length + #line + 1
		end

		local playersList = playersContent:GetChild("OnlinePlayersList")
		if playersList then
			playersList:settext(#lines > 0 and table.concat(lines, "\n") or "Aucun joueur connecte trouve.")
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

		self:queuecommand("UpdateOnlinePlayers")
		lobby_flow_trace("UpdateLobbyView_end lobbyVisible=" .. tostring(mode ~= "joined")
			.. " empty=" .. tostring(#candidates == 0)
			.. " queuedUpdateOnlinePlayers=true")
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
			local display_name = "Joueur"
			if player_action_user then
				display_name = ITGOnline and ITGOnline.UserDisplayName
					and ITGOnline:UserDisplayName(player_action_user, player_action_user.profileName or "Joueur")
					or tostring(player_action_user.display_name or player_action_user.displayName or player_action_user.name or player_action_user.profileName or "Joueur")
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
	UpdateGlobalOptionsMenuCommand=function(self)
		local menu = self:GetChild("GlobalOptionsMenu")
		if not menu then return end
		rebuild_global_options_choices()
		local title = menu:GetChild("GlobalOptionsTitle")
		if title then title:settext("Options globales") end
		local detail = menu:GetChild("GlobalOptionsDetail")
		if detail then
			detail:settext("Applique au salon entier : score leaderboard et vitesse de musique.")
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
				title:settext(tostring(inviter.name or "Un joueur") .. " vous invite")
			else
				title:settext(tostring(requester.name or "Un joueur") .. " veut rejoindre")
			end
		end
		local detail = prompt:GetChild("PrivateJoinDetail")
		if detail then
			detail:settext(tostring(room.visibility == "private" and "Salon prive : " or "Salon : ") .. tostring(room.name or "Salon"))
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
		sync_local_missing_song_from_joined_players()
		local joinedContent = self:GetChild("JoinedLobbyContent")
		if not joinedContent then
			lobby_flow_trace("UpdateJoinedLobbyText_aborted reason=no_joined_content")
			return
		end
		local codeValue = joinedContent:GetChild("JoinedLobbyCodeValue")
		if codeValue then
			codeValue:settext(joined_lobby_code ~= "" and joined_lobby_code or "(en attente)")
		end

		local lines = {}
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
			local profile = trim_text(player.profileName or player.name or player.playerId or ("Joueur "..i))
			if tostring(player.playerId or "") == tostring(joined_manager_user_id or "") then
				profile = "[M] " .. profile
			end
			local ready = player.ready and " ✔" or player.readyPendingServer and " ..." or ""
			local missing = ""
			local packSyncText = pack_sync_line_for_player(player)
			if packSyncText ~= "" then
				missing = " · " .. packSyncText
			end
			local optionParts = {}
			local speedMod = trim_text(player.speedMod)
			if speedMod ~= "" then optionParts[#optionParts+1] = speedMod end
			local stepchart = abbreviate_stepchart(player.stepchart)
			if stepchart ~= "" then optionParts[#optionParts+1] = stepchart end
			if missing == "" and joined_song_preview ~= nil and player.songAvailable == false and not player_is_current_user(player) then
				missing = " - selection en cours"
			end
			local maxLineLen = 88
			local selectedPrefix = joined_players_selected and i == joined_player_index and "> " or "  "
			local lineHead = selectedPrefix..i..". "..profile
			local lineTail = ready .. missing
			local optionsText = table.concat(optionParts, " | ")
			local options = ""
			if optionsText ~= "" then
				local remaining = maxLineLen - #lineHead - #lineTail
				if remaining >= 8 then
					local optionsBudget = remaining - 3 -- " [" + "]"
					options = " [" .. clamp_text(optionsText, optionsBudget) .. "]"
				end
			end
			local line = clamp_text(lineHead..options..lineTail, maxLineLen)
			if joined_players_selected and i == joined_player_index then
				selected_start = text_length
				selected_length = #line
			end
			lines[#lines+1] = line
			text_length = text_length + #line + 1
		end
		if joined_is_manager and #joined_lobby_players > 1 then
			local helpLine = joined_players_selected
				and "START: transferer manager  |  SELECT: revenir"
				or "SELECT: choisir un joueur pour transferer manager"
			lines[#lines+1] = ""
			lines[#lines+1] = helpLine
		end

		local playersText = joinedContent:GetChild("JoinedLobbyPlayers")
		if playersText then
			playersText:settext(#lines > 0 and table.concat(lines, "\n") or "En attente des joueurs...")
			playersText:ClearAttributes()
			if selected_start and selected_length and selected_length > 0 then
				playersText:AddAttribute(selected_start, {Length=selected_length, Diffuse={0,1,0,1}})
			end
		end
		update_joined_song_card(joinedContent)

		local songStatus = joinedContent and joinedContent:GetChild("JoinedLobbySongStatus")
		if songStatus then
			local statusLines = {}

			local missingSongInfo = joined_missing_song_info or joined_song_preview
			if joined_missing_song and missingSongInfo then
				if joined_missing_song_reason == "song_hash_mismatch" then
					statusLines[#statusLines + 1] = "La stepchart existe localement, mais l'audio est different de celui du salon."
					statusLines[#statusLines + 1] = "Le mode online exige la même musique et la même stepchart."
				elseif joined_missing_song_reason == "chart_mismatch" or joined_missing_song_reason == "hash_mismatch" then
					statusLines[#statusLines + 1] = "La musique ou la stepchart trouvée est différente de celle du salon."
					statusLines[#statusLines + 1] = "Veuillez supprimer le pack manuellement, recharger Songs, puis télécharger à nouveau le pack."
				elseif joined_missing_song_reason == "download_failed" then
					if pack_choice_all_candidates_exhausted then
						statusLines[#statusLines + 1] = "Aucun pack candidat ne contient la chart attendue."
						statusLines[#statusLines + 1] = "Installez manuellement le bon pack/stepchart."
					else
						statusLines[#statusLines + 1] = "Le téléchargement du pack a échoué."
						statusLines[#statusLines + 1] = "Veuillez réessayer ou installer le pack manuellement."
					end
				elseif joined_missing_song_reason == "missing_local_song" and joined_can_download_pack then
					statusLines[#statusLines + 1] = "Vous ne possédez pas ce pack localement."
					statusLines[#statusLines + 1] = "Vous pouvez télécharger le pack utilisé par le salon."
				elseif joined_can_download_pack then
					statusLines[#statusLines + 1] = "Cette chanson existe peut-être dans vos packs,"
					statusLines[#statusLines + 1] = "mais aucune stepchart identique à celle du salon n’a été trouvée."
					statusLines[#statusLines + 1] = "Vous pouvez télécharger le pack utilisé par le salon."
				else
					statusLines[#statusLines + 1] = "Pack de chansons manquant ou different localement"
				end

				local countdownSeconds = joined_missing_song_countdown_seconds()
				if countdownSeconds and joined_can_download_pack and not pack_sync_busy() then
					statusLines[#statusLines + 1] = "Expulsion du salon dans " .. tostring(countdownSeconds) .. " s si le pack n'est pas telecharge."
				end
			elseif joined_song_preview then
				statusLines[#statusLines + 1] = (joined_song_confirmed and "✔ Chanson selectionnee" or "Choix de chanson en cours")
				if joined_preview_unknown_pack and not joined_song_confirmed then
					statusLines[#statusLines + 1] = "Pack absent localement."
					statusLines[#statusLines + 1] = "Le manager parcourt ce pack sans avoir encore choisi de chanson."
					statusLines[#statusLines + 1] = "Vous pouvez le telecharger maintenant si vous le souhaitez."
				end
				if joined_phase == "playing" then
					statusLines[#statusLines + 1] = "Manche en cours. En attente de la fin pour tous."
				elseif joined_phase == "results" then
					statusLines[#statusLines + 1] = "Resultats prets."
				elseif joined_phase == "starting" then
					local seconds = ITGOnline and ITGOnline.SecondsUntilScheduledStart and ITGOnline:SecondsUntilScheduledStart() or nil
					statusLines[#statusLines + 1] = seconds and ("Demarrage dans " .. tostring(math.ceil(math.max(0, seconds))) .. "...") or "Demarrage..."
				elseif joined_phase == "config" or joined_phase == "lobby_ready" then
					if joined_any_player_missing_song() then
						statusLines[#statusLines + 1] = "Selection en cours."
					end
				end
			elseif joined_is_manager then
				statusLines[#statusLines + 1] = "Choisissez une chanson pour lancer la manche."
			else
				statusLines[#statusLines + 1] = ""
			end
			songStatus:settext(table.concat(statusLines, "\n"):gsub("^%s+", ""):gsub("%s+$", ""))
			songStatus:diffuse(joined_missing_song and Color.Red or joined_song_confirmed and Color.Green or Color.White)
		end

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

		local selectSongButton = joinedContent and joinedContent:GetChild("SelectSongButton")
		if selectSongButton then
			local allowSelection = joined_phase_allows_song_selection()
			local visible = joined_is_manager and allowSelection
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
			if visibilityKey ~= last_select_song_visibility_debug_key then
				last_select_song_visibility_debug_key = visibilityKey
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
			reloadSongsButton:visible(show_pack_download_button())
			local label = reloadSongsButton:GetChild("ReloadSongsLabel")
			if label then
				if syncBusy then
					label:settext("Telechargement...")
				else
					label:settext((joined_can_download_pack or canDownloadBrowsePack) and "Telecharger pack" or "Recharger chansons")
				end
			end
			reloadSongsButton:playcommand("Hover")
		end

		local globalOptionsButton = joinedContent and joinedContent:GetChild("GlobalOptionsButton")
		if globalOptionsButton then
			local visible = joined_is_manager and joined_phase_allows_song_selection()
			globalOptionsButton:visible(visible)
			local label = globalOptionsButton:GetChild("GlobalOptionsLabel")
			if label then
				label:settext("Options globales")
			end
			local modeLabel = globalOptionsButton:GetChild("GlobalOptionsModeLabel")
			if modeLabel then
				modeLabel:settext(global_options_mode_label())
			end
		end

		local cancelChoiceButton = joinedContent and joinedContent:GetChild("CancelChoiceButton")
		if cancelChoiceButton then
			cancelChoiceButton:visible(joined_can_cancel_song_selection())
			cancelChoiceButton:playcommand("Hover")
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
			if debugKey ~= last_start_visibility_debug_key then
				last_start_visibility_debug_key = debugKey
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
					if focusKey ~= last_auto_start_focus_key then
						last_auto_start_focus_key = focusKey
					end
					if joined_active_index ~= 5 and (not joined_user_moved_focus or not currentFocusStillAvailable) then
						joined_active_index = 5
						joined_user_moved_focus = false
						self:queuecommand("Hover")
					end
					last_auto_start_request_key = ""
				else
					last_auto_start_focus_key = ""
					last_auto_start_request_key = ""
				end
			end
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
				lobby_flow_trace("CheckConnect_deferred reason=recent_leave_no_room")
				self:sleep(0.25):queuecommand("CheckConnect")
				return
			end
			local onlineHandler = GetOnlineHandlerInstance()
			if onlineHandler then
				-- If no connection exists, first (re)establish the connection.
				-- Only try once per screen load to avoid infinite loops of trying to connect.
				if not attempted and (not onlineHandler.socket or onlineHandler.errorMsg ~= nil) then
					self:playcommand("SetStatus", {
						text="Connexion au service en ligne...",
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
						text="Connexion au service en ligne... ("..wait_time.."s)",
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
					text="Initialisation du gestionnaire en ligne...",
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
				lobby_flow_trace("Display_deferred reason=recent_leave_no_room")
				self:sleep(0.25):queuecommand("Display")
				return
			end
			local onlineHandler = GetOnlineHandlerInstance()
			if onlineHandler then
				if onlineHandler.connected then
					connected = true
					has_error = false
					reset_browse_focus()
					self:playcommand("SetStatus", {
						text="Connecte au service en ligne.",
						showSpinner=false,
						showPrompt=false
					})
					self:GetChild("NetworkStatus"):visible(false)
					ScreenOnlineLobbiesApplyCurrentRoomSnapshot(self, "display")
					if ITGOnline and ITGOnline.Sync then
						lobby_flow_trace("Display_sync_requested")
						self:playcommand("SetStatus", {
							text="Synchronisation de l'etat en ligne...",
							showSpinner=true,
							showPrompt=false
						})
						ITGOnline:Sync(function(ok, decoded)
							lobby_flow_trace("Display_sync_result ok=" .. tostring(ok == true)
								.. " hasRoom=" .. tostring(decoded and decoded.current_room ~= nil)
								.. " lobbyCount=" .. tostring(decoded and decoded.lobbies and #decoded.lobbies or 0))
							if not ok or not decoded then
								MESSAGEMAN:Broadcast("SearchLobby")
							end
						end)
					elseif ITGOnline and ITGOnline.currentRoomId then
						lobby_flow_trace("Display_fetch_current_room_by_id room=" .. tostring(ITGOnline.currentRoomId))
						self:playcommand("SetStatus", {
							text="Restauration du salon actuel...",
							showSpinner=true,
							showPrompt=false
						})
						ITGOnline:FetchRoom(ITGOnline.currentRoomId, function(ok, decoded)
							lobby_flow_trace("Display_fetch_room_result ok=" .. tostring(ok == true)
								.. " hasRoom=" .. tostring(decoded and decoded.room ~= nil)
								.. " phase=" .. tostring(decoded and decoded.room and decoded.room.phase or "nil"))
							if ok and decoded and decoded.room then
								MESSAGEMAN:Broadcast("OnlineLobbyState", ITGOnline:LobbyStatePayload(decoded.room))
							else
								MESSAGEMAN:Broadcast("SearchLobby")
							end
						end)
					elseif ITGOnline and ITGOnline.FetchCurrentRoom then
						lobby_flow_trace("Display_fetch_current_room")
						self:playcommand("SetStatus", {
							text="Restauration du salon actuel...",
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
								MESSAGEMAN:Broadcast("SearchLobby")
							end
						end)
					else
						lobby_flow_trace("Display_search_lobby_fallback")
						self:queuecommand("UpdateLobbyView")
						MESSAGEMAN:Broadcast("SearchLobby")
					end
					self:queuecommand("Hover")
				end

				if onlineHandler.errorMsg ~= nil then
					connected = false
					has_error = true
					self:playcommand("SetStatus", {
						text="Erreur de connexion au service en ligne :\n"..onlineHandler.errorMsg,
						showSpinner=false,
						showPrompt=true,
						promptText="Appuyez sur &START; pour revenir au menu principal."
					})
					self:GetChild("LobbyContent"):visible(false)
					self:GetChild("OnlinePlayersContent"):visible(false)
				end
			end
		end,
				RefreshCurrentRoomSnapshotCommand=function(self)
					ScreenOnlineLobbiesApplyCurrentRoomSnapshot(self, "screen_online_lobbies_refresh")
				end,
				RefreshLobbyAfterLeaveCommand=function(self)
					if not is_active_lobby_overlay() then return end
					if leaving_lobby then return end
					if ITGOnline and ITGOnline.currentRoomId then return end
					lobby_flow_trace("refresh_lobby_after_leave")
					MESSAGEMAN:Broadcast("SearchLobby", { force=true, minInterval=0 })
				end,
				LeaveLobbyWatchdogCommand=function(self)
					if not is_active_lobby_overlay() then return end
					if not leaving_lobby then return end
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
					lobby_search_ui_pending = false
					apply_lobby_search_to_ui(self, "deferred")
				end,
				LobbySearchedMessageCommand=function(self, params)
					if not is_active_lobby_overlay() then
						lobby_flow_trace("LobbySearched_ignored reason=inactive_overlay")
						return
					end
					candidates = params and params.lobbies or {}
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
			local previousLobbyCode = joined_lobby_code
			local previousJoinedPhase = joined_phase
			local previousSongConfirmed = joined_song_confirmed
			lobby_flow_trace("OnlineLobbyState_before_apply previous_code=" .. tostring(previousLobbyCode)
				.. " previous_phase=" .. tostring(previousJoinedPhase)
				.. " previous_song_confirmed=" .. tostring(previousSongConfirmed == true)
				.. " previous_ready={" .. tostring(ready_summary()) .. "}")
			local previousIsManager = joined_is_manager
			clear_pending_join()
			clear_pending_create()
			mode = "joined"
			leaving_lobby = false
			showing_leave_confirm = false
			list_selected = false
			join_lobby_code = ""
			joined_lobby_code = params and params.code or ""
			if joined_lobby_code ~= previousLobbyCode then
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
			end
			joined_lobby_players = params and params.players or {}
			joined_is_manager = params and params.isManager or false
			joined_manager_user_id = params and params.manager and params.manager.id or nil
			if previousLobbyCode ~= "" and previousLobbyCode == joined_lobby_code and not previousIsManager and joined_is_manager then
				self:playcommand("SetStatus", {
					text="Vous etes maintenant le manager du salon.",
					showSpinner=false,
					showPrompt=false,
					duration=5
				})
			end
			if not joined_is_manager then
				joined_players_selected = false
			end
			joined_player_index = math.max(1, math.min(joined_player_index, math.max(1, #joined_lobby_players)))
			joined_phase = params and params.phase or nil
			joined_global_options = normalize_global_options(params and params.globalOptions or nil)
			if joined_phase == "results" then
				joined_song_preview = nil
				joined_song_confirmed = false
				joined_song_selected_key = ""
				joined_missing_song = false
				joined_missing_song_info = nil
				joined_can_download_pack = false
				joined_missing_song_reason = nil
				joined_preview_unknown_pack = false
			else
				local previousSelectedKey = joined_song_selected_key
				local selectedSongInfo = normalize_online_song_info(params and params.songInfo or nil)
				if selectedSongInfo then
					joined_song_preview = selectedSongInfo
					joined_song_confirmed = true
					joined_song_selected_key = tostring(selectedSongInfo.selectedAt or selectedSongInfo.selected_at or "")
				else
					local snapshotSource = tostring(params and params.snapshotSource or "")
					local shouldClearPreview = (previousJoinedPhase == "results" and joined_phase == "lobby")
						or (previousSongConfirmed and joined_phase == "lobby")
						or snapshotSource:find("song_selection_cancel", 1, true) ~= nil
						or snapshotSource:find("room.play_state_reset_to_lobby", 1, true) ~= nil
					if shouldClearPreview then
						joined_song_preview = nil
						joined_preview_unknown_pack = false
					end
					joined_song_confirmed = false
					joined_song_selected_key = ""
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
				if ITGOnline and ITGOnline.PackSync and ITGOnline.PackSync.ResetLocalState then
					ITGOnline.PackSync:ResetLocalState("no_song_confirmed")
				end
				if joined_song_preview and ITGOnline and ITGOnline.PackSync and ITGOnline.PackSync.ManagerBrowsingPreview then
					ITGOnline.PackSync:ManagerBrowsingPreview(joined_song_preview)
				end
			end
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
				.. " isManager=" .. tostring(joined_is_manager)
				.. " managerUserId=" .. tostring(joined_manager_user_id)
				.. " players=" .. tostring(#joined_lobby_players)
				.. " songConfirmed=" .. tostring(joined_song_confirmed == true)
				.. " preview=" .. tostring(joined_song_preview and (joined_song_preview.title or joined_song_preview.folder_name or joined_song_preview.song_hash) or "none")
				.. " missingSong=" .. tostring(joined_missing_song == true)
				.. " ready={" .. tostring(ready_summary()) .. "}")

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
				lobby_flow_trace("OnlineMissingSong_received reason=" .. tostring(params and params.reason or "missing_local_song")
					.. " hasSongInfo=" .. tostring(params and params.songInfo ~= nil)
					.. " noCompatibleChart=" .. tostring(params and params.noCompatibleChart == true)
					.. " currentPreviewPack=" .. tostring(joined_song_preview and song_info_pack(joined_song_preview) or "")
					.. " mode=" .. tostring(mode)
					.. " joined_code=" .. tostring(joined_lobby_code)
					.. " phase=" .. tostring(joined_phase))
				joined_missing_song = true
			joined_missing_song_info = params and params.songInfo or joined_song_preview
			joined_missing_song_reason = params and params.reason or "missing_local_song"
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
			local reason = params and params.reason or "missing_local_song"
			if reason == "download_failed" then
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
							"Le pack choisi n'a pas fourni la chart attendue. Choisissez un autre pack."
						)
					end
				end
				if not reopened then
					lobby_flow_trace("OnlineMissingSong_pack_choice_exhausted")
					pack_choice_all_candidates_exhausted = true
					self:playcommand("SetStatus", {
						text="Aucun des packs testés ne contient la chart attendue.\nInstallation manuelle requise pour cette chanson.",
						showSpinner=false,
						showPrompt=true
					})
				end
			end
			set_joined_default_active_index()
			lobby_flow_trace("OnlineMissingSong_update_ui")
			self:queuecommand("UpdateJoinedLobbyText")
			self:queuecommand("Hover")
		end,
			OnlineSongAvailableMessageCommand=function(self)
				if not is_active_lobby_overlay() then
					lobby_flow_trace("OnlineSongAvailable_ignored reason=inactive_overlay")
					return
				end
				local wasMissing = joined_missing_song
			lobby_flow_trace("OnlineSongAvailable_received wasMissing=" .. tostring(wasMissing)
				.. " mode=" .. tostring(mode)
				.. " joined_code=" .. tostring(joined_lobby_code)
				.. " phase=" .. tostring(joined_phase)
				.. " currentPreviewPack=" .. tostring(joined_song_preview and song_info_pack(joined_song_preview) or ""))
			joined_missing_song = false
			joined_missing_song_info = nil
			joined_can_download_pack = false
			joined_missing_song_reason = nil
			if wasMissing and ITGOnline and ITGOnline.ReportSongAvailability then
				lobby_flow_trace("OnlineSongAvailable_report_availability missing=false reason=reloaded")
				ITGOnline:ReportSongAvailability(false, "reloaded")
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
			.. " acceptsNewMembers=" .. tostring(params.acceptsNewMembers)
			.. " phase=" .. tostring(params.phase)
			.. " mode=" .. tostring(mode)
			.. " currentRoomId=" .. tostring(ITGOnline and ITGOnline.currentRoomId or "nil"))
		if params.acceptsNewMembers == false
			or (params.acceptsNewMembers == nil and params.phase ~= nil and normalized_online_phase(params.phase) ~= "lobby") then
			lobby_flow_trace("OnlineLobbyJoinSelected_rejected reason=not_accepting_members code=" .. tostring(params.code)
				.. " phase=" .. tostring(params.phase))
			play_online_sound_once("Common", "Cancel")
			self:playcommand("SetStatus", {
				text="Ce salon n'accepte plus de nouveaux joueurs.",
				showSpinner=false,
				showPrompt=true,
				duration=4
			})
			return
		end

		join_lobby_code = params.code
		self:GetChild("LobbyContent"):visible(false)
		self:GetChild("OnlinePlayersContent"):visible(false)
		self:playcommand("SetStatus", {
			text="Connexion au salon...",
			showSpinner=true,
			showPrompt=false
		})
		begin_join_timeout(self)
		lobby_flow_trace("OnlineLobbyJoinSelected_broadcast_join code=" .. tostring(params.code))
		MESSAGEMAN:Broadcast("JoinLobby", {
			code=params.code,
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
	private_join_request = params
	private_join_prompt_kind = "join_request"
	private_join_prompt_index = 1
	showing_private_join_prompt = true
	local prompt = self:GetChild("PrivateJoinPrompt")
	if prompt then prompt:visible(true) end
	self:queuecommand("UpdatePrivateJoinPrompt")
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
	lobby_flow_trace("OnlineRoomInvitation_received inviter=" .. tostring(params.invitation.inviter_id or params.invitation.user_id or "")
		.. " room=" .. tostring(params.invitation.room_id or "")
		.. " mode=" .. tostring(mode)
		.. " joined_code=" .. tostring(joined_lobby_code)
		.. " currentRoomId=" .. tostring(ITGOnline and ITGOnline.currentRoomId or "nil"))
	private_join_request = params
	private_join_prompt_kind = "invitation"
	private_join_prompt_index = 1
	showing_private_join_prompt = true
	local prompt = self:GetChild("PrivateJoinPrompt")
	if prompt then prompt:visible(true) end
	self:queuecommand("UpdatePrivateJoinPrompt")
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
			local preview = normalize_online_song_info(params)
		if preview then
			lobby_flow_trace("OnlineSongPreview_received pack=" .. tostring(song_info_pack(preview))
				.. " song=" .. tostring(preview.song or preview.title or "")
				.. " mode=" .. tostring(mode)
				.. " joined_code=" .. tostring(joined_lobby_code)
				.. " phase=" .. tostring(joined_phase)
				.. " currentRoomId=" .. tostring(ITGOnline and ITGOnline.currentRoomId or "nil"))
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
			self:queuecommand("UpdateJoinedLobbyText")
		else
			lobby_flow_trace("OnlineSongPreview_ignored reason=normalize_failed")
		end
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
		lobby_flow_trace("OnlinePackSyncLocalStatus_received status=" .. tostring(params and params.status or "")
			.. " progress=" .. tostring(params and params.progress or "")
			.. " userId=" .. tostring(params and params.userId or params and params.user_id or "")
			.. " mode=" .. tostring(mode)
			.. " joined_code=" .. tostring(joined_lobby_code))
		apply_local_pack_sync_status_to_joined_player(params)
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
		if params and params.songInfo and joined_song_preview and song_info_pack(params.songInfo) == song_info_pack(joined_song_preview) then
			joined_preview_unknown_pack = false
			lobby_flow_trace("OnlinePackDownloaded_matches_preview refreshing_joined_ui pack=" .. tostring(song_info_pack(params.songInfo)))
			if ITGOnline and ITGOnline.PackSync and ITGOnline.PackSync.ManagerBrowsingPreview then
				lobby_flow_trace("OnlinePackDownloaded_recheck_manager_preview")
				ITGOnline.PackSync:ManagerBrowsingPreview(joined_song_preview)
			end
			normalize_joined_active_index()
			self:queuecommand("UpdateJoinedLobbyText")
			self:queuecommand("UpdateLobbyView")
			self:queuecommand("UpdateOnlinePlayers")
			self:queuecommand("Hover")
		end
		if ITGOnline and ITGOnline.FetchRoom and ITGOnline.currentRoomId then
			lobby_flow_trace("OnlinePackDownloaded_fetch_room_begin room=" .. tostring(ITGOnline.currentRoomId))
			ITGOnline:FetchRoom(ITGOnline.currentRoomId, function(ok, decoded)
				lobby_flow_trace("OnlinePackDownloaded_fetch_room_result ok=" .. tostring(ok == true)
					.. " hasRoom=" .. tostring(decoded and decoded.room ~= nil)
					.. " room=" .. tostring(decoded and decoded.room and decoded.room.id or "nil")
					.. " phase=" .. tostring(decoded and decoded.room and decoded.room.phase or "nil"))
				if ok and decoded and decoded.room then
					MESSAGEMAN:Broadcast("OnlineLobbyState", ITGOnline:LobbyStatePayload(decoded.room))
				end
			end)
		else
			lobby_flow_trace("OnlinePackDownloaded_fetch_room_skipped hasClient=" .. tostring(ITGOnline ~= nil)
				.. " hasFetch=" .. tostring(ITGOnline and ITGOnline.FetchRoom ~= nil)
				.. " currentRoomId=" .. tostring(ITGOnline and ITGOnline.currentRoomId or "nil"))
		end
	end,
			OnlineResponseStatusMessageCommand=function(self, params)
				if not is_active_lobby_overlay() then return end
				if params and params.event == "createLobby" and params.success == false then
				clear_pending_create()
				mode = "browse"
				self:GetChild("JoinedLobbyContent"):visible(false)
				self:queuecommand("UpdateLobbyView")
				self:playcommand("SetStatus", {
					text=params.message and ("Echec de creation du salon :\n"..params.message) or "Echec de creation du salon.",
					showSpinner=false,
					showPrompt=false,
					force=true
				})
		elseif params and params.event == "joinLobby" and params.success == true then
			begin_join_timeout(self, 60)
			self:playcommand("SetStatus", {
				text=(params.message or "Demande envoyee. En attente du manager du salon.") .. "\nAppuyez sur Select ou Back pour annuler.",
				showSpinner=false,
				showPrompt=false
			})
		elseif params and params.event == "joinLobby" and params.success == false then
			clear_pending_join()
			mode = "browse"
			self:GetChild("JoinedLobbyContent"):visible(false)
			self:queuecommand("UpdateLobbyView")
				self:playcommand("SetStatus", {
					text=params.message and ("Echec de connexion au salon :\n"..params.message) or "Echec de connexion au salon.",
					showSpinner=false,
						showPrompt=false,
						duration=4,
						force=true
					})
			elseif params and params.event == "leaveLobby" and params.success == false then
				leaving_lobby = false
				showing_leave_confirm = false
				-- Leave failed: restore joined view coherently.
				mode = "joined"
				self:GetChild("JoinedLobbyContent"):visible(true)
				self:GetChild("LobbyContent"):visible(false)
				self:GetChild("OnlinePlayersContent"):visible(false)
				if ITGOnline and ITGOnline.FetchRoom and ITGOnline.LobbyStatePayload then
					ITGOnline:FetchRoom(nil, function(ok, decoded)
						if ok and decoded and decoded.room and is_active_lobby_overlay() then
							MESSAGEMAN:Broadcast("OnlineLobbyState", ITGOnline:LobbyStatePayload(decoded.room))
						end
					end)
				end
				self:queuecommand("UpdateJoinedLobbyText")
				self:playcommand("SetStatus", {
				text=params.message and ("Echec de sortie du salon :\n"..params.message) or "Echec de sortie du salon.",
				showSpinner=false,
				showPrompt=false,
				force=true
			})
		elseif params and params.event == "invitePlayer" then
				if params.success then
					self:playcommand("SetStatus", {
						text=params.message or "Invitation envoyee.",
						showSpinner=false,
						showPrompt=false
					})
				else
					mode = "browse"
					self:GetChild("JoinedLobbyContent"):visible(false)
					self:queuecommand("UpdateLobbyView")
					self:playcommand("SetStatus", {
						text=params.message and ("Echec de l'invitation :\n"..params.message) or "Echec de l'invitation.",
						showSpinner=false,
						showPrompt=false,
						force=true
					})
				end
		elseif params and params.event == "privateJoinAnswer" then
			self:playcommand("SetStatus", {
				text=params.message or "Demande traitee.",
				showSpinner=false,
				showPrompt=false
			})
		elseif params and params.event == "roomInvitationAnswer" then
			self:playcommand("SetStatus", {
				text=params.message or "Invitation traitee.",
				showSpinner=false,
				showPrompt=false
			})
			elseif params and params.event == "cancelSongSelection" then
					self:playcommand("SetStatus", {
						text=params.message or (params.success and "Choix de chanson annule." or "Impossible d'annuler le choix de chanson."),
						showSpinner=false,
						showPrompt=params.success ~= true,
						duration=4,
						force=params.success ~= true
					})
			elseif params and params.message then
				self:playcommand("SetStatus", {
					text=tostring(params.message),
					showSpinner=false,
					showPrompt=params.success ~= true,
					duration=params.success == true and 3 or 5,
					force=params.success ~= true or params.critical == true
				})
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
				self:x(browse_lobby_x)
				self.idx = 0
			end,
			OnCommand=function(self)
				self:playcommand("UpdateData", {data=candidates})
			end,

			Def.Quad{
				InitCommand=function(self)
					self:zoomto(browse_panel_width,browse_panel_height):y(browse_panel_y):diffuse(Color.White)
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
					self:zoomto(browse_panel_width-2,browse_panel_height-2):y(browse_panel_y):diffuse(Color.Black)
				end
			},

			Def.Quad{
				InitCommand=function(self)
					self:zoomto(browse_panel_width-10, 1):y(-150):diffuse(Color.White)
				end
			},

			LoadFont("Common Bold")..{
					Text="Salons disponibles",
				InitCommand=function(self)
					self:horizalign(left):x(-(browse_panel_width/2)+8):y(-170):zoom(0.42)
				end,
				HoverCommand=function(self)
					self:diffuse(active_index == self:GetParent().idx and GetHexColor(SL.Global.ActiveColorIndex) or Color.White)
				end
			},

			LoadFont("Common Normal")..{
				Name="LobbyCount",
				Text="0/0",
				InitCommand=function(self)
					self:horizalign(right):x((browse_panel_width/2)-8):y(-170):zoom(0.58)
				end,
				UpdateIndexCommand=function(self, params)
					self:settext(params.idx .. "/" .. params.total)
				end
			},

			LoadActor("LobbyInfo.lua")
		},

		LoadFont("Common Normal")..{
			Name="EmptyStateText",
				Text="Aucun salon trouve.",
			InitCommand=function(self)
				self:horizalign(center):xy(browse_lobby_x, -118):zoom(0.72):diffuse(Color.White):visible(false)
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
					Text="Joueurs en ligne",
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
				self:x(browse_button_x)
				self.idx = idx - 1
			end,

			Def.Quad{
				InitCommand=function(self)
					self:zoomto(browse_button_width, browse_button_height):diffuse(Color.White)
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
					self:zoomto(browse_button_width-2, browse_button_height-2):diffuse(Color.Black)
				end
			},

			LoadFont("Common Bold")..{
					Text="Rafraichir",
				InitCommand=function(self)
					self:zoom(0.42)
				end,
				HoverCommand=function(self)
					self:diffuse(active_index == self:GetParent().idx and GetHexColor(SL.Global.ActiveColorIndex) or Color.White)
				end
			},
			Def.Quad{
				InitCommand=function(self)
					self:zoomto(browse_button_width, browse_button_height):diffuse(color("#424242")):diffusealpha(0)
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
				self:x(browse_button_x)
				self.idx = idx - 1
			end,

			Def.Quad{
				InitCommand=function(self)
					self:zoomto(browse_button_width, browse_button_height):diffuse(Color.White)
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
					self:zoomto(browse_button_width-2, browse_button_height-2):diffuse(Color.Black)
				end
			},

			LoadFont("Common Bold")..{
					Text="Creer un salon",
				InitCommand=function(self)
					self:zoom(0.38)
				end,
				HoverCommand=function(self)
					self:diffuse(active_index == self:GetParent().idx and GetHexColor(SL.Global.ActiveColorIndex) or Color.White)
				end
			},
			Def.Quad{
				InitCommand=function(self)
					self:zoomto(browse_button_width, browse_button_height):diffuse(color("#424242")):diffusealpha(0)
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
				self:x(browse_button_x)
				self.idx = idx - 1
			end,

			Def.Quad{
				InitCommand=function(self)
					self:zoomto(browse_button_width, browse_button_height):diffuse(Color.White)
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
					self:zoomto(browse_button_width-2, browse_button_height-2):diffuse(Color.Black)
				end
			},

			LoadFont("Common Bold")..{
					Text="Retour",
				InitCommand=function(self)
					self:zoom(0.42)
				end,
				HoverCommand=function(self)
					self:diffuse(active_index == self:GetParent().idx and GetHexColor(SL.Global.ActiveColorIndex) or Color.White)
				end
			},
			Def.Quad{
				InitCommand=function(self)
					self:zoomto(browse_button_width, browse_button_height):diffuse(color("#424242")):diffusealpha(0)
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
				self:zoomto(browse_panel_width,browse_panel_height):x(browse_players_x):y(browse_panel_y):diffuse(Color.White)
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
				self:zoomto(browse_panel_width-2,browse_panel_height-2):x(browse_players_x):y(browse_panel_y):diffuse(Color.Black)
			end
		},
		Def.Quad{
			InitCommand=function(self)
				self:zoomto(browse_panel_width-10, 1):x(browse_players_x):y(-150):diffuse(Color.White)
			end
		},
		LoadFont("Common Bold")..{
				Text="Joueurs en ligne",
			InitCommand=function(self)
				self:horizalign(left):x(browse_players_x-(browse_panel_width/2)+8):y(-170):zoom(0.42)
			end
		},
		LoadFont("Common Normal")..{
			Name="OnlinePlayersCount",
			Text="0",
			InitCommand=function(self)
				self:horizalign(right):x(browse_players_x+(browse_panel_width/2)-8):y(-170):zoom(0.58)
			end
		},
		LoadFont("Common Normal")..{
			Name="OnlinePlayersList",
				Text="Aucun joueur connecte trouve.",
			InitCommand=function(self)
				self:horizalign(left):vertalign(top):xy(browse_players_x-(browse_panel_width/2)+10, -132):zoom(0.48):maxwidth(420)
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
					Text="Salons disponibles",
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
					Text="Rafraichir",
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
					Text="Creer un salon",
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
					Text="Retour",
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
				Text="Salon rejoint",
			InitCommand=function(self)
				self:horizalign(left):x(-290):y(-170):zoom(0.40)
			end
		},
		LoadFont("Common Normal")..{
			Name="JoinedLobbyCodeLabel",
				Text="Code du salon :",
			InitCommand=function(self)
				self:horizalign(right):x(-10):y(-170):zoom(0.72)
			end
		},
		LoadFont("Common Bold")..{
			Name="JoinedLobbyCodeValue",
				Text="(en attente)",
			InitCommand=function(self)
				self:horizalign(right):x(50):y(-170):zoom(0.42)
			end
		},
		LoadFont("Common Normal")..{
			Name="JoinedLobbyPlayers",
				Text="En attente des joueurs...",
			InitCommand=function(self)
				self:horizalign(left):x(-290):y(-112):zoom(0.72):maxwidth(470)
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
			Text="BANNIERE",
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
		LoadFont("Common Normal")..{
			Name="JoinedSongPack",
			Text="",
			InitCommand=function(self)
				self:horizalign(left):xy(96, -148):zoom(0.38):maxwidth(500):diffuse(0.85,0.85,0.85,1)
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
				self:horizalign(left):xy(160, -96):zoom(WideScale(0.38, 0.40)):maxwidth(320)
			end
		},
		LoadFont("Common Normal")..{
			Name="JoinedLobbySongStatus",
				Text="En attente de la chanson...",
			InitCommand=function(self)
				self:horizalign(left):vertalign(top):xy(-290, 58):zoom(0.44):maxwidth(800)
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
					Text="Quitter le salon",
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
					Text="Choisir musique",
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
						Text="Telecharger pack",
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
					}
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
					Text="Options globales",
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
						self:xy(180, 138)
						self.idx = 6
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
						Text="Annuler choix",
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
					self.idx = 5
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
						Text="START",
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
					title:settext("Etes-vous sur de vouloir quitter ?")
				else
					title:settext("Se deconnecter du salon ?")
				end
			end
			if cancelLabel then
				cancelLabel:settext(leave_confirm_mode == "exit_online" and "Non" or "Annuler")
			end
			if confirmLabel then
				confirmLabel:settext(leave_confirm_mode == "exit_online" and "Oui" or "Deconnecter")
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
				Text="Se deconnecter du salon ?",
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
					Text="Annuler",
				InitCommand=function(self)
					self:zoom(0.5)
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
					Text="Deconnecter",
				InitCommand=function(self)
					self:zoom(0.5)
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
			Text="Telecharger ce pack ?",
			InitCommand=function(self)
				self:y(-82):zoom(0.72):diffuse(Color.White)
			end
		},
		LoadFont("Common Normal")..{
			Text="Le manager parcourt ce pack, mais n'a pas encore choisi de chanson.\nTelecharger maintenant peut prendre du temps et de l'espace disque.",
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
				Text="Annuler",
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
				Text="Telecharger",
				InitCommand=function(self)
					self:zoom(0.5)
				end,
				HoverCommand=function(self)
					self:diffuse(browse_pack_download_confirm_index == 1 and GetHexColor(SL.Global.ActiveColorIndex) or Color.White)
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
			Text="Options globales",
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
			Text="Gauche/Droite : choisir   Valider : appliquer   Retour : fermer",
			InitCommand=function(self)
				self:xy(0, 135):zoom(0.38):maxwidth(1180):diffuse(0.7,0.7,0.7,1)
			end
		}
	},



		LoadFont("Common Normal")..{
			Name="ITGOnlineBuildMarker",
			Text="ITG Online client",
			InitCommand=function(self)
				self:xy(_screen.w - 12, _screen.h - 18):horizalign(right):zoom(0.32):diffuse(0.75,0.75,0.75,0.85)
			end
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
