-- Extra reliability path: push live score whenever judgments update gameplay state.
-- This runs independently from score text visibility/layout.

local function primary_enabled_player()
	local enabled = GAMESTATE:GetEnabledPlayers()
	return enabled and enabled[1] or nil
end

return Def.Actor{
	JudgmentMessageCommand=function(self, params)
		if not (ITGOnline and ITGOnline.QueueLiveScore and ITGOnline.currentRoomId and ITGOnline.currentRoom) then return end

		local primary = primary_enabled_player()
		if primary and params and params.Player and params.Player ~= primary then return end

		local snapshot = ITGOnline.lastDisplayedScoreSnapshot
		if not snapshot and ITGOnline.BuildCurrentScoreSnapshot then
			snapshot = ITGOnline:BuildCurrentScoreSnapshot()
		end
		if snapshot then ITGOnline:QueueLiveScore(snapshot) end
	end,
}
