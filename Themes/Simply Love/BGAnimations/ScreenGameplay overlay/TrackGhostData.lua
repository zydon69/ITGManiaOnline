-- Track per-judgment ITG/EX point curves for local ghost-data targets.
-- This is intentionally logic-only: it does not alter engine scoring.

if SL.Global.GameMode == "Casual" then return end

local player = ...
local pn = ToEnumShortString(player)
local stats = STATSMAN:GetCurStageStats():GetPlayerStageStats(player)
local stageStorage = SL[pn].Stages.Stats[SL.Global.Stages.PlayedThisGame + 1]
local mods = SL[pn].ActiveModifiers

local currentItgPoints = 0
local currentExCounts = {
	W0 = 0,
	W010 = 0,
	W1 = 0,
	W110 = 0,
	W2 = 0,
	W3 = 0,
	W4 = 0,
	W5 = 0,
	Miss = 0,
	HitMine = 0,
	Held = 0,
	LetGo = 0,
}

local validTapScores = {
	W1 = true,
	W2 = true,
	W3 = true,
	W4 = true,
	W5 = true,
	Miss = true,
	HitMine = true,
}

local validHoldScores = {
	Held = true,
	LetGo = true,
	MissedHold = true,
}

local function ActiveGhostTarget()
	return tonumber(mods.TargetScore) == 19
end

local function ProfileDir()
	local profile_slot = {
		[PLAYER_1] = "ProfileSlot_Player1",
		[PLAYER_2] = "ProfileSlot_Player2",
	}
	local dir = PROFILEMAN:GetProfileDir(profile_slot[player])
	if not dir or dir == "" then return nil end
	return dir
end

local function GhostPath()
	local hash = SL[pn].Streams and SL[pn].Streams.Hash or ""
	if hash == "" then return nil end

	local dir = ProfileDir()
	if not dir then return nil end
	return dir .. "GhostData/" .. hash .. ".json"
end

local function ReadGhostCurve()
	local path = GhostPath()
	if not path or not FILEMAN:DoesFileExist(path) then return nil end

	local f = RageFileUtil:CreateRageFile()
	if not f:Open(path, 1) then
		f:destroy()
		return nil
	end

	local ok, data = pcall(JsonDecode, f:Read())
	f:Close()
	f:destroy()

	if not ok or type(data) ~= "table" then return nil end
	local key = mods.ShowExScore and "ex" or "itg"
	return type(data[key]) == "table" and data[key] or nil
end

local ghostCurve = nil
local hasGhostData = false

local function ItgWeight(scoreKey)
	local key = "GradeWeight" .. scoreKey
	local weights = SL.Metrics and SL.Metrics[SL.Global.GameMode]
	return weights and weights[key] or 0
end

local function AppendCurrentScores()
	stageStorage.ghost_data = stageStorage.ghost_data or { itg = {}, ex = {} }
	stageStorage.ghost_data.itg[#stageStorage.ghost_data.itg + 1] = currentItgPoints

	local _, exPoints = CalculateExScore(player, currentExCounts)
	stageStorage.ghost_data.ex[#stageStorage.ghost_data.ex + 1] = exPoints or 0

	if ActiveGhostTarget() and hasGhostData and ghostCurve then
		local index = mods.ShowExScore and #stageStorage.ghost_data.ex or #stageStorage.ghost_data.itg
		local current = mods.ShowExScore and (exPoints or 0) or currentItgPoints
		local target = ghostCurve[index]
		if target ~= nil then
			local _, _, possible = CalculateExScore(player, currentExCounts)
			if not mods.ShowExScore then possible = stats:GetPossibleDancePoints() end
			MESSAGEMAN:Broadcast("GhostDataUpdated", {
				player=player,
				current=current,
				target=target,
				possible=possible or 0
			})
		end
	end
end

return Def.Actor{
	OnCommand=function()
		stageStorage.ghost_data = { itg = {}, ex = {} }
		if ActiveGhostTarget() then
			ghostCurve = ReadGhostCurve()
			hasGhostData = ghostCurve ~= nil and #ghostCurve > 0
			if not hasGhostData then
				MESSAGEMAN:Broadcast("NoGhostData", { player=player })
			end
		end
	end,

	JudgmentMessageCommand=function(_, params)
		if params.Player ~= player or IsAutoplay(player) then return end

		if params.HoldNoteScore then
			local hns = ToEnumShortString(params.HoldNoteScore)
			if validHoldScores[hns] then
				if hns == "MissedHold" then hns = "LetGo" end
				if not stats:GetFailed() then
					currentItgPoints = currentItgPoints + ItgWeight(hns)
					currentExCounts[hns] = (currentExCounts[hns] or 0) + 1
				end
				AppendCurrentScores()
			end
			return
		end

		if params.TapNoteScore then
			local tns = ToEnumShortString(params.TapNoteScore)
			if not validTapScores[tns] then return end

			if not stats:GetFailed() then
				currentItgPoints = currentItgPoints + ItgWeight(tns)

				if SL.Global.GameMode == "ITG" and tns == "W1" then
					if IsW010Judgment(params, player) then
						currentExCounts.W0 = currentExCounts.W0 + 1
						currentExCounts.W010 = currentExCounts.W010 + 1
					elseif IsW0Judgment(params, player) then
						currentExCounts.W0 = currentExCounts.W0 + 1
						currentExCounts.W110 = currentExCounts.W110 + 1
					else
						currentExCounts.W1 = currentExCounts.W1 + 1
						currentExCounts.W110 = currentExCounts.W110 + 1
					end
				else
					currentExCounts[tns] = (currentExCounts[tns] or 0) + 1
				end
			end
			AppendCurrentScores()
		end
	end,
}
