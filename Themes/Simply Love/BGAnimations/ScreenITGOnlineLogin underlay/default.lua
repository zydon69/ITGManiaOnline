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
}

local function refresh()
	MESSAGEMAN:Broadcast("ITGOnlineLoginStateChanged")
end

local function set_status(text)
	state.status = tostring(text or "")
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
			return
		end

		connect_to_lobbies()
	end)
end

local function start_device_login()
	if state.connecting or state.polling then return end
	if is_two_player_online_requested() then
		set_status(THEME:GetString("ScreenITGOnlineLogin", "TwoPlayerNotice"))
		return
	end

	state.mode = "starting"
	clear_session()
	set_status(THEME:GetString("ScreenITGOnlineLogin", "QrStarting"))
	ITGOnline:StartDeviceLogin(function(ok, decoded, response)
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

	start_device_login()
end

local function action_disconnect()
	ITGOnline:Disconnect()
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
	local code = panel:GetChild("Code")
	local url = panel:GetChild("Url")

	local showQr = state.mode == "waiting" and state.verificationUrl and state.verificationUrl ~= ""
	if showQr then
		local verts, pixelSize = build_qr_vertices(state.verificationUrl, 124)
		if verts and data then
			if outer then outer:visible(true) end
			if border then border:visible(true) end
			if inset then inset:visible(true) end
			data:visible(true)
			data:SetVertices(verts)
			data:zoom(pixelSize)
		end
	else
		if outer then outer:visible(false) end
		if border then border:visible(false) end
		if inset then inset:visible(false) end
		if data then data:visible(false) end
	end

	if status then
		if state.status ~= "" then
			status:settext(state.status)
		elseif is_connected() then
			status:settext(THEME:GetString("ScreenITGOnlineLogin", "ConnectedAs"):format(tostring(ITGOnline.user and (ITGOnline.user.name or ITGOnline.user.email) or "ITG Online")))
		else
			status:settext(THEME:GetString("ScreenITGOnlineLogin", "NotConnected"))
		end
	end

	if code then
		code:settext(state.shortCode ~= "" and ("Code: " .. state.shortCode) or "")
	end

	if url then
		url:settext(showQr and state.verificationUrl or "")
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
		if is_connected() then
			state.mode = "connected"
			set_status(THEME:GetString("ScreenITGOnlineLogin", "Connected"))
		elseif has_stored_access_token() then
			state.mode = "connecting"
			set_status(THEME:GetString("ScreenITGOnlineLogin", "Connecting"))
			connect_with_token((ITGOnline:Config().accessToken or ""))
		else
			start_device_login()
		end
		self:playcommand("Refresh")
		self:sleep(0.25):queuecommand("Tick")
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
		if state.mode == "waiting" then
			poll_device_login()
		end
		refresh_selection()
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
		if menu then
			menu:settext(table.concat(labels, "    "))
		end
	end,

	Def.Quad{
		InitCommand=function(self) self:FullScreen():diffuse(0,0,0,0.82) end
	},

	LoadFont("Common Bold")..{
		Text=THEME:GetString("ScreenITGOnlineLogin", "Title"),
		InitCommand=function(self) self:xy(_screen.cx, _screen.cy - 160):zoom(0.62):diffuse(PlayerColor(PLAYER_1)) end
	},

	LoadFont("Common Normal")..{
		Text=THEME:GetString("ScreenITGOnlineLogin", "QrInstructions"),
		InitCommand=function(self) self:xy(_screen.cx, _screen.cy - 122):zoom(0.72):maxwidth(760) end,
	},

	Def.ActorFrame{
		Name="QrPanel",
		InitCommand=function(self) self:xy(_screen.cx, _screen.cy - 6) end,
		Def.Quad{ InitCommand=function(self) self:zoomto(300, 270):diffuse(1,1,1,0.12) end },
		Def.Quad{ InitCommand=function(self) self:zoomto(296, 266):diffuse(0.09,0.09,0.1,0.98) end },
		Def.Quad{ InitCommand=function(self) self:y(-112):zoomto(300, 32):diffuse(0.14,0.14,0.16,1) end },
		LoadFont("Common Bold")..{
			InitCommand=function(self) self:y(-112):zoom(0.5):settext(THEME:GetString("ScreenITGOnlineLogin", "Title")) end
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
			InitCommand=function(self) self:xy(0, 88):zoom(0.56):maxwidth(250):settext("") end
		},
		LoadFont("Common Normal")..{
			Name="Code",
			InitCommand=function(self) self:xy(0, 116):zoom(0.48):maxwidth(250):settext("") end
		},
		LoadFont("Common Normal")..{
			Name="Url",
			InitCommand=function(self) self:xy(0, 136):zoom(0.34):maxwidth(250):settext("") end
		},
	},

	LoadFont("Common Normal")..{
		Text=THEME:GetString("ScreenITGOnlineLogin", "Help"),
		InitCommand=function(self) self:xy(_screen.cx, _screen.cy + 134):zoom(0.56):maxwidth(760):diffuse(0.8,0.8,0.8,1) end,
	},

	LoadFont("Common Normal")..{
		Name="MenuRow",
		InitCommand=function(self) self:xy(_screen.cx, _screen.cy + 168):zoom(0.72):maxwidth(760) end,
		ITGOnlineLoginStateChangedMessageCommand=function(self) self:playcommand("Refresh") end,
	},
}

return t
