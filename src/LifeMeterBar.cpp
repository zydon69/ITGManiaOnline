#include "LifeMeterBar.h"

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <limits>
#include <string>

#include "ActorUtil.h"
#include "Course.h"
#include "Difficulty.h"
#include "GameConstantsAndTypes.h"
#include "GameState.h"
#include "LifeMeter.h"
#include "LuaReference.h"
#include "MessageManager.h"
#include "PlayerNumber.h"
#include "PlayerOptions.h"
#include "PlayerStageStats.h"
#include "PlayerState.h"
#include "PrefsManager.h"
#include "RageLog.h"
#include "RageUtil.h"
#include "Steps.h"
#include "StreamDisplay.h"
#include "ThemeManager.h"
#include "ThemeMetric.h"
#include "global.h"

static std::string LIFE_PERCENT_CHANGE_NAME(size_t i) {
  return "LifePercentChange" + ScoreEventToString((ScoreEvent)i);
}

namespace {
bool IsValidPlayerNumber(PlayerNumber pn) {
  return pn >= PLAYER_1 && pn < NUM_PLAYERS;
}

bool IsValidTapNoteScore(TapNoteScore score) {
  return score >= TNS_None && score < NUM_TapNoteScore;
}

bool IsValidHoldNoteScore(HoldNoteScore score) {
  return score >= HNS_None && score < NUM_HoldNoteScore;
}

DrainType NormalizeDrainType(DrainType dtype, const char* context) {
  if (dtype >= DrainType_Normal && dtype < NUM_DrainType) {
    return dtype;
  }

  LOG->Warn(
      "%s: invalid DrainType %i; using normal drain.",
      context, dtype);
  return DrainType_Normal;
}

float NormalizeLifeDifficulty(float difficulty, const char* context) {
  if (std::isfinite(difficulty) && difficulty > 0.0f) {
    return difficulty;
  }

  LOG->Warn(
      "%s: invalid life difficulty %f; using 1.0.",
      context, difficulty);
  return 1.0f;
}

float NormalizeMaxLife(float maxLife) {
  return std::isfinite(maxLife) && maxLife > 0.0f ? maxLife : 1.0f;
}
}  // namespace

LifeMeterBar::LifeMeterBar() {
  m_pStream = nullptr;
  m_pPlayerState = nullptr;
  m_fLifePercentage = 0.0f;
  m_fPassingAlpha = 0.0f;
  m_fHotAlpha = 0.0f;
  m_fBaseLifeDifficulty = 1.0f;
  m_fLifeDifficulty = 1.0f;
  m_bMercifulBeginnerInEffect = false;
  m_iProgressiveLifebar = 0;
  m_iMissCombo = 0;
  m_iComboToRegainLife = 0;

  if (THEME == nullptr || PREFSMAN == nullptr || GAMESTATE == nullptr) {
    LOG->Warn(
        "LifeMeterBar constructed without complete runtime "
        "managers.");
    return;
  }

  DANGER_THRESHOLD.Load("LifeMeterBar", "DangerThreshold");
  INITIAL_VALUE.Load("LifeMeterBar", "InitialValue");
  HOT_VALUE.Load("LifeMeterBar", "HotValue");
  LIFE_MULTIPLIER.Load("LifeMeterBar", "LifeMultiplier");
  MIN_STAY_ALIVE.Load("LifeMeterBar", "MinStayAlive");
  FORCE_LIFE_DIFFICULTY_ON_EXTRA_STAGE.Load(
      "LifeMeterBar", "ForceLifeDifficultyOnExtraStage");
  EXTRA_STAGE_LIFE_DIFFICULTY.Load("LifeMeterBar", "ExtraStageLifeDifficulty");
  m_fLifePercentChange.Load(
      "LifeMeterBar", LIFE_PERCENT_CHANGE_NAME, NUM_ScoreEvent);

  const std::string sType = "LifeMeterBar";

  m_fBaseLifeDifficulty = PREFSMAN->m_fLifeDifficultyScale;
  m_fLifeDifficulty = m_fBaseLifeDifficulty;
  m_iProgressiveLifebar = std::max(0, (int)PREFSMAN->m_iProgressiveLifebar);

  bool bExtra = GAMESTATE->IsAnExtraStage();
  std::string sExtra = bExtra ? "extra " : "";

  m_sprUnder.Load(THEME->GetPathG(sType, sExtra + "Under"));
  m_sprUnder->SetName("Under");
  ActorUtil::LoadAllCommandsAndSetXY(m_sprUnder, sType);
  this->AddChild(m_sprUnder);

  m_sprDanger.Load(THEME->GetPathG(sType, sExtra + "Danger"));
  m_sprDanger->SetName("Danger");
  ActorUtil::LoadAllCommandsAndSetXY(m_sprDanger, sType);
  this->AddChild(m_sprDanger);

  m_pStream = new StreamDisplay;
  m_pStream->Load(bExtra ? "StreamDisplayExtra" : "StreamDisplay");
  m_pStream->SetName("Stream");
  ActorUtil::LoadAllCommandsAndSetXY(m_pStream, sType);
  this->AddChild(m_pStream);

  m_sprOver.Load(THEME->GetPathG(sType, sExtra + "Over"));
  m_sprOver->SetName("Over");
  ActorUtil::LoadAllCommandsAndSetXY(m_sprOver, sType);
  this->AddChild(m_sprOver);
}

LifeMeterBar::~LifeMeterBar() { RageUtil::SafeDelete(m_pStream); }

void LifeMeterBar::Load(
    const PlayerState* pPlayerState, PlayerStageStats* pPlayerStageStats) {
  LifeMeter::Load(pPlayerState, pPlayerStageStats);

  if (pPlayerState == nullptr || pPlayerStageStats == nullptr) {
    LOG->Warn(
        "LifeMeterBar loaded without complete player "
        "state.");
    m_fLifePercentage = INITIAL_VALUE;
    if (m_pStream != nullptr) {
      m_pStream->SetPercent(m_fLifePercentage);
    }
    return;
  }

  PlayerNumber pn = pPlayerState->m_PlayerNumber;
  if (!IsValidPlayerNumber(pn) || GAMESTATE == nullptr || PREFSMAN == nullptr) {
    LOG->Warn(
        "LifeMeterBar refused load with invalid "
        "player or missing managers.");
    return;
  }

  DrainType dtype = NormalizeDrainType(
      pPlayerState->m_PlayerOptions.GetStage().m_DrainType,
      "LifeMeterBar::Load");
  switch (dtype) {
    case DrainType_Normal:
      m_fLifePercentage = INITIAL_VALUE;
      break;
      /* These types only go down, so they always start at full. */
    case DrainType_NoRecover:
    case DrainType_SuddenDeath:
      m_fLifePercentage = 1.0f;
      break;
    default:
      break;
  }

  // Change life difficulty to really easy if merciful beginner on
  const bool hasValidSteps = GAMESTATE->m_pCurSteps[pn] != nullptr;
  m_bMercifulBeginnerInEffect =
      GAMESTATE->m_PlayMode == PLAY_MODE_REGULAR &&
      GAMESTATE->IsPlayerEnabled(pPlayerState) && hasValidSteps &&
      GAMESTATE->m_pCurSteps[pn]->GetDifficulty() == Difficulty_Beginner &&
      PREFSMAN->m_bMercifulBeginner;
  if (!hasValidSteps && IsValidPlayerNumber(pn)) {
    LOG->Trace(
        "LifeMeterBar skipped merciful beginner check "
        "without current steps for player %i.",
        pn);
  }

  AfterLifeChanged();
}

void LifeMeterBar::ChangeLife(TapNoteScore score) {
  if (!IsValidTapNoteScore(score)) {
    LOG->Warn(
        "LifeMeterBar ignored invalid TapNoteScore %i.",
        score);
    return;
  }
  if (m_pPlayerState == nullptr || PREFSMAN == nullptr) {
    LOG->Warn(
        "LifeMeterBar ignored tap score without "
        "complete runtime state.");
    return;
  }

  float fDeltaLife = 0.f;
  switch (score) {
    case TNS_AvoidMine:
      fDeltaLife = 0.0f;
      break;
    case TNS_W1:
      fDeltaLife = m_fLifePercentChange.GetValue(SE_W1);
      break;
    case TNS_W2:
      fDeltaLife = m_fLifePercentChange.GetValue(SE_W2);
      break;
    case TNS_W3:
      fDeltaLife = m_fLifePercentChange.GetValue(SE_W3);
      break;
    case TNS_W4:
      fDeltaLife = m_fLifePercentChange.GetValue(SE_W4);
      break;
    case TNS_W5:
      fDeltaLife = m_fLifePercentChange.GetValue(SE_W5);
      break;
    case TNS_Miss:
      fDeltaLife = m_fLifePercentChange.GetValue(SE_Miss);
      break;
    case TNS_HitMine:
      fDeltaLife = m_fLifePercentChange.GetValue(SE_HitMine);
      break;
    case TNS_None:
      fDeltaLife = m_fLifePercentChange.GetValue(SE_Miss);
      break;
    case TNS_CheckpointHit:
      fDeltaLife = m_fLifePercentChange.GetValue(SE_CheckpointHit);
      break;
    case TNS_CheckpointMiss:
      fDeltaLife = m_fLifePercentChange.GetValue(SE_CheckpointMiss);
      break;
    default:
      break;
  }

  // this was previously if( IsHot()  &&  score < TNS_GOOD ) in 3.9... -freem
  if (PREFSMAN != nullptr && PREFSMAN->m_HarshHotLifePenalty && IsHot() &&
      fDeltaLife < 0) {
    fDeltaLife = std::min(
        fDeltaLife, -0.10f);  // make it take a while to get back to "hot"
  }

  switch (NormalizeDrainType(
      m_pPlayerState->m_PlayerOptions.GetSong().m_DrainType,
      "LifeMeterBar::ChangeLife(TapNoteScore)")) {
    case DrainType_Normal:
      break;
    case DrainType_NoRecover:
      fDeltaLife = std::min(fDeltaLife, 0.0f);
      break;
    case DrainType_SuddenDeath:
      if (score < MIN_STAY_ALIVE) {
        fDeltaLife = -1.0f;
      } else {
        fDeltaLife = 0;
      }
      break;
    default:
      break;
  }

  ChangeLife(fDeltaLife);
}

void LifeMeterBar::ChangeLife(HoldNoteScore score, TapNoteScore tscore) {
  if (!IsValidHoldNoteScore(score)) {
    LOG->Warn(
        "LifeMeterBar ignored invalid HoldNoteScore "
        "%i.",
        score);
    return;
  }
  if (score == HNS_None) {
    return;
  }
  if (m_pPlayerState == nullptr) {
    LOG->Warn(
        "LifeMeterBar ignored hold score without "
        "PlayerState.");
    return;
  }

  float fDeltaLife = 0.f;
  DrainType dtype = NormalizeDrainType(
      m_pPlayerState->m_PlayerOptions.GetSong().m_DrainType,
      "LifeMeterBar::ChangeLife(HoldNoteScore)");
  switch (dtype) {
    case DrainType_Normal:
      switch (score) {
        case HNS_Held:
          fDeltaLife = m_fLifePercentChange.GetValue(SE_Held);
          break;
        case HNS_LetGo:
          fDeltaLife = m_fLifePercentChange.GetValue(SE_LetGo);
          break;
        case HNS_Missed:
          fDeltaLife = m_fLifePercentChange.GetValue(SE_Missed);
          break;
        default:
          break;
      }
      if (PREFSMAN != nullptr && PREFSMAN->m_HarshHotLifePenalty && IsHot() &&
          score == HNS_LetGo) {
        fDeltaLife = -0.10f;  // make it take a while to get back to "hot"
      }
      break;
    case DrainType_NoRecover:
      switch (score) {
        case HNS_Held:
          fDeltaLife = +0.000f;
          break;
        case HNS_LetGo:
          fDeltaLife = m_fLifePercentChange.GetValue(SE_LetGo);
          break;
        case HNS_Missed:
          fDeltaLife = +0.000f;
          break;
        default:
          break;
      }
      break;
    case DrainType_SuddenDeath:
      switch (score) {
        case HNS_Held:
          fDeltaLife = +0;
          break;
        case HNS_LetGo:
          fDeltaLife = -1.0f;
          break;
        case HNS_Missed:
          fDeltaLife = +0;
          break;
        default:
          break;
      }
      break;
    default:
      break;
  }

  ChangeLife(fDeltaLife);
}

void LifeMeterBar::ChangeLife(float fDeltaLife) {
  if (!std::isfinite(fDeltaLife)) {
    LOG->Warn(
        "LifeMeterBar ignored non-finite life delta "
        "%f.",
        fDeltaLife);
    return;
  }
  if (m_pPlayerState == nullptr || m_pPlayerStageStats == nullptr) {
    LOG->Warn(
        "LifeMeterBar ignored life change without "
        "complete player state.");
    return;
  }
  if (PREFSMAN == nullptr) {
    LOG->Warn(
        "LifeMeterBar ignored life change without PrefsManager.");
    return;
  }

  bool bUseMercifulDrain =
      m_bMercifulBeginnerInEffect || PREFSMAN->m_bMercifulDrain;
  if (bUseMercifulDrain && fDeltaLife < 0) {
    fDeltaLife *= SCALE(m_fLifePercentage, 0.f, 1.f, 0.5f, 1.f);
  }

  // handle progressiveness and ComboToRegainLife here
  if (fDeltaLife >= 0) {
    m_iMissCombo = 0;
    m_iComboToRegainLife = std::max(m_iComboToRegainLife - 1, 0);
    if (m_iComboToRegainLife > 0) {
      fDeltaLife = 0.0f;
    }
  } else {
    const double progressiveMultiplier =
        1.0 + static_cast<double>(std::max(m_iProgressiveLifebar, 0)) / 8.0 *
                  std::max(m_iMissCombo, 0);
    const double progressiveDelta =
        static_cast<double>(fDeltaLife) * progressiveMultiplier;
    if (!std::isfinite(progressiveDelta) ||
        progressiveDelta < -std::numeric_limits<float>::max() ||
        progressiveDelta > std::numeric_limits<float>::max()) {
      LOG->Warn(
          "LifeMeterBar saturated progressive life delta.");
      fDeltaLife = progressiveDelta < 0.0
                       ? -std::numeric_limits<float>::max()
                       : std::numeric_limits<float>::max();
    } else {
      fDeltaLife = static_cast<float>(progressiveDelta);
    }
    // do this after; only successive W5/miss will increase the amount of life
    // lost.
    if (m_iMissCombo < std::numeric_limits<int>::max()) {
      ++m_iMissCombo;
    }
    /* Increase by m_iRegenComboAfterMiss; never push it beyond
     * m_iMaxRegenComboAfterMiss but don't reduce it if it's already past. */
    const int maxRegen =
        std::max(0, (int)PREFSMAN->m_iMaxRegenComboAfterMiss);
    const int regen = std::max(0, (int)PREFSMAN->m_iRegenComboAfterMiss);
    const int64_t proposedRegen =
        static_cast<int64_t>(std::max(m_iComboToRegainLife, 0)) + regen;
    const int NewComboToRegainLife = static_cast<int>(std::min<int64_t>(
        maxRegen, std::min<int64_t>(proposedRegen,
                                    std::numeric_limits<int>::max())));

    m_iComboToRegainLife = std::max(m_iComboToRegainLife, NewComboToRegainLife);
  }

  // If we've already failed, there's no point in letting them fill up the bar
  // again.
  if (m_pPlayerStageStats->m_bFailed) {
    return;
  }

  m_fLifeDifficulty =
      NormalizeLifeDifficulty(m_fLifeDifficulty, "LifeMeterBar");

  switch (NormalizeDrainType(
      m_pPlayerState->m_PlayerOptions.GetSong().m_DrainType,
      "LifeMeterBar::ChangeLife(float)")) {
    case DrainType_Normal:
    case DrainType_NoRecover:
      if (fDeltaLife > 0) {
        fDeltaLife *= m_fLifeDifficulty;
      } else {
        fDeltaLife /= m_fLifeDifficulty;
      }
      break;
    case DrainType_SuddenDeath:
      // This should always -1.0f;
      if (fDeltaLife < 0) {
        fDeltaLife = -1.0f;
      } else {
        fDeltaLife = 0;
      }
      break;
    default:
      break;
  }

  m_fLifePercentage += fDeltaLife;
  if (!std::isfinite(m_fLifePercentage)) {
    LOG->Warn(
        "LifeMeterBar corrected non-finite life %f.",
        m_fLifePercentage);
    m_fLifePercentage = 0.0f;
  }
  rage_clamp(m_fLifePercentage, 0.0f, NormalizeMaxLife(LIFE_MULTIPLIER));
  AfterLifeChanged();
}

void LifeMeterBar::SetLife(float value) {
  if (!std::isfinite(value)) {
    LOG->Warn(
        "LifeMeterBar ignored non-finite SetLife %f.",
        value);
    return;
  }
  m_fLifePercentage = value;
  rage_clamp(m_fLifePercentage, 0.0f, NormalizeMaxLife(LIFE_MULTIPLIER));
  AfterLifeChanged();
}

extern ThemeMetric<bool> PENALIZE_TAP_SCORE_NONE;
void LifeMeterBar::HandleTapScoreNone() {
  if (PENALIZE_TAP_SCORE_NONE) {
    ChangeLife(TNS_None);
  }
}

void LifeMeterBar::AfterLifeChanged() {
  if (m_pStream != nullptr) {
    m_pStream->SetPercent(m_fLifePercentage);
  }
  if (m_pPlayerState == nullptr ||
      !IsValidPlayerNumber(m_pPlayerState->m_PlayerNumber) ||
      MESSAGEMAN == nullptr) {
    LOG->Trace(
        "LifeMeterBar skipped LifeChanged broadcast "
        "without PlayerState.");
    return;
  }

  Message msg("LifeChanged");
  msg.SetParam("Player", m_pPlayerState->m_PlayerNumber);
  msg.SetParam("LifeMeter", LuaReference::CreateFromPush(*this));
  MESSAGEMAN->Broadcast(msg);
}

bool LifeMeterBar::IsHot() const {
  return HOT_VALUE.IsLoaded() && m_fLifePercentage >= HOT_VALUE;
}

bool LifeMeterBar::IsInDanger() const {
  return DANGER_THRESHOLD.IsLoaded() && m_fLifePercentage < DANGER_THRESHOLD;
}

bool LifeMeterBar::IsFailing() const {
  if (m_pPlayerState == nullptr) {
    return true;
  }
  const float passmark =
      m_pPlayerState->m_PlayerOptions.GetCurrent().m_fPassmark;
  if (!std::isfinite(passmark)) {
    LOG->Trace(
        "LifeMeterBar treated non-finite passmark as "
        "0.");
    return m_fLifePercentage <= 0.0f;
  }
  return m_fLifePercentage <=
         passmark;
}

void LifeMeterBar::Update(float fDeltaTime) {
  LifeMeter::Update(fDeltaTime);
  if (m_pStream == nullptr || m_pPlayerState == nullptr) {
    LOG->Trace(
        "LifeMeterBar skipped update without stream or "
        "PlayerState.");
    return;
  }
  if (!std::isfinite(fDeltaTime) || fDeltaTime < 0.0f) {
    LOG->Warn(
        "LifeMeterBar ignored invalid update delta %f.",
        fDeltaTime);
    return;
  }

  m_fPassingAlpha += !IsFailing() ? +fDeltaTime * 2 : -fDeltaTime * 2;
  rage_clamp(m_fPassingAlpha, 0, 1);

  m_fHotAlpha += IsHot() ? +fDeltaTime * 2 : -fDeltaTime * 2;
  rage_clamp(m_fHotAlpha, 0, 1);

  m_pStream->SetPassingAlpha(m_fPassingAlpha);
  m_pStream->SetHotAlpha(m_fHotAlpha);

  if (m_pPlayerState->m_HealthState == HealthState_Danger) {
    m_sprDanger->SetVisible(true);
  } else {
    m_sprDanger->SetVisible(false);
  }
}

void LifeMeterBar::UpdateNonstopLifebar() {
  if (GAMESTATE == nullptr || PREFSMAN == nullptr) {
    LOG->Warn(
        "LifeMeterBar skipped progressive update "
        "without managers.");
    return;
  }

  int iCleared, iTotal, iProgressiveLifebarDifficulty;

  switch (GAMESTATE->m_PlayMode) {
    case PLAY_MODE_REGULAR:
      if (GAMESTATE->IsEventMode() || GAMESTATE->m_bDemonstrationOrJukebox) {
        return;
      }

      iCleared = GAMESTATE->m_iCurrentStageIndex;
      iTotal = PREFSMAN->m_iSongsPerPlay;
      iProgressiveLifebarDifficulty = PREFSMAN->m_iProgressiveStageLifebar;
      break;
    case PLAY_MODE_NONSTOP:
      if (GAMESTATE->m_pCurCourse == nullptr) {
        LOG->Warn(
            "LifeMeterBar skipped progressive nonstop "
            "without current course.");
        return;
      }
      iCleared = GAMESTATE->GetCourseSongIndex();
      iTotal = GAMESTATE->m_pCurCourse->GetEstimatedNumStages();
      iProgressiveLifebarDifficulty = PREFSMAN->m_iProgressiveNonstopLifebar;
      break;
    default:
      return;
  }

  if (iTotal <= 0) {
    LOG->Warn(
        "LifeMeterBar ignored progressive lifebar with "
        "total stages %i.",
        iTotal);
    m_fLifeDifficulty =
        NormalizeLifeDifficulty(m_fBaseLifeDifficulty, "LifeMeterBar");
    return;
  }

  if (GAMESTATE->IsAnExtraStage() && FORCE_LIFE_DIFFICULTY_ON_EXTRA_STAGE) {
    // extra stage is its own thing, should not be progressive
    // and it should be as difficult as life 4
    // (e.g. it should not depend on life settings)

    m_iProgressiveLifebar = 0;
    m_fLifeDifficulty = NormalizeLifeDifficulty(
        EXTRA_STAGE_LIFE_DIFFICULTY, "LifeMeterBar extra stage");
    return;
  }

  iCleared = std::max(iCleared, 0);
  const int64_t progressiveProduct =
      static_cast<int64_t>(iProgressiveLifebarDifficulty) * iCleared;
  const double progressiveAdjustment =
      iTotal > 1
          ? static_cast<double>(progressiveProduct) / (iTotal - 1)
          : static_cast<double>(iProgressiveLifebarDifficulty);
  if (!std::isfinite(progressiveAdjustment)) {
    LOG->Warn(
        "LifeMeterBar ignored non-finite progressive "
        "adjustment.");
    m_fLifeDifficulty = NormalizeLifeDifficulty(
        m_fBaseLifeDifficulty, "LifeMeterBar");
    return;
  }

  m_fLifeDifficulty = static_cast<float>(
      static_cast<double>(m_fBaseLifeDifficulty) -
      0.2 * progressiveAdjustment);

  if (m_fLifeDifficulty >= 0.4f) {
    m_fLifeDifficulty =
        NormalizeLifeDifficulty(m_fLifeDifficulty, "LifeMeterBar");
    return;
  }

  /* Approximate deductions for a miss
   * Life 1 :    5   %
   * Life 2 :    5.7 %
   * Life 3 :    6.6 %
   * Life 4 :    8   %
   * Life 5 :   10   %
   * Life 6 :   13.3 %
   * Life 7 :   20   %
   * Life 8 :   26.6 %
   * Life 9 :   32   %
   * Life 10:   40   %
   * Life 11:   50   %
   * Life 12:   57.1 %
   * Life 13:   66.6 %
   * Life 14:   80   %
   * Life 15:  100   %
   * Life 16+: 200   %
   *
   * Note there is 200%, because boos take off 1/2 as much as
   * a miss, and a W5 would suck up half of your lifebar.
   *
   * Everything past 7 is intended mainly for nonstop mode.
   */

  // the lifebar is pretty harsh at 0.4 already (you lose
  // about 20% of your lifebar); at 0.2 it would be 40%, which
  // is too harsh at one difficulty level higher.  Override.
  int iLifeDifficulty = int((1.8f - m_fLifeDifficulty) / 0.2f);
  if (iLifeDifficulty < 0) {
    m_fLifeDifficulty =
        NormalizeLifeDifficulty(m_fBaseLifeDifficulty, "LifeMeterBar");
    return;
  }

  // first eight values don't matter
  float fDifficultyValues[16] = {0,     0,     0,     0,     0,    0,
                                 0,     0,     0.3f,  0.25f, 0.2f, 0.16f,
                                 0.14f, 0.12f, 0.10f, 0.08f};

  if (iLifeDifficulty >= 16) {
    // judge 16 or higher
    m_fLifeDifficulty = 0.04f;
    return;
  }

  m_fLifeDifficulty = fDifficultyValues[iLifeDifficulty];
  return;
}

void LifeMeterBar::FillForHowToPlay(int NumW2s, int NumMisses) {
  m_iProgressiveLifebar = 0;  // disable progressive lifebar

  m_fLifeDifficulty =
      NormalizeLifeDifficulty(m_fLifeDifficulty, "LifeMeterBar HTP");
  float AmountForW2 = NumW2s * m_fLifeDifficulty * 0.008f;
  float AmountForMiss = NumMisses / m_fLifeDifficulty * 0.08f;

  m_fLifePercentage = AmountForMiss - AmountForW2;
  if (!std::isfinite(m_fLifePercentage)) {
    LOG->Warn(
        "LifeMeterBar corrected non-finite HTP life "
        "%f.",
        m_fLifePercentage);
    m_fLifePercentage = 0.0f;
  }
  rage_clamp(m_fLifePercentage, 0.0f, 1.0f);
  AfterLifeChanged();
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
