local player = ...
local pn = ToEnumShortString(player)

local mods = SL[pn].ActiveModifiers
local IsUltraWide = (GetScreenAspectRatio() > 21/9)
local NumPlayers = #GAMESTATE:GetHumanPlayers()
local IsEX = SL[pn].ActiveModifiers.ShowExScore
local IsHardEX = SL[pn].ActiveModifiers.ShowHardEXScore
local OnlineITGScoreColor = Color.White
local OnlineEXScoreColor = (SL.JudgmentColors and SL.JudgmentColors["FA+"] and SL.JudgmentColors["FA+"][1]) or color("#21CCE8")
local OnlineHardEXScoreColor = (SL.JudgmentColors and SL.JudgmentColors["HardEX"] and SL.JudgmentColors["HardEX"][1]) or color("#ff00cc")
local pss

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
	return IsEX, IsHardEX, IsHardEX and "hardex" or (IsEX and "ex" or "itg")
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
		actor:zoomx(0.34):zoomy(0.34)
	end
end

local function get_itg_percent()
	return tonumber(FormatPercentScore(pss:GetPercentDancePoints()):sub(1,-2)) or 0
end

local function set_normal_lower_score_layout(actor_frame)
	local lower_ex = actor_frame:GetChild("LowerEXScore")
	local lower_itg = actor_frame:GetChild("LowerITGScore")
	local primary = actor_frame:GetChild("PrimaryScore")
	if primary then primary:horizalign(right) end
	if lower_ex then lower_ex:horizalign(left):xy(8, -2) end
	if lower_itg then lower_itg:horizalign(left):xy(70, -2) end
	prepare_lower_score(lower_ex)
	prepare_lower_score(lower_itg)
end

local function set_online_lower_score_layout(actor_frame)
	local lower_ex = actor_frame:GetChild("LowerEXScore")
	local lower_itg = actor_frame:GetChild("LowerITGScore")
	local primary = actor_frame:GetChild("PrimaryScore")
	if primary then primary:horizalign(center) end
	if lower_ex then lower_ex:horizalign(center):xy(-36, 18) end
	if lower_itg then lower_itg:horizalign(center):xy(36, 18) end
	prepare_lower_score(lower_ex)
	prepare_lower_score(lower_itg)
end

local function update_lower_scores(actor_frame, scoreMode, exPercent)
	local lower_ex = actor_frame:GetChild("LowerEXScore")
	local lower_itg = actor_frame:GetChild("LowerITGScore")
	if not (lower_ex and lower_itg) then return end

	lower_ex:visible(false)
	lower_itg:visible(false)

	if mods.ShowAllScoreModes ~= true then return end
	if scoreMode == "itg" then return end

	local itgPercent = get_itg_percent()
	if scoreMode == "hardex" then
		if is_online_column_layout() then
			lower_ex:horizalign(center):xy(-36, 18)
			lower_itg:horizalign(center):xy(36, 18)
		else
			lower_ex:horizalign(left):xy(8, -2)
			lower_itg:horizalign(left):xy(70, -2)
		end
		lower_ex:settext(format_percent(exPercent or CalculateExScore(player))):visible(true)
		lower_itg:settext(format_percent(itgPercent)):visible(true)
	elseif scoreMode == "ex" then
		if is_online_column_layout() then
			lower_itg:horizalign(center):xy(0, 18)
		else
			lower_itg:horizalign(left):xy(8, -2)
		end
		lower_itg:settext(format_percent(itgPercent)):visible(true)
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

pss = STATSMAN:GetCurStageStats():GetPlayerStageStats(player)

local StepsOrTrail = (GAMESTATE:IsCourseMode() and GAMESTATE:GetCurrentTrail(player)) or GAMESTATE:GetCurrentSteps(player)
local total_tapnotes = StepsOrTrail and StepsOrTrail:GetRadarValues(player):GetValue( "RadarCategory_Notes" ) or 1
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
	JudgmentMessageCommand=function(self)
		self:queuecommand("RedrawScore")
	end,
	RedrawScoreCommand=function(self)
		local primary = self:GetChild("PrimaryScore")
		local showEx, showHardEx, scoreMode = active_score_flags()
		local exPercent = CalculateExScore(player)
		local hardExPercent = CalculateHardExScore(player)
		local dance_points = pss:GetPercentDancePoints()
		local percent = FormatPercentScore( dance_points ):sub(1,-2)
		local displayedPercent = showHardEx and tonumber(hardExPercent) or (showEx and tonumber(exPercent) or tonumber(percent))

		apply_score_color(primary, showEx, showHardEx)
		if showHardEx then
			primary:settext(format_percent(hardExPercent))
		elseif showEx then
			primary:settext(format_percent(exPercent))
		else
			primary:settext(percent)
		end
		update_lower_scores(self, scoreMode, exPercent)

		if ITGOnline and ITGOnline.currentRoomId then
			if ITGOnline.debugOnlineTrace == true or ITGOnline.debugReadyFlow == true then
				Trace("ITG Online: FLOW gameplay_score_broadcast source=RedrawScore"
					.. " player=" .. tostring(player)
					.. " room=" .. tostring(ITGOnline.currentRoomId)
					.. " score=" .. tostring(percent)
					.. " ex=" .. tostring(exPercent)
					.. " hardex=" .. tostring(hardExPercent)
					.. " displayed=" .. tostring(displayedPercent)
					.. " scoreMode=" .. tostring(scoreMode)
					.. " combo=" .. tostring(pss:GetCurrentCombo() or 0))
			end
			MESSAGEMAN:Broadcast("OnlineScoreSnapshot", {
				Player = player,
				ScorePercent = tonumber(percent),
				ExScorePercent = tonumber(exPercent),
				HardExScorePercent = tonumber(hardExPercent),
				DisplayedPercent = displayedPercent,
				ScoreMode = scoreMode,
				Combo = pss:GetCurrentCombo() or 0,
			})
		end
	end,
	ExCountsChangedMessageCommand=function(self, params)
		if params.Player ~= player then return end

		local primary = self:GetChild("PrimaryScore")
		local showEx, showHardEx, scoreMode = active_score_flags()
		apply_score_color(primary, showEx, showHardEx)
		if showHardEx then
			primary:settext(format_percent(params.HardExScore))
		elseif showEx then
			primary:settext(format_percent(params.ExScore))
		else
			return
		end
		update_lower_scores(self, scoreMode, params.ExScore)

		if ITGOnline and ITGOnline.currentRoomId then
			local dance_points = pss:GetPercentDancePoints()
			local percent = FormatPercentScore( dance_points ):sub(1,-2)
			if ITGOnline.debugOnlineTrace == true or ITGOnline.debugReadyFlow == true then
				Trace("ITG Online: FLOW gameplay_score_broadcast source=ExCountsChanged"
					.. " player=" .. tostring(player)
					.. " room=" .. tostring(ITGOnline.currentRoomId)
					.. " score=" .. tostring(percent)
					.. " ex=" .. tostring(params.ExScore)
					.. " hardex=" .. tostring(params.HardExScore)
					.. " displayed=" .. tostring(showHardEx and tonumber(params.HardExScore) or tonumber(params.ExScore))
					.. " scoreMode=" .. tostring(scoreMode)
					.. " combo=" .. tostring(pss:GetCurrentCombo() or 0))
			end
			MESSAGEMAN:Broadcast("OnlineScoreSnapshot", {
				Player = player,
				ScorePercent = tonumber(percent),
				ExScorePercent = tonumber(params.ExScore),
				HardExScorePercent = tonumber(params.HardExScore),
				DisplayedPercent = showHardEx and tonumber(params.HardExScore) or tonumber(params.ExScore),
				ScoreMode = scoreMode,
				Combo = pss:GetCurrentCombo() or 0,
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
