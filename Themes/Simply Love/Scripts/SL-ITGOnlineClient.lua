-- -----------------------------------------------------------------------
-- ITG Online API client.
--
-- This bridges Simply Love's existing online-lobby UI to the Laravel server.
-- Save/ITGOnline.ini stores connection settings only; the password is kept in
-- native secure storage when available, otherwise only in memory for the
-- current session. Access tokens can be persisted only when the current local
-- profile explicitly enables it; native secure storage is preferred, with a
-- profile-scoped fallback in ProfileDir/ITGOnline.ini.

ITGOnline = ITGOnline or {}

ITGOnline.configPath = "/Save/ITGOnline.ini"
ITGOnline.debugConfigPath = "/Save/ITGOnlineDebug.ini"
ITGOnline.passwordService = "ITG Online Password"
ITGOnline.accessTokenService = "ITG Online Access Token"
ITGOnline.profileAccessTokenCache = ITGOnline.profileAccessTokenCache or {}
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
ITGOnline.currentRoomBlockedReason = ITGOnline.currentRoomBlockedReason or ""
ITGOnline.currentRoomBlockedOpenCount = ITGOnline.currentRoomBlockedOpenCount or nil
ITGOnline.currentRoomBlockedLastNoticeKey = ITGOnline.currentRoomBlockedLastNoticeKey or ""
ITGOnline.currentSongPayload = ITGOnline.currentSongPayload or nil
ITGOnline.currentRoomRoundKey = ITGOnline.currentRoomRoundKey or ""
ITGOnline.lastResultSongPayload = ITGOnline.lastResultSongPayload or nil
ITGOnline.activeGameplaySongPayload = ITGOnline.activeGameplaySongPayload or nil
ITGOnline.activeGameplayRoundKey = ITGOnline.activeGameplayRoundKey or ""
ITGOnline.pendingJoinRoomId = ITGOnline.pendingJoinRoomId or nil
ITGOnline.pendingJoinRequestId = ITGOnline.pendingJoinRequestId or nil
ITGOnline.lastScoreSentAt = ITGOnline.lastScoreSentAt or 0
ITGOnline.scheduledStartLocalTime = ITGOnline.scheduledStartLocalTime or nil
ITGOnline.sessionExpired = ITGOnline.sessionExpired or false
ITGOnline.authSessionInvalidated = ITGOnline.authSessionInvalidated or false
ITGOnline.authSessionInvalidatedReason = ITGOnline.authSessionInvalidatedReason or ""
ITGOnline.disconnecting = ITGOnline.disconnecting or false
ITGOnline.lastEventCursor = ITGOnline.lastEventCursor or 0
ITGOnline.fetchRoomInFlightByRoomId = ITGOnline.fetchRoomInFlightByRoomId or {}
ITGOnline.fetchRoomStableResultsLastAtByRoomId = ITGOnline.fetchRoomStableResultsLastAtByRoomId or {}
ITGOnline.fetchRoomStableResultsCoalesceSeconds = ITGOnline.fetchRoomStableResultsCoalesceSeconds or 0.75
ITGOnline.lastRealtimeMessageAt = ITGOnline.lastRealtimeMessageAt or GetTimeSinceStart()
ITGOnline.lastRealtimeClientPingAt = ITGOnline.lastRealtimeClientPingAt or 0
ITGOnline.lastRealtimeHealthState = ITGOnline.lastRealtimeHealthState or ""
ITGOnline.lastRealtimeStateReconcileAt = ITGOnline.lastRealtimeStateReconcileAt or 0
ITGOnline.realtimeStaleSeconds = ITGOnline.realtimeStaleSeconds or 45.0
ITGOnline.realtimeGhostSeconds = ITGOnline.realtimeGhostSeconds or 75.0
ITGOnline.criticalRoomActionResyncMinIntervalSeconds = ITGOnline.criticalRoomActionResyncMinIntervalSeconds or 0.75
ITGOnline.lastCriticalRoomActionResyncAt = ITGOnline.lastCriticalRoomActionResyncAt or 0
ITGOnline.lastSyncRequestedAt = ITGOnline.lastSyncRequestedAt or 0
ITGOnline.lastCurrentRoomWatchdogAt = ITGOnline.lastCurrentRoomWatchdogAt or 0
ITGOnline.currentRoomWatchdogIntervalSeconds = ITGOnline.currentRoomWatchdogIntervalSeconds or 2.0
ITGOnline.currentRoomWatchdogRealtimeIntervalSeconds = ITGOnline.currentRoomWatchdogRealtimeIntervalSeconds or 4.0
ITGOnline.realtimeReconnectNextAttemptAt = ITGOnline.realtimeReconnectNextAttemptAt or 0
ITGOnline.realtimeReconnectAttempt = ITGOnline.realtimeReconnectAttempt or 0
ITGOnline.realtimeReconnectBaseDelaySeconds = ITGOnline.realtimeReconnectBaseDelaySeconds or 1.0
ITGOnline.realtimeReconnectMaxDelaySeconds = ITGOnline.realtimeReconnectMaxDelaySeconds or 10.0
ITGOnline.screenGeneration = ITGOnline.screenGeneration or 0
ITGOnline.currentScreenName = ITGOnline.currentScreenName or "NoScreen"
ITGOnline.authRefreshInFlight = ITGOnline.authRefreshInFlight or false
ITGOnline.authRefreshCallbacks = ITGOnline.authRefreshCallbacks or {}
ITGOnline.authRefreshFailureCount = ITGOnline.authRefreshFailureCount or 0
ITGOnline.maxAuthRefreshFailures = ITGOnline.maxAuthRefreshFailures or 3
ITGOnline.authRefreshNextAttemptAt = ITGOnline.authRefreshNextAttemptAt or 0
ITGOnline.authRefreshMaxBackoffSeconds = ITGOnline.authRefreshMaxBackoffSeconds or 30
ITGOnline.lastFinalScoreKey = ITGOnline.lastFinalScoreKey or ""
ITGOnline.lastFinalScoreInFlightKey = ITGOnline.lastFinalScoreInFlightKey or ""
ITGOnline.lastScorePositionKey = ITGOnline.lastScorePositionKey or nil
ITGOnline.lastScoreSongPosition = ITGOnline.lastScoreSongPosition or 0
ITGOnline.lastAcceptedScoreSongPosition = ITGOnline.lastAcceptedScoreSongPosition or 0
ITGOnline.lastAcceptedScoreFingerprint = ITGOnline.lastAcceptedScoreFingerprint or nil
ITGOnline.scoreInFlightFingerprint = ITGOnline.scoreInFlightFingerprint or nil
ITGOnline.lastDisplayedScoreSnapshot = ITGOnline.lastDisplayedScoreSnapshot or nil
ITGOnline.lastDisplayedScoreSnapshotAt = ITGOnline.lastDisplayedScoreSnapshotAt or 0
ITGOnline.lastScoreJudgmentsByRoundKey = ITGOnline.lastScoreJudgmentsByRoundKey or {}
ITGOnline.pendingLiveScoreSnapshot = ITGOnline.pendingLiveScoreSnapshot or nil
ITGOnline.pendingLiveScoreRoundKey = ITGOnline.pendingLiveScoreRoundKey or ""
ITGOnline.liveScoreInFlight = ITGOnline.liveScoreInFlight or false
ITGOnline.liveScoreNextAttemptAt = ITGOnline.liveScoreNextAttemptAt or 0
ITGOnline.liveScoreMinIntervalSeconds = ITGOnline.liveScoreMinIntervalSeconds or 0.50
ITGOnline.liveScoreEndgameWindowSeconds = ITGOnline.liveScoreEndgameWindowSeconds or 6
ITGOnline.liveScoreEndgameIntervalSeconds = ITGOnline.liveScoreEndgameIntervalSeconds or 0.50
ITGOnline.gameplayLobbyRefreshMinIntervalSeconds = ITGOnline.gameplayLobbyRefreshMinIntervalSeconds or 5.0
ITGOnline.lastGameplayLobbyRefreshAt = ITGOnline.lastGameplayLobbyRefreshAt or 0
ITGOnline.lastLeaderboardVersionByRoomId = ITGOnline.lastLeaderboardVersionByRoomId or {}
ITGOnline.lastLeaderboardRealtimeAt = ITGOnline.lastLeaderboardRealtimeAt or 0
ITGOnline.lastPlayStateVersionByRoomId = ITGOnline.lastPlayStateVersionByRoomId or {}
ITGOnline.lastRoomVersionByRoomId = ITGOnline.lastRoomVersionByRoomId or {}
ITGOnline.currentRoomPlayStateByRoomId = ITGOnline.currentRoomPlayStateByRoomId or {}
ITGOnline.lastRoomEventIdByRoomId = ITGOnline.lastRoomEventIdByRoomId or {}
ITGOnline.promptedPendingJoinRequestIds = ITGOnline.promptedPendingJoinRequestIds or {}
ITGOnline.lastUnversionedPlayStateFetchAt = ITGOnline.lastUnversionedPlayStateFetchAt or 0
ITGOnline.lastRoomNotPlayingScoreRejectAt = ITGOnline.lastRoomNotPlayingScoreRejectAt or 0
ITGOnline.processedRealtimeEventIds = ITGOnline.processedRealtimeEventIds or {}
ITGOnline.processedRealtimeEventOrder = ITGOnline.processedRealtimeEventOrder or {}
ITGOnline.processedRealtimeEventLimit = ITGOnline.processedRealtimeEventLimit or 512
ITGOnline.deletedRoomIds = ITGOnline.deletedRoomIds or {}
ITGOnline.leavingRoomIds = ITGOnline.leavingRoomIds or {}
ITGOnline.ignoredRoomEventsUntil = ITGOnline.ignoredRoomEventsUntil or {}
ITGOnline.needsSyncAfterScreenCancel = ITGOnline.needsSyncAfterScreenCancel or false
ITGOnline.requestCancelGeneration = ITGOnline.requestCancelGeneration or 0
ITGOnline.songLoadedAckKey = ITGOnline.songLoadedAckKey or ""
ITGOnline.songLoadedInFlightKey = ITGOnline.songLoadedInFlightKey or ""
ITGOnline.songLoadedPendingCallbacks = ITGOnline.songLoadedPendingCallbacks or {}
ITGOnline.songAvailabilityInFlightKey = ITGOnline.songAvailabilityInFlightKey or ""
ITGOnline.songAvailabilityInFlightCallbacks = ITGOnline.songAvailabilityInFlightCallbacks or {}
ITGOnline.songAvailabilityReportedKey = ITGOnline.songAvailabilityReportedKey or ""
ITGOnline.songAvailabilitySuppressedUntil = ITGOnline.songAvailabilitySuppressedUntil or {}
ITGOnline.songAvailabilityFailureDedupSeconds = ITGOnline.songAvailabilityFailureDedupSeconds or 5
ITGOnline.songSelectionInFlightKey = ITGOnline.songSelectionInFlightKey or ""
ITGOnline.songSelectionInFlightCallbacks = ITGOnline.songSelectionInFlightCallbacks or {}
ITGOnline.songSelectionTransitionInFlight = ITGOnline.songSelectionTransitionInFlight or false
ITGOnline.songSelectionTransitionKind = ITGOnline.songSelectionTransitionKind or ""
ITGOnline.songSelectionTransitionRoomId = ITGOnline.songSelectionTransitionRoomId or nil
ITGOnline.songSelectionTransitionStartedAt = ITGOnline.songSelectionTransitionStartedAt or 0
ITGOnline.songSelectionTransitionTimeoutSeconds = ITGOnline.songSelectionTransitionTimeoutSeconds or 4.0
ITGOnline.songSelectionCancelledVersionByRoomId = ITGOnline.songSelectionCancelledVersionByRoomId or {}
ITGOnline.songSelectionCancelledAtByRoomId = ITGOnline.songSelectionCancelledAtByRoomId or {}
ITGOnline.songSelectionCancelGuardSeconds = ITGOnline.songSelectionCancelGuardSeconds or 1.5
ITGOnline.startScheduleAckKey = ITGOnline.startScheduleAckKey or ""
ITGOnline.startScheduleAckInFlightKey = ITGOnline.startScheduleAckInFlightKey or ""
ITGOnline.onlineGameplayEnteredInFlightKey = ITGOnline.onlineGameplayEnteredInFlightKey or ""
ITGOnline.managerAutoReadyInFlightKey = ITGOnline.managerAutoReadyInFlightKey or ""
ITGOnline.managerAutoReadyCompletedKey = ITGOnline.managerAutoReadyCompletedKey or ""
ITGOnline.readyRequestInFlight = ITGOnline.readyRequestInFlight or {}
ITGOnline.readyRequestLastResult = ITGOnline.readyRequestLastResult or {}
ITGOnline.readyRequestReplayWindowSeconds = ITGOnline.readyRequestReplayWindowSeconds or 1.0
ITGOnline.readyRequestBlockedRetrySeconds = ITGOnline.readyRequestBlockedRetrySeconds or 2.5
ITGOnline.readyRequestBlockedErrors = ITGOnline.readyRequestBlockedErrors or {}
ITGOnline.configReadyInFlight = ITGOnline.configReadyInFlight or false
ITGOnline.configReadyInFlightByKey = ITGOnline.configReadyInFlightByKey or {}
ITGOnline.pendingConfigReadyIntentKey = ITGOnline.pendingConfigReadyIntentKey or ""
ITGOnline.pendingConfigReadyIntentRoomId = ITGOnline.pendingConfigReadyIntentRoomId or nil
ITGOnline.pendingConfigReadyIntentAt = ITGOnline.pendingConfigReadyIntentAt or 0
ITGOnline.pendingConfigReadyIntentSource = ITGOnline.pendingConfigReadyIntentSource or ""
ITGOnline.pendingConfigReadyDispatchKey = ITGOnline.pendingConfigReadyDispatchKey or ""
ITGOnline.optimisticConfigReadyKey = ITGOnline.optimisticConfigReadyKey or ""
ITGOnline.optimisticConfigReadyAt = ITGOnline.optimisticConfigReadyAt or 0
ITGOnline.onlineOptionsReadyDeadlineKey = ITGOnline.onlineOptionsReadyDeadlineKey or ""
ITGOnline.onlineOptionsReadyDeadlineAt = ITGOnline.onlineOptionsReadyDeadlineAt or 0
ITGOnline.onlineOptionsReadyTimeoutInFlightKey = ITGOnline.onlineOptionsReadyTimeoutInFlightKey or ""
ITGOnline.onlineOptionsReadyExitSuppressedKey = ITGOnline.onlineOptionsReadyExitSuppressedKey or ""
ITGOnline.onlineOptionsReadyTimeoutSeconds = ITGOnline.onlineOptionsReadyTimeoutSeconds or 30
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
ITGOnline.lobbyRefreshReplayDelaySeconds = ITGOnline.lobbyRefreshReplayDelaySeconds or 0.20
ITGOnline.lobbyRefreshLastAppliedAt = ITGOnline.lobbyRefreshLastAppliedAt or 0
ITGOnline.roomUiLobbyRefreshGeneration = ITGOnline.roomUiLobbyRefreshGeneration or 0
ITGOnline.deferredLobbyRefreshReason = ITGOnline.deferredLobbyRefreshReason or ""
ITGOnline.deferredLobbyRefreshRoomUiGeneration = ITGOnline.deferredLobbyRefreshRoomUiGeneration or nil
ITGOnline.onlineGameplayEnteredKey = ITGOnline.onlineGameplayEnteredKey or ""
ITGOnline.onlineGameplayReturnedKey = ITGOnline.onlineGameplayReturnedKey or ""
ITGOnline.onlineGameplayReturnedInFlightKey = ITGOnline.onlineGameplayReturnedInFlightKey or ""
ITGOnline.onlineGameplayReturnedLocalRoomId = ITGOnline.onlineGameplayReturnedLocalRoomId or ""
ITGOnline.onlineGameplayReturnedLocalAt = ITGOnline.onlineGameplayReturnedLocalAt or 0
ITGOnline.onlineGameplayTerminalKey = ITGOnline.onlineGameplayTerminalKey or ""
ITGOnline.onlineGameplayTerminalInFlightKey = ITGOnline.onlineGameplayTerminalInFlightKey or ""
ITGOnline.onlineGameplayTerminalState = ITGOnline.onlineGameplayTerminalState or ""
ITGOnline.onlineGameplayFailedEarlyKey = ITGOnline.onlineGameplayFailedEarlyKey or ""
ITGOnline.onlineGameplayFailedEarlyInFlightKey = ITGOnline.onlineGameplayFailedEarlyInFlightKey or ""
ITGOnline.onlineGameplayEndedKey = ITGOnline.onlineGameplayEndedKey or ""
ITGOnline.onlineGameplayEvaluationMarkKey = ITGOnline.onlineGameplayEvaluationMarkKey or ""
ITGOnline.onlineGameplayEvaluationMarkInFlightKey = ITGOnline.onlineGameplayEvaluationMarkInFlightKey or ""
ITGOnline.onlineGameplayEvaluationRetryKey = ITGOnline.onlineGameplayEvaluationRetryKey or ""
ITGOnline.onlineGameplayEvaluationRetryCount = ITGOnline.onlineGameplayEvaluationRetryCount or 0
ITGOnline.onlineGameplayEvaluationNextRetryAt = ITGOnline.onlineGameplayEvaluationNextRetryAt or 0
ITGOnline.onlineGameplayEvaluationMaxRetries = ITGOnline.onlineGameplayEvaluationMaxRetries or 20
ITGOnline.onlineGameplayEvaluationTerminalErrorKey = ITGOnline.onlineGameplayEvaluationTerminalErrorKey or ""
ITGOnline.onlineGameplayEvaluationNavigationKey = ITGOnline.onlineGameplayEvaluationNavigationKey or ""
ITGOnline.onlineGameplayEvaluationNavigationAt = ITGOnline.onlineGameplayEvaluationNavigationAt or 0
ITGOnline.onlineGameplayEvaluationShownKey = ITGOnline.onlineGameplayEvaluationShownKey or ""
ITGOnline.onlineGameplayEvaluationReturnedKey = ITGOnline.onlineGameplayEvaluationReturnedKey or ""
ITGOnline.onlineGameplayAllTerminalHoldKey = ITGOnline.onlineGameplayAllTerminalHoldKey or ""
ITGOnline.onlineGameplayAllTerminalHoldUntil = ITGOnline.onlineGameplayAllTerminalHoldUntil or 0
ITGOnline.onlineGameplayReleaseLoggedKey = ITGOnline.onlineGameplayReleaseLoggedKey or ""
ITGOnline.previousScreenName = ITGOnline.previousScreenName or nil
ITGOnline.scheduledStartVisibleKey = ITGOnline.scheduledStartVisibleKey or ""
ITGOnline.scheduledStartVisibleSeconds = ITGOnline.scheduledStartVisibleSeconds or nil
ITGOnline.scheduledStartVisibleUpdatedAt = ITGOnline.scheduledStartVisibleUpdatedAt or 0
ITGOnline.heartbeatInFlight = ITGOnline.heartbeatInFlight or false
ITGOnline.heartbeatQueuedStatus = ITGOnline.heartbeatQueuedStatus or nil
ITGOnline.heartbeatQueuedForce = ITGOnline.heartbeatQueuedForce or false
ITGOnline.heartbeatQueuedFingerprint = ITGOnline.heartbeatQueuedFingerprint or ""
ITGOnline.heartbeatQueuedAt = ITGOnline.heartbeatQueuedAt or 0
ITGOnline.lastHeartbeatSentAt = ITGOnline.lastHeartbeatSentAt or 0
ITGOnline.lastHeartbeatFingerprint = ITGOnline.lastHeartbeatFingerprint or ""
ITGOnline.heartbeatMinIntervalSeconds = ITGOnline.heartbeatMinIntervalSeconds or 30
ITGOnline.heartbeatThrottleLogKey = ITGOnline.heartbeatThrottleLogKey or ""
ITGOnline.heartbeatThrottleLogAt = ITGOnline.heartbeatThrottleLogAt or 0
ITGOnline.heartbeatThrottleLogCount = ITGOnline.heartbeatThrottleLogCount or 0
ITGOnline.lobbyRefreshQueuedReason = ITGOnline.lobbyRefreshQueuedReason or ""
ITGOnline.lobbyRefreshQueuedAt = ITGOnline.lobbyRefreshQueuedAt or 0
ITGOnline.fileHashCache = ITGOnline.fileHashCache or {}
ITGOnline.fileHashCacheTtlSeconds = ITGOnline.fileHashCacheTtlSeconds or 30
ITGOnline.onlineFlowTraceThrottle = ITGOnline.onlineFlowTraceThrottle or {}
ITGOnline.debugOnlineTrace = ITGOnline.debugOnlineTrace == true
ITGOnline.debugScoreTrace = ITGOnline.debugScoreTrace == true
ITGOnline.debugReadyFlow = ITGOnline.debugReadyFlow == true
ITGOnline.lastDebugConfigPollAt = ITGOnline.lastDebugConfigPollAt or 0
ITGOnline.debugConfigPollIntervalSeconds = ITGOnline.debugConfigPollIntervalSeconds or 1.0
ITGOnline.lastHudScoreTraceSecond = ITGOnline.lastHudScoreTraceSecond or -1
ITGOnline.cachedLobbySearchPayload = ITGOnline.cachedLobbySearchPayload or { lobbies = {}, onlinePlayers = {} }
ITGOnline.finalLeaderboardCache = ITGOnline.finalLeaderboardCache or {}
ITGOnline.latestFinalLeaderboardCache = ITGOnline.latestFinalLeaderboardCache or nil
ITGOnline.finalLeaderboardCacheSignature = ITGOnline.finalLeaderboardCacheSignature or ""
ITGOnline.finalLeaderboardCacheLogSignature = ITGOnline.finalLeaderboardCacheLogSignature or ""
ITGOnline.finalLeaderboardCacheBootLogged = ITGOnline.finalLeaderboardCacheBootLogged or false

local function final_leaderboard_cache_trace(message)
	local line = "ITG Online: FLOW final_leaderboard_cache " .. tostring(message or "")
	if Trace then Trace(line) elseif Warn then Warn(line) end
end

if not ITGOnline.finalLeaderboardCacheBootLogged then
	ITGOnline.finalLeaderboardCacheBootLogged = true
	final_leaderboard_cache_trace("boot version=2026-06-23-global-final-leaderboard-cache")
end

local function online_table_copy(value, depth)
	if type(value) ~= "table" then return value end
	depth = tonumber(depth) or 0
	if depth > 5 then return nil end
	local copy = {}
	for key, item in pairs(value) do
		if type(item) == "table" then
			copy[key] = online_table_copy(item, depth + 1)
		else
			copy[key] = item
		end
	end
	return copy
end

local function trim(value)
	return tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function user_display_name(user, fallback)
	if type(user) ~= "table" then return tostring(fallback or "Player") end
	local displayName = trim(user.display_name or user.displayName or user.name)
	if displayName ~= "" then return displayName end
	if user.id ~= nil then return "User " .. tostring(user.id) end
	return tostring(fallback or "Player")
end

local function online_score_entry_summary(entry, index)
	if type(entry) ~= "table" then
		return tostring(index or "?") .. ":invalid"
	end
	local user = type(entry.user) == "table" and entry.user or type(entry.player) == "table" and entry.player or {}
	local userId = user.id or entry.user_id or entry.player_id or entry.playerId or ""
	local name = user_display_name(user, entry.name or entry.display_name or entry.displayName or "")
	return table.concat({
		tostring(index or ""),
		tostring(entry.rank or ""),
		tostring(userId or ""),
		tostring(name or ""),
		tostring(entry.displayed_percent or entry.displayedPercent or ""),
		tostring(entry.score_percent or entry.scorePercent or ""),
		tostring(entry.accuracy or ""),
		tostring(entry.score or ""),
		tostring(entry.failed == true),
		tostring(entry.state or entry.play_state or ""),
		tostring(entry.source or ""),
	}, ":")
end

local function online_score_rows_summary(rows, limit)
	if type(rows) ~= "table" then return "none" end
	local parts = {}
	local maxRows = math.min(#rows, tonumber(limit) or 8)
	for index = 1, maxRows do
		parts[#parts + 1] = online_score_entry_summary(rows[index], index)
	end
	if #rows > maxRows then
		parts[#parts + 1] = "more=" .. tostring(#rows - maxRows)
	end
	return table.concat(parts, ",")
end

function ITGOnline:UserDisplayName(user, fallback)
	return user_display_name(user, fallback)
end

local function parse_bool(value, fallback)
	if value == nil then return fallback == true end
	local text = trim(value):lower()
	if text == "1" or text == "true" or text == "yes" or text == "on" then return true end
	if text == "0" or text == "false" or text == "no" or text == "off" then return false end
	return fallback == true
end

local function query_escape(value)
	return tostring(value or ""):gsub("([^%w%-%_%.%~])", function(char)
		return string.format("%%%02X", string.byte(char))
	end)
end

local function url_host(value)
	local host = tostring(value or ""):match("^[A-Za-z]+://%[([^%]]+)%]")
	if host then return host end
	return tostring(value or ""):match("^[A-Za-z]+://([^/:]+)")
end

local function is_local_host(host)
	if not host then return false end
	host = tostring(host):lower():gsub("^%[", ""):gsub("%]$", "")
	return host == "localhost" or host == "127.0.0.1" or host == "::1"
end

local function is_itgonline_host(host)
	if not host then return false end
	host = tostring(host):lower()
	return host == "itgonline.fr" or host:match("%.itgonline%.fr$") ~= nil
end

local function network_allows(value)
	return NETWORK and NETWORK.IsUrlAllowed and NETWORK:IsUrlAllowed(value)
end

local function is_trusted_online_api_url(value)
	local lower = tostring(value or ""):lower()
	local host = url_host(value)
	if lower:match("^https://") and is_itgonline_host(host) then return true end
	if lower:match("^http://") and is_local_host(host) then return true end
	return false
end

local function is_trusted_online_websocket_url(value)
	local lower = tostring(value or ""):lower()
	local host = url_host(value)
	if lower:match("^wss://") and is_itgonline_host(host) then return true end
	if lower:match("^ws://") and is_local_host(host) then return true end
	return false
end

local function normalize_base_url(value)
	value = trim(value)
	if value == "" then return ITGOnline.defaults.apiBaseUrl end
	value = value:gsub("/+$", "")
	if is_trusted_online_api_url(value) and network_allows(value) then return value end
	return ITGOnline.defaults.apiBaseUrl
end

local function normalize_websocket_url(value)
	value = trim(value)
	if value == "" then return ITGOnline.defaults.webSocketUrl end
	if is_trusted_online_websocket_url(value) and network_allows(value) then return value end
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

local function active_online_player()
	if GAMESTATE then
		for player in ivalues(GAMESTATE:GetEnabledPlayers()) do
			if GAMESTATE:IsHumanPlayer(player) then return player end
		end
		if GAMESTATE:IsSideJoined(PLAYER_1) then return PLAYER_1 end
		if GAMESTATE:IsSideJoined(PLAYER_2) then return PLAYER_2 end
	end

	return PLAYER_1
end

local function active_online_player_modifiers()
	local player = active_online_player()
	local pn = player and ToEnumShortString(player) or "P1"
	return player, pn, SL and SL[pn] and SL[pn].ActiveModifiers or nil
end

local function profile_prefers_persistent_online_token()
	local player, pn, modifiers = active_online_player_modifiers()
	local rememberToken = modifiers and modifiers.RememberOnlineToken == true

	if not rememberToken and ThemePrefs and ThemePrefs.Get then
		local ok, value = pcall(function()
			return ThemePrefs.Get("ITGOnlineRememberToken")
		end)
		rememberToken = ok and value == true
		if rememberToken and modifiers then
			modifiers.RememberOnlineToken = true
		end
	end

	if not player or not rememberToken then
		return false
	end

	if not PROFILEMAN or not PROFILEMAN.IsPersistentProfile then return false end
	return PROFILEMAN:IsPersistentProfile(player)
end

local function online_profile_slot(player)
	if player == PLAYER_2 then return "ProfileSlot_Player2" end
	return "ProfileSlot_Player1"
end

local function active_profile_auth_path()
	if not PROFILEMAN then return nil, nil end

	local player = active_online_player()
	local ok, dir = pcall(function()
		return PROFILEMAN:GetProfileDir(online_profile_slot(player))
	end)
	if not ok or trim(dir) == "" then return nil, nil end

	return dir .. "ITGOnline.ini", dir
end

local function access_token_scope(apiBaseUrl, deviceName)
	local _, profileDir = active_profile_auth_path()
	if profileDir then
		return "profile:" .. profileDir
	end

	return "machine:" .. normalize_base_url(apiBaseUrl) .. "|" .. trim(deviceName)
end

local function profile_access_token_cache_entry(path)
	ITGOnline.profileAccessTokenCache = ITGOnline.profileAccessTokenCache or {}
	return ITGOnline.profileAccessTokenCache[path]
end

local function set_profile_access_token_cache(path, apiBaseUrl, token, exists)
	if not path then return end

	ITGOnline.profileAccessTokenCache = ITGOnline.profileAccessTokenCache or {}
	ITGOnline.profileAccessTokenCache[path] = {
		apiBaseUrl = normalize_base_url(apiBaseUrl),
		token = tostring(token or ""),
		exists = exists == true,
	}
end

local function invalidate_profile_access_token_cache(path)
	ITGOnline.profileAccessTokenCache = ITGOnline.profileAccessTokenCache or {}
	if path then
		ITGOnline.profileAccessTokenCache[path] = nil
	else
		ITGOnline.profileAccessTokenCache = {}
	end
end

local function read_profile_access_token(apiBaseUrl, deviceName)
	local path = active_profile_auth_path()
	if not path or not FILEMAN:DoesFileExist(path) then return nil, false end

	local normalizedApiBaseUrl = normalize_base_url(apiBaseUrl)
	local expectedScope = access_token_scope(apiBaseUrl, deviceName)
	local cached = profile_access_token_cache_entry(path)
	if cached
		and cached.apiBaseUrl == normalizedApiBaseUrl
		and (not cached.scope or cached.scope == expectedScope) then
		local cachedToken = tostring(cached.token or "")
		return cachedToken ~= "" and cachedToken or nil, cachedToken ~= ""
	end

	local contents = IniFile.ReadFile(path) or {}
	local section = contents["ITGOnline"] or {}
	if normalize_base_url(section["ApiBaseUrl"]) ~= normalizedApiBaseUrl then
		return nil, false
	end

	local storedScope = tostring(section["AccessTokenScope"] or "")
	if storedScope ~= "" and storedScope ~= expectedScope then
		return nil, false
	end

	local token = tostring(section["AccessToken"] or "")
	set_profile_access_token_cache(path, normalizedApiBaseUrl, token, token ~= "")
	ITGOnline.profileAccessTokenCache[path].scope = expectedScope
	if token == "" then return nil, false end

	return token, true
end

local function write_profile_access_token(apiBaseUrl, deviceName, accessToken, user)
	local path = active_profile_auth_path()
	if not path or tostring(accessToken or "") == "" then return false end

	local contents = {}
	if FILEMAN:DoesFileExist(path) then
		contents = IniFile.ReadFile(path) or {}
	end

	contents["ITGOnline"] = contents["ITGOnline"] or {}
	contents["ITGOnline"]["ApiBaseUrl"] = normalize_base_url(apiBaseUrl)
	contents["ITGOnline"]["AccessTokenScope"] = access_token_scope(apiBaseUrl, deviceName)
	contents["ITGOnline"]["AccessToken"] = tostring(accessToken or "")
	if user and user.id then
		contents["ITGOnline"]["UserId"] = tostring(user.id)
	end
	if user then
		contents["ITGOnline"]["UserName"] = user_display_name(user, user.name)
	end

	IniFile.WriteFile(path, contents)
	set_profile_access_token_cache(path, contents["ITGOnline"]["ApiBaseUrl"], contents["ITGOnline"]["AccessToken"], true)
	ITGOnline.profileAccessTokenCache[path].scope = contents["ITGOnline"]["AccessTokenScope"]
	return true
end

local function clear_profile_access_token()
	local path = active_profile_auth_path()
	if not path or not FILEMAN:DoesFileExist(path) then
		invalidate_profile_access_token_cache(path)
		return false
	end

	local cached = profile_access_token_cache_entry(path)
	if cached and tostring(cached.token or "") == "" then
		return false
	end

	local contents = IniFile.ReadFile(path) or {}
	contents["ITGOnline"] = contents["ITGOnline"] or {}
	if tostring(contents["ITGOnline"]["AccessToken"] or "") == "" then
		set_profile_access_token_cache(path, contents["ITGOnline"]["ApiBaseUrl"] or "", "", true)
		return false
	end

	contents["ITGOnline"]["AccessToken"] = ""
	contents["ITGOnline"]["AccessTokenScope"] = ""
	IniFile.WriteFile(path, contents)
	set_profile_access_token_cache(path, contents["ITGOnline"]["ApiBaseUrl"] or "", "", true)
	return true
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

local function secure_access_token_account(apiBaseUrl, deviceName)
	local account = normalize_base_url(apiBaseUrl) .. "|" .. access_token_scope(apiBaseUrl, deviceName)
	return account == "|" and "" or account
end

local function legacy_secure_access_token_account(apiBaseUrl, deviceName)
	local account = normalize_base_url(apiBaseUrl) .. "|" .. trim(deviceName)
	return account == "|" and "" or account
end

local function secure_access_token_get(apiBaseUrl, deviceName)
	if not profile_prefers_persistent_online_token() then
		return nil, false
	end

	if not secure_credentials_available() then
		local profileToken, profileStored = read_profile_access_token(apiBaseUrl, deviceName)
		if profileStored then return profileToken, false end
		online_trace("Secure access token load skipped: secure credential storage unavailable; using profile token fallback only when present.")
		return nil, false
	end

	local account = secure_access_token_account(apiBaseUrl, deviceName)
	if account == "" then return nil, false end

	local result = NETWORK:SecureCredentialGet(ITGOnline.accessTokenService, account)
	if result and result.ok and tostring(result.secret or "") ~= "" then
		return tostring(result.secret), true
	end

	local legacyAccount = legacy_secure_access_token_account(apiBaseUrl, deviceName)
	if legacyAccount ~= "" and legacyAccount ~= account then
		result = NETWORK:SecureCredentialGet(ITGOnline.accessTokenService, legacyAccount)
		if result and result.ok and tostring(result.secret or "") ~= "" then
			return tostring(result.secret), true
		end
	end

	local profileToken, profileStored = read_profile_access_token(apiBaseUrl, deviceName)
	if profileStored then return profileToken, false end

	return nil, false
end

local function secure_access_token_set(apiBaseUrl, deviceName, accessToken, user)
	if not profile_prefers_persistent_online_token() then
		clear_profile_access_token()
		return false
	end

	if not secure_credentials_available() then
		local savedToProfile = write_profile_access_token(apiBaseUrl, deviceName, accessToken, user)
		online_trace(
			"Secure access token save skipped: secure credential storage unavailable; " ..
			(savedToProfile and "stored token in local profile file." or "failed to store token in local profile file.")
		)
		return savedToProfile
	end

	local account = secure_access_token_account(apiBaseUrl, deviceName)
	if account == "" or tostring(accessToken or "") == "" then return false end

	local result = NETWORK:SecureCredentialSet(ITGOnline.accessTokenService, account, tostring(accessToken))
	if not result or not result.ok then
		online_trace("Secure access token save failed using " .. secure_credentials_backend() .. ": " .. tostring(result and result.error or "unknown"))
		clear_profile_access_token()
		return false
	end

	clear_profile_access_token()

	local legacyAccount = legacy_secure_access_token_account(apiBaseUrl, deviceName)
	if legacyAccount ~= "" and legacyAccount ~= account then
		NETWORK:SecureCredentialDelete(ITGOnline.accessTokenService, legacyAccount)
	end

	return true
end

local function secure_access_token_delete(apiBaseUrl, deviceName)
	clear_profile_access_token()
	if not secure_credentials_available() then return false end

	local account = secure_access_token_account(apiBaseUrl, deviceName)
	local deleted = false
	if account ~= "" then
		local result = NETWORK:SecureCredentialDelete(ITGOnline.accessTokenService, account)
		deleted = result and result.ok
	end

	local legacyAccount = legacy_secure_access_token_account(apiBaseUrl, deviceName)
	if legacyAccount ~= "" and legacyAccount ~= account then
		local result = NETWORK:SecureCredentialDelete(ITGOnline.accessTokenService, legacyAccount)
		deleted = deleted or (result and result.ok)
	end

	return deleted
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

local function response_error_code(response, decoded)
	if decoded and decoded.error_code then return tostring(decoded.error_code) end
	if response and response.error_code then return tostring(response.error_code) end
	if response and response.error then return tostring(response.error) end
	return ""
end

local function sync_current_room_meta(decoded)
	local meta = decoded and decoded.meta or nil
	local currentRoomMeta = meta and meta.current_room or nil
	return type(currentRoomMeta) == "table" and currentRoomMeta or nil
end

local function apply_authenticated_user_state(client, user)
	local previousUserId = client.lastAuthenticatedUserId or (client.user and client.user.id) or nil
	local nextUserId = user and user.id or nil
	if nextUserId and tostring(previousUserId or "") ~= "" and tostring(previousUserId) ~= tostring(nextUserId) then
		client:ResetRealtimeState()
	end
	client.lastAuthenticatedUserId = nextUserId
	client.user = user
	client.sessionExpired = false
end

local function ready_flow_trace_message(message)
	local text = tostring(message or "")
	return text:match("^FLOW") ~= nil
		or text:match("^ITG Online ReadyFlow") ~= nil
		or text:match("^%[ITGOnline%] ready_") ~= nil
		or text:match("^manager_auto_ready") ~= nil
end

function online_trace(message)
	if not (ITGOnline and (
		ITGOnline.debugOnlineTrace == true
		or (ITGOnline.debugReadyFlow == true and ready_flow_trace_message(message))
	)) then
		return
	end
	local line = "ITG Online: " .. tostring(message or "")
	if Trace then Trace(line) elseif Warn then Warn(line) end
end

function ITGOnline:RefreshDebugFlags(force)
	local now = GetTimeSinceStart()
	if not force and (now - (tonumber(self.lastDebugConfigPollAt) or 0) < (tonumber(self.debugConfigPollIntervalSeconds) or 1.0)) then
		return
	end
	self.lastDebugConfigPollAt = now

	if not FILEMAN:DoesFileExist(self.debugConfigPath) then
		IniFile.WriteFile(self.debugConfigPath, {
			["ITGOnlineDebug"] = {
				["OnlineTrace"] = "false",
				["ScoreTrace"] = "false",
				["ReadyFlow"] = "false",
			}
		})
	end

	local raw = IniFile.ReadFile(self.debugConfigPath) or {}
	local section = raw["ITGOnlineDebug"] or {}

	self.debugOnlineTrace = parse_bool(section["OnlineTrace"], false)
	self.debugScoreTrace = parse_bool(section["ScoreTrace"], false)
	self.debugReadyFlow = parse_bool(section["ReadyFlow"], false)
end

local function online_flow_trace(message)
	if not (ITGOnline and (ITGOnline.debugOnlineTrace == true or ITGOnline.debugReadyFlow == true)) then
		return
	end
	local screen = SCREENMAN and SCREENMAN:GetTopScreen() or nil
	local screenName = screen and screen:GetName() or "NoScreen"
	local phase = ITGOnline and ITGOnline.currentRoom and ITGOnline.currentRoom.phase or "no-room"
	local roomId = ITGOnline and ITGOnline.currentRoomId or "no-room-id"
	local line = "ITG Online: FLOW room=" .. tostring(roomId)
		.. " phase=" .. tostring(phase)
		.. " screen=" .. tostring(screenName)
		.. " " .. tostring(message or "")
	if Trace then Trace(line) elseif Warn then Warn(line) end
	if Flush then Flush() end
end

local function online_flow_trace_throttled(key, intervalSeconds, message)
	if not ITGOnline then return end

	local now = GetTimeSinceStart()
	ITGOnline.onlineFlowTraceThrottle = ITGOnline.onlineFlowTraceThrottle or {}

	local throttleKey = tostring(key or "")
	local previous = ITGOnline.onlineFlowTraceThrottle[throttleKey] or {}
	if previous.message == message and now - (tonumber(previous.at) or 0) < (tonumber(intervalSeconds) or 1.0) then
		return
	end

	ITGOnline.onlineFlowTraceThrottle[throttleKey] = {
		at = now,
		message = message,
	}
	online_flow_trace(message)
end

local function sorted_count_summary(counts)
	local keys = {}
	for key, _ in pairs(counts or {}) do
		keys[#keys + 1] = tostring(key)
	end
	table.sort(keys)

	local parts = {}
	for key in ivalues(keys) do
		parts[#parts + 1] = key .. ":" .. tostring(counts[key] or 0)
	end
	return table.concat(parts, ",")
end

local function room_member_status_summary(room)
	local packCounts = {}
	local playCounts = {}
	local members = room and room.members or {}
	for member in ivalues(members) do
		local packStatus = tostring(member.pack_sync_status or "none")
		packCounts[packStatus] = (packCounts[packStatus] or 0) + 1

		local playState = tostring(member.play_state or "none")
		playCounts[playState] = (playCounts[playState] or 0) + 1
	end

	return "members=" .. tostring(#members)
		.. " pack={" .. sorted_count_summary(packCounts) .. "}"
		.. " play={" .. sorted_count_summary(playCounts) .. "}"
end

local function room_ready_summary(room)
	local counts = {}
	for ready in ivalues(room and room.ready_states or {}) do
		local phase = tostring(ready.phase or "unknown")
		counts[phase] = (counts[phase] or 0) + 1
	end
	return sorted_count_summary(counts)
end

local function room_final_results_summary(room)
	local results = room and (room.final_results or (room.play_state and room.play_state.final_results)) or {}
	if type(results) ~= "table" then return "" end

	local parts = {}
	for key, result in pairs(results) do
		if type(result) == "table" then
			local user = result.user or result.player or {}
			local userId = result.user_id or result.player_id or result.userId or result.playerId or user.id or key
			local displayed = result.displayed_percent or result.displayedPercent or result.score_percent or result.percent
			local source = result.source or result.finalization_source or result.finalizationSource or ""
			parts[#parts + 1] = tostring(userId or "")
				.. ":" .. tostring(displayed or "")
				.. ":" .. tostring(result.failed == true)
				.. ":" .. tostring(source or "")
		else
			parts[#parts + 1] = tostring(key) .. ":" .. tostring(result)
		end
	end
	table.sort(parts)
	return table.concat(parts, ",")
end

local function room_transition_key(room)
	if not room then return "" end
	local selected = room.selected_song or {}
	local playState = room.play_state or {}
	return table.concat({
		tostring(room.id or ""),
		tostring(room.phase or ""),
		tostring(selected.selected_at or selected.chart_hash or selected.song_hash or ""),
		tostring(room.start_at_ms or room.start_at or ""),
		tostring(room.started_at_ms or room.started_at or ""),
		tostring(playState.version_ms or ""),
		room_member_status_summary(room),
		"ready={" .. room_ready_summary(room) .. "}",
		"final={" .. room_final_results_summary(room) .. "}",
	}, "|")
end

local function online_room_transition_trace(previousRoom, room, source)
	if not ITGOnline or not room then return end

	local key = room_transition_key(room)
	if key == "" or ITGOnline.lastOnlineRoomTransitionTraceKey == key then return end
	ITGOnline.lastOnlineRoomTransitionTraceKey = key

	local selected = room.selected_song or {}
	local previousPhase = previousRoom and previousRoom.phase or "none"
	online_flow_trace("room_transition source=" .. tostring(source or "unknown")
		.. " previousPhase=" .. tostring(previousPhase)
		.. " nextPhase=" .. tostring(room.phase or "nil")
		.. " selected=" .. tostring(selected.title or selected.folder_name or selected.song_hash or "none")
		.. " startAt=" .. tostring(room.start_at_ms or room.start_at or "nil")
		.. " playStateVersion=" .. tostring(room.play_state and room.play_state.version_ms or "nil")
		.. " ready={" .. room_ready_summary(room) .. "}"
		.. " " .. room_member_status_summary(room))
end

local function online_room_snapshot_debug(label, room, source, previousRoom)
	if not ITGOnline or type(room) ~= "table" then return end
	local selected = room.selected_song or {}
	local playState = room.play_state or {}
	local previousPhase = previousRoom and previousRoom.phase or "none"
	local previousMembers = previousRoom and previousRoom.members or {}
	local previousReady = previousRoom and previousRoom.ready_states or {}
	online_flow_trace(tostring(label or "room_snapshot")
		.. " source=" .. tostring(source or "unknown")
		.. " room=" .. tostring(room.id or "nil")
		.. " previousPhase=" .. tostring(previousPhase)
		.. " incomingPhase=" .. tostring(room.phase or "nil")
		.. " previousMembers=" .. tostring(#previousMembers)
		.. " incomingMembers=" .. tostring(type(room.members) == "table" and #room.members or 0)
		.. " previousReady=" .. tostring(#previousReady)
		.. " incomingReady=" .. tostring(type(room.ready_states) == "table" and #room.ready_states or 0)
		.. " selected=" .. tostring(selected.title or selected.folder_name or selected.song_hash or "none")
		.. " roundKey=" .. tostring(ITGOnline:RoomSongRoundKey(room) or "")
		.. " playStateVersion=" .. tostring(playState.version_ms or "nil")
		.. " currentScreen=" .. tostring(ITGOnline.currentScreenName or "nil")
		.. " generation=" .. tostring(ITGOnline.screenGeneration or "nil")
		.. " " .. room_member_status_summary(room)
		.. " ready={" .. room_ready_summary(room) .. "}")
end

function ITGOnline:ShouldApplyRoomSnapshotPayload(room, source, eventId)
	if type(room) ~= "table" then return false end

	local roomId = tostring(room.id or room.room_id or room.roomId or self.currentRoomId or "")
	local key = room_transition_key(room)
	if roomId == "" or key == "" then return true end

	self.lastAppliedRoomSnapshotKeyByRoomId = self.lastAppliedRoomSnapshotKeyByRoomId or {}
	local previousKey = self.lastAppliedRoomSnapshotKeyByRoomId[roomId]
	if previousKey == key then
		online_flow_trace_throttled("duplicate_room_snapshot:" .. roomId, 0.75,
			"duplicate_room_snapshot_ignored source=" .. tostring(source or "unknown")
				.. " roomId=" .. roomId
				.. " eventId=" .. tostring(eventId or "nil")
				.. " phase=" .. tostring(room.phase or "nil")
				.. " selectedAt=" .. tostring(room.selected_song and (room.selected_song.selected_at or room.selected_song.selectedAt) or "nil")
				.. " playStateVersion=" .. tostring(room.play_state and room.play_state.version_ms or "nil")
				.. " final={" .. room_final_results_summary(room) .. "}")
		return false
	end

	self.lastAppliedRoomSnapshotKeyByRoomId[roomId] = key
	return true
end

local function request_id()
	if CRYPTMAN and CRYPTMAN.GenerateRandomUUID then
		return CRYPTMAN:GenerateRandomUUID()
	end

	-- Correlation only. This fallback must never be used as an auth or replay token.
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

local function is_leap_year(year)
	return (year % 4 == 0 and year % 100 ~= 0) or (year % 400 == 0)
end

local function days_in_month(year, month)
	local days = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }
	if month == 2 and is_leap_year(year) then return 29 end
	return days[month] or 0
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
	if year < 1970 or year > 2100 or month < 1 or month > 12 then return nil end
	if day < 1 or day > days_in_month(year, month) then return nil end
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

local function online_local_player_count()
	local count = 0
	for player in ivalues(GAMESTATE:GetEnabledPlayers()) do
		if GAMESTATE:IsSideJoined(player) then count = count + 1 end
	end
	return count
end

local function online_single_local_player_allowed()
	return online_local_player_count() <= 1
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

local function cached_sha256_file_hex(path)
	path = tostring(path or "")
	if path == "" then return nil end
	ITGOnline.fileHashCache = ITGOnline.fileHashCache or {}
	local size = nil
	if FILEMAN and FILEMAN.GetFileSizeBytes then
		local ok, value = pcall(function() return FILEMAN:GetFileSizeBytes(path) end)
		if ok and tonumber(value) then size = tonumber(value) end
	end
	local cacheKey = path .. "|" .. tostring(size or "unknown")
	local cached = ITGOnline.fileHashCache[cacheKey]
	local now = GetTimeSinceStart()
	local ttl = tonumber(ITGOnline.fileHashCacheTtlSeconds) or 30
	if type(cached) == "table" and cached.digest and cached.at and now - cached.at <= ttl then
		return cached.digest
	end

	local digest = sha256_file_hex(path)
	if digest then
		ITGOnline.fileHashCache[cacheKey] = { digest = digest, at = now }
	end
	return digest
end

local function manifest_file_name(path)
	local value = tostring(path or ""):gsub("\\", "/")
	local name = value:match("([^/]+)$") or ""
	name = name:gsub("[^%w%._%- ]", "_")
	if name == "" then return nil end
	return name
end

local function simfile_relative_path(path)
	local value = tostring(path or ""):gsub("\\", "/")
	value = value:gsub("^/*Songs/+", "")
	value = value:gsub("^/+", "")
	value = value:gsub("/+$", "")
	return value ~= "" and value or nil
end

function ITGOnline:NormalizeHash(value, options)
	options = options or {}
	value = tostring(value or ""):lower()
	if value:match("^[a-f0-9]+$") and #value == 64 then return value end
	if options.hashFallback then return sha256_hex(value) end
	return ""
end

local function normalized_hash(value)
	return ITGOnline:NormalizeHash(value, { hashFallback = true })
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

local function apply_music_rate(rate)
	rate = math.max(0.25, math.min(3.0, tonumber(rate) or 1.0))
	if SL and SL.Global and SL.Global.ActiveModifiers then
		SL.Global.ActiveModifiers.MusicRate = rate
	end
	if not GAMESTATE or not GAMESTATE.GetSongOptionsObject then return rate end

	for _, level in ipairs({ "ModsLevel_Preferred", "ModsLevel_Song" }) do
		local ok, options = pcall(function() return GAMESTATE:GetSongOptionsObject(level) end)
		if ok and options and options.MusicRate then
			pcall(function() options:MusicRate(rate) end)
		end
	end

	return rate
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
		["dance-threepanel"] = "dance-threepanel",
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
		threepanel = game .. "-threepanel",
	}
	if short[lower] then return short[lower] end

	return lower
end

local function read_config(loadPassword)
	if loadPassword == nil then loadPassword = true end
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
	local deviceName = trim(section["DeviceName"]) ~= "" and trim(section["DeviceName"]) or ITGOnline.defaults.deviceName
	local securePassword, securePasswordStored = nil, false
	if loadPassword then
		securePassword, securePasswordStored = secure_password_get(apiBaseUrl, email)
		if not securePasswordStored then
			local transientAccount = ITGOnline and ITGOnline.transientPasswordAccount or nil
			local currentAccount = secure_password_account(apiBaseUrl, email)
			if (currentAccount ~= "" and transientAccount == currentAccount)
				or (transientAccount == "" and tostring(ITGOnline.transientPassword or "") ~= "")
			then
				local transientPassword = tostring(ITGOnline.transientPassword or "")
				if transientPassword ~= "" then
					securePassword = transientPassword
				end
			end
		end
	end
	local accessToken, accessTokenStored = secure_access_token_get(apiBaseUrl, deviceName)

	return {
		apiBaseUrl = apiBaseUrl,
		webSocketUrl = normalize_websocket_url(section["WebSocketUrl"]),
		email = email,
		password = tostring(securePassword or ""),
		passwordStoredSecurely = securePasswordStored,
		accessToken = tostring(accessToken or ""),
		accessTokenStoredSecurely = accessTokenStored,
		accessTokenScope = access_token_scope(apiBaseUrl, deviceName),
		secureCredentialsBackend = secure_credentials_backend(),
		deviceName = deviceName,
	}
end

local function copy_connection_config(config)
	config = config or {}
	return {
		apiBaseUrl = config.apiBaseUrl or ITGOnline.defaults.apiBaseUrl,
		webSocketUrl = config.webSocketUrl or ITGOnline.defaults.webSocketUrl,
		email = config.email or "",
		password = "",
		passwordStoredSecurely = config.passwordStoredSecurely == true,
		accessToken = config.accessToken or "",
		accessTokenStoredSecurely = config.accessTokenStoredSecurely == true,
		accessTokenScope = config.accessTokenScope or access_token_scope(config.apiBaseUrl, config.deviceName),
		secureCredentialsBackend = config.secureCredentialsBackend or secure_credentials_backend(),
		deviceName = config.deviceName or ITGOnline.defaults.deviceName,
	}
end

local function hydrate_config_password(config)
	config = config or {}
	local currentAccessTokenScope = access_token_scope(config.apiBaseUrl, config.deviceName)
	if config.accessTokenScope ~= currentAccessTokenScope then
		config.accessToken = ""
		config.accessTokenStoredSecurely = false
		config.accessTokenScope = currentAccessTokenScope
	end

	if tostring(config.password or "") == "" then
		local securePassword, securePasswordStored = secure_password_get(config.apiBaseUrl, config.email)
		if securePasswordStored and tostring(securePassword or "") ~= "" then
			config.password = tostring(securePassword or "")
			config.passwordStoredSecurely = true
		else
			local transientAccount = ITGOnline and ITGOnline.transientPasswordAccount or nil
			local currentAccount = secure_password_account(config.apiBaseUrl, config.email)
			if (currentAccount ~= "" and transientAccount == currentAccount)
				or (transientAccount == "" and tostring(ITGOnline.transientPassword or "") ~= "")
			then
				local transientPassword = tostring(ITGOnline.transientPassword or "")
				if transientPassword ~= "" then
					config.password = transientPassword
				end
			end

			config.passwordStoredSecurely = false
		end
	end

	local accessToken, accessTokenStored = secure_access_token_get(config.apiBaseUrl, config.deviceName)
	if accessTokenStored and tostring(accessToken or "") ~= "" then
		config.accessToken = tostring(accessToken or "")
		config.accessTokenStoredSecurely = true
		config.accessTokenScope = currentAccessTokenScope
		return config
	end
	if tostring(accessToken or "") ~= "" then
		config.accessToken = tostring(accessToken)
		config.accessTokenStoredSecurely = false
		config.accessTokenScope = currentAccessTokenScope
		return config
	end

	config.accessTokenStoredSecurely = false
	return config
end

function ITGOnline:Config()
	if self.config then
		return hydrate_config_password(self.config)
	end

	if self.connectionConfig then
		self.config = copy_connection_config(self.connectionConfig)
		return hydrate_config_password(self.config)
	end

	self.config = read_config(true)
	self.connectionConfig = copy_connection_config(self.config)
	return self.config
end

function ITGOnline:IsTrustedConnectionConfig(config)
	config = config or self.config or self:Config()
	return is_trusted_online_api_url(config.apiBaseUrl)
		and is_trusted_online_websocket_url(config.webSocketUrl)
		and network_allows(config.apiBaseUrl)
		and network_allows(config.webSocketUrl)
end

function ITGOnline:ConnectionConfig()
	if self.connectionConfig then
		local currentAccessTokenScope = access_token_scope(self.connectionConfig.apiBaseUrl, self.connectionConfig.deviceName)
		if self.connectionConfig.accessTokenScope ~= currentAccessTokenScope then
			self.connectionConfig.accessToken = ""
			self.connectionConfig.accessTokenStoredSecurely = false
			self.connectionConfig.accessTokenScope = currentAccessTokenScope
		end
		if tostring(self.connectionConfig.accessToken or "") == "" then
			local accessToken, accessTokenStored = secure_access_token_get(
				self.connectionConfig.apiBaseUrl,
				self.connectionConfig.deviceName
			)
			if tostring(accessToken or "") ~= "" then
				self.connectionConfig.accessToken = tostring(accessToken)
				self.connectionConfig.accessTokenStoredSecurely = accessTokenStored == true
			end
		end
		return self.connectionConfig
	end

	if self.config then
		self.connectionConfig = copy_connection_config(self.config)
		return self.connectionConfig
	end

	self.connectionConfig = read_config(false)
	return self.connectionConfig
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
			self.transientPassword = nil
			self.transientPasswordAccount = nil
			secure_password_delete(current.apiBaseUrl, current.email)
			secure_password_delete(nextConfig.apiBaseUrl, nextConfig.email)
		else
			securePasswordStored = secure_password_set(nextConfig.apiBaseUrl, nextConfig.email, nextPassword)
			if securePasswordStored
				and (nextConfig.email ~= current.email or nextConfig.apiBaseUrl ~= current.apiBaseUrl) then
				secure_password_delete(current.apiBaseUrl, current.email)
			end
			if securePasswordStored then
				self.transientPassword = nil
				self.transientPasswordAccount = nil
			else
				self.transientPassword = nextPassword
				self.transientPasswordAccount = secure_password_account(nextConfig.apiBaseUrl, nextConfig.email)
			end
		end
	else
		local storedPassword
		storedPassword, securePasswordStored = secure_password_get(nextConfig.apiBaseUrl, nextConfig.email)
		if storedPassword and storedPassword ~= "" then
			nextPassword = storedPassword
		elseif self.transientPasswordAccount == secure_password_account(nextConfig.apiBaseUrl, nextConfig.email)
			and tostring(self.transientPassword or "") ~= ""
		then
			nextPassword = tostring(self.transientPassword or "")
		elseif self.transientPasswordAccount == ""
			and tostring(self.transientPassword or "") ~= ""
		then
			nextPassword = tostring(self.transientPassword or "")
			self.transientPasswordAccount = secure_password_account(nextConfig.apiBaseUrl, nextConfig.email)
		elseif nextConfig.email ~= current.email or nextConfig.apiBaseUrl ~= current.apiBaseUrl then
			nextPassword = ""
		end
	end

	nextConfig.password = nextPassword
	nextConfig.passwordStoredSecurely = securePasswordStored
	nextConfig.accessToken = ""
	nextConfig.accessTokenStoredSecurely = false
	nextConfig.accessTokenScope = access_token_scope(nextConfig.apiBaseUrl, nextConfig.deviceName)
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
	self.connectionConfig = copy_connection_config(nextConfig)
	return nextConfig
end

function ITGOnline:ClearTransientSecrets()
	online_flow_trace("transient_secrets_clear hasTransientPassword=" .. tostring(tostring(ITGOnline.transientPassword or "") ~= "")
		.. " hasConfigPassword=" .. tostring(self.config and tostring(self.config.password or "") ~= "" or false))
	ITGOnline.transientPassword = nil
	ITGOnline.transientPasswordAccount = nil
	if self.config then
		self.config.password = ""
	end
end

function ITGOnline:HasStoredAccessToken()
	if not profile_prefers_persistent_online_token() then
		return false
	end

	local config = self:ConnectionConfig()
	if tostring(config.accessToken or "") ~= "" then return true end
	local accessToken = secure_access_token_get(config.apiBaseUrl, config.deviceName)
	return accessToken ~= nil and tostring(accessToken or "") ~= ""
end

function ITGOnline:StoreAccessToken(accessToken, user)
	local config = self:Config()
	if not profile_prefers_persistent_online_token() then
		self:ClearStoredAccessToken()
		self.config = self.config or config
		self.config.accessToken = ""
		self.config.accessTokenStoredSecurely = false
		self.config.accessTokenScope = access_token_scope(config.apiBaseUrl, config.deviceName)
		self.connectionConfig = copy_connection_config(self.config)
		online_trace("ITG Online token persistence disabled for active profile; token kept in memory for current session only.")
		return false
	end

	local stored = secure_access_token_set(config.apiBaseUrl, config.deviceName, accessToken, user)
	if stored then
		local _, storedSecurely = secure_access_token_get(config.apiBaseUrl, config.deviceName)
		self.config = self.config or config
		self.config.accessToken = tostring(accessToken or "")
		self.config.accessTokenStoredSecurely = storedSecurely == true
		self.config.accessTokenScope = access_token_scope(config.apiBaseUrl, config.deviceName)
		self.connectionConfig = copy_connection_config(self.config)
	end
	return stored
end

function ITGOnline:ShouldRememberTokenForCurrentProfile()
	return profile_prefers_persistent_online_token()
end

function ITGOnline:LogPreferenceChange(name, value, pn)
	online_trace(
		"ITG Online preference changed: " .. tostring(name) ..
		"=" .. tostring(value) .. " player=" .. tostring(pn or "?") ..
		" persistentProfile=" .. tostring(profile_prefers_persistent_online_token())
	)
end

function ITGOnline:ClearStoredAccessToken()
	local config = self:ConnectionConfig()
	online_flow_trace("stored_access_token_clear scope=" .. tostring(access_token_scope(config.apiBaseUrl, config.deviceName))
		.. " hadConfigToken=" .. tostring(self.config and tostring(self.config.accessToken or "") ~= "" or false)
		.. " hadConnectionToken=" .. tostring(self.connectionConfig and tostring(self.connectionConfig.accessToken or "") ~= "" or false))
	secure_access_token_delete(config.apiBaseUrl, config.deviceName)
	if self.config then
		self.config.accessToken = ""
		self.config.accessTokenStoredSecurely = false
	end
	if self.connectionConfig then
		self.connectionConfig.accessToken = ""
		self.connectionConfig.accessTokenStoredSecurely = false
	end
end

function ITGOnline:InvalidateAuthenticatedSession(reason, payload)
	reason = tostring(reason or "session_invalidated")
	payload = type(payload) == "table" and payload or {}
	local message = tostring(payload.message or payload.reason_message or "")
	if message == "" then
		if reason == "auth.session_revoked" then
			message = "Cette session a ete ouverte ailleurs. Reconnecte ce joueur avec un compte different."
		else
			message = "La session en ligne n'est plus valide. Reconnecte ce joueur."
		end
	end

	online_flow_trace("auth_session_invalidate_begin reason=" .. reason
		.. " message=" .. tostring(message)
		.. " user=" .. tostring(self.user and self.user.id or "nil")
		.. " room=" .. tostring(self.currentRoomId or "nil")
		.. " screen=" .. tostring(self.currentScreenName or "nil")
		.. " socket=" .. tostring(self.socket ~= nil)
		.. " disconnecting=" .. tostring(self.disconnecting == true))

	self.authSessionInvalidated = true
	self.authSessionInvalidatedReason = reason
	self.sessionExpired = true
	self.disconnecting = false
	self.authRefreshInFlight = false
	self.authRefreshCallbacks = {}
	self.authRefreshFailureCount = self.maxAuthRefreshFailures or 3
	self.authRefreshNextAttemptAt = GetTimeSinceStart() + 3600

	self:CancelPendingRequests()
	if self.socket then
		online_flow_trace("auth_session_invalidate_socket_close generation=" .. tostring(self.realtimeGeneration or "nil"))
		self.realtimeGeneration = (tonumber(self.realtimeGeneration) or 0) + 1
		pcall(function() self.socket:Close() end)
	end
	self.socket = nil
	self.realtimeConnecting = false
	self.realtimeConnected = false
	self.pendingRealtimeConnectCallbacks = {}
	self.activeRealtimeCallbacks = nil

	self:ClearStoredAccessToken()
	self.token = nil
	self.user = nil
	self.currentRoomId = nil
	self.currentRoom = nil
	self.pendingJoinRoomId = nil
	self.pendingJoinRequestId = nil
	self.currentSongPayload = nil
	self.currentRoomRoundKey = ""
	self.lastResultSongPayload = nil
	self.activeGameplaySongPayload = nil
	self.activeGameplayRoundKey = ""
	self.cachedLobbySearchPayload = { lobbies = {}, onlinePlayers = {} }
	self.syncInFlight = false
	self.syncQueued = false
	self.syncCallbacks = {}
	self.syncAccumulator = nil
	self.syncGeneration = (tonumber(self.syncGeneration) or 0) + 1
	self.lobbyRefreshInFlight = false
	self.lobbyRefreshQueued = false
	self.lobbyRefreshQueuedReason = ""
	self.lobbyRefreshQueuedAt = 0
	self.lobbyRefreshDeferredScheduled = false
	self.heartbeatInFlight = false
	self.heartbeatQueuedStatus = nil
	self.heartbeatQueuedForce = false
	self.heartbeatQueuedFingerprint = ""
	self.heartbeatQueuedAt = 0
	self.lastHeartbeatSentAt = 0
	self.lastHeartbeatFingerprint = ""
	self.readyRequestInFlight = {}
	self.readyRequestLastResult = {}
	self.readyRequestBlockedErrors = {}
	self:ClearCurrentRoomBlocked("auth_session_invalidated")
	self:ClearOnlineOptionsReadyDeadline("auth_session_invalidated")
	self:ResetRealtimeState()
	self:ClearTransientSecrets()

	MESSAGEMAN:Broadcast("ITGOnlineSessionInvalidated", {
		reason = reason,
		message = message,
		payload = payload,
	})
	MESSAGEMAN:Broadcast("ITGOnlineLoginStateChanged")

	online_flow_trace("auth_session_invalidate_end reason=" .. reason
		.. " syncGeneration=" .. tostring(self.syncGeneration or "nil")
		.. " realtimeGeneration=" .. tostring(self.realtimeGeneration or "nil")
		.. " disconnecting=" .. tostring(self.disconnecting == true)
		.. " sessionExpired=" .. tostring(self.sessionExpired == true)
		.. " authInvalidated=" .. tostring(self.authSessionInvalidated == true))
end

function ITGOnline:UnlinkLocalProfile()
	local hadStoredToken = self:HasStoredAccessToken()
	local hadActiveToken = tostring(self.token or "") ~= ""

	if hadActiveToken then
		self:Disconnect({ revokeToken = true })
	else
		self:ClearStoredAccessToken()
		self.user = nil
		self.sessionExpired = false
	end

	self:ClearStoredAccessToken()
	online_trace(
		"Local ITG Online profile link cleared; hadStoredToken=" ..
		tostring(hadStoredToken) .. " hadActiveToken=" .. tostring(hadActiveToken)
	)
	MESSAGEMAN:Broadcast("ITGOnlineLocalProfileUnlinked", {
		hadStoredToken = hadStoredToken,
		hadActiveToken = hadActiveToken
	})

	return hadStoredToken or hadActiveToken
end

function ITGOnline:LoadAuthenticatedUser(callback)
	online_flow_trace("auth_load_user_begin"
		.. " hasToken=" .. tostring(self.token ~= nil)
		.. " configured=" .. tostring(self:Configured() == true)
		.. " profileTokenPreferred=" .. tostring(profile_prefers_persistent_online_token() == true))
	if tostring(self.token or "") == "" then
		if callback then callback(false, nil, { errorMessage = "No access token available." }) end
		return
	end

	self:Request("GET", "/me", nil, function(ok, decoded, response)
		if ok and decoded and decoded.user then
			self.user = decoded.user
			self.sessionExpired = false
			if callback then callback(true, decoded.user, decoded) end
			return
		end

		if callback then callback(false, nil, response or decoded or { errorMessage = "Failed to load authenticated user." }) end
	end, true)
end

function ITGOnline:ApplyAccessToken(accessToken, callback)
	online_flow_trace("auth_apply_token_begin hasToken=" .. tostring(tostring(accessToken or "") ~= "")
		.. " disconnecting=" .. tostring(self.disconnecting == true)
		.. " sessionExpired=" .. tostring(self.sessionExpired == true)
		.. " authInvalidated=" .. tostring(self.authSessionInvalidated == true))
	accessToken = tostring(accessToken or "")
	if accessToken == "" then
		if callback then callback(false, nil, { errorMessage = "No access token provided." }) end
		return
	end

	if self.disconnecting then
		online_flow_trace("auth_session_resumed source=apply_access_token previousDisconnecting=true")
	end
	self.token = accessToken
	self.user = nil
	self.disconnecting = false
	self.sessionExpired = false
	self.authSessionInvalidated = false
	self.authSessionInvalidatedReason = ""
	self.authRefreshFailureCount = 0
	self.authRefreshNextAttemptAt = 0

	self:LoadAuthenticatedUser(function(ok, user, decodedOrResponse)
		if not ok then
			self.token = nil
			self.user = nil
			if callback then callback(false, nil, decodedOrResponse) end
			return
		end

		apply_authenticated_user_state(self, user)
		self:StoreAccessToken(accessToken, user)
		if callback then callback(true, user, decodedOrResponse) end
	end)
end

function ITGOnline:StartDeviceLogin(callback)
	online_flow_trace("device_login_begin configured=" .. tostring(self:Configured() == true))
	local config = self:ConnectionConfig()
	self:Request("POST", "/device-login/start", {
		machineLabel = config.deviceName,
		clientVersion = "ITGMania",
		themeVersion = THEME and THEME.GetThemeDisplayName and THEME:GetThemeDisplayName() or "Simply Love",
	}, callback, true, { cancelOnScreenChange = true })
end

function ITGOnline:PollDeviceLogin(sessionId, pollToken, callback)
	online_flow_trace("device_login_poll_begin"
		.. " hasSession=" .. tostring(tostring(sessionId or "") ~= "")
		.. " hasPollToken=" .. tostring(tostring(pollToken or "") ~= ""))
	self:Request("POST", "/device-login/poll", {
		sessionId = sessionId,
		pollToken = pollToken,
	}, callback, true, { cancelOnScreenChange = true })
end

function ITGOnline:ResetRealtimeState()
	online_flow_trace("realtime_state_reset cursor=" .. tostring(self.lastEventCursor or "nil")
		.. " currentRoomId=" .. tostring(self.currentRoomId or "nil")
		.. " pendingJoinRoomId=" .. tostring(self.pendingJoinRoomId or "nil")
		.. " fetchRoomsInFlight=" .. tostring(type(self.fetchRoomInFlightByRoomId) == "table")
		.. " leavingRooms=" .. tostring(type(self.leavingRoomIds) == "table")
		.. " ignoredRooms=" .. tostring(type(self.ignoredRoomEventsUntil) == "table"))
	self.lastEventCursor = 0
	self.fetchRoomInFlightByRoomId = {}
	self.cachedLobbySearchPayload = { lobbies = {}, onlinePlayers = {} }
	self.lastLeaderboardVersionByRoomId = {}
	self.lastLeaderboardRealtimeAt = 0
	self.lastPlayStateVersionByRoomId = {}
	self.lastRoomEventIdByRoomId = {}
	self.lastUnversionedPlayStateFetchAt = 0
	self.lastRoomNotPlayingScoreRejectAt = 0
	self.processedRealtimeEventIds = {}
	self.processedRealtimeEventOrder = {}
	self.leavingRoomIds = {}
	self.ignoredRoomEventsUntil = {}
end

function ITGOnline:ScheduleRealtimeReconnect(reason)
	if self.disconnecting or not self.token then
		return false
	end

	local attempt = math.max(1, (tonumber(self.realtimeReconnectAttempt) or 0) + 1)
	self.realtimeReconnectAttempt = attempt
	local baseDelay = tonumber(self.realtimeReconnectBaseDelaySeconds) or 1.0
	local maxDelay = tonumber(self.realtimeReconnectMaxDelaySeconds) or 10.0
	local delay = math.min(maxDelay, baseDelay * math.pow(2, math.min(attempt - 1, 4)))
	self.realtimeReconnectNextAttemptAt = GetTimeSinceStart() + delay
	online_flow_trace("realtime_reconnect_scheduled reason=" .. tostring(reason or "unknown")
		.. " attempt=" .. tostring(attempt)
		.. " delay=" .. string.format("%.3f", delay)
		.. " nextAt=" .. string.format("%.3f", self.realtimeReconnectNextAttemptAt)
		.. " room=" .. tostring(self.currentRoomId or "nil")
		.. " screen=" .. tostring(self.currentScreenName or "nil"))
	return true
end

function ITGOnline:RealtimeIsConnected()
	return self.socket ~= nil and self.realtimeConnected == true and self.disconnecting ~= true
end

function ITGOnline:RealtimeLastMessageAge()
	return GetTimeSinceStart() - (tonumber(self.lastRealtimeMessageAt) or 0)
end

function ITGOnline:RealtimeIsFresh(maxAgeSeconds)
	if not self:RealtimeIsConnected() then return false end
	local maxAge = tonumber(maxAgeSeconds) or tonumber(self.realtimeStaleSeconds) or 8.0
	return self:RealtimeLastMessageAge() <= maxAge
end

function ITGOnline:RealtimeHealthSnapshot()
	local age = self.RealtimeLastMessageAge and self:RealtimeLastMessageAge() or 999
	local connected = self.RealtimeIsConnected and self:RealtimeIsConnected() or false
	local connecting = self.realtimeConnecting == true
	local staleAt = tonumber(self.realtimeStaleSeconds) or 45.0
	local ghostAt = tonumber(self.realtimeGhostSeconds) or 75.0
	local state = "offline"
	local label = "HTTP ONLY"
	local color = {0.55, 0.55, 0.55, 0.90}

	if self.disconnecting then
		state = "offline"
		label = "OFFLINE"
	elseif connecting then
		state = "reconnecting"
		label = "RECONNEXION"
		color = {1.00, 0.25, 0.20, 1.00}
	elseif connected and age <= staleAt then
		state = "ok"
		label = "ONLINE OK"
		color = {0.10, 1.00, 0.20, 1.00}
	elseif connected and age <= ghostAt then
		state = "stale"
		label = "SYNC..."
		color = {1.00, 0.72, 0.10, 1.00}
	elseif connected then
		state = "ghost"
		label = "RECONNEXION"
		color = {1.00, 0.25, 0.20, 1.00}
	end

	return {
		state = state,
		label = label,
		color = color,
		age = age,
		connected = connected,
		connecting = connecting,
		socket = self.socket ~= nil,
	}
end

function ITGOnline:BroadcastRealtimeHealth(reason)
	local snapshot = self:RealtimeHealthSnapshot()
	local key = tostring(snapshot.state) .. "|" .. tostring(math.floor((tonumber(snapshot.age) or 0) / 5))
	if key ~= tostring(self.lastRealtimeHealthState or "") then
		self.lastRealtimeHealthState = key
		online_flow_trace("realtime_health state=" .. tostring(snapshot.state)
			.. " label=" .. tostring(snapshot.label)
			.. " age=" .. string.format("%.3f", tonumber(snapshot.age) or 0)
			.. " connected=" .. tostring(snapshot.connected == true)
			.. " connecting=" .. tostring(snapshot.connecting == true)
			.. " socket=" .. tostring(snapshot.socket == true)
			.. " reason=" .. tostring(reason or "unknown"))
	end
	MESSAGEMAN:Broadcast("OnlineRealtimeHealth", snapshot)
	return snapshot
end

function ITGOnline:SendRealtimePing(reason)
	if not self.socket then
		online_flow_trace("realtime_ping_skipped reason=no_socket source=" .. tostring(reason or "unknown")
			.. " connected=" .. tostring(self.realtimeConnected == true))
		return false
	end

	local ok, encoded = pcall(JsonEncode, { action = "ping" })
	if not ok or not encoded then
		online_flow_trace("realtime_ping_encode_failed source=" .. tostring(reason or "unknown")
			.. " ok=" .. tostring(ok == true))
		return false
	end

	local sent = self.socket:Send(encoded)
	self.lastRealtimeClientPingAt = GetTimeSinceStart()
	online_flow_trace("realtime_ping_send source=" .. tostring(reason or "unknown")
		.. " sent=" .. tostring(sent == true)
		.. " generation=" .. tostring(self.realtimeGeneration or "nil")
		.. " lastRealtimeAge=" .. string.format("%.3f", self:RealtimeLastMessageAge()))
	if not sent and self.ForceRealtimeReconnect then
		self:ForceRealtimeReconnect("ping_send_failed:" .. tostring(reason or "unknown"))
	end
	return sent == true
end

function ITGOnline:ForceRealtimeReconnect(reason)
	if self.disconnecting or not self.token then
		return false
	end

	online_flow_trace("realtime_force_reconnect reason=" .. tostring(reason or "unknown")
		.. " connected=" .. tostring(self.realtimeConnected == true)
		.. " connecting=" .. tostring(self.realtimeConnecting == true)
		.. " socket=" .. tostring(self.socket ~= nil)
		.. " age=" .. string.format("%.3f", self:RealtimeLastMessageAge())
		.. " generation=" .. tostring(self.realtimeGeneration or "nil")
		.. " room=" .. tostring(self.currentRoomId or "nil")
		.. " screen=" .. tostring(self.currentScreenName or "nil"))

	self.realtimeGeneration = (tonumber(self.realtimeGeneration) or 0) + 1
	if self.socket then
		pcall(function() self.socket:Close() end)
	end
	self.socket = nil
	self.realtimeConnected = false
	self.realtimeConnecting = false
	self.activeRealtimeCallbacks = nil
	self.pendingRealtimeConnectCallbacks = {}

	local handler = GetOnlineHandlerInstance and GetOnlineHandlerInstance() or nil
	if handler then
		handler.socket = nil
		handler.connected = false
	end

	self:ScheduleRealtimeReconnect("forced:" .. tostring(reason or "unknown"))
	if self.currentRoomId and self.ReconcileCurrentRoomAfterRealtimeGap then
		self:ReconcileCurrentRoomAfterRealtimeGap("forced_reconnect:" .. tostring(reason or "unknown"), 0)
	end
	self:BroadcastRealtimeHealth("forced_reconnect")
	return true
end

function ITGOnline:ReconcileCurrentRoomAfterRealtimeGap(source, minIntervalSeconds)
	local now = GetTimeSinceStart()
	local minInterval = tonumber(minIntervalSeconds) or tonumber(self.criticalRoomActionResyncMinIntervalSeconds) or 0.75
	local age = self:RealtimeLastMessageAge()
	local fresh = self:RealtimeIsFresh()
	local connected = self:RealtimeIsConnected()
	if fresh and connected then
		online_flow_trace("critical_room_reconcile_skipped reason=realtime_fresh"
			.. " source=" .. tostring(source or "unknown")
			.. " age=" .. string.format("%.3f", age)
			.. " room=" .. tostring(self.currentRoomId or "nil"))
		return false
	end
	if now - (tonumber(self.lastCriticalRoomActionResyncAt) or 0) < minInterval then
		online_flow_trace("critical_room_reconcile_skipped reason=throttled"
			.. " source=" .. tostring(source or "unknown")
			.. " age=" .. string.format("%.3f", age)
			.. " connected=" .. tostring(connected == true)
			.. " minInterval=" .. tostring(minInterval)
			.. " room=" .. tostring(self.currentRoomId or "nil"))
		return false
	end

	self.lastCriticalRoomActionResyncAt = now
	online_flow_trace("critical_room_reconcile_begin source=" .. tostring(source or "unknown")
		.. " age=" .. string.format("%.3f", age)
		.. " connected=" .. tostring(connected == true)
		.. " socket=" .. tostring(self.socket ~= nil)
		.. " room=" .. tostring(self.currentRoomId or "nil")
		.. " phase=" .. tostring(self.currentRoom and self.currentRoom.phase or "nil"))

	if not connected and self.ScheduleRealtimeReconnect then
		self:ScheduleRealtimeReconnect("critical_room_reconcile:" .. tostring(source or "unknown"))
	end
	if self.currentRoomId and self.FetchCurrentRoomFallback then
		self:FetchCurrentRoomFallback("critical_room_reconcile:" .. tostring(source or "unknown"), 0)
	elseif self.Sync then
		self:Sync()
	end
	return true
end

function ITGOnline:MaintainRealtimeAndRoomSync(source)
	if self.disconnecting or not self.token then
		return false
	end

	local now = GetTimeSinceStart()
	local screenName = tostring(self.currentScreenName or "NoScreen")
	local roomId = self.currentRoomId or self.pendingJoinRoomId
	local onlineContext = self:IsOnlineLobbyScreen(screenName)
		or self:IsOnlineOptionsScreen(screenName)
		or self:IsOnlineGameplayScreen(screenName)
		or roomId ~= nil
	if not onlineContext then
		return false
	end

	local didWork = false
	if self.realtimeConnected and not self.realtimeConnecting then
		local age = self:RealtimeLastMessageAge()
		local ghostAt = tonumber(self.realtimeGhostSeconds) or 75.0
		if age > ghostAt then
			online_flow_trace("realtime_ghost_detected source=" .. tostring(source or "unknown")
				.. " age=" .. string.format("%.3f", age)
				.. " ghostAt=" .. string.format("%.3f", ghostAt)
				.. " socket=" .. tostring(self.socket ~= nil)
				.. " room=" .. tostring(roomId or "nil")
				.. " screen=" .. screenName)
			self:ForceRealtimeReconnect("ghost_timeout:" .. tostring(source or "unknown"))
			didWork = true
		end
	end

	if not self.realtimeConnected and not self.realtimeConnecting then
		local nextAttemptAt = tonumber(self.realtimeReconnectNextAttemptAt) or 0
		if now >= nextAttemptAt then
			online_flow_trace("realtime_reconnect_attempt source=" .. tostring(source or "unknown")
				.. " attempt=" .. tostring((tonumber(self.realtimeReconnectAttempt) or 0) + 1)
				.. " room=" .. tostring(roomId or "nil")
				.. " screen=" .. screenName
				.. " cursor=" .. tostring(self.lastEventCursor or "nil"))
			self:ConnectWebSocket({
				open = function()
					self.realtimeReconnectAttempt = 0
					self.realtimeReconnectNextAttemptAt = 0
					online_flow_trace("realtime_reconnect_open source=" .. tostring(source or "unknown")
						.. " room=" .. tostring(self.currentRoomId or "nil")
						.. " cursor=" .. tostring(self.lastEventCursor or "nil"))
					if self.Sync then self:Sync() end
					if self.currentRoomId and self.FetchCurrentRoomFallback then
						self:FetchCurrentRoomFallback("realtime_reconnect_open", 0.1)
					end
				end,
				close = function(reason)
					self:ScheduleRealtimeReconnect("connect_close:" .. tostring(reason or "unknown"))
				end,
				error = function(reason)
					self:ScheduleRealtimeReconnect("connect_error:" .. tostring(reason or "unknown"))
				end,
			})
			didWork = true
		end
	end
	if self.BroadcastRealtimeHealth then
		self:BroadcastRealtimeHealth(source)
	end

	if roomId then
		local realtimeFresh = self.RealtimeIsFresh and self:RealtimeIsFresh() or false
		local interval = realtimeFresh
			and (tonumber(self.currentRoomWatchdogRealtimeIntervalSeconds) or 4.0)
			or (tonumber(self.currentRoomWatchdogIntervalSeconds) or 2.0)
		local elapsed = now - (tonumber(self.lastCurrentRoomWatchdogAt) or 0)
		if elapsed >= interval then
			self.lastCurrentRoomWatchdogAt = now
			online_flow_trace("current_room_watchdog_tick source=" .. tostring(source or "unknown")
				.. " room=" .. tostring(roomId)
				.. " screen=" .. screenName
				.. " phase=" .. tostring(self.currentRoom and self.currentRoom.phase or "nil")
				.. " realtimeConnected=" .. tostring(self.realtimeConnected == true)
				.. " realtimeConnecting=" .. tostring(self.realtimeConnecting == true)
				.. " lastSyncAge=" .. string.format("%.3f", now - (tonumber(self.lastSyncRequestedAt) or 0))
				.. " lastRealtimeAge=" .. string.format("%.3f", now - (tonumber(self.lastRealtimeMessageAt) or 0)))
			if self.FetchCurrentRoomFallback then
				self:FetchCurrentRoomFallback("current_room_watchdog:" .. tostring(source or "unknown"), 1.0)
			end
			local syncInterval = realtimeFresh and 6.0 or 2.0
			if self.Sync and not self.syncInFlight and (now - (tonumber(self.lastSyncRequestedAt) or 0)) >= syncInterval then
				online_flow_trace("current_room_watchdog_sync source=" .. tostring(source or "unknown")
					.. " room=" .. tostring(roomId)
					.. " syncInterval=" .. tostring(syncInterval))
				self:Sync()
			end
			didWork = true
		end
	end

	return didWork
end

function ITGOnline:RoomKey(roomId)
	if roomId == nil then return "" end
	local numeric = tonumber(roomId)
	if numeric then return tostring(math.floor(numeric)) end
	return tostring(roomId)
end

function ITGOnline:IsLeavingRoom(roomId)
	local key = self:RoomKey(roomId)
	return key ~= "" and self.leavingRoomIds and self.leavingRoomIds[key] == true
end

function ITGOnline:MarkLeavingRoom(roomId, leaving)
	local key = self:RoomKey(roomId)
	if key == "" then return end
	self.leavingRoomIds = self.leavingRoomIds or {}
	online_flow_trace("leaving_room_flag_update room=" .. tostring(key)
		.. " leaving=" .. tostring(leaving ~= false)
		.. " previous=" .. tostring(self.leavingRoomIds[key] == true)
		.. " currentRoomId=" .. tostring(self.currentRoomId or "nil")
		.. " phase=" .. tostring(self.currentRoom and self.currentRoom.phase or "nil"))
	if leaving == false then
		self.leavingRoomIds[key] = nil
	else
		self.leavingRoomIds[key] = true
	end
end

function ITGOnline:IgnoreRoomEvents(roomId, seconds)
	local key = self:RoomKey(roomId)
	if key == "" then return end
	self.ignoredRoomEventsUntil = self.ignoredRoomEventsUntil or {}
	self.ignoredRoomEventsUntil[key] = GetTimeSinceStart() + (tonumber(seconds) or 30)
	online_flow_trace("ignore_room_events_set room=" .. tostring(key)
		.. " seconds=" .. tostring(tonumber(seconds) or 30)
		.. " until=" .. tostring(self.ignoredRoomEventsUntil[key])
		.. " currentRoomId=" .. tostring(self.currentRoomId or "nil"))
end

function ITGOnline:ShouldIgnoreRoomEvents(roomId)
	local key = self:RoomKey(roomId)
	if key == "" then return false end
	local untilTime = self.ignoredRoomEventsUntil and tonumber(self.ignoredRoomEventsUntil[key]) or nil
	if not untilTime then return false end
	if GetTimeSinceStart() <= untilTime then
		online_flow_trace("ignore_room_events_active room=" .. tostring(key)
			.. " remaining=" .. tostring(untilTime - GetTimeSinceStart())
			.. " currentRoomId=" .. tostring(self.currentRoomId or "nil"))
		return true
	end
	self.ignoredRoomEventsUntil[key] = nil
	online_flow_trace("ignore_room_events_expired room=" .. tostring(key))
	return false
end

function ITGOnline:SuppressLobbyRefresh(seconds, reason)
	local duration = tonumber(seconds) or 1
	self.lobbyRefreshSuppressedUntil = math.max(
		tonumber(self.lobbyRefreshSuppressedUntil) or 0,
		GetTimeSinceStart() + duration)
	online_flow_trace("lobby_refresh_suppressed duration=" .. tostring(duration)
		.. " reason=" .. tostring(reason or "unknown"))
end

function ITGOnline:IsLobbyRefreshSuppressed()
	local untilTime = tonumber(self.lobbyRefreshSuppressedUntil) or 0
	if untilTime <= 0 then return false end
	if GetTimeSinceStart() <= untilTime then
		return true
	end
	self.lobbyRefreshSuppressedUntil = nil
	return false
end

	function ITGOnline:LobbyRefreshSuppressionRemaining()
		local untilTime = tonumber(self.lobbyRefreshSuppressedUntil) or 0
		return math.max(0, untilTime - GetTimeSinceStart())
	end

	function ITGOnline:SuppressAutomaticLobbyRefresh(seconds, reason)
		local duration = tonumber(seconds) or 5
		self.lobbyRefreshDropUntil = math.max(
			tonumber(self.lobbyRefreshDropUntil) or 0,
			GetTimeSinceStart() + duration)
		self.lobbyRefreshQueued = false
		self.lobbyRefreshDeferredScheduled = false
		online_flow_trace("lobby_refresh_auto_suppressed duration=" .. tostring(duration)
			.. " reason=" .. tostring(reason or "unknown"))
	end

	function ITGOnline:IsAutomaticLobbyRefreshSuppressed()
		if self.currentRoomId ~= nil then
			self.lobbyRefreshDropUntil = nil
			return false
		end
		local untilTime = tonumber(self.lobbyRefreshDropUntil) or 0
		if untilTime <= 0 then return false end
		if GetTimeSinceStart() <= untilTime then
			return true
		end
		self.lobbyRefreshDropUntil = nil
		return false
	end

	function ITGOnline:ClearLobbyRefreshSuppression(reason)
		self.lobbyRefreshSuppressedUntil = nil
		self.lobbyRefreshDropUntil = nil
		self.lobbyRefreshDeferredScheduled = false
		self.deferredLobbyRefreshReason = ""
		self.lobbyRefreshQueued = false
		online_flow_trace("lobby_refresh_suppression_cleared reason=" .. tostring(reason or "unknown")
			.. " currentRoomId=" .. tostring(self.currentRoomId or "nil")
			.. " screen=" .. tostring(self.currentScreenName or "nil"))
	end

	function ITGOnline:InvalidateRoomUiLobbyRefresh(reason)
		self.roomUiLobbyRefreshGeneration = (tonumber(self.roomUiLobbyRefreshGeneration) or 0) + 1
		self.roomUiLobbyRefreshDeferredScheduled = false
		if tostring(self.deferredLobbyRefreshReason or ""):sub(1, 16) == "room_ui_refresh:" then
			self.deferredLobbyRefreshRoomUiGeneration = nil
		end
		online_flow_trace("room_ui_lobby_refresh_invalidated reason=" .. tostring(reason or "unknown")
			.. " generation=" .. tostring(self.roomUiLobbyRefreshGeneration))
	end

	function ITGOnline:ScheduleDeferredLobbyRefresh(delay, reason)
		local source = tostring(reason or "unknown")
		local roomUiGeneration = nil
		if source:sub(1, 16) == "room_ui_refresh:" then
			roomUiGeneration = tonumber(self.roomUiLobbyRefreshGeneration) or 0
		end
		online_flow_trace("lobby_refresh_deferred_schedule_begin"
			.. " source=" .. tostring(source)
			.. " delay=" .. tostring(delay)
			.. " roomUiGeneration=" .. tostring(roomUiGeneration or "nil")
			.. " deferredAlready=" .. tostring(self.lobbyRefreshDeferredScheduled == true)
			.. " deferredReason=" .. tostring(self.deferredLobbyRefreshReason or "nil")
			.. " automaticSuppressed=" .. tostring(self:IsAutomaticLobbyRefreshSuppressed() == true)
			.. " suppressed=" .. tostring(self:IsLobbyRefreshSuppressed() == true)
			.. " currentRoomId=" .. tostring(self.currentRoomId or "nil")
			.. " screen=" .. tostring(self.currentScreenName or "nil"))
		if self:IsAutomaticLobbyRefreshSuppressed() then
			if self.lobbyRefreshDeferredScheduled
				and tostring(self.deferredLobbyRefreshReason or ""):sub(1, 11) == "post_leave:" then
				online_flow_trace(
					"lobby_refresh_deferred_post_leave_ignored reason=duplicate_existing" ..
					" source=" .. source ..
					" existing=" .. tostring(self.deferredLobbyRefreshReason or "nil"))
				return
			end
			online_flow_trace(
				"lobby_refresh_deferred_post_leave delay=" .. tostring(delay) ..
				" source=" .. source)
			self.lobbyRefreshDeferredScheduled = true
			self.deferredLobbyRefreshReason = "post_leave:" .. source
			online_flow_trace("lobby_refresh_deferred_broadcast"
				.. " source=" .. source
				.. " broadcastReason=" .. tostring(self.deferredLobbyRefreshReason)
				.. " delay=" .. tostring(math.max(0.05, tonumber(delay) or 0.05))
				.. " mode=post_leave")
			MESSAGEMAN:Broadcast("ITGOnlineLobbyRefreshDeferred", {
				delay = math.max(0.05, tonumber(delay) or 0.05),
				reason = "post_leave:" .. source,
				roomUiGeneration = roomUiGeneration,
			})
			return
		end
		self.deferredLobbyRefreshReason = source
		self.deferredLobbyRefreshRoomUiGeneration = roomUiGeneration
		self.lobbyRefreshDeferredScheduled = true
		online_flow_trace("lobby_refresh_deferred_broadcast"
			.. " source=" .. source
			.. " broadcastReason=" .. tostring(self.deferredLobbyRefreshReason)
			.. " delay=" .. tostring(math.max(0.05, tonumber(delay) or 0.05))
			.. " mode=normal"
			.. " roomUiGeneration=" .. tostring(roomUiGeneration or "nil"))
		MESSAGEMAN:Broadcast("ITGOnlineLobbyRefreshDeferred", {
			delay = math.max(0.05, tonumber(delay) or 0.05),
			reason = source,
			roomUiGeneration = roomUiGeneration,
		})
	end

	function ITGOnline:ScheduleCoalescedLobbyRefresh(reason, delay)
		local refreshDelay = math.max(
			0.05,
			tonumber(delay) or tonumber(self.lobbyRefreshReplayDelaySeconds) or 0.20)
		local roomSnapshotAge = GetTimeSinceStart() - (tonumber(self.lastAuthoritativeRoomSnapshotAt) or 0)
		if self.currentRoomId
			and roomSnapshotAge >= 0
			and roomSnapshotAge < 0.50 then
			online_flow_trace("lobby_refresh_coalesced_skipped reason=recent_room_snapshot"
				.. " requestReason=" .. tostring(reason or "unknown")
				.. " age=" .. string.format("%.3f", roomSnapshotAge)
				.. " currentRoomId=" .. tostring(self.currentRoomId or "nil")
				.. " snapshotSource=" .. tostring(self.lastAuthoritativeRoomSnapshotSource or "nil")
				.. " screen=" .. tostring(self.currentScreenName or "nil"))
			return
		end
		if self.lobbyRefreshDeferredScheduled then
			online_flow_trace("lobby_refresh_coalesced_existing reason=" .. tostring(reason or "unknown")
				.. " delay=" .. tostring(refreshDelay)
				.. " existingReason=" .. tostring(self.deferredLobbyRefreshReason or "nil")
				.. " currentRoomId=" .. tostring(self.currentRoomId or "nil")
				.. " screen=" .. tostring(self.currentScreenName or "nil"))
			return
		end
		online_flow_trace("lobby_refresh_coalesced_scheduled reason=" .. tostring(reason or "unknown")
			.. " delay=" .. tostring(refreshDelay)
			.. " lastAppliedAge=" .. tostring(GetTimeSinceStart() - (tonumber(self.lobbyRefreshLastAppliedAt) or 0))
			.. " currentRoomId=" .. tostring(self.currentRoomId or "nil")
			.. " screen=" .. tostring(self.currentScreenName or "nil")
			.. " automaticSuppressed=" .. tostring(self:IsAutomaticLobbyRefreshSuppressed() == true)
			.. " suppressed=" .. tostring(self:IsLobbyRefreshSuppressed() == true))
		self:ScheduleDeferredLobbyRefresh(refreshDelay, "coalesced:" .. tostring(reason or "unknown"))
	end

	function ITGOnline:RequestLobbyRefresh(reason, options)
		options = type(options) == "table" and options or {}
		local source = tostring(reason or options.reason or "unknown")
		if options.immediate == true then
			online_flow_trace("lobby_refresh_requested source=" .. source
				.. " mode=immediate"
				.. " forceFresh=" .. tostring(options.forceFresh == true)
				.. " currentRoomId=" .. tostring(self.currentRoomId or "nil")
				.. " inFlight=" .. tostring(self.lobbyRefreshInFlight == true)
				.. " queued=" .. tostring(self.lobbyRefreshQueued == true)
				.. " deferred=" .. tostring(self.lobbyRefreshDeferredScheduled == true)
				.. " automaticSuppressed=" .. tostring(self:IsAutomaticLobbyRefreshSuppressed() == true)
				.. " suppressed=" .. tostring(self:IsLobbyRefreshSuppressed() == true)
				.. " screen=" .. tostring(self.currentScreenName or "nil"))
			self:QueueLobbyRefresh({
				reason = source,
				forceFresh = options.forceFresh == true,
				ignoreSuppression = options.ignoreSuppression == true,
			})
			return true
		end

		local delay = tonumber(options.delay)
		online_flow_trace("lobby_refresh_requested source=" .. source
			.. " mode=coalesced"
			.. " delay=" .. tostring(delay or self.lobbyRefreshReplayDelaySeconds or 0.20)
			.. " currentRoomId=" .. tostring(self.currentRoomId or "nil")
			.. " inFlight=" .. tostring(self.lobbyRefreshInFlight == true)
			.. " queued=" .. tostring(self.lobbyRefreshQueued == true)
			.. " deferred=" .. tostring(self.lobbyRefreshDeferredScheduled == true)
			.. " automaticSuppressed=" .. tostring(self:IsAutomaticLobbyRefreshSuppressed() == true)
			.. " suppressed=" .. tostring(self:IsLobbyRefreshSuppressed() == true)
			.. " screen=" .. tostring(self.currentScreenName or "nil"))
		self:ScheduleCoalescedLobbyRefresh(source, delay)
		return true
	end

	function ITGOnline:HasLobbyRefreshScheduler()
		return self.QueueLobbyRefresh ~= nil
			and self.ScheduleCoalescedLobbyRefresh ~= nil
			and self.RequestLobbyRefresh ~= nil
	end

function ITGOnline:CurrentRoomConflictCode(decoded, response)
	local currentRoomMeta = sync_current_room_meta(decoded)
	local metaErrorCode = currentRoomMeta and currentRoomMeta.error_code or nil
	if tostring(metaErrorCode or "") == "multiple_open_rooms" then
		return "multiple_open_rooms", tonumber(currentRoomMeta.open_room_count)
	end

	local errorCode = response_error_code(response, decoded)
	if errorCode == "multiple_open_rooms" then
		return "multiple_open_rooms", nil
	end

	return "", nil
end

function ITGOnline:SetCurrentRoomBlocked(errorCode, openRoomCount, source)
	errorCode = tostring(errorCode or "")
	if errorCode == "" then return false end

	self.currentRoomBlockedReason = errorCode
	self.currentRoomBlockedOpenCount = tonumber(openRoomCount) or self.currentRoomBlockedOpenCount
	local noticeKey = errorCode .. "|" .. tostring(self.currentRoomBlockedOpenCount or "")
	online_trace("Current room blocked source=" .. tostring(source or "unknown")
		.. " error=" .. tostring(errorCode)
		.. " open_room_count=" .. tostring(self.currentRoomBlockedOpenCount or "unknown"))

	if self.currentRoomBlockedLastNoticeKey ~= noticeKey then
		self.currentRoomBlockedLastNoticeKey = noticeKey
		MESSAGEMAN:Broadcast("OnlineResponseStatus", {
			event = "current_room",
			success = false,
			error_code = errorCode,
			message = "Plusieurs salons ouverts detectes. Quittez les anciens salons puis relancez la synchronisation."
		})
	end

	return true
end

function ITGOnline:ClearCurrentRoomBlocked(source)
	if tostring(self.currentRoomBlockedReason or "") == "" then return end
	online_trace("Current room block cleared source=" .. tostring(source or "unknown")
		.. " previous=" .. tostring(self.currentRoomBlockedReason))
	self.currentRoomBlockedReason = ""
	self.currentRoomBlockedOpenCount = nil
	self.currentRoomBlockedLastNoticeKey = ""
end

function ITGOnline:RequestCanRetry(record)
	if not record then
		online_flow_trace("request_retry_denied reason=no_record")
		return false
	end
	if record.cancelled then
		online_flow_trace("request_retry_denied reason=cancelled"
			.. " requestId=" .. tostring(record.requestId or "nil")
			.. " traceId=" .. tostring(record.traceId or "nil"))
		return false
	end
	if record.cancelGeneration and record.cancelGeneration ~= self.requestCancelGeneration then
		online_flow_trace("request_retry_denied reason=cancel_generation_changed"
			.. " requestId=" .. tostring(record.requestId or "nil")
			.. " traceId=" .. tostring(record.traceId or "nil")
			.. " recordGeneration=" .. tostring(record.cancelGeneration)
			.. " currentGeneration=" .. tostring(self.requestCancelGeneration))
		return false
	end
	if record.cancelOnScreenChange and record.screenGeneration ~= self.screenGeneration then
		self.needsSyncAfterScreenCancel = true
		online_flow_trace("request_retry_denied reason=screen_generation_changed"
			.. " requestId=" .. tostring(record.requestId or "nil")
			.. " traceId=" .. tostring(record.traceId or "nil")
			.. " requestScreenGeneration=" .. tostring(record.screenGeneration)
			.. " currentScreenGeneration=" .. tostring(self.screenGeneration)
			.. " path=" .. tostring(record.path or "nil"))
		return false
	end
	return true
end

function ITGOnline:Configured()
	return self:HasStoredCredentials()
end

function ITGOnline:HasStoredCredentials()
	local config = self:ConnectionConfig()
	if tostring(config.accessToken or "") ~= "" then return true end
	if config.email == "" then return false end

	local transientPassword = tostring(self.transientPassword or "")
	if transientPassword ~= "" then return true end

	local storedPassword = secure_password_get(config.apiBaseUrl, config.email)
	local hasPassword = storedPassword ~= nil and tostring(storedPassword) ~= ""
	storedPassword = nil
	return hasPassword
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
	local config = self:ConnectionConfig()
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
		requestId = requestId,
		traceId = traceId,
		method = method,
		path = path,
		future = nil,
		cancelled = false,
		cancelOnScreenChange = options.cancelOnScreenChange == true,
		resyncAfterCancel = options.resyncAfterCancel ~= false and options.cancelOnScreenChange == true,
		screenGeneration = self.screenGeneration,
		cancelGeneration = self.requestCancelGeneration,
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
	online_flow_trace("http_request_begin id=" .. tostring(requestId)
		.. " traceId=" .. tostring(traceId)
		.. " method=" .. tostring(method)
		.. " path=" .. tostring(path)
		.. " hasPayload=" .. tostring(payload ~= nil)
		.. " cancelOnScreenChange=" .. tostring(options.cancelOnScreenChange == true)
		.. " screenGeneration=" .. tostring(self.screenGeneration or "nil")
		.. " cancelGeneration=" .. tostring(self.requestCancelGeneration or "nil")
		.. " currentScreen=" .. tostring(self.currentScreenName or "nil")
		.. " room=" .. tostring(self.currentRoomId or "nil"))
	self:TraceOnlineState("http_request_begin", {
		source = "http_request",
		requestId = requestId,
		traceId = traceId,
		method = method,
		path = path,
		hasPayload = payload ~= nil,
		cancelOnScreenChange = options.cancelOnScreenChange == true,
		screenGeneration = self.screenGeneration or "nil",
		cancelGeneration = self.requestCancelGeneration or "nil",
	})
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
				online_flow_trace("http_response_ignored id=" .. tostring(requestId)
					.. " traceId=" .. tostring(traceId)
					.. " reason=cancelled"
					.. " method=" .. tostring(method)
					.. " path=" .. tostring(path)
					.. " status=" .. tostring(response and response.statusCode or "nil")
					.. " resyncAfterCancel=" .. tostring(record.resyncAfterCancel == true))
				if record.resyncAfterCancel and self.Sync then
					self.needsSyncAfterScreenCancel = true
					self:Sync()
				end
				return
			end
			if not record then
				online_flow_trace("http_response_ignored id=" .. tostring(requestId)
					.. " traceId=" .. tostring(traceId)
					.. " reason=no_record"
					.. " method=" .. tostring(method)
					.. " path=" .. tostring(path)
					.. " status=" .. tostring(response and response.statusCode or "nil"))
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
			online_flow_trace("http_response id=" .. tostring(requestId)
				.. " traceId=" .. tostring(traceId)
				.. " method=" .. tostring(method)
				.. " path=" .. tostring(path)
				.. " ok=" .. tostring(ok == true)
				.. " status=" .. tostring(response and response.statusCode or "nil")
				.. " durationMs=" .. tostring(duration)
				.. " bytes=" .. tostring(responseBytes)
				.. " error=" .. tostring(errorCode or "nil")
				.. " currentScreen=" .. tostring(self.currentScreenName or "nil")
				.. " currentGeneration=" .. tostring(self.screenGeneration or "nil")
				.. " requestGeneration=" .. tostring(record.screenGeneration or "nil")
				.. " room=" .. tostring(self.currentRoomId or "nil"))
			self:TraceOnlineState("http_response", {
				source = "http_request",
				requestId = requestId,
				traceId = traceId,
				method = method,
				path = path,
				ok = ok == true,
				status = response and response.statusCode or "nil",
				durationMs = duration,
				bytes = responseBytes,
				error = errorCode or "nil",
				requestGeneration = record.screenGeneration or "nil",
				currentGeneration = self.screenGeneration or "nil",
			})
			if not ok and decoded and decoded.message then
				online_trace(method .. " " .. path .. " message: " .. tostring(decoded.message))
			end

			if response and response.statusCode == 401 and path ~= "/auth/login" and path ~= "/auth/refresh" and not self.disconnecting and not alreadyRetriedAuth then
				local retryRecord = record
					online_flow_trace("http_auth_retry_begin id=" .. tostring(requestId)
						.. " traceId=" .. tostring(traceId)
						.. " method=" .. tostring(method)
						.. " path=" .. tostring(path)
						.. " authFailures=" .. tostring(self.authRefreshFailureCount or 0))
					if (self.authRefreshFailureCount or 0) >= (self.maxAuthRefreshFailures or 3) then
						self.sessionExpired = true
						if self.socket then self.socket:Close() end
						self.socket = nil
						self:ClearStoredAccessToken()
						self:ClearTransientSecrets()
						MESSAGEMAN:Broadcast("OnlineSessionExpired")
						if callback then callback(false, decoded, response) end
						return
				end

				self:Relogin(function(loginOk)
					online_flow_trace("http_auth_retry_login_result id=" .. tostring(requestId)
						.. " traceId=" .. tostring(traceId)
						.. " ok=" .. tostring(loginOk == true)
						.. " path=" .. tostring(path))
					if loginOk then
						if not self:RequestCanRetry(retryRecord) then
							if callback then callback(false, nil, { cancelled = true, errorMessage = "Request was cancelled before auth retry." }) end
							return
						end
						online_flow_trace("http_auth_retry_replay id=" .. tostring(requestId)
							.. " traceId=" .. tostring(traceId)
							.. " method=" .. tostring(method)
							.. " path=" .. tostring(path))
						self:Request(method, path, payload, callback, true, options)
						return
					end

						self.sessionExpired = true
						if self.socket then self.socket:Close() end
						self.socket = nil
						self:ClearStoredAccessToken()
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
	local count = 0
	for _, _ in pairs(self.requests or {}) do
		count = count + 1
	end
	self.requestCancelGeneration = (tonumber(self.requestCancelGeneration) or 0) + 1
	online_flow_trace("cancel_pending_requests generation=" .. tostring(self.requestCancelGeneration)
		.. " count=" .. tostring(count)
		.. " screen=" .. tostring(self.currentScreenName or "nil")
		.. " room=" .. tostring(self.currentRoomId or "nil")
		.. " phase=" .. tostring(self.currentRoom and self.currentRoom.phase or "nil"))
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
	local cancelledCount = 0
	local cancelledLobbyRequest = false
	for requestId, request in pairs(self.requests or {}) do
		if request.cancelOnScreenChange == true and request.screenGeneration ~= self.screenGeneration then
			request.cancelled = true
			cancelledCount = cancelledCount + 1
			local requestPath = tostring(request.path or "")
			if requestPath:match("^/lobby") or requestPath:find("/lobby?", 1, true) then
				cancelledLobbyRequest = true
			end
			online_flow_trace("screen_bound_request_cancelled id=" .. tostring(requestId)
				.. " traceId=" .. tostring(request.traceId or "nil")
				.. " method=" .. tostring(request.method or "nil")
				.. " path=" .. tostring(request.path or "nil")
				.. " requestScreenGeneration=" .. tostring(request.screenGeneration or "nil")
				.. " currentScreenGeneration=" .. tostring(self.screenGeneration or "nil")
				.. " currentScreen=" .. tostring(self.currentScreenName or "nil")
				.. " cancelGeneration=" .. tostring(self.requestCancelGeneration or "nil"))
			if request.future and request.future.Cancel then
				request.future:Cancel()
			end
			self.requests[requestId] = nil
			cancelledAny = true
		end
	end
	if cancelledAny then
		self.requestCancelGeneration = (tonumber(self.requestCancelGeneration) or 0) + 1
		self.needsSyncAfterScreenCancel = true
		if cancelledLobbyRequest then
			self.lobbyRefreshInFlight = false
			self.lobbyRefreshQueued = true
			self.lobbyRefreshQueuedReason = "screen_bound_lobby_request_cancelled"
			self.lobbyRefreshQueuedAt = GetTimeSinceStart()
		end
		online_flow_trace("screen_bound_requests_cancelled count=" .. tostring(cancelledCount)
			.. " newCancelGeneration=" .. tostring(self.requestCancelGeneration)
			.. " needsSyncAfterScreenCancel=true"
			.. " cancelledLobbyRequest=" .. tostring(cancelledLobbyRequest == true)
			.. " lobbyRefreshInFlight=" .. tostring(self.lobbyRefreshInFlight == true)
			.. " disconnecting=" .. tostring(self.disconnecting == true))
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
	if not room or not self.user then return false end
	local currentUserId = tostring(self.user.id or "")
	if currentUserId == "" then return false end

	local manager = type(room.manager) == "table" and room.manager or nil
	local managerId = room.manager_user_id or room.managerUserId or (manager and manager.id) or nil
	if managerId ~= nil and tostring(managerId) == currentUserId then return true end

	for member in ivalues(room.members or {}) do
		local memberUser = type(member.user) == "table" and member.user or {}
		local memberUserId = member.user_id or member.userId or memberUser.id or nil
		local role = tostring(member.role or member.member_role or member.memberRole or "")
		if memberUserId ~= nil and tostring(memberUserId) == currentUserId and role == "manager" then
			return true
		end
	end

	return false
end

function ITGOnline:RoomMatchesId(room, roomId)
	if not room or not room.id or roomId == nil then return false end
	if tonumber(room.id) ~= nil and tonumber(roomId) ~= nil then
		return tonumber(room.id) == tonumber(roomId)
	end
	return tostring(room.id) == tostring(roomId)
end

function ITGOnline:EnsureCurrentRoom(callback)
	if tostring(self.currentRoomBlockedReason or "") ~= "" then
		if callback then callback(false, nil, {
			error_code = self.currentRoomBlockedReason,
			errorMessage = "Current room is blocked by an unresolved server state."
		}) end
		return
	end

	if self.currentRoomId
		and self.currentRoom
		and self:RoomMatchesId(self.currentRoom, self.currentRoomId)
		and self.currentRoom.manager
		and self.user then
		if callback then callback(true, self.currentRoom, nil) end
		return
	end

	local roomId = self.currentRoomId
	if roomId and self.FetchRoom then
		online_flow_trace("ensure_current_room source=fetch_room room=" .. tostring(roomId)
			.. " hasRoom=" .. tostring(self.currentRoom ~= nil)
			.. " hasManager=" .. tostring(self.currentRoom and self.currentRoom.manager ~= nil)
			.. " hasUser=" .. tostring(self.user ~= nil))
		self:FetchRoom(roomId, function(ok, decoded, response)
			local room = decoded and decoded.room or nil
			if not room and self:RoomMatchesId(self.currentRoom, roomId) then
				room = self.currentRoom
			end
			if callback then callback(ok and room ~= nil and self:RoomMatchesId(room, roomId), room, response) end
		end)
		return
	end

	if self.Sync then
		online_flow_trace("ensure_current_room source=sync room=nil")
		self:Sync(function(ok, decoded, response)
			local conflictCode = self:CurrentRoomConflictCode(decoded, response)
			if conflictCode ~= "" then
				if callback then callback(false, nil, {
					error_code = conflictCode,
					errorMessage = "Current room is blocked by multiple open rooms."
				}) end
				return
			end

			local room = decoded and decoded.current_room or self.currentRoom
			if callback then callback(ok and room ~= nil, room, response) end
		end)
		return
	end

	if callback then callback(false, nil, { errorMessage = "No current room available." }) end
end

function ITGOnline:IsCurrentUserReadyInRoom(room, phase)
	if not room or not self.user then return false end
	if tostring(phase or "") == "config_ready" and self:CurrentUserHasOptimisticConfigReady(room) then
		online_flow_trace("current_user_ready_state result=true reason=optimistic_config_ready"
			.. " room=" .. tostring(room.id or self.currentRoomId or "nil")
			.. " phase=" .. tostring(room.phase or "nil"))
		return true
	end
	if not room.ready_states then return false end
	local currentUserId = tonumber(self.user.id)
	if not currentUserId then return false end
	local expectedPhase = tostring(phase or "")

	for state in ivalues(room.ready_states or {}) do
		local stateUserId = tonumber((state.user and state.user.id) or state.user_id)
		if stateUserId == currentUserId then
			if expectedPhase ~= "" then
				local statePhase = tostring(state.phase or state.ready_phase or state.readyPhase or "")
				if statePhase ~= expectedPhase then
					online_flow_trace("current_user_ready_state_ignored reason=phase_mismatch"
						.. " expected=" .. tostring(expectedPhase)
						.. " actual=" .. tostring(statePhase)
						.. " room=" .. tostring(room.id or self.currentRoomId or "nil"))
					return false
				end
			end
			return state.is_ready and true or false
		end
	end

	return false
end

function ITGOnline:CurrentUserConfirmedSelectedSong(room)
	room = room or self.currentRoom
	if not room or not self.user then
		online_flow_trace("current_user_song_confirmation result=false reason=missing_context"
			.. " hasRoom=" .. tostring(room ~= nil)
			.. " hasUser=" .. tostring(self.user ~= nil))
		return false, "missing_context"
	end
	local selectedSong = room.selected_song or self.currentSongPayload
	if selectedSong == nil then
		online_flow_trace("current_user_song_confirmation result=false reason=song_not_selected"
			.. " room=" .. tostring(room.id or self.currentRoomId or "nil")
			.. " phase=" .. tostring(room.phase or "nil"))
		return false, "song_not_selected"
	end
	local currentUserId = tostring(self.user.id or "")
	if currentUserId == "" then
		online_flow_trace("current_user_song_confirmation result=false reason=missing_user_id"
			.. " room=" .. tostring(room.id or self.currentRoomId or "nil"))
		return false, "missing_user_id"
	end

	for member in ivalues(room.members or {}) do
		local memberUser = type(member.user) == "table" and member.user or {}
		local memberUserId = tostring(member.user_id or memberUser.id or member.id or "")
		if memberUserId == currentUserId then
			local songAvailable = member.song_available == true or member.songAvailable == true
			local missingSong = member.missing_song == true or member.missingSong == true
			local packStatus = tostring(member.pack_sync_status or member.packSyncStatus or "")
			if songAvailable and not missingSong then
				online_flow_trace("current_user_song_confirmation result=true reason=confirmed"
					.. " room=" .. tostring(room.id or self.currentRoomId or "nil")
					.. " phase=" .. tostring(room.phase or "nil")
					.. " user=" .. tostring(currentUserId)
					.. " packStatus=" .. tostring(packStatus)
					.. " songHash=" .. tostring(selectedSong.song_hash or selectedSong.songHash or ""):sub(1, 12)
					.. " chartHash=" .. tostring(selectedSong.chart_hash or selectedSong.chartHash or ""):sub(1, 12))
				return true, "confirmed"
			end
			online_flow_trace("current_user_song_confirmation result=false reason=member_not_confirmed"
				.. " room=" .. tostring(room.id or self.currentRoomId or "nil")
				.. " phase=" .. tostring(room.phase or "nil")
				.. " user=" .. tostring(currentUserId)
				.. " available=" .. tostring(songAvailable)
				.. " missing=" .. tostring(missingSong)
				.. " packStatus=" .. tostring(packStatus)
				.. " songHash=" .. tostring(selectedSong.song_hash or selectedSong.songHash or ""):sub(1, 12)
				.. " chartHash=" .. tostring(selectedSong.chart_hash or selectedSong.chartHash or ""):sub(1, 12))
			return false, "not_confirmed:available=" .. tostring(songAvailable)
				.. ",missing=" .. tostring(missingSong)
				.. ",packStatus=" .. tostring(packStatus)
		end
	end

	online_flow_trace("current_user_song_confirmation result=false reason=member_not_found"
		.. " room=" .. tostring(room.id or self.currentRoomId or "nil")
		.. " phase=" .. tostring(room.phase or "nil")
		.. " user=" .. tostring(currentUserId)
		.. " members=" .. tostring(room.members and #room.members or 0))
	return false, "member_not_found"
end

function ITGOnline:OnlineOptionsReadyKey()
	if not self.currentRoomId then return "" end
	local key = self.PlayStateKey and self:PlayStateKey() or ""
	if self.PlayStateKeyIsValid and self:PlayStateKeyIsValid(key) then
		return key
	end

	return tostring(self.currentRoomId) .. "|" .. tostring(self.currentRoomRoundKey or "")
end

function ITGOnline:RoomOnlineOptionsReadyKey(room)
	if not room then return "" end
	local key = self:RoomSongRoundKey(room)
	if key ~= "" then return key end
	return tostring(room.id or self.currentRoomId or "") .. "|" .. tostring(self.currentRoomRoundKey or "")
end

function ITGOnline:SetOptimisticConfigReady(source)
	local key = self.currentRoom and self:RoomOnlineOptionsReadyKey(self.currentRoom) or self:OnlineOptionsReadyKey()
	if key == "" then
		online_flow_trace("config_ready_optimistic_skipped source=" .. tostring(source or "unknown")
			.. " reason=empty_key"
			.. " room=" .. tostring(self.currentRoomId or "nil")
			.. " phase=" .. tostring(self.currentRoom and self.currentRoom.phase or "nil"))
		return false
	end
	if self.currentRoom and self:NormalizeRoomPhase(self.currentRoom.phase) ~= "config" then
		online_flow_trace("config_ready_optimistic_skipped source=" .. tostring(source or "unknown")
			.. " reason=not_config_phase"
			.. " key=" .. tostring(key)
			.. " phase=" .. tostring(self.currentRoom and self.currentRoom.phase or "nil"))
		return false
	end
	if self.optimisticConfigReadyKey ~= key then
		online_flow_trace("config_ready_optimistic_set source=" .. tostring(source or "unknown")
			.. " key=" .. tostring(key))
	end
	self.optimisticConfigReadyKey = key
	self.optimisticConfigReadyAt = GetTimeSinceStart()
	if self.currentRoom then
		MESSAGEMAN:Broadcast("OnlineLobbyState", self:LobbyStatePayload(self.currentRoom))
	end
	return true
end

function ITGOnline:ClearOptimisticConfigReady(source)
	if self.optimisticConfigReadyKey ~= "" then
		online_flow_trace("config_ready_optimistic_cleared source=" .. tostring(source or "unknown")
			.. " key=" .. tostring(self.optimisticConfigReadyKey))
	end
	self.optimisticConfigReadyKey = ""
	self.optimisticConfigReadyAt = 0
end

function ITGOnline:CurrentUserHasOptimisticConfigReady(room)
	if not self.user or self.optimisticConfigReadyKey == "" then return false end
	room = room or self.currentRoom
	if not room then return false end
	if self:NormalizeRoomPhase(room.phase) ~= "config" then return false end
	return self.optimisticConfigReadyKey == self:RoomOnlineOptionsReadyKey(room)
end

function ITGOnline:CurrentOptionsSelectionKey(room)
	room = room or self.currentRoom
	if not room then return "" end
	local key = self:RoomOnlineOptionsReadyKey(room)
	if key ~= "" then return key end
	return self.currentRoomId and tostring(self.currentRoomId) or ""
end

function ITGOnline:HasPresentedOptionsForCurrentSelection(room)
	local key = self:CurrentOptionsSelectionKey(room)
	return key ~= "" and tostring(self.onlineOptionsPresentedKey or "") == key
end

function ITGOnline:MarkOptionsPresentedForCurrentSelection(source, room)
	local key = self:CurrentOptionsSelectionKey(room)
	if key == "" then
		online_flow_trace("options_presented_mark_skipped source=" .. tostring(source or "unknown")
			.. " reason=empty_key"
			.. " room=" .. tostring(self.currentRoomId or "nil")
			.. " phase=" .. tostring(self.currentRoom and self.currentRoom.phase or "nil"))
		return false
	end
	if tostring(self.onlineOptionsPresentedKey or "") ~= key then
		online_flow_trace("options_presented_marked source=" .. tostring(source or "unknown")
			.. " key=" .. tostring(key)
			.. " previous=" .. tostring(self.onlineOptionsPresentedKey or "")
			.. " room=" .. tostring(self.currentRoomId or "nil")
			.. " phase=" .. tostring(self.currentRoom and self.currentRoom.phase or "nil"))
	end
	self.onlineOptionsPresentedKey = key
	self.onlineOptionsPresentedAt = GetTimeSinceStart()
	return true
end

function ITGOnline:ConfigReadyIntentKey(room)
	room = room or self.currentRoom
	local key = room and self:RoomOnlineOptionsReadyKey(room) or self:OnlineOptionsReadyKey()
	if key == "" then return "" end
	if self.PlayStateKeyIsValid and not self:PlayStateKeyIsValid(key) then return "" end
	return key
end

function ITGOnline:RememberPendingConfigReadyIntent(source)
	if not self.currentRoomId then
		online_flow_trace("config_ready_intent_skipped source=" .. tostring(source or "unknown")
			.. " reason=no_current_room")
		return false
	end

	local roomPhase = self:NormalizeRoomPhase(self.currentRoom and self.currentRoom.phase)
	if roomPhase == "starting" or roomPhase == "playing" or roomPhase == "results" then
		online_flow_trace("config_ready_intent_skipped source=" .. tostring(source or "unknown")
			.. " reason=terminal_or_active_phase"
			.. " phase=" .. tostring(roomPhase))
		return false
	end

	local key = self:ConfigReadyIntentKey(self.currentRoom)
	if key == "" then
		online_flow_trace("config_ready_intent_skipped source=" .. tostring(source or "unknown")
			.. " reason=invalid_round_key"
			.. " room=" .. tostring(self.currentRoomId or "nil")
			.. " phase=" .. tostring(roomPhase))
		return false
	end

	if self.pendingConfigReadyIntentKey ~= key
		or tostring(self.pendingConfigReadyIntentRoomId or "") ~= tostring(self.currentRoomId or "") then
		online_flow_trace("config_ready_intent_remembered source=" .. tostring(source or "unknown")
			.. " key=" .. tostring(key)
			.. " room=" .. tostring(self.currentRoomId)
			.. " phase=" .. tostring(roomPhase)
			.. " previousKey=" .. tostring(self.pendingConfigReadyIntentKey or "")
			.. " previousRoom=" .. tostring(self.pendingConfigReadyIntentRoomId or "nil"))
	end

	self.pendingConfigReadyIntentKey = key
	self.pendingConfigReadyIntentRoomId = self.currentRoomId
	self.pendingConfigReadyIntentAt = GetTimeSinceStart()
	self.pendingConfigReadyIntentSource = tostring(source or "unknown")
	return true
end

function ITGOnline:ClearPendingConfigReadyIntent(source)
	if self.pendingConfigReadyIntentKey ~= "" or self.pendingConfigReadyDispatchKey ~= "" then
		online_flow_trace("config_ready_intent_cleared source=" .. tostring(source or "unknown")
			.. " key=" .. tostring(self.pendingConfigReadyIntentKey or "")
			.. " room=" .. tostring(self.pendingConfigReadyIntentRoomId or "nil")
			.. " dispatchKey=" .. tostring(self.pendingConfigReadyDispatchKey or ""))
	end
	self.pendingConfigReadyIntentKey = ""
	self.pendingConfigReadyIntentRoomId = nil
	self.pendingConfigReadyIntentAt = 0
	self.pendingConfigReadyIntentSource = ""
	self.pendingConfigReadyDispatchKey = ""
end

function ITGOnline:PendingConfigReadyIntentMatchesRoom(room)
	room = room or self.currentRoom
	if self.pendingConfigReadyIntentKey == "" then return false, "no_pending_intent" end
	if not room or not room.id then return false, "no_room" end
	if tostring(room.id or "") ~= tostring(self.pendingConfigReadyIntentRoomId or "") then
		return false, "room_changed"
	end
	if self:NormalizeRoomPhase(room.phase) ~= "config" then
		return false, "phase_not_config"
	end
	if not room.selected_song then
		return false, "missing_selected_song"
	end
	local roomKey = self:ConfigReadyIntentKey(room)
	if roomKey == "" then return false, "invalid_room_key" end
	if roomKey ~= self.pendingConfigReadyIntentKey then
		return false, "round_changed"
	end
	if self:IsCurrentUserReadyInRoom(room, "config_ready") then
		return false, "already_ready"
	end
	return true, "matched"
end

function ITGOnline:MaybeReplayPendingConfigReady(source, room)
	room = room or self.currentRoom
	local matches, reason = self:PendingConfigReadyIntentMatchesRoom(room)
	if not matches then
		if reason == "room_changed" or reason == "round_changed" or reason == "already_ready" then
			online_flow_trace("config_ready_intent_not_replayed source=" .. tostring(source or "unknown")
				.. " reason=" .. tostring(reason)
				.. " key=" .. tostring(self.pendingConfigReadyIntentKey or "")
				.. " room=" .. tostring(room and room.id or "nil")
				.. " phase=" .. tostring(room and room.phase or "nil"))
			self:ClearPendingConfigReadyIntent("config_ready_intent_" .. tostring(reason))
		end
		return false
	end

	local key = self.pendingConfigReadyIntentKey
	if self.pendingConfigReadyDispatchKey == key or self.configReadyInFlight == true then
		online_flow_trace("config_ready_intent_replay_deferred source=" .. tostring(source or "unknown")
			.. " reason=inflight"
			.. " key=" .. tostring(key)
			.. " dispatchKey=" .. tostring(self.pendingConfigReadyDispatchKey or ""))
		return false
	end

	self.pendingConfigReadyDispatchKey = key
	online_flow_trace("config_ready_intent_replay_begin source=" .. tostring(source or "unknown")
		.. " key=" .. tostring(key)
		.. " room=" .. tostring(room.id)
		.. " phase=" .. tostring(room.phase)
		.. " rememberedSource=" .. tostring(self.pendingConfigReadyIntentSource or "")
		.. " age=" .. tostring(GetTimeSinceStart() - (tonumber(self.pendingConfigReadyIntentAt) or 0)))

	self:MarkConfigReady(function(ok, decoded, response)
		if self.pendingConfigReadyDispatchKey == key then
			self.pendingConfigReadyDispatchKey = ""
		end
		online_flow_trace("config_ready_intent_replay_finish key=" .. tostring(key)
			.. " ok=" .. tostring(ok == true)
			.. " error=" .. tostring(decoded and decoded.error_code or response and response.errorMessage or "nil"))
		if ok then
			self:ClearPendingConfigReadyIntent("config_ready_intent_replayed")
		end
	end)
	return true
end

function ITGOnline:ClearOnlineOptionsReadyDeadline(source)
	if self.onlineOptionsReadyDeadlineKey ~= "" then
		online_flow_trace("options_ready_deadline_cleared source=" .. tostring(source or "unknown")
			.. " key=" .. tostring(self.onlineOptionsReadyDeadlineKey))
	end
	self.onlineOptionsReadyDeadlineKey = ""
	self.onlineOptionsReadyDeadlineAt = 0
	self.onlineOptionsReadyTimeoutInFlightKey = ""
	self.onlineOptionsReadyExitSuppressedKey = ""
end

function ITGOnline:BeginOnlineOptionsReadyDeadline(seconds, source)
	if not self.currentRoomId or not self.currentRoom then return nil end
	if self:NormalizeRoomPhase(self.currentRoom.phase) ~= "config" then return nil end
	if self:IsCurrentUserReadyInRoom(self.currentRoom, "config_ready") then
		self:ClearOnlineOptionsReadyDeadline("already_ready")
		return nil
	end

	local key = self:OnlineOptionsReadyKey()
	if key == "" then return nil end

	if self.onlineOptionsReadyDeadlineKey ~= key then
		self.onlineOptionsReadyDeadlineKey = key
		self.onlineOptionsReadyDeadlineAt = GetTimeSinceStart() + (tonumber(seconds) or tonumber(self.onlineOptionsReadyTimeoutSeconds) or 30)
		self.onlineOptionsReadyTimeoutInFlightKey = ""
		self.onlineOptionsReadyExitSuppressedKey = ""
		online_flow_trace("options_ready_deadline_started source=" .. tostring(source or "unknown")
			.. " key=" .. tostring(key)
			.. " deadline=" .. tostring(self.onlineOptionsReadyDeadlineAt))
	end

	return math.max(0, (tonumber(self.onlineOptionsReadyDeadlineAt) or 0) - GetTimeSinceStart())
end

function ITGOnline:OnlineOptionsReadyRemaining()
	if self.onlineOptionsReadyDeadlineKey == "" then return nil end
	if self.onlineOptionsReadyDeadlineKey ~= self:OnlineOptionsReadyKey() then
		self:ClearOnlineOptionsReadyDeadline("stale_key")
		return nil
	end
	if self.currentRoom and self:IsCurrentUserReadyInRoom(self.currentRoom, "config_ready") then
		self:ClearOnlineOptionsReadyDeadline("ready")
		return nil
	end
	return math.max(0, (tonumber(self.onlineOptionsReadyDeadlineAt) or 0) - GetTimeSinceStart())
end

function ITGOnline:ShouldSuppressOnlineConfigReadyOnOptionsExit()
	local key = self:OnlineOptionsReadyKey()
	return key ~= "" and self.onlineOptionsReadyExitSuppressedKey == key
end

function ITGOnline:ExpireOnlineOptionsReady(source, callback)
	if not self.currentRoomId or not self.currentRoom then
		if callback then callback(false) end
		return
	end
	if self:NormalizeRoomPhase(self.currentRoom.phase) ~= "config" then
		if callback then callback(false) end
		return
	end
	if self:IsCurrentUserReadyInRoom(self.currentRoom, "config_ready") then
		self:ClearOnlineOptionsReadyDeadline("expire_already_ready")
		if callback then callback(false) end
		return
	end

	local key = self:OnlineOptionsReadyKey()
	if key == "" then
		if callback then callback(false) end
		return
	end
	if self.onlineOptionsReadyTimeoutInFlightKey == key then
		if callback then callback(true) end
		return
	end

	self.onlineOptionsReadyTimeoutInFlightKey = key
	self.onlineOptionsReadyExitSuppressedKey = key
	online_flow_trace("options_ready_deadline_expired source=" .. tostring(source or "unknown")
		.. " key=" .. tostring(key))
	if self.QueuePostRoomExitLobbyRefresh then
		self:QueuePostRoomExitLobbyRefresh("options_ready_timeout:" .. tostring(source or "unknown"), 0.35)
	end

	MESSAGEMAN:Broadcast("OnlineResponseStatus", {
		event = "ready",
		success = false,
		message = "Options timeout. You left the lobby."
	})

	self:LeaveRoom(function(ok, decoded, response)
		if self.onlineOptionsReadyTimeoutInFlightKey == key then
			self.onlineOptionsReadyTimeoutInFlightKey = ""
		end
		self:ClearOnlineOptionsReadyDeadline("timeout_leave")
		if ok and self.QueuePostRoomExitLobbyRefresh then
			self:QueuePostRoomExitLobbyRefresh("options_ready_timeout_leave_confirmed", 0.20)
		end
		if callback then callback(ok, decoded, response) end
	end)
end

function ITGOnline:ManagerAutoReadyKey(room, readyPhase)
	return tostring(readyPhase or "") .. "|" .. tostring(self:RoomSongRoundKey(room))
end

function ITGOnline:RoomMembersConfirmedSelectedSong(room)
	room = room or self.currentRoom
	local members = room and room.members or {}
	if #members == 0 then
		return false, "no_members", "members=0"
	end

	local waiting = {}
	local confirmed = 0
	for member in ivalues(members) do
		local user = member.user or member
		local userId = tostring(user.id or member.user_id or "?")
		local displayName = user_display_name(user, "Player " .. userId)
		local packStatus = tostring(member.pack_sync_status or "none")
		local songAvailable = member.song_available == true
		local missingSong = member.missing_song == true

		if songAvailable and not missingSong then
			confirmed = confirmed + 1
		else
			waiting[#waiting + 1] = tostring(displayName)
				.. ":songAvailable=" .. tostring(songAvailable)
				.. ",missingSong=" .. tostring(missingSong)
				.. ",packSyncStatus=" .. tostring(packStatus)
		end
	end

	if #waiting > 0 then
		return false, "members_song_not_confirmed", table.concat(waiting, ";")
	end

	return true, "all_members_song_confirmed", "confirmed=" .. tostring(confirmed) .. "/" .. tostring(#members)
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
	else
		return
	end

	local key = self:ManagerAutoReadyKey(room, readyPhase)
	if self.managerAutoReadyCompletedKey == key then return end
	if self:IsCurrentUserReadyInRoom(room, readyPhase) then
		self.managerAutoReadyCompletedKey = key
		online_trace("manager_auto_ready skipped: already ready [" .. key .. "]")
		return
	end
	if self.managerAutoReadyInFlightKey == key then return end

	if self.managerAutoReadyDeferredKey == key then
		online_flow_trace("manager_auto_ready_unblocked reason=own_ready_allowed key=" .. tostring(key))
		self.managerAutoReadyDeferredKey = ""
	end

	self.managerAutoReadyInFlightKey = key
	online_trace("manager_auto_ready sending phase=" .. tostring(readyPhase) .. " key=" .. key)
	self:SetReady(readyPhase, true, function(ok, decoded)
		if self.managerAutoReadyInFlightKey == key then
			self.managerAutoReadyInFlightKey = ""
		end

		if not ok then
			local errorCode = decoded and decoded.error_code
			if errorCode == "room_members_song_not_confirmed" or errorCode == "room_member_song_not_confirmed" then
				local retryAfter = tonumber(decoded.retry_after) or tonumber(self.readyRequestBlockedRetrySeconds) or 0.5
				self.managerAutoReadyDeferredKey = key
				online_flow_trace("manager_auto_ready_deferred reason=server_song_not_confirmed"
					.. " key=" .. tostring(key)
					.. " retry_after=" .. tostring(retryAfter)
					.. " serverDeferred=" .. tostring(decoded and decoded.deferred == true))
			end
			if errorCode == "room_phase_not_accepting_lobby_ready" then
				-- Stale phase race: avoid immediate replay storm on the same key.
				self.managerAutoReadyCompletedKey = key
			end
			online_trace("manager_auto_ready failed key=" .. key)
			return
		end

		self.managerAutoReadyCompletedKey = key
		online_trace("manager_auto_ready success key=" .. key)
		if decoded and decoded.room then
			local room = self:ApplyRoomSnapshot(decoded.room, "manager_auto_ready")
			decoded.room = room or decoded.room
			MESSAGEMAN:Broadcast("OnlineLobbyState", self:LobbyStatePayload(room or decoded.room))
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

function ITGOnline:IsOnlineEvaluationScreen(screenName)
	return screenName == "ScreenEvaluationStage"
		or screenName == "ScreenEvaluationNonstop"
		or screenName == "ScreenEvaluationSummary"
end

function ITGOnline:CurrentTopScreenName()
	local screen = SCREENMAN and SCREENMAN:GetTopScreen() or nil
	if screen and screen.GetName then
		return tostring(screen:GetName() or "")
	end
	return tostring(self.currentScreenName or "")
end

function ITGOnline:CanonicalGameplayRoundKey(source)
	local activeRoundKey = tostring(self.activeGameplayRoundKey or "")
	local currentRoomRoundKey = tostring(self.currentRoomRoundKey or "")
	local playStateRoundKey = self.PlayStateKey and tostring(self:PlayStateKey() or "") or ""
	local activeValid = self.PlayStateKeyIsValid and self:PlayStateKeyIsValid(activeRoundKey)
	local currentRoomValid = self.PlayStateKeyIsValid and self:PlayStateKeyIsValid(currentRoomRoundKey)
	local playStateValid = self.PlayStateKeyIsValid and self:PlayStateKeyIsValid(playStateRoundKey)

	if activeValid then
		if playStateValid and playStateRoundKey ~= activeRoundKey then
			online_flow_trace(
				"round_key_canonicalized source=" .. tostring(source or "unknown") ..
				" canonical=active" ..
				" activeRoundKey=" .. activeRoundKey ..
				" stalePlayStateRoundKey=" .. playStateRoundKey
			)
		end
		return activeRoundKey, "active"
	end

	if currentRoomValid then
		if playStateValid and playStateRoundKey ~= currentRoomRoundKey then
			online_flow_trace(
				"round_key_canonicalized source=" .. tostring(source or "unknown") ..
				" canonical=current_room" ..
				" currentRoomRoundKey=" .. currentRoomRoundKey ..
				" stalePlayStateRoundKey=" .. playStateRoundKey
			)
		end
		return currentRoomRoundKey, "current_room"
	end

	if playStateValid then
		return playStateRoundKey, "play_state"
	end

	return playStateRoundKey ~= "" and playStateRoundKey or currentRoomRoundKey ~= "" and currentRoomRoundKey or activeRoundKey, "fallback"
end

function ITGOnline:StopLiveScoreFlush(reason)
	local hadPending = self.pendingLiveScoreSnapshot ~= nil or tostring(self.pendingLiveScoreRoundKey or "") ~= ""
	local pendingRoundKey = tostring(self.pendingLiveScoreRoundKey or "")
	local currentRoundKey = self.PlayStateKey and self:PlayStateKey() or ""
	self.pendingLiveScoreSnapshot = nil
	self.pendingLiveScoreRoundKey = ""
	self.liveScoreNextAttemptAt = 0
	online_flow_trace(
		"live_score_flush_stopped reason=" .. tostring(reason or "unknown") ..
		" hadPending=" .. tostring(hadPending) ..
		" inFlight=" .. tostring(self.liveScoreInFlight == true) ..
		" room=" .. tostring(self.currentRoomId or "") ..
		" phase=" .. tostring(self.currentRoom and self.currentRoom.phase or "nil") ..
		" screen=" .. tostring(self.currentScreenName or "nil") ..
		" pendingRoundKey=" .. tostring(pendingRoundKey) ..
		" currentRoundKey=" .. tostring(currentRoundKey)
	)
end

function ITGOnline:NormalizeRoomPhase(value)
	local phase = tostring(value or ""):lower()
	if phase == "lobby" or phase == "lobby_ready" or phase == "config"
		or phase == "starting" or phase == "playing" or phase == "results" then
		return phase
	end
	return "unknown"
end

function ITGOnline:HasCurrentOnlineRoom()
	if not (self.currentRoomId and self.currentRoom) then return false end

	local expectedRoomId = tostring(self.currentRoomId or "")
	local snapshotRoomId = tostring(self.currentRoom.id or self.currentRoom.room_id or self.currentRoom.roomId or "")
	return expectedRoomId ~= "" and snapshotRoomId ~= "" and snapshotRoomId == expectedRoomId
end

function ITGOnline:HasActiveLiveScoreRoom()
	if not self:HasCurrentOnlineRoom() then return false end

	local phase = self:NormalizeRoomPhase(self.currentRoom and self.currentRoom.phase)
	return phase == "starting" or phase == "playing"
end

function ITGOnline:TraceOnlineState(label, fields)
	if not online_flow_trace then return end
	fields = type(fields) == "table" and fields or {}
	local room = fields.roomSnapshot or self.currentRoom or {}
	local selectedSong = type(room.selected_song) == "table" and room.selected_song
		or type(self.currentSongPayload) == "table" and self.currentSongPayload
		or {}
	local playState = type(room.play_state) == "table" and room.play_state or {}
	local summary = self.PlayStateSummary and self:PlayStateSummary(room) or nil
	local parts = {
		"online_state_trace",
		"label=" .. tostring(label or "unknown"),
		"room=" .. tostring(fields.room_id or fields.roomId or self.currentRoomId or room.id or "nil"),
		"user=" .. tostring(self.user and self.user.id or "nil"),
		"screen=" .. tostring(self.currentScreenName or "nil"),
		"phase=" .. tostring(fields.phase or room.phase or "nil"),
		"selectedAt=" .. tostring(fields.selected_at or fields.selectedAt or selectedSong.selected_at or selectedSong.selectedAt or "nil"),
		"roundKey=" .. tostring(fields.roundKey or (self.PlayStateKey and self:PlayStateKey() or "nil")),
		"roomRoundKey=" .. tostring(self.currentRoomRoundKey or ""),
		"members=" .. tostring(type(room.members) == "table" and #room.members or "nil"),
		"readyStates=" .. tostring(type(room.ready_states) == "table" and #room.ready_states or "nil"),
		"sessions=" .. tostring(type(playState.sessions) == "table" and #playState.sessions or "nil"),
		"finalResults=" .. tostring(type(playState.final_results) == "table" and #playState.final_results or "nil"),
		"finalResultsReady=" .. tostring(summary and summary.finalResultsReady == true or false),
		"source=" .. tostring(fields.source or "unknown"),
	}
	for key, value in pairs(fields) do
		if key ~= "roomSnapshot" and key ~= "room_id" and key ~= "roomId" and key ~= "phase"
			and key ~= "selected_at" and key ~= "selectedAt" and key ~= "roundKey" and key ~= "source" then
			parts[#parts + 1] = tostring(key) .. "=" .. tostring(value)
		end
	end
	online_flow_trace(table.concat(parts, " "))
end

function ITGOnline:TraceFinalScorePayload(label, fields)
	if not online_flow_trace then return end
	fields = type(fields) == "table" and fields or {}
	local judgments = type(fields.judgments) == "table" and fields.judgments or {}
	local judgmentTotal = self:JudgmentTotal(judgments)
	local score = tonumber(fields.score) or 0
	local displayedPercent = tonumber(fields.displayedPercent) or 0
	local accuracy = tonumber(fields.accuracy) or 0
	local songPosition = tonumber(fields.songPosition) or 0
	local failed = fields.failed == true
	local classification = "client_final_completed"
	if failed then
		if score == 0 and displayedPercent == 0 then
			if accuracy > 0 or songPosition > 0 or judgmentTotal > 0 then
				classification = "client_failed_zero_progress_confirmed"
			else
				classification = "suspicious_empty_failed_final"
			end
		else
			classification = "client_failed_scored"
		end
	end
	online_flow_trace("final_score_payload_trace"
		.. " label=" .. tostring(label or "unknown")
		.. " room=" .. tostring(fields.roomId or self.currentRoomId or "nil")
		.. " roundKey=" .. tostring(fields.roundKey or "")
		.. " final=" .. tostring(fields.final == true)
		.. " failed=" .. tostring(failed)
		.. " classification=" .. tostring(classification)
		.. " score=" .. tostring(score)
		.. " displayedPercent=" .. tostring(displayedPercent)
		.. " accuracy=" .. tostring(accuracy)
		.. " songPosition=" .. tostring(songPosition)
		.. " judgmentTotal=" .. tostring(judgmentTotal)
		.. " forceFinalFailed=" .. tostring(fields.forceFinalFailed == true)
		.. " scoreMode=" .. tostring(fields.scoreMode or "nil")
		.. " source=" .. tostring(fields.source or "unknown"))
end

function ITGOnline:JudgmentTotal(judgments)
	if type(judgments) ~= "table" then return 0 end

	local total = 0
	for _, value in pairs(judgments) do
		total = total + math.max(0, tonumber(value) or 0)
	end

	return total
end

function ITGOnline:IsSongReloadOrDownloadActive(source)
	local screenName = self.CurrentTopScreenName and self:CurrentTopScreenName() or tostring(self.currentScreenName or "")
	local packSync = self.PackSync
	local downloadKey = packSync and tostring(packSync.downloadInFlightKey or "") or ""
	local browseOnlyDownload = packSync and packSync.activeBrowseOnlyDownload == true
	local status = packSync and tostring(packSync.currentStatus or "") or ""
	local function status_matches(value)
		value = tostring(value or "")
		return value ~= "" and status == value
	end
	local downloadingStatus = packSync and packSync.status and (
		status_matches(packSync.status.DownloadInProgress)
		or status_matches(packSync.status.DownloadRequested)
		or status_matches(packSync.status.ReloadingSongs)
	)
	local active = screenName == "ScreenReloadSongsOnline"
		or downloadKey ~= ""
		or browseOnlyDownload
		or downloadingStatus == true
	if active then
		online_flow_trace_throttled("song_reload_or_download_active", 0.5,
			"song_reload_or_download_active source=" .. tostring(source or "unknown")
			.. " screen=" .. tostring(screenName)
			.. " downloadKey=" .. tostring(downloadKey)
			.. " browseOnlyDownload=" .. tostring(browseOnlyDownload == true)
			.. " status=" .. tostring(status))
	end
	return active
end

function ITGOnline:KnownRoomPhaseOrNil(value)
	local phase = self:NormalizeRoomPhase(value)
	if phase == "unknown" then return nil end
	return phase
end

function ITGOnline:RoomPhaseRank(phase)
	phase = self:NormalizeRoomPhase(phase)
	local ranks = {
		lobby = 1,
		lobby_ready = 2,
		config = 3,
		starting = 4,
		playing = 5,
		results = 6,
	}
	return ranks[phase] or 0
end

function ITGOnline:RoomSongRoundKey(room)
	if not room then return "" end
	local song = room.selected_song
	if not song or not song.chart_hash then return "" end
	return tostring(room.id or "") .. "|"
		.. tostring(song.game_session_id or song.session_id or song.round_id or song.selected_song_id or "") .. "|"
		.. tostring(song.song_hash or song.songHash or "") .. "|"
		.. tostring(song.chart_hash or "") .. "|"
		.. tostring(song.selected_at or song.selectedAt or "")
end

function ITGOnline:SelectedSongRoundKey(song, roomId)
	if not song or not song.chart_hash then return "" end
	return tostring(roomId or self.currentRoomId or "") .. "|"
		.. tostring(song.game_session_id or song.session_id or song.round_id or song.selected_song_id or "") .. "|"
		.. tostring(song.song_hash or song.songHash or "") .. "|"
		.. tostring(song.chart_hash or "") .. "|"
		.. tostring(song.selected_at or song.selectedAt or "")
end

function ITGOnline:CaptureActiveGameplayRound(source)
	local song = (self.currentRoom and self.currentRoom.selected_song) or self.currentSongPayload
	if not song or not song.chart_hash then return "" end

	local roundKey = self:SelectedSongRoundKey(song, self.currentRoomId)
	if roundKey == "" then return "" end

	if self.activeGameplayRoundKey ~= roundKey then
		online_flow_trace("active_gameplay_round source=" .. tostring(source or "unknown")
			.. " previous=" .. tostring(self.activeGameplayRoundKey or "")
			.. " current=" .. tostring(roundKey))
	end

	self.activeGameplaySongPayload = song
	self.activeGameplayRoundKey = roundKey
	return roundKey
end

function ITGOnline:ClearActiveGameplayRound(source)
	if self.activeGameplayRoundKey ~= "" then
		online_flow_trace("active_gameplay_round_cleared source=" .. tostring(source or "unknown")
			.. " previous=" .. tostring(self.activeGameplayRoundKey or ""))
	end
	self.activeGameplaySongPayload = nil
	self.activeGameplayRoundKey = ""
	self.onlineGameplayEvaluationNavigationKey = ""
	self.onlineGameplayEvaluationNavigationAt = 0
	self.onlineGameplayEvaluationShownKey = ""
	self.onlineGameplayEvaluationReturnedKey = ""
end

function ITGOnline:ResetOnlineRoundRuntimeState(source)
	local previousActiveRoundKey = tostring(self.activeGameplayRoundKey or "")
	local previousRoomRoundKey = tostring(self.currentRoomRoundKey or "")
	local previousPlayStateKey = self.PlayStateKey and tostring(self:PlayStateKey() or "") or ""
	online_flow_trace("round_runtime_state_reset source=" .. tostring(source or "unknown")
		.. " room=" .. tostring(self.currentRoomId or "nil")
		.. " phase=" .. tostring(self.currentRoom and self.currentRoom.phase or "nil")
		.. " activeRoundKey=" .. tostring(previousActiveRoundKey)
		.. " currentRoundKey=" .. tostring(previousRoomRoundKey)
		.. " playStateKey=" .. tostring(previousPlayStateKey)
		.. " hadPendingLiveScore=" .. tostring(self.pendingLiveScoreSnapshot ~= nil)
		.. " liveScoreInFlight=" .. tostring(self.liveScoreInFlight == true)
		.. " scoreInFlight=" .. tostring(self.scoreInFlightFingerprint ~= nil))

	self.songLoadedAckKey = ""
	self.songLoadedInFlightKey = ""
	self.songLoadedPendingCallbacks = {}
	self.songAvailabilityInFlightKey = ""
	self.songAvailabilityInFlightCallbacks = {}
	self.songAvailabilityReportedKey = ""
	self.songAvailabilitySuppressedUntil = {}
	self.startScheduleAckKey = ""
	self.startScheduleAckInFlightKey = ""
	self.onlineGameplayEnteredKey = ""
	self.onlineGameplayEnteredInFlightKey = ""
	self.onlineGameplayReturnedKey = ""
	self.onlineGameplayReturnedInFlightKey = ""
	self.onlineGameplayReturnedLocalRoomId = ""
	self.onlineGameplayReturnedLocalAt = 0
	self.onlineGameplayTerminalKey = ""
	self.onlineGameplayTerminalInFlightKey = ""
	self.onlineGameplayTerminalState = ""
	self.onlineGameplayFailedEarlyKey = ""
	self.onlineGameplayFailedEarlyInFlightKey = ""
	self.onlineGameplayEndedKey = ""
	self.onlineGameplayEvaluationMarkKey = ""
	self.onlineGameplayEvaluationMarkInFlightKey = ""
	self.onlineGameplayEvaluationRetryKey = ""
	self.onlineGameplayEvaluationRetryCount = 0
	self.onlineGameplayEvaluationNextRetryAt = 0
	self.onlineGameplayEvaluationTerminalErrorKey = ""
	self.onlineGameplayEvaluationNavigationKey = ""
	self.onlineGameplayEvaluationNavigationAt = 0
	self.onlineGameplayEvaluationShownKey = ""
	self.onlineGameplayEvaluationReturnedKey = ""
	self.onlineGameplayEvaluationHoldStartedKey = ""
	self.onlineGameplayEvaluationMinimumHoldUntil = 0
	self.onlineGameplayAllTerminalHoldKey = ""
	self.onlineGameplayAllTerminalHoldUntil = 0
	self.onlineOptionsPresentedKey = ""
	self.onlineOptionsPresentedAt = 0
	self.readyRequestBlockedErrors = {}
	self.lastFinalScoreKey = ""
	self.lastFinalScoreInFlightKey = ""
	self.lastAcceptedScoreFingerprint = nil
	self.scoreInFlightFingerprint = nil
	self.pendingLiveScoreSnapshot = nil
	self.pendingLiveScoreRoundKey = ""
	self.liveScoreInFlight = false
	self.liveScoreNextAttemptAt = 0
	self.lastScorePositionKey = nil
	self.lastScoreSongPosition = 0
	self.lastAcceptedScoreSongPosition = 0
	self.lastDisplayedScoreSnapshot = nil
	self.lastDisplayedScoreSnapshotAt = 0
	self.lastScoreJudgmentsByRoundKey = {}
	self:ClearActiveGameplayRound(source or "round_runtime_state_reset")
end

function ITGOnline:RoomSongSelectedAtMs(room)
	local value = room and room.selected_song and (room.selected_song.selected_at or room.selected_song.selectedAt) or nil
	return iso_utc_milliseconds(value)
end

function ITGOnline:RoomPhaseIsStale(currentPhase, incomingPhase)
	currentPhase = self:NormalizeRoomPhase(currentPhase)
	incomingPhase = self:NormalizeRoomPhase(incomingPhase)

	-- Score/room events can arrive out of order around song end. Once this
	-- client has observed `results`, an older score event must not pull the
	-- local room back to `playing`; that reopens the gameplay/evaluation flow.
	return currentPhase == "results" and (incomingPhase == "playing" or incomingPhase == "starting")
end

function ITGOnline:RoomPhaseFromScoreEventIsStale(incomingPhase)
	local currentPhase = self:NormalizeRoomPhase(self.currentRoom and self.currentRoom.phase or nil)
	incomingPhase = self:NormalizeRoomPhase(incomingPhase)

	if (currentPhase == "lobby" or currentPhase == "lobby_ready" or currentPhase == "config")
		and (incomingPhase == "starting" or incomingPhase == "playing" or incomingPhase == "results") then
		return true
	end

	return self:RoomPhaseIsStale(currentPhase, incomingPhase)
end

function ITGOnline:RoomSnapshotIsStale(previousRoom, incomingRoom)
	if not previousRoom or not incomingRoom then return false end
	if tostring(previousRoom.id or "") ~= tostring(incomingRoom.id or "") then return false end

	local currentPhase = self:NormalizeRoomPhase(previousRoom.phase)
	local incomingPhase = self:NormalizeRoomPhase(incomingRoom.phase)
	local currentKey = self:RoomSongRoundKey(previousRoom)
	if currentKey == "" then
		currentKey = tostring(self.currentRoomRoundKey or "")
	end
	local incomingKey = self:RoomSongRoundKey(incomingRoom)

	if currentKey ~= "" and incomingKey ~= "" and currentKey ~= incomingKey then
		local currentSelectedAt = self:RoomSongSelectedAtMs(previousRoom)
		local incomingSelectedAt = self:RoomSongSelectedAtMs(incomingRoom)
		if currentSelectedAt and incomingSelectedAt then
			return incomingSelectedAt < currentSelectedAt
		end
		if currentSelectedAt and not incomingSelectedAt then
			return true
		end
		return false
	end

	if incomingPhase == "results"
		and (currentPhase == "lobby" or currentPhase == "lobby_ready" or currentPhase == "config")
		and incomingKey ~= "" then
		return true
	end

	return self:RoomPhaseIsStale(currentPhase, incomingPhase)
end

function ITGOnline:ApplyRoomPhase(incomingPhase, source)
	if not self.currentRoom or incomingPhase == nil then return end
	local normalizedPhase = self:KnownRoomPhaseOrNil(incomingPhase)
	if not normalizedPhase then
		online_flow_trace("ignored_invalid_room_phase source=" .. tostring(source or "unknown")
			.. " current=" .. tostring(self.currentRoom.phase)
			.. " incoming=" .. tostring(incomingPhase))
		return
	end
	local currentPhase = self.currentRoom.phase
	if self:RoomPhaseIsStale(currentPhase, normalizedPhase) then
		online_flow_trace("ignored_stale_room_phase source=" .. tostring(source or "unknown")
			.. " current=" .. tostring(currentPhase)
			.. " incoming=" .. tostring(normalizedPhase))
		return
	end
	self.currentRoom.phase = normalizedPhase
	if normalizedPhase ~= "starting" and normalizedPhase ~= "playing" and self.StopLiveScoreFlush then
		self:StopLiveScoreFlush("phase_applied_not_live:" .. tostring(normalizedPhase) .. ":" .. tostring(source or "unknown"))
	end
	if normalizedPhase == "config" then
		self:MaybeReplayPendingConfigReady("room_phase_" .. tostring(source or "unknown"), self.currentRoom)
	elseif normalizedPhase == "starting" or normalizedPhase == "playing" or normalizedPhase == "results" then
		self:ClearPendingConfigReadyIntent("room_phase_" .. tostring(normalizedPhase))
	end
end

function ITGOnline:ClearSelectedSongForLobby(source, shouldBroadcast)
	if not self.currentRoom then return false end
	local phase = self:NormalizeRoomPhase(self.currentRoom.phase)
	if phase ~= "lobby" then return false end

	local hadSong = self.currentRoom.selected_song ~= nil
	local previousRoundKey = tostring(self.currentRoomRoundKey or "")
	self.currentRoom.selected_song = nil
	self.currentSongPayload = nil
	self.currentRoomRoundKey = ""
	self:ClearActiveGameplayRound(tostring(source or "lobby_song_clear"))
	if type(self.currentRoom.ready_states) == "table" and #self.currentRoom.ready_states > 0 then
		self.currentRoom.ready_states = {}
	end

	online_flow_trace("room_lobby_song_state_cleared source=" .. tostring(source or "unknown")
		.. " hadSong=" .. tostring(hadSong == true)
		.. " previousRoundKey=" .. tostring(previousRoundKey)
		.. " broadcast=" .. tostring(shouldBroadcast == true))

	if shouldBroadcast == true then
		self:BroadcastCurrentRoomState(tostring(source or "lobby_song_clear"))
	end

	return hadSong
end

function ITGOnline:NormalizeGlobalOptions(options)
	options = type(options) == "table" and options or {}
	local scoreMode = tostring(options.score_mode or options.scoreMode or "itg"):lower()
	if scoreMode ~= "ex" and scoreMode ~= "hardex" then
		scoreMode = "itg"
	end

	local musicRate = tonumber(options.music_rate or options.musicRate) or 1.0
	musicRate = math.max(0.25, math.min(3.0, musicRate))

	return {
		score_mode = scoreMode,
		music_rate = musicRate,
		scoreMode = scoreMode,
		musicRate = musicRate,
	}
end

function ITGOnline:CurrentGlobalOptions()
	return self:NormalizeGlobalOptions(self.currentRoom and self.currentRoom.global_options)
end

function ITGOnline:ApplyGlobalOptionsToLocalState(room, source)
	local options = self:NormalizeGlobalOptions(room and room.global_options)
	apply_music_rate(options.music_rate)

	for player in ivalues(GAMESTATE:GetEnabledPlayers()) do
		local pn = ToEnumShortString(player)
		if pn and SL and SL[pn] and SL[pn].ActiveModifiers then
			SL[pn].ActiveModifiers.ShowExScore = options.score_mode == "ex"
			SL[pn].ActiveModifiers.ShowHardEXScore = options.score_mode == "hardex"
		end
	end

	local key = tostring(options.score_mode) .. "|" .. string.format("%.3f", options.music_rate)
	if self.lastAppliedGlobalOptionsKey ~= key then
		self.lastAppliedGlobalOptionsKey = key
		online_flow_trace("global_options_applied source=" .. tostring(source or "unknown")
			.. " score_mode=" .. tostring(options.score_mode)
			.. " music_rate=" .. string.format("%.3f", options.music_rate))
	end

	return options
end

local function room_member_user_id(member)
	if type(member) ~= "table" then return "" end
	local user = member.user or {}
	return tostring(user.id or member.user_id or member.player_id or member.id or "")
end

local function room_ready_user_id(state)
	if type(state) ~= "table" then return "" end
	local user = state.user or {}
	return tostring(user.id or state.user_id or state.player_id or state.id or "")
end

local partialRoomSnapshotSources = {
	pack_sync_status = true,
	ready = true,
	song_availability = true,
}

local function source_can_be_partial_room_snapshot(source)
	local value = tostring(source or "")
	return partialRoomSnapshotSources[value] == true
		or value == "realtime_room_event:room.member_pack_sync_updated"
		or value == "realtime_room_event:room.member_song_availability_updated"
		or value == "member_room_refresh:room.member_pack_sync_updated"
		or value == "member_room_refresh:room.member_song_availability_updated"
		or value == "lobby_refresh_current_room:fetch_lobby"
end

local function merge_room_array_by_user_id(previousItems, incomingItems, userIdFn)
	local merged = {}
	local indexByUserId = {}

	for item in ivalues(previousItems or {}) do
		local userId = userIdFn(item)
		if userId ~= "" then
			indexByUserId[userId] = #merged + 1
		end
		merged[#merged + 1] = item
	end

	for item in ivalues(incomingItems or {}) do
		local userId = userIdFn(item)
		local index = userId ~= "" and indexByUserId[userId] or nil
		if index then
			merged[index] = item
		else
			if userId ~= "" then
				indexByUserId[userId] = #merged + 1
			end
			merged[#merged + 1] = item
		end
	end

	return merged
end

local roomPhaseProgressionOrder = {
	lobby = 1,
	lobby_ready = 2,
	config = 3,
	starting = 4,
	playing = 5,
	results = 6,
}

local roomPhaseRegressionSources = {
	song_selection_cancelled = true,
	["realtime_room_event:room.song_selection_cancelled"] = true,
	["realtime_room_event_fetch:room.song_selection_cancelled"] = true,
	load_timeout = true,
	["realtime_room_event:room.load_timeout"] = true,
	["realtime_room_event_fetch:room.load_timeout"] = true,
	["realtime_room_event:room.play_state_reset_to_lobby"] = true,
	["realtime_room_event_fetch:room.play_state_reset_to_lobby"] = true,
	["realtime_room_event:room.member_left"] = true,
	["member_room_refresh:room.member_left"] = true,
	fetch_room = true,
	fetch_current_room = true,
	sync_current_room = true,
}

local function source_allows_room_phase_regression(source)
	return roomPhaseRegressionSources[tostring(source or "")] == true
end

function ITGOnline:RoomSnapshotRegressesPhase(previousRoom, incomingRoom, source)
	online_flow_trace_throttled("room_snapshot_regression_check", 1.0,
		"room_snapshot_regression_check source=" .. tostring(source or "unknown")
		.. " previousPhase=" .. tostring(previousRoom and previousRoom.phase or "nil")
		.. " incomingPhase=" .. tostring(incomingRoom and incomingRoom.phase or "nil")
		.. " previousSelectedAt=" .. tostring(previousRoom and previousRoom.selected_song and previousRoom.selected_song.selected_at or "")
		.. " incomingSelectedAt=" .. tostring(incomingRoom and incomingRoom.selected_song and incomingRoom.selected_song.selected_at or ""))
	if type(previousRoom) ~= "table" or type(incomingRoom) ~= "table" then return false end
	if tonumber(previousRoom.id or -1) ~= tonumber(incomingRoom.id or -2) then return false end
	if source_allows_room_phase_regression(source) then return false end

	local previousPhase = self:NormalizeRoomPhase(previousRoom.phase)
	local incomingPhase = self:NormalizeRoomPhase(incomingRoom.phase)
	local previousOrder = roomPhaseProgressionOrder[previousPhase]
	local incomingOrder = roomPhaseProgressionOrder[incomingPhase]
	if not previousOrder or not incomingOrder then return false end
	if incomingOrder >= previousOrder then return false end

	local previousKey = tostring(self:RoomSongRoundKey(previousRoom) or "")
	local incomingKey = tostring(self:RoomSongRoundKey(incomingRoom) or "")
	if previousKey ~= "" and incomingKey ~= "" and previousKey ~= incomingKey then return false end

	return true
end

function ITGOnline:NormalizeRoomSnapshot(room, previousRoom, source)
	online_flow_trace_throttled("room_snapshot_normalize_begin", 0.75,
		"room_snapshot_normalize_begin source=" .. tostring(source or "unknown")
		.. " room=" .. tostring(room and (room.id or room.code) or "nil")
		.. " previousRoom=" .. tostring(previousRoom and (previousRoom.id or previousRoom.code) or "nil")
		.. " incomingPhase=" .. tostring(room and room.phase or "nil")
		.. " previousPhase=" .. tostring(previousRoom and previousRoom.phase or "nil")
		.. " incomingMembers=" .. tostring(room and room.members and #room.members or "nil")
		.. " previousMembers=" .. tostring(previousRoom and previousRoom.members and #previousRoom.members or "nil"))
	if not room or not previousRoom then return room end
	if tonumber(room.id or -1) ~= tonumber(previousRoom.id or -2) then return room end
	if not source_can_be_partial_room_snapshot(source) then
		online_flow_trace("room_snapshot_partial_merge_skipped source=" .. tostring(source or "unknown")
			.. " reason=source_not_partial"
			.. " room=" .. tostring(room.id or "nil")
			.. " incomingMembers=" .. tostring(type(room.members) == "table" and #room.members or 0)
			.. " previousMembers=" .. tostring(type(previousRoom.members) == "table" and #previousRoom.members or 0)
			.. " incomingReady=" .. tostring(type(room.ready_states) == "table" and #room.ready_states or 0)
			.. " previousReady=" .. tostring(type(previousRoom.ready_states) == "table" and #previousRoom.ready_states or 0))
		return room
	end

	local incomingMembers = room.members or {}
	local previousMembers = previousRoom.members or {}
	local incomingReadyStates = room.ready_states or {}
	local previousReadyStates = previousRoom.ready_states or {}
	local preservedSelectedSong = false
	local preservedGlobalOptions = false
	local preservedPlayState = false

	if room.selected_song == nil and previousRoom.selected_song ~= nil then
		room.selected_song = previousRoom.selected_song
		preservedSelectedSong = true
	end

	if room.global_options == nil and previousRoom.global_options ~= nil then
		room.global_options = previousRoom.global_options
		preservedGlobalOptions = true
	end

	if room.play_state == nil and previousRoom.play_state ~= nil then
		room.play_state = previousRoom.play_state
		preservedPlayState = true
	end

	if preservedSelectedSong or preservedGlobalOptions or preservedPlayState then
		online_flow_trace("room_snapshot_partial_context_preserved source=" .. tostring(source or "unknown")
			.. " room=" .. tostring(room.id or "nil")
			.. " selected_song=" .. tostring(preservedSelectedSong)
			.. " global_options=" .. tostring(preservedGlobalOptions)
			.. " play_state=" .. tostring(preservedPlayState)
			.. " previousRoundKey=" .. tostring(self:RoomSongRoundKey(previousRoom))
			.. " incomingMembers=" .. tostring(#incomingMembers)
			.. " previousMembers=" .. tostring(#previousMembers))
	end

	local shouldMergeMembers = #previousMembers > #incomingMembers
	local shouldMergeReady = #previousReadyStates > #incomingReadyStates

	if not shouldMergeMembers and not shouldMergeReady then
		online_flow_trace("room_snapshot_partial_merge_skipped source=" .. tostring(source or "unknown")
			.. " reason=no_shrink_detected"
			.. " room=" .. tostring(room.id or "nil")
			.. " incomingMembers=" .. tostring(#incomingMembers)
			.. " previousMembers=" .. tostring(#previousMembers)
			.. " incomingReady=" .. tostring(#incomingReadyStates)
			.. " previousReady=" .. tostring(#previousReadyStates))
		return room
	end

	if shouldMergeMembers then
		room.members = merge_room_array_by_user_id(previousMembers, incomingMembers, room_member_user_id)
		room.members_count = math.max(tonumber(room.members_count) or 0, #room.members)
	end

	if shouldMergeReady then
		room.ready_states = merge_room_array_by_user_id(previousReadyStates, incomingReadyStates, room_ready_user_id)
	end

	online_flow_trace("room_snapshot_partial_merged source=" .. tostring(source or "unknown")
		.. " incoming_members=" .. tostring(#incomingMembers)
		.. " previous_members=" .. tostring(#previousMembers)
		.. " merged_members=" .. tostring(type(room.members) == "table" and #room.members or 0)
		.. " incoming_ready=" .. tostring(#incomingReadyStates)
		.. " previous_ready=" .. tostring(#previousReadyStates)
		.. " merged_ready=" .. tostring(type(room.ready_states) == "table" and #room.ready_states or 0))

	return room
end

function ITGOnline:MaybeAutoConfirmSelectedSongAndMarkLobbyReady(room, source)
	room = room or self.currentRoom
	if not room or not self.currentRoomId then
		online_flow_trace("song_selected_auto_ready_skipped source=" .. tostring(source or "unknown")
			.. " reason=no_room"
			.. " currentRoomId=" .. tostring(self.currentRoomId or "nil"))
		return
	end

	local phase = self:NormalizeRoomPhase(room.phase)
	if phase ~= "lobby_ready" then
		return
	end

	local selectedSong = room.selected_song
	if not selectedSong or not selectedSong.song_hash or not selectedSong.chart_hash then
		online_flow_trace("song_selected_auto_ready_skipped source=" .. tostring(source or "unknown")
			.. " reason=no_selected_song"
			.. " room=" .. tostring(room.id or self.currentRoomId or "nil")
			.. " phase=" .. tostring(phase))
		return
	end
	if self:IsSongReloadOrDownloadActive("song_selected_auto_ready:" .. tostring(source or "unknown")) then
		self.songSelectedAutoReadyInFlightKey = ""
		online_flow_trace("song_selected_auto_ready_skipped source=" .. tostring(source or "unknown")
			.. " reason=download_or_reload_active"
			.. " room=" .. tostring(room.id or self.currentRoomId or "nil")
			.. " phase=" .. tostring(phase)
			.. " selectedAt=" .. tostring(selectedSong.selected_at or selectedSong.selectedAt or "nil"))
		return
	end

	local key = self:RoomSongRoundKey(room)
	if key == "" then
		online_flow_trace("song_selected_auto_ready_skipped source=" .. tostring(source or "unknown")
			.. " reason=invalid_round_key"
			.. " room=" .. tostring(room.id or self.currentRoomId or "nil")
			.. " phase=" .. tostring(phase)
			.. " selectedAt=" .. tostring(selectedSong.selected_at or selectedSong.selectedAt or "nil"))
		return
	end

	if self:IsCurrentUserReadyInRoom(room, "lobby_ready") then
		if self.songSelectedAutoReadyCompletedKey ~= key then
			online_flow_trace("song_selected_auto_ready_completed_by_snapshot source=" .. tostring(source or "unknown")
				.. " key=" .. tostring(key)
				.. " room=" .. tostring(room.id or self.currentRoomId or "nil"))
		end
		self.songSelectedAutoReadyCompletedKey = key
		if self.songSelectedAutoReadyInFlightKey == key then
			self.songSelectedAutoReadyInFlightKey = ""
		end
		return
	end

	if self.songSelectedAutoReadyCompletedKey == key then
		return
	end

	if self.songSelectedAutoReadyInFlightKey == key then
		online_flow_trace("song_selected_auto_ready_skipped source=" .. tostring(source or "unknown")
			.. " reason=in_flight"
			.. " key=" .. tostring(key)
			.. " room=" .. tostring(room.id or self.currentRoomId or "nil"))
		return
	end

	self.songSelectedAutoReadyInFlightKey = key
	online_flow_trace("song_selected_auto_ready_begin source=" .. tostring(source or "unknown")
		.. " key=" .. tostring(key)
		.. " room=" .. tostring(room.id or self.currentRoomId or "nil")
		.. " title=" .. tostring(selectedSong.title or selectedSong.folder_name or selectedSong.song_hash or "unknown")
		.. " selectedAt=" .. tostring(selectedSong.selected_at or selectedSong.selectedAt or "nil"))

	self:ConfirmSelectedSongAvailability("room_song_selected_auto", function(availabilityOk, availabilityDecoded, availabilityResponse)
		online_flow_trace("song_selected_auto_ready_availability_result key=" .. tostring(key)
			.. " ok=" .. tostring(availabilityOk == true)
			.. " status=" .. tostring(availabilityResponse and availabilityResponse.statusCode or "nil")
			.. " hasRoom=" .. tostring(availabilityDecoded and availabilityDecoded.room ~= nil)
			.. " phase=" .. tostring(availabilityDecoded and availabilityDecoded.room and availabilityDecoded.room.phase or self.currentRoom and self.currentRoom.phase or "nil")
			.. " error=" .. tostring(availabilityDecoded and availabilityDecoded.error_code or availabilityResponse and availabilityResponse.errorMessage or "nil"))

		if self.songSelectedAutoReadyInFlightKey ~= key then
			online_flow_trace("song_selected_auto_ready_aborted reason=stale_inflight key=" .. tostring(key))
			return
		end

		if not availabilityOk then
			self.songSelectedAutoReadyInFlightKey = ""
			online_flow_trace("song_selected_auto_ready_failed key=" .. tostring(key)
				.. " step=availability"
				.. " message=" .. tostring(response_message(availabilityResponse, availabilityDecoded, "availability failed")))
			return
		end

		local currentPhase = self:NormalizeRoomPhase(self.currentRoom and self.currentRoom.phase)
		if currentPhase == "config" then
			self.songSelectedAutoReadyInFlightKey = ""
			self.songSelectedAutoReadyCompletedKey = key
			online_flow_trace("song_selected_auto_ready_completed key=" .. tostring(key)
				.. " reason=room_already_config")
			if self.EnforceRoomPhaseScreen then
				self:EnforceRoomPhaseScreen()
			end
			return
		end

		self:SetReady("lobby_ready", true, function(readyOk, readyDecoded, readyResponse)
			if self.songSelectedAutoReadyInFlightKey == key then
				self.songSelectedAutoReadyInFlightKey = ""
			end

			online_flow_trace("song_selected_auto_ready_ready_result key=" .. tostring(key)
				.. " ok=" .. tostring(readyOk == true)
				.. " status=" .. tostring(readyResponse and readyResponse.statusCode or "nil")
				.. " hasRoom=" .. tostring(readyDecoded and readyDecoded.room ~= nil)
				.. " phase=" .. tostring(readyDecoded and readyDecoded.room and readyDecoded.room.phase or self.currentRoom and self.currentRoom.phase or "nil")
				.. " error=" .. tostring(readyDecoded and readyDecoded.error_code or readyResponse and readyResponse.errorMessage or "nil"))

			if readyOk then
				self.songSelectedAutoReadyCompletedKey = key
				if readyDecoded and readyDecoded.room then
					MESSAGEMAN:Broadcast("OnlineLobbyState", self:LobbyStatePayload(self.currentRoom or readyDecoded.room))
				end
				if self.EnforceRoomPhaseScreen then
					self:EnforceRoomPhaseScreen()
				end
				return
			end

			local errorCode = readyDecoded and readyDecoded.error_code
			if errorCode == "room_members_song_not_confirmed" or errorCode == "room_member_song_not_confirmed" then
				online_flow_trace("song_selected_auto_ready_waiting key=" .. tostring(key)
					.. " reason=" .. tostring(errorCode)
					.. " retryAfter=" .. tostring(readyDecoded and readyDecoded.retry_after or "nil"))
				return
			end

			online_flow_trace("song_selected_auto_ready_failed key=" .. tostring(key)
				.. " step=ready"
				.. " message=" .. tostring(response_message(readyResponse, readyDecoded, "ready failed")))
		end)
	end)
end

function ITGOnline:ApplyRoomSnapshot(room, source)
	self:TraceOnlineState("room_snapshot_incoming", {
		source = source or "unknown",
		roomSnapshot = type(room) == "table" and room or nil,
		incomingPhase = type(room) == "table" and room.phase or "nil",
		currentPhase = self.currentRoom and self.currentRoom.phase or "nil",
		currentRoom = self.currentRoomId or "nil",
	})
	online_flow_trace("room_snapshot_apply_begin source=" .. tostring(source or "unknown")
		.. " incomingRoom=" .. tostring(room and (room.id or room.code) or "nil")
		.. " currentRoom=" .. tostring(self.currentRoomId or "nil")
		.. " incomingPhase=" .. tostring(room and room.phase or "nil")
		.. " currentPhase=" .. tostring(self.currentRoom and self.currentRoom.phase or "nil")
		.. " incomingMembers=" .. tostring(room and room.members and #room.members or "nil"))
	if not room then
		online_flow_trace("room_snapshot_apply_skipped source=" .. tostring(source or "unknown")
			.. " reason=nil_room"
			.. " currentRoomId=" .. tostring(self.currentRoomId or "nil")
			.. " currentPhase=" .. tostring(self.currentRoom and self.currentRoom.phase or "nil"))
		return nil
	end
	if self:ShouldRejectSongSelectedAfterCancel(room, source) then
		online_room_snapshot_debug("room_snapshot_rejected_stale_song_selected_after_cancel", room, source, self.currentRoom)
		return self.currentRoom
	end
	if tostring(source or ""):find("song_selection_cancelled", 1, true) then
		self:RememberSongSelectionCancelled(room, source)
	end
	local previousRoom = self.currentRoom
	local previousMembers = previousRoom and previousRoom.members and #previousRoom.members or 0
	local previousReadyStates = previousRoom and previousRoom.ready_states and #previousRoom.ready_states or 0
	local incomingMembers = room.members and #room.members or 0
	local incomingReadyStates = room.ready_states and #room.ready_states or 0
	local previousSelectedAt = previousRoom and previousRoom.selected_song and (previousRoom.selected_song.selected_at or previousRoom.selected_song.selectedAt) or nil
	local incomingSelectedAt = room.selected_song and (room.selected_song.selected_at or room.selected_song.selectedAt) or nil
	local previousSongHash = previousRoom and previousRoom.selected_song and (previousRoom.selected_song.song_hash or previousRoom.selected_song.songHash) or nil
	local previousChartHash = previousRoom and previousRoom.selected_song and (previousRoom.selected_song.chart_hash or previousRoom.selected_song.chartHash) or nil
	local incomingSongHash = room.selected_song and (room.selected_song.song_hash or room.selected_song.songHash) or nil
	local incomingChartHash = room.selected_song and (room.selected_song.chart_hash or room.selected_song.chartHash) or nil
	local previousPlayStateVersion = previousRoom and previousRoom.play_state and previousRoom.play_state.version_ms or nil
	local incomingPlayStateVersionForLog = room.play_state and room.play_state.version_ms or nil
	if previousRoom then
		local previousHadSong = previousRoom.selected_song ~= nil
		local incomingHasSong = room.selected_song ~= nil
		local songTransition = nil
		if not previousHadSong and incomingHasSong then
			songTransition = "selected_song_added"
		elseif previousHadSong and not incomingHasSong then
			songTransition = "selected_song_removed"
		elseif previousHadSong and incomingHasSong
			and (tostring(previousSelectedAt or "") ~= tostring(incomingSelectedAt or "")
				or tostring(previousSongHash or "") ~= tostring(incomingSongHash or "")
				or tostring(previousChartHash or "") ~= tostring(incomingChartHash or "")) then
			songTransition = "selected_song_changed"
		elseif self:NormalizeRoomPhase(room.phase) == "lobby" and incomingHasSong then
			songTransition = "lobby_with_selected_song"
		end
		if songTransition then
			online_flow_trace("room_snapshot_selected_song_transition source=" .. tostring(source or "unknown")
				.. " transition=" .. tostring(songTransition)
				.. " room=" .. tostring(room.id or self.currentRoomId or "nil")
				.. " previousPhase=" .. tostring(previousRoom.phase or "nil")
				.. " incomingPhase=" .. tostring(room.phase or "nil")
				.. " previousSelectedAt=" .. tostring(previousSelectedAt or "nil")
				.. " incomingSelectedAt=" .. tostring(incomingSelectedAt or "nil")
				.. " previousSongHash=" .. tostring(previousSongHash or ""):sub(1, 12)
				.. " incomingSongHash=" .. tostring(incomingSongHash or ""):sub(1, 12)
				.. " previousChartHash=" .. tostring(previousChartHash or ""):sub(1, 12)
				.. " incomingChartHash=" .. tostring(incomingChartHash or ""):sub(1, 12))
		end
	end
	online_flow_trace("room_snapshot_apply_start source=" .. tostring(source or "unknown")
		.. " incomingRoom=" .. tostring(room.id or "nil")
		.. " incomingPhase=" .. tostring(room.phase or "nil")
		.. " incomingMembers=" .. tostring(incomingMembers)
		.. " incomingReadyStates=" .. tostring(incomingReadyStates)
		.. " incomingSelectedAt=" .. tostring(incomingSelectedAt or "nil")
		.. " incomingPlayStateVersion=" .. tostring(incomingPlayStateVersionForLog or "nil")
		.. " previousRoom=" .. tostring(previousRoom and previousRoom.id or "nil")
		.. " previousPhase=" .. tostring(previousRoom and previousRoom.phase or "nil")
		.. " previousMembers=" .. tostring(previousMembers)
		.. " previousReadyStates=" .. tostring(previousReadyStates)
		.. " previousSelectedAt=" .. tostring(previousSelectedAt or "nil")
		.. " previousPlayStateVersion=" .. tostring(previousPlayStateVersion or "nil"))
	online_room_snapshot_debug("room_snapshot_apply_begin", room, source, previousRoom)
	room = self:NormalizeRoomSnapshot(room, previousRoom, source)
	local normalizedIncomingPhase = self:NormalizeRoomPhase(room.phase)
	if normalizedIncomingPhase ~= "results" and type(room.play_state) == "table" and type(room.play_state.final_results) == "table" and #room.play_state.final_results > 0 then
		online_flow_trace("room_snapshot_final_results_ignored_non_results"
			.. " source=" .. tostring(source or "unknown")
			.. " room=" .. tostring(room.id or self.currentRoomId or "nil")
			.. " phase=" .. tostring(normalizedIncomingPhase or "nil")
			.. " rows=" .. tostring(#room.play_state.final_results)
			.. " version=" .. tostring(room.play_state.version_ms or "nil"))
		room.play_state.final_results = {}
	end
	local normalizedPreviousPhase = previousRoom and self:NormalizeRoomPhase(previousRoom.phase) or "unknown"
	local normalizedIncomingSelectedAt = room.selected_song and (room.selected_song.selected_at or room.selected_song.selectedAt) or nil
	local normalizedIncomingSongHash = room.selected_song and (room.selected_song.song_hash or room.selected_song.songHash) or nil
	local normalizedIncomingChartHash = room.selected_song and (room.selected_song.chart_hash or room.selected_song.chartHash) or nil
	local finalCacheShouldClear = normalizedIncomingPhase ~= "results" and (
		normalizedPreviousPhase == "results"
		or tostring(previousSelectedAt or "") ~= tostring(normalizedIncomingSelectedAt or "")
		or tostring(previousSongHash or "") ~= tostring(normalizedIncomingSongHash or "")
		or tostring(previousChartHash or "") ~= tostring(normalizedIncomingChartHash or "")
	)
	if finalCacheShouldClear and self.ClearFinalLeaderboardCache then
		if normalizedPreviousPhase == "results" and normalizedIncomingPhase == "lobby" then
			self.finalLeaderboardCacheInvalidLobbyRoomId = tostring(room.id or self.currentRoomId or "")
			self.finalLeaderboardCacheInvalidLobbyAt = GetTimeSinceStart()
		end
		self:ClearFinalLeaderboardCache(
			"room_snapshot_" .. tostring(normalizedPreviousPhase) .. "_to_" .. tostring(normalizedIncomingPhase),
			room.id or self.currentRoomId
		)
	end
	if self:NormalizeRoomPhase(room.phase) == "results" and not room.selected_song then
		local fallbackSong = self.lastResultSongPayload
			or (previousRoom and previousRoom.selected_song)
			or self.currentSongPayload
			or self.activeGameplaySongPayload
		if type(fallbackSong) == "table" then
			local hydratedSong = {}
			for key, value in pairs(fallbackSong) do
				hydratedSong[key] = value
			end
			room.selected_song = hydratedSong
			online_flow_trace("room_snapshot_results_song_hydrated source=" .. tostring(source or "unknown")
				.. " room=" .. tostring(room.id or self.currentRoomId or "nil")
				.. " fallbackTitle=" .. tostring(hydratedSong.title or hydratedSong.folder_name or hydratedSong.song_hash or "unknown")
				.. " fallbackSongHash=" .. tostring(hydratedSong.song_hash or hydratedSong.songHash or ""):sub(1, 12)
				.. " fallbackChartHash=" .. tostring(hydratedSong.chart_hash or hydratedSong.chartHash or ""):sub(1, 12))
		else
			online_flow_trace_throttled("room_snapshot_results_song_missing", 1.0,
				"room_snapshot_results_song_missing source=" .. tostring(source or "unknown")
				.. " room=" .. tostring(room.id or self.currentRoomId or "nil")
				.. " previousHasSong=" .. tostring(previousRoom and previousRoom.selected_song ~= nil)
				.. " hasCurrentSong=" .. tostring(self.currentSongPayload ~= nil)
				.. " hasActiveGameplaySong=" .. tostring(self.activeGameplaySongPayload ~= nil))
		end
	end
	if previousRoom and self:RoomSnapshotRegressesPhase(previousRoom, room, source) then
		self:TraceOnlineState("room_snapshot_rejected_regressive", {
			source = source or "unknown",
			roomSnapshot = room,
			previousPhase = previousRoom.phase or "nil",
			incomingPhase = room.phase or "nil",
		})
		online_room_snapshot_debug("room_snapshot_rejected_regressive", room, source, previousRoom)
		online_flow_trace("ignored_regressive_room_snapshot source=" .. tostring(source or "unknown")
			.. " room=" .. tostring(room.id or "")
			.. " currentRoomId=" .. tostring(self.currentRoomId or "nil")
			.. " previous_phase=" .. tostring(self:NormalizeRoomPhase(previousRoom.phase))
			.. " incoming_phase=" .. tostring(self:NormalizeRoomPhase(room.phase))
			.. " previous_key=" .. tostring(self:RoomSongRoundKey(previousRoom) or "")
			.. " incoming_key=" .. tostring(self:RoomSongRoundKey(room) or ""))
		return self.currentRoom
	end
	if previousRoom and self:RoomSnapshotIsStale(previousRoom, room) then
		self:TraceOnlineState("room_snapshot_rejected_stale", {
			source = source or "unknown",
			roomSnapshot = room,
			previousPhase = previousRoom.phase or "nil",
			incomingPhase = room.phase or "nil",
		})
		local previousKey = self:RoomSongRoundKey(previousRoom)
		if previousKey == "" then
			previousKey = self.currentRoomRoundKey or ""
		end
		online_room_snapshot_debug("room_snapshot_rejected_stale", room, source, previousRoom)
		online_flow_trace("ignored_stale_room_snapshot source=" .. tostring(source or "unknown")
			.. " room=" .. tostring(room.id or "")
			.. " currentRoomId=" .. tostring(self.currentRoomId or "nil")
			.. " current=" .. tostring(previousRoom.phase)
			.. " incoming=" .. tostring(room.phase)
			.. " current_key=" .. tostring(previousKey)
			.. " incoming_key=" .. tostring(self:RoomSongRoundKey(room) or ""))
		return self.currentRoom
	end

	local roomVersionKey = tostring(room.id or self.currentRoomId or "")
	local incomingRoomVersion = tonumber(room.room_version or room.roomVersion) or 0
	local previousRoomVersion = tonumber(self.lastRoomVersionByRoomId[roomVersionKey]) or 0
	if incomingRoomVersion > 0 and previousRoomVersion > 0 and incomingRoomVersion < previousRoomVersion then
		self:TraceOnlineState("room_snapshot_rejected_room_version", {
			source = source or "unknown",
			roomSnapshot = room,
			incomingRoomVersion = incomingRoomVersion,
			previousRoomVersion = previousRoomVersion,
		})
		online_room_snapshot_debug("room_snapshot_rejected_stale_room_version", room, source, previousRoom)
		online_flow_trace("ignored_stale_room_snapshot source=" .. tostring(source or "unknown")
			.. " reason=room_version_regression"
			.. " room=" .. tostring(roomVersionKey)
			.. " incomingRoomVersion=" .. tostring(incomingRoomVersion)
			.. " previousRoomVersion=" .. tostring(previousRoomVersion)
			.. " incomingPhase=" .. tostring(room.phase or "nil")
			.. " previousPhase=" .. tostring(previousRoom and previousRoom.phase or "nil")
			.. " incomingSelectionId=" .. tostring(room.current_selection_id or room.currentSelectionId or "nil")
			.. " previousSelectionId=" .. tostring(previousRoom and (previousRoom.current_selection_id or previousRoom.currentSelectionId) or "nil"))
		return self.currentRoom
	elseif incomingRoomVersion > 0 and roomVersionKey ~= "" then
		self.lastRoomVersionByRoomId[roomVersionKey] = incomingRoomVersion
		online_flow_trace("room_snapshot_room_version_accepted source=" .. tostring(source or "unknown")
			.. " room=" .. tostring(roomVersionKey)
			.. " incomingRoomVersion=" .. tostring(incomingRoomVersion)
			.. " previousRoomVersion=" .. tostring(previousRoomVersion)
			.. " selectionId=" .. tostring(room.current_selection_id or room.currentSelectionId or "nil"))
	end
	local incomingPlayStateVersion = tonumber(room.play_state and room.play_state.version_ms) or 0
	local previousPlayStateVersion = tonumber(self.lastPlayStateVersionByRoomId[roomVersionKey]) or 0
	if incomingPlayStateVersion > 0 and incomingPlayStateVersion < previousPlayStateVersion and previousRoom and previousRoom.play_state then
		online_flow_trace("room_snapshot_play_state_preserved source=" .. tostring(source or "unknown")
			.. " reason=incoming_version_older"
			.. " room=" .. tostring(roomVersionKey)
			.. " incomingVersion=" .. tostring(incomingPlayStateVersion)
			.. " previousVersion=" .. tostring(previousPlayStateVersion)
			.. " incomingPhase=" .. tostring(room.phase or "nil")
			.. " previousPhase=" .. tostring(previousRoom.phase or "nil"))
		room.play_state = previousRoom.play_state
	elseif incomingPlayStateVersion <= 0 and previousPlayStateVersion > 0 and previousRoom and previousRoom.play_state then
		online_flow_trace("room_snapshot_play_state_preserved source=" .. tostring(source or "unknown")
			.. " reason=incoming_unversioned"
			.. " room=" .. tostring(roomVersionKey)
			.. " previousVersion=" .. tostring(previousPlayStateVersion)
			.. " incomingPhase=" .. tostring(room.phase or "nil")
			.. " previousPhase=" .. tostring(previousRoom.phase or "nil"))
		room.play_state = previousRoom.play_state
	elseif incomingPlayStateVersion > 0 and roomVersionKey ~= "" then
		online_flow_trace("room_snapshot_play_state_version_accepted source=" .. tostring(source or "unknown")
			.. " room=" .. tostring(roomVersionKey)
			.. " incomingVersion=" .. tostring(incomingPlayStateVersion)
			.. " previousVersion=" .. tostring(previousPlayStateVersion)
			.. " phase=" .. tostring(room.phase or "nil"))
		self.lastPlayStateVersionByRoomId[roomVersionKey] = incomingPlayStateVersion
	end

	self.currentRoomId = room.id
	room.online_snapshot_source = source
	self.lastAuthoritativeRoomSnapshotAt = GetTimeSinceStart()
	self.lastAuthoritativeRoomSnapshotSource = tostring(source or "unknown")
	self.currentRoom = room
	online_room_snapshot_debug("room_snapshot_accepted", room, source, previousRoom)
	online_room_transition_trace(previousRoom, room, source)
	if room.id then
		self.deletedRoomIds[tostring(room.id)] = nil
		self:MarkLeavingRoom(room.id, false)
		if self.ignoredRoomEventsUntil then
			self.ignoredRoomEventsUntil[self:RoomKey(room.id)] = nil
		end
		online_flow_trace("room_snapshot_flags_cleared source=" .. tostring(source or "unknown")
			.. " room=" .. tostring(room.id)
			.. " deletedFlag=false leavingFlag=false ignoredEvents=false")
	end
	self:ApplyGlobalOptionsToLocalState(room, source)
	local normalizedRoomPhase = self:NormalizeRoomPhase(room.phase)
	if normalizedRoomPhase ~= "config" then
		self:ClearOnlineOptionsReadyDeadline("room_snapshot_" .. tostring(room.phase or "unknown"))
		self:ClearOptimisticConfigReady("room_snapshot_" .. tostring(room.phase or "unknown"))
	elseif self.optimisticConfigReadyKey ~= "" and self.optimisticConfigReadyKey ~= self:RoomOnlineOptionsReadyKey(room) then
		self:ClearOptimisticConfigReady("room_snapshot_config_round_changed")
	elseif self:IsCurrentUserReadyInRoom(room, "config_ready") then
		local readyKey = self:OnlineOptionsReadyKey()
		self.configReadyInFlight = false
		self.configReadyInFlightByKey = {}
		self:ClearOnlineOptionsReadyDeadline("room_snapshot_config_ready")
		self:ClearOptimisticConfigReady("room_snapshot_config_ready")
		self:ClearPendingConfigReadyIntent("room_snapshot_config_ready")
		if self.lastConfigReadySnapshotConfirmedKey ~= readyKey then
			self.lastConfigReadySnapshotConfirmedKey = readyKey
			online_flow_trace("config_ready_confirmed_by_snapshot source=" .. tostring(source or "unknown")
				.. " key=" .. tostring(readyKey))
			MESSAGEMAN:Broadcast("OnlineConfigReadyConfirmed", {
				key = readyKey,
				source = source,
				room = room,
			})
		end
	end
	if normalizedRoomPhase == "config" then
		self:MaybeReplayPendingConfigReady("room_snapshot_" .. tostring(source or "unknown"), room)
	elseif normalizedRoomPhase == "starting" or normalizedRoomPhase == "playing" or normalizedRoomPhase == "results" then
		self:ClearPendingConfigReadyIntent("room_snapshot_" .. tostring(normalizedRoomPhase))
	end

	if room.selected_song and room.selected_song.song_hash and room.selected_song.chart_hash then
		local phase = normalizedRoomPhase
		if phase == "results" then
			online_flow_trace("room_snapshot_song_payload_store source=" .. tostring(source or "unknown")
				.. " target=last_result"
				.. " phase=" .. tostring(phase)
				.. " roundKey=" .. tostring(self:RoomSongRoundKey(room))
				.. " title=" .. tostring(room.selected_song.title or room.selected_song.folder_name or room.selected_song.song_hash or "unknown"))
			self.lastResultSongPayload = room.selected_song
		else
			local previousRoundKey = tostring(self.currentRoomRoundKey or "")
			local incomingRoundKey = self:RoomSongRoundKey(room)
			if previousRoundKey ~= "" and incomingRoundKey ~= "" and previousRoundKey ~= incomingRoundKey then
				self:ResetOnlineRoundRuntimeState("room_snapshot_round_changed:" .. tostring(source or "unknown"))
			end
			self.currentSongPayload = room.selected_song
			self.currentRoomRoundKey = incomingRoundKey
			online_flow_trace("room_snapshot_song_payload_store source=" .. tostring(source or "unknown")
				.. " target=current"
				.. " phase=" .. tostring(phase)
				.. " previousRoundKey=" .. tostring(previousRoundKey)
				.. " currentRoundKey=" .. tostring(self.currentRoomRoundKey)
				.. " title=" .. tostring(room.selected_song.title or room.selected_song.folder_name or room.selected_song.song_hash or "unknown"))
			if phase == "lobby" or phase == "lobby_ready" or phase == "config" then
				self:ClearActiveGameplayRound("room_snapshot_" .. tostring(phase))
			end
		end
	elseif self:NormalizeRoomPhase(room.phase) ~= "results" then
		online_flow_trace("room_snapshot_song_payload_cleared source=" .. tostring(source or "unknown")
			.. " phase=" .. tostring(room.phase or "nil")
			.. " previousRoundKey=" .. tostring(self.currentRoomRoundKey or "")
			.. " hadCurrentSong=" .. tostring(self.currentSongPayload ~= nil))
		local normalizedClearPhase = self:NormalizeRoomPhase(room.phase)
		if normalizedClearPhase == "lobby" and tostring(self.currentRoomRoundKey or "") ~= "" then
			self:ResetOnlineRoundRuntimeState("room_snapshot_lobby_without_song:" .. tostring(source or "unknown"))
		end
		self.currentSongPayload = nil
		self.currentRoomRoundKey = ""
		self:ClearActiveGameplayRound("room_snapshot_no_song")
	end

	if self.MaybeAutoReadyManager then
		self:MaybeAutoReadyManager(self.currentRoom)
	end
	if self.MaybeAutoConfirmSelectedSongAndMarkLobbyReady then
		self:MaybeAutoConfirmSelectedSongAndMarkLobbyReady(self.currentRoom, source)
	end

	online_flow_trace("room_snapshot_apply_complete source=" .. tostring(source or "unknown")
		.. " room=" .. tostring(self.currentRoomId or "nil")
		.. " phase=" .. tostring(self.currentRoom and self.currentRoom.phase or "nil")
		.. " members=" .. tostring(self.currentRoom and self.currentRoom.members and #self.currentRoom.members or 0)
		.. " readyStates=" .. tostring(self.currentRoom and self.currentRoom.ready_states and #self.currentRoom.ready_states or 0)
		.. " selectedAt=" .. tostring(self.currentRoom and self.currentRoom.selected_song and (self.currentRoom.selected_song.selected_at or self.currentRoom.selected_song.selectedAt) or "nil")
		.. " roundKey=" .. tostring(self.currentRoomRoundKey or "")
		.. " playStateVersion=" .. tostring(self.currentRoom and self.currentRoom.play_state and self.currentRoom.play_state.version_ms or "nil")
		.. " snapshotSource=" .. tostring(self.currentRoom and self.currentRoom.online_snapshot_source or "nil"))
	if self.PlayStateSummary then
		local summary = self:PlayStateSummary(self.currentRoom)
		online_flow_trace("room_snapshot_play_state_summary source=" .. tostring(source or "unknown")
			.. " room=" .. tostring(self.currentRoomId or "nil")
			.. " phase=" .. tostring(self.currentRoom and self.currentRoom.phase or "nil")
			.. " localState=" .. tostring(self.CurrentUserPlayState and self:CurrentUserPlayState(self.currentRoom) or "nil")
			.. " allTerminal=" .. tostring(summary and summary.allTerminal == true)
			.. " finalResultsReady=" .. tostring(summary and summary.finalResultsReady == true)
			.. " submittedScores=" .. tostring(summary and summary.submittedScores or "nil")
			.. " finalResults=" .. tostring(summary and summary.finalResults or "nil")
			.. " waitingFailedFinals=" .. tostring(summary and summary.waitingFailedFinals == true))
	end
	self:TraceOnlineState("room_snapshot_applied", {
		source = source or "unknown",
		roomSnapshot = self.currentRoom,
		previousPhase = previousRoom and previousRoom.phase or "nil",
		previousMembers = previousMembers,
		previousReadyStates = previousReadyStates,
		previousSelectedAt = previousSelectedAt or "nil",
	})

	return self.currentRoom
end

function ITGOnline:IsPostResultsLobbyScreen(room, screenName)
	room = room or self.currentRoom
	if not room then
		return false
	end

	local resolvedScreenName = tostring(screenName or "")
	if resolvedScreenName == "" then
		local topScreen = SCREENMAN and SCREENMAN:GetTopScreen() or nil
		resolvedScreenName = tostring((topScreen and topScreen:GetName()) or self.currentScreenName or "")
	end

	if resolvedScreenName ~= "ScreenOnlineLobbies" then
		return false
	end

	if self:NormalizeRoomPhase(room.phase) ~= "results" then
		return false
	end

	local playState = ""
	if self.CurrentUserPlayState then
		playState = tostring(self:CurrentUserPlayState(room) or "")
	end
	if playState == "returned_to_lobby" then
		return true
	end

	local roundKey = ""
	if self.PlayStateKey then
		roundKey = tostring(self:PlayStateKey() or "")
	end
	if roundKey ~= "" and (not self.PlayStateKeyIsValid or self:PlayStateKeyIsValid(roundKey)) then
		if tostring(self.onlineGameplayEvaluationReturnedKey or "") == roundKey then
			return true
		end
	end

	return false
end

function ITGOnline:BroadcastLeaderboardFromRoom(room, source)
	room = room or self.currentRoom
	if not room then
		online_flow_trace("broadcast_room_leaderboard_skipped reason=no_room source=" .. tostring(source or "unknown")
			.. " currentRoomId=" .. tostring(self.currentRoomId or "nil"))
		return false
	end

	if self.StoreFinalLeaderboardFromRoom then
		self:StoreFinalLeaderboardFromRoom(room, "broadcast_room_leaderboard:" .. tostring(source or "unknown"))
	end

	local topScreen = SCREENMAN and SCREENMAN:GetTopScreen() or nil
	local screenName = tostring((topScreen and topScreen:GetName()) or self.currentScreenName or "")
	if self:IsPostResultsLobbyScreen(room, screenName) then
		online_flow_trace_throttled("post_results_leaderboard_broadcast_suppressed", 1.0,
			"broadcast_room_leaderboard_suppressed reason=post_results_lobby"
			.. " source=" .. tostring(source or "unknown")
			.. " room=" .. tostring(room.id or self.currentRoomId or "nil")
			.. " phase=" .. tostring(room.phase or "nil")
			.. " screen=" .. screenName)
		return false
	end

	local leaderboard = room.live_scores or room.top_scores or room.leaderboard
	if not leaderboard or #leaderboard == 0 then
		online_flow_trace_throttled("broadcast_room_leaderboard_empty", 2.0,
			"broadcast_room_leaderboard_skipped reason=empty_leaderboard source=" .. tostring(source or "unknown")
			.. " room=" .. tostring(room.id or self.currentRoomId or "nil")
			.. " phase=" .. tostring(room.phase or "nil")
			.. " hasLiveScores=" .. tostring(room.live_scores ~= nil)
			.. " hasTopScores=" .. tostring(room.top_scores ~= nil)
			.. " hasLeaderboard=" .. tostring(room.leaderboard ~= nil))
		return false
	end

	local roomId = room.id or self.currentRoomId
	local version = tonumber(room.leaderboard_version_ms or room.live_score_version_ms or room.updated_version_ms) or 0
	local versionKey = tostring(roomId or "")
	if version > 0 and versionKey ~= "" then
		local previousVersion = tonumber(self.lastLeaderboardVersionByRoomId[versionKey]) or 0
		if version < previousVersion then
			online_flow_trace("ignored_stale_room_leaderboard source=" .. tostring(source or "unknown")
				.. " version=" .. tostring(version)
				.. " previous=" .. tostring(previousVersion))
			return false
		end
		self.lastLeaderboardVersionByRoomId[versionKey] = version
	end

	online_flow_trace("broadcast_room_leaderboard source=" .. tostring(source or "unknown")
		.. " room=" .. tostring(roomId or "nil")
		.. " rows=" .. tostring(#leaderboard)
		.. " phase=" .. tostring(room.phase or "nil")
		.. " version=" .. tostring(version)
		.. " selectedAt=" .. tostring(room.selected_song and (room.selected_song.selected_at or room.selected_song.selectedAt) or "nil")
		.. " playStateVersion=" .. tostring(room.play_state and room.play_state.version_ms or "nil")
		.. " rowsSummary=" .. online_score_rows_summary(leaderboard, 8))
	if self.debugScoreTrace == true then
		local parts = {}
		for entry in ivalues(leaderboard or {}) do
			local user = type(entry) == "table" and entry.user or {}
			parts[#parts + 1] = table.concat({
				tostring(user and user.id or ""),
				tostring(entry and entry.displayed_percent or ""),
				tostring(entry and entry.failed == true),
				tostring(entry and entry.source or ""),
			}, ":")
		end
		online_trace("broadcast_room_leaderboard_rows room=" .. tostring(roomId or "nil")
			.. " rows=" .. table.concat(parts, ","))
	end
	MESSAGEMAN:Broadcast("ITGOnlineLeaderboardUpdated", {
		leaderboard = leaderboard,
		room_id = roomId,
		leaderboard_version_ms = version,
	})
	return true
end

function ITGOnline:FinalLeaderboardResultsFrom(source)
	if type(source) ~= "table" then return nil end
	if type(source.finalResults) == "table" then return source.finalResults end
	if type(source.final_results) == "table" then return source.final_results end
	if type(source.play_state) == "table" and type(source.play_state.final_results) == "table" then
		return source.play_state.final_results
	end
	if type(source.playState) == "table" and type(source.playState.final_results) == "table" then
		return source.playState.final_results
	end
	return nil
end

function ITGOnline:StoreFinalLeaderboardFromRoom(source, cacheSource)
	if type(source) ~= "table" then
		final_leaderboard_cache_trace("skip reason=invalid_source source=" .. tostring(cacheSource or "unknown"))
		return false
	end

	local playState = type(source.play_state) == "table" and source.play_state
		or type(source.playState) == "table" and source.playState
		or {}
	local songInfo = type(source.songInfo) == "table" and source.songInfo
		or type(source.selected_song) == "table" and source.selected_song
		or {}
	local phase = source.phase or source.status or source.readyPhase or playState.phase
	if self.NormalizeRoomPhase then
		phase = self:NormalizeRoomPhase(phase)
	end
	if phase ~= "results" then
		return false
	end

	local results = self:FinalLeaderboardResultsFrom(source)
	if type(results) ~= "table" or #results == 0 then
		final_leaderboard_cache_trace("skip reason=empty_results source=" .. tostring(cacheSource or "unknown")
			.. " room=" .. tostring(source.roomId or source.room_id or source.id or self.currentRoomId or "nil")
			.. " phase=" .. tostring(phase or "nil")
			.. " playStateSessions=" .. tostring(playState.sessions and #playState.sessions or 0)
			.. " submittedScores=" .. tostring(playState.submitted_scores and #playState.submitted_scores or 0))
		return false
	end

	local roomId = tostring(source.roomId or source.room_id or source.id or self.currentRoomId or "")
	local roundKey = tostring(playState.round_key
		or playState.round_id
		or playState.game_session_id
		or source.roundKey
		or source.round_key
		or source.startAt
		or source.start_at
		or source.startedAt
		or source.started_at
		or songInfo.roundId
		or songInfo.round_id
		or songInfo.selectedAt
		or songInfo.selected_at
		or songInfo.game_session_id
		or songInfo.session_id
		or songInfo.song_hash
		or songInfo.songHash
		or songInfo.chart_hash
		or songInfo.chartHash
		or "")
	local version = tonumber(source.leaderboard_version_ms
		or source.live_score_version_ms
		or source.updated_version_ms
		or playState.version_ms
		or playState.updated_version_ms) or 0
	local rowsSignatureParts = {}
	for index, result in ipairs(results or {}) do
		if type(result) == "table" then
			local user = type(result.user) == "table" and result.user or {}
			rowsSignatureParts[#rowsSignatureParts + 1] = table.concat({
				tostring(index),
				tostring(result.rank or ""),
				tostring(user.id or result.user_id or ""),
				tostring(result.displayed_percent or result.displayedPercent or result.score_percent or ""),
				tostring(result.score or ""),
				tostring(result.failed == true),
			}, ":")
		end
	end
	local canonicalSignature = table.concat({
		roomId,
		roundKey,
		tostring(version),
		tostring(#results),
		table.concat(rowsSignatureParts, ","),
	}, "|")

	local cache = {
		room_id = roomId,
		round_key = roundKey,
		version_ms = version,
		source = tostring(cacheSource or "unknown"),
		stored_at = GetTimeSinceStart and GetTimeSinceStart() or 0,
		signature = canonicalSignature,
		rows = online_table_copy(results, 0) or {},
	}
	self.finalLeaderboardCache = self.finalLeaderboardCache or {}
	local previous = roomId ~= "" and self.finalLeaderboardCache[roomId] or self.latestFinalLeaderboardCache
	local duplicate = previous and tostring(previous.signature or "") == canonicalSignature
	if roomId ~= "" then
		self.finalLeaderboardCache[roomId] = cache
	end
	self.latestFinalLeaderboardCache = cache

	self.finalLeaderboardCacheSignature = canonicalSignature
	if duplicate then
		final_leaderboard_cache_trace("duplicate"
			.. " source=" .. tostring(cacheSource or "unknown")
			.. " room=" .. tostring(roomId ~= "" and roomId or "nil")
			.. " roundKey=" .. tostring(roundKey ~= "" and roundKey or "nil")
			.. " version=" .. tostring(version)
			.. " rows=" .. tostring(#results)
			.. " rowsSummary=" .. online_score_rows_summary(results, 8))
		return true
	end
	local logSignature = table.concat({ canonicalSignature, tostring(cacheSource or "unknown") }, "|")
	if logSignature ~= tostring(self.finalLeaderboardCacheLogSignature or "") then
		self.finalLeaderboardCacheLogSignature = logSignature
		final_leaderboard_cache_trace("store"
			.. " source=" .. tostring(cacheSource or "unknown")
			.. " room=" .. tostring(roomId ~= "" and roomId or "nil")
			.. " roundKey=" .. tostring(roundKey ~= "" and roundKey or "nil")
			.. " version=" .. tostring(version)
			.. " rows=" .. tostring(#results)
			.. " rowsSummary=" .. online_score_rows_summary(results, 8))
	end
	return true
end

function ITGOnline:ClearFinalLeaderboardCache(reason, roomId)
	self.finalLeaderboardCache = self.finalLeaderboardCache or {}
	local key = tostring(roomId or self.currentRoomId or "")
	local clearReason = tostring(reason or "unknown")
	if clearReason == "room_snapshot_results_to_lobby_ready" then
		local screen = SCREENMAN and SCREENMAN:GetTopScreen() or nil
		local screenName = tostring((screen and screen.GetName and screen:GetName()) or self.currentScreenName or "")
		if screenName == "ScreenEvaluationStage"
			or screenName == "ScreenEvaluationNonstop"
			or screenName == "ScreenEvaluationSummary" then
			final_leaderboard_cache_trace("clear_deferred"
				.. " reason=" .. clearReason
				.. " room=" .. tostring(key ~= "" and key or "nil")
				.. " screen=" .. tostring(screenName))
			return false
		end
	end
	local clearedRoomCache = false
	if key ~= "" and self.finalLeaderboardCache[key] ~= nil then
		self.finalLeaderboardCache[key] = nil
		clearedRoomCache = true
	end
	local clearedLatest = false
	if self.latestFinalLeaderboardCache
		and (key == "" or tostring(self.latestFinalLeaderboardCache.room_id or "") == key) then
		self.latestFinalLeaderboardCache = nil
		clearedLatest = true
	end
	if clearedRoomCache or clearedLatest or tostring(self.finalLeaderboardCacheSignature or "") ~= "" then
		self.finalLeaderboardCacheSignature = ""
		self.finalLeaderboardCacheLogSignature = ""
		final_leaderboard_cache_trace("clear"
			.. " reason=" .. clearReason
			.. " room=" .. tostring(key ~= "" and key or "nil")
			.. " clearedRoom=" .. tostring(clearedRoomCache)
			.. " clearedLatest=" .. tostring(clearedLatest))
	end
	return clearedRoomCache or clearedLatest
end

function ITGOnline:GetFinalLeaderboardCache(roomId)
	self.finalLeaderboardCache = self.finalLeaderboardCache or {}
	local key = tostring(roomId or self.currentRoomId or "")
	local currentPhase = self.currentRoom and self:NormalizeRoomPhase(self.currentRoom.phase) or ""
	if currentPhase == "lobby"
		and key ~= ""
		and tostring(self.finalLeaderboardCacheInvalidLobbyRoomId or "") == key then
		final_leaderboard_cache_trace("miss reason=invalidated_lobby_phase"
			.. " room=" .. tostring(key)
			.. " age=" .. tostring(GetTimeSinceStart() - (tonumber(self.finalLeaderboardCacheInvalidLobbyAt) or GetTimeSinceStart())))
		return nil
	end
	if key ~= "" and self.finalLeaderboardCache[key] then
		final_leaderboard_cache_trace("hit room=" .. tostring(key)
			.. " rows=" .. tostring(self.finalLeaderboardCache[key].rows and #self.finalLeaderboardCache[key].rows or 0)
			.. " source=" .. tostring(self.finalLeaderboardCache[key].source or "unknown")
			.. " rowsSummary=" .. online_score_rows_summary(self.finalLeaderboardCache[key].rows, 8))
		return self.finalLeaderboardCache[key]
	end
	if self.latestFinalLeaderboardCache
		and (key == "" or tostring(self.latestFinalLeaderboardCache.room_id or "") == key) then
		final_leaderboard_cache_trace("hit_latest requestedRoom=" .. tostring(key ~= "" and key or "nil")
			.. " cachedRoom=" .. tostring(self.latestFinalLeaderboardCache.room_id or "nil")
			.. " rows=" .. tostring(self.latestFinalLeaderboardCache.rows and #self.latestFinalLeaderboardCache.rows or 0)
			.. " source=" .. tostring(self.latestFinalLeaderboardCache.source or "unknown")
			.. " rowsSummary=" .. online_score_rows_summary(self.latestFinalLeaderboardCache.rows, 8))
		return self.latestFinalLeaderboardCache
	elseif self.latestFinalLeaderboardCache then
		final_leaderboard_cache_trace("skip_latest reason=room_mismatch requestedRoom=" .. tostring(key ~= "" and key or "nil")
			.. " cachedRoom=" .. tostring(self.latestFinalLeaderboardCache.room_id or "nil"))
	end
	return nil
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

function ITGOnline:IsTerminalPlayState(state)
	state = tostring(state or "")
	return state == "finished"
		or state == "failed"
		or state == "returned_to_lobby"
		or state == "disconnected"
end

function ITGOnline:PlayStateSummary(room)
	room = room or self.currentRoom
	local playState = room and room.play_state or nil
	local sessions = playState and playState.sessions or {}
	local finalResults = playState and playState.final_results or {}
	local players = tonumber(playState and playState.players_count) or #(sessions or {})
	if players <= 0 and room and type(room.members) == "table" then
		players = #room.members
	end
	local terminal = tonumber(playState and playState.terminal_players_count)
	local failedTerminal = tonumber(playState and playState.failed_players_count) or 0

	if terminal == nil then
		terminal = 0
		for session in ivalues(sessions or {}) do
			if self:IsTerminalPlayState(session and session.state) then
				terminal = terminal + 1
			end
		end
	end
	if failedTerminal <= 0 then
		for session in ivalues(sessions or {}) do
			if tostring(session and session.state or "") == "failed" then
				failedTerminal = failedTerminal + 1
			end
		end
	end

	local playing = tonumber(playState and playState.playing_players_count)
	if playing == nil then
		playing = math.max(0, players - terminal)
	end

	local allTerminal = playState and playState.all_players_terminal == true
	if not allTerminal then
		allTerminal = players > 0 and terminal >= players
	end

	return {
		players = players,
		terminal = terminal,
		failedTerminal = failedTerminal,
		playing = playing,
		allTerminal = allTerminal,
		allFailedTerminal = (playState and playState.all_players_failed == true) or (players > 0 and failedTerminal >= players),
		finalResults = #(finalResults or {}),
		finalResultsReady = players > 0 and #(finalResults or {}) >= players,
		failedFinalsPending = tonumber(playState and playState.failed_client_final_scores_pending_count) or 0,
		failedFinalsReady = playState and playState.all_failed_client_finals_ready == true,
		sessions = sessions or {},
	}
end

function ITGOnline:ShouldWaitForOnlineResults(room)
	room = room or self.currentRoom
	if not room then
		online_flow_trace_throttled("results_wait_no_room", 2.0,
			"results_wait_decision wait=false reason=no_room currentRoomId=" .. tostring(self.currentRoomId or "nil"))
		return false
	end
	local phase = self:NormalizeRoomPhase(room.phase)
	if phase ~= "playing" and phase ~= "results" then
		online_flow_trace_throttled("results_wait_phase_not_relevant", 2.0,
			"results_wait_decision wait=false reason=phase_not_relevant phase=" .. tostring(phase)
			.. " room=" .. tostring(room.id or self.currentRoomId or "nil"))
		return false
	end

	local state = self:CurrentUserPlayState(room)
	local roundKey, roundKeySource = self:CanonicalGameplayRoundKey("results_wait")
	local localRoundEnded = self.PlayStateKeyIsValid and self:PlayStateKeyIsValid(roundKey)
		and self.onlineGameplayEndedKey == roundKey
	local localRoundEnding = self.PlayStateKeyIsValid and self:PlayStateKeyIsValid(roundKey)
		and self.onlineGameplayEvaluationMarkInFlightKey == roundKey

	if localRoundEnding then
		online_flow_trace_throttled("results_wait_local_round_ending", 1.0,
			"results_wait_decision wait=true reason=local_round_ending"
			.. " phase=" .. tostring(phase)
			.. " state=" .. tostring(state or "nil")
			.. " roundKey=" .. tostring(roundKey)
			.. " roundKeySource=" .. tostring(roundKeySource))
		return true
	end
	if not localRoundEnded and not self:IsTerminalPlayState(state) then
		online_flow_trace_throttled("results_wait_local_not_terminal", 1.0,
			"results_wait_decision wait=false reason=local_not_terminal"
			.. " phase=" .. tostring(phase)
			.. " state=" .. tostring(state or "nil")
			.. " localRoundEnded=" .. tostring(localRoundEnded == true)
			.. " roundKey=" .. tostring(roundKey)
			.. " roundKeySource=" .. tostring(roundKeySource))
		return false
	end

	local summary = self:PlayStateSummary(room)
	if phase == "results" and summary.players > 0 and not summary.finalResultsReady then
		online_flow_trace_throttled("results_wait_phase_results_incomplete", 1.0,
			"results_wait_decision wait=true reason=results_phase_incomplete_final_results"
			.. " state=" .. tostring(state or "nil")
			.. " terminal=" .. tostring(summary.terminal)
			.. " players=" .. tostring(summary.players)
			.. " finalResults=" .. tostring(summary.finalResults))
		return true
	end
	if summary.players <= 0 then
		online_flow_trace_throttled("results_wait_no_players", 1.0,
			"results_wait_decision wait=false reason=no_players"
			.. " phase=" .. tostring(phase)
			.. " state=" .. tostring(state or "nil"))
		return false
	end
	if not summary.allTerminal then
		if phase == "results" and summary.finalResultsReady then
			online_flow_trace("results_wait_released reason=phase_results_with_final_results"
				.. " terminal=" .. tostring(summary.terminal)
				.. " players=" .. tostring(summary.players)
				.. " finalResults=" .. tostring(summary.finalResults))
			return false
		end
		online_flow_trace_throttled("results_wait_not_all_terminal", 1.0,
			"results_wait_decision wait=true reason=not_all_terminal"
			.. " phase=" .. tostring(phase)
			.. " state=" .. tostring(state or "nil")
			.. " terminal=" .. tostring(summary.terminal)
			.. " players=" .. tostring(summary.players)
			.. " finalResults=" .. tostring(summary.finalResults)
			.. " finalResultsReady=" .. tostring(summary.finalResultsReady == true))
		return true
	end
	if phase == "playing" and summary.allFailedTerminal and not summary.finalResultsReady then
		online_flow_trace_throttled("results_wait_all_failed_pending_finals", 1.0,
			"results_wait_decision wait=true reason=all_failed_pending_client_finals"
			.. " terminal=" .. tostring(summary.terminal)
			.. " failedTerminal=" .. tostring(summary.failedTerminal)
			.. " players=" .. tostring(summary.players)
			.. " finalResults=" .. tostring(summary.finalResults)
			.. " finalResultsReady=" .. tostring(summary.finalResultsReady == true)
			.. " failedFinalsPending=" .. tostring(summary.failedFinalsPending))
		return true
	end
	if phase ~= "results" then
		online_flow_trace_throttled("results_wait_all_terminal_not_results", 1.0,
			"results_wait_decision wait=true reason=all_terminal_waiting_results_phase"
			.. " terminal=" .. tostring(summary.terminal)
			.. " players=" .. tostring(summary.players)
			.. " finalResults=" .. tostring(summary.finalResults))
		return true
	end
	local wait = not summary.finalResultsReady
	online_flow_trace_throttled("results_wait_final_results", 1.0,
		"results_wait_decision wait=" .. tostring(wait == true)
		.. " reason=results_phase_final_results"
		.. " terminal=" .. tostring(summary.terminal)
		.. " players=" .. tostring(summary.players)
		.. " finalResults=" .. tostring(summary.finalResults)
		.. " finalResultsReady=" .. tostring(summary.finalResultsReady == true))
	return wait
end

function ITGOnline:ShouldBlockEvaluationExit(reason, room)
	room = room or self.currentRoom
	if not room then
		online_flow_trace("evaluation_exit_block_decision block=false reason=no_room source=" .. tostring(reason or "unknown")
			.. " currentRoomId=" .. tostring(self.currentRoomId or "nil"))
		return false
	end

	local phase = self:NormalizeRoomPhase(room.phase)
	local summary = self:PlayStateSummary(room)
	if phase ~= "results" then
		online_flow_trace_throttled("evaluation_exit_block_not_results", 1.0,
			"evaluation_exit_block_decision block=false reason=room_not_results"
			.. " source=" .. tostring(reason or "unknown")
			.. " room=" .. tostring(room.id or self.currentRoomId or "nil")
			.. " phase=" .. tostring(phase)
			.. " players=" .. tostring(summary.players)
			.. " terminal=" .. tostring(summary.terminal)
			.. " failedTerminal=" .. tostring(summary.failedTerminal)
			.. " finalResults=" .. tostring(summary.finalResults)
			.. " finalResultsReady=" .. tostring(summary.finalResultsReady == true)
			.. " failedFinalsPending=" .. tostring(summary.failedFinalsPending))
		return false
	end

	if summary.players > 0 and not summary.finalResultsReady then
		online_flow_trace_throttled("evaluation_exit_block_results_not_ready", 1.0,
			"evaluation_exit_block_decision block=true reason=final_results_not_ready"
			.. " source=" .. tostring(reason or "unknown")
			.. " room=" .. tostring(room.id or self.currentRoomId or "nil")
			.. " phase=" .. tostring(phase)
			.. " players=" .. tostring(summary.players)
			.. " finalResults=" .. tostring(summary.finalResults)
			.. " finalResultsReady=" .. tostring(summary.finalResultsReady == true))
		return true
	end

	online_flow_trace("evaluation_exit_block_decision block=false reason=results_ready"
		.. " source=" .. tostring(reason or "unknown")
		.. " room=" .. tostring(room.id or self.currentRoomId or "nil")
		.. " phase=" .. tostring(phase)
		.. " players=" .. tostring(summary.players)
		.. " finalResults=" .. tostring(summary.finalResults))
	return false
end

function ITGOnline:MarkGameplayCompleteForEvaluation(source)
	if not self.currentRoomId or not self.currentRoom then return false end

	local phase = self:NormalizeRoomPhase(self.currentRoom.phase)
	if phase ~= "starting" and phase ~= "playing" and phase ~= "results" then
		online_flow_trace("mark_terminal_skipped source=" .. tostring(source or "unknown")
			.. " phase=" .. tostring(phase))
		return false
	end

	local roundKey, roundKeySource = self:CanonicalGameplayRoundKey(source)
	local activeRoundKey = tostring(self.activeGameplayRoundKey or "")
	if not (self.PlayStateKeyIsValid and self:PlayStateKeyIsValid(roundKey)) then
		online_flow_trace("mark_terminal_skipped source=" .. tostring(source or "unknown")
			.. " reason=invalid_canonical_round_key"
			.. " active=" .. tostring(activeRoundKey)
			.. " roundKey=" .. tostring(roundKey)
			.. " roundKeySource=" .. tostring(roundKeySource))
		return false
	end

	if self.onlineGameplayEvaluationMarkKey == roundKey then
		return true
	end
	if self.onlineGameplayEvaluationMarkInFlightKey == roundKey then
		return true
	end
	if self.onlineGameplayEvaluationRetryKey ~= roundKey then
		self.onlineGameplayEvaluationRetryKey = roundKey
		self.onlineGameplayEvaluationRetryCount = 0
		self.onlineGameplayEvaluationNextRetryAt = 0
	end
	if GetTimeSinceStart() < (tonumber(self.onlineGameplayEvaluationNextRetryAt) or 0) then
		return true
	end

	local player = first_enabled_player()
	local stats = player and STATSMAN:GetCurStageStats():GetPlayerStageStats(player) or nil
	local failedOk, failedValue = pcall(function() return stats and stats:GetFailed() end)
	local failed = failedOk and failedValue == true
	local currentPlayState = self:CurrentUserPlayState(self.currentRoom)
	if tostring(currentPlayState or "") == "failed" then
		failed = true
	end

	online_flow_trace("mark_terminal source=" .. tostring(source or "unknown")
		.. " phase=" .. tostring(phase)
		.. " failed=" .. tostring(failed)
		.. " currentPlayState=" .. tostring(currentPlayState or "nil")
		.. " roundKey=" .. tostring(roundKey)
		.. " roundKeySource=" .. tostring(roundKeySource)
		.. " lastDisplayed=" .. tostring(self.lastDisplayedScoreSnapshot and self:ScoreSnapshotDisplayedPercent(self.lastDisplayedScoreSnapshot) or "nil")
		.. " pendingDisplayed=" .. tostring(self.pendingLiveScoreSnapshot and self:ScoreSnapshotDisplayedPercent(self.pendingLiveScoreSnapshot) or "nil")
		.. " lastFinalScoreKey=" .. tostring(self.lastFinalScoreKey or "")
		.. " finalInFlightKey=" .. tostring(self.lastFinalScoreInFlightKey or ""))

	if failed then
		local now = GetTimeSinceStart()
		local stabilizeSeconds = tonumber(self.failedFinalScoreStabilizeSeconds) or 0.35
		local stabilizeKey = tostring(self.failedFinalScoreStabilizeKey or "")
		local stabilizeAt = tonumber(self.failedFinalScoreStabilizeAt) or 0
		local candidateSnapshot = self.BuildCurrentScoreSnapshot and self:BuildCurrentScoreSnapshot() or nil
		local candidateDisplayed = candidateSnapshot and self.ScoreSnapshotDisplayedPercent and self:ScoreSnapshotDisplayedPercent(candidateSnapshot) or nil
		if stabilizeKey ~= roundKey then
			self.failedFinalScoreStabilizeKey = roundKey
			self.failedFinalScoreStabilizeAt = now + stabilizeSeconds
			self.onlineGameplayEvaluationNextRetryAt = self.failedFinalScoreStabilizeAt
			online_flow_trace("mark_terminal_failed_final_stabilizing"
				.. " source=" .. tostring(source or "unknown")
				.. " room=" .. tostring(self.currentRoomId or "nil")
				.. " roundKey=" .. tostring(roundKey)
				.. " delay=" .. string.format("%.3f", stabilizeSeconds)
				.. " candidateDisplayed=" .. tostring(candidateDisplayed or "nil")
				.. " hadDisplayedSnapshot=" .. tostring(self.lastDisplayedScoreSnapshot ~= nil)
				.. " currentPlayState=" .. tostring(currentPlayState or "nil"))
			return true
		end
		if now < stabilizeAt then
			self.onlineGameplayEvaluationNextRetryAt = stabilizeAt
			online_flow_trace("mark_terminal_failed_final_stabilizing_wait"
				.. " source=" .. tostring(source or "unknown")
				.. " room=" .. tostring(self.currentRoomId or "nil")
				.. " roundKey=" .. tostring(roundKey)
				.. " remaining=" .. string.format("%.3f", math.max(0, stabilizeAt - now))
				.. " candidateDisplayed=" .. tostring(candidateDisplayed or "nil")
				.. " hadDisplayedSnapshot=" .. tostring(self.lastDisplayedScoreSnapshot ~= nil)
				.. " currentPlayState=" .. tostring(currentPlayState or "nil"))
			return true
		end
		online_flow_trace("mark_terminal_failed_final_stabilized"
			.. " source=" .. tostring(source or "unknown")
			.. " room=" .. tostring(self.currentRoomId or "nil")
			.. " roundKey=" .. tostring(roundKey)
			.. " waited=" .. string.format("%.3f", math.max(0, now - (stabilizeAt - stabilizeSeconds)))
			.. " candidateDisplayed=" .. tostring(candidateDisplayed or "nil")
			.. " hadDisplayedSnapshot=" .. tostring(self.lastDisplayedScoreSnapshot ~= nil)
			.. " currentPlayState=" .. tostring(currentPlayState or "nil"))
	end

	if phase == "results" then
		self.onlineGameplayEvaluationMarkKey = roundKey
		self.onlineGameplayEndedKey = roundKey
		self.onlineGameplayEvaluationTerminalErrorKey = ""
		self.onlineGameplayEvaluationRetryCount = 0
		self.onlineGameplayEvaluationNextRetryAt = 0
		online_flow_trace("mark_terminal_skipped_results_phase roundKey=" .. tostring(roundKey))
		if self.FetchPlayState then
			self:FetchPlayState()
		end
		return true
	end

	local scheduleTerminalRetry = function(label, decoded, response)
		self.onlineGameplayEvaluationRetryCount = (tonumber(self.onlineGameplayEvaluationRetryCount) or 0) + 1
		local retryCount = math.max(1, tonumber(self.onlineGameplayEvaluationRetryCount) or 1)
		local maxRetries = math.max(1, tonumber(self.onlineGameplayEvaluationMaxRetries) or 3)
		if retryCount >= maxRetries then
			self.onlineGameplayEvaluationNextRetryAt = GetTimeSinceStart() + 8.0
			online_flow_trace(tostring(label or "mark_terminal_retry_exhausted")
				.. " roundKey=" .. tostring(roundKey)
				.. " retry=" .. tostring(retryCount)
				.. " message=" .. tostring(response_message(response, decoded, "terminal state rejected")))
			if self.onlineGameplayEvaluationTerminalErrorKey ~= roundKey then
				self.onlineGameplayEvaluationTerminalErrorKey = roundKey
				MESSAGEMAN:Broadcast("OnlineResponseStatus", {
					event = "terminalPlayState",
					success = false,
					message = response_message(response, decoded, "Could not confirm final play state.")
				})
			end
			return
		end
		local retryDelay = math.min(8.0, math.pow(2, math.min(3, retryCount - 1)))
		self.onlineGameplayEvaluationNextRetryAt = GetTimeSinceStart() + retryDelay
		online_flow_trace(tostring(label or "mark_terminal_retry")
			.. " roundKey=" .. tostring(roundKey)
			.. " retry=" .. tostring(retryCount)
			.. " nextIn=" .. string.format("%.1f", retryDelay)
			.. " message=" .. tostring(response_message(response, decoded, "terminal state rejected")))
	end

	if self.SendScore and phase == "playing" then
		self.onlineGameplayEvaluationMarkInFlightKey = roundKey
		if failed then
			self.scoreInFlightFingerprint = nil
			self.pendingLiveScoreSnapshot = nil
			self.pendingLiveScoreRoundKey = ""
			online_flow_trace("final_failed_score_prepare"
				.. " source=" .. tostring(source or "unknown")
				.. " room=" .. tostring(self.currentRoomId or "nil")
				.. " roundKey=" .. tostring(roundKey)
				.. " currentPlayState=" .. tostring(currentPlayState or "nil")
				.. " hadDisplayedSnapshot=" .. tostring(self.lastDisplayedScoreSnapshot ~= nil))
		end
		self:SendScore(true, true, nil, function(scoreOk, scoreDecoded, scoreResponse)
			if not scoreOk then
				if response_error_code(scoreResponse, scoreDecoded) == "score_already_finalized" then
					if self.onlineGameplayEvaluationMarkInFlightKey == roundKey then
						self.onlineGameplayEvaluationMarkInFlightKey = ""
					end
					self.onlineGameplayEvaluationMarkKey = roundKey
					self.onlineGameplayEndedKey = roundKey
					self.onlineGameplayEvaluationTerminalErrorKey = ""
					self.onlineGameplayEvaluationRetryCount = 0
					self.onlineGameplayEvaluationNextRetryAt = 0
					online_flow_trace("mark_terminal_score_already_finalized roundKey=" .. tostring(roundKey))
					if self.FetchPlayState then
						self:FetchPlayState()
					end
					return
				end
				if self.onlineGameplayEvaluationMarkInFlightKey == roundKey then
					self.onlineGameplayEvaluationMarkInFlightKey = ""
				end
				self.onlineGameplayEvaluationRetryCount = (tonumber(self.onlineGameplayEvaluationRetryCount) or 0) + 1
				online_flow_trace("mark_terminal_waiting_for_score_retry roundKey=" .. tostring(roundKey)
					.. " retry=" .. tostring(self.onlineGameplayEvaluationRetryCount)
					.. " message=" .. tostring(response_message(scoreResponse, scoreDecoded, "score rejected")))
				if self.onlineGameplayEvaluationRetryCount >= (tonumber(self.onlineGameplayEvaluationMaxRetries) or 3) then
					self.onlineGameplayEvaluationNextRetryAt = GetTimeSinceStart() + 2.0
					online_flow_trace("mark_terminal_without_score_blocked"
						.. " reason=final_score_retry_exhausted"
						.. " roundKey=" .. tostring(roundKey)
						.. " decision=retry_final_score")
				else
					self.onlineGameplayEvaluationNextRetryAt = GetTimeSinceStart() + 1.0
				end
				return
			end

			local terminalCallback = function(terminalOk, terminalDecoded, terminalResponse)
				if self.onlineGameplayEvaluationMarkInFlightKey == roundKey then
					self.onlineGameplayEvaluationMarkInFlightKey = ""
				end
				if terminalOk then
					self.onlineGameplayEvaluationMarkKey = roundKey
					self.onlineGameplayEndedKey = roundKey
					self.onlineGameplayEvaluationTerminalErrorKey = ""
					self.onlineGameplayEvaluationRetryCount = 0
					self.onlineGameplayEvaluationNextRetryAt = 0
					return
				end

				scheduleTerminalRetry("mark_terminal_failed_after_score", terminalDecoded, terminalResponse)
			end

			local scoreRoomPhase = self:NormalizeRoomPhase(
				scoreDecoded and (scoreDecoded.room_phase or scoreDecoded.room and scoreDecoded.room.phase)
					or self.currentRoom and self.currentRoom.phase
					or phase
			)
			if scoreRoomPhase == "results" then
				if self.onlineGameplayEvaluationMarkInFlightKey == roundKey then
					self.onlineGameplayEvaluationMarkInFlightKey = ""
				end
				self.onlineGameplayEvaluationMarkKey = roundKey
				self.onlineGameplayEndedKey = roundKey
				self.onlineGameplayEvaluationTerminalErrorKey = ""
				self.onlineGameplayEvaluationRetryCount = 0
				self.onlineGameplayEvaluationNextRetryAt = 0
				if failed then
					self:ApplyLocalPlayState("failed", "mark_terminal_final_score_accepted_results_phase")
				else
					self:ApplyLocalPlayState("finished", "mark_terminal_final_score_accepted_results_phase")
				end
				online_flow_trace("mark_terminal_skipped_after_score"
					.. " reason=server_already_results"
					.. " room=" .. tostring(self.currentRoomId or "nil")
					.. " roundKey=" .. tostring(roundKey)
					.. " scoreRoomPhase=" .. tostring(scoreRoomPhase)
					.. " lastFinalScoreKey=" .. tostring(self.lastFinalScoreKey or "")
					.. " hasFinalResult=" .. tostring(self:CurrentUserHasFinalResult(self.currentRoom) == true))
				if self.FetchPlayState then self:FetchPlayState() end
				return
			end

			if failed and self.MarkPlayFailed then
				self:MarkPlayFailed(terminalCallback)
			elseif self.MarkPlayFinished then
				self:MarkPlayFinished(terminalCallback)
			end
		end, { forceFailed = failed, forceFinalFailed = failed })
	else
		self.onlineGameplayEvaluationNextRetryAt = GetTimeSinceStart() + 2.0
		online_flow_trace("mark_terminal_without_score_blocked"
			.. " reason=no_score_submission_path"
			.. " roundKey=" .. tostring(roundKey)
			.. " decision=wait_for_score_api")
	end

	return true
end

function ITGOnline:ShouldHoldGameplayForEvaluation()
	if not self.currentRoomId or not self.currentRoom then return false end
	local screen = SCREENMAN:GetTopScreen()
	local screenName = screen and screen:GetName() or "NoScreen"
	if not self:IsOnlineGameplayScreen(screenName) then return false end
	local phase = self:NormalizeRoomPhase(self.currentRoom and self.currentRoom.phase)
	local roundKey = self.CanonicalGameplayRoundKey and self:CanonicalGameplayRoundKey("evaluation_guard") or (self.PlayStateKey and self:PlayStateKey() or "")
	if phase == "results"
		and not self:CurrentUserHasFinalResult(self.currentRoom)
		and tostring(self.lastFinalScoreKey or "") ~= tostring(roundKey or "") then
		local now = GetTimeSinceStart()
		if tostring(self.lastFinalScoreInFlightKey or "") == tostring(roundKey or "")
			or tostring(self.onlineGameplayEvaluationGuardInFlightKey or "") == tostring(roundKey or "") then
			online_flow_trace_throttled("evaluation_guard_final_inflight", 1.0,
				"evaluation_guard_hold reason=final_score_inflight"
				.. " room=" .. tostring(self.currentRoomId or "nil")
				.. " roundKey=" .. tostring(roundKey or "")
				.. " lastFinalScoreInFlightKey=" .. tostring(self.lastFinalScoreInFlightKey or "")
				.. " guardInFlightKey=" .. tostring(self.onlineGameplayEvaluationGuardInFlightKey or ""))
			return true
		end

		if now < (tonumber(self.onlineGameplayEvaluationGuardNextAttemptAt) or 0) then
			online_flow_trace_throttled("evaluation_guard_backoff", 1.0,
				"evaluation_guard_hold reason=retry_backoff"
				.. " room=" .. tostring(self.currentRoomId or "nil")
				.. " roundKey=" .. tostring(roundKey or "")
				.. " retryIn=" .. tostring((tonumber(self.onlineGameplayEvaluationGuardNextAttemptAt) or 0) - now))
			return true
		end

		if not self.SendScore then
			online_flow_trace("evaluation_guard_hold reason=no_send_score_api"
				.. " room=" .. tostring(self.currentRoomId or "nil")
				.. " roundKey=" .. tostring(roundKey or ""))
			return true
		end

		self.onlineGameplayEvaluationGuardInFlightKey = roundKey
		self.onlineGameplayEvaluationGuardNextAttemptAt = now + 1.0
		online_flow_trace("evaluation_guard_final_score_submit"
			.. " room=" .. tostring(self.currentRoomId or "nil")
			.. " roundKey=" .. tostring(roundKey or "")
			.. " phase=" .. tostring(phase)
			.. " screen=" .. tostring(screenName)
			.. " hasDisplayedSnapshot=" .. tostring(self.lastDisplayedScoreSnapshot ~= nil))

		self:SendScore(true, true, nil, function(ok, decoded, response)
			if tostring(self.onlineGameplayEvaluationGuardInFlightKey or "") == tostring(roundKey or "") then
				self.onlineGameplayEvaluationGuardInFlightKey = ""
			end

			if ok then
				self.lastFinalScoreKey = roundKey
				self.onlineGameplayEvaluationGuardNextAttemptAt = 0
				online_flow_trace("evaluation_guard_final_score_accepted"
					.. " room=" .. tostring(self.currentRoomId or "nil")
					.. " roundKey=" .. tostring(roundKey or "")
					.. " status=" .. tostring(response and response.statusCode or "nil"))
				if self.FetchPlayState then self:FetchPlayState() end
				return
			end

			self.onlineGameplayEvaluationGuardNextAttemptAt = GetTimeSinceStart() + 1.0
			online_flow_trace("evaluation_guard_final_score_rejected"
				.. " room=" .. tostring(self.currentRoomId or "nil")
				.. " roundKey=" .. tostring(roundKey or "")
				.. " status=" .. tostring(response and response.statusCode or "nil")
				.. " errorCode=" .. tostring(response_error_code(response, decoded) or "nil")
				.. " message=" .. tostring(response_message(response, decoded, "final score rejected")))
			if self.FetchPlayState then self:FetchPlayState() end
		end)

		return true
	end

	self:MarkGameplayCompleteForEvaluation("engine_hold")
	local waiting = self:ShouldWaitForOnlineResults()
	local summary = self:PlayStateSummary()
	local validRoundKey = self.PlayStateKeyIsValid and self:PlayStateKeyIsValid(roundKey)
	local now = GetTimeSinceStart()
	local minimumVisibleHoldSeconds = 2.25
	online_flow_trace_throttled("evaluation_guard_decision_context", 1.0,
		"evaluation_guard_decision_context"
		.. " room=" .. tostring(self.currentRoomId or "nil")
		.. " screen=" .. tostring(screenName)
		.. " phase=" .. tostring(phase)
		.. " normalizedPhase=" .. tostring(self:NormalizeRoomPhase(self.currentRoom and self.currentRoom.phase))
		.. " roundKey=" .. tostring(roundKey or "")
		.. " validRoundKey=" .. tostring(validRoundKey == true)
		.. " waiting=" .. tostring(waiting == true)
		.. " hasCurrentFinal=" .. tostring(self:CurrentUserHasFinalResult(self.currentRoom) == true)
		.. " lastFinalScoreKey=" .. tostring(self.lastFinalScoreKey or "")
		.. " finalInFlightKey=" .. tostring(self.lastFinalScoreInFlightKey or "")
		.. " players=" .. tostring(summary and summary.players or "nil")
		.. " terminal=" .. tostring(summary and summary.terminal or "nil")
		.. " failedTerminal=" .. tostring(summary and summary.failedTerminal or "nil")
		.. " finalResults=" .. tostring(summary and summary.finalResults or "nil")
		.. " failedFinalsPending=" .. tostring(summary and summary.failedFinalsPending or "nil")
		.. " finalResultsReady=" .. tostring(summary and summary.finalResultsReady == true))

	local releaseWithResults = summary
		and summary.players > 0
		and summary.finalResultsReady == true
		and self:NormalizeRoomPhase(self.currentRoom and self.currentRoom.phase) == "results"

	if summary and summary.players > 0 and releaseWithResults and not waiting then
		self.onlineGameplayEvaluationHoldStartedKey = roundKey
		self.onlineGameplayEvaluationMinimumHoldUntil = 0
		self.onlineGameplayAllTerminalHoldKey = roundKey
		self.onlineGameplayAllTerminalHoldUntil = 0
		local releaseLogKey = validRoundKey and roundKey or table.concat({
			tostring(self.currentRoomId or ""),
			tostring(summary.terminal or ""),
			tostring(summary.players or ""),
			tostring(summary.finalResults or ""),
		}, "|")
		if self.onlineGameplayReleaseLoggedKey ~= releaseLogKey then
			self.onlineGameplayReleaseLoggedKey = releaseLogKey
			online_flow_trace("hold_gameplay_release reason=results_final_results_ready"
				.. " terminal=" .. tostring(summary.terminal)
				.. " players=" .. tostring(summary.players)
				.. " finalResults=" .. tostring(summary.finalResults))
		end
		return false
	end

	if summary
		and self:NormalizeRoomPhase(self.currentRoom and self.currentRoom.phase) == "playing"
		and summary.allFailedTerminal == true
		and summary.finalResultsReady ~= true
	then
		self.onlineGameplayEvaluationHoldStartedKey = roundKey
		self.onlineGameplayEvaluationMinimumHoldUntil = 0
		self.onlineGameplayAllTerminalHoldKey = roundKey
		self.onlineGameplayAllTerminalHoldUntil = 0
		if self.FetchPlayState then
			if not self.onlineGameplayHoldFetchAt or (now - self.onlineGameplayHoldFetchAt) >= 0.75 then
				self.onlineGameplayHoldFetchAt = now
				self:FetchPlayState()
			end
		end
		online_flow_trace_throttled("hold_gameplay_all_failed_pending_finals", 1.0,
			"hold_gameplay_wait reason=all_failed_pending_client_finals"
			.. " terminal=" .. tostring(summary.terminal)
			.. " failedTerminal=" .. tostring(summary.failedTerminal)
			.. " players=" .. tostring(summary.players)
			.. " finalResults=" .. tostring(summary.finalResults)
			.. " failedFinalsPending=" .. tostring(summary.failedFinalsPending))
		return true
	end

	if validRoundKey and self.onlineGameplayEvaluationHoldStartedKey ~= roundKey then
		self.onlineGameplayEvaluationHoldStartedKey = roundKey
		self.onlineGameplayEvaluationMinimumHoldUntil = now + minimumVisibleHoldSeconds
		online_flow_trace("hold_gameplay_minimum start roundKey=" .. tostring(roundKey)
			.. " until=" .. tostring(self.onlineGameplayEvaluationMinimumHoldUntil))
	end

		online_flow_trace_throttled("hold_gameplay_before_evaluation", 1.0, "hold_gameplay_before_evaluation waiting=" .. tostring(waiting == true)
			.. " phase=" .. tostring(self.currentRoom and self.currentRoom.phase or "nil")
			.. " terminal=" .. tostring(summary and summary.terminal or "nil")
			.. " failedTerminal=" .. tostring(summary and summary.failedTerminal or "nil")
			.. " players=" .. tostring(summary and summary.players or "nil")
			.. " allTerminal=" .. tostring(summary and summary.allTerminal == true)
			.. " allFailedTerminal=" .. tostring(summary and summary.allFailedTerminal == true)
			.. " finalResults=" .. tostring(summary and summary.finalResults or "nil")
			.. " finalResultsReady=" .. tostring(summary and summary.finalResultsReady == true)
			.. " failedFinalsPending=" .. tostring(summary and summary.failedFinalsPending or "nil"))

	if waiting and self.FetchPlayState then
		if not self.onlineGameplayHoldFetchAt or (now - self.onlineGameplayHoldFetchAt) >= 0.75 then
			self.onlineGameplayHoldFetchAt = now
			self:FetchPlayState()
		end

		self.onlineGameplayAllTerminalHoldKey = ""
		self.onlineGameplayAllTerminalHoldUntil = 0
	end

	if waiting then return true end

	if validRoundKey and self.onlineGameplayEvaluationHoldStartedKey == roundKey then
		local minimumRemaining = (tonumber(self.onlineGameplayEvaluationMinimumHoldUntil) or 0) - now
		if minimumRemaining > 0 then
			online_flow_trace_throttled("hold_gameplay_minimum_wait", 0.5,
				"hold_gameplay_minimum_wait"
				.. " roundKey=" .. tostring(roundKey)
				.. " remaining=" .. tostring(minimumRemaining)
				.. " phase=" .. tostring(self.currentRoom and self.currentRoom.phase or "nil")
				.. " waiting=" .. tostring(waiting == true))
			return true
		end
	end

	if summary and summary.players > 0 and releaseWithResults then
		if self.onlineGameplayAllTerminalHoldKey ~= roundKey then
			self.onlineGameplayAllTerminalHoldKey = roundKey
			self.onlineGameplayAllTerminalHoldUntil = now + 2.0
			online_flow_trace("hold_gameplay_after_terminal_or_results start roundKey=" .. tostring(roundKey)
				.. " reason=results_final_results_ready"
				.. " until=" .. tostring(self.onlineGameplayAllTerminalHoldUntil))
		end

		local remaining = (tonumber(self.onlineGameplayAllTerminalHoldUntil) or 0) - now
		if remaining > 0 then
			return true
		end
	end

	online_flow_trace_throttled("hold_gameplay_release_no_hold_needed", 1.0,
		"hold_gameplay_release reason=no_hold_needed"
		.. " room=" .. tostring(self.currentRoomId or "nil")
		.. " phase=" .. tostring(self.currentRoom and self.currentRoom.phase or "nil")
		.. " roundKey=" .. tostring(roundKey or "")
		.. " waiting=" .. tostring(waiting == true)
		.. " players=" .. tostring(summary and summary.players or "nil")
		.. " finalResultsReady=" .. tostring(summary and summary.finalResultsReady == true))
	return false
end

ITGOnlineMarkGameplayCompleteForEvaluation = function()
	return ITGOnline and ITGOnline.MarkGameplayCompleteForEvaluation and ITGOnline:MarkGameplayCompleteForEvaluation("global")
end

ITGOnlineShouldHoldGameplayForEvaluation = function()
	return ITGOnline and ITGOnline.ShouldHoldGameplayForEvaluation and ITGOnline:ShouldHoldGameplayForEvaluation()
end

ITGOnlineShouldKeepGameplayAliveAfterLocalFail = function()
	if not (ITGOnline and ITGOnline.currentRoomId and ITGOnline.currentRoom) then
		if ITGOnline and online_flow_trace_throttled then
			online_flow_trace_throttled("keep_alive_after_fail_no_room", 2.0,
				"keep_alive_after_fail decision=false reason=no_room"
				.. " room=" .. tostring(ITGOnline and ITGOnline.currentRoomId or "nil")
				.. " hasRoom=" .. tostring(ITGOnline and ITGOnline.currentRoom ~= nil))
		end
		return false
	end
	local phase = ITGOnline:NormalizeRoomPhase(ITGOnline.currentRoom.phase)
	if phase ~= "playing" and phase ~= "starting" then
		online_flow_trace_throttled("keep_alive_after_fail_phase", 2.0,
			"keep_alive_after_fail decision=false reason=phase"
			.. " phase=" .. tostring(phase)
			.. " room=" .. tostring(ITGOnline.currentRoomId or "nil"))
		return false
	end
	local summary = ITGOnline:PlayStateSummary()
	if summary
		and summary.allFailedTerminal == true
		and summary.finalResultsReady ~= true
		and phase == "playing"
	then
		online_flow_trace_throttled("keep_alive_after_fail_all_failed_pending_finals", 1.0,
			"keep_alive_after_fail decision=true reason=all_failed_pending_client_finals"
			.. " players=" .. tostring(summary.players)
			.. " terminal=" .. tostring(summary.terminal)
			.. " failedTerminal=" .. tostring(summary.failedTerminal)
			.. " failedFinalsPending=" .. tostring(summary.failedFinalsPending))
		return true
	end
	if not summary or tonumber(summary.players or 0) <= 1 then
		online_flow_trace_throttled("keep_alive_after_fail_solo", 2.0,
			"keep_alive_after_fail decision=false reason=not_multiplayer"
			.. " players=" .. tostring(summary and summary.players or "nil")
			.. " phase=" .. tostring(phase))
		return false
	end
	local keepAlive = summary.allTerminal ~= true
	if summary.allFailedTerminal == true and summary.finalResultsReady ~= true and phase == "playing" then
		keepAlive = true
	end
	online_flow_trace_throttled("keep_alive_after_fail_decision", 1.0,
		"keep_alive_after_fail decision=" .. tostring(keepAlive == true)
		.. " phase=" .. tostring(phase)
		.. " terminal=" .. tostring(summary.terminal)
		.. " failedTerminal=" .. tostring(summary.failedTerminal)
		.. " players=" .. tostring(summary.players)
		.. " allTerminal=" .. tostring(summary.allTerminal == true)
		.. " allFailedTerminal=" .. tostring(summary.allFailedTerminal == true)
		.. " finalResultsReady=" .. tostring(summary.finalResultsReady == true)
		.. " failedFinalsPending=" .. tostring(summary.failedFinalsPending))
	return keepAlive
end

function ITGOnline:PreferredScreenForRoomPhase(screenName)
	if not self.currentRoom then
		online_flow_trace("preferred=nil reason=no_current_room screen=" .. tostring(screenName or "nil"))
		return nil
	end

	self.preferredScreenDecisionSequence = (tonumber(self.preferredScreenDecisionSequence) or 0) + 1
	local decisionId = self.preferredScreenDecisionSequence
	local topScreen = SCREENMAN and SCREENMAN:GetTopScreen() or nil
	local topScreenName = topScreen and topScreen.GetName and topScreen:GetName() or "nil"
	local phase = self:NormalizeRoomPhase(self.currentRoom.phase)
	local playState = tostring(self:CurrentUserPlayState(self.currentRoom) or "")
	local roundKey = self.PlayStateKey and self:PlayStateKey() or ""
	local localRoundEnded = self.PlayStateKeyIsValid and self:PlayStateKeyIsValid(roundKey) and self.onlineGameplayEndedKey == roundKey
	local summary = self.PlayStateSummary and self:PlayStateSummary(self.currentRoom) or nil
	online_flow_trace("preferred_check decisionId=" .. tostring(decisionId)
		.. " screen=" .. tostring(screenName or "nil")
		.. " topScreen=" .. tostring(topScreenName)
		.. " screenMatchesTop=" .. tostring(tostring(screenName or "") == tostring(topScreenName or ""))
		.. " room=" .. tostring(self.currentRoomId or "nil")
		.. " phase=" .. tostring(phase)
		.. " playState=" .. tostring(playState)
		.. " roundKey=" .. tostring(roundKey)
		.. " localRoundEnded=" .. tostring(localRoundEnded == true)
		.. " activeRoundKey=" .. tostring(self.activeGameplayRoundKey or "")
		.. " endedKey=" .. tostring(self.onlineGameplayEndedKey or "")
		.. " screenGeneration=" .. tostring(self.screenGeneration or "nil")
		.. " optionsPresentedKey=" .. tostring(self.onlineOptionsPresentedSelectionKey or "")
		.. " evaluationShownKey=" .. tostring(self.onlineGameplayEvaluationShownKey or "")
		.. " evaluationReturnedKey=" .. tostring(self.onlineGameplayEvaluationReturnedKey or "")
		.. " finalResultsReady=" .. tostring(summary and summary.finalResultsReady == true)
		.. " summaryPlayers=" .. tostring(summary and summary.players or "nil")
		.. " summaryTerminal=" .. tostring(summary and summary.terminal or "nil")
		.. " summaryFinalResults=" .. tostring(summary and summary.finalResults or "nil"))

	if self:IsOnlineOptionsScreen(screenName) and phase == "results" and self.songSelectionInFlightKey ~= "" then
		online_flow_trace("preferred=nil reason=options_during_song_selection playState=" .. tostring(playState)
			.. " selectionKey=" .. tostring(self.songSelectionInFlightKey))
		return nil
	end

	if phase == "results" and self.songSelectionInFlightKey ~= "" then
		online_flow_trace("preferred=nil reason=results_during_song_selection"
			.. " screen=" .. tostring(screenName or "nil")
			.. " playState=" .. tostring(playState)
			.. " selectionKey=" .. tostring(self.songSelectionInFlightKey))
		return nil
	end

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
			if playState == "returned_to_lobby" or playState == "disconnected" then
				online_flow_trace("preferred=lobby reason=gameplay_user_left_song playState=" .. tostring(playState))
				return "lobby"
			end
			online_flow_trace("preferred=nil reason=already_in_gameplay playState=" .. tostring(playState)
				.. " roundEnded=" .. tostring(localRoundEnded))
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
		online_flow_trace_throttled(
			"preferred_playing_non_gameplay_screen",
			5.0,
			"preferred=lobby reason=playing_non_gameplay_screen playState=" .. tostring(playState) .. " roundEnded=" .. tostring(localRoundEnded)
		)
		return "lobby"
	end

	if phase == "results" then
		if self:IsOnlineGameplayScreen(screenName) then
			local summary = self.PlayStateSummary and self:PlayStateSummary(self.currentRoom) or nil
			if summary and summary.players > 0 and summary.finalResultsReady ~= true then
				online_flow_trace_throttled("preferred_results_incomplete_hold_gameplay", 1.0,
					"preferred=nil reason=results_incomplete_final_results"
					.. " playState=" .. tostring(playState)
					.. " players=" .. tostring(summary.players)
					.. " finalResults=" .. tostring(summary.finalResults))
				return nil
			end
			if self.ShouldHoldGameplayForEvaluation and self:ShouldHoldGameplayForEvaluation() then
				online_flow_trace_throttled("preferred_hold_gameplay_before_evaluation", 1.0, "preferred=nil reason=hold_gameplay_before_evaluation playState=" .. tostring(playState))
				return nil
			end
			online_flow_trace("preferred=evaluation reason=results_while_in_gameplay playState=" .. tostring(playState))
			return "evaluation"
		end
		if screenName == "ScreenOnlineLobbies" then
			local summary = self.PlayStateSummary and self:PlayStateSummary(self.currentRoom) or nil
			local userTerminal = self.IsTerminalPlayState and self:IsTerminalPlayState(playState)
			local userHasFinalResult = self.CurrentUserHasFinalResult and self:CurrentUserHasFinalResult(self.currentRoom) == true
			local alreadyShown = self:PlayStateKeyIsValid(roundKey) and self.onlineGameplayEvaluationShownKey == roundKey
			local alreadyReturned = self:PlayStateKeyIsValid(roundKey) and self.onlineGameplayEvaluationReturnedKey == roundKey
			if summary and summary.finalResultsReady == true and (userTerminal or userHasFinalResult) and not alreadyShown and not alreadyReturned then
				online_flow_trace("preferred=evaluation reason=results_ready_while_in_lobby"
					.. " playState=" .. tostring(playState)
					.. " userTerminal=" .. tostring(userTerminal == true)
					.. " userHasFinalResult=" .. tostring(userHasFinalResult == true)
					.. " finalResults=" .. tostring(summary.finalResults or "nil")
					.. " roundKey=" .. tostring(roundKey))
				return "evaluation"
			end
			if summary and summary.finalResultsReady == true and (userTerminal or userHasFinalResult) then
				online_flow_trace("preferred=nil reason=results_ready_lobby_already_handled"
					.. " playState=" .. tostring(playState)
					.. " userTerminal=" .. tostring(userTerminal == true)
					.. " userHasFinalResult=" .. tostring(userHasFinalResult == true)
					.. " roundKey=" .. tostring(roundKey)
					.. " shown=" .. tostring(alreadyShown)
					.. " returned=" .. tostring(alreadyReturned))
			end
		end
		online_flow_trace("preferred=nil reason=results_non_gameplay_screen screen=" .. tostring(screenName)
			.. " playState=" .. tostring(playState))
		return nil
	end

	if phase == "lobby" or phase == "lobby_ready" or phase == "config" then
		if self:IsOnlineEvaluationScreen(screenName) then
			if (phase == "lobby_ready" or phase == "config")
				and self.currentRoom
				and self.currentRoom.selected_song
				and self:CurrentUserConfirmedSelectedSong(self.currentRoom)
				and not self:IsCurrentUserReadyInRoom(self.currentRoom, "config_ready") then
				online_flow_trace("preferred=options reason=new_song_while_evaluation playState=" .. tostring(playState)
					.. " phase=" .. tostring(phase))
				return "options"
			end
			online_flow_trace("preferred=nil reason=keep_evaluation_after_round_until_player_leaves playState=" .. tostring(playState)
				.. " phase=" .. tostring(phase))
			return nil
		end
		if self:IsOnlineGameplayScreen(screenName) then
			online_flow_trace("preferred=lobby reason=non_playing_phase_in_gameplay playState=" .. tostring(playState))
			return "lobby"
		end
		if phase == "config" and self.currentRoom and self.currentRoom.selected_song and self:CurrentUserConfirmedSelectedSong(self.currentRoom) then
			if self:IsCurrentUserReadyInRoom(self.currentRoom, "config_ready") then
				online_flow_trace("preferred=nil reason=config_phase_current_user_already_ready screen=" .. tostring(screenName)
					.. " phase=" .. tostring(phase)
					.. " playState=" .. tostring(playState))
				return nil
			end
			if screenName == "ScreenOnlineLobbies" and self:HasPresentedOptionsForCurrentSelection(self.currentRoom) then
				online_flow_trace("preferred=nil reason=config_phase_options_already_presented"
					.. " screen=" .. tostring(screenName)
					.. " phase=" .. tostring(phase)
					.. " playState=" .. tostring(playState)
					.. " key=" .. tostring(self:CurrentOptionsSelectionKey(self.currentRoom))
					.. " age=" .. tostring(GetTimeSinceStart() - (tonumber(self.onlineOptionsPresentedAt) or 0)))
				return nil
			end
			online_flow_trace("preferred=options reason=config_phase_current_user_has_song screen=" .. tostring(screenName)
				.. " phase=" .. tostring(phase)
				.. " playState=" .. tostring(playState))
			return "options"
		end
		local okReason = phase == "config" and "config_phase_waiting_in_lobby_until_song_confirmed"
			or phase == "lobby_ready" and "lobby_ready_phase_screen_ok"
			or "lobby_phase_screen_ok"
		online_flow_trace("preferred=nil reason=" .. okReason .. " screen=" .. tostring(screenName)
			.. " phase=" .. tostring(phase)
			.. " playState=" .. tostring(playState))
		return nil
	end

	online_flow_trace("preferred=nil reason=unhandled_phase screen=" .. tostring(screenName)
		.. " phase=" .. tostring(phase)
		.. " playState=" .. tostring(playState))
	return nil
end

function ITGOnline:ApplyPreferredRoomScreen(topScreen, preferred)
	self.navigationDecisionSequence = (tonumber(self.navigationDecisionSequence) or 0) + 1
	local decisionId = self.navigationDecisionSequence
	if not topScreen or not preferred then
		online_flow_trace("navigate_skipped decisionId=" .. tostring(decisionId)
			.. " reason=" .. (not topScreen and "no_top_screen" or "no_preferred")
			.. " preferred=" .. tostring(preferred or "nil"))
		return false
	end

	local target = nil
	if preferred == "lobby" then
		target = "ScreenOnlineLobbies"
	elseif preferred == "gameplay" then
		local style = GAMESTATE:GetCurrentStyle() and GAMESTATE:GetCurrentStyle():GetName() or ""
		target = style == "routine" and "ScreenGameplayShared" or "ScreenGameplay"
	elseif preferred == "evaluation" then
		target = GAMESTATE:IsCourseMode() and "ScreenEvaluationNonstop" or "ScreenEvaluationStage"
	elseif preferred == "options" then
		target = "ScreenPlayerOptions"
	end

	if not target or topScreen:GetName() == target then
		online_flow_trace("navigate_skipped decisionId=" .. tostring(decisionId)
			.. " reason=" .. (not target and "no_target" or "already_on_target")
			.. " preferred=" .. tostring(preferred)
			.. " target=" .. tostring(target or "nil")
			.. " from=" .. tostring(topScreen:GetName()))
		return false
	end

	local roomPhase = self:NormalizeRoomPhase(self.currentRoom and self.currentRoom.phase)
	local roundKey = self.CanonicalGameplayRoundKey and self:CanonicalGameplayRoundKey("navigation") or (self.PlayStateKey and self:PlayStateKey() or "")
	local navigationKey = table.concat({
		tostring(self.currentRoomId or ""),
		tostring(roomPhase or ""),
		tostring(roundKey or ""),
		tostring(topScreen:GetName() or ""),
		tostring(target or ""),
	}, "|")
	local now = GetTimeSinceStart()
	local summary = self.PlayStateSummary and self:PlayStateSummary(self.currentRoom) or nil
	online_flow_trace("navigate_decision_begin decisionId=" .. tostring(decisionId)
		.. " preferred=" .. tostring(preferred)
		.. " target=" .. tostring(target)
		.. " from=" .. tostring(topScreen:GetName())
		.. " room=" .. tostring(self.currentRoomId or "nil")
		.. " phase=" .. tostring(roomPhase)
		.. " roundKey=" .. tostring(roundKey or "")
		.. " generation=" .. tostring(self.screenGeneration or "nil")
		.. " inFlightKey=" .. tostring(self.onlineNavigationInFlightKey or "")
		.. " optionsPresentedKey=" .. tostring(self.onlineOptionsPresentedSelectionKey or "")
		.. " finalResultsReady=" .. tostring(summary and summary.finalResultsReady == true)
		.. " summaryPlayers=" .. tostring(summary and summary.players or "nil")
		.. " summaryFinalResults=" .. tostring(summary and summary.finalResults or "nil"))
	if tostring(self.onlineNavigationInFlightKey or "") == navigationKey
		and (now - (tonumber(self.onlineNavigationInFlightAt) or 0)) < 1.25 then
		online_flow_trace("navigate_skipped decisionId=" .. tostring(decisionId)
			.. " reason=navigation_in_flight"
			.. " preferred=" .. tostring(preferred)
			.. " target=" .. tostring(target)
			.. " from=" .. tostring(topScreen:GetName())
			.. " room=" .. tostring(self.currentRoomId or "nil")
			.. " phase=" .. tostring(roomPhase)
			.. " roundKey=" .. tostring(roundKey or ""))
		return true
	end
	self.onlineNavigationInFlightKey = navigationKey
	self.onlineNavigationInFlightAt = now

		online_flow_trace("navigate decisionId=" .. tostring(decisionId) .. " target=" .. tostring(target) .. " preferred=" .. tostring(preferred) .. " from=" .. tostring(topScreen:GetName()))
		if preferred == "options" then
			self:MarkOptionsPresentedForCurrentSelection("apply_preferred_room_screen", self.currentRoom)
			if self.ClearFinalLeaderboardCache then
				self:ClearFinalLeaderboardCache("new_song_options_navigation", self.currentRoomId)
			end
			if self:IsOnlineEvaluationScreen(topScreen:GetName()) then
				self.onlineEvaluationExitRequested = true
				self.onlineEvaluationExitRequestedAt = GetTimeSinceStart()
				online_flow_trace("evaluation_forced_exit_to_options reason=preferred_screen_options"
					.. " from=" .. tostring(topScreen:GetName())
					.. " phase=" .. tostring(roomPhase)
					.. " room=" .. tostring(self.currentRoomId or "nil"))
			end
		end
		topScreen:SetNextScreenName(target)
	if preferred == "evaluation" and self:IsOnlineGameplayScreen(topScreen:GetName()) then
		-- Let ScreenGameplay perform its normal end-of-song cleanup instead of
		-- jumping screens directly.  Direct SM_GoToNextScreen can leave gameplay
		-- state half-alive when every online player has failed.
		local roundKey, roundKeySource = self:CanonicalGameplayRoundKey("navigate_evaluation")
		local roomPhase = self:NormalizeRoomPhase(self.currentRoom and self.currentRoom.phase)
		local summary = self.PlayStateSummary and self:PlayStateSummary(self.currentRoom) or nil
		local now = GetTimeSinceStart()
		local previousAt = tonumber(self.onlineGameplayEvaluationNavigationAt) or 0
		if roundKey ~= ""
			and self.onlineGameplayEvaluationNavigationKey == roundKey
			and (now - previousAt) < 1.5 then
			online_flow_trace_throttled("evaluation_navigation_skipped", 1.0,
				"navigate_via_gameplay_message_skipped reason=already_posted target=" .. tostring(target)
				.. " roundKey=" .. tostring(roundKey)
				.. " roundKeySource=" .. tostring(roundKeySource))
			return true
		end
		if roundKey ~= "" then
			self.onlineGameplayEvaluationNavigationKey = roundKey
			self.onlineGameplayEvaluationNavigationAt = now
		end
		online_flow_trace("navigate_via_gameplay_message message=SM_LeaveGameplay target=" .. tostring(target)
			.. " roundKey=" .. tostring(roundKey)
			.. " roundKeySource=" .. tostring(roundKeySource)
			.. " roomPhase=" .. tostring(roomPhase)
			.. " finalResultsReady=" .. tostring(summary and summary.finalResultsReady == true)
			.. " finalResults=" .. tostring(summary and summary.finalResults or "nil"))
		if roomPhase == "results" and summary and summary.finalResultsReady == true then
			online_flow_trace("navigate_force_evaluation reason=results_ready target=" .. tostring(target)
				.. " roundKey=" .. tostring(roundKey))
			topScreen:StartTransitioningScreen("SM_GoToNextScreen")
		elseif topScreen.PostScreenMessage then
			topScreen:PostScreenMessage("SM_LeaveGameplay", 0)
		else
			topScreen:StartTransitioningScreen("SM_GoToNextScreen")
		end
		return true
	end
	if preferred == "options" and self:IsOnlineEvaluationScreen(topScreen:GetName()) then
		online_flow_trace("evaluation_forced_exit_to_options action=start_transition"
			.. " from=" .. tostring(topScreen:GetName())
			.. " target=" .. tostring(target)
			.. " phase=" .. tostring(roomPhase)
			.. " room=" .. tostring(self.currentRoomId or "nil"))
	end
	topScreen:StartTransitioningScreen("SM_GoToNextScreen")
	return true
end

function ITGOnline:EnforceRoomPhaseScreen(screenName)
	if not self.currentRoomId or not self.currentRoom then
		online_flow_trace("enforce_screen_skipped reason=no_current_room requestedScreen=" .. tostring(screenName or "nil"))
		return false
	end
	local topScreen = SCREENMAN:GetTopScreen()
	if not topScreen then
		online_flow_trace("enforce_screen_skipped reason=no_top_screen requestedScreen=" .. tostring(screenName or "nil")
			.. " room=" .. tostring(self.currentRoomId or "nil")
			.. " phase=" .. tostring(self.currentRoom and self.currentRoom.phase or "nil"))
		return false
	end

	local preferred = self:PreferredScreenForRoomPhase(screenName or topScreen:GetName())
	online_flow_trace("enforce_screen_decision requestedScreen=" .. tostring(screenName or "nil")
		.. " topScreen=" .. tostring(topScreen:GetName())
		.. " preferred=" .. tostring(preferred or "nil")
		.. " room=" .. tostring(self.currentRoomId or "nil")
		.. " phase=" .. tostring(self.currentRoom and self.currentRoom.phase or "nil"))
	if self.TraceOnlineState then
		self:TraceOnlineState("enforce_screen_decision", {
			source = "screen_enforcer",
			requestedScreen = screenName or "nil",
			topScreen = topScreen:GetName(),
			preferred = preferred or "nil",
			roomId = self.currentRoomId or "nil",
			roomPhase = self.currentRoom and self.currentRoom.phase or "nil",
			playState = self.CurrentUserPlayState and self:CurrentUserPlayState(self.currentRoom) or "nil",
			summary = self.PlayStateSummary and self:PlayStateSummary() or nil,
		})
	end
	return self:ApplyPreferredRoomScreen(topScreen, preferred)
end

function ITGOnline:NoteScreenChanged(screenName)
	screenName = tostring(screenName or "NoScreen")
	if self.currentScreenName ~= screenName then
		local previous = self.currentScreenName
		local topScreen = SCREENMAN and SCREENMAN:GetTopScreen() or nil
		local topScreenName = topScreen and topScreen.GetName and topScreen:GetName() or "nil"
		local summary = self.PlayStateSummary and self:PlayStateSummary(self.currentRoom) or nil
		local playState = self.CurrentUserPlayState and self:CurrentUserPlayState(self.currentRoom) or "nil"
		self.currentScreenName = screenName
			self.screenGeneration = (self.screenGeneration or 0) + 1
			if self:IsOnlineOptionsScreen(screenName) then
				self:MarkOptionsPresentedForCurrentSelection("screen_changed_to_options", self.currentRoom)
			end
			self.onlineNavigationInFlightKey = ""
		self.onlineNavigationInFlightAt = 0
		online_flow_trace("screen_changed previous=" .. tostring(previous)
			.. " next=" .. tostring(screenName)
			.. " topScreen=" .. tostring(topScreenName)
			.. " screenMatchesTop=" .. tostring(tostring(screenName or "") == tostring(topScreenName or ""))
			.. " generation=" .. tostring(self.screenGeneration)
			.. " room=" .. tostring(self.currentRoomId or "nil")
			.. " phase=" .. tostring(self.currentRoom and self.currentRoom.phase or "nil")
			.. " playState=" .. tostring(playState)
			.. " currentRoundKey=" .. tostring(self.currentRoomRoundKey or "")
			.. " activeRoundKey=" .. tostring(self.activeGameplayRoundKey or "")
			.. " optionsPresentedKey=" .. tostring(self.onlineOptionsPresentedSelectionKey or "")
			.. " evaluationShownKey=" .. tostring(self.onlineGameplayEvaluationShownKey or "")
			.. " evaluationReturnedKey=" .. tostring(self.onlineGameplayEvaluationReturnedKey or "")
			.. " finalResultsReady=" .. tostring(summary and summary.finalResultsReady == true)
			.. " summaryPlayers=" .. tostring(summary and summary.players or "nil")
			.. " summaryTerminal=" .. tostring(summary and summary.terminal or "nil")
			.. " summaryFinalResults=" .. tostring(summary and summary.finalResults or "nil")
			.. " pendingJoinRoomId=" .. tostring(self.pendingJoinRoomId or "nil")
			.. " syncInFlight=" .. tostring(self.syncInFlight == true)
			.. " lobbyRefreshInFlight=" .. tostring(self.lobbyRefreshInFlight == true)
			.. " lobbyRefreshQueued=" .. tostring(self.lobbyRefreshQueued == true))
		SL.Global.Online = SL.Global.Online or {}
		SL.Global.Online.GameplayLayoutActive = self:IsOnlineGameplayScreen(screenName)
			and self.currentRoomId ~= nil
			and self.currentRoom ~= nil
		self:CancelScreenBoundRequests()
		if self:IsOnlineGameplayScreen(previous) and not self:IsOnlineGameplayScreen(screenName) then
			self:StopLiveScoreFlush("screen_changed:" .. tostring(previous) .. "->" .. tostring(screenName))
		end
		if previous == "ScreenReloadSongsOnline" and screenName == "ScreenOnlineLobbies" then
			online_flow_trace("reload_songs_online_returned_to_lobby")
			self:ClearFileHashCache()
			MESSAGEMAN:Broadcast("OnlineSongReloadCompleted")
			if self.PackSync and self.PackSync.ValidatePendingPostReload then
				self.PackSync:ValidatePendingPostReload()
			end
		elseif screenName == "ScreenReloadSongsOnline" then
			online_flow_trace("reload_songs_online_entered previous=" .. tostring(previous))
		end
		self:HandleOnlineGameplayScreenTransition(previous, screenName)
		self:EnforceRoomPhaseScreen(screenName)
	elseif self.debugOnlineTrace == true then
		online_flow_trace_throttled("screen_still_" .. tostring(screenName), 2.0,
			"screen_unchanged screen=" .. tostring(screenName)
			.. " generation=" .. tostring(self.screenGeneration or "nil")
			.. " room=" .. tostring(self.currentRoomId or "nil")
			.. " phase=" .. tostring(self.currentRoom and self.currentRoom.phase or "nil"))
	end
end

function ITGOnline:EnforceCurrentRoomScreenAfterStateUpdate(source)
	local topScreen = SCREENMAN and SCREENMAN.GetTopScreen and SCREENMAN:GetTopScreen() or nil
	if not topScreen then
		online_flow_trace("enforce_after_state_skipped reason=no_top_screen source=" .. tostring(source or "unknown"))
		return false
	end

	local screenName = topScreen:GetName()
	if self.IsOnlineOptionsScreen and self:IsOnlineOptionsScreen(screenName) then
		return false
	end

	online_flow_trace("enforce_after_state source=" .. tostring(source or "unknown")
		.. " screen=" .. tostring(screenName)
		.. " room=" .. tostring(self.currentRoomId or "nil")
		.. " phase=" .. tostring(self.currentRoom and self.currentRoom.phase or "nil"))
	return self:EnforceRoomPhaseScreen(screenName)
end

function ITGOnline:ForceGameplayEvaluationIfResultsReady(source)
	if not self.currentRoomId or not self.currentRoom then
		online_flow_trace("force_evaluation_skipped reason=no_current_room source=" .. tostring(source or "unknown"))
		return false
	end

	local topScreen = SCREENMAN and SCREENMAN.GetTopScreen and SCREENMAN:GetTopScreen() or nil
	local screenName = topScreen and topScreen.GetName and topScreen:GetName() or "nil"
	if not (topScreen and self:IsOnlineGameplayScreen(screenName)) then
		return false
	end

	local phase = self:NormalizeRoomPhase(self.currentRoom.phase)
	if phase ~= "results" then
		return false
	end

	local summary = self.PlayStateSummary and self:PlayStateSummary(self.currentRoom) or nil
	if not (summary and summary.players > 0 and summary.finalResultsReady == true) then
		online_flow_trace_throttled("force_evaluation_wait_results", 1.0,
			"force_evaluation_skipped reason=final_results_not_ready"
			.. " source=" .. tostring(source or "unknown")
			.. " room=" .. tostring(self.currentRoomId or "nil")
			.. " phase=" .. tostring(phase)
			.. " players=" .. tostring(summary and summary.players or "nil")
			.. " terminal=" .. tostring(summary and summary.terminal or "nil")
			.. " finalResults=" .. tostring(summary and summary.finalResults or "nil")
			.. " finalResultsReady=" .. tostring(summary and summary.finalResultsReady == true))
		return false
	end

	local roundKey, roundKeySource = self:CanonicalGameplayRoundKey("force_results_ready_evaluation")
	local forceKey = table.concat({
		tostring(self.currentRoomId or ""),
		tostring(roundKey or ""),
		tostring(screenName or ""),
		"results_ready",
	}, "|")
	local now = GetTimeSinceStart()
	if tostring(self.onlineGameplayEvaluationForceKey or "") == forceKey
		and (now - (tonumber(self.onlineGameplayEvaluationForceAt) or 0)) < 1.5 then
		online_flow_trace_throttled("force_evaluation_duplicate", 1.0,
			"force_evaluation_skipped reason=already_forced"
			.. " source=" .. tostring(source or "unknown")
			.. " key=" .. tostring(forceKey)
			.. " age=" .. tostring(now - (tonumber(self.onlineGameplayEvaluationForceAt) or 0)))
		return true
	end

	self.onlineGameplayEvaluationForceKey = forceKey
	self.onlineGameplayEvaluationForceAt = now
	online_flow_trace("force_evaluation_results_ready"
		.. " source=" .. tostring(source or "unknown")
		.. " room=" .. tostring(self.currentRoomId or "nil")
		.. " screen=" .. tostring(screenName)
		.. " roundKey=" .. tostring(roundKey or "")
		.. " roundKeySource=" .. tostring(roundKeySource or "")
		.. " players=" .. tostring(summary.players)
		.. " terminal=" .. tostring(summary.terminal)
		.. " finalResults=" .. tostring(summary.finalResults))

	if topScreen.PostScreenMessage then
		topScreen:PostScreenMessage("SM_LeaveGameplay", 0)
	else
		topScreen:StartTransitioningScreen("SM_GoToNextScreen")
	end
	return true
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
	local previousWasEvaluation = previousScreenName == "ScreenEvaluationStage"
		or previousScreenName == "ScreenEvaluationNonstop"
		or previousScreenName == "ScreenEvaluationSummary"
	local roomPhase = self:NormalizeRoomPhase(self.currentRoom.phase)
	local roundKey = self:PlayStateKey()
	local validRoundKey = self:PlayStateKeyIsValid(roundKey)
	online_flow_trace("gameplay_transition previous=" .. tostring(previousScreenName)
		.. " next=" .. tostring(nextScreenName)
		.. " roomPhase=" .. tostring(roomPhase)
		.. " roundKey=" .. tostring(roundKey)
		.. " previousWasGameplay=" .. tostring(previousWasGameplay)
		.. " previousWasEvaluation=" .. tostring(previousWasEvaluation)
		.. " nextIsEvaluation=" .. tostring(nextIsEvaluation)
		.. " nextIsLobby=" .. tostring(nextIsLobby)
		.. " nextIsSelectMusic=" .. tostring(nextIsSelectMusic))

	if nextIsGameplay and roomPhase == "playing" then
		self:CaptureActiveGameplayRound("entered_gameplay")
		online_flow_trace("mark_play_entered reason=entered_gameplay")
		self:MarkPlayEntered()
	elseif nextIsGameplay and roomPhase == "starting" then
		self:CaptureActiveGameplayRound("entered_gameplay_starting")
	elseif previousWasGameplay and nextIsEvaluation and (roomPhase == "starting" or roomPhase == "playing" or roomPhase == "results") then
		-- Fallback only. The normal online path marks completion while still
		-- on ScreenGameplay so every client can wait there before results.
		self.onlineEvaluationExitRequested = false
		if validRoundKey then
			self.onlineGameplayEvaluationShownKey = roundKey
			self.onlineGameplayEvaluationReturnedKey = ""
			online_flow_trace("evaluation_seen roundKey=" .. tostring(roundKey)
				.. " reason=gameplay_to_evaluation")
		end
		self:MarkGameplayCompleteForEvaluation("screen_transition")
	elseif nextIsEvaluation and roomPhase == "results" then
		if validRoundKey then
			self.onlineGameplayEvaluationShownKey = roundKey
			self.onlineGameplayEvaluationReturnedKey = ""
			online_flow_trace("evaluation_seen roundKey=" .. tostring(roundKey)
				.. " reason=results_screen_entered")
		end
	elseif previousWasGameplay and nextIsLobby and roomPhase == "playing" then
		online_flow_trace("mark_returned_to_lobby_skipped reason=gameplay_to_lobby_before_results"
			.. " roomPhase=" .. tostring(roomPhase))
	elseif previousWasEvaluation and nextIsLobby and (roomPhase == "playing" or roomPhase == "starting") then
		online_flow_trace("mark_returned_to_lobby_skipped reason=evaluation_to_lobby_before_results"
			.. " roomPhase=" .. tostring(roomPhase))
	elseif previousWasEvaluation and nextIsLobby and roomPhase == "results" then
		-- Some flows go Gameplay -> Evaluation -> Lobby. Make sure we still
		-- notify the server immediately when the player is back in the lobby.
		if validRoundKey then
			self.onlineGameplayEvaluationShownKey = roundKey
			self.onlineGameplayEvaluationReturnedKey = roundKey
		end
		online_flow_trace("mark_returned_to_lobby reason=evaluation_to_lobby roomPhase=" .. tostring(roomPhase)
			.. " roundKey=" .. tostring(roundKey))
		self:MarkReturnedToLobby()
	elseif previousWasGameplay and nextIsSelectMusic and (roomPhase == "playing" or roomPhase == "starting") then
		online_flow_trace("mark_returned_to_lobby_skipped reason=gameplay_to_select_music_before_results"
			.. " roomPhase=" .. tostring(roomPhase))
	elseif previousWasGameplay and nextIsSelectMusic and roomPhase == "results" then
		-- If a player leaves gameplay early, force the online flow back to the room lobby.
		online_flow_trace("mark_returned_to_lobby reason=gameplay_to_select_music roomPhase=" .. tostring(roomPhase))
		self:MarkReturnedToLobby()
		local topScreen = SCREENMAN:GetTopScreen()
		if topScreen and topScreen:GetName() == nextScreenName then
			online_flow_trace("navigate target=ScreenOnlineLobbies preferred=lobby reason=gameplay_to_select_music_redirect")
			topScreen:SetNextScreenName("ScreenOnlineLobbies")
			topScreen:StartTransitioningScreen("SM_GoToNextScreen")
		end
	end
end

function ITGOnline:Login(callback)
	self.authSessionInvalidated = false
	self.authSessionInvalidatedReason = ""
	self.authRefreshFailureCount = 0
	self.authRefreshNextAttemptAt = 0
	online_flow_trace("login_begin localPlayers=" .. tostring(online_local_player_count())
		.. " hasToken=" .. tostring(tostring(self.token or "") ~= "")
		.. " sessionExpired=" .. tostring(self.sessionExpired == true))
	if online_local_player_count() > 1 then
		online_flow_trace("login_failed reason=two_local_players")
		if callback then callback(false, THEME:GetString("ScreenITGOnlineLogin", "TwoPlayerNotice")) end
		return
	end

	local config = self:Config()
	if config.email == "" or config.password == "" then
		online_flow_trace("login_failed reason=missing_credentials hasEmail=" .. tostring(config.email ~= "")
			.. " hasPassword=" .. tostring(config.password ~= ""))
		self:ClearTransientSecrets()
		if callback then callback(false, "Configure Save/ITGOnline.ini with Email and Password.") end
		return
	end

	local loginPassword = config.password
	self:Request("POST", "/auth/login", {
		email = config.email,
		password = loginPassword,
		device_name = config.deviceName,
	}, function(ok, decoded, response)
		online_flow_trace("login_response ok=" .. tostring(ok == true)
			.. " status=" .. tostring(response and response.statusCode or "nil")
			.. " hasToken=" .. tostring(decoded and decoded.access_token ~= nil)
			.. " hasUser=" .. tostring(decoded and decoded.user ~= nil)
			.. " error=" .. tostring(decoded and decoded.error_code or response and response.errorMessage or "nil"))
		if not ok or not decoded or not decoded.access_token then
			if callback then callback(false, response_message(response, decoded, "Login failed")) end
			return
		end

		self:ClearTransientSecrets()

		apply_authenticated_user_state(self, decoded.user)
		self.authSessionInvalidated = false
		self.authSessionInvalidatedReason = ""
		self.token = decoded.access_token
		self:StoreAccessToken(self.token, decoded.user)
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
	local config = self:ConnectionConfig()
	if config.email == "" then
		if callback then callback(false, nil, { errorMessage = "Email is required." }) end
		return
	end

	self:Request("POST", "/auth/email/resend", {
		email = config.email,
	}, callback)
end

function ITGOnline:ForgotPassword(callback)
	local config = self:ConnectionConfig()
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
	online_flow_trace("relogin_begin callbacks=" .. tostring(#self.authRefreshCallbacks)
		.. " inFlight=" .. tostring(self.authRefreshInFlight == true)
		.. " failureCount=" .. tostring(self.authRefreshFailureCount or 0)
		.. " nextAttemptAt=" .. tostring(self.authRefreshNextAttemptAt or 0)
		.. " hasToken=" .. tostring(tostring(self.token or "") ~= ""))

	if self.authRefreshInFlight then
		online_flow_trace("relogin_join_inflight")
		return
	end
	local nowTs = GetTimeSinceStart()
	if nowTs < (self.authRefreshNextAttemptAt or 0) then
		online_trace("Auth refresh skipped due to cooldown.")
		online_flow_trace("relogin_skipped reason=cooldown remaining=" .. tostring((self.authRefreshNextAttemptAt or 0) - nowTs))
		local callbacks = self.authRefreshCallbacks or {}
		self.authRefreshCallbacks = {}
		for cb in ivalues(callbacks) do
			if cb then cb(false) end
		end
		return
	end
	if (self.authRefreshFailureCount or 0) >= (self.maxAuthRefreshFailures or 3) then
		online_flow_trace("relogin_skipped reason=max_failures failureCount=" .. tostring(self.authRefreshFailureCount or 0))
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
		online_flow_trace("relogin_failed reason=no_token callbacks=" .. tostring(self.authRefreshCallbacks and #self.authRefreshCallbacks or 0))
		local callbacks = self.authRefreshCallbacks or {}
		self.authRefreshCallbacks = {}
		for cb in ivalues(callbacks) do
			if cb then cb(false) end
		end
		return
	end

	self:Request("POST", "/auth/refresh", {}, function(ok, decoded, response)
		local callbacks = self.authRefreshCallbacks or {}
		self.authRefreshCallbacks = {}

		if ok and decoded and decoded.access_token then
			self.authRefreshInFlight = false
			self.token = decoded.access_token
			self.user = decoded.user
			self.sessionExpired = false
			self.authRefreshFailureCount = 0
			self.authRefreshNextAttemptAt = 0
			self:StoreAccessToken(self.token, decoded.user)
			online_flow_trace("relogin_refresh_success callbacks=" .. tostring(#callbacks)
				.. " hasUser=" .. tostring(decoded.user ~= nil))
			for cb in ivalues(callbacks) do
				if cb then cb(true) end
			end
			return
		end

		if response and response.statusCode == 401 and self:Configured() then
			online_trace("Auth refresh failed with 401; falling back to password login.")
			online_flow_trace("relogin_refresh_401_fallback_to_login callbacks=" .. tostring(#callbacks))
			self.token = nil
			self.user = nil
			self:Login(function(loginOk)
				self.authRefreshInFlight = false
				if loginOk then
					self.sessionExpired = false
					self.authRefreshFailureCount = 0
					self.authRefreshNextAttemptAt = 0
					online_flow_trace("relogin_password_fallback_success")
				else
					self.authRefreshFailureCount = (self.authRefreshFailureCount or 0) + 1
					local failCount = math.max(1, self.authRefreshFailureCount or 1)
					local backoffSeconds = math.min(
						tonumber(self.authRefreshMaxBackoffSeconds) or 30,
						math.pow(2, math.max(0, failCount - 1))
					)
					self.authRefreshNextAttemptAt = GetTimeSinceStart() + backoffSeconds
					online_flow_trace("relogin_password_fallback_failed failureCount=" .. tostring(self.authRefreshFailureCount)
						.. " backoff=" .. tostring(backoffSeconds))
				end
				for cb in ivalues(callbacks) do
					if cb then cb(loginOk == true) end
				end
			end)
			return
		end

		self.authRefreshInFlight = false
		online_trace("Auth refresh failed: " .. response_message(response, decoded, "unknown"))
		online_flow_trace("relogin_refresh_failed status=" .. tostring(response and response.statusCode or "nil")
			.. " error=" .. tostring(decoded and decoded.error_code or response and response.errorMessage or "nil"))
		self.token = nil
		self.user = nil
		self.authRefreshFailureCount = (self.authRefreshFailureCount or 0) + 1
		local failCount = math.max(1, self.authRefreshFailureCount or 1)
		local backoffSeconds = math.min(
			tonumber(self.authRefreshMaxBackoffSeconds) or 30,
			math.pow(2, math.max(0, failCount - 1))
		)
		self.authRefreshNextAttemptAt = GetTimeSinceStart() + backoffSeconds

		for cb in ivalues(callbacks) do
			if cb then cb(false) end
		end
	end)
end

function ITGOnline:RememberRealtimeConnectCallbacks(callbacks)
	if not callbacks then return end
	self.pendingRealtimeConnectCallbacks = self.pendingRealtimeConnectCallbacks or {}
	self.pendingRealtimeConnectCallbacks[#self.pendingRealtimeConnectCallbacks + 1] = callbacks
	online_flow_trace("realtime_callbacks_remembered count=" .. tostring(#self.pendingRealtimeConnectCallbacks)
		.. " connecting=" .. tostring(self.realtimeConnecting == true)
		.. " connected=" .. tostring(self.realtimeConnected == true)
		.. " generation=" .. tostring(self.realtimeGeneration or "nil"))
end

function ITGOnline:FlushRealtimeConnectCallbacks(method, value)
	local callbacks = self.pendingRealtimeConnectCallbacks or {}
	self.pendingRealtimeConnectCallbacks = {}
	online_flow_trace("realtime_callbacks_flush method=" .. tostring(method)
		.. " count=" .. tostring(#callbacks)
		.. " value=" .. tostring(value or "")
		.. " connected=" .. tostring(self.realtimeConnected == true)
		.. " connecting=" .. tostring(self.realtimeConnecting == true))
	for cb in ivalues(callbacks) do
		if cb and cb[method] then
			cb[method](value)
		end
	end
end

function ITGOnline:ConnectWebSocket(callbacks)
	if self.disconnecting and tostring(self.token or "") ~= "" then
		online_flow_trace("auth_session_resumed source=connect_websocket previousDisconnecting=true"
			.. " hasUser=" .. tostring(self.user ~= nil)
			.. " socket=" .. tostring(self.socket ~= nil)
			.. " connected=" .. tostring(self.realtimeConnected == true)
			.. " screen=" .. tostring(self.currentScreenName or "nil"))
		self.disconnecting = false
	end
	if self.socket and self.realtimeConnected and not self.disconnecting then
		online_flow_trace("connect_websocket_reused reason=already_connected"
			.. " generation=" .. tostring(self.realtimeGeneration or "nil")
			.. " room=" .. tostring(self.currentRoomId or "nil")
			.. " screen=" .. tostring(self.currentScreenName or "nil"))
		if callbacks and callbacks.open then callbacks.open() end
		return
	end
	if self.realtimeConnecting then
		online_flow_trace("connect_websocket_join_inflight generation=" .. tostring(self.realtimeGeneration or "nil")
			.. " pendingCallbacks=" .. tostring(self.pendingRealtimeConnectCallbacks and #self.pendingRealtimeConnectCallbacks or 0))
		self:RememberRealtimeConnectCallbacks(callbacks)
		return
	end

	self.realtimeConnecting = true
	self:RememberRealtimeConnectCallbacks(callbacks)
	online_flow_trace("connect_websocket_ticket_request generation=" .. tostring(self.realtimeGeneration or "nil")
		.. " hasToken=" .. tostring(tostring(self.token or "") ~= "")
		.. " room=" .. tostring(self.currentRoomId or "nil")
		.. " screen=" .. tostring(self.currentScreenName or "nil"))
	self:TraceOnlineState("realtime_ticket_request", {
		source = "connect_websocket",
		generation = self.realtimeGeneration or "nil",
		hasToken = tostring(self.token or "") ~= "",
		realtimeConnecting = self.realtimeConnecting == true,
		realtimeConnected = self.realtimeConnected == true,
	})
	self:Request("POST", "/websocket/tickets", {}, function(ok, decoded, response)
		online_flow_trace("connect_websocket_ticket_response ok=" .. tostring(ok == true)
			.. " status=" .. tostring(response and response.statusCode or "nil")
			.. " hasTicket=" .. tostring(decoded and decoded.ticket ~= nil)
			.. " connecting=" .. tostring(self.realtimeConnecting == true))
		self:TraceOnlineState("realtime_ticket_response", {
			source = "connect_websocket",
			ok = ok == true,
			status = response and response.statusCode or "nil",
			hasTicket = decoded and decoded.ticket ~= nil,
			realtimeConnecting = self.realtimeConnecting == true,
		})
		if not ok or not decoded or not decoded.ticket then
			self.realtimeConnecting = false
			self.realtimeConnected = false
			self:FlushRealtimeConnectCallbacks(
				"error",
				response_message(response, decoded, "WebSocket ticket request failed"))
			return
		end

		local config = self:ConnectionConfig()
		if self.socket then
			online_flow_trace("connect_websocket_closing_previous_socket")
			self.realtimeGeneration = (tonumber(self.realtimeGeneration) or 0) + 1
			pcall(function() self.socket:Close() end)
			self.socket = nil
		end
		self.activeRealtimeCallbacks = callbacks
		self.realtimeGeneration = (tonumber(self.realtimeGeneration) or 0) + 1
		local generation = self.realtimeGeneration
		online_flow_trace("connect_websocket_opening generation=" .. tostring(generation)
			.. " url=" .. tostring(config.webSocketUrl)
			.. " origin=" .. tostring(origin_from_base_url(config.apiBaseUrl))
			.. " room=" .. tostring(self.currentRoomId or "nil")
			.. " screen=" .. tostring(self.currentScreenName or "nil"))
		self:TraceOnlineState("realtime_socket_opening", {
			source = "connect_websocket",
			generation = generation,
			url = config.webSocketUrl,
			origin = origin_from_base_url(config.apiBaseUrl),
		})
		local socket
		socket = NETWORK:WebSocket{
			url = config.webSocketUrl,
			headers = {
				["Origin"] = origin_from_base_url(config.apiBaseUrl),
				["Cookie"] = "itgmania_ws_ticket=" .. tostring(decoded.ticket),
				["Sec-WebSocket-Protocol"] = "itgmania-ticket",
			},
			pingInterval = 20,
				automaticReconnect = false,
				onMessage = function(msg)
					if generation ~= self.realtimeGeneration or self.socket ~= socket then
						online_flow_trace("realtime_message_ignored reason=stale_socket generation="
							.. tostring(generation)
							.. " active=" .. tostring(self.realtimeGeneration or "nil")
							.. " type=" .. tostring(ToEnumShortString(msg.type))
							.. " room=" .. tostring(self.currentRoomId or "nil"))
						return
					end
					local msgType = ToEnumShortString(msg.type)
					if msgType == "Open" then
						self.lastRealtimeMessageAt = GetTimeSinceStart()
						self.realtimeConnecting = false
						self.realtimeConnected = true
						online_flow_trace("realtime_socket_open generation=" .. tostring(generation)
							.. " room=" .. tostring(self.currentRoomId or "nil")
							.. " screen=" .. tostring(self.currentScreenName or "nil")
							.. " pendingCallbacks=" .. tostring(self.pendingRealtimeConnectCallbacks and #self.pendingRealtimeConnectCallbacks or 0))
						self:TraceOnlineState("realtime_socket_open", {
							source = "websocket",
							generation = generation,
							pendingCallbacks = self.pendingRealtimeConnectCallbacks and #self.pendingRealtimeConnectCallbacks or 0,
						})
						self:FlushRealtimeConnectCallbacks("open")
					elseif msgType == "Message" then
						self.lastRealtimeMessageAt = GetTimeSinceStart()
						local payload = safe_decode(msg.data)
						online_flow_trace("realtime_message_received id=" .. tostring(payload and payload.id or "nil")
							.. " name=" .. tostring(payload and (payload.event or payload.name) or "nil")
							.. " bytes=" .. tostring(msg.data and string.len(msg.data) or 0))
						self:TraceOnlineState("realtime_message_received", {
							source = "websocket",
							eventId = payload and payload.id or "nil",
							eventName = payload and (payload.event or payload.name) or "nil",
							bytes = msg.data and string.len(msg.data) or 0,
							generation = generation,
						})
						local handled, err = pcall(function()
							online_flow_trace("realtime_handle_begin id=" .. tostring(payload and payload.id or "nil")
								.. " name=" .. tostring(payload and (payload.event or payload.name) or "nil"))
							self:HandleRealtimeEvent(payload)
						end)
						online_flow_trace("realtime_handle_end id=" .. tostring(payload and payload.id or "nil")
							.. " name=" .. tostring(payload and (payload.event or payload.name) or "nil")
							.. " ok=" .. tostring(handled == true))
						self:TraceOnlineState("realtime_handle_end", {
							source = "websocket",
							eventId = payload and payload.id or "nil",
							eventName = payload and (payload.event or payload.name) or "nil",
							ok = handled == true,
						})
						if handled and payload and payload.id and not payload._itgOnlineAckHandled then
							online_flow_trace("realtime_ack_begin id=" .. tostring(payload.id)
								.. " name=" .. tostring(payload.event or payload.name or "nil"))
							self:SendRealtimeAck(payload.id)
							online_flow_trace("realtime_ack_end id=" .. tostring(payload.id)
								.. " name=" .. tostring(payload.event or payload.name or "nil"))
						elseif not handled then
							online_trace("Realtime event handling failed before ack: " .. tostring(err))
						end
						if handled and callbacks and callbacks.message then
							online_flow_trace("realtime_callback_message_begin id=" .. tostring(payload and payload.id or "nil")
								.. " name=" .. tostring(payload and (payload.event or payload.name) or "nil"))
							callbacks.message(payload)
							online_flow_trace("realtime_callback_message_end id=" .. tostring(payload and payload.id or "nil")
								.. " name=" .. tostring(payload and (payload.event or payload.name) or "nil"))
						end
					elseif msgType == "Close" then
						self.realtimeConnecting = false
						self.realtimeConnected = false
						self.socket = nil
						online_flow_trace("realtime_socket_close reason=" .. tostring(msg.reason or "")
							.. " generation=" .. tostring(generation)
							.. " room=" .. tostring(self.currentRoomId or "nil")
							.. " screen=" .. tostring(self.currentScreenName or "nil")
							.. " pendingCallbacks=" .. tostring(self.pendingRealtimeConnectCallbacks and #self.pendingRealtimeConnectCallbacks or 0))
						self:TraceOnlineState("realtime_socket_close", {
							source = "websocket",
							generation = generation,
							reason = msg.reason or "",
							pendingCallbacks = self.pendingRealtimeConnectCallbacks and #self.pendingRealtimeConnectCallbacks or 0,
						})
						if self.pendingRealtimeConnectCallbacks and #self.pendingRealtimeConnectCallbacks > 0 then
							self:FlushRealtimeConnectCallbacks("close", msg.reason)
						elseif self.activeRealtimeCallbacks and self.activeRealtimeCallbacks.close then
							self.activeRealtimeCallbacks.close(msg.reason)
						end
						self.activeRealtimeCallbacks = nil
						self:ScheduleRealtimeReconnect("socket_close:" .. tostring(msg.reason or "unknown"))
						if self.currentRoomId and self.ReconcileCurrentRoomAfterRealtimeGap then
							self:ReconcileCurrentRoomAfterRealtimeGap("socket_close", 0)
						end
					elseif msgType == "Error" then
						self.realtimeConnecting = false
						self.realtimeConnected = false
						self.socket = nil
						online_flow_trace("realtime_socket_error reason=" .. tostring(msg.reason or "")
							.. " generation=" .. tostring(generation)
							.. " room=" .. tostring(self.currentRoomId or "nil")
							.. " screen=" .. tostring(self.currentScreenName or "nil")
							.. " pendingCallbacks=" .. tostring(self.pendingRealtimeConnectCallbacks and #self.pendingRealtimeConnectCallbacks or 0))
						self:TraceOnlineState("realtime_socket_error", {
							source = "websocket",
							generation = generation,
							reason = msg.reason or "",
							pendingCallbacks = self.pendingRealtimeConnectCallbacks and #self.pendingRealtimeConnectCallbacks or 0,
						})
						if self.pendingRealtimeConnectCallbacks and #self.pendingRealtimeConnectCallbacks > 0 then
							self:FlushRealtimeConnectCallbacks("error", msg.reason or "WebSocket error")
						elseif self.activeRealtimeCallbacks and self.activeRealtimeCallbacks.error then
							self.activeRealtimeCallbacks.error(msg.reason or "WebSocket error")
						end
						self:ScheduleRealtimeReconnect("socket_error:" .. tostring(msg.reason or "unknown"))
						if self.currentRoomId and self.ReconcileCurrentRoomAfterRealtimeGap then
							self:ReconcileCurrentRoomAfterRealtimeGap("socket_error", 0)
						end
					end
				end,
			}
		self.socket = socket
	end)
end

function ITGOnline:SendRealtimeAck(eventId)
	if not self.socket or not eventId then
		online_flow_trace("realtime_ack_skipped reason=" .. (not self.socket and "no_socket" or "no_event_id")
			.. " eventId=" .. tostring(eventId or "nil")
			.. " connected=" .. tostring(self.realtimeConnected == true))
		return
	end
	local ok, encoded = pcall(JsonEncode, {
		action = "ack",
		event_id = tonumber(eventId),
	})
	if ok and encoded then
		local sent = self.socket:Send(encoded)
		if not sent then
			online_trace("Realtime ack send failed for event " .. tostring(eventId))
		end
		online_flow_trace("realtime_ack_send eventId=" .. tostring(eventId)
			.. " encoded=" .. tostring(ok == true)
			.. " sent=" .. tostring(sent == true)
			.. " generation=" .. tostring(self.realtimeGeneration or "nil"))
	else
		online_flow_trace("realtime_ack_encode_failed eventId=" .. tostring(eventId)
			.. " ok=" .. tostring(ok == true))
	end
end

function ITGOnline:Connect(callbacks)
	self.disconnecting = false
	online_flow_trace("connect_begin hasToken=" .. tostring(tostring(self.token or "") ~= "")
		.. " hasUser=" .. tostring(self.user ~= nil)
		.. " sessionExpired=" .. tostring(self.sessionExpired == true)
		.. " authInvalidated=" .. tostring(self.authSessionInvalidated == true)
		.. " authInvalidatedReason=" .. tostring(self.authSessionInvalidatedReason or "")
		.. " realtimeConnected=" .. tostring(self.realtimeConnected == true)
		.. " realtimeConnecting=" .. tostring(self.realtimeConnecting == true)
		.. " socket=" .. tostring(self.socket ~= nil)
		.. " room=" .. tostring(self.currentRoomId or "nil")
		.. " screen=" .. tostring(self.currentScreenName or "nil"))
	self:TraceOnlineState("connect_begin", {
		source = "connect",
		hasToken = tostring(self.token or "") ~= "",
		hasUser = self.user ~= nil,
		sessionExpired = self.sessionExpired == true,
		authInvalidated = self.authSessionInvalidated == true,
		authInvalidatedReason = self.authSessionInvalidatedReason or "",
		realtimeConnected = self.realtimeConnected == true,
		realtimeConnecting = self.realtimeConnecting == true,
		socket = self.socket ~= nil,
	})
	if self.authSessionInvalidated and not self.token then
		local message = "Session ouverte ailleurs. Utilise un compte different ou reconnecte-toi depuis l'ecran de connexion."
		online_flow_trace("connect_blocked reason=auth_session_invalidated authReason="
			.. tostring(self.authSessionInvalidatedReason or ""))
		if callbacks and callbacks.error then callbacks.error(message) end
		return
	end
	if self.socket and self.realtimeConnected and not self.sessionExpired then
		online_flow_trace("connect_reused reason=realtime_already_connected generation=" .. tostring(self.realtimeGeneration or "nil"))
		if callbacks and callbacks.open then callbacks.open() end
		return
	end
	if self.realtimeConnecting then
		online_flow_trace("connect_join_inflight generation=" .. tostring(self.realtimeGeneration or "nil")
			.. " pendingCallbacks=" .. tostring(self.pendingRealtimeConnectCallbacks and #self.pendingRealtimeConnectCallbacks or 0))
		self:RememberRealtimeConnectCallbacks(callbacks)
		return
	end
	if self.token and self.user and not self.sessionExpired then
		online_flow_trace("connect_using_existing_token")
		self:ConnectWebSocket(callbacks)
		return
	end
	online_flow_trace("connect_login_required")

	if self.token and not self.sessionExpired then
		self:LoadAuthenticatedUser(function(ok, user, response)
			if not ok then
				if callbacks and callbacks.error then callbacks.error(response_message(nil, response, "Failed to load user profile.")) end
				return
			end
			apply_authenticated_user_state(self, user)
			self:ConnectWebSocket(callbacks)
		end)
		return
	end

	local config = self:Config()
	if tostring(config.accessToken or "") ~= "" then
		self:ApplyAccessToken(tostring(config.accessToken), function(ok, _user, response)
			if not ok then
				if callbacks and callbacks.error then callbacks.error(response_message(nil, response, "Failed to load user profile.")) end
				return
			end
			self:ConnectWebSocket(callbacks)
		end)
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

function ITGOnline:Disconnect(options)
	options = options or {}
	local revokeToken = options.revokeToken == true
	local roomIdToLeave = self.currentRoomId
	online_flow_trace("disconnect_begin leaveRoom=" .. tostring(options.leaveRoom ~= false)
		.. " revokeToken=" .. tostring(revokeToken == true)
		.. " room=" .. tostring(roomIdToLeave or "nil")
		.. " phase=" .. tostring(self.currentRoom and self.currentRoom.phase or "nil")
		.. " hasToken=" .. tostring(tostring(self.token or "") ~= "")
		.. " socket=" .. tostring(self.socket ~= nil)
		.. " realtimeConnected=" .. tostring(self.realtimeConnected == true)
		.. " syncInFlight=" .. tostring(self.syncInFlight == true)
		.. " requests=" .. tostring(type(self.requests) == "table"))
	self:TraceOnlineState("disconnect_begin", {
		source = "disconnect",
		leaveRoom = options.leaveRoom ~= false,
		revokeToken = revokeToken == true,
		roomToLeave = roomIdToLeave or "nil",
		hasToken = tostring(self.token or "") ~= "",
		socket = self.socket ~= nil,
		realtimeConnected = self.realtimeConnected == true,
		syncInFlight = self.syncInFlight == true,
	})
	self.disconnecting = true
	if roomIdToLeave and options.leaveRoom ~= false and self.token and NETWORK and NETWORK.HttpRequest then
		self:MarkLeavingRoom(roomIdToLeave, true)
		self:IgnoreRoomEvents(roomIdToLeave, 30)
		local config = self:ConnectionConfig()
		local leaveUrl = tostring(config.apiBaseUrl or "") .. "/rooms/" .. tostring(roomIdToLeave) .. "/leave"
		local leaveHeaders = self:AuthHeaders()
		local leaveQueued = pcall(function()
			NETWORK:HttpRequest{
				url = leaveUrl,
				method = "POST",
				body = "{}",
				headers = leaveHeaders,
				connectTimeout = 2,
				transferTimeout = 5,
				onResponse = function(response)
					online_trace("Disconnect best-effort leave room=" .. tostring(roomIdToLeave)
						.. " status=" .. tostring(response and response.statusCode or "no-status"))
				end
			}
		end)
		online_flow_trace("disconnect_best_effort_leave_queue room=" .. tostring(roomIdToLeave)
			.. " queued=" .. tostring(leaveQueued == true))
		if not leaveQueued then
			online_trace("Disconnect best-effort leave could not be queued room=" .. tostring(roomIdToLeave))
		end
	else
		online_flow_trace("disconnect_best_effort_leave_skipped room=" .. tostring(roomIdToLeave or "nil")
			.. " leaveRoom=" .. tostring(options.leaveRoom ~= false)
			.. " hasToken=" .. tostring(tostring(self.token or "") ~= "")
			.. " hasNetwork=" .. tostring(NETWORK and NETWORK.HttpRequest ~= nil))
	end
	self:CancelPendingRequests()
	if revokeToken and self.token then
		online_flow_trace("disconnect_revoke_token_request")
		local token = self.token
		self:Request("POST", "/auth/logout", {}, function() end)
		self.token = token
	end
	if self.socket then
		online_flow_trace("disconnect_socket_close generation=" .. tostring(self.realtimeGeneration or "nil"))
		self.realtimeGeneration = (tonumber(self.realtimeGeneration) or 0) + 1
		self.socket:Close()
	end
	self.socket = nil
	self.realtimeConnecting = false
	self.realtimeConnected = false
	self.pendingRealtimeConnectCallbacks = {}
	self.activeRealtimeCallbacks = nil
	self.token = nil
	self.user = nil
	self.currentRoomId = nil
	self.currentRoom = nil
	self:ClearCurrentRoomBlocked("disconnect")
	self.cachedLobbySearchPayload = { lobbies = {}, onlinePlayers = {} }
	self.currentSongPayload = nil
	self.currentRoomRoundKey = ""
	self.lastResultSongPayload = nil
	self.activeGameplaySongPayload = nil
	self.activeGameplayRoundKey = ""
	self.lastDisplayedScoreSnapshot = nil
	self.lastDisplayedScoreSnapshotAt = 0
	self.lastScoreJudgmentsByRoundKey = {}
	self.pendingLiveScoreSnapshot = nil
	self.pendingLiveScoreRoundKey = ""
	self.liveScoreInFlight = false
	self.liveScoreNextAttemptAt = 0
	self.pendingJoinRoomId = nil
	self.heartbeatInFlight = false
	self.heartbeatQueuedStatus = nil
	self.heartbeatQueuedForce = false
	self.heartbeatQueuedFingerprint = ""
	self.heartbeatQueuedAt = 0
	self.lastHeartbeatSentAt = 0
	self.lastHeartbeatFingerprint = ""
	self.lobbyRefreshQueued = false
	self.lobbyRefreshQueuedReason = ""
	self.lobbyRefreshQueuedAt = 0
	self.lobbyRefreshInFlight = false
	self.lobbyRefreshDeferredScheduled = false
	self.scheduledStartLocalTime = nil
	self.scheduledStartVisibleKey = ""
	self.scheduledStartVisibleSeconds = nil
	self.scheduledStartVisibleUpdatedAt = 0
	self.songLoadedAckKey = ""
	self.songLoadedInFlightKey = ""
	self.songLoadedPendingCallbacks = {}
	self.songAvailabilityInFlightKey = ""
	self.songAvailabilityInFlightCallbacks = {}
	self.songAvailabilityReportedKey = ""
	self.songAvailabilitySuppressedUntil = {}
	self.songSelectionInFlightKey = ""
	self.startScheduleAckKey = ""
	self.startScheduleAckInFlightKey = ""
	self.managerAutoReadyInFlightKey = ""
	self.managerAutoReadyCompletedKey = ""
	self.readyRequestInFlight = {}
	self.readyRequestLastResult = {}
	self.readyRequestBlockedErrors = {}
	self:ClearOnlineOptionsReadyDeadline("disconnect")
	self.onlineGameplayEnteredKey = ""
	self.onlineGameplayReturnedKey = ""
	self.onlineGameplayReturnedInFlightKey = ""
	self.onlineGameplayReturnedLocalRoomId = ""
	self.onlineGameplayReturnedLocalAt = 0
	self.onlineGameplayTerminalKey = ""
	self.onlineGameplayTerminalInFlightKey = ""
	self.onlineGameplayTerminalState = ""
	self.onlineGameplayFailedEarlyKey = ""
	self.onlineGameplayFailedEarlyInFlightKey = ""
	self.onlineGameplayEndedKey = ""
	self.onlineGameplayEvaluationMarkKey = ""
	self.onlineGameplayEvaluationMarkInFlightKey = ""
	self.onlineGameplayEvaluationRetryKey = ""
	self.onlineGameplayEvaluationRetryCount = 0
	self.onlineGameplayEvaluationNextRetryAt = 0
	self.onlineGameplayEvaluationTerminalErrorKey = ""
	self.onlineGameplayEvaluationNavigationKey = ""
	self.onlineGameplayEvaluationNavigationAt = 0
	self.onlineGameplayEvaluationShownKey = ""
	self.onlineGameplayEvaluationReturnedKey = ""
	self.onlineGameplayEvaluationHoldStartedKey = ""
	self.onlineGameplayEvaluationMinimumHoldUntil = 0
	self.onlineGameplayAllTerminalHoldKey = ""
	self.onlineGameplayAllTerminalHoldUntil = 0
	self.lastFinalScoreKey = ""
	self.lastFinalScoreInFlightKey = ""
	self.syncInFlight = false
	self.syncQueued = false
	self.syncCallbacks = {}
	self.syncGeneration = (self.syncGeneration or 0) + 1
	self:ResetRealtimeState()
	self:ClearTransientSecrets()
	online_flow_trace("disconnect_end syncGeneration=" .. tostring(self.syncGeneration)
		.. " realtimeGeneration=" .. tostring(self.realtimeGeneration or "nil")
		.. " currentRoomId=" .. tostring(self.currentRoomId or "nil")
		.. " token=" .. tostring(self.token ~= nil)
		.. " user=" .. tostring(self.user ~= nil)
		.. " disconnecting=" .. tostring(self.disconnecting == true))
	self:TraceOnlineState("disconnect_end", {
		source = "disconnect",
		syncGeneration = self.syncGeneration or "nil",
		realtimeGeneration = self.realtimeGeneration or "nil",
		hasToken = self.token ~= nil,
		hasUser = self.user ~= nil,
		disconnecting = self.disconnecting == true,
	})
end

function ITGOnline:Sync(callback)
	if self.disconnecting then
		online_flow_trace("sync_skipped reason=disconnecting")
		if callback then callback(false, nil, { errorMessage = "Client is disconnecting." }) end
		return
	end

	self.syncCallbacks = self.syncCallbacks or {}
	if callback then
		self.syncCallbacks[#self.syncCallbacks + 1] = callback
		online_flow_trace("sync_callback_registered count=" .. tostring(#self.syncCallbacks))
	end

	if self.syncInFlight then
		self.syncQueued = true
		online_flow_trace("sync_join_inflight queued=true generation=" .. tostring(self.syncGeneration or "nil")
			.. " callbacks=" .. tostring(#self.syncCallbacks)
			.. " lastCursor=" .. tostring(self.lastEventCursor or "nil")
			.. " screen=" .. tostring(self.currentScreenName or "nil")
			.. " room=" .. tostring(self.currentRoomId or "nil"))
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
	online_flow_trace("sync_begin generation=" .. tostring(generation)
		.. " cursor=" .. tostring(accumulator.next_cursor)
		.. " callbacks=" .. tostring(#self.syncCallbacks)
		.. " screen=" .. tostring(self.currentScreenName or "nil")
		.. " room=" .. tostring(self.currentRoomId or "nil")
		.. " phase=" .. tostring(self.currentRoom and self.currentRoom.phase or "nil")
		.. " realtimeConnected=" .. tostring(self.realtimeConnected == true)
		.. " realtimeConnecting=" .. tostring(self.realtimeConnecting == true)
		.. " pendingJoinRoomId=" .. tostring(self.pendingJoinRoomId or "nil"))
	self:TraceOnlineState("sync_begin", {
		source = "sync",
		generation = generation,
		cursor = accumulator.next_cursor,
		callbacks = #self.syncCallbacks,
		realtimeConnected = self.realtimeConnected == true,
		realtimeConnecting = self.realtimeConnecting == true,
		pendingJoinRoomId = self.pendingJoinRoomId or "nil",
	})
	self:SyncPages(accumulator, generation, 0)
end

function ITGOnline:FinishSync(generation, ok, decoded, response)
	if generation ~= self.syncGeneration then
		online_flow_trace("sync_finish_ignored reason=generation_mismatch generation=" .. tostring(generation)
			.. " current=" .. tostring(self.syncGeneration or "nil")
			.. " ok=" .. tostring(ok == true))
		return
	end

	self.syncInFlight = false
	self.syncAccumulator = nil
	online_flow_trace("sync_finish generation=" .. tostring(generation)
		.. " ok=" .. tostring(ok == true)
		.. " status=" .. tostring(response and response.statusCode or "nil")
		.. " hasCurrentRoom=" .. tostring(decoded and decoded.current_room ~= nil)
		.. " publicRooms=" .. tostring(decoded and decoded.public_rooms and #decoded.public_rooms or 0)
		.. " onlineUsers=" .. tostring(decoded and decoded.online_users and #decoded.online_users or 0)
		.. " events=" .. tostring(decoded and decoded.events and #decoded.events or 0)
		.. " nextCursor=" .. tostring(decoded and decoded.next_cursor or "nil")
		.. " lastEventCursor=" .. tostring(self.lastEventCursor or "nil")
		.. " snapshotToken=" .. tostring(decoded and decoded.meta and decoded.meta.sync and decoded.meta.sync.snapshot_token or "nil")
		.. " callbacks=" .. tostring(self.syncCallbacks and #self.syncCallbacks or 0)
		.. " queued=" .. tostring(self.syncQueued == true))
	self:TraceOnlineState("sync_finish", {
		source = "sync",
		generation = generation,
		ok = ok == true,
		status = response and response.statusCode or "nil",
		roomSnapshot = decoded and decoded.current_room or self.currentRoom,
		hasCurrentRoom = decoded and decoded.current_room ~= nil,
		publicRooms = decoded and decoded.public_rooms and #decoded.public_rooms or 0,
		onlineUsers = decoded and decoded.online_users and #decoded.online_users or 0,
		events = decoded and decoded.events and #decoded.events or 0,
		nextCursor = decoded and decoded.next_cursor or "nil",
		queued = self.syncQueued == true,
	})

	local callbacks = self.syncCallbacks or {}
	self.syncCallbacks = {}
	for cb in ivalues(callbacks) do
		if cb then cb(ok, decoded, response) end
	end

	local shouldRunQueuedSync = self.syncQueued and not self.disconnecting
	self.syncQueued = false
	if shouldRunQueuedSync then
		online_flow_trace("sync_finish_start_queued generation=" .. tostring(generation)
			.. " nextGeneration=" .. tostring((self.syncGeneration or 0) + 1)
			.. " lastEventCursor=" .. tostring(self.lastEventCursor or "nil"))
		self:Sync()
	else
		self:MaintainRealtimeAndRoomSync("sync_finish")
	end
end

function ITGOnline:ApplySyncPayload(decoded)
	if not decoded then
		online_flow_trace("sync_apply_skipped reason=no_payload")
		return
	end
	online_flow_trace("sync_apply_begin"
		.. " hasCurrentRoom=" .. tostring(decoded.current_room ~= nil)
		.. " currentRoomId=" .. tostring(self.currentRoomId or "nil")
		.. " incomingCurrentRoomId=" .. tostring(decoded.current_room and decoded.current_room.id or "nil")
		.. " incomingCurrentRoomPhase=" .. tostring(decoded.current_room and decoded.current_room.phase or "nil")
		.. " publicRooms=" .. tostring(decoded.public_rooms and #decoded.public_rooms or 0)
		.. " onlineUsers=" .. tostring(decoded.online_users and #decoded.online_users or 0)
		.. " pendingJoinRequests=" .. tostring(decoded.pending_join_requests and #decoded.pending_join_requests or 0)
		.. " pendingInvitations=" .. tostring(decoded.pending_invitations and #decoded.pending_invitations or 0)
		.. " events=" .. tostring(decoded.events and #decoded.events or 0)
		.. " nextCursor=" .. tostring(decoded.next_cursor or "nil")
		.. " screen=" .. tostring(self.currentScreenName or "nil"))

	if decoded.server_policy then
		online_flow_trace("sync_apply_server_policy present=true")
		self.serverPolicy = decoded.server_policy
	end

	for event in ivalues(decoded.events or {}) do
		online_flow_trace("sync_apply_event name=" .. tostring(event and (event.event or event.name) or "nil")
			.. " id=" .. tostring(event and event.id or "nil")
			.. " targetType=" .. tostring(event and event.target and event.target.type or "nil")
			.. " targetId=" .. tostring(event and event.target and event.target.id or "nil")
			.. " payloadRoomId=" .. tostring(event and event.payload and (event.payload.room_id or (event.payload.room and event.payload.room.id)) or "nil")
			.. " payloadPhase=" .. tostring(event and event.payload and ((event.payload.room and event.payload.room.phase) or event.payload.room_phase) or "nil"))
		self:HandleRealtimeEvent(event)
	end

	if decoded.current_room then
		if self:IsLeavingRoom(decoded.current_room.id) then
			online_flow_trace("sync_current_room_ignored reason=leaving_room room=" .. tostring(decoded.current_room.id))
			MESSAGEMAN:Broadcast("LobbySearched", self:LobbySearchPayload(decoded))
			online_flow_trace("sync_apply_broadcast lobby_searched_only reason=leaving_room"
				.. " lobbies=" .. tostring(decoded.public_rooms and #decoded.public_rooms or 0)
				.. " onlineUsers=" .. tostring(decoded.online_users and #decoded.online_users or 0))
			return
		end
		self:ClearCurrentRoomBlocked("sync_current_room")
		local room = self:ApplyRoomSnapshot(decoded.current_room, "sync_current_room")
		online_flow_trace("sync_apply_broadcast online_lobby_state room=" .. tostring((room or decoded.current_room).id or "nil")
			.. " phase=" .. tostring((room or decoded.current_room).phase or "nil")
			.. " members=" .. tostring((room or decoded.current_room).members and #(room or decoded.current_room).members or 0))
		MESSAGEMAN:Broadcast("OnlineLobbyState", self:LobbyStatePayload(room or decoded.current_room))
	else
		local conflictCode, openRoomCount = self:CurrentRoomConflictCode(decoded, nil)
		if conflictCode ~= "" then
			online_flow_trace("sync_apply_current_room_blocked code=" .. tostring(conflictCode)
				.. " openRoomCount=" .. tostring(openRoomCount or "nil"))
			self:SetCurrentRoomBlocked(conflictCode, openRoomCount, "sync_current_room")
		else
			online_flow_trace("sync_apply_clear_current_room reason=no_current_room_in_payload"
				.. " previousRoom=" .. tostring(self.currentRoomId or "nil"))
			self:ClearCurrentRoomBlocked("sync_no_current_room")
			self.currentRoomId = nil
			self.currentRoom = nil
			self.currentSongPayload = nil
			self.currentRoomRoundKey = ""
			self.lastResultSongPayload = nil
		end
	end
	MESSAGEMAN:Broadcast("LobbySearched", self:LobbySearchPayload(decoded))
	online_flow_trace("sync_apply_broadcast lobby_searched"
		.. " lobbies=" .. tostring(decoded.public_rooms and #decoded.public_rooms or 0)
		.. " onlineUsers=" .. tostring(decoded.online_users and #decoded.online_users or 0)
		.. " pendingJoinRequests=" .. tostring(decoded.pending_join_requests and #decoded.pending_join_requests or 0)
		.. " pendingInvitations=" .. tostring(decoded.pending_invitations and #decoded.pending_invitations or 0)
		.. " nextCursor=" .. tostring(decoded.next_cursor or "nil")
		.. " pendingInvitations=" .. tostring(decoded.pending_invitations and #decoded.pending_invitations or 0))

	for joinRequest in ivalues(decoded.pending_join_requests or {}) do
		online_flow_trace("sync_apply_pending_join_request id=" .. tostring(joinRequest and joinRequest.id or "nil")
			.. " room=" .. tostring(joinRequest and joinRequest.room_id or "nil")
			.. " user=" .. tostring(joinRequest and (joinRequest.user_id or joinRequest.user and joinRequest.user.id) or "nil"))
		self:BroadcastPendingJoinRequest(joinRequest, joinRequest.room)
	end

	for invitation in ivalues(decoded.pending_invitations or {}) do
		online_flow_trace("sync_apply_pending_invitation id=" .. tostring(invitation and invitation.id or "nil")
			.. " room=" .. tostring(invitation and invitation.room_id or "nil")
			.. " inviter=" .. tostring(invitation and invitation.inviter and invitation.inviter.id or "nil"))
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
	online_flow_trace("sync_apply_end currentRoomId=" .. tostring(self.currentRoomId or "nil")
		.. " cachedLobbies=" .. tostring(self.cachedLobbySearchPayload and self.cachedLobbySearchPayload.lobbies and #self.cachedLobbySearchPayload.lobbies or 0)
		.. " cachedOnlinePlayers=" .. tostring(self.cachedLobbySearchPayload and self.cachedLobbySearchPayload.onlinePlayers and #self.cachedLobbySearchPayload.onlinePlayers or 0))
end

function ITGOnline:BroadcastPendingJoinRequest(joinRequest, room)
	if type(joinRequest) ~= "table" or not joinRequest.id then
		online_flow_trace("pending_join_request_broadcast_skipped reason=invalid_payload")
		return false
	end

	local requestId = tostring(joinRequest.id)
	self.promptedPendingJoinRequestIds = self.promptedPendingJoinRequestIds or {}
	if self.promptedPendingJoinRequestIds[requestId] then
		online_flow_trace("pending_join_request_broadcast_skipped reason=already_prompted id=" .. tostring(requestId))
		return false
	end

	local resolvedRoom = room or joinRequest.room or self.currentRoom
	local roomId = joinRequest.room_id
		or (resolvedRoom and resolvedRoom.id)
		or self.currentRoomId

	self.promptedPendingJoinRequestIds[requestId] = true
	online_flow_trace("pending_join_request_broadcast id=" .. tostring(requestId)
		.. " room=" .. tostring(roomId or "nil")
		.. " requester=" .. tostring(joinRequest.user_id or joinRequest.user and joinRequest.user.id or "nil")
		.. " hasRoom=" .. tostring(resolvedRoom ~= nil))
	MESSAGEMAN:Broadcast("OnlinePrivateJoinRequest", {
		join_request = {
			id = joinRequest.id,
			room_id = roomId,
			user_id = joinRequest.user_id or (joinRequest.user and joinRequest.user.id) or nil,
			status = joinRequest.status or "pending",
		},
		requester = joinRequest.user,
		room = resolvedRoom,
	})
	return true
end

function ITGOnline:BroadcastPendingJoinRequestsFromRoom(room)
	if type(room) ~= "table" then return 0 end
	local count = 0
	for joinRequest in ivalues(room.pending_join_requests or {}) do
		if self:BroadcastPendingJoinRequest(joinRequest, room) then
			count = count + 1
		end
	end
	return count
end

function ITGOnline:SyncPages(accumulator, generation, pageCount)
	pageCount = pageCount or 0
	self.lastSyncRequestedAt = GetTimeSinceStart()
	if generation ~= self.syncGeneration or not accumulator then
		online_flow_trace("sync_page_skipped reason=stale_or_missing_accumulator generation=" .. tostring(generation)
			.. " current=" .. tostring(self.syncGeneration or "nil")
			.. " hasAccumulator=" .. tostring(accumulator ~= nil))
		return
	end
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
	online_flow_trace("sync_page_request generation=" .. tostring(generation)
		.. " page=" .. tostring(page)
		.. " cursor=" .. tostring(cursor)
		.. " snapshotToken=" .. tostring(accumulator.snapshot_token or "nil")
		.. " budgetMultiplier=" .. tostring(accumulator.syncPageBudgetMultiplier or 1)
		.. " disconnecting=" .. tostring(self.disconnecting == true))
	self:Request("GET", query, nil, function(ok, decoded, response)
		if generation ~= self.syncGeneration then
			online_flow_trace("sync_page_response_ignored reason=generation_mismatch generation=" .. tostring(generation)
				.. " current=" .. tostring(self.syncGeneration or "nil")
				.. " ok=" .. tostring(ok == true))
			return
		end
		online_flow_trace("sync_page_response generation=" .. tostring(generation)
			.. " page=" .. tostring(page)
			.. " ok=" .. tostring(ok == true)
			.. " status=" .. tostring(response and response.statusCode or "nil")
			.. " onlineUsers=" .. tostring(decoded and decoded.online_users and #decoded.online_users or 0)
			.. " publicRooms=" .. tostring(decoded and decoded.public_rooms and #decoded.public_rooms or 0)
			.. " joinRequests=" .. tostring(decoded and decoded.pending_join_requests and #decoded.pending_join_requests or 0)
			.. " invitations=" .. tostring(decoded and decoded.pending_invitations and #decoded.pending_invitations or 0)
			.. " events=" .. tostring(decoded and decoded.events and #decoded.events or 0)
			.. " nextCursor=" .. tostring(decoded and decoded.next_cursor or "nil")
			.. " hasCurrentRoom=" .. tostring(decoded and decoded.current_room ~= nil)
			.. " error=" .. tostring(decoded and decoded.error_code or response and response.errorMessage or "nil"))

		if ok and decoded then
			if decoded.next_cursor then
				accumulator.next_cursor = math.max(accumulator.next_cursor or self.lastEventCursor or 0, tonumber(decoded.next_cursor) or 0)
			end

			accumulator.seen = accumulator.seen or {}
			for _, key in ipairs({ "online_users", "public_rooms", "pending_join_requests", "pending_invitations", "events" }) do
				accumulator.seen[key] = accumulator.seen[key] or {}
				for item in ivalues(decoded[key] or {}) do
					local itemId = type(item) == "table" and (item.id or item.room_id or (item.user and item.user.id)) or nil
					local itemKey = tostring(itemId or (#accumulator[key] + 1) .. ":" .. tostring(item))
					if not accumulator.seen[key][itemKey] then
						accumulator.seen[key][itemKey] = true
						accumulator[key][#accumulator[key] + 1] = item
					end
				end
				decoded[key] = accumulator[key]
			end

			local meta = decoded.meta or {}
			if meta.sync and meta.sync.snapshot_token then
				accumulator.snapshot_token = tostring(meta.sync.snapshot_token)
			end
			local eventsMeta = meta.events or {}
			if eventsMeta.cursor_too_old then
				if not accumulator.cursorTooOld then
					online_trace("Sync cursor too old; discarding partial event replay and reconciling from snapshots.")
					online_flow_trace("sync_page_cursor_too_old generation=" .. tostring(generation)
						.. " page=" .. tostring(page)
						.. " cursor=" .. tostring(cursor))
				end
				accumulator.cursorTooOld = true
			end
			if accumulator.cursorTooOld then
				accumulator.events = {}
				if accumulator.seen then accumulator.seen.events = {} end
				decoded.events = {}
			end
			local hasMore = ((not accumulator.cursorTooOld) and eventsMeta.has_more)
				or (meta.online_users and meta.online_users.has_more)
				or (meta.public_rooms and meta.public_rooms.has_more)
				or (meta.pending_join_requests and meta.pending_join_requests.has_more)
				or (meta.pending_invitations and meta.pending_invitations.has_more)
			local baseBudget = math.max(1, tonumber(self.syncMaxPages or 100) or 100)
			local budgetMultiplier = math.max(1, tonumber(accumulator.syncPageBudgetMultiplier or 1) or 1)
			local pageBudget = baseBudget * budgetMultiplier
			online_flow_trace("sync_page_aggregate generation=" .. tostring(generation)
				.. " page=" .. tostring(page)
				.. " hasMore=" .. tostring(hasMore == true)
				.. " pageBudget=" .. tostring(pageBudget)
				.. " onlineUsersTotal=" .. tostring(#accumulator.online_users)
				.. " publicRoomsTotal=" .. tostring(#accumulator.public_rooms)
				.. " joinRequestsTotal=" .. tostring(#accumulator.pending_join_requests)
				.. " invitationsTotal=" .. tostring(#accumulator.pending_invitations)
				.. " eventsTotal=" .. tostring(#accumulator.events)
				.. " cursor=" .. tostring(accumulator.next_cursor or "nil"))
			if hasMore and page < pageBudget and not self.disconnecting then
				online_flow_trace("sync_page_continue generation=" .. tostring(generation)
					.. " nextPage=" .. tostring(page + 1)
					.. " pageBudget=" .. tostring(pageBudget))
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
					accumulator.seen = {}
					local maxMultiplier = math.max(1, tonumber(self.syncOverflowMaxBudgetMultiplier or 4) or 4)
					accumulator.syncPageBudgetMultiplier = math.min(
						maxMultiplier,
						math.max(1, tonumber(accumulator.syncPageBudgetMultiplier or 1) or 1) * 2
					)
					online_trace("Sync overflow retry " .. tostring(attempt) .. "/" .. tostring(maxRetries)
						.. " with page budget x" .. tostring(accumulator.syncPageBudgetMultiplier))
					online_flow_trace("sync_page_overflow_retry generation=" .. tostring(generation)
						.. " attempt=" .. tostring(attempt)
						.. " maxRetries=" .. tostring(maxRetries)
						.. " nextBudgetMultiplier=" .. tostring(accumulator.syncPageBudgetMultiplier))
					self:SyncPages(accumulator, generation, 0)
					return
				end

				local syncResponse = { errorMessage = "Sync did not complete before the page budget was exhausted." }
				online_trace(syncResponse.errorMessage)
				online_flow_trace("sync_page_overflow_failed generation=" .. tostring(generation)
					.. " page=" .. tostring(page)
					.. " pageBudget=" .. tostring(pageBudget)
					.. " attempts=" .. tostring(attempt))
				MESSAGEMAN:Broadcast("OnlineResponseStatus", {
					event = "sync",
					success = false,
					message = syncResponse.errorMessage,
				})
				self:FinishSync(generation, false, decoded, syncResponse)
				return
			end

			self:ApplySyncPayload(decoded)
			self.lastEventCursor = math.max(self.lastEventCursor or 0, tonumber(accumulator.next_cursor or decoded.next_cursor or 0) or 0)
			online_flow_trace("sync_page_complete generation=" .. tostring(generation)
				.. " lastEventCursor=" .. tostring(self.lastEventCursor or "nil")
				.. " page=" .. tostring(page))
		end

		self:FinishSync(generation, ok, decoded, response)
	end)
end

function ITGOnline:BuildSongPayloadFor(song, steps)
	online_flow_trace_throttled("song_payload_build_for", 1.0,
		"song_payload_build_for hasSong=" .. tostring(song ~= nil)
		.. " hasSteps=" .. tostring(steps ~= nil)
		.. " songDir=" .. tostring(song and song.GetSongDir and song:GetSongDir() or "nil")
		.. " stepsType=" .. tostring(steps and steps.GetStepsType and steps:GetStepsType() or "nil")
		.. " difficulty=" .. tostring(steps and steps.GetDifficulty and steps:GetDifficulty() or "nil"))
	if not song then return nil end
	steps = steps or selected_steps()
	local path = song_path(song)
	local chartType = normalize_chart_type(steps and enum_short(steps:GetStepsType()) or "")
	local difficulty = steps and enum_short(steps:GetDifficulty()) or "unknown"
	local meter = steps and steps:GetMeter() or nil
	local songFilePath = song.GetSongFilePath and song:GetSongFilePath() or ""
	local musicPath = song.GetMusicPath and song:GetMusicPath() or ""
	local songFileHash = cached_sha256_file_hex(songFilePath)
	local musicHash = cached_sha256_file_hex(musicPath)
	if not songFileHash or not musicHash then return nil end
	local musicName = manifest_file_name(musicPath)
	local songFileName = manifest_file_name(songFilePath)
	if not musicName or not songFileName then return nil end
	local chartHash = self:ChartHashForSteps(steps)
	local chartKey = steps and steps.GetChartKey and tostring(steps:GetChartKey() or "") or ""
	local globalOptions = self:CurrentGlobalOptions()
	local rate = tonumber(globalOptions and globalOptions.music_rate) or current_music_rate()
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
		chart_key = chartKey ~= "" and chartKey or nil,
		simfile_relative_path = simfile_relative_path(songFilePath),
		simfile_hash = chartHash,
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

function ITGOnline:BuildSongPayload()
	online_flow_trace_throttled("song_payload_build_current", 1.0,
		"song_payload_build_current currentRoom=" .. tostring(self.currentRoomId or "nil")
		.. " phase=" .. tostring(self.currentRoom and self.currentRoom.phase or "nil")
		.. " screen=" .. tostring(self.currentScreenName or "nil"))
	return self:BuildSongPayloadFor(GAMESTATE:GetCurrentSong(), selected_steps())
end

function ITGOnline:ApplyMatchedSongSelection(match, source)
	if not match or not match.song then
		online_flow_trace("apply_matched_song_selection_skipped reason=no_match"
			.. " source=" .. tostring(source or "unknown")
			.. " room=" .. tostring(self.currentRoomId or "nil"))
		return false
	end

	GAMESTATE:SetCurrentSong(match.song)
	if match.steps then
		for player in ivalues(GAMESTATE:GetEnabledPlayers()) do
			GAMESTATE:SetCurrentSteps(player, match.steps)
		end
	end

	if match.payload then
		self.currentSongPayload = match.payload
	end

	online_flow_trace("apply_matched_song_selection_applied"
		.. " source=" .. tostring(source or "unknown")
		.. " room=" .. tostring(self.currentRoomId or "nil")
		.. " songDir=" .. tostring(match.song.GetSongDir and match.song:GetSongDir() or "nil")
		.. " hasSteps=" .. tostring(match.steps ~= nil)
		.. " matchSource=" .. tostring(match.matchSource or "nil")
		.. " songHash=" .. tostring(match.payload and match.payload.song_hash or "nil")
		.. " chartHash=" .. tostring(match.payload and match.payload.chart_hash or "nil"))
	return true
end

function ITGOnline:SelectedSongPayloadMatchesExpected(payload, selectedSong)
	if not payload then return false, "local_payload_unavailable" end
	selectedSong = selectedSong or {}
	local expectedSongHash = selectedSong.song_hash or selectedSong.songHash
	local expectedChartHash = selectedSong.chart_hash or selectedSong.chartHash
	if expectedSongHash and expectedSongHash ~= "" and payload.song_hash ~= expectedSongHash then
		return false, "song_hash_mismatch"
	end
	if expectedChartHash and expectedChartHash ~= "" and payload.chart_hash ~= expectedChartHash then
		return false, "chart_hash_mismatch"
	end
	return true, "matched"
end

function ITGOnline:ResolveSelectedSongAvailabilityPayload(selectedSong, source)
	selectedSong = selectedSong or {}
	local directPayload = self:BuildSongPayload()
	local directOk, directReason = self:SelectedSongPayloadMatchesExpected(directPayload, selectedSong)
	if directOk then
		online_flow_trace("song_availability_local_resolved source=" .. tostring(source or "unknown")
			.. " method=current_selection"
			.. " songHash=" .. tostring(directPayload.song_hash or "nil")
			.. " chartHash=" .. tostring(directPayload.chart_hash or "nil"))
		return directPayload, "current_selection"
	end

	online_flow_trace("song_availability_current_selection_unusable source=" .. tostring(source or "unknown")
		.. " reason=" .. tostring(directReason or "unknown")
		.. " selectedAt=" .. tostring(selectedSong.selected_at or selectedSong.selectedAt or "nil")
		.. " expectedSongHash=" .. tostring(selectedSong.song_hash or selectedSong.songHash or "nil")
		.. " expectedChartHash=" .. tostring(selectedSong.chart_hash or selectedSong.chartHash or "nil"))

	if self.PackSync and self.PackSync.FindLocalMatch then
		local match = self.PackSync:FindLocalMatch(selectedSong)
		if match and match.ok and match.payload then
			self:ApplyMatchedSongSelection(match, "availability:" .. tostring(source or "unknown"))
			online_flow_trace("song_availability_local_resolved source=" .. tostring(source or "unknown")
				.. " method=packsync_hash_match"
				.. " matchSource=" .. tostring(match.matchSource or "nil")
				.. " songHash=" .. tostring(match.payload.song_hash or "nil")
				.. " chartHash=" .. tostring(match.payload.chart_hash or "nil"))
			return match.payload, tostring(match.matchSource or "packsync_hash_match")
		end

		online_flow_trace("song_availability_pack_sync_match_failed source=" .. tostring(source or "unknown")
			.. " status=" .. tostring(match and match.status or "nil")
			.. " reason=" .. tostring(match and match.reason or directReason or "unknown"))
		return nil, tostring(match and match.reason or directReason or "local_payload_unavailable")
	end

	return nil, tostring(directReason or "local_payload_unavailable")
end

function ITGOnline:ChartHashForSteps(steps)
	if not steps then
		online_flow_trace("chart_hash_skipped reason=no_steps")
	end
	local stepsHash = steps and tostring(steps:GetHash()) or "no-steps"
	local grooveStatsHash = steps and steps.GetGrooveStatsHash and tostring(steps:GetGrooveStatsHash()) or ""

	return normalized_hash(grooveStatsHash ~= "" and grooveStatsHash or stepsHash)
end

function ITGOnline:SelectSong(callback, options)
	options = type(options) == "table" and options or {}
	if self.ReconcileCurrentRoomAfterRealtimeGap then
		self:ReconcileCurrentRoomAfterRealtimeGap("select_song_before_request", 0.75)
	end
	if not self.currentRoomId then
		online_flow_trace("song_selection_failed reason=no_current_room"
			.. " phase=" .. tostring(self.currentRoom and self.currentRoom.phase or "nil")
			.. " screen=" .. tostring(self.currentScreenName or "nil"))
		if callback then callback(false, nil, { errorMessage = "No active online room." }) end
		return
	end
	if not has_server_scoring_policy() then
		online_flow_trace("song_selection_policy_missing sync_begin room=" .. tostring(self.currentRoomId)
			.. " phase=" .. tostring(self.currentRoom and self.currentRoom.phase or "nil"))
		self:Sync(function(ok)
			online_flow_trace("song_selection_policy_sync_result ok=" .. tostring(ok == true)
				.. " hasPolicy=" .. tostring(has_server_scoring_policy() == true)
				.. " room=" .. tostring(self.currentRoomId or "nil"))
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

	local song = GAMESTATE:GetCurrentSong()
	local steps = selected_steps()
	local payload = self:BuildSongPayloadFor(song, steps)
	if not payload then
		local songFilePath = song and song.GetSongFilePath and song:GetSongFilePath() or ""
		local musicPath = song and song.GetMusicPath and song:GetMusicPath() or ""
		local songFileExists = songFilePath ~= "" and FILEMAN:DoesFileExist(songFilePath) or false
		local musicFileExists = musicPath ~= "" and FILEMAN:DoesFileExist(musicPath) or false
		online_flow_trace("song_selection_payload_missing"
			.. " song=" .. tostring(song and song.GetDisplayFullTitle and song:GetDisplayFullTitle() or "nil")
			.. " song_path=" .. tostring(song and song_path(song) or "nil")
			.. " steps=" .. tostring(steps ~= nil)
			.. " note_count=" .. tostring(current_chart_note_count(steps))
			.. " song_file=" .. tostring(songFilePath)
			.. " song_file_exists=" .. tostring(songFileExists)
			.. " music_file=" .. tostring(musicPath)
			.. " music_file_exists=" .. tostring(musicFileExists)
			.. " room=" .. tostring(self.currentRoomId or "nil"))
		if callback then callback(false, nil, { errorMessage = "No selected song or chart." }) end
		MESSAGEMAN:Broadcast("OnlineResponseStatus", {
			event = "selectSong",
			success = false,
			message = "No selected song or chart."
		})
		return
	end

	local previousSongPayload = self.currentSongPayload
	local selectionKey = tostring(self.currentRoomId or "") .. "|"
		.. tostring(payload.song_hash or "") .. "|"
		.. tostring(payload.chart_hash or "") .. "|"
		.. tostring(payload.chart_note_count or "") .. "|"
		.. tostring(payload.rate or "")
	payload.client_action_id = request_id()
	local existingSong = self.currentRoom and self.currentRoom.selected_song or nil
	local existingSelectionKey = existingSong and table.concat({
		tostring(self.currentRoomId or ""),
		tostring(existingSong.song_hash or existingSong.songHash or ""),
		tostring(existingSong.chart_hash or existingSong.chartHash or ""),
		tostring(existingSong.chart_note_count or existingSong.chartNoteCount or ""),
		tostring(existingSong.rate or existingSong.music_rate or existingSong.musicRate or ""),
	}, "|") or ""
	local replacingExistingSelection = existingSelectionKey ~= "" and existingSelectionKey ~= selectionKey
	if self:IsSongSelectionTransitionLocked("select") then
		online_flow_trace("song_selection_rejected reason=transition_inflight"
			.. " transition=" .. tostring(self.songSelectionTransitionKind or "")
			.. " transitionRoom=" .. tostring(self.songSelectionTransitionRoomId or "nil")
			.. " requested=" .. tostring(selectionKey)
			.. " existing=" .. tostring(existingSelectionKey))
		if callback then callback(false, nil, { errorMessage = "Song selection is already updating." }) end
		return
	end
	if replacingExistingSelection then
		online_flow_trace("song_selection_replace_existing_atomic_server"
			.. " room=" .. tostring(self.currentRoomId)
			.. " phase=" .. tostring(self.currentRoom and self.currentRoom.phase or "nil")
			.. " existing=" .. tostring(existingSelectionKey)
			.. " next=" .. tostring(selectionKey))
	end
	if self.songSelectionInFlightKey ~= "" then
		if self.songSelectionInFlightKey == selectionKey then
			online_flow_trace("song_selection_join_inflight key=" .. tostring(selectionKey))
			if callback then
				self.songSelectionInFlightCallbacks[#self.songSelectionInFlightCallbacks + 1] = callback
			end
			return
		end
		online_flow_trace("song_selection_rejected reason=another_inflight current=" .. tostring(self.songSelectionInFlightKey)
			.. " requested=" .. tostring(selectionKey))
		if callback then callback(false, nil, { errorMessage = "Another song selection is already in progress." }) end
		return
	end

	online_flow_trace("song_selection_request room=" .. tostring(self.currentRoomId)
		.. " actionId=" .. tostring(payload.client_action_id or "")
		.. " title=" .. tostring(payload.title or "")
		.. " pack=" .. tostring(payload.pack or "")
		.. " chart=" .. tostring(payload.chart_hash or ""):sub(1, 12)
		.. " song=" .. tostring(payload.song_hash or ""):sub(1, 12))
	self:TraceOnlineState("song_selection_request", {
		source = "select_song",
		actionId = payload.client_action_id or "",
		title = payload.title or "",
		pack = payload.pack or "",
		songHash = tostring(payload.song_hash or ""):sub(1, 12),
		chartHash = tostring(payload.chart_hash or ""):sub(1, 12),
		replacingExisting = replacingExistingSelection == true,
		selectionKey = selectionKey,
	})
	self:BeginSongSelectionTransition("select", self.currentRoomId)
	self.songSelectionInFlightKey = selectionKey
	self.songSelectionInFlightCallbacks = {}
	if callback then
		self.songSelectionInFlightCallbacks[#self.songSelectionInFlightCallbacks + 1] = callback
	end
	self:Request("POST", "/rooms/" .. tostring(self.currentRoomId) .. "/song-selection", payload, function(ok, decoded, response)
		local callbacks = self.songSelectionInFlightCallbacks or {}
		self.songSelectionInFlightKey = ""
		self.songSelectionInFlightCallbacks = {}
		self:ClearSongSelectionTransition("select_response")
		online_flow_trace("song_selection_response ok=" .. tostring(ok == true)
			.. " status=" .. tostring(response and response.statusCode or "nil")
			.. " error=" .. tostring(decoded and decoded.error_code or response and response.error or "nil")
			.. " message=" .. tostring(decoded and decoded.message or response and response.errorMessage or "nil"))
		self:TraceOnlineState("song_selection_response", {
			source = "select_song",
			roomSnapshot = decoded and decoded.room or nil,
			ok = ok == true,
			status = response and response.statusCode or "nil",
			error = decoded and decoded.error_code or response and response.error or "nil",
			selectionKey = selectionKey,
		})
		if ok and decoded and decoded.room then
			local room = self:ApplyRoomSnapshot(decoded.room, "song_selection")
			decoded.room = room or decoded.room
			self.currentSongPayload = (room and room.selected_song) or payload
			self:ResetOnlineRoundRuntimeState("song_selection")
			MESSAGEMAN:Broadcast("OnlineLobbyState", self:LobbyStatePayload(decoded.room))
		elseif ok then
			self:FetchRoom(self.currentRoomId)
		else
			self.currentSongPayload = previousSongPayload
			if self.EnforceRoomPhaseScreen then
				self:EnforceRoomPhaseScreen()
			end
		end
		for cb in ivalues(callbacks) do
			if cb then cb(ok, decoded, response) end
		end
	end)
end

function ITGOnline:IsSongSelectionTransitionLocked(reason)
	if self.songSelectionTransitionInFlight ~= true then return false end
	local now = GetTimeSinceStart()
	local startedAt = tonumber(self.songSelectionTransitionStartedAt) or 0
	local timeout = tonumber(self.songSelectionTransitionTimeoutSeconds) or 4.0
	if startedAt > 0 and now - startedAt > timeout then
		online_flow_trace("song_selection_transition_lock_expired"
			.. " reason=" .. tostring(reason or "unknown")
			.. " transition=" .. tostring(self.songSelectionTransitionKind or "")
			.. " room=" .. tostring(self.songSelectionTransitionRoomId or "nil")
			.. " age=" .. tostring(now - startedAt)
			.. " timeout=" .. tostring(timeout))
		self.songSelectionTransitionInFlight = false
		self.songSelectionTransitionKind = ""
		self.songSelectionTransitionRoomId = nil
		self.songSelectionTransitionStartedAt = 0
		return false
	end
	return true
end

function ITGOnline:BeginSongSelectionTransition(kind, roomId)
	self.songSelectionTransitionInFlight = true
	self.songSelectionTransitionKind = tostring(kind or "unknown")
	self.songSelectionTransitionRoomId = roomId or self.currentRoomId
	self.songSelectionTransitionStartedAt = GetTimeSinceStart()
	online_flow_trace("song_selection_transition_begin"
		.. " kind=" .. tostring(self.songSelectionTransitionKind)
		.. " room=" .. tostring(self.songSelectionTransitionRoomId or "nil")
		.. " phase=" .. tostring(self.currentRoom and self.currentRoom.phase or "nil"))
end

function ITGOnline:ClearSongSelectionTransition(reason)
	if self.songSelectionTransitionInFlight ~= true then return end
	online_flow_trace("song_selection_transition_clear"
		.. " reason=" .. tostring(reason or "unknown")
		.. " kind=" .. tostring(self.songSelectionTransitionKind or "")
		.. " room=" .. tostring(self.songSelectionTransitionRoomId or "nil")
		.. " age=" .. tostring(GetTimeSinceStart() - (tonumber(self.songSelectionTransitionStartedAt) or GetTimeSinceStart())))
	self.songSelectionTransitionInFlight = false
	self.songSelectionTransitionKind = ""
	self.songSelectionTransitionRoomId = nil
	self.songSelectionTransitionStartedAt = 0
end

function ITGOnline:RememberSongSelectionCancelled(room, source)
	local roomId = tostring(room and room.id or self.currentRoomId or "")
	if roomId == "" then return end

	local incomingRoomVersion = tonumber(room and (room.room_version or room.roomVersion)) or 0
	local previousCancelVersion = tonumber(self.songSelectionCancelledVersionByRoomId[roomId]) or 0
	if incomingRoomVersion > previousCancelVersion then
		self.songSelectionCancelledVersionByRoomId[roomId] = incomingRoomVersion
	end
	self.songSelectionCancelledAtByRoomId[roomId] = GetTimeSinceStart()

	online_flow_trace("song_selection_cancel_guard_recorded"
		.. " source=" .. tostring(source or "unknown")
		.. " room=" .. tostring(roomId)
		.. " roomVersion=" .. tostring(incomingRoomVersion)
		.. " storedCancelVersion=" .. tostring(self.songSelectionCancelledVersionByRoomId[roomId] or 0)
		.. " selectionId=" .. tostring(room and (room.current_selection_id or room.currentSelectionId) or "nil"))
end

function ITGOnline:ShouldRejectSongSelectedAfterCancel(room, source)
	local sourceText = tostring(source or "")
	if not sourceText:find("song_selected", 1, true) then return false end
	if not (room and room.selected_song) then return false end

	local roomId = tostring(room.id or self.currentRoomId or "")
	if roomId == "" then return false end

	local incomingRoomVersion = tonumber(room.room_version or room.roomVersion) or 0
	local cancelVersion = tonumber(self.songSelectionCancelledVersionByRoomId[roomId]) or 0
	if incomingRoomVersion > 0 and cancelVersion > 0 and incomingRoomVersion <= cancelVersion then
		online_flow_trace("song_selection_snapshot_rejected_after_cancel"
			.. " source=" .. sourceText
			.. " room=" .. tostring(roomId)
			.. " incomingRoomVersion=" .. tostring(incomingRoomVersion)
			.. " cancelVersion=" .. tostring(cancelVersion)
			.. " selectedAt=" .. tostring(room.selected_song and (room.selected_song.selected_at or room.selected_song.selectedAt) or "nil"))
		return true
	end

	return false
end

function ITGOnline:UpdateGlobalOptions(options, callback)
	if not self.currentRoomId then
		online_flow_trace("global_options_failed reason=no_current_room")
		if callback then callback(false, nil, { errorMessage = "No active online room." }) end
		return
	end

	options = type(options) == "table" and options or {}
	local normalized = self:NormalizeGlobalOptions(options)
	local payload = {}
	if options.score_mode ~= nil or options.scoreMode ~= nil then
		payload.score_mode = normalized.score_mode
	end
	if options.music_rate ~= nil or options.musicRate ~= nil then
		payload.music_rate = normalized.music_rate
	end
	if payload.score_mode == nil and payload.music_rate == nil then
		payload.score_mode = normalized.score_mode
		payload.music_rate = normalized.music_rate
	end
	online_flow_trace("global_options_request room=" .. tostring(self.currentRoomId)
		.. " phase=" .. tostring(self.currentRoom and self.currentRoom.phase or "nil")
		.. " scoreMode=" .. tostring(payload.score_mode or "nil")
		.. " musicRate=" .. tostring(payload.music_rate or "nil")
		.. " requestedScoreMode=" .. tostring(options.score_mode or options.scoreMode or "nil")
		.. " requestedMusicRate=" .. tostring(options.music_rate or options.musicRate or "nil"))
	self:TraceOnlineState("global_options_request", {
		source = "global_options",
		scoreMode = payload.score_mode or "nil",
		musicRate = payload.music_rate or "nil",
		requestedScoreMode = options.score_mode or options.scoreMode or "nil",
		requestedMusicRate = options.music_rate or options.musicRate or "nil",
	})

	self:Request("POST", "/rooms/" .. tostring(self.currentRoomId) .. "/global-options", payload, function(ok, decoded, response)
		online_flow_trace("global_options_response ok=" .. tostring(ok == true)
			.. " status=" .. tostring(response and response.statusCode or "nil")
			.. " hasRoom=" .. tostring(decoded and decoded.room ~= nil)
			.. " phase=" .. tostring(decoded and decoded.room and decoded.room.phase or "nil")
			.. " error=" .. tostring(decoded and decoded.error_code or response and response.errorMessage or "nil"))
		self:TraceOnlineState("global_options_response", {
			source = "global_options",
			roomSnapshot = decoded and decoded.room or nil,
			ok = ok == true,
			status = response and response.statusCode or "nil",
			error = decoded and decoded.error_code or response and response.errorMessage or "nil",
			scoreMode = payload.score_mode or "nil",
			musicRate = payload.music_rate or "nil",
		})
		if ok and decoded and decoded.room then
			local room = self:ApplyRoomSnapshot(decoded.room, "global_options")
			decoded.room = room or decoded.room
			MESSAGEMAN:Broadcast("OnlineLobbyState", self:LobbyStatePayload(decoded.room))
			MESSAGEMAN:Broadcast("OnlineResponseStatus", {
				event = "globalOptions",
				success = true,
				message = "Options globales mises a jour."
			})
		else
			MESSAGEMAN:Broadcast("OnlineResponseStatus", {
				event = "globalOptions",
				success = false,
				message = response_message(response, decoded, "Impossible de mettre a jour les options globales.")
			})
		end

		if callback then callback(ok, decoded, response) end
	end)
end

function ITGOnline:TransferRoomManager(userId, callback)
	if not self.currentRoomId then
		if callback then callback(false, nil, { errorMessage = "No active online room." }) end
		return
	end

	self:TraceOnlineState("manager_transfer_request", {
		source = "manager_transfer",
		targetUser = userId,
	})
	self:Request("POST", "/rooms/" .. tostring(self.currentRoomId) .. "/transfer-manager", {
		user_id = tonumber(userId) or userId,
	}, function(ok, decoded, response)
		self:TraceOnlineState("manager_transfer_response", {
			source = "manager_transfer",
			roomSnapshot = decoded and decoded.room or nil,
			targetUser = userId,
			ok = ok == true,
			status = response and response.statusCode or "nil",
			error = decoded and decoded.error_code or response and response.errorMessage or "nil",
		})
		if ok and decoded and decoded.room then
			local room = self:ApplyRoomSnapshot(decoded.room, "manager_transfer")
			decoded.room = room or decoded.room
			MESSAGEMAN:Broadcast("OnlineLobbyState", self:LobbyStatePayload(decoded.room))
			MESSAGEMAN:Broadcast("OnlineResponseStatus", {
				event = "managerTransfer",
				success = true,
				message = "Role manager transfere."
			})
		else
			MESSAGEMAN:Broadcast("OnlineResponseStatus", {
				event = "managerTransfer",
				success = false,
				message = response_message(response, decoded, "Impossible de transferer le role manager.")
			})
		end

		if callback then callback(ok, decoded, response) end
	end)
end

function ITGOnline:KickRoomMember(userId, callback)
	if not self.currentRoomId then
		if callback then callback(false, nil, { errorMessage = "No active online room." }) end
		return
	end

	self:TraceOnlineState("room_member_kick_request", {
		source = "room_member_kick",
		targetUser = userId,
	})
	self:Request("POST", "/rooms/" .. tostring(self.currentRoomId) .. "/kick", {
		user_id = tonumber(userId) or userId,
	}, function(ok, decoded, response)
		self:TraceOnlineState("room_member_kick_response", {
			source = "room_member_kick",
			roomSnapshot = decoded and decoded.room or nil,
			targetUser = userId,
			ok = ok == true,
			status = response and response.statusCode or "nil",
			error = decoded and decoded.error_code or response and response.errorMessage or "nil",
		})
		if ok and decoded and decoded.room then
			local room = self:ApplyRoomSnapshot(decoded.room, "room_member_kick")
			decoded.room = room or decoded.room
			MESSAGEMAN:Broadcast("OnlineLobbyState", self:LobbyStatePayload(decoded.room))
			MESSAGEMAN:Broadcast("OnlineResponseStatus", {
				event = "memberKick",
				success = true,
				message = "Joueur exclu du salon."
			})
		else
			MESSAGEMAN:Broadcast("OnlineResponseStatus", {
				event = "memberKick",
				success = false,
				message = response_message(response, decoded, "Impossible d'exclure ce joueur.")
			})
		end

		if callback then callback(ok, decoded, response) end
	end)
end

function ITGOnline:CancelSongSelection(callback)
	if not self.currentRoomId then
		online_flow_trace("song_selection_cancel_failed reason=no_current_room")
		if callback then callback(false, nil, { errorMessage = "No active online room." }) end
		return
	end
	if self:IsSongSelectionTransitionLocked("cancel") then
		online_flow_trace("song_selection_cancel_rejected reason=transition_inflight"
			.. " transition=" .. tostring(self.songSelectionTransitionKind or "")
			.. " transitionRoom=" .. tostring(self.songSelectionTransitionRoomId or "nil")
			.. " room=" .. tostring(self.currentRoomId or "nil")
			.. " phase=" .. tostring(self.currentRoom and self.currentRoom.phase or "nil"))
		if callback then callback(false, nil, { errorMessage = "Song selection is already updating." }) end
		return
	end

	online_flow_trace("song_selection_cancel_request room=" .. tostring(self.currentRoomId)
		.. " phase=" .. tostring(self.currentRoom and self.currentRoom.phase or "nil")
		.. " hasSelectedSong=" .. tostring(self.currentRoom and self.currentRoom.selected_song ~= nil)
		.. " songPayload=" .. tostring(self.currentSongPayload ~= nil))
	self:TraceOnlineState("song_selection_cancel_request", {
		source = "cancel_song_selection",
		hasSelectedSong = self.currentRoom and self.currentRoom.selected_song ~= nil,
		hasSongPayload = self.currentSongPayload ~= nil,
	})
	self:BeginSongSelectionTransition("cancel", self.currentRoomId)
	local payload = { client_action_id = request_id() }
	online_flow_trace("song_selection_cancel_action actionId=" .. tostring(payload.client_action_id or ""))
	self:Request("POST", "/rooms/" .. tostring(self.currentRoomId) .. "/song-selection/cancel", payload, function(ok, decoded, response)
		self:ClearSongSelectionTransition("cancel_response")
		online_flow_trace("song_selection_cancel_response ok=" .. tostring(ok == true)
			.. " status=" .. tostring(response and response.statusCode or "nil")
			.. " hasRoom=" .. tostring(decoded and decoded.room ~= nil)
			.. " phase=" .. tostring(decoded and decoded.room and decoded.room.phase or "nil")
			.. " error=" .. tostring(decoded and decoded.error_code or response and response.errorMessage or "nil"))
		self:TraceOnlineState("song_selection_cancel_response", {
			source = "cancel_song_selection",
			roomSnapshot = decoded and decoded.room or nil,
			ok = ok == true,
			status = response and response.statusCode or "nil",
			error = decoded and decoded.error_code or response and response.errorMessage or "nil",
		})
		if ok and decoded and decoded.room then
			self:RememberSongSelectionCancelled(decoded.room, "song_selection_cancel_response")
			local room = self:ApplyRoomSnapshot(decoded.room, "song_selection_cancelled")
			decoded.room = room or decoded.room
			self.currentSongPayload = nil
			self.currentRoomRoundKey = ""
			self.songLoadedAckKey = ""
			self.songLoadedInFlightKey = ""
			self.songLoadedPendingCallbacks = {}
			self.songAvailabilityInFlightKey = ""
			self.songAvailabilityInFlightCallbacks = {}
			self.songAvailabilityReportedKey = ""
			self.songAvailabilitySuppressedUntil = {}
			self.startScheduleAckKey = ""
			self.startScheduleAckInFlightKey = ""
			self.readyRequestBlockedErrors = {}
			self:ClearActiveGameplayRound("song_selection_cancelled")
			MESSAGEMAN:Broadcast("OnlineLobbyState", self:LobbyStatePayload(decoded.room))
			MESSAGEMAN:Broadcast("OnlineResponseStatus", {
				event = "cancelSongSelection",
				success = true,
				message = "Choix de chanson annule."
			})
		else
			MESSAGEMAN:Broadcast("OnlineResponseStatus", {
				event = "cancelSongSelection",
				success = false,
				message = response_message(response, decoded, "Impossible d'annuler le choix de chanson.")
			})
		end

		if callback then callback(ok, decoded, response) end
	end)
end

function ITGOnline:SelectSongAndMarkLobbyReady(callback)
	if not self.currentRoomId then
		online_flow_trace("song_select_and_ready_failed reason=no_current_room")
		if callback then callback(false, nil, { errorMessage = "No active online room." }) end
		return
	end

	online_flow_trace("song_select_and_ready_begin room=" .. tostring(self.currentRoomId)
		.. " phase=" .. tostring(self.currentRoom and self.currentRoom.phase or "nil")
		.. " playKey=" .. tostring(self.PlayStateKey and self:PlayStateKey() or "nil")
		.. " hasSongPayload=" .. tostring(self.currentSongPayload ~= nil))
	self:SelectSong(function(selectOk, selectDecoded, selectResponse)
		online_flow_trace("song_select_and_ready_select_result ok=" .. tostring(selectOk == true)
			.. " status=" .. tostring(selectResponse and selectResponse.statusCode or "nil")
			.. " hasRoom=" .. tostring(selectDecoded and selectDecoded.room ~= nil)
			.. " phase=" .. tostring(selectDecoded and selectDecoded.room and selectDecoded.room.phase or "nil")
			.. " error=" .. tostring(selectDecoded and selectDecoded.error_code or selectResponse and selectResponse.errorMessage or "nil"))
		if not selectOk then
			if callback then callback(false, selectDecoded, selectResponse) end
			MESSAGEMAN:Broadcast("OnlineResponseStatus", {
				event = "selectSong",
				success = false,
				message = response_message(selectResponse, selectDecoded, "Song selection failed")
			})
			return
		end

		local availabilityAttempts = 0
		local confirmAvailability
		confirmAvailability = function()
			availabilityAttempts = availabilityAttempts + 1
			self:ConfirmSelectedSongAvailability("song_selected", function(availabilityOk, availabilityDecoded, availabilityResponse)
				online_flow_trace("song_select_and_ready_availability_result attempt=" .. tostring(availabilityAttempts)
					.. " ok=" .. tostring(availabilityOk == true)
					.. " status=" .. tostring(availabilityResponse and availabilityResponse.statusCode or "nil")
					.. " hasRoom=" .. tostring(availabilityDecoded and availabilityDecoded.room ~= nil)
					.. " phase=" .. tostring(availabilityDecoded and availabilityDecoded.room and availabilityDecoded.room.phase or "nil")
					.. " error=" .. tostring(availabilityDecoded and availabilityDecoded.error_code or availabilityResponse and availabilityResponse.errorMessage or "nil"))
				if not availabilityOk then
					if availabilityAttempts < 2 and self.FetchRoom then
						online_flow_trace("song_selection_availability_retry attempt=" .. tostring(availabilityAttempts)
							.. " status=" .. tostring(availabilityResponse and availabilityResponse.statusCode or "nil")
							.. " error=" .. tostring(availabilityDecoded and availabilityDecoded.error_code or availabilityResponse and availabilityResponse.error or "nil"))
						self:FetchRoom(self.currentRoomId, function()
							confirmAvailability()
						end)
						return
					end
					if callback then callback(false, availabilityDecoded or selectDecoded, availabilityResponse or selectResponse) end
					MESSAGEMAN:Broadcast("OnlineResponseStatus", {
						event = "songAvailability",
						success = false,
						message = response_message(availabilityResponse, availabilityDecoded, "Could not confirm selected song")
					})
					return
				end

				self:SetReady("lobby_ready", true, function(readyOk, readyDecoded, readyResponse)
					online_flow_trace("song_select_and_ready_ready_result ok=" .. tostring(readyOk == true)
						.. " status=" .. tostring(readyResponse and readyResponse.statusCode or "nil")
						.. " hasRoom=" .. tostring(readyDecoded and readyDecoded.room ~= nil)
						.. " phase=" .. tostring(readyDecoded and readyDecoded.room and readyDecoded.room.phase or "nil")
						.. " error=" .. tostring(readyDecoded and readyDecoded.error_code or readyResponse and readyResponse.errorMessage or "nil"))
					if readyOk and readyDecoded and readyDecoded.room then
						MESSAGEMAN:Broadcast("OnlineLobbyState", self:LobbyStatePayload(self.currentRoom or readyDecoded.room))
					end
					local readyErrorCode = readyDecoded and readyDecoded.error_code
					if not readyOk and (readyErrorCode == "room_members_song_not_confirmed" or readyErrorCode == "room_member_song_not_confirmed") then
						local room = (readyDecoded and readyDecoded.room)
							or (availabilityDecoded and availabilityDecoded.room)
							or (selectDecoded and selectDecoded.room)
							or self.currentRoom
						online_flow_trace("song_selection_ready_pending reason=" .. tostring(readyErrorCode))
						if room then
							MESSAGEMAN:Broadcast("OnlineLobbyState", self:LobbyStatePayload(room))
						end
						if callback then
							callback(true, {
								room = room,
								selection_ready_pending = true,
								error_code = readyErrorCode,
							}, readyResponse or availabilityResponse or selectResponse)
						end
						return
					end
					if callback then callback(readyOk, readyDecoded or availabilityDecoded or selectDecoded, readyResponse or availabilityResponse or selectResponse) end
				end)
			end)
		end
		confirmAvailability()
	end)
end

function ITGOnline:PreviewSong(callback)
	if not self.currentRoomId then
		online_flow_trace("song_preview_failed reason=no_current_room")
		if callback then callback(false, nil, { errorMessage = "No active online room." }) end
		return
	end
	local payload = self:BuildSongPayload()
	if not payload then
		online_flow_trace("song_preview_skipped reason=no_payload"
			.. " room=" .. tostring(self.currentRoomId or "nil")
			.. " phase=" .. tostring(self.currentRoom and self.currentRoom.phase or "nil")
			.. " screen=" .. tostring(self.currentScreenName or "nil"))
		if callback then callback(false, nil, { errorMessage = "No selected song or chart." }) end
		return
	end

	online_flow_trace("song_preview_request_payload room=" .. tostring(self.currentRoomId)
		.. " phase=" .. tostring(self.currentRoom and self.currentRoom.phase or "nil")
		.. " title=" .. tostring(payload.title or "")
		.. " pack=" .. tostring(payload.pack or "")
		.. " chart=" .. tostring(payload.chart_hash or ""):sub(1, 12)
		.. " song=" .. tostring(payload.song_hash or ""):sub(1, 12))
	self:Request("POST", "/rooms/" .. tostring(self.currentRoomId) .. "/song-preview", {
		title = payload.title,
		artist = payload.artist,
		pack = payload.pack,
		folder_name = payload.folder_name,
		difficulty = payload.difficulty,
		meter = payload.meter,
	}, function(ok, decoded, response)
		local statusCode = tonumber(response and response.statusCode) or 0
		local cancelled = ok ~= true and statusCode == 0
		online_flow_trace("song_preview_response_payload ok=" .. tostring(ok == true)
			.. " status=" .. tostring(response and response.statusCode or "nil")
			.. " cancelled=" .. tostring(cancelled == true)
			.. " hasRoom=" .. tostring(decoded and decoded.room ~= nil)
			.. " phase=" .. tostring(decoded and decoded.room and decoded.room.phase or "nil")
			.. " error=" .. tostring(decoded and decoded.error_code or response and response.errorMessage or "nil"))
		if cancelled then
			if callback then callback(true, { cancelled = true }, response) end
			return
		end
		if callback then callback(ok, decoded, response) end
	end, nil, { cancelOnScreenChange = true })
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

function ITGOnline:HasScoredJudgments(judgments)
	if type(judgments) ~= "table" then return false end

	return (tonumber(judgments.fantastic) or 0)
		+ (tonumber(judgments.excellent) or 0)
		+ (tonumber(judgments.great) or 0)
		+ (tonumber(judgments.decent) or 0)
		+ (tonumber(judgments.way_off) or 0)
		+ (tonumber(judgments.miss) or 0) > 0
end

function ITGOnline:CopyServerJudgments(judgments)
	local copy = {}
	for _, key in ipairs({ "fantastic", "excellent", "great", "decent", "way_off", "miss", "mine", "hold_ok", "hold_ng" }) do
		copy[key] = math.max(0, math.floor(tonumber(judgments and judgments[key]) or 0))
	end
	return copy
end

function ITGOnline:ScoreFingerprint(score, combo, maxCombo, failed, judgments)
	local j = judgments or {}
	return table.concat({
		tostring(self.PlayStateKey and self:PlayStateKey() or self.currentRoomId or ""),
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

function ITGOnline:BuildCurrentScoreSnapshot()
	local player = first_enabled_player()
	if not player or not STATSMAN or not STATSMAN.GetCurStageStats then return nil end

	local ok, stats = pcall(function()
		return STATSMAN:GetCurStageStats():GetPlayerStageStats(player)
	end)
	if not ok or not stats then return nil end

	local dancePoints = 0
	local danceOk, danceValue = pcall(function() return stats:GetPercentDancePoints() end)
	if danceOk and tonumber(danceValue) then dancePoints = tonumber(danceValue) end

	local exScore = 0
	if CalculateExScore then
		local exOk, exValue = pcall(function() return CalculateExScore(player) end)
		if exOk and tonumber(exValue) then exScore = tonumber(exValue) end
	end

	local hardExScore = 0
	if CalculateHardExScore then
		local hardExOk, hardExValue = pcall(function() return CalculateHardExScore(player) end)
		if hardExOk and tonumber(hardExValue) then hardExScore = tonumber(hardExValue) end
	end

	local globalOptions = self:CurrentGlobalOptions()
	local scoreMode = tostring(globalOptions.score_mode or "itg")
	local formattedScore = FormatPercentScore and tonumber(FormatPercentScore(dancePoints):sub(1, -2)) or nil
	local scorePercent = math.max(0, math.min(100, formattedScore or (dancePoints * 100)))
	local displayedPercent = scorePercent
	if scoreMode == "hardex" then
		displayedPercent = hardExScore
	elseif scoreMode == "ex" then
		displayedPercent = exScore
	end
	if scoreMode == "itg" and (tonumber(displayedPercent) or 0) <= 0 and scorePercent > 0 then
		displayedPercent = scorePercent
	end
	local combo = 0
	local comboOk, comboValue = pcall(function() return stats:GetCurrentCombo() end)
	if comboOk and tonumber(comboValue) then combo = tonumber(comboValue) end

	if self.debugScoreTrace == true then
		local nowSecond = math.floor(GetTimeSinceStart())
		if nowSecond ~= tonumber(self.lastHudScoreTraceSecond) then
			self.lastHudScoreTraceSecond = nowSecond
			online_trace(string.format(
				"hud-score room=%s round=%s mode=%s displayed=%.3f score=%.3f ex=%.3f hardex=%.3f combo=%d",
				tostring(self.currentRoomId or ""),
				tostring(self.PlayStateKey and self:PlayStateKey() or ""),
				tostring(scoreMode),
				tonumber(displayedPercent) or 0,
				tonumber(scorePercent) or 0,
				tonumber(exScore) or 0,
				tonumber(hardExScore) or 0,
				tonumber(combo) or 0
			))
		end
	end

	return {
		Player = player,
		ScorePercent = scorePercent,
		ExScorePercent = exScore,
		HardExScorePercent = hardExScore,
		DisplayedPercent = displayedPercent,
		ScoreMode = scoreMode,
		Combo = combo,
		scorePercent = scorePercent,
		exScorePercent = exScore,
		hardExScorePercent = hardExScore,
		displayedPercent = displayedPercent,
		scoreMode = scoreMode,
		combo = combo,
	}
end

function ITGOnline:ScoreSnapshotDisplayedPercent(snapshot)
	if type(snapshot) ~= "table" then return nil end
	return tonumber(snapshot.displayedPercent or snapshot.DisplayedPercent)
end

function ITGOnline:BestFinalFailedScoreSnapshot(candidate, fallback)
	if type(candidate) ~= "table" then return fallback end
	if type(fallback) ~= "table" then return candidate end

	local candidateDisplayed = self:ScoreSnapshotDisplayedPercent(candidate) or 0
	local fallbackDisplayed = self:ScoreSnapshotDisplayedPercent(fallback) or 0
	local candidateScore = tonumber(candidate.scorePercent or candidate.ScorePercent) or 0
	local fallbackScore = tonumber(fallback.scorePercent or fallback.ScorePercent) or 0
	local candidateHasProgress = candidateDisplayed > 0 or candidateScore > 0
	local fallbackHasProgress = fallbackDisplayed > 0 or fallbackScore > 0

	if fallbackHasProgress and not candidateHasProgress then
		online_flow_trace("final_failed_snapshot_preserved reason=fresh_zero"
			.. " fallbackDisplayed=" .. tostring(fallbackDisplayed)
			.. " fallbackScore=" .. tostring(fallbackScore)
			.. " candidateDisplayed=" .. tostring(candidateDisplayed)
			.. " candidateScore=" .. tostring(candidateScore))
		return fallback
	end

	if fallbackDisplayed > candidateDisplayed then
		online_flow_trace("final_failed_snapshot_replaced reason=prefer_fresh_candidate"
			.. " fallbackDisplayed=" .. tostring(fallbackDisplayed)
			.. " candidateDisplayed=" .. tostring(candidateDisplayed)
			.. " fallbackScore=" .. tostring(fallbackScore)
			.. " candidateScore=" .. tostring(candidateScore))
	end
	return candidate
end

function ITGOnline:ClearFileHashCache()
	self.fileHashCache = {}
end

function ITGOnline:QueueLiveScore(snapshot)
	if type(snapshot) ~= "table" then
		online_flow_trace("live_score_queue_skipped reason=invalid_snapshot")
		return false
	end
	if not online_single_local_player_allowed() then
		online_flow_trace("ignored_live_score_multiple_local_players")
		return false
	end
	if not self:HasActiveLiveScoreRoom() then
		if self.pendingLiveScoreSnapshot ~= nil or tostring(self.pendingLiveScoreRoundKey or "") ~= "" or self.liveScoreInFlight == true then
			self:StopLiveScoreFlush("queue_without_active_room")
			self.liveScoreInFlight = false
		end
		online_flow_trace_throttled("live_score_queue_no_active_room", 3.0,
			"live_score_queue_skipped reason=no_active_room"
			.. " room=" .. tostring(self.currentRoomId or "nil")
			.. " hasRoom=" .. tostring(self.currentRoom ~= nil)
			.. " phase=" .. tostring(self.currentRoom and self.currentRoom.phase or "nil"))
		return false
	end

	local scorePercent = tonumber(snapshot.scorePercent or snapshot.ScorePercent) or 0
	local exScorePercent = tonumber(snapshot.exScorePercent or snapshot.ExScorePercent) or 0
	local hardExScorePercent = tonumber(snapshot.hardExScorePercent or snapshot.HardExScorePercent) or 0
	local scoreMode = tostring(snapshot.scoreMode or snapshot.ScoreMode or (self:CurrentGlobalOptions().score_mode or "itg"))
	local displayedPercent = tonumber(snapshot.displayedPercent or snapshot.DisplayedPercent)
	if displayedPercent == nil or (scoreMode == "itg" and displayedPercent <= 0 and scorePercent > 0) then
		displayedPercent = scorePercent
	end
	local combo = tonumber(snapshot.combo or snapshot.Combo) or 0
	snapshot = {
		Player = snapshot.Player,
		ScorePercent = scorePercent,
		ExScorePercent = exScorePercent,
		HardExScorePercent = hardExScorePercent,
		DisplayedPercent = displayedPercent,
		ScoreMode = scoreMode,
		Combo = combo,
		scorePercent = scorePercent,
		exScorePercent = exScorePercent,
		hardExScorePercent = hardExScorePercent,
		displayedPercent = displayedPercent,
		scoreMode = scoreMode,
		combo = combo,
	}
	self.lastDisplayedScoreSnapshot = snapshot
	self.lastDisplayedScoreSnapshotAt = GetTimeSinceStart()
	self.pendingLiveScoreRoundKey = self.PlayStateKey and self:PlayStateKey() or tostring(self.currentRoomId or "")
	self.pendingLiveScoreSnapshot = snapshot
	online_flow_trace_throttled("live_score_queue", 1.5,
		"live_score_queue room=" .. tostring(self.currentRoomId or "nil")
		.. " phase=" .. tostring(self.currentRoom and self.currentRoom.phase or "nil")
		.. " roundKey=" .. tostring(self.pendingLiveScoreRoundKey or "")
		.. " score=" .. tostring(scorePercent)
		.. " ex=" .. tostring(exScorePercent)
		.. " hardex=" .. tostring(hardExScorePercent)
		.. " displayed=" .. tostring(displayedPercent)
		.. " mode=" .. tostring(scoreMode)
		.. " combo=" .. tostring(combo))
	return true
end

function ITGOnline:RememberLiveScoreSnapshot(snapshot)
	return self:QueueLiveScore(snapshot)
end

function ITGOnline:QueueLiveScoreTickIfDue(snapshot)
	if not self:HasActiveLiveScoreRoom() then
		if self.pendingLiveScoreSnapshot ~= nil or tostring(self.pendingLiveScoreRoundKey or "") ~= "" or self.liveScoreInFlight == true then
			self:StopLiveScoreFlush("tick_without_active_room")
			self.liveScoreInFlight = false
		end
		return false
	end

	if type(snapshot) == "table" then
		self:RememberLiveScoreSnapshot(snapshot)
	elseif self.pendingLiveScoreSnapshot == nil and self.BuildCurrentScoreSnapshot then
		local currentSnapshot = self:BuildCurrentScoreSnapshot()
		if currentSnapshot then
			self:RememberLiveScoreSnapshot(currentSnapshot)
		end
	end
	return self:HasPendingLiveScore()
end

function ITGOnline:HasPendingLiveScore()
	if not self:HasCurrentOnlineRoom() then return false end
	return self.pendingLiveScoreSnapshot ~= nil or self.liveScoreInFlight == true
end

function ITGOnline:LiveScoreMinIntervalSeconds()
	local normalInterval = math.max(0.50, tonumber(self.liveScoreMinIntervalSeconds) or 0.50)
	local endgameInterval = math.max(0.50, tonumber(self.liveScoreEndgameIntervalSeconds) or normalInterval)
	local endgameWindow = tonumber(self.liveScoreEndgameWindowSeconds) or 6
	if endgameInterval >= normalInterval or endgameWindow <= 0 then
		return normalInterval
	end

	local roomPhase = self:NormalizeRoomPhase(self.currentRoom and self.currentRoom.phase)
	if roomPhase ~= "playing" then
		return normalInterval
	end

	local song = self.CurrentSelectedSongPayload and self:CurrentSelectedSongPayload() or nil
	local duration = tonumber(song and (song.chart_duration_seconds or song.music_length_seconds))
	if duration == nil or duration <= 0 then
		return normalInterval
	end

	local rate = tonumber(song and song.rate) or 1
	rate = math.max(0.25, math.min(3, rate))
	local expectedPlaySeconds = duration / rate

	local player = first_enabled_player()
	if not player or not GAMESTATE or not GAMESTATE.GetPlayerState then
		return normalInterval
	end

	local ok, position = pcall(function()
		local songPositionState = GAMESTATE:GetPlayerState(player):GetSongPosition()
		local visibleOk, visibleSeconds = pcall(function()
			return songPositionState:GetMusicSecondsVisible()
		end)
		if visibleOk and tonumber(visibleSeconds) then
			return tonumber(visibleSeconds)
		end
		return tonumber(songPositionState:GetMusicSeconds())
	end)
	if not ok or tonumber(position) == nil then
		return normalInterval
	end

	local remaining = expectedPlaySeconds - math.max(0, tonumber(position) or 0)
	if remaining >= 0 and remaining <= endgameWindow then
		return endgameInterval
	end

	return normalInterval
end

function ITGOnline:FlushLiveScore()
	if not self:HasCurrentOnlineRoom() then
		online_flow_trace_throttled("live_score_flush_missing_room", 3.0,
			"live_score_flush_skipped reason=missing_room"
			.. " room=" .. tostring(self.currentRoomId or "nil")
			.. " hasRoom=" .. tostring(self.currentRoom ~= nil)
			.. " hadPending=" .. tostring(self.pendingLiveScoreSnapshot ~= nil)
			.. " inFlight=" .. tostring(self.liveScoreInFlight == true))
		self.pendingLiveScoreSnapshot = nil
		self.pendingLiveScoreRoundKey = ""
		self.liveScoreInFlight = false
		return false
	end
	if self.liveScoreInFlight then
		online_flow_trace_throttled("live_score_flush_inflight", 2.0,
			"live_score_flush_skipped reason=inflight room=" .. tostring(self.currentRoomId or "nil")
			.. " roundKey=" .. tostring(self.pendingLiveScoreRoundKey or ""))
		return true
	end

	local now = GetTimeSinceStart()
	local currentScreenName = self:CurrentTopScreenName()
	local roomPhase = self:NormalizeRoomPhase(self.currentRoom and self.currentRoom.phase)
	if not self:IsOnlineGameplayScreen(currentScreenName) then
		self:StopLiveScoreFlush("screen_not_gameplay:" .. tostring(currentScreenName))
		return false
	end
	if roomPhase ~= "starting" and roomPhase ~= "playing" then
		self:StopLiveScoreFlush("phase_not_live:" .. tostring(roomPhase))
		return false
	end

	if now < (tonumber(self.liveScoreNextAttemptAt) or 0) then
		online_flow_trace_throttled("live_score_flush_backoff", 2.0,
			"live_score_flush_skipped reason=backoff remaining="
			.. tostring((tonumber(self.liveScoreNextAttemptAt) or 0) - now)
			.. " room=" .. tostring(self.currentRoomId or "nil"))
		return true
	end

	local minInterval = self:LiveScoreMinIntervalSeconds()
	if now - (tonumber(self.lastScoreSentAt) or 0) < minInterval then
		online_flow_trace_throttled("live_score_flush_interval", 2.0,
			"live_score_flush_skipped reason=min_interval elapsed="
			.. tostring(now - (tonumber(self.lastScoreSentAt) or 0))
			.. " minInterval=" .. tostring(minInterval)
			.. " room=" .. tostring(self.currentRoomId or "nil"))
		return true
	end

	local snapshot = self.pendingLiveScoreSnapshot
	if snapshot == nil then
		online_flow_trace_throttled("live_score_flush_no_snapshot", 3.0,
			"live_score_flush_skipped reason=no_snapshot room=" .. tostring(self.currentRoomId or "nil")
			.. " phase=" .. tostring(self.currentRoom and self.currentRoom.phase or "nil"))
		return false
	end
	if roomPhase == "starting" then
		online_flow_trace_throttled("live_score_flush_starting", 2.0,
			"live_score_flush_wait reason=starting room=" .. tostring(self.currentRoomId or "nil"))
		return true
	end
	if roomPhase ~= "playing" then
		online_flow_trace("live_score_flush_dropped reason=phase_not_playing"
			.. " phase=" .. tostring(roomPhase)
			.. " room=" .. tostring(self.currentRoomId or "nil")
			.. " roundKey=" .. tostring(self.pendingLiveScoreRoundKey or ""))
		self.pendingLiveScoreSnapshot = nil
		self.pendingLiveScoreRoundKey = ""
		return false
	end
	local roundKey, roundKeySource = self:CanonicalGameplayRoundKey("live_score_flush")
	local currentRoundIsValid = roundKey ~= ""
	local pendingRoundIsValid = self.pendingLiveScoreRoundKey ~= ""
	if self.PlayStateKeyIsValid then
		currentRoundIsValid = self:PlayStateKeyIsValid(roundKey)
		pendingRoundIsValid = self:PlayStateKeyIsValid(self.pendingLiveScoreRoundKey)
	end
	if currentRoundIsValid and pendingRoundIsValid and self.pendingLiveScoreRoundKey ~= roundKey then
		online_flow_trace("live_score_flush_dropped reason=round_mismatch"
			.. " pending=" .. tostring(self.pendingLiveScoreRoundKey or "")
			.. " current=" .. tostring(roundKey)
			.. " currentSource=" .. tostring(roundKeySource)
			.. " room=" .. tostring(self.currentRoomId or "nil"))
		self.pendingLiveScoreSnapshot = nil
		self.pendingLiveScoreRoundKey = ""
		return false
	elseif not currentRoundIsValid then
		online_flow_trace_throttled("live_score_flush_invalid_round", 2.0,
			"live_score_flush_wait reason=current_round_invalid"
			.. " current=" .. tostring(roundKey)
			.. " currentSource=" .. tostring(roundKeySource)
			.. " pending=" .. tostring(self.pendingLiveScoreRoundKey or ""))
		return true
	end

	self.pendingLiveScoreSnapshot = nil
	self.pendingLiveScoreRoundKey = ""
	self.liveScoreInFlight = true
	online_flow_trace("live_score_flush_send room=" .. tostring(self.currentRoomId or "nil")
		.. " roundKey=" .. tostring(roundKey)
		.. " roundKeySource=" .. tostring(roundKeySource)
		.. " score=" .. tostring(snapshot.ScorePercent or snapshot.scorePercent or "nil")
		.. " displayed=" .. tostring(snapshot.DisplayedPercent or snapshot.displayedPercent or "nil")
		.. " combo=" .. tostring(snapshot.Combo or snapshot.combo or "nil"))
	self:SendScore(false, false, snapshot, function(ok, decoded, response)
		self.liveScoreInFlight = false
		online_flow_trace("live_score_flush_response ok=" .. tostring(ok == true)
			.. " status=" .. tostring(response and response.statusCode or "nil")
			.. " inFlight=" .. tostring(response and response.inFlight == true)
			.. " hasRoom=" .. tostring(decoded and decoded.room ~= nil)
			.. " phase=" .. tostring(decoded and decoded.room and decoded.room.phase or "nil")
			.. " error=" .. tostring(decoded and decoded.error_code or response and response.errorMessage or "nil"))
		local errorCode = decoded and decoded.error_code or response and response.errorMessage or ""
		local statusCode = tonumber(response and response.statusCode)
		if not ok and tostring(errorCode) == "room_not_playing" then
			self:StopLiveScoreFlush("server_rejected_live_score:" .. tostring(errorCode or "unknown"))
			if self.HandleRoomNotPlayingScoreReject then
				self:HandleRoomNotPlayingScoreReject(false, decoded)
			end
			return
		elseif not ok and statusCode == 422 then
			self:StopLiveScoreFlush("server_rejected_live_score_status_422:" .. tostring(errorCode or "unknown"))
			return
		end
		if not ok and response and response.inFlight then
			self.pendingLiveScoreSnapshot = self.pendingLiveScoreSnapshot or snapshot
			self.pendingLiveScoreRoundKey = self.pendingLiveScoreRoundKey ~= "" and self.pendingLiveScoreRoundKey or roundKey
		end
		if not ok and response and tonumber(response.statusCode) == 429 then
			self.pendingLiveScoreSnapshot = self.pendingLiveScoreSnapshot or snapshot
			self.pendingLiveScoreRoundKey = self.pendingLiveScoreRoundKey ~= "" and self.pendingLiveScoreRoundKey or roundKey
			self.liveScoreNextAttemptAt = GetTimeSinceStart() + 1.5
		elseif not ok and not (response and response.inFlight) then
			self.pendingLiveScoreSnapshot = self.pendingLiveScoreSnapshot or snapshot
			self.pendingLiveScoreRoundKey = self.pendingLiveScoreRoundKey ~= "" and self.pendingLiveScoreRoundKey or roundKey
			self.liveScoreNextAttemptAt = GetTimeSinceStart() + 0.75
		end
	end)
	return true
end

function ITGOnline:HandleRoomNotPlayingScoreReject(final, decoded)
	if type(decoded) == "table" and decoded.room_phase and self.ApplyRoomPhase then
		self:ApplyRoomPhase(decoded.room_phase, "score_reject_room_not_playing")
	end

	self.liveScoreNextAttemptAt = GetTimeSinceStart() + 1.5
	if not final then
		self.pendingLiveScoreSnapshot = nil
		self.pendingLiveScoreRoundKey = ""
	end

	local now = GetTimeSinceStart()
	if now - (tonumber(self.lastRoomNotPlayingScoreRejectAt) or 0) < 0.75 then
		return
	end
	self.lastRoomNotPlayingScoreRejectAt = now

	online_flow_trace_throttled(
		"score_reject_room_not_playing",
		1.0,
		"score_reject_room_not_playing trigger_resync final=" .. tostring(final == true)
	)
	if self.FetchPlayState then
		self:FetchPlayState()
	elseif self.FetchRoom and self.currentRoomId then
		self:FetchRoom(self.currentRoomId)
	end
end

function ITGOnline:CurrentUserHasFinalResult(room)
	room = room or self.currentRoom
	local userId = self.LocalUserId and self:LocalUserId() or tostring(self.user and self.user.id or "")
	if userId == "" then return false end

	local playState = room and room.play_state or {}
	for key, result in pairs(playState.final_results or room and room.final_results or {}) do
		if tostring(key or "") == userId then
			return true
		end
		if type(result) == "table" then
			local user = result.user or result.player or {}
			local resultUserId = tostring(user.id or result.user_id or result.player_id or result.playerId or "")
			if resultUserId == userId then
				return true
			end
		end
	end

	return false
end

function ITGOnline:SendScore(force, final, snapshot, callback, options)
	options = type(options) == "table" and options or {}
	local forceFinalFailed = options.forceFinalFailed == true or (final == true and options.forceFailed == true)
	if forceFinalFailed then
		final = true
		force = true
	end
	local finish = function(ok, decoded, response, meta)
		if callback then callback(ok, decoded, response, meta or {}) end
	end

	online_flow_trace("send_score_begin force=" .. tostring(force == true)
		.. " final=" .. tostring(final == true)
		.. " room=" .. tostring(self.currentRoomId or "nil")
		.. " phase=" .. tostring(self.currentRoom and self.currentRoom.phase or "nil")
		.. " playKey=" .. tostring(self.PlayStateKey and self:PlayStateKey() or "")
		.. " currentRoundKey=" .. tostring(self.currentRoomRoundKey or "")
		.. " activeRoundKey=" .. tostring(self.activeGameplayRoundKey or "")
		.. " hasSnapshot=" .. tostring(snapshot ~= nil)
		.. " forceFailed=" .. tostring(options.forceFailed == true)
		.. " forceFinalFailed=" .. tostring(forceFinalFailed == true)
		.. " hasDisplayedSnapshot=" .. tostring(self.lastDisplayedScoreSnapshot ~= nil)
		.. " displayedSnapshot=" .. tostring(self.lastDisplayedScoreSnapshot and self:ScoreSnapshotDisplayedPercent(self.lastDisplayedScoreSnapshot) or "nil")
		.. " inputSnapshotDisplayed=" .. tostring(snapshot and self:ScoreSnapshotDisplayedPercent(snapshot) or "nil")
		.. " inFlight=" .. tostring(self.scoreInFlightFingerprint ~= nil))
	self:TraceOnlineState("send_score_begin", {
		source = "send_score",
		force = force == true,
		final = final == true,
		forceFailed = options.forceFailed == true,
		forceFinalFailed = forceFinalFailed == true,
		hasSnapshot = snapshot ~= nil,
		inFlight = self.scoreInFlightFingerprint ~= nil,
	})

	if not online_single_local_player_allowed() then
		online_flow_trace("send_score_failed reason=multiple_local_players final=" .. tostring(final == true))
		finish(false, nil, { errorMessage = "Online play supports one local player per client." })
		return
	end
	if not self.currentRoomId then
		online_flow_trace("send_score_failed reason=no_current_room_id final=" .. tostring(final == true))
		finish(false, nil, { errorMessage = "No active online room." })
		return
	end
	if not self.currentRoom then
		online_flow_trace("send_score_failed reason=no_current_room_snapshot room=" .. tostring(self.currentRoomId) .. " final=" .. tostring(final == true))
		finish(false, nil, { errorMessage = "No active online room snapshot." })
		return
	end
	local roomPhase = self:NormalizeRoomPhase(self.currentRoom.phase)
	if self.currentRoom.selected_song and roomPhase ~= "results" then
		self.currentSongPayload = self.currentRoom.selected_song
	end
	local scoreSongPayload = self:CurrentSelectedSongPayload()
	if not scoreSongPayload then
		online_flow_trace("send_score_failed reason=no_selected_song room=" .. tostring(self.currentRoomId)
			.. " phase=" .. tostring(roomPhase)
			.. " final=" .. tostring(final == true))
		finish(false, nil, { errorMessage = "No selected online song." })
		return
	end
	local roundKey = self.CanonicalGameplayRoundKey and self:CanonicalGameplayRoundKey("send_score") or tostring(self.currentRoomId or "")
	local validRoundKey = self.PlayStateKeyIsValid and self:PlayStateKeyIsValid(roundKey)
	online_flow_trace("send_score_context room=" .. tostring(self.currentRoomId or "nil")
		.. " phase=" .. tostring(roomPhase)
		.. " roundKey=" .. tostring(roundKey)
		.. " validRoundKey=" .. tostring(validRoundKey == true)
		.. " selectedAt=" .. tostring(scoreSongPayload.selected_at or scoreSongPayload.selectedAt or "nil")
		.. " songHash=" .. tostring(scoreSongPayload.song_hash or scoreSongPayload.songHash or ""):sub(1, 12)
		.. " chartHash=" .. tostring(scoreSongPayload.chart_hash or scoreSongPayload.chartHash or ""):sub(1, 12))
	if not final
		and validRoundKey
		and (self.onlineGameplayEndedKey == roundKey
			or self.onlineGameplayEvaluationMarkKey == roundKey
			or self.onlineGameplayEvaluationMarkInFlightKey == roundKey)
	then
		online_flow_trace("send_score_skipped reason=local_round_terminal"
			.. " room=" .. tostring(self.currentRoomId)
			.. " phase=" .. tostring(roomPhase)
			.. " roundKey=" .. tostring(roundKey)
			.. " endedKey=" .. tostring(self.onlineGameplayEndedKey or "")
			.. " markKey=" .. tostring(self.onlineGameplayEvaluationMarkKey or "")
			.. " inFlightKey=" .. tostring(self.onlineGameplayEvaluationMarkInFlightKey or ""))
		finish(false, nil, { errorMessage = "Round is already terminal.", room_phase = roomPhase })
		return
	end
	if roomPhase ~= "playing" then
		if final and not forceFinalFailed and (roomPhase == "results" or self:CurrentUserHasFinalResult(self.currentRoom)) then
			if validRoundKey and self.lastFinalScoreKey ~= roundKey then
				self.lastFinalScoreKey = roundKey
			end
			online_flow_trace("final_score_skipped reason=already_terminal_results"
				.. " room=" .. tostring(self.currentRoomId)
				.. " roundKey=" .. tostring(roundKey)
				.. " roomPhase=" .. tostring(roomPhase)
				.. " hasFinalResult=" .. tostring(self:CurrentUserHasFinalResult(self.currentRoom) == true))
			finish(true, nil, nil, { alreadyAccepted = true, roomPhase = roomPhase })
			return
		end
		online_flow_trace("send_score_failed reason=room_not_accepting_score"
			.. " room=" .. tostring(self.currentRoomId)
			.. " phase=" .. tostring(roomPhase)
			.. " final=" .. tostring(final == true)
			.. " roundKey=" .. tostring(roundKey))
		finish(false, nil, { errorMessage = "Room is not accepting score updates.", room_phase = roomPhase })
		return
	end
	local minLiveInterval = self:LiveScoreMinIntervalSeconds()
	if not force and GetTimeSinceStart() - self.lastScoreSentAt < minLiveInterval then
		online_flow_trace("send_score_skipped reason=live_interval"
			.. " room=" .. tostring(self.currentRoomId)
			.. " final=" .. tostring(final == true)
			.. " elapsed=" .. tostring(GetTimeSinceStart() - self.lastScoreSentAt)
			.. " minInterval=" .. tostring(minLiveInterval))
		finish(false, nil, { retryAfter = minLiveInterval })
		return
	end
	if final and validRoundKey and self.lastFinalScoreKey == roundKey then
		online_flow_trace("send_score_skipped reason=final_already_accepted"
			.. " room=" .. tostring(self.currentRoomId)
			.. " roundKey=" .. tostring(roundKey))
		finish(true, nil, nil, { alreadyAccepted = true, roundKey = roundKey })
		return
	end
	if final and validRoundKey and self.lastFinalScoreInFlightKey == roundKey then
		online_flow_trace("send_score_skipped reason=final_in_flight"
			.. " room=" .. tostring(self.currentRoomId)
			.. " roundKey=" .. tostring(roundKey)
			.. " forceFinalFailed=" .. tostring(forceFinalFailed == true))
		finish(false, nil, { retryAfter = 0.5, inFlight = true }, { roundKey = roundKey })
		return
	end
	self.lastScoreSentAt = GetTimeSinceStart()

	local previousDisplayedSnapshot = self.lastDisplayedScoreSnapshot
	if final and self.BuildCurrentScoreSnapshot then
		local freshSnapshot = self:BuildCurrentScoreSnapshot()
		if freshSnapshot ~= nil then
			if forceFinalFailed then
				snapshot = self:BestFinalFailedScoreSnapshot(freshSnapshot, snapshot or previousDisplayedSnapshot)
			else
				snapshot = freshSnapshot
			end
		end
	end
	if snapshot ~= nil and not (final and forceFinalFailed and self:BestFinalFailedScoreSnapshot(snapshot, previousDisplayedSnapshot) == previousDisplayedSnapshot) then
		self.lastDisplayedScoreSnapshot = snapshot
		self.lastDisplayedScoreSnapshotAt = GetTimeSinceStart()
	end
	if snapshot == nil then
		snapshot = self.lastDisplayedScoreSnapshot
	end
	if snapshot == nil and self.BuildCurrentScoreSnapshot then
		snapshot = self:BuildCurrentScoreSnapshot()
	end
	if snapshot == nil and not final then
		online_flow_trace("send_score_failed reason=no_live_snapshot"
			.. " room=" .. tostring(self.currentRoomId)
			.. " roundKey=" .. tostring(roundKey))
		finish(false, nil, { errorMessage = "No score snapshot available." })
		return
	end

		local player = snapshot and snapshot.Player or first_enabled_player()
		local stats = nil
		if player and STATSMAN and STATSMAN.GetCurStageStats then
			local statsOk, statsValue = pcall(function()
				return STATSMAN:GetCurStageStats():GetPlayerStageStats(player)
			end)
			if statsOk then stats = statsValue end
		end

		local dancePoints = (tonumber(snapshot and snapshot.scorePercent) or 0) / 100
		if stats then
			local danceOk, danceValue = pcall(function() return stats:GetPercentDancePoints() end)
			if danceOk and tonumber(danceValue) then dancePoints = tonumber(danceValue) end
		end

		local exScore = tonumber(snapshot and snapshot.exScorePercent) or 0
		if player and CalculateExScore then
			local exOk, exValue = pcall(function() return CalculateExScore(player) end)
			if exOk and tonumber(exValue) then exScore = tonumber(exValue) end
		end

		local hardExScore = tonumber(snapshot and snapshot.hardExScorePercent) or 0
		if player and CalculateHardExScore then
			local hardExOk, hardExValue = pcall(function() return CalculateHardExScore(player) end)
			if hardExOk and tonumber(hardExValue) then hardExScore = tonumber(hardExValue) end
		end

		local songPosition = tonumber(self.lastScoreSongPosition) or 0
		if player and GAMESTATE and GAMESTATE.GetPlayerState then
			local positionOk, positionValue = pcall(function()
				local songPositionState = GAMESTATE:GetPlayerState(player):GetSongPosition()
				local visibleOk, visibleSeconds = pcall(function() return songPositionState:GetMusicSecondsVisible() end)
				if visibleOk and tonumber(visibleSeconds) then return tonumber(visibleSeconds) end
				return tonumber(songPositionState:GetMusicSeconds())
			end)
			if positionOk and tonumber(positionValue) then songPosition = tonumber(positionValue) end
		end
	local positionKey = roundKey
	if self.lastScorePositionKey ~= positionKey then
		self.lastScorePositionKey = positionKey
		self.lastScoreSongPosition = 0
		self.lastAcceptedScoreSongPosition = 0
	end
	songPosition = math.max(0, tonumber(songPosition) or 0)
	local startAtMs = tonumber(self.currentRoom.start_at_ms or "") or iso_utc_milliseconds(self.currentRoom.start_at)
	if startAtMs and self.serverClockOffsetSeconds then
		local rateForClock = tonumber(scoreSongPayload.rate) or 1
		rateForClock = math.max(0.25, math.min(3, rateForClock))
		local estimatedServerNowSeconds = GetTimeSinceStart() + self.serverClockOffsetSeconds
		local estimatedPosition = math.max(0, (estimatedServerNowSeconds - (startAtMs / 1000)) * rateForClock)
		-- Keep client position coherent with server clock to avoid "behind_server_clock" rejects.
		songPosition = math.max(songPosition, math.max(0, estimatedPosition - 0.5))
	end
	local chartDuration = tonumber(scoreSongPayload.chart_duration_seconds) or tonumber(scoreSongPayload.music_length_seconds)
	local lastKnownSongPosition = math.max(
		tonumber(self.lastScoreSongPosition) or 0,
		tonumber(self.lastAcceptedScoreSongPosition) or 0
	)
	if final and chartDuration then
		local rate = tonumber(scoreSongPayload.rate) or 1
		rate = math.max(0.25, math.min(3, rate))
		local playDuration = math.max(0, (tonumber(chartDuration) or songPosition) / rate)
		local allowedFinalPosition = playDuration + 9.95
		local finalPosition = math.max(songPosition, lastKnownSongPosition, playDuration)
		if self.currentRoom.phase ~= "results" then
			finalPosition = math.max(lastKnownSongPosition, math.min(finalPosition, allowedFinalPosition))
		end
		songPosition = finalPosition
	else
		songPosition = math.max(songPosition, lastKnownSongPosition)
	end
	self.lastScoreSongPosition = songPosition
		local maxCombo = tonumber(snapshot and (snapshot.maxCombo or snapshot.MaxCombo or snapshot.combo or snapshot.Combo)) or 0
		if stats then
			local currentComboOk, currentComboValue = pcall(function() return stats:GetCurrentCombo() end)
			if currentComboOk and tonumber(currentComboValue) then maxCombo = tonumber(currentComboValue) end
			for _, methodName in ipairs({ "GetMaxCombo", "MaxCombo" }) do
				local ok, value = pcall(function() return stats[methodName] and stats[methodName](stats) or nil end)
				if ok and tonumber(value) then
					maxCombo = tonumber(value)
					break
				end
			end
		end
		local failedOk, failedValue = stats ~= nil and pcall(function() return stats:GetFailed() end) or false, false
		local failed = failedOk and failedValue == true or false

	local selectedMaxScore = tonumber(scoreSongPayload.max_score) or server_max_score_for_note_count(scoreSongPayload.chart_note_count)
	local itgScorePercent = math.max(0, math.min(100, (tonumber(dancePoints) or 0) * 100))
	local exScorePercent = tonumber(snapshot and snapshot.exScorePercent) or tonumber(exScore) or 0
	local hardExScorePercent = tonumber(snapshot and snapshot.hardExScorePercent) or tonumber(hardExScore) or 0
	local normalizedExScore = math.max(0, math.min(100, exScorePercent)) / 100
	local scoreMode = tostring((self:CurrentGlobalOptions() or {}).score_mode or "itg")
	local displayedScorePercent = tonumber(snapshot and snapshot.displayedPercent)
	if displayedScorePercent == nil then
		if scoreMode == "hardex" then
			displayedScorePercent = hardExScorePercent
		elseif scoreMode == "ex" then
			displayedScorePercent = exScorePercent
		else
			displayedScorePercent = tonumber(snapshot and snapshot.scorePercent)
		end
	end
	if displayedScorePercent == nil then
		if scoreMode == "hardex" then
			displayedScorePercent = hardExScorePercent
		elseif scoreMode == "ex" then
			displayedScorePercent = exScorePercent
		else
			displayedScorePercent = itgScorePercent
		end
	end
	if scoreMode == "itg" and (tonumber(displayedScorePercent) or 0) <= 0 then
		local snapshotScorePercent = tonumber(snapshot and snapshot.scorePercent)
		if snapshotScorePercent and snapshotScorePercent > 0 then
			displayedScorePercent = snapshotScorePercent
		elseif itgScorePercent > 0 then
			displayedScorePercent = itgScorePercent
		end
	end
	if final and forceFinalFailed and (tonumber(displayedScorePercent) or 0) <= 0 and previousDisplayedSnapshot ~= nil then
		local preservedDisplayed = self:ScoreSnapshotDisplayedPercent(previousDisplayedSnapshot)
		if preservedDisplayed ~= nil and preservedDisplayed > 0 then
			online_flow_trace("final_failed_displayed_percent_restored"
				.. " from=" .. tostring(displayedScorePercent)
				.. " to=" .. tostring(preservedDisplayed)
				.. " snapshotScore=" .. tostring(previousDisplayedSnapshot.scorePercent or previousDisplayedSnapshot.ScorePercent or "nil"))
			displayedScorePercent = preservedDisplayed
			snapshot = previousDisplayedSnapshot
		end
	end
	displayedScorePercent = math.max(0, math.min(100, tonumber(displayedScorePercent) or 0))
	local judgments = {}
	if player then
		local judgmentsOk, judgmentsValue = pcall(function() return self:ServerJudgments(player) end)
		if judgmentsOk and type(judgmentsValue) == "table" then judgments = self:CopyServerJudgments(judgmentsValue) end
	end
	local judgmentRoundKey = validRoundKey and roundKey or tostring(self.currentRoomId or "")
	self.lastScoreJudgmentsByRoundKey = self.lastScoreJudgmentsByRoundKey or {}
	if self:HasScoredJudgments(judgments) then
		self.lastScoreJudgmentsByRoundKey[judgmentRoundKey] = self:CopyServerJudgments(judgments)
	elseif final and self.lastScoreJudgmentsByRoundKey[judgmentRoundKey] then
		judgments = self:CopyServerJudgments(self.lastScoreJudgmentsByRoundKey[judgmentRoundKey])
	end
	if final and not self:HasScoredJudgments(judgments) and not forceFinalFailed then
		online_trace("score-final-deferred room=" .. tostring(self.currentRoomId or "")
			.. " round=" .. tostring(roundKey)
			.. " reason=missing_judgments")
		online_flow_trace("send_score_skipped reason=final_missing_judgments"
			.. " room=" .. tostring(self.currentRoomId)
			.. " roundKey=" .. tostring(roundKey))
		finish(false, nil, { retryAfter = 0.5, errorMessage = "Final score judgments are not ready yet." }, { roundKey = roundKey })
		return
	end
	if final and forceFinalFailed and not self:HasScoredJudgments(judgments) then
		online_trace("score-final-failed-without-judgments room=" .. tostring(self.currentRoomId or "")
			.. " round=" .. tostring(roundKey)
			.. " reason=failed_final_must_not_block")
		online_flow_trace("send_score_continue reason=final_failed_missing_judgments_allowed"
			.. " room=" .. tostring(self.currentRoomId)
			.. " roundKey=" .. tostring(roundKey)
			.. " displayedSnapshot=" .. tostring(snapshot and snapshot.displayedPercent or "nil"))
	end
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
	if final and forceFinalFailed and (tonumber(displayedScorePercent) or 0) <= 0 and accuracy > 0 then
		online_flow_trace("final_failed_displayed_percent_kept_zero"
			.. " reason=accuracy_is_not_displayed_score"
			.. " accuracy=" .. tostring(accuracy)
			.. " scoreMode=" .. tostring(scoreMode)
			.. " hasJudgments=" .. tostring(self:HasScoredJudgments(judgments) == true))
	end
		local liveCombo = tonumber(snapshot and snapshot.combo)
		if liveCombo == nil then
			if stats then
				local comboOk, comboValue = pcall(function() return stats:GetCurrentCombo() end)
				liveCombo = comboOk and tonumber(comboValue) or 0
			else
				liveCombo = 0
			end
		end

	-- Always transport the score currently shown to the player in gameplay.
	local outgoingScore = math.max(0, math.floor((displayedScorePercent / 100) * selectedMaxScore + 0.5))
	local outgoingPercent = selectedMaxScore > 0 and ((outgoingScore / selectedMaxScore) * 100) or 0
	if self.debugScoreTrace == true then
		online_trace(string.format(
			"score-trace room=%s mode=%s displayed=%.3f outgoing=%.3f snapshot(score=%.3f ex=%.3f hardex=%.3f shown=%.3f) max=%d combo=%d",
			tostring(self.currentRoomId or ""),
			tostring(scoreMode),
			tonumber(displayedScorePercent) or 0,
			tonumber(outgoingPercent) or 0,
			tonumber(snapshot and snapshot.scorePercent) or -1,
			tonumber(snapshot and snapshot.exScorePercent) or -1,
			tonumber(snapshot and snapshot.hardExScorePercent) or -1,
			tonumber(snapshot and snapshot.displayedPercent) or -1,
			tonumber(selectedMaxScore) or 0,
			tonumber(liveCombo) or 0
		))
	end
	if math.abs((tonumber(displayedScorePercent) or 0) - outgoingPercent) > 0.2 then
		if self.debugScoreTrace == true then
			online_trace(string.format(
				"score-drift local(displayed=%.3f, outgoing=%.3f, max=%d, rawScore=%d)",
				tonumber(displayedScorePercent) or 0,
				tonumber(outgoingPercent) or 0,
				tonumber(selectedMaxScore) or 0,
				tonumber(outgoingScore) or 0
			))
		end
	end
	local outgoingCombo = math.max(0, liveCombo or 0)
	local outgoingMaxCombo = math.max(0, maxCombo or 0)
	local outgoingFailed = (failed or options.forceFailed == true) and true or false
	local scoreFingerprint = self:ScoreFingerprint(outgoingScore, outgoingCombo, outgoingMaxCombo, outgoingFailed, judgments)
	if forceFinalFailed and not outgoingFailed then
		outgoingFailed = true
		scoreFingerprint = self:ScoreFingerprint(outgoingScore, outgoingCombo, outgoingMaxCombo, outgoingFailed, judgments)
	end
	if final and forceFinalFailed then
		online_flow_trace("final_failed_score_available"
			.. " room=" .. tostring(self.currentRoomId)
			.. " roundKey=" .. tostring(roundKey)
			.. " score=" .. tostring(outgoingScore)
			.. " displayedPercent=" .. tostring(displayedScorePercent)
			.. " accuracy=" .. tostring(accuracy)
			.. " songPosition=" .. tostring(songPosition)
			.. " hasJudgments=" .. tostring(self:HasScoredJudgments(judgments) == true)
			.. " snapshotDisplayed=" .. tostring(snapshot and snapshot.displayedPercent or "nil"))
	end
	if final then
		self:TraceFinalScorePayload("before_post", {
			source = "send_score",
			roomId = self.currentRoomId,
			roundKey = roundKey,
			final = true,
			failed = outgoingFailed,
			score = outgoingScore,
			displayedPercent = displayedScorePercent,
			accuracy = accuracy,
			songPosition = songPosition,
			judgments = judgments,
			forceFinalFailed = forceFinalFailed,
			scoreMode = scoreMode,
		})
	end

	if not final then
		if self.scoreInFlightFingerprint then
			self.pendingLiveScoreSnapshot = snapshot
			self.pendingLiveScoreRoundKey = validRoundKey and roundKey or tostring(self.currentRoomId or "")
			online_flow_trace("send_score_skipped reason=live_score_in_flight"
				.. " room=" .. tostring(self.currentRoomId)
				.. " roundKey=" .. tostring(roundKey)
				.. " pendingRoundKey=" .. tostring(self.pendingLiveScoreRoundKey))
			finish(false, nil, { retryAfter = minLiveInterval, inFlight = true })
			return
		end
		if self.lastAcceptedScoreFingerprint and self.lastAcceptedScoreFingerprint == scoreFingerprint then
			online_flow_trace("send_score_skipped reason=duplicate_fingerprint"
				.. " room=" .. tostring(self.currentRoomId)
				.. " roundKey=" .. tostring(roundKey))
			finish(true, nil, nil, { duplicate = true })
			return
		end
	end
	if final and forceFinalFailed and self.scoreInFlightFingerprint then
		online_flow_trace("final_failed_score_supersedes_live_inflight"
			.. " room=" .. tostring(self.currentRoomId)
			.. " roundKey=" .. tostring(roundKey)
			.. " previousFingerprint=" .. tostring(self.scoreInFlightFingerprint))
		self.scoreInFlightFingerprint = nil
		self.pendingLiveScoreSnapshot = nil
		self.pendingLiveScoreRoundKey = ""
	end

	local latestRoomPhase = self:NormalizeRoomPhase(self.currentRoom and self.currentRoom.phase or roomPhase)
	if not final then
		local summary = self.PlayStateSummary and self:PlayStateSummary(self.currentRoom) or nil
		local localPlayState = self.CurrentUserPlayState and tostring(self:CurrentUserPlayState(self.currentRoom) or "") or ""
		local localTerminal = self.IsTerminalPlayState and self:IsTerminalPlayState(localPlayState) or false
		local finalResultsCount = summary and tonumber(summary.finalResults) or 0
		local allTerminal = summary and summary.allTerminal == true
		if latestRoomPhase == "results" or allTerminal or localTerminal then
			if self.StopLiveScoreFlush then
				self:StopLiveScoreFlush("send_score_before_post_terminal_play_state:" .. tostring(latestRoomPhase))
			end
			online_flow_trace("send_score_skipped reason=terminal_play_state_before_post"
				.. " room=" .. tostring(self.currentRoomId)
				.. " roundKey=" .. tostring(roundKey)
				.. " initialPhase=" .. tostring(roomPhase)
				.. " latestPhase=" .. tostring(latestRoomPhase)
				.. " localPlayState=" .. tostring(localPlayState)
				.. " localTerminal=" .. tostring(localTerminal == true)
				.. " allTerminal=" .. tostring(allTerminal == true)
				.. " finalResults=" .. tostring(finalResultsCount)
				.. " final=" .. tostring(final == true))
			finish(false, nil, {
				errorMessage = "Round is already terminal; live score update dropped.",
				room_phase = latestRoomPhase,
				dropped = true,
				terminal = true,
			})
			return
		end
	end
	if final and not forceFinalFailed and (latestRoomPhase == "results" or self:CurrentUserHasFinalResult(self.currentRoom)) then
		if validRoundKey then
			self.lastFinalScoreKey = roundKey
			self.lastFinalScoreInFlightKey = ""
		end
		online_flow_trace("final_score_skipped reason=already_terminal_results"
			.. " room=" .. tostring(self.currentRoomId)
			.. " roundKey=" .. tostring(roundKey)
			.. " roomPhase=" .. tostring(latestRoomPhase)
			.. " hasFinalResult=" .. tostring(self:CurrentUserHasFinalResult(self.currentRoom) == true)
			.. " stage=before_post")
		finish(true, nil, nil, {
			failed = outgoingFailed,
			roundKey = roundKey,
			final = true,
			alreadyAccepted = true,
			roomPhase = latestRoomPhase,
		})
		return
	end
	if not final and latestRoomPhase ~= "playing" then
		if self.StopLiveScoreFlush then
			self:StopLiveScoreFlush("send_score_before_post_phase_not_playing:" .. tostring(latestRoomPhase))
		end
		online_flow_trace("send_score_skipped reason=live_score_phase_not_playing_before_post"
			.. " room=" .. tostring(self.currentRoomId)
			.. " roundKey=" .. tostring(roundKey)
			.. " initialPhase=" .. tostring(roomPhase)
			.. " latestPhase=" .. tostring(latestRoomPhase)
			.. " final=" .. tostring(final == true))
		finish(false, nil, {
			errorMessage = "Room is no longer accepting live score updates.",
			room_phase = latestRoomPhase,
			dropped = true,
		})
		return
	end

	self.scoreInFlightFingerprint = scoreFingerprint
	if final and validRoundKey then
		self.lastFinalScoreInFlightKey = roundKey
	end

	online_flow_trace("send_score_request"
		.. " room=" .. tostring(self.currentRoomId)
		.. " roundKey=" .. tostring(roundKey)
		.. " final=" .. tostring(final == true)
		.. " force=" .. tostring(force == true)
		.. " score=" .. tostring(outgoingScore)
		.. " percent=" .. tostring(outgoingPercent)
		.. " displayedPercent=" .. tostring(displayedScorePercent)
		.. " itgScorePercent=" .. tostring(itgScorePercent)
		.. " exScorePercent=" .. tostring(exScorePercent)
		.. " hardExScorePercent=" .. tostring(hardExScorePercent)
		.. " accuracy=" .. tostring(accuracy)
		.. " combo=" .. tostring(outgoingCombo)
		.. " maxCombo=" .. tostring(outgoingMaxCombo)
		.. " failed=" .. tostring(outgoingFailed)
		.. " forceFinalFailed=" .. tostring(forceFinalFailed == true)
		.. " songPosition=" .. tostring(songPosition)
		.. " scoreMode=" .. tostring(scoreMode)
		.. " snapshotDisplayed=" .. tostring(snapshot and self:ScoreSnapshotDisplayedPercent(snapshot) or "nil")
		.. " previousDisplayed=" .. tostring(previousDisplayedSnapshot and self:ScoreSnapshotDisplayedPercent(previousDisplayedSnapshot) or "nil")
		.. " judgmentsTotal=" .. tostring(self:JudgmentTotal(judgments)))
	if final and forceFinalFailed then
		online_flow_trace("final_failed_score_post"
			.. " room=" .. tostring(self.currentRoomId)
			.. " roundKey=" .. tostring(roundKey)
			.. " score=" .. tostring(outgoingScore)
			.. " displayedPercent=" .. tostring(displayedScorePercent)
			.. " outgoingPercent=" .. tostring(outgoingPercent)
			.. " accuracy=" .. tostring(accuracy)
			.. " songPosition=" .. tostring(songPosition)
			.. " judgments=" .. tostring(self:JudgmentTotal(judgments))
			.. " hadDisplayedSnapshot=" .. tostring(self.lastDisplayedScoreSnapshot ~= nil)
			.. " finalInFlightKey=" .. tostring(self.lastFinalScoreInFlightKey or "")
			.. " scoreInFlight=" .. tostring(self.scoreInFlightFingerprint ~= nil))
	end

	self:Request("POST", "/rooms/" .. tostring(self.currentRoomId) .. "/score", {
		score = outgoingScore,
		score_percent = displayedScorePercent,
		displayed_percent = displayedScorePercent,
		itg_score_percent = itgScorePercent,
		ex_score_percent = exScorePercent,
		hard_ex_score_percent = hardExScorePercent,
		combo = outgoingCombo,
		max_combo = outgoingMaxCombo,
		accuracy = accuracy,
		song_position_seconds = songPosition,
		song_hash = scoreSongPayload.song_hash,
		chart_hash = scoreSongPayload.chart_hash,
		failed = outgoingFailed,
		final = final and true or false,
		score_mode = scoreMode,
		judgments = judgments,
	}, function(ok, decoded, response)
		local errorCode = response_error_code(response, decoded)
		online_flow_trace("send_score_response"
			.. " room=" .. tostring(self.currentRoomId)
			.. " roundKey=" .. tostring(roundKey)
			.. " final=" .. tostring(final == true)
			.. " ok=" .. tostring(ok == true)
			.. " status=" .. tostring(response and response.statusCode or "nil")
			.. " errorCode=" .. tostring(errorCode or "nil")
			.. " roomPhase=" .. tostring(decoded and decoded.room_phase or decoded and decoded.room and decoded.room.phase or "nil")
			.. " responseFinalResults=" .. tostring(decoded and decoded.room and decoded.room.play_state and decoded.room.play_state.final_results and #decoded.room.play_state.final_results or 0)
			.. " responseFinalRowsSummary=" .. online_score_rows_summary(decoded and decoded.room and decoded.room.play_state and decoded.room.play_state.final_results or nil, 8)
			.. " sentScore=" .. tostring(outgoingScore)
			.. " sentDisplayed=" .. tostring(displayedScorePercent)
			.. " sentFailed=" .. tostring(outgoingFailed == true))
		self:TraceOnlineState("send_score_response", {
			source = "send_score",
			roomSnapshot = decoded and decoded.room or self.currentRoom,
			ok = ok == true,
			status = response and response.statusCode or "nil",
			errorCode = errorCode or "nil",
			final = final == true,
			failed = outgoingFailed == true,
			roundKey = roundKey,
			score = outgoingScore,
			displayedPercent = displayedScorePercent,
			scoreMode = scoreMode,
			songPosition = songPosition,
		})
		if self.scoreInFlightFingerprint == scoreFingerprint then
			self.scoreInFlightFingerprint = nil
		end
		if final and self.lastFinalScoreInFlightKey == roundKey then
			self.lastFinalScoreInFlightKey = ""
		end
		if ok and final then
			self.lastFinalScoreKey = roundKey
			self.onlineGameplayEvaluationRetryCount = 0
			self.onlineGameplayEvaluationNextRetryAt = 0
			self.onlineGameplayEvaluationTerminalErrorKey = ""
		end
		if ok then
			self.lastAcceptedScoreFingerprint = scoreFingerprint
			self.lastAcceptedScoreSongPosition = math.max(
				tonumber(self.lastAcceptedScoreSongPosition) or 0,
				tonumber(songPosition) or 0
			)
			if self.debugScoreTrace == true then
				online_trace("score-ack room=" .. tostring(self.currentRoomId or "")
					.. " round=" .. tostring(roundKey)
					.. " final=" .. tostring(final == true)
					.. " sent=" .. tostring(outgoingScore)
					.. " sent_percent=" .. tostring(outgoingPercent)
					.. " displayed_percent=" .. tostring(displayedScorePercent)
					.. " score_mode=" .. tostring(scoreMode)
					.. " combo=" .. tostring(outgoingCombo)
					.. " max_combo=" .. tostring(outgoingMaxCombo)
					.. " failed=" .. tostring(outgoingFailed)
					.. " song_pos=" .. tostring(songPosition)
					.. " status=" .. tostring(response and response.statusCode or "nil"))
			end
		elseif self.debugScoreTrace == true then
			online_trace("score-nack room=" .. tostring(self.currentRoomId or "")
				.. " round=" .. tostring(roundKey)
				.. " final=" .. tostring(final == true)
				.. " sent=" .. tostring(outgoingScore)
				.. " sent_percent=" .. tostring(outgoingPercent)
				.. " displayed_percent=" .. tostring(displayedScorePercent)
				.. " score_mode=" .. tostring(scoreMode)
				.. " status=" .. tostring(response and response.statusCode or "nil")
				.. " message=" .. tostring(response_message(response, decoded, "score failed")))
		end
		if not ok and errorCode == "room_not_playing" and final then
			if validRoundKey then
				self.lastFinalScoreKey = roundKey
			end
			self.onlineGameplayEvaluationRetryCount = 0
			self.onlineGameplayEvaluationNextRetryAt = 0
			self.onlineGameplayEvaluationTerminalErrorKey = ""
			self:HandleRoomNotPlayingScoreReject(final, decoded)
			online_flow_trace("final_score_terminal_race_accepted reason=room_not_playing"
				.. " room=" .. tostring(self.currentRoomId or "")
				.. " roundKey=" .. tostring(roundKey)
				.. " serverPhase=" .. tostring(decoded and decoded.room_phase or "nil"))
			finish(true, decoded, response, {
				failed = outgoingFailed,
				roundKey = roundKey,
				final = true,
				alreadyAccepted = true,
				roomNotPlaying = true,
			})
			return
		end
		if not ok and errorCode == "room_not_playing" then
			self:HandleRoomNotPlayingScoreReject(final, decoded)
		end
		if not ok and final then
			MESSAGEMAN:Broadcast("OnlineResponseStatus", {
				event = final and "finalScore" or "score",
				success = false,
				message = response_message(response, decoded, final and "Final score upload failed" or "Score upload failed")
			})
		end
		finish(ok, decoded, response, {
			failed = outgoingFailed,
			roundKey = roundKey,
			final = final and true or false,
		})
	end)
end

function ITGOnline:SetReady(phase, isReady, callback, refreshedUnknownPhase)
	if not self.currentRoomId then
		online_flow_trace("ready_request_failed reason=no_current_room phase=" .. tostring(phase)
			.. " isReady=" .. tostring(isReady == true))
		if callback then callback(false, nil, { errorMessage = "No active online room." }) end
		return
	end

	local currentPhase = self:NormalizeRoomPhase(self.currentRoom and self.currentRoom.phase)
	local readyRoundKey = self.PlayStateKey and self:PlayStateKey() or ""
	local readySelectionKey = self.CurrentOptionsSelectionKey and self:CurrentOptionsSelectionKey(self.currentRoom) or ""
	local readyScreen = self.currentScreenName or ((SCREENMAN and SCREENMAN:GetTopScreen() and SCREENMAN:GetTopScreen():GetName()) or "nil")
	online_flow_trace("ready_request_begin room=" .. tostring(self.currentRoomId)
		.. " requestedPhase=" .. tostring(phase)
		.. " isReady=" .. tostring(isReady == true)
		.. " currentPhase=" .. tostring(currentPhase)
		.. " screen=" .. tostring(readyScreen)
		.. " playState=" .. tostring(self.CurrentUserPlayState and self:CurrentUserPlayState(self.currentRoom) or "nil")
		.. " roundKey=" .. tostring(readyRoundKey)
		.. " selectionKey=" .. tostring(readySelectionKey)
		.. " refreshedUnknownPhase=" .. tostring(refreshedUnknownPhase == true)
		.. " optimisticConfigKey=" .. tostring(self.optimisticConfigReadyKey or "")
		.. " configInFlight=" .. tostring(self.configReadyRequestInFlight == true))
	if isReady and currentPhase == "unknown" then
		if not refreshedUnknownPhase then
			online_flow_trace("ready_request_refresh room=" .. tostring(self.currentRoomId)
				.. " phase=" .. tostring(phase)
				.. " reason=unknown_room_phase")
			self:EnsureCurrentRoom(function(ok, room, response)
				if ok and room then
					self.currentRoom = room
					self:SetReady(phase, isReady, callback, true)
					return
				end
				if callback then callback(false, nil, response or {
					error_code = "room_phase_unknown",
					errorMessage = "Unable to confirm current room phase before ready request."
				}) end
			end)
			return
		end

		online_flow_trace("ready_request_failed room=" .. tostring(self.currentRoomId)
			.. " phase=" .. tostring(phase)
			.. " reason=unknown_room_phase")
		if callback then callback(false, { room = self.currentRoom }, {
			error_code = "room_phase_unknown",
			errorMessage = "Unable to confirm current room phase before ready request."
		}) end
		return
	end

	if isReady and phase == "lobby_ready" and currentPhase ~= "lobby" and currentPhase ~= "lobby_ready" then
		online_flow_trace("ready_request_skipped room=" .. tostring(self.currentRoomId)
			.. " phase=" .. tostring(phase)
			.. " current_phase=" .. tostring(currentPhase)
			.. " reason=stale_lobby_ready")
		if callback then callback(true, { room = self.currentRoom, stale_ready = true }, nil) end
		return
	end

	if isReady and phase == "lobby_ready" then
		local confirmed, reason = self:CurrentUserConfirmedSelectedSong(self.currentRoom)
		if not confirmed then
			online_flow_trace("ready_request_deferred room=" .. tostring(self.currentRoomId)
				.. " phase=" .. tostring(phase)
				.. " currentPhase=" .. tostring(currentPhase)
				.. " reason=current_member_song_not_confirmed"
				.. " detail=" .. tostring(reason))
			if callback then
				callback(false, {
					room = self.currentRoom,
					error_code = "room_member_song_not_confirmed",
					retry_after = tonumber(self.readyRequestBlockedRetrySeconds) or 2.5,
					deferred = true,
					local_guard = true,
				}, nil)
			end
			return
		end
	end

	if isReady and phase == "config_ready"
		and currentPhase ~= "config"
		and currentPhase ~= "lobby"
		and currentPhase ~= "lobby_ready" then
		online_flow_trace("ready_request_skipped room=" .. tostring(self.currentRoomId)
			.. " phase=" .. tostring(phase)
			.. " current_phase=" .. tostring(currentPhase)
			.. " reason=stale_config_ready")
		if callback then callback(true, { room = self.currentRoom, stale_ready = true }, nil) end
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
		tostring(self:PlayStateKey()),
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
		and self:IsCurrentUserReadyInRoom(self.currentRoom, phase) then
		online_flow_trace("ready_request_replayed_success key=" .. tostring(requestKey)
			.. " age=" .. tostring(nowTs - (tonumber(lastResult.at) or 0))
			.. " phase=" .. tostring(phase)
			.. " currentPhase=" .. tostring(currentPhase))
		if callback then callback(true, { room = self.currentRoom }, nil) end
		return
	end
	local blockedUntil = tonumber(self.readyRequestBlockedErrors[requestKey] or 0) or 0
	if isReady
		and blockedUntil > nowTs
		and self.currentRoom
		and self:NormalizeRoomPhase(self.currentRoom.phase) == currentPhase then
		online_flow_trace_throttled("ready_request_deferred", 10.0,
			"ready_request_deferred room=" .. tostring(self.currentRoomId)
			.. " phase=" .. tostring(phase)
			.. " reason=room_members_song_not_confirmed")
		if callback then
			callback(false, {
				room = self.currentRoom,
				error_code = "room_members_song_not_confirmed",
				retry_after = math.max(0, blockedUntil - nowTs),
				deferred = true,
			}, nil)
		end
		return
	end

	local inflight = self.readyRequestInFlight[requestKey]
	if inflight then
		if callback then
			inflight.callbacks[#inflight.callbacks + 1] = callback
		end
		online_flow_trace("ready_request_join_inflight key=" .. tostring(requestKey)
			.. " callbacks=" .. tostring(inflight.callbacks and #inflight.callbacks or 0)
			.. " phase=" .. tostring(phase)
			.. " currentPhase=" .. tostring(currentPhase))
		return
	end

	local requestRoomId = tostring(self.currentRoomId or "")
	local requestPhase = tostring(currentPhase or "")
	self.readyRequestInFlight[requestKey] = {
		callbacks = callback and { callback } or {},
		roomId = requestRoomId,
		phase = requestPhase,
	}
	online_flow_trace("ready_request_begin key=" .. tostring(requestKey)
		.. " room=" .. tostring(self.currentRoomId)
		.. " requestedPhase=" .. tostring(phase)
		.. " currentPhase=" .. tostring(currentPhase)
		.. " isReady=" .. tostring(isReady == true)
		.. " playKey=" .. tostring(self:PlayStateKey())
		.. " options=" .. tostring(options.speed_mod or "") .. "," .. tostring(options.music_rate_bpm or "") .. "," .. tostring(options.stepchart or ""))
	self:TraceOnlineState("ready_request_begin", {
		source = "set_ready",
		requestedPhase = phase,
		currentPhase = currentPhase,
		isReady = isReady == true,
		requestKey = requestKey,
		optionsSpeed = options.speed_mod or "",
		optionsRate = options.music_rate_bpm or "",
		optionsStepchart = options.stepchart or "",
	})

	if self.debugReadyFlow == true then
		online_trace("[ITGOnline] ready_request room=" .. tostring(self.currentRoomId)
			.. " phase=" .. tostring(phase)
			.. " is_ready=" .. tostring(isReady and true or false)
			.. " play_key=" .. tostring(self:PlayStateKey()))
	end

	self:Request("POST", "/rooms/" .. requestRoomId .. "/ready", payload, function(ok, decoded, response)
		self.readyRequestLastResult[requestKey] = {
			ok = ok and true or false,
			at = GetTimeSinceStart(),
		}
		local pending = self.readyRequestInFlight[requestKey]
		local callbacks = pending and pending.callbacks or {}
		self.readyRequestInFlight[requestKey] = nil
		local liveRoomId = tostring(self.currentRoomId or "")
		local livePhase = self:NormalizeRoomPhase(self.currentRoom and self.currentRoom.phase)
		local errorCode = decoded and decoded.error_code
		local phaseNotAccepting = errorCode == "room_phase_not_accepting"
			or tostring(errorCode or ""):match("^room_phase_not_accepting") ~= nil
		if liveRoomId ~= requestRoomId or (livePhase ~= "unknown" and livePhase ~= requestPhase) then
			online_flow_trace("ready_request_response_dropped reason=context_changed"
				.. " key=" .. tostring(requestKey)
				.. " ok=" .. tostring(ok == true)
				.. " requestRoom=" .. tostring(requestRoomId)
				.. " liveRoom=" .. tostring(liveRoomId)
				.. " requestPhase=" .. tostring(requestPhase)
				.. " livePhase=" .. tostring(livePhase)
				.. " error=" .. tostring(errorCode or response and response.errorMessage or "nil")
				.. " callbacks=" .. tostring(callbacks and #callbacks or 0))
			if phaseNotAccepting and self.currentRoomId then
				online_flow_trace("ready_request_context_changed_reconcile"
					.. " key=" .. tostring(requestKey)
					.. " requestedPhase=" .. tostring(phase)
					.. " requestRoom=" .. tostring(requestRoomId)
					.. " liveRoom=" .. tostring(liveRoomId)
					.. " livePhase=" .. tostring(livePhase)
					.. " error=" .. tostring(errorCode))
				self:FetchCurrentRoomFallback("ready_context_changed_phase_not_accepting", 0)
			end
			for cb in ivalues(callbacks) do
				cb(false, {
					room = self.currentRoom,
					error_code = "ready_context_changed",
					stale = true,
				}, response)
			end
			return
		end
		if ok and decoded and decoded.room then
			self.readyRequestBlockedErrors[requestKey] = nil
			local room = self:ApplyRoomSnapshot(decoded.room, "ready")
			decoded.room = room or decoded.room
			if phase == "config_ready" and isReady then
				self:ClearOnlineOptionsReadyDeadline("config_ready")
			end
		end
		local roomPhase = decoded and decoded.room and decoded.room.phase
		if not ok and isReady and (errorCode == "room_members_song_not_confirmed" or errorCode == "room_member_song_not_confirmed") then
			self.readyRequestBlockedErrors[requestKey] = GetTimeSinceStart() + (tonumber(self.readyRequestBlockedRetrySeconds) or 2.5)
		elseif errorCode ~= "room_members_song_not_confirmed" and errorCode ~= "room_member_song_not_confirmed" then
			self.readyRequestBlockedErrors[requestKey] = nil
		end
		if not ok and phaseNotAccepting then
			online_flow_trace("ready_request_phase_not_accepting_reconcile"
				.. " key=" .. tostring(requestKey)
				.. " requestedPhase=" .. tostring(phase)
				.. " requestRoom=" .. tostring(requestRoomId)
				.. " localPhase=" .. tostring(currentPhase)
				.. " livePhase=" .. tostring(livePhase)
				.. " serverRoomPhase=" .. tostring(roomPhase or "nil")
				.. " status=" .. tostring(response and response.statusCode or "nil"))
			if phase == "config_ready" then
				self:ClearOptimisticConfigReady("ready_phase_not_accepting")
				self:ClearOnlineOptionsReadyDeadline("ready_phase_not_accepting")
				self:ClearPendingConfigReadyIntent("ready_phase_not_accepting")
			end
			self:FetchCurrentRoomFallback("ready_phase_not_accepting", 0)
		end
		if self.debugReadyFlow == true then
			online_trace("[ITGOnline] ready_response room=" .. tostring(self.currentRoomId)
				.. " phase=" .. tostring(phase)
				.. " ok=" .. tostring(ok and true or false)
				.. " room_phase=" .. tostring(roomPhase or "")
				.. " error=" .. tostring(errorCode or (response and response.errorMessage) or ""))
		end
		online_flow_trace("ready_request_response key=" .. tostring(requestKey)
			.. " ok=" .. tostring(ok == true)
			.. " requestedPhase=" .. tostring(phase)
			.. " roomPhase=" .. tostring(roomPhase or "nil")
			.. " members=" .. tostring(decoded and decoded.room and decoded.room.members and #decoded.room.members or 0)
			.. " readyStates=" .. tostring(decoded and decoded.room and decoded.room.ready_states and #decoded.room.ready_states or 0)
			.. " error=" .. tostring(errorCode or response and response.errorMessage or "nil")
			.. " callbacks=" .. tostring(callbacks and #callbacks or 0)
			.. " blockedUntil=" .. tostring(self.readyRequestBlockedErrors[requestKey] or "nil"))
		self:TraceOnlineState("ready_request_response", {
			source = "set_ready",
			roomSnapshot = decoded and decoded.room or self.currentRoom,
			ok = ok == true,
			status = response and response.statusCode or "nil",
			requestedPhase = phase,
			serverPhase = roomPhase or "nil",
			error = errorCode or response and response.errorMessage or "nil",
			callbacks = callbacks and #callbacks or 0,
			requestKey = requestKey,
		})
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
	if self.ReconcileCurrentRoomAfterRealtimeGap then
		self:ReconcileCurrentRoomAfterRealtimeGap("mark_config_ready_before_request", 0.75)
	end
	if not self.currentRoomId then
		online_flow_trace("config_ready_failed reason=no_current_room")
		if callback then callback(false, nil, { errorMessage = "No active online room." }) end
		return
	end

	self:RememberPendingConfigReadyIntent("mark_config_ready")

	local localPhase = self:NormalizeRoomPhase(self.currentRoom and self.currentRoom.phase)
	local requestMode = (localPhase == "config" and self.currentRoom and self.currentRoom.selected_song) and "config" or "pre_config"
	local requestKey = table.concat({
		tostring(self.currentRoomId),
		tostring(self:PlayStateKey()),
		requestMode,
	}, "|")
	local inflight = self.configReadyInFlightByKey[requestKey]
	if inflight then
		if callback then
			inflight.callbacks[#inflight.callbacks + 1] = callback
		end
		online_flow_trace("config_ready_join_inflight key=" .. tostring(requestKey))
		return
	end

	self.configReadyInFlightByKey[requestKey] = {
		callbacks = callback and { callback } or {},
	}
	self.configReadyInFlight = true
	online_flow_trace("config_ready_begin key=" .. tostring(requestKey)
		.. " phase=" .. tostring(localPhase)
		.. " mode=" .. tostring(requestMode))

	local finish = function(ok, decoded, response)
		local pending = self.configReadyInFlightByKey[requestKey]
		self.configReadyInFlightByKey[requestKey] = nil
		self.configReadyInFlight = next(self.configReadyInFlightByKey) ~= nil
		online_flow_trace("config_ready_finish key=" .. tostring(requestKey)
			.. " ok=" .. tostring(ok and true or false)
			.. " status=" .. tostring(response and response.statusCode or "nil")
			.. " hasRoom=" .. tostring(decoded and decoded.room ~= nil)
			.. " phase=" .. tostring(decoded and decoded.room and decoded.room.phase or "nil")
			.. " callbacks=" .. tostring(pending and pending.callbacks and #pending.callbacks or 0)
			.. " error=" .. tostring((decoded and decoded.error_code) or (response and response.errorMessage) or ""))
		if not ok then
			self:ClearOptimisticConfigReady("config_ready_finish_failed")
		elseif requestMode == "config" then
			self:ClearPendingConfigReadyIntent("config_ready_finish_ok")
		end
		if requestMode ~= "config" and self:NormalizeRoomPhase(self.currentRoom and self.currentRoom.phase) == "config" then
			self:MaybeReplayPendingConfigReady("config_ready_finish_" .. tostring(requestMode))
		end
		local callbacks = pending and pending.callbacks or {}
		for cb in ivalues(callbacks) do
			cb(ok, decoded, response)
		end
	end

	local directConfigReady = function()
		online_flow_trace("config_ready_path direct_config key=" .. tostring(requestKey)
			.. " phase=" .. tostring(localPhase)
			.. " hasSelectedSong=" .. tostring(self.currentRoom and self.currentRoom.selected_song ~= nil))
		self:SetReady("config_ready", true, function(ok, decoded, response)
			if ok and decoded and decoded.room then
				MESSAGEMAN:Broadcast("OnlineLobbyState", self:LobbyStatePayload(self.currentRoom or decoded.room))
			end
			finish(ok, decoded, response)
		end)
	end

	local finishConfigReady = function()
		online_flow_trace("config_ready_path confirm_availability_then_config key=" .. tostring(requestKey)
			.. " phase=" .. tostring(localPhase))
		self:ConfirmSelectedSongAvailability("options_ready", function(availabilityOk, availabilityDecoded, availabilityResponse)
			online_flow_trace("config_ready_availability_result key=" .. tostring(requestKey)
				.. " ok=" .. tostring(availabilityOk == true)
				.. " status=" .. tostring(availabilityResponse and availabilityResponse.statusCode or "nil")
				.. " error=" .. tostring(availabilityDecoded and availabilityDecoded.error_code or availabilityResponse and availabilityResponse.errorMessage or "nil"))
			if not availabilityOk then
				finish(false, availabilityDecoded, availabilityResponse)
				return
			end

			self:SetReady("config_ready", true, function(ok, decoded, response)
				if ok and decoded and decoded.room then
					MESSAGEMAN:Broadcast("OnlineLobbyState", self:LobbyStatePayload(self.currentRoom or decoded.room))
				end
				finish(ok, decoded or availabilityDecoded, response or availabilityResponse)
			end)
		end)
	end

	if localPhase == "config" and self.currentRoom and self.currentRoom.selected_song then
		directConfigReady()
		return
	end

	self:FetchRoom(self.currentRoomId, function(fetchOk, fetchDecoded, fetchResponse)
		online_flow_trace("config_ready_fetch_room_result key=" .. tostring(requestKey)
			.. " ok=" .. tostring(fetchOk == true)
			.. " status=" .. tostring(fetchResponse and fetchResponse.statusCode or "nil")
			.. " hasRoom=" .. tostring(fetchDecoded and fetchDecoded.room ~= nil)
			.. " phase=" .. tostring(fetchDecoded and fetchDecoded.room and fetchDecoded.room.phase or "nil")
			.. " hasSelectedSong=" .. tostring(fetchDecoded and fetchDecoded.room and fetchDecoded.room.selected_song ~= nil))
		if not fetchOk or not fetchDecoded or not fetchDecoded.room then
			finish(false, fetchDecoded, fetchResponse)
			return
		end

		local room = fetchDecoded.room
		if not room.selected_song then
			local isManager = self:IsCurrentUserRoomManager(room)
			if isManager then
				online_flow_trace("config_ready_path select_song_and_mark_lobby_ready key=" .. tostring(requestKey)
					.. " isManager=true")
				self:SelectSongAndMarkLobbyReady(finish)
				return
			end

			online_flow_trace("config_ready_waiting_for_manager_selection key=" .. tostring(requestKey)
				.. " phase=" .. tostring(room.phase or "nil")
				.. " isManager=false"
				.. " room=" .. tostring(room.id or self.currentRoomId or "nil"))
			if self.FetchCurrentRoomFallback then
				self:FetchCurrentRoomFallback("config_ready_missing_song_non_manager", 0.25)
			end
			finish(false, fetchDecoded, {
				error_code = "missing_selected_song_non_manager",
				errorMessage = "Waiting for manager song selection.",
				retryAfter = 0.5,
				deferred = true,
			})
			return
		end

			if room.phase == "starting" or room.phase == "playing" or room.phase == "results" then
				online_flow_trace("config_ready_path already_started key=" .. tostring(requestKey)
					.. " phase=" .. tostring(room.phase))
				if type(fetchDecoded) == "table" then
					fetchDecoded.stale_ready = true
					fetchDecoded.already_started = true
					fetchDecoded.ready_result = "already_started"
				end
				finish(true, fetchDecoded, fetchResponse)
		elseif room.phase == "config" then
			finishConfigReady()
		elseif room.phase == "lobby" or room.phase == "lobby_ready" then
			online_flow_trace("config_ready_path lobby_ready_after_availability key=" .. tostring(requestKey)
				.. " phase=" .. tostring(room.phase))
			self:ConfirmSelectedSongAvailability("options_ready", function(availabilityOk, availabilityDecoded, availabilityResponse)
				online_flow_trace("config_ready_lobby_availability_result key=" .. tostring(requestKey)
					.. " ok=" .. tostring(availabilityOk == true)
					.. " status=" .. tostring(availabilityResponse and availabilityResponse.statusCode or "nil")
					.. " error=" .. tostring(availabilityDecoded and availabilityDecoded.error_code or availabilityResponse and availabilityResponse.errorMessage or "nil"))
				if not availabilityOk then
					finish(false, availabilityDecoded or fetchDecoded, availabilityResponse)
					return
				end

				online_flow_trace("config_ready_queued_until_config key=" .. tostring(requestKey)
					.. " phase=" .. tostring(room.phase)
					.. " pendingKey=" .. tostring(self.pendingConfigReadyIntentKey or ""))
				self:FetchCurrentRoomFallback("config_ready_waiting_for_config_phase", 0.25)
				finish(false, availabilityDecoded or fetchDecoded, {
					errorMessage = "Waiting for room config phase.",
					retryAfter = 0.5,
					deferred = true,
				})
			end)
		else
			online_flow_trace("config_ready_path_unknown_phase key=" .. tostring(requestKey)
				.. " phase=" .. tostring(room.phase or "nil"))
			finish(false, fetchDecoded, { errorMessage = "Room is not accepting ready state." })
		end
	end)
end

function ITGOnline:StartRoom(callback)
	if not self.currentRoomId then
		online_flow_trace("start_room_failed reason=no_current_room")
		if callback then callback(false, nil, { errorMessage = "No active online room." }) end
		return
	end
	online_flow_trace("start_room_request room=" .. tostring(self.currentRoomId)
		.. " phase=" .. tostring(self.currentRoom and self.currentRoom.phase or "nil")
		.. " members=" .. tostring(self.currentRoom and self.currentRoom.members and #self.currentRoom.members or 0)
		.. " readyStates=" .. tostring(self.currentRoom and self.currentRoom.ready_states and #self.currentRoom.ready_states or 0)
		.. " hasSelectedSong=" .. tostring(self.currentRoom and self.currentRoom.selected_song ~= nil)
		.. " playKey=" .. tostring(self.PlayStateKey and self:PlayStateKey() or "nil"))
	self:TraceOnlineState("start_room_request", {
		source = "start_room",
		members = self.currentRoom and self.currentRoom.members and #self.currentRoom.members or 0,
		readyStates = self.currentRoom and self.currentRoom.ready_states and #self.currentRoom.ready_states or 0,
		hasSelectedSong = self.currentRoom and self.currentRoom.selected_song ~= nil,
	})
	self:Request("POST", "/rooms/" .. tostring(self.currentRoomId) .. "/start", {}, function(ok, decoded, response)
		online_flow_trace("start_room_response ok=" .. tostring(ok == true)
			.. " status=" .. tostring(response and response.statusCode or "nil")
			.. " hasRoom=" .. tostring(decoded and decoded.room ~= nil)
			.. " phase=" .. tostring(decoded and decoded.room and decoded.room.phase or "nil")
			.. " scheduledStart=" .. tostring(decoded and decoded.room and (decoded.room.scheduled_start_at or decoded.room.scheduled_start_ms) or "nil")
			.. " error=" .. tostring(decoded and decoded.error_code or response and response.errorMessage or "nil"))
		self:TraceOnlineState("start_room_response", {
			source = "start_room",
			roomSnapshot = decoded and decoded.room or nil,
			ok = ok == true,
			status = response and response.statusCode or "nil",
			error = decoded and decoded.error_code or response and response.errorMessage or "nil",
			scheduledStart = decoded and decoded.room and (decoded.room.scheduled_start_at or decoded.room.scheduled_start_ms) or "nil",
		})
		if ok and decoded and decoded.room then
			local room = self:ApplyRoomSnapshot(decoded.room, "start_room")
			decoded.room = room or decoded.room
			self.startScheduleAckKey = ""
			self.startScheduleAckInFlightKey = ""
		end
		if callback then callback(ok, decoded, response) end
	end)
end

function ITGOnline:UpdatePlayStateFromResponse(decoded)
	if decoded and decoded.play_state and self.currentRoom then
		local versionKey = tostring(self.currentRoomId or self.currentRoom.id or "")
		local incomingVersion = tonumber(decoded.play_state_version_ms or (decoded.play_state and decoded.play_state.version_ms) or decoded.version_ms) or 0
		local previousVersion = tonumber(self.lastPlayStateVersionByRoomId[versionKey]) or 0
		if incomingVersion > 0 then
			if incomingVersion < previousVersion then
				online_flow_trace("ignored_stale_play_state_response version=" .. tostring(incomingVersion)
					.. " previous=" .. tostring(previousVersion))
				return
			end
			self.lastPlayStateVersionByRoomId[versionKey] = incomingVersion
		elseif previousVersion > 0 then
			online_flow_trace("ignored_unversioned_play_state_response previous=" .. tostring(previousVersion))
			if self.FetchRoom then
				local now = GetTimeSinceStart()
				if now - (tonumber(self.lastUnversionedPlayStateFetchAt) or 0) >= 1.0 then
					self.lastUnversionedPlayStateFetchAt = now
					self:FetchRoom(self.currentRoomId)
				end
			end
			return
		end
		local previousPhase = self.currentRoom.phase
		self.currentRoom.play_state = decoded.play_state
		local rawResponsePhase = decoded.room_phase
		local hasResponsePhase = rawResponsePhase ~= nil and tostring(rawResponsePhase or "") ~= ""
		local responsePhase = hasResponsePhase and self:KnownRoomPhaseOrNil(rawResponsePhase) or nil
		local responsePhaseLabel = "unchanged"
		if responsePhase then
			responsePhaseLabel = responsePhase
			self:ApplyRoomPhase(responsePhase, "play_state_response")
			if responsePhase == "lobby" then
				if self:NormalizeRoomPhase(self.currentRoom.phase) ~= "lobby" then
					online_flow_trace("play_state_response_force_lobby_reset previousPhase=" .. tostring(self.currentRoom.phase))
					self.currentRoom.phase = "lobby"
				end
				self:ClearSelectedSongForLobby("play_state_response", false)
			end
		elseif hasResponsePhase then
			responsePhaseLabel = "ignored:" .. tostring(rawResponsePhase)
			online_flow_trace("ignored_invalid_play_state_response_phase previousPhase=" .. tostring(previousPhase)
				.. " incoming=" .. tostring(rawResponsePhase)
				.. " version=" .. tostring(incomingVersion))
		end
		if not responsePhase and self.FetchRoom then
			local summary = self:PlayStateSummary(self.currentRoom)
			local needsAuthoritativePhase = summary
				and summary.players > 0
				and summary.allTerminal == true
				and (self:NormalizeRoomPhase(previousPhase) == "playing" or self:NormalizeRoomPhase(previousPhase) == "starting")

			if needsAuthoritativePhase then
				local now = GetTimeSinceStart()
				if now - (tonumber(self.lastMissingPhasePlayStateFetchAt) or 0) >= 0.75 then
					self.lastMissingPhasePlayStateFetchAt = now
					online_flow_trace("play_state_response_missing_phase_fetch previousPhase=" .. tostring(previousPhase)
						.. " version=" .. tostring(incomingVersion)
						.. " terminal=" .. tostring(summary.terminal)
						.. " players=" .. tostring(summary.players))
					self:FetchRoom(self.currentRoomId)
				end
			end
		end
		online_flow_trace("play_state_response previousPhase=" .. tostring(previousPhase)
			.. " responsePhase=" .. tostring(responsePhaseLabel)
			.. " currentPhase=" .. tostring(self.currentRoom.phase))
		self:ApplyPlayStateSnapshot(decoded.play_state, "play_state_response", incomingVersion)
		if self.EnforceRoomPhaseScreen then
			self:EnforceRoomPhaseScreen()
		end
	end
end

function ITGOnline:ApplyPlayStateSnapshot(playState, source, versionMs, options)
	options = type(options) == "table" and options or {}
	if type(playState) ~= "table" or not self.currentRoom then
		online_flow_trace("play_state_snapshot_skipped source=" .. tostring(source or "unknown")
			.. " reason=missing_context"
			.. " hasPlayState=" .. tostring(type(playState) == "table")
			.. " hasRoom=" .. tostring(self.currentRoom ~= nil))
		return false
	end

	local roomId = tostring(self.currentRoomId or self.currentRoom.id or "")
	local incomingVersion = tonumber(versionMs or playState.version_ms) or 0
	local previousVersion = tonumber(self.lastPlayStateVersionByRoomId[roomId]) or 0
	if incomingVersion > 0 and incomingVersion < previousVersion then
		online_flow_trace("play_state_snapshot_ignored source=" .. tostring(source or "unknown")
			.. " reason=stale_version"
			.. " room=" .. tostring(roomId)
			.. " version=" .. tostring(incomingVersion)
			.. " previous=" .. tostring(previousVersion))
		return false
	end

	if incomingVersion > 0 then
		self.lastPlayStateVersionByRoomId[roomId] = incomingVersion
	end
	self.currentRoom.play_state = playState
	if roomId ~= "" then
		self.currentRoomPlayStateByRoomId[roomId] = {
			play_state = playState,
			version_ms = incomingVersion,
			applied_at = GetTimeSinceStart(),
			source = tostring(source or "unknown"),
		}
	end
	online_flow_trace("play_state_snapshot_applied source=" .. tostring(source or "unknown")
		.. " room=" .. tostring(roomId)
		.. " version=" .. tostring(incomingVersion)
		.. " previous=" .. tostring(previousVersion)
		.. " sessions=" .. tostring(playState.sessions and #playState.sessions or 0)
		.. " finalResults=" .. tostring(playState.final_results and #playState.final_results or 0)
		.. " finalRowsSummary=" .. online_score_rows_summary(playState.final_results, 8))
	self:TraceOnlineState("play_state_snapshot_applied", {
		source = source or "unknown",
		roomSnapshot = self.currentRoom,
		version = incomingVersion,
		previousVersion = previousVersion,
	})
	if options.suppressLobbyBroadcast == true then
		online_flow_trace("play_state_snapshot_lobby_broadcast_suppressed source=" .. tostring(source or "unknown")
			.. " room=" .. tostring(roomId)
			.. " version=" .. tostring(incomingVersion))
	else
		MESSAGEMAN:Broadcast("OnlineLobbyState", self:LobbyStatePayload(self.currentRoom))
	end
	MESSAGEMAN:Broadcast("ITGOnlinePlayStateUpdated", playState)
	return true
end

function ITGOnline:ReplayCurrentPlayState(source)
	if not self.currentRoom then return false end
	local roomId = tostring(self.currentRoomId or self.currentRoom.id or "")
	local cached = roomId ~= "" and self.currentRoomPlayStateByRoomId and self.currentRoomPlayStateByRoomId[roomId] or nil
	local playState = self.currentRoom.play_state or (cached and cached.play_state) or nil
	if type(playState) ~= "table" then
		online_flow_trace("play_state_replay_skipped source=" .. tostring(source or "unknown")
			.. " room=" .. tostring(roomId)
			.. " reason=no_cached_play_state")
		return false
	end
	online_flow_trace("play_state_replay source=" .. tostring(source or "unknown")
		.. " room=" .. tostring(roomId)
		.. " cachedSource=" .. tostring(cached and cached.source or "current_room")
		.. " version=" .. tostring(cached and cached.version_ms or playState.version_ms or "nil")
		.. " sessions=" .. tostring(playState.sessions and #playState.sessions or 0)
		.. " finalResults=" .. tostring(playState.final_results and #playState.final_results or 0)
		.. " finalRowsSummary=" .. online_score_rows_summary(playState.final_results, 8))
	return self:ApplyPlayStateSnapshot(playState, "replay:" .. tostring(source or "unknown"), cached and cached.version_ms or playState.version_ms)
end

function ITGOnline:BroadcastCurrentRoomState(source)
	if not self.currentRoom then return end
	if online_flow_trace then
		local localState = self:LocalPlayState()
		online_flow_trace("broadcast_room_state source=" .. tostring(source or "unknown")
			.. " phase=" .. tostring(self.currentRoom.phase)
			.. " localPlayState=" .. tostring(localState))
	end
	if self.currentRoom.play_state then
		self:ApplyPlayStateSnapshot(self.currentRoom.play_state, "broadcast_room_state:" .. tostring(source or "unknown"))
	else
		MESSAGEMAN:Broadcast("OnlineLobbyState", self:LobbyStatePayload(self.currentRoom))
	end
end

function ITGOnline:ResetLocalPlayStateForLobby(source)
	if not self.currentRoom then return false end

	local roomId = tostring(self.currentRoomId or self.currentRoom.id or "")
	local previousPlayState = type(self.currentRoom.play_state) == "table" and self.currentRoom.play_state or {}
	local previousSessions = type(previousPlayState.sessions) == "table" and #previousPlayState.sessions or 0
	local previousFinalResults = type(previousPlayState.final_results) == "table" and #previousPlayState.final_results or 0
	local previousSubmittedScores = type(previousPlayState.submitted_scores) == "table" and #previousPlayState.submitted_scores or 0
	local sessions = {}

	for _, member in ipairs(self.currentRoom.members or {}) do
		local user = type(member.user) == "table" and member.user or {}
		local userId = member.user_id or member.userId or user.id or member.id
		if userId ~= nil then
			sessions[#sessions + 1] = {
				user_id = userId,
				user = user,
				state = "pending",
			}
		end
	end

	self.currentRoom.play_state = {
		state = "pending",
		sessions = sessions,
		submitted_scores = {},
		final_results = {},
		live_scores = {},
		top_scores = {},
	}

	if roomId ~= "" then
		self.currentRoomPlayStateByRoomId = self.currentRoomPlayStateByRoomId or {}
		self.currentRoomPlayStateByRoomId[roomId] = {
			play_state = self.currentRoom.play_state,
			version_ms = 0,
			applied_at = GetTimeSinceStart(),
			source = tostring(source or "local_lobby_reset"),
		}
	end

	if self.StopLiveScoreFlush then
		self:StopLiveScoreFlush("local_lobby_play_state_reset:" .. tostring(source or "unknown"))
	end

	online_flow_trace("local_lobby_play_state_reset"
		.. " source=" .. tostring(source or "unknown")
		.. " room=" .. tostring(roomId)
		.. " previousSessions=" .. tostring(previousSessions)
		.. " nextSessions=" .. tostring(#sessions)
		.. " previousFinalResults=" .. tostring(previousFinalResults)
		.. " previousSubmittedScores=" .. tostring(previousSubmittedScores))
	return true
end

function ITGOnline:ShouldBlockEvaluationAutoAdvance()
	if not self.currentRoomId or self.onlineEvaluationExitRequested then return false end
	local phase = self.currentRoom and self:NormalizeRoomPhase(self.currentRoom.phase) or ""
	if phase ~= "playing" and phase ~= "results" then
		return false
	end

	local summary = self:PlayStateSummary(self.currentRoom)
	if summary and phase == "results" and summary.finalResultsReady then
		online_flow_trace("evaluation_auto_advance_unblocked final_results_ready=true phase=" .. tostring(phase)
			.. " players=" .. tostring(summary.players)
			.. " terminal=" .. tostring(summary.terminal)
			.. " finalResults=" .. tostring(summary.finalResults))
		return false
	end

	if self.FetchPlayState then
		local now = GetTimeSinceStart()
		if not self.onlineEvaluationBlockedFetchAt or (now - self.onlineEvaluationBlockedFetchAt) >= 0.75 then
			self.onlineEvaluationBlockedFetchAt = now
			self:FetchPlayState()
		end
	end

	return true
end

function ITGOnline:LocalUserId()
	return tostring(self.user and self.user.id or "")
end

function ITGOnline:LocalPlayState()
	local userId = self:LocalUserId()
	if userId == "" or not self.currentRoom or not self.currentRoom.play_state then return "" end
	for session in ivalues(self.currentRoom.play_state.sessions or {}) do
		local user = session.user or {}
		local sessionUserId = tostring(user.id or session.user_id or "")
		if sessionUserId == userId then
			return tostring(session.state or "")
		end
	end
	return ""
end

function ITGOnline:ApplyLocalPlayState(state, source)
	local userId = self:LocalUserId()
	if userId == "" or not self.currentRoom then return false end

	self.currentRoom.play_state = self.currentRoom.play_state or {}
	self.currentRoom.play_state.sessions = self.currentRoom.play_state.sessions or {}

	local target = nil
	local created = false
	for session in ivalues(self.currentRoom.play_state.sessions) do
		local user = session.user or {}
		local sessionUserId = tostring(user.id or session.user_id or "")
		if sessionUserId == userId then
			target = session
			break
		end
	end

	if not target then
		target = {
			user_id = tonumber(userId) or userId,
			user = {
				id = tonumber(userId) or userId,
				name = user_display_name(self.user, "Player"),
			},
		}
		table.insert(self.currentRoom.play_state.sessions, target)
		created = true
	end

	local nextState = tostring(state or "")
	local changed = created or tostring(target.state or "") ~= nextState
	target.state = nextState
	if state == "finished" then
		changed = changed or target.finished_at == nil
		target.finished_at = target.finished_at or "local"
	elseif state == "failed" then
		changed = changed or target.failed_at == nil
		target.failed_at = target.failed_at or "local"
	elseif state == "returned_to_lobby" then
		changed = changed or target.returned_to_lobby_at == nil
		target.returned_to_lobby_at = target.returned_to_lobby_at or "local"
	end

	if changed then
		self:BroadcastCurrentRoomState(source or "local_play_state")
	end
	return true
end

function ITGOnline:CurrentSelectedSongPayload()
	local roomSong = self.currentRoom and self.currentRoom.selected_song or nil
	local phase = self:NormalizeRoomPhase(self.currentRoom and self.currentRoom.phase or nil)
	local screen = SCREENMAN:GetTopScreen()
	local screenName = screen and screen:GetName() or tostring(self.currentScreenName or "")
	if self:IsOnlineGameplayScreen(screenName)
		and self.activeGameplaySongPayload
		and self.PlayStateKeyIsValid
		and self:PlayStateKeyIsValid(self.activeGameplayRoundKey)
	then
		return self.activeGameplaySongPayload
	end
	if roomSong and roomSong.chart_hash then
		if phase == "results" then
			return self.lastResultSongPayload or roomSong
		end
		return roomSong
	end
	if phase == "results" then
		return self.lastResultSongPayload or self.currentSongPayload
	end
	if phase == "lobby" or phase == "lobby_ready" or phase == "config" then
		return nil
	end
	return self.currentSongPayload
end

function ITGOnline:PlayStateKeyIsValid(key)
	local roomId, sessionId, songHash, chartHash, selectedAt = tostring(key or ""):match("^([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)$")
	return roomId ~= nil and roomId ~= ""
		and chartHash ~= nil and chartHash ~= ""
		and (
			(sessionId ~= nil and sessionId ~= "")
			or (songHash ~= nil and songHash ~= "")
			or (selectedAt ~= nil and selectedAt ~= "")
		)
end

function ITGOnline:PlayStateKey()
	local song = self:CurrentSelectedSongPayload()
	local selectedAt = song and (song.selected_at or song.selectedAt) or ""
	return tostring(self.currentRoomId or "") .. "|"
		.. tostring(song and (song.game_session_id or song.session_id or song.round_id or song.selected_song_id) or "") .. "|"
		.. tostring(song and (song.song_hash or song.songHash) or "") .. "|"
		.. tostring(song and song.chart_hash or "") .. "|"
		.. tostring(selectedAt or "")
end

function ITGOnline:MarkPlayEntered(callback)
	if not self.currentRoomId then
		if callback then callback(false, nil, { errorMessage = "No active online room." }) end
		return
	end
	local key = self:PlayStateKey()
	local topScreen = SCREENMAN and SCREENMAN:GetTopScreen() or nil
	local screenName = topScreen and topScreen:GetName() or tostring(self.currentScreenName or "NoScreen")
	local roomPhase = self:NormalizeRoomPhase(self.currentRoom and self.currentRoom.phase or nil)
	if not self:IsOnlineGameplayScreen(screenName) then
		online_flow_trace("mark_play_entered_skipped reason=not_gameplay_screen"
			.. " screen=" .. tostring(screenName)
			.. " room=" .. tostring(self.currentRoomId)
			.. " phase=" .. tostring(roomPhase)
			.. " key=" .. tostring(key)
			.. " enteredKey=" .. tostring(self.onlineGameplayEnteredKey or "")
			.. " returnedKey=" .. tostring(self.onlineGameplayReturnedKey or ""))
		if callback then callback(false, nil, { errorMessage = "Play entered ignored outside gameplay." }) end
		return
	end
	if roomPhase ~= "starting" and roomPhase ~= "playing" then
		online_flow_trace("mark_play_entered_skipped reason=phase_not_live"
			.. " screen=" .. tostring(screenName)
			.. " room=" .. tostring(self.currentRoomId)
			.. " phase=" .. tostring(roomPhase)
			.. " key=" .. tostring(key))
		if callback then callback(false, nil, { errorMessage = "Play entered ignored for non-live room phase." }) end
		return
	end
	if not self:PlayStateKeyIsValid(key) then
		online_flow_trace("mark_play_entered_skipped reason=invalid_round_key"
			.. " screen=" .. tostring(screenName)
			.. " room=" .. tostring(self.currentRoomId)
			.. " phase=" .. tostring(roomPhase)
			.. " key=" .. tostring(key))
		if callback then callback(false, nil, { errorMessage = "Invalid online round key." }) end
		return
	end
	if self.onlineGameplayReturnedKey == key or self.onlineGameplayTerminalKey == key then
		online_flow_trace("mark_play_entered_skipped reason=round_already_finished"
			.. " screen=" .. tostring(screenName)
			.. " room=" .. tostring(self.currentRoomId)
			.. " phase=" .. tostring(roomPhase)
			.. " key=" .. tostring(key)
			.. " returnedKey=" .. tostring(self.onlineGameplayReturnedKey or "")
			.. " terminalKey=" .. tostring(self.onlineGameplayTerminalKey or ""))
		if callback then callback(true, { play_state = self.currentRoom and self.currentRoom.play_state or nil }, nil) end
		return
	end
	if self.onlineGameplayEnteredKey == key then
		if callback then callback(true, { play_state = self.currentRoom and self.currentRoom.play_state or nil }, nil) end
		return
	end
	if self.onlineGameplayEnteredInFlightKey == key then
		if callback then callback(true, { play_state = self.currentRoom and self.currentRoom.play_state or nil }, nil) end
		return
	end

	self.onlineGameplayEnteredInFlightKey = key
	self:TraceOnlineState("mark_play_entered_request", {
		source = "play_entered",
		roundKey = key,
		screenName = screenName,
		roomPhase = roomPhase,
	})
	self:Request("POST", "/rooms/" .. tostring(self.currentRoomId) .. "/play/entered", {}, function(ok, decoded, response)
		if self.onlineGameplayEnteredInFlightKey == key then
			self.onlineGameplayEnteredInFlightKey = ""
		end
		if ok then
			self.onlineGameplayEnteredKey = key
			self.onlineGameplayReturnedKey = ""
			self.onlineGameplayReturnedLocalRoomId = ""
			self.onlineGameplayReturnedLocalAt = 0
			self:UpdatePlayStateFromResponse(decoded)
		end
		self:TraceOnlineState("mark_play_entered_response", {
			source = "play_entered",
			roomSnapshot = self.currentRoom,
			roundKey = key,
			ok = ok == true,
			status = response and response.statusCode or "nil",
			error = decoded and decoded.error_code or response and response.errorMessage or "nil",
		})
		if callback then callback(ok, decoded, response) end
	end)
end

function ITGOnline:MarkReturnedToLobby(callback)
	if not self.currentRoomId then
		online_flow_trace("mark_returned_to_lobby_failed reason=no_current_room")
		if callback then callback(false, nil, { errorMessage = "No active online room." }) end
		return
	end
	local roomPhase = self:NormalizeRoomPhase(self.currentRoom and self.currentRoom.phase or self.currentRoomPhase)
	if roomPhase ~= "results" then
		online_flow_trace("mark_returned_to_lobby_skipped reason=room_not_results"
			.. " room=" .. tostring(self.currentRoomId)
			.. " phase=" .. tostring(roomPhase)
			.. " roundKey=" .. tostring(self:PlayStateKey()))
		if callback then callback(false, nil, { errorMessage = "Returned-to-lobby ignored before results.", skipped=true }) end
		return
	end
	local key = self:PlayStateKey()
	if self:PlayStateKeyIsValid(key) and self.onlineGameplayReturnedKey == key then
		online_flow_trace("mark_returned_to_lobby_skipped reason=already_returned"
			.. " room=" .. tostring(self.currentRoomId)
			.. " roundKey=" .. tostring(key))
		if callback then callback(true, { play_state = self.currentRoom and self.currentRoom.play_state or nil }, nil) end
		return
	end
	if self:PlayStateKeyIsValid(key) and self.onlineGameplayReturnedInFlightKey == key then
		online_flow_trace("mark_returned_to_lobby_skipped reason=in_flight"
			.. " room=" .. tostring(self.currentRoomId)
			.. " roundKey=" .. tostring(key))
		if callback then callback(false, nil, { retryAfter = 0.5, inFlight = true }) end
		return
	end

	if self:PlayStateKeyIsValid(key) then
		self.onlineGameplayReturnedInFlightKey = key
		self.onlineGameplayEvaluationShownKey = key
		self.onlineGameplayEvaluationReturnedKey = key
	end
	self.onlineGameplayReturnedLocalRoomId = tostring(self.currentRoomId or "")
	self.onlineGameplayReturnedLocalAt = GetTimeSinceStart()
	local summary = self.PlayStateSummary and self:PlayStateSummary(self.currentRoom) or nil
	local cache = self.GetFinalLeaderboardCache and self:GetFinalLeaderboardCache(self.currentRoomId) or nil
	online_flow_trace("mark_returned_to_lobby_request room=" .. tostring(self.currentRoomId)
		.. " roundKey=" .. tostring(key)
		.. " phase=" .. tostring(roomPhase)
		.. " players=" .. tostring(summary and summary.players or "nil")
		.. " terminal=" .. tostring(summary and summary.terminal or "nil")
		.. " finalResults=" .. tostring(summary and summary.finalResults or "nil")
		.. " finalResultsReady=" .. tostring(summary and summary.finalResultsReady == true)
		.. " cacheRows=" .. tostring(cache and cache.rows and #cache.rows or 0)
		.. " cacheSource=" .. tostring(cache and cache.source or "nil")
		.. " localReturnRoomId=" .. tostring(self.onlineGameplayReturnedLocalRoomId)
		.. " localReturnAt=" .. string.format("%.3f", tonumber(self.onlineGameplayReturnedLocalAt) or 0))
	self:Request("POST", "/rooms/" .. tostring(self.currentRoomId) .. "/play/returned-to-lobby", {}, function(ok, decoded, response)
		if self.onlineGameplayReturnedInFlightKey == key then
			self.onlineGameplayReturnedInFlightKey = ""
		end
		if ok then
			self.onlineGameplayReturnedKey = key
			self:UpdatePlayStateFromResponse(decoded)
			if self.currentRoom then
				online_flow_trace("mark_returned_to_lobby_confirmed_preserve_server_phase"
					.. " room=" .. tostring(self.currentRoomId)
					.. " phase=" .. tostring(self.currentRoom.phase or "nil")
					.. " roundKey=" .. tostring(key))
			end
		end
		online_flow_trace("mark_returned_to_lobby_response room=" .. tostring(self.currentRoomId)
			.. " roundKey=" .. tostring(key)
			.. " ok=" .. tostring(ok == true)
			.. " status=" .. tostring(response and response.statusCode or "nil")
			.. " responsePhase=" .. tostring(decoded and decoded.room and decoded.room.phase or decoded and decoded.room_phase or "nil")
			.. " responseFinalResults=" .. tostring(decoded and decoded.room and decoded.room.play_state and decoded.room.play_state.final_results and #decoded.room.play_state.final_results or 0)
			.. " responseFinalRowsSummary=" .. online_score_rows_summary(decoded and decoded.room and decoded.room.play_state and decoded.room.play_state.final_results or nil, 8)
			.. " message=" .. tostring(response_message(response, decoded, "")))
		if callback then callback(ok, decoded, response) end
	end)
end

function ITGOnline:MarkPlayTerminal(endpoint, state, callback)
	if not self.currentRoomId then
		online_flow_trace("mark_play_terminal_failed state=" .. tostring(state)
			.. " reason=no_current_room")
		if callback then callback(false, nil, { errorMessage = "No active online room." }) end
		return
	end
	local key = self:PlayStateKey()
	local validKey = self:PlayStateKeyIsValid(key)
	local terminalKey = key .. "|" .. tostring(state or "")
	if validKey and self.onlineGameplayTerminalKey == terminalKey then
		online_flow_trace("mark_play_terminal_skipped state=" .. tostring(state)
			.. " reason=already_terminal"
			.. " room=" .. tostring(self.currentRoomId)
			.. " roundKey=" .. tostring(key))
		if callback then callback(true, { play_state = self.currentRoom and self.currentRoom.play_state or nil }, nil) end
		return
	end
	if validKey and self.onlineGameplayTerminalKey == (key .. "|finished") then
		online_flow_trace("mark_play_terminal_skipped state=" .. tostring(state)
			.. " reason=already_finished"
			.. " room=" .. tostring(self.currentRoomId)
			.. " roundKey=" .. tostring(key))
		if callback then callback(true, { play_state = self.currentRoom and self.currentRoom.play_state or nil }, nil) end
		return
	end
	if validKey and self.onlineGameplayTerminalKey == (key .. "|failed") and state == "failed" then
		online_flow_trace("mark_play_terminal_skipped state=failed reason=already_failed"
			.. " room=" .. tostring(self.currentRoomId)
			.. " roundKey=" .. tostring(key))
		if callback then callback(true, { play_state = self.currentRoom and self.currentRoom.play_state or nil }, nil) end
		return
	end
	if validKey and self.onlineGameplayTerminalKey == key and self.onlineGameplayTerminalState == state then
		online_flow_trace("mark_play_terminal_skipped state=" .. tostring(state)
			.. " reason=legacy_terminal_key"
			.. " room=" .. tostring(self.currentRoomId)
			.. " roundKey=" .. tostring(key))
		if callback then callback(true, { play_state = self.currentRoom and self.currentRoom.play_state or nil }, nil) end
		return
	end
	if validKey and self.onlineGameplayTerminalInFlightKey == terminalKey then
		online_flow_trace("mark_play_terminal_skipped state=" .. tostring(state)
			.. " reason=in_flight"
			.. " room=" .. tostring(self.currentRoomId)
			.. " roundKey=" .. tostring(key))
		if callback then callback(false, nil, { retryAfter = 0.5, inFlight = true }) end
		return
	end

	local currentPhase = self:NormalizeRoomPhase(self.currentRoom and self.currentRoom.phase)
	if validKey
		and currentPhase == "results"
		and (
			tostring(self.lastFinalScoreKey or "") == tostring(key or "")
			or self:CurrentUserHasFinalResult(self.currentRoom)
		)
	then
		self.onlineGameplayTerminalKey = terminalKey
		self.onlineGameplayTerminalState = state
		self:ApplyLocalPlayState(state, "terminal_skipped_results_final_score_accepted")
		online_flow_trace("mark_play_terminal_skipped state=" .. tostring(state)
			.. " reason=results_final_score_accepted"
			.. " room=" .. tostring(self.currentRoomId)
			.. " roundKey=" .. tostring(key)
			.. " phase=" .. tostring(currentPhase)
			.. " lastFinalScoreKey=" .. tostring(self.lastFinalScoreKey or "")
			.. " hasFinalResult=" .. tostring(self:CurrentUserHasFinalResult(self.currentRoom) == true))
		if callback then callback(true, { play_state = self.currentRoom and self.currentRoom.play_state or nil }, nil) end
		return
	end

	if validKey then
		self.onlineGameplayTerminalInFlightKey = terminalKey
	end

	self.onlineGameplayTerminalState = state

	online_flow_trace("mark_play_terminal_request state=" .. tostring(state)
		.. " endpoint=" .. tostring(endpoint)
		.. " room=" .. tostring(self.currentRoomId)
		.. " roundKey=" .. tostring(key)
		.. " validKey=" .. tostring(validKey == true)
		.. " phase=" .. tostring(self.currentRoom and self.currentRoom.phase or "nil"))
	self:TraceOnlineState("mark_play_terminal_request", {
		source = "play_terminal",
		state = state,
		endpoint = endpoint,
		roundKey = key,
		validKey = validKey == true,
	})

	self:Request("POST", "/rooms/" .. tostring(self.currentRoomId) .. endpoint, {}, function(ok, decoded, response)
		if validKey and self.onlineGameplayTerminalInFlightKey == terminalKey then
			self.onlineGameplayTerminalInFlightKey = ""
		end
		if ok then
			if validKey then
				self.onlineGameplayTerminalKey = terminalKey
				self.onlineGameplayTerminalState = state
			end
			self:ApplyLocalPlayState(state, "terminal_response")
			self:UpdatePlayStateFromResponse(decoded)
		end
		online_flow_trace("mark_play_terminal_response state=" .. tostring(state)
			.. " room=" .. tostring(self.currentRoomId)
			.. " roundKey=" .. tostring(key)
			.. " ok=" .. tostring(ok == true)
			.. " status=" .. tostring(response and response.statusCode or "nil")
			.. " message=" .. tostring(response_message(response, decoded, "")))
		self:TraceOnlineState("mark_play_terminal_response", {
			source = "play_terminal",
			roomSnapshot = self.currentRoom,
			state = state,
			endpoint = endpoint,
			roundKey = key,
			ok = ok == true,
			status = response and response.statusCode or "nil",
			error = decoded and decoded.error_code or response and response.errorMessage or "nil",
		})
		local errorCode = response_error_code(response, decoded)
		if not ok
			and state == "finished"
			and errorCode == "finished_requires_finalized_score"
			and self.SendScore
		then
			online_flow_trace("mark_play_terminal_recover_missing_final_score"
				.. " state=" .. tostring(state)
				.. " room=" .. tostring(self.currentRoomId)
				.. " roundKey=" .. tostring(key)
				.. " status=" .. tostring(response and response.statusCode or "nil"))
			self:SendScore(true, true, nil, function(scoreOk, scoreDecoded, scoreResponse)
				if scoreOk then
					online_flow_trace("mark_play_terminal_retry_after_final_score"
						.. " state=" .. tostring(state)
						.. " room=" .. tostring(self.currentRoomId)
						.. " roundKey=" .. tostring(key))
					self:MarkPlayTerminal(endpoint, state, callback)
					return
				end
				online_flow_trace("mark_play_terminal_missing_final_score_recovery_failed"
					.. " state=" .. tostring(state)
					.. " room=" .. tostring(self.currentRoomId)
					.. " roundKey=" .. tostring(key)
					.. " status=" .. tostring(scoreResponse and scoreResponse.statusCode or "nil")
					.. " errorCode=" .. tostring(response_error_code(scoreResponse, scoreDecoded) or "nil"))
				if callback then callback(false, scoreDecoded, scoreResponse or response) end
			end)
			return
		end
		if callback then callback(ok, decoded, response) end
	end)
end

function ITGOnline:MarkPlayFinished(callback)
	online_flow_trace("mark_play_finished_invoked room=" .. tostring(self.currentRoomId or "nil"))
	self:MarkPlayTerminal("/play/finished", "finished", callback)
end

function ITGOnline:MarkPlayFailed(callback)
	online_flow_trace("mark_play_failed_invoked room=" .. tostring(self.currentRoomId or "nil"))
	self:MarkPlayTerminal("/play/failed", "failed", callback)
end

function ITGOnline:MarkPlayFailedEarly(source, callback)
	if not self.currentRoomId or not self.currentRoom then
		if callback then callback(false, nil, { errorMessage = "No active online room." }) end
		return false
	end

	local phase = self:NormalizeRoomPhase(self.currentRoom.phase)
	if phase ~= "starting" and phase ~= "playing" and phase ~= "results" then
		online_flow_trace("mark_failed_early_skipped source=" .. tostring(source or "unknown")
			.. " phase=" .. tostring(phase))
		if callback then callback(false, nil, { errorMessage = "Room is not in a playable phase." }) end
		return false
	end

	local key = self:PlayStateKey()
	if not self:PlayStateKeyIsValid(key) then
		online_flow_trace("mark_failed_early_skipped source=" .. tostring(source or "unknown")
			.. " reason=invalid_round_key")
		if callback then callback(false, nil, { errorMessage = "No active song round." }) end
		return false
	end

	local activeRoundKey = tostring(self.activeGameplayRoundKey or "")
	if self:PlayStateKeyIsValid(activeRoundKey) and activeRoundKey ~= key then
		online_flow_trace("mark_failed_early_skipped source=" .. tostring(source or "unknown")
			.. " reason=stale_round_key"
			.. " active=" .. tostring(activeRoundKey)
			.. " incoming=" .. tostring(key))
		if callback then callback(false, nil, { errorMessage = "Stale song round." }) end
		return false
	end

	local finalScoreAccepted = self.lastFinalScoreKey == key
	if self.onlineGameplayFailedEarlyKey == key then
		if finalScoreAccepted then
			online_flow_trace("mark_failed_early_skipped source=" .. tostring(source or "unknown")
				.. " reason=already_confirmed"
				.. " roundKey=" .. tostring(key)
				.. " finalScoreAccepted=true")
			if callback then callback(true, { play_state = self.currentRoom and self.currentRoom.play_state or nil }, nil) end
			return true
		end

		online_flow_trace("mark_failed_early_retry source=" .. tostring(source or "unknown")
			.. " reason=failed_state_confirmed_without_final_score"
			.. " roundKey=" .. tostring(key)
			.. " lastFinalScoreKey=" .. tostring(self.lastFinalScoreKey or "")
			.. " hasFinalResult=" .. tostring(self:CurrentUserHasFinalResult(self.currentRoom) == true))
		self.onlineGameplayFailedEarlyKey = ""
	end
	if self.onlineGameplayFailedEarlyInFlightKey == key then
		online_flow_trace("mark_failed_early_skipped source=" .. tostring(source or "unknown")
			.. " reason=in_flight"
			.. " roundKey=" .. tostring(key))
		if callback then callback(false, nil, { retryAfter = 0.5, inFlight = true }) end
		return true
	end

	self.onlineGameplayFailedEarlyInFlightKey = key
		online_flow_trace("mark_failed_early source=" .. tostring(source or "unknown")
		.. " phase=" .. tostring(phase)
		.. " roundKey=" .. tostring(key))

	local confirmFailed
	confirmFailed = function(scoreOk, scoreDecoded, scoreResponse)
		if scoreOk == false then
			if self.onlineGameplayFailedEarlyInFlightKey == key then
				self.onlineGameplayFailedEarlyInFlightKey = ""
			end
			self.onlineGameplayFailedEarlyKey = ""
			online_flow_trace("mark_failed_early_aborted_before_terminal_state"
				.. " roundKey=" .. tostring(key)
				.. " reason=final_failed_score_not_accepted"
				.. " status=" .. tostring(scoreResponse and scoreResponse.statusCode or "nil")
				.. " errorCode=" .. tostring(response_error_code(scoreResponse, scoreDecoded) or "nil")
				.. " message=" .. tostring(response_message(scoreResponse, scoreDecoded, "failed score rejected")))
			self.onlineGameplayEvaluationRetryKey = key
			self.onlineGameplayEvaluationNextRetryAt = GetTimeSinceStart() + 0.35
			if callback then callback(false, scoreDecoded, scoreResponse or { errorMessage = "Failed final score was not accepted." }) end
			return
		end

		local scoreRoomPhase = self:NormalizeRoomPhase(
			scoreDecoded and (scoreDecoded.room_phase or scoreDecoded.room and scoreDecoded.room.phase)
				or self.currentRoom and self.currentRoom.phase
				or phase
		)
		if scoreRoomPhase == "results" then
			if self.onlineGameplayFailedEarlyInFlightKey == key then
				self.onlineGameplayFailedEarlyInFlightKey = ""
			end
			self.onlineGameplayFailedEarlyKey = key
			self:ApplyLocalPlayState("failed", "mark_failed_early_final_score_accepted")
			online_flow_trace("mark_failed_early_confirmed_without_terminal_post"
				.. " roundKey=" .. tostring(key)
				.. " reason=final_failed_score_accepted"
				.. " roomPhase=" .. tostring(scoreRoomPhase)
				.. " lastFinalScoreKey=" .. tostring(self.lastFinalScoreKey or ""))
			if callback then callback(true, scoreDecoded, scoreResponse) end
			return
		end

		self:MarkPlayFailed(function(ok, decoded, response)
			if self.onlineGameplayFailedEarlyInFlightKey == key then
				self.onlineGameplayFailedEarlyInFlightKey = ""
			end
			local errorCode = response_error_code(response, decoded)
			if ok or errorCode == "room_not_playing" then
				self.onlineGameplayFailedEarlyKey = key
				self:ApplyLocalPlayState("failed", "mark_failed_early_terminal_post")
				online_flow_trace("mark_failed_early_confirmed roundKey=" .. tostring(key)
					.. " terminalPostOk=" .. tostring(ok == true)
					.. " errorCode=" .. tostring(errorCode or "nil"))
			else
				online_flow_trace("mark_failed_early_rejected roundKey=" .. tostring(key)
					.. " message=" .. tostring(response_message(response, decoded, "failed state rejected")))
			end
			if callback then callback(ok or errorCode == "room_not_playing", decoded, response) end
		end)
	end

	if self.SendScore then
		self.scoreInFlightFingerprint = nil
		self.pendingLiveScoreSnapshot = nil
		self.pendingLiveScoreRoundKey = ""
		online_flow_trace("mark_failed_early_final_score_submit"
			.. " source=" .. tostring(source or "unknown")
			.. " room=" .. tostring(self.currentRoomId or "nil")
			.. " phase=" .. tostring(phase)
			.. " roundKey=" .. tostring(key)
			.. " hasDisplayedSnapshot=" .. tostring(self.lastDisplayedScoreSnapshot ~= nil))
		self:SendScore(true, true, nil, confirmFailed, { forceFailed = true, forceFinalFailed = true })
		return true
	end

	self:MarkPlayFailed(function(ok, decoded, response)
		if self.onlineGameplayFailedEarlyInFlightKey == key then
			self.onlineGameplayFailedEarlyInFlightKey = ""
		end
		if ok then
			self.onlineGameplayFailedEarlyKey = key
			online_flow_trace("mark_failed_early_confirmed roundKey=" .. tostring(key))
		else
			online_flow_trace("mark_failed_early_rejected roundKey=" .. tostring(key)
				.. " message=" .. tostring(response_message(response, decoded, "failed state rejected")))
		end
		if callback then callback(ok, decoded, response) end
	end)

	return true
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

	local songKey = self.PlayStateKey and self:PlayStateKey() or ""
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
	self:TraceOnlineState("song_loaded_request", {
		source = "mark_song_loaded",
		roundKey = songKey,
		clockFresh = self.ClockSyncIsFresh and self:ClockSyncIsFresh() or false,
		callbacks = self.songLoadedPendingCallbacks[songKey] and #self.songLoadedPendingCallbacks[songKey] or 0,
	})
	self:Request("POST", "/rooms/" .. tostring(self.currentRoomId) .. "/loaded", {}, function(ok, decoded, response)
		if self.songLoadedInFlightKey == songKey then
			self.songLoadedInFlightKey = ""
		end
		self:TraceOnlineState("song_loaded_response", {
			source = "mark_song_loaded",
			roomSnapshot = decoded and decoded.room or nil,
			roundKey = songKey,
			ok = ok == true,
			status = response and response.statusCode or "nil",
			error = decoded and decoded.error_code or response and response.errorMessage or "nil",
		})
				if ok and decoded and decoded.room then
					local room = self:ApplyRoomSnapshot(decoded.room, "mark_song_loaded")
					decoded.room = room or decoded.room
					self:UpdateScheduledStart(room or decoded.room)
					self:MaybeAckScheduledStart(room or decoded.room)
					self.songLoadedAckKey = songKey
					MESSAGEMAN:Broadcast("OnlineLobbyState", self:LobbyStatePayload(room or decoded.room))
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
	if screenName ~= "ScreenGameplay" and screenName ~= "ScreenGameplayShared" then
		online_flow_trace("start_ack_skipped reason=not_gameplay_screen"
			.. " screen=" .. tostring(screenName)
			.. " room=" .. tostring(self.currentRoomId)
			.. " phase=" .. tostring(room.phase or "nil"))
		return
	end

	local selectedSong = room.selected_song or self.currentSongPayload
	local roomId = tostring(room.id or self.currentRoomId or "")
	local chartHash = tostring(selectedSong and selectedSong.chart_hash or "")
	local startAt = tostring(room.start_at or room.start_at_ms or "")
	if roomId == "" or chartHash == "" or startAt == "" then
		online_flow_trace("start_ack_skipped reason=missing_identity"
			.. " room=" .. tostring(roomId)
			.. " chartHash=" .. tostring(chartHash)
			.. " startAt=" .. tostring(startAt))
		return
	end
	local key = roomId .. "|" .. tostring(self:SelectedSongRoundKey(selectedSong, roomId)) .. "|" .. startAt
	local intentKey = roomId .. "|" .. tostring(self:SelectedSongRoundKey(selectedSong, roomId))
	local now = GetTimeSinceStart and GetTimeSinceStart() or 0
	if intentKey ~= "" and intentKey == tostring(self.startScheduleAckIntentKey or "") then
		local age = now - (tonumber(self.startScheduleAckIntentAt) or 0)
		if age < 2.0 then
			online_flow_trace("start_ack_skipped reason=duplicate_intent"
				.. " key=" .. tostring(key)
				.. " intentKey=" .. tostring(intentKey)
				.. " age=" .. string.format("%.3f", age)
				.. " completed=" .. tostring(self.startScheduleAckKey == key)
				.. " inFlight=" .. tostring(self.startScheduleAckInFlightKey == key))
			return
		end
	end
	if self.startScheduleAckKey == key or self.startScheduleAckInFlightKey == key then
		online_flow_trace("start_ack_skipped reason=duplicate"
			.. " key=" .. tostring(key)
			.. " completed=" .. tostring(self.startScheduleAckKey == key)
			.. " inFlight=" .. tostring(self.startScheduleAckInFlightKey == key))
		return
	end

	self.startScheduleAckIntentKey = intentKey
	self.startScheduleAckIntentAt = now
	self.startScheduleAckInFlightKey = key
	self:TraceOnlineState("start_ack_request", {
		source = "start_ack",
		ackKey = key,
		intentKey = intentKey,
		screenName = screenName,
		startAt = startAt,
		chartHash = tostring(chartHash):sub(1, 12),
	})
	self:Request("POST", "/rooms/" .. tostring(self.currentRoomId) .. "/start-ack", {}, function(ok, decoded, response)
		if self.startScheduleAckInFlightKey == key then
			self.startScheduleAckInFlightKey = ""
		end
		self:TraceOnlineState("start_ack_response", {
			source = "start_ack",
			roomSnapshot = decoded and decoded.room or nil,
			ackKey = key,
			intentKey = intentKey,
			ok = ok == true,
			status = response and response.statusCode or "nil",
			error = decoded and decoded.error_code or response and response.errorMessage or "nil",
		})
		if ok and decoded and decoded.room then
			local room = self:ApplyRoomSnapshot(decoded.room, "ack_scheduled_start")
			decoded.room = room or decoded.room
			self:UpdateScheduledStart(room or decoded.room)
			self.startScheduleAckKey = key
			MESSAGEMAN:Broadcast("OnlineLobbyState", self:LobbyStatePayload(room or decoded.room))
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
	local visibleKey = tostring(self.currentRoomId or "") .. "|" .. tostring(startAtMs or "")

	if serverTimeMs and self.UpdateServerClockOffset then
		self:UpdateServerClockOffset(serverTimeMs, GetTimeSinceStart(), GetTimeSinceStart())
	end

	if self.scheduledStartVisibleKey ~= visibleKey then
		self.scheduledStartVisibleKey = visibleKey
		self.scheduledStartVisibleSeconds = nil
		self.scheduledStartVisibleUpdatedAt = 0
	end

	if startAtMs and self.serverClockOffsetSeconds then
		self.scheduledStartLocalTime = (startAtMs / 1000) - self.serverClockOffsetSeconds
	elseif startAtMs and serverTimeMs then
		self.scheduledStartLocalTime = GetTimeSinceStart() + ((startAtMs - serverTimeMs) / 1000)
	elseif room.phase ~= "starting" and room.phase ~= "playing" then
		self.scheduledStartLocalTime = nil
		self.scheduledStartVisibleKey = ""
		self.scheduledStartVisibleSeconds = nil
		self.scheduledStartVisibleUpdatedAt = 0
	end
end

function ITGOnline:SecondsUntilScheduledStart()
	if not self.scheduledStartLocalTime then return nil end
	return self.scheduledStartLocalTime - GetTimeSinceStart()
end

function ITGOnline:VisibleSecondsUntilScheduledStart()
	local seconds = self:SecondsUntilScheduledStart()
	if not seconds then
		if tostring(self.scheduledStartVisibleTraceKey or "") ~= "nil_seconds" then
			self.scheduledStartVisibleTraceKey = "nil_seconds"
			online_flow_trace("scheduled_start_visible_reset reason=nil_seconds"
				.. " room=" .. tostring(self.currentRoomId or "nil")
				.. " phase=" .. tostring(self.currentRoom and self.currentRoom.phase or "nil"))
		end
		self.scheduledStartVisibleSeconds = nil
		self.scheduledStartVisibleUpdatedAt = 0
		return nil
	end

	if seconds <= 0 then
		local traceKey = "elapsed|" .. tostring(math.ceil(seconds))
		if tostring(self.scheduledStartVisibleTraceKey or "") ~= traceKey then
			self.scheduledStartVisibleTraceKey = traceKey
			online_flow_trace("scheduled_start_visible_elapsed seconds=" .. tostring(seconds)
				.. " room=" .. tostring(self.currentRoomId or "nil")
				.. " phase=" .. tostring(self.currentRoom and self.currentRoom.phase or "nil"))
		end
		self.scheduledStartVisibleSeconds = nil
		self.scheduledStartVisibleUpdatedAt = 0
		return seconds
	end

	local now = GetTimeSinceStart()
	local actualCeil = math.max(0, math.ceil(seconds))
	if self.scheduledStartVisibleSeconds == nil then
		self.scheduledStartVisibleSeconds = actualCeil
		self.scheduledStartVisibleUpdatedAt = now
		self.scheduledStartVisibleTraceKey = "init|" .. tostring(actualCeil)
		online_flow_trace("scheduled_start_visible_init actual=" .. tostring(actualCeil)
			.. " seconds=" .. tostring(seconds)
			.. " room=" .. tostring(self.currentRoomId or "nil")
			.. " phase=" .. tostring(self.currentRoom and self.currentRoom.phase or "nil"))
		return actualCeil
	end

	local visible = tonumber(self.scheduledStartVisibleSeconds) or actualCeil
	if actualCeil > visible then
		visible = actualCeil
		self.scheduledStartVisibleUpdatedAt = now
	elseif actualCeil < visible then
		local elapsed = math.max(0, now - (tonumber(self.scheduledStartVisibleUpdatedAt) or now))
		if elapsed >= 0.85 then
			visible = math.max(actualCeil, visible - 1)
			self.scheduledStartVisibleUpdatedAt = now
		end
	end

	self.scheduledStartVisibleSeconds = visible
	local traceKey = tostring(actualCeil) .. "|" .. tostring(visible)
	if tostring(self.scheduledStartVisibleTraceKey or "") ~= traceKey then
		self.scheduledStartVisibleTraceKey = traceKey
		online_flow_trace("scheduled_start_visible_update actual=" .. tostring(actualCeil)
			.. " visible=" .. tostring(visible)
			.. " seconds=" .. tostring(seconds)
			.. " room=" .. tostring(self.currentRoomId or "nil")
			.. " phase=" .. tostring(self.currentRoom and self.currentRoom.phase or "nil"))
	end
	return visible
end

function ITGOnline:Heartbeat(status, force)
	status = status or "available"
	local roomId = self.currentRoomId
	local isLobbyPresenceHeartbeat = roomId == nil and tostring(status) == "available"
	online_flow_trace("heartbeat_begin status=" .. tostring(status)
		.. " force=" .. tostring(force == true)
		.. " room=" .. tostring(roomId or "nil")
		.. " phase=" .. tostring(self.currentRoom and self.currentRoom.phase or "nil")
		.. " inFlight=" .. tostring(self.heartbeatInFlight == true)
		.. " queued=" .. tostring(self.heartbeatQueuedStatus or "nil")
		.. " screen=" .. tostring(self.currentScreenName or "nil"))
	self:TraceOnlineState("heartbeat_begin", {
		source = "heartbeat",
		status = status,
		force = force == true,
		inFlight = self.heartbeatInFlight == true,
		queued = self.heartbeatQueuedStatus or "nil",
		fingerprint = tostring(status) .. "|" .. tostring(roomId or ""),
	})
	if tostring(self.currentRoomBlockedReason or "") ~= "" and not isLobbyPresenceHeartbeat then
		online_trace("Heartbeat suppressed while current room is blocked: status="
			.. tostring(status)
			.. " reason=" .. tostring(self.currentRoomBlockedReason))
		online_flow_trace("heartbeat_suppressed reason=current_room_blocked"
			.. " status=" .. tostring(status)
			.. " block=" .. tostring(self.currentRoomBlockedReason)
			.. " openCount=" .. tostring(self.currentRoomBlockedOpenCount or "nil"))
		return
	end

	local fingerprint = tostring(status) .. "|" .. tostring(roomId or "")
	local now = GetTimeSinceStart()

	if self.heartbeatInFlight then
		local previousQueuedFingerprint = tostring(self.heartbeatQueuedFingerprint or "")
		if previousQueuedFingerprint == fingerprint then
			self.heartbeatQueuedForce = self.heartbeatQueuedForce or force == true
			self.heartbeatQueuedAt = now
			online_flow_trace("heartbeat_queue_coalesced reason=same_fingerprint_in_flight status=" .. tostring(status)
				.. " fingerprint=" .. tostring(fingerprint)
				.. " queuedForce=" .. tostring(self.heartbeatQueuedForce == true)
				.. " screen=" .. tostring(self.currentScreenName or "nil"))
			return
		end
		self.heartbeatQueuedStatus = status
		self.heartbeatQueuedForce = self.heartbeatQueuedForce or force == true
		self.heartbeatQueuedFingerprint = fingerprint
		self.heartbeatQueuedAt = now
		online_flow_trace("heartbeat_queued reason=in_flight status=" .. tostring(status)
			.. " fingerprint=" .. tostring(fingerprint)
			.. " previousQueued=" .. tostring(previousQueuedFingerprint ~= "" and previousQueuedFingerprint or "nil")
			.. " queuedForce=" .. tostring(self.heartbeatQueuedForce == true))
		return
	end

	if not force
		and fingerprint == self.lastHeartbeatFingerprint
		and now - (tonumber(self.lastHeartbeatSentAt) or 0) < (tonumber(self.heartbeatMinIntervalSeconds) or 1.5) then
		local throttleLogKey = tostring(status) .. "|" .. tostring(roomId or "") .. "|" .. tostring(self.currentScreenName or "")
		self.heartbeatThrottleLogCount = (tonumber(self.heartbeatThrottleLogCount) or 0) + 1
		if throttleLogKey ~= tostring(self.heartbeatThrottleLogKey or "")
			or now - (tonumber(self.heartbeatThrottleLogAt) or 0) >= 5 then
			online_flow_trace("heartbeat_skipped reason=throttled status=" .. tostring(status)
				.. " fingerprint=" .. tostring(fingerprint)
				.. " elapsed=" .. tostring(now - (tonumber(self.lastHeartbeatSentAt) or 0))
				.. " minInterval=" .. tostring(tonumber(self.heartbeatMinIntervalSeconds) or 1.5)
				.. " screen=" .. tostring(self.currentScreenName or "nil")
				.. " suppressedCount=" .. tostring(self.heartbeatThrottleLogCount))
			self.heartbeatThrottleLogKey = throttleLogKey
			self.heartbeatThrottleLogAt = now
			self.heartbeatThrottleLogCount = 0
		end
		return
	end

	local payload = { status = status }
	if roomId then payload.room_id = roomId end

	self.heartbeatInFlight = true
	self.lastHeartbeatSentAt = now
	self.lastHeartbeatFingerprint = fingerprint
	online_flow_trace("heartbeat_request status=" .. tostring(status)
		.. " room=" .. tostring(roomId or "nil")
		.. " fingerprint=" .. tostring(fingerprint)
		.. " force=" .. tostring(force == true))
	self:Request("POST", "/presence/heartbeat", payload, function(ok, decoded, response)
		self.heartbeatInFlight = false
		local queuedStatus = self.heartbeatQueuedStatus
		local queuedForce = self.heartbeatQueuedForce == true
		local queuedFingerprint = tostring(self.heartbeatQueuedFingerprint or "")
		self.heartbeatQueuedStatus = nil
		self.heartbeatQueuedForce = false
		self.heartbeatQueuedFingerprint = ""
		self.heartbeatQueuedAt = 0
		online_flow_trace("heartbeat_response status=" .. tostring(status)
			.. " ok=" .. tostring(ok == true)
			.. " statusCode=" .. tostring(response and response.statusCode or "nil")
			.. " room=" .. tostring(roomId or "nil")
			.. " queuedStatus=" .. tostring(queuedStatus or "nil")
			.. " queuedForce=" .. tostring(queuedForce == true)
			.. " queuedFingerprint=" .. tostring(queuedFingerprint ~= "" and queuedFingerprint or "nil")
			.. " screen=" .. tostring(self.currentScreenName or "nil")
			.. " disconnecting=" .. tostring(self.disconnecting == true))
		if ok and self.currentScreenName == "ScreenOnlineLobbies" and not self.disconnecting then
			if self.currentRoomId then
				online_flow_trace("heartbeat_fetch_current_room source=heartbeat_ack room=" .. tostring(self.currentRoomId))
				self:FetchCurrentRoomFallback("heartbeat_ack", 1.0)
			else
				online_flow_trace("heartbeat_queue_lobby_refresh source=heartbeat_ack")
				self:QueueLobbyRefresh({ reason = "heartbeat_ack" })
			end
		end
		if queuedStatus then
			local replayNow = GetTimeSinceStart()
			if queuedFingerprint ~= ""
				and queuedFingerprint == tostring(self.lastHeartbeatFingerprint or "")
				and (replayNow - (tonumber(self.lastHeartbeatSentAt) or 0)) < (tonumber(self.heartbeatMinIntervalSeconds) or 30)
			then
				online_flow_trace("heartbeat_replay_skipped reason=coalesced_recent_duplicate"
					.. " status=" .. tostring(queuedStatus)
					.. " fingerprint=" .. tostring(queuedFingerprint)
					.. " elapsed=" .. tostring(replayNow - (tonumber(self.lastHeartbeatSentAt) or 0)))
				return
			end
			online_flow_trace("heartbeat_replay_queued status=" .. tostring(queuedStatus)
				.. " force=" .. tostring(queuedForce == true))
			self:Heartbeat(queuedStatus, queuedForce)
		end
	end)
end

function ITGOnline:ForceLobbyPresenceHeartbeat(reason)
	online_flow_trace("lobby_presence_heartbeat_forced reason=" .. tostring(reason or "unknown")
		.. " currentRoomId=" .. tostring(self.currentRoomId or "nil")
		.. " screen=" .. tostring(self.currentScreenName or "nil")
		.. " connected=" .. tostring(self.realtimeConnected == true))
	self:Heartbeat(self.currentRoomId and "in_room" or "available", true)
end

function ITGOnline:IsPostLeaveLobbyRefreshReason(reason)
	reason = tostring(reason or "")
	return reason == "leave_room_confirmed"
		or reason == "overlay_post_leave"
		or reason == "overlay_post_leave_command"
		or reason == "room.member_left"
		or reason == "room.deleted"
		or reason == "presence.updated"
		or reason:match("^purge_stale_lobby_candidate:") ~= nil
		or reason:match("^coalesced:queued_after_response:") ~= nil
end

function ITGOnline:FetchLobby(callback)
	local accumulator = {
		online_users = {},
		public_rooms = {},
		meta = nil,
	}
	local onlineCursor = nil
	local roomsCursor = nil
	local pagesFetched = 0
	local maxPages = 20

	local fetchPage
	fetchPage = function()
		pagesFetched = pagesFetched + 1
		local path = "/lobby?online_per_page=250&rooms_per_page=100"
		if onlineCursor then path = path .. "&online_cursor=" .. query_escape(onlineCursor) end
		if roomsCursor then path = path .. "&rooms_cursor=" .. query_escape(roomsCursor) end

		self:Request("GET", path, nil, function(ok, decoded, response)
			if not ok or type(decoded) ~= "table" then
				if callback then callback(ok, decoded, response) end
				return
			end

			for _, user in ipairs(decoded.online_users or {}) do
				accumulator.online_users[#accumulator.online_users + 1] = user
			end
			for _, room in ipairs(decoded.public_rooms or {}) do
				accumulator.public_rooms[#accumulator.public_rooms + 1] = room
			end

			local onlineMeta = decoded.meta and decoded.meta.online_users or {}
			local roomsMeta = decoded.meta and decoded.meta.public_rooms or {}
			local hasMoreOnline = onlineMeta.has_more == true and tostring(onlineMeta.next_cursor or "") ~= ""
			local hasMoreRooms = roomsMeta.has_more == true and tostring(roomsMeta.next_cursor or "") ~= ""

			accumulator.meta = decoded.meta or accumulator.meta
			onlineCursor = hasMoreOnline and tostring(onlineMeta.next_cursor) or nil
			roomsCursor = hasMoreRooms and tostring(roomsMeta.next_cursor) or nil

			if (onlineCursor or roomsCursor) and pagesFetched < maxPages then
				fetchPage()
				return
			end

			if accumulator.meta then
				accumulator.meta.online_users = accumulator.meta.online_users or {}
				accumulator.meta.public_rooms = accumulator.meta.public_rooms or {}
				accumulator.meta.online_users.has_more = onlineCursor ~= nil
				accumulator.meta.public_rooms.has_more = roomsCursor ~= nil
				accumulator.meta.online_users.next_cursor = onlineCursor
				accumulator.meta.public_rooms.next_cursor = roomsCursor
			end

			if callback then callback(true, accumulator, response) end
		end)
	end

	fetchPage()
end

function ITGOnline:FetchCurrentRoomFallback(source, minIntervalSeconds)
	local roomId = self.currentRoomId or self.pendingJoinRoomId
	if not roomId or type(self.FetchRoom) ~= "function" then
		return false
	end

	local key = tostring(roomId)
	local now = GetTimeSinceStart()
	local interval = tonumber(minIntervalSeconds) or 0.75
	self.lastCurrentRoomFallbackFetchAtByRoomId = self.lastCurrentRoomFallbackFetchAtByRoomId or {}
	local lastFetchAt = tonumber(self.lastCurrentRoomFallbackFetchAtByRoomId[key]) or 0
	if now - lastFetchAt < interval then
		online_flow_trace("current_room_fallback_fetch_throttled source=" .. tostring(source)
			.. " room=" .. key
			.. " elapsed=" .. string.format("%.3f", now - lastFetchAt)
			.. " interval=" .. string.format("%.3f", interval))
		return false
	end

	self.lastCurrentRoomFallbackFetchAtByRoomId[key] = now
	online_flow_trace("current_room_fallback_fetch_start source=" .. tostring(source) .. " room=" .. key)
	self:FetchRoom(roomId, function(ok, decoded)
		local room = type(decoded) == "table" and decoded.room or nil
		online_flow_trace("current_room_fallback_fetch_done source=" .. tostring(source)
			.. " room=" .. key
			.. " ok=" .. tostring(ok == true)
			.. " hasRoom=" .. tostring(type(room) == "table")
			.. " phase=" .. tostring(type(room) == "table" and room.phase or "nil")
			.. " members=" .. tostring(type(room) == "table" and type(room.members) == "table" and #room.members or 0)
			.. " readyStates=" .. tostring(type(room) == "table" and type(room.ready_states) == "table" and #room.ready_states or 0))
		if ok and type(room) == "table" then
			local applied = self:ApplyRoomSnapshot(room, "current_room_fallback:" .. tostring(source))
			MESSAGEMAN:Broadcast("OnlineLobbyState", self:LobbyStatePayload(applied or room))
			self:BroadcastLeaderboardFromRoom(applied or room, "current_room_fallback:" .. tostring(source))
			if type(self.EnforceRoomPhaseScreen) == "function" then
				self:EnforceRoomPhaseScreen()
			end
		end
	end)

	return true
end

function ITGOnline:ReconcileCurrentRoomFromLobbyPayload(decoded, source)
	if not self.currentRoomId or type(decoded) ~= "table" then
		return false
	end

	local rooms = decoded.public_rooms or decoded.rooms or decoded.lobbies or {}
	if type(rooms) ~= "table" then
		online_flow_trace("current_room_lobby_reconcile_invalid_rooms source=" .. tostring(source)
			.. " room=" .. tostring(self.currentRoomId)
			.. " roomsType=" .. type(rooms))
		return false
	end

	local wantedRoomId = tostring(self.currentRoomId)
	local roomCount = 0
	for _, room in ipairs(rooms) do
		roomCount = roomCount + 1
		if type(room) == "table" then
			local candidateId = room.id or room.room_id or room.roomId or room.code
			if candidateId and tostring(candidateId) == wantedRoomId then
				local selectedSong = room.selected_song or room.selectedSong
				local selectedAt = type(selectedSong) == "table" and (selectedSong.selected_at or selectedSong.selectedAt) or nil
				online_flow_trace("current_room_lobby_reconcile_match source=" .. tostring(source)
					.. " room=" .. wantedRoomId
					.. " phase=" .. tostring(room.phase)
					.. " selectedAt=" .. tostring(selectedAt)
					.. " members=" .. tostring(type(room.members) == "table" and #room.members or 0)
					.. " readyStates=" .. tostring(type(room.ready_states) == "table" and #room.ready_states or 0))
				if self.currentRoom
					and type(room.members) == "table"
					and #room.members == 0
					and type(self.currentRoom.members) == "table"
					and #self.currentRoom.members > 0 then
					online_flow_trace("current_room_lobby_reconcile_empty_members_protected source=" .. tostring(source)
						.. " room=" .. wantedRoomId
						.. " previousMembers=" .. tostring(#self.currentRoom.members)
						.. " incomingPhase=" .. tostring(room.phase)
						.. " currentPhase=" .. tostring(self.currentRoom.phase or "nil"))
				end
				online_flow_trace("current_room_lobby_reconcile_skipped_apply reason=lobby_payload_not_authoritative"
					.. " source=" .. tostring(source)
					.. " room=" .. wantedRoomId
					.. " phase=" .. tostring(room.phase)
					.. " selectedAt=" .. tostring(selectedAt)
					.. " members=" .. tostring(type(room.members) == "table" and #room.members or 0)
					.. " readyStates=" .. tostring(type(room.ready_states) == "table" and #room.ready_states or 0)
					.. " currentPhase=" .. tostring(self.currentRoom and self.currentRoom.phase or "nil"))
				self:FetchCurrentRoomFallback("lobby_refresh_current_room_match", 0.25)
				return true
			end
		end
	end

	online_flow_trace("current_room_lobby_reconcile_miss source=" .. tostring(source)
		.. " room=" .. wantedRoomId
		.. " roomCount=" .. tostring(roomCount))
	return false
end

function ITGOnline:PurgeStaleLobbyCandidate(roomId, reason)
	local roomKey = self:RoomKey(roomId)
	if roomKey == "" then
		return false
	end

	local cachedPayload = self.cachedLobbySearchPayload or { lobbies = {}, onlinePlayers = {} }
	local filteredLobbies = {}
	local removed = false

	for _, lobby in ipairs(cachedPayload.lobbies or {}) do
		local lobbyKey = self:RoomKey(lobby and (lobby.roomId or lobby.code or lobby.id))
		if lobbyKey == roomKey then
			removed = true
		else
			filteredLobbies[#filteredLobbies + 1] = lobby
		end
	end

	if ScreenOnlineLobbiesRemoveLobbyCandidateByCode then
		removed = ScreenOnlineLobbiesRemoveLobbyCandidateByCode(roomKey) or removed
	end

	if removed then
		self.cachedLobbySearchPayload = {
			lobbies = filteredLobbies,
			onlinePlayers = cachedPayload.onlinePlayers or {},
		}
		online_flow_trace(
			"lobby_refresh_removed_stale_candidate room=" .. tostring(roomKey) ..
			" reason=" .. tostring(reason or "unknown"))
		MESSAGEMAN:Broadcast("LobbySearched", self.cachedLobbySearchPayload)
	end

	self:QueueLobbyRefresh({ ignoreSuppression = true, reason = "purge_stale_lobby_candidate:" .. tostring(reason or "unknown") })
	return removed
end

function ITGOnline:ResetPostRoomExitLobbyRefreshState(reason)
	local source = tostring(reason or "unknown")
	self.lobbyRefreshInFlight = false
	self.lobbyRefreshQueued = false
	self.lobbyRefreshQueuedReason = ""
	self.lobbyRefreshQueuedAt = 0
	self.lobbyRefreshDeferredScheduled = false
	self.deferredLobbyRefreshReason = ""
	self.deferredLobbyRefreshRoomUiGeneration = nil
	self.lobbyRefreshSuppressedUntil = nil
	self.lobbyRefreshDropUntil = nil
	self.postRoomExitLobbyRefreshPending = true
	self.postRoomExitLobbyRefreshReason = source
	self.postRoomExitLobbyRefreshRequestedAt = GetTimeSinceStart()
	online_flow_trace("post_room_exit_lobby_refresh_state_reset reason=" .. source
		.. " screen=" .. tostring(self.currentScreenName or "nil")
		.. " currentRoomId=" .. tostring(self.currentRoomId or "nil")
		.. " pendingJoinRoomId=" .. tostring(self.pendingJoinRoomId or "nil"))
end

function ITGOnline:QueuePostRoomExitLobbyRefresh(reason, delay)
	local source = tostring(reason or self.postRoomExitLobbyRefreshReason or "unknown")
	self:ResetPostRoomExitLobbyRefreshState(source)
	local refreshDelay = math.max(0.05, tonumber(delay) or 0.20)
	online_flow_trace("post_room_exit_lobby_refresh_scheduled reason=" .. source
		.. " delay=" .. tostring(refreshDelay)
		.. " screen=" .. tostring(self.currentScreenName or "nil"))
	self:ScheduleDeferredLobbyRefresh(refreshDelay, "post_room_exit:" .. source)
	return true
end

function ITGOnline:ShouldSuppressLobbyCandidate(roomId, reason)
	local roomKey = self:RoomKey(roomId)
	if roomKey == "" then
		return false
	end

	local deleted = self.deletedRoomIds and self.deletedRoomIds[roomKey] == true
	local ignored = self:ShouldIgnoreRoomEvents(roomKey)
	local suppressed = deleted
	if suppressed then
		online_flow_trace("lobby_candidate_suppressed"
			.. " room=" .. tostring(roomKey)
			.. " reason=" .. tostring(reason or "unknown")
			.. " deleted=" .. tostring(deleted == true)
			.. " ignored=" .. tostring(ignored == true))
	elseif ignored then
		online_flow_trace("lobby_candidate_visible_despite_recent_room_ignore"
			.. " room=" .. tostring(roomKey)
			.. " reason=" .. tostring(reason or "unknown"))
	end
	return suppressed
end

	function ITGOnline:QueueLobbyRefresh(options)
		options = type(options) == "table" and options or {}
		local ignoreSuppression = options.ignoreSuppression == true
		local refreshReason = tostring(options.reason or "unknown")
		local refreshScreen = tostring(self.currentScreenName or "nil")
		local forceFresh = options.forceFresh == true
			or refreshReason:match("^post_room_exit:") ~= nil
			or (self.currentRoomId == nil and self:IsOnlineLobbyScreen(refreshScreen) and refreshReason:match("refresh") ~= nil)
		local refreshIsGameplay = self:IsOnlineGameplayScreen(refreshScreen)
		local now = GetTimeSinceStart()
		local recentRoomSnapshotAge = now - (tonumber(self.lastAuthoritativeRoomSnapshotAt) or 0)
		local automaticRoomUiRefresh = refreshReason:match("^coalesced:queued_after_response:") ~= nil
			or refreshReason:match("^queued_after_response:") ~= nil
			or refreshReason:match("^room_ui_refresh:") ~= nil
			or refreshReason == "lobby_refresh_current_room:fetch_lobby"
		if not ignoreSuppression
			and self.currentRoomId
			and automaticRoomUiRefresh
			and recentRoomSnapshotAge >= 0
			and recentRoomSnapshotAge < 0.50 then
			online_flow_trace("lobby_refresh_skipped reason=recent_room_snapshot"
				.. " requestReason=" .. refreshReason
				.. " age=" .. string.format("%.3f", recentRoomSnapshotAge)
				.. " currentRoomId=" .. tostring(self.currentRoomId or "nil")
				.. " snapshotSource=" .. tostring(self.lastAuthoritativeRoomSnapshotSource or "nil")
				.. " screen=" .. refreshScreen)
			return
		end
		if self.currentRoomId == nil and not ignoreSuppression and self:IsPostLeaveLobbyRefreshReason(refreshReason) then
			local lastPostLeaveAt = tonumber(self.lastPostLeaveLobbyRefreshAt) or 0
			if refreshReason == "leave_room_confirmed" or lastPostLeaveAt <= 0 then
				self.lastPostLeaveLobbyRefreshAt = now
				self.lastPostLeaveLobbyRefreshReason = refreshReason
			elseif now - lastPostLeaveAt < 0.8 then
				online_flow_trace("lobby_refresh_skipped reason=post_leave_coalesced"
					.. " requestReason=" .. refreshReason
					.. " previousReason=" .. tostring(self.lastPostLeaveLobbyRefreshReason or "nil")
					.. " age=" .. string.format("%.3f", now - lastPostLeaveAt))
				return
			else
				self.lastPostLeaveLobbyRefreshAt = now
				self.lastPostLeaveLobbyRefreshReason = refreshReason
			end
		end
		online_flow_trace("lobby_refresh_queue_begin screen=" .. refreshScreen
			.. " generation=" .. tostring(self.screenGeneration or "nil")
			.. " currentRoomId=" .. tostring(self.currentRoomId or "nil")
			.. " pendingJoinRoomId=" .. tostring(self.pendingJoinRoomId or "nil")
			.. " inFlight=" .. tostring(self.lobbyRefreshInFlight == true)
			.. " queued=" .. tostring(self.lobbyRefreshQueued == true)
			.. " deferred=" .. tostring(self.lobbyRefreshDeferredScheduled == true)
			.. " reason=" .. refreshReason
			.. " ignoreSuppression=" .. tostring(ignoreSuppression == true)
			.. " forceFresh=" .. tostring(forceFresh == true)
			.. " autoSuppressed=" .. tostring(self:IsAutomaticLobbyRefreshSuppressed() == true)
			.. " suppressed=" .. tostring(self:IsLobbyRefreshSuppressed() == true))
		if forceFresh then
			self.lobbyRefreshSuppressedUntil = nil
			self.lobbyRefreshDropUntil = nil
			if self.lobbyRefreshInFlight then
				online_flow_trace("lobby_refresh_force_fresh_reset_inflight reason=" .. refreshReason
					.. " queuedReason=" .. tostring(self.lobbyRefreshQueuedReason or "nil")
					.. " screen=" .. refreshScreen)
				self.lobbyRefreshInFlight = false
			end
			self.lobbyRefreshQueued = false
			self.lobbyRefreshQueuedReason = ""
			self.lobbyRefreshQueuedAt = 0
			self.lobbyRefreshDeferredScheduled = false
			self.deferredLobbyRefreshReason = ""
			self.deferredLobbyRefreshRoomUiGeneration = nil
		end
		if not ignoreSuppression and self:IsAutomaticLobbyRefreshSuppressed() then
			local remaining = math.max(0.05, (tonumber(self.lobbyRefreshDropUntil) or 0) - GetTimeSinceStart() + 0.05)
			online_flow_trace("lobby_refresh_deferred reason=post_leave_auto_suppressed delay=" .. tostring(remaining))
			self.lobbyRefreshQueued = true
			if not self.lobbyRefreshDeferredScheduled then
				self:ScheduleDeferredLobbyRefresh(remaining, "post_leave_auto_suppressed")
			end
			return
		end
		if not ignoreSuppression and self:IsLobbyRefreshSuppressed() then
			online_flow_trace("lobby_refresh_skipped reason=suppressed_after_leave")
			self.lobbyRefreshQueued = true
			if not self.lobbyRefreshDeferredScheduled then
				self:ScheduleDeferredLobbyRefresh(
					self:LobbyRefreshSuppressionRemaining() + 0.05,
				"suppressed_before_request")
			end
			return
		end
		if refreshIsGameplay and not ignoreSuppression then
			if self.lobbyRefreshInFlight then
				online_flow_trace_throttled("lobby_refresh_gameplay_inflight_skip", 1.0,
					"lobby_refresh_skipped reason=gameplay_inflight_no_replay"
					.. " requestReason=" .. refreshReason
					.. " screen=" .. refreshScreen
					.. " room=" .. tostring(self.currentRoomId or "nil"))
				return
			end

			local now = GetTimeSinceStart()
			local minInterval = math.max(1.0, tonumber(self.gameplayLobbyRefreshMinIntervalSeconds) or 5.0)
			local elapsed = now - (tonumber(self.lastGameplayLobbyRefreshAt) or 0)
			if elapsed < minInterval then
				online_flow_trace_throttled("lobby_refresh_gameplay_throttled", 1.0,
					"lobby_refresh_skipped reason=gameplay_throttle"
					.. " requestReason=" .. refreshReason
					.. " elapsed=" .. string.format("%.2f", elapsed)
					.. " minInterval=" .. string.format("%.2f", minInterval)
					.. " room=" .. tostring(self.currentRoomId or "nil"))
				return
			end
			self.lastGameplayLobbyRefreshAt = now
		end
		if self.lobbyRefreshInFlight then
			local previousReason = tostring(self.lobbyRefreshQueuedReason or "")
			self.lobbyRefreshQueued = true
			self.lobbyRefreshQueuedReason = refreshReason
			self.lobbyRefreshQueuedAt = GetTimeSinceStart()
			online_flow_trace("lobby_refresh_join_inflight queued=true"
				.. " reason=" .. refreshReason
				.. " previousReason=" .. tostring(previousReason ~= "" and previousReason or "nil"))
			return
		end
		self.lobbyRefreshDeferredScheduled = false

		self.lobbyRefreshInFlight = true
		local refreshPurpose = "background_state_tracking"
		if self:IsOnlineLobbyScreen(refreshScreen) then
			refreshPurpose = "lobby_ui_and_state"
		elseif self:IsOnlineOptionsScreen(refreshScreen) then
			refreshPurpose = "options_room_state_tracking"
		elseif self:IsOnlineGameplayScreen(refreshScreen) then
			refreshPurpose = "gameplay_room_state_tracking"
		end
		online_flow_trace("lobby_refresh_request screen=" .. tostring(self.currentScreenName or "nil")
			.. " room=" .. tostring(self.currentRoomId or "nil")
			.. " phase=" .. tostring(self.currentRoom and self.currentRoom.phase or "nil")
			.. " purpose=" .. tostring(refreshPurpose))
		self:FetchLobby(function(ok, decoded)
			self.lobbyRefreshInFlight = false
			if forceFresh then
				self.postRoomExitLobbyRefreshPending = false
				self.postRoomExitLobbyRefreshReason = ""
			end
			if self.disconnecting or not self.token then
				self.lobbyRefreshQueued = false
				self.lobbyRefreshQueuedReason = ""
				self.lobbyRefreshQueuedAt = 0
				online_flow_trace("lobby_refresh_response_dropped reason=disconnecting_or_logged_out"
					.. " ok=" .. tostring(ok == true)
					.. " screen=" .. tostring(self.currentScreenName or "nil")
					.. " disconnecting=" .. tostring(self.disconnecting == true)
					.. " hasToken=" .. tostring(self.token ~= nil))
				return
			end
			local rawPublicRoomCount = decoded and decoded.public_rooms and #decoded.public_rooms
				or decoded and decoded.lobbies and #decoded.lobbies
				or 0
			local rawOnlineUserCount = decoded and decoded.online_users and #decoded.online_users
				or decoded and decoded.online_players and #decoded.online_players
				or decoded and decoded.onlinePlayers and #decoded.onlinePlayers
				or 0
			online_flow_trace("lobby_refresh_response ok=" .. tostring(ok == true)
				.. " rawPublicRooms=" .. tostring(rawPublicRoomCount)
				.. " rawOnlineUsers=" .. tostring(rawOnlineUserCount)
				.. " queued=" .. tostring(self.lobbyRefreshQueued == true)
				.. " screen=" .. tostring(self.currentScreenName or "nil")
				.. " room=" .. tostring(self.currentRoomId or "nil")
				.. " currentRoomWillBeMerged=" .. tostring(self.currentRoom ~= nil))
				if ok then
					if not ignoreSuppression and self:IsAutomaticLobbyRefreshSuppressed() then
						local remaining = math.max(0.05, (tonumber(self.lobbyRefreshDropUntil) or 0) - GetTimeSinceStart() + 0.05)
						online_flow_trace("lobby_refresh_result_deferred reason=post_leave_auto_suppressed delay=" .. tostring(remaining))
						self.lobbyRefreshQueued = true
						if not self.lobbyRefreshDeferredScheduled then
							self:ScheduleDeferredLobbyRefresh(remaining, "post_leave_response")
						end
						return
					end
					if not ignoreSuppression and self:IsLobbyRefreshSuppressed() then
						online_flow_trace("lobby_refresh_result_dropped reason=suppressed_after_leave")
						self.lobbyRefreshQueued = true
						if not self.lobbyRefreshDeferredScheduled then
						self:ScheduleDeferredLobbyRefresh(
							self:LobbyRefreshSuppressionRemaining() + 0.05,
							"suppressed_after_response")
					end
				else
					local lobbyPayload = self:LobbySearchPayload(decoded)
					local currentRoomMerged = self:ReconcileCurrentRoomFromLobbyPayload(decoded, "fetch_lobby")
					if self.currentRoomId and not currentRoomMerged then
						self:FetchCurrentRoomFallback("lobby_refresh_missing_current_room", 0.75)
					end
					self.lobbyRefreshLastAppliedAt = GetTimeSinceStart()
					online_flow_trace("lobby_refresh_broadcast source=fetch_lobby"
						.. " rawPublicRooms=" .. tostring(rawPublicRoomCount)
						.. " rawOnlineUsers=" .. tostring(rawOnlineUserCount)
						.. " normalizedLobbies=" .. tostring(#(lobbyPayload.lobbies or {}))
						.. " displayOnlinePlayers=" .. tostring(#(lobbyPayload.onlinePlayers or {})))
					MESSAGEMAN:Broadcast("LobbySearched", lobbyPayload)
				end
			end
		if self.lobbyRefreshQueued and not self.disconnecting then
			local queuedReason = tostring(self.lobbyRefreshQueuedReason or "")
			self.lobbyRefreshQueued = false
			self.lobbyRefreshQueuedReason = ""
			self.lobbyRefreshQueuedAt = 0
			online_flow_trace("lobby_refresh_replay_coalesced reason=" .. tostring(queuedReason ~= "" and queuedReason or "queued_after_response"))
			self:ScheduleCoalescedLobbyRefresh("queued_after_response:" .. tostring(queuedReason ~= "" and queuedReason or "unknown"))
		end
	end)
end

function ITGOnline:ApplyLobbyPresencePayload(payload)
	if type(payload) ~= "table" or type(payload.user) ~= "table" then
		online_flow_trace("lobby_presence_payload_ignored reason=invalid_payload hasPayload=" .. tostring(type(payload) == "table")
			.. " hasUser=" .. tostring(type(payload) == "table" and type(payload.user) == "table"))
		return false
	end

	local user = payload.user
	if self.user and tonumber(user.id) == tonumber(self.user.id) then
		online_flow_trace("lobby_presence_payload_ignored reason=self_user userId=" .. tostring(user.id or "nil"))
		return false
	end

	local cachedPayload = self.cachedLobbySearchPayload or { lobbies = {}, onlinePlayers = {} }
	local onlinePlayers = {}
	local found = false
	local status = tostring(user.status or payload.status or "available")
	local shouldRemove = status == "offline" or status == "disconnected" or status == "left"
	online_flow_trace("lobby_presence_payload_begin userId=" .. tostring(user.id or "nil")
		.. " status=" .. tostring(status)
		.. " shouldRemove=" .. tostring(shouldRemove == true)
		.. " cachedOnlinePlayers=" .. tostring(cachedPayload.onlinePlayers and #cachedPayload.onlinePlayers or 0)
		.. " cachedLobbies=" .. tostring(cachedPayload.lobbies and #cachedPayload.lobbies or 0)
		.. " screen=" .. tostring(self.currentScreenName or "nil"))

	for player in ivalues(cachedPayload.onlinePlayers or {}) do
		if tostring(player.id or "") == tostring(user.id or "") then
			if not shouldRemove then
				onlinePlayers[#onlinePlayers + 1] = {
					id = user.id,
					name = user_display_name(user, player.name or ("User " .. tostring(user.id or "?"))),
					displayName = user.display_name or user.displayName or player.displayName or player.display_name or player.name,
					status = status ~= "" and status or player.status or "available",
					room = user.room,
					lastSeenAt = user.last_seen_at or player.lastSeenAt,
					isSelf = false,
				}
			end
			found = true
		else
			onlinePlayers[#onlinePlayers + 1] = player
		end
	end

	if not found and not shouldRemove and user.id ~= nil then
		onlinePlayers[#onlinePlayers + 1] = {
			id = user.id,
			name = user_display_name(user, "User " .. tostring(user.id or "?")),
			displayName = user.display_name or user.displayName or user.name,
			status = status ~= "" and status or "available",
			room = user.room,
			lastSeenAt = user.last_seen_at,
			isSelf = false,
		}
	end

	self.cachedLobbySearchPayload = {
		lobbies = cachedPayload.lobbies or {},
		onlinePlayers = onlinePlayers,
	}
	online_flow_trace("lobby_presence_payload_applied userId=" .. tostring(user.id or "nil")
		.. " found=" .. tostring(found == true)
		.. " removed=" .. tostring(shouldRemove == true)
		.. " onlinePlayers=" .. tostring(#onlinePlayers)
		.. " lobbies=" .. tostring(self.cachedLobbySearchPayload.lobbies and #self.cachedLobbySearchPayload.lobbies or 0))

	return true
end

function ITGOnline:FetchCurrentRoom(callback)
	online_flow_trace("fetch_current_room_begin screen=" .. tostring(self.currentScreenName or "nil")
		.. " currentRoomId=" .. tostring(self.currentRoomId or "nil")
		.. " pendingJoinRoomId=" .. tostring(self.pendingJoinRoomId or "nil"))
	self:TraceOnlineState("fetch_current_room_begin", {
		source = "fetch_current_room",
		pendingJoinRoomId = self.pendingJoinRoomId or "nil",
	})
	self:Request("GET", "/rooms/current", nil, function(ok, decoded, response)
			online_flow_trace("fetch_current_room_response ok=" .. tostring(ok == true)
				.. " status=" .. tostring(response and response.statusCode or "nil")
				.. " hasRoom=" .. tostring(decoded and decoded.room ~= nil)
				.. " phase=" .. tostring(decoded and decoded.room and decoded.room.phase or "nil")
				.. " room=" .. tostring(decoded and decoded.room and decoded.room.id or "nil"))
			self:TraceOnlineState("fetch_current_room_response", {
				source = "fetch_current_room",
				roomSnapshot = decoded and decoded.room or nil,
				ok = ok == true,
				status = response and response.statusCode or "nil",
				hasRoom = decoded and decoded.room ~= nil,
				conflict = decoded and decoded.error_code or "nil",
			})
			if ok and decoded and decoded.room then
				self:ClearCurrentRoomBlocked("fetch_current_room")
				local room = self:ApplyRoomSnapshot(decoded.room, "fetch_current_room")
				decoded.room = room or decoded.room
				self.pendingJoinRequestId = nil
			else
				local conflictCode, openRoomCount = self:CurrentRoomConflictCode(decoded, response)
				if conflictCode ~= "" then
					self:SetCurrentRoomBlocked(conflictCode, openRoomCount, "fetch_current_room")
				end
			end
		if callback then callback(ok, decoded, response) end
	end)
end

function ITGOnline:CreateRoom(callback, visibility)
	local roomName = local_profile_name() .. "'s room"
	online_flow_trace("create_room_begin visibility=" .. tostring(visibility or "public")
		.. " name=" .. tostring(roomName)
		.. " screen=" .. tostring(self.currentScreenName or "nil"))
	self:TraceOnlineState("create_room_begin", {
		source = "create_room",
		visibility = visibility or "public",
		roomName = roomName,
	})
	self:Request("POST", "/rooms", { name = roomName, visibility = visibility or "public" }, function(ok, decoded, response)
		online_flow_trace("create_room_response ok=" .. tostring(ok == true)
			.. " status=" .. tostring(response and response.statusCode or "nil")
			.. " hasRoom=" .. tostring(decoded and decoded.room ~= nil)
			.. " room=" .. tostring(decoded and decoded.room and decoded.room.id or "nil")
			.. " phase=" .. tostring(decoded and decoded.room and decoded.room.phase or "nil"))
		self:TraceOnlineState("create_room_response", {
			source = "create_room",
			roomSnapshot = decoded and decoded.room or nil,
			ok = ok == true,
			status = response and response.statusCode or "nil",
			hasRoom = decoded and decoded.room ~= nil,
			error = decoded and decoded.error_code or response and response.errorMessage or "nil",
		})
		if ok and decoded and decoded.room then
			local room = self:ApplyRoomSnapshot(decoded.room, "create_room")
			decoded.room = room or decoded.room
		end
		if callback then callback(ok, decoded, response) end
	end)
end

function ITGOnline:RequestJoinRoom(roomId, callback)
	online_flow_trace("join_room_begin room=" .. tostring(roomId)
		.. " currentRoomId=" .. tostring(self.currentRoomId or "nil")
		.. " pendingJoinRoomId=" .. tostring(self.pendingJoinRoomId or "nil")
		.. " screen=" .. tostring(self.currentScreenName or "nil"))
	self:TraceOnlineState("join_room_begin", {
		source = "join_room",
		targetRoom = roomId,
		pendingJoinRoomId = self.pendingJoinRoomId or "nil",
	})
	self.pendingJoinRoomId = roomId
	local roomKey = self:RoomKey(roomId)
	if roomKey ~= "" and self.ignoredRoomEventsUntil then
		self.ignoredRoomEventsUntil[roomKey] = nil
	end
	self:MarkLeavingRoom(roomId, false)
			self:Request("POST", "/rooms/" .. tostring(roomId) .. "/join", {}, function(ok, decoded, response)
			online_flow_trace("join_room_response room=" .. tostring(roomId)
				.. " ok=" .. tostring(ok == true)
				.. " status=" .. tostring(response and response.statusCode or "nil")
				.. " hasRoom=" .. tostring(decoded and decoded.room ~= nil)
				.. " phase=" .. tostring(decoded and decoded.room and decoded.room.phase or "nil")
				.. " currentRoomId=" .. tostring(self.currentRoomId or "nil")
				.. " pendingJoinRoomId=" .. tostring(self.pendingJoinRoomId or "nil"))
			self:TraceOnlineState("join_room_response", {
				source = "join_room",
				roomSnapshot = decoded and decoded.room or nil,
				targetRoom = roomId,
				ok = ok == true,
				status = response and response.statusCode or "nil",
				hasRoom = decoded and decoded.room ~= nil,
				error = decoded and decoded.error_code or response and response.errorMessage or "nil",
				pendingJoinRoomId = self.pendingJoinRoomId or "nil",
			})
			if ok and decoded and decoded.room then
				local room = self:ApplyRoomSnapshot(decoded.room, "join_room")
				decoded.room = room or decoded.room
				self.pendingJoinRoomId = nil
				self.pendingJoinRequestId = nil
			elseif not ok then
				local statusCode = response and tonumber(response.statusCode) or nil
				if statusCode == 404 or statusCode == 410 or statusCode == 422 then
					self:PurgeStaleLobbyCandidate(roomId, "join_failed_" .. tostring(statusCode))
				end
				self.pendingJoinRoomId = nil
				self.pendingJoinRequestId = nil
			end
			if callback then callback(ok, decoded, response) end
		end)
	end

	function ITGOnline:CancelJoinRequest(callback)
		local joinRequestId = self.pendingJoinRequestId
		if not joinRequestId then
			self.pendingJoinRoomId = nil
			if callback then callback(true, { message = "No pending join request." }, nil) end
			return
		end

		self.pendingJoinRoomId = nil
		self.pendingJoinRequestId = nil
		self:Request("POST", "/room-join-requests/" .. tostring(joinRequestId) .. "/cancel", {}, callback)
	end

function ITGOnline:ReportSongAvailability(missing, reason, callback)
	online_flow_trace("song_availability_begin"
		.. " room=" .. tostring(self.currentRoomId or "nil")
		.. " missing=" .. tostring(missing == true)
		.. " reason=" .. tostring(reason or "nil")
		.. " phase=" .. tostring(self.currentRoom and self.currentRoom.phase or "nil")
		.. " selectedAt="
			.. tostring(self.currentRoom and self.currentRoom.selected_song and (self.currentRoom.selected_song.selected_at or self.currentRoom.selected_song.selectedAt) or "nil"))
	if not self.currentRoomId then
		online_flow_trace("song_availability_failed reason=no_current_room missing=" .. tostring(missing == true)
			.. " reportReason=" .. tostring(reason or "nil"))
		if callback then callback(false, nil, { errorMessage = "No active online room." }) end
		return
	end

	local payload = {
		missing = missing and true or false,
		reason = missing and (reason or "unknown") or "reloaded",
	}
	local selectedSong = self.currentRoom and self.currentRoom.selected_song or {}
	local selectedPayload = self.CurrentSelectedSongPayload and self:CurrentSelectedSongPayload() or nil
	local selectedAt = (selectedPayload and (selectedPayload.selected_at or selectedPayload.selectedAt))
		or (selectedSong and (selectedSong.selected_at or selectedSong.selectedAt))
	online_flow_trace("song_availability_payload_context"
		.. " room=" .. tostring(self.currentRoomId or "nil")
		.. " selectedAt=" .. tostring(selectedAt or "nil")
		.. " hasSelectedPayload=" .. tostring(selectedPayload ~= nil)
		.. " hasSelectedSong=" .. tostring(selectedSong ~= nil)
		.. " selectedSongHash=" .. tostring(selectedPayload and selectedPayload.song_hash or selectedSong and selectedSong.song_hash or "nil")
		.. " selectedChartHash=" .. tostring(selectedPayload and selectedPayload.chart_hash or selectedSong and selectedSong.chart_hash or "nil"))
	if selectedAt ~= nil and tostring(selectedAt) ~= "" then
		payload.selected_at = tostring(selectedAt)
	end

	if not missing then
		if self:IsSongReloadOrDownloadActive("song_availability:" .. tostring(reason or "unknown")) then
			online_flow_trace("song_availability_deferred reason=download_or_reload_active"
				.. " room=" .. tostring(self.currentRoomId or "nil")
				.. " reportReason=" .. tostring(reason or "nil"))
			if callback then
				callback(false, nil, {
					statusCode = 0,
					errorMessage = "download_in_progress",
					downloadInProgress = true,
					retryAfter = 0.75,
				})
			end
			return
		end
		local expectedSong = selectedPayload or selectedSong or {}
		local localPayload, localSourceOrReason = self:ResolveSelectedSongAvailabilityPayload(expectedSong, reason)
		if not localPayload then
			online_flow_trace("song_availability_local_check_failed reason=" .. tostring(localSourceOrReason or "local_payload_unavailable")
				.. " selectedAt=" .. tostring(payload.selected_at or "nil")
				.. " selectedSongHash=" .. tostring(expectedSong.song_hash or expectedSong.songHash or "nil")
				.. " selectedChartHash=" .. tostring(expectedSong.chart_hash or expectedSong.chartHash or "nil"))
			self:ReportSongAvailability(true, localSourceOrReason or "local_payload_unavailable", callback)
			return
		end
		online_flow_trace("song_availability_local_payload"
			.. " room=" .. tostring(self.currentRoomId or "nil")
			.. " selectedAt=" .. tostring(payload.selected_at or "nil")
			.. " source=" .. tostring(localSourceOrReason or "unknown")
			.. " songHash=" .. tostring(localPayload.song_hash or "nil")
			.. " chartHash=" .. tostring(localPayload.chart_hash or "nil")
			.. " chartNoteCount=" .. tostring(localPayload.chart_note_count or "nil")
			.. " maxScore=" .. tostring(localPayload.max_score or "nil"))
		payload.song_hash = localPayload.song_hash
		payload.chart_hash = localPayload.chart_hash
		payload.chart_note_count = localPayload.chart_note_count
		payload.max_score = localPayload.max_score
	end

	local availabilityKey = table.concat({
		tostring(self.currentRoomId or ""),
		tostring(payload.selected_at or selectedSong.selected_at or selectedSong.selectedAt or ""),
		missing and "missing" or "available",
		tostring(payload.song_hash or selectedSong.song_hash or ""),
		tostring(payload.chart_hash or selectedSong.chart_hash or ""),
		tostring(payload.reason or ""),
	}, "|")
	if self.songAvailabilityInFlightKey == availabilityKey then
		if callback then
			self.songAvailabilityInFlightCallbacks[#self.songAvailabilityInFlightCallbacks + 1] = callback
		end
		online_flow_trace("song_availability_join_inflight key=" .. tostring(availabilityKey)
			.. " callbacks=" .. tostring(#self.songAvailabilityInFlightCallbacks)
			.. " missing=" .. tostring(missing == true)
			.. " reason=" .. tostring(payload.reason or "nil"))
		return
	end
	if self.songAvailabilityReportedKey == availabilityKey then
		online_flow_trace("song_availability_skipped reason=already_reported key=" .. tostring(availabilityKey))
		if callback then callback(true, nil, { duplicate = true }) end
		return
	end
	local suppressedUntil = tonumber(self.songAvailabilitySuppressedUntil[availabilityKey]) or 0
	if suppressedUntil > GetTimeSinceStart() then
		online_flow_trace("song_availability_skipped reason=suppressed key=" .. tostring(availabilityKey)
			.. " remaining=" .. tostring(suppressedUntil - GetTimeSinceStart()))
		if callback then callback(true, nil, { duplicate = true, suppressed = true }) end
		return
	end
	self.songAvailabilityInFlightKey = availabilityKey
	self.songAvailabilityInFlightCallbacks = callback and { callback } or {}
	online_flow_trace("song_availability_request key=" .. tostring(availabilityKey)
		.. " room=" .. tostring(self.currentRoomId)
		.. " missing=" .. tostring(missing == true)
		.. " reason=" .. tostring(payload.reason or "nil")
		.. " selectedAt=" .. tostring(payload.selected_at or "nil")
		.. " songHash=" .. tostring(payload.song_hash or "nil")
		.. " chartHash=" .. tostring(payload.chart_hash or "nil"))

	self:Request("POST", "/rooms/" .. tostring(self.currentRoomId) .. "/song-availability", payload, function(ok, decoded, response)
		local callbacks = self.songAvailabilityInFlightCallbacks or {}
		local availabilityResult = decoded and decoded.song_availability or nil
		local ignored = ok and availabilityResult and availabilityResult.applied == false
		local callbackOk = ok and not ignored
		if self.songAvailabilityInFlightKey == availabilityKey then
			self.songAvailabilityInFlightKey = ""
			self.songAvailabilityInFlightCallbacks = {}
		end
		if ignored then
			decoded.error_code = decoded.error_code or "song_availability_ignored"
			decoded.message = decoded.message or "Song availability update was ignored for a stale selection."
			response = response or {}
			response.errorMessage = response.errorMessage or decoded.message
			online_flow_trace("song_availability_ignored key=" .. tostring(availabilityKey)
				.. " reason=" .. tostring(availabilityResult and availabilityResult.ignored_reason or "unknown"))
		end
		if callbackOk then
			self.songAvailabilityReportedKey = availabilityKey
		elseif not ignored and not (response and tonumber(response.statusCode) == 401) then
			self.songAvailabilitySuppressedUntil[availabilityKey] = GetTimeSinceStart()
				+ (tonumber(self.songAvailabilityFailureDedupSeconds) or 5)
		end
		online_flow_trace("song_availability_response key=" .. tostring(availabilityKey)
			.. " ok=" .. tostring(ok == true)
			.. " callbackOk=" .. tostring(callbackOk == true)
			.. " ignored=" .. tostring(ignored == true)
			.. " status=" .. tostring(response and response.statusCode or "nil")
			.. " error=" .. tostring(decoded and decoded.error_code or response and response.errorMessage or "nil")
			.. " hasRoom=" .. tostring(decoded and decoded.room ~= nil)
			.. " roomPhase=" .. tostring(decoded and decoded.room and decoded.room.phase or "nil")
			.. " callbacks=" .. tostring(#callbacks))
		if ok and decoded and decoded.room then
			local room = self:ApplyRoomSnapshot(decoded.room, "song_availability")
			decoded.room = room or decoded.room
				if missing then
					self.songLoadedAckKey = ""
					self.songLoadedInFlightKey = ""
					self.songLoadedPendingCallbacks = {}
				end
			MESSAGEMAN:Broadcast("OnlineLobbyState", self:LobbyStatePayload(room or decoded.room))
			if not missing and self.EnforceRoomPhaseScreen then
				self:EnforceRoomPhaseScreen()
			end
		end
		for cb in ivalues(callbacks) do
			if cb then cb(callbackOk, decoded, response) end
		end
	end)
end

function ITGOnline:ConfirmSelectedSongAvailability(reason, callback)
	online_flow_trace("song_availability_confirm_selected reason=" .. tostring(reason or "nil")
		.. " room=" .. tostring(self.currentRoomId or "nil")
		.. " phase=" .. tostring(self.currentRoom and self.currentRoom.phase or "nil"))
	self:ReportSongAvailability(false, "reloaded", callback)
end

function ITGOnline:RequestJoinUserRoom(userId, callback)
		self:TraceOnlineState("join_user_room_request", {
			source = "request_join_user_room",
			targetUser = userId,
			pendingJoinRoomId = self.pendingJoinRoomId or "nil",
		})
		self:Request("POST", "/users/" .. tostring(userId) .. "/room-join-request", {}, function(ok, decoded, response)
			self:TraceOnlineState("join_user_room_response", {
				source = "request_join_user_room",
				roomSnapshot = decoded and decoded.room or nil,
				targetUser = userId,
				ok = ok == true,
				status = response and response.statusCode or "nil",
				hasRoom = decoded and decoded.room ~= nil,
				hasJoinRequest = decoded and decoded.join_request ~= nil,
				error = decoded and decoded.error_code or response and response.errorMessage or "nil",
			})
			if ok and decoded and decoded.room then
				local room = self:ApplyRoomSnapshot(decoded.room, "request_join_user_room")
				decoded.room = room or decoded.room
				self.pendingJoinRoomId = nil
				self.pendingJoinRequestId = nil
			elseif ok and decoded and decoded.join_request then
				self.pendingJoinRoomId = decoded.join_request.room_id
				self.pendingJoinRequestId = decoded.join_request.id
			elseif not ok then
				self.pendingJoinRoomId = nil
				self.pendingJoinRequestId = nil
			end
			if callback then callback(ok, decoded, response) end
		end)
	end

function ITGOnline:InviteUser(roomId, userId, callback)
	self:TraceOnlineState("invite_user_request", {
		source = "invite_user",
		targetRoom = roomId,
		targetUser = userId,
	})
	self:Request("POST", "/rooms/" .. tostring(roomId) .. "/invitations", {
		user_id = tonumber(userId) or userId,
	}, function(ok, decoded, response)
		self:TraceOnlineState("invite_user_response", {
			source = "invite_user",
			targetRoom = roomId,
			targetUser = userId,
			ok = ok == true,
			status = response and response.statusCode or "nil",
			error = decoded and decoded.error_code or response and response.errorMessage or "nil",
			hasInvitation = decoded and decoded.invitation ~= nil,
		})
		if callback then callback(ok, decoded, response) end
	end)
end

function ITGOnline:InviteUserToNewRoom(userId, visibility, callback)
	self:TraceOnlineState("invite_user_to_new_room_begin", {
		source = "invite_user_to_new_room",
		targetUser = userId,
		visibility = visibility or "private",
	})
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
	self:TraceOnlineState("accept_invitation_request", {
		source = "accept_invitation",
		invitationId = invitationId,
	})
	self:Request("POST", "/room-invitations/" .. tostring(invitationId) .. "/accept", {}, function(ok, decoded, response)
		self:TraceOnlineState("accept_invitation_response", {
			source = "accept_invitation",
			roomSnapshot = decoded and decoded.room or nil,
			invitationId = invitationId,
			ok = ok == true,
			status = response and response.statusCode or "nil",
			hasRoom = decoded and decoded.room ~= nil,
			error = decoded and decoded.error_code or response and response.errorMessage or "nil",
		})
		if ok and decoded and decoded.room then
			local room = self:ApplyRoomSnapshot(decoded.room, "accept_invitation")
			decoded.room = room or decoded.room
			MESSAGEMAN:Broadcast("OnlineLobbyState", self:LobbyStatePayload(room or decoded.room))
		end
		if callback then callback(ok, decoded, response) end
	end)
end

function ITGOnline:DeclineInvitation(invitationId, callback)
	self:TraceOnlineState("decline_invitation_request", {
		source = "decline_invitation",
		invitationId = invitationId,
	})
	self:Request("POST", "/room-invitations/" .. tostring(invitationId) .. "/decline", {}, function(ok, decoded, response)
		self:TraceOnlineState("decline_invitation_response", {
			source = "decline_invitation",
			invitationId = invitationId,
			ok = ok == true,
			status = response and response.statusCode or "nil",
			error = decoded and decoded.error_code or response and response.errorMessage or "nil",
		})
		if callback then callback(ok, decoded, response) end
	end)
end

function ITGOnline:AcceptJoinRequest(joinRequestId, callback)
	self:TraceOnlineState("accept_join_request_request", {
		source = "accept_join_request",
		joinRequestId = joinRequestId,
	})
	self:Request("POST", "/room-join-requests/" .. tostring(joinRequestId) .. "/accept", {}, function(ok, decoded, response)
		self:TraceOnlineState("accept_join_request_response", {
			source = "accept_join_request",
			joinRequestId = joinRequestId,
			ok = ok == true,
			status = response and response.statusCode or "nil",
			error = decoded and decoded.error_code or response and response.errorMessage or "nil",
		})
		if callback then callback(ok, decoded, response) end
	end)
end

function ITGOnline:DeclineJoinRequest(joinRequestId, reason, callback)
	self:TraceOnlineState("decline_join_request_request", {
		source = "decline_join_request",
		joinRequestId = joinRequestId,
		reason = reason or "",
	})
	self:Request("POST", "/room-join-requests/" .. tostring(joinRequestId) .. "/decline", {
		reason = reason or "",
	}, function(ok, decoded, response)
		self:TraceOnlineState("decline_join_request_response", {
			source = "decline_join_request",
			joinRequestId = joinRequestId,
			ok = ok == true,
			status = response and response.statusCode or "nil",
			error = decoded and decoded.error_code or response and response.errorMessage or "nil",
		})
		if callback then callback(ok, decoded, response) end
	end)
end

function ITGOnline:ClearCurrentRoomState(source)
	local previousRoomId = self.currentRoomId
	online_flow_trace("clear_current_room_state_begin source=" .. tostring(source or "unknown")
		.. " previousRoomId=" .. tostring(previousRoomId or "nil")
		.. " previousPhase=" .. tostring(self.currentRoom and self.currentRoom.phase or "nil")
		.. " previousRoundKey=" .. tostring(self.currentRoomRoundKey or "")
		.. " pendingJoinRoomId=" .. tostring(self.pendingJoinRoomId or "nil")
		.. " currentSong=" .. tostring(self.currentSongPayload ~= nil)
		.. " lastResultSong=" .. tostring(self.lastResultSongPayload ~= nil))
	if previousRoomId then
		local sourceKey = tostring(source or "")
		if sourceKey:find("leave_room", 1, true) or sourceKey:find("room_deleted", 1, true) then
			self:IgnoreRoomEvents(previousRoomId, 30)
		else
			self:MarkLeavingRoom(previousRoomId, false)
		end
	end
	self.currentRoomId = nil
	self.currentRoom = nil
	self:ClearCurrentRoomBlocked(source or "clear_room")
	self.currentSongPayload = nil
	self.currentRoomRoundKey = ""
	self.lastResultSongPayload = nil
	if self.StopLiveScoreFlush then
		self:StopLiveScoreFlush("clear_current_room_state:" .. tostring(source or "unknown"))
	else
		self.pendingLiveScoreSnapshot = nil
		self.pendingLiveScoreRoundKey = ""
		self.liveScoreNextAttemptAt = 0
	end
	self.liveScoreInFlight = false
	self.pendingJoinRoomId = nil
	self:ClearOptimisticConfigReady(source or "clear_room")
	self:ClearOnlineOptionsReadyDeadline(source or "clear_room")
	self:ClearPendingConfigReadyIntent(source or "clear_room")
	local sourceKey = tostring(source or "")
	if sourceKey:find("leave", 1, true)
		or sourceKey:find("left", 1, true)
		or sourceKey:find("timeout", 1, true)
		or sourceKey:find("deleted", 1, true) then
		self:ResetPostRoomExitLobbyRefreshState(sourceKey)
	end
	online_flow_trace("clear_current_room_state_end source=" .. tostring(source or "unknown")
		.. " previousRoomId=" .. tostring(previousRoomId or "nil")
		.. " currentRoomId=" .. tostring(self.currentRoomId or "nil")
		.. " pendingJoinRoomId=" .. tostring(self.pendingJoinRoomId or "nil"))
end

	function ITGOnline:LeaveRoom(callback)
		if not self.currentRoomId then
			online_flow_trace("leave_room_skipped reason=no_current_room")
			if callback then callback(true, {}) end
			return
		end
		local roomId = self.currentRoomId
		local roomKey = self:RoomKey(roomId)
		self.leaveRoomCallbacksByRoomId = self.leaveRoomCallbacksByRoomId or {}
		if self.leaveRoomCallbacksByRoomId[roomKey] then
			online_flow_trace("leave_room_join_inflight room=" .. tostring(roomId)
				.. " callbacks=" .. tostring(#self.leaveRoomCallbacksByRoomId[roomKey])
				.. " currentRoomId=" .. tostring(self.currentRoomId or "nil")
				.. " phase=" .. tostring(self.currentRoom and self.currentRoom.phase or "nil")
				.. " leaving=" .. tostring(self:IsLeavingRoom(roomId) == true))
			if callback then
				self.leaveRoomCallbacksByRoomId[roomKey][#self.leaveRoomCallbacksByRoomId[roomKey] + 1] = callback
			end
			return
		end
		self.leaveRoomCallbacksByRoomId[roomKey] = callback and { callback } or {}
		online_flow_trace("leave_room_begin room=" .. tostring(roomId)
			.. " currentRoomId=" .. tostring(self.currentRoomId)
			.. " phase=" .. tostring(self.currentRoom and self.currentRoom.phase or "nil"))
		self:TraceOnlineState("leave_room_begin", {
			source = "leave_room",
			targetRoom = roomId,
			phase = self.currentRoom and self.currentRoom.phase or "nil",
			leaving = self:IsLeavingRoom(roomId) == true,
		})
		self:CancelPendingRequests()
		self:MarkLeavingRoom(roomId, true)
		self:IgnoreRoomEvents(roomId, 30)
		online_flow_trace("leave_room_request room=" .. tostring(roomId))
		self:Request("POST", "/rooms/" .. tostring(roomId) .. "/leave", {}, function(ok, decoded, response)
			local gone = response and (response.statusCode == 404 or response.statusCode == 410)
			online_flow_trace("leave_room_response room=" .. tostring(roomId)
				.. " ok=" .. tostring(ok == true)
				.. " gone=" .. tostring(gone == true)
				.. " status=" .. tostring(response and response.statusCode or "nil")
				.. " currentRoomId=" .. tostring(self.currentRoomId or "nil"))
			self:TraceOnlineState("leave_room_response", {
				source = "leave_room",
				targetRoom = roomId,
				ok = ok == true,
				gone = gone == true,
				status = response and response.statusCode or "nil",
				error = decoded and decoded.error_code or response and response.errorMessage or "nil",
				leaving = self:IsLeavingRoom(roomId) == true,
			})
			if ok or gone then
				if self.currentRoomId ~= nil and tonumber(self.currentRoomId) == tonumber(roomId) then
					online_flow_trace("leave_room_clear_current room=" .. tostring(roomId))
					self:ClearCurrentRoomState("leave_room_confirmed")
				else
					online_flow_trace("leave_room_mark_not_leaving room=" .. tostring(roomId)
						.. " reason=current_room_changed")
					self:MarkLeavingRoom(roomId, false)
				end
					self.deletedRoomIds[self:RoomKey(roomId)] = gone == true or nil
					self:ClearLobbyRefreshSuppression("leave_room_confirmed")
					self:QueueLobbyRefresh({ ignoreSuppression = true, reason = "leave_room_confirmed" })
				else
				online_flow_trace("leave_room_failed_unmark room=" .. tostring(roomId))
				self:MarkLeavingRoom(roomId, false)
			end
			local callbacks = self.leaveRoomCallbacksByRoomId and self.leaveRoomCallbacksByRoomId[roomKey] or {}
			if self.leaveRoomCallbacksByRoomId then self.leaveRoomCallbacksByRoomId[roomKey] = nil end
			online_flow_trace("leave_room_callbacks_begin room=" .. tostring(roomId)
				.. " count=" .. tostring(#callbacks)
				.. " okOrGone=" .. tostring((ok or gone) == true)
				.. " currentRoomId=" .. tostring(self.currentRoomId or "nil")
				.. " leaving=" .. tostring(self:IsLeavingRoom(roomId) == true))
			for index, cb in ipairs(callbacks) do
				online_flow_trace("leave_room_callback_call room=" .. tostring(roomId)
					.. " index=" .. tostring(index)
					.. " okOrGone=" .. tostring((ok or gone) == true))
				cb(ok or gone, decoded, response)
			end
			online_flow_trace("leave_room_callbacks_end room=" .. tostring(roomId)
				.. " currentRoomId=" .. tostring(self.currentRoomId or "nil")
				.. " leaving=" .. tostring(self:IsLeavingRoom(roomId) == true))
		end)
	end

function ITGOnline:FetchRoom(roomId, callback)
	roomId = roomId or self.currentRoomId or self.pendingJoinRoomId
	if not roomId then
		online_flow_trace("fetch_room_skipped reason=no_room_id currentRoomId=" .. tostring(self.currentRoomId or "nil")
			.. " pendingJoinRoomId=" .. tostring(self.pendingJoinRoomId or "nil"))
		if callback then callback(false, nil, { errorMessage = "No room id available." }) end
		return
	end
	local roomKey = tostring(roomId)
	local currentRoomKey = tostring(self.currentRoom and (self.currentRoom.id or self.currentRoom.room_id or self.currentRoom.roomId) or self.currentRoomId or "")
	local currentPhase = self.NormalizeRoomPhase and self:NormalizeRoomPhase(self.currentRoom and self.currentRoom.phase) or tostring(self.currentRoom and self.currentRoom.phase or "")
	local currentSummary = self.PlayStateSummary and self:PlayStateSummary(self.currentRoom) or nil
	if currentRoomKey == roomKey
		and currentPhase == "results"
		and currentSummary
		and currentSummary.finalResultsReady == true
	then
		self.fetchRoomStableResultsLastAtByRoomId = self.fetchRoomStableResultsLastAtByRoomId or {}
		local now = GetTimeSinceStart()
		local lastAt = tonumber(self.fetchRoomStableResultsLastAtByRoomId[roomKey]) or 0
		local coalesceSeconds = tonumber(self.fetchRoomStableResultsCoalesceSeconds) or 0.75
		if now - lastAt < coalesceSeconds then
			online_flow_trace("fetch_room_coalesced reason=stable_results"
				.. " room=" .. tostring(roomKey)
				.. " age=" .. tostring(now - lastAt)
				.. " coalesceSeconds=" .. tostring(coalesceSeconds)
				.. " finalResults=" .. tostring(currentSummary.finalResults or "nil"))
			if callback then callback(true, { room = self.currentRoom, coalesced = true }, { statusCode = 200, coalesced = true }) end
			return
		end
		self.fetchRoomStableResultsLastAtByRoomId[roomKey] = now
	end
	online_flow_trace("fetch_room_begin room=" .. tostring(roomKey)
		.. " currentRoomId=" .. tostring(self.currentRoomId or "nil")
		.. " pendingJoinRoomId=" .. tostring(self.pendingJoinRoomId or "nil")
		.. " inFlight=" .. tostring(self.fetchRoomInFlightByRoomId and self.fetchRoomInFlightByRoomId[roomKey] ~= nil)
		.. " screen=" .. tostring(self.currentScreenName or "nil"))
	if self.deletedRoomIds[roomKey] then
		online_flow_trace_throttled("fetch_deleted_room_" .. roomKey, 5.0,
			"fetch_room_skipped reason=room_deleted roomId=" .. roomKey)
		if callback then callback(false, nil, { statusCode = 410, errorMessage = "Room was deleted." }) end
		return
	end
	self.fetchRoomInFlightByRoomId = self.fetchRoomInFlightByRoomId or {}
	local inFlight = self.fetchRoomInFlightByRoomId[roomKey]
	if inFlight then
		if callback then
			inFlight[#inFlight + 1] = callback
		end
		online_flow_trace("fetch_room_join_inflight room=" .. tostring(roomKey)
			.. " callbacks=" .. tostring(#inFlight)
			.. " currentRoomId=" .. tostring(self.currentRoomId or "nil"))
		return
	end

	local callbacks = {}
	if callback then callbacks[#callbacks + 1] = callback end
	self.fetchRoomInFlightByRoomId[roomKey] = callbacks

	self:Request("GET", "/rooms/" .. roomKey, nil, function(ok, decoded, response)
		local queuedCallbacks = self.fetchRoomInFlightByRoomId[roomKey] or {}
		self.fetchRoomInFlightByRoomId[roomKey] = nil
		online_flow_trace("fetch_room_response room=" .. tostring(roomKey)
			.. " ok=" .. tostring(ok == true)
			.. " status=" .. tostring(response and response.statusCode or "nil")
			.. " hasRoom=" .. tostring(decoded and decoded.room ~= nil)
			.. " phase=" .. tostring(decoded and decoded.room and decoded.room.phase or "nil")
			.. " members=" .. tostring(decoded and decoded.room and decoded.room.members and #decoded.room.members or 0)
			.. " readyStates=" .. tostring(decoded and decoded.room and decoded.room.ready_states and #decoded.room.ready_states or 0)
			.. " callbacks=" .. tostring(#queuedCallbacks))

		if ok and decoded and decoded.room then
			local room = self:ApplyRoomSnapshot(decoded.room, "fetch_room")
			decoded.room = room or decoded.room
			self.pendingJoinRoomId = nil
		end

		for queuedCallback in ivalues(queuedCallbacks) do
			queuedCallback(ok, decoded, response)
		end
	end)
end

function ITGOnline:MarkRealtimeEventProcessed(eventId)
	local normalizedId = tonumber(eventId)
	if not normalizedId or normalizedId <= 0 then return false end
	normalizedId = tostring(math.floor(normalizedId))

	self.processedRealtimeEventIds = self.processedRealtimeEventIds or {}
	self.processedRealtimeEventOrder = self.processedRealtimeEventOrder or {}
	if self.processedRealtimeEventIds[normalizedId] then return true end

	self.processedRealtimeEventIds[normalizedId] = true
	self.processedRealtimeEventOrder[#self.processedRealtimeEventOrder + 1] = normalizedId

	local limit = tonumber(self.processedRealtimeEventLimit) or 512
	while #self.processedRealtimeEventOrder > limit do
		local oldestId = table.remove(self.processedRealtimeEventOrder, 1)
		if oldestId then self.processedRealtimeEventIds[oldestId] = nil end
	end

	return false
end

	function ITGOnline:RealtimeRoomEventPolicy(name, hasRoomSnapshot)
		local policies = {
			["room.member_joined"] = {
				memberChange = true,
				fetchRoom = true,
				refreshLobby = true,
				reason = "member_joined_requires_room_and_lobby_refresh",
			},
			["room.member_left"] = {
				memberChange = true,
				fetchRoom = true,
				refreshLobby = true,
				reason = "member_left_requires_room_and_lobby_refresh",
			},
			["room.member_pack_sync_updated"] = {
				roomUiRefresh = true,
				minLobbyRefreshInterval = 1.5,
				reason = "pack_sync_updates_player_ui",
			},
			["room.member_song_availability_updated"] = {
				roomUiRefresh = true,
				minLobbyRefreshInterval = 0.5,
				reason = "song_availability_updates_player_ui",
			},
			["room.song_selected"] = {
				fetchRoom = true,
				roomUiRefresh = true,
				minLobbyRefreshInterval = 0.25,
				reason = "song_selected_requires_authoritative_room_refresh",
			},
			["room.song_selection_cancelled"] = {
				roomUiRefresh = true,
				minLobbyRefreshInterval = 0.25,
				reason = "song_selection_cancelled_snapshot_updates_room_ui_only",
			},
			["room.ready_updated"] = {
				roomUiRefresh = true,
				minLobbyRefreshInterval = 0.5,
				reason = "ready_state_updates_room_ui",
			},
		}
		local policy = policies[tostring(name or "")]
		if not policy then
			policy = {
				reason = "default_room_event_state_only",
			}
		end
		online_flow_trace("realtime_room_policy name=" .. tostring(name or "nil")
			.. " reason=" .. tostring(policy.reason or "nil")
			.. " hasRoomSnapshot=" .. tostring(hasRoomSnapshot == true)
			.. " memberChange=" .. tostring(policy.memberChange == true)
			.. " fetchRoom=" .. tostring(policy.fetchRoom == true)
			.. " refreshLobby=" .. tostring(policy.refreshLobby == true)
			.. " roomUiRefresh=" .. tostring(policy.roomUiRefresh == true)
			.. " minLobbyRefreshInterval=" .. tostring(policy.minLobbyRefreshInterval or "nil"))
		return policy
	end

	function ITGOnline:RealtimeNonRoomEventPolicy(name)
		local policies = {
			["connection.ready"] = {
				action = "sync_unless_lobby_screen_or_recent_sync",
				reason = "connection_ready_reconciles_client_state",
			},
			["server.ping"] = {
				action = "ignore_control_frame",
				reason = "server_ping_has_no_state",
			},
			["connection.closed"] = {
				action = "ignore_control_frame",
				reason = "close_lifecycle_handled_by_socket",
			},
			["auth.session_revoked"] = {
				action = "invalidate_authenticated_session",
				reason = "same_account_connected_elsewhere",
			},
			["presence.pruned"] = {
				action = "queue_lobby_refresh",
				reason = "presence_cleanup_changes_online_players",
			},
			["room.left"] = {
				action = "leave_current_room_if_matching",
				reason = "server_confirms_local_room_exit_or_ejection",
			},
			["lobby.updated"] = {
				action = "apply_presence_cache_then_refresh_lobby",
				reason = "lobby_presence_or_room_list_changed",
			},
			["room.invitation.created"] = {
				action = "broadcast_invitation",
				reason = "user_action_required",
			},
			["room.join_request.declined"] = {
				action = "clear_pending_join_and_notify",
				reason = "pending_join_terminal_state",
			},
			["room.join_request.expired"] = {
				action = "clear_pending_join_and_notify",
				reason = "pending_join_terminal_state",
			},
			["room.join_request.accepted"] = {
				action = "fetch_room_then_broadcast",
				reason = "pending_join_accepted_needs_room_snapshot",
			},
		}
		local policy = policies[tostring(name or "")] or {
			action = "fallback_event_handler",
			reason = "no_explicit_non_room_policy",
		}
		online_flow_trace("realtime_non_room_policy name=" .. tostring(name or "nil")
			.. " action=" .. tostring(policy.action or "nil")
			.. " reason=" .. tostring(policy.reason or "nil"))
		return policy
	end

	function ITGOnline:HandleRealtimeEvent(event)
		if type(event) ~= "table" then
			online_trace("Ignored malformed realtime event.")
			return
		end
		local name = event.event or event.name
		local payload = event.payload or {}
		local eventId = tonumber(event.id)
		local payloadRoom = type(payload.room) == "table" and payload.room or nil
		local payloadMembers = payloadRoom and (payloadRoom.members or payloadRoom.players or payloadRoom.room_members) or payload.members
		local payloadReadyStates = payloadRoom and payloadRoom.ready_states or payload.ready_states
		local payloadFinalResults = payloadRoom and payloadRoom.final_results or payload.final_results
		local payloadSessions = payloadRoom and payloadRoom.play_sessions or payload.play_sessions
		local payloadLeaderboard = payload.leaderboard or (payloadRoom and payloadRoom.leaderboard)
		local payloadPlayState = payload.play_state or payload.playState or (payloadRoom and (payloadRoom.play_state or payloadRoom.playState))
		online_flow_trace("realtime_event_begin name=" .. tostring(name or "nil")
			.. " eventId=" .. tostring(eventId or "nil")
			.. " payloadRoomId=" .. tostring(payload.room_id or (payload.room and payload.room.id) or "nil")
			.. " payloadPhase=" .. tostring(payload.room and payload.room.phase or payload.room_phase or "nil")
			.. " payloadMembers=" .. tostring(type(payloadMembers) == "table" and #payloadMembers or "nil")
			.. " payloadReadyStates=" .. tostring(type(payloadReadyStates) == "table" and #payloadReadyStates or "nil")
			.. " payloadFinalResults=" .. tostring(type(payloadFinalResults) == "table" and #payloadFinalResults or "nil")
			.. " payloadSessions=" .. tostring(type(payloadSessions) == "table" and #payloadSessions or "nil")
			.. " payloadLeaderboard=" .. tostring(type(payloadLeaderboard) == "table" and #payloadLeaderboard or "nil")
			.. " payloadSelectedAt=" .. tostring((payloadRoom and payloadRoom.selected_song and payloadRoom.selected_song.selected_at) or payload.selected_at or "nil")
			.. " payloadPlayStateVersion=" .. tostring(type(payloadPlayState) == "table" and (payloadPlayState.version or payloadPlayState.play_state_version) or "nil")
			.. " currentRoomId=" .. tostring(self.currentRoomId or "nil")
			.. " pendingJoinRoomId=" .. tostring(self.pendingJoinRoomId or "nil")
			.. " currentPhase=" .. tostring(self.currentRoom and self.currentRoom.phase or "nil")
			.. " screen=" .. tostring(self.currentScreenName or "nil")
			.. " generation=" .. tostring(self.screenGeneration or "nil"))
		local idlessControlEvents = {
			["connection.ready"] = true,
			["connection.closed"] = true,
			["server.ping"] = true,
			["pong"] = true,
			["client.error"] = true,
			["auth.session_revoked"] = true,
		}
		if eventId and eventId > 0 then
			self.lastEventCursor = math.max(self.lastEventCursor or 0, math.floor(eventId))
			if self:MarkRealtimeEventProcessed(eventId) then
				online_flow_trace("realtime_event_ignored reason=duplicate eventId=" .. tostring(eventId)
					.. " name=" .. tostring(name or "nil"))
				return
			end
			online_flow_trace("realtime_event_cursor_advanced eventId=" .. tostring(eventId)
				.. " lastEventCursor=" .. tostring(self.lastEventCursor or "nil")
				.. " name=" .. tostring(name or "nil"))
	end
	if not name then
			online_trace("Ignored realtime event without name.")
			online_flow_trace("realtime_event_ignored reason=missing_name eventId=" .. tostring(eventId or "nil"))
			return
		end
		if (not eventId or eventId <= 0) and not idlessControlEvents[name] then
			online_trace("Ignored idless non-control realtime event: " .. tostring(name))
			online_flow_trace("realtime_event_ignored reason=idless_non_control name=" .. tostring(name))
			return
		end
		if not tostring(name):match("^room%.") or name == "room.left"
			or name == "room.invitation.created"
			or name == "room.join_request.declined"
			or name == "room.join_request.expired"
			or name == "room.join_request.accepted" then
			self:RealtimeNonRoomEventPolicy(name)
		end

	local room_event_is_relevant = function(roomId)
		local expected = self.currentRoomId or self.pendingJoinRoomId
		if roomId and self:ShouldIgnoreRoomEvents(roomId) then
			online_flow_trace("room_event_ignored reason=recently_left_room room=" .. tostring(roomId)
				.. " event=" .. tostring(name))
			return false
		end
		if not expected then
			online_flow_trace("room_event_ignored reason=no_expected_room"
				.. " room=" .. tostring(roomId or "nil")
				.. " event=" .. tostring(name)
				.. " currentRoomId=" .. tostring(self.currentRoomId or "nil")
				.. " pendingJoinRoomId=" .. tostring(self.pendingJoinRoomId or "nil")
				.. " screen=" .. tostring(self.currentScreenName or "nil"))
			return false
		end
		if not roomId then
			online_flow_trace("room_event_relevant reason=missing_payload_room_using_expected"
				.. " event=" .. tostring(name)
				.. " expected=" .. tostring(expected)
				.. " currentRoomId=" .. tostring(self.currentRoomId or "nil")
				.. " pendingJoinRoomId=" .. tostring(self.pendingJoinRoomId or "nil"))
			return true
		end
		if self:IsLeavingRoom(roomId) then
			online_flow_trace("room_event_ignored reason=leaving_room room=" .. tostring(roomId)
				.. " event=" .. tostring(name))
			return false
		end
		local relevant = tonumber(roomId) == tonumber(expected)
		if not relevant then
			online_flow_trace("room_event_ignored reason=room_mismatch"
				.. " room=" .. tostring(roomId)
				.. " expected=" .. tostring(expected)
				.. " event=" .. tostring(name)
				.. " currentRoomId=" .. tostring(self.currentRoomId or "nil")
				.. " pendingJoinRoomId=" .. tostring(self.pendingJoinRoomId or "nil")
				.. " screen=" .. tostring(self.currentScreenName or "nil"))
		else
			online_flow_trace("room_event_relevant reason=room_match"
				.. " room=" .. tostring(roomId)
				.. " expected=" .. tostring(expected)
				.. " event=" .. tostring(name))
		end
		return relevant
	end

	if name == "connection.ready" then
			online_flow_trace("realtime_event_apply name=connection.ready"
				.. " serverTime=" .. tostring(event.server_time or payload.server_time or "nil"))
			if self.UpdateServerClockOffset then
				self:UpdateServerClockOffset(event.server_time or payload.server_time, GetTimeSinceStart(), GetTimeSinceStart())
			end
			local screen = SCREENMAN and SCREENMAN:GetTopScreen() or nil
			local screenName = screen and screen:GetName() or ""
			if screenName == "ScreenOnlineLobbies" then
				online_flow_trace("connection_ready_sync_deferred_to_lobby_screen")
			elseif not self.syncInFlight and GetTimeSinceStart() - (self.lastSyncRequestedAt or 0) > 1 then
				online_flow_trace("connection_ready_sync_requested screen=" .. tostring(screenName))
				self:Sync()
			else
				online_flow_trace("connection_ready_sync_skipped inFlight=" .. tostring(self.syncInFlight == true)
					.. " lastSyncAge=" .. tostring(GetTimeSinceStart() - (self.lastSyncRequestedAt or 0)))
			end
	elseif name == "server.ping" then
		online_flow_trace("realtime_event_apply name=server.ping action=client_ping")
		if self.SendRealtimePing then
			self:SendRealtimePing("server.ping")
		end
		return
	elseif name == "pong" then
		online_flow_trace("realtime_event_apply name=pong action=keepalive_ack"
			.. " serverTime=" .. tostring(event.server_time or payload.server_time or "nil"))
		if self.UpdateServerClockOffset then
			self:UpdateServerClockOffset(event.server_time or payload.server_time, GetTimeSinceStart(), GetTimeSinceStart())
		end
		return
		elseif name == "connection.closed" then
			-- Informational frame. WebSocket close lifecycle is handled by onMessage Close.
			online_flow_trace("realtime_event_apply name=connection.closed action=none")
			return
		elseif name == "auth.session_revoked" then
			online_flow_trace("realtime_event_apply name=auth.session_revoked action=invalidate_authenticated_session"
				.. " eventId=" .. tostring(eventId or "nil")
				.. " reason=" .. tostring(payload.reason or "nil")
				.. " user=" .. tostring(payload.user_id or payload.userId or "nil"))
			if eventId and eventId > 0 then
				self:SendRealtimeAck(eventId)
				event._itgOnlineAckHandled = true
			end
			self:InvalidateAuthenticatedSession("auth.session_revoked", payload)
			return
		elseif name == "presence.pruned" then
			-- Server-side cleanup notification. The next sync/lobby refresh carries the durable state.
			online_flow_trace("presence_pruned_refresh_requested")
			self:QueueLobbyRefresh({ reason = "presence_pruned" })
			return
		elseif name == "room.left" then
			local roomId = tonumber(payload.room_id or -1)
			if roomId ~= tonumber(self.currentRoomId or -1) then
				online_flow_trace("room_left_event_ignored reason=room_mismatch"
					.. " payloadRoomId=" .. tostring(roomId)
					.. " currentRoomId=" .. tostring(self.currentRoomId or "nil")
					.. " pendingJoinRoomId=" .. tostring(self.pendingJoinRoomId or "nil"))
				return
			end

			local reason = tostring(payload.reason or "")
			local roomCode = self.currentRoom and (self.currentRoom.code or self.currentRoom.room_code or self.currentRoom.roomCode) or nil
			online_flow_trace("room_left_event_apply room=" .. tostring(roomId)
				.. " reason=" .. tostring(reason)
				.. " roomCode=" .. tostring(roomCode or "nil"))
			self:IgnoreRoomEvents(roomId, 30)
			self:ClearCurrentRoomState("room_left_event")
			MESSAGEMAN:Broadcast("OnlineLobbyLeft", {
				left=true,
				roomId=roomId,
				lobbyCode=roomCode,
				reason=reason,
				source="room.left",
			})
			MESSAGEMAN:Broadcast("OnlineResponseStatus", {
				event = "leaveLobby",
				success = true,
				message = reason == "pack_sync_timeout"
					and "Vous avez ete ejecte du salon car le telechargement du pack n'a pas commence a temps."
					or "Vous avez quitte le salon."
			})
			return
			elseif name == "lobby.updated" then
				local lobbyUpdateReason = tostring(payload.reason or "lobby.updated")
				local hasUserPayload = type(payload.user) == "table"
				local lobbyRoomId = payload.room_id or payload.roomId or (payload.room and payload.room.id)
				online_flow_trace("lobby_updated_event begin hasLobbyPayload=" .. tostring(type(payload) == "table")
					.. " reason=" .. lobbyUpdateReason
					.. " userId=" .. tostring(payload.user_id or "nil")
					.. " roomId=" .. tostring(lobbyRoomId or "nil")
					.. " hasUser=" .. tostring(hasUserPayload == true))
				if lobbyUpdateReason == "room.results_ready" then
					online_flow_trace("lobby_updated_event ignored reason=room_results_ready_room_scoped"
						.. " roomId=" .. tostring(lobbyRoomId or "nil")
						.. " currentRoomId=" .. tostring(self.currentRoomId or "nil")
						.. " screen=" .. tostring(self.currentScreenName or "nil"))
					return
				end
				if lobbyUpdateReason == "room.deleted" and lobbyRoomId then
					local roomKey = self:RoomKey(lobbyRoomId)
					self.deletedRoomIds = self.deletedRoomIds or {}
					self.deletedRoomIds[roomKey] = true
					self:IgnoreRoomEvents(roomKey, 30)
					online_flow_trace("lobby_updated_room_deleted_marked"
						.. " room=" .. tostring(roomKey)
						.. " reason=" .. lobbyUpdateReason)
					if self.PurgeStaleLobbyCandidate then
						self:PurgeStaleLobbyCandidate(roomKey, "lobby_updated_room_deleted")
					end
				end
				local appliedPresence = false
				if hasUserPayload then
					appliedPresence = self:ApplyLobbyPresencePayload(payload)
				else
					online_flow_trace("lobby_updated_event presence_skipped reason=room_or_lobby_event_without_user"
						.. " updateReason=" .. lobbyUpdateReason
						.. " roomId=" .. tostring(lobbyRoomId or "nil"))
				end
				online_flow_trace("lobby_updated_event presence_applied=" .. tostring(appliedPresence == true)
					.. " cachedLobbies=" .. tostring(self.cachedLobbySearchPayload and self.cachedLobbySearchPayload.lobbies and #self.cachedLobbySearchPayload.lobbies or 0)
					.. " cachedOnlinePlayers=" .. tostring(self.cachedLobbySearchPayload and self.cachedLobbySearchPayload.onlinePlayers and #self.cachedLobbySearchPayload.onlinePlayers or 0))
				if appliedPresence then
					online_flow_trace("lobby_updated_event broadcast_cached")
					MESSAGEMAN:Broadcast("LobbySearched", self.cachedLobbySearchPayload)
				end
				online_flow_trace("lobby_updated_event queue_lobby_refresh")
				self:QueueLobbyRefresh({ reason = lobbyUpdateReason })
		elseif name == "room.invitation.created" then
		online_flow_trace("realtime_event_apply name=room.invitation.created action=broadcast_invitation"
			.. " invitationId=" .. tostring(payload.invitation_id or payload.id or "nil"))
		MESSAGEMAN:Broadcast("OnlineRoomInvitation", payload)
		elseif name == "room.join_request.declined" then
			online_flow_trace("realtime_event_apply name=room.join_request.declined"
				.. " roomId=" .. tostring(payload.room_id or "nil")
				.. " pendingJoinRoomId=" .. tostring(self.pendingJoinRoomId or "nil")
				.. " reason=" .. tostring(payload.reason or "nil"))
			if payload.room_id == nil or tonumber(payload.room_id) == tonumber(self.pendingJoinRoomId or -1) then
				self.pendingJoinRoomId = nil
				self.pendingJoinRequestId = nil
			end
			MESSAGEMAN:Broadcast("OnlineResponseStatus", {
				event = "joinLobby",
				success = false,
				message = payload.reason and payload.reason ~= "" and ("Join request declined: " .. tostring(payload.reason)) or "Join request declined."
			})
		elseif name == "room.join_request.expired" then
			online_flow_trace("realtime_event_apply name=room.join_request.expired"
				.. " roomId=" .. tostring(payload.room_id or "nil")
				.. " pendingJoinRoomId=" .. tostring(self.pendingJoinRoomId or "nil")
				.. " reason=" .. tostring(payload.reason or "nil"))
			if payload.room_id == nil or tonumber(payload.room_id) == tonumber(self.pendingJoinRoomId or -1) then
				self.pendingJoinRoomId = nil
				self.pendingJoinRequestId = nil
			end
			MESSAGEMAN:Broadcast("OnlineResponseStatus", {
				event = "joinLobby",
				success = false,
				message = payload.reason == "cancelled_by_user" and "Join request cancelled." or "Join request expired."
			})
		elseif name == "room.join_request.accepted" and payload.room_id then
			if not room_event_is_relevant(payload.room_id) then return end
			online_flow_trace("realtime_event_apply name=room.join_request.accepted action=fetch_room"
				.. " roomId=" .. tostring(payload.room_id)
				.. " pendingJoinRoomId=" .. tostring(self.pendingJoinRoomId or "nil"))
			self.pendingJoinRoomId = nil
			self.pendingJoinRequestId = nil
			self:FetchRoom(payload.room_id, function(ok, decoded)
				online_flow_trace("realtime_join_request_accepted_fetch_result ok=" .. tostring(ok == true)
					.. " roomId=" .. tostring(payload.room_id)
					.. " hasRoom=" .. tostring(decoded and decoded.room ~= nil)
					.. " phase=" .. tostring(decoded and decoded.room and decoded.room.phase or "nil"))
				if ok and decoded and decoded.room then
					local room = self:ApplyRoomSnapshot(decoded.room, "realtime_join_request_accepted")
					MESSAGEMAN:Broadcast("OnlineLobbyState", self:LobbyStatePayload(decoded.room))
				end
		end)
	elseif name == "room.song_previewed" then
		online_flow_trace("realtime_event_apply name=room.song_previewed action=broadcast_preview"
			.. " title=" .. tostring(payload.preview and (payload.preview.title or payload.preview.folder_name) or "nil")
			.. " pack=" .. tostring(payload.preview and payload.preview.pack or "nil"))
		MESSAGEMAN:Broadcast("OnlineSongPreview", payload.preview or {})
	elseif name == "room.score_updated" then
		self.lastLeaderboardRealtimeAt = GetTimeSinceStart()
		local roomId = tonumber(payload.room_id)
		local expectedRoomId = tonumber(self.currentRoomId or self.pendingJoinRoomId or -1)
		if roomId and expectedRoomId > 0 and roomId ~= expectedRoomId then
			online_flow_trace("score_updated_ignored reason=room_mismatch"
				.. " roomId=" .. tostring(roomId)
				.. " expectedRoomId=" .. tostring(expectedRoomId))
			return
		end
		online_flow_trace("score_updated_event_begin roomId=" .. tostring(roomId or "nil")
			.. " expectedRoomId=" .. tostring(expectedRoomId)
			.. " leaderboardVersion=" .. tostring(payload.leaderboard_version_ms or "nil")
			.. " playStateVersion=" .. tostring(payload.play_state_version_ms or payload.play_state and payload.play_state.version_ms or "nil")
			.. " hasLeaderboard=" .. tostring(payload.leaderboard ~= nil)
			.. " hasPlayState=" .. tostring(payload.play_state ~= nil)
			.. " roomPhase=" .. tostring(payload.room_phase or "nil"))

		local incomingVersion = tonumber(payload.leaderboard_version_ms) or 0
		local incomingPlayStateVersion = tonumber(payload.play_state_version_ms or (payload.play_state and payload.play_state.version_ms)) or 0
		local versionRoomId = tostring(roomId or expectedRoomId or "")
		local leaderboardIsFresh = false
		if payload.leaderboard and versionRoomId ~= "" then
			local previousVersion = tonumber(self.lastLeaderboardVersionByRoomId[versionRoomId]) or 0
			if incomingVersion > 0 and incomingVersion < previousVersion then
				online_flow_trace("ignored_stale_score_leaderboard version=" .. tostring(incomingVersion)
					.. " previous=" .. tostring(previousVersion))
			elseif incomingVersion > 0 then
				self.lastLeaderboardVersionByRoomId[versionRoomId] = incomingVersion
				leaderboardIsFresh = true
			else
				local now = GetTimeSinceStart()
				if now - (tonumber(self.lastUnversionedPlayStateFetchAt) or 0) > 1 then
					self.lastUnversionedPlayStateFetchAt = now
					self:FetchRoom(roomId or expectedRoomId)
				end
			end
		end

		if payload.leaderboard and leaderboardIsFresh then
			if self.currentRoom then
				self.currentRoom.live_scores = payload.leaderboard
				self.currentRoom.leaderboard_version_ms = incomingVersion
				self.currentRoom.live_score_version_ms = incomingVersion
				if payload.room_phase then
					self.currentRoom.phase = payload.room_phase
				end
				online_flow_trace("score_updated_live_scores_applied roomId=" .. tostring(payload.room_id or "nil")
					.. " version=" .. tostring(incomingVersion)
					.. " entries=" .. tostring(payload.leaderboard and #payload.leaderboard or 0)
					.. " phase=" .. tostring(self.currentRoom.phase or "nil")
					.. " rowsSummary=" .. online_score_rows_summary(payload.leaderboard, 8))
			end
			local topScreen = SCREENMAN and SCREENMAN:GetTopScreen() or nil
			local screenName = tostring((topScreen and topScreen:GetName()) or self.currentScreenName or "")
			local suppressPostResultsBroadcast = self:IsPostResultsLobbyScreen(self.currentRoom, screenName)
			if suppressPostResultsBroadcast then
				online_flow_trace_throttled("post_results_score_leaderboard_suppressed", 1.0,
					"score_updated_leaderboard_broadcast_suppressed reason=post_results_lobby"
					.. " roomId=" .. tostring(payload.room_id or "nil")
					.. " version=" .. tostring(incomingVersion)
					.. " entries=" .. tostring(payload.leaderboard and #payload.leaderboard or 0)
					.. " phase=" .. tostring((self.currentRoom and self.currentRoom.phase) or "nil")
					.. " screen=" .. screenName)
			else
				online_flow_trace("score_updated_leaderboard_broadcast roomId=" .. tostring(payload.room_id or "nil")
					.. " version=" .. tostring(incomingVersion)
					.. " entries=" .. tostring(payload.leaderboard and #payload.leaderboard or 0))
			end
			if self.debugScoreTrace == true then
				local parts = {}
				for entry in ivalues(payload.leaderboard or {}) do
					local user = type(entry) == "table" and entry.user or {}
					parts[#parts + 1] = table.concat({
						tostring(user and user.id or ""),
						tostring(entry and entry.displayed_percent or ""),
						tostring(entry and entry.failed == true),
						tostring(entry and entry.source or ""),
					}, ":")
				end
				online_trace("score_updated_leaderboard_rows room=" .. tostring(payload.room_id or "nil")
					.. " version=" .. tostring(incomingVersion)
					.. " rows=" .. table.concat(parts, ","))
			end
			if self.debugScoreTrace == true then
				local score = payload.score or {}
				local user = score.user or {}
				local localDisplayed = tonumber(self.lastDisplayedScoreSnapshot and self.lastDisplayedScoreSnapshot.displayedPercent) or -1
				local localScore = tonumber(self.lastDisplayedScoreSnapshot and self.lastDisplayedScoreSnapshot.scorePercent) or -1
				local localEx = tonumber(self.lastDisplayedScoreSnapshot and self.lastDisplayedScoreSnapshot.exScorePercent) or -1
				local playState = ""
				if payload.play_state and payload.play_state.sessions and user.id then
					for session in ivalues(payload.play_state.sessions) do
						local sessionUser = session.user or {}
						if tostring(sessionUser.id or session.user_id or "") == tostring(user.id or "") then
							playState = tostring(session.state or "")
							break
						end
					end
				end
				online_trace("score_update room=" .. tostring(payload.room_id or "")
					.. " version=" .. tostring(incomingVersion)
					.. " user=" .. tostring(user.id or "")
					.. " score=" .. tostring(score.score or "")
					.. " percent=" .. tostring(score.score_percent or "")
					.. " state=" .. tostring(playState)
					.. " local_displayed=" .. tostring(localDisplayed)
					.. " local_score=" .. tostring(localScore)
					.. " local_ex=" .. tostring(localEx))
			end
			if not suppressPostResultsBroadcast then
				MESSAGEMAN:Broadcast("ITGOnlineLeaderboardUpdated", {
					leaderboard = payload.leaderboard,
					room_id = payload.room_id,
					leaderboard_version_ms = incomingVersion,
				})
			end
		end
		if payload.play_state and self.currentRoom then
			local playStateVersionKey = tostring(roomId or expectedRoomId or "")
			local previousPlayStateVersion = tonumber(self.lastPlayStateVersionByRoomId[playStateVersionKey]) or 0
			if incomingPlayStateVersion <= 0 and previousPlayStateVersion > 0 then
				online_flow_trace("ignored_unversioned_score_play_state previous=" .. tostring(previousPlayStateVersion))
			elseif incomingPlayStateVersion > 0 and incomingPlayStateVersion < previousPlayStateVersion then
				online_flow_trace("ignored_stale_score_play_state version=" .. tostring(incomingPlayStateVersion)
					.. " previous=" .. tostring(previousPlayStateVersion))
			else
				if incomingPlayStateVersion > 0 then
					self.lastPlayStateVersionByRoomId[playStateVersionKey] = incomingPlayStateVersion
				end
				self.currentRoom.play_state = payload.play_state
				online_flow_trace("score_updated_play_state_applied roomId=" .. tostring(playStateVersionKey)
					.. " version=" .. tostring(incomingPlayStateVersion)
					.. " previousVersion=" .. tostring(previousPlayStateVersion)
					.. " roomPhase=" .. tostring(payload.room_phase or "nil")
					.. " sessions=" .. tostring(payload.play_state.sessions and #payload.play_state.sessions or 0))
				if payload.room_phase then
					if self:RoomPhaseFromScoreEventIsStale(payload.room_phase) then
						online_flow_trace("ignored_stale_score_room_phase current="
							.. tostring(self.currentRoom and self.currentRoom.phase or "nil")
							.. " incoming=" .. tostring(payload.room_phase))
					else
						self:ApplyRoomPhase(payload.room_phase, "score_updated")
					end
				end
				self:ApplyPlayStateSnapshot(payload.play_state, "score_updated", incomingPlayStateVersion)
				if self.EnforceRoomPhaseScreen then
					self:EnforceRoomPhaseScreen()
				end
			end
		end
		elseif name == "room.deleted" then
			local roomId = payload.room_id
				or (event.target and event.target.id)
				or payload.id
				or self.currentRoomId
				or self.pendingJoinRoomId
			if roomId then
				local roomKey = tostring(roomId)
				local activeRoomDeleted = tostring(self.currentRoomId or "") == roomKey
					or tostring(self.pendingJoinRoomId or "") == roomKey
				local ignoredAfterLeave = self:ShouldIgnoreRoomEvents(roomId) or self:IsLeavingRoom(roomId)
				online_flow_trace("room_deleted_event_begin roomId=" .. roomKey
					.. " active=" .. tostring(activeRoomDeleted == true)
					.. " ignoredAfterLeave=" .. tostring(ignoredAfterLeave == true)
					.. " currentRoomId=" .. tostring(self.currentRoomId or "nil")
					.. " pendingJoinRoomId=" .. tostring(self.pendingJoinRoomId or "nil"))
				self.deletedRoomIds[roomKey] = true
				self:IgnoreRoomEvents(roomId, 30)
				local roomDeletedRefreshQueued = false
				if self.PurgeStaleLobbyCandidate then
					self:PurgeStaleLobbyCandidate(roomKey, "room_deleted_event")
					roomDeletedRefreshQueued = true
				end

				if ignoredAfterLeave then
					online_flow_trace("room_deleted_event_ignored reason=recently_left_room roomId=" .. roomKey)
					if self.ScheduleDeferredLobbyRefresh and not roomDeletedRefreshQueued then
						self:ScheduleDeferredLobbyRefresh(0.35, "room_deleted_ignored_after_leave")
					elseif not roomDeletedRefreshQueued then
						self:QueueLobbyRefresh({ reason = "room_deleted_ignored_after_leave" })
					end
					return
				elseif activeRoomDeleted then
					self:ClearCurrentRoomState("room_deleted_event")
					MESSAGEMAN:Broadcast("OnlineLobbyState", self:LobbyStatePayload(nil))
					MESSAGEMAN:Broadcast("OnlineResponseStatus", {
						event = "roomDeleted",
						success = false,
						message = "Room closed."
					})
				end

				if not roomDeletedRefreshQueued then
					self:QueueLobbyRefresh({ reason = "room_deleted_event" })
				end
				online_flow_trace("room_deleted_event roomId=" .. roomKey)
			end
		elseif name == "room.load_timeout" then
			if payload.room then
				online_flow_trace("load_timeout_event_apply hasRoom=true phase=" .. tostring(payload.room.phase or "nil")
					.. " roomId=" .. tostring(payload.room.id or payload.room_id or "nil"))
				local room = self:ApplyRoomSnapshot(payload.room, "load_timeout")
				self.songLoadedAckKey = ""
				MESSAGEMAN:Broadcast("OnlineLobbyState", self:LobbyStatePayload(room or payload.room))
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
				online_flow_trace("realtime_room_event_apply_snapshot_begin name=" .. tostring(name)
					.. " roomId=" .. tostring(roomId or payload.room.id or "nil")
					.. " eventId=" .. tostring(eventId or "nil")
					.. " payloadPhase=" .. tostring(payload.room.phase or "nil")
					.. " payloadMembers=" .. tostring(payload.room.members and #payload.room.members or 0)
					.. " payloadReadyStates=" .. tostring(payload.room.ready_states and #payload.room.ready_states or 0)
					.. " payloadSelectedAt=" .. tostring(payload.room.selected_song and (payload.room.selected_song.selected_at or payload.room.selected_song.selectedAt) or "nil"))
				local versionRoomId = tostring(roomId or payload.room.id or "")
				if eventId and eventId > 0 and versionRoomId ~= "" then
					local previousRoomEventId = tonumber(self.lastRoomEventIdByRoomId[versionRoomId]) or 0
					if eventId < previousRoomEventId then
						online_flow_trace("ignored_stale_room_event name=" .. tostring(name)
							.. " roomId=" .. tostring(versionRoomId)
							.. " previousEventId=" .. tostring(previousRoomEventId)
							.. " eventId=" .. tostring(eventId))
						return
					end
					self.lastRoomEventIdByRoomId[versionRoomId] = eventId
				end
				if not self:ShouldApplyRoomSnapshotPayload(payload.room, "realtime_room_event:" .. tostring(name), eventId) then
					return
				end
				online_flow_trace("realtime_room_event name=" .. tostring(name)
					.. " payloadPhase=" .. tostring(payload.room.phase)
					.. " previousPhase=" .. tostring(self.currentRoom and self.currentRoom.phase or "no-room")
					.. " eventId=" .. tostring(eventId))
				local room = self:ApplyRoomSnapshot(payload.room, "realtime_room_event:" .. tostring(name))
				online_flow_trace("realtime_room_event_broadcast_state name=" .. tostring(name)
					.. " roomId=" .. tostring(roomId or payload.room.id or "nil")
					.. " appliedRoom=" .. tostring(room and room.id or "nil")
					.. " appliedPhase=" .. tostring(room and room.phase or "nil")
					.. " members=" .. tostring(room and room.members and #room.members or 0)
					.. " readyStates=" .. tostring(room and room.ready_states and #room.ready_states or 0)
					.. " eventId=" .. tostring(eventId))
				MESSAGEMAN:Broadcast("OnlineLobbyState", self:LobbyStatePayload(room or self.currentRoom or payload.room))
				self:BroadcastLeaderboardFromRoom(room or payload.room, "realtime_room_event:" .. tostring(name))
				local roomPolicy = self:RealtimeRoomEventPolicy(name, payload.room ~= nil)
				if roomPolicy.fetchRoom == true and type(self.FetchCurrentRoomFallback) == "function" then
					local minInterval = roomPolicy.minLobbyRefreshInterval or 0.5
					if name == "room.song_selected" then minInterval = 0 end
					self:FetchCurrentRoomFallback("realtime_room_event:" .. tostring(name), minInterval)
				end
				if roomPolicy.memberChange == true then
					online_flow_trace("room_member_change_refresh_requested name=" .. tostring(name)
						.. " roomId=" .. tostring(roomId or payload.room.id or "nil")
						.. " eventId=" .. tostring(eventId)
						.. " policyReason=" .. tostring(roomPolicy.reason or "nil"))
					if roomPolicy.refreshLobby == true then
						online_flow_trace("room_policy_lobby_refresh name=" .. tostring(name)
							.. " reason=" .. tostring(roomPolicy.reason or "nil"))
						self:QueueLobbyRefresh({ reason = tostring(roomPolicy.reason or name or "room_policy") })
					end
					local refreshRoomId = roomId or (room and room.id) or (self.currentRoom and self.currentRoom.id) or self.currentRoomId
					if roomPolicy.fetchRoom == true and refreshRoomId and self.FetchRoom then
						self.lastMemberRoomRefreshAtByRoomId = self.lastMemberRoomRefreshAtByRoomId or {}
						local refreshKey = tostring(refreshRoomId)
						local now = GetTimeSinceStart()
						local lastRefreshAt = tonumber(self.lastMemberRoomRefreshAtByRoomId[refreshKey]) or 0
						if now - lastRefreshAt >= 0.5 then
							self.lastMemberRoomRefreshAtByRoomId[refreshKey] = now
							online_flow_trace("member_room_refresh_fetch name=" .. tostring(name)
								.. " roomId=" .. tostring(refreshRoomId)
								.. " eventId=" .. tostring(eventId))
							self:FetchRoom(refreshRoomId, function(ok, decoded)
								online_flow_trace("member_room_refresh_result name=" .. tostring(name)
									.. " ok=" .. tostring(ok == true)
									.. " roomId=" .. tostring(refreshRoomId)
									.. " hasRoom=" .. tostring(decoded and decoded.room ~= nil)
									.. " phase=" .. tostring(decoded and decoded.room and decoded.room.phase or "nil")
									.. " members=" .. tostring(decoded and decoded.room and decoded.room.members and #decoded.room.members or 0)
									.. " readyStates=" .. tostring(decoded and decoded.room and decoded.room.ready_states and #decoded.room.ready_states or 0))
								if ok and decoded and decoded.room then
									local fetchedRoom = self:ApplyRoomSnapshot(decoded.room, "member_room_refresh:" .. tostring(name))
									online_flow_trace("member_room_refresh_broadcast name=" .. tostring(name)
										.. " roomId=" .. tostring(refreshRoomId)
										.. " appliedPhase=" .. tostring(fetchedRoom and fetchedRoom.phase or "nil")
										.. " members=" .. tostring(fetchedRoom and fetchedRoom.members and #fetchedRoom.members or 0))
									MESSAGEMAN:Broadcast("OnlineLobbyState", self:LobbyStatePayload(fetchedRoom or decoded.room))
								end
							end)
						else
							online_flow_trace("member_room_refresh_throttled name=" .. tostring(name)
								.. " roomId=" .. tostring(refreshRoomId)
								.. " age=" .. tostring(now - lastRefreshAt))
						end
					end
				elseif roomPolicy.roomUiRefresh == true then
					if payload.room then
						if self.InvalidateRoomUiLobbyRefresh then
							self:InvalidateRoomUiLobbyRefresh("snapshot_already_applied:" .. tostring(name))
						end
						online_flow_trace("room_ui_lobby_refresh_skipped name=" .. tostring(name)
							.. " reason=snapshot_already_applied"
							.. " screen=" .. tostring(self.currentScreenName or "nil")
							.. " phase=" .. tostring(room and room.phase or self.currentRoom and self.currentRoom.phase or "nil"))
					else
					local now = GetTimeSinceStart()
					local minInterval = tonumber(roomPolicy.minLobbyRefreshInterval) or 0.5
					local lastRefreshAt = tonumber(self.lastRoomUiLobbyRefreshAt) or 0
					if now - lastRefreshAt >= minInterval then
						self.lastRoomUiLobbyRefreshAt = now
						online_flow_trace("room_ui_lobby_refresh_immediate name=" .. tostring(name)
							.. " age=" .. tostring(now - lastRefreshAt)
							.. " minInterval=" .. tostring(minInterval)
							.. " policyReason=" .. tostring(roomPolicy.reason or "nil"))
						self:QueueLobbyRefresh({ reason = tostring(roomPolicy.reason or name or "room_ui_refresh") })
					elseif not self.roomUiLobbyRefreshDeferredScheduled and self.ScheduleDeferredLobbyRefresh then
						self.roomUiLobbyRefreshDeferredScheduled = true
						online_flow_trace("room_ui_lobby_refresh_deferred name=" .. tostring(name)
							.. " age=" .. tostring(now - lastRefreshAt)
							.. " delay=" .. tostring(math.max(0.1, minInterval - (now - lastRefreshAt) + 0.05))
							.. " policyReason=" .. tostring(roomPolicy.reason or "nil"))
						self:ScheduleDeferredLobbyRefresh(
							math.max(0.1, minInterval - (now - lastRefreshAt) + 0.05),
							"room_ui_refresh:" .. tostring(name))
					else
						online_flow_trace("room_ui_lobby_refresh_already_deferred name=" .. tostring(name)
							.. " age=" .. tostring(now - lastRefreshAt)
							.. " minInterval=" .. tostring(minInterval)
							.. " policyReason=" .. tostring(roomPolicy.reason or "nil"))
					end
					end
				end
				if name == "room.join_request.created" then
					online_flow_trace("room_join_request_broadcast_pending source=realtime roomId=" .. tostring(roomId or payload.room.id or "nil"))
					self:BroadcastPendingJoinRequestsFromRoom(room or payload.room)
				end
				if room and room.play_state then
					online_flow_trace("realtime_room_event_broadcast_play_state name=" .. tostring(name)
						.. " version=" .. tostring(room.play_state.version_ms or "nil")
						.. " phase=" .. tostring(room.phase or "nil"))
					self:ApplyPlayStateSnapshot(room.play_state, "realtime_room_event:" .. tostring(name), room.play_state.version_ms, {
						suppressLobbyBroadcast = true,
					})
				end
			elseif roomId then
				online_flow_trace("realtime_room_event_fetch name=" .. tostring(name)
					.. " roomId=" .. tostring(roomId)
					.. " eventId=" .. tostring(eventId))
				self:FetchRoom(roomId, function(ok, decoded)
					online_flow_trace("realtime_room_event_fetch_callback name=" .. tostring(name)
						.. " ok=" .. tostring(ok == true)
						.. " roomId=" .. tostring(roomId)
						.. " hasRoom=" .. tostring(decoded and decoded.room ~= nil)
						.. " phase=" .. tostring(decoded and decoded.room and decoded.room.phase or "nil"))
					if ok and decoded and decoded.room then
						online_flow_trace("realtime_room_event_fetch_result name=" .. tostring(name)
							.. " roomId=" .. tostring(roomId)
							.. " phase=" .. tostring(decoded.room.phase)
							.. " members=" .. tostring(decoded.room.members and #decoded.room.members or 0)
							.. " readyStates=" .. tostring(decoded.room.ready_states and #decoded.room.ready_states or 0)
							.. " selectedAt=" .. tostring(decoded.room.selected_song and (decoded.room.selected_song.selected_at or decoded.room.selected_song.selectedAt) or "nil"))
						local room = self:ApplyRoomSnapshot(decoded.room, "realtime_room_event_fetch:" .. tostring(name))
						MESSAGEMAN:Broadcast("OnlineLobbyState", self:LobbyStatePayload(room or self.currentRoom or decoded.room))
						self:BroadcastLeaderboardFromRoom(room or decoded.room, "realtime_room_event_fetch:" .. tostring(name))
						if name == "room.join_request.created" then
							self:BroadcastPendingJoinRequestsFromRoom(room or self.currentRoom or decoded.room)
						end
					end
				end)
			end
	else
		online_trace("Unhandled realtime event: " .. tostring(name))
	end
end

function ITGOnline:LobbySearchPayload(decoded)
	local lobbies = {}
	local cachedPayload = self.cachedLobbySearchPayload or { lobbies = {}, onlinePlayers = {} }
	local source = decoded and "decoded" or "cache"
	local decodedOnlineUsers = decoded and (decoded.online_users or decoded.online_players or decoded.onlinePlayers) or nil
	local decodedOnlineUsersSource = "none"
	if decoded then
		if decoded.online_users ~= nil then
			decodedOnlineUsersSource = "online_users"
		elseif decoded.online_players ~= nil then
			decodedOnlineUsersSource = "online_players"
		elseif decoded.onlinePlayers ~= nil then
			decodedOnlineUsersSource = "onlinePlayers"
		end
	end
	local rawPublicRoomCount = decoded and decoded.public_rooms and #decoded.public_rooms
		or decoded and decoded.lobbies and #decoded.lobbies
		or 0
	local rawOnlineUserCount = decodedOnlineUsers and #decodedOnlineUsers or 0
	local selfOnlineUserFiltered = 0
	local rawOnlineUserIds = {}
	local displayOnlineUserIds = {}
	local rawPresenceIdentities = {}
	local selfPresenceIdentities = {}
	local selfPresenceSessionIds = {}
	local selfPresenceDevices = {}
	local retainedSameAccountPresenceIds = {}
	local retainedSameAccountSessionIds = {}

	if decoded and decoded.public_rooms ~= nil then
		for room in ivalues(decoded.public_rooms or {}) do
			local roomId = room and (room.id or room.room_id or room.roomId or room.code)
			if self:ShouldSuppressLobbyCandidate(roomId, "decoded_lobby_payload") then
				online_flow_trace("lobby_search_room_filtered source=decoded room=" .. tostring(roomId or "nil"))
			else
				local phase = room and room.phase or nil
				local acceptsNewMembers = room and room.accepts_new_members
				if acceptsNewMembers == nil and room then
					acceptsNewMembers = room.acceptsNewMembers
				end
				if acceptsNewMembers == nil then
					local normalizedPhase = self.NormalizeRoomPhase and self:NormalizeRoomPhase(phase) or tostring(phase or "")
					acceptsNewMembers = normalizedPhase == "lobby" or normalizedPhase == "results"
				end
				lobbies[#lobbies + 1] = {
					code = tostring(roomId or ""),
					roomId = roomId,
					name = room.name,
					playerCount = room.members_count or 0,
					phase = phase,
					acceptsNewMembers = acceptsNewMembers == true,
				}
			end
		end
	else
		for lobby in ivalues(cachedPayload.lobbies or {}) do
			local roomId = lobby and (lobby.roomId or lobby.code or lobby.id)
			if self:ShouldSuppressLobbyCandidate(roomId, "cached_lobby_payload") then
				online_flow_trace("lobby_search_room_filtered source=cache room=" .. tostring(roomId or "nil"))
			else
				lobbies[#lobbies + 1] = lobby
			end
		end
	end

	local onlinePlayers = {}
	if decodedOnlineUsers ~= nil then
		for user in ivalues(decodedOnlineUsers or {}) do
			rawOnlineUserIds[#rawOnlineUserIds + 1] = tostring(user.id or "?")
			local presenceIdentity = type(user.presence_identity) == "table" and user.presence_identity or {}
			local viewerSession = type(presenceIdentity.viewer_session) == "table" and presenceIdentity.viewer_session or {}
			local presenceId = presenceIdentity.presence_id or presenceIdentity.presenceId or user.presence_id or user.presenceId
			local presenceKey = tostring(presenceIdentity.model or "presence") .. ":" .. tostring(presenceId or "?") .. ":user:" .. tostring(user.id or "?")
			rawPresenceIdentities[#rawPresenceIdentities + 1] = presenceKey
			local isViewerPresence = presenceIdentity.is_viewer == true or presenceIdentity.isViewer == true
			local isSelf = isViewerPresence
			if isSelf then
				selfOnlineUserFiltered = selfOnlineUserFiltered + 1
				selfPresenceIdentities[#selfPresenceIdentities + 1] = presenceKey
				if viewerSession.api_token_id or viewerSession.apiTokenId then
					selfPresenceSessionIds[#selfPresenceSessionIds + 1] = tostring(viewerSession.api_token_id or viewerSession.apiTokenId)
				end
				if viewerSession.device_name or viewerSession.deviceName then
					selfPresenceDevices[#selfPresenceDevices + 1] = tostring(viewerSession.device_name or viewerSession.deviceName)
				end
			else
				local sameAccountNonViewer = self.user and tonumber(user.id) == tonumber(self.user.id)
				if sameAccountNonViewer then
					retainedSameAccountPresenceIds[#retainedSameAccountPresenceIds + 1] = tostring(presenceId or "?")
					local apiTokenId = presenceIdentity.api_token_id or presenceIdentity.apiTokenId
					if apiTokenId then
						retainedSameAccountSessionIds[#retainedSameAccountSessionIds + 1] = tostring(apiTokenId)
					end
					online_flow_trace("lobby_search_presence_retained_same_account"
						.. " userId=" .. tostring(user.id or "?")
						.. " selfUserId=" .. tostring(self.user and self.user.id or "nil")
						.. " presenceKey=" .. tostring(presenceKey)
						.. " apiTokenId=" .. tostring(apiTokenId or "nil")
						.. " isViewerPresence=" .. tostring(isViewerPresence)
						.. " status=" .. tostring(user.status or "nil")
						.. " roomId=" .. tostring(user.room and user.room.id or "nil"))
				end
				onlinePlayers[#onlinePlayers + 1] = {
					id = user.id,
					name = user_display_name(user, "User " .. tostring(user.id or "?")),
					displayName = user.display_name or user.displayName or user.name,
					status = user.status or "available",
					room = user.room,
					lastSeenAt = user.last_seen_at,
					presenceIdentity = user.presence_identity,
					isSelf = false,
				}
				displayOnlineUserIds[#displayOnlineUserIds + 1] = tostring(user.id or "?")
			end
		end
	else
		for player in ivalues(cachedPayload.onlinePlayers or {}) do
			onlinePlayers[#onlinePlayers + 1] = player
			displayOnlineUserIds[#displayOnlineUserIds + 1] = tostring(player.id or "?")
		end
	end

	local selfOnlyPresenceFiltered = decodedOnlineUsers ~= nil
		and rawOnlineUserCount > 0
		and rawOnlineUserCount == selfOnlineUserFiltered
		and #onlinePlayers == 0

	local payload = {
		lobbies = lobbies,
		onlinePlayers = onlinePlayers,
		presenceDiagnostics = {
			rawOnlineUserCount = rawOnlineUserCount,
			selfOnlineUserFiltered = selfOnlineUserFiltered,
			selfOnlyPresenceFiltered = selfOnlyPresenceFiltered,
			rawOnlineUserIds = rawOnlineUserIds,
			displayOnlineUserIds = displayOnlineUserIds,
			rawPresenceIdentities = rawPresenceIdentities,
			selfPresenceIdentities = selfPresenceIdentities,
			selfPresenceSessionIds = selfPresenceSessionIds,
			selfPresenceDevices = selfPresenceDevices,
			retainedSameAccountPresenceIds = retainedSameAccountPresenceIds,
			retainedSameAccountSessionIds = retainedSameAccountSessionIds,
		},
	}

	self.cachedLobbySearchPayload = payload
	online_flow_trace("lobby_search_payload_built source=" .. tostring(source)
		.. " onlineUsersField=" .. tostring(decodedOnlineUsersSource)
		.. " rawPublicRooms=" .. tostring(rawPublicRoomCount)
		.. " rawOnlineUsers=" .. tostring(rawOnlineUserCount)
		.. " normalizedLobbies=" .. tostring(#lobbies)
		.. " normalizedOnlinePlayers=" .. tostring(#onlinePlayers)
		.. " displayOnlinePlayers=" .. tostring(#onlinePlayers)
		.. " selfOnlineUserFiltered=" .. tostring(selfOnlineUserFiltered)
		.. " selfOnlyPresenceFiltered=" .. tostring(selfOnlyPresenceFiltered)
		.. " rawOnlineUserIds=" .. table.concat(rawOnlineUserIds, ",")
		.. " displayOnlineUserIds=" .. table.concat(displayOnlineUserIds, ",")
		.. " rawPresenceIdentities=" .. table.concat(rawPresenceIdentities, ",")
		.. " selfPresenceIdentities=" .. table.concat(selfPresenceIdentities, ",")
		.. " selfPresenceSessionIds=" .. table.concat(selfPresenceSessionIds, ",")
		.. " selfPresenceDevices=" .. table.concat(selfPresenceDevices, ",")
		.. " retainedSameAccountPresenceIds=" .. table.concat(retainedSameAccountPresenceIds, ",")
		.. " retainedSameAccountSessionIds=" .. table.concat(retainedSameAccountSessionIds, ",")
		.. " selfUserId=" .. tostring(self.user and self.user.id or "nil")
		.. " authInvalidated=" .. tostring(self.authSessionInvalidated == true)
		.. " authInvalidatedReason=" .. tostring(self.authSessionInvalidatedReason or "")
		.. " usedCachedLobbies=" .. tostring(not (decoded and decoded.public_rooms ~= nil))
		.. " usedCachedOnlinePlayers=" .. tostring(decodedOnlineUsers == nil)
		.. " cachedOnlinePlayers=" .. tostring(cachedPayload.onlinePlayers and #cachedPayload.onlinePlayers or 0)
		.. " currentRoomId=" .. tostring(self.currentRoomId or "nil")
		.. " screen=" .. tostring(self.currentScreenName or "nil"))
	return payload
end

function ITGOnline:LobbyStatePayload(room)
	room = room or self.currentRoom
	if not room then return { code = "", players = {} } end
	self:UpdateScheduledStart(room)
	self:MaybeAckScheduledStart(room)
	local globalOptions = self:NormalizeGlobalOptions(room.global_options)

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
	if room.phase == "config" then
		screenName = "ScreenPlayerOptions"
	elseif room.phase == "starting" or room.phase == "playing" then
		screenName = "ScreenGameplay"
	elseif room.phase == "results" then
		screenName = "ScreenOnlineLobbies"
	end
	local players = {}
	local playersByUserId = {}
	for member in ivalues(room.members or {}) do
		local user = member.user or member
		local userId = tostring(user.id or member.user_id or "")
		local session = playByUserId[userId] or {}
		local state = tostring(session.state or member.play_state or "pending")
		local memberScreenName = screenName
		local songAvailable = nil
		if member.song_available == true then
			songAvailable = true
		elseif member.song_available == false or member.song_available == 0 then
			songAvailable = false
		end
		if (room.phase == "config" or room.phase == "starting") and songAvailable ~= true then
			memberScreenName = "ScreenOnlineLobbies"
		elseif room.phase == "playing" and state ~= "playing" then
			memberScreenName = "ScreenOnlineLobbies"
		elseif room.phase == "results" then
			if member.returned_to_lobby == true or state == "returned_to_lobby" then
				memberScreenName = "ScreenOnlineLobbies"
			elseif state == "finished" or state == "failed" or state == "disconnected" or member.waiting_on_evaluation == true then
				memberScreenName = "ScreenEvaluationStage"
			end
		end
			local liveScore = liveScoreByUserId[userId] or {}
			local selectedMaxScore = tonumber(room.selected_song and room.selected_song.max_score) or 0
			local scorePercent = tonumber(liveScore.accuracy or session.last_accuracy)
			local displayedPercent = tonumber(liveScore.displayed_percent or liveScore.displayedPercent or session.last_displayed_percent)
			local exPercent = tonumber(liveScore.score_percent)
			if exPercent == nil and selectedMaxScore > 0 and tonumber(liveScore.score or session.last_score) then
				exPercent = math.max(0, math.min(100, (tonumber(liveScore.score or session.last_score) / selectedMaxScore) * 100))
			end
		-- Unified online score semantics:
		-- - `score` is what we treat as the canonical displayed competition percentage.
		-- - `accuracy` keeps the judgment-derived metric for diagnostics.
		if displayedPercent == nil then
			displayedPercent = exPercent or scorePercent
		end
			local localOptimisticConfigReady = self.user
				and tonumber(self.user.id) == tonumber(userId)
				and self:CurrentUserHasOptimisticConfigReady(room)
				and readyByUserId[userId] ~= true
			local playerPayload = {
				playerId = userId,
				profileName = user_display_name(user, "Player " .. userId),
				screenName = memberScreenName,
				ready = readyByUserId[userId] == true,
				readyPendingServer = localOptimisticConfigReady,
				missingSong = member.missing_song and true or false,
				missingSongReason = member.missing_song_reason,
				missingSongAt = member.missing_song_at,
				packSyncDownloadStartedAt = member.pack_sync_download_started_at,
				packSyncDownloadDeadlineMs = member.pack_sync_download_deadline_ms,
				songAvailable = songAvailable,
				packSyncStatus = member.pack_sync_status or "unknown",
				packSyncMessage = member.pack_sync_message,
				packSyncDownloadProgress = member.pack_sync_download_progress,
				packSyncSequence = member.pack_sync_sequence,
				packSyncUpdatedAt = member.pack_sync_updated_at,
				waitingOnEvaluation = member.waiting_on_evaluation == true,
				returnedToLobby = member.returned_to_lobby == true,
				speedMod = member.options and member.options.speed_mod or nil,
				musicRateBpm = member.options and member.options.music_rate_bpm or nil,
				stepchart = member.options and member.options.stepchart or nil,
				playState = state,
				isPlayingSong = state == "playing" and room.phase == "playing",
				score = displayedPercent,
				accuracy = scorePercent,
				exScore = exPercent,
			}
			players[#players + 1] = playerPayload
			if userId ~= "" then playersByUserId[userId] = playerPayload end
	end

	if self:NormalizeRoomPhase(room.phase) == "results" and type(playState.final_results) == "table" then
		for result in ivalues(playState.final_results) do
			if type(result) == "table" then
				local user = type(result.user) == "table" and result.user or {}
				local userId = tostring(user.id or result.user_id or "")
				if userId ~= "" and not playersByUserId[userId] then
					local displayedPercent = tonumber(result.displayed_percent or result.displayedPercent or result.score_percent or result.accuracy)
					local playerPayload = {
						playerId = userId,
						profileName = user_display_name(user, "Player " .. userId),
						screenName = "ScreenEvaluationStage",
						ready = false,
						readyPendingServer = false,
						missingSong = false,
						songAvailable = true,
						packSyncStatus = "ready",
						packSyncMessage = nil,
						packSyncDownloadProgress = nil,
						packSyncSequence = nil,
						packSyncUpdatedAt = nil,
						playState = result.failed and "failed" or "finished",
						isPlayingSong = false,
						score = displayedPercent,
						accuracy = tonumber(result.accuracy),
						exScore = tonumber(result.score_percent),
					}
					players[#players + 1] = playerPayload
					playersByUserId[userId] = playerPayload
					online_flow_trace("lobby_state_payload_final_result_player_restored"
						.. " room=" .. tostring(room.id or self.currentRoomId or "nil")
						.. " userId=" .. tostring(userId)
						.. " name=" .. tostring(playerPayload.profileName or "")
						.. " displayedPercent=" .. tostring(displayedPercent or "nil")
						.. " failed=" .. tostring(result.failed == true))
				end
			end
		end
	end

	local songInfo = nil
	local songSource = room.selected_song
	if self:NormalizeRoomPhase(room.phase) == "results" and (not songSource or not songSource.chart_hash) then
		songSource = self.lastResultSongPayload or self.activeGameplaySongPayload or self.currentSongPayload
	end
	if songSource then
			songInfo = {
				songPath = songSource.folder_name or "",
				title = songSource.title or "",
				artist = songSource.artist or "",
				pack = songSource.pack or tostring(songSource.folder_name or ""):match("^([^/]+)") or "",
				songLength = songSource.music_length_seconds or songSource.chart_duration_seconds,
					songHash = songSource.song_hash or "",
					chartHash = songSource.chart_hash or "",
					chartKey = songSource.chart_key or "",
					simfileRelativePath = songSource.simfile_relative_path or "",
					simfileHash = songSource.simfile_hash or songSource.chart_hash or "",
					selectedAt = songSource.selected_at or "",
					roundId = songSource.game_session_id or songSource.session_id or songSource.round_id or songSource.selected_song_id or "",
				chartType = songSource.chart_type or "",
			difficulty = songSource.difficulty or "",
			meter = songSource.meter,
			rate = songSource.rate or globalOptions.music_rate,
		}
	end

		local payload = {
			code = tostring(room.id),
			roomId = room.id,
			phase = room.phase,
			snapshotSource = room.online_snapshot_source,
			acceptsNewMembers = room.accepts_new_members == true,
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
			finalResults = self:NormalizeRoomPhase(room.phase) == "results" and (playState.final_results or {}) or {},
			secondsUntilStart = self:SecondsUntilScheduledStart(),
			manager = room.manager,
			isManager = self.user and room.manager and tonumber(room.manager.id) == tonumber(self.user.id) or false,
			globalOptions = globalOptions,
			players = players,
		songInfo = songInfo,
	}
	online_flow_trace("lobby_state_payload_built room=" .. tostring(payload.roomId or "nil")
		.. " phase=" .. tostring(payload.phase or "nil")
		.. " source=" .. tostring(payload.snapshotSource or "nil")
		.. " players=" .. tostring(#players)
		.. " isManager=" .. tostring(payload.isManager == true)
		.. " manager=" .. tostring(payload.manager and payload.manager.id or "nil")
		.. " hasSong=" .. tostring(songInfo ~= nil)
		.. " song=" .. tostring(songInfo and (songInfo.title or songInfo.songHash) or "none")
		.. " playSessions=" .. tostring(playState.sessions and #playState.sessions or 0)
		.. " finalResults=" .. tostring(payload.finalResults and #payload.finalResults or 0))
	return payload
end
