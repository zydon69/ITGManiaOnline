local Players = GAMESTATE:GetHumanPlayers()
local NumPanes = SL.Global.GameMode=="Casual" and 1 or 8

local InputHandler = nil
local EventOverlayInputHandler = nil
local OnlineResultsWaitInputHandler = nil

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
		SCREENMAN:GetTopScreen():AddInputCallback(InputHandler)
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
		PROFILEMAN:SaveMachineProfile()
	end
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
		OnlineResultsWaitInputHandler = function(event)
			local holding = ITGOnline and ITGOnline.ShouldHoldOnlineEvaluation and ITGOnline:ShouldHoldOnlineEvaluation()
			if not holding then
				return false
			end

			if event and event.type == "InputEventType_FirstPress" then
				local waiting = ITGOnline and ITGOnline.ShouldWaitForOnlineResults and ITGOnline:ShouldWaitForOnlineResults()
				SM(waiting and "Waiting for every online player to finish..." or "Final score confirmed.")
			end
			return true
		end

		local screen = SCREENMAN:GetTopScreen()
		if screen then screen:AddInputCallback(OnlineResultsWaitInputHandler) end
		self:queuecommand("Refresh")
	end,
	OffCommand=function(self)
		local screen = SCREENMAN:GetTopScreen()
		if screen and OnlineResultsWaitInputHandler then
			screen:RemoveInputCallback(OnlineResultsWaitInputHandler)
		end
		for player in ivalues(PlayerNumber) do
			SCREENMAN:set_input_redirected(player, false)
		end
	end,
	RefreshCommand=function(self)
		local waiting = ITGOnline and ITGOnline.ShouldWaitForOnlineResults and ITGOnline:ShouldWaitForOnlineResults()
		local holding = ITGOnline and ITGOnline.ShouldHoldOnlineEvaluation and ITGOnline:ShouldHoldOnlineEvaluation()
		local visible = ITGOnline and ITGOnline.ShouldShowOnlineEvaluationStatus and ITGOnline:ShouldShowOnlineEvaluationStatus()
		self:visible(visible)

		local screen = SCREENMAN:GetTopScreen()
		if screen then
			local timer = screen:GetChild("Timer")
			if timer and visible then timer:visible(false) end
		end

		for player in ivalues(PlayerNumber) do
			SCREENMAN:set_input_redirected(player, holding == true)
		end
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
		elseif visible and ITGOnline and ITGOnline.currentRoomId and ITGOnline.FetchRoom then
			ITGOnline:FetchRoom(ITGOnline.currentRoomId, function(ok)
				if ok and ITGOnline and ITGOnline.currentRoom and ITGOnline.LobbyStatePayload then
					MESSAGEMAN:Broadcast("OnlineLobbyState", ITGOnline:LobbyStatePayload(ITGOnline.currentRoom))
					MESSAGEMAN:Broadcast("ITGOnlinePlayStateUpdated", ITGOnline.currentRoom.play_state or {})
				end
			end)
		else
			for player in ivalues(PlayerNumber) do
				SCREENMAN:set_input_redirected(player, false)
			end
		end

		self:sleep(visible and 0.75 or 0.25):queuecommand("Refresh")
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
			local waiting = ITGOnline and ITGOnline.ShouldWaitForOnlineResults and ITGOnline:ShouldWaitForOnlineResults()
			self:settext(waiting and "Waiting for every player to finish" or "Final scores confirmed - press Start or Esc")
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

return t
