if not PREFSMAN:GetPreference("EventMode") then return end
-- -----------------------------------------------------------------------

local player = ...
local pn = ToEnumShortString(player)

local FailOnMissedTarget    = SL[pn].ActiveModifiers.ActionOnMissedTarget == "Fail"
local RestartOnMissedTarget = SL[pn].ActiveModifiers.ActionOnMissedTarget == "Restart"

local args = {
	TargetGradeMissedMessageCommand=function(self, params)
		if params.Player == player then
			if FailOnMissedTarget then
				-- Use the engine's internal "SM_BeginFailed" message to *immediately* leave ScreenGameplay.
				--   An alternative would be "SM_NotesEnded" which queue's ScreenGameplay's "out" transition (a fade to black in SL).
				-- For more on SM_xxx messages:
				--   https://quietly-turning.github.io/Lua-For-SM5/LuaAPI#Screens-Screen-PostScreenMessage
				--   https://github.com/stepmania/stepmania/blob/1c869edab5/Docs/Themerdocs/ScreenMessages.txt

				-- Force fail the player on this stage, since for some reason it treats the score as a pass
				-- (and submits to GrooveStats!!) otherwise.
				local pss = STATSMAN:GetCurStageStats():GetPlayerStageStats(player)
				pss:FailPlayer()
				
				SCREENMAN:GetTopScreen():PostScreenMessage("SM_BeginFailed", 0)

			elseif RestartOnMissedTarget then
				if ITGOnline and ITGOnline.currentRoomId then
					if type(online_flow_trace) == "function" then
						online_flow_trace("gameplay_restart_blocked"
							.. " reason=target_score_restart"
							.. " room=" .. tostring(ITGOnline.currentRoomId or "nil")
							.. " player=" .. tostring(pn))
					end
					return
				end
				-- EventMode is assumed (i.e. not CoinMode_Pay), so no need to fuss with managing stage counts for SL or SM
				SCREENMAN:GetTopScreen():SetPrevScreenName("ScreenGameplay"):SetNextScreenName("ScreenGameplay"):begin_backing_out()
			end
		end
	end
}

return Def.Actor(args)
