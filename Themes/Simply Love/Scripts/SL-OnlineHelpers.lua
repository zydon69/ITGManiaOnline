-- -----------------------------------------------------------------------
-- ALL ONLINE PLAY SOCKET STUFF

local isWaiting = false
local readyState = {
	["P1"] = true,
	["P2"] = true
}
local songSelected = false
-- Track Start button hold time for disconnect
local startHoldTime = {
	["P1"] = 0,
	["P2"] = 0
}
local lastDisconnectCountdown = nil
local lastSongPreviewSentAt = 0
local lastSongPreviewKey = ""
local lastOnlineOptionsSongKey = ""
local lastOnlineGameplayRoomId = nil
local pendingOnlineStartRoomId = nil
local pendingConfigReady = false
-- These screens are the ones we want to display the player's scores for.
local scoreScreens = {"ScreenGameplay", "ScreenEvaluationStage"}

local syncLockScreens = {
	["ScreenGameplay"] = true,
	["ScreenEvaluationStage"] = true,
}

local autoReadyScreens = {
	["ScreenSelectMusic"] = true,
	["ScreenEvaluationStage"] = true,
}

local knownDisconnectScreens = {
  ["ScreenTitleMenu"] = true,
  ["ScreenGameOver"] = true,
  ["ScreenNameEntryTraditional"] = true,
  ["ScreenOptionsService"] = true,
}

local DisplayLobbyState

local OnlineStartCountdownText = function()
	if not (ITGOnline and ITGOnline.SecondsUntilScheduledStart) then return nil end

	local seconds = ITGOnline:SecondsUntilScheduledStart()
	if not seconds then return nil end

	if seconds > 0 then
		return "Song starts in " .. tostring(math.ceil(seconds)) .. "..."
	end

	return "Song started. Syncing audio..."
end

-- This input handler is used to lock input while we're waiting on the server to tell us to proceed.
-- It does nothing, but it's necessary to prevent the player from interacting with the screen
-- until everyone is ready.
-- Holding Start for 5 seconds will disconnect from the lobby.
local InputHandler = function(event)
	local topScreen = SCREENMAN:GetTopScreen()
	if topScreen and isWaiting and event.PlayerNumber then
		local pn = ToEnumShortString(event.PlayerNumber)
		if event.type == "InputEventType_FirstPress" and event.GameButton == "Start" then
			startHoldTime[pn] = GetTimeSinceStart()
			lastDisconnectCountdown = nil
			if topScreen:GetName() == "ScreenGameplay" then
				readyState[pn] = true
				MESSAGEMAN:Broadcast("UpdateMachineState")
			end
		elseif event.type == "InputEventType_Repeat" and event.GameButton == "Start" then
			-- Check if Start has been held for 5 seconds
			if startHoldTime[pn] > 0 then
				local holdDuration = GetTimeSinceStart() - startHoldTime[pn]
				local remainingSeconds = math.max(0, 5 - math.floor(holdDuration))
				if remainingSeconds ~= lastDisconnectCountdown then
					SM("Continue holding &START; for " .. remainingSeconds .. " more seconds to disconnect...")
					lastDisconnectCountdown = remainingSeconds
				end
					if holdDuration >= 5.0 then
					SM("Disconnected from lobby.")
					startHoldTime[pn] = 0
					lastDisconnectCountdown = nil
					isWaiting = false
					local topScreen = SCREENMAN:GetTopScreen()
					if topScreen and topScreen:GetName() == "ScreenGameplay" then
						topScreen:PauseGame(false)
					end
					MESSAGEMAN:Broadcast("DisconnectOnline", {leaveRoom=true})
				end
			end
		elseif event.type == "InputEventType_Release" and event.GameButton == "Start" then
			startHoldTime[pn] = 0
			lastDisconnectCountdown = nil
		end
	end

	return false
end

local UnlockOnlineInput = function()
	isWaiting = false
	for player in ivalues(PlayerNumber) do
		SCREENMAN:set_input_redirected(player, false)
	end
end

local OnlineGameplayScreen = function()
	local style = GAMESTATE:GetCurrentStyle() and GAMESTATE:GetCurrentStyle():GetName() or ""
	return style == "routine" and "ScreenGameplayShared" or "ScreenGameplay"
end

local OnlineSongKey = function(data)
	if not data or not data.songInfo then return "" end
	return tostring(data.roomId or data.code or "") .. "|" .. tostring(data.songInfo.chartHash or data.songInfo.songPath or "")
end

local ApplyOnlineSongSelection = function(songInfo)
	if not songInfo or not songInfo.songPath then return false end

	local song = SONGMAN:FindSong(songInfo.songPath)
	local parts = songInfo.songPath:split("/")
	if not song and parts[2] then
		song = SONGMAN:FindSong(parts[2])
	end
	if not song then
		SM("Online song not found locally: " .. tostring(songInfo.songPath))
		MESSAGEMAN:Broadcast("OnlineMissingSong", {songInfo=songInfo})
		return false
	end

	GAMESTATE:SetCurrentSong(song)

	local stepsType = GAMESTATE:GetCurrentStyle() and GAMESTATE:GetCurrentStyle():GetStepsType() or nil
	local matchedSteps = nil
	if stepsType and songInfo.chartHash and songInfo.chartHash ~= "" and ITGOnline and ITGOnline.BuildSongPayload then
		for steps in ivalues(song:GetStepsByStepsType(stepsType)) do
			for player in ivalues(GAMESTATE:GetEnabledPlayers()) do
				GAMESTATE:SetCurrentSteps(player, steps)
			end
			local localPayload = ITGOnline:BuildSongPayload()
			if localPayload and localPayload.chart_hash == songInfo.chartHash then
				matchedSteps = steps
				break
			end
		end
	end
	if stepsType then
		for steps in ivalues(song:GetStepsByStepsType(stepsType)) do
			if matchedSteps then break end
			local difficultyMatches = songInfo.difficulty == nil or songInfo.difficulty == "" or ToEnumShortString(steps:GetDifficulty()) == songInfo.difficulty
			local meterMatches = songInfo.meter == nil or tonumber(songInfo.meter) == nil or steps:GetMeter() == tonumber(songInfo.meter)
			if difficultyMatches and meterMatches then
				matchedSteps = steps
				break
			end
		end
	end

	if not matchedSteps then
		for steps in ivalues(SongUtil.GetPlayableSteps(song)) do
			matchedSteps = steps
			break
		end
	end

	if matchedSteps then
		for player in ivalues(GAMESTATE:GetEnabledPlayers()) do
			GAMESTATE:SetCurrentSteps(player, matchedSteps)
		end
	end

	local localPayload = ITGOnline and ITGOnline.BuildSongPayload and ITGOnline:BuildSongPayload() or nil
	if localPayload then
		if songInfo.songHash and songInfo.songHash ~= "" and localPayload.song_hash ~= songInfo.songHash then
			SM("Online song hash mismatch for: " .. tostring(songInfo.songPath))
			MESSAGEMAN:Broadcast("OnlineMissingSong", {songInfo=songInfo, reason="hash_mismatch"})
			return false
		end
		if songInfo.chartHash and songInfo.chartHash ~= "" and localPayload.chart_hash ~= songInfo.chartHash then
			SM("Online chart hash mismatch for: " .. tostring(songInfo.songPath))
			MESSAGEMAN:Broadcast("OnlineMissingSong", {songInfo=songInfo, reason="hash_mismatch"})
			return false
		end
	end

	MESSAGEMAN:Broadcast("OnlineSongAvailable", {songInfo=songInfo})
	return true
end

local TransitionToOnlineOptions = function()
	local topScreen = SCREENMAN:GetTopScreen()
	if not topScreen then return end

	local screenName = topScreen:GetName()
	if screenName == "ScreenPlayerOptions"
		or screenName == "ScreenPlayerOptions2"
		or screenName == "ScreenPlayerOptions3"
		or screenName == "ScreenGameplay"
		or screenName == "ScreenGameplayShared" then
		return
	end

	topScreen:SetNextScreenName("ScreenPlayerOptions")
	topScreen:StartTransitioningScreen("SM_GoToNextScreen")
end

local TransitionToOnlineGameplay = function()
	local topScreen = SCREENMAN:GetTopScreen()
	if not topScreen then return end

	local screenName = topScreen:GetName()
	if screenName == "ScreenGameplay" or screenName == "ScreenGameplayShared" then
		return
	end

	topScreen:SetNextScreenName(OnlineGameplayScreen())
	topScreen:StartTransitioningScreen("SM_GoToNextScreen")
end

local ReturnToOnlineLobbyFromMusicSelect = function()
	local topScreen = SCREENMAN:GetTopScreen()
	if not topScreen or topScreen:GetName() ~= "ScreenSelectMusic" then return false end
	if not (ITGOnline and ITGOnline.currentRoomId) then return false end

	UnlockOnlineInput()
	topScreen:SetNextScreenName("ScreenOnlineLobbies")
	topScreen:StartTransitioningScreen("SM_GoToNextScreen")
	return true
end

local PollOnlineStart = function(actor, roomId)
	if not actor or not roomId or not (ITGOnline and ITGOnline.FetchRoom) then return end

	local timer = actor:GetChild("OnlineStartPollTimer")
	if not timer then return end

	pendingOnlineStartRoomId = roomId
	timer:stoptweening()
	timer:sleep(1):queuecommand("Poll")
end

local SelectMusicInputHandler = function(event)
	if not event or event.type ~= "InputEventType_FirstPress" then return false end

	local deviceButton = ""
	if event.DeviceInput and event.DeviceInput.button then
		deviceButton = string.lower(tostring(event.DeviceInput.button))
	end

	if event.GameButton == "Back" or string.find(deviceButton, "backspace", 1, true) then
		SOUND:PlayOnce(THEME:GetPathS("Common", "Cancel"))
		return ReturnToOnlineLobbyFromMusicSelect()
	end

	return false
end

local RestoreCurrentRoom = function(actor, callback)
	if not (ITGOnline and ITGOnline.FetchCurrentRoom) then
		if callback then callback(false) end
		return
	end

	ITGOnline:FetchCurrentRoom(function(ok, decoded)
		if ok and decoded and decoded.room then
			actor.inLobby = true
			local payload = ITGOnline:LobbyStatePayload(decoded.room)
			DisplayLobbyState(payload, actor)
			MESSAGEMAN:Broadcast("OnlineLobbyState", payload)
			ITGOnline:Heartbeat("in_room")
			if callback then callback(true) end
			return
		end

		actor.inLobby = false
		ITGOnline:Heartbeat("available")
		if callback then callback(false) end
	end)
end

local CreateRequest = function(event, data)
	return JsonEncode({
		event=event,
		data=data
	})
end

local GetJudgmentCounts = function(player)
	local counts = GetExJudgmentCounts(player)
	local translation = {
		["W0"] = "fantasticPlus",
		["W1"] = "fantastics",
		["W2"] = "excellents",
		["W3"] = "greats",
		["W4"] = "decents",
		["W5"] = "wayOffs",
		["Miss"] = "misses",
		["totalSteps"] = "totalSteps",
		["Mines"] = "minesHit",
		["totalMines"] = "totalMines",
		["Holds"] = "holdsHeld",
		["totalHolds"] = "totalHolds",
		["Rolls"] = "rollsHeld",
		["totalRolls"] = "totalRolls"
	}

	local judgmentCounts = {}

	for key, value in pairs(counts) do
		if translation[key] ~= nil then
			judgmentCounts[translation[key]] = value
		end
	end

	return judgmentCounts
end

local GetMachineState = function()
	-- NOTE(teejusb): Keep in mind that SCREENMAN:GetTopScreen() might return nil since we might be
	-- transitioning screens when we receive any messages from the server.

	local screen = SCREENMAN:GetTopScreen()
	-- Use a "NoScreen" fallback in case we're transitioning screens.
	local screenName = screen and screen:GetName() or "NoScreen"

	local players = {}
	for player in ivalues(GAMESTATE:GetEnabledPlayers()) do
		if GAMESTATE:IsSideJoined(player) then
			local profileName = "NoName"
			if (PROFILEMAN:IsPersistentProfile(player) and
					PROFILEMAN:GetProfile(player)) then
				profileName = PROFILEMAN:GetProfile(player):GetDisplayName()
			end

			local judgments = nil
			local score = nil
			local exScore = nil
			if screenName == "ScreenGameplay" or screenName == "ScreenEvaluationStage" then
				judgments = GetJudgmentCounts(player)
				local dance_points = STATSMAN:GetCurStageStats():GetPlayerStageStats(player):GetPercentDancePoints()
				local percent = FormatPercentScore( dance_points ):gsub("%%", "")
				score = tonumber(percent)
				exScore = CalculateExScore(player)
			end

			local pn = ToEnumShortString(player)
			players[pn] = {
				playerId = pn,
				profileName = profileName,
				screenName=screenName,
				ready=readyState[pn],

				judgments = judgments,
				score = score,
				exScore = exScore,
				-- TODO(teejusb): Add song progression.
			}
		end
	end

	-- If "P1"/"P2" is missing from players, then the player isn't enabled and the corresponding
	-- player1/player2 key will be nil.
	return {
		machine = {
			player1=players["P1"],
			player2=players["P2"]
		}
	}
end

local OrderPlayers = function(data, localScreenName)
	local updatedData = {
		players = {},

		-- Additional data that we can pre-calculate.
		aux = {
			-- Used to give input back to the players if we're waiting.
			allInSameScreen = true,
			-- Evaluation should stay locked only while any player is still in gameplay.
			anyInGameplay = false,
			-- Used to determine when to display the Ready/Not Ready state for players.
			allPlayersReady = true,
		}
	}

	--  Copy over the song info, if any.
	updatedData.songInfo = data.songInfo

	-- Use the current screen as the baseline to prevent
	-- incorrectly reporting all players as synchronized.
	local firstScreen = localScreenName
	-- Process the scoreScreens first so we can sort the players by score.
	for player in ivalues(data.players) do
		if firstScreen == nil then
			firstScreen = player.screenName
		end

		if player.screenName ~= firstScreen then
			updatedData.aux.allInSameScreen = false
		end

		if player.screenName == "ScreenGameplay" then
			updatedData.aux.anyInGameplay = true
		end

		if not player.ready then
			updatedData.aux.allPlayersReady = false
		end

		for screen in ivalues(scoreScreens) do
			if player.screenName == screen then
				updatedData.players[#updatedData.players+1] = player
				break
			end
		end
	end

	-- Sort the players by score.
	-- TODO(teejusb): Determine how to do toggle between score and exScore.
	table.sort(updatedData.players, function(a, b)
		-- a.exScore or b.exScore can be nil, so we need to handle that.
		if a.exScore == nil then
			return false
		end
		if b.exScore == nil then
			return true
		end
		return a.exScore > b.exScore
	end)

	-- Then add all the other players in other screens below.
	for player in ivalues(data.players) do
		if firstScreen == nil then
			firstScreen = player.screenName
		end

		if player.screenName ~= firstScreen then
			updatedData.aux.allInSameScreen = false
		end

		if player.screenName == "ScreenGameplay" then
			updatedData.aux.anyInGameplay = true
		end

		if not player.ready then
			updatedData.aux.allPlayersReady = false
		end

		local inScoreScreen = false
		for screen in ivalues(scoreScreens) do
			if player.screenName == screen then
				inScoreScreen = true
				break
			end
		end

		if not inScoreScreen then
			updatedData.players[#updatedData.players+1] = player
		end
	end

	return updatedData
end

DisplayLobbyState = function(data, actor)
	-- NOTE(teejusb): Keep in mind that SCREENMAN:GetTopScreen() might return nil since we might be
	-- transitioning screens when we receive any messages from the server.
	          local screen = SCREENMAN:GetTopScreen()
	          local screenName = screen and screen:GetName() or "NoScreen"
						startHoldTime = { ["P1"] = 0, ["P2"] = 0 }
						lastDisconnectCountdown = nil

	local updatedData = OrderPlayers(data, screenName)

	local lines = {}

	if isWaiting then
		local readyToUnlock = false
		if screenName == "ScreenGameplay" then
			-- Gameplay requires everyone to be in gameplay and manually ready-up.
			readyToUnlock = updatedData.aux.allInSameScreen and updatedData.aux.allPlayersReady
		elseif screenName == "ScreenEvaluationStage" then
			-- Evaluation should only be blocked while someone is still playing.
			readyToUnlock = not updatedData.aux.anyInGameplay
		elseif autoReadyScreens[screenName] then
			-- Other auto-ready screens require everyone to arrive at the same screen.
			readyToUnlock = updatedData.aux.allInSameScreen
		else
			readyToUnlock = updatedData.aux.allPlayersReady
		end

		if screenName == "ScreenSelectMusic" and data.songInfo ~= nil then
			-- If we're navigating back to screen select music (say from options),
			-- then don't lock input as we will have already synced before.
			-- In this case a song will have been selected already.
			-- However, if someone is still in EvaluationStage, we are transitioning
			-- eval -> music and should keep input locked until everyone arrives.
			local anyInEval = false
			for _, player in ipairs(updatedData.players) do
				if player.screenName == "ScreenEvaluationStage" then
					anyInEval = true
					break
				end
			end
			if not anyInEval then
				readyToUnlock = true
			end
			end

			if readyToUnlock then
			isWaiting = false
			-- Lift the lock.
			-- SCREENMAN:GetTopScreen():RemoveInputCallback(InputHandler)

			-- The below does work, but it's currently possible that other screens are resetting this early.
			for player in ivalues(PlayerNumber) do
				SCREENMAN:set_input_redirected(player, false)
			end

			if screenName == "ScreenGameplay" then
				local topScreen = SCREENMAN:GetTopScreen()
				if topScreen then topScreen:PauseGame(false) end
			end
		else
			lines[#lines+1] = "Waiting for players to sync screens...\n"
			if screenName == "ScreenGameplay" then
				lines[#lines+1] = "Press &START; to ready up!\n"
			end
		end
	end

		if screenName == "ScreenGameplay" and data.phase == "playing" then
			isWaiting = false
			for player in ivalues(PlayerNumber) do
				SCREENMAN:set_input_redirected(player, false)
			end
			local topScreen = SCREENMAN:GetTopScreen()
			if topScreen then topScreen:PauseGame(false) end
		end
	for i, player in ipairs(updatedData.players) do
		local displayedScreen = player.screenName ~= "NoScreen" and player.screenName:gsub("Screen", "") or "Transitioning"
		local readyText = ""
		if screenName == "ScreenGameplay" and not updatedData.aux.allPlayersReady then
			readyText =" ["..(player.ready and "✔" or "❌").."]"
		end

		-- Only display the screen name of the players that are on a different
		-- screen than we are.
		local playerAndScreen = i..'. '..player.profileName..readyText
		if screenName ~= player.screenName then
			playerAndScreen = playerAndScreen.." - in "..displayedScreen
		end

		lines[#lines+1] = playerAndScreen
		for scoreScreen in ivalues(scoreScreens) do
			if player.screenName == scoreScreen then
				-- Display the score and EX score.
				local score = (player.score ~= nil and player.score) or 0
				local exScore = (player.exScore ~= nil and player.exScore) or 0

				local scoreStr = string.format("%.2f", score).."%"
				local exScoreStr = string.format("%.2f", exScore).."%"

				lines[#lines+1] = "    "..scoreStr.." - "..exScoreStr.." EX"
				break
			end
		end

		-- Add a new line between players.
		lines[#lines+1] = ""
	end

	if data.songInfo ~= nil then
		local songKey = OnlineSongKey(data)
		if (data.phase == "lobby_ready" or data.phase == "config") and songKey ~= "" and songKey ~= lastOnlineOptionsSongKey then
			if ApplyOnlineSongSelection(data.songInfo) then
				lastOnlineOptionsSongKey = songKey
				if data.phase == "lobby_ready" then
					ITGOnline:SetReady("lobby_ready", true)
				end
				TransitionToOnlineOptions()
			end
		end

		if not songSelected then
			local topScreen = SCREENMAN:GetTopScreen()
			if topScreen and topScreen:GetName() == "ScreenSelectMusic" then
				local song = SONGMAN:FindSong(data.songInfo.songPath)
				local wheel = topScreen:GetMusicWheel()
				if not song and data.songInfo.songPath:split("/")[2] then
					song = SONGMAN:FindSong(data.songInfo.songPath:split("/")[2])
				end
				if song and wheel then
					wheel:SelectSong(song)
					wheel:Move(1)
					wheel:Move(-1)
					wheel:Move(0)
				end
			end
		else
      -- Only display the song in ScreenSelectMusic so that players know
      -- which songs they may need to navigate to.
      if screenName == "ScreenSelectMusic" then
        -- Split the song path into pack and song name for easier reading.
        -- It looks like "<pack>/<song>" so we can just split on the first "/"
        local songPathParts = data.songInfo.songPath:split("/")
        local pack = songPathParts[1] or "Unknown"
        local song = songPathParts[2] or "Unknown"

        -- Sometimes the pack or song can get quite long, so add ... if it's too long.
        local maxLength = 30
        if #pack > maxLength then
          pack = string.sub(pack, 1, maxLength) .. "..."
        end
        if #song > maxLength then
          song = string.sub(song, 1, maxLength) .. "..."
        end

        lines[#lines+1] = "Pack: "..pack
        lines[#lines+1] = "Song: "..song
      end
		end
	end

	-- This gets cleared out by the server when every player has arrived at the song selection screen.
	songSelected = (data.songInfo ~= nil)

			if data.phase == "starting" and data.roomId and lastOnlineGameplayRoomId ~= data.roomId then
				if ApplyOnlineSongSelection(data.songInfo) then
					lines[#lines+1] = OnlineStartCountdownText() or "Starting song..."
					pendingOnlineStartRoomId = data.roomId
					lastOnlineGameplayRoomId = data.roomId
					UnlockOnlineInput()
					TransitionToOnlineGameplay()
				end
			elseif data.phase == "playing" and data.roomId and lastOnlineGameplayRoomId ~= data.roomId then
				if ApplyOnlineSongSelection(data.songInfo) then
				pendingOnlineStartRoomId = nil
				lastOnlineGameplayRoomId = data.roomId
				UnlockOnlineInput()
				TransitionToOnlineGameplay()
		end
	end

	actor:GetChild("Display"):playcommand("UpdateText", {text=table.concat(lines, "\n")})
end

local HandleResponse = function(response, actor)
	local event = response.event
	local data = response.data

	if event == "lobbyState" then
		actor.inLobby = true
		DisplayLobbyState(data, actor)
		MESSAGEMAN:Broadcast("OnlineLobbyState", data or {})
	elseif event == "lobbySearched" then
		MESSAGEMAN:Broadcast("LobbySearched", {
			lobbies = data and data.lobbies or {}
		})
	elseif event == "lobbyLeft" then
		actor.inLobby = false
		MESSAGEMAN:Broadcast("OnlineLobbyLeft", data or {})
	elseif event == "clientDisconnected" then
		actor.inLobby = false
		MESSAGEMAN:Broadcast("OnlineClientDisconnected", data or {})
	elseif event == "responseStatus" then
		MESSAGEMAN:Broadcast("OnlineResponseStatus", data or {})
	end
end

-- Only allow one instance of the online handler at a time.
-- Things can get a bit convoluted if we have many handlers trying to manage
-- multiple connections.
local onlineHandler = nil
local onlineHandlerInstance = nil
local onlineHandlerShuttingDown = false

GetOnlineHandlerInstance = function()
	return onlineHandlerInstance
end

CreateOnlineHandler = function() 
  if onlineHandler == nil then
    onlineHandler = Def.ActorFrame{
      Name="OnlineWebsocketHandler",
      InitCommand=function(self)
				onlineHandlerInstance = self
				onlineHandlerShuttingDown = false
	        self.socket = nil
	        self.connected = false
					self.inLobby = false
					self.errorMsg = nil
					self.reconnectDelay = 1
					self.deadmanTimeoutSeconds = 75
	      end,
				OnCommand=function(self)
					self:sleep(1):queuecommand("RealtimeDeadman")
				end,
			OffCommand=function(self)
				onlineHandlerShuttingDown = true
				ITGOnline:Disconnect()
				self.socket = nil
				self.connected = false
				self.inLobby = false
				self.errorMsg = nil
				local display = self:GetChild("Display")
				if display then
					display:GetChild("Text"):settext("")
				end
					if onlineHandlerInstance == self then
						onlineHandlerInstance = nil
					end
					lastSongPreviewSentAt = 0
					lastSongPreviewKey = ""
					lastOnlineOptionsSongKey = ""
					lastOnlineGameplayRoomId = nil
					pendingOnlineStartRoomId = nil
					pendingConfigReady = false
					startHoldTime = { ["P1"] = 0, ["P2"] = 0 }
					lastDisconnectCountdown = nil
					self.joinLobbyBusy = false
					self.createLobbyBusy = false
					self.startRoomBusy = false
					self.invitePlayerBusy = false
					self.joinPlayerBusy = false
					self.privateJoinAnswerBusy = false
					self.searchLobbyBusy = false
					self.leaveLobbyBusy = false
				end,
      ConnectOnlineMessageCommand=function(self)
        if self.socket == nil or self.errorMsg ~= nil then
					onlineHandlerShuttingDown = false
					self.errorMsg = nil
					ITGOnline:Connect({
							open=function()
								if onlineHandlerShuttingDown then return end
								self.socket = ITGOnline.socket
								self.connected = true
								self.reconnectDelay = 1
								self.inLobby = ITGOnline.currentRoomId ~= nil
								self.errorMsg = nil
									self:GetChild("Display"):visible(false)
								if ITGOnline.Sync then
									ITGOnline:Sync(function(ok, decoded)
										if ok and decoded and decoded.current_room then
											self.inLobby = true
											ITGOnline:Heartbeat("in_room")
										else
											RestoreCurrentRoom(self)
										end
									end)
								else
									RestoreCurrentRoom(self)
								end
						end,
						error=function(message)
							if onlineHandlerShuttingDown then return end
							self.inLobby = false
							self.connected = false
							self.errorMsg = message or "Connection failed"
							self:GetChild("Display"):GetChild("Text"):settext("")
							self:GetChild("Display"):visible(false)
						end,
							close=function()
								if onlineHandlerShuttingDown then return end
								self.connected = false
								self.socket = nil
								self:GetChild("Display"):GetChild("Text"):settext("")
								self:GetChild("Display"):visible(false)
								if not ITGOnline.disconnecting then
									self:stoptweening()
									self:sleep(self.reconnectDelay or 1):queuecommand("ReconnectOnline")
									self.reconnectDelay = math.min(30, (self.reconnectDelay or 1) * 2)
								end
							end,
						})
	        end
	      end,
				ReconnectOnlineCommand=function(self)
					if onlineHandlerShuttingDown or ITGOnline.disconnecting or self.connected or self.socket ~= nil then
						return
					end
					MESSAGEMAN:Broadcast("ConnectOnline")
				end,
				RealtimeDeadmanCommand=function(self)
					if onlineHandlerShuttingDown then return end

					if self.connected and self.socket ~= nil and ITGOnline and ITGOnline.lastRealtimeMessageAt then
						local idle = GetTimeSinceStart() - ITGOnline.lastRealtimeMessageAt
						if idle > (self.deadmanTimeoutSeconds or 75) then
							self.connected = false
							if ITGOnline.socket then
								ITGOnline.socket:Close()
							end
							self.socket = nil
							MESSAGEMAN:Broadcast("OnlineResponseStatus", {
								event="websocket",
								success=false,
								message="Realtime connection timed out. Reconnecting..."
							})
							self:queuecommand("ReconnectOnline")
						end
					end

					self:sleep(1):queuecommand("RealtimeDeadman")
				end,
      ScreenChangedMessageCommand=function(self)
        if self.connected and self.socket ~= nil then
					if not self.inLobby then
						return
					end

          local screen = SCREENMAN:GetTopScreen()
          local screenName = screen and screen:GetName() or "NoScreen"

          if knownDisconnectScreens[screenName] then
            MESSAGEMAN:Broadcast("DisconnectOnline", {leaveRoom=true})
            return
          end

	          if screenName == "ScreenSelectMusic" then
	            UnlockOnlineInput()
		            if screen then screen:AddInputCallback(SelectMusicInputHandler) end
	          end

          -- Lock input while syncing arrival on key screens.
          if syncLockScreens[screenName] then
            isWaiting = true

            -- The below does work, but it's currently possible that other screens are resetting this early.
            for player in ivalues(PlayerNumber) do
              SCREENMAN:set_input_redirected(player, true)
            end
          end

		if autoReadyScreens[screenName] then
			for player in ivalues(GAMESTATE:GetEnabledPlayers()) do
				local pn = ToEnumShortString(player)
				readyState[pn] = true
			end
		end

          if screenName == "ScreenGameplay" or screenName == "ScreenGameplayShared" then
				for player in ivalues(GAMESTATE:GetEnabledPlayers()) do
					local pn = ToEnumShortString(player)
					readyState[pn] = false
				end
	            -- Input callbacks get cleared out when we transition screens, so we don't need to worry about explicitly removing it.
	            if screen then screen:AddInputCallback(InputHandler) end
	            if ITGOnline.currentRoom and ITGOnline.currentRoom.phase == "playing" then
	              UnlockOnlineInput()
	              if screen then screen:PauseGame(false) end
	            else
	              if screen then screen:PauseGame(true) end
	            end
			elseif isWaiting then
				if screen then screen:AddInputCallback(InputHandler) end

		end

						local status = (screenName == "ScreenGameplay" and ITGOnline.currentRoom and ITGOnline.currentRoom.phase == "playing") and "playing" or "in_room"
						ITGOnline:Heartbeat(status)
						if screenName == "ScreenEvaluationStage" and ITGOnline and ITGOnline.SendScore then
							ITGOnline:SendScore(true)
						end
							if screenName == "ScreenSelectMusic" and ITGOnline.currentSongPayload then
								ITGOnline:SetReady("lobby_ready", true)
							end
          MESSAGEMAN:Broadcast("UpdateMachineState")
        end
      end,
      PlayerJoinedMessageCommand=function(self)
				if self.connected and self.socket ~= nil and self.inLobby then	
          ITGOnline:Heartbeat("in_room")
        end
      end,
      PlayerUnjoinedMessageCommand=function(self)
				if self.connected and self.socket ~= nil and self.inLobby then	
          ITGOnline:Heartbeat("in_room")
        end
      end,
		UpdateMachineStateMessageCommand=function(self)
				if self.connected and self.socket ~= nil and self.inLobby then	
          ITGOnline:Heartbeat("in_room")
        end
      end,
	      OnlineConfigReadyMessageCommand=function(self)
					if not (self.connected and self.socket ~= nil and ITGOnline.currentRoomId) then
						return
					end

					self.inLobby = true
					if ITGOnline.MarkConfigReady then
						ITGOnline:MarkConfigReady()
						return
					end

					pendingConfigReady = true
					self:queuecommand("RetryOnlineConfigReady")
	      end,
	      RetryOnlineConfigReadyCommand=function(self)
					if not pendingConfigReady or not ITGOnline.currentRoomId then
						return
					end

					ITGOnline:FetchRoom(ITGOnline.currentRoomId, function(ok, decoded)
						if not ok or not decoded or not decoded.room then
							self:sleep(1):queuecommand("RetryOnlineConfigReady")
							return
						end

						local phase = decoded.room.phase
						if not decoded.room.selected_song then
							ITGOnline:SelectSong(function(selectOk, selectDecoded, selectResponse)
								if selectOk then
									self:sleep(0.25):queuecommand("RetryOnlineConfigReady")
								else
									pendingConfigReady = false
									MESSAGEMAN:Broadcast("OnlineResponseStatus", {
										event="selectSong",
										success=false,
										message=(selectDecoded and selectDecoded.message) or (selectResponse and selectResponse.errorMessage) or "Song selection failed."
									})
								end
							end)
							return
						end

						if phase == "config" or phase == "starting" or phase == "playing" then
							ITGOnline:SetReady("config_ready", true, function()
								pendingConfigReady = false
								ITGOnline:FetchRoom(ITGOnline.currentRoomId, function(fetchOk, fetchDecoded)
									if fetchOk and fetchDecoded and fetchDecoded.room then
									MESSAGEMAN:Broadcast("OnlineLobbyState", ITGOnline:LobbyStatePayload(fetchDecoded.room))
									end
								end)
							end)
						elseif phase == "lobby" or phase == "lobby_ready" then
							ITGOnline:SetReady("lobby_ready", true, function()
								self:sleep(0.5):queuecommand("RetryOnlineConfigReady")
							end)
						else
							pendingConfigReady = false
						end
					end)
	      end,
		      ExCountsChangedMessageCommand=function(self)
						if self.connected and self.socket ~= nil and self.inLobby and ITGOnline and ITGOnline.SendScore then
		          ITGOnline:SendScore()
		        end
	      end,
				OnlineSessionExpiredMessageCommand=function(self)
					self.connected = false
					self.inLobby = false
					self.socket = nil
					isWaiting = false
					for player in ivalues(PlayerNumber) do
						SCREENMAN:set_input_redirected(player, false)
					end
					MESSAGEMAN:Broadcast("OnlineResponseStatus", {
						event="sessionExpired",
						success=false,
						message="Online session expired. Please reconnect."
					})
				end,
				OnlineLobbyStateMessageCommand=function(self, params)
					if self.connected and params and params.roomId then
						self.inLobby = true
						DisplayLobbyState(params, self)
					end
				end,
				OnlineLobbyLeftMessageCommand=function(self)
					self.inLobby = false
				end,
			      SongSelectedMessageCommand=function(self)
						if self.connected and self.socket ~= nil and ITGOnline.currentRoomId then
							self.inLobby = true
							if ITGOnline.SelectSongAndMarkLobbyReady then
								ITGOnline:SelectSongAndMarkLobbyReady()
								return
							end

		          ITGOnline:SelectSong(function(ok, decoded, response)
								if ok then
									ITGOnline:SetReady("lobby_ready", true)
								ITGOnline:FetchRoom(ITGOnline.currentRoomId, function(fetchOk, fetchDecoded)
									if fetchOk and fetchDecoded and fetchDecoded.room then
										local payload = ITGOnline:LobbyStatePayload(fetchDecoded.room)
										DisplayLobbyState(payload, self)
										MESSAGEMAN:Broadcast("OnlineLobbyState", payload)
									end
								end)
							else
								MESSAGEMAN:Broadcast("OnlineResponseStatus", {
									event="selectSong",
									success=false,
									message=(decoded and decoded.message) or (response and response.errorMessage) or "Song selection failed."
								})
							end
						end)
	        end
	      end,
		      CurrentSongChangedMessageCommand=function(self)
						if self.connected and self.socket ~= nil and ITGOnline.currentRoomId and ITGOnline.currentRoom and ITGOnline.user then
						local manager = ITGOnline.currentRoom.manager
						if not manager or tonumber(manager.id) ~= tonumber(ITGOnline.user.id) then
							return
						end

						local song = GAMESTATE:GetCurrentSong()
						if not song then return end

						local now = GetTimeSinceStart()
						local key = song:GetSongDir() or song:GetDisplayFullTitle() or ""
						if key == lastSongPreviewKey and now - lastSongPreviewSentAt < 0.75 then
							return
						end

						lastSongPreviewKey = key
						lastSongPreviewSentAt = now
						ITGOnline:PreviewSong()
					end
	      end,
		      JoinLobbyMessageCommand=function(self, params)
		        if self.connected and self.socket ~= nil then
						if self.joinLobbyBusy then return end
						self.joinLobbyBusy = true
						self.inLobby = false
		          ITGOnline:RequestJoinRoom(params.code, function(ok, decoded, response)
								self.joinLobbyBusy = false
								if ok then
								MESSAGEMAN:Broadcast("OnlineResponseStatus", {
									event="joinLobby",
									success=true,
									message="Join request sent. Waiting for the room manager."
								})
								elseif decoded and (decoded.error_code == "already_in_room" or decoded.message == "You are already in this room.") and params and params.code then
								ITGOnline:FetchRoom(params.code, function(fetchOk, fetchDecoded, fetchResponse)
									if fetchOk and fetchDecoded and fetchDecoded.room then
										self.inLobby = true
										DisplayLobbyState(ITGOnline:LobbyStatePayload(fetchDecoded.room), self)
										MESSAGEMAN:Broadcast("OnlineLobbyState", ITGOnline:LobbyStatePayload(fetchDecoded.room))
									else
										MESSAGEMAN:Broadcast("OnlineResponseStatus", {
											event="joinLobby",
											success=false,
											message=(fetchDecoded and fetchDecoded.message) or (fetchResponse and fetchResponse.errorMessage) or "Could not restore lobby state."
										})
									end
								end)
							else
								MESSAGEMAN:Broadcast("OnlineResponseStatus", {
									event="joinLobby",
									success=false,
									message=(decoded and decoded.message) or (response and response.errorMessage) or "Join lobby failed."
								})
							end
						end)
	        end
	      end,
		      CreateLobbyMessageCommand=function(self, params)
		        if self.connected and self.socket ~= nil then
						if self.createLobbyBusy then return end
						self.createLobbyBusy = true
						self.inLobby = false
		          ITGOnline:CreateRoom(function(ok, decoded, response)
								self.createLobbyBusy = false
								if ok and decoded and decoded.room then
								self.inLobby = true
								DisplayLobbyState(ITGOnline:LobbyStatePayload(decoded.room), self)
								MESSAGEMAN:Broadcast("OnlineLobbyState", ITGOnline:LobbyStatePayload(decoded.room))
								elseif decoded and (decoded.error_code == "already_in_open_room" or decoded.message == "User is already in an open room.") then
								RestoreCurrentRoom(self, function(restored)
									if not restored then
										MESSAGEMAN:Broadcast("OnlineResponseStatus", {
											event="createLobby",
											success=false,
											message="Create lobby failed: User is already in an open room."
										})
									end
								end)
							else
								MESSAGEMAN:Broadcast("OnlineResponseStatus", {
									event="createLobby",
									success=false,
									message=(decoded and decoded.message) or (response and response.errorMessage) or "Create lobby failed."
								})
							end
						end, params and params.visibility or "public")
	        end
	      end,
		      StartOnlineRoomMessageCommand=function(self)
					if self.connected and self.socket ~= nil and self.inLobby then
						if self.startRoomBusy then return end
						self.startRoomBusy = true
	          ITGOnline:StartRoom(function(ok, decoded, response)
							self.startRoomBusy = false
							if ok and decoded and decoded.room then
							local payload = ITGOnline:LobbyStatePayload(decoded.room)
							DisplayLobbyState(payload, self)
							MESSAGEMAN:Broadcast("OnlineLobbyState", payload)
						else
							MESSAGEMAN:Broadcast("OnlineResponseStatus", {
								event="startRoom",
								success=false,
								message=(decoded and decoded.message) or (response and response.errorMessage) or "Start failed."
							})
						end
					end)
        end
      end,
	      InviteOnlinePlayerMessageCommand=function(self, params)
	        if self.connected and self.socket ~= nil and params and params.user_id then
						if self.invitePlayerBusy then return end
						self.invitePlayerBusy = true
						self.inLobby = false
						local visibility = params.visibility or "private"
	          ITGOnline:InviteUserToNewRoom(params.user_id, visibility, function(ok, decoded, response)
							self.invitePlayerBusy = false
							if ok then
							self.inLobby = true
							if ITGOnline.currentRoom then
								DisplayLobbyState(ITGOnline:LobbyStatePayload(ITGOnline.currentRoom), self)
								MESSAGEMAN:Broadcast("OnlineLobbyState", ITGOnline:LobbyStatePayload(ITGOnline.currentRoom))
							end
							MESSAGEMAN:Broadcast("OnlineResponseStatus", {
								event="invitePlayer",
								success=true,
								message="Invitation sent."
							})
						else
							MESSAGEMAN:Broadcast("OnlineResponseStatus", {
								event="invitePlayer",
								success=false,
								message=(decoded and decoded.message) or (response and response.errorMessage) or "Invitation failed."
							})
						end
					end)
        end
      end,
	      JoinOnlinePlayerRoomMessageCommand=function(self, params)
	        if self.connected and self.socket ~= nil and params and params.user_id then
						if self.joinPlayerBusy then return end
						self.joinPlayerBusy = true
						self.inLobby = false
	          ITGOnline:RequestJoinUserRoom(params.user_id, function(ok, decoded, response)
							self.joinPlayerBusy = false
							if ok and decoded and decoded.room then
							self.inLobby = true
							DisplayLobbyState(ITGOnline:LobbyStatePayload(decoded.room), self)
							MESSAGEMAN:Broadcast("OnlineLobbyState", ITGOnline:LobbyStatePayload(decoded.room))
						elseif ok then
							MESSAGEMAN:Broadcast("OnlineResponseStatus", {
								event="joinLobby",
								success=true,
								message="Private join request sent. Waiting for approval."
							})
						else
							MESSAGEMAN:Broadcast("OnlineResponseStatus", {
								event="joinLobby",
								success=false,
								message=(decoded and decoded.message) or (response and response.errorMessage) or "Join request failed."
							})
						end
					end)
        end
      end,
	      AnswerPrivateJoinRequestMessageCommand=function(self, params)
	        if self.connected and self.socket ~= nil and params and params.join_request_id then
						if self.privateJoinAnswerBusy then return end
						self.privateJoinAnswerBusy = true
						if params.accept then
							ITGOnline:AcceptJoinRequest(params.join_request_id, function(ok, decoded, response)
								self.privateJoinAnswerBusy = false
								if ok and decoded and decoded.room then
								DisplayLobbyState(ITGOnline:LobbyStatePayload(decoded.room), self)
								MESSAGEMAN:Broadcast("OnlineLobbyState", ITGOnline:LobbyStatePayload(decoded.room))
							end
							MESSAGEMAN:Broadcast("OnlineResponseStatus", {
								event="privateJoinAnswer",
								success=ok and true or false,
								message=ok and "Join request accepted." or ((decoded and decoded.message) or (response and response.errorMessage) or "Could not answer join request.")
							})
						end)
						else
							ITGOnline:DeclineJoinRequest(params.join_request_id, params.reason or "", function(ok, decoded, response)
								self.privateJoinAnswerBusy = false
								MESSAGEMAN:Broadcast("OnlineResponseStatus", {
								event="privateJoinAnswer",
								success=ok and true or false,
								message=ok and "Join request declined." or ((decoded and decoded.message) or (response and response.errorMessage) or "Could not answer join request.")
							})
						end)
					end
        end
      end,
	      AnswerRoomInvitationMessageCommand=function(self, params)
	        if self.connected and self.socket ~= nil and params and params.invitation_id then
						if self.roomInvitationAnswerBusy then return end
						self.roomInvitationAnswerBusy = true
						if params.accept then
							ITGOnline:AcceptInvitation(params.invitation_id, function(ok, decoded, response)
								self.roomInvitationAnswerBusy = false
								if ok and decoded and decoded.room then
									DisplayLobbyState(ITGOnline:LobbyStatePayload(decoded.room), self)
									MESSAGEMAN:Broadcast("OnlineLobbyState", ITGOnline:LobbyStatePayload(decoded.room))
								end
								MESSAGEMAN:Broadcast("OnlineResponseStatus", {
									event="roomInvitationAnswer",
									success=ok and true or false,
									message=ok and "Invitation accepted." or ((decoded and decoded.message) or (response and response.errorMessage) or "Could not answer invitation.")
								})
							end)
						else
							ITGOnline:DeclineInvitation(params.invitation_id, function(ok, decoded, response)
								self.roomInvitationAnswerBusy = false
								MESSAGEMAN:Broadcast("OnlineResponseStatus", {
									event="roomInvitationAnswer",
									success=ok and true or false,
									message=ok and "Invitation declined." or ((decoded and decoded.message) or (response and response.errorMessage) or "Could not answer invitation.")
								})
							end)
						end
        end
      end,
				SearchLobbyMessageCommand=function(self)
					if self.connected and self.socket ~= nil then
						if self.searchLobbyBusy then return end
						self.searchLobbyBusy = true
						ITGOnline:FetchLobby(function(ok, decoded, response)
							self.searchLobbyBusy = false
							if ok then
							MESSAGEMAN:Broadcast("LobbySearched", ITGOnline:LobbySearchPayload(decoded))
						else
							MESSAGEMAN:Broadcast("OnlineResponseStatus", {
								event="searchLobby",
								success=false,
								message=(decoded and decoded.message) or (response and response.errorMessage) or "Lobby search failed."
							})
						end
					end)
				end
			end,
				LeaveLobbyMessageCommand=function(self)
					if self.connected and self.socket ~= nil then
						if self.leaveLobbyBusy then return end
						self.leaveLobbyBusy = true
						ITGOnline:LeaveRoom(function(ok, decoded, response)
							self.leaveLobbyBusy = false
							if ok then
							self.inLobby = false
							MESSAGEMAN:Broadcast("OnlineLobbyLeft", {left=true})
						else
							MESSAGEMAN:Broadcast("OnlineResponseStatus", {
								event="leaveLobby",
								success=false,
								message=(decoded and decoded.message) or (response and response.errorMessage) or "Leave lobby failed."
							})
						end
					end)
				end
			end,
	      DisconnectOnlineMessageCommand=function(self, params)
				local shouldLeaveRoom = params and params.leaveRoom and self.inLobby
				local finalize = function()
					onlineHandlerShuttingDown = true
					isWaiting = false
					ITGOnline:Disconnect()
					for player in ivalues(PlayerNumber) do
						SCREENMAN:set_input_redirected(player, false)
					end
					self.connected = false
					self.inLobby = false
					self.socket = nil
					self:GetChild("Display"):GetChild("Text"):settext("")
					self:GetChild("Display"):visible(false)
				end

				if shouldLeaveRoom then
					ITGOnline:LeaveRoom(function()
						finalize()
					end)
					return
				end

					finalize()
	      end,

	      Def.Actor{
	        Name="OnlineStartPollTimer",
	        PollCommand=function(self)
						local actor = self:GetParent()
						local roomId = pendingOnlineStartRoomId
						if not roomId or not (ITGOnline and ITGOnline.FetchRoom) then
							return
						end

						ITGOnline:FetchRoom(roomId, function(ok, decoded)
							if not ok or not decoded or not decoded.room then
								PollOnlineStart(actor, roomId)
								return
							end

							local payload = ITGOnline:LobbyStatePayload(decoded.room)
							DisplayLobbyState(payload, actor)
							MESSAGEMAN:Broadcast("OnlineLobbyState", payload)

							if decoded.room.phase == "starting" then
								PollOnlineStart(actor, roomId)
							end
						end)
	        end,
	      },

		      Def.ActorFrame{
		        Name="Display",
	        InitCommand=function(self)
	          self:visible(false)

					local width = 200
					local LEFT = width/2
					self:xy(LEFT, _screen.cy)
        end,
	        UpdateTextCommand=function(self, params)
						self:visible(false)
	          local screen = SCREENMAN:GetTopScreen()
          local screenName = screen and screen:GetName() or "NoScreen"

          local bg = self:GetChild("Background")
          local width = 200
          local height = SCREEN_HEIGHT

          -- Some generic constants for easy positioning.
          local LEFT = width/2
          local RIGHT = SCREEN_WIDTH - width/2
          local CENTER = _screen.cx

          -- If we're on a different screen, we'll just retain the last position.
          if screenName == "ScreenSelectMusic" then
            self:xy(LEFT, _screen.cy)
            bg:zoomto(width, height)
          elseif screenName == "ScreenEvaluationStage" or screenName == "ScreenGameplay" then
            local p1Joined = GAMESTATE:IsSideJoined("PlayerNumber_P1")
            local p2Joined = GAMESTATE:IsSideJoined("PlayerNumber_P2")

            if p1Joined and p2Joined then
              self:xy(CENTER, _screen.cy)
              bg:zoomto(width, height)
            elseif p1Joined then
              self:xy(RIGHT, _screen.cy)
              bg:zoomto(width, height)
            elseif p2Joined then
              self:xy(LEFT, _screen.cy)
              bg:zoomto(width, height)
            end
          end

          self:GetChild("Text"):playcommand("Resize", {width=width, height=height, text=params.text})
        end,

        Def.Quad{
          Name="Background",
          InitCommand=function(self)
            self:zoomto(SCREEN_WIDTH / 3, SCREEN_HEIGHT):diffuse(0, 0, 0, 0.5)
          end,
        },

        LoadFont("Common Normal").. {
          Name="Text",
          Text="",
          InitCommand=function(self)
            self:diffuse(Color.Yellow)
          end,
          ResizeCommand=function(self, params)
            self:settext(params.text)
            DiffuseEmojis(self)
            -- We don't want text to be cut off.
            -- Incrementally adjust the zoom while checking the width until it fits.
            -- Not the prettiest solution but it works.
            for zoomVal=1.0, 0.1, -0.05 do
              self:zoom(zoomVal)
              self:settext(params.text)
              if self:GetWidth() * zoomVal <= params.width then
                break
              end
            end
          end
        },
      },
    }
  end

  return onlineHandler
end
