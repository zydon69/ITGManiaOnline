ITGOnlineRoomStateMachine = ITGOnlineRoomStateMachine or {}

local StateMachine = ITGOnlineRoomStateMachine

local phases = {
	lobby = true,
	lobby_ready = true,
	config = true,
	starting = true,
	playing = true,
	results = true,
}

local phaseOrder = {
	lobby = 1,
	lobby_ready = 2,
	config = 3,
	starting = 4,
	playing = 5,
	results = 6,
}

function StateMachine.normalize_phase(value)
	local phase = tostring(value or ""):lower()
	return phases[phase] and phase or "unknown"
end

local function local_party_companions_by_user_id(room)
	local companions = {}
	for _, member in ipairs(type(room) == "table" and room.members or {}) do
		local user = type(member.user) == "table" and member.user or member
		local userId = tostring(member.user_id or user.id or member.id or "")
		local party = type(member.local_party) == "table" and member.local_party
			or type(user.local_party) == "table" and user.local_party
			or nil
		local companion = party and party.companion or nil
		if userId ~= "" and type(companion) == "table" then
			companions[userId] = tostring(companion.id or companion.user_id or "")
		end
	end
	return companions
end

function StateMachine.validate_room_contract(room, context)
	if type(room) ~= "table" then return false, "missing_room_snapshot" end
	if type(room.members) ~= "table" then return false, "missing_room_members" end
	context = type(context) == "table" and context or {}
	if context.localPartyRequired == true then
		return StateMachine.validate_local_party_relation(
			room,
			context.firstUserId,
			context.secondUserId
		)
	end
	return true
end

function StateMachine.validate_local_party_relation(room, firstUserId, secondUserId)
	firstUserId = tostring(firstUserId or "")
	secondUserId = tostring(secondUserId or "")
	if firstUserId == "" or secondUserId == "" then
		return false, "missing_local_party_identity"
	end
	local companionByUserId = local_party_companions_by_user_id(room)
	if companionByUserId[firstUserId] ~= secondUserId
		or companionByUserId[secondUserId] ~= firstUserId then
		return false, "missing_local_party_relation"
	end
	return true
end

function StateMachine.local_party_relation_signature(room)
	local relations = {}
	for userId, companionId in pairs(local_party_companions_by_user_id(room)) do
		relations[#relations + 1] = tostring(userId) .. ">" .. tostring(companionId)
	end
	table.sort(relations)
	return #relations > 0 and table.concat(relations, ",") or "none"
end

function StateMachine.validate_song_availability(decoded, expectedMissing)
	if type(decoded) ~= "table" or type(decoded.song_availability) ~= "table" then
		return false, "missing_song_availability"
	end
	if type(decoded.song_availability.missing) ~= "boolean" then
		return false, "missing_song_availability_state"
	end
	if decoded.song_availability.missing ~= (expectedMissing == true) then
		return false, "song_availability_state_mismatch"
	end
	return true
end

function StateMachine.phase_regresses(previousPhase, incomingPhase, context)
	context = type(context) == "table" and context or {}
	if context.sameRoom ~= true or context.allowRegression == true then return false end
	local previousOrder = phaseOrder[StateMachine.normalize_phase(previousPhase)]
	local incomingOrder = phaseOrder[StateMachine.normalize_phase(incomingPhase)]
	if not previousOrder or not incomingOrder or incomingOrder >= previousOrder then
		return false
	end
	if context.sameRound == false then return false end
	return true
end

function StateMachine.room_event_relevance(roomId, expectedRoomId, ignored, leaving, idsMatch)
	if ignored == true then return false, "recently_left_room" end
	if expectedRoomId == nil or tostring(expectedRoomId) == "" then
		return false, "no_expected_room"
	end
	if roomId == nil or tostring(roomId) == "" then return false, "missing_payload_room" end
	if leaving == true then return false, "leaving_room" end
	if idsMatch ~= true then return false, "room_mismatch" end
	return true, "room_match"
end

return StateMachine
