if not IsServiceAllowed(SL.GrooveStats.AutoSubmit) or GAMESTATE:IsCourseMode() then return end

local NumEntries = 10

local IsOnlineEvaluation = function()
	return ITGOnline and ITGOnline.currentRoomId ~= nil
end

local GrooveStatsSubmitTrace = function(message)
	if not IsOnlineEvaluation() then return end

	if Trace then
		Trace("ITG Online external_submit groovestats " .. tostring(message or ""))
	end
end

local GetChildSafe

local SetEntryText = function(rank, name, score, date, actor)
	if actor == nil then return end

	local rankText = GetChildSafe(actor, "Rank")
	local nameText = GetChildSafe(actor, "Name")
	local scoreText = GetChildSafe(actor, "Score")
	local dateText = GetChildSafe(actor, "Date")

	if rankText then rankText:settext(rank) end
	if nameText then nameText:settext(name) end
	if scoreText then scoreText:settext(score) end
	if dateText then dateText:settext(date) end
end

local GetMachineTag

local GetLazyPaneContent = function(panes, paneIndex, side)
	if not panes then return nil end

	local sidePane = panes:GetChild(("Pane%i_SideP%i"):format(paneIndex, side))
	if not sidePane then return nil end

	local ok, command = pcall(function() return sidePane:GetCommand("EnsureLoaded") end)
	if ok and command then
		sidePane:playcommand("EnsureLoaded")
	end

	local childOk, content = pcall(function()
		return sidePane:GetChild("")
	end)
	return childOk and content or nil
end

GetChildSafe = function(actor, name)
	if not actor then return nil end

	local ok, child = pcall(function()
		return actor:GetChild(name)
	end)

	return ok and child or nil
end

local DecodeResponseBody = function(res)
	if not res or not res.body or res.body == "" then return nil end

	local ok, data = pcall(function()
		return JsonDecode(res.body)
	end)

	if not ok then
		GrooveStatsSubmitTrace("result=failed reason=json_decode")
		Trace("GrooveStats auto-submit warning: failed to decode response body")
		return nil
	end

	return data
end

local PopulateGrooveStatsLeaderboardPane = function(pane, leaderboard, scoreColor)
	if not pane or type(leaderboard) ~= "table" then return false end

	local highScoreList = GetChildSafe(pane, "HighScoreList")
	if not highScoreList then return false end

	local entryNum = 1
	for gsEntry in ivalues(leaderboard) do
		local entry = GetChildSafe(highScoreList, "HighScoreEntry"..entryNum)
		if not entry then break end

		entry:stoptweening()
		entry:diffuse(Color.White)
		SetEntryText(
			tostring(gsEntry["rank"] or entryNum)..".",
			GetMachineTag(gsEntry),
			string.format("%.2f%%", tonumber(gsEntry["score"] or 0) / 100),
			ParseGrooveStatsDate(gsEntry["date"]),
			entry
		)

		local score = GetChildSafe(entry, "Score")
		if score then score:diffuse(scoreColor or Color.White) end
		if gsEntry["isRival"] then
			entry:diffuse(color("#BD94FF"))
		elseif gsEntry["isSelf"] then
			entry:diffuse(color("#A1FF94"))
		end

		if gsEntry["isFail"] then
			if score then score:diffuse(Color.Red) end
		end

		entryNum = entryNum + 1
	end

	return entryNum > 1
end

GetMachineTag = function(gsEntry)
	if not gsEntry then return end
	if gsEntry["machineTag"] then
		-- Make sure we only use up to 4 characters for space concerns.
		return gsEntry["machineTag"]:sub(1, 4):upper()
	end

	-- User doesn't have a machineTag set. We'll "make" one based off of
	-- their name.
	if gsEntry["name"] then
		-- 4 Characters is the "intended" length.
		return gsEntry["name"]:sub(1,4):upper()
	end

	return ""
end

local GetJudgmentCounts = function(player)
	local counts = GetExJudgmentCounts(player)
	local translation = {
		["W0"] = "fantasticPlus",
		["W1"] = "fantastic",
		["W2"] = "excellent",
		["W3"] = "great",
		["W4"] = "decent",
		["W5"] = "wayOff",
		["Miss"] = "miss",
		["totalSteps"] = "totalSteps",
		["Holds"] = "holdsHeld",
		["totalHolds"] = "totalHolds",
		["Mines"] = "minesHit",
		["totalMines"] = "totalMines",
		["Rolls"] = "rollsHeld",
		["totalRolls"] = "totalRolls"
	}

	local judgmentCounts = {}

	for key, value in pairs(counts) do
		if translation[key] ~= nil then
			judgmentCounts[translation[key]] = value
		end
	end

	return judgmentCounts
end

local GetRescoredJudgmentCounts = function(player)
	local pn = ToEnumShortString(player)

	local translation = {
		["W0"] = "fantasticPlus",
		["W1"] = "fantastic",
		["W2"] = "excellent",
		["W3"] = "great",
		["W4"] = "decent",
		["W5"] = "wayOff",
	}

	local rescored = {
		["fantasticPlus"] = 0,
		["fantastic"] = 0,
		["excellent"] = 0,
		["great"] = 0,
		["decent"] = 0,
		["wayOff"] = 0
	}
	
	for i=1,GAMESTATE:GetCurrentStyle():ColumnsPerPlayer() do
		for window, name in pairs(translation) do
			rescored[name] = rescored[name] + SL[pn].Stages.Stats[SL.Global.Stages.PlayedThisGame + 1].column_judgments[i]["Early"][window]
		end
	end

	return rescored
end

local AttemptDownloads = function(res)
	local data = JsonDecode(res.body)
	for i=1,2 do
		local playerStr = "player"..i
		local events = {"rpg", "itl"}
		local player = "PlayerNumber_P"..i
		local itlDownloadsFound = false


		for event in ivalues(events) do
			if data and data[playerStr] and data[playerStr][event] then
				local eventData = data[playerStr][event]
				local eventName = eventData["name"] or "Unknown Event"
			
				-- See if any quests were completed.
				if eventData["progress"] and eventData["progress"]["questsCompleted"] then
					local quests = eventData["progress"]["questsCompleted"]
					-- Iterate through the quests...
					for quest in ivalues(quests) do
						-- ...and check for any unlocks.
						if quest["songDownloadUrl"] then
							local url = quest["songDownloadUrl"]
							local title = quest["title"] or ""

							if ThemePrefs.Get("SeparateUnlocksByPlayer") then
								local profileName = "NoName"
								if (PROFILEMAN:IsPersistentProfile(player) and
										PROFILEMAN:GetProfile(player)) then
									profileName = PROFILEMAN:GetProfile(player):GetDisplayName()
								end
								title = title.." - "..profileName
								DownloadEventUnlock(url, "["..eventName.."] "..title, eventName.." Unlocks - "..profileName)
							else
								DownloadEventUnlock(url, "["..eventName.."] "..title, eventName.." Unlocks")
							end
						end
					end
				end
			end
		end
	end
end

local AutoSubmitRequestProcessor = function(res, overlay)
	local master = GetChildSafe(overlay, "AutoSubmitMaster")
	if not master then
		GrooveStatsSubmitTrace("result=ignored reason=missing_auto_submit_master")
		Trace("GrooveStats auto-submit warning: response ignored because evaluation actors are unavailable")
		return
	end

	local P1SubmitText = GetChildSafe(master, "P1SubmitText")
	local P2SubmitText = GetChildSafe(master, "P2SubmitText")
	GrooveStatsSubmitTrace("response_received room=" .. tostring(ITGOnline and ITGOnline.currentRoomId or "nil")
		.. " phase=" .. tostring(ITGOnline and ITGOnline.currentRoom and ITGOnline.currentRoom.phase or "nil")
		.. " status=" .. tostring(res and res.statusCode or "nil")
		.. " hasError=" .. tostring(res and res.error ~= nil)
		.. " bodyBytes=" .. tostring(res and res.body and string.len(res.body) or 0))

	if not res or res.error or res.statusCode ~= 200 then
		local statusCode = res and res.statusCode or nil
		local error = res and res.error and ToEnumShortString(res.error) or nil
		GrooveStatsSubmitTrace("result=failed status=" .. tostring(statusCode)
			.. " error=" .. tostring(error or "nil"))
		if error == "Timeout" then
			if P1SubmitText then P1SubmitText:queuecommand("TimedOut") end
			if P2SubmitText then P2SubmitText:queuecommand("TimedOut") end
		elseif error or (statusCode ~= nil and statusCode ~= 200) then
			if P1SubmitText then P1SubmitText:queuecommand("SubmitFailed") end
			if P2SubmitText then P2SubmitText:queuecommand("SubmitFailed") end
		end
		return
	end

	GrooveStatsSubmitTrace("result=ok status=" .. tostring(res.statusCode))

	local panes = GetChildSafe(overlay, "Panes")
	local shouldDisplayOverlay = false

	-- Hijack the leaderboard pane to display the GrooveStats leaderboards.
	if panes then
		local data = DecodeResponseBody(res)
		GrooveStatsSubmitTrace("response_decoded room=" .. tostring(ITGOnline and ITGOnline.currentRoomId or "nil")
			.. " hasData=" .. tostring(data ~= nil)
			.. " hasPlayer1=" .. tostring(data and data.player1 ~= nil)
			.. " hasPlayer2=" .. tostring(data and data.player2 ~= nil))
		for i=1,2 do
			local playerStr = "player"..i
			local entryNum = 1
			local rivalNum = 1
			-- Pane 8 is the groovestats highscores pane.
			local highScorePane = GetLazyPaneContent(panes, 8, i)
			local QRPane = GetLazyPaneContent(panes, 7, i)
			local RPGPane = GetLazyPaneContent(panes, 9, i)
			local ITLPane = GetLazyPaneContent(panes, 10, i)

			-- If only one player is joined, we then need to update both panes with only
			-- one players' data.
			local side = i
			if data and GAMESTATE:GetNumSidesJoined() == 1 then
				if data["player1"] then
					side = 1
				else
					side = 2
				end
				playerStr = "player"..side
			end

			if data and data[playerStr] then
				-- And then also ensure that the chart hash matches the currently parsed one.
				-- It's better to just not display anything than display the wrong scores.
				if SL["P"..side].Streams.Hash == data[playerStr]["chartHash"] then
					GrooveStatsSubmitTrace("leaderboard_apply player=P" .. tostring(side)
						.. " chartHash=" .. tostring(data[playerStr]["chartHash"] or "")
						.. " expectedHash=" .. tostring(SL["P"..side].Streams.Hash or "")
						.. " hasGsLeaderboard=" .. tostring(data[playerStr]["gsLeaderboard"] ~= nil)
						.. " hasExLeaderboard=" .. tostring(data[playerStr]["exLeaderboard"] ~= nil)
						.. " room=" .. tostring(ITGOnline and ITGOnline.currentRoomId or "nil"))
					local personalRank = nil
					local showExScore = SL["P"..side].ActiveModifiers.ShowExScore and data[playerStr]["exLeaderboard"]

					local leaderboardData = nil
					if showExScore then
						leaderboardData = data[playerStr]["exLeaderboard"]
					elseif data[playerStr]["gsLeaderboard"] then
						leaderboardData = data[playerStr]["gsLeaderboard"]
					end

					if leaderboardData and highScorePane then
						for gsEntry in ivalues(leaderboardData) do
							local highScoreList = GetChildSafe(highScorePane, "HighScoreList")
							local entry = highScoreList and GetChildSafe(highScoreList, "HighScoreEntry"..entryNum)
							if not entry then break end
							entry:stoptweening()
							entry:diffuse(Color.White)
							SetEntryText(
								gsEntry["rank"]..".",
								GetMachineTag(gsEntry),
								string.format("%.2f%%", gsEntry["score"]/100),
								ParseGrooveStatsDate(gsEntry["date"]),
								entry
							)

							-- TODO(teejusb): Determine how we want to easily display EX scores.
							-- For now just highlight blue because it's simple.
							local score = GetChildSafe(entry, "Score")
							if showExScore then
								if score then score:diffuse(SL.JudgmentColors["ITG"][1]) end
							else
								if score then score:diffuse(Color.White) end
							end

							if gsEntry["isRival"] then
								entry:diffuse(color("#BD94FF"))
								rivalNum = rivalNum + 1
							elseif gsEntry["isSelf"] then
								entry:diffuse(color("#A1FF94"))
								personalRank = gsEntry["rank"]
							end

							if gsEntry["isFail"] then
								if score then score:diffuse(Color.Red) end
							end
							entryNum = entryNum + 1
						end

						if QRPane then
							local qrCode = GetChildSafe(QRPane, "QRCode")
							local helpText = GetChildSafe(QRPane, "HelpText")
							if qrCode then qrCode:queuecommand("Hide") end
							if helpText then helpText:settext(THEME:GetString("GrooveStats", "ScoreAlreadySubmitted")) end
						end
						if i == 1 and P1SubmitText then
							P1SubmitText:queuecommand("Submit")
						elseif i == 2 and P2SubmitText then
							P2SubmitText:queuecommand("Submit")
						end
					end

					if data[playerStr]["rpg"] then
						PopulateGrooveStatsLeaderboardPane(
							RPGPane,
							data[playerStr]["rpg"]["rpgLeaderboard"],
							Color.White
						)
					end

					if data[playerStr]["itl"] then
						PopulateGrooveStatsLeaderboardPane(
							ITLPane,
							data[playerStr]["itl"]["itlLeaderboard"],
							SL.JudgmentColors["FA+"][1]
						)
					end

					-- Only display the overlay on the sides that are actually joined.
					if ToEnumShortString("PLAYER_P"..i) == "P"..side and (data[playerStr]["rpg"] or data[playerStr]["itl"]) then
						local eventOverlay = GetChildSafe(master, "EventOverlay")
						local eventAf = eventOverlay and GetChildSafe(eventOverlay, "P"..i.."EventAf")
						if eventAf then
							eventAf:playcommand("Show", {data=data[playerStr]})
							shouldDisplayOverlay = true
						end

						if data[playerStr]["itl"] then
							-- Check for downloadFolders
							local itlData = data[playerStr]["itl"]
							if itlData["progress"] and itlData["progress"]["questsCompleted"] then
								local quests = itlData["progress"]["questsCompleted"]
								local hasDownloadFolders = false
								for quest in ivalues(quests) do
									if quest["songDownloadFolders"] then
										local downloadFolders = quest["songDownloadFolders"]
										UpdateItlUnlocks("PlayerNumber_P"..side, downloadFolders)
										hasDownloadFolders = true
									end
								end
								if hasDownloadFolders then
									-- Write out the file if we found any download unlocks.
									WriteItlFile("PlayerNumber_P"..side)
								end
							end
						end
					end

					-- Only update PB/WR messages on the side that is joined
					if ToEnumShortString("PLAYER_P"..i) == "P"..side then
						local upperPane = GetChildSafe(overlay, "P"..side.."_AF_Upper")
						if upperPane then
							if data[playerStr]["result"] == "score-added" or data[playerStr]["result"] == "improved" then
								local recordText = GetChildSafe(master, "P"..side.."RecordText")
								local GSIcon = GetChildSafe(master, "P"..side.."GrooveStats_Logo")

								if recordText and GSIcon then
									recordText:visible(true)
									GSIcon:visible(true)
									recordText:diffuseshift():effectcolor1(Color.White):effectcolor2(Color.Yellow):effectperiod(3)
									if personalRank == 1 then
										local worldRecordText = THEME:GetString("GrooveStats", "WorldRecord")
										if showExScore then
											worldRecordText = worldRecordText .. " (EX)"
										end
										recordText:settext(worldRecordText)
									else
										recordText:settext(THEME:GetString("GrooveStats", "PersonalBest"))
									end
									local recordTextXStart = recordText:GetX() - recordText:GetWidth()*recordText:GetZoom()/2
									local GSIconWidth = GSIcon:GetWidth()*GSIcon:GetZoom()
									-- This will automatically adjust based on the length of the recordText length.
									GSIcon:xy(recordTextXStart - GSIconWidth/2, recordText:GetY())
								end
							end
						end
					end
				end
			end

			-- Empty out any remaining entries on a successful response.
			-- For failed responses we fallback to the scores available in the machine.
			if res["status"] == "success" and highScorePane then
				local highScoreList = GetChildSafe(highScorePane, "HighScoreList")
				for j=entryNum, NumEntries do
					local entry = highScoreList and GetChildSafe(highScoreList, "HighScoreEntry"..j)
					if not entry then break end
					entry:stoptweening()
					-- We didn't get any scores if i is still == 1.
					if j == 1 then
						SetEntryText("", "No Scores", "", "", entry)
					else
						-- Empty out the remaining rows.
						SetEntryText("---", "----", "------", "----------", entry)
					end
				else
					GrooveStatsSubmitTrace("leaderboard_skip player=P" .. tostring(side)
						.. " reason=chart_hash_mismatch"
						.. " expectedHash=" .. tostring(SL["P"..side].Streams.Hash or "")
						.. " responseHash=" .. tostring(data[playerStr]["chartHash"] or "")
						.. " room=" .. tostring(ITGOnline and ITGOnline.currentRoomId or "nil"))
				end
			end
		end
	end

	if shouldDisplayOverlay then
		local eventOverlay = GetChildSafe(master, "EventOverlay")
		if not eventOverlay then return end
		eventOverlay:visible(true)
		overlay:queuecommand("DirectInputToEventOverlayHandler")
	end

	if ThemePrefs.Get("AutoDownloadUnlocks") then
		-- This will only download if the expected data exists.
		AttemptDownloads(res)
	end
end

local af = Def.ActorFrame {
	Name="AutoSubmitMaster",
	OnCommand=function(self)
		-- local overlay = SCREENMAN:GetTopScreen():GetChild("Overlay"):GetChild("ScreenEval Common")
		-- overlay:GetChild("AutoSubmitMaster"):GetChild("EventOverlay"):visible(true)
		-- overlay:queuecommand("DirectInputToEventOverlayHandler")

		-- local eventAf = overlay:GetChild("AutoSubmitMaster"):GetChild("EventOverlay"):GetChild("P1EventAf")
		-- eventAf:playcommand("Show", {data={
		-- 	["rpg"] = {
		-- 		["name"] = "SRPG9",
		-- 		["result"] = "score-added",
		-- 		["rpgLeaderboard"] = {
		-- 			{
		-- 				["rank"] = 1,
		-- 				["name"] = "Player1",
		-- 				["score"] = 9900,
		-- 				["date"] ="2024-05-05 1:20:30",
		-- 				["isRival"] = false,
		-- 				["isSelf"] = false,
		-- 			},
		-- 			{
		-- 				["rank"] = 2,
		-- 				["name"] = "Player2",
		-- 				["score"] = 9800,
		-- 				["date"] ="2024-05-05 1:20:30",
		-- 				["isRival"] = true,
		-- 				["isSelf"] = false,
		-- 			},
		-- 			{
		-- 				["rank"] = 3,
		-- 				["name"] = "Player3",
		-- 				["score"] = 9700,
		-- 				["date"] ="2024-05-05 1:20:30",
		-- 				["isRival"] = false,
		-- 				["isSelf"] = true,
		-- 			}
		-- 		}
		-- 	}
		-- }})
	end,
	RequestResponseActor(17, 50)..{
		OnCommand=function(self)
			local sendRequest = false
			local headers = {}
			local query = {
				maxLeaderboardResults=NumEntries,
			}
			local body = {}

			GrooveStatsSubmitTrace("screen=ScreenEvaluationStage room=" .. tostring(ITGOnline and ITGOnline.currentRoomId or "nil")
				.. " rate=" .. tostring(SL.Global.ActiveModifiers.MusicRate)
				.. " players=" .. tostring(GAMESTATE:GetNumSidesJoined()))

			local rate = tonumber(string.format("%.0f", SL.Global.ActiveModifiers.MusicRate * 100))
			for i=1,2 do
				local player = "PlayerNumber_P"..i
				local pn = ToEnumShortString(player)

				if GAMESTATE:IsHumanPlayer(player) and GAMESTATE:IsSideJoined(player) then
					local _, valid, _ = ValidForGrooveStats(player)
					local stats = STATSMAN:GetCurStageStats():GetPlayerStageStats(player)
					local submitForPlayer = false
					local failed = stats:GetFailed()
					local isPadPlayer = SL[pn].IsPadPlayer == true
					local hasApiKey = SL[pn].ApiKey ~= ""
					local hasHash = SL[pn].Streams.Hash ~= ""
					GrooveStatsSubmitTrace("player=" .. pn .. " snapshot"
						.. " valid=" .. tostring(valid)
						.. " failed=" .. tostring(failed)
						.. " pad=" .. tostring(isPadPlayer)
						.. " hasApiKey=" .. tostring(hasApiKey)
						.. " hasHash=" .. tostring(hasHash)
						.. " room=" .. tostring(ITGOnline and ITGOnline.currentRoomId or "nil")
						.. " phase=" .. tostring(ITGOnline and ITGOnline.currentRoom and ITGOnline.currentRoom.phase or "nil")
						.. " scoreMode=" .. tostring(SL[pn].ActiveModifiers and SL[pn].ActiveModifiers.SimulateScoreMode or "nil"))

					if valid and not failed and isPadPlayer then
						local percentDP = stats:GetPercentDancePoints()
						local score = tonumber(("%.0f"):format(percentDP * 10000))

						if hasApiKey and hasHash then
							query["chartHashP"..i] = SL[pn].Streams.Hash
							headers["x-api-key-player-"..i] = SL[pn].ApiKey

							body["player"..i] = {
								rate=rate,
								score=score,
								judgmentCounts=GetJudgmentCounts(player),
								rescoreCounts=GetRescoredJudgmentCounts(player),
								usedCmod=(GAMESTATE:GetPlayerState(pn):GetPlayerOptions("ModsLevel_Preferred"):CMod() ~= nil),
								comment=CreateCommentString(player),
								playerOptions=GetPlayerOptionsJsonForGrooveStats(player),
							}
							sendRequest = true
							submitForPlayer = true
							GrooveStatsSubmitTrace("player=" .. pn .. " action=submit"
								.. " hash=" .. tostring(SL[pn].Streams.Hash)
								.. " score=" .. tostring(score)
								.. " percentDP=" .. tostring(percentDP)
								.. " rate=" .. tostring(rate)
								.. " online=true")
						else
							GrooveStatsSubmitTrace("player=" .. pn .. " action=skip"
								.. " reason=" .. (not hasApiKey and "missing_api_key" or "missing_chart_hash")
								.. " valid=" .. tostring(valid)
								.. " failed=" .. tostring(failed)
								.. " pad=" .. tostring(isPadPlayer))
						end
					else
						GrooveStatsSubmitTrace("player=" .. pn .. " action=skip"
							.. " reason=" .. (not valid and "invalid_for_groovestats" or failed and "failed" or "not_pad_player")
							.. " valid=" .. tostring(valid)
							.. " failed=" .. tostring(failed)
							.. " pad=" .. tostring(isPadPlayer)
							.. " key=" .. tostring(hasApiKey)
							.. " hash=" .. tostring(hasHash))
					end

					if not submitForPlayer then
						-- Hide the submit text if we're not submitting a score for a player.
						-- For example in versus, if one player fails and the other passes, we
						-- want to show that the first player score won't be submitted.
						local submitText = GetChildSafe(self:GetParent(), "P"..i.."SubmitText")
						if submitText then submitText:visible(false) end
					end
				end
			end

			-- Only send the request if it's applicable.
			if sendRequest then
				-- Unjoined players won't have the text displayed.
				local parent = self:GetParent()
				local p1SubmitText = GetChildSafe(parent, "P1SubmitText")
				local p2SubmitText = GetChildSafe(parent, "P2SubmitText")
				if p1SubmitText then p1SubmitText:settext(THEME:GetString("GrooveStats", "Submitting")) end
				if p2SubmitText then p2SubmitText:settext(THEME:GetString("GrooveStats", "Submitting")) end

				local topScreen = SCREENMAN:GetTopScreen()
				local overlay = topScreen and GetChildSafe(topScreen, "Overlay")
				local evalCommon = overlay and GetChildSafe(overlay, "ScreenEval Common")

				GrooveStatsSubmitTrace("request_send room=" .. tostring(ITGOnline and ITGOnline.currentRoomId or "nil")
					.. " phase=" .. tostring(ITGOnline and ITGOnline.currentRoom and ITGOnline.currentRoom.phase or "nil")
					.. " queryPlayers=" .. tostring((query.chartHashP1 and "P1" or "") .. (query.chartHashP2 and ",P2" or ""))
					.. " bodyBytes=" .. tostring(string.len(JsonEncode(body))))
				self:playcommand("MakeGrooveStatsRequest", {
					endpoint="?action=scoreSubmit&"..NETWORK:EncodeQueryParameters(query),
					method="POST",
					headers=headers,
					body=JsonEncode(body),
					timeout=30,
					callback=AutoSubmitRequestProcessor,
					args=evalCommon,
				})
			else
				GrooveStatsSubmitTrace("action=no_request")
			end
		end
	}
}

local textColor = Color.White
local shadowLength = 0
if ThemePrefs.Get("RainbowMode") then
	textColor = Color.Black
end

af[#af+1] = LoadFont("Common Normal").. {
	Name="P1SubmitText",
	Text="",
	InitCommand=function(self)
		self:xy(_screen.w * 0.25, _screen.h - 15)
		self:diffuse(textColor)
		self:shadowlength(shadowLength)
		self:zoom(0.8)
		self:visible(GAMESTATE:IsSideJoined(PLAYER_1))
	end,
	SubmitCommand=function(self)
		self:settext(THEME:GetString("GrooveStats", "Submitted"))
	end,
	SubmitFailedCommand=function(self)
		self:settext(THEME:GetString("GrooveStats", "SubmitFailed"))
		DiffuseEmojis(self)
	end,
	TimedOutCommand=function(self)
		self:settext(THEME:GetString("GrooveStats", "TimedOut"))
	end
}

af[#af+1] = LoadFont("Common Normal").. {
	Name="P2SubmitText",
	Text="",
	InitCommand=function(self)
		self:xy(_screen.w * 0.75, _screen.h - 15)
		self:diffuse(textColor)
		self:shadowlength(shadowLength)
		self:zoom(0.8)
		self:visible(GAMESTATE:IsSideJoined(PLAYER_2))
	end,
	SubmitCommand=function(self)
		self:settext(THEME:GetString("GrooveStats", "Submitted"))
	end,
	SubmitFailedCommand=function(self)
		self:settext(THEME:GetString("GrooveStats", "SubmitFailed"))
		DiffuseEmojis(self)
	end,
	TimedOutCommand=function(self)
		self:settext(THEME:GetString("GrooveStats", "TimedOut"))
	end
}

af[#af+1] = Def.Sprite{
	Texture=THEME:GetPathG("","GrooveStats.png"),
	Name="P1GrooveStats_Logo",
	InitCommand=function(self)
		self:zoom(0.2)
		self:visible(false)
	end,
}

af[#af+1] = LoadFont("Common Bold")..{
	Name="P1RecordText",
	InitCommand=function(self)
		local x = _screen.cx - 225
		self:zoom(0.225)
		self:xy(x,40)
		self:visible(false)
	end,
}

af[#af+1] = Def.Sprite{
	Texture=THEME:GetPathG("","GrooveStats.png"),
	Name="P2GrooveStats_Logo",
	InitCommand=function(self)
		self:zoom(0.2)
		self:visible(false)
	end,
}

af[#af+1] = LoadFont("Common Bold")..{
	Name="P2RecordText",
	InitCommand=function(self)
		local x = _screen.cx + 225
		self:zoom(0.225)
		self:xy(x,40)
		self:visible(false)
	end,
}

af[#af+1] = LoadActor("./EventOverlay.lua")

return af
