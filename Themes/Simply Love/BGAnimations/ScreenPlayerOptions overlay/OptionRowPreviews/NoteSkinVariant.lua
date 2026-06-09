local t = ...
local preview_path = THEME:GetPathB("", "_modules/NoteSkinPreview.lua")
local choices = CustomOptionRow("NoteSkin").Choices
local active_noteskins = {}
local active_variants = {}
local active_noteskin_count = 0
local active_variant_count = 0
local loaded_previews = {}
local variant_count = 0
local skipped_variant_count = 0

local function remember_active_noteskin(noteskin)
	if not noteskin or active_noteskins[noteskin] then return end
	active_noteskins[noteskin] = true
	active_noteskin_count = active_noteskin_count + 1
end

local function remember_active_variant(noteskin, variant)
	if not variant or variant == noteskin or active_variants[variant] then return end
	active_variants[variant] = true
	active_variant_count = active_variant_count + 1
end

for player in ivalues(GAMESTATE:GetHumanPlayers()) do
	local pn = ToEnumShortString(player)
	local mods = SL[pn] and SL[pn].ActiveModifiers
	if mods then
		remember_active_noteskin(mods.NoteSkin)
		remember_active_variant(mods.NoteSkin, mods.NoteSkinVariant)
	end
end

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

for variant in pairs(active_variants) do
	add_preview(variant)
end

-- Add only the variant actors that can be displayed immediately.  The base
-- NoteSkin preview for every selectable NoteSkin is already loaded by
-- NoteSkin.lua, and OptionRow Frame.lua falls back to that actor when a
-- NoteSkinVariant-specific preview is not present.
for noteskin in ivalues(choices) do
	local variants = NOTESKIN:GetVariantNamesForNoteSkin(noteskin)

	-- Variant previews are expensive because each one builds a real NoteSkin
	-- actor.  Load the complete variant set only for NoteSkins currently used
	-- by joined players.
	if active_noteskins[noteskin] and variants and #variants > 0 then
		for _, variant in ipairs(variants) do
			add_preview(variant)
		end
	elseif variants then
		skipped_variant_count = skipped_variant_count + #variants
	end
end

if Trace then
	Trace(
		("ScreenPlayerOptions previews: NoteSkinVariant variants=%d skipped_variants=%d active_noteskins=%d active_variants=%d")
		:format(variant_count, skipped_variant_count, active_noteskin_count, active_variant_count)
	)
end
