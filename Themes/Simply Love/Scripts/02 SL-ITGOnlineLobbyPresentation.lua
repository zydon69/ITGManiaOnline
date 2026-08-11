ITGOnlineLobbyPresentation = ITGOnlineLobbyPresentation or {}

local Presentation = ITGOnlineLobbyPresentation

function Presentation.text(key, fallback, ...)
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

function Presentation.player_status_label(status)
	local normalized = tostring(status or ""):lower()
	local key = ({
		available = "StatusAvailable",
		in_room = "StatusInRoom",
		playing = "StatusPlaying",
	})[normalized]
	if key then return Presentation.text(key, status) end
	return tostring(status or "")
end

function Presentation.local_player_suffix(player)
	if type(player) ~= "table" then return "" end
	local side = tostring(player.localSide or player.local_side or "")
	if side == "P1" or side == "P2" then
		return "(" .. side .. ")"
	end
	if side == "self" or player.isSelf == true then
		return "(" .. Presentation.text("Me", "Me") .. ")"
	end
	-- Keep older cached room projections readable during a live theme reload.
	if player.isLocalCompanion == true then return "(P2)" end
	return ""
end

function Presentation.is_local_player(player)
	return Presentation.local_player_suffix(player) ~= ""
end

return Presentation
