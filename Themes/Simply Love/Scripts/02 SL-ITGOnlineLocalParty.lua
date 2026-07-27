ITGOnlineLocalParty = ITGOnlineLocalParty or {}

local Party = ITGOnlineLocalParty

local function normalized_side(value)
	local side = tostring(value or ""):upper()
	if side == "PLAYERNUMBER_P1" or side == "PLAYER_1" then return "P1" end
	if side == "PLAYERNUMBER_P2" or side == "PLAYER_2" then return "P2" end
	if side == "P1" or side == "P2" then return side end
	return nil
end

function Party.normalized_side(value)
	return normalized_side(value)
end

function Party.session_plan(joinedSides)
	local joined = {}
	for _, value in ipairs(type(joinedSides) == "table" and joinedSides or {}) do
		local side = normalized_side(value)
		if side then joined[side] = true end
	end

	local required = {}
	if joined.P1 then required[#required + 1] = "P1" end
	if joined.P2 then required[#required + 1] = "P2" end
	local coordinator = joined.P1 and "P1" or (joined.P2 and "P2" or nil)

	return {
		requiredSides = required,
		requiredCount = #required,
		coordinatorSide = coordinator,
		twoPlayer = #required == 2,
	}
end

function Party.validate_identities(plan, identities)
	plan = type(plan) == "table" and plan or { requiredSides = {} }
	identities = type(identities) == "table" and identities or {}
	local seen = {}
	for _, side in ipairs(plan.requiredSides or {}) do
		local userId = tostring(identities[side] or "")
		if userId == "" then
			return false, "local_player_not_authenticated", side
		end
		if seen[userId] then
			return false, "duplicate_local_online_identity", side
		end
		seen[userId] = side
	end
	if #(plan.requiredSides or {}) == 0 then
		return false, "no_local_player"
	end
	return true
end

function Party.online_mode_supported(isCouple, isRoutine)
	if isCouple == true then return false, "couple_not_supported_online" end
	if isRoutine == true then return false, "routine_not_supported_online" end
	return true
end

function Party.role_for_side(plan, side)
	side = normalized_side(side)
	if not side or type(plan) ~= "table" then return nil end
	if side == plan.coordinatorSide then return "coordinator" end
	for _, requiredSide in ipairs(plan.requiredSides or {}) do
		if side == requiredSide then return "companion" end
	end
	return nil
end

function Party.all_local_finals_accepted(plan, acceptedBySide)
	if type(plan) ~= "table" or type(acceptedBySide) ~= "table" then return false end
	local requiredSides = type(plan.requiredSides) == "table" and plan.requiredSides or {}
	if #requiredSides == 0 then return false end
	for _, side in ipairs(requiredSides) do
		if acceptedBySide[normalized_side(side)] ~= true then return false end
	end
	return true
end

function Party.failed_player_route(plan, side)
	local role = Party.role_for_side(plan, side)
	if role == "coordinator" then return "primary" end
	if role == "companion" then return "companion" end
	return nil
end

function Party.should_submit_companion_ready(plan, isReady, companionReadyAlready)
	return type(plan) == "table"
		and plan.twoPlayer == true
		and companionReadyAlready ~= true
		and isReady == true
end

function Party.should_fan_out_companion_not_ready(plan, isReady, companionReadyAlready)
	return type(plan) == "table"
		and plan.twoPlayer == true
		and companionReadyAlready ~= true
		and isReady ~= true
end

function Party.companion_score_is_terminal(finalAccepted, roomHasFinalResult)
	return finalAccepted == true or roomHasFinalResult == true
end

function Party.companion_live_score_should_send(zeroLiveAccepted, final, hasLiveProgress)
	if final == true or hasLiveProgress == true then
		return true
	end

	return zeroLiveAccepted ~= true
end

function Party.should_preserve_local_chart_choice(phase, screenName)
	phase = tostring(phase or ""):lower()
	screenName = tostring(screenName or "")

	return phase == "lobby"
		or phase == "lobby_ready"
		or phase == "config"
		or screenName == "ScreenSelectMusic"
		or screenName == "ScreenPlayerOptions"
end

function Party.resolve_pre_game_chart(pendingSteps, intentSteps, currentSteps, preferredSteps, fallbackSteps)
	return pendingSteps or intentSteps or currentSteps or preferredSteps or fallbackSteps
end

return Party
