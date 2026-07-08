-- Simply Thonk needs render-to-texture, and render-to-texture doesn't work with SM5's D3D implementation
local ThonkAndRTTOkay = function()
	local style = ThemePrefs.Get("VisualStyle")
	if style == "Thonk" and not SupportsRenderToTexture() then
		SM( THEME:GetString("ScreenThemeOptions", "ThonkRequiresRenderToTexture") )
		return false
	end
	return true
end

local InputHandler = function(event)
	if not event then return false end
	if event.type == "InputEventType_FirstPress" and event.GameButton == "Back" then
		 if ThonkAndRTTOkay() and CurrentGameIsSupported() and StepManiaVersionIsSupported() then
			 local top = SCREENMAN:GetTopScreen()
			 if top then top:Cancel() end
			 return true
		 end
	end
	return false
end

local a = Def.Actor{}

a.OnCommand=function(self)
	local top = SCREENMAN:GetTopScreen()
	if top then
		top:AddInputCallback(InputHandler)
	end
end
a.BeginCommand=function(self)
	local style = ThemePrefs.Get("VisualStyle")
	local rainbow = ThemePrefs.Get("RainbowMode")
	-- In case we switched into SRPG10 and had Rainbow Mode enabled, disable it.
	if style == "SRPG10" and rainbow == true then
		ThemePrefs.Set("RainbowMode", false)
	end

	SL.ExWeights["W0"] = 3.5
	
	-- we might have just backed out of ScreenThemeOptions ("Simply Love Options")
	-- in which case we'll want to call ThemePrefs.Save() now
	ThemePrefs.Save()

	-- but, we might have also just backed out of ScreenSelectGame ("System Options")
	-- where we might have just changed the language, in which case the ThemePrefsRows table
	-- needs to update its text to use that language.
	SL_CustomPrefs.Init()

	-- Aside: the engine does not broadcast anything when SM5's language is changed via ConfOption
	--        and the engine does not expose any methods for setting the language directly using Lua.

	-- Broadcast a message for "./BGAnimations/_shared background/" to listen for in case VisualStyle has changed.
	-- This compensates for ThemePrefsRows' current lack of support for ExportOnChange() and SaveSelections().
	Trace(("Simply Love theme options applied VisualStyle=%s RainbowMode=%s Color=%s"):format(
		tostring(ThemePrefs.Get("VisualStyle")),
		tostring(ThemePrefs.Get("RainbowMode")),
		tostring(ThemePrefs.Get("SimplyLoveColor"))
	))
	MESSAGEMAN:Broadcast("VisualStyleSelected")
	MESSAGEMAN:Broadcast("AllowThemeVideoChanged")
end

-- OffCommand() will be called if the player tries to leave the operator menu by choosing an OptionRow
-- it will not be called if the player presses the "Back" MenuButton (typically Esc on a keyboard),
-- so we handle that case using a Lua InputCallback function
a.OffCommand=function(self)
	local top = SCREENMAN:GetTopScreen()
	if top then
		top:RemoveInputCallback(InputHandler)
	end

	if top and top:AllAreOnLastRow() then
		local current_game = GAMESTATE:GetCurrentGame():GetName()
		if not ThonkAndRTTOkay() then
			SCREENMAN:SetNewScreen("ScreenOptionsService")
		end

		if not CurrentGameIsSupported() then
			SM( THEME:GetString("ScreenInit", "UnsupportedGame"):format(current_game) )
			SCREENMAN:SetNewScreen("ScreenSystemOptions")
		end

		if not StepManiaVersionIsSupported() then
			SM( THEME:GetString("ScreenInit", "UnsupportedSMVersion"):format(ProductFamily(), ProductVersion(), MinimumVersionString()) )
			SCREENMAN:SetNewScreen("ScreenSystemOptions")
		end
	end
end

return a
