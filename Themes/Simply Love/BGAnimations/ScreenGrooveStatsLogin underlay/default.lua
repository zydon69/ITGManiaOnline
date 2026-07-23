local qrModulePath = THEME:GetPathB("", "_modules/QR Code/SL-QRCode.lua")
local qrEncodePath = THEME:GetPathB("", "_modules/QR Code/qrencode.lua")
local grooveStatsUuid = CRYPTMAN:GenerateRandomUUID():gsub("-", ""):upper()
local grooveStatsWs = nil

local ARROWCLOUD_BASE_URL = "https://api.arrowcloud.dance"
local ARROWCLOUD_DEVICE_LOGIN_START_PATH = "/device-login/start"
local ARROWCLOUD_DEVICE_LOGIN_POLL_PATH = "/device-login/poll"

local qrEncoder = nil

local function is_arrowcloud_enabled()
	return ThemePrefs and ThemePrefs.Get and ThemePrefs.Get("EnableArrowCloud") == true
end

local function get_machine_label()
	local configured = PREFSMAN and PREFSMAN:GetPreference("MachineName") or ""
	if type(configured) == "string" and configured:gsub("%s+", "") ~= "" then
		return configured
	end
	return "ITGMania Machine"
end

local function safe_close_groovestats_ws()
	if grooveStatsWs and grooveStatsWs.Close then
		grooveStatsWs:Close()
	end
end

local function reset_groovestats_settings(pn)
	SL[pn].ApiKey = ""
	SL[pn].GrooveStatsUsername = ""
	SL[pn].IsPadPlayer = false
end

local function is_http_ok(response)
	return type(response) == "table" and tonumber(response.statusCode) and response.statusCode >= 200 and response.statusCode < 300
end

local function decode_json_response(response)
	if type(response) ~= "table" or type(response.body) ~= "string" or response.body == "" then
		return nil
	end

	local ok, decoded = pcall(JsonDecode, response.body)
	if ok and type(decoded) == "table" then
		return decoded
	end

	return nil
end

local function load_qr_encoder()
	if qrEncoder ~= nil then return qrEncoder end

	local chunk = loadfile(qrEncodePath)
	if not chunk then return nil end

	local ok, module = pcall(chunk)
	if ok and type(module) == "table" and module.qrcode then
		qrEncoder = module
		return qrEncoder
	end

	return nil
end

local function build_qr_vertices(url, size)
	if not url or url == "" then return nil, nil end

	local encoder = load_qr_encoder()
	if not encoder then return nil, nil end

	local ok, qrOk, modules = pcall(encoder.qrcode, url)
	if not ok or not qrOk or type(modules) ~= "table" then
		return nil, nil
	end

	local verts = {}
	for c, column in ipairs(modules) do
		for m, module in ipairs(column) do
			local clr = (module > 0) and Color.Black or Color.White
			verts[#verts + 1] = {{m - 1, c - 1, 0}, clr}
			verts[#verts + 1] = {{m, c - 1, 0}, clr}
			verts[#verts + 1] = {{m, c, 0}, clr}
			verts[#verts + 1] = {{m - 1, c, 0}, clr}
		end
	end

	return verts, size / #modules
end

local function request_arrowcloud_start(on_done)
	NETWORK:HttpRequest{
		url = ARROWCLOUD_BASE_URL .. ARROWCLOUD_DEVICE_LOGIN_START_PATH,
		method = "POST",
		body = JsonEncode({
			machineLabel = get_machine_label(),
			clientVersion = "ITGMania",
			themeVersion = THEME and THEME:GetThemeDisplayName() or "Simply Love"
		}),
		headers = {
			["Content-Type"] = "application/json"
		},
		connectTimeout = 8,
		transferTimeout = 12,
		onResponse = function(response)
			if on_done then on_done(response, is_http_ok(response), decode_json_response(response)) end
		end
	}
end

local function request_arrowcloud_poll(session_id, poll_token, on_done)
	NETWORK:HttpRequest{
		url = ARROWCLOUD_BASE_URL .. ARROWCLOUD_DEVICE_LOGIN_POLL_PATH,
		method = "POST",
		body = JsonEncode({
			sessionId = session_id,
			pollToken = poll_token
		}),
		headers = {
			["Content-Type"] = "application/json"
		},
		connectTimeout = 8,
		transferTimeout = 10,
		onResponse = function(response)
			if on_done then on_done(response, is_http_ok(response), decode_json_response(response)) end
		end
	}
end

grooveStatsWs = NETWORK:WebSocket{
	url = "ws://qrlogin.groovestats.com:3000",
	pingInterval = 15,
	automaticReconnect = true,
	onMessage = function(msg)
		local msgType = ToEnumShortString(msg.type)
		if msgType == "Open" then
			grooveStatsWs:Send(JsonEncode({
				event = "uuid",
				data = { uuid = grooveStatsUuid }
			}))

		elseif msgType == "Message" then
			local resp = JsonDecode(msg.data)
			if resp.event == "apiKey" then
				local data = resp.data
				if data.uuid == grooveStatsUuid then
					local side = data.side
					local pn = (side == 1) and "P1" or "P2"
					local player = (side == 1) and PLAYER_1 or PLAYER_2

					if data.playerOptions then
						SetPlayerOptionsJsonFromGroovestats(player, data.playerOptions)
					end

					SL[pn].ApiKey = data.apiKey
					SL[pn].GrooveStatsUsername = data.username
					SL[pn].IsPadPlayer = true
					MESSAGEMAN:Broadcast("SetCreditsText", { pn = pn, username = data.username })
					MESSAGEMAN:Broadcast("HideQr", { pn = pn, username = data.username, service = "GrooveStats" })
				end
			end
		end
	end,
}

local InputHandler = function(event)
	if not event.PlayerNumber or not event.button then return false end

	if event.type == "InputEventType_FirstPress" then
		if event.GameButton == "Back" then
			SCREENMAN:GetTopScreen():Cancel()
		elseif event.GameButton == "Start" then
			SCREENMAN:GetTopScreen():StartTransitioningScreen("SM_GoToNextScreen")
		end
	end
end

local players = GAMESTATE:GetHumanPlayers()
local cardCount = #players * 2
local useCompactLayout = cardCount > 2
local boxWidth = useCompactLayout and 188 or 230
local boxHeight = useCompactLayout and 158 or 210
local qrcodeSize = useCompactLayout and 92 or 138

local function panel_position(player, service)
	if useCompactLayout then
		local x = (player == PLAYER_1) and -230 or 230
		local y = (service == "GrooveStats") and -56 or 114
		return x, y
	end

	local x = (service == "GrooveStats") and -135 or 135
	return x, 18
end

local function make_service_panel(player, service)
	local pn = ToEnumShortString(player)
	local x, y = panel_position(player, service)
	local title = pn .. "  " .. service
	local statusY = (qrcodeSize / 2) + 20

	local panel = Def.ActorFrame{
		Name = service .. "Panel" .. pn,
		InitCommand = function(self) self:xy(x, y) end,

		SetStatusCommand = function(self, params)
			local status = self:GetChild("Status")
			if status then status:settext(params and params.text or "") end
		end,

		SetArrowCloudQrCommand = function(self, params)
			local url = params and params.url or ""
			local data = self:GetChild("ArrowCloudQRCodeData")
			local outer = self:GetChild("ArrowCloudQROuter")
			local inset = self:GetChild("ArrowCloudQRInset")
			local verts, pixelSize = build_qr_vertices(url, qrcodeSize)

			if not data or not verts then
				if data then data:visible(false) end
				if outer then outer:visible(false) end
				if inset then inset:visible(false) end
				return
			end

			if outer then outer:visible(true) end
			if inset then inset:visible(true) end
			data:visible(true)
			data:SetVertices(verts)
			data:zoom(pixelSize)
		end,

		ClearArrowCloudQrCommand = function(self)
			local data = self:GetChild("ArrowCloudQRCodeData")
			local outer = self:GetChild("ArrowCloudQROuter")
			local inset = self:GetChild("ArrowCloudQRInset")
			if data then data:visible(false) end
			if outer then outer:visible(false) end
			if inset then inset:visible(false) end
		end,

		Def.Quad{
			InitCommand = function(self) self:zoomto(boxWidth, boxHeight):diffuse(Color.White) end
		},
		Def.Quad{
			InitCommand = function(self) self:zoomto(boxWidth - 3, boxHeight - 3):diffuse(Color.Black) end
		},
		Def.Quad{
			InitCommand = function(self) self:y((boxHeight * -0.5) + 15):zoomto(boxWidth - 3, 30):diffuse(0.08, 0.08, 0.09, 1) end
		},
		Def.Quad{
			Name = "TopBorder",
			InitCommand = function(self)
				self:y(boxHeight * -0.5):zoomto(boxWidth, 2):diffuse(Color.White)
			end
		},
		LoadFont("Common Bold")..{
			Text = title,
			InitCommand = function(self)
				self:y((boxHeight * -0.5) + 15):zoom(useCompactLayout and 0.42 or 0.48):maxwidth((boxWidth - 16) / (useCompactLayout and 0.42 or 0.48))
			end
		},
		LoadFont("Common Normal")..{
			Name = "Status",
			InitCommand = function(self)
				self:y(statusY):zoom(useCompactLayout and 0.34 or 0.42):maxwidth((boxWidth - 14) / (useCompactLayout and 0.34 or 0.42)):settext("")
			end
		}
	}

	if service == "GrooveStats" then
		panel[#panel + 1] = LoadFont("Common Normal")..{
			Text = SL[pn].ApiKey ~= "" and THEME:GetString("ScreenSelectProfile", "ProfileConnected") or "",
			InitCommand = function(self)
				self:y(0):zoom(useCompactLayout and 0.42 or 0.5):maxwidth((boxWidth - 16) / (useCompactLayout and 0.42 or 0.5))
			end,
			HideQrMessageCommand = function(self, params)
				if params.pn == pn then
					WriteGrooveStatsIni(player)
					self:settext((params.username or "GrooveStats") .. "\nLogged in!")
				end
			end,
		}

		if ThemePrefs.Get("QRLogin") == "Always" or SL[pn].ApiKey == "" then
			local side = (player == PLAYER_1) and 1 or 2
			local url = ("https://www.groovestats.com/qrlogin.php?UUID=%s&SIDE=%d"):format(grooveStatsUuid, side)

			panel[#panel + 1] = LoadActor(qrModulePath, { url, qrcodeSize })..{
				Name = "QRCode",
				InitCommand = function(self) self:xy(qrcodeSize * -0.5, qrcodeSize * -0.5 + 8) end,
				HideQrMessageCommand = function(self, params)
					if params.pn == pn then self:visible(false) end
				end
			}
		end

	elseif service == "ArrowCloud" then
		panel[#panel + 1] = Def.Quad{
			Name = "ArrowCloudQROuter",
			InitCommand = function(self) self:xy(0, 8):zoom(qrcodeSize + 12):diffuse(Color.White):visible(false) end
		}
		panel[#panel + 1] = Def.Quad{
			Name = "ArrowCloudQRInset",
			InitCommand = function(self) self:xy(0, 8):zoom(qrcodeSize + 4):diffuse(Color.White):visible(false) end
		}
		panel[#panel + 1] = Def.ActorMultiVertex{
			Name = "ArrowCloudQRCodeData",
			InitCommand = function(self)
				self:SetDrawState({ Mode = "DrawMode_Quads" })
				self:xy(qrcodeSize * -0.5, qrcodeSize * -0.5 + 8):visible(false)
			end
		}
	end

	return panel
end

local af = Def.ActorFrame{
	InitCommand = function(self)
		self:Center()
		self.arrowCloudRunToken = 0
		self.arrowCloudStates = {}
	end,

	OnCommand = function(self)
		SCREENMAN:GetTopScreen():AddInputCallback(InputHandler)
		self:queuecommand("StartArrowCloudLogin")
	end,

	CancelCommand = function(self)
		reset_groovestats_settings("P1")
		reset_groovestats_settings("P2")
		self.arrowCloudRunToken = self.arrowCloudRunToken + 1
		safe_close_groovestats_ws()
	end,

	OffCommand = function(self)
		self.arrowCloudRunToken = self.arrowCloudRunToken + 1
		safe_close_groovestats_ws()
	end,

	StartArrowCloudLoginCommand = function(self)
		self.arrowCloudRunToken = self.arrowCloudRunToken + 1
		local runToken = self.arrowCloudRunToken

		for player in ivalues(players) do
			local pn = ToEnumShortString(player)
			local panel = self:GetChild("ArrowCloudPanel" .. pn)
			if panel then panel:playcommand("ClearArrowCloudQr") end

			if not is_arrowcloud_enabled() then
				if panel then panel:playcommand("SetStatus", { text = THEME:GetString("ScreenSelectProfile", "ArrowCloudUnavailable") }) end

			elseif not PROFILEMAN:IsPersistentProfile(player) then
				if panel then panel:playcommand("SetStatus", { text = THEME:GetString("ScreenSelectProfile", "GuestProfile") }) end

			else
				if type(EnsureArrowCloudIniLoaded) == "function" then
					EnsureArrowCloudIniLoaded(player)
				else
					ParseArrowCloudIni(player)
				end

				if SL[pn].ArrowCloudApiKey and SL[pn].ArrowCloudApiKey ~= "" then
					if panel then panel:playcommand("SetStatus", { text = THEME:GetString("ScreenSelectProfile", "ArrowCloudProfileConnected") }) end
				else
					self.arrowCloudStates[pn] = {
						player = player,
						status = "starting",
						nextPollAt = 0,
						pollIntervalSeconds = 3,
						polling = false
					}
					if panel then panel:playcommand("SetStatus", { text = "Arrow Cloud: starting..." }) end

					request_arrowcloud_start(function(response, ok, body)
						if self.arrowCloudRunToken ~= runToken then return end
						local state = self.arrowCloudStates[pn]
						if not state then return end

						if ok and body and body.sessionId and body.pollToken and body.verificationUrl then
							state.status = "waiting"
							state.sessionId = tostring(body.sessionId)
							state.pollToken = tostring(body.pollToken)
							state.pollIntervalSeconds = tonumber(body.pollIntervalSeconds) or 3
							state.nextPollAt = GetTimeSinceStart() + 0.5
							if panel then
								panel:playcommand("SetStatus", { text = THEME:GetString("ScreenSelectProfile", "ArrowCloudWaiting") })
								panel:playcommand("SetArrowCloudQr", { url = tostring(body.verificationUrl) })
							end
						else
							state.status = "failure"
							if panel then panel:playcommand("SetStatus", { text = "Arrow Cloud: login unavailable" }) end
						end
					end)
				end
			end
		end

		self:sleep(0.2):queuecommand("PollArrowCloudLogin")
	end,

	PollArrowCloudLoginCommand = function(self)
		local runToken = self.arrowCloudRunToken
		local now = GetTimeSinceStart()
		local hasPending = false

		for pn, state in pairs(self.arrowCloudStates) do
			if state.status == "waiting" then
				hasPending = true
				if not state.polling and now >= (state.nextPollAt or 0) then
					state.polling = true
					request_arrowcloud_poll(state.sessionId, state.pollToken, function(response, ok, body)
						if self.arrowCloudRunToken ~= runToken then return end
						state.polling = false

						local panel = self:GetChild("ArrowCloudPanel" .. pn)
						if not ok or not body then
							state.nextPollAt = GetTimeSinceStart() + 3
							return
						end

						local status = body.status and tostring(body.status) or "pending"
						if status == "pending" then
							state.nextPollAt = GetTimeSinceStart() + (state.pollIntervalSeconds or 3)
						elseif status == "consumed" and body.apiKey and tostring(body.apiKey) ~= "" then
							SL[pn].ArrowCloudApiKey = tostring(body.apiKey)
							WriteArrowCloudIni(state.player)
							state.status = "success"
							if panel then
								panel:playcommand("ClearArrowCloudQr")
								panel:playcommand("SetStatus", { text = THEME:GetString("ScreenSelectProfile", "ArrowCloudProfileConnected") })
							end
						elseif status == "expired" or status == "cancelled" then
							state.status = "failure"
							if panel then
								panel:playcommand("ClearArrowCloudQr")
								panel:playcommand("SetStatus", { text = "Arrow Cloud: " .. status })
							end
						else
							state.nextPollAt = GetTimeSinceStart() + (state.pollIntervalSeconds or 3)
						end
					end)
				end
			end
		end

		if hasPending then
			self:sleep(0.2):queuecommand("PollArrowCloudLogin")
		end
	end,

	LoadFont("Common Normal")..{
		Text = THEME:GetString("ScreenSelectProfile", "LoginInstructions"),
		InitCommand = function(self)
			self:y(useCompactLayout and -206 or -150):zoom(useCompactLayout and 0.48 or 0.55):maxwidth(_screen.w * 1.55)
			if ThemePrefs.Get("RainbowMode") then self:diffuse(Color.Black) end
		end,
	},
	LoadFont("Common Normal")..{
		Text = THEME:GetString("ScreenSelectProfile", "ArrowCloudLoginInstructions"),
		InitCommand = function(self)
			self:y(useCompactLayout and -182 or -125):zoom(useCompactLayout and 0.42 or 0.48):maxwidth(_screen.w * 1.65)
			if ThemePrefs.Get("RainbowMode") then self:diffuse(Color.Black) end
		end,
	},

	LoadFont("Common Bold")..{
		Text = THEME:GetString("ScreenEvaluation", "PressStartToContinue"),
		InitCommand = function(self)
			self:zoom(0.55):y(useCompactLayout and 214 or 160):shadowlength(1)
		end,
	},
}

for player in ivalues(players) do
	af[#af + 1] = make_service_panel(player, "GrooveStats")
	af[#af + 1] = make_service_panel(player, "ArrowCloud")
end

return af
