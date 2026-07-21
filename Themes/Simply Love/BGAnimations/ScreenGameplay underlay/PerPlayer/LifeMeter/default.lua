local player = ...
local style = GAMESTATE:GetCurrentStyle()
local style_type = style and style:GetStyleType()
local style_type_name = style_type and ToEnumShortString(style_type) or ""
local source_player = style_type_name == "TwoPlayersSharedSides"
	and GAMESTATE:GetMasterPlayerNumber()
	or player
local source_pn = ToEnumShortString(source_player)

if SL[source_pn].ActiveModifiers.HideLifebar then return end

local lifemeter_actor

-- in ITG, we have the choice a "Standard" LifeMeter (at the top of the screen)
-- a "Surround" LifeMeter, which occupies the space behind the arrows,
-- or a "Vertical" LifeMeter, which mimics the sizing and positioning used in ITG2.
if SL.Global.GameMode == "ITG" then
	local lifemeter_type = SL[source_pn].ActiveModifiers.LifeMeterType or CustomOptionRow("LifeMeterType").Choices[1]
	lifemeter_actor = LoadActor(lifemeter_type .. ".lua", player)
end

-- Casual doesn't have a LifeMeter, so in Casual GameMode,
-- lifemeter_actor will be returned as nil
return lifemeter_actor
