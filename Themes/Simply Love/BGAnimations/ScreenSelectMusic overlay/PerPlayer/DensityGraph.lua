-- Currently the Density Graph in SSM doesn't work for Courses.
-- Disable the functionality.
if GAMESTATE:IsCourseMode() then return end

local player = ...
local pn = ToEnumShortString(player)
local autoStyle = type(IsSelectMusicAutoStyle) == "function" and IsSelectMusicAutoStyle()

-- Height and width of the density graph.
local height = 64
local width = IsUsingWideScreen() and 286 or 276
if autoStyle then
	width = 352
end
local patternInfoWidth = IsUsingWideScreen() and 286 or 276
local patternInfoHeight = height
local patternInfoYOffset = 88

-- In 2-players mode, whether the DensityGraph or PatternInfo is shown
-- Can be toggled by the code "ToggleChartInfo" in metrics.ini
local showPatternInfo = false

local PatternInfoTrace = function(message)
	if not PREFSMAN then return end
	local okContent, logContent = pcall(function()
		return PREFSMAN:GetPreference("LogContentLoadDiagnostics")
	end)
	local okTheme, logTheme = pcall(function()
		return PREFSMAN:GetPreference("LogThemeLuaDiagnostics")
	end)
	if not ((okContent and logContent) or (okTheme and logTheme)) then return end
	Trace("PATTERN_INFO_TRACE " .. tostring(message or ""))
end

local PlayCommandOnChildren = function(parent, command)
	if not parent then return end
	local children = parent:GetChildren()
	if not children then return end
	for _, child in pairs(children) do
		child:playcommand(command)
	end
end

local GetCurrentStyleName = function()
	if not GAMESTATE or not GAMESTATE.GetCurrentStyle then return false end
	local style = GAMESTATE:GetCurrentStyle()
	if not style or not style.GetName then return false end
	return style:GetName()
end

local IsCoupleMode = function()
	return GetCurrentStyleName() == "couple" and GAMESTATE:GetNumSidesJoined() == 2
end

local IsRoutineMode = function()
	return GetCurrentStyleName() == "routine" and GAMESTATE:GetNumSidesJoined() == 2
end

local IsVersusMode = function()
	return GetCurrentStyleName() == "versus" and GAMESTATE:GetNumSidesJoined() == 2
end

local ShouldShowPlayerFrame = function()
	if GAMESTATE:IsHumanPlayer(player) then return true end
	if GAMESTATE.IsSideJoined and GAMESTATE:IsSideJoined(player) then return true end
	return (IsCoupleMode() or IsRoutineMode()) and GAMESTATE:GetNumSidesJoined() == 2
end

local GetCurrentStepsForChartInfo = function()
	local steps = GAMESTATE:GetCurrentSteps(player)
	if steps then return steps, false end

	if IsCoupleMode() or IsRoutineMode() then
		local otherPlayer = player == PLAYER_1 and PLAYER_2 or PLAYER_1
		steps = GAMESTATE:GetCurrentSteps(otherPlayer)
		if steps then return steps, true end
	end

	return nil, false
end

local ShouldUsePatternInfoForSteps = function(steps)
	if IsRoutineMode() then return player == PLAYER_2 end
	if IsCoupleMode() then return true end
	return IsVersusMode()
end

local GetStyleLabelForSteps = function(steps)
	if not steps then return "" end

	local stepsType = ""
	local ok = pcall(function()
		stepsType = ToEnumShortString(steps:GetStepsType()):gsub("_", "-"):lower()
	end)
	if not ok or stepsType == "" then return "" end

	local game, style = stepsType:match("^([^-]+)%-(.+)$")
	style = style or stepsType

	local labels = {
		single = "Single",
		versus = "Versus",
		double = "Double",
		couple = "Couple",
		routine = "Routine",
		solo = "Solo",
		threepanel = "3 Panel",
		halfdouble = "Half Double",
	}

	local label = labels[style] or style:gsub("^%l", string.upper)
	if game and game ~= "dance" then
		label = game:gsub("^%l", string.upper) .. " " .. label
	end

	return "Style: " .. label
end

local ShouldShowPatternInfo = function()
	return GAMESTATE:GetNumSidesJoined() == 1 or showPatternInfo
end

local GetSoloPatternInfoPosition = function()
	local parentX = _screen.cx - (IsUsingWideScreen() and 187 or 182)
	local parentY = _screen.cy + 23
	if player == PLAYER_2 then
		parentY = parentY + height + 24
	end

	return parentX, parentY + patternInfoYOffset * (player == PLAYER_1 and 1 or -1)
end

local GetCurrentPatternInfoParentPosition = function()
	if autoStyle then
		local parentX = IsUsingWideScreen() and _screen.cx - 170 or _screen.cx - 176
		local parentY = _screen.cy + 20
		if player == PLAYER_2 then
			parentY = parentY + height + 11
		end
		return parentX, parentY, 0.91
	end

	local parentX = _screen.cx - 182
	local parentY = _screen.cy + 23
	if player == PLAYER_2 then
		parentY = parentY + height + 24
	end
	if IsUsingWideScreen() then
		parentX = parentX - 5
	end

	return parentX, parentY, 1
end

local PositionPatternInfo = function(actor)
	actor:zoom(1)
	if IsVersusMode() or IsCoupleMode() or IsRoutineMode() then
		actor:xy(0, 0)
		return
	end

	if autoStyle then
		local targetX, targetY = GetSoloPatternInfoPosition()
		local parentX, parentY, parentZoom = GetCurrentPatternInfoParentPosition()
		actor:zoom(1 / parentZoom)
		actor:xy((targetX - parentX) / parentZoom, (targetY - parentY) / parentZoom)
		return
	end

	actor:x(0)
	actor:y(patternInfoYOffset * (player == PLAYER_1 and 1 or -1))
end

local GetPatternInfoContentLeftX = function()
	local contentLeft = -patternInfoWidth/2 + 50
	if not autoStyle then return contentLeft end

	local targetX = GetSoloPatternInfoPosition()
	local parentX, _, parentZoom = GetCurrentPatternInfoParentPosition()
	return (targetX - parentX + contentLeft) / parentZoom
end

local af = Def.ActorFrame{
	InitCommand=function(self)
		self:visible(ShouldShowPlayerFrame())
		self:xy(_screen.cx-182, _screen.cy+23)
		if autoStyle then
			self:xy(IsUsingWideScreen() and _screen.cx-170 or _screen.cx-176, _screen.cy+20):zoom(0.91)
		end

		if player == PLAYER_2 then
			self:addy(autoStyle and height+11 or height+24)
		end

		if IsUsingWideScreen() and not autoStyle then
			self:addx(-5)
		end
	end,
	PlayerJoinedMessageCommand=function(self, params)
		if params.Player == player then
			self:visible(ShouldShowPlayerFrame())
		end
	end,
	PlayerUnjoinedMessageCommand=function(self, params)
		if params.Player == player then
			self:visible(ShouldShowPlayerFrame())
		end
	end,
	PlayerProfileSetMessageCommand=function(self, params)
		if params.Player == player then
			self:queuecommand("Redraw")
		end
	end,
	CodeMessageCommand=function(self, params)
		-- Toggle between the density graph and the pattern info
		if params.Name == "TogglePatternInfo" and params.PlayerNumber == player then
			-- Only need to toggle in versus since in single player modes, both
			-- panes are already displayed.
			if GAMESTATE:GetNumSidesJoined() == 2 then
				showPatternInfo = not showPatternInfo
				local chartParser = self:GetChild("ChartParser")
				if chartParser then
					chartParser:playcommand("TogglePatternInfo")
				end
			end
		end
	end,
}

-- Background quad for the density graph
af[#af+1] = Def.Quad{
	InitCommand=function(self)
		self:diffuse(color("#1e282f")):zoomto(width, height)
		if ThemePrefs.Get("RainbowMode") then
			self:diffusealpha(0.9)
		end
		if ThemePrefs.Get("VisualStyle") == "Technique" then
			self:diffusealpha(0.5)
		end
	end
}

af[#af+1] = Def.ActorFrame{
	Name="ChartParser",
	-- Hide when scrolling through the wheel. This also handles the case of
	-- going from song -> folder. It will get unhidden after a chart is parsed
	-- below.
	CurrentSongChangedMessageCommand=function(self)
		self:playcommand("Hide")
	end,
	HandleCurrentStepsChangedCommand=function(self)
		-- Stop only the pending hash debounce from the previous transient wheel item.
		-- Queueing Show before this would cancel the Show command too.
		self:stoptweening()
		self:playcommand("Hide")
		local steps, usedFallback = GetCurrentStepsForChartInfo()
		if steps then
			showPatternInfo = ShouldUsePatternInfoForSteps(steps)
			local stepsType = ToEnumShortString(steps:GetStepsType()):gsub("_", "-"):lower()
			PatternInfoTrace(("current_steps pn=%s type=%s showPatternInfo=%s sides=%s style=%s fallback=%s"):format(
				tostring(pn),
				tostring(stepsType),
				tostring(showPatternInfo),
				tostring(GAMESTATE:GetNumSidesJoined()),
				tostring(GetCurrentStyleName()),
				tostring(usedFallback)))
			MESSAGEMAN:Broadcast(pn.."ChartParsing")
			ParseChartInfo(steps, pn)
			self:playcommand("Show")
		end

		-- Computing the GrooveStats hash requires parsing the simfile, which is
		-- expensive. Debounce it so wheel scrolling only hashes the chart the
		-- player settles on.
		self:sleep(0.4)
		self:queuecommand("ComputeHash")
	end,
	CurrentStepsP1ChangedMessageCommand=function(self)
		if player == PLAYER_1 or IsCoupleMode() or IsRoutineMode() then
			self:playcommand("HandleCurrentStepsChanged")
		end
	end,
	CurrentStepsP2ChangedMessageCommand=function(self)
		if player == PLAYER_2 or IsCoupleMode() or IsRoutineMode() then
			self:playcommand("HandleCurrentStepsChanged")
		end
	end,
	ComputeHashCommand=function(self)
		local steps = GetCurrentStepsForChartInfo()
		ComputeChartHash(steps, pn)
		MESSAGEMAN:Broadcast(pn.."ChartParsed")
	end,
	HideCommand=function(self)
		PlayCommandOnChildren(self, "Hide")
	end,
	RedrawCommand=function(self)
		PlayCommandOnChildren(self, "Redraw")
	end,
	TogglePatternInfoCommand=function(self)
		PlayCommandOnChildren(self, "TogglePatternInfo")
	end,
	ShowCommand=function(self)
		if GAMESTATE:GetCurrentSong() and
				GetCurrentStepsForChartInfo() then
			PatternInfoTrace(("chart_parser_show pn=%s showPatternInfo=%s sides=%s style=%s"):format(
				tostring(pn),
				tostring(showPatternInfo),
				tostring(GAMESTATE:GetNumSidesJoined()),
				tostring(GetCurrentStyleName())))
			self:playcommand("TogglePatternInfo")
			self:playcommand("Redraw")
		else
			self:playcommand("Hide")
		end
	end
}

local af2 = af[#af]

-- The Density Graph itself. It already has a "RedrawCommand".
af2[#af2+1] = NPS_Histogram(player, width, height)..{
	Name="DensityGraph",
	OnCommand=function(self)
		self:addx(-width/2):addy(height/2)
	end,
	HideCommand=function(self)
		self:visible(false)
	end,
	RedrawCommand=function(self)
		self:visible(not showPatternInfo)
	end,
	TogglePatternInfoCommand=function(self)
		self:visible(not showPatternInfo)
	end
}
-- Don't let the density graph parse the chart.
-- We do this in parent actorframe because we want to "stall" before we parse.
af2[#af2]["CurrentSteps"..pn.."ChangedMessageCommand"] = nil

-- The Peak NPS text
local peakNPSText = THEME:GetString("ScreenGameplay", "PeakNPS")
af2[#af2+1] = LoadFont("Common Normal")..{
	Name="NPS",
	Text=peakNPSText..": ",
	InitCommand=function(self)
		self:horizalign(left):zoom(0.8)
		if player == PLAYER_1 then
			self:addx(60):addy(-41)
		else
			self:addx(-136):addy(-41)
		end
		-- We want black text in Rainbow mode except during HolidayCheer(), white otherwise.
		self:diffuse((ThemePrefs.Get("RainbowMode") and not HolidayCheer()) and {0, 0, 0, 1} or {1, 1, 1, 1})
	end,
	HideCommand=function(self)
		self:settext(peakNPSText..": ")
		self:visible(false)
	end,
	RedrawCommand=function(self)
		if SL[pn].Streams.PeakNPS ~= 0 then
			self:settext((peakNPSText..": %.1f"):format(SL[pn].Streams.PeakNPS * SL.Global.ActiveModifiers.MusicRate))
			self:visible(not showPatternInfo)
		end
	end,
	TogglePatternInfoCommand=function(self)
		self:visible(not showPatternInfo)
	end
}

-- Breakdown
af2[#af2+1] = Def.ActorFrame{
	Name="Breakdown",
	InitCommand=function(self)
		local actorHeight = 17
		self:addy(height/2 - actorHeight/2)
	end,
	HideCommand=function(self)
		self:visible(false)
	end,
	RedrawCommand=function(self)
		self:visible(not showPatternInfo)
		PlayCommandOnChildren(self, "Redraw")
	end,
	TogglePatternInfoCommand=function(self)
		self:visible(not showPatternInfo)
	end,
	Def.Quad{
		InitCommand=function(self)
			local bgHeight = 17
			self:diffuse(color("#000000")):zoomto(width, bgHeight):diffusealpha(0.5)
		end
	},

	LoadFont("Common Normal")..{
		Text="",
		Name="BreakdownText",
		InitCommand=function(self)
			local textZoom = 0.8
			self:maxwidth(width/textZoom):zoom(textZoom)
		end,
		HideCommand=function(self)
			self:settext("")
		end,
		RedrawCommand=function(self)
			local textZoom = 0.8
			self:settext(GenerateBreakdownText(pn, 0))
			local minimization_level = 1
			while self:GetWidth() > (width/textZoom) and minimization_level < 4 do
				self:settext(GenerateBreakdownText(pn, minimization_level))
				minimization_level = minimization_level + 1
			end
		end,
	}
}

af2[#af2+1] = Def.ActorFrame{
	Name="PatternInfo",
	InitCommand=function(self)
		PositionPatternInfo(self)
		self:visible(ShouldShowPatternInfo())
	end,
	PlayerJoinedMessageCommand=function(self, params)
		self:visible(ShouldShowPatternInfo())
		PositionPatternInfo(self)
	end,
	PlayerUnjoinedMessageCommand=function(self, params)
		self:visible(ShouldShowPatternInfo())
		PositionPatternInfo(self)
	end,
	HideCommand=function(self)
		self:visible(false)
		PlayCommandOnChildren(self, "Hide")
	end,
	RedrawCommand=function(self)
		local visible = ShouldShowPatternInfo()
		PositionPatternInfo(self)
		self:visible(visible)
		PatternInfoTrace(("pattern_frame_redraw pn=%s visible=%s showPatternInfo=%s sides=%s"):format(
			tostring(pn),
			tostring(visible),
			tostring(showPatternInfo),
			tostring(GAMESTATE:GetNumSidesJoined())))
		PlayCommandOnChildren(self, "Redraw")
	end,
	TogglePatternInfoCommand=function(self)
		local visible = ShouldShowPatternInfo()
		PositionPatternInfo(self)
		self:visible(visible)
		PatternInfoTrace(("pattern_frame_toggle pn=%s visible=%s showPatternInfo=%s sides=%s"):format(
			tostring(pn),
			tostring(visible),
			tostring(showPatternInfo),
			tostring(GAMESTATE:GetNumSidesJoined())))
	end,

	-- Background for the additional chart info.
	-- Only shown in 1 Player mode
	Def.Quad{
		InitCommand=function(self)
			self:diffuse(color("#1e282f")):zoomto(patternInfoWidth, patternInfoHeight)
			if ThemePrefs.Get("VisualStyle") == "Technique" then
				self:diffusealpha(0.5)
			end
		end,
	}
}

local af3 = af2[#af2]

local layout = {
	{"Crossovers", "Footswitches"},
	{"Sideswitches", "Jacks"},
	{"Brackets", "Total Stream"},
}

local colSpacing = 150
local rowSpacing = 20
local noneText = THEME:GetString("SLPlayerOptions", "None")
local totalStreamKey = "Total Stream"
local unknownText = "N/A"
local fallbackLabels = {
	Crossovers = "Crossovers",
	Footswitches = "Footswitches",
	Sideswitches = "Sideswitches",
	Jacks = "Jacks",
	Brackets = "Brackets",
	["Total Stream"] = THEME:GetString("SLPlayerOptions", "TotalStream"),
}

local GetTechCategoryLabel = function(col)
	local ok, label = pcall(function()
		return THEME:GetString("TechCategory", col)
	end)
	label = ok and label or nil
	if label == nil or label == "" or label == ("TechCategory:" .. col) then
		return fallbackLabels[col] or col
	end
	return label
end

local FormatTechCount = function(value)
	value = tonumber(value)
	if value == nil or value < 0 then
		return unknownText
	end
	return tostring(value)
end

local GetDisplayedTechCount = function(col)
	if IsRoutineMode() and player == PLAYER_2 then
		local p1 = tonumber(SL.P1.Streams[col]) or 0
		local p2 = tonumber(SL.P2.Streams[col]) or 0
		return p1 + p2
	end

	return SL[pn].Streams[col]
end

local GetDisplayedTotalStreamAndBreakMeasures = function()
	if not (IsRoutineMode() and player == PLAYER_2) then
		return GetTotalStreamAndBreakMeasures(pn)
	end

	local combinedNotesPerMeasure = {}
	local p1Notes = SL.P1.Streams.NotesPerMeasure or {}
	local p2Notes = SL.P2.Streams.NotesPerMeasure or {}
	local maxMeasures = math.max(#p1Notes, #p2Notes)
	for i=1, maxMeasures do
		combinedNotesPerMeasure[i] = (tonumber(p1Notes[i]) or 0) + (tonumber(p2Notes[i]) or 0)
	end

	local totalStream, totalBreak = 0, 0
	local segments = GetStreamSequences(combinedNotesPerMeasure, 16)
	for _, segment in ipairs(segments) do
		local segmentSize = segment.streamEnd - segment.streamStart
		if segment.isBreak then
			totalBreak = totalBreak + segmentSize
		else
			totalStream = totalStream + segmentSize
		end
	end

	return totalStream, totalBreak
end

for i, row in ipairs(layout) do
	for j, col in ipairs(row) do
		af3[#af3+1] = LoadFont("Common Normal")..{
			Text=(col ~= totalStreamKey and "0" or noneText).." (0.0%)",
			Name=col .. "Value",
			InitCommand=function(self)
				local textZoom = 0.8
				self:zoom(textZoom):horizalign(right)
				if col == totalStreamKey then
					self:maxwidth(100)
				end
				self:xy(-patternInfoWidth/2 + 40, -height/2 + 13)
				self:addx((j-1)*colSpacing)
				self:addy((i-1)*rowSpacing)
			end,
			HideCommand=function(self)
				if col ~= totalStreamKey then
					self:settext("0")
				else
					self:settext(noneText.." (0.0%)")
				end
			end,
			RedrawCommand=function(self)
				if col ~= totalStreamKey then
					local rawValue = GetDisplayedTechCount(col)
					local text = FormatTechCount(rawValue)
					self:settext(text)
					PatternInfoTrace(("pattern_value pn=%s col=%s raw=%s text=%s"):format(
						tostring(pn),
						tostring(col),
						tostring(rawValue),
						tostring(text)))
				else
					local streamMeasures, breakMeasures = GetDisplayedTotalStreamAndBreakMeasures()
					local totalMeasures = streamMeasures + breakMeasures
					if streamMeasures == 0 then
						self:settext(noneText.." (0.0%)")
					else
						self:settext(string.format("%d/%d (%0.1f%%)", streamMeasures, totalMeasures, streamMeasures/totalMeasures*100))
					end
				end
			end
		}

		af3[#af3+1] = LoadFont("Common Normal")..{
			Text=GetTechCategoryLabel(col),
			Name=col,
			InitCommand=function(self)
				local textZoom = 0.8
				self:maxwidth(patternInfoWidth/textZoom):zoom(textZoom):horizalign(left)
				self:xy(-patternInfoWidth/2 + 50, -height/2 + 13)
				self:addx((j-1)*colSpacing)
				self:addy((i-1)*rowSpacing)
			end,
		}
	end
end

af[#af+1] = LoadFont("Common Normal")..{
	Name="SelectedStyleLabel",
	InitCommand=function(self)
		local textZoom = 0.9
		self:visible(false):zoom(textZoom):diffuse(Color.White):shadowlength(1):horizalign(left)
		self:maxwidth(180 / textZoom)
		self:x(GetPatternInfoContentLeftX())
		self:y(autoStyle and 44 or 45)
	end,
	CurrentSongChangedMessageCommand=function(self) self:queuecommand("Set") end,
	["CurrentSteps"..pn.."ChangedMessageCommand"]=function(self) self:queuecommand("Set") end,
	PlayerJoinedMessageCommand=function(self, params)
		if params.Player == player then
			self:queuecommand("Set")
		end
	end,
	PlayerUnjoinedMessageCommand=function(self, params)
		if params.Player == player then
			self:visible(false)
		end
	end,
	SetCommand=function(self)
		if not autoStyle or not GAMESTATE:IsHumanPlayer(player) or not GAMESTATE:GetCurrentSong() then
			self:settext("")
			self:visible(false)
			return
		end

		local label = GetStyleLabelForSteps(GAMESTATE:GetCurrentSteps(player))
		self:settext(label)
		local steps = GAMESTATE:GetCurrentSteps(player)
		if steps then
			self:diffuse(DifficultyColor(steps:GetDifficulty()))
		else
			self:diffuse(Color.White)
		end
		self:visible(label ~= "")
	end,
}

return af
