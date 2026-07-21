local function is_connected()
	return ITGOnline
		and ITGOnline.HasActiveAccessToken
		and ITGOnline:HasActiveAccessToken()
		and ITGOnline.user ~= nil
end

local function has_stored_access_token()
	return ITGOnline
		and ITGOnline.ShouldRememberTokenForCurrentProfile
		and ITGOnline:ShouldRememberTokenForCurrentProfile()
		and ITGOnline.HasStoredAccessToken
		and ITGOnline:HasStoredAccessToken()
end

local function is_two_player_online_requested()
	local joined = 0
	for player in ivalues(GAMESTATE:GetEnabledPlayers()) do
		if GAMESTATE:IsSideJoined(player) then
			joined = joined + 1
		end
	end
	return joined > 1
end

local function qr_encoder()
	local path = THEME:GetPathB("", "_modules/QR Code/qrencode.lua")
	local chunk = loadfile(path)
	if not chunk then return nil end
	local ok, module = pcall(chunk)
	if not ok or type(module) ~= "table" or type(module.qrcode) ~= "function" then
		return nil
	end
	return module
end

local function build_qr_vertices(url, size)
	if type(url) ~= "string" or #url == 0 or #url > 512 then return nil, nil end
	local encoder = qr_encoder()
	if not encoder then return nil, nil end
	local ok, qrOk, modules = pcall(encoder.qrcode, url)
	if not ok or not qrOk or type(modules) ~= "table" then return nil, nil end

	if #modules == 0 or #modules > 177 then return nil, nil end
	local verts = {}
	for c, column in ipairs(modules) do
		if type(column) ~= "table" or #column ~= #modules then return nil, nil end
		for m, module in ipairs(column) do
			local color = (module > 0) and Color.Black or Color.White
			verts[#verts + 1] = { { m - 1, c - 1, 0 }, color }
			verts[#verts + 1] = { { m, c - 1, 0 }, color }
			verts[#verts + 1] = { { m, c, 0 }, color }
			verts[#verts + 1] = { { m - 1, c, 0 }, color }
		end
	end

	return verts, size / #modules
end

local function trusted_verification_url(value)
	value = tostring(value or "")
	if #value == 0 or #value > 512 or value:find("[%c]") then return nil end
	local scheme, host = value:match("^(https)://([^/%?#:]+)")
	if scheme ~= "https" or not host then return nil end
	local config = ITGOnline and ITGOnline.ConnectionConfig and ITGOnline:ConnectionConfig() or {}
	local expectedHost = tostring(config.apiBaseUrl or ""):match("^https://([^/%?#:]+)")
	if not expectedHost or host:lower() ~= expectedHost:lower() then return nil end
	return value
end

local function normalize_short_code(value)
	value = tostring(value or ""):upper()
	if value:match("^[A-F0-9][A-F0-9][A-F0-9][A-F0-9][A-F0-9][A-F0-9][A-F0-9][A-F0-9]$") then
		return value
	end
	return ""
end

local state = {
	mode = "idle",
	status = "",
	shortCode = "",
	sessionId = nil,
	pollToken = nil,
	verificationUrl = nil,
	pollIntervalSeconds = 3,
	nextPollAt = 0,
	expiresAt = nil,
	polling = false,
	connecting = false,
	startRequestedAt = 0,
	startAttempts = 0,
	attemptGeneration = 0,
	screenActive = false,
}

local function login_flow_trace(message)
	if type(online_logs_enabled) == "function" and not online_logs_enabled("auth") then
		return
	end
	if type(online_trace) == "function" then
		online_trace("login_flow " .. tostring(message or ""), "auth")
	end
end

local function login_state_summary()
	return " mode=" .. tostring(state.mode)
		.. " connected=" .. tostring(is_connected())
		.. " hasStoredToken=" .. tostring(has_stored_access_token())
		.. " session=" .. tostring(state.sessionId ~= nil and state.sessionId ~= "")
		.. " pollToken=" .. tostring(state.pollToken ~= nil and state.pollToken ~= "")
		.. " polling=" .. tostring(state.polling)
		.. " connecting=" .. tostring(state.connecting)
		.. " attempts=" .. tostring(state.startAttempts)
		.. " generation=" .. tostring(state.attemptGeneration)
		.. " screenActive=" .. tostring(state.screenActive)
end

local function invalidate_login_attempt(reason)
	state.attemptGeneration = (tonumber(state.attemptGeneration) or 0) + 1
	state.startRequestedAt = 0
	state.polling = false
	login_flow_trace("invalidate_attempt reason=" .. tostring(reason or "unknown") .. login_state_summary())
	return state.attemptGeneration
end

local function attempt_is_current(generation)
	return state.screenActive == true
		and tonumber(generation) == tonumber(state.attemptGeneration)
end

local function safe_screen_text_width()
	return math.max(280, math.min(760, _screen.w - 80))
end

local function safe_qr_panel_width()
	return math.max(260, math.min(300, _screen.w - 40))
end

local function refresh()
	MESSAGEMAN:Broadcast("ITGOnlineLoginStateChanged")
end

local function set_status(text)
	text = tostring(text or "")
	if state.status == text then return end
	login_flow_trace("status_change from=" .. tostring(state.status) .. " to=" .. text .. login_state_summary())
	state.status = text
	refresh()
end

local function response_status_code(response)
	return type(response) == "table" and tonumber(response.statusCode) or nil
end

local function response_error_text(decoded, response)
	if type(decoded) == "table" and tostring(decoded.message or "") ~= "" then
		return tostring(decoded.message)
	end
	if type(response) == "table" then
		return tostring(response.errorMessage or response.message or "")
	end
	return ""
end

local function response_error_code(decoded, response)
	if type(decoded) == "table" then
		local code = tostring(decoded.error_code or decoded.code or "")
		if code ~= "" then return code end
	end
	if type(response) == "table" then
		return tostring(response.error_code or response.errorCode or response.code or "")
	end
	return ""
end

local function authentication_was_rejected(response)
	return response_status_code(response) == 401
		or response_error_code(nil, response) == "profile_token_user_mismatch"
end

local function friendly_login_error(decoded, response, fallbackKey)
	local detail = response_error_text(decoded, response)
	local lowerDetail = detail:lower()
	if response_error_code(decoded, response) == "profile_token_user_mismatch" then
		return THEME:GetString("ScreenITGOnlineLogin", "ProfileTokenMismatch")
	end
	if lowerDetail:find("public key pinning", 1, true)
		or lowerDetail:find("public key pin", 1, true)
	then
		return THEME:GetString("ScreenITGOnlineLogin", "SecureConnectionFailed")
	end

	local statusCode = response_status_code(response)
	if statusCode == nil or statusCode == 0
		or lowerDetail:find("cannot connect", 1, true)
		or lowerDetail:find("timed out", 1, true)
		or lowerDetail:find("timeout", 1, true)
	then
		return THEME:GetString("ScreenITGOnlineLogin", "ConnectionFailed")
	end

	-- Server validation messages are useful when short and safe to render.  Raw
	-- transport diagnostics remain in the gated logs instead of the UI.
	if detail ~= "" and #detail <= 160 and not detail:find("[%c]") then
		return detail
	end
	return THEME:GetString("ScreenITGOnlineLogin", fallbackKey or "ConnectionFailed")
end

local function clear_session()
	login_flow_trace("clear_session" .. login_state_summary())
	state.sessionId = nil
	state.pollToken = nil
	state.verificationUrl = nil
	state.shortCode = ""
	state.polling = false
	state.pollIntervalSeconds = 3
	state.nextPollAt = 0
	state.expiresAt = nil
end

local function go_back()
	login_flow_trace("go_back begin" .. login_state_summary())
	invalidate_login_attempt("go_back")
	if is_connected() then
		ITGOnline:Disconnect()
	end
	SL.Global.ITGOnline = SL.Global.ITGOnline or {}
	SL.Global.ITGOnline.Enabled = false
	login_flow_trace("go_back screen=ScreenSelectOnlineMode")
	SCREENMAN:SetNewScreen("ScreenSelectOnlineMode")
end

local start_device_login

local function connect_to_lobbies(generation)
	if not attempt_is_current(generation) then return end
	login_flow_trace("websocket_connect_begin" .. login_state_summary())
	ITGOnline:ConnectWebSocket({
		open = function()
			if not attempt_is_current(generation) then return end
			state.connecting = false
			state.mode = "connected"
			login_flow_trace("websocket_open screen=ScreenOnlineLobbies" .. login_state_summary())
			set_status(THEME:GetString("ScreenITGOnlineLogin", "Connected"))
			SCREENMAN:SetNewScreen("ScreenOnlineLobbies")
		end,
			error = function(message)
			if not attempt_is_current(generation) then return end
			state.connecting = false
			login_flow_trace("websocket_error message=" .. tostring(message) .. login_state_summary())
				-- A transport outage does not invalidate a previously validated token.
				state.mode = "idle"
				set_status(tostring(message or THEME:GetString("ScreenITGOnlineLogin", "ConnectionFailed")))
			end,
		close = function(reason)
			if not attempt_is_current(generation) then return end
			state.connecting = false
			login_flow_trace("websocket_close reason=" .. tostring(reason) .. login_state_summary())
			set_status(tostring(reason or THEME:GetString("ScreenITGOnlineLogin", "Disconnected")))
		end,
	})
end

local function finish_token_connection(generation)
	return function(ok, user, response)
		if not attempt_is_current(generation) then return end
		local userId = type(user) == "table" and (user.id or user.user_id) or nil
		login_flow_trace("apply_access_token result ok=" .. tostring(ok)
			.. " userId=" .. tostring(userId)
			.. " responseMessage=" .. tostring(response and response.message)
			.. login_state_summary())
		if not ok then
			state.connecting = false
			clear_session()
			state.mode = "failed"
			set_status(friendly_login_error(nil, response, "ConnectionFailed"))
			if authentication_was_rejected(response) then
				-- Only an explicit authentication rejection proves the saved token
				-- unusable.  TLS, DNS and timeout failures must preserve it.
				ITGOnline:ClearStoredAccessToken()
				state.mode = "idle"
				start_device_login()
			end
			return
		end

		local sessionId = state.sessionId
		local pollToken = state.pollToken
		if tostring(sessionId or "") ~= "" and tostring(pollToken or "") ~= "" then
			ITGOnline:AcknowledgeDeviceLogin(sessionId, pollToken, function(ackOk, decoded, ackResponse)
				login_flow_trace("device_login_acknowledge result ok=" .. tostring(ackOk)
					.. " acknowledged=" .. tostring(decoded and decoded.acknowledged)
					.. " responseError=" .. tostring(ackResponse and ackResponse.errorMessage))
			end)
		end
		clear_session()
		connect_to_lobbies(generation)
	end
end

local function prepare_token_connection(generation, source)
	generation = generation or state.attemptGeneration
	if not attempt_is_current(generation) then return nil end
	state.mode = "connecting"
	state.connecting = true
	login_flow_trace("connect_with_token begin source=" .. tostring(source) .. " tokenPresent=true" .. login_state_summary())
	set_status(THEME:GetString("ScreenITGOnlineLogin", "Connecting"))
	return generation
end

local function connect_with_token(accessToken, generation)
	generation = generation or state.attemptGeneration
	if tostring(accessToken or "") == "" then
		login_flow_trace("connect_with_token rejected empty_token" .. login_state_summary())
		set_status(THEME:GetString("ScreenITGOnlineLogin", "DeviceLoginUnavailable"))
		return
	end
	if not prepare_token_connection(generation, "device_login") then return end
	ITGOnline:ApplyAccessToken(accessToken, finish_token_connection(generation))
end

local function connect_with_stored_token(generation)
	generation = generation or state.attemptGeneration
	if not prepare_token_connection(generation, "credential_store") then return end
	if not ITGOnline:ApplyStoredAccessToken(finish_token_connection(generation)) then
		state.connecting = false
		state.mode = "idle"
		start_device_login()
	end
end

start_device_login = function(resetAttempts)
	if state.connecting or state.polling or state.mode == "starting" or state.mode == "waiting" then
		login_flow_trace("start_device_login skipped busy resetAttempts=" .. tostring(resetAttempts) .. login_state_summary())
		return
	end
	if is_two_player_online_requested() then
		login_flow_trace("start_device_login blocked two_player_requested" .. login_state_summary())
		set_status(THEME:GetString("ScreenITGOnlineLogin", "TwoPlayerNotice"))
		return
	end

	if resetAttempts then
		state.startAttempts = 0
	end
	local generation = invalidate_login_attempt("start_device_login")
	state.mode = "starting"
	clear_session()
	state.startAttempts = (tonumber(state.startAttempts) or 0) + 1
	state.startRequestedAt = GetTimeSinceStart()
	login_flow_trace("start_device_login begin resetAttempts=" .. tostring(resetAttempts) .. login_state_summary())
	set_status(THEME:GetString("ScreenITGOnlineLogin", "QrStarting"))
	ITGOnline:StartDeviceLogin(function(ok, decoded, response)
		if not attempt_is_current(generation) then
			login_flow_trace("start_device_login result ignored reason=stale" .. login_state_summary())
			return
		end
		state.startRequestedAt = 0
		login_flow_trace("start_device_login result ok=" .. tostring(ok)
			.. " hasDecoded=" .. tostring(decoded ~= nil)
			.. " responseError=" .. tostring(response and response.errorMessage)
			.. login_state_summary())
		if not ok or not decoded then
			state.mode = "failed"
			set_status(friendly_login_error(decoded, response, "DeviceLoginUnavailable"))
			return
		end

		state.sessionId = tostring(decoded.sessionId or "")
		state.pollToken = tostring(decoded.pollToken or "")
			state.verificationUrl = trusted_verification_url(decoded.verificationUrl)
			if not state.verificationUrl then
				clear_session()
				state.mode = "failed"
				set_status(THEME:GetString("ScreenITGOnlineLogin", "DeviceLoginUnavailable"))
				login_flow_trace("start_device_login rejected untrusted_verification_url" .. login_state_summary())
				return
			end
		state.shortCode = normalize_short_code(decoded.shortCode)
		state.pollIntervalSeconds = tonumber(decoded.pollIntervalSeconds) or 3
		state.expiresAt = tostring(decoded.expiresAt or "")
		state.nextPollAt = GetTimeSinceStart() + 0.25
		state.mode = "waiting"
		login_flow_trace("start_device_login waiting shortCode=" .. tostring(state.shortCode)
			.. " pollInterval=" .. tostring(state.pollIntervalSeconds)
			.. " expiresAt=" .. tostring(state.expiresAt)
			.. " verificationUrlPresent=" .. tostring(state.verificationUrl ~= "")
			.. login_state_summary())
		set_status(THEME:GetString("ScreenITGOnlineLogin", "QrWaiting"))
	end)
end

local function poll_device_login()
	if state.mode ~= "waiting" or state.polling then return end
	if not state.sessionId or not state.pollToken then return end
	if state.nextPollAt and GetTimeSinceStart() < state.nextPollAt then return end

	local generation = state.attemptGeneration
	local sessionId = state.sessionId
	local pollToken = state.pollToken
	state.polling = true
	login_flow_trace("poll_device_login begin" .. login_state_summary())
	ITGOnline:PollDeviceLogin(sessionId, pollToken, function(ok, decoded, response)
		if not attempt_is_current(generation)
			or state.sessionId ~= sessionId
			or state.pollToken ~= pollToken
		then
			login_flow_trace("poll_device_login result ignored reason=stale" .. login_state_summary())
			return
		end
		state.polling = false
		login_flow_trace("poll_device_login result ok=" .. tostring(ok)
			.. " hasDecoded=" .. tostring(decoded ~= nil)
			.. " status=" .. tostring(decoded and decoded.status)
			.. " responseError=" .. tostring(response and response.errorMessage)
			.. login_state_summary())
		if not ok or not decoded then
			state.nextPollAt = GetTimeSinceStart() + (state.pollIntervalSeconds or 3)
			login_flow_trace("poll_device_login retry_after_error nextPollAt=" .. tostring(state.nextPollAt) .. login_state_summary())
			return
		end

		local pollStatus = tostring(decoded.status or "pending")
		if pollStatus == "pending" then
			state.nextPollAt = GetTimeSinceStart() + (state.pollIntervalSeconds or 3)
			login_flow_trace("poll_device_login pending nextPollAt=" .. tostring(state.nextPollAt) .. login_state_summary())
			set_status(THEME:GetString("ScreenITGOnlineLogin", "QrWaiting"))
			return
		end

		if pollStatus == "expired" or pollStatus == "cancelled" then
			state.mode = "failed"
			login_flow_trace("poll_device_login terminal status=" .. tostring(pollStatus) .. login_state_summary())
			clear_session()
			set_status(THEME:GetString("ScreenITGOnlineLogin", "QrExpired"))
			return
		end

		if pollStatus == "consumed" and tostring(decoded.apiKey or "") ~= "" then
			state.mode = "connecting"
			login_flow_trace("poll_device_login consumed tokenPresent=true" .. login_state_summary())
			set_status(THEME:GetString("ScreenITGOnlineLogin", "Connecting"))
			connect_with_token(tostring(decoded.apiKey), generation)
			return
		end

		state.nextPollAt = GetTimeSinceStart() + (state.pollIntervalSeconds or 3)
		login_flow_trace("poll_device_login unhandled_status status=" .. tostring(pollStatus)
			.. " nextPollAt=" .. tostring(state.nextPollAt)
			.. login_state_summary())
	end)
end

local function action_connect()
	login_flow_trace("action_connect" .. login_state_summary())
	if is_connected() then
		login_flow_trace("action_connect already_connected screen=ScreenOnlineLobbies")
		SCREENMAN:SetNewScreen("ScreenOnlineLobbies")
		return
	end

	if has_stored_access_token() then
		login_flow_trace("action_connect stored_token")
		connect_with_stored_token()
		return
	end

	start_device_login(true)
end

local function action_disconnect()
	login_flow_trace("action_disconnect begin" .. login_state_summary())
	invalidate_login_attempt("action_disconnect")
	ITGOnline:Disconnect({ revokeToken = true })
	ITGOnline:ClearStoredAccessToken()
	clear_session()
	state.mode = "idle"
	set_status(THEME:GetString("ScreenITGOnlineLogin", "Disconnected"))
	login_flow_trace("action_disconnect restarting_device_login")
	start_device_login()
end

local function current_rows()
	if is_connected() then
		return { "Continue", "Disconnect", "Back" }
	end
	return { "Connect", "Disconnect", "Back" }
end

local selection = 1
local lastMenuText = nil
local lastQrUrl = nil
local lastQrVerts = nil
local lastQrPixelSize = nil
local lastRenderedQrUrl = nil
local lastRenderedQrVisible = nil
local lastStatusText = nil
local lastUrlText = nil

local function refresh_selection()
	local rows = current_rows()
	if selection > #rows then
		selection = #rows
	end
	login_flow_trace("selection_refresh selection=" .. tostring(selection)
		.. " rows=" .. table.concat(rows, ",")
		.. login_state_summary())
	refresh()
end

local function selected_action()
	local rows = current_rows()
	return rows[selection]
end

local function render_qr(panel)
	local outer = panel:GetChild("QROuter")
	local border = panel:GetChild("QRBorder")
	local inset = panel:GetChild("QRInset")
	local data = panel:GetChild("QRCodeData")
	local status = panel:GetChild("Status")
	local code = panel:GetChild("Code")
	local url = panel:GetChild("Url")

	local showQr = state.mode == "waiting" and state.verificationUrl and state.verificationUrl ~= ""
	if showQr then
		if state.verificationUrl ~= lastQrUrl then
			lastQrUrl = state.verificationUrl
			lastQrVerts, lastQrPixelSize = build_qr_vertices(state.verificationUrl, 124)
			lastRenderedQrUrl = nil
		end

		if lastQrVerts and data then
			if lastRenderedQrVisible ~= true then
				if outer then outer:visible(true) end
				if border then border:visible(true) end
				if inset then inset:visible(true) end
				data:visible(true)
				lastRenderedQrVisible = true
			end
			if lastRenderedQrUrl ~= state.verificationUrl then
				data:SetVertices(lastQrVerts)
				data:zoom(lastQrPixelSize)
				lastRenderedQrUrl = state.verificationUrl
			end
		end
	else
		if lastRenderedQrVisible ~= false then
			if outer then outer:visible(false) end
			if border then border:visible(false) end
			if inset then inset:visible(false) end
			if data then data:visible(false) end
			lastRenderedQrVisible = false
		end
	end

	if status then
		local statusText
		if state.status ~= "" then
			statusText = state.status
		elseif is_connected() then
			local displayName = ITGOnline and ITGOnline.UserDisplayName and ITGOnline:UserDisplayName(ITGOnline.user, ITGOnline.user and ITGOnline.user.email or "ITG Online") or "ITG Online"
			statusText = THEME:GetString("ScreenITGOnlineLogin", "ConnectedAs"):format(tostring(displayName))
		else
			statusText = THEME:GetString("ScreenITGOnlineLogin", "NotConnected")
		end
		if statusText ~= lastStatusText then
			status:settext(statusText)
			lastStatusText = statusText
		end
	end

	if url then
		local urlText = ""
		if urlText ~= lastUrlText then
			url:settext(urlText)
			lastUrlText = urlText
		end
	end

	if code then
		local codeText = normalize_short_code(state.shortCode)
		code:settext(codeText ~= "" and ("CODE: " .. codeText) or "")
	end
end

local function input(event)
	if not event.button then return false end
	if event.type ~= "InputEventType_FirstPress" then return false end

	local rows = current_rows()
	if event.GameButton == "MenuUp" or event.GameButton == "MenuLeft" then
		selection = ((selection - 2) % #rows) + 1
		refresh_selection()
	elseif event.GameButton == "MenuDown" or event.GameButton == "MenuRight" then
		selection = (selection % #rows) + 1
		refresh_selection()
	elseif event.GameButton == "Start" then
		local action = selected_action()
		login_flow_trace("input_start action=" .. tostring(action)
			.. " selection=" .. tostring(selection)
			.. login_state_summary())
		if action == "Connect" or action == "Continue" then
			action_connect()
		elseif action == "Disconnect" then
			action_disconnect()
		elseif action == "Back" then
			go_back()
		end
	elseif event.GameButton == "Back" then
		login_flow_trace("input_back" .. login_state_summary())
		go_back()
	end
end

local t = Def.ActorFrame{
	InitCommand=function(self) self:Center() end,
	OnCommand=function(self)
		state.screenActive = true
		invalidate_login_attempt("screen_on")
		if not is_connected() then
			clear_session()
			state.mode = "idle"
			state.connecting = false
		end
		login_flow_trace("screen_on" .. login_state_summary())
		local topScreen = SCREENMAN:GetTopScreen()
		if topScreen then
			topScreen:AddInputCallback(input)
		end
		selection = 1
		self:sleep(0.2):queuecommand("AutoConnect")
		self:playcommand("Refresh")
		self:sleep(0.25):queuecommand("Tick")
	end,
	AutoConnectCommand=function(self)
		if not state.screenActive then return end
		login_flow_trace("auto_connect begin" .. login_state_summary())
		if is_connected() then
			state.mode = "connected"
			login_flow_trace("auto_connect already_connected" .. login_state_summary())
			set_status(THEME:GetString("ScreenITGOnlineLogin", "Connected"))
		elseif has_stored_access_token() then
			state.mode = "connecting"
			login_flow_trace("auto_connect stored_token" .. login_state_summary())
			set_status(THEME:GetString("ScreenITGOnlineLogin", "Connecting"))
			connect_with_stored_token(state.attemptGeneration)
		else
			login_flow_trace("auto_connect start_device_login" .. login_state_summary())
			start_device_login(true)
		end
		self:playcommand("Refresh")
	end,
	ITGOnlineLoginStateChangedMessageCommand=function(self)
		self:playcommand("Refresh")
	end,
	OffCommand=function(self)
		login_flow_trace("screen_off" .. login_state_summary())
		state.screenActive = false
		invalidate_login_attempt("screen_off")
		local topScreen = SCREENMAN:GetTopScreen()
		if topScreen then
			pcall(function() topScreen:RemoveInputCallback(input) end)
		end
	end,
	CancelCommand=function(self)
		go_back()
	end,
	TickCommand=function(self)
			if not state.screenActive then return end
		if state.mode == "starting"
			and (tonumber(state.startRequestedAt) or 0) > 0
			and GetTimeSinceStart() - (tonumber(state.startRequestedAt) or 0) > 2.0
		then
			if (tonumber(state.startAttempts) or 0) < 3 then
				login_flow_trace("start_device_login timeout_retry" .. login_state_summary())
				clear_session()
				state.mode = "idle"
				start_device_login()
			else
				state.startRequestedAt = 0
				state.mode = "failed"
				login_flow_trace("start_device_login timeout_failed" .. login_state_summary())
				set_status(THEME:GetString("ScreenITGOnlineLogin", "DeviceLoginUnavailable"))
			end
		end
			if state.mode == "waiting" then
				local remainingSeconds = ITGOnline and ITGOnline.SecondsUntilServerTimestamp
					and ITGOnline:SecondsUntilServerTimestamp(state.expiresAt)
				if remainingSeconds ~= nil and remainingSeconds <= 0 then
					state.mode = "failed"
					clear_session()
					login_flow_trace("device_login_expired_local" .. login_state_summary())
					set_status(THEME:GetString("ScreenITGOnlineLogin", "QrExpired"))
				else
				poll_device_login()
				end
			end
			local rows = current_rows()
			if selection > #rows then
				selection = #rows
				refresh()
			end
			self:sleep(0.25):queuecommand("Tick")
		end,
	RefreshCommand=function(self)
		local panel = self:GetChild("QrPanel")
		if panel then
			render_qr(panel)
		end
		local rows = current_rows()
		local labels = {}
		for i, row in ipairs(rows) do
			local label = THEME:GetString("ScreenITGOnlineLogin", row)
			if i == selection then
				label = "> " .. label .. " <"
			end
			labels[#labels + 1] = label
		end
			local menu = self:GetChild("MenuRow")
			local menuText = table.concat(labels, "    ")
			if menu and menuText ~= lastMenuText then
				menu:settext(menuText)
				lastMenuText = menuText
			end
		end,

	Def.Quad{
		InitCommand=function(self) self:xy(0, 0):zoomto(_screen.w, _screen.h):diffuse(0,0,0,0.82) end
	},

	LoadFont("Common Bold")..{
		Text=THEME:GetString("ScreenITGOnlineLogin", "Title"),
		InitCommand=function(self) self:xy(0, -160):horizalign(center):zoom(0.62):maxwidth(safe_screen_text_width()):diffuse(PlayerColor(PLAYER_1)) end
	},

	LoadFont("Common Normal")..{
		Text=THEME:GetString("ScreenITGOnlineLogin", "QrInstructions"),
		InitCommand=function(self) self:xy(0, -122):horizalign(center):zoom(0.72):maxwidth(safe_screen_text_width()) end,
	},

	Def.ActorFrame{
		Name="QrPanel",
		InitCommand=function(self) self:xy(0, -6) end,
		Def.Quad{ InitCommand=function(self) self:zoomto(safe_qr_panel_width(), 270):diffuse(1,1,1,0.12) end },
		Def.Quad{ InitCommand=function(self) self:zoomto(math.max(256, safe_qr_panel_width() - 4), 266):diffuse(0.09,0.09,0.1,0.98) end },
		Def.Quad{ InitCommand=function(self) self:y(-112):zoomto(safe_qr_panel_width(), 32):diffuse(0.14,0.14,0.16,1) end },
		LoadFont("Common Bold")..{
			InitCommand=function(self) self:y(-112):zoom(0.5):maxwidth(safe_qr_panel_width() - 32):settext(THEME:GetString("ScreenITGOnlineLogin", "Title")) end
		},
		Def.Quad{ Name="QROuter", InitCommand=function(self) self:zoomto(144, 144):xy(0, -10):diffuse(Color.Black):visible(false) end },
		Def.Quad{ Name="QRInset", InitCommand=function(self) self:zoomto(136, 136):xy(0, -10):diffuse(Color.Black):visible(false) end },
		Def.Quad{ Name="QRBorder", InitCommand=function(self) self:zoomto(140, 140):xy(0, -10):diffuse(Color.White):visible(false) end },
		Def.ActorMultiVertex{
			Name="QRCodeData",
			InitCommand=function(self) self:SetDrawState({ Mode = "DrawMode_Quads" }):xy(-62, -72):visible(false) end
		},
		LoadFont("Common Normal")..{
			Name="Status",
			InitCommand=function(self)
				self:xy(0, 88):horizalign(center):zoom(0.56)
					:_wrapwidthpixels((safe_qr_panel_width() - 24) / 0.56)
					:vertspacing(-5):maxheight(38 / 0.56):settext("")
			end
		},
		LoadFont("Common Normal")..{
			Name="Code",
			InitCommand=function(self)
				self:xy(0, 116):horizalign(center):zoom(0.74):maxwidth(286)
					:diffuse(1, 1, 1, 1):strokecolor(0, 0, 0, 1):settext("")
			end
		},
		LoadFont("Common Normal")..{
			Name="Url",
			InitCommand=function(self) self:xy(0, 148):horizalign(center):zoom(0.28):maxwidth(250):settext("") end
		},
	},

	LoadFont("Common Normal")..{
		Text=THEME:GetString("ScreenITGOnlineLogin", "Help"),
		InitCommand=function(self) self:xy(0, 164):horizalign(center):zoom(0.56):maxwidth(safe_screen_text_width()):diffuse(0.8,0.8,0.8,1) end,
	},

	LoadFont("Common Normal")..{
		Name="MenuRow",
		InitCommand=function(self) self:xy(0, 198):horizalign(center):zoom(0.72):maxwidth(safe_screen_text_width()) end,
		ITGOnlineLoginStateChangedMessageCommand=function(self) self:playcommand("Refresh") end,
	},
}

return t
