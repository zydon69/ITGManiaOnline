local function is_connected()
	return ITGOnline and ITGOnline.token ~= nil and ITGOnline.user ~= nil
end

local function has_stored_access_token()
	return ITGOnline and ITGOnline.HasStoredAccessToken and ITGOnline:HasStoredAccessToken()
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
	local encoder = qr_encoder()
	if not encoder then return nil, nil end
	local ok, qrOk, modules = pcall(encoder.qrcode, url)
	if not ok or not qrOk or type(modules) ~= "table" then return nil, nil end

	local verts = {}
	for c, column in ipairs(modules) do
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
}

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
	state.status = text
	refresh()
end

local function clear_session()
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
	if is_connected() then
		ITGOnline:Disconnect()
	end
	SL.Global.ITGOnline = SL.Global.ITGOnline or {}
	SL.Global.ITGOnline.Enabled = false
	SCREENMAN:SetNewScreen("ScreenSelectOnlineMode")
end

local start_device_login

local function connect_to_lobbies()
	ITGOnline:ConnectWebSocket({
		open = function()
			state.connecting = false
			state.mode = "connected"
			set_status(THEME:GetString("ScreenITGOnlineLogin", "Connected"))
			SCREENMAN:SetNewScreen("ScreenOnlineLobbies")
		end,
		error = function(message)
			state.connecting = false
			ITGOnline:ClearStoredAccessToken()
			clear_session()
			state.mode = "idle"
			set_status(tostring(message or THEME:GetString("ScreenITGOnlineLogin", "ConnectionFailed")))
			start_device_login()
		end,
		close = function(reason)
			state.connecting = false
			set_status(tostring(reason or THEME:GetString("ScreenITGOnlineLogin", "Disconnected")))
		end,
	})
end

local function connect_with_token(accessToken)
	if tostring(accessToken or "") == "" then
		set_status(THEME:GetString("ScreenITGOnlineLogin", "DeviceLoginUnavailable"))
		return
	end

	state.mode = "connecting"
	state.connecting = true
	set_status(THEME:GetString("ScreenITGOnlineLogin", "Connecting"))
	ITGOnline:ApplyAccessToken(accessToken, function(ok, user, response)
		if not ok then
			state.connecting = false
			ITGOnline:ClearStoredAccessToken()
			clear_session()
			state.mode = "idle"
			set_status(tostring((response and response.message) or THEME:GetString("ScreenITGOnlineLogin", "ConnectionFailed")))
			start_device_login()
			return
		end

		connect_to_lobbies()
	end)
end

start_device_login = function(resetAttempts)
	if state.connecting or state.polling then return end
	if is_two_player_online_requested() then
		set_status(THEME:GetString("ScreenITGOnlineLogin", "TwoPlayerNotice"))
		return
	end

	if resetAttempts then
		state.startAttempts = 0
	end
	state.mode = "starting"
	clear_session()
	state.startAttempts = (tonumber(state.startAttempts) or 0) + 1
	state.startRequestedAt = GetTimeSinceStart()
	set_status(THEME:GetString("ScreenITGOnlineLogin", "QrStarting"))
	ITGOnline:StartDeviceLogin(function(ok, decoded, response)
		state.startRequestedAt = 0
		if not ok or not decoded then
			state.mode = "failed"
			set_status(tostring((decoded and decoded.message) or (response and response.errorMessage) or THEME:GetString("ScreenITGOnlineLogin", "DeviceLoginUnavailable")))
			return
		end

		state.sessionId = tostring(decoded.sessionId or "")
		state.pollToken = tostring(decoded.pollToken or "")
		state.verificationUrl = tostring(decoded.verificationUrl or "")
		state.shortCode = tostring(decoded.shortCode or "")
		state.pollIntervalSeconds = tonumber(decoded.pollIntervalSeconds) or 3
		state.expiresAt = decoded.expiresAt
		state.nextPollAt = GetTimeSinceStart() + 0.25
		state.mode = "waiting"
		set_status(THEME:GetString("ScreenITGOnlineLogin", "QrWaiting"))
	end)
end

local function poll_device_login()
	if state.mode ~= "waiting" or state.polling then return end
	if not state.sessionId or not state.pollToken then return end
	if state.nextPollAt and GetTimeSinceStart() < state.nextPollAt then return end

	state.polling = true
	ITGOnline:PollDeviceLogin(state.sessionId, state.pollToken, function(ok, decoded, response)
		state.polling = false
		if not ok or not decoded then
			state.nextPollAt = GetTimeSinceStart() + (state.pollIntervalSeconds or 3)
			return
		end

		local pollStatus = tostring(decoded.status or "pending")
		if pollStatus == "pending" then
			state.nextPollAt = GetTimeSinceStart() + (state.pollIntervalSeconds or 3)
			set_status(THEME:GetString("ScreenITGOnlineLogin", "QrWaiting"))
			return
		end

		if pollStatus == "expired" or pollStatus == "cancelled" then
			state.mode = "failed"
			clear_session()
			set_status(THEME:GetString("ScreenITGOnlineLogin", "QrExpired"))
			return
		end

		if pollStatus == "consumed" and tostring(decoded.apiKey or "") ~= "" then
			state.mode = "connecting"
			set_status(THEME:GetString("ScreenITGOnlineLogin", "Connecting"))
			connect_with_token(tostring(decoded.apiKey))
			return
		end

		state.nextPollAt = GetTimeSinceStart() + (state.pollIntervalSeconds or 3)
	end)
end

local function action_connect()
	if is_connected() then
		SCREENMAN:SetNewScreen("ScreenOnlineLobbies")
		return
	end

	if has_stored_access_token() then
		connect_with_token((ITGOnline:Config().accessToken or ""))
		return
	end

	start_device_login(true)
end

local function action_disconnect()
	ITGOnline:Disconnect({ revokeToken = true })
	ITGOnline:ClearStoredAccessToken()
	clear_session()
	state.mode = "idle"
	set_status(THEME:GetString("ScreenITGOnlineLogin", "Disconnected"))
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
			statusText = THEME:GetString("ScreenITGOnlineLogin", "ConnectedAs"):format(tostring(ITGOnline.user and (ITGOnline.user.name or ITGOnline.user.email) or "ITG Online"))
		else
			statusText = THEME:GetString("ScreenITGOnlineLogin", "NotConnected")
		end
		if statusText ~= lastStatusText then
			status:settext(statusText)
			lastStatusText = statusText
		end
	end

	if url then
		local urlText = showQr and state.verificationUrl or ""
		if urlText ~= lastUrlText then
			url:settext(urlText)
			lastUrlText = urlText
		end
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
		if action == "Connect" or action == "Continue" then
			action_connect()
		elseif action == "Disconnect" then
			action_disconnect()
		elseif action == "Back" then
			go_back()
		end
	elseif event.GameButton == "Back" then
		go_back()
	end
end

local t = Def.ActorFrame{
	InitCommand=function(self) self:Center() end,
	OnCommand=function(self)
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
		if is_connected() then
			state.mode = "connected"
			set_status(THEME:GetString("ScreenITGOnlineLogin", "Connected"))
		elseif has_stored_access_token() then
			state.mode = "connecting"
			set_status(THEME:GetString("ScreenITGOnlineLogin", "Connecting"))
			connect_with_token((ITGOnline:Config().accessToken or ""))
		else
			start_device_login(true)
		end
		self:playcommand("Refresh")
	end,
	ITGOnlineLoginStateChangedMessageCommand=function(self)
		self:playcommand("Refresh")
	end,
	OffCommand=function(self)
		local topScreen = SCREENMAN:GetTopScreen()
		if topScreen then
			pcall(function() topScreen:RemoveInputCallback(input) end)
		end
	end,
	CancelCommand=function(self)
		go_back()
	end,
		TickCommand=function(self)
		if state.mode == "starting"
			and (tonumber(state.startRequestedAt) or 0) > 0
			and GetTimeSinceStart() - (tonumber(state.startRequestedAt) or 0) > 2.0
		then
			if (tonumber(state.startAttempts) or 0) < 3 then
				clear_session()
				state.mode = "idle"
				start_device_login()
			else
				state.startRequestedAt = 0
				state.mode = "failed"
				set_status(THEME:GetString("ScreenITGOnlineLogin", "DeviceLoginUnavailable"))
			end
		end
			if state.mode == "waiting" then
				poll_device_login()
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
			InitCommand=function(self) self:xy(0, 96):horizalign(center):zoom(0.56):maxwidth(250):settext("") end
		},
		LoadFont("Common Normal")..{
			Name="Url",
			InitCommand=function(self) self:xy(0, 128):horizalign(center):zoom(0.34):maxwidth(250):settext("") end
		},
	},

	LoadFont("Common Normal")..{
		Text=THEME:GetString("ScreenITGOnlineLogin", "Help"),
		InitCommand=function(self) self:xy(0, 134):horizalign(center):zoom(0.56):maxwidth(safe_screen_text_width()):diffuse(0.8,0.8,0.8,1) end,
	},

	LoadFont("Common Normal")..{
		Name="MenuRow",
		InitCommand=function(self) self:xy(0, 168):horizalign(center):zoom(0.72):maxwidth(safe_screen_text_width()) end,
		ITGOnlineLoginStateChangedMessageCommand=function(self) self:playcommand("Refresh") end,
	},
}

return t
