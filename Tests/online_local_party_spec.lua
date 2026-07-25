local sourceRoot = assert(arg[1], "source root is required")
local party = assert(dofile(
	sourceRoot .. "/Themes/Simply Love/Scripts/02 SL-ITGOnlineLocalParty.lua"
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

local clientSource = read_source("Themes/Simply Love/Scripts/SL-ITGOnlineClient.lua")
assert(clientSource:find("function ITGOnline:SendCompanionScore", 1, true),
	"client must expose an isolated Player 2 score pipeline")
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
assert(clientSource:find("function ITGOnline:CaptureLocalPartyPlan", 1, true),
	"the online session must capture local party membership once")
assert(clientSource:find("function ITGOnline:RequiredLocalPlayers", 1, true),
	"critical online requests must use the captured local party")
assert(clientSource:find("companion_ready_barrier_result", 1, true),
	"Player 1 ready must wait for the companion ready response")
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
assert(clientSource:find("function ITGOnline:RequiredLocalPlayersConfirmedSelectedSong", 1, true),
	"the lobby-ready barrier must validate both local players")
assert(clientSource:find("function ITGOnline:RefreshLocalPartyRoomForSongSelectedAutoReady", 1, true),
	"a partial local-party room snapshot must be refreshed before readiness is abandoned")
assert(clientSource:find("reason=local_party_room_incomplete", 1, true),
	"local-party readiness must recover from a transient incomplete room snapshot")
local selectionReset = assert(clientSource:find('self:ResetOnlineRoundRuntimeState("song_selection")', 1, true),
	"song selection must reset the previous round")
local selectionAutoReady = assert(clientSource:find('"song_selection_stabilized"', selectionReset, true),
	"song selection must restart auto-readiness after the round reset")
assert(selectionReset < selectionAutoReady,
	"song selection must reset round state before starting availability")
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
local onlineHelpersSource = read_source("Themes/Simply Love/Scripts/SL-OnlineHelpers.lua")
local optionsSource = read_source("Themes/Simply Love/BGAnimations/ScreenPlayerOptions common.lua")
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
assert(clientSource:find("retryAfter = 0.75, error_code = \"local_party_room_incomplete\"", 1, true),
	"transient local-party readiness failures must be retried")
assert(lobbySource:find("online_player_status_label", 1, true),
	"online player statuses must use localized labels")
assert(onlineHelpersSource:find("deferredConfigReadyAfterOptionsExit", 1, true),
	"options completion must survive a transient room-context gap")
assert(onlineHelpersSource:find("retry_deferred_config_ready", 1, true),
	"deferred options completion must be retried after room restoration")
assert(not onlineHelpersSource:find("ITGOnline.inLobby", 1, true),
	"screen transitions must read the lobby state from their actor, not the API client")
assert(optionsSource:find("onlineOptionsSessionActive", 1, true),
	"online options must preserve their room context during screen transitions")

local branchSource = read_source("Themes/Simply Love/Scripts/SL-Branches.lua")
assert(branchSource:find('styleName == "couple"', 1, true),
	"online couple mode must be rejected")
assert(branchSource:find('styleName == "routine"', 1, true),
	"online routine mode must be rejected")

print("online local party spec: ok")
