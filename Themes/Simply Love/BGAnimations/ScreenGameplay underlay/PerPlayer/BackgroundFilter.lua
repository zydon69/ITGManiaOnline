local player = ...
local pn = ToEnumShortString(player)
local mods = SL[pn].ActiveModifiers

local function IsSharedSidesSecondaryPlayer()
	local style = GAMESTATE and GAMESTATE.GetCurrentStyle and GAMESTATE:GetCurrentStyle() or nil
	local style_type = style and style.GetStyleType and style:GetStyleType() or nil
	local style_type_name = style_type and ToEnumShortString(style_type) or ""
	if style_type_name ~= "TwoPlayersSharedSides" then return false end

	local master = GAMESTATE.GetMasterPlayerNumber and GAMESTATE:GetMasterPlayerNumber() or nil
	return master ~= nil and player ~= master
end

-- if no BackgroundFilter is necessary, it's safe to bail now
if mods.BackgroundFilter == "Off" then return end
if IsSharedSidesSecondaryPlayer() then return end

local FilterAlpha = BackgroundFilterValues()
return Def.Quad{
	InitCommand=function(self)
		local filter_width = GetNotefieldWidth()
		if IsUsingOnlineGameplayColumns and IsUsingOnlineGameplayColumns() and GetOnlineGameplayPanelWidth then
			filter_width = GetOnlineGameplayPanelWidth("side")
		end

		self:xy(GetNotefieldX(player), _screen.cy )
			:diffuse(Color.Black)
			:diffusealpha( FilterAlpha[mods.BackgroundFilter]/100 or 0 )
			:zoomto( filter_width, _screen.h )
	end,
	OffCommand=function(self) self:queuecommand("ComboFlash") end,
	ComboFlashCommand=function(self)
		local pss = STATSMAN:GetCurStageStats():GetPlayerStageStats(player)
		local FlashColor = nil
		local WorstAcceptableFC = SL.Preferences[SL.Global.GameMode].MinTNSToHideNotes:gsub("TapNoteScore_W", "")

		for i=1, tonumber(WorstAcceptableFC) do
			if pss:FullComboOfScore("TapNoteScore_W"..i) then
				FlashColor = SL.JudgmentColors[SL.Global.GameMode][i]
				break
			end
		end

		if (FlashColor ~= nil) then
			self:accelerate(0.25):diffuse( FlashColor )
				:accelerate(0.5):faderight(1):fadeleft(1)
				:accelerate(0.15):diffusealpha(0)
		end
	end
}
