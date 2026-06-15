local bg_width = WideScale(287,292)
local bg_height = 350
local padding = 10
local wrap_width = bg_width - padding*2

local explanation_bmt
local last_explanation_text = nil
local last_next_rows_text = nil
local last_option_row_name = nil

-- -----------------------------------------------------------------------
-- Build this map once and cache it globally. Recomputing it on every load of
-- ScreenOptionsService causes avoidable stalls during settings navigation.
SL.Global = SL.Global or {}
SL.Global.ScreenOptionsServiceCache = SL.Global.ScreenOptionsServiceCache or {}

local nextScreenOptRows = SL.Global.ScreenOptionsServiceCache.nextScreenOptRows
if not nextScreenOptRows then
	nextScreenOptRows = {}

	-- get the LineNames metric for ScreenOptionsService
	for childscreen_name in THEME:GetMetric("ScreenOptionsService", "LineNames"):gmatch('([^,]+)') do
		local s = ""
		local count = 0

	-- We can prepend "Screen" to the beginning of each child screen's Name to transform
	-- something like "InputOptions" into "ScreenInputOptions".
	-- From there, we can see metric's "ScreenInputOptions" has its own LineNames
	-- and split those on commas to get OptionRows that would be available on the next screen.
	--
	-- This is is not a safe assumption in other themes (or even everywhere in SL), but I've configured
	-- SL's metrics for ScreenOptionsService and children to Just Work™ for this sort of lookup.

		if THEME:HasMetric("Screen"..childscreen_name, "LineNames") then
			-- split the list of internal OptionRow names (e.g. "AutoMap,OnlyDedicatedMenu,OptionsNav,Debounce,ThreeKey,AxisFix") on commas
			for optrow_name in THEME:GetMetric("Screen"..childscreen_name, "LineNames"):gmatch('([^,]+)') do

			-- don't bother retrieving more than 6
				count = count + 1
				if count > 6 then
					-- if we've already got 6, append an ellipsis and break from the loop
					s = s .. "\n..."
					break
				end

			-- optrow_title will be the optrow_name localized for the current language (English, Spanish, Japanese, etc.)
				local optrow_title
				-- fmt will be the formatting string used
				-- if the next screen has conf-based OptionRows, present them here as a bulleted list
				-- if the next screen has OptionRows leading deeper to subscreens, present them here as-is
				local fmt

				-- the choices on the next screen are conf-based OptionRows that set Preferences
				-- (assumes the "Fallback" metric of each of these literally matches "ScreenOptionsServiceChild"
				--  which is brittle but works for now, because of how I've set up SL's metrics.)
					if THEME:GetMetric("Screen"..childscreen_name, "Fallback") == "ScreenOptionsServiceChild" then
						local _line = THEME:GetMetric("Screen"..childscreen_name, "Line"..optrow_name)

						if _line:match("conf,") then
							optrow_title = _line:gsub("conf,","")
						else
							optrow_title = optrow_name
						end
						fmt = "\n• %s"

				-- the choices on the next screen would take us deeper into sub-subscreens
				-- (assumes the "Fallback" metric of each of these literally matches "ScreenOptionsServiceSub"
				--  which is brittle but works for now, because of how I've set up SL's metrics.)
					elseif THEME:GetMetric("Screen"..childscreen_name, "Fallback") == "ScreenOptionsServiceSub" then
						optrow_title = optrow_name
						fmt = "\n %s"
					end

				-- localize if possible
					if type(optrow_title) == "string" and THEME:HasString("OptionTitles", optrow_title) then
						-- remove embedded newline characters so that "Allow Players\nTo Fail Set" becomes "Allow Players To Fail Set"
						s = s .. (fmt):format( THEME:GetString("OptionTitles", optrow_title):gsub("\n", " "))
					else
						s = s .. (fmt or "\n%s"):format(optrow_name)
					end
				end
			end

		nextScreenOptRows[childscreen_name] = s
	end

	SL.Global.ScreenOptionsServiceCache.nextScreenOptRows = nextScreenOptRows
end

-- -----------------------------------------------------------------------

local af = Def.ActorFrame{}

af.InitCommand=function(self)
	self:xy(WideScale(490,683), _screen.cy - 15.5)
end
af.OffCommand=function(self)
	last_option_row_name = nil
	last_explanation_text = nil
	last_next_rows_text = nil
end

-- this broadcast is done from SL's metrics.ini under
-- [OptionRowSimpleService] via TitleGainFocusCommand
-- We use it here to detect when the player scrolls to a different OptionRow
-- (that OptionRow has "gained focus") but has not yet chosen anything.
af.OptionRowChangedMessageCommand=function(self, params)
	if not params or not params.Title then return end
	local title_parent = params.Title:GetParent()
	if not title_parent then return end
	local row_actor = title_parent:GetParent()
	if not row_actor then return end
	local OptionRowName = row_actor:GetName()
	if OptionRowName == last_option_row_name then return end
	last_option_row_name = OptionRowName
	self:playcommand("Update", {Name=OptionRowName} )
end

-- -----------------------------------------------------------------------
-- verify certain settings/configurations are compatible with Simply Love
--    render-to-texture is needed for Simply Thonk but not possible with the d3d renderer
--    some StepMania game types (popn, beat, kickbox, etc.) are not supported in SL
--    SL only supports official StepMania releases, and a limited range of versions at that
af[#af+1] = LoadActor("./Support.lua")
-- -----------------------------------------------------------------------
af[#af+1] = LoadActor("./ActiveOptionRowState.lua")
-- -----------------------------------------------------------------------

-- background Quad for side pane
af[#af+1] = Def.Quad{
	InitCommand=function(self)
		self:zoomto(bg_width, bg_height)
		self:diffuse(DarkUI() and color("#666666") or color("#333333"))
	end
}

-- Option Explanation text
af[#af+1] = Def.BitmapText{
	Font="Common Normal",
	InitCommand=function(self)
		self:xy(-bg_width/2 + padding, -bg_height/2 + padding)
		self:vertalign(top):horizalign(left)
		self:_wrapwidthpixels(wrap_width)
		explanation_bmt = self
	end,
	UpdateCommand=function(self, params)
		if not params or not params.Name then return end
		local txt = THEME:GetString("OptionExplanations", params.Name)
		if txt ~= last_explanation_text then
			last_explanation_text = txt
			self:settext(txt):_wrapwidthpixels(wrap_width)
		end
	end
}

-- text for first six OptionRows on the next screen
af[#af+1] = Def.BitmapText{
	Font="Common Normal",
	InitCommand=function(self)
		self:x(-bg_width/2 + padding*2)
		self:vertalign(top):horizalign(left)
		self:_wrapwidthpixels(wrap_width)
	end,
	UpdateCommand=function(self, params)
		if not params or not params.Name then return end
		-- Name is passed in as a param from OptionRowChangedMessageCommand (above), which gets
		-- it from TitleGainFocusCommand under [OptionRowSimpleService] in SL's metrics.ini
		-- It will be the internal name for this OptionRow, like "SystemOptions" or "InputOptions" or "USBProfileOptions"
		--
		-- We'll use it to look up the help string associated with this OptionRow that just received focus
		-- within the nextScreenOptRows table.
		local s = nextScreenOptRows[params.Name] or ""

		-- set the y position of this list based on the height of the explanation text because that
		-- can vary (sometimes 2 lines, sometimes 3; sometimes different for different localizations)
		self:y(-bg_height/2 + padding + explanation_bmt:GetHeight())
		if s ~= last_next_rows_text then
			last_next_rows_text = s
			self:settext(s):_wrapwidthpixels(wrap_width)
		end
	end
}

return af
