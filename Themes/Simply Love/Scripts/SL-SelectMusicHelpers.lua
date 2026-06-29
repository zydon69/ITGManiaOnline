-- ----------------------------------------------------------------------------------------
-- functions used by ScreenSelectMusicCasual

-- used by SSMCasual to play preview music of the current song
-- this is invoked each time the custom MusicWheel changes focus
play_sample_music = function()
	if GAMESTATE:IsCourseMode() then return end
	local song = GAMESTATE:GetCurrentSong()

	if song then
		local songpath = song:GetMusicPath()
		local sample_start = song:GetSampleStart()
		local sample_len = song:GetSampleLength()

		if songpath and sample_start and sample_len then
			SOUND:DimMusic(PREFSMAN:GetPreference("SoundVolume"), math.huge)
			SOUND:PlayMusicPart(songpath, sample_start,sample_len, 0.5, 1.5, ThemePrefs.Get("SampleMusicLoops"), true)
		else
			stop_music()
		end
	else
		stop_music()
	end
end

-- used by SSMCasual to stop playing preview music,
-- this is invoked every time the custom MusicWheel changes focus
-- if the new focus is on song item, play_sample_music() will be invoked immediately afterwards
-- ths is also invoked when the player closes the current group to choose some other group
stop_music = function()
	SOUND:PlayMusicPart("", 0, 0)
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
	if GAMESTATE:IsCourseMode() then return false end
	if not (SOUND and THEME) then return false end

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

	local songpath = song:GetMusicPath()
	local sample_start = song:GetSampleStart()
	local sample_len = song:GetSampleLength()
	if not (songpath and sample_start and sample_len) then
		stop_music()
		return false
	end

	if online_flow_trace then
		online_flow_trace("online_preview_music_play_normal_rate"
			.. " source=" .. tostring(source or "unknown")
			.. " path=" .. tostring(songpath)
			.. " sampleStart=" .. tostring(sample_start)
			.. " sampleLen=" .. tostring(sample_len)
			.. " activeMusicRate=" .. tostring(SL and SL.Global and SL.Global.ActiveModifiers and SL.Global.ActiveModifiers.MusicRate or "nil")
			.. " applyMusicRate=false")
	end
	SOUND:DimMusic(PREFSMAN:GetPreference("SoundVolume"), math.huge)
	SOUND:PlayMusicPart(songpath, sample_start, sample_len, 0.5, 1.5, ThemePrefs.Get("SampleMusicLoops"), false, true)
	return true
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
	local Title = self:GetChild("Title")
	local Subtitle = self:GetChild("Subtitle")

	-- assume the song's Subtitle is an empty string by default and position the Title
	-- in the vertical middle of the MusicWheelItem
	Title:y(0)

	-- if the Subtitle isn't an empty string
	if Subtitle:GetText() ~= "" then
		-- offset the Title's y() by -6 pixels
		Title:y(-6)
		-- and offset the Subtitle's y() by 6 pixels
		Subtitle:y(6)
	end
end

----------------------------------------------------------------------------------------
-- functions used by both SSM and SSMCasual

SSM_Header_StageText = function()

	-- if the continue system is enabled, don't worry about determining "Final Stage"
	if ThemePrefs.Get("NumberOfContinuesAllowed") > 0 then
		return THEME:GetString("Stage", "Stage") .. " " .. tostring(SL.Global.Stages.PlayedThisGame + 1)
	end

	local topscreen = SCREENMAN:GetTopScreen()
	if topscreen then

		-- if we're on ScreenEval for normal gameplay
		-- we might want to display the text for StageFinal, or we might want to
		-- increment the Stages.PlayedThisGame by the cost of the song that was just played
		if topscreen:GetName() == "ScreenEvaluationStage" then
			local song = GAMESTATE:GetCurrentSong()
			local Duration = song:GetLastSecond()
			local DurationWithRate = Duration / SL.Global.ActiveModifiers.MusicRate

			local LongCutoff = PREFSMAN:GetPreference("LongVerSongSeconds")
			local MarathonCutoff = PREFSMAN:GetPreference("MarathonVerSongSeconds")

			local IsMarathon = (DurationWithRate/MarathonCutoff > 1)
			local IsLong 	 = (DurationWithRate/LongCutoff > 1)

			local SongCost = (IsMarathon and 3) or (IsLong and 2) or 1

			if SL.Global.Stages.PlayedThisGame + SongCost >= PREFSMAN:GetPreference("SongsPerPlay") then
				return THEME:GetString("Stage", "Final")
			else
				return THEME:GetString("Stage", "Stage") .. " " .. tostring(SL.Global.Stages.PlayedThisGame + SongCost)
			end

		-- if we're on ScreenEval within Marathon Mode, generic text will suffice
		elseif topscreen:GetName() == "ScreenEvaluationNonstop" then
			return THEME:GetString("ScreenSelectPlayMode", "Marathon")

		-- if we're on ScreenSelectMusic, display the number of Stages.PlayedThisGame + 1
		-- the song the player actually selects may cost more than 1, but we cannot know that now
		else
			return THEME:GetString("Stage", "Stage") .. " " .. tostring(SL.Global.Stages.PlayedThisGame + 1)
		end
	end
end
