-- This file will track the time that a player fails and show on the Evaluation screen.
-- Additionally, if the player fails inside a stream (16ths or higher) it will display 
-- the position in the stream (16ths) that they fail.

-- This does not count if the player holds start to fail

local player = ...
local routineShared = IsRoutine and IsRoutine()
local sourcePlayer = routineShared and GAMESTATE:GetMasterPlayerNumber() or player
local pn = ToEnumShortString(sourcePlayer)

local NotifyOnlineFailed = function()
    if ITGOnline and ITGOnline.MarkPlayFailedEarly then
        ITGOnline:MarkPlayFailedEarly("health_state_dead")
    end
end

local IsDeadHealthState = function(value)
    local state = tostring(value or "")
    return state == "Dead"
        or state == "HealthState_Dead"
        or state == "0"
end

-- Return an array of cumulativeSeconds for each song in a course, which is used by Step Statistics Time.lua
local CourseLengthPerSong = function(player)
    local cumulativeSeconds = {}
    if GAMESTATE:IsCourseMode() then
        local rate = SL.Global.ActiveModifiers.MusicRate
        local seconds = 0
        local trail = GAMESTATE:GetCurrentTrail(player)

        if trail then
            local entries = trail:GetTrailEntries()
            for i, entry in ipairs(entries) do
                seconds = seconds + (entry:GetSong():GetLastSecond() / rate)
                table.insert(cumulativeSeconds, seconds)
            end
        end
        return cumulativeSeconds
    end
end

-- Return the current time of the course or song, in seconds
local CurrentTimeSongOrCourse = function(player)
    local playerState = GAMESTATE:GetPlayerState(player)	
    local seconds = 0
    local rate = SL.Global.ActiveModifiers.MusicRate

    if GAMESTATE:IsCourseMode() then
        local cumulativeSeconds = CourseLengthPerSong(player)
        
        -- Find out what song in the course and add up all the previous songs
        local courseIndex = GAMESTATE:GetCourseSongIndex()
		if courseIndex > 0 then
			seconds = cumulativeSeconds[courseIndex]
		end

        -- Thenn add on the current song's timer
        local currentSongTimer = playerState:GetSongPosition():GetMusicSecondsVisible()
        currentSongTimer = currentSongTimer / rate
        seconds = seconds + currentSongTimer
    else
        seconds = playerState:GetSongPosition():GetMusicSecondsVisible() / rate
    end

    return seconds
end

-- Return the total length of the current song or course, in seconds
local TotalLengthSongOrCourse = function(player)
    local totalSeconds = 0
    if GAMESTATE:IsCourseMode() then
        local trail = GAMESTATE:GetCurrentTrail(player)
        if trail then
            totalSeconds = trail:GetLengthSeconds()
        end
    else
        local song = GAMESTATE:GetCurrentSong()
        if song then
            totalSeconds = song:GetLastSecond()
        end
    end

    -- totalSeconds is initilialzed in the engine as -1
    -- https://github.com/stepmania/stepmania/blob/6a645b4710/src/Song.cpp#L80
    -- and might not have ever been set to anything meaningful in edge cases
    -- e.g. ogg file is 5 seconds, ssc file has 1 tapnote occuring at beat 0
    if totalSeconds < 0 then totalSeconds = 0 end

    local rate = SL.Global.ActiveModifiers.MusicRate
    totalSeconds = totalSeconds / rate

    return totalSeconds
end

local af = Def.Actor{
	HealthStateChangedMessageCommand=function(self, param)
		-- Only do something if the player fails
		if param.PlayerNumber == sourcePlayer and IsDeadHealthState(param.HealthState) then
			NotifyOnlineFailed()

			local playerState = GAMESTATE:GetPlayerState(sourcePlayer)
			if not playerState then return end

			-- These functions already account for rate mod
			local currentSecond = CurrentTimeSongOrCourse(sourcePlayer)
			-- The course mode graph only shows lifebar history for the entire course up until the end
            -- of the current song. So for positioning in course mode, we need to find the total time
            -- of all the songs up until the end of the current song. This is *maybe* correct.
			local totalSeconds = TotalLengthSongOrCourse(sourcePlayer)
			local deathSecond = CurrentTimeSongOrCourse(sourcePlayer)
			local graphPercentage = 0
            local graphLabel = 0

			if GAMESTATE:IsCourseMode() then 
				local cumulativeSeconds = CourseLengthPerSong(sourcePlayer)
				local courseIndex = GAMESTATE:GetCourseSongIndex()
				local totalSecondsToEndOfSong = cumulativeSeconds and cumulativeSeconds[courseIndex+1] or totalSeconds

				graphPercentage = totalSecondsToEndOfSong > 0 and deathSecond / totalSecondsToEndOfSong or 0
				graphLabel = totalSeconds > 0 and deathSecond / totalSeconds or 0
			else 
				graphPercentage = totalSeconds > 0 and deathSecond / totalSeconds or 0
				graphLabel = totalSeconds - deathSecond
			end

			local currentMeasure = math.floor(playerState:GetSongPosition():GetSongBeatVisible()/4)

			local streams = SL[pn] and SL[pn].Streams
			local storage = SL[pn] and SL[pn].Stages and SL[pn].Stages.Stats[SL.Global.Stages.PlayedThisGame + 1]
			if not storage then
				if type(online_logs_enabled) == "function" and online_logs_enabled() and Trace then
					Trace("ROUTINE_UI TrackFailTime skipped missing storage player="
						.. tostring(ToEnumShortString(player))
						.. " source=" .. tostring(pn)
						.. " routine_shared=" .. tostring(routineShared == true))
				end
				return
			end

			storage.TotalSeconds = totalSeconds
			storage.DeathSecond = deathSecond
			storage.GraphPercentage = graphPercentage
			storage.GraphLabel = graphLabel

			-- find out if this measure was a stream (16ths or higher)
			if streams and streams.NotesPerMeasure and streams.NotesPerMeasure[currentMeasure+1] and streams.NotesPerMeasure[currentMeasure+1] >= 16 then
				-- find out which measure the fail was 
				for i=1,#(streams.Measures or {}) do
					if currentMeasure >= streams.Measures[i].streamStart and currentMeasure < streams.Measures[i].streamEnd  then							
						local streamRun = currentMeasure - streams.Measures[i].streamStart + 1
						local streamTotal = streams.Measures[i].streamEnd - streams.Measures[i].streamStart
						storage.DeathMeasures = string.format("%s/%s", streamRun, streamTotal)
					end
				end
			end
		end
	end
}

return af
