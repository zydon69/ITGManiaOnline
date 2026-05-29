local max_rows = 8
local play_state_for_user

local function compact_name(name)
	name = tostring(name or "Player")
	if #name <= 19 then return name end
	return name:sub(1, 16) .. "..."
end

local function local_user_id()
	if ITGOnline and ITGOnline.user and ITGOnline.user.id then
		return tostring(ITGOnline.user.id)
	end
	return ""
end

local function local_displayed_percent()
	local room = ITGOnline and ITGOnline.currentRoom or nil
	local phase = tostring(room and room.phase or "")
	if phase ~= "playing" then return nil end
	local state = play_state_for_user(local_user_id())
	if state ~= "" and state ~= "playing" then return nil end
	if ITGOnline and ITGOnline.lastDisplayedScoreSnapshot then
		local age = GetTimeSinceStart() - (tonumber(ITGOnline.lastDisplayedScoreSnapshotAt) or 0)
		if age > 1.0 and not ITGOnline.liveScoreInFlight and ITGOnline.pendingLiveScoreSnapshot == nil then
			return nil
		end
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

play_state_for_user = function(user_id)
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
	local failed = explicit_failed == true or state == "failed"
	local exited = state == "returned_to_lobby" or state == "disconnected"
	return {
		finished = state == "finished" and not failed,
		failed = failed,
		exited = exited,
	}
end

local function rows_from_leaderboard(leaderboard)
	local rows = {}
	local max_score = selected_max_score()
	for score in ivalues(leaderboard or {}) do
		local user = score.user or {}
		local accuracy_percent = tonumber(score.accuracy)
		local score_percent = tonumber(score.score_percent)
		if score_percent == nil and max_score > 0 and tonumber(score.score) then
			score_percent = math.max(0, math.min(100, (tonumber(score.score) / max_score) * 100))
		end

		-- The live leaderboard must follow the same canonical score shown in gameplay.
		local percent = score_percent
		if percent == nil then
			percent = accuracy_percent
		end
		local user_id = tostring(user.id or "")
		local play_state = play_state_for_user(user_id)
		local flags = terminal_flags(play_state, score.failed and true or false)
		local tick_status = tostring(score.leaderboard_tick_status or "")
		rows[#rows + 1] = {
			user_id = user_id,
			name = tostring(user.name or "Player"),
			percent = percent or 0,
			stale = tick_status == "stale" or score.leaderboard_tick_pending == true,
			failed = flags.failed,
			exited = flags.exited,
			finished = flags.finished,
			play_state = play_state,
		}
	end
	return rows
end

local function rows_from_lobby_state(data)
	local rows = {}
	if not data or (data.phase ~= "playing" and data.phase ~= "results") then return rows end
	for player in ivalues(data.players or {}) do
		if player.exScore ~= nil or player.score ~= nil or player.playState ~= nil then
			local score_percent = tonumber(player.score)
			local ex_percent = tonumber(player.exScore)
			-- `player.score` is canonical in online play; EX is fallback only.
			local percent = score_percent
			if percent == nil then percent = ex_percent end
			local player_id = tostring(player.playerId or "")
			local flags = terminal_flags(player.playState, false)
			rows[#rows + 1] = {
				user_id = player_id,
				name = tostring(player.profileName or "Player"),
				percent = percent or 0,
				failed = flags.failed,
				exited = flags.exited,
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
			local statusText = data.failed and "F" or (data.exited and "X" or (data.finished and "OK" or ""))
			local rowColor = color("#ffffff")
			if data.failed or data.exited then
				rowColor = color("#ff3b30")
			elseif data.finished then
				rowColor = color("#66ff99")
			elseif data.stale then
				rowColor = color("#ff9f1c")
			end
			if data.user_id == self_id and ITGOnline and ITGOnline.debugScoreTrace == true then
				local localValue = tonumber(self_displayed)
				local shownValue = tonumber(data.percent) or 0
				if online_trace then
					online_trace(string.format(
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
				if online_trace and ITGOnline and ITGOnline.debugScoreTrace == true then
					online_trace(string.format(
						"ITG Online Leaderboard drift: shown=%.3f local_displayed=%.3f",
						tonumber(data.percent) or 0,
						tonumber(self_displayed) or 0
					))
				end
			end
			if label then
				label:settext(string.format("%d. %s", i, compact_name(data.name)))
				label:diffuse(rowColor)
			end
			local marker = row:GetChild("Marker")
			if marker then
				marker:settext(data.user_id == self_id and ">" or "")
				marker:diffuse(rowColor)
			end
			local score = row:GetChild("Score")
			if score then
				score:settext(string.format("%.2f%%", data.percent or 0))
				score:diffuse(rowColor)
			end
			if status then
				status:settext(statusText)
				status:diffuse(rowColor)
			end
			row:diffuse(color("#ffffff"))
			row:stoptweening():linear(0.18):y(12 + (i - 1) * 20)
			row:visible(true)
		elseif row then
			row:visible(false)
		end
	end
end

local af = Def.ActorFrame{
	InitCommand=function(self)
		self:xy(_screen.cx, _screen.cy - 125):visible(false)
	end,
	ITGOnlineLeaderboardUpdatedMessageCommand=function(self, params)
		update_rows(self, rows_from_leaderboard(params and params.leaderboard or {}))
	end,
	OnlineLobbyStateMessageCommand=function(self, data)
		update_rows(self, rows_from_lobby_state(data))
	end,
}

af[#af + 1] = Def.Quad{
	Name="Background",
	InitCommand=function(self)
		local top = -36
		local bottom = _screen.h - self:GetParent():GetY()
		self:xy(-4, (top + bottom) / 2):zoomto(196, bottom - top):diffuse(color("#000000")):diffusealpha(0.55)
	end,
}

af[#af + 1] = LoadFont("Common Bold")..{
	Name="Title",
	Text="Leaderboard",
	InitCommand=function(self)
		self:y(-16):horizalign(center):zoom(0.48):shadowlength(1):diffuse(color("#ffffff")):diffusealpha(0.92)
	end,
}

for i = 1, max_rows do
	af[#af + 1] = Def.ActorFrame{
		Name="Row" .. tostring(i),
		InitCommand=function(self)
			self:visible(false)
		end,
		LoadFont("Common Normal")..{
			Name="Marker",
			InitCommand=function(self)
				self:x(-88):horizalign(center):zoom(0.833):shadowlength(1):diffusealpha(0.95)
			end,
		},
		LoadFont("Common Normal")..{
			Name="Label",
			InitCommand=function(self)
				self:x(-76):horizalign(left):zoom(0.833):shadowlength(1):diffusealpha(0.9)
			end,
		},
		LoadFont("Wendy/_ScreenEvaluation numbers")..{
			Name="Score",
			InitCommand=function(self)
				self:x(82):horizalign(right):zoom(0.26):shadowlength(1):diffusealpha(0.95)
			end,
		},
		LoadFont("Common Normal")..{
			Name="Status",
			InitCommand=function(self)
				self:x(98):horizalign(center):zoom(0.48):shadowlength(1):diffusealpha(0.95)
			end,
		},
	}
end

return af
