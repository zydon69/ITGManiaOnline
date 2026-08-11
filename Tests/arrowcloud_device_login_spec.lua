local sourceRoot = assert(arg[1], "source root is required")
local deviceLogin = assert(dofile(
	sourceRoot .. "/Themes/Simply Love/Scripts/02 SL-ArrowCloudDeviceLogin.lua"
))

local function equal(actual, expected, label)
	assert(actual == expected, (label or "value")
		.. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
end

equal(deviceLogin.has_in_flight({ P1 = { status = "starting" } }), true,
	"the polling scheduler survives a slow device-login start request")
equal(deviceLogin.has_in_flight({ P1 = { status = "waiting" } }), true,
	"the polling scheduler remains active while approval is pending")
equal(deviceLogin.has_in_flight({ P1 = { status = "success" } }), false,
	"the polling scheduler stops after successful consumption")

local outcome = deviceLogin.poll_outcome({
	status = "approved",
	pollIntervalSeconds = 4,
})
equal(outcome.kind, "retry", "browser approval remains pollable until credentials are consumed")
equal(outcome.intervalSeconds, 4, "server polling interval is honored")

outcome = deviceLogin.poll_outcome({ status = "consumed", apiKey = "secret" })
equal(outcome.kind, "success", "consumed credentials complete device login")
equal(outcome.apiKey, "secret", "the consumed API key reaches profile persistence")

outcome = deviceLogin.poll_outcome({ status = "consumed" })
equal(outcome.kind, "failure", "a consumed response without credentials fails closed")

print("arrowcloud device login spec: ok")
