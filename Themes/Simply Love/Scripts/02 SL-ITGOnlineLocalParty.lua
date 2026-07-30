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

function Party.score_transport_should_continue(plan, finalizedBySide)
	if type(plan) ~= "table" or type(finalizedBySide) ~= "table" then return false end
	local requiredSides = type(plan.requiredSides) == "table" and plan.requiredSides or {}
	if #requiredSides == 0 then return false end
	for _, side in ipairs(requiredSides) do
		if finalizedBySide[normalized_side(side)] ~= true then return true end
	end
	return false
end

function Party.failed_player_route(plan, side)
	local role = Party.role_for_side(plan, side)
	if role == "coordinator" then return "primary" end
	if role == "companion" then return "companion" end
	return nil
end

-- A shared ScreenGameplay cannot return only one local side to the lobby.
-- The requesting side may therefore leave only after every *other* local side
-- already owns an authoritative final result.  A one-player machine has no
-- companion to wait for.
function Party.gameplay_exit_allowed(plan, requestingSide, finalizedBySide)
	if type(plan) ~= "table" or type(finalizedBySide) ~= "table" then
		return false
	end

	local requester = normalized_side(requestingSide)
	if Party.role_for_side(plan, requester) == nil then return false end
	if plan.twoPlayer ~= true then return true end

	for _, side in ipairs(plan.requiredSides or {}) do
		side = normalized_side(side)
		if side ~= requester and finalizedBySide[side] ~= true then
			return false
		end
	end

	return true
end

-- Once every required local score is frozen, leaving ScreenGameplay is a
-- local operation.  Transport failures only defer the idempotent lifecycle
-- acknowledgement; deterministic contract rejections still stop the replay.
function Party.gameplay_exit_failure_action(statusCode, errorCode, retryAfter)
	if (tonumber(retryAfter) or 0) > 0 then return "defer" end

	local status = tonumber(statusCode)
	local code = tostring(errorCode or ""):lower()
	if status == nil or status == 0 then return "defer" end
	if status == 408 or status == 425 or status == 429 or status >= 500 then
		return "defer"
	end
	if code == ""
		or code:find("cannotconnect", 1, true)
		or code:find("cannot_connect", 1, true)
		or code:find("timeout", 1, true)
		or code:find("network", 1, true)
		or code:find("temporar", 1, true)
	then
		return "defer"
	end

	return "cancel"
end

function Party.deferred_gameplay_exit_action(hasCurrentRoom, phase, sameRoom)
	if hasCurrentRoom ~= true or sameRoom ~= true then return "departed" end

	phase = tostring(phase or ""):lower()
	if phase == "lobby" or phase == "lobby_ready" or phase == "config" then
		return "confirmed"
	end
	if phase == "playing" or phase == "results" then return "retry" end

	return "wait"
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

-- Failed-score stabilization protects a final snapshot that has not reached
-- the server yet.  Re-running it after the primary final was already accepted
-- blocks the companion final behind an unnecessary timer at natural song end.
function Party.primary_final_requires_stabilization(failed, primaryFinalAccepted)
	return failed == true and primaryFinalAccepted ~= true
end

function Party.gameplay_completion_needs_progress(engineEndedKey, evaluationMarkKey, roundKey)
	roundKey = tostring(roundKey or "")
	return roundKey ~= ""
		and tostring(engineEndedKey or "") == roundKey
		and tostring(evaluationMarkKey or "") ~= roundKey
end

-- A score can legitimately decrease on the judgment that causes failure.
-- Therefore the terminal engine snapshot is authoritative even when the last
-- live snapshot had a higher percentage. The live cache is only a recovery
-- fallback when the engine no longer exposes a terminal snapshot.
function Party.terminal_score_snapshot(currentSnapshot, lastLiveSnapshot)
	if type(currentSnapshot) == "table" then return currentSnapshot end
	if type(lastLiveSnapshot) == "table" then return lastLiveSnapshot end
	return nil
end

function Party.returned_to_lobby_needs_reconciliation(
	phase,
	isLobbyScreen,
	evaluationShownKey,
	returnedKey,
	roundKey
)
	roundKey = tostring(roundKey or "")
	return tostring(phase or "") == "results"
		and isLobbyScreen == true
		and roundKey ~= ""
		and tostring(evaluationShownKey or "") == roundKey
		and tostring(returnedKey or "") ~= roundKey
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
