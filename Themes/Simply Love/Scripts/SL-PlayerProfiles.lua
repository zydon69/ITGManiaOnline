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
	NoteSkinVariant  = "string",
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

local GAMEPLAY_PRESET_COUNT = 6
local GAMEPLAY_PRESET_VERSION = 1

-- Authentication/session preferences remain profile-wide.  Everything else
-- in this allowlist represents gameplay state and belongs to each preset.
local gameplay_preset_settings = {}
for key, valueType in pairs(permitted_profile_settings) do
	if key ~= "RememberOnlineToken" then
		gameplay_preset_settings[key] = valueType
	end
end

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
	local ok, result = safe_call("IniFile.WriteFile " .. path, function()
		return IniFile.WriteFile(path, contents)
	end)
	return ok == true and result ~= false
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
	if key == "NoteSkinVariant" then
		if not (NOTESKIN and type(NOTESKIN.DoesNoteSkinExist) == "function") then return nil end
		local ok, exists = safe_call("NOTESKIN.DoesNoteSkinExist " .. value, function()
			return NOTESKIN:DoesNoteSkinExist(value)
		end)
		return ok and exists == true and value or nil
	end

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

local function arrowcloud_allow_autoplay_is_current(value, expected)
	if value == nil then return false end
	if expected then
		return value == true or value == 1 or value == "1" or value == "true"
	end
	return value == false or value == 0 or value == "0" or value == "false"
end

-- Keep the profile-scoped ArrowCloud values that were loaded from disk.  The
-- profile loader explicitly refreshes this cache; later consumers in the same
-- menu flow can reuse it without parsing the same file again.
local arrowcloud_profile_cache = {}

local function cache_arrowcloud_profile(pn, path, api_key, allow_autoplay)
	arrowcloud_profile_cache[pn] = {
		path = path,
		apiKey = api_key,
		allowAutoplay = allow_autoplay == true,
	}
end

local function apply_cached_arrowcloud_profile(pn, path)
	local cached = arrowcloud_profile_cache[pn]
	if not cached or cached.path ~= path then return false end

	SL[pn].ArrowCloudApiKey = cached.apiKey
	SL[pn].ArrowCloudAllowAutoplay = cached.allowAutoplay
	return true
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

local function migrate_deprecated_gameplay_settings(settings)
	if type(settings) ~= "table" then return settings end
	if settings.ColumnFlashOnMiss ~= nil then
		judgment_flash_trace(("profile_migration_begin pn=%s ColumnFlashOnMiss=%s FlashMissBefore=%s")
			:format("snapshot", tostring(settings.ColumnFlashOnMiss), tostring(settings.FlashMiss)))
	end
	if settings.ColumnFlashOnMiss == true and settings.FlashMiss ~= true then
		settings.FlashMiss = true
	end
	settings.ColumnFlashOnMiss = nil
	return settings
end

local function migrate_deprecated_profile_modifiers(pn)
	local mods = pn and SL and SL[pn] and SL[pn].ActiveModifiers or nil
	if type(mods) ~= "table" then return end
	local hadDeprecatedSetting = mods.ColumnFlashOnMiss ~= nil
	migrate_deprecated_gameplay_settings(mods)
	if hadDeprecatedSetting and mods.FlashMiss == true then
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

local function copy_value(value)
	if type(value) ~= "table" then return value end
	local copied = {}
	for key, nested in pairs(value) do
		copied[key] = copy_value(nested)
	end
	return copied
end

local function copy_snapshot(snapshot)
	local copied = {}
	for key, value in pairs(type(snapshot) == "table" and snapshot or {}) do
		copied[key] = copy_value(value)
	end
	return copied
end

local function default_gameplay_preset_name(index)
	return ("Preset %d"):format(index)
end

local function normalize_gameplay_preset_index(index)
	index = math.floor(tonumber(index) or 1)
	return clamp_number(index, 1, GAMEPLAY_PRESET_COUNT, 1)
end

local function normalize_gameplay_preset_name(name, index)
	name = tostring(name or ""):gsub("[\r\n]", ""):gsub("^%s+", ""):gsub("%s+$", "")
	if type(string.utf8len) == "function" and type(string.utf8sub) == "function" then
		local ok, length = pcall(string.utf8len, name)
		if ok and length > 32 then
			local truncated, value = pcall(string.utf8sub, name, 1, 32)
			if truncated then name = value end
		end
	elseif #name > 32 then
		name = name:sub(1, 32)
	end
	if name == "" then return default_gameplay_preset_name(index) end
	return name
end

local function gameplay_preset_metadata_section(theme_name)
	return theme_name .. " Gameplay Presets"
end

local function gameplay_preset_section(theme_name, index)
	return ("%s Gameplay Preset %d"):format(theme_name, index)
end

local function sanitize_settings(source, allowed_settings)
	local output = {}
	for key, value in pairs(type(source) == "table" and source or {}) do
		if allowed_settings[key] then
			local sanitized = sanitize_profile_value(key, value)
			if sanitized ~= nil then output[key] = copy_value(sanitized) end
		end
	end
	if output.ShowHardEXScore then output.ShowExScore = false end
	return output
end

local function current_player_options_string(player, pn)
	local playerState = safe_player_state(player)
	local optionsString = safe_method(
		"PlayerState.GetPlayerOptionsString",
		playerState,
		"GetPlayerOptionsString",
		"ModsLevel_Preferred"
	)
	if type(optionsString) == "string" and optionsString ~= "" then
		if pn and SL and SL[pn] then SL[pn].PlayerOptionsString = optionsString end
		return optionsString
	end
	local cached = pn and SL and SL[pn] and SL[pn].PlayerOptionsString or nil
	return type(cached) == "string" and cached or nil
end

local function capture_gameplay_preset_snapshot(player, pn)
	local modifiers = pn and SL and SL[pn] and SL[pn].ActiveModifiers or {}
	local snapshot = sanitize_settings(modifiers, gameplay_preset_settings)
	local optionsString = current_player_options_string(player, pn)
	if optionsString then
		snapshot.PlayerOptionsString = sanitize_profile_value("PlayerOptionsString", optionsString)
	end
	return snapshot
end

local function new_gameplay_preset_state(seed)
	local state = {
		Version = GAMEPLAY_PRESET_VERSION,
		Selected = 1,
		Names = {},
		Slots = {},
	}
	for index=1, GAMEPLAY_PRESET_COUNT do
		state.Names[index] = default_gameplay_preset_name(index)
		state.Slots[index] = migrate_deprecated_gameplay_settings(copy_snapshot(seed))
	end
	return state
end

local function ensure_gameplay_preset_state(player, pn)
	if not (pn and SL and SL[pn]) then return nil end
	local state = SL[pn].GameplayPresets
	if type(state) ~= "table" or type(state.Names) ~= "table" or type(state.Slots) ~= "table" then
		state = new_gameplay_preset_state(capture_gameplay_preset_snapshot(player, pn))
		SL[pn].GameplayPresets = state
	end
	state.Selected = normalize_gameplay_preset_index(state.Selected)
	for index=1, GAMEPLAY_PRESET_COUNT do
		state.Names[index] = normalize_gameplay_preset_name(state.Names[index], index)
		if type(state.Slots[index]) ~= "table" then
			state.Slots[index] = capture_gameplay_preset_snapshot(player, pn)
		end
		migrate_deprecated_gameplay_settings(state.Slots[index])
	end
	return state
end

local function replace_active_gameplay_modifiers(pn, snapshot)
	local modifiers = pn and SL and SL[pn] and SL[pn].ActiveModifiers or nil
	if type(modifiers) ~= "table" then return false end
	for key in pairs(gameplay_preset_settings) do
		if key ~= "PlayerOptionsString" then
			modifiers[key] = copy_value(snapshot[key])
		end
	end
	return true
end

local function apply_gameplay_preset_snapshot(player, pn, snapshot, apply_theme_mods)
	if type(snapshot) ~= "table" or not replace_active_gameplay_modifiers(pn, snapshot) then
		return false
	end
	if type(snapshot.PlayerOptionsString) == "string" then
		restore_player_options_string(player, pn, snapshot.PlayerOptionsString)
	end
	migrate_deprecated_profile_modifiers(pn)
	apply_hard_ex_exclusivity(pn)
	if apply_theme_mods and type(ApplyMods) == "function" then
		safe_call("ApplyMods gameplay preset", function() ApplyMods(player) end)
	end
	return true
end

local function load_gameplay_preset_state(contents, theme_name, player, pn)
	local seed = capture_gameplay_preset_snapshot(player, pn)
	local state = new_gameplay_preset_state(seed)
	local metadata = type(contents[gameplay_preset_metadata_section(theme_name)]) == "table"
		and contents[gameplay_preset_metadata_section(theme_name)] or nil

	if metadata then
		state.Version = GAMEPLAY_PRESET_VERSION
		state.Selected = normalize_gameplay_preset_index(metadata.SelectedPreset)
		for index=1, GAMEPLAY_PRESET_COUNT do
			state.Names[index] = normalize_gameplay_preset_name(metadata["Preset" .. index .. "Name"], index)
			local stored = contents[gameplay_preset_section(theme_name, index)]
			if type(stored) == "table" then
				local snapshot = copy_snapshot(seed)
				for key, value in pairs(sanitize_settings(stored, gameplay_preset_settings)) do
					snapshot[key] = copy_value(value)
				end
				state.Slots[index] = migrate_deprecated_gameplay_settings(snapshot)
			end
		end
	end

	SL[pn].GameplayPresets = state
	apply_gameplay_preset_snapshot(player, pn, state.Slots[state.Selected], false)
	return state
end

-- Theme scripts are loaded alphabetically, so this file is evaluated before
-- SL_Init.lua creates SL.  Keep the service in a dedicated bootstrap global;
-- SL_Init.lua attaches the same table to SL.GameplayPresets.
SL_GameplayPresets = SL_GameplayPresets or {}
local GameplayPresets = SL_GameplayPresets
if SL then SL.GameplayPresets = GameplayPresets end
GameplayPresets.Count = GAMEPLAY_PRESET_COUNT

function GameplayPresets:GetSelected(player)
	local pn = safe_enum_short(player, nil)
	local state = ensure_gameplay_preset_state(player, pn)
	return state and state.Selected or 1
end

function GameplayPresets:GetName(player, index)
	local pn = safe_enum_short(player, nil)
	local state = ensure_gameplay_preset_state(player, pn)
	index = normalize_gameplay_preset_index(index)
	return state and state.Names[index] or default_gameplay_preset_name(index)
end

function GameplayPresets:Capture(player)
	local pn = safe_enum_short(player, nil)
	local state = ensure_gameplay_preset_state(player, pn)
	if not state then return false end
	state.Slots[state.Selected] = capture_gameplay_preset_snapshot(player, pn)
	return true
end

function GameplayPresets:Select(player, index)
	local pn = safe_enum_short(player, nil)
	local state = ensure_gameplay_preset_state(player, pn)
	if not state then return false end
	index = normalize_gameplay_preset_index(index)
	if index == state.Selected then return true end

	local previous = state.Selected
	self:Capture(player)
	state.Selected = index
	if not apply_gameplay_preset_snapshot(player, pn, state.Slots[index], true) then
		state.Selected = previous
		return false
	end
	if MESSAGEMAN and type(MESSAGEMAN.Broadcast) == "function" then
		MESSAGEMAN:Broadcast("GameplayPresetChanged", {
			Player = player,
			Index = index,
			Name = state.Names[index],
		})
	end
	return true
end

function GameplayPresets:Rename(player, index, name)
	local pn = safe_enum_short(player, nil)
	local state = ensure_gameplay_preset_state(player, pn)
	if not state then return false end
	index = normalize_gameplay_preset_index(index)
	local normalized = normalize_gameplay_preset_name(name, index)
	if tostring(name or ""):gsub("^%s+", ""):gsub("%s+$", "") == "" then return false end
	state.Names[index] = normalized
	if MESSAGEMAN and type(MESSAGEMAN.Broadcast) == "function" then
		MESSAGEMAN:Broadcast("GameplayPresetRenamed", {
			Player = player,
			Index = index,
			Name = normalized,
		})
	end
	return true
end

function GameplayPresets:Save(player)
	if safe_method(
		"PROFILEMAN.IsPersistentProfile",
		PROFILEMAN,
		"IsPersistentProfile",
		player
	) ~= true then
		return false
	end
	local profile = safe_method("PROFILEMAN.GetProfile", PROFILEMAN, "GetProfile", player)
	local dir = safe_profile_dir(player)
	if not (profile and dir ~= "" and type(SaveProfileCustom) == "function") then
		return false
	end
	local ok, saved = safe_call("SaveProfileCustom gameplay presets", function()
		return SaveProfileCustom(profile, dir)
	end)
	return ok and saved == true
end

local function gameplay_preset_string(name, fallback)
	if not (THEME and type(THEME.GetString) == "function") then return fallback end
	local ok, value = safe_call("THEME.GetString OptionNames." .. name, function()
		return THEME:GetString("OptionNames", name)
	end)
	return ok and value ~= name and tostring(value) or fallback
end

function GameplayPresets:OpenRenameScreen(player)
	local index = self:GetSelected(player)
	if not (SCREENMAN and type(SCREENMAN.AddNewScreenToTop) == "function") then return false end
	SCREENMAN:AddNewScreenToTop("ScreenTextEntry")
	local screen = SCREENMAN:GetTopScreen()
	if not (screen and type(screen.Load) == "function") then return false end
	screen:Load({
		Question = gameplay_preset_string("RenameGameplayPresetPrompt", "Enter a name for this preset."),
		InitialAnswer = self:GetName(player, index),
		MaxInputLength = 32,
		Validate = function(answer)
			if tostring(answer or ""):gsub("^%s+", ""):gsub("%s+$", "") == "" then
				return false, gameplay_preset_string("GameplayPresetNameBlank", "Preset name cannot be blank.")
			end
			return true, ""
		end,
		OnOK = function(answer)
			if self:Rename(player, index, answer) then self:Save(player) end
		end,
	})
	return true
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
	apply_hard_ex_exclusivity(pn)
	SL[pn].GameplayPresets = new_gameplay_preset_state(capture_gameplay_preset_snapshot(player, pn))
	return true
end


-- function assigned to "CustomLoadFunction" under [Profile] in metrics.ini
LoadProfileCustom = function(profile, dir)
	local theme_name = theme_display_name()
	local path =  tostring(dir or "") .. user_prefs_filename()
	local player, pn
	local filecontents = {}

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

		if type(ParseGrooveStatsIni) == "function" then
			safe_call("ParseGrooveStatsIni", function() ParseGrooveStatsIni(player) end)
		end
		if type(ParseArrowCloudIni) == "function" then
			-- A profile load is the cache invalidation boundary.  Always refresh
			-- from disk here, then let the branch and login screen reuse it.
			safe_call("ParseArrowCloudIni", function() ParseArrowCloudIni(player, true) end)
		end
		if type(ReadItlFile) == "function" then
			safe_call("ReadItlFile", function() ReadItlFile(player) end)
		end
	end

	if pn and safe_file_exists(path) then
		filecontents = safe_ini_read(path)
		local legacy = filecontents[theme_name]

		-- for each key/value pair read in from the player's profile
		for k,v in pairs(type(legacy) == "table" and legacy or {}) do
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

	if pn then load_gameplay_preset_state(filecontents, theme_name, player, pn) end
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
			if SL.GameplayPresets then SL.GameplayPresets:Capture(player) end
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

			local sections = {[theme_name]=output}
			local state = ensure_gameplay_preset_state(player, pn)
			if state then
				local metadata = {
					Version = GAMEPLAY_PRESET_VERSION,
					SelectedPreset = state.Selected,
				}
				for index=1, GAMEPLAY_PRESET_COUNT do
					metadata["Preset" .. index .. "Name"] =
						normalize_gameplay_preset_name(state.Names[index], index)
					sections[gameplay_preset_section(theme_name, index)] =
						migrate_deprecated_gameplay_settings(
							sanitize_settings(state.Slots[index], gameplay_preset_settings)
						)
				end
				sections[gameplay_preset_metadata_section(theme_name)] = metadata
			end

			ok = safe_ini_write(path, sections) and ok

			if type(WriteGrooveStatsIni) == "function" then
				local grooveOk, grooveResult = safe_call("WriteGrooveStatsIni", function() return WriteGrooveStatsIni(player) end)
				ok = grooveOk and grooveResult ~= false and ok
			end
			if type(WriteArrowCloudIni) == "function" then
				local arrowOk, arrowResult = safe_call("WriteArrowCloudIni", function() return WriteArrowCloudIni(player) end)
				ok = arrowOk and arrowResult ~= false and ok
			end
			-- Write to the ITL file if we need to.
			-- This is relevant for memory cards.
			if type(WriteItlFile) == "function" then
				local itlOk, itlResult = safe_call("WriteItlFile", function() return WriteItlFile(player) end)
				ok = itlOk and itlResult ~= false and ok
			end
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

ParseArrowCloudIni = function(player, forceReload)
	if not player then return end

	if not profile_slot_for_player(player) then return "" end

	local dir = safe_profile_dir(player)
	local pn = safe_enum_short(player, nil)
	if not dir or #dir == 0 then return "" end
	if not (pn and SL and SL[pn]) then return false end

	local path = dir .. "ArrowCloud.ini"
	if forceReload ~= true and apply_cached_arrowcloud_profile(pn, path) then
		return true
	end

	SL[pn].ArrowCloudApiKey = ""
	SL[pn].ArrowCloudAllowAutoplay = false

	if not safe_file_exists(path) then
		local created = safe_ini_write(path, {
			["ArrowCloud"]={
				["ApiKey"]="",
				["AllowAutoplay"]="0"
			}
		})
		if created then
			cache_arrowcloud_profile(pn, path, "", false)
		end
		return created
	end

	local contents = safe_ini_read(path)
	local sectionExists = type(contents["ArrowCloud"]) == "table"
	local section = sectionExists and contents["ArrowCloud"] or {}
	local apiKey = sanitize_arrowcloud_token(section["ApiKey"])
	local allowAutoplay = normalize_arrowcloud_allow_autoplay(section["AllowAutoplay"])
	local serializedAllowAutoplay = allowAutoplay and "1" or "0"
	local requiresWrite = not sectionExists
		or section["ApiKey"] ~= apiKey
		or not arrowcloud_allow_autoplay_is_current(section["AllowAutoplay"], allowAutoplay)

	SL[pn].ArrowCloudApiKey = apiKey
	SL[pn].ArrowCloudAllowAutoplay = allowAutoplay

	if requiresWrite then
		section["ApiKey"] = apiKey
		section["AllowAutoplay"] = serializedAllowAutoplay
		contents["ArrowCloud"] = section
		if not safe_ini_write(path, contents) then
			return false
		end
	end

	cache_arrowcloud_profile(pn, path, apiKey, allowAutoplay)
	return true
end

EnsureArrowCloudIniLoaded = function(player)
	return ParseArrowCloudIni(player, false)
end

WriteArrowCloudIni = function(player)
	if not player then return end

	if not profile_slot_for_player(player) then return "" end

	local dir = safe_profile_dir(player)
	local pn = safe_enum_short(player, nil)
	if not dir or #dir == 0 then return "" end
	if not (pn and SL and SL[pn]) then return false end

	local path = dir .. "ArrowCloud.ini"
	local apiKey = sanitize_arrowcloud_token(SL[pn].ArrowCloudApiKey)
	local allowAutoplay = normalize_arrowcloud_allow_autoplay(SL[pn].ArrowCloudAllowAutoplay)
	local cached = arrowcloud_profile_cache[pn]
	if cached
	and cached.path == path
	and cached.apiKey == apiKey
	and cached.allowAutoplay == allowAutoplay
	then
		return true
	end

	local contents = {}
	if safe_file_exists(path) then
		contents = safe_ini_read(path)
	end
	local sectionExists = type(contents["ArrowCloud"]) == "table"
	local section = sectionExists and contents["ArrowCloud"] or {}
	local serializedAllowAutoplay = allowAutoplay and "1" or "0"
	local requiresWrite = not sectionExists
		or section["ApiKey"] ~= apiKey
		or not arrowcloud_allow_autoplay_is_current(section["AllowAutoplay"], allowAutoplay)

	if requiresWrite then
		section["ApiKey"] = apiKey
		section["AllowAutoplay"] = serializedAllowAutoplay
		contents["ArrowCloud"] = section
		if not safe_ini_write(path, contents) then
			return false
		end
	end

	SL[pn].ArrowCloudApiKey = apiKey
	SL[pn].ArrowCloudAllowAutoplay = allowAutoplay
	cache_arrowcloud_profile(pn, path, apiKey, allowAutoplay)
	return true
end
