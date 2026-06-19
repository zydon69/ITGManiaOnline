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

local function final_ranking_trace(message)
	if not (ITGOnline and (ITGOnline.debugOnlineTrace == true or ITGOnline.debugReadyFlow == true)) then
		return
	end
	local line = "ITG Online: FLOW final_ranking " .. tostring(message or "")
	if Trace then Trace(line) elseif Warn then Warn(line) end
end

local function final_results()
	if not (ITGOnline and ITGOnline.currentRoom and ITGOnline.currentRoom.play_state) then
		final_ranking_trace("final_results_empty reason=missing_context"
			.. " room=" .. tostring(ITGOnline and ITGOnline.currentRoomId or "nil")
			.. " hasRoom=" .. tostring(ITGOnline and ITGOnline.currentRoom ~= nil)
			.. " hasPlayState=" .. tostring(ITGOnline and ITGOnline.currentRoom and ITGOnline.currentRoom.play_state ~= nil))
		return {}
	end

	local results = ITGOnline.currentRoom.play_state.final_results
	if type(results) ~= "table" then
		final_ranking_trace("final_results_empty reason=invalid_results"
			.. " type=" .. tostring(type(results))
			.. " phase=" .. tostring(ITGOnline.currentRoom.phase or "nil"))
		return {}
	end

	final_ranking_trace("final_results_begin raw=" .. tostring(#results)
		.. " room=" .. tostring(ITGOnline.currentRoomId or "nil")
		.. " phase=" .. tostring(ITGOnline.currentRoom.phase or "nil"))
	local normalized = {}
	for index, result in ipairs(results) do
		if type(result) == "table" then
			local user = type(result.user) == "table" and result.user or {}
			normalized[#normalized + 1] = {
				rank = tonumber(result.rank) or index,
				name = online_display_name(user, localized("OnlineUnknownPlayer", "Player")),
				score = math.floor(tonumber(result.score) or 0),
				score_percent = tonumber(result.score_percent),
				accuracy = tonumber(result.accuracy),
				failed = result.failed and true or false,
			}
		end
	end

	table.sort(normalized, function(a, b)
		return (tonumber(a.rank) or 0) < (tonumber(b.rank) or 0)
	end)

	final_ranking_trace("final_results_end rows=" .. tostring(#normalized))
	return normalized
end

local width = clamp(_screen.w * 0.16, 230, 320)
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
		self:xy(panel_x, panel_y):visible(false)
	end,
	OnCommand=function(self)
		self:queuecommand("Refresh")
	end,
	OnlineLobbyStateMessageCommand=function(self)
		final_ranking_trace("message_online_lobby_state")
		self:queuecommand("Refresh")
	end,
	ITGOnlinePlayStateUpdatedMessageCommand=function(self)
		final_ranking_trace("message_play_state_updated")
		self:queuecommand("Refresh")
	end,
	RefreshCommand=function(self)
		self:stoptweening()
		local rows = final_results()
		local show = #rows > 0
		self:visible(show)
		self.polling_active = show
		final_ranking_trace("refresh show=" .. tostring(show == true)
			.. " rows=" .. tostring(#rows)
			.. " room=" .. tostring(ITGOnline and ITGOnline.currentRoomId or "nil")
			.. " phase=" .. tostring(ITGOnline and ITGOnline.currentRoom and ITGOnline.currentRoom.phase or "nil")
			.. " polling=" .. tostring(self.polling_active == true))

		if show then
			self:GetChild("Title"):settext(localized("OnlineFinalRanking", "Online ranking"))
			for i = 1, max_rows do
				local row = self:GetChild("Row" .. tostring(i))
				local data = rows[i]
				if row and data then
					local percent = data.score_percent or data.accuracy or 0
					local suffix = data.failed and " F" or ""
					local line = string.format("%d. %s  %.2f%%%s", data.rank, data.name, percent, suffix)
					row:settext(line)
					row:maxwidth(width / 0.42)
					row:diffuse(data.failed and color("#ff3b30") or Color.White)
					row:visible(true)
				elseif row then
					row:visible(false)
				end
			end
		end

		if self.polling_active then
			self:sleep(0.5):queuecommand("Refresh")
		end
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
				:zoom(0.42)
				:maxwidth((width - 20) / 0.42)
				:visible(false)
		end,
	}
end

return t
