-- hide the entire ActorFrame (and, thus, its children) in the InitCommand
local af = Def.ActorFrame{
	Name="LetterGradesAF",
	InitCommand=function(self) self:visible(false) end
}

-- how many GradeTiers are defined in Metrics.ini?
local num_grade_tiers = THEME:GetMetric("PlayerStageStats", "NumGradeTiersUsed")
local needed = { Grade_Failed = true }

-- Only load grade actors we actually need for this session's summary rows.
for _, player in ipairs({ PLAYER_1, PLAYER_2 }) do
	local pn = ToEnumShortString(player)
	local stages = SL[pn] and SL[pn].Stages and SL[pn].Stages.Stats or nil
	if stages then
		for _, stats in ipairs(stages) do
			if stats and stats.grade then
				needed[tostring(stats.grade)] = true
			end
		end
	end
end

-- Loop num_grade_tiers times, adding each letter grade Actor to this hidden ActorFrame.
-- We won't show these Actors directly; we may not need them all, or we may need some repeatedly.
-- Instead, we'll have an ActorProxy for each player in each StageStats row that will refer to the
-- appropriate letter grade Actor as needed.
for i=0,num_grade_tiers do
	local tier_string = "Grade_Tier"..string.format("%02d",i)
	if needed[tier_string] then
		af[#af+1] = LoadActor( THEME:GetPathG("", "_grades/"..tier_string..".lua"))..{ Name=tier_string }
	end
end

-- "Failed" is not a grade tier, but players don't need to worry about such details. :)
if needed.Grade_Failed then
	af[#af+1] = LoadActor( THEME:GetPathG("", "_grades/Grade_Failed.lua"))..{ Name="Grade_Failed" }
end

return af
