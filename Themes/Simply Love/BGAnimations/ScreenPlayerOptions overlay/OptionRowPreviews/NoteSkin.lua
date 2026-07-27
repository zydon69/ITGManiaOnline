local t = ...
local preview_path = THEME:GetPathB("", "_modules/NoteSkinPreview.lua")
local choices = CustomOptionRow("NoteSkin").Choices
local selected = {}
local loaded = 0

for player in ivalues(GAMESTATE:GetHumanPlayers()) do
	local pn = ToEnumShortString(player)
	local mods = SL[pn] and SL[pn].ActiveModifiers
	local noteskin = mods and mods.NoteSkin
	if noteskin and noteskin ~= "" then selected[noteskin] = true end
end

-- A screen can be constructed just before GAMESTATE exposes its human player.
-- Keep one deterministic fallback; every other preview is materialized when
-- its option row first requests it.
if next(selected) == nil and choices[1] then
	selected[choices[1]] = true
end

for noteskin in ivalues(choices) do
	if selected[noteskin] then
		t[#t+1] = LoadActor(preview_path, {
			noteskin_name=noteskin,
			preview_zoom=0.80,
			freeze_preview=false
		})
		loaded = loaded + 1
	end
end

if Trace then
	Trace(("ScreenPlayerOptions previews: NoteSkin loaded=%d deferred=%d")
		:format(loaded, math.max(0, #choices - loaded)))
end
