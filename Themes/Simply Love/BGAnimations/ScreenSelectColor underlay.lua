local wheel = setmetatable({}, sick_wheel_mt)
local top_screen = nil

-- a simple flag to determine if the color was actively selected by a player;
-- we don't want the FinishCommand to double-trigger via the timer running out
-- AND a player pressing start
local ColorSelected = false
local ColorPrefDirty = false

local is_widescreen = IsUsingWideScreen()
local NumHeartsToDraw = is_widescreen and 11 or 7
local HeartsSpacing = is_widescreen and (_screen.w / (NumHeartsToDraw-1)) or (_screen.w / NumHeartsToDraw)
local WheelHalfItems = math.floor(NumHeartsToDraw/2)

local style = ThemePrefs.Get("VisualStyle")
local colorTable = (style == "SRPG9") and SL.SRPG9.Colors or SL.DecorativeColors
local color_count = #colorTable
local colorIndexMap = {}
for i, c in ipairs(colorTable) do
	colorIndexMap[c] = i
end
local factionBmt
local selectColorTexture = THEME:GetPathG("", "_VisualStyles/"..style.."/SelectColor.png")
local underlay_ref = nil
local change_sound_ref = nil
local start_sound_ref = nil

local text
if style == "Gay" then
	text = { "I'm gay", "we're gay", "proud", "queer" }
end
local text_count = (type(text) == "table") and #text or 0

-- this handles user input
-- need to split declaration and assignment up across two lines
-- so that the reference to "input" in RemoveInputCallback(input)
-- is scoped properly (i.e. so that "input" isn't nil)
local input
input = function(event)
	if not event.PlayerNumber or not event.button then
		return false
	end

	if event.type == "InputEventType_FirstPress" then
		local topscreen = top_screen or SCREENMAN:GetTopScreen()
		if not topscreen then return false end
		local underlay = underlay_ref or topscreen:GetChild("Underlay")
		if not underlay then return false end
		underlay_ref = underlay
		local direction = nil
		if event.GameButton == "MenuRight" then direction = 1 end
		if event.GameButton == "MenuLeft" then direction = -1 end

		if direction ~= nil then
			wheel:scroll_by_amount(direction)
			change_sound_ref = change_sound_ref or underlay:GetChild("change_sound")
			if change_sound_ref then change_sound_ref:play() end
			underlay:playcommand("Preview")
		elseif event.GameButton == "Start" then
			ColorSelected = true
			underlay:playcommand("Finish")

		elseif event.GameButton == "Back" then
			topscreen:RemoveInputCallback(input)
			topscreen:Cancel()
		end
	end

	return false
end


-- the metatable for an item in the wheel
local wheel_item_mt = {
	__index = {
		create_actors = function(self, name)
			self.name=name

			local af = Def.ActorFrame{
				Name=name,
				InitCommand=function(subself)
					self.container = subself
					if style=="Gay" and not HolidayCheer() then
						subself:bob():effectmagnitude(0,0,0):effectclock('bgm'):effectperiod(0.666)
					end
				end,
				OffCommand=function(subself)
					subself:sleep(0.04 * self.index)
					subself:linear(0.2)
					subself:diffusealpha(0)
				end
			}

			af[#af+1] = Def.Sprite{
				Texture=selectColorTexture,
				InitCommand=function(subself)
					self.heart = subself
					subself:diffusealpha(0)
					subself:zoom(0.25)
					if style == "SRPG9" then
						subself:zoom(0.8)
					end
				end,
				OnCommand=function(subself)
					subself:sleep(0.2)
					subself:sleep(0.04 * self.index)
					subself:linear(0.2)
					subself:diffusealpha(1)
				end,
			}

			if style == "Gay" then
				af[#af+1] = Def.BitmapText{
					Font="Common Normal",
					InitCommand=function(subself)
						self.text = subself
						subself:y(-6):diffuse(Color.Black):zoom(1.2)
					end
				}
			end

			return af
		end,

		transform = function(self, item_index, num_items, has_focus)
			self.container:finishtweening()
			self.container:linear(0.2)
			self.index=item_index

			local half_items = (num_items == NumHeartsToDraw) and WheelHalfItems or math.floor(num_items/2)
			local OffsetFromCenter = (item_index - half_items)-1
			local x = HeartsSpacing * OffsetFromCenter
			local z = -1 * math.abs(OffsetFromCenter)
			local zoom = is_widescreen and (z + half_items)/4 or (z + half_items + 1)/4

			if item_index <= 1 or item_index >= num_items then
				self.container:diffusealpha(0)
			else
				self.container:diffusealpha(1)
			end

			self.container:x(x)
			self.container:z(z)
			self.heart:diffuse( color(self.color) )

			if is_widescreen then
				local y = (12 * math.pow(OffsetFromCenter,2)) - 20
				self.container:rotationz( OffsetFromCenter * 15 )
				self.container:zoom( zoom )
				self.container:y( y )

			else
				self.container:y( -20 )
				self.container:zoom( zoom )
			end

			if style=="Gay" and item_index == (is_widescreen and 6 or 4) then
				self.container:effectmagnitude(0,4,0)
			else
				self.container:effectmagnitude(0,0,0)
			end

			if style == "SRPG9" and has_focus then
				local idx = self.color_index % color_count + 1
				factionBmt:settext(SL.SRPG9.GetFactionName(idx))
			end
		end,

		set = function(self, color)
			if not color then return end
			self.color = color
			self.color_index = colorIndexMap[color]
			if not self.color_index then return end
			if style=="Gay" and text_count > 0 then
				self.text:settext(text[(self.color_index - (SL.Global.ActiveColorIndex-(text_count-1))) % text_count + 1])
			end
		end
	}
}

local t = Def.ActorFrame{
	InitCommand=function(self)
		top_screen = SCREENMAN:GetTopScreen()
		wheel:set_info_set(colorTable, SL.Global.ActiveColorIndex - 1)
		self:queuecommand("Capture")
		self:GetChild("ColorWheel"):SetDrawByZPosition(true)
	end,
	OnCommand=function(self)
		if PREFSMAN:GetPreference("MenuTimer") then
			self:queuecommand("Listen")
		end
	end,
	ListenCommand=function(self)
		local topscreen = top_screen or SCREENMAN:GetTopScreen()
		if not topscreen then return end
		local seconds = topscreen:GetChild("Timer"):GetSeconds()
		if seconds <= 0 and not ColorSelected then
			ColorSelected = true
			self:playcommand("Finish")
		else
			self:sleep(0.25)
			self:queuecommand("Listen")
		end
	end,
	CaptureCommand=function(self)
		local topscreen = top_screen or SCREENMAN:GetTopScreen()
		if topscreen then
			top_screen = topscreen
			topscreen:AddInputCallback(input)
		end
	end,
	PreviewCommand=function(self)
		local focused = wheel:get_info_at_focus_pos()
		local new_index = colorIndexMap[focused]
		if not new_index then return end
		new_index = (new_index % color_count) + 1
		if new_index ~= SL.Global.ActiveColorIndex then
			SL.Global.ActiveColorIndex = new_index
			ThemePrefs.Set("SimplyLoveColor", SL.Global.ActiveColorIndex)
			ColorPrefDirty = true
			MESSAGEMAN:Broadcast("ColorSelected")
		end
	end,
	FinishCommand=function(self)
		start_sound_ref = start_sound_ref or self:GetChild("start_sound")
		if start_sound_ref then start_sound_ref:play() end
		local topscreen = top_screen or SCREENMAN:GetTopScreen()
		if topscreen then
			topscreen:RemoveInputCallback(input)
			topscreen:StartTransitioningScreen("SM_GoToNextScreen")
		end
		if ColorPrefDirty then
			ThemePrefs.Save()
			ColorPrefDirty = false
		end
	end,
	OffCommand=function(self)
		underlay_ref = nil
		change_sound_ref = nil
		start_sound_ref = nil
		top_screen = nil
	end,
	wheel:create_actors( "ColorWheel", NumHeartsToDraw, wheel_item_mt, _screen.cx, _screen.cy )
}

if style == "SRPG9" then
	t[#t+1] = Def.BitmapText{
		Font="Common Normal",
		Text=THEME:GetString("SRPG", "SelectFaction"),
		InitCommand=function(self)
			self:xy(_screen.cx, 80)
			self:zoom(1.5)
			self:diffuse(color(SL.SRPG9.TextColor))
			self:shadowlength(0.5)
		end
	}

	t[#t+1] = Def.BitmapText{
		Font="Common Normal",
		Text="",
		InitCommand=function(self)
			factionBmt = self

			self:xy(_screen.cx, _screen.h - 110)
			self:zoom(2.0)
			self:diffuse(color(SL.SRPG9.TextColor))
			self:shadowlength(0.5)
			self:wrapwidthpixels(150)
		end
	}
end

t[#t+1] = LoadActor( THEME:GetPathS("ScreenSelectMaster", "change") )..{ Name="change_sound", IsAction=true, SupportPan=false }
t[#t+1] = LoadActor( THEME:GetPathS("Common", "start") )..{ Name="start_sound", IsAction=true, SupportPan=false }

return t
