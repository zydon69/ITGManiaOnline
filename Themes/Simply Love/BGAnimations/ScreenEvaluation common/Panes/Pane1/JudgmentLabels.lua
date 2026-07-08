local player, controller = unpack(...)

local pn = ToEnumShortString(player)
local pss = GetEvaluationPlayerStageStats and GetEvaluationPlayerStageStats(player) or STATSMAN:GetCurStageStats():GetPlayerStageStats(player)
local controller_name = ToEnumShortString(controller)

local tns_string = "TapNoteScore" .. (SL.Global.GameMode=="ITG" and "" or SL.Global.GameMode)

local GetTNSStringFromTheme = function( arg )
	return THEME:GetString(tns_string, arg)
end

-- iterating through the TapNoteScore enum directly isn't helpful because the
-- sequencing is strange, so make our own data structures for this purpose
local TapNoteScores = {}
TapNoteScores.Types = { 'W1', 'W2', 'W3', 'W4', 'W5', 'Miss' }
TapNoteScores.Names = map(GetTNSStringFromTheme, TapNoteScores.Types)

local RadarCategories = {
	THEME:GetString("ScreenEvaluation", 'Hands'),
	THEME:GetString("ScreenEvaluation", 'Holds'),
	THEME:GetString("ScreenEvaluation", 'Mines'),
	THEME:GetString("ScreenEvaluation", 'Rolls')
}

local FrameX = { P1=50, P2=-50 }
local TapLabelX = { P1=28, P2=-28 }
local RadarLabelX = { P1=-160, P2=90 }

local t = Def.ActorFrame{
	InitCommand=function(self)
		self:xy(FrameX[controller_name], _screen.cy-24)
	end,
}

local windows = SL[pn].ActiveModifiers.TimingWindows

--  labels: W1, W2, W3, W4, W5, Miss

-- Shift labels left if any tap note counts exceeded 9999
-- The positioning logic breaks if we get to 7 digits, please nobody hit a million Fantastics
local maxCount = 1
for i=1, #TapNoteScores.Types do
	local window = TapNoteScores.Types[i]
	local number = pss:GetTapNoteScores( "TapNoteScore_"..window )
	if number > maxCount then maxCount = number end
end

for i=1, #TapNoteScores.Types do
	-- no need to add BitmapText actors for TimingWindows that were turned off
	if windows[i] or i==#TapNoteScores.Types then

		t[#t+1] = LoadFont("Common Normal")..{
			Text=TapNoteScores.Names[i]:upper(),
			InitCommand=function(self) self:zoom(0.833):horizalign(right):maxwidth(76) end,
			BeginCommand=function(self)
				self:x(TapLabelX[controller_name])
				if maxCount > 9999 then
					local length = math.floor(math.log10(maxCount)+1)
					local modifier = controller == PLAYER_1 and -11*(length-4) or 11*(length-4)
					local finalPos = 28 + modifier
					local finalZoom = 0.833 - 0.1*(length-4)
					self:x( (controller == PLAYER_1 and finalPos) or -finalPos ):zoom(finalZoom)
				end
				self:y((i-1)*28 -16)
				-- diffuse the JudgmentLabels the appropriate colors for the current GameMode
				self:diffuse( SL.JudgmentColors[SL.Global.GameMode][i] )
			end
		}
	end
end

-- labels: hands/ex, holds, mines, rolls
for index, label in ipairs(RadarCategories) do
    t[#t+1] = LoadFont("Common Normal")..{
        Text=label,
        InitCommand=function(self) self:zoom(0.833):horizalign(right) end,
        BeginCommand=function(self)
            self:x(RadarLabelX[controller_name])
            self:y((index-1)*28 + 41)
        end
    }
end

return t
