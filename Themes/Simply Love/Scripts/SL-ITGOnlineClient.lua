-- -----------------------------------------------------------------------
-- ITG Online API client.
--
-- This bridges Simply Love's existing online-lobby UI to the Laravel server.
-- Save/ITGOnline.ini stores connection settings only; the password is kept in
-- native secure storage when available, otherwise only in memory for the
-- current session. It is never persisted to Save/ITGOnline.ini.

ITGOnline = ITGOnline or {}

ITGOnline.configPath = "/Save/ITGOnline.ini"
ITGOnline.passwordService = "ITG Online Password"
ITGOnline.defaults = {
	apiBaseUrl = "https://itgonline.fr/api/v1",
	webSocketUrl = "wss://ws.itgonline.fr",
	deviceName = "itgmania-client",
}

ITGOnline.requests = ITGOnline.requests or {}
ITGOnline.nextRequestId = ITGOnline.nextRequestId or 1
ITGOnline.requestIdCounter = ITGOnline.requestIdCounter or 0
ITGOnline.token = ITGOnline.token or nil
ITGOnline.user = ITGOnline.user or nil
ITGOnline.socket = ITGOnline.socket or nil
ITGOnline.currentRoomId = ITGOnline.currentRoomId or nil
ITGOnline.currentRoom = ITGOnline.currentRoom or nil
ITGOnline.currentSongPayload = ITGOnline.currentSongPayload or nil
ITGOnline.pendingJoinRoomId = ITGOnline.pendingJoinRoomId or nil
ITGOnline.lastScoreSentAt = ITGOnline.lastScoreSentAt or 0
ITGOnline.scheduledStartLocalTime = ITGOnline.scheduledStartLocalTime or nil
ITGOnline.sessionExpired = ITGOnline.sessionExpired or false
ITGOnline.disconnecting = ITGOnline.disconnecting or false
ITGOnline.lastEventCursor = ITGOnline.lastEventCursor or 0
ITGOnline.lastRealtimeMessageAt = ITGOnline.lastRealtimeMessageAt or GetTimeSinceStart()
ITGOnline.lastSyncRequestedAt = ITGOnline.lastSyncRequestedAt or 0
ITGOnline.screenGeneration = ITGOnline.screenGeneration or 0
ITGOnline.currentScreenName = ITGOnline.currentScreenName or "NoScreen"
ITGOnline.authRefreshInFlight = ITGOnline.authRefreshInFlight or false
ITGOnline.authRefreshCallbacks = ITGOnline.authRefreshCallbacks or {}
ITGOnline.authRefreshFailureCount = ITGOnline.authRefreshFailureCount or 0
ITGOnline.maxAuthRefreshFailures = ITGOnline.maxAuthRefreshFailures or 3
ITGOnline.authRefreshNextAttemptAt = ITGOnline.authRefreshNextAttemptAt or 0
ITGOnline.authRefreshMaxBackoffSeconds = ITGOnline.authRefreshMaxBackoffSeconds or 30
ITGOnline.lastFinalScoreRoomId = ITGOnline.lastFinalScoreRoomId or nil
ITGOnline.lastScorePositionKey = ITGOnline.lastScorePositionKey or nil
ITGOnline.lastScoreSongPosition = ITGOnline.lastScoreSongPosition or 0
ITGOnline.lastAcceptedScoreFingerprint = ITGOnline.lastAcceptedScoreFingerprint or nil
ITGOnline.scoreInFlightFingerprint = ITGOnline.scoreInFlightFingerprint or nil
ITGOnline.lastDisplayedScoreSnapshot = ITGOnline.lastDisplayedScoreSnapshot or nil
ITGOnline.lastLeaderboardVersionByRoomId = ITGOnline.lastLeaderboardVersionByRoomId or {}
ITGOnline.needsSyncAfterScreenCancel = ITGOnline.needsSyncAfterScreenCancel or false
ITGOnline.songLoadedAckKey = ITGOnline.songLoadedAckKey or ""
ITGOnline.songLoadedInFlightKey = ITGOnline.songLoadedInFlightKey or ""
ITGOnline.songLoadedPendingCallbacks = ITGOnline.songLoadedPendingCallbacks or {}
ITGOnline.startScheduleAckKey = ITGOnline.startScheduleAckKey or ""
ITGOnline.startScheduleAckInFlightKey = ITGOnline.startScheduleAckInFlightKey or ""
ITGOnline.managerAutoReadyInFlightKey = ITGOnline.managerAutoReadyInFlightKey or ""
ITGOnline.managerAutoReadyCompletedKey = ITGOnline.managerAutoReadyCompletedKey or ""
ITGOnline.readyRequestInFlight = ITGOnline.readyRequestInFlight or {}
ITGOnline.readyRequestLastResult = ITGOnline.readyRequestLastResult or {}
ITGOnline.readyRequestReplayWindowSeconds = ITGOnline.readyRequestReplayWindowSeconds or 1.0
ITGOnline.serverClockOffsetSeconds = ITGOnline.serverClockOffsetSeconds or nil
ITGOnline.lastClockSyncAt = ITGOnline.lastClockSyncAt or 0
ITGOnline.lastClockRttSeconds = ITGOnline.lastClockRttSeconds or nil
ITGOnline.syncMaxPages = ITGOnline.syncMaxPages or 100
ITGOnline.syncOverflowMaxRetries = ITGOnline.syncOverflowMaxRetries or 3
ITGOnline.syncOverflowMaxBudgetMultiplier = ITGOnline.syncOverflowMaxBudgetMultiplier or 4
ITGOnline.syncInFlight = ITGOnline.syncInFlight or false
ITGOnline.syncQueued = ITGOnline.syncQueued or false
ITGOnline.syncCallbacks = ITGOnline.syncCallbacks or {}
ITGOnline.syncGeneration = ITGOnline.syncGeneration or 0
ITGOnline.onlineGameplayEnteredKey = ITGOnline.onlineGameplayEnteredKey or ""
ITGOnline.onlineGameplayReturnedKey = ITGOnline.onlineGameplayReturnedKey or ""
ITGOnline.previousScreenName = ITGOnline.previousScreenName or nil

local function trim(value)
	return tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function url_host(value)
	return tostring(value or ""):match("^[A-Za-z]+://([^/:]+)")
end

local function is_local_host(host)
	if not host then return false end
	host = tostring(host):lower():gsub("^%[", ""):gsub("%]$", "")
	return host == "localhost" or host == "127.0.0.1" or host == "::1"
end

local function normalize_base_url(value)
	value = trim(value)
	if value == "" then return ITGOnline.defaults.apiBaseUrl end
	value = value:gsub("/+$", "")
	local lower = value:lower()
	if lower:match("^https://") then return value end
	if lower:match("^http://") and is_local_host(url_host(value)) then return value end
	return ITGOnline.defaults.apiBaseUrl
end

local function normalize_websocket_url(value)
	value = trim(value)
	if value == "" then return ITGOnline.defaults.webSocketUrl end
	local lower = value:lower()
	if lower:match("^wss://") then return value end
	if lower:match("^ws://") and is_local_host(url_host(value)) then return value end
	return ITGOnline.defaults.webSocketUrl
end

local function origin_from_base_url(value)
	value = normalize_base_url(value)
	return value:match("^(https?://[^/]+)") or ""
end

local online_trace

local function secure_credentials_available()
	return NETWORK and NETWORK.SecureCredentialIsAvailable and NETWORK:SecureCredentialIsAvailable()
end

local function secure_credentials_backend()
	if NETWORK and NETWORK.SecureCredentialBackend then
		return tostring(NETWORK:SecureCredentialBackend() or "unavailable")
	end
	return "unavailable"
end

local function secure_password_account(apiBaseUrl, email)
	email = trim(email):lower()
	if email == "" then return "" end
	return normalize_base_url(apiBaseUrl) .. "|" .. email
end

local function secure_password_get(apiBaseUrl, email)
	if not secure_credentials_available() then return nil, false end

	local account = secure_password_account(apiBaseUrl, email)
	if account == "" then return nil, false end

	local result = NETWORK:SecureCredentialGet(ITGOnline.passwordService, account)
	if result and result.ok and tostring(result.secret or "") ~= "" then
		return tostring(result.secret), true
	end

	return nil, false
end

local function secure_password_set(apiBaseUrl, email, password)
	if not secure_credentials_available() then return false end

	local account = secure_password_account(apiBaseUrl, email)
	if account == "" or tostring(password or "") == "" then return false end

	local result = NETWORK:SecureCredentialSet(ITGOnline.passwordService, account, tostring(password))
	if not result or not result.ok then
		online_trace("Secure password save failed using " .. secure_credentials_backend() .. ": " .. tostring(result and result.error or "unknown"))
		return false
	end

	return true
end

local function secure_password_delete(apiBaseUrl, email)
	if not secure_credentials_available() then return false end

	local account = secure_password_account(apiBaseUrl, email)
	if account == "" then return false end

	local result = NETWORK:SecureCredentialDelete(ITGOnline.passwordService, account)
	return result and result.ok
end

local function safe_decode(body)
	if type(body) ~= "string" or body == "" then return nil end
	local ok, decoded = pcall(JsonDecode, body)
	if ok then return decoded end
	return nil
end

local function response_message(response, decoded, fallback)
	if response and response.errorMessage then return response.errorMessage end
	if response and response.error then return fallback .. " (" .. tostring(response.error) .. ")" end
	if decoded and decoded.message then return decoded.message end
	if response and response.statusCode then return fallback .. " (" .. tostring(response.statusCode) .. ")" end
	return fallback
end

function online_trace(message)
	local line = "ITG Online: " .. tostring(message or "")
	if Warn then Warn(line) elseif Trace then Trace(line) end
end

local function online_flow_trace(message)
	local screen = SCREENMAN and SCREENMAN:GetTopScreen() or nil
	local screenName = screen and screen:GetName() or "NoScreen"
	local phase = ITGOnline and ITGOnline.currentRoom and ITGOnline.currentRoom.phase or "no-room"
	local roomId = ITGOnline and ITGOnline.currentRoomId or "no-room-id"
	online_trace("FLOW room=" .. tostring(roomId)
		.. " phase=" .. tostring(phase)
		.. " screen=" .. tostring(screenName)
		.. " " .. tostring(message or ""))
end

local function request_id()
	if CRYPTMAN and CRYPTMAN.GenerateRandomUUID then
		return CRYPTMAN:GenerateRandomUUID()
	end

	ITGOnline.requestIdCounter = (tonumber(ITGOnline.requestIdCounter) or 0) + 1
	local millis = math.floor((GetTimeSinceStart() or 0) * 1000)
	return tostring(millis) .. "-" .. tostring(ITGOnline.requestIdCounter)
end

local function days_from_civil(year, month, day)
	year = year - (month <= 2 and 1 or 0)
	local era = math.floor(year / 400)
	local yoe = year - era * 400
	local mp = month + (month > 2 and -3 or 9)
	local doy = math.floor((153 * mp + 2) / 5) + day - 1
	local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
	return era * 146097 + doe - 719468
end

local function iso_utc_milliseconds(value)
	if type(value) ~= "string" then return nil end

	local year, month, day, hour, minute, second, fraction = value:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d):(%d%d)%.?(%d*)Z$")
	if not year then return nil end
	year = tonumber(year)
	month = tonumber(month)
	day = tonumber(day)
	hour = tonumber(hour)
	minute = tonumber(minute)
	second = tonumber(second)
	if not year or not month or not day or not hour or not minute or not second then return nil end
	if year < 1970 or year > 2100 or month < 1 or month > 12 or day < 1 or day > 31 then return nil end
	if hour > 23 or minute > 59 or second > 60 then return nil end

	local days = days_from_civil(year, month, day)
	local seconds = (((days * 24 + hour) * 60 + minute) * 60) + second
	local milliseconds = tonumber((fraction or ""):sub(1, 3)) or 0
	if fraction and #fraction == 1 then milliseconds = milliseconds * 100 end
	if fraction and #fraction == 2 then milliseconds = milliseconds * 10 end

	return seconds * 1000 + milliseconds
end

local function first_enabled_player()
	for player in ivalues(GAMESTATE:GetEnabledPlayers()) do
		if GAMESTATE:IsSideJoined(player) then return player end
	end
	return PLAYER_1
end

local function local_profile_name()
	local player = first_enabled_player()
	if player and PROFILEMAN:IsPersistentProfile(player) and PROFILEMAN:GetProfile(player) then
		local name = PROFILEMAN:GetProfile(player):GetDisplayName()
		if name and name ~= "" then return name end
	end
	return "ITG Player"
end

local function song_path(song)
	if not song then return "" end
	local path = song:GetSongDir() or ""
	return path:gsub("^/Songs/", ""):gsub("/$", "")
end

local function sha256_hex(value)
	return BinaryToHex(CRYPTMAN:SHA256String(tostring(value or ""))):lower()
end

local function sha256_file_hex(path)
	if not path or path == "" or not CRYPTMAN or not CRYPTMAN.SHA256File then return nil end
	local ok, digest = pcall(function() return CRYPTMAN:SHA256File(path) end)
	if ok and digest and digest ~= "" then
		return BinaryToHex(digest):lower()
	end
	return nil
end

local function manifest_file_name(path)
	local value = tostring(path or ""):gsub("\\", "/")
	local name = value:match("([^/]+)$") or ""
	name = name:gsub("[^%w%._%- ]", "_")
	if name == "" then return nil end
	return name
end

local function normalized_hash(value)
	value = tostring(value or ""):lower()
	if value:match("^[a-f0-9]+$") and #value == 64 then return value end
	return sha256_hex(value)
end

local function selected_steps()
	local player = first_enabled_player()
	return (GAMESTATE:IsCourseMode() and GAMESTATE:GetCurrentTrail(player)) or GAMESTATE:GetCurrentSteps(player)
end

local function current_chart_note_count(steps)
	if not steps or not steps.GetRadarValues then return nil end

	local player = first_enabled_player()
	local ok, radar = pcall(function() return steps:GetRadarValues(player) end)
	if not ok or not radar or not radar.GetValue then return nil end

	local function radar_value(name)
		local valueOk, value = pcall(function() return radar:GetValue("RadarCategory_" .. name) end)
		return valueOk and tonumber(value) or 0
	end

	local total = math.floor(
		math.max(0, radar_value("TapsAndHolds")) +
		math.max(0, radar_value("Holds")) +
		math.max(0, radar_value("Rolls"))
	)

	return total > 0 and total or nil
end

local function server_max_score_for_note_count(noteCount)
	local scoring = ITGOnline and ITGOnline.serverPolicy and ITGOnline.serverPolicy.scoring or {}
	local maxScore = tonumber(scoring.max_score) or 1000000
	local maxScorePerNote = tonumber(scoring.max_score_per_note) or 1000

	return math.max(1, math.min(maxScore, math.floor((tonumber(noteCount) or 0) * maxScorePerNote)))
end

local function has_server_scoring_policy()
	local scoring = ITGOnline and ITGOnline.serverPolicy and ITGOnline.serverPolicy.scoring or {}
	return tonumber(scoring.max_score) ~= nil and tonumber(scoring.max_score_per_note) ~= nil
end

local function song_steps_seconds(song)
	if song and song.GetStepsSeconds then
		local ok, seconds = pcall(function() return song:GetStepsSeconds() end)
		seconds = ok and tonumber(seconds) or nil
		if seconds and seconds > 0 then return seconds end
	end

	if song and song.GetLastSecond and song.GetFirstSecond then
		local ok, lastSecond, firstSecond = pcall(function() return song:GetLastSecond(), song:GetFirstSecond() end)
		lastSecond = ok and tonumber(lastSecond) or nil
		firstSecond = ok and tonumber(firstSecond) or 0
		if lastSecond and lastSecond > firstSecond then return lastSecond - firstSecond end
	end

	return song and song.MusicLengthSeconds and song:MusicLengthSeconds() or 1
end

local function current_music_rate()
	if not GAMESTATE or not GAMESTATE.GetSongOptionsObject then return 1.0 end

	local ok, options = pcall(function() return GAMESTATE:GetSongOptionsObject("ModsLevel_Preferred") end)
	if not ok or not options or not options.MusicRate then return 1.0 end

	local rateOk, rate = pcall(function() return options:MusicRate() end)
	rate = rateOk and tonumber(rate) or nil
	if not rate or rate <= 0 then return 1.0 end

	return math.max(0.25, math.min(3.0, rate))
end

local function current_speed_mod_label()
	local player = first_enabled_player()
	local pn = player and ToEnumShortString(player) or "P1"
	local activeModifiers = SL and SL[pn] and SL[pn].ActiveModifiers or nil
	if not activeModifiers then return nil end

	local speedModType = tostring(activeModifiers.SpeedModType or "")
	local speedMod = tonumber(activeModifiers.SpeedMod)
	if not speedMod or speedMod <= 0 then return nil end

	if speedModType == "X" then
		return string.format("%.2fx", speedMod)
	end

	if speedModType == "C" or speedModType == "M" then
		return speedModType .. string.format("%g", speedMod)
	end

	return string.format("%g", speedMod)
end

local function current_stepchart_label()
	local steps = selected_steps()
	if not steps then return nil end

	local chartType = tostring(ToEnumShortString(steps:GetStepsType()) or ""):gsub("_", "-"):lower()
	local difficulty = ToEnumShortString(steps:GetDifficulty())
	local meter = tonumber(steps:GetMeter())

	local chartLabel = chartType ~= "" and chartType or "unknown"
	local difficultyLabel = difficulty ~= "" and difficulty or "unknown"

	if meter and meter > 0 then
		return chartLabel .. "/" .. difficultyLabel .. " " .. tostring(math.floor(meter))
	end

	return chartLabel .. "/" .. difficultyLabel
end

local function enum_short(value)
	if value == nil then return "" end
	return ToEnumShortString(value)
end

local function current_game_name()
	local game = GAMESTATE:GetCurrentGame()
	if game and game.GetName then
		local name = game:GetName()
		if name and name ~= "" then return tostring(name):lower() end
	end

	return "dance"
end

local function normalize_chart_type(value)
	local raw = tostring(value or ""):gsub("_", "-")
	local lower = raw:lower()

	local direct = {
		["dance-single"] = "dance-single",
		["dance-double"] = "dance-double",
		["dance-couple"] = "dance-couple",
		["dance-solo"] = "dance-solo",
		["pump-single"] = "pump-single",
		["pump-double"] = "pump-double",
	}
	if direct[lower] then return direct[lower] end

	local game = current_game_name()
	local short = {
		single = game .. "-single",
		double = game .. "-double",
		couple = game .. "-couple",
		solo = game .. "-solo",
	}
	if short[lower] then return short[lower] end

	return lower
end

local function read_config()
	if not FILEMAN:DoesFileExist(ITGOnline.configPath) then
		IniFile.WriteFile(ITGOnline.configPath, {
			["ITGOnline"] = {
					["ApiBaseUrl"] = ITGOnline.defaults.apiBaseUrl,
					["WebSocketUrl"] = ITGOnline.defaults.webSocketUrl,
					["Email"] = "",
					["DeviceName"] = ITGOnline.defaults.deviceName,
				}
			})
	end

	local raw = IniFile.ReadFile(ITGOnline.configPath) or {}
	local section = raw["ITGOnline"] or {}
	local apiBaseUrl = normalize_base_url(section["ApiBaseUrl"])
	local email = trim(section["Email"])
	local securePassword, securePasswordStored = secure_password_get(apiBaseUrl, email)

	return {
			apiBaseUrl = apiBaseUrl,
			webSocketUrl = normalize_websocket_url(section["WebSocketUrl"]),
			email = email,
			password = tostring(securePassword or ""),
			passwordStoredSecurely = securePasswordStored,
			secureCredentialsBackend = secure_credentials_backend(),
			deviceName = trim(section["DeviceName"]) ~= "" and trim(section["DeviceName"]) or ITGOnline.defaults.deviceName,
		}
	end

function ITGOnline:Config()
	self.config = read_config()
	return self.config
end

function ITGOnline:SaveConfig(values)
	local current = self:Config()
	values = values or {}

	local nextConfig = {
			apiBaseUrl = normalize_base_url(values.apiBaseUrl or current.apiBaseUrl),
			webSocketUrl = normalize_websocket_url(values.webSocketUrl or current.webSocketUrl),
			email = trim(values.email or current.email),
			deviceName = trim(values.deviceName or current.deviceName) ~= "" and trim(values.deviceName or current.deviceName) or ITGOnline.defaults.deviceName,
		}

	local passwordWasProvided = values.password ~= nil
	local nextPassword = tostring(passwordWasProvided and values.password or current.password or "")
	local securePasswordStored = false

	if passwordWasProvided then
		if nextPassword == "" then
			secure_password_delete(current.apiBaseUrl, current.email)
			secure_password_delete(nextConfig.apiBaseUrl, nextConfig.email)
		else
			securePasswordStored = secure_password_set(nextConfig.apiBaseUrl, nextConfig.email, nextPassword)
		end
	else
		local storedPassword
		storedPassword, securePasswordStored = secure_password_get(nextConfig.apiBaseUrl, nextConfig.email)
		if storedPassword and storedPassword ~= "" then
			nextPassword = storedPassword
		elseif nextConfig.email ~= current.email or nextConfig.apiBaseUrl ~= current.apiBaseUrl then
			nextPassword = ""
		end
	end

	nextConfig.password = nextPassword
	nextConfig.passwordStoredSecurely = securePasswordStored
	nextConfig.secureCredentialsBackend = secure_credentials_backend()

		IniFile.WriteFile(ITGOnline.configPath, {
			["ITGOnline"] = {
				["ApiBaseUrl"] = nextConfig.apiBaseUrl,
				["WebSocketUrl"] = nextConfig.webSocketUrl,
				["Email"] = nextConfig.email,
				["DeviceName"] = nextConfig.deviceName,
			}
		})

	self.config = nextConfig
	return nextConfig
end

function ITGOnline:ClearTransientSecrets()
	ITGOnline.transientPassword = nil
	if self.config then
		self.config.password = ""
	end
end

function ITGOnline:Configured()
	local config = self:Config()
	return config.email ~= "" and config.password ~= ""
end

function ITGOnline:AuthHeaders()
	local headers = {
		["Accept"] = "application/json",
		["Content-Type"] = "application/json",
	}
	if self.token then
		headers["Authorization"] = "Bearer " .. tostring(self.token)
	end
	return headers
end

function ITGOnline:Request(method, path, payload, callback, alreadyRetriedAuth, options)
	options = options or {}
	local config = self:Config()
	local url = config.apiBaseUrl .. path
	local encodeOk, body = pcall(JsonEncode, payload or {})
	if not encodeOk then
		if callback then callback(false, nil, { errorMessage = "Request payload could not be encoded." }) end
		return
	end
	if payload == nil then body = "" end

	local requestId = self.nextRequestId
	self.nextRequestId = self.nextRequestId + 1
	local traceId = request_id()
	self.requests[requestId] = {
		future = nil,
		cancelled = false,
		cancelOnScreenChange = options.cancelOnScreenChange == true,
		resyncAfterCancel = options.resyncAfterCancel ~= false and options.cancelOnScreenChange == true,
		screenGeneration = self.screenGeneration,
	}

	local headers = {
		["Accept"] = "application/json",
		["Content-Type"] = "application/json",
		["X-Request-ID"] = traceId,
	}
	if self.token then
		headers["Authorization"] = "Bearer " .. self.token
	end

	online_trace(method .. " " .. path .. " [" .. traceId .. "]")
	local startedAt = GetTimeSinceStart()
	local request = NETWORK:HttpRequest{
		url = url,
		method = method,
		body = body,
		headers = headers,
		connectTimeout = 5,
		transferTimeout = 45,
			onResponse = function(response)
				local record = ITGOnline.requests[requestId]
				if record and record.cancelled then
					ITGOnline.requests[requestId] = nil
					if record.resyncAfterCancel and self.Sync then
						self.needsSyncAfterScreenCancel = true
						self:Sync()
					end
					return
				end
				if not record then
					return
				end

			ITGOnline.requests[requestId] = nil
			local decoded = safe_decode(response and response.body)
				local ok = response and response.statusCode and response.statusCode >= 200 and response.statusCode < 300
				local duration = math.floor((GetTimeSinceStart() - startedAt) * 1000)
				if decoded and decoded.server_time and self.UpdateServerClockOffset then
					self:UpdateServerClockOffset(decoded.server_time, startedAt, GetTimeSinceStart())
				end
				local responseBytes = response and response.body and #tostring(response.body) or 0
			local errorCode = decoded and decoded.error_code or response and response.error or nil
			online_trace(method .. " " .. path .. " -> " .. tostring(response and response.statusCode or "no-status") .. " in " .. tostring(duration) .. "ms, " .. tostring(responseBytes) .. "b" .. (errorCode and (", error=" .. tostring(errorCode)) or "") .. " [" .. traceId .. "]")
				if not ok and decoded and decoded.message then
					online_trace(method .. " " .. path .. " message: " .. tostring(decoded.message))
				end

			if response and response.statusCode == 401 and path ~= "/auth/login" and path ~= "/auth/refresh" and not self.disconnecting and not alreadyRetriedAuth then
				if (self.authRefreshFailureCount or 0) >= (self.maxAuthRefreshFailures or 3) then
					self.sessionExpired = true
					if self.socket then self.socket:Close() end
					self.socket = nil
					self:ClearTransientSecrets()
					MESSAGEMAN:Broadcast("OnlineSessionExpired")
					if callback then callback(false, decoded, response) end
					return
				end

				self:Relogin(function(loginOk)
					if loginOk then
						self:Request(method, path, payload, callback, true, options)
						return
					end

					self.sessionExpired = true
					if self.socket then self.socket:Close() end
					self.socket = nil
					self:ClearTransientSecrets()
					MESSAGEMAN:Broadcast("OnlineSessionExpired")
					if callback then callback(false, decoded, response) end
				end)
				return
			end

			if callback then callback(ok, decoded, response) end
		end,
	}
		if self.requests[requestId] then
			self.requests[requestId].future = request
		end
	end

function ITGOnline:UpdateServerClockOffset(serverTime, localStartedAt, localReceivedAt)
	local serverTimeMs = tonumber(serverTime or "") or iso_utc_milliseconds(serverTime)
	if not serverTimeMs then return end

	local midpoint = ((tonumber(localStartedAt) or GetTimeSinceStart()) + (tonumber(localReceivedAt) or GetTimeSinceStart())) / 2
	local observedOffset = (serverTimeMs / 1000) - midpoint
	local rttSeconds = math.max(0, (tonumber(localReceivedAt) or GetTimeSinceStart()) - (tonumber(localStartedAt) or GetTimeSinceStart()))
	if not self.serverClockOffsetSeconds then
		self.serverClockOffsetSeconds = observedOffset
	else
		self.serverClockOffsetSeconds = (self.serverClockOffsetSeconds * 0.8) + (observedOffset * 0.2)
	end
	self.lastClockSyncAt = GetTimeSinceStart()
	self.lastClockRttSeconds = rttSeconds
end

function ITGOnline:ClockSyncIsFresh()
	return self.serverClockOffsetSeconds ~= nil
		and (GetTimeSinceStart() - (self.lastClockSyncAt or 0)) <= 15
		and (tonumber(self.lastClockRttSeconds) or 999) <= 2
end

function ITGOnline:CancelPendingRequests()
	for _, request in pairs(self.requests or {}) do
		request.cancelled = true
		if request.future and request.future.Cancel then
			request.future:Cancel()
		end
	end
	self.requests = {}
end

function ITGOnline:CancelScreenBoundRequests()
	local cancelledAny = false
	for requestId, request in pairs(self.requests or {}) do
		if request.cancelOnScreenChange == true and request.screenGeneration ~= self.screenGeneration then
			request.cancelled = true
			if request.future and request.future.Cancel then
				request.future:Cancel()
			end
			self.requests[requestId] = nil
			cancelledAny = true
		end
	end
	if cancelledAny then
		self.needsSyncAfterScreenCancel = true
		if not self.disconnecting and self.Sync then
			self:Sync()
		end
	end
end

function ITGOnline:ConsumeNeedsSyncAfterScreenCancel()
	if not self.needsSyncAfterScreenCancel then return false end
	self.needsSyncAfterScreenCancel = false
	return true
end

function ITGOnline:IsCurrentUserRoomManager(room)
	if not room or not room.manager or not self.user then return false end
	return tonumber(room.manager.id) == tonumber(self.user.id)
end

function ITGOnline:IsCurrentUserReadyInRoom(room)
	if not room or not self.user or not room.ready_states then return false end
	local currentUserId = tonumber(self.user.id)
	if not currentUserId then return false end

	for state in ivalues(room.ready_states or {}) do
		local stateUserId = tonumber((state.user and state.user.id) or state.user_id)
		if stateUserId == currentUserId then
			return state.is_ready and true or false
		end
	end

	return false
end

function ITGOnline:ManagerAutoReadyKey(room, readyPhase)
	local roomId = tostring(room and room.id or "")
	local chartHash = tostring(room and room.selected_song and room.selected_song.chart_hash or "")
	return roomId .. "|" .. tostring(readyPhase or "") .. "|" .. chartHash
end

function ITGOnline:MaybeAutoReadyManager(room)
	room = room or self.currentRoom
	if not room or not room.id or not self.currentRoomId then return end
	local currentRoom = self.currentRoom
	if currentRoom and tonumber(currentRoom.id) == tonumber(room.id) then
		room = currentRoom
	end
	if not self:IsCurrentUserRoomManager(room) then return end

	local normalizedPhase = self:NormalizeRoomPhase(room.phase)
	local readyPhase = nil
	if normalizedPhase == "lobby_ready" then
		readyPhase = "lobby_ready"
	elseif normalizedPhase == "config" then
		readyPhase = "config_ready"
	else
		return
	end

	local key = self:ManagerAutoReadyKey(room, readyPhase)
	if self.managerAutoReadyCompletedKey == key then return end
	if self:IsCurrentUserReadyInRoom(room) then
		self.managerAutoReadyCompletedKey = key
		online_trace("manager_auto_ready skipped: already ready [" .. key .. "]")
		return
	end
	if self.managerAutoReadyInFlightKey == key then return end

	self.managerAutoReadyInFlightKey = key
	online_trace("manager_auto_ready sending phase=" .. tostring(readyPhase) .. " key=" .. key)
	self:SetReady(readyPhase, true, function(ok, decoded)
		if self.managerAutoReadyInFlightKey == key then
			self.managerAutoReadyInFlightKey = ""
		end

		if not ok then
			if decoded and decoded.error_code == "room_phase_not_accepting_lobby_ready" then
				-- Stale phase race: avoid immediate replay storm on the same key.
				self.managerAutoReadyCompletedKey = key
			end
			online_trace("manager_auto_ready failed key=" .. key)
			return
		end

		self.managerAutoReadyCompletedKey = key
		online_trace("manager_auto_ready success key=" .. key)
		if decoded and decoded.room then
			self.currentRoom = decoded.room
			MESSAGEMAN:Broadcast("OnlineLobbyState", self:LobbyStatePayload(decoded.room))
		end
	end)
end

function ITGOnline:IsOnlineGameplayScreen(screenName)
	return screenName == "ScreenGameplay" or screenName == "ScreenGameplayShared"
end

function ITGOnline:IsOnlineOptionsScreen(screenName)
	return screenName == "ScreenPlayerOptions"
		or screenName == "ScreenPlayerOptions2"
		or screenName == "ScreenPlayerOptions3"
end

function ITGOnline:IsOnlineLobbyScreen(screenName)
	return screenName == "ScreenOnlineLobbies"
end

function ITGOnline:IsOnlineMusicSelectScreen(screenName)
	return screenName == "ScreenSelectMusic"
end

function ITGOnline:NormalizeRoomPhase(value)
	local phase = tostring(value or ""):lower()
	if phase == "lobby" or phase == "lobby_ready" or phase == "config"
		or phase == "starting" or phase == "playing" or phase == "results" then
		return phase
	end
	return "unknown"
end

function ITGOnline:CurrentUserPlayState(room)
	if not room or not self.user then return nil end
	local userId = tonumber(self.user.id)
	if not userId then return nil end

	local sessions = room.play_state and room.play_state.sessions or {}
	for session in ivalues(sessions or {}) do
		local sessionUserId = tonumber((session.user and session.user.id) or session.user_id)
		if sessionUserId == userId then
			return tostring(session.state or "")
		end
	end

	return nil
end

function ITGOnline:PreferredScreenForRoomPhase(screenName)
	if not self.currentRoom then return nil end

	local phase = self:NormalizeRoomPhase(self.currentRoom.phase)
	local playState = tostring(self:CurrentUserPlayState(self.currentRoom) or "")
	local roundKey = self.PlayStateKey and self:PlayStateKey() or ""
	local localRoundEnded = roundKey ~= "|" and self.onlineGameplayEndedKey == roundKey

	if self:IsOnlineOptionsScreen(screenName)
		and (phase == "playing" or phase == "results")
	then
		online_flow_trace("preferred=lobby reason=options_during_terminal_or_playing playState=" .. tostring(playState) .. " roundEnded=" .. tostring(localRoundEnded))
		return "lobby"
	end

	if phase == "starting" then
		if localRoundEnded then
			online_flow_trace("preferred=nil reason=starting_after_local_round_end playState=" .. tostring(playState) .. " roundKey=" .. tostring(roundKey))
			return nil
		end
		online_flow_trace("preferred=gameplay reason=starting playState=" .. tostring(playState) .. " roundEnded=" .. tostring(localRoundEnded))
		return "gameplay"
	end

	if phase == "playing" then
		if self:IsOnlineGameplayScreen(screenName) then
			if playState ~= "playing" then
				online_flow_trace("preferred=lobby reason=gameplay_but_user_terminal playState=" .. tostring(playState))
				return "lobby"
			end
			return nil
		end

		if screenName == "ScreenEvaluationStage"
			or screenName == "ScreenEvaluationNonstop"
			or screenName == "ScreenEvaluationSummary"
		then
			online_flow_trace("preferred=nil reason=keep_evaluation_while_server_playing playState=" .. tostring(playState) .. " roundEnded=" .. tostring(localRoundEnded))
			return nil
		end

		-- Never auto-jump from lobby/options/music select back into gameplay while a song is already running.
		-- A player who left/quit mid-song must stay in lobby view and wait for the current round to end.
		online_flow_trace("preferred=lobby reason=playing_non_gameplay_screen playState=" .. tostring(playState) .. " roundEnded=" .. tostring(localRoundEnded))
		return "lobby"
	end

	if phase == "results" then
		if self:IsOnlineGameplayScreen(screenName) then
			online_flow_trace("preferred=evaluation reason=results_while_in_gameplay playState=" .. tostring(playState))
			return "evaluation"
		end
		return nil
	end

	if phase == "lobby" or phase == "lobby_ready" or phase == "config" then
		if self:IsOnlineGameplayScreen(screenName) then
			online_flow_trace("preferred=lobby reason=non_playing_phase_in_gameplay playState=" .. tostring(playState))
			return "lobby"
		end
		return nil
	end

	return nil
end

function ITGOnline:ApplyPreferredRoomScreen(topScreen, preferred)
	if not topScreen or not preferred then return false end

	local target = nil
	if preferred == "lobby" then
		target = "ScreenOnlineLobbies"
	elseif preferred == "gameplay" then
		local style = GAMESTATE:GetCurrentStyle() and GAMESTATE:GetCurrentStyle():GetName() or ""
		target = style == "routine" and "ScreenGameplayShared" or "ScreenGameplay"
	elseif preferred == "evaluation" then
		target = GAMESTATE:IsCourseMode() and "ScreenEvaluationNonstop" or "ScreenEvaluationStage"
	end

	if not target or topScreen:GetName() == target then return false end

	online_flow_trace("navigate target=" .. tostring(target) .. " preferred=" .. tostring(preferred) .. " from=" .. tostring(topScreen:GetName()))
	topScreen:SetNextScreenName(target)
	topScreen:StartTransitioningScreen("SM_GoToNextScreen")
	return true
end

function ITGOnline:EnforceRoomPhaseScreen(screenName)
	if not self.currentRoomId or not self.currentRoom then return false end
	local topScreen = SCREENMAN:GetTopScreen()
	if not topScreen then return false end

	local preferred = self:PreferredScreenForRoomPhase(screenName or topScreen:GetName())
	return self:ApplyPreferredRoomScreen(topScreen, preferred)
end

function ITGOnline:NoteScreenChanged(screenName)
	screenName = tostring(screenName or "NoScreen")
	if self.currentScreenName ~= screenName then
		local previous = self.currentScreenName
		self.currentScreenName = screenName
		self.screenGeneration = (self.screenGeneration or 0) + 1
		online_flow_trace("screen_changed previous=" .. tostring(previous) .. " next=" .. tostring(screenName) .. " generation=" .. tostring(self.screenGeneration))
		self:CancelScreenBoundRequests()
		self:HandleOnlineGameplayScreenTransition(previous, screenName)
		self:EnforceRoomPhaseScreen(screenName)
	end
end

function ITGOnline:HandleOnlineGameplayScreenTransition(previousScreenName, nextScreenName)
	if not self.currentRoomId or not self.currentRoom then return end

	local previousWasGameplay = self:IsOnlineGameplayScreen(previousScreenName)
	local nextIsGameplay = self:IsOnlineGameplayScreen(nextScreenName)
	local nextIsLobby = self:IsOnlineLobbyScreen(nextScreenName)
	local nextIsSelectMusic = self:IsOnlineMusicSelectScreen(nextScreenName)
	local nextIsEvaluation = nextScreenName == "ScreenEvaluationStage"
		or nextScreenName == "ScreenEvaluationNonstop"
		or nextScreenName == "ScreenEvaluationSummary"
	local roomPhase = self:NormalizeRoomPhase(self.currentRoom.phase)
	online_flow_trace("gameplay_transition previous=" .. tostring(previousScreenName)
		.. " next=" .. tostring(nextScreenName)
		.. " roomPhase=" .. tostring(roomPhase)
		.. " previousWasGameplay=" .. tostring(previousWasGameplay)
		.. " nextIsEvaluation=" .. tostring(nextIsEvaluation)
		.. " nextIsLobby=" .. tostring(nextIsLobby)
		.. " nextIsSelectMusic=" .. tostring(nextIsSelectMusic))

	if nextIsGameplay and roomPhase == "playing" then
		online_flow_trace("mark_play_entered reason=entered_gameplay")
		self:MarkPlayEntered()
	elseif previousWasGameplay and nextIsEvaluation and (roomPhase == "starting" or roomPhase == "playing" or roomPhase == "results") then
		-- Song finished locally: eagerly mark finished so the server session state
		-- no longer treats this player as actively playing.
		local roundKey = self.PlayStateKey and self:PlayStateKey() or ""
		if roundKey ~= "|" then
			self.onlineGameplayEndedKey = roundKey
		end

		local player = first_enabled_player()
		local stats = player and STATSMAN:GetCurStageStats():GetPlayerStageStats(player) or nil
		local failedOk, failedValue = pcall(function() return stats and stats:GetFailed() end)
		local markTerminal = function()
			local freshPhase = self.currentRoom and self:NormalizeRoomPhase(self.currentRoom.phase) or roomPhase
			online_flow_trace("mark_terminal freshPhase=" .. tostring(freshPhase)
				.. " failed=" .. tostring(failedOk and failedValue == true)
				.. " roundKey=" .. tostring(roundKey))
			if self.SendScore and (freshPhase == "playing" or freshPhase == "results") then
				self:SendScore(true, true)
				return
			end

			if failedOk and failedValue == true and self.MarkPlayFailed then
				self:MarkPlayFailed()
			else
				self:MarkPlayFinished()
			end
		end

		if roomPhase == "starting" and self.FetchRoom and self.currentRoomId then
			online_flow_trace("fetch_before_terminal_mark reason=left_gameplay_while_starting")
			self:FetchRoom(self.currentRoomId, function(ok, decoded)
				if ok and decoded and decoded.room then
					self.currentRoom = decoded.room
					local freshPhase = self:NormalizeRoomPhase(decoded.room.phase)
					online_flow_trace("fetch_before_terminal_mark result phase=" .. tostring(freshPhase))
					if freshPhase == "playing" or freshPhase == "results" then
						markTerminal()
					end
				else
					online_flow_trace("fetch_before_terminal_mark failed ok=" .. tostring(ok))
				end
			end)
		else
			markTerminal()
		end
	elseif previousWasGameplay and nextIsLobby and roomPhase == "playing" then
		online_flow_trace("mark_returned_to_lobby reason=gameplay_to_lobby")
		self:MarkReturnedToLobby()
	elseif previousWasGameplay and nextIsSelectMusic and (roomPhase == "playing" or roomPhase == "starting" or roomPhase == "results") then
		-- If a player leaves gameplay early, force the online flow back to the room lobby.
		online_flow_trace("mark_returned_to_lobby reason=gameplay_to_select_music roomPhase=" .. tostring(roomPhase))
		self:MarkReturnedToLobby()
	end
end

function ITGOnline:Login(callback)
	local config = self:Config()
	if config.email == "" or config.password == "" then
		if callback then callback(false, "Configure Save/ITGOnline.ini with Email and Password.") end
		return
	end

	self:Request("POST", "/auth/login", {
		email = config.email,
		password = config.password,
		device_name = config.deviceName,
	}, function(ok, decoded, response)
		if not ok or not decoded or not decoded.access_token then
			if callback then callback(false, response_message(response, decoded, "Login failed")) end
			return
			end

			self.token = decoded.access_token
			self.user = decoded.user
			self.sessionExpired = false
			self:ClearTransientSecrets()
			if callback then callback(true) end
		end)
	end

function ITGOnline:Register(name, callback)
	local config = self:Config()
	local password = tostring(config.password or "")
	if config.email == "" or password == "" or tostring(name or "") == "" then
		if callback then callback(false, nil, { errorMessage = "Name, email, and password are required." }) end
		return
	end

	self:Request("POST", "/auth/register", {
		name = tostring(name),
		email = config.email,
		password = password,
		password_confirmation = password,
	}, function(ok, decoded, response)
		self:ClearTransientSecrets()
		if callback then callback(ok, decoded, response) end
	end)
end

function ITGOnline:ResendVerification(callback)
	local config = self:Config()
	if config.email == "" then
		if callback then callback(false, nil, { errorMessage = "Email is required." }) end
		return
	end

	self:Request("POST", "/auth/email/resend", {
		email = config.email,
	}, callback)
end

function ITGOnline:ForgotPassword(callback)
	local config = self:Config()
	if config.email == "" then
		if callback then callback(false, nil, { errorMessage = "Email is required." }) end
		return
	end

	self:Request("POST", "/auth/password/forgot", {
		email = config.email,
	}, callback)
end

function ITGOnline:Relogin(callback)
	self.authRefreshCallbacks = self.authRefreshCallbacks or {}
	self.authRefreshCallbacks[#self.authRefreshCallbacks + 1] = callback

	if self.authRefreshInFlight then return end
	local nowTs = GetTimeSinceStart()
	if nowTs < (self.authRefreshNextAttemptAt or 0) then
		online_trace("Auth refresh skipped due to cooldown.")
		local callbacks = self.authRefreshCallbacks or {}
		self.authRefreshCallbacks = {}
		for cb in ivalues(callbacks) do
			if cb then cb(false) end
		end
		return
	end
	if (self.authRefreshFailureCount or 0) >= (self.maxAuthRefreshFailures or 3) then
		local callbacks = self.authRefreshCallbacks or {}
		self.authRefreshCallbacks = {}
		for cb in ivalues(callbacks) do
			if cb then cb(false) end
		end
		return
	end
	self.authRefreshInFlight = true

	if not self.token then
		self.authRefreshInFlight = false
		local callbacks = self.authRefreshCallbacks or {}
		self.authRefreshCallbacks = {}
		for cb in ivalues(callbacks) do
			if cb then cb(false) end
		end
		return
	end

	self:Request("POST", "/auth/refresh", {}, function(ok, decoded, response)
		self.authRefreshInFlight = false
		local callbacks = self.authRefreshCallbacks or {}
		self.authRefreshCallbacks = {}

		if ok and decoded and decoded.access_token then
			self.token = decoded.access_token
			self.user = decoded.user
			self.sessionExpired = false
			self.authRefreshFailureCount = 0
			self.authRefreshNextAttemptAt = 0
		else
			online_trace("Auth refresh failed: " .. response_message(response, decoded, "unknown"))
			self.token = nil
			self.user = nil
			self.authRefreshFailureCount = (self.authRefreshFailureCount or 0) + 1
			local failCount = math.max(1, self.authRefreshFailureCount or 1)
			local backoffSeconds = math.min(
				tonumber(self.authRefreshMaxBackoffSeconds) or 30,
				math.pow(2, math.max(0, failCount - 1))
			)
			self.authRefreshNextAttemptAt = GetTimeSinceStart() + backoffSeconds
		end

		for cb in ivalues(callbacks) do
			if cb then cb(ok and decoded and decoded.access_token ~= nil) end
		end
	end)
end

function ITGOnline:ConnectWebSocket(callbacks)
	self:Request("POST", "/websocket/tickets", {}, function(ok, decoded, response)
		if not ok or not decoded or not decoded.ticket then
			if callbacks and callbacks.error then
				callbacks.error(response_message(response, decoded, "WebSocket ticket request failed"))
			end
			return
		end

		local config = self:Config()
			self.socket = NETWORK:WebSocket{
				url = config.webSocketUrl,
					headers = {
						["Origin"] = origin_from_base_url(config.apiBaseUrl),
						["Cookie"] = "itgmania_ws_ticket=" .. tostring(decoded.ticket),
						["Sec-WebSocket-Protocol"] = "itgmania-ticket",
					},
			pingInterval = 20,
			automaticReconnect = false,
			onMessage = function(msg)
				local msgType = ToEnumShortString(msg.type)
				if msgType == "Open" then
					self.lastRealtimeMessageAt = GetTimeSinceStart()
					if callbacks and callbacks.open then callbacks.open() end
				elseif msgType == "Message" then
					self.lastRealtimeMessageAt = GetTimeSinceStart()
					local payload = safe_decode(msg.data)
					if payload and payload.id then
						self:SendRealtimeAck(payload.id)
					end
					self:HandleRealtimeEvent(payload)
					if callbacks and callbacks.message then callbacks.message(payload) end
				elseif msgType == "Close" then
					if callbacks and callbacks.close then callbacks.close(msg.reason) end
				elseif msgType == "Error" then
					if callbacks and callbacks.error then callbacks.error(msg.reason or "WebSocket error") end
				end
			end,
		}
	end)
end

function ITGOnline:SendRealtimeAck(eventId)
	if not self.socket or not eventId then return end
	local ok, encoded = pcall(JsonEncode, {
		action = "ack",
		event_id = tonumber(eventId),
	})
	if ok and encoded then
		self.socket:Send(encoded)
	end
end

function ITGOnline:Connect(callbacks)
	self.disconnecting = false
	if self.token and self.user and not self.sessionExpired then
		self:ConnectWebSocket(callbacks)
		return
	end

	self:Login(function(ok, errorMessage)
		if not ok then
			if callbacks and callbacks.error then callbacks.error(errorMessage) end
			return
		end
		self:ConnectWebSocket(callbacks)
	end)
end

function ITGOnline:Disconnect()
	self.disconnecting = true
	self:CancelPendingRequests()
	if self.token then
		local token = self.token
		self:Request("POST", "/auth/logout", {}, function() end)
		self.token = token
	end
	if self.socket then
		self.socket:Close()
	end
	self.socket = nil
	self.token = nil
	self.user = nil
	self.currentRoomId = nil
	self.currentRoom = nil
	self.currentSongPayload = nil
	self.lastDisplayedScoreSnapshot = nil
	self.pendingJoinRoomId = nil
		self.scheduledStartLocalTime = nil
		self.songLoadedAckKey = ""
		self.songLoadedInFlightKey = ""
	self.songLoadedPendingCallbacks = {}
	self.startScheduleAckKey = ""
	self.startScheduleAckInFlightKey = ""
	self.managerAutoReadyInFlightKey = ""
	self.managerAutoReadyCompletedKey = ""
	self.readyRequestInFlight = {}
	self.readyRequestLastResult = {}
	self.onlineGameplayEnteredKey = ""
	self.onlineGameplayReturnedKey = ""
	self.syncInFlight = false
	self.syncQueued = false
	self.syncCallbacks = {}
	self.syncGeneration = (self.syncGeneration or 0) + 1
	self:ClearTransientSecrets()
end

function ITGOnline:Sync(callback)
	if self.disconnecting then
		if callback then callback(false, nil, { errorMessage = "Client is disconnecting." }) end
		return
	end

	self.syncCallbacks = self.syncCallbacks or {}
	if callback then
		self.syncCallbacks[#self.syncCallbacks + 1] = callback
	end

	if self.syncInFlight then
		self.syncQueued = true
		return
	end

	self.syncInFlight = true
	self.syncQueued = false
	self.syncGeneration = (self.syncGeneration or 0) + 1
	local generation = self.syncGeneration
	local accumulator = {
		online_users = {},
		public_rooms = {},
		pending_join_requests = {},
		pending_invitations = {},
		events = {},
		next_cursor = tonumber(self.lastEventCursor or 0) or 0,
		snapshot_token = nil,
		syncOverflowAttempts = 0,
		syncPageBudgetMultiplier = 1,
	}
	self.syncAccumulator = accumulator
	self:SyncPages(accumulator, generation, 0)
end

function ITGOnline:FinishSync(generation, ok, decoded, response)
	if generation ~= self.syncGeneration then return end

	self.syncInFlight = false
	self.syncAccumulator = nil

	local callbacks = self.syncCallbacks or {}
	self.syncCallbacks = {}
	for cb in ivalues(callbacks) do
		if cb then cb(ok, decoded, response) end
	end

	local shouldRunQueuedSync = self.syncQueued and not self.disconnecting
	self.syncQueued = false
	if shouldRunQueuedSync then
		self:Sync()
	end
end

function ITGOnline:ApplySyncPayload(decoded)
	if not decoded then return end

	if decoded.server_policy then
		self.serverPolicy = decoded.server_policy
	end

	for event in ivalues(decoded.events or {}) do
		self:HandleRealtimeEvent(event)
	end

	if decoded.current_room then
		self.currentRoomId = decoded.current_room.id
		self.currentRoom = decoded.current_room
		self:MaybeAutoReadyManager(decoded.current_room)
		if decoded.current_room.selected_song then
			self.currentSongPayload = decoded.current_room.selected_song
		end
		MESSAGEMAN:Broadcast("OnlineLobbyState", self:LobbyStatePayload(decoded.current_room))
	else
		self.currentRoomId = nil
		self.currentRoom = nil
		self.currentSongPayload = nil
	end
	MESSAGEMAN:Broadcast("LobbySearched", self:LobbySearchPayload(decoded))

		for joinRequest in ivalues(decoded.pending_join_requests or {}) do
			MESSAGEMAN:Broadcast("OnlinePrivateJoinRequest", {
				join_request = {
					id = joinRequest.id,
					room_id = joinRequest.room_id,
					user_id = joinRequest.user and joinRequest.user.id or nil,
					status = "pending",
				},
				requester = joinRequest.user,
				room = joinRequest.room,
		})
	end

	for invitation in ivalues(decoded.pending_invitations or {}) do
		MESSAGEMAN:Broadcast("OnlineRoomInvitation", {
			invitation = {
				id = invitation.id,
				room_id = invitation.room_id,
				status = "pending",
			},
			inviter = invitation.inviter,
			room = invitation.room,
		})
	end
end

function ITGOnline:SyncPages(accumulator, generation, pageCount)
	pageCount = pageCount or 0
	self.lastSyncRequestedAt = GetTimeSinceStart()
	if generation ~= self.syncGeneration or not accumulator then return end
	local cursor = tonumber(accumulator and accumulator.next_cursor or self.lastEventCursor or 0) or 0
	local page = pageCount + 1
	local query = "/sync?limit=250&cursor=" .. tostring(math.floor(cursor))
		.. "&online_limit=250&rooms_limit=250&join_requests_limit=250&invitations_limit=250"
		.. "&online_page=" .. tostring(page)
		.. "&rooms_page=" .. tostring(page)
		.. "&join_requests_page=" .. tostring(page)
		.. "&invitations_page=" .. tostring(page)
	if accumulator.snapshot_token then
		query = query .. "&snapshot_token=" .. tostring(accumulator.snapshot_token)
	end
	self:Request("GET", query, nil, function(ok, decoded, response)
		if generation ~= self.syncGeneration then return end

		if ok and decoded then
					if decoded.next_cursor then
						local nextCursor = math.max(accumulator and accumulator.next_cursor or self.lastEventCursor or 0, tonumber(decoded.next_cursor) or 0)
						if accumulator then
							accumulator.next_cursor = nextCursor
						else
							self.lastEventCursor = nextCursor
						end
					end

						if accumulator then
						for _, key in ipairs({ "online_users", "public_rooms", "pending_join_requests", "pending_invitations", "events" }) do
							for item in ivalues(decoded[key] or {}) do
								accumulator[key][#accumulator[key] + 1] = item
							end
							decoded[key] = accumulator[key]
						end
					end

					local meta = decoded.meta or {}
					if meta.sync and meta.sync.snapshot_token then
						accumulator.snapshot_token = tostring(meta.sync.snapshot_token)
					end
					local hasMore = (meta.events and meta.events.has_more)
					or (meta.online_users and meta.online_users.has_more)
					or (meta.public_rooms and meta.public_rooms.has_more)
					or (meta.pending_join_requests and meta.pending_join_requests.has_more)
					or (meta.pending_invitations and meta.pending_invitations.has_more)
					local baseBudget = math.max(1, tonumber(self.syncMaxPages or 100) or 100)
					local budgetMultiplier = math.max(1, tonumber(accumulator.syncPageBudgetMultiplier or 1) or 1)
					local pageBudget = baseBudget * budgetMultiplier
					if hasMore and page < pageBudget and not self.disconnecting then
						self:SyncPages(accumulator, generation, pageCount + 1)
						return
					elseif hasMore then
						local attempt = (tonumber(accumulator.syncOverflowAttempts or 0) or 0) + 1
						local maxRetries = math.max(1, tonumber(self.syncOverflowMaxRetries or 3) or 3)
						if attempt <= maxRetries then
							accumulator.syncOverflowAttempts = attempt
							accumulator.snapshot_token = nil
							accumulator.next_cursor = 0
							accumulator.online_users = {}
							accumulator.public_rooms = {}
							accumulator.pending_join_requests = {}
							accumulator.pending_invitations = {}
							accumulator.events = {}
							local maxMultiplier = math.max(1, tonumber(self.syncOverflowMaxBudgetMultiplier or 4) or 4)
							accumulator.syncPageBudgetMultiplier = math.min(
								maxMultiplier,
								math.max(1, tonumber(accumulator.syncPageBudgetMultiplier or 1) or 1) * 2
							)
							online_trace(
								"Sync overflow retry "
									.. tostring(attempt)
									.. "/"
									.. tostring(maxRetries)
									.. " with page budget x"
									.. tostring(accumulator.syncPageBudgetMultiplier)
							)
							self:SyncPages(accumulator, generation, 0)
							return
						end

					online_trace("Sync page limit reached before all state was drained.")
					local response = { errorMessage = "Sync did not complete before the page budget was exhausted." }
					MESSAGEMAN:Broadcast("OnlineResponseStatus", {
						event = "sync",
						success = false,
						message = response.errorMessage,
					})
					self:FinishSync(generation, false, decoded, response)
					return
				end

						self:ApplySyncPayload(decoded)
						self.lastEventCursor = math.max(self.lastEventCursor or 0, tonumber(accumulator and accumulator.next_cursor or decoded.next_cursor or 0) or 0)
					end

		self:FinishSync(generation, ok, decoded, response)
		end)
	end

function ITGOnline:BuildSongPayload()
	local song = GAMESTATE:GetCurrentSong()
	if not song then return nil end

	local steps = selected_steps()
	local path = song_path(song)
	local chartType = normalize_chart_type(steps and enum_short(steps:GetStepsType()) or "")
	local difficulty = steps and enum_short(steps:GetDifficulty()) or "unknown"
	local meter = steps and steps:GetMeter() or nil
	local songFilePath = song.GetSongFilePath and song:GetSongFilePath() or ""
	local musicPath = song.GetMusicPath and song:GetMusicPath() or ""
	local songFileHash = sha256_file_hex(songFilePath)
	local musicHash = sha256_file_hex(musicPath)
	if not songFileHash or not musicHash then return nil end
	local musicName = manifest_file_name(musicPath)
	local songFileName = manifest_file_name(songFilePath)
	if not musicName or not songFileName then return nil end
	local chartHash = self:ChartHashForSteps(steps)
	local rate = current_music_rate()
	local noteCount = current_chart_note_count(steps)
	if not noteCount then return nil end

	return {
		title = song:GetDisplayFullTitle(),
		artist = song:GetDisplayArtist(),
		pack = path:match("^([^/]+)") or "",
		folder_name = path,
		song_hash = musicHash,
		audio_file_hash = musicHash,
		chart_hash = chartHash,
		chart_file_hash = songFileHash,
		chart_type = chartType,
		difficulty = difficulty,
		meter = meter,
		rate = rate,
		music_length_seconds = math.max(1, math.floor(song:MusicLengthSeconds() or 1)),
		chart_duration_seconds = math.max(1, math.floor(song_steps_seconds(song))),
		chart_note_count = noteCount,
		max_score = server_max_score_for_note_count(noteCount),
		required_files = {
			{ path = "music/" .. musicName, sha256 = musicHash },
			{ path = "chart/" .. songFileName, sha256 = songFileHash },
		},
	}
end

function ITGOnline:ChartHashForSteps(steps)
	local stepsHash = steps and tostring(steps:GetHash()) or "no-steps"
	local grooveStatsHash = steps and steps.GetGrooveStatsHash and tostring(steps:GetGrooveStatsHash()) or ""

	return normalized_hash(grooveStatsHash ~= "" and grooveStatsHash or stepsHash)
end

function ITGOnline:SelectSong(callback)
	if not self.currentRoomId then return end
	if not has_server_scoring_policy() then
		self:Sync(function(ok)
			if ok and has_server_scoring_policy() then
				self:SelectSong(callback)
				return
			end

			if callback then callback(false, nil, { errorMessage = "Server scoring policy is unavailable." }) end
			MESSAGEMAN:Broadcast("OnlineResponseStatus", {
				event = "selectSong",
				success = false,
				message = "Server scoring policy is unavailable."
			})
		end)
		return
	end

	local payload = self:BuildSongPayload()
	if not payload then
		if callback then callback(false, nil, { errorMessage = "No selected song or chart." }) end
		MESSAGEMAN:Broadcast("OnlineResponseStatus", {
			event = "selectSong",
			success = false,
			message = "No selected song or chart."
		})
		return
	end

	self.currentSongPayload = payload
	self:Request("POST", "/rooms/" .. tostring(self.currentRoomId) .. "/song-selection", payload, function(ok, decoded, response)
		if ok and decoded and decoded.room then
			self.currentRoom = decoded.room
				self.songLoadedAckKey = ""
				self.songLoadedInFlightKey = ""
				self.songLoadedPendingCallbacks = {}
				self.startScheduleAckKey = ""
				self.startScheduleAckInFlightKey = ""
				self.onlineGameplayEnteredKey = ""
				self.onlineGameplayReturnedKey = ""
			MESSAGEMAN:Broadcast("OnlineLobbyState", self:LobbyStatePayload(decoded.room))
		elseif ok then
			self:FetchRoom(self.currentRoomId)
		end
		if callback then callback(ok, decoded, response) end
	end)
end

function ITGOnline:SelectSongAndMarkLobbyReady(callback)
	if not self.currentRoomId then
		if callback then callback(false, nil, { errorMessage = "No active online room." }) end
		return
	end

	self:SelectSong(function(selectOk, selectDecoded, selectResponse)
		if not selectOk then
			if callback then callback(false, selectDecoded, selectResponse) end
			MESSAGEMAN:Broadcast("OnlineResponseStatus", {
				event = "selectSong",
				success = false,
				message = response_message(selectResponse, selectDecoded, "Song selection failed")
			})
			return
		end

		self:SetReady("lobby_ready", true, function(readyOk, readyDecoded, readyResponse)
			if readyOk and readyDecoded and readyDecoded.room then
				MESSAGEMAN:Broadcast("OnlineLobbyState", self:LobbyStatePayload(readyDecoded.room))
			end
			if callback then callback(readyOk, readyDecoded or selectDecoded, readyResponse or selectResponse) end
		end)
	end)
end

function ITGOnline:PreviewSong(callback)
	if not self.currentRoomId then return end
	local payload = self:BuildSongPayload()
	if not payload then return end

	self:Request("POST", "/rooms/" .. tostring(self.currentRoomId) .. "/song-preview", {
		title = payload.title,
		artist = payload.artist,
		pack = payload.pack,
		folder_name = payload.folder_name,
		difficulty = payload.difficulty,
		meter = payload.meter,
	}, callback, nil, { cancelOnScreenChange = true })
end

function ITGOnline:ServerJudgments(player)
	local counts = GetExJudgmentCounts(player)
	return {
		fantastic = (counts.W0 or 0) + (counts.W1 or 0),
		excellent = counts.W2 or 0,
		great = counts.W3 or 0,
		decent = counts.W4 or 0,
		way_off = counts.W5 or 0,
		miss = counts.Miss or 0,
		mine = counts.Mines or 0,
		hold_ok = (counts.Holds or 0) + (counts.Rolls or 0),
		hold_ng = math.max(0, ((counts.totalHolds or 0) + (counts.totalRolls or 0)) - ((counts.Holds or 0) + (counts.Rolls or 0))),
	}
end

function ITGOnline:ServerAccuracyFromJudgments(judgments)
	if not judgments then return nil end

	local fantastic = tonumber(judgments.fantastic) or 0
	local excellent = tonumber(judgments.excellent) or 0
	local great = tonumber(judgments.great) or 0
	local decent = tonumber(judgments.decent) or 0
	local wayOff = tonumber(judgments.way_off) or 0
	local miss = tonumber(judgments.miss) or 0

	local total = fantastic + excellent + great + decent + wayOff + miss
	if total <= 0 then return nil end

	local weightedHits = (fantastic * 1.0)
		+ (excellent * 0.95)
		+ (great * 0.8)
		+ (decent * 0.5)
		+ (wayOff * 0.2)
		+ (miss * 0.0)

	return math.max(0, math.min(100, (weightedHits / total) * 100))
end

function ITGOnline:ScoreFingerprint(score, combo, maxCombo, failed, judgments)
	local j = judgments or {}
	return table.concat({
		tostring(self.currentRoomId or ""),
		tostring(self.currentSongPayload and self.currentSongPayload.chart_hash or ""),
		tostring(math.floor(tonumber(score) or 0)),
		tostring(math.floor(tonumber(combo) or 0)),
		tostring(math.floor(tonumber(maxCombo) or 0)),
		(failed and "1" or "0"),
		tostring(math.floor(tonumber(j.fantastic) or 0)),
		tostring(math.floor(tonumber(j.excellent) or 0)),
		tostring(math.floor(tonumber(j.great) or 0)),
		tostring(math.floor(tonumber(j.decent) or 0)),
		tostring(math.floor(tonumber(j.way_off) or 0)),
		tostring(math.floor(tonumber(j.miss) or 0)),
		tostring(math.floor(tonumber(j.mine) or 0)),
		tostring(math.floor(tonumber(j.hold_ok) or 0)),
		tostring(math.floor(tonumber(j.hold_ng) or 0)),
	}, "|")
end

function ITGOnline:SendScore(force, final, snapshot)
	if not self.currentRoomId then return end
	if not self.currentRoom then return end
	if not self.currentSongPayload and self.currentRoom.selected_song then
		self.currentSongPayload = self.currentRoom.selected_song
	end
	if not self.currentSongPayload then return end
	if final and self.currentRoom.phase ~= "results" and self.currentRoom.phase ~= "playing" then return end
	if not force and GetTimeSinceStart() - self.lastScoreSentAt < 1 then return end
	if final and self.lastFinalScoreRoomId == self.currentRoomId then return end
	self.lastScoreSentAt = GetTimeSinceStart()

	if snapshot ~= nil then
		self.lastDisplayedScoreSnapshot = snapshot
	end
	if snapshot == nil then
		snapshot = self.lastDisplayedScoreSnapshot
	end
	if snapshot == nil and not final then
		return
	end

	local player = first_enabled_player()
	local stats = STATSMAN:GetCurStageStats():GetPlayerStageStats(player)
	local dancePoints = stats:GetPercentDancePoints()
	local exScore = CalculateExScore(player) or 0
	local songPositionState = GAMESTATE:GetPlayerState(player):GetSongPosition()
	local songPosition = songPositionState:GetMusicSeconds()
	local visibleOk, visibleSeconds = pcall(function() return songPositionState:GetMusicSecondsVisible() end)
	if visibleOk and tonumber(visibleSeconds) then songPosition = visibleSeconds end
	local positionKey = tostring(self.currentRoomId or "") .. "|" .. tostring(self.currentSongPayload.chart_hash or "")
	if self.lastScorePositionKey ~= positionKey then
		self.lastScorePositionKey = positionKey
		self.lastScoreSongPosition = 0
	end
	songPosition = math.max(0, tonumber(songPosition) or 0)
	local startAtMs = tonumber(self.currentRoom.start_at_ms or "") or iso_utc_milliseconds(self.currentRoom.start_at)
	if startAtMs and self.serverClockOffsetSeconds then
		local rateForClock = tonumber(self.currentSongPayload.rate) or 1
		rateForClock = math.max(0.25, math.min(3, rateForClock))
		local estimatedServerNowSeconds = GetTimeSinceStart() + self.serverClockOffsetSeconds
		local estimatedPosition = math.max(0, (estimatedServerNowSeconds - (startAtMs / 1000)) * rateForClock)
		-- Keep client position coherent with server clock to avoid "behind_server_clock" rejects.
		songPosition = math.max(songPosition, math.max(0, estimatedPosition - 0.5))
	end
	local chartDuration = tonumber(self.currentSongPayload.chart_duration_seconds) or tonumber(self.currentSongPayload.music_length_seconds)
	if final and self.currentRoom.phase == "results" and chartDuration then
		songPosition = math.max(songPosition, chartDuration)
	else
		songPosition = math.max(songPosition, tonumber(self.lastScoreSongPosition) or 0)
	end
	self.lastScoreSongPosition = songPosition
	local maxCombo = stats:GetCurrentCombo() or 0
	for _, methodName in ipairs({ "GetMaxCombo", "MaxCombo" }) do
		local ok, value = pcall(function() return stats[methodName] and stats[methodName](stats) or nil end)
		if ok and tonumber(value) then
			maxCombo = tonumber(value)
			break
		end
	end
	local failedOk, failedValue = pcall(function() return stats:GetFailed() end)
	local failed = failedOk and failedValue == true or false

	local selectedMaxScore = tonumber(self.currentSongPayload.max_score) or server_max_score_for_note_count(self.currentSongPayload.chart_note_count)
	local exScorePercent = tonumber(snapshot and snapshot.exScorePercent) or tonumber(exScore) or 0
	local normalizedExScore = math.max(0, math.min(100, exScorePercent)) / 100
	local pn = ToEnumShortString(player)
	local showExScore = SL and pn and SL[pn] and SL[pn].ActiveModifiers and SL[pn].ActiveModifiers.ShowExScore == true
	local displayedScorePercent = tonumber(snapshot and snapshot.displayedPercent)
	if displayedScorePercent == nil then
		displayedScorePercent = showExScore
		and tonumber(snapshot and snapshot.exScorePercent)
		or tonumber(snapshot and snapshot.scorePercent)
	end
	if displayedScorePercent == nil then
		displayedScorePercent = showExScore and exScorePercent or ((tonumber(dancePoints) or 0) * 100)
	end
	displayedScorePercent = math.max(0, math.min(100, tonumber(displayedScorePercent) or 0))
	local judgments = self:ServerJudgments(player)
	local accuracyFromJudgments = self:ServerAccuracyFromJudgments(judgments)
	local accuracy = tonumber(snapshot and snapshot.scorePercent)
	if accuracyFromJudgments ~= nil then
		accuracy = accuracyFromJudgments
	elseif accuracy == nil then
		accuracy = math.max(0, math.min(100, (tonumber(dancePoints) or 0) * 100))
	else
		accuracy = math.max(0, math.min(100, accuracy))
	end
	if accuracy <= 0 and normalizedExScore > 0 then
		-- Some gameplay flows keep PercentDancePoints at 0 during live play.
		-- Use EX-derived percentage as live accuracy fallback.
		accuracy = normalizedExScore * 100
	end
	local liveCombo = tonumber(snapshot and snapshot.combo)
	if liveCombo == nil then
		liveCombo = stats:GetCurrentCombo() or 0
	end

	-- Always transport the score currently shown to the player in gameplay.
	local outgoingScore = math.max(0, math.floor((displayedScorePercent / 100) * selectedMaxScore + 0.5))
	local outgoingPercent = selectedMaxScore > 0 and ((outgoingScore / selectedMaxScore) * 100) or 0
	online_trace(string.format(
		"score-trace room=%s displayed=%.3f outgoing=%.3f snapshot(score=%.3f ex=%.3f shown=%.3f) max=%d combo=%d",
		tostring(self.currentRoomId or ""),
		tonumber(displayedScorePercent) or 0,
		tonumber(outgoingPercent) or 0,
		tonumber(snapshot and snapshot.scorePercent) or -1,
		tonumber(snapshot and snapshot.exScorePercent) or -1,
		tonumber(snapshot and snapshot.displayedPercent) or -1,
		tonumber(selectedMaxScore) or 0,
		tonumber(liveCombo) or 0
	))
	if math.abs((tonumber(displayedScorePercent) or 0) - outgoingPercent) > 0.2 then
		online_trace(string.format(
			"score-drift local(displayed=%.3f, outgoing=%.3f, max=%d, rawScore=%d)",
			tonumber(displayedScorePercent) or 0,
			tonumber(outgoingPercent) or 0,
			tonumber(selectedMaxScore) or 0,
			tonumber(outgoingScore) or 0
		))
	end
	local outgoingCombo = math.max(0, liveCombo or 0)
	local outgoingMaxCombo = math.max(0, maxCombo or 0)
	local outgoingFailed = failed and true or false
	local scoreFingerprint = self:ScoreFingerprint(outgoingScore, outgoingCombo, outgoingMaxCombo, outgoingFailed, judgments)

	if not final then
		if self.scoreInFlightFingerprint and self.scoreInFlightFingerprint == scoreFingerprint then
			return
		end
		if self.lastAcceptedScoreFingerprint and self.lastAcceptedScoreFingerprint == scoreFingerprint then
			return
		end
	end

	self.scoreInFlightFingerprint = scoreFingerprint

	self:Request("POST", "/rooms/" .. tostring(self.currentRoomId) .. "/score", {
		score = outgoingScore,
		combo = outgoingCombo,
		max_combo = outgoingMaxCombo,
		accuracy = accuracy,
		song_position_seconds = songPosition,
		song_hash = self.currentSongPayload.song_hash,
		chart_hash = self.currentSongPayload.chart_hash,
		failed = outgoingFailed,
		final = final and true or false,
		judgments = judgments,
			}, function(ok, decoded, response)
				if self.scoreInFlightFingerprint == scoreFingerprint then
					self.scoreInFlightFingerprint = nil
				end
				if ok and final then
					self.lastFinalScoreRoomId = self.currentRoomId
					if outgoingFailed and self.MarkPlayFailed then
						self:MarkPlayFailed()
					elseif self.MarkPlayFinished then
						self:MarkPlayFinished()
					end
				end
				if ok then
					self.lastAcceptedScoreFingerprint = scoreFingerprint
				end
				if not ok and (force or final) then
					MESSAGEMAN:Broadcast("OnlineResponseStatus", {
					event = final and "finalScore" or "score",
				success = false,
				message = response_message(response, decoded, final and "Final score upload failed" or "Score upload failed")
			})
		end
	end)
end

function ITGOnline:SetReady(phase, isReady, callback)
	if not self.currentRoomId then
		if callback then callback(false, nil, { errorMessage = "No active online room." }) end
		return
	end
	local payload = {
		phase = phase,
		is_ready = isReady and true or false,
	}

	if phase == "config_ready" then
		payload.options = self:CurrentOnlineOptionSummary()
	end

	local options = payload.options or {}
	local requestKey = table.concat({
		tostring(self.currentRoomId),
		tostring(phase or ""),
		isReady and "1" or "0",
		tostring(options.speed_mod or ""),
		tostring(options.music_rate_bpm or ""),
		tostring(options.stepchart or ""),
	}, "|")
	local nowTs = GetTimeSinceStart()
	local lastResult = self.readyRequestLastResult[requestKey]
	if lastResult
		and lastResult.ok == true
		and (nowTs - (tonumber(lastResult.at) or 0)) <= (tonumber(self.readyRequestReplayWindowSeconds) or 1.0)
		and self.currentRoom
		and self:IsCurrentUserReadyInRoom(self.currentRoom) then
		if callback then callback(true, { room = self.currentRoom }, nil) end
		return
	end

	local inflight = self.readyRequestInFlight[requestKey]
	if inflight then
		if callback then
			inflight.callbacks[#inflight.callbacks + 1] = callback
		end
		return
	end

	self.readyRequestInFlight[requestKey] = {
		callbacks = callback and { callback } or {},
	}

	self:Request("POST", "/rooms/" .. tostring(self.currentRoomId) .. "/ready", payload, function(ok, decoded, response)
		self.readyRequestLastResult[requestKey] = {
			ok = ok and true or false,
			at = GetTimeSinceStart(),
		}
		local pending = self.readyRequestInFlight[requestKey]
		self.readyRequestInFlight[requestKey] = nil
		if ok and decoded and decoded.room then
			self.currentRoom = decoded.room
		end
		local callbacks = pending and pending.callbacks or {}
		for cb in ivalues(callbacks) do
			cb(ok, decoded, response)
		end
	end)
end

function ITGOnline:CurrentOnlineOptionSummary()
	return {
		speed_mod = current_speed_mod_label(),
		music_rate_bpm = string.format("%.2fx", current_music_rate()),
		stepchart = current_stepchart_label(),
	}
end

function ITGOnline:MarkConfigReady(callback)
	if not self.currentRoomId then
		if callback then callback(false, nil, { errorMessage = "No active online room." }) end
		return
	end
	if self.configReadyInFlight then
		if callback then callback(false, nil, { errorMessage = "Ready synchronization is already in progress." }) end
		return
	end
	self.configReadyInFlight = true

	local finish = function(ok, decoded, response)
		self.configReadyInFlight = false
		if callback then callback(ok, decoded, response) end
	end

	local finishConfigReady = function()
		self:SetReady("config_ready", true, function(ok, decoded, response)
			if ok and decoded and decoded.room then
				MESSAGEMAN:Broadcast("OnlineLobbyState", self:LobbyStatePayload(decoded.room))
			end
			finish(ok, decoded, response)
		end)
	end

	self:FetchRoom(self.currentRoomId, function(fetchOk, fetchDecoded, fetchResponse)
		if not fetchOk or not fetchDecoded or not fetchDecoded.room then
			finish(false, fetchDecoded, fetchResponse)
			return
		end

		local room = fetchDecoded.room
		if not room.selected_song then
			self:SelectSongAndMarkLobbyReady(finish)
			return
		end

		if room.phase == "starting" or room.phase == "playing" or room.phase == "results" then
			finish(true, fetchDecoded, fetchResponse)
		elseif room.phase == "config" then
			finishConfigReady()
		elseif room.phase == "lobby" or room.phase == "lobby_ready" then
			self:SetReady("lobby_ready", true, function(readyOk, readyDecoded, readyResponse)
				if readyOk and readyDecoded and readyDecoded.room then
					MESSAGEMAN:Broadcast("OnlineLobbyState", self:LobbyStatePayload(readyDecoded.room))
				end
				finish(false, readyDecoded or fetchDecoded, {
					errorMessage = "Waiting for room config phase.",
					retryAfter = 1,
				})
			end)
		else
			finish(false, fetchDecoded, { errorMessage = "Room is not accepting ready state." })
		end
	end)
end

function ITGOnline:StartRoom(callback)
	if not self.currentRoomId then
		if callback then callback(false, nil, { errorMessage = "No active online room." }) end
		return
	end
		self:Request("POST", "/rooms/" .. tostring(self.currentRoomId) .. "/start", {}, function(ok, decoded, response)
			if ok and decoded and decoded.room then
				self.currentRoom = decoded.room
				self.startScheduleAckKey = ""
				self.startScheduleAckInFlightKey = ""
			end
			if callback then callback(ok, decoded, response) end
		end)
end

function ITGOnline:UpdatePlayStateFromResponse(decoded)
	if decoded and decoded.play_state and self.currentRoom then
		local previousPhase = self.currentRoom.phase
		self.currentRoom.play_state = decoded.play_state
		if decoded.room_phase then
			self.currentRoom.phase = decoded.room_phase
		end
		online_flow_trace("play_state_response previousPhase=" .. tostring(previousPhase)
			.. " responsePhase=" .. tostring(decoded.room_phase)
			.. " currentPhase=" .. tostring(self.currentRoom.phase))
		MESSAGEMAN:Broadcast("OnlineLobbyState", self:LobbyStatePayload(self.currentRoom))
		MESSAGEMAN:Broadcast("ITGOnlinePlayStateUpdated", decoded.play_state)
	end
end

function ITGOnline:PlayStateKey()
	return tostring(self.currentRoomId or "") .. "|" .. tostring(self.currentSongPayload and self.currentSongPayload.chart_hash or "")
end

function ITGOnline:MarkPlayEntered(callback)
	if not self.currentRoomId then
		if callback then callback(false, nil, { errorMessage = "No active online room." }) end
		return
	end
	local key = self:PlayStateKey()
	if key ~= "|" and self.onlineGameplayEnteredKey == key then
		if callback then callback(true, { play_state = self.currentRoom and self.currentRoom.play_state or nil }, nil) end
		return
	end

	self:Request("POST", "/rooms/" .. tostring(self.currentRoomId) .. "/play/entered", {}, function(ok, decoded, response)
		if ok then
			self.onlineGameplayEnteredKey = key
			self.onlineGameplayReturnedKey = ""
			self:UpdatePlayStateFromResponse(decoded)
		end
		if callback then callback(ok, decoded, response) end
	end)
end

function ITGOnline:MarkReturnedToLobby(callback)
	if not self.currentRoomId then
		if callback then callback(false, nil, { errorMessage = "No active online room." }) end
		return
	end
	local key = self:PlayStateKey()
	if key ~= "|" and self.onlineGameplayReturnedKey == key then
		if callback then callback(true, { play_state = self.currentRoom and self.currentRoom.play_state or nil }, nil) end
		return
	end

	self:Request("POST", "/rooms/" .. tostring(self.currentRoomId) .. "/play/returned-to-lobby", {}, function(ok, decoded, response)
		if ok then
			self.onlineGameplayReturnedKey = key
			self:UpdatePlayStateFromResponse(decoded)
		end
		if callback then callback(ok, decoded, response) end
	end)
end

function ITGOnline:MarkPlayFinished(callback)
	if not self.currentRoomId then
		if callback then callback(false, nil, { errorMessage = "No active online room." }) end
		return
	end

	self:Request("POST", "/rooms/" .. tostring(self.currentRoomId) .. "/play/finished", {}, function(ok, decoded, response)
		if ok then self:UpdatePlayStateFromResponse(decoded) end
		if callback then callback(ok, decoded, response) end
	end)
end

function ITGOnline:MarkPlayFailed(callback)
	if not self.currentRoomId then
		if callback then callback(false, nil, { errorMessage = "No active online room." }) end
		return
	end

	self:Request("POST", "/rooms/" .. tostring(self.currentRoomId) .. "/play/failed", {}, function(ok, decoded, response)
		if ok then self:UpdatePlayStateFromResponse(decoded) end
		if callback then callback(ok, decoded, response) end
	end)
end

function ITGOnline:FetchPlayState(callback)
	if not self.currentRoomId then
		if callback then callback(false, nil, { errorMessage = "No active online room." }) end
		return
	end

	self:Request("GET", "/rooms/" .. tostring(self.currentRoomId) .. "/play-state", nil, function(ok, decoded, response)
		if ok then self:UpdatePlayStateFromResponse(decoded) end
		if callback then callback(ok, decoded, response) end
	end)
end

function ITGOnline:MarkSongLoaded(callback, clockRetry)
	if not self.currentRoomId then
		if callback then callback(false, nil, { errorMessage = "No active online room." }) end
		return
	end

	if not clockRetry and not self:ClockSyncIsFresh() then
		self:Sync(function(ok)
			if ok and self:ClockSyncIsFresh() then
				self:MarkSongLoaded(callback, true)
				return
			end

			if callback then callback(false, nil, { errorMessage = "Could not synchronize clock before song loading." }) end
		end)
		return
	end

	local songKey = tostring(self.currentRoomId or "") .. "|" .. tostring(self.currentSongPayload and self.currentSongPayload.chart_hash or "")
	if self.songLoadedAckKey == songKey then
		if callback then callback(true, { room = self.currentRoom }, nil) end
		return
	end
	if self.songLoadedInFlightKey == songKey then
		if callback then
			self.songLoadedPendingCallbacks[songKey] = self.songLoadedPendingCallbacks[songKey] or {}
			self.songLoadedPendingCallbacks[songKey][#self.songLoadedPendingCallbacks[songKey] + 1] = callback
		end
		return
	end

	self.songLoadedInFlightKey = songKey
	self.songLoadedPendingCallbacks[songKey] = callback and { callback } or {}
	self:Request("POST", "/rooms/" .. tostring(self.currentRoomId) .. "/loaded", {}, function(ok, decoded, response)
		if self.songLoadedInFlightKey == songKey then
			self.songLoadedInFlightKey = ""
		end
			if ok and decoded and decoded.room then
				self.currentRoom = decoded.room
				self:UpdateScheduledStart(decoded.room)
				self:MaybeAckScheduledStart(decoded.room)
				self.songLoadedAckKey = songKey
				MESSAGEMAN:Broadcast("OnlineLobbyState", self:LobbyStatePayload(decoded.room))
			end
		local callbacks = self.songLoadedPendingCallbacks[songKey] or {}
		self.songLoadedPendingCallbacks[songKey] = nil
		for pendingCallback in ivalues(callbacks) do
			pendingCallback(ok, decoded, response)
		end
		end)
	end

	function ITGOnline:MaybeAckScheduledStart(room)
		room = room or self.currentRoom
		if not room or room.phase ~= "starting" or not room.start_at then return end
		if not self.currentRoomId then return end

		local screen = SCREENMAN:GetTopScreen()
		local screenName = screen and screen:GetName() or "NoScreen"
		if screenName ~= "ScreenGameplay" and screenName ~= "ScreenGameplayShared" then return end

		local key = tostring(room.id or self.currentRoomId or "") .. "|"
			.. tostring(room.selected_song and room.selected_song.chart_hash or self.currentSongPayload and self.currentSongPayload.chart_hash or "") .. "|"
			.. tostring(room.start_at or room.start_at_ms or "")
		if key == "||" or self.startScheduleAckKey == key or self.startScheduleAckInFlightKey == key then return end

		self.startScheduleAckInFlightKey = key
		self:Request("POST", "/rooms/" .. tostring(self.currentRoomId) .. "/start-ack", {}, function(ok, decoded, response)
			if self.startScheduleAckInFlightKey == key then
				self.startScheduleAckInFlightKey = ""
			end
			if ok and decoded and decoded.room then
				self.currentRoom = decoded.room
				self:UpdateScheduledStart(decoded.room)
				self.startScheduleAckKey = key
				MESSAGEMAN:Broadcast("OnlineLobbyState", self:LobbyStatePayload(decoded.room))
			elseif not ok then
				MESSAGEMAN:Broadcast("OnlineResponseStatus", {
					event = "startAck",
					success = false,
					message = response_message(response, decoded, "Could not acknowledge synchronized start.")
				})
			end
		end)
	end

	function ITGOnline:ShouldHoldGameplayForOnlineStart()
	return self.currentRoom
		and self.currentRoom.phase == "starting"
		and self:SecondsUntilScheduledStart() == nil
end

function ITGOnline:UpdateScheduledStart(room)
	room = room or self.currentRoom
	if not room then return end

	local startAtMs = tonumber(room.start_at_ms or "") or iso_utc_milliseconds(room.start_at)
	local serverTimeMs = tonumber(room.server_time_ms or "") or iso_utc_milliseconds(room.server_time)

	if serverTimeMs and self.UpdateServerClockOffset then
		self:UpdateServerClockOffset(serverTimeMs, GetTimeSinceStart(), GetTimeSinceStart())
	end

	if startAtMs and self.serverClockOffsetSeconds then
		self.scheduledStartLocalTime = (startAtMs / 1000) - self.serverClockOffsetSeconds
	elseif startAtMs and serverTimeMs then
		self.scheduledStartLocalTime = GetTimeSinceStart() + ((startAtMs - serverTimeMs) / 1000)
	elseif room.phase ~= "starting" and room.phase ~= "playing" then
		self.scheduledStartLocalTime = nil
	end
end

function ITGOnline:SecondsUntilScheduledStart()
	if not self.scheduledStartLocalTime then return nil end
	return self.scheduledStartLocalTime - GetTimeSinceStart()
end

function ITGOnline:Heartbeat(status)
	local payload = { status = status or "available" }
	if self.currentRoomId then payload.room_id = self.currentRoomId end
	self:Request("POST", "/presence/heartbeat", payload)
end

function ITGOnline:FetchLobby(callback)
	self:Request("GET", "/lobby", nil, function(ok, decoded, response)
		if callback then callback(ok, decoded, response) end
	end)
end

function ITGOnline:QueueLobbyRefresh()
	if self.lobbyRefreshInFlight then
		self.lobbyRefreshQueued = true
		return
	end

	self.lobbyRefreshInFlight = true
	self:FetchLobby(function(ok, decoded)
		self.lobbyRefreshInFlight = false
		if ok then MESSAGEMAN:Broadcast("LobbySearched", self:LobbySearchPayload(decoded)) end
		if self.lobbyRefreshQueued and not self.disconnecting then
			self.lobbyRefreshQueued = false
			self:QueueLobbyRefresh()
		end
	end)
end

function ITGOnline:FetchCurrentRoom(callback)
	self:Request("GET", "/rooms/current", nil, function(ok, decoded, response)
		if ok and decoded and decoded.room then
			self.currentRoomId = decoded.room.id
			self.currentRoom = decoded.room
			if decoded.room.selected_song and decoded.room.selected_song.song_hash and decoded.room.selected_song.chart_hash then
				self.currentSongPayload = decoded.room.selected_song
			end
		end
		if callback then callback(ok, decoded, response) end
	end)
end

function ITGOnline:CreateRoom(callback, visibility)
	local roomName = local_profile_name() .. "'s room"
	self:Request("POST", "/rooms", { name = roomName, visibility = visibility or "public" }, function(ok, decoded, response)
		if ok and decoded and decoded.room then
			self.currentRoomId = decoded.room.id
			self.currentRoom = decoded.room
		end
		if callback then callback(ok, decoded, response) end
	end)
end

function ITGOnline:RequestJoinRoom(roomId, callback)
	self.pendingJoinRoomId = roomId
	self:Request("POST", "/rooms/" .. tostring(roomId) .. "/join-requests", {}, function(ok, decoded, response)
		if not ok then
			self.pendingJoinRoomId = nil
		end
		if callback then callback(ok, decoded, response) end
	end)
end

function ITGOnline:ReportSongAvailability(missing, reason, callback)
	if not self.currentRoomId then
		if callback then callback(false, nil, { errorMessage = "No active online room." }) end
		return
	end

	local payload = {
		missing = missing and true or false,
		reason = reason or (missing and "unknown" or "reloaded"),
	}

	if not missing then
		local selectedSong = self.currentRoom and self.currentRoom.selected_song or nil
		local localPayload = self:BuildSongPayload()
		payload.song_hash = self.currentSongPayload and self.currentSongPayload.song_hash or selectedSong and selectedSong.song_hash or nil
		payload.chart_hash = self.currentSongPayload and self.currentSongPayload.chart_hash or selectedSong and selectedSong.chart_hash or nil
		payload.chart_note_count = localPayload and localPayload.chart_note_count or selectedSong and selectedSong.chart_note_count or nil
		payload.max_score = localPayload and localPayload.max_score or selectedSong and selectedSong.max_score or nil
	end

	self:Request("POST", "/rooms/" .. tostring(self.currentRoomId) .. "/song-availability", payload, function(ok, decoded, response)
		if ok and decoded and decoded.room then
			self.currentRoom = decoded.room
				if missing then
					self.songLoadedAckKey = ""
					self.songLoadedInFlightKey = ""
					self.songLoadedPendingCallbacks = {}
				end
			MESSAGEMAN:Broadcast("OnlineLobbyState", self:LobbyStatePayload(decoded.room))
		end
		if callback then callback(ok, decoded, response) end
	end)
end

function ITGOnline:RequestJoinUserRoom(userId, callback)
	self:Request("POST", "/users/" .. tostring(userId) .. "/room-join-request", {}, function(ok, decoded, response)
		if ok and decoded and decoded.room then
			self.currentRoomId = decoded.room.id
			self.currentRoom = decoded.room
			elseif ok and decoded and decoded.join_request then
				self.pendingJoinRoomId = decoded.join_request.room_id
			elseif not ok then
				self.pendingJoinRoomId = nil
			end
		if callback then callback(ok, decoded, response) end
	end)
end

function ITGOnline:InviteUser(roomId, userId, callback)
	self:Request("POST", "/rooms/" .. tostring(roomId) .. "/invitations", {
		user_id = tonumber(userId) or userId,
	}, callback)
end

function ITGOnline:InviteUserToNewRoom(userId, visibility, callback)
	self:CreateRoom(function(ok, decoded, response)
		if not ok or not decoded or not decoded.room then
			if callback then callback(false, decoded, response) end
			return
		end

		self:InviteUser(decoded.room.id, userId, function(inviteOk, inviteDecoded, inviteResponse)
			if not inviteOk then
				self:LeaveRoom(function()
					if callback then callback(false, inviteDecoded or decoded, inviteResponse or response) end
				end)
				return
			end

			if callback then callback(inviteOk, inviteDecoded or decoded, inviteResponse or response) end
		end)
	end, visibility or "private")
end

function ITGOnline:AcceptInvitation(invitationId, callback)
	self:Request("POST", "/room-invitations/" .. tostring(invitationId) .. "/accept", {}, function(ok, decoded, response)
		if ok and decoded and decoded.room then
			self.currentRoomId = decoded.room.id
			self.currentRoom = decoded.room
			self:MaybeAutoReadyManager(decoded.room)
			MESSAGEMAN:Broadcast("OnlineLobbyState", self:LobbyStatePayload(decoded.room))
		end
		if callback then callback(ok, decoded, response) end
	end)
end

function ITGOnline:DeclineInvitation(invitationId, callback)
	self:Request("POST", "/room-invitations/" .. tostring(invitationId) .. "/decline", {}, callback)
end

function ITGOnline:AcceptJoinRequest(joinRequestId, callback)
	self:Request("POST", "/room-join-requests/" .. tostring(joinRequestId) .. "/accept", {}, callback)
end

function ITGOnline:DeclineJoinRequest(joinRequestId, reason, callback)
	self:Request("POST", "/room-join-requests/" .. tostring(joinRequestId) .. "/decline", {
		reason = reason or "",
	}, callback)
end

function ITGOnline:LeaveRoom(callback)
	if not self.currentRoomId then
		if callback then callback(true, {}) end
		return
	end
	local roomId = self.currentRoomId
	self:Request("POST", "/rooms/" .. tostring(roomId) .. "/leave", {}, function(ok, decoded, response)
		local gone = response and (response.statusCode == 404 or response.statusCode == 410)
		if ok or gone then
			self.currentRoomId = nil
			self.currentRoom = nil
			self.currentSongPayload = nil
			self.pendingJoinRoomId = nil
		end
		if callback then callback(ok or gone, decoded, response) end
	end)
end

function ITGOnline:FetchRoom(roomId, callback)
	roomId = roomId or self.currentRoomId or self.pendingJoinRoomId
	if not roomId then return end
	self:Request("GET", "/rooms/" .. tostring(roomId), nil, function(ok, decoded, response)
		if ok and decoded and decoded.room then
			self.currentRoomId = decoded.room.id
			self.currentRoom = decoded.room
			self:MaybeAutoReadyManager(decoded.room)
			if decoded.room.selected_song and decoded.room.selected_song.song_hash and decoded.room.selected_song.chart_hash then
				self.currentSongPayload = decoded.room.selected_song
			end
			self.pendingJoinRoomId = nil
		end
		if callback then callback(ok, decoded, response) end
	end)
end

function ITGOnline:HandleRealtimeEvent(event)
	if type(event) ~= "table" then
		online_trace("Ignored malformed realtime event.")
		return
	end
	local name = event.event or event.name
	local payload = event.payload or {}
	local eventId = tonumber(event.id)
	if eventId and eventId > 0 then
		self.lastEventCursor = math.max(self.lastEventCursor or 0, math.floor(eventId))
	end
	if not name then
		online_trace("Ignored realtime event without name.")
		return
	end

	local room_event_is_relevant = function(roomId)
		if not roomId then return true end
		local expected = self.currentRoomId or self.pendingJoinRoomId
		return expected == nil or tonumber(roomId) == tonumber(expected)
	end

	if name == "connection.ready" then
			if self.UpdateServerClockOffset then
				self:UpdateServerClockOffset(event.server_time or payload.server_time, GetTimeSinceStart(), GetTimeSinceStart())
			end
			if GetTimeSinceStart() - (self.lastSyncRequestedAt or 0) > 1 then
				self:Sync()
			end
	elseif name == "server.ping" then
		-- Heartbeat frame from server; no client-side action required.
		return
	elseif name == "connection.closed" then
		-- Informational frame. WebSocket close lifecycle is handled by onMessage Close.
		return
	elseif name == "lobby.updated" then
		self:QueueLobbyRefresh()
	elseif name == "room.invitation.created" then
		MESSAGEMAN:Broadcast("OnlineRoomInvitation", payload)
	elseif name == "room.join_request.declined" then
		if payload.room_id == nil or tonumber(payload.room_id) == tonumber(self.pendingJoinRoomId or -1) then
			self.pendingJoinRoomId = nil
		end
		MESSAGEMAN:Broadcast("OnlineResponseStatus", {
			event = "joinLobby",
			success = false,
			message = payload.reason and payload.reason ~= "" and ("Join request declined: " .. tostring(payload.reason)) or "Join request declined."
		})
	elseif name == "room.join_request.accepted" and payload.room_id then
		if not room_event_is_relevant(payload.room_id) then return end
		self:FetchRoom(payload.room_id, function(ok, decoded)
			if ok and decoded and decoded.room then
				MESSAGEMAN:Broadcast("OnlineLobbyState", self:LobbyStatePayload(decoded.room))
			end
		end)
	elseif name == "room.song_previewed" then
		MESSAGEMAN:Broadcast("OnlineSongPreview", payload.preview or {})
	elseif name == "room.score_updated" then
		local roomId = tonumber(payload.room_id)
		local expectedRoomId = tonumber(self.currentRoomId or self.pendingJoinRoomId or -1)
		if roomId and expectedRoomId > 0 and roomId ~= expectedRoomId then
			return
		end

		local incomingVersion = tonumber(payload.leaderboard_version_ms) or 0
		local versionRoomId = tostring(roomId or expectedRoomId or "")
		if versionRoomId ~= "" then
			local previousVersion = tonumber(self.lastLeaderboardVersionByRoomId[versionRoomId]) or 0
			if incomingVersion > 0 and incomingVersion < previousVersion then
				return
			end
			if incomingVersion > 0 then
				self.lastLeaderboardVersionByRoomId[versionRoomId] = incomingVersion
			end
		end

		if payload.leaderboard then
			MESSAGEMAN:Broadcast("ITGOnlineLeaderboardUpdated", {
				leaderboard = payload.leaderboard,
				room_id = payload.room_id,
				leaderboard_version_ms = incomingVersion,
			})
		end
	elseif name == "room.load_timeout" then
		if payload.room then
			self.currentRoomId = payload.room.id
			self.currentRoom = payload.room
			self:MaybeAutoReadyManager(payload.room)
			self.songLoadedAckKey = ""
			MESSAGEMAN:Broadcast("OnlineLobbyState", self:LobbyStatePayload(payload.room))
		end
		MESSAGEMAN:Broadcast("OnlineResponseStatus", {
			event = "songLoaded",
			success = false,
			message = "Song loading timed out. Returning to lobby."
		})
	elseif name and name:match("^room%.") then
		local roomId = payload.room_id
			or (payload.room and payload.room.id)
			or (event.target and event.target.id)
			or payload.id
			or self.currentRoomId
			or self.pendingJoinRoomId
		if not room_event_is_relevant(roomId) then return end
		if payload.room then
			online_flow_trace("realtime_room_event name=" .. tostring(name)
				.. " payloadPhase=" .. tostring(payload.room.phase)
				.. " previousPhase=" .. tostring(self.currentRoom and self.currentRoom.phase or "no-room")
				.. " eventId=" .. tostring(eventId))
			self.currentRoomId = payload.room.id
			self.currentRoom = payload.room
			self:MaybeAutoReadyManager(payload.room)
			MESSAGEMAN:Broadcast("OnlineLobbyState", self:LobbyStatePayload(payload.room))
			if payload.room.play_state then
				MESSAGEMAN:Broadcast("ITGOnlinePlayStateUpdated", payload.room.play_state)
			end
		elseif roomId then
			online_flow_trace("realtime_room_event_fetch name=" .. tostring(name)
				.. " roomId=" .. tostring(roomId)
				.. " eventId=" .. tostring(eventId))
			self:FetchRoom(roomId, function(ok, decoded)
				if ok and decoded and decoded.room then
					online_flow_trace("realtime_room_event_fetch_result name=" .. tostring(name)
						.. " roomId=" .. tostring(roomId)
						.. " phase=" .. tostring(decoded.room.phase))
					MESSAGEMAN:Broadcast("OnlineLobbyState", self:LobbyStatePayload(decoded.room))
				end
			end)
		end
	else
		online_trace("Unhandled realtime event: " .. tostring(name))
	end
end

function ITGOnline:LobbySearchPayload(decoded)
	local lobbies = {}
	local rooms = decoded and decoded.public_rooms or {}
	for room in ivalues(rooms) do
		lobbies[#lobbies + 1] = {
			code = tostring(room.id),
			roomId = room.id,
			name = room.name,
			playerCount = room.members_count or 0,
			phase = room.phase,
		}
	end

	local onlinePlayers = {}
	local users = decoded and decoded.online_users or {}
	for user in ivalues(users) do
		local isSelf = self.user and tonumber(user.id) == tonumber(self.user.id)
		if not isSelf then onlinePlayers[#onlinePlayers + 1] = {
			id = user.id,
			name = user.name or ("User " .. tostring(user.id or "?")),
			status = user.status or "available",
			room = user.room,
			lastSeenAt = user.last_seen_at,
			isSelf = false,
		} end
	end

	return {
		lobbies = lobbies,
		onlinePlayers = onlinePlayers,
	}
end

function ITGOnline:LobbyStatePayload(room)
	room = room or self.currentRoom
	if not room then return { code = "", players = {} } end
	self:UpdateScheduledStart(room)
	self:MaybeAckScheduledStart(room)

	local readyByUserId = {}
	if room.ready_states then
		for state in ivalues(room.ready_states) do
			if state.user and state.user.id then
				readyByUserId[tostring(state.user.id)] = state.is_ready and true or false
			elseif state.user_id then
				readyByUserId[tostring(state.user_id)] = state.is_ready and true or false
			end
		end
	end

	local playByUserId = {}
	local playState = room.play_state or {}
	for session in ivalues(playState.sessions or {}) do
		local user = session.user or {}
		local userId = tostring(user.id or session.user_id or "")
		if userId ~= "" then playByUserId[userId] = session end
	end

	local liveScoreByUserId = {}
	for score in ivalues(room.live_scores or room.top_scores or {}) do
		local user = score.user or {}
		local userId = tostring(user.id or score.user_id or "")
		if userId ~= "" then liveScoreByUserId[userId] = score end
	end

	local screenName = "ScreenOnlineLobbies"
	if room.phase == "config" or room.phase == "lobby_ready" then
		screenName = "ScreenPlayerOptions"
	elseif room.phase == "starting" or room.phase == "playing" then
		screenName = "ScreenGameplay"
	elseif room.phase == "results" then
		screenName = "ScreenOnlineLobbies"
	end
	local players = {}
	for member in ivalues(room.members or {}) do
		local user = member.user or member
		local userId = tostring(user.id or member.user_id or "")
		local session = playByUserId[userId] or {}
		local state = tostring(session.state or "pending")
		local memberScreenName = screenName
		if room.phase == "playing" and state ~= "playing" then
			memberScreenName = "ScreenOnlineLobbies"
		end
			local liveScore = liveScoreByUserId[userId] or {}
			local selectedMaxScore = tonumber(room.selected_song and room.selected_song.max_score) or 0
			local scorePercent = tonumber(liveScore.accuracy or session.last_accuracy)
			local exPercent = tonumber(liveScore.score_percent)
			if exPercent == nil and selectedMaxScore > 0 and tonumber(liveScore.score or session.last_score) then
				exPercent = math.max(0, math.min(100, (tonumber(liveScore.score or session.last_score) / selectedMaxScore) * 100))
			end
		-- Unified online score semantics:
		-- - `score` is what we treat as the canonical displayed competition percentage.
		-- - `accuracy` keeps the judgment-derived metric for diagnostics.
		local displayedPercent = exPercent
		if displayedPercent == nil then
			displayedPercent = scorePercent
		end
			players[#players + 1] = {
				playerId = userId,
				profileName = user.name or ("Player " .. userId),
				screenName = memberScreenName,
				ready = readyByUserId[userId] == true,
				missingSong = member.missing_song and true or false,
				missingSongReason = member.missing_song_reason,
				songAvailable = member.song_available and true or false,
				speedMod = member.options and member.options.speed_mod or nil,
				musicRateBpm = member.options and member.options.music_rate_bpm or nil,
				stepchart = member.options and member.options.stepchart or nil,
				playState = state,
				isPlayingSong = state == "playing" and room.phase == "playing",
				score = displayedPercent,
				accuracy = scorePercent,
				exScore = exPercent,
			}
	end

	local songInfo = nil
	if room.selected_song then
			songInfo = {
				songPath = room.selected_song.folder_name or "",
				title = room.selected_song.title or "",
				artist = room.selected_song.artist or "",
				pack = room.selected_song.pack or tostring(room.selected_song.folder_name or ""):match("^([^/]+)") or "",
				songLength = room.selected_song.music_length_seconds or room.selected_song.chart_duration_seconds,
				songHash = room.selected_song.song_hash or "",
				chartHash = room.selected_song.chart_hash or "",
			chartType = room.selected_song.chart_type or "",
			difficulty = room.selected_song.difficulty or "",
			meter = room.selected_song.meter,
		}
	end

		return {
			code = tostring(room.id),
			roomId = room.id,
			phase = room.phase,
			startAt = room.start_at,
			startAtMs = room.start_at_ms,
			startedAt = room.started_at,
			startedAtMs = room.started_at_ms,
			serverTime = room.server_time,
			serverTimeMs = room.server_time_ms,
			playState = room.play_state,
			estimatedEndAt = playState.estimated_end_at,
			estimatedEndAtMs = playState.estimated_end_at_ms,
			remainingSeconds = playState.remaining_seconds,
			finalResults = playState.final_results or {},
			secondsUntilStart = self:SecondsUntilScheduledStart(),
			manager = room.manager,
			isManager = self.user and room.manager and tonumber(room.manager.id) == tonumber(self.user.id) or false,
			players = players,
		songInfo = songInfo,
	}
end
