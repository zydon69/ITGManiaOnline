ITGOnlineScoreTransport = ITGOnlineScoreTransport or {}

local Transport = ITGOnlineScoreTransport

local payloadFields = {
	"selection_id",
	"score",
	"score_percent",
	"displayed_percent",
	"itg_score_percent",
	"ex_score_percent",
	"hard_ex_score_percent",
	"combo",
	"max_combo",
	"accuracy",
	"song_position_seconds",
	"song_hash",
	"chart_hash",
	"failed",
	"final",
	"compact_response",
	"score_mode",
	"judgments",
	"client_action_id",
}

function Transport.new_runtime(identity, roundKey)
	identity = type(identity) == "table" and identity or {}
	return {
		localPlayer = identity.side,
		roundKey = tostring(roundKey or ""),
		inFlight = false,
		finalAccepted = false,
		pendingFinalRequested = false,
		pendingFinalCallbacks = {},
		lastSentAt = 0,
		lastAcceptedSongPosition = 0,
		maxCombo = 0,
		failedFinalRetryCount = 0,
		failedFinalNextAttemptAt = 0,
	}
end

function Transport.payload(identity, values, context)
	identity = type(identity) == "table" and identity or {}
	values = type(values) == "table" and values or {}
	assert(identity.side == "P1" or identity.side == "P2", "local score identity is required")
	local payload = {}
	for _, field in ipairs(payloadFields) do
		payload[field] = values[field]
	end
	payload.failed = values.failed == true
	payload.final = values.final == true
	payload.compact_response = values.final ~= true
	payload.judgments = type(values.judgments) == "table" and values.judgments or {}
	if type(context) == "table" then
		assert(tostring(context.song_hash or "") ~= "", "score song context is required")
		assert(tostring(context.chart_hash or "") ~= "", "score chart context is required")
		payload.song_hash = context.song_hash
		payload.chart_hash = context.chart_hash
	end
	return payload
end

function Transport.score_context(song, options)
	song = type(song) == "table" and song or {}
	options = type(options) == "table" and options or {}

	local selectedSongHash = tostring(song.song_hash or song.songHash or ""):lower()
	local optionSongHash = tostring(options.song_hash or options.songHash or ""):lower()
	local chartHash = tostring(options.chart_hash or options.chartHash or ""):lower()
	if selectedSongHash == "" then
		return nil, "missing_selected_song_hash"
	end
	if optionSongHash ~= "" and optionSongHash ~= selectedSongHash then
		return nil, "player_song_hash_mismatch"
	end
	if chartHash == "" then
		return nil, "missing_player_chart_hash"
	end
	local chartNoteCount = tonumber(options.chart_note_count or options.chartNoteCount)
	local maxScore = tonumber(options.max_score or options.maxScore)
	if maxScore == nil and chartNoteCount == nil then
		return nil, "missing_player_chart_score_basis"
	end

	return {
		song_hash = selectedSongHash,
		chart_hash = chartHash,
		chart_note_count = chartNoteCount,
		max_score = maxScore,
		rate = tonumber(song.rate) or 1,
		chart_duration_seconds = tonumber(song.chart_duration_seconds),
		music_length_seconds = tonumber(song.music_length_seconds),
	}, nil
end

function Transport.is_contract_error(errorCode)
	errorCode = tostring(errorCode or "")
	return errorCode == "score_song_mismatch"
		or errorCode == "invalid_player_score_context"
		or errorCode == "score_contract_rejected"
		or errorCode == "selected_chart_metadata_missing"
end

-- Only immutable song/chart contract failures poison a round transport.
-- Snapshot validation also uses HTTP 422, but clock/progress errors can become
-- valid after a fresh engine snapshot or an authoritative clock resync.
function Transport.is_deterministic_rejection(_statusCode, errorCode)
	return Transport.is_contract_error(errorCode)
end

function Transport.is_clock_rejection(errorCode)
	return tostring(errorCode or "") == "song_position_ahead_of_server_clock"
		or tostring(errorCode or "") == "song_position_behind_server_clock"
end

function Transport.position_belongs_to_round(positionKey, roundKey)
	positionKey = tostring(positionKey or "")
	roundKey = tostring(roundKey or "")
	if positionKey == "" or roundKey == "" then return false end
	return positionKey == roundKey
		or positionKey:sub(1, #roundKey + 1) == roundKey .. "|"
end

function Transport.round_position_fallback(positionKey, roundKey, position)
	if not Transport.position_belongs_to_round(positionKey, roundKey) then
		return 0
	end
	return math.max(0, tonumber(position) or 0)
end

function Transport.has_round_runtime_state(runtime)
	runtime = type(runtime) == "table" and runtime or {}
	return tostring(runtime.currentRoundKey or "") ~= ""
		or tostring(runtime.activeRoundKey or "") ~= ""
		or tostring(runtime.positionKey or "") ~= ""
		or (tonumber(runtime.songPosition) or 0) > 0
		or tostring(runtime.finalScoreKey or "") ~= ""
		or runtime.failedSnapshot ~= nil
		or runtime.pendingLiveScore ~= nil
end

function Transport.failed_final_action(failed, finalAccepted, inFlight, now, nextAttemptAt)
	if finalAccepted == true then return "complete" end
	if failed ~= true then return "live" end
	if inFlight == true then return "wait" end
	if (tonumber(now) or 0) < (tonumber(nextAttemptAt) or 0) then return "wait" end
	return "final"
end

function Transport.next_transient_final_retry(runtime, now)
	runtime = type(runtime) == "table" and runtime or {}
	runtime.failedFinalRetryCount =
		(tonumber(runtime.failedFinalRetryCount) or 0) + 1
	local delay = math.min(
		8,
		2 ^ math.min(3, runtime.failedFinalRetryCount - 1)
	)
	runtime.failedFinalNextAttemptAt = (tonumber(now) or 0) + delay
	return delay
end

function Transport.context_key(roundKey, context)
	context = type(context) == "table" and context or {}
	return table.concat({
		tostring(roundKey or ""),
		tostring(context.song_hash or ""),
		tostring(context.chart_hash or ""),
		tostring(context.chart_note_count or ""),
		tostring(context.max_score or ""),
	}, "|")
end

function Transport.queue_final(runtime, callback)
	if type(runtime) ~= "table" then return false end
	runtime.pendingFinalRequested = true
	runtime.pendingFinalCallbacks = runtime.pendingFinalCallbacks or {}
	if callback then
		runtime.pendingFinalCallbacks[#runtime.pendingFinalCallbacks + 1] = callback
	end
	return true
end

function Transport.take_pending_final(runtime)
	if type(runtime) ~= "table" then return false, {} end
	local requested = runtime.pendingFinalRequested == true
	local callbacks = runtime.pendingFinalCallbacks or {}
	runtime.pendingFinalRequested = false
	runtime.pendingFinalCallbacks = {}
	return requested, callbacks
end

function Transport.send(client, identity, roomId, payload, callback)
	assert(type(client) == "table", "score transport client is required")
	assert(type(identity) == "table" and identity.player ~= nil,
		"local score identity is required")
	client:RequestAsLocalPlayer(
		identity.player,
		"POST",
		"/rooms/" .. tostring(roomId) .. "/score",
		payload,
		callback
	)
end

return Transport
