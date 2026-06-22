#include "ScoreDisplayAliveTime.h"

#include <cmath>

#include "ActorUtil.h"
#include "BitmapText.h"
#include "GameState.h"
#include "LuaManager.h"
#include "MessageManager.h"
#include "PlayerNumber.h"
#include "RageLog.h"
#include "RageUtil.h"
#include "StageStats.h"
#include "StatsManager.h"
#include "XmlFile.h"
#include "global.h"

REGISTER_ACTOR_CLASS(ScoreDisplayAliveTime);

namespace {
void WarnScoreDisplayAliveTimeAuditFix(const char* message) {
  if (LOG != nullptr) {
    LOG->Warn("%s", message);
  }
}

void TraceScoreDisplayAliveTimeAuditFix(const char* message) {
  if (LOG != nullptr) {
    LOG->Trace("%s", message);
  }
}

bool IsValidPlayerNumber(PlayerNumber pn) {
  return pn >= PLAYER_1 && pn < NUM_PLAYERS;
}

bool IsValidMultiPlayer(MultiPlayer mp) {
  return mp >= MultiPlayer_P1 && mp < NUM_MultiPlayer;
}
}  // namespace

ScoreDisplayAliveTime::ScoreDisplayAliveTime() {
  m_PlayerNumber = PLAYER_INVALID;
  m_MultiPlayer = MultiPlayer_Invalid;
}

ScoreDisplayAliveTime::~ScoreDisplayAliveTime() {}

void ScoreDisplayAliveTime::LoadFromNode(const XNode* pNode) {
  if (pNode == nullptr) {
    WarnScoreDisplayAliveTimeAuditFix(
        "SRC_AUDIT_FIX SRC-1099: ScoreDisplayAliveTime ignored null XML "
        "node.");
    return;
  }
  BitmapText::LoadFromNode(pNode);

  if (LUA != nullptr) {
    Lua* L = LUA->Get();
    bool b = false;
    bool b2 = false;
    if (L != nullptr) {
      b = pNode->PushAttrValue(L, "PlayerNumber");
      if (b) {
        LuaHelpers::Pop(L, m_PlayerNumber);
      } else {
        lua_pop(L, 1);
      }
      b2 = pNode->PushAttrValue(L, "MultiPlayer");
      if (b2) {
        LuaHelpers::Pop(L, m_MultiPlayer);
      } else {
        lua_pop(L, 1);
      }
    }
    if (!b && !b2) {
      WarnScoreDisplayAliveTimeAuditFix(
          "SRC_AUDIT_FIX SRC-237: ScoreDisplayAliveTime missing PlayerNumber "
          "or MultiPlayer attribute.");
    }
    if (b && !IsValidPlayerNumber(m_PlayerNumber)) {
      WarnScoreDisplayAliveTimeAuditFix(
          "SRC_AUDIT_FIX SRC-237: ScoreDisplayAliveTime ignored invalid "
          "PlayerNumber.");
      m_PlayerNumber = PLAYER_INVALID;
    }
    if (b2 && !IsValidMultiPlayer(m_MultiPlayer)) {
      WarnScoreDisplayAliveTimeAuditFix(
          "SRC_AUDIT_FIX SRC-237: ScoreDisplayAliveTime ignored invalid "
          "MultiPlayer.");
      m_MultiPlayer = MultiPlayer_Invalid;
    }
    if (L != nullptr) {
      LUA->Release(L);
    }
  } else {
    WarnScoreDisplayAliveTimeAuditFix(
        "SRC_AUDIT_FIX SRC-1099: ScoreDisplayAliveTime loaded without LUA.");
  }
}

void ScoreDisplayAliveTime::Update(float fDelta) {
  UpdateNumber();
  BitmapText::Update(fDelta);
}

void ScoreDisplayAliveTime::HandleMessage(const Message& msg) {
  // TODO: Add handling of GoalComplete message
  BitmapText::HandleMessage(msg);
}

void ScoreDisplayAliveTime::UpdateNumber() {
  if (GAMESTATE == nullptr || STATSMAN == nullptr) {
    TraceScoreDisplayAliveTimeAuditFix(
        "SRC_AUDIT_FIX SRC-1101: ScoreDisplayAliveTime skipped update without "
        "game/stat manager.");
    SetText(SecondsToMMSSMsMs(0));
    return;
  }

  float fSecsIntoPlay = 0;
  if (IsValidPlayerNumber(m_PlayerNumber) &&
      GAMESTATE->IsPlayerEnabled(m_PlayerNumber)) {
    fSecsIntoPlay =
        STATSMAN->GetAccumPlayedStageStats()
            .m_player[m_PlayerNumber]
            .m_fAliveSeconds +
        STATSMAN->m_CurStageStats.m_player[m_PlayerNumber].m_fAliveSeconds;
  }
  if (IsValidMultiPlayer(m_MultiPlayer) &&
      GAMESTATE->IsMultiPlayerEnabled(m_MultiPlayer)) {
    fSecsIntoPlay = STATSMAN->GetAccumPlayedStageStats().m_fGameplaySeconds +
                    STATSMAN->m_CurStageStats.m_fGameplaySeconds;
  }
  if (!std::isfinite(fSecsIntoPlay) || fSecsIntoPlay < 0.0f) {
    TraceScoreDisplayAliveTimeAuditFix(
        "SRC_AUDIT_FIX SRC-1101: ScoreDisplayAliveTime corrected invalid "
        "seconds.");
    fSecsIntoPlay = 0.0f;
  }

  SetText(SecondsToMMSSMsMs(fSecsIntoPlay));
}

// lua start
#include "LuaBinding.h"

/** @brief Allow Lua to have access to the ScoreDisplayAliveTime. */
class LunaScoreDisplayAliveTime : public Luna<ScoreDisplayAliveTime> {
 public:
  LunaScoreDisplayAliveTime() {}
};

LUA_REGISTER_DERIVED_CLASS(ScoreDisplayAliveTime, BitmapText)

// lua end

/*
 * (c) 2001-2004 Chris Danford
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
