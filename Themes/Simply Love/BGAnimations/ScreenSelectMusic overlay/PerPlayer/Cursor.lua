-- the difficulty grid and per-player bouncing cursors don't support CourseMode
-- CourseContentsList.lua should be used instead
if GAMESTATE:IsCourseMode() then return end
-- ----------------------------------------------

local player = ...
local pn = ToEnumShortString(player)
local p = PlayerNumber:Reverse()[player]

local GetStepsToDisplay = LoadActor("../StepsDisplayList/StepsToDisplay.lua")
-- I feel like this surely must be the wrong way to do this...
local GlobalOffsetSeconds = PREFSMAN:GetPreference("GlobalOffsetSeconds")
if PREFSMAN and PREFSMAN.LogGlobalOffsetDiagnostics then
	PREFSMAN:LogGlobalOffsetDiagnostics("lua_cursor_read GlobalOffsetSeconds=" .. tostring(GlobalOffsetSeconds))
end

local RowIndex = 1

local CursorTrace = function(message)
	if not PREFSMAN then return end
	local okContent, logContent = pcall(function()
		return PREFSMAN:GetPreference("LogContentLoadDiagnostics")
	end)
	local okTheme, logTheme = pcall(function()
		return PREFSMAN:GetPreference("LogThemeLuaDiagnostics")
	end)
	if not ((okContent and logContent) or (okTheme and logTheme)) then return end
	Trace("SELECT_MUSIC_CURSOR_TRACE " .. tostring(message or ""))
end

local StepsLabel = function(steps)
	if not steps then return "nil" end
	local stepsType = "unknown"
	local difficulty = "unknown"
	local meter = "?"
	local description = ""
	pcall(function() stepsType = ToEnumShortString(steps:GetStepsType()):gsub("_", "-"):lower() end)
	pcall(function() difficulty = ToEnumShortString(steps:GetDifficulty()) end)
	pcall(function() meter = tostring(steps:GetMeter()) end)
	pcall(function() description = tostring(steps:GetDescription() or "") end)
	return ("%s/%s/%s/%s"):format(stepsType, difficulty, meter, description)
end

return Def.Sprite{
	Texture=THEME:GetPathB("ScreenSelectMusic", "overlay/PerPlayer/arrow.png"),
	Name="Cursor"..pn,
	InitCommand=function(self)
		self:visible( GAMESTATE:IsHumanPlayer(player) )
		self:halign( p ):zoom(0.575)

		-- FIXME: SM5.1-beta's EffectClock enum includes constants for
		--   CLOCK_BGM_BEAT_PLAYER1 and CLOCK_BGM_BEAT_PLAYER2 but
		--   but effectclock(), the only method currently available via
		--   the Lua API, doesn't appear to have any way to use them.
		--
		--   effectclock in Lua maps to Actor::SetEffectClockString() in C++
		--   which handles a limited set of hardcoded english strings:
		--   "timer", "timerglobal", "beat", "music", "musicnooffset", and "beatnooffset"
		--   as well as some limited cabinet light handling.
		--
		--   Notably, there is not anything like "beatp1" or "beatp2" or "stepsbeat" or etc.
		--   The takeaway here is that these bouncing cursors will sync with song timing.
	 	--   If the current song uses steps timing, it will not be used in the bounce() effect.
		--
		--   One example of this is ACE FOR ACES, where some step timing is a steady 200bpm,
		--   while others are 50-400bpm, but the song timing is 200.  This song timing is what
		--   will be used to animate both players' bouncing cursors here, regardless of whether
		--   one or both are joined.  This would need to be fixed in the engine.
		self:bounce():effectclock("beatnooffset")

		if player == PLAYER_1 then
			self:x( IsUsingWideScreen() and _screen.cx-53 or 267)
			self:effectmagnitude(-3,0,0)
		elseif player == PLAYER_2 then
			self:rotationz(180)
			self:x(IsUsingWideScreen() and _screen.cx-17 or 303)
			self:effectmagnitude(3,0,0)
		end

		self:effectperiod(1):effectoffset( -10 * GlobalOffsetSeconds)
	end,

	PlayerJoinedMessageCommand=function(self, params)
		if params.Player == player then self:visible(true) end
	end,
	PlayerUnjoinedMessageCommand=function(self, params)
		if params.Player == player then self:visible(false) end
	end,

	OnCommand=function(self) self:queuecommand("Set") end,
	CurrentSongChangedMessageCommand=function(self) self:queuecommand("Set") end,
	-- Need to update when either player's selection changes because the other
	-- player's selection can change which steps are visible.
	CurrentStepsP1ChangedMessageCommand=function(self) self:queuecommand("Set") end,
	CurrentStepsP2ChangedMessageCommand=function(self) self:queuecommand("Set") end,

	SetCommand=function(self)
		local song = GAMESTATE:GetCurrentSong()
		local exactMatch = false
		local fallbackReason = "none"

		if song then
			local playable_steps = SongUtil.GetPlayableSteps( song )
			local current_steps = GAMESTATE:GetCurrentSteps(player)
			if song and FindInTable(song, SL[pn].Favorites) then 
				self:diffuse(color("#ffc0cb"))
			else
				self:diffuse(1,1,1,1) 
			end
			for i,chart in pairs( GetStepsToDisplay(playable_steps) ) do
				if chart == current_steps then
					RowIndex = i
					exactMatch = true
					break
				end
			end
			if current_steps and not exactMatch then
				local ok, difficulty = pcall(function()
					return current_steps:GetDifficulty()
				end)
				local difficultyIndex = ok and Difficulty:Reverse()[difficulty] or nil
				if difficultyIndex then
					RowIndex = difficultyIndex + 1
					fallbackReason = "difficulty"
				else
					RowIndex = 1
					fallbackReason = "default"
				end
			elseif not current_steps then
				RowIndex = 1
				fallbackReason = "no_current_steps"
			end
			CursorTrace(("set pn=%s row=%s exact=%s fallback=%s current=%s"):format(
				tostring(pn),
				tostring(RowIndex),
				tostring(exactMatch),
				tostring(fallbackReason),
				StepsLabel(current_steps)))
		end

		-- keep within reasonable limits because Edit charts are a thing
		RowIndex = clamp(RowIndex, 1, 5)

		-- update cursor y position
		local sdl = self:GetParent():GetParent():GetChild("StepsDisplayList")
		if sdl then
			local grid = sdl:GetChild("Grid")
			self:y(sdl:GetY() + grid:GetY() + grid:GetChild("Meter_"..RowIndex):GetY() + 1 )
		end
	end
}
