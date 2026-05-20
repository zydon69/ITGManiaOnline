-- -----------------------------------------------------------------------
-- ITG Online API client.
--
-- This bridges Simply Love's existing online-lobby UI to the Laravel server.
-- Credentials are intentionally read from a local Save/ITGOnline.ini file and
-- are never committed with the theme.

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
	if decoded and decoded.message then return decoded.message end
	if response and response.statusCode then return fallback .. " (" .. tostring(response.statusCode) .. ")" end
	return fallback
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

local function read_config()
	if not FILEMAN:DoesFileExist(ITGOnline.configPath) then
		IniFile.WriteFile(ITGOnline.configPath, {
			["ITGOnline"] = {
				["ApiBaseUrl"] = ITGOnline.defaults.apiBaseUrl,
				["WebSocketUrl"] = ITGOnline.defaults.webSocketUrl,
				["Email"] = "",
				["Password"] = "",
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
		password = tostring(section["Password"] or ""),
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
		password = tostring(values.password ~= nil and values.password or current.password or ""),
		deviceName = trim(values.deviceName or current.deviceName) ~= "" and trim(values.deviceName or current.deviceName) or ITGOnline.defaults.deviceName,
	}

	IniFile.WriteFile(ITGOnline.configPath, {
		["ITGOnline"] = {
			["ApiBaseUrl"] = nextConfig.apiBaseUrl,
			["WebSocketUrl"] = nextConfig.webSocketUrl,
			["Email"] = nextConfig.email,
			["Password"] = nextConfig.password,
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
	return {
		["Accept"] = "application/json",
		["Content-Type"] = "application/json",
		["Authorization"] = "Bearer " .. tostring(self.token or ""),
	}
end

function ITGOnline:Request(method, path, payload, callback)
	local config = self:Config()
	local url = config.apiBaseUrl .. path
	local body = payload and JsonEncode(payload) or ""
	local requestId = self.nextRequestId
	self.nextRequestId = self.nextRequestId + 1

	local headers = {
		["Accept"] = "application/json",
		["Content-Type"] = "application/json",
	}
	if self.token then
		headers["Authorization"] = "Bearer " .. self.token
	end

	self.requests[requestId] = NETWORK:HttpRequest{
		url = url,
		method = method,
		body = body,
		headers = headers,
		connectTimeout = 5,
		transferTimeout = 20,
		onResponse = function(response)
			ITGOnline.requests[requestId] = nil
			local decoded = safe_decode(response and response.body)
			local ok = response and response.statusCode and response.statusCode >= 200 and response.statusCode < 300
			if callback then callback(ok, decoded, response) end
		end,
	}
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
			automaticReconnect = true,
			onMessage = function(msg)
				local msgType = ToEnumShortString(msg.type)
				if msgType == "Open" then
					if callbacks and callbacks.open then callbacks.open() end
				elseif msgType == "Message" then
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
	self:Login(function(ok, errorMessage)
		if not ok then
			if callbacks and callbacks.error then callbacks.error(errorMessage) end
			return
		end
		self:ConnectWebSocket(callbacks)
	end)
end

function ITGOnline:Disconnect()
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
end

function ITGOnline:BuildSongPayload()
	local song = GAMESTATE:GetCurrentSong()
	if not song then return nil end

	local steps = selected_steps()
	local path = song_path(song)
	local stepsHash = steps and tostring(steps:GetHash()) or "no-steps"
	local chartType = steps and enum_short(steps:GetStepsType()) or "unknown"
	local difficulty = steps and enum_short(steps:GetDifficulty()) or "unknown"
		local meter = steps and steps:GetMeter() or nil
		local chartName = steps and steps:GetChartName() or ""

		local songHashSource = table.concat({
			path,
			song:GetDisplayFullTitle() or "",
			song:GetDisplayArtist() or "",
			tostring(song:MusicLengthSeconds() or 0),
		}, "|")

		local chartHashSource = table.concat({
			path,
			chartType,
			difficulty,
			tostring(meter or ""),
		chartName or "",
		stepsHash,
	}, "|")

	return {
		title = song:GetDisplayFullTitle(),
		artist = song:GetDisplayArtist(),
		pack = path:match("^([^/]+)") or "",
		folder_name = path,
		song_hash = sha256_hex(songHashSource),
		chart_hash = sha256_hex(chartHashSource),
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
		if callback then callback(ok, decoded, response) end
		if ok then self:FetchRoom(self.currentRoomId) end
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

function ITGOnline:SendScore()
	if not self.currentRoomId or not self.currentSongPayload then return end
	if not self.currentRoom or self.currentRoom.phase ~= "playing" then return end
	if GetTimeSinceStart() - self.lastScoreSentAt < 1 then return end
	self.lastScoreSentAt = GetTimeSinceStart()

	local player = first_enabled_player()
	local stats = STATSMAN:GetCurStageStats():GetPlayerStageStats(player)
	local dancePoints = stats:GetPercentDancePoints()
	local accuracy = tonumber(FormatPercentScore(dancePoints):gsub("%%", "")) or 0
	local exScore = CalculateExScore(player) or 0
	local songPosition = GAMESTATE:GetPlayerState(player):GetSongPosition():GetMusicSeconds()

	self:Request("POST", "/rooms/" .. tostring(self.currentRoomId) .. "/score", {
		score = math.max(0, math.floor(exScore * 1000000)),
		combo = math.max(0, stats:GetCurrentCombo() or 0),
		max_combo = math.max(0, stats:GetCurrentCombo() or 0),
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
		}, callback)
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
		if ok then
			self.currentRoomId = nil
			self.currentRoom = nil
			self.currentSongPayload = nil
		end
		if callback then callback(ok, decoded, response) end
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

	for request in ivalues(room.pending_join_requests) do
		if request and request.id and request.status == "pending" then
			self:AcceptJoinRequest(request.id, function()
				self:FetchRoom(room.id)
			end)
		end
	end
end

function ITGOnline:HandleRealtimeEvent(event)
	if type(event) ~= "table" then return end
	local name = event.event or event.name
	local payload = event.payload or {}

	if name == "connection.ready" then
		if self.currentRoomId then self:FetchRoom(self.currentRoomId) end
	elseif name == "lobby.updated" then
		self:FetchLobby(function(ok, decoded)
			if ok then MESSAGEMAN:Broadcast("LobbySearched", self:LobbySearchPayload(decoded)) end
		end)
	elseif name == "room.private_join_request.created" then
		MESSAGEMAN:Broadcast("OnlinePrivateJoinRequest", payload)
	elseif name == "room.join_request.declined" then
		MESSAGEMAN:Broadcast("OnlineResponseStatus", {
			event = "joinLobby",
			success = false,
			message = payload.reason and payload.reason ~= "" and ("Join request declined: " .. tostring(payload.reason)) or "Join request declined."
		})
	elseif name == "room.join_request.accepted" and payload.room_id then
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
		if roomId then
			self:FetchRoom(roomId, function(ok, decoded)
				if ok and decoded and decoded.room then
					MESSAGEMAN:Broadcast("OnlineLobbyState", self:LobbyStatePayload(decoded.room))
				end
			end)
		end
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

	local screen = SCREENMAN:GetTopScreen()
	local screenName = screen and screen:GetName() or "ScreenSelectMusic"
	local players = {}
	for member in ivalues(room.members or {}) do
		local user = member.user or member
		local userId = tostring(user.id or member.user_id or "")
			players[#players + 1] = {
				playerId = userId,
				profileName = user.name or ("Player " .. userId),
				screenName = screenName,
				ready = readyByUserId[userId] == true,
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
		manager = room.manager,
		isManager = self.user and room.manager and tonumber(room.manager.id) == tonumber(self.user.id) or false,
		players = players,
		songInfo = songInfo,
	}
end
