-- You know that spot under the rug where you sweep away all the dirty
-- details and then hope no one finds them?  This file is that spot.
--
-- The idea is basically to just throw setup-related stuff
-- in here that we don't want cluttering up default.lua
---------------------------------------------------------------------------

local function trace(msg)
	if lua and lua.ReportScriptError then
		lua.ReportScriptError("ScreenSelectMusicCasual: " .. tostring(msg))
	elseif Trace then
		Trace("ScreenSelectMusicCasual: " .. tostring(msg))
	end
end

local function finite_number_or(value, fallback)
	value = tonumber(value)
	if value == nil or value ~= value or value == math.huge or value == -math.huge then
		return fallback
	end
	return value
end

if not (GAMESTATE and SONGMAN and PREFSMAN and THEME) then
	trace("required managers are not available")
	return nil
end

-- because no one wants "Invalid PlayMode 7"
if GAMESTATE.SetCurrentPlayMode then
	pcall(function() GAMESTATE:SetCurrentPlayMode('PlayMode_Regular') end)
end

---------------------------------------------------------------------------
-- local junk
local margin = {
	w = WideScale(54,72),
	h = 30
}

-- FIXME: making numCols and numRows configurable variables made sense when SSMCasual was more grid-like
-- but groups are now a single row of coverflow, and songs follow a mostly-hardcoded U-shape transform
-- figure out what else depends on these and refactor
local numCols = 3
local numRows = 5

---------------------------------------------------------------------------
-- variables that are to be passed between files
local OptionsWheel = {}

-- simple option definitions
local OptionRows = LoadActor("./OptionRows.lua")

for player in ivalues( PlayerNumber ) do
	-- create the optionwheel for this player
	OptionsWheel[player] = setmetatable({disable_wrapping = true}, sick_wheel_mt)

	-- set up each optionrow for each optionwheel
	for i=1,#OptionRows do
		OptionsWheel[player][i] = setmetatable({}, sick_wheel_mt)
	end
end

local col = {
	how_many = numCols,
	w = (_screen.w/numCols) - margin.w,
}
local row = {
	how_many = numRows,
	h = ((_screen.h - (margin.h*(numRows-2))) / (numRows-2)),
}

---------------------------------------------------------------------------
-- a steps_type like "StepsType_Dance_Single" is needed so we can filter out steps that aren't suitable

local ok_style, current_style = pcall(function()
	return GAMESTATE:GetCurrentStyle()
end)
if not ok_style or not current_style then
	trace("missing current style")
	return nil
end

local ok_steps_type, steps_type = pcall(function()
	return current_style:GetStepsType()
end)
if not ok_steps_type or not steps_type then
	trace("missing current steps type")
	return nil
end

local GetCasualMaxMeter = function()
	return math.max(1, finite_number_or(ThemePrefs and ThemePrefs.Get and ThemePrefs.Get("CasualMaxMeter"), 10))
end

local GetLongSongSeconds = function()
	return math.max(0, finite_number_or(PREFSMAN:GetPreference("LongVerSongSeconds"), math.huge))
end

local SongIsUnlocked = function(song)
	if not (UNLOCKMAN and UNLOCKMAN.IsSongLocked) then return true end
	return UNLOCKMAN:IsSongLocked(song) == 0
end

local SongHasCasualSteps = function(song)
	if not (song and song.HasStepsType and song:HasStepsType(steps_type)) then return false end
	if song:GetLastSecond() >= GetLongSongSeconds() then return false end
	if not SongIsUnlocked(song) then return false end

	for steps in ivalues(song:GetStepsByStepsType(steps_type)) do
		if steps and steps.GetMeter and steps:GetMeter() <= GetCasualMaxMeter() then
			return true
		end
	end

	return false
end

local SongIsInGroups = function(song, groups)
	if not (song and groups) then return false end
	return FindInTable(song:GetGroupName(), groups) ~= nil
end

local SongIsCasualValid = function(song, groups)
	return SongIsInGroups(song, groups) and SongHasCasualSteps(song)
end

---------------------------------------------------------------------------
-- initializes sick_wheel OptionRows for the CurrentSong with needed information
-- this function is called when choosing a song, either actively (pressing START)
-- or passively (MenuTimer running out)

local InitOptionRowsForSingleSong = function()
	for pn in ivalues( PlayerNumber ) do
		OptionsWheel[pn]:set_info_set(OptionRows, 1)

		for i,row in ipairs(OptionRows) do
			if row.OnLoad then
				row.OnLoad(OptionsWheel[pn][i], pn, row:Choices(), row.Values())
			end
		end
	end
end

---------------------------------------------------------------------------
-- helper function used by GetGroups() and GetDefaultSong()
-- returns the contents of a txt file as an indexed table, split on newline

local GetFileContents = function(path)
	local contents = ""

	if not (FILEMAN and FILEMAN.DoesFileExist and RageFileUtil and RageFileUtil.CreateRageFile) then
		trace("file manager unavailable while reading " .. tostring(path))
		return {}, "unreadable"
	end

	if FILEMAN:DoesFileExist(path) then
		-- create a generic RageFile that we'll use to read the contents
		local file = RageFileUtil.CreateRageFile()
		-- the second argument here (the 1) signifies
		-- that we are opening the file in read-only mode
		if file:Open(path, 1) then
			contents = file:Read()
		else
			file:destroy()
			trace("could not open " .. tostring(path))
			return {}, "unreadable"
		end

		-- destroy the generic RageFile now that we have the contents
		file:destroy()
	else
		return {}, "missing"
	end

	-- split the contents of the file on newline
	-- to create a table of lines as strings
	local lines = {}
	for line in contents:gmatch("[^\r\n]+") do
		lines[#lines+1] = line
	end

	return lines, "ok"
end

---------------------------------------------------------------------------
-- provided a group title as a string, prune out songs that don't have valid steps
-- returns an indexed table of song objects

local PruneSongsFromGroup = function(group)
	local songs = {}
	local current_song = GAMESTATE:GetCurrentSong()
	local index = 1

	-- prune out songs that don't have valid steps
	for i,song in ipairs(SONGMAN:GetSongsInGroup(group)) do
		if SongHasCasualSteps(song) then
			songs[#songs+1] = song
		end
		-- we need to retain the index of the current song so we can set the SongWheel to start on it
		if current_song == song then index = #songs end
	end

	return songs, index
end

---------------------------------------------------------------------------
-- parse ./Other/CasualMode-Groups.txt to find which groups will appear in SSMCasual
-- returns an indexed table of group names as strings

local GetGroups = function()
	local path = THEME:GetCurrentThemeDirectory() .. "Other/CasualMode-Groups.txt"
	local preliminary_groups, status = GetFileContents(path)

	-- if the file didn't exist or was empty or contained no valid groups,
	-- return the full list of groups available to SM
	if status == "unreadable" then
		return {}, false
	end

	if preliminary_groups == nil or #preliminary_groups == 0 then
		return SONGMAN:GetSongGroupNames(), true
	end

	local groups = {}
	-- some Groups found in the file may not actually exist due to human error, typos, etc.
	for prelim_group in ivalues(preliminary_groups) do
		-- if this group exists
		if SONGMAN:DoesSongGroupExist( prelim_group ) then
			-- add this preliminary group to the table of finalized groups
			groups[#groups+1] = prelim_group
		end
	end

	if #groups > 0 then
		return groups, true
	else
		trace(path .. " contained no valid groups; falling back to all groups")
		return SONGMAN:GetSongGroupNames(), true
	end
end

---------------------------------------------------------------------------
-- parse ./Other/CasualMode-DefaultSong.txt to find one or more songs to
-- default to when SSMCasual first loads
-- returns a song object

local GetDefaultSong = function(groups)

	local path = THEME:GetCurrentThemeDirectory() .. "Other/CasualMode-DefaultSong.txt"
	local preliminary_songs = GetFileContents(path)

	-- verify that the song(s) specified actually exist
	local songs = {}
	if preliminary_songs and #preliminary_songs > 0 then
		for prelim_song in ivalues(preliminary_songs) do
			local song = SONGMAN:FindSong(prelim_song)
			if SongIsCasualValid(song, groups) then
				songs[#songs+1] = song
			end
		end
	end

	-- if multiple valid songs were found, randomly select and return one
	if #songs >= 2 then
		return songs[math.random(1, #songs)]

	-- if DefaultSong.txt only contained one song, return that
	elseif #songs == 1 then
		return songs[1]
	end

	-- fall back on first valid song from first valid group if needed
	for group in ivalues(groups) do
		local pruned_songs = PruneSongsFromGroup(group)
		if #pruned_songs > 0 then
			return pruned_songs[1]
		end
	end

	return nil
end


---------------------------------------------------------------------------
-- prune out groups that have no valid steps
-- passed an indexed table of strings representing potential group names
-- returns an indexed table of group names as strings

local PruneGroups = function(_groups)
	local groups = {}

	for group in ivalues( _groups ) do
		if #PruneSongsFromGroup(group) > 0 then
			groups[#groups+1] = group
		end
	end

	return groups
end

---------------------------------------------------------------------------
-- currently not used

local GetGroupInfo = function(groups)
	local info = {}
	for group in ivalues(groups) do
		local songs = PruneSongsFromGroup(group)
		local artists, genres, charts = {}, {}, {}

		info[group] = {}
		info[group].num_songs = #songs
		info[group].artists = ""
		info[group].genres = ""
		info[group].charts = ""

		for song in ivalues(songs) do
			if #artists < 5 then
				if song:GetDisplayArtist() ~= "" then
					artists[#artists+1] = song:GetDisplayArtist()
				end
			end

			if #genres < 5 then
				if song:GetGenre() ~= "" then
					genres[#genres+1] = song:GetGenre()
				end
			end

			for i,difficulty in ipairs(Difficulty) do
				-- don't care about edits
				if i>5 then break end
				if charts[difficulty] == nil then charts[difficulty] = 0 end

				if song:HasStepsTypeAndDifficulty(steps_type, difficulty) then
					charts[difficulty] = charts[difficulty] + 1
				end
			end
		end

		for i, a in ipairs(artists) do
			info[group].artists = info[group].artists .. "• " .. a .. (i ~= #artists and "\n" or "")
		end
		for i, g in ipairs(genres) do
			info[group].genres = info[group].genres .. "• " .. g .. (i ~= #genres and "\n" or "")
		end
		for i,difficulty in ipairs(Difficulty) do
			if i>5 then break end
			info[group].charts = info[group].charts .. charts[difficulty] .. " " .. THEME:GetString( "CustomDifficulty", ToEnumShortString(difficulty) ) .. "\n"
		end

	end
	return info
end

---------------------------------------------------------------------------


local current_song = GAMESTATE:GetCurrentSong()
local group_index = 1

-- GetGroups() will read from ./Other/CasualMode-Groups.txt
local groups, allow_global_retry = GetGroups()
-- prune the list of potential groups down to valid groups
groups = PruneGroups(groups)

-- it's possible the list used in GetGroups() was too limited and we
-- just pruned the table to be completely empty
-- in that case, try again using ALL groups available to StepMania
if #groups == 0 and allow_global_retry then
	groups = PruneGroups(SONGMAN:GetSongGroupNames())
end

-- If there are STILL no valid groups, we aren't going to find any.
-- return nil, which default.lua will interpret to mean the
-- player needs to be informed that this machine has no suitable
-- casual content...  D:
if #groups == 0 then
	return nil
end

-- there will be a current_song if we're on stage 2 or later
-- if no current_song, check ./Other/CasualMode-DefaultSong.txt
if not SongIsCasualValid(current_song, groups) then
	current_song = GetDefaultSong(groups)
end

if current_song == nil then
	trace("no valid default song found")
	return nil
end

if GAMESTATE:GetCurrentSong() ~= current_song then
	GAMESTATE:SetCurrentSong(current_song)
end

group_index = FindInTable(current_song:GetGroupName(), groups) or 1

return {
	steps_type=steps_type,
	Groups=groups,
	group_index=group_index,
	-- group_info=GetGroupInfo(groups),
	OptionsWheel=OptionsWheel,
	OptionRows=OptionRows,
	row=row,
	col=col,
	InitOptionRowsForSingleSong=InitOptionRowsForSingleSong,
	PruneSongsFromGroup=PruneSongsFromGroup
}
