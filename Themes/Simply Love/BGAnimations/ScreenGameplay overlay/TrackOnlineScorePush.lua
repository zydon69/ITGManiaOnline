-- Extra reliability path: remember every score change, then send fixed music-time
-- ticks so every client fills the same leaderboard table rows.

local function primary_enabled_player()
	local enabled = GAMESTATE:GetEnabledPlayers()
	return enabled and enabled[1] or nil
end

local onlineScoreTraceLastAt = 0
local onlineScoreTraceSuppressed = 0

local function online_score_trace(message, force)
	if not (ITGOnline and (ITGOnline.debugOnlineTrace == true or ITGOnline.debugReadyFlow == true)) then
		return
	end
	local now = GetTimeSinceStart and GetTimeSinceStart() or 0
	if not force and now - onlineScoreTraceLastAt < 1.5 then
		onlineScoreTraceSuppressed = onlineScoreTraceSuppressed + 1
		return
	end
	local suffix = onlineScoreTraceSuppressed > 0 and (" suppressed=" .. tostring(onlineScoreTraceSuppressed)) or ""
	onlineScoreTraceSuppressed = 0
	onlineScoreTraceLastAt = now
	local line = "ITG Online: FLOW gameplay_score " .. tostring(message or "") .. suffix
	if Trace then Trace(line) elseif Warn then Warn(line) end
end

local function remember_current_score()
	if not (ITGOnline and ITGOnline.RememberLiveScoreSnapshot and ITGOnline.currentRoomId and ITGOnline.currentRoom) then
		online_score_trace("remember_skipped reason=missing_context"
			.. " hasClient=" .. tostring(ITGOnline ~= nil)
			.. " hasRememberApi=" .. tostring(ITGOnline and ITGOnline.RememberLiveScoreSnapshot ~= nil)
			.. " room=" .. tostring(ITGOnline and ITGOnline.currentRoomId or "nil")
			.. " hasRoom=" .. tostring(ITGOnline and ITGOnline.currentRoom ~= nil))
		return
	end
	local phase = tostring(ITGOnline.currentRoom.phase or "")
	if phase ~= "playing" then
		online_score_trace("remember_skipped reason=phase_not_playing phase=" .. tostring(phase)
			.. " room=" .. tostring(ITGOnline.currentRoomId or "nil"))
		return
	end

	local snapshot = nil
	if ITGOnline.BuildCurrentScoreSnapshot then
		snapshot = ITGOnline:BuildCurrentScoreSnapshot()
	end
	if type(snapshot) ~= "table" then
		online_score_trace("remember_skipped reason=no_snapshot room=" .. tostring(ITGOnline.currentRoomId or "nil"))
		return
	end

	ITGOnline:RememberLiveScoreSnapshot(snapshot)
	online_score_trace("remember_snapshot room=" .. tostring(ITGOnline.currentRoomId or "nil")
		.. " score=" .. tostring(snapshot.scorePercent or snapshot.displayedPercent or "nil")
		.. " combo=" .. tostring(snapshot.combo or "nil"))
end

return Def.Actor{
	OnCommand=function(self)
		online_score_trace("tracker_on room=" .. tostring(ITGOnline and ITGOnline.currentRoomId or "nil"), true)
		self:queuecommand("FlushOnlineScore")
	end,
	FlushOnlineScoreCommand=function(self)
		remember_current_score()
		online_score_trace("flush_tick room=" .. tostring(ITGOnline and ITGOnline.currentRoomId or "nil")
			.. " phase=" .. tostring(ITGOnline and ITGOnline.currentRoom and ITGOnline.currentRoom.phase or "nil")
			.. " hasLastSnapshot=" .. tostring(ITGOnline and ITGOnline.lastDisplayedScoreSnapshot ~= nil))
		if ITGOnline and ITGOnline.QueueLiveScoreTickIfDue then
			ITGOnline:QueueLiveScoreTickIfDue()
		end
		if ITGOnline and ITGOnline.FlushLiveScore then
			ITGOnline:FlushLiveScore()
		end
		self:sleep(0.10):queuecommand("FlushOnlineScore")
	end,
	JudgmentMessageCommand=function(self, params)
		if not (ITGOnline and ITGOnline.RememberLiveScoreSnapshot and ITGOnline.currentRoomId and ITGOnline.currentRoom) then
			online_score_trace("judgment_skipped reason=missing_context")
			return
		end
		if tostring(ITGOnline.currentRoom.phase or "") ~= "playing" then
			online_score_trace("judgment_skipped reason=phase_not_playing phase=" .. tostring(ITGOnline.currentRoom.phase or "nil"))
			return
		end

		local primary = primary_enabled_player()
		if primary and params and params.Player and params.Player ~= primary then
			online_score_trace("judgment_skipped reason=non_primary player=" .. tostring(params.Player)
				.. " primary=" .. tostring(primary))
			return
		end

		local snapshot = nil
		if ITGOnline.BuildCurrentScoreSnapshot then
			snapshot = ITGOnline:BuildCurrentScoreSnapshot()
		end
		snapshot = snapshot or ITGOnline.lastDisplayedScoreSnapshot
		if snapshot then
			ITGOnline:RememberLiveScoreSnapshot(snapshot)
			online_score_trace("judgment_snapshot room=" .. tostring(ITGOnline.currentRoomId or "nil")
				.. " score=" .. tostring(snapshot.scorePercent or snapshot.displayedPercent or "nil")
				.. " combo=" .. tostring(snapshot.combo or "nil"))
		else
			online_score_trace("judgment_skipped reason=no_snapshot")
		end
	end,
}
