ITGOnlineProtocol = ITGOnlineProtocol or {}

local MAX_TABLE_ENTRIES = 16384
local MAX_DEPTH = 16
local MAX_VALUE_TEXT_BYTES = 65536
local MAX_LOG_TEXT_BYTES = 4096
local MAX_ID_DIGITS = 20
local MAX_UINT64 = "18446744073709551615"
local MAX_SAFE_INTEGER = 9007199254740991

local sensitiveLogKeys = {
	accesstoken = true,
	refreshtoken = true,
	token = true,
	apikey = true,
	password = true,
	passwordconfirmation = true,
	secret = true,
	authorization = true,
	polltoken = true,
	devicecode = true,
	shortcode = true,
	usercode = true,
	verificationurl = true,
	email = true,
}

local authRetryIdempotentPostPaths = {
	"^/rooms/%d+/leave$",
	"^/rooms/%d+/transfer%-manager$",
	"^/rooms/%d+/kick$",
	"^/rooms/%d+/global%-options$",
	"^/rooms/%d+/song%-selection$",
	"^/rooms/%d+/song%-selection/cancel$",
	"^/rooms/%d+/song%-preview/clear$",
	"^/rooms/%d+/pack%-sync%-status$",
	"^/rooms/%d+/ready$",
	"^/rooms/%d+/loaded$",
	"^/rooms/%d+/start%-ack$",
	"^/rooms/%d+/start$",
	"^/rooms/%d+/score$",
}

local knownPhases = {
	lobby = true,
	lobby_ready = true,
	config = true,
	starting = true,
	playing = true,
	results = true,
	closed = true,
}

local decimalIdFields = {
	id = true,
	room_id = true,
	roomId = true,
	user_id = true,
	userId = true,
	player_id = true,
	playerId = true,
	member_id = true,
	memberId = true,
	manager_user_id = true,
	managerUserId = true,
	inviter_id = true,
	inviterId = true,
	requester_id = true,
	requesterId = true,
	target_user_id = true,
	targetUserId = true,
}

local function bounded_text(value, maxBytes)
	if type(value) ~= "string" then return value end
	maxBytes = math.max(1, tonumber(maxBytes) or MAX_LOG_TEXT_BYTES)
	value = value:gsub("[%z\1-\8\11\12\14-\31\127]", "")
	if #value > maxBytes then value = value:sub(1, maxBytes) end
	return value
end

local function canonical_decimal_id(value)
	if type(value) == "number" then
		if value < 0 or value > MAX_SAFE_INTEGER or value ~= math.floor(value) then return nil end
	elseif type(value) ~= "string" then
		return nil
	end
	local text = tostring(value)
	if not text:match("^%d+$") then return nil end
	text = text:gsub("^0+", "")
	if text == "" then text = "0" end
	if #text > MAX_ID_DIGITS or (#text == MAX_ID_DIGITS and text > MAX_UINT64) then return nil end
	return text
end

local function valid_round_key(value)
	local key = tostring(value or "")
	local selectionRoomId, selectionId = key:match("^([^|]+)|selection:([^|]+)$")
	if selectionRoomId and selectionId then
		return canonical_decimal_id(selectionRoomId) ~= nil and selectionId ~= ""
	end

	local roomId, sessionId, songHash, chartHash, selectedAt = key:match("^([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)$")
	return canonical_decimal_id(roomId) ~= nil
		and chartHash ~= nil and chartHash ~= ""
		and (
			(sessionId ~= nil and sessionId ~= "")
			or (songHash ~= nil and songHash ~= "")
			or (selectedAt ~= nil and selectedAt ~= "")
		)
end

local function sanitize(value, depth, seen, path)
	local valueType = type(value)
	if valueType == "string" then
		if #value > MAX_VALUE_TEXT_BYTES then return nil, "text_too_long:" .. path end
		local cleaned = value:gsub("[%z\1-\8\11\12\14-\31\127]", "")
		return cleaned
	end
	if valueType ~= "table" then
		if valueType == "number" then
			if value ~= value or value == math.huge or value == -math.huge then
				return nil, "non_finite_number:" .. path
			end
			return value
		end
		if valueType == "boolean" or valueType == "nil" then return value end
		return nil, "unsupported_value:" .. path
	end
	if depth >= MAX_DEPTH then return nil, "table_too_deep:" .. path end
	if seen[value] then return nil, "cyclic_table:" .. path end
	seen[value] = true
	local result = {}
	local count = 0
	for key, item in pairs(value) do
		count = count + 1
		if count > MAX_TABLE_ENTRIES then
			seen[value] = nil
			return nil, "table_too_large:" .. path
		end
		if type(key) ~= "number" and type(key) ~= "string" then
			seen[value] = nil
			return nil, "unsupported_key:" .. path
		end
		if type(key) == "number" and (key ~= math.floor(key) or key < 1) then
			seen[value] = nil
			return nil, "invalid_numeric_key:" .. path
		end
		if type(key) == "string" and #key > 128 then
			seen[value] = nil
			return nil, "key_too_long:" .. path
		end
		local safeItem, itemError = sanitize(item, depth + 1, seen, path .. "." .. tostring(key))
		if itemError then
			seen[value] = nil
			return nil, itemError
		end
		result[key] = safeItem
	end
	seen[value] = nil
	return result
end

local function normalize_id_fields(value, path, seen)
	if type(value) ~= "table" then return true end
	if seen[value] then return true end
	seen[value] = true
	for key, item in pairs(value) do
		local itemPath = path .. "." .. tostring(key)
		if decimalIdFields[key] and item ~= nil then
			local normalizedId = canonical_decimal_id(item)
			if not normalizedId then
				seen[value] = nil
				return false, "invalid_decimal_id:" .. itemPath
			end
			value[key] = normalizedId
		elseif type(item) == "table" then
			local ok, normalizeError = normalize_id_fields(item, itemPath, seen)
			if not ok then
				seen[value] = nil
				return false, normalizeError
			end
		end
	end
	seen[value] = nil
	return true
end

local function validate_list(value, path)
	if type(value) ~= "table" then return false, "collection_not_table:" .. path end
	local length = #value
	local count = 0
	for key in pairs(value) do
		if type(key) ~= "number" or key < 1 or key ~= math.floor(key) or key > length then
			return false, "collection_not_dense:" .. path
		end
		count = count + 1
	end
	if count ~= length then return false, "collection_not_dense:" .. path end
	return true
end

local function normalize_room(room, alreadySanitized)
	if type(room) ~= "table" then return nil, "room_not_table" end
	local normalized = room
	if not alreadySanitized then
		local sanitizeError
		normalized, sanitizeError = sanitize(room, 0, {}, "room")
		if not normalized then return nil, sanitizeError or "invalid_room" end
	end
	local idsOk, idError = normalize_id_fields(normalized, "room", {})
	if not idsOk then return nil, idError end
	if not normalized.id or normalized.id == "0" then return nil, "invalid_room_id" end
	if type(normalized.phase) ~= "string" then return nil, "invalid_room_phase" end
	normalized.phase = normalized.phase:lower()
	if not knownPhases[normalized.phase] then return nil, "unknown_room_phase" end

	for _, collectionName in ipairs({
		"members",
		"ready_states",
		"live_scores",
		"top_scores",
		"pending_join_requests",
	}) do
		local collection = normalized[collectionName]
		if collection ~= nil then
			local listOk, listError = validate_list(collection, "room." .. collectionName)
			if not listOk then return nil, listError end
			for index = 1, #collection do
				if type(collection[index]) ~= "table" then
					return nil, "collection_item_not_table:room." .. collectionName .. "." .. tostring(index)
				end
			end
		end
	end

	if normalized.manager ~= nil and type(normalized.manager) ~= "table" then
		return nil, "invalid_room_manager"
	end
	if normalized.selected_song ~= nil and type(normalized.selected_song) ~= "table" then
		return nil, "invalid_selected_song"
	end
	if normalized.global_options ~= nil and type(normalized.global_options) ~= "table" then
		return nil, "invalid_global_options"
	end
	if normalized.play_state ~= nil then
		if type(normalized.play_state) ~= "table" then return nil, "invalid_play_state" end
		for _, collectionName in ipairs({ "sessions", "final_results" }) do
			local collection = normalized.play_state[collectionName]
			if collection ~= nil then
				local listOk, listError = validate_list(collection, "room.play_state." .. collectionName)
				if not listOk then return nil, listError end
			end
		end
	end
	return normalized
end

local function normalize_event(event, alreadySanitized)
	if type(event) ~= "table" then return nil, "event_not_table" end
	local normalized = event
	if not alreadySanitized then
		local sanitizeError
		normalized, sanitizeError = sanitize(event, 0, {}, "event")
		if not normalized then return nil, sanitizeError or "invalid_event" end
	end
	local idsOk, idError = normalize_id_fields(normalized, "event", {})
	if not idsOk then return nil, idError end
	local name = normalized.event or normalized.name
	if type(name) ~= "string" or name == "" or #name > 128 then return nil, "invalid_event_name" end
	normalized.event = name
	if normalized.payload == nil then normalized.payload = {} end
	if type(normalized.payload) ~= "table" then return nil, "invalid_event_payload" end
	if normalized.payload.room ~= nil then
		local normalizedRoom, roomError = normalize_room(normalized.payload.room, true)
		if not normalizedRoom then return nil, "invalid_event_room:" .. tostring(roomError) end
		normalized.payload.room = normalizedRoom
	end
	return normalized
end

function ITGOnlineProtocol.canonical_decimal_id(value)
	return canonical_decimal_id(value)
end

function ITGOnlineProtocol.is_auth_retry_idempotent(method, path, payload)
	method = tostring(method or ""):upper()
	if method == "GET" or method == "HEAD" or method == "OPTIONS" then return true end
	if method ~= "POST" or type(payload) ~= "table" then return false end
	local actionId = payload.client_action_id
	if type(actionId) ~= "string" or actionId:match("^[A-Za-z0-9._:-]+$") == nil then return false end
	for _, pattern in ipairs(authRetryIdempotentPostPaths) do
		if tostring(path or ""):match(pattern) then return true end
	end
	return false
end

function ITGOnlineProtocol.safe_log_text(value, maxBytes)
	local text = tostring(value or ""):gsub("[%c]", " ")

	-- URLs may embed temporary login/download credentials. Keeping the origin and
	-- path is sufficient to diagnose routing while removing query and fragment data.
	text = text:gsub("([Hh][Tt][Tt][Pp][Ss]?://[^%s%?#]+)[%?#][^%s]+", "%1?<redacted>")
	text = text:gsub("([Bb][Ee][Aa][Rr][Ee][Rr]%s+)[^%s,;]+", "%1[redacted]")

	local function is_sensitive_key(key)
		local normalized = tostring(key or ""):lower():gsub("[_%-]", "")
		return sensitiveLogKeys[normalized] == true
	end

	-- Redact quoted JSON-like fields before generic key/value fragments so quote
	-- boundaries cannot leave a credential suffix visible.
	text = text:gsub("([\"'])([%w_%-]+)([\"']%s*:%s*[\"'])([^\"']*)([\"'])", function(openQuote, key, separator, _, closeQuote)
		if not is_sensitive_key(key) then
			return openQuote .. key .. separator .. _ .. closeQuote
		end
		return openQuote .. key .. separator .. "[redacted]" .. closeQuote
	end)
	text = text:gsub("([%w_%-]+)(%s*[=:]%s*)([^%s,;]+)", function(key, separator, fieldValue)
		if not is_sensitive_key(key) then return key .. separator .. fieldValue end
		return key .. separator .. "[redacted]"
	end)

	-- Never expose host-user paths. Engine virtual paths remain useful and do not
	-- identify the workstation account.
	text = text:gsub("/Users/[^%s,;]+", "<local-path>")
	text = text:gsub("/home/[^%s,;]+", "<local-path>")
	text = text:gsub("/var/folders/[^%s,;]+", "<local-path>")
	text = text:gsub("/tmp/[^%s,;]+", "<local-path>")
	text = text:gsub("%f[%a]%a:[/\\][^%s,;]+", "<local-path>")

	return bounded_text(text, maxBytes or MAX_LOG_TEXT_BYTES)
end

function ITGOnlineProtocol.normalize_room(room)
	return normalize_room(room, false)
end

function ITGOnlineProtocol.normalize_event(event)
	return normalize_event(event, false)
end

function ITGOnlineProtocol.normalize_sync_payload(payload)
	if type(payload) ~= "table" then return nil, "sync_not_table" end
	local normalized, sanitizeError = sanitize(payload, 0, {}, "sync")
	if not normalized then return nil, sanitizeError or "invalid_sync" end
	local idsOk, idError = normalize_id_fields(normalized, "sync", {})
	if not idsOk then return nil, idError end
	if normalized.next_cursor ~= nil then
		local nextCursor = canonical_decimal_id(normalized.next_cursor)
		if not nextCursor then return nil, "invalid_next_cursor" end
		normalized.next_cursor = nextCursor
	end

	for _, collectionName in ipairs({
		"online_users",
		"public_rooms",
		"pending_join_requests",
		"pending_invitations",
		"events",
	}) do
		local collection = normalized[collectionName]
		if collection ~= nil then
			local listOk, listError = validate_list(collection, "sync." .. collectionName)
			if not listOk then return nil, listError end
			for index = 1, #collection do
				if type(collection[index]) ~= "table" then
					return nil, "collection_item_not_table:sync." .. collectionName .. "." .. tostring(index)
				end
			end
		end
	end

	if normalized.current_room ~= nil then
		local normalizedRoom, roomError = normalize_room(normalized.current_room, true)
		if not normalizedRoom then return nil, "invalid_current_room:" .. tostring(roomError) end
		normalized.current_room = normalizedRoom
	end
	for index = 1, #(normalized.public_rooms or {}) do
		local normalizedRoom, roomError = normalize_room(normalized.public_rooms[index], true)
		if not normalizedRoom then
			return nil, "invalid_public_room:" .. tostring(index) .. ":" .. tostring(roomError)
		end
		normalized.public_rooms[index] = normalizedRoom
	end
	for index = 1, #(normalized.events or {}) do
		local normalizedEvent, eventError = normalize_event(normalized.events[index], true)
		if not normalizedEvent then
			return nil, "invalid_sync_event:" .. tostring(index) .. ":" .. tostring(eventError)
		end
		normalized.events[index] = normalizedEvent
	end
	if normalized.server_policy ~= nil and type(normalized.server_policy) ~= "table" then
		return nil, "invalid_server_policy"
	end
	if normalized.meta ~= nil and type(normalized.meta) ~= "table" then return nil, "invalid_sync_meta" end
	return normalized
end

function ITGOnlineProtocol.new_event_reducer(roomId)
	local expectedRoomId = canonical_decimal_id(roomId)
	local reducer = { room_id = expectedRoomId, version = 0, phase = "", resync_required = false }
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

ITGOnlineProtocol.valid_round_key = valid_round_key

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
