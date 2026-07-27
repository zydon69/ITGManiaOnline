ITGOnlineRealtimeEventRouter = ITGOnlineRealtimeEventRouter or {}

local Router = ITGOnlineRealtimeEventRouter

local idlessControlEvents = {
	["connection.ready"] = true,
	["connection.closed"] = true,
	["server.ping"] = true,
	["pong"] = true,
	["client.error"] = true,
	["auth.session_revoked"] = true,
}

local lobbyEvents = {
	["room.left"] = true,
	["lobby.updated"] = true,
	["room.invitation.created"] = true,
	["room.join_request.created"] = true,
	["room.join_request.declined"] = true,
	["room.join_request.expired"] = true,
	["room.join_request.cancelled"] = true,
	["room.join_request.accepted"] = true,
}

local scoreEvents = {
	["room.score_updated"] = true,
	["room.results_ready"] = true,
}

function Router.route(event, canonicalId)
	if type(event) ~= "table" then return nil, "malformed_event" end
	local name = event.event or event.name
	local payload = event.payload or {}
	if type(name) ~= "string" or name == "" or type(payload) ~= "table" then
		return nil, "invalid_schema"
	end

	local eventId = canonicalId and canonicalId(event.id) or event.id
	if (eventId == nil or tostring(eventId) == "0") and idlessControlEvents[name] ~= true then
		return nil, "idless_non_control"
	end

	local category = "control"
	if scoreEvents[name] then
		category = "score"
	elseif lobbyEvents[name] then
		category = "lobby"
	elseif name:match("^room%.") then
		category = "room"
	elseif name ~= "connection.ready"
		and name ~= "connection.closed"
		and name ~= "server.ping"
		and name ~= "pong"
		and name ~= "client.error"
		and name ~= "auth.session_revoked" then
		category = "unknown"
	end

	return {
		name = name,
		payload = payload,
		eventId = eventId,
		category = category,
		serverTime = event.server_time,
	}
end

function Router.requires_non_room_policy(route)
	if type(route) ~= "table" then return false end
	local name = tostring(route.name or "")
	return not name:match("^room%.")
		or name == "room.left"
		or name == "room.invitation.created"
		or name == "room.join_request.declined"
		or name == "room.join_request.expired"
		or name == "room.join_request.cancelled"
		or name == "room.join_request.accepted"
end

return Router
