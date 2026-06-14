local active_index = 0
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

local mode = "browse"
local joined_active_index = 1
local joined_is_manager = false
local joined_phase = nil
local joined_lobby_code = ""
local joined_lobby_players = {}
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
local showing_global_options_menu = false
local global_options_index = 1
local joined_global_options = { scoreMode="itg", musicRate=1.0 }
local global_options_choices = {}
local joined_focus_initialized = false

local join_lobby_code = ""

SL.Global.Online = SL.Global.Online or {}
SL.Global.Online.PackChoiceRecovery = SL.Global.Online.PackChoiceRecovery or {}
if type(SL.Global.Online.PackChoiceRecovery.candidates) == "table" then
	pack_choice_last_candidates = SL.Global.Online.PackChoiceRecovery.candidates
	pack_choice_last_song_info = SL.Global.Online.PackChoiceRecovery.songInfo
	pack_choice_last_selected_pack_id = SL.Global.Online.PackChoiceRecovery.selectedPackId
end

local joined_any_player_missing_song
local joined_all_players_ready
local last_start_visibility_debug_key = ""
local last_select_song_visibility_debug_key = ""
local last_auto_start_focus_key = ""

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

local function focus_selected_browse_list(root)
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

local function lobby_debug_enabled()
	if ITGOnline and ITGOnline.debugReadyFlow ~= nil then
		return ITGOnline.debugReadyFlow == true
	end
	return false
end

local function lobby_debug(message)
	if not lobby_debug_enabled() then return end
	local line = "ITG Online Lobby: " .. tostring(message or "")
	if Warn then Warn(line) elseif Trace then Trace(line) end
end

local function lobby_flow_trace(message)
	local line = "ITG Online: FLOW lobby_ui " .. tostring(message or "")
	if Trace then Trace(line) elseif Warn then Warn(line) end
end

local function ready_summary()
	local parts = {}
	for _, player in pairs(joined_lobby_players or {}) do
		if type(player) == "table" then
			parts[#parts + 1] = tostring(player.profileName or "?")
				.. ":" .. tostring(player.playerId or "?")
				.. "=" .. tostring(player.ready and "1" or "0")
		end
	end
	return table.concat(parts, ",")
end

local function normalize_global_options(options)
	options = type(options) == "table" and options or {}
	local scoreMode = tostring(options.scoreMode or options.score_mode or "itg"):lower()
	if scoreMode ~= "ex" and scoreMode ~= "hardex" then
		scoreMode = "itg"
	end
	local musicRate = tonumber(options.musicRate or options.music_rate) or 1.0
	musicRate = math.max(0.25, math.min(3.0, musicRate))
	return { scoreMode=scoreMode, score_mode=scoreMode, musicRate=musicRate, music_rate=musicRate }
end

local function global_score_label(mode)
	mode = tostring(mode or "itg"):lower()
	if mode == "hardex" then return "HardEX" end
	if mode == "ex" then return "EX" end
	return "ITG"
end

local function global_options_summary()
	local options = normalize_global_options(joined_global_options)
	return global_score_label(options.scoreMode) .. " / " .. string.format("%.2fx", options.musicRate)
end

local function global_options_button_label()
	return "Options globales\n(" .. global_options_summary() .. ")"
end

local function rebuild_global_options_choices()
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

local function select_current_global_score_choice()
	local current = normalize_global_options(joined_global_options)
	for i, choice in ipairs(global_options_choices) do
		if choice.scoreMode and choice.scoreMode == current.scoreMode then
			global_options_index = i
			return
		end
	end
	global_options_index = math.min(math.max(1, global_options_index), #global_options_choices)
end

local function open_global_options_menu()
	rebuild_global_options_choices()
	select_current_global_score_choice()
	showing_global_options_menu = true
	if t then
		local menu = t:GetChild("GlobalOptionsMenu")
		if menu then menu:visible(true) end
		t:queuecommand("UpdateGlobalOptionsMenu")
	end
end

local function close_global_options_menu()
	showing_global_options_menu = false
	if t then
		local menu = t:GetChild("GlobalOptionsMenu")
		if menu then menu:visible(false) end
	end
end

local function move_global_options_choice(delta)
	if #global_options_choices == 0 then rebuild_global_options_choices() end
	global_options_index = global_options_index + delta
	if global_options_index < 1 then global_options_index = #global_options_choices end
	if global_options_index > #global_options_choices then global_options_index = 1 end
	if t then t:queuecommand("UpdateGlobalOptionsMenu") end
end

local function apply_global_options_choice()
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

local function text_or_empty(value)
	return tostring(value or "")
end

local function trim_text(value)
	return text_or_empty(value):gsub("^%s+", ""):gsub("%s+$", "")
end

local function clamp_text(value, maxLen)
	value = text_or_empty(value)
	maxLen = math.max(1, tonumber(maxLen) or 1)
	if #value <= maxLen then return value end
	if maxLen <= 1 then return "…" end
	return value:sub(1, maxLen - 1) .. "…"
end

local function song_info_path(songInfo)
	return trim_text(songInfo and (songInfo.songPath or songInfo.folder_name or songInfo.folderName or songInfo.path))
end

local function song_info_pack(songInfo)
	local pack = trim_text(songInfo and (songInfo.pack or songInfo.group or songInfo.group_name or songInfo.groupName))
	if pack ~= "" then return pack end

	local path = song_info_path(songInfo)
	return trim_text(path:match("^([^/]+)"))
end

local function song_info_title(songInfo)
	local title = trim_text(songInfo and (songInfo.title or songInfo.name or songInfo.songName or songInfo.song_title or songInfo.songTitle))
	if title ~= "" then return title end

	local path = song_info_path(songInfo)
	return trim_text(path:match("^[^/]+/(.+)$") or path)
end

local function song_info_artist(songInfo)
	return trim_text(songInfo and (songInfo.artist or songInfo.artistName or songInfo.song_artist or songInfo.songArtist))
end

local function normalize_online_song_info(songInfo)
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

local function find_online_song(songInfo)
	if not SONGMAN or not SONGMAN.FindSong or type(songInfo) ~= "table" then return nil end
	local songPath = song_info_path(songInfo)
	local song = songPath ~= "" and SONGMAN:FindSong(songPath) or nil
	if song then return song end
	local relative = songPath:match("^[^/]+/(.+)$")
	return relative and SONGMAN:FindSong(relative) or nil
end

local function update_joined_song_card(joinedContent)
	if not joinedContent then return end
	local songInfo = normalize_online_song_info(joined_missing_song_info or joined_song_preview)
	local hasSong = type(songInfo) == "table"
	local card = joinedContent:GetChild("JoinedSongCard")
	if card then card:visible(hasSong) end

	local title = joinedContent:GetChild("JoinedSongTitle")
	if title then
		local titleText = hasSong and song_info_title(songInfo) or ""
		title:settext(hasSong and clamp_text(titleText ~= "" and titleText or "Chanson inconnue", 42) or "Aucune chanson selectionnee")
	end

	local artist = joinedContent:GetChild("JoinedSongArtist")
	if artist then
		local artistText = hasSong and song_info_artist(songInfo) or ""
		artist:settext("Artiste : " .. (artistText ~= "" and clamp_text(artistText, 44) or "Artiste inconnu"))
	end

	local pack = joinedContent:GetChild("JoinedSongPack")
	if pack then
		local packText = hasSong and song_info_pack(songInfo) or ""
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

local function abbreviate_stepchart(value)
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

local function pack_sync_display_text(status)
	status = trim_text(status)
	if status == "" or status == "unknown" then return "" end
	if ITGOnline and ITGOnline.PackSync and ITGOnline.PackSync.statusText then
		return ITGOnline.PackSync.statusText[status] or status
	end
	return status:gsub("_", " ")
end

local function pack_sync_busy()
	if not (ITGOnline and ITGOnline.PackSync and ITGOnline.PackSync.currentStatus) then return false end
	local status = trim_text(ITGOnline.PackSync.currentStatus)
	return status == "download_requested" or status == "download_in_progress" or status == "reloading_songs"
end

local function pack_sync_status_for_joined_song()
	if not (ITGOnline and ITGOnline.PackSync) then return "" end
	if not joined_song_confirmed or joined_song_selected_key == "" then return "" end

	local packSync = ITGOnline.PackSync
	local songInfo = packSync.currentSongInfo
	if type(songInfo) ~= "table" then return "" end

	local selectedAt = trim_text(songInfo.selectedAt or songInfo.selected_at)
	if selectedAt == "" or selectedAt ~= joined_song_selected_key then return "" end

	return trim_text(packSync.currentStatus)
end

local function pack_sync_confirms_joined_song()
	local status = pack_sync_status_for_joined_song()
	return status == "local_chart_match_found"
		or status == "ready"
		or status == "downloaded_ok"
end

local function pack_sync_is_checking_joined_song()
	local status = pack_sync_status_for_joined_song()
	return status == "searching_local_charts"
		or status == "local_chart_match_found"
		or status == "download_requested"
		or status == "download_in_progress"
		or status == "reloading_songs"
		or status == "downloaded_ok"
		or status == "ready"
end

local function can_download_pack_for_reason(reason)
	reason = trim_text(reason)
	return reason == "missing_local_song"
		or reason == "no_compatible_chart_found"
		or reason == "local_payload_unavailable"
		or reason == "song_hash_mismatch"
		or reason == "chart_hash_mismatch"
end

local function joined_missing_song_countdown_seconds()
	if not (ITGOnline and ITGOnline.currentRoom) then return nil end
	local roomTimeMs = nil
	if ITGOnline.serverClockOffsetSeconds then
		roomTimeMs = math.floor((GetTimeSinceStart() + tonumber(ITGOnline.serverClockOffsetSeconds)) * 1000)
	else
		roomTimeMs = tonumber(ITGOnline.currentRoom.server_time_ms)
	end
	if not roomTimeMs then return nil end
	local currentUserId = tostring(ITGOnline.user and ITGOnline.user.id or "")
	if currentUserId == "" then return nil end

	for _, player in ipairs(joined_lobby_players or {}) do
		if tostring(player.playerId or "") == currentUserId then
			local deadlineMs = tonumber(player.packSyncDownloadDeadlineMs)
			if deadlineMs and deadlineMs > roomTimeMs then
				return math.max(1, math.ceil((deadlineMs - roomTimeMs) / 1000))
			end
			return nil
		end
	end

	return nil
end

local function local_pack_exists(songInfo)
	local pack = trim_text(songInfo and songInfo.pack)
	return pack ~= "" and SONGMAN and SONGMAN.DoesSongGroupExist and SONGMAN:DoesSongGroupExist(pack)
end

local function normalized_online_phase(value)
	return tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", ""):lower()
end

local function joined_phase_allows_song_selection()
	local phase = normalized_online_phase(joined_phase)
	if phase == "" and ITGOnline and ITGOnline.currentRoom then
		phase = normalized_online_phase(ITGOnline.currentRoom.phase)
	end
	return phase == "lobby"
		or phase == "lobby_ready"
		or phase == "config"
		or phase == "results"
end

local function joined_phase_allows_start()
	return joined_phase == "config" or joined_phase == "lobby_ready"
end

local function joined_room_can_start()
	return joined_is_manager
		and joined_song_confirmed
		and joined_phase_allows_start()
		and joined_all_players_ready()
		and not joined_any_player_missing_song()
end

local function joined_button_indices()
	local indices = {1}
	if joined_is_manager and joined_phase_allows_song_selection() then
		indices[#indices + 1] = 2
	end
	if joined_is_manager and joined_phase_allows_song_selection() then
		indices[#indices + 1] = 4
	end
	if joined_missing_song then
		indices[#indices + 1] = 3
	end
	if joined_room_can_start() then
		indices[#indices + 1] = 5
	end
	return indices
end

function joined_all_players_ready()
	-- Legacy helper kept for debug text compatibility; gameplay start no longer depends on ready flags.
	if #joined_lobby_players == 0 then return false end
	for player in ivalues(joined_lobby_players) do
		if not player.ready then
			return false
		end
	end
	return true
end

local function joined_manager_profile_name()
	if joined_manager_user_id == nil then return nil end
	local managerId = tostring(joined_manager_user_id)
	for _, player in ipairs(joined_lobby_players or {}) do
		if tostring(player.playerId or "") == managerId then
			return trim_text(player.profileName or player.name or player.playerId)
		end
	end
	return nil
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

local function player_missing_song_for_ui(player)
	if joined_phase == "results" then return false end
	if player_is_current_user(player) and pack_sync_is_checking_joined_song() then
		return false
	end
	return player and player.missingSong == true or false
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
			return
		end
	end
	joined_active_index = indices[1] or 1
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
				return
			end
		end
	end
	joined_active_index = indices[1] or 1
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

local function selected_online_user()
	if #online_users == 0 then return nil end
	online_player_index = math.max(1, math.min(online_player_index, #online_users))
	return online_users[online_player_index]
end

local function build_player_action_options(user)
	if not user then return {} end
	if user.isSelf then
		return {{label="C'est vous", action="cancel"}, {label="Annuler", action="cancel"}}
	end
	if user.room and user.room.visibility == "public" then
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

	local function clear_pending_join()
		pending_join_action_id = 0
		pending_join_deadline = 0
	end

local function begin_join_timeout(actor, seconds)
	seconds = tonumber(seconds) or 20
	pending_join_action_id = pending_join_action_id + 1
	pending_join_deadline = GetTimeSinceStart() + seconds
	local timer = actor and actor:GetChild("JoinTimeoutTimer")
	if timer then
		timer:stoptweening()
		timer:sleep(seconds):queuecommand("CheckJoinTimeout")
	end
end

	local function cancel_pending_join(message)
		local onlineHandler = GetOnlineHandlerInstance()
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

	if option.action == "invite_private" then
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

local function close_pack_choice_menu()
	showing_pack_choice_menu = false
	pack_choice_index = 1
	pack_choice_candidates = {}
	pack_choice_song_info = nil
	pack_choice_message = nil
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

local function open_pack_choice_menu(songInfo, candidates, message)
	if type(candidates) ~= "table" or #candidates == 0 then return false end
	showing_player_action_menu = false
	if t then
		local playerMenu = t:GetChild("PlayerActionMenu")
		if playerMenu then playerMenu:visible(false) end
	end
	pack_choice_song_info = songInfo
	pack_choice_candidates = candidates
	pack_choice_last_song_info = songInfo
	pack_choice_last_candidates = candidates
	SL.Global.Online.PackChoiceRecovery = {
		songInfo = songInfo,
		candidates = candidates,
		selectedPackId = pack_choice_last_selected_pack_id,
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

local InputHandler = function(event)
  if not event.PlayerNumber or not event.button then return false end
	if not t then return false end

  if event.type == "InputEventType_FirstPress" then
		if showing_leave_confirm then
			if event.GameButton == "MenuRight" or event.GameButton == "MenuLeft" then
				leave_confirm_index = (leave_confirm_index + (event.GameButton=="MenuRight" and 1 or -1)) % 2
				SOUND:PlayOnce(THEME:GetPathS("ScreenSelectMaster", "change"))
				t:GetChild("LeaveConfirmPrompt"):playcommand("Hover")
			elseif event.GameButton == "Start" then
				if leave_confirm_index == 1 then
					SOUND:PlayOnce(THEME:GetPathS("Common", "Start"))
					showing_leave_confirm = false
					t:GetChild("LeaveConfirmPrompt"):visible(false)
					leaving_lobby = true
					-- Immediate local UX transition: avoid mixed joined/browse visuals
					-- while waiting for async leave-lobby response.
					mode = "browse"
					t:GetChild("JoinedLobbyContent"):visible(false)
					t:queuecommand("UpdateLobbyView")
					t:playcommand("SetStatus", {
							text="Sortie du salon...",
						showSpinner=true,
						showPrompt=false
					})
					MESSAGEMAN:Broadcast("LeaveLobby")
				else
					SOUND:PlayOnce(THEME:GetPathS("Common", "Cancel"))
					showing_leave_confirm = false
					t:GetChild("LeaveConfirmPrompt"):visible(false)
				end
			elseif event.GameButton == "Select" or event.GameButton == "Back" then
				SOUND:PlayOnce(THEME:GetPathS("Common", "Cancel"))
				showing_leave_confirm = false
				t:GetChild("LeaveConfirmPrompt"):visible(false)
			end
			return false
		end

		if showing_private_join_prompt then
			local promptOptions = active_private_prompt_options()
			if event.GameButton == "MenuRight" or event.GameButton == "MenuLeft" then
				private_join_prompt_index = ((private_join_prompt_index - 1 + (event.GameButton=="MenuRight" and 1 or -1)) % #promptOptions) + 1
				SOUND:PlayOnce(THEME:GetPathS("ScreenSelectMaster", "change"))
				t:queuecommand("UpdatePrivateJoinPrompt")
			elseif event.GameButton == "Start" then
				local option = promptOptions[private_join_prompt_index]
				if private_join_prompt_kind == "invitation" then
					local invitation = private_join_request and private_join_request.invitation
					if option and option.dismiss then
						showing_private_join_prompt = false
						t:GetChild("PrivateJoinPrompt"):visible(false)
						SOUND:PlayOnce(THEME:GetPathS("Common", "Cancel"))
					elseif option and invitation and invitation.id then
						showing_private_join_prompt = false
						t:GetChild("PrivateJoinPrompt"):visible(false)
						MESSAGEMAN:Broadcast("AnswerRoomInvitation", {
							invitation_id=invitation.id,
							accept=option.accept,
						})
						SOUND:PlayOnce(THEME:GetPathS("Common", "Start"))
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
					SOUND:PlayOnce(THEME:GetPathS("Common", "Start"))
				end
				end
			elseif event.GameButton == "Select" or event.GameButton == "Back" then
				showing_private_join_prompt = false
				t:GetChild("PrivateJoinPrompt"):visible(false)
				SOUND:PlayOnce(THEME:GetPathS("Common", "Cancel"))
			end
			return false
		end

			if showing_player_action_menu then
			if event.GameButton == "MenuRight" or event.GameButton == "MenuLeft" then
				player_action_index = ((player_action_index - 1 + (event.GameButton=="MenuRight" and 1 or -1)) % #player_action_options) + 1
				SOUND:PlayOnce(THEME:GetPathS("ScreenSelectMaster", "change"))
				t:queuecommand("UpdatePlayerActionMenu")
			elseif event.GameButton == "Start" then
				SOUND:PlayOnce(THEME:GetPathS("Common", "Start"))
				execute_player_action(player_action_options[player_action_index], player_action_user)
			elseif event.GameButton == "Select" or event.GameButton == "Back" then
				showing_player_action_menu = false
				t:GetChild("PlayerActionMenu"):visible(false)
				SOUND:PlayOnce(THEME:GetPathS("Common", "Cancel"))
			end
			return false
		end

			if has_error and event.GameButton == "Start" then
				local topScreen = SCREENMAN:GetTopScreen()
				if topScreen then
					topScreen:SetNextScreenName("ScreenTitleMenu")
					topScreen:StartTransitioningScreen("SM_GoToNextScreen")
				end
				return false
			end

			if showing_pack_choice_menu then
				if event.GameButton == "MenuRight" or event.GameButton == "MenuLeft" then
					pack_choice_index = ((pack_choice_index - 1 + (event.GameButton=="MenuRight" and 1 or -1)) % #pack_choice_candidates) + 1
					SOUND:PlayOnce(THEME:GetPathS("ScreenSelectMaster", "change"))
					update_pack_choice_menu()
				elseif event.GameButton == "Start" then
					local candidate = pack_choice_candidates[pack_choice_index]
					if candidate and ITGOnline and ITGOnline.PackSync and ITGOnline.PackSync.DownloadPackByCandidate then
						SOUND:PlayOnce(THEME:GetPathS("Common", "Start"))
						pack_choice_last_selected_pack_id = tonumber(candidate.id)
						if SL and SL.Global and SL.Global.Online then
							SL.Global.Online.PackChoiceRecovery = {
								songInfo = pack_choice_last_song_info or pack_choice_song_info,
								candidates = pack_choice_last_candidates,
								selectedPackId = pack_choice_last_selected_pack_id,
							}
						end
						close_pack_choice_menu()
						t:playcommand("SetStatus", {
								text="Demarrage du telechargement du pack...",
							showSpinner=true,
							showPrompt=false
						})
						ITGOnline.PackSync:DownloadPackByCandidate(pack_choice_song_info or joined_missing_song_info or joined_song_preview, candidate, function(ok, message)
							if ok and t then
								t:playcommand("SetStatus", {
										text="Telechargement termine. Extraction et rechargement des chansons...",
									showSpinner=true,
									showPrompt=false
								})
	elseif not ok and t then
								t:playcommand("SetStatus", {
									text=message or "Le téléchargement du pack a échoué.\nVeuillez réessayer ou installer le pack manuellement.",
									showSpinner=false,
									showPrompt=true
								})
							end
						end)
					end
				elseif event.GameButton == "Select" or event.GameButton == "Back" then
					SOUND:PlayOnce(THEME:GetPathS("Common", "Cancel"))
					close_pack_choice_menu()
				end
				return false
			end

		if not connected then
			return false
		end

		if pending_join_action_id > 0 and (event.GameButton == "Select" or event.GameButton == "Back") then
			SOUND:PlayOnce(THEME:GetPathS("Common", "Cancel"))
				cancel_pending_join("Connexion annulee. Rafraichissement des salons...")
			return false
		end

		if showing_global_options_menu then
			if event.GameButton == "MenuRight" or event.GameButton == "MenuLeft" then
				move_global_options_choice(event.GameButton == "MenuRight" and 1 or -1)
				SOUND:PlayOnce(THEME:GetPathS("ScreenSelectMaster", "change"))
			elseif event.GameButton == "Start" then
				SOUND:PlayOnce(THEME:GetPathS("Common", "Start"))
				apply_global_options_choice()
			elseif event.GameButton == "Select" or event.GameButton == "Back" then
				SOUND:PlayOnce(THEME:GetPathS("Common", "Cancel"))
				close_global_options_menu()
			end
			return false
		end

			if mode == "joined" then
				if leaving_lobby then
					return false
				end

				if event.GameButton == "MenuRight" or event.GameButton == "MenuLeft" then
					move_joined_button(event.GameButton == "MenuRight" and 1 or -1)
					SOUND:PlayOnce(THEME:GetPathS("ScreenSelectMaster", "change"))
					t:queuecommand("Hover")
				elseif event.GameButton == "Start" then
					normalize_joined_active_index()
					SOUND:PlayOnce(THEME:GetPathS("Common", "Start"))
					if joined_active_index == 1 then
						leave_confirm_index = 0
						showing_leave_confirm = true
						t:GetChild("LeaveConfirmPrompt"):visible(true)
						t:GetChild("LeaveConfirmPrompt"):playcommand("Hover")
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
							topScreen:SetNextScreenName("ScreenSelectMusic")
							topScreen:StartTransitioningScreen("SM_GoToNextScreen")
						end
					elseif joined_active_index == 3 and joined_missing_song then
						if joined_can_download_pack and ITGOnline and ITGOnline.PackSync and ITGOnline.PackSync.DownloadSelectedPack then
							ITGOnline.PackSync:DownloadSelectedPack(joined_missing_song_info or joined_song_preview, function(ok, message)
								if not ok and type(message) == "table" and message.kind == "pack_candidates" then
									open_pack_choice_menu(
										joined_missing_song_info or joined_song_preview,
										message.candidates,
										message.message or "Plusieurs packs correspondent. Choisissez-en un."
									)
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
					elseif joined_active_index == 5 and joined_is_manager then
						if joined_room_can_start() then
							MESSAGEMAN:Broadcast("StartOnlineRoom")
						else
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

		if event.GameButton == "MenuRight" or event.GameButton == "MenuLeft" then
			holding[event.GameButton] = true
			if holding[event.GameButton == "MenuRight" and "MenuLeft" or "MenuRight"] then
				-- Same as Select below.
				if list_selected then
					list_selected = false
					SOUND:PlayOnce(THEME:GetPathS("Common", "Cancel"))
					t:queuecommand("LoseFocus")
					t:queuecommand("Hover")
				end
			else
				if not list_selected then
					active_index = (active_index + (event.GameButton=="MenuRight" and 1 or -1)) % #options
					SOUND:PlayOnce(THEME:GetPathS("ScreenSelectMaster", "change"))
					t:queuecommand("Hover")
				else
					if lobby_view == "players" then
						if #online_users > 0 then
							online_player_index = ((online_player_index - 1 + (event.GameButton=="MenuRight" and 1 or -1)) % #online_users) + 1
							SOUND:PlayOnce(THEME:GetPathS("ScreenSelectMaster", "change"))
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
						SOUND:PlayOnce(THEME:GetPathS("Common", "Start"))
						t:queuecommand("OpenPlayerActionMenu")
					else
						SOUND:PlayOnce(THEME:GetPathS("Common", "Cancel"))
					end
				else
					local lobbyList = t:GetChild("LobbyContent") and t:GetChild("LobbyContent"):GetChild("LobbyList")
					if lobbyList then
						SOUND:PlayOnce(THEME:GetPathS("Common", "Start"))
						lobbyList:playcommand("SelectLobby")
					else
						SOUND:PlayOnce(THEME:GetPathS("Common", "Cancel"))
					end
				end
				return false
			end

			if active_index == 0 or active_index == 1 then
				lobby_view = active_index == 1 and "players" or "lobbies"
				if (lobby_view == "lobbies" and #candidates > 0) or (lobby_view == "players" and #online_users > 0) then
					list_selected = true
					SOUND:PlayOnce(THEME:GetPathS("Common", "Start"))
					focus_selected_browse_list(t)
					t:queuecommand("UpdateOnlinePlayers")
				else
					SOUND:PlayOnce(THEME:GetPathS("Common", "Cancel"))
				end
			elseif active_index == 2 then
				SOUND:PlayOnce(THEME:GetPathS("Common", "Start"))

				local onlineHandler = GetOnlineHandlerInstance()
				if onlineHandler and onlineHandler.connected then
					t:playcommand("SetStatus", {
							text="Recherche des salons...",
						showSpinner=true,
						showPrompt=false
					})
					MESSAGEMAN:Broadcast("SearchLobby")
				else
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
					SOUND:PlayOnce(THEME:GetPathS("Common", "Start"))
					local topScreen = SCREENMAN:GetTopScreen()
					if topScreen then
						topScreen:SetNextScreenName("ScreenTitleMenu")
						topScreen:StartTransitioningScreen("SM_GoToNextScreen")
					end
				elseif active_index == 3 then
				SOUND:PlayOnce(THEME:GetPathS("Common", "Start"))
				t:GetChild("LobbyContent"):visible(false)
				t:GetChild("OnlinePlayersContent"):visible(false)
				t:playcommand("SetStatus", {
						text="Creation du salon...",
					showSpinner=true,
					showPrompt=false
				})
				MESSAGEMAN:Broadcast("CreateLobby", {})
			end
		elseif event.GameButton == "Select" or event.GameButton == "Back" then
			if list_selected then
				list_selected = false
				SOUND:PlayOnce(THEME:GetPathS("Common", "Cancel"))
				t:queuecommand("LoseFocus")
				t:queuecommand("Hover")
			end
		end
	elseif event.type == "InputEventType_Release" then
		if event.GameButton == "MenuRight" or event.GameButton == "MenuLeft" then
			holding[event.GameButton] = false
		end
	end
end

local wait_time = 0
local attempted = false
local input_screen = nil
local af = Def.ActorFrame{
	  OnCommand=function(self)
			t=self
			input_added = false
			holding.MenuLeft = false
			holding.MenuRight = false
	    self:Center()
			local screen = SCREENMAN:GetTopScreen()
			if not input_added and screen then
				screen:AddInputCallback(InputHandler)
				input_screen = screen
			input_added = true
		end
			self:playcommand("SetStatus", {
					text="Initialisation de la connexion en ligne...",
				showSpinner=true
			})
		self:queuecommand("CheckConnect")
  end,
	OffCommand=function(self)
			if input_added and input_screen and input_screen.RemoveInputCallback then
				pcall(function() input_screen:RemoveInputCallback(InputHandler) end)
			end
			input_screen = nil
			input_added = false
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
			if pending_join_action_id > 0 and GetTimeSinceStart() >= pending_join_deadline then
					cancel_pending_join("La tentative de rejoindre le salon a expire. Rafraichissement...")
			end
		end
	},
	HoverCommand=function(self)
		self:GetChild("LobbyContent"):playcommand("Hover")
		self:GetChild("OnlinePlayersContent"):playcommand("Hover")
		self:GetChild("JoinedLobbyContent"):playcommand("Hover")
	end,
	UpdateOnlinePlayersCommand=function(self)
		local playersContent = self:GetChild("OnlinePlayersContent")
		if not playersContent then return end

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
			local line = clamp_text(selected .. i .. ". " .. tostring(user.name or "Joueur") .. status .. room, 44)
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
	end,
	UpdateLobbyViewCommand=function(self)
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
				title:settext(player_action_user and tostring(player_action_user.name or "Joueur") or "Joueur")
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
			sync_local_missing_song_from_joined_players()
			local joinedContent = self:GetChild("JoinedLobbyContent")
			if not joinedContent then return end
			local codeValue = joinedContent:GetChild("JoinedLobbyCodeValue")
		if codeValue then
				codeValue:settext(joined_lobby_code ~= "" and joined_lobby_code or "(en attente)")
		end

			local lines = {}
			for i, player in ipairs(joined_lobby_players) do
					local profile = trim_text(player.profileName or player.name or player.playerId or ("Joueur "..i))
				local ready = player.ready and " ✔" or ""
					local missing = player_missing_song_for_ui(player) and " ⚠ chanson manquante" or ""
					local packSyncStatus = trim_text(player.packSyncStatus)
					local packSyncText = pack_sync_display_text(packSyncStatus)
					if packSyncText ~= "" and packSyncStatus ~= "" and packSyncStatus ~= "unknown" and packSyncStatus ~= "ready" then
						local progress = tonumber(player.packSyncDownloadProgress)
						if progress and packSyncStatus == "download_in_progress" then
							packSyncText = packSyncText .. " " .. tostring(progress) .. "%"
						end
					missing = missing .. " · " .. packSyncText
				end
				local optionParts = {}
				local speedMod = trim_text(player.speedMod)
				if speedMod ~= "" then optionParts[#optionParts+1] = speedMod end
				local stepchart = abbreviate_stepchart(player.stepchart)
				if stepchart ~= "" then optionParts[#optionParts+1] = stepchart end
					if missing == "" and joined_song_preview ~= nil and player.songAvailable == false and not player_is_current_user(player) then
						missing = " … confirmation chanson"
				end
				local maxLineLen = 88
				local lineHead = i..". "..profile
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
				lines[#lines+1] = clamp_text(lineHead..options..lineTail, maxLineLen)
			end

			local playersText = joinedContent:GetChild("JoinedLobbyPlayers")
		if playersText then
				playersText:settext(#lines > 0 and table.concat(lines, "\n") or "En attente des joueurs...")
		end
			update_joined_song_card(joinedContent)

			local songStatus = joinedContent and joinedContent:GetChild("JoinedLobbySongStatus")
			if songStatus then
				local statusLines = {}
				local managerName = joined_manager_profile_name()
				local managerLabel = managerName and (managerName .. " (" .. tostring(joined_manager_user_id or "?") .. ")")
					or tostring(joined_manager_user_id or "unknown")
					statusLines[#statusLines + 1] = "Manager : " .. managerLabel

				local missingSongInfo = joined_missing_song_info or joined_song_preview
				if joined_missing_song and missingSongInfo then
					if joined_missing_song_reason == "song_hash_mismatch" then
						statusLines[#statusLines + 1] = "La stepchart existe localement, mais l'audio est différent de celui du manager."
						statusLines[#statusLines + 1] = "Le mode online exige la même musique et la même stepchart."
					elseif joined_missing_song_reason == "chart_mismatch" or joined_missing_song_reason == "hash_mismatch" then
						statusLines[#statusLines + 1] = "La musique ou la stepchart trouvée est différente de celle du manager."
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
						statusLines[#statusLines + 1] = "Vous pouvez télécharger le pack utilisé par le manager."
					elseif joined_can_download_pack then
						statusLines[#statusLines + 1] = "Cette chanson existe peut-être dans vos packs,"
						statusLines[#statusLines + 1] = "mais aucune stepchart identique à celle du manager n’a été trouvée."
						statusLines[#statusLines + 1] = "Vous pouvez télécharger le pack utilisé par le manager."
					else
							statusLines[#statusLines + 1] = "Pack de chansons manquant ou different localement"
					end
					local countdownSeconds = joined_missing_song_countdown_seconds()
					if countdownSeconds and joined_can_download_pack and not pack_sync_busy() then
						statusLines[#statusLines + 1] = "Cliquez sur \"Telecharger pack\" dans " .. tostring(countdownSeconds) .. " s."
					end
					elseif joined_song_preview then
						statusLines[#statusLines + 1] = (joined_song_confirmed and "✔ Chanson selectionnee" or "Choix de chanson en cours")
					if joined_preview_unknown_pack and not joined_song_confirmed then
						statusLines[#statusLines + 1] = "Le manager navigue dans un pack que vous ne possédez pas."
					end
						if joined_phase == "playing" then
							statusLines[#statusLines + 1] = "Manche en cours. En attente de la fin pour tous."
						elseif joined_phase == "results" then
							statusLines[#statusLines + 1] = joined_is_manager and "Resultats prets. Choisissez la prochaine chanson."
								or "Resultats prets. En attente du choix du manager."
						elseif joined_phase == "starting" then
							local seconds = ITGOnline and ITGOnline.SecondsUntilScheduledStart and ITGOnline:SecondsUntilScheduledStart() or nil
							statusLines[#statusLines + 1] = seconds and ("Demarrage dans " .. tostring(math.ceil(math.max(0, seconds))) .. "...") or "Demarrage..."
						elseif joined_phase == "config" or joined_phase == "lobby_ready" then
							if joined_any_player_missing_song() then
								statusLines[#statusLines + 1] = "En attente de confirmation de la chanson par tous les joueurs."
							else
								statusLines[#statusLines + 1] = joined_is_manager and "Chanson confirmee. Appuyez sur START."
									or "Chanson confirmee. En attente du lancement par le manager."
							end
						end
				elseif joined_is_manager then
					statusLines[#statusLines + 1] = "Choisissez une chanson pour lancer la manche."
				else
						statusLines[#statusLines + 1] = "En attente du choix de chanson par le createur du salon."
				end
				songStatus:settext(table.concat(statusLines, "\n"))
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
				reloadSongsButton:visible(joined_missing_song)
				local label = reloadSongsButton:GetChild("ReloadSongsLabel")
				if label then
						label:settext(joined_can_download_pack and "Telecharger pack" or "Recharger chansons")
				end
			end

			local globalOptionsButton = joinedContent and joinedContent:GetChild("GlobalOptionsButton")
			if globalOptionsButton then
				local visible = joined_is_manager and joined_phase_allows_song_selection()
				globalOptionsButton:visible(visible)
				local label = globalOptionsButton:GetChild("GlobalOptionsLabel")
				if label then
					label:settext(global_options_button_label())
				end
			end

			local startRoomButton = joinedContent and joinedContent:GetChild("StartRoomButton")
			if startRoomButton then
					local canStartInPhase = joined_phase_allows_start()
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
						local autoFocusKey = table.concat({
							tostring(joined_lobby_code or ""),
							tostring(joined_phase or ""),
							tostring(joined_song_selected_key or ""),
							ready_summary(),
							hasMissingSong and "1" or "0",
						}, "|")
						if autoFocusKey ~= last_auto_start_focus_key then
							last_auto_start_focus_key = autoFocusKey
							if joined_active_index ~= 5 then
								joined_active_index = 5
								self:queuecommand("Hover")
							end
						end
					else
						last_auto_start_focus_key = ""
					end
				end
			end,
		SetStatusCommand=function(self, params)
			if showing_pack_choice_menu then
				return
			end
			self:GetChild("NetworkStatus"):visible(true)
			self:GetChild("NetworkStatus"):playcommand("Set", params)
		end,
		CheckConnectCommand=function(self)
			local onlineHandler = GetOnlineHandlerInstance()
		if onlineHandler then
			-- If no connection exists, first (re)establish the connection.
			-- Only try once per screen load to avoid infinite loops of trying to connect.
			if not attempted and (not onlineHandler.socket or onlineHandler.errorMsg ~= nil) then
				self:playcommand("SetStatus", {
						text="Connexion au service en ligne...",
					showSpinner=true
				})
				MESSAGEMAN:Broadcast("ConnectOnline")
				attempted = true
			end

			if not onlineHandler.connected and onlineHandler.errorMsg == nil then
				wait_time = wait_time + 1
				self:playcommand("SetStatus", {
						text="Connexion au service en ligne... ("..wait_time.."s)",
					showSpinner=true
				})
				self:sleep(1):queuecommand("CheckConnect")
			else
				self:queuecommand("Display")
			end
		else
			self:playcommand("SetStatus", {
					text="Initialisation du gestionnaire en ligne...",
				showSpinner=true
			})
			self:sleep(0.25):queuecommand("CheckConnect")
		end
	end,
	DisplayCommand=function(self)
		local onlineHandler = GetOnlineHandlerInstance()
		if onlineHandler then
			if onlineHandler.connected then
				connected = true
				has_error = false
					self:playcommand("SetStatus", {
							text="Connecte au service en ligne.",
						showSpinner=false,
						showPrompt=false
					})
					self:GetChild("NetworkStatus"):visible(false)
							if ITGOnline and ITGOnline.Sync then
								self:playcommand("SetStatus", {
										text="Synchronisation de l'etat en ligne...",
									showSpinner=true,
									showPrompt=false
								})
								ITGOnline:Sync(function(ok, decoded)
									if ok and decoded and decoded.current_room then
										MESSAGEMAN:Broadcast("OnlineLobbyState", ITGOnline:LobbyStatePayload(decoded.current_room))
									else
										MESSAGEMAN:Broadcast("SearchLobby")
									end
								end)
							elseif ITGOnline and ITGOnline.currentRoomId then
								self:playcommand("SetStatus", {
										text="Restauration du salon actuel...",
									showSpinner=true,
									showPrompt=false
								})
								ITGOnline:FetchRoom(ITGOnline.currentRoomId, function(ok, decoded)
									if ok and decoded and decoded.room then
										MESSAGEMAN:Broadcast("OnlineLobbyState", ITGOnline:LobbyStatePayload(decoded.room))
									else
										MESSAGEMAN:Broadcast("SearchLobby")
									end
								end)
						elseif ITGOnline and ITGOnline.FetchCurrentRoom then
							self:playcommand("SetStatus", {
									text="Restauration du salon actuel...",
								showSpinner=true,
								showPrompt=false
							})
							ITGOnline:FetchCurrentRoom(function(ok, decoded)
								if ok and decoded and decoded.room then
									MESSAGEMAN:Broadcast("OnlineLobbyState", ITGOnline:LobbyStatePayload(decoded.room))
								else
									MESSAGEMAN:Broadcast("SearchLobby")
								end
							end)
						else
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
	LobbySearchedMessageCommand=function(self, params)
		candidates = params and params.lobbies or {}
		online_users = params and params.onlinePlayers or {}

		local lobbyContent = self:GetChild("LobbyContent")
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
			self:GetChild("NetworkStatus"):visible(false)
		end
		self:queuecommand("UpdateLobbyView")
		self:GetChild("JoinedLobbyContent"):visible(mode == "joined")
		self:queuecommand("Hover")
	end,
		OnlineLobbyStateMessageCommand=function(self, params)
			local previousLobbyCode = joined_lobby_code
			clear_pending_join()
			mode = "joined"
		leaving_lobby = false
		showing_leave_confirm = false
		list_selected = false
		join_lobby_code = ""
			joined_lobby_code = params and params.code or ""
			if joined_lobby_code ~= previousLobbyCode then
				joined_focus_initialized = false
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

			self:queuecommand("UpdateJoinedLobbyText")

		if not pack_sync_busy() then
			self:GetChild("NetworkStatus"):visible(false)
		end
			self:GetChild("LobbyContent"):visible(false)
				self:GetChild("OnlinePlayersContent"):visible(false)
				self:GetChild("JoinedLobbyContent"):visible(true)
				normalize_joined_active_index()
				self:queuecommand("Hover")
			end,
		OnlineMissingSongMessageCommand=function(self, params)
				joined_missing_song = true
				joined_missing_song_info = params and params.songInfo or joined_song_preview
				joined_missing_song_reason = params and params.reason or "missing_local_song"
				joined_can_download_pack = params and (
					params.noCompatibleChart == true
					or can_download_pack_for_reason(params.reason)
				) or false
				if ITGOnline and ITGOnline.ReportSongAvailability then
					ITGOnline:ReportSongAvailability(true, params and params.reason or "missing_local_song")
				end
			if params and params.songInfo then
					joined_song_preview = params.songInfo
					joined_song_confirmed = true
			end
			local reason = params and params.reason or "missing_local_song"
			if reason == "download_failed" then
				if (#pack_choice_last_candidates == 0) and SL and SL.Global and SL.Global.Online and type(SL.Global.Online.PackChoiceRecovery.candidates) == "table" then
					pack_choice_last_candidates = SL.Global.Online.PackChoiceRecovery.candidates
					pack_choice_last_song_info = SL.Global.Online.PackChoiceRecovery.songInfo
					pack_choice_last_selected_pack_id = SL.Global.Online.PackChoiceRecovery.selectedPackId
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
						reopened = open_pack_choice_menu(
							pack_choice_last_song_info or joined_missing_song_info or joined_song_preview,
							alternatives,
							"Le pack choisi n'a pas fourni la chart attendue. Choisissez un autre pack."
						)
					end
				end
				if not reopened then
					pack_choice_all_candidates_exhausted = true
					self:playcommand("SetStatus", {
						text="Aucun des packs testés ne contient la chart attendue.\nInstallation manuelle requise pour cette chanson.",
						showSpinner=false,
						showPrompt=true
					})
				end
			end
					set_joined_default_active_index()
				self:queuecommand("UpdateJoinedLobbyText")
				self:queuecommand("Hover")
			end,
			OnlineSongAvailableMessageCommand=function(self)
				local wasMissing = joined_missing_song
				joined_missing_song = false
				joined_missing_song_info = nil
				joined_can_download_pack = false
				joined_missing_song_reason = nil
				if wasMissing and ITGOnline and ITGOnline.ReportSongAvailability then
					ITGOnline:ReportSongAvailability(false, "reloaded")
				end
				normalize_joined_active_index()
			self:queuecommand("UpdateJoinedLobbyText")
			self:queuecommand("Hover")
		end,
	OnlineLobbyJoinSelectedMessageCommand=function(self, params)
		if not params or not params.code then
			SOUND:PlayOnce(THEME:GetPathS("Common", "Cancel"))
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
			MESSAGEMAN:Broadcast("JoinLobby", {
				code=params.code,
			})
		end,
		OnlineLobbyLeftMessageCommand=function(self, params)
			if params == nil or params.left == nil or params.left then
				clear_pending_join()
				leaving_lobby = false
				showing_leave_confirm = false
			if ITGOnline and ITGOnline.PackSync and ITGOnline.PackSync.ResetLocalState then
				ITGOnline.PackSync:ResetLocalState("lobby_left")
			end
			mode = "browse"
			joined_lobby_code = ""
			joined_lobby_players = {}
			self:GetChild("JoinedLobbyContent"):visible(false)
			self:queuecommand("UpdateLobbyView")
			self:GetChild("NetworkStatus"):visible(false)
			self:playcommand("SetStatus", {
					text="Salon quitte.",
				showSpinner=false,
				showPrompt=false
			})
			self:queuecommand("Hover")
		end
	end,
	OnlinePrivateJoinRequestMessageCommand=function(self, params)
		if not params or not params.join_request then return end
		private_join_request = params
		private_join_prompt_kind = "join_request"
		private_join_prompt_index = 1
		showing_private_join_prompt = true
		local prompt = self:GetChild("PrivateJoinPrompt")
		if prompt then prompt:visible(true) end
		self:queuecommand("UpdatePrivateJoinPrompt")
	end,
	OnlineRoomInvitationMessageCommand=function(self, params)
		if not params or not params.invitation then return end
		private_join_request = params
		private_join_prompt_kind = "invitation"
		private_join_prompt_index = 1
		showing_private_join_prompt = true
		local prompt = self:GetChild("PrivateJoinPrompt")
		if prompt then prompt:visible(true) end
		self:queuecommand("UpdatePrivateJoinPrompt")
	end,
	OnlineSongPreviewMessageCommand=function(self, params)
		local preview = normalize_online_song_info(params)
		if preview then
			joined_song_preview = preview
			joined_song_confirmed = false
			joined_song_selected_key = ""
			joined_preview_unknown_pack = not local_pack_exists(preview)
			if joined_preview_unknown_pack and ITGOnline and ITGOnline.PackSync and ITGOnline.PackSync.ManagerBrowsingPreview then
				ITGOnline.PackSync:ManagerBrowsingPreview(preview)
			end
			self:queuecommand("UpdateJoinedLobbyText")
		end
	end,
	OnlinePackSyncReloadSongsMessageCommand=function(self)
		transition_to_online_song_reload()
	end,
	OnlineResponseStatusMessageCommand=function(self, params)
		if params and params.event == "createLobby" and params.success == false then
			mode = "browse"
			self:GetChild("JoinedLobbyContent"):visible(false)
			self:queuecommand("UpdateLobbyView")
			self:playcommand("SetStatus", {
					text=params.message and ("Echec de creation du salon :\n"..params.message) or "Echec de creation du salon.",
				showSpinner=false,
				showPrompt=false
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
				showPrompt=false
			})
		elseif params and params.event == "leaveLobby" and params.success == false then
			leaving_lobby = false
			showing_leave_confirm = false
			-- Leave failed: restore joined view coherently.
			mode = "joined"
			self:GetChild("JoinedLobbyContent"):visible(true)
			self:GetChild("LobbyContent"):visible(false)
			self:GetChild("OnlinePlayersContent"):visible(false)
			self:queuecommand("UpdateJoinedLobbyText")
			self:playcommand("SetStatus", {
					text=params.message and ("Echec de sortie du salon :\n"..params.message) or "Echec de sortie du salon.",
				showSpinner=false,
				showPrompt=false
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
					showPrompt=false
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
		end
	end,

	Def.ActorFrame{
		Name="LobbyContent",
		InitCommand=function(self)
			self:visible(false)
		end,
  
		LoadFont("Common Normal")..{
				Text="&MENULEFT;/&MENURIGHT; pour choisir | &START; pour valider | &SELECT; ou &MENULEFT;+&MENURIGHT; pour revenir",
			InitCommand=function(self)
				self:y(185):zoom(0.72)
			end
		},

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

		LoadFont("Common Normal")..{
				Text="&MENULEFT;/&MENURIGHT; pour choisir | &START; pour valider",
			InitCommand=function(self)
				self:visible(false)
			end
		},

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
				self:xy(180, -116):zoomto(210, 86):diffuse(0,0,0,0.82):visible(false)
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
			Text="Aucune chanson selectionnee",
			InitCommand=function(self)
				self:horizalign(left):xy(160, -119):zoom(WideScale(0.30, 0.32)):maxwidth(405)
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
						self:diffuse(joined_active_index == self:GetParent().idx and Color.Yellow or Color.White)
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
						self:diffuse(joined_active_index == self:GetParent().idx and GetHexColor(SL.Global.ActiveColorIndex) or Color.White)
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
						self:zoom(WideScale(0.25, 0.27)):vertspacing(-34):maxwidth(640)
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
