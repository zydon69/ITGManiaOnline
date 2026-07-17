local af = LoadActor(THEME:GetPathB("ScreenProfileSave", "decorations"))

af[#af+1] = Def.Actor{
	OnCommand=function(self)
		PROFILEMAN:SaveMachineProfile()
	end
}

return af
