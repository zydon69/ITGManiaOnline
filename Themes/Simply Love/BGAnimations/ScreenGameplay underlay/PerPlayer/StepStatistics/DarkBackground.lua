local player, header_height, width = unpack(...)

local style = GAMESTATE:GetCurrentStyle():GetName()

local FilterAlpha = BackgroundFilterValues()
local alpha = clamp(FilterAlpha[SL[ToEnumShortString(player)].ActiveModifiers.BackgroundFilter]/100 or 0, 0.25, 0.9)
if style ~= "double" then
	return Def.Quad{
		InitCommand=function(self)
			if Trace then
				Trace("SL_STEP_STATS_DARK_BACKGROUND"
					.. " player=" .. tostring(ToEnumShortString(player))
					.. " style=" .. tostring(style)
					.. " width=" .. tostring(width)
					.. " height=" .. tostring(_screen.h)
					.. " header_height=" .. tostring(header_height)
					.. " local_x=" .. tostring(self:GetX())
					.. " local_y=" .. tostring(-header_height)
					.. " alpha=" .. tostring(alpha)
					.. " screen_w=" .. tostring(_screen.w)
					.. " screen_h=" .. tostring(_screen.h))
			end
			self:diffuse(Color.Black):diffusealpha(alpha):zoomto(width, _screen.h):y(-header_height)
		end
	}
else
	local af = Def.ActorFrame{}
	local xadjust = 0;
	
	-- left side
	af[#af+1] = Def.Quad{
		InitCommand=function(self)
			self:diffuse(0, 0, 0, alpha):setsize(200, _screen.h):x(-GetNotefieldWidth()/2):y(-header_height):halign(1);
		end
	}
	
	-- right side
	af[#af+1] = Def.Quad{
		InitCommand=function(self)
			self:diffuse(0, 0, 0, alpha):setsize(200, _screen.h):x(0 + GetNotefieldWidth()/2):y(-header_height):halign(0);
		end
	}
	
	return af
end
