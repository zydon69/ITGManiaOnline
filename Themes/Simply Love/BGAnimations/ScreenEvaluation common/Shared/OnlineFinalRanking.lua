local max_rows = 8

local function localized(name, fallback)
	if THEME:HasString("ScreenEvaluation", name) then
		return THEME:GetString("ScreenEvaluation", name)
	end
	return fallback
end

local function clamp(value, min_value, max_value)
	return math.max(min_value, math.min(max_value, value))
end

local function online_display_name(user, fallback)
	if ITGOnline and ITGOnline.UserDisplayName then
		return ITGOnline:UserDisplayName(user, fallback)
	end
	user = type(user) == "table" and user or {}
	return tostring(user.display_name or user.displayName or user.name or fallback or "Player")
end

local final_ranking_trace_seen = {}
local final_ranking_trace_order = {}
local max_final_ranking_trace_signatures = 256

local function final_ranking_trace(message)
	if type(online_logs_enabled) == "function" and not online_logs_enabled("score") then
		return
	end
	local normalizedMessage = tostring(message or "")
	if final_ranking_trace_seen[normalizedMessage] then
		return
	end
	final_ranking_trace_seen[normalizedMessage] = true
	final_ranking_trace_order[#final_ranking_trace_order + 1] = normalizedMessage
	if #final_ranking_trace_order > max_final_ranking_trace_signatures then
		local oldest = table.remove(final_ranking_trace_order, 1)
		final_ranking_trace_seen[oldest] = nil
	end
	if type(online_trace) == "function" then
		online_trace("FLOW final_ranking " .. normalizedMessage, "score")
	end
end

local function final_ranking_row_summary(row, index)
	if type(row) ~= "table" then return tostring(index or "?") .. ":invalid" end
	local user = type(row.user) == "table" and row.user or {}
	return table.concat({
		tostring(index or ""),
		tostring(row.rank or ""),
		tostring(user.id or row.user_id or row.player_id or ""),
		tostring(row.name or user.display_name or user.displayName or user.name or ""),
		tostring(row.displayed_percent or row.displayedPercent or ""),
		tostring(row.score_percent or row.scorePercent or ""),
		tostring(row.accuracy or ""),
		tostring(row.score or ""),
		tostring(row.failed == true),
		tostring(row.source or ""),
	}, ":")
end

local function final_ranking_rows_summary(rows)
	if type(rows) ~= "table" then return "none" end
	local parts = {}
	local count = math.min(#rows, max_rows)
	for index = 1, count do
		parts[#parts + 1] = final_ranking_row_summary(rows[index], index)
	end
	if #rows > count then
		parts[#parts + 1] = "more=" .. tostring(#rows - count)
	end
	return table.concat(parts, ",")
end

local function has_final_ranking_context()
	if not ITGOnline then return false end
	return ITGOnline.currentRoom ~= nil or ITGOnline.currentRoomId ~= nil
end

local function final_results()
	local results = nil
	local source = "current_room"
	local phase = nil
	local roomId = ITGOnline and ITGOnline.currentRoomId or nil

	if ITGOnline and ITGOnline.currentRoom and ITGOnline.currentRoom.play_state then
		results = ITGOnline.currentRoom.play_state.final_results
		phase = ITGOnline.currentRoom.phase
	end

	if type(results) ~= "table" or #results == 0 then
		local cached = ITGOnline and ITGOnline.GetFinalLeaderboardCache and ITGOnline:GetFinalLeaderboardCache(roomId) or nil
		if cached and type(cached.rows) == "table" and #cached.rows > 0 then
			results = cached.rows
			source = "cache:" .. tostring(cached.source or "unknown")
			roomId = cached.room_id or roomId
			final_ranking_trace("final_results_cache_hit"
				.. " room=" .. tostring(roomId or "nil")
				.. " rows=" .. tostring(#results)
				.. " roundKey=" .. tostring(cached.round_key or "nil")
				.. " version=" .. tostring(cached.version_ms or "nil"))
		else
			final_ranking_trace("final_results_empty"
				.. " reason=missing_current_and_cache"
				.. " room=" .. tostring(roomId or "nil")
				.. " hasRoom=" .. tostring(ITGOnline and ITGOnline.currentRoom ~= nil)
				.. " hasPlayState=" .. tostring(ITGOnline and ITGOnline.currentRoom and ITGOnline.currentRoom.play_state ~= nil)
				.. " currentType=" .. tostring(type(results))
				.. " phase=" .. tostring(phase or "nil"))
			return {}
		end
	end

	final_ranking_trace("final_results_begin raw=" .. tostring(#results)
		.. " room=" .. tostring(roomId or "nil")
		.. " phase=" .. tostring(phase or "nil")
		.. " source=" .. tostring(source)
		.. " rawRowsSummary=" .. final_ranking_rows_summary(results))
	local normalized = {}
	for index, result in ipairs(results) do
		if type(result) == "table" then
			local user = type(result.user) == "table" and result.user or {}
			local displayedPercent = tonumber(result.displayed_percent or result.displayedPercent)
			if displayedPercent == nil then
				final_ranking_trace("final_result_rejected_missing_displayed_percent"
					.. " index=" .. tostring(index)
					.. " user=" .. tostring(user.id or result.user_id or "nil")
					.. " score=" .. tostring(result.score or "nil")
					.. " score_percent=" .. tostring(result.score_percent or "nil")
					.. " accuracy=" .. tostring(result.accuracy or "nil"))
			else
				normalized[#normalized + 1] = {
					rank = tonumber(result.rank) or index,
					name = online_display_name(user, localized("OnlineUnknownPlayer", "Player")),
					score = math.floor(tonumber(result.score) or 0),
					displayed_percent = displayedPercent,
					score_percent = tonumber(result.score_percent),
					accuracy = tonumber(result.accuracy),
					failed = result.failed and true or false,
					user_id = user.id or result.user_id,
					source = result.source,
				}
			end
		end
	end

	table.sort(normalized, function(a, b)
		return (tonumber(a.rank) or 0) < (tonumber(b.rank) or 0)
	end)

	final_ranking_trace("final_results_end rows=" .. tostring(#normalized)
		.. " source=" .. tostring(source)
		.. " normalizedRowsSummary=" .. final_ranking_rows_summary(normalized))
	for index, row in ipairs(normalized) do
		final_ranking_trace("final_result_row"
			.. " index=" .. tostring(index)
			.. " rank=" .. tostring(row.rank or "nil")
			.. " user=" .. tostring(row.user_id or "nil")
			.. " name=" .. tostring(row.name or "nil")
			.. " displayed_percent=" .. tostring(row.displayed_percent or "nil")
			.. " score_percent=" .. tostring(row.score_percent or "nil")
			.. " accuracy=" .. tostring(row.accuracy or "nil")
			.. " score=" .. tostring(row.score or "nil")
			.. " failed=" .. tostring(row.failed == true)
			.. " source=" .. tostring(row.source or "nil"))
	end
	return normalized
end

local function final_results_signature(rows)
	local parts = {}
	for index, row in ipairs(rows or {}) do
		parts[#parts + 1] = table.concat({
			tostring(index),
			tostring(row.rank or ""),
			tostring(row.name or ""),
			tostring(row.score or ""),
			tostring(row.displayed_percent or ""),
			tostring(row.score_percent or ""),
			tostring(row.accuracy or ""),
			tostring(row.failed == true),
		}, ":")
	end
	return table.concat(parts, "|")
end

local function should_poll_final_results()
	if not (ITGOnline and ITGOnline.currentRoom and ITGOnline.NormalizeRoomPhase) then
		return false
	end
	if ITGOnline:NormalizeRoomPhase(ITGOnline.currentRoom.phase) ~= "results" then
		return false
	end
	if type(ITGOnline.RoomPlayStateSummary) ~= "function" then
		return true
	end
	local summary = ITGOnline:RoomPlayStateSummary(ITGOnline.currentRoom)
	return not (summary and summary.finalResultsReady == true)
end

local function schedule_refresh(self)
	if not self.polling_active or self.polling_scheduled then return end
	self.polling_scheduled = true
	self:sleep(0.5):queuecommand("Poll")
end

local width = clamp(_screen.w * 0.20, 280, 400)
local row_zoom = 0.66
local banner_zoom = 0.7
local banner_width = 418 * banner_zoom
local banner_height = 164 * banner_zoom
local banner_title_height = 25 * banner_zoom
local banner_title_y = (SL and SL.Global and SL.Global.GameMode == "Casual") and 50 or 46
local banner_y = banner_title_y + 66
local panel_height = clamp(banner_height + banner_title_height + 12, 108, 164)
local row_height = math.max(11, (panel_height - 30) / max_rows)
local panel_x = _screen.cx + (banner_width / 2) + (width / 2) + 10
local banner_top = banner_y - (banner_height / 2)
local panel_y = banner_top + (panel_height / 2)

local t = Def.ActorFrame{
	Name="OnlineFinalRanking",
	InitCommand=function(self)
		-- Upper evaluation data, including the P2 grade, uses draworder 20 and
		-- song identity uses 30.  Keep the online result board above both.
		self:xy(panel_x, panel_y):draworder(40):visible(false)
	end,
	OnCommand=function(self)
		if ITGOnline and ITGOnline.ReplayCurrentPlayState then
			ITGOnline:ReplayCurrentPlayState("final_ranking_on")
		end
		self:queuecommand("Refresh")
	end,
	OnlineLobbyStateMessageCommand=function(self)
		if has_final_ranking_context() then
			final_ranking_trace("message_online_lobby_state")
		end
		self:queuecommand("Refresh")
	end,
	ITGOnlinePlayStateUpdatedMessageCommand=function(self)
		if has_final_ranking_context() then
			final_ranking_trace("message_play_state_updated")
		end
		self:queuecommand("Refresh")
	end,
	RefreshCommand=function(self)
		self:stoptweening()
		if not has_final_ranking_context() then
			self:visible(false)
			self.polling_active = false
			self.polling_scheduled = false
			self.lastFinalRankingSignature = ""
			return
		end
		local rows = final_results()
		local show = #rows > 0
		local shouldPoll = should_poll_final_results()
		local signature = final_results_signature(rows)
		if signature == tostring(self.lastFinalRankingSignature or "") then
			self.polling_active = shouldPoll
			schedule_refresh(self)
			final_ranking_trace("refresh_skipped reason=duplicate_signature rows=" .. tostring(#rows))
			return
		end
		self.lastFinalRankingSignature = signature
		self:visible(show)
		self.polling_active = shouldPoll
		final_ranking_trace("refresh show=" .. tostring(show == true)
			.. " rows=" .. tostring(#rows)
			.. " room=" .. tostring(ITGOnline and ITGOnline.currentRoomId or "nil")
			.. " phase=" .. tostring(ITGOnline and ITGOnline.currentRoom and ITGOnline.currentRoom.phase or "nil")
			.. " polling=" .. tostring(self.polling_active == true)
			.. " signature=" .. tostring(signature)
			.. " rowsSummary=" .. final_ranking_rows_summary(rows))

		if show then
			self:GetChild("Title"):settext(localized("OnlineFinalRanking", "Online ranking"))
			for i = 1, max_rows do
				local row = self:GetChild("Row" .. tostring(i))
				local data = rows[i]
				if row and data then
					local percent = tonumber(data.displayed_percent) or 0
					local suffix = data.failed and " F" or ""
					local line = string.format("%d. %s  %.2f%%%s", data.rank, data.name, percent, suffix)
					row:settext(line)
					row:maxwidth((width - 20) / row_zoom)
					row:diffuse(data.failed and color("#ff3b30") or Color.White)
					row:visible(true)
					final_ranking_trace("row_visible"
						.. " slot=" .. tostring(i)
						.. " rank=" .. tostring(data.rank or "nil")
						.. " user=" .. tostring(data.user_id or "nil")
						.. " name=" .. tostring(data.name or "nil")
						.. " displayed_percent=" .. tostring(data.displayed_percent or "nil")
						.. " score_percent=" .. tostring(data.score_percent or "nil")
						.. " accuracy=" .. tostring(data.accuracy or "nil")
						.. " score=" .. tostring(data.score or "nil")
						.. " failed=" .. tostring(data.failed == true)
						.. " source=" .. tostring(data.source or "nil"))
				elseif row then
					row:visible(false)
					final_ranking_trace("row_hidden slot=" .. tostring(i))
				end
			end
		end

		schedule_refresh(self)
	end,
	PollCommand=function(self)
		self.polling_scheduled = false
		self:queuecommand("Refresh")
	end,

	Def.Quad{
		Name="Background",
		InitCommand=function(self)
			self:setsize(width, panel_height)
				:diffuse(color("#101820"))
				:diffusealpha(0.82)
		end,
	},

	LoadFont("Common Bold")..{
		Name="Title",
		InitCommand=function(self)
			self:horizalign(left)
				:xy(-width / 2 + 10, -panel_height / 2 + 9)
				:zoom(0.38)
				:maxwidth((width - 20) / 0.38)
				:diffuse(color("#00d8ff"))
		end,
	},
}

for i = 1, max_rows do
	t[#t+1] = LoadFont("Common Normal")..{
		Name="Row" .. tostring(i),
		InitCommand=function(self)
			self:horizalign(left)
				:xy(-width / 2 + 10, -panel_height / 2 + 31 + ((i - 1) * row_height))
				:zoom(row_zoom)
				:maxwidth((width - 20) / row_zoom)
				:visible(false)
		end,
	}
end

return t
