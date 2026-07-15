local sourceRoot = assert(arg[1], "source root is required")
local protocol = assert(dofile(sourceRoot .. "/Themes/Simply Love/Scripts/01 SL-ITGOnlineProtocol.lua"))

local function equal(actual, expected, label)
	assert(actual == expected, (label or "value") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
end

equal(protocol.canonical_decimal_id("00042"), "42", "leading zero ID")
equal(protocol.canonical_decimal_id("18446744073709551615"), "18446744073709551615", "uint64 max")
equal(protocol.canonical_decimal_id("18446744073709551616"), nil, "uint64 overflow")
equal(protocol.canonical_decimal_id("1e3"), nil, "scientific ID")
equal(protocol.canonical_decimal_id(-1), nil, "negative ID")
equal(protocol.canonical_decimal_id(9007199254740992), nil, "unsafe numeric ID")

equal(protocol.is_auth_retry_idempotent("GET", "/rooms/1", nil), true, "safe read retry")
equal(protocol.is_auth_retry_idempotent("POST", "/rooms/1/song-selection", {
	client_action_id = "selection:abc-123",
}), true, "declared selection retry")
equal(protocol.is_auth_retry_idempotent("POST", "/rooms/1/score", {
	client_action_id = "score:abc-123",
}), true, "declared final score retry")
equal(protocol.is_auth_retry_idempotent("POST", "/rooms/1/kick", {
	client_action_id = "invented-key",
}), true, "declared room command retry")
equal(protocol.is_auth_retry_idempotent("POST", "/rooms/1/invitations", {
	client_action_id = "invented-key",
}), false, "unknown mutation retry rejection")
equal(protocol.is_auth_retry_idempotent("POST", "/rooms/1/song-selection", {}), false, "missing action ID retry rejection")

local logged = protocol.safe_log_text("room\r\nforged", 32)
assert(not logged:find("\r") and not logged:find("\n"), "log controls must be removed")

local sensitiveLog = protocol.safe_log_text(
	'https://online.example/device?poll_token=query-secret#fragment '
		.. 'Authorization: Bearer bearer-secret access_token=access-secret refresh-token=refresh-secret '
		.. 'pollToken=poll-secret password=pass-secret email=player@example.test '
		.. 'json={"apiKey":"json-secret","device_code":"device-secret"} '
		.. 'path=/Users/player/Library/Application Support/ITGmania/token.ini '
		.. 'windows=C:\\Users\\player\\token.ini',
	4096
)
for _, secret in ipairs({
	"query-secret", "fragment", "bearer-secret", "access-secret", "refresh-secret",
	"poll-secret", "pass-secret", "player@example.test", "json-secret", "device-secret", "player/Library",
}) do
	assert(not sensitiveLog:find(secret, 1, true), "sensitive log value leaked: " .. secret)
end
assert(sensitiveLog:find("https://online.example/device?<redacted>", 1, true), "URL route should remain diagnosable")
assert(sensitiveLog:find("<local-path>", 1, true), "local paths must be redacted")

local members = {}
for index = 1, 300 do members[index] = { user_id = tostring(index), user = { id = tostring(index), name = "player" } } end
local room = assert(protocol.normalize_room({
	id = "009",
	phase = "PLAYING",
	members = members,
	ready_states = {},
}))
equal(room.id, "9", "room ID")
equal(room.phase, "playing", "room phase")
equal(#room.members, 300, "complete member list")
equal(#room.ready_states, 0, "empty ready states")

local invalidCollection, invalidCollectionReason = protocol.normalize_room({
	id = "9",
	phase = "playing",
	ready_states = "invalid",
})
equal(invalidCollection, nil, "invalid collection rejection")
equal(invalidCollectionReason, "collection_not_table:room.ready_states", "invalid collection reason")

local cyclic = { id = "10", phase = "lobby" }
cyclic.self = cyclic
local normalizedCyclic, cyclicReason = protocol.normalize_room(cyclic)
equal(normalizedCyclic, nil, "cycle rejection")
equal(cyclicReason, "cyclic_table:room.self", "cycle reason")
local invalidRoom, invalidReason = protocol.normalize_room({ id = "not-an-id", phase = "lobby" })
equal(invalidRoom, nil, "invalid room")
equal(invalidReason, "invalid_decimal_id:room.id", "invalid room reason")

local missingPhase, missingPhaseReason = protocol.normalize_room({ id = "11" })
equal(missingPhase, nil, "missing phase rejection")
equal(missingPhaseReason, "invalid_room_phase", "missing phase reason")

local nonFiniteRoom, nonFiniteReason = protocol.normalize_room({
	id = "11",
	phase = "lobby",
	server_time_ms = math.huge,
})
equal(nonFiniteRoom, nil, "non-finite number rejection")
equal(nonFiniteReason, "non_finite_number:room.server_time_ms", "non-finite number reason")

local event = assert(protocol.normalize_event({
	id = "00017",
	event = "room.ready_updated",
	target = { id = "0009", type = "room" },
	payload = {
		room_id = "0009",
		room = { id = "0009", phase = "config", members = {}, ready_states = {} },
	},
}))
equal(event.id, "17", "event ID")
equal(event.target.id, "9", "nested target ID")
equal(event.payload.room_id, "9", "nested payload room ID")

local invalidEvent, invalidEventReason = protocol.normalize_event({
	id = "18",
	event = "room.ready_updated",
	payload = { room = { id = "9", phase = "future" } },
})
equal(invalidEvent, nil, "invalid event room rejection")
equal(invalidEventReason, "invalid_event_room:unknown_room_phase", "invalid event room reason")

local syncPayload = assert(protocol.normalize_sync_payload({
	current_room = { id = "9", phase = "lobby", members = {}, ready_states = {} },
	public_rooms = { { id = "12", phase = "lobby", members = {}, ready_states = {} } },
	online_users = {},
	pending_join_requests = {},
	pending_invitations = {},
	events = { event },
	next_cursor = "17",
	meta = {},
}))
equal(syncPayload.current_room.id, "9", "sync current room ID")
equal(syncPayload.public_rooms[1].id, "12", "sync public room ID")
equal(syncPayload.events[1].id, "17", "sync event ID")

local invalidSync, invalidSyncReason = protocol.normalize_sync_payload({
	public_rooms = "invalid",
	events = {},
})
equal(invalidSync, nil, "invalid sync rejection")
equal(invalidSyncReason, "collection_not_table:sync.public_rooms", "invalid sync reason")

local invalidCursorSync, invalidCursorReason = protocol.normalize_sync_payload({
	public_rooms = {},
	events = {},
	next_cursor = "1e3",
})
equal(invalidCursorSync, nil, "invalid sync cursor rejection")
equal(invalidCursorReason, "invalid_next_cursor", "invalid sync cursor reason")

local reducer = protocol.new_event_reducer("9007199254740993")
local applied, reason = reducer:apply({ room_id = "9007199254740993", version = 2, phase = "playing" })
equal(applied, true, "new event")
applied, reason = reducer:apply({ room_id = "9007199254740993", version = 1, phase = "lobby" })
equal(applied, false, "reordered event")
equal(reason, "stale_event", "reordered reason")
applied, reason = reducer:apply({ room_id = "9007199254740993", version = 3, phase = "future_phase" })
equal(applied, false, "unknown phase")
equal(reason, "unknown_phase", "unknown phase reason")
equal(reducer.resync_required, true, "unknown phase resync")

local callbacks = protocol.new_callback_queue(2)
local calls = 0
assert(callbacks:append(function(value) calls = calls + value end))
assert(callbacks:append(function(value) calls = calls + value end))
local accepted, queueReason = callbacks:append(function() end)
equal(accepted, false, "callback overflow")
equal(queueReason, "queue_full", "callback overflow reason")
equal(callbacks:drain(2), 2, "callback drain count")
equal(calls, 4, "callback invocation")

math.randomseed(1977)
for _ = 1, 10000 do
	local length = math.random(0, 40)
	local value = ""
	for _ = 1, length do
		local alphabet = "0123456789abcdef-+eE"
		local index = math.random(1, #alphabet)
		value = value .. alphabet:sub(index, index)
	end
	local canonical = protocol.canonical_decimal_id(value)
	if canonical ~= nil then
		assert(canonical:match("^%d+$"), "canonical ID must remain decimal")
		assert(#canonical <= 20, "canonical ID must remain bounded")
	end
end

print("online protocol behavioral tests passed")
