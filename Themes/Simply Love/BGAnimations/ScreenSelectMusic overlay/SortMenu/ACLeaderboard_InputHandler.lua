-- This handles user input while in the ArrowCloud leaderboard overlay.
local function input(event)
	if not (event and event.PlayerNumber and event.button) then
		return false
	end
	if not GAMESTATE:IsSideJoined(event.PlayerNumber) then
		return false
	end

	SOUND:StopMusic()

	local screen = SCREENMAN:GetTopScreen()
	local overlay = screen:GetChild("Overlay")

	if event.type ~= "InputEventType_Repeat" then
		MESSAGEMAN:Broadcast("ACLeaderboardInputEvent", event)
	end

	if (event.GameButton == "Start" or event.GameButton == "Back") and event.type ~= "InputEventType_Release" then
		overlay:queuecommand("DirectInputToEngine")
	end

	return false
end

return input
