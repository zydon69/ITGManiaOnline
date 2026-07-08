#include "HighScore.h"

#include <algorithm>
#include <array>
#include <climits>
#include <cmath>
#include <cstddef>
#include <limits>
#include <string>
#include <vector>

#include "EnumHelper.h"
#include "GameConstantsAndTypes.h"
#include "Grade.h"
#include "LuaManager.h"
#include "PlayerNumber.h"
#include "PrefsManager.h"
#include "RadarValues.h"
#include "RageLog.h"
#include "RageUtil.h"
#include "RageUtil_AutoPtr.h"
#include "ThemeManager.h"
#include "ThemeMetric.h"
#include "XmlFile.h"
#include "global.h"

ThemeMetric<std::string> EMPTY_NAME("HighScore", "EmptyName");

namespace {
constexpr int DEFAULT_MACHINE_HIGH_SCORE_LIMIT = 10;
constexpr int DEFAULT_PLAYER_HIGH_SCORE_LIMIT = 3;
constexpr int MAX_REASONABLE_HIGH_SCORE_LIMIT = 1000;

void WarnHighScore(const char* message) {
  if (LOG != nullptr) {
    LOG->Warn("SRC_AUDIT_FIX: %s", message);
  }
}

bool IsValidGradeValue(Grade grade) {
  return (grade >= Grade_Tier01 && grade <= Grade_Failed) ||
         grade == Grade_NoData;
}

bool IsValidStageAwardValue(StageAward award) {
  return (award >= 0 && award < NUM_StageAward) ||
         award == StageAward_Invalid;
}

bool IsValidPeakComboAwardValue(PeakComboAward award) {
  return (award >= 0 && award < NUM_PeakComboAward) ||
         award == PeakComboAward_Invalid;
}

bool IsValidTapNoteScoreValue(TapNoteScore tns) {
  return tns >= TNS_None && tns < NUM_TapNoteScore;
}

bool IsValidHoldNoteScoreValue(HoldNoteScore hns) {
  return hns >= HNS_None && hns < NUM_HoldNoteScore;
}

bool IsValidRoutinePlayer(PlayerNumber pn) {
  return pn >= PLAYER_1 && pn < NUM_PLAYERS;
}

Grade SanitizeGrade(Grade grade) {
  if (IsValidGradeValue(grade)) {
    return grade;
  }
  WarnHighScore("HighScore normalized invalid grade to NoData.");
  return Grade_NoData;
}

StageAward SanitizeStageAward(StageAward award) {
  if (IsValidStageAwardValue(award)) {
    return award;
  }
  WarnHighScore("HighScore normalized invalid stage award.");
  return StageAward_Invalid;
}

PeakComboAward SanitizePeakComboAward(PeakComboAward award) {
  if (IsValidPeakComboAwardValue(award)) {
    return award;
  }
  WarnHighScore("HighScore normalized invalid peak combo award.");
  return PeakComboAward_Invalid;
}

float SanitizeFiniteNonNegativeFloat(
    float value, const char* field, float fallback = 0.0f) {
  if (!std::isfinite(value) || value < 0.0f) {
    if (LOG != nullptr) {
      LOG->Warn(
          "SRC_AUDIT_FIX: HighScore normalized invalid %s value %f to %f.",
          field, value, fallback);
    }
    return fallback;
  }
  return value;
}

float SanitizePercentDP(float value) {
  value = SanitizeFiniteNonNegativeFloat(value, "PercentDP");
  if (value > 1.0f) {
    if (LOG != nullptr) {
      LOG->Warn(
          "SRC_AUDIT_FIX: HighScore clamped PercentDP value %f to 1.", value);
    }
    return 1.0f;
  }
  return value;
}

int SanitizeNonNegativeInt(int value, const char* field) {
  if (value < 0) {
    if (LOG != nullptr) {
      LOG->Warn(
          "SRC_AUDIT_FIX: HighScore clamped negative %s value %i to 0.",
          field, value);
    }
    return 0;
  }
  return value;
}

int AddNonNegativeIntSaturated(int lhs, int rhs, const char* field) {
  lhs = SanitizeNonNegativeInt(lhs, field);
  rhs = SanitizeNonNegativeInt(rhs, field);
  if (rhs > std::numeric_limits<int>::max() - lhs) {
    if (LOG != nullptr) {
      LOG->Warn(
          "SRC_AUDIT_FIX: HighScore saturated %s sum %i + %i.",
          field, lhs, rhs);
    }
    return std::numeric_limits<int>::max();
  }
  return lhs + rhs;
}

int GetMaxHighScoresForList(bool isMachine) {
  int value = isMachine ? DEFAULT_MACHINE_HIGH_SCORE_LIMIT
                        : DEFAULT_PLAYER_HIGH_SCORE_LIMIT;
  if (PREFSMAN != nullptr) {
    value = isMachine ? PREFSMAN->m_iMaxHighScoresPerListForMachine.Get()
                      : PREFSMAN->m_iMaxHighScoresPerListForPlayer.Get();
  }
  if (value < 0 || value > MAX_REASONABLE_HIGH_SCORE_LIMIT) {
    if (LOG != nullptr) {
      LOG->Warn(
          "SRC_AUDIT_FIX: HighScore clamped max high score list size %i.",
          value);
    }
    value = std::clamp(value, 0, MAX_REASONABLE_HIGH_SCORE_LIMIT);
  }
  return value;
}

bool AllowMultipleHighScoresWithSameName() {
  return PREFSMAN == nullptr ||
         PREFSMAN->m_bAllowMultipleHighScoreWithSameName.Get();
}

bool IsBetterGrade(Grade lhs, Grade rhs) {
  lhs = SanitizeGrade(lhs);
  rhs = SanitizeGrade(rhs);
  if (lhs == Grade_NoData) {
    return false;
  }
  if (rhs == Grade_NoData) {
    return true;
  }
  return lhs < rhs;
}

Grade BestGrade(Grade lhs, Grade rhs) {
  return IsBetterGrade(lhs, rhs) ? lhs : rhs;
}

float ComparablePercent(const HighScore& hs) {
  return SanitizePercentDP(hs.GetPercentDP());
}

bool IsBetterHighScore(const HighScore& lhs, const HighScore& rhs) {
  if (PREFSMAN != nullptr && PREFSMAN->m_bPercentageScoring.Get()) {
    const float lhsPercent = ComparablePercent(lhs);
    const float rhsPercent = ComparablePercent(rhs);
    if (lhsPercent != rhsPercent) {
      return lhsPercent > rhsPercent;
    }
  } else if (lhs.GetScore() != rhs.GetScore()) {
    return lhs.GetScore() > rhs.GetScore();
  }

  if (lhs.GetGrade() != rhs.GetGrade()) {
    return IsBetterGrade(lhs.GetGrade(), rhs.GetGrade());
  }
  if (lhs.GetMaxCombo() != rhs.GetMaxCombo()) {
    return lhs.GetMaxCombo() > rhs.GetMaxCombo();
  }
  return lhs.GetDateTime() > rhs.GetDateTime();
}

Grade CalculateHighGrade(const std::vector<HighScore>& scores) {
  Grade highGrade = Grade_NoData;
  for (const HighScore& score : scores) {
    highGrade = BestGrade(score.GetGrade(), highGrade);
  }
  return highGrade;
}

void SortHighScoresBestFirst(std::vector<HighScore>& scores) {
  std::stable_sort(scores.begin(), scores.end(), IsBetterHighScore);
}

bool ShouldDeduplicateHighScoreName(const std::string& name) {
  return !name.empty() && !IsRankingToFillIn(name);
}

std::string SafeStageAwardToString(StageAward award) {
  award = SanitizeStageAward(award);
  return award == StageAward_Invalid ? std::string("")
                                     : StageAwardToString(award);
}

std::string SafePeakComboAwardToString(PeakComboAward award) {
  award = SanitizePeakComboAward(award);
  return award == PeakComboAward_Invalid ? std::string("")
                                         : PeakComboAwardToString(award);
}

bool IsSafeScreenshotFilename(const std::string& fileName) {
  return !fileName.empty() && fileName == Basename(fileName) &&
         fileName.find("..") == std::string::npos;
}

bool IsHexChar(char c) {
  return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') ||
         (c >= 'A' && c <= 'F');
}

bool IsValidMD5(const std::string& md5) {
  return md5.empty() ||
         (md5.size() == 32 &&
          std::all_of(md5.begin(), md5.end(), IsHexChar));
}

bool NearlyEqualHighScoreFloat(float lhs, float rhs, const char* field) {
  lhs = SanitizeFiniteNonNegativeFloat(lhs, field);
  rhs = SanitizeFiniteNonNegativeFloat(rhs, field);
  return std::fabs(lhs - rhs) <= 0.000001f;
}
}  // namespace

struct HighScoreImpl {
  std::string sName;  // name that shows in the machine's ranking screen
  Grade grade;
  unsigned int iScore;
  float fPercentDP;
  float fSurviveSeconds;
  unsigned int iMaxCombo;         // maximum combo obtained [SM5 alpha 1a+]
  StageAward stageAward;          // stage award [SM5 alpha 1a+]
  PeakComboAward peakComboAward;  // peak combo award [SM5 alpha 1a+]
  std::string sModifiers;
  DateTime dateTime;         // return value of time() when screenshot was taken
  std::string sPlayerGuid;   // who made this high score
  std::string sMachineGuid;  // where this high score was made
  int iProductID;
  int iTapNoteScores[NUM_TapNoteScore];
  int iHoldNoteScores[NUM_HoldNoteScore];
  RadarValues radarValues;
  float fLifeRemainingSeconds;
  bool bDisqualified;
  bool bIsRoutine;
  std::vector<Grade> playerGrades;
  std::vector<unsigned int> playerScores;
  std::vector<float> playerPercentDPs;
  std::vector<unsigned int> playerMaxCombos;
  std::vector<std::string> playerGuids;
  std::vector<std::array<int, NUM_TapNoteScore>> playerTapNoteScores;
  std::vector<std::array<int, NUM_HoldNoteScore>> playerHoldNoteScores;

  HighScoreImpl();
  XNode* CreateNode() const;
  void LoadFromNode(const XNode* pNode);

  bool operator==(const HighScoreImpl& other) const;
  bool operator!=(const HighScoreImpl& other) const {
    return !(*this == other);
  }
};

bool HighScoreImpl::operator==(const HighScoreImpl& other) const {
  if (sName != other.sName) {
    return false;
  }
  if (grade != other.grade) {
    return false;
  }
  if (iScore != other.iScore) {
    return false;
  }
  if (iMaxCombo != other.iMaxCombo) {
    return false;
  }
  if (stageAward != other.stageAward) {
    return false;
  }
  if (peakComboAward != other.peakComboAward) {
    return false;
  }
  if (!NearlyEqualHighScoreFloat(fPercentDP, other.fPercentDP, "PercentDP")) {
    return false;
  }
  if (!NearlyEqualHighScoreFloat(
          fSurviveSeconds, other.fSurviveSeconds, "SurviveSeconds")) {
    return false;
  }
  if (sModifiers != other.sModifiers) {
    return false;
  }
  if (dateTime != other.dateTime) {
    return false;
  }
  if (sPlayerGuid != other.sPlayerGuid) {
    return false;
  }
  if (sMachineGuid != other.sMachineGuid) {
    return false;
  }
  if (iProductID != other.iProductID) {
    return false;
  }
  FOREACH_ENUM(TapNoteScore, tns) {
    if (iTapNoteScores[tns] != other.iTapNoteScores[tns]) {
      return false;
    }
  }
  FOREACH_ENUM(HoldNoteScore, hns) {
    if (iHoldNoteScores[hns] != other.iHoldNoteScores[hns]) {
      return false;
    }
  }
  if (radarValues != other.radarValues) {
    return false;
  }
  if (!NearlyEqualHighScoreFloat(
          fLifeRemainingSeconds,
          other.fLifeRemainingSeconds,
          "LifeRemainingSeconds")) {
    return false;
  }
  if (bDisqualified != other.bDisqualified) {
    return false;
  }
  if (bIsRoutine != other.bIsRoutine) {
    return false;
  }
  if (playerGrades != other.playerGrades ||
      playerScores != other.playerScores ||
      playerGuids != other.playerGuids ||
      playerMaxCombos != other.playerMaxCombos ||
      playerTapNoteScores != other.playerTapNoteScores ||
      playerHoldNoteScores != other.playerHoldNoteScores) {
    return false;
  }
  for (size_t i = 0; i < playerPercentDPs.size(); ++i) {
    if (i >= other.playerPercentDPs.size() ||
        !NearlyEqualHighScoreFloat(
            playerPercentDPs[i], other.playerPercentDPs[i],
            "Routine PercentDP")) {
      return false;
    }
  }
  if (playerPercentDPs.size() != other.playerPercentDPs.size()) {
    return false;
  }
  return true;
}

HighScoreImpl::HighScoreImpl() {
  sName = "";
  grade = Grade_NoData;
  iScore = 0;
  fPercentDP = 0;
  fSurviveSeconds = 0;
  iMaxCombo = 0;
  stageAward = StageAward_Invalid;
  peakComboAward = PeakComboAward_Invalid;
  sModifiers = "";
  dateTime.Init();
  sPlayerGuid = "";
  sMachineGuid = "";
  iProductID = 0;
  ZERO(iTapNoteScores);
  ZERO(iHoldNoteScores);
  radarValues.MakeUnknown();
  fLifeRemainingSeconds = 0;
  bDisqualified = false;
  bIsRoutine = false;
  playerGrades.assign(NUM_PLAYERS, Grade_NoData);
  playerScores.assign(NUM_PLAYERS, 0);
  playerPercentDPs.assign(NUM_PLAYERS, 0.0f);
  playerMaxCombos.assign(NUM_PLAYERS, 0);
  playerGuids.assign(NUM_PLAYERS, "");
  playerTapNoteScores.assign(NUM_PLAYERS, {});
  playerHoldNoteScores.assign(NUM_PLAYERS, {});
  for (auto& scores : playerTapNoteScores) {
    scores.fill(0);
  }
  for (auto& scores : playerHoldNoteScores) {
    scores.fill(0);
  }
}

XNode* HighScoreImpl::CreateNode() const {
  XNode* pNode = new XNode("HighScore");
  const bool bWriteSimpleValues = RadarValues::WRITE_SIMPLE_VALIES;
  const bool bWriteComplexValues = RadarValues::WRITE_COMPLEX_VALIES;

  // TRICKY:  Don't write "name to fill in" markers.
  pNode->AppendChild(
      "Name", IsRankingToFillIn(sName) ? std::string("") : sName);
  pNode->AppendChild("Grade", GradeToString(SanitizeGrade(grade)));
  pNode->AppendChild("Score", iScore);
  pNode->AppendChild("PercentDP", SanitizePercentDP(fPercentDP));
  pNode->AppendChild(
      "SurviveSeconds",
      SanitizeFiniteNonNegativeFloat(fSurviveSeconds, "SurviveSeconds"));
  pNode->AppendChild("MaxCombo", iMaxCombo);
  pNode->AppendChild("StageAward", SafeStageAwardToString(stageAward));
  pNode->AppendChild(
      "PeakComboAward", SafePeakComboAwardToString(peakComboAward));
  pNode->AppendChild("Modifiers", sModifiers);
  pNode->AppendChild("DateTime", dateTime.GetString());
  pNode->AppendChild("PlayerGuid", sPlayerGuid);
  pNode->AppendChild("MachineGuid", sMachineGuid);
  pNode->AppendChild("ProductID", iProductID);
  XNode* pTapNoteScores = pNode->AppendChild("TapNoteScores");
  FOREACH_ENUM(TapNoteScore, tns)
  if (tns != TNS_None) {  // HACK: don't save meaningless "none" count
    pTapNoteScores->AppendChild(
        TapNoteScoreToString(tns),
        SanitizeNonNegativeInt(iTapNoteScores[tns], "tap note score"));
  }
  XNode* pHoldNoteScores = pNode->AppendChild("HoldNoteScores");
  FOREACH_ENUM(HoldNoteScore, hns)
  if (hns != HNS_None) {  // HACK: don't save meaningless "none" count
    pHoldNoteScores->AppendChild(
        HoldNoteScoreToString(hns),
        SanitizeNonNegativeInt(iHoldNoteScores[hns], "hold note score"));
  }
  pNode->AppendChild(
      radarValues.CreateNode(bWriteSimpleValues, bWriteComplexValues));
  pNode->AppendChild(
      "LifeRemainingSeconds",
      SanitizeFiniteNonNegativeFloat(
          fLifeRemainingSeconds, "LifeRemainingSeconds"));
  pNode->AppendChild("Disqualified", bDisqualified);
  if (bIsRoutine) {
    XNode* pRoutineNode = pNode->AppendChild("RoutineData");
    FOREACH_PlayerNumber(pn) {
      const size_t index = static_cast<size_t>(pn);
      XNode* pPlayerNode = pRoutineNode->AppendChild(PlayerNumberToString(pn));
      pPlayerNode->AppendChild(
          "Grade", GradeToString(SanitizeGrade(playerGrades[index])));
      pPlayerNode->AppendChild("Score", playerScores[index]);
      pPlayerNode->AppendChild(
          "PercentDP", SanitizePercentDP(playerPercentDPs[index]));
      pPlayerNode->AppendChild("MaxCombo", playerMaxCombos[index]);
      pPlayerNode->AppendChild("PlayerGuid", playerGuids[index]);

      XNode* pRoutineTapNoteScores = pPlayerNode->AppendChild("TapNoteScores");
      FOREACH_ENUM(TapNoteScore, tns) {
        if (tns != TNS_None) {
          pRoutineTapNoteScores->AppendChild(
              TapNoteScoreToString(tns),
              SanitizeNonNegativeInt(
                  playerTapNoteScores[index][tns],
                  "routine tap note score"));
        }
      }

      XNode* pRoutineHoldNoteScores =
          pPlayerNode->AppendChild("HoldNoteScores");
      FOREACH_ENUM(HoldNoteScore, hns) {
        if (hns != HNS_None) {
          pRoutineHoldNoteScores->AppendChild(
              HoldNoteScoreToString(hns),
              SanitizeNonNegativeInt(
                  playerHoldNoteScores[index][hns],
                  "routine hold note score"));
        }
      }
    }
  }

  return pNode;
}

void HighScoreImpl::LoadFromNode(const XNode* pNode) {
  if (pNode == nullptr || pNode->GetName() != "HighScore") {
    WarnHighScore("HighScore ignored invalid or null HighScore XML node.");
    *this = HighScoreImpl();
    return;
  }

  *this = HighScoreImpl();
  std::string s;

  pNode->GetChildValue("Name", sName);
  if (pNode->GetChildValue("Grade", s) && !s.empty()) {
    grade = SanitizeGrade(StringToGrade(s));
  }
  pNode->GetChildValue("Score", iScore);
  pNode->GetChildValue("PercentDP", fPercentDP);
  fPercentDP = SanitizePercentDP(fPercentDP);
  pNode->GetChildValue("SurviveSeconds", fSurviveSeconds);
  fSurviveSeconds =
      SanitizeFiniteNonNegativeFloat(fSurviveSeconds, "SurviveSeconds");
  pNode->GetChildValue("MaxCombo", iMaxCombo);
  if (pNode->GetChildValue("StageAward", s) && !s.empty()) {
    stageAward = SanitizeStageAward(StringToStageAward(s));
  }
  if (pNode->GetChildValue("PeakComboAward", s) && !s.empty()) {
    peakComboAward = SanitizePeakComboAward(StringToPeakComboAward(s));
  }
  pNode->GetChildValue("Modifiers", sModifiers);
  if (pNode->GetChildValue("DateTime", s)) {
    dateTime.FromString(s);
  }
  pNode->GetChildValue("PlayerGuid", sPlayerGuid);
  pNode->GetChildValue("MachineGuid", sMachineGuid);
  pNode->GetChildValue("ProductID", iProductID);
  const XNode* pTapNoteScores = pNode->GetChild("TapNoteScores");
  if (pTapNoteScores) {
    FOREACH_ENUM(TapNoteScore, tns)
    if (pTapNoteScores->GetChildValue(
            TapNoteScoreToString(tns), iTapNoteScores[tns])) {
      iTapNoteScores[tns] =
          SanitizeNonNegativeInt(iTapNoteScores[tns], "tap note score");
    }
  }
  const XNode* pHoldNoteScores = pNode->GetChild("HoldNoteScores");
  if (pHoldNoteScores) {
    FOREACH_ENUM(HoldNoteScore, hns)
    if (pHoldNoteScores->GetChildValue(
            HoldNoteScoreToString(hns), iHoldNoteScores[hns])) {
      iHoldNoteScores[hns] =
          SanitizeNonNegativeInt(iHoldNoteScores[hns], "hold note score");
    }
  }
  const XNode* pRadarValues = pNode->GetChild("RadarValues");
  if (pRadarValues) {
    radarValues.LoadFromNode(pRadarValues);
  }
  pNode->GetChildValue("LifeRemainingSeconds", fLifeRemainingSeconds);
  fLifeRemainingSeconds = SanitizeFiniteNonNegativeFloat(
      fLifeRemainingSeconds, "LifeRemainingSeconds");
  pNode->GetChildValue("Disqualified", bDisqualified);
  const XNode* pRoutineNode = pNode->GetChild("RoutineData");
  if (pRoutineNode != nullptr) {
    bIsRoutine = true;
    FOREACH_PlayerNumber(pn) {
      const XNode* pPlayerNode =
          pRoutineNode->GetChild(PlayerNumberToString(pn));
      if (pPlayerNode == nullptr) {
        continue;
      }
      std::string routineGrade;
      if (pPlayerNode->GetChildValue("Grade", routineGrade) &&
          !routineGrade.empty()) {
        playerGrades[pn] = SanitizeGrade(StringToGrade(routineGrade));
      }
      if (pPlayerNode->GetChildValue("Score", playerScores[pn])) {
        playerScores[pn] = static_cast<unsigned int>(
            SanitizeNonNegativeInt(
                static_cast<int>(std::min<unsigned int>(
                    playerScores[pn],
                    static_cast<unsigned int>(std::numeric_limits<int>::max()))),
                "routine player score"));
      }
      if (pPlayerNode->GetChildValue("PercentDP", playerPercentDPs[pn])) {
        playerPercentDPs[pn] = SanitizePercentDP(playerPercentDPs[pn]);
      }
      if (pPlayerNode->GetChildValue("MaxCombo", playerMaxCombos[pn])) {
        playerMaxCombos[pn] = static_cast<unsigned int>(
            SanitizeNonNegativeInt(
                static_cast<int>(std::min<unsigned int>(
                    playerMaxCombos[pn],
                    static_cast<unsigned int>(std::numeric_limits<int>::max()))),
                "routine player max combo"));
      }
      pPlayerNode->GetChildValue("PlayerGuid", playerGuids[pn]);

      const XNode* pRoutineTapNoteScores =
          pPlayerNode->GetChild("TapNoteScores");
      if (pRoutineTapNoteScores != nullptr) {
        FOREACH_ENUM(TapNoteScore, tns) {
          if (pRoutineTapNoteScores->GetChildValue(
                  TapNoteScoreToString(tns), playerTapNoteScores[pn][tns])) {
            playerTapNoteScores[pn][tns] = SanitizeNonNegativeInt(
                playerTapNoteScores[pn][tns], "routine tap note score");
          }
        }
      }

      const XNode* pRoutineHoldNoteScores =
          pPlayerNode->GetChild("HoldNoteScores");
      if (pRoutineHoldNoteScores != nullptr) {
        FOREACH_ENUM(HoldNoteScore, hns) {
          if (pRoutineHoldNoteScores->GetChildValue(
                  HoldNoteScoreToString(hns),
                  playerHoldNoteScores[pn][hns])) {
            playerHoldNoteScores[pn][hns] = SanitizeNonNegativeInt(
                playerHoldNoteScores[pn][hns], "routine hold note score");
          }
        }
      }
    }
  }
}

REGISTER_CLASS_TRAITS(HighScoreImpl, new HighScoreImpl(*pCopy))

HighScore::HighScore() { m_Impl = new HighScoreImpl; }

void HighScore::Unset() { m_Impl = new HighScoreImpl; }

bool HighScore::IsEmpty() const {
  if (GetTapNoteScore(TNS_W1) > 0 || GetTapNoteScore(TNS_W2) > 0 ||
      GetTapNoteScore(TNS_W3) > 0 || GetTapNoteScore(TNS_W4) > 0 ||
      GetTapNoteScore(TNS_W5) > 0) {
    return false;
  }
  if (GetHoldNoteScore(HNS_Held) > 0) {
    return false;
  }
  return true;
}

std::string HighScore::GetName() const { return m_Impl->sName; }
Grade HighScore::GetGrade() const { return SanitizeGrade(m_Impl->grade); }
unsigned int HighScore::GetScore() const { return m_Impl->iScore; }
unsigned int HighScore::GetMaxCombo() const { return m_Impl->iMaxCombo; }
StageAward HighScore::GetStageAward() const {
  return SanitizeStageAward(m_Impl->stageAward);
}
PeakComboAward HighScore::GetPeakComboAward() const {
  return SanitizePeakComboAward(m_Impl->peakComboAward);
}
float HighScore::GetPercentDP() const {
  return SanitizePercentDP(m_Impl->fPercentDP);
}
float HighScore::GetSurviveSeconds() const {
  return SanitizeFiniteNonNegativeFloat(
      m_Impl->fSurviveSeconds, "SurviveSeconds");
}
float HighScore::GetSurvivalSeconds() const {
  const float surviveSeconds = GetSurviveSeconds();
  const float lifeRemainingSeconds = GetLifeRemainingSeconds();
  if (lifeRemainingSeconds >
      std::numeric_limits<float>::max() - surviveSeconds) {
    WarnHighScore("HighScore saturated survival seconds sum.");
    return std::numeric_limits<float>::max();
  }
  return surviveSeconds + lifeRemainingSeconds;
}
std::string HighScore::GetModifiers() const { return m_Impl->sModifiers; }
DateTime HighScore::GetDateTime() const { return m_Impl->dateTime; }
std::string HighScore::GetPlayerGuid() const { return m_Impl->sPlayerGuid; }
std::string HighScore::GetMachineGuid() const { return m_Impl->sMachineGuid; }
int HighScore::GetProductID() const { return m_Impl->iProductID; }
int HighScore::GetTapNoteScore(TapNoteScore tns) const {
  if (!IsValidTapNoteScoreValue(tns)) {
    WarnHighScore("HighScore rejected invalid tap note score getter enum.");
    return 0;
  }
  return m_Impl->iTapNoteScores[tns];
}
int HighScore::GetHoldNoteScore(HoldNoteScore hns) const {
  if (!IsValidHoldNoteScoreValue(hns)) {
    WarnHighScore("HighScore rejected invalid hold note score getter enum.");
    return 0;
  }
  return m_Impl->iHoldNoteScores[hns];
}
const RadarValues& HighScore::GetRadarValues() const {
  return m_Impl->radarValues;
}
float HighScore::GetLifeRemainingSeconds() const {
  return SanitizeFiniteNonNegativeFloat(
      m_Impl->fLifeRemainingSeconds, "LifeRemainingSeconds");
}
bool HighScore::GetDisqualified() const { return m_Impl->bDisqualified; }
bool HighScore::IsRoutine() const { return m_Impl->bIsRoutine; }

Grade HighScore::GetPlayerGrade(PlayerNumber pn) const {
  if (!IsValidRoutinePlayer(pn)) {
    WarnHighScore("HighScore rejected invalid routine player grade getter.");
    return Grade_NoData;
  }
  return SanitizeGrade(m_Impl->playerGrades[pn]);
}

unsigned int HighScore::GetPlayerScore(PlayerNumber pn) const {
  if (!IsValidRoutinePlayer(pn)) {
    WarnHighScore("HighScore rejected invalid routine player score getter.");
    return 0;
  }
  return m_Impl->playerScores[pn];
}

float HighScore::GetPlayerPercentDP(PlayerNumber pn) const {
  if (!IsValidRoutinePlayer(pn)) {
    WarnHighScore("HighScore rejected invalid routine player percent getter.");
    return 0.0f;
  }
  return SanitizePercentDP(m_Impl->playerPercentDPs[pn]);
}

unsigned int HighScore::GetPlayerMaxCombo(PlayerNumber pn) const {
  if (!IsValidRoutinePlayer(pn)) {
    WarnHighScore("HighScore rejected invalid routine player combo getter.");
    return 0;
  }
  return m_Impl->playerMaxCombos[pn];
}

std::string HighScore::GetPlayerGuid(PlayerNumber pn) const {
  if (!IsValidRoutinePlayer(pn)) {
    WarnHighScore("HighScore rejected invalid routine player guid getter.");
    return "";
  }
  return m_Impl->playerGuids[pn];
}

int HighScore::GetPlayerTapNoteScore(
    PlayerNumber pn, TapNoteScore tns) const {
  if (!IsValidRoutinePlayer(pn) || !IsValidTapNoteScoreValue(tns)) {
    WarnHighScore(
        "HighScore rejected invalid routine player tap score getter.");
    return 0;
  }
  return m_Impl->playerTapNoteScores[pn][tns];
}

int HighScore::GetPlayerHoldNoteScore(
    PlayerNumber pn, HoldNoteScore hns) const {
  if (!IsValidRoutinePlayer(pn) || !IsValidHoldNoteScoreValue(hns)) {
    WarnHighScore(
        "HighScore rejected invalid routine player hold score getter.");
    return 0;
  }
  return m_Impl->playerHoldNoteScores[pn][hns];
}

void HighScore::SetName(const std::string& sName) { m_Impl->sName = sName; }
void HighScore::SetGrade(Grade g) { m_Impl->grade = SanitizeGrade(g); }
void HighScore::SetScore(unsigned int iScore) { m_Impl->iScore = iScore; }
void HighScore::SetMaxCombo(unsigned int i) { m_Impl->iMaxCombo = i; }
void HighScore::SetStageAward(StageAward a) {
  m_Impl->stageAward = SanitizeStageAward(a);
}
void HighScore::SetPeakComboAward(PeakComboAward a) {
  m_Impl->peakComboAward = SanitizePeakComboAward(a);
}
void HighScore::SetPercentDP(float f) {
  m_Impl->fPercentDP = SanitizePercentDP(f);
}
void HighScore::SetAliveSeconds(float f) {
  m_Impl->fSurviveSeconds =
      SanitizeFiniteNonNegativeFloat(f, "SurviveSeconds");
}
void HighScore::SetModifiers(std::string s) { m_Impl->sModifiers = s; }
void HighScore::SetDateTime(DateTime d) { m_Impl->dateTime = d; }
void HighScore::SetPlayerGuid(std::string s) { m_Impl->sPlayerGuid = s; }
void HighScore::SetMachineGuid(std::string s) { m_Impl->sMachineGuid = s; }
void HighScore::SetProductID(int i) { m_Impl->iProductID = i; }
void HighScore::SetTapNoteScore(TapNoteScore tns, int i) {
  if (!IsValidTapNoteScoreValue(tns)) {
    WarnHighScore("HighScore rejected invalid tap note score setter enum.");
    return;
  }
  m_Impl->iTapNoteScores[tns] = SanitizeNonNegativeInt(i, "tap note score");
}
void HighScore::SetHoldNoteScore(HoldNoteScore hns, int i) {
  if (!IsValidHoldNoteScoreValue(hns)) {
    WarnHighScore("HighScore rejected invalid hold note score setter enum.");
    return;
  }
  m_Impl->iHoldNoteScores[hns] = SanitizeNonNegativeInt(i, "hold note score");
}
void HighScore::SetRadarValues(const RadarValues& rv) {
  m_Impl->radarValues = rv;
}
void HighScore::SetLifeRemainingSeconds(float f) {
  m_Impl->fLifeRemainingSeconds =
      SanitizeFiniteNonNegativeFloat(f, "LifeRemainingSeconds");
}
void HighScore::SetDisqualified(bool b) { m_Impl->bDisqualified = b; }
void HighScore::SetRoutine(bool b) { m_Impl->bIsRoutine = b; }

void HighScore::SetPlayerGrade(PlayerNumber pn, Grade g) {
  if (!IsValidRoutinePlayer(pn)) {
    WarnHighScore("HighScore rejected invalid routine player grade setter.");
    return;
  }
  m_Impl->playerGrades[pn] = SanitizeGrade(g);
}

void HighScore::SetPlayerScore(PlayerNumber pn, unsigned int iScore) {
  if (!IsValidRoutinePlayer(pn)) {
    WarnHighScore("HighScore rejected invalid routine player score setter.");
    return;
  }
  m_Impl->playerScores[pn] = iScore;
}

void HighScore::SetPlayerPercentDP(PlayerNumber pn, float f) {
  if (!IsValidRoutinePlayer(pn)) {
    WarnHighScore("HighScore rejected invalid routine player percent setter.");
    return;
  }
  m_Impl->playerPercentDPs[pn] = SanitizePercentDP(f);
}

void HighScore::SetPlayerMaxCombo(PlayerNumber pn, unsigned int i) {
  if (!IsValidRoutinePlayer(pn)) {
    WarnHighScore("HighScore rejected invalid routine player combo setter.");
    return;
  }
  m_Impl->playerMaxCombos[pn] = i;
}

void HighScore::SetPlayerGuid(PlayerNumber pn, const std::string& guid) {
  if (!IsValidRoutinePlayer(pn)) {
    WarnHighScore("HighScore rejected invalid routine player guid setter.");
    return;
  }
  m_Impl->playerGuids[pn] = guid;
}

void HighScore::SetPlayerTapNoteScore(
    PlayerNumber pn, TapNoteScore tns, int i) {
  if (!IsValidRoutinePlayer(pn) || !IsValidTapNoteScoreValue(tns)) {
    WarnHighScore(
        "HighScore rejected invalid routine player tap score setter.");
    return;
  }
  m_Impl->playerTapNoteScores[pn][tns] =
      SanitizeNonNegativeInt(i, "routine tap note score");
}

void HighScore::SetPlayerHoldNoteScore(
    PlayerNumber pn, HoldNoteScore hns, int i) {
  if (!IsValidRoutinePlayer(pn) || !IsValidHoldNoteScoreValue(hns)) {
    WarnHighScore(
        "HighScore rejected invalid routine player hold score setter.");
    return;
  }
  m_Impl->playerHoldNoteScores[pn][hns] =
      SanitizeNonNegativeInt(i, "routine hold note score");
}

/* We normally don't give direct access to the members.  We need this one
 * for NameToFillIn; use a special accessor so it's easy to find where this
 * is used. */
std::string* HighScore::GetNameMutable() { return &m_Impl->sName; }

bool HighScore::operator<(const HighScore& other) const {
  /* Make sure we treat AAAA as higher than AAA, even though the score
   * is the same. */
  return IsBetterHighScore(other, *this);
}

bool HighScore::operator>(const HighScore& other) const {
  return other.operator<(*this);
}

bool HighScore::operator<=(const HighScore& other) const {
  return !operator>(other);
}

bool HighScore::operator>=(const HighScore& other) const {
  return !operator<(other);
}

bool HighScore::operator==(const HighScore& other) const {
  return *m_Impl == *other.m_Impl;
}

bool HighScore::operator!=(const HighScore& other) const {
  return !operator==(other);
}

XNode* HighScore::CreateNode() const { return m_Impl->CreateNode(); }

void HighScore::LoadFromNode(const XNode* pNode) {
  m_Impl->LoadFromNode(pNode);
}

std::string HighScore::GetDisplayName() const {
  if (GetName().empty()) {
    if (THEME != nullptr && THEME->IsThemeLoaded() && EMPTY_NAME.IsLoaded()) {
      return EMPTY_NAME.GetValue();
    }
    return "???";
  } else {
    return GetName();
  }
}

/* begin HighScoreList */
void HighScoreList::Init() {
  iNumTimesPlayed = 0;
  vHighScores.clear();
  HighGrade = Grade_NoData;
  dtLastPlayed.Init();
}

void HighScoreList::AddHighScore(
    HighScore hs, int& iIndexOut, bool bIsMachine) {
  iIndexOut = -1;
  size_t insertIndex = 0;
  for (; insertIndex < vHighScores.size(); insertIndex++) {
    if (hs >= vHighScores[insertIndex]) {
      break;
    }
  }
  const int iMaxScores = GetMaxHighScoresForList(bIsMachine);
  if (insertIndex < static_cast<size_t>(iMaxScores)) {
    vHighScores.insert(vHighScores.begin() + insertIndex, hs);
    iIndexOut = static_cast<int>(insertIndex);

    // Delete extra machine high scores in RemoveAllButOneOfEachNameAndClampSize
    // and not here so that we don't end up with less than iMaxScores after
    // removing HighScores with duplicate names.
    //
    if (!bIsMachine) {
      ClampSize(bIsMachine);
    }
    HighGrade = BestGrade(hs.GetGrade(), HighGrade);
  }
}

void HighScoreList::IncrementPlayCount(DateTime _dtLastPlayed) {
  dtLastPlayed = _dtLastPlayed;
  iNumTimesPlayed = AddNonNegativeIntSaturated(
      iNumTimesPlayed, 1, "number of times played");
}

const HighScore& HighScoreList::GetTopScore() const {
  if (vHighScores.empty()) {
    static const HighScore hs;
    return hs;
  } else {
    return vHighScores[0];
  }
}

XNode* HighScoreList::CreateNode() const {
  XNode* pNode = new XNode("HighScoreList");

  pNode->AppendChild(
      "NumTimesPlayed",
      SanitizeNonNegativeInt(iNumTimesPlayed, "number of times played"));
  pNode->AppendChild("LastPlayed", dtLastPlayed.GetString());
  if (HighGrade != Grade_NoData) {
    pNode->AppendChild("HighGrade", GradeToString(SanitizeGrade(HighGrade)));
  }

  for (size_t i = 0; i < vHighScores.size(); i++) {
    const HighScore& hs = vHighScores[i];
    pNode->AppendChild(hs.CreateNode());
  }

  return pNode;
}

void HighScoreList::LoadFromNode(const XNode* pHighScoreList) {
  Init();

  if (pHighScoreList == nullptr ||
      pHighScoreList->GetName() != "HighScoreList") {
    WarnHighScore("HighScoreList ignored invalid or null XML node.");
    return;
  }
  FOREACH_CONST_Child(pHighScoreList, p) {
    const std::string& name = p->GetName();
    if (name == "NumTimesPlayed") {
      p->GetTextValue(iNumTimesPlayed);
      iNumTimesPlayed =
          SanitizeNonNegativeInt(iNumTimesPlayed, "number of times played");
    } else if (name == "LastPlayed") {
      std::string s;
      p->GetTextValue(s);
      dtLastPlayed.FromString(s);
    } else if (name == "HighGrade") {
      std::string s;
      p->GetTextValue(s);
      HighGrade = s.empty() ? Grade_NoData : SanitizeGrade(StringToGrade(s));
    } else if (name == "HighScore") {
      if (vHighScores.size() >=
          static_cast<size_t>(MAX_REASONABLE_HIGH_SCORE_LIMIT)) {
        WarnHighScore("HighScoreList truncated oversized XML score list.");
        continue;
      }
      vHighScores.resize(vHighScores.size() + 1);
      vHighScores.back().LoadFromNode(p);
    }
  }
  SortHighScoresBestFirst(vHighScores);
  std::vector<HighScore>::iterator unique_end =
      std::unique(vHighScores.begin(), vHighScores.end());
  vHighScores.erase(unique_end, vHighScores.end());
  HighGrade = CalculateHighGrade(vHighScores);
}

void HighScoreList::RemoveAllButOneOfEachName() {
  for (std::vector<HighScore>::iterator i = vHighScores.begin();
       i != vHighScores.end(); ++i) {
    if (!ShouldDeduplicateHighScoreName(i->GetName())) {
      continue;
    }
    for (std::vector<HighScore>::iterator j = i + 1; j != vHighScores.end();
         /* incremented below */) {
      if (i->GetName() == j->GetName()) {
        j = vHighScores.erase(j);
      } else {
        ++j;
      }
    }
  }
  HighGrade = CalculateHighGrade(vHighScores);
}

void HighScoreList::ClampSize(bool bIsMachine) {
  const int iMaxScores = GetMaxHighScoresForList(bIsMachine);
  const size_t maxScores = static_cast<size_t>(iMaxScores);
  if (vHighScores.size() > maxScores) {
    vHighScores.erase(vHighScores.begin() + maxScores, vHighScores.end());
  }
  HighGrade = CalculateHighGrade(vHighScores);
}

void HighScoreList::MergeFromOtherHSL(HighScoreList& other, bool is_machine) {
  iNumTimesPlayed = AddNonNegativeIntSaturated(
      iNumTimesPlayed, other.iNumTimesPlayed, "number of times played");
  if (other.dtLastPlayed > dtLastPlayed) {
    dtLastPlayed = other.dtLastPlayed;
  }
  vHighScores.insert(
      vHighScores.end(), other.vHighScores.begin(), other.vHighScores.end());
  SortHighScoresBestFirst(vHighScores);
  // Remove non-unique scores because they probably come from an accidental
  // repeated merge. -Kyz
  std::vector<HighScore>::iterator unique_end =
      std::unique(vHighScores.begin(), vHighScores.end());
  vHighScores.erase(unique_end, vHighScores.end());

  if (!AllowMultipleHighScoresWithSameName()) {
    // erase all but the highest score for each name
    RemoveAllButOneOfEachName();
  }
  ClampSize(is_machine);
  HighGrade = CalculateHighGrade(vHighScores);
}

XNode* Screenshot::CreateNode() const {
  XNode* pNode = new XNode("Screenshot");

  if (!sFileName.empty() && !IsSafeScreenshotFilename(sFileName)) {
    WarnHighScore("Screenshot omitted unsafe filename while writing XML.");
  }
  if (!IsValidMD5(sMD5)) {
    WarnHighScore("Screenshot omitted invalid MD5 while writing XML.");
  }
  pNode->AppendChild(
      "FileName", IsSafeScreenshotFilename(sFileName) ? sFileName : "");
  pNode->AppendChild("MD5", IsValidMD5(sMD5) ? sMD5 : "");
  pNode->AppendChild(highScore.CreateNode());

  return pNode;
}

void Screenshot::LoadFromNode(const XNode* pNode) {
  if (pNode == nullptr || pNode->GetName() != "Screenshot") {
    WarnHighScore("Screenshot ignored invalid or null XML node.");
    *this = Screenshot();
    return;
  }

  sFileName.clear();
  sMD5.clear();
  highScore.Unset();

  pNode->GetChildValue("FileName", sFileName);
  if (!sFileName.empty() && !IsSafeScreenshotFilename(sFileName)) {
    WarnHighScore("Screenshot cleared unsafe filename from XML.");
    sFileName.clear();
  }
  pNode->GetChildValue("MD5", sMD5);
  if (!IsValidMD5(sMD5)) {
    WarnHighScore("Screenshot cleared invalid MD5 from XML.");
    sMD5.clear();
  }
  const XNode* pHighScore = pNode->GetChild("HighScore");
  if (pHighScore) {
    highScore.LoadFromNode(pHighScore);
  } else {
    highScore.Unset();
  }
}

// lua start
#include "LuaBinding.h"

/** @brief Allow Lua to have access to the HighScore. */
class LunaHighScore : public Luna<HighScore> {
 public:
  static int GetName(T* p, lua_State* L) {
    lua_pushstring(L, p->GetName().c_str());
    return 1;
  }
  static int GetScore(T* p, lua_State* L) {
    lua_pushnumber(L, p->GetScore());
    return 1;
  }
  static int GetPercentDP(T* p, lua_State* L) {
    lua_pushnumber(L, p->GetPercentDP());
    return 1;
  }
  static int GetDate(T* p, lua_State* L) {
    lua_pushstring(L, p->GetDateTime().GetString().c_str());
    return 1;
  }
  static int GetSurvivalSeconds(T* p, lua_State* L) {
    lua_pushnumber(L, p->GetSurvivalSeconds());
    return 1;
  }
  static int IsFillInMarker(T* p, lua_State* L) {
    bool bIsFillInMarker = false;
    FOREACH_PlayerNumber(pn) bIsFillInMarker |=
        p->GetName() == RANKING_TO_FILL_IN_MARKER[pn];
    lua_pushboolean(L, bIsFillInMarker);
    return 1;
  }
  static int GetMaxCombo(T* p, lua_State* L) {
    lua_pushnumber(L, p->GetMaxCombo());
    return 1;
  }
  static int GetModifiers(T* p, lua_State* L) {
    lua_pushstring(L, p->GetModifiers().c_str());
    return 1;
  }
  static int GetTapNoteScore(T* p, lua_State* L) {
    lua_pushnumber(
        L, p->GetTapNoteScore(Enum::Check<TapNoteScore>(L, 1, true, true)));
    return 1;
  }
  static int GetHoldNoteScore(T* p, lua_State* L) {
    lua_pushnumber(
        L, p->GetHoldNoteScore(Enum::Check<HoldNoteScore>(L, 1, true, true)));
    return 1;
  }
  static int GetRadarValues(T* p, lua_State* L) {
    p->GetRadarValues().PushSelf(L);
    return 1;
  }
  static int IsRoutine(T* p, lua_State* L) {
    lua_pushboolean(L, p->IsRoutine());
    return 1;
  }
  static int GetPlayerGuid(T* p, lua_State* L) {
    PlayerNumber pn = Enum::Check<PlayerNumber>(L, 1, true);
    lua_pushstring(
        L, pn != PLAYER_INVALID ? p->GetPlayerGuid(pn).c_str() : "");
    return 1;
  }
  static int GetPlayerScore(T* p, lua_State* L) {
    PlayerNumber pn = Enum::Check<PlayerNumber>(L, 1, true);
    lua_pushnumber(L, pn != PLAYER_INVALID ? p->GetPlayerScore(pn) : 0);
    return 1;
  }
  static int GetPlayerPercentDP(T* p, lua_State* L) {
    PlayerNumber pn = Enum::Check<PlayerNumber>(L, 1, true);
    lua_pushnumber(L, pn != PLAYER_INVALID ? p->GetPlayerPercentDP(pn) : 0);
    return 1;
  }
  static int GetPlayerTapNoteScore(T* p, lua_State* L) {
    PlayerNumber pn = Enum::Check<PlayerNumber>(L, 1, true);
    TapNoteScore tns = Enum::Check<TapNoteScore>(L, 2, true, true);
    lua_pushnumber(
        L, pn != PLAYER_INVALID ? p->GetPlayerTapNoteScore(pn, tns) : 0);
    return 1;
  }
  static int GetPlayerHoldNoteScore(T* p, lua_State* L) {
    PlayerNumber pn = Enum::Check<PlayerNumber>(L, 1, true);
    HoldNoteScore hns = Enum::Check<HoldNoteScore>(L, 2, true, true);
    lua_pushnumber(
        L, pn != PLAYER_INVALID ? p->GetPlayerHoldNoteScore(pn, hns) : 0);
    return 1;
  }
  DEFINE_METHOD(GetGrade, GetGrade())
  DEFINE_METHOD(GetStageAward, GetStageAward())
  DEFINE_METHOD(GetPeakComboAward, GetPeakComboAward())

  LunaHighScore() {
    ADD_METHOD(GetName);
    ADD_METHOD(GetScore);
    ADD_METHOD(GetPercentDP);
    ADD_METHOD(GetDate);
    ADD_METHOD(GetSurvivalSeconds);
    ADD_METHOD(IsFillInMarker);
    ADD_METHOD(GetModifiers);
    ADD_METHOD(GetTapNoteScore);
    ADD_METHOD(GetHoldNoteScore);
    ADD_METHOD(GetRadarValues);
    ADD_METHOD(IsRoutine);
    ADD_METHOD(GetPlayerGuid);
    ADD_METHOD(GetPlayerScore);
    ADD_METHOD(GetPlayerPercentDP);
    ADD_METHOD(GetPlayerTapNoteScore);
    ADD_METHOD(GetPlayerHoldNoteScore);
    ADD_METHOD(GetGrade);
    ADD_METHOD(GetMaxCombo);
    ADD_METHOD(GetStageAward);
    ADD_METHOD(GetPeakComboAward);
  }
};

LUA_REGISTER_CLASS(HighScore)

/** @brief Allow Lua to have access to the HighScoreList. */
class LunaHighScoreList : public Luna<HighScoreList> {
 public:
  static int GetHighScores(T* p, lua_State* L) {
    lua_newtable(L);
    const size_t maxLuaScores = std::min(
        p->vHighScores.size(),
        static_cast<size_t>(std::numeric_limits<int>::max()));
    if (maxLuaScores != p->vHighScores.size()) {
      WarnHighScore("HighScoreList truncated oversized Lua high score table.");
    }
    for (size_t i = 0; i < maxLuaScores; ++i) {
      p->vHighScores[i].PushSelf(L);
      lua_rawseti(L, -2, static_cast<int>(i) + 1);
    }

    return 1;
  }

  static int GetHighestScoreOfName(T* p, lua_State* L) {
    std::string name = SArg(1);
    if (name.empty()) {
      lua_pushnil(L);
      return 1;
    }
    for (size_t i = 0; i < p->vHighScores.size(); ++i) {
      if (name == p->vHighScores[i].GetName()) {
        p->vHighScores[i].PushSelf(L);
        return 1;
      }
    }
    lua_pushnil(L);
    return 1;
  }

  static int GetRankOfName(T* p, lua_State* L) {
    std::string name = SArg(1);
    if (name.empty()) {
      lua_pushnumber(L, 0);
      return 1;
    }
    const size_t maxLuaScores = std::min(
        p->vHighScores.size(),
        static_cast<size_t>(std::numeric_limits<int>::max()));
    if (maxLuaScores != p->vHighScores.size()) {
      WarnHighScore("HighScoreList truncated oversized Lua rank lookup.");
    }
    int rank = 0;
    for (size_t i = 0; i < maxLuaScores; ++i) {
      if (name == p->vHighScores[i].GetName()) {
        // Indices from Lua are one-indexed.  +1 to adjust.
        rank = static_cast<int>(i) + 1;
        break;
      }
    }
    // The themer is expected to check for validity before using.
    lua_pushnumber(L, rank);
    return 1;
  }

  LunaHighScoreList() {
    ADD_METHOD(GetHighScores);
    ADD_METHOD(GetHighestScoreOfName);
    ADD_METHOD(GetRankOfName);
  }
};

LUA_REGISTER_CLASS(HighScoreList)
// lua end

/*
 * (c) 2004 Chris Danford
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
