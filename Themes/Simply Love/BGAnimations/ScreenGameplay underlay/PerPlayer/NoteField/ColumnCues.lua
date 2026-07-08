local player = ...
local pn = ToEnumShortString(player)
local routineShared = IsRoutine and IsRoutine()
local masterPlayer = routineShared and GAMESTATE:GetMasterPlayerNumber() or player
local masterPn = ToEnumShortString(masterPlayer)

local mods = SL[pn].ActiveModifiers
if SL.Global.GameMode == "Casual" then return end
if not mods.ColumnCues then return end
if routineShared and player ~= masterPlayer then return end

local columnMapping = GetColumnMapping(masterPlayer)

-- Disable column cues if we couldn't compute valid columnMapping
if columnMapping == nil then return end

local playerState = GAMESTATE:GetPlayerState(masterPlayer)
local columnCues = SL[masterPn].Streams.ColumnCues

local style = GAMESTATE:GetCurrentStyle(masterPlayer)
local numColumns = style:ColumnsPerPlayer()
local width = style:GetWidth(masterPlayer)
local columnCenters = {}
local columnWidths = {}

local yOffset = 80
local reverseOffset = THEME:GetMetric("Player", "ReceptorArrowsYReverse")
local fadeTime = 0.15
local curIndex = 1
local activeColumnCues = {}

local font = mods.ComboFont
if font == "Wendy" or font == "Wendy (Cursed)" then
	font = "Wendy/_wendy small"
else
	font = "_Combo Fonts/" .. font .. "/"
end

local function GetCueAlpha(curTime, cue)
	local elapsed = curTime - cue.startTime
	local remaining = cue.endTime - curTime
	if elapsed < 0 or remaining <= 0 then return 0 end
	if elapsed < fadeTime then return elapsed / fadeTime end
	if remaining < fadeTime then return remaining / fadeTime end
	return 1
end

local function UpdateColumnCueVisuals(self, curTime)
	for col=1,numColumns do
		local column = self:GetChild("Column"..col)
		local flash = column and column:GetChild("ColumnFlash")
		local countdown = column and column:GetChild("ColumnText")
		local cue = activeColumnCues[col]

		if cue and curTime < cue.endTime then
			local alpha = GetCueAlpha(curTime, cue)
			if flash then
				if cue.isMine then
					flash:diffuse(1, 0, 0, 0.12 * alpha)
				else
					flash:diffuse(0.3, 1, 1, 0.12 * alpha)
				end
			end

			if countdown then
				local remaining = cue.endTime - curTime
				if cue.showCountdown and remaining > 0.5 then
					countdown:settext(round(remaining)):diffuse(Color.White)
				else
					countdown:diffuse(0,0,0,0)
				end
			end
		else
			activeColumnCues[col] = nil
			if flash then flash:diffuse(0,0,0,0) end
			if countdown then countdown:diffuse(0,0,0,0) end
		end
	end
end

local function GetAlignedNotefieldX()
	local baseX = GetBaseNotefieldX and GetBaseNotefieldX(masterPlayer) or GetNotefieldX(masterPlayer)
	local layoutX = GetNotefieldX(masterPlayer)
	local activeMods = SL[masterPn].ActiveModifiers
	local offsetX = (tonumber(activeMods.NoteFieldOffsetX) or 0) * (masterPlayer == PLAYER_1 and -1 or 1)
	return (layoutX or baseX or _screen.cx) + offsetX
end

local function GetFieldZoom()
	local playerOptions = GAMESTATE:GetPlayerState(masterPlayer):GetCurrentPlayerOptions()
	local fallbackMini = (tonumber((tostring(mods.Mini or "0"):gsub("%%", ""))) or 0) / 100
	local mini = nil
	if playerOptions and playerOptions.Mini then
		local ok, value = pcall(function() return playerOptions:Mini() end)
		if ok and tonumber(value) then
			mini = tonumber(value)
		end
	end
	mini = mini or fallbackMini

	return 1 - (mini * 0.5), mini
end

local function Scale(value, inLow, inHigh, outLow, outHigh)
	if inHigh == inLow then return outLow end
	return outLow + ((value - inLow) * (outHigh - outLow) / (inHigh - inLow))
end

local function GetPerspectiveInfo()
	local playerOptions = GAMESTATE:GetPlayerState(masterPlayer):GetCurrentPlayerOptions()
	if not playerOptions then return 0, "Overhead", 0 end

	local function optionValue(name)
		if not playerOptions[name] then return nil end
		local ok, value = pcall(function() return playerOptions[name](playerOptions) end)
		return ok and tonumber(value) or nil
	end

	local hallway = optionValue("Hallway")
	if hallway and hallway > 0 then
		return -hallway, "Hallway", hallway
	end

	local distant = optionValue("Distant")
	if distant and distant > 0 then
		return distant, "Distant", distant
	end

	return 0, "Overhead", 0
end

local function GetEngineDrawZoom(mini, perspectiveTilt)
	local zoom = Scale(mini or 0, 0, 1, 1, 0.5)
	if (perspectiveTilt or 0) > 0 then
		zoom = zoom * Scale(perspectiveTilt, 0, 1, 1, 0.9)
	else
		zoom = zoom * Scale(perspectiveTilt or 0, 0, -1, 1, 0.9)
	end
	return zoom
end

local fieldZoom, miniValue = GetFieldZoom()
local perspectiveTilt, perspectiveMode, perspectiveValue = GetPerspectiveInfo()
local drawZoom = GetEngineDrawZoom(miniValue, perspectiveTilt)

local function RebuildColumnGeometry()
	columnCenters = {}
	columnWidths = {}

	for columnIndex=1,numColumns do
		local center = (columnIndex - (numColumns/2 + 0.5)) * (width/numColumns)
		if style and style.GetColumnInfo then
			local ok, info = pcall(function() return style:GetColumnInfo(masterPlayer, columnIndex) end)
			if ok and info and tonumber(info.XOffset) then
				center = tonumber(info.XOffset)
			end
		end
		columnCenters[columnIndex] = center * drawZoom
	end

	for columnIndex=1,numColumns do
		local prevCenter = columnCenters[columnIndex - 1]
		local nextCenter = columnCenters[columnIndex + 1]
		local defaultWidth = (width / numColumns) * drawZoom
		if prevCenter and nextCenter then
			columnWidths[columnIndex] = (nextCenter - prevCenter) / 2
		elseif nextCenter then
			columnWidths[columnIndex] = nextCenter - columnCenters[columnIndex]
		elseif prevCenter then
			columnWidths[columnIndex] = columnCenters[columnIndex] - prevCenter
		else
			columnWidths[columnIndex] = defaultWidth
		end
	end
end

RebuildColumnGeometry()

local Update = function(self, delta)
	local topScreen = SCREENMAN:GetTopScreen()
	if topScreen and topScreen.IsPaused and topScreen:IsPaused() then return end

	local curTime = playerState:GetSongPosition():GetMusicSecondsVisible()
	if curIndex <= #columnCues then
		local columnCue = columnCues[curIndex]
		local startTime = columnCue.startTime
		local duration = columnCue.duration
		if startTime <= curTime then
			-- Recompute visual state from MusicSecondsVisible every update instead
			-- of using sleep/tween timing. This keeps cues tied to chart time and
			-- prevents TAB haste from accelerating the cue animation.
			if duration > 2 * fadeTime then
				for col_mine in ivalues(columnCue.columns) do
					local col = columnMapping[col_mine.colNum]
					local isMine = col_mine.isMine
					activeColumnCues[col] = {
						startTime=startTime,
						endTime=startTime + duration,
						isMine=isMine,
						showCountdown=duration >= 5,
					}
				end
			end
			curIndex = curIndex + 1
		end
	end

	UpdateColumnCueVisuals(self, curTime)
end

local af = Def.ActorFrame{
	InitCommand=function(self)
		self:xy(GetAlignedNotefieldX(), yOffset)
		self:queuecommand("SetUpdate")
		if type(online_logs_enabled) == "function" and online_logs_enabled() and Trace then
			local geometry = {}
			for columnIndex=1,numColumns do
				geometry[#geometry + 1] = tostring(columnIndex) .. ":"
					.. tostring(round(columnCenters[columnIndex] or 0, 2))
					.. "/"
					.. tostring(round(columnWidths[columnIndex] or 0, 2))
			end
			Trace("ROUTINE_UI ColumnCues init player=" .. tostring(pn)
				.. " source=" .. tostring(masterPn)
				.. " routine_shared=" .. tostring(routineShared == true)
				.. " x=" .. tostring(GetAlignedNotefieldX())
				.. " width=" .. tostring(width)
				.. " columns=" .. tostring(numColumns)
				.. " mini=" .. tostring(miniValue)
				.. " field_zoom=" .. tostring(fieldZoom)
				.. " draw_zoom=" .. tostring(drawZoom)
				.. " perspective=" .. tostring(perspectiveMode)
				.. " perspective_value=" .. tostring(perspectiveValue)
				.. " perspective_tilt=" .. tostring(perspectiveTilt)
				.. " geometry=" .. table.concat(geometry, ","))
		end
	end,
	SetUpdateCommand=function(self)
		self:SetUpdateFunction(Update)
	end,
	CurrentSongChangedMessageCommand=function(self)
		local steps = nil
		if GAMESTATE:IsCourseMode() then
			local songIndex = GAMESTATE:GetCourseSongIndex() + 1
			local trail = GAMESTATE:GetCurrentTrail(masterPlayer):GetTrailEntries()[songIndex]
			steps = trail:GetSteps()
		else
			steps = GAMESTATE:GetCurrentSteps(masterPlayer)
		end

		ParseColumnCues(steps, masterPn)

		playerState = GAMESTATE:GetPlayerState(masterPlayer)
		columnCues = SL[masterPn].Streams.ColumnCues
		curIndex = 1
		activeColumnCues = {}
	end,
	PlayingCommand=function(self)
		curIndex = 1
		activeColumnCues = {}
	end,
}

local IsReversedColumn = function(player, columnIndex)
	local columns = {}
	for i=1, numColumns do
		columns[#columns + 1] = false
	end

	local opts = GAMESTATE:GetPlayerState(masterPlayer):GetCurrentPlayerOptions()
	if opts:Reverse() == 1 then
		for column,val in ipairs(columns) do
			columns[column] = not val
		end
	end

	if opts:Alternate() == 1 then
		for column,val in ipairs(columns) do
			if column % 2 == 0 then
				columns[column] = not val
			end
		end
	end

	if opts:Split() == 1 then
		for column,val in ipairs(columns) do
			if column > numColumns / 2 then
				columns[column] = not val
			end
		end
	end

	if opts:Cross() == 1 then
		local firstChunk = numColumns / 4
		local lastChunk = numColumns - firstChunk
		for column,val in ipairs(columns) do
			if column > firstChunk and column <= lastChunk then
				columns[column] = not val
			end
		end
	end

	return columns[columnIndex]
end

for columnIndex=1,numColumns do
	af[#af+1] = Def.ActorFrame{
		Name="Column"..columnIndex,
		Def.Quad{
			Name="ColumnFlash",
			InitCommand=function(self)
				self:diffuse(0,0,0,0)
					:x(columnCenters[columnIndex])
					:vertalign(top)
					:setsize(columnWidths[columnIndex], _screen.h - yOffset)
					:fadebottom(0.333)

				if IsReversedColumn(player, columnIndex) then
					self:rotationz(180)
					self:y(yOffset * 2 + reverseOffset + (columnWidths[columnIndex] or 0)/2)
				end
			end,
			FlashCommand=function(self, params)
				local clr = params.isMine and color("1,0,0,0.12") or color("0.3,1,1,0.12")
				self:stoptweening():diffuse(clr)
			end
		},
		Def.BitmapText {
			Name="ColumnText",
			Font=font,
			Text="",
			InitCommand=function(self)
				self:zoom(0.5)
					:diffuse(0,0,0,0)
					:horizalign(center)
					:x(columnCenters[columnIndex])
				
				if IsReversedColumn(player, columnIndex) then
					self:y(260)
				else
					self:y(80)
				end
			end,
		}
	}
end

return af
