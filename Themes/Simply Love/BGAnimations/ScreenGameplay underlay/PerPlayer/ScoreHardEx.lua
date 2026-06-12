local player = ...
local pn = ToEnumShortString(player)

local mods = SL[pn].ActiveModifiers
local IsUltraWide = (GetScreenAspectRatio() > 21/9)
local NumPlayers = #GAMESTATE:GetHumanPlayers()
local IsHardEX = SL[pn].ActiveModifiers.ShowHardEXScore

if not IsHardEX then return end
if mods.HideScore then return end

if NumPlayers > 1
and mods.NPSGraphAtTop
and not IsUltraWide
then
	return
end

local styletype = ToEnumShortString(GAMESTATE:GetCurrentStyle():GetStyleType())
local pos = {
	[PLAYER_1] = { x=(_screen.cx - clamp(_screen.w, 640, 854)/4.3),  y=56 },
	[PLAYER_2] = { x=(_screen.cx + clamp(_screen.w, 640, 854)/4.3), y=56 },
}

local StepsOrTrail = (GAMESTATE:IsCourseMode() and GAMESTATE:GetCurrentTrail(player)) or GAMESTATE:GetCurrentSteps(player)
local total_tapnotes = StepsOrTrail and StepsOrTrail:GetRadarValues(player):GetValue("RadarCategory_Notes") or 1
total_tapnotes = math.max(1, tonumber(total_tapnotes) or 1)
local digits = clamp(math.max(4, math.floor(math.log10(total_tapnotes)) + 1) - 4, 0, 3)

local NoteFieldIsCentered = (GetNotefieldX(player) == _screen.cx)
local hardExColor = color("#ff00cc")

return LoadFont("Wendy/_wendy monospace numbers")..{
	Text="0.00",
	Name=pn.."ScoreHardEx",
	InitCommand=function(self)
		if player == PLAYER_1 then
			self:valign(0):horizalign(left)
		else
			self:valign(0):horizalign(right)
		end
		self:zoom(0.25):diffuse(hardExColor)
	end,

	BeginCommand=function(self)
		if IsUltraWide and #GAMESTATE:GetHumanPlayers() > 1 then
			self:x(player == PLAYER_1 and 134 or _screen.w - 4)
			self:y(238)
			return
		end

		self:xy(pos[player].x, pos[player].y)

		if mods.NPSGraphAtTop and styletype ~= "OnePlayerTwoSides" then
			if mods.DataVisualizations == "Step Statistics" then
				local step_stats = self:GetParent():GetChild("StepStatsPane"..pn)
				if step_stats then
					if player == PLAYER_1 then
						if NoteFieldIsCentered then
							self:x(pos[OtherPlayer[player]].x + SL_WideScale(94, 112.5))
						else
							self:x(pos[OtherPlayer[player]].x - SL_WideScale(-84, -60))
						end
					else
						if NoteFieldIsCentered then
							self:x(pos[OtherPlayer[player]].x - 65.5)
						else
							self:x(pos[OtherPlayer[player]].x - SL_WideScale(-6, -2))
						end
					end
					self:y(282)
				end
			elseif not NoteFieldIsCentered then
				self:x(pos[OtherPlayer[player]].x + 115)
				self:y(pos[OtherPlayer[player]].y)
			end
		end

		if player == PLAYER_1 then
			self:addx(-6 - digits * 5)
		else
			self:addx(6 + digits * 5)
		end
	end,

	JudgmentMessageCommand=function(self, params)
		if params.Player ~= player then return end
		self:queuecommand("RedrawScore")
	end,
	RedrawScoreCommand=function(self)
		self:settext(("%.02f"):format(CalculateHardExScore(player)))
	end,
	ExCountsChangedMessageCommand=function(self, params)
		if params.Player ~= player then return end
		self:settext(("%.02f"):format(params.HardExScore))
	end,
}
