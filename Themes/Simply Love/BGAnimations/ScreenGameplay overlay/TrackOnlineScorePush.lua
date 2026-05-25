-- Extra reliability path: push live score whenever judgments update gameplay state.
-- This runs independently from score text visibility/layout.

local function online_connected()
	if not (GetOnlineHandlerInstance and ITGOnline) then return false end
	local handler = GetOnlineHandlerInstance()
	if not handler then return false end
	return handler.connected and handler.socket ~= nil
end

local function primary_enabled_player()
	local enabled = GAMESTATE:GetEnabledPlayers()
	return enabled and enabled[1] or nil
end

return Def.Actor{
	JudgmentMessageCommand=function(self, params)
		if not (ITGOnline and ITGOnline.SendScore and ITGOnline.currentRoom) then return end
		if not online_connected() then return end

		local primary = primary_enabled_player()
		if primary and params and params.Player and params.Player ~= primary then return end

		ITGOnline:SendScore(true, false, ITGOnline.lastDisplayedScoreSnapshot)
	end,
}
