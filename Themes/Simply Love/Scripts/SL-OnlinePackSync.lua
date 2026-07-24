-- -----------------------------------------------------------------------
-- Online Pack Sync
--
-- Finds the manager-selected chart locally by hash, reports per-player
-- synchronization state, and downloads missing packs from StepManiaOnline
-- only after a selected chart cannot be matched locally.

ITGOnline = ITGOnline or {}
ITGOnline.PackSync = ITGOnline.PackSync or {}

local PackSync = ITGOnline.PackSync

local function local_success_response(source)
	return {
		statusCode = 200,
		transportAttempted = false,
		localOnly = true,
		source = tostring(source or "local_success"),
	}
end

local function pack_text(key, fallback, ...)
	local value = fallback or key
	if THEME and THEME.HasString and THEME:HasString("ScreenOnlineLobbies", key) then
		value = THEME:GetString("ScreenOnlineLobbies", key)
	end
	if select("#", ...) > 0 then
		local ok, formatted = pcall(string.format, value, ...)
		if ok then return formatted end
	end
	return value
end

PackSync.scriptVersion = "2026-06-21-pack-status-download-sequence-v2"
PackSync.statusChangedAt = PackSync.statusChangedAt or 0
PackSync.currentStatusMessage = PackSync.currentStatusMessage or nil
PackSync.currentStatusProgress = tonumber(PackSync.currentStatusProgress) or 0
PackSync.watchdogLastKey = PackSync.watchdogLastKey or ""
PackSync.watchdogTimeoutSeconds = PackSync.watchdogTimeoutSeconds or 25
PackSync.activeBrowseOnlyDownload = PackSync.activeBrowseOnlyDownload or false
PackSync.installedPackNames = PackSync.installedPackNames or {}
PackSync.browsePreviewPackKey = PackSync.browsePreviewPackKey or ""
PackSync.downloadedPackKey = PackSync.downloadedPackKey or ""
PackSync.downloadGeneration = tonumber(PackSync.downloadGeneration) or 0
PackSync.downloadStatusSequence = tonumber(PackSync.downloadStatusSequence) or 0
PackSync.activeDownloadId = PackSync.activeDownloadId or ""
PackSync.lastDownloadId = PackSync.lastDownloadId or ""
PackSync.activeDownloadSelectionId = PackSync.activeDownloadSelectionId or ""
PackSync.lastDownloadSelectionId = PackSync.lastDownloadSelectionId or ""
PackSync.downloadFuture = PackSync.downloadFuture or nil
PackSync.localScanCache = PackSync.localScanCache or {}
PackSync.lastPostedStatusSignature = PackSync.lastPostedStatusSignature or ""
PackSync.lastPostedStatusAt = tonumber(PackSync.lastPostedStatusAt) or 0
PackSync.statusPostInFlightSignature = PackSync.statusPostInFlightSignature or ""
PackSync.statusPostInFlightCallbacks = PackSync.statusPostInFlightCallbacks or {}
PackSync.statusPostInFlightStartedAt = tonumber(PackSync.statusPostInFlightStartedAt) or 0
PackSync.statusPostInFlightTimeoutSeconds = tonumber(PackSync.statusPostInFlightTimeoutSeconds) or 15
PackSync.statusPostPendingIntent = PackSync.statusPostPendingIntent or nil
PackSync.statusPostRequestToken = tonumber(PackSync.statusPostRequestToken) or 0
PackSync.statusPostActiveRequestToken = tonumber(PackSync.statusPostActiveRequestToken) or 0
PackSync.lastAppliedLocalStatusSignature = PackSync.lastAppliedLocalStatusSignature or ""
PackSync.lastAppliedLocalStatusAt = tonumber(PackSync.lastAppliedLocalStatusAt) or 0
PackSync.localStatusDuplicateSuppressSeconds = tonumber(PackSync.localStatusDuplicateSuppressSeconds) or 0.35
PackSync.statusPostDuplicateHeartbeatSeconds = tonumber(PackSync.statusPostDuplicateHeartbeatSeconds) or 5.0
PackSync.downloadHeartbeatSeconds = tonumber(PackSync.downloadHeartbeatSeconds) or 10.0
PackSync.lastManagerBrowsingPreviewPostKey = PackSync.lastManagerBrowsingPreviewPostKey or ""
PackSync.lastManagerBrowsingPreviewPostAt = tonumber(PackSync.lastManagerBrowsingPreviewPostAt) or 0
PackSync.managerBrowsingPreviewDuplicateSuppressSeconds = tonumber(PackSync.managerBrowsingPreviewDuplicateSuppressSeconds) or 1.5
PackSync.pendingBrowseCompletionRetryAt = tonumber(PackSync.pendingBrowseCompletionRetryAt) or 0
PackSync.pendingBrowseCompletionRetryCount = tonumber(PackSync.pendingBrowseCompletionRetryCount) or 0
PackSync.pendingSelectedAvailabilitySongInfo = PackSync.pendingSelectedAvailabilitySongInfo or nil
PackSync.pendingSelectedAvailabilityMessage = PackSync.pendingSelectedAvailabilityMessage or nil
PackSync.pendingSelectedAvailabilityRetryAt = tonumber(PackSync.pendingSelectedAvailabilityRetryAt) or 0
PackSync.pendingSelectedAvailabilityRetryCount = tonumber(PackSync.pendingSelectedAvailabilityRetryCount) or 0
PackSync.selectedAvailabilityInFlight = PackSync.selectedAvailabilityInFlight or false
PackSync.lastResetSignature = PackSync.lastResetSignature or ""
PackSync.lastResetAt = tonumber(PackSync.lastResetAt) or 0
PackSync.lastNoSongClearResetAt = tonumber(PackSync.lastNoSongClearResetAt) or 0
PackSync.lastNoSongClearResetReason = PackSync.lastNoSongClearResetReason or ""
PackSync.lastDeferredLocalMatchTraceKey = PackSync.lastDeferredLocalMatchTraceKey or ""
PackSync.lastDeferredApplyKey = PackSync.lastDeferredApplyKey or ""
PackSync.lastTerminalApplyKey = PackSync.lastTerminalApplyKey or ""
PackSync.lastTerminalApplyStatus = PackSync.lastTerminalApplyStatus or ""
PackSync.maxDownloadBytes = 5 * 1024 * 1024 * 1024
PackSync.minimumDownloadFreeBytes = 256 * 1024 * 1024
PackSync.maxArchiveUncompressedBytes = 5 * 1024 * 1024 * 1024
PackSync.extractionReserveBytes = PackSync.maxArchiveUncompressedBytes
PackSync.diskSafetyMarginBytes = 256 * 1024 * 1024

PackSync.status = {
	Unknown = "unknown",
	Ready = "ready",
	ManagerBrowsingUnknownPack = "manager_browsing_unknown_pack",
	SearchingLocalCharts = "searching_local_charts",
	LocalChartMatchFound = "local_chart_match_found",
	NoCompatibleChartFound = "no_compatible_chart_found",
	AwaitingPackChoice = "awaiting_pack_choice",
	DownloadRequested = "download_requested",
	DownloadInProgress = "download_in_progress",
	DownloadFailed = "download_failed",
	ReloadingSongs = "reloading_songs",
	ValidatingDownload = "validating_download",
	DownloadedOk = "downloaded_ok",
	ChartMismatch = "chart_mismatch",
}

PackSync.statusText = {
	unknown = "Unknown status",
	ready = "Ready",
	manager_browsing_unknown_pack = "Pack missing - download after selection",
	searching_local_charts = "Searching local charts",
	local_chart_match_found = "Compatible chart found",
	no_compatible_chart_found = "No compatible chart",
	awaiting_pack_choice = "Choose a pack",
	download_requested = "Download requested",
	download_in_progress = "Download in progress",
	download_failed = "Download failed",
	reloading_songs = "Reloading songs",
	validating_download = "Validating downloaded chart",
	downloaded_ok = "Download complete",
	chart_mismatch = "Different chart",
}

PackSync.statusTextKeys = {
	unknown = "PackStatusUnknown",
	ready = "PackStatusReady",
	manager_browsing_unknown_pack = "PackStatusManagerBrowsingUnknown",
	searching_local_charts = "PackStatusSearchingLocal",
	local_chart_match_found = "PackStatusCompatibleFound",
	no_compatible_chart_found = "PackStatusNoCompatible",
	awaiting_pack_choice = "PackStatusAwaitingChoice",
	download_requested = "PackStatusDownloadRequested",
	download_in_progress = "PackStatusDownloadInProgress",
	download_failed = "PackStatusDownloadFailed",
	reloading_songs = "PackStatusReloadingSongs",
	validating_download = "PackStatusValidatingDownload",
	downloaded_ok = "PackStatusDownloaded",
	chart_mismatch = "PackStatusChartMismatch",
}

local function early_trim(value)
	return tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local trace
local current_room_selected_at
local current_room_selection_id

function PackSync:IsActiveDownloadStatus(status)
	status = tostring(status or self.currentStatus or "")
	return status == self.status.DownloadRequested
		or status == self.status.DownloadInProgress
		or status == self.status.ReloadingSongs
		or status == self.status.ValidatingDownload
end

function PackSync:IsActiveDownload()
	return self:IsActiveDownloadStatus(self.currentStatus)
		or early_trim(self.downloadInFlightKey) ~= ""
		or self.activeBrowseOnlyDownload == true
		or self.pendingPostReloadSongInfo ~= nil
end

function PackSync:HasDownloadWorkInFlight()
	return self:IsActiveDownloadStatus(self.currentStatus)
		or early_trim(self.downloadInFlightKey) ~= ""
		or self.pendingPostReloadSongInfo ~= nil
end

function PackSync:ClearActiveDownloadId(reason)
	if early_trim(self.activeDownloadId) == "" then return end
	self.lastDownloadId = self.activeDownloadId
	self.lastDownloadSelectionId = self.activeDownloadSelectionId or ""
	trace("Active download id cleared reason=" .. tostring(reason or "unknown")
		.. " activeDownloadId=" .. tostring(self.activeDownloadId)
		.. " status=" .. tostring(self.currentStatus or "nil")
		.. " key=" .. tostring(self.downloadInFlightKey or ""))
	self.activeDownloadId = ""
	self.activeDownloadSelectionId = ""
end

function PackSync:UsesDownloadStatusSequence(status)
	status = tostring(status or "")
	return status == self.status.DownloadRequested
		or status == self.status.DownloadInProgress
		or status == self.status.ReloadingSongs
		or status == self.status.DownloadedOk
		or status == self.status.DownloadFailed
end

function PackSync:IsTerminalDownloadStatus(status)
	status = tostring(status or "")
	return status == self.status.DownloadedOk or status == self.status.DownloadFailed
end

function PackSync:ShouldPreserveActiveDownloadDuringReset(reason)
	if not self:HasDownloadWorkInFlight() then
		if self.currentStatus == self.status.Ready or self.currentStatus == self.status.DownloadedOk then
			self:ClearActiveDownloadId("reset_preserve_check_completed:" .. tostring(reason or "unknown"))
		end
		return false
	end

	reason = tostring(reason or "unknown")
	local preserveActiveDownload = reason == "no_song_confirmed"
		or reason == "online_lobby_state_clear_unconfirmed_preview"
		or reason == "song_selection_cancelled"
		or reason == "song_preview_cleared"
	if preserveActiveDownload then
		trace("Reset will preserve active download reason=" .. tostring(reason)
			.. " status=" .. tostring(self.currentStatus or "nil")
			.. " key=" .. tostring(self.downloadInFlightKey or "")
			.. " activeDownloadId=" .. tostring(self.activeDownloadId or ""))
		return true
	end

	trace("Reset will cancel active download reason=" .. tostring(reason)
		.. " status=" .. tostring(self.currentStatus or "nil")
		.. " key=" .. tostring(self.downloadInFlightKey or "")
		.. " activeDownloadId=" .. tostring(self.activeDownloadId or ""))
	return false
end

local function safe_invoke_callback(callback, ...)
	if type(callback) ~= "function" then return end
	local ok, err = pcall(callback, ...)
	if not ok then
		trace("Callback failed err=" .. tostring(err))
	end
end

local function runtime_validation_trace(message)
	if not (PREFSMAN and PREFSMAN.GetPreference) then return end
	local ok, enabled = pcall(function() return PREFSMAN:GetPreference("runtime_validation") end)
	if not ok or enabled ~= true then return end
	local line = "RUNTIME_VALIDATION [OnlinePackSync] " .. tostring(message or "")
	if Trace then Trace(line) elseif Warn then Warn(line) end
end

function PackSync:DiscardPendingStatusPost(reason)
	local pending = self.statusPostPendingIntent
	if type(pending) ~= "table" then return false end
	self.statusPostPendingIntent = nil
	for _, pendingCallback in ipairs(pending.callbacks or {}) do
		safe_invoke_callback(pendingCallback, false, nil, {
			errorCode = "client_status_post_coalesced",
			errorMessage = pack_text("PackStatusSuperseded", "The online status was replaced by a newer state."),
		})
	end
	runtime_validation_trace("discarded pending pack status reason=" .. tostring(reason or "unknown")
		.. " status=" .. tostring(pending.status or "nil")
		.. " signature=" .. tostring(pending.signature or ""))
	return true
end

function PackSync:QueuePendingStatusPost(signature, status, message, progress, callback, options, roomId, selectedAt)
	local pending = self.statusPostPendingIntent
	if type(pending) == "table" and tostring(pending.signature or "") == tostring(signature or "") then
		if callback then
			pending.callbacks = pending.callbacks or {}
			if #pending.callbacks < 16 then
				pending.callbacks[#pending.callbacks + 1] = callback
			else
				safe_invoke_callback(callback, false, nil, {
					errorMessage = pack_text("TooManyPendingPackStatuses", "Too many online pack statuses are pending.")
				})
			end
		end
		return
	end

	self:DiscardPendingStatusPost("superseded_by_newer_status")
	local queuedOptions = {}
	for key, value in pairs(type(options) == "table" and options or {}) do
		queuedOptions[key] = value
	end
	queuedOptions.fromPendingStatusQueue = true
	self.statusPostPendingIntent = {
		signature = signature,
		status = status,
		message = message,
		progress = progress,
		options = queuedOptions,
		roomId = tostring(roomId or ""),
		selectedAt = tostring(selectedAt or ""),
		callbacks = callback and { callback } or {},
	}
	runtime_validation_trace("queued latest pack status while request is active status=" .. tostring(status)
		.. " room=" .. tostring(roomId or "")
		.. " selected_at=" .. tostring(selectedAt or ""))
end

function PackSync:FlushPendingStatusPost(reason)
	local pending = self.statusPostPendingIntent
	if type(pending) ~= "table" then return false end
	self.statusPostPendingIntent = nil
	local activeRoomId = tostring(ITGOnline and ITGOnline.currentRoomId or "")
	local activeSelectedAt = tostring(current_room_selected_at() or "")
	local immutableDownloadId = early_trim(pending.options and pending.options.downloadId)
	if activeRoomId ~= tostring(pending.roomId or "")
		or (immutableDownloadId == "" and activeSelectedAt ~= tostring(pending.selectedAt or "")) then
		for _, pendingCallback in ipairs(pending.callbacks or {}) do
			safe_invoke_callback(pendingCallback, false, nil, {
				errorCode = "client_status_context_changed",
				errorMessage = pack_text("PackStatusContextChanged", "The lobby or selection changed before the status was published."),
			})
		end
		runtime_validation_trace("dropped pending pack status after context change reason=" .. tostring(reason or "unknown")
			.. " queued_room=" .. tostring(pending.roomId or "")
			.. " active_room=" .. activeRoomId
			.. " queued_selected_at=" .. tostring(pending.selectedAt or "")
			.. " active_selected_at=" .. activeSelectedAt)
		return false
	end

	local callbacks = pending.callbacks or {}
	local function fan_out(...)
		for _, pendingCallback in ipairs(callbacks) do
			safe_invoke_callback(pendingCallback, ...)
		end
	end
	runtime_validation_trace("flushing latest queued pack status reason=" .. tostring(reason or "unknown")
		.. " status=" .. tostring(pending.status or "nil"))
	self:UpdateStatus(pending.status, pending.message, pending.progress,
		#callbacks > 0 and fan_out or nil, pending.options)
	return true
end

function PackSync:ExpireStatusPostInFlight(reason)
	local signature = tostring(self.statusPostInFlightSignature or "")
	if signature == "" then return false end
	local now = GetTimeSinceStart and GetTimeSinceStart() or 0
	local startedAt = tonumber(self.statusPostInFlightStartedAt) or 0
	local timeout = math.max(1, tonumber(self.statusPostInFlightTimeoutSeconds) or 15)
	if startedAt > 0 and (now - startedAt) < timeout then
		return false
	end

	local callbacks = self.statusPostInFlightCallbacks[signature] or {}
	self.statusPostInFlightCallbacks[signature] = nil
	self.statusPostInFlightSignature = ""
	self.statusPostInFlightStartedAt = 0
	self.statusPostActiveRequestToken = 0
	trace("Expired in-flight status post reason=" .. tostring(reason or "unknown")
		.. " signature=" .. tostring(signature)
		.. " age=" .. tostring(startedAt > 0 and string.format("%.3f", now - startedAt) or "unknown")
		.. " callbacks=" .. tostring(#callbacks))
	local response = { errorMessage = pack_text("PackStatusPublishTimeout", "Publishing the online status timed out.") }
	for _, queuedCallback in ipairs(callbacks) do
		safe_invoke_callback(queuedCallback, false, nil, response)
	end
	return true
end

function PackSync:CancelStatusPostInFlight(reason)
	local signature = tostring(self.statusPostInFlightSignature or "")
	if signature == "" then return false end

	local callbacks = self.statusPostInFlightCallbacks[signature] or {}
	self.statusPostInFlightCallbacks[signature] = nil
	self.statusPostInFlightSignature = ""
	self.statusPostInFlightStartedAt = 0
	self.statusPostActiveRequestToken = 0
	trace("Cancelled in-flight status post reason=" .. tostring(reason or "unknown")
		.. " signature=" .. tostring(signature)
		.. " callbacks=" .. tostring(#callbacks))
	local response = {
		errorCode = "client_status_post_cancelled",
		errorMessage = pack_text("PackStatusCancelledContextChanged", "Publishing the online status was cancelled because its context changed."),
	}
	for _, waitingCallback in ipairs(callbacks) do
		safe_invoke_callback(waitingCallback, false, nil, response)
	end
	return true
end

trace = function(message)
	if type(online_logs_enabled) == "function" and not online_logs_enabled() then
		return
	end
	local line = "pack_sync " .. tostring(message or "")
	if type(online_flow_trace) == "function" then
		online_flow_trace(line)
		return
	end
	local safeLine = type(online_safe_log_text) == "function"
		and online_safe_log_text(line, 4096)
		or tostring(line):gsub("[%c]", " ")
	if Trace then Trace("ITG Online FLOW: " .. safeLine) elseif Warn then Warn("ITG Online FLOW: " .. safeLine) end
end

local function trace_online_state(label, fields)
	if type(online_logs_enabled) == "function" and not online_logs_enabled() then
		return
	end
	if ITGOnline and ITGOnline.TraceOnlineState then
		fields = type(fields) == "table" and fields or {}
		fields.source = fields.source or "pack_sync"
		ITGOnline:TraceOnlineState("pack_sync_" .. tostring(label or "unknown"), fields)
	end
end

local function availability_confirmation_state(ok, decoded, response)
	local decodedTable = type(decoded) == "table" and decoded or {}
	local responseTable = type(response) == "table" and response or {}
	local deferred = decodedTable.deferred == true
		or responseTable.deferred == true
		or responseTable.downloadInProgress == true
	local reason = decodedTable.deferredReason
		or decodedTable.errorCode
		or decodedTable.error_code
		or responseTable.deferredReason
		or responseTable.errorCode
		or responseTable.error_code
		or responseTable.errorMessage
		or "nil"
	local retryAfter = tonumber(decodedTable.retryAfter or decodedTable.retry_after
		or responseTable.retryAfter or responseTable.retry_after)
	return ok == true, deferred == true, reason, retryAfter
end

local function local_member_pack_status(room)
	if type(room) ~= "table" then return "" end
	local localUserId = ITGOnline and ITGOnline.LocalUserId
		and tostring(ITGOnline:LocalUserId() or "") or ""
	if localUserId == "" then return "" end
	local members = room.players or room.members or room.room_members
	if type(members) ~= "table" then return "" end
	for _, member in pairs(members) do
		local user = type(member) == "table" and (member.user or member.player or {}) or {}
		local memberUserId = tostring((type(member) == "table" and
			(member.user_id or member.userId or member.player_id or member.playerId)) or user.id or "")
		if type(member) == "table" and memberUserId == localUserId then
			return tostring(member.pack_sync_status or member.status or "")
		end
	end
	return ""
end

trace("Loaded script version=" .. tostring(PackSync.scriptVersion))

local function download_already_in_progress_message()
	return pack_text("DownloadAlreadyInProgress", "A download is already in progress.")
end

local function status_progress_signature(progress)
	local numeric = tonumber(progress)
	if not numeric then
		return ""
	end
	if numeric < 0 then numeric = 0 end
	if numeric > 100 then numeric = 100 end
	return tostring(math.floor(numeric + 0.5))
end

local function status_post_signature(roomId, selectedAt, status, message, progress, options)
	return table.concat({
		tostring(roomId or ""),
		tostring(selectedAt or ""),
		tostring(status or ""),
		tostring(message or ""),
		status_progress_signature(progress),
		options and options.downloadCancelled and "cancelled" or "",
		tostring(options and options.downloadId or ""),
		tostring(options and options.downloadSelectionId or ""),
	}, "|")
end

local function current_user_is_active_room_member()
	if not (ITGOnline and ITGOnline.currentRoomId and ITGOnline.currentRoom and ITGOnline.user) then
		return false
	end
	local currentUserId = tostring(ITGOnline.user.id or "")
	local currentRoomId = tostring(ITGOnline.currentRoomId or "")
	if currentUserId == "" or currentRoomId == "" then
		return false
	end
	if tostring(ITGOnline.currentRoom.id or "") ~= currentRoomId then
		return false
	end
	local members = ITGOnline.currentRoom.members or ITGOnline.currentRoom.players or ITGOnline.currentRoom.room_members
	local memberCount = 0
	if type(members) == "table" then
		for _ in pairs(members) do
			memberCount = memberCount + 1
		end
	end
	if type(members) ~= "table" or memberCount == 0 then
		trace("Active room membership unavailable; refusing online pack sync action"
			.. " room=" .. tostring(currentRoomId)
			.. " hasMembers=" .. tostring(type(members) == "table")
			.. " count=" .. tostring(type(members) == "table" and memberCount or "nil")
			.. " status=" .. tostring(PackSync and PackSync.currentStatus or "nil")
			.. " key=" .. tostring(PackSync and PackSync.downloadInFlightKey or ""))
		return false
	end
	for _, member in pairs(members) do
		local memberTable = type(member) == "table" and member or {}
		local user = memberTable.user or memberTable.player or memberTable
		local userId = tostring(user.id or memberTable.user_id or memberTable.userId or memberTable.player_id or memberTable.playerId or "")
		if userId == currentUserId then
			return true
		end
	end
	return false
end

function PackSync:NextDownloadGeneration(reason)
	if self.downloadFuture and self.downloadFuture.Cancel then
		pcall(function() self.downloadFuture:Cancel() end)
		trace("Cancelled stale pack download before advancing generation=" .. tostring(self.downloadGeneration or 0))
	end
	self.downloadFuture = nil
	self.downloadGeneration = (tonumber(self.downloadGeneration) or 0) + 1
	self.downloadStatusSequence = math.max(tonumber(self.downloadStatusSequence) or 0, tonumber(self.sequence) or 0)
	reason = tostring(reason or "unknown")
	local startsDownload = reason == "download_selected_search"
		or reason == "download_browsing_search"
		or reason == "selected_candidate_start"
		or reason == "browse_candidate_start"
	if startsDownload then
		if early_trim(self.activeDownloadId) ~= "" then
			self:ClearActiveDownloadId("superseded_by_new_generation:" .. reason)
		end
		if ITGOnline and ITGOnline.NewClientActionId then
			self.activeDownloadId = ITGOnline:NewClientActionId("pack-download")
		else
			self.activeDownloadId = tostring(self.downloadGeneration) .. ":" .. tostring(math.floor(((GetTimeSinceStart and GetTimeSinceStart()) or 0) * 1000))
		end
		self.lastDownloadId = ""
		self.activeDownloadSelectionId = current_room_selection_id and current_room_selection_id() or ""
		self.lastDownloadSelectionId = ""
	else
		self:ClearActiveDownloadId("generation_advanced:" .. reason)
	end
	trace("Download generation advanced generation=" .. tostring(self.downloadGeneration)
		.. " reason=" .. tostring(reason)
		.. " activeDownloadId=" .. tostring(self.activeDownloadId)
		.. " downloadStatusSequence=" .. tostring(self.downloadStatusSequence))
	return self.downloadGeneration
end

function PackSync:IsDownloadGenerationCurrent(generation)
	return tonumber(generation) == tonumber(self.downloadGeneration)
end

local selected_at

function PackSync:SyncSequenceFromRoomPayload(room, currentSelectedAt, reason)
	if not (ITGOnline and ITGOnline.user and type(room) == "table") then return false end
	local selectedSong = room.selected_song or {}
	if tostring(currentSelectedAt or "") ~= "" and selected_at(selectedSong) ~= tostring(currentSelectedAt or "") then
		trace("SyncSequenceFromRoomPayload skipped reason=selected_at_mismatch requested="
			.. tostring(currentSelectedAt or "")
			.. " roomSelectedAt=" .. tostring(selected_at(selectedSong))
			.. " source=" .. tostring(reason or "unknown"))
		return false
	end

	local currentUserId = tostring(ITGOnline.user.id or "")
	if currentUserId == "" then return false end

	for member in ivalues(room.members or {}) do
		local user = member.user or {}
		local memberUserId = tostring(user.id or member.user_id or "")
		if memberUserId == currentUserId then
			local serverSequence = tonumber(member.pack_sync_sequence)
			if serverSequence and serverSequence > math.max(tonumber(self.sequence) or 0, tonumber(self.downloadStatusSequence) or 0) then
				trace("Pack sync sequence adopted source=" .. tostring(reason or "unknown")
					.. " local=" .. tostring(self.sequence or "nil")
					.. " downloadLocal=" .. tostring(self.downloadStatusSequence or "nil")
					.. " server=" .. tostring(serverSequence)
					.. " selected_at=" .. tostring(currentSelectedAt or ""))
				self.sequence = serverSequence
				self.downloadStatusSequence = math.max(tonumber(self.downloadStatusSequence) or 0, serverSequence)
				return true
			end
			return false
		end
	end
	return false
end

-- Selection identity and filesystem safety
-- -----------------------------------------------------------------------

local function trim(value)
	return tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function lower(value)
	return trim(value):lower()
end

local function normalized_hash(value)
	if ITGOnline and ITGOnline.NormalizeHash then
		return ITGOnline:NormalizeHash(value)
	end
	value = lower(value)
	return value:match("^[a-f0-9]+$") and #value == 64 and value or ""
end

local function selected_title(songInfo)
	return trim(songInfo and (songInfo.title or songInfo.name))
end

local function selected_artist(songInfo)
	return trim(songInfo and songInfo.artist)
end

local function selected_pack(songInfo)
	return trim(songInfo and songInfo.pack)
end

local function pack_name_key(packName)
	return lower(packName):gsub("%s+", " ")
end

local function selected_path(songInfo)
	return trim(songInfo and (songInfo.songPath or songInfo.folder_name or songInfo.folderName))
end

local function selected_chart_hash(songInfo)
	return normalized_hash(songInfo and (songInfo.chartHash or songInfo.chart_hash or songInfo.simfileHash or songInfo.simfile_hash))
end

local function selected_song_hash(songInfo)
	return normalized_hash(songInfo and (songInfo.songHash or songInfo.song_hash or songInfo.audio_file_hash))
end

local function selected_chart_key(songInfo)
	local key = trim(songInfo and (songInfo.chartKey or songInfo.chart_key))
	if key:match("^[Xx][A-Fa-f0-9]+$") then
		key = key:sub(2)
	end
	return key
end

function selected_at(songInfo)
	return trim(songInfo and (songInfo.selectedAt or songInfo.selected_at))
end

local function current_room_selected_song()
	return ITGOnline and ITGOnline.currentRoom and ITGOnline.currentRoom.selected_song or nil
end

current_room_selected_at = function()
	return selected_at(current_room_selected_song())
end

current_room_selection_id = function()
	local room = ITGOnline and ITGOnline.currentRoom or nil
	return trim(room and (room.current_selection_id or room.currentSelectionId))
end

local function song_info_matches_room_selection(songInfo, roomSong)
	if type(songInfo) ~= "table" or type(roomSong) ~= "table" then return false end

	local songHash = selected_song_hash(songInfo)
	local roomSongHash = selected_song_hash(roomSong)
	if songHash ~= "" and roomSongHash ~= "" and songHash == roomSongHash then
		return true
	end

	local chartHash = selected_chart_hash(songInfo)
	local roomChartHash = selected_chart_hash(roomSong)
	if chartHash ~= "" and roomChartHash ~= "" and chartHash == roomChartHash then
		return true
	end

	local path = selected_path(songInfo)
	local roomPath = selected_path(roomSong)
	if path ~= "" and roomPath ~= "" and path == roomPath then
		return true
	end

	local title = lower(selected_title(songInfo))
	local roomTitle = lower(selected_title(roomSong))
	local pack = pack_name_key(selected_pack(songInfo))
	local roomPack = pack_name_key(selected_pack(roomSong))
	return title ~= "" and title == roomTitle and pack ~= "" and pack == roomPack
end

local function with_current_room_selection(songInfo, reason)
	if type(songInfo) ~= "table" then return songInfo end
	if selected_at(songInfo) ~= "" then return songInfo end

	local roomSong = current_room_selected_song()
	local roomSelectedAt = current_room_selected_at()
	if roomSelectedAt == "" or not song_info_matches_room_selection(songInfo, roomSong) then
		return songInfo
	end

	local enriched = {}
	for key, value in pairs(songInfo) do
		enriched[key] = value
	end

	enriched.selected_at = roomSelectedAt
	enriched.selectedAt = roomSelectedAt
	enriched.song_hash = enriched.song_hash or enriched.songHash or roomSong.song_hash or roomSong.songHash
	enriched.songHash = enriched.songHash or enriched.song_hash
	enriched.audio_file_hash = enriched.audio_file_hash or roomSong.audio_file_hash
	enriched.chart_hash = enriched.chart_hash or enriched.chartHash or roomSong.chart_hash or roomSong.chartHash
	enriched.chartHash = enriched.chartHash or enriched.chart_hash
	enriched.chart_key = enriched.chart_key or enriched.chartKey or roomSong.chart_key or roomSong.chartKey
	enriched.chartKey = enriched.chartKey or enriched.chart_key
	enriched.folder_name = enriched.folder_name or enriched.folderName or roomSong.folder_name or roomSong.folderName
	enriched.folderName = enriched.folderName or enriched.folder_name

	trace("SongInfo enriched with current room selection"
		.. " reason=" .. tostring(reason or "unknown")
		.. " selected_at=" .. tostring(roomSelectedAt)
		.. " title=" .. tostring(selected_title(enriched))
		.. " pack=" .. tostring(selected_pack(enriched)))

	return enriched
end

local function split_path_segments(path)
	local segments = {}
	for segment in tostring(path or ""):gmatch("[^/]+") do
		segments[#segments + 1] = segment
	end
	return segments
end

local function status_message(value)
	value = trim(value)
	if #value > 240 then
		value = value:sub(1, 240)
	end
	return value ~= "" and value or nil
end

local MAX_SAFE_NAME_LENGTH = 96

local function limit_safe_name(value, suffix)
	value = trim(value)
	suffix = tostring(suffix or "")
	local maxBaseLength = math.max(1, MAX_SAFE_NAME_LENGTH - #suffix)
	if #value > maxBaseLength then
		value = value:sub(1, maxBaseLength)
	end
	return value .. suffix
end

local function safe_file_name(value)
	value = trim(value):gsub("[/\\:%c]", "_"):gsub("%.%.", "_")
	value = value:gsub("^%s+", ""):gsub("%s+$", "")
	if value == "" then value = "stepmaniaonline-pack" end
	if value:lower():match("%.zip$") then
		value = value:gsub("%.[Zz][Ii][Pp]$", "")
	end
	return limit_safe_name(value, ".zip")
end

local function safe_folder_name(value)
	value = trim(value):gsub("[/\\:%c]", "_"):gsub("%.%.", "_")
	value = value:gsub("^%s+", ""):gsub("%s+$", "")
	value = value:gsub("%.[Zz][Ii][Pp]$", "")
	if value == "" then value = "stepmaniaonline-pack" end
	return limit_safe_name(value)
end

local function pack_quarantine_path(packId, packName)
	local folderName = safe_folder_name("__OnlineDownload_" .. tostring(packId) .. "_" .. tostring(packName or "pack"))
	return "/Songs/" .. folderName .. "/"
end

local function remove_directory_if_possible(path)
	if not FILEMAN or not FILEMAN.DeleteRecursive then return end
	if not path or path == "" then return end
	local exists = true
	if FILEMAN.DoesFileExist then
		exists = FILEMAN:DoesFileExist(path)
	end
	if exists then
		FILEMAN:DeleteRecursive(path)
	end
end

local function rollback_installed_pack_if_possible(path)
	if not path or path == "" then return false end
	if FILEMAN and FILEMAN.RollbackOnlineSongPack then
		local ok, removed = pcall(function() return FILEMAN:RollbackOnlineSongPack(path) end)
		if ok and removed then return true end
		trace("Installed pack rollback failed path=<engine-pack-path>")
		return false
	end
	return false
end

local function create_directory_if_possible(path)
	if not FILEMAN or not FILEMAN.CreateDir then return end
	if not path or path == "" then return end
	FILEMAN:CreateDir(path)
end

local function path_exists(path)
	if not FILEMAN or not FILEMAN.DoesFileExist then return false end
	if not path or path == "" then return false end
	return FILEMAN:DoesFileExist(path) and true or false
end

local function pack_root_path(packName)
	packName = trim(packName)
	if packName == "" then return "" end
	if packName:find("[/\\]") or packName:find("%.%.") then
		trace("Pack root lookup rejected unsafe pack name=" .. tostring(packName))
		return ""
	end
	return "/Songs/" .. packName .. "/"
end

local function flush_dir_cache(path)
	if not FILEMAN or not FILEMAN.FlushDirCache then return end
	pcall(function() FILEMAN:FlushDirCache(path or "") end)
end

local function dir_listing(path, onlyDirs, returnPathToo)
	if not FILEMAN or not FILEMAN.GetDirListing then return {} end
	local ok, entries = pcall(function()
		return FILEMAN:GetDirListing(path, onlyDirs, returnPathToo)
	end)
	if not ok or type(entries) ~= "table" then return {} end
	return entries
end

local function safe_child_folder_name(value)
	value = tostring(value or "")
	if value == "" or value:find("[/\\]") or value:find("%.%.") then return "" end
	return value
end

local function is_temp_newdir_artifact(value)
	return tostring(value or ""):lower():match("%.temp%.newdir$") ~= nil
end

local function remove_temp_newdir_artifacts(path, maxDepth)
	if not path or path == "" or not FILEMAN then return end
	maxDepth = tonumber(maxDepth) or 0

	for _, entry in ivalues(dir_listing(path, false, true)) do
		if is_temp_newdir_artifact(entry) then
			if FILEMAN.DeleteRecursive then
				FILEMAN:DeleteRecursive(entry)
			elseif FILEMAN.Remove then
				FILEMAN:Remove(entry)
			end
		end
	end

	if maxDepth <= 0 then return end
	for _, folderName in ivalues(dir_listing(path, true, false)) do
		local safeName = safe_child_folder_name(folderName)
		if safeName ~= "" and not is_temp_newdir_artifact(safeName) then
			remove_temp_newdir_artifacts(path .. safeName .. "/", maxDepth - 1)
		end
	end
end

local function has_simfile_in_directory(path)
	for _, fileName in ivalues(dir_listing(path, false, true)) do
		local lowerName = tostring(fileName or ""):lower()
		if lowerName:match("%.sm$") or lowerName:match("%.ssc$") then
			return true
		end
	end
	return false
end

local function has_simfile_below_directory(path, maxDepth)
	if not path or path == "" then return false end
	maxDepth = tonumber(maxDepth) or 0
	if has_simfile_in_directory(path) then return true end
	if maxDepth <= 0 then return false end

	for _, folderName in ivalues(dir_listing(path, true, false)) do
		local safeName = safe_child_folder_name(folderName)
		if safeName ~= "" and not is_temp_newdir_artifact(safeName) and has_simfile_below_directory(path .. safeName .. "/", maxDepth - 1) then
			return true
		end
	end

	return false
end

local function single_nested_group_folder(quarantinePath, expectedPackName)
	if has_simfile_in_directory(quarantinePath) then return "" end

	local folders = {}
	for _, folderName in ivalues(dir_listing(quarantinePath, true, false)) do
		local safeName = safe_child_folder_name(folderName)
		if safeName ~= "" and not is_temp_newdir_artifact(safeName) then folders[#folders + 1] = safeName end
	end

	if #folders == 0 then
		local expectedName = safe_child_folder_name(expectedPackName)
		if expectedName ~= "" and (path_exists(quarantinePath .. expectedName) or path_exists(quarantinePath .. expectedName .. "/")) then
			trace("Using expected pack folder fallback name=" .. tostring(expectedName))
			return expectedName
		end
	end

	if #folders ~= 1 then return "" end
	local folderName = folders[1]
	local expectedName = safe_child_folder_name(expectedPackName)
	if expectedName ~= "" and pack_name_key(folderName) ~= pack_name_key(expectedName) then
		trace("Nested pack folder rejected reason=unexpected_name expected=" .. tostring(expectedName)
			.. " actual=" .. tostring(folderName))
		return ""
	end
	for _, entryName in ivalues(dir_listing(quarantinePath, false, false)) do
		if entryName ~= folderName and not is_temp_newdir_artifact(entryName) then
			return ""
		end
	end

	return folders[1]
end

local function set_current_selection(song, steps, songInfo, source)
	if not (GAMESTATE and song) then return end
	if GAMESTATE.SetCurrentSong then
		local ok, err = pcall(function() GAMESTATE:SetCurrentSong(song) end)
		if not ok then
			trace("SetCurrentSong failed source=" .. tostring(source or "unknown") .. " err=" .. tostring(err))
			return
		end
	end
	if steps and GAMESTATE.GetEnabledPlayers and GAMESTATE.SetCurrentSteps then
		for player in ivalues(GAMESTATE:GetEnabledPlayers() or {}) do
			local playerSteps = steps
			if ITGOnline and ITGOnline.ResolveLocalGameplayStepsForSelectedSong then
				playerSteps = ITGOnline:ResolveLocalGameplayStepsForSelectedSong(
					songInfo,
					steps,
					source or "pack_sync_set_current_selection",
					player
				)
			end
			if not playerSteps then
				trace("SetCurrentSteps skipped reason=no_player_chart"
					.. " source=" .. tostring(source or "unknown")
					.. " player=" .. tostring(player))
			end
			local ok, err = pcall(function()
				if playerSteps then GAMESTATE:SetCurrentSteps(player, playerSteps) end
			end)
			if not ok then
				trace("SetCurrentSteps failed source=" .. tostring(source or "unknown")
					.. " player=" .. tostring(player)
					.. " err=" .. tostring(err))
			end
		end
	end
end

local function transition_to_reload_songs()
	local topScreen = SCREENMAN and SCREENMAN:GetTopScreen() or nil
	if not topScreen then
		if online_flow_trace then
			online_flow_trace("pack_sync_reload_songs_skipped reason=no_top_screen")
		end
		return false
	end

	if topScreen:GetName() == "ScreenReloadSongsOnline" then
		if online_flow_trace then
			online_flow_trace("pack_sync_reload_songs_skipped reason=already_reloading")
		end
		return true
	end

	if online_flow_trace then
		online_flow_trace("pack_sync_reload_songs_transition from=" .. tostring(topScreen:GetName()))
	end
	local ok, err = pcall(function()
		topScreen:SetNextScreenName("ScreenReloadSongsOnline")
		topScreen:StartTransitioningScreen("SM_GoToNextScreen")
	end)
	if not ok and SCREENMAN and SCREENMAN.SetNewScreen then
		ok, err = pcall(function() SCREENMAN:SetNewScreen("ScreenReloadSongsOnline") end)
	end
	if not ok then
		if online_flow_trace then
			online_flow_trace("pack_sync_reload_songs_failed error=" .. tostring(err or "unknown"))
		end
		return false
	end
	if SL and SL.Global then
		SL.Global.Online = SL.Global.Online or {}
		SL.Global.Online.ReturnToLobbyAfterSongReload = true
	end
	return true
end

local function playable_steps(song)
	if not song then return {} end
	if SongUtil and SongUtil.GetPlayableSteps then
		local ok, steps = pcall(function() return SongUtil.GetPlayableSteps(song) end)
		if ok and type(steps) == "table" then return steps end
	end
	local style = GAMESTATE and GAMESTATE.GetCurrentStyle and GAMESTATE:GetCurrentStyle() or nil
	local stepsType = style and style:GetStepsType() or nil
	if stepsType and song.GetStepsByStepsType then
		local ok, steps = pcall(function() return song:GetStepsByStepsType(stepsType) end)
		if ok and type(steps) == "table" then return steps end
	end
	return {}
end

local function chart_hash_for_steps(steps)
	if not steps then return "" end
	if ITGOnline and ITGOnline.ChartHashForSteps then
		return tostring(ITGOnline:ChartHashForSteps(steps) or "")
	end
	return ""
end

local function song_count_key()
	if not SONGMAN or not SONGMAN.GetAllSongs then return "" end
	local ok, songs = pcall(function() return SONGMAN:GetAllSongs() end)
	if not ok or type(songs) ~= "table" then return "" end
	return tostring(#songs)
end

local function local_song_library_key()
	if not SONGMAN or not SONGMAN.GetAllSongs then return "" end
	local ok, songs = pcall(function() return SONGMAN:GetAllSongs() end)
	if not ok or type(songs) ~= "table" then return "" end
	local dirs = {}
	for song in ivalues(songs) do
		local dir = song and song.GetSongDir and tostring(song:GetSongDir() or "") or ""
		if dir ~= "" then dirs[#dirs + 1] = dir end
	end
	table.sort(dirs)
	local joined = table.concat(dirs, "\n")
	if CRYPTMAN and CRYPTMAN.SHA256String and type(BinaryToHex) == "function" then
		local ok, digest = pcall(function()
			return BinaryToHex(CRYPTMAN:SHA256String(joined))
		end)
		if ok and type(digest) == "string" and digest ~= "" then
			return tostring(#dirs) .. ":" .. digest:lower()
		end
	end
	-- No imprecise numeric hash fallback: a failed native digest merely forces
	-- a rescan instead of risking a cache collision.
	return ""
end

local function local_scan_key(songInfo)
	if not songInfo then return "" end
	return table.concat({
		selected_at(songInfo),
		selected_song_hash(songInfo),
		selected_chart_hash(songInfo),
		tostring(songInfo.chart_note_count or ""),
		tostring(songInfo.max_score or ""),
		song_count_key(),
		local_song_library_key(),
	}, "|")
end

local function terminal_apply_key(songInfo, generation)
	if not songInfo then return "" end
	return table.concat({
		selected_at(songInfo),
		selected_song_hash(songInfo),
		selected_chart_hash(songInfo),
		selected_path(songInfo),
		tostring(generation or 0),
		tostring(ITGOnline and ITGOnline.screenGeneration or 0),
	}, "|")
end

local function build_payload(song, steps)
	if ITGOnline and ITGOnline.BuildSongPayloadFor then
		return ITGOnline:BuildSongPayloadFor(song, steps)
	end
	return nil
end

local function payload_matches_selected(payload, songInfo)
	if not payload then return false, "local_payload_unavailable" end
	local expectedSongHash = selected_song_hash(songInfo)
	local expectedChartHash = selected_chart_hash(songInfo)
	if expectedChartHash ~= "" and lower(payload.chart_hash) ~= expectedChartHash then
		return false, "chart_hash_mismatch"
	end
	if expectedSongHash ~= "" and lower(payload.song_hash) ~= expectedSongHash then
		return false, "song_hash_mismatch"
	end
	return true, nil
end

local function matching_steps_in_song(song, songInfo)
	local expectedChartHash = selected_chart_hash(songInfo)
	local style = GAMESTATE and GAMESTATE.GetCurrentStyle and GAMESTATE:GetCurrentStyle() or nil
	local stepsType = style and style:GetStepsType() or nil
	local stepsList = {}

	if stepsType then
		local ok, byType = pcall(function() return song:GetStepsByStepsType(stepsType) end)
		stepsList = ok and type(byType) == "table" and byType or {}
	else
		stepsList = playable_steps(song)
	end

	for steps in ivalues(stepsList) do
		if expectedChartHash ~= "" and lower(chart_hash_for_steps(steps)) == expectedChartHash then
			return steps
		end
	end

	return nil
end

local function song_matches_text_prefilter(song, songInfo)
	if not song then return false end
	local expectedTitle = lower(selected_title(songInfo))
	if expectedTitle == "" then return true end

	local fullTitle = song.GetDisplayFullTitle and lower(song:GetDisplayFullTitle()) or ""
	local displayMainTitle = song.GetDisplayMainTitle and lower(song:GetDisplayMainTitle()) or ""
	local translitMainTitle = song.GetTranslitMainTitle and lower(song:GetTranslitMainTitle()) or ""
	local translitFullTitle = song.GetTranslitFullTitle and lower(song:GetTranslitFullTitle()) or ""
	if fullTitle ~= expectedTitle
		and displayMainTitle ~= expectedTitle
		and translitMainTitle ~= expectedTitle
		and translitFullTitle ~= expectedTitle then
		return false
	end

	local expectedArtist = lower(selected_artist(songInfo))
	if expectedArtist == "" then return true end

	local artist = song.GetDisplayArtist and lower(song:GetDisplayArtist()) or ""
	local translitArtist = song.GetTranslitArtist and lower(song:GetTranslitArtist()) or artist
	return artist == expectedArtist or translitArtist == expectedArtist
end

function PackSync:DisplayText(status)
	status = tostring(status or "")
	local fallback = self.statusText[status] or self.statusText.unknown
	return pack_text(self.statusTextKeys[status] or self.statusTextKeys.unknown, fallback)
end

function PackSync:MarkPackInstalled(packName)
	packName = trim(packName)
	if packName == "" then return end
	self.installedPackNames = self.installedPackNames or {}
	self.installedPackNames[pack_name_key(packName)] = true
	self.downloadedPackKey = pack_name_key(packName)
	trace("Pack marked installed pack=" .. tostring(packName))
end

function PackSync:UnmarkPackInstalled(packName, reason)
	packName = trim(packName)
	if packName == "" then return end
	local key = pack_name_key(packName)
	if self.installedPackNames then
		self.installedPackNames[key] = nil
	end
	if self.downloadedPackKey == key then
		self.downloadedPackKey = nil
	end
	trace("Pack unmarked installed pack=" .. tostring(packName)
		.. " reason=" .. tostring(reason or "unknown"))
end

function PackSync:PackVisibleToSongman(packName)
	packName = trim(packName)
	if packName == "" or not SONGMAN then
		trace("PackVisibleToSongman skipped pack=" .. tostring(packName)
			.. " hasSongman=" .. tostring(SONGMAN ~= nil))
		return false
	end
	if SONGMAN.DoesSongGroupExist and SONGMAN:DoesSongGroupExist(packName) then
		trace("PackVisibleToSongman yes source=DoesSongGroupExist pack=" .. tostring(packName))
		return true
	end
	if SONGMAN.GetSongGroupNames then
		local expectedKey = pack_name_key(packName)
		for group in ivalues(SONGMAN:GetSongGroupNames()) do
			if pack_name_key(group) == expectedKey then
				trace("PackVisibleToSongman yes source=group_scan pack=" .. tostring(packName)
					.. " matchedGroup=" .. tostring(group))
				return true
			end
		end
	end
	trace("PackVisibleToSongman no pack=" .. tostring(packName))
	return false
end

function PackSync:PackExists(packName)
	packName = trim(packName)
	if packName == "" then
		trace("PackExists skipped reason=empty_pack")
		return false
	end
	if self:PackVisibleToSongman(packName) then
		trace("PackExists yes source=songman pack=" .. tostring(packName))
		return true
	end
	local rootExists = path_exists(pack_root_path(packName))
	local key = pack_name_key(packName)
	if self.installedPackNames and self.installedPackNames[key] == true then
		if rootExists then
			return true
		end
		self.installedPackNames[key] = nil
		if self.downloadedPackKey == key then
			self.downloadedPackKey = nil
		end
		trace("Pack installed cache pruned pack=" .. tostring(packName) .. " reason=missing_root")
	end
	trace("PackExists disk_result pack=" .. tostring(packName)
		.. " root=" .. tostring(pack_root_path(packName))
		.. " rootExists=" .. tostring(rootExists)
		.. " cachedInstalled=" .. tostring(self.installedPackNames and self.installedPackNames[key] == true))
	return rootExists
end

function PackSync:SongInfoMatchesCurrentSelection(songInfo)
	local songSelectedAt = selected_at(songInfo)
	local roomSelectedAt = current_room_selected_at()
	if songSelectedAt == "" or roomSelectedAt == "" then
		return false
	end
	return songSelectedAt == roomSelectedAt
end

function PackSync:SelectedAtForStatusPost(status, songInfo)
	local songSelectedAt = selected_at(songInfo)
	if songSelectedAt == "" then
		return ""
	end

	local roomSelectedAt = current_room_selected_at()
	if roomSelectedAt == "" then
		trace("Status selected_at stripped reason=no_active_room_selection"
			.. " status=" .. tostring(status)
			.. " songSelectedAt=" .. tostring(songSelectedAt))
		return ""
	end
	if roomSelectedAt ~= songSelectedAt then
		trace("Status selected_at stripped reason=stale_selection"
			.. " status=" .. tostring(status)
			.. " songSelectedAt=" .. tostring(songSelectedAt)
			.. " roomSelectedAt=" .. tostring(roomSelectedAt)
			.. " title=" .. tostring(selected_title(songInfo))
			.. " roomTitle=" .. tostring(selected_title(current_room_selected_song())))
		return ""
	end
	return songSelectedAt
end

-- Server status synchronization
-- -----------------------------------------------------------------------

function PackSync:UpdateStatus(status, message, progress, callback, options)
	status = tostring(status or self.status.Unknown)
	message = status_message(message)
	if type(callback) == "table" and options == nil then
		options = callback
		callback = nil
	end
	options = type(options) == "table" and options or {}
	if not (ITGOnline and ITGOnline.Request and current_user_is_active_room_member()) then
		trace("Status skipped reason=not_active_room_member status=" .. tostring(status))
		safe_invoke_callback(callback, false, nil, {
			errorMessage = pack_text("NoActiveOnlineLobby", "No active online lobby.")
		})
		return
	end
	local previousStatus = tostring(self.currentStatus or "")
	trace_online_state("status_update_begin", {
		status = status,
		message = message or "",
		progress = progress or "",
		downloadKey = self.downloadInFlightKey or "",
		activeDownloadId = self.activeDownloadId or "",
		browseOnly = self.activeBrowseOnlyDownload == true,
	})
	self.currentSongInfo = with_current_room_selection(self.currentSongInfo, "status:" .. tostring(status))
	local currentSelectedAt = self:SelectedAtForStatusPost(status, self.currentSongInfo)
	local tracksDownload = self:UsesDownloadStatusSequence(status) or options.downloadCancelled == true
	if tracksDownload then
		local immutableDownloadId = early_trim(options.downloadId)
		if immutableDownloadId == "" then immutableDownloadId = early_trim(self.activeDownloadId) end
		if immutableDownloadId == "" then immutableDownloadId = early_trim(self.lastDownloadId) end
		local immutableSelectionId = early_trim(options.downloadSelectionId)
		if immutableSelectionId == "" then immutableSelectionId = early_trim(self.activeDownloadSelectionId) end
		if immutableSelectionId == "" then immutableSelectionId = early_trim(self.lastDownloadSelectionId) end
		options.downloadId = immutableDownloadId
		options.downloadSelectionId = immutableSelectionId
		if immutableDownloadId == "" then
			trace("Status post blocked reason=missing_download_identity status=" .. tostring(status)
				.. " generation=" .. tostring(self.downloadGeneration or "nil")
				.. " selected_at=" .. tostring(currentSelectedAt))
			self:ApplyLocalStatus(status, message, progress)
			safe_invoke_callback(callback, false, nil, {
				errorCode = "client_download_identity_missing",
				errorMessage = pack_text("MissingDownloadIdentity", "The immutable download identifier is missing."),
			})
			return
		end
	end
	if status == self.status.SearchingLocalCharts then
		self:ApplyLocalStatus(status, message, progress)
		safe_invoke_callback(callback, true, {
			pack_sync_status = {
				applied = false,
				ignored_reason = "client_local_scan_status",
			},
			local_only = true,
		}, local_success_response("client_local_scan_status"))
		return
	end
	if status == self.status.Ready and currentSelectedAt ~= "" then
		self.lastReadySelectedAt = currentSelectedAt
	end
	if currentSelectedAt ~= "" and (status == self.status.SearchingLocalCharts or status == self.status.LocalChartMatchFound) then
		local localUserId = ITGOnline and ITGOnline.LocalUserId and tostring(ITGOnline:LocalUserId() or "") or ""
		local room = ITGOnline and ITGOnline.currentRoom or nil
		local members = type(room) == "table" and (room.players or room.members or room.room_members) or nil
		local alreadyReadyForSelection = false
		if localUserId ~= "" and type(members) == "table" then
			for _, member in pairs(members) do
				local user = type(member) == "table" and (member.user or member.player or {}) or {}
				local memberUserId = tostring((type(member) == "table" and (member.user_id or member.userId or member.player_id or member.playerId)) or user.id or "")
				local memberStatus = tostring((type(member) == "table" and (member.pack_sync_status or member.status)) or "")
				local memberSelectedAt = tostring((type(member) == "table" and (member.pack_sync_selected_at or member.selected_at or member.selectedAt)) or "")
				if memberUserId == localUserId and memberStatus == self.status.Ready and (memberSelectedAt == "" or memberSelectedAt == currentSelectedAt) then
					alreadyReadyForSelection = true
					break
				end
			end
		end
		local locallyReadyForSelection = tostring(self.lastReadySelectedAt or "") == currentSelectedAt
			and previousStatus == self.status.Ready
			if alreadyReadyForSelection or locallyReadyForSelection then
				trace("Status post skipped reason=client_ready_status_protected_from_local_scan"
					.. " status=" .. tostring(status)
					.. " selected_at=" .. tostring(currentSelectedAt)
					.. " room=" .. tostring(ITGOnline and ITGOnline.currentRoomId or "nil"))
				safe_invoke_callback(callback, true, {
					pack_sync_status = {
						applied = false,
						ignored_reason = "client_ready_status_protected_from_local_scan",
						local_ready = locallyReadyForSelection,
						server_ready = alreadyReadyForSelection,
					},
					local_only = true,
				}, local_success_response("client_ready_status_protected_from_local_scan"))
				return
			end
		end
	-- Browsing has no selected chart to synchronize, but the lobby still needs
	-- the member's pack-transfer state.  Otherwise other players retain a
	-- stale "Pack inconnu" row after a background download completes.
	-- Keep only chart-validation states local; transfer lifecycle states are
	-- deliberately shared with the room.
	local noActiveSelectionLocalOnly = currentSelectedAt == "" and (
		status == self.status.Ready
		or status == self.status.SearchingLocalCharts
		or status == self.status.LocalChartMatchFound
		or status == self.status.NoCompatibleChartFound
		or status == self.status.ChartMismatch
		)
		if noActiveSelectionLocalOnly then
			trace("Status post skipped reason=no_active_selection_local_only"
				.. " status=" .. tostring(status)
				.. " browseOnly=" .. tostring(self.activeBrowseOnlyDownload == true)
				.. " progress=" .. tostring(progress)
				.. " room=" .. tostring(ITGOnline and ITGOnline.currentRoomId or "nil")
				.. " phase=" .. tostring(ITGOnline and ITGOnline.currentRoom and ITGOnline.currentRoom.phase or "nil"))
			self:ApplyLocalStatus(status, message, progress)
			safe_invoke_callback(callback, true, {
				pack_sync_status = {
					applied = false,
					ignored_reason = "client_no_active_selection_local_only",
				},
				local_only = true,
			}, local_success_response("client_no_active_selection_local_only"))
			return
		end
	local usesDownloadSequence = self:UsesDownloadStatusSequence(status)
	if not usesDownloadSequence and self.lastSelectedAt ~= currentSelectedAt then
		self.sequence = 0
		self.lastSelectedAt = currentSelectedAt
	end

	self:SyncSequenceFromRoom(currentSelectedAt)
	local intentSignature = table.concat({
		tostring(ITGOnline and ITGOnline.currentRoomId or ""),
		tostring(currentSelectedAt or ""),
		tostring(status or ""),
		tostring(message or ""),
		tostring(progress or ""),
		tostring(options.downloadCancelled == true),
		tostring(self.downloadInFlightKey or ""),
		tostring(options.downloadId or ""),
		tostring(options.downloadSelectionId or ""),
	}, "||")
	local now = GetTimeSinceStart and GetTimeSinceStart() or 0
	if options.fromPendingStatusQueue ~= true
		and intentSignature ~= ""
		and intentSignature == tostring(self.lastStatusPostIntentSignature or "") then
		local age = now - (tonumber(self.lastStatusPostIntentAt) or 0)
		if age < 0.35 then
			trace("Status post skipped duplicate_intent status=" .. tostring(status)
				.. " progress=" .. tostring(progress)
				.. " selected_at=" .. tostring(currentSelectedAt)
				.. " age=" .. string.format("%.3f", age))
				safe_invoke_callback(callback, true, {
					pack_sync_status = {
						applied = false,
						ignored_reason = "client_duplicate_status_intent",
					},
					duplicate = true,
				}, local_success_response("client_duplicate_status_intent"))
				return
			end
		end
	self.lastStatusPostIntentSignature = intentSignature
	self.lastStatusPostIntentAt = now
	local signature = status_post_signature(ITGOnline and ITGOnline.currentRoomId or "", currentSelectedAt, status, message, progress, options)
	self:ExpireStatusPostInFlight("before_status_update")
	if tostring(self.statusPostInFlightSignature or "") == "" and self.statusPostPendingIntent then
		self:DiscardPendingStatusPost("superseded_after_in_flight_timeout")
	end
	if tostring(self.statusPostInFlightSignature or "") ~= ""
		and signature ~= tostring(self.statusPostInFlightSignature or "") then
		self:ApplyLocalStatus(status, message, progress)
		self:QueuePendingStatusPost(signature, status, message, progress, callback,
			options, ITGOnline and ITGOnline.currentRoomId or "", currentSelectedAt)
		return
	end

	local requestSequence = 0
	if usesDownloadSequence then
		self.downloadStatusSequence = math.max(tonumber(self.downloadStatusSequence) or 0, tonumber(self.sequence) or 0) + 1
		self.sequence = math.max(tonumber(self.sequence) or 0, tonumber(self.downloadStatusSequence) or 0)
		requestSequence = tonumber(self.downloadStatusSequence) or 0
	else
		self.sequence = (tonumber(self.sequence) or 0) + 1
		requestSequence = tonumber(self.sequence) or 0
	end
	local requestSelectedAt = currentSelectedAt
	local requestRoomId = tostring(ITGOnline and ITGOnline.currentRoomId or "")
	trace("Status " .. status .. (message and (" - " .. tostring(message)) or ""))
	trace("Status detail room=" .. tostring(ITGOnline and ITGOnline.currentRoomId or "nil")
		.. " phase=" .. tostring(ITGOnline and ITGOnline.currentRoom and ITGOnline.currentRoom.phase or "nil")
		.. " selected_at=" .. tostring(currentSelectedAt)
		.. " roomSelectedAt=" .. tostring(current_room_selected_at())
		.. " currentSongTitle=" .. tostring(selected_title(self.currentSongInfo))
		.. " currentSongPack=" .. tostring(selected_pack(self.currentSongInfo))
		.. " sequence=" .. tostring(requestSequence)
		.. " sequenceMode=" .. tostring(usesDownloadSequence and "download" or "selection")
		.. " generation=" .. tostring(self.downloadGeneration or "nil")
		.. " statusChangedAt=" .. tostring(self.statusChangedAt or "nil")
		.. " pendingPostReload=" .. tostring(self.pendingPostReloadSongInfo ~= nil)
		.. " activeDownloadId=" .. tostring(self.activeDownloadId or "")
		.. " progress=" .. tostring(progress)
		.. " inFlightKey=" .. tostring(self.downloadInFlightKey or "")
		.. " browseOnly=" .. tostring(self.activeBrowseOnlyDownload == true))
		local postedAt = tonumber(self.lastPostedStatusAt) or 0
		local heartbeat = tonumber(self.statusPostDuplicateHeartbeatSeconds) or 5.0
		if signature ~= "" and signature == tostring(self.statusPostInFlightSignature or "") then
			trace("Status post skipped duplicate_in_flight status=" .. tostring(status)
				.. " progress=" .. tostring(progress)
				.. " selected_at=" .. tostring(currentSelectedAt))
			if callback then
				self.statusPostInFlightCallbacks[signature] = self.statusPostInFlightCallbacks[signature] or {}
				local waitingCallbacks = self.statusPostInFlightCallbacks[signature]
				if #waitingCallbacks < 16 then
					waitingCallbacks[#waitingCallbacks + 1] = callback
				else
					trace("Status duplicate_in_flight callback rejected reason=queue_full signature=" .. tostring(signature))
					safe_invoke_callback(callback, false, nil, {
						errorMessage = pack_text("TooManyPendingPackStatuses", "Too many online pack statuses are pending.")
					})
				end
			end
			return
		end
	if signature ~= "" and signature == tostring(self.lastPostedStatusSignature or "") and (now - postedAt) < heartbeat then
			trace("Status post skipped duplicate status=" .. tostring(status)
				.. " progress=" .. tostring(progress)
				.. " selected_at=" .. tostring(currentSelectedAt)
				.. " age=" .. string.format("%.3f", now - postedAt))
			safe_invoke_callback(callback, true, {
				pack_sync_status = {
					applied = false,
					ignored_reason = "client_duplicate_status",
				},
				duplicate = true,
			}, local_success_response("client_duplicate_status"))
			return
		end
		self.currentStatus = status
		self.currentStatusMessage = message
		self.currentStatusProgress = tonumber(progress) or self.currentStatusProgress or 0
		self.statusChangedAt = now
		if MESSAGEMAN then
			local activeRoomId = ITGOnline and ITGOnline.currentRoomId or nil
			local activeRoomPhase = ITGOnline and ITGOnline.currentRoom and ITGOnline.currentRoom.phase or nil
		MESSAGEMAN:Broadcast("OnlinePackSyncLocalStatus", {
			status = status,
			message = message,
			download_progress = progress,
			selected_at = currentSelectedAt,
			room_id = activeRoomId,
			room_phase = activeRoomPhase,
			mode = activeRoomId and "joined" or "browse",
		})
	end
	self.lastPostedStatusSignature = signature
	self.lastPostedStatusAt = now
	self.statusPostInFlightSignature = signature
	self.statusPostInFlightStartedAt = now
	self.statusPostInFlightCallbacks[signature] = callback and { callback } or {}
	self.statusPostRequestToken = (tonumber(self.statusPostRequestToken) or 0) + 1
	self.statusPostActiveRequestToken = self.statusPostRequestToken
	local requestToken = self.statusPostRequestToken

	local payload = {
		client_action_id = ITGOnline:NewClientActionId("pack-status"),
		status = status,
		message = message,
		download_progress = progress,
		sequence = requestSequence,
	}
	local selectionId = current_room_selection_id()
	if tracksDownload then
		selectionId = early_trim(options.downloadSelectionId)
	end
	if selectionId ~= "" then payload.selection_id = selectionId end
	if tracksDownload then
		local downloadId = early_trim(options.downloadId)
		if downloadId ~= "" then payload.download_id = downloadId end
	end
	if options.downloadCancelled == true then
		payload.download_cancelled = true
	end
	if self.currentSongInfo and (not tracksDownload or selectionId == current_room_selection_id()) then
		if currentSelectedAt ~= "" then
			payload.selected_at = currentSelectedAt
		end
	end

	if ITGOnline.IsLocalTwoPlayerSession
		and ITGOnline:IsLocalTwoPlayerSession()
		and ITGOnline.LocalPartyRoomComplete
		and ITGOnline:LocalPartyRoomComplete(ITGOnline.currentRoom)
		and ITGOnline.RequestAsLocalPlayer
	then
		local companionPayload = {}
		for key, value in pairs(payload) do companionPayload[key] = value end
		companionPayload.client_action_id = ITGOnline:NewClientActionId("p2-pack-status")
		trace("Status companion request localPlayer=P2"
			.. " status=" .. tostring(status)
			.. " room=" .. tostring(requestRoomId)
			.. " sequence=" .. tostring(requestSequence)
			.. " selected_at=" .. tostring(requestSelectedAt))
		ITGOnline:RequestAsLocalPlayer(PLAYER_2, "POST",
			"/rooms/" .. requestRoomId .. "/pack-sync-status",
			companionPayload, function(ok, decoded, response)
				trace("Status companion response localPlayer=P2"
					.. " status=" .. tostring(status)
					.. " room=" .. tostring(requestRoomId)
					.. " ok=" .. tostring(ok == true)
					.. " statusCode=" .. tostring(response and response.statusCode or "nil")
					.. " error=" .. tostring(decoded and decoded.error_code
						or response and response.errorMessage or "nil"))
				if ok and decoded and decoded.room and ITGOnline.ApplyRoomSnapshot then
					ITGOnline:ApplyRoomSnapshot(decoded.room, "pack_sync_status_p2")
					MESSAGEMAN:Broadcast("OnlineLobbyState", ITGOnline:LobbyStatePayload(decoded.room))
				elseif not ok then
					MESSAGEMAN:Broadcast("ITGOnlineLocalPartyPackSyncFailed", {
						localPlayer = "P2",
						status = status,
						errorCode = decoded and decoded.error_code or nil,
					})
				end
			end)
	end

	ITGOnline:Request("POST", "/rooms/" .. requestRoomId .. "/pack-sync-status", payload, function(ok, decoded, response)
		local ownsActiveRequest = tonumber(self.statusPostActiveRequestToken) == tonumber(requestToken)
			and tostring(self.statusPostInFlightSignature or "") == signature
		if ownsActiveRequest then
			self.statusPostInFlightSignature = ""
			self.statusPostInFlightStartedAt = 0
			self.statusPostActiveRequestToken = 0
		else
			runtime_validation_trace("ignored stale pack status response status=" .. tostring(status)
				.. " request_token=" .. tostring(requestToken)
				.. " active_token=" .. tostring(self.statusPostActiveRequestToken or 0)
				.. " room=" .. tostring(requestRoomId)
				.. " selected_at=" .. tostring(requestSelectedAt))
			local staleResponse = response or {}
			staleResponse.errorCode = "client_stale_status_response"
			staleResponse.errorMessage = pack_text("StalePackStatusIgnored", "An outdated online status response was ignored.")
			local waitingCallbacks = self.statusPostInFlightCallbacks[signature] or {}
			self.statusPostInFlightCallbacks[signature] = nil
			for _, waitingCallback in ipairs(waitingCallbacks) do
				safe_invoke_callback(waitingCallback, false, decoded, staleResponse)
			end
			return
		end
		if not ok and tostring(self.lastPostedStatusSignature or "") == signature then
			self.lastPostedStatusSignature = ""
			self.lastPostedStatusAt = 0
			trace("Cleared failed status post dedupe key status=" .. tostring(status)
				.. " selected_at=" .. tostring(requestSelectedAt))
		end
		local statusResult = decoded and decoded.pack_sync_status or nil
		if ok and self:IsTerminalDownloadStatus(status)
			and tostring(payload.download_id or "") == tostring(self.lastDownloadId or "") then
			self.lastDownloadId = ""
			self.lastDownloadSelectionId = ""
		end
		local ignored = ok and statusResult and statusResult.applied == false
		local callbackOk = ok and not ignored
		local responseRoom = decoded and decoded.room or nil
		trace("Status response status=" .. tostring(status)
			.. " ok=" .. tostring(ok == true)
			.. " ignored=" .. tostring(ignored == true)
			.. " applied=" .. tostring(statusResult and statusResult.applied)
			.. " ignored_reason=" .. tostring(statusResult and statusResult.ignored_reason or "nil")
			.. " statusCode=" .. tostring(response and response.statusCode or "nil")
			.. " hasRoom=" .. tostring(decoded and decoded.room ~= nil)
			.. " roomPhase=" .. tostring(decoded and decoded.room and decoded.room.phase or "nil")
			.. " requestSequence=" .. tostring(requestSequence)
			.. " localSequence=" .. tostring(self.sequence)
			.. " selected_at=" .. tostring(requestSelectedAt))
		if ignored and responseRoom then
			self:SyncSequenceFromRoomPayload(responseRoom, requestSelectedAt, "pack_sync_status_ignored")
		elseif ok and responseRoom and ITGOnline.ApplyRoomSnapshot then
			ITGOnline:ApplyRoomSnapshot(responseRoom, "pack_sync_status")
			MESSAGEMAN:Broadcast("OnlineLobbyState", ITGOnline:LobbyStatePayload(responseRoom))
			self:SyncSequenceFromRoomPayload(responseRoom, requestSelectedAt, "pack_sync_status_applied")
		end
		if ignored then
			decoded.error_code = decoded.error_code or "pack_sync_status_ignored"
			decoded.message = decoded.message or "Pack sync status update was ignored for a stale room state."
			response = response or {}
			response.errorMessage = response.errorMessage or decoded.message
			trace("Status ignored reason=" .. tostring(statusResult and statusResult.ignored_reason or "unknown")
				.. " status=" .. tostring(status)
				.. " sequence=" .. tostring(payload.sequence)
				.. " selected_at=" .. tostring(payload.selected_at or ""))
		end
			local waitingCallbacks = self.statusPostInFlightCallbacks[signature] or {}
			self.statusPostInFlightCallbacks[signature] = nil
			for _, queuedCallback in ipairs(waitingCallbacks) do
				safe_invoke_callback(queuedCallback, callbackOk, decoded, response)
			end
			self:FlushPendingStatusPost("status_response")
		end)
	end

function PackSync:ApplyLocalStatus(status, message, progress)
	status = tostring(status or self.status.Unknown)
	message = status_message(message)
	trace("ApplyLocalStatus status=" .. tostring(status)
		.. " message=" .. tostring(message or "")
		.. " progress=" .. tostring(progress)
		.. " room=" .. tostring(ITGOnline and ITGOnline.currentRoomId or "nil")
		.. " phase=" .. tostring(ITGOnline and ITGOnline.currentRoom and ITGOnline.currentRoom.phase or "nil")
		.. " selected_at=" .. tostring(selected_at(self.currentSongInfo))
		.. " title=" .. tostring(selected_title(self.currentSongInfo))
		.. " pack=" .. tostring(selected_pack(self.currentSongInfo))
		.. " generation=" .. tostring(self.downloadGeneration or "nil")
		.. " key=" .. tostring(self.downloadInFlightKey or "")
		.. " browseOnly=" .. tostring(self.activeBrowseOnlyDownload == true))
	self.currentStatus = status
	self.currentStatusMessage = message
	self.currentStatusProgress = tonumber(progress) or self.currentStatusProgress or 0
	local now = GetTimeSinceStart and GetTimeSinceStart() or 0
	self.statusChangedAt = now
	local localSignature = table.concat({
		tostring(ITGOnline and ITGOnline.currentRoomId or ""),
		tostring(selected_at(self.currentSongInfo)),
		tostring(status),
		tostring(message or ""),
		tostring(progress or ""),
	}, "||")
	if localSignature ~= "" and localSignature == tostring(self.lastAppliedLocalStatusSignature or "") then
		local age = now - (tonumber(self.lastAppliedLocalStatusAt) or 0)
		local suppressFor = tonumber(self.localStatusDuplicateSuppressSeconds) or 0.35
		if age >= 0 and age < suppressFor then
			trace("ApplyLocalStatus skipped duplicate status=" .. tostring(status)
				.. " progress=" .. tostring(progress)
				.. " selected_at=" .. tostring(selected_at(self.currentSongInfo))
				.. " age=" .. string.format("%.3f", age))
			return
		end
	end
	self.lastAppliedLocalStatusSignature = localSignature
	self.lastAppliedLocalStatusAt = now
	if MESSAGEMAN then
		local activeRoomId = ITGOnline and ITGOnline.currentRoomId or nil
		local activeRoomPhase = ITGOnline and ITGOnline.currentRoom and ITGOnline.currentRoom.phase or nil
		MESSAGEMAN:Broadcast("OnlinePackSyncLocalStatus", {
			status = status,
			message = message,
			download_progress = progress,
			selected_at = selected_at(self.currentSongInfo),
			room_id = activeRoomId,
			room_phase = activeRoomPhase,
			mode = activeRoomId and "joined" or "browse",
		})
	end
end

function PackSync:WatchdogTick()
	if self.pendingSelectedAvailabilitySongInfo ~= nil then
		local now = GetTimeSinceStart()
		if not self.selectedAvailabilityInFlight
			and now >= (tonumber(self.pendingSelectedAvailabilityRetryAt) or 0)
		then
			self:FinalizeDownloadedSelectedSongAvailability(
				self.pendingSelectedAvailabilitySongInfo,
				"watchdog_retry",
				self.pendingSelectedAvailabilityMessage)
		end
	end

	local status = tostring(self.currentStatus or self.status.Unknown)
	if status == self.status.DownloadedOk and self.pendingPostReloadSongInfo ~= nil then
		local now = GetTimeSinceStart()
		if now >= (tonumber(self.pendingBrowseCompletionRetryAt) or 0)
		and tostring(self.statusPostInFlightSignature or "") == "" then
			self.pendingBrowseCompletionRetryAt = now + 5.25
			self.pendingBrowseCompletionRetryCount = (tonumber(self.pendingBrowseCompletionRetryCount) or 0) + 1
			local browseOnly = self.pendingPostReloadBrowseOnly == true
			trace("Retrying " .. (browseOnly and "browse-only" or "selected-song")
				.. " completion acknowledgement attempt="
				.. tostring(self.pendingBrowseCompletionRetryCount)
				.. " downloadId=" .. tostring(self.activeDownloadId or self.lastDownloadId or ""))
			if browseOnly then
				self:UpdateStatus(self.status.DownloadedOk,
					pack_text("PackDownloadedWaitingManager", "Pack downloaded. Waiting for the manager's song selection."), 100,
					function(statusOk, decoded, response)
						trace("Browse-only completion retry response ok=" .. tostring(statusOk == true)
							.. " status=" .. tostring(response and response.statusCode or "nil")
							.. " error=" .. tostring(decoded and decoded.error_code or response and response.errorMessage or "nil"))
						if statusOk then
							self:CompletePendingPostReload(true, pack_text("PackDownloadedValidated", "Pack downloaded and validated after reload."),
								"browse_reload_validation_retry_ok")
						end
					end)
			else
				self:ValidatePendingPostReload()
			end
		end
		return
	end
	if status == self.status.Unknown or status == self.status.Ready then
		self.watchdogLastKey = ""
		return
	end

	local watchable = (
		status == self.status.SearchingLocalCharts
		or status == self.status.DownloadRequested
		or status == self.status.DownloadInProgress
		or status == self.status.ReloadingSongs
	)
	if not watchable then return end

	local now = GetTimeSinceStart()
	if status == self.status.DownloadInProgress
		and early_trim(self.activeDownloadId) ~= ""
		and tostring(self.statusPostInFlightSignature or "") == ""
		and (now - (tonumber(self.lastPostedStatusAt) or 0)) >= (tonumber(self.downloadHeartbeatSeconds) or 10.0)
	then
		trace("Download heartbeat status=" .. tostring(status)
			.. " progress=" .. tostring(self.currentStatusProgress or 0)
			.. " downloadId=" .. tostring(self.activeDownloadId))
		self:UpdateStatus(status, self.currentStatusMessage, self.currentStatusProgress, nil, {
			downloadId = self.activeDownloadId,
			downloadSelectionId = self.activeDownloadSelectionId,
		})
	end
	local age = now - (tonumber(self.statusChangedAt) or 0)
	local timeout = tonumber(self.watchdogTimeoutSeconds) or 25
	if status == self.status.DownloadInProgress then
		local lastByteAt = tonumber(self.downloadLastByteAt) or tonumber(self.downloadStartedAt) or tonumber(self.statusChangedAt) or now
		age = now - lastByteAt
		timeout = math.max(timeout, 45)
	end
	if age < timeout then return end

	local key = status .. ":" .. tostring(selected_at(self.currentSongInfo))
	if self.watchdogLastKey == key then return end
	self.watchdogLastKey = key

	local message = pack_text("PackOperationTimeout", "Operation timed out. Try downloading the pack again.")
	trace("Watchdog timeout status=" .. tostring(status) .. " age=" .. tostring(math.floor(age)))
	self.downloadInFlightKey = nil
	self.downloadStartedAt = nil
	self.downloadLastByteAt = nil
	self.downloadLastByteCount = nil
	self.activeBrowseOnlyDownload = false
	self:NextDownloadGeneration("watchdog_timeout")
	self:UpdateStatus(self.status.DownloadFailed, message)
	if SM then SM(message, 4) end
end

function PackSync:CompletePendingPostReload(ok, message, reason)
	local pendingCallback = self.pendingPostReloadCallback
	self.pendingPostReloadSongInfo = nil
	self.pendingQuarantinePath = nil
	self.pendingPostReloadBrowseOnly = false
	self.pendingPostReloadCallback = nil
	self.pendingBrowseCompletionRetryAt = 0
	self.pendingBrowseCompletionRetryCount = 0
	self.downloadInFlightKey = nil
	self.activeBrowseOnlyDownload = false
	self:ClearActiveDownloadId(reason or "post_reload_validation_complete")
	safe_invoke_callback(pendingCallback, ok == true, message)
end

function PackSync:ClearSelectedAvailabilityRetry(reason)
	if self.pendingSelectedAvailabilitySongInfo ~= nil or self.selectedAvailabilityInFlight then
		trace("Selected availability retry cleared reason=" .. tostring(reason or "unknown")
			.. " attempts=" .. tostring(self.pendingSelectedAvailabilityRetryCount or 0))
	end
	self.pendingSelectedAvailabilitySongInfo = nil
	self.pendingSelectedAvailabilityMessage = nil
	self.pendingSelectedAvailabilityRetryAt = 0
	self.pendingSelectedAvailabilityRetryCount = 0
	self.selectedAvailabilityInFlight = false
end

function PackSync:ScheduleSelectedAvailabilityRetry(songInfo, reason, readyMessage, retryAfter)
	if not self:SongInfoMatchesCurrentSelection(songInfo) then
		self:ClearSelectedAvailabilityRetry("selection_changed")
		return false
	end
	self.pendingSelectedAvailabilitySongInfo = songInfo
	self.pendingSelectedAvailabilityMessage = readyMessage
	self.pendingSelectedAvailabilityRetryCount = (tonumber(self.pendingSelectedAvailabilityRetryCount) or 0) + 1
	local delay = math.min(10, math.max(
		1.5 * self.pendingSelectedAvailabilityRetryCount,
		tonumber(retryAfter) or 0))
	self.pendingSelectedAvailabilityRetryAt = GetTimeSinceStart() + delay
	trace("Selected availability retry scheduled reason=" .. tostring(reason or "unknown")
		.. " attempt=" .. tostring(self.pendingSelectedAvailabilityRetryCount)
		.. " delay=" .. tostring(delay)
		.. " selected_at=" .. tostring(selected_at(songInfo)))
	return true
end

function PackSync:FinalizeDownloadedSelectedSongAvailability(songInfo, source, readyMessage)
	if self.selectedAvailabilityInFlight then
		trace("Selected availability finalization skipped reason=in_flight source=" .. tostring(source or "unknown"))
		return false
	end
	if not self:SongInfoMatchesCurrentSelection(songInfo) then
		self:ClearSelectedAvailabilityRetry("selection_changed_before_confirmation")
		return false
	end
	if not (ITGOnline and ITGOnline.ConfirmSelectedSongAvailability) then
		self:UpdateStatus(self.status.Ready, readyMessage, nil, function(statusOk)
			if statusOk then
				self:MarkLobbyReadyForSelectedSong("downloaded_ok_no_client_confirm")
			end
		end)
		self:ClearSelectedAvailabilityRetry("client_confirmation_unavailable")
		return true
	end

	self.selectedAvailabilityInFlight = true
	self.pendingSelectedAvailabilitySongInfo = songInfo
	trace("Selected availability finalization begin source=" .. tostring(source or "unknown")
		.. " selected_at=" .. tostring(selected_at(songInfo)))
	ITGOnline:ConfirmSelectedSongAvailability("downloaded_ok", function(ok, decoded, response)
		self.selectedAvailabilityInFlight = false
		local confirmed, deferred, availabilityReason, retryAfter = availability_confirmation_state(ok, decoded, response)
		trace("Selected availability finalization response confirmed=" .. tostring(confirmed)
			.. " deferred=" .. tostring(deferred)
			.. " reason=" .. tostring(availabilityReason)
			.. " source=" .. tostring(source or "unknown"))
		if not confirmed then
			self:ScheduleSelectedAvailabilityRetry(songInfo, availabilityReason, readyMessage, retryAfter)
			return
		end

		local acknowledgedStatus = local_member_pack_status(
			decoded and decoded.room or ITGOnline and ITGOnline.currentRoom)
		if acknowledgedStatus == self.status.Ready then
			-- Song availability atomically promotes ordinary local matches to
			-- READY on the server.  Do not post the same transition again: the
			-- server correctly reports it as a semantic duplicate, which would
			-- otherwise be mistaken for another failed acknowledgement.
			self:ApplyLocalStatus(self.status.Ready, readyMessage)
			self:ClearSelectedAvailabilityRetry("selected_song_ready_from_availability")
			self:MarkLobbyReadyForSelectedSong(tostring(source or "unknown") .. "_availability")
			return
		end

		self:UpdateStatus(self.status.Ready, readyMessage, nil, function(statusOk, statusDecoded, statusResponse)
			trace("Selected ready status response ok=" .. tostring(statusOk == true)
				.. " status=" .. tostring(statusResponse and statusResponse.statusCode or "nil")
				.. " error=" .. tostring(statusDecoded and statusDecoded.error_code
					or statusResponse and statusResponse.errorMessage or "nil"))
			if not statusOk then
				self:ScheduleSelectedAvailabilityRetry(songInfo, "ready_status_not_acknowledged", readyMessage)
				return
			end
			self:ClearSelectedAvailabilityRetry("selected_song_ready")
			self:MarkLobbyReadyForSelectedSong("downloaded_ok")
		end)
	end)
	return true
end

-- Local lifecycle and chart index
-- -----------------------------------------------------------------------

function PackSync:ResetLocalState(reason)
	local normalizedReason = tostring(reason or "unknown")
	local resetSignature = table.concat({
		normalizedReason,
		tostring(self.currentStatus or "nil"),
		tostring(self.currentStatusMessage or ""),
		tostring(self.downloadInFlightKey or ""),
		tostring(self.currentSongInfo ~= nil),
		tostring(self.pendingPostReloadSongInfo ~= nil),
		tostring(self.activeBrowseOnlyDownload == true),
		tostring(ITGOnline and ITGOnline.currentRoomId or "nil"),
		tostring(ITGOnline and ITGOnline.currentRoom and ITGOnline.currentRoom.phase or "nil"),
	}, "|")
	local now = GetTimeSinceStart()
	trace("ResetLocalState requested reason=" .. tostring(normalizedReason)
		.. " status=" .. tostring(self.currentStatus or "nil")
		.. " message=" .. tostring(self.currentStatusMessage or "")
		.. " selected_at=" .. tostring(selected_at(self.currentSongInfo))
		.. " title=" .. tostring(selected_title(self.currentSongInfo))
		.. " pack=" .. tostring(selected_pack(self.currentSongInfo))
		.. " downloadWorkInFlight=" .. tostring(self:HasDownloadWorkInFlight())
		.. " activeDownloadId=" .. tostring(self.activeDownloadId or "")
		.. " downloadKey=" .. tostring(self.downloadInFlightKey or "")
		.. " generation=" .. tostring(self.downloadGeneration or "nil")
		.. " pendingPostReload=" .. tostring(self.pendingPostReloadSongInfo ~= nil)
		.. " room=" .. tostring(ITGOnline and ITGOnline.currentRoomId or "nil")
		.. " phase=" .. tostring(ITGOnline and ITGOnline.currentRoom and ITGOnline.currentRoom.phase or "nil"))
	if resetSignature == tostring(self.lastResetSignature or "")
		and (now - (tonumber(self.lastResetAt) or 0)) < 0.25 then
		trace("ResetLocalState skipped duplicate reason=" .. tostring(normalizedReason)
			.. " status=" .. tostring(self.currentStatus or "nil"))
		return
	end

	local isNoSongClearReset = normalizedReason == "no_song_confirmed"
		or normalizedReason == "online_lobby_state_clear_unconfirmed_preview"
		or normalizedReason == "song_selection_cancelled"
	if isNoSongClearReset
		and not self:HasDownloadWorkInFlight()
		and self.currentSongInfo == nil
		and tostring(self.downloadInFlightKey or "") == ""
		and self.pendingPostReloadSongInfo == nil
		and self.activeBrowseOnlyDownload ~= true
		and (now - (tonumber(self.lastNoSongClearResetAt) or 0)) < 0.75
	then
		trace("ResetLocalState skipped equivalent no-song clear reason=" .. tostring(normalizedReason)
			.. " previousReason=" .. tostring(self.lastNoSongClearResetReason or "")
			.. " age=" .. string.format("%.3f", now - (tonumber(self.lastNoSongClearResetAt) or 0))
			.. " status=" .. tostring(self.currentStatus or "nil"))
		return
	end

	self.lastResetSignature = resetSignature
	self.lastResetAt = now
	if isNoSongClearReset then
		self.lastNoSongClearResetAt = now
		self.lastNoSongClearResetReason = normalizedReason
	end
	trace("ResetLocalState begin reason=" .. tostring(reason or "unknown")
		.. " status=" .. tostring(self.currentStatus or "nil")
		.. " message=" .. tostring(self.currentStatusMessage or "")
		.. " key=" .. tostring(self.downloadInFlightKey or "")
		.. " hasSong=" .. tostring(self.currentSongInfo ~= nil)
		.. " pendingPostReload=" .. tostring(self.pendingPostReloadSongInfo ~= nil)
		.. " browseOnly=" .. tostring(self.activeBrowseOnlyDownload == true)
		.. " room=" .. tostring(ITGOnline and ITGOnline.currentRoomId or "nil")
		.. " phase=" .. tostring(ITGOnline and ITGOnline.currentRoom and ITGOnline.currentRoom.phase or "nil"))
	trace_online_state("reset_local_state_begin", {
		reason = reason or "unknown",
		status = self.currentStatus or "nil",
		message = self.currentStatusMessage or "",
		downloadKey = self.downloadInFlightKey or "",
		activeDownloadId = self.activeDownloadId or "",
		hasSong = self.currentSongInfo ~= nil,
		selected_at = selected_at(self.currentSongInfo),
		pendingPostReload = self.pendingPostReloadSongInfo ~= nil,
		browseOnly = self.activeBrowseOnlyDownload == true,
	})
	if reason == "online_lobby_state_results" then
		if not self:HasDownloadWorkInFlight() then
			self:ClearActiveDownloadId("results_reset_without_active_download")
		end
		trace("ResetLocalState ignored during results; preserving final song/download state")
		return
	end
	if self:ShouldPreserveActiveDownloadDuringReset(reason) then
		trace("ResetLocalState preserved active download reason=" .. tostring(reason or "unknown")
			.. " status=" .. tostring(self.currentStatus or "nil")
			.. " key=" .. tostring(self.downloadInFlightKey or "")
			.. " generation=" .. tostring(self.downloadGeneration or "nil")
			.. " selected_at=" .. tostring(selected_at(self.currentSongInfo))
			.. " pendingPostReload=" .. tostring(self.pendingPostReloadSongInfo ~= nil)
			.. " browseOnly=" .. tostring(self.activeBrowseOnlyDownload == true))
		trace_online_state("reset_local_state_preserved_download", {
			reason = reason or "unknown",
			status = self.currentStatus or "nil",
			downloadKey = self.downloadInFlightKey or "",
			activeDownloadId = self.activeDownloadId or "",
			selected_at = selected_at(self.currentSongInfo),
			pendingPostReload = self.pendingPostReloadSongInfo ~= nil,
			browseOnly = self.activeBrowseOnlyDownload == true,
		})
		return
	end
	if reason == "no_song_confirmed"
		and self.currentSongInfo == nil
		and self.currentStatus == self.status.Unknown
		and self.currentStatusMessage == nil
		and tostring(self.downloadInFlightKey or "") == ""
		and self.pendingPostReloadSongInfo == nil
		and self.activeBrowseOnlyDownload ~= true
	then
		trace("Reset local state skipped; already clear (" .. tostring(reason) .. ")")
		return
	end
	self.currentSongInfo = nil
	self.currentStatus = self.status.Unknown
	self.currentStatusMessage = nil
	self.statusChangedAt = 0
	self.watchdogLastKey = ""
	self.sequence = 0
	self.lastSelectedAt = ""
		self.lastPostedStatusSignature = ""
		self.lastPostedStatusAt = 0
		self:CancelStatusPostInFlight("reset_local_state")
		self.statusPostInFlightCallbacks = {}
		self:DiscardPendingStatusPost("reset_local_state")
		self.lastAppliedLocalStatusSignature = ""
		self.lastAppliedLocalStatusAt = 0
		self.lastResetSignature = ""
	self.lastResetAt = 0
	self.lastNoSongClearResetAt = now
	self.lastNoSongClearResetReason = normalizedReason
	self.localScanCache = {}
	self.lastCachedTerminalScanTraceKey = ""
	self.lastTerminalApplyKey = ""
	self.lastTerminalApplyStatus = ""
	self.browsePreviewPackKey = ""
	self.downloadInFlightKey = nil
	self.downloadStartedAt = nil
	self.downloadLastByteAt = nil
	self.downloadLastByteCount = nil
	self:ClearActiveDownloadId(reason or "reset_local_state")
	self.activeBrowseOnlyDownload = false
	self.pendingPostReloadSongInfo = nil
		self.pendingQuarantinePath = nil
		self.pendingPostReloadBrowseOnly = false
		self:ClearSelectedAvailabilityRetry(reason or "reset_local_state")
		self:NextDownloadGeneration(reason or "reset_local_state")
		if MESSAGEMAN then
			MESSAGEMAN:Broadcast("OnlinePackSyncLocalStatus", {
				status = self.status.Unknown,
				message = nil,
				download_progress = nil,
				selected_at = "",
				room_id = ITGOnline and ITGOnline.currentRoomId or nil,
				room_phase = ITGOnline and ITGOnline.currentRoom and ITGOnline.currentRoom.phase or nil,
				mode = ITGOnline and ITGOnline.currentRoomId and "joined" or "browse",
				local_only = true,
				reset_reason = normalizedReason,
			})
		end
		trace("Reset local state" .. (reason and (" (" .. tostring(reason) .. ")") or ""))
	trace_online_state("reset_local_state_complete", {
		reason = reason or "unknown",
		status = self.currentStatus or "nil",
		downloadKey = self.downloadInFlightKey or "",
		activeDownloadId = self.activeDownloadId or "",
		hasSong = self.currentSongInfo ~= nil,
		generation = self.downloadGeneration or "nil",
	})
end

function PackSync:CancelPendingPackChoice(reason)
	local status = tostring(self.currentStatus or self.status.Unknown)
	if trim(self.downloadInFlightKey) == "" or status ~= self.status.DownloadRequested then
		trace("CancelPendingPackChoice skipped reason=no_pending_choice requested_reason=" .. tostring(reason or "unknown")
			.. " status=" .. tostring(status)
			.. " key=" .. tostring(self.downloadInFlightKey or "")
			.. " browseOnly=" .. tostring(self.activeBrowseOnlyDownload == true))
		return false
	end

	local songInfo = self.currentSongInfo
	local wasBrowseOnly = self.activeBrowseOnlyDownload == true
	trace("Pending pack choice cancelled reason=" .. tostring(reason or "user_cancelled")
		.. " key=" .. tostring(self.downloadInFlightKey)
		.. " browseOnly=" .. tostring(wasBrowseOnly))
	self.downloadInFlightKey = nil
	self.downloadStartedAt = nil
	self.downloadLastByteAt = nil
	self.downloadLastByteCount = nil
	self.pendingPostReloadBrowseOnly = false
	self.activeBrowseOnlyDownload = false
	self.watchdogLastKey = ""
	self:NextDownloadGeneration(reason or "pack_choice_cancelled")

	if wasBrowseOnly and songInfo then
		self:ManagerBrowsingPreview(songInfo)
	else
		self:UpdateStatus(
			self.status.NoCompatibleChartFound,
			pack_text("PackDownloadCancelled", "Pack download cancelled."),
			nil,
			nil,
			{ downloadCancelled = true })
	end
	return true
end

function PackSync:SyncSequenceFromRoom(currentSelectedAt)
	if not (ITGOnline and ITGOnline.currentRoom) then return end
	self:SyncSequenceFromRoomPayload(ITGOnline.currentRoom, currentSelectedAt, "current_room")
end

function PackSync:InvalidateLocalChartIndex()
	self.localChartIndex = nil
	self.localChartIndexKey = nil
	self.localScanCache = {}
	self.lastCachedTerminalScanTraceKey = ""
	self.lastTerminalApplyKey = ""
	self.lastTerminalApplyStatus = ""
end

function PackSync:LocalChartIndex()
	local key = local_song_library_key()
	if self.localChartIndex and self.localChartIndexKey == key then
		trace("LocalChartIndex reused key=" .. tostring(key))
		return self.localChartIndex
	end

	local index = {}
	local songCount = 0
	local stepsCount = 0
	local hashCount = 0
	if SONGMAN and SONGMAN.GetAllSongs then
		local ok, songs = pcall(function() return SONGMAN:GetAllSongs() end)
		if not ok or type(songs) ~= "table" then songs = {} end
		for song in ivalues(songs) do
			songCount = songCount + 1
			for steps in ivalues(playable_steps(song)) do
				stepsCount = stepsCount + 1
				local hash = normalized_hash(chart_hash_for_steps(steps))
				if hash ~= "" then
					if index[hash] == nil then hashCount = hashCount + 1 end
					index[hash] = index[hash] or {}
					index[hash][#index[hash] + 1] = { song = song, steps = steps }
				end
			end
		end
	end

	self.localChartIndex = index
	self.localChartIndexKey = key
	trace("LocalChartIndex built key=" .. tostring(key)
		.. " songs=" .. tostring(songCount)
		.. " steps=" .. tostring(stepsCount)
		.. " hashes=" .. tostring(hashCount))
	return index
end

function PackSync:ManagerBrowsingPreview(songInfo)
	if not songInfo then
		trace("ManagerBrowsingPreview skipped reason=no_song_info")
		return
	end
	local packName = selected_pack(songInfo)
	if packName == "" then
		trace("ManagerBrowsingPreview skipped reason=no_pack title=" .. tostring(selected_title(songInfo)))
		return
	end
	if self:IsActiveDownload() then
		trace("Manager browsing preview ignored during active download pack=" .. tostring(packName)
			.. " status=" .. tostring(self.currentStatus or "nil")
			.. " key=" .. tostring(self.downloadInFlightKey or "")
			.. " browseOnly=" .. tostring(self.activeBrowseOnlyDownload == true)
			.. " pendingPostReload=" .. tostring(self.pendingPostReloadSongInfo ~= nil))
		return
	end

	self.currentSongInfo = songInfo
	local packKey = pack_name_key(packName)
	local exists = self:PackExists(packName)
	-- A locally available pack is not a completed transfer.  Keep the terminal
	-- downloaded_ok status reserved for an identified download acknowledged at
	-- 100%, as required by the server protocol.
	local status = exists and self.status.LocalChartMatchFound or self.status.ManagerBrowsingUnknownPack
	local message = exists and pack_text("PackAvailableLocally", "Pack available locally.")
		or pack_text("PackMissingSearchAvailable", "Pack missing. You can search for a matching pack.")
	if exists and self.downloadedPackKey == packKey then
		message = pack_text("PackDownloadedAvailable", "Pack downloaded and available locally.")
	end
	-- downloaded_ok is a terminal transfer acknowledgement and requires the
	-- immutable download id plus progress=100.  A later preview refresh must not
	-- manufacture a second, incomplete terminal update while that acknowledgement
	-- is queued or already applied.
	if exists
		and self.downloadedPackKey == packKey
		and self.currentStatus == self.status.DownloadedOk then
		trace("Manager browsing preview preserved completed download pack=" .. tostring(packName)
			.. " reason=terminal_download_status_is_not_preview_state")
		self.currentSongInfo = songInfo
		return
	end
	local normalizedMessage = status_message(message)
	local postKey = table.concat({
		tostring(ITGOnline and ITGOnline.currentRoomId or ""),
		packKey,
		status,
		tostring(normalizedMessage or ""),
	}, "|")
	local now = GetTimeSinceStart and GetTimeSinceStart() or 0
	if postKey ~= ""
		and postKey == tostring(self.lastManagerBrowsingPreviewPostKey or "")
		and (now - (tonumber(self.lastManagerBrowsingPreviewPostAt) or 0)) < (tonumber(self.managerBrowsingPreviewDuplicateSuppressSeconds) or 1.5) then
		trace("Manager browsing preview skipped duplicate_recent pack=" .. tostring(packName)
			.. " status=" .. tostring(status)
			.. " age=" .. string.format("%.3f", now - (tonumber(self.lastManagerBrowsingPreviewPostAt) or 0)))
		self:ApplyLocalStatus(status, normalizedMessage)
		return
	end
	trace("Manager browsing preview pack=" .. tostring(packName)
		.. " exists=" .. tostring(exists)
		.. " previous_pack_key=" .. tostring(self.browsePreviewPackKey or "")
		.. " next_status=" .. tostring(status))
	if self.browsePreviewPackKey == packKey
		and self.currentStatus == status
		and self.currentStatusMessage == normalizedMessage then
		return
	end

	self.browsePreviewPackKey = packKey
	self.lastManagerBrowsingPreviewPostKey = postKey
	self.lastManagerBrowsingPreviewPostAt = now
	self:UpdateStatus(status, normalizedMessage)
end

-- Local chart matching and selection
-- -----------------------------------------------------------------------

function PackSync:FindLocalMatch(songInfo)
	trace("FindLocalMatch begin title=" .. tostring(selected_title(songInfo))
		.. " pack=" .. tostring(selected_pack(songInfo))
		.. " chartHash=" .. tostring(selected_chart_hash(songInfo)):sub(1, 12)
		.. " songHash=" .. tostring(selected_song_hash(songInfo)):sub(1, 12)
		.. " selectedAt=" .. tostring(selected_at(songInfo)))
	if not songInfo then
		return { ok = false, status = "missing", reason = "missing_local_song" }
	end

	self.currentSongInfo = songInfo
	if self:IsActiveDownload() and self.validatingPostReload ~= true then
		local deferredKey = table.concat({
			selected_at(songInfo),
			self.downloadInFlightKey or "",
			self.activeDownloadId or "",
			self.currentStatus or "",
		}, "|")
		local traceEmitted = self.lastDeferredLocalMatchTraceKey ~= deferredKey
		if traceEmitted then
			self.lastDeferredLocalMatchTraceKey = deferredKey
			trace("Deferring local chart scan until active download completes title=" .. selected_title(songInfo))
			trace_online_state("local_match_deferred_active_download", {
				selected_at = selected_at(songInfo),
				title = selected_title(songInfo),
				pack = selected_pack(songInfo),
				status = self.currentStatus or "nil",
				downloadKey = self.downloadInFlightKey or "",
				activeDownloadId = self.activeDownloadId or "",
				browseOnly = self.activeBrowseOnlyDownload == true,
				outcome = "deferred",
			})
		end
		return {
			ok = false,
			deferred = true,
			traceEmitted = traceEmitted,
			status = "download_in_progress",
			reason = "download_in_progress",
		}
	end
	local scanKey = local_scan_key(songInfo)
	local cachedScan = self.localScanCache and self.localScanCache[scanKey] or nil
	if cachedScan and cachedScan.ok == true then
		runtime_validation_trace("reused successful local chart scan title=" .. selected_title(songInfo)
			.. " source=" .. tostring(cachedScan.matchSource or "unknown"))
		self:ApplyLocalStatus(self.status.LocalChartMatchFound, cachedScan.matchMessage)
		return {
			ok = true,
			status = "matched",
			song = cachedScan.song,
			steps = cachedScan.steps,
			payload = cachedScan.payload,
			matchSource = cachedScan.matchSource,
			matchMessage = cachedScan.matchMessage,
		}
	elseif cachedScan and cachedScan.ok == false then
		if self.lastCachedTerminalScanTraceKey ~= scanKey then
			self.lastCachedTerminalScanTraceKey = scanKey
			trace("Local chart scan reused cached terminal result title=" .. selected_title(songInfo)
				.. " status=" .. tostring(cachedScan.status)
				.. " reason=" .. tostring(cachedScan.reason))
		end
		local cachedStatus = cachedScan.status == "mismatch"
			and self.status.ChartMismatch or self.status.NoCompatibleChartFound
		if self.currentStatus ~= cachedStatus or self.currentStatusMessage ~= cachedScan.message then
			self:ApplyLocalStatus(cachedStatus, cachedScan.message)
		end
		return {
			ok = false,
			status = cachedScan.status,
			reason = cachedScan.reason,
		}
	end
	trace("Searching local charts title=" .. selected_title(songInfo) .. " pack=" .. selected_pack(songInfo))
	if self.validatingPostReload == true then
		self:ApplyLocalStatus(self.status.ValidatingDownload)
	else
		self:UpdateStatus(self.status.SearchingLocalCharts, nil)
	end

	local expectedChartHash = selected_chart_hash(songInfo)
		if expectedChartHash == "" then
			trace("Local chart scan failed reason=missing_expected_chart_hash title=" .. selected_title(songInfo)
				.. " pack=" .. selected_pack(songInfo)
				.. " selected_at=" .. selected_at(songInfo))
			return { ok = false, status = "missing", reason = "chart_hash_mismatch" }
		end
		if not (SONGMAN and SONGMAN.FindSong and SONGMAN.GetAllSongs) then
			trace("Local chart scan failed reason=songman_unavailable title=" .. selected_title(songInfo)
				.. " pack=" .. selected_pack(songInfo)
				.. " selected_at=" .. selected_at(songInfo))
			self:ApplyLocalStatus(self.status.NoCompatibleChartFound, "La bibliothèque locale n'est pas disponible.")
			return { ok = false, status = "missing", reason = "songman_unavailable" }
		end

		local exactPath = selected_path(songInfo)
		local exactSong = nil
		if exactPath ~= "" then
			local ok, found = pcall(function() return SONGMAN:FindSong(exactPath) end)
			exactSong = ok and found or nil
		end
		trace("Local chart exact path lookup path=" .. tostring(exactPath)
			.. " found=" .. tostring(exactSong ~= nil))
		if not exactSong and exactPath ~= "" then
			local parts = split_path_segments(exactPath)
			local fallbackPath = ""
			if #parts >= 3 and lower(parts[1]) == "songs" then
				fallbackPath = parts[2] .. "/" .. parts[3] .. "/"
			elseif #parts >= 2 then
				fallbackPath = parts[#parts - 1] .. "/" .. parts[#parts] .. "/"
			end
			if fallbackPath ~= "" then
				local ok, found = pcall(function() return SONGMAN:FindSong(fallbackPath) end)
				exactSong = ok and found or nil
			end
			trace("Local chart fallback path lookup folder=" .. tostring(fallbackPath ~= "" and fallbackPath or "nil")
				.. " found=" .. tostring(exactSong ~= nil))
		end

	local mismatchReason = nil
	local function evaluate_candidate(song, source)
		local steps = matching_steps_in_song(song, songInfo)
		if not steps then return nil end

		trace("Candidate chart found " .. tostring(source or song:GetSongDir()))
		trace("Candidate expected chart_hash=" .. tostring(selected_chart_hash(songInfo))
			.. " expected song_hash=" .. tostring(selected_song_hash(songInfo)))
		trace("Candidate local song_dir=" .. tostring(song and song.GetSongDir and song:GetSongDir() or ""))
		trace("Candidate local chart_hash=" .. tostring(chart_hash_for_steps(steps) or ""))
		local payload = build_payload(song, steps)
		local payloadOk, reason = payload_matches_selected(payload, songInfo)
		if payload then
			trace("Candidate payload chart_hash=" .. tostring(payload.chart_hash or "")
				.. " payload song_hash=" .. tostring(payload.song_hash or ""))
		end
		if payloadOk then
			trace("Matching local chart found " .. tostring(source or song:GetSongDir()))
			local matchSource = source == "manager pack" and "manager_pack" or "alternate_pack"
			local matchMessage = matchSource == "manager_pack"
				and pack_text("PackAndChartFound", "Pack and chart found")
				or pack_text("CompatibleChartFound", "Pack missing / compatible chart found")
			self:UpdateStatus(self.status.LocalChartMatchFound, matchMessage)
			local result = { ok = true, status = "matched", song = song, steps = steps, payload = payload, matchSource = matchSource, matchMessage = matchMessage }
			self.localScanCache[scanKey] = result
			return result
		end

		mismatchReason = mismatchReason or reason or "chart_mismatch"
		trace("Candidate hash mismatch " .. tostring(source or song:GetSongDir()) .. " reason=" .. tostring(mismatchReason))
		return nil
	end

	if exactSong then
		local result = evaluate_candidate(exactSong, "manager pack")
		if result then return result end
	end

		local okSongs, allSongs = pcall(function() return SONGMAN:GetAllSongs() end)
		allSongs = okSongs and type(allSongs) == "table" and allSongs or {}
		for song in ivalues(allSongs) do
			if song ~= exactSong and song_matches_text_prefilter(song, songInfo) then
				local result = evaluate_candidate(song)
			if result then return result end
		end
	end

	local indexedCandidates = {}
	if SONGMAN.FindStepsByOnlineChartHash then
		local okCandidates, candidates = pcall(function()
			return SONGMAN:FindStepsByOnlineChartHash(expectedChartHash)
		end)
		if okCandidates and type(candidates) == "table" then
			indexedCandidates = candidates
		else
			trace("Native chart hash lookup failed; using Lua index fallback error="
				.. tostring(candidates or "invalid_result"))
			indexedCandidates = self:LocalChartIndex()[expectedChartHash] or {}
		end
	else
		indexedCandidates = self:LocalChartIndex()[expectedChartHash] or {}
	end
	trace("Local chart hash index candidates hash=" .. tostring(expectedChartHash)
		.. " count=" .. tostring(#indexedCandidates))
	for candidate in ivalues(indexedCandidates) do
		if candidate.song ~= exactSong and not song_matches_text_prefilter(candidate.song, songInfo) then
			trace("Candidate chart found via hash index " .. tostring(candidate.song:GetSongDir()))
			local payload = build_payload(candidate.song, candidate.steps)
			local payloadOk, reason = payload_matches_selected(payload, songInfo)
			if payloadOk then
				trace("Matching local chart found via hash index " .. tostring(candidate.song:GetSongDir()))
				local matchMessage = pack_text("CompatibleChartFound", "Pack missing / compatible chart found")
				self:UpdateStatus(self.status.LocalChartMatchFound, matchMessage)
				local result = { ok = true, status = "matched", song = candidate.song, steps = candidate.steps, payload = payload, matchSource = "alternate_pack", matchMessage = matchMessage }
				self.localScanCache[scanKey] = result
				return result
			end
			trace("Candidate hash index mismatch dir=" .. tostring(candidate.song:GetSongDir())
				.. " reason=" .. tostring(reason or "unknown")
				.. " expectedSongHash=" .. tostring(selected_song_hash(songInfo)))
			mismatchReason = mismatchReason or reason or "chart_mismatch"
		end
	end

	if mismatchReason then
		local message = mismatchReason == "song_hash_mismatch"
			and pack_text("LocalChartAudioMismatch", "The chart exists locally, but its audio differs from the manager's.")
			or pack_text("SongOrChartMismatch", "The song or chart differs from the manager's.")
		self:UpdateStatus(self.status.ChartMismatch, message)
		self.localScanCache[scanKey] = { ok = false, status = "mismatch", reason = mismatchReason, message = message }
		return { ok = false, status = "mismatch", reason = mismatchReason }
	end

	trace("No compatible chart found title=" .. selected_title(songInfo))
	local message = pack_text("NoIdenticalManagerChart", "No chart identical to the manager's was found.")
	self:UpdateStatus(self.status.NoCompatibleChartFound, message)
	self.localScanCache[scanKey] = { ok = false, status = "missing", reason = "no_compatible_chart_found", message = message }
	return { ok = false, status = "missing", reason = "no_compatible_chart_found" }
end

function PackSync:ApplySelectedChart(songInfo)
	-- A download owns the song scan until its reload/validation finishes.  Room
	-- snapshots can repeat while that happens; do not rescan or re-log the same
	-- selected chart for the same in-flight transfer.
	if self:IsActiveDownload() and self.validatingPostReload ~= true then
		local deferredKey = table.concat({
			selected_at(songInfo),
			self.downloadInFlightKey or "",
			self.activeDownloadId or "",
			self.currentStatus or "",
		}, "|")
		if self.lastDeferredApplyKey == deferredKey then
			return false
		end
		self.lastDeferredApplyKey = deferredKey
		trace("ApplySelectedChart deferred reason=active_download"
			.. " title=" .. tostring(selected_title(songInfo))
			.. " selected_at=" .. tostring(selected_at(songInfo))
			.. " downloadKey=" .. tostring(self.downloadInFlightKey or "")
			.. " activeDownloadId=" .. tostring(self.activeDownloadId or ""))
		trace_online_state("apply_selected_chart_deferred", {
			selected_at = selected_at(songInfo),
			status = self.currentStatus or "nil",
			reason = "download_in_progress",
			outcome = "deferred_before_scan",
		})
		return false
	end
	self.lastDeferredApplyKey = ""

	-- Room snapshots can repeat without changing either the selected chart or
	-- the local song library.  Once the same generation has produced a terminal
	-- negative result, keep the existing status and missing-song notification
	-- instead of re-emitting both for every snapshot.  Song reloads explicitly
	-- invalidate this key through InvalidateLocalChartIndex().
	local applyKey = terminal_apply_key(songInfo, self.downloadGeneration)
	if applyKey ~= ""
		and self.lastTerminalApplyKey == applyKey
		and self.lastTerminalApplyStatus ~= ""
		and self.currentStatus == self.lastTerminalApplyStatus
	then
		return false
	end

	trace_online_state("apply_selected_chart_begin", {
		selected_at = selected_at(songInfo),
		title = selected_title(songInfo),
		pack = selected_pack(songInfo),
		chartHash = tostring(selected_chart_hash(songInfo)):sub(1, 12),
		status = self.currentStatus or "nil",
		downloadKey = self.downloadInFlightKey or "",
		activeDownloadId = self.activeDownloadId or "",
	})
	trace("ApplySelectedChart begin title=" .. tostring(selected_title(songInfo))
		.. " pack=" .. tostring(selected_pack(songInfo))
		.. " selected_at=" .. tostring(selected_at(songInfo))
		.. " chart_hash=" .. tostring(selected_chart_hash(songInfo))
		.. " room=" .. tostring(ITGOnline and ITGOnline.currentRoomId or "nil")
		.. " phase=" .. tostring(ITGOnline and ITGOnline.currentRoom and ITGOnline.currentRoom.phase or "nil")
		.. " downloadWorkInFlight=" .. tostring(self:HasDownloadWorkInFlight())
		.. " activeDownloadId=" .. tostring(self.activeDownloadId or "")
		.. " generation=" .. tostring(self.downloadGeneration or "nil"))
		local okFind, result = pcall(function() return self:FindLocalMatch(songInfo) end)
		if not okFind or type(result) ~= "table" then
			trace("ApplySelectedChart local match failed err=" .. tostring(result))
			result = { ok = false, status = "missing", reason = "local_match_error" }
		end
	if result.deferred == true and result.traceEmitted == true then
		trace("ApplySelectedChart deferred status=" .. tostring(result.status or "nil")
			.. " reason=" .. tostring(result.reason or "nil"))
		trace_online_state("apply_selected_chart_deferred", {
			selected_at = selected_at(songInfo),
			status = result.status or "nil",
			reason = result.reason or "nil",
			outcome = "deferred",
		})
	else
		trace("ApplySelectedChart result ok=" .. tostring(result and result.ok == true)
			.. " status=" .. tostring(result and result.status or "nil")
			.. " reason=" .. tostring(result and result.reason or "nil")
			.. " message=" .. tostring(result and result.message or "nil"))
		trace_online_state("apply_selected_chart_result", {
			selected_at = selected_at(songInfo),
			ok = result and result.ok == true,
			status = result and result.status or "nil",
			reason = result and result.reason or "nil",
		})
	end
	if result.ok then
		self.lastTerminalApplyKey = ""
		self.lastTerminalApplyStatus = ""
		set_current_selection(result.song, result.steps, songInfo, "pack_sync_apply_selected_chart")
		if MESSAGEMAN then
			MESSAGEMAN:Broadcast("OnlineSongAvailable", { songInfo = songInfo })
		end
		-- Local and freshly downloaded charts use the same acknowledged retry
		-- path.  A transient HTTP failure must never strand the member in the
		-- intermediate LOCAL_CHART_MATCH_FOUND state.
		self:FinalizeDownloadedSelectedSongAvailability(
			songInfo,
			"local_chart_match_found",
			result.matchMessage)
		return true
	end

	local reason = result.reason or "missing_local_song"
	if result.deferred == true or reason == "download_in_progress" then
		return false
	end
	if result.status == "mismatch" then
		if MESSAGEMAN then
			MESSAGEMAN:Broadcast("OnlineMissingSong", { songInfo = songInfo, reason = reason, chartMismatch = true })
		end
	else
		if MESSAGEMAN then
			MESSAGEMAN:Broadcast("OnlineMissingSong", { songInfo = songInfo, reason = reason, noCompatibleChart = true })
		end
	end
	if result.status == "mismatch" then
		self.lastTerminalApplyKey = applyKey
		self.lastTerminalApplyStatus = self.status.ChartMismatch
	elseif result.reason == "no_compatible_chart_found" then
		self.lastTerminalApplyKey = applyKey
		self.lastTerminalApplyStatus = self.status.NoCompatibleChartFound
	else
		-- Transport, parser, and SONGMAN availability failures are transient.
		-- They must remain retryable even when the room selection is unchanged.
		self.lastTerminalApplyKey = ""
		self.lastTerminalApplyStatus = ""
	end
	return false
end

function PackSync:MarkLobbyReadyForSelectedSong(source, retrying)
	if not (ITGOnline and ITGOnline.SetReady) then
		trace("MarkLobbyReady skipped reason=no_online_client source=" .. tostring(source or "unknown"))
		return false
	end
	local phase = ITGOnline.NormalizeRoomPhase and ITGOnline:NormalizeRoomPhase(ITGOnline.currentRoom and ITGOnline.currentRoom.phase) or tostring(ITGOnline.currentRoom and ITGOnline.currentRoom.phase or "")
	if phase == "config" then
		trace("MarkLobbyReady skipped reason=already_config source=" .. tostring(source or "unknown"))
		if ITGOnline.EnforceRoomPhaseScreen then ITGOnline:EnforceRoomPhaseScreen() end
		return true
	end
	if phase ~= "lobby_ready" and phase ~= "lobby" then
		trace("MarkLobbyReady skipped reason=phase_not_lobby source=" .. tostring(source or "unknown")
			.. " phase=" .. tostring(phase))
		return false
	end
	if ITGOnline.CurrentUserConfirmedSelectedSong then
		local confirmed, confirmationReason = ITGOnline:CurrentUserConfirmedSelectedSong(ITGOnline.currentRoom)
		if not confirmed then
			trace("MarkLobbyReady skipped reason=local_song_not_confirmed"
				.. " source=" .. tostring(source or "unknown")
				.. " confirmation=" .. tostring(confirmationReason or "unknown")
				.. " phase=" .. tostring(phase))
			return false
		end
	end
	trace("MarkLobbyReady begin source=" .. tostring(source or "unknown")
		.. " retrying=" .. tostring(retrying == true)
		.. " room=" .. tostring(ITGOnline.currentRoomId or "nil")
		.. " phase=" .. tostring(phase)
		.. " selected_at=" .. tostring(current_room_selected_at())
		.. " currentTitle=" .. tostring(selected_title(current_room_selected_song()))
		.. " status=" .. tostring(self.currentStatus or "nil")
		.. " downloadWorkInFlight=" .. tostring(self:HasDownloadWorkInFlight()))
	local readyIntentKey = table.concat({
		tostring(ITGOnline.currentRoomId or ""),
		tostring(current_room_selected_at()),
		tostring(phase),
	}, "|")
	local now = GetTimeSinceStart and GetTimeSinceStart() or 0
	if self.markLobbyReadyInFlightKey == readyIntentKey then
		trace("MarkLobbyReady skipped reason=in_flight"
			.. " source=" .. tostring(source or "unknown")
			.. " key=" .. tostring(readyIntentKey))
		return true
	end
	if retrying ~= true and self.lastMarkLobbyReadyCompletedKey == readyIntentKey then
		trace("MarkLobbyReady skipped reason=already_acknowledged"
			.. " source=" .. tostring(source or "unknown")
			.. " key=" .. tostring(readyIntentKey))
		return true
	end
	if retrying ~= true
		and self.lastMarkLobbyReadyIntentKey == readyIntentKey
		and (now - (tonumber(self.lastMarkLobbyReadyIntentAt) or 0)) < 1.5
	then
		trace("MarkLobbyReady skipped reason=recent_duplicate"
			.. " source=" .. tostring(source or "unknown")
			.. " key=" .. tostring(readyIntentKey)
			.. " age=" .. string.format("%.3f", now - (tonumber(self.lastMarkLobbyReadyIntentAt) or 0)))
		return true
	end
	self.markLobbyReadyInFlightKey = readyIntentKey
	self.lastMarkLobbyReadyIntentKey = readyIntentKey
	self.lastMarkLobbyReadyIntentAt = now
	trace_online_state("mark_lobby_ready_begin", {
		source = source or "unknown",
		phase = phase,
		retrying = retrying == true,
		status = self.currentStatus or "nil",
		selected_at = selected_at(self.currentSongInfo),
	})
	ITGOnline:SetReady("lobby_ready", true, function(ok, decoded, response)
		if self.markLobbyReadyInFlightKey == readyIntentKey then
			self.markLobbyReadyInFlightKey = ""
		end
		trace("MarkLobbyReady response source=" .. tostring(source or "unknown")
			.. " ok=" .. tostring(ok == true)
			.. " status=" .. tostring(response and response.statusCode or "nil")
			.. " error=" .. tostring(decoded and decoded.error_code or response and response.errorMessage or "nil")
			.. " hasRoom=" .. tostring(decoded and decoded.room ~= nil)
			.. " phase=" .. tostring(decoded and decoded.room and decoded.room.phase or ITGOnline.currentRoom and ITGOnline.currentRoom.phase or "nil"))
		trace_online_state("mark_lobby_ready_response", {
			source = source or "unknown",
			roomSnapshot = decoded and decoded.room or nil,
			ok = ok == true,
			statusCode = response and response.statusCode or "nil",
			error = decoded and decoded.error_code or response and response.errorMessage or "nil",
			selected_at = selected_at(self.currentSongInfo),
		})
		if ok then
			self.lastMarkLobbyReadyCompletedKey = readyIntentKey
			if ITGOnline.EnforceRoomPhaseScreen then ITGOnline:EnforceRoomPhaseScreen() end
			return
		end
		local errorCode = tostring(decoded and decoded.error_code or "")
		if errorCode == "ready_context_changed" then
			trace("MarkLobbyReady stopped reason=ready_context_changed"
				.. " source=" .. tostring(source or "unknown")
				.. " selected_at=" .. tostring(current_room_selected_at())
				.. " hasRoom=" .. tostring(decoded and decoded.room ~= nil))
			if decoded and decoded.room and ITGOnline.ApplyRoomSnapshot then
				ITGOnline:ApplyRoomSnapshot(decoded.room, "mark_lobby_ready_context_changed")
				if MESSAGEMAN then
					MESSAGEMAN:Broadcast("OnlineLobbyState", ITGOnline:LobbyStatePayload(decoded.room))
				end
				if ITGOnline.EnforceRoomPhaseScreen then ITGOnline:EnforceRoomPhaseScreen() end
			elseif ITGOnline.EnsureCurrentRoom then
				ITGOnline:EnsureCurrentRoom()
			end
			return
		end
		if retrying then return end
		if ITGOnline.EnsureCurrentRoom then
			ITGOnline:EnsureCurrentRoom(function(fetchOk)
				trace("MarkLobbyReady retry_refresh source=" .. tostring(source or "unknown")
					.. " ok=" .. tostring(fetchOk == true))
				if fetchOk then
					self.lastMarkLobbyReadyIntentKey = ""
					self.lastMarkLobbyReadyIntentAt = 0
					self:MarkLobbyReadyForSelectedSong(tostring(source or "unknown") .. "_retry", true)
				end
			end)
		end
	end)
	return true
end

-- External catalogue lookup and transactional installation
-- -----------------------------------------------------------------------

local function stepmaniaonline_origin()
	-- API endpoints now resolve reliably on the apex domain.
	return "https://stepmaniaonline.net"
end

local function request_json(url, callback, options)
	options = options or {}
	local requestLabel = tostring(options.logLabel or "stepmaniaonline")
	if not (NETWORK and NETWORK.HttpRequest) then
		trace("HTTP JSON skipped reason=network_unavailable request=" .. requestLabel)
		safe_invoke_callback(callback, false, nil, { errorMessage = pack_text("EngineNetworkUnavailable", "The engine network service is unavailable.") })
		return
	end
	if type(JsonDecode) ~= "function" then
		trace("HTTP JSON skipped reason=json_decode_unavailable request=" .. requestLabel)
		safe_invoke_callback(callback, false, nil, { errorMessage = pack_text("JsonDecoderUnavailable", "The JSON decoder is unavailable.") })
		return
	end
	local okRequest, requestOrError = pcall(function()
		return NETWORK:HttpRequest({
		url = url,
		method = "GET",
		headers = {
			["Accept"] = "application/json",
			["Accept-Encoding"] = "identity",
		},
		connectTimeout = 10,
		transferTimeout = 20,
			onResponse = function(response)
			local statusCode = tonumber(response and response.statusCode) or 0
				if statusCode ~= 200 then
					if statusCode == 404 and options.expected404 == true then
						trace("HTTP JSON not found (expected fallback) request=" .. requestLabel)
					else
						trace("HTTP JSON failed status=" .. tostring(statusCode) .. " request=" .. requestLabel)
					end
					safe_invoke_callback(callback, false, nil, response)
					return
				end
				local ok, decoded = pcall(JsonDecode, response.body or "")
				if not ok or decoded == nil then
					local bodyLength = #(tostring(response and response.body or ""))
					trace("HTTP JSON decode failed status=" .. tostring(statusCode)
						.. " request=" .. requestLabel
						.. " body_length=" .. tostring(bodyLength))
					local firstByte = string.byte(response and response.body or "", 1)
					local secondByte = string.byte(response and response.body or "", 2)
					if firstByte == 0x1f and secondByte == 0x8b then
						safe_invoke_callback(callback, false, nil, {
							statusCode = statusCode,
							errorMessage = pack_text("CompressedCatalogResponseInvalid", "The compressed StepManiaOnline response could not be decoded."),
						})
						return
					end
				end
				safe_invoke_callback(callback, ok and decoded ~= nil, decoded, response)
			end,
		})
	end)
	if not okRequest then
		trace("HTTP JSON request failed request=" .. requestLabel .. " err=" .. tostring(requestOrError))
		safe_invoke_callback(callback, false, nil, { errorMessage = pack_text("CatalogRequestFailed", "The StepManiaOnline request failed.") })
	end
end

local function path_escape(value)
	return tostring(value or ""):gsub("([^%w%._:%-])", function(char)
		return string.format("%%%02X", string.byte(char))
	end)
end

local function canonical_id(value)
	if ITGOnlineProtocol and ITGOnlineProtocol.canonical_decimal_id then
		return ITGOnlineProtocol.canonical_decimal_id(value)
	end
	local text = tostring(value or "")
	if not text:match("^%d+$") then return nil end
	text = text:gsub("^0+", "")
	return text ~= "" and text or "0"
end

local function build_pack_candidate(packResult, source)
	if type(packResult) ~= "table" then return nil end
	local id = canonical_id(packResult.id)
	if not id or id == "0" then return nil end
	local archiveHash = tostring(packResult.archive_sha256 or packResult.download_sha256 or packResult.sha256 or ""):lower()
	return {
		id = id,
		name = trim(packResult.name or ("Pack " .. tostring(id))),
		songs_count = tonumber(packResult.songs_count) or 0,
		archive_sha256 = #archiveHash == 64 and archiveHash:match("^[a-f0-9]+$") and archiveHash or nil,
		match_source = source or "unknown",
	}
end

local function disk_free_bytes(path)
	if not (FILEMAN and FILEMAN.GetDiskFreeSpaceBytes) then return nil end
	local ok, value = pcall(function() return FILEMAN:GetDiskFreeSpaceBytes(path) end)
	value = ok and tonumber(value) or nil
	if not value or value <= 0 then return nil end
	return value
end

local function dedupe_candidates(candidates)
	local byId = {}
	for _, candidate in ipairs(candidates or {}) do
		if candidate and candidate.id then
			byId[tostring(candidate.id)] = candidate
		end
	end
	local deduped = {}
	for _, candidate in pairs(byId) do
		deduped[#deduped + 1] = candidate
	end
	table.sort(deduped, function(a, b)
		return tostring(a.name or "") < tostring(b.name or "")
	end)
	return deduped
end

local function remove_path_if_exists(path)
	if not FILEMAN or not FILEMAN.DoesFileExist then return end
	if not path or path == "" or not FILEMAN:DoesFileExist(path) then return end
	-- Lua DeleteRecursive guard rejects file-like paths (e.g. *.zip). If the
	-- direct Remove binding is unavailable, skip cleanup to avoid noisy warnings.
	if tostring(path):lower():match("%.zip$") and not FILEMAN.Remove then
		return
	end
	if FILEMAN.Remove then
		FILEMAN:Remove(path)
		return
	end
	if FILEMAN.DeleteRecursive then
		FILEMAN:DeleteRecursive(path)
	end
end

local function log_dir_listing(prefix, path)
	if not FILEMAN or not FILEMAN.GetDirListing then return end
	local ok, entries = pcall(function()
		return FILEMAN:GetDirListing(path .. "*", false, true)
	end)
	if not ok or type(entries) ~= "table" then
		trace(prefix .. " path=<engine-pack-path> entries=<unavailable>")
		return
	end
	table.sort(entries)
	trace(prefix .. " path=<engine-pack-path> entries=" .. tostring(#entries))
	for i = 1, math.min(#entries, 20) do
		trace(prefix .. " entry[" .. tostring(i) .. "]=<redacted>")
	end
	if #entries > 20 then
		trace(prefix .. " ... truncated")
	end
end

local function install_extracted_pack_at_songs_root(quarantinePath, expectedPackName)
	trace("Install extracted pack begin quarantine=" .. tostring(quarantinePath)
		.. " expectedPack=" .. tostring(expectedPackName)
		.. " songsRootExists=" .. tostring(path_exists("/Songs/") or path_exists("/Songs")))
	log_dir_listing("Install quarantine before cleanup", quarantinePath)
	remove_temp_newdir_artifacts(quarantinePath, 4)
	local nestedGroup = single_nested_group_folder(quarantinePath, expectedPackName)
	if nestedGroup == "" then
		log_dir_listing("Install quarantine invalid", quarantinePath)
		return nil, pack_text("ArchiveMissingSinglePackFolder", "The downloaded archive does not contain exactly one pack folder.")
	end

	local sourcePath = quarantinePath .. nestedGroup
	local rootGroupPath = "/Songs/" .. nestedGroup
	trace("Install extracted pack resolved nestedGroup=" .. tostring(nestedGroup)
		.. " source=" .. tostring(sourcePath)
		.. " target=" .. tostring(rootGroupPath)
		.. " sourceExists=" .. tostring(path_exists(sourcePath) or path_exists(sourcePath .. "/"))
		.. " targetExists=" .. tostring(path_exists(rootGroupPath) or path_exists(rootGroupPath .. "/")))
	remove_temp_newdir_artifacts(sourcePath .. "/", 4)
	if path_exists(rootGroupPath) or path_exists(rootGroupPath .. "/") then
		log_dir_listing("Install existing target", rootGroupPath .. "/")
		remove_directory_if_possible(quarantinePath)
		trace("Install extracted pack rejected existing target=" .. tostring(rootGroupPath)
			.. " quarantineExistsAfterCleanup=" .. tostring(path_exists(quarantinePath) or path_exists(quarantinePath .. "/")))
		return nil, pack_text("PackFolderAlreadyExists", "A local pack folder with the same name already exists.")
	end
	if not FILEMAN or not FILEMAN.MoveOnlineSongPack then
		return nil, pack_text("EngineCannotInstallPack", "The engine cannot install the downloaded pack.")
	end
	local moved = FILEMAN:MoveOnlineSongPack(sourcePath, rootGroupPath)
	flush_dir_cache("/Songs/")
	flush_dir_cache(quarantinePath)
	flush_dir_cache(sourcePath)
	flush_dir_cache(rootGroupPath)
	trace("MoveOnlineSongPack result moved=" .. tostring(moved)
		.. " sourceExistsAfter=" .. tostring(path_exists(sourcePath) or path_exists(sourcePath .. "/"))
		.. " targetExistsAfter=" .. tostring(path_exists(rootGroupPath) or path_exists(rootGroupPath .. "/")))
	if not moved then
		trace("MoveOnlineSongPack failed; refusing non-transactional recursive copy source=" .. tostring(sourcePath) .. " target=" .. tostring(rootGroupPath))
		remove_directory_if_possible(quarantinePath)
		return nil, pack_text("AtomicPackInstallFailed", "Could not install the downloaded pack atomically.")
	elseif path_exists(sourcePath) or path_exists(sourcePath .. "/") then
		trace("MoveOnlineSongPack left source visible after cache flush; removing source=" .. tostring(sourcePath))
		log_dir_listing("Install source still visible after move", sourcePath .. "/")
		remove_directory_if_possible(sourcePath .. "/")
		flush_dir_cache("/Songs/")
		flush_dir_cache(quarantinePath)
		flush_dir_cache(sourcePath)
		flush_dir_cache(rootGroupPath)
	end

	log_dir_listing("Installed root group", rootGroupPath .. "/")
	remove_directory_if_possible(quarantinePath)
	flush_dir_cache("/Songs/")
	flush_dir_cache(quarantinePath)
	log_dir_listing("Remaining quarantine after cleanup", quarantinePath)
	trace("Install extracted pack complete target=" .. tostring(rootGroupPath)
		.. " quarantineExistsAfterCleanup=" .. tostring(path_exists(quarantinePath) or path_exists(quarantinePath .. "/")))
	return rootGroupPath .. "/", nil
end

function PackSync:SearchStepManiaOnline(songInfo, callback)
	trace("SearchStepManiaOnline begin title=" .. tostring(selected_title(songInfo))
		.. " artist=" .. tostring(selected_artist(songInfo))
		.. " pack=" .. tostring(selected_pack(songInfo))
		.. " chartHash=" .. tostring(selected_chart_hash(songInfo)):sub(1, 12))
	local origin = stepmaniaonline_origin()
	local function search(queryType, query, cb)
		local encoded = ""
		if NETWORK and NETWORK.EncodeQueryParameters then
			local ok, result = pcall(function()
				return NETWORK:EncodeQueryParameters({ type = queryType, query = query })
			end)
			encoded = ok and tostring(result or "") or ""
		end
		if encoded == "" then
			encoded = "type=" .. path_escape(queryType) .. "&query=" .. path_escape(query)
		end
		trace("SMO search begin type=" .. tostring(queryType)
			.. " query=" .. tostring(query)
			.. " origin=" .. tostring(origin))
		request_json(origin .. "/api/search/?" .. encoded, cb)
	end

	local pack = selected_pack(songInfo)
	local title = selected_title(songInfo)
	local artist = lower(selected_artist(songInfo))
	local chartKey = selected_chart_key(songInfo)
	trace("SearchStepManiaOnline begin pack=" .. tostring(pack)
		.. " title=" .. tostring(title)
		.. " artist=" .. tostring(artist)
			.. " chartKey=" .. tostring(chartKey)
			.. " selected_at=" .. tostring(selected_at(songInfo)))

	local function pack_result_has_title(packResult)
		if title == "" then return true end
		if type(packResult) ~= "table" or type(packResult.matching_songs) ~= "table" then return false end
		for songTitle in ivalues(packResult.matching_songs) do
			if lower(songTitle) == lower(title) then
				return true
			end
		end
		return false
	end

	local function choose_chart_key_pack(chartDecoded)
		local commonPacks = chartDecoded and chartDecoded.common_packs or {}
		if pack ~= "" then
			for packResult in ivalues(commonPacks) do
				if lower(packResult.name) == lower(pack) then
					return packResult
				end
			end
		end
		return #commonPacks == 1 and commonPacks[1] or nil
	end

	local function choose(results)
		local candidates = {}
		for packResult in ivalues(results or {}) do
			local name = trim(packResult.name)
			local packExact = pack ~= "" and lower(name) == lower(pack)
			local titleMatches = pack_result_has_title(packResult)
			if (packExact and titleMatches) or (title ~= "" and titleMatches) then
				candidates[#candidates + 1] = packResult
			end
		end
		return candidates
	end

	local function finish_with_results(decoded)
		local candidates = choose(decoded and decoded.results or {})
		trace("SMO finish_with_results raw=" .. tostring(decoded and decoded.results and #decoded.results or 0)
			.. " filtered=" .. tostring(#candidates)
			.. " pack=" .. tostring(pack)
			.. " title=" .. tostring(title))
		if #candidates == 1 then
			callback(true, candidates[1])
			return
		end
		local payload = {}
		for _, candidate in ipairs(candidates) do
			local built = build_pack_candidate(candidate, "title")
			if built then payload[#payload + 1] = built end
		end
		callback(false, nil, {
			errorMessage = #payload == 0 and "Aucun pack StepManiaOnline ne correspond." or "La recherche StepManiaOnline est ambigue.",
			candidates = dedupe_candidates(payload),
		})
	end

	local function finish_title_results(decoded)
		decoded = decoded or { results = {} }
		if artist == "" then
			finish_with_results(decoded)
			return
		end

		search("artist", artist, function(artistOk, artistDecoded)
			trace("SMO artist filter result ok=" .. tostring(artistOk == true)
				.. " results=" .. tostring(artistDecoded and artistDecoded.results and #artistDecoded.results or 0)
				.. " artist=" .. tostring(artist))
			if not artistOk then
				callback(false, nil, { errorMessage = pack_text("CatalogArtistSearchFailed", "The StepManiaOnline artist search failed.") })
				return
			end

			local artistPackIds = {}
			for packResult in ivalues(artistDecoded and artistDecoded.results or {}) do
				artistPackIds[tostring(packResult.id or "")] = true
			end

			local filtered = {}
			for packResult in ivalues(decoded and decoded.results or {}) do
				if artistPackIds[tostring(packResult.id or "")] then
					filtered[#filtered + 1] = packResult
				end
			end
			decoded.results = filtered
			finish_with_results(decoded)
		end)
	end

	if chartKey ~= "" then
		local completed = false
		local chartLookupDone = false
		local catalogLookupDone = false
		local catalogResult = nil
		local function finish_once(ok, result, details, source)
			if completed then
				trace("SMO parallel lookup ignored late result source=" .. tostring(source or "unknown")
					.. " ok=" .. tostring(ok == true))
				return false
			end
			completed = true
			trace("SMO parallel lookup resolved source=" .. tostring(source or "unknown")
				.. " ok=" .. tostring(ok == true)
				.. " candidates=" .. tostring(details and details.candidates and #details.candidates or 0))
			callback(ok, result, details)
			return true
		end
		local function finish_catalog_if_available()
			if not catalogLookupDone or not catalogResult then return false end
			return finish_once(
				catalogResult.ok,
				catalogResult.result,
				catalogResult.details,
				"catalog_after_chart")
		end

		-- A missing chart-key endpoint used to delay the catalog search by a
		-- complete network round trip.  Both lookups are independent and either
		-- may safely produce the exact pack or a bounded user choice.
		self:SearchStepManiaOnline({
			title = title,
			artist = artist,
			pack = pack,
			songPath = selected_path(songInfo),
		}, function(ok, result, details)
			catalogLookupDone = true
			catalogResult = { ok = ok, result = result, details = details }
			local hasCandidates = type(details) == "table"
				and type(details.candidates) == "table"
				and #details.candidates > 0
			trace("SMO parallel catalog result ok=" .. tostring(ok == true)
				.. " candidates=" .. tostring(hasCandidates and #details.candidates or 0)
				.. " chartLookupDone=" .. tostring(chartLookupDone))
			if ok or hasCandidates or chartLookupDone then
				finish_once(ok, result, details, "catalog")
			end
		end)

		trace("SMO chart_key lookup begin chartKey=" .. tostring(chartKey))
		request_json(origin .. "/api/chart/key/" .. path_escape(chartKey), function(ok, chartDecoded)
			chartLookupDone = true
			trace("SMO chart_key lookup result ok=" .. tostring(ok == true)
				.. " commonPacks=" .. tostring(chartDecoded and chartDecoded.common_packs and #chartDecoded.common_packs or 0)
				.. " chartKey=" .. tostring(chartKey))
			if ok and chartDecoded then
				local chartPack = choose_chart_key_pack(chartDecoded)
				if chartPack and chartPack.id then
					finish_once(true, chartPack, nil, "chart_key_exact")
					return
				end
					local commonPacks = chartDecoded.common_packs or {}
					if #commonPacks > 1 and pack == "" then
						local payload = {}
						for _, candidate in ipairs(commonPacks) do
							local built = build_pack_candidate(candidate, "chart_key")
							if built then payload[#payload + 1] = built end
						end
						finish_once(false, nil, {
							errorMessage = pack_text("CatalogChartMatchesMultiplePacks", "The StepManiaOnline chart matches several packs."),
							candidates = dedupe_candidates(payload),
						}, "chart_key_candidates")
						return
					end
					finish_catalog_if_available()
				return
			end
			finish_catalog_if_available()
		end, { expected404 = true })
	elseif pack ~= "" then
		search("pack", pack, function(ok, decoded)
			trace("SMO pack search result ok=" .. tostring(ok == true)
				.. " results=" .. tostring(decoded and decoded.results and #decoded.results or 0)
				.. " pack=" .. tostring(pack))
			if not ok then
				-- Pack endpoint unavailable: fall back once to title-based search.
				if title ~= "" then
					search("title", title, function(titleOk, titleDecoded)
						trace("SMO title fallback after pack result ok=" .. tostring(titleOk == true)
							.. " results=" .. tostring(titleDecoded and titleDecoded.results and #titleDecoded.results or 0)
							.. " title=" .. tostring(title))
						if not titleOk then
							callback(false, nil, { errorMessage = pack_text("CatalogPackAndTitleSearchFailed", "The StepManiaOnline pack and title searches failed.") })
							return
						end
						finish_title_results(titleDecoded)
					end)
				else
					callback(false, nil, { errorMessage = pack_text("CatalogPackSearchFailed", "The StepManiaOnline pack search failed.") })
				end
				return
			end

			local packCandidatesPayload = {}
			if decoded and type(decoded.results) == "table" then
				for packResult in ivalues(decoded.results) do
					local built = build_pack_candidate(packResult, "pack")
					if built then packCandidatesPayload[#packCandidatesPayload + 1] = built end
				end
				packCandidatesPayload = dedupe_candidates(packCandidatesPayload)
			end

				local exactPackMatches = {}
				if decoded and type(decoded.results) == "table" then
					for packResult in ivalues(decoded.results) do
						if lower(trim(packResult.name)) == lower(pack) and pack_result_has_title(packResult) then
							exactPackMatches[#exactPackMatches + 1] = packResult
						end
					end
				end
				if #exactPackMatches == 1 then
				callback(true, exactPackMatches[1])
				return
			end
				if #packCandidatesPayload == 1 then
					callback(false, nil, {
						errorMessage = pack_text("CatalogPackNeedsConfirmation", "The StepManiaOnline pack search must be confirmed by title or chart."),
						candidates = packCandidatesPayload,
					})
					return
				elseif #packCandidatesPayload > 1 then
					callback(false, nil, {
					errorMessage = pack_text("CatalogPackMatchesMultiplePacks", "The StepManiaOnline pack search matches several packs."),
					candidates = packCandidatesPayload,
				})
				return
			end
			if title == "" then finish_with_results(decoded); return end
			search("title", title, function(titleOk, titleDecoded)
				trace("SMO title refinement result ok=" .. tostring(titleOk == true)
					.. " results=" .. tostring(titleDecoded and titleDecoded.results and #titleDecoded.results or 0)
					.. " title=" .. tostring(title))
					if not titleOk then
						if title == "" and #exactPackMatches == 1 then
							callback(true, exactPackMatches[1])
						elseif #packCandidatesPayload > 0 then
							callback(false, nil, {
								errorMessage = pack_text("CatalogTitleSearchFailed", "The StepManiaOnline title search failed."),
								candidates = packCandidatesPayload,
						})
					else
						callback(false, nil, { errorMessage = pack_text("CatalogTitleSearchFailed", "The StepManiaOnline title search failed.") })
					end
					return
				end
				finish_title_results(titleDecoded)
			end)
		end)
	elseif title ~= "" then
		search("title", title, function(ok, decoded)
			trace("SMO title search result ok=" .. tostring(ok == true)
				.. " results=" .. tostring(decoded and decoded.results and #decoded.results or 0)
				.. " title=" .. tostring(title))
			if not ok then callback(false, nil, { errorMessage = pack_text("CatalogTitleSearchFailed", "The StepManiaOnline title search failed.") }); return end
			finish_title_results(decoded)
		end)
	else
		trace("SearchStepManiaOnline failed reason=no_pack_no_title")
		callback(false, nil, { errorMessage = pack_text("CatalogSearchMissingTerms", "No pack or title is available for the StepManiaOnline search.") })
	end
end

function PackSync:DownloadPackByCandidate(songInfo, pack, callback, options)
	songInfo = with_current_room_selection(songInfo, "download_candidate")
	trace_online_state("download_candidate_begin", {
		selected_at = selected_at(songInfo),
		packId = pack and pack.id or "nil",
		packName = pack and (pack.name or pack.title) or "",
		title = selected_title(songInfo),
		browseOnly = options and options.browseOnly == true,
		generation = self.downloadGeneration or "nil",
		downloadKey = self.downloadInFlightKey or "",
		activeDownloadId = self.activeDownloadId or "",
	})
	trace("DownloadPackByCandidate begin packId=" .. tostring(pack and pack.id or "nil")
		.. " packName=" .. tostring(pack and (pack.name or pack.title) or "")
		.. " songTitle=" .. tostring(selected_title(songInfo))
		.. " selected_at=" .. tostring(selected_at(songInfo))
		.. " roomSelectedAt=" .. tostring(current_room_selected_at())
		.. " browseOnly=" .. tostring(options and options.browseOnly == true)
		.. " generation=" .. tostring(self.downloadGeneration or "nil")
		.. " activeDownloadId=" .. tostring(self.activeDownloadId or "")
		.. " existingDownloadKey=" .. tostring(self.downloadInFlightKey or "")
		.. " room=" .. tostring(ITGOnline and ITGOnline.currentRoomId or "nil")
		.. " phase=" .. tostring(ITGOnline and ITGOnline.currentRoom and ITGOnline.currentRoom.phase or "nil"))
		if not pack or not pack.id then
			trace("DownloadPackByCandidate blocked reason=invalid_candidate"
				.. " hasPack=" .. tostring(pack ~= nil)
				.. " packId=" .. tostring(pack and pack.id or "nil")
				.. " title=" .. tostring(selected_title(songInfo))
				.. " selected_at=" .. tostring(selected_at(songInfo)))
			if callback then callback(false, pack_text("InvalidPackCandidate", "Invalid pack candidate.")) end
			return
		end
		local trustedCatalogCandidate = pack.trusted_catalog_candidate == true
		if not trustedCatalogCandidate then
			trace("DownloadPackByCandidate blocked reason=untrusted_source packId=" .. tostring(pack.id))
			if callback then callback(false, pack_text("PackSourceNotAllowed", "The pack source is not allowed.")) end
			return
		end
		if not (NETWORK and NETWORK.HttpRequest) then
			trace("DownloadPackByCandidate blocked reason=network_unavailable")
			if callback then callback(false, pack_text("EngineNetworkUnavailable", "The engine network service is unavailable.")) end
			return
		end
			if not (FILEMAN and FILEMAN.DoesFileExist and NETWORK.ProcessPackArchive) then
			trace("DownloadPackByCandidate blocked reason=fileman_unavailable")
			if callback then callback(false, pack_text("EngineFileManagerUnavailable", "The engine file manager is unavailable.")) end
			return
		end
		if not current_user_is_active_room_member() then
		trace("DownloadPackByCandidate blocked reason=not_active_room_member"
			.. " packId=" .. tostring(pack and pack.id or "nil")
			.. " packName=" .. tostring(pack and pack.name or "nil")
			.. " room=" .. tostring(ITGOnline and ITGOnline.currentRoomId or "nil")
			.. " hasRoom=" .. tostring(ITGOnline and ITGOnline.currentRoom ~= nil)
			.. " hasUser=" .. tostring(ITGOnline and ITGOnline.user ~= nil))
		if callback then callback(false, pack_text("NoLongerInLobby", "You are no longer in the lobby.")) end
		return
	end
	options = type(options) == "table" and options or {}
	local browseOnly = options.browseOnly == true
	local existingDownloadKey = trim(self.downloadInFlightKey)
	local expectedDownloadKey = trim(options.allowExistingDownloadKey)
	if existingDownloadKey ~= "" and (expectedDownloadKey == "" or existingDownloadKey ~= expectedDownloadKey) then
		local message = download_already_in_progress_message()
		trace(message .. " key=" .. tostring(existingDownloadKey)
			.. " expectedKey=" .. tostring(expectedDownloadKey)
			.. " requestedPackId=" .. tostring(pack and pack.id or "nil")
			.. " browseOnly=" .. tostring(browseOnly == true))
		trace_online_state("download_candidate_blocked_existing_download", {
			selected_at = selected_at(songInfo),
			packId = pack and pack.id or "nil",
			packName = pack and (pack.name or pack.title) or "",
			existingDownloadKey = existingDownloadKey,
			expectedDownloadKey = expectedDownloadKey,
			browseOnly = browseOnly == true,
			activeDownloadId = self.activeDownloadId or "",
		})
		if callback then callback(false, message) end
		return
	end

	local packId = canonical_id(pack.id)
	if not packId or packId == "0" then
		trace("DownloadPackByCandidate blocked reason=invalid_pack_id raw=" .. tostring(pack.id)
			.. " packName=" .. tostring(pack.name or "nil"))
		if callback then callback(false, pack_text("InvalidCatalogPackId", "StepManiaOnline returned an invalid pack identifier.")) end
		return
	end

	local packName = trim(pack.name or ("Pack " .. tostring(packId)))
	-- StepManiaOnline currently does not publish this field. Keep the value in
	-- the enclosing function scope so response callbacks can safely distinguish
	-- "integrity unavailable" from an actual manifest mismatch.
	local expectedArchiveHash = ""
	local url = tostring(pack.download_url or "")
	if trustedCatalogCandidate then
		local expectedCatalogUrl = stepmaniaonline_origin() .. "/download/pack/" .. tostring(packId) .. "/"
		if url ~= expectedCatalogUrl then
			trace("DownloadPackByCandidate blocked reason=invalid_catalog_url packId=" .. tostring(packId)
				.. " url=" .. tostring(url))
			if callback then callback(false, pack_text("InvalidCatalogPackUrl", "The StepManiaOnline pack URL is invalid.")) end
			return
		end
		expectedArchiveHash = tostring(pack.archive_sha256 or ""):lower()
		if expectedArchiveHash ~= "" and (#expectedArchiveHash ~= 64 or not expectedArchiveHash:match("^[a-f0-9]+$")) then
			trace("DownloadPackByCandidate blocked reason=invalid_catalog_archive_hash packId="
				.. tostring(pack.id))
			if callback then callback(false, pack_text("InvalidCatalogManifest", "The catalog pack manifest is invalid.")) end
			return
		end
	end
	if existingDownloadKey == "" then
		self.downloadInFlightKey = (browseOnly and "browse-candidate|" or "selected-candidate|") .. tostring(packId) .. "|" .. packName
	end
		local downloadGeneration = tonumber(options.downloadGeneration)
			or self:NextDownloadGeneration(browseOnly and "browse_candidate_start" or "selected_candidate_start")
			local fileName = "itg-online-" .. tostring(packId) .. "_" .. safe_file_name(packName)
			local zipPath = "/Downloads/" .. fileName
			local quarantinePath = pack_quarantine_path(packId, packName)
		local maxDownloadBytes = tonumber(self.maxDownloadBytes) or (5 * 1024 * 1024 * 1024)
		local defaultMaxDownloadBytes = 5 * 1024 * 1024 * 1024
		local maximumDownloadBytes = 5 * 1024 * 1024 * 1024
		if maxDownloadBytes < (16 * 1024 * 1024) or maxDownloadBytes > maximumDownloadBytes then
			trace("Download max bytes clamped raw=" .. tostring(self.maxDownloadBytes)
				.. " effective=" .. tostring(defaultMaxDownloadBytes))
			maxDownloadBytes = defaultMaxDownloadBytes
		end
		local initialFreeBytes = disk_free_bytes("/Downloads/")
		local minimumFreeBytes = tonumber(self.minimumDownloadFreeBytes) or (256 * 1024 * 1024)
		if initialFreeBytes and initialFreeBytes < minimumFreeBytes then
			trace("Download blocked reason=insufficient_disk_space free=" .. tostring(initialFreeBytes)
				.. " required=" .. tostring(minimumFreeBytes)
				.. " pack=" .. tostring(packName))
			self.downloadInFlightKey = nil
			self:ClearActiveDownloadId("download_disk_preflight_failed")
			if callback then callback(false, pack_text("InsufficientDiskDownload", "Not enough disk space to download this pack.")) end
			return
		end

		if url == "" then
			if callback then callback(false, pack_text("MissingSecureDownloadUrl", "The server did not provide a secure download URL.")) end
			return
		end
	local downloadMessage = "Telechargement de " .. tostring(packName)
	trace("Download started pack=" .. tostring(packName) .. " id=" .. tostring(packId)
		.. " generation=" .. tostring(downloadGeneration)
		.. " browseOnly=" .. tostring(browseOnly == true)
		.. " key=" .. tostring(self.downloadInFlightKey or "")
		.. " room=" .. tostring(ITGOnline and ITGOnline.currentRoomId or "nil")
		.. " phase=" .. tostring(ITGOnline and ITGOnline.currentRoom and ITGOnline.currentRoom.phase or "nil"))
	trace_online_state("download_security_limits", {
		selected_at = selected_at(songInfo),
		packId = packId,
		maxDownloadBytes = maxDownloadBytes,
		maxArchiveUncompressedBytes = tonumber(self.maxArchiveUncompressedBytes) or 0,
		extractionReserveBytes = tonumber(self.extractionReserveBytes) or 0,
		diskSafetyMarginBytes = tonumber(self.diskSafetyMarginBytes) or 0,
		archiveIntegrity = expectedArchiveHash ~= "" and "sha256_catalog" or "publisher_signature_unavailable",
	})
	trace_online_state("download_started", {
		selected_at = selected_at(songInfo),
		packId = packId,
		packName = packName,
		browseOnly = browseOnly == true,
		generation = downloadGeneration,
		downloadKey = self.downloadInFlightKey or "",
		activeDownloadId = self.activeDownloadId or "",
	})
	self.currentSongInfo = songInfo or self.currentSongInfo
	-- Candidate downloads can be started after the choice overlay has cleared its
	-- transient state. Persist the mode on PackSync before any room refresh can
	-- decide whether a no-selection reset should cancel the transfer.
	self.activeBrowseOnlyDownload = browseOnly
	self:UpdateStatus(self.status.DownloadInProgress, downloadMessage, 0)
	self.lastProgressStatusAt = 0
	self.lastProgressValue = -10
	self.lastProgressBucket = -1
	local downloadCompleted = false
	local diskCapacityChecked = false

	local function fail_candidate_download(message, broadcastMissing)
		if not self:IsDownloadGenerationCurrent(downloadGeneration) then
			trace("Download failure ignored reason=stale_generation pack=" .. tostring(packName)
				.. " generation=" .. tostring(downloadGeneration)
				.. " current=" .. tostring(self.downloadGeneration))
			return
		end
		if downloadCompleted then return end
		downloadCompleted = true
		message = message or pack_text("PackDownloadFailed", "Pack download failed.")
		trace("Download failed pack=" .. tostring(packName)
			.. " id=" .. tostring(packId)
			.. " generation=" .. tostring(downloadGeneration)
			.. " message=" .. tostring(message)
			.. " broadcastMissing=" .. tostring(broadcastMissing ~= false)
			.. " room=" .. tostring(ITGOnline and ITGOnline.currentRoomId or "nil"))
		trace_online_state("download_failed", {
			selected_at = selected_at(songInfo),
			packId = packId,
			packName = packName,
			generation = downloadGeneration,
			currentGeneration = self.downloadGeneration or "nil",
			downloadKey = self.downloadInFlightKey or "",
			activeDownloadId = self.activeDownloadId or "",
			message = message,
			broadcastMissing = broadcastMissing ~= false,
		})
		self.downloadInFlightKey = nil
		self.downloadStartedAt = nil
			self.downloadLastByteAt = nil
			self.downloadLastByteCount = nil
			self.pendingPostReloadCallback = nil
			self:ClearActiveDownloadId("candidate_download_failed")
			self:UpdateStatus(self.status.DownloadFailed, message)
			-- Keep the browse-only marker through UpdateStatus so this terminal
			-- state stays local as well; clear it only once the local UI has seen it.
			if browseOnly then self.activeBrowseOnlyDownload = false end
		remove_path_if_exists(zipPath)
		remove_directory_if_possible(quarantinePath)
		if not browseOnly and broadcastMissing ~= false and MESSAGEMAN and self:SongInfoMatchesCurrentSelection(songInfo) then
			MESSAGEMAN:Broadcast("OnlineMissingSong", {
				songInfo = songInfo,
				reason = "download_failed",
				-- The archive never reached the chart-verification step. Keep the
				-- selected candidate available for a retry instead of treating it as
				-- an incompatible pack.
				downloadAttemptFailed = true,
				message = message,
			})
		elseif not browseOnly and broadcastMissing ~= false then
			trace("Download failure missing broadcast skipped reason=stale_or_no_active_selection"
				.. " pack=" .. tostring(packName)
				.. " selectedAt=" .. tostring(selected_at(songInfo))
				.. " roomSelectedAt=" .. tostring(current_room_selected_at()))
		end
		if callback then callback(false, message) end
	end

	local function finish_candidate_download()
		if not self:IsDownloadGenerationCurrent(downloadGeneration) then
			trace("Download finish ignored reason=stale_generation pack=" .. tostring(packName)
				.. " generation=" .. tostring(downloadGeneration)
				.. " current=" .. tostring(self.downloadGeneration))
			return false
		end
		if downloadCompleted then return false end
		downloadCompleted = true
		trace("Download finished pack=" .. tostring(packName)
			.. " id=" .. tostring(packId)
			.. " generation=" .. tostring(downloadGeneration)
			.. " browseOnly=" .. tostring(browseOnly == true)
			.. " room=" .. tostring(ITGOnline and ITGOnline.currentRoomId or "nil"))
		trace_online_state("download_finished", {
			selected_at = selected_at(songInfo),
			packId = packId,
			packName = packName,
			browseOnly = browseOnly == true,
			generation = downloadGeneration,
			downloadKey = self.downloadInFlightKey or "",
			activeDownloadId = self.activeDownloadId or "",
		})
		return true
	end

	local function guarded_download_callback(stage, callbackFn, response)
		local ok, result = xpcall(callbackFn, function(callbackError)
			if debug and debug.traceback then
				return debug.traceback(tostring(callbackError), 2)
			end
			return tostring(callbackError)
		end)
		if ok then return true, result end

		trace("Download callback exception stage=" .. tostring(stage)
			.. " pack=" .. tostring(packName)
			.. " id=" .. tostring(packId)
			.. " generation=" .. tostring(downloadGeneration)
			.. " error=" .. tostring(result))
		trace_online_state("download_callback_exception", {
			selected_at = selected_at(songInfo),
			packId = packId,
			packName = packName,
			stage = stage,
			generation = downloadGeneration,
			activeDownloadId = self.activeDownloadId or "",
			statusCode = response and response.statusCode or "",
			error = tostring(result),
		})
		fail_candidate_download(pack_text("PackDownloadInternalError", "The download encountered an internal error. Try the pack again."))
		return false
	end

	local okRequest, requestError = pcall(function()
		return NETWORK:HttpRequest({
			url = url,
			method = "GET",
			headers = pack.headers or {},
			downloadFile = fileName,
			connectTimeout = 15,
			transferTimeout = 600,
			maxDownloadBytes = maxDownloadBytes,
			-- Older engine builds can still apply this cap even for file downloads.
			-- Newer builds stream with maxDownloadBytes instead.
			maxResponseBytes = maxDownloadBytes,
			-- Keep the zip until we explicitly unzip/cleanup it. If removed too early,
			-- the post-download check will falsely report "file missing".
			deleteDownloadAfterResponse = false,
			onFileError = function(errorMessage)
				return guarded_download_callback("file_error", function()
				if not self:IsDownloadGenerationCurrent(downloadGeneration) then return end
				if downloadCompleted then return end
				trace("Download file error pack=" .. tostring(packName) .. " err=" .. tostring(errorMessage))
				local normalizedError = tostring(errorMessage or "unknown error")
				if normalizedError:lower():find("maximum allowed size", 1, true) then
					fail_candidate_download(pack_text("PackTooLarge", "The pack exceeds the 5 GiB download limit."))
					return
				end
				fail_candidate_download(pack_text("DownloadWriteError", "Could not write the downloaded file: %s", normalizedError))
				end)
			end,
			onProgress = function(current, total)
				local callbackOk, callbackResult = guarded_download_callback("progress", function()
				if not self:IsDownloadGenerationCurrent(downloadGeneration) then return false end
					if downloadCompleted then return false end
					if not current_user_is_active_room_member() then
						trace("Download aborted reason=not_active_room_member pack=" .. tostring(packName))
						fail_candidate_download(pack_text("NoLongerInLobby", "You are no longer in the lobby."), false)
						return false
					end
					local now = GetTimeSinceStart and GetTimeSinceStart() or 0
					if self.downloadStartedAt == nil then
						self.downloadStartedAt = now
						self.downloadLastByteAt = now
						self.downloadLastByteCount = tonumber(current) or 0
					end

					local currentBytes = tonumber(current) or 0
					local totalBytes = tonumber(total) or 0
					if not diskCapacityChecked and totalBytes > 0 then
						local freeBytes = disk_free_bytes("/Downloads/")
						local remainingBytes = math.max(0, totalBytes - currentBytes)
						local extractionReserve = tonumber(self.extractionReserveBytes) or (5 * 1024 * 1024 * 1024)
						local safetyMargin = tonumber(self.diskSafetyMarginBytes) or (256 * 1024 * 1024)
						local requiredBytes = remainingBytes + extractionReserve + safetyMargin
						if freeBytes and freeBytes < requiredBytes then
							trace("Download aborted reason=insufficient_disk_capacity free=" .. tostring(freeBytes)
								.. " required=" .. tostring(requiredBytes)
								.. " total=" .. tostring(totalBytes)
								.. " current=" .. tostring(currentBytes)
								.. " pack=" .. tostring(packName))
							fail_candidate_download(pack_text("InsufficientDiskDownloadExtract", "Not enough disk space to download and extract this pack."))
							return false
						end
						diskCapacityChecked = true
					end
					if currentBytes > (tonumber(self.downloadLastByteCount) or 0) then
						self.downloadLastByteCount = currentBytes
						self.downloadLastByteAt = now
					end
					if now - (tonumber(self.downloadLastByteAt) or now) >= 45 then
						trace("Download stalled for 45s, aborting pack=" .. tostring(packName))
						fail_candidate_download(pack_text("PackDownloadStalled", "The pack download has not progressed for 45 seconds."))
						return false
					end

					if tonumber(total) and tonumber(total) > 0 then
						local rawProgress = math.max(0, math.min(100, math.floor((tonumber(current) or 0) * 100 / tonumber(total))))
						local displayProgress = math.min(99, rawProgress)
						-- Send coarse progress updates only (0/20/40/60/80/99) to avoid
						-- saturating the network callback queue during fast downloads.
						local bucket = (displayProgress >= 99) and 99 or (math.floor(displayProgress / 20) * 20)
						if bucket ~= tonumber(self.lastProgressBucket) then
							self.lastProgressBucket = bucket
							self.lastProgressValue = displayProgress
							self.lastProgressStatusAt = now
							self:UpdateStatus(self.status.DownloadInProgress, downloadMessage, bucket)
						end
					end
					return true
				end)
				return callbackOk and callbackResult ~= false
			end,
			onResponse = function(response)
				guarded_download_callback("response", function()
			trace("Download response pack=" .. tostring(packName)
				.. " id=" .. tostring(packId)
				.. " generation=" .. tostring(downloadGeneration)
				.. " statusCode=" .. tostring(response and response.statusCode or "nil")
				.. " completed=" .. tostring(downloadCompleted == true)
				.. " currentGeneration=" .. tostring(self.downloadGeneration))
			if not self:IsDownloadGenerationCurrent(downloadGeneration) then
					remove_path_if_exists(zipPath)
					trace("Download response ignored reason=stale_generation pack=" .. tostring(packName)
					.. " generation=" .. tostring(downloadGeneration)
					.. " current=" .. tostring(self.downloadGeneration))
				return
			end
			if downloadCompleted then return end
			if not current_user_is_active_room_member() then
				trace("Download response ignored reason=not_active_room_member pack=" .. tostring(packName))
				fail_candidate_download(pack_text("NoLongerInLobby", "You are no longer in the lobby."), false)
				return
			end
			self.downloadStartedAt = nil
			self.downloadLastByteAt = nil
			self.downloadLastByteCount = nil
			local transportError = trim(response and response.errorMessage or "")
			if transportError ~= "" then
				trace("Download failed transport_error pack=" .. tostring(packName)
					.. " error=" .. tostring(transportError))
				if transportError:lower():find("response body exceeded maximum allowed size", 1, true) then
					fail_candidate_download(pack_text("LegacyDownloadLimit", "This game build still limits downloads to 8 MiB. Rebuild the current version before trying again."))
					return
				end
				fail_candidate_download(pack_text("DownloadTransportError", "Download failed: %s", transportError))
				return
			end
				local statusCode = tonumber(response and response.statusCode) or 0
				trace_online_state("download_response_received", {
					selected_at = selected_at(songInfo),
					packId = packId,
					packName = packName,
					generation = downloadGeneration,
					activeDownloadId = self.activeDownloadId or "",
					statusCode = statusCode,
					browseOnly = browseOnly == true,
				})
				if statusCode < 200 or statusCode >= 300 then
				local message = pack_text("PackDownloadFailed", "Pack download failed.")
				trace("Download failed status=" .. tostring(statusCode))
				fail_candidate_download(message)
				return
			end
				-- The bytes are complete, but the archive is not usable yet. Make the
				-- post-transfer phase explicit instead of leaving a misleading 100%.
				self:UpdateStatus(self.status.DownloadInProgress, pack_text("VerifyingPack", "Verifying pack"), 100)

			if not FILEMAN:DoesFileExist(zipPath) then
				trace("Download failed missing zip pack=" .. tostring(packName)
					.. " zipPath=" .. tostring(zipPath)
					.. " fileName=" .. tostring(fileName))
				fail_candidate_download(pack_text("DownloadedFileMissing", "The downloaded file could not be found."))
				return
			end
				self:UpdateStatus(self.status.DownloadInProgress, pack_text("InstallingPack", "Installing pack"), 100)
				local extractionFreeBytes = disk_free_bytes("/Songs/")
				local extractionRequiredBytes = (tonumber(self.extractionReserveBytes) or (5 * 1024 * 1024 * 1024))
					+ (tonumber(self.diskSafetyMarginBytes) or (256 * 1024 * 1024))
				if extractionFreeBytes and extractionFreeBytes < extractionRequiredBytes then
					trace("Download extraction blocked reason=insufficient_disk_space free="
						.. tostring(extractionFreeBytes) .. " required=" .. tostring(extractionRequiredBytes)
						.. " pack=" .. tostring(packName))
					fail_candidate_download(pack_text("InsufficientDiskExtract", "Not enough disk space to extract this pack."))
					return
				end
				remove_directory_if_possible(quarantinePath)
				create_directory_if_possible(quarantinePath)
				trace("Download archive worker begin pack=" .. tostring(packName)
					.. " generation=" .. tostring(downloadGeneration))

				local archiveQueued, archiveFuture = pcall(function()
					return NETWORK:ProcessPackArchive({
						archivePath = zipPath,
						targetPath = quarantinePath,
						expectedSha256 = expectedArchiveHash,
						onComplete = function(result)
							guarded_download_callback("archive_process", function()
								self.downloadFuture = nil
								if not self:IsDownloadGenerationCurrent(downloadGeneration) then
									remove_path_if_exists(zipPath)
									remove_directory_if_possible(quarantinePath)
									trace("Archive result ignored reason=stale_generation pack=" .. tostring(packName))
									return
								end

								result = type(result) == "table" and result or {}
								local archiveHash = trim(result.sha256 or ""):lower()
								if result.ok ~= true then
									local errorCode = trim(result.errorCode or "archive_processing_failed")
									remove_path_if_exists(zipPath)
									remove_directory_if_possible(quarantinePath)
									trace("Download archive worker failed pack=" .. tostring(packName)
										.. " errorCode=" .. tostring(errorCode))
									local message = pack_text("InvalidPackArchive", "The downloaded archive is invalid or cannot be extracted.")
									if errorCode == "hash_unavailable" then
										message = pack_text("CatalogIntegrityUnavailable", "Could not verify the catalog pack integrity.")
									elseif errorCode == "hash_mismatch" then
										message = pack_text("CatalogHashMismatch", "The catalog pack SHA-256 does not match the manifest.")
									elseif errorCode == "engine_unavailable" then
										message = pack_text("EngineFileManagerUnavailable", "The engine file manager is unavailable.")
									elseif errorCode == "cancelled" then
										message = pack_text("PackInstallationCancelled", "Pack installation was cancelled.")
									end
									fail_candidate_download(message)
									return
								end

								trace_online_state("download_archive_verified", {
									selected_at = selected_at(songInfo), packId = packId, packName = packName,
									generation = downloadGeneration, activeDownloadId = self.activeDownloadId or "",
									hashProvided = expectedArchiveHash ~= "",
									hashVerified = expectedArchiveHash ~= "" and archiveHash ~= "",
									archiveHashPrefix = archiveHash:sub(1, 12),
								})
								flush_dir_cache("/Songs/")
								flush_dir_cache(quarantinePath)
								log_dir_listing("Extracted quarantine", quarantinePath)
								trace_online_state("download_archive_extracted", {
									selected_at = selected_at(songInfo), packId = packId, packName = packName,
									generation = downloadGeneration, activeDownloadId = self.activeDownloadId or "",
								})

								local installedPath, installError = install_extracted_pack_at_songs_root(quarantinePath, packName)
								if not installedPath then
									remove_path_if_exists(zipPath)
									remove_directory_if_possible(quarantinePath)
									fail_candidate_download(installError
										or pack_text("PackInstallFailed", "Could not install the downloaded pack."))
									return
								end
								remove_path_if_exists(zipPath)
								trace_online_state("download_pack_installed", {
									selected_at = selected_at(songInfo), packId = packId, packName = packName,
									generation = downloadGeneration, activeDownloadId = self.activeDownloadId or "",
								})

								self.pendingPostReloadSongInfo = songInfo
								self.pendingQuarantinePath = installedPath
								self.pendingPostReloadBrowseOnly = browseOnly
								self.pendingPostReloadCallback = callback
								self:UpdateStatus(self.status.ReloadingSongs,
									pack_text("ReloadingSongs", "Reloading songs"))
								trace_online_state("download_reload_requested", {
									selected_at = selected_at(songInfo), packId = packId, packName = packName,
									generation = downloadGeneration, activeDownloadId = self.activeDownloadId or "",
									browseOnly = browseOnly == true,
								})
								if not transition_to_reload_songs() then
									rollback_installed_pack_if_possible(installedPath)
									self.pendingPostReloadSongInfo = nil
									self.pendingQuarantinePath = nil
									self.pendingPostReloadBrowseOnly = false
									self.pendingPostReloadCallback = nil
									fail_candidate_download(pack_text("SongReloadFailed", "Song reload could not start."), false)
									return
								end
								finish_candidate_download()
							end)
						end,
					})
				end)
				if not archiveQueued or not archiveFuture then
					fail_candidate_download(pack_text("PackProcessingFailed", "Pack processing could not start: %s",
						tostring(archiveFuture or "worker unavailable")))
					return
				end
				self.downloadFuture = archiveFuture
				end, response)
			end,
		})
	end)
	if okRequest and requestOrError and requestOrError.Cancel then
		self.downloadFuture = requestOrError
	end
	-- Some engine builds enqueue an asynchronous HTTP request without returning
	-- a Lua future. `nil` is therefore not a submission failure; only a thrown
	-- request call is terminal here. Completion still arrives through callbacks.
	if not okRequest then
		fail_candidate_download(pack_text("DownloadRequestFailed", "The download request failed: %s",
			tostring(requestOrError or "unknown error")))
	end
end

function PackSync:DownloadSelectedPack(songInfo, callback)
	songInfo = with_current_room_selection(songInfo, "download_selected")
	if not songInfo then
		trace("DownloadSelectedPack blocked reason=no_song_info")
		if callback then callback(false, pack_text("NoSongSelected", "No song selected.")) end
		return
	end
	trace("DownloadSelectedPack begin title=" .. tostring(selected_title(songInfo))
		.. " pack=" .. tostring(selected_pack(songInfo))
		.. " selected_at=" .. tostring(selected_at(songInfo))
		.. " chart_hash=" .. tostring(selected_chart_hash(songInfo))
		.. " currentKey=" .. tostring(self.downloadInFlightKey or "")
		.. " room=" .. tostring(ITGOnline and ITGOnline.currentRoomId or "nil")
		.. " phase=" .. tostring(ITGOnline and ITGOnline.currentRoom and ITGOnline.currentRoom.phase or "nil"))
	if not current_user_is_active_room_member() then
		trace("DownloadSelectedPack blocked reason=not_active_room_member"
			.. " room=" .. tostring(ITGOnline and ITGOnline.currentRoomId or "nil")
			.. " hasRoom=" .. tostring(ITGOnline and ITGOnline.currentRoom ~= nil)
			.. " hasUser=" .. tostring(ITGOnline and ITGOnline.user ~= nil))
		if callback then callback(false, pack_text("NoLongerInLobby", "You are no longer in the lobby.")) end
		return
	end
	if trim(self.downloadInFlightKey) ~= "" then
		local message = download_already_in_progress_message()
		trace(message .. " key=" .. tostring(self.downloadInFlightKey)
			.. " requestedSelectedAt=" .. tostring(selected_at(songInfo))
			.. " requestedPack=" .. tostring(selected_pack(songInfo)))
		if callback then callback(false, message) end
		return
	end

	self.currentSongInfo = songInfo
	self.pendingPostReloadBrowseOnly = false
	local downloadKey = selected_at(songInfo)
	if downloadKey == "" then
		downloadKey = selected_chart_hash(songInfo) .. "|" .. selected_path(songInfo)
	end
	if downloadKey == "" then downloadKey = tostring(songInfo) end
	self.downloadInFlightKey = downloadKey
	local downloadGeneration = self:NextDownloadGeneration("download_selected_search")
	-- Keep the catalog search cancellable without announcing it as a download.
	-- Only DownloadPackByCandidate may pause the server-side missing-pack
	-- deadline, once an actual archive transfer has started.
	local function fail_download(message)
		if not self:IsDownloadGenerationCurrent(downloadGeneration) then
			trace("DownloadSelected failure ignored reason=stale_generation generation="
				.. tostring(downloadGeneration) .. " current=" .. tostring(self.downloadGeneration))
			return
		end
		self.downloadInFlightKey = nil
		self.downloadStartedAt = nil
		self.downloadLastByteAt = nil
		self.downloadLastByteCount = nil
		self:ClearActiveDownloadId("selected_download_failed")
		self:UpdateStatus(self.status.DownloadFailed, message)
		if callback then callback(false, message) end
	end

	trace("DownloadSelectedPack catalog lookup begin"
		.. " room=" .. tostring(ITGOnline and ITGOnline.currentRoomId or "nil")
		.. " selected_at=" .. tostring(selected_at(songInfo)))
	self:DownloadBrowsingPack(songInfo, function(catalogOk, catalogMessage)
		if not self:IsDownloadGenerationCurrent(downloadGeneration) then return end
		if catalogOk and type(catalogMessage) == "table" and catalogMessage.kind == "pack_candidates" then
			catalogMessage.downloadKey = downloadKey
			local candidates = catalogMessage.candidates or {}
			if #candidates == 1 then
				trace("DownloadSelectedPack catalog resolved a single candidate; starting transfer"
					.. " packId=" .. tostring(candidates[1] and candidates[1].id or "nil")
					.. " selected_at=" .. tostring(selected_at(songInfo)))
				self:DownloadPackByCandidate(songInfo, candidates[1], callback, {
					allowExistingDownloadKey = downloadKey,
					downloadGeneration = downloadGeneration,
				})
				return
			end

			-- The selection modal needs its own bounded grace period.  This status
			-- deliberately does not start a download, but the server rearms the
			-- missing-pack deadline once for this selection.
			self:UpdateStatus(self.status.AwaitingPackChoice,
				pack_text("ChoosePackWithinSeconds", "Choose the matching pack within %d seconds.", 30), nil,
				function(statusOk, _, statusResponse)
					if not statusOk then
						trace("DownloadSelectedPack candidate choice deadline rearm failed"
							.. " status=" .. tostring(statusResponse and statusResponse.statusCode or "nil")
							.. " error=" .. tostring(statusResponse and statusResponse.errorMessage or "unknown"))
						if callback then
							callback(false, pack_text("PackChoiceDeadlineResetFailed", "Could not reset the pack choice deadline. Try again."))
						end
						return
					end
					if callback then callback(true, catalogMessage) end
				end)
			return
		end
		fail_download(catalogMessage or pack_text("NoCompatibleCatalogPack", "No compatible catalog pack was found."))
	end)
end

function PackSync:DownloadBrowsingPack(songInfo, callback, options)
	songInfo = with_current_room_selection(songInfo, "download_browsing")
	options = type(options) == "table" and options or {}
	if not songInfo then
		trace("DownloadBrowsingPack blocked reason=no_song_info")
		if callback then callback(false, pack_text("NoPackToDownload", "No pack to download.")) end
		return
	end

	-- Downloads use only the canonical HTTPS URL built from the external pack
	-- catalog's validated numeric ID. Post-reload chart verification decides
	-- whether the downloaded pack matches the selected online chart.
	self:SearchStepManiaOnline(songInfo, function(ok, result, details)
		local candidates = {}
		if ok and type(result) == "table" then
			local candidate = build_pack_candidate(result, "catalog_exact")
			if candidate then candidates[#candidates + 1] = candidate end
		elseif type(details) == "table" and type(details.candidates) == "table" then
			candidates = details.candidates
		end

		candidates = dedupe_candidates(candidates)
		for _, candidate in ipairs(candidates) do
			local candidateId = canonical_id(candidate.id)
			if candidateId then
				candidate.id = candidateId
				candidate.trusted_catalog_candidate = true
				candidate.download_url = stepmaniaonline_origin() .. "/download/pack/" .. tostring(candidateId) .. "/"
			end
		end

		trace("DownloadBrowsingPack catalog candidates=" .. tostring(#candidates)
			.. " title=" .. tostring(selected_title(songInfo))
			.. " pack=" .. tostring(selected_pack(songInfo)))
		if #candidates == 0 then
			if callback then
				callback(false, (type(details) == "table" and details.errorMessage)
					or pack_text("NoMatchingStepManiaOnlinePack", "No matching StepManiaOnline pack was found."))
			end
			return
		end
		if options.autoStartSingleCandidate == true and #candidates == 1 then
			trace("DownloadBrowsingPack single catalog candidate; starting transfer"
				.. " title=" .. tostring(selected_title(songInfo))
				.. " pack=" .. tostring(candidates[1].name or candidates[1].title or "")
				.. " candidateId=" .. tostring(candidates[1].id or "nil"))
			self:DownloadPackByCandidate(songInfo, candidates[1], callback, {
				browseOnly = options.browseOnly ~= false,
			})
			return
		end
		if callback then
			callback(true, {
				kind = "pack_candidates",
				candidates = candidates,
				message = pack_text("ChoosePreviewPack", "Choose the pack matching this preview."),
			})
		end
	end)
end

local function browse_pack_reload_validated(songInfo, quarantinePath)
	local packName = selected_pack(songInfo)
	if packName ~= "" and PackSync:PackVisibleToSongman(packName) then
		return true
	end
	if packName ~= "" and PackSync:PackExists(packName) then
		trace("Browse-only pack exists on disk but is not visible to SONGMAN after reload pack=" .. tostring(packName))
	elseif quarantinePath and quarantinePath ~= "" and has_simfile_below_directory(quarantinePath, 2) then
		trace("Browse-only quarantine contains simfiles but expected pack is not visible to SONGMAN pack=" .. tostring(packName))
	end

	return false
end

-- Post-reload validation
-- -----------------------------------------------------------------------

function PackSync:ValidatePendingPostReload()
	local songInfo = self.pendingPostReloadSongInfo
	local quarantinePath = self.pendingQuarantinePath
	local browseOnly = self.pendingPostReloadBrowseOnly == true
	local packName = selected_pack(songInfo)
	local pendingCompleted = false
	local function complete_pending(ok, message, reason)
		if pendingCompleted then return end
		pendingCompleted = true
		self:CompletePendingPostReload(ok, message, reason)
	end
	trace("ValidatePendingPostReload begin hasSong=" .. tostring(songInfo ~= nil)
		.. " browseOnly=" .. tostring(browseOnly == true)
		.. " pack=" .. tostring(packName)
		.. " quarantine=" .. tostring(quarantinePath or "nil")
			.. " room=" .. tostring(ITGOnline and ITGOnline.currentRoomId or "nil")
			.. " phase=" .. tostring(ITGOnline and ITGOnline.currentRoom and ITGOnline.currentRoom.phase or "nil"))
	if not songInfo then
		trace("ValidatePendingPostReload skipped reason=no_pending_song")
		complete_pending(false, pack_text("NoDownloadPendingValidation", "No download is pending validation."),
			"post_reload_no_pending_song")
		return false
	end

	self:InvalidateLocalChartIndex()
	if browseOnly then
		trace("PostReload browse-only pack download complete quarantine=" .. tostring(quarantinePath or ""))
		if quarantinePath and quarantinePath ~= "" then
			log_dir_listing("PostReload browse-only pack", quarantinePath)
		end
		if not browse_pack_reload_validated(songInfo, quarantinePath) then
			trace("Browse-only pack download did not expose the expected pack after reload")
			rollback_installed_pack_if_possible(quarantinePath)
			self:UnmarkPackInstalled(packName, "browse_reload_validation_failed")
			self:UpdateStatus(self.status.DownloadFailed,
				pack_text("DownloadedPackMissingAfterReload", "The downloaded pack was not found after reload."))
				if MESSAGEMAN then
					MESSAGEMAN:Broadcast("OnlinePackDownloadFailed", { songInfo = songInfo, reason = "download_failed" })
				end
				complete_pending(false,
					pack_text("DownloadedPackMissingAfterReload", "The downloaded pack was not found after reload."),
					"browse_reload_validation_failed")
				return false
			end
			self:MarkPackInstalled(packName)
			self:UpdateStatus(self.status.DownloadedOk,
				pack_text("PackDownloadedWaitingManager", "Pack downloaded. Waiting for the manager's song selection."), 100,
				function(statusOk, decoded, response)
					trace("PostReload browse-only completion acknowledged ok=" .. tostring(statusOk == true)
						.. " status=" .. tostring(response and response.statusCode or "nil")
						.. " error=" .. tostring(decoded and decoded.error_code or response and response.errorMessage or "nil")
						.. " downloadId=" .. tostring(self.activeDownloadId or self.lastDownloadId or ""))
					if statusOk then
						complete_pending(true,
							pack_text("PackDownloadedValidated", "Pack downloaded and validated after reload."),
							"browse_reload_validation_ok")
					else
						self.pendingBrowseCompletionRetryAt = GetTimeSinceStart() + 5.25
						trace("PostReload browse-only completion retained for retry reason=browse_reload_status_not_acknowledged")
					end
				end)
		if MESSAGEMAN then
			MESSAGEMAN:Broadcast("OnlinePackDownloaded", { songInfo = songInfo })
		end
		local selectedSong = ITGOnline and ITGOnline.currentRoom and ITGOnline.currentRoom.selected_song or nil
			if selectedSong and selected_song_hash(selectedSong) ~= "" and selected_chart_hash(selectedSong) ~= "" then
				trace("Browse-only download complete; applying current selected song after reload"
				.. " title=" .. tostring(selected_title(selectedSong))
				.. " pack=" .. tostring(selected_pack(selectedSong))
				.. " selected_at=" .. tostring(selected_at(selectedSong))
				.. " room=" .. tostring(ITGOnline and ITGOnline.currentRoomId or "nil")
				.. " phase=" .. tostring(ITGOnline and ITGOnline.currentRoom and ITGOnline.currentRoom.phase or "nil"))
				self:ApplySelectedChart(selectedSong)
			end
			return true
		end
	trace("PostReload validate expected chart_hash=" .. tostring(selected_chart_hash(songInfo))
		.. " expected song_hash=" .. tostring(selected_song_hash(songInfo))
		.. " quarantine=" .. tostring(quarantinePath or ""))
	if quarantinePath and quarantinePath ~= "" then
		log_dir_listing("PostReload quarantine", quarantinePath)
	end
	self.validatingPostReload = true
	local okFind, result = pcall(function() return self:FindLocalMatch(songInfo) end)
	self.validatingPostReload = false
	if not okFind or type(result) ~= "table" then
		trace("PostReload local match failed err=" .. tostring(result))
		result = { ok = false, status = "missing", reason = "local_match_error" }
	end
	trace("PostReload local match result ok=" .. tostring(result and result.ok == true)
		.. " status=" .. tostring(result and result.status or "nil")
		.. " reason=" .. tostring(result and result.reason or "nil")
		.. " quarantine=" .. tostring(quarantinePath or "nil"))
	if result.ok then
		local songDir = result.song and result.song.GetSongDir and tostring(result.song:GetSongDir() or "") or ""
		if quarantinePath and quarantinePath ~= "" and songDir:sub(1, #quarantinePath) ~= quarantinePath then
				trace("Downloaded pack did not contain the selected chart; matched existing local chart instead")
				rollback_installed_pack_if_possible(quarantinePath)
			self:UnmarkPackInstalled(packName, "selected_chart_not_in_downloaded_pack")
			self:UpdateStatus(self.status.DownloadFailed,
				pack_text("DownloadedPackMissingExpectedChart", "The downloaded pack does not contain the expected chart."))
				if MESSAGEMAN and self:SongInfoMatchesCurrentSelection(songInfo) then
					MESSAGEMAN:Broadcast("OnlineMissingSong", { songInfo = songInfo, reason = "download_failed" })
				end
				complete_pending(false,
					pack_text("DownloadedPackMissingExpectedChart", "The downloaded pack does not contain the expected chart."),
					"selected_chart_not_in_downloaded_pack")
				return false
			end
		set_current_selection(result.song, result.steps, songInfo, "pack_sync_reload_apply_selected_chart")
		trace("Downloaded OK and local chart validated")
		self:MarkPackInstalled(packName)

		local currentSelectedSong = ITGOnline and ITGOnline.currentRoom and ITGOnline.currentRoom.selected_song or nil
		local downloadedSelectedAt = selected_at(songInfo)
		local currentSelectedAt = selected_at(currentSelectedSong)
		local currentSelectionChanged = downloadedSelectedAt ~= "" and downloadedSelectedAt ~= currentSelectedAt
		if currentSelectionChanged then
			trace("Downloaded pack belongs to an old manager selection; keeping download complete without readying stale song"
				.. " downloadedSelectedAt=" .. tostring(downloadedSelectedAt)
				.. " currentSelectedAt=" .. tostring(currentSelectedAt)
				.. " downloadedTitle=" .. tostring(selected_title(songInfo))
				.. " currentTitle=" .. tostring(selected_title(currentSelectedSong))
				.. " room=" .. tostring(ITGOnline and ITGOnline.currentRoomId or "nil")
				.. " phase=" .. tostring(ITGOnline and ITGOnline.currentRoom and ITGOnline.currentRoom.phase or "nil"))
			self:UpdateStatus(self.status.DownloadedOk,
				pack_text("PackDownloadedWaitingManager", "Pack downloaded. Waiting for the manager's song selection."), 100,
				function(statusOk, statusDecoded, statusResponse)
					if not statusOk then
						trace("Stale-selection completion acknowledgement failed; retaining transfer identity"
							.. " status=" .. tostring(statusResponse and statusResponse.statusCode or "nil")
							.. " error=" .. tostring(statusDecoded and statusDecoded.error_code
								or statusResponse and statusResponse.errorMessage or "nil"))
						return
					end
					if MESSAGEMAN then
						MESSAGEMAN:Broadcast("OnlinePackDownloaded", { songInfo = songInfo, staleSelection = true })
					end
					complete_pending(true, pack_text("PackDownloadedValidated", "Pack downloaded and validated after reload."),
						"selected_reload_validation_stale_selection")
				end)
			if currentSelectedSong and currentSelectedAt ~= "" then
					trace("Applying current manager selection after stale-selection download completion"
					.. " currentSelectedAt=" .. tostring(currentSelectedAt)
					.. " currentTitle=" .. tostring(selected_title(currentSelectedSong))
					.. " currentPack=" .. tostring(selected_pack(currentSelectedSong)))
					self:ApplySelectedChart(currentSelectedSong)
			end
			return true
			end

		self:UpdateStatus(self.status.DownloadedOk, nil, 100, function(statusOk, statusDecoded, statusResponse)
			if not statusOk then
				trace("PostReload completion acknowledgement failed; retaining transfer identity"
					.. " status=" .. tostring(statusResponse and statusResponse.statusCode or "nil")
					.. " error=" .. tostring(statusDecoded and statusDecoded.error_code or statusResponse and statusResponse.errorMessage or "nil"))
				return
			end
			-- The transfer is already acknowledged by the server and the local chart
			-- has been validated. Release the download guard before availability is
			-- confirmed; otherwise ReportSongAvailability defers itself forever on
			-- the very download that has just completed.
			complete_pending(true, pack_text("PackDownloadedValidated", "Pack downloaded and validated after reload."),
				"selected_reload_validation_ok")
			if MESSAGEMAN then
				MESSAGEMAN:Broadcast("OnlineSongAvailable", { songInfo = songInfo })
			end
			self:FinalizeDownloadedSelectedSongAvailability(songInfo, "post_reload")
		end)
		return true
	end

	if result.status == "mismatch" then
		self:UpdateStatus(self.status.ChartMismatch,
			pack_text("SongOrChartMismatch", "The song or chart differs from the manager's."))
		rollback_installed_pack_if_possible(quarantinePath)
		self:UnmarkPackInstalled(packName, "chart_mismatch")
		if ITGOnline and ITGOnline.ReportSongAvailability and self:SongInfoMatchesCurrentSelection(songInfo) then
			ITGOnline:ReportSongAvailability(true, "chart_mismatch")
		end
			if MESSAGEMAN and self:SongInfoMatchesCurrentSelection(songInfo) then
				MESSAGEMAN:Broadcast("OnlineMissingSong", { songInfo = songInfo, reason = "chart_mismatch", chartMismatch = true })
			end
			complete_pending(false, pack_text("SongOrChartMismatch", "The song or chart differs from the manager's."),
				"post_reload_chart_mismatch")
		else
			self:UpdateStatus(self.status.DownloadFailed,
				pack_text("SongMissingAfterReload", "The song could not be found after reload."))
			rollback_installed_pack_if_possible(quarantinePath)
		self:UnmarkPackInstalled(packName, "downloaded_song_missing_after_reload")
		if ITGOnline and ITGOnline.ReportSongAvailability and self:SongInfoMatchesCurrentSelection(songInfo) then
			ITGOnline:ReportSongAvailability(true, "download_failed")
		end
		if MESSAGEMAN and self:SongInfoMatchesCurrentSelection(songInfo) then
			MESSAGEMAN:Broadcast("OnlineMissingSong", { songInfo = songInfo, reason = "download_failed" })
			else
				trace("PostReload missing broadcast skipped reason=stale_or_no_active_selection"
					.. " selectedAt=" .. tostring(selected_at(songInfo))
					.. " roomSelectedAt=" .. tostring(current_room_selected_at()))
			end
			complete_pending(false, pack_text("SongMissingAfterReload", "The song could not be found after reload."),
				"post_reload_missing")
		end
	return false
end

OnlinePackSyncManager = PackSync
OnlineLocalChartMatcher = PackSync
OnlinePackSearchClient = PackSync
OnlinePackDownloadService = PackSync
OnlineChartHashService = PackSync
