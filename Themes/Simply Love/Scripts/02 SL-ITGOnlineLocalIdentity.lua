ITGOnlineLocalIdentity = ITGOnlineLocalIdentity or {}

local Identity = ITGOnlineLocalIdentity

local function normalized_side(value)
	local side = tostring(value or ""):upper()
	if side == "P1" or side == "PLAYER_1" or side == "PLAYERNUMBER_P1" then
		return "P1"
	end
	if side == "P2" or side == "PLAYER_2" or side == "PLAYERNUMBER_P2" then
		return "P2"
	end
	return nil
end

function Identity.side(value, playerOne, playerTwo)
	if value ~= nil and playerTwo ~= nil and value == playerTwo then return "P2" end
	if value ~= nil and playerOne ~= nil and value == playerOne then return "P1" end
	return normalized_side(value)
end

function Identity.player(side, playerOne, playerTwo)
	local normalized = Identity.side(side, playerOne, playerTwo)
	if normalized == "P1" then return playerOne end
	if normalized == "P2" then return playerTwo end
	return nil
end

function Identity.describe(value, playerOne, playerTwo, plan)
	local side = Identity.side(value, playerOne, playerTwo)
	if side == nil then return nil, "invalid_local_identity" end
	local coordinatorSide = type(plan) == "table"
		and Identity.side(plan.coordinatorSide, playerOne, playerTwo)
		or nil
	if coordinatorSide == nil then return nil, "invalid_coordinator_identity" end

	return {
		side = side,
		player = Identity.player(side, playerOne, playerTwo),
		isPrimary = side == coordinatorSide,
		role = side == coordinatorSide and "coordinator" or "companion",
	}
end

return Identity
