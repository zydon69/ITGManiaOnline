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

return Def.ActorFrame {
	Def.Quad {
		Name="CursorTop",
		InitCommand=function(self) self:zoomto(1,2):y(-12) end,
	},
	Def.Quad {
		Name="CursorBottom",
		InitCommand=function(self) self:zoomto(1,2):y(12) end,
		OptionRowChangedMessageCommand=function(self)
			self:y(PlayerOnStepChartOptRow(player) and 16 or 12)
		end
	}
}
