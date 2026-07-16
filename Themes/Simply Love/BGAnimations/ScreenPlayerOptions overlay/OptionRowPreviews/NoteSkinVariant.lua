local t = ...
local preview_path = THEME:GetPathB("", "_modules/NoteSkinPreview.lua")
local choices = CustomOptionRow("NoteSkin").Choices
local loaded_previews = {}
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

-- Option rows cannot add actors after the overlay has loaded.  Preload every
-- selectable variant so changing the base NoteSkin on this screen always has
-- a matching proxy target instead of silently falling back to the base skin.
for noteskin in ivalues(choices) do
	local variants = NOTESKIN:GetVariantNamesForNoteSkin(noteskin)
	if variants then
		for _, variant in ipairs(variants) do
			add_preview(variant)
		end
	end
end

if Trace then
	Trace(("ScreenPlayerOptions previews: NoteSkinVariant variants=%d preloaded_all=true")
		:format(variant_count))
end
