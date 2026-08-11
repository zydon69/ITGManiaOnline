ArrowCloudDeviceLogin = ArrowCloudDeviceLogin or {}

local DeviceLogin = ArrowCloudDeviceLogin

function DeviceLogin.is_in_flight(status)
	return status == "starting" or status == "waiting"
end

function DeviceLogin.has_in_flight(states)
	if type(states) ~= "table" then return false end

	for _, state in pairs(states) do
		if type(state) == "table" and DeviceLogin.is_in_flight(state.status) then
			return true
		end
	end

	return false
end

function DeviceLogin.poll_outcome(body)
	if type(body) ~= "table" then
		return { kind = "retry", status = "invalid_response" }
	end

	local status = tostring(body.status or "pending"):lower()
	if status == "pending" or status == "approved" then
		return {
			kind = "retry",
			status = status,
			intervalSeconds = tonumber(body.pollIntervalSeconds),
		}
	end

	if status == "consumed" then
		local apiKey = tostring(body.apiKey or "")
		if apiKey ~= "" then
			return { kind = "success", status = status, apiKey = apiKey }
		end
		return { kind = "failure", status = status, reason = "missing_api_key" }
	end

	if status == "expired" or status == "cancelled" then
		return { kind = "failure", status = status, reason = status }
	end

	-- A new non-terminal server state must not silently stop device-login polling.
	return { kind = "retry", status = status }
end

return DeviceLogin
