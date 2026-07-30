ITGOnlineRoomPolicy = ITGOnlineRoomPolicy or {}

local Policy = ITGOnlineRoomPolicy

local function normalized_phase(value)
	return tostring(value or ""):lower()
end

local function member_identifier(member)
	if type(member) ~= "table" then return "" end
	local user = type(member.user) == "table" and member.user or {}
	return tostring(member.user_id or user.id or member.id or "")
end

function Policy.presence_status(hasRoom, phase, _screenName)
	if hasRoom ~= true then return "available" end

	phase = normalized_phase(phase)
	if phase == "starting"
		or phase == "playing"
		or phase == "results" then
		return "playing"
	end

	return "in_room"
end

function Policy.pending_song_sync_member_ids(room)
	if type(room) ~= "table"
		or type(room.selected_song) ~= "table"
		or normalized_phase(room.phase) ~= "config" then
		return {}
	end

	local pending = {}
	for _, member in ipairs(type(room.members) == "table" and room.members or {}) do
		local missing = member.missing_song == true or member.missingSong == true
		local available = member.song_available == true or member.songAvailable == true
		if missing or not available then
			pending[#pending + 1] = member_identifier(member)
		end
	end

	return pending
end

function Policy.options_deadline_blocked(room)
	return #Policy.pending_song_sync_member_ids(room) > 0
end

function Policy.can_leave_room(phase, roundKey, returnedRoundKey)
	phase = normalized_phase(phase)
	if phase ~= "starting" and phase ~= "playing" then
		return true, "phase_leaveable"
	end

	-- A local player who has already completed the authoritative
	-- returned-to-lobby handshake is no longer participating in gameplay.
	-- Keeping the global room phase at "playing" must not trap that player.
	if phase == "playing"
		and tostring(roundKey or "") ~= ""
		and tostring(returnedRoundKey or "") == tostring(roundKey)
	then
		return true, "local_party_returned"
	end

	return false, "active_round"
end

function Policy.projection_includes_user(projectedUserIds, expectedUserId)
	expectedUserId = tostring(expectedUserId or "")
	if expectedUserId == "" then return false end

	for _, userId in ipairs(type(projectedUserIds) == "table" and projectedUserIds or {}) do
		if tostring(userId or "") == expectedUserId then return true end
	end

	return false
end

return Policy
