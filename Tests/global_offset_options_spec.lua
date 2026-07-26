local sourceRoot = assert(arg[1], "source root is required")

PLAYER_1 = "PlayerNumber_P1"
PLAYER_2 = "PlayerNumber_P2"
ThemePrefs = {}
PROFILEMAN = {}
GAMESTATE = {}

round = function(value)
	if value >= 0 then return math.floor(value + 0.5) end
	return math.ceil(value - 0.5)
end

range = function(low, high)
	local values = {}
	for value=low, high do values[#values+1] = value end
	return values
end

stringify = function(values, format)
	local strings = {}
	for index, value in ipairs(values) do
		strings[index] = format:format(value)
	end
	return strings
end

local names = {
	"Default", "Headphones", "Television",
	"Projector", "Arcade", "Capture",
}
local seconds = {-0.008, 0.087, 0.125, -0.019, 0.033, 0}
local selected = 0
local runtimeSeconds = seconds[1]
local saveCount = 0
local broadcasts = {}

PREFSMAN = {
	GetPreference = function(_, name)
		if name == "GlobalOffsetSeconds" then return runtimeSeconds end
		return 0
	end,
	SetPreference = function(_, name, value)
		assert(name == "GlobalOffsetSeconds", "unexpected preference write")
		runtimeSeconds = value
		seconds[selected + 1] = value
	end,
	GetGlobalOffsetProfileCount = function() return #names end,
	GetGlobalOffsetProfileName = function(_, index) return names[index + 1] end,
	GetGlobalOffsetProfileSeconds = function(_, index) return seconds[index + 1] end,
	GetGlobalOffsetProfileSelected = function() return selected end,
	SetGlobalOffsetProfileSelected = function(_, index)
		selected = index
		runtimeSeconds = seconds[index + 1]
	end,
	SavePreferences = function() saveCount = saveCount + 1 end,
	LogGlobalOffsetDiagnostics = function() end,
}

MESSAGEMAN = {
	Broadcast = function(_, name)
		broadcasts[#broadcasts+1] = name
	end,
}

THEME = {
	GetString = function(_, _, name) return name end,
}

dofile(sourceRoot .. "/Themes/Simply Love/Scripts/SL-OperatorMenuOptions.lua")

local offsetRow = OperatorMenuOptionRows.GlobalOffsetSeconds()
assert(offsetRow.ExportOnChange == true,
	"global offset edits must export before a profile switch can reload the row")

local profileRow = OperatorMenuOptionRows.GlobalOffsetProfile()
local hasValueReload = false
for _, message in ipairs(profileRow.ReloadRowMessages) do
	if message == "GlobalOffsetProfile1SecondsChanged" then hasValueReload = true end
end
assert(hasValueReload, "profile labels must reload after active offset changes")
for _, message in ipairs(profileRow.ReloadRowMessages) do
	assert(message ~= "GlobalOffsetSecondsChanged",
		"profile selection must not re-enter its own row reload")
end

-- Adjust profile 1 from -8 ms to -42 ms. ExportOnChange calls this before the
-- user can move to the profile row.
local offsetSelection = {}
offsetSelection[-42 - offsetRow._low + 1] = true
offsetRow:SaveSelections(offsetSelection, PLAYER_1)
assert(seconds[1] == -0.042, "edited offset must update the active named slot")

profileRow:Reload()
assert(profileRow.Choices[1] == "Default (-42ms)",
	"profile label must immediately display the edited value")

-- Switch to profile 2. The outgoing profile and new selection must be durable
-- before the reload broadcast changes either option row.
profileRow:SaveSelections({false, true}, PLAYER_1)
assert(selected == 1, "profile 2 must become active")
assert(runtimeSeconds == 0.087, "profile switch must load profile 2 offset")
assert(saveCount == 1, "profile switch must persist exactly once")
assert(broadcasts[#broadcasts] == "GlobalOffsetProfileChanged",
	"profile switch must broadcast its row reload after persistence")

offsetRow:Reload()
local loadedSelection = {}
offsetRow:LoadSelections(loadedSelection, PLAYER_1)
local expectedIndex = 87 - offsetRow._low + 1
assert(loadedSelection[expectedIndex] == true,
	"offset row reload must select the newly active profile value")
assert(seconds[1] == -0.042,
	"switching profiles must not discard the outgoing profile edit")

print("global_offset_options_spec: ok")
