-- per-player upper half of ScreenEvaluation

local player = ...

return Def.ActorFrame{
	Name=ToEnumShortString(player).."_AF_Upper",
	OnCommand=function(self)
		if player == PLAYER_1 then
			self:x(_screen.cx - 155)
		elseif player == PLAYER_2 then
			self:x(_screen.cx + 155)
		end
	end,

	-- nice
	LoadActor("./nice.lua", player),

	-- stepartist
	LoadActor("./StepArtist.lua", player),

	-- stream breakdown
	((SL and SL[ToEnumShortString(player)] and SL[ToEnumShortString(player)].ActiveModifiers and SL[ToEnumShortString(player)].ActiveModifiers.ShowStreamBreakdown == true)
		and LoadActor("./StreamBreakdown.lua", player)
		or Def.ActorFrame{}),

	-- difficulty text and meter
	LoadActor("./Difficulty.lua", player),

	-- Record Texts (Machine and/or Personal)
	LoadActor("./RecordTexts.lua", player),

	-- Event Progress Box
	LoadActor("./EventProgress.lua", player),

	-- letter grade
	LoadActor("./LetterGrade.lua", player)
}
