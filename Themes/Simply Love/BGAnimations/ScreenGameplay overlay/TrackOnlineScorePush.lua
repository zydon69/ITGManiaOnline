-- Extra reliability path: push live score whenever judgments update gameplay state.
-- This runs independently from score text visibility/layout.

local function primary_enabled_player()
	local enabled = GAMESTATE:GetEnabledPlayers()
	return enabled and enabled[1] or nil
end

local function snapshot_key(snapshot)
	if type(snapshot) ~= "table" then return "" end

	return table.concat({
		string.format("%.4f", tonumber(snapshot.displayedPercent or snapshot.DisplayedPercent) or 0),
		string.format("%.4f", tonumber(snapshot.scorePercent or snapshot.ScorePercent) or 0),
		string.format("%.4f", tonumber(snapshot.exScorePercent or snapshot.ExScorePercent) or 0),
		tostring(math.floor(tonumber(snapshot.combo or snapshot.Combo) or 0)),
	}, "|")
end

local function lbtrace(message)
	if not (ITGOnline and ITGOnline.debugLeaderboardTrace == true) then return end
	if online_trace then
		online_trace("LBTRACE client_push " .. tostring(message or ""))
	end
end

local function queue_current_score_if_changed(actor)
	if not (ITGOnline and ITGOnline.QueueLiveScore and ITGOnline.currentRoomId and ITGOnline.currentRoom) then return end
	if tostring(ITGOnline.currentRoom.phase or "") ~= "playing" then return end

	local snapshot = nil
	if ITGOnline.BuildCurrentScoreSnapshot then
		snapshot = ITGOnline:BuildCurrentScoreSnapshot()
	end
	if type(snapshot) ~= "table" then return end

	local key = snapshot_key(snapshot)
	if key ~= "" and key ~= actor.lastOnlineScoreSnapshotKey then
		actor.lastOnlineScoreSnapshotKey = key
		lbtrace(string.format(
			"room=%s kind=periodic displayed=%.3f score=%.3f ex=%.3f combo=%d key=%s",
			tostring(ITGOnline and ITGOnline.currentRoomId or ""),
			tonumber(snapshot.displayedPercent or snapshot.DisplayedPercent) or -1,
			tonumber(snapshot.scorePercent or snapshot.ScorePercent) or -1,
			tonumber(snapshot.exScorePercent or snapshot.ExScorePercent) or -1,
			math.floor(tonumber(snapshot.combo or snapshot.Combo) or 0),
			tostring(key)
		))
		ITGOnline:QueueLiveScore(snapshot)
	end
end

return Def.Actor{
	OnCommand=function(self)
		self.lastOnlineScoreSnapshotKey = ""
		self:queuecommand("FlushOnlineScore")
	end,
	FlushOnlineScoreCommand=function(self)
		queue_current_score_if_changed(self)
		if ITGOnline and ITGOnline.FlushLiveScore then
			ITGOnline:FlushLiveScore()
		end
		self:sleep(0.20):queuecommand("FlushOnlineScore")
	end,
	JudgmentMessageCommand=function(self, params)
		if not (ITGOnline and ITGOnline.QueueLiveScore and ITGOnline.currentRoomId and ITGOnline.currentRoom) then return end

		local primary = primary_enabled_player()
		if primary and params and params.Player and params.Player ~= primary then return end

		local snapshot = nil
		if ITGOnline.BuildCurrentScoreSnapshot then
			snapshot = ITGOnline:BuildCurrentScoreSnapshot()
		end
		snapshot = snapshot or ITGOnline.lastDisplayedScoreSnapshot
		if snapshot then
			self.lastOnlineScoreSnapshotKey = snapshot_key(snapshot)
			lbtrace(string.format(
				"room=%s kind=judgment displayed=%.3f score=%.3f ex=%.3f combo=%d key=%s",
				tostring(ITGOnline and ITGOnline.currentRoomId or ""),
				tonumber(snapshot.displayedPercent or snapshot.DisplayedPercent) or -1,
				tonumber(snapshot.scorePercent or snapshot.ScorePercent) or -1,
				tonumber(snapshot.exScorePercent or snapshot.ExScorePercent) or -1,
				math.floor(tonumber(snapshot.combo or snapshot.Combo) or 0),
				tostring(self.lastOnlineScoreSnapshotKey or "")
			))
			ITGOnline:QueueLiveScore(snapshot)
			if ITGOnline.FlushLiveScore then
				ITGOnline:FlushLiveScore()
			end
		end
	end,
}
