local max_rows = 8

local function local_user_id()
	if ITGOnline and ITGOnline.user and ITGOnline.user.id then
		return tostring(ITGOnline.user.id)
	end
	return ""
end

local function local_displayed_percent()
	if ITGOnline and ITGOnline.lastDisplayedScoreSnapshot then
		local value = tonumber(ITGOnline.lastDisplayedScoreSnapshot.displayedPercent)
		if value ~= nil then
			return math.max(0, math.min(100, value))
		end
	end
	return nil
end

local function selected_max_score()
	if ITGOnline and ITGOnline.currentSongPayload and tonumber(ITGOnline.currentSongPayload.max_score) then
		return tonumber(ITGOnline.currentSongPayload.max_score)
	end
	if ITGOnline and ITGOnline.currentRoom and ITGOnline.currentRoom.selected_song and tonumber(ITGOnline.currentRoom.selected_song.max_score) then
		return tonumber(ITGOnline.currentRoom.selected_song.max_score)
	end
	return 0
end

local function rows_from_leaderboard(leaderboard)
	local rows = {}
	local max_score = selected_max_score()
	local self_id = local_user_id()
	local self_displayed = local_displayed_percent()
	for score in ivalues(leaderboard or {}) do
		local user = score.user or {}
		local accuracy_percent = tonumber(score.accuracy)
		local ex_percent = tonumber(score.score_percent)
		if ex_percent == nil and max_score > 0 and tonumber(score.score) then
			ex_percent = math.max(0, math.min(100, (tonumber(score.score) / max_score) * 100))
		end

		-- The live leaderboard should follow score progression, not accuracy.
		-- Use accuracy only when score-based percentage is unavailable.
		local percent = ex_percent
		if percent == nil then
			percent = accuracy_percent
		end
		local user_id = tostring(user.id or "")
		if user_id == self_id and self_displayed ~= nil then
			percent = self_displayed
		end
		rows[#rows + 1] = {
			user_id = user_id,
			name = tostring(user.name or "Player"),
			percent = percent or 0,
			failed = score.failed and true or false,
		}
	end
	return rows
end

local function rows_from_lobby_state(data)
	local rows = {}
	if not data or data.phase ~= "playing" then return rows end
	local self_id = local_user_id()
	local self_displayed = local_displayed_percent()
	for player in ivalues(data.players or {}) do
		if player.exScore ~= nil or player.score ~= nil then
			local score_percent = tonumber(player.score)
			local ex_percent = tonumber(player.exScore)
			-- `player.score` is currently accuracy in LobbyState payload.
			-- Prefer EX/score-derived percentage for consistency with gameplay score.
			local percent = ex_percent
			if percent == nil then
				percent = score_percent
			end
			local player_id = tostring(player.playerId or "")
			if player_id == self_id and self_displayed ~= nil then
				percent = self_displayed
			end
			rows[#rows + 1] = {
				user_id = player_id,
				name = tostring(player.profileName or "Player"),
				percent = percent or 0,
				failed = player.playState == "failed" or player.playState == "returned_to_lobby",
			}
		end
	end
	table.sort(rows, function(a, b)
		return (a.percent or 0) > (b.percent or 0)
	end)
	return rows
end

local function update_rows(frame, rows)
	local show = ITGOnline and ITGOnline.currentRoom and ITGOnline.currentRoom.phase == "playing" and #rows > 0
	frame:visible(show)
	if not show then return end

	local self_id = local_user_id()
	local self_displayed = local_displayed_percent()
	for i = 1, max_rows do
		local row = frame:GetChild("Row" .. tostring(i))
		local data = rows[i]
		if row and data then
			local suffix = data.failed and "  ✖" or ""
			if data.user_id == self_id then
				local localValue = tonumber(self_displayed)
				local shownValue = tonumber(data.percent) or 0
				if Warn then
					Warn(string.format("ITG Online Leaderboard trace: shown=%.3f local_displayed=%s", shownValue, localValue and string.format("%.3f", localValue) or "nil"))
				end
			end
			if data.user_id == self_id and self_displayed ~= nil and math.abs((tonumber(data.percent) or 0) - self_displayed) > 0.2 then
				if Warn then
					Warn(string.format(
						"ITG Online Leaderboard drift: shown=%.3f local_displayed=%.3f",
						tonumber(data.percent) or 0,
						tonumber(self_displayed) or 0
					))
				end
			end
			row:settext(string.format("%d. %s  %.2f%%%s", i, data.name, data.percent or 0, suffix))
			if data.failed then
				row:diffuse(color("#ff3b30"))
			elseif data.user_id == self_id then
				row:diffuse(color("#ffd166"))
			else
				row:diffuse(color("#ffffff"))
			end
			row:stoptweening():linear(0.18):y((i - 1) * 20)
			row:visible(true)
		elseif row then
			row:visible(false)
		end
	end
end

local af = Def.ActorFrame{
	InitCommand=function(self)
		self:xy(_screen.cx, _screen.cy - 95):visible(false)
	end,
	ITGOnlineLeaderboardUpdatedMessageCommand=function(self, params)
		update_rows(self, rows_from_leaderboard(params and params.leaderboard or {}))
	end,
	OnlineLobbyStateMessageCommand=function(self, data)
		update_rows(self, rows_from_lobby_state(data))
	end,
}

for i = 1, max_rows do
	af[#af + 1] = LoadFont("Common Normal")..{
		Name="Row" .. tostring(i),
		InitCommand=function(self)
			self:horizalign(center):zoom(0.55):shadowlength(1):diffusealpha(0.9):visible(false)
		end,
	}
end

return af
