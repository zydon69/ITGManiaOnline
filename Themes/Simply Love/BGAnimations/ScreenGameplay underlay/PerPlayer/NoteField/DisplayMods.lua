local player = ...

if SL.Global.GameMode == "Casual" then return end

local style = GAMESTATE:GetCurrentStyle()
local style_type = style and style:GetStyleType()
local style_type_name = style_type and ToEnumShortString(style_type) or ""
local is_shared_sides = style_type_name == "TwoPlayersSharedSides"
local sourcePlayer = is_shared_sides and PLAYER_1 or player
if is_shared_sides and player ~= sourcePlayer then
  Trace("ROUTINE_LAYOUT DisplayMods skipped_secondary"
    .. " player=" .. tostring(ToEnumShortString(player))
    .. " source=" .. tostring(sourcePlayer and ToEnumShortString(sourcePlayer) or "nil")
    .. " style_type=" .. tostring(style_type_name))
  return
end

local optionslist = GetPlayerOptionsString(player)
local font_zoom = 0.8
local wrap_width = math.max(150, math.min((GetNotefieldWidth and GetNotefieldWidth() or 256) * 0.9, 360))

local af = Def.ActorFrame{
  InitCommand = function(self)
    self:diffusealpha(1):xy(GetNotefieldX(player), SCREEN_HEIGHT/4*1.3)
    Trace("ROUTINE_LAYOUT DisplayMods"
      .. " player=" .. tostring(ToEnumShortString(player))
      .. " style_type=" .. tostring(style_type_name)
      .. " shared=" .. tostring(is_shared_sides)
      .. " source=" .. tostring(sourcePlayer and ToEnumShortString(sourcePlayer) or "nil")
      .. " x=" .. tostring(GetNotefieldX(player))
      .. " y=" .. tostring(SCREEN_HEIGHT/4*1.3)
      .. " wrap_width=" .. tostring(wrap_width)
      .. " text=" .. tostring(optionslist))
  end,
  OnCommand=function(self)
    self:sleep(5):decelerate(0.5):diffusealpha(0)
  end,
  PlayerOptionsChangedMessageCommand=function(self, params)
    if params.Player ~= player then return false end
    self:stoptweening():playcommand("Init"):queuecommand("On")
  end,
}

af[#af+1] = LoadFont("Common Normal")..{
  Text=optionslist,
  InitCommand=function(self)
    self:y(15)
    self:zoom(font_zoom)
    self:align(0.5, 0)
    self:maxwidth(wrap_width / font_zoom)
    self:shadowcolor(Color.Black)
    self:shadowlength(1)
  end,
  PlayerOptionsChangedMessageCommand=function(self, params)
    if params.Player ~= player then return false end
    optionslist = GetPlayerOptionsString(player, "ModsLevel_Song")
    self:settext(optionslist)
    self:maxwidth(wrap_width / font_zoom)
  end
}

return af
