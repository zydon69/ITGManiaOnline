local function onlineFlowSuppressesPrompt()
	local onlineEnabled = SL and SL.Global and SL.Global.ITGOnline and SL.Global.ITGOnline.Enabled
	return (ITGOnline and ITGOnline.currentRoomId) or onlineEnabled
end

local function optionsPromptSeconds()
	local seconds = tonumber(THEME:GetMetric("ScreenSelectMusic", "ShowOptionsMessageSeconds")) or 3
	return math.max(0.25, seconds)
end

local segment_count = 24
local radius = 42
local prompt_y = 104

local countdown_segments = Def.ActorFrame{
	Name="CountdownSegments",
	InitCommand=function(self)
		self:xy(_screen.cx, _screen.cy + prompt_y):visible(false)
	end,
	ShowPressStartForOptionsCommand=function(self)
		if onlineFlowSuppressesPrompt() then
			self:visible(false)
			return
		end
		self:stoptweening():visible(true):diffusealpha(1)
		self:playcommand("StartCountdown", {Seconds=optionsPromptSeconds()})
	end,
	ShowEnteringOptionsCommand=function(self)
		self:stoptweening():linear(0.12):diffusealpha(0)
	end,
	HidePressStartForOptionsCommand=function(self)
		self:stoptweening():linear(0.12):diffusealpha(0)
	end,
	CountdownExpiredCommand=function(self)
		self:stoptweening():linear(0.12):diffusealpha(0)
	end,
}

for i=1,segment_count do
	local angle = ((i - 1) / segment_count) * math.pi * 2 - math.pi / 2
	local degrees = ((i - 1) / segment_count) * 360
	countdown_segments[#countdown_segments+1] = Def.Quad{
		InitCommand=function(self)
			self:xy(math.cos(angle) * radius, math.sin(angle) * radius)
				:rotationz(degrees)
				:zoomto(3, 10)
				:diffuse(Color.White)
				:diffusealpha(0)
		end,
		StartCountdownCommand=function(self, params)
			local seconds = tonumber(params and params.Seconds) or 1.5
			local delay = seconds * ((i - 1) / segment_count)
			self:stoptweening()
				:diffuse(GetHexColor(SL.Global.ActiveColorIndex))
				:diffusealpha(0.95)
				:sleep(delay)
				:linear(math.min(0.08, seconds / segment_count))
				:diffusealpha(0.12)
		end,
		EnteringOptionsCommand=function(self)
			self:stoptweening():linear(0.08):diffusealpha(0)
		end,
		CountdownExpiredCommand=function(self)
			self:stoptweening():linear(0.08):diffusealpha(0)
		end
	}
end

return Def.ActorFrame{
	InitCommand=function(self) self:draworder(200) end,

	Def.Quad{
		InitCommand=function(self) self:diffuse(0,0,0,0):FullScreen():cropbottom(1):fadebottom(0.5) end,
		OffCommand=function(self) self:linear(0.3):cropbottom(-0.5):diffusealpha(1) end
	},

	Def.ActorFrame{
		Name="OptionsPromptCountdown",
		InitCommand=function(self)
			self:Center():visible(false)
		end,
		ShowPressStartForOptionsCommand=function(self)
			if onlineFlowSuppressesPrompt() then
				self:visible(false)
				return
			end
			self:stoptweening():visible(true):diffusealpha(1)
			self:playcommand("StartCountdown", {Seconds=optionsPromptSeconds()})
		end,
		ShowEnteringOptionsCommand=function(self)
			if onlineFlowSuppressesPrompt() then
				self:visible(false)
				return
			end
			self:stoptweening():visible(true):diffusealpha(1)
			self:playcommand("EnteringOptions")
		end,
		HidePressStartForOptionsCommand=function(self)
			self:stoptweening():linear(0.12):diffusealpha(0)
		end,

		Def.Quad{
			Name="PromptFill",
			InitCommand=function(self)
				self:y(0):zoomto(500, 54):diffuse(0,0,0,0)
			end,
			StartCountdownCommand=function(self)
				self:stoptweening():diffuse(0,0,0,0)
			end,
			EnteringOptionsCommand=function(self)
				self:stoptweening():linear(0.08):diffusealpha(0)
			end
		},
		Def.Quad{
			Name="PromptBorder",
			InitCommand=function(self)
				self:y(0):zoomto(502, 56):diffuse(Color.White):diffusealpha(0)
			end,
			StartCountdownCommand=function(self)
				self:stoptweening():diffuse(Color.White):diffusealpha(0)
			end,
			EnteringOptionsCommand=function(self)
				self:stoptweening():linear(0.08):diffusealpha(0)
			end
		},

		LoadFont("Common Bold")..{
			Name="PrimaryText",
			Text=THEME:GetString("ScreenSelectMusic", "Press Start for Options"),
			InitCommand=function(self)
				self:y(0):zoom(0.72):diffuse(Color.White):shadowlength(1)
			end,
			StartCountdownCommand=function(self)
				self:stoptweening()
					:settext(THEME:GetString("ScreenSelectMusic", "Press Start for Options"))
					:diffuse(Color.White)
					:diffusealpha(1)
			end,
			CountdownExpiredCommand=function(self)
				self:stoptweening()
					:settext(THEME:GetString("ScreenSelectMusic", "Options Locked"))
					:diffuse(0.75,0.75,0.75,1)
			end,
			EnteringOptionsCommand=function(self)
				self:stoptweening()
					:settext(THEME:GetString("ScreenSelectMusic", "Entering Options..."))
					:diffuse(Color.White)
			end
		},

		LoadFont("Common Normal")..{
			Name="SecondaryText",
			Text="",
			InitCommand=function(self)
				self:visible(false):settext("")
			end,
			StartCountdownCommand=function(self)
				self:stoptweening():visible(false):settext("")
			end,
			CountdownExpiredCommand=function(self)
				self:stoptweening():visible(false):settext("")
			end,
			EnteringOptionsCommand=function(self)
				self:stoptweening():visible(false):settext("")
			end
		},

		Def.Actor{
			Name="CountdownTicker",
			StartCountdownCommand=function(self, params)
				self:stoptweening()
				self.remaining = tonumber(params and params.Seconds) or optionsPromptSeconds()
				self:sleep(self.remaining):queuecommand("TickerExpired")
			end,
			TickerExpiredCommand=function(self)
				local parent = self:GetParent()
				if parent then parent:playcommand("CountdownExpired") end
			end,
			CountdownExpiredCommand=function(self)
				self:stoptweening()
			end,
			EnteringOptionsCommand=function(self)
				self:stoptweening()
			end,
			HidePressStartForOptionsCommand=function(self)
				self:stoptweening()
			end
		},

		CountdownExpiredCommand=function(self)
			self:stoptweening():sleep(0.18):linear(0.22):diffusealpha(0)
		end,
		EnteringOptionsCommand=function(self)
			self:stoptweening():diffusealpha(1):sleep(1)
		end,
	},

	countdown_segments
}
