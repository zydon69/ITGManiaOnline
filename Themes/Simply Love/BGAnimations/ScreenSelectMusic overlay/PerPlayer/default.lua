local t = Def.ActorFrame{
	Name="PerPlayer"
}

-- Always instantiate per-player actors for every side.  Some online/profile flows
-- can join or restore players after this overlay is initialized; individual actors
-- already handle visibility based on GAMESTATE, so pruning them here can leave the
-- left-side song info, chart grid cursor, or scorebox permanently absent.
for player in ivalues( PlayerNumber ) do
	t[#t+1] = LoadActor("./DensityGraph.lua", player)
	-- AuthorCredit, Description, and ChartName associated with the current stepchart
	t[#t+1] = LoadActor("./StepArtist.lua", player)
	t[#t+1] = LoadActor("./Scorebox.lua", player)
end

-- Bouncing cursor inside the grid of difficulty blocks. These should be on top of both of the other elements.
for player in ivalues( PlayerNumber ) do
	t[#t+1] = LoadActor("./Cursor.lua", player)
end

return t
