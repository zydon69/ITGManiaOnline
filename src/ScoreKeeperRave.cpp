#include "ScoreKeeperRave.h"

#include <algorithm>
#include <cctype>
#include <cmath>
#include <cstddef>
#include <string>

#include "Attack.h"
#include "Character.h"
#include "EnumHelper.h"
#include "GameConstantsAndTypes.h"
#include "GameState.h"
#include "NoteTypes.h"
#include "PlayerNumber.h"
#include "PlayerState.h"
#include "Preference.h"
#include "PrefsManager.h"
#include "RageLog.h"
#include "RageUtil.h"
#include "RageUtil/RandomNumbers.h"
#include "ScoreKeeper.h"
#include "ThemeMetric.h"
#include "global.h"

ThemeMetric<float> ATTACK_DURATION_SECONDS(
    "ScoreKeeperRave", "AttackDurationSeconds");

static void SuperMeterPercentChangeInit(
    size_t /*ScoreEvent*/ i, std::string& sNameOut, float& defaultValueOut) {
  ScoreEvent ci = (ScoreEvent)i;
  sNameOut = "SuperMeterPercentChange" + ScoreEventToString(ci);
  switch (ci) {
    case SE_CheckpointHit:
      defaultValueOut = +0.05f;
      break;
    case SE_W1:
      defaultValueOut = +0.05f;
      break;
    case SE_W2:
      defaultValueOut = +0.04f;
      break;
    case SE_W3:
      defaultValueOut = +0.02f;
      break;
    case SE_W4:
      defaultValueOut = +0.00f;
      break;
    case SE_W5:
      defaultValueOut = +0.00f;
      break;
    case SE_Miss:
      defaultValueOut = -0.20f;
      break;
    case SE_HitMine:
      defaultValueOut = -0.40f;
      break;
    case SE_CheckpointMiss:
      defaultValueOut = -0.20f;
      break;
    case SE_Held:
      defaultValueOut = +0.04f;
      break;
    case SE_LetGo:
      defaultValueOut = -0.20f;
      break;
    case SE_Missed:
      defaultValueOut = -0.00f;
      break;
    default:
      LOG->Warn(
          "SRC_AUDIT_FIX SRC-2063: Unknown ScoreEvent %i for Rave super "
          "meter preference default; using 0.",
          ci);
      defaultValueOut = 0.0f;
      break;
  }
}

static Preference1D<float> g_fSuperMeterPercentChange(
    SuperMeterPercentChangeInit, NUM_ScoreEvent);

namespace {
bool IsValidRavePlayer(PlayerNumber pn) {
  return pn >= PLAYER_1 && pn < NUM_PLAYERS;
}

bool IsValidRaveTapScore(TapNoteScore tns) {
  return tns >= TNS_None && tns < NUM_TapNoteScore;
}

bool IsValidRaveHoldScore(HoldNoteScore hns) {
  return hns >= HNS_None && hns < NUM_HoldNoteScore;
}

bool IsValidAttackLevel(AttackLevel al) {
  return al >= ATTACK_LEVEL_1 && al < NUM_ATTACK_LEVELS;
}

float ClampFiniteFloat(float value, float low, float high, const char* context) {
  if (!std::isfinite(value)) {
    LOG->Warn(
        "SRC_AUDIT_FIX: %s normalized non-finite value %f to %f.",
        context, value, low);
    return low;
  }
  return std::max(low, std::min(high, value));
}

float ClampSuperMeterDelta(float value, const char* context) {
  return ClampFiniteFloat(value, -1.0f, 1.0f, context);
}

float ClampAttackDuration(float value) {
  static const float kMaxRaveAttackDurationSeconds = 60.0f;
  return ClampFiniteFloat(
      value, 0.0f, kMaxRaveAttackDurationSeconds,
      "ScoreKeeperRave attack duration");
}

float GetSafeTugLifePercent() {
  if (GAMESTATE == nullptr) {
    LOG->Warn(
        "SRC_AUDIT_FIX: ScoreKeeperRave used neutral tug life because "
        "GAMESTATE is null.");
    return 0.5f;
  }
  return ClampFiniteFloat(
      GAMESTATE->m_fTugLifePercentP1, 0.0f, 1.0f,
      "ScoreKeeperRave tug life percent");
}

bool HasRaveGlobals(const char* context) {
  if (GAMESTATE != nullptr && PREFSMAN != nullptr) {
    return true;
  }
  LOG->Warn(
      "SRC_AUDIT_FIX: %s ignored callback with missing globals: GAMESTATE=%p "
      "PREFSMAN=%p.",
      context, static_cast<void*>(GAMESTATE), static_cast<void*>(PREFSMAN));
  return false;
}

bool IsSafeRaveAttackModifier(std::string modifier, const char* context) {
  Trim(modifier);
  if (modifier.empty()) {
    LOG->Warn("SRC_AUDIT_FIX: %s rejected empty attack modifier.", context);
    return false;
  }
  static const size_t kMaxRaveAttackModifierChars = 256;
  if (modifier.size() > kMaxRaveAttackModifierChars) {
    LOG->Warn(
        "SRC_AUDIT_FIX SRC-2064: %s rejected oversized attack modifier (%zu "
        "chars).",
        context, modifier.size());
    return false;
  }
  for (unsigned char c : modifier) {
    if (std::iscntrl(c)) {
      LOG->Warn(
          "SRC_AUDIT_FIX SRC-2064: %s rejected attack modifier containing a "
          "control character.",
          context);
      return false;
    }
  }
  return true;
}
}  // namespace

ScoreKeeperRave::ScoreKeeperRave(
    PlayerState* pPlayerState, PlayerStageStats* pPlayerStageStats)
    : ScoreKeeper(pPlayerState, pPlayerStageStats) {}

void ScoreKeeperRave::HandleTapScore(const TapNote& tn) {
  if (!HasScoringState("ScoreKeeperRave::HandleTapScore")) {
    return;
  }
  TapNoteScore score = tn.result.tns;
  if (!IsValidRaveTapScore(score)) {
    LOG->Warn(
        "SRC_AUDIT_FIX SRC-2062: ScoreKeeperRave ignored invalid tap score "
        "%i.",
        score);
    return;
  }
  float fPercentToMove = 0;

  if (score == TNS_HitMine) {
    fPercentToMove = ClampSuperMeterDelta(
        g_fSuperMeterPercentChange[SE_HitMine],
        "ScoreKeeperRave HitMine super meter delta");
  }

  AddSuperMeterDelta(fPercentToMove);
}

#define CROSSED(val) (fOld < val && fNew >= val)
#define CROSSED_ATTACK_LEVEL(level) \
  CROSSED(1.f / NUM_ATTACK_LEVELS * (level + 1))
void ScoreKeeperRave::HandleTapRowScore(const NoteData& nd, int iRow) {
  if (!HasScoringState("ScoreKeeperRave::HandleTapRowScore")) {
    return;
  }
  TapNoteScore scoreOfLastTap;
  int iNumTapsInRow;
  float fPercentToMove = 0.0f;

  GetScoreOfLastTapInRow(nd, iRow, scoreOfLastTap, iNumTapsInRow);
  if (iNumTapsInRow <= 0) {
    return;
  }
  switch (scoreOfLastTap) {
    case TNS_W1:
      fPercentToMove = ClampSuperMeterDelta(
          g_fSuperMeterPercentChange[SE_W1],
          "ScoreKeeperRave W1 super meter delta");
      break;
    case TNS_W2:
      fPercentToMove = ClampSuperMeterDelta(
          g_fSuperMeterPercentChange[SE_W2],
          "ScoreKeeperRave W2 super meter delta");
      break;
    case TNS_W3:
      fPercentToMove = ClampSuperMeterDelta(
          g_fSuperMeterPercentChange[SE_W3],
          "ScoreKeeperRave W3 super meter delta");
      break;
    case TNS_W4:
      fPercentToMove = ClampSuperMeterDelta(
          g_fSuperMeterPercentChange[SE_W4],
          "ScoreKeeperRave W4 super meter delta");
      break;
    case TNS_W5:
      fPercentToMove = ClampSuperMeterDelta(
          g_fSuperMeterPercentChange[SE_W5],
          "ScoreKeeperRave W5 super meter delta");
      break;
    case TNS_Miss:
      fPercentToMove = ClampSuperMeterDelta(
          g_fSuperMeterPercentChange[SE_Miss],
          "ScoreKeeperRave Miss super meter delta");
      break;
    case TNS_None:
    case TNS_AvoidMine:
    case TNS_HitMine:
    case TNS_CheckpointHit:
    case TNS_CheckpointMiss:
      fPercentToMove = 0.0f;
      break;
    default:
      LOG->Warn(
          "SRC_AUDIT_FIX: ScoreKeeperRave ignored invalid tap row score %i.",
          scoreOfLastTap);
      return;
  }
  AddSuperMeterDelta(fPercentToMove);
}

void ScoreKeeperRave::HandleHoldScore(const TapNote& tn) {
  if (!HasScoringState("ScoreKeeperRave::HandleHoldScore")) {
    return;
  }
  // todo: should hit mine be handled in HandleTapRow score instead? -aj
  TapNoteScore tapScore = tn.result.tns;
  float fPercentToMove = 0.0f;
  if (!IsValidRaveTapScore(tapScore)) {
    LOG->Warn(
        "SRC_AUDIT_FIX SRC-2062: ScoreKeeperRave ignored invalid hold tap "
        "score %i.",
        tapScore);
  } else {
    switch (tapScore) {
      case TNS_HitMine:
        fPercentToMove = ClampSuperMeterDelta(
            g_fSuperMeterPercentChange[SE_HitMine],
            "ScoreKeeperRave hold HitMine super meter delta");
        break;
      default:
        break;
    }
  }

  // Playing with this code enabled seems to feel "wrong", but I'm leaving it
  // in for player feedback. -aj
  HoldNoteScore holdScore = tn.HoldResult.hns;
  if (!IsValidRaveHoldScore(holdScore)) {
    LOG->Warn(
        "SRC_AUDIT_FIX SRC-2062: ScoreKeeperRave ignored invalid hold score "
        "%i.",
        holdScore);
    return;
  }
  switch (holdScore) {
    case HNS_Held:
      fPercentToMove = ClampSuperMeterDelta(
          g_fSuperMeterPercentChange[SE_Held],
          "ScoreKeeperRave Held super meter delta");
      break;
    case HNS_LetGo:
      fPercentToMove = ClampSuperMeterDelta(
          g_fSuperMeterPercentChange[SE_LetGo],
          "ScoreKeeperRave LetGo super meter delta");
      break;
    case HNS_Missed:
      fPercentToMove = ClampSuperMeterDelta(
          g_fSuperMeterPercentChange[SE_Missed],
          "ScoreKeeperRave Missed super meter delta");
      break;
    default:
      break;
  }
  AddSuperMeterDelta(fPercentToMove);
}

extern ThemeMetric<bool> PENALIZE_TAP_SCORE_NONE;
void ScoreKeeperRave::HandleTapScoreNone() {
  if (!HasScoringState("ScoreKeeperRave::HandleTapScoreNone")) {
    return;
  }
  if (PENALIZE_TAP_SCORE_NONE) {
    float fPercentToMove = ClampSuperMeterDelta(
        g_fSuperMeterPercentChange[SE_Miss],
        "ScoreKeeperRave None super meter delta");
    AddSuperMeterDelta(fPercentToMove);
  }
}

void ScoreKeeperRave::AddSuperMeterDelta(float fUnscaledPercentChange) {
  if (!HasScoringState("ScoreKeeperRave::AddSuperMeterDelta") ||
      !HasRaveGlobals("ScoreKeeperRave::AddSuperMeterDelta")) {
    return;
  }
  if (m_pPlayerState == nullptr ||
      !IsValidRavePlayer(m_pPlayerState->m_PlayerNumber)) {
    LOG->Warn(
        "SRC_AUDIT_FIX: ScoreKeeperRave ignored super meter delta for "
        "invalid player state %p.",
        static_cast<void*>(m_pPlayerState));
    return;
  }
  fUnscaledPercentChange = ClampSuperMeterDelta(
      fUnscaledPercentChange, "ScoreKeeperRave unscaled super meter delta");
  m_pPlayerState->m_fSuperMeter = ClampFiniteFloat(
      m_pPlayerState->m_fSuperMeter, 0.0f,
      static_cast<float>(NUM_ATTACK_LEVELS) - 0.0001f,
      "ScoreKeeperRave current super meter");
  m_pPlayerState->m_fSuperMeterGrowthScale = ClampFiniteFloat(
      m_pPlayerState->m_fSuperMeterGrowthScale, 0.0f, 10.0f,
      "ScoreKeeperRave super meter growth scale");

  if (PREFSMAN->m_bMercifulDrain && fUnscaledPercentChange < 0) {
    float fSuperPercentage =
        m_pPlayerState->m_fSuperMeter / Enum::to_integral(NUM_ATTACK_LEVELS);
    fUnscaledPercentChange *= SCALE(fSuperPercentage, 0.f, 1.f, 0.5f, 1.f);
  }

  // more mercy: Grow super meter slower or faster depending on life.
  if (PREFSMAN->m_bMercifulSuperMeter) {
    float fLifePercentage = 0;
    switch (m_pPlayerState->m_PlayerNumber) {
      case PLAYER_1:
        fLifePercentage = GetSafeTugLifePercent();
        break;
      case PLAYER_2:
        fLifePercentage = 1.0f - GetSafeTugLifePercent();
        break;
      default:
        LOG->Warn(
            "SRC_AUDIT_FIX: ScoreKeeperRave ignored merciful super meter for "
            "invalid player %i.",
            m_pPlayerState->m_PlayerNumber);
        return;
    }
    fLifePercentage = ClampFiniteFloat(
        fLifePercentage, 0.0f, 1.0f, "ScoreKeeperRave life percentage");
    if (fUnscaledPercentChange > 0) {
      fUnscaledPercentChange *= SCALE(fLifePercentage, 0.f, 1.f, 1.7f, 0.3f);
    } else {  // fUnscaledPercentChange <= 0
      fUnscaledPercentChange /= SCALE(fLifePercentage, 0.f, 1.f, 1.7f, 0.3f);
    }
  }

  // mercy: drop super meter faster if at a higher level
  if (fUnscaledPercentChange < 0) {
    fUnscaledPercentChange *=
        SCALE(
            m_pPlayerState->m_fSuperMeter, 0.f,
            static_cast<float>(NUM_ATTACK_LEVELS), 0.01f, 1.f);
  }

  AttackLevel oldAL = (AttackLevel)(int)m_pPlayerState->m_fSuperMeter;

  float fPercentToMove = fUnscaledPercentChange;
  m_pPlayerState->m_fSuperMeter +=
      fPercentToMove * m_pPlayerState->m_fSuperMeterGrowthScale;
  rage_clamp(m_pPlayerState->m_fSuperMeter, 0.f, NUM_ATTACK_LEVELS);

  AttackLevel newAL = (AttackLevel)(int)m_pPlayerState->m_fSuperMeter;

  if (newAL > oldAL) {
    LaunchAttack(oldAL);
    if (newAL == NUM_ATTACK_LEVELS) {  // hit upper bounds of meter
      m_pPlayerState->m_fSuperMeter -= 1.f;
    }
  }

  // mercy: if losing remove attacks on life drain
  if (fUnscaledPercentChange < 0) {
    bool bWinning;
    switch (m_pPlayerState->m_PlayerNumber) {
      case PLAYER_1:
        bWinning = GetSafeTugLifePercent() > 0.5f;
        break;
      case PLAYER_2:
        bWinning = GetSafeTugLifePercent() < 0.5f;
        break;
      default:
        LOG->Warn(
            "SRC_AUDIT_FIX: ScoreKeeperRave skipped losing attack cleanup for "
            "invalid player %i.",
            m_pPlayerState->m_PlayerNumber);
        return;
    }
    if (!bWinning) {
      m_pPlayerState->EndActiveAttacks();
    }
  }
}

void ScoreKeeperRave::LaunchAttack(AttackLevel al) {
  if (!HasScoringState("ScoreKeeperRave::LaunchAttack") ||
      !HasRaveGlobals("ScoreKeeperRave::LaunchAttack")) {
    return;
  }
  PlayerNumber pn = m_pPlayerState->m_PlayerNumber;
  if (!IsValidRavePlayer(pn) || !IsValidAttackLevel(al)) {
    LOG->Warn(
        "SRC_AUDIT_FIX: ScoreKeeperRave skipped attack launch for player %i "
        "attack level %i.",
        pn, al);
    return;
  }

  std::string sAttackToGive;
  Character* pCharacter = GAMESTATE->m_pCurCharacters[pn];
  if (pCharacter != nullptr) {
    std::string* asAttacks = pCharacter->m_sAttacks[al];
    sAttackToGive = asAttacks[RandomInt(NUM_ATTACKS_PER_LEVEL)];
  } else {
    // "If you add any noteskins here, you need to make sure they're cached,
    // too." -? Noteskins probably won't work here anymore. -aj
    std::string DefaultAttacks[8] = {"1.5x",   "2.0x",  "0.5x",  "reverse",
                                     "sudden", "boost", "brake", "wave"};
    sAttackToGive = DefaultAttacks[RandomInt(8)];
  }
  if (!IsSafeRaveAttackModifier(
          sAttackToGive, "ScoreKeeperRave::LaunchAttack")) {
    LOG->Warn(
        "SRC_AUDIT_FIX SRC-2064: ScoreKeeperRave skipped invalid attack "
        "modifier for player %i attack level %i.",
        pn, al);
    return;
  }
  Trim(sAttackToGive);

  PlayerNumber pnToAttack = OPPOSITE_PLAYER[pn];
  if (!IsValidRavePlayer(pnToAttack)) {
    LOG->Warn(
        "SRC_AUDIT_FIX: ScoreKeeperRave skipped attack from player %i because "
        "target player %i is invalid.",
        pn, pnToAttack);
    return;
  }
  PlayerState* pPlayerStateToAttack = GAMESTATE->m_pPlayerState[pnToAttack];
  if (pPlayerStateToAttack == nullptr) {
    LOG->Warn(
        "SRC_AUDIT_FIX: ScoreKeeperRave skipped attack from player %i because "
        "target player state %i is missing.",
        pn, pnToAttack);
    return;
  }

  Attack a;
  a.level = al;
  a.fSecsRemaining = ClampAttackDuration(ATTACK_DURATION_SECONDS);
  if (a.fSecsRemaining <= 0.0f) {
    LOG->Warn(
        "SRC_AUDIT_FIX: ScoreKeeperRave skipped attack with non-positive "
        "duration %f.",
        a.fSecsRemaining);
    return;
  }
  a.sModifiers = sAttackToGive;

  // remove current attack (if any)
  pPlayerStateToAttack->RemoveActiveAttacks();

  // apply new attack
  pPlayerStateToAttack->LaunchAttack(a);

  //	SCREENMAN->SystemMessage( ssprintf( "attacking %d with %s", pnToAttack,
  // sAttackToGive.c_str() ) );
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
