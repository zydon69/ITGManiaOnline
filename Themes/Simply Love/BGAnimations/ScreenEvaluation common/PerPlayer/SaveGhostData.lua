local player = ...
local pn = ToEnumShortString(player)

if SL.Global.GameMode == "Casual" then return end
if IsAutoplay(player) then return end

local stats = STATSMAN:GetCurStageStats():GetPlayerStageStats(player)
if stats:GetFailed() then return end

local stageStorage = SL[pn].Stages.Stats[SL.Global.Stages.PlayedThisGame + 1]
local ghostData = stageStorage and stageStorage.ghost_data
if type(ghostData) ~= "table" or type(ghostData.itg) ~= "table" or type(ghostData.ex) ~= "table" then return end
if #ghostData.itg == 0 or #ghostData.ex == 0 then return end

local profile_slot = {
	[PLAYER_1] = "ProfileSlot_Player1",
	[PLAYER_2] = "ProfileSlot_Player2",
}

local function ProfileDir()
	local dir = PROFILEMAN:GetProfileDir(profile_slot[player])
	if not dir or dir == "" then return nil end
	return dir
end

local function GhostPath()
	local hash = SL[pn].Streams and SL[pn].Streams.Hash or ""
	if hash == "" then return nil end

	local dir = ProfileDir()
	if not dir then return nil end

	local ghostDir = dir .. "GhostData/"
	return ghostDir .. hash .. ".json"
end

local function ReadExisting(path)
	if not FILEMAN:DoesFileExist(path) then return nil end

	local f = RageFileUtil:CreateRageFile()
	if not f:Open(path, 1) then
		f:destroy()
		return nil
	end

	local ok, data = pcall(JsonDecode, f:Read())
	f:Close()
	f:destroy()

	return ok and type(data) == "table" and data or nil
end

local function LastValue(values)
	return type(values) == "table" and tonumber(values[#values]) or nil
end

local function BestCurve(existing, incoming, key)
	local currentBest = existing and existing[key] or nil
	local currentFinal = LastValue(currentBest)
	local incomingFinal = LastValue(incoming)

	if currentFinal ~= nil and incomingFinal ~= nil and currentFinal >= incomingFinal then
		return currentBest, false
	end
	return incoming, true
end

return Def.Actor{
	OnCommand=function()
		local path = GhostPath()
		if not path then return end

		local existing = ReadExisting(path)
		local output = {}
		local changedItg, changedEx

		output.itg, changedItg = BestCurve(existing, ghostData.itg, "itg")
		output.ex, changedEx = BestCurve(existing, ghostData.ex, "ex")

		if not changedItg and not changedEx then return end

		local f = RageFileUtil:CreateRageFile()
		if f:Open(path, 2) then
			f:Write(JsonEncode(output))
			f:Close()
		end
		f:destroy()
	end
}
