ITGOnlineLeaderboardPolicy = ITGOnlineLeaderboardPolicy or {}

local Policy = ITGOnlineLeaderboardPolicy

local function score_position(row)
	if type(row) ~= "table" then return 0 end
	return tonumber(row.song_position_seconds or row.latest_song_position_seconds) or 0
end

local function updated_at(row)
	if type(row) ~= "table" then return "" end
	return tostring(row.reported_at or row.last_updated_at or row.updated_at or "")
end

function Policy.canonical_leaderboard(room)
	if type(room) ~= "table" then return nil end
	return room.live_scores or room.leaderboard or room.top_scores
end

function Policy.row_supersedes(previous, incoming)
	if type(incoming) ~= "table" then return false end
	if type(previous) ~= "table" then return true end

	local incomingPlaceholder = incoming.is_placeholder == true
	local previousPlaceholder = previous.is_placeholder == true
	if incomingPlaceholder ~= previousPlaceholder then
		return previousPlaceholder
	end

	local incomingPosition = score_position(incoming)
	local previousPosition = score_position(previous)
	if incomingPosition + 0.001 < previousPosition then
		return false
	end
	if incomingPosition > previousPosition + 0.001 then
		return true
	end

	local incomingUpdatedAt = updated_at(incoming)
	local previousUpdatedAt = updated_at(previous)
	if incomingUpdatedAt ~= "" and previousUpdatedAt ~= "" then
		return incomingUpdatedAt >= previousUpdatedAt
	end

	return true
end

function Policy.sort_rows(rows)
	table.sort(rows, function(left, right)
		local leftPercent = tonumber(left and left.percent) or 0
		local rightPercent = tonumber(right and right.percent) or 0
		if leftPercent ~= rightPercent then
			return leftPercent > rightPercent
		end

		local leftRank = tonumber(left and left.rank)
		local rightRank = tonumber(right and right.rank)
		if leftRank ~= nil and rightRank ~= nil and leftRank ~= rightRank then
			return leftRank < rightRank
		end

		local leftDisplayOrder = tonumber(left and left.display_order)
		local rightDisplayOrder = tonumber(right and right.display_order)
		if leftDisplayOrder ~= nil and rightDisplayOrder ~= nil and leftDisplayOrder ~= rightDisplayOrder then
			return leftDisplayOrder < rightDisplayOrder
		end

		local leftUpdatedAt = updated_at(left)
		local rightUpdatedAt = updated_at(right)
		if leftUpdatedAt ~= rightUpdatedAt then
			return leftUpdatedAt > rightUpdatedAt
		end

		local leftName = tostring(left and left.name or "")
		local rightName = tostring(right and right.name or "")
		if leftName ~= rightName then
			return leftName < rightName
		end

		return tostring(left and left.user_id or "") < tostring(right and right.user_id or "")
	end)

	return rows
end

return Policy
