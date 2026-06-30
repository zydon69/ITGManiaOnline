local Input = function(event)
	-- if any of these, don't attempt to handle input
	if not event or not event.button then return false end

	if event.type == "InputEventType_FirstPress" and event.GameButton == "Start" then
		local topscreen = SCREENMAN and SCREENMAN.GetTopScreen and SCREENMAN:GetTopScreen() or nil
		if topscreen then
			topscreen:SetNextScreenName("ScreenGameOver")
			topscreen:StartTransitioningScreen("SM_GoToNextScreen")
		end
	end
	return false
end

local input_screen = nil

local af = Def.ActorFrame{
	OnCommand=function(self)
		local topscreen = SCREENMAN and SCREENMAN.GetTopScreen and SCREENMAN:GetTopScreen() or nil
		if topscreen and topscreen.AddInputCallback then
			input_screen = topscreen
			topscreen:AddInputCallback(Input)
		end
	end,
	OffCommand=function(self)
		if input_screen and input_screen.RemoveInputCallback then
			pcall(function() input_screen:RemoveInputCallback(Input) end)
		end
		input_screen = nil
	end,

	LoadActor(THEME:GetPathB("ScreenSelectMusicCasual", "overlay/Header.lua"), {h=60} ),

	Def.Quad{
		InitCommand=function(self) self:FullScreen():Center():diffuse(0,0,0,0.6) end
	},

	Def.BitmapText{
		Font="Common Normal",
		Text=ScreenString("NoValidSongs"),
		InitCommand=function(self) self:Center():zoom(1.1):_wrapwidthpixels(320) end
	},
}

return af
