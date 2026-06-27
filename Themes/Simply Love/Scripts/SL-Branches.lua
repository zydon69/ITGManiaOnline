------------------------------------------------------------
-- Helper Functions for Branches
------------------------------------------------------------

local MAX_STAGE_ADD_BACK = 10

local BranchTrace = function(message)
	if type(online_trace) == "function" then
		online_trace("FLOW branch " .. tostring(message or ""))
	elseif Trace then
		Trace("SL-Branches: " .. tostring(message or ""))
	elseif Warn then
		Warn("SL-Branches: " .. tostring(message or ""))
	end
end

local SafeCall = function(context, fn)
	if type(fn) ~= "function" then return false, nil end
	local ok, result = pcall(fn)
	if not ok then
		BranchTrace("safe_call_failed context=" .. tostring(context or "unknown")
			.. " error=" .. tostring(result))
		return false, nil
	end
	return true, result
end

local IsCallable = function(value)
	return type(value) == "function"
end

local IsFiniteNumber = function(value)
	value = tonumber(value)
	return value ~= nil and value == value and value ~= math.huge and value ~= -math.huge
end

local FiniteNumberOr = function(value, fallback)
	value = tonumber(value)
	if IsFiniteNumber(value) then return value end
	return fallback
end

local ClampNumber = function(value, minimum, maximum)
	value = FiniteNumberOr(value, minimum)
	if value < minimum then return minimum end
	if value > maximum then return maximum end
	return value
end

local SafeThemePref = function(name, fallback)
	if not (ThemePrefs and IsCallable(ThemePrefs.Get)) then return fallback end
	local ok, value = SafeCall("ThemePrefs.Get " .. tostring(name), function()
		return ThemePrefs.Get(name)
	end)
	if not ok or value == nil then return fallback end
	return value
end

local SafePreference = function(name, fallback)
	if not (PREFSMAN and PREFSMAN.GetPreference) then return fallback end
	local ok, value = SafeCall("PREFSMAN.GetPreference " .. tostring(name), function()
		return PREFSMAN:GetPreference(name)
	end)
	if not ok or value == nil then return fallback end
	return value
end

local SafeEnumShort = function(value, fallback)
	if not IsCallable(ToEnumShortString) or value == nil then return fallback end
	local ok, result = SafeCall("ToEnumShortString", function()
		return ToEnumShortString(value)
	end)
	return ok and result or fallback
end

local SafeGameMode = function()
	return SL and SL.Global and SL.Global.GameMode or nil
end

local SafeCourseMode = function()
	if not (GAMESTATE and GAMESTATE.IsCourseMode) then return false end
	local ok, result = SafeCall("GAMESTATE.IsCourseMode", function()
		return GAMESTATE:IsCourseMode()
	end)
	return ok and result == true
end

local SafeCurrentStyle = function()
	if not (GAMESTATE and GAMESTATE.GetCurrentStyle) then return nil end
	local ok, style = SafeCall("GAMESTATE.GetCurrentStyle", function()
		return GAMESTATE:GetCurrentStyle()
	end)
	return ok and style or nil
end

local SafeCurrentStyleName = function()
	local style = SafeCurrentStyle()
	if not (style and style.GetName) then return nil end
	local ok, name = SafeCall("Style.GetName", function()
		return style:GetName()
	end)
	return ok and tostring(name or "") or nil
end

local SafeCurrentStyleType = function()
	local style = SafeCurrentStyle()
	if not (style and style.GetStyleType) then return nil end
	local ok, styleType = SafeCall("Style.GetStyleType", function()
		return style:GetStyleType()
	end)
	return ok and SafeEnumShort(styleType, nil) or nil
end

local NormalizeRoomPhase = function(phase)
	if ITGOnline and IsCallable(ITGOnline.NormalizeRoomPhase) then
		local ok, normalized = SafeCall("ITGOnline.NormalizeRoomPhase", function()
			return ITGOnline:NormalizeRoomPhase(phase)
		end)
		if ok and normalized then return tostring(normalized) end
	end
	return tostring(phase or ""):lower()
end

local CurrentOnlineUserId = function()
	return tostring(ITGOnline and ITGOnline.user and ITGOnline.user.id or "")
end

local OnlineRoomId = function(room)
	if type(room) ~= "table" then return "" end
	return tostring(room.id or room.room_id or room.roomId or "")
end

local OnlineUserIsRoomMember = function(room, userId)
	if type(room) ~= "table" then return false end
	userId = tostring(userId or "")
	if userId == "" then return false end

	for member in ivalues(type(room.members) == "table" and room.members or {}) do
		local user = type(member and member.user) == "table" and member.user or nil
		local memberId = tostring(member and (member.user_id or member.userId or member.playerId or member.id) or "")
		if memberId == userId or tostring(user and user.id or "") == userId then
			return true
		end
	end

	return false
end

local HasActiveOnlineRoom = function(options)
	options = type(options) == "table" and options or {}
	if not (ITGOnline and ITGOnline.currentRoomId and ITGOnline.currentRoom) then
		return false, nil, "missing_room"
	end

	local room = ITGOnline.currentRoom
	local expectedRoomId = tostring(ITGOnline.currentRoomId or "")
	local actualRoomId = OnlineRoomId(room)
	if expectedRoomId == "" or actualRoomId == "" or actualRoomId ~= expectedRoomId then
		return false, room, "room_id_mismatch"
	end

	local userId = CurrentOnlineUserId()
	if options.requireUser ~= false and userId == "" then
		return false, room, "missing_user"
	end

	if options.requireMember ~= false and not OnlineUserIsRoomMember(room, userId) then
		return false, room, "user_not_in_room"
	end

	if options.phase then
		local currentPhase = NormalizeRoomPhase(room.phase)
		local phases = type(options.phase) == "table" and options.phase or { options.phase }
		local phaseOk = false
		for phase in ivalues(phases) do
			if currentPhase == tostring(phase) then
				phaseOk = true
				break
			end
		end
		if not phaseOk then
			return false, room, "phase_mismatch"
		end
	end

	if options.requireRealtime == true and IsCallable(ITGOnline.RealtimeIsConnected) then
		local ok, connected = SafeCall("ITGOnline.RealtimeIsConnected", function()
			return ITGOnline:RealtimeIsConnected()
		end)
		if not ok or connected ~= true then
			return false, room, "realtime_disconnected"
		end
	end

	return true, room, nil
end

local OnlineRoomPhase = function(room)
	return NormalizeRoomPhase(room and room.phase or nil)
end

local OnlineEvaluationBranchState = function(room)
	local screen = SCREENMAN and SCREENMAN:GetTopScreen() or nil
	local screenName = screen and screen.GetName and screen:GetName() or "nil"
	local playState = ITGOnline and IsCallable(ITGOnline.CurrentUserPlayState)
		and ITGOnline:CurrentUserPlayState(room)
		or "nil"
	local roundKey = ITGOnline and IsCallable(ITGOnline.PlayStateKey)
		and ITGOnline:PlayStateKey()
		or ""
	local summary = ITGOnline and IsCallable(ITGOnline.PlayStateSummary)
		and ITGOnline:PlayStateSummary(room)
		or nil
	local userHasFinalResult = ITGOnline and IsCallable(ITGOnline.CurrentUserHasFinalResult)
		and ITGOnline:CurrentUserHasFinalResult(room)
		or false
	return " topScreen=" .. tostring(screenName)
		.. " playState=" .. tostring(playState)
		.. " roundKey=" .. tostring(roundKey)
		.. " shownKey=" .. tostring(ITGOnline and ITGOnline.onlineGameplayEvaluationShownKey or "")
		.. " returnedKey=" .. tostring(ITGOnline and ITGOnline.onlineGameplayEvaluationReturnedKey or "")
		.. " exitRequested=" .. tostring(ITGOnline and ITGOnline.onlineEvaluationExitRequested == true)
		.. " userHasFinalResult=" .. tostring(userHasFinalResult == true)
		.. " summaryPlayers=" .. tostring(summary and summary.players or "nil")
		.. " summaryTerminal=" .. tostring(summary and summary.terminal or "nil")
		.. " summaryFinalResults=" .. tostring(summary and summary.finalResults or "nil")
		.. " summaryFinalReady=" .. tostring(summary and summary.finalResultsReady == true)
end

local ValidAutoStyles = {
	single = true,
	versus = true,
	double = true,
}

local EnoughCreditsToContinue = function()
	local credits = 0
	if IsCallable(GetCredits) then
		local ok, creditState = SafeCall("GetCredits", function()
			return GetCredits()
		end)
		credits = FiniteNumberOr(ok and creditState and creditState.Credits or nil, 0)
	end

	local premium = "Off"
	if GAMESTATE and GAMESTATE.GetPremium then
		local ok, value = SafeCall("GAMESTATE.GetPremium", function()
			return GAMESTATE:GetPremium()
		end)
		premium = ok and SafeEnumShort(value, "Off") or "Off"
	end

	local styletype = SafeCurrentStyleType() or "OnePlayerOneSide"

	if premium == "2PlayersFor1Credit" then
		return (credits > 0) -- any value greater than 0 is good enough

	elseif premium == "DoubleFor1Credit" then
		-- versus, routine, couple
		if styletype == "TwoPlayersTwoSides" or styletype == "TwoPlayersSharedSides" then
			return (credits > 1)

		-- single, double, solo
		else
			return (credits > 0)
		end

	elseif premium == "Off" then
		-- single, solo
		if styletype == "OnePlayerOneSide" then
			return (credits > 0)

		-- versus, double, routine, couple
		else
			return (credits > 1)
		end
	end

	return false
end

------------------------------------------------------------

if not Branch then Branch = {} end

Branch.AfterScreenRankingDouble = function()
	return SafePreference("MemoryCards", false) and "ScreenMemoryCard" or "ScreenRainbow"
end

local SelectMusicOrCourse = function()
	if SafeCourseMode() then
		return "ScreenSelectCourse"
	else
		if SafeGameMode() == "Casual" then
			return "ScreenSelectMusicCasual"
		end

		return "ScreenSelectMusic"
	end
end
Branch.SelectMusicOrCourse = SelectMusicOrCourse

Branch.AllowScreenSelectProfile = function()
	if SafeThemePref("AllowScreenSelectProfile", false) then
		return "ScreenSelectProfile"
	else
		return Branch.AfterSelectProfile()
	end
end

Branch.AfterSelectProfile = function()
	-- If we only want to sometimes display QR Login, only do so if at least one
	-- of the chosen profiles doesn't already have an API key saved.
	local allApiKeys = true
	local needsArrowCloudLogin = false

	if not (GAMESTATE and GAMESTATE.GetHumanPlayers and SL) then
		BranchTrace("AfterSelectProfile fallback=select_color reason=missing_runtime")
		return Branch.AllowScreenSelectColor()
	end

	local okPlayers, players = SafeCall("GAMESTATE.GetHumanPlayers", function()
		return GAMESTATE:GetHumanPlayers()
	end)
	if not okPlayers or type(players) ~= "table" then
		BranchTrace("AfterSelectProfile fallback=select_color reason=missing_players")
		return Branch.AllowScreenSelectColor()
	end

	for player in ivalues(players) do
		local pn = SafeEnumShort(player, nil)
		local playerState = pn and SL[pn] or nil
		if not playerState or playerState.ApiKey == nil or playerState.ApiKey == "" then
			allApiKeys = false
		end

		local persistentProfile = false
		if SafeThemePref("EnableArrowCloud", false) == true
			and PROFILEMAN and PROFILEMAN.IsPersistentProfile then
			local okPersistent, result = SafeCall("PROFILEMAN.IsPersistentProfile", function()
				return PROFILEMAN:IsPersistentProfile(player)
			end)
			persistentProfile = okPersistent and result == true
		end

		if persistentProfile then
			if IsCallable(ParseArrowCloudIni) then
				SafeCall("ParseArrowCloudIni", function()
					ParseArrowCloudIni(player)
				end)
			end
			if not playerState or not playerState.ArrowCloudApiKey or playerState.ArrowCloudApiKey == "" then
				needsArrowCloudLogin = true
			end
		end
	end

	local qrLogin = SafeThemePref("QRLogin", "Never")
	if (SL.GrooveStats and SL.GrooveStats.IsConnected and
	    (qrLogin == "Always" or
			 (qrLogin == "Sometimes" and not allApiKeys)))
		or needsArrowCloudLogin then
		return "ScreenGrooveStatsLogin"
	else
		return Branch.AllowScreenSelectColor()
	end
end

Branch.AllowScreenSelectColor = function()
	if SafeThemePref("AllowScreenSelectColor", false) and not SafeThemePref("RainbowMode", false) then
		return "ScreenSelectColor"
	else
		return Branch.AfterScreenSelectColor()
	end
end

Branch.AfterScreenSelectColor = function()
	local preferred_style = tostring(SafeThemePref("AutoStyle", "none") or "none")

	if preferred_style ~= "none"
	-- AutoStyle should not be possible in pay mode
	-- it's too confusing for machine operators, novice players, and developers alike
	and GAMESTATE
	and GAMESTATE.GetCoinMode
	and GAMESTATE.SetCurrentStyle then

		if not ValidAutoStyles[preferred_style] then
			BranchTrace("AutoStyle skipped invalid_style=" .. tostring(preferred_style))
			return "ScreenSelectStyle"
		end

		local okCoin, coinMode = SafeCall("GAMESTATE.GetCoinMode", function()
			return GAMESTATE:GetCoinMode()
		end)
		if not okCoin or coinMode == "CoinMode_Pay" then
			return "ScreenSelectStyle"
		end

		-- If "versus" ensure that both players are actually considered joined.
		if preferred_style == "versus" then
			if GAMESTATE.JoinPlayer then
				SafeCall("GAMESTATE.JoinPlayer P1", function() GAMESTATE:JoinPlayer(PLAYER_1) end)
				SafeCall("GAMESTATE.JoinPlayer P2", function() GAMESTATE:JoinPlayer(PLAYER_2) end)
			end

		-- if AutoStyle was "single" but both players are already joined
		-- (for whatever reason), we're in a bit of a pickle, as there is
		-- no way to read the player's mind and know which side they really
		-- want to play on. Unjoin PLAYER_2 for lack of a better solution.
		elseif preferred_style == "single" and GAMESTATE.GetNumSidesJoined and GAMESTATE.UnjoinPlayer then
			local okSides, sidesJoined = SafeCall("GAMESTATE.GetNumSidesJoined", function()
				return GAMESTATE:GetNumSidesJoined()
			end)
			if okSides and sidesJoined == 2 then
				SafeCall("GAMESTATE.UnjoinPlayer P2", function() GAMESTATE:UnjoinPlayer(PLAYER_2) end)
			end
		end

		local okStyle = SafeCall("GAMESTATE.SetCurrentStyle " .. preferred_style, function()
			GAMESTATE:SetCurrentStyle(preferred_style)
		end)
		if not okStyle then
			BranchTrace("AutoStyle skipped set_failed style=" .. tostring(preferred_style))
			return "ScreenSelectStyle"
		end

		return Branch.AllowScreenSelectPlayMode()
	end

	return "ScreenSelectStyle"
end

Branch.AllowScreenSelectPlayMode = function()
	if SafeThemePref("AllowScreenSelectPlayMode", false) then
		return "ScreenSelectPlayMode"
	else
		return Branch.AllowScreenSelectPlayMode2()
	end
end

Branch.AllowScreenSelectPlayMode2 = function()
	-- now that a GameMode has been selected (or defaulted), set related preferences
	local gameMode = tostring(SafeGameMode() or "")
	if Branch._lastGameModePreferencesApplied ~= gameMode then
		if IsCallable(SetGameModePreferences) then
			SafeCall("SetGameModePreferences", function()
				SetGameModePreferences()
			end)
		end
		-- and reload the theme's Metrics
		if THEME and THEME.ReloadMetrics then
			SafeCall("THEME.ReloadMetrics", function()
				THEME:ReloadMetrics()
			end)
		end
		Branch._lastGameModePreferencesApplied = gameMode
	end

	if gameMode == "ITG" and SafeThemePref("AllowScreenSelectPlayMode2", false) then
		return "ScreenSelectPlayMode2"
	else
		return Branch.AllowScreenSelectOnlineMode()
	end
end

Branch.AllowScreenSelectOnlineMode = function()
	if SafeThemePref("AllowScreenSelectOnlineMode", false) then
		return "ScreenSelectOnlineMode"
	end

	if SL and SL.Global then
		SL.Global.ITGOnline = SL.Global.ITGOnline or {}
		SL.Global.ITGOnline.Enabled = false
	end
	return "ScreenProfileLoad"
end

Branch.AfterSelectOnlineMode = function()
	if SL and SL.Global and SL.Global.ITGOnline and SL.Global.ITGOnline.Enabled then
		return "ScreenITGOnlineLogin"
	end

	return "ScreenProfileLoad"
end

Branch.AfterEvaluationStage = function()
	local active, room, inactiveReason = HasActiveOnlineRoom()
	if active then
		if ITGOnline.onlineEvaluationExitRequested then
			ITGOnline.onlineEvaluationExitRequested = false
			BranchTrace("AfterEvaluationStage room=" .. tostring(ITGOnline.currentRoomId)
				.. " phase=" .. tostring(OnlineRoomPhase(room))
				.. " next=ScreenOnlineLobbies reason=explicit_exit"
				.. OnlineEvaluationBranchState(room))
			return "ScreenOnlineLobbies"
		end
		BranchTrace("AfterEvaluationStage room=" .. tostring(ITGOnline.currentRoomId)
			.. " phase=" .. tostring(OnlineRoomPhase(room))
			.. " next=ScreenEvaluationStage reason=online_exit_not_requested"
			.. OnlineEvaluationBranchState(room))
		return "ScreenEvaluationStage"
	end
	BranchTrace("AfterEvaluationStage inactive reason=" .. tostring(inactiveReason or "nil")
		.. " room=" .. tostring(ITGOnline and ITGOnline.currentRoomId or "nil")
		.. " phase=" .. tostring(OnlineRoomPhase(room))
		.. OnlineEvaluationBranchState(room))

	-- If we're in Casual mode, don't save the profile(s).
	if SafeGameMode() == "Casual" then
		return Branch.AfterProfileSave()
	else
		return "ScreenProfileSave"
	end
end

Branch.AfterSelectPlayMode = function()
	return Branch.SelectMusicOrCourse()
end

local OnlineEvaluationScreen = function()
	return SafeCourseMode() and "ScreenEvaluationNonstop" or "ScreenEvaluationStage"
end

Branch.AfterGameplay = function()
	local active, room, inactiveReason = HasActiveOnlineRoom()
	if ITGOnline and ITGOnline.currentRoomId then
		BranchTrace("AfterGameplay room=" .. tostring(ITGOnline.currentRoomId)
			.. " phase=" .. tostring(OnlineRoomPhase(room))
			.. " active=" .. tostring(active)
			.. " inactiveReason=" .. tostring(inactiveReason or "none"))
	end

	if active then
		local phase = OnlineRoomPhase(room)
		if phase == "results" then
			ITGOnline.onlineEvaluationExitRequested = false
			local nextScreen = OnlineEvaluationScreen()
			BranchTrace("AfterGameplay room=" .. tostring(ITGOnline.currentRoomId)
				.. " phase=" .. tostring(phase)
				.. " next=" .. tostring(nextScreen)
				.. " reason=online_results")
			return nextScreen
		end

		BranchTrace("AfterGameplay room=" .. tostring(ITGOnline.currentRoomId)
			.. " phase=" .. tostring(phase)
			.. " next=" .. tostring(OnlineEvaluationScreen())
			.. " reason=online_fallback_no_gameplay_loop")
		return OnlineEvaluationScreen()
	end

	if THEME and THEME.GetMetric then
		local okMetric, heartEntryEnabled = SafeCall("THEME.GetMetric ScreenHeartEntry.HeartEntryEnabled", function()
			return THEME:GetMetric("ScreenHeartEntry", "HeartEntryEnabled")
		end)
		local go_to_heart= false
		if okMetric and heartEntryEnabled and GAMESTATE and GAMESTATE.GetEnabledPlayers and PROFILEMAN and PROFILEMAN.GetProfile then
			local okPlayers, players = SafeCall("GAMESTATE.GetEnabledPlayers", function()
				return GAMESTATE:GetEnabledPlayers()
			end)
			for i, pn in ipairs(okPlayers and type(players) == "table" and players or {}) do
				local okProfile, profile = SafeCall("PROFILEMAN.GetProfile", function()
					return PROFILEMAN:GetProfile(pn)
				end)
				if okProfile and profile and profile.GetIgnoreStepCountCalories then
					local okIgnore, ignore = SafeCall("Profile.GetIgnoreStepCountCalories", function()
						return profile:GetIgnoreStepCountCalories()
					end)
					if okIgnore and ignore then
						go_to_heart= true
					end
				end
			end

			if go_to_heart then
				return "ScreenHeartEntry"
			end
		end
	end

	return Branch.AfterHeartEntry()
end

Branch.AfterHeartEntry = function()
	local pm = nil
	if GAMESTATE and GAMESTATE.GetPlayMode then
		local ok, playMode = SafeCall("GAMESTATE.GetPlayMode", function()
			return GAMESTATE:GetPlayMode()
		end)
		pm = ok and SafeEnumShort(playMode, nil) or nil
	end
	local nextScreen = "ScreenEvaluationStage"
	if( pm == "Regular" ) then nextScreen = "ScreenEvaluationStage" end
	if( pm == "Nonstop" ) then nextScreen = "ScreenEvaluationNonstop" end

	if pm ~= "Regular" and pm ~= "Nonstop" then
		BranchTrace("AfterHeartEntry fallback=ScreenEvaluationStage playMode=" .. tostring(pm))
	end

	local active, room = HasActiveOnlineRoom()
	if active then
		BranchTrace("AfterHeartEntry room=" .. tostring(ITGOnline.currentRoomId)
			.. " phase=" .. tostring(OnlineRoomPhase(room))
			.. " playMode=" .. tostring(pm)
			.. " next=" .. tostring(nextScreen))
	end
	return nextScreen
end

Branch.AfterSelectMusic = function()
	-- This happens in the "good path" i.e. when proceeding forward in the game
	-- loop vs. reloading the screen programmatically, or ending the session, etc.
	-- Broadcasting song selection (for online lobbies) here makes sense since
	-- this is the point at which the player has actually "selected" a song and
	-- we're proceeding to the next screen which is either Gameplay or PlayerOptions.
	--
	-- NOTE: It is possible for a player to back out of PlayerOptions, but they
	-- would be expected to pick the same song since it's broadcast to the library.
	--
	-- TODO: Consider locking the music wheel in this case.
	local active, room, inactiveReason = HasActiveOnlineRoom({ phase = { "lobby", "lobby_ready", "config" } })
	if active then
		BranchTrace("AfterSelectMusic action=broadcast_song_selected"
			.. " room=" .. tostring(ITGOnline.currentRoomId)
			.. " phase=" .. tostring(OnlineRoomPhase(room)))
		if MESSAGEMAN and MESSAGEMAN.Broadcast then
			SafeCall("MESSAGEMAN.Broadcast SongSelected", function()
				MESSAGEMAN:Broadcast("SongSelected", {
					roomId = ITGOnline.currentRoomId,
					phase = OnlineRoomPhase(room),
				})
			end)
		end
		return "ScreenOnlineLobbies"
	elseif ITGOnline and ITGOnline.currentRoomId then
		BranchTrace("AfterSelectMusic online_skipped reason=" .. tostring(inactiveReason)
			.. " room=" .. tostring(ITGOnline.currentRoomId))
	end

	local goToOptions = false
	if SCREENMAN and SCREENMAN.GetTopScreen then
		local okScreen, topScreen = SafeCall("SCREENMAN.GetTopScreen", function()
			return SCREENMAN:GetTopScreen()
		end)
		if okScreen and topScreen and topScreen.GetGoToOptions then
			local okOptions, result = SafeCall("Screen.GetGoToOptions", function()
				return topScreen:GetGoToOptions()
			end)
			goToOptions = okOptions and result == true
		end
	end

	if goToOptions then
		return "ScreenPlayerOptions"
	else
		-- routine mode specifically uses ScreenGameplayShared
		local style = SafeCurrentStyleName()
		if style == "routine" then
			return "ScreenGameplayShared"
		end

		-- while everything else (single, versus, double, etc.) uses ScreenGameplay
		return "ScreenGameplay"
	end
end

Branch.SSMCancel = function()

	if HasActiveOnlineRoom() then
		return "ScreenOnlineLobbies"
	end

	local stageIndex = 0
	if GAMESTATE and GAMESTATE.GetCurrentStageIndex then
		local ok, result = SafeCall("GAMESTATE.GetCurrentStageIndex", function()
			return GAMESTATE:GetCurrentStageIndex()
		end)
		stageIndex = ok and FiniteNumberOr(result, 0) or 0
	end

	if stageIndex > 0 then
		return Branch.AllowScreenEvalSummary()
	end

	return IsCallable(Branch.TitleMenu) and Branch.TitleMenu() or "ScreenTitleMenu"
end

Branch.AllowScreenNameEntry = function()

	-- If we're in Casual mode, don't allow NameEntry, and don't
	-- bother saving the profile(s). Skip directly to GameOver.
	if SafeGameMode() == "Casual" then
		return Branch.AfterProfileSaveSummary()

	elseif SafeThemePref("AllowScreenNameEntry", false) then
		return "ScreenNameEntryTraditional"

	else
		return "ScreenProfileSaveSummary"
	end
end

Branch.AllowScreenEvalSummary = function()
	if SafeThemePref("AllowScreenEvalSummary", false) then
		return "ScreenEvaluationSummary"
	else
		return Branch.AllowScreenNameEntry()
	end
end

local SongCost = function(song, durationOverride)
	if not song then return nil end

	local isMarathon = false
	local isLong = false
	if song.IsMarathon then
		local ok, result = SafeCall("Song.IsMarathon", function()
			return song:IsMarathon()
		end)
		isMarathon = ok and result == true
	end
	if song.IsLong then
		local ok, result = SafeCall("Song.IsLong", function()
			return song:IsLong()
		end)
		isLong = ok and result == true
	end

	if durationOverride ~= nil then
		local duration = FiniteNumberOr(durationOverride, nil)
		local longCutoff = FiniteNumberOr(SafePreference("LongVerSongSeconds", nil), nil)
		local marathonCutoff = FiniteNumberOr(SafePreference("MarathonVerSongSeconds", nil), nil)
		if duration and marathonCutoff and marathonCutoff > 0 and duration / marathonCutoff > 1 then
			isMarathon = true
			isLong = true
		elseif duration and longCutoff and longCutoff > 0 and duration / longCutoff > 1 then
			isMarathon = false
			isLong = true
		else
			isMarathon = false
			isLong = false
		end
	end

	return (isMarathon and 3) or (isLong and 2) or 1
end

local CurrentSong = function()
	if not (GAMESTATE and GAMESTATE.GetCurrentSong) then return nil end
	local ok, song = SafeCall("GAMESTATE.GetCurrentSong", function()
		return GAMESTATE:GetCurrentSong()
	end)
	return ok and song or nil
end

local CurrentStageStatsAllFailed = function()
	if not (STATSMAN and STATSMAN.GetCurStageStats) then return false end
	local okStats, stats = SafeCall("STATSMAN.GetCurStageStats", function()
		return STATSMAN:GetCurStageStats()
	end)
	if not (okStats and stats and stats.AllFailed) then return false end
	local okFailed, failed = SafeCall("StageStats.AllFailed", function()
		return stats:AllFailed()
	end)
	return okFailed and failed == true
end

local HumanPlayers = function()
	if not (GAMESTATE and GAMESTATE.GetHumanPlayers) then return {} end
	local ok, players = SafeCall("GAMESTATE.GetHumanPlayers", function()
		return GAMESTATE:GetHumanPlayers()
	end)
	return ok and type(players) == "table" and players or {}
end

local MasterStagesLeft = function()
	if not (GAMESTATE and GAMESTATE.GetMasterPlayerNumber and GAMESTATE.GetNumStagesLeft) then return nil end
	local okMaster, master = SafeCall("GAMESTATE.GetMasterPlayerNumber", function()
		return GAMESTATE:GetMasterPlayerNumber()
	end)
	if not okMaster then return nil end
	local okStages, stages = SafeCall("GAMESTATE.GetNumStagesLeft", function()
		return GAMESTATE:GetNumStagesLeft(master)
	end)
	return okStages and FiniteNumberOr(stages, nil) or nil
end

local AddStagesBackToPlayers = function(stagesToAddBack)
	if not (GAMESTATE and GAMESTATE.AddStageToPlayer) then return end
	stagesToAddBack = math.floor(ClampNumber(stagesToAddBack, 0, MAX_STAGE_ADD_BACK))
	if stagesToAddBack <= 0 then return end

	for pn in ivalues(HumanPlayers()) do
		for i=1, stagesToAddBack do
			SafeCall("GAMESTATE.AddStageToPlayer", function()
				GAMESTATE:AddStageToPlayer(pn)
			end)
		end
	end
end

Branch.AfterProfileSave = function()
	local active, room = HasActiveOnlineRoom()
	if active then
		BranchTrace("AfterProfileSave room=" .. tostring(ITGOnline.currentRoomId)
			.. " phase=" .. tostring(OnlineRoomPhase(room))
			.. " next=ScreenOnlineLobbies")
		return "ScreenOnlineLobbies"
	end

	if SafePreference("EventMode", false) then
		return Branch.SelectMusicOrCourse()

	elseif SafeCourseMode() then
		return Branch.AllowScreenNameEntry()

	else

		-- deduct the number of stages that stock StepMania says the song is
		local song = CurrentSong()
		if not song then
			BranchTrace("AfterProfileSave fallback=eval_summary reason=no_current_song")
			return Branch.AllowScreenEvalSummary()
		end

		if not SL then
			BranchTrace("AfterProfileSave fallback=eval_summary reason=missing_sl_global")
			return Branch.AllowScreenEvalSummary()
		end

		SL.Global = SL.Global or {}
		SL.Global.Stages = SL.Global.Stages or {}
		SL.Global.ActiveModifiers = SL.Global.ActiveModifiers or {}
		SL.Global.Stages.Remaining = FiniteNumberOr(SL.Global.Stages.Remaining, 0)

		local SMSongCost = SongCost(song) or 1
		SL.Global.Stages.Remaining = SL.Global.Stages.Remaining - SMSongCost

		-- check if stages should be "added back" to SL.Global.Stages.Remaining because of an active rate mod
		local musicRate = FiniteNumberOr(SL.Global.ActiveModifiers.MusicRate, 1)
		if musicRate > 0 and musicRate ~= 1 then
			local duration = nil
			if song.GetLastSecond then
				local okDuration, result = SafeCall("Song.GetLastSecond", function()
					return song:GetLastSecond()
				end)
				duration = okDuration and FiniteNumberOr(result, nil) or nil
			end

			local ActualSongCost = SongCost(song, duration and (duration / musicRate) or nil) or SMSongCost
			local StagesToAddBack = ClampNumber(SMSongCost - ActualSongCost, 0, MAX_STAGE_ADD_BACK)

			if StagesToAddBack > 0 then
				SL.Global.Stages.Remaining = SL.Global.Stages.Remaining + StagesToAddBack
			end
		elseif musicRate <= 0 then
			BranchTrace("AfterProfileSave ignored invalid_music_rate=" .. tostring(SL.Global.ActiveModifiers.MusicRate))
		end

		-- Now, check if StepMania and SL disagree on the stage count. If necessary, add stages back.
		-- This might be necessary because:
		-- a) a Lua chart reloaded ScreenGameplay, or
		-- b) everyone failed, and StepmMania zeroed out the stage numbers
		local engineStagesLeft = MasterStagesLeft()
		if engineStagesLeft and engineStagesLeft < SL.Global.Stages.Remaining then
			local StagesToAddBack = math.floor(ClampNumber(SL.Global.Stages.Remaining - engineStagesLeft, 0, MAX_STAGE_ADD_BACK))
			AddStagesBackToPlayers(StagesToAddBack)
		end

		-- now, check if this set is over.
		local setOver
		-- This is only true if the set would have been over naturally,
		setOver = (SL.Global.Stages.Remaining <= 0)
		-- OR if we allow players to fail a set early and the players actually failed.
		if SafeThemePref("AllowFailingOutOfSet", false) == true then
			setOver = setOver or CurrentStageStatsAllFailed()
		end
		-- this style is more verbose but avoids obnoxious if statements

		if setOver then
			-- continues are only allowed in Pay mode
			if SafePreference("CoinMode", nil) == "CoinMode_Pay" then
				local continuesRemaining = FiniteNumberOr(SL.Global.ContinuesRemaining, 0)
				if continuesRemaining > 0 and EnoughCreditsToContinue() then
					return "ScreenPlayAgain"
				end
			end

			return Branch.AllowScreenEvalSummary()
		else
			return Branch.SelectMusicOrCourse()
		end
	end

	-- just in case?
	return Branch.SelectMusicOrCourse()
end

Branch.AfterProfileSaveSummary = function()
	if SafeThemePref("AllowScreenGameOver", false) then
		return "ScreenGameOver"
	else
		return IsCallable(Branch.AfterInit) and Branch.AfterInit() or "ScreenTitleMenu"
	end
end
