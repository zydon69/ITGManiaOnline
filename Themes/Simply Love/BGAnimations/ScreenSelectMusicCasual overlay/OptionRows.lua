-- helper functions
local function finite_number_or(value, fallback)
	value = tonumber(value)
	if value == nil or value ~= value or value == math.huge or value == -math.huge then
		return fallback
	end
	return value
end

local function casual_max_meter()
	return math.max(1, finite_number_or(ThemePrefs and ThemePrefs.Get and ThemePrefs.Get("CasualMaxMeter"), 10))
end

local function current_song_playable_steps()
	if not (GAMESTATE and GAMESTATE.GetCurrentSong and SongUtil and SongUtil.GetPlayableSteps) then return {} end

	local song = GAMESTATE:GetCurrentSong()
	if not song then return {} end

	local steps = SongUtil.GetPlayableSteps(song) or {}
	local filtered_steps = {}

	-- prune out charts whose meter exceeds the specified max
	for chart in ivalues(steps) do
		if chart and chart.GetMeter and chart:GetMeter() <= casual_max_meter() then
			filtered_steps[#filtered_steps+1] = chart
		end
	end

	return filtered_steps
end

local GetDifficulty = function(steps)
	if not (steps and steps.GetDifficulty and steps.GetMeter) then return {"", ""} end
	return {THEME:GetString( "CustomDifficulty", steps:GetDifficulty():gsub("Difficulty_", "") ), steps:GetMeter()}
end

-- ------------------------------------------------------
local OptionRows = {
	{
		Name = "Charts",
		HelpText = THEME:GetString("ScreenSelectMusicCasual", "SelectDifficulty"),
		Choices = function(self) return map(GetDifficulty, self.Values()) end,
		Values = function()
			return current_song_playable_steps()
		end,
		OnLoad=function(actor, pn, choices, values)
			local index = 1
			values = type(values) == "table" and values or {}
			choices = type(choices) == "table" and choices or {}
			if #values == 0 or #choices == 0 then
				actor:set_info_set({{"", ""}}, 1)
				return
			end

			local current_meter = 1
			if GAMESTATE and GAMESTATE.IsHumanPlayer and GAMESTATE.GetCurrentSteps and GAMESTATE:IsHumanPlayer(pn) and GAMESTATE:GetCurrentSteps(pn) then
				current_meter = finite_number_or(GAMESTATE:GetCurrentSteps(pn):GetMeter(), 1)
			end

			-- if the player has a chart set (from a previous round, picking a song but then canceling, etc.),
			-- set this OptionRow's starting choice to the chart whose meter is closest without exceeding
			-- previous chart's meter.  I attempting to match by numerical Meter makes more sense for Casual mode than
			-- attempting to match by difficulty. It mitagates scenarios in which the previous song had a Medium 4
			-- but the current song has a Medium 10.
			for i,chart in ipairs(values) do
				if chart:GetMeter() <= current_meter then
					if current_meter-chart:GetMeter() < current_meter-values[index]:GetMeter() then
						index = i
					end
				end
			end
			actor:set_info_set(choices, index)
		end,
		OnSave=function(self, pn, choice, choices, values)
			if type(choice) ~= "table" then return false end
			choices = type(choices) == "table" and choices or self:Choices()
			values = type(values) == "table" and values or self:Values()
			if #choices == 0 or #values == 0 then return false end

			local index = 1
			for i,v in ipairs(choices) do
				if choice[1]==v[1] and choice[2]==v[2] then index=i; break end
			end

			if values[index] and GAMESTATE and GAMESTATE.SetCurrentSteps then
				GAMESTATE:SetCurrentSteps(pn, values[index])
				return true
			end
			return false
		end
	},
	-- ------------------------------------------------------
	{
		Name = "Speed",
		HelpText = THEME:GetString("ScreenSelectMusicCasual", "SelectSpeedMod"),
		Choices = function()
			return {
				THEME:GetString("ScreenSelectMusicCasual", "Normal"),
				THEME:GetString("ScreenSelectMusicCasual", "MoreSpace"),
				THEME:GetString("ScreenSelectMusicCasual", "LessSpace"),
			}
		end,
		Values = function() return {210, 300, 125} end,
		OnLoad=function(actor, pn, choices, values)
			local index = 1
			local player_state = GAMESTATE and GAMESTATE.GetPlayerState and GAMESTATE:GetPlayerState(pn) or nil
			local player_options = player_state and player_state.GetPlayerOptions and player_state:GetPlayerOptions("ModsLevel_Preferred") or nil
			local cmod = player_options and player_options.CMod and player_options:CMod() or nil
			if cmod then index = FindInTable(cmod,values) or 1 end
			actor:set_info_set(choices, index)
		end,
		OnSave=function(self, pn, choice, choices, values)
			local index = FindInTable(choice, choices)
			if not (index and values[index]) then return false end

			local player_state = GAMESTATE and GAMESTATE.GetPlayerState and GAMESTATE:GetPlayerState(pn) or nil
			local player_options = player_state and player_state.GetPlayerOptions and player_state:GetPlayerOptions("ModsLevel_Preferred") or nil
			if player_options and player_options.CMod then
				player_options:CMod(values[index])
				return true
			end
			return false
		end,
	},
}
-- ------------------------------------------------------

-- add Exit row last
OptionRows[#OptionRows + 1] = {
	Name = "Exit",
	HelpText = "",
}

return OptionRows
