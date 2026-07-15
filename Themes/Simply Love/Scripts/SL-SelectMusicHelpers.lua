-- ----------------------------------------------------------------------------------------
-- functions used by ScreenSelectMusicCasual

local function sl_select_music_trace(message)
	local line = "SL-SelectMusicHelpers: " .. tostring(message or "")
	if type(Trace) == "function" then
		Trace(line)
	elseif type(Warn) == "function" then
		Warn(line)
	end
end

local function safe_call(context, fn)
	if type(fn) ~= "function" then return false, nil end
	local ok, result = pcall(fn)
	if not ok then
		sl_select_music_trace("safe_call_failed context=" .. tostring(context or "unknown")
			.. " error=" .. tostring(result))
		return false, nil
	end
	return true, result
end

local function finite_number_or(value, fallback)
	value = tonumber(value)
	if value ~= nil and value == value and value ~= math.huge and value ~= -math.huge then
		return value
	end
	return fallback
end

local function clamp_number(value, minimum, maximum, fallback)
	value = finite_number_or(value, fallback or minimum)
	if value < minimum then return minimum end
	if value > maximum then return maximum end
	return value
end

local function bool_or(value, fallback)
	if value == nil then return fallback == true end
	if value == true or value == false then return value end
	local text = tostring(value):lower()
	if text == "1" or text == "true" or text == "yes" or text == "on" then return true end
	if text == "0" or text == "false" or text == "no" or text == "off" then return false end
	return fallback == true
end

local function safe_theme_pref(name, fallback)
	if not (ThemePrefs and type(ThemePrefs.Get) == "function") then return fallback end
	local ok, value = safe_call("ThemePrefs.Get " .. tostring(name), function()
		return ThemePrefs.Get(name)
	end)
	if not ok or value == nil then return fallback end
	return value
end

local function safe_preference_number(name, fallback)
	if not (PREFSMAN and type(PREFSMAN.GetPreference) == "function") then return fallback end
	local ok, value = safe_call("PREFSMAN.GetPreference " .. tostring(name), function()
		return PREFSMAN:GetPreference(name)
	end)
	return finite_number_or(ok and value or nil, fallback)
end

local function safe_theme_string(group, key)
	if not (THEME and type(THEME.GetString) == "function") then return tostring(key or "") end
	local ok, value = safe_call("THEME.GetString " .. tostring(group) .. "." .. tostring(key), function()
		return THEME:GetString(group, key)
	end)
	return ok and tostring(value or key or "") or tostring(key or "")
end

local function safe_is_course_mode()
	if not (GAMESTATE and type(GAMESTATE.IsCourseMode) == "function") then return false end
	local ok, isCourse = safe_call("GAMESTATE.IsCourseMode", function()
		return GAMESTATE:IsCourseMode()
	end)
	return ok and isCourse == true
end

local function safe_current_song()
	if not (GAMESTATE and type(GAMESTATE.GetCurrentSong) == "function") then return nil end
	local ok, song = safe_call("GAMESTATE.GetCurrentSong", function()
		return GAMESTATE:GetCurrentSong()
	end)
	return ok and song or nil
end

local function safe_song_method(song, method)
	if not (song and type(song[method]) == "function") then return nil end
	local ok, value = safe_call("Song." .. tostring(method), function()
		return song[method](song)
	end)
	return ok and value or nil
end

local function safe_sample_music_loops()
	return bool_or(safe_theme_pref("SampleMusicLoops", true), true)
end

local function safe_sound_volume()
	return clamp_number(safe_preference_number("SoundVolume", 1.0), 0, 1, 1.0)
end

local function safe_stop_music()
	if not (SOUND and type(SOUND.PlayMusicPart) == "function") then return false end
	local ok = safe_call("SOUND.PlayMusicPart stop", function()
		SOUND:PlayMusicPart("", 0, 0)
	end)
	return ok
end

local function song_sample(song)
	local songpath = safe_song_method(song, "GetMusicPath")
	local sample_start = finite_number_or(safe_song_method(song, "GetSampleStart"), nil)
	local sample_len = finite_number_or(safe_song_method(song, "GetSampleLength"), nil)
	if type(songpath) ~= "string" or songpath == "" then
		return nil, "missing_music_path"
	end
	if sample_start == nil or sample_start < 0 then
		return nil, "invalid_sample_start"
	end
	if sample_len == nil or sample_len <= 0 then
		return nil, "invalid_sample_length"
	end
	return {
		path = songpath,
		start = sample_start,
		length = sample_len,
	}, nil
end

local function play_song_sample(song, options)
	options = type(options) == "table" and options or {}
	local sample = type(options.sample) == "table" and options.sample or nil
	local reason = nil
	if not sample then
		sample, reason = song_sample(song)
	end
	if not sample then
		sl_select_music_trace("sample_music_skipped reason=" .. tostring(reason or "unknown")
			.. " source=" .. tostring(options.source or "unknown"))
		safe_stop_music()
		return false
	end

	if not (SOUND and type(SOUND.PlayMusicPart) == "function") then
		return false
	end
	if type(SOUND.DimMusic) == "function" then
		safe_call("SOUND.DimMusic", function()
			SOUND:DimMusic(safe_sound_volume(), math.huge)
		end)
	end
	local sampleLoops = options.loop == nil
		and safe_sample_music_loops()
		or options.loop == true
	local ok = safe_call("SOUND.PlayMusicPart sample", function()
		if options.normalRate == true then
			SOUND:PlayMusicPart(sample.path, sample.start, sample.length, 0.5, 1.5, sampleLoops, false, true)
		else
			SOUND:PlayMusicPart(sample.path, sample.start, sample.length, 0.5, 1.5, sampleLoops, options.applyMusicRate ~= false)
		end
	end)
	if not ok then safe_stop_music() end
	return ok
end

-- used by SSMCasual to play preview music of the current song
-- this is invoked each time the custom MusicWheel changes focus
play_sample_music = function()
	if safe_is_course_mode() then return false end
	local song = safe_current_song()
	if not song then
		stop_music()
		return false
	end
	local onlinePhase = ITGOnline and ITGOnline.currentRoom and tostring(ITGOnline.currentRoom.phase or "") or ""
	local onlinePreview = ITGOnline
		and ITGOnline.currentRoomId ~= nil
		and ITGOnline.currentRoom ~= nil
		and (onlinePhase == "lobby" or onlinePhase == "lobby_ready" or onlinePhase == "config")
		and ITGOnline.currentRoom.selected_song == nil
	return play_song_sample(song, {
		source = onlinePreview and "online_manager_music_wheel" or "casual_music_wheel",
		applyMusicRate = true,
		-- Online participants can remain on a focused song indefinitely.  Their
		-- shared preview must therefore not depend on the local theme preference.
		loop = onlinePreview and true or nil,
	})
end

-- used by SSMCasual to stop playing preview music,
-- this is invoked every time the custom MusicWheel changes focus
-- if the new focus is on song item, play_sample_music() will be invoked immediately afterwards
-- ths is also invoked when the player closes the current group to choose some other group
stop_music = function()
	return safe_stop_music()
end

local function online_preview_trim(value)
	return tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function online_preview_song_path(songInfo)
	if type(songInfo) ~= "table" then return "" end
	return online_preview_trim(songInfo.songPath
		or songInfo.song_path
		or songInfo.path
		or songInfo.folder
		or songInfo.folder_name)
end

local function online_preview_find_song(songInfo)
	if not (SONGMAN and SONGMAN.FindSong) then return nil end
	local songPath = online_preview_song_path(songInfo)
	if songPath == "" then return nil end

	local song = SONGMAN:FindSong(songPath)
	if song then return song end

	local relative = songPath:match("^[^/]+/(.+)$")
	if relative then
		song = SONGMAN:FindSong(relative)
		if song then return song end
	end

	local pack = online_preview_trim(songInfo.pack or songInfo.group or songInfo.group_name)
	local title = online_preview_trim(songInfo.title or songInfo.song or songInfo.name or songInfo.folder_name)
	if pack ~= "" and title ~= "" then
		return SONGMAN:FindSong(pack .. "/" .. title)
	end

	return nil
end

play_online_preview_music_normal_rate = function(songInfo, source)
	if safe_is_course_mode() then return false end
	if not SOUND then return false end

	local song = online_preview_find_song(songInfo)
	if not song then
		if online_flow_trace then
			online_flow_trace("online_preview_music_skipped reason=local_song_missing"
				.. " source=" .. tostring(source or "unknown")
				.. " path=" .. tostring(online_preview_song_path(songInfo)))
		end
		stop_music()
		return false
	end

	local sample, reason = song_sample(song)
	if not sample then
		sl_select_music_trace("online_preview_music_skipped reason=" .. tostring(reason or "unknown")
			.. " source=" .. tostring(source or "unknown"))
		stop_music()
		return false
	end

	if online_flow_trace then
		online_flow_trace("online_preview_music_play_normal_rate"
			.. " source=" .. tostring(source or "unknown")
			.. " path=" .. tostring(sample.path)
			.. " sampleStart=" .. tostring(sample.start)
			.. " sampleLen=" .. tostring(sample.length)
			.. " loop=true"
			.. " activeMusicRate=" .. tostring(SL and SL.Global and SL.Global.ActiveModifiers and SL.Global.ActiveModifiers.MusicRate or "nil")
			.. " applyMusicRate=false")
	end
	return play_song_sample(song, {
		source = source or "online_preview",
		applyMusicRate = false,
		normalRate = true,
		loop = true,
		sample = sample,
	})
end


----------------------------------------------------------------------------------------
-- functions used by ScreenSelectMusic

-- TextBanner is an engine-defined ActorFrame that contains three BitmapText actors named
-- "Title", "Subtitle", and "Artist".  Simply Love's MusicWheel only uses the first two.
--
-- It has two unique Metrics, "AfterSetCommand" and "ArtistPrependString"
-- Simply Love is only concerned with "AfterSetCommand"
-- because the song Artist does not appear in each MusicWheelItem

TextBannerAfterSet = function(self)
	-- acquire handles to two of the BitmapText children of this TextBanner ActorFrame
	-- we'll use them to position each song's Title and Subtitle as they appear in the MusicWheel
	if not (self and type(self.GetChild) == "function") then return end
	local okTitle, Title = safe_call("TextBanner.GetChild Title", function()
		return self:GetChild("Title")
	end)
	local okSubtitle, Subtitle = safe_call("TextBanner.GetChild Subtitle", function()
		return self:GetChild("Subtitle")
	end)
	Title = okTitle and Title or nil
	Subtitle = okSubtitle and Subtitle or nil
	if not (Title and type(Title.y) == "function") then return end

	-- assume the song's Subtitle is an empty string by default and position the Title
	-- in the vertical middle of the MusicWheelItem
	safe_call("TextBanner.Title.y", function()
		Title:y(0)
	end)

	-- if the Subtitle isn't an empty string
	local subtitleText = ""
	if Subtitle and type(Subtitle.GetText) == "function" then
		local okText, text = safe_call("TextBanner.Subtitle.GetText", function()
			return Subtitle:GetText()
		end)
		subtitleText = okText and tostring(text or "") or ""
	end
	if Subtitle and type(Subtitle.y) == "function" and subtitleText ~= "" then
		-- offset the Title's y() by -6 pixels
		safe_call("TextBanner.Title.y subtitle", function()
			Title:y(-6)
		end)
		-- and offset the Subtitle's y() by 6 pixels
		safe_call("TextBanner.Subtitle.y", function()
			Subtitle:y(6)
		end)
	end
end

----------------------------------------------------------------------------------------
-- functions used by both SSM and SSMCasual

SSM_Header_StageText = function()
	local stageLabel = safe_theme_string("Stage", "Stage")
	local playedThisGame = 0
	if SL and SL.Global and SL.Global.Stages then
		playedThisGame = math.max(0, math.floor(finite_number_or(SL.Global.Stages.PlayedThisGame, 0)))
	end
	local function numbered_stage(offset)
		return stageLabel .. " " .. tostring(playedThisGame + (tonumber(offset) or 1))
	end

	-- if the continue system is enabled, don't worry about determining "Final Stage"
	if finite_number_or(safe_theme_pref("NumberOfContinuesAllowed", 0), 0) > 0 then
		return numbered_stage(1)
	end

	local topscreen = nil
	if SCREENMAN and type(SCREENMAN.GetTopScreen) == "function" then
		local ok, screen = safe_call("SCREENMAN.GetTopScreen", function()
			return SCREENMAN:GetTopScreen()
		end)
		topscreen = ok and screen or nil
	end
	local topScreenName = ""
	if topscreen and type(topscreen.GetName) == "function" then
		local ok, name = safe_call("Screen.GetName", function()
			return topscreen:GetName()
		end)
		topScreenName = ok and tostring(name or "") or ""
	end
	if topScreenName ~= "" then

		-- if we're on ScreenEval for normal gameplay
		-- we might want to display the text for StageFinal, or we might want to
		-- increment the Stages.PlayedThisGame by the cost of the song that was just played
		if topScreenName == "ScreenEvaluationStage" then
			local song = safe_current_song()
			local Duration = finite_number_or(safe_song_method(song, "GetLastSecond"), 0)
			local MusicRate = 1
			if SL and SL.Global and SL.Global.ActiveModifiers then
				MusicRate = finite_number_or(SL.Global.ActiveModifiers.MusicRate, 1)
			end
			if MusicRate <= 0 then MusicRate = 1 end
			local DurationWithRate = math.max(0, Duration) / MusicRate

			local LongCutoff = safe_preference_number("LongVerSongSeconds", nil)
			local MarathonCutoff = safe_preference_number("MarathonVerSongSeconds", nil)

			local IsMarathon = MarathonCutoff and MarathonCutoff > 0 and (DurationWithRate/MarathonCutoff > 1)
			local IsLong 	 = LongCutoff and LongCutoff > 0 and (DurationWithRate/LongCutoff > 1)

			local SongCost = (IsMarathon and 3) or (IsLong and 2) or 1

			local songsPerPlay = math.max(1, math.floor(safe_preference_number("SongsPerPlay", 1)))
			if playedThisGame + SongCost >= songsPerPlay then
				return safe_theme_string("Stage", "Final")
			else
				return numbered_stage(SongCost)
			end

		-- if we're on ScreenEval within Marathon Mode, generic text will suffice
		elseif topScreenName == "ScreenEvaluationNonstop" then
			return safe_theme_string("ScreenSelectPlayMode", "Marathon")

		-- if we're on ScreenSelectMusic, display the number of Stages.PlayedThisGame + 1
		-- the song the player actually selects may cost more than 1, but we cannot know that now
		else
			return numbered_stage(1)
		end
	end
	return numbered_stage(1)
end
