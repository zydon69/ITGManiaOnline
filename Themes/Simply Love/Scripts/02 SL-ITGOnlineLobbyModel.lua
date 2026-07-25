ITGOnlineLobbyModel = ITGOnlineLobbyModel or {}

local Model = ITGOnlineLobbyModel

function Model.stable_scalar(value)
	if value == nil then return "" end
	return tostring(value)
end

function Model.player_state_signature(player)
	player = type(player) == "table" and player or {}
	local user = type(player.user) == "table" and player.user or {}
	return table.concat({
		Model.stable_scalar(player.id or player.user_id or user.id),
		Model.stable_scalar(user.display_name or user.displayName or user.name or player.name),
		Model.stable_scalar(player.status or player.play_state or player.state),
		Model.stable_scalar(player.ready_state or player.readyState),
		Model.stable_scalar(player.is_ready or player.ready),
		Model.stable_scalar(player.song_available or player.songAvailable),
		Model.stable_scalar(player.missing_song or player.missingSong),
		Model.stable_scalar(player.pack_sync_status or player.packSyncStatus),
		Model.stable_scalar(player.pack_sync_sequence or player.packSyncSequence),
		Model.stable_scalar(player.download_progress or player.downloadProgress),
		Model.stable_scalar(player.pack_sync_download_deadline_ms or player.packSyncDownloadDeadlineMs),
	}, ":")
end

function Model.joined_player_stable_key(player)
	if type(player) ~= "table" then return "" end
	local user = type(player.user) == "table" and player.user or {}
	local key = player.playerId or player.id or player.user_id or user.id
	if key ~= nil and tostring(key) ~= "" then
		return "id:" .. tostring(key)
	end
	key = player.profileName or player.displayName or player.name
		or user.display_name or user.displayName or user.name
	if key ~= nil and tostring(key) ~= "" then
		return "name:" .. tostring(key)
	end
	return ""
end

function Model.joined_player_index_for_key(players, key, fallback)
	if key == nil or tostring(key) == "" then
		return fallback or 1
	end
	for index, player in ipairs(players or {}) do
		if Model.joined_player_stable_key(player) == key then
			return index
		end
	end
	return fallback or 1
end

function Model.joined_players_order_signature(players)
	local parts = {}
	for index, player in ipairs(players or {}) do
		parts[#parts + 1] =
			tostring(index) .. "=" .. tostring(Model.joined_player_stable_key(player))
	end
	return table.concat(parts, ",")
end

function Model.online_lobby_state_signature(params)
	params = type(params) == "table" and params or {}
	local players = {}
	for index, player in ipairs(params.players or {}) do
		players[#players + 1] =
			Model.player_state_signature(player) .. "#" .. tostring(index)
	end
	table.sort(players)
	local songInfo = type(params.songInfo) == "table" and params.songInfo or {}
	local playState = type(params.playState) == "table" and params.playState or {}
	local playSessions = {}
	for index, session in ipairs(playState.sessions or {}) do
		session = type(session) == "table" and session or {}
		local user = type(session.user) == "table" and session.user or {}
		playSessions[#playSessions + 1] = table.concat({
			Model.stable_scalar(session.user_id or user.id),
			Model.stable_scalar(session.state),
			Model.stable_scalar(session.returned_to_lobby_at),
			Model.stable_scalar(session.finished_at),
			Model.stable_scalar(session.failed_at),
			Model.stable_scalar(session.disconnected_at),
			tostring(index),
		}, ":")
	end
	table.sort(playSessions)
	local globalOptions =
		type(params.globalOptions) == "table" and params.globalOptions or {}
	local manager = type(params.manager) == "table" and params.manager or {}
	return table.concat({
		Model.stable_scalar(params.roomId or params.id),
		Model.stable_scalar(params.code),
		Model.stable_scalar(params.phase or params.status or params.readyPhase),
		Model.stable_scalar(params.isManager),
		Model.stable_scalar(manager.id),
		Model.stable_scalar(songInfo.selectedAt or songInfo.selected_at),
		Model.stable_scalar(songInfo.song_hash or songInfo.songHash),
		Model.stable_scalar(songInfo.chart_hash or songInfo.chartHash),
		Model.stable_scalar(songInfo.pack),
		Model.stable_scalar(globalOptions.scoreMode),
		Model.stable_scalar(globalOptions.musicRate),
		Model.stable_scalar(playState.submitted_scores and #playState.submitted_scores),
		Model.stable_scalar(playState.final_results and #playState.final_results),
		table.concat(playSessions, "|"),
		table.concat(players, "|"),
	}, "||")
end

return Model
