local player = ...

local playerStats = GetEvaluationPlayerStageStats and GetEvaluationPlayerStageStats(player) or STATSMAN:GetCurStageStats():GetPlayerStageStats(player)
local grade = playerStats:GetGrade()
local grade_path = THEME:GetPathG("", "_grades/"..grade..".lua")

-- "I passd with a q though."
local song = GAMESTATE:GetCurrentSong()
local title = song and song:GetDisplayFullTitle() or ""
if title == "D" then
	grade = "Grade_Tier99"
	grade_path = THEME:GetPathG("", "_grades/"..grade..".lua")
end

-- QUINT
local ex = CalculateExScore(player)
if ex == 100 then
	grade = "Grade_Tier00"
	grade_path = THEME:GetPathG("", "_grades/"..grade..".lua")
end

local t = Def.ActorFrame{}

t[#t+1] = LoadActor(grade_path, playerStats)..{
	Name="LetterGrade",
	InitCommand=function(self)
		self:x(70 * (player==PLAYER_1 and -1 or 1))
		self:y(_screen.cy-134)
		self:draworder(100):ztest(false):zwrite(false):diffuse(Color.White):diffusealpha(1)
	end,
	OnCommand=function(self) self:zoom(0.4) end
}

return t
