local config = ITGOnline:Config()
local selection = 1
local status = ""
local busy = false

local function mask_password(value, storedSecurely)
	value = tostring(value or "")
	if value == "" then return "(not set)" end
	if storedSecurely then
		return "******** (" .. THEME:GetString("ScreenITGOnlineLogin", "PasswordStoredSecurely") .. ")"
	end
	return string.rep("*", #value)
end

local function refresh()
	MESSAGEMAN:Broadcast("ITGOnlineLoginStateChanged")
end

local function connected()
	return ITGOnline.token ~= nil and ITGOnline.user ~= nil
end

local function enabled_sides()
	local sides = {}
	for player in ivalues(GAMESTATE:GetEnabledPlayers()) do
		if GAMESTATE:IsSideJoined(player) then sides[#sides + 1] = player end
	end
	return sides
end

local function two_player_online_requested()
	return #enabled_sides() > 1
end

local function option_rows()
	if connected() then
		return { "Continue", "Disconnect", "EditEmail", "EditPassword", "Back" }
	end

	return { "Connect", "Register", "EditEmail", "EditPassword", "ResendVerification", "ForgotPassword", "Back" }
end

local function save_config(password)
	local values = {
		apiBaseUrl = config.apiBaseUrl,
		webSocketUrl = config.webSocketUrl,
		email = config.email,
		deviceName = config.deviceName,
	}
	if password ~= nil then
		values.password = password
	end
	config = ITGOnline:SaveConfig(values)
end

local function prompt_for(field)
	if busy then return end

	local is_password = field == "password"
	SCREENMAN:AddNewScreenToTop("ScreenTextEntry")
	SCREENMAN:GetTopScreen():Load({
		Question = is_password and THEME:GetString("ScreenITGOnlineLogin", "PasswordQuestion") or THEME:GetString("ScreenITGOnlineLogin", "EmailQuestion"),
		InitialAnswer = is_password and "" or tostring(config.email or ""),
		MaxInputLength = is_password and 128 or 160,
		Password = is_password,
		OnOK = function(input)
			config[field] = tostring(input or "")
			save_config(is_password and config[field] or nil)
			status = THEME:GetString("ScreenITGOnlineLogin", "Saved")
			refresh()
		end,
	})
end

local function go_back()
	SL.Global.ITGOnline = SL.Global.ITGOnline or {}
	SL.Global.ITGOnline.Enabled = false
	SCREENMAN:SetNewScreen("ScreenSelectOnlineMode")
end

local function connect()
	if busy then return end

	if two_player_online_requested() then
		status = THEME:GetString("ScreenITGOnlineLogin", "TwoPlayerNotice")
		refresh()
		return
	end

	if tostring(config.email or "") == "" or tostring(config.password or "") == "" then
		status = THEME:GetString("ScreenITGOnlineLogin", "MissingCredentials")
		refresh()
		return
	end

	if NETWORK and NETWORK.HttpEnabled and not NETWORK:HttpEnabled() then
		status = THEME:GetString("ScreenITGOnlineLogin", "HttpDisabled")
		refresh()
		return
	end

		if ITGOnline and ITGOnline.IsTrustedConnectionConfig and not ITGOnline:IsTrustedConnectionConfig(config) then
			status = THEME:GetString("ScreenITGOnlineLogin", "HostNotAllowed")
			refresh()
			return
		end

	busy = true
	status = THEME:GetString("ScreenITGOnlineLogin", "Connecting")
	refresh()

	ITGOnline:Connect({
		open = function()
			busy = false
			status = THEME:GetString("ScreenITGOnlineLogin", "Connected")
			refresh()
			SCREENMAN:SetNewScreen("ScreenOnlineLobbies")
		end,
		error = function(message)
			busy = false
			status = tostring(message or THEME:GetString("ScreenITGOnlineLogin", "ConnectionFailed"))
			refresh()
		end,
		close = function(reason)
			busy = false
			status = tostring(reason or THEME:GetString("ScreenITGOnlineLogin", "Disconnected"))
			refresh()
		end,
	})
end

local function disconnect()
	ITGOnline:Disconnect()
	status = THEME:GetString("ScreenITGOnlineLogin", "Disconnected")
	refresh()
end

local function forgot_password()
	if busy then return end

	if tostring(config.email or "") == "" then
		status = THEME:GetString("ScreenITGOnlineLogin", "MissingEmail")
		refresh()
		return
	end

	busy = true
	status = THEME:GetString("ScreenITGOnlineLogin", "PasswordResetSending")
	refresh()

	ITGOnline:ForgotPassword(function(ok, decoded, response)
		busy = false
		status = ok
			and THEME:GetString("ScreenITGOnlineLogin", "PasswordResetSent")
			or tostring((decoded and decoded.message) or (response and response.errorMessage) or THEME:GetString("ScreenITGOnlineLogin", "PasswordResetFailed"))
		refresh()
	end)
end

local function resend_verification()
	if busy then return end

	if tostring(config.email or "") == "" then
		status = THEME:GetString("ScreenITGOnlineLogin", "MissingEmail")
		refresh()
		return
	end

	busy = true
	status = THEME:GetString("ScreenITGOnlineLogin", "VerificationSending")
	refresh()

	ITGOnline:ResendVerification(function(ok, decoded, response)
		busy = false
		status = ok
			and THEME:GetString("ScreenITGOnlineLogin", "VerificationSent")
			or tostring((decoded and decoded.message) or (response and response.errorMessage) or THEME:GetString("ScreenITGOnlineLogin", "VerificationFailed"))
		refresh()
	end)
end

local function register_account()
	if busy then return end

	if two_player_online_requested() then
		status = THEME:GetString("ScreenITGOnlineLogin", "TwoPlayerNotice")
		refresh()
		return
	end

	if tostring(config.email or "") == "" or tostring(config.password or "") == "" then
		status = THEME:GetString("ScreenITGOnlineLogin", "MissingCredentials")
		refresh()
		return
	end

	SCREENMAN:AddNewScreenToTop("ScreenTextEntry")
	SCREENMAN:GetTopScreen():Load({
		Question = THEME:GetString("ScreenITGOnlineLogin", "NameQuestion"),
		InitialAnswer = "",
		MaxInputLength = 32,
		OnOK = function(input)
			local name = tostring(input or "")
			if name == "" then
				status = THEME:GetString("ScreenITGOnlineLogin", "MissingName")
				refresh()
				return
			end

			busy = true
			status = THEME:GetString("ScreenITGOnlineLogin", "Registering")
			refresh()

			ITGOnline:Register(name, function(ok, decoded, response)
				busy = false
				status = ok
					and THEME:GetString("ScreenITGOnlineLogin", "RegisterSent")
					or tostring((decoded and decoded.message) or (response and response.errorMessage) or THEME:GetString("ScreenITGOnlineLogin", "RegisterFailed"))
				refresh()
			end)
		end,
	})
end

local actions = {
	Continue = function() SCREENMAN:SetNewScreen("ScreenOnlineLobbies") end,
	Disconnect = disconnect,
	Connect = connect,
	Register = register_account,
	EditEmail = function() prompt_for("email") end,
	EditPassword = function() prompt_for("password") end,
	ResendVerification = resend_verification,
	ForgotPassword = forgot_password,
	Back = go_back,
}

local input = function(event)
	if not event.button then return false end
	if event.type ~= "InputEventType_FirstPress" then return false end
	local rows = option_rows()

	if event.GameButton == "MenuUp" or event.GameButton == "MenuLeft" then
		selection = ((selection - 2) % #rows) + 1
		refresh()
	elseif event.GameButton == "MenuDown" or event.GameButton == "MenuRight" then
		selection = (selection % #rows) + 1
		refresh()
	elseif event.GameButton == "Start" then
		local action = actions[rows[selection]]
		if action then action() end
	elseif event.GameButton == "Back" then
		go_back()
	end
end

local t = Def.ActorFrame{
	OnCommand=function(self)
		SCREENMAN:GetTopScreen():AddInputCallback(input)
		if two_player_online_requested() then
			status = THEME:GetString("ScreenITGOnlineLogin", "TwoPlayerNotice")
		elseif connected() then
			status = THEME:GetString("ScreenITGOnlineLogin", "AlreadyConnected")
		end
		self:queuecommand("Refresh")
	end,
	RefreshCommand=function()
		refresh()
	end,

	Def.Quad{
		InitCommand=function(self) self:FullScreen():diffuse(0,0,0,0.82) end
	},

	LoadFont("Common Bold")..{
		Text=THEME:GetString("ScreenITGOnlineLogin", "Title"),
		InitCommand=function(self) self:xy(_screen.cx, _screen.cy - 160):zoom(0.62):diffuse(PlayerColor(PLAYER_1)) end
	},

	LoadFont("Common Normal")..{
		InitCommand=function(self) self:xy(_screen.cx, _screen.cy - 104):zoom(0.8):maxwidth(760) end,
		RefreshCommand=function(self)
			config = ITGOnline:Config()
			local user = connected() and ITGOnline.user and (ITGOnline.user.name or ITGOnline.user.email) or nil
			local text = connected()
				and THEME:GetString("ScreenITGOnlineLogin", "ConnectedAs"):format(tostring(user or "ITG Online"))
				or THEME:GetString("ScreenITGOnlineLogin", "NotConnected")
			self:settext(text)
		end,
		ITGOnlineLoginStateChangedMessageCommand=function(self) self:playcommand("Refresh") end,
		OnCommand=function(self) self:queuecommand("Refresh") end,
	},

	LoadFont("Common Normal")..{
		InitCommand=function(self) self:xy(_screen.cx - 260, _screen.cy - 36):halign(0):zoom(0.7):maxwidth(640) end,
		RefreshCommand=function(self)
			config = ITGOnline:Config()
			self:settext(THEME:GetString("ScreenITGOnlineLogin", "EmailLabel") .. " " .. (config.email ~= "" and config.email or "(not set)"))
		end,
		ITGOnlineLoginStateChangedMessageCommand=function(self) self:playcommand("Refresh") end,
		OnCommand=function(self) self:queuecommand("Refresh") end,
	},

	LoadFont("Common Normal")..{
		InitCommand=function(self) self:xy(_screen.cx - 260, _screen.cy - 8):halign(0):zoom(0.7):maxwidth(640) end,
		RefreshCommand=function(self)
			config = ITGOnline:Config()
			self:settext(THEME:GetString("ScreenITGOnlineLogin", "PasswordLabel") .. " " .. mask_password(config.password, config.passwordStoredSecurely))
		end,
		ITGOnlineLoginStateChangedMessageCommand=function(self) self:playcommand("Refresh") end,
		OnCommand=function(self) self:queuecommand("Refresh") end,
	},

	LoadFont("Common Normal")..{
		InitCommand=function(self) self:xy(_screen.cx, _screen.cy + 34):zoom(0.66):maxwidth(760):diffuse(1,0.85,0.45,1) end,
		RefreshCommand=function(self) self:settext(status) end,
		ITGOnlineLoginStateChangedMessageCommand=function(self) self:playcommand("Refresh") end,
		OnCommand=function(self) self:queuecommand("Refresh") end,
	},

	LoadFont("Common Normal")..{
		InitCommand=function(self) self:xy(_screen.cx, _screen.cy + 126):zoom(0.78):maxwidth(760) end,
		RefreshCommand=function(self)
			local rows = option_rows()
			if selection > #rows then selection = #rows end
			local labels = {}
			for i, row in ipairs(rows) do
				local label = THEME:GetString("ScreenITGOnlineLogin", row)
				if i == selection then label = "> " .. label .. " <" end
				labels[#labels + 1] = label
			end
			self:settext(table.concat(labels, "\n"))
		end,
		ITGOnlineLoginStateChangedMessageCommand=function(self) self:playcommand("Refresh") end,
		OnCommand=function(self) self:queuecommand("Refresh") end,
	},

	LoadFont("Common Normal")..{
		Text=THEME:GetString("ScreenITGOnlineLogin", "Help"),
		InitCommand=function(self) self:xy(_screen.cx, _screen.cy + 214):zoom(0.56):maxwidth(760):diffuse(0.8,0.8,0.8,1) end,
	},
}

return t
