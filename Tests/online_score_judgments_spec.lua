local sourceRoot = assert(arg[1], "source root is required")
local judgments = assert(dofile(
	sourceRoot .. "/Themes/Simply Love/Scripts/02 SL-ITGOnlineScoreJudgments.lua"
))

local function equal(actual, expected, label)
	assert(actual == expected, (label or "value")
		.. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
end

local live = judgments.build({
	W0 = 3,
	W1 = 4,
	W2 = 5,
	W3 = 2,
	W4 = 1,
	W5 = 1,
	Miss = 2,
	Mines = 1,
	totalHolds = 28,
	totalRolls = 4,
}, {
	Held = 2,
	LetGo = 1,
	MissedHold = 1,
})

equal(live.fantastic, 7, "fantastic aggregation")
equal(live.hold_ok, 2, "only resolved successful holds are sent")
equal(live.hold_ng, 2, "only resolved failed holds are sent")

local beforeFirstHold = judgments.build({
	totalHolds = 28,
	totalRolls = 4,
}, {})
equal(beforeFirstHold.hold_ok, 0, "future holds are not successful")
equal(beforeFirstHold.hold_ng, 0, "future holds are not failed")

local merged, restored = judgments.merge_monotonic({
	fantastic = 8,
	hold_ok = 3,
	hold_ng = 1,
}, {
	fantastic = 7,
	hold_ok = 2,
	hold_ng = 1,
})
equal(merged.fantastic, 8, "forward tap progress")
equal(merged.hold_ok, 3, "forward hold progress")
equal(merged.hold_ng, 1, "stable failed hold progress")
equal(#restored, 0, "forward progress requires no restoration")

merged, restored = judgments.merge_monotonic({
	fantastic = 6,
	hold_ok = 1,
	hold_ng = 0,
}, {
	fantastic = 7,
	hold_ok = 2,
	hold_ng = 1,
})
equal(merged.fantastic, 7, "tap regression restoration")
equal(merged.hold_ok, 2, "successful hold regression restoration")
equal(merged.hold_ng, 1, "failed hold regression restoration")
equal(#restored, 3, "all regressed counters are reported")

local sanitized = judgments.copy({
	fantastic = -10,
	excellent = 2.9,
	hold_ng = math.huge,
})
equal(sanitized.fantastic, 0, "negative count clamp")
equal(sanitized.excellent, 2, "fractional count floor")
equal(sanitized.hold_ng, 0, "non-finite count clamp")

print("online score judgment behavior: ok")
