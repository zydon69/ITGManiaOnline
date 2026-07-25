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
			if key then entries[key] = value end
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
assert(clientSource:find("ITGOnline.onlineFlowLoggingDefaultEnabled = true", 1, true),
	"new installations must enable online network diagnostics by default")
assert(not clientSource:find("forceOnlineFlowLogging", 1, true),
	"online diagnostics must remain a preference after their initial default is applied")
assert(clientSource:find('["OnlineTrace"] = "true"', 1, true),
	"new debug configurations must enable the online trace")
assert(clientSource:find("function ITGOnline:SendCompanionScore", 1, true),
	"client must expose an isolated Player 2 score pipeline")
assert(clientSource:find("onlineStateTraceThrottle", 1, true),
	"high-frequency state tracing must be throttled without disabling online diagnostics")
assert(clientSource:find("options_room_snapshot_authoritative", 1, true),
	"the options screen must not refresh the whole lobby from a room-scoped realtime update")
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
assert(clientSource:find("should_submit_companion_ready", 1, true),
	"the paired readiness barrier must use the tested local-party policy")
assert(clientSource:find("should_fan_out_companion_not_ready", 1, true),
	"clearing paired readiness must use the tested local-party policy")
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
assert(autoReadySource:find('self:SetReady("lobby_ready", true', 1, true),
	"a successful availability barrier must progress to ready")
assert(not autoReadySource:find("CurrentUserConfirmedSelectedSong", 1, true),
	"a stale room snapshot must not prevent a ready request after availability succeeds")
assert(not autoReadySource:find("local_party_room_incomplete", 1, true),
	"the ready flow must not retain the obsolete local-party recovery branch")
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
assert(not lobbySource:find("local function online_lobby_text", 1, true),
	"lobby presentation helpers must stay outside the Lua chunk local limit")
assert(lobbySource:find("ITGOnlineLobbyPresentation.text", 1, true),
	"the lobby overlay must use the extracted presentation helper")
assert(lobbySource:find("ITGOnlineLobbyModel.online_lobby_state_signature", 1, true),
	"stable lobby view-model helpers must stay outside the overlay chunk")
local onlineHelpersSource = read_source("Themes/Simply Love/Scripts/SL-OnlineHelpers.lua")
local optionsSource = read_source("Themes/Simply Love/BGAnimations/ScreenPlayerOptions common.lua")
assert(not clientSource:find("function ITGOnline:MaybeAutoReadyManager", 1, true),
	"the manager must not run a second readiness orchestrator")
assert(not onlineHelpersSource:find("OnlineManagerAutoReadyRetryRequested", 1, true),
	"the obsolete manager ready retry handler must be removed")
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
assert(scoreSource:find("should_broadcast_online_score_snapshot", 1, true),
	"only the primary local score feed must use OnlineScoreSnapshot")

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
