if SL.Global.GameMode == "Casual" then return end

local player = ...
local pn = ToEnumShortString(player)
local sourcePlayer = GetRoutineSourcePlayer and GetRoutineSourcePlayer(player) or player
local routineMirror = IsRoutine and IsRoutine() and player ~= sourcePlayer

local pss = GetEvaluationPlayerStageStats and GetEvaluationPlayerStageStats(player) or STATSMAN:GetCurStageStats():GetPlayerStageStats(player)

local HighScoreIndex = {
	Machine =  pss:GetMachineHighScoreIndex(),
	Personal = pss:GetPersonalHighScoreIndex()
}

-- ---------------------------------------------
-- GetMachineHighScoreIndex() will always return -1 in EventMode, so...

local SongOrCourse = GAMESTATE:IsCourseMode() and GAMESTATE:GetCurrentCourse() or GAMESTATE:GetCurrentSong()
local StepsOrTrail = GAMESTATE:IsCourseMode() and GAMESTATE:GetCurrentTrail(sourcePlayer) or GAMESTATE:GetCurrentSteps(sourcePlayer)

local MaxMachineHighScores = PREFSMAN:GetPreference("MaxHighScoresPerListForMachine")
local MachineHighScoreList = SongOrCourse and StepsOrTrail and PROFILEMAN:GetMachineProfile():GetHighScoreList(SongOrCourse, StepsOrTrail) or nil
local MachineHighScores = MachineHighScoreList and MachineHighScoreList:GetHighScores() or {}

local EarnedMachineHighScoreInEventMode = function()
	-- if no DancePoints were earned, it's not a HighScore
	if pss:GetPercentDancePoints() <= 0.01 then return false end
	-- if DancePoints were earned, and no MachineHighScores exist, it's a HighScore
	if #MachineHighScores < 1 then return true end
	-- otherwise, check if this score is better than the worst current HighScore retrieved from MachineProfile
	return pss:GetHighScore():GetPercentDP() >= MachineHighScores[math.min(MaxMachineHighScores, #MachineHighScores)]:GetPercentDP()
end

-- FIXME: This approach is bizarre and heavily flawed + limited.
--        GetMachineHighScoreIndex() should really be patched in the SM5 engine.
local MachineHighScoreIndexInEventMode = function()
	local index = -1
	local playerProfile = PROFILEMAN:GetProfile(sourcePlayer)
	local lastUsedName = playerProfile and playerProfile:GetLastUsedHighScoreName() or ""

	for i, highscore in ipairs(MachineHighScores) do
		local name = pss:GetHighScore():GetName()

	 	if  pss:GetHighScore():GetScore() == highscore:GetScore()
		and pss:GetHighScore():GetDate()  == highscore:GetDate()
		and
		(
			name == lastUsedName
			or
			(
				(#GAMESTATE:GetHumanPlayers()==1 and name=="EVNT")
				or (not (IsRoutine and IsRoutine()) and highscore:GetScore() ~= STATSMAN:GetPlayedStageStats(1):GetPlayerStageStats(OtherPlayer[player]):GetHighScore():GetScore())
			)
		)
		then
			index = i-1
			break
		end
	end

	return index
end

if GAMESTATE:IsEventMode() then
	HighScoreIndex.Machine = MachineHighScoreIndexInEventMode()
end

-- ---------------------------------------------

local EarnedMachineRecord  = GAMESTATE:IsEventMode() and EarnedMachineHighScoreInEventMode() or ((HighScoreIndex.Machine ~= -1) and pss:GetPercentDancePoints() >= 0.01)
local EarnedPersonalRecord = ( HighScoreIndex.Personal ~= -1 ) and pss:GetPercentDancePoints() >= 0.01

-- ---------------------------------------------

-- this player earned some record and the ability to enter a high score name
-- we'll check for this flag later in ./BGAnimations/ScreenNameEntryTradtional underlay/default.lua
if (EarnedMachineRecord or EarnedPersonalRecord) and not routineMirror then
	SL[pn].HighScores = SL[pn].HighScores or {}
	SL[pn].HighScores.EnteringName = true
end

-- We always want to return this actor frame in case we need to "hijack" it for GrooveStats functionality.
local t = Def.ActorFrame{
	Name="RecordTexts",
	InitCommand=function(self) self:zoom(0.225) end,
	OnCommand=function(self)
		self:x( player == PLAYER_1 and -45 or 95 )
		self:y( 54 )
	end
}

t[#t+1] = LoadFont("Common Bold")..{
	Name="MachineRecord",
	InitCommand=function(self) self:xy(-110,-18):diffuse(PlayerColor(player)) end,
	OnCommand=function(self)
		if EarnedMachineRecord and HighScoreIndex.Machine+1 > 0 then
			self:settext(ScreenString("MachineRecord"):format(HighScoreIndex.Machine+1))
		end
	end,
}

t[#t+1] = LoadFont("Common Bold")..{
	Name="PersonalRecord",
	InitCommand=function(self) self:xy(-110,24):diffuse(PlayerColor(player)) end,
	OnCommand=function(self)
		if EarnedPersonalRecord and HighScoreIndex.Personal+1 > 0 then
			self:settext(ScreenString("PersonalRecord"):format(HighScoreIndex.Personal+1))
		end
	end,
}

return t
