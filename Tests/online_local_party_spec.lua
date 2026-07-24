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
assert(clientSource:find("function ITGOnline:RequestCompanionJoinRequest", 1, true),
	"private-room membership must be synchronized for Player 2")
assert(clientSource:find("function ITGOnline:ActiveLocalPartyId", 1, true),
	"both local presences must publish the same ephemeral party identity")
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
assert(lobbySource:find("local_companion_read_only", 1, true),
	"Player 2 lobby controls must remain read-only")
assert(lobbySource:find("user.isLocalCompanion", 1, true),
	"the local companion must not expose invitation actions")
assert(lobbySource:find('"WithPlayer"', 1, true),
	"remote local parties must display their companion name")

local branchSource = read_source("Themes/Simply Love/Scripts/SL-Branches.lua")
assert(branchSource:find('styleName == "couple"', 1, true),
	"online couple mode must be rejected")
assert(branchSource:find('styleName == "routine"', 1, true),
	"online routine mode must be rejected")

print("online local party spec: ok")
