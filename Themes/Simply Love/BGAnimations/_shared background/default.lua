-- the best way to spread holiday cheer is singing loud for all to hear
if HolidayCheer() then
	return LoadActor( THEME:GetPathB("", "_shared background/Snow.lua") )
end

local style = ThemePrefs.Get("VisualStyle")

-- use the "VisualStyle" ThemePrefs value to generate a proper filepath to the appropriate
-- SharedBackground texture and pass it to Normal.lua and RainbowMode.lua now as this file
-- is being initialized.

-- if the player chooses a different VisualStyle during runtime, MESSAGEMAN will broadcast
-- "VisualStyleSelected" which we can use in Normal.lua and RainbowMode.lua to Load() the
-- newly-appropriate texture from disk into each Sprite; see also: ./BGAnimations/ScreenOptionsService overlay.lua
local file = THEME:GetPathG("", "_VisualStyles/" .. style .. "/SharedBackground.png")
Trace(("Simply Love shared background init VisualStyle=%s file=%s"):format(tostring(style), tostring(file)))

local af = Def.ActorFrame{}

-- a simple Quad to serve as the backdrop
af[#af+1] = Def.Quad{
	InitCommand=function(self)
		local rainbow = ThemePrefs.Get("RainbowMode")
		self:FullScreen():Center():diffuse(rainbow and Color.White or Color.Black)
	end,
		VisualStyleSelectedMessageCommand=function(self)
			local rainbow = ThemePrefs.Get("RainbowMode")
			SL.Global.ActiveColorIndex = rainbow and 3 or ThemePrefs.Get("SimplyLoveColor")
			Trace(("Simply Love shared background refresh VisualStyle=%s RainbowMode=%s Color=%s"):format(
				tostring(ThemePrefs.Get("VisualStyle")),
				tostring(rainbow),
				tostring(SL.Global.ActiveColorIndex)
			))
			self:linear(1):diffuse(rainbow and Color.White or Color.Black)
		end
	}

af[#af+1] = LoadActor("./Normal.lua", file)
af[#af+1] = LoadActor("./RainbowMode.lua", file)
af[#af+1] = LoadActor("./Static.lua", file)
af[#af+1] = LoadActor("./Technique.lua", file)

return af
