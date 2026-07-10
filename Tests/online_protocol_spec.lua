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

local logged = protocol.safe_log_text("room\r\nforged", 32)
assert(not logged:find("\r") and not logged:find("\n"), "log controls must be removed")

local members = {}
for index = 1, 300 do members[index] = { user_id = tostring(index), user = { id = tostring(index), name = "player" } } end
local room = assert(protocol.normalize_room({
	id = "009",
	phase = "PLAYING",
	members = members,
	ready_states = "invalid",
}))
equal(room.id, "9", "room ID")
equal(room.phase, "playing", "room phase")
equal(#room.members, 256, "member cap")
equal(#room.ready_states, 0, "invalid ready states")

local cyclic = { id = "10", phase = "lobby" }
cyclic.self = cyclic
local normalizedCyclic = assert(protocol.normalize_room(cyclic))
equal(normalizedCyclic.self, nil, "cycle removal")
local invalidRoom, invalidReason = protocol.normalize_room({ id = "not-an-id" })
equal(invalidRoom, nil, "invalid room")
equal(invalidReason, "invalid_room_id", "invalid room reason")

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
