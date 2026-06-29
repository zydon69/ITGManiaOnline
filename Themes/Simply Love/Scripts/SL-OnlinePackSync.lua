-- -----------------------------------------------------------------------
-- Online Pack Sync
--
-- Finds the manager-selected chart locally by hash, reports per-player
-- synchronization state, and downloads missing packs from StepManiaOnline
-- only after a selected chart cannot be matched locally.

ITGOnline = ITGOnline or {}
ITGOnline.PackSync = ITGOnline.PackSync or {}

local PackSync = ITGOnline.PackSync
PackSync.scriptVersion = "2026-06-21-pack-status-download-sequence-v2"
PackSync.statusChangedAt = PackSync.statusChangedAt or 0
PackSync.currentStatusMessage = PackSync.currentStatusMessage or nil
PackSync.watchdogLastKey = PackSync.watchdogLastKey or ""
PackSync.watchdogTimeoutSeconds = PackSync.watchdogTimeoutSeconds or 25
PackSync.activeBrowseOnlyDownload = PackSync.activeBrowseOnlyDownload or false
PackSync.installedPackNames = PackSync.installedPackNames or {}
PackSync.browsePreviewPackKey = PackSync.browsePreviewPackKey or ""
PackSync.downloadedPackKey = PackSync.downloadedPackKey or ""
PackSync.downloadGeneration = tonumber(PackSync.downloadGeneration) or 0
PackSync.downloadStatusSequence = tonumber(PackSync.downloadStatusSequence) or 0
PackSync.activeDownloadId = PackSync.activeDownloadId or ""
PackSync.localScanCache = PackSync.localScanCache or {}
PackSync.lastPostedStatusSignature = PackSync.lastPostedStatusSignature or ""
PackSync.lastPostedStatusAt = tonumber(PackSync.lastPostedStatusAt) or 0
PackSync.statusPostInFlightSignature = PackSync.statusPostInFlightSignature or ""
PackSync.statusPostInFlightCallbacks = PackSync.statusPostInFlightCallbacks or {}
PackSync.statusPostInFlightStartedAt = tonumber(PackSync.statusPostInFlightStartedAt) or 0
PackSync.lastAppliedLocalStatusSignature = PackSync.lastAppliedLocalStatusSignature or ""
PackSync.statusPostDuplicateHeartbeatSeconds = tonumber(PackSync.statusPostDuplicateHeartbeatSeconds) or 5.0
PackSync.lastManagerBrowsingPreviewPostKey = PackSync.lastManagerBrowsingPreviewPostKey or ""
PackSync.lastManagerBrowsingPreviewPostAt = tonumber(PackSync.lastManagerBrowsingPreviewPostAt) or 0
PackSync.managerBrowsingPreviewDuplicateSuppressSeconds = tonumber(PackSync.managerBrowsingPreviewDuplicateSuppressSeconds) or 1.5
PackSync.lastResetSignature = PackSync.lastResetSignature or ""
PackSync.lastResetAt = tonumber(PackSync.lastResetAt) or 0
PackSync.lastNoSongClearResetAt = tonumber(PackSync.lastNoSongClearResetAt) or 0
PackSync.lastNoSongClearResetReason = PackSync.lastNoSongClearResetReason or ""

PackSync.status = {
	Unknown = "unknown",
	Ready = "ready",
	ManagerBrowsingUnknownPack = "manager_browsing_unknown_pack",
	SearchingLocalCharts = "searching_local_charts",
	LocalChartMatchFound = "local_chart_match_found",
	NoCompatibleChartFound = "no_compatible_chart_found",
	DownloadRequested = "download_requested",
	DownloadInProgress = "download_in_progress",
	DownloadFailed = "download_failed",
	ReloadingSongs = "reloading_songs",
	DownloadedOk = "downloaded_ok",
	ChartMismatch = "chart_mismatch",
}

PackSync.statusText = {
	unknown = "Pret",
	ready = "Pret",
	manager_browsing_unknown_pack = "Pack inconnu",
	searching_local_charts = "Recherche locale",
	local_chart_match_found = "Chart compatible trouvee",
	no_compatible_chart_found = "Aucune chart compatible",
	download_requested = "Telechargement demande",
	download_in_progress = "Telechargement en cours",
	download_failed = "Telechargement echoue",
	reloading_songs = "Rechargement chansons",
	downloaded_ok = "Telechargement OK",
	chart_mismatch = "Chart differente",
}

local function early_trim(value)
	return tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local trace

function PackSync:IsActiveDownloadStatus(status)
	status = tostring(status or self.currentStatus or "")
	return status == self.status.DownloadRequested
		or status == self.status.DownloadInProgress
		or status == self.status.ReloadingSongs
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
	trace("Active download id cleared reason=" .. tostring(reason or "unknown")
		.. " activeDownloadId=" .. tostring(self.activeDownloadId)
		.. " status=" .. tostring(self.currentStatus or "nil")
		.. " key=" .. tostring(self.downloadInFlightKey or ""))
	self.activeDownloadId = ""
end

function PackSync:UsesDownloadStatusSequence(status)
	status = tostring(status or "")
	return status == self.status.DownloadRequested
		or status == self.status.DownloadInProgress
		or status == self.status.ReloadingSongs
		or status == self.status.DownloadedOk
		or status == self.status.DownloadFailed
end

function PackSync:ShouldPreserveActiveDownloadDuringReset(reason)
	if not self:HasDownloadWorkInFlight() then
		if self.currentStatus == self.status.Ready or self.currentStatus == self.status.DownloadedOk then
			self:ClearActiveDownloadId("reset_preserve_check_completed:" .. tostring(reason or "unknown"))
		end
		return false
	end

	reason = tostring(reason or "unknown")
	if reason == "lobby_left"
		or reason == "logout"
		or reason == "disconnect"
		or reason == "watchdog_timeout"
		or reason == "explicit_cancel"
	then
		return false
	end

	return true
end

trace = function(message)
	if type(online_logs_enabled) == "function" and not online_logs_enabled() then
		return
	end
	local line = "[OnlinePackSync] " .. tostring(message or "")
	if Trace then Trace(line) elseif Warn then Warn(line) end
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

trace("Loaded script version=" .. tostring(PackSync.scriptVersion))

local function download_already_in_progress_message()
	return "Telechargement deja en cours."
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
	if type(ITGOnline.currentRoom.members) == "table"
		and #ITGOnline.currentRoom.members == 0
		and PackSync
		and PackSync:IsActiveDownload() then
		trace("Active room membership trusted during active download because current room snapshot has no members"
			.. " room=" .. tostring(currentRoomId)
			.. " status=" .. tostring(PackSync.currentStatus or "nil")
			.. " key=" .. tostring(PackSync.downloadInFlightKey or "")
			.. " browseOnly=" .. tostring(PackSync.activeBrowseOnlyDownload == true))
		return true
	end
	for member in ivalues(ITGOnline.currentRoom.members or {}) do
		local user = member.user or member
		local userId = tostring(user.id or member.user_id or "")
		if userId == currentUserId then
			return true
		end
	end
	return false
end

function PackSync:NextDownloadGeneration(reason)
	self.downloadGeneration = (tonumber(self.downloadGeneration) or 0) + 1
	self.downloadStatusSequence = math.max(tonumber(self.downloadStatusSequence) or 0, tonumber(self.sequence) or 0)
	reason = tostring(reason or "unknown")
	local startsDownload = reason == "download_selected_search"
		or reason == "download_browsing_search"
		or reason == "selected_candidate_start"
		or reason == "browse_candidate_start"
	if startsDownload then
		self.activeDownloadId = tostring(self.downloadGeneration) .. ":" .. tostring(math.floor(((GetTimeSinceStart and GetTimeSinceStart()) or 0) * 1000))
	else
		self.activeDownloadId = ""
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

local function current_room_selected_at()
	return selected_at(current_room_selected_song())
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

local function safe_file_name(value)
	value = trim(value):gsub("[/\\:%c]", "_"):gsub("%.%.", "_")
	value = value:gsub("^%s+", ""):gsub("%s+$", "")
	if value == "" then value = "stepmaniaonline-pack" end
	if not value:lower():match("%.zip$") then value = value .. ".zip" end
	return value
end

local function safe_folder_name(value)
	value = trim(value):gsub("[/\\:%c]", "_"):gsub("%.%.", "_")
	value = value:gsub("^%s+", ""):gsub("%s+$", "")
	value = value:gsub("%.[Zz][Ii][Pp]$", "")
	if value == "" then value = "stepmaniaonline-pack" end
	return value
end

local function pack_quarantine_path(packId, packName)
	local folderName = safe_folder_name("__OnlineDownload_" .. tostring(packId) .. "_" .. tostring(packName or "pack"))
	return "/Songs/" .. folderName .. "/"
end

local function legacy_online_downloads_root()
	return "/Songs/Online Downloads/"
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
	for _, entryName in ivalues(dir_listing(quarantinePath, false, false)) do
		if entryName ~= folderName and not is_temp_newdir_artifact(entryName) then
			return ""
		end
	end

	return folders[1]
end

local function first_enabled_player()
	local enabled = GAMESTATE and GAMESTATE:GetEnabledPlayers() or {}
	return enabled[1] or PLAYER_1
end

local function set_current_selection(song, steps)
	if not song then return end
	GAMESTATE:SetCurrentSong(song)
	if steps then
		for player in ivalues(GAMESTATE:GetEnabledPlayers()) do
			GAMESTATE:SetCurrentSteps(player, steps)
		end
	end
end

local function transition_to_player_options()
	local topScreen = SCREENMAN and SCREENMAN:GetTopScreen() or nil
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

local function transition_to_reload_songs()
	if SL and SL.Global then
		SL.Global.Online = SL.Global.Online or {}
		SL.Global.Online.ReturnToLobbyAfterSongReload = true
	end

	local topScreen = SCREENMAN and SCREENMAN:GetTopScreen() or nil
	if not topScreen then
		if online_flow_trace then
			online_flow_trace("pack_sync_reload_songs_skipped reason=no_top_screen")
		end
		return
	end

	if topScreen:GetName() == "ScreenReloadSongsOnline" then
		if online_flow_trace then
			online_flow_trace("pack_sync_reload_songs_skipped reason=already_reloading")
		end
		return
	end

	if online_flow_trace then
		online_flow_trace("pack_sync_reload_songs_transition from=" .. tostring(topScreen:GetName()))
	end
	topScreen:SetNextScreenName("ScreenReloadSongsOnline")
	topScreen:StartTransitioningScreen("SM_GoToNextScreen")
end

local function playable_steps(song)
	if not song then return {} end
	if SongUtil and SongUtil.GetPlayableSteps then
		return SongUtil.GetPlayableSteps(song)
	end
	local style = GAMESTATE:GetCurrentStyle()
	local stepsType = style and style:GetStepsType() or nil
	return stepsType and song:GetStepsByStepsType(stepsType) or {}
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
	return tostring(#SONGMAN:GetAllSongs())
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
	local style = GAMESTATE:GetCurrentStyle()
	local stepsType = style and style:GetStepsType() or nil
	local stepsList = {}

	if stepsType then
		stepsList = song:GetStepsByStepsType(stepsType)
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

	local fullTitle = lower(song:GetDisplayFullTitle())
	local mainTitle = song.GetTranslitMainTitle and lower(song:GetTranslitMainTitle()) or fullTitle
	if fullTitle ~= expectedTitle and mainTitle ~= expectedTitle then
		return false
	end

	local expectedArtist = lower(selected_artist(songInfo))
	if expectedArtist == "" then return true end

	local artist = lower(song:GetDisplayArtist())
	local translitArtist = song.GetTranslitArtist and lower(song:GetTranslitArtist()) or artist
	return artist == expectedArtist or translitArtist == expectedArtist
end

function PackSync:DisplayText(status)
	return self.statusText[tostring(status or "")] or self.statusText.unknown
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
		if callback then callback(false, nil, { errorMessage = "Aucun salon online actif." }) end
		return
	end
	self.currentStatus = status
	self.currentStatusMessage = message
	self.statusChangedAt = GetTimeSinceStart()
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
		if alreadyReadyForSelection then
			trace("Status post skipped reason=client_ready_status_protected_from_local_scan"
				.. " status=" .. tostring(status)
				.. " selected_at=" .. tostring(currentSelectedAt)
				.. " room=" .. tostring(ITGOnline and ITGOnline.currentRoomId or "nil"))
			if callback then
				callback(true, {
					pack_sync_status = {
						applied = false,
						ignored_reason = "client_ready_status_protected_from_local_scan",
					},
					local_only = true,
				}, nil)
			end
			return
		end
	end
	local noActiveSelectionLocalOnly = currentSelectedAt == "" and (
		status == self.status.DownloadedOk
		or status == self.status.Ready
		or status == self.status.SearchingLocalCharts
		or status == self.status.LocalChartMatchFound
		or status == self.status.NoCompatibleChartFound
		or status == self.status.ChartMismatch
	)
	if noActiveSelectionLocalOnly then
		trace("Status post skipped reason=no_active_selection_local_only"
			.. " status=" .. tostring(status)
			.. " progress=" .. tostring(progress)
			.. " room=" .. tostring(ITGOnline and ITGOnline.currentRoomId or "nil")
			.. " phase=" .. tostring(ITGOnline and ITGOnline.currentRoom and ITGOnline.currentRoom.phase or "nil"))
		if MESSAGEMAN then
			local activeRoomId = ITGOnline and ITGOnline.currentRoomId or nil
			local activeRoomPhase = ITGOnline and ITGOnline.currentRoom and ITGOnline.currentRoom.phase or nil
			MESSAGEMAN:Broadcast("OnlinePackSyncLocalStatus", {
				status = status,
				message = message,
				download_progress = progress,
				selected_at = "",
				room_id = activeRoomId,
				room_phase = activeRoomPhase,
				mode = activeRoomId and "joined" or "browse",
				local_only = true,
			})
		end
		if callback then
			callback(true, {
				pack_sync_status = {
					applied = false,
					ignored_reason = "client_no_active_selection_local_only",
				},
				local_only = true,
			}, nil)
		end
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
		tostring(self.activeDownloadId or ""),
	}, "||")
	local now = GetTimeSinceStart and GetTimeSinceStart() or 0
	if intentSignature ~= "" and intentSignature == tostring(self.lastStatusPostIntentSignature or "") then
		local age = now - (tonumber(self.lastStatusPostIntentAt) or 0)
		if age < 0.35 then
			trace("Status post skipped duplicate_intent status=" .. tostring(status)
				.. " progress=" .. tostring(progress)
				.. " selected_at=" .. tostring(currentSelectedAt)
				.. " age=" .. string.format("%.3f", age))
			if callback then
				callback(true, {
					pack_sync_status = {
						applied = false,
						ignored_reason = "client_duplicate_status_intent",
					},
					duplicate = true,
				}, nil)
			end
			return
		end
	end
	self.lastStatusPostIntentSignature = intentSignature
	self.lastStatusPostIntentAt = now

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
	local signature = status_post_signature(ITGOnline and ITGOnline.currentRoomId or "", currentSelectedAt, status, message, progress, options)
	local postedAt = tonumber(self.lastPostedStatusAt) or 0
	local heartbeat = tonumber(self.statusPostDuplicateHeartbeatSeconds) or 5.0
	if signature ~= "" and signature == tostring(self.statusPostInFlightSignature or "") then
		trace("Status post skipped duplicate_in_flight status=" .. tostring(status)
			.. " progress=" .. tostring(progress)
			.. " selected_at=" .. tostring(currentSelectedAt))
		if callback then
			self.statusPostInFlightCallbacks[signature] = self.statusPostInFlightCallbacks[signature] or {}
			self.statusPostInFlightCallbacks[signature][#self.statusPostInFlightCallbacks[signature] + 1] = callback
		end
		return
	end
	if signature ~= "" and signature == tostring(self.lastPostedStatusSignature or "") and (now - postedAt) < heartbeat then
		trace("Status post skipped duplicate status=" .. tostring(status)
			.. " progress=" .. tostring(progress)
			.. " selected_at=" .. tostring(currentSelectedAt)
			.. " age=" .. string.format("%.3f", now - postedAt))
		if callback then
			callback(true, {
				pack_sync_status = {
					applied = false,
					ignored_reason = "client_duplicate_status",
				},
				duplicate = true,
			}, nil)
		end
		return
	end
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

	local payload = {
		status = status,
		message = message,
		download_progress = progress,
		sequence = requestSequence,
	}
	if options.downloadCancelled == true then
		payload.download_cancelled = true
	end
	if self.currentSongInfo then
		if currentSelectedAt ~= "" then
			payload.selected_at = currentSelectedAt
		end
	end

	ITGOnline:Request("POST", "/rooms/" .. requestRoomId .. "/pack-sync-status", payload, function(ok, decoded, response)
		if tostring(self.statusPostInFlightSignature or "") == signature then
			self.statusPostInFlightSignature = ""
			self.statusPostInFlightStartedAt = 0
		end
		local statusResult = decoded and decoded.pack_sync_status or nil
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
		if callback then callback(callbackOk, decoded, response) end
		local waitingCallbacks = self.statusPostInFlightCallbacks[signature] or {}
		self.statusPostInFlightCallbacks[signature] = nil
		for _, queuedCallback in ipairs(waitingCallbacks) do
			queuedCallback(callbackOk, decoded, response)
		end
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
	self.statusChangedAt = GetTimeSinceStart()
	local localSignature = table.concat({
		tostring(ITGOnline and ITGOnline.currentRoomId or ""),
		tostring(selected_at(self.currentSongInfo)),
		tostring(status),
		tostring(message or ""),
		tostring(progress or ""),
	}, "||")
	if localSignature ~= "" and localSignature == tostring(self.lastAppliedLocalStatusSignature or "") then
		trace("ApplyLocalStatus skipped duplicate status=" .. tostring(status)
			.. " progress=" .. tostring(progress)
			.. " selected_at=" .. tostring(selected_at(self.currentSongInfo)))
		return
	end
	self.lastAppliedLocalStatusSignature = localSignature
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
	local status = tostring(self.currentStatus or self.status.Unknown)
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

	local message = "Opération interrompue (timeout). Réessayez le téléchargement du pack."
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
	if reason == "no_song_confirmed" and self.activeBrowseOnlyDownload == true then
		trace("Keep browse-only download state during no_song_confirmed reset")
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
	if reason == "no_song_confirmed" and (
		self.currentStatus == self.status.DownloadRequested
		or self.currentStatus == self.status.DownloadInProgress
		or self.currentStatus == self.status.ReloadingSongs
	) then
		trace("Keep active download state during no_song_confirmed reset status=" .. tostring(self.currentStatus))
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
	self.statusPostInFlightSignature = ""
	self.lastAppliedLocalStatusSignature = ""
	self.lastResetSignature = ""
	self.lastResetAt = 0
	self.lastNoSongClearResetAt = now
	self.lastNoSongClearResetReason = normalizedReason
	self.localScanCache = {}
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
	self:NextDownloadGeneration(reason or "reset_local_state")
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
			"Telechargement du pack annule.",
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
end

function PackSync:LocalChartIndex()
	local key = song_count_key()
	if self.localChartIndex and self.localChartIndexKey == key then
		trace("LocalChartIndex reused key=" .. tostring(key))
		return self.localChartIndex
	end

	local index = {}
	local songCount = 0
	local stepsCount = 0
	local hashCount = 0
	if SONGMAN and SONGMAN.GetAllSongs then
		for song in ivalues(SONGMAN:GetAllSongs()) do
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
	local status = exists and self.status.DownloadedOk or self.status.ManagerBrowsingUnknownPack
	local message = exists and "Pack disponible localement." or "Le manager navigue dans un pack que vous ne possédez pas."
	if exists and self.downloadedPackKey == packKey then
		message = "Pack téléchargé et disponible localement."
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
		trace("Skipping local chart status scan during active download title=" .. selected_title(songInfo))
		trace_online_state("local_match_skipped_active_download", {
			selected_at = selected_at(songInfo),
			title = selected_title(songInfo),
			pack = selected_pack(songInfo),
			status = self.currentStatus or "nil",
			downloadKey = self.downloadInFlightKey or "",
			activeDownloadId = self.activeDownloadId or "",
			browseOnly = self.activeBrowseOnlyDownload == true,
		})
		return { ok = false, status = "download_in_progress", reason = "download_in_progress" }
	end
	local scanKey = local_scan_key(songInfo)
	local cachedScan = self.localScanCache and self.localScanCache[scanKey] or nil
	if cachedScan and cachedScan.ok == false then
		trace("Local chart scan reused cached terminal result title=" .. selected_title(songInfo)
			.. " status=" .. tostring(cachedScan.status)
			.. " reason=" .. tostring(cachedScan.reason))
		if cachedScan.status == "mismatch" then
			self:ApplyLocalStatus(self.status.ChartMismatch, cachedScan.message)
		else
			self:ApplyLocalStatus(self.status.NoCompatibleChartFound, cachedScan.message)
		end
		return {
			ok = false,
			status = cachedScan.status,
			reason = cachedScan.reason,
		}
	end
	trace("Searching local charts title=" .. selected_title(songInfo) .. " pack=" .. selected_pack(songInfo))
	self:UpdateStatus(self.status.SearchingLocalCharts, nil)

	local expectedChartHash = selected_chart_hash(songInfo)
	if expectedChartHash == "" then
		trace("Local chart scan failed reason=missing_expected_chart_hash title=" .. selected_title(songInfo)
			.. " pack=" .. selected_pack(songInfo)
			.. " selected_at=" .. selected_at(songInfo))
		return { ok = false, status = "missing", reason = "chart_hash_mismatch" }
	end

	local exactPath = selected_path(songInfo)
	local exactSong = exactPath ~= "" and SONGMAN:FindSong(exactPath) or nil
	trace("Local chart exact path lookup path=" .. tostring(exactPath)
		.. " found=" .. tostring(exactSong ~= nil))
	if not exactSong and exactPath ~= "" then
		local parts = split_path_segments(exactPath)
		if parts and parts[2] then exactSong = SONGMAN:FindSong(parts[2]) end
		trace("Local chart fallback path lookup folder=" .. tostring(parts and parts[2] or "nil")
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
				and "Pack+chart trouvées"
				or "Pack KO / chart compatible trouvée"
			self:UpdateStatus(self.status.LocalChartMatchFound, matchMessage)
			return { ok = true, song = song, steps = steps, payload = payload, matchSource = matchSource, matchMessage = matchMessage }
		end

		mismatchReason = mismatchReason or reason or "chart_mismatch"
		trace("Candidate hash mismatch " .. tostring(source or song:GetSongDir()) .. " reason=" .. tostring(mismatchReason))
		return nil
	end

	if exactSong then
		local result = evaluate_candidate(exactSong, "manager pack")
		if result then return result end
	end

	for song in ivalues(SONGMAN:GetAllSongs()) do
		if song ~= exactSong and song_matches_text_prefilter(song, songInfo) then
			local result = evaluate_candidate(song)
			if result then return result end
		end
	end

	local indexedCandidates = self:LocalChartIndex()[expectedChartHash] or {}
	trace("Local chart hash index candidates hash=" .. tostring(expectedChartHash)
		.. " count=" .. tostring(#indexedCandidates))
	for candidate in ivalues(indexedCandidates) do
		if candidate.song ~= exactSong and not song_matches_text_prefilter(candidate.song, songInfo) then
			trace("Candidate chart found via hash index " .. tostring(candidate.song:GetSongDir()))
			local payload = build_payload(candidate.song, candidate.steps)
			local payloadOk, reason = payload_matches_selected(payload, songInfo)
			if payloadOk then
				trace("Matching local chart found via hash index " .. tostring(candidate.song:GetSongDir()))
				local matchMessage = "Pack KO / chart compatible trouvée"
				self:UpdateStatus(self.status.LocalChartMatchFound, matchMessage)
				return { ok = true, song = candidate.song, steps = candidate.steps, payload = payload, matchSource = "alternate_pack", matchMessage = matchMessage }
			end
			trace("Candidate hash index mismatch dir=" .. tostring(candidate.song:GetSongDir())
				.. " reason=" .. tostring(reason or "unknown")
				.. " expectedSongHash=" .. tostring(selected_song_hash(songInfo)))
			mismatchReason = mismatchReason or reason or "chart_mismatch"
		end
	end

	if mismatchReason then
		local message = mismatchReason == "song_hash_mismatch"
			and "La stepchart existe localement, mais l'audio differe de celui du manager."
			or "La musique ou la stepchart trouvée est différente de celle du manager."
		self:UpdateStatus(self.status.ChartMismatch, message)
		self.localScanCache[scanKey] = { ok = false, status = "mismatch", reason = mismatchReason, message = message }
		return { ok = false, status = "mismatch", reason = mismatchReason }
	end

	trace("No compatible chart found title=" .. selected_title(songInfo))
	local message = "Aucune stepchart identique à celle du manager n’a été trouvée."
	self:UpdateStatus(self.status.NoCompatibleChartFound, message)
	self.localScanCache[scanKey] = { ok = false, status = "missing", reason = "no_compatible_chart_found", message = message }
	return { ok = false, status = "missing", reason = "no_compatible_chart_found" }
end

function PackSync:ApplySelectedChart(songInfo)
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
		.. " chartHash=" .. tostring(selected_chart_hash(songInfo)):sub(1, 12)
		.. " currentStatus=" .. tostring(self.currentStatus or "nil"))
	trace("ApplySelectedChart begin title=" .. tostring(selected_title(songInfo))
		.. " pack=" .. tostring(selected_pack(songInfo))
		.. " selected_at=" .. tostring(selected_at(songInfo))
		.. " chart_hash=" .. tostring(selected_chart_hash(songInfo))
		.. " room=" .. tostring(ITGOnline and ITGOnline.currentRoomId or "nil")
		.. " phase=" .. tostring(ITGOnline and ITGOnline.currentRoom and ITGOnline.currentRoom.phase or "nil")
		.. " downloadWorkInFlight=" .. tostring(self:HasDownloadWorkInFlight())
		.. " activeDownloadId=" .. tostring(self.activeDownloadId or "")
		.. " generation=" .. tostring(self.downloadGeneration or "nil"))
	local result = self:FindLocalMatch(songInfo)
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
	if result.ok then
		set_current_selection(result.song, result.steps)
		MESSAGEMAN:Broadcast("OnlineSongAvailable", { songInfo = songInfo })
		if ITGOnline and ITGOnline.ConfirmSelectedSongAvailability then
			ITGOnline:ConfirmSelectedSongAvailability("local_chart_match_found", function(ok)
				trace("ApplySelectedChart availability confirmed ok=" .. tostring(ok == true)
					.. " source=local_chart_match_found")
				if ok then
					self:UpdateStatus(self.status.Ready, result.matchMessage)
					self:MarkLobbyReadyForSelectedSong("local_chart_match_found")
				end
			end)
		else
			self:UpdateStatus(self.status.Ready, result.matchMessage)
			self:MarkLobbyReadyForSelectedSong("local_chart_match_found_no_client_confirm")
		end
		return true
	end

	local reason = result.reason or "missing_local_song"
	if reason == "download_in_progress" then
		return false
	end
	if result.status == "mismatch" then
		MESSAGEMAN:Broadcast("OnlineMissingSong", { songInfo = songInfo, reason = reason, chartMismatch = true })
	else
		MESSAGEMAN:Broadcast("OnlineMissingSong", { songInfo = songInfo, reason = reason, noCompatibleChart = true })
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

local function stepmaniaonline_origin()
	-- API endpoints now resolve reliably on the apex domain.
	return "https://stepmaniaonline.net"
end

local function request_json(url, callback, options)
	options = options or {}
	NETWORK:HttpRequest({
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
					trace("HTTP JSON not found (expected fallback) url=" .. tostring(url))
				else
					trace("HTTP JSON failed status=" .. tostring(statusCode) .. " url=" .. tostring(url))
				end
				callback(false, nil, response)
				return
			end
			local ok, decoded = pcall(JsonDecode, response.body or "")
			if not ok or decoded == nil then
				local sample = tostring(response and response.body or ""):gsub("%s+", " "):sub(1, 200)
				trace("HTTP JSON decode failed status=" .. tostring(statusCode) .. " url=" .. tostring(url) .. " body_sample=" .. sample)
				local firstByte = string.byte(response and response.body or "", 1)
				local secondByte = string.byte(response and response.body or "", 2)
				if firstByte == 0x1f and secondByte == 0x8b then
					callback(false, nil, {
						statusCode = statusCode,
						errorMessage = "Compressed StepManiaOnline response could not be decoded.",
					})
					return
				end
			end
			callback(ok and decoded ~= nil, decoded, response)
		end,
	})
end

local function path_escape(value)
	return tostring(value or ""):gsub("([^%w%._:%-])", function(char)
		return string.format("%%%02X", string.byte(char))
	end)
end

local function build_pack_candidate(packResult, source)
	if type(packResult) ~= "table" then return nil end
	local id = tonumber(packResult.id)
	if not id or id < 1 then return nil end
	return {
		id = id,
		name = trim(packResult.name or ("Pack " .. tostring(id))),
		songs_count = tonumber(packResult.songs_count) or 0,
		match_source = source or "unknown",
	}
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
		trace(prefix .. " path=" .. tostring(path) .. " entries=<unavailable>")
		return
	end
	table.sort(entries)
	trace(prefix .. " path=" .. tostring(path) .. " entries=" .. tostring(#entries))
	for i = 1, math.min(#entries, 20) do
		trace(prefix .. " entry[" .. tostring(i) .. "]=" .. tostring(entries[i]))
	end
	if #entries > 20 then
		trace(prefix .. " ... truncated")
	end
end

local function copy_directory_recursive(sourcePath, targetPath, maxDepth)
	if not FILEMAN or not FILEMAN.Copy or not FILEMAN.CreateDir then return false end
	if not sourcePath or sourcePath == "" or not targetPath or targetPath == "" then return false end
	maxDepth = tonumber(maxDepth) or 0
	if maxDepth < 0 then return false end
	if sourcePath:sub(-1) ~= "/" then sourcePath = sourcePath .. "/" end
	if targetPath:sub(-1) ~= "/" then targetPath = targetPath .. "/" end

	FILEMAN:CreateDir(targetPath)
	local folderPaths = {}
	for _, folderName in ivalues(dir_listing(sourcePath, true, false)) do
		local safeName = safe_child_folder_name(folderName)
		if safeName ~= "" and not is_temp_newdir_artifact(safeName) then
			folderPaths[sourcePath .. safeName] = true
			folderPaths[sourcePath .. safeName .. "/"] = true
			if not copy_directory_recursive(sourcePath .. safeName .. "/", targetPath .. safeName .. "/", maxDepth - 1) then
				return false
			end
		end
	end
	for _, entryPath in ivalues(dir_listing(sourcePath, false, true)) do
		local fileName = tostring(entryPath or ""):match("([^/]+)$") or ""
		if fileName ~= "" and not is_temp_newdir_artifact(fileName) and not folderPaths[tostring(entryPath or "")] then
			if not FILEMAN:Copy(entryPath, targetPath .. fileName) then
				trace("Recursive copy failed from=" .. tostring(entryPath) .. " to=" .. tostring(targetPath .. fileName))
				return false
			end
		end
	end
	return true
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
		return nil, "Le zip téléchargé ne contient pas un dossier de pack unique."
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
		trace("Install extracted pack reused existing target=" .. tostring(rootGroupPath)
			.. " quarantineExistsAfterCleanup=" .. tostring(path_exists(quarantinePath) or path_exists(quarantinePath .. "/")))
		return rootGroupPath .. "/", nil
	end
	if not FILEMAN or not FILEMAN.MoveOnlineSongPack then
		return nil, "Le moteur ne permet pas d'installer le pack téléchargé."
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
		trace("MoveOnlineSongPack failed; trying recursive copy source=" .. tostring(sourcePath) .. " target=" .. tostring(rootGroupPath))
		if not copy_directory_recursive(sourcePath .. "/", rootGroupPath .. "/", 8) then
			remove_directory_if_possible(rootGroupPath .. "/")
			return nil, "Impossible d'installer le pack téléchargé."
		end
		flush_dir_cache("/Songs/")
		flush_dir_cache(quarantinePath)
		flush_dir_cache(sourcePath)
		flush_dir_cache(rootGroupPath)
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
		local encoded = NETWORK:EncodeQueryParameters({ type = queryType, query = query })
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
			local titleMatches = false
			if type(packResult.matching_songs) == "table" and #packResult.matching_songs > 0 and title ~= "" then
				for songTitle in ivalues(packResult.matching_songs) do
					if lower(songTitle) == lower(title) then
						titleMatches = true
						break
					end
				end
			end
			if packExact or titleMatches then
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
				callback(false, nil, { errorMessage = "La recherche artiste StepManiaOnline a echoue." })
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
		trace("SMO chart_key lookup begin chartKey=" .. tostring(chartKey))
		request_json(origin .. "/api/chart/key/" .. path_escape(chartKey), function(ok, chartDecoded)
			trace("SMO chart_key lookup result ok=" .. tostring(ok == true)
				.. " commonPacks=" .. tostring(chartDecoded and chartDecoded.common_packs and #chartDecoded.common_packs or 0)
				.. " chartKey=" .. tostring(chartKey))
			if ok and chartDecoded then
				local chartPack = choose_chart_key_pack(chartDecoded)
				if chartPack and chartPack.id then
					callback(true, chartPack)
					return
				end
					local commonPacks = chartDecoded.common_packs or {}
					if #commonPacks > 1 and pack == "" then
						local payload = {}
						for _, candidate in ipairs(commonPacks) do
							local built = build_pack_candidate(candidate, "chart_key")
							if built then payload[#payload + 1] = built end
						end
						callback(false, nil, {
							errorMessage = "La chart StepManiaOnline correspond a plusieurs packs.",
							candidates = dedupe_candidates(payload),
						})
						return
					end
					callback(false, nil, { errorMessage = "La chart StepManiaOnline ne correspond pas au pack selectionne." })
				return
			end
			self:SearchStepManiaOnline({
				title = title,
				artist = artist,
				pack = pack,
				songPath = selected_path(songInfo),
			}, callback)
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
							callback(false, nil, { errorMessage = "Les recherches pack et titre StepManiaOnline ont echoue." })
							return
						end
						finish_title_results(titleDecoded)
					end)
				else
					callback(false, nil, { errorMessage = "La recherche de pack StepManiaOnline a echoue." })
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
					if lower(trim(packResult.name)) == lower(pack) then
						exactPackMatches[#exactPackMatches + 1] = packResult
					end
				end
			end
			if #exactPackMatches == 1 then
				callback(true, exactPackMatches[1])
				return
			end
			-- When pack search already returned candidates, do not hard-depend on title search:
			-- title endpoint can be flaky and should not block the flow.
			if #packCandidatesPayload == 1 then
				callback(true, {
					id = packCandidatesPayload[1].id,
					name = packCandidatesPayload[1].name,
					songs_count = packCandidatesPayload[1].songs_count,
				})
				return
			elseif #packCandidatesPayload > 1 then
				callback(false, nil, {
					errorMessage = "La recherche de pack StepManiaOnline correspond a plusieurs packs.",
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
					-- Keep a resilient fallback: if title search fails upstream, but pack search
					-- yielded one exact pack match, continue with that match instead of hard failing.
					if #exactPackMatches == 1 then
						callback(true, exactPackMatches[1])
					elseif #packCandidatesPayload == 1 then
						callback(true, {
							id = packCandidatesPayload[1].id,
							name = packCandidatesPayload[1].name,
							songs_count = packCandidatesPayload[1].songs_count,
						})
					elseif #packCandidatesPayload > 1 then
						callback(false, nil, {
							errorMessage = "La recherche titre StepManiaOnline a echoue.",
							candidates = packCandidatesPayload,
						})
					else
						callback(false, nil, { errorMessage = "La recherche titre StepManiaOnline a echoue." })
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
			if not ok then callback(false, nil, { errorMessage = "La recherche titre StepManiaOnline a echoue." }); return end
			finish_title_results(decoded)
		end)
	else
		trace("SearchStepManiaOnline failed reason=no_pack_no_title")
		callback(false, nil, { errorMessage = "Aucun pack ou titre disponible pour la recherche StepManiaOnline." })
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
		if callback then callback(false, "Pack candidat invalide.") end
		return
	end
	if not current_user_is_active_room_member() then
		trace("DownloadPackByCandidate blocked reason=not_active_room_member"
			.. " packId=" .. tostring(pack and pack.id or "nil")
			.. " packName=" .. tostring(pack and pack.name or "nil")
			.. " room=" .. tostring(ITGOnline and ITGOnline.currentRoomId or "nil")
			.. " hasRoom=" .. tostring(ITGOnline and ITGOnline.currentRoom ~= nil)
			.. " hasUser=" .. tostring(ITGOnline and ITGOnline.user ~= nil))
		if callback then callback(false, "Vous n'etes plus dans le salon.") end
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

	local packId = tonumber(pack.id)
	if not packId or math.floor(packId) ~= packId or packId < 1 then
		trace("DownloadPackByCandidate blocked reason=invalid_pack_id raw=" .. tostring(pack.id)
			.. " packName=" .. tostring(pack.name or "nil"))
		if callback then callback(false, "StepManiaOnline a renvoye un identifiant de pack invalide.") end
		return
	end

	local packName = trim(pack.name or ("Pack " .. tostring(packId)))
	if existingDownloadKey == "" then
		self.downloadInFlightKey = (browseOnly and "browse-candidate|" or "selected-candidate|") .. tostring(packId) .. "|" .. packName
	end
	local downloadGeneration = tonumber(options.downloadGeneration)
		or self:NextDownloadGeneration(browseOnly and "browse_candidate_start" or "selected_candidate_start")
	local fileName = tostring(packId) .. "_" .. safe_file_name(packName)
	local quarantinePath = pack_quarantine_path(packId, packName)
	local maxDownloadBytes = tonumber(self.maxDownloadBytes) or (512 * 1024 * 1024)

	local url = stepmaniaonline_origin() .. "/download/pack/" .. tostring(packId) .. "/"
	local downloadMessage = "Telechargement de " .. tostring(packName)
	trace("Download started pack=" .. tostring(packName) .. " id=" .. tostring(packId)
		.. " generation=" .. tostring(downloadGeneration)
		.. " browseOnly=" .. tostring(browseOnly == true)
		.. " key=" .. tostring(self.downloadInFlightKey or "")
		.. " room=" .. tostring(ITGOnline and ITGOnline.currentRoomId or "nil")
		.. " phase=" .. tostring(ITGOnline and ITGOnline.currentRoom and ITGOnline.currentRoom.phase or "nil"))
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
	self:UpdateStatus(self.status.DownloadInProgress, downloadMessage, 0)
	self.lastProgressStatusAt = 0
	self.lastProgressValue = -10
	self.lastProgressBucket = -1
	local downloadCompleted = false

	local function fail_candidate_download(message, broadcastMissing)
		if not self:IsDownloadGenerationCurrent(downloadGeneration) then
			trace("Download failure ignored reason=stale_generation pack=" .. tostring(packName)
				.. " generation=" .. tostring(downloadGeneration)
				.. " current=" .. tostring(self.downloadGeneration))
			return
		end
		if downloadCompleted then return end
		downloadCompleted = true
		message = message or "Le téléchargement du pack a échoué."
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
		trace_online_state("download_failed", {
			selected_at = selected_at(songInfo),
			packId = packId,
			packName = packName,
			generation = downloadGeneration,
			message = message,
			broadcastMissing = broadcastMissing ~= false,
			downloadKey = self.downloadInFlightKey or "",
			activeDownloadId = self.activeDownloadId or "",
		})
		self.downloadInFlightKey = nil
		self.downloadStartedAt = nil
		self.downloadLastByteAt = nil
		self.downloadLastByteCount = nil
		if browseOnly then self.activeBrowseOnlyDownload = false end
		self:UpdateStatus(self.status.DownloadFailed, message)
		remove_directory_if_possible(quarantinePath)
		if not browseOnly and broadcastMissing ~= false and MESSAGEMAN and self:SongInfoMatchesCurrentSelection(songInfo) then
			MESSAGEMAN:Broadcast("OnlineMissingSong", { songInfo = songInfo, reason = "download_failed" })
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
		if callback then callback(true) end
		return true
	end

	NETWORK:HttpRequest({
		url = url,
		method = "GET",
		downloadFile = fileName,
		connectTimeout = 15,
		transferTimeout = 600,
		maxDownloadBytes = maxDownloadBytes,
		-- Keep the zip until we explicitly unzip/cleanup it. If removed too early,
		-- the post-download check will falsely report "file missing".
		deleteDownloadAfterResponse = false,
		onFileError = function(errorMessage)
			if not self:IsDownloadGenerationCurrent(downloadGeneration) then return end
			if downloadCompleted then return end
			trace("Download file error pack=" .. tostring(packName) .. " err=" .. tostring(errorMessage))
			fail_candidate_download("Erreur d'écriture du fichier téléchargé: " .. tostring(errorMessage or "unknown error"))
		end,
		onProgress = function(current, total)
			if not self:IsDownloadGenerationCurrent(downloadGeneration) then return false end
			if downloadCompleted then return false end
			if not current_user_is_active_room_member() then
				trace("Download aborted reason=not_active_room_member pack=" .. tostring(packName))
				fail_candidate_download("Vous n'etes plus dans le salon.", false)
				return false
			end
			local now = GetTimeSinceStart and GetTimeSinceStart() or 0
			if self.downloadStartedAt == nil then
				self.downloadStartedAt = now
				self.downloadLastByteAt = now
				self.downloadLastByteCount = tonumber(current) or 0
			end

			local currentBytes = tonumber(current) or 0
			if currentBytes > (tonumber(self.downloadLastByteCount) or 0) then
				self.downloadLastByteCount = currentBytes
				self.downloadLastByteAt = now
			end
			if now - (tonumber(self.downloadLastByteAt) or now) >= 45 then
				trace("Download stalled for 45s, aborting pack=" .. tostring(packName))
				fail_candidate_download("Le téléchargement du pack n'a pas progressé depuis 45 secondes.")
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
		end,
		onResponse = function(response)
			trace("Download response pack=" .. tostring(packName)
				.. " id=" .. tostring(packId)
				.. " generation=" .. tostring(downloadGeneration)
				.. " statusCode=" .. tostring(response and response.statusCode or "nil")
				.. " completed=" .. tostring(downloadCompleted == true)
				.. " currentGeneration=" .. tostring(self.downloadGeneration))
			if not self:IsDownloadGenerationCurrent(downloadGeneration) then
				trace("Download response ignored reason=stale_generation pack=" .. tostring(packName)
					.. " generation=" .. tostring(downloadGeneration)
					.. " current=" .. tostring(self.downloadGeneration))
				return
			end
			if downloadCompleted then return end
			if not current_user_is_active_room_member() then
				trace("Download response ignored reason=not_active_room_member pack=" .. tostring(packName))
				fail_candidate_download("Vous n'etes plus dans le salon.", false)
				return
			end
			self.downloadStartedAt = nil
			self.downloadLastByteAt = nil
			self.downloadLastByteCount = nil
			local statusCode = tonumber(response and response.statusCode) or 0
			if statusCode < 200 or statusCode >= 300 then
				local message = "Le téléchargement du pack a échoué."
				trace("Download failed status=" .. tostring(statusCode))
				fail_candidate_download(message)
				return
			end
			self:UpdateStatus(self.status.DownloadInProgress, downloadMessage, 100)

			local zipPath = "/Downloads/" .. fileName
			if not FILEMAN:DoesFileExist(zipPath) then
				trace("Download failed missing zip pack=" .. tostring(packName)
					.. " zipPath=" .. tostring(zipPath)
					.. " fileName=" .. tostring(fileName))
				fail_candidate_download("Le fichier téléchargé est introuvable.")
				return
			end

			remove_directory_if_possible(quarantinePath)
			remove_directory_if_possible(legacy_online_downloads_root())
			create_directory_if_possible(quarantinePath)
			trace("Download unzip begin pack=" .. tostring(packName)
				.. " zipPath=" .. tostring(zipPath)
				.. " quarantine=" .. tostring(quarantinePath))
			local extracted = FILEMAN:Unzip(zipPath, quarantinePath, 0)
			if not extracted then
				remove_path_if_exists(zipPath)
				remove_directory_if_possible(quarantinePath)
				trace("Download failed unzip pack=" .. tostring(packName))
				fail_candidate_download("Le zip téléchargé est invalide ou impossible à extraire.")
				return
			end
			flush_dir_cache("/Songs/")
			flush_dir_cache(quarantinePath)
			log_dir_listing("Extracted quarantine", quarantinePath)

			local installedPath, installError = install_extracted_pack_at_songs_root(quarantinePath, packName)
			if not installedPath then
				remove_path_if_exists(zipPath)
				remove_directory_if_possible(quarantinePath)
				trace("Download failed install pack=" .. tostring(packName) .. " reason=" .. tostring(installError))
				fail_candidate_download(installError or "Impossible d'installer le pack téléchargé.")
				return
			end
			remove_path_if_exists(zipPath)

			trace("Reload Songs after download pack=" .. tostring(packName))
			self.pendingPostReloadSongInfo = songInfo
			self.pendingQuarantinePath = installedPath
			self.pendingPostReloadBrowseOnly = browseOnly
			self:UpdateStatus(self.status.ReloadingSongs, "Rechargement des chansons")
			transition_to_reload_songs()
			finish_candidate_download()
		end,
	})
end

function PackSync:DownloadSelectedPack(songInfo, callback)
	songInfo = with_current_room_selection(songInfo, "download_selected")
	trace("DownloadSelectedPack begin title=" .. tostring(selected_title(songInfo))
		.. " pack=" .. tostring(selected_pack(songInfo))
		.. " status=" .. tostring(self.currentStatus or "nil")
		.. " key=" .. tostring(self.downloadInFlightKey or ""))
	if not songInfo then
		trace("DownloadSelectedPack blocked reason=no_song_info")
		if callback then callback(false, "Aucune chanson selectionnee.") end
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
		if callback then callback(false, "Vous n'etes plus dans le salon.") end
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
		self:UpdateStatus(self.status.DownloadFailed, message)
		if callback then callback(false, message) end
	end

	self:UpdateStatus(self.status.DownloadRequested, nil)
	self:SearchStepManiaOnline(songInfo, function(ok, pack, searchError)
		trace("DownloadSelectedPack search_result ok=" .. tostring(ok == true)
			.. " packId=" .. tostring(pack and pack.id or "nil")
			.. " packName=" .. tostring(pack and pack.name or "nil")
			.. " candidates=" .. tostring(searchError and searchError.candidates and #searchError.candidates or 0)
			.. " generation=" .. tostring(downloadGeneration)
			.. " currentGeneration=" .. tostring(self.downloadGeneration))
		if not self:IsDownloadGenerationCurrent(downloadGeneration) then
			trace("DownloadSelected search result ignored reason=stale_generation generation="
				.. tostring(downloadGeneration) .. " current=" .. tostring(self.downloadGeneration))
			return
		end
		if not current_user_is_active_room_member() then
			trace("DownloadSelectedPack cancelled after search reason=not_active_room_member")
			fail_download("Vous n'etes plus dans le salon.")
			return
		end
		if not ok or not pack or not pack.id then
			if searchError and type(searchError.candidates) == "table" and #searchError.candidates > 0 then
				trace("Download selection required candidates=" .. tostring(#searchError.candidates))
				self:UpdateStatus(self.status.DownloadRequested, "Choisissez le pack a telecharger")
				if callback then
					callback(false, {
						kind = "pack_candidates",
						message = searchError.errorMessage or "Plusieurs packs correspondent à cette chanson.",
						candidates = searchError.candidates,
						downloadKey = downloadKey,
					})
				end
				return
			end
			local message = searchError and searchError.errorMessage or "La recherche de pack StepManiaOnline a echoue."
			trace("Download failed search=" .. tostring(message))
			fail_download(message)
			return
		end
		self:DownloadPackByCandidate(songInfo, pack, function(downloadOk, downloadMessage)
			trace("DownloadSelectedPack candidate_callback ok=" .. tostring(downloadOk == true)
				.. " message=" .. tostring(downloadMessage or "")
				.. " generation=" .. tostring(downloadGeneration)
				.. " currentGeneration=" .. tostring(self.downloadGeneration))
			if not self:IsDownloadGenerationCurrent(downloadGeneration) then return end
			if downloadOk then
				if callback then callback(true) end
				return
			end
			self.downloadInFlightKey = nil
			if callback then callback(false, downloadMessage or "Le téléchargement du pack a échoué.") end
		end, { allowExistingDownloadKey = downloadKey, downloadGeneration = downloadGeneration })
	end)
end

function PackSync:DownloadBrowsingPack(songInfo, callback)
	songInfo = with_current_room_selection(songInfo, "download_browsing")
	trace("DownloadBrowsingPack begin title=" .. tostring(selected_title(songInfo))
		.. " pack=" .. tostring(selected_pack(songInfo))
		.. " status=" .. tostring(self.currentStatus or "nil")
		.. " key=" .. tostring(self.downloadInFlightKey or ""))
	if not songInfo then
		trace("DownloadBrowsingPack blocked reason=no_song_info")
		if callback then callback(false, "Aucun pack a telecharger.") end
		return
	end
	trace("DownloadBrowsingPack begin title=" .. tostring(selected_title(songInfo))
		.. " pack=" .. tostring(selected_pack(songInfo))
		.. " selected_at=" .. tostring(selected_at(songInfo))
		.. " currentKey=" .. tostring(self.downloadInFlightKey or "")
		.. " room=" .. tostring(ITGOnline and ITGOnline.currentRoomId or "nil")
		.. " phase=" .. tostring(ITGOnline and ITGOnline.currentRoom and ITGOnline.currentRoom.phase or "nil"))
	if not current_user_is_active_room_member() then
		trace("DownloadBrowsingPack blocked reason=not_active_room_member"
			.. " room=" .. tostring(ITGOnline and ITGOnline.currentRoomId or "nil")
			.. " hasRoom=" .. tostring(ITGOnline and ITGOnline.currentRoom ~= nil)
			.. " hasUser=" .. tostring(ITGOnline and ITGOnline.user ~= nil))
		if callback then callback(false, "Vous n'etes plus dans le salon.") end
		return
	end

	if trim(self.downloadInFlightKey) ~= "" then
		local message = download_already_in_progress_message()
		trace(message .. " key=" .. tostring(self.downloadInFlightKey)
			.. " requestedPack=" .. tostring(selected_pack(songInfo))
			.. " requestedTitle=" .. tostring(selected_title(songInfo)))
		if callback then callback(false, message) end
		return
	end
	self.currentSongInfo = songInfo
	self.activeBrowseOnlyDownload = true
	local packName = selected_pack(songInfo)
	local downloadKey = "browse|" .. (packName ~= "" and packName or (selected_title(songInfo) .. "|" .. selected_artist(songInfo)))
	if downloadKey == "browse|" then downloadKey = "browse|" .. tostring(songInfo) end

	self.downloadInFlightKey = downloadKey
	local downloadGeneration = self:NextDownloadGeneration("download_browsing_search")
	local function fail_download(message)
		if not self:IsDownloadGenerationCurrent(downloadGeneration) then
			trace("DownloadBrowsing failure ignored reason=stale_generation generation="
				.. tostring(downloadGeneration) .. " current=" .. tostring(self.downloadGeneration))
			return
		end
		self.downloadInFlightKey = nil
		self.activeBrowseOnlyDownload = false
		self.downloadStartedAt = nil
		self.downloadLastByteAt = nil
		self.downloadLastByteCount = nil
		self.pendingPostReloadBrowseOnly = false
		self:UpdateStatus(self.status.DownloadFailed, message)
		if callback then callback(false, message) end
	end

	self:UpdateStatus(self.status.DownloadRequested, nil)
	self:SearchStepManiaOnline(songInfo, function(ok, pack, searchError)
		trace("DownloadBrowsingPack search_result ok=" .. tostring(ok == true)
			.. " packId=" .. tostring(pack and pack.id or "nil")
			.. " packName=" .. tostring(pack and pack.name or "nil")
			.. " candidates=" .. tostring(searchError and searchError.candidates and #searchError.candidates or 0)
			.. " generation=" .. tostring(downloadGeneration)
			.. " currentGeneration=" .. tostring(self.downloadGeneration))
		if not self:IsDownloadGenerationCurrent(downloadGeneration) then
			trace("DownloadBrowsing search result ignored reason=stale_generation generation="
				.. tostring(downloadGeneration) .. " current=" .. tostring(self.downloadGeneration))
			return
		end
		if not current_user_is_active_room_member() then
			trace("DownloadBrowsingPack cancelled after search reason=not_active_room_member")
			fail_download("Vous n'etes plus dans le salon.")
			return
		end
		if not ok or not pack or not pack.id then
			if searchError and type(searchError.candidates) == "table" and #searchError.candidates > 0 then
				trace("Browse download selection required candidates=" .. tostring(#searchError.candidates))
				self:UpdateStatus(self.status.DownloadRequested, "Choisissez le pack a telecharger")
				if callback then
					callback(false, {
						kind = "pack_candidates",
						message = searchError.errorMessage or "Plusieurs packs correspondent a ce pack.",
						candidates = searchError.candidates,
						browseOnly = true,
						downloadKey = downloadKey,
					})
				end
				return
			end
			local message = searchError and searchError.errorMessage or "La recherche de pack StepManiaOnline a echoue."
			trace("Browse download failed search=" .. tostring(message))
			fail_download(message)
			return
		end
		self:DownloadPackByCandidate(songInfo, pack, function(downloadOk, downloadMessage)
			trace("DownloadBrowsingPack candidate_callback ok=" .. tostring(downloadOk == true)
				.. " message=" .. tostring(downloadMessage or "")
				.. " generation=" .. tostring(downloadGeneration)
				.. " currentGeneration=" .. tostring(self.downloadGeneration))
			if not self:IsDownloadGenerationCurrent(downloadGeneration) then return end
			if downloadOk then
				if callback then callback(true) end
				return
			end
			self.downloadInFlightKey = nil
			self.activeBrowseOnlyDownload = false
			if callback then callback(false, downloadMessage or "Le telechargement du pack a echoue.") end
		end, { browseOnly = true, allowExistingDownloadKey = downloadKey, downloadGeneration = downloadGeneration })
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

function PackSync:ValidatePendingPostReload()
	local songInfo = self.pendingPostReloadSongInfo
	local quarantinePath = self.pendingQuarantinePath
	local browseOnly = self.pendingPostReloadBrowseOnly == true
	local packName = selected_pack(songInfo)
	trace("ValidatePendingPostReload begin hasSong=" .. tostring(songInfo ~= nil)
		.. " browseOnly=" .. tostring(browseOnly == true)
		.. " pack=" .. tostring(packName)
		.. " quarantine=" .. tostring(quarantinePath or "nil")
		.. " room=" .. tostring(ITGOnline and ITGOnline.currentRoomId or "nil")
		.. " phase=" .. tostring(ITGOnline and ITGOnline.currentRoom and ITGOnline.currentRoom.phase or "nil"))
	self.pendingPostReloadSongInfo = nil
	self.pendingQuarantinePath = nil
	self.pendingPostReloadBrowseOnly = false
	self.downloadInFlightKey = nil
	self:ClearActiveDownloadId("post_reload_validation_begin")
	if not songInfo then
		trace("ValidatePendingPostReload skipped reason=no_pending_song")
		return false
	end

	self:InvalidateLocalChartIndex()
	if browseOnly then
		self.activeBrowseOnlyDownload = false
		trace("PostReload browse-only pack download complete quarantine=" .. tostring(quarantinePath or ""))
		if quarantinePath and quarantinePath ~= "" then
			log_dir_listing("PostReload browse-only pack", quarantinePath)
		end
		if not browse_pack_reload_validated(songInfo, quarantinePath) then
			trace("Browse-only pack download did not expose the expected pack after reload")
			remove_directory_if_possible(quarantinePath)
			self:UnmarkPackInstalled(packName, "browse_reload_validation_failed")
			self:UpdateStatus(self.status.DownloadFailed, "Le pack telecharge n'a pas ete trouve apres reload.")
			if MESSAGEMAN then
				MESSAGEMAN:Broadcast("OnlinePackDownloadFailed", { songInfo = songInfo, reason = "download_failed" })
			end
			return false
		end
		self:MarkPackInstalled(packName)
		self:UpdateStatus(self.status.DownloadedOk, "Pack telecharge. En attente du choix de chanson du manager.")
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
	local result = self:FindLocalMatch(songInfo)
	self.validatingPostReload = false
	trace("PostReload local match result ok=" .. tostring(result and result.ok == true)
		.. " status=" .. tostring(result and result.status or "nil")
		.. " reason=" .. tostring(result and result.reason or "nil")
		.. " quarantine=" .. tostring(quarantinePath or "nil"))
	if result.ok then
		local songDir = result.song and result.song.GetSongDir and tostring(result.song:GetSongDir() or "") or ""
		if quarantinePath and quarantinePath ~= "" and songDir:sub(1, #quarantinePath) ~= quarantinePath then
			trace("Downloaded pack did not contain the selected chart; matched existing local chart instead")
			remove_directory_if_possible(quarantinePath)
			self:UnmarkPackInstalled(packName, "selected_chart_not_in_downloaded_pack")
			self:UpdateStatus(self.status.DownloadFailed, "Le pack téléchargé ne contient pas la stepchart attendue.")
			if MESSAGEMAN and self:SongInfoMatchesCurrentSelection(songInfo) then
				MESSAGEMAN:Broadcast("OnlineMissingSong", { songInfo = songInfo, reason = "download_failed" })
			end
			return false
		end
		set_current_selection(result.song, result.steps)
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
			self:UpdateStatus(self.status.DownloadedOk, "Pack telecharge. En attente du choix de chanson du manager.")
			if MESSAGEMAN then
				MESSAGEMAN:Broadcast("OnlinePackDownloaded", { songInfo = songInfo, staleSelection = true })
			end
			if currentSelectedSong and currentSelectedAt ~= "" then
				trace("Applying current manager selection after stale-selection download completion"
					.. " currentSelectedAt=" .. tostring(currentSelectedAt)
					.. " currentTitle=" .. tostring(selected_title(currentSelectedSong))
					.. " currentPack=" .. tostring(selected_pack(currentSelectedSong)))
				self:ApplySelectedChart(currentSelectedSong)
			end
			return true
		end

		self:UpdateStatus(self.status.DownloadedOk, nil)
		if ITGOnline and ITGOnline.ConfirmSelectedSongAvailability then
			ITGOnline:ConfirmSelectedSongAvailability("downloaded_ok", function(ok)
				trace("PostReload availability confirmed ok=" .. tostring(ok == true)
					.. " source=downloaded_ok")
				if ok then
					self:UpdateStatus(self.status.Ready, nil)
					self:MarkLobbyReadyForSelectedSong("downloaded_ok")
				end
			end)
		else
			self:UpdateStatus(self.status.Ready, nil)
			self:MarkLobbyReadyForSelectedSong("downloaded_ok_no_client_confirm")
		end
		MESSAGEMAN:Broadcast("OnlineSongAvailable", { songInfo = songInfo })
		return true
	end

	if result.status == "mismatch" then
		self:UpdateStatus(self.status.ChartMismatch, "La musique ou la stepchart trouvée est différente de celle du manager.")
		remove_directory_if_possible(quarantinePath)
		self:UnmarkPackInstalled(packName, "chart_mismatch")
		if ITGOnline and ITGOnline.ReportSongAvailability and self:SongInfoMatchesCurrentSelection(songInfo) then
			ITGOnline:ReportSongAvailability(true, "chart_mismatch")
		end
		if MESSAGEMAN and self:SongInfoMatchesCurrentSelection(songInfo) then
			MESSAGEMAN:Broadcast("OnlineMissingSong", { songInfo = songInfo, reason = "chart_mismatch", chartMismatch = true })
		end
	else
		self:UpdateStatus(self.status.DownloadFailed, "La chanson est introuvable après reload.")
		remove_directory_if_possible(quarantinePath)
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
	end
	return false
end

OnlinePackSyncManager = PackSync
OnlineLocalChartMatcher = PackSync
OnlinePackSearchClient = PackSync
OnlinePackDownloadService = PackSync
OnlineChartHashService = PackSync
