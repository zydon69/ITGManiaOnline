local Players = GAMESTATE:GetHumanPlayers()
local NumPanes = SL.Global.GameMode=="Casual" and 1 or 8

local InputHandler = nil
local EventOverlayInputHandler = nil
local OnlineEvaluationInputHandler = nil

local function OnlineEvaluationActive()
	return ITGOnline and ITGOnline.currentRoomId ~= nil
end

local function SetOnlineEvaluationInputRedirected(enabled, reason)
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

		local waiting = ITGOnline.ShouldWaitForOnlineResults and ITGOnline:ShouldWaitForOnlineResults()
		if online_trace then
			local summary = ITGOnline.PlayStateSummary and ITGOnline:PlayStateSummary() or nil
			online_trace("FLOW evaluation_input button=" .. tostring(event.GameButton)
				.. " type=" .. tostring(event.type)
				.. " reason=" .. tostring(reason or "unknown")
				.. " waiting=" .. tostring(waiting == true)
				.. " terminal=" .. tostring(summary and summary.terminal or "nil")
				.. " players=" .. tostring(summary and summary.players or "nil"))
		end

		if waiting then
			if event.type == "InputEventType_FirstPress" then
				SM("Waiting for every online player to finish...")
			end
			return true
		end

		if event.type == "InputEventType_FirstPress" then
			ReturnToOnlineLobby("evaluation_common_input")
		end
		return true
	end
end

local function DisableOnlineEvaluationTimer(reason)
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
			screen:AddInputCallback(InputHandler)
			OnlineEvaluationInputHandler = BuildOnlineEvaluationInputHandler("standard")
			screen:AddInputCallback(OnlineEvaluationInputHandler)
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

-- the title of the song and its graphical banner, if there is one
t[#t+1] = LoadActor("./Shared/TitleAndBanner.lua")

-- text to display BPM range (and ratemod if ~= 1.0) and song length immediately
-- under the banner
t[#t+1] = LoadActor("./Shared/SongFeatures.lua")

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

	-- the per-player upper half of ScreenEvaluation, including: letter grade, nice
	-- stepartist, difficulty text, difficulty meter, machine/personal HighScore text
	t[#t+1] = LoadActor("./PerPlayer/Upper/default.lua", player)

	-- the per-player lower half of ScreenEvaluation, including:
	-- judgment scatterplot, modifier list, disqualified text
	t[#t+1] = LoadActor("./PerPlayer/Lower/default.lua", player)

	-- Generate the .itl file for the player.
	-- When the event isn't active, this actor is nil.
	t[#t+1] = LoadActor("./PerPlayer/ItlFile.lua", player)
end

-- -----------------------------------------------------------------------
-- Then load the Panes.

t[#t+1] = LoadActor("./Panes/default.lua", NumPanes)

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

	t[#t+1] = Def.ActorFrame{
	Name="ITGOnlineResultsWait",
	InitCommand=function(self)
		self:Center():visible(false)
	end,
	OnCommand=function(self)
		self:queuecommand("Refresh")
	end,
	OffCommand=function(self)
		SetOnlineEvaluationInputRedirected(false, "results_wait_off")
	end,
	RefreshCommand=function(self)
		local waiting = ITGOnline and ITGOnline.ShouldWaitForOnlineResults and ITGOnline:ShouldWaitForOnlineResults()
		self:visible(waiting == true)
		DisableOnlineEvaluationTimer("results_wait_refresh")

		local screen = SCREENMAN:GetTopScreen()
		if screen then
			local timer = screen:GetChild("Timer")
			if timer then timer:visible(false) end
		end

		SetOnlineEvaluationInputRedirected(waiting == true, "results_wait_refresh")
		local progress = self:GetChild("Progress")
		if progress then progress:playcommand("Refresh") end
		local sessions = self:GetChild("Sessions")
		if sessions then sessions:playcommand("Refresh") end
		local title = self:GetChild("Title")
		if title then title:playcommand("Refresh") end

		if waiting and ITGOnline and ITGOnline.FetchRoom and ITGOnline.currentRoomId then
			ITGOnline:FetchRoom(ITGOnline.currentRoomId, function(ok)
				if ok and ITGOnline and ITGOnline.currentRoom and ITGOnline.LobbyStatePayload then
					MESSAGEMAN:Broadcast("OnlineLobbyState", ITGOnline:LobbyStatePayload(ITGOnline.currentRoom))
					MESSAGEMAN:Broadcast("ITGOnlinePlayStateUpdated", ITGOnline.currentRoom.play_state or {})
				end
			end)
		end

		self:sleep(waiting and 0.75 or 0.25):queuecommand("Refresh")
	end,

	Def.Quad{
		InitCommand=function(self)
			self:zoomto(_screen.w, _screen.h):diffuse(color("#000000")):diffusealpha(0.74)
		end,
	},
	LoadFont("Common Normal")..{
		Name="Title",
		Text="Waiting for every player to finish",
		InitCommand=function(self)
			self:y(-76):zoom(0.72):diffuse(color("#66ff99")):shadowlength(1)
		end,
		RefreshCommand=function(self)
			self:settext("Waiting for every player to finish")
		end,
	},
	LoadFont("Common Normal")..{
		Name="Progress",
		Text="",
		InitCommand=function(self)
			self:y(-46):zoom(0.54):diffuse(Color.White):shadowlength(1)
		end,
		RefreshCommand=function(self)
			local summary = ITGOnline and ITGOnline.PlayStateSummary and ITGOnline:PlayStateSummary() or nil
			if not summary then
				self:settext("")
				return
			end
			if summary.allTerminal then
				self:settext("All players finished")
			else
				self:settext(string.format("%d/%d players finished", summary.terminal or 0, summary.players or 0))
			end
		end,
	},
	LoadFont("Common Normal")..{
		Name="Sessions",
		Text="",
		InitCommand=function(self)
			self:y(8):zoom(0.48):diffuse(Color.White):shadowlength(1):wrapwidthpixels(_screen.w * 1.45):vertspacing(5)
		end,
		RefreshCommand=function(self)
			local summary = ITGOnline and ITGOnline.PlayStateSummary and ITGOnline:PlayStateSummary() or nil
			if not summary then
				self:settext("")
				return
			end

			local lines = {}
			for session in ivalues(summary.sessions or {}) do
				local user = session.user or {}
				local name = tostring(user.name or session.name or "Player")
				local state = tostring(session.state or "pending")
				local prefix = "…"
				if state == "finished" then
					prefix = "✓"
				elseif state == "failed" or state == "returned_to_lobby" or state == "disconnected" then
					prefix = "✖"
				end
				lines[#lines + 1] = prefix .. " " .. name .. " - " .. state
			end
			self:settext(table.concat(lines, "\n"))
		end,
	},
	}
end

return t
