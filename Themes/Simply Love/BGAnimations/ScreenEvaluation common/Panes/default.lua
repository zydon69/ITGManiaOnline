local NumPanes = ...
local players = GAMESTATE:GetHumanPlayers()
local lazy_pane_path = THEME:GetPathB("ScreenEvaluation", "common/Panes/LazyPane.lua")
local routine_shared = IsRoutine and IsRoutine()

local af = Def.ActorFrame{}
af.Name="Panes"

local offset = {
	[PLAYER_1] = _screen.cx-155,
	[PLAYER_2] = _screen.cx+155
}

local lazy_contexts = {}
local lazy_loaded = {}
local lazy_placeholder_count = 0

local function PaneIsAvailable(i, player)
	local pn = ToEnumShortString(player)

	if i == 2 then
		return SL.Global.GameMode == "ITG"
			and SL[pn]
			and SL[pn].ActiveModifiers
			and SL[pn].ActiveModifiers.ShowFaPlusPane
	end

	if i == 6 then
		if SL.Global.GameMode == "Casual" then return false end
		if not PREFSMAN:GetPreference("OnlyDedicatedMenuButtons") then return false end

		local game = GAMESTATE:GetCurrentGame():GetName()
		return game == "dance" or game == "pump" or game == "techno"
	end

	if i == 8 or i == 9 or i == 10 then
		return IsServiceAllowed(SL.GrooveStats.AutoSubmit)
	end

	if i == 11 then
		return not GAMESTATE:IsCourseMode()
	end

	return true
end

local function MakeLazyPane(i, player, controller, ComputedData)
	local controller_name = ToEnumShortString(controller)
	local name = ("Pane%i_Side%s"):format(i, controller_name)
	lazy_placeholder_count = lazy_placeholder_count + 1

	lazy_contexts[name] = {
		PaneIndex = i,
		PanePath = THEME:GetPathB("ScreenEvaluation", "common/Panes/Pane" .. tostring(i) .. "/default.lua"),
		Player = player,
		Controller = controller,
		ComputedData = ComputedData,
	}

	return Def.ActorFrame{
		Name=name,
		InitCommand=function(self)
			self:x(offset[controller]):visible(false)
		end,
		EnsureLoadedCommand=function(self)
			if lazy_loaded[name] then return end

			SL.Global.EvaluationLazyPaneRequest = lazy_contexts[name]
			local ok, added = pcall(function()
				return self:AddChildFromPathWithName(lazy_pane_path, "")
			end)
			SL.Global.EvaluationLazyPaneRequest = nil

			lazy_loaded[name] = ok and added == true
			if lazy_loaded[name] then
				local child = self:GetChild("")
				if child then
					child:playcommand("Begin")
					child:playcommand("On")
				end
				Trace(("ScreenEvaluation lazy pane loaded name=%s pane=%i player=%s controller=%s"):format(
					name,
					i,
					ToEnumShortString(player),
					controller_name
				))
			else
				Trace(("ScreenEvaluation lazy pane skipped name=%s pane=%i error=%s"):format(
					name,
					i,
					ok and "nil" or tostring(added)
				))
			end
		end,
	}
end

-- -----------------------------------------------------------------------
-- Note: Some of these Pane actors may be nil. This is not a bug, but
--       a feature for any panes we want to be conditional.  -teejusb

if routine_shared then
	local ComputedData = {}
	local mpn = GAMESTATE:GetMasterPlayerNumber()
	for i=1, NumPanes do
		if PaneIsAvailable(i, mpn) then
			af[#af+1] = MakeLazyPane(i, mpn, PLAYER_1, ComputedData)
			af[#af+1] = MakeLazyPane(i, mpn, PLAYER_2, ComputedData)
		end
	end
	if RoutineCoupleTrace then
		RoutineCoupleTrace("event=evaluation_panes_layout mode=routine source="
			.. tostring(ToEnumShortString(mpn))
			.. " controllers=2 shared_result=1")
	end

elseif #players == 2 or SL.Global.GameMode=="Casual" then
	for player in ivalues(players) do
		-- add Panes for this player to the ActorFrame using a simple, numerical for-loop
		for i=1, NumPanes do
			if PaneIsAvailable(i, player) then
				af[#af+1] = MakeLazyPane(i, player, player)
			end
		end
	end

elseif #players == 1 then
	-- Lazily load only the panes that are visible. Some panes (QR code,
	-- timing histogram, high-score lists, noteskin arrows) are expensive and
	-- used to be created up front even when the player never viewed them.
	-- ComputedData remains shared across both sides for panes that cache
	-- expensive calculations after they are actually opened.
	local ComputedData = {}
	local mpn = GAMESTATE:GetMasterPlayerNumber()

	for i=1, NumPanes do
		if PaneIsAvailable(i, mpn) then
			af[#af+1] = MakeLazyPane(i, mpn, PLAYER_1, ComputedData)
			af[#af+1] = MakeLazyPane(i, mpn, PLAYER_2, ComputedData)
		end
	end
end

Trace(("ScreenEvaluation lazy pane placeholders=%i players=%i game_mode=%s"):format(
	lazy_placeholder_count,
	#players,
	tostring(SL.Global.GameMode)
))

return af
