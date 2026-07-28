local sourceRoot = assert(arg[1], "source root is required")
local party = assert(dofile(
	sourceRoot .. "/Themes/Simply Love/Scripts/02 SL-ITGOnlineLocalParty.lua"
))
local lobbyPresentation = assert(dofile(
	sourceRoot .. "/Themes/Simply Love/Scripts/02 SL-ITGOnlineLobbyPresentation.lua"
))
local lobbyModel = assert(dofile(
	sourceRoot .. "/Themes/Simply Love/Scripts/02 SL-ITGOnlineLobbyModel.lua"
))
local roomPolicy = assert(dofile(
	sourceRoot .. "/Themes/Simply Love/Scripts/02 SL-ITGOnlineRoomPolicy.lua"
))
local localIdentity = assert(dofile(
	sourceRoot .. "/Themes/Simply Love/Scripts/02 SL-ITGOnlineLocalIdentity.lua"
))
local scoreTransport = assert(dofile(
	sourceRoot .. "/Themes/Simply Love/Scripts/02 SL-ITGOnlineScoreTransport.lua"
))
local readinessCoordinator = assert(dofile(
	sourceRoot .. "/Themes/Simply Love/Scripts/02 SL-ITGOnlineReadinessCoordinator.lua"
))
local realtimeEventRouter = assert(dofile(
	sourceRoot .. "/Themes/Simply Love/Scripts/02 SL-ITGOnlineRealtimeEventRouter.lua"
))
local roomStateMachine = assert(dofile(
	sourceRoot .. "/Themes/Simply Love/Scripts/02 SL-ITGOnlineRoomStateMachine.lua"
))

local function equal(actual, expected, label)
	assert(actual == expected, (label or "value")
		.. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
end

local soloP1 = party.session_plan({ "P1" })
equal(soloP1.requiredCount, 1, "P1 solo required identity count")
equal(soloP1.coordinatorSide, "P1", "P1 solo coordinator")
equal(soloP1.twoPlayer, false, "P1 solo mode")
equal(party.role_for_side(soloP1, "P1"), "coordinator", "P1 solo role")

local soloP2 = party.session_plan({ "PlayerNumber_P2" })
equal(soloP2.requiredCount, 1, "P2 solo required identity count")
equal(soloP2.coordinatorSide, "P2", "P2 solo coordinator")
equal(party.role_for_side(soloP2, "P2"), "coordinator", "P2 solo role")

local versus = party.session_plan({ "PlayerNumber_P2", "PlayerNumber_P1" })
equal(versus.requiredCount, 2, "two-player required identity count")
equal(versus.requiredSides[1], "P1", "stable P1 ordering")
equal(versus.requiredSides[2], "P2", "stable P2 ordering")
equal(versus.coordinatorSide, "P1", "two-player coordinator")
equal(versus.twoPlayer, true, "two-player mode")
equal(party.role_for_side(versus, "P1"), "coordinator", "P1 two-player role")
equal(party.role_for_side(versus, "P2"), "companion", "P2 two-player role")
local p1Identity = localIdentity.describe("P1", "P1", "P2", versus)
local p2Identity = localIdentity.describe("P2", "P1", "P2", versus)
equal(p1Identity.isPrimary, true, "P1 identity owns room coordination")
equal(p2Identity.isPrimary, false, "P2 identity remains the local companion")
equal(p2Identity.role, "companion", "P2 identity role")
local scorePayload = scoreTransport.payload(p2Identity, {
	score = 420000,
	displayed_percent = 42,
	final = false,
	judgments = { Fantastic = 10 },
})
equal(scorePayload.score, 420000, "shared score payload keeps score")
equal(scorePayload.compact_response, true, "live score payload is compact for every identity")
equal(scorePayload.final, false, "shared score payload normalizes final state")
local scoreContext = assert(scoreTransport.score_context({
	song_hash = "AAAA",
	chart_hash = "room-chart",
	max_score = 973000,
}, {
	song_hash = "aaaa",
	chart_hash = "PLAYER-CHART",
	chart_note_count = 210,
	max_score = 210000,
}))
equal(scoreContext.song_hash, "aaaa", "score context keeps the authoritative song")
equal(scoreContext.chart_hash, "player-chart",
	"score context always uses the local player's ready chart")
equal(scoreContext.max_score, 210000,
	"score context never reuses the manager chart maximum for another chart")
local contextualPayload = scoreTransport.payload(p1Identity, {
	score = 100000,
	song_hash = "room-song",
	chart_hash = "room-chart",
}, scoreContext)
equal(contextualPayload.song_hash, "aaaa",
	"score payload always uses the validated player song context")
equal(contextualPayload.chart_hash, "player-chart",
	"score payload cannot fall back to the manager chart")
equal(
	scoreTransport.context_key("round-1", scoreContext),
	"round-1|aaaa|player-chart|210|210000",
	"score contract identity is stable and player-specific"
)
local invalidScoreContext, invalidScoreContextReason = scoreTransport.score_context({
	song_hash = "song-a",
}, {
	song_hash = "song-b",
	chart_hash = "chart-b",
})
equal(invalidScoreContext, nil, "score context rejects a stale player song")
equal(invalidScoreContextReason, "player_song_hash_mismatch",
	"stale score context exposes a stable diagnostic")
equal(scoreTransport.is_contract_error("score_song_mismatch"), true,
	"server chart contract rejects stop the current score transport")
equal(scoreTransport.is_contract_error("temporary_server_error"), false,
	"transient score failures remain retryable")
local scoreRuntime = scoreTransport.new_runtime(p2Identity, "round-1")
equal(scoreRuntime.localPlayer, "P2", "score runtime is bound to its local identity")
scoreTransport.queue_final(scoreRuntime, function() end)
local finalQueued, finalCallbacks = scoreTransport.take_pending_final(scoreRuntime)
equal(finalQueued, true, "final score is queued behind an in-flight local score")
equal(#finalCallbacks, 1, "queued final callbacks are preserved")
local readyPayload = readinessCoordinator.payload(p2Identity, {
	clientActionId = "action-1",
	selectionId = "selection-1",
	phase = "config_ready",
	isReady = true,
	options = { stepchart = "Hard 8" },
})
equal(readyPayload.is_ready, true, "shared readiness payload normalizes ready state")
equal(readinessCoordinator.local_party_action(versus, true, false), "companion_barrier",
	"two-player ready requires the companion barrier")
equal(readinessCoordinator.local_party_action(versus, false, false), "companion_fanout",
	"two-player not-ready fans out to the companion")
local routed = assert(realtimeEventRouter.route({
	id = "12",
	event = "room.score_updated",
	payload = {},
}))
equal(routed.category, "score", "score events use the score route")
local rejectedRoute, rejectedReason = realtimeEventRouter.route({
	event = "room.updated",
	payload = {},
})
equal(rejectedRoute, nil, "idless room events are rejected")
equal(rejectedReason, "idless_non_control", "idless event rejection reason")
equal(roomStateMachine.normalize_phase("PLAYING"), "playing", "room phase normalization")
equal(roomStateMachine.phase_regresses("playing", "config", {
	sameRoom = true,
	sameRound = true,
}), true, "same-round room snapshots cannot regress without an authorized transition")
equal(roomStateMachine.phase_regresses("results", "lobby", {
	sameRoom = true,
	sameRound = true,
	allowRegression = true,
}), false, "authorized room reset can return to the lobby")
local roomContractOk = roomStateMachine.validate_room_contract({
	members = {},
})
equal(roomContractOk, true, "current room contract is accepted")
local obsoleteContractOk, obsoleteContractReason =
	roomStateMachine.validate_room_contract({})
equal(obsoleteContractOk, false, "room snapshots without the current contract are rejected")
equal(obsoleteContractReason, "missing_room_members",
	"missing room contract requests an explicit resynchronization")
local localPartyContractOk = roomStateMachine.validate_room_contract({
	members = {
		{ id = "3", local_party = { companion = { id = "4" } } },
		{ id = "4", local_party = { companion = { id = "3" } } },
	},
}, {
	localPartyRequired = true,
	firstUserId = "3",
	secondUserId = "4",
})
equal(localPartyContractOk, true,
	"current room snapshots expose the verified local party in both directions")
local missingLocalPartyContract, missingLocalPartyReason =
	roomStateMachine.validate_room_contract({
		members = {
			{ id = "3" },
			{ id = "4" },
		},
	}, {
		localPartyRequired = true,
		firstUserId = "3",
		secondUserId = "4",
	})
equal(missingLocalPartyContract, false,
	"realtime snapshots cannot erase the verified local party relation")
equal(missingLocalPartyReason, "missing_local_party_relation",
	"missing local party metadata requests an explicit authoritative resynchronization")
equal(roomStateMachine.local_party_relation_signature({
	members = {
		{ id = "4", local_party = { companion = { id = "3" } } },
		{ id = "3", local_party = { companion = { id = "4" } } },
	},
}), "3>4,4>3", "local party diagnostics are stable and omit the private party UUID")
local availabilityOk = roomStateMachine.validate_song_availability({
	song_availability = { missing = false },
}, false)
equal(availabilityOk, true, "authoritative song availability is accepted")
local availabilityMissing, availabilityReason =
	roomStateMachine.validate_song_availability({ song_availability = {} }, false)
equal(availabilityMissing, false, "missing availability state is rejected")
equal(availabilityReason, "missing_song_availability_state",
	"missing availability state cannot be reconstructed locally")
equal(party.all_local_finals_accepted(versus, { P1 = true, P2 = false }), false,
	"two-player evaluation must wait for P2's accepted final")
equal(party.all_local_finals_accepted(versus, { P1 = true, P2 = true }), true,
	"two-player evaluation releases after both local finals are accepted")
equal(party.all_local_finals_accepted(soloP1, { P1 = true }), true,
	"solo evaluation releases independently from remote machines")
equal(party.all_local_finals_accepted(soloP1, { P1 = false }), false,
	"solo evaluation must wait for its local final acknowledgement")
equal(party.score_transport_should_continue(versus, { P1 = true, P2 = false }), true,
	"P2 live-score transport must continue after P1 finalization")
equal(party.score_transport_should_continue(versus, { P1 = false, P2 = true }), true,
	"P1 live-score transport must continue after P2 finalization")
equal(party.score_transport_should_continue(versus, { P1 = true, P2 = true }), false,
	"two-player score transport stops only after both local finals")
equal(party.score_transport_should_continue(soloP1, { P1 = false }), true,
	"solo score transport continues before finalization")
equal(party.score_transport_should_continue(soloP1, { P1 = true }), false,
	"solo score transport stops after finalization")
equal(party.failed_player_route(versus, "P1"), "primary",
	"P1 failure must use the primary score identity")
equal(party.failed_player_route(versus, "P2"), "companion",
	"P2 failure must use the companion score identity")
equal(party.failed_player_route(soloP2, "P2"), "primary",
	"a solo P2 session must use its coordinator identity")
equal(party.failed_player_route(versus, "P3"), nil,
	"an unknown local side must not be routed")

equal(party.should_submit_companion_ready(versus, true, false), true,
	"P2 must be submitted before P1 becomes ready")
equal(party.should_submit_companion_ready(versus, true, true), false,
	"P2 must not be submitted twice after the readiness barrier")
equal(party.should_submit_companion_ready(soloP1, true, false), false,
	"solo readiness must not submit a companion")
equal(party.should_fan_out_companion_not_ready(versus, false, false), true,
	"clearing readiness must be propagated to P2")
equal(party.should_fan_out_companion_not_ready(versus, false, true), false,
	"readiness fan-out must remain single-shot")
equal(party.companion_score_is_terminal(false, false), false,
	"a live companion score must remain sendable before finalization")
equal(party.companion_score_is_terminal(true, false), true,
	"an accepted companion final must suppress every later score")
equal(party.companion_score_is_terminal(false, true), true,
	"an authoritative room final must suppress every later score")
equal(party.companion_live_score_should_send(false, false, false), true,
	"the first zero-progress companion snapshot establishes server state")
equal(party.companion_live_score_should_send(true, false, false), false,
	"accepted zero-progress companion snapshots must not be resent")
equal(party.companion_live_score_should_send(true, false, true), true,
	"real companion progress must resume live score publication")
equal(party.companion_live_score_should_send(true, true, false), true,
	"a final companion snapshot must never be suppressed")
equal(party.should_preserve_local_chart_choice("lobby", "ScreenSelectMusic"), true,
	"the wheel choice must survive the initial server song application")
equal(party.should_preserve_local_chart_choice("lobby_ready", "ScreenOnlineLobbies"), true,
	"the wheel choice must survive the lobby-ready acknowledgement")
equal(party.should_preserve_local_chart_choice("config", "ScreenPlayerOptions"), true,
	"the player-specific chart must remain authoritative in options")
equal(party.should_preserve_local_chart_choice("starting", "ScreenGameplay"), false,
	"gameplay must resolve the server-accepted member options")
local p1Level6 = { player = "P1", meter = 6 }
local p2Level8 = { player = "P2", meter = 8 }
equal(party.resolve_pre_game_chart(nil, p1Level6, nil, nil, p1Level6), p1Level6,
	"P1 must keep its level 6 wheel intent")
equal(party.resolve_pre_game_chart(nil, p2Level8, nil, nil, p1Level6), p2Level8,
	"P2 must keep its level 8 wheel intent instead of the manager fallback")
equal(roomPolicy.presence_status(false, nil, "ScreenOnlineLobbies"), "available",
	"presence without a room is available")
equal(roomPolicy.presence_status(true, "config", "ScreenPlayerOptions"), "in_room",
	"options presence remains in-room")
equal(roomPolicy.presence_status(true, "starting", "ScreenGameplay"), "playing",
	"starting gameplay presence is playing")
equal(roomPolicy.presence_status(true, "playing", "ScreenGameplayShared"), "playing",
	"shared gameplay presence is playing")
equal(roomPolicy.presence_status(true, "results", "ScreenGameplay"), "playing",
	"gameplay held for global results remains playing")
equal(roomPolicy.presence_status(true, "results", "ScreenEvaluationStage"), "playing",
	"evaluation presence remains playing until the server closes the active round")
equal(roomPolicy.presence_status(true, "playing", "ScreenEvaluationStage"), "playing",
	"a locally completed player cannot regress presence while remote players continue")
equal(roomPolicy.presence_status(true, "lobby", "ScreenEvaluationStage"), "in_room",
	"presence returns in-room only after the authoritative lobby reset")

local pendingSongSyncIds = roomPolicy.pending_song_sync_member_ids({
	phase = "config",
	selected_song = { title = "Test" },
	members = {
		{ id = 1, song_available = true, missing_song = false },
		{ id = 2, song_available = false, missing_song = true },
		{ id = 3, song_available = nil, missing_song = false },
	},
})
equal(#pendingSongSyncIds, 2,
	"options deadline waits for every authoritative song confirmation")
equal(pendingSongSyncIds[1], "2", "missing-song blocker identity")
equal(pendingSongSyncIds[2], "3", "unconfirmed-song blocker identity")
equal(roomPolicy.options_deadline_blocked({
	phase = "config",
	selected_song = { title = "Test" },
	members = {
		{ id = 1, song_available = true },
		{ id = 2, song_available = true },
	},
}), false, "options deadline starts once every song is confirmed")
equal(roomPolicy.projection_includes_user({ 4, "7" }, 7), true,
	"availability projection accepts protocol-equivalent user identifiers")
equal(roomPolicy.projection_includes_user({ 4, "7" }, 8), false,
	"availability projection does not cover another user")
equal(lobbyPresentation.text("MissingTranslation", "Fallback"), "Fallback",
	"lobby presentation must preserve safe translation fallbacks")
equal(lobbyModel.joined_player_stable_key({ playerId = 42 }), "id:42",
	"lobby players must use a stable identity key")
equal(lobbyModel.joined_player_index_for_key({
	{ playerId = 1 },
	{ playerId = 2 },
}, "id:2", 1), 2, "lobby selection must survive stable player refreshes")

local valid, reason, side = party.validate_identities(versus, {
	P1 = "user-1",
	P2 = "user-2",
})
equal(valid, true, "distinct identities")
equal(reason, nil, "distinct identity reason")
equal(side, nil, "distinct identity side")

valid, reason, side = party.validate_identities(versus, {
	P1 = "user-1",
})
equal(valid, false, "missing P2 identity")
equal(reason, "local_player_not_authenticated", "missing P2 reason")
equal(side, "P2", "missing P2 side")

valid, reason, side = party.validate_identities(versus, {
	P1 = "same-user",
	P2 = "same-user",
})
equal(valid, false, "duplicate identity")
equal(reason, "duplicate_local_online_identity", "duplicate identity reason")
equal(side, "P2", "duplicate identity side")

local supported, unsupportedReason = party.online_mode_supported(false, false)
equal(supported, true, "single/versus online support")
equal(unsupportedReason, nil, "supported mode reason")

supported, unsupportedReason = party.online_mode_supported(true, false)
equal(supported, false, "couple online rejection")
equal(unsupportedReason, "couple_not_supported_online", "couple rejection reason")

supported, unsupportedReason = party.online_mode_supported(false, true)
equal(supported, false, "routine online rejection")
equal(unsupportedReason, "routine_not_supported_online", "routine rejection reason")

local function read_source(relativePath)
	local file = assert(io.open(sourceRoot .. "/" .. relativePath, "rb"))
	local source = assert(file:read("*a"))
	file:close()
	return source
end

local function ini_section(source, sectionName)
	local entries = {}
	local currentSection = ""
	for line in tostring(source or ""):gmatch("[^\r\n]+") do
		local heading = line:match("^%[([^%]]+)%]$")
		if heading then
			currentSection = heading
		elseif currentSection == sectionName then
			local key, value = line:match("^([^;#][^=]*)=(.*)$")
			if key then
				if value:match('^".*"$') then value = value:sub(2, -2) end
				entries[key] = value
			end
		end
	end
	return entries
end

local function format_placeholders(value)
	local placeholders = {}
	for placeholder in tostring(value or ""):gmatch("%%[%d%.]*[a-zA-Z%%]") do
		placeholders[#placeholders + 1] = placeholder
	end
	return table.concat(placeholders, "|")
end

local clientSource = read_source("Themes/Simply Love/Scripts/SL-ITGOnlineClient.lua")
local onlineHelpersSource = read_source("Themes/Simply Love/Scripts/SL-OnlineHelpers.lua")
local onlineScorePushSource = read_source(
	"Themes/Simply Love/BGAnimations/ScreenGameplay overlay/TrackOnlineScorePush.lua"
)
local evaluationAutoSubmitSource = read_source(
	"Themes/Simply Love/BGAnimations/ScreenEvaluation common/Shared/AutoSubmitScore.lua"
)
local evaluationPanesSource = read_source(
	"Themes/Simply Love/BGAnimations/ScreenEvaluation common/Panes/default.lua"
)
local onlineLobbyScreenSource = read_source(
	"Themes/Simply Love/BGAnimations/ScreenOnlineLobbies overlay/default.lua"
)
assert(clientSource:find("ITGOnlineLocalIdentity.describe", 1, true),
	"local P1/P2 behavior must be parameterized by one identity contract")
assert(clientSource:find("ITGOnlineScoreTransport.payload", 1, true),
	"P1 and P2 scores must share one transport payload contract")
assert(clientSource:find("ITGOnlineReadinessCoordinator.payload", 1, true),
	"P1 and P2 readiness must share one coordinator")
assert(clientSource:find("ITGOnlineRealtimeEventRouter.route", 1, true),
	"realtime schema validation and classification must be routed centrally")
assert(clientSource:find("ITGOnlineRoomStateMachine.validate_room_contract", 1, true),
	"room snapshots must pass through the room state machine")
assert(not clientSource:find("annotate_song_availability_result", 1, true),
	"missing song availability fields must never be reconstructed locally")
local lobbyStateStart = assert(clientSource:find("function ITGOnline:LobbyStatePayload", 1, true))
local lobbyStateSource = clientSource:sub(lobbyStateStart)
assert(not lobbyStateSource:find("cachedLobbySearchPayload", 1, true),
	"room-local party relations must never fall back to the global presence cache")
for _, deadMethod in ipairs({
	"SaveConfig",
	"SuppressLobbyRefresh",
	"SuppressAutomaticLobbyRefresh",
	"Register",
	"ResendVerification",
	"ForgotPassword",
}) do
	assert(not clientSource:find("function ITGOnline:" .. deadMethod, 1, true),
		"dead public method must stay removed: " .. deadMethod)
end
assert(clientSource:find("ITGOnline.onlineFlowLoggingDefaultEnabled = true", 1, true),
	"new installations must enable online network diagnostics by default")
assert(not clientSource:find("forceOnlineFlowLogging", 1, true),
	"online diagnostics must remain a preference after their initial default is applied")
assert(clientSource:find('["OnlineTrace"] = "true"', 1, true),
	"new debug configurations must enable the online trace")
assert(clientSource:find("function ITGOnline:SendCompanionScore", 1, true),
	"client must expose an isolated Player 2 score pipeline")
assert(clientSource:find("ITGOnlineLocalParty.should_preserve_local_chart_choice", 1, true)
	and clientSource:find("ITGOnlineLocalParty.resolve_pre_game_chart", 1, true),
	"the online client must preserve each local wheel chart before options")
assert(clientSource:find("function ITGOnline:CurrentRoomSnapshotIsAuthoritative", 1, true),
	"client must expose the authoritative cached-room policy")
assert(clientSource:find("function ITGOnline:CurrentPresenceStatus", 1, true)
	and clientSource:find("self:Heartbeat(self:CurrentPresenceStatus(), true, true)", 1, true),
	"user activity must preserve the active-round playing presence")
assert(not clientSource:find('self:Heartbeat("in_room", true, true)', 1, true),
	"user activity must never hard-code a presence regression to in_room")
assert(onlineHelpersSource:find("ITGOnline:CurrentPresenceStatus", 1, true),
	"screen heartbeats must use the same centralized presence policy")
assert(clientSource:find("function ITGOnline:OptionsReadyDeadlineBlockedByPackSync", 1, true)
	and clientSource:find("options_ready_deadline_deferred", 1, true)
	and clientSource:find("reason=pack_sync_pending", 1, true),
	"the options deadline must remain suspended while authoritative pack sync is pending")
assert(clientSource:find("function ITGOnline:SongAvailabilityProjectionIncludesCompanion", 1, true)
	and clientSource:find("reason=server_projection_confirmed", 1, true)
	and clientSource:find("reason=server_projection_unavailable", 1, true),
	"availability must use server projection or an authenticated companion request")
assert(onlineLobbyScreenSource:find(
	"Display_sync_skipped reason=authoritative_current_room",
	1,
	true
), "a fresh realtime room snapshot must suppress the screen-entry full sync")
assert(clientSource:find("companion_heartbeat_retry_queued", 1, true),
	"transient companion heartbeat failures must receive a bounded retry")
assert(not evaluationAutoSubmitSource:find('playcommand("EnsureLoaded")', 1, true),
	"GrooveStats callbacks must never force lazy evaluation panes onto the render thread")
assert(evaluationAutoSubmitSource:find("response_deferred_to_actor_queue", 1, true),
	"GrooveStats HTTP callbacks must defer UI work to the actor queue")
assert(not evaluationAutoSubmitSource:find('res["status"]', 1, true),
	"GrooveStats leaderboard cleanup must use validated response data, not an absent transport field")
assert(evaluationPanesSource:find('MESSAGEMAN:Broadcast("EvaluationLazyPaneLoaded"', 1, true),
	"newly opened panes must request pending GrooveStats data after loading")
assert(clientSource:find("onlineStateTraceThrottle", 1, true),
	"high-frequency state tracing must be throttled without disabling online diagnostics")
assert(clientSource:find('"rv:" .. tostring(roomVersion or 0)', 1, true),
	"versioned room snapshots must avoid recursive whole-payload fingerprints")
assert(clientSource:find("reason=current_room_snapshot_authoritative", 1, true),
	"a current-room snapshot must suppress the redundant full-lobby refresh on every online screen")
assert(clientSource:find("reason=presence_payload_authoritative", 1, true),
	"an authoritative presence row must update the lobby cache without a second full-lobby request")
assert(clientSource:find("lobby_updated_current_room:", 1, true),
	"a missed current-room snapshot must reconcile the room instead of downloading the full lobby")
assert(clientSource:find("room_left_event_duplicate reason=already_applied", 1, true),
	"a late room.left event must be diagnosed as an idempotent duplicate after local exit")
assert(clientSource:find("function ITGOnline:ConnectLocalPlayerPartyWebSockets", 1, true),
	"client must open both authenticated realtime connections")
assert(clientSource:find("function ITGOnline:CanLocalPlayerControlOnlineRoom", 1, true),
	"client must expose local room-control ownership")
assert(clientSource:find("expectedOnlineGameplayStepsByPlayer", 1, true),
	"gameplay charts must be tracked independently for both local players")
assert(clientSource:find("localPartyServerManaged", 1, true),
	"private-room membership must be managed atomically by the server")
assert(not clientSource:find("function ITGOnline:RequestCompanionJoinRequest", 1, true),
	"the client must not create a second, divergent private-room join request for Player 2")
assert(clientSource:find("function ITGOnline:ActiveLocalPartyId", 1, true),
	"both local presences must publish the same ephemeral party identity")
assert(clientSource:find('localPartyId and "coordinator" or nil', 1, true),
	"Player 1 heartbeats must declare the room-control coordinator")
assert(clientSource:find('localPartyId and "companion" or nil', 1, true),
	"Player 2 heartbeats must declare the non-controlling companion")
assert(clientSource:find("payload.local_party_role = localPartyRole", 1, true),
	"both local heartbeat payloads must publish their explicit party role")
assert(clientSource:find("function ITGOnline:CaptureLocalPartyPlan", 1, true),
	"the online session must capture local party membership once")
assert(clientSource:find("function ITGOnline:RequiredLocalPlayers", 1, true),
	"critical online requests must use the captured local party")
assert(clientSource:find("companion_ready_barrier_result", 1, true),
	"Player 1 ready must wait for the companion ready response")
assert(clientSource:find("ITGOnlineReadinessCoordinator.local_party_action", 1, true),
	"both readiness paths must use the identity-aware coordinator")
assert(clientSource:find("companion_ready_snapshot_membership_unconfirmed", 1, true),
	"a partial local room snapshot must not prevent the companion ready request")
local companionReadyStart = assert(clientSource:find("function ITGOnline:SetCompanionReady", 1, true),
	"client must expose the companion ready request")
local companionReadyEnd = assert(clientSource:find("function ITGOnline:SetReady", companionReadyStart, true),
	"companion ready boundary must remain identifiable")
local companionReadySource = clientSource:sub(companionReadyStart, companionReadyEnd - 1)
assert(not companionReadySource:find("error_code = \"local_party_room_incomplete\"", 1, true),
	"a stale local snapshot must not reject the companion before the server validates membership")
local readyStart = assert(clientSource:find("function ITGOnline:SetReady", 1, true),
	"client must expose the primary ready request")
local readyEnd = assert(clientSource:find("function ITGOnline:CurrentOnlineOptionSummary", readyStart, true),
	"primary ready request boundary must remain identifiable")
local readySource = clientSource:sub(readyStart, readyEnd - 1)
assert(not readySource:find("CurrentUserConfirmedSelectedSong", 1, true),
	"a stale local snapshot must not reject the primary ready request")
local companionScoreStart = assert(clientSource:find("function ITGOnline:SendCompanionScore", 1, true),
	"client must expose the companion score request")
local companionScoreEnd = assert(clientSource:find("function ITGOnline:SetCompanionReady", companionScoreStart, true),
	"companion score request boundary must remain identifiable")
local companionScoreSource = clientSource:sub(companionScoreStart, companionScoreEnd - 1)
assert(not companionScoreSource:find("LocalPartyRoomComplete", 1, true),
	"a stale local snapshot must not suppress Player 2 score delivery")
assert(companionScoreSource:find("companion_final_score_queued", 1, true),
	"a Player 2 final score must be queued behind an in-flight live score")
assert(companionScoreSource:find("companion_final_score_dispatch", 1, true),
	"the queued Player 2 final score must be dispatched as soon as the live request completes")
assert(companionScoreSource:find("state.pendingFinalCallbacks", 1, true),
	"all callers waiting for the queued Player 2 final score must be completed")
assert(companionScoreSource:find("IsCompanionScoreFinalizedForCurrentRound", 1, true),
	"live and final Player 2 scores must stop after final acceptance")
assert(companionScoreSource:find("companion_live_score_should_send", 1, true)
	and companionScoreSource:find("state.zeroLiveAccepted = true", 1, true),
	"Player 2 must suppress repeated zero-progress live score writes")
assert(clientSource:find("companion_score_suppressed reason=final_already_accepted", 1, true),
	"suppression of post-final Player 2 score traffic must remain diagnosable")
assert(clientSource:find("ITGOnline.liveScoreMinIntervalSeconds = ITGOnline.liveScoreMinIntervalSeconds or 1.00", 1, true)
	and clientSource:find("ITGOnline.liveScoreEndgameIntervalSeconds = ITGOnline.liveScoreEndgameIntervalSeconds or 0.50", 1, true),
	"live leaderboard publication must use a low-cost normal cadence with a bounded endgame refresh")
local scoreEventStart = assert(clientSource:find('elseif name == "room.score_updated" then', 1, true),
	"client must handle realtime score updates")
local scoreEventEnd = assert(clientSource:find('elseif name == "room.deleted" then', scoreEventStart, true),
	"realtime score handler boundary must remain identifiable")
local scoreEventSource = clientSource:sub(scoreEventStart, scoreEventEnd - 1)
assert(scoreEventSource:find("suppressLobbyBroadcast = true", 1, true),
	"score ticks must not rebuild and broadcast the complete lobby state")
assert(scoreEventSource:find("suppressUnchangedPlayStateBroadcast = true", 1, true),
	"score ticks must suppress unchanged play-state broadcasts")
assert(scoreEventSource:find('traceCategory = "score"', 1, true),
	"high-frequency score diagnostics must stay behind the dedicated score trace")
assert(clientSource:find("local isLiveScoreRequest =", 1, true)
	and clientSource:find("local traceHttpRequest = not isLiveScoreRequest or self.debugScoreTrace == true", 1, true),
	"successful live-score HTTP transport traces must stay behind ScoreTrace")
assert(clientSource:find('local scoreUpdateSource = tostring(source or "") == "score_updated"', 1, true)
	and clientSource:find("if not scoreUpdateSource or self.debugScoreTrace == true then", 1, true),
	"live leaderboard row summaries must not be built while routine score tracing is disabled")
assert(clientSource:find('online_score_trace("live_score_queue_activity room="', 1, true)
	and not clientSource:find('online_score_trace("live_score_queue room="', 1, true),
	"live score queue diagnostics must aggregate gameplay snapshots")
assert(clientSource:find("local companionTickDue =", 1, true)
	and clientSource:find("self.companionLiveScoreNextTickAt = companionNow + self:LiveScoreMinIntervalSeconds()", 1, true),
	"Player 2 score collection must run at the network cadence instead of every 100 ms")
local scoreTransportTickStart = assert(clientSource:find(
	"function ITGOnline:TickLiveScoreTransport()",
	1,
	true
), "the shared live-score transport tick must remain identifiable")
local scoreTransportTickEnd = assert(clientSource:find(
	"function ITGOnline:HasPendingLiveScore()",
	scoreTransportTickStart,
	true
), "the shared live-score transport tick boundary must remain identifiable")
local scoreTransportTickSource = clientSource:sub(
	scoreTransportTickStart,
	scoreTransportTickEnd - 1
)
assert(scoreTransportTickSource:find(
	'self:ShouldContinueLocalScoreTransport("live_score_tick")',
	1,
	true
) and scoreTransportTickSource:find("self:SendCompanionScore(false, false", 1, true),
	"P1 finalization must not return before the P2 transport tick")
assert(not scoreTransportTickSource:find(
	'if self:IsLiveScoreFinalizedForCurrentRound("live_score_tick") then',
	1,
	true
), "the shared transport must never use P1 finalization as its global stop condition")
assert(clientSource:find("function ITGOnline:ShouldContinueLocalScoreTransport", 1, true)
	and clientSource:find("ITGOnlineLocalParty.score_transport_should_continue", 1, true)
	and clientSource:find("function ITGOnline:IsPrimaryScoreTransportFinalizedForCurrentRound", 1, true),
	"the shared score transport must use all local finalization states")
assert(not onlineHelpersSource:find("OnlineScoreSnapshotMessageCommand", 1, true),
	"the online handler must not retain the legacy HUD score receiver")
assert(onlineScorePushSource:find("local function score_trace_enabled()", 1, true)
	and onlineScorePushSource:find("CaptureOnlineScoreCommand", 1, true)
	and onlineScorePushSource:find("self.scoreCaptureQueued", 1, true),
	"the gameplay score tracker must avoid per-judgment diagnostic string construction when disabled")
assert(onlineScorePushSource:find("local transportTickSeconds = 0.25", 1, true)
	and onlineScorePushSource:find("self:sleep(transportTickSeconds)", 1, true),
	"the gameplay transport poll must match its sub-second network cadence without running at 10 Hz")
local scoreFlushStart = assert(onlineScorePushSource:find("FlushOnlineScoreCommand", 1, true),
	"the score tracker must expose its transport cadence")
local scoreCaptureStart = assert(onlineScorePushSource:find("CaptureOnlineScoreCommand", scoreFlushStart, true),
	"the score tracker must isolate snapshot capture from transport")
local scoreFlushSource = onlineScorePushSource:sub(scoreFlushStart, scoreCaptureStart - 1)
assert(not scoreFlushSource:find("BuildCurrentScoreSnapshot", 1, true)
	and not scoreFlushSource:find("QueueLiveScore", 1, true),
	"the transport timer must never walk or requeue gameplay statistics")
assert(scoreFlushSource:find("local_score_transport_complete()", 1, true)
	and scoreFlushSource:find("not primary_live_score_finalized()", 1, true),
	"the shared timer must outlive either player while suppressing finalized P1 traffic")
assert(not clientSource:find("RememberLiveScoreSnapshot", 1, true)
	and not clientSource:find("QueueLiveScoreTickIfDue", 1, true)
	and clientSource:find("function ITGOnline:TickLiveScoreTransport()", 1, true),
	"the score client must expose one capture API and one transport tick API")
assert(onlineScorePushSource:find("HoldJudgmentMessageCommand", 1, true)
	and onlineScorePushSource:find("ExCountsChangedMessageCommand", 1, true),
	"tap, hold, and EX score changes must converge on the same coalesced capture owner")
assert(clientSource:find('tostring(self.lastFinalScoreInFlightKey or "") == roundKey', 1, true),
	"an in-flight final score must stop later live-score flushes")
local primaryScoreStart = assert(clientSource:find("function ITGOnline:SendScore", 1, true),
	"client must expose the primary score request")
local primaryScoreSource = clientSource:sub(primaryScoreStart, companionScoreStart - 1)
assert(primaryScoreSource:find("self:UpdatePlayStateFromResponse(decoded)", 1, true),
	"Player 1 must apply the authoritative final-score HTTP play-state fallback")
assert(companionScoreSource:find("self:UpdatePlayStateFromResponse(decoded)", 1, true),
	"Player 2 must apply the authoritative final-score HTTP play-state fallback")
assert(primaryScoreSource:find("ITGOnlineScoreTransport.payload", 1, true)
	and companionScoreSource:find("ITGOnlineScoreTransport.payload", 1, true),
	"both local players must use the shared score payload contract")
local localFailureStart = assert(
	clientSource:find("function ITGOnline:MarkLocalPlayerFailedEarly", 1, true),
	"early failure finalization must route by local player identity")
local localFailureEnd = assert(
	clientSource:find("function ITGOnline:MarkPlayFailedEarly", localFailureStart, true),
	"primary early failure boundary must remain identifiable")
local localFailureSource = clientSource:sub(localFailureStart, localFailureEnd - 1)
assert(localFailureSource:find("failed_player_route", 1, true),
	"early failure finalization must use the tested local-party routing policy")
assert(localFailureSource:find("self:SendCompanionScore(true, true", 1, true),
	"an early Player 2 failure must use the companion score pipeline")
assert(not localFailureSource:find("self:SendScore(", 1, true),
	"the Player 2 failure route must not directly use the primary score pipeline")
assert(clientSource:find('normalizedHealth == "Dead"', 1, true),
	"early failure detection must recognize the health enum representation used by the theme")
local companionLifecycleStart = assert(clientSource:find("function ITGOnline:RequestCompanionLifecycleAction", 1, true),
	"client must expose the companion lifecycle request")
local companionLifecycleEnd = assert(clientSource:find("function ITGOnline:MarkPlayEntered", companionLifecycleStart, true),
	"companion lifecycle request boundary must remain identifiable")
local companionLifecycleSource = clientSource:sub(companionLifecycleStart, companionLifecycleEnd - 1)
assert(not companionLifecycleSource:find("LocalPartyRoomComplete", 1, true),
	"a stale local snapshot must not suppress Player 2 lifecycle delivery")
assert(clientSource:find("function ITGOnline:ShouldSynchronizeCompanionRoomAfterSnapshot", 1, true),
	"companion reconciliation must be restricted to intentional room-entry snapshots")
assert(clientSource:find("reason=non_reconciliation_snapshot", 1, true),
	"ordinary room refreshes must not rejoin the companion")
assert(clientSource:find("function ITGOnline:ReportLocalPartyRoomSyncFailure", 1, true),
	"failed companion reconciliation must remain observable")
assert(clientSource:find("action=keep_primary_room", 1, true),
	"a transient companion reconciliation failure must not leave the primary room")
local syncStart = assert(clientSource:find("function ITGOnline:SynchronizeCompanionRoom", 1, true),
	"client must expose companion room reconciliation")
local syncEnd = assert(clientSource:find("function ITGOnline:CreateRoom", syncStart, true),
	"companion reconciliation boundary must remain identifiable")
local syncSource = clientSource:sub(syncStart, syncEnd - 1)
assert(not syncSource:find("HandleLocalPartyInvariantFailure", 1, true),
	"a failed companion reconciliation must never force a group leave")
assert(clientSource:find("song_availability_barrier_result", 1, true),
	"song availability must wait for both local players")
assert(clientSource:find("song_selected_auto_ready_deferred", 1, true),
	"song selection snapshots must defer auto-readiness until the new round is stable")
assert(not clientSource:find("function ITGOnline:RequiredLocalPlayersConfirmedSelectedSong", 1, true),
	"the client must not treat a possibly stale room snapshot as the availability authority")
assert(not clientSource:find("function ITGOnline:RefreshLocalPartyRoomForSongSelectedAutoReady", 1, true),
	"the readiness flow must not be blocked by a one-shot local room refresh")
local autoReadyStart = assert(clientSource:find("function ITGOnline:MaybeAutoConfirmSelectedSongAndMarkLobbyReady", 1, true),
	"client must expose the automatic availability and ready flow")
local autoReadyEnd = assert(clientSource:find("function ITGOnline:ApplyDecodedRoomSnapshot", autoReadyStart, true),
	"automatic availability and ready flow boundary must remain identifiable")
local autoReadySource = clientSource:sub(autoReadyStart, autoReadyEnd - 1)
assert(autoReadySource:find("self:ConfirmSelectedSongAvailability", 1, true),
	"readiness must begin with the local availability barrier")
assert(autoReadySource:find("managerSelectionAlreadyConfirmed", 1, true)
	and autoReadySource:find("song_selected_auto_ready_availability_skipped", 1, true),
	"a preconfirmed single-player manager must skip the redundant availability request")
assert(autoReadySource:find("self.IsLocalTwoPlayerSession", 1, true),
	"the manager availability fast path must preserve the local Player 2 barrier")
assert(autoReadySource:find('self:SetReady("lobby_ready", true', 1, true),
	"a successful availability barrier must progress to ready")
assert(clientSource:find("song_availability_confirm_selected_deferred", 1, true),
	"an acknowledged missing-song report must not progress to any ready endpoint")
assert(autoReadySource:find("songSelectedAutoReadyInFlightCallbacks", 1, true),
	"every caller for one selected-song round must join the same ready transaction")
assert(autoReadySource:find("ready_snapshot_applied_by_availability", 1, true),
	"an authoritative ready snapshot must prevent a duplicate ready request")
local continueReadyStart = assert(autoReadySource:find("local function continueWithLobbyReady", 1, true),
	"the post-availability ready flow must remain isolated")
local managerFastPathStart = assert(autoReadySource:find("local managerSelectionAlreadyConfirmed", continueReadyStart, true),
	"the manager fast path boundary must remain identifiable")
local continueReadySource = autoReadySource:sub(continueReadyStart, managerFastPathStart - 1)
assert(not continueReadySource:find("CurrentUserConfirmedSelectedSong", 1, true),
	"a stale room snapshot must not prevent a ready request after availability succeeds")
assert(not autoReadySource:find("local_party_room_incomplete", 1, true),
	"the ready flow must not retain the obsolete local-party recovery branch")
local selectionReset = assert(clientSource:find('self:ResetOnlineRoundRuntimeState("song_selection")', 1, true),
	"song selection must reset the previous round")
local selectionAutoReady = assert(clientSource:find('"song_selection_stabilized"', selectionReset, true),
	"song selection must restart auto-readiness after the round reset")
assert(selectionReset < selectionAutoReady,
	"song selection must reset round state before starting availability")
assert(clientSource:find("reason=caller_owns_ready_orchestration", 1, true),
	"the manager selection wrapper must be the sole ready orchestrator")
assert(clientSource:find("end, { autoReady = false })", 1, true),
	"the manager wrapper must suppress the lower-level duplicate auto-ready flow")
assert(clientSource:find("song_availability_callbacks_ignored reason=stale_barrier", 1, true),
	"an obsolete availability response must not consume a newer selection's callbacks")
assert(clientSource:find("song_availability_context_invalidated", 1, true),
	"availability invalidation must release queued callers")
assert(clientSource:find("songSelectedAutoReadyGeneration", 1, true),
	"stale availability callbacks must not complete a newer ready transaction")
assert(clientSource:find("song_availability_join_inflight_context", 1, true),
	"duplicate availability callers must coalesce before recomputing local chart hashes")
assert(clientSource:find("song_availability_skipped reason=already_reported_context", 1, true),
	"an acknowledged selection must skip repeated local chart hash work")
assert(clientSource:find("companion_song_availability_response_ignored", 1, true),
	"an obsolete Player 2 availability response must not restore a stale room snapshot")
assert(clientSource:find("function ITGOnline:AcceptInvitationForLocalPlayer", 1, true),
	"an invitation addressed to either local player must be answerable")
assert(clientSource:find("companion_invitation_forwarded", 1, true),
	"Player 2 invitations must be forwarded to the coordinator UI")
assert(not clientSource:find("Online play supports one local player per client.", 1, true),
	"legacy local two-player score rejection must not remain")

local loginSource = read_source(
	"Themes/Simply Love/BGAnimations/ScreenITGOnlineLogin underlay/default.lua"
)
assert(loginSource:find("P1 = new_player_state(PLAYER_1)", 1, true),
	"login must own an independent Player 1 authentication state")
assert(loginSource:find("P2 = new_player_state(PLAYER_2)", 1, true),
	"login must own an independent Player 2 authentication state")
assert(loginSource:find("ApplyAccessTokenForPlayer", 1, true),
	"login must bind each token to its local profile")
assert(loginSource:find("all_required_players_connected", 1, true),
	"login must wait for every joined local player")
assert(loginSource:find('label = label .. " [" .. tostring(onlineName) .. "]"', 1, true),
	"the online name must identify a connected player without a local profile")

local lobbySource = read_source(
	"Themes/Simply Love/BGAnimations/ScreenOnlineLobbies overlay/default.lua"
)
assert(not lobbySource:find("local function online_lobby_text", 1, true),
	"lobby presentation helpers must stay outside the Lua chunk local limit")
assert(lobbySource:find("ITGOnlineLobbyPresentation.text", 1, true),
	"the lobby overlay must use the extracted presentation helper")
assert(lobbySource:find("ITGOnlineLobbyModel.online_lobby_state_signature", 1, true),
	"stable lobby view-model helpers must stay outside the overlay chunk")
local onlineHelpersSource = read_source("Themes/Simply Love/Scripts/SL-OnlineHelpers.lua")
local onlinePackSyncSource = read_source("Themes/Simply Love/Scripts/SL-OnlinePackSync.lua")
local optionsSource = read_source("Themes/Simply Love/BGAnimations/ScreenPlayerOptions common.lua")
local judgmentPreviewSource = read_source(
	"Themes/Simply Love/BGAnimations/ScreenPlayerOptions overlay/OptionRowPreviews/JudgmentGraphic.lua"
)
local noteSkinPreviewSource = read_source(
	"Themes/Simply Love/BGAnimations/ScreenPlayerOptions overlay/OptionRowPreviews/NoteSkin.lua"
)
local noteSkinVariantPreviewSource = read_source(
	"Themes/Simply Love/BGAnimations/ScreenPlayerOptions overlay/OptionRowPreviews/NoteSkinVariant.lua"
)
local optionRowFrameSource = read_source("Themes/Simply Love/Graphics/OptionRow Frame.lua")
local actorFrameSource = read_source("src/ActorFrame.cpp")
local themeMetricsSource = read_source("Themes/Simply Love/metrics.ini")
local onlineLobbyMetrics = ini_section(themeMetricsSource, "ScreenOnlineLobbies")
equal(onlineLobbyMetrics.PrepareScreens,
	"ScreenSelectMusic",
	"only song-independent online screens may preload before a song is selected")
assert(not tostring(onlineLobbyMetrics.PrepareScreens or ""):find("ScreenPlayerOptions", 1, true),
	"song-dependent player option screens must not be constructed from the lobby")
assert(not judgmentPreviewSource:find("or selected_count == 0", 1, true),
	"a transient missing player context must not cold-load every judgment graphic")
assert(judgmentPreviewSource:find("remember_selected_judgment(judgment_filename)", 1, true),
	"the judgment preview must retain a deterministic cold-start fallback")
assert(noteSkinPreviewSource:find("deferred=%d", 1, true),
	"the options screen must preload only selected NoteSkin previews")
assert(not noteSkinVariantPreviewSource:find("preloaded_all=true", 1, true),
	"the options screen must not cold-load every NoteSkin variant")
assert(optionRowFrameSource:find("TryLoadDeferredNoteSkin", 1, true),
	"an unselected NoteSkin preview must remain available through on-demand loading")
assert(optionRowFrameSource:find("AddChildFromLuaPathWithParams", 1, true),
	"deferred NoteSkin previews must retain their required Lua parameters")
assert(actorFrameSource:find("ADD_METHOD(AddChildFromLuaPathWithParams)", 1, true),
	"the engine must expose parameterized dynamic Lua actors to the theme")
assert(onlinePackSyncSource:find("server_confirms_single_player_manager_selection", 1, true),
	"a manager selection already confirmed by the server must avoid redundant pack-sync reports")
assert(onlinePackSyncSource:find("manager_selection_already_confirmed", 1, true),
	"the manager fast path must remain explicit and diagnosable")
equal(onlineLobbyMetrics.PersistScreens, "",
	"stateful online screens must be reconstructed between rounds")
assert(tostring(onlineLobbyMetrics.GroupedScreens or ""):find("ScreenGameplay", 1, true),
	"online transitions must keep the shared screen group until the round ends")
assert(not clientSource:find("function ITGOnline:MaybeAutoReadyManager", 1, true),
	"the manager must not run a second readiness orchestrator")
assert(not onlineHelpersSource:find("OnlineManagerAutoReadyRetryRequested", 1, true),
	"the obsolete manager ready retry handler must be removed")
local playingTickStart = assert(onlineHelpersSource:find("OnlinePlayingCountdownTickCommand=function", 1, true),
	"online runtime must expose its room countdown tick")
local playingTickEnd = assert(onlineHelpersSource:find("OnlineSongReloadCompletedMessageCommand=function", playingTickStart, true),
	"online countdown tick boundary must remain identifiable")
local playingTickSource = onlineHelpersSource:sub(playingTickStart, playingTickEnd - 1)
assert(not playingTickSource:find("ITGOnline:FlushLiveScore", 1, true),
	"the room countdown must not duplicate ScreenGameplay's primary live-score transport loop")
local countdownPolicyStart = assert(onlineHelpersSource:find("function room_countdown_should_run", 1, true),
	"online runtime must expose a dedicated countdown policy")
local countdownPolicyEnd = assert(onlineHelpersSource:find("function start_connection_timers", countdownPolicyStart, true),
	"countdown policy boundary must remain identifiable")
local countdownPolicySource = onlineHelpersSource:sub(countdownPolicyStart, countdownPolicyEnd - 1)
assert(countdownPolicySource:find('normalized_room_phase_for_runtime() ~= "starting"', 1, true),
	"the pre-song countdown must stop as soon as gameplay starts")
assert(not onlineHelpersSource:find("room_fast_runtime_should_run", 1, true),
	"the old starting-or-playing countdown policy must not return")
assert(onlineScorePushSource:find("ITGOnline:FlushLiveScore()", 1, true),
	"ScreenGameplay must remain the sole owner of primary live-score transport")
local helperReadyStart = assert(onlineHelpersSource:find("function maybe_set_lobby_ready", 1, true),
	"online screens must expose a single ready delegation helper")
local helperReadyEnd = assert(onlineHelpersSource:find("function maybe_preview_current_online_song", helperReadyStart, true),
	"ready delegation helper boundary must remain identifiable")
local helperReadySource = onlineHelpersSource:sub(helperReadyStart, helperReadyEnd - 1)
assert(helperReadySource:find("MaybeAutoConfirmSelectedSongAndMarkLobbyReady", 1, true),
	"screen-level ready requests must delegate to the client orchestrator")
assert(not helperReadySource:find("ITGOnline:SetReady", 1, true),
	"screen-level ready requests must not bypass the client orchestrator")
local packReadyStart = assert(onlinePackSyncSource:find("function PackSync:MarkLobbyReadyForSelectedSong", 1, true),
	"pack synchronization must expose selected-song readiness")
local packReadyEnd = assert(onlinePackSyncSource:find("-- External catalogue lookup", packReadyStart, true),
	"pack readiness boundary must remain identifiable")
local packReadySource = onlinePackSyncSource:sub(packReadyStart, packReadyEnd - 1)
assert(packReadySource:find("MaybeAutoConfirmSelectedSongAndMarkLobbyReady", 1, true),
	"pack synchronization must join the client ready transaction")
assert(not packReadySource:find("ITGOnline:SetReady", 1, true),
	"pack synchronization must not issue an independent lobby-ready request")
assert(onlinePackSyncSource:find("apply_selected_chart_cached", 1, true),
	"repeated room snapshots must not rescan and rehash an already applied local chart")
assert(onlinePackSyncSource:find("localSongLibraryFingerprintCount == #songs", 1, true),
	"the unchanged local song library must reuse its directory fingerprint")
assert(lobbySource:find("local_companion_read_only", 1, true),
	"Player 2 lobby controls must remain read-only")
assert(lobbySource:find("user.isLocalCompanion", 1, true),
	"the local companion must not expose invitation actions")
assert(lobbySource:find('"WithPlayer"', 1, true),
	"remote local parties must display their companion name")
assert(clientSource:find("party_companion_descriptor", 1, true),
	"online presence party relations must be normalized centrally")
assert(clientSource:find("party_companion_descriptor(member)", 1, true),
	"joined-room players must prefer the companion relation supplied by the room snapshot")
assert(clientSource:find("partyCompanionName = partyCompanion and partyCompanion.name", 1, true),
	"room and online projections must retain the companion display name")
assert(onlineHelpersSource:find("player.isLocalCompanion == true", 1, true),
	"joined-room players must identify the local companion")
assert(clientSource:find("companion_ready_song_hash_recovered", 1, true),
	"companion readiness must survive the shared options transition")
assert(clientSource:find("action=server_authoritative_request", 1, true),
	"the server must validate companion membership when a local room snapshot is incomplete")
assert(companionReadySource:find("companion_ready_join_inflight", 1, true),
	"duplicate Player 2 readiness callers must join the authoritative request")
assert(not companionReadySource:find("error_code = \"companion_ready_in_flight\"", 1, true),
	"an existing Player 2 readiness request must not be reported as a failure")
assert(lobbySource:find("ITGOnlineLobbyPresentation.player_status_label", 1, true),
	"online player statuses must use localized labels")
assert(onlineHelpersSource:find("deferredConfigReadyAfterOptionsExit", 1, true),
	"options completion must survive a transient room-context gap")
assert(onlineHelpersSource:find("retry_deferred_config_ready", 1, true),
	"deferred options completion must be retried after room restoration")
assert(not onlineHelpersSource:find("ITGOnline.inLobby", 1, true),
	"screen transitions must read the lobby state from their actor, not the API client")
assert(optionsSource:find("onlineOptionsSessionActive", 1, true),
	"online options must preserve their room context during screen transitions")

local scoreSource = read_source("Themes/Simply Love/BGAnimations/ScreenGameplay underlay/PerPlayer/Score.lua")
local messageManagerSource = read_source("src/MessageManager.cpp")
assert(not scoreSource:find("OnlineScoreSnapshot", 1, true)
	and not onlineHelpersSource:find("OnlineScoreSnapshot", 1, true)
	and not messageManagerSource:find("OnlineScoreSnapshot", 1, true),
	"presentation code and the native message bus must not retain the legacy score pipeline")

local trackFailTimeSource = read_source(
	"Themes/Simply Love/BGAnimations/ScreenGameplay overlay/TrackFailTime.lua"
)
assert(not trackFailTimeSource:find("MarkPlayFailedEarly", 1, true),
	"the theme must not duplicate the engine's authoritative per-player failure event")

local stepStatisticsSource = read_source(
	"Themes/Simply Love/BGAnimations/ScreenGameplay underlay/PerPlayer/StepStatistics/default.lua"
)
assert(stepStatisticsSource:find("if OnlineGameplay then return end", 1, true),
	"online gameplay must suppress local Step Statistics counters")
local versusStepStatisticsSource = read_source(
	"Themes/Simply Love/BGAnimations/ScreenGameplay underlay/Shared/VersusStepStatistics.lua"
)
assert(versusStepStatisticsSource:find("IsOnlineGameplaySessionActive", 1, true),
	"online local versus gameplay must suppress the shared central judgment counters")
assert(versusStepStatisticsSource:find("online_step_statistics_suppressed", 1, true),
	"shared judgment-counter suppression must remain diagnosable")

assert(onlineHelpersSource:find("music_select_back_consumed", 1, true),
	"Back must be consumed while the selected-song screen is already transitioning")
assert(onlineHelpersSource:find("native_music_selection_finalized", 1, true),
	"Back must be consumed from the native finalized-selection state")
assert(onlineHelpersSource:find("song_selection_commit_in_progress", 1, true),
	"Back must not race an in-flight online song-selection commit")
assert(onlineHelpersSource:find("screen:SetInputCallbacksHandleBeforeScreen(true)", 1, true),
	"the online music-selection guard must run before the native Back handler")
local selectMusicHeaderSource = read_source("src/ScreenSelectMusic.h")
local selectMusicNativeSource = read_source("src/ScreenSelectMusic.cpp")
assert(selectMusicHeaderSource:find("IsMusicSelectionFinalized", 1, true),
	"the native finalized-selection state must be exposed to the online guard")
assert(selectMusicNativeSource:find("if (!m_Out.IsWaiting())", 1, true),
	"a non-reusable outgoing transition must use the direct lobby fallback")
assert(selectMusicNativeSource:find('SCREENMAN->SetNewScreen("ScreenOnlineLobbies")', 1, true),
	"the black-screen guard must have a deterministic lobby fallback")
assert(onlineHelpersSource:find("song_preview_deferred reason=screen_generation_not_committed", 1, true),
	"the initial song preview must wait for the music-selection screen generation")
assert(clientSource:find("realtime_transport_frame:", 1, true),
	"transport keepalive logs must be aggregated without disabling online diagnostics")
assert(clientSource:find("realtime_event_apply:server.ping", 1, true),
	"successful server ping application logs must be throttled")
assert(clientSource:find("staleFinalCallbacks", 1, true),
	"stale companion score responses must release queued final callbacks")
assert(clientSource:find("if previous", 1, true),
	"a throttled trace must not suppress the first diagnostic occurrence")
assert(clientSource:find("heartbeat_deferred reason=initial_sync_room_unknown", 1, true),
	"initial presence must wait until synchronization resolves an existing room")
assert(clientSource:find("heartbeat_deferred_sync_dispatch", 1, true),
	"deferred presence must be replayed with the authoritative room context")
assert(onlineHelpersSource:find("queue_presence_update", 1, true)
	and onlineHelpersSource:find("PresenceUpdateTimer", 1, true)
	and onlineHelpersSource:find("FlushPresenceUpdateCommand", 1, true),
	"screen presence must be deferred and coalesced outside the transition frame")
assert(not onlineHelpersSource:find('safe_broadcast("UpdateMachineState")', 1, true)
	and not onlineHelpersSource:find("UpdateMachineStateMessageCommand", 1, true),
	"screen changes must not fan out through the legacy forced-heartbeat message")
assert(onlineHelpersSource:find("OnlineGameplayInitializeTimer", 1, true)
	and onlineHelpersSource:find("InitializeOnlineGameplayCommand", 1, true),
	"gameplay network initialization must run after the screen transition frame")
assert(clientSource:find('stream_profile = "control"', 1, true),
	"the companion websocket must request the low-volume control stream")

local gameLoopSource = read_source("src/GameLoop.cpp")
assert(gameLoopSource:find("PERF_TRACE: fps_drop", 1, true),
	"FPS drops must have targeted diagnostics")
assert(gameLoopSource:find("network_ms=%.3f", 1, true),
	"low-FPS diagnostics must expose the network phase cost")
assert(gameLoopSource:find("kCriticalFrameHitchSeconds", 1, true),
	"critical frame hitches must be logged even with verbose diagnostics disabled")
assert(gameLoopSource:find("if (!PerfTraceRateLimit(nowUsec))", 1, true),
	"always-on hitch diagnostics must remain rate-limited")

local rageDisplaySource = read_source("src/RageDisplay.cpp")
assert(not rageDisplaySource:find(
	"std::max<uint64_t>(wakeUsec - nowUsec, 10000)", 1, true
), "background frame pacing must not overshoot high-refresh deadlines")
assert(rageDisplaySource:find(
	"Background throttling must lower the target rate", 1, true
), "background frame pacing must preserve deadline ownership")

local messageManagerSource = read_source("src/MessageManager.cpp")
assert(not messageManagerSource:find("LOG->Flush()", 1, true),
	"verbose online message traces must not force synchronous disk flushes")
local networkManagerSource = read_source("src/NetworkManager.cpp")
assert(networkManagerSource:find("IsRoutineWebSocketControlFrame", 1, true),
	"native transport logs must suppress redundant successful control frames")
local perfDiagnosticsSource = read_source("src/PerfDiagnostics.cpp")
assert(perfDiagnosticsSource:find("kRefreshIntervalSeconds = 30", 1, true),
	"online diagnostic preferences must not poll the filesystem every frame")
assert(perfDiagnosticsSource:find("OnlineNetworkDiagnosticsEnabled", 1, true),
	"native online diagnostics must share one cached preference")
local metalPresenterSource = read_source(
	"src/arch/LowLevelWindow/MacOSMetalPresenter.mm"
)
local metalPresentationPolicySource = read_source(
	"src/arch/LowLevelWindow/MacOSMetalPresentationPolicy.cpp"
)
assert(metalPresenterSource:find(
	"impl->presentationPolicy.displaySyncEnabled ? YES : NO", 1, true
), "Metal layer display sync must follow the explicit presentation policy")
assert(metalPresentationPolicySource:find(
	"case Mode::CompositedWindow:", 1, true
) and metalPresentationPolicySource:find(
	"policy.displaySyncEnabled = false;", 1, true
) and metalPresentationPolicySource:find(
	"policy.scheduleMinimumPresentDuration = false;", 1, true
), "engine-paced composited presentation must not add a second cadence")
assert(metalPresenterSource:find("afterMinimumDuration:", 1, true)
	and metalPresenterSource:find("ScheduleMetalDrawable(", 1, true),
	"Metal presentation must schedule drawables through the selected policy")
assert(metalPresenterSource:find("pacing_owner=%s", 1, true),
	"Metal cadence ownership must remain mode-aware in runtime diagnostics")

local rankingSource = read_source(
	"Themes/Simply Love/BGAnimations/ScreenEvaluation common/Shared/OnlineFinalRanking.lua"
)
assert(rankingSource:find(":draworder(40):visible(false)", 1, true),
	"the final online ranking must draw above evaluation grades")

assert(lobbySource:find("generatedEnglishName", 1, true),
	"generated invitation room names must be localized before display")
for _, language in ipairs({ "en", "fr", "es", "de", "it", "ja", "pl", "pt-br", "ru" }) do
	local languageSource = read_source("Themes/Simply Love/Languages/" .. language .. ".ini")
	assert(languageSource:find("PlayerLobbyName=", 1, true),
		"invitation room names must be localized for " .. language)
end

local englishOnlineText = ini_section(
	read_source("Themes/Simply Love/Languages/en.ini"),
	"ScreenOnlineLobbies"
)
local frenchOnlineText = ini_section(
	read_source("Themes/Simply Love/Languages/fr.ini"),
	"ScreenOnlineLobbies"
)
local intentionallyUniversalFrenchText = {
	AccuracyShort = true,
	HttpOnly = true,
	LobbyNameValue = true,
	RealtimeHttpOnly = true,
	ScreenOptionsLabel = true,
	ScreenTransitionLabel = true,
	Start = true,
	TypeColumn = true,
}
for key, englishValue in pairs(englishOnlineText) do
	local frenchValue = assert(frenchOnlineText[key],
		"French online translation is missing key " .. tostring(key))
	equal(format_placeholders(frenchValue), format_placeholders(englishValue),
		"French online placeholders for " .. tostring(key))
	if not intentionallyUniversalFrenchText[key] then
		assert(frenchValue ~= englishValue,
			"French online translation still contains English text for " .. tostring(key))
	end
end

local branchSource = read_source("Themes/Simply Love/Scripts/SL-Branches.lua")
assert(branchSource:find('styleName == "couple"', 1, true),
	"online couple mode must be rejected")
assert(branchSource:find('styleName == "routine"', 1, true),
	"online routine mode must be rejected")

print("online local party spec: ok")
