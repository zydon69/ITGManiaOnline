local t = ...
local preview_path = THEME:GetPathB("", "_modules/NoteSkinPreview.lua")
local loaded = 0

-- Add noteskin actors to the primary AF and hide them immediately.
-- We'll refer to these later via ActorProxy in ./Graphics/OptionRow Frame.lua
for noteskin in ivalues( CustomOptionRow("NoteSkin").Choices ) do
	t[#t+1] = LoadActor(preview_path, {noteskin_name=noteskin})
	loaded = loaded + 1
end

if Trace then
	Trace(("ScreenPlayerOptions previews: NoteSkin loaded=%d"):format(loaded))
end
