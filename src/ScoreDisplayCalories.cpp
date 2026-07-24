#include "ScoreDisplayCalories.h"

#include <algorithm>
#include <cmath>

#include "ActorUtil.h"
#include "BitmapText.h"
#include "LuaManager.h"
#include "MessageManager.h"
#include "PlayerNumber.h"
#include "RageLog.h"
#include "RollingNumbers.h"
#include "StageStats.h"
#include "StatsManager.h"
#include "XmlFile.h"
#include "global.h"

REGISTER_ACTOR_CLASS(ScoreDisplayCalories);

namespace {
void WarnScoreDisplayCaloriesSafety(const char* message) {
  if (LOG != nullptr) {
    LOG->Warn("%s", message);
  }
}

void TraceScoreDisplayCaloriesSafety(const char* message) {
  if (LOG != nullptr) {
    LOG->Trace("%s", message);
  }
}

bool IsValidPlayerNumber(PlayerNumber pn) {
  return pn >= PLAYER_1 && pn < NUM_PLAYERS;
}
}  // namespace

ScoreDisplayCalories::ScoreDisplayCalories() {
  m_PlayerNumber = PLAYER_INVALID;
}

ScoreDisplayCalories::~ScoreDisplayCalories() {
  if (MESSAGEMAN != nullptr && m_sMessageOnStep != "") {
    MESSAGEMAN->Unsubscribe(this, m_sMessageOnStep);
    m_sMessageOnStep.clear();
  }
}

void ScoreDisplayCalories::LoadFromNode(const XNode* pNode) {
  if (pNode == nullptr) {
    WarnScoreDisplayCaloriesSafety(
        "ScoreDisplayCalories ignored null XML node.");
    return;
  }
  RollingNumbers::LoadFromNode(pNode);

  if (LUA != nullptr) {
    Lua* L = LUA->Get();
    bool b = false;
    if (L != nullptr) {
      b = pNode->PushAttrValue(L, "PlayerNumber");
    }
    if (b) {
      LuaHelpers::Pop(L, m_PlayerNumber);
      if (!IsValidPlayerNumber(m_PlayerNumber)) {
        WarnScoreDisplayCaloriesSafety(
            "ScoreDisplayCalories ignored invalid "
            "PlayerNumber.");
        m_PlayerNumber = PLAYER_INVALID;
      }
    } else {
      if (L != nullptr) {
        lua_pop(L, 1);
      }
      WarnScoreDisplayCaloriesSafety(
          "ScoreDisplayCalories missing PlayerNumber "
          "attribute.");
      m_PlayerNumber = PLAYER_INVALID;
    }
    if (L != nullptr) {
      LUA->Release(L);
    }
  } else {
    WarnScoreDisplayCaloriesSafety(
        "ScoreDisplayCalories loaded without LUA.");
  }

  if (MESSAGEMAN != nullptr) {
    if (m_sMessageOnStep != "") {
      MESSAGEMAN->Unsubscribe(this, m_sMessageOnStep);
    }
    m_sMessageOnStep = "Step";
    MESSAGEMAN->Subscribe(this, m_sMessageOnStep);
  }
}

void ScoreDisplayCalories::Update(float fDelta) {
  // We have to set the initial text after
  // StatsManager::CalcAccumPlayedStageStats is called.
  if (IsFirstUpdate()) {
    UpdateNumber();
  }

  RollingNumbers::Update(fDelta);
}

void ScoreDisplayCalories::HandleMessage(const Message& msg) {
  if (msg.GetName() == "Step") {
    PlayerNumber pn = PLAYER_INVALID;
    if (LUA != nullptr && msg.GetParam("PlayerNumber", pn) &&
        IsValidPlayerNumber(pn) && pn == m_PlayerNumber) {
      UpdateNumber();
    }
  }

  RollingNumbers::HandleMessage(msg);
}

void ScoreDisplayCalories::UpdateNumber() {
  if (!IsValidPlayerNumber(m_PlayerNumber)) {
    TraceScoreDisplayCaloriesSafety(
        "ScoreDisplayCalories skipped update with "
        "invalid PlayerNumber.");
    SetTargetNumber(0);
    return;
  }
  if (STATSMAN == nullptr) {
    TraceScoreDisplayCaloriesSafety(
        "ScoreDisplayCalories skipped update without "
        "StatsManager.");
    SetTargetNumber(0);
    return;
  }

  float fCals =
      STATSMAN->GetAccumPlayedStageStats()
          .m_player[m_PlayerNumber]
          .m_fCaloriesBurned +
      STATSMAN->m_CurStageStats.m_player[m_PlayerNumber].m_fCaloriesBurned;
  if (!std::isfinite(fCals) || fCals < 0.0f) {
    TraceScoreDisplayCaloriesSafety(
        "ScoreDisplayCalories corrected invalid "
        "calories.");
    fCals = std::max(0.0f, std::isfinite(fCals) ? fCals : 0.0f);
  }

  SetTargetNumber(fCals);
}

// lua start
#include "LuaBinding.h"

/** @brief Allow Lua to have access to the ScoreDisplayCalories. */
class LunaScoreDisplayCalories : public Luna<ScoreDisplayCalories> {
 public:
  LunaScoreDisplayCalories() {}
};

LUA_REGISTER_DERIVED_CLASS(ScoreDisplayCalories, BitmapText)

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
