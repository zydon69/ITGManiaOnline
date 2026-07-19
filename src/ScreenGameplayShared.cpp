#include "ScreenGameplayShared.h"

#include <vector>

#include "Difficulty.h"
#include "GameState.h"
#include "InputEventPlus.h"
#include "PerfDiagnostics.h"
#include "PlayerNumber.h"
#include "RageLog.h"
#include "Screen.h"
#include "ScreenGameplay.h"

REGISTER_SCREEN_CLASS(ScreenGameplayShared);

namespace {
bool IsSharedGameplayPlayer(const PlayerNumber pn) {
  return pn == PLAYER_1 || pn == PLAYER_2;
}
}  // namespace

void ScreenGameplayShared::FillPlayerInfo(
    std::vector<PlayerInfo>& vPlayerInfoOut) {
  vPlayerInfoOut.clear();
  vPlayerInfoOut.resize(NUM_PLAYERS);

  if (GAMESTATE == nullptr) {
    LOG->Warn("ScreenGameplayShared::FillPlayerInfo called without GAMESTATE.");
    return;
  }

  const PlayerNumber master = GAMESTATE->GetMasterPlayerNumber();
  if (!IsSharedGameplayPlayer(master)) {
    LOG->Warn("ScreenGameplayShared::FillPlayerInfo ignored invalid master "
              "player %d.",
              master);
    return;
  }

  /* Routine has one chart, one score keeper, and one life meter.  Participant
   * statistics have dedicated StageStats slots and do not require a second
   * Player actor.  Loading an invisible second actor would still update and
   * judge the full chart, producing duplicate misses, offsets and keysounds. */
  vPlayerInfoOut[master].Load(
      master, MultiPlayer_Invalid, true, Difficulty_Invalid);
  LogRoutineCoupleDiagnostics(
      "component=gameplay_shared event=player_info_loaded master=%d infos=%zu "
      "active_actor_count=1",
      static_cast<int>(master), vPlayerInfoOut.size());
}

PlayerInfo* ScreenGameplayShared::GetPlayerInfoForInput(
    const InputEventPlus& iep) {
  if (GAMESTATE == nullptr) {
    LOG->Warn("ScreenGameplayShared::GetPlayerInfoForInput called without "
              "GAMESTATE.");
    return nullptr;
  }

  const PlayerNumber master = GAMESTATE->GetMasterPlayerNumber();
  if (!IsSharedGameplayPlayer(master) ||
      static_cast<size_t>(master) >= m_vPlayerInfo.size()) {
    LogRoutineCoupleDiagnostics(
        "component=gameplay_shared event=input_route_rejected source=%d "
        "master=%d infos=%zu",
        static_cast<int>(iep.pn), static_cast<int>(master),
        m_vPlayerInfo.size());
    return nullptr;
  }
  LogRoutineCoupleDiagnostics(
      "component=gameplay_shared event=input_routed source=%d master=%d "
      "controller=%d button=%d type=%d",
      static_cast<int>(iep.pn), static_cast<int>(master),
      static_cast<int>(iep.GameI.controller),
      static_cast<int>(iep.GameI.button), static_cast<int>(iep.type));
  return &m_vPlayerInfo[master];
}

/*
 * (c) 2006 Steve Checkoway
 * All rights reserved.
 *
 * Permission is hereby granted, free of charge, to any person obtaining a
 * copy of this software and associated documentation files (the
 * "Software"), to deal in the Software without restriction, including
 * without limitation the rights to use, copy, modify, merge, publish,
 * distribute, and/or sell copies of the Software, and to permit persons to
 * whom the Software is furnished to do so, provided that the above
 * copyright notice(s) and this permission notice appear in all copies of
 * the Software and that both the above copyright notice(s) and this
 * permission notice appear in supporting documentation.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS
 * OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
 * MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT OF
 * THIRD PARTY RIGHTS. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR HOLDERS
 * INCLUDED IN THIS NOTICE BE LIABLE FOR ANY CLAIM, OR ANY SPECIAL INDIRECT
 * OR CONSEQUENTIAL DAMAGES, OR ANY DAMAGES WHATSOEVER RESULTING FROM LOSS
 * OF USE, DATA OR PROFITS, WHETHER IN AN ACTION OF CONTRACT, NEGLIGENCE OR
 * OTHER TORTIOUS ACTION, ARISING OUT OF OR IN CONNECTION WITH THE USE OR
 * PERFORMANCE OF THIS SOFTWARE.
 */
