local player = ...
local info

-- in CourseMode, GetStepsCredit() will return a table of info that
-- has as many entries as there are stepcharts in the course
-- (i.e. potentially a lot) so just show course Scripter or Description
if GAMESTATE:IsCourseMode() then
	local course = GAMESTATE:GetCurrentCourse()
	local scripter = course:GetScripter()
	local descript = course:GetDescription()
	-- prefer scripter, use description if scripter is empty
	info = (scripter ~= "" and scripter) or (descript ~= "" and descript) or ""

else
	info = GetStepsCredit(player)
end

local marquee_index = 0
local max_width = 145
local text_zoom = 0.64
local text_color = ThemePrefs.Get("RainbowMode") and not HolidayCheer() and Color.Black or Color.White
local bg_color = ThemePrefs.Get("RainbowMode") and not HolidayCheer() and Color.White or Color.Black

return Def.ActorFrame{
	Def.Quad{
		Name="StepArtistBG",
		InitCommand=function(self)
			self:xy(115, _screen.cy-42):zoomto(10, 10):diffuse(bg_color):diffusealpha(0.62)
			self:vertalign("VertAlign_Bottom")
			if player == PLAYER_1 then
				self:x(self:GetX() * -1):horizalign(left)
			else
				self:horizalign(right)
			end
		end
	},
	LoadFont("Common Normal")..{
		Name="StepArtistText",
		InitCommand=function(self)
			self:zoom(text_zoom):maxwidth(max_width / text_zoom):xy(112, _screen.cy-44)
			self:vertalign("VertAlign_Bottom"):diffuse(text_color):shadowlength(0)

			if player == PLAYER_1 then
				self:x(self:GetX() * -1):horizalign(left)
			else
				self:horizalign(right)
			end
		end,
		OnCommand=function(self)
			if type(info)=="table" and #info > 0 then
				self:playcommand("Marquee")
			elseif type(info)=="string" and info ~= "" then
				self:settext(info)
				self:playcommand("ResizeBG")
			else
				self:visible(false)
				self:GetParent():GetChild("StepArtistBG"):visible(false)
			end
		end,
		MarqueeCommand=function(self)
			marquee_index = (marquee_index % #info) + 1
			local text = info[marquee_index]

			self:settext(text)
			DiffuseEmojis(self, text)
			self:playcommand("ResizeBG")

			if #info > 1 then
				self:sleep(2):queuecommand("Marquee")
			end
		end,
		ResizeBGCommand=function(self)
			local bg = self:GetParent():GetChild("StepArtistBG")
			if bg then
				bg:SetWidth(math.min(max_width, self:GetWidth() * text_zoom + 12))
				bg:SetHeight(self:GetHeight() * text_zoom + 6)
				if player == PLAYER_1 then
					bg:faderight(0.1)
				else
					bg:fadeleft(0.1)
				end
			end
		end,
		OffCommand=function(self) self:stoptweening() end
	}
}
