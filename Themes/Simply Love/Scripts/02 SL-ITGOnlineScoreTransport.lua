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
	}
end

function Transport.payload(identity, values)
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
	return payload
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
