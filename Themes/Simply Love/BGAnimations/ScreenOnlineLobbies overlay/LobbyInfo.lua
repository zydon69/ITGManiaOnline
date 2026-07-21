local focus_pos = 0
local offset = 0
local num_rows = 5
local data = {}
local private_border_color = color("#777777")

local function lobby_info_trace(message)
  if type(online_logs_enabled) == "function" and not online_logs_enabled() then
    return
  end
  if type(online_flow_trace) == "function" then
    online_flow_trace("lobby_info " .. tostring(message or ""))
  end
end

local function lobby_row_summary(row)
  row = type(row) == "table" and row or {}
  return " code=" .. tostring(row.code)
    .. " visibility=" .. tostring(row.visibility)
    .. " phase=" .. tostring(row.phase)
    .. " acceptsNewMembers=" .. tostring(row.acceptsNewMembers)
    .. " playerCount=" .. tostring(row.playerCount)
end

local function is_selectable(row)
  return type(row) == "table" and tostring(row.visibility or "public") ~= "private"
end

local function first_selectable_index()
  for index, row in ipairs(data) do
    if is_selectable(row) then return index end
  end
  return nil
end

local function selected_index()
  if focus_pos < 1 then return nil end
  return focus_pos + offset
end

local function set_selected_index(index)
  if not index or index < 1 or index > #data then
    focus_pos = 0
    offset = 0
    return
  end

  if index <= num_rows then
    focus_pos = index
    offset = 0
  else
    focus_pos = num_rows
    offset = index - num_rows
  end
end

local function adjacent_selectable_index(direction)
  local current = selected_index()
  if not current then return first_selectable_index() end

  local index = current + direction
  while index >= 1 and index <= #data do
    if is_selectable(data[index]) then return index end
    index = index + direction
  end
  return nil
end

local function update_parent_index(self)
  if self:GetParent() then
    self:GetParent():playcommand("UpdateIndex", {idx=selected_index() or 0, total=#data})
  end
end

local t = Def.ActorFrame{
  InitCommand=function(self)
    self:y(-180)
    self.hasSelectableRoom = false
  end,
  UpdateDataCommand=function(self, params)
    data = type(params) == "table" and type(params.data) == "table" and params.data or {}
    set_selected_index(first_selectable_index())
    self.hasSelectableRoom = selected_index() ~= nil
    if self:GetParent() then
      self:GetParent().hasSelectableRoom = self.hasSelectableRoom
    end
    lobby_info_trace("update_data count=" .. tostring(#data)
      .. " selectable=" .. tostring(self.hasSelectableRoom)
      .. " selectedIndex=" .. tostring(selected_index() or 0)
      .. " first=" .. lobby_row_summary(data[1]))
    update_parent_index(self)
    self:queuecommand("UpdateSelf")
  end,
  NextLobbyCommand=function(self)
    local nextIndex = adjacent_selectable_index(1)
    if not nextIndex then return end
    set_selected_index(nextIndex)
    lobby_info_trace("next_lobby selectedIndex=" .. tostring(nextIndex)
      .. " focus=" .. tostring(focus_pos)
      .. " offset=" .. tostring(offset)
      .. lobby_row_summary(data[nextIndex]))
    self:queuecommand("UpdateSelf")
    SOUND:PlayOnce(THEME:GetPathS("ScreenSelectMaster", "change"))
    update_parent_index(self)
  end,
  PrevLobbyCommand=function(self)
    local previousIndex = adjacent_selectable_index(-1)
    if not previousIndex then return end
    set_selected_index(previousIndex)
    lobby_info_trace("prev_lobby selectedIndex=" .. tostring(previousIndex)
      .. " focus=" .. tostring(focus_pos)
      .. " offset=" .. tostring(offset)
      .. lobby_row_summary(data[previousIndex]))
    self:queuecommand("UpdateSelf")
    SOUND:PlayOnce(THEME:GetPathS("ScreenSelectMaster", "change"))
    update_parent_index(self)
  end,
  SelectLobbyCommand=function(self)
    local index = selected_index()
    local selected = index and data[index] or nil
    if not selected or not is_selectable(selected) then
      lobby_info_trace("select_lobby rejected reason="
        .. tostring(selected and "private_room" or "missing_selection")
        .. " selectedIndex=" .. tostring(index or 0)
        .. " count=" .. tostring(#data))
      SOUND:PlayOnce(THEME:GetPathS("Common", "Cancel"))
      return
    end

    lobby_info_trace("select_lobby" .. lobby_row_summary(selected)
      .. " selectedIndex=" .. tostring(index)
      .. " focus=" .. tostring(focus_pos)
      .. " offset=" .. tostring(offset))
    MESSAGEMAN:Broadcast("OnlineLobbyJoinSelected", {
      code = selected.code,
      visibility = selected.visibility,
      phase = selected.phase,
      acceptsNewMembers = selected.acceptsNewMembers,
    })
  end
}

-- Two extra rows preserve the original scrolling padding.
for i=1,num_rows+2 do
  local af = Def.ActorFrame{
    InitCommand=function(self)
      self.idx = i
      if i > num_rows then self:diffusealpha(0) end
      self:y(60 * i)
    end,
    UpdateSelfCommand=function(self)
      if i + offset > #data or i > num_rows then
        self:diffusealpha(0)
      else
        self:diffusealpha(1)
      end
    end
  }

  af[#af+1] = Def.Quad{
    InitCommand=function(self)
      self:zoomto(220, 50):diffuse(Color.White)
      self.focus = false
    end,
    GainFocusCommand=function(self)
      self.focus = true
      self:queuecommand("UpdateSelf")
    end,
    LoseFocusCommand=function(self)
      self.focus = false
      self:queuecommand("UpdateSelf")
    end,
    UpdateSelfCommand=function(self)
      local row = data[i + offset]
      if row and tostring(row.visibility or "public") == "private" then
        self:diffuse(private_border_color)
      elseif self.focus and i == focus_pos then
        self:diffuse(Color.Green)
      else
        self:diffuse(Color.White)
      end
    end
  }

  af[#af+1] = Def.Quad{
    InitCommand=function(self)
      self:zoomto(218, 48):diffuse(Color.Black)
    end
  }

  af[#af+1] = LoadFont("Common Normal")..{
    Text="Code salon",
    InitCommand=function(self)
      self:zoom(0.58):x(-72):y(-10)
    end,
  }

  af[#af+1] = LoadFont("Common Bold")..{
    Text="",
    InitCommand=function(self)
      self:zoom(0.44):x(-72):y(10)
    end,
    UpdateSelfCommand=function(self)
      local row = data[i + offset]
      self:settext(row and row.code or "")
    end
  }

  af[#af+1] = LoadFont("Common Normal")..{
    Text="Joueurs",
    InitCommand=function(self)
      self:zoom(0.58):y(-10)
    end,
  }

  af[#af+1] = LoadFont("Common Bold")..{
    Text="",
    InitCommand=function(self)
      self:zoom(0.44):y(10)
    end,
    UpdateSelfCommand=function(self)
      local row = data[i + offset]
      self:settext(row and row.playerCount or "")
    end
  }

  af[#af+1] = LoadFont("Common Normal")..{
    Text="Phase",
    InitCommand=function(self)
      self:zoom(0.58):x(72):y(-10)
    end,
  }

  af[#af+1] = LoadFont("Common Bold")..{
    Text="",
    InitCommand=function(self)
      self:zoom(0.44):x(72):y(10)
    end,
    UpdateSelfCommand=function(self)
      local row = data[i + offset]
      self:settext(row and row.phase or "")
    end
  }

  t[#t+1] = af
end

return t
