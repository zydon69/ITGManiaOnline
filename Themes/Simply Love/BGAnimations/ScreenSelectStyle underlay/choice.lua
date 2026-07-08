local args = ...
local choiceName = args[1].name
local frame_x = args[1].x
local frame_y = args[1].y or (_screen.cy + WideScale(0,10))
local pads = args[1].pads
local choice_index = args[2]

-- -----------------------------------------------------------------------

local info_keys = {
	double = "DoubleInfo",
	couple = "CoupleInfo",
	routine = "RoutineInfo",
}

local info_key = info_keys[choiceName]
local info_text = info_key and THEME:GetString("ScreenSelectStyle", info_key) or nil
local bubble_width = SL_WideScale(390, 500)
local bubble_height = 132
local bubble_y = -206
local bubble_text_zoom = 1.04
local bubble_x = 0

if choiceName == "double" then
	bubble_x = SL_WideScale(108, 150)
elseif choiceName == "routine" then
	bubble_x = -SL_WideScale(108, 150)
end

local rounded_rect_vertices = function(width, height, radius, color)
	local w = width / 2
	local h = height / 2
	local r = math.min(radius, w, h)
	local verts = { {{0, 0, 0}, color} }
	local first_perimeter_vert = nil
	local segments = 8
	local corners = {
		{ w-r, -h+r, -90,   0 },
		{ w-r,  h-r,   0,  90 },
		{-w+r,  h-r,  90, 180 },
		{-w+r, -h+r, 180, 270 },
	}

	for corner in ivalues(corners) do
		local cx, cy, start_angle, end_angle = unpack(corner)
		for i=0, segments do
			local t = i / segments
			local angle = math.rad(start_angle + ((end_angle - start_angle) * t))
			local vertex = {{ cx + math.cos(angle) * r, cy + math.sin(angle) * r, 0 }, color}
			if not first_perimeter_vert then first_perimeter_vert = vertex end
			verts[#verts+1] = vertex
		end
	end

	verts[#verts+1] = first_perimeter_vert
	return verts
end

local af = Def.ActorFrame{
	InitCommand=function(self)
		-- I needed a way to keep track of whether each choice (single, versus, double, solo)
		-- was enabled or disabled depending on Premium settings and current coin standings.
		-- We can use aux() to associate arbitrary data with actors in a way that can be
		-- accessed externally without leaking memory. aux() accepts floating point values,
		-- so here I'm using 0 as a stand-in for false and 1 for true.
		self:aux(0)

		self:zoom(0.5):xy( frame_x, frame_y )

		if ThemePrefs.Get("VisualStyle")=="Gay" and not HolidayCheer() then
			self:bob():effectmagnitude(0,0,0):effectclock('bgm'):effectperiod(0.666)
		end
	end,
	GainFocusCommand=function(self)
		self:finishtweening():linear(0.125):zoom(1)
		local bubble = self:GetChild("InfoBubble")
		if bubble then bubble:playcommand("Show") end
		if ThemePrefs.Get("VisualStyle")=="Gay" and not HolidayCheer() then
			self:effectmagnitude(0,4,0)
		end
	end,
	LoseFocusCommand=function(self)
		self:finishtweening():linear(0.125):zoom(0.5):effectmagnitude(0,0,0)
		local bubble = self:GetChild("InfoBubble")
		if bubble then bubble:playcommand("Hide") end
	end,
	EnableCommand=function(self)
		if self:getaux() == 1 then
			self:diffusealpha(1)
		else
			self:diffusealpha(0.25)
		end
	end,
	ChosenCommand=function(self)
		-- if this choice was chosen, fluidly zoom in a tiny amount then zoom to 0
		-- similar to animation from SelectProfile
		self:finishtweening():bouncebegin(0.415):zoom(0)
	end,
	NotChosenCommand=function(self)
		-- if this choice wasn't chosen, fade out
		self:finishtweening():sleep(0.1):smooth(0.2):diffusealpha(0)
	end,

	LoadFont("Common Bold")..{
		Text=THEME:GetString("ScreenSelectStyle", choiceName:gsub("^%l", string.upper)),
		InitCommand=function(self)
			self:shadowlength(1):y(37):zoom(0.5)
		end,
		GainFocusCommand=function(self) if ThemePrefs.Get("VisualStyle")=="Gay" then self:rainbowscroll(true) end end,
		LoseFocusCommand=function(self) if ThemePrefs.Get("VisualStyle")=="Gay" then self:rainbowscroll(false) end end,
	}
}

if info_text then
	af[#af+1] = Def.ActorFrame{
		Name="InfoBubble",
		InitCommand=function(self)
			self:xy(bubble_x, bubble_y):visible(false):diffusealpha(0)
		end,
		ShowCommand=function(self)
			self:stoptweening():visible(true):decelerate(0.12):diffusealpha(1)
		end,
		HideCommand=function(self)
			self:stoptweening():accelerate(0.08):diffusealpha(0):queuecommand("Invisible")
		end,
		InvisibleCommand=function(self)
			self:visible(false)
		end,

		Def.ActorMultiVertex{
			InitCommand=function(self)
				self:SetDrawState({Mode="DrawMode_Fan"})
				local verts = rounded_rect_vertices(bubble_width + 10, bubble_height + 10, (bubble_height + 10) / 2, Color.Black)
				self:SetNumVertices(#verts):SetVertices(verts)
			end
		},
		Def.Quad{
			InitCommand=function(self)
				self:xy(-bubble_x, (bubble_height * 0.5) - 2):zoomto(42, 42):rotationz(45):diffuse(Color.Black)
			end
		},
		Def.Quad{
			InitCommand=function(self)
				self:xy(-bubble_x, (bubble_height * 0.5) - 5):zoomto(30, 30):rotationz(45):diffuse(Color.White)
			end
		},
		Def.ActorMultiVertex{
			InitCommand=function(self)
				self:SetDrawState({Mode="DrawMode_Fan"})
				local verts = rounded_rect_vertices(bubble_width, bubble_height, bubble_height / 2, Color.White)
				self:SetNumVertices(#verts):SetVertices(verts)
			end
		},
		LoadFont("Common Normal")..{
			Text=info_text,
			InitCommand=function(self)
				self:wrapwidthpixels((bubble_width - 44) / bubble_text_zoom):zoom(bubble_text_zoom):diffuse(Color.Black):maxwidth((bubble_width - 36) / bubble_text_zoom)
			end
		}
	}
end

-- draw as many pads as needed for this choice
for i, pad in ipairs(pads) do
	af[#af+1] = LoadActor("./pad.lua", {pad.color, {0.2,0.2,0.2,1}, i, choiceName})..{
		InitCommand=function(self)
			self:x(pad.offset):playcommand("Set")
		end,
	}
end

return af
