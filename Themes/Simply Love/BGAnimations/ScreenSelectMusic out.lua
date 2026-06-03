local function onlineFlowSuppressesPrompt()
	local onlineEnabled = SL and SL.Global and SL.Global.ITGOnline and SL.Global.ITGOnline.Enabled
	return (ITGOnline and ITGOnline.currentRoomId) or onlineEnabled
end

return Def.ActorFrame{
	InitCommand=function(self) self:draworder(200) end,

	Def.Quad{
		InitCommand=function(self) self:diffuse(0,0,0,0):FullScreen():cropbottom(1):fadebottom(0.5) end,
		OffCommand=function(self) self:linear(0.3):cropbottom(-0.5):diffusealpha(1) end
	},

	LoadFont("Common Bold")..{
		Text=THEME:GetString("ScreenSelectMusic", "Press Start for Options"),
		InitCommand=function(self) self:visible(false):Center():zoom(0.75) end,
		ShowPressStartForOptionsCommand=function(self)
			if onlineFlowSuppressesPrompt() then
				self:visible(false)
				return
			end
			self:visible(true)
		end,
		ShowEnteringOptionsCommand=function(self)
			if onlineFlowSuppressesPrompt() then
				self:visible(false)
				return
			end
			self:stoptweening()
				:visible(true)
				:diffusealpha(1)
				:settext(THEME:GetString("ScreenSelectMusic", "Entering Options..."))
				:sleep(1)
		end
	}
}
