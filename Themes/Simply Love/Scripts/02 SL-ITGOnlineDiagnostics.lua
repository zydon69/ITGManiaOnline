ITGOnlineDiagnostics = ITGOnlineDiagnostics or {}

local function values(collection)
	local result = {}
	for _, value in pairs(type(collection) == "table" and collection or {}) do
		result[#result + 1] = value
	end
	return result
end

local function count_by(collection, field, fallback)
	local counts = {}
	for _, value in ipairs(values(collection)) do
		local key = tostring(type(value) == "table" and value[field] or fallback)
		if key == "" then key = fallback end
		counts[key] = (counts[key] or 0) + 1
	end
	return counts
end

local function sorted_count_summary(counts)
	local keys = {}
	for key in pairs(counts or {}) do keys[#keys + 1] = tostring(key) end
	table.sort(keys)

	local parts = {}
	for _, key in ipairs(keys) do
		parts[#parts + 1] = key .. ":" .. tostring(counts[key] or 0)
	end
	return table.concat(parts, ",")
end

function ITGOnlineDiagnostics.hash_completion_error(ok, errorCode, signatureChanged)
	if ok == true then return nil end
	if type(errorCode) == "string" and errorCode ~= "" then return errorCode end
	return signatureChanged == true and "file_changed" or "hash_failed"
end

function ITGOnlineDiagnostics.response_final_results(decoded)
	if type(decoded) ~= "table" then return {} end
	if type(decoded.play_state) == "table"
		and type(decoded.play_state.final_results) == "table"
	then
		return decoded.play_state.final_results
	end
	if type(decoded.room) == "table"
		and type(decoded.room.play_state) == "table"
		and type(decoded.room.play_state.final_results) == "table"
	then
		return decoded.room.play_state.final_results
	end
	if type(decoded.room) == "table" and type(decoded.room.final_results) == "table" then
		return decoded.room.final_results
	end
	return {}
end

function ITGOnlineDiagnostics.room_status_summary(room)
	room = type(room) == "table" and room or {}
	local members = type(room.members) == "table" and room.members or {}
	local playState = type(room.play_state) == "table" and room.play_state or {}
	local sessions = type(playState.sessions) == "table" and playState.sessions or {}

	return "members=" .. tostring(#values(members))
		.. " pack={" .. sorted_count_summary(count_by(members, "pack_sync_status", "none")) .. "}"
		.. " sessions={" .. sorted_count_summary(count_by(sessions, "state", "none")) .. "}"
end

return ITGOnlineDiagnostics
