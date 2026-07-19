-- -----------------------------------------------------------------------
-- call this to draw a Quad with a border
-- arguments are: width of quad, height of quad, and border width, in pixels

local function sl_helpers_trace(message)
	local line = "SL-Helpers: " .. tostring(message or "")
	if type(Trace) == "function" then
		Trace(line)
	elseif type(Warn) == "function" then
		Warn(line)
	end
end

local function safe_call(context, fn)
	if type(fn) ~= "function" then return false, nil end
	local results = { pcall(fn) }
	local ok = table.remove(results, 1)
	if not ok then
		sl_helpers_trace("safe_call_failed context=" .. tostring(context or "unknown")
			.. " error=" .. tostring(results[1]))
		return false, nil
	end
	return true, unpack(results)
end

local function safe_method(context, object, method, ...)
	if not (object and type(object[method]) == "function") then return nil end
	local args = { ... }
	local ok, result = safe_call(context, function()
		return object[method](object, unpack(args))
	end)
	return ok and result or nil
end

local function finite_number_or(value, fallback)
	value = tonumber(value)
	if value ~= nil and value == value and value ~= math.huge and value ~= -math.huge then
		return value
	end
	return fallback
end

local function positive_number_or(value, fallback)
	value = finite_number_or(value, fallback)
	if value == nil or value <= 0 then return fallback end
	return value
end

local function clamp_number(value, minimum, maximum, fallback)
	value = finite_number_or(value, fallback or minimum)
	if value < minimum then return minimum end
	if value > maximum then return maximum end
	return value
end

local function format_mini_option(option, mods)
	local mini = mods and mods.Mini
	if type(mini) == "string" then
		local value = mini:match("^%s*([%+%-]?%d+%.?%d*)%%?%s*$")
		if value then return value .. "% Mini" end
	elseif type(mini) == "number" and mini == mini and mini ~= math.huge and mini ~= -math.huge then
		return ("%g%% Mini"):format(mini)
	end

	local option_value = tostring(option or ""):match("([%+%-]?%d+%.?%d*)%%?%s*Mini")
	if option_value then return option_value .. "% Mini" end

	return "Mini"
end

local function option_enabled(value)
	value = finite_number_or(value, value)
	if type(value) == "number" then return value > 0 end
	return value == true
end

local function safe_preference(name, fallback)
	if not (PREFSMAN and type(PREFSMAN.GetPreference) == "function") then return fallback end
	local ok, value = safe_call("PREFSMAN.GetPreference " .. tostring(name), function()
		return PREFSMAN:GetPreference(name)
	end)
	if not ok or value == nil then return fallback end
	return value
end

RoutineCoupleTrace = function(message)
	if safe_preference("review_src", false) ~= true then return end
	local line = "ROUTINE_COUPLE_TRACE component=theme " .. tostring(message or "")
	if type(Trace) == "function" then
		Trace(line)
	elseif type(Warn) == "function" then
		Warn(line)
	end
end

local function safe_preference_number(name, fallback)
	return finite_number_or(safe_preference(name, fallback), fallback)
end

local function safe_theme_pref(name, fallback)
	if not (ThemePrefs and type(ThemePrefs.Get) == "function") then return fallback end
	local ok, value = safe_call("ThemePrefs.Get " .. tostring(name), function()
		return ThemePrefs.Get(name)
	end)
	if not ok or value == nil then return fallback end
	return value
end

IsTemporarySelectMusicAutoStyle = function()
	return SL and SL.Global and SL.Global.SelectMusicTemporaryAutoStyle == true
end

IsSelectMusicAutoStyle = function()
	return safe_theme_pref("AutoStyle", "none") == "auto" or IsTemporarySelectMusicAutoStyle()
end

SetTemporarySelectMusicAutoStyle = function(enabled)
	SL = SL or {}
	SL.Global = SL.Global or {}
	SL.Global.SelectMusicTemporaryAutoStyle = enabled == true
end

local function safe_theme_string(group, key)
	if not (THEME and type(THEME.GetString) == "function") then return tostring(key or "") end
	local ok, value = safe_call("THEME.GetString " .. tostring(group) .. "." .. tostring(key), function()
		return THEME:GetString(group, key)
	end)
	return ok and tostring(value or key or "") or tostring(key or "")
end

local function safe_enum_short(value, fallback)
	if type(ToEnumShortString) ~= "function" or value == nil then return fallback end
	local ok, result = safe_call("ToEnumShortString", function()
		return ToEnumShortString(value)
	end)
	return ok and result or fallback
end

local function safe_game_state_method(method, fallback, ...)
	if not (GAMESTATE and type(GAMESTATE[method]) == "function") then return fallback end
	local args = { ... }
	local ok, result = safe_call("GAMESTATE." .. tostring(method), function()
		return GAMESTATE[method](GAMESTATE, unpack(args))
	end)
	if not ok or result == nil then return fallback end
	return result
end

local function safe_current_game_name()
	local game = safe_game_state_method("GetCurrentGame", nil)
	return tostring(safe_method("Game.GetName", game, "GetName") or "dance")
end

local function safe_current_style()
	return safe_game_state_method("GetCurrentStyle", nil)
end

local function safe_player_state(player)
	return safe_game_state_method("GetPlayerState", nil, player)
end

local function safe_player_options(player, modsLevel)
	local state = safe_player_state(player)
	return safe_method("PlayerState.GetPlayerOptions", state, "GetPlayerOptions", modsLevel or "ModsLevel_Preferred")
end

local function safe_player_options_array(player, modsLevel)
	local state = safe_player_state(player)
	local options = safe_method("PlayerState.GetPlayerOptionsArray", state, "GetPlayerOptionsArray", modsLevel or "ModsLevel_Preferred")
	return type(options) == "table" and options or {}
end

local function safe_player_mods(player)
	local pn = safe_enum_short(player, nil)
	local playerState = pn and SL and SL[pn] or nil
	local mods = playerState and playerState.ActiveModifiers or nil
	return type(mods) == "table" and mods or {}, pn, playerState
end

local function safe_is_course_mode()
	return safe_game_state_method("IsCourseMode", false) == true
end

local function safe_human_players()
	local players = safe_game_state_method("GetHumanPlayers", {})
	return type(players) == "table" and players or {}
end

local function safe_radar_value(owner, player, category)
	local radar = safe_method("RadarOwner.GetRadarValues", owner, "GetRadarValues", player)
	return math.max(0, finite_number_or(safe_method("RadarValues.GetValue", radar, "GetValue", category), 0))
end

local function safe_trail_entry_radar_values(owner, player)
	if not (owner and owner.GetTrailEntries) then return 0, 0, 0, 0 end
	local entries = safe_method("Trail.GetTrailEntries", owner, "GetTrailEntries")
	if type(entries) ~= "table" then return 0, 0, 0, 0 end

	local totalSteps, totalHolds, totalRolls, entryCount = 0, 0, 0, 0
	for _, entry in ipairs(entries) do
		local steps = safe_method("TrailEntry.GetSteps", entry, "GetSteps")
		if steps then
			totalSteps = totalSteps + safe_radar_value(steps, player, "RadarCategory_TapsAndHolds")
			totalHolds = totalHolds + safe_radar_value(steps, player, "RadarCategory_Holds")
			totalRolls = totalRolls + safe_radar_value(steps, player, "RadarCategory_Rolls")
			entryCount = entryCount + 1
		end
	end

	return totalSteps, totalHolds, totalRolls, entryCount
end

local function safe_stats_tap_score(stats, window)
	return math.max(0, finite_number_or(safe_method("PlayerStageStats.GetTapNoteScores", stats, "GetTapNoteScores", window), 0))
end

local safe_stage_index

local function safe_player_stage_stats(player)
	local curStageStats = safe_method("STATSMAN.GetCurStageStats", STATSMAN, "GetCurStageStats")
	local stats = safe_method("StageStats.GetPlayerStageStats", curStageStats, "GetPlayerStageStats", player)
	if stats then return stats end

	local playerKey = safe_enum_short(player, nil)
	return playerKey and safe_method("StageStats.GetPlayerStageStats", curStageStats, "GetPlayerStageStats", playerKey) or nil
end

local routine_stage_stats_trace = {}

GetRoutineSourcePlayer = function(player)
	if IsRoutine and IsRoutine() then
		local master = safe_game_state_method("GetMasterPlayerNumber", nil)
		if master ~= nil then return master end
	end
	return player
end

GetEvaluationPlayerStageStats = function(player)
	local curStageStats = safe_method("STATSMAN.GetCurStageStats", STATSMAN, "GetCurStageStats")
	if IsRoutine and IsRoutine() then
		local routineStats = safe_method("StageStats.GetRoutineStageStats", curStageStats, "GetRoutineStageStats")
		if routineStats then
			local sourcePlayer = GetRoutineSourcePlayer(player)
			local key = tostring(safe_stage_index()) .. ":" .. tostring(safe_enum_short(player, player))
			if not routine_stage_stats_trace[key] then
				routine_stage_stats_trace[key] = true
				RoutineCoupleTrace("event=evaluation_stats_source mode=routine shared=1"
					.. " player=" .. tostring(safe_enum_short(player, player))
					.. " source=" .. tostring(safe_enum_short(sourcePlayer, sourcePlayer))
					.. " stage=" .. tostring(safe_stage_index()))
			end
			return routineStats, sourcePlayer, true
		end
	end

	return safe_player_stage_stats(player), player, false
end

local function safe_stage_possible_radar_value(player, category)
	local stats = safe_player_stage_stats(player)
	local radar = safe_method("PlayerStageStats.GetRadarPossible", stats, "GetRadarPossible")
	return math.max(0, finite_number_or(safe_method("RadarValues.GetValue", radar, "GetValue", category), 0))
end

local function safe_score_possible_values(owner, player)
	local totalSteps = safe_radar_value(owner, player, "RadarCategory_TapsAndHolds")
	local totalHolds = safe_radar_value(owner, player, "RadarCategory_Holds")
	local totalRolls = safe_radar_value(owner, player, "RadarCategory_Rolls")
	local source = "steps_or_trail"

	if safe_is_course_mode() and totalSteps <= 0 then
		local trailSteps, trailHolds, trailRolls, trailEntries = safe_trail_entry_radar_values(owner, player)
		if trailSteps > 0 then
			totalSteps = trailSteps
			totalHolds = trailHolds
			totalRolls = trailRolls
			source = "trail_entries:" .. tostring(trailEntries)
			return totalSteps, totalHolds, totalRolls, source
		end

		local stageSteps = safe_stage_possible_radar_value(player, "RadarCategory_TapsAndHolds")
		if stageSteps > 0 then
			totalSteps = stageSteps
			totalHolds = safe_stage_possible_radar_value(player, "RadarCategory_Holds")
			totalRolls = safe_stage_possible_radar_value(player, "RadarCategory_Rolls")
			source = "stage_possible"
		end
	end

	return totalSteps, totalHolds, totalRolls, source
end

local score_possible_trace_counts = {}
local score_possible_trace_version_logged = false
local function trace_score_possible(kind, player, source, totalSteps, totalHolds, totalRolls, primaryWeight, heldWeight, totalPossible)
	if not (safe_is_course_mode() and Trace and (source ~= "steps_or_trail" or totalPossible <= 0)) then return end
	if not score_possible_trace_version_logged then
		score_possible_trace_version_logged = true
		Trace("FA_PLUS_CALC_VERSION: course full-trail EX/HardEX denominator v3")
	end
	local key = tostring(kind) .. ":" .. tostring(source) .. ":" .. tostring(totalPossible <= 0)
	score_possible_trace_counts[key] = (score_possible_trace_counts[key] or 0) + 1
	local seen = score_possible_trace_counts[key]
	if seen > 4 and seen % 200 ~= 0 then return end

	Trace(("FA_PLUS_CALC: type=%s seen=%s player=%s source=%s totalSteps=%s totalHolds=%s totalRolls=%s primaryWeight=%s heldWeight=%s possible=%s"):format(
		tostring(kind),
		tostring(seen),
		tostring(safe_enum_short(player, player)),
		tostring(source),
		tostring(totalSteps),
		tostring(totalHolds),
		tostring(totalRolls),
		tostring(primaryWeight),
		tostring(heldWeight),
		tostring(totalPossible)
	))
end

safe_stage_index = function()
	local played = SL and SL.Global and SL.Global.Stages and SL.Global.Stages.PlayedThisGame
	return math.max(1, math.floor(finite_number_or(played, 0) + 1))
end

local function active_music_rate()
	local rate = SL and SL.Global and SL.Global.ActiveModifiers and SL.Global.ActiveModifiers.MusicRate
	return positive_number_or(rate, 1)
end

local function safe_dir_listing(path, dirs_only, return_full_path)
	if type(path) ~= "string" or path == "" then return {} end
	if not (FILEMAN and type(FILEMAN.GetDirListing) == "function") then return {} end
	local ok, files = safe_call("FILEMAN.GetDirListing " .. path, function()
		return FILEMAN:GetDirListing(path, dirs_only, return_full_path)
	end)
	return ok and type(files) == "table" and files or {}
end

Border = function(width, height, bw)
	width  = math.max(2, finite_number_or(width, 2))
	height = math.max(2, finite_number_or(height, 2))
	bw     = clamp_number(bw, 0, math.min(width, height) / 2, 1)

	return Def.ActorFrame {
		Def.Quad { InitCommand=function(self) self:zoomto(width-2*bw, height-2*bw):MaskSource(true) end },
		Def.Quad { InitCommand=function(self) self:zoomto(width,height):MaskDest() end },
		Def.Quad { InitCommand=function(self) self:diffusealpha(0):clearzbuffer(true) end },
	}
end

-- -----------------------------------------------------------------------
-- SL_WideScale() is modified version of WideScale() from SM5.1's _fallback theme
--
-- _fallback's WideScale() is useful for scaling a number to accommodate both 4:3 and 16:9 aspect ratios
-- first arg is what will be returned if AspectRatio is 4:3
-- second arg is what will be returned if AspectRatio is 16:9
-- The number returned will be scaled proprotionately between if AspectRatio is, for example, 16:10
-- and likewise scaled futher up if AspectRatio is, for example, 21:9.
--
-- SL's UI was originally designed for 4:3 and later extended for 16:9, so WideScale() works great there.
-- I'm opting to accommodate ultrawide displays by clamping the scale at 16:9.
--
-- You may not want to adopt this strategy in your theme, but for here
-- it's easier than redesigning the UI again.
--
-- It's important to not override _fallback's WideScale() for the sake of scripted simfiles
-- that expect it to behave a particular way.

SL_WideScale = function(AR4_3, AR16_9)
	AR4_3 = finite_number_or(AR4_3, 0)
	AR16_9 = finite_number_or(AR16_9, AR4_3)
	local width = finite_number_or(SCREEN_WIDTH, 640)
	return clamp(scale(width, 640, 854, AR4_3, AR16_9), math.min(AR4_3, AR16_9), math.max(AR4_3, AR16_9))
end

-- -----------------------------------------------------------------------
BackgroundFilterValues = function()
	return {
		Off = 0,
		Dark = 50,
		Darker = 75,
		Darkest = 95,
	}
end


-- -----------------------------------------------------------------------
-- get timing window in milliseconds

GetTimingWindow = function(n, mode, useHardExInnerWindow)
	n = math.floor(clamp_number(n, 1, NumJudgmentsAvailable(), 1))
	local gameMode = mode or (SL and SL.Global and SL.Global.GameMode) or "ITG"
	local scale = positive_number_or(safe_preference_number("TimingWindowScale", 1), 1)

	if n == 1 and mode == "FA+" and useHardExInnerWindow then
		local prefs = SL and SL.Preferences and SL.Preferences["FA+"] or {}
		return math.max(0, 0.0085 * scale + finite_number_or(prefs.TimingWindowAdd, 0))
	end

	local prefs = SL and SL.Preferences and SL.Preferences[gameMode] or {}
	local seconds = finite_number_or(prefs["TimingWindowSecondsW"..n], nil)
	if seconds == nil and SL and SL.Preferences and SL.Preferences.ITG then
		prefs = SL.Preferences.ITG
		seconds = finite_number_or(prefs["TimingWindowSecondsW"..n], 0)
	end
	return math.max(0, finite_number_or(seconds, 0) * scale + finite_number_or(prefs.TimingWindowAdd, 0))
end

-- -----------------------------------------------------------------------
-- determines which timing_window an offset value (number) belongs to
-- used by the judgment scatter plot and offset histogram in ScreenEvaluation

DetermineTimingWindow = function(offset)
	offset = math.abs(finite_number_or(offset, math.huge))
	for i=1,NumJudgmentsAvailable() do
		if offset <= GetTimingWindow(i) then
			return i
		end
	end
	return 5
end

-- -----------------------------------------------------------------------
-- return number of available judgments

NumJudgmentsAvailable = function()
	return 5
end

-- -----------------------------------------------------------------------
-- get worst timing judgment hit for a song

GetWorstJudgment = function(offsets)
	local worst_judgment = 1
	for i in ivalues(type(offsets) == "table" and offsets or {}) do
		local offset = type(i) == "table" and i[2] or nil
		if offset ~= "Miss" then
			local judgment = DetermineTimingWindow(offset)
			if worst_judgment < judgment then
				worst_judgment = judgment
			end
		end
	end

	return worst_judgment
end

-- -----------------------------------------------------------------------
-- some common information needed by ScreenSystemOverlay's credit display,
-- as well as ScreenTitleJoin overlay and ./Scripts/SL-Branches.lua regarding coin credits

GetCredits = function()
	local coins = math.max(0, math.floor(finite_number_or(safe_game_state_method("GetCoins", 0), 0)))
	local coinsPerCredit = math.max(1, math.floor(safe_preference_number('CoinsPerCredit', 1)))
	local credits = math.floor(coins/coinsPerCredit)
	local remainder = coins % coinsPerCredit

	return { Credits=credits,Remainder=remainder, CoinsPerCredit=coinsPerCredit }
end

-- -----------------------------------------------------------------------
-- return the x value for the center of a player's notefield
--   this is used to position various elements in ScreenGameplay
--   but it is not used to position the notefields themselves
--   (that's handled in Metrics.ini under [ScreenGameplay])

local function BaseNotefieldX(player)
	if not player then return _screen and _screen.cx or 0 end

	local style = safe_current_style()
	if not style then return _screen and _screen.cx or 0 end

	local p = safe_enum_short(player, player == PLAYER_1 and "P1" or "P2")
	local game = safe_current_game_name()

	local styleStepsType = tostring(safe_method("Style.GetStepsType", style, "GetStepsType") or "")
	local styleName = tostring(safe_method("Style.GetName", style, "GetName") or "")
	local IsPlayingDanceSolo = (styleStepsType == "StepsType_Dance_Solo")
	local IsPlayingDanceThreePanel = (styleName == "threepanel")
	local NumPlayersEnabled  = math.max(0, math.floor(finite_number_or(safe_game_state_method("GetNumPlayersEnabled", 0), 0)))
	local NumSidesJoined     = math.max(0, math.floor(finite_number_or(safe_game_state_method("GetNumSidesJoined", 0), 0)))
	local IsUsingSoloSingles = safe_preference("Center1Player", false) == true or IsPlayingDanceSolo or IsPlayingDanceThreePanel or (NumSidesJoined==1 and (game=="techno" or game=="kb7"))

	-- dance solo is always centered
	if IsUsingSoloSingles and NumPlayersEnabled == 1 and NumSidesJoined == 1 then return _screen.cx end
	-- double is always centered
	if safe_method("Style.GetStyleType", style, "GetStyleType") == "StyleType_OnePlayerTwoSides" then return _screen.cx end

	local mods = safe_player_mods(player)
	local PlayerOffset = finite_number_or(mods.NoteFieldOffsetX, 0) * (player == PLAYER_1 and -1 or 1)

	local NumPlayersAndSides = safe_enum_short(safe_method("Style.GetStyleType", style, "GetStyleType"), "")
	local fallbackX = _screen and _screen.cx or 0
	if not (THEME and type(THEME.GetMetric) == "function") then return fallbackX + PlayerOffset end
	local ok, metric = safe_call("THEME.GetMetric ScreenGameplay PlayerX", function()
		return THEME:GetMetric("ScreenGameplay","Player".. p .. NumPlayersAndSides .."X")
	end)
	return finite_number_or(ok and metric or nil, fallbackX) + PlayerOffset
end

GetOnlineGameplayColumnX = function(column)
	local layout = GetOnlineGameplayLayout()
	local data = layout.columns[column or "center"] or layout.columns.center
	return data.x
end

GetOnlineGameplayPanelWidth = function(kind)
	local layout = GetOnlineGameplayLayout()
	if kind == "center" or kind == "leaderboard" then
		return layout.leaderboard_width
	end
	return layout.side_panel_width
end

IsOnlineGameplayLayoutLoggingEnabled = function()
	return ThemePrefs
		and ThemePrefs.Get
		and ThemePrefs.Get("ITGOnlineGameplayLayoutLogs") == true
end

local function IsOnlineDiagnosticLoggingEnabled(prefName)
	return ThemePrefs and ThemePrefs.Get and ThemePrefs.Get(prefName) == true
end

IsOnlineNetworkLoggingEnabled = function()
	return IsOnlineDiagnosticLoggingEnabled("ITGOnlineNetworkLogs")
end

IsOnlineAuthLoggingEnabled = function()
	return IsOnlineDiagnosticLoggingEnabled("ITGOnlineAuthLogs")
end

IsOnlineScoreLoggingEnabled = function()
	return IsOnlineDiagnosticLoggingEnabled("ITGOnlineScoreLogs")
end

local online_layout_trace_keys = {}
local function TraceOnlineLayoutState(name, key, message)
	if not (Trace and IsOnlineGameplayLayoutLoggingEnabled()) then return end
	key = tostring(key or "")
	if online_layout_trace_keys[name] == key then return end
	online_layout_trace_keys[name] = key
	Trace(message)
end

GetOnlineGameplayLayout = function()
	local margin = clamp(_screen.w * 0.055, 44, 120)
	local usable_width = math.max(1, _screen.w - (margin * 2))
	local column_width = usable_width / 3
	local aspect = GetScreenAspectRatio()
	local compact_aspect = 4/3
	local ultra_aspect = 8/3
	local aspect_factor = clamp((aspect - compact_aspect) / (ultra_aspect - compact_aspect), 0, 1)
	local leaderboard_ratio = 0.65 + ((1.10 - 0.65) * aspect_factor)
	local columns = {
		left = {
			x = margin + (column_width / 2),
			left = margin,
			right = margin + column_width,
		},
		center = {
			x = _screen.cx,
			left = margin + column_width,
			right = margin + (column_width * 2),
		},
		right = {
			x = _screen.w - margin - (column_width / 2),
			left = margin + (column_width * 2),
			right = _screen.w - margin,
		},
	}

	local layout_trace = "SL_ONLINE_LAYOUT_CALC"
			.. " screen_w=" .. tostring(_screen.w)
			.. " screen_h=" .. tostring(_screen.h)
			.. " screen_cx=" .. tostring(_screen.cx)
			.. " aspect=" .. tostring(aspect)
			.. " margin=" .. tostring(margin)
			.. " usable_width=" .. tostring(usable_width)
			.. " column_width=" .. tostring(column_width)
			.. " side_panel_width=" .. tostring(GetNotefieldWidth() or 256)
			.. " leaderboard_ratio=" .. tostring(leaderboard_ratio)
			.. " leaderboard_width=" .. tostring(column_width * leaderboard_ratio)
			.. " left_x=" .. tostring(columns.left.x)
			.. " center_x=" .. tostring(columns.center.x)
			.. " right_x=" .. tostring(columns.right.x)
	TraceOnlineLayoutState("layout", layout_trace, layout_trace)

	return {
		margin = margin,
		usable_width = usable_width,
		column_width = column_width,
		side_panel_width = GetNotefieldWidth() or 256,
		leaderboard_width = column_width * leaderboard_ratio,
		columns = columns,
	}
end

IsUsingOnlineGameplayColumns = function()
	local style = GAMESTATE:GetCurrentStyle()
	local top_screen = SCREENMAN and SCREENMAN:GetTopScreen() or nil
	local screen_name = top_screen and top_screen:GetName() or ""
	local has_active_online_room = ITGOnline
		and ITGOnline.currentRoomId ~= nil
		and ITGOnline.currentRoom ~= nil
	local has_online_gameplay_context = has_active_online_room
		and (
			(SL.Global.Online and SL.Global.Online.GameplayLayoutActive == true)
			or ITGOnline.currentSongPayload ~= nil
			or ITGOnline.activeGameplaySongPayload ~= nil
			or tostring(ITGOnline.activeGameplayRoundKey or "") ~= ""
			or tostring(ITGOnline.currentRoomRoundKey or "") ~= ""
		)
	local result = ITGOnline
		and has_online_gameplay_context
		and style
		and style:GetName() == "single"

	local columns_trace = "SL_ONLINE_COLUMNS_CHECK"
			.. " result=" .. tostring(result == true)
			.. " screen=" .. tostring(screen_name)
			.. " style=" .. tostring(style and style:GetName() or "nil")
			.. " has_itgonline=" .. tostring(ITGOnline ~= nil)
			.. " has_active_room=" .. tostring(has_active_online_room == true)
			.. " has_context=" .. tostring(has_online_gameplay_context == true)
			.. " layout_flag=" .. tostring(SL.Global.Online and SL.Global.Online.GameplayLayoutActive)
			.. " room_id=" .. tostring(ITGOnline and ITGOnline.currentRoomId or "nil")
			.. " has_room=" .. tostring(ITGOnline and ITGOnline.currentRoom ~= nil)
			.. " has_user=" .. tostring(ITGOnline and ITGOnline.user ~= nil)
			.. " user_id=" .. tostring(ITGOnline and ITGOnline.user and ITGOnline.user.id or "nil")
			.. " has_current_song_payload=" .. tostring(ITGOnline and ITGOnline.currentSongPayload ~= nil)
			.. " has_active_gameplay_song=" .. tostring(ITGOnline and ITGOnline.activeGameplaySongPayload ~= nil)
			.. " active_round_key=" .. tostring(ITGOnline and ITGOnline.activeGameplayRoundKey or "nil")
			.. " room_round_key=" .. tostring(ITGOnline and ITGOnline.currentRoomRoundKey or "nil")
	TraceOnlineLayoutState("columns", columns_trace, columns_trace)

	return result
end

GetOnlineGameplayPlayerColumn = function(player)
	if not player then return "center" end
	return player == PLAYER_1 and "left" or "right"
end

GetOnlineGameplayStatsColumn = function(player)
	if not player then return "center" end

	if #safe_human_players() > 1 then
		return player == PLAYER_1 and "left" or "right"
	end

	return player == PLAYER_1 and "right" or "left"
end

GetBaseNotefieldX = function(player)
	return BaseNotefieldX(player)
end

GetNotefieldX = function(player)
	local useOnlineColumns = false
	if type(IsUsingOnlineGameplayColumns) == "function" then
		local ok, result = safe_call("IsUsingOnlineGameplayColumns", IsUsingOnlineGameplayColumns)
		useOnlineColumns = ok and result == true
	end
	if useOnlineColumns then
		local pn = safe_enum_short(player, "")
		local player_offset = finite_number_or(
			SL and SL[pn] and SL[pn].ActiveModifiers and SL[pn].ActiveModifiers.NoteFieldOffsetX,
			0)
			* (player == PLAYER_1 and -1 or 1)
		local columnX = nil
		if type(GetOnlineGameplayColumnX) == "function" then
			local okColumn, value = safe_call("GetOnlineGameplayColumnX", function()
				return GetOnlineGameplayColumnX(GetOnlineGameplayPlayerColumn(player))
			end)
			columnX = okColumn and finite_number_or(value, nil) or nil
		end
		if columnX ~= nil then return columnX + player_offset end
	end

	return BaseNotefieldX(player)
end

-- -----------------------------------------------------------------------
-- this is verbose, but it lets us manage what seem to be
-- quirks/oversights in the engine on a per-game + per-style basis

local NoteFieldWidth = {
	-- dance uses such nice, clean multiples of 64.  It's almost like this game gets the most attention and fixes.
	dance = {
		single  = 256,
		versus  = 256,
		double  = 512,
		solo    = 384,
		threepanel = 192,
		routine = 512,
		couple  = 256,
	},
	-- pump's values are very similar to those used in dance, but curiously smaller
	pump = {
		single  = 250,
		versus  = 250,
		double  = 500,
		routine = 500,
		couple  = 250,
	},
	-- These values for techno, para, and kb7 are the result of empirical observation
	-- of the SM5 engine and should not be regarded as any kind of Truth.
	techno = {
		single8 = 448,
		versus8 = 272,
		double8 = 543,
	},
	para = {
		single = 280,
		versus = 280,
	},
	kb7 = {
		single = 480,
		versus = 270,
	},
}

GetNotefieldWidth = function()
	local game = safe_game_state_method("GetCurrentGame", nil)

	if game then
		local game_widths = NoteFieldWidth[tostring(safe_method("Game.GetName", game, "GetName") or "")]
		local style = safe_current_style()
		if style then
			return game_widths and game_widths[tostring(safe_method("Style.GetName", style, "GetName") or "")] or false
		end
	end

	return false
end

-- -----------------------------------------------------------------------
-- Define what is necessary to maintain and/or increment your combo, per Gametype.
-- For example, in dance Gametype, TapNoteScore_W3 (window #3) is commonly "Great"
-- so in dance, a "Great" will not only maintain a player's combo, it will also increment it.
--
-- We reference this function in Metrics.ini under the [Gameplay] section.
GetComboThreshold = function( MaintainOrContinue )

	local Combo = {}
	Combo.dance = { Maintain = "TapNoteScore_W3", Continue = "TapNoteScore_W3" }
	Combo.pump  = { Maintain = "TapNoteScore_W4", Continue = "TapNoteScore_W4" }
	Combo.techno= { Maintain = "TapNoteScore_W3", Continue = "TapNoteScore_W3" }
	Combo.kb7   = { Maintain = "TapNoteScore_W4", Continue = "TapNoteScore_W4" }

	-- values for para were inherited from freem's Moonlight theme which had an inline comment stating:
	-- "these are chosen to match Deluxe's PARASTAR"
	Combo.para = { Maintain = "TapNoteScore_W5", Continue = "TapNoteScore_W3" }

	-- I don't know what these values are supposed to be.
	Combo.popn    = { Maintain = "TapNoteScore_W3", Continue = "TapNoteScore_W3" }
	Combo.beat    = { Maintain = "TapNoteScore_W3", Continue = "TapNoteScore_W3" }
	Combo.kickbox = { Maintain = "TapNoteScore_W3", Continue = "TapNoteScore_W3" }

	-- lights is not a playable game mode, but it is, oddly, a selectable one within the operator menu
	-- include dummy values here to prevent Lua errors in case players accidentally switch to lights
	Combo.lights  = { Maintain = "TapNoteScore_W3", Continue = "TapNoteScore_W3" }

	local game = safe_current_game_name()
	local combo = Combo[game] or Combo.dance
	return combo[MaintainOrContinue] or combo.Maintain
end

-- -----------------------------------------------------------------------

-- FailType is a PlayerOption that can be set using SM5's PlayerOptions interface.
-- If you wanted, you could set FailTyper per-player, prior to Gameplay like
--
-- GAMESTATE:GetPlayerState(PLAYER_1):GetPlayerOptions("ModsLevel_Preferred"):FailSetting("FailType_ImmediateContinue")
-- GAMESTATE:GetPlayerState(PLAYER_2):GetPlayerOptions("ModsLevel_Preferred"):FailSetting("FailType_Off")
--
-- and then P1 and P2 would have different Fail settings during gameplay.
--
-- That sounds kind of chaotic, particularly with saving Machine HighScores, so Simply Love
-- enforces the same FailType for both players and allows machine operators to set a
-- "default FailType" within Advanced Options in the Operator Menu.
--
-- This "default FailType" is sort of handled by the engine, but not in a way that is
-- necessarily clear to me.  Whatever the history there was, it is lost to me now.
--
-- The engine's FailType enum has the following four values:
-- 'FailType_Immediate', 'FailType_ImmediateContinue', 'FailType_EndOfSong', and 'FailType_Off'
--
-- The conf-based OptionRow for "DefaultFailType" presents these^ as the following hardcoded English strings:
-- 'Immediate', 'ImmediateContinue', 'EndOfSong', and 'Off'
--
-- and whichever the machine operator chooses gets saved as a different hardcoded English string in
-- the DefaultModifiers Preference for the current game:
-- '', 'FailImmediateContinue', 'FailAtEnd', or 'FailOff'

-- It is worth pointing out that a default FailType of "FailType_Immediate" is saved to the DefaultModifiers
-- Preference as an empty string!
--
-- so this:
-- DefaultModifiers=FailOff, Overhead, Cel
-- would result in the engine applying FailType_Off to players when they join the game
--
-- while this:
-- DefaultModifiers=Overhead, Cel
-- would result in the engine applying FailType_Immediate to players when they join the game
--
-- Anyway, this is all convoluted enough that I wrote this global helper function to find the default
-- FailType setting in the current game's DefaultModifiers Preference and return it as an enum value
-- the PlayerOptions interface can accept.
--
-- Keeping track of the logical flow of which preference overrides which metrics
-- and attempting to extrapolate how that will play out over time in a community
-- where players expect to be able to modify the code that drives gameplay is so
-- convoluted that it seems unreasonable to expect any player to follow along.
--
-- I can barely follow along.
--
-- I'm pretty sure ZP Theart was wailing about such project bitrot in Lost Souls in Endless Time.

GetDefaultFailType = function()
	local default_mods = tostring(safe_preference("DefaultModifiers", "") or "")

	local default_fail = ""
	local fail_strings = {}

	-- -------------------------------------------------------------------
	-- these mappings just recreate the if/else chain in PlayerOptions.cpp
	fail_strings.failarcade            = "FailType_Immediate"
	fail_strings.failimmediate         = "FailType_Immediate"
	fail_strings.failendofsong         = "FailType_ImmediateContinue"
	fail_strings.failimmediatecontinue = "FailType_ImmediateContinue"
	fail_strings.failatend             = "FailType_EndOfSong"
	fail_strings.failoff               = "FailType_Off"

	-- handle the "faildefault" string differently than the SM5 engine
	-- PlayerOptions.cpp will lookup GAMESTATE's DefaultPlayerOptions
	-- which applies, in sequence:
	--    DefaultModifiers from Preferences.ini
	--    DefaultModifers from [Common] in metrics.ini
	--    DefaultNoteSkinName from [Common] in metrics.ini
	--
	-- SM5.1's _fallback theme does not currently specify any FailType
	-- in DefaultModifiers under [Common] in its metrics.ini
	--
	-- This suggests that if a non-standard failstring (like "FailASDF")
	-- is found, the _fallback theme won't enforce anything, but the engine
	-- will enforce FailType_Immediate.  Brief testing seems to align with this
	-- theory, but I haven't dug through enough of the src to *know*.
	--
	-- So, anyway, if Simply Love finds "faildefault" as a DefaultModifier in
	-- Simply Love UserPrefs.ini, I'll go with "FailType_ImmediateContinue.
	-- ImmediateContinue will be Simply Love's default.
	fail_strings.faildefault           = "FailType_ImmediateContinue"
	-- -------------------------------------------------------------------

	for mod in string.gmatch(default_mods, "%w+") do
		if mod:lower():find("fail") then
			-- we found something matches "fail", so set our default_fail variable
			-- and keep looking; don't break from the loop immediately.
			-- I don't know if it's possible to have multiple FailType
			-- strings saved in a single DefaultModifiers string...
			default_fail = mod:lower()
		end
	end

	-- return the appropriate Enum string or "FailType_Immediate" if nothing was parsed out of DefaultModifiers
	return fail_strings[default_fail] or "FailType_Immediate"
end

-- -----------------------------------------------------------------------

SetGameModePreferences = function()
	local gameMode = SL and SL.Global and SL.Global.GameMode or "ITG"
	local preferences = SL and SL.Preferences and SL.Preferences[gameMode] or nil
	if type(preferences) ~= "table" then
		sl_helpers_trace("SetGameModePreferences skipped missing preferences for " .. tostring(gameMode))
		return false
	end

	-- apply the preferences associated with this SL GameMode (Casual, ITG)
	for key,val in pairs(preferences) do
		if PREFSMAN and type(PREFSMAN.SetPreference) == "function" then
			safe_call("PREFSMAN.SetPreference " .. tostring(key), function()
				PREFSMAN:SetPreference(key, val)
			end)
		end
	end

	--------------------------------------------
	-- loop through human players and apply whatever mods need to be set now
	for player in ivalues(safe_human_players()) do
		local mods, pn = safe_player_mods(player)
		-- If we're switching to Casual mode,
		-- we want to reduce the number of judgments,
		-- so turn Decents and WayOffs off now.
		if gameMode == "Casual" and pn and SL and SL[pn] then
			SL[pn].ActiveModifiers = mods
			SL[pn].ActiveModifiers.TimingWindows = {true,true,true,false,false}
		end

		-- Now that we've set the SL table for TimingWindows appropriately,
		-- use it to apply TimingWindows.
		if type(CustomOptionRow) == "function" then
			local okRow, TW_OptRow = safe_call("CustomOptionRow TimingWindows", function()
				return CustomOptionRow("TimingWindows")
			end)
			if okRow and TW_OptRow and type(TW_OptRow.LoadSelections) == "function" then
				safe_call("TimingWindows.LoadSelections", function()
					TW_OptRow:LoadSelections(TW_OptRow.Choices or {}, player)
				end)
			end
		end


		local player_modslevel = safe_player_options(player, "ModsLevel_Preferred")

		-- using PREFSMAN to set the preference for MinTNSToHideNotes apparently isn't
		-- enough when switching gamemodes because MinTNSToHideNotes is also a PlayerOption.
		-- so, set the PlayerOption version of it now, too, to ensure that arrows disappear
		-- at the appropriate judgments during gameplay for this gamemode.
		if player_modslevel and type(player_modslevel.MinTNSToHideNotes) == "function" then
			safe_call("PlayerOptions.MinTNSToHideNotes", function()
				player_modslevel:MinTNSToHideNotes(preferences.MinTNSToHideNotes)
			end)
		end

		-- FailSetting is also a modifier that can be set per-player per-stage in SM5, but I'm
		-- opting to enforce it in Simply Love using what the machine operator sets
		-- as the default FailType in Advanced Options in the operator menu
		if player_modslevel and type(player_modslevel.FailSetting) == "function" then
			safe_call("PlayerOptions.FailSetting", function()
				player_modslevel:FailSetting( GetDefaultFailType() )
			end)
		end
	end

	--------------------------------------------
	-- finally, load the Stats.xml file appropriate for this SL GameMode

	-- these are the prefixes that are prepended to each custom Stats.xml, resulting in
	-- Stats.xml, ECFA-Stats.xml, Casual-Stats.xml
	local prefix = {}

	-- ITG has no prefix and scores go directly into the main Stats.xml
	-- this was probably a Bad Decision™ on my part in hindsight  -quietly
	prefix["ITG"] = ""

	prefix["Casual"] = "Casual-"

	if PROFILEMAN and type(PROFILEMAN.GetStatsPrefix) == "function" and type(PROFILEMAN.SetStatsPrefix) == "function" then
		local targetPrefix = prefix[gameMode] or ""
		local currentPrefix = safe_method("PROFILEMAN.GetStatsPrefix", PROFILEMAN, "GetStatsPrefix")
		if currentPrefix ~= targetPrefix then
			safe_call("PROFILEMAN.SetStatsPrefix", function()
				PROFILEMAN:SetStatsPrefix(targetPrefix)
			end)
		end
	end
	return true
end

-- -----------------------------------------------------------------------
-- Call ResetPreferencesToStockSM5() to reset all the Preferences that SL silently
-- manages for you back to their stock SM5 values.
--
-- These "managed" Preferences are listed in ./Scripts/SL_Init.lua
-- per-gamemode (Casual, ITG), and actively applied (and reapplied)
-- for each new game using SetGameModePreferences()
--
-- SL normally calls ResetPreferencesToStockSM5() from
-- ./BGAnimations/ScreenPromptToResetPreferencesToStock overlay.lua
-- but people have requested that the functionality for resetting Preferences be
-- generally accessible (for example, switching themes via a pad code).
-- Thus, this global function.

ResetPreferencesToStockSM5 = function()
	local gameMode = SL and SL.Global and SL.Global.GameMode or "ITG"
	local preferences = SL and SL.Preferences and SL.Preferences[gameMode] or nil
	if type(preferences) ~= "table" then
		sl_helpers_trace("ResetPreferencesToStockSM5 skipped missing preferences for " .. tostring(gameMode))
		return false
	end
	-- loop through all the Preferences that SL forcibly manages and reset them
	for key, value in pairs(preferences) do
		if PREFSMAN and type(PREFSMAN.SetPreferenceToDefault) == "function" then
			safe_call("PREFSMAN.SetPreferenceToDefault " .. tostring(key), function()
				PREFSMAN:SetPreferenceToDefault(key)
			end)
		end
	end
	-- now that those Preferences are reset to default values, write Preferences.ini to disk now
	if PREFSMAN and type(PREFSMAN.SavePreferences) == "function" then
		return safe_call("PREFSMAN.SavePreferences", function()
			PREFSMAN:SavePreferences()
		end)
	end
	return false
end

-- -----------------------------------------------------------------------
-- given a player, return a table of stepartist text for the current song or trail
-- so that various screens (SSM, Eval) can cycle through these values and players
-- can see each for brief duration

GetStepsCredit = function(player)
	local t = {}

	if safe_is_course_mode() then
		local trail = safe_game_state_method("GetCurrentTrail", nil, player)
		local entries = safe_method("Trail.GetTrailEntries", trail, "GetTrailEntries")
		if type(entries) ~= "table" then return t end

		for i, entry in ipairs(entries) do
			local steps = safe_method("TrailEntry.GetSteps", entry, "GetSteps")
			if steps then
			-- prefer steps Description; this is where stepartists seem to put chart info
				local description = tostring(safe_method("Steps.GetDescription", steps, "GetDescription") or "")
				local author = tostring(safe_method("Steps.GetAuthorCredit", steps, "GetAuthorCredit") or "")
				if description ~= "" then
					t[i] = description

			-- if no description was available, use AuthorCredit instead
				elseif author ~= "" then
					t[i] = author
				end
			end
		end
		else
			local steps = safe_game_state_method("GetCurrentSteps", nil, player)
			if not steps then return t end

			local rawStepsType = safe_method("Steps.GetStepsType", steps, "GetStepsType")
			local stepsType = tostring(safe_enum_short(rawStepsType, "")):gsub("_", "-"):lower()
			if stepsType == "dance-couple" then
				t[#t+1] = player == PLAYER_2 and "Stats techniques joueur 2" or "Stats techniques joueur 1"
				return t
			elseif stepsType == "dance-routine" then
				t[#t+1] = "Stats techniques joueur 1 et 2"
				return t
			end

			-- credit
			local author = tostring(safe_method("Steps.GetAuthorCredit", steps, "GetAuthorCredit") or "")
			if author ~= "" then t[#t+1] = author end
		-- description
		local description = tostring(safe_method("Steps.GetDescription", steps, "GetDescription") or "")
		if description ~= "" then t[#t+1] = description end
		-- chart name
		local chartName = tostring(safe_method("Steps.GetChartName", steps, "GetChartName") or "")
		if chartName ~= "" then t[#t+1] = chartName end
	end

	return t
end

-- -----------------------------------------------------------------------
-- the best way to spread holiday cheer is singing loud for all to hear

HolidayCheer = function()
	local month = type(MonthOfYear) == "function" and MonthOfYear() or -1
	return (safe_preference("EasterEggs", false) == true and month == 11)
end

DarkUI = function()
	-- During the process of switching games, THEME:GetCurThemeName() will temporarily return "_fallback"
	-- which will cause the ThemePrefs system to throw errors when a "RainbowMode" key isn't found
	-- because a [_fallback] section doesn't exist.  This should really be fixed in the _fallback theme,
	-- but we can prevent Lua errors from being thrown in the meantime.
	if not (THEME and type(THEME.GetCurThemeName) == "function") then return false end
	local curTheme = safe_method("THEME.GetCurThemeName", THEME, "GetCurThemeName")
	if curTheme ~= safe_preference("Theme", curTheme) then return false end

	if safe_theme_pref("RainbowMode", false) == true then return true end
	if HolidayCheer() then return true end
	return false
end

-- -----------------------------------------------------------------------
-- "The chills, I have them down my spine."
IsSpooky = function()
	local month = type(MonthOfYear) == "function" and MonthOfYear() or -1
	return (safe_preference("EasterEggs", false) == true and month == 9 and safe_theme_pref("VisualStyle", "")=="Spooky")
end

-- -----------------------------------------------------------------------
-- functions that handle custom judgment graphic detection/loading

-- look for the "[frames wide] x [frames tall]" and some sort of all-letters file extension
-- return true if both are found in the filename
-- (note: Lua doesn't natively support an end-of-string regex marker.)
local FilenameIsMultiFrameSprite = function(filename)
	if type(filename) ~= "string" then return false end
	return filename:match(" %d+x%d+") and filename:match("%.[A-Za-z]+$")
end

-- remove "[frames wide] x [frames tall]"
-- remove "(doublres)"
-- remove ".png"
StripSpriteHints = function(filename)
	-- handle common cases here, gory details in /src/RageBitmapTexture.cpp
	return tostring(filename or ""):gsub(" %d+x%d+", ""):gsub(" %(doubleres%)", ""):gsub("%.[Pp][Nn][Gg]$", "")
end

GetJudgmentGraphics = function()
	local path = ""
	if THEME and type(THEME.GetPathG) == "function" then
		local okPath, value = safe_call("THEME.GetPathG _judgments", function()
			return THEME:GetPathG('', '_judgments')
		end)
		path = okPath and tostring(value or "") or ""
	end
	local files = safe_dir_listing(path .. '/')
	local judgment_graphics = {}

	for i,filename in ipairs(files) do

		-- Filter out files that aren't judgment graphics
		-- e.g. hidden system files like .DS_Store
		if FilenameIsMultiFrameSprite(filename) then

			-- remove the file extension from the string, leaving only the name of the graphic
			local name = StripSpriteHints(filename)

			-- Fill the table, special-casing Love so that it comes first.
			if name == "Love" then
				table.insert(judgment_graphics, 1, filename)
			else
				judgment_graphics[#judgment_graphics+1] = filename
			end
		end
	end

	-- "None" results in Player judgment.lua returning an empty Def.Actor
	judgment_graphics[#judgment_graphics+1] = "None"

	return judgment_graphics
end

GetHoldJudgments = function()
	local themeDir = safe_method("THEME.GetCurrentThemeDirectory", THEME, "GetCurrentThemeDirectory") or ""
	local path = tostring(themeDir).."Graphics/_HoldJudgments/"
	local files = safe_dir_listing(path)
	local hold_graphics = {}

	for i,filename in ipairs(files) do

		-- Filter out files that aren't HoldJudgment labels
		-- e.g. hidden system files like .DS_Store
		if FilenameIsMultiFrameSprite(filename) then
			table.insert(hold_graphics, filename)
		end
	end

	if #hold_graphics == 0 then
		hold_graphics[#hold_graphics+1] = "None 1x2.png"
	end
	return hold_graphics
end


-- -----------------------------------------------------------------------
-- GetComboFonts returns a table of strings that match valid ComboFonts for use in Gameplay
--
-- a valid ComboFont must:
--   • have its assets in a unique directory at ./Fonts/_Combo Fonts/
--   • include the usual files needed for a StepMania BitmapText actor (a png and an ini)
--   • have its png and ini file both be named to match the directory they are in
--
-- a valid ComboFont should:
--   • include glyphs for 1234567890()/.-%
--   • be open source or "100% free" on dafont.com

GetComboFonts = function()
	local themeDir = safe_method("THEME.GetCurrentThemeDirectory", THEME, "GetCurrentThemeDirectory") or ""
	local path = tostring(themeDir).."Fonts/_Combo Fonts/"
	local dirs = safe_dir_listing(path, true, false)
	local fonts = {}
	local has_wendy_cursed = false

	for directory_name in ivalues(dirs) do
		local files = safe_dir_listing(path..tostring(directory_name).."/")
		local has_png, has_ini = false, false

		for filename in ivalues(files) do
			if FilenameIsMultiFrameSprite(filename) and StripSpriteHints(filename)==directory_name then has_png = true end
			if type(filename) == "string" and filename:match("%.[Ii][Nn][Ii]$") and filename:gsub("%.[Ii][Nn][Ii]$","")==directory_name then has_ini = true end
		end

		if has_png and has_ini then
			-- special-case Wendy to always appear first in the list
			if directory_name == "Wendy" then
				table.insert(fonts, 1, directory_name)

			-- special-case Wendy (Cursed) to always appear last in the last
			elseif directory_name == "Wendy (Cursed)" then
				has_wendy_cursed = true
			else
				table.insert(fonts, directory_name)
			end
		end
	end

	if has_wendy_cursed then table.insert(fonts, "Wendy (Cursed)") end
	if #fonts == 0 then fonts[#fonts+1] = "Wendy" end

	return fonts
end


-- -----------------------------------------------------------------------
IsHumanPlayer = function(player)
	local playerState = safe_player_state(player)
	return safe_method("PlayerState.GetPlayerController", playerState, "GetPlayerController") == "PlayerController_Human"
end

-- -----------------------------------------------------------------------
IsAutoplay = function(player)
	local playerState = safe_player_state(player)
	return safe_method("PlayerState.GetPlayerController", playerState, "GetPlayerController") == "PlayerController_Autoplay"
end

-- -----------------------------------------------------------------------
-- Helper function to determine if a TNS falls within the W0 window.
-- Params are the params received from the JudgmentMessageCommand.
-- Returns true/false
IsW0Judgment = function(params, player)
	if type(params) ~= "table" then return false end
	if params.Player ~= player then return false end
	if params.HoldNoteScore then return false end

	-- Only check/update FA+ count if we received a TNS in the top window.
	if params.TapNoteScore == "TapNoteScore_W1" and SL and SL.Global and SL.Global.GameMode == "ITG" then
		local prefs = SL and SL.Preferences and SL.Preferences["FA+"] or {}
		local scale = positive_number_or(safe_preference_number("TimingWindowScale", 1), 1)
		local W0 = math.max(0, finite_number_or(prefs["TimingWindowSecondsW1"], 0) * scale + finite_number_or(prefs["TimingWindowAdd"], 0))

		local offset = math.abs(finite_number_or(params.TapNoteOffset, math.huge))
		if offset <= W0 then
			return true
		end
	end
	return false
end

-- -----------------------------------------------------------------------
-- ArrowCloud HardEX splits the top ITG Fantastic window again at +/-10ms.
-- This is display/scoring interpretation only; it does not change the
-- engine's immutable raw judgment result.
IsW010Judgment = function(params, player)
	if type(params) ~= "table" then return false end
	if params.Player ~= player then return false end
	if params.HoldNoteScore then return false end
	if params.TapNoteScore ~= "TapNoteScore_W1" then return false end
	if not (SL and SL.Global and SL.Global.GameMode == "ITG") then return false end

	return math.abs(finite_number_or(params.TapNoteOffset, math.huge)) <= GetTimingWindow(1, "FA+", true)
end

-- -----------------------------------------------------------------------
-- Gets the fully populated judgment counts for a player.
-- This includes the FA+ window (W0). Decents/WayOffs (W4/W5) will only exist in the
-- resultant table if the windows were active.
--
-- Should NOT be used in casual mode.
--
-- Returns a table with the following keys:
-- {
--             "W0" -> the fantasticPlus count
--             "W1" -> the fantastic count
--             "W2" -> the excellent count
--             "W3" -> the great count
--             "W4" -> the decent count (may not exist if window is disabled)
--             "W5" -> the way off count (may not exist if window is disabled)
--           "Miss" -> the miss count
--     "totalSteps" -> the total number of steps in the chart (including hold heads)
--          "Holds" -> total number of holds held
--     "totalHolds" -> total number of holds in the chart
--          "Mines" -> total number of mines hit
--     "totalMines" -> total number of mines in the chart
--          "Rolls" -> total number of rolls held
--     "totalRolls" -> total number of rolls in the chart
-- }
--
-- Note: The returned table can't be used directly into CalculateExScore because the keys
-- "HitMine", "Held", and "LetGo" aren't calculated here.
GetExJudgmentCounts = function(player)
	local sourcePlayer = GetRoutineSourcePlayer and GetRoutineSourcePlayer(player) or player
	local pn = safe_enum_short(sourcePlayer, nil)
	local curStageStats = safe_method("STATSMAN.GetCurStageStats", STATSMAN, "GetCurStageStats")
	local stats = GetEvaluationPlayerStageStats and GetEvaluationPlayerStageStats(player) or nil
	stats = stats or (pn and safe_method("StageStats.GetPlayerStageStats", curStageStats, "GetPlayerStageStats", pn) or nil)
	local StepsOrTrail = (safe_is_course_mode() and safe_game_state_method("GetCurrentTrail", nil, sourcePlayer)) or safe_game_state_method("GetCurrentSteps", nil, sourcePlayer)

	local counts = {}

	local TNS = { "W1", "W2", "W3", "W4", "W5", "Miss" }

	if SL and SL.Global and SL.Global.GameMode == "ITG" then
		for window in ivalues(TNS) do
			-- Get the count.
			local number = safe_stats_tap_score(stats, "TapNoteScore_"..window)
			-- We need to extract the W0 count in ITG mode.
			if window == "W1" then
				local playerState = pn and SL and SL[pn] or nil
				local stageStats = playerState and playerState.Stages and playerState.Stages.Stats and playerState.Stages.Stats[safe_stage_index()]
				local exCounts = stageStats and stageStats.ex_counts or {}
				local faPlus = math.max(0, finite_number_or(exCounts.W0_total, 0))
				local faPlus10 = math.max(0, finite_number_or(exCounts.W010_total, 0))
				-- Subtract FA+ count from the overall fantastic window count.
				number = math.max(0, number - faPlus)
				-- Populate the split top-window numbers.
				counts["W0"] = faPlus
				counts["W1"] = number
				counts["W010"] = faPlus10
				counts["W110"] = math.max(0, safe_stats_tap_score(stats, "TapNoteScore_W1") - faPlus10)
			else
				local mods = safe_player_mods(sourcePlayer)
				local timingWindows = type(mods.TimingWindows) == "table" and mods.TimingWindows or {}
				if ((window ~= "W4" and window ~= "W5") or
						-- Only populate decent and way off windows if they're active.
						(window == "W4" and timingWindows[4]) or
						(window == "W5" and timingWindows[5])) then
					counts[window] = number
				end
			end
		end
	end
	counts["totalSteps"] = safe_radar_value(StepsOrTrail, sourcePlayer, "RadarCategory_TapsAndHolds")

	local RadarCategory = { "Holds", "Mines", "Rolls" }

	local po = safe_player_options(sourcePlayer, "ModsLevel_Preferred")

	for RCType in ivalues(RadarCategory) do
		local radarActual = safe_method("PlayerStageStats.GetRadarActual", stats, "GetRadarActual")
		local number = math.max(0, finite_number_or(safe_method("RadarValues.GetValue", radarActual, "GetValue", "RadarCategory_"..RCType), 0))
		local possible = safe_radar_value(StepsOrTrail, sourcePlayer, "RadarCategory_"..RCType)

		if RCType == "Mines" then
			-- NoMines still report the total number of mines that exist in a chart, even if they weren't played in the chart.
			-- If NoMines was set, report 0 for the number of mines as the chart actually didn't have any.
			-- TODO(teejusb): Track AvoidMine in the future. This is fine for now as ITL compares serverside.
			if option_enabled(safe_method("PlayerOptions.NoMines", po, "NoMines")) then
				counts[RCType] = 0
				counts["total"..RCType] = 0
			else
				-- We want to keep track of mines hit.
				counts[RCType] = math.max(0, possible - number)
				counts["total"..RCType] = possible
			end
		else
			counts[RCType] = number
			counts["total"..RCType] = possible
		end
	end

	return counts
end

-- -----------------------------------------------------------------------
-- Calculate the EX score given for a given player.
--
-- The ex_counts default to those computed in BGAnimations/ScreenGameplay underlay/TrackExScoreJudgments.lua
-- They are computed from the HoldNoteScore and TapNotScore from the JudgmentMessageCommands.
-- We look for the following keys:
-- {
--             "W0" -> the fantasticPlus count
--             "W1" -> the fantastic count
--             "W2" -> the excellent count
--             "W3" -> the great count
--             "W4" -> the decent count
--             "W5" -> the way off count
--           "Miss" -> the miss count
--           "Held" -> the number of holds/rolds held
--          "LetGo" -> the number of holds/rolds dropped
--        "HitMine" -> total number of mines hit
-- }
--
-- The W0 weight may have been modified for Tournament mode purposes.
-- Use the optional boolean argument use_actual_w0_weight to choose to fallback to the proper W0 weight.
CalculateExScore = function(player, ex_counts, use_actual_w0_weight)
	-- No EX scores in Casual mode, just return some dummy number early.
	if SL and SL.Global and SL.Global.GameMode == "Casual" then return 0 end
	local sourcePlayer = GetRoutineSourcePlayer and GetRoutineSourcePlayer(player) or player
	local StepsOrTrail = (safe_is_course_mode() and safe_game_state_method("GetCurrentTrail", nil, sourcePlayer)) or safe_game_state_method("GetCurrentSteps", nil, sourcePlayer)

	local totalSteps, totalHolds, totalRolls, possibleSource = safe_score_possible_values(StepsOrTrail, sourcePlayer)

	local weights = type(SL and SL.ExWeights) == "table" and SL.ExWeights or {}
	local W0Weight = use_actual_w0_weight and 3.5 or finite_number_or(weights["W0"], 0)
	local heldWeight = finite_number_or(weights["Held"], 0)
	local total_possible = totalSteps * W0Weight + (totalHolds + totalRolls) * heldWeight
	trace_score_possible("ex", player, possibleSource, totalSteps, totalHolds, totalRolls, W0Weight, heldWeight, total_possible)

	local total_points = 0

	local po = safe_player_options(sourcePlayer, "ModsLevel_Preferred")

	-- If mines are disabled, they should still be accounted for in EX Scoring based on the weight assigned to it.
	-- Stamina community does often play with no-mines on, but because EX scoring is more timing centric where mines
	-- generally have a negative weight, it's a better experience to make sure the EX score reflects that.
	if option_enabled(safe_method("PlayerOptions.NoMines", po, "NoMines")) then
		local totalMines = safe_radar_value(StepsOrTrail, sourcePlayer, "RadarCategory_Mines")
		total_points = total_points + totalMines * finite_number_or(weights["HitMine"], 0)
	end

	local keys = { "W0", "W1", "W2", "W3", "W4", "W5", "Miss", "Held", "LetGo", "HitMine" }
	local playerKey = safe_enum_short(sourcePlayer, nil)
	local playerState = playerKey and SL and SL[playerKey] or nil
	local stages = playerState and playerState.Stages
	local stats = stages and stages.Stats
	local stageStats = stats and stats[safe_stage_index()]
	local sourceCounts = ex_counts or (stageStats and stageStats.ex_counts)
	-- Just for validation, but shouldn't happen in normal gameplay.
	if type(sourceCounts) ~= "table" then return 0, 0, total_possible end

	local counts = {}
	for key,value in pairs(sourceCounts) do
		counts[key] = value
	end
	counts["Held"] = counts["Held"] or (finite_number_or(counts["Holds"], 0) + finite_number_or(counts["Rolls"], 0))
	counts["HitMine"] = counts["HitMine"] or counts["Mines"] or 0

	local exCountSteps = math.max(0, finite_number_or(counts.totalSteps, 0))
	if safe_is_course_mode() and exCountSteps > 0 then
		totalSteps = exCountSteps
		totalHolds = math.max(0, finite_number_or(counts.totalHolds, 0))
		totalRolls = math.max(0, finite_number_or(counts.totalRolls, 0))
		total_possible = totalSteps * W0Weight + (totalHolds + totalRolls) * heldWeight
		trace_score_possible("ex_counts", player, "ex_counts", totalSteps, totalHolds, totalRolls, W0Weight, heldWeight, total_possible)
	elseif total_possible <= 0 then
		totalSteps = exCountSteps
		totalHolds = math.max(0, finite_number_or(counts.totalHolds, 0))
		totalRolls = math.max(0, finite_number_or(counts.totalRolls, 0))
		total_possible = totalSteps * W0Weight + (totalHolds + totalRolls) * heldWeight
		trace_score_possible("ex_counts", player, "ex_counts", totalSteps, totalHolds, totalRolls, W0Weight, heldWeight, total_possible)
		if total_possible <= 0 then return 0, 0, 0 end
	end

	for key in ivalues(keys) do
		local value = finite_number_or(counts[key], nil)
		local weight = finite_number_or(weights[key], nil)
		if value ~= nil and weight ~= nil then
			total_points = total_points + value * weight
		end
	end

	return math.max(0, math.floor(total_points/total_possible * 10000) / 100), total_points, total_possible
end

-- -----------------------------------------------------------------------
-- Calculate ArrowCloud HardEX score. HardEX uses a +/-10ms inner Fantastic
-- split and stricter weights:
-- 10ms=3.5, white Fantastic=3, Excellent=1, Great=0. Decents,
-- WayOffs, misses, dropped holds, and mines are subtractive so the live
-- score can move down when bad judgments occur.
CalculateHardExScore = function(player, ex_counts, use_actual_w0_weight)
	if SL and SL.Global and SL.Global.GameMode == "Casual" then return 0 end
	local sourcePlayer = GetRoutineSourcePlayer and GetRoutineSourcePlayer(player) or player
	local StepsOrTrail = (safe_is_course_mode() and safe_game_state_method("GetCurrentTrail", nil, sourcePlayer)) or safe_game_state_method("GetCurrentSteps", nil, sourcePlayer)

	local totalSteps, totalHolds, totalRolls, possibleSource = safe_score_possible_values(StepsOrTrail, sourcePlayer)
	local weights = type(SL and SL.HardExWeights) == "table" and SL.HardExWeights or {}
	local W010Weight = finite_number_or(weights["W010"], 0)
	local heldWeight = finite_number_or(weights["Held"], 0)
	local total_possible = totalSteps * W010Weight + (totalHolds + totalRolls) * heldWeight
	trace_score_possible("hardex", player, possibleSource, totalSteps, totalHolds, totalRolls, W010Weight, heldWeight, total_possible)

	local total_points = 0
	local po = safe_player_options(sourcePlayer, "ModsLevel_Preferred")
	if option_enabled(safe_method("PlayerOptions.NoMines", po, "NoMines")) then
		local totalMines = safe_radar_value(StepsOrTrail, sourcePlayer, "RadarCategory_Mines")
		total_points = total_points + totalMines * finite_number_or(weights["HitMine"], 0)
	end

	local keys = { "W010", "W110", "W2", "W3", "W4", "W5", "Miss", "Held", "LetGo", "HitMine" }
	local playerKey = safe_enum_short(sourcePlayer, nil)
	local playerState = playerKey and SL and SL[playerKey] or nil
	local stages = playerState and playerState.Stages
	local stats = stages and stages.Stats
	local stageStats = stats and stats[safe_stage_index()]
	local sourceCounts = ex_counts or (stageStats and stageStats.ex_counts)
	if type(sourceCounts) ~= "table" then return 0, 0, total_possible end

	local counts = {}
	for key,value in pairs(sourceCounts) do
		counts[key] = value
	end
	counts["Held"] = counts["Held"] or (finite_number_or(counts["Holds"], 0) + finite_number_or(counts["Rolls"], 0))
	counts["HitMine"] = counts["HitMine"] or counts["Mines"] or 0

	local exCountSteps = math.max(0, finite_number_or(counts.totalSteps, 0))
	if safe_is_course_mode() and exCountSteps > 0 then
		totalSteps = exCountSteps
		totalHolds = math.max(0, finite_number_or(counts.totalHolds, 0))
		totalRolls = math.max(0, finite_number_or(counts.totalRolls, 0))
		total_possible = totalSteps * W010Weight + (totalHolds + totalRolls) * heldWeight
		trace_score_possible("hardex_counts", player, "ex_counts", totalSteps, totalHolds, totalRolls, W010Weight, heldWeight, total_possible)
	elseif total_possible <= 0 then
		totalSteps = exCountSteps
		totalHolds = math.max(0, finite_number_or(counts.totalHolds, 0))
		totalRolls = math.max(0, finite_number_or(counts.totalRolls, 0))
		total_possible = totalSteps * W010Weight + (totalHolds + totalRolls) * heldWeight
		trace_score_possible("hardex_counts", player, "ex_counts", totalSteps, totalHolds, totalRolls, W010Weight, heldWeight, total_possible)
		if total_possible <= 0 then return 0, 0, 0 end
	end

	for key in ivalues(keys) do
		local value = finite_number_or(counts[key], nil)
		local weight = finite_number_or(weights[key], nil)
		if value ~= nil and weight ~= nil then
			total_points = total_points + value * weight
		end
	end

	return math.max(0, math.floor(total_points / total_possible * 10000) / 100), total_points, total_possible
end

-- -----------------------------------------------------------------------
-- Generates the column mapping in case of any turn mods.
-- Returns a table containing the column swaps.
-- Returns nil if we can't compute it
GetColumnMapping = function(player)
	local po = safe_player_options(player, 'ModsLevel_Preferred')
	if not po then return nil end

	local shuffle = option_enabled(safe_method("PlayerOptions.Shuffle", po, "Shuffle"))
		or option_enabled(safe_method("PlayerOptions.SoftShuffle", po, "SoftShuffle"))
		or option_enabled(safe_method("PlayerOptions.SuperShuffle", po, "SuperShuffle"))
	local notes_inserted = (option_enabled(safe_method("PlayerOptions.Wide", po, "Wide"))
		or option_enabled(safe_method("PlayerOptions.Skippy", po, "Skippy"))
		or option_enabled(safe_method("PlayerOptions.Quick", po, "Quick"))
		or option_enabled(safe_method("PlayerOptions.Echo", po, "Echo"))
		or option_enabled(safe_method("PlayerOptions.BMRize", po, "BMRize"))
		or option_enabled(safe_method("PlayerOptions.Stomp", po, "Stomp"))
		or option_enabled(safe_method("PlayerOptions.Big", po, "Big")))
	local notes_removed = (option_enabled(safe_method("PlayerOptions.Little", po, "Little"))
		or option_enabled(safe_method("PlayerOptions.NoHolds", po, "NoHolds"))
		or option_enabled(safe_method("PlayerOptions.NoStretch", po, "NoStretch"))
		or option_enabled(safe_method("PlayerOptions.NoHands", po, "NoHands"))
		or option_enabled(safe_method("PlayerOptions.NoJumps", po, "NoJumps"))
		or option_enabled(safe_method("PlayerOptions.NoFakes", po, "NoFakes"))
		or option_enabled(safe_method("PlayerOptions.NoLifts", po, "NoLifts"))
		or option_enabled(safe_method("PlayerOptions.NoQuads", po, "NoQuads"))
		or option_enabled(safe_method("PlayerOptions.NoRolls", po, "NoRolls")))

	-- If shuffle is used or notes were inserted/removed, we can't compute it
	-- return early
	-- TODO(teejusb): Add support for Backwards()
	if shuffle or notes_inserted or notes_removed or option_enabled(safe_method("PlayerOptions.Backwards", po, "Backwards")) then
		return nil
	end

	local flip = finite_number_or(safe_method("PlayerOptions.Flip", po, "Flip"), 0) > 0
	local invert = finite_number_or(safe_method("PlayerOptions.Invert", po, "Invert"), 0) > 0
	local left = option_enabled(safe_method("PlayerOptions.Left", po, "Left"))
	local right = option_enabled(safe_method("PlayerOptions.Right", po, "Right"))
	local mirror = option_enabled(safe_method("PlayerOptions.Mirror", po, "Mirror"))
	local udmirror = option_enabled(safe_method("PlayerOptions.UDMirror", po, "UDMirror"))
	local lrmirror = option_enabled(safe_method("PlayerOptions.LRMirror", po, "LRMirror"))

	-- Combining flip and invert results in unusual spacing so ignore it.
	if flip and invert then
		return nil
	end

	local has_turn = flip or invert or left or right or mirror or udmirror or lrmirror
	local style = safe_current_style()
	local num_columns = math.max(0, math.floor(finite_number_or(safe_method("Style.ColumnsPerPlayer", style, "ColumnsPerPlayer"), 0)))
	if num_columns <= 0 then return nil end

	-- We only resolve turn mods in 4 and 8 panel.
	if num_columns ~= 4 and num_columns ~= 8 then
		if not has_turn then
			-- Not turn mod used, return 1-to-1 mapping.
				return type(range) == "function" and range(num_columns) or (function()
					local t = {}
					for i=1,num_columns do t[i] = i end
					return t
				end)()
		else
			-- If we are using turn mods in modes without 4 or 8 columns then return
			-- early since we don't try to resolve them.
			return nil
		end
	end

	local column_mapping = {1, 2, 3, 4}

	if flip then
		column_mapping = {column_mapping[4], column_mapping[3], column_mapping[2], column_mapping[1]}
	end

	if invert then
		column_mapping = {column_mapping[2], column_mapping[1], column_mapping[4], column_mapping[3]}
	end

	if left then
		column_mapping = {column_mapping[2], column_mapping[4], column_mapping[1], column_mapping[3]}
	end

	if right then
		column_mapping = {column_mapping[3], column_mapping[1], column_mapping[4], column_mapping[2]}
	end

	if mirror then
		column_mapping = {column_mapping[4], column_mapping[3], column_mapping[2], column_mapping[1]}
	end

	if udmirror then
		column_mapping = {column_mapping[1], column_mapping[3], column_mapping[2], column_mapping[4]}
	end

	if lrmirror then
		column_mapping = {column_mapping[4], column_mapping[2], column_mapping[3], column_mapping[1]}
	end

	if num_columns == 8 then
		for i=1,4 do
			column_mapping[4+i] = column_mapping[i] + 4
		end

		-- Flip, Mirror. and LRMirror all swap left and right sides.
		-- If an odd number of them are set then swap.
		local swapCount = 0
		if flip then swapCount = swapCount + 1 end
		if mirror then swapCount = swapCount + 1 end
		if lrmirror then swapCount = swapCount + 1 end

		if swapCount % 2 == 1 then
			for i=1,4 do
				column_mapping[i] = column_mapping[i] + 4
				column_mapping[i+4] = column_mapping[i+4] - 4
			end
		end
	end

	return column_mapping
end

-- -----------------------------------------------------------------------
-- IsGameAndMenuButton() is used to position GameButton labels in [ScreenMapControllers] in metrics.ini

-- list of GameButtons that serve double duty as menu buttons when OnlyDedicatedMenuButtons=0
local GameAndMenuButtons = {
	dance = { "Left", "Down", "Up", "Right" },
	pump  = { "DownLeft", "UpLeft", "Center", "UpRight", "DownRight" },
	techno= { "Left", "Down", "Up", "Right" },
	kb7   = { "Key2", "Key3", "Key5", "Key6" },
	para  = { "Left", "UpLeft", "Right", "UpRight" },
}

-- local table to serve as per-language lookup
-- e.g. LocalizedGameButtons.es.Arriba = "Up"
--      LocalizedGameButtons.en.Up = "Up"
local LocalizedGameButtons = {}

local DelocalizeGameButton = function(localized_btn)
	local game = safe_current_game_name()
	if not GameAndMenuButtons[game] then return false end

	-- if we haven't created a lookup table for the current language yet, do that now
	local language = tostring(safe_method("THEME.GetCurLanguage", THEME, "GetCurLanguage") or "")
	local cacheKey = language .. ":" .. game
	if not LocalizedGameButtons[cacheKey] then
		local t = {}
		for gb in ivalues(GameAndMenuButtons[game]) do
			t[safe_theme_string("GameButton", gb)] = gb
		end
		LocalizedGameButtons[cacheKey] = t
	end

	-- given a localized string like "Ariba" return a GameButton like "Up"
	return LocalizedGameButtons[cacheKey][localized_btn]
end

IsGameAndMenuButton = function(localized_btn)
	if safe_preference("OnlyDedicatedMenuButtons", false) == true then return false end

	local btn = DelocalizeGameButton(localized_btn)
	if not btn then return false end

	local buttons = GameAndMenuButtons[safe_current_game_name()]
	return type(FindInTable) == "function" and type(buttons) == "table" and FindInTable(btn, buttons) or false
end

-- -----------------------------------------------------------------------
-- Returns a stringified form of a player's selected options.
GetPlayerOptionsString = function(player, modsLevel)
	local modsLevel = modsLevel or "ModsLevel_Preferred"
	-- grab the song options from this PlayerState
	local PlayerOptions = safe_player_options_array(player, modsLevel)
	local mods, pn = safe_player_mods(player)

	local rendered = {}

	-- if the player used an XMod of 1x, it won't be in PlayerOptions list
	-- so check here, and add it in manually if necessary
	if mods.SpeedModType == "X" and finite_number_or(mods.SpeedMod, 0) == 1 then
		rendered[#rendered+1] = "1x"
	end

	--  ...and append options to that string as needed
	for i,option in ipairs(PlayerOptions) do
		option = tostring(option or "")

		-- these don't need to show up in the mods list
		if option ~= "FailAtEnd" and option ~= "FailImmediateContinue" and option ~= "FailImmediate" and 
			not string.find(option, "Lights") then
			-- 100% Mini will be in the PlayerOptions as just "Mini" so use the value from the SL table instead
			if option:match("Mini") then
				option = format_mini_option(option, mods)
			end

			if option:match("Cover") then
				option = safe_theme_string("OptionNames", "Cover")
			end

			rendered[#rendered+1] = option
		end
	end

	-- Display TimingWindowScale as a modifier if it's set to anything other than 1
	local TimingWindowScale = safe_preference_number("TimingWindowScale", 1)
	if TimingWindowScale ~= 1 then
		local label = "%g%% Timing"
		if type(ScreenString) == "function" then
			local okLabel, value = safe_call("ScreenString TimingWindowScale", function()
				return ScreenString("TimingWindowScale")
			end)
			label = okLabel and tostring(value or label) or label
		end
		rendered[#rendered+1] = tostring(label):format(TimingWindowScale*100)
	end

	local substitutions = {
		["SuperShuffle"] = "Blender",
		["HyperShuffle"] = "Random",
		["LRMirror"] = "LR-Mirror",
		["UDMirror"] = "UD-Mirror",
	}

	local optionslist = table.concat(rendered, ", ")
	for k,v in pairs(substitutions) do
		optionslist = optionslist:gsub(k, v)
	end

	return optionslist
end

-- -----------------------------------------------------------------------
-- helper function for returning the player AF
-- Works as expected in ScreenGameplay + Edit + Practice Mode
--     arguments:  pn is short string PlayerNumber like "P1" or "P2"
--     returns:    the "PlayerP1" or "PlayerP2" ActorFrame
GetPlayerAF = function(pn)
	local topscreen = safe_method("SCREENMAN.GetTopScreen", SCREENMAN, "GetTopScreen")
	if not topscreen then
		if lua and type(lua.ReportScriptError) == "function" then
			safe_call("lua.ReportScriptError GetPlayerAF", function()
				lua.ReportScriptError("GetPlayerAF() failed to find the player ActorFrame because there is no Screen yet.")
			end)
		end
		return nil
	end

	-- Get the player ActorFrame on ScreenGameplay
	-- It's a direct child of the screen and named "PlayerP1" for P1
	-- and "PlayerP2" for P2.
	-- This naming convention is hardcoded in the SM5 engine.
	--
	-- ScreenEdit does not name its player ActorFrame, but does set its alias to
	-- "PlayerP1" or "PlayerP2". GetChild will return the child if either the
	-- name or alias matches.
	return safe_method("Screen.GetChild PlayerAF", topscreen, "GetChild", "Player"..tostring(pn or ""))
end

-- -----------------------------------------------------------------------
-- If the banner is missing, use the VisualStyle fallback banner according to selected color.
GetFallbackBanner = function()
	local visualStyle = tostring(safe_theme_pref("VisualStyle", "Arrows") or "Arrows")
	-- Technique intentionally reuses the neutral Arrows fallback artwork; it
	-- does not ship a redundant set of twelve identical banner assets.
	local bannerStyle = visualStyle == "Technique" and "Arrows" or visualStyle
	local bannerIndex = math.max(1, math.floor(finite_number_or(SL and SL.Global and SL.Global.ActiveColorIndex, 1)))
	local bannerName = "banner" .. tostring(bannerIndex) .. " (doubleres).png"
	local function theme_graphic_path(relativePath)
		local themeDir = tostring(safe_method("THEME.GetCurrentThemeDirectory", THEME, "GetCurrentThemeDirectory") or "")
		if themeDir ~= "" and themeDir:sub(1, 1) ~= "/" then
			themeDir = "/" .. themeDir
		end
		return themeDir .. "Graphics/" .. relativePath
	end

	local function file_exists(path)
		if not path or path == "" then return false end
		if not (FILEMAN and type(FILEMAN.DoesFileExist) == "function") then return true end
		local ok, result = safe_call("FILEMAN.DoesFileExist fallback banner", function()
			return FILEMAN:DoesFileExist(path)
		end)
		return ok and result == true
	end

	local path = theme_graphic_path("_FallbackBanners/" .. bannerStyle .. "/" .. bannerName)
	if file_exists(path) then
		return path
	end

	local fallback = theme_graphic_path("_FallbackBanners/Arrows/" .. bannerName)
	if file_exists(fallback) then
		return fallback
	end

	-- Last resort: keep returning a theme-resolved path so the caller never
	-- receives a screen-relative "Themes/..." path that breaks LoadActor().
	if PREFSMAN and PREFSMAN:GetPreference("LogThemeLuaDiagnostics") then
		Trace(("Simply Love fallback banner unavailable VisualStyle=%s index=%d path=%s fallback=%s"):format(visualStyle, bannerIndex, path, fallback))
	end
	return fallback
end

-- -----------------------------------------------------------------------
-- cool functions for scatterplotting course mode

-- calculate each chart's actual length by GetLastSecond instead of song length
TotalCourseLength = function(player)
    local trail = safe_game_state_method("GetCurrentTrail", nil, player)
    local t = 0
    for te in ivalues(safe_method("Trail.GetTrailEntries", trail, "GetTrailEntries") or {}) do
		local song = safe_method("TrailEntry.GetSong", te, "GetSong")
        t = t + math.max(0, finite_number_or(safe_method("Song.GetLastSecond", song, "GetLastSecond"), 0))
    end

    return t / active_music_rate()
end

-- calculate amount of course played for properly scaling the scatterplot of judgments
TotalCourseLengthPlayed = function(player)
	local pn = safe_enum_short(player, nil)
	local trail = safe_game_state_method("GetCurrentTrail", nil, player)
	local playerState = pn and SL and SL[pn] or nil
	local storage = playerState and playerState.Stages and playerState.Stages.Stats and playerState.Stages.Stats[safe_stage_index()] or {}
	if storage.DeathSecond ~= nil then
		local deathSecond = finite_number_or(storage.DeathSecond, nil)
		if deathSecond == nil then return -1 end
		local t = 0
		for te in ivalues(safe_method("Trail.GetTrailEntries", trail, "GetTrailEntries") or {}) do
			local song = safe_method("TrailEntry.GetSong", te, "GetSong")
			t = t + ( math.max(0, finite_number_or(safe_method("Song.GetLastSecond", song, "GetLastSecond"), 0)) / active_music_rate() )
			if t > deathSecond then break end
		end
		return t
	else
		return -1
	end
end
