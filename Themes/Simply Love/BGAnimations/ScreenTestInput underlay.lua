local held = {}
local unmapped_list
local held_count = 0
local last_unmapped_text = nil
local game = GAMESTATE:GetCurrentGame():GetName()
local is_supported_game = (game=="dance" or game=="pump" or game=="techno")
local is_rainbow_mode = ThemePrefs.Get("RainbowMode")
local not_mapped_label = THEME:GetString("ScreenTestInput", "not mapped")

-- -----------------------------------------------------------------------

local InputHandler = function(event)
	if not (event and event.button) then return false end

	-- allow players to back out of ScreenTestInput by pressing Escape on their keyboard
	if event.GameButton == "Back" then
		local top = SCREENMAN:GetTopScreen()
		if top then
			top:StartTransitioningScreen("SM_GoToNextScreen")
		end
	end

	if event.type ~= "InputEventType_Repeat" then
		MESSAGEMAN:Broadcast("TestInputEvent", event)
	end

	if event.button == "" then
		local key = ("%s %s"):format(ToEnumShortString(event.DeviceInput.device), ToEnumShortString(event.DeviceInput.button))
		local changed = false

		if event.type == "InputEventType_Release" then
			if held[key] then
				held[key] = false
				held_count = math.max(0, held_count - 1)
				changed = true
			end
		else
			if not held[key] then
				held[key] = true
				held_count = held_count + 1
				changed = true
			end
		end

		if changed and unmapped_list then
			unmapped_list:playcommand("Update")
		end
	end

	return false
end

-- -----------------------------------------------------------------------

local af = Def.ActorFrame {
	OnCommand=function(self)
		-- only add a Lua input callback handler for dance, pump, and techno
		-- where we load in custom visuals
		if is_supported_game then
			SCREENMAN:GetTopScreen():AddInputCallback(InputHandler)
		end
	end,
	OffCommand=function(self) self:sleep(0.4) end,

	Def.DeviceList {
		Font=THEME:GetPathF("","Common Normal"),
		InitCommand=function(self)
			if is_rainbow_mode then self:diffuse(0,0,0,1) end
			self:xy(_screen.cx,_screen.h-60):zoom(0.8)
		end
	}
}

-- for these specific games
if is_supported_game then

	-- load custom visuals only for players that are actually joined
	for player in ivalues(PlayerNumber) do
		if GAMESTATE:IsHumanPlayer(player) then
		local pad = LoadActor(THEME:GetPathB("", "_modules/TestInput Pad"), {Player=player, ShowMenuButtons=true, ShowPlayerLabel=true})

		pad.InitCommand=function(self) self:xy(_screen.cx + 150 * (player==PLAYER_1 and -1 or 1), _screen.cy):diffusealpha(0) end
		pad.OnCommand=function(self) self:linear(0.3):diffusealpha(1) end
		pad.OffCommand=function(self) self:linear(0.2):diffusealpha(0) end

		af[#af+1] = pad
		end
	end

	-- and add a custom BitmapText to show which inputs are not mapped to any game buttons
	af[#af+1] = Def.BitmapText{
		Font="Common Normal",
		InitCommand=function(self)
			if is_rainbow_mode then self:diffuse(0,0,0,1) end
			self:xy(_screen.cx, _screen.cy+32):vertalign(top):vertspacing(-3)
			unmapped_list = self
		end,
		UpdateCommand=function(self)
			if held_count == 0 then
				if last_unmapped_text ~= "" then
					last_unmapped_text = ""
					self:settext("")
				end
				return
			end
			local lines = {}
			for k, v in pairs(held) do
				if v then
					lines[#lines+1] = ("%s (%s)"):format(k, not_mapped_label)
				end
			end
			local text = table.concat(lines, "\n")
			if text ~= last_unmapped_text then
				last_unmapped_text = text
				self:settext(text)
			end
		end

	}

-- for other games (para, kb7), just use a standard InputList provided by the engine
else
	af[#af+1] = Def.InputList{
		Font="Common Normal",
		InitCommand=function(self)
			if is_rainbow_mode then self:diffuse(0,0,0,1) end
			self:xy(_screen.cx-250, 50):horizalign(left):vertalign(top):vertspacing(0)
		end
	}
end

return af
