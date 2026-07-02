local player = ...
if not player then return Def.Actor end

local StepchartOptRowIndex = nil
for i, name in ipairs(split(",", THEME:GetMetric("ScreenPlayerOptions", "LineNames"))) do
	if name == "Stepchart" then
		StepchartOptRowIndex = i - 1
		break
	end
end

local PlayerOnStepChartOptRow = function(p)
	if not StepchartOptRowIndex then return false end
	local ok, row = pcall(function()
		return SCREENMAN:GetTopScreen():GetCurrentRowIndex(p)
	end)
	return ok and row == StepchartOptRowIndex
end

return Def.Quad {
	Name="CursorLeft",
	InitCommand=function(self) self:zoomto(2,26) end,
	OptionRowChangedMessageCommand=function(self)
		if PlayerOnStepChartOptRow(player) then
			self:y(player == PLAYER_1 and 1 or 3):zoomto(2,30)
		else
			self:y(player == PLAYER_1 and -1 or 1):zoomto(2,26)
		end
	end
}
