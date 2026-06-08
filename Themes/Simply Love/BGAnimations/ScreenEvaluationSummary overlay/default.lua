local numStages = SL.Global.Stages.PlayedThisGame

local page = 1
local pages = math.ceil(numStages/4)
local next_page
local visible_stage_rows = math.min(4, math.max(numStages, 0))

-- start by assuming that the player has dedicated MenuButtons
local buttons = {
	-- previous page
	MenuLeft = -1,
	MenuUp = -1,
	-- next page
	MenuRight = 1,
	MenuDown = 1,
}

-- if OnlyDedicatedMenuButtons is disabled, add in support for navigating this screen with gameplay buttons
if not PREFSMAN:GetPreference("OnlyDedicatedMenuButtons") then
	-- previous page
	buttons.Left=-1
	buttons.Up=-1
	buttons.DownLeft=-1
	-- next page
	buttons.Right=1
	buttons.Down=1
	buttons.DownRight=1
end

local page_text = THEME:GetString("ScreenEvaluationSummary", "Page")
local online_max_rows = 8

-- -----------------------------------------------------------------------


-- Utility function to collect the names of all unique profiles that played at least one song
-- as player pn this session.
uniqueProfilesUsedForPlayer = function(pn)
	local extractProfile = function(stats)
		return stats.profile
	end
	local profilesUsed = map(extractProfile, SL[pn].Stages.Stats)
	return deduplicate(profilesUsed)
end

local online_final_results = function()
	if not (ITGOnline and ITGOnline.currentRoom and ITGOnline.currentRoom.play_state) then
		return {}
	end

	local results = ITGOnline.currentRoom.play_state.final_results
	if type(results) ~= "table" then
		return {}
	end

	local normalized = {}
	for index, result in ipairs(results) do
		local user = result.user or {}
		normalized[#normalized + 1] = {
			rank = tonumber(result.rank) or index,
			name = tostring(user.name or "Player"),
			score = math.floor(tonumber(result.score) or 0),
			accuracy = tonumber(result.accuracy) or 0,
			failed = result.failed and true or false,
		}
	end

	table.sort(normalized, function(a, b)
		return (tonumber(a.rank) or 0) < (tonumber(b.rank) or 0)
	end)

	return normalized
end


-- -----------------------------------------------------------------------

local t = Def.ActorFrame{
	-- this CodeMessage is defined in metrics.ini under [ScreenEvaluationSummary]
	-- it handles both page navigation and screenshot requests
	CodeMessageCommand=function(self, param)

		-- player wants to save a screenshot
		if param.Name == "Screenshot" then
			-- format a localized month string like "06-June" or "12-Diciembre"
			local month = ("%02d-%s"):format(MonthOfYear()+1, THEME:GetString("Months", "Month"..MonthOfYear()+1))

			-- organize screenshots Love into directories, like...
			--      ./Screenshots/Simply_Love/2020/04-April/2020-04-22_175951.png
			-- note that the engine's SaveScreenshot() function will convert whitespace
			-- characters to underscores, so we might as well just use underscores here
			local prefix = "Simply_Love/" .. Year() .. "/" .. month .. "/"

			-- for more info on SaveScreenshot(), see ./BGA/ScreenEvaluation common/ScreenshotHandler.lua
			SaveScreenshot(param.PlayerNumber, false, false, prefix)
		end

		if pages > 1 and buttons[param.Name] ~= nil then
			next_page = page + buttons[param.Name]

			if next_page > 0 and next_page < pages+1 then
				page = next_page
				self:finishtweening():queuecommand("Hide")
			end
		end
	end
}

-- centered text like "Page 2/5" where
-- 2 is the current page the player is viewing, and
-- 5 is the total number of pages
t[#t+1] = LoadFont("Common Bold")..{
	Name="PageNumber",
	Text=("%s %i/%i"):format(page_text, page, pages),
	InitCommand=function(self) self:diffusealpha(0):zoom(WideScale(0.5,0.6)):xy(_screen.cx, 15) end,
	OnCommand=function(self) self:sleep(0.1):decelerate(0.33):diffusealpha(1) end,
	OffCommand=function(self) self:accelerate(0.33):diffusealpha(0) end,
	HideCommand=function(self) self:sleep(0.5):settext( ("%s %i/%i"):format(page_text, page, pages) ) end
}

t[#t+1] = Def.ActorFrame{
	Name="OnlineFinalRanking",
	polling_active=false,
	InitCommand=function(self)
		self:xy(_screen.w - 190, _screen.cy - 110):visible(false)
	end,
	OnCommand=function(self)
		self:queuecommand("Refresh")
	end,
	OnlineLobbyStateMessageCommand=function(self)
		self:queuecommand("Refresh")
	end,
	ITGOnlinePlayStateUpdatedMessageCommand=function(self)
		self:queuecommand("Refresh")
	end,
	RefreshCommand=function(self)
		local rows = online_final_results()
		local show = #rows > 0
		self:visible(show)
		self.polling_active = show

		if show then
			self:GetChild("Title"):settext("Online final ranking")
			for i = 1, online_max_rows do
				local row = self:GetChild("Row" .. tostring(i))
				local data = rows[i]
				if row and data then
					local line = string.format("%d. %s  %d pts (%.2f%%)", data.rank, data.name, data.score, data.accuracy)
					if data.failed then
						line = line .. " ✖"
					end
					row:settext(line)
					row:diffuse(data.failed and color("#ff3b30") or color("#ffffff"))
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
	LoadFont("Common Bold")..{
		Name="Title",
		InitCommand=function(self)
			self:horizalign(left):xy(-140, -30):zoom(0.45):diffuse(Color.Yellow)
		end,
	},
}

for i = 1, online_max_rows do
	t[#t][#t[#t] + 1] = LoadFont("Common Normal")..{
		Name="Row" .. tostring(i),
		InitCommand=function(self)
			self:horizalign(left):xy(-140, -8 + ((i - 1) * 18)):zoom(0.4):visible(false)
		end,
	}
end


t[#t+1] = LoadActor("./LetterGrades.lua")
t[#t+1] = LoadActor(GetFallbackBanner())..{
	Name="SummaryFallbackBannerSource",
	InitCommand=function(self) self:visible(false) end
}

-- -----------------------------------------------------------------------
-- 4 rows
-- i will increment so that we progress down the screen from top to bottom
-- first song of the round at the top, more recently played song at the bottom

for i=1,visible_stage_rows do

	t[#t+1] = LoadActor("Row.lua", i)..{
		Name="StageStats_"..i,
		InitCommand=function(self) self:diffusealpha(0) end,
		OnCommand=function(self)
			self:xy(_screen.cx, ((_screen.h/4.75) * i))
				:queuecommand("Hide")
		end,
		ShowCommand=function(self)
			self:finishtweening():sleep(i*0.05):linear(0.15):diffusealpha(1)
		end,
		HideCommand=function(self)
			self:playcommand("DrawPage", {Page=page})
		end,
	}

end

-- -----------------------------------------------------------------------

return t
