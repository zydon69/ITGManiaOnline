local args = ...
local GroupWheel = args.GroupWheel
local SongWheel = args.SongWheel
local OptionsWheel = args.OptionsWheel
local OptionRows = args.OptionRows

local ActiveOptionRow
local Players = {}

local t = {}

local function SafeGetChild(actor, name)
	if not (actor and name) then return nil end
	local ok, child = pcall(function() return actor:GetChild(name) end)
	return ok and child or nil
end

local function GetTopScreen()
	return SCREENMAN and SCREENMAN.GetTopScreen and SCREENMAN:GetTopScreen() or nil
end

local function Broadcast(name, params)
	if MESSAGEMAN and MESSAGEMAN.Broadcast then
		MESSAGEMAN:Broadcast(name, params)
	end
end

local function GetHumanPlayers()
	if not (GAMESTATE and GAMESTATE.GetHumanPlayers) then return {} end
	return GAMESTATE:GetHumanPlayers() or {}
end

local function RefreshPlayers()
	Players = GetHumanPlayers()
	return Players
end

local function PlayerIsJoined(pn)
	return GAMESTATE and GAMESTATE.IsSideJoined and GAMESTATE:IsSideJoined(pn)
end

local function Queue(actor, command)
	if actor and command then actor:queuecommand(command) end
end

local function Play(actor, command, params)
	if actor and command then actor:playcommand(command, params) end
end

local function PressActorPath(actor, ...)
	for _, name in ipairs({...}) do
		actor = SafeGetChild(actor, name)
		if not actor then return false end
	end
	actor:finishtweening():playcommand("Press")
	return true
end

local function PressSongArrow(direction)
	local arrow = direction == "right" and "RightArrow" or "LeftArrow"
	return PressActorPath(GetTopScreen(), "Overlay", "SongWheelShared", "Arrows", arrow)
end

local function PlayerOptionWheel(pn)
	return t.WheelWithFocus == OptionsWheel and OptionsWheel[pn] or nil
end

local function PlayerOptionItemWheel(pn, index)
	local wheel = PlayerOptionWheel(pn)
	return wheel and wheel[index] or nil
end

local function PressOptionArrow(pn, index, direction)
	local wheel = PlayerOptionWheel(pn)
	local arrow = direction == "right" and "RightArrow" or "LeftArrow"
	return wheel and PressActorPath(wheel.container, "item"..index, "Cursor", arrow)
end

local function SwitchInputFocus(button)
	if button == "Start" then
		if t.WheelWithFocus == GroupWheel then
			t.WheelWithFocus = SongWheel
		elseif t.WheelWithFocus == SongWheel then
			t.WheelWithFocus = OptionsWheel
		end
	elseif button == "Select" or button == "Back" then
		if t.WheelWithFocus == SongWheel then
			t.WheelWithFocus = GroupWheel
		elseif t.WheelWithFocus == OptionsWheel then
			t.WheelWithFocus = SongWheel
		end
	end
end

function t.AllPlayersAreAtLastRow()
	if #Players == 0 then return false end
	for player in ivalues(Players) do
		if ActiveOptionRow[player] ~= #OptionRows then
			return false
		end
	end
	return true
end

local function CloseCurrentFolder()
	if t.WheelWithFocus == GroupWheel then return end

	t.Enabled = false
	Queue(t.WheelWithFocus and t.WheelWithFocus.container, "Hide")
	t.WheelWithFocus = GroupWheel
	Queue(t.WheelWithFocus.container, "Unhide")
	Broadcast("PlaySFX", {Action="ChangeGroup"})
end

local function UnhideOptionRows(pn)
	local wheel = PlayerOptionWheel(pn)
	if not (wheel and wheel.container) then return false end

	Queue(wheel.container, "Unhide")
	for i=1,#OptionRows do
		Queue(wheel[i] and wheel[i].container, "Unhide")
	end
	return true
end

function t.AllowLateJoin()
	if not (GAMESTATE and PREFSMAN and GAMESTATE.GetCurrentStyle) then return false end
	local style = GAMESTATE:GetCurrentStyle()
	if not (style and style.GetName and style:GetName() == "single") then return false end
	if PREFSMAN:GetPreference("EventMode") then return true end
	if GAMESTATE:GetCoinMode() ~= "CoinMode_Pay" then return true end
	if GAMESTATE:GetCoinMode() == "CoinMode_Pay" and PREFSMAN:GetPreference("Premium") == "Premium_2PlayersFor1Credit" then return true end
	return false
end

local function SaveOptionRow(player, index)
	local row = OptionRows[index]
	local wheel = PlayerOptionItemWheel(player, index)
	if not (row and row.OnSave and wheel and wheel.get_info_at_focus_pos) then return true end

	local choice = wheel:get_info_at_focus_pos()
	local choices = row.Choices and row:Choices() or {}
	local values = row.Values and row.Values() or {}
	if choice == nil or #choices == 0 or #values == 0 then return false end

	local ok = row:OnSave(player, choice, choices, values)
	return ok ~= false
end

function t.SaveOptionsForPlayer(player, max_index)
	if not (OptionsWheel[player] and PlayerIsJoined(player)) then return false end
	max_index = math.min(tonumber(max_index) or (#OptionRows - 1), #OptionRows - 1)

	for index=1, max_index do
		if not SaveOptionRow(player, index) then return false end
	end

	return true
end

function t.Init()
	t.Enabled = false
	t.WheelWithFocus = GAMESTATE and GAMESTATE.GetCurrentSong and GAMESTATE:GetCurrentSong() and SongWheel or GroupWheel
	ActiveOptionRow = {
		[PLAYER_1] = 1,
		[PLAYER_2] = 1
	}
	RefreshPlayers()

	t.CancelSongChoice = function()
		t.Enabled = false
		for pn in ivalues(Players) do
			ActiveOptionRow[pn] = 1
			local wheel = PlayerOptionWheel(pn)
			if wheel then
				Play(wheel.container, "Hide")
				for i=1,#OptionRows do
					Queue(wheel[i] and wheel[i].container, "Hide")
				end
				if wheel.scroll_to_pos then wheel:scroll_to_pos(1) end
			end
		end
		Broadcast("SingleSongCanceled")
		t.WheelWithFocus = SongWheel
		Queue(t.WheelWithFocus.container, "Unhide")
	end
end

function t.Handler(event)
	if t.Enabled == false or not event or not event.PlayerNumber or not event.button then
		return false
	end

	if event.type ~= "InputEventType_FirstPress" then
		return false
	end

	if not PlayerIsJoined(event.PlayerNumber) then
		if not t.AllowLateJoin() then return false end

		if t.WheelWithFocus == OptionsWheel and event.GameButton == "Start" then
			GAMESTATE:JoinPlayer(event.PlayerNumber)
			if PlayerIsJoined(event.PlayerNumber) then
				RefreshPlayers()
				ActiveOptionRow[event.PlayerNumber] = ActiveOptionRow[event.PlayerNumber] or 1
				UnhideOptionRows(event.PlayerNumber)
				Broadcast("PlaySFX", {Action="Start"})
			end
		end
		return false
	end

	if event.GameButton == "Back" then
		t.Enabled = false
		local topscreen = GetTopScreen()
		if topscreen then
			topscreen:SetNextScreenName(Branch.SSMCancel()):StartTransitioningScreen("SM_GoToNextScreen")
		end
		return false
	end

	if t.WheelWithFocus ~= OptionsWheel then
		if event.GameButton == "MenuRight" or event.GameButton == "MenuDown" then
			if t.WheelWithFocus and t.WheelWithFocus.scroll_by_amount then
				t.WheelWithFocus:scroll_by_amount(1)
			end
			if t.WheelWithFocus == SongWheel then PressSongArrow("right") end

		elseif event.GameButton == "MenuLeft" or event.GameButton == "MenuUp" then
			if t.WheelWithFocus and t.WheelWithFocus.scroll_by_amount then
				t.WheelWithFocus:scroll_by_amount(-1)
			end
			if t.WheelWithFocus == SongWheel then PressSongArrow("left") end

		elseif event.GameButton == "Start" then
			if t.WheelWithFocus and t.WheelWithFocus.get_info_at_focus_pos and t.WheelWithFocus:get_info_at_focus_pos() == "CloseThisFolder" then
				CloseCurrentFolder()
				return false
			end

			t.Enabled = false
			Queue(t.WheelWithFocus and t.WheelWithFocus.container, "Start")
			SwitchInputFocus(event.GameButton)

			if t.WheelWithFocus and t.WheelWithFocus.container then
				Queue(t.WheelWithFocus.container, "Unhide")
			else
				for pn in ivalues(Players) do
					UnhideOptionRows(pn)
				end
			end

		elseif event.GameButton == "Select" then
			CloseCurrentFolder()
		end

		if event.GameButton == "MenuRight" or event.GameButton == "MenuDown" or event.GameButton == "MenuLeft" or event.GameButton == "MenuUp" then
			Broadcast("PlaySFX", {Action=(t.WheelWithFocus == GroupWheel and "ChangeGroup" or "ChangeSong"), Player=event.PlayerNumber})
		elseif event.GameButton == "Start" then
			Broadcast("PlaySFX", {Action="Start"})
		end

		return false
	end

	local player = event.PlayerNumber
	local index = ActiveOptionRow[player] or 1
	local player_wheel = PlayerOptionWheel(player)
	local item_wheel = PlayerOptionItemWheel(player, index)
	if not player_wheel then return false end

	if event.GameButton == "MenuRight" then
		if item_wheel and item_wheel.scroll_by_amount then item_wheel:scroll_by_amount(1) end
		PressOptionArrow(player, index, "right")
		Broadcast("PlaySFX", {Action="ChangeSong", Player=player})

	elseif event.GameButton == "MenuLeft" then
		if item_wheel and item_wheel.scroll_by_amount then item_wheel:scroll_by_amount(-1) end
		PressOptionArrow(player, index, "left")
		Broadcast("PlaySFX", {Action="ChangeSong", Player=player})

	elseif event.GameButton == "MenuUp" then
		if index > 1 then
			ActiveOptionRow[player] = math.max(index-1, 1)
			if player_wheel.scroll_by_amount then player_wheel:scroll_by_amount(-1) end
			Broadcast("CancelBothPlayersAreReady")
			Broadcast("PlaySFX", {Action="ChangeSong", Player=player})
		end

	elseif event.GameButton == "Start" or event.GameButton == "MenuDown" then
		if event.GameButton == "Start" and t.AllPlayersAreAtLastRow() then
			Broadcast("PlaySFX", {Action="Start", Player=player})
			local topscreen = GetTopScreen()
			if topscreen then topscreen:StartTransitioningScreen("SM_GoToNextScreen") end
			return false
		end

		if index < #OptionRows then
			if not SaveOptionRow(player, index) then return false end
			if player_wheel.scroll_by_amount then player_wheel:scroll_by_amount(1) end
		end

		index = math.min(index+1, #OptionRows)
		ActiveOptionRow[player] = index

		if index == #OptionRows then
			local cursor = SafeGetChild(SafeGetChild(player_wheel.container, "item"..index), "Cursor")
			Play(cursor, "ExitRow", {PlayerNumber=player})
		end

		Broadcast("PlaySFX", {Action="ChangeSong", Player=player})
		if t.AllPlayersAreAtLastRow() then
			Broadcast("BothPlayersAreReady")
		end

	elseif event.GameButton == "Select" then
		t.CancelSongChoice()
	end

	return false
end

return t
