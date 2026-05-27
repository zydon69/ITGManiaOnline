-- if the MenuTimer is enabled, we should reset SSM's MenuTimer now that we've reached Gameplay
if PREFSMAN:GetPreference("MenuTimer") then
	SL.Global.MenuTimer.ScreenSelectMusic = ThemePrefs.Get("ScreenSelectMusicMenuTimer")
end

local Players = GAMESTATE:GetHumanPlayers()
local holdingCtrl = false

local function online_gameplay_phase()
	if not ITGOnline or not ITGOnline.currentRoom then return "" end
	if not ITGOnline.NormalizeRoomPhase then return tostring(ITGOnline.currentRoom.phase or "") end
	return ITGOnline:NormalizeRoomPhase(ITGOnline.currentRoom.phase)
end

local function online_gameplay_routes_back_to_lobby()
	local phase = online_gameplay_phase()
	return ITGOnline
		and ITGOnline.currentRoomId
		and (phase == "starting" or phase == "playing" or phase == "results")
end

local RestartHandler = function(event)
	if not event then return end

	if event.type == "InputEventType_FirstPress" then
		if event.GameButton == "Back" and online_gameplay_routes_back_to_lobby() then
			SCREENMAN:GetTopScreen():SetNextScreenName("ScreenOnlineLobbies")
		end

		if event.DeviceInput.button == "DeviceButton_left ctrl" then
			holdingCtrl = true
		elseif event.DeviceInput.button == "DeviceButton_r" then
			if holdingCtrl then
				SCREENMAN:GetTopScreen():SetPrevScreenName("ScreenGameplay"):SetNextScreenName("ScreenGameplay"):begin_backing_out()
			end
		end
	elseif event.type == "InputEventType_Release" then
		if event.DeviceInput.button == "DeviceButton_left ctrl" then
			holdingCtrl = false
		end
	end
end

local t = Def.ActorFrame{
	Name="GameplayUnderlay",
	OnCommand=function(self)
		if ITGOnline and ITGOnline.currentRoomId then
			SCREENMAN:GetTopScreen():AddInputCallback(RestartHandler)
			return
		end

		if ThemePrefs.Get("KeyboardFeatures") and PREFSMAN:GetPreference("EventMode") and not GAMESTATE:IsCourseMode() then
			SCREENMAN:GetTopScreen():AddInputCallback(RestartHandler)
		end
	end
}

for player in ivalues(Players) do
	t[#t+1] = LoadActor("./PerPlayer/Danger.lua", player)
	t[#t+1] = LoadActor("./PerPlayer/StepStatistics/default.lua", player)
	t[#t+1] = LoadActor("./PerPlayer/BackgroundFilter.lua", player)
	t[#t+1] = LoadActor("./PerPlayer/nice.lua", player)
end

-- UI elements shared by both players
t[#t+1] = LoadActor("./Shared/VersusStepStatistics.lua")
t[#t+1] = LoadActor("./Shared/Header.lua")
t[#t+1] = LoadActor("./Shared/SongInfoBar.lua") -- song title and progress bar

-- per-player UI elements
for player in ivalues(Players) do
	-- Tournament Mode modifications. Put this before everything as it sets
	-- player mods and other actors below might depend on it.
	t[#t+1] = LoadActor("./PerPlayer/TournamentMode.lua", player)

	t[#t+1] = LoadActor("./PerPlayer/UpperNPSGraph.lua", player)
	t[#t+1] = LoadActor("./PerPlayer/Score.lua", player)
	t[#t+1] = LoadActor("./PerPlayer/DifficultyMeter.lua", player)
	t[#t+1] = LoadActor("./PerPlayer/LifeMeter/default.lua", player)
	t[#t+1] = LoadActor("./PerPlayer/TargetScore/default.lua", player)

	-- All NoteField specific actors are contained in this file.
	t[#t+1] = LoadActor("./PerPlayer/NoteField/default.lua", player)

end

-- add to the ActorFrame last; overlapped by StepStatistics otherwise
t[#t+1] = LoadActor("./Shared/BPMDisplay.lua")

t[#t+1] = Def.ActorFrame{
	Name="OnlineStartCountdown",
	InitCommand=function(self)
		self:xy(_screen.cx, _screen.cy - 120):visible(false)
	end,
	OnCommand=function(self)
		self:queuecommand("RefreshCountdown")
	end,
	RefreshCountdownCommand=function(self)
		if not (ITGOnline and ITGOnline.SecondsUntilScheduledStart) then
			self:visible(false)
			self:sleep(0.1):queuecommand("RefreshCountdown")
			return
		end

		local seconds = ITGOnline:SecondsUntilScheduledStart()
		if not seconds or seconds <= 0 then
			self:visible(false)
			self:sleep(0.1):queuecommand("RefreshCountdown")
			return
		end

		self:visible(true)
		self:GetChild("CountdownText"):settext("START IN " .. tostring(math.ceil(seconds)))
		self:sleep(0.1):queuecommand("RefreshCountdown")
	end,

	Def.Quad{
		InitCommand=function(self)
			self:zoomto(260, 62):diffuse(0,0,0,0.72)
		end
	},
	LoadFont("Common Bold")..{
		Name="CountdownText",
		Text="",
		InitCommand=function(self)
			self:zoom(0.82):diffuse(Color.Yellow)
		end
	}
}

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
		local text = connected and "ITG Online: connected" or "ITG Online: reconnecting"
		self:settext(text)
		self:diffuse(connected and color("#66ff99") or Color.Yellow)
		self:sleep(0.5):queuecommand("RefreshOnlineStatus")
	end
}

return t
