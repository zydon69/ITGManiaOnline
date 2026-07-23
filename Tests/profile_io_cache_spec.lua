local sourceRoot = assert(arg[1], "source root is required")

unpack = unpack or table.unpack
PLAYER_1 = "PlayerNumber_P1"
PLAYER_2 = "PlayerNumber_P2"

local currentProfileDir = "/profiles/p1/"
local files = {}
local reads = 0
local writes = 0

local function copy(value)
	if type(value) ~= "table" then return value end
	local result = {}
	for key, item in pairs(value) do
		result[copy(key)] = copy(item)
	end
	return result
end

local function equal(actual, expected, label)
	assert(actual == expected,
		(label or "value") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
end

local function resetCounters()
	reads = 0
	writes = 0
end

Trace = function() end
Warn = function() end
SM = function() end
ToEnumShortString = function(player)
	if player == PLAYER_1 then return "P1" end
	if player == PLAYER_2 then return "P2" end
	return nil
end
PROFILEMAN = {
	GetProfileDir = function()
		return currentProfileDir
	end,
}
FILEMAN = {
	DoesFileExist = function(_, path)
		return files[path] ~= nil
	end,
}
IniFile = {
	ReadFile = function(path)
		reads = reads + 1
		return copy(files[path] or {})
	end,
	WriteFile = function(path, contents)
		writes = writes + 1
		files[path] = copy(contents)
		return true
	end,
}
SL = {
	P1 = {
		ApiKey = "",
		GrooveStatsUsername = "",
		IsPadPlayer = false,
		ArrowCloudApiKey = "",
		ArrowCloudAllowAutoplay = false,
	},
	P2 = {},
}

dofile(sourceRoot .. "/Themes/Simply Love/Scripts/SL-PlayerProfiles.lua")

local arrowPath = currentProfileDir .. "ArrowCloud.ini"
files[arrowPath] = {
	ArrowCloud = {
		ApiKey = "arrow-token",
		AllowAutoplay = 0,
	},
	Unrelated = {
		Preserved = "yes",
	},
}

resetCounters()
equal(ParseArrowCloudIni(PLAYER_1, true), true, "initial ArrowCloud load")
equal(reads, 1, "initial ArrowCloud read count")
equal(writes, 0, "canonical ArrowCloud write count")
equal(SL.P1.ArrowCloudApiKey, "arrow-token", "loaded ArrowCloud token")
equal(SL.P1.ArrowCloudAllowAutoplay, false, "loaded ArrowCloud autoplay")

equal(EnsureArrowCloudIniLoaded(PLAYER_1), true, "cached branch load")
equal(EnsureArrowCloudIniLoaded(PLAYER_1), true, "cached screen load")
equal(reads, 1, "cached ArrowCloud read count")
equal(writes, 0, "cached ArrowCloud write count")

files[arrowPath].ArrowCloud.AllowAutoplay = "invalid"
equal(ParseArrowCloudIni(PLAYER_1, true), true, "ArrowCloud migration")
equal(reads, 2, "ArrowCloud migration read count")
equal(writes, 1, "ArrowCloud migration write count")
equal(files[arrowPath].ArrowCloud.AllowAutoplay, "0", "ArrowCloud normalized autoplay")
equal(files[arrowPath].Unrelated.Preserved, "yes", "ArrowCloud unrelated data")

resetCounters()
equal(WriteArrowCloudIni(PLAYER_1), true, "unchanged ArrowCloud save")
equal(reads, 0, "unchanged ArrowCloud save read count")
equal(writes, 0, "unchanged ArrowCloud save write count")

SL.P1.ArrowCloudApiKey = "new-arrow-token"
equal(WriteArrowCloudIni(PLAYER_1), true, "changed ArrowCloud save")
equal(reads, 1, "changed ArrowCloud save read count")
equal(writes, 1, "changed ArrowCloud save write count")
equal(files[arrowPath].ArrowCloud.ApiKey, "new-arrow-token", "saved ArrowCloud token")
equal(files[arrowPath].Unrelated.Preserved, "yes", "saved ArrowCloud unrelated data")

currentProfileDir = "/profiles/other/"
local otherArrowPath = currentProfileDir .. "ArrowCloud.ini"
files[otherArrowPath] = {
	ArrowCloud = {
		ApiKey = "other-profile-token",
		AllowAutoplay = 1,
	},
}
resetCounters()
equal(EnsureArrowCloudIniLoaded(PLAYER_1), true, "profile cache invalidation")
equal(reads, 1, "new profile ArrowCloud read count")
equal(SL.P1.ArrowCloudApiKey, "other-profile-token", "new profile ArrowCloud token")
equal(SL.P1.ArrowCloudAllowAutoplay, true, "new profile ArrowCloud autoplay")

dofile(sourceRoot .. "/Themes/Simply Love/Scripts/SL-Helpers-GrooveStats.lua")

local groovePath = currentProfileDir .. "GrooveStats.ini"
files[groovePath] = {
	GrooveStats = {
		ApiKey = "",
		Username = "",
		IsPadPlayer = 0,
	},
}
SL.P1.ApiKey = ""
SL.P1.GrooveStatsUsername = ""
SL.P1.IsPadPlayer = false

resetCounters()
equal(ParseGrooveStatsIni(PLAYER_1), true, "canonical GrooveStats load")
equal(reads, 1, "canonical GrooveStats read count")
equal(writes, 0, "canonical GrooveStats write count")

files[groovePath].GrooveStats.ApiKey = "invalid"
resetCounters()
equal(ParseGrooveStatsIni(PLAYER_1), true, "GrooveStats migration")
equal(reads, 1, "GrooveStats migration read count")
equal(writes, 1, "GrooveStats migration write count")
equal(files[groovePath].GrooveStats.ApiKey, "", "normalized GrooveStats token")

print("profile_io_cache_spec: ok")
