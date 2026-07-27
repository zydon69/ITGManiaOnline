local t = ...
local preview_path = THEME:GetPathB("", "_modules/NoteSkinPreview.lua")
local choices = CustomOptionRow("NoteSkin").Choices
local loaded_previews = {}
local selected_previews = {}
local variant_count = 0

local function add_preview(noteskin)
	if not noteskin or loaded_previews[noteskin] then return end

	loaded_previews[noteskin] = true
	t[#t+1] = LoadActor(preview_path, {
		noteskin_name=noteskin,
		using_variant=true,
		preview_zoom=0.80,
		freeze_preview=false
	})
	variant_count = variant_count + 1
end

for player in ivalues(GAMESTATE:GetHumanPlayers()) do
	local pn = ToEnumShortString(player)
	local mods = SL[pn] and SL[pn].ActiveModifiers
	local selected_variant = mods and (mods.NoteSkinVariant or mods.NoteSkin)
	if selected_variant and selected_variant ~= "" then
		selected_previews[selected_variant] = true
	end
end

if next(selected_previews) == nil and choices[1] then
	selected_previews[choices[1]] = true
end

for noteskin in pairs(selected_previews) do
	add_preview(noteskin)
end

if Trace then
	Trace(("ScreenPlayerOptions previews: NoteSkinVariant loaded=%d deferred=true")
		:format(variant_count))
end
