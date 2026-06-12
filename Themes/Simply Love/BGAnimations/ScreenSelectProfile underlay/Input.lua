local args = ...
local af = args.af
local scrollers = args.Scrollers
local profile_data = args.ProfileData

-- a simple boolean flag we'll use to ignore input once profiles have been
-- selected and the screen's OffCommand has been queued.
--
-- aside: SM's screen class does have a RemoveInputCallback() method,
-- but it needs a reference to the original input handler funtion as
-- a passed-in argument, and that's tricky with how I've split
-- ScreenSelectProfile's code across multiple files.
local finished = false

-- Table used to determine whether a player has selected their profile. 
-- This value basically represents the amount of players that are ready to
-- move forward.
local readyPlayers = {
	["P1"] = false,
	["P2"] = false,
}

-- If a player is not joined, we'll set their readyPlayers flag to true
-- to bypass that side
if not GAMESTATE:IsSideJoined(PLAYER_1) then
	readyPlayers["P1"] = true
end
if not GAMESTATE:IsSideJoined(PLAYER_2) then
	readyPlayers["P2"] = true
end

-- we need to calculate how many dummy rows the scroller was "padded" with
-- (to achieve the desired transform behavior since I am not mathematically
-- perspicacious enough to have done so otherwise).
-- we'll use index_padding to get the correct info out of profile_data.
local index_padding = 0
for profile in ivalues(profile_data) do
	if profile.index == nil or profile.index <= 0 then
		index_padding = index_padding + 1
	end
end

local AutoStyle = ThemePrefs.Get("AutoStyle")
local function is_create_profile(info)
	return type(info) == "table" and info.isCreateProfile == true
end

local function trimmed_profile_name(answer)
	return (answer or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function screen_string(key, fallback)
	local text = THEME:GetString("ScreenSelectProfile", key)
	if not text or text == "" or text == key then
		return fallback
	end
	return text
end

local function profile_create_log(message)
	Trace("[SL_PROFILE_CREATE] " .. tostring(message))
end

local function count_profile_data()
	local count = 0
	for _ in ivalues(profile_data) do
		count = count + 1
	end
	return count
end

local function total_songs_text(num_songs)
	local key = num_songs == 1 and "SingularSongPlayed" or "SeveralSongsPlayed"
	local template = screen_string(key, "%d Songs Played")
	return template:format(num_songs)
end

local function build_scroller_data()
	local create_profile = { displayname = THEME:GetString("ScreenSelectProfile", "CreateProfile"), isCreateProfile = true }
	local guest_profile = { index = 0, displayname = THEME:GetString("ScreenSelectProfile", "GuestProfile") }
	local scroller_data = {{}, {}, {}, create_profile, guest_profile}

	for profile in ivalues(profile_data) do
		table.insert(scroller_data, profile)
	end

	return scroller_data
end

local function rebuild_profile_data_from_manager()
	local existing_by_dir = {}
	for profile in ivalues(profile_data) do
		if profile.dir then
			existing_by_dir[profile.dir] = profile
		end
	end

	for key in pairs(profile_data) do
		profile_data[key] = nil
	end

	for i = 1, PROFILEMAN:GetNumLocalProfiles() do
		local manager_index = i - 1
		local id = PROFILEMAN:GetLocalProfileIDFromIndex(manager_index)
		local dir = PROFILEMAN:LocalProfileIDToDir(id)
		local profile = PROFILEMAN:GetLocalProfileFromIndex(manager_index)
		local data = existing_by_dir[dir] or {}

		data.index = i
		data.dir = dir
		data.displayname = profile:GetDisplayName()
		data.totalsongs = total_songs_text(profile:GetNumTotalSongsPlayed())
		data.guid = profile:GetGUID()

		table.insert(profile_data, data)
	end

	profile_create_log(("rebuild_profile_data_from_manager count=%d manager_count=%s"):format(
		count_profile_data(),
		tostring(PROFILEMAN:GetNumLocalProfiles())
	))
end

local function set_player_frame_data(player, data)
	local frame = af:GetChild(ToEnumShortString(player) .. "Frame")
	if not frame then return end

	local selected_text = frame:GetChild("SelectedProfileText")
	if selected_text then
		selected_text:settext(data and data.displayname or "")
	end
end

local function refresh_profile_scrollers(created_profile_id, creating_player)
	profile_create_log(("refresh_begin profile_id=%s creating_player=%s num_before=%s data_before=%d"):format(
		tostring(created_profile_id),
		tostring(creating_player),
		tostring(PROFILEMAN:GetNumLocalProfiles()),
		count_profile_data()
	))

	rebuild_profile_data_from_manager()

	local created_index = PROFILEMAN:GetLocalProfileIndexFromID(created_profile_id)
	profile_create_log(("created_index profile_id=%s index=%s"):format(tostring(created_profile_id), tostring(created_index)))
	if not created_index or created_index < 0 then
		return false
	end

	local created_data = profile_data[created_index + 1]
	profile_create_log(("created_data exists=%s displayname=%s index=%s"):format(
		tostring(created_data ~= nil),
		created_data and tostring(created_data.displayname) or "nil",
		created_data and tostring(created_data.index) or "nil"
	))
	if not created_data then
		return false
	end

	local scroller_data = build_scroller_data()
	profile_create_log(("scroller_data_count=%d"):format(#scroller_data))
	for player, scroller in pairs(scrollers) do
		profile_create_log(("updating_scroller player=%s is_creator=%s"):format(tostring(player), tostring(player == creating_player)))
		scroller:set_info_set(scroller_data, 1)
		if player == creating_player then
			scroller:scroll_by_amount(created_data.index)
			set_player_frame_data(player, created_data)
		else
			local focused = scroller:get_info_at_focus_pos()
			set_player_frame_data(player, focused)
		end
	end

	profile_create_log("refresh_success")
	return true
end

local function prompt_for_new_profile(player)
	profile_create_log(("prompt_open player=%s num_profiles=%s data_count=%d"):format(
		tostring(player),
		tostring(PROFILEMAN:GetNumLocalProfiles()),
		count_profile_data()
	))
	SCREENMAN:AddNewScreenToTop("ScreenTextEntry")
	SCREENMAN:GetTopScreen():Load({
		Question = screen_string("CreateProfilePrompt", "Enter a name for the profile."),
		InitialAnswer = "",
		MaxInputLength = 32,
		Validate = function(answer)
			local trimmed = trimmed_profile_name(answer)
			profile_create_log(("validate raw='%s' trimmed='%s'"):format(tostring(answer), tostring(trimmed)))
			if trimmed == "" then
				profile_create_log("validate_failed blank_name")
				return false, screen_string("ProfileNameBlank", "Profile name cannot be blank.")
			end

			profile_create_log("validate_success")
			return true, ""
		end,
		OnOK = function(answer)
			local trimmed = trimmed_profile_name(answer)
			profile_create_log(("on_ok_begin name='%s' num_before=%s"):format(tostring(trimmed), tostring(PROFILEMAN:GetNumLocalProfiles())))
			local ok, profile_id = PROFILEMAN:CreateLocalProfile(trimmed)
			profile_create_log(("create_result ok=%s profile_id=%s num_after_create=%s"):format(
				tostring(ok),
				tostring(profile_id),
				tostring(PROFILEMAN:GetNumLocalProfiles())
			))
			if not ok or not profile_id or profile_id == "" then
				profile_create_log("create_failed")
				SCREENMAN:SystemMessage(screen_string("ProfileCreateFailed", "The profile could not be created. Check that the game can write to the Save folder."))
				return
			end

			SL.Global.SelectProfileCreatedProfileID = profile_id
			if not refresh_profile_scrollers(profile_id, player) then
				profile_create_log("refresh_failed")
				SCREENMAN:SystemMessage(screen_string("ProfileCreateFailed", "The profile was created, but the profile list could not be refreshed."))
			end
		end,
	})
end

local Handle = {}

Handle.Start = function(event)
	-- Nothing to do if the player has already selected a profile
	if GAMESTATE:IsHumanPlayer(event.PlayerNumber) and readyPlayers[ToEnumShortString(event.PlayerNumber)] then return end

	local topscreen = SCREENMAN:GetTopScreen()

	-- if the input event came from a side that is not currently registered as a human player, we'll either
	-- want to reject the input (we're in Pay mode and there aren't enough credits to join the player),
	-- or we'll use ScreenSelectProfile's inscrutably custom SetProfileIndex() method to join the player.
	if not GAMESTATE:IsHumanPlayer(event.PlayerNumber) then

		-- IsArcade() is defined in _fallback/Scripts/02 Utilities.lua
		-- in CoinMode_Free, EnoughCreditsToJoin() will always return true
		-- thankfully, EnoughCreditsToJoin() factors in Premium settings
		if IsArcade() then
			if not GAMESTATE:EnoughCreditsToJoin() then
				-- play the InvalidChoice sound and don't go any further
				MESSAGEMAN:Broadcast("InvalidChoice", {PlayerNumber=event.PlayerNumber})
				return
			else
				if (not SL.Global.FastProfileSwitchInProgress and
						GAMESTATE:GetCoinMode() == "CoinMode_Pay" and
						(GAMESTATE:GetPremium() ~= "Premium_2PlayersFor1Credit" or
						GAMESTATE:GetNumPlayersEnabled()==0)) then
					-- Consume the credit if:
					-- 1. This side is not joined
					-- 2. We are not fast switching (i.e. in the SelectMusic screen)
					-- 3. We are in coin mode
					-- 4. EITHER Each side needs its own credits
					--    OR neither side is currently joined
					GAMESTATE:InsertCoin(-GAMESTATE:GetCoinsNeededToJoin())
				end
			end
		end

		-- unset the readyPlayers flag for this player since they now
		-- have to make a selection
		readyPlayers[ToEnumShortString(event.PlayerNumber)] = false

		-- otherwise, pass -1 to SetProfileIndex() to join that player
		-- see ScreenSelectProfile.cpp for details
		topscreen:SetProfileIndex(event.PlayerNumber, -1)
	else

		local other_player = event.PlayerNumber == PLAYER_1 and PLAYER_2 or PLAYER_1
		local info = scrollers[event.PlayerNumber]:get_info_at_focus_pos()

		if is_create_profile(info) and event.GameButton == "Start" then
			prompt_for_new_profile(event.PlayerNumber)
			return
		end

		-- we only bother checking scrollers to see if both players are
		-- trying to choose the same profile if there are scrollers because
		-- there are local profiles.  If there are no local profiles, there are
		-- no scrollers to compare.
		if PROFILEMAN:GetNumLocalProfiles() > 0
			-- and if both players have joined and neither is using a memorycard
			and #GAMESTATE:GetHumanPlayers() > 1 and not GAMESTATE:IsAnyHumanPlayerUsingMemoryCard()
			-- and if a player is trying to select a profile the other has already selected
			and readyPlayers[ToEnumShortString(other_player)] == true
			and scrollers[PLAYER_1]:get_info_at_focus_pos().index == scrollers[PLAYER_2]:get_info_at_focus_pos().index
			-- and that profile they are both trying to choose isn't [GUEST]
			and scrollers[PLAYER_1]:get_info_at_focus_pos().index ~= 0 then
			-- broadcast an InvalidChoice message to play the "Common invalid" sound
			-- and "shake" the playerframe for the player that just pressed start
			MESSAGEMAN:Broadcast("InvalidChoice", {PlayerNumber=event.PlayerNumber})
			return
		end
		readyPlayers[ToEnumShortString(event.PlayerNumber)] = true
		MESSAGEMAN:Broadcast("SelectedProfile", {PlayerNumber=event.PlayerNumber})

		if readyPlayers["P1"] and readyPlayers["P2"] then
			-- Set finished to true so that we don't process any more input
			finished = true	
			-- if we're here, both players have selected a profile
			-- play the StartButton sound
			MESSAGEMAN:Broadcast("StartButton")
			-- and queue the OffCommand for the entire screen
			topscreen:queuecommand("Off"):sleep(0.4)
		end
	end
end
Handle.Center = Handle.Start


Handle.MenuLeft = function(event)
	-- Nothing to do if the player has already selected a profile
	if readyPlayers[ToEnumShortString(event.PlayerNumber)] then return end

	if GAMESTATE:IsHumanPlayer(event.PlayerNumber) and MEMCARDMAN:GetCardState(event.PlayerNumber) == 'MemoryCardState_none' then
		local info = scrollers[event.PlayerNumber]:get_info_at_focus_pos()
		local index = type(info)=="table" and info.index or 0

		-- Allow moving from [Guest] to the special "Create Profile" entry,
		-- but do not let the selection travel above that sentinel row.
		if (index - 1 >= 0) or (index == 0 and not (type(info) == "table" and info.isCreateProfile)) then
			MESSAGEMAN:Broadcast("DirectionButton")
			scrollers[event.PlayerNumber]:scroll_by_amount(-1)

			local new_info = scrollers[event.PlayerNumber]:get_info_at_focus_pos()
			local data = type(new_info) == "table" and new_info.isCreateProfile
				and new_info
				or profile_data[(type(new_info) == "table" and new_info.index or 0) + index_padding]
			local frame = af:GetChild(ToEnumShortString(event.PlayerNumber) .. 'Frame')
			frame:GetChild("SelectedProfileText"):settext(data and data.displayname or "")
			frame:playcommand("Set", data)
		end
	end
end
Handle.MenuUp = Handle.MenuLeft
Handle.DownLeft = Handle.MenuLeft

Handle.MenuRight = function(event)
	-- Nothing to do if the player has already selected a profile
	if readyPlayers[ToEnumShortString(event.PlayerNumber)] then return end

	if GAMESTATE:IsHumanPlayer(event.PlayerNumber) and MEMCARDMAN:GetCardState(event.PlayerNumber) == 'MemoryCardState_none' then
		local info = scrollers[event.PlayerNumber]:get_info_at_focus_pos()
		local index = type(info)=="table" and info.index or 0

		if index+1 <= PROFILEMAN:GetNumLocalProfiles() then
			MESSAGEMAN:Broadcast("DirectionButton")
			scrollers[event.PlayerNumber]:scroll_by_amount(1)

			local new_info = scrollers[event.PlayerNumber]:get_info_at_focus_pos()
			local data = type(new_info) == "table" and new_info.isCreateProfile
				and new_info
				or profile_data[(type(new_info) == "table" and new_info.index or 0) + index_padding]
			local frame = af:GetChild(ToEnumShortString(event.PlayerNumber) .. 'Frame')
			frame:GetChild("SelectedProfileText"):settext(data and data.displayname or "")
			frame:playcommand("Set", data)
		end
	end
end
Handle.MenuDown = Handle.MenuRight
Handle.DownRight = Handle.MenuRight

Handle.Back = function(event)
	if GAMESTATE:GetNumPlayersEnabled()==0 then
		if SL.Global.FastProfileSwitchInProgress then
			-- Going back to the song wheel without any players connected doesn't
			-- make much sense; disallow dismissing the ScreenSelectProfile
			-- top screen until at least one player has joined in
			MESSAGEMAN:Broadcast("PreventEscape")
		else
			-- On the other hand, dismissing the regular ScreenSelectProfile
			-- (not in fast switch mode) is perfectly fine since we can just go
			-- back to the previous screen
			SCREENMAN:GetTopScreen():Cancel()
		end
	else
		-- If the player is joined, has selected a profile but then pressed back, we
		-- need to unset the readyPlayers flag and go back to the profile scoller.
		if GAMESTATE:IsHumanPlayer(event.PlayerNumber) and 
				readyPlayers[ToEnumShortString(event.PlayerNumber)] then
			readyPlayers[ToEnumShortString(event.PlayerNumber)] = false
			MESSAGEMAN:Broadcast("BackButton", {PlayerNumber=event.PlayerNumber})
			MESSAGEMAN:Broadcast("UnselectedProfile", {PlayerNumber=event.PlayerNumber})
			return
		end
		
		-- Otherwise they are unjoining.
		MESSAGEMAN:Broadcast("BackButton", {PlayerNumber=event.PlayerNumber})

		if (GAMESTATE:IsHumanPlayer(event.PlayerNumber) and
				not SL.Global.FastProfileSwitchInProgress and
				GAMESTATE:GetCoinMode() == "CoinMode_Pay" and
			    (GAMESTATE:GetPremium() ~= "Premium_2PlayersFor1Credit" or
				 GAMESTATE:GetNumPlayersEnabled()==1)) then
			-- Refund credit if:
			-- 1. This side is originally joined
			-- 2. We are not fast switching (i.e. in the SelectMusic screen)
			-- 3. We are in coin mode
			-- 4. EITHER each side needs its own credits
			--    OR we are about to have 0 players joined, thus refunding the original credit.
			
			-- We originally consumed the credit when the player joined, so we
			-- should refund them if they unjoin.

			-- Use the CoinsPerCredit over GetCoinsNeededToJoin because
			-- it'll report 0 when going from 1 -> 0 players in
			-- Premium_2PlayersFor1Credit mode since a side is currently
			-- joined.
			local coins = PREFSMAN:GetPreference("CoinsPerCredit")
			GAMESTATE:InsertCoin(coins)
		end
		
		-- set the readyPlayers flag for this player since they no longer
		-- need to make a selection
		readyPlayers[ToEnumShortString(event.PlayerNumber)] = true

		-- ScreenSelectProfile:SetProfileIndex() will interpret -2 as
		-- "Unjoin this player and unmount their USB stick if there is one"
		-- see ScreenSelectProfile.cpp for details
		SCREENMAN:GetTopScreen():SetProfileIndex(event.PlayerNumber, -2)

		-- CurrentStyle has to be explicitly set to single in order to be able to
		-- unjoin a player from a 2-player setup
		if SL.Global.FastProfileSwitchInProgress and GAMESTATE:GetNumSidesJoined() == 1 then
			GAMESTATE:SetCurrentStyle("single")
			-- If AutoStyle is single then someone had joined during gameplay
			-- We need to explicitly remove this player's join frame
			if (AutoStyle=="single") then
				SCREENMAN:GetTopScreen():playcommand("Update", {player=event.PlayerNumber})
			else
				SCREENMAN:GetTopScreen():playcommand("Update")
			end
		end

	end
end
Handle.Select = Handle.Back


local InputHandler = function(event)
	if finished then return false end
	if not event or not event.button then return false end
	if (((AutoStyle=="single" or AutoStyle=="double") and #GAMESTATE:GetHumanPlayers() == 1) and event.PlayerNumber ~= GAMESTATE:GetMasterPlayerNumber()) then return false	end

	if event.type ~= "InputEventType_Release" then
		if Handle[event.GameButton] then Handle[event.GameButton](event) end
	end
end

return InputHandler
