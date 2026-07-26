local sourceRoot = assert(arg[1], "source root is required")
local protocol = assert(dofile(sourceRoot .. "/Themes/Simply Love/Scripts/01 SL-ITGOnlineProtocol.lua"))

local function equal(actual, expected, label)
	assert(actual == expected, (label or "value") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
end

equal(protocol.canonical_decimal_id("00042"), "42", "leading zero ID")
equal(protocol.canonical_decimal_id("18446744073709551615"), "18446744073709551615", "uint64 max")
equal(protocol.canonical_decimal_id("18446744073709551616"), nil, "uint64 overflow")
equal(protocol.canonical_decimal_id("1e3"), nil, "scientific ID")
equal(protocol.canonical_decimal_id(-1), nil, "negative ID")
equal(protocol.canonical_decimal_id(9007199254740992), nil, "unsafe numeric ID")

equal(protocol.is_auth_retry_idempotent("GET", "/rooms/1", nil), true, "safe read retry")
equal(protocol.is_auth_retry_idempotent("POST", "/rooms/1/song-selection", {
	client_action_id = "selection:abc-123",
}), true, "declared selection retry")
equal(protocol.is_auth_retry_idempotent("POST", "/rooms/1/pack-downloads/authorize", {
	client_action_id = "pack-download-authorize:abc-123",
}), true, "declared pack download authorization retry")
equal(protocol.is_auth_retry_idempotent("POST", "/rooms/1/score", {
	client_action_id = "score:abc-123",
}), true, "declared final score retry")
equal(protocol.is_auth_retry_idempotent("POST", "/rooms/1/kick", {
	client_action_id = "invented-key",
}), true, "declared room command retry")
equal(protocol.is_auth_retry_idempotent("POST", "/rooms/1/invitations", {
	client_action_id = "invented-key",
}), false, "unknown mutation retry rejection")
equal(protocol.is_auth_retry_idempotent("POST", "/rooms/1/song-selection", {}), false, "missing action ID retry rejection")

equal(protocol.valid_round_key("183|selection:74e14e8e-ff1b-4fe6-b50d-ee201090b493"), true, "selection round key")
equal(protocol.valid_round_key("183|session-1|song-hash|chart-hash|2026-07-15T11:18:57Z"), true, "legacy round key")
equal(protocol.valid_round_key("183|selection:"), false, "empty selection ID")
equal(protocol.valid_round_key("bad-room|selection:uuid"), false, "invalid selection room ID")
equal(protocol.valid_round_key("183|selection:uuid|extra"), false, "selection key with trailing field")
equal(protocol.valid_round_key("183||||"), false, "incomplete legacy round key")

local expectedSongPayload = {
	song_hash = string.rep("a", 64),
	chart_hash = string.rep("b", 64),
	audio_file_hash = string.rep("a", 64),
	chart_file_hash = string.rep("c", 64),
	required_files = {
		{ path = "music/song.ogg", sha256 = string.rep("a", 64) },
		{ path = "chart/song.sm", sha256 = string.rep("c", 64) },
	},
}
local exactPayload = {
	song_hash = string.rep("a", 64),
	chart_hash = string.rep("b", 64),
	audio_file_hash = string.rep("a", 64),
	chart_file_hash = string.rep("c", 64),
	required_files = {
		{ path = "music/song.ogg", sha256 = string.rep("a", 64) },
		{ path = "chart/song.sm", sha256 = string.rep("c", 64) },
	},
}
local payloadMatches, payloadReason, fileVariances =
	protocol.selected_song_payload_matches(exactPayload, expectedSongPayload)
equal(payloadMatches, true, "exact selected-song payload")
equal(payloadReason, "matched", "exact selected-song payload reason")
equal(#fileVariances, 0, "exact selected-song payload variances")

local repackedPayload = {
	song_hash = string.rep("a", 64),
	chart_hash = string.rep("b", 64),
	audio_file_hash = string.rep("a", 64),
	chart_file_hash = string.rep("d", 64),
	required_files = {
		{ path = "music/song.ogg", sha256 = string.rep("a", 64) },
		{ path = "chart/song.sm", sha256 = string.rep("d", 64) },
	},
}
payloadMatches, payloadReason, fileVariances =
	protocol.selected_song_payload_matches(repackedPayload, expectedSongPayload)
equal(payloadMatches, true, "semantically identical repacked chart")
equal(payloadReason, "matched_with_file_variance", "repacked chart reason")
equal(fileVariances[1], "chart_file_hash", "repacked chart file variance")
equal(fileVariances[2], "required_file:chart/song.sm", "repacked manifest variance")

local differentChartPayload = {
	song_hash = string.rep("a", 64),
	chart_hash = string.rep("e", 64),
}
payloadMatches, payloadReason =
	protocol.selected_song_payload_matches(differentChartPayload, expectedSongPayload)
equal(payloadMatches, false, "different semantic chart")
equal(payloadReason, "chart_hash_mismatch", "different semantic chart reason")

local availabilityConfirmed, availabilityReason =
	protocol.song_availability_confirmation_state(true, {
		song_availability = { applied = true, missing = false },
	}, nil)
equal(availabilityConfirmed, true, "available song acknowledgement")
equal(availabilityReason, "selected_song_confirmed", "available song acknowledgement reason")

availabilityConfirmed, availabilityReason =
	protocol.song_availability_confirmation_state(true, {
		song_availability = { applied = true, missing = true },
	}, nil)
equal(availabilityConfirmed, false, "missing song acknowledgement")
equal(availabilityReason, "selected_song_missing", "missing song acknowledgement reason")

availabilityConfirmed, availabilityReason =
	protocol.song_availability_confirmation_state(false, {
		error_code = "song_availability_hash_mismatch",
	}, nil)
equal(availabilityConfirmed, false, "rejected song availability")
equal(availabilityReason, "song_availability_hash_mismatch", "rejected song availability reason")

local logged = protocol.safe_log_text("room\r\nforged", 32)
assert(not logged:find("\r") and not logged:find("\n"), "log controls must be removed")

local sensitiveLog = protocol.safe_log_text(
	'https://online.example/device?poll_token=query-secret#fragment '
		.. 'Authorization: Bearer bearer-secret access_token=access-secret refresh-token=refresh-secret '
		.. 'pollToken=poll-secret password=pass-secret email=player@example.test '
		.. 'local_party_id=party-secret '
		.. 'json={"apiKey":"json-secret","device_code":"device-secret"} '
		.. 'path=/Users/player/Library/Application Support/ITGmania/token.ini '
		.. 'windows=C:\\Users\\player\\token.ini',
	4096
)
for _, secret in ipairs({
	"query-secret", "fragment", "bearer-secret", "access-secret", "refresh-secret",
	"poll-secret", "pass-secret", "player@example.test", "party-secret", "json-secret", "device-secret", "player/Library",
}) do
	assert(not sensitiveLog:find(secret, 1, true), "sensitive log value leaked: " .. secret)
end
assert(sensitiveLog:find("https://online.example/device?<redacted>", 1, true), "URL route should remain diagnosable")
assert(sensitiveLog:find("<local-path>", 1, true), "local paths must be redacted")

local members = {}
for index = 1, 300 do members[index] = { user_id = tostring(index), user = { id = tostring(index), name = "player" } } end
members[1].local_party = {
	companion = { id = "2", display_name = "second player" },
}
local room = assert(protocol.normalize_room({
	id = "009",
	phase = "PLAYING",
	members = members,
	ready_states = {},
}))
equal(room.id, "9", "room ID")
equal(room.phase, "playing", "room phase")
equal(#room.members, 300, "complete member list")
equal(#room.ready_states, 0, "empty ready states")
equal(room.members[1].local_party.companion.id, "2", "room member local party companion ID")

local invalidCollection, invalidCollectionReason = protocol.normalize_room({
	id = "9",
	phase = "playing",
	ready_states = "invalid",
})
equal(invalidCollection, nil, "invalid collection rejection")
equal(invalidCollectionReason, "collection_not_table:room.ready_states", "invalid collection reason")

local cyclic = { id = "10", phase = "lobby" }
cyclic.self = cyclic
local normalizedCyclic, cyclicReason = protocol.normalize_room(cyclic)
equal(normalizedCyclic, nil, "cycle rejection")
equal(cyclicReason, "cyclic_table:room.self", "cycle reason")
local invalidRoom, invalidReason = protocol.normalize_room({ id = "not-an-id", phase = "lobby" })
equal(invalidRoom, nil, "invalid room")
equal(invalidReason, "invalid_decimal_id:room.id", "invalid room reason")

local missingPhase, missingPhaseReason = protocol.normalize_room({ id = "11" })
equal(missingPhase, nil, "missing phase rejection")
equal(missingPhaseReason, "invalid_room_phase", "missing phase reason")

local nonFiniteRoom, nonFiniteReason = protocol.normalize_room({
	id = "11",
	phase = "lobby",
	server_time_ms = math.huge,
})
equal(nonFiniteRoom, nil, "non-finite number rejection")
equal(nonFiniteReason, "non_finite_number:room.server_time_ms", "non-finite number reason")

local event = assert(protocol.normalize_event({
	id = "00017",
	event = "room.ready_updated",
	requires_ack = false,
	target = { id = "0009", type = "room" },
	payload = {
		room_id = "0009",
		room = { id = "0009", phase = "config", members = {}, ready_states = {} },
	},
}))
equal(event.id, "17", "event ID")
equal(event.target.id, "9", "nested target ID")
equal(event.payload.room_id, "9", "nested payload room ID")
equal(event.requires_ack, false, "event acknowledgement contract")

local invitationEvent = assert(protocol.normalize_event({
	id = "19",
	event = "room.invitation.created",
	payload = {
		invitation = { id = "7", room_id = "9", status = "pending" },
		inviter = { id = "3", name = "Inviting Player" },
		room = { id = "9", phase = "lobby", name = "Private room", visibility = "private" },
	},
}))
equal(invitationEvent.payload.room.phase, "lobby", "invitation room phase")
equal(invitationEvent.payload.inviter.name, "Inviting Player", "invitation inviter name")

local joinRequestEvent = assert(protocol.normalize_event({
	id = "20",
	event = "room.join_request.created",
	payload = {
		room_id = "9",
		join_request = { id = "8", room_id = "9", user_id = "4", status = "pending" },
		requester = { id = "4", name = "Requesting Player" },
		room = { id = "9", phase = "lobby", name = "Private room", visibility = "private" },
	},
}))
equal(joinRequestEvent.payload.room.phase, "lobby", "join request room phase")
equal(joinRequestEvent.payload.requester.name, "Requesting Player", "join request requester name")

local pendingJoinState = {
	current_room_id = nil,
	pending_join_room_id = "9",
	pending_join_request_id = "8",
}
local terminalMatches, terminalReason = protocol.pending_join_event_matches(pendingJoinState, {
	room_id = "9",
	join_request_id = "8",
	recipient_role = "requester",
})
equal(terminalMatches, true, "matching pending join terminal event")
equal(terminalReason, "request_match", "matching pending join terminal reason")

terminalMatches, terminalReason = protocol.pending_join_event_matches({
	current_room_id = "9",
	pending_join_room_id = "9",
	pending_join_request_id = "8",
}, {
	room_id = "9",
	join_request_id = "8",
	recipient_role = "requester",
})
equal(terminalMatches, false, "joined member must ignore terminal join event")
equal(terminalReason, "already_in_room", "joined member terminal rejection reason")

terminalMatches, terminalReason = protocol.pending_join_event_matches(pendingJoinState, {
	room_id = "9",
	join_request_id = "7",
	recipient_role = "requester",
})
equal(terminalMatches, false, "unrelated join request must be ignored")
equal(terminalReason, "request_mismatch", "unrelated join request rejection reason")

terminalMatches, terminalReason = protocol.pending_join_event_matches(pendingJoinState, {
	room_id = "9",
	join_request_id = "8",
	recipient_role = "manager",
})
equal(terminalMatches, false, "manager notification must not mutate requester state")
equal(terminalReason, "invalid_recipient_role", "manager notification rejection reason")

equal(protocol.online_player_room_label({
	id = "000205",
	name = "Private lobby",
	visibility = "private",
}), "Private lobby n°205", "private room player label")
equal(protocol.online_player_room_label({
	id = "206",
	name = "Public lobby",
	visibility = "public",
}), "Public lobby n°206", "public room player label")
equal(protocol.online_player_room_label({
	id = "000205",
	visibility = "private",
}, {
	private = "Salon privé",
	public = "Salon public",
	generic = "Salon",
}), "Salon privé n°205", "localized private room player label")
equal(protocol.online_player_room_label({
	id = "206",
	visibility = "public",
}, {}), "Public lobby n°206", "partial localization falls back safely")
equal(protocol.online_player_room_label(nil), "", "missing room player label")

local onlineLocalizationKeys = {}
for _, relativePath in ipairs({
	"Themes/Simply Love/BGAnimations/ScreenOnlineLobbies overlay/default.lua",
	"Themes/Simply Love/BGAnimations/ScreenOnlineLobbies overlay/LobbyInfo.lua",
	"Themes/Simply Love/BGAnimations/ScreenOnlineLobbies overlay/PackChoiceMenu.lua",
	"Themes/Simply Love/BGAnimations/ScreenOnlineLobbies overlay/PlayerActionMenu.lua",
	"Themes/Simply Love/BGAnimations/ScreenOnlineLobbies overlay/PrivateJoinPrompt.lua",
	"Themes/Simply Love/BGAnimations/ScreenGameplay overlay/OnlineLiveLeaderboard.lua",
	"Themes/Simply Love/Scripts/SL-OnlineHelpers.lua",
	"Themes/Simply Love/Scripts/SL-OnlinePackSync.lua",
	"Themes/Simply Love/Scripts/SL-ITGOnlineClient.lua",
}) do
	local path = sourceRoot .. "/" .. relativePath
	local file = assert(io.open(path, "rb"), "missing online localization source: " .. path)
	local content = file:read("*a")
	file:close()
	for helper in content:gmatch("online_lobby_text%s*%(%s*\"([%w_]+)\"") do
		onlineLocalizationKeys[helper] = true
	end
	for helper in content:gmatch("pack_text%s*%(%s*\"([%w_]+)\"") do
		onlineLocalizationKeys[helper] = true
	end
	for helper in content:gmatch("online_client_text%s*%(%s*\"([%w_]+)\"") do
		onlineLocalizationKeys[helper] = true
	end
	for helper in content:gmatch("THEME:GetString%s*%(%s*\"ScreenOnlineLobbies\"%s*,%s*\"([%w_]+)\"") do
		onlineLocalizationKeys[helper] = true
	end
end

for _, language in ipairs({ "de", "en", "es", "fr", "it", "ja", "pl", "pt-br", "ru" }) do
	local path = sourceRoot .. "/Themes/Simply Love/Languages/" .. language .. ".ini"
	local file = assert(io.open(path, "rb"), "missing language file: " .. path)
	local content = file:read("*a")
	file:close()
	local onlineSection = assert(content:match("%[ScreenOnlineLobbies%]%s*(.-)%s*%[ScreenITGOnlineUnlinkProfile%]"),
		language .. " is missing ScreenOnlineLobbies")
	local loginSection = assert(content:match("%[ScreenITGOnlineLogin%]%s*(.-)%s*%[ScreenOnlineLobbies%]"),
		language .. " is missing ScreenITGOnlineLogin")
	assert(loginSection:find("ShortCode=", 1, true), language .. " is missing ShortCode")
	for key in pairs(onlineLocalizationKeys) do
		assert(onlineSection:find("\n" .. key .. "=", 1, true) or onlineSection:find("^" .. key .. "="),
			language .. " is missing online localization key " .. key)
	end
	for _, key in ipairs({
		"PublicLobby",
		"PrivateLobby",
		"Lobby",
		"JoinRequestDeclined",
		"JoinRequestRetryCooldown",
		"JoinRequestExpired",
		"JoinRequestCancelled",
	}) do
		assert(content:find(key .. "=", 1, true), language .. " is missing " .. key)
	end
	assert(content:match("JoinRequestDeclined=[^\r\n]*%%d"), language .. " decline message must expose retry seconds")
	assert(content:match("JoinRequestRetryCooldown=[^\r\n]*%%d"), language .. " cooldown message must expose retry seconds")
end

local onlineHelpersPath = sourceRoot .. "/Themes/Simply Love/Scripts/SL-OnlineHelpers.lua"
local onlineHelpersFile = assert(io.open(onlineHelpersPath, "rb"), "missing online helpers: " .. onlineHelpersPath)
local onlineHelpersContent = onlineHelpersFile:read("*a")
onlineHelpersFile:close()
local joinLobbyHandler = assert(
	onlineHelpersContent:match("JoinLobbyMessageCommand=function%b()%s*(.-)%s*CreateLobbyMessageCommand=function"),
	"missing JoinLobbyMessageCommand"
)
assert(joinLobbyHandler:find("errorCode=(decoded and (decoded.error_code or decoded.errorCode))", 1, true),
	"join failures must forward the structured error code")
assert(joinLobbyHandler:find("retryAfterSeconds=(decoded and (decoded.retry_after_seconds or decoded.retryAfterSeconds))", 1, true),
	"join failures must forward the authoritative retry delay")
assert(joinLobbyHandler:find("roomId=params.code", 1, true),
	"join failures must retain the target room identity")

local onlineClientPath = sourceRoot .. "/Themes/Simply Love/Scripts/SL-ITGOnlineClient.lua"
local onlineClientFile = assert(io.open(onlineClientPath, "rb"), "missing online client: " .. onlineClientPath)
local onlineClientContent = onlineClientFile:read("*a")
onlineClientFile:close()
assert(onlineClientContent:find('self:HandleDeletedRoom(lobbyRoomId, "lobby_updated_room_deleted")', 1, true),
	"lobby.updated room deletions must clear an active room")
assert(onlineClientContent:find('self:HandleDeletedRoom(roomId, "room_deleted_event")', 1, true),
	"direct room.deleted events must share the same cleanup path")
assert(onlineClientContent:find("readyStates = room.ready_states or {}", 1, true),
	"lobby payloads must preserve authoritative ready-state rows")
assert(onlineClientContent:find('preferred=lobby reason=completed_round_reset_while_evaluating', 1, true),
	"a server-side evaluation timeout must force the client back to the online lobby")
local postRoomExitRefreshReset = assert(
	onlineClientContent:match(
		"function ITGOnline:ResetPostRoomExitLobbyRefreshState%b()%s*(.-)%s*function ITGOnline:QueuePostRoomExitLobbyRefresh"
	),
	"missing post-room-exit lobby refresh reset"
)
assert(not postRoomExitRefreshReset:find("self.lobbyRefreshInFlight = false", 1, true),
	"room exit must not forget an HTTP lobby refresh that is still in flight")
assert(postRoomExitRefreshReset:find("preservedInFlight=", 1, true),
	"room-exit refresh diagnostics must expose the preserved in-flight request")
assert(onlineClientContent:find('if phase == "lobby" and not (self.currentRoom and self.currentRoom.selected_song) then', 1, true),
	"a missed evaluation-timeout event must recover from the authoritative lobby snapshot")
local roomTransitionKey = assert(
	onlineClientContent:match("local function room_transition_key%b()%s*(.-)%s*local function online_room_transition_trace"),
	"missing room transition identity"
)
assert(roomTransitionKey:find("memberPackSyncStates", 1, true)
	and roomTransitionKey:find("pack_sync_download_progress", 1, true)
	and roomTransitionKey:find('"pack:" .. table.concat(memberPackSyncStates, ",")', 1, true),
	"room snapshot deduplication must retain member pack-sync projection changes")
local songBrowsingTimeoutHandler = assert(
	onlineClientContent:match('if name == "room%.song_browsing_timeout" then(.-)%s*if eventId'),
	"the client must handle the authoritative idle song-browser timeout"
)
assert(songBrowsingTimeoutHandler:find('self:ApplyPreferredRoomScreen(topScreen, "lobby")', 1, true),
	"an idle song-browsing manager must return to the online lobby screen")
assert(songBrowsingTimeoutHandler:find("online_protocol_ids_match(timedOutManagerId, currentUserId)", 1, true),
	"song-browser timeout navigation must only apply to the room manager")
local liveScoreFlush = assert(
	onlineClientContent:match("function ITGOnline:FlushLiveScore%b()%s*(.-)%s*function ITGOnline:HandleRoomNotPlayingScoreReject"),
	"missing live-score flush handler"
)
local liveScoreResponseTrace = assert(
	liveScoreFlush:match('online_score_transport_trace%(false, "live_score_flush_response(.-)local errorCode'),
	"missing live-score response trace"
)
assert(not liveScoreResponseTrace:find("hasRoom=", 1, true),
	"live-score acknowledgements must not be diagnosed as missing room snapshots")
assert(liveScoreResponseTrace:find("phaseSource=", 1, true),
	"live-score acknowledgements must identify the phase source")
local deletedRoomHandler = assert(
	onlineClientContent:match("function ITGOnline:HandleDeletedRoom%b()%s*(.-)%s*function ITGOnline:HandleRealtimeEvent"),
	"missing deleted-room cleanup handler"
)
assert(deletedRoomHandler:find('safe_broadcast("OnlineLobbyLeft"', 1, true),
	"deleted active rooms must leave the joined-lobby UI")
assert(deletedRoomHandler:find('self:ClearCurrentRoomState', 1, true),
	"deleted active rooms must clear cached room state")
local authoritativeRoomExit = assert(
	onlineClientContent:match("function ITGOnline:ApplyAuthoritativeRoomExit%b()%s*(.-)%s*function ITGOnline:"),
	"missing authoritative room-exit handler"
)
assert(authoritativeRoomExit:find('safe_broadcast("OnlineLobbyLeft"', 1, true),
	"every authoritative room exit must leave the joined-lobby UI")
assert(authoritativeRoomExit:find("self:ClearCurrentRoomState", 1, true),
	"every authoritative room exit must clear cached room state")
local heartbeatRoomUnavailableHandler = assert(
	onlineClientContent:match('if not ok and errorCode == "presence_room_not_available"(.-)%s*elseif not ok'),
	"missing heartbeat room-unavailable reconciliation"
)
assert(heartbeatRoomUnavailableHandler:find("self:ApplyAuthoritativeRoomExit", 1, true),
	"a heartbeat proving server-side removal must immediately leave the joined-lobby UI")
local roomLeftHandler = assert(
	onlineClientContent:match('elseif name == "room%.left" then(.-)%s*elseif name == "lobby%.updated"'),
	"missing room.left handler"
)
assert(roomLeftHandler:find("self:ApplyAuthoritativeRoomExit", 1, true),
	"room.left and heartbeat removal must share the idempotent authoritative exit path")

local packSyncPath = sourceRoot .. "/Themes/Simply Love/Scripts/SL-OnlinePackSync.lua"
local packSyncFile = assert(io.open(packSyncPath, "rb"), "missing online pack-sync source: " .. packSyncPath)
local packSyncContent = packSyncFile:read("*a")
packSyncFile:close()
local browsingDownloadHandler = assert(
	packSyncContent:match("function PackSync:DownloadBrowsingPack%b()%s*(.-)%s*local function browse_pack_reload_validated"),
	"missing browsing-pack download handler"
)
assert(browsingDownloadHandler:find("callback(true, {", 1, true)
	and browsingDownloadHandler:find('kind = "pack_candidates"', 1, true),
	"catalog candidate discovery is a successful result")
assert(packSyncContent:find('if catalogOk and type(catalogMessage) == "table" and catalogMessage.kind == "pack_candidates"', 1, true),
	"selected-pack downloads must consume successful candidate discovery")
assert(not packSyncContent:find("callback(false, catalogMessage)", 1, true),
	"pack-choice results must never be reported as failures")
local downloadAuthorizationHandler = assert(
	packSyncContent:match("function PackSync:RequestDownloadAuthorization%b()%s*(.-)%s*function PackSync:UpdateStatus"),
	"missing server-side pack download authorization handler"
)
assert(downloadAuthorizationHandler:find("/pack%-downloads/authorize"),
	"pack downloads must request explicit server authorization")
assert(downloadAuthorizationHandler:find("authorizationMatches", 1, true)
	and downloadAuthorizationHandler:find("authorization.authorized == true", 1, true),
	"the client must validate the complete server authorization identity")
assert(downloadAuthorizationHandler:find("ITGOnline:ApplyAuthoritativeRoomExit", 1, true),
	"an authorization-time ejection must immediately clear the local room")
local packStatusHandler = assert(
	packSyncContent:match("function PackSync:UpdateStatus%b()%s*(.-)%s*function PackSync:ApplyLocalStatus"),
	"missing pack status handler"
)
assert(packStatusHandler:find("download_authorization_endpoint_required", 1, true),
	"the generic status path must refuse to publish download_requested")
local candidateDownloadHandler = assert(
	packSyncContent:match("function PackSync:DownloadPackByCandidate%b()%s*(.-)%s*function PackSync:DownloadSelectedPack"),
	"missing candidate download handler"
)
local authorizationGate = assert(
	candidateDownloadHandler:find("if options.serverAuthorized ~= true then", 1, true),
	"candidate downloads must stop at a server authorization gate"
)
local transferStart = assert(
	candidateDownloadHandler:find("NETWORK:HttpRequest", authorizationGate + 1, true),
	"missing authorized pack transfer"
)
assert(candidateDownloadHandler:find("return", authorizationGate + 1, true) < transferStart,
	"the unauthorized branch must return before opening the pack transfer")
assert(candidateDownloadHandler:find("missing_or_stale_server_authorization", 1, true),
	"the transfer path must reject a missing or stale authorization identity")
assert(packSyncContent:find("self.status.NoCompatibleChartFound, message", 1, true),
	"catalogue failure before authorization must not forge a download failure")

local lobbyOverlayPath = sourceRoot .. "/Themes/Simply Love/BGAnimations/ScreenOnlineLobbies overlay/default.lua"
local lobbyOverlayFile = assert(io.open(lobbyOverlayPath, "rb"), "missing online lobby overlay: " .. lobbyOverlayPath)
local lobbyOverlayContent = lobbyOverlayFile:read("*a")
lobbyOverlayFile:close()
assert(lobbyOverlayContent:find("autoStartSingleCandidate = true", 1, true)
	and packSyncContent:find("options.autoStartSingleCandidate == true and #candidates == 1", 1, true),
	"browsing downloads must auto-start when the catalog has exactly one candidate")
assert(lobbyOverlayContent:find("ui_pack_choice_download_authorization_requested", 1, true)
	and not lobbyOverlayContent:find("ui_pack_choice_download_start", 1, true),
	"the pack-choice UI must describe an authorization intent, not a download already started")
assert(not lobbyOverlayContent:find('refresh_joined_room_snapshot("pack_choice_download_start"', 1, true),
	"pack authorization must not race a parallel room refresh")
assert(lobbyOverlayContent:find(
	'ITGOnlineLobbyPresentation.text("LeaveLobby", "Leave lobby")',
	1,
	true
),
	"the lobby exit confirmation must describe leaving the lobby rather than disconnecting")
assert(lobbyOverlayContent:find("self:zoom(0.5):maxwidth(280)", 1, true),
	"localized lobby exit labels must be constrained to their buttons")

local frenchLanguagePath = sourceRoot .. "/Themes/Simply Love/Languages/fr.ini"
local frenchLanguageFile = assert(io.open(frenchLanguagePath, "rb"), "missing French language file: " .. frenchLanguagePath)
local frenchLanguageContent = frenchLanguageFile:read("*a")
frenchLanguageFile:close()
assert(frenchLanguageContent:find("CreatingLobby=Création du salon...", 1, true),
	"the lobby creation status must be translated into French")
assert(frenchLanguageContent:find("CreatingPrivateLobbyInvite=Création du salon privé et envoi de l’invitation...", 1, true),
	"the private invitation creation status must be translated into French")
assert(frenchLanguageContent:find("LeavingLobby=Sortie du salon...", 1, true),
	"the lobby leave status must be translated into French")

local invalidAckEvent, invalidAckReason = protocol.normalize_event({
	id = "18",
	event = "room.ready_updated",
	requires_ack = "false",
	payload = {},
})
equal(invalidAckEvent, nil, "invalid event acknowledgement rejection")
equal(invalidAckReason, "invalid_event_requires_ack", "invalid event acknowledgement reason")

local invalidEvent, invalidEventReason = protocol.normalize_event({
	id = "18",
	event = "room.ready_updated",
	payload = { room = { id = "9", phase = "future" } },
})
equal(invalidEvent, nil, "invalid event room rejection")
equal(invalidEventReason, "invalid_event_room:unknown_room_phase", "invalid event room reason")

local syncPayload = assert(protocol.normalize_sync_payload({
	current_room = { id = "9", phase = "lobby", members = {}, ready_states = {} },
	visible_rooms = {
		{ id = "12", phase = "lobby", visibility = "public", members = {}, ready_states = {} },
		{ id = "13", phase = "lobby", visibility = "private", members = {}, ready_states = {} },
	},
	online_users = {},
	pending_join_requests = {},
	pending_invitations = {},
	events = { event },
	next_cursor = "17",
	meta = {},
}))
equal(syncPayload.current_room.id, "9", "sync current room ID")
equal(syncPayload.visible_rooms[1].id, "12", "sync visible room ID")
equal(syncPayload.visible_rooms[2].visibility, "private", "private room visibility")
equal(syncPayload.events[1].id, "17", "sync event ID")

local invalidSync, invalidSyncReason = protocol.normalize_sync_payload({
	visible_rooms = "invalid",
	events = {},
})
equal(invalidSync, nil, "invalid sync rejection")
equal(invalidSyncReason, "collection_not_table:sync.visible_rooms", "invalid sync reason")

local invalidCursorSync, invalidCursorReason = protocol.normalize_sync_payload({
	visible_rooms = {},
	events = {},
	next_cursor = "1e3",
})
equal(invalidCursorSync, nil, "invalid sync cursor rejection")
equal(invalidCursorReason, "invalid_next_cursor", "invalid sync cursor reason")

local reducer = protocol.new_event_reducer("9007199254740993")
local applied, reason = reducer:apply({ room_id = "9007199254740993", version = 2, phase = "playing" })
equal(applied, true, "new event")
applied, reason = reducer:apply({ room_id = "9007199254740993", version = 1, phase = "lobby" })
equal(applied, false, "reordered event")
equal(reason, "stale_event", "reordered reason")
applied, reason = reducer:apply({ room_id = "9007199254740993", version = 3, phase = "future_phase" })
equal(applied, false, "unknown phase")
equal(reason, "unknown_phase", "unknown phase reason")
equal(reducer.resync_required, true, "unknown phase resync")

local callbacks = protocol.new_callback_queue(2)
local calls = 0
assert(callbacks:append(function(value) calls = calls + value end))
assert(callbacks:append(function(value) calls = calls + value end))
local accepted, queueReason = callbacks:append(function() end)
equal(accepted, false, "callback overflow")
equal(queueReason, "queue_full", "callback overflow reason")
equal(callbacks:drain(2), 2, "callback drain count")
equal(calls, 4, "callback invocation")

math.randomseed(1977)
for _ = 1, 10000 do
	local length = math.random(0, 40)
	local value = ""
	for _ = 1, length do
		local alphabet = "0123456789abcdef-+eE"
		local index = math.random(1, #alphabet)
		value = value .. alphabet:sub(index, index)
	end
	local canonical = protocol.canonical_decimal_id(value)
	if canonical ~= nil then
		assert(canonical:match("^%d+$"), "canonical ID must remain decimal")
		assert(#canonical <= 20, "canonical ID must remain bounded")
	end
end

local captureStart = assert(packSyncContent:find(
	"ITGOnline:CaptureLocalChartIntentsForSong(", 1, true
), "pack sync must capture per-player chart intent")
local songApplyStart = assert(packSyncContent:find(
	"GAMESTATE:SetCurrentSong(song)", captureStart, true
), "pack sync must apply the selected song")
assert(captureStart < songApplyStart,
	"per-player chart intent must be captured before SetCurrentSong can invalidate it")
assert(onlineClientContent:find("function ITGOnline:ResolveLocalChartIntent", 1, true)
	and onlineClientContent:find('or intentSteps', 1, true),
	"online chart resolution must preserve each local player's wheel choice")
assert(onlineClientContent:find(
	"local steps = GAMESTATE:GetCurrentSteps(selectionPlayer)", 1, true
), "a new manager selection must use the live wheel chart instead of stale option state")
assert(onlineClientContent:find("function ITGOnline:LocalPartyReadyForEvaluation", 1, true)
	and onlineClientContent:find(
		"hold_gameplay_release reason=local_party_final_scores_accepted", 1, true
	),
	"gameplay must release to evaluation after local, not global, final acceptance")
assert(onlineClientContent:find("roomDeleted = roomDeleted == true", 1, true)
	and onlineClientContent:find(
		'PurgeStaleLobbyCandidate(roomId, "leave_room_response_deleted")', 1, true
	),
	"an authoritative deleted-room leave response must purge the lobby immediately")
local resultsFastPathStart = assert(onlineClientContent:find(
	"function ITGOnline:ApplyResultsReadyPayload", 1, true
), "results-ready must expose a compact terminal-state applicator")
local resultsFastPathEnd = assert(onlineClientContent:find(
	"function ITGOnline:HandleRealtimeEvent", resultsFastPathStart, true
), "results-ready fast-path boundary must remain identifiable")
local resultsFastPathSource = onlineClientContent:sub(resultsFastPathStart, resultsFastPathEnd - 1)
assert(resultsFastPathSource:find("ApplyPlayStateSnapshot", 1, true)
	and resultsFastPathSource:find("FetchPlayState", 1, true),
	"results-ready must apply its terminal projection and reconcile only play-state when absent")
assert(not resultsFastPathSource:find("ApplyRoomSnapshot", 1, true)
	and not resultsFastPathSource:find("FetchRoom", 1, true),
	"results-ready must not rebuild or download a complete room during gameplay exit")
local resultsBranch = assert(onlineClientContent:find(
	'elseif name == "room.results_ready" then', resultsFastPathEnd, true
), "results-ready must have a dedicated realtime branch")
local genericRoomBranch = assert(onlineClientContent:find(
	'elseif name and name:match("^room%.") then', resultsBranch, true
), "generic room event branch must remain available")
assert(resultsBranch < genericRoomBranch,
	"results-ready must bypass generic full-room snapshot processing")

local networkManagerHeaderPath = sourceRoot .. "/src/NetworkManager.h"
local networkManagerHeaderFile = assert(io.open(networkManagerHeaderPath, "rb"), "missing NetworkManager header")
local networkManagerHeader = networkManagerHeaderFile:read("*a")
networkManagerHeaderFile:close()
local networkManagerPath = sourceRoot .. "/src/NetworkManager.cpp"
local networkManagerFile = assert(io.open(networkManagerPath, "rb"), "missing NetworkManager source")
local networkManagerSource = networkManagerFile:read("*a")
networkManagerFile:close()
assert(networkManagerHeader:find("std::vector<std::thread> httpWorkers", 1, true)
	and networkManagerSource:find("constexpr std::size_t kHttpWorkerCount = 4", 1, true),
	"local two-player HTTP traffic must use a bounded concurrent worker pool")
assert(networkManagerSource:find("ix::HttpClient requestClient;", 1, true)
	and networkManagerSource:find("requestClient.setTLSOptions(this->tlsOptions)", 1, true)
	and networkManagerSource:find(
		"requestClient.request(req->url, req->verb, req->body, req)", 1, true
	),
	"each worker must execute its API request synchronously with isolated IXHttpClient state")
assert(onlineClientContent:find(
	"ITGOnline.realtimeGhostSeconds = ITGOnline.realtimeGhostSeconds or 15.0", 1, true
) and not onlineClientContent:find(
	"tonumber(self.realtimeGhostSeconds) or 75.0", 1, true
), "all realtime ghost-detection fallbacks must use the server ping-based timeout")

local leaderboardPath = sourceRoot
	.. "/Themes/Simply Love/BGAnimations/ScreenGameplay overlay/OnlineLiveLeaderboard.lua"
local leaderboardFile = assert(io.open(leaderboardPath, "rb"), "missing live leaderboard")
local leaderboardContent = leaderboardFile:read("*a")
leaderboardFile:close()
assert(leaderboardContent:find("local function local_user_roles()", 1, true)
	and leaderboardContent:find('Name="RightMarker"', 1, true)
	and leaderboardContent:find('localRole == "P2" and "<" or ""', 1, true),
	"the live leaderboard must identify P2 locally and draw its marker on the right")

local paneNumbersPath = sourceRoot
	.. "/Themes/Simply Love/BGAnimations/ScreenEvaluation common/Panes/Pane2/JudgmentNumbers.lua"
local paneNumbersFile = assert(io.open(paneNumbersPath, "rb"), "missing pane 2 judgment values")
local paneNumbersContent = paneNumbersFile:read("*a")
paneNumbersFile:close()
assert(not paneNumbersContent:find("usesExPrimaryLayout", 1, true)
	and paneNumbersContent:find("TapNotes = 94", 1, true),
	"EX and HardEX values must share the label-aligned P2 geometry")
local playerOptionsPath = sourceRoot .. "/Themes/Simply Love/Scripts/SL-PlayerOptions.lua"
local playerOptionsFile = assert(io.open(playerOptionsPath, "rb"), "missing player options")
local playerOptionsContent = playerOptionsFile:read("*a")
playerOptionsFile:close()
assert(playerOptionsContent:find("ApplySimplyLoveScoreMode = function", 1, true)
	and onlineClientContent:find(
		"ApplySimplyLoveScoreMode(player, options.score_mode)", 1, true
	),
	"local options and manager-global options must share one complete score-mode applicator")

print("online protocol behavioral tests passed")
