ITGOnlineProtocol = ITGOnlineProtocol or {}

local MAX_TABLE_ENTRIES = 256
local MAX_DEPTH = 5
local MAX_TEXT_BYTES = 4096
local MAX_ID_DIGITS = 20
local MAX_UINT64 = "18446744073709551615"

local function bounded_text(value, maxBytes)
	if type(value) ~= "string" then return value end
	maxBytes = math.max(1, tonumber(maxBytes) or MAX_TEXT_BYTES)
	value = value:gsub("[%z\1-\8\11\12\14-\31\127]", "")
	if #value > maxBytes then value = value:sub(1, maxBytes) end
	return value
end

local function canonical_decimal_id(value)
	if type(value) ~= "string" and type(value) ~= "number" then return nil end
	local text = tostring(value)
	if not text:match("^%d+$") then return nil end
	text = text:gsub("^0+", "")
	if text == "" then text = "0" end
	if #text > MAX_ID_DIGITS or (#text == MAX_ID_DIGITS and text > MAX_UINT64) then return nil end
	return text
end

local function sanitize(value, depth, seen)
	local valueType = type(value)
	if valueType == "string" then return bounded_text(value) end
	if valueType ~= "table" then
		if valueType == "number" or valueType == "boolean" or valueType == "nil" then return value end
		return nil
	end
	if depth >= MAX_DEPTH or seen[value] then return nil end
	seen[value] = true
	local result = {}
	local count = 0
	for key, item in pairs(value) do
		count = count + 1
		if count > MAX_TABLE_ENTRIES then break end
		if type(key) == "number" or type(key) == "string" then
			local safeKey = type(key) == "string" and bounded_text(key, 128) or key
			result[safeKey] = sanitize(item, depth + 1, seen)
		end
	end
	seen[value] = nil
	return result
end

local function normalize_id_fields(value)
	if type(value) ~= "table" then return end
	for _, key in ipairs({ "id", "room_id", "roomId", "user_id", "userId", "player_id", "playerId", "manager_user_id" }) do
		if value[key] ~= nil then value[key] = canonical_decimal_id(value[key]) end
	end
	if type(value.user) == "table" and value.user.id ~= nil then
		value.user.id = canonical_decimal_id(value.user.id)
	end
end

function ITGOnlineProtocol.canonical_decimal_id(value)
	return canonical_decimal_id(value)
end

function ITGOnlineProtocol.safe_log_text(value, maxBytes)
	return bounded_text(tostring(value or ""), maxBytes or MAX_TEXT_BYTES):gsub("[%c]", " ")
end

function ITGOnlineProtocol.normalize_room(room)
	if type(room) ~= "table" then return nil, "room_not_table" end
	local normalized = sanitize(room, 0, {})
	if type(normalized) ~= "table" then return nil, "room_too_deep" end
	normalize_id_fields(normalized)
	if room.id ~= nil and normalized.id == nil then return nil, "invalid_room_id" end
	if type(normalized.phase) ~= "string" then normalized.phase = "" end
	normalized.phase = bounded_text(normalized.phase:lower(), 32)
	for _, collectionName in ipairs({ "members", "ready_states" }) do
		local collection = normalized[collectionName]
		if collection ~= nil and type(collection) ~= "table" then
			normalized[collectionName] = {}
		elseif type(collection) == "table" then
			local values = {}
			for index = 1, math.min(#collection, MAX_TABLE_ENTRIES) do
				local item = collection[index]
				if type(item) == "table" then
					normalize_id_fields(item)
					values[#values + 1] = item
				end
			end
			normalized[collectionName] = values
		end
	end
	return normalized
end

function ITGOnlineProtocol.new_event_reducer(roomId)
	local expectedRoomId = canonical_decimal_id(roomId)
	local reducer = { room_id = expectedRoomId, version = 0, phase = "", resync_required = false }
	local knownPhases = { lobby = true, lobby_ready = true, config = true, starting = true, playing = true, results = true, closed = true }
	function reducer:apply(event)
		if type(event) ~= "table" then return false, "event_not_table" end
		local eventRoomId = canonical_decimal_id(event.room_id or event.roomId)
		if not eventRoomId or eventRoomId ~= self.room_id then return false, "room_mismatch" end
		local version = tonumber(event.version)
		if not version or version < 0 or version ~= math.floor(version) then return false, "invalid_version" end
		if version <= self.version then return false, "stale_event" end
		local phase = bounded_text(tostring(event.phase or ""):lower(), 32)
		if phase ~= "" and not knownPhases[phase] then
			self.resync_required = true
			return false, "unknown_phase"
		end
		self.version = version
		if phase ~= "" then self.phase = phase end
		self.resync_required = false
		return true
	end
	return reducer
end

function ITGOnlineProtocol.new_callback_queue(limit)
	limit = math.max(1, math.min(256, math.floor(tonumber(limit) or 32)))
	local queue = { values = {}, limit = limit }
	function queue:append(callback)
		if type(callback) ~= "function" then return false, "invalid_callback" end
		if #self.values >= self.limit then return false, "queue_full" end
		self.values[#self.values + 1] = callback
		return true
	end
	function queue:drain(...)
		local callbacks = self.values
		self.values = {}
		for _, callback in ipairs(callbacks) do callback(...) end
		return #callbacks
	end
	return queue
end

return ITGOnlineProtocol
