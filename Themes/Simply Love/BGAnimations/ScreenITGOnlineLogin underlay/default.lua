local function required_players()
	if ITGOnline and ITGOnline.JoinedLocalPlayers then
		local players = ITGOnline:JoinedLocalPlayers()
		if type(players) == "table" and #players > 0 then return players end
	end
	return { PLAYER_1 }
end

local function player_key(player)
	if ITGOnline and ITGOnline.LocalPlayerKey then
		return ITGOnline:LocalPlayerKey(player)
	end
	return player == PLAYER_2 and "P2" or "P1"
end

local function player_from_key(key)
	return key == "P2" and PLAYER_2 or PLAYER_1
end

local function player_is_required(player)
	for _, requiredPlayer in ipairs(required_players()) do
		if requiredPlayer == player then return true end
	end
	return false
end

local function is_connected(player)
	return ITGOnline
		and ITGOnline.HasActiveAccessTokenForPlayer
		and ITGOnline:HasActiveAccessTokenForPlayer(player)
		and ITGOnline.UserForLocalPlayer
		and ITGOnline:UserForLocalPlayer(player) ~= nil
end

local function has_stored_access_token(player)
	return ITGOnline
		and ITGOnline.ShouldRememberTokenForPlayer
		and ITGOnline:ShouldRememberTokenForPlayer(player)
		and ITGOnline.HasStoredAccessTokenForPlayer
		and ITGOnline:HasStoredAccessTokenForPlayer(player)
end

local function all_required_players_connected()
	local players = required_players()
	if #players == 0 then return false end
	for _, player in ipairs(players) do
		if not is_connected(player) then return false end
	end
	return true
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

	local vertices = {}
	for columnIndex, column in ipairs(modules) do
		if type(column) ~= "table" or #column ~= #modules then return nil, nil end
		for moduleIndex, module in ipairs(column) do
			local color = module > 0 and Color.Black or Color.White
			vertices[#vertices + 1] = { { moduleIndex - 1, columnIndex - 1, 0 }, color }
			vertices[#vertices + 1] = { { moduleIndex, columnIndex - 1, 0 }, color }
			vertices[#vertices + 1] = { { moduleIndex, columnIndex, 0 }, color }
			vertices[#vertices + 1] = { { moduleIndex - 1, columnIndex, 0 }, color }
		end
	end
	return vertices, size / #modules
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
	return value:match("^[A-F0-9][A-F0-9][A-F0-9][A-F0-9][A-F0-9][A-F0-9][A-F0-9][A-F0-9]$")
		and value or ""
end

local function new_player_state(player)
	return {
		player = player,
		key = player_key(player),
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
		lastQrUrl = nil,
		lastQrVerts = nil,
		lastQrPixelSize = nil,
		lastRenderedQrUrl = nil,
		lastRenderedQrVisible = nil,
		lastStatusText = nil,
	}
end

local states = {
	P1 = new_player_state(PLAYER_1),
	P2 = new_player_state(PLAYER_2),
}
local screenActive = false
local partyConnecting = false
local selection = 1
local lastMenuText = nil

local function login_flow_trace(state, message)
	if type(online_logs_enabled) == "function" and not online_logs_enabled("auth") then return end
	if type(online_trace) == "function" then
		online_trace("login_flow localPlayer=" .. tostring(state and state.key or "party")
			.. " " .. tostring(message or ""), "auth")
	end
end

local function state_summary(state)
	return " mode=" .. tostring(state.mode)
		.. " connected=" .. tostring(is_connected(state.player))
		.. " stored=" .. tostring(has_stored_access_token(state.player))
		.. " session=" .. tostring(tostring(state.sessionId or "") ~= "")
		.. " polling=" .. tostring(state.polling)
		.. " connecting=" .. tostring(state.connecting)
		.. " attempts=" .. tostring(state.startAttempts)
		.. " generation=" .. tostring(state.attemptGeneration)
		.. " screenActive=" .. tostring(screenActive)
end

local function refresh()
	MESSAGEMAN:Broadcast("ITGOnlineLoginStateChanged")
end

local function set_status(state, text)
	text = tostring(text or "")
	if state.status == text then return end
	login_flow_trace(state, "status_change from=" .. tostring(state.status)
		.. " to=" .. text .. state_summary(state))
	state.status = text
	refresh()
end

local function invalidate_attempt(state, reason)
	state.attemptGeneration = (tonumber(state.attemptGeneration) or 0) + 1
	state.startRequestedAt = 0
	state.polling = false
	login_flow_trace(state, "invalidate reason=" .. tostring(reason or "unknown") .. state_summary(state))
	return state.attemptGeneration
end

local function attempt_is_current(state, generation)
	return screenActive
		and player_is_required(state.player)
		and tonumber(generation) == tonumber(state.attemptGeneration)
end

local function clear_device_session(state)
	state.sessionId = nil
	state.pollToken = nil
	state.verificationUrl = nil
	state.shortCode = ""
	state.polling = false
	state.pollIntervalSeconds = 3
	state.nextPollAt = 0
	state.expiresAt = nil
end

local function response_status_code(response)
	return type(response) == "table" and tonumber(response.statusCode) or nil
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

local function response_error_text(decoded, response)
	if type(decoded) == "table" and tostring(decoded.message or "") ~= "" then
		return tostring(decoded.message)
	end
	if type(response) == "table" then
		return tostring(response.errorMessage or response.message or "")
	end
	return ""
end

local function authentication_was_rejected(response)
	return response_status_code(response) == 401
		or response_error_code(nil, response) == "profile_token_user_mismatch"
		or response_error_code(nil, response) == "duplicate_local_online_identity"
end

local function friendly_login_error(decoded, response, fallbackKey)
	local detail = response_error_text(decoded, response)
	local lowerDetail = detail:lower()
	local errorCode = response_error_code(decoded, response)
	if errorCode == "profile_token_user_mismatch" then
		return THEME:GetString("ScreenITGOnlineLogin", "ProfileTokenMismatch")
	end
	if errorCode == "duplicate_local_online_identity" then
		return THEME:GetString("ScreenITGOnlineLogin", "ConnectionFailed")
	end
	if lowerDetail:find("public key pinning", 1, true)
		or lowerDetail:find("public key pin", 1, true) then
		return THEME:GetString("ScreenITGOnlineLogin", "SecureConnectionFailed")
	end
	local statusCode = response_status_code(response)
	if statusCode == nil or statusCode == 0
		or lowerDetail:find("cannot connect", 1, true)
		or lowerDetail:find("timed out", 1, true)
		or lowerDetail:find("timeout", 1, true) then
		return THEME:GetString("ScreenITGOnlineLogin", "ConnectionFailed")
	end
	return THEME:GetString("ScreenITGOnlineLogin", fallbackKey or "ConnectionFailed")
end

local start_device_login

local function connect_party_to_lobbies()
	if partyConnecting or not all_required_players_connected() then return end
	local valid, reason, side = ITGOnline:ValidateLocalPlayerIdentities()
	if not valid then
		local state = states[tostring(side or "P1")]
		if state then set_status(state, THEME:GetString("ScreenITGOnlineLogin", "ConnectionFailed")) end
		login_flow_trace(state, "party_validation_failed reason=" .. tostring(reason))
		return
	end

	partyConnecting = true
	login_flow_trace(nil, "party_websocket_connect_begin players=" .. tostring(#required_players()))
	local connect = ITGOnline.ConnectLocalPlayerPartyWebSockets or ITGOnline.ConnectWebSocket
	connect(ITGOnline, {
		open = function()
			if not screenActive then return end
			partyConnecting = false
			for _, player in ipairs(required_players()) do
				local state = states[player_key(player)]
				state.connecting = false
				state.mode = "connected"
				set_status(state, THEME:GetString("ScreenITGOnlineLogin", "Connected"))
			end
			login_flow_trace(nil, "party_websocket_open screen=ScreenOnlineLobbies")
			SCREENMAN:SetNewScreen("ScreenOnlineLobbies")
		end,
		error = function(message)
			if not screenActive then return end
			partyConnecting = false
			login_flow_trace(nil, "party_websocket_error message=" .. tostring(message))
			for _, player in ipairs(required_players()) do
				local state = states[player_key(player)]
				state.connecting = false
				if state.mode == "connecting" then state.mode = "idle" end
				set_status(state, tostring(message or THEME:GetString("ScreenITGOnlineLogin", "ConnectionFailed")))
			end
		end,
		close = function(reason)
			if not screenActive then return end
			partyConnecting = false
			login_flow_trace(nil, "party_websocket_close reason=" .. tostring(reason))
		end,
	})
end

local function finish_token_connection(state, generation)
	return function(ok, user, response)
		if not attempt_is_current(state, generation) then return end
		login_flow_trace(state, "apply_access_token result=" .. tostring(ok == true)
			.. " user=" .. tostring(user and (user.id or user.user_id) or "nil")
			.. state_summary(state))
		if not ok then
			state.connecting = false
			clear_device_session(state)
			state.mode = "failed"
			set_status(state, friendly_login_error(nil, response, "ConnectionFailed"))
			if authentication_was_rejected(response) then
				ITGOnline:ClearStoredAccessTokenForPlayer(state.player)
				state.mode = "idle"
				start_device_login(state.player)
			end
			return
		end

		local sessionId = state.sessionId
		local pollToken = state.pollToken
		if tostring(sessionId or "") ~= "" and tostring(pollToken or "") ~= "" then
			ITGOnline:AcknowledgeDeviceLogin(sessionId, pollToken, function(ackOk, decoded, ackResponse)
				login_flow_trace(state, "device_login_acknowledge ok=" .. tostring(ackOk == true)
					.. " acknowledged=" .. tostring(decoded and decoded.acknowledged)
					.. " error=" .. tostring(ackResponse and ackResponse.errorMessage or "nil"))
			end)
		end
		clear_device_session(state)
		state.mode = "connected"
		state.connecting = false
		state.status = ""
		refresh()
		connect_party_to_lobbies()
	end
end

local function connect_with_token(state, accessToken, generation)
	if tostring(accessToken or "") == "" or not attempt_is_current(state, generation) then return end
	state.mode = "connecting"
	state.connecting = true
	set_status(state, THEME:GetString("ScreenITGOnlineLogin", "Connecting"))
	ITGOnline:ApplyAccessTokenForPlayer(
		state.player,
		accessToken,
		finish_token_connection(state, generation)
	)
end

local function connect_with_stored_token(state, generation)
	if not attempt_is_current(state, generation) then return end
	state.mode = "connecting"
	state.connecting = true
	set_status(state, THEME:GetString("ScreenITGOnlineLogin", "Connecting"))
	if not ITGOnline:ApplyStoredAccessTokenForPlayer(
		state.player,
		finish_token_connection(state, generation)
	) then
		state.connecting = false
		state.mode = "idle"
		start_device_login(state.player)
	end
end

start_device_login = function(player, resetAttempts)
	local state = states[player_key(player)]
	if not state or not player_is_required(player) then return end
	if state.connecting or state.polling or state.mode == "starting" or state.mode == "waiting" then
		login_flow_trace(state, "start_device_login skipped reason=busy" .. state_summary(state))
		return
	end
	if resetAttempts then state.startAttempts = 0 end
	local generation = invalidate_attempt(state, "start_device_login")
	state.mode = "starting"
	clear_device_session(state)
	state.startAttempts = (tonumber(state.startAttempts) or 0) + 1
	state.startRequestedAt = GetTimeSinceStart()
	set_status(state, THEME:GetString("ScreenITGOnlineLogin", "QrStarting"))
	ITGOnline:StartDeviceLogin(function(ok, decoded, response)
		if not attempt_is_current(state, generation) then return end
		state.startRequestedAt = 0
		login_flow_trace(state, "start_device_login result=" .. tostring(ok == true)
			.. " error=" .. tostring(response and response.errorMessage or "nil"))
		if not ok or not decoded then
			state.mode = "failed"
			set_status(state, friendly_login_error(decoded, response, "DeviceLoginUnavailable"))
			return
		end

		state.sessionId = tostring(decoded.sessionId or "")
		state.pollToken = tostring(decoded.pollToken or "")
		state.verificationUrl = trusted_verification_url(decoded.verificationUrl)
		if not state.verificationUrl then
			clear_device_session(state)
			state.mode = "failed"
			set_status(state, THEME:GetString("ScreenITGOnlineLogin", "DeviceLoginUnavailable"))
			return
		end
		state.shortCode = normalize_short_code(decoded.shortCode)
		state.pollIntervalSeconds = tonumber(decoded.pollIntervalSeconds) or 3
		state.expiresAt = tostring(decoded.expiresAt or "")
		state.nextPollAt = GetTimeSinceStart() + 0.25
		state.mode = "waiting"
		set_status(state, THEME:GetString("ScreenITGOnlineLogin", "QrWaiting"))
	end)
end

local function poll_device_login(state)
	if state.mode ~= "waiting" or state.polling then return end
	if not state.sessionId or not state.pollToken then return end
	if state.nextPollAt and GetTimeSinceStart() < state.nextPollAt then return end

	local generation = state.attemptGeneration
	local sessionId = state.sessionId
	local pollToken = state.pollToken
	state.polling = true
	ITGOnline:PollDeviceLogin(sessionId, pollToken, function(ok, decoded, response)
		if not attempt_is_current(state, generation)
			or state.sessionId ~= sessionId
			or state.pollToken ~= pollToken then
			return
		end
		state.polling = false
		login_flow_trace(state, "poll result=" .. tostring(ok == true)
			.. " status=" .. tostring(decoded and decoded.status or "nil")
			.. " error=" .. tostring(response and response.errorMessage or "nil"))
		if not ok or not decoded then
			state.nextPollAt = GetTimeSinceStart() + state.pollIntervalSeconds
			return
		end

		local pollStatus = tostring(decoded.status or "pending")
		if pollStatus == "pending" then
			state.nextPollAt = GetTimeSinceStart() + state.pollIntervalSeconds
			set_status(state, THEME:GetString("ScreenITGOnlineLogin", "QrWaiting"))
		elseif pollStatus == "expired" or pollStatus == "cancelled" then
			state.mode = "failed"
			clear_device_session(state)
			set_status(state, THEME:GetString("ScreenITGOnlineLogin", "QrExpired"))
		elseif pollStatus == "consumed" and tostring(decoded.apiKey or "") ~= "" then
			connect_with_token(state, tostring(decoded.apiKey), generation)
		else
			state.nextPollAt = GetTimeSinceStart() + state.pollIntervalSeconds
		end
	end)
end

local function reset_missing_players(resetAttempts)
	for _, player in ipairs(required_players()) do
		local state = states[player_key(player)]
		if is_connected(player) then
			state.mode = "connected"
			state.connecting = false
		elseif has_stored_access_token(player) then
			local generation = invalidate_attempt(state, "stored_token")
			connect_with_stored_token(state, generation)
		else
			start_device_login(player, resetAttempts)
		end
	end
end

local function disconnect_all()
	partyConnecting = false
	for _, player in ipairs(required_players()) do
		local state = states[player_key(player)]
		invalidate_attempt(state, "disconnect_all")
		clear_device_session(state)
		state.mode = "idle"
		state.status = ""
		state.connecting = false
	end
	ITGOnline:Disconnect({ revokeToken = true, leaveRoom = false })
	reset_missing_players(false)
end

local function go_back()
	screenActive = false
	for _, state in pairs(states) do invalidate_attempt(state, "go_back") end
	if ITGOnline and ITGOnline.Disconnect then
		ITGOnline:Disconnect({ leaveRoom = false })
	end
	SL.Global.ITGOnline = SL.Global.ITGOnline or {}
	SL.Global.ITGOnline.Enabled = false
	SCREENMAN:SetNewScreen("ScreenSelectOnlineMode")
end

local function current_rows()
	return all_required_players_connected()
		and { "Continue", "Disconnect", "Back" }
		or { "Connect", "Disconnect", "Back" }
end

local function selected_action()
	return current_rows()[selection]
end

local function safe_screen_text_width()
	return math.max(280, math.min(760, _screen.w - 80))
end

local function panel_width()
	return #required_players() > 1
		and math.max(240, math.min(286, (_screen.w - 52) / 2))
		or math.max(260, math.min(300, _screen.w - 40))
end

local function panel_x(player)
	if #required_players() < 2 then return 0 end
	local offset = (panel_width() / 2) + 8
	return player == PLAYER_2 and offset or -offset
end

local function profile_label(player)
	local label = player_key(player)
	local hasPersistentProfile = false
	if PROFILEMAN and PROFILEMAN.IsPersistentProfile then
		local ok, persistent = pcall(function() return PROFILEMAN:IsPersistentProfile(player) end)
		hasPersistentProfile = ok and persistent == true
	end
	if hasPersistentProfile and PROFILEMAN and PROFILEMAN.GetProfile then
		local ok, profile = pcall(function() return PROFILEMAN:GetProfile(player) end)
		if ok and profile and profile.GetDisplayName then
			local nameOk, name = pcall(function() return profile:GetDisplayName() end)
			if nameOk and tostring(name or "") ~= "" then
				label = label .. " — " .. tostring(name)
			end
		end
	end
	if not hasPersistentProfile and is_connected(player) and ITGOnline.UserForLocalPlayer then
		local user = ITGOnline:UserForLocalPlayer(player)
		local onlineName = ITGOnline.UserDisplayName
			and ITGOnline:UserDisplayName(user, "")
			or ""
		if tostring(onlineName or "") ~= "" then
			label = label .. " [" .. tostring(onlineName) .. "]"
		end
	end
	return label
end

local function render_panel(panel, state)
	if not panel or not state then return end
	local required = player_is_required(state.player)
	panel:visible(required)
	if not required then return end
	panel:x(panel_x(state.player))

	local outer = panel:GetChild("QROuter")
	local border = panel:GetChild("QRBorder")
	local inset = panel:GetChild("QRInset")
	local data = panel:GetChild("QRCodeData")
	local status = panel:GetChild("Status")
	local code = panel:GetChild("Code")
	local title = panel:GetChild("PlayerTitle")

	if title then title:settext(profile_label(state.player)) end
	local showQr = state.mode == "waiting" and tostring(state.verificationUrl or "") ~= ""
	if showQr then
		if state.verificationUrl ~= state.lastQrUrl then
			state.lastQrUrl = state.verificationUrl
			state.lastQrVerts, state.lastQrPixelSize = build_qr_vertices(state.verificationUrl, 112)
			state.lastRenderedQrUrl = nil
		end
		if state.lastQrVerts and data then
			if state.lastRenderedQrVisible ~= true then
				if outer then outer:visible(true) end
				if border then border:visible(true) end
				if inset then inset:visible(true) end
				data:visible(true)
				state.lastRenderedQrVisible = true
			end
			if state.lastRenderedQrUrl ~= state.verificationUrl then
				data:SetVertices(state.lastQrVerts)
				data:zoom(state.lastQrPixelSize)
				state.lastRenderedQrUrl = state.verificationUrl
			end
		end
	elseif state.lastRenderedQrVisible ~= false then
		if outer then outer:visible(false) end
		if border then border:visible(false) end
		if inset then inset:visible(false) end
		if data then data:visible(false) end
		state.lastRenderedQrVisible = false
	end

	local statusText = state.status
	if statusText == "" and is_connected(state.player) then
		local user = ITGOnline:UserForLocalPlayer(state.player)
		local displayName = ITGOnline.UserDisplayName
			and ITGOnline:UserDisplayName(user, user and user.email or state.key)
			or state.key
		statusText = THEME:GetString("ScreenITGOnlineLogin", "ConnectedAs"):format(tostring(displayName))
	elseif statusText == "" then
		statusText = THEME:GetString("ScreenITGOnlineLogin", "NotConnected")
	end
	if status and statusText ~= state.lastStatusText then
		status:settext(statusText)
		state.lastStatusText = statusText
	end
	if code then
		local codeText = normalize_short_code(state.shortCode)
		code:settext(codeText ~= ""
			and THEME:GetString("ScreenITGOnlineLogin", "ShortCode"):format(codeText) or "")
	end
end

local function input(event)
	if not event.button or event.type ~= "InputEventType_FirstPress" then return false end
	local rows = current_rows()
	if event.GameButton == "MenuUp" or event.GameButton == "MenuLeft" then
		selection = ((selection - 2) % #rows) + 1
		refresh()
	elseif event.GameButton == "MenuDown" or event.GameButton == "MenuRight" then
		selection = (selection % #rows) + 1
		refresh()
	elseif event.GameButton == "Start" then
		local action = selected_action()
		login_flow_trace(nil, "input_start action=" .. tostring(action))
		if action == "Continue" then
			connect_party_to_lobbies()
		elseif action == "Connect" then
			reset_missing_players(true)
		elseif action == "Disconnect" then
			disconnect_all()
		elseif action == "Back" then
			go_back()
		end
	elseif event.GameButton == "Back" then
		go_back()
	end
	return false
end

local function qr_panel(player)
	local width = panel_width()
	return Def.ActorFrame{
		Name="QrPanel" .. player_key(player),
		InitCommand=function(self) self:xy(panel_x(player), -4) end,
		Def.Quad{ InitCommand=function(self) self:zoomto(width, 264):diffuse(1,1,1,0.12) end },
		Def.Quad{ InitCommand=function(self) self:zoomto(width - 4, 260):diffuse(0.09,0.09,0.1,0.98) end },
		Def.Quad{ InitCommand=function(self) self:y(-109):zoomto(width, 32):diffuse(0.14,0.14,0.16,1) end },
		LoadFont("Common Bold")..{
			Name="PlayerTitle",
			InitCommand=function(self) self:y(-109):zoom(0.48):maxwidth(width - 24):settext(profile_label(player)) end,
		},
		Def.Quad{ Name="QROuter", InitCommand=function(self) self:zoomto(132,132):xy(0,-12):diffuse(Color.Black):visible(false) end },
		Def.Quad{ Name="QRInset", InitCommand=function(self) self:zoomto(124,124):xy(0,-12):diffuse(Color.Black):visible(false) end },
		Def.Quad{ Name="QRBorder", InitCommand=function(self) self:zoomto(128,128):xy(0,-12):diffuse(Color.White):visible(false) end },
		Def.ActorMultiVertex{
			Name="QRCodeData",
			InitCommand=function(self) self:SetDrawState({ Mode="DrawMode_Quads" }):xy(-56,-68):visible(false) end,
		},
		LoadFont("Common Normal")..{
			Name="Status",
			InitCommand=function(self)
				self:xy(0,82):horizalign(center):zoom(0.5)
					:_wrapwidthpixels((width - 20) / 0.5):vertspacing(-5):maxheight(40 / 0.5):settext("")
			end,
		},
		LoadFont("Common Normal")..{
			Name="Code",
			InitCommand=function(self)
				self:xy(0,112):horizalign(center):zoom(0.66):maxwidth(width - 20)
					:diffuse(1,1,1,1):strokecolor(0,0,0,1):settext("")
			end,
		},
	}
end

local t = Def.ActorFrame{
	InitCommand=function(self) self:Center() end,
	OnCommand=function(self)
		screenActive = true
		partyConnecting = false
		for _, state in pairs(states) do
			invalidate_attempt(state, "screen_on")
			clear_device_session(state)
			state.mode = is_connected(state.player) and "connected" or "idle"
			state.connecting = false
			state.status = ""
		end
		local topScreen = SCREENMAN:GetTopScreen()
		if topScreen then topScreen:AddInputCallback(input) end
		selection = 1
		self:sleep(0.2):queuecommand("AutoConnect")
		self:playcommand("Refresh")
		self:sleep(0.25):queuecommand("Tick")
	end,
	AutoConnectCommand=function(self)
		if not screenActive then return end
		if all_required_players_connected() then
			connect_party_to_lobbies()
		else
			reset_missing_players(true)
		end
	end,
	ITGOnlineLoginStateChangedMessageCommand=function(self) self:playcommand("Refresh") end,
	OffCommand=function(self)
		screenActive = false
		for _, state in pairs(states) do invalidate_attempt(state, "screen_off") end
		local topScreen = SCREENMAN:GetTopScreen()
		if topScreen then pcall(function() topScreen:RemoveInputCallback(input) end) end
	end,
	CancelCommand=function() go_back() end,
	TickCommand=function(self)
		if not screenActive then return end
		for _, player in ipairs(required_players()) do
			local state = states[player_key(player)]
			if state.mode == "starting"
				and (tonumber(state.startRequestedAt) or 0) > 0
				and GetTimeSinceStart() - state.startRequestedAt > 2 then
				if state.startAttempts < 3 then
					clear_device_session(state)
					state.mode = "idle"
					start_device_login(player)
				else
					state.startRequestedAt = 0
					state.mode = "failed"
					set_status(state, THEME:GetString("ScreenITGOnlineLogin", "DeviceLoginUnavailable"))
				end
			elseif state.mode == "waiting" then
				local remaining = ITGOnline.SecondsUntilServerTimestamp
					and ITGOnline:SecondsUntilServerTimestamp(state.expiresAt)
				if remaining ~= nil and remaining <= 0 then
					state.mode = "failed"
					clear_device_session(state)
					set_status(state, THEME:GetString("ScreenITGOnlineLogin", "QrExpired"))
				else
					poll_device_login(state)
				end
			end
		end
		local rows = current_rows()
		if selection > #rows then selection = #rows end
		self:sleep(0.25):queuecommand("Tick")
	end,
	RefreshCommand=function(self)
		render_panel(self:GetChild("QrPanelP1"), states.P1)
		render_panel(self:GetChild("QrPanelP2"), states.P2)
		local labels = {}
		for index, row in ipairs(current_rows()) do
			local label = THEME:GetString("ScreenITGOnlineLogin", row)
			if index == selection then label = "> " .. label .. " <" end
			labels[#labels + 1] = label
		end
		local menuText = table.concat(labels, "    ")
		local menu = self:GetChild("MenuRow")
		if menu and menuText ~= lastMenuText then
			menu:settext(menuText)
			lastMenuText = menuText
		end
	end,

	Def.Quad{
		InitCommand=function(self) self:xy(0,0):zoomto(_screen.w,_screen.h):diffuse(0,0,0,0.82) end,
	},
	LoadFont("Common Bold")..{
		Text=THEME:GetString("ScreenITGOnlineLogin", "Title"),
		InitCommand=function(self)
			self:xy(0,-166):horizalign(center):zoom(0.62)
				:maxwidth(safe_screen_text_width()):diffuse(PlayerColor(PLAYER_1))
		end,
	},
	LoadFont("Common Normal")..{
		Text=THEME:GetString("ScreenITGOnlineLogin", "QrInstructions"),
		InitCommand=function(self)
			self:xy(0,-136):horizalign(center):zoom(0.62):maxwidth(safe_screen_text_width())
		end,
	},
	qr_panel(PLAYER_1),
	qr_panel(PLAYER_2),
	LoadFont("Common Normal")..{
		Text=THEME:GetString("ScreenITGOnlineLogin", "Help"),
		InitCommand=function(self)
			self:xy(0,150):horizalign(center):zoom(0.52)
				:maxwidth(safe_screen_text_width()):diffuse(0.8,0.8,0.8,1)
		end,
	},
	LoadFont("Common Normal")..{
		Name="MenuRow",
		InitCommand=function(self)
			self:xy(0,188):horizalign(center):zoom(0.68):maxwidth(safe_screen_text_width())
		end,
	},
}

return t
