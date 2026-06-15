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

local function compact_name(name)
	name = tostring(name or "Player")
	local max_chars = math.max(8, math.floor(panel_width / 13))
	if #name <= max_chars then return name end
	return name:sub(1, max_chars - 3) .. "..."
end

local function local_user_id()
	if ITGOnline and ITGOnline.user and ITGOnline.user.id then
		return tostring(ITGOnline.user.id)
	end
	return ""
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
		local play_state = play_state_for_user(user_id)
		local flags = terminal_flags(play_state, score.failed and true or false)
		local is_finalized = score.finalized_at ~= nil and tostring(score.finalized_at) ~= ""
		rows[#rows + 1] = {
			user_id = user_id,
			name = tostring(user.name or "Player"),
			percent = percent or 0,
			failed = flags.failed,
			exited = flags.exited,
			finished = flags.finished or is_finalized,
			play_state = play_state,
		}
	end
	return rows
end

local function update_rows(frame, rows)
	local phase = ITGOnline and ITGOnline.currentRoom and ITGOnline.currentRoom.phase or nil
	local show = ITGOnline and ITGOnline.currentRoom and (phase == "playing" or phase == "results") and #rows > 0
	frame:visible(show)
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
			row:stoptweening():linear(0.18):y(12 + (i - 1) * 20)
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
	ITGOnlineLeaderboardUpdatedMessageCommand=function(self, params)
		update_rows(self, rows_from_leaderboard(params and params.leaderboard or {}))
	end,
	OnlineLobbyStateMessageCommand=function(self, data)
		-- Intentionally ignored: gameplay leaderboard is driven exclusively by ITGOnlineLeaderboardUpdated.
		return
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
