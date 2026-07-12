return Def.ActorFrame{
	Name="PackChoiceMenu",
	InitCommand=function(self) self:visible(false):draworder(510) end,
	Def.Quad{
		InitCommand=function(self)
			self:zoomto(SCREEN_WIDTH, SCREEN_HEIGHT):diffuse(0,0,0,0.74)
		end
	},
	Def.Quad{
		InitCommand=function(self)
			self:zoomto(780, 380):diffuse(0,0,0,0.95)
		end
	},
	LoadFont("Common Bold")..{
		Name="PackChoiceTitle",
			Text="Choisir le pack a telecharger",
		InitCommand=function(self)
			self:y(-146):zoom(0.78)
		end
	},
	LoadFont("Common Normal")..{
			Text="&MENULEFT;/&MENURIGHT; pour choisir | &START; pour telecharger | &SELECT; pour annuler",
		InitCommand=function(self)
			self:y(-114):zoom(0.5)
		end
	},
	LoadFont("Common Normal")..{
		Name="PackChoiceOptions",
		Text="",
		InitCommand=function(self)
			self:horizalign(left):vertalign(top):xy(-350, -78):zoom(0.68):maxwidth(1020)
		end
	},
	LoadFont("Common Bold")..{
		Name="PackChoiceKickWarning",
		Text="",
		InitCommand=function(self)
			self:y(154):zoom(0.56):maxwidth(760):diffuse(color("#FFDD55"))
				:strokecolor(Color.Black):visible(false)
		end,
	},
}
