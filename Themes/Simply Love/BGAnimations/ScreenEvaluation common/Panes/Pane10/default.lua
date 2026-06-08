-- Pane10 displays GrooveStats ITL leaderboard scores for the stepchart played.

if not IsServiceAllowed(SL.GrooveStats.AutoSubmit) then return end

local player = unpack(...)

local pane = Def.ActorFrame{
	InitCommand=function(self)
		self:y(_screen.cy - 62):zoom(0.8)
	end
}

local args = { Player=player, RowHeight=22, HideScores=true }
args.NumHighScores = 10

pane[#pane+1] = Def.Sprite{
	Texture=THEME:GetPathG("", "ITL.png"),
	Name="ITL_Logo",
	InitCommand=function(self)
		self:zoom(1):xy(0,120):diffusealpha(0.15)
	end,
}

pane[#pane+1] = LoadActor(THEME:GetPathB("", "_modules/HighScoreList.lua"), args)

return pane
