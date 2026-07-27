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

local frozen, captured = judgments.freeze_once({
	fantastic = 8,
	miss = 6,
	hold_ng = 1,
}, nil)
equal(captured, true, "first failed judgment snapshot is captured")
equal(frozen.fantastic, 8, "failed fantastic count")
equal(frozen.miss, 6, "failed miss count")

local afterFail, recaptured = judgments.freeze_once({
	fantastic = 20,
	miss = 400,
	hold_ng = 30,
}, frozen)
equal(recaptured, false, "failed judgment snapshot is immutable")
equal(afterFail.fantastic, 8, "post-fail hits are ignored")
equal(afterFail.miss, 6, "post-fail misses are ignored")
equal(afterFail.hold_ng, 1, "post-fail holds are ignored")

frozen.miss = 999
equal(afterFail.miss, 6, "frozen judgment snapshots do not share mutable tables")

local playerOneFinal = judgments.freeze_once({
	fantastic = 5,
	miss = 6,
}, nil)
local playerTwoFinal = judgments.freeze_once({
	fantastic = 3,
	miss = 8,
}, nil)
local playerOneAfterGameplay = judgments.freeze_once({ miss = 400 }, playerOneFinal)
local playerTwoAfterGameplay = judgments.freeze_once({ miss = 500 }, playerTwoFinal)
equal(playerOneAfterGameplay.miss, 6, "player one keeps its own failure-time result")
equal(playerTwoAfterGameplay.miss, 8, "player two keeps its own failure-time result")
equal(playerOneAfterGameplay.fantastic, 5, "player one snapshot is independent")
equal(playerTwoAfterGameplay.fantastic, 3, "player two snapshot is independent")

print("online score judgment behavior: ok")
