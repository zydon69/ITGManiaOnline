local max_rows = 8
local play_state_for_user
local panel_width = GetOnlineGameplayPanelWidth and GetOnlineGameplayPanelWidth("leaderboard") or 300
local panel_padding = panel_width * 0.07
local marker_x = (-panel_width / 2) + panel_padding
local label_x = (-panel_width / 2) + (panel_width * 0.15)
local score_x = (panel_width / 2) - (panel_width * 0.12)
local status_x = (panel_width / 2) - panel_padding
local title_zoom = 0.40
local row_zoom = 0.72
local score_zoom = 0.23
local status_zoom = 0.38
local label_maxwidth = math.max(1, (score_x - label_x - (panel_width * 0.12)) / row_zoom)
local score_maxwidth = math.max(1, (panel_width * 0.27) / score_zoom)
local last_visible_trace_at = -999
local last_layout_signature = ""
local last_visible_state = nil
local cached_score_context = ""
local cached_score_rows_by_user_id = {}
local cached_score_user_order = {}

local function monotonic_time()
	if GetTimeSinceStart then
		return tonumber(GetTimeSinceStart()) or 0
	end
	return 0
end

local function force_trace(message)
	local line = "ITG Online: FLOW live_leaderboard " .. tostring(message or "")
	if Trace then Trace(line) elseif Warn then Warn(line) end
end

local function compact_name(name)
	name = tostring(name or "Player")
	local max_chars = math.max(8, math.floor(panel_width / 13))
	if #name <= max_chars then return name end
	return name:sub(1, max_chars - 3) .. "..."
end

local function online_display_name(user, fallback)
	if ITGOnline and ITGOnline.UserDisplayName then
		return ITGOnline:UserDisplayName(user, fallback)
	end
	user = type(user) == "table" and user or {}
	return tostring(user.display_name or user.displayName or user.name or fallback or "Player")
end

local function local_user_id()
	if ITGOnline and ITGOnline.user and ITGOnline.user.id then
		return tostring(ITGOnline.user.id)
	end
	return ""
end

local function leaderboard_trace(message)
	if not (ITGOnline and (ITGOnline.debugOnlineTrace == true or ITGOnline.debugReadyFlow == true)) then
		return
	end
	force_trace(message)
end

local function room_round_context(room)
	room = room or (ITGOnline and ITGOnline.currentRoom) or {}
	local play_state = room.play_state or {}
	local selected_song = room.selected_song or {}
	return table.concat({
		tostring(room.id or room.roomId or ITGOnline and ITGOnline.currentRoomId or ""),
		tostring(play_state.round_key or play_state.roundKey or play_state.round_id or play_state.roundId or ""),
		tostring(play_state.started_at or play_state.startedAt or play_state.start_at or play_state.startAt or ""),
		tostring(selected_song.selected_at or selected_song.selectedAt or selected_song.id or selected_song.chart_key or selected_song.chartKey or ""),
	}, "|")
end

local function reset_score_cache_if_needed(room)
	local context = room_round_context(room)
	if context == cached_score_context then
		return
	end
	cached_score_context = context
	cached_score_rows_by_user_id = {}
	cached_score_user_order = {}
	leaderboard_trace("score_cache_reset context=" .. tostring(context))
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
	leaderboard_trace("rows_from_leaderboard begin raw=" .. tostring(leaderboard and #leaderboard or 0)
		.. " maxScore=" .. tostring(max_score)
		.. " room=" .. tostring(ITGOnline and ITGOnline.currentRoomId or "nil")
		.. " phase=" .. tostring(ITGOnline and ITGOnline.currentRoom and ITGOnline.currentRoom.phase or "nil"))
	for score in ivalues(leaderboard or {}) do
		local user = score.user or {}
		local accuracy_percent = tonumber(score.accuracy)
		local displayed_percent = tonumber(score.displayed_percent or score.displayedPercent)
		local ex_percent = tonumber(score.score_percent)
		if ex_percent == nil and max_score > 0 and tonumber(score.score) then
			ex_percent = math.max(0, math.min(100, (tonumber(score.score) / max_score) * 100))
		end

		-- The live leaderboard should follow score progression, not accuracy.
		-- Use accuracy only when score-based percentage is unavailable.
		local percent = displayed_percent or ex_percent
		if percent == nil then
			percent = accuracy_percent
		end
		local user_id = tostring(user.id or score.user_id or score.userId or "")
		local play_state = play_state_for_user(user_id)
		if play_state == "" and score.state ~= nil then
			play_state = tostring(score.state)
		end
		local flags = terminal_flags(play_state, score.failed and true or false)
		local is_finalized = score.finalized_at ~= nil and tostring(score.finalized_at) ~= ""
		rows[#rows + 1] = {
			user_id = user_id,
			name = online_display_name(user, score.user_name or score.userName or score.name or "Player"),
			percent = percent or 0,
			failed = flags.failed,
			exited = flags.exited,
			finished = flags.finished or is_finalized,
			play_state = play_state,
		}
	end
	leaderboard_trace("rows_from_leaderboard end rows=" .. tostring(#rows))
	return rows
end

local function rows_from_play_state_sessions(play_state)
	local rows = {}
	local sessions = play_state and play_state.sessions or {}
	leaderboard_trace("rows_from_play_state_sessions begin sessions=" .. tostring(sessions and #sessions or 0)
		.. " room=" .. tostring(ITGOnline and ITGOnline.currentRoomId or "nil")
		.. " phase=" .. tostring(ITGOnline and ITGOnline.currentRoom and ITGOnline.currentRoom.phase or "nil"))
	for session in ivalues(sessions or {}) do
		local user = session.user or {}
		local user_id = tostring(user.id or session.user_id or "")
		local state = tostring(session.state or "")
		local flags = terminal_flags(state, state == "failed")
		rows[#rows + 1] = {
			user_id = user_id,
			name = online_display_name(user, "Player"),
			percent = 0,
			failed = flags.failed,
			exited = flags.exited,
			finished = flags.finished,
			play_state = state,
		}
	end
	leaderboard_trace("rows_from_play_state_sessions end rows=" .. tostring(#rows))
	return rows
end

local function copy_row(row)
	local copied = {}
	for key, value in pairs(row or {}) do
		copied[key] = value
	end
	return copied
end

local function cache_has_user_id(user_id)
	user_id = tostring(user_id or "")
	for id in ivalues(cached_score_user_order or {}) do
		if tostring(id) == user_id then
			return true
		end
	end
	return false
end

local function remember_score_rows(rows)
	local remembered = 0
	for row in ivalues(rows or {}) do
		local user_id = tostring(row.user_id or "")
		if user_id ~= "" then
			cached_score_rows_by_user_id[user_id] = copy_row(row)
			if not cache_has_user_id(user_id) then
				cached_score_user_order[#cached_score_user_order + 1] = user_id
			end
			remembered = remembered + 1
		end
	end
	if remembered > 0 then
		leaderboard_trace("score_cache_remember rows=" .. tostring(remembered)
			.. " context=" .. tostring(cached_score_context))
	end
end

local function rows_layout_signature(rows)
	local parts = {}
	for row in ivalues(rows or {}) do
		parts[#parts + 1] = table.concat({
			tostring(row.user_id or ""),
			tostring(row.name or ""),
		}, ":")
	end
	return table.concat(parts, "|")
end

local function rows_from_room(room, leaderboard_override)
	reset_score_cache_if_needed(room)
	local leaderboard = leaderboard_override or (room and (room.leaderboard or room.live_scores or room.top_scores) or nil)
	local score_rows = rows_from_leaderboard(leaderboard or {})
	local session_rows = rows_from_play_state_sessions(room and room.play_state or nil)
	local score_by_user_id = {}
	local merged = {}
	local seen = {}
	remember_score_rows(score_rows)

	for row in ivalues(score_rows or {}) do
		if row.user_id and tostring(row.user_id) ~= "" then
			score_by_user_id[tostring(row.user_id)] = row
		end
	end

	if #session_rows > 0 then
		for session_row in ivalues(session_rows) do
			local user_id = tostring(session_row.user_id or "")
			local score_row = score_by_user_id[user_id] or cached_score_rows_by_user_id[user_id]
			local row = score_row and copy_row(score_row) or copy_row(session_row)
			if score_row then
				row.play_state = session_row.play_state
				row.failed = session_row.failed or score_row.failed
				row.exited = session_row.exited or score_row.exited
				row.finished = session_row.finished or score_row.finished
			end
			merged[#merged + 1] = row
			if user_id ~= "" then seen[user_id] = true end
		end

		for row in ivalues(score_rows or {}) do
			local user_id = tostring(row.user_id or "")
			if user_id ~= "" and not seen[user_id] then
				merged[#merged + 1] = row
				seen[user_id] = true
			end
		end

		for user_id in ivalues(cached_score_user_order or {}) do
			if tostring(user_id) ~= "" and not seen[tostring(user_id)] and cached_score_rows_by_user_id[tostring(user_id)] then
				merged[#merged + 1] = copy_row(cached_score_rows_by_user_id[tostring(user_id)])
				seen[tostring(user_id)] = true
			end
		end
	else
		merged = score_rows
	end

	leaderboard_trace("rows_from_room merged scoreRows=" .. tostring(#score_rows)
		.. " sessionRows=" .. tostring(#session_rows)
		.. " mergedRows=" .. tostring(#merged)
		.. " cachedRows=" .. tostring(#cached_score_user_order)
		.. " room=" .. tostring(room and room.id or ITGOnline and ITGOnline.currentRoomId or "nil")
		.. " phase=" .. tostring(room and room.phase or "nil"))
	return merged, leaderboard
end

local function update_rows(frame, rows)
	local phase = ITGOnline and ITGOnline.currentRoom and ITGOnline.currentRoom.phase or nil
	local show = ITGOnline and ITGOnline.currentRoom and (phase == "playing" or phase == "results") and #rows > 0
	local now = monotonic_time()
	if last_visible_state ~= show then
		frame:visible(show)
		frame:diffusealpha(show and 1 or 0)
		frame:zoom(1)
		last_visible_state = show
	end
	if now - last_visible_trace_at >= 1.0 then
		force_trace("visible_state show=" .. tostring(show == true)
			.. " rows=" .. tostring(#rows)
			.. " phase=" .. tostring(phase or "nil")
			.. " room=" .. tostring(ITGOnline and ITGOnline.currentRoomId or "nil")
			.. " x=" .. tostring(frame.GetX and frame:GetX() or "nil")
			.. " y=" .. tostring(frame.GetY and frame:GetY() or "nil")
			.. " alpha=" .. tostring(show and 1 or 0))
		last_visible_trace_at = now
	end
	leaderboard_trace("update_rows show=" .. tostring(show == true)
		.. " rows=" .. tostring(#rows)
		.. " phase=" .. tostring(phase or "nil")
		.. " room=" .. tostring(ITGOnline and ITGOnline.currentRoomId or "nil")
		.. " hasRoom=" .. tostring(ITGOnline and ITGOnline.currentRoom ~= nil))
	local signature = show and rows_layout_signature(rows) or ""
	local structure_changed = signature ~= last_layout_signature
	last_layout_signature = signature
	if not show then return end

	local self_id = local_user_id()
	for i = 1, max_rows do
		local row = frame:GetChild("Row" .. tostring(i))
		local data = rows[i]
		if row and data then
			local label = row:GetChild("Label")
			local status = row:GetChild("Status")
			local statusText = data.exited and "X" or (data.failed and "F" or (data.finished and "OK" or ""))
			local rowColor = color("#ffffff")
			if data.failed or data.exited then
				rowColor = color("#ff3b30")
			elseif data.finished then
				rowColor = color("#66ff99")
			elseif data.user_id == self_id then
				rowColor = color("#ffd166")
			end
			if data.user_id == self_id and ITGOnline and ITGOnline.debugScoreTrace == true then
				local shownValue = tonumber(data.percent) or 0
				local localShown = tonumber(ITGOnline.lastDisplayedScoreSnapshot and ITGOnline.lastDisplayedScoreSnapshot.displayedPercent) or -1
				local delta = (localShown >= 0) and (shownValue - localShown) or 0
				if online_trace then
					online_trace(string.format(
						"ITG Online Leaderboard trace: shown=%.3f local=%.3f delta=%.3f source=server state=%s failed=%s finished=%s status=%s",
						shownValue,
						localShown,
						delta,
						tostring(data.play_state or ""),
						tostring(data.failed == true),
						tostring(data.finished == true),
						tostring(statusText)
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
			if structure_changed then
				row:stoptweening():linear(0.18):y(12 + (i - 1) * 20)
			else
				row:y(12 + (i - 1) * 20)
			end
			row:visible(true)
		elseif row then
			row:visible(false)
		end
	end
end

local af = Def.ActorFrame{
	InitCommand=function(self)
		self:xy(GetOnlineGameplayColumnX and GetOnlineGameplayColumnX("center") or _screen.cx, _screen.cy - 125):visible(false)
		if Trace then
			Trace("SL_ONLINE_LIVE_LEADERBOARD"
				.. " panel_width=" .. tostring(panel_width)
				.. " panel_padding=" .. tostring(panel_padding)
				.. " local_x=" .. tostring(self:GetX())
				.. " local_y=" .. tostring(self:GetY())
				.. " marker_x=" .. tostring(marker_x)
				.. " label_x=" .. tostring(label_x)
				.. " score_x=" .. tostring(score_x)
				.. " status_x=" .. tostring(status_x)
				.. " title_zoom=" .. tostring(title_zoom)
				.. " row_zoom=" .. tostring(row_zoom)
				.. " score_zoom=" .. tostring(score_zoom)
				.. " screen_w=" .. tostring(_screen.w)
				.. " screen_h=" .. tostring(_screen.h)
				.. " aspect=" .. tostring(GetScreenAspectRatio()))
		end
	end,
	OnCommand=function(self)
		self:queuecommand("RefreshFromRoom")
	end,
	RefreshFromRoomCommand=function(self)
		local room = ITGOnline and ITGOnline.currentRoom or nil
		if room then
			local rows = rows_from_room(room)
			update_rows(self, rows)
		else
			update_rows(self, {})
		end
		self:sleep(0.25):queuecommand("RefreshFromRoom")
	end,
	ITGOnlineLeaderboardUpdatedMessageCommand=function(self, params)
		leaderboard_trace("message_leaderboard_updated version=" .. tostring(params and params.version_ms or "nil")
			.. " rows=" .. tostring(params and params.leaderboard and #params.leaderboard or 0)
			.. " source=" .. tostring(params and params.source or "nil"))
		local room = ITGOnline and ITGOnline.currentRoom or nil
		if room then
			update_rows(self, rows_from_room(room, params and params.leaderboard or {}))
		else
			update_rows(self, rows_from_leaderboard(params and params.leaderboard or {}))
		end
	end,
	OnlineLobbyStateMessageCommand=function(self, data)
		local room = data or (ITGOnline and ITGOnline.currentRoom) or nil
		local current_room_id = tostring(ITGOnline and ITGOnline.currentRoomId or "")
		local incoming_room_id = tostring(room and room.id or room and room.roomId or "")
		if current_room_id ~= "" and incoming_room_id ~= "" and current_room_id ~= incoming_room_id then
			leaderboard_trace("lobby_state_ignored reason=room_mismatch current=" .. current_room_id .. " incoming=" .. incoming_room_id)
			return
		end

		local rows, leaderboard = rows_from_room(room)
		leaderboard_trace("lobby_state_update rows=" .. tostring(#rows)
			.. " leaderboardRows=" .. tostring(leaderboard and #leaderboard or 0)
			.. " phase=" .. tostring(room and room.phase or "nil"))
		update_rows(self, rows)
	end,
}

af[#af + 1] = Def.Quad{
	Name="Background",
	InitCommand=function(self)
		local top = -36
		local bottom = _screen.h - self:GetParent():GetY()
		self:xy(0, (top + bottom) / 2):zoomto(panel_width, bottom - top):diffuse(color("#000000")):diffusealpha(0.55)
	end,
}

af[#af + 1] = LoadFont("Common Bold")..{
	Name="Title",
	Text="Leaderboard",
	InitCommand=function(self)
		self:y(-16):horizalign(center):zoom(title_zoom):maxwidth((panel_width * 0.88) / title_zoom):shadowlength(1):diffuse(color("#ffffff")):diffusealpha(0.92)
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
				self:x(marker_x):horizalign(center):zoom(row_zoom):shadowlength(1):diffusealpha(0.95)
			end,
		},
		LoadFont("Common Normal")..{
			Name="Label",
			InitCommand=function(self)
				self:x(label_x):horizalign(left):zoom(row_zoom):maxwidth(label_maxwidth):shadowlength(1):diffusealpha(0.9)
			end,
		},
		LoadFont("Wendy/_ScreenEvaluation numbers")..{
			Name="Score",
			InitCommand=function(self)
				self:x(score_x):horizalign(right):zoom(score_zoom):maxwidth(score_maxwidth):shadowlength(1):diffusealpha(0.95)
			end,
		},
		LoadFont("Common Normal")..{
			Name="Status",
			InitCommand=function(self)
				self:x(status_x):horizalign(center):zoom(status_zoom):maxwidth((panel_width * 0.18) / status_zoom):shadowlength(1):diffusealpha(0.95)
			end,
		},
	}
end

return af
