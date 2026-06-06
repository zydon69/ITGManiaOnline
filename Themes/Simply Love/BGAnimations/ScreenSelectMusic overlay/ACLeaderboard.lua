-- ArrowCloud detailed leaderboard overlay, opened from the ScreenSelectMusic SortMenu.
-- Ported as a self-contained Simply Love integration so it does not depend on the
-- full ArrowCloud theme state.

local NumEntries = 12
local RowHeight = 21
local PaneHeight = 330
local BorderWidth = 2
local HeaderColor = color("#2a6099")
local FontName = "Common Normal"
local AC_BASE_URL = "https://api.arrowcloud.dance"
local AC_TIMEOUT = 5

local function getPaneWidth()
	return math.min(820, _screen.w - 96)
end

local function getColumnLayout(width)
	return {
		rankX = -width / 2 + 54,
		nameX = -width / 2 + 78,
		scoreX = width / 2 - 34,
		nameMaxWidth = math.max(100, width - 245),
		scoreMaxWidth = 118,
	}
end

local function getCombinedColumnLayout(width)
	local left = -width / 2
	local right = width / 2
	local rankWidth = 64
	local nameWidth = math.max(170, width * 0.36)
	local scoreWidth = math.max(90, (width - rankWidth - nameWidth - 60) / 3)
	return {
		rankX = left + 48,
		nameX = left + rankWidth + 24,
		score1X = right - scoreWidth * 3 + 20,
		score2X = right - scoreWidth * 2 + 10,
		score3X = right - scoreWidth + 0,
		nameMaxWidth = nameWidth,
		scoreMaxWidth = scoreWidth - 14,
	}
end

local function normalizeBoardType(typeLabel)
	local key = tostring(typeLabel or ""):lower():gsub("[^a-z0-9]", "")
	if key == "hex" or key == "hardex" or (key:find("hard", 1, true) and key:find("ex", 1, true)) then
		return "H.EX"
	end
	if key == "ex" then return "EX" end
	return "ITG"
end

local function boardSortKey(board)
	local t = normalizeBoardType(board and board.TypeLabel)
	if t == "ITG" then return 1 end
	if t == "EX" then return 2 end
	return 3
end

local function getScoreColumnIndex(board)
	local t = normalizeBoardType(board and board.TypeLabel)
	if t == "H.EX" then return 1 end
	if t == "EX" then return 2 end
	return 3
end

local function normalizePlayerName(name)
	return tostring(name or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
end

local function isPrimaryLeaderboardPane(player)
	if GAMESTATE:IsSideJoined(PLAYER_1) then
		return player == PLAYER_1
	end
	return player == PLAYER_2
end

local function isArrowCloudEnabled()
	return ThemePrefs and ThemePrefs.Get and ThemePrefs.Get("EnableArrowCloud") == true
end

local function ensureArrowCloudRuntime()
	SL.ArrowCloud = SL.ArrowCloud or {}
	SL.ArrowCloud.Enabled = isArrowCloudEnabled()
	SL.ArrowCloud.BaseURL = SL.ArrowCloud.BaseURL or AC_BASE_URL
	SL.ArrowCloud.RequestTimeout = SL.ArrowCloud.RequestTimeout or AC_TIMEOUT
end

local function readArrowCloudApiKey(player)
	local pn = ToEnumShortString(player)
	if SL[pn] and SL[pn].ArrowCloudApiKey and #SL[pn].ArrowCloudApiKey > 0 then
		return SL[pn].ArrowCloudApiKey
	end

	if not PROFILEMAN:IsPersistentProfile(player) then return "" end
	local profileDir = PROFILEMAN:GetProfileDir(ProfileSlot[PlayerNumber:Reverse()[player] + 1])
	if not profileDir or profileDir == "" then return "" end

	local path = profileDir .. "ArrowCloud.ini"
	if not FILEMAN:DoesFileExist(path) then return "" end

	local contents = IniFile.ReadFile(path) or {}
	local apiKey = contents["ArrowCloud"] and contents["ArrowCloud"]["ApiKey"] or ""
	if apiKey and #apiKey > 0 then
		SL[pn].ArrowCloudApiKey = apiKey
		return apiKey
	end

	return ""
end

local function getSelectedChartHash()
	for player in ivalues(GAMESTATE:GetHumanPlayers()) do
		local pn = ToEnumShortString(player)
		if SL[pn] and SL[pn].Streams and SL[pn].Streams.Hash and #SL[pn].Streams.Hash > 0 then
			return SL[pn].Streams.Hash
		end
	end
	return ""
end

local function getFirstApiKey()
	for player in ivalues(GAMESTATE:GetHumanPlayers()) do
		local apiKey = readArrowCloudApiKey(player)
		if apiKey and #apiKey > 0 then return apiKey end
	end
	return ""
end

local function getLeaderboardTypeColor(typeLabel)
	if not typeLabel then return Color.White end
	local label = typeLabel:upper()
	if label == "HARDEX" or label == "H.EX" then
		return color("#ff00cc")
	elseif label == "EX" then
		local c = SL and SL.JudgmentColors and SL.JudgmentColors["ITG"] and SL.JudgmentColors["ITG"][1]
		return c or color("#21CCE8")
	end
	return Color.White
end

local function setEntryText(row, rank, name, score, date)
	if not row then return end
	row:GetChild("Rank"):settext(rank or "")
	row:GetChild("Name"):settext(name or "")
	row:GetChild("Score"):settext(score or "")
	row:GetChild("Date"):settext(date or "")
end

local function clearLeaderboard(leaderboard, message)
	if not leaderboard then return end
	leaderboard:GetChild("Header"):settext("Arrow Cloud")
	local typeBadge = leaderboard:GetChild("TypeBadge")
	if typeBadge then typeBadge:visible(false):settext("") end
	leaderboard:GetChild("Self"):visible(false)
	for i = 1, 3 do leaderboard:GetChild("Rival" .. i):visible(false) end
	local paneIcons = leaderboard:GetChild("PaneIcons")
	if paneIcons then paneIcons:visible(false) end
	local combinedHeader = leaderboard:GetChild("CombinedHeader")
	if combinedHeader then combinedHeader:visible(false) end

	for i = 1, NumEntries do
		local row = leaderboard:GetChild("LeaderboardEntry" .. i)
		setEntryText(row, "", i == 1 and message or "", "", "")
		for col = 1, 3 do
			local cell = row:GetChild("Board" .. col)
			if cell then cell:settext(""):visible(false) end
		end
	end
end

local function setLeaderboardForPlayer(leaderboard, leaderboardData)
	if not leaderboard or not leaderboardData then return end

	local combinedHeader = leaderboard:GetChild("CombinedHeader")
	if combinedHeader then combinedHeader:visible(false) end
	leaderboard:GetChild("Self"):visible(false)
	for i = 1, 3 do leaderboard:GetChild("Rival" .. i):visible(false) end

	leaderboard:GetChild("Header"):settext(leaderboardData.Name or "Arrow Cloud")

	local typeBadge = leaderboard:GetChild("TypeBadge")
	if typeBadge then
		if leaderboardData.TypeLabel and leaderboardData.TypeLabel ~= "" then
			typeBadge:settext(leaderboardData.TypeLabel):visible(true)
		else
			typeBadge:visible(false):settext("")
		end
	end

	local scoreColor = getLeaderboardTypeColor(leaderboardData.TypeLabel)
	local rivalNum = 1
	local rows = leaderboardData.Data or {}
	local hasMultipleBoards = leaderboardData.HasMultipleBoards == true
	for i = 1, NumEntries do
		local row = leaderboard:GetChild("LeaderboardEntry" .. i)
		local entry = rows[i]
		for col = 1, 3 do
			local cell = row:GetChild("Board" .. col)
			if cell then cell:settext(""):visible(false) end
		end
		row:GetChild("Name"):visible(true)
		row:GetChild("Score"):visible(true)
		if entry then
			setEntryText(row, entry.rank and (tostring(entry.rank) .. ".") or "", entry.name or "", entry.score or "", entry.date or "")

			if entry.isSelf then
				row:GetChild("Rank"):diffuse(Color.Black)
				row:GetChild("Name"):diffuse(Color.Black)
				row:GetChild("Score"):diffuse(Color.Black)
				row:GetChild("Date"):diffuse(Color.Black)
				leaderboard:GetChild("Self"):y(row:GetY()):visible(true)
			elseif entry.isRival and rivalNum <= 3 then
				row:GetChild("Rank"):diffuse(Color.Black)
				row:GetChild("Name"):diffuse(Color.Black)
				row:GetChild("Score"):diffuse(Color.Black)
				row:GetChild("Date"):diffuse(Color.Black)
				leaderboard:GetChild("Rival" .. rivalNum):y(row:GetY()):visible(true)
				rivalNum = rivalNum + 1
			else
				row:GetChild("Rank"):diffuse(Color.White)
				row:GetChild("Name"):diffuse(Color.White)
				row:GetChild("Score"):diffuse(scoreColor)
				row:GetChild("Date"):diffuse(Color.White)
			end
		else
			setEntryText(row, "", i == 1 and "No Scores" or "", "", "")
			row:GetChild("Rank"):diffuse(Color.White)
			row:GetChild("Name"):diffuse(Color.White)
			row:GetChild("Score"):diffuse(Color.White)
			row:GetChild("Date"):diffuse(Color.White)
		end
	end

	local paneIcons = leaderboard:GetChild("PaneIcons")
	if paneIcons then paneIcons:visible(hasMultipleBoards) end
end

local function setCombinedLeaderboards(leaderboard, leaderboards)
	if not leaderboard or not leaderboards then return end

	table.sort(leaderboards, function(a, b) return boardSortKey(a) < boardSortKey(b) end)

	leaderboard:GetChild("Header"):settext("Arrow Cloud")
	local typeBadge = leaderboard:GetChild("TypeBadge")
	if typeBadge then typeBadge:visible(false):settext("") end
	leaderboard:GetChild("Self"):visible(false)
	for i = 1, 3 do leaderboard:GetChild("Rival" .. i):visible(false) end

	local combinedHeader = leaderboard:GetChild("CombinedHeader")
	if combinedHeader then
		combinedHeader:visible(true)
		combinedHeader:GetChild("Position"):settext("#")
		combinedHeader:GetChild("PlayerName"):settext("Nom du joueur")
		combinedHeader:GetChild("Score1"):settext("HardEX"):diffuse(getLeaderboardTypeColor("H.EX"))
		combinedHeader:GetChild("Score2"):settext("EX"):diffuse(getLeaderboardTypeColor("EX"))
		combinedHeader:GetChild("Score3"):settext("ITG"):diffuse(getLeaderboardTypeColor("ITG"))
	end

	local paneIcons = leaderboard:GetChild("PaneIcons")
	if paneIcons then paneIcons:visible(false) end

	local combinedRowsByName = {}
	local combinedRows = {}
	for _, board in ipairs(leaderboards) do
		local scoreIndex = getScoreColumnIndex(board)
		for _, entry in ipairs(board.Data or {}) do
			local key = normalizePlayerName(entry.name)
			if key ~= "" then
				local row = combinedRowsByName[key]
				if not row then
					row = {
						name = entry.name or "--",
						bestRank = tonumber(entry.rank) or 999999,
						scores = { "", "", "" },
						isSelf = false,
						isRival = false,
					}
					combinedRowsByName[key] = row
					combinedRows[#combinedRows + 1] = row
				end

				row.bestRank = math.min(row.bestRank, tonumber(entry.rank) or 999999)
				row.scores[scoreIndex] = entry.score or ""
				row.isSelf = row.isSelf or entry.isSelf
				row.isRival = row.isRival or entry.isRival
			end
		end
	end

	table.sort(combinedRows, function(a, b)
		if a.bestRank == b.bestRank then return tostring(a.name) < tostring(b.name) end
		return a.bestRank < b.bestRank
	end)

	for i = 1, NumEntries do
		local row = leaderboard:GetChild("LeaderboardEntry" .. i)
		local entry = combinedRows[i]
		local layout = getCombinedColumnLayout(leaderboard:GetWidth())
		setEntryText(row, entry and tostring(i) .. "." or "", entry and entry.name or (i == 1 and "No Scores" or ""), "", "")
		row:GetChild("Rank"):x(layout.rankX):maxwidth(40):diffuse(Color.White)
		row:GetChild("Name"):x(layout.nameX):maxwidth(layout.nameMaxWidth):visible(true):diffuse(Color.White)
		row:GetChild("Score"):visible(false)
		row:GetChild("Date"):visible(false)

		for col = 1, 3 do
			local cell = row:GetChild("Board" .. col)
			if cell then
				if entry then
					local label = entry.scores[col] or ""
					cell:settext(label):diffuse(getLeaderboardTypeColor(({ "H.EX", "EX", "ITG" })[col])):visible(true)
				else
					cell:settext(""):visible(true)
				end
			end
		end

		if entry and entry.isSelf then
			row:GetChild("Rank"):diffuse(Color.Black)
			row:GetChild("Name"):diffuse(Color.Black)
			for col = 1, 3 do row:GetChild("Board" .. col):diffuse(Color.Black) end
			leaderboard:GetChild("Self"):y(row:GetY()):visible(true)
		elseif entry and entry.isRival then
			row:GetChild("Rank"):diffuse(Color.Black)
			row:GetChild("Name"):diffuse(Color.Black)
			for col = 1, 3 do row:GetChild("Board" .. col):diffuse(Color.Black) end
		end
	end
end

local function buildLeaderboardList(responseBody)
	local ok, parsed = pcall(JsonDecode, responseBody or "")
	if not ok or type(parsed) ~= "table" or type(parsed.leaderboards) ~= "table" then
		return nil
	end

	local result = {}
	for _, board in ipairs(parsed.leaderboards) do
		local entries = {}
		if type(board.scores) == "table" then
			for _, score in ipairs(board.scores) do
				if score and (score.rank or score.alias or score.userAlias or score.score) then
					entries[#entries + 1] = {
						rank = score.rank,
						name = score.alias or score.userAlias or "--",
						score = tostring(score.score or ""),
						date = score.date or score.createdAt or "",
						isSelf = not not score.isSelf,
						isRival = not not score.isRival,
					}
				end
			end
		end

		result[#result + 1] = {
			Name = "Arrow Cloud",
			TypeLabel = board.type or "Unknown",
			Data = entries,
		}
	end

	return result
end

local function applyLeaderboards(master, leaderboards)
	for player in ivalues(PlayerNumber) do
		local pn = ToEnumShortString(player)
		local leaderboard = master:GetChild(pn .. "ACLeaderboard")
		if not GAMESTATE:IsSideJoined(player) then
			clearLeaderboard(leaderboard, "")
		elseif not leaderboards or #leaderboards == 0 then
			clearLeaderboard(leaderboard, "No Scores")
		else
			master[pn].Leaderboards = DeepCopy(leaderboards)
			master[pn].LeaderboardIndex = 1
			for _, board in ipairs(master[pn].Leaderboards) do
				board.HasMultipleBoards = #leaderboards > 1
			end
			local paneIcons = leaderboard:GetChild("PaneIcons")
			if paneIcons then paneIcons:visible(#leaderboards > 1) end
			if #master[pn].Leaderboards > 1 then
				setCombinedLeaderboards(leaderboard, master[pn].Leaderboards)
			else
				setLeaderboardForPlayer(leaderboard, master[pn].Leaderboards[1])
			end
		end
	end
end

local function showRequestUnavailable(master, message)
	for player in ivalues(PlayerNumber) do
		clearLeaderboard(master:GetChild(ToEnumShortString(player) .. "ACLeaderboard"), message)
	end
end

local af = Def.ActorFrame{
	Name = "ACLeaderboardMaster",
	InitCommand = function(self) self:visible(false) end,
	ShowACLeaderboardCommand = function(self)
		ensureArrowCloudRuntime()
		self:visible(true)
		for player in ivalues(PlayerNumber) do
			local pn = ToEnumShortString(player)
			self[pn] = { Leaderboards = {}, LeaderboardIndex = 0 }
		end
		MESSAGEMAN:Broadcast("ACResetEntry")
		self:queuecommand("SendACLeaderboardRequest")
	end,
	HideACLeaderboardCommand = function(self) self:visible(false) end,
	ACLeaderboardResponseMessageCommand = function(self, params)
		local response = params and params.response
		local expectedHash = params and params.expectedHash
		if expectedHash ~= nil and expectedHash ~= "" and expectedHash ~= getSelectedChartHash() then
			showRequestUnavailable(self, "Chart Changed")
			return
		end

		if not response or response.statusCode ~= 200 then
			showRequestUnavailable(self, response and response.statusCode == 0 and "Offline" or "Failed to Load")
			return
		end

		local leaderboards = buildLeaderboardList(response.body)
		if not leaderboards then
			showRequestUnavailable(self, "Failed to Load")
			return
		end

		applyLeaderboards(self, leaderboards)
	end,
	ACLeaderboardInputEventMessageCommand = function(self, event)
		if not (event and event.PlayerNumber) then return end
		local pn = ToEnumShortString(event.PlayerNumber)
		if not self[pn] or #self[pn].Leaderboards == 0 then return end
		if #self[pn].Leaderboards <= 1 then return end
		if event.type ~= "InputEventType_FirstPress" then return end

		if event.GameButton == "MenuLeft" then
			self[pn].LeaderboardIndex = self[pn].LeaderboardIndex - 1
			if self[pn].LeaderboardIndex < 1 then self[pn].LeaderboardIndex = #self[pn].Leaderboards end
		elseif event.GameButton == "MenuRight" then
			self[pn].LeaderboardIndex = self[pn].LeaderboardIndex + 1
			if self[pn].LeaderboardIndex > #self[pn].Leaderboards then self[pn].LeaderboardIndex = 1 end
		else
			return
		end

		setLeaderboardForPlayer(
			self:GetChild(pn .. "ACLeaderboard"),
			self[pn].Leaderboards[self[pn].LeaderboardIndex]
		)
	end,

	Def.Quad{ InitCommand = function(self) self:FullScreen():diffuse(0, 0, 0, 0.875) end },

	LoadFont(FontName)..{
		Text = THEME:GetString("Common", "PopupDismissText"),
		InitCommand = function(self) self:xy(_screen.cx, _screen.h - 50):zoom(1.1) end
	},

	Def.Actor{
		SendACLeaderboardRequestCommand = function(self)
			local master = self:GetParent()
			ensureArrowCloudRuntime()

			if not (SL.ArrowCloud and SL.ArrowCloud.Enabled) then
				showRequestUnavailable(master, "Arrow Cloud Disabled")
				return
			end

			local hash = getSelectedChartHash()
			if hash == "" then
				showRequestUnavailable(master, "No Chart Selected")
				return
			end

			local apiKey = getFirstApiKey()
			if apiKey == "" then
				showRequestUnavailable(master, "No API Key")
				return
			end

			showRequestUnavailable(master, "Loading ...")

			NETWORK:HttpRequest{
				url = SL.ArrowCloud.BaseURL .. "/v1/chart/" .. hash .. "/leaderboards?limit=" .. tostring(NumEntries),
				method = "GET",
				headers = { Authorization = "Bearer " .. apiKey },
					connectTimeout = SL.ArrowCloud.RequestTimeout or AC_TIMEOUT,
					transferTimeout = SL.ArrowCloud.RequestTimeout or AC_TIMEOUT,
					onResponse = function(response)
						MESSAGEMAN:Broadcast("ACLeaderboardResponse", { response = response, expectedHash = hash })
					end,
				}
			end
	}
}

for player in ivalues(PlayerNumber) do
	af[#af + 1] = Def.ActorFrame{
		Name = ToEnumShortString(player) .. "ACLeaderboard",
		InitCommand = function(self)
			self:y(_screen.cy - 15)
			self:queuecommand("Refresh")
		end,
		PlayerJoinedMessageCommand = function(self) self:queuecommand("Refresh") end,
		RefreshCommand = function(self)
			self:visible(GAMESTATE:IsSideJoined(player) and isPrimaryLeaderboardPane(player))
			self:xy(_screen.cx, _screen.cy - 15)
			self:SetWidth(getPaneWidth())
		end,

		Def.Quad{ InitCommand = function(self) self:diffuse(Color.White) end, RefreshCommand = function(self) self:zoomto(self:GetParent():GetWidth() + BorderWidth, PaneHeight + BorderWidth) end },
		Def.Quad{ InitCommand = function(self) self:diffuse(Color.Black) end, RefreshCommand = function(self) self:zoomto(self:GetParent():GetWidth(), PaneHeight) end },
		Def.Quad{ InitCommand = function(self) self:diffuse(Color.White):y(-PaneHeight / 2 + RowHeight / 2) end, RefreshCommand = function(self) self:zoomto(self:GetParent():GetWidth() + BorderWidth, RowHeight + BorderWidth) end },
		Def.Quad{ InitCommand = function(self) self:diffuse(HeaderColor):y(-PaneHeight / 2 + RowHeight / 2) end, RefreshCommand = function(self) self:zoomto(self:GetParent():GetWidth(), RowHeight) end },

		LoadFont(FontName)..{
			Name = "Header",
			Text = "Arrow Cloud",
			InitCommand = function(self) self:zoom(0.9):y(-PaneHeight / 2 + RowHeight / 2) end
		},
		LoadFont(FontName)..{
			Name = "TypeBadge",
			Text = "",
			InitCommand = function(self) self:zoom(0.62):horizalign(right):y(-PaneHeight / 2 + RowHeight / 2):visible(false):maxwidth(90) end,
			RefreshCommand = function(self) self:x(self:GetParent():GetWidth() / 2 - 14) end,
		},

		Def.Quad{ Name = "Self", InitCommand = function(self) self:diffuse(color("#A1FF94")):visible(false) end, ACResetEntryMessageCommand = function(self) self:visible(false) end, RefreshCommand = function(self) self:zoomto(self:GetParent():GetWidth(), RowHeight) end },
		Def.Quad{ Name = "Rival1", InitCommand = function(self) self:diffuse(color("#BD94FF")):visible(false) end, ACResetEntryMessageCommand = function(self) self:visible(false) end, RefreshCommand = function(self) self:zoomto(self:GetParent():GetWidth(), RowHeight) end },
		Def.Quad{ Name = "Rival2", InitCommand = function(self) self:diffuse(color("#BD94FF")):visible(false) end, ACResetEntryMessageCommand = function(self) self:visible(false) end, RefreshCommand = function(self) self:zoomto(self:GetParent():GetWidth(), RowHeight) end },
		Def.Quad{ Name = "Rival3", InitCommand = function(self) self:diffuse(color("#BD94FF")):visible(false) end, ACResetEntryMessageCommand = function(self) self:visible(false) end, RefreshCommand = function(self) self:zoomto(self:GetParent():GetWidth(), RowHeight) end },

		Def.ActorFrame{
			Name = "PaneIcons",
			InitCommand = function(self) self:y(PaneHeight / 2 - RowHeight / 2):visible(false) end,
			ACResetEntryMessageCommand = function(self) self:visible(false) end,
			LoadFont(FontName)..{ Text = "&MENULEFT;", InitCommand = function(self) self:zoom(0.6) end, RefreshCommand = function(self) self:x(-self:GetParent():GetParent():GetWidth() / 2 + 16) end },
			LoadFont(FontName)..{ Text = "More Leaderboards", InitCommand = function(self) self:zoom(0.62):diffuse(Color.White) end },
			LoadFont(FontName)..{ Text = "&MENURIGHT;", InitCommand = function(self) self:zoom(0.6) end, RefreshCommand = function(self) self:x(self:GetParent():GetParent():GetWidth() / 2 - 16) end },
		},

			Def.ActorFrame{
				Name = "CombinedHeader",
				InitCommand = function(self) self:y(-PaneHeight / 2 + RowHeight * 1.65):visible(false) end,
				RefreshCommand = function(self)
					local layout = getCombinedColumnLayout(self:GetParent():GetWidth())
					self:GetChild("Position"):x(layout.rankX):maxwidth(40)
					self:GetChild("PlayerName"):x(layout.nameX):maxwidth(layout.nameMaxWidth)
					self:GetChild("Score1"):x(layout.score1X):maxwidth(layout.scoreMaxWidth)
					self:GetChild("Score2"):x(layout.score2X):maxwidth(layout.scoreMaxWidth)
					self:GetChild("Score3"):x(layout.score3X):maxwidth(layout.scoreMaxWidth)
				end,
				LoadFont(FontName)..{ Name = "Position", Text = "#", InitCommand = function(self) self:horizalign(right):zoom(0.62):diffuse(Color.White) end },
				LoadFont(FontName)..{ Name = "PlayerName", Text = "Nom du joueur", InitCommand = function(self) self:horizalign(left):zoom(0.62):diffuse(Color.White) end },
				LoadFont(FontName)..{ Name = "Score1", Text = "HardEX", InitCommand = function(self) self:horizalign(right):zoom(0.62):diffuse(Color.White) end },
				LoadFont(FontName)..{ Name = "Score2", Text = "EX", InitCommand = function(self) self:horizalign(right):zoom(0.62):diffuse(Color.White) end },
				LoadFont(FontName)..{ Name = "Score3", Text = "ITG", InitCommand = function(self) self:horizalign(right):zoom(0.62):diffuse(Color.White) end },
			}
		}

	local pane = af[#af]
	for i = 1, NumEntries do
		pane[#pane + 1] = Def.ActorFrame{
			Name = "LeaderboardEntry" .. i,
			InitCommand = function(self) self:y(RowHeight * (i - (NumEntries + 1) / 2) + 10) end,
			RefreshCommand = function(self) self:GetChild("Date"):visible(false) end,

			LoadFont(FontName)..{
				Name = "Rank",
				Text = "",
				InitCommand = function(self) self:horizalign(right):zoom(0.68):maxwidth(44):diffuse(Color.White) end,
				RefreshCommand = function(self)
					local layout = getColumnLayout(self:GetParent():GetParent():GetWidth())
					self:x(layout.rankX)
				end,
				ACResetEntryMessageCommand = function(self) self:settext(""):diffuse(Color.White) end,
			},
			LoadFont(FontName)..{
				Name = "Name",
				Text = i == 1 and "Loading ..." or "",
				InitCommand = function(self) self:horizalign(left):zoom(0.68):diffuse(Color.White) end,
				RefreshCommand = function(self)
					local layout = getColumnLayout(self:GetParent():GetParent():GetWidth())
					self:x(layout.nameX):maxwidth(layout.nameMaxWidth)
				end,
				ACResetEntryMessageCommand = function(self) self:settext(i == 1 and "Loading ..." or ""):diffuse(Color.White) end,
			},
			LoadFont(FontName)..{
				Name = "Score",
				Text = "",
				InitCommand = function(self) self:horizalign(right):zoom(0.66):diffuse(Color.White):maxwidth(130) end,
				RefreshCommand = function(self)
					local layout = getColumnLayout(self:GetParent():GetParent():GetWidth())
					self:x(layout.scoreX):maxwidth(layout.scoreMaxWidth)
				end,
				ACResetEntryMessageCommand = function(self) self:settext(""):diffuse(Color.White) end,
			},
			LoadFont(FontName)..{
				Name = "Date",
				Text = "",
				InitCommand = function(self) self:horizalign(right):zoom(0.6):diffuse(Color.White):visible(false) end,
				RefreshCommand = function(self) self:visible(false) end,
				ACResetEntryMessageCommand = function(self) self:settext(""):diffuse(Color.White) end,
			},
				LoadFont(FontName)..{
					Name = "Board1",
					Text = "",
					InitCommand = function(self) self:horizalign(right):zoom(0.58):maxwidth(110):visible(false) end,
					RefreshCommand = function(self)
						local layout = getCombinedColumnLayout(self:GetParent():GetParent():GetWidth())
						self:x(layout.score1X):maxwidth(layout.scoreMaxWidth)
					end,
					ACResetEntryMessageCommand = function(self) self:settext(""):visible(false) end,
				},
				LoadFont(FontName)..{
					Name = "Board2",
					Text = "",
					InitCommand = function(self) self:horizalign(right):zoom(0.58):maxwidth(110):visible(false) end,
					RefreshCommand = function(self)
						local layout = getCombinedColumnLayout(self:GetParent():GetParent():GetWidth())
						self:x(layout.score2X):maxwidth(layout.scoreMaxWidth)
					end,
					ACResetEntryMessageCommand = function(self) self:settext(""):visible(false) end,
				},
				LoadFont(FontName)..{
					Name = "Board3",
					Text = "",
					InitCommand = function(self) self:horizalign(right):zoom(0.58):maxwidth(110):visible(false) end,
					RefreshCommand = function(self)
						local layout = getCombinedColumnLayout(self:GetParent():GetParent():GetWidth())
						self:x(layout.score3X):maxwidth(layout.scoreMaxWidth)
					end,
					ACResetEntryMessageCommand = function(self) self:settext(""):visible(false) end,
				},
		}
	end
end

return af
