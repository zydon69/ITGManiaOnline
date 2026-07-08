-- --------------------------------------------------------
-- static background image

local file = ...
local STYLE_SRPG10 = "SRPG10"

local function Brighten(color, intensity)
	color[1] = math.min(1, color[1] * intensity)
	color[2] = math.min(1, color[2] * intensity)
	color[3] = math.min(1, color[3] * intensity)
	return color
end

local function CurrentStyle()
	return ThemePrefs.Get("VisualStyle")
end

local function AllowBackgroundVideo()
	local arch = HOOKS:GetArchName():lower()
	return ThemePrefs.Get("AllowThemeVideos") and not arch:match("mac")
end

local function Srpg10Trace(message)
	if not Trace then return end
	if not (PREFSMAN and PREFSMAN:GetPreference("LogThemeLuaDiagnostics")) then return end
	Trace("SL_SRPG10_TRACE " .. tostring(message or ""))
end

local function LoadStaticBackground(self)
	if CurrentStyle() ~= STYLE_SRPG10 then
		self:Load(nil)
		return
	end

	local video_allowed = AllowBackgroundVideo()
	if video_allowed then
		self:Load(THEME:GetPathG("", "_VisualStyles/SRPG10/BackgroundVideo.mp4"))
		Srpg10Trace("background using video")
	else
		if ThemePrefs.Get("AllowThemeVideos") and HOOKS:GetArchName():lower():match("mac") then
			Srpg10Trace("background video disabled on macOS; using static background")
		end
		self:Load(THEME:GetPathG("", "_VisualStyles/SRPG10/SharedBackground.png"))
		Srpg10Trace("background using static image")
	end

	self:xy(_screen.cx, _screen.cy)
	    :zoomto(_screen.h * 16 / 9, _screen.h)
		:diffuse(Brighten(GetCurrentColor(true), 3))
end

local af = Def.ActorFrame {
	InitCommand=function(self)
		self:diffusealpha(0)
		self:visible(CurrentStyle() == "SRPG10")
	end,
	OnCommand=function(self)
		self:accelerate(0.8):diffusealpha(1)
	end,
	VisualStyleSelectedMessageCommand=function(self)
		if CurrentStyle() == STYLE_SRPG10 then
			self:visible(true)
		else
			self:visible(false)
		end
	end,
	Def.Sprite {
		Name="Background",
		InitCommand= function(self)
			LoadStaticBackground(self)
			self:visible(CurrentStyle() == STYLE_SRPG10)
		end,
		ColorSelectedMessageCommand=function(self)
			self:diffuse(Brighten(GetCurrentColor(true), 3))
		end,
		VisualStyleSelectedMessageCommand=function(self)
			LoadStaticBackground(self)
		end,
		AllowThemeVideoChangedMessageCommand=function(self)
			LoadStaticBackground(self)
		end,
	},
	Def.Quad{
		InitCommand=function(self)
			self:FullScreen()
			 :diffuse(Color.Black)
			 :diffusealpha(0.5)
		end,
	}
}

return af
