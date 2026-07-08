-- --------------------------------------------------------
-- non-RainbowMode (normal) background

local file = ...

local anim_data = {
	color_add = {-1,0,0,-1,-1,-1,0,0,0,0},
	diffusealpha = {0.05,0.2,0.1,0.1,0.1,0.1,0.1,0.05,0.1,0.1},
	xy = {0,40,80,120,200,280,360,400,480,560},
	texcoordvelocity = {{0.03,0.01},{0.03,0.02},{0.03,0.01},{0.02,0.02},{0.03,0.03},{0.02,0.02},{0.03,0.01},{-0.03,0.01},{0.05,0.03},{0.03,0.04}}
}

local function LoadSharedBackground(sprite, path)
	sprite:Load(nil)
	if path then
		sprite:Load(path)
	end
end

local t = Def.ActorFrame {
	InitCommand=function(self)
		local style = ThemePrefs.Get("VisualStyle")
		self:visible(not ThemePrefs.Get("RainbowMode") and style ~= "SRPG10" and style ~= "Technique")
	end,
	OnCommand=function(self) self:accelerate(0.8):diffusealpha(1) end,
	HideCommand=function(self) self:visible(false) end,

		VisualStyleSelectedMessageCommand=function(self)
			local style = ThemePrefs.Get("VisualStyle")
			Trace(("Simply Love normal background VisualStyleSelected style=%s RainbowMode=%s"):format(
				tostring(style),
				tostring(ThemePrefs.Get("RainbowMode"))
			))

			if ThemePrefs.Get("RainbowMode") or style == "SRPG10" or style == "Technique" then
				self:RunCommandsOnChildren(function(child) LoadSharedBackground(child, nil) end)
				self:linear(0.6):diffusealpha(0):queuecommand("Hide")
			else
				self:visible(true):linear(0.6):diffusealpha(1)

				local new_file = THEME:GetPathG("", "_VisualStyles/" .. style .. "/SharedBackground.png")
				Trace(("Simply Love normal background loading file=%s"):format(tostring(new_file)))
				self:RunCommandsOnChildren(function(child) LoadSharedBackground(child, new_file) end)
			end
		end
}

local function ShouldShowNormal()
	local style = ThemePrefs.Get("VisualStyle")
	return not ThemePrefs.Get("RainbowMode") and style ~= "SRPG10" and style ~= "Technique"
end

for i=1,10 do
	t[#t+1] = Def.Sprite {
		InitCommand=function(self)
			self:diffuse(GetHexColor(SL.Global.ActiveColorIndex+anim_data.color_add[i], true))
		end,
			OnCommand=function(self)
				if ShouldShowNormal() then
					if i == 1 then
						Trace(("Simply Love normal background on style=%s file=%s"):format(tostring(ThemePrefs.Get("VisualStyle")), tostring(file)))
					end
					LoadSharedBackground(self, file)
				end
			self:zoom(1.3):xy(anim_data.xy[i], anim_data.xy[i])
			:customtexturerect(0,0,1,1):texcoordvelocity(anim_data.texcoordvelocity[i][1], anim_data.texcoordvelocity[i][2])
			:diffusealpha(anim_data.diffusealpha[i])
		end,
		ColorSelectedMessageCommand=function(self)
			self:linear(0.5)
			:diffuse(GetHexColor(SL.Global.ActiveColorIndex+anim_data.color_add[i], true))
			:diffusealpha(anim_data.diffusealpha[i])
		end
	}
end

return t
