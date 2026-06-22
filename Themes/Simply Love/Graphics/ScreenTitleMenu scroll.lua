local index = Var("GameCommand"):GetIndex()
local has_focus = false
local focus_tween_seconds = 0.1

local function GetTextColor()
	if has_focus then
		if ThemePrefs.Get("VisualStyle") == "SRPG9" then
			return GetCurrentColor(true)
		end
		return PlayerColor(PLAYER_2)
	end

	if ThemePrefs.Get("RainbowMode") then
		return Color.White
	end
	if ThemePrefs.Get("VisualStyle") == "SRPG9" then
		return color(SL.SRPG9.TextColor)
	end
	return color("#888888")
end

local t = Def.ActorFrame{}

-- this renders the text of a single choice in the scroller
t[#t+1] = LoadFont("Common Bold")..{
	Name="Choice"..index,
	Text=THEME:GetString( 'ScreenTitleMenu', Var("GameCommand"):GetText() ),

	InitCommand=function(self) self:shadowlength(0.5) end,
	OnCommand=function(self) self:diffusealpha(0):sleep(index*0.075):linear(0.2):diffusealpha(1) end,
	OffCommand=function(self)
		-- if the first TitleMenu choice (Gameplay) was chosen by the player
		-- broadcast using MESSAGEMAN
		if index==0 and has_focus then
			-- actors can hook into this like
			-- TitleMenuToGameplayMessageCommand=function(self) end
			MESSAGEMAN:Broadcast("TitleMenuToGameplay")
		end

		self:sleep(index*0.075):linear(0.18):diffusealpha(0)
	end,
	VisualStyleSelectedMessageCommand=function(self)
		self:playcommand("UpdateColor")
	end,
	UpdateColorCommand=function(self)
		self:diffuse(GetTextColor())
	end,

	GainFocusCommand=function(self)
		has_focus = true
		self:stoptweening():diffusealpha(1):decelerate(focus_tween_seconds):zoom(0.5):diffuse(GetTextColor())
		self:accelerate(0.1):glow(1,1,1,0.5)
		self:decelerate(0.05):glow(1,1,1,0)
	end,
	LoseFocusCommand=function(self)
		has_focus = false
		self:stoptweening():diffusealpha(1):decelerate(focus_tween_seconds):zoom(0.4):diffuse(GetTextColor())
		self:accelerate(0.1):glow(1,1,1,0)
	end
}

return t
