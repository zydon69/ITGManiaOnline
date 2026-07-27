local player, controller = unpack(...)

local pn = ToEnumShortString(player)
local pss = GetEvaluationPlayerStageStats and GetEvaluationPlayerStageStats(player) or STATSMAN:GetCurStageStats():GetPlayerStageStats(player)

-- ============================================================================
-- MANUAL P2 CALIBRATION (EX + HardEX) — do not change without a two-local-
-- player in-game evaluation check.
--
-- Pane1 is the ITG reference pane. The validated shared value offset is +230.
-- It intentionally moves tap counts, radar counts, and /possible together.
-- ============================================================================
local P2ExValueOffset = (controller == PLAYER_2
	and (SL[pn].ActiveModifiers.ShowExScore or SL[pn].ActiveModifiers.ShowHardEXScore)) and 230 or 0

local TapNoteScores = {
	Types = { 'W1', 'W2', 'W3', 'W4', 'W5', 'Miss' },
	-- x values for P1 and P2
	x = { P1=64, P2=-128 + P2ExValueOffset }
}

local RadarCategories = {
	Types = { 'Hands', 'Holds', 'Mines', 'Rolls' },
	-- x values for P1 and P2
	x = { P1=-180, P2=-3 + P2ExValueOffset }
}

local SlashPossibleX = { P1=-114, P2=61 + P2ExValueOffset }

local t = Def.ActorFrame{
	InitCommand=function(self)self:zoom(0.8):xy(90,_screen.cy-24) end,
	OnCommand=function(self)
		-- shift the x position of this ActorFrame to -90 for PLAYER_2
		if controller == PLAYER_2 then
			self:x( self:GetX() * -1 )
		end
	end
}

-- do "regular" TapNotes first
for i=1,#TapNoteScores.Types do
	local window = TapNoteScores.Types[i]
	local number = pss:GetTapNoteScores( "TapNoteScore_"..window )

	-- actual numbers
	t[#t+1] = Def.RollingNumbers{
		Font="Wendy/_ScreenEvaluation numbers",
		InitCommand=function(self)
			self:zoom(0.5):horizalign(right)

			self:diffuse( SL.JudgmentColors[SL.Global.GameMode][i] )

			-- if some TimingWindows were turned off, the leading 0s should not
			-- be colored any differently than the (lack of) JudgmentNumber,
			-- so load a unique Metric group.
			if SL[pn].ActiveModifiers.TimingWindows[i]==false and i ~= #TapNoteScores.Types then
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
			self:y((i-1)*35 -20)
			self:targetnumber(number)
		end
	}

end

-- then handle hands/ex, holds, mines, rolls
for index, RCType in ipairs(RadarCategories.Types) do
    local performance = pss:GetRadarActual():GetValue( "RadarCategory_"..RCType )
    local possible = pss:GetRadarPossible():GetValue( "RadarCategory_"..RCType )
    possible = clamp(possible, 0, 999)

    -- player performance value
    -- use a RollingNumber to animate the count tallying up for visual effect
    t[#t+1] = Def.RollingNumbers{
        Font="Wendy/_ScreenEvaluation numbers",
        InitCommand=function(self) self:zoom(0.5):horizalign(right):Load("RollingNumbersEvaluationB") end,
        BeginCommand=function(self)
            self:x( RadarCategories.x[ToEnumShortString(controller)] )
            self:y((index-1)*35 + 53)
            self:targetnumber(performance)
        end
    }

    -- slash and possible value
    t[#t+1] = LoadFont("Wendy/_ScreenEvaluation numbers")..{
        InitCommand=function(self) self:zoom(0.5):horizalign(right) end,
        BeginCommand=function(self)
            self:x( SlashPossibleX[ToEnumShortString(controller)] )
            self:y((index-1)*35 + 53)
            self:settext(("/%03d"):format(possible))
            local leadingZeroAttr = { Length=4-tonumber(tostring(possible):len()), Diffuse=color("#5A6166") }
            self:AddAttribute(0, leadingZeroAttr )
        end
    }
end

return t
