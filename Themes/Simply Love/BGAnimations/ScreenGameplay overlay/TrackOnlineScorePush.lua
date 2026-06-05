-- Extra reliability path: remember every score change, then send fixed music-time
-- ticks so every client fills the same leaderboard table rows.

local function primary_enabled_player()
	local enabled = GAMESTATE:GetEnabledPlayers()
	return enabled and enabled[1] or nil
end

local function remember_current_score()
	if not (ITGOnline and ITGOnline.RememberLiveScoreSnapshot and ITGOnline.currentRoomId and ITGOnline.currentRoom) then return end
	local phase = tostring(ITGOnline.currentRoom.phase or "")
	if phase ~= "starting" and phase ~= "playing" then return end

	local snapshot = nil
	if ITGOnline.BuildCurrentScoreSnapshot then
		snapshot = ITGOnline:BuildCurrentScoreSnapshot()
	end
	if type(snapshot) ~= "table" then return end

	ITGOnline:RememberLiveScoreSnapshot(snapshot)
end

return Def.Actor{
	OnCommand=function(self)
		self:queuecommand("FlushOnlineScore")
	end,
	FlushOnlineScoreCommand=function(self)
		remember_current_score()
		if ITGOnline and ITGOnline.QueueLiveScoreTickIfDue then
			ITGOnline:QueueLiveScoreTickIfDue()
		end
		if ITGOnline and ITGOnline.FlushLiveScore then
			ITGOnline:FlushLiveScore()
		end
		self:sleep(0.10):queuecommand("FlushOnlineScore")
	end,
	JudgmentMessageCommand=function(self, params)
		if not (ITGOnline and ITGOnline.RememberLiveScoreSnapshot and ITGOnline.currentRoomId and ITGOnline.currentRoom) then return end

		local primary = primary_enabled_player()
		if primary and params and params.Player and params.Player ~= primary then return end

		local snapshot = nil
		if ITGOnline.BuildCurrentScoreSnapshot then
			snapshot = ITGOnline:BuildCurrentScoreSnapshot()
		end
		snapshot = snapshot or ITGOnline.lastDisplayedScoreSnapshot
		if snapshot then
			ITGOnline:RememberLiveScoreSnapshot(snapshot)
		end
	end,
}
