local player = ...
local pn = ToEnumShortString(player)

if GAMESTATE:IsCourseMode() then return end

local max_width = 155
local text_zoom = 0.68
local text_color = ThemePrefs.Get("RainbowMode") and not HolidayCheer() and Color.Black or Color.White
local bg_color = ThemePrefs.Get("RainbowMode") and not HolidayCheer() and Color.White or Color.Black

return Def.ActorFrame{
	Def.Quad{
		Name="BreakdownBG",
		InitCommand=function(self)
			self:xy(150, _screen.cy-95):zoomto(10, 10):diffuse(bg_color):diffusealpha(0.68)
			self:vertalign("VertAlign_Bottom")
			if player == PLAYER_1 then
				self:x(self:GetX() * -1):horizalign(left)
			else
				self:horizalign(right)
			end
		end
	},
	LoadFont("Common Normal")..{
		Text="",
		InitCommand=function(self)
			self:maxwidth(max_width / text_zoom):zoom(text_zoom):xy(148, _screen.cy-97)
			self:vertalign("VertAlign_Bottom"):diffuse(text_color):shadowlength(0)
			if player == PLAYER_1 then
				self:x(self:GetX() * -1):horizalign(left)
			else
				self:horizalign(right)
			end
		end,
		OnCommand=function(self)
			local minimization_level = 0
			self:settext(GenerateBreakdownText(pn, minimization_level))

			while self:GetWidth() > (max_width / text_zoom) and minimization_level < 3 do
				minimization_level = minimization_level + 1
				self:settext(GenerateBreakdownText(pn, minimization_level))
			end

			local bg = self:GetParent():GetChild("BreakdownBG")
			if bg then
				bg:SetWidth(math.min(max_width, self:GetWidth() * text_zoom + 12))
				bg:SetHeight(self:GetHeight() * text_zoom + 6)
				bg:zoom(1)
				if player == PLAYER_1 then
					bg:faderight(0.1)
				else
					bg:fadeleft(0.1)
				end
			end
		end,
	}
}
