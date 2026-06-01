local t = Def.ActorFrame{}
local human = {}
for player in ivalues(GAMESTATE:GetHumanPlayers()) do
	human[player] = true
end

-- These are among the heaviest per-player overlays on ScreenSelectMusic.
-- Keep them scoped to currently joined players to reduce load spikes.
for player in ivalues( PlayerNumber ) do
	if human[player] then
		t[#t+1] = LoadActor("./DensityGraph.lua", player)
		-- AuthorCredit, Description, and ChartName associated with the current stepchart
		t[#t+1] = LoadActor("./StepArtist.lua", player)
	end
end

-- Bouncing cursor inside the grid of difficulty blocks. These should be on top of both of the other elements.
for player in ivalues( PlayerNumber ) do
	if human[player] then
		t[#t+1] = LoadActor("./Cursor.lua", player)
	end
end

return t
