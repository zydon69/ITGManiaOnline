local style = GAMESTATE:GetCurrentStyle()
local style_type = style and style:GetStyleType()
local style_type_name = style_type and ToEnumShortString(style_type) or ""
local is_shared_sides = style_type_name == "TwoPlayersSharedSides"
local w = SL_WideScale(310, 417)
local y = 20
local h = 22

-- Song Completion Meter
return Def.ActorFrame{
	Name="SongMeter",
	InitCommand=function(self)
		self:xy(_screen.cx, y)
		Trace("ROUTINE_LAYOUT SongInfoBar"
			.. " style_type=" .. tostring(style_type_name)
			.. " shared=" .. tostring(is_shared_sides)
			.. " x=" .. tostring(_screen.cx)
			.. " y=" .. tostring(y)
			.. " w=" .. tostring(w)
			.. " h=" .. tostring(h))
	end,

	-- border
	Def.Quad{ InitCommand=function(self) self:zoomto(w, h) end },
	Def.Quad{ InitCommand=function(self) self:zoomto(w-4, h-4):diffuse(0,0,0,1) end },

	Def.SongMeterDisplay{
		StreamWidth=(w-4),
		Stream=Def.Quad({ InitCommand=function(self) self:zoomy(18):diffuse(GetCurrentColor(true)) end })
	},

	-- Song Title
	LoadFont("Common Normal")..{
		Name="SongTitle",
		InitCommand=function(self) self:zoom(0.8):shadowlength(0.6):maxwidth(_screen.w/2.5 - 10) end,
		CurrentSongChangedMessageCommand=function(self)
			local song = GAMESTATE:GetCurrentSong()
			self:settext( song and song:GetDisplayFullTitle() or "" )
		end
	}
}
