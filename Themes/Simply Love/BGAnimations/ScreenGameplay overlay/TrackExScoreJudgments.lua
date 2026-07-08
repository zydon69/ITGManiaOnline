-- In this file, we're keep track of judgment counts for calculating the EX score to display during
-- ScreenGameplay and ScreeEvaluation.
--
-- Similar to PerColumnJudgmentTracking.lua, this file doesn't override or recreate the engine's
-- judgment system in any way. It just allows transient judgment data to persist beyond ScreenGameplay.
------------------------------------------------------------

-- don't bother tracking for Casual gamemode
if SL.Global.GameMode == "Casual" then return end

local player = ...
local routineShared = IsRoutine and IsRoutine()
local sourcePlayer = routineShared and GAMESTATE:GetMasterPlayerNumber() or player
if routineShared and player ~= sourcePlayer then return end

local stats = routineShared and STATSMAN:GetCurStageStats():GetRoutineStageStats() or STATSMAN:GetCurStageStats():GetPlayerStageStats(player)
local sourcePn = ToEnumShortString(sourcePlayer)
local stageIndex = math.max(1, math.floor(tonumber(SL.Global.Stages.PlayedThisGame) or 0) + 1)
local mods = SL[sourcePn].ActiveModifiers

local function current_stage_storage()
	SL[sourcePn].Stages = SL[sourcePn].Stages or {}
	SL[sourcePn].Stages.Stats = SL[sourcePn].Stages.Stats or {}
	SL[sourcePn].Stages.Stats[stageIndex] = SL[sourcePn].Stages.Stats[stageIndex] or {}
	return SL[sourcePn].Stages.Stats[stageIndex]
end

local storage = current_stage_storage()

local valid_tns = {
	-- Emulated, not a real TNS.
	W0 = true,
	W010 = true,
	W110 = true,

	-- Actual TNS's
	W1 = true,
	W2 = true,
	W3 = true,
	W4 = true,
	W5 = true,
	Miss = true,
	HitMine = true
}

local valid_hns = {
	LetGo = true,
	Held = true
}

local function fresh_ex_counts()
	return {
		-- These counts are only tracked while a player hasn't failed.
		-- This is so that the EX score stops changing once they've failed.
		W0 = 0,
		W010 = 0,
		W1 = 0,
		W110 = 0,
		W2 = 0,
		W3 = 0,
		W4 = 0,
		W5 = 0,
		Miss = 0,
		HitMine = 0,
		-- Hold and rolls are tracked together here since they're covered by
		-- the HoldNoteScore.
		Held = 0,
		LetGo = 0,

		-- The W0 count displayed in the pane in ScreenEvaluation should
		-- still display the total count (whether or not the player has failed).
		-- Track that separately.
		W0_total = 0,
		W010_total = 0,

		-- Some course/marathon screens expose a Trail with zero radar totals
		-- during gameplay. Keep a fallback denominator so live EX/HardEX can
		-- still be calculated against the whole course when possible.
		totalSteps = 0,
		totalHolds = 0,
		totalRolls = 0,
		possible_song_indexes = {},
		possible_source = "unset"
	}
end

local function ensure_ex_counts()
	storage = current_stage_storage()
	if type(storage.ex_counts) ~= "table" then
		storage.ex_counts = fresh_ex_counts()
		return
	end

	for key, value in pairs(fresh_ex_counts()) do
		if storage.ex_counts[key] == nil then
			storage.ex_counts[key] = value
		end
	end
end

local function radar_value(owner, category, radarPlayer)
	if not (owner and owner.GetRadarValues) then return 0 end
	local ok, radar
	if radarPlayer == nil then
		ok, radar = pcall(function() return owner:GetRadarValues() end)
	else
		ok, radar = pcall(function() return owner:GetRadarValues(radarPlayer) end)
	end
	if not ok or not radar or not radar.GetValue then return 0 end
	local valueOk, value = pcall(function() return radar:GetValue(category) end)
	return valueOk and math.max(0, tonumber(value) or 0) or 0
end

local function add_steps_radar(totals, steps)
	if not steps then return end
	totals.steps = totals.steps + radar_value(steps, "RadarCategory_TapsAndHolds", sourcePlayer)
	totals.holds = totals.holds + radar_value(steps, "RadarCategory_Holds", sourcePlayer)
	totals.rolls = totals.rolls + radar_value(steps, "RadarCategory_Rolls", sourcePlayer)
end

local function course_trail_possible()
	local trail = GAMESTATE.GetCurrentTrail and GAMESTATE:GetCurrentTrail(sourcePlayer) or nil
	if not trail then return nil end

	local totals = { steps = 0, holds = 0, rolls = 0, entries = 0, source = "trail_entries" }
	if trail.GetTrailEntries then
		local ok, entries = pcall(function() return trail:GetTrailEntries() end)
		if ok and type(entries) == "table" then
			for _, entry in ipairs(entries) do
				local steps = nil
				if entry and entry.GetSteps then
					local stepsOk, trailSteps = pcall(function() return entry:GetSteps() end)
					steps = stepsOk and trailSteps or nil
				end
				add_steps_radar(totals, steps)
				totals.entries = totals.entries + 1
			end
			if totals.steps > 0 then return totals end
		end
	end

	totals.steps = radar_value(trail, "RadarCategory_TapsAndHolds", nil)
	totals.holds = radar_value(trail, "RadarCategory_Holds", nil)
	totals.rolls = radar_value(trail, "RadarCategory_Rolls", nil)
	totals.entries = 0
	totals.source = "trail"
	if totals.steps > 0 then return totals end

	return nil
end

local function set_course_possible_from_trail(reason)
	local totals = course_trail_possible()
	if not totals or totals.steps <= 0 then return false end
	if storage.ex_counts.possible_source == "trail_entries" or storage.ex_counts.possible_source == "trail" then
		return true
	end

	storage.ex_counts.totalSteps = totals.steps
	storage.ex_counts.totalHolds = totals.holds
	storage.ex_counts.totalRolls = totals.rolls
	storage.ex_counts.possible_source = totals.source
	storage.ex_counts.possible_song_indexes = storage.ex_counts.possible_song_indexes or {}
	storage.ex_counts.possible_song_indexes.__full_course = true

	Trace(("FA_PLUS_POSSIBLE: reason=%s pn=%s source=%s entries=%s totalSteps=%s totalHolds=%s totalRolls=%s"):format(
		tostring(reason),
		tostring(sourcePn),
		tostring(totals.source),
		tostring(totals.entries),
		tostring(storage.ex_counts.totalSteps),
		tostring(storage.ex_counts.totalHolds),
		tostring(storage.ex_counts.totalRolls)
	))
	return true
end

local function add_current_steps_possible(reason)
	if not GAMESTATE:IsCourseMode() then return end
	ensure_ex_counts()
	if set_course_possible_from_trail(reason) then return end

	local songIndex = 0
	if GAMESTATE.GetCourseSongIndex then
		local ok, index = pcall(function() return GAMESTATE:GetCourseSongIndex() end)
		songIndex = ok and tonumber(index) or 0
	end

	storage.ex_counts.possible_song_indexes = storage.ex_counts.possible_song_indexes or {}
	if storage.ex_counts.possible_song_indexes[songIndex] then return end

	local steps = GAMESTATE.GetCurrentSteps and GAMESTATE:GetCurrentSteps(sourcePlayer) or nil
	local totalSteps = radar_value(steps, "RadarCategory_TapsAndHolds", sourcePlayer)
	if totalSteps <= 0 then
		Trace(("FA_PLUS_POSSIBLE: reason=%s pn=%s courseIndex=%s source=current_steps totalSteps=0"):format(
			tostring(reason),
			tostring(sourcePn),
			tostring(songIndex)
		))
		return
	end

	local totalHolds = radar_value(steps, "RadarCategory_Holds", sourcePlayer)
	local totalRolls = radar_value(steps, "RadarCategory_Rolls", sourcePlayer)
	storage.ex_counts.totalSteps = (tonumber(storage.ex_counts.totalSteps) or 0) + totalSteps
	storage.ex_counts.totalHolds = (tonumber(storage.ex_counts.totalHolds) or 0) + totalHolds
	storage.ex_counts.totalRolls = (tonumber(storage.ex_counts.totalRolls) or 0) + totalRolls
	storage.ex_counts.possible_source = "current_steps_cumulative"
	storage.ex_counts.possible_song_indexes[songIndex] = true

	Trace(("FA_PLUS_POSSIBLE: reason=%s pn=%s source=current_steps courseIndex=%s addedSteps=%s addedHolds=%s addedRolls=%s totalSteps=%s totalHolds=%s totalRolls=%s"):format(
		tostring(reason),
		tostring(sourcePn),
		tostring(songIndex),
		tostring(totalSteps),
		tostring(totalHolds),
		tostring(totalRolls),
		tostring(storage.ex_counts.totalSteps),
		tostring(storage.ex_counts.totalHolds),
		tostring(storage.ex_counts.totalRolls)
	))
end

local function should_track_score_counts()
	-- In courses/marathons, PlayerStageStats can remain failed while the
	-- course keeps playing.  Continue accumulating live EX/HardEX counts
	-- there; single-song gameplay still freezes after a real fail.
	if GAMESTATE:IsCourseMode() then return true end
	return not stats:GetFailed()
end

local function same_player(left, right)
	return left ~= nil and right ~= nil and tostring(left) == tostring(right)
end

local function judgment_matches_source_player(params)
	if not params then return false end
	local judgmentPlayer = params.Player or params.PlayerNumber
	if judgmentPlayer ~= nil then
		return same_player(judgmentPlayer, sourcePlayer)
	end
	return #GAMESTATE:GetHumanPlayers() == 1
end

local traceCounts = {
	ignored_player = 0,
	updated = 0,
}

local function trace_count(reason, params, tns, hns, exScore, hardExScore, actualPoints, actualPossible, hardExPoints, hardExPossible)
	if not Trace then return end
	traceCounts[reason] = (traceCounts[reason] or 0) + 1
	if reason == "updated" and traceCounts[reason] > 20 and traceCounts[reason] % 50 ~= 0 then return end
	if reason ~= "updated" and traceCounts[reason] > 8 then return end

	local counts = storage.ex_counts or {}
	Trace(("FA_PLUS_COUNT: reason=%s seen=%s pn=%s stage=%s course=%s paramPlayer=%s paramPlayerNumber=%s tns=%s hns=%s failed=%s possibleSource=%s totalSteps=%s totalHolds=%s totalRolls=%s w010=%s w0=%s w1=%s w2=%s w3=%s miss=%s held=%s letgo=%s ex=%s hardex=%s exPoints=%s exPossible=%s hardExPoints=%s hardExPossible=%s"):format(
		tostring(reason),
		tostring(traceCounts[reason]),
		tostring(sourcePn),
		tostring(stageIndex),
		tostring(GAMESTATE:IsCourseMode()),
		tostring(params and params.Player),
		tostring(params and params.PlayerNumber),
		tostring(tns),
		tostring(hns),
		tostring(stats:GetFailed()),
		tostring(counts.possible_source or "unset"),
		tostring(counts.totalSteps or 0),
		tostring(counts.totalHolds or 0),
		tostring(counts.totalRolls or 0),
		tostring(counts.W010 or 0),
		tostring(counts.W0 or 0),
		tostring(counts.W1 or 0),
		tostring(counts.W2 or 0),
		tostring(counts.W3 or 0),
		tostring(counts.Miss or 0),
		tostring(counts.Held or 0),
		tostring(counts.LetGo or 0),
		tostring(exScore),
		tostring(hardExScore),
		tostring(actualPoints),
		tostring(actualPossible),
		tostring(hardExPoints),
		tostring(hardExPossible)
	))
end

return Def.Actor{
	OnCommand=function(self)
		ensure_ex_counts()
		add_current_steps_possible("On")
		Trace(("FA_PLUS_ACTIVE: pn=%s stage=%s course=%s window=%s ex=%s hardex=%s pane=%s smaller_white=%s"):format(
			ToEnumShortString(sourcePlayer),
			tostring(stageIndex),
			tostring(GAMESTATE:IsCourseMode()),
			tostring(mods.ShowFaPlusWindow),
			tostring(mods.ShowExScore),
			tostring(mods.ShowHardEXScore),
			tostring(mods.ShowFaPlusPane),
			tostring(mods.SmallerWhite)
		))
	end,
	JudgmentMessageCommand=function(self, params)
		if not judgment_matches_source_player(params) then
			trace_count("ignored_player", params, params and params.TapNoteScore, params and params.HoldNoteScore)
			return
		end
		if IsAutoplay(sourcePlayer) then return end
		ensure_ex_counts()
		add_current_steps_possible("Judgment")
		
		local count_updated = false
		if params.HoldNoteScore then
			local HNS = ToEnumShortString(params.HoldNoteScore)
			-- Missed holds are scored the same way as let go holds, so count them as such
			if HNS == "MissedHold" then
				HNS = "LetGo"
			end
			-- Only track the HoldNoteScores we care about
			if valid_hns[HNS] then
				if should_track_score_counts() then
					storage.ex_counts[HNS] = storage.ex_counts[HNS] + 1
					count_updated = true
				end
			end
		-- HNS also contain TNS. We don't want to double count so add an else if.
		elseif params.TapNoteScore then
			local TNS = ToEnumShortString(params.TapNoteScore)

			if SL.Global.GameMode == "ITG" then
				if TNS == "W1" then
					-- Split the engine's top ITG window into:
					-- W010: ArrowCloud HardEX +/-10ms
					-- W0:   FA+/EX inner Fantastic
					-- W1:   remaining white Fantastic
					local is_W010 = IsW010Judgment(params, sourcePlayer)
					local is_W0 = IsW0Judgment(params, sourcePlayer)
					if is_W010 then
						if should_track_score_counts() then
							storage.ex_counts.W0 = storage.ex_counts.W0 + 1
							storage.ex_counts.W010 = storage.ex_counts.W010 + 1
							count_updated = true
						end
						storage.ex_counts.W0_total = storage.ex_counts.W0_total + 1
						storage.ex_counts.W010_total = storage.ex_counts.W010_total + 1
					elseif is_W0 then
						if should_track_score_counts() then
							storage.ex_counts.W0 = storage.ex_counts.W0 + 1
							storage.ex_counts.W110 = storage.ex_counts.W110 + 1
							count_updated = true
						end
						storage.ex_counts.W0_total = storage.ex_counts.W0_total + 1
					else
						if should_track_score_counts() then
							storage.ex_counts.W1 = storage.ex_counts.W1 + 1
							storage.ex_counts.W110 = storage.ex_counts.W110 + 1
							count_updated = true
						end
					end
				else
					-- Only track the TapNoteScores we care about
					if valid_tns[TNS] then
						if should_track_score_counts() then
							storage.ex_counts[TNS] = storage.ex_counts[TNS] + 1
							count_updated = true
						end
					end
				end
			else
				local adjusted_TNS = TNS
				local tier = string.match(TNS, "W(%d)")

				-- In FA+ mode, we need to shift the windows up 1 so that the key we're using is accurate.
				-- E.g. W1 window becomes W0, W2 becomes W1, etc.
				if tier ~= nil then
					adjusted_TNS = "W"..(tonumber(tier)-1)
				end
				
				-- Only track the TapNoteScores we care about
				if valid_tns[adjusted_TNS] then
					if should_track_score_counts() then
						storage.ex_counts[adjusted_TNS] = storage.ex_counts[adjusted_TNS] + 1
						count_updated = true
					end
				end
			end
		end
		if count_updated then
			-- Broadcast so other elements on ScreenGameplay can process the updated count.
			local ExScore, ActualPoints, ActualPossible = CalculateExScore(sourcePlayer, storage.ex_counts)
			local HardExScore, HardExPoints, HardExPossible = CalculateHardExScore(sourcePlayer, storage.ex_counts)
			trace_count("updated", params, params.TapNoteScore, params.HoldNoteScore, ExScore, HardExScore, ActualPoints, ActualPossible, HardExPoints, HardExPossible)

			MESSAGEMAN:Broadcast(
				"ExCountsChanged",
				{
					Player=sourcePlayer,
					ExCounts=storage.ex_counts,
					ExScore=ExScore,
					HardExScore=HardExScore,
					ActualPoints=ActualPoints,
					ActualPossible=ActualPossible
				}
			)
		end
	end,
	CurrentSongChangedMessageCommand=function(self)
		add_current_steps_possible("CurrentSongChanged")
	end,
	OffCommand=function(self)
		ensure_ex_counts()
		local counts = storage.ex_counts or {}
		Trace(("FA_PLUS_SUMMARY: pn=%s stage=%s course=%s w010=%s w0=%s w1=%s w2=%s w3=%s miss=%s held=%s letgo=%s smaller_white=%s"):format(
			ToEnumShortString(sourcePlayer),
			tostring(stageIndex),
			tostring(GAMESTATE:IsCourseMode()),
			tostring(counts.W010_total or counts.W010 or 0),
			tostring(counts.W0_total or counts.W0 or 0),
			tostring(counts.W1 or 0),
			tostring(counts.W2 or 0),
			tostring(counts.W3 or 0),
			tostring(counts.Miss or 0),
			tostring(counts.Held or 0),
			tostring(counts.LetGo or 0),
			tostring(mods.SmallerWhite)
		))
	end,
}
