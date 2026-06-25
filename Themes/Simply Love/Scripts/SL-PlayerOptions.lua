-- -----------------------------------------------------------------------
-- Helper Functions for PlayerOptions
-- -----------------------------------------------------------------------

local applyingProfileMods = false

local PlayerOptionsTrace = function(message)
	if type(online_trace) == "function" then
		online_trace("FLOW player_options " .. tostring(message or ""))
	elseif type(Trace) == "function" then
		Trace("SL-PlayerOptions: " .. tostring(message or ""))
	elseif type(Warn) == "function" then
		Warn("SL-PlayerOptions: " .. tostring(message or ""))
	end
end

local SafeCall = function(context, fn)
	if type(fn) ~= "function" then return false, nil end
	local results = { pcall(fn) }
	local ok = table.remove(results, 1)
	if not ok then
		local result = results[1]
		PlayerOptionsTrace("safe_call_failed context=" .. tostring(context or "unknown")
			.. " error=" .. tostring(result))
		return false, nil
	end
	return true, unpack(results)
end

local SafeMethod = function(context, object, method)
	if not (object and type(object[method]) == "function") then return nil end
	local ok, result = SafeCall(context, function()
		return object[method](object)
	end)
	return ok and result or nil
end

local SafeBroadcast = function(message, params)
	if applyingProfileMods and tostring(message or "") == "RefreshActorProxy" then
		return false
	end
	if not (MESSAGEMAN and MESSAGEMAN.Broadcast) then return false end
	return SafeCall("MESSAGEMAN.Broadcast " .. tostring(message), function()
		MESSAGEMAN:Broadcast(message, params)
	end)
end

local SafeThemePref = function(name, fallback)
	if not (ThemePrefs and type(ThemePrefs.Get) == "function") then return fallback end
	local ok, value = SafeCall("ThemePrefs.Get " .. tostring(name), function()
		return ThemePrefs.Get(name)
	end)
	if not ok or value == nil then return fallback end
	return value
end

local SafeEnumShort = function(value, fallback)
	if type(ToEnumShortString) ~= "function" or value == nil then return fallback end
	local ok, result = SafeCall("ToEnumShortString", function()
		return ToEnumShortString(value)
	end)
	return ok and result or fallback
end

local PlayerKey = function(player)
	return SafeEnumShort(player, nil)
end

local PlayerMods = function(player)
	local pn = PlayerKey(player)
	local sl_pn = pn and SL and SL[pn] or nil
	if not sl_pn then
		PlayerOptionsTrace("missing_player_state player=" .. tostring(pn or player))
		return nil, nil
	end
	sl_pn.ActiveModifiers = sl_pn.ActiveModifiers or {}
	return sl_pn.ActiveModifiers, sl_pn
end

local IsFiniteNumber = function(value)
	value = tonumber(value)
	return value ~= nil and value == value and value ~= math.huge and value ~= -math.huge
end

local NumberOr = function(value, fallback)
	value = tonumber(value)
	if IsFiniteNumber(value) then return value end
	return fallback
end

local Clamp = function(value, minimum, maximum)
	value = NumberOr(value, minimum)
	if value < minimum then return minimum end
	if value > maximum then return maximum end
	return value
end

local FindSelectedIndex = function(list, limit)
	for i=1, math.min(#(list or {}), tonumber(limit) or #(list or {})) do
		if list[i] then return i end
	end
	return nil
end

local SafeTopScreenName = function()
	if not (SCREENMAN and SCREENMAN.GetTopScreen) then return nil end
	local ok, screen = SafeCall("SCREENMAN.GetTopScreen", function()
		return SCREENMAN:GetTopScreen()
	end)
	if not (ok and screen and screen.GetName) then return nil end
	local okName, name = SafeCall("Screen.GetName", function()
		return screen:GetName()
	end)
	return okName and tostring(name or "") or nil
end

local HumanPlayers = function()
	if GAMESTATE and GAMESTATE.GetHumanPlayers then
		local ok, players = SafeCall("GAMESTATE.GetHumanPlayers", function()
			return GAMESTATE:GetHumanPlayers()
		end)
		if ok and type(players) == "table" and #players > 0 then return players end
	end
	return {}
end

local NormalizeRoomPhase = function(phase)
	if ITGOnline and type(ITGOnline.NormalizeRoomPhase) == "function" then
		local ok, normalized = SafeCall("ITGOnline.NormalizeRoomPhase", function()
			return ITGOnline:NormalizeRoomPhase(phase)
		end)
		if ok and normalized then return tostring(normalized) end
	end
	return tostring(phase or ""):lower()
end

local RoomId = function(room)
	if type(room) ~= "table" then return "" end
	return tostring(room.id or room.room_id or room.roomId or "")
end

local CurrentUserId = function()
	return tostring(ITGOnline and ITGOnline.user and ITGOnline.user.id or "")
end

local UserIsRoomMember = function(room, userId)
	if type(room) ~= "table" then return false end
	userId = tostring(userId or "")
	if userId == "" then return false end
	for member in ivalues(type(room.members) == "table" and room.members or {}) do
		local memberTable = type(member) == "table" and member or {}
		local user = type(memberTable.user) == "table" and memberTable.user or nil
		local memberId = tostring(memberTable.user_id or memberTable.userId or memberTable.playerId or memberTable.id or "")
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
	if expectedRoomId == "" or RoomId(room) ~= expectedRoomId then
		return false, room, "room_id_mismatch"
	end
	local userId = CurrentUserId()
	if options.requireUser ~= false and userId == "" then
		return false, room, "missing_user"
	end
	if options.requireMember ~= false and not UserIsRoomMember(room, userId) then
		return false, room, "user_not_in_room"
	end
	if options.phase then
		local currentPhase = NormalizeRoomPhase(room.phase)
		local phases = type(options.phase) == "table" and options.phase or { options.phase }
		local okPhase = false
		for phase in ivalues(phases) do
			if currentPhase == tostring(phase) then
				okPhase = true
				break
			end
		end
		if not okPhase then return false, room, "phase_mismatch" end
	end
	return true, room, nil
end

local CurrentGameMode = function()
	return SL and SL.Global and SL.Global.GameMode or "ITG"
end

local IsTournamentMode = function()
	return SafeThemePref("EnableTournamentMode", false) == true
end

local TournamentScoringSystem = function()
	local scoring = tostring(SafeThemePref("ScoringSystem", "ITG") or "ITG")
	return scoring == "EX" and "EX" or "ITG"
end

local GetModsAndPlayerOptions = function(player)
	local mods = PlayerMods(player)
	if not mods then return nil, nil end
	-- This can get called already when loading ScreenTitleMenu if all screens
	-- before and including ScreenSelectPlayMode are disabled. Top screen will
	-- be nil in that case.
	local topscreenname = SafeTopScreenName()
	local modslevel = topscreenname == "ScreenEditOptions" and "ModsLevel_Stage" or "ModsLevel_Preferred"
	if not (GAMESTATE and GAMESTATE.GetPlayerState) then return mods, nil end
	local okState, playerstate = SafeCall("GAMESTATE.GetPlayerState", function()
		return GAMESTATE:GetPlayerState(player)
	end)
	if not (okState and playerstate and playerstate.GetPlayerOptions) then
		PlayerOptionsTrace("missing_player_options player=" .. tostring(PlayerKey(player) or player))
		return mods, nil
	end
	local okOptions, playeroptions = SafeCall("PlayerState.GetPlayerOptions", function()
		return playerstate:GetPlayerOptions(modslevel)
	end)
	if not okOptions then playeroptions = nil end

	return mods, playeroptions
end

-- -----------------------------------------------------------------------
-- For normal gameplay, the engine offers SongUtil.GetPlayableSteps()
-- but there is not currently any analogous helper function for CourseMode.
-- Let's use this for now.

local GetPlayableTrails = function(course)
	if not (course and course.GetAllTrails) then return nil end

	local trails = {}
	local okTrails, allTrails = SafeCall("Course.GetAllTrails", function()
		return course:GetAllTrails()
	end)
	for _,trail in ipairs(okTrails and type(allTrails) == "table" and allTrails or {}) do
		local playable = true
		local entries = SafeMethod("Trail.GetTrailEntries", trail, "GetTrailEntries")
		for _,entry in ipairs(type(entries) == "table" and entries or {}) do
			local song = SafeMethod("TrailEntry.GetSong", entry, "GetSong")
			local steps = SafeMethod("TrailEntry.GetSteps", entry, "GetSteps")
			local stepsType = SafeMethod("Steps.GetStepsType", steps, "GetStepsType")
			local okPlayable, isPlayable = false, false
			if SongUtil and SongUtil.IsStepsTypePlayable and song and stepsType then
				okPlayable, isPlayable = SafeCall("SongUtil.IsStepsTypePlayable", function()
					return SongUtil.IsStepsTypePlayable(song, stepsType)
				end)
			end
			if not (SongUtil and SongUtil.IsStepsTypePlayable and song and stepsType)
				or not (okPlayable and isPlayable) then
				playable = false
				break
			end
		end
		if playable then table.insert(trails, trail) end
	end

	return trails
end

local ApplyScoreMode = function(player, mode)
	local mods, sl_pn = PlayerMods(player)
	if not mods then return {}, {} end
	local is_ex = mode == "ex"
	local is_hardex = mode == "hardex"

	mods.ShowExScore = is_ex
	mods.ShowHardEXScore = is_hardex
	mods.ShowFaPlusWindow = is_ex or is_hardex
	mods.ShowFaPlusPane = is_ex or is_hardex or mods.ShowFaPlusPane == true
	mods.SmallerWhite = is_hardex
	sl_pn.EvalPanePrimary = ((mods.ShowFaPlusWindow or mods.ShowExScore or mods.ShowHardEXScore) and mods.ShowFaPlusPane) and 2 or 1

	return mods, sl_pn
end

local SafeAssetList = function(context, fn, fallback)
	local ok, values = SafeCall(context, fn)
	if not ok or type(values) ~= "table" then return fallback or {} end
	local sanitized = {}
	for value in ivalues(values) do
		if value ~= nil then sanitized[#sanitized+1] = value end
	end
	if #sanitized == 0 and fallback then return fallback end
	return sanitized
end

local SafeStringChoices = function(values, fallback)
	local choices = {}
	for value in ivalues(type(values) == "table" and values or {}) do
		if value ~= nil then choices[#choices+1] = tostring(value) end
	end
	if #choices == 0 and fallback then return fallback end
	return choices
end

local ResolveOptionTable = function(context, source)
	if type(source) == "function" then
		local ok, values = SafeCall(context, source)
		return ok and type(values) == "table" and values or {}
	end
	return type(source) == "table" and source or {}
end

local StripHintsList = function(values, fallback)
	local choices = {}
	for value in ivalues(type(values) == "table" and values or {}) do
		if type(StripSpriteHints) == "function" then
			local ok, stripped = SafeCall("StripSpriteHints", function()
				return StripSpriteHints(value)
			end)
			choices[#choices+1] = tostring(ok and stripped or value)
		else
			choices[#choices+1] = tostring(value)
		end
	end
	if #choices == 0 and fallback then return fallback end
	return choices
end

local SafeThemeString = function(group, key)
	if not (THEME and THEME.GetString) then return tostring(key or "") end
	local ok, value = SafeCall("THEME.GetString " .. tostring(group) .. "." .. tostring(key), function()
		return THEME:GetString(group, key)
	end)
	return ok and tostring(value or key or "") or tostring(key or "")
end

local SafeCourseMode = function()
	if not (GAMESTATE and GAMESTATE.IsCourseMode) then return false end
	local ok, result = SafeCall("GAMESTATE.IsCourseMode", function()
		return GAMESTATE:IsCourseMode()
	end)
	return ok and result == true
end

local CurrentSongOrCourse = function()
	if not GAMESTATE then return nil end
	if SafeCourseMode() then
		if not GAMESTATE.GetCurrentCourse then return nil end
		local ok, course = SafeCall("GAMESTATE.GetCurrentCourse", function()
			return GAMESTATE:GetCurrentCourse()
		end)
		return ok and course or nil
	end
	if not GAMESTATE.GetCurrentSong then return nil end
	local ok, song = SafeCall("GAMESTATE.GetCurrentSong", function()
		return GAMESTATE:GetCurrentSong()
	end)
	return ok and song or nil
end

local PlayableSteps = function(song)
	if not (SongUtil and SongUtil.GetPlayableSteps and song) then return {} end
	local ok, steps = SafeCall("SongUtil.GetPlayableSteps", function()
		return SongUtil.GetPlayableSteps(song)
	end)
	return ok and type(steps) == "table" and steps or {}
end

local StepchartSnapshot = function()
	local values = {}
	local choices = {}
	local songOrCourse = CurrentSongOrCourse()
	if not songOrCourse then return choices, values end

	if SafeCourseMode() then
		values = GetPlayableTrails(songOrCourse) or {}
		for _, trail in ipairs(values) do
			local difficulty = SafeMethod("Trail.GetDifficulty", trail, "GetDifficulty")
			local meter = SafeMethod("Trail.GetMeter", trail, "GetMeter") or 0
			choices[#choices+1] = ("%s %i"):format(
				SafeThemeString("Difficulty", SafeEnumShort(difficulty, "Edit")),
				tonumber(meter) or 0)
		end
	else
		values = PlayableSteps(songOrCourse)
		for steps in ivalues(values) do
			local isEdit = SafeMethod("Steps.IsAnEdit", steps, "IsAnEdit") == true
			if steps and isEdit then
				choices[#choices+1] = ("%s %i"):format(
					tostring(SafeMethod("Steps.GetDescription", steps, "GetDescription") or "Edit"),
					tonumber(SafeMethod("Steps.GetMeter", steps, "GetMeter") or 0) or 0)
			elseif steps then
				local difficulty = SafeMethod("Steps.GetDifficulty", steps, "GetDifficulty")
				choices[#choices+1] = ("%s %i"):format(
					SafeThemeString("Difficulty", SafeEnumShort(difficulty, "Edit")),
					tonumber(SafeMethod("Steps.GetMeter", steps, "GetMeter") or 0) or 0)
			end
		end
	end
	return choices, values
end

local IsGrooveStatsScoreboxAllowed = function()
	if not (SL and SL.GrooveStats and SL.GrooveStats.GetScores and type(IsServiceAllowed) == "function") then
		return false
	end
	local ok, allowed = SafeCall("IsServiceAllowed GrooveStats.GetScores", function()
		return IsServiceAllowed(SL.GrooveStats.GetScores)
	end)
	return ok and allowed == true
end

local SafeIsUsingWideScreen = function()
	if type(IsUsingWideScreen) ~= "function" then return true end
	local ok, result = SafeCall("IsUsingWideScreen", IsUsingWideScreen)
	return ok and result == true
end

local ScreenSelectMusicAvailable = function()
	local global = SL and SL.Global or {}
	local timer = type(global.MenuTimer) == "table" and global.MenuTimer or {}
	return NumberOr(timer.ScreenSelectMusic, 0) > 1 and global.MusicWheelLocked ~= true
end

local EnsureScreenAfter = function()
	SL.Global = SL.Global or {}
	SL.Global.ScreenAfter = SL.Global.ScreenAfter or {}
	return SL.Global.ScreenAfter
end

-- -----------------------------------------------------------------------
-- when to use Choices() vs. Values()
--
-- Each OptionRow needs stringified choices to present to the player.  Sometimes using hardcoded strings
-- is okay. For example, SpeedModType choices (X, C, M) are the same in English as in French.
--
-- Other times, we need to be able to localize the choices presented to the player but also
-- maintain an internal value that code within the theme can rely on regardless of language.
--
-- For each of the subtables in Overrides, you must specify 'Choices' and/or 'Values' depending on your
-- needs. Each can be either a table of strings or a function that returns a table of strings.
-- Using a function can be helpful when the OptionRow needs to present different options depending
-- on certain conditions.
--
-- If you specify only 'Choices', the engine presents the strings exactly as-is and also uses those
-- same strings internally.
--
-- If you specify only 'Values', the engine will use those raw strings internally but localize them
-- using the corresponding display strings in en.ini (or es.ini, fr.ini, etc.) for the user.
--
-- If you specify both, then the strings in 'Choices' are presented as-is,
-- but the strings in 'Values' are what the theme stores into the ActiveModifiers table.

------------------------------------------------------------

-- Define SL's custom OptionRows that appear in ScreenPlayerOptions as subtables within Overrides.
-- As an OptionRow, each subtable is expected to have specific key/value pairs:
--
-- ExportOnChange (boolean)
-- 	false if unspecified; if true, calls SaveSelections() whenever the current choice changes
-- LayoutType (string)
-- 	"ShowAllInRow" if unspecified; you can set it to "ShowOneInRow" if needed
-- OneChoiceForAllPlayers (boolean)
-- 	false if unspecified
-- SelectType (string)
-- 	"SelectOne" if unspecified; you can set it to "SelectMultiple" if needed
-- LoadSelections (function)
-- 	normally (in other themes) called when the PlayerOption screen initializes
-- 	read the notes surrounding ApplyMods() for further discussion of additional work SL does
-- SaveSelections (function)
-- 	this is where you should do whatever work is needed to ensure that the player's choice
-- 	persists beyond the PlayerOptions screen; normally called around the time of ScreenPlayerOption's
-- 	OffCommand; can also be called because ExportOnChange=true


-- It's not necessary to define each possible key for each OptionRow.  Anything you don't specify
-- will use fallback values in OptionRowDefault (defined later, below).

local Overrides = {

	-------------------------------------------------------------------------
	SpeedModType = {
		Values = function()
			-- if ThemePrefs.Get("EnableTournamentMode") and ThemePrefs.Get("EnforceNoCmod") then
			-- 	local song = GAMESTATE:GetCurrentSong()
			-- 	if song then
			-- 		if (song:GetDisplayFullTitle():lower():match("no cmod") or
			-- 			song:GetTranslitFullTitle():lower():match("no cmod")) then
			-- 				-- Put "M" first so that the CMods will automatically change into MMods instead of XMods.
			-- 				-- NOTE(teejusb): This only gets applied if the player goes into the options menu.
			-- 				-- We also enforce this in screen gameplay.
			-- 				return { "M", "X" }
			-- 		end
			-- 	end
			-- end

			-- NOTE(teejusb): We could remove "C" as an option in Tournament mode + Enforce No Cmod (like above),
			-- but consider the following:
			-- 
			-- 1. Player has a CMod set
			-- 2. Player plays a No CMod song where it auto converts to MMod.
			--
			-- It would be nice for the it to automatically go back to CMod if possible.
			-- Removing "C" as an option makes it so the player will need to explicitly set it back if they had
			-- previously entered the options menu.
			--
			-- Keeping the option, while making it the functionality more opaque, I think is better QOL where players
			-- in a tournament can keep everything on CMod and it'll auto-convert to MMod as needed.
			return { "X", "C", "M" }
		end,
		ExportOnChange = true,
		LayoutType = "ShowOneInRow",
		SaveSelections = function(self, list, pn)
			local mods = PlayerMods(pn)
			if not mods then return end
			for i=1,#list do
				if list[i] then
					local value = self.Values[i]
					if value ~= "X" and value ~= "C" and value ~= "M" then value = "X" end
					local previous = mods.SpeedModType or "X"
					mods.SpeedModType = value
					-- Broadcast a message that ./BGAnimations/ScreenPlayerOptions overlay.lua will be listening for
					-- so it can hackishly modify the single BitmapText actor used in the SpeedMod optionrow
					PlayerOptionsTrace("speed_mod_type_selected player=" .. tostring(PlayerKey(pn) or pn)
						.. " previous=" .. tostring(previous)
						.. " selected=" .. tostring(value)
						.. " speed=" .. tostring(mods.SpeedMod))
					SafeBroadcast('SpeedModType'..tostring(PlayerKey(pn) or "")..'Set', {
						SpeedModType=value,
						PreviousSpeedModType=previous,
						Player=pn
					})
				end
			end
		end
	},
	-------------------------------------------------------------------------
	SpeedMod = {
		Choices = { "       " },
		ExportOnChange = true,
		LayoutType = "ShowOneInRow",
		SaveSelections = function(self, list, pn)
			local mods, playeroptions = GetModsAndPlayerOptions(pn)
			if not (mods and playeroptions) then
				PlayerOptionsTrace("speed_mod_export_skipped player=" .. tostring(PlayerKey(pn) or pn)
					.. " has_mods=" .. tostring(mods ~= nil)
					.. " has_playeroptions=" .. tostring(playeroptions ~= nil))
				return
			end
			local speedType  = mods.SpeedModType or "X"
			local speed = NumberOr(mods.SpeedMod, 1.00)

			local appliers = {
				X = playeroptions.XMod,
				C = playeroptions.CMod,
				M = playeroptions.MMod,
			}
			local applier = appliers[speedType] or appliers.X
			if type(applier) == "function" then
				local ok = SafeCall("PlayerOptions." .. tostring(speedType) .. "Mod", function()
					applier(playeroptions, speed)
				end)
				PlayerOptionsTrace("speed_mod_export_applied player=" .. tostring(PlayerKey(pn) or pn)
					.. " type=" .. tostring(speedType)
					.. " speed=" .. tostring(speed)
					.. " ok=" .. tostring(ok))
			else
				PlayerOptionsTrace("speed_mod_export_missing_applier player=" .. tostring(PlayerKey(pn) or pn)
					.. " type=" .. tostring(speedType)
					.. " speed=" .. tostring(speed))
			end
		end
	},
	-------------------------------------------------------------------------
	NoteSkin = {
		ExportOnChange = true,
		LayoutType = "ShowOneInRow",
		Choices = function()

			local all = SafeAssetList("NOTESKIN.GetNoteSkinNames", function()
				return NOTESKIN and NOTESKIN:GetNoteSkinNames(false)
			end, { "default" })

			if SafeThemePref("HideStockNoteSkins", false) then
				local game = "dance"
				if GAMESTATE and GAMESTATE.GetCurrentGame then
					local okGame, currentGame = SafeCall("GAMESTATE.GetCurrentGame", function()
						return GAMESTATE:GetCurrentGame()
					end)
					if okGame and currentGame and currentGame.GetName then
						local okName, name = SafeCall("Game.GetName", function()
							return currentGame:GetName()
						end)
						game = okName and tostring(name or game) or game
					end
				end

				-- Apologies, midiman. :(
				-- Most of these are StepMania 5 stock note skins
				local stock = {
					dance = {
						"default", "delta", "easyv2", "exactv2", "lambda", "midi-note",
						"midi-note-3d", "midi-rainbow", "midi-routine-p1", "midi-routine-p2",
						"midi-solo", "midi-vivid", "midi-vivid-3d", "retro", "retrobar",
						"retrobar-splithand_whiteblue"
					},
					pump = {
						"cmd", "cmd-routine-p1", "cmd-routine-p2", "complex", "default",
						"delta", "delta-note", "delta-routine-p1", "delta-routine-p2",
						"frame5p", "newextra", "pad", "rhythm", "simple"
					},
					kb7 = {
						"default", "orbital", "retrobar", "retrobar-iidx",
						"retrobar-o2jam", "retrobar-razor", "retrobar-razor_o2"
					},
					techno = {
						"default"
					}
				}

				if stock[game] then
					for stock_noteskin in ivalues(stock[game]) do
						for i=1,#all do
							if stock_noteskin == all[i] then
								table.remove(all, i)
								break
							end
						end
					end
				end
			end

			-- It's possible a user might want to hide stock noteskins
			-- but only have stock noteskins.  If so, just return all noteskins.
			if #all == 0 then all = SafeAssetList("NOTESKIN.GetNoteSkinNames fallback", function()
				return NOTESKIN and NOTESKIN:GetNoteSkinNames(false)
			end, { "default" }) end

			return all
		end,
		SaveSelections = function(self, list, pn)
			local mods, playeroptions = GetModsAndPlayerOptions(pn)
			if not mods then return end
			for i, val in ipairs(self.Choices) do
				if list[i] then mods.NoteSkin = val; break end
			end
			-- Broadcast a message that ./Graphics/OptionRow Frame.lua will be listening for so it can change the NoteSkin preview
			SafeBroadcast("RefreshActorProxy", {Player=pn, Name="NoteSkin", Value=mods.NoteSkin})
			if playeroptions and playeroptions.NoteSkin and mods.NoteSkin then
				SafeCall("PlayerOptions.NoteSkin", function()
					playeroptions:NoteSkin(mods.NoteSkin)
				end)
			end
		end
	},
	NoteSkinVariant = {
		ExportOnChange = true,
		HideOnDisable = true,
		LayoutType = "ShowOneInRow",
		Choices = { "       " },
		EnabledForPlayers = function() 
			local players = {}
			for player in ivalues(HumanPlayers()) do
				local mods = PlayerMods(player)
				local variant = mods and mods.NoteSkinVariant or nil
				local noteskin = mods and mods.NoteSkin or nil
				local hasVariants = false
				if noteskin and NOTESKIN and NOTESKIN.HasVariants then
					local ok, result = SafeCall("NOTESKIN.HasVariants", function()
						return NOTESKIN:HasVariants(noteskin)
					end)
					hasVariants = ok and result == true
				end
				if (variant or noteskin) and hasVariants then
					players[#players+1] = player
				end
			end
			return players 
		end,
		ReloadRowMessages = { "RefreshActorProxy" },
		SaveSelections = function(self, list, pn)
			local mods, playeroptions = GetModsAndPlayerOptions(pn)
			if not mods then return end
			local variant = mods.NoteSkinVariant
			if variant then
				-- Broadcast a message that ./Graphics/OptionRow Frame.lua will be listening for so it can change the NoteSkin preview
				SafeBroadcast("RefreshActorProxy", {Player=pn, Name="NoteSkinVariant", Value=mods.NoteSkinVariant})
				if playeroptions and playeroptions.NoteSkin then
					SafeCall("PlayerOptions.NoteSkinVariant", function()
						playeroptions:NoteSkin(mods.NoteSkinVariant)
					end)
				end
			end
		end
	},
	-------------------------------------------------------------------------
	JudgmentGraphic = {
		LayoutType = "ShowOneInRow",
		ExportOnChange = true,
		Choices = function()
			return StripHintsList(SafeAssetList("GetJudgmentGraphics", GetJudgmentGraphics, { "default" }), { "default" })
		end,
		Values = function()
			return SafeAssetList("GetJudgmentGraphics", GetJudgmentGraphics, { "default" })
		end,
		SaveSelections = function(self, list, pn)
			local mods = PlayerMods(pn)
			if not mods then return end
			for i, val in ipairs(self.Values) do
				if list[i] then mods.JudgmentGraphic = val; break end
			end
			-- Broadcast a message that ./Graphics/OptionRow Frame.lua will be listening for so it can change the Judgment preview
			SafeBroadcast("RefreshActorProxy", {
				Player=pn,
				Name="JudgmentGraphic",
				Value=StripHintsList({ mods.JudgmentGraphic }, { mods.JudgmentGraphic or "" })[1]
			})
		end
	},
	-------------------------------------------------------------------------
	HoldJudgment = {
		LayoutType = "ShowOneInRow",
		ExportOnChange = true,
		Choices = function()
			return StripHintsList(SafeAssetList("GetHoldJudgments", GetHoldJudgments, { "default" }), { "default" })
		end,
		Values = function()
			return SafeAssetList("GetHoldJudgments", GetHoldJudgments, { "default" })
		end,
		SaveSelections = function(self, list, pn)
			local mods = PlayerMods(pn)
			if not mods then return end
			for i, val in ipairs(self.Values) do
				if list[i] then mods.HoldJudgment = val; break end
			end
			-- Broadcast a message that ./Graphics/OptionRow Frame.lua will be listening for so it can change the HoldJudgment preview
			SafeBroadcast("RefreshActorProxy", {
				Player=pn,
				Name="HoldJudgment",
				Value=StripHintsList({ mods.HoldJudgment }, { mods.HoldJudgment or "" })[1]
			})
		end
	},
	-------------------------------------------------------------------------
	ComboFont = {
		LayoutType = "ShowOneInRow",
		ExportOnChange = true,
		Choices = function()
			return SafeStringChoices(SafeAssetList("GetComboFonts", GetComboFonts, { "default" }), { "default" })
		end,
		SaveSelections = function(self, list, pn)
			local mods = PlayerMods(pn)
			if not mods then return end
			for i, val in ipairs(self.Choices) do
				if list[i] then mods.ComboFont = val; break end
			end
			-- Broadcast a message that ./Graphics/OptionRow Frame.lua will be listening for so it can change the ComboFont preview
			SafeBroadcast("RefreshActorProxy", {Player=pn, Name="ComboFont", Value=mods.ComboFont})
		end
	},
	-------------------------------------------------------------------------
	BackgroundFilter = {
		Values = { 'Off','Dark','Darker','Darkest' },
	},
	-------------------------------------------------------------------------
	Mini = {
		Choices = function()
			local first	= -100
			local last 	= 150
			local step 	= 1

			return stringify( range(first, last, step), "%g%%")
		end,
		SaveSelections = function(self, list, pn)
			local mods, playeroptions = GetModsAndPlayerOptions(pn)
			if not (mods and playeroptions) then return end

			for i=1,#self.Choices do
				if list[i] then
					mods.Mini = self.Choices[i]
				end
			end

			-- to make the arrows smaller, pass Mini() a value between 0 and 1
			-- (to make the arrows bigger, pass Mini() a value larger than 1)
			local mini = Clamp(tostring(mods.Mini or "0"):gsub("%%",""), -100, 150) / 100
			if playeroptions.Mini then
				SafeCall("PlayerOptions.Mini", function()
					playeroptions:Mini(mini)
				end)
			end
		end
	},
	-------------------------------------------------------------------------
	MusicRate = {
		ApplyOnProfileLoad = false,
		Choices = function()
			local first	= 0.05
			local last 	= 3
			local step 	= 0.01

			return stringify( range(first, last, step), "%g")
		end,
		ExportOnChange = true,
		OneChoiceForAllPlayers = true,
		HideOnDisable = true,
		EnabledForPlayers = function()
			local active, room = HasActiveOnlineRoom({ phase = { "lobby", "lobby_ready", "config" } })
			if active then
				local manager = room.manager or {}
				local managerId = tostring(manager.id or room.manager_id or room.managerId or "")
				local userId = CurrentUserId()
				if managerId ~= "" and userId ~= "" and managerId ~= userId then
					if online_flow_trace then
						online_flow_trace("player_options_music_rate_hidden reason=online_non_manager"
							.. " room=" .. tostring(ITGOnline.currentRoomId or "nil")
							.. " manager=" .. tostring(managerId)
							.. " user=" .. tostring(userId))
					end
					return {}
				end
			end
			local players = HumanPlayers()
			return #players > 0 and players or {PLAYER_1, PLAYER_2}
		end,
		LoadSelections = function(self, list, pn)
			local rate = ("%g"):format(Clamp(SL and SL.Global and SL.Global.ActiveModifiers and SL.Global.ActiveModifiers.MusicRate or 1, 0.05, 3))
			local i = FindInTable(rate, self.Choices) or 1
			list[i] = true
			return list
		end,
		SaveSelections = function(self, list, pn)

			SL.Global = SL.Global or {}
			SL.Global.ActiveModifiers = SL.Global.ActiveModifiers or {}
			local mods = SL.Global.ActiveModifiers

			local selected = FindSelectedIndex(list, #self.Choices)
			if not selected then return end
			for i=1,#self.Choices do
				if list[i] then
					mods.MusicRate = Clamp(self.Choices[i], 0.05, 3)
				end
			end

			local topscreen = SafeTopScreenName()

			-- Use the older GameCommand interface for applying rate mods in Edit Mode;
			-- it seems to be the only way (probably due to how broken Edit Mode is, in general).
			-- As an unintentional side-effect of setting musicrate mods this way, they STAY set
			-- (between songs, between screens, etc.) until you manually change them.  This is (probably)
			-- not the desired behavior in EditMode, so when users change between different songs in EditMode,
			-- always reset the musicrate mod.  See: ./BGAnimations/ScreenEditMeny underlay.lua
			if GAMESTATE then
				if topscreen == "ScreenEditOptions" and GAMESTATE.ApplyGameCommand then
					SafeCall("GAMESTATE.ApplyGameCommand music rate", function()
						GAMESTATE:ApplyGameCommand("mod," .. mods.MusicRate .."xmusic")
					end)
				elseif GAMESTATE.GetSongOptionsObject then
					local okOptions, songOptions = SafeCall("GAMESTATE.GetSongOptionsObject", function()
						return GAMESTATE:GetSongOptionsObject("ModsLevel_Preferred")
					end)
					if okOptions and songOptions and songOptions.MusicRate then
						SafeCall("SongOptions.MusicRate", function()
							songOptions:MusicRate(mods.MusicRate)
						end)
					end
				end
			end

			SafeBroadcast("MusicRateChanged")
			-- Broadcast a message that ./Graphics/OptionRow Frame.lua will be listening for so it can update ActorProxies
			-- in the MusicRate OptionRow for split BPMs if needed
			SafeBroadcast("RefreshActorProxy", {Player=pn, Name="MusicRate", Value=""})
		end
	},
	-------------------------------------------------------------------------
	Stepchart = {
		ApplyOnProfileLoad = false,
		ExportOnChange = true,
		Snapshot = function()
			return StepchartSnapshot()
		end,
		Choices = function()
			local choices = StepchartSnapshot()
			return choices
		end,
		Values = function()
			local _, values = StepchartSnapshot()
			return values
		end,
		LoadSelections = function(self, list, pn)
			local StepsOrTrail = nil
			if GAMESTATE then
				if SafeCourseMode() and GAMESTATE.GetCurrentTrail then
					local ok, trail = SafeCall("GAMESTATE.GetCurrentTrail", function()
						return GAMESTATE:GetCurrentTrail(pn)
					end)
					StepsOrTrail = ok and trail or nil
				elseif GAMESTATE.GetCurrentSteps then
					local ok, steps = SafeCall("GAMESTATE.GetCurrentSteps", function()
						return GAMESTATE:GetCurrentSteps(pn)
					end)
					StepsOrTrail = ok and steps or nil
				end
			end
			local i = FindInTable(StepsOrTrail, self.Values) or 1
			if self.Values[i] then list[i] = true end
			return list
		end,
		SaveSelections = function(self, list, pn)
			for i,v in ipairs(self.Values) do
				if list[i] then
					-- GAMESTATE keeps track of what the "preferred difficulty" is and this is used by
					-- the engine's SelectMusic class.  SL is using the engine's SelectMusic for now.
					-- Set the PreferredDifficulty now so that the player's newly chosen difficulty
					-- doesn't reset when they return to SelectMusic/SelectCourse.
					if not (GAMESTATE and v and v.GetDifficulty) then return end
					SafeCall("GAMESTATE.SetPreferredDifficulty", function()
						GAMESTATE:SetPreferredDifficulty(pn, v:GetDifficulty())
					end)

					if SafeCourseMode() then
						if GAMESTATE.SetCurrentTrail then
							SafeCall("GAMESTATE.SetCurrentTrail", function()
								GAMESTATE:SetCurrentTrail(pn, v)
							end)
						end
						SafeBroadcast("CurrentTrail"..tostring(PlayerKey(pn) or "").."Changed")
					else
						if GAMESTATE.SetCurrentSteps then
							SafeCall("GAMESTATE.SetCurrentSteps", function()
								GAMESTATE:SetCurrentSteps(pn, v)
							end)
						end
						SafeBroadcast("CurrentSteps"..tostring(PlayerKey(pn) or "").."Changed")
					end
					break
				end
			end
		end
	},
	FaPlus = {
		SelectType = "SelectMultiple",
		Values = function()
			-- 1. Still allow the player to toggle the FA+ window during gameplay in Tournament Mode since
			--    some might find it distracting. We should still display it in step stats if it's enabled
			--    though.
			-- 2. EX score/ITG score is forced in Tournament Mode so remove the option.
			-- 3. FA Plus Pane should always be shown in Tournament Mode to prevent issues with
			--    potentially crucial information.
			if IsTournamentMode() then
				return { "ShowFaPlusWindow" }
			end

			return { "ShowFaPlusWindow", "ShowFaPlusPane", "SmallerWhite" }
		end,
		LoadSelections = function(self, list, pn)
			local mods = PlayerMods(pn)
			if not mods then return list end
			if IsTournamentMode() then
				list[1] = mods.ShowFaPlusWindow or false
				return list
			end

			list[1] = mods.ShowFaPlusWindow or false
			list[2] = mods.ShowFaPlusPane and true
			list[3] = mods.SmallerWhite or false
			return list
		end,
		SaveSelections = function(self, list, pn)
			local mods, sl_pn = PlayerMods(pn)
			if not mods then return end

			if IsTournamentMode() then
				mods.ShowFaPlusWindow = list[1]
				mods.ShowExScore = TournamentScoringSystem() == "EX"
				mods.ShowHardEXScore = false
				mods.ShowFaPlusPane = true
				mods.SmallerWhite = false
				-- Default to FA+ pane in Tournament Mode
				sl_pn.EvalPanePrimary = 2
				PlayerOptionsTrace(("FA_PLUS_OPTIONS: pn=%s tournament=1 window=%s ex=%s hardex=%s pane=%s smaller_white=%s eval_pane=%s"):format(
					tostring(PlayerKey(pn) or pn),
					tostring(mods.ShowFaPlusWindow),
					tostring(mods.ShowExScore),
					tostring(mods.ShowHardEXScore),
					tostring(mods.ShowFaPlusPane),
					tostring(mods.SmallerWhite),
					tostring(sl_pn.EvalPanePrimary)
				))
				return
			end

			mods.ShowFaPlusWindow = list[1]
			mods.ShowFaPlusPane = list[2]
			mods.SmallerWhite = list[3] == true
			-- Default to FA+ pane if either options are active.
			sl_pn.EvalPanePrimary = ((mods.ShowFaPlusWindow or mods.ShowExScore or mods.ShowHardEXScore) and mods.ShowFaPlusPane) and 2 or 1
			PlayerOptionsTrace(("FA_PLUS_OPTIONS: pn=%s window=%s ex=%s hardex=%s pane=%s smaller_white=%s eval_pane=%s"):format(
				tostring(PlayerKey(pn) or pn),
				tostring(mods.ShowFaPlusWindow),
				tostring(mods.ShowExScore),
				tostring(mods.ShowHardEXScore),
				tostring(mods.ShowFaPlusPane),
				tostring(mods.SmallerWhite),
				tostring(sl_pn.EvalPanePrimary)
			))
		end
	},
	ExScoreMode = {
		SelectType = "SelectOne",
		Values = function()
			if IsTournamentMode() then
				return { TournamentScoringSystem() == "EX" and "ScoreModeEX" or "ScoreModeITG" }
			end
			return { "ScoreModeITG", "ScoreModeEX", "ScoreModeHardEX" }
		end,
		LoadSelections = function(self, list, pn)
			local mods = PlayerMods(pn)
			if not mods then return list end
			if IsTournamentMode() then
				list[1] = true
				return list
			end
			if mods.ShowHardEXScore then
				list[3] = true
			elseif mods.ShowExScore then
				list[2] = true
			else
				list[1] = true
			end
			return list
		end,
		SaveSelections = function(self, list, pn)
			local mode = "itg"
			if IsTournamentMode() then
				mode = TournamentScoringSystem() == "EX" and "ex" or "itg"
			elseif list[3] then
				mode = "hardex"
			elseif list[2] then
				mode = "ex"
			end
			local mods, sl_pn = ApplyScoreMode(pn, mode)
			if not mods.ShowFaPlusWindow then return end
			PlayerOptionsTrace(("FA_PLUS_SCORE_MODE: pn=%s mode=%s window=%s ex=%s hardex=%s pane=%s smaller_white=%s eval_pane=%s"):format(
				tostring(PlayerKey(pn) or pn),
				mode,
				tostring(mods.ShowFaPlusWindow),
				tostring(mods.ShowExScore),
				tostring(mods.ShowHardEXScore),
				tostring(mods.ShowFaPlusPane),
				tostring(mods.SmallerWhite),
				tostring(sl_pn.EvalPanePrimary)
			))
		end
	},
	ShowAllScoreModes = {
		SelectType = "SelectOne",
		Values = { "No", "Yes" },
		LoadSelections = function(self, list, pn)
			local mods = PlayerMods(pn)
			if not mods then return list end
			list[mods.ShowAllScoreModes and 2 or 1] = true
			return list
		end,
		SaveSelections = function(self, list, pn)
			local mods = PlayerMods(pn)
			if mods then mods.ShowAllScoreModes = list[2] == true end
		end
	},
	MatchFantasticColor = {
		SelectType = "SelectOne",
		Values = { "No", "Yes" },
		LoadSelections = function(self, list, pn)
			local mods = PlayerMods(pn)
			if not mods then return list end
			list[mods.MatchFantasticColor and 2 or 1] = true
			return list
		end,
		SaveSelections = function(self, list, pn)
			local mods = PlayerMods(pn)
			if mods then mods.MatchFantasticColor = list[2] == true end
		end
	},
	-------------------------------------------------------------------------
	Hide = {
		SelectType = "SelectMultiple",
		Values = { "Targets", "SongBG", "Combo", "Lifebar", "Score", "Danger", "ComboExplosions" },
		LoadSelections = function(self, list, pn)
			local mods = PlayerMods(pn)
			if not mods then return list end
			list[1] = mods.HideTargets or false
			list[2] = mods.HideSongBG  or false
			list[3] = mods.HideCombo   or false
			list[4] = mods.HideLifebar or false
			list[5] = mods.HideScore   or false
			list[6] = mods.HideDanger  or false
			list[7] = mods.HideComboExplosions or false
			return list
		end,
		SaveSelections = function(self, list, pn)
			local mods, playeroptions = GetModsAndPlayerOptions(pn)
			if not mods then return end
			mods.HideTargets = list[1]
			mods.HideSongBG  = list[2]
			mods.HideCombo   = list[3]
			mods.HideLifebar = list[4]
			mods.HideScore   = list[5]
			mods.HideDanger  = list[6]
			mods.HideComboExplosions = list[7]

			if playeroptions and playeroptions.Dark then
				SafeCall("PlayerOptions.Dark", function()
					playeroptions:Dark(mods.HideTargets and 1 or 0)
				end)
			end
			if playeroptions and playeroptions.Cover then
				SafeCall("PlayerOptions.Cover", function()
					playeroptions:Cover(mods.HideSongBG and 1 or 0)
				end)
			end
		end,
	},
	-------------------------------------------------------------------------
	DataVisualizations = {
		Values = function()
			local choices = { "None", "Target Score Graph", "Step Statistics" }

			-- None and Target Score Graph should always be available to players
			-- but Step Statistics needs a lot of space and isn't always possible
			-- remove it as an available option if we aren't in single or if the current
			-- notefield width already uses more than half the screen width
			local styleName = ""
			if GAMESTATE and GAMESTATE.GetCurrentStyle then
				local okStyle, style = SafeCall("GAMESTATE.GetCurrentStyle", function()
					return GAMESTATE:GetCurrentStyle()
				end)
				if okStyle and style and style.GetName then
					local okName, name = SafeCall("Style.GetName", function()
						return style:GetName()
					end)
					styleName = okName and tostring(name or "") or ""
				end
			end
			local wide = SafeIsUsingWideScreen()
			local aspect = 16/9
			if type(GetScreenAspectRatio) == "function" then
				local okAspect, ratio = SafeCall("GetScreenAspectRatio", GetScreenAspectRatio)
				aspect = okAspect and NumberOr(ratio, aspect) or aspect
			end
			local IsUltraWide = aspect > 21/9
			local mpn = nil
			if GAMESTATE and GAMESTATE.GetMasterPlayerNumber then
				local okMpn, master = SafeCall("GAMESTATE.GetMasterPlayerNumber", function()
					return GAMESTATE:GetMasterPlayerNumber()
				end)
				mpn = okMpn and master or nil
			end
			local centered4x3 = false
			if mpn and type(GetNotefieldX) == "function" and _screen and _screen.cx then
				local okX, notefieldX = SafeCall("GetNotefieldX", function()
					return GetNotefieldX(mpn)
				end)
				centered4x3 = okX and notefieldX == _screen.cx and not wide
			end

			-- Not in 4:3 versus mode
			if (not wide and styleName == "versus")
			-- if the notefield is centered with 4:3 aspect ratio
			or centered4x3
			-- Tournament Mode always enforces whether to display/hide step stats so remove that as an option.
			or IsTournamentMode()
			then
				table.remove(choices, 3)
			end

			return choices
		end,
	},
	-------------------------------------------------------------------------
	TargetScore = {
		Values = function()
			local t = {}
			-- "GradeTier16" to "GradeTier01"
			for i=16,1,-1 do
				table.insert(t, ("GradeTier%02d"):format(i))
			end
			table.insert(t, "Machine best")
			table.insert(t, "Personal best")
			table.insert(t, "Ghost Data")
			return t
		end,
		LoadSelections = function(self, list, pn)
			local mods = PlayerMods(pn)
			if not mods then return list end
			local i = Clamp(mods.TargetScore, 1, #(self.Values or {}))
			list[i] = true
			return list
		end,
		SaveSelections = function(self, list, pn)
			local mods = PlayerMods(pn)
			if not mods then return end
			for i,v in ipairs(self.Values) do
				if list[i] then mods.TargetScore = i; break end
			end
		end
	},
	-------------------------------------------------------------------------
	ActionOnMissedTarget = {
		Values = { "Nothing", "Fail", "Restart" },
	},
	-------------------------------------------------------------------------
	GameplayExtras = {
		SelectType = "SelectMultiple",
		Values = function()
			-- GameplayExtras will be presented as a single OptionRow when WideScreen
			local vals = { "ColumnFlashOnMiss", "SubtractiveScoring", "Pacemaker", "NPSGraphAtTop" }

			-- if not WideScreen (traditional DDR cabinets running at 640x480)
			-- remove the last two choices to be appended an additional OptionRow (GameplayExtrasB below).
			if not SafeIsUsingWideScreen() then
				table.remove(vals, 4)
			end
			return vals
		end,
	},
	GameplayExtrasB = {
		SelectType = "SelectMultiple",
		Values = function()
			local vals = {}
			if SafeIsUsingWideScreen() then
				vals = { "JudgmentTilt", "ColumnCues", "LifeMeterSwoosh", "ShowNativeLifeMeter" }
				if IsGrooveStatsScoreboxAllowed() then
					vals[#vals+1] = "DisplayScorebox"
				end
			else
				-- Add in the two removed options if not in WideScreen.
				vals = { "NPSGraphAtTop", "JudgmentTilt", "ColumnCues", "LifeMeterSwoosh", "ShowNativeLifeMeter" }
			end
			return vals
		end
	},
	GameplayExtrasC = {
		SelectType = "SelectMultiple",
		Values = function()
			local vals = {}
			if not SafeIsUsingWideScreen() and IsGrooveStatsScoreboxAllowed() then
				vals = { "DisplayScorebox" }
			end
			return vals
		end
	},
	TiltMultiplier = {
		Choices = function()
			local first	= 1
			local last 	= 3
			local step 	= 0.5

			return stringify(range(first, last, step), "%g")
		end,
		LoadSelections = function(self, list, pn)
			local mods = PlayerMods(pn)
			if not mods then return list end
			local tiltMultiplier = ("%g"):format(Clamp(mods.TiltMultiplier, 1, 3))
			local i = FindInTable(tiltMultiplier, self.Choices) or 1
			list[i] = true
			return list
		end,
		SaveSelections = function(self, list, pn)
			local mods = PlayerMods(pn)
			if not mods then return end

			for i=1,#self.Choices do
				if list[i] then
					mods.TiltMultiplier = Clamp(self.Choices[i], 1, 3)
				end
			end
		end
	},
	-------------------------------------------------------------------------
	ErrorBar = {
		Values = { "None", "Colorful", "Monochrome", "Text" },
	},
	-------------------------------------------------------------------------
	ErrorBarTrim = {
		Values = { "Off", "Great", "Excellent" },
		Choices = function()
			local tns = "TapNoteScore"
			local t = {SafeThemeString("SLPlayerOptions","Off"), SafeThemeString(tns,"W3"), SafeThemeString(tns,"W2")}
			return t
		end,
	},
	-------------------------------------------------------------------------
	ErrorBarOptions = {
		SelectType = "SelectMultiple",
		Values = { "ErrorBarUp", "ErrorBarMultiTick" },
	},
	-------------------------------------------------------------------------
	MeasureCounter = {
		Values = { "None", "8th", "12th", "16th", "24th", "32nd" },
	},
	-------------------------------------------------------------------------
	MeasureCounterOptions = {
		SelectType = "SelectMultiple",
		Values = { "MeasureCounterLeft", "MeasureCounterUp", "HideLookahead" },
	},
	-------------------------------------------------------------------------
	MeasureLines = {
		Values = { "Off", "Measure", "Quarter", "Eighth" },
	},
	-------------------------------------------------------------------------
	EvaluationExtras = {
		SelectType = "SelectMultiple",
		Values = { "ShowStreamBreakdown" },
		LoadSelections = function(self, list, pn)
			local mods = PlayerMods(pn)
			if not mods then return list end
			list[1] = mods.ShowStreamBreakdown == true
			return list
		end,
		SaveSelections = function(self, list, pn)
			local mods = PlayerMods(pn)
			if mods then mods.ShowStreamBreakdown = list[1] == true end
		end,
	},
	-------------------------------------------------------------------------
	VisualDelay = {
		Choices = function()
			local first	= -100
			local last 	= 100
			local step 	= 1
			return stringify( range(first, last, step), "%gms")
		end,
		ExportOnChange = true,
		LayoutType = "ShowOneInRow",
		SaveSelections = function(self, list, pn)
			local mods, playeroptions = GetModsAndPlayerOptions(pn)
			if not (mods and playeroptions) then return end

			for i=1,#self.Choices do
				if list[i] then
					mods.VisualDelay = self.Choices[i]
				end
			end
			local delayMs = Clamp(tostring(mods.VisualDelay or "0ms"):gsub("ms",""), -100, 100)
			mods.VisualDelay = ("%gms"):format(delayMs)
			if playeroptions.VisualDelay then
				SafeCall("PlayerOptions.VisualDelay", function()
					playeroptions:VisualDelay(delayMs/1000)
				end)
			end
		end
	},
	-------------------------------------------------------------------------
	TimingWindowOptions = {
		SelectType = "SelectMultiple",
		Values = { "HideEarlyDecentWayOffJudgments", "HideEarlyDecentWayOffFlash" }
	},
	-------------------------------------------------------------------------
	TimingWindows = {
		Values = function()
			return {
				{true,true,true,true,true},
				{true,true,true,false,false},
			}
		end,
		Choices = function()
			local gameMode = CurrentGameMode()
			local tns = "TapNoteScore" .. (gameMode=="ITG" and "" or gameMode)
			local t = {SafeThemeString("SLPlayerOptions","None")}
			if gameMode=="Casual" then
				local idx = 2
				t[idx] = SafeThemeString(tns,"W4").."s + "..t[idx-1]
			end
			return t
		end,
		LoadSelections = function(self, list, pn)
			local mods, playeroptions = GetModsAndPlayerOptions(pn)
			if not mods then return list end
			-- First determine the set of actual enabled windows.
			local windows = {true,true,true,true,true}
			if CurrentGameMode() == "Casual" then
				windows[4] = false
				windows[5] = false
				list[2] = true
			else
				if playeroptions and playeroptions.ResetDisabledTimingWindows then
					SafeCall("PlayerOptions.ResetDisabledTimingWindows", function()
						playeroptions:ResetDisabledTimingWindows()
					end)
				end
				list[1] = true
			end
			mods.TimingWindows = windows
			return list
		end,
		SaveSelections = function(self, list, pn)
			local mods, playeroptions = GetModsAndPlayerOptions(pn)
			if not (mods and playeroptions) then return end
			for i=1,#list do
				if list[i] then
					mods.TimingWindows = self.Values[i]
					if playeroptions.ResetDisabledTimingWindows then
						SafeCall("PlayerOptions.ResetDisabledTimingWindows", function()
							playeroptions:ResetDisabledTimingWindows()
						end)
					end
					if CurrentGameMode() == "ITG" then return end
					for i,enabled in ipairs(mods.TimingWindows) do
						if not enabled and playeroptions.DisableTimingWindow then
							SafeCall("PlayerOptions.DisableTimingWindow", function()
								playeroptions:DisableTimingWindow("TimingWindow_W"..i)
							end)
						end
					end
				end
			end
		end
	},
	-------------------------------------------------------------------------
	NoteFieldOffsetX = {
		LayoutType = "ShowOneInRow",
		ExportOnChange = true,
		Choices = function()
			local first	= 0
			local last 	= 50
			local step 	= 1

			return range(first, last, step)
		end,
		LoadSelections = function(self, list, pn)
			local mods = PlayerMods(pn)
			if not mods then return list end
			local val = Clamp(mods.NoteFieldOffsetX, 0, 50)
			for i,v in ipairs(self.Choices) do
				if v == val then
					list[i] = true
					break
				end
			end
			return list
		end,
		SaveSelections = function(self, list, pn)
			local mods = PlayerMods(pn)
			if not mods then return end
			for i,v in ipairs(self.Choices) do
				if list[i] then
					mods.NoteFieldOffsetX = Clamp(v, 0, 50)
					break
				end
			end
		end
	},
	-------------------------------------------------------------------------
	NoteFieldOffsetY = {
		LayoutType = "ShowOneInRow",
		ExportOnChange = true,
		Choices = function()
			local first	= -50
			local last 	= 50
			local step 	= 1

			return range(first, last, step)
		end,
		LoadSelections = function(self, list, pn)
			local mods = PlayerMods(pn)
			if not mods then return list end
			local val = Clamp(mods.NoteFieldOffsetY, -50, 50)
			for i,v in ipairs(self.Choices) do
				if v == val then
					list[i] = true
					break
				end
			end
			return list
		end,
		SaveSelections = function(self, list, pn)
			local mods = PlayerMods(pn)
			if not mods then return end
			for i,v in ipairs(self.Choices) do
				if list[i] then
					mods.NoteFieldOffsetY = Clamp(v, -50, 50)
					break
				end
			end
		end
	},
	-------------------------------------------------------------------------
	LifeMeterType = {
		Values = { "Standard", "Surround", "Vertical" },
	},
	-------------------------------------------------------------------------
	ScreenAfterPlayerOptions = {
		ApplyOnProfileLoad = false,
		Values = function()
			if HasActiveOnlineRoom() then
				return { "Ready", "Options2", "Options3" }
			end
			local finishChoice = "Gameplay"
			local choices = { finishChoice, "Select Music", "Options2", "Options3"  }
			if not ScreenSelectMusicAvailable() then table.remove(choices, 2) end
			return choices
		end,
		OneChoiceForAllPlayers = true,
		SaveSelections = function(self, list, pn)
			local screenAfter = EnsureScreenAfter()
			if HasActiveOnlineRoom() then
				if list[2] then
					screenAfter.PlayerOptions = "ScreenPlayerOptions2"
				elseif list[3] then
					screenAfter.PlayerOptions = "ScreenPlayerOptions3"
				else
					screenAfter.PlayerOptions = "ScreenOnlineLobbies"
				end
				return
			end
			if list[1] then
				screenAfter.PlayerOptions = Branch.GameplayScreen()
			end

			if ScreenSelectMusicAvailable() then
				if list[2] then screenAfter.PlayerOptions = Branch.SelectMusicOrCourse() end
				if list[3] then screenAfter.PlayerOptions = "ScreenPlayerOptions2" end
				if list[4] then screenAfter.PlayerOptions = "ScreenPlayerOptions3" end
			else
				if list[2] then screenAfter.PlayerOptions = "ScreenPlayerOptions2" end
				if list[3] then screenAfter.PlayerOptions = "ScreenPlayerOptions3" end
			end
		end
	},
	-------------------------------------------------------------------------
	ScreenAfterPlayerOptions2 = {
		ApplyOnProfileLoad = false,
		Values = function()
			if HasActiveOnlineRoom() then
				return { "Ready", "Options1", "Options3" }
			end
			local finishChoice = "Gameplay"
			local choices = { finishChoice, "Select Music", "Options1", "Options3"  }
			if not ScreenSelectMusicAvailable() then table.remove(choices, 2) end
			return choices
		end,
		OneChoiceForAllPlayers = true,
		SaveSelections = function(self, list, pn)
			local screenAfter = EnsureScreenAfter()
			if HasActiveOnlineRoom() then
				if list[2] then
					screenAfter.PlayerOptions2 = "ScreenPlayerOptions"
				elseif list[3] then
					screenAfter.PlayerOptions2 = "ScreenPlayerOptions3"
				else
					screenAfter.PlayerOptions2 = "ScreenOnlineLobbies"
				end
				return
			end
			if list[1] then
				screenAfter.PlayerOptions2 = Branch.GameplayScreen()
			end

			if ScreenSelectMusicAvailable() then
				if list[2] then screenAfter.PlayerOptions2 = Branch.SelectMusicOrCourse() end
				if list[3] then screenAfter.PlayerOptions2 = "ScreenPlayerOptions" end
				if list[4] then screenAfter.PlayerOptions2 = "ScreenPlayerOptions3" end
			else
				if list[2] then screenAfter.PlayerOptions2 = "ScreenPlayerOptions" end
				if list[3] then screenAfter.PlayerOptions2 = "ScreenPlayerOptions3" end
			end
		end
	},
	-------------------------------------------------------------------------
	-- this is so dumb; I need to find time to completely rewrite ScreenPlayerOptions :(
	ScreenAfterPlayerOptions3 = {
		ApplyOnProfileLoad = false,
		Values = function()
			if HasActiveOnlineRoom() then
				return { "Ready", "Options1", "Options2" }
			end
			local finishChoice = "Gameplay"
			local choices = { finishChoice, "Select Music", "Options1", "Options2"  }
			if not ScreenSelectMusicAvailable() then table.remove(choices, 2) end
			return choices
		end,
		OneChoiceForAllPlayers = true,
		SaveSelections = function(self, list, pn)
			local screenAfter = EnsureScreenAfter()
			if HasActiveOnlineRoom() then
				if list[2] then
					screenAfter.PlayerOptions3 = "ScreenPlayerOptions"
				elseif list[3] then
					screenAfter.PlayerOptions3 = "ScreenPlayerOptions2"
				else
					screenAfter.PlayerOptions3 = "ScreenOnlineLobbies"
				end
				return
			end
			if list[1] then
				screenAfter.PlayerOptions3 = Branch.GameplayScreen()
			end

			if ScreenSelectMusicAvailable() then
				if list[2] then screenAfter.PlayerOptions3 = Branch.SelectMusicOrCourse() end
				if list[3] then screenAfter.PlayerOptions3 = "ScreenPlayerOptions" end
				if list[4] then screenAfter.PlayerOptions3 = "ScreenPlayerOptions2" end
			else
				if list[2] then screenAfter.PlayerOptions3 = "ScreenPlayerOptions" end
				if list[3] then screenAfter.PlayerOptions3 = "ScreenPlayerOptions2" end
			end
		end
	}
	-------------------------------------------------------------------------
}


-- -----------------------------------------------------------------------
-- Generic OptionRow Definition
-- -----------------------------------------------------------------------
local OptionRowDefault = {
	-- the __index metatable will serve to define a completely generic OptionRow
	__index = {
		initialize = function(self, name)

			self.Name = name
			local override = Overrides[name]

			-- FIXME: add inline comments explaining the intent/purpose of All This Code
			if override.Snapshot then
				local ok, choices, values = SafeCall("OptionRow.Snapshot " .. name, function()
					return override.Snapshot()
				end)
				self.Choices = ok and type(choices) == "table" and choices or {}
				self.Values = ok and type(values) == "table" and values or {}
			elseif override.Values then
				local values = ResolveOptionTable("OptionRow.Values " .. name, override.Values)
				if override.Choices then
					self.Choices = ResolveOptionTable("OptionRow.Choices " .. name, override.Choices)
				else
					self.Choices = {}
					for i, v in ipairs(values) do
						self.Choices[i] = SafeThemeString("SLPlayerOptions", v)
					end
				end
				self.Values = values
			else
				self.Choices = ResolveOptionTable("OptionRow.Choices " .. name, override.Choices)
			end
			self.Choices = type(self.Choices) == "table" and self.Choices or {}
			self.Values = type(self.Values) == "table" and self.Values or nil

			-- define fallback values to use here if an override isn't specified
			self.LayoutType = override.LayoutType or "ShowAllInRow"
			self.SelectType = override.SelectType or "SelectOne"
			self.OneChoiceForAllPlayers = override.OneChoiceForAllPlayers or false
			self.ExportOnChange = override.ExportOnChange or false
			self.EnabledForPlayers = override.EnabledForPlayers or function() return HumanPlayers() end
			self.ReloadRowMessages = override.ReloadRowMessages or {}
			self.BroadcastOnExport = override.BroadcastOnExport or {}
			self.HideOnDisable = override.HideOnDisable or false
			self.ApplyOnProfileLoad = override.ApplyOnProfileLoad ~= false
			self.NotifyOfSelection = override.NotifyOfSelection or function() return false end
			
			if self.SelectType == "SelectOne" then

				self.LoadSelections = override.LoadSelections or function(subself, list, pn)
					local mods, playeroptions = GetModsAndPlayerOptions(pn)
					if not mods then return list end
					local vals = self.Values or self.Choices
					if #vals == 0 then return list end
					local choice = mods[name]
					if choice == nil and playeroptions and type(playeroptions[name]) == "function" then
						local ok, optionValue = SafeCall("PlayerOptions." .. name, function()
							return playeroptions[name](playeroptions)
						end)
						if ok then choice = optionValue end
					end
					choice = choice or vals[1]
					local i = FindInTable(choice, vals) or 1
					if vals[i] ~= nil then list[i] = true end
					return list
				end
				self.SaveSelections = override.SaveSelections or function(subself, list, pn)
					local mods = PlayerMods(pn)
					if not mods then return end
					local vals = self.Values or self.Choices
					for i, val in ipairs(vals) do
						if list[i] then mods[name] = val; break end
					end
				end

			else
				-- "SelectMultiple" typically means a collection of theme-defined flags in a single OptionRow
				-- most of these behave the same and can fall back on this generic definition; a notable exception is "Hide"
				self.LoadSelections = override.LoadSelections or function(subself, list, pn)
					local mods = PlayerMods(pn)
					if not mods then return list end
					local vals = self.Values or self.Choices
					for i, mod in ipairs(vals) do
						list[i] = mods[mod] or false
					end
					return list
				end
				self.SaveSelections = override.SaveSelections or function(subself, list, pn)
					local mods = PlayerMods(pn)
					if not mods then return end
					local vals = self.Values or self.Choices
					for i, mod in ipairs(vals) do
						mods[mod] = list[i] == true
					end
				end
			end

			return self
		end
	}
}

-- -----------------------------------------------------------------------
-- Passed a string like "Mini", CustomOptionRow() will return table that represents
-- the themeside attributes of the OptionRow for Mini.
--
-- CustomOptionRow() is mostly used in Metrics.ini under [ScreenPlayerOptions] and siblings
-- to pass OptionRow data (Lua) to the engine (C++) via Metrics (ini).
--
-- There are a few other places in the theme where CustomOptionRow() is used to retrieve a list
-- of possible choices for a given OptionRow and then do something based on that list.
-- For example, ./ScreenPlayerOptions overlay/NoteSkinPreviews.lua uses it to get a list of NoteSkins
-- so it can load preview NoteSkin actors into the overlay's ActorFrame ahead of time.

function CustomOptionRow( name )
	if not (type(name)=="string" and Overrides[name]) then return false end

	-- assign the properties of the generic OptionRowDefault to OptRow
	local OptRow = setmetatable( {}, OptionRowDefault )

	-- now that OptRow has the method available, run its initialize() method
	return OptRow:initialize( name )
end


-- -----------------------------------------------------------------------
-- Mods are applied in their respective SaveSelections() functions when
-- ScreenPlayerOptions receives its OffCommand(), but what happens
-- if a player expects mods to have been set via a profile,
-- and thus never visits ScreenPlayerOptions?
--
-- Thus, we have this global function, ApplyMods(), which we can call from
-- ./BGAnimations/ScreenProfileLoad overlay.lua
-- as well as the the PlayerJoinedMessageCommand of
-- /BGAnimations/ScreenSelectMusic overlay/PlayerModifiers.lua
-- the former handles "normally" joined players, and the latter handles latejoin

function ApplyMods(player)
	local previousApplyingProfileMods = applyingProfileMods
	applyingProfileMods = true

	for name,override in pairs(Overrides) do
		if override.ApplyOnProfileLoad ~= false then
			SafeCall("ApplyMods " .. tostring(name), function()
				local optRow = CustomOptionRow(name)
				if type(optRow) ~= "table"
					or type(optRow.Choices) ~= "table"
					or type(optRow.LoadSelections) ~= "function"
					or type(optRow.SaveSelections) ~= "function" then
					PlayerOptionsTrace("apply_mods_skip_invalid_row name=" .. tostring(name))
					return
				end

				-- LoadSelections() receives a false-filled list matching the row's
				-- current choices, then SaveSelections() applies only profile-safe
				-- engine/player modifiers.
				local list = {}
				for i=1, #optRow.Choices do
					list[i] = false
				end
				local okLoad, loaded = SafeCall("ApplyMods.LoadSelections " .. tostring(name), function()
					return optRow:LoadSelections(list, player)
				end)
				if okLoad and type(loaded) == "table" then list = loaded end
				SafeCall("ApplyMods.SaveSelections " .. tostring(name), function()
					optRow:SaveSelections(list, player)
				end)
			end)
		end
	end

	applyingProfileMods = previousApplyingProfileMods
end
