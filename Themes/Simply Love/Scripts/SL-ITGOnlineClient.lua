-- -----------------------------------------------------------------------
-- ITG Online API client.
--
-- This bridges Simply Love's existing online-lobby UI to the Laravel server.
-- Save/ITGOnline.ini stores connection settings only; the password is kept in
-- memory for the current session and is never persisted to disk.

ITGOnline = ITGOnline or {}

ITGOnline.configPath = "/Save/ITGOnline.ini"
ITGOnline.defaults = {
	apiBaseUrl = "https://itgonline.fr/api/v1",
	webSocketUrl = "wss://ws.itgonline.fr",
	deviceName = "itgmania-client",
}

ITGOnline.requests = ITGOnline.requests or {}
ITGOnline.nextRequestId = ITGOnline.nextRequestId or 1
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

local function trim(value)
	return tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function normalize_base_url(value)
	value = trim(value)
	if value == "" then return ITGOnline.defaults.apiBaseUrl end
	return value:gsub("/+$", "")
end

local function origin_from_base_url(value)
	value = normalize_base_url(value)
	return value:match("^(https?://[^/]+)") or ""
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

local function online_trace(message)
	if Trace then Trace("ITG Online: " .. tostring(message or "")) end
end

local function request_id()
	if CRYPTMAN and CRYPTMAN.GenerateRandomUUID then
		return CRYPTMAN:GenerateRandomUUID()
	end

	return tostring(GetTimeSinceStart()) .. "-" .. tostring(math.random(100000, 999999))
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

	local days = days_from_civil(tonumber(year), tonumber(month), tonumber(day))
	local seconds = (((days * 24 + tonumber(hour)) * 60 + tonumber(minute)) * 60) + tonumber(second)
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

local function selected_steps()
	local player = first_enabled_player()
	return (GAMESTATE:IsCourseMode() and GAMESTATE:GetCurrentTrail(player)) or GAMESTATE:GetCurrentSteps(player)
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
	return {
			apiBaseUrl = normalize_base_url(section["ApiBaseUrl"]),
			webSocketUrl = trim(section["WebSocketUrl"]) ~= "" and trim(section["WebSocketUrl"]) or ITGOnline.defaults.webSocketUrl,
			email = trim(section["Email"]),
			password = tostring(ITGOnline.transientPassword or ""),
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
			webSocketUrl = trim(values.webSocketUrl or current.webSocketUrl) ~= "" and trim(values.webSocketUrl or current.webSocketUrl) or ITGOnline.defaults.webSocketUrl,
			email = trim(values.email or current.email),
			deviceName = trim(values.deviceName or current.deviceName) ~= "" and trim(values.deviceName or current.deviceName) or ITGOnline.defaults.deviceName,
		}
	ITGOnline.transientPassword = tostring(values.password ~= nil and values.password or current.password or ITGOnline.transientPassword or "")
	nextConfig.password = ITGOnline.transientPassword

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

function ITGOnline:Request(method, path, payload, callback, alreadyRetriedAuth)
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
			if not record or record.cancelled then
				return
			end

			ITGOnline.requests[requestId] = nil
			local decoded = safe_decode(response and response.body)
			local ok = response and response.statusCode and response.statusCode >= 200 and response.statusCode < 300
			local duration = math.floor((GetTimeSinceStart() - startedAt) * 1000)
			local responseBytes = response and response.body and #tostring(response.body) or 0
			local errorCode = decoded and decoded.error_code or response and response.error or nil
			online_trace(method .. " " .. path .. " -> " .. tostring(response and response.statusCode or "no-status") .. " in " .. tostring(duration) .. "ms, " .. tostring(responseBytes) .. "b" .. (errorCode and (", error=" .. tostring(errorCode)) or "") .. " [" .. traceId .. "]")
			if not ok and response and response.body then
				online_trace(method .. " " .. path .. " body: " .. tostring(response.body))
			end

			if response and response.statusCode == 401 and path ~= "/auth/login" and not alreadyRetriedAuth then
				self:Login(function(loginOk)
					if loginOk then
						self:Request(method, path, payload, callback, true)
						return
					end

					self.sessionExpired = true
					MESSAGEMAN:Broadcast("OnlineSessionExpired")
					if callback then callback(false, decoded, response) end
				end)
				return
			end

			if callback then callback(ok, decoded, response) end
		end,
	}
	self.requests[requestId] = { future = request, cancelled = false }
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
		if callback then callback(true) end
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
				["Sec-WebSocket-Protocol"] = "itgmania-ticket." .. tostring(decoded.ticket),
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

function ITGOnline:Connect(callbacks)
	self.disconnecting = false
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
	self.pendingJoinRoomId = nil
	self.scheduledStartLocalTime = nil
end

function ITGOnline:Sync(callback)
	local cursor = tonumber(self.lastEventCursor or 0) or 0
	self:Request("GET", "/sync?cursor=" .. tostring(math.floor(cursor)), nil, function(ok, decoded, response)
		if ok and decoded then
			if decoded.next_cursor then
				self.lastEventCursor = math.max(self.lastEventCursor or 0, tonumber(decoded.next_cursor) or 0)
			end

			if decoded.current_room then
				self.currentRoomId = decoded.current_room.id
				self.currentRoom = decoded.current_room
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
						target_user_id = joinRequest.target and joinRequest.target.id or nil,
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

			for event in ivalues(decoded.events or {}) do
				self:HandleRealtimeEvent(event)
			end
		end

		if callback then callback(ok, decoded, response) end
	end)
end

function ITGOnline:BuildSongPayload()
	local song = GAMESTATE:GetCurrentSong()
	if not song then return nil end

	local steps = selected_steps()
	local path = song_path(song)
	local stepsHash = steps and tostring(steps:GetHash()) or "no-steps"
	local chartType = normalize_chart_type(steps and enum_short(steps:GetStepsType()) or "")
	local difficulty = steps and enum_short(steps:GetDifficulty()) or "unknown"
	local meter = steps and steps:GetMeter() or nil

	local songHashSource = table.concat({
		path,
		song:GetDisplayFullTitle() or "",
		song:GetDisplayArtist() or "",
		tostring(song:MusicLengthSeconds() or 0),
	}, "|")

	return {
		title = song:GetDisplayFullTitle(),
		artist = song:GetDisplayArtist(),
		pack = path:match("^([^/]+)") or "",
		folder_name = path,
		song_hash = sha256_hex(songHashSource),
		chart_hash = sha256_hex(stepsHash),
		chart_type = chartType,
		difficulty = difficulty,
		meter = meter,
		rate = 1.0,
		music_length_seconds = math.max(1, math.floor(song:MusicLengthSeconds() or 1)),
		chart_duration_seconds = math.max(1, math.floor(song:MusicLengthSeconds() or 1)),
	}
end

function ITGOnline:SelectSong(callback)
	if not self.currentRoomId then return end
	local payload = self:BuildSongPayload()
	if not payload then return end

	self.currentSongPayload = payload
	self:Request("POST", "/rooms/" .. tostring(self.currentRoomId) .. "/song-selection", payload, function(ok, decoded, response)
		if ok and decoded and decoded.room then
			self.currentRoom = decoded.room
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
	}, callback)
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

function ITGOnline:SendScore(force)
	if not self.currentRoomId or not self.currentSongPayload then return end
	if not self.currentRoom or self.currentRoom.phase ~= "playing" then return end
	if not force and GetTimeSinceStart() - self.lastScoreSentAt < 1 then return end
	self.lastScoreSentAt = GetTimeSinceStart()

	local player = first_enabled_player()
	local stats = STATSMAN:GetCurStageStats():GetPlayerStageStats(player)
	local dancePoints = stats:GetPercentDancePoints()
	local accuracy = math.max(0, math.min(100, (tonumber(dancePoints) or 0) * 100))
	local exScore = CalculateExScore(player) or 0
	local songPosition = GAMESTATE:GetPlayerState(player):GetSongPosition():GetMusicSeconds()
	local maxCombo = stats.MaxCombo and stats:MaxCombo() or stats:GetCurrentCombo()

	self:Request("POST", "/rooms/" .. tostring(self.currentRoomId) .. "/score", {
		score = math.max(0, math.floor(exScore * 1000000)),
		combo = math.max(0, stats:GetCurrentCombo() or 0),
		max_combo = math.max(0, maxCombo or 0),
		accuracy = accuracy,
		song_position_seconds = math.max(0, songPosition or 0),
		song_hash = self.currentSongPayload.song_hash,
		chart_hash = self.currentSongPayload.chart_hash,
		failed = stats:GetFailed() and true or false,
		judgments = self:ServerJudgments(player),
	})
end

function ITGOnline:SetReady(phase, isReady, callback)
	if not self.currentRoomId then
		if callback then callback(false, nil, { errorMessage = "No active online room." }) end
		return
	end
	self:Request("POST", "/rooms/" .. tostring(self.currentRoomId) .. "/ready", {
		phase = phase,
		is_ready = isReady and true or false,
	}, function(ok, decoded, response)
		if ok and decoded and decoded.room then
			self.currentRoom = decoded.room
		end
		if callback then callback(ok, decoded, response) end
	end)
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

	local waitForConfig
	waitForConfig = function(attempt)
		attempt = attempt or 1
			self:FetchRoom(self.currentRoomId, function(fetchOk, fetchDecoded, fetchResponse)
				if not fetchOk or not fetchDecoded or not fetchDecoded.room then
				finish(false, fetchDecoded, fetchResponse)
				return
			end

			local room = fetchDecoded.room
			if not room.selected_song then
				self:SelectSongAndMarkLobbyReady(function(ok, decoded, response)
					if ok and attempt < 6 then
						waitForConfig(attempt + 1)
					else
						finish(ok, decoded, response)
					end
				end)
				return
			end

			if room.phase == "config" or room.phase == "starting" or room.phase == "playing" then
				finishConfigReady()
			elseif room.phase == "lobby" or room.phase == "lobby_ready" then
				self:SetReady("lobby_ready", true, function(readyOk, readyDecoded, readyResponse)
					if readyOk and readyDecoded and readyDecoded.room then
						MESSAGEMAN:Broadcast("OnlineLobbyState", self:LobbyStatePayload(readyDecoded.room))
					end

					if readyOk and attempt < 6 then
						waitForConfig(attempt + 1)
					else
						finish(readyOk, readyDecoded, readyResponse)
					end
				end)
			else
				finish(false, fetchDecoded, { errorMessage = "Room is not accepting ready state." })
			end
		end)
	end

	waitForConfig(1)
end

function ITGOnline:StartRoom(callback)
	if not self.currentRoomId then
		if callback then callback(false, nil, { errorMessage = "No active online room." }) end
		return
	end
	self:Request("POST", "/rooms/" .. tostring(self.currentRoomId) .. "/start", {}, function(ok, decoded, response)
		if ok and decoded and decoded.room then
			self.currentRoom = decoded.room
		end
		if callback then callback(ok, decoded, response) end
	end)
end

function ITGOnline:UpdateScheduledStart(room)
	room = room or self.currentRoom
	if not room then return end

	local startAtMs = tonumber(room.start_at_ms or "") or iso_utc_milliseconds(room.start_at)
	local serverTimeMs = tonumber(room.server_time_ms or "") or iso_utc_milliseconds(room.server_time)

	if startAtMs and serverTimeMs then
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

function ITGOnline:FetchCurrentRoom(callback)
	self:Request("GET", "/rooms/current", nil, function(ok, decoded, response)
		if ok and decoded and decoded.room then
			self.currentRoomId = decoded.room.id
			self.currentRoom = decoded.room
			if decoded.room.selected_song and decoded.room.selected_song.song_hash and decoded.room.selected_song.chart_hash then
				self.currentSongPayload = decoded.room.selected_song
			end
			self:AutoAcceptPendingRequests(decoded.room)
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

	self:Request("POST", "/rooms/" .. tostring(self.currentRoomId) .. "/song-availability", {
		missing = missing and true or false,
		reason = reason or (missing and "unknown" or "reloaded"),
	}, function(ok, decoded, response)
		if ok and decoded and decoded.room then
			self.currentRoom = decoded.room
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
			if decoded.room.selected_song and decoded.room.selected_song.song_hash and decoded.room.selected_song.chart_hash then
				self.currentSongPayload = decoded.room.selected_song
			end
			self.pendingJoinRoomId = nil
			self:AutoAcceptPendingRequests(decoded.room)
		end
		if callback then callback(ok, decoded, response) end
	end)
end

function ITGOnline:AutoAcceptPendingRequests(room)
	if not room or not self.user or not room.manager or tonumber(room.manager.id) ~= tonumber(self.user.id) then return end
	if not room.pending_join_requests then return end
	self.acceptedJoinRequestIds = self.acceptedJoinRequestIds or {}

	for request in ivalues(room.pending_join_requests) do
		local requestId = request and tostring(request.id or "")
		if request and request.id and request.status == "pending" and not self.acceptedJoinRequestIds[requestId] then
			self.acceptedJoinRequestIds[requestId] = true
			self:AcceptJoinRequest(request.id, function()
				self:FetchRoom(room.id)
			end)
		end
	end
end

function ITGOnline:HandleRealtimeEvent(event)
	if type(event) ~= "table" then
		online_trace("Ignored malformed realtime event.")
		return
	end
	local name = event.event or event.name
	local payload = event.payload or {}
	if event.id then
		self.lastEventCursor = math.max(self.lastEventCursor or 0, tonumber(event.id) or 0)
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
		self:Sync()
	elseif name == "lobby.updated" then
		self:FetchLobby(function(ok, decoded)
			if ok then MESSAGEMAN:Broadcast("LobbySearched", self:LobbySearchPayload(decoded)) end
		end)
	elseif name == "room.invitation.created" then
		MESSAGEMAN:Broadcast("OnlineRoomInvitation", payload)
	elseif name == "room.private_join_request.created" then
		MESSAGEMAN:Broadcast("OnlinePrivateJoinRequest", payload)
	elseif name == "room.join_request.declined" then
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
	elseif name and name:match("^room%.") then
		local roomId = payload.room_id
			or (payload.room and payload.room.id)
			or (event.target and event.target.id)
			or payload.id
			or self.currentRoomId
			or self.pendingJoinRoomId
		if not room_event_is_relevant(roomId) then return end
		if payload.room then
			self.currentRoomId = payload.room.id
			self.currentRoom = payload.room
			MESSAGEMAN:Broadcast("OnlineLobbyState", self:LobbyStatePayload(payload.room))
		elseif roomId then
			self:FetchRoom(roomId, function(ok, decoded)
				if ok and decoded and decoded.room then
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
			isPasswordProtected = false,
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

	local screenName = "ScreenOnlineLobbies"
	if room.phase == "config" or room.phase == "lobby_ready" then
		screenName = "ScreenPlayerOptions"
	elseif room.phase == "starting" or room.phase == "playing" then
		screenName = "ScreenGameplay"
	elseif room.phase == "results" then
		screenName = "ScreenEvaluationStage"
	end
	local players = {}
	for member in ivalues(room.members or {}) do
		local user = member.user or member
		local userId = tostring(user.id or member.user_id or "")
			players[#players + 1] = {
				playerId = userId,
				profileName = user.name or ("Player " .. userId),
				screenName = screenName,
				ready = readyByUserId[userId] == true,
				missingSong = member.missing_song and true or false,
				missingSongReason = member.missing_song_reason,
				score = nil,
				exScore = nil,
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
			secondsUntilStart = self:SecondsUntilScheduledStart(),
			manager = room.manager,
			isManager = self.user and room.manager and tonumber(room.manager.id) == tonumber(self.user.id) or false,
			players = players,
		songInfo = songInfo,
	}
end
