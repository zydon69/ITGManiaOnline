ITGOnlineScoreJudgments = ITGOnlineScoreJudgments or {}

local Judgments = ITGOnlineScoreJudgments

local judgment_keys = {
	"fantastic",
	"excellent",
	"great",
	"decent",
	"way_off",
	"miss",
	"mine",
	"hold_ok",
	"hold_ng",
}

local function count(value)
	value = tonumber(value)
	if not value or value ~= value or value == math.huge or value == -math.huge then
		return 0
	end
	return math.max(0, math.floor(value))
end

function Judgments.build(tapCounts, holdCounts)
	tapCounts = type(tapCounts) == "table" and tapCounts or {}
	holdCounts = type(holdCounts) == "table" and holdCounts or {}

	return {
		fantastic = count(tapCounts.W0) + count(tapCounts.W1),
		excellent = count(tapCounts.W2),
		great = count(tapCounts.W3),
		decent = count(tapCounts.W4),
		way_off = count(tapCounts.W5),
		miss = count(tapCounts.Miss),
		mine = count(tapCounts.Mines),
		hold_ok = count(holdCounts.Held),
		hold_ng = count(holdCounts.LetGo) + count(holdCounts.MissedHold),
	}
end

function Judgments.copy(judgments)
	local copy = {}
	for _, key in ipairs(judgment_keys) do
		copy[key] = count(type(judgments) == "table" and judgments[key] or nil)
	end
	return copy
end

function Judgments.merge_monotonic(current, previous)
	local merged = Judgments.copy(current)
	local restored = {}

	for _, key in ipairs(judgment_keys) do
		local previousCount = count(type(previous) == "table" and previous[key] or nil)
		if previousCount > merged[key] then
			restored[#restored + 1] = key .. ":" .. tostring(merged[key]) .. "->" .. tostring(previousCount)
			merged[key] = previousCount
		end
	end

	return merged, restored
end

return Judgments
