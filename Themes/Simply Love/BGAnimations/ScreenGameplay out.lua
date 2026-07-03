return Def.Quad{
	InitCommand=function(self) self:FullScreen():diffuse(0,0,0,0) end,
	OnCommand=function(self) self:sleep(0.5):linear(1):diffusealpha(1) end,
	OffCommand=function(self)
		if SL.Global.GameMode == "ITG" then
			local song = GAMESTATE:GetCurrentSong()
			local routineShared = IsRoutine and IsRoutine()
			local sourcePlayer = routineShared and GAMESTATE:GetMasterPlayerNumber() or nil
			local stageIndex = SL.Global.Stages.PlayedThisGame + 1
			for player in ivalues( GAMESTATE:GetHumanPlayers() ) do
				local scorePlayer = sourcePlayer or player
				local pn = ToEnumShortString(scorePlayer)
				local pss = routineShared and STATSMAN:GetCurStageStats():GetRoutineStageStats() or STATSMAN:GetCurStageStats():GetPlayerStageStats(player)
				local number = pss:GetTapNoteScores("TapNoteScore_W1")
				local stageStats = SL[pn] and SL[pn].Stages and SL[pn].Stages.Stats and SL[pn].Stages.Stats[stageIndex]
				local exCounts = stageStats and stageStats.ex_counts or {}
				local faPlus = exCounts.W0_total or 0
				-- Subtract FA+ count from the overall fantastic window count.
				local whites = number - faPlus
				-- This will save the white count to Stats.xml, so we can later recover
				-- it when we deprecate FA+ mode and introduce W0.
				--
				-- The Score field is completely unused in Simply Love, and the ability
				-- to set the field is exposed to lua so we can hijack it for our own\
				-- purposes.
				local bestWhites = whites
				if PROFILEMAN:IsPersistentProfile(pn) then
					local steps = GAMESTATE:GetCurrentSteps(scorePlayer)
					local scores = PROFILEMAN:GetProfile(pn):GetHighScoreList(song, steps):GetHighScores()
					for hs in ivalues(scores) do
						-- If the player previously quadded the song, retain the better white count.
						-- Technically this is a workaround because the date would be wrong, but
						-- it's still worth to keep the score around
						if (pss:GetPercentDancePoints() == hs:GetPercentDP() and hs:GetPercentDP() == 1.0) then
							bestWhites = math.min(bestWhites, hs:GetScore())
						end
					end
				end
				pss:SetScore(bestWhites)
			end
		end
	end
}
