-- Pane9 displays GrooveStats RPG leaderboard scores for the stepchart played.

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
	Texture=THEME:GetPathG("", "_VisualStyles/SRPG10/logo_main (doubleres).png"),
	Name="SRPG_Logo",
	InitCommand=function(self)
		self:zoom(0.08):xy(0,120):diffusealpha(0.3)
	end,
}

pane[#pane+1] = LoadActor(THEME:GetPathB("", "_modules/HighScoreList.lua"), args)

return pane
