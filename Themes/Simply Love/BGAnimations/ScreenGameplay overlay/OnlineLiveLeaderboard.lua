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

local function play_state_for_user(user_id)
	local room = ITGOnline and ITGOnline.currentRoom or nil
	local sessions = room and room.play_state and room.play_state.sessions or {}
	local wanted = tostring(user_id or "")
	for session in ivalues(sessions or {}) do
		local user = session.user or {}
		local current = tostring(user.id or session.user_id or "")
		if current ~= "" and current == wanted then
			return tostring(session.state or "")
		end
	end
	return ""
end

local function terminal_flags(state, explicit_failed)
	state = tostring(state or "")
	return {
		finished = state == "finished",
		failed = state ~= "finished" and (explicit_failed == true
			or state == "failed"
			or state == "returned_to_lobby"
			or state == "disconnected"),
	}
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
		local play_state = play_state_for_user(user_id)
		local flags = terminal_flags(play_state, score.failed and true or false)
		rows[#rows + 1] = {
			user_id = user_id,
			name = tostring(user.name or "Player"),
			percent = percent or 0,
			failed = flags.failed,
			finished = flags.finished,
			play_state = play_state,
		}
	end
	return rows
end

local function rows_from_lobby_state(data)
	local rows = {}
	if not data or (data.phase ~= "playing" and data.phase ~= "results") then return rows end
	local self_id = local_user_id()
	local self_displayed = local_displayed_percent()
	for player in ivalues(data.players or {}) do
		if player.exScore ~= nil or player.score ~= nil or player.playState ~= nil then
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
			local flags = terminal_flags(player.playState, false)
			rows[#rows + 1] = {
				user_id = player_id,
				name = tostring(player.profileName or "Player"),
				percent = percent or 0,
				failed = flags.failed,
				finished = flags.finished,
				play_state = tostring(player.playState or ""),
			}
		end
	end
	table.sort(rows, function(a, b)
		return (a.percent or 0) > (b.percent or 0)
	end)
	return rows
end

local function update_rows(frame, rows)
	local phase = ITGOnline and ITGOnline.currentRoom and ITGOnline.currentRoom.phase or nil
	local show = ITGOnline and ITGOnline.currentRoom and (phase == "playing" or phase == "results") and #rows > 0
	frame:visible(show)
	if not show then return end

	local self_id = local_user_id()
	local self_displayed = local_displayed_percent()
	for i = 1, max_rows do
		local row = frame:GetChild("Row" .. tostring(i))
		local data = rows[i]
		if row and data then
			local label = row:GetChild("Label")
			local status = row:GetChild("Status")
			local statusText = data.failed and "✖" or (data.finished and "✔" or "")
			if data.user_id == self_id then
				local localValue = tonumber(self_displayed)
				local shownValue = tonumber(data.percent) or 0
				if Warn then
					Warn(string.format(
						"ITG Online Leaderboard trace: shown=%.3f local_displayed=%s state=%s failed=%s finished=%s status=%s",
						shownValue,
						localValue and string.format("%.3f", localValue) or "nil",
						tostring(data.play_state or ""),
						tostring(data.failed == true),
						tostring(data.finished == true),
						tostring(statusText)
					))
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
			if label then
				label:settext(string.format("%d. %s  %.2f%%", i, data.name, data.percent or 0))
			end
			if status then
				status:settext(statusText)
				status:diffuse(data.failed and color("#ff3b30") or color("#66ff99"))
			end
			if data.failed then
				row:diffuse(color("#ff3b30"))
			elseif data.finished then
				row:diffuse(color("#66ff99"))
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
	af[#af + 1] = Def.ActorFrame{
		Name="Row" .. tostring(i),
		InitCommand=function(self)
			self:visible(false)
		end,
		LoadFont("Common Normal")..{
			Name="Label",
			InitCommand=function(self)
				self:horizalign(center):zoom(0.55):shadowlength(1):diffusealpha(0.9)
			end,
		},
		LoadFont("16px fonts/_emoji 16px")..{
			Name="Status",
			InitCommand=function(self)
				self:x(168):horizalign(center):zoom(0.72):shadowlength(1):diffusealpha(0.95)
			end,
		},
	}
end

return af
