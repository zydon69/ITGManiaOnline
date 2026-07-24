local sourceRoot = assert(arg[1], "source root is required")

unpack = unpack or table.unpack
ivalues = function(values)
	local index = 0
	return function()
		index = index + 1
		return values[index]
	end
end
PLAYER_1 = "PlayerNumber_P1"
PLAYER_2 = "PlayerNumber_P2"

local profile = {}
local profileDir = "/profiles/p1/"
local prefsPath = profileDir .. "Simply Love UserPrefs.ini"
local files = {}
local broadcasts = {}
local applyModsCount = 0

local function copy(value)
	if type(value) ~= "table" then return value end
	local result = {}
	for key, item in pairs(value) do result[copy(key)] = copy(item) end
	return result
end

local function equal(actual, expected, label)
	assert(actual == expected,
		(label or "value") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
end

local playerState = {
	optionsString = "",
	SetPlayerOptions = function(self, _, value) self.optionsString = value end,
	GetPlayerOptionsString = function(self) return self.optionsString end,
	GetPlayerOptions = function()
		return {
			ResetDisabledTimingWindows = function() end,
			FailSetting = function() end,
		}
	end,
}

local function resetPlayer()
	SL.P1.ActiveModifiers = {
		SpeedModType = "M",
		SpeedMod = 250,
		Mini = "0%",
		NoteSkin = "default",
		HideTargets = false,
		ErrorBar = "None",
		RememberOnlineToken = false,
		ShowExScore = false,
		ShowHardEXScore = false,
	}
	SL.P1.PlayerOptionsString = nil
	SL.P1.GameplayPresets = nil
	SL.P1.Stages = {Stats={}}
	playerState.optionsString = "default-native"
end

Trace = function() end
Warn = function() end
ToEnumShortString = function(player)
	if player == PLAYER_1 then return "P1" end
	if player == PLAYER_2 then return "P2" end
	return nil
end
GetDefaultFailType = function() return "FailType_Immediate" end
FindInTable = function(value, list)
	for index, item in ipairs(list or {}) do
		if item == value then return index end
	end
	return nil
end
CustomOptionRow = function(key)
	local rows = {
		SpeedModType = {Values={"X", "C", "M"}, Choices={"X", "C", "M"}},
		Mini = {Values={"0%", "10%"}, Choices={"0%", "10%"}},
		NoteSkin = {Choices={"default", "cel"}},
		ErrorBar = {Values={"None", "Text"}, Choices={"None", "Text"}},
	}
	return rows[key]
end
NOTESKIN = {
	DoesNoteSkinExist = function(_, name)
		return name == "default" or name == "cel" or name == "cel__blue"
	end,
}
THEME = {
	GetThemeDisplayName = function() return "Simply Love" end,
	GetString = function(_, group, key)
		local strings = {
			RenameGameplayPresetPrompt = "Enter a name for this preset.",
			GameplayPresetNameBlank = "Preset name cannot be blank.",
		}
		return strings[key] or key
	end,
}
FILEMAN = {
	DoesFileExist = function(_, path) return files[path] ~= nil end,
}
IniFile = {
	ReadFile = function(path) return copy(files[path] or {}) end,
	WriteFile = function(path, contents)
		files[path] = copy(contents)
		return true
	end,
}
GAMESTATE = {
	GetHumanPlayers = function() return {PLAYER_1} end,
	GetPlayerState = function(_, player)
		return player == PLAYER_1 and playerState or nil
	end,
	ResetPlayerOptions = function() playerState.optionsString = "default-native" end,
}
PROFILEMAN = {
	GetProfile = function(_, player) return player == PLAYER_1 and profile or nil end,
	GetProfileDir = function() return profileDir end,
	IsPersistentProfile = function(_, player) return player == PLAYER_1 end,
	SaveProfile = function() return true end,
}
MESSAGEMAN = {
	Broadcast = function(_, name, params)
		broadcasts[#broadcasts+1] = {name=name, params=params}
	end,
}
ApplyMods = function() applyModsCount = applyModsCount + 1 end

-- Reproduce the engine's alphabetical theme-script load order: profile
-- helpers are evaluated before SL_Init.lua creates the shared SL table.
SL = nil
SL_GameplayPresets = nil
dofile(sourceRoot .. "/Themes/Simply Love/Scripts/SL-PlayerProfiles.lua")
assert(type(SL_GameplayPresets) == "table", "preset service must bootstrap before SL exists")

SL = {
	P1 = {
		initialize = function(self) resetPlayer() end,
	},
	P2 = {},
	GameplayPresets = SL_GameplayPresets,
}
resetPlayer()

-- A legacy flat profile becomes six identical presets without changing the
-- active gameplay or profile-wide authentication preference.
files[prefsPath] = {
	["Simply Love"] = {
		SpeedModType = "C",
		SpeedMod = 500,
		Mini = "10%",
		NoteSkin = "cel",
		RememberOnlineToken = true,
		PlayerOptionsString = "legacy-native",
	},
}

equal(LoadProfileCustom(profile, profileDir), true, "legacy profile load")
equal(SL.GameplayPresets:GetSelected(PLAYER_1), 1, "legacy selected preset")
equal(SL.GameplayPresets:GetName(PLAYER_1, 1), "Preset 1", "default preset name")
equal(SL.GameplayPresets:GetName(PLAYER_1, 6), "Preset 6", "sixth default preset name")
equal(SL.P1.ActiveModifiers.SpeedModType, "C", "legacy speed type")
equal(SL.P1.ActiveModifiers.SpeedMod, 500, "legacy speed value")
equal(SL.P1.ActiveModifiers.RememberOnlineToken, true, "profile-wide auth preference")
equal(playerState.optionsString, "legacy-native", "legacy native options")

-- Give Preset 2 distinct theme and native engine options.
equal(SL.GameplayPresets:Select(PLAYER_1, 2), true, "select preset 2")
SL.P1.ActiveModifiers.SpeedModType = "X"
SL.P1.ActiveModifiers.SpeedMod = 2
SL.P1.ActiveModifiers.Mini = "0%"
SL.P1.ActiveModifiers.HideTargets = true
SL.P1.ActiveModifiers.ErrorBar = "Text"
playerState.optionsString = "2x, Mirror, No Holds, No Mines"
equal(SL.GameplayPresets:Capture(PLAYER_1), true, "capture preset 2")

equal(SL.GameplayPresets:Select(PLAYER_1, 1), true, "restore preset 1")
equal(SL.P1.ActiveModifiers.SpeedModType, "C", "preset 1 speed type")
equal(SL.P1.ActiveModifiers.SpeedMod, 500, "preset 1 speed value")
equal(playerState.optionsString, "legacy-native", "preset 1 native options")
equal(SL.P1.ActiveModifiers.HideTargets, false, "preset 1 advanced theme option")
equal(SL.P1.ActiveModifiers.ErrorBar, "None", "preset 1 second-page option")
equal(SL.P1.ActiveModifiers.RememberOnlineToken, true, "auth preference survives preset switch")
assert(applyModsCount >= 2, "preset switches must apply theme modifiers immediately")

equal(SL.GameplayPresets:Rename(PLAYER_1, 2, "Double"), true, "rename preset")
equal(SL.GameplayPresets:GetName(PLAYER_1, 2), "Double", "renamed preset label")
equal(SL.GameplayPresets:Rename(PLAYER_1, 2, "   "), false, "reject blank preset name")

equal(SaveProfileCustom(profile, profileDir), true, "preset profile save")
local saved = files[prefsPath]
equal(saved["Simply Love Gameplay Presets"].Version, 1, "preset schema version")
equal(saved["Simply Love Gameplay Presets"].SelectedPreset, 1, "saved selected preset")
equal(saved["Simply Love Gameplay Presets"].Preset2Name, "Double", "saved preset name")
equal(saved["Simply Love Gameplay Preset 2"].SpeedModType, "X", "saved preset 2 speed type")
equal(saved["Simply Love Gameplay Preset 2"].SpeedMod, 2, "saved preset 2 speed value")
equal(saved["Simply Love Gameplay Preset 2"].HideTargets, true, "saved advanced theme option")
equal(saved["Simply Love Gameplay Preset 2"].ErrorBar, "Text", "saved second-page option")
equal(saved["Simply Love Gameplay Preset 2"].PlayerOptionsString,
	"2x, Mirror, No Holds, No Mines", "saved native options from all option pages")
equal(saved["Simply Love Gameplay Preset 2"].RememberOnlineToken, nil, "auth excluded from presets")

-- Existing schemas may still contain the deprecated flag in presets that
-- have never been selected. Loading must migrate every slot, not only the
-- active one.
saved["Simply Love Gameplay Preset 3"].ColumnFlashOnMiss = true
saved["Simply Love Gameplay Preset 3"].FlashMiss = false

-- Reload the serialized profile and verify the second preset still restores
-- both storage domains.
resetPlayer()
equal(LoadProfileCustom(profile, profileDir), true, "preset profile reload")
equal(SL.GameplayPresets:GetName(PLAYER_1, 2), "Double", "reloaded preset name")
equal(SL.GameplayPresets:Select(PLAYER_1, 2), true, "select reloaded preset 2")
equal(SL.P1.ActiveModifiers.SpeedModType, "X", "reloaded preset speed type")
equal(SL.P1.ActiveModifiers.SpeedMod, 2, "reloaded preset speed value")
equal(SL.P1.ActiveModifiers.HideTargets, true, "reloaded advanced theme option")
equal(SL.P1.ActiveModifiers.ErrorBar, "Text", "reloaded second-page option")
equal(playerState.optionsString, "2x, Mirror, No Holds, No Mines", "reloaded native options")
equal(SL.P1.ActiveModifiers.RememberOnlineToken, true, "reloaded auth preference remains global")
equal(SL.P1.GameplayPresets.Slots[3].ColumnFlashOnMiss, nil, "deprecated slot key removed")
equal(SL.P1.GameplayPresets.Slots[3].FlashMiss, true, "deprecated slot value migrated")

-- Leaving any player-options page uses this targeted save path. It must
-- persist the active slot without requiring evaluation or a full Stats.xml
-- profile save.
SL.P1.ActiveModifiers.SpeedMod = 3.5
playerState.optionsString = "3.5x, Mirror, No Holds"
equal(SL.GameplayPresets:Save(PLAYER_1), true, "targeted preset save")
saved = files[prefsPath]
equal(saved["Simply Love Gameplay Preset 2"].SpeedMod, 3.5, "targeted save speed")
equal(saved["Simply Love Gameplay Preset 2"].PlayerOptionsString,
	"3.5x, Mirror, No Holds", "targeted save native options")
equal(saved["Simply Love Gameplay Preset 3"].ColumnFlashOnMiss, nil,
	"deprecated key not serialized")
equal(saved["Simply Love Gameplay Preset 3"].FlashMiss, true,
	"migrated slot serialized")

print("gameplay_presets_spec: ok")
