local color1 = GetHexColor(SL.Global.ActiveColorIndex-2, true)
local color2 = GetHexColor(SL.Global.ActiveColorIndex-1, true)
local style = ThemePrefs.Get("VisualStyle")

local assets = {}
assets.flycenter = THEME:GetPathG("", "_VisualStyles/".. style .."/TitleMenu flycenter")
assets.flytop    = THEME:GetPathG("", "_VisualStyles/".. style .."/TitleMenu flytop")
assets.flybottom = THEME:GetPathG("", "_VisualStyles/".. style .."/TitleMenu flybottom")

local timing = {}
timing.af_decel = 0.4
timing.af_accel = 0.5
timing.img_accel= 0.8
timing.duration = 1

local source_names = {
	flycenter = "FlySourceCenter",
	flytop = "FlySourceTop",
	flybottom = "FlySourceBottom",
}

local t = Def.ActorFrame{}

local function MakeFlyProxy(source_name, init_fn, off_fn)
	return Def.ActorProxy{
		InitCommand=function(self)
			init_fn(self)
			self:visible(false)
		end,
		OnCommand=function(self)
			local root = self:GetParent()
			while root and root.GetParent and root:GetParent() do
				root = root:GetParent()
			end
			local source = root and root:GetChild(source_name) or nil
			if source then
				self:SetTarget(source)
				self:visible(true)
			end
		end,
		OffCommand=off_fn,
	}
end

local function AddFlySource(name, texture)
	t[#t+1] = Def.Sprite{
		Name=name,
		Texture=texture,
		InitCommand=function(self)
			self:visible(false):diffusealpha(0):zoom(0)
		end
	}
end

-- -----------------------------------------------------------------------
-- override if it's time to get spooky
if IsSpooky() then
	style = "Spooky/ExtraSpooky"
	assets.flycenter = THEME:GetPathG("", "_VisualStyles/Spooky/ExtraSpooky/Bats")
	assets.flytop    = THEME:GetPathG("", "_VisualStyles/Spooky/ExtraSpooky/Bats")
	assets.flybottom = THEME:GetPathG("", "_VisualStyles/Spooky/ExtraSpooky/Bats")

	-- this is broadcast from ./Graphics/ScreenTitleMenu scroll.lua
	-- when the first choice ("Gameplay") is chosen by the player
	t.TitleMenuToGameplayMessageCommand=function(self)
		-- change tween timing values before OffCommands evaluate them
		timing.af_decel = 0.35
		timing.af_accel = 1.15
		timing.img_accel= 1.45
		timing.duration = 2.5
	end
end
-- -----------------------------------------------------------------------

t.OffCommand=function(self)
	self:sleep(timing.duration)
end

AddFlySource(source_names.flycenter, assets.flycenter)
AddFlySource(source_names.flytop, assets.flytop)
AddFlySource(source_names.flybottom, assets.flybottom)

-- centers
t[#t+1] = Def.ActorFrame {
	InitCommand=function(self) self:xy(_screen.cx, _screen.cy+50) end,
	OffCommand=function(self)
		self:decelerate(timing.af_decel):addy(-250)
		    :accelerate(timing.af_accel):addy(20):diffusealpha(0)
	end,

	MakeFlyProxy(source_names.flycenter,
		function(self) self:diffuse(color2):diffusealpha(0):rotationy(180):zoom(0) end,
		function(self)
			self:accelerate(timing.img_accel):addx(50):zoom(1):diffusealpha(0.4)
			    :sleep(0):zoom(0)
		end
	),
	MakeFlyProxy(source_names.flycenter,
		function(self) self:diffuse(color1):diffusealpha(0):zoom(0) end,
		function(self)
			self:accelerate(timing.img_accel):addx(-50):zoom(0.6):diffusealpha(0.6)
			    :sleep(0):zoom(0)
		end
	),
}

t[#t+1] = Def.ActorFrame {
	InitCommand=function(self) self:xy(_screen.cx, _screen.cy+380) end,
	OffCommand=function(self)
		self:decelerate(timing.af_decel):addy(-250)
		    :accelerate(timing.af_accel):addy(80):diffusealpha(0)
	end,

	MakeFlyProxy(source_names.flycenter,
		function(self) self:diffuse(color2):diffusealpha(0):rotationy(180):zoom(0) end,
		function(self)
			self:accelerate(timing.img_accel):addx(50):zoom(0.6):diffusealpha(0.6)
			    :sleep(0):zoom(0)
		end
	),
	MakeFlyProxy(source_names.flycenter,
		function(self) self:diffuse(color1):diffusealpha(0):zoom(0) end,
		function(self)
			self:accelerate(timing.img_accel):addx(-50):zoom(1):diffusealpha(0.4)
			    :sleep(0):zoom(0)
		end
	)
}

-- up 200
t[#t+1] = Def.ActorFrame {
	InitCommand=function(self) self:xy(_screen.cx, _screen.cy+200) end,
	OffCommand=function(self)
		self:decelerate(timing.af_decel):addy(-200)
		    :accelerate(timing.af_accel):addy(100):diffusealpha(0)
	end,

	MakeFlyProxy(source_names.flycenter,
		function(self) self:diffuse(color1):diffusealpha(0):rotationy(180):zoom(0) end,
		function(self)
			self:accelerate(timing.img_accel):addx(-200):zoom(1):diffusealpha(0.6)
			    :sleep(0):zoom(0)
		end
	),
	MakeFlyProxy(source_names.flytop,
		function(self) self:diffuse(color1):diffusealpha(0):zoom(0) end,
		function(self)
			self:accelerate(timing.img_accel):addx(200):zoom(1):diffusealpha(0.4)
			    :sleep(0):zoom(0)
		end
	)
}

--up 250
t[#t+1] = Def.ActorFrame {
	InitCommand=function(self) self:xy(_screen.cx, _screen.cy+200) end,
	OffCommand=function(self)
		self:decelerate(timing.af_decel):addy(-250)
		    :accelerate(timing.af_accel):addy(100):diffusealpha(0)
	end,

	MakeFlyProxy(source_names.flytop,
		function(self) self:diffuse(color2):diffusealpha(0):rotationy(180):zoom(0) end,
		function(self)
			self:accelerate(timing.img_accel):addx(-200):zoom(1.5):diffusealpha(0.3)
			    :sleep(0):zoom(0)
		end
	),
	MakeFlyProxy(source_names.flytop,
		function(self) self:diffuse(color1):diffusealpha(0):rotationy(180):zoom(0) end,
		function(self)
			self:accelerate(timing.img_accel):addx(-200):zoom(0.8):diffusealpha(0.6)
			    :sleep(0):zoom(0)
		end
	),
	MakeFlyProxy(source_names.flytop,
		function(self) self:diffuse(color1):diffusealpha(0):zoom(0) end,
		function(self)
			self:accelerate(timing.img_accel):addx(200):zoom(1.5):diffusealpha(0.2)
			    :sleep(0):zoom(0)
		end
	),
	MakeFlyProxy(source_names.flytop,
		function(self) self:diffuse(color2):diffusealpha(0):zoom(0) end,
		function(self)
			self:accelerate(timing.img_accel):addx(200):zoom(0.8):diffusealpha(0.4)
			    :sleep(0):zoom(0)
		end
	)
}

--up 150, out 280
t[#t+1] = Def.ActorFrame {
	InitCommand=function(self) self:xy(_screen.cx, _screen.cy+200) end,
	OffCommand=function(self)
		self:decelerate(timing.af_decel):addy(-150)
		    :accelerate(timing.af_accel):addy(100):diffusealpha(0)
	end,

	MakeFlyProxy(source_names.flytop,
		function(self) self:diffuse(color1):diffusealpha(0):rotationy(180):zoom(0) end,
		function(self)
			self:accelerate(timing.img_accel):addx(-280):zoom(1.2):diffusealpha(0.6)
			    :sleep(0):zoom(0)
		end
	),
	MakeFlyProxy(source_names.flytop,
		function(self) self:diffuse(color1):diffusealpha(0):zoom(0) end,
		function(self)
			self:accelerate(timing.img_accel):addx(280):zoom(1.2):diffusealpha(0.4)
			    :sleep(0):zoom(0)
		end
	)
}

--up 250, out 280
t[#t+1] = Def.ActorFrame {
	InitCommand=function(self) self:xy(_screen.cx, _screen.cy+200) end,
	OffCommand=function(self)
		self:decelerate(timing.af_decel):addy(-250)
		    :accelerate(timing.af_accel):addy(100):diffusealpha(0)
	end,

	MakeFlyProxy(source_names.flytop,
		function(self) self:diffuse(color1):diffusealpha(0):rotationy(180):zoom(0) end,
		function(self)
			self:accelerate(timing.img_accel):addx(-280):zoom(0.2):diffusealpha(0.3)
			    :sleep(0):zoom(0)
		end
	),
	MakeFlyProxy(source_names.flytop,
		function(self) self:diffuse(color1):diffusealpha(0):zoom(0) end,
		function(self)
			self:accelerate(timing.img_accel):addx(280):zoom(0.2):diffusealpha(0.2)
			    :sleep(0):zoom(0)
		end
	)
}

--up 200
t[#t+1] = Def.ActorFrame {
	InitCommand=function(self) self:xy(_screen.cx, _screen.cy+200) end,
	OffCommand=function(self)
		self:decelerate(timing.af_decel):addy(-200)
		    :accelerate(timing.af_accel):addy(100):diffusealpha(0)
	end,

	MakeFlyProxy(source_names.flybottom,
		function(self) self:diffuse(color1):diffusealpha(0):rotationy(180):zoom(0) end,
		function(self)
			self:accelerate(timing.img_accel):addx(-200):zoom(1):diffusealpha(0.3)
			    :sleep(0):zoom(0)
		end
	),
	MakeFlyProxy(source_names.flybottom,
		function(self) self:diffuse(color1):diffusealpha(0):zoom(0) end,
		function(self)
			self:accelerate(timing.img_accel):addx(200):zoom(1):diffusealpha(0.2)
			    :sleep(0):zoom(0)
		end
	)
}

--up 250
t[#t+1] = Def.ActorFrame {
	InitCommand=function(self) self:xy(_screen.cx, _screen.cy+200) end,
	OffCommand=function(self)
		self:decelerate(timing.af_decel):addy(-250)
		    :accelerate(timing.af_accel):addy(100):diffusealpha(0)
	end,

	MakeFlyProxy(source_names.flybottom,
		function(self) self:diffuse(color2):diffusealpha(0):rotationy(180):zoom(0) end,
		function(self)
			self:accelerate(timing.img_accel):addx(-200):zoom(1.5):diffusealpha(0.6)
			    :sleep(0):zoom(0)
		end
	),
	MakeFlyProxy(source_names.flybottom,
		function(self) self:diffuse(color1):diffusealpha(0):rotationy(180):zoom(0) end,
		function(self)
			self:accelerate(timing.img_accel):addx(-200):zoom(0.8):diffusealpha(0.3)
			    :sleep(0):zoom(0)
		end
	),
	MakeFlyProxy(source_names.flybottom,
		function(self) self:diffuse(color1):diffusealpha(0):zoom(0) end,
		function(self)
			self:accelerate(timing.img_accel):addx(200):zoom(1.5):diffusealpha(0.4)
			    :sleep(0):zoom(0)
		end
	),
	MakeFlyProxy(source_names.flybottom,
		function(self) self:diffuse(color2):diffusealpha(0):zoom(0) end,
		function(self)
			self:accelerate(timing.img_accel):addx(200):zoom(0.8):diffusealpha(0.2)
			    :sleep(0):zoom(0)
		end
	)
}

--up 150, out 280
t[#t+1] = Def.ActorFrame {
	InitCommand=function(self) self:xy(_screen.cx, _screen.cy+200) end,
	OffCommand=function(self)
		self:decelerate(timing.af_decel):addy(-150)
		    :accelerate(timing.af_accel):addy(100):diffusealpha(0)
	end,

	MakeFlyProxy(source_names.flybottom,
		function(self) self:diffuse(color1):diffusealpha(0):rotationy(180):zoom(0) end,
		function(self)
			self:accelerate(timing.img_accel):addx(-280):zoom(1.2):diffusealpha(0.3)
			    :sleep(0):zoom(0)
		end
	),
	MakeFlyProxy(source_names.flybottom,
		function(self) self:diffuse(color1):diffusealpha(0):zoom(0) end,
		function(self)
			self:accelerate(timing.img_accel):addx(280):zoom(1.2):diffusealpha(0.2)
			    :sleep(0):zoom(0)
		end
	)
}

--up 250, out 280
t[#t+1] = Def.ActorFrame {
	InitCommand=function(self) self:xy(_screen.cx, _screen.cy+200) end,
	OffCommand=function(self)
		self:decelerate(timing.af_decel):addy(-250)
		    :accelerate(timing.af_accel):addy(100):diffusealpha(0)
	end,

	MakeFlyProxy(source_names.flybottom,
		function(self) self:diffuse(color1):diffusealpha(0):rotationy(180):zoom(0) end,
		function(self)
			self:accelerate(timing.img_accel):addx(-280):zoom(0.2):diffusealpha(0.3)
				:sleep(0):zoom(0)
		end
	),
	MakeFlyProxy(source_names.flybottom,
		function(self) self:diffuse(color1):diffusealpha(0):zoom(0) end,
		function(self)
			self:accelerate(timing.img_accel):addx(280):zoom(0.2):diffusealpha(0.2)
			    :sleep(0):zoom(0)
		end
	)
}

if IsSpooky() then
	-- sound effect
	t[#t+1] = LoadActor(THEME:GetPathG("", "_VisualStyles/Spooky/ExtraSpooky/spooky.ogg"))..{
		-- only play when the first choice (Gameplay) is chosen
		TitleMenuToGameplayMessageCommand=function(self) self:play() end
	}
end

return t
