local player, controller = unpack(...)

local pn = ToEnumShortString(player)
local pss = GetEvaluationPlayerStageStats and GetEvaluationPlayerStageStats(player) or STATSMAN:GetCurStageStats():GetPlayerStageStats(player)
local usesExPrimaryLayout = SL[pn].ActiveModifiers.ShowExScore
	or SL[pn].ActiveModifiers.ShowHardEXScore

-- EX and HardEX promote Pane2 to the primary evaluation pane. Reuse the
-- proven ITG Pane1 value columns so P2's labels and values remain aligned.
local ITGPrimaryP2Positions = {
	TapNotes = -128,
	Radar = -3,
	Percent = 61,
	SlashPossible = 61,
}

-- When Pane2 remains the optional FA+ detail pane, keep its wider secondary
-- layout instead of moving that separate presentation.
local FAPlusDetailP2Positions = {
	TapNotes = 94,
	Radar = 218,
	Percent = 286,
	SlashPossible = 286,
}
local P2Positions = usesExPrimaryLayout
	and ITGPrimaryP2Positions
	or FAPlusDetailP2Positions

local TapNoteScores = {
	Types = { 'W0', 'W1', 'W2', 'W3', 'W4', 'W5', 'Miss' },
	Colors = {
		SL.JudgmentColors["ITG"][1], -- Fantastic Blue
		SL.JudgmentColors["FA+"][2], -- Just extract the Fantastic white color
        SL.JudgmentColors["ITG"][2], -- Yellow Excellent
		SL.JudgmentColors["ITG"][3], -- Green Great
		SL.JudgmentColors["ITG"][4], -- Purple Decent
		SL.JudgmentColors["ITG"][5], -- Way Off
		SL.JudgmentColors["ITG"][6], -- Red Miss
	},
	-- x values for P1 and P2
	x = { P1=64, P2=P2Positions.TapNotes }
}

local RadarCategories = {
	Types = { 'Holds', 'Mines', 'Rolls' },
	-- x values for P1 and P2
	x = { P1=-180, P2=P2Positions.Radar }
}

local PercentX = { P1=-114, P2=P2Positions.Percent }
local SlashPossibleX = { P1=-114, P2=P2Positions.SlashPossible }

-- TODO(Zankoku) - EX judgments are in storage now, so we shouldn't have to calculate this all over again
local counts = GetExJudgmentCounts(player)

local t = Def.ActorFrame{
	InitCommand=function(self)self:zoom(0.8):xy(90,_screen.cy-24) end,
	OnCommand=function(self)
		-- shift the x position of this ActorFrame to -90 for PLAYER_2
		if controller == PLAYER_2 then
			self:x( self:GetX() * -1 )
		end
	end
}

-- The FA+ window shares the status as the FA window.
-- If the FA window is disabled, then we consider the FA+ window disabled as well.
local windows = {SL[pn].ActiveModifiers.TimingWindows[1]}
for v in ivalues( SL[pn].ActiveModifiers.TimingWindows) do
	windows[#windows + 1] = v
end

-- do "regular" TapNotes first
for i=1,#TapNoteScores.Types do
	local window = TapNoteScores.Types[i]
	local number = counts[window] or 0

	-- actual numbers
	t[#t+1] = Def.RollingNumbers{
		Font="Wendy/_ScreenEvaluation numbers",
		InitCommand=function(self)
			self:zoom(0.5):horizalign(right)

			self:diffuse( TapNoteScores.Colors[i] )

			-- if some TimingWindows were turned off, the leading 0s should not
			-- be colored any differently than the (lack of) JudgmentNumber,
			-- so load a unique Metric group.
			if windows[i]==false and i ~= #TapNoteScores.Types then
				self:Load("RollingNumbersEvaluationNoDecentsWayOffs")
				self:diffuse(color("#444444"))

			-- Otherwise, We want leading 0s to be dimmed, so load the Metrics
			-- group "RollingNumberEvaluationA"	which does that for us.
			else
				self:Load("RollingNumbersEvaluationA")
			end
		end,
		BeginCommand=function(self)
			self:x( TapNoteScores.x[ToEnumShortString(controller)] )
			self:y((i-1)*32 -24)
			self:targetnumber(number)
		end
	}

end

-- then handle hands/ex, holds, mines, rolls
for index, RCType in ipairs(RadarCategories.Types) do
	-- Swap to displaying ITG score if we're showing EX score in gameplay.
	local percent = nil
	if SL[pn].ActiveModifiers.ShowExScore then
		local PercentDP = pss:GetPercentDancePoints()
		percent = FormatPercentScore(PercentDP):gsub("%%", "")
		-- Format the Percentage string, removing the % symbol
		percent = tonumber(percent)
	else
		percent = CalculateExScore(player)
	end

	if index == 1 then
		t[#t+1] = LoadFont("Wendy/_wendy white")..{
			Name="Percent",
			Text=("%.2f"):format(percent),
			InitCommand=function(self)
				self:horizalign(right):zoom(0.4)
				self:x( PercentX[ToEnumShortString(controller)] )
				self:y(47)
				
				if SL[pn].ActiveModifiers.ShowExScore then
					self:diffuse(Color.White)
				else
					self:diffuse( SL.JudgmentColors[SL.Global.GameMode][1] )
				end
			end
		}
	end

	local possible = counts["total"..RCType]
	local performance = counts[RCType]

	if RCType == "Mines" then
		-- The mines in the counts is mines hit but we want to display mines dodged.
		performance = possible - performance
	end

	possible = clamp(possible, 0, 999)

	-- player performance value
	-- use a RollingNumber to animate the count tallying up for visual effect
	t[#t+1] = Def.RollingNumbers{
		Font="Wendy/_ScreenEvaluation numbers",
		InitCommand=function(self) self:zoom(0.5):horizalign(right):Load("RollingNumbersEvaluationB") end,
		BeginCommand=function(self)
			self:x( RadarCategories.x[ToEnumShortString(controller)] )
			self:y((index)*35 + 53)
			self:targetnumber(performance)
		end
	}

	-- slash and possible value
	t[#t+1] = LoadFont("Wendy/_ScreenEvaluation numbers")..{
		InitCommand=function(self) self:zoom(0.5):horizalign(right) end,
		BeginCommand=function(self)
			self:x( SlashPossibleX[ToEnumShortString(controller)] )
			self:y(index*35 + 53)
			self:settext(("/%03d"):format(possible))
			local leadingZeroAttr = { Length=4-tonumber(tostring(possible):len()), Diffuse=color("#5A6166") }
			self:AddAttribute(0, leadingZeroAttr )
		end
	}
end

return t
