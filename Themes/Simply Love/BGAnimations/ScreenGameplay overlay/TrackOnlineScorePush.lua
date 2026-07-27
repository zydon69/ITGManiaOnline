-- The sole owner of primary live-score capture and transport.
--
-- Judgment messages are intentionally coalesced into a queued actor command:
-- engine statistics and theme judgment counters have finished updating by the
-- time the snapshot is built.  The transport timer never walks gameplay stats;
-- it only flushes the latest immutable snapshot.

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

local function primary_live_score_finalized()
	if not ITGOnline then return false end
	if ITGOnline.IsPrimaryScoreTransportFinalizedForCurrentRound then
		return ITGOnline:IsPrimaryScoreTransportFinalizedForCurrentRound(
			"track_online_score_push"
		)
	end
	return ITGOnline.IsLiveScoreFinalizedForCurrentRound
		and ITGOnline:IsLiveScoreFinalizedForCurrentRound("track_online_score_push")
end

local function live_score_runtime_active()
	if not (ITGOnline and ITGOnline.currentRoomId and ITGOnline.currentRoom) then
		return false
	end

	local phase = ITGOnline.NormalizeRoomPhase and ITGOnline:NormalizeRoomPhase(ITGOnline.currentRoom.phase) or tostring(ITGOnline.currentRoom.phase or "")
	return phase == "starting" or phase == "playing"
end

local function local_score_transport_complete()
	if not live_score_runtime_active() then return false end
	if not (ITGOnline and ITGOnline.ShouldContinueLocalScoreTransport) then
		return primary_live_score_finalized()
	end
	return not ITGOnline:ShouldContinueLocalScoreTransport("track_online_score_push")
end

local function live_score_playing()
	if not live_score_runtime_active() then return false end
	if primary_live_score_finalized() then return false end
	local phase = ITGOnline.NormalizeRoomPhase and ITGOnline:NormalizeRoomPhase(ITGOnline.currentRoom.phase) or tostring(ITGOnline.currentRoom.phase or "")
	return phase == "playing"
end

local function queue_score_capture(actor, params, source)
	if not (live_score_playing() and ITGOnline and ITGOnline.QueueLiveScore) then
		-- Local gameplay can emit thousands of judgments. It is not an online
		-- failure and must not fill the online diagnostic log.
		if score_trace_enabled()
			and ITGOnline and (ITGOnline.currentRoomId or ITGOnline.currentRoom) then
			online_score_trace(tostring(source or "score")
				.. "_skipped reason=inactive_online_context")
		end
		return
	end

	local primary = primary_enabled_player()
	if primary and params and params.Player and params.Player ~= primary then
		if score_trace_enabled() then
			online_score_trace(tostring(source or "score")
				.. "_skipped reason=non_primary player=" .. tostring(params.Player)
				.. " primary=" .. tostring(primary))
		end
		return
	end

	if not actor.scoreCaptureQueued then
		actor.scoreCaptureQueued = true
		actor:queuecommand("CaptureOnlineScore")
	end
end

return Def.Actor{
	OnCommand=function(self)
		self.scoreCaptureQueued = false
		if local_score_transport_complete() then
			online_score_trace("tracker_off reason=all_local_scores_finalized"
				.. " room=" .. tostring(ITGOnline and ITGOnline.currentRoomId or "nil"), true)
			if ITGOnline and ITGOnline.StopLiveScoreFlush then
				ITGOnline:StopLiveScoreFlush("tracker_all_local_scores_finalized_on")
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
		if local_score_transport_complete() then
			online_score_trace("tracker_stop reason=all_local_scores_finalized"
				.. " room=" .. tostring(ITGOnline and ITGOnline.currentRoomId or "nil"), true)
			if ITGOnline and ITGOnline.StopLiveScoreFlush then
				ITGOnline:StopLiveScoreFlush("tracker_all_local_scores_finalized_flush")
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

		if score_trace_enabled() then
			online_score_trace("flush_tick room=" .. tostring(ITGOnline and ITGOnline.currentRoomId or "nil")
				.. " phase=" .. tostring(ITGOnline and ITGOnline.currentRoom and ITGOnline.currentRoom.phase or "nil")
				.. " hasLastSnapshot=" .. tostring(ITGOnline and ITGOnline.lastDisplayedScoreSnapshot ~= nil))
		end
		if ITGOnline and ITGOnline.TickLiveScoreTransport then
			ITGOnline:TickLiveScoreTransport()
		end
		if not primary_live_score_finalized() and ITGOnline and ITGOnline.FlushLiveScore then
			ITGOnline:FlushLiveScore()
		end
		self:sleep(transportTickSeconds):queuecommand("FlushOnlineScore")
	end,
	CaptureOnlineScoreCommand=function(self)
		self.scoreCaptureQueued = false
		if not (live_score_playing() and ITGOnline and ITGOnline.QueueLiveScore) then
			return
		end

		local snapshot = ITGOnline.BuildCurrentScoreSnapshot
			and ITGOnline:BuildCurrentScoreSnapshot()
			or nil
		if snapshot then
			ITGOnline:QueueLiveScore(snapshot)
			if score_trace_enabled() then
				online_score_trace("judgment_snapshot room=" .. tostring(ITGOnline.currentRoomId or "nil")
					.. " score=" .. tostring(snapshot.scorePercent or snapshot.displayedPercent or "nil")
					.. " combo=" .. tostring(snapshot.combo or "nil"))
			end
		elseif score_trace_enabled() then
			online_score_trace("judgment_skipped reason=no_snapshot")
		end
	end,
	JudgmentMessageCommand=function(self, params)
		queue_score_capture(self, params, "judgment")
	end,
	HoldJudgmentMessageCommand=function(self, params)
		queue_score_capture(self, params, "hold_judgment")
	end,
	ExCountsChangedMessageCommand=function(self, params)
		queue_score_capture(self, params, "ex_counts")
	end,
}
