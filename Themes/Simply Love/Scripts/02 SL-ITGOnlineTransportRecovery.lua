ITGOnlineTransportRecovery = ITGOnlineTransportRecovery or {}

local Recovery = ITGOnlineTransportRecovery

local function finite_number(value, fallback)
	value = tonumber(value)
	if value == nil or value ~= value or value == math.huge or value == -math.huge then
		return fallback
	end
	return value
end

function Recovery.schedule(attempt, now, baseDelay, maxDelay, notBefore)
	attempt = math.max(1, math.floor(finite_number(attempt, 0)) + 1)
	now = finite_number(now, 0)
	baseDelay = math.max(0.1, finite_number(baseDelay, 1))
	maxDelay = math.max(baseDelay, finite_number(maxDelay, 10))
	local exponentialDelay = math.min(
		maxDelay,
		baseDelay * (2 ^ math.min(attempt - 1, 16))
	)
	local nextAttemptAt = math.max(
		now + exponentialDelay,
		finite_number(notBefore, 0)
	)
	return attempt, math.max(0, nextAttemptAt - now), nextAttemptAt
end

function Recovery.observe_transport_failure(state, now, baseDelay, maxDelay)
	state = type(state) == "table" and state or {}
	now = finite_number(now, 0)
	local nextProbeAt = finite_number(state.nextProbeAt, 0)
	if state.unavailable == true and now < nextProbeAt then
		return state, false, math.max(0, nextProbeAt - now)
	end

	local attempt, delay
	attempt, delay, nextProbeAt = Recovery.schedule(
		state.attempt,
		now,
		baseDelay,
		maxDelay
	)
	state.unavailable = true
	state.attempt = attempt
	state.nextProbeAt = nextProbeAt
	return state, true, delay
end

function Recovery.observe_transport_success(state)
	state = type(state) == "table" and state or {}
	local changed = state.unavailable == true
		or finite_number(state.attempt, 0) ~= 0
		or finite_number(state.nextProbeAt, 0) ~= 0
	state.unavailable = false
	state.attempt = 0
	state.nextProbeAt = 0
	return state, changed
end

function Recovery.watchdogs_allowed(state)
	return type(state) ~= "table" or state.unavailable ~= true
end

return Recovery
