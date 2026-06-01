-- after ScreenOptionsService initializes, attempt to set the active OptionRow
-- based on state that might exist in SL.Global.PrevScreenOptionsServiceRow
--
-- this applies to any screens that inherit from ScreenOptionsService, including ScreenOptionsServiceSub

local a = Def.Actor{}
local MPN = GAMESTATE:GetMasterPlayerNumber()

SL.Global = SL.Global or {}
SL.Global.PrevScreenOptionsServiceRow = SL.Global.PrevScreenOptionsServiceRow or {}

a.InitCommand=function(self)
	self:queuecommand("SetActiveOptionRow")
end

-- check if an OptionRow index has been saved for the screen we're currently on.
-- if so, it tells us we've returned here from a sub-screen, and should set the
-- active OptionRow
a.SetActiveOptionRowCommand=function(self)
	local screen = SCREENMAN:GetTopScreen()
	if not screen then return end
	local row_index = SL.Global.PrevScreenOptionsServiceRow[screen:GetName()] or 0
	screen:SetOptionRowIndex(MPN, row_index)
end

-- when leaving this screen, save the index of the active OptionRow
a.OffCommand=function(self)
	local screen = SCREENMAN:GetTopScreen()
	if not screen then return end
	local row_index = screen:GetCurrentRowIndex(MPN)
  -- if we're on the "Exit" row, save the index for this screen's 1st row
  if screen:GetNumRows()-1 == row_index then
    row_index = 0
  end
	SL.Global.PrevScreenOptionsServiceRow[screen:GetName()] = row_index
end

return a
