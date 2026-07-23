local max_rows = 8
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
local cached_room_id = ""
local cached_score_rows_by_user_id = {}
local cached_score_user_order = {}
local last_non_empty_rows = {}
local last_non_empty_rows_at = -999
local last_score_phase = ""
local leaderboard_trace_seen = {}
local leaderboard_trace_order = {}
local max_leaderboard_trace_signatures = 512

local function monotonic_time()
	if GetTimeSinceStart then
		return tonumber(GetTimeSinceStart()) or 0
	end
	return 0
end

local function force_trace(message)
	if type(online_logs_enabled) == "function" and not online_logs_enabled("score") then
		return
	end
	local normalizedMessage = tostring(message or "")
	if leaderboard_trace_seen[normalizedMessage] then
		return
	end
	leaderboard_trace_seen[normalizedMessage] = true
	leaderboard_trace_order[#leaderboard_trace_order + 1] = normalizedMessage
	if #leaderboard_trace_order > max_leaderboard_trace_signatures then
		local oldest = table.remove(leaderboard_trace_order, 1)
		leaderboard_trace_seen[oldest] = nil
	end
	if type(online_trace) == "function" then
		online_trace("FLOW live_leaderboard " .. normalizedMessage, "score")
	end
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
	if type(online_logs_enabled) == "function" and not online_logs_enabled("score") then
		return
	end
	force_trace(message)
end

local function room_round_context(room)
	room = room or (ITGOnline and ITGOnline.currentRoom) or {}
	if ITGOnline and ITGOnline.CanonicalGameplayRoundKey then
		local key = ITGOnline:CanonicalGameplayRoundKey("live_leaderboard")
		if ITGOnline.PlayStateKeyIsValid and ITGOnline:PlayStateKeyIsValid(key) then
			return key
		end
	end
	local play_state = room.play_state or {}
	local selected_song = room.selected_song or {}
	return table.concat({
		tostring(room.id or room.roomId or ITGOnline and ITGOnline.currentRoomId or ""),
		tostring(play_state.round_key or play_state.roundKey or play_state.round_id or play_state.roundId or ""),
		tostring(selected_song.song_hash or selected_song.songHash or ""),
		tostring(selected_song.chart_hash or selected_song.chartHash or selected_song.chart_key or selected_song.chartKey or ""),
		tostring(selected_song.selected_at or selected_song.selectedAt or play_state.started_at or play_state.startedAt or play_state.start_at or play_state.startAt or selected_song.id or ""),
	}, "|")
end

local function reset_score_cache_if_needed(room)
	local context = room_round_context(room)
	local room_id = tostring(room and (room.id or room.roomId) or ITGOnline and ITGOnline.currentRoomId or "")
	local phase = tostring(room and room.phase or ITGOnline and ITGOnline.currentRoom and ITGOnline.currentRoom.phase or "")
	if room_id == cached_room_id and context == cached_score_context then
		last_score_phase = phase
		return
	end
	if room_id == cached_room_id and phase == "playing" then
		leaderboard_trace("score_cache_reset reason=playing_context_changed context=" .. tostring(context)
			.. " cachedContext=" .. tostring(cached_score_context)
			.. " cachedRows=" .. tostring(#cached_score_user_order)
			.. " lastRows=" .. tostring(#last_non_empty_rows))
	end
	if room_id == cached_room_id and phase == "lobby" and last_score_phase == "results" and #last_non_empty_rows > 0 then
		last_score_phase = phase
		leaderboard_trace("score_cache_preserved reason=results_to_lobby_visual_grace context=" .. tostring(context)
			.. " cachedContext=" .. tostring(cached_score_context)
			.. " rows=" .. tostring(#last_non_empty_rows))
		return
	end
	if room_id == cached_room_id and phase == "results" and #last_non_empty_rows > 0 then
		cached_score_context = context
		last_score_phase = phase
		leaderboard_trace("score_cache_preserved reason=results_context_shift context=" .. tostring(context)
			.. " cachedRows=" .. tostring(#cached_score_user_order)
			.. " rows=" .. tostring(#last_non_empty_rows))
		return
	end
	cached_room_id = room_id
	cached_score_context = context
	cached_score_rows_by_user_id = {}
	cached_score_user_order = {}
	last_non_empty_rows = {}
	last_non_empty_rows_at = -999
	last_score_phase = phase
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
		local is_placeholder = score.is_placeholder == true or score.placeholder == true
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
		local is_finalized = (not is_placeholder) and score.finalized_at ~= nil and tostring(score.finalized_at) ~= ""
		rows[#rows + 1] = {
			user_id = user_id,
			name = online_display_name(user, score.user_name or score.userName or score.name or "Player"),
			percent = (is_placeholder and 0) or (percent or 0),
			is_placeholder = is_placeholder,
			is_reliable = score.is_reliable ~= false,
			rank = tonumber(score.rank),
			display_order = tonumber(score.display_order),
			failed = flags.failed,
			exited = flags.exited,
			finished = flags.finished or is_finalized,
			play_state = play_state,
			last_updated_at = tostring(score.updated_at or ""),
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
			is_placeholder = true,
			is_session_placeholder = true,
			is_reliable = false,
			rank = tonumber(session.rank),
			display_order = tonumber(session.display_order),
			failed = flags.failed,
			exited = flags.exited,
			finished = flags.finished,
			play_state = state,
			last_updated_at = tostring(session.updated_at or ""),
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

local function sort_row_for_display(left, right)
	local left_rank = tonumber(left and left.rank)
	local right_rank = tonumber(right and right.rank)
	if left_rank ~= nil and right_rank ~= nil and left_rank ~= right_rank then
		return left_rank < right_rank
	end

	local left_display_order = tonumber(left and left.display_order)
	local right_display_order = tonumber(right and right.display_order)
	if left_display_order ~= nil and right_display_order ~= nil and left_display_order ~= right_display_order then
		return left_display_order < right_display_order
	end

	local left_percent = tonumber(left and left.percent) or 0
	local right_percent = tonumber(right and right.percent) or 0
	if left_percent ~= right_percent then
		return left_percent > right_percent
	end

	local left_updated = tostring(left and left.last_updated_at or left and left.updated_at or "")
	local right_updated = tostring(right and right.last_updated_at or right and right.updated_at or "")
	if left_updated ~= right_updated then
		return left_updated > right_updated
	end

	local left_name = tostring(left and left.name or "")
	local right_name = tostring(right and right.name or "")
	if left_name ~= right_name then
		return left_name < right_name
	end

	return tostring(left and left.user_id or "") < tostring(right and right.user_id or "")
end

local function rows_debug_summary(rows)
	local parts = {}
	for row in ivalues(rows or {}) do
		parts[#parts + 1] = table.concat({
			tostring(row.user_id or ""),
			tostring(row.name or ""),
			string.format("%.2f", tonumber(row.percent) or 0),
			tostring(row.play_state or ""),
			tostring(row.failed == true),
			tostring(row.finished == true),
		}, ":")
	end
	return table.concat(parts, ",")
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

local function last_non_empty_score_row_for_user(user_id)
	user_id = tostring(user_id or "")
	if user_id == "" then
		return nil
	end

	for row in ivalues(last_non_empty_rows or {}) do
		if tostring(row.user_id or "") == user_id
			and row.is_session_placeholder ~= true
			and row.is_placeholder ~= true then
			return copy_row(row)
		end
	end

	return nil
end

local function remember_score_rows(rows)
	local remembered = 0
	for row in ivalues(rows or {}) do
		local user_id = tostring(row.user_id or "")
		if user_id ~= "" then
			local previous = cached_score_rows_by_user_id[user_id]
			local incoming_terminal = row.failed == true or row.finished == true or row.exited == true
			local incoming_placeholder = row.is_placeholder == true
			local previous_placeholder = previous and previous.is_placeholder == true
			if not previous
				or (previous_placeholder and not incoming_placeholder)
				or (not incoming_placeholder and incoming_terminal)
				or not incoming_placeholder then
				cached_score_rows_by_user_id[user_id] = copy_row(row)
			else
				leaderboard_trace("score_cache_kept_reliable user=" .. tostring(user_id)
					.. " incomingPlaceholder=" .. tostring(incoming_placeholder)
					.. " previousPlaceholder=" .. tostring(previous_placeholder))
			end
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
			local user_id = tostring(row.user_id)
			local cached = cached_score_rows_by_user_id[user_id]
			local row_is_placeholder = row.is_placeholder == true
			if cached and row_is_placeholder and cached.is_placeholder ~= true then
				score_by_user_id[user_id] = cached
			else
				score_by_user_id[user_id] = row
			end
		end
	end

	if #session_rows > 0 then
		for session_row in ivalues(session_rows) do
			local user_id = tostring(session_row.user_id or "")
			local score_row = score_by_user_id[user_id] or cached_score_rows_by_user_id[user_id]
			if not score_row and session_row.is_session_placeholder == true then
				score_row = last_non_empty_score_row_for_user(user_id)
				if score_row then
					leaderboard_trace("session_placeholder_preserved_score user=" .. tostring(user_id)
						.. " percent=" .. tostring(score_row.percent)
						.. " state=" .. tostring(session_row.play_state or "")
						.. " phase=" .. tostring(room and room.phase or "nil"))
				end
			end
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

		-- `session_rows` is authoritative membership. Cached scores may enrich a
		-- present placeholder, but must never resurrect a departed member.
	else
		for row in ivalues(score_rows or {}) do
			local user_id = tostring(row.user_id or "")
			local cached = cached_score_rows_by_user_id[user_id]
			local row_is_placeholder = row.is_placeholder == true
			if cached and row_is_placeholder and cached.is_placeholder ~= true then
				merged[#merged + 1] = copy_row(cached)
			else
				merged[#merged + 1] = row
			end
			if user_id ~= "" then seen[user_id] = true end
		end

		for user_id in ivalues(cached_score_user_order or {}) do
			if tostring(user_id) ~= "" and not seen[tostring(user_id)] and cached_score_rows_by_user_id[tostring(user_id)] then
				merged[#merged + 1] = copy_row(cached_score_rows_by_user_id[tostring(user_id)])
				seen[tostring(user_id)] = true
			end
		end
	end

	local room_phase = tostring(room and room.phase or "")
	if #merged == 0 and (room_phase == "playing" or room_phase == "results") and #last_non_empty_rows > 0 then
		leaderboard_trace("rows_from_room_reuse_last_non_empty reason=empty_" .. room_phase
			.. " room=" .. tostring(room and room.id or ITGOnline and ITGOnline.currentRoomId or "nil"))
		for row in ivalues(last_non_empty_rows) do
			merged[#merged + 1] = copy_row(row)
		end
	elseif #merged > 1 then
		table.sort(merged, sort_row_for_display)
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
	if (phase == "playing" or phase == "results") and (not rows or #rows == 0) and #last_non_empty_rows > 0 then
		leaderboard_trace("update_rows_reuse_last_non_empty reason=empty_" .. tostring(phase)
			.. " room=" .. tostring(ITGOnline and ITGOnline.currentRoomId or "nil"))
		rows = last_non_empty_rows
	end
	local show = ITGOnline and ITGOnline.currentRoom and (phase == "playing" or phase == "results") and #rows > 0
	local now = monotonic_time()
	if show and rows and #rows > 0 then
		last_non_empty_rows = {}
		for row in ivalues(rows) do
			last_non_empty_rows[#last_non_empty_rows + 1] = copy_row(row)
		end
		last_non_empty_rows_at = now
	elseif not show
		and phase == "lobby"
		and last_visible_state == true
		and #last_non_empty_rows > 0
		and now - last_non_empty_rows_at <= 1.0 then
		leaderboard_trace("update_rows_hide_deferred reason=results_to_lobby_visual_grace"
			.. " age=" .. tostring(now - last_non_empty_rows_at)
			.. " room=" .. tostring(ITGOnline and ITGOnline.currentRoomId or "nil"))
		show = true
		rows = last_non_empty_rows
	end
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
			.. " alpha=" .. tostring(show and 1 or 0)
			.. " rowSummary=" .. rows_debug_summary(rows))
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
					force_trace(string.format(
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
		force_trace("init"
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
	Text=THEME:GetString("ScreenOnlineLobbies", "Leaderboard"),
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
