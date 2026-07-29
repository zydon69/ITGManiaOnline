ITGOnlineReadinessCoordinator = ITGOnlineReadinessCoordinator or {}

local Coordinator = ITGOnlineReadinessCoordinator

function Coordinator.payload(identity, values)
	identity = type(identity) == "table" and identity or {}
	values = type(values) == "table" and values or {}
	assert(identity.side == "P1" or identity.side == "P2", "local readiness identity is required")
	return {
		local_player = identity.side,
		client_action_id = values.clientActionId,
		selection_id = values.selectionId,
		phase = values.phase,
		is_ready = values.isReady == true,
		options = values.options,
	}
end

function Coordinator.request_key(roomId, roundKey, payload)
	payload = type(payload) == "table" and payload or {}
	local options = type(payload.options) == "table" and payload.options or {}
	return table.concat({
		tostring(roomId or ""),
		tostring(roundKey or ""),
		tostring(payload.local_player or payload.localPlayer or ""),
		tostring(payload.selection_id or ""),
		tostring(payload.phase or ""),
		payload.is_ready == true and "1" or "0",
		tostring(options.song_hash or ""),
		tostring(options.chart_hash or ""),
		tostring(options.chart_key or ""),
		tostring(options.score_mode or options.scoreMode or ""),
		tostring(options.speed_mod or ""),
		tostring(options.music_rate_bpm or ""),
		tostring(options.stepchart or ""),
	}, "|")
end

function Coordinator.local_party_action(plan, isReady, companionReadyAlready)
	if type(plan) ~= "table" or plan.twoPlayer ~= true or companionReadyAlready == true then
		return "primary_only"
	end
	return isReady == true and "companion_barrier" or "companion_fanout"
end

function Coordinator.validate_song_context(selectedSong, options, isReady)
	if isReady ~= true then return true end
	selectedSong = type(selectedSong) == "table" and selectedSong or {}
	options = type(options) == "table" and options or {}
	local selectedHash = tostring(selectedSong.song_hash or selectedSong.songHash or ""):lower()
	local optionHash = tostring(options.song_hash or ""):lower()
	if selectedHash == "" or optionHash == "" or optionHash ~= selectedHash then
		return false, "config_ready_song_context_mismatch", selectedHash, optionHash
	end
	return true, nil, selectedHash, optionHash
end

function Coordinator.send(client, identity, roomId, payload, callback)
	assert(type(client) == "table", "readiness client is required")
	assert(type(identity) == "table" and identity.player ~= nil,
		"local readiness identity is required")
	client:RequestAsLocalPlayer(
		identity.player,
		"POST",
		"/rooms/" .. tostring(roomId) .. "/ready",
		payload,
		callback
	)
end

return Coordinator
