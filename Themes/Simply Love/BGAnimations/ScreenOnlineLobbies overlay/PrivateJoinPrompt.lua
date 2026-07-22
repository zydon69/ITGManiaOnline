return Def.ActorFrame{
	Name="PrivateJoinPrompt",
	InitCommand=function(self)
		self:visible(false):draworder(1000)
	end,
	Def.Quad{
		InitCommand=function(self)
			self:zoomto(SCREEN_WIDTH, SCREEN_HEIGHT):diffuse(0,0,0,0.72)
		end
	},
	Def.Quad{
		InitCommand=function(self)
			self:zoomto(600, 280):diffuse(0,0,0,0.94)
		end
	},
	LoadFont("Common Bold")..{
		Name="PrivateJoinTitle",
			Text=THEME:GetString("ScreenOnlineLobbies", "PlayerWantsToJoinGeneric"),
		InitCommand=function(self)
			self:y(-104):zoom(0.76)
		end
	},
	LoadFont("Common Normal")..{
		Name="PrivateJoinDetail",
			Text=THEME:GetString("ScreenOnlineLobbies", "PrivateLobby"),
		InitCommand=function(self)
			self:y(-74):zoom(0.56):maxwidth(760)
		end
	},
	LoadFont("Common Normal")..{
			Text=THEME:GetString("ScreenOnlineLobbies", "PrivateJoinHelp"),
		InitCommand=function(self)
			self:y(-48):zoom(0.48):diffuse(0.8,0.8,0.8,1)
		end
	},
	LoadFont("Common Normal")..{
		Name="PrivateJoinOptions",
		Text="",
		InitCommand=function(self)
			self:horizalign(left):vertalign(top):xy(-220, -16):zoom(0.68):maxwidth(680)
		end
	},
}
