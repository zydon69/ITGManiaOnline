-- -----------------------------------------------------------------------
-- Online Pack Sync
--
-- Finds the manager-selected chart locally by hash, reports per-player
-- synchronization state, and downloads missing packs from StepManiaOnline
-- only after a selected chart cannot be matched locally.

ITGOnline = ITGOnline or {}
ITGOnline.PackSync = ITGOnline.PackSync or {}

local PackSync = ITGOnline.PackSync

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
	unknown = "Ready",
	ready = "Ready",
	manager_browsing_unknown_pack = "Browsing unknown pack",
	searching_local_charts = "Searching local charts",
	local_chart_match_found = "Compatible chart found",
	no_compatible_chart_found = "No compatible chart found",
	download_requested = "Download requested",
	download_in_progress = "Download in progress",
	download_failed = "Download failed",
	reloading_songs = "Reloading songs",
	downloaded_ok = "Downloaded OK",
	chart_mismatch = "Chart mismatch",
}

local function trace(message)
	local line = "[OnlinePackSync] " .. tostring(message or "")
	if Trace then Trace(line) elseif Warn then Warn(line) end
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
	return trim(songInfo and (songInfo.chartKey or songInfo.chart_key))
end

local function selected_at(songInfo)
	return trim(songInfo and (songInfo.selectedAt or songInfo.selected_at))
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
	if not topScreen then return end

	if topScreen:GetName() == "ScreenReloadSongsOnline" then
		return
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

function PackSync:UpdateStatus(status, message, progress, callback)
	status = tostring(status or self.status.Unknown)
	local currentSelectedAt = selected_at(self.currentSongInfo)
	if self.lastSelectedAt ~= currentSelectedAt then
		self.sequence = 0
		self.lastSelectedAt = currentSelectedAt
	end

	self:SyncSequenceFromRoom(currentSelectedAt)
	self.sequence = (tonumber(self.sequence) or 0) + 1
	message = status_message(message)
	trace("Status " .. status .. (message and (" - " .. tostring(message)) or ""))

	if not (ITGOnline and ITGOnline.Request and ITGOnline.currentRoomId) then
		if callback then callback(false, nil, { errorMessage = "No active online room." }) end
		return
	end

	local payload = {
		status = status,
		message = message,
		download_progress = progress,
		sequence = self.sequence,
	}
	if self.currentSongInfo then
		if currentSelectedAt ~= "" then
			payload.selected_at = currentSelectedAt
		end
	end

	ITGOnline:Request("POST", "/rooms/" .. tostring(ITGOnline.currentRoomId) .. "/pack-sync-status", payload, function(ok, decoded, response)
		if ok and decoded and decoded.room and ITGOnline.ApplyRoomSnapshot then
			ITGOnline:ApplyRoomSnapshot(decoded.room, "pack_sync_status")
			MESSAGEMAN:Broadcast("OnlineLobbyState", ITGOnline:LobbyStatePayload(decoded.room))
		end
		if callback then callback(ok, decoded, response) end
	end)
end

function PackSync:SyncSequenceFromRoom(currentSelectedAt)
	if not (ITGOnline and ITGOnline.currentRoom and ITGOnline.user) then return end
	local selectedSong = ITGOnline.currentRoom.selected_song or {}
	if selected_at(selectedSong) ~= currentSelectedAt then return end

	local currentUserId = tostring(ITGOnline.user.id or "")
	if currentUserId == "" then return end

	for member in ivalues(ITGOnline.currentRoom.members or {}) do
		local user = member.user or {}
		local memberUserId = tostring(user.id or member.user_id or "")
		if memberUserId == currentUserId then
			local serverSequence = tonumber(member.pack_sync_sequence)
			if serverSequence and serverSequence > (tonumber(self.sequence) or 0) then
				self.sequence = serverSequence
			end
			return
		end
	end
end

function PackSync:InvalidateLocalChartIndex()
	self.localChartIndex = nil
	self.localChartIndexKey = nil
end

function PackSync:LocalChartIndex()
	local key = song_count_key()
	if self.localChartIndex and self.localChartIndexKey == key then
		return self.localChartIndex
	end

	local index = {}
	if SONGMAN and SONGMAN.GetAllSongs then
		for song in ivalues(SONGMAN:GetAllSongs()) do
			for steps in ivalues(playable_steps(song)) do
				local hash = normalized_hash(chart_hash_for_steps(steps))
				if hash ~= "" then
					index[hash] = index[hash] or {}
					index[hash][#index[hash] + 1] = { song = song, steps = steps }
				end
			end
		end
	end

	self.localChartIndex = index
	self.localChartIndexKey = key
	return index
end

function PackSync:ManagerBrowsingPreview(songInfo)
	if not songInfo then return end
	if selected_pack(songInfo) ~= "" and SONGMAN and SONGMAN.DoesSongGroupExist and not SONGMAN:DoesSongGroupExist(selected_pack(songInfo)) then
		self.currentSongInfo = nil
		self:UpdateStatus(self.status.ManagerBrowsingUnknownPack, "Le manager navigue dans un pack que vous ne possédez pas.")
	end
end

function PackSync:FindLocalMatch(songInfo)
	if not songInfo then
		return { ok = false, status = "missing", reason = "missing_local_song" }
	end

	self.currentSongInfo = songInfo
	trace("Searching local charts title=" .. selected_title(songInfo) .. " pack=" .. selected_pack(songInfo))
	self:UpdateStatus(self.status.SearchingLocalCharts, nil)

	local expectedChartHash = selected_chart_hash(songInfo)
	if expectedChartHash == "" then
		return { ok = false, status = "missing", reason = "chart_hash_mismatch" }
	end

	local exactPath = selected_path(songInfo)
	local exactSong = exactPath ~= "" and SONGMAN:FindSong(exactPath) or nil
	if not exactSong and exactPath ~= "" then
		local parts = exactPath:split("/")
		if parts and parts[2] then exactSong = SONGMAN:FindSong(parts[2]) end
	end

	local mismatchReason = nil
	local function evaluate_candidate(song, source)
		local steps = matching_steps_in_song(song, songInfo)
		if not steps then return nil end

		trace("Candidate chart found " .. tostring(source or song:GetSongDir()))
		local payload = build_payload(song, steps)
		local payloadOk, reason = payload_matches_selected(payload, songInfo)
		if payloadOk then
			trace("Matching local chart found " .. tostring(source or song:GetSongDir()))
			self:UpdateStatus(self.status.LocalChartMatchFound, nil)
			return { ok = true, song = song, steps = steps, payload = payload }
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
	for candidate in ivalues(indexedCandidates) do
		if candidate.song ~= exactSong and not song_matches_text_prefilter(candidate.song, songInfo) then
			trace("Candidate chart found via hash index " .. tostring(candidate.song:GetSongDir()))
			local payload = build_payload(candidate.song, candidate.steps)
			local payloadOk, reason = payload_matches_selected(payload, songInfo)
			if payloadOk then
				trace("Matching local chart found via hash index " .. tostring(candidate.song:GetSongDir()))
				self:UpdateStatus(self.status.LocalChartMatchFound, nil)
				return { ok = true, song = candidate.song, steps = candidate.steps, payload = payload }
			end
			mismatchReason = mismatchReason or reason or "chart_mismatch"
		end
	end

	if mismatchReason then
		local message = mismatchReason == "song_hash_mismatch"
			and "La stepchart existe localement, mais l'audio differe de celui du manager."
			or "La musique ou la stepchart trouvée est différente de celle du manager."
		self:UpdateStatus(self.status.ChartMismatch, message)
		return { ok = false, status = "mismatch", reason = mismatchReason }
	end

	trace("No compatible chart found title=" .. selected_title(songInfo))
	self:UpdateStatus(self.status.NoCompatibleChartFound, "Aucune stepchart identique à celle du manager n’a été trouvée.")
	return { ok = false, status = "missing", reason = "no_compatible_chart_found" }
end

function PackSync:ApplySelectedChart(songInfo)
	local result = self:FindLocalMatch(songInfo)
	if result.ok then
		set_current_selection(result.song, result.steps)
		MESSAGEMAN:Broadcast("OnlineSongAvailable", { songInfo = songInfo })
		if ITGOnline and ITGOnline.ConfirmSelectedSongAvailability then
			ITGOnline:ConfirmSelectedSongAvailability("local_chart_match_found", function(ok)
				if ok then self:UpdateStatus(self.status.Ready, nil) end
			end)
		else
			self:UpdateStatus(self.status.Ready, nil)
		end
		return true
	end

	local reason = result.reason or "missing_local_song"
	if result.status == "mismatch" then
		MESSAGEMAN:Broadcast("OnlineMissingSong", { songInfo = songInfo, reason = reason, chartMismatch = true })
	else
		MESSAGEMAN:Broadcast("OnlineMissingSong", { songInfo = songInfo, reason = reason, noCompatibleChart = true })
	end
	return false
end

local function stepmaniaonline_origin()
	return "https://www.stepmaniaonline.net"
end

local function request_json(url, callback)
	NETWORK:HttpRequest({
		url = url,
		method = "GET",
		connectTimeout = 10,
		transferTimeout = 20,
		onResponse = function(response)
			if (tonumber(response and response.statusCode) or 0) ~= 200 then
				callback(false, nil, response)
				return
			end
			local ok, decoded = pcall(JsonDecode, response.body or "")
			callback(ok and decoded ~= nil, decoded, response)
		end,
	})
end

local function path_escape(value)
	return tostring(value or ""):gsub("([^%w%._:%-])", function(char)
		return string.format("%%%02X", string.byte(char))
	end)
end

function PackSync:SearchStepManiaOnline(songInfo, callback)
	local origin = stepmaniaonline_origin()
	local function search(queryType, query, cb)
		local encoded = NETWORK:EncodeQueryParameters({ type = queryType, query = query })
		request_json(origin .. "/api/search/?" .. encoded, cb)
	end

	local pack = selected_pack(songInfo)
	local title = selected_title(songInfo)
	local artist = lower(selected_artist(songInfo))
	local chartKey = selected_chart_key(songInfo)

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
		if #candidates == 1 then
			callback(true, candidates[1])
			return
		end
		callback(false, nil, { errorMessage = #candidates == 0 and "No StepManiaOnline pack matched." or "StepManiaOnline pack search is ambiguous." })
	end

	local function finish_title_results(decoded)
		decoded = decoded or { results = {} }
		if artist == "" then
			finish_with_results(decoded)
			return
		end

		search("artist", artist, function(artistOk, artistDecoded)
			if not artistOk then
				callback(false, nil, { errorMessage = "StepManiaOnline artist search failed." })
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
		request_json(origin .. "/api/chart/key/" .. path_escape(chartKey), function(ok, chartDecoded)
			if ok and chartDecoded then
				local chartPack = choose_chart_key_pack(chartDecoded)
				if chartPack and chartPack.id then
					callback(true, chartPack)
					return
				end
				local commonPacks = chartDecoded.common_packs or {}
				if #commonPacks > 1 and pack == "" then
					callback(false, nil, { errorMessage = "StepManiaOnline chart key matched multiple packs." })
					return
				end
				callback(false, nil, { errorMessage = "StepManiaOnline chart key did not match the selected pack." })
				return
			end
			self:SearchStepManiaOnline({
				title = title,
				artist = artist,
				pack = pack,
				songPath = selected_path(songInfo),
			}, callback)
		end)
	elseif pack ~= "" then
		search("pack", pack, function(ok, decoded)
			if ok and decoded and decoded.results and #decoded.results == 1 and lower(decoded.results[1].name) == lower(pack) then
				callback(true, decoded.results[1])
				return
			end
			if title == "" then finish_with_results(decoded); return end
			search("title", title, function(titleOk, titleDecoded)
				if not titleOk then callback(false, nil, { errorMessage = "StepManiaOnline title search failed." }); return end
				finish_title_results(titleDecoded)
			end)
		end)
	elseif title ~= "" then
		search("title", title, function(ok, decoded)
			if not ok then callback(false, nil, { errorMessage = "StepManiaOnline title search failed." }); return end
			finish_title_results(decoded)
		end)
	else
		callback(false, nil, { errorMessage = "No pack or title available for StepManiaOnline search." })
	end
end

function PackSync:DownloadSelectedPack(songInfo, callback)
	if not songInfo then
		if callback then callback(false, "No selected song.") end
		return
	end

	self.currentSongInfo = songInfo
	local downloadKey = selected_at(songInfo)
	if downloadKey == "" then
		downloadKey = selected_chart_hash(songInfo) .. "|" .. selected_path(songInfo)
	end
	if downloadKey == "" then downloadKey = tostring(songInfo) end
	if self.downloadInFlightKey == downloadKey then
		local message = "Download already in progress."
		trace(message)
		if callback then callback(false, message) end
		return
	end

	self.downloadInFlightKey = downloadKey
	local function fail_download(message)
		self.downloadInFlightKey = nil
		self:UpdateStatus(self.status.DownloadFailed, message)
		if callback then callback(false, message) end
	end

	self:UpdateStatus(self.status.DownloadRequested, nil)
	self:SearchStepManiaOnline(songInfo, function(ok, pack, searchError)
		if not ok or not pack or not pack.id then
			local message = searchError and searchError.errorMessage or "StepManiaOnline pack search failed."
			trace("Download failed search=" .. tostring(message))
			fail_download(message)
			return
		end

		local packId = tonumber(pack.id)
		if not packId or math.floor(packId) ~= packId or packId < 1 then
			fail_download("StepManiaOnline returned an invalid pack id.")
			return
		end

		local fileName = tostring(packId) .. "_" .. safe_file_name(pack.name)
		local quarantinePath = "/Songs/Online Downloads/" .. safe_folder_name(pack.name) .. " " .. tostring(packId) .. "/"
		if FILEMAN:DoesFileExist(quarantinePath) then
			FILEMAN:DeleteRecursive(quarantinePath)
		end
		local url = stepmaniaonline_origin() .. "/download/pack/" .. tostring(packId) .. "/"
		local downloadMessage = "Downloading " .. tostring(pack.name)
		trace("Download started pack=" .. tostring(pack.name) .. " id=" .. tostring(packId))
		self:UpdateStatus(self.status.DownloadInProgress, downloadMessage, 0)
		self.lastProgressStatusAt = 0
		self.lastProgressValue = -10

		NETWORK:HttpRequest({
			url = url,
			method = "GET",
			downloadFile = fileName,
			connectTimeout = 15,
			transferTimeout = 600,
			maxDownloadBytes = 2 * 1024 * 1024 * 1024 - 1,
			deleteDownloadAfterResponse = true,
			onProgress = function(current, total)
				if tonumber(total) and tonumber(total) > 0 then
					local progress = math.max(0, math.min(100, math.floor((tonumber(current) or 0) * 100 / tonumber(total))))
					local now = GetTimeSinceStart and GetTimeSinceStart() or 0
					if progress >= 100 or progress - (tonumber(self.lastProgressValue) or -10) >= 10 or now - (tonumber(self.lastProgressStatusAt) or 0) >= 2 then
						self.lastProgressValue = progress
						self.lastProgressStatusAt = now
						self:UpdateStatus(self.status.DownloadInProgress, downloadMessage, progress)
					end
				end
				return true
			end,
			onResponse = function(response)
				local statusCode = tonumber(response and response.statusCode) or 0
				if statusCode < 200 or statusCode >= 300 then
					local message = "Le téléchargement du pack a échoué."
					trace("Download failed status=" .. tostring(statusCode))
					fail_download(message)
					return
				end

				local zipPath = "/Downloads/" .. fileName
				if not FILEMAN:DoesFileExist(zipPath) then
					fail_download("Le fichier téléchargé est introuvable.")
					return
				end

				local extracted = FILEMAN:Unzip(zipPath, quarantinePath, 0)
				if not extracted then
					local message = "Le zip téléchargé est invalide ou impossible à extraire."
					trace("Download failed unzip pack=" .. tostring(pack.name))
					fail_download(message)
					return
				end

				trace("Reload Songs after download pack=" .. tostring(pack.name))
				self.pendingPostReloadSongInfo = songInfo
				self.pendingQuarantinePath = quarantinePath
				self:UpdateStatus(self.status.ReloadingSongs, "Reloading songs")
				transition_to_reload_songs()
				if callback then callback(true) end
			end,
		})
	end)
end

function PackSync:ValidatePendingPostReload()
	local songInfo = self.pendingPostReloadSongInfo
	local quarantinePath = self.pendingQuarantinePath
	self.pendingPostReloadSongInfo = nil
	self.pendingQuarantinePath = nil
	self.downloadInFlightKey = nil
	if not songInfo then return false end

	self:InvalidateLocalChartIndex()
	local result = self:FindLocalMatch(songInfo)
	if result.ok then
		local songDir = result.song and result.song.GetSongDir and tostring(result.song:GetSongDir() or "") or ""
		if quarantinePath and quarantinePath ~= "" and songDir:sub(1, #quarantinePath) ~= quarantinePath then
			trace("Downloaded pack did not contain the selected chart; matched existing local chart instead")
			if FILEMAN and FILEMAN.DeleteRecursive then FILEMAN:DeleteRecursive(quarantinePath) end
			self:UpdateStatus(self.status.DownloadFailed, "Le pack téléchargé ne contient pas la stepchart attendue.")
			MESSAGEMAN:Broadcast("OnlineMissingSong", { songInfo = songInfo, reason = "download_failed" })
			return false
		end
		set_current_selection(result.song, result.steps)
		trace("Downloaded OK and local chart validated")
		self:UpdateStatus(self.status.DownloadedOk, nil)
		if ITGOnline and ITGOnline.ConfirmSelectedSongAvailability then
			ITGOnline:ConfirmSelectedSongAvailability("downloaded_ok", function(ok)
				if ok then self:UpdateStatus(self.status.Ready, nil) end
			end)
		else
			self:UpdateStatus(self.status.Ready, nil)
		end
		MESSAGEMAN:Broadcast("OnlineSongAvailable", { songInfo = songInfo })
		transition_to_player_options()
		return true
	end

	if result.status == "mismatch" then
		self:UpdateStatus(self.status.ChartMismatch, "La musique ou la stepchart trouvée est différente de celle du manager.")
		if quarantinePath and quarantinePath ~= "" and FILEMAN and FILEMAN.DeleteRecursive then FILEMAN:DeleteRecursive(quarantinePath) end
		if ITGOnline and ITGOnline.ReportSongAvailability then
			ITGOnline:ReportSongAvailability(true, "chart_mismatch")
		end
		MESSAGEMAN:Broadcast("OnlineMissingSong", { songInfo = songInfo, reason = "chart_mismatch", chartMismatch = true })
	else
		self:UpdateStatus(self.status.DownloadFailed, "La chanson est introuvable après reload.")
		if quarantinePath and quarantinePath ~= "" and FILEMAN and FILEMAN.DeleteRecursive then FILEMAN:DeleteRecursive(quarantinePath) end
		if ITGOnline and ITGOnline.ReportSongAvailability then
			ITGOnline:ReportSongAvailability(true, "download_failed")
		end
		MESSAGEMAN:Broadcast("OnlineMissingSong", { songInfo = songInfo, reason = "download_failed" })
	end
	return false
end

OnlinePackSyncManager = PackSync
OnlineLocalChartMatcher = PackSync
OnlinePackSearchClient = PackSync
OnlinePackDownloadService = PackSync
OnlineChartHashService = PackSync
