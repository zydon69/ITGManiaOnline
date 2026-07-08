local Players = GAMESTATE:GetHumanPlayers()
local NumPanes = SL.Global.GameMode=="Casual" and 1 or 11

local InputHandler = nil
local EventOverlayInputHandler = nil
local OnlineEvaluationInputHandler = nil

local function OnlineEvaluationActive()
	return ITGOnline and ITGOnline.currentRoomId ~= nil
end

local function OnlineDisplayName(user, fallback)
	if ITGOnline and ITGOnline.UserDisplayName then
		return ITGOnline:UserDisplayName(user, fallback)
	end
	user = type(user) == "table" and user or {}
	return tostring(user.display_name or user.displayName or user.name or fallback or "Player")
end

local function SetOnlineEvaluationInputRedirected(enabled, reason)
	if type(online_logs_enabled) == "function" and online_logs_enabled() then
		Trace("ITG Online: FLOW evaluation_input_redirect"
			.. " enabled=" .. tostring(enabled == true)
			.. " reason=" .. tostring(reason or "unknown")
			.. " room=" .. tostring(ITGOnline.currentRoomId or "nil")
			.. " phase=" .. tostring(ITGOnline.currentRoom and ITGOnline.currentRoom.phase or "nil"))
	end
	if not OnlineEvaluationActive() then return end
	for player in ivalues(PlayerNumber) do
		SCREENMAN:set_input_redirected(player, enabled == true)
	end
	if online_trace then
		online_trace("FLOW evaluation_input_redirected enabled=" .. tostring(enabled == true)
			.. " reason=" .. tostring(reason or "unknown"))
	end
end

local function ReturnToOnlineLobby(reason)
	if type(online_logs_enabled) == "function" and online_logs_enabled() then
		Trace("ITG Online: FLOW evaluation_return_to_lobby_begin"
			.. " reason=" .. tostring(reason or "unknown")
			.. " room=" .. tostring(ITGOnline.currentRoomId or "nil")
			.. " phase=" .. tostring(ITGOnline.currentRoom and ITGOnline.currentRoom.phase or "nil"))
	end
	if ITGOnlineReturnToLobbyFromEvaluation and ITGOnlineReturnToLobbyFromEvaluation(reason) then
		return true
	end

	local topScreen = SCREENMAN:GetTopScreen()
	if not topScreen then return false end
	if ITGOnline then ITGOnline.onlineEvaluationExitRequested = true end
	if online_trace then
		online_trace("FLOW evaluation_exit_requested reason=" .. tostring(reason or "fallback")
			.. " screen=" .. tostring(topScreen:GetName()))
	end
	SetOnlineEvaluationInputRedirected(false, "exit_fallback")
	topScreen:SetNextScreenName("ScreenOnlineLobbies")
	topScreen:StartTransitioningScreen("SM_GoToNextScreen")
	return true
end

local function IsEvaluationExitInput(event)
	if not event then return false end
	local deviceButton = ""
	if event.DeviceInput and event.DeviceInput.button then
		deviceButton = string.lower(tostring(event.DeviceInput.button))
	end
	return event.GameButton == "Start"
		or event.GameButton == "Back"
		or string.find(deviceButton, "enter", 1, true) ~= nil
		or string.find(deviceButton, "return", 1, true) ~= nil
		or deviceButton == "devicebutton_z"
		or deviceButton == "z"
		or string.find(deviceButton, "escape", 1, true) ~= nil
		or string.find(deviceButton, "backspace", 1, true) ~= nil
end

local function BuildOnlineEvaluationInputHandler(reason)
	return function(event)
		if not OnlineEvaluationActive() then return false end
		if not IsEvaluationExitInput(event) then return false end
		if event.type ~= "InputEventType_FirstPress" and event.type ~= "InputEventType_Repeat" then
			return true
		end

		if online_trace then
			local summary = ITGOnline.PlayStateSummary and ITGOnline:PlayStateSummary() or nil
			online_trace("FLOW evaluation_input button=" .. tostring(event.GameButton)
				.. " type=" .. tostring(event.type)
				.. " reason=" .. tostring(reason or "unknown")
				.. " terminal=" .. tostring(summary and summary.terminal or "nil")
				.. " players=" .. tostring(summary and summary.players or "nil"))
		end

		if event.type == "InputEventType_FirstPress" then
			ReturnToOnlineLobby("evaluation_common_input")
		end
		return true
	end
end

local function DisableOnlineEvaluationTimer(reason)
	if type(online_logs_enabled) == "function" and online_logs_enabled() then
		Trace("ITG Online: FLOW evaluation_timer_disable"
			.. " reason=" .. tostring(reason or "unknown")
			.. " room=" .. tostring(ITGOnline.currentRoomId or "nil")
			.. " phase=" .. tostring(ITGOnline.currentRoom and ITGOnline.currentRoom.phase or "nil"))
	end
	if not (ITGOnline and ITGOnline.currentRoomId) then return end
	local screen = SCREENMAN:GetTopScreen()
	local timer = screen and screen:GetChild("Timer") or nil
	if not timer then
		if online_trace then
			online_trace("FLOW evaluation_timer_absent reason=" .. tostring(reason or "unknown"))
		end
		return
	end

	pcall(function() timer:disable() end)
	pcall(function() timer:pause() end)
	pcall(function() timer:stop() end)
	pcall(function() timer:SetSeconds(999) end)
	timer:visible(false)
	if online_trace then
		online_trace("FLOW evaluation_timer_disabled reason=" .. tostring(reason or "unknown"))
	end
end

if ThemePrefs.Get("WriteCustomScores") then
	WriteScores()
end

local t = Def.ActorFrame{Name="ScreenEval Common"}

if SL.Global.GameMode ~= "Casual" then
	-- add a lua-based InputCalllback to this screen so that we can navigate
	-- through multiple panes of information; pass a reference to this ActorFrame
	-- and the number of panes there are to InputHandler.lua
	t.OnCommand=function(self)
		InputHandler = LoadActor("./InputHandler.lua", {self, NumPanes})
		EventOverlayInputHandler = LoadActor("./Shared/EventInputHandler.lua")
		local screen = SCREENMAN:GetTopScreen()
		if screen then
			OnlineEvaluationInputHandler = BuildOnlineEvaluationInputHandler("standard")
			screen:AddInputCallback(OnlineEvaluationInputHandler)
			screen:AddInputCallback(InputHandler)
			DisableOnlineEvaluationTimer("on_command")
		end
		PROFILEMAN:SaveMachineProfile()
	end
	t.DirectInputToEngineCommand=function(self)
		SCREENMAN:GetTopScreen():RemoveInputCallback(EventOverlayInputHandler)
		SCREENMAN:GetTopScreen():AddInputCallback(InputHandler)

		for player in ivalues(PlayerNumber) do
			SCREENMAN:set_input_redirected(player, false)
		end
	end
	t.DirectInputToEventOverlayHandlerCommand=function(self)
		SCREENMAN:GetTopScreen():RemoveInputCallback(InputHandler)
		SCREENMAN:GetTopScreen():AddInputCallback(EventOverlayInputHandler)

		for player in ivalues(PlayerNumber) do
			SCREENMAN:set_input_redirected(player, true)
		end
	end
else
	t.OnCommand=function(self)
		OnlineEvaluationInputHandler = BuildOnlineEvaluationInputHandler("casual")
		local screen = SCREENMAN:GetTopScreen()
		if screen then screen:AddInputCallback(OnlineEvaluationInputHandler) end
		DisableOnlineEvaluationTimer("casual_on_command")
		PROFILEMAN:SaveMachineProfile()
	end
end

t.OffCommand=function(self)
	local screen = SCREENMAN:GetTopScreen()
	if screen and OnlineEvaluationInputHandler then
		screen:RemoveInputCallback(OnlineEvaluationInputHandler)
	end
	SetOnlineEvaluationInputRedirected(false, "off")
end

-- -----------------------------------------------------------------------
-- First, add actors that would be the same whether 1 or 2 players are joined.

-- code for triggering a screenshot and animating a "screenshot" texture
t[#t+1] = LoadActor("./Shared/ScreenshotHandler.lua")

-- code for non-normal exits, such as restarting the song or entering practice mode
t[#t+1] = LoadActor("./Shared/ExitHandler.lua")

-- online final ranking, displayed only after the server has validated results
t[#t+1] = LoadActor("./Shared/OnlineFinalRanking.lua")

-- store some attributes of this playthrough of this song in the global SL table
-- for later retrieval on ScreenEvaluationSummary
t[#t+1] = LoadActor("./Shared/GlobalStorage.lua")

-- help text that appears if we're in Casual gamemode
t[#t+1] = LoadActor("./Shared/CasualHelpText.lua")

-- -----------------------------------------------------------------------
-- Then, load player-specific actors.

for player in ivalues(Players) do

	-- store player stats for later retrieval on EvaluationSummary and NameEntryTraditional
	-- this doesn't draw anything to the screen, it just runs some code
	t[#t+1] = LoadActor("./PerPlayer/Storage.lua", player)

	-- the per-player lower half of ScreenEvaluation, including:
	-- judgment scatterplot, modifier list, disqualified text
	t[#t+1] = LoadActor("./PerPlayer/Lower/default.lua", player)

	-- Generate the .itl file for the player.
	-- When the event isn't active, this actor is nil.
	t[#t+1] = LoadActor("./PerPlayer/ItlFile.lua", player)

	-- Save best local ghost data for future pacemaker comparisons.
	t[#t+1] = LoadActor("./PerPlayer/SaveGhostData.lua", player)
end

-- -----------------------------------------------------------------------
-- Then load the Panes.

t[#t+1] = LoadActor("./Panes/default.lua", NumPanes)

-- -----------------------------------------------------------------------

-- Draw upper player data after the lower panels and panes.  Their background
-- quads are meant to sit behind evaluation data, never over the grades,
-- difficulty labels, or step artist text.
for player in ivalues(Players) do
	t[#t+1] = LoadActor("./PerPlayer/Upper/default.lua", player)..{
		InitCommand=function(self) self:draworder(20) end
	}
end

-- Draw the song identity layer last among the normal evaluation content so
-- the banner, title, BPM, artist, and length cannot be tinted by pane panels.
t[#t+1] = LoadActor("./Shared/TitleAndBanner.lua")..{
	InitCommand=function(self) self:draworder(30) end
}
t[#t+1] = LoadActor("./Shared/SongFeatures.lua")..{
	InitCommand=function(self) self:draworder(30) end
}

-- -----------------------------------------------------------------------

-- The actor that will automatically upload scores to GrooveStats.
-- This is only added in "dance" mode and if the service is available.
-- Since this actor also spawns the event overlay it must go on top of everything else
t[#t+1] = LoadActor("./Shared/AutoSubmitScore.lua")

if OnlineEvaluationActive() then
	t[#t+1] = LoadFont("Common Normal")..{
		Name="ITGOnlineConnectionStatus",
		Text="",
		InitCommand=function(self)
			self:xy(_screen.w - 14, _screen.h - 18):halign(1):zoom(0.45):diffuse(Color.White):shadowlength(1)
		end,
		OnCommand=function(self)
			self:queuecommand("RefreshOnlineStatus")
		end,
		RefreshOnlineStatusCommand=function(self)
			if not ITGOnline or not ITGOnline.currentRoomId then
				self:settext("")
				self:sleep(0.5):queuecommand("RefreshOnlineStatus")
				return
			end

			local handler = GetOnlineHandlerInstance and GetOnlineHandlerInstance() or nil
			local connected = handler and handler.connected and handler.socket ~= nil
			self:settext(connected and "ITG Online: connected" or "ITG Online: reconnecting")
			self:diffuse(connected and color("#66ff99") or Color.Yellow)
			self:sleep(0.5):queuecommand("RefreshOnlineStatus")
		end
	}
end

return t
