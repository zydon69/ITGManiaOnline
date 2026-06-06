return Def.ActorFrame{
	Name="PlayerActionMenu",
	InitCommand=function(self) self:visible(false):draworder(500) end,
	Def.Quad{
		InitCommand=function(self)
			self:zoomto(SCREEN_WIDTH, SCREEN_HEIGHT):diffuse(0,0,0,0.72)
		end
	},
	Def.Quad{
		InitCommand=function(self)
			self:zoomto(760, 360):diffuse(0,0,0,0.94)
		end
	},
	LoadFont("Common Bold")..{
		Name="PlayerActionTitle",
			Text="Joueur",
		InitCommand=function(self)
			self:y(-138):zoom(0.8)
		end
	},
	LoadFont("Common Normal")..{
			Text="&MENULEFT;/&MENURIGHT; pour choisir | &START; pour confirmer | &SELECT; pour annuler",
		InitCommand=function(self)
			self:y(-108):zoom(0.5)
		end
	},
	LoadFont("Common Normal")..{
		Name="PlayerActionOptions",
		Text="",
		InitCommand=function(self)
			self:horizalign(left):vertalign(top):xy(-340, -72):zoom(0.7):maxwidth(980)
		end
	},
}
