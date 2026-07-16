#include "StageStats.h"

#include <algorithm>
#include <climits>
#include <cmath>
#include <limits>
#include <string>
#include <vector>

#include "DateTime.h"
#include "Difficulty.h"
#include "EnumHelper.h"
#include "GameConstantsAndTypes.h"
#include "GameState.h"
#include "HighScore.h"
#include "LuaManager.h"
#include "PlayerNumber.h"
#include "PlayerStageStats.h"
#include "PlayerState.h"
#include "PrefsManager.h"
#include "Profile.h"
#include "ProfileManager.h"
#include "RageLog.h"
#include "RageThreads.h"
#include "RageUtil.h"
#include "Song.h"
#include "Steps.h"
#include "Style.h"
#include "Trail.h"
#include "global.h"

namespace {
bool IsValidPlayerNumber(PlayerNumber pn) {
  return pn >= PLAYER_1 && pn < NUM_PLAYERS;
}

bool IsValidMultiPlayer(MultiPlayer mp) {
  return mp >= MultiPlayer_P1 && mp < NUM_MultiPlayer;
}

bool IsValidPlayMode(PlayMode playMode) {
  return playMode >= PLAY_MODE_REGULAR && playMode < NUM_PlayMode;
}

bool IsCoursePlayMode(PlayMode playMode) {
  switch (playMode) {
    case PLAY_MODE_NONSTOP:
    case PLAY_MODE_ONI:
    case PLAY_MODE_ENDLESS:
      return true;
    default:
      return false;
  }
}

bool HasRecordedPlayerStats(const PlayerStageStats& pss) {
  return pss.m_bJoined || pss.m_iStepsPlayed > 0 ||
         !pss.m_vpPossibleSteps.empty();
}

float ClampFiniteNonNegativeStageFloat(
    float value, const char* field, const char* context) {
  if (!std::isfinite(value)) {
    LOG->Warn(
        "SRC_AUDIT_FIX: %s clamped non-finite %s value %f to 0.",
        context, field, value);
    return 0.0f;
  }
  if (value < 0.0f) {
    LOG->Warn(
        "SRC_AUDIT_FIX: %s clamped negative %s value %f to 0.",
        context, field, value);
    return 0.0f;
  }
  return value;
}

float AddFiniteNonNegativeStageFloat(
    float current, float add, const char* field, const char* context) {
  current = ClampFiniteNonNegativeStageFloat(current, field, context);
  add = ClampFiniteNonNegativeStageFloat(add, field, context);
  if (add > std::numeric_limits<float>::max() - current) {
    LOG->Warn(
        "SRC_AUDIT_FIX: %s saturated %s float sum %f + %f.",
        context, field, current, add);
    return std::numeric_limits<float>::max();
  }
  return current + add;
}

int ClampMeterForAverage(int meter, const char* context) {
  if (meter < 0) {
    LOG->Warn(
        "SRC_AUDIT_FIX: %s clamped negative meter %i to 0.",
        context, meter);
    return 0;
  }
  return meter;
}

const Song* GetPrimaryScoreSong(const StageStats& ss) {
  if (!ss.m_vpPlayedSongs.empty() && ss.m_vpPlayedSongs[0] != nullptr) {
    return ss.m_vpPlayedSongs[0];
  }
  if (!ss.m_vpPossibleSongs.empty() && ss.m_vpPossibleSongs[0] != nullptr) {
    return ss.m_vpPossibleSongs[0];
  }
  return nullptr;
}

const Steps* GetPrimaryScoreSteps(const PlayerStageStats& pss) {
  if (!pss.m_vpPossibleSteps.empty() && pss.m_vpPossibleSteps[0] != nullptr) {
    return pss.m_vpPossibleSteps[0];
  }
  return nullptr;
}

bool IsRoutineSharedStyleActive() {
  if (GAMESTATE == nullptr) {
    return false;
  }

  const PlayerNumber master = GAMESTATE->GetMasterPlayerNumber();
  if (!IsValidPlayerNumber(master)) {
    return false;
  }

  const Style* style = GAMESTATE->GetCurrentStyle(master);
  return style != nullptr &&
         style->m_StyleType == StyleType_TwoPlayersSharedSides;
}

bool HasUsableStageStats(
    const PlayerStageStats& pss, const std::vector<Song*>& playedSongs,
    const std::vector<Song*>& possibleSongs, PlayMode playMode,
    const char* context) {
  if (playedSongs.empty() || possibleSongs.empty()) {
    LOG->Warn(
        "SRC_AUDIT_FIX: %s received empty stage song lists: played=%zu "
        "possible=%zu.",
        context, playedSongs.size(), possibleSongs.size());
    return false;
  }
  if (pss.m_iStepsPlayed <= 0 || pss.m_vpPossibleSteps.empty() ||
      pss.m_vpPossibleSteps[0] == nullptr) {
    LOG->Warn(
        "SRC_AUDIT_FIX: %s received incomplete player stats: stepsPlayed=%i "
        "possibleSteps=%zu.",
        context, pss.m_iStepsPlayed, pss.m_vpPossibleSteps.size());
    return false;
  }
  if (!IsValidPlayMode(playMode)) {
    LOG->Warn(
        "SRC_AUDIT_FIX: %s received invalid play mode %i.",
        context, playMode);
    return false;
  }
  if (playedSongs.size() != static_cast<size_t>(pss.m_iStepsPlayed) ||
      possibleSongs.size() != pss.m_vpPossibleSteps.size()) {
    LOG->Warn(
        "SRC_AUDIT_FIX: %s received mismatched stage stats: playedSongs=%zu "
        "stepsPlayed=%i possibleSongs=%zu possibleSteps=%zu.",
        context, playedSongs.size(), pss.m_iStepsPlayed, possibleSongs.size(),
        pss.m_vpPossibleSteps.size());
    return false;
  }
  if (pss.m_vpPossibleSteps.size() < playedSongs.size()) {
    LOG->Warn(
        "SRC_AUDIT_FIX: %s received too few possible steps: playedSongs=%zu "
        "possibleSteps=%zu.",
        context, playedSongs.size(), pss.m_vpPossibleSteps.size());
    return false;
  }
  for (size_t i = 0; i < playedSongs.size(); ++i) {
    if (playedSongs[i] == nullptr) {
      LOG->Warn(
          "SRC_AUDIT_FIX: %s received null played song at index %zu.",
          context, i);
      return false;
    }
  }
  for (size_t i = 0; i < possibleSongs.size(); ++i) {
    if (possibleSongs[i] == nullptr) {
      LOG->Warn(
          "SRC_AUDIT_FIX: %s received null possible song at index %zu.",
          context, i);
      return false;
    }
  }
  for (size_t i = 0; i < pss.m_vpPossibleSteps.size(); ++i) {
    const Steps* steps = pss.m_vpPossibleSteps[i];
    if (steps == nullptr) {
      LOG->Warn(
          "SRC_AUDIT_FIX: %s received null possible steps at index %zu.",
          context, i);
      return false;
    }
    if (steps->GetDifficulty() < 0 ||
        steps->GetDifficulty() >= NUM_Difficulty) {
      LOG->Warn(
          "SRC_AUDIT_FIX: %s received invalid difficulty %i at index %zu.",
          context, steps->GetDifficulty(), i);
      return false;
    }
  }
  return true;
}
}  // namespace

/* Arcade:	for the current stage (one song).
 * Nonstop/Oni/Endless:	 for current course (which usually contains multiple
 * songs)
 */

StageStats::StageStats() {
  m_playMode = PlayMode_Invalid;
  m_Stage = Stage_Invalid;
  m_iStageIndex = -1;
  m_vpPlayedSongs.clear();
  m_vpPossibleSongs.clear();
  m_EarnedExtraStage = EarnedExtraStage_No;
  m_bGaveUp = false;
  m_bUsedAutoplay = false;
  m_fGameplaySeconds = 0;
  m_fStepsSeconds = 0;
  m_fMusicRate = 1;
  FOREACH_PlayerNumber(pn) { m_player[pn].Init(pn); }
  FOREACH_MultiPlayer(pn) { m_multiPlayer[pn].Init(pn); }
  m_RoutinePlayer.Init(
      GAMESTATE != nullptr && IsValidPlayerNumber(GAMESTATE->GetMasterPlayerNumber())
          ? GAMESTATE->GetMasterPlayerNumber()
          : PLAYER_1);
}

void StageStats::Init() { *this = StageStats(); }

void StageStats::AssertValid(PlayerNumber pn) const {
  if (!IsValidPlayerNumber(pn)) {
    LOG->Warn(
        "SRC_AUDIT_FIX: StageStats::AssertValid ignored invalid player %i.",
        pn);
    return;
  }
  HasUsableStageStats(
      m_player[pn], m_vpPlayedSongs, m_vpPossibleSongs, m_playMode,
      "StageStats::AssertValid(PlayerNumber)");
}

void StageStats::AssertValid(MultiPlayer pn) const {
  if (!IsValidMultiPlayer(pn)) {
    LOG->Warn(
        "SRC_AUDIT_FIX: StageStats::AssertValid ignored invalid multiplayer "
        "%i.",
        pn);
    return;
  }
  HasUsableStageStats(
      m_multiPlayer[pn], m_vpPlayedSongs, m_vpPossibleSongs, m_playMode,
      "StageStats::AssertValid(MultiPlayer)");
}

int StageStats::GetAverageMeter(PlayerNumber pn) const {
  if (!IsValidPlayerNumber(pn) ||
      !HasUsableStageStats(
          m_player[pn], m_vpPlayedSongs, m_vpPossibleSongs, m_playMode,
          "StageStats::GetAverageMeter")) {
    return 0;
  }

  long long iTotalMeter = 0;
  int iValidMeters = 0;

  for (size_t i = 0; i < m_vpPlayedSongs.size(); i++) {
    const Steps* pSteps = m_player[pn].m_vpPossibleSteps[i];
    if (pSteps == nullptr) {
      LOG->Warn(
          "SRC_AUDIT_FIX: StageStats::GetAverageMeter skipped null steps at "
          "index %zu for player %i.",
          i, pn);
      continue;
    }
    iTotalMeter += ClampMeterForAverage(
        pSteps->GetMeter(), "StageStats::GetAverageMeter");
    ++iValidMeters;
  }
  if (iValidMeters <= 0) {
    return 0;
  }
  const long long iAverageMeter = iTotalMeter / iValidMeters;  // round down
  if (iAverageMeter > std::numeric_limits<int>::max()) {
    LOG->Warn(
        "SRC_AUDIT_FIX: StageStats::GetAverageMeter saturated average meter "
        "%lld.",
        iAverageMeter);
    return std::numeric_limits<int>::max();
  }
  return static_cast<int>(iAverageMeter);
}

void StageStats::AddStats(const StageStats& other) {
  if (other.m_vpPlayedSongs.empty()) {
    LOG->Warn("SRC_AUDIT_FIX: StageStats::AddStats ignored empty stage stats.");
    return;
  }
  if (!IsValidPlayMode(other.m_playMode)) {
    LOG->Warn(
        "SRC_AUDIT_FIX: StageStats::AddStats ignored invalid source play mode "
        "%i.",
        other.m_playMode);
  } else if (!IsValidPlayMode(m_playMode)) {
    m_playMode = other.m_playMode;
  } else if (m_playMode != other.m_playMode) {
    LOG->Warn(
        "SRC_AUDIT_FIX: StageStats::AddStats kept play mode %i while adding "
        "stats from mode %i.",
        m_playMode, other.m_playMode);
  }
  for (Song* s : other.m_vpPlayedSongs) {
    if (s == nullptr) {
      LOG->Warn(
          "SRC_AUDIT_FIX: StageStats::AddStats skipped null played song.");
      continue;
    }
    m_vpPlayedSongs.push_back(s);
  }
  for (Song* s : other.m_vpPossibleSongs) {
    if (s == nullptr) {
      LOG->Warn(
          "SRC_AUDIT_FIX: StageStats::AddStats skipped null possible song.");
      continue;
    }
    m_vpPossibleSongs.push_back(s);
  }
  m_Stage = Stage_Invalid;  // meaningless
  m_iStageIndex = -1;       // meaningless

  m_bGaveUp |= other.m_bGaveUp;
  m_bUsedAutoplay |= other.m_bUsedAutoplay;

  m_fGameplaySeconds = AddFiniteNonNegativeStageFloat(
      m_fGameplaySeconds, other.m_fGameplaySeconds, "gameplay seconds",
      "StageStats::AddStats");
  m_fStepsSeconds = AddFiniteNonNegativeStageFloat(
      m_fStepsSeconds, other.m_fStepsSeconds, "steps seconds",
      "StageStats::AddStats");

  FOREACH_PlayerNumber(p) {
    if (other.m_player[p].m_bJoined ||
        !other.m_player[p].m_vpPossibleSteps.empty() ||
        other.m_player[p].m_iStepsPlayed > 0) {
      m_player[p].AddStats(other.m_player[p]);
    }
  }
  FOREACH_MultiPlayer(mp) {
    if (other.m_multiPlayer[mp].m_bJoined ||
        !other.m_multiPlayer[mp].m_vpPossibleSteps.empty() ||
        other.m_multiPlayer[mp].m_iStepsPlayed > 0) {
      m_multiPlayer[mp].AddStats(other.m_multiPlayer[mp]);
    }
  }
  if (HasRecordedPlayerStats(other.m_RoutinePlayer)) {
    m_RoutinePlayer.AddStats(other.m_RoutinePlayer);
  }
}

void StageStats::SynchronizeRoutineScoreToPlayers() {
  if (!IsRoutineSharedStyleActive() ||
      !HasRecordedPlayerStats(m_RoutinePlayer)) {
    return;
  }

  const PlayerNumber master = GAMESTATE->GetMasterPlayerNumber();
  const Style* style = IsValidPlayerNumber(master)
                           ? GAMESTATE->GetCurrentStyle(master)
                           : nullptr;
  if (style == nullptr) {
    LOG->Warn(
        "Routine score synchronization skipped because the shared style is "
        "missing.");
    return;
  }

  FOREACH_PlayerNumber(pn) {
    PlayerStageStats& target = m_player[pn];
    target.m_pStyle = style;
    target.m_bJoined = true;
    target.m_vpPossibleSteps = m_RoutinePlayer.m_vpPossibleSteps;
    target.m_iStepsPlayed = m_RoutinePlayer.m_iStepsPlayed;
    target.m_fAliveSeconds = m_RoutinePlayer.m_fAliveSeconds;
    target.m_bFailed = m_RoutinePlayer.m_bFailed;
    target.m_bPlayerCanAchieveFullCombo =
        m_RoutinePlayer.m_bPlayerCanAchieveFullCombo;
    target.m_iPossibleDancePoints = m_RoutinePlayer.m_iPossibleDancePoints;
    target.m_iCurPossibleDancePoints =
        m_RoutinePlayer.m_iCurPossibleDancePoints;
    target.m_iActualDancePoints = m_RoutinePlayer.m_iActualDancePoints;
    target.m_iPossibleGradePoints = m_RoutinePlayer.m_iPossibleGradePoints;
    FOREACH_ENUM(TapNoteScore, tns) {
      target.m_iTapNoteScores[tns] = m_RoutinePlayer.m_iTapNoteScores[tns];
    }
    FOREACH_ENUM(HoldNoteScore, hns) {
      target.m_iHoldNoteScores[hns] = m_RoutinePlayer.m_iHoldNoteScores[hns];
    }
    target.m_iCurCombo = m_RoutinePlayer.m_iCurCombo;
    target.m_iMaxCombo = m_RoutinePlayer.m_iMaxCombo;
    target.m_iCurMissCombo = m_RoutinePlayer.m_iCurMissCombo;
    target.m_iCurScoreMultiplier = m_RoutinePlayer.m_iCurScoreMultiplier;
    target.m_iScore = m_RoutinePlayer.m_iScore;
    target.m_iCurMaxScore = m_RoutinePlayer.m_iCurMaxScore;
    target.m_iMaxScore = m_RoutinePlayer.m_iMaxScore;
    target.m_iSongsPassed = m_RoutinePlayer.m_iSongsPassed;
    target.m_iSongsPlayed = m_RoutinePlayer.m_iSongsPlayed;
    target.m_fLifeRemainingSeconds =
        m_RoutinePlayer.m_fLifeRemainingSeconds;
    target.m_fLifeRecord = m_RoutinePlayer.m_fLifeRecord;
    target.m_ComboList = m_RoutinePlayer.m_ComboList;
    target.m_fFirstSecond = m_RoutinePlayer.m_fFirstSecond;
    target.m_fLastSecond = m_RoutinePlayer.m_fLastSecond;
    target.m_StageAward = m_RoutinePlayer.m_StageAward;
    target.m_PeakComboAward = m_RoutinePlayer.m_PeakComboAward;
    target.m_bDisqualified = m_RoutinePlayer.m_bDisqualified;
  }

  LOG->Trace(
      "Routine shared score synchronized to participants: master=%i score=%u "
      "percent=%.6f failed=%d disqualified=%d.",
      static_cast<int>(master), m_RoutinePlayer.m_iScore,
      m_RoutinePlayer.GetPercentDancePoints(), m_RoutinePlayer.m_bFailed ? 1 : 0,
      m_RoutinePlayer.m_bDisqualified ? 1 : 0);
}

bool StageStats::OnePassed() const {
  if (IsRoutineSharedStyleActive() &&
      HasRecordedPlayerStats(m_RoutinePlayer)) {
    return !m_RoutinePlayer.m_bFailed;
  }

  FOREACH_PlayerNumber(p) {
    if (HasRecordedPlayerStats(m_player[p]) && !m_player[p].m_bFailed) {
      return true;
    }
  }
  return false;
}

bool StageStats::AllFailed() const {
  if (IsRoutineSharedStyleActive() &&
      HasRecordedPlayerStats(m_RoutinePlayer)) {
    return m_RoutinePlayer.m_bFailed;
  }

  bool bSawRecordedPlayer = false;
  FOREACH_PlayerNumber(p) {
    if (!HasRecordedPlayerStats(m_player[p])) {
      continue;
    }
    bSawRecordedPlayer = true;
    if (!m_player[p].m_bFailed) {
      return false;
    }
  }
  return bSawRecordedPlayer;
}

float StageStats::GetTotalPossibleStepsSeconds() const {
  float fSecs = 0;
  for (const Song* s : m_vpPlayedSongs) {
    if (s == nullptr) {
      LOG->Warn(
          "SRC_AUDIT_FIX: StageStats::GetTotalPossibleStepsSeconds skipped "
          "null song.");
      continue;
    }
    const float fSongSeconds = s->GetStepsSeconds();
    if (!std::isfinite(fSongSeconds) || fSongSeconds < 0.0f) {
      LOG->Warn(
          "SRC_AUDIT_FIX: StageStats::GetTotalPossibleStepsSeconds skipped "
          "invalid song seconds %f.",
          fSongSeconds);
      continue;
    }
    fSecs = AddFiniteNonNegativeStageFloat(
        fSecs, fSongSeconds, "possible steps seconds",
        "StageStats::GetTotalPossibleStepsSeconds");
  }
  if (!std::isfinite(m_fMusicRate) || m_fMusicRate <= 0.0f) {
    LOG->Warn(
        "SRC_AUDIT_FIX: StageStats::GetTotalPossibleStepsSeconds ignored "
        "invalid music rate %f.",
        m_fMusicRate);
    return fSecs;
  }
  return fSecs / m_fMusicRate;
}

static HighScore FillInHighScore(
    const PlayerStageStats& pss, const PlayerState& ps,
    const std::string& sRankingToFillInMarker, const std::string& sPlayerGuid,
    const std::string& sSongOptions, const std::string& sMachineGuid,
    int iProductID) {
  HighScore hs;
  hs.SetName(sRankingToFillInMarker);
  hs.SetGrade(pss.GetGrade());
  hs.SetScore(pss.m_iScore);
  hs.SetPercentDP(ClampFiniteNonNegativeStageFloat(
      pss.GetPercentDancePoints(), "percent dance points",
      "FillInHighScore"));
  hs.SetAliveSeconds(ClampFiniteNonNegativeStageFloat(
      pss.m_fAliveSeconds, "alive seconds", "FillInHighScore"));
  hs.SetMaxCombo(pss.GetMaxCombo().m_cnt);
  hs.SetStageAward(pss.m_StageAward);
  hs.SetPeakComboAward(pss.m_PeakComboAward);

  std::vector<std::string> asModifiers;
  {
    std::string sPlayerOptions = ps.m_PlayerOptions.GetStage().GetString();
    if (!sPlayerOptions.empty()) {
      asModifiers.push_back(sPlayerOptions);
    }
    if (!sSongOptions.empty()) {
      asModifiers.push_back(sSongOptions);
    }
  }
  hs.SetModifiers(join(", ", asModifiers));

  hs.SetDateTime(DateTime::GetNowDateTime());
  hs.SetPlayerGuid(sPlayerGuid);
  if (!sMachineGuid.empty()) {
    hs.SetMachineGuid(sMachineGuid);
  }
  hs.SetProductID(iProductID);
  FOREACH_ENUM(TapNoteScore, tns)
  hs.SetTapNoteScore(tns, pss.m_iTapNoteScores[tns]);
  FOREACH_ENUM(HoldNoteScore, hns)
  hs.SetHoldNoteScore(hns, pss.m_iHoldNoteScores[hns]);
  hs.SetRadarValues(pss.m_radarActual);
  hs.SetLifeRemainingSeconds(ClampFiniteNonNegativeStageFloat(
      pss.m_fLifeRemainingSeconds, "life remaining seconds",
      "FillInHighScore"));
  hs.SetDisqualified(pss.IsDisqualified());

  return hs;
}

static std::string GetPersistentPlayerGuid(PlayerNumber pn) {
  if (PROFILEMAN == nullptr || !IsValidPlayerNumber(pn)) {
    return "";
  }

  const Profile* pPlayerProfile = PROFILEMAN->GetProfile(pn);
  return PROFILEMAN->IsPersistentProfile(pn) && pPlayerProfile != nullptr
             ? pPlayerProfile->m_sGuid
             : std::string("");
}

static std::string GetRepresentativeRoutineGuid(
    const std::vector<std::string>& playerGuids, PlayerNumber master) {
  if (IsValidPlayerNumber(master) &&
      static_cast<size_t>(master) < playerGuids.size() &&
      !playerGuids[master].empty()) {
    return playerGuids[master];
  }

  for (const std::string& guid : playerGuids) {
    if (!guid.empty()) {
      return guid;
    }
  }

  return "";
}

static HighScore FillInRoutineHighScore(
    const PlayerStageStats& sharedStats, const PlayerState& masterState,
    PlayerNumber master, const std::vector<PlayerStageStats>& playerStats,
    const std::vector<std::string>& playerGuids,
    const std::string& sSongOptions, const std::string& sMachineGuid,
    int iProductID) {
  HighScore hs = FillInHighScore(
      sharedStats, masterState, RANKING_TO_FILL_IN_MARKER[master],
      GetRepresentativeRoutineGuid(playerGuids, master), sSongOptions,
      sMachineGuid, iProductID);
  hs.SetRoutine(true);

  FOREACH_PlayerNumber(pn) {
    const PlayerStageStats& pss = playerStats[pn];
    hs.SetPlayerGrade(pn, pss.GetGrade());
    hs.SetPlayerScore(pn, pss.m_iScore);
    hs.SetPlayerPercentDP(pn, pss.GetPercentDancePoints());
    hs.SetPlayerMaxCombo(pn, pss.GetMaxCombo().m_cnt);
    if (static_cast<size_t>(pn) < playerGuids.size()) {
      hs.SetPlayerGuid(pn, playerGuids[pn]);
    }
    FOREACH_ENUM(TapNoteScore, tns) {
      hs.SetPlayerTapNoteScore(pn, tns, pss.m_iTapNoteScores[tns]);
    }
    FOREACH_ENUM(HoldNoteScore, hns) {
      hs.SetPlayerHoldNoteScore(pn, hns, pss.m_iHoldNoteScores[hns]);
    }
  }

  return hs;
}

static bool CanFillHighScore(PlayerNumber p, const char* context) {
  if (GAMESTATE == nullptr || !IsValidPlayerNumber(p) ||
      GAMESTATE->m_pPlayerState[p] == nullptr) {
    LOG->Warn(
        "SRC_AUDIT_FIX: %s skipped player %i because PlayerState is missing.",
        context, p);
    return false;
  }
  return true;
}

static bool CanFillHighScore(MultiPlayer mp, const char* context) {
  if (GAMESTATE == nullptr || !IsValidMultiPlayer(mp) ||
      GAMESTATE->m_pMultiPlayerState[mp] == nullptr) {
    LOG->Warn(
        "SRC_AUDIT_FIX: %s skipped multiplayer %i because PlayerState is "
        "missing.",
        context, mp);
    return false;
  }
  return true;
}

static const Style* GetScoreStyle(
    const PlayerStageStats& pss, PlayerNumber p, const char* context) {
  if (!IsValidPlayerNumber(p)) {
    return nullptr;
  }
  const Style* pStyle = pss.m_pStyle;
  if (pStyle == nullptr && GAMESTATE != nullptr) {
    pStyle = GAMESTATE->GetCurrentStyle(p);
  }
  if (pStyle == nullptr) {
    LOG->Warn(
        "SRC_AUDIT_FIX: %s skipped player %i because current style is "
        "missing.",
        context, p);
  }
  return pStyle;
}

static bool HasSongScoreContext(
    const Song* pSong, const Steps* pSteps, PlayerNumber p,
    const char* context) {
  if (pSong == nullptr || pSteps == nullptr) {
    LOG->Warn(
        "SRC_AUDIT_FIX: %s skipped player %i because song=%p steps=%p.",
        context, p, static_cast<const void*>(pSong),
        static_cast<const void*>(pSteps));
    return false;
  }
  return true;
}

static bool HasCourseScoreContext(
    const Course* pCourse, const Trail* pTrail, PlayerNumber p,
    const char* context) {
  if (pCourse == nullptr || pTrail == nullptr) {
    LOG->Warn(
        "SRC_AUDIT_FIX: %s skipped player %i because course=%p trail=%p.",
        context, p, static_cast<const void*>(pCourse),
        static_cast<const void*>(pTrail));
    return false;
  }
  return true;
}

void StageStats::FinalizeScores(bool bSummary) {
  if (GAMESTATE == nullptr || PREFSMAN == nullptr || PROFILEMAN == nullptr) {
    LOG->Warn(
        "SRC_AUDIT_FIX: StageStats::FinalizeScores skipped because a manager "
        "is missing: GAMESTATE=%p PREFSMAN=%p PROFILEMAN=%p.",
        static_cast<void*>(GAMESTATE), static_cast<void*>(PREFSMAN),
        static_cast<void*>(PROFILEMAN));
    return;
  }

  PlayMode playMode = m_playMode;
  if (!IsValidPlayMode(playMode)) {
    playMode = GAMESTATE->m_PlayMode.Get();
    LOG->Warn(
        "SRC_AUDIT_FIX: StageStats::FinalizeScores fell back to live play "
        "mode %i because stored mode %i is invalid.",
        playMode, m_playMode);
  }
  if (!IsValidPlayMode(playMode)) {
    LOG->Warn(
        "SRC_AUDIT_FIX: StageStats::FinalizeScores skipped invalid play mode "
        "%i.",
        playMode);
    return;
  }

  switch (playMode) {
    case PLAY_MODE_BATTLE:
    case PLAY_MODE_RAVE:
      return;  // don't save scores in battle
    default:
      break;
  }

  if (PREFSMAN->m_sTestInitialScreen.Get() != "") {
    FOREACH_PlayerNumber(pn) {
      m_player[pn].m_iPersonalHighScoreIndex = 0;
      m_player[pn].m_iMachineHighScoreIndex = 0;
    }
  }

  // don't save scores if the player chose not to
  if (!GAMESTATE->m_SongOptions.GetCurrent().m_bSaveScore) {
    return;
  }

  LOG->Trace("saving stats and high scores");

  // generate a HighScore for each player
  bool bPlayerScoreFilled[NUM_PLAYERS] = {};
  bool bMultiPlayerScoreFilled[NUM_MultiPlayer] = {};
  const bool bCourseMode = IsCoursePlayMode(playMode);
  if (GAMESTATE->IsCourseMode() != bCourseMode) {
    LOG->Warn(
        "SRC_AUDIT_FIX: StageStats::FinalizeScores play mode mismatch: "
        "stored course mode=%i live course mode=%i.",
        bCourseMode ? 1 : 0, GAMESTATE->IsCourseMode() ? 1 : 0);
  }
  const std::string sSongOptions =
      GAMESTATE->m_SongOptions.GetStage().GetString();
  const Profile* pMachineProfile = PROFILEMAN->GetMachineProfile();
  const std::string sMachineGuid =
      pMachineProfile != nullptr ? pMachineProfile->m_sGuid : std::string("");
  if (pMachineProfile == nullptr) {
    LOG->Warn(
        "SRC_AUDIT_FIX: StageStats::FinalizeScores is filling scores without "
        "a machine profile guid.");
  }

  // whether or not to save scores when the stage was failed depends on if this
  // is a course or not... it's handled below in the switch.
  FOREACH_PlayerNumber(p) {
    if (!HasRecordedPlayerStats(m_player[p])) {
      continue;
    }
    if (!CanFillHighScore(p, "StageStats::FinalizeScores")) {
      continue;
    }
    const std::string sPlayerGuid = GetPersistentPlayerGuid(p);
    m_player[p].m_HighScore = FillInHighScore(
        m_player[p], *GAMESTATE->m_pPlayerState[p],
        RANKING_TO_FILL_IN_MARKER[p], sPlayerGuid, sSongOptions, sMachineGuid,
        PREFSMAN->m_iProductID);
    bPlayerScoreFilled[p] = true;
  }
  FOREACH_MultiPlayer(mp) {
    if (!HasRecordedPlayerStats(m_multiPlayer[mp])) {
      continue;
    }
    if (!CanFillHighScore(mp, "StageStats::FinalizeScores")) {
      continue;
    }
    std::string sPlayerGuid = "00000000-0000-0000-0000-000000000000";  // FIXME
    m_multiPlayer[mp].m_HighScore = FillInHighScore(
        m_multiPlayer[mp], *GAMESTATE->m_pMultiPlayerState[mp], "",
        sPlayerGuid, sSongOptions, sMachineGuid, PREFSMAN->m_iProductID);
    bMultiPlayerScoreFilled[mp] = true;
  }
  const PlayerNumber master = GAMESTATE->GetMasterPlayerNumber();
  const Style* pMasterStyle = IsValidPlayerNumber(master)
                                  ? GAMESTATE->GetCurrentStyle(master)
                                  : nullptr;
  const bool bRoutineSharedStyle =
      pMasterStyle != nullptr &&
      pMasterStyle->m_StyleType == StyleType_TwoPlayersSharedSides;
  if (bRoutineSharedStyle && IsValidPlayerNumber(master) &&
      HasRecordedPlayerStats(m_RoutinePlayer)) {
    m_player[master].m_bFailed = m_RoutinePlayer.m_bFailed;
    FOREACH_PlayerNumber(p) {
      if (p != master) {
        bPlayerScoreFilled[p] = false;
      }
    }

    const Steps* pRoutineSteps = GetPrimaryScoreSteps(m_RoutinePlayer);
    const std::string routineStepsType =
        pRoutineSteps != nullptr
            ? StepsTypeToString(pRoutineSteps->m_StepsType)
            : std::string("StepsType_Invalid");

    if (m_RoutinePlayer.m_bFailed) {
      bPlayerScoreFilled[master] = false;
      m_player[master].m_iPersonalHighScoreIndex = -1;
      m_player[master].m_iMachineHighScoreIndex = -1;
      LOG->Trace(
          "Routine shared high score skipped: master=%i reason=failed "
          "score=%u percent=%.6f steps_type=%s.",
          static_cast<int>(master), m_RoutinePlayer.m_iScore,
          m_RoutinePlayer.GetPercentDancePoints(), routineStepsType.c_str());
    } else if (CanFillHighScore(
                   master, "StageStats::FinalizeScores routine")) {
      std::vector<PlayerStageStats> routinePlayerStats(NUM_PLAYERS);
      std::vector<std::string> routinePlayerGuids(NUM_PLAYERS);
      FOREACH_PlayerNumber(pn) {
        routinePlayerStats[pn] = m_player[pn];
        routinePlayerGuids[pn] = GetPersistentPlayerGuid(pn);
      }
      m_player[master].m_HighScore = FillInRoutineHighScore(
          m_RoutinePlayer, *GAMESTATE->m_pPlayerState[master], master,
          routinePlayerStats, routinePlayerGuids, sSongOptions, sMachineGuid,
          PREFSMAN->m_iProductID);
      m_player[master].m_HighScore.SetName(RANKING_TO_FILL_IN_MARKER[master]);
      bPlayerScoreFilled[master] = true;
      LOG->Trace(
          "Routine shared high score prepared: master=%i score=%u "
          "percent=%.6f steps_type=%s p1_guid=%s p2_guid=%s.",
          static_cast<int>(master), m_RoutinePlayer.m_iScore,
          m_RoutinePlayer.GetPercentDancePoints(), routineStepsType.c_str(),
          routinePlayerGuids[PLAYER_1].c_str(),
          routinePlayerGuids[PLAYER_2].c_str());
    }
  }

  FOREACH_PlayerNumber(p) {
    if (!bPlayerScoreFilled[p]) {
      continue;
    }
    const HighScore& hs = m_player[p].m_HighScore;
    const bool bRoutineSharedScore =
        bRoutineSharedStyle && p == master &&
        HasRecordedPlayerStats(m_RoutinePlayer);
    const PlayerStageStats& scoreStats =
        bRoutineSharedScore ? m_RoutinePlayer : m_player[p];
    const Style* pStyle =
        bRoutineSharedScore
            ? pMasterStyle
            : GetScoreStyle(m_player[p], p, "StageStats::FinalizeScores");
    if (pStyle == nullptr) {
      continue;
    }
    StepsType st = pStyle->m_StepsType;

    const Song* pSong = GetPrimaryScoreSong(*this);
    const Steps* pSteps = GetPrimaryScoreSteps(scoreStats);

    // Don't save DQ'd scores
    if (hs.GetDisqualified()) {
      continue;
    }

    // Don't save autoplay scores
    if (m_bUsedAutoplay) {
      continue;
    }

    if (bSummary) {
      // don't save scores if any stage was failed
      if (scoreStats.m_bFailed) {
        continue;
      }

      int iRankingMeter = GetAverageMeter(p);
      if (bCourseMode) {
        const Trail* pTrail = GAMESTATE->m_pCurTrail[p];
        if (pTrail != nullptr) {
          iRankingMeter = ClampMeterForAverage(
              pTrail->GetMeter(), "StageStats::FinalizeScores");
        } else {
          LOG->Warn(
              "SRC_AUDIT_FIX: StageStats::FinalizeScores used average step "
              "meter for summary player %i because trail is missing.",
              p);
        }
      }
      m_player[p].m_rc = AverageMeterToRankingCategory(iRankingMeter);

      PROFILEMAN->AddCategoryScore(
          st, m_player[p].m_rc, p, hs, m_player[p].m_iPersonalHighScoreIndex,
          m_player[p].m_iMachineHighScoreIndex);

      // TRICKY: Increment play count here, and not on ScreenGameplay like the
      // others.
      PROFILEMAN->IncrementCategoryPlayCount(st, m_player[p].m_rc, p);
    } else if (bCourseMode) {
      // Save this stage to recent scores
      Course* pCourse = GAMESTATE->m_pCurCourse;
      Trail* pTrail = GAMESTATE->m_pCurTrail[p];
      if (!HasCourseScoreContext(
              pCourse, pTrail, p, "StageStats::FinalizeScores")) {
        continue;
      }

      PROFILEMAN->AddCourseScore(
          pCourse, pTrail, p, hs, m_player[p].m_iPersonalHighScoreIndex,
          m_player[p].m_iMachineHighScoreIndex);
    } else {
      if (!HasSongScoreContext(
              pSong, pSteps, p, "StageStats::FinalizeScores")) {
        continue;
      }

      PROFILEMAN->AddStepsScore(
          pSong, pSteps, p, hs, m_player[p].m_iPersonalHighScoreIndex,
          m_player[p].m_iMachineHighScoreIndex);
    }
  }

  // If both players get a machine high score in the same HighScoreList,
  // then one player's score may have bumped the other player. Look in
  // the HighScoreList and re-get the high score index.
  FOREACH_PlayerNumber(p) {
    if (!bPlayerScoreFilled[p]) {
      continue;
    }
    if (m_player[p].m_iMachineHighScoreIndex == -1) {  // no record
      continue;                                        // skip
    }

    HighScore& hs = m_player[p].m_HighScore;
    Profile* pProfile = PROFILEMAN->GetMachineProfile();
    if (pProfile == nullptr) {
      LOG->Warn(
          "SRC_AUDIT_FIX: StageStats::FinalizeScores cannot reindex machine "
          "score without machine profile.");
      m_player[p].m_iMachineHighScoreIndex = -1;
      continue;
    }
    const bool bRoutineSharedScore =
        bRoutineSharedStyle && p == master &&
        HasRecordedPlayerStats(m_RoutinePlayer);
    const PlayerStageStats& scoreStats =
        bRoutineSharedScore ? m_RoutinePlayer : m_player[p];
    const Style* pStyle =
        bRoutineSharedScore
            ? pMasterStyle
            : GetScoreStyle(m_player[p], p, "StageStats::FinalizeScores");
    if (pStyle == nullptr) {
      m_player[p].m_iMachineHighScoreIndex = -1;
      continue;
    }
    StepsType st = pStyle->m_StepsType;

    const HighScoreList* pHSL = nullptr;
    if (bSummary) {
      pHSL = &pProfile->GetCategoryHighScoreList(st, m_player[p].m_rc);
    } else if (bCourseMode) {
      Course* pCourse = GAMESTATE->m_pCurCourse;
      Trail* pTrail = GAMESTATE->m_pCurTrail[p];
      if (!HasCourseScoreContext(
              pCourse, pTrail, p, "StageStats::FinalizeScores")) {
        m_player[p].m_iMachineHighScoreIndex = -1;
        continue;
      }
      pHSL = &pProfile->GetCourseHighScoreList(pCourse, pTrail);
    } else {
      const Song* pSong = GetPrimaryScoreSong(*this);
      const Steps* pSteps = GetPrimaryScoreSteps(scoreStats);
      if (!HasSongScoreContext(
              pSong, pSteps, p, "StageStats::FinalizeScores")) {
        m_player[p].m_iMachineHighScoreIndex = -1;
        continue;
      }
      pHSL = &pProfile->GetStepsHighScoreList(pSong, pSteps);
    }

    std::vector<HighScore>::const_iterator iter =
        find(pHSL->vHighScores.begin(), pHSL->vHighScores.end(), hs);
    if (iter == pHSL->vHighScores.end()) {
      m_player[p].m_iMachineHighScoreIndex = -1;
    } else {
      m_player[p].m_iMachineHighScoreIndex = iter - pHSL->vHighScores.begin();
    }
  }
  FOREACH_MultiPlayer(mp) {
    if (bMultiPlayerScoreFilled[mp]) {
      LOG->Trace(
          "SRC_AUDIT_FIX: StageStats::FinalizeScores prepared multiplayer "
          "high score %i for runtime consumers; profile persistence remains "
          "handled outside StageStats.",
          mp);
    }
  }

  if (bRoutineSharedStyle && IsValidPlayerNumber(master) &&
      HasRecordedPlayerStats(m_RoutinePlayer)) {
    m_RoutinePlayer.m_HighScore = m_player[master].m_HighScore;
    m_RoutinePlayer.m_iPersonalHighScoreIndex =
        m_player[master].m_iPersonalHighScoreIndex;
    m_RoutinePlayer.m_iMachineHighScoreIndex =
        m_player[master].m_iMachineHighScoreIndex;
  }

  LOG->Trace("done saving stats and high scores");
}

bool StageStats::PlayerHasHighScore(PlayerNumber pn) const {
  if (!IsValidPlayerNumber(pn)) {
    LOG->Warn(
        "SRC_AUDIT_FIX: StageStats::PlayerHasHighScore ignored invalid "
        "player %i.",
        pn);
    return false;
  }
  if (GAMESTATE == nullptr || PROFILEMAN == nullptr || PREFSMAN == nullptr) {
    LOG->Warn(
        "SRC_AUDIT_FIX: StageStats::PlayerHasHighScore skipped because a "
        "manager is missing: GAMESTATE=%p PROFILEMAN=%p PREFSMAN=%p.",
        static_cast<void*>(GAMESTATE), static_cast<void*>(PROFILEMAN),
        static_cast<void*>(PREFSMAN));
    return false;
  }

  const PlayerNumber master = GAMESTATE->GetMasterPlayerNumber();
  const bool bRoutineSharedScore =
      IsRoutineSharedStyleActive() && pn == master &&
      HasRecordedPlayerStats(m_RoutinePlayer);
  const PlayerStageStats& scoreStats =
      bRoutineSharedScore ? m_RoutinePlayer : m_player[pn];

  if (scoreStats.m_bFailed) {
    LOG->Trace(
        "Routine shared high score check skipped failed score: player=%i "
        "routine=%d.",
        static_cast<int>(pn), bRoutineSharedScore ? 1 : 0);
    return false;
  }

  if (m_vpPlayedSongs.empty() || m_vpPlayedSongs[0] == nullptr ||
      scoreStats.m_vpPossibleSteps.empty() ||
      scoreStats.m_vpPossibleSteps[0] == nullptr) {
    LOG->Warn(
        "SRC_AUDIT_FIX: StageStats::PlayerHasHighScore missing stats for "
        "player %i routine=%d.",
        pn, bRoutineSharedScore ? 1 : 0);
    return false;
  }

  const Song* pSong = GetPrimaryScoreSong(*this);
  const Steps* pSteps = GetPrimaryScoreSteps(scoreStats);
  const bool bCourseMode =
      IsValidPlayMode(m_playMode) ? IsCoursePlayMode(m_playMode)
                                  : GAMESTATE->IsCourseMode();
  const Course* pCourse = GAMESTATE->m_pCurCourse;
  const Trail* pTrail = GAMESTATE->m_pCurTrail[pn];
  Profile* pMachineProfile = PROFILEMAN->GetMachineProfile();
  if (pMachineProfile == nullptr) {
    LOG->Warn(
        "SRC_AUDIT_FIX: StageStats::PlayerHasHighScore cannot check machine "
        "scores without machine profile.");
    return false;
  }
  if (bCourseMode &&
      !HasCourseScoreContext(
          pCourse, pTrail, pn, "StageStats::PlayerHasHighScore")) {
    return false;
  }

  // Don't show high scores for tutorial songs.
  if (pSong->IsTutorial() == Song::SHOW_NEVER) {
    return false;
  }

  const HighScoreList& hsl =
      bCourseMode
          ? pMachineProfile->GetCourseHighScoreList(pCourse, pTrail)
          : pMachineProfile->GetStepsHighScoreList(pSong, pSteps);

  const unsigned int iScore = scoreStats.m_iScore;
  float fPercentDP = ClampFiniteNonNegativeStageFloat(
      scoreStats.GetPercentDancePoints(), "percent dance points",
      "StageStats::PlayerHasHighScore");
  const int iMaxScores =
      std::max(0, PREFSMAN->m_iMaxHighScoresPerListForMachine.Get());
  for (int h = 0; h < static_cast<int>(hsl.vHighScores.size()) &&
                  h < iMaxScores;
       ++h) {
    const HighScore& hs = hsl.vHighScores[h];
    if (hs.GetName() == RANKING_TO_FILL_IN_MARKER[pn] &&
        std::fabs(hs.GetPercentDP() - fPercentDP) <= 0.000001f &&
        hs.GetScore() == iScore) {
      return true;
    }
  }

  return false;
}

unsigned int StageStats::GetMinimumMissCombo() const {
  unsigned int iMin = INT_MAX;
  bool bSawHumanPlayer = false;
  FOREACH_PlayerNumber(p) {
    if (!HasRecordedPlayerStats(m_player[p])) {
      continue;
    }
    bSawHumanPlayer = true;
    iMin = std::min(iMin, m_player[p].m_iCurMissCombo);
  }
  if (!bSawHumanPlayer) {
    return 0;
  }
  return iMin;
}

// lua start
#include "LuaBinding.h"

/** @brief Allow Lua to have access to the StageStats. */
class LunaStageStats : public Luna<StageStats> {
 public:
  static int GetPlayerStageStats(T* p, lua_State* L) {
    PlayerNumber pn = Enum::Check<PlayerNumber>(L, 1);
    if (!IsValidPlayerNumber(pn)) {
      lua_pushnil(L);
      return 1;
    }
    p->m_player[pn].PushSelf(L);
    return 1;
  }
  static int GetMultiPlayerStageStats(T* p, lua_State* L) {
    MultiPlayer mp = Enum::Check<MultiPlayer>(L, 1);
    if (!IsValidMultiPlayer(mp)) {
      lua_pushnil(L);
      return 1;
    }
    p->m_multiPlayer[mp].PushSelf(L);
    return 1;
  }
  static int GetPlayedSongs(T* p, lua_State* L) {
    lua_newtable(L);
    const size_t iLimit = std::min(
        p->m_vpPlayedSongs.size(),
        static_cast<size_t>(std::numeric_limits<int>::max()));
    if (iLimit != p->m_vpPlayedSongs.size()) {
      LOG->Warn(
          "SRC_AUDIT_FIX: StageStats:GetPlayedSongs truncated %zu songs for "
          "Lua.",
          p->m_vpPlayedSongs.size() - iLimit);
    }
    for (size_t i = 0; i < iLimit; ++i) {
      if (p->m_vpPlayedSongs[i] == nullptr) {
        LOG->Warn(
            "SRC_AUDIT_FIX: StageStats:GetPlayedSongs skipped null song at "
            "index %zu.",
            i);
        continue;
      }
      p->m_vpPlayedSongs[i]->PushSelf(L);
      lua_rawseti(L, -2, static_cast<int>(i + 1));
    }
    return 1;
  }
  static int GetPossibleSongs(T* p, lua_State* L) {
    lua_newtable(L);
    const size_t iLimit = std::min(
        p->m_vpPossibleSongs.size(),
        static_cast<size_t>(std::numeric_limits<int>::max()));
    if (iLimit != p->m_vpPossibleSongs.size()) {
      LOG->Warn(
          "SRC_AUDIT_FIX: StageStats:GetPossibleSongs truncated %zu songs for "
          "Lua.",
          p->m_vpPossibleSongs.size() - iLimit);
    }
    for (size_t i = 0; i < iLimit; ++i) {
      if (p->m_vpPossibleSongs[i] == nullptr) {
        LOG->Warn(
            "SRC_AUDIT_FIX: StageStats:GetPossibleSongs skipped null song at "
            "index %zu.",
            i);
        continue;
      }
      p->m_vpPossibleSongs[i]->PushSelf(L);
      lua_rawseti(L, -2, static_cast<int>(i + 1));
    }
    return 1;
  }
  static int GetGameplaySeconds(T* p, lua_State* L) {
    lua_pushnumber(
        L, ClampFiniteNonNegativeStageFloat(
               p->m_fGameplaySeconds, "gameplay seconds",
               "StageStats:GetGameplaySeconds"));
    return 1;
  }
  static int OnePassed(T* p, lua_State* L) {
    lua_pushboolean(L, p->OnePassed());
    return 1;
  }
  static int AllFailed(T* p, lua_State* L) {
    lua_pushboolean(L, p->AllFailed());
    return 1;
  }
  static int GetStage(T* p, lua_State* L) {
    LuaHelpers::Push(L, p->m_Stage);
    return 1;
  }
  DEFINE_METHOD(GetStageIndex, m_iStageIndex)
  static int GetStepsSeconds(T* p, lua_State* L) {
    lua_pushnumber(
        L, ClampFiniteNonNegativeStageFloat(
               p->m_fStepsSeconds, "steps seconds",
               "StageStats:GetStepsSeconds"));
    return 1;
  }
  static int PlayerHasHighScore(T* p, lua_State* L) {
    lua_pushboolean(L, p->PlayerHasHighScore(Enum::Check<PlayerNumber>(L, 1)));
    return 1;
  }
  DEFINE_METHOD(GetEarnedExtraStage, m_EarnedExtraStage)
  static int GaveUp(T* p, lua_State* L) {
    LuaHelpers::Push(L, p->m_bGaveUp);
    return 1;
  }
  static int GetRoutineStageStats(T* p, lua_State* L) {
    p->m_RoutinePlayer.PushSelf(L);
    return 1;
  }

  LunaStageStats() {
    ADD_METHOD(GetPlayerStageStats);
    ADD_METHOD(GetMultiPlayerStageStats);
    ADD_METHOD(GetPlayedSongs);
    ADD_METHOD(GetPossibleSongs);
    ADD_METHOD(GetGameplaySeconds);
    ADD_METHOD(OnePassed);
    ADD_METHOD(AllFailed);
    ADD_METHOD(GetStage);
    ADD_METHOD(GaveUp);
    ADD_METHOD(GetStageIndex);
    ADD_METHOD(GetStepsSeconds);
    ADD_METHOD(PlayerHasHighScore);
    ADD_METHOD(GetEarnedExtraStage);
    ADD_METHOD(GetRoutineStageStats);
  }
};

LUA_REGISTER_CLASS(StageStats)
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
