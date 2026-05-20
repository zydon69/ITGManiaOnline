local active_index = 0
local list_selected = false
local options = { "Available Lobbies", "Online Players", "Refresh List", "Create Lobby", "Go Back" }
local t = nil
local connected = false
local has_error = false
local input_added = false

local holding = {
	["MenuRight"]=false,
	["MenuLeft"]=false,
}

local candidates = {}
local online_users = {}
local lobby_view = "lobbies"
local online_player_index = 1
local showing_player_action_menu = false
local player_action_index = 1
local player_action_options = {}
local player_action_user = nil
local showing_private_join_prompt = false
local private_join_prompt_index = 1
local private_join_request = nil
local private_join_options = {
	{label="Accept", accept=true, reason=""},
	{label="Decline", accept=false, reason=""},
	{label="Busy", accept=false, reason="Busy right now."},
	{label="Maybe Later", accept=false, reason="Maybe later."},
}
local pending_join_action_id = 0
local pending_join_deadline = 0

local mode = "browse"
local joined_active_index = 1
local joined_is_manager = false
local joined_lobby_code = ""
local joined_lobby_players = {}
local joined_song_preview = nil
local joined_song_confirmed = false
local joined_missing_song = false
local joined_missing_song_info = nil
local leaving_lobby = false
local showing_leave_confirm = false
local leave_confirm_index = 0

local create_lobby_password = ""
local join_lobby_password = ""
local join_lobby_code = ""
local password_prompt_mode = "create"
local show_password_in_lobby = false
local showing_password_prompt = false
local password_char_limit = 4
local password_chars = {
	"❌", "✔",
	"A", "B", "C", "D", "E", "F", "G", "H", "I", "J", "K", "L", "M",
	"N", "O", "P", "Q", "R", "S", "T", "U", "V", "W", "X", "Y", "Z",
}
local password_wheel = setmetatable({}, sick_wheel_mt)
local password_character_mt = {
	__index = {
		create_actors = function(self, name)
			self.name=name
			local af = Def.ActorFrame{
				Name=name,
				InitCommand=function(subself)
					self.container = subself
					subself:diffusealpha(0)
				end,
				OnCommand=function(self) self:linear(0.2):diffusealpha(1) end,
				Def.BitmapText{
					Font="Wendy/_wendy white",
					InitCommand=function(subself)
						self.bmt = subself
						subself:zoom(0.8):diffuse(0.75,0.75,0.75,1)
					end,
				}
			}
			return af
		end,
		transform = function(self, item_index, num_items, has_focus)
			self.container:finishtweening()
			if item_index <= 0 or item_index >= num_items-1 then
				self.container:diffusealpha(0)
			else
				self.container:diffusealpha(1)
			end
			self.bmt:diffuse(has_focus and 1 or 0.3, has_focus and 1 or 0.3, has_focus and 1 or 0.3, 1)
			self.container:linear(0.075)
			self.container:x(52 * (item_index - math.ceil(num_items/2)))
		end,
		set = function(self, character)
			if character then
				self.bmt:settext(character)
			end
		end
	}
}

SL.Global.Online = SL.Global.Online or {}

-- Just for testing
local sample_lobby = {
	code = "ABCD",
	playerCount = 1,
	isPasswordProtected = true,
}

local function GetPromptPassword()
	if password_prompt_mode == "join" then
		return join_lobby_password
	end
	return create_lobby_password
end

local function SetPromptPassword(value)
	if password_prompt_mode == "join" then
		join_lobby_password = value
	else
		create_lobby_password = value
	end
end

local function joined_button_indices()
	local indices = {1}
	if joined_is_manager then
		indices[#indices + 1] = 2
	end
	if joined_missing_song then
		indices[#indices + 1] = 3
	end
	return indices
end

local function normalize_joined_active_index()
	local indices = joined_button_indices()
	for index in ivalues(indices) do
		if joined_active_index == index then
			return
		end
	end
	joined_active_index = indices[1] or 1
end

local function move_joined_button(delta)
	local indices = joined_button_indices()
	local current = 1
	for i, index in ipairs(indices) do
		if joined_active_index == index then
			current = i
			break
		end
	end

	local nextIndex = current + delta
	if nextIndex < 1 then nextIndex = #indices end
	if nextIndex > #indices then nextIndex = 1 end
	joined_active_index = indices[nextIndex] or 1
end

local function transition_to_online_song_reload()
	SL.Global.Online = SL.Global.Online or {}
	SL.Global.Online.ReturnToLobbyAfterSongReload = true

	local topScreen = SCREENMAN:GetTopScreen()
	if topScreen then
		topScreen:SetNextScreenName("ScreenReloadSongsOnline")
		topScreen:StartTransitioningScreen("SM_GoToNextScreen")
	end
end

local function room_visibility_label(room)
	if not room then return "" end
	if room.visibility == "private" then return "[PRV]" end
	if room.visibility == "public" then return "[PUB]" end
	return "[ROOM]"
end

local function selected_online_user()
	if #online_users == 0 then return nil end
	online_player_index = math.max(1, math.min(online_player_index, #online_users))
	return online_users[online_player_index]
end

local function build_player_action_options(user)
	if not user then return {} end
	if user.isSelf then
		return {{label="This Is You", action="cancel"}, {label="Cancel", action="cancel"}}
	end
	if user.room and user.room.visibility == "public" then
		return {{label="Join Public Lobby", action="join_user_room"}, {label="Cancel", action="cancel"}}
	end
	if user.room and user.room.visibility == "private" then
		return {{label="Ask To Join Private Lobby", action="join_user_room"}, {label="Cancel", action="cancel"}}
	end
	return {
		{label="Invite To Private Lobby", action="invite_private"},
		{label="Invite To Public Lobby", action="invite_public"},
		{label="Cancel", action="cancel"},
	}
end

local function clear_pending_join()
	pending_join_action_id = 0
	pending_join_deadline = 0
end

local function begin_join_timeout(actor)
	pending_join_action_id = pending_join_action_id + 1
	pending_join_deadline = GetTimeSinceStart() + 12
	local timer = actor and actor:GetChild("JoinTimeoutTimer")
	if timer then
		timer:stoptweening()
		timer:sleep(12):queuecommand("CheckJoinTimeout")
	end
end

local function cancel_pending_join(message)
	clear_pending_join()
	mode = "browse"
	showing_password_prompt = false
	showing_player_action_menu = false

	if t then
		t:GetChild("PasswordPrompt"):visible(false)
		t:GetChild("PlayerActionMenu"):visible(false)
		t:GetChild("JoinedLobbyContent"):visible(false)
		t:queuecommand("UpdateLobbyView")
		t:playcommand("SetStatus", {
			text=message or "Lobby join timed out. Refreshing lobbies...",
			showSpinner=false,
			showPrompt=false
		})
		MESSAGEMAN:Broadcast("SearchLobby")
		t:queuecommand("Hover")
	end
end

local function execute_player_action(option, user)
	if not option or not user then return end
	showing_player_action_menu = false
	t:GetChild("PlayerActionMenu"):visible(false)

	if option.action == "invite_private" then
		t:GetChild("LobbyContent"):visible(false)
		t:GetChild("OnlinePlayersContent"):visible(false)
		t:playcommand("SetStatus", {text="Creating private lobby and sending invite...", showSpinner=true, showPrompt=false})
		MESSAGEMAN:Broadcast("InviteOnlinePlayer", {user_id=user.id, visibility="private"})
	elseif option.action == "invite_public" then
		t:GetChild("LobbyContent"):visible(false)
		t:GetChild("OnlinePlayersContent"):visible(false)
		t:playcommand("SetStatus", {text="Creating public lobby and sending invite...", showSpinner=true, showPrompt=false})
		MESSAGEMAN:Broadcast("InviteOnlinePlayer", {user_id=user.id, visibility="public"})
	elseif option.action == "join_user_room" then
		t:GetChild("LobbyContent"):visible(false)
		t:GetChild("OnlinePlayersContent"):visible(false)
		t:playcommand("SetStatus", {text="Contacting player lobby...", showSpinner=true, showPrompt=false})
		begin_join_timeout(t)
		MESSAGEMAN:Broadcast("JoinOnlinePlayerRoom", {user_id=user.id})
	end
end

local InputHandler = function(event)
  if not event.PlayerNumber or not event.button then return false end

  if event.type == "InputEventType_FirstPress" then
		if showing_leave_confirm then
			if event.GameButton == "MenuRight" or event.GameButton == "MenuLeft" then
				leave_confirm_index = (leave_confirm_index + (event.GameButton=="MenuRight" and 1 or -1)) % 2
				SOUND:PlayOnce(THEME:GetPathS("ScreenSelectMaster", "change"))
				t:GetChild("LeaveConfirmPrompt"):playcommand("Hover")
			elseif event.GameButton == "Start" then
				if leave_confirm_index == 1 then
					SOUND:PlayOnce(THEME:GetPathS("Common", "Start"))
					showing_leave_confirm = false
					t:GetChild("LeaveConfirmPrompt"):visible(false)
					leaving_lobby = true
					MESSAGEMAN:Broadcast("LeaveLobby")
				else
					SOUND:PlayOnce(THEME:GetPathS("Common", "Cancel"))
					showing_leave_confirm = false
					t:GetChild("LeaveConfirmPrompt"):visible(false)
				end
			elseif event.GameButton == "Select" or event.GameButton == "Back" then
				SOUND:PlayOnce(THEME:GetPathS("Common", "Cancel"))
				showing_leave_confirm = false
				t:GetChild("LeaveConfirmPrompt"):visible(false)
			end
			return false
		end

		if showing_private_join_prompt then
			if event.GameButton == "MenuRight" or event.GameButton == "MenuLeft" then
				private_join_prompt_index = ((private_join_prompt_index - 1 + (event.GameButton=="MenuRight" and 1 or -1)) % #private_join_options) + 1
				SOUND:PlayOnce(THEME:GetPathS("ScreenSelectMaster", "change"))
				t:queuecommand("UpdatePrivateJoinPrompt")
			elseif event.GameButton == "Start" then
				local option = private_join_options[private_join_prompt_index]
				local request = private_join_request and private_join_request.join_request
				if option and request and request.id then
					showing_private_join_prompt = false
					t:GetChild("PrivateJoinPrompt"):visible(false)
					MESSAGEMAN:Broadcast("AnswerPrivateJoinRequest", {
						join_request_id=request.id,
						accept=option.accept,
						reason=option.reason,
					})
					SOUND:PlayOnce(THEME:GetPathS("Common", "Start"))
				end
			elseif event.GameButton == "Select" or event.GameButton == "Back" then
				showing_private_join_prompt = false
				t:GetChild("PrivateJoinPrompt"):visible(false)
				SOUND:PlayOnce(THEME:GetPathS("Common", "Cancel"))
			end
			return false
		end

		if showing_player_action_menu then
			if event.GameButton == "MenuRight" or event.GameButton == "MenuLeft" then
				player_action_index = ((player_action_index - 1 + (event.GameButton=="MenuRight" and 1 or -1)) % #player_action_options) + 1
				SOUND:PlayOnce(THEME:GetPathS("ScreenSelectMaster", "change"))
				t:queuecommand("UpdatePlayerActionMenu")
			elseif event.GameButton == "Start" then
				SOUND:PlayOnce(THEME:GetPathS("Common", "Start"))
				execute_player_action(player_action_options[player_action_index], player_action_user)
			elseif event.GameButton == "Select" or event.GameButton == "Back" then
				showing_player_action_menu = false
				t:GetChild("PlayerActionMenu"):visible(false)
				SOUND:PlayOnce(THEME:GetPathS("Common", "Cancel"))
			end
			return false
		end

		if showing_password_prompt then
			if event.GameButton == "MenuRight" then
				password_wheel:scroll_by_amount(1)
				SOUND:PlayOnce(THEME:GetPathS("ScreenSelectMaster", "change"))
			elseif event.GameButton == "MenuLeft" then
				password_wheel:scroll_by_amount(-1)
				SOUND:PlayOnce(THEME:GetPathS("ScreenSelectMaster", "change"))
			elseif event.GameButton == "Start" then
				local selected_char = password_wheel:get_info_at_focus_pos()
				if selected_char == "✔" then
					if password_prompt_mode == "join" and join_lobby_code == "" then
						SOUND:PlayOnce(THEME:GetPathS("Common", "Cancel"))
						return false
					end
					showing_password_prompt = false
					t:GetChild("PasswordPrompt"):visible(false)
					t:GetChild("LobbyContent"):visible(false)
					t:GetChild("OnlinePlayersContent"):visible(false)
						if password_prompt_mode == "join" then
							t:playcommand("SetStatus", {
								text="Joining lobby...",
								showSpinner=true,
								showPrompt=false
							})
							begin_join_timeout(t)
							MESSAGEMAN:Broadcast("JoinLobby", {
								code=join_lobby_code,
								password=join_lobby_password
							})
						-- Clear out passwords after attempting to join a lobby for security
						join_lobby_password = ""
					else
						t:playcommand("SetStatus", {
							text="Creating lobby...",
							showSpinner=true,
							showPrompt=false
						})
						MESSAGEMAN:Broadcast("CreateLobby", {password=create_lobby_password})
					end
					SOUND:PlayOnce(THEME:GetPathS("Common", "Start"))
				elseif selected_char == "❌" then
					local password = GetPromptPassword()
					if password:len() > 0 then
						SetPromptPassword(password:sub(1, -2))
						SOUND:PlayOnce(THEME:GetPathS("Common", "Cancel"))
					end
					t:queuecommand("UpdatePasswordText")
				else
					local password = GetPromptPassword()
					if password:len() < password_char_limit then
						SetPromptPassword(password .. selected_char)
						SOUND:PlayOnce(THEME:GetPathS("Common", "Start"))
						if GetPromptPassword():len() >= password_char_limit then
							password_wheel:scroll_to_pos(2)
						end
					else
						SOUND:PlayOnce(THEME:GetPathS("Common", "Cancel"))
					end
					t:queuecommand("UpdatePasswordText")
				end
			elseif event.GameButton == "Select" or event.GameButton == "Back" then
				local password = GetPromptPassword()
				if password:len() > 0 then
					SetPromptPassword(password:sub(1, -2))
					SOUND:PlayOnce(THEME:GetPathS("Common", "Cancel"))
					t:queuecommand("UpdatePasswordText")
				end
			end
			return false
		end

		if has_error and event.GameButton == "Start" then
			local topScreen = SCREENMAN:GetTopScreen()
			if topScreen then
				topScreen:SetNextScreenName("ScreenSelectMusic")
				topScreen:StartTransitioningScreen("SM_GoToNextScreen")
			end
			return false
		end

			if not connected then
				return false
			end

			if pending_join_action_id > 0 and (event.GameButton == "Select" or event.GameButton == "Back") then
				SOUND:PlayOnce(THEME:GetPathS("Common", "Cancel"))
				cancel_pending_join("Join cancelled. Refreshing lobbies...")
				return false
			end

			if mode == "joined" then
				if leaving_lobby then
					return false
				end

				if event.GameButton == "MenuRight" or event.GameButton == "MenuLeft" then
					move_joined_button(event.GameButton == "MenuRight" and 1 or -1)
					SOUND:PlayOnce(THEME:GetPathS("ScreenSelectMaster", "change"))
					t:queuecommand("Hover")
				elseif event.GameButton == "Start" then
					normalize_joined_active_index()
					SOUND:PlayOnce(THEME:GetPathS("Common", "Start"))
					if joined_active_index == 1 then
						leave_confirm_index = 0
						showing_leave_confirm = true
						t:GetChild("LeaveConfirmPrompt"):visible(true)
					t:GetChild("LeaveConfirmPrompt"):playcommand("Hover")
				elseif joined_active_index == 2 and joined_is_manager then
					local topScreen = SCREENMAN:GetTopScreen()
					if topScreen then
							topScreen:SetNextScreenName("ScreenSelectMusic")
							topScreen:StartTransitioningScreen("SM_GoToNextScreen")
						end
					elseif joined_active_index == 3 and joined_missing_song then
						transition_to_online_song_reload()
					end
				end
				return false
			end

		if event.GameButton == "MenuRight" or event.GameButton == "MenuLeft" then
			holding[event.GameButton] = true
			if holding[event.GameButton == "MenuRight" and "MenuLeft" or "MenuRight"] then
				-- Same as Select below.
				if list_selected then
					list_selected = false
					SOUND:PlayOnce(THEME:GetPathS("Common", "Cancel"))
					t:queuecommand("LoseFocus")
					t:queuecommand("Hover")
				end
			else
				if not list_selected then
					active_index = (active_index + (event.GameButton=="MenuRight" and 1 or -1)) % #options
					SOUND:PlayOnce(THEME:GetPathS("ScreenSelectMaster", "change"))
					t:queuecommand("Hover")
				else
					if lobby_view == "players" then
						if #online_users > 0 then
							online_player_index = ((online_player_index - 1 + (event.GameButton=="MenuRight" and 1 or -1)) % #online_users) + 1
							SOUND:PlayOnce(THEME:GetPathS("ScreenSelectMaster", "change"))
							t:queuecommand("UpdateOnlinePlayers")
						end
					else
						if event.GameButton == "MenuRight" then
							t:queuecommand("NextLobby")
						else
							t:queuecommand("PrevLobby")
						end
					end
				end
			end
		elseif event.GameButton == "Start" then
			if list_selected then
				if lobby_view == "players" then
					if selected_online_user() then
						SOUND:PlayOnce(THEME:GetPathS("Common", "Start"))
						t:queuecommand("OpenPlayerActionMenu")
					else
						SOUND:PlayOnce(THEME:GetPathS("Common", "Cancel"))
					end
				else
					local lobbyList = t:GetChild("LobbyContent") and t:GetChild("LobbyContent"):GetChild("LobbyList")
					if lobbyList then
						SOUND:PlayOnce(THEME:GetPathS("Common", "Start"))
						lobbyList:playcommand("SelectLobby")
					else
						SOUND:PlayOnce(THEME:GetPathS("Common", "Cancel"))
					end
				end
				return false
			end

			if active_index == 0 then
				if (lobby_view == "lobbies" and #candidates > 0) or (lobby_view == "players" and #online_users > 0) then
					list_selected = true
					SOUND:PlayOnce(THEME:GetPathS("Common", "Start"))
					t:queuecommand("GainFocus")
					t:queuecommand("Selected")
					t:queuecommand("UpdateOnlinePlayers")
				else
					SOUND:PlayOnce(THEME:GetPathS("Common", "Cancel"))
				end
			elseif active_index == 1 then
				SOUND:PlayOnce(THEME:GetPathS("Common", "Start"))
				list_selected = false
				lobby_view = lobby_view == "players" and "lobbies" or "players"
				t:queuecommand("LoseFocus")
				t:queuecommand("UpdateLobbyView")
				t:queuecommand("Hover")
			elseif active_index == 2 then
				SOUND:PlayOnce(THEME:GetPathS("Common", "Start"))

				-- Uncomment the below to inject a sample lobby for testing purposes when refreshing the lobby list. --- IGNORE ---
				-- t:playcommand("SetStatus", {
				-- 	text="Loaded sample lobby (test mode).",
				-- 	showSpinner=false,
				-- 	showPrompt=false
				-- })
				-- MESSAGEMAN:Broadcast("LobbySearched", {
				-- 	lobbies = {sample_lobby}
				-- })
				-- return false

				local onlineHandler = GetOnlineHandlerInstance()
				if onlineHandler and onlineHandler.connected then
					t:playcommand("SetStatus", {
						text="Searching lobbies...",
						showSpinner=true,
						showPrompt=false
					})
					MESSAGEMAN:Broadcast("SearchLobby")
				else
					connected = false
					has_error = false
					attempted = false
					wait_time = 0
					t:GetChild("LobbyContent"):visible(false)
					t:GetChild("OnlinePlayersContent"):visible(false)
					t:playcommand("SetStatus", {
						text="Refreshing lobby list...",
						showSpinner=true,
						showPrompt=false
					})
					t:queuecommand("CheckConnect")
				end
			elseif active_index == 4 then
				SOUND:PlayOnce(THEME:GetPathS("Common", "Start"))
				local topScreen = SCREENMAN:GetTopScreen()
				if topScreen then
					topScreen:SetNextScreenName("ScreenSelectMusic")
					topScreen:StartTransitioningScreen("SM_GoToNextScreen")
				end
			elseif active_index == 3 then
				SOUND:PlayOnce(THEME:GetPathS("Common", "Start"))
				create_lobby_password = ""
				show_password_in_lobby = false
				showing_password_prompt = false
				t:GetChild("PasswordPrompt"):visible(false)
				t:GetChild("LobbyContent"):visible(false)
				t:GetChild("OnlinePlayersContent"):visible(false)
				t:playcommand("SetStatus", {
					text="Creating lobby...",
					showSpinner=true,
					showPrompt=false
				})
				MESSAGEMAN:Broadcast("CreateLobby", {})
			end
		elseif event.GameButton == "Select" or event.GameButton == "Back" then
			if list_selected then
				list_selected = false
				SOUND:PlayOnce(THEME:GetPathS("Common", "Cancel"))
				t:queuecommand("LoseFocus")
				t:queuecommand("Hover")
			end
		end
	elseif event.type == "InputEventType_Release" then
		if event.GameButton == "MenuRight" or event.GameButton == "MenuLeft" then
			holding[event.GameButton] = false
		end
	end
end

local wait_time = 0
local attempted = false
local af = Def.ActorFrame{
  OnCommand=function(self)
		t=self
    self:Center()
		if not input_added and SCREENMAN:GetTopScreen() then
			SCREENMAN:GetTopScreen():AddInputCallback(InputHandler)
			input_added = true
		end
		create_lobby_password = ""
		password_wheel:set_info_set(password_chars, 3)
		self:playcommand("SetStatus", {
			text="Initializing online connection...",
			showSpinner=true
		})
		self:queuecommand("CheckConnect")
  end,
	OffCommand=function(self)
		local onlineHandler = GetOnlineHandlerInstance()
		if onlineHandler and onlineHandler.connected and not onlineHandler.inLobby then
			MESSAGEMAN:Broadcast("DisconnectOnline")
		end
	end,
	Def.Actor{
		Name="JoinTimeoutTimer",
		CheckJoinTimeoutCommand=function(self)
			if pending_join_action_id > 0 and GetTimeSinceStart() >= pending_join_deadline then
				cancel_pending_join("Lobby join timed out. Refreshing lobbies...")
			end
		end
	},
	HoverCommand=function(self)
		self:GetChild("LobbyContent"):playcommand("Hover")
		self:GetChild("OnlinePlayersContent"):playcommand("Hover")
		self:GetChild("JoinedLobbyContent"):playcommand("Hover")
	end,
	UpdateOnlinePlayersCommand=function(self)
		local playersContent = self:GetChild("OnlinePlayersContent")
		if not playersContent then return end

		if #online_users == 0 then
			online_player_index = 1
		else
			online_player_index = math.max(1, math.min(online_player_index, #online_users))
		end

		local lines = {}
		for i, user in ipairs(online_users) do
			local selected = (list_selected and lobby_view == "players" and i == online_player_index) and "> " or "  "
			local room = user.room and user.room.name and (" " .. room_visibility_label(user.room) .. " " .. tostring(user.room.name)) or ""
			local status = user.status and (" [" .. tostring(user.status) .. "]") or ""
			lines[#lines + 1] = selected .. i .. ". " .. tostring(user.name or "Player") .. status .. room
		end

		local playersList = playersContent:GetChild("OnlinePlayersList")
		if playersList then
			playersList:settext(#lines > 0 and table.concat(lines, "\n") or "No connected players found.")
		end

		local playerCount = playersContent:GetChild("OnlinePlayersCount")
		if playerCount then
			playerCount:settext(tostring(#online_users))
		end
	end,
	UpdateLobbyViewCommand=function(self)
		local lobbyContent = self:GetChild("LobbyContent")
		local playersContent = self:GetChild("OnlinePlayersContent")
		if lobbyContent then
			lobbyContent:visible(mode ~= "joined")
			local lobbyList = lobbyContent:GetChild("LobbyList")
			if lobbyList then lobbyList:visible(lobby_view == "lobbies") end
		end
		if playersContent then playersContent:visible(mode ~= "joined" and lobby_view == "players") end

		local emptyText = lobbyContent and lobbyContent:GetChild("EmptyStateText")
		if emptyText then
			emptyText:visible(lobby_view == "lobbies" and #candidates == 0)
		end

		local toggleButton = lobbyContent and lobbyContent:GetChild("OnlinePlayersButton")
		local toggleText = toggleButton and toggleButton:GetChild("OnlinePlayersButtonText")
		if toggleText then
			toggleText:settext(lobby_view == "players" and "Available Lobbies" or "Online Players")
		end

		self:queuecommand("UpdateOnlinePlayers")
	end,
	OpenPlayerActionMenuCommand=function(self)
		player_action_user = selected_online_user()
		player_action_options = build_player_action_options(player_action_user)
		player_action_index = 1
		showing_player_action_menu = player_action_user ~= nil and #player_action_options > 0
		local menu = self:GetChild("PlayerActionMenu")
		if menu then
			menu:visible(showing_player_action_menu)
			self:queuecommand("UpdatePlayerActionMenu")
		end
	end,
	UpdatePlayerActionMenuCommand=function(self)
		local menu = self:GetChild("PlayerActionMenu")
		if not menu then return end
		local title = menu:GetChild("PlayerActionTitle")
		if title then
			title:settext(player_action_user and tostring(player_action_user.name or "Player") or "Player")
		end
		local body = {}
		for i, option in ipairs(player_action_options) do
			body[#body + 1] = (i == player_action_index and "> " or "  ") .. tostring(option.label)
		end
		local text = menu:GetChild("PlayerActionOptions")
		if text then text:settext(table.concat(body, "\n")) end
	end,
	UpdatePrivateJoinPromptCommand=function(self)
		local prompt = self:GetChild("PrivateJoinPrompt")
		if not prompt then return end
		local requester = private_join_request and private_join_request.requester or {}
		local room = private_join_request and private_join_request.room or {}
		local title = prompt:GetChild("PrivateJoinTitle")
		if title then
			title:settext(tostring(requester.name or "A player") .. " wants to join")
		end
		local detail = prompt:GetChild("PrivateJoinDetail")
		if detail then
			detail:settext("Private lobby: " .. tostring(room.name or "Lobby"))
		end
		local lines = {}
		for i, option in ipairs(private_join_options) do
			lines[#lines + 1] = (i == private_join_prompt_index and "> " or "  ") .. option.label
		end
		local optionsText = prompt:GetChild("PrivateJoinOptions")
		if optionsText then optionsText:settext(table.concat(lines, "\n")) end
	end,
	UpdatePasswordTextCommand=function(self)
		local text = GetPromptPassword()
		if text == "" then
			text = "(empty)"
		end
		local prompt = self:GetChild("PasswordPrompt")
		if prompt then
			prompt:GetChild("PasswordValue"):settext(text)
		end
	end,
	UpdatePasswordPromptUICommand=function(self)
		local prompt = self:GetChild("PasswordPrompt")
		if not prompt then return end

		local title = prompt:GetChild("PromptTitle")
		local hint = prompt:GetChild("PromptHint")
		local footer = prompt:GetChild("PromptFooter")

		if password_prompt_mode == "join" then
			if title then title:settext("Enter Lobby Password") end
			if hint then hint:settext("Use &MENULEFT;/&MENURIGHT; to pick characters, &START; to select, &SELECT; to delete.") end
			if footer then footer:settext("❌ removes a character. ✔ joins lobby.") end
		else
			if title then title:settext("Create Lobby Password (Optional)") end
			if hint then hint:settext("Use &MENULEFT;/&MENURIGHT; to pick characters, &START; to select, &SELECT; to delete.") end
			if footer then footer:settext("❌ removes a character. ✔ confirms.") end
		end
	end,
	UpdateJoinedLobbyTextCommand=function(self)
		local joinedContent = self:GetChild("JoinedLobbyContent")
		local codeValue = self:GetChild("JoinedLobbyContent"):GetChild("JoinedLobbyCodeValue")
		if codeValue then
			codeValue:settext(joined_lobby_code ~= "" and joined_lobby_code or "(pending)")
		end

		local lines = {}
		for i, player in ipairs(joined_lobby_players) do
			local profile = player.profileName or player.name or player.playerId or ("Player "..i)
			local ready = player.ready and " ✔" or ""
			lines[#lines+1] = i..". "..profile..ready
		end

		local playersText = self:GetChild("JoinedLobbyContent"):GetChild("JoinedLobbyPlayers")
		if playersText then
			playersText:settext(#lines > 0 and table.concat(lines, "\n") or "Waiting for players...")
		end

			local songStatus = joinedContent and joinedContent:GetChild("JoinedLobbySongStatus")
			if songStatus then
				local statusLines = {}
				local missingSongInfo = joined_missing_song_info or joined_song_preview
				if joined_missing_song and missingSongInfo then
					statusLines[#statusLines + 1] = "Missing or different song pack locally"
					if missingSongInfo.pack and missingSongInfo.pack ~= "" then
						statusLines[#statusLines + 1] = "Pack: " .. tostring(missingSongInfo.pack)
					end
					statusLines[#statusLines + 1] = "Song: " .. tostring(missingSongInfo.title or "Unknown")
					statusLines[#statusLines + 1] = "Install the exact pack in Songs/, then reload."
				elseif joined_song_preview then
					statusLines[#statusLines + 1] = (joined_song_confirmed and "✔ Song selected" or "Browsing song")
					if joined_song_preview.pack and joined_song_preview.pack ~= "" then
						statusLines[#statusLines + 1] = "Pack: " .. tostring(joined_song_preview.pack)
					end
					statusLines[#statusLines + 1] = "Song: " .. tostring(joined_song_preview.title or "Unknown")
				if joined_song_preview.artist and joined_song_preview.artist ~= "" then
					statusLines[#statusLines + 1] = "Artist: " .. tostring(joined_song_preview.artist)
				end
			elseif joined_is_manager then
				statusLines[#statusLines + 1] = "Choose a song when everyone is ready."
			else
					statusLines[#statusLines + 1] = "Waiting for the lobby creator to choose a song."
				end
				songStatus:settext(table.concat(statusLines, "\n"))
				songStatus:diffuse(joined_missing_song and Color.Red or joined_song_confirmed and Color.Green or Color.White)
			end

		local codeLabel = joinedContent and joinedContent:GetChild("JoinedLobbyCodeLabel")
		local passwordLabel = joinedContent and joinedContent:GetChild("JoinedLobbyPasswordLabel")
		local passwordValue = joinedContent and joinedContent:GetChild("JoinedLobbyPasswordValue")
		local hasPassword = create_lobby_password ~= ""
		local passwordHidden = hasPassword and (not show_password_in_lobby)
		if passwordLabel and passwordValue then
			if not hasPassword then
				passwordLabel:visible(false)
				passwordValue:visible(false)
			else
				local value = passwordHidden and string.rep("+", 4) or create_lobby_password
				passwordLabel:visible(true)
				passwordValue:visible(true)
				passwordValue:settext(value)
			end
		end

		if joinedContent then
			local function get_zoomed_width(actor)
				if not actor then return 0 end
				return actor:GetWidth() * actor:GetZoomX()
			end

			local function place_label_left_if_needed(labelActor, valueActor, defaultLabelX, valueX)
				if not labelActor or not valueActor then return end
				local valueWidth = get_zoomed_width(valueActor)
				local valueLeftEdge = valueX - valueWidth
				local gap = 12
				local desiredLabelX = math.min(defaultLabelX, valueLeftEdge - gap)
				local minLabelX = -285
				labelActor:x(math.max(minLabelX, desiredLabelX))
			end

			place_label_left_if_needed(codeLabel, codeValue, -10, 50)
			if hasPassword then
				place_label_left_if_needed(passwordLabel, passwordValue, -10, 50)
			else
				if passwordLabel then passwordLabel:x(-10) end
			end
		end

		local toggleButton = self:GetChild("JoinedLobbyContent"):GetChild("TogglePasswordButton")
		local toggleText = toggleButton and toggleButton:GetChild("TogglePasswordText")
		if toggleText then
			toggleText:settext(passwordHidden and "Show Password" or "Hide Password")
			toggleText:visible(hasPassword)
		end

		if toggleButton then
			toggleButton:visible(hasPassword)
		end

			local selectSongButton = joinedContent and joinedContent:GetChild("SelectSongButton")
			if selectSongButton then
				selectSongButton:visible(joined_is_manager)
			end

			local reloadSongsButton = joinedContent and joinedContent:GetChild("ReloadSongsButton")
			if reloadSongsButton then
				reloadSongsButton:visible(joined_missing_song)
			end
		end,
		SetStatusCommand=function(self, params)
			self:GetChild("NetworkStatus"):visible(true)
			self:GetChild("NetworkStatus"):playcommand("Set", params)
		end,
		CheckConnectCommand=function(self)
			local onlineHandler = GetOnlineHandlerInstance()
		if onlineHandler then
			-- If no connection exists, first (re)establish the connection.
			-- Only try once per screen load to avoid infinite loops of trying to connect.
			if not attempted and (not onlineHandler.socket or onlineHandler.errorMsg ~= nil) then
				self:playcommand("SetStatus", {
					text="Connecting to online service...",
					showSpinner=true
				})
				MESSAGEMAN:Broadcast("ConnectOnline")
				attempted = true
			end

			if not onlineHandler.connected and onlineHandler.errorMsg == nil then
				wait_time = wait_time + 1
				self:playcommand("SetStatus", {
					text="Connecting to online service... ("..wait_time.."s)",
					showSpinner=true
				})
				self:sleep(1):queuecommand("CheckConnect")
			else
				self:queuecommand("Display")
			end
		else
			self:playcommand("SetStatus", {
				text="Initializing online handler...",
				showSpinner=true
			})
			self:sleep(0.25):queuecommand("CheckConnect")
		end
	end,
	DisplayCommand=function(self)
		local onlineHandler = GetOnlineHandlerInstance()
		if onlineHandler then
			if onlineHandler.connected then
				connected = true
				has_error = false
				self:playcommand("SetStatus", {
					text="Connected to online service.",
					showSpinner=false,
					showPrompt=false
				})
				self:GetChild("NetworkStatus"):visible(false)
				self:queuecommand("UpdateLobbyView")
					self:GetChild("JoinedLobbyContent"):visible(mode == "joined")
					if ITGOnline and ITGOnline.currentRoomId then
						ITGOnline:FetchRoom(ITGOnline.currentRoomId, function(ok, decoded)
							if ok and decoded and decoded.room then
								MESSAGEMAN:Broadcast("OnlineLobbyState", ITGOnline:LobbyStatePayload(decoded.room))
							else
								MESSAGEMAN:Broadcast("SearchLobby")
							end
						end)
					else
						MESSAGEMAN:Broadcast("SearchLobby")
					end
					self:queuecommand("Hover")
				end

			if onlineHandler.errorMsg ~= nil then
				connected = false
				has_error = true
				self:playcommand("SetStatus", {
					text="Error connecting to online service:\n"..onlineHandler.errorMsg,
					showSpinner=false,
					showPrompt=true,
					promptText="Press &START; to return to Select Music."
				})
				self:GetChild("LobbyContent"):visible(false)
				self:GetChild("OnlinePlayersContent"):visible(false)
			end
		end
	end,
	LobbySearchedMessageCommand=function(self, params)
		candidates = params and params.lobbies or {}
		online_users = params and params.onlinePlayers or {}

		local lobbyContent = self:GetChild("LobbyContent")
		if lobbyContent then
			local lobbyList = lobbyContent:GetChild("LobbyList")
			if lobbyList then
				lobbyList:playcommand("UpdateData", {data=candidates})
			end

			local lobbyCount = lobbyContent:GetChild("LobbyCount")
			if lobbyCount then
				local total = #candidates
				lobbyCount:settext(total > 0 and ("1/"..total) or "0/0")
			end

			local emptyText = lobbyContent:GetChild("EmptyStateText")
			if emptyText then
				emptyText:visible(lobby_view == "lobbies" and #candidates == 0)
			end
		end

		self:GetChild("NetworkStatus"):visible(false)
		self:queuecommand("UpdateLobbyView")
		self:GetChild("JoinedLobbyContent"):visible(mode == "joined")
		self:queuecommand("Hover")
	end,
		OnlineLobbyStateMessageCommand=function(self, params)
			clear_pending_join()
			mode = "joined"
			leaving_lobby = false
		showing_leave_confirm = false
		list_selected = false
		showing_password_prompt = false
		password_prompt_mode = "create"
		join_lobby_code = ""
		join_lobby_password = ""
		joined_lobby_code = params and params.code or ""
			joined_lobby_players = params and params.players or {}
			joined_is_manager = params and params.isManager or false
			joined_song_preview = params and params.songInfo or nil
			joined_song_confirmed = params and params.songInfo ~= nil or false
			if not joined_song_confirmed then
				joined_missing_song = false
				joined_missing_song_info = nil
			end
			normalize_joined_active_index()

			self:queuecommand("UpdateJoinedLobbyText")

		self:GetChild("PasswordPrompt"):visible(false)
		self:GetChild("NetworkStatus"):visible(false)
		self:GetChild("LobbyContent"):visible(false)
			self:GetChild("OnlinePlayersContent"):visible(false)
			self:GetChild("JoinedLobbyContent"):visible(true)
			normalize_joined_active_index()
			self:queuecommand("Hover")
		end,
		OnlineMissingSongMessageCommand=function(self, params)
			joined_missing_song = true
			joined_missing_song_info = params and params.songInfo or joined_song_preview
			if params and params.songInfo then
				joined_song_preview = params.songInfo
				joined_song_confirmed = true
			end
			normalize_joined_active_index()
			self:queuecommand("UpdateJoinedLobbyText")
			self:queuecommand("Hover")
		end,
		OnlineSongAvailableMessageCommand=function(self)
			joined_missing_song = false
			joined_missing_song_info = nil
			normalize_joined_active_index()
			self:queuecommand("UpdateJoinedLobbyText")
			self:queuecommand("Hover")
		end,
	OnlineLobbyJoinSelectedMessageCommand=function(self, params)
		if not params or not params.code then
			SOUND:PlayOnce(THEME:GetPathS("Common", "Cancel"))
			return
		end

		join_lobby_code = params.code
		if params.isPasswordProtected then
			password_prompt_mode = "join"
			join_lobby_password = ""
			showing_password_prompt = true
			self:GetChild("PasswordPrompt"):visible(true)
			password_wheel:scroll_to_pos(3)
			self:queuecommand("UpdatePasswordPromptUI")
			self:queuecommand("UpdatePasswordText")
		else
			showing_password_prompt = false
			self:GetChild("PasswordPrompt"):visible(false)
			self:GetChild("LobbyContent"):visible(false)
			self:GetChild("OnlinePlayersContent"):visible(false)
				self:playcommand("SetStatus", {
					text="Joining lobby...",
					showSpinner=true,
					showPrompt=false
				})
				begin_join_timeout(self)
				MESSAGEMAN:Broadcast("JoinLobby", {
					code=params.code,
					password=params.password or ""
				})
			end
		end,
		OnlineLobbyLeftMessageCommand=function(self, params)
			if params == nil or params.left == nil or params.left then
				clear_pending_join()
				leaving_lobby = false
				showing_leave_confirm = false
			mode = "browse"
			joined_lobby_code = ""
			joined_lobby_players = {}
			self:GetChild("JoinedLobbyContent"):visible(false)
			self:queuecommand("UpdateLobbyView")
			self:GetChild("NetworkStatus"):visible(false)
			self:playcommand("SetStatus", {
				text="Left lobby.",
				showSpinner=false,
				showPrompt=false
			})
			self:queuecommand("Hover")
		end
	end,
	OnlinePrivateJoinRequestMessageCommand=function(self, params)
		if not params or not params.join_request then return end
		private_join_request = params
		private_join_prompt_index = 1
		showing_private_join_prompt = true
		local prompt = self:GetChild("PrivateJoinPrompt")
		if prompt then prompt:visible(true) end
		self:queuecommand("UpdatePrivateJoinPrompt")
	end,
	OnlineSongPreviewMessageCommand=function(self, params)
		if params and params.title then
			joined_song_preview = params
			joined_song_confirmed = false
			self:queuecommand("UpdateJoinedLobbyText")
		end
	end,
	OnlineResponseStatusMessageCommand=function(self, params)
		if params and params.event == "createLobby" and params.success == false then
			mode = "browse"
			self:GetChild("JoinedLobbyContent"):visible(false)
			self:queuecommand("UpdateLobbyView")
			self:playcommand("SetStatus", {
				text=params.message and ("Create lobby failed:\n"..params.message) or "Create lobby failed.",
				showSpinner=false,
				showPrompt=false
			})
			elseif params and params.event == "joinLobby" and params.success == true then
				clear_pending_join()
				self:playcommand("SetStatus", {
					text=params.message or "Join request sent. Waiting for the room manager.",
					showSpinner=false,
					showPrompt=false
				})
			elseif params and params.event == "joinLobby" and params.success == false then
				clear_pending_join()
				mode = "browse"
				self:GetChild("JoinedLobbyContent"):visible(false)
			self:queuecommand("UpdateLobbyView")
			self:playcommand("SetStatus", {
				text=params.message and ("Join lobby failed:\n"..params.message) or "Join lobby failed.",
				showSpinner=false,
				showPrompt=false
			})
		elseif params and params.event == "leaveLobby" and params.success == false then
			leaving_lobby = false
			showing_leave_confirm = false
			self:playcommand("SetStatus", {
				text=params.message and ("Leave lobby failed:\n"..params.message) or "Leave lobby failed.",
				showSpinner=false,
				showPrompt=false
			})
		elseif params and params.event == "invitePlayer" then
			if params.success then
				self:playcommand("SetStatus", {
					text=params.message or "Invitation sent.",
					showSpinner=false,
					showPrompt=false
				})
			else
				mode = "browse"
				self:GetChild("JoinedLobbyContent"):visible(false)
				self:queuecommand("UpdateLobbyView")
				self:playcommand("SetStatus", {
					text=params.message and ("Invitation failed:\n"..params.message) or "Invitation failed.",
					showSpinner=false,
					showPrompt=false
				})
			end
		elseif params and params.event == "privateJoinAnswer" then
			self:playcommand("SetStatus", {
				text=params.message or "Join request answered.",
				showSpinner=false,
				showPrompt=false
			})
		end
	end,

	Def.ActorFrame{
		Name="LobbyContent",
		InitCommand=function(self)
			self:visible(false)
		end,
  
		LoadFont("Common Normal")..{
			Text="&MENULEFT;/&MENURIGHT; to Choose | &START; to Select | &SELECT; or &MENULEFT;+&MENURIGHT; to Return",
			InitCommand=function(self)
				self:y(180)
			end
		},

		Def.ActorFrame{
			Name="LobbyList",
			InitCommand=function(self)
				self:x(-120)
				self.idx = 0
			end,
			OnCommand=function(self)
				self:playcommand("UpdateData", {data=candidates})
			end,

			Def.Quad{
				InitCommand=function(self)
					self:zoomto(360,340):y(-20):diffuse(Color.White)
				end,
				HoverCommand=function(self)
					if not list_selected then
						self:diffuse(active_index == self:GetParent().idx and Color.Yellow or Color.White)
					end
				end,
				SelectedCommand=function(self)
					self:diffuse(active_index == self:GetParent().idx and Color.Green or Color.White)
				end
			},

			Def.Quad{
				InitCommand=function(self)
					self:zoomto(360-2,340-2):y(-20):diffuse(Color.Black)
				end
			},

			Def.Quad{
				InitCommand=function(self)
					self:zoomto(350, 1):y(-150):diffuse(Color.White)
				end
			},

			LoadFont("Common Bold")..{
				Text="Available Lobbies",
				InitCommand=function(self)
					self:horizalign(left):x(-170):y(-170):zoom(0.5)
				end,
				HoverCommand=function(self)
					self:diffuse(active_index == self:GetParent().idx and GetHexColor(SL.Global.ActiveColorIndex) or Color.White)
				end
			},

			LoadFont("Common Normal")..{
				Name="LobbyCount",
				Text="0/0",
				InitCommand=function(self)
					self:horizalign(right):x(170):y(-170)
				end,
				UpdateIndexCommand=function(self, params)
					self:settext(params.idx .. "/" .. params.total)
				end
			},

			LoadActor("LobbyInfo.lua")
		},

		LoadFont("Common Normal")..{
			Name="EmptyStateText",
			Text="No lobbies found.",
			InitCommand=function(self)
				self:horizalign(center):xy(-120, -120):zoom(1.4):diffuse(Color.White):visible(false)
			end
		},

		Def.ActorFrame{
			Name="OnlinePlayersButton",
			InitCommand=function(self)
				local idx = 2
				local width = 200
				local height = 40
				local spacing = 20
				local mid = #options / 2
				self:y((idx - 1 - mid) * (spacing + height))
				self:x(180)
				self.idx = idx - 1
			end,
			Def.Quad{
				InitCommand=function(self)
					self:zoomto(200, 40):diffuse(Color.White)
				end,
				HoverCommand=function(self)
					self:diffuse(active_index == self:GetParent().idx and Color.Yellow or Color.White)
				end,
				SelectedCommand=function(self)
					self:diffuse(active_index == self:GetParent().idx and Color.Green or Color.White)
				end
			},

			Def.Quad{
				InitCommand=function(self)
					self:zoomto(198, 38):diffuse(Color.Black)
				end
			},

			LoadFont("Common Bold")..{
				Name="OnlinePlayersButtonText",
				Text="Online Players",
				InitCommand=function(self)
					self:zoom(0.5)
				end,
				HoverCommand=function(self)
					self:diffuse(active_index == self:GetParent().idx and GetHexColor(SL.Global.ActiveColorIndex) or Color.White)
				end
			},
			Def.Quad{
				InitCommand=function(self)
					self:zoomto(200, 40):diffuse(color("#424242")):diffusealpha(0)
				end,
				SelectedCommand=function(self)
					if active_index ~= self:GetParent().idx then
						-- Gray out the button if it's not selected, since it won't do anything.
						self:diffusealpha(0.70)
					else
						self:diffusealpha(0)
					end
				end,
				LoseFocusCommand=function(self)
					self:diffusealpha(0)
				end
			},
		},

		Def.ActorFrame{
			InitCommand=function(self)
				local idx = 3
				local width = 200
				local height = 40
				local spacing = 20
				local mid = #options / 2
				self:y((idx - 1 - mid) * (spacing + height))
				self:x(180)
				self.idx = idx - 1
			end,

			Def.Quad{
				InitCommand=function(self)
					self:zoomto(200, 40):diffuse(Color.White)
				end,
				HoverCommand=function(self)
					self:diffuse(active_index == self:GetParent().idx and Color.Yellow or Color.White)
				end,
				SelectedCommand=function(self)
					self:diffuse(active_index == self:GetParent().idx and Color.Green or Color.White)
				end
			},

			Def.Quad{
				InitCommand=function(self)
					self:zoomto(198, 38):diffuse(Color.Black)
				end
			},

			LoadFont("Common Bold")..{
				Text="Refresh List",
				InitCommand=function(self)
					self:zoom(0.5)
				end,
				HoverCommand=function(self)
					self:diffuse(active_index == self:GetParent().idx and GetHexColor(SL.Global.ActiveColorIndex) or Color.White)
				end
			},
			Def.Quad{
				InitCommand=function(self)
					self:zoomto(200, 40):diffuse(color("#424242")):diffusealpha(0)
				end,
				SelectedCommand=function(self)
					if active_index ~= self:GetParent().idx then
						-- Gray out the button if it's not selected, since it won't do anything.
						self:diffusealpha(0.70)
					else
						self:diffusealpha(0)
					end
				end,
				LoseFocusCommand=function(self)
					self:diffusealpha(0)
				end
			},
		},

		Def.ActorFrame{
			InitCommand=function(self)
				local idx = 4
				local width = 200
				local height = 40
				local spacing = 20
				local mid = #options / 2
				self:y((idx - 1 - mid) * (spacing + height))
				self:x(180)
				self.idx = idx - 1
			end,

			Def.Quad{
				InitCommand=function(self)
					self:zoomto(200, 40):diffuse(Color.White)
				end,
				HoverCommand=function(self)
					self:diffuse(active_index == self:GetParent().idx and Color.Yellow or Color.White)
				end,
				SelectedCommand=function(self)
					self:diffuse(active_index == self:GetParent().idx and Color.Green or Color.White)
				end
			},

			Def.Quad{
				InitCommand=function(self)
					self:zoomto(198, 38):diffuse(Color.Black)
				end
			},

			LoadFont("Common Bold")..{
				Text="Create Lobby",
				InitCommand=function(self)
					self:zoom(0.5)
				end,
				HoverCommand=function(self)
					self:diffuse(active_index == self:GetParent().idx and GetHexColor(SL.Global.ActiveColorIndex) or Color.White)
				end
			},
			Def.Quad{
				InitCommand=function(self)
					self:zoomto(200, 40):diffuse(color("#424242")):diffusealpha(0)
				end,
				SelectedCommand=function(self)
					if active_index ~= self:GetParent().idx then
						-- Gray out the button if it's not selected, since it won't do anything.
						self:diffusealpha(0.70)
					else
						self:diffusealpha(0)
					end
				end,
				LoseFocusCommand=function(self)
					self:diffusealpha(0)
				end
			},
		},

		Def.ActorFrame{
			InitCommand=function(self)
				local idx = 5
				local width = 200
				local height = 40
				local spacing = 20
				local mid = #options / 2
				self:y((idx - 1 - mid) * (spacing + height))
				self:x(180)
				self.idx = idx - 1
			end,

			Def.Quad{
				InitCommand=function(self)
					self:zoomto(200, 40):diffuse(Color.White)
				end,
				HoverCommand=function(self)
					self:diffuse(active_index == self:GetParent().idx and Color.Yellow or Color.White)
				end,
				SelectedCommand=function(self)
					self:diffuse(active_index == self:GetParent().idx and Color.Green or Color.White)
				end
			},

			Def.Quad{
				InitCommand=function(self)
					self:zoomto(198, 38):diffuse(Color.Black)
				end
			},

			LoadFont("Common Bold")..{
				Text="Go Back",
				InitCommand=function(self)
					self:zoom(0.5)
				end,
				HoverCommand=function(self)
					self:diffuse(active_index == self:GetParent().idx and GetHexColor(SL.Global.ActiveColorIndex) or Color.White)
				end
			},
			Def.Quad{
				InitCommand=function(self)
					self:zoomto(200, 40):diffuse(color("#424242")):diffusealpha(0)
				end,
				SelectedCommand=function(self)
					if active_index ~= self:GetParent().idx then
						self:diffusealpha(0.70)
					else
						self:diffusealpha(0)
					end
				end,
				LoseFocusCommand=function(self)
					self:diffusealpha(0)
				end
			},
		},
	},

	Def.ActorFrame{
		Name="OnlinePlayersContent",
		InitCommand=function(self)
			self:visible(false)
		end,
		HoverCommand=function(self)
			local toggleButton = t and t:GetChild("LobbyContent") and t:GetChild("LobbyContent"):GetChild("OnlinePlayersButton")
			if toggleButton then toggleButton:playcommand("Hover") end
		end,

		LoadFont("Common Normal")..{
			Text="&MENULEFT;/&MENURIGHT; to Choose | &START; to Select",
			InitCommand=function(self)
				self:y(180)
			end
		},

		Def.Quad{
			InitCommand=function(self)
				self:zoomto(360,340):x(-120):y(-20):diffuse(Color.White)
			end
		},
		Def.Quad{
			InitCommand=function(self)
				self:zoomto(358,338):x(-120):y(-20):diffuse(Color.Black)
			end
		},
		Def.Quad{
			InitCommand=function(self)
				self:zoomto(350, 1):x(-120):y(-150):diffuse(Color.White)
			end
		},
		LoadFont("Common Bold")..{
			Text="Online Players",
			InitCommand=function(self)
				self:horizalign(left):x(-290):y(-170):zoom(0.5)
			end
		},
		LoadFont("Common Normal")..{
			Name="OnlinePlayersCount",
			Text="0",
			InitCommand=function(self)
				self:horizalign(right):x(50):y(-170):zoom(0.8)
			end
		},
		LoadFont("Common Normal")..{
			Name="OnlinePlayersList",
			Text="No connected players found.",
			InitCommand=function(self)
				self:horizalign(left):vertalign(top):xy(-290, -132):zoom(0.82):maxwidth(620)
			end
		},
	},

	Def.ActorFrame{
		Name="PlayerActionMenu",
		InitCommand=function(self) self:visible(false) end,
		Def.Quad{
			InitCommand=function(self)
				self:zoomto(SCREEN_WIDTH, SCREEN_HEIGHT):diffuse(0,0,0,0.72)
			end
		},
		Def.Quad{
			InitCommand=function(self)
				self:zoomto(560, 250):diffuse(0,0,0,0.92)
			end
		},
		LoadFont("Common Bold")..{
			Name="PlayerActionTitle",
			Text="Player",
			InitCommand=function(self)
				self:y(-88):zoom(0.8)
			end
		},
		LoadFont("Common Normal")..{
			Text="&MENULEFT;/&MENURIGHT; to Choose | &START; to Confirm | &SELECT; to Cancel",
			InitCommand=function(self)
				self:y(-58):zoom(0.5)
			end
		},
		LoadFont("Common Normal")..{
			Name="PlayerActionOptions",
			Text="",
			InitCommand=function(self)
				self:horizalign(left):vertalign(top):xy(-220, -22):zoom(0.7):maxwidth(650)
			end
		},
	},

	Def.ActorFrame{
		Name="PrivateJoinPrompt",
		InitCommand=function(self) self:visible(false) end,
		Def.Quad{
			InitCommand=function(self)
				self:zoomto(SCREEN_WIDTH, SCREEN_HEIGHT):diffuse(0,0,0,0.72)
			end
		},
		Def.Quad{
			InitCommand=function(self)
				self:zoomto(600, 280):diffuse(0,0,0,0.94)
			end
		},
		LoadFont("Common Bold")..{
			Name="PrivateJoinTitle",
			Text="Player wants to join",
			InitCommand=function(self)
				self:y(-104):zoom(0.76)
			end
		},
		LoadFont("Common Normal")..{
			Name="PrivateJoinDetail",
			Text="Private lobby",
			InitCommand=function(self)
				self:y(-74):zoom(0.56):maxwidth(760)
			end
		},
		LoadFont("Common Normal")..{
			Text="Choose a reply. Decline reason is sent only to that player.",
			InitCommand=function(self)
				self:y(-48):zoom(0.48):diffuse(0.8,0.8,0.8,1)
			end
		},
		LoadFont("Common Normal")..{
			Name="PrivateJoinOptions",
			Text="",
			InitCommand=function(self)
				self:horizalign(left):vertalign(top):xy(-220, -16):zoom(0.68):maxwidth(680)
			end
		},
	},

	Def.ActorFrame{
		Name="PasswordPrompt",
		InitCommand=function(self)
			self:visible(false)
		end,

		Def.Quad{
			InitCommand=function(self)
				self:zoomto(SCREEN_WIDTH, SCREEN_HEIGHT):diffuse(0,0,0,0.75)
			end
		},
		Def.Quad{
			InitCommand=function(self)
				self:zoomto(560, 210):diffuse(0,0,0,0.9)
			end
		},
		LoadFont("Common Normal")..{
			Name="PromptTitle",
			Text="Create Lobby Password (Optional)",
			InitCommand=function(self)
				self:y(-72):zoom(0.85)
			end
		},
		LoadFont("Common Normal")..{
			Name="PromptHint",
			Text="Use &MENULEFT;/&MENURIGHT; to pick characters, &START; to select, &SELECT; to delete.",
			InitCommand=function(self)
				self:y(-46):zoom(0.55)
			end
		},
		LoadFont("Common Bold")..{
			Name="PasswordValue",
			Text="(empty)",
			InitCommand=function(self)
				self:y(-14):zoom(0.6)
			end
		},
		password_wheel:create_actors("PasswordWheel", 7, password_character_mt, 50, 38),
		LoadFont("Common Normal")..{
			Name="PromptFooter",
			Text="❌ removes a character. ✔ confirms.",
			InitCommand=function(self)
				self:y(90):zoom(0.6)
			end
		},
	},

	Def.ActorFrame{
		Name="JoinedLobbyContent",
		InitCommand=function(self)
			self:visible(false)
		end,

		Def.Quad{
			InitCommand=function(self)
				self:zoomto(360,340):x(-120):y(-20):diffuse(Color.White)
			end
		},
		Def.Quad{
			InitCommand=function(self)
				self:zoomto(358,338):x(-120):y(-20):diffuse(Color.Black)
			end
		},
		Def.Quad{
			InitCommand=function(self)
				self:zoomto(350, 1):x(-120):y(-150):diffuse(Color.White)
			end
		},
		LoadFont("Common Bold")..{
			Text="Joined Lobby",
			InitCommand=function(self)
				self:horizalign(left):x(-290):y(-170):zoom(0.5)
			end
		},
		LoadFont("Common Normal")..{
			Name="JoinedLobbyCodeLabel",
			Text="Lobby Code:",
			InitCommand=function(self)
				self:horizalign(right):x(-10):y(-170):zoom(1)
			end
		},
		LoadFont("Common Bold")..{
			Name="JoinedLobbyCodeValue",
			Text="(pending)",
			InitCommand=function(self)
				self:horizalign(right):x(50):y(-170):zoom(0.5)
			end
		},
		LoadFont("Common Normal")..{
			Name="JoinedLobbyPlayers",
			Text="Waiting for players...",
			InitCommand=function(self)
				self:horizalign(left):x(-290):y(-100):zoom(1):maxwidth(560)
			end
		},
		LoadFont("Common Normal")..{
			Name="JoinedLobbySongStatus",
			Text="Waiting for song...",
			InitCommand=function(self)
				self:horizalign(left):vertalign(top):xy(-290, 20):zoom(0.62):maxwidth(580)
			end
		},
		LoadFont("Common Normal")..{
			Name="JoinedLobbyPasswordLabel",
			Text="Password:",
			InitCommand=function(self)
				self:horizalign(right):x(-10):y(-130):zoom(1):visible(false)
			end
		},
		LoadFont("Common Bold")..{
			Name="JoinedLobbyPasswordValue",
			Text="",
			InitCommand=function(self)
				self:horizalign(right):x(50):y(-130):zoom(0.5):visible(false)
			end
		},

		Def.ActorFrame{
			Name="TogglePasswordButton",
			InitCommand=function(self)
				self:xy(180, -60)
				self.idx = 0
				self:visible(false)
			end,
			Def.Quad{
				InitCommand=function(self)
					self:zoomto(200, 40):diffuse(Color.White)
				end,
				HoverCommand=function(self)
					self:diffuse(joined_active_index == self:GetParent().idx and Color.Yellow or Color.White)
				end
			},
			Def.Quad{
				InitCommand=function(self)
					self:zoomto(198, 38):diffuse(Color.Black)
				end
			},
			LoadFont("Common Bold")..{
				Name="TogglePasswordText",
				Text="Show Password",
				InitCommand=function(self)
					self:zoom(0.5)
				end,
				HoverCommand=function(self)
					self:diffuse(joined_active_index == self:GetParent().idx and GetHexColor(SL.Global.ActiveColorIndex) or Color.White)
				end
			}
		},

		Def.ActorFrame{
			InitCommand=function(self)
				self:xy(180, 0)
				self.idx = 1
			end,
			Def.Quad{
				InitCommand=function(self)
					self:zoomto(200, 40):diffuse(Color.White)
				end,
				HoverCommand=function(self)
					self:diffuse(joined_active_index == self:GetParent().idx and Color.Yellow or Color.White)
				end
			},
			Def.Quad{
				InitCommand=function(self)
					self:zoomto(198, 38):diffuse(Color.Black)
				end
			},
			LoadFont("Common Bold")..{
				Text="Leave Lobby",
				InitCommand=function(self)
					self:zoom(0.5)
				end,
				HoverCommand=function(self)
					self:diffuse(joined_active_index == self:GetParent().idx and GetHexColor(SL.Global.ActiveColorIndex) or Color.White)
				end
			}
		},

			Def.ActorFrame{
				Name="SelectSongButton",
				InitCommand=function(self)
					self:xy(180, 60)
					self.idx = 2
			end,
			Def.Quad{
				InitCommand=function(self)
					self:zoomto(200, 40):diffuse(Color.White)
				end,
				HoverCommand=function(self)
					self:diffuse(joined_active_index == self:GetParent().idx and Color.Yellow or Color.White)
				end
			},
			Def.Quad{
				InitCommand=function(self)
					self:zoomto(198, 38):diffuse(Color.Black)
				end
			},
			LoadFont("Common Bold")..{
				Text="Select Music",
				InitCommand=function(self)
					self:zoom(0.5)
				end,
				HoverCommand=function(self)
					self:diffuse(joined_active_index == self:GetParent().idx and GetHexColor(SL.Global.ActiveColorIndex) or Color.White)
				end
				}
			},

			Def.ActorFrame{
				Name="ReloadSongsButton",
				InitCommand=function(self)
					self:xy(180, 120)
					self.idx = 3
					self:visible(false)
				end,
				Def.Quad{
					InitCommand=function(self)
						self:zoomto(200, 40):diffuse(Color.White)
					end,
					HoverCommand=function(self)
						self:diffuse(joined_active_index == self:GetParent().idx and Color.Yellow or Color.White)
					end
				},
				Def.Quad{
					InitCommand=function(self)
						self:zoomto(198, 38):diffuse(Color.Black)
					end
				},
				LoadFont("Common Bold")..{
					Text="Reload Songs",
					InitCommand=function(self)
						self:zoom(0.5)
					end,
					HoverCommand=function(self)
						self:diffuse(joined_active_index == self:GetParent().idx and GetHexColor(SL.Global.ActiveColorIndex) or Color.White)
					end
				}
			},
		},

	Def.ActorFrame{
		Name="LeaveConfirmPrompt",
		InitCommand=function(self)
			self:visible(false)
		end,
		HoverCommand=function(self)
			self:GetChild("CancelButton"):playcommand("Hover")
			self:GetChild("ConfirmButton"):playcommand("Hover")
		end,

		Def.Quad{
			InitCommand=function(self)
				self:zoomto(SCREEN_WIDTH, SCREEN_HEIGHT):diffuse(0,0,0,0.6)
			end
		},
		Def.Quad{
			InitCommand=function(self)
				self:zoomto(500, 180):diffuse(0,0,0,0.9)
			end
		},
		LoadFont("Common Normal")..{
			Text="Disconnect from the lobby and return to Select Music?",
			InitCommand=function(self)
				self:y(-42):zoom(1)
			end
		},

		Def.ActorFrame{
			Name="CancelButton",
			InitCommand=function(self)
				self:x(-90):y(30)
			end,
			Def.Quad{
				InitCommand=function(self)
					self:zoomto(150, 40):diffuse(Color.White)
				end,
				HoverCommand=function(self)
					self:diffuse(leave_confirm_index == 0 and Color.Yellow or Color.White)
				end
			},
			Def.Quad{
				InitCommand=function(self)
					self:zoomto(148, 38):diffuse(Color.Black)
				end
			},
			LoadFont("Common Bold")..{
				Text="Cancel",
				InitCommand=function(self)
					self:zoom(0.5)
				end,
				HoverCommand=function(self)
					self:diffuse(leave_confirm_index == 0 and GetHexColor(SL.Global.ActiveColorIndex) or Color.White)
				end
			}
		},

		Def.ActorFrame{
			Name="ConfirmButton",
			InitCommand=function(self)
				self:x(90):y(30)
			end,
			Def.Quad{
				InitCommand=function(self)
					self:zoomto(150, 40):diffuse(Color.White)
				end,
				HoverCommand=function(self)
					self:diffuse(leave_confirm_index == 1 and Color.Yellow or Color.White)
				end
			},
			Def.Quad{
				InitCommand=function(self)
					self:zoomto(148, 38):diffuse(Color.Black)
				end
			},
			LoadFont("Common Bold")..{
				Text="Disconnect",
				InitCommand=function(self)
					self:zoom(0.5)
				end,
				HoverCommand=function(self)
					self:diffuse(leave_confirm_index == 1 and GetHexColor(SL.Global.ActiveColorIndex) or Color.White)
				end
			}
		}
	},



	-- Keep this on top of everything else so that it doesn't get covered up by any other elements.
	Def.ActorFrame{
		Name="NetworkStatus",
		InitCommand=function(self)
			self:y(-130)
		end,
		SetCommand=function(self, params)
			if not params then return end
			local showPrompt = params.showPrompt == true
			self:GetChild("Spinner"):visible(params.showSpinner == true)
			self:GetChild("StatusText"):settext(params.text or "")
			self:GetChild("PromptText"):visible(showPrompt)
			self:GetChild("PromptText"):settext(showPrompt and (params.promptText or "") or "")

			local statusWidth = self:GetChild("StatusText"):GetWidth()
			local promptWidth = showPrompt and self:GetChild("PromptText"):GetWidth() or 0
			local width = math.min(math.max(math.max(statusWidth, promptWidth) + 50, 360), 620)
			local height = showPrompt and 78 or 52
			self:GetChild("Background"):zoomto(width, height)
			self:GetChild("Spinner"):x(-width/2 + 22)
		end,

		Def.Quad{
			Name="Background",
			InitCommand=function(self)
				self:zoomto(280, 44):diffuse(0,0,0,0.75)
			end
		},
		Def.Sprite{
			Name="Spinner",
			Texture=THEME:GetPathG("", "LoadingSpinner 10x3.png"),
			Frames=Sprite.LinearFrames(30,1),
			InitCommand=function(self)
				self:x(-118):zoom(0.14):diffuse(GetHexColor(SL.Global.ActiveColorIndex, true)):visible(false)
			end,
			VisualStyleSelectedMessageCommand=function(self)
				self:diffuse(GetHexColor(SL.Global.ActiveColorIndex, true))
			end
		},
		LoadFont("Common Normal")..{
			Name="StatusText",
			Text="",
			InitCommand=function(self)
				self:maxwidth(560):zoom(0.82):diffuse(Color.White):y(-10)
			end
		},
		LoadFont("Common Normal")..{
			Name="PromptText",
			Text="",
			InitCommand=function(self)
				self:maxwidth(560):zoom(0.95):diffuse(Color.White):y(18):visible(false)
			end
		}
	},
}

return af
