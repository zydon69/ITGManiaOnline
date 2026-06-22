#include "ScoreDisplayOni.h"

#include <cmath>

#include "ActorUtil.h"
#include "GameState.h"
#include "PlayerNumber.h"
#include "PlayerStageStats.h"
#include "PlayerState.h"
#include "RageLog.h"
#include "RageUtil.h"
#include "ScoreDisplay.h"
#include "StatsManager.h"
#include "ThemeManager.h"

namespace {
void WarnScoreDisplayOniAuditFix(const char* message) {
  if (LOG != nullptr) {
    LOG->Warn("%s", message);
  }
}

void TraceScoreDisplayOniAuditFix(const char* message) {
  if (LOG != nullptr) {
    LOG->Trace("%s", message);
  }
}

bool IsValidPlayerNumber(PlayerNumber pn) {
  return pn >= PLAYER_1 && pn < NUM_PLAYERS;
}
}  // namespace

ScoreDisplayOni::ScoreDisplayOni() {
  if (LOG != nullptr) {
    LOG->Trace("ScoreDisplayOni::ScoreDisplayOni()");
  }

  if (THEME != nullptr) {
    m_sprFrame.Load(THEME->GetPathG("ScoreDisplayOni", "frame"));
  } else {
    WarnScoreDisplayOniAuditFix(
        "SRC_AUDIT_FIX SRC-1110: ScoreDisplayOni constructed without THEME.");
  }
  this->AddChild(&m_sprFrame);

  // init the text
  if (THEME != nullptr) {
    m_text.LoadFromFont(THEME->GetPathF("ScoreDisplayOni", "numbers"));
  }
  m_text.SetName("ScoreDisplayOni Numbers");
  m_text.SetShadowLength(0);
  if (THEME != nullptr) {
    LOAD_ALL_COMMANDS(m_text);
  }
  this->AddChild(&m_text);
}

void ScoreDisplayOni::Init(
    const PlayerState* pPlayerState,
    const PlayerStageStats* pPlayerStageStats) {
  ScoreDisplay::Init(pPlayerState, pPlayerStageStats);
}

void ScoreDisplayOni::Update(float fDelta) {
  ScoreDisplay::Update(fDelta);

  if (m_pPlayerState == nullptr) {
    TraceScoreDisplayOniAuditFix(
        "SRC_AUDIT_FIX SRC-241: ScoreDisplayOni skipped update without "
        "PlayerState.");
    m_text.SetText(SecondsToMMSSMsMs(0));
    return;
  }

  // TODO: Remove use of PlayerNumber.
  PlayerNumber pn = m_pPlayerState->m_PlayerNumber;

  float fSecsIntoPlay = 0;
  if (GAMESTATE != nullptr && STATSMAN != nullptr && IsValidPlayerNumber(pn) &&
      GAMESTATE->IsPlayerEnabled(pn)) {
    fSecsIntoPlay = STATSMAN->m_CurStageStats.m_player[pn].m_fAliveSeconds;
  } else if (!IsValidPlayerNumber(pn)) {
    TraceScoreDisplayOniAuditFix(
        "SRC_AUDIT_FIX SRC-241: ScoreDisplayOni ignored invalid player.");
  }
  if (!std::isfinite(fSecsIntoPlay) || fSecsIntoPlay < 0.0f) {
    TraceScoreDisplayOniAuditFix(
        "SRC_AUDIT_FIX SRC-1111: ScoreDisplayOni corrected invalid seconds.");
    fSecsIntoPlay = 0.0f;
  }

  m_text.SetText(SecondsToMMSSMsMs(fSecsIntoPlay));
}

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
