-- Extra reliability path: remember every score change, then send fixed music-time
-- ticks so every client fills the same leaderboard table rows.

local function primary_enabled_player()
	local enabled = GAMESTATE:GetEnabledPlayers()
	return enabled and enabled[1] or nil
end

local onlineScoreTraceLastAt = 0
local onlineScoreTraceSuppressed = 0
local transportTickSeconds = 0.25

local function score_trace_enabled()
	return ITGOnline ~= nil and ITGOnline.debugScoreTrace == true
end

local function online_score_trace(message, force)
	if not score_trace_enabled() then return end
	local now = GetTimeSinceStart and GetTimeSinceStart() or 0
	if not force and now - onlineScoreTraceLastAt < 1.5 then
		onlineScoreTraceSuppressed = onlineScoreTraceSuppressed + 1
		return
	end
	local suffix = onlineScoreTraceSuppressed > 0 and (" suppressed=" .. tostring(onlineScoreTraceSuppressed)) or ""
	onlineScoreTraceSuppressed = 0
	onlineScoreTraceLastAt = now
	local line = "FLOW gameplay_score " .. tostring(message or "") .. suffix
	if type(online_trace) == "function" then
		online_trace(line, "score")
	end
end

local function live_score_finalized()
	return ITGOnline and ITGOnline.IsLiveScoreFinalizedForCurrentRound
		and ITGOnline:IsLiveScoreFinalizedForCurrentRound("track_online_score_push")
end

local function live_score_runtime_active()
	if not (ITGOnline and ITGOnline.currentRoomId and ITGOnline.currentRoom) then
		return false
	end

	local phase = ITGOnline.NormalizeRoomPhase and ITGOnline:NormalizeRoomPhase(ITGOnline.currentRoom.phase) or tostring(ITGOnline.currentRoom.phase or "")
	return phase == "starting" or phase == "playing"
end

local function live_score_playing()
	if not live_score_runtime_active() then return false end
	if live_score_finalized() then return false end
	local phase = ITGOnline.NormalizeRoomPhase and ITGOnline:NormalizeRoomPhase(ITGOnline.currentRoom.phase) or tostring(ITGOnline.currentRoom.phase or "")
	return phase == "playing"
end

local function remember_current_score()
	if not (live_score_playing() and ITGOnline.RememberLiveScoreSnapshot) then
		if score_trace_enabled() then
			online_score_trace("remember_skipped reason=missing_context"
				.. " hasClient=" .. tostring(ITGOnline ~= nil)
				.. " hasRememberApi=" .. tostring(ITGOnline and ITGOnline.RememberLiveScoreSnapshot ~= nil)
				.. " room=" .. tostring(ITGOnline and ITGOnline.currentRoomId or "nil")
				.. " hasRoom=" .. tostring(ITGOnline and ITGOnline.currentRoom ~= nil))
		end
		return
	end

	local snapshot = ITGOnline.lastDisplayedScoreSnapshot
	if type(snapshot) ~= "table" then
		if score_trace_enabled() then
			online_score_trace("remember_skipped reason=no_snapshot room="
				.. tostring(ITGOnline.currentRoomId or "nil"))
		end
		return
	end

	ITGOnline:RememberLiveScoreSnapshot(snapshot)
	if score_trace_enabled() then
		online_score_trace("remember_snapshot room=" .. tostring(ITGOnline.currentRoomId or "nil")
			.. " score=" .. tostring(snapshot.scorePercent or snapshot.displayedPercent or "nil")
			.. " combo=" .. tostring(snapshot.combo or "nil"))
	end
end

return Def.Actor{
	OnCommand=function(self)
		if live_score_finalized() then
			online_score_trace("tracker_off reason=final_score_already_accepted"
				.. " room=" .. tostring(ITGOnline and ITGOnline.currentRoomId or "nil"), true)
			if ITGOnline and ITGOnline.StopLiveScoreFlush then
				ITGOnline:StopLiveScoreFlush("tracker_finalized_on")
			end
			return
		end
		if not live_score_runtime_active() then
			online_score_trace("tracker_off reason=local_or_inactive_room"
				.. " room=" .. tostring(ITGOnline and ITGOnline.currentRoomId or "nil")
				.. " hasRoom=" .. tostring(ITGOnline and ITGOnline.currentRoom ~= nil), true)
			if ITGOnline and ITGOnline.StopLiveScoreFlush then
				ITGOnline:StopLiveScoreFlush("tracker_inactive_on")
			end
			return
		end
		online_score_trace("tracker_on room=" .. tostring(ITGOnline and ITGOnline.currentRoomId or "nil"), true)
		self:queuecommand("FlushOnlineScore")
	end,
	FlushOnlineScoreCommand=function(self)
		if live_score_finalized() then
			online_score_trace("tracker_stop reason=final_score_already_accepted"
				.. " room=" .. tostring(ITGOnline and ITGOnline.currentRoomId or "nil"), true)
			if ITGOnline and ITGOnline.StopLiveScoreFlush then
				ITGOnline:StopLiveScoreFlush("tracker_finalized_flush")
			end
			return
		end
		if not live_score_runtime_active() then
			online_score_trace("tracker_stop reason=local_or_inactive_room"
				.. " room=" .. tostring(ITGOnline and ITGOnline.currentRoomId or "nil")
				.. " hasRoom=" .. tostring(ITGOnline and ITGOnline.currentRoom ~= nil), true)
			if ITGOnline and ITGOnline.StopLiveScoreFlush then
				ITGOnline:StopLiveScoreFlush("tracker_inactive_flush")
			end
			return
		end

		-- Judgment messages own snapshot construction. The timer only transports
		-- the last immutable snapshot, avoiding a full stats walk every 100 ms.
		remember_current_score()
		if score_trace_enabled() then
			online_score_trace("flush_tick room=" .. tostring(ITGOnline and ITGOnline.currentRoomId or "nil")
				.. " phase=" .. tostring(ITGOnline and ITGOnline.currentRoom and ITGOnline.currentRoom.phase or "nil")
				.. " hasLastSnapshot=" .. tostring(ITGOnline and ITGOnline.lastDisplayedScoreSnapshot ~= nil))
		end
		if ITGOnline and ITGOnline.QueueLiveScoreTickIfDue then
			ITGOnline:QueueLiveScoreTickIfDue()
		end
		if ITGOnline and ITGOnline.FlushLiveScore then
			ITGOnline:FlushLiveScore()
		end
		self:sleep(transportTickSeconds):queuecommand("FlushOnlineScore")
	end,
	JudgmentMessageCommand=function(self, params)
		if not (live_score_playing() and ITGOnline.RememberLiveScoreSnapshot) then
			-- Local gameplay can emit thousands of judgments.  It is not an
			-- online failure and must not fill the online diagnostic log.
			if ITGOnline and (ITGOnline.currentRoomId or ITGOnline.currentRoom) then
				online_score_trace("judgment_skipped reason=inactive_online_context")
			end
			return
		end

		local primary = primary_enabled_player()
		if primary and params and params.Player and params.Player ~= primary then
			if score_trace_enabled() then
				online_score_trace("judgment_skipped reason=non_primary player=" .. tostring(params.Player)
					.. " primary=" .. tostring(primary))
			end
			return
		end

		local snapshot = nil
		if ITGOnline.BuildCurrentScoreSnapshot then
			snapshot = ITGOnline:BuildCurrentScoreSnapshot()
		end
		snapshot = snapshot or ITGOnline.lastDisplayedScoreSnapshot
		if snapshot then
			ITGOnline:RememberLiveScoreSnapshot(snapshot)
			if score_trace_enabled() then
				online_score_trace("judgment_snapshot room=" .. tostring(ITGOnline.currentRoomId or "nil")
					.. " score=" .. tostring(snapshot.scorePercent or snapshot.displayedPercent or "nil")
					.. " combo=" .. tostring(snapshot.combo or "nil"))
			end
		elseif score_trace_enabled() then
			online_score_trace("judgment_skipped reason=no_snapshot")
		end
	end,
}
