local focus_pos = 1
local offset = 0
local num_rows = 5
local data = {}

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
    .. " phase=" .. tostring(row.phase)
    .. " acceptsNewMembers=" .. tostring(row.acceptsNewMembers)
    .. " playerCount=" .. tostring(row.playerCount)
end

local t = Def.ActorFrame{
  InitCommand=function(self)
    self:y(-180)
  end,
  UpdateDataCommand=function(self, params)
    data = params.data
    focus_pos = 1
    offset = 0
    lobby_info_trace("update_data count=" .. tostring(#data)
      .. " first=" .. lobby_row_summary(data[1]))
    if self:GetParent() then
      self:GetParent():playcommand("UpdateIndex", {idx=(#data > 0 and 1 or 0), total=#data})
    end
    self:queuecommand("UpdateSelf")
  end,
  NextLobbyCommand=function(self)
    if focus_pos < num_rows and focus_pos < #data then
      focus_pos = focus_pos + 1
      lobby_info_trace("next_lobby focus=" .. tostring(focus_pos)
        .. " offset=" .. tostring(offset)
        .. lobby_row_summary(data[focus_pos + offset]))
      self:queuecommand("UpdateSelf")
      SOUND:PlayOnce(THEME:GetPathS("ScreenSelectMaster", "change"))
      self:GetParent():playcommand("UpdateIndex", {idx=focus_pos+offset, total=#data})
    elseif focus_pos == num_rows and focus_pos + offset < #data then
      offset = offset + 1
      lobby_info_trace("next_lobby_scroll focus=" .. tostring(focus_pos)
        .. " offset=" .. tostring(offset)
        .. lobby_row_summary(data[focus_pos + offset]))
      self:queuecommand("UpdateSelf")
      SOUND:PlayOnce(THEME:GetPathS("ScreenSelectMaster", "change"))
      self:GetParent():playcommand("UpdateIndex", {idx=focus_pos+offset, total=#data})
    end
  end,
  PrevLobbyCommand=function(self)
    if focus_pos > 1 then
      focus_pos = focus_pos - 1
      lobby_info_trace("prev_lobby focus=" .. tostring(focus_pos)
        .. " offset=" .. tostring(offset)
        .. lobby_row_summary(data[focus_pos + offset]))
      self:queuecommand("UpdateSelf")
      SOUND:PlayOnce(THEME:GetPathS("ScreenSelectMaster", "change"))
      self:GetParent():playcommand("UpdateIndex", {idx=focus_pos+offset, total=#data})
    elseif focus_pos == 1 and focus_pos + offset > 1 then
      offset = offset - 1
      lobby_info_trace("prev_lobby_scroll focus=" .. tostring(focus_pos)
        .. " offset=" .. tostring(offset)
        .. lobby_row_summary(data[focus_pos + offset]))
      self:queuecommand("UpdateSelf")
      SOUND:PlayOnce(THEME:GetPathS("ScreenSelectMaster", "change"))
      self:GetParent():playcommand("UpdateIndex", {idx=focus_pos+offset, total=#data})
    end
  end,
  SelectLobbyCommand=function(self, params)
    local selected = data[focus_pos + offset]
    if not selected then
      lobby_info_trace("select_lobby missing focus=" .. tostring(focus_pos)
        .. " offset=" .. tostring(offset)
        .. " count=" .. tostring(#data))
      SOUND:PlayOnce(THEME:GetPathS("Common", "Cancel"))
      return
    end

	    lobby_info_trace("select_lobby" .. lobby_row_summary(selected)
	      .. " focus=" .. tostring(focus_pos)
	      .. " offset=" .. tostring(offset))
	    MESSAGEMAN:Broadcast("OnlineLobbyJoinSelected", {
	      code = selected.code,
	      phase = selected.phase,
	      acceptsNewMembers = selected.acceptsNewMembers,
	    })
	  end
	}

-- +2 because we want to have two of the actors for padding purposes.
for i=1,num_rows+2 do
  local af = Def.ActorFrame{
    InitCommand=function(self)
      self.idx = i
      if i > num_rows then
        self:diffusealpha(0)
      end
      self:y(60 * i)
    end,
    UpdateSelfCommand=function(self)
      if #data < i or i > num_rows then
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
      self:diffuse(i == focus_pos and Color.Green or Color.White)
    end,
    LoseFocusCommand=function(self)
      self.focus = false
      self:diffuse(Color.White)
    end,
    UpdateSelfCommand=function(self)
      self:diffuse(self.focus and i == focus_pos and Color.Green or Color.White)
    end
  }

  af[#af+1] = Def.Quad{
    InitCommand=function(self)
      self:zoomto(220-2, 50-2):diffuse(Color.Black)
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
      if i + offset <= #data then
        self:settext(data[i + offset].code)
      end
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
      if i + offset <= #data then
        self:settext(data[i + offset].playerCount)
      end
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
      if i + offset <= #data then
        self:settext(data[i + offset].phase or "")
      end
    end
  }

  t[#t+1] = af
end


return t
