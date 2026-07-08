local player = ...
local info

-- in CourseMode, GetStepsCredit() will return a table of info that
-- has as many entries as there are stepcharts in the course
-- (i.e. potentially a lot) so just show course Scripter or Description
if GAMESTATE:IsCourseMode() then
	local course = GAMESTATE:GetCurrentCourse()
	if course then
		local scripter = course:GetScripter()
		local descript = course:GetDescription()
		-- prefer scripter, use description if scripter is empty
		info = (scripter ~= "" and scripter) or (descript ~= "" and descript) or ""
	else
		info = ""
	end

else
	info = GetStepsCredit(player)
end

local marquee_index = 0
local max_width = 145
local text_zoom = 0.64
local text_color = ThemePrefs.Get("RainbowMode") and not HolidayCheer() and Color.Black or Color.White

return Def.ActorFrame{
	LoadFont("Common Normal")..{
		Name="StepArtistText",
		InitCommand=function(self)
			self:zoom(text_zoom):maxwidth(max_width / text_zoom):xy(112, _screen.cy-57)
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
				DiffuseEmojis(self, info)
			else
				self:visible(false)
			end
		end,
		MarqueeCommand=function(self)
			marquee_index = (marquee_index % #info) + 1
			local text = info[marquee_index]

			self:settext(text)
			DiffuseEmojis(self, text)

			if #info > 1 then
				self:sleep(2):queuecommand("Marquee")
			end
		end,
		OffCommand=function(self) self:stoptweening() end
	}
}
