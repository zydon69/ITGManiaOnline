local player = PLAYER_2
local last_stepchart_state

local function OptionsCursorTrace(message)
	if not Trace then return end
	if not (PREFSMAN and PREFSMAN:GetPreference("LogThemeLuaDiagnostics")) then return end
	Trace("SL_OPTIONS_CURSOR_TRACE " .. tostring(message or ""))
end

local function CurrentScreenName()
	local screen = SCREENMAN and SCREENMAN:GetTopScreen()
	return screen and screen:GetName() or ""
end

local function IsPlayerOptionsScreen()
	return CurrentScreenName():match("^ScreenPlayerOptions") ~= nil
end

local function StepchartRowIndex()
	if not IsPlayerOptionsScreen() then return nil end

	local ok, line_names = pcall(function()
		return THEME:GetMetric(CurrentScreenName(), "LineNames")
	end)
	if not ok or type(line_names) ~= "string" then return nil end

	for index, name in ipairs(split(",", line_names)) do
		if name == "Stepchart" then return index - 1 end
	end
	return nil
end

local function PlayerOnStepchartRow()
	local screen = SCREENMAN and SCREENMAN:GetTopScreen()
	local stepchart_row = StepchartRowIndex()
	if not screen or stepchart_row == nil then return false end

	local ok, current_row = pcall(function()
		return screen:GetCurrentRowIndex(player)
	end)
	return ok and current_row == stepchart_row
end

local function ApplyCursorShape(self)
	local on_stepchart = PlayerOnStepchartRow()
	if on_stepchart ~= last_stepchart_state then
		last_stepchart_state = on_stepchart
		OptionsCursorTrace(("player=P2 part=Middle screen=%s stepchart=%s")
			:format(CurrentScreenName(), tostring(on_stepchart)))
	end

	local bottom = self:GetChild("CursorBottom")
	if bottom then bottom:y(on_stepchart and 16 or 12) end
end

return Def.ActorFrame {
	BeginCommand=function(self) ApplyCursorShape(self) end,
	OptionRowChangedMessageCommand=function(self) ApplyCursorShape(self) end,
	Def.Quad {
		Name="CursorTop",
		InitCommand=function(self) self:zoomto(1,2):y(-12) end
	},
	Def.Quad {
		Name="CursorBottom",
		InitCommand=function(self) self:zoomto(1,2):y(12) end
	}
}
