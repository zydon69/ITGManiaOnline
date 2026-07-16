#include "ScoreDisplayRave.h"

#include <cmath>

#include "ActorUtil.h"
#include "EnumHelper.h"
#include "GameConstantsAndTypes.h"
#include "PlayerNumber.h"
#include "PlayerState.h"
#include "RageLog.h"
#include "RageUtil.h"
#include "ScoreDisplay.h"
#include "ThemeManager.h"

namespace {
void WarnScoreDisplayRaveAuditFix(const char* message) {
  if (LOG != nullptr) {
    LOG->Warn("%s", message);
  }
}

bool IsValidScoreDisplayPlayer(PlayerNumber pn) {
  return pn >= PLAYER_1 && pn < NUM_PLAYERS;
}
}  // namespace

ScoreDisplayRave::ScoreDisplayRave() {
  if (LOG != nullptr) {
    LOG->Trace("ScoreDisplayRave::ScoreDisplayRave()");
  }

  m_lastLevelSeen = ATTACK_LEVEL_1;

  if (THEME != nullptr) {
    for (int i = 0; i < NUM_ATTACK_LEVELS; i++) {
      m_sprMeter[i].Load(THEME->GetPathG(
          "ScoreDisplayRave", ssprintf("stream level%d", i + 1)));
      m_sprMeter[i].SetCropRight(1.f);
    }

    m_textLevel.LoadFromFont(THEME->GetPathF("ScoreDisplayRave", "level"));
  } else {
    WarnScoreDisplayRaveAuditFix(
        "SRC_AUDIT_FIX SRC-1112: ScoreDisplayRave constructed without THEME.");
  }
  m_textLevel.SetText("1");
}

void ScoreDisplayRave::ResetLoadedActors() {
  if (m_sprFrameBase.IsLoaded()) {
    RemoveChild(m_sprFrameBase);
    m_sprFrameBase.Unload();
  }
  if (m_sprFrameOverlay.IsLoaded()) {
    RemoveChild(m_sprFrameOverlay);
    m_sprFrameOverlay.Unload();
  }
  for (int i = 0; i < NUM_ATTACK_LEVELS; i++) {
    RemoveChild(&m_sprMeter[i]);
  }
  RemoveChild(&m_textLevel);
}

void ScoreDisplayRave::Init(
    const PlayerState* pPlayerState,
    const PlayerStageStats* pPlayerStageStats) {
  ScoreDisplay::Init(pPlayerState, pPlayerStageStats);
  ResetLoadedActors();

  if (THEME == nullptr) {
    WarnScoreDisplayRaveAuditFix(
        "SRC_AUDIT_FIX SRC-1112: ScoreDisplayRave refused init without "
        "THEME.");
    return;
  }

  PlayerNumber pn = PLAYER_1;
  if (pPlayerState == nullptr ||
      !IsValidScoreDisplayPlayer(pPlayerState->m_PlayerNumber)) {
    WarnScoreDisplayRaveAuditFix(
        "SRC_AUDIT_FIX: ScoreDisplayRave initialized with invalid "
        "PlayerState; using PLAYER_1 assets.");
  } else {
    pn = pPlayerState->m_PlayerNumber;
  }

  m_sprFrameBase.Load(
      THEME->GetPathG("ScoreDisplayRave", ssprintf("frame base p%d", pn + 1)));
  m_sprFrameBase->SetName(ssprintf("FrameBaseP%d", pn + 1));
  LOAD_ALL_COMMANDS_AND_SET_XY(m_sprFrameBase);
  this->AddChild(m_sprFrameBase);

  for (int i = 0; i < NUM_ATTACK_LEVELS; i++) {
    m_sprMeter[i].SetName(ssprintf("MeterP%d", pn + 1));
    LOAD_ALL_COMMANDS_AND_SET_XY(m_sprMeter[i]);
    this->AddChild(&m_sprMeter[i]);
  }

  m_textLevel.SetName(ssprintf("LevelP%d", pn + 1));
  LOAD_ALL_COMMANDS_AND_SET_XY(m_textLevel);
  this->AddChild(&m_textLevel);

  m_sprFrameOverlay.Load(THEME->GetPathG(
      "ScoreDisplayRave", ssprintf("frame overlay p%d", pn + 1)));
  m_sprFrameOverlay->SetName(ssprintf("FrameOverP%d", pn + 1));
  LOAD_ALL_COMMANDS_AND_SET_XY(m_sprFrameOverlay);
  this->AddChild(m_sprFrameOverlay);
}

void ScoreDisplayRave::Update(float fDelta) {
  ScoreDisplay::Update(fDelta);

  if (m_pPlayerState == nullptr) {
    return;
  }

  float fLevel = m_pPlayerState->m_fSuperMeter;
  if (!std::isfinite(fLevel)) {
    WarnScoreDisplayRaveAuditFix(
        "SRC_AUDIT_FIX: ScoreDisplayRave ignored non-finite super meter.");
    fLevel = 0.0f;
  }
  rage_clamp(fLevel, 0.0f, (float)NUM_ATTACK_LEVELS - 0.0001f);
  AttackLevel level = (AttackLevel)(int)fLevel;

  if (level != m_lastLevelSeen) {
    if (m_lastLevelSeen >= ATTACK_LEVEL_1 && m_lastLevelSeen < NUM_ATTACK_LEVELS) {
      m_sprMeter[m_lastLevelSeen].SetCropRight(1.f);
    }
    m_lastLevelSeen = level;
    m_textLevel.SetText(ssprintf("%d", level + 1));
  }

  float fPercent = fLevel - Enum::to_integral(level);
  m_sprMeter[level].SetCropRight(1 - fPercent);
}

/*
 * (c) 2003 Chris Danford
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
