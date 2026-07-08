-- When AutoSetStyle is enabled, reset the engine style before ScreenSelectMusic
-- builds its wheel so mixed stepchart styles can remain visible side-by-side.

local actor = Def.Actor{}

local StyleFlowTrace = function(message)
	if type(online_logs_enabled) == "function" and not online_logs_enabled() then return end
	if Trace then
		Trace("ROUTINE_STYLE_FLOW auto_set_style " .. tostring(message or ""))
	end
end

local CurrentStyleName = function()
	local ok, style = pcall(function() return GAMESTATE:GetCurrentStyle() end)
	if not ok or not style then return "nil" end
	ok, style = pcall(function() return style:GetName() end)
	return ok and tostring(style or "nil") or "unknown"
end

local UseAutoStyle = function()
	return ThemePrefs.Get("AutoStyle") == "auto"
end

local GetCurrentGameName = function()
	local ok, game = pcall(function()
		return GAMESTATE:GetCurrentGame()
	end)
	if not ok or not game then return "" end

	ok, game = pcall(function()
		return game:GetName()
	end)
	return ok and tostring(game or "") or ""
end

local GetBaseStyle = function()
	local ok, sides_joined = pcall(function()
		return GAMESTATE:GetNumSidesJoined()
	end)
	if not ok then sides_joined = 1 end
	local style = (sides_joined == 1) and "single" or "versus"
	if GetCurrentGameName() == "techno" then
		style = style .. "8"
	end
	return style
end

StyleFlowTrace("init metric=" .. tostring(THEME:GetMetric("Common", "AutoSetStyle"))
	.. " pref=" .. tostring(ThemePrefs.Get("AutoStyle"))
	.. " style_before=" .. CurrentStyleName())

if THEME:GetMetric("Common", "AutoSetStyle") == true and UseAutoStyle() then
	local current_steps = {}
	for player in ivalues(PlayerNumber) do
		current_steps[player] = GAMESTATE:GetCurrentSteps(player)
	end

	local next_style = GetBaseStyle()
	StyleFlowTrace("set_begin next_style=" .. tostring(next_style)
		.. " style_before=" .. CurrentStyleName())
	pcall(function()
		GAMESTATE:SetCurrentStyle(next_style)
	end)
	StyleFlowTrace("set_end next_style=" .. tostring(next_style)
		.. " style_after=" .. CurrentStyleName())

	actor.OnCommand=function(self)
		for player in ivalues(PlayerNumber) do
			if current_steps[player] then
				pcall(function()
					GAMESTATE:SetCurrentSteps(player, current_steps[player])
				end)
			end
		end
		StyleFlowTrace("restore_steps style=" .. CurrentStyleName())
	end
end

return actor
