local choices, choice_actors, choice_backgrounds = {}, {}, {}
local TopScreen = nil
local MPN = GAMESTATE:GetMasterPlayerNumber()
local last_description_key = nil
local current_choice = nil
-- give this a value now, before the TopScreen has been prepared and we can fetch its name
-- we'll reassign it appropriately below, once the TopScreen is available
local ScreenName = "ScreenSelectPlayMode"

local cursor = {
	h = 40,
	index = 0,
	-- the width of the cursor will be clamped to exist between these two values
	min_w = 90, max_w = 170,
	width = 90,
}

local function ChoiceWidth(index)
	local actor = choice_actors[index]
	if not actor then return cursor.min_w end

	local width = actor:GetWidth()
	if width <= 0 then
		width = actor:GetZoomedWidth()
	end
	if width <= 0 then return cursor.min_w end

	return clamp(width/1.4, cursor.min_w, cursor.max_w)
end

local function RefreshCursorWidth()
	local new_width = ChoiceWidth(cursor.index+1)
	if new_width == cursor.width then return false end

	cursor.width = new_width
	return true
end

local function SetCursorIndex(index)
	if not index or #choices == 0 then return false end

	index = clamp(index, 0, #choices - 1)
	local changed = index ~= cursor.index

	cursor.index = index
	current_choice = choices[cursor.index+1]
	local width_changed = RefreshCursorWidth()

	return changed, width_changed
end

local function RefreshChoiceBackground(index, tween)
	local actor = choice_backgrounds[index]
	if not actor then return end

	local exists = choices[index] ~= nil
	actor:visible(exists)
	if not exists then return end

	actor:stoptweening()
	if tween then actor:linear(0.1) end
	actor:zoomtowidth(ChoiceWidth(index))
end

local function RefreshChoiceBackgrounds(tween)
	for i=1,4 do
		RefreshChoiceBackground(i, tween)
	end
end

local function ChoiceBackground(index)
	return Def.Quad{
		InitCommand=function(self)
			choice_backgrounds[index] = self
			self:diffuse(0.2,0.2,0.2,1)
				:x(-188)
				:y(-60 + (cursor.h * (index-1)))
				:zoomto(cursor.min_w, 38)
		end,
		OnCommand=function(self) RefreshChoiceBackground(index, false) end,
		UpdateCommand=function(self) RefreshChoiceBackground(index, true) end,
		OffCommand=function(self) self:sleep(0.5 - index*0.1):linear(0.1):diffusealpha(0) end
	}
end

local Update = function(af)
	if not TopScreen then return end
	local index = TopScreen:GetSelectionIndex(MPN)
	local index_changed, width_changed = SetCursorIndex(index)

	if index_changed then
		-- queue the appropriate command to the faux playfield, if needed
		if ScreenName=="ScreenSelectPlayMode2" then
			if choices[cursor.index+1] == "Marathon" then
				af:queuecommand("FirstLoopMarathon")
			else
				af:queuecommand("FirstLoopRegular")
			end
		end

		-- queue an "Update" to the AF containing the cursor, description text, score, and lifemeter actors
		-- since they are children of that AF, they will also listen for that command
		RefreshChoiceBackgrounds(true)
		af:queuecommand("Update")
	elseif width_changed then
		RefreshChoiceBackgrounds(false)
		af:queuecommand("Update")
	end
end

local InputHandler = function(event)
	if not event.PlayerNumber or not event.button then return false end
	if event.PlayerNumber ~= MPN then return false end
	if event.type ~= "InputEventType_FirstPress" or event.GameButton ~= "Start" then
		return false
	end

	local selected = choices[cursor.index+1]
	if not selected then return false end

	if ScreenName=="ScreenSelectPlayMode" or ScreenName=="ScreenSelectPlayModeThonk" then
		SL.Global.GameMode = selected
		-- now that a GameMode has been selected, set related preferences
		SetGameModePreferences()
		-- and reload the theme's Metrics
		THEME:ReloadMetrics()
		if TopScreen then TopScreen:StartTransitioningScreen("SM_GoToNextScreen") end
	elseif ScreenName=="ScreenSelectOnlineMode" then
		SL.Global.ITGOnline = SL.Global.ITGOnline or {}
		SL.Global.ITGOnline.Enabled = selected == "Online"

		if TopScreen then
			TopScreen:SetNextScreenName(Branch.AfterSelectOnlineMode())
			TopScreen:StartTransitioningScreen("SM_GoToNextScreen")
		end
	end
end

local t = Def.ActorFrame{
	InitCommand=function(self)
		self:SetUpdateFunction( Update )
			:xy(_screen.cx+90, _screen.cy)
			:zoom(1.25)
	end,
	OnCommand=function(self)
		-- Get the Topscreen and its name, now that that TopScreen itself actually exists
		TopScreen = SCREENMAN:GetTopScreen()
		ScreenName = TopScreen:GetName()
		choices = {}
		choice_actors = {}
		current_choice = nil
		last_description_key = nil

		-- now that we have the TopScreen's name, get the single string containing this
		-- screen's choices from Metrics.ini, and split it on commas; store those choices
		-- in the choices table, and do similarly with actors associated with those choices
		for choice in THEME:GetMetric(ScreenName, "ChoiceNames"):gmatch('([^,]+)') do
			choices[#choices+1] = choice
			choice_actors[#choice_actors+1] = TopScreen:GetChild("IconChoice"..choice)
		end

		if ScreenName == "ScreenSelectPlayMode" then
			SetCursorIndex((FindInTable(ThemePrefs.Get("DefaultGameMode"), choices) or 2) - 1)
		else
			SetCursorIndex(TopScreen:GetSelectionIndex(MPN) or 0)
		end

    	TopScreen:AddInputCallback(InputHandler)

		RefreshChoiceBackgrounds(false)
		self:queuecommand("Update")
		self:sleep(0):queuecommand("RefreshInitialChoiceLayout")
		self:sleep(0.05):queuecommand("RefreshInitialChoiceLayout")
	end,
	RefreshInitialChoiceLayoutCommand=function(self)
		SetCursorIndex(cursor.index)
		RefreshChoiceBackgrounds(false)
		self:queuecommand("Update")
	end,
	OffCommand=function(self)
		if TopScreen then
			TopScreen:RemoveInputCallback(InputHandler)
		end
		TopScreen = nil
		choices = {}
		choice_actors = {}
		choice_backgrounds = {}
		current_choice = nil
		last_description_key = nil
	end,
	-- side mask
	Def.Quad{
		InitCommand=function(self) self:zoomto(450, 450):diffuse(1,1,1,1):x(375):MaskSource() end
	},
	-- lower mask
	Def.Quad{
		InitCommand=function(self) self:zoomto(450, 450):diffuse(1,1,1,1):xy(74,305):MaskSource() end
	},

	-- gray backgrounds
	Def.ActorFrame{
		ChoiceBackground(1),
		ChoiceBackground(2),
		ChoiceBackground(3),
		ChoiceBackground(4),
	},

	-- border
	Def.Quad{
		InitCommand=function(self) self:zoomto(302, 162):diffuse(1,1,1,1) end,
		OffCommand=function(self) self:sleep(0.6):linear(0.2):cropleft(1) end
	},
	-- background
	Def.Quad{
		InitCommand=function(self) self:zoomto(300, 160):diffuse(0,0,0,1) end,
		OffCommand=function(self) self:sleep(0.6):linear(0.2):cropleft(1) end
	},


	-- description
	Def.BitmapText{
		Font="Common Normal",
		InitCommand=function(self)
			self:zoom(0.825):halign(0):valign(0):xy(-130,-60)
		end,
		UpdateCommand=function(self)
			local selected = current_choice or choices[cursor.index+1]
			if selected then
				local key = selected .. "Description"
				if key ~= last_description_key then
					last_description_key = key
					self:settext(THEME:GetString("ScreenSelectPlayMode", key))
				end
			else
				if last_description_key ~= "" then
					last_description_key = ""
					self:settext("")
				end
			end
		end,
		OffCommand=function(self) self:sleep(0.4):linear(0.2):diffusealpha(0) end
	},

	-- cursor to highlight the current choice
	Def.ActorFrame{
		Name="Cursor",
		OnCommand=function(self)
			-- it is possible for players to have something other than "ITG" as the default choice
			-- for ScreenSelectPlayMode (see: Simply Love Options in the Operator Menu)
			-- account for that here, in the OnCommand of the cursor ActorFrame, by updating cursor.index
			-- to match the value of ThemePrefs.Get("DefaultGameMode") in the choices table
			if ScreenName == "ScreenSelectPlayMode" then
				SetCursorIndex((FindInTable(ThemePrefs.Get("DefaultGameMode"), choices) or 2) - 1)
			else
				SetCursorIndex(cursor.index)
			end
			self:x(-150):y( -60 + (cursor.h * cursor.index) )
		end,
		UpdateCommand=function(self)
			self:stoptweening():linear(0.1)
				:y( -60 + (cursor.h * cursor.index) )
		end,

		Def.Quad{
			InitCommand=function(self) self:zoomtoheight(cursor.h+2):diffuse(1,1,1,1):x(-1):halign(1) end,
			UpdateCommand=function(self) self:zoomtowidth(cursor.width) end,
			OffCommand=function(self) self:sleep(0.4):linear(0.2):cropleft(1) end
		},
		Def.Quad{
			InitCommand=function(self) self:zoomtoheight(cursor.h):diffuse(0,0,0,1):halign(1) end,
			UpdateCommand=function(self) self:zoomtowidth(cursor.width) end,
			OffCommand=function(self) self:sleep(0.4):linear(0.2):cropleft(1) end
		}
	},

	-- Score
	Def.BitmapText{
		Font="Wendy/_wendy monospace numbers",
		InitCommand=function(self)
			self:zoom(0.225):xy(124,-68):diffusealpha(0)
		end,
		OffCommand=function(self) self:sleep(0.4):linear(0.2):diffusealpha(0) end,
		UpdateCommand=function(self)
			if ScreenName == "ScreenSelectOnlineMode" then
				self:stoptweening():linear(0.25):diffusealpha(0)
			elseif ScreenName == "ScreenSelectPlayMode" then
				if current_choice == "Casual" then
					self:stoptweening():linear(0.25):diffusealpha(0)
				else
					self:settext("77.41")
					self:stoptweening():linear(0.25):diffusealpha(1)
				end
			else
				self:diffusealpha(1)
				self:settext("77.41")
			end
		end,

	},
	-- LifeMeter
	Def.ActorFrame{
		Name="LifeMeter",
		InitCommand=function(self) self:diffusealpha(0) end,
		OffCommand=function(self) self:sleep(0.4):linear(0.2):diffusealpha(0) end,
		UpdateCommand=function(self)
			if ScreenName == "ScreenSelectOnlineMode" then
				self:stoptweening():linear(0.25):diffusealpha(0)
			elseif ScreenName == "ScreenSelectPlayMode" then
				if current_choice == "ITG" then
					self:stoptweening():linear(0.25):diffusealpha(1)
				else
					self:stoptweening():linear(0.25):diffusealpha(0)
				end
			else
				self:diffusealpha(1)
			end
		end,
		-- lifemeter white border
		Def.Quad{
			InitCommand=function(self) self:zoomto(60,16):xy(68,-64) end
		},
		-- lifemeter black bg
		Def.Quad{
			InitCommand=function(self) self:zoomto(58,14):xy(68,-64):diffuse(0,0,0,1) end
		},
		-- lifemeter colored quad
		Def.Quad{
			InitCommand=function(self) self:zoomto(40,14):xy(59,-64):diffuse( GetCurrentColor(true) ) end
		},
		-- Keep this static in menu screens to reduce asset churn and audio pressure.
	},
}

-- Preview arrows are intentionally disabled here to eliminate transition stalls
-- and reduce intermittent mixer underruns on lower-end machines.

return t
