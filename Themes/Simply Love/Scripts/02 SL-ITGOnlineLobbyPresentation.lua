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

return Presentation
