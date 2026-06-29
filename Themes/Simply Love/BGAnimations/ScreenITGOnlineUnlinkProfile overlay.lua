local text_width = WideScale(460, 560)
local choice_gap = WideScale(150, 190)
local active_index = 1
local completed = false
local choice_actors = {}
local body
local af

local function screen_text(key)
	return THEME:GetString("ScreenITGOnlineUnlinkProfile", key)
end

local function unlink_trace(message)
	if type(online_logs_enabled) == "function" and not online_logs_enabled() then
		return
	end
	if not Trace then return end
	Trace("ITG Online: UnlinkProfile " .. tostring(message or ""))
end

local function go_back()
	unlink_trace("go_back screen=ScreenOnlineOptions completed=" .. tostring(completed))
	local top_screen = SCREENMAN:GetTopScreen()
	top_screen:SetNextScreenName("ScreenOnlineOptions"):StartTransitioningScreen("SM_GoToNextScreen")
end

local function update_choices()
	unlink_trace("update_choices activeIndex=" .. tostring(active_index) .. " completed=" .. tostring(completed))
	for i, actor in pairs(choice_actors) do
		actor:finishtweening()
		if i == active_index then
			actor:diffuse(PlayerColor(PLAYER_1)):linear(0.08):zoom(1.05)
		else
			actor:diffuse(1, 1, 1, 0.65):linear(0.08):zoom(0.82)
		end
	end
end

local function unlink_profile()
	unlink_trace("unlink_profile begin hasClient=" .. tostring(ITGOnline ~= nil)
		.. " hasMethod=" .. tostring(ITGOnline and ITGOnline.UnlinkLocalProfile ~= nil))
	local had_link = false
	if ITGOnline and ITGOnline.UnlinkLocalProfile then
		had_link = ITGOnline:UnlinkLocalProfile()
	end

	unlink_trace("unlink_profile complete hadLink=" .. tostring(had_link))
	completed = true
	active_index = 2
	if body then
		body:settext(screen_text(had_link and "DoneBody" or "NothingBody"))
	end
	for i, actor in pairs(choice_actors) do
		actor:visible(i == 2)
	end
	update_choices()
	SCREENMAN:SystemMessage(screen_text(had_link and "DoneMessage" or "NothingMessage"))
end

local InputHandler = function(event)
	if not event.PlayerNumber or not event.button then return false end
	if event.type ~= "InputEventType_FirstPress" then return false end

	if completed then
		if event.GameButton == "Start" or event.GameButton == "Back" then
			unlink_trace("input_after_completed button=" .. tostring(event.GameButton))
			go_back()
			return true
		end
		return false
	end

	if event.GameButton == "MenuLeft" or event.GameButton == "MenuRight" then
		active_index = active_index == 1 and 2 or 1
		unlink_trace("input_move button=" .. tostring(event.GameButton) .. " activeIndex=" .. tostring(active_index))
		update_choices()
		if af then af:queuecommand("DirectionButton") end
		return true
	end

	if event.GameButton == "Back" then
		unlink_trace("input_back activeIndex=" .. tostring(active_index))
		go_back()
		return true
	end

	if event.GameButton == "Start" then
		unlink_trace("input_start activeIndex=" .. tostring(active_index))
		if active_index == 1 then
			unlink_profile()
		else
			go_back()
		end
		return true
	end

	return false
end

local t = Def.ActorFrame{
	OnCommand=function(self)
		unlink_trace("screen_on")
		af = self
		SCREENMAN:GetTopScreen():AddInputCallback(InputHandler)
	end
}

t[#t+1] = Def.Quad{
	InitCommand=function(self)
		self:FullScreen():diffuse(color("#05070CEE"))
	end
}

t[#t+1] = LoadFont("Common Bold")..{
	Text=screen_text("Title"),
	InitCommand=function(self)
		self:xy(_screen.cx, _screen.cy - 130):zoom(WideScale(0.95, 1.1))
	end
}

t[#t+1] = LoadFont("Common Normal")..{
	Text=screen_text("Body"),
	InitCommand=function(self)
		body = self
		self:xy(_screen.cx - text_width / 2, _screen.cy - 55)
			:halign(0):valign(0):zoom(WideScale(0.75, 0.85))
			:_wrapwidthpixels(text_width)
	end
}

local choices = Def.ActorFrame{
	InitCommand=function(self) self:xy(_screen.cx, _screen.cy + 95) end,
	OnCommand=function(self) update_choices() end
}

choices[#choices+1] = Def.ActorFrame{
	InitCommand=function(self)
		self:x(-choice_gap / 2)
		choice_actors[1] = self
	end,
	LoadFont("Common Bold")..{
		Text=screen_text("Confirm"),
		InitCommand=function(self) self:zoom(0.9) end
	}
}

choices[#choices+1] = Def.ActorFrame{
	InitCommand=function(self)
		self:x(choice_gap / 2)
		choice_actors[2] = self
	end,
	LoadFont("Common Bold")..{
		Text=screen_text("Cancel"),
		InitCommand=function(self) self:zoom(0.9) end
	}
}

t[#t+1] = choices

t[#t+1] = LoadActor(THEME:GetPathS("ScreenSelectMaster", "change"))..{
	IsAction=true,
	DirectionButtonCommand=function(self) self:play() end
}

return t
