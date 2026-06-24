#include "PlayerStageStats.h"

#include <algorithm>
#include <cfloat>
#include <cmath>
#include <cstddef>
#include <deque>
#include <limits>
#include <map>
#include <numeric>
#include <string>

#include "CommonMetrics.h"
#include "Course.h"
#include "Difficulty.h"
#include "EnumHelper.h"
#include "GameConstantsAndTypes.h"
#include "GameState.h"
#include "Grade.h"
#include "HighScore.h"
#include "LuaManager.h"
#include "MessageManager.h"
#include "PlayerNumber.h"
#include "PrefsManager.h"
#include "RageLog.h"
#include "RageUtil.h"
#include "ScoreKeeperNormal.h"
#include "Steps.h"
#include "ThemeManager.h"
#include "ThemeMetric.h"
#include "global.h"

static ThemeMetric<TapNoteScore> g_MinScoreToMaintainCombo(
    "Gameplay", "MinScoreToMaintainCombo");
static ThemeMetric<bool> g_MineHitIncrementsMissCombo(
    "Gameplay", "MineHitIncrementsMissCombo");

const float LESSON_PASS_THRESHOLD = 0.8f;
const size_t MAX_COMBO_LIST_ENTRIES = 10000;
const int MAX_LUA_LIFE_RECORD_SAMPLES = 4096;

Grade GetGradeFromPercent(float fPercent);

namespace {
bool IsValidPlayerNumber(PlayerNumber pn) {
  return pn >= PLAYER_1 && pn < NUM_PLAYERS;
}

bool IsValidMultiPlayer(MultiPlayer mp) {
  return mp >= MultiPlayer_P1 && mp < NUM_MultiPlayer;
}

bool IsValidFullComboTapScore(TapNoteScore tns) {
  return tns >= TNS_W5 && tns <= TNS_W1;
}

bool IsValidTapNoteScore(TapNoteScore tns) {
  return tns >= TNS_None && tns < NUM_TapNoteScore;
}

bool IsValidHoldNoteScore(HoldNoteScore hns) {
  return hns >= HNS_None && hns < NUM_HoldNoteScore;
}

bool IsThemeAvailable(const char* context) {
  if (THEME == nullptr || !THEME->IsThemeLoaded()) {
    LOG->Warn(
        "SRC_AUDIT_FIX: %s used fallback because THEME is unavailable.",
        context);
    return false;
  }
  return true;
}

float ClampFiniteFloat(float value, const char* field, float fallback) {
  if (!std::isfinite(value)) {
    LOG->Warn(
        "SRC_AUDIT_FIX: PlayerStageStats normalized non-finite %s value %f "
        "to %f.",
        field, value, fallback);
    return fallback;
  }
  return value;
}

float ClampLifeValue(float value, const char* field) {
  value = ClampFiniteFloat(value, field, 0.0f);
  if (value < 0.0f || value > 1.0f) {
    LOG->Warn(
        "SRC_AUDIT_FIX: PlayerStageStats clamped out-of-range %s value %f.",
        field, value);
  }
  rage_clamp(value, 0.0f, 1.0f);
  return value;
}

int ClampNonNegativeInt(int value, const char* field) {
  if (value < 0) {
    LOG->Warn(
        "SRC_AUDIT_FIX: PlayerStageStats clamped negative %s value %i to 0.",
        field, value);
    return 0;
  }
  return value;
}

int AddNonNegativeIntSaturated(int current, int add, const char* field) {
  current = ClampNonNegativeInt(current, field);
  add = ClampNonNegativeInt(add, field);

  if (add > std::numeric_limits<int>::max() - current) {
    LOG->Warn(
        "SRC_AUDIT_FIX: PlayerStageStats saturated %s integer sum %i + %i.",
        field, current, add);
    return std::numeric_limits<int>::max();
  }
  return current + add;
}

double AddGradeContribution(
    double current, int count, int gradeValue, const char* field) {
  const int safeCount = ClampNonNegativeInt(count, field);
  const double contribution =
      static_cast<double>(safeCount) * static_cast<double>(gradeValue);
  const double result = current + contribution;
  if (!std::isfinite(result)) {
    LOG->Warn(
        "SRC_AUDIT_FIX: PlayerStageStats saturated non-finite grade sum for "
        "%s.",
        field);
    return contribution < 0.0 ? -std::numeric_limits<double>::max()
                              : std::numeric_limits<double>::max();
  }
  return result;
}

unsigned int AddUnsignedSaturated(
    unsigned int current, unsigned int add, const char* field) {
  if (add > std::numeric_limits<unsigned int>::max() - current) {
    LOG->Warn(
        "SRC_AUDIT_FIX: PlayerStageStats saturated %s unsigned sum %u + %u.",
        field, current, add);
    return std::numeric_limits<unsigned int>::max();
  }
  return current + add;
}

int ClampUnsignedToInt(unsigned int value, const char* field) {
  if (value > static_cast<unsigned int>(std::numeric_limits<int>::max())) {
    LOG->Warn(
        "SRC_AUDIT_FIX: PlayerStageStats saturated %s value %u to INT_MAX.",
        field, value);
    return std::numeric_limits<int>::max();
  }
  return static_cast<int>(value);
}

float ClampFiniteNonNegativeFloat(float value, const char* field) {
  if (!std::isfinite(value)) {
    LOG->Warn(
        "SRC_AUDIT_FIX: PlayerStageStats clamped non-finite %s value %f to 0.",
        field, value);
    return 0.0f;
  }
  if (value < 0.0f) {
    LOG->Warn(
        "SRC_AUDIT_FIX: PlayerStageStats clamped negative %s value %f to 0.",
        field, value);
    return 0.0f;
  }
  return value;
}

float AddFiniteNonNegativeFloat(float current, float add, const char* field) {
  current = ClampFiniteNonNegativeFloat(current, field);
  add = ClampFiniteNonNegativeFloat(add, field);

  if (add > std::numeric_limits<float>::max() - current) {
    LOG->Warn(
        "SRC_AUDIT_FIX: PlayerStageStats saturated %s float sum %f + %f.",
        field, current, add);
    return std::numeric_limits<float>::max();
  }
  return current + add;
}

int GetSafePercentDecimalPlaces() {
  const int iDecimals = CommonMetrics::PERCENT_SCORE_DECIMAL_PLACES;
  const int iClamped = std::min(std::max(iDecimals, 0), 6);
  if (iDecimals != iClamped) {
    LOG->Warn(
        "SRC_AUDIT_FIX: Clamped invalid PercentScoreDecimalPlaces %i to %i.",
        iDecimals, iClamped);
  }
  return iClamped;
}

float GetSafeGradePercentTier(Grade g) {
  if (!IsThemeAvailable("GetGradeFromPercent")) {
    return std::numeric_limits<float>::infinity();
  }
  const float value = THEME->GetMetricF(
      "PlayerStageStats",
      ssprintf("GradePercent%s", GradeToString(g).c_str()));
  if (!std::isfinite(value)) {
    LOG->Warn(
        "SRC_AUDIT_FIX: GetGradeFromPercent ignored non-finite threshold for "
        "%s.",
        GradeToString(g).c_str());
    return std::numeric_limits<float>::infinity();
  }
  return value;
}

bool GetSafeGradeMetricB(const char* metricName, bool fallback) {
  if (!IsThemeAvailable(metricName)) {
    return fallback;
  }
  return THEME->GetMetricB("PlayerStageStats", metricName);
}

TapNoteScore GetSafeMinScoreToMaintainCombo() {
  if (!g_MinScoreToMaintainCombo.IsLoaded()) {
    LOG->Warn(
        "SRC_AUDIT_FIX: PlayerStageStats used TNS_W3 because "
        "MinScoreToMaintainCombo is not loaded.");
    return TNS_W3;
  }
  const TapNoteScore tns = g_MinScoreToMaintainCombo.GetValue();
  if (!IsValidFullComboTapScore(tns)) {
    LOG->Warn(
        "SRC_AUDIT_FIX: PlayerStageStats used TNS_W3 because "
        "MinScoreToMaintainCombo is invalid: %i.",
        tns);
    return TNS_W3;
  }
  return tns;
}

bool GetSafeMineHitIncrementsMissCombo() {
  if (!g_MineHitIncrementsMissCombo.IsLoaded()) {
    return false;
  }
  return g_MineHitIncrementsMissCombo.GetValue();
}

bool CurrentCourseIsEndless(const char* context) {
  if (GAMESTATE == nullptr) {
    LOG->Warn(
        "SRC_AUDIT_FIX: %s could not inspect current course because "
        "GAMESTATE is unavailable.",
        context);
    return false;
  }
  return GAMESTATE->m_pCurCourse != nullptr &&
         GAMESTATE->m_pCurCourse->IsEndless();
}

void PushSaneNumber(lua_State* L, float value, const char* field) {
  lua_pushnumber(L, ClampFiniteNonNegativeFloat(value, field));
}
}  // namespace

void PlayerStageStats::InternalInit() {
  m_pStyle = nullptr;
  m_for_multiplayer = false;
  m_player_number = PLAYER_1;
  m_multiplayer_number = MultiPlayer_P1;

  m_bPlayerCanAchieveFullCombo = true;
  m_bJoined = false;
  m_vpPossibleSteps.clear();
  m_iStepsPlayed = 0;
  m_fAliveSeconds = 0;
  m_bFailed = false;
  m_iPossibleDancePoints = 0;
  m_iCurPossibleDancePoints = 0;
  m_iActualDancePoints = 0;
  m_iPossibleGradePoints = 0;
  m_iCurCombo = 0;
  m_iMaxCombo = 0;
  m_iCurMissCombo = 0;
  m_iCurScoreMultiplier = 1;
  m_iScore = 0;
  m_iMaxScore = 0;
  m_iCurMaxScore = 0;
  m_iSongsPassed = 0;
  m_iSongsPlayed = 0;
  m_fLifeRemainingSeconds = 0;
  m_iNumControllerSteps = 0;
  m_fCaloriesBurned = 0;

  ZERO(m_iTapNoteScores);
  ZERO(m_iHoldNoteScores);
  m_radarPossible.Zero();
  m_radarActual.Zero();

  m_fFirstSecond = FLT_MAX;
  m_fLastSecond = 0;

  m_StageAward = StageAward_Invalid;
  m_PeakComboAward = PeakComboAward_Invalid;
  m_iPersonalHighScoreIndex = -1;
  m_iMachineHighScoreIndex = -1;
  m_bDisqualified = false;
  m_rc = RankingCategory_Invalid;
  m_HighScore = HighScore();
}

void PlayerStageStats::Init(PlayerNumber pn) {
  InternalInit();
  m_for_multiplayer = false;
  if (!IsValidPlayerNumber(pn)) {
    LOG->Warn(
        "SRC_AUDIT_FIX: PlayerStageStats::Init received invalid player %i; "
        "defaulting to PLAYER_1.",
        pn);
    pn = PLAYER_1;
  }
  m_player_number = pn;
}

void PlayerStageStats::Init(MultiPlayer pn) {
  InternalInit();
  m_for_multiplayer = true;
  if (!IsValidMultiPlayer(pn)) {
    LOG->Warn(
        "SRC_AUDIT_FIX: PlayerStageStats::Init received invalid multiplayer "
        "%i; defaulting to MultiPlayer_P1.",
        pn);
    pn = MultiPlayer_P1;
  }
  m_multiplayer_number = pn;
}

void PlayerStageStats::AddStats(const PlayerStageStats& other) {
  m_pStyle = other.m_pStyle;
  m_bJoined |= other.m_bJoined;
  for (Steps* s : other.m_vpPossibleSteps) {
    if (s == nullptr) {
      LOG->Warn(
          "SRC_AUDIT_FIX: PlayerStageStats::AddStats skipped null possible "
          "steps.");
      continue;
    }
    m_vpPossibleSteps.push_back(s);
  }
  m_iStepsPlayed = AddNonNegativeIntSaturated(
      m_iStepsPlayed, other.m_iStepsPlayed, "steps played");
  m_fAliveSeconds =
      AddFiniteNonNegativeFloat(m_fAliveSeconds, other.m_fAliveSeconds,
                                "alive seconds");
  m_bFailed |= other.m_bFailed;
  m_iPossibleDancePoints = AddNonNegativeIntSaturated(
      m_iPossibleDancePoints, other.m_iPossibleDancePoints,
      "possible dance points");
  m_iActualDancePoints = AddNonNegativeIntSaturated(
      m_iActualDancePoints, other.m_iActualDancePoints, "actual dance points");
  m_iCurPossibleDancePoints = AddNonNegativeIntSaturated(
      m_iCurPossibleDancePoints, other.m_iCurPossibleDancePoints,
      "current possible dance points");
  m_iPossibleGradePoints = AddNonNegativeIntSaturated(
      m_iPossibleGradePoints, other.m_iPossibleGradePoints,
      "possible grade points");

  for (int t = 0; t < NUM_TapNoteScore; t++) {
    m_iTapNoteScores[t] = AddNonNegativeIntSaturated(
        m_iTapNoteScores[t], other.m_iTapNoteScores[t], "tap note score");
  }
  for (int h = 0; h < NUM_HoldNoteScore; h++) {
    m_iHoldNoteScores[h] = AddNonNegativeIntSaturated(
        m_iHoldNoteScores[h], other.m_iHoldNoteScores[h], "hold note score");
  }
  m_iCurCombo =
      AddUnsignedSaturated(m_iCurCombo, other.m_iCurCombo, "current combo");
  m_iMaxCombo =
      AddUnsignedSaturated(m_iMaxCombo, other.m_iMaxCombo, "max combo");
  m_iCurMissCombo = AddUnsignedSaturated(
      m_iCurMissCombo, other.m_iCurMissCombo, "current miss combo");
  m_iScore = AddUnsignedSaturated(m_iScore, other.m_iScore, "score");
  m_iMaxScore =
      AddUnsignedSaturated(m_iMaxScore, other.m_iMaxScore, "max score");
  m_iCurMaxScore = AddUnsignedSaturated(
      m_iCurMaxScore, other.m_iCurMaxScore, "current max score");
  FOREACH_ENUM(RadarCategory, rc) {
    m_radarPossible[rc] = AddFiniteNonNegativeFloat(
        m_radarPossible[rc], other.m_radarPossible[rc], "possible radar");
    m_radarActual[rc] = AddFiniteNonNegativeFloat(
        m_radarActual[rc], other.m_radarActual[rc], "actual radar");
  }
  m_iSongsPassed = AddNonNegativeIntSaturated(
      m_iSongsPassed, other.m_iSongsPassed, "songs passed");
  m_iSongsPlayed = AddNonNegativeIntSaturated(
      m_iSongsPlayed, other.m_iSongsPlayed, "songs played");
  m_iNumControllerSteps = AddFiniteNonNegativeFloat(
      m_iNumControllerSteps, other.m_iNumControllerSteps, "controller steps");
  m_fCaloriesBurned = AddFiniteNonNegativeFloat(
      m_fCaloriesBurned, other.m_fCaloriesBurned, "calories burned");
  m_fLifeRemainingSeconds = ClampFiniteNonNegativeFloat(
      other.m_fLifeRemainingSeconds, "life remaining seconds");  // don't accumulate
  m_bDisqualified |= other.m_bDisqualified;

  // FirstSecond is always 0, and last second is the time of the last step,
  // so add 1 second between the stages so that the last element of this
  // stage's record isn't overwritten by the first element of the other
  // stage's record. -Kyz
  const float baseLastSecond =
      ClampFiniteNonNegativeFloat(m_fLastSecond, "last second");
  const float otherFirstSecond =
      other.m_fFirstSecond == FLT_MAX
          ? 0.0f
          : ClampFiniteNonNegativeFloat(other.m_fFirstSecond, "first second");
  const float otherLastSecond =
      ClampFiniteNonNegativeFloat(other.m_fLastSecond, "last second");
  const float fOtherFirstSecond = otherFirstSecond + baseLastSecond + 1.0f;
  const float fOtherLastSecond = otherLastSecond + baseLastSecond + 1.0f;
  if (!std::isfinite(fOtherFirstSecond) || !std::isfinite(fOtherLastSecond)) {
    LOG->Warn(
        "SRC_AUDIT_FIX: PlayerStageStats::AddStats skipped time-series merge "
        "because offsets are non-finite: first=%f last=%f.",
        fOtherFirstSecond, fOtherLastSecond);
    return;
  }
  m_fLastSecond = fOtherLastSecond;

  std::map<float, float>::const_iterator it;
  for (it = other.m_fLifeRecord.begin(); it != other.m_fLifeRecord.end();
       ++it) {
    const float pos = it->first;
    const float life = it->second;
    if (!std::isfinite(pos) || !std::isfinite(life)) {
      LOG->Warn(
          "SRC_AUDIT_FIX: PlayerStageStats::AddStats skipped non-finite life "
          "record pos=%f life=%f.",
          pos, life);
      continue;
    }
    const float shiftedPos = fOtherFirstSecond + pos;
    if (!std::isfinite(shiftedPos)) {
      LOG->Warn(
          "SRC_AUDIT_FIX: PlayerStageStats::AddStats skipped life record with "
          "non-finite shifted position %f.",
          shiftedPos);
      continue;
    }
    m_fLifeRecord[shiftedPos] = ClampLifeValue(life, "life record");
  }

  for (size_t i = 0; i < other.m_ComboList.size(); ++i) {
    if (m_ComboList.size() >= MAX_COMBO_LIST_ENTRIES) {
      LOG->Warn(
          "SRC_AUDIT_FIX: PlayerStageStats::AddStats capped combo list at "
          "%zu entries.",
          MAX_COMBO_LIST_ENTRIES);
      break;
    }
    const Combo_t& combo = other.m_ComboList[i];
    if (!std::isfinite(combo.m_fStartSecond) ||
        !std::isfinite(combo.m_fSizeSeconds) || combo.m_fSizeSeconds < 0.0f ||
        combo.m_cnt < 0 || combo.m_rollover < 0 ||
        combo.m_rollover > combo.m_cnt) {
      LOG->Warn(
          "SRC_AUDIT_FIX: PlayerStageStats::AddStats skipped invalid combo "
          "start=%f size=%f count=%i rollover=%i.",
          combo.m_fStartSecond, combo.m_fSizeSeconds, combo.m_cnt,
          combo.m_rollover);
      continue;
    }

    Combo_t newcombo(combo);
    newcombo.m_fStartSecond += fOtherFirstSecond;
    if (!std::isfinite(newcombo.m_fStartSecond)) {
      LOG->Warn(
          "SRC_AUDIT_FIX: PlayerStageStats::AddStats skipped combo with "
          "non-finite shifted start %f.",
          newcombo.m_fStartSecond);
      continue;
    }
    m_ComboList.push_back(newcombo);
  }

  /* Merge identical combos. This normally only happens in course mode, when
   * a combo continues between songs. */
  for (size_t i = 1; i < m_ComboList.size(); ++i) {
    Combo_t& prevcombo = m_ComboList[i - 1];
    Combo_t& combo = m_ComboList[i];
    const float PrevComboEnd =
        prevcombo.m_fStartSecond + prevcombo.m_fSizeSeconds;
    const float ThisComboStart = combo.m_fStartSecond;
    if (std::abs(PrevComboEnd - ThisComboStart) > 0.001) {
      continue;
    }

    // These are really the same combo.
    prevcombo.m_fSizeSeconds = AddFiniteNonNegativeFloat(
        prevcombo.m_fSizeSeconds, combo.m_fSizeSeconds, "combo size seconds");
    prevcombo.m_cnt = AddNonNegativeIntSaturated(
        prevcombo.m_cnt, combo.m_cnt, "combo count");
    m_ComboList.erase(m_ComboList.begin() + i);
    --i;
  }
}

Grade GetGradeFromPercent(float fPercent) {
  if (!std::isfinite(fPercent)) {
    LOG->Warn(
        "SRC_AUDIT_FIX: GetGradeFromPercent received non-finite percent %f.",
        fPercent);
    return Grade_Failed;
  }

  Grade grade = Grade_Failed;

  for (Grade g = Grade_Tier01; g < GetNumGradeTiersUsed();
       enum_add<Grade>(g, 1)) {
    if (fPercent >= GetSafeGradePercentTier(g)) {
      grade = g;
      break;
    }
  }
  return grade;
}

Grade PlayerStageStats::GetGrade() const {
  if (m_bFailed) {
    return Grade_Failed;
  }
  if (m_iPossibleGradePoints <= 0) {
    if (m_iPossibleGradePoints < 0) {
      LOG->Warn(
          "SRC_AUDIT_FIX: PlayerStageStats::GetGrade ignored negative "
          "possible grade points %i.",
          m_iPossibleGradePoints);
    }
    return GetGradeFromPercent(0.0f);
  }

  /* XXX: This entire calculation should be in ScoreKeeper, but final evaluation
   * is tricky since at that point the ScoreKeepers no longer exist. */
  double fActual = 0.0;

  bool bIsBeginner = false;
  if (m_iStepsPlayed == 1) {
    if (!m_vpPossibleSteps.empty() && m_vpPossibleSteps[0] != nullptr) {
      bIsBeginner =
          m_vpPossibleSteps[0]->GetDifficulty() == Difficulty_Beginner;
    } else {
      LOG->Warn(
          "SRC_AUDIT_FIX: PlayerStageStats::GetGrade could not inspect "
          "beginner difficulty because possible steps are missing.");
    }
  }

  FOREACH_ENUM(TapNoteScore, tns) {
    int iTapScoreValue =
        ScoreKeeperNormal::TapNoteScoreToGradePoints(tns, bIsBeginner);
    fActual = AddGradeContribution(
        fActual, m_iTapNoteScores[tns], iTapScoreValue, "tap grade count");
    // LOG->Trace( "GetGrade actual: %i * %i", m_iTapNoteScores[tns],
    // iTapScoreValue );
  }

  FOREACH_ENUM(HoldNoteScore, hns) {
    int iHoldScoreValue =
        ScoreKeeperNormal::HoldNoteScoreToGradePoints(hns, bIsBeginner);
    fActual = AddGradeContribution(
        fActual, m_iHoldNoteScores[hns], iHoldScoreValue, "hold grade count");
    // LOG->Trace( "GetGrade actual: %i * %i", m_iHoldNoteScores[hns],
    // iHoldScoreValue );
  }

  // LOG->Trace( "GetGrade: fActual: %f, fPossible: %d", fActual,
  // m_iPossibleGradePoints );

  float fPercent = static_cast<float>(fActual / m_iPossibleGradePoints);

  Grade grade = GetGradeFromPercent(fPercent);

  // LOG->Trace( "GetGrade: Grade: %s, %i", GradeToString(grade).c_str(),
  // GRADE_TIER02_IS_ALL_W2S );

  // TODO: Change these conditions to use Lua instead. -aj
  if (GetSafeGradeMetricB("GradeTier02IsAllW2s", false)) {
    if (FullComboOfScore(TNS_W1)) {
      return Grade_Tier01;
    }

    if (FullComboOfScore(TNS_W2)) {
      return Grade_Tier02;
    }

    grade = std::max(grade, Grade_Tier03);
  }

  if (GetSafeGradeMetricB("GradeTier01IsAllW2s", false)) {
    if (FullComboOfScore(TNS_W2)) {
      return Grade_Tier01;
    }
    grade = std::max(grade, Grade_Tier02);
  }

  if (GetSafeGradeMetricB("GradeTier02IsFullCombo", false)) {
    if (FullComboOfScore(GetSafeMinScoreToMaintainCombo())) {
      return Grade_Tier02;
    }
    grade = std::max(grade, Grade_Tier03);
  }

  return grade;
}

float PlayerStageStats::MakePercentScore(int iActual, int iPossible) {
  if (iPossible <= 0) {
    return 0;  // div/0
  }

  if (iActual >= iPossible) {
    return 1;  // correct for rounding error
  }

  // This can happen in battle, with transform attacks.
  // ASSERT_M( iActual <= iPossible, ssprintf("%i/%i", iActual, iPossible) );

  float fPercent = iActual / (float)iPossible;

  // don't allow negative
  fPercent = std::max(0.0f, fPercent);

  int iPercentTotalDigits =
      3 + GetSafePercentDecimalPlaces();  // "100" + "." + "00"

  // TRICKY: printf will round, but we want to truncate. Otherwise, we may
  // display a percent score that's too high and doesn't match up with the
  // calculated grade.
  float fTruncInterval = std::pow(0.1f, (float)iPercentTotalDigits - 1);

  // TRICKY: ftruncf is rounding 1.0000000 to 0.99990004. Give a little boost
  // to fPercentDancePoints to correct for this.
  fPercent += 0.000001f;

  fPercent = ftruncf(fPercent, fTruncInterval);
  return fPercent;
}

std::string PlayerStageStats::FormatPercentScore(float fPercentDancePoints) {
  if (!std::isfinite(fPercentDancePoints)) {
    LOG->Warn(
        "SRC_AUDIT_FIX: FormatPercentScore received non-finite percent %f.",
        fPercentDancePoints);
    fPercentDancePoints = 0.0f;
  }
  fPercentDancePoints = std::max(0.0f, std::min(1.0f, fPercentDancePoints));

  const int iDecimals = GetSafePercentDecimalPlaces();
  int iPercentTotalDigits = 3 + iDecimals;  // "100" + "." + "00"

  std::string s = ssprintf(
      "%*.*f%%", iPercentTotalDigits, iDecimals, fPercentDancePoints * 100);
  return s;
}

float PlayerStageStats::GetPercentDancePoints() const {
  return MakePercentScore(m_iActualDancePoints, m_iPossibleDancePoints);
}

float PlayerStageStats::GetCurMaxPercentDancePoints() const {
  return MakePercentScore(m_iCurPossibleDancePoints, m_iPossibleDancePoints);
}

// TODO: Make this use lua. Let more judgments be possible. -Wolfman2000
int PlayerStageStats::GetLessonScoreActual() const {
  int iScore = 0;

  FOREACH_ENUM(TapNoteScore, tns) {
    switch (tns) {
      case TNS_AvoidMine:
      case TNS_W5:
      case TNS_W4:
      case TNS_W3:
      case TNS_W2:
      case TNS_W1:
        iScore = AddNonNegativeIntSaturated(
            iScore, m_iTapNoteScores[tns], "lesson tap score");
      default:
        break;
    }
  }

  FOREACH_ENUM(HoldNoteScore, hns) {
    switch (hns) {
      case HNS_Held:
        iScore = AddNonNegativeIntSaturated(
            iScore, m_iHoldNoteScores[hns], "lesson hold score");
      default:
        break;
    }
  }

  return iScore;
}

int PlayerStageStats::GetLessonScoreNeeded() const {
  const PlayerNumber pn =
      (m_player_number >= PLAYER_1 && m_player_number < NUM_PLAYERS)
          ? m_player_number
          : PLAYER_1;
  float fScore = std::accumulate(
      m_vpPossibleSteps.begin(), m_vpPossibleSteps.end(), 0.f,
      [pn](float total, const Steps* steps) {
        if (steps == nullptr) {
          LOG->Warn(
              "SRC_AUDIT_FIX: PlayerStageStats::GetLessonScoreNeeded skipped "
              "null steps.");
          return total;
        }
        const float tapsAndHolds =
            steps->GetRadarValues(pn)[RadarCategory_TapsAndHolds];
        if (!std::isfinite(tapsAndHolds) || tapsAndHolds < 0.0f) {
          LOG->Warn(
              "SRC_AUDIT_FIX: PlayerStageStats::GetLessonScoreNeeded skipped "
              "invalid radar total %f.",
              tapsAndHolds);
          return total;
        }
        return total + tapsAndHolds;
      });
  if (!std::isfinite(fScore) || fScore <= 0.0f) {
    return 0;
  }
  const double needed = static_cast<double>(fScore) * LESSON_PASS_THRESHOLD;
  if (needed > std::numeric_limits<int>::max()) {
    LOG->Warn(
        "SRC_AUDIT_FIX: PlayerStageStats::GetLessonScoreNeeded saturated "
        "score %f.",
        needed);
    return std::numeric_limits<int>::max();
  }
  return std::lrint(needed);
}

void PlayerStageStats::ResetScoreForLesson() {
  m_iPossibleDancePoints = 0;
  m_iCurPossibleDancePoints = 0;
  m_iActualDancePoints = 0;
  m_iPossibleGradePoints = 0;
  FOREACH_ENUM(TapNoteScore, tns)
  m_iTapNoteScores[tns] = 0;
  FOREACH_ENUM(HoldNoteScore, hns)
  m_iHoldNoteScores[hns] = 0;
  m_iCurCombo = 0;
  m_iMaxCombo = 0;
  m_iCurMissCombo = 0;
  m_iScore = 0;
  m_iCurMaxScore = 0;
  m_iMaxScore = 0;
  m_radarPossible.Zero();
  m_radarActual.Zero();
  m_bFailed = false;
  m_bPlayerCanAchieveFullCombo = true;
  m_fAliveSeconds = 0.0f;
  m_fLifeRemainingSeconds = 0.0f;
  m_fLifeRecord.clear();
  m_ComboList.clear();
  m_fFirstSecond = FLT_MAX;
  m_fLastSecond = 0.0f;
  m_StageAward = StageAward_Invalid;
  m_PeakComboAward = PeakComboAward_Invalid;
  m_iPersonalHighScoreIndex = -1;
  m_iMachineHighScoreIndex = -1;
  m_bDisqualified = false;
  m_rc = RankingCategory_Invalid;
  m_HighScore = HighScore();
}

void PlayerStageStats::SetLifeRecordAt(float fLife, float fStepsSecond) {
  // Don't save life stats in endless courses, or could run OOM in a few hours.
  if (CurrentCourseIsEndless("PlayerStageStats::SetLifeRecordAt")) {
    return;
  }

  if (!std::isfinite(fLife) || !std::isfinite(fStepsSecond)) {
    LOG->Warn(
        "SRC_AUDIT_FIX: PlayerStageStats::SetLifeRecordAt ignored "
        "non-finite life record life=%f second=%f.",
        fLife, fStepsSecond);
    return;
  }

  if (fStepsSecond < 0) {
    return;
  }
  fLife = ClampLifeValue(fLife, "life record");

  m_fFirstSecond = std::min(fStepsSecond, m_fFirstSecond);
  m_fLastSecond = std::max(fStepsSecond, m_fLastSecond);
  // LOG->Trace( "fLastSecond = %f", m_fLastSecond );

  // fStepsSecond will usually be greater than any value already in the map,
  // but if a tap and a hold both set the life on the same frame, it won't.
  // Check whether an entry already exists for the current time, and move it
  // back a tiny bit if it does and the new value is not the same as the old.
  // Otherwise, you get the rare bug where the life graph shows a gradual
  // decline when the lifebar was actually full up to a miss.  This occurs
  // because the first call has full life, and removes the previous full life
  // entry.  Then the second call of the frame occurs and sets the life for
  // the current time to a lower value.
  // -Kyz
  std::map<float, float>::iterator curr = m_fLifeRecord.find(fStepsSecond);
  if (curr != m_fLifeRecord.end()) {
    if (curr->second != fLife) {
      // 2^-8
      const float previousSecond = std::max(0.0f, fStepsSecond - 0.00390625f);
      if (previousSecond != fStepsSecond) {
        m_fLifeRecord[previousSecond] = curr->second;
      }
      // At exactly 0s, there is no earlier timestamp where the previous life
      // value can be represented. Replacing the initial value is intentional.
    }
  }
  m_fLifeRecord[fStepsSecond] = fLife;

  if (IsValidPlayerNumber(m_player_number)) {
    Message msg(
        static_cast<MessageID>(
            Message_LifeMeterChangedP1 + Enum::to_integral(m_player_number)));
    msg.SetParam("Life", fLife);
    msg.SetParam("StepsSecond", fStepsSecond);
    if (MESSAGEMAN != nullptr) {
      MESSAGEMAN->Broadcast(msg);
    } else {
      LOG->Warn(
          "SRC_AUDIT_FIX: PlayerStageStats::SetLifeRecordAt skipped life "
          "message because MESSAGEMAN is unavailable.");
    }
  } else {
    LOG->Warn(
        "SRC_AUDIT_FIX: PlayerStageStats::SetLifeRecordAt skipped life "
        "message for invalid player %i.",
        m_player_number);
  }

  // Memory optimization:
  // If we have three consecutive records A, B, and C all with the same fLife,
  // we can eliminate record B without losing data. Only check the last three
  // records in the map since we're only inserting at the end, and we know all
  // earlier redundant records have already been removed.
  std::map<float, float>::iterator C = m_fLifeRecord.end();
  --C;
  if (C == m_fLifeRecord.begin()) {  // no earlier records left
    return;
  }

  std::map<float, float>::iterator B = C;
  --B;
  if (B == m_fLifeRecord.begin()) {  // no earlier records left
    return;
  }

  std::map<float, float>::iterator A = B;
  --A;

  if (A->second == B->second && B->second == C->second) {
    m_fLifeRecord.erase(B);
  }
}

float PlayerStageStats::GetLifeRecordAt(float fStepsSecond) const {
  if (!std::isfinite(fStepsSecond) || fStepsSecond < 0.0f) {
    LOG->Warn(
        "SRC_AUDIT_FIX: PlayerStageStats::GetLifeRecordAt normalized invalid "
        "second %f.",
        fStepsSecond);
    fStepsSecond = 0.0f;
  }
  if (m_fLifeRecord.empty()) {
    return 0;
  }

  // Find the first element whose key is greater than k.
  std::map<float, float>::const_iterator it =
      m_fLifeRecord.upper_bound(fStepsSecond);

  // Find the last element whose key is less than or equal to k.
  if (it != m_fLifeRecord.begin()) {
    --it;
  }

  return ClampLifeValue(it->second, "life record");
}

float PlayerStageStats::GetLifeRecordLerpAt(float fStepsSecond) const {
  if (!std::isfinite(fStepsSecond) || fStepsSecond < 0.0f) {
    LOG->Warn(
        "SRC_AUDIT_FIX: PlayerStageStats::GetLifeRecordLerpAt normalized "
        "invalid second %f.",
        fStepsSecond);
    fStepsSecond = 0.0f;
  }
  if (m_fLifeRecord.empty()) {
    return 0;
  }

  // Find the first element whose key is greater than k.
  std::map<float, float>::const_iterator later =
      m_fLifeRecord.upper_bound(fStepsSecond);

  // Find the last element whose key is less than or equal to k.
  std::map<float, float>::const_iterator earlier = later;
  if (earlier != m_fLifeRecord.begin()) {
    --earlier;
  }

  if (later == m_fLifeRecord.end()) {
    return ClampLifeValue(earlier->second, "life record");
  }

  if (earlier->first == later->first) {  // two samples from the same time.
                                         // Don't divide by zero in SCALE
    return ClampLifeValue(earlier->second, "life record");
  }

  // earlier <= pos <= later
  const float value = SCALE(
      fStepsSecond, earlier->first, later->first, earlier->second,
      later->second);
  return ClampLifeValue(value, "life record");
}

void PlayerStageStats::GetLifeRecord(
    float* fLifeOut, int iNumSamples, float fStepsEndSecond) const {
  if (fLifeOut == nullptr || iNumSamples <= 0) {
    LOG->Warn(
        "SRC_AUDIT_FIX: PlayerStageStats::GetLifeRecord ignored invalid "
        "output buffer=%p samples=%i.",
        static_cast<void*>(fLifeOut), iNumSamples);
    return;
  }
  if (!std::isfinite(fStepsEndSecond) || fStepsEndSecond < 0.0f) {
    LOG->Warn(
        "SRC_AUDIT_FIX: PlayerStageStats::GetLifeRecord normalized invalid "
        "end second %f.",
        fStepsEndSecond);
    fStepsEndSecond = 0.0f;
  }
  if (iNumSamples == 1) {
    fLifeOut[0] = GetLifeRecordLerpAt(0.0f);
    return;
  }
  for (int i = 0; i < iNumSamples; ++i) {
    float from = SCALE(i, 0, (float)iNumSamples - 1.0f, 0.0f, fStepsEndSecond);
    fLifeOut[i] = GetLifeRecordLerpAt(from);
  }
}

float PlayerStageStats::GetCurrentLife() const {
  if (m_fLifeRecord.empty()) {
    return 0;
  }
  std::map<float, float>::const_iterator iter = m_fLifeRecord.end();
  --iter;
  return ClampLifeValue(iter->second, "life record");
}

/* If bRollover is true, we're being called before gameplay begins, so we can
 * record the amount of the first combo that comes from the previous song. */
void PlayerStageStats::UpdateComboList(float fSecond, bool bRollover) {
  // Don't save combo stats in endless courses, or could run OOM in a few hours.
  if (CurrentCourseIsEndless("PlayerStageStats::UpdateComboList")) {
    return;
  }

  if (!std::isfinite(fSecond) || fSecond < 0.0f) {
    LOG->Warn(
        "SRC_AUDIT_FIX: PlayerStageStats::UpdateComboList ignored invalid "
        "second %f.",
        fSecond);
    return;
  }

  if (!bRollover) {
    m_fFirstSecond = std::min(fSecond, m_fFirstSecond);
    m_fLastSecond = std::max(fSecond, m_fLastSecond);
    // LOG->Trace( "fLastSecond = %f", fLastSecond );
  }

  int cnt = ClampUnsignedToInt(m_iCurCombo, "current combo");
  if (!cnt) {
    return;  // no combo
  }

  if (m_ComboList.size() == 0 || m_ComboList.back().m_cnt >= cnt) {
    /* If the previous combo (if any) starts on -9999, then we rolled over
     * some combo, but missed the first step. Remove it. */
    if (m_ComboList.size() && m_ComboList.back().m_fStartSecond == -9999) {
      m_ComboList.erase(
          m_ComboList.begin() + m_ComboList.size() - 1, m_ComboList.end());
    }

    // This is a new combo.
    if (m_ComboList.size() >= MAX_COMBO_LIST_ENTRIES) {
      LOG->Warn(
          "SRC_AUDIT_FIX: PlayerStageStats::UpdateComboList capped combo list "
          "at %zu entries.",
          MAX_COMBO_LIST_ENTRIES);
      return;
    }
    Combo_t NewCombo;
    /* "start" is the position that the combo started within this song.
     * If we're recording rollover, the combo hasn't started yet (within
     * this song), so put a placeholder in and set it on the next call.
     * (Otherwise, start will be less than fFirstPos.) */
    if (bRollover) {
      NewCombo.m_fStartSecond = -9999;
    } else {
      NewCombo.m_fStartSecond = fSecond;
    }
    m_ComboList.push_back(NewCombo);
  }

  Combo_t& combo = m_ComboList.back();
  if (!bRollover && combo.m_fStartSecond == -9999) {
    combo.m_fStartSecond = 0;
  }

  combo.m_fSizeSeconds = std::max(0.0f, fSecond - combo.m_fStartSecond);
  if (!std::isfinite(combo.m_fSizeSeconds)) {
    LOG->Warn(
        "SRC_AUDIT_FIX: PlayerStageStats::UpdateComboList normalized "
        "non-finite combo size %f.",
        combo.m_fSizeSeconds);
    combo.m_fSizeSeconds = 0.0f;
  }
  combo.m_cnt = cnt;

  if (bRollover) {
    combo.m_rollover = cnt;
  }
}

/* This returns the largest combo contained within the song, as if
 * m_bComboContinuesBetweenSongs is turned off. */
PlayerStageStats::Combo_t PlayerStageStats::GetMaxCombo() const {
  if (m_ComboList.size() == 0) {
    return Combo_t();
  }

  int m = 0;
  for (unsigned i = 1; i < m_ComboList.size(); ++i) {
    if (m_ComboList[i].m_cnt > m_ComboList[m].m_cnt) {
      m = i;
    }
  }

  return m_ComboList[m];
}

int PlayerStageStats::GetComboAtStartOfStage() const {
  if (m_ComboList.empty()) {
    return 0;
  } else {
    return m_ComboList[0].m_rollover;
  }
}

bool PlayerStageStats::FullComboOfScore(
    TapNoteScore tnsAllGreaterOrEqual) const {
  if (!IsValidFullComboTapScore(tnsAllGreaterOrEqual)) {
    LOG->Warn(
        "SRC_AUDIT_FIX: PlayerStageStats::FullComboOfScore ignored invalid "
        "tap score %i.",
        tnsAllGreaterOrEqual);
    return false;
  }

  // if we've set MissCombo to anything besides 0, it's not a full combo
  if (!m_bPlayerCanAchieveFullCombo) {
    return false;
  }

  // If missed any holds, then it's not a full combo
  if (ClampNonNegativeInt(m_iHoldNoteScores[HNS_LetGo], "hold note score") >
      0) {
    return false;
  }

  // if any checkpoints were missed, it's not a full combo	either
  if (ClampNonNegativeInt(
          m_iTapNoteScores[TNS_CheckpointMiss], "tap note score") > 0) {
    return false;
  }

  // If has any of the judgments below, then not a full combo
  for (int i = TNS_Miss; i < tnsAllGreaterOrEqual; i++) {
    if (ClampNonNegativeInt(m_iTapNoteScores[i], "tap note score") > 0) {
      return false;
    }
  }

  // hit any mines when they increment the miss combo? It's not a full combo.
  if (GetSafeMineHitIncrementsMissCombo() &&
      ClampNonNegativeInt(m_iTapNoteScores[TNS_HitMine], "tap note score") >
          0) {
    return false;
  }

  // If has at least one of the judgments equal to or above, then is a full
  // combo.
  for (int i = tnsAllGreaterOrEqual; i < NUM_TapNoteScore; i++) {
    if (ClampNonNegativeInt(m_iTapNoteScores[i], "tap note score") > 0) {
      return true;
    }
  }

  return false;
}

TapNoteScore PlayerStageStats::GetBestFullComboTapNoteScore() const {
  // Optimization opportunity: ...
  // (seriously? -aj)
  for (TapNoteScore i = TNS_W1; i >= TNS_W5; enum_add(i, -1)) {
    if (FullComboOfScore(i)) {
      return i;
    }
  }
  return TapNoteScore_Invalid;
}

bool PlayerStageStats::SingleDigitsOfScore(
    TapNoteScore tnsAllGreaterOrEqual) const {
  if (!IsValidFullComboTapScore(tnsAllGreaterOrEqual)) {
    LOG->Warn(
        "SRC_AUDIT_FIX: PlayerStageStats::SingleDigitsOfScore ignored "
        "invalid tap score %i.",
        tnsAllGreaterOrEqual);
    return false;
  }
  return FullComboOfScore(tnsAllGreaterOrEqual) &&
         ClampNonNegativeInt(
             m_iTapNoteScores[tnsAllGreaterOrEqual], "tap note score") < 10;
}

bool PlayerStageStats::OneOfScore(TapNoteScore tnsAllGreaterOrEqual) const {
  if (!IsValidFullComboTapScore(tnsAllGreaterOrEqual)) {
    LOG->Warn(
        "SRC_AUDIT_FIX: PlayerStageStats::OneOfScore ignored invalid tap "
        "score %i.",
        tnsAllGreaterOrEqual);
    return false;
  }
  return FullComboOfScore(tnsAllGreaterOrEqual) &&
         ClampNonNegativeInt(
             m_iTapNoteScores[tnsAllGreaterOrEqual], "tap note score") == 1;
}

int PlayerStageStats::GetTotalTaps() const {
  int iTotalTaps = 0;
  for (int i = TNS_Miss; i < NUM_TapNoteScore; i++) {
    iTotalTaps = AddNonNegativeIntSaturated(
        iTotalTaps, m_iTapNoteScores[i], "total taps");
  }
  return iTotalTaps;
}

float PlayerStageStats::GetPercentageOfTaps(TapNoteScore tns) const {
  if (tns < TNS_None || tns >= NUM_TapNoteScore) {
    LOG->Warn(
        "SRC_AUDIT_FIX: PlayerStageStats::GetPercentageOfTaps ignored "
        "invalid tap score %i.",
        tns);
    return 0.0f;
  }
  int iTotalTaps = 0;
  for (int i = TNS_Miss; i < NUM_TapNoteScore; i++) {
    iTotalTaps = AddNonNegativeIntSaturated(
        iTotalTaps, m_iTapNoteScores[i], "total taps");
  }
  if (iTotalTaps <= 0) {
    return 0.0f;
  }
  return ClampNonNegativeInt(m_iTapNoteScores[tns], "tap note score") /
         (float)iTotalTaps;
}

void PlayerStageStats::CalcAwards(
    PlayerNumber p, bool bGaveUp, bool bUsedAutoplay) {
  // LOG->Trace( "hand out awards" );

  m_PeakComboAward = PeakComboAward_Invalid;

  if (!IsValidPlayerNumber(p)) {
    LOG->Warn(
        "SRC_AUDIT_FIX: PlayerStageStats::CalcAwards ignored invalid player "
        "%i.",
        p);
    return;
  }
  if (GAMESTATE == nullptr) {
    LOG->Warn(
        "SRC_AUDIT_FIX: PlayerStageStats::CalcAwards skipped because "
        "GAMESTATE is unavailable.");
    return;
  }

  if (bGaveUp || bUsedAutoplay) {
    return;
  }

  // LOG->Trace( "per difficulty awards" );

  // per-difficulty awards
  // don't give per-difficutly awards if using easy mods
  StageAward stageAward = StageAward_Invalid;
  if (!IsDisqualified()) {
    if (FullComboOfScore(TNS_W3)) {
      stageAward = StageAward_FullComboW3;
    }
    if (SingleDigitsOfScore(TNS_W3)) {
      stageAward = StageAward_SingleDigitW3;
    }
    if (FullComboOfScore(TNS_W2)) {
      stageAward = StageAward_FullComboW2;
    }
    if (SingleDigitsOfScore(TNS_W2)) {
      stageAward = StageAward_SingleDigitW2;
    }
    if (FullComboOfScore(TNS_W1)) {
      stageAward = StageAward_FullComboW1;
    }

    if (OneOfScore(TNS_W3)) {
      stageAward = StageAward_OneW3;
    }
    if (OneOfScore(TNS_W2)) {
      stageAward = StageAward_OneW2;
    }

    float fPercentW3s = GetPercentageOfTaps(TNS_W3);
    if (fPercentW3s >= 0.8f) {
      stageAward = StageAward_80PercentW3;
    }
    if (fPercentW3s >= 0.9f) {
      stageAward = StageAward_90PercentW3;
    }
    if (fPercentW3s >= 1.f) {
      stageAward = StageAward_100PercentW3;
    }
  }

  m_StageAward = stageAward;
  std::deque<StageAward>& vPdas = GAMESTATE->m_vLastStageAwards[p];
  vPdas.clear();
  if (stageAward != StageAward_Invalid) {
    vPdas.push_back(stageAward);
  }

  // LOG->Trace( "done with per difficulty awards" );

  // DO give peak combo awards if using easy mods
  int iComboAtStartOfStage = GetComboAtStartOfStage();
  int iPeakCombo = GetMaxCombo().m_cnt;

  PeakComboAward peakAward = PeakComboAward_Invalid;
  FOREACH_ENUM(PeakComboAward, pca) {
    int iLevel = 1000 * (pca + 1);
    bool bCrossedLevel = iComboAtStartOfStage < iLevel && iPeakCombo >= iLevel;
    // LOG->Trace( "pca = %d, iLevel = %d, bCrossedLevel = %d", pca, iLevel,
    // bCrossedLevel );
    if (bCrossedLevel) {
      peakAward = pca;
    }
  }

  m_PeakComboAward = peakAward;
  std::deque<PeakComboAward>& vPeak = GAMESTATE->m_vLastPeakComboAwards[p];
  vPeak.clear();
  if (peakAward != PeakComboAward_Invalid) {
    vPeak.push_back(peakAward);
  }

  // LOG->Trace( "done with per combo awards" );
}

bool PlayerStageStats::IsDisqualified() const {
  if (PREFSMAN == nullptr || !PREFSMAN->m_bDisqualification) {
    return false;
  }
  return m_bDisqualified;
}

float PlayerStageStats::GetSurvivalSeconds() const {
  const float aliveSeconds =
      ClampFiniteNonNegativeFloat(m_fAliveSeconds, "alive seconds");
  const float lifeRemainingSeconds = ClampFiniteNonNegativeFloat(
      m_fLifeRemainingSeconds, "life remaining seconds");
  const float survivalSeconds = aliveSeconds + lifeRemainingSeconds;
  if (!std::isfinite(survivalSeconds)) {
    LOG->Warn(
        "SRC_AUDIT_FIX: PlayerStageStats::GetSurvivalSeconds saturated "
        "non-finite survival seconds.");
    return std::numeric_limits<float>::max();
  }
  return survivalSeconds;
}

LuaFunction(GetGradeFromPercent, GetGradeFromPercent(FArg(1))) LuaFunction(
    FormatPercentScore, PlayerStageStats::FormatPercentScore(FArg(1)))
// lua start
#include "LuaBinding.h"

    /** @brief Allow Lua to have access to the PlayerStageStats. */
class LunaPlayerStageStats : public Luna<PlayerStageStats> {
 public:
  static int GetCaloriesBurned(T* p, lua_State* L) {
    PushSaneNumber(L, p->m_fCaloriesBurned, "calories burned");
    return 1;
  }
  static int GetNumControllerSteps(T* p, lua_State* L) {
    PushSaneNumber(L, p->m_iNumControllerSteps, "controller steps");
    return 1;
  }
  static int GetLifeRemainingSeconds(T* p, lua_State* L) {
    PushSaneNumber(L, p->m_fLifeRemainingSeconds, "life remaining seconds");
    return 1;
  }
  static int GetAliveSeconds(T* p, lua_State* L) {
    PushSaneNumber(L, p->m_fAliveSeconds, "alive seconds");
    return 1;
  }
  static int GetActualDancePoints(T* p, lua_State* L) {
    lua_pushnumber(
        L, ClampNonNegativeInt(p->m_iActualDancePoints, "actual dance points"));
    return 1;
  }
  static int GetPossibleDancePoints(T* p, lua_State* L) {
    lua_pushnumber(
        L, ClampNonNegativeInt(
               p->m_iPossibleDancePoints, "possible dance points"));
    return 1;
  }
  static int GetCurrentPossibleDancePoints(T* p, lua_State* L) {
    lua_pushnumber(
        L, ClampNonNegativeInt(
               p->m_iCurPossibleDancePoints, "current possible dance points"));
    return 1;
  }
  DEFINE_METHOD(GetSurvivalSeconds, GetSurvivalSeconds())
  DEFINE_METHOD(GetCurrentCombo, m_iCurCombo)
  DEFINE_METHOD(GetCurrentMissCombo, m_iCurMissCombo)
  DEFINE_METHOD(GetCurrentScoreMultiplier, m_iCurScoreMultiplier)
  DEFINE_METHOD(GetScore, m_iScore)
  DEFINE_METHOD(GetCurMaxScore, m_iCurMaxScore)
  DEFINE_METHOD(FullCombo, FullCombo())
  DEFINE_METHOD(
      FullComboOfScore, FullComboOfScore(Enum::Check<TapNoteScore>(L, 1)))
  DEFINE_METHOD(MaxCombo, GetMaxCombo().m_cnt)
  DEFINE_METHOD(GetCurrentLife, GetCurrentLife())
  DEFINE_METHOD(GetGrade, GetGrade())
  DEFINE_METHOD(GetPercentDancePoints, GetPercentDancePoints())
  DEFINE_METHOD(GetLessonScoreActual, GetLessonScoreActual())
  DEFINE_METHOD(GetLessonScoreNeeded, GetLessonScoreNeeded())
  DEFINE_METHOD(GetPersonalHighScoreIndex, m_iPersonalHighScoreIndex)
  DEFINE_METHOD(GetMachineHighScoreIndex, m_iMachineHighScoreIndex)
  DEFINE_METHOD(GetStageAward, m_StageAward)
  DEFINE_METHOD(GetPeakComboAward, m_PeakComboAward)
  DEFINE_METHOD(IsDisqualified, IsDisqualified())
  DEFINE_METHOD(
      GetPercentageOfTaps, GetPercentageOfTaps(Enum::Check<TapNoteScore>(L, 1)))
  DEFINE_METHOD(GetBestFullComboTapNoteScore, GetBestFullComboTapNoteScore())
  DEFINE_METHOD(GetFailed, m_bFailed)
  DEFINE_METHOD(GetSongsPassed, m_iSongsPassed)
  DEFINE_METHOD(GetSongsPlayed, m_iSongsPlayed)

  static int GetHighScore(T* p, lua_State* L) {
    p->m_HighScore.PushSelf(L);
    return 1;
  }

  static int GetTapNoteScores(T* p, lua_State* L) {
    TapNoteScore tns = Enum::Check<TapNoteScore>(L, 1);
    if (!IsValidTapNoteScore(tns)) {
      LOG->Warn(
          "SRC_AUDIT_FIX: PlayerStageStats:GetTapNoteScores ignored invalid "
          "tap score %i.",
          tns);
      lua_pushnumber(L, 0);
      return 1;
    }
    lua_pushnumber(L, ClampNonNegativeInt(p->m_iTapNoteScores[tns],
                                          "tap note score"));
    return 1;
  }

  static int GetHoldNoteScores(T* p, lua_State* L) {
    HoldNoteScore hns = Enum::Check<HoldNoteScore>(L, 1);
    if (!IsValidHoldNoteScore(hns)) {
      LOG->Warn(
          "SRC_AUDIT_FIX: PlayerStageStats:GetHoldNoteScores ignored invalid "
          "hold score %i.",
          hns);
      lua_pushnumber(L, 0);
      return 1;
    }
    lua_pushnumber(L, ClampNonNegativeInt(p->m_iHoldNoteScores[hns],
                                          "hold note score"));
    return 1;
  }

  static int GetPlayedSteps(T* p, lua_State* L) {
    lua_newtable(L);
    const int stepsPlayed = std::max(0, p->m_iStepsPlayed);
    const size_t possibleLimit = std::min(
        p->m_vpPossibleSteps.size(),
        static_cast<size_t>(std::numeric_limits<int>::max()));
    if (possibleLimit != p->m_vpPossibleSteps.size()) {
      LOG->Warn(
          "SRC_AUDIT_FIX: PlayerStageStats:GetPlayedSteps truncated possible "
          "steps for Lua.");
    }
    const int maxSteps =
        std::min(stepsPlayed, static_cast<int>(possibleLimit));
    int luaIndex = 1;
    for (int i = 0; i < maxSteps; ++i) {
      Steps* steps = p->m_vpPossibleSteps[i];
      if (steps == nullptr) {
        LOG->Warn(
            "SRC_AUDIT_FIX: PlayerStageStats:GetPlayedSteps skipped null "
            "steps at index %i.",
            i);
        continue;
      }
      steps->PushSelf(L);
      lua_rawseti(L, -2, luaIndex++);
    }
    return 1;
  }
  static int GetPossibleSteps(T* p, lua_State* L) {
    lua_newtable(L);
    int luaIndex = 1;
    const size_t possibleLimit = std::min(
        p->m_vpPossibleSteps.size(),
        static_cast<size_t>(std::numeric_limits<int>::max()));
    if (possibleLimit != p->m_vpPossibleSteps.size()) {
      LOG->Warn(
          "SRC_AUDIT_FIX: PlayerStageStats:GetPossibleSteps truncated "
          "possible steps for Lua.");
    }
    for (size_t i = 0; i < possibleLimit; ++i) {
      Steps* steps = p->m_vpPossibleSteps[i];
      if (steps == nullptr) {
        LOG->Warn(
            "SRC_AUDIT_FIX: PlayerStageStats:GetPossibleSteps skipped null "
            "steps at index %zu.",
            i);
        continue;
      }
      steps->PushSelf(L);
      lua_rawseti(L, -2, luaIndex++);
    }
    return 1;
  }
  static int GetComboList(T* p, lua_State* L) {
    const size_t comboLimit = std::min(
        p->m_ComboList.size(),
        static_cast<size_t>(std::numeric_limits<int>::max()));
    if (comboLimit != p->m_ComboList.size()) {
      LOG->Warn(
          "SRC_AUDIT_FIX: PlayerStageStats:GetComboList truncated combo list "
          "for Lua.");
    }
    lua_createtable(L, static_cast<int>(comboLimit), 0);
    int luaIndex = 1;
    for (size_t i = 0; i < comboLimit; ++i) {
      const PlayerStageStats::Combo_t& combo = p->m_ComboList[i];
      if (!std::isfinite(combo.m_fStartSecond) ||
          !std::isfinite(combo.m_fSizeSeconds) ||
          combo.m_fSizeSeconds < 0.0f || combo.m_cnt < 0 ||
          combo.m_rollover < 0 || combo.m_rollover > combo.m_cnt ||
          combo.IsZero()) {
        LOG->Warn(
            "SRC_AUDIT_FIX: PlayerStageStats:GetComboList skipped invalid "
            "combo start=%f size=%f count=%i rollover=%i.",
            combo.m_fStartSecond, combo.m_fSizeSeconds, combo.m_cnt,
            combo.m_rollover);
        continue;
      }
      lua_createtable(L, 0, 6);
      lua_pushstring(L, "StartSecond");
      lua_pushnumber(L, combo.m_fStartSecond);
      lua_rawset(L, -3);
      lua_pushstring(L, "SizeSeconds");
      lua_pushnumber(L, combo.m_fSizeSeconds);
      lua_rawset(L, -3);
      lua_pushstring(L, "Count");
      lua_pushnumber(L, combo.m_cnt);
      lua_rawset(L, -3);
      lua_pushstring(L, "Rollover");
      lua_pushnumber(L, combo.m_rollover);
      lua_rawset(L, -3);
      lua_pushstring(L, "StageCount");
      lua_pushnumber(L, combo.GetStageCnt());
      lua_rawset(L, -3);
      lua_pushstring(L, "IsZero");
      lua_pushnumber(L, combo.IsZero());
      lua_rawset(L, -3);
      lua_rawseti(L, -2, luaIndex++);
    }
    return 1;
  }
  static int GetLifeRecord(T* p, lua_State* L) {
    float last_second = FArg(1);
    if (!std::isfinite(last_second) || last_second < 0.0f) {
      LOG->Warn(
          "SRC_AUDIT_FIX: PlayerStageStats:GetLifeRecord normalized invalid "
          "last second %f.",
          last_second);
      last_second = 0.0f;
    }
    int samples = 100;
    if (lua_gettop(L) >= 2 && !lua_isnil(L, 2)) {
      samples = IArg(2);
      if (samples <= 0) {
        LOG->Trace(
            "PlayerStageStats:GetLifeRecord requires an integer greater than "
            "0.  Defaulting to 100.");
        samples = 100;
      }
    }
    if (samples > MAX_LUA_LIFE_RECORD_SAMPLES) {
      LOG->Warn(
          "SRC_AUDIT_FIX: PlayerStageStats:GetLifeRecord clamped samples %i "
          "to %i.",
          samples, MAX_LUA_LIFE_RECORD_SAMPLES);
      samples = MAX_LUA_LIFE_RECORD_SAMPLES;
    }
    lua_createtable(L, samples, 0);
    for (int i = 0; i < samples; ++i) {
      // The scale from range is [0, samples-1] because that is i's range.
      float from = samples == 1
                       ? 0.0f
                       : SCALE(i, 0, (float)samples - 1.0f, 0.0f, last_second);
      float curr = p->GetLifeRecordLerpAt(from);
      lua_pushnumber(L, curr);
      lua_rawseti(L, -2, i + 1);
    }
    return 1;
  }

  static int GetRadarPossible(T* p, lua_State* L) {
    p->m_radarPossible.PushSelf(L);
    return 1;
  }
  static int GetRadarActual(T* p, lua_State* L) {
    p->m_radarActual.PushSelf(L);
    return 1;
  }
  static int SetScore(T* p, lua_State* L) {
    const int score = IArg(1);
    if (score >= 0) {
      p->m_iScore = static_cast<unsigned int>(score);
    } else {
      LOG->Warn(
          "SRC_AUDIT_FIX: PlayerStageStats:SetScore ignored negative score "
          "%i.",
          score);
    }
    COMMON_RETURN_SELF;
  }
  static int SetCurMaxScore(T* p, lua_State* L) {
    const int score = IArg(1);
    if (score >= 0) {
      p->m_iCurMaxScore = static_cast<unsigned int>(score);
    } else {
      LOG->Warn(
          "SRC_AUDIT_FIX: PlayerStageStats:SetCurMaxScore ignored negative "
          "score %i.",
          score);
    }
    COMMON_RETURN_SELF;
  }
  static int SetDancePointLimits(T* p, lua_State* L) {
    int actual = IArg(1);
    int possible = IArg(2);
    if (actual >= 0 && possible > 0) {
      p->m_iPossibleDancePoints = possible;
      p->m_iCurPossibleDancePoints = possible;
      if (actual <= possible) {
        p->m_iActualDancePoints = actual;
      } else {
        p->m_iActualDancePoints = possible;
      }
    } else {
      LOG->Warn(
          "SRC_AUDIT_FIX: PlayerStageStats:SetDancePointLimits ignored "
          "invalid limits actual=%i possible=%i.",
          actual, possible);
    }
    COMMON_RETURN_SELF;
  }

  static int FailPlayer(T* p, lua_State* L) {
    p->m_bFailed = true;
    COMMON_RETURN_SELF;
  }

  LunaPlayerStageStats() {
    ADD_METHOD(GetCaloriesBurned);
    ADD_METHOD(GetNumControllerSteps);
    ADD_METHOD(GetLifeRemainingSeconds);
    ADD_METHOD(GetSurvivalSeconds);
    ADD_METHOD(GetCurrentCombo);
    ADD_METHOD(GetCurrentMissCombo);
    ADD_METHOD(GetCurrentScoreMultiplier);
    ADD_METHOD(GetScore);
    ADD_METHOD(GetCurMaxScore);
    ADD_METHOD(GetTapNoteScores);
    ADD_METHOD(GetHoldNoteScores);
    ADD_METHOD(FullCombo);
    ADD_METHOD(FullComboOfScore);
    ADD_METHOD(MaxCombo);
    ADD_METHOD(GetCurrentLife);
    ADD_METHOD(GetGrade);
    ADD_METHOD(GetHighScore);
    ADD_METHOD(GetActualDancePoints);
    ADD_METHOD(GetPossibleDancePoints);
    ADD_METHOD(GetCurrentPossibleDancePoints);
    ADD_METHOD(GetPercentDancePoints);
    ADD_METHOD(GetLessonScoreActual);
    ADD_METHOD(GetLessonScoreNeeded);
    ADD_METHOD(GetPersonalHighScoreIndex);
    ADD_METHOD(GetMachineHighScoreIndex);
    ADD_METHOD(GetStageAward);
    ADD_METHOD(GetPeakComboAward);
    ADD_METHOD(IsDisqualified);
    ADD_METHOD(GetPlayedSteps);
    ADD_METHOD(GetPossibleSteps);
    ADD_METHOD(GetComboList);
    ADD_METHOD(GetLifeRecord);
    ADD_METHOD(GetAliveSeconds);
    ADD_METHOD(GetPercentageOfTaps);
    ADD_METHOD(GetRadarActual);
    ADD_METHOD(GetRadarPossible);
    ADD_METHOD(GetBestFullComboTapNoteScore);
    ADD_METHOD(GetFailed);
    ADD_METHOD(SetScore);
    ADD_METHOD(GetCurMaxScore);
    ADD_METHOD(SetCurMaxScore);
    ADD_METHOD(SetDancePointLimits);
    ADD_METHOD(FailPlayer);
    ADD_METHOD(GetSongsPassed);
    ADD_METHOD(GetSongsPlayed);
  }
};

LUA_REGISTER_CLASS(PlayerStageStats)
// lua end

/*
 * (c) 2001-2004 Chris Danford, Glenn Maynard
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
