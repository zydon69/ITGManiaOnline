local player = ...
local pn = ToEnumShortString(player)

local mods = SL[pn].ActiveModifiers
local IsUltraWide = (GetScreenAspectRatio() > 21/9)
local NumPlayers = #GAMESTATE:GetHumanPlayers()
local IsEX = SL[pn].ActiveModifiers.ShowExScore
local IsHardEX = SL[pn].ActiveModifiers.ShowHardEXScore
local OnlineITGScoreColor = Color.White
local OnlineEXScoreColor = (SL.JudgmentColors and SL.JudgmentColors["FA+"] and SL.JudgmentColors["FA+"][1]) or color("#21CCE8")
local OnlineHardEXScoreColor = color("#ff00cc")

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
	if showHardEx then
		actor:diffuse(OnlineHardEXScoreColor)
	elseif showEx then
		actor:diffuse(OnlineEXScoreColor)
	else
		actor:diffuse(OnlineITGScoreColor)
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

local pss = STATSMAN:GetCurStageStats():GetPlayerStageStats(player)

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

return LoadFont("Wendy/_wendy monospace numbers")..{
	Text="0.00",
	Name=pn.."Score",
	InitCommand=function(self)
		self:valign(1):horizalign(right)
		self:zoom(0.5)
		local showEx, showHardEx = active_score_flags()
		apply_score_color(self, showEx, showHardEx)
	end,

	BeginCommand=function(self)
		if IsUsingOnlineGameplayColumns and IsUsingOnlineGameplayColumns() then
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
		self:horizalign(center)
		self:x(GetOnlineGameplayColumnX(GetOnlineGameplayPlayerColumn(player)))
		self:y(pos[player].y)
	end,
	JudgmentMessageCommand=function(self)
		self:queuecommand("RedrawScore")
	end,
	RedrawScoreCommand=function(self)
		local showEx, showHardEx, scoreMode = active_score_flags()
		local exPercent = CalculateExScore(player)
		local hardExPercent = CalculateHardExScore(player)
		local dance_points = pss:GetPercentDancePoints()
		local percent = FormatPercentScore( dance_points ):sub(1,-2)
		local displayedPercent = showHardEx and tonumber(hardExPercent) or (showEx and tonumber(exPercent) or tonumber(percent))

		apply_score_color(self, showEx, showHardEx)
		if showHardEx then
			self:settext(("%.02f"):format(hardExPercent))
		elseif showEx then
			self:settext(("%.02f"):format(exPercent))
		else
			self:settext(percent)
		end

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

		local showEx, showHardEx, scoreMode = active_score_flags()
		apply_score_color(self, showEx, showHardEx)
		if showHardEx then
			self:settext(("%.02f"):format(params.HardExScore))
		elseif showEx then
			self:settext(("%.02f"):format(params.ExScore))
		else
			return
		end

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
}
