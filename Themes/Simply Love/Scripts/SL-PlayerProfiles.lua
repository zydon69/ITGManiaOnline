-- It's possible for players to edit their Simply Love UserPrefs.ini file
-- in various ways that might break the theme.  Also, sometimes theme-specific mods
-- are deprecated or change their internal name, leaving old values behind in player profiles
-- that might break the theme as well. Use this table to validate settings read in
-- from and written out to player profiles.
--
-- For now, this table is local to this file, but might be moved into the SL table (or something)
-- in the future to facilitate type checking in ./Scripts/SL-PlayerOptions.lua and elsewhere.

local permitted_profile_settings = {

	----------------------------------
	-- "Main Modifiers"
	-- OptionRows that appear in SL's first page of PlayerOptions

	SpeedModType     = "string",
	SpeedMod         = "number",
	Mini             = "string",
	NoteSkin         = "string",
	JudgmentGraphic  = "string",
	ComboFont        = "string",
	HoldJudgment     = "string",
	BackgroundFilter = "string",
	NoteFieldOffsetX = "number",
	NoteFieldOffsetY = "number",
	VisualDelay      = "string",

	----------------------------------
	-- "Advanced Modifiers"
	-- OptionRows that appear in SL's second page of PlayerOptions

	HideTargets          = "boolean",
	HideSongBG           = "boolean",
	HideCombo            = "boolean",
	HideLifebar          = "boolean",
	HideScore            = "boolean",
	HideDanger           = "boolean",
	HideComboExplosions  = "boolean",

	LifeMeterType        = "string",
	DataVisualizations   = "string",
	TargetScore          = "number",
	ActionOnMissedTarget = "string",

	MeasureCounter       = "string",
	MeasureCounterLeft   = "boolean",
	MeasureCounterUp     = "boolean",
	HideLookahead        = "boolean",

	MeasureLines         = "string",
	ShowStreamBreakdown  = "boolean",

	-- Deprecated in Simply Love 5.9.0.  Keep readable so existing profiles can
	-- migrate to FlashMiss without losing the player's old behavior.
	ColumnFlashOnMiss    = "boolean",
	FlashMiss            = "boolean",
	FlashWayOff          = "boolean",
	FlashDecent          = "boolean",
	FlashGreat           = "boolean",
	FlashExcellent       = "boolean",
	FlashFantastic       = "boolean",
	SubtractiveScoring   = "boolean",
	Pacemaker            = "boolean",
	NPSGraphAtTop        = "boolean",
	JudgmentTilt         = "boolean",
	TiltMultiplier       = "number",
	ColumnCues           = "boolean",
	LifeMeterSwoosh      = "boolean",
	ShowNativeLifeMeter  = "boolean",
	DisplayScorebox      = "boolean",
	SBITGScore           = "boolean",
	SBExScore            = "boolean",
	SBEvents             = "boolean",

	ErrorBar             = "string",
	ErrorBarUp           = "boolean",
	ErrorBarMultiTick    = "boolean",
	ErrorBarTrim         = "string",

	ShowFaPlusWindow     = "boolean",
	ShowExScore          = "boolean",
	ShowHardEXScore      = "boolean",
	ShowAllScoreModes    = "boolean",
	MatchFantasticColor  = "boolean",
	ShowFaPlusPane       = "boolean",
	SmallerWhite         = "boolean",
	RememberOnlineToken  = "boolean",

	HideEarlyDecentWayOffJudgments = "boolean",
	HideEarlyDecentWayOffFlash     = "boolean",

	----------------------------------
	-- Profile Settings without OptionRows
	-- these settings are saved per-profile, but are transparently managed by the theme
	-- they have no player-facing OptionRows

	PlayerOptionsString = "string",
}

-- -----------------------------------------------------------------------

local function profile_trace(message)
	local line = "SL-PlayerProfiles: " .. tostring(message or "")
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
		profile_trace("safe_call_failed context=" .. tostring(context or "unknown")
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

local function clamp_number(value, minimum, maximum, fallback)
	value = finite_number_or(value, fallback or minimum)
	if value < minimum then return minimum end
	if value > maximum then return maximum end
	return value
end

local function safe_enum_short(value, fallback)
	if type(ToEnumShortString) ~= "function" or value == nil then return fallback end
	local ok, result = safe_call("ToEnumShortString", function()
		return ToEnumShortString(value)
	end)
	return ok and result or fallback
end

local function profile_slot_for_player(player)
	return ({
		[PLAYER_1] = "ProfileSlot_Player1",
		[PLAYER_2] = "ProfileSlot_Player2"
	})[player]
end

local function safe_profile_dir(player)
	local slot = profile_slot_for_player(player)
	if not slot then return "" end
	return tostring(safe_method("PROFILEMAN.GetProfileDir", PROFILEMAN, "GetProfileDir", slot) or "")
end

local function safe_human_players()
	local players = safe_method("GAMESTATE.GetHumanPlayers", GAMESTATE, "GetHumanPlayers")
	return type(players) == "table" and players or {}
end

local function safe_player_state(player)
	return safe_method("GAMESTATE.GetPlayerState", GAMESTATE, "GetPlayerState", player)
end

local function safe_file_exists(path)
	if type(path) ~= "string" or path == "" then return false end
	return safe_method("FILEMAN.DoesFileExist", FILEMAN, "DoesFileExist", path) == true
end

local function safe_ini_read(path)
	if type(path) ~= "string" or path == "" or not IniFile or type(IniFile.ReadFile) ~= "function" then
		return {}
	end
	local ok, contents = safe_call("IniFile.ReadFile " .. path, function()
		return IniFile.ReadFile(path)
	end)
	return ok and type(contents) == "table" and contents or {}
end

local function safe_ini_write(path, contents)
	if type(path) ~= "string" or path == "" or type(contents) ~= "table" or not IniFile or type(IniFile.WriteFile) ~= "function" then
		return false
	end
	local ok = safe_call("IniFile.WriteFile " .. path, function()
		IniFile.WriteFile(path, contents)
	end)
	return ok == true
end

local function theme_display_name()
	return tostring(safe_method("THEME.GetThemeDisplayName", THEME, "GetThemeDisplayName") or "Simply Love")
end

local function user_prefs_filename()
	return theme_display_name() .. " UserPrefs.ini"
end

local numeric_profile_bounds = {
	SpeedMod = { minimum = 0, maximum = 9999, fallback = 1 },
	NoteFieldOffsetX = { minimum = 0, maximum = 50, fallback = 0 },
	NoteFieldOffsetY = { minimum = -50, maximum = 50, fallback = 0 },
	TargetScore = { minimum = 1, maximum = 19, fallback = 1 },
	TiltMultiplier = { minimum = 1, maximum = 3, fallback = 1 },
}

local function find_in_table(value, list)
	if type(list) ~= "table" then return nil end
	if type(FindInTable) == "function" then
		local ok, index = safe_call("FindInTable " .. tostring(value), function()
			return FindInTable(value, list)
		end)
		if ok then return index end
	end
	for i,item in ipairs(list) do
		if item == value then return i end
	end
	return nil
end

local function option_row_for_key(key)
	if type(CustomOptionRow) ~= "function" then return nil end
	local ok, row = safe_call("CustomOptionRow " .. tostring(key), function()
		return CustomOptionRow(key)
	end)
	return ok and type(row) == "table" and row or nil
end

local function sanitize_profile_string(key, value)
	value = tostring(value or ""):gsub("[\r\n]", "")
	if #value > 4096 then
		value = value:sub(1, 4096)
	end
	if key == "PlayerOptionsString" then return value end

	local row = option_row_for_key(key)
	if not row then return nil end
	local values = type(row.Values) == "table" and row.Values or nil
	local choices = type(row.Choices) == "table" and row.Choices or nil
	if find_in_table(value, values) or find_in_table(value, choices) then
		return value
	end
	return nil
end

local function sanitize_profile_value(key, value)
	local expected = permitted_profile_settings[key]
	if not expected or type(value) ~= expected then return nil end
	if expected == "number" then
		local bounds = numeric_profile_bounds[key]
		if bounds then
			return clamp_number(value, bounds.minimum, bounds.maximum, bounds.fallback)
		end
		return finite_number_or(value, nil)
	elseif expected == "string" then
		return sanitize_profile_string(key, value)
	end
	return value
end

local function sanitize_arrowcloud_token(value)
	if type(value) ~= "string" then return "" end
	value = value:gsub("^%s+", ""):gsub("%s+$", "")
	if value:find("[\r\n]") or #value > 2048 then return "" end
	return value
end

local function normalize_arrowcloud_allow_autoplay(value)
	return value == true or value == 1 or value == "1" or value == "true"
end

local function apply_hard_ex_exclusivity(pn)
	if pn and SL and SL[pn] and SL[pn].ActiveModifiers and SL[pn].ActiveModifiers.ShowHardEXScore then
		SL[pn].ActiveModifiers.ShowExScore = false
	end
end

local function theme_lua_diagnostics_enabled()
	if not (PREFSMAN and type(PREFSMAN.GetPreference) == "function") then return false end
	local ok, enabled = safe_call("PREFSMAN.GetPreference LogThemeLuaDiagnostics", function()
		return PREFSMAN:GetPreference("LogThemeLuaDiagnostics")
	end)
	return ok and enabled == true
end

local function judgment_flash_trace(message)
	if theme_lua_diagnostics_enabled() then
		profile_trace("SL_JUDGMENT_FLASH_TRACE " .. tostring(message or ""))
	end
end

local function migrate_deprecated_profile_modifiers(pn)
	local mods = pn and SL and SL[pn] and SL[pn].ActiveModifiers or nil
	if type(mods) ~= "table" then return end

	if mods.ColumnFlashOnMiss ~= nil then
		judgment_flash_trace(("profile_migration_begin pn=%s ColumnFlashOnMiss=%s FlashMissBefore=%s")
			:format(tostring(pn), tostring(mods.ColumnFlashOnMiss), tostring(mods.FlashMiss)))
	end
	if mods.ColumnFlashOnMiss == true and mods.FlashMiss ~= true then
		mods.FlashMiss = true
	end
	mods.ColumnFlashOnMiss = nil
	if mods.FlashMiss == true then
		judgment_flash_trace(("profile_migration_end pn=%s FlashMiss=%s")
			:format(tostring(pn), tostring(mods.FlashMiss)))
	end
end

local function restore_player_options_string(player, pn, value)
	if type(value) ~= "string" or value == "" then return false end
	local playerState = safe_player_state(player)
	if not playerState then return false end
	local okSet = safe_call("PlayerState.SetPlayerOptions", function()
		playerState:SetPlayerOptions("ModsLevel_Preferred", value)
	end)
	local playerOptions = safe_method("PlayerState.GetPlayerOptions", playerState, "GetPlayerOptions", "ModsLevel_Preferred")
	if playerOptions and type(playerOptions.ResetDisabledTimingWindows) == "function" then
		safe_call("PlayerOptions.ResetDisabledTimingWindows", function()
			playerOptions:ResetDisabledTimingWindows()
		end)
	end
	if playerOptions and type(playerOptions.FailSetting) == "function" then
		safe_call("PlayerOptions.FailSetting", function()
			playerOptions:FailSetting(GetDefaultFailType())
		end)
	end
	if pn and SL and SL[pn] then
		local optionsString = safe_method("PlayerState.GetPlayerOptionsString", playerState, "GetPlayerOptionsString", "ModsLevel_Preferred")
		SL[pn].PlayerOptionsString = tostring(optionsString or value)
	end
	return okSet == true
end


-- Function called when a [GUEST] joins during SSM, either by late joining or via the fast
-- profile switcher. It does two things:
-- 1) properly reset profile state (e.g. modifiers), and
-- 2) persist any state that should survive a profile switch (e.g., session history
--    in SL[pn].Stages with songs played for displaying on ScreenEvaluationSummary).
-- LoadProfileCustom takes care of this for persistent profiles.
LoadGuest = function(player)
	if not player then return false end
	safe_call("GAMESTATE.ResetPlayerOptions", function()
		GAMESTATE:ResetPlayerOptions(player)
	end)
	local pn = safe_enum_short(player, nil)
	if not (pn and SL and SL[pn] and type(SL[pn].initialize) == "function") then return false end
	local stages = SL[pn].Stages
	safe_call("SL player initialize guest", function()
		SL[pn]:initialize()
	end)
	SL[pn].Stages = stages
	migrate_deprecated_profile_modifiers(pn)
	migrate_deprecated_profile_modifiers(pn)
	apply_hard_ex_exclusivity(pn)
	return true
end


-- function assigned to "CustomLoadFunction" under [Profile] in metrics.ini
LoadProfileCustom = function(profile, dir)
	local theme_name = theme_display_name()
	local path =  tostring(dir or "") .. user_prefs_filename()
	local player, pn, filecontents

	-- we've been passed a profile object as the variable "profile"
	-- see if it matches against anything returned by PROFILEMAN:GetProfile(player)
	for p in ivalues(safe_human_players()) do
		if profile == safe_method("PROFILEMAN.GetProfile", PROFILEMAN, "GetProfile", p) then
			player = p
			pn = safe_enum_short(p, nil)
			break
		end
	end

	if pn then
		-- Remember and persist stats about songs played across profile switches
		local stages = SL and SL[pn] and SL[pn].Stages or nil

		if SL and SL[pn] and type(SL[pn].initialize) == "function" then
			safe_call("SL player initialize profile", function()
				SL[pn]:initialize()
			end)
			SL[pn].Stages = stages
		end

		safe_call("ParseGrooveStatsIni", function() ParseGrooveStatsIni(player) end)
		safe_call("ParseArrowCloudIni", function() ParseArrowCloudIni(player) end)
		safe_call("ReadItlFile", function() ReadItlFile(player) end)
	end

	if pn and safe_file_exists(path) then
		filecontents = safe_ini_read(path)[theme_name]

		-- for each key/value pair read in from the player's profile
		for k,v in pairs(type(filecontents) == "table" and filecontents or {}) do
			-- ensure that the key has a corresponding key in permitted_profile_settings
			local sanitized = sanitize_profile_value(k, v)
			if sanitized ~= nil then
				if k == "PlayerOptionsString" then
					restore_player_options_string(player, pn, sanitized)
				elseif SL and SL[pn] and SL[pn].ActiveModifiers then
					SL[pn].ActiveModifiers[k] = sanitized
				end
			end
		end
	end

	apply_hard_ex_exclusivity(pn)
	return true
end

-- function assigned to "CustomSaveFunction" under [Profile] in metrics.ini
SaveProfileCustom = function(profile, dir)

	local theme_name = theme_display_name()
	local path =  tostring(dir or "") .. user_prefs_filename()
	local ok = true
	local matched = false

	for player in ivalues(safe_human_players()) do
		if profile == safe_method("PROFILEMAN.GetProfile", PROFILEMAN, "GetProfile", player) then
			matched = true
			local pn = safe_enum_short(player, nil)
			local output = {}
			local modifiers = pn and SL and SL[pn] and SL[pn].ActiveModifiers or {}
			for k,v in pairs(type(modifiers) == "table" and modifiers or {}) do
				local sanitized = sanitize_profile_value(k, v)
				if sanitized ~= nil then
					output[k] = sanitized
				end
			end

			if output.ShowHardEXScore then
				output.ShowExScore = false
			end

			-- these values are saved outside the SL[pn].ActiveModifiers tables
			-- and thus won't be handled in the loop above
			local playerOptionsString = pn and SL and SL[pn] and SL[pn].PlayerOptionsString or nil
			if type(playerOptionsString) == "string" then
				output.PlayerOptionsString = sanitize_profile_value("PlayerOptionsString", playerOptionsString)
			end

			ok = safe_ini_write(path, {[theme_name]=output}) and ok

			local grooveOk, grooveResult = safe_call("WriteGrooveStatsIni", function() return WriteGrooveStatsIni(player) end)
			ok = grooveOk and grooveResult ~= false and ok
			local arrowOk, arrowResult = safe_call("WriteArrowCloudIni", function() return WriteArrowCloudIni(player) end)
			ok = arrowOk and arrowResult ~= false and ok
			-- Write to the ITL file if we need to.
			-- This is relevant for memory cards.
			local itlOk, itlResult = safe_call("WriteItlFile", function() return WriteItlFile(player) end)
			ok = itlOk and itlResult ~= false and ok
			break
		end
	end

	return matched and ok or false
end

-- -----------------------------------------------------------------------
-- returns a path to a profile avatar, or nil if none is found

GetAvatarPath = function(profileDirectory, displayName)

	if type(profileDirectory) ~= "string" then return end

	local path = nil

	-- sequence matters here
	-- prefer png first, then jpg, then jpeg, etc.
	-- (note that SM5 does not support animated gifs at this time, so SL doesn't either)
	-- TODO: investigate effects (memory footprint, fps) of allowing movie files as avatars in SL
	local extensions = { "png", "jpg", "jpeg", "bmp", "gif" }
	local avatarName = tostring(displayName or ""):gsub("[/\\:]", ""):gsub("^%s+", ""):gsub("%s+$", "")
	if avatarName == "" then avatarName = nil end

	-- prefer an avatar named:
	--    "avatar" in the player's profile directory (preferred by Simply Love)
	--    then "profile picture" in the player's profile directory (used by Digital Dance)
	--    then (whatever the profile's DisplayName is) in /Appearance/Avatars/ (used in OutFox?)
	local paths = {
		("%savatar"):format(profileDirectory),
		("%sprofile picture"):format(profileDirectory),
	}
	if avatarName then
		paths[#paths+1] = ("/Appearance/Avatars/%s"):format(avatarName)
	end

	for _, path in ipairs(paths) do
		for _, extension in ipairs(extensions) do
			local avatar_path = ("%s.%s"):format(path, extension)

			local okType, fileType = safe_call("ActorUtil.GetFileType", function()
				return ActorUtil and ActorUtil.GetFileType and ActorUtil.GetFileType(avatar_path)
			end)
			if safe_file_exists(avatar_path)
			and okType
			and fileType == "FileType_Bitmap"
			then
				-- return the first valid avatar path that is found
				return avatar_path
			end
		end
	end

	-- or, return nil if no avatars were found in any of the permitted paths
	return nil
end

-- -----------------------------------------------------------------------
-- returns a path to a player's profile avatar, or nil if none is found

GetPlayerAvatarPath = function(player)
	if not player then return end

	local profile_slot = {
		[PLAYER_1] = "ProfileSlot_Player1",
		[PLAYER_2] = "ProfileSlot_Player2"
	}

	if not profile_slot[player] then return end

	local dir  = safe_profile_dir(player)
	local profile = safe_method("PROFILEMAN.GetProfile", PROFILEMAN, "GetProfile", player)
	local name = safe_method("Profile.GetDisplayName", profile, "GetDisplayName")

	return GetAvatarPath(dir, name)
end

-- -----------------------------------------------------------------------
-- ArrowCloud ApiKey handling.

ParseArrowCloudIni = function(player)
	if not player then return end

	local profile_slot = {
		[PLAYER_1] = "ProfileSlot_Player1",
		[PLAYER_2] = "ProfileSlot_Player2"
	}
	if not profile_slot[player] then return "" end

	local dir = safe_profile_dir(player)
	local pn = safe_enum_short(player, nil)
	if not dir or #dir == 0 then return "" end
	if not (pn and SL and SL[pn]) then return false end

	local path = dir .. "ArrowCloud.ini"
	SL[pn].ArrowCloudApiKey = ""
	SL[pn].ArrowCloudAllowAutoplay = false

	if not safe_file_exists(path) then
		return safe_ini_write(path, {
			["ArrowCloud"]={
				["ApiKey"]="",
				["AllowAutoplay"]="0"
			}
		})
	else
		local contents = safe_ini_read(path)
		local section = type(contents["ArrowCloud"]) == "table" and contents["ArrowCloud"] or {}
		SL[pn].ArrowCloudApiKey = sanitize_arrowcloud_token(section["ApiKey"])
		SL[pn].ArrowCloudAllowAutoplay = normalize_arrowcloud_allow_autoplay(section["AllowAutoplay"])
		section["ApiKey"] = SL[pn].ArrowCloudApiKey
		section["AllowAutoplay"] = SL[pn].ArrowCloudAllowAutoplay and "1" or "0"
		contents["ArrowCloud"] = section
		return safe_ini_write(path, contents)
	end
end

WriteArrowCloudIni = function(player)
	if not player then return end

	local profile_slot = {
		[PLAYER_1] = "ProfileSlot_Player1",
		[PLAYER_2] = "ProfileSlot_Player2"
	}
	if not profile_slot[player] then return "" end

	local dir = safe_profile_dir(player)
	local pn = safe_enum_short(player, nil)
	if not dir or #dir == 0 then return "" end
	if not (pn and SL and SL[pn]) then return false end

	local path = dir .. "ArrowCloud.ini"
	local contents = {}
	if safe_file_exists(path) then
		contents = safe_ini_read(path)
	end
	contents["ArrowCloud"] = contents["ArrowCloud"] or {}
	contents["ArrowCloud"]["ApiKey"] = sanitize_arrowcloud_token(SL[pn].ArrowCloudApiKey)
	contents["ArrowCloud"]["AllowAutoplay"] = normalize_arrowcloud_allow_autoplay(SL[pn].ArrowCloudAllowAutoplay) and "1" or "0"

	return safe_ini_write(path, contents)
end
