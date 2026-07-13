local player = ...
local pn = ToEnumShortString(player)
local routineShared = IsRoutine and IsRoutine()
local masterPlayer = routineShared and GAMESTATE:GetMasterPlayerNumber() or player
local sourcePlayer = routineShared and masterPlayer or player
local sourcePn = ToEnumShortString(sourcePlayer)

local mods = SL[pn].ActiveModifiers
local scoreMods = SL[sourcePn].ActiveModifiers
local IsUltraWide = (GetScreenAspectRatio() > 21/9)
local NumPlayers = #GAMESTATE:GetHumanPlayers()
local OnlineITGScoreColor = Color.White
local OnlineEXScoreColor = (SL.JudgmentColors and SL.JudgmentColors["FA+"] and SL.JudgmentColors["FA+"][1]) or color("#21CCE8")
local OnlineHardEXScoreColor = (SL.JudgmentColors and SL.JudgmentColors["HardEX"] and SL.JudgmentColors["HardEX"][1]) or color("#ff00cc")
local pss
local lastRoutineDisplayedPercent
local lastRoutineScoreSnapshot
local failedScoreSnapshot
local failedDetected = false
local lastLowerLayoutTraceKey
local stageIndex = math.max(1, math.floor(tonumber(SL.Global.Stages.PlayedThisGame) or 0) + 1)

local LowerScoreLayout = {
	y = -2,
	gap = 8,
	legacyFirstX = 8,
	legacySecondX = 70,
	primaryFallbackWidth = 54,
	lowerFallbackWidth = 36,
}

local function online_score_mode()
	if ITGOnline and ITGOnline.currentRoomId and ITGOnline.CurrentGlobalOptions then
		local options = ITGOnline:CurrentGlobalOptions()
		return tostring(options.score_mode or "itg")
	end
	return nil
end

local function active_score_flags()
	local mode = online_score_mode()
	if mode == "hardex" then
		return false, true, mode
	elseif mode == "ex" then
		return true, false, mode
	elseif mode == "itg" then
		return false, false, mode
	end
	local isEx = scoreMods.ShowExScore
	local isHardEx = scoreMods.ShowHardEXScore
	return isEx, isHardEx, isHardEx and "hardex" or (isEx and "ex" or "itg")
end

local function apply_score_color(actor, showEx, showHardEx)
	if not actor then return end
	if showHardEx then
		actor:diffuse(OnlineHardEXScoreColor)
	elseif showEx then
		actor:diffuse(OnlineEXScoreColor)
	else
		actor:diffuse(OnlineITGScoreColor)
	end
end

local function is_online_column_layout()
	return IsUsingOnlineGameplayColumns and IsUsingOnlineGameplayColumns()
end

local function format_percent(value)
	return ("%.02f"):format(tonumber(value) or 0)
end

local function prepare_lower_score(actor)
	if actor then
		actor:zoomx(0.25):zoomy(0.25)
	end
end

local function zoomed_width(actor, fallback)
	if not actor then return fallback end

	local ok, width = pcall(function() return actor:GetZoomedWidth() end)
	width = ok and tonumber(width) or nil
	return (width and width > 0) and width or fallback
end

local function place_lower_score(actor, x)
	if actor then
		actor:horizalign(right):xy(x, LowerScoreLayout.y)
	end
end

local function place_legacy_lower_score(actor, x)
	if actor then
		actor:horizalign(left):xy(x, LowerScoreLayout.y)
	end
end

local function place_lower_scores_left_of_primary(actor_frame, showExScore, showItgScore)
	local lower_ex = actor_frame:GetChild("LowerEXScore")
	local lower_itg = actor_frame:GetChild("LowerITGScore")
	local primary = actor_frame:GetChild("PrimaryScore")
	local primary_width = zoomed_width(primary, LowerScoreLayout.primaryFallbackWidth)
	local primary_left_edge = is_online_column_layout() and -(primary_width / 2) or -primary_width
	local next_right_edge = primary_left_edge - LowerScoreLayout.gap
	local ex_x
	local itg_x

	if showExScore and lower_ex then
		ex_x = next_right_edge
		place_lower_score(lower_ex, ex_x)
		next_right_edge = next_right_edge - zoomed_width(lower_ex, LowerScoreLayout.lowerFallbackWidth) - LowerScoreLayout.gap
	end

	if showItgScore and lower_itg then
		itg_x = next_right_edge
		place_lower_score(lower_itg, itg_x)
	end

	return ex_x, itg_x, primary_width
end

local function place_lower_scores_for_player(actor_frame, showExScore, showItgScore)
	if player ~= PLAYER_1 then
		return place_lower_scores_left_of_primary(actor_frame, showExScore, showItgScore)
	end

	local lower_ex = actor_frame:GetChild("LowerEXScore")
	local lower_itg = actor_frame:GetChild("LowerITGScore")
	local primary = actor_frame:GetChild("PrimaryScore")
	local ex_x
	local itg_x

	if showExScore and lower_ex then
		ex_x = LowerScoreLayout.legacyFirstX
		place_legacy_lower_score(lower_ex, ex_x)
	end

	if showItgScore and lower_itg then
		itg_x = showExScore and LowerScoreLayout.legacySecondX or LowerScoreLayout.legacyFirstX
		place_legacy_lower_score(lower_itg, itg_x)
	end

	return ex_x, itg_x, zoomed_width(primary, LowerScoreLayout.primaryFallbackWidth)
end

local function get_itg_percent()
	return tonumber(FormatPercentScore(pss:GetPercentDancePoints()):sub(1,-2)) or 0
end

local function current_ex_counts()
	local playerState = SL[sourcePn]
	local stages = playerState and playerState.Stages
	local stats = stages and stages.Stats
	local storage = stats and stats[stageIndex]
	return storage and storage.ex_counts or nil
end

local function current_ex_score()
	return CalculateExScore(sourcePlayer, current_ex_counts())
end

local function current_hard_ex_score()
	return CalculateHardExScore(sourcePlayer, current_ex_counts())
end

local function set_normal_lower_score_layout(actor_frame)
	local lower_ex = actor_frame:GetChild("LowerEXScore")
	local lower_itg = actor_frame:GetChild("LowerITGScore")
	local primary = actor_frame:GetChild("PrimaryScore")
	if primary then primary:horizalign(right) end
	prepare_lower_score(lower_ex)
	prepare_lower_score(lower_itg)
	place_lower_scores_for_player(actor_frame, true, true)
end

local function set_online_lower_score_layout(actor_frame)
	local lower_ex = actor_frame:GetChild("LowerEXScore")
	local lower_itg = actor_frame:GetChild("LowerITGScore")
	local primary = actor_frame:GetChild("PrimaryScore")
	if primary then primary:horizalign(center) end
	prepare_lower_score(lower_ex)
	prepare_lower_score(lower_itg)
	place_lower_scores_for_player(actor_frame, true, true)
end

local function stage_stats_failed()
	local ok, failed = pcall(function() return pss and pss:GetFailed() end)
	if ok and failed == true then return true end

	local sourceOk, sourceFailed = pcall(function()
		return STATSMAN:GetCurStageStats():GetPlayerStageStats(sourcePlayer):GetFailed()
	end)
	if sourceOk and sourceFailed == true then return true end

	local healthOk, healthState = pcall(function()
		return GAMESTATE:GetPlayerState(sourcePlayer):GetHealthState()
	end)
	if healthOk and tostring(healthState) == "HealthState_Dead" then return true end

	return failedDetected == true
end

local function same_player(left, right)
	return left ~= nil and right ~= nil and tostring(left) == tostring(right)
end

local function message_matches_source_player(params)
	if not params then return true end
	if params.PlayerNumber ~= nil then
		return same_player(params.PlayerNumber, sourcePlayer)
	end
	if params.Player ~= nil then
		return same_player(params.Player, sourcePlayer)
	end
	return true
end

local function mark_failed_detected(reason)
	if failedDetected then return end
	failedDetected = true
	if type(online_logs_enabled) == "function" and online_logs_enabled() and Trace then
		Trace("ROUTINE_UI Score failed_detected"
			.. " player=" .. tostring(pn)
			.. " source=" .. tostring(sourcePn)
			.. " reason=" .. tostring(reason or "unknown"))
	end
end

local function build_score_snapshot(scoreMode, percent, exPercent, hardExPercent, displayedPercent, combo)
	return {
		ScoreMode = scoreMode,
		ScorePercent = tonumber(percent) or 0,
		ExScorePercent = tonumber(exPercent) or 0,
		HardExScorePercent = tonumber(hardExPercent) or 0,
		DisplayedPercent = tonumber(displayedPercent) or 0,
		Combo = tonumber(combo) or 0,
	}
end

local function trace_routine_score_drop(snapshot, reason, frozen)
	if not routineShared then return end
	if not (type(online_logs_enabled) == "function" and online_logs_enabled() and Trace) then return end

	if lastRoutineScoreSnapshot then
		local itgDelta = snapshot.ScorePercent - lastRoutineScoreSnapshot.ScorePercent
		local exDelta = snapshot.ExScorePercent - lastRoutineScoreSnapshot.ExScorePercent
		local hardExDelta = snapshot.HardExScorePercent - lastRoutineScoreSnapshot.HardExScorePercent
		if itgDelta < 0 or exDelta < 0 or hardExDelta < 0 then
			Trace("ROUTINE_UI Score drop"
				.. " player=" .. tostring(pn)
				.. " source=" .. tostring(sourcePn)
				.. " reason=" .. tostring(reason or "unknown")
				.. " mode=" .. tostring(snapshot.ScoreMode)
				.. " itg=" .. tostring(snapshot.ScorePercent)
				.. " itg_delta=" .. tostring(itgDelta)
				.. " ex=" .. tostring(snapshot.ExScorePercent)
				.. " ex_delta=" .. tostring(exDelta)
				.. " hardex=" .. tostring(snapshot.HardExScorePercent)
				.. " hardex_delta=" .. tostring(hardExDelta)
				.. " displayed=" .. tostring(snapshot.DisplayedPercent)
				.. " combo=" .. tostring(snapshot.Combo)
				.. " frozen=" .. tostring(frozen == true))
		end
	end

	lastRoutineScoreSnapshot = build_score_snapshot(
		snapshot.ScoreMode,
		snapshot.ScorePercent,
		snapshot.ExScorePercent,
		snapshot.HardExScorePercent,
		snapshot.DisplayedPercent,
		snapshot.Combo
	)
end

local function frozen_or_current_score(snapshot, reason)
	if GAMESTATE:IsCourseMode() then return snapshot, false end
	if not stage_stats_failed() then return snapshot, false end
	if failedScoreSnapshot == nil then
		failedScoreSnapshot = snapshot
		if type(online_logs_enabled) == "function" and online_logs_enabled() and Trace then
			Trace("ROUTINE_UI Score freeze_on_failed"
				.. " player=" .. tostring(pn)
				.. " source=" .. tostring(sourcePn)
				.. " reason=" .. tostring(reason or "unknown")
				.. " mode=" .. tostring(snapshot.ScoreMode)
				.. " displayed=" .. tostring(snapshot.DisplayedPercent)
				.. " score=" .. tostring(snapshot.ScorePercent)
				.. " ex=" .. tostring(snapshot.ExScorePercent)
				.. " hardex=" .. tostring(snapshot.HardExScorePercent)
				.. " combo=" .. tostring(snapshot.Combo))
		end
	end
	return failedScoreSnapshot, true
end

local function update_lower_scores(actor_frame, scoreMode, exPercent, itgPercent)
	local lower_ex = actor_frame:GetChild("LowerEXScore")
	local lower_itg = actor_frame:GetChild("LowerITGScore")
	if not (lower_ex and lower_itg) then return end

	lower_ex:visible(false)
	lower_itg:visible(false)

	if scoreMods.ShowAllScoreModes ~= true then return end
	if scoreMode == "itg" then return end

	itgPercent = itgPercent or get_itg_percent()
	if scoreMode == "hardex" then
		lower_ex:settext(format_percent(exPercent or current_ex_score())):visible(true)
		lower_itg:settext(format_percent(itgPercent)):visible(true)
		local ex_x, itg_x, primary_width = place_lower_scores_for_player(actor_frame, true, true)
		if type(online_logs_enabled) == "function" and online_logs_enabled() and Trace then
			local traceKey = table.concat({ tostring(scoreMode), tostring(ex_x), tostring(itg_x), tostring(primary_width), tostring(is_online_column_layout()), tostring(player) }, ":")
			if traceKey ~= lastLowerLayoutTraceKey then
				lastLowerLayoutTraceKey = traceKey
				Trace("ROUTINE_UI Score lower_layout"
					.. " player=" .. tostring(pn)
					.. " source=" .. tostring(sourcePn)
					.. " mode=" .. tostring(scoreMode)
					.. " primary_width=" .. tostring(primary_width)
					.. " ex_x=" .. tostring(ex_x)
					.. " itg_x=" .. tostring(itg_x)
					.. " online_layout=" .. tostring(is_online_column_layout()))
			end
		end
	elseif scoreMode == "ex" then
		lower_itg:settext(format_percent(itgPercent)):visible(true)
		place_lower_scores_for_player(actor_frame, false, true)
	end
end

-- -----------------------------------------------------------------------
-- first, check for conditions where we might not draw the score actor at all

if mods.HideScore then return end

if NumPlayers > 1
and mods.NPSGraphAtTop
and not IsUltraWide
then
	return
end

-- -----------------------------------------------------------------------
-- set up some preliminary variables and calculations for positioning and zooming

local styletype = ToEnumShortString(GAMESTATE:GetCurrentStyle():GetStyleType())

-- scores are not aligned symmetrically around screen.cx for aesthetic reasons
-- and this is the cause of many code-induced headaches
local pos = {
	[PLAYER_1] = { x=(_screen.cx - clamp(_screen.w, 640, 854)/4.3),  y=56 },
	[PLAYER_2] = { x=(_screen.cx + clamp(_screen.w, 640, 854)/2.75), y=56 },
}

if IsUltraWide and NumPlayers == 1 then
	local difficulty_x = _screen.cx - SL_WideScale(292.5, 342.5)
	local header_gap = clamp(_screen.w * 0.11, 180, 260)
	pos[PLAYER_1].x = math.max(pos[PLAYER_1].x, difficulty_x + header_gap)
end

pss = routineShared and STATSMAN:GetCurStageStats():GetRoutineStageStats() or STATSMAN:GetCurStageStats():GetPlayerStageStats(player)

local StepsOrTrail = (GAMESTATE:IsCourseMode() and GAMESTATE:GetCurrentTrail(sourcePlayer)) or GAMESTATE:GetCurrentSteps(sourcePlayer)
local total_tapnotes = StepsOrTrail and StepsOrTrail:GetRadarValues(sourcePlayer):GetValue( "RadarCategory_Notes" ) or 1
total_tapnotes = math.max(1, tonumber(total_tapnotes) or 1)

-- determine how many digits are needed to express the number of notes in base-10
local digits = (math.floor(math.log10(total_tapnotes)) + 1)
-- subtract 4 from the digit count; we're only really interested in how many digits past 4
-- this stepcount is so we can use it to align the score actor in the StepStats pane if needed
-- aligned-with-4-digits is the default
digits = clamp(math.max(4, digits) - 4, 0, 3)

local NoteFieldIsCentered = (GetNotefieldX(player) == _screen.cx)

local ar_scale = {
	sixteen_ten  = 0.825,
	sixteen_nine = 1
}
local zoom_factor = clamp(scale(GetScreenAspectRatio(), 16/10, 16/9, ar_scale.sixteen_ten, ar_scale.sixteen_nine), 0, 1.125)

-- -----------------------------------------------------------------------

return Def.ActorFrame{
	Name=pn.."Score",
	InitCommand=function(self)
		set_normal_lower_score_layout(self)
		local showEx, showHardEx = active_score_flags()
		apply_score_color(self:GetChild("PrimaryScore"), showEx, showHardEx)
	end,

	BeginCommand=function(self)
		if type(online_logs_enabled) == "function" and online_logs_enabled() and Trace then
			Trace("ROUTINE_UI Score init player=" .. tostring(pn)
				.. " source=" .. tostring(sourcePn)
				.. " routine_shared=" .. tostring(routineShared == true))
		end
		set_normal_lower_score_layout(self)
		if is_online_column_layout() then
			self:playcommand("OnlineColumnLayout")
			return
		end

		-----------------------------------------------------------------
		-- ultrawide with both players joined is really its own layout
		-- hardcode some numbers for now, return early, and call it a day
		-- until 21:9 displays become more popular
		if IsUltraWide and #GAMESTATE:GetHumanPlayers() > 1 then
			if player==PLAYER_1 then
				self:x(134)
			else
				self:x(_screen.w - 4)
			end

			self:y( 238 )
			return
		end
		-----------------------------------------------------------------

		-- assume "normal" score positioning first, but there are many reasons it will need to be moved
		self:xy( pos[player].x, pos[player].y )

		if mods.NPSGraphAtTop and styletype ~= "OnePlayerTwoSides" then
			-- if NPSGraphAtTop and Step Statistics and not double,
			-- move the score down into the stepstats pane under
			-- the judgment breakdown
			if mods.DataVisualizations=="Step Statistics" then
				local step_stats = self:GetParent():GetChild("StepStatsPane"..pn)

				-- Step Statistics might be true in the SL table from a previous game session
				-- but current conditions might be such that it won't actually appear.
				-- Ensure the StepStats ActorFrame is present before trying to traverse it.
				if step_stats then
					if player==PLAYER_1 then
						if NoteFieldIsCentered then
							self:x( pos[ OtherPlayer[player] ].x + SL_WideScale( 94, 112.5) )
						else
							self:x( pos[ OtherPlayer[player] ].x - SL_WideScale(-84, -60) )
						end

					-- PLAYER_2
					else
						if NoteFieldIsCentered then
							self:x( pos[ OtherPlayer[player] ].x - 65.5 )
						else
							self:x( pos[ OtherPlayer[player] ].x - SL_WideScale(-6, -2))
						end
					end

					self:y( 282 )
				end

			-- if NPSGraphAtTop but not Step Statistics
			else
				-- if not Center1Player, move the score right or left
				-- within the normal gameplay header to where the
				-- other player's score would be if this were versus
				if not NoteFieldIsCentered then
					self:x( pos[ OtherPlayer[player] ].x )
					self:y( pos[ OtherPlayer[player] ].y )
				end
				-- if NoteFieldIsCentered, no need to move the score
			end
		end
	end,
	OnlineColumnLayoutCommand=function(self)
		set_online_lower_score_layout(self)
		self:x(GetOnlineGameplayColumnX(GetOnlineGameplayPlayerColumn(player)))
		self:y(pos[player].y)
	end,
	JudgmentMessageCommand=function(self, params)
		if not message_matches_source_player(params) then return end
		self:queuecommand("RedrawScore")
	end,
	PlayerFailedMessageCommand=function(self, params)
		if not message_matches_source_player(params) then return end
		mark_failed_detected("PlayerFailed")
		self:queuecommand("RedrawScore")
	end,
	HealthStateChangedMessageCommand=function(self, params)
		if not message_matches_source_player(params) then return end
		if params and tostring(params.HealthState) ~= "HealthState_Dead" then return end
		mark_failed_detected("HealthStateChanged")
		self:queuecommand("RedrawScore")
	end,
	CurrentSongChangedMessageCommand=function(self)
		if GAMESTATE:IsCourseMode() then
			self:queuecommand("RedrawScore")
		end
	end,
	RedrawScoreCommand=function(self)
		local primary = self:GetChild("PrimaryScore")
		local showEx, showHardEx, scoreMode = active_score_flags()
		local exPercent = current_ex_score()
		local hardExPercent = current_hard_ex_score()
		local dance_points = pss:GetPercentDancePoints()
		local percent = FormatPercentScore( dance_points ):sub(1,-2)
		local displayedPercent = showHardEx and tonumber(hardExPercent) or (showEx and tonumber(exPercent) or tonumber(percent))
		local snapshot = build_score_snapshot(scoreMode, percent, exPercent, hardExPercent, displayedPercent, pss:GetCurrentCombo() or 0)
		local frozen
		snapshot, frozen = frozen_or_current_score(snapshot, "RedrawScore")
		percent = format_percent(snapshot.ScorePercent)
		exPercent = snapshot.ExScorePercent
		hardExPercent = snapshot.HardExScorePercent
		displayedPercent = snapshot.DisplayedPercent

		apply_score_color(primary, showEx, showHardEx)
		if showHardEx then
			primary:settext(format_percent(hardExPercent))
		elseif showEx then
			primary:settext(format_percent(exPercent))
		else
			primary:settext(percent)
		end
		update_lower_scores(self, scoreMode, exPercent, snapshot.ScorePercent)
		trace_routine_score_drop(snapshot, "RedrawScore", frozen)

		if routineShared and type(online_logs_enabled) == "function" and online_logs_enabled() and Trace then
			if lastRoutineDisplayedPercent and ((lastRoutineDisplayedPercent > 0 and displayedPercent == 0) or (lastRoutineDisplayedPercent == 0 and displayedPercent > 0)) then
				Trace("ROUTINE_UI Score zero_edge player=" .. tostring(pn)
					.. " source=" .. tostring(sourcePn)
					.. " mode=" .. tostring(scoreMode)
					.. " previous=" .. tostring(lastRoutineDisplayedPercent)
					.. " displayed=" .. tostring(displayedPercent)
					.. " itg=" .. tostring(percent)
					.. " ex=" .. tostring(exPercent)
					.. " hardex=" .. tostring(hardExPercent)
					.. " combo=" .. tostring(snapshot.Combo)
					.. " frozen=" .. tostring(frozen == true))
			end
			lastRoutineDisplayedPercent = displayedPercent
		end

		if ITGOnline and ITGOnline.currentRoomId then
			-- TrackOnlineScorePush emits a throttled, score-category trace for this
			-- stream. Logging every redraw here flooded log.txt during gameplay.
			MESSAGEMAN:Broadcast("OnlineScoreSnapshot", {
				Player = sourcePlayer,
				ScorePercent = snapshot.ScorePercent,
				ExScorePercent = snapshot.ExScorePercent,
				HardExScorePercent = snapshot.HardExScorePercent,
				DisplayedPercent = displayedPercent,
				ScoreMode = scoreMode,
				Combo = snapshot.Combo,
				Failed = stage_stats_failed(),
				Frozen = frozen == true,
			})
		end
	end,
	ExCountsChangedMessageCommand=function(self, params)
		if params.Player ~= sourcePlayer then return end

		local primary = self:GetChild("PrimaryScore")
		local showEx, showHardEx, scoreMode = active_score_flags()
		apply_score_color(primary, showEx, showHardEx)
		if not (showHardEx or showEx) then
			return
		end
		local dance_points = pss:GetPercentDancePoints()
		local percent = FormatPercentScore( dance_points ):sub(1,-2)
		local exCounts = params.ExCounts or current_ex_counts()
		local exPercent = CalculateExScore(sourcePlayer, exCounts)
		local hardExPercent = CalculateHardExScore(sourcePlayer, exCounts)
		local displayedPercent = showHardEx and tonumber(hardExPercent) or tonumber(exPercent)
		local snapshot = build_score_snapshot(scoreMode, percent, exPercent, hardExPercent, displayedPercent, pss:GetCurrentCombo() or 0)
		local frozen
		snapshot, frozen = frozen_or_current_score(snapshot, "ExCountsChanged")
		if showHardEx then
			primary:settext(format_percent(snapshot.HardExScorePercent))
		elseif showEx then
			primary:settext(format_percent(snapshot.ExScorePercent))
		end
		update_lower_scores(self, scoreMode, snapshot.ExScorePercent, snapshot.ScorePercent)
		trace_routine_score_drop(snapshot, "ExCountsChanged", frozen)

		if ITGOnline and ITGOnline.currentRoomId then
			MESSAGEMAN:Broadcast("OnlineScoreSnapshot", {
				Player = sourcePlayer,
				ScorePercent = snapshot.ScorePercent,
				ExScorePercent = snapshot.ExScorePercent,
				HardExScorePercent = snapshot.HardExScorePercent,
				DisplayedPercent = snapshot.DisplayedPercent,
				ScoreMode = scoreMode,
				Combo = snapshot.Combo,
				Failed = stage_stats_failed(),
				Frozen = frozen == true,
			})
		end
	end,

	LoadFont("Wendy/_wendy monospace numbers")..{
		Text="0.00",
		Name="PrimaryScore",
		InitCommand=function(self)
			self:valign(1):horizalign(right)
			self:zoom(0.5)
		end
	},

	LoadFont("Wendy/_wendy monospace numbers")..{
		Text="",
		Name="LowerEXScore",
		InitCommand=function(self)
			self:valign(1):horizalign(left)
			self:zoom(0.28):diffuse(OnlineEXScoreColor):visible(false)
		end
	},

	LoadFont("Wendy/_wendy monospace numbers")..{
		Text="",
		Name="LowerITGScore",
		InitCommand=function(self)
			self:valign(1):horizalign(left)
			self:zoom(0.28):diffuse(OnlineITGScoreColor):visible(false)
		end
	}
}
