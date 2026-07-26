local t = ...
local selected_judgments = {}
local selected_count = 0
local loaded_count = 0
local deferred_count = 0

local function remember_selected_judgment(judgment)
	if not judgment or selected_judgments[judgment] then return end
	selected_judgments[judgment] = true
	selected_judgments[StripSpriteHints(judgment)] = true
	selected_count = selected_count + 1
end

for player in ivalues(GAMESTATE:GetHumanPlayers()) do
	local pn = ToEnumShortString(player)
	local mods = SL[pn] and SL[pn].ActiveModifiers
	if mods then
		remember_selected_judgment(mods.JudgmentGraphic)
	end
end

local judgment_graphics = GetJudgmentGraphics()
if selected_count == 0 then
	-- During the first online transition the engine can construct this overlay
	-- before GetHumanPlayers() exposes the active player. Loading every judgment
	-- in that transient state caused a multi-second cold-start stall. The first
	-- asset is Simply Love's deterministic default; any actual profile choice
	-- is loaded on demand by OptionRow Frame once player state is available.
	for judgment_filename in ivalues(judgment_graphics) do
		if judgment_filename ~= "None" then
			remember_selected_judgment(judgment_filename)
			break
		end
	end
end

for judgment_filename in ivalues(judgment_graphics) do
	local stripped_name = StripSpriteHints(judgment_filename)
	local should_load = judgment_filename == "None"
		or selected_judgments[judgment_filename] or selected_judgments[stripped_name]

	if should_load and judgment_filename ~= "None" then
		t[#t+1] = LoadActor( THEME:GetPathG("", "_judgments/" .. judgment_filename) )..{
			Name="JudgmentGraphic_"..stripped_name,
			InitCommand=function(self)
				self:visible(false):animate(false)
			end
		}
		loaded_count = loaded_count + 1
	elseif should_load then
		t[#t+1] = Def.Actor{ Name="JudgmentGraphic_None", InitCommand=function(self) self:visible(false) end }
		loaded_count = loaded_count + 1
	else
		deferred_count = deferred_count + 1
	end
end

if Trace then
	Trace(
		("ScreenPlayerOptions previews: JudgmentGraphic loaded=%d deferred=%d selected=%d")
		:format(loaded_count, deferred_count, selected_count)
	)
end
