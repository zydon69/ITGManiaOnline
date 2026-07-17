#include "ScoreKeeperNormal.h"

#include <algorithm>
#include <cinttypes>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <limits>
#include <string>
#include <vector>

#include "Course.h"
#include "Difficulty.h"
#include "Game.h"
#include "GameConstantsAndTypes.h"
#include "GamePreferences.h"
#include "GameState.h"
#include "LuaManager.h"
#include "MessageManager.h"
#include "NoteData.h"
#include "NoteDataUtil.h"
#include "NoteDataWithScoring.h"
#include "NoteTypes.h"
#include "PlayerNumber.h"
#include "PlayerState.h"
#include "PrefsManager.h"
#include "ProfileManager.h"
#include "RageLog.h"
#include "RageUtil.h"
#include "ScoreKeeper.h"
#include "ScreenManager.h"
#include "Song.h"
#include "SongManager.h"
#include "StageStats.h"
#include "Steps.h"
#include "Style.h"
#include "ThemeMetric.h"
#include "ThemeManager.h"
#include "TimingData.h"
#include "TimingSegments.h"
#include "global.h"

static std::string PercentScoreWeightName(size_t i) {
  return "PercentScoreWeight" + ScoreEventToString((ScoreEvent)i);
}
static std::string GradeWeightName(size_t i) {
  return "GradeWeight" + ScoreEventToString((ScoreEvent)i);
}

static ThemeMetric1D<int> g_iPercentScoreWeight(
    "ScoreKeeperNormal", PercentScoreWeightName, NUM_ScoreEvent);
static ThemeMetric1D<int> g_iGradeWeight(
    "ScoreKeeperNormal", GradeWeightName, NUM_ScoreEvent);

namespace {
bool IsValidPlayerNumber(PlayerNumber pn) {
  return pn >= PLAYER_1 && pn < NUM_PLAYERS;
}

bool IsValidTapNoteScore(TapNoteScore tns) {
  return tns >= TNS_None && tns < NUM_TapNoteScore;
}

bool IsRegularTapNoteScore(TapNoteScore tns) {
  return tns >= TNS_Miss && tns <= TNS_W1;
}

bool IsRowTapNoteScore(TapNoteScore tns) {
  return IsRegularTapNoteScore(tns) || tns == TNS_CheckpointMiss ||
         tns == TNS_CheckpointHit;
}

bool IsValidHoldNoteScore(HoldNoteScore hns) {
  return hns >= HNS_None && hns < NUM_HoldNoteScore;
}

bool ShouldShowW1() { return GAMESTATE == nullptr || GAMESTATE->ShowW1(); }

int ClampInt64ToInt(int64_t value, const char* context) {
  if (value > std::numeric_limits<int>::max()) {
    LOG->Warn(
        "SRC_AUDIT_FIX: %s saturated integer value %" PRId64 " to INT_MAX.",
        context, value);
    return std::numeric_limits<int>::max();
  }
  if (value < std::numeric_limits<int>::min()) {
    LOG->Warn(
        "SRC_AUDIT_FIX: %s saturated integer value %" PRId64 " to INT_MIN.",
        context, value);
    return std::numeric_limits<int>::min();
  }
  return static_cast<int>(value);
}

int AddIntSaturated(int current, int delta, const char* context) {
  return ClampInt64ToInt(
      static_cast<int64_t>(current) + static_cast<int64_t>(delta), context);
}

int AddDancePointsClampedNonNegative(
    int current, int delta, const char* context) {
  const int value = AddIntSaturated(current, delta, context);
  if (value < 0) {
    return 0;
  }
  return value;
}

int AddNonNegativeIntSaturated(int current, int delta, const char* context) {
  int value =
      AddIntSaturated(std::max(0, current), std::max(0, delta), context);
  if (value < 0) {
    LOG->Warn(
        "SRC_AUDIT_FIX: %s clamped negative saturated result %i to 0.", context,
        value);
    return 0;
  }
  return value;
}

unsigned int AddUnsignedDeltaSaturated(
    unsigned int current, int64_t delta, const char* context) {
  const int64_t value = static_cast<int64_t>(current) + delta;
  if (value < 0) {
    LOG->Warn(
        "SRC_AUDIT_FIX: %s clamped unsigned score delta %" PRId64 " below 0.",
        context, delta);
    return 0;
  }
  if (value > std::numeric_limits<unsigned int>::max()) {
    LOG->Warn(
        "SRC_AUDIT_FIX: %s saturated unsigned score value %" PRId64 ".",
        context, value);
    return std::numeric_limits<unsigned int>::max();
  }
  return static_cast<unsigned int>(value);
}

int MulIntSaturated(int lhs, int rhs, const char* context) {
  return ClampInt64ToInt(
      static_cast<int64_t>(lhs) * static_cast<int64_t>(rhs), context);
}

int RadarValueToNonNegativeInt(float value, const char* context) {
  if (!std::isfinite(value) || value <= 0.0f) {
    if (!std::isfinite(value) || value < 0.0f) {
      LOG->Warn(
          "SRC_AUDIT_FIX: %s ignored invalid radar value %f.", context, value);
    }
    return 0;
  }
  // INT_MAX rounds to 2147483648 as a float, which is already outside the
  // representable int range.  Keep the comparison inclusive before casting.
  if (value >= static_cast<float>(std::numeric_limits<int>::max())) {
    LOG->Warn(
        "SRC_AUDIT_FIX: %s saturated radar value %f to INT_MAX.", context,
        value);
    return std::numeric_limits<int>::max();
  }
  return static_cast<int>(value);
}

int UnsignedToIntSaturated(unsigned int value, const char* context) {
  if (value > static_cast<unsigned int>(std::numeric_limits<int>::max())) {
    LOG->Warn(
        "SRC_AUDIT_FIX: %s saturated unsigned value %u to INT_MAX.", context,
        value);
    return std::numeric_limits<int>::max();
  }
  return static_cast<int>(value);
}

int ClampScoreWeight(int weight, const char* context) {
  static const int kMaxReasonableWeight = 1000000;
  if (weight > kMaxReasonableWeight) {
    LOG->Warn(
        "SRC_AUDIT_FIX: %s clamped extreme score weight %i to %i.", context,
        weight, kMaxReasonableWeight);
    return kMaxReasonableWeight;
  }
  if (weight < -kMaxReasonableWeight) {
    LOG->Warn(
        "SRC_AUDIT_FIX: %s clamped extreme score weight %i to -%i.", context,
        weight, kMaxReasonableWeight);
    return -kMaxReasonableWeight;
  }
  return weight;
}

int ClampComboInput(int count, const char* context) {
  if (count < 0) {
    LOG->Warn(
        "SRC_AUDIT_FIX: %s clamped negative combo count %i to 0.", context,
        count);
    return 0;
  }
  return count;
}

bool IsValidScoreRow(int row) { return row >= 0 && row <= MAX_NOTE_ROW; }

void BroadcastScoreKeeperMessage(Message& msg, const char* context) {
  if (MESSAGEMAN == nullptr) {
    LOG->Warn(
        "SRC_AUDIT_FIX: %s skipped message broadcast without MESSAGEMAN.",
        context);
    return;
  }
  MESSAGEMAN->Broadcast(msg);
}

void BroadcastScoreKeeperMessage(MessageID msg, const char* context) {
  if (MESSAGEMAN == nullptr) {
    LOG->Warn(
        "SRC_AUDIT_FIX: %s skipped message broadcast without MESSAGEMAN.",
        context);
    return;
  }
  MESSAGEMAN->Broadcast(msg);
}

TapNoteScore ClampTapMetric(
    TapNoteScore score, TapNoteScore fallback, const char* context) {
  if (IsRegularTapNoteScore(score)) {
    return score;
  }
  LOG->Warn(
      "SRC_AUDIT_FIX: %s used fallback tap score metric %i for invalid %i.",
      context, fallback, score);
  return fallback;
}

TimingData* GetCurrentTimingDataForPlayer(PlayerNumber pn) {
  if (GAMESTATE == nullptr) {
    LOG->Warn(
        "SRC_AUDIT_FIX: ScoreKeeperNormal missing timing data because "
        "GAMESTATE is null.");
    return nullptr;
  }
  if (!IsValidPlayerNumber(pn)) {
    LOG->Warn(
        "SRC_AUDIT_FIX: ScoreKeeperNormal missing timing data for invalid "
        "player %i.",
        pn);
    return nullptr;
  }

  Steps* pSteps = GAMESTATE->m_pCurSteps[pn];
  if (pSteps == nullptr || pSteps->GetTimingData() == nullptr) {
    LOG->Warn(
        "SRC_AUDIT_FIX: ScoreKeeperNormal missing current timing data for "
        "player %i.",
        pn);
    return nullptr;
  }
  return pSteps->GetTimingData();
}

int GetComboMultiplier(
    TimingData* pTiming, int iRow, bool bMissComboMultiplier) {
  if (pTiming == nullptr || iRow == -1) {
    return 1;
  }
  if (!IsValidScoreRow(iRow)) {
    LOG->Warn(
        "SRC_AUDIT_FIX: ScoreKeeperNormal ignored combo multiplier for "
        "invalid row %i.",
        iRow);
    return 1;
  }

  ComboSegment* cs = pTiming->GetComboSegmentAtRow(iRow);
  if (cs == nullptr) {
    LOG->Warn(
        "SRC_AUDIT_FIX: ScoreKeeperNormal missing combo segment at row %i; "
        "using multiplier 1.",
        iRow);
    return 1;
  }

  int multiplier = bMissComboMultiplier ? cs->GetMissCombo() : cs->GetCombo();
  if (multiplier <= 0) {
    LOG->Warn(
        "SRC_AUDIT_FIX: ScoreKeeperNormal clamped invalid combo multiplier %i "
        "at row %i to 1.",
        multiplier, iRow);
    return 1;
  }
  static const int kMaxComboMultiplier = 1000;
  if (multiplier > kMaxComboMultiplier) {
    LOG->Warn(
        "SRC_AUDIT_FIX: ScoreKeeperNormal clamped huge combo multiplier %i at "
        "row %i to %i.",
        multiplier, iRow, kMaxComboMultiplier);
    return kMaxComboMultiplier;
  }
  return multiplier;
}
}  // namespace

ScoreKeeperNormal::ScoreKeeperNormal(
    PlayerState* pPlayerState, PlayerStageStats* pPlayerStageStats)
    : ScoreKeeper(pPlayerState, pPlayerStageStats),
      m_iScoreRemainder(0),
      m_iMaxPossiblePoints(0),
      m_iTapNotesHit(0),
      m_iNumTapsAndHolds(0),
      m_iMaxScoreSoFar(0),
      m_iPointBonus(0),
      m_cur_toasty_combo(0),
      m_cur_toasty_level(0),
      m_next_toasty_at(250),
      m_bIsLastSongInCourse(false),
      m_bIsBeginner(false),
      m_iNumNotesHitThisRow(0),
      m_iRoundTo(1) {
  memset(m_ComboBonusFactor, 0, sizeof(m_ComboBonusFactor));
}

void ScoreKeeperNormal::Load(
    const std::vector<Song*>& apSongs, const std::vector<Steps*>& apSteps,
    const std::vector<AttackArray>& asModifiers) {
  if (!HasScoringState("ScoreKeeperNormal::Load")) {
    return;
  }

  // Load can be called again on the same scorekeeper.  Clear every value that
  // depends on the previous chart before validating the replacement so that a
  // rejected load cannot retain stale scoring state.
  m_apSteps.clear();
  m_pPlayerStageStats->m_iPossibleDancePoints = 0;
  m_pPlayerStageStats->m_iPossibleGradePoints = 0;
  m_iScoreRemainder = 0;
  m_iMaxPossiblePoints = 0;
  m_iTapNotesHit = 0;
  m_iNumTapsAndHolds = 0;
  m_iMaxScoreSoFar = 0;
  m_iPointBonus = 0;
  m_cur_toasty_combo = 0;
  m_cur_toasty_level = 0;
  m_next_toasty_at = 250;
  m_bIsLastSongInCourse = false;
  m_bIsBeginner = false;
  m_iNumNotesHitThisRow = 0;
  m_iRoundTo = 1;
  memset(m_ComboBonusFactor, 0, sizeof(m_ComboBonusFactor));

  if (GAMESTATE == nullptr ||
      !IsValidPlayerNumber(m_pPlayerState->m_PlayerNumber)) {
    LOG->Warn(
        "SRC_AUDIT_FIX SRC-2051: ScoreKeeperNormal::Load aborted with "
        "GAMESTATE=%p player=%i.",
        static_cast<void*>(GAMESTATE), m_pPlayerState->m_PlayerNumber);
    return;
  }
  if (THEME == nullptr || !THEME->IsThemeLoaded() || LUA == nullptr) {
    LOG->Warn(
        "SRC_AUDIT_FIX: ScoreKeeperNormal::Load aborted without theme/Lua "
        "runtime.");
    return;
  }

  if (apSongs.size() != apSteps.size() ||
      apSongs.size() != asModifiers.size()) {
    LOG->Warn(
        "SRC_AUDIT_FIX: ScoreKeeperNormal::Load rejected mismatched course "
        "vectors: songs=%zu steps=%zu modifiers=%zu.",
        apSongs.size(), apSteps.size(), asModifiers.size());
    return;
  }

  const Style* pStyle =
      GAMESTATE->GetCurrentStyle(m_pPlayerState->m_PlayerNumber);
  if (pStyle == nullptr && !apSongs.empty()) {
    LOG->Warn(
        "SRC_AUDIT_FIX: ScoreKeeperNormal::Load rejected charts because no "
        "current style was available for player %i.",
        m_pPlayerState->m_PlayerNumber);
    return;
  }
  for (size_t i = 0; i < apSongs.size(); ++i) {
    if (apSongs[i] == nullptr || apSteps[i] == nullptr ||
        apSteps[i]->m_pSong != apSongs[i] ||
        apSteps[i]->GetTimingData() == nullptr) {
      LOG->Warn(
          "SRC_AUDIT_FIX: ScoreKeeperNormal::Load rejected invalid entry %zu: "
          "song=%p steps=%p steps_song=%p timing=%p.",
          i, static_cast<void*>(apSongs[i]), static_cast<void*>(apSteps[i]),
          apSteps[i] == nullptr ? nullptr
                                : static_cast<void*>(apSteps[i]->m_pSong),
          apSteps[i] == nullptr
              ? nullptr
              : static_cast<void*>(apSteps[i]->GetTimingData()));
      return;
    }
  }

  // True if a jump is one to combo, false if combo is purely based on tap
  // count.
  m_ComboIsPerRow.Load("Gameplay", "ComboIsPerRow");
  m_MissComboIsPerRow.Load("Gameplay", "MissComboIsPerRow");
  m_MinScoreToContinueCombo.Load("Gameplay", "MinScoreToContinueCombo");
  m_MinScoreToMaintainCombo.Load("Gameplay", "MinScoreToMaintainCombo");
  m_MaxScoreToIncrementMissCombo.Load(
      "Gameplay", "MaxScoreToIncrementMissCombo");
  m_MineHitIncrementsMissCombo.Load("Gameplay", "MineHitIncrementsMissCombo");
  m_AvoidMineIncrementsCombo.Load("Gameplay", "AvoidMineIncrementsCombo");
  m_UseInternalScoring.Load("Gameplay", "UseInternalScoring");

  // This can be a function or a number, the type is checked when needed.
  // -Kyz
  m_toasty_trigger.Load("Gameplay", "ToastyTriggersAt");
  m_toasty_min_tns.Load("Gameplay", "ToastyMinTNS");

  // Fill in STATSMAN->m_CurStageStats, calculate multiplier
  int iTotalPossibleDancePoints = 0;
  int iTotalPossibleGradePoints = 0;
  for (size_t i = 0; i < apSongs.size(); i++) {
    Song* pSong = apSongs[i];
    Steps* pSteps = apSteps[i];
    const TimingData* pTiming = pSteps->GetTimingData();
    const AttackArray& aa = asModifiers[i];
    NoteData ndTemp;
    pSteps->GetNoteData(ndTemp);

    // We might have been given lots of songs; don't keep them in memory
    // uncompressed.
    pSteps->Compress();

    NoteData ndPre;
    pStyle->GetTransformedNoteDataForStyle(
        m_pPlayerState->m_PlayerNumber, ndTemp, ndPre);

    /* Compute RadarValues before applying any user-selected mods. Apply
     * Course mods and count them in the "pre" RadarValues because they're
     * forced and not chosen by the user. */
    NoteDataUtil::TransformNoteData(
        ndPre, *pTiming, aa, pSteps->m_StepsType, pSong);

    /* Apply user transforms to find out how the notes will really look.
     *
     * XXX: This is brittle: if we end up combining mods for a song differently
     * than ScreenGameplay, we'll end up with the wrong data.  We should
     * probably have eg. GAMESTATE->GetOptionsForCourse(po,so,pn) to get options
     * based on the last call to StoreSelectedOptions and the modifiers list,
     * but that'd mean moving the queues in ScreenGameplay to GameState ... */
    NoteData ndPost = ndPre;
    NoteDataUtil::TransformNoteData(
        ndPost, *pTiming, m_pPlayerState->m_PlayerOptions.GetStage(),
        pSteps->m_StepsType);

    iTotalPossibleDancePoints = AddNonNegativeIntSaturated(
        iTotalPossibleDancePoints,
        this->GetPossibleDancePoints(
            &ndPre, &ndPost, pTiming, pSong->m_fMusicLengthSeconds),
        "ScoreKeeperNormal::Load possible dance points");
    iTotalPossibleGradePoints = AddNonNegativeIntSaturated(
        iTotalPossibleGradePoints,
        this->GetPossibleGradePoints(
            &ndPre, &ndPost, pTiming, pSong->m_fMusicLengthSeconds),
        "ScoreKeeperNormal::Load possible grade points");
    m_apSteps.push_back(pSteps);
  }

  m_pPlayerStageStats->m_iPossibleDancePoints = iTotalPossibleDancePoints;
  m_pPlayerStageStats->m_iPossibleGradePoints = iTotalPossibleGradePoints;

  // Initialize m_next_toasty_at to 0 so that CalcNextToastyAt just needs to
  // add the value. -Kyz
  m_next_toasty_at = 0;
  m_next_toasty_at = CalcNextToastyAt(m_cur_toasty_level);

  Message msg("ScoreChanged");
  msg.SetParam("PlayerNumber", m_pPlayerState->m_PlayerNumber);
  msg.SetParam("MultiPlayer", m_pPlayerState->m_mp);
  BroadcastScoreKeeperMessage(msg, "ScoreKeeperNormal::Load");
}

void ScoreKeeperNormal::OnNextSong(
    int iSongInCourseIndex, const Steps* pSteps, const NoteData* pNoteData) {
  if (!HasScoringState("ScoreKeeperNormal::OnNextSong")) {
    return;
  }
  if (pSteps == nullptr || pNoteData == nullptr ||
      pSteps->GetTimingData() == nullptr) {
    LOG->Warn(
        "SRC_AUDIT_FIX: ScoreKeeperNormal::OnNextSong ignored invalid input: "
        "steps=%p notedata=%p timing=%p.",
        static_cast<const void*>(pSteps), static_cast<const void*>(pNoteData),
        pSteps == nullptr ? nullptr
                          : static_cast<const void*>(pSteps->GetTimingData()));
    m_iMaxPossiblePoints = 0;
    m_iNumTapsAndHolds = 0;
    m_iPointBonus = 0;
    return;
  }

  /*
    Note on NONSTOP Mode scoring

    Nonstop mode requires the player to play 4 songs in succession, with the
    total maximum possible score for the four song set being 100,000,000. This
    comes from the sum of the four stages' maximum possible scores, which,
    regardless of song or difficulty is:

    10,000,000 for the first song
    20,000,000 for the second song
    30,000,000 for the third song
    40,000,000 for the fourth song

    We extend this to work with nonstop courses of any length.

    We also keep track of this scoring type in endless, with 100mil per
    iteration of all songs, though this score isn't actually seen anywhere right
    now.
  */
  // Calculate the score multiplier
  m_iMaxPossiblePoints = 0;
  const bool isCourseMode = GAMESTATE != nullptr && GAMESTATE->IsCourseMode();
  if (isCourseMode) {
    if (iSongInCourseIndex < 0) {
      LOG->Warn(
          "SRC_AUDIT_FIX: ScoreKeeperNormal::OnNextSong rejected negative "
          "course index %i.",
          iSongInCourseIndex);
      m_iPointBonus = 0;
      m_iNumTapsAndHolds = 0;
      return;
    }
    if (m_apSteps.empty() ||
        m_apSteps.size() >
            static_cast<size_t>(std::numeric_limits<int>::max())) {
      LOG->Warn(
          "SRC_AUDIT_FIX: ScoreKeeperNormal::OnNextSong ignored invalid "
          "course scoring size %zu.",
          m_apSteps.size());
      m_iPointBonus = 0;
      m_iNumTapsAndHolds = 0;
      return;
    }

    const int numSongsInCourse = static_cast<int>(m_apSteps.size());
    const int iIndex = iSongInCourseIndex % numSongsInCourse;
    if (m_apSteps[iIndex] != pSteps) {
      LOG->Warn(
          "SRC_AUDIT_FIX: ScoreKeeperNormal::OnNextSong rejected course "
          "steps mismatch at index %i: expected=%p actual=%p.",
          iIndex, static_cast<void*>(m_apSteps[iIndex]),
          static_cast<const void*>(pSteps));
      m_iPointBonus = 0;
      m_iNumTapsAndHolds = 0;
      return;
    }
    m_bIsLastSongInCourse = (iIndex + 1 == numSongsInCourse);

    if (numSongsInCourse < 10) {
      const int courseMult = MulIntSaturated(
          numSongsInCourse, numSongsInCourse + 1,
          "ScoreKeeperNormal::OnNextSong course multiplier");
      const int divisor = std::max(1, courseMult / 2);

      m_iMaxPossiblePoints = ClampInt64ToInt(
          (static_cast<int64_t>(100000000) * (iIndex + 1)) / divisor,
          "ScoreKeeperNormal::OnNextSong max possible course points");
    } else {
      /* When we have lots of songs, the scale above biases too much: in a
       * course with 50 songs, the first song is worth 80k, the last 4mil, which
       * is too much of a difference.
       *
       * With this, each song in a 50-song course will be worth 2mil. */
      m_iMaxPossiblePoints = 100000000 / numSongsInCourse;
    }
  } else {
    // long ver and marathon ver songs have higher max possible scores
    const Song* pSong = pSteps->m_pSong;
    if (pSong == nullptr && GAMESTATE != nullptr) {
      pSong = GAMESTATE->m_pCurSong;
    }
    int iLengthMultiplier = 1;
    if (pSong != nullptr) {
      iLengthMultiplier = GameState::GetNumStagesMultiplierForSong(pSong);
    } else {
      LOG->Warn(
          "SRC_AUDIT_FIX: ScoreKeeperNormal::OnNextSong used length "
          "multiplier 1 because no song was available.");
    }
    iLengthMultiplier = std::max(1, iLengthMultiplier);

    /* This is no longer just simple additive/subtractive scoring,
     * but start with capping the score at the size of the score counter. */
    m_iMaxPossiblePoints = ClampInt64ToInt(
        static_cast<int64_t>(10) * 10000000 * iLengthMultiplier,
        "ScoreKeeperNormal::OnNextSong max possible points");
  }
  m_iMaxPossiblePoints = std::max(0, m_iMaxPossiblePoints);
  m_iMaxScoreSoFar = AddNonNegativeIntSaturated(
      m_iMaxScoreSoFar, m_iMaxPossiblePoints,
      "ScoreKeeperNormal::OnNextSong max score so far");

  const TimingData* scoringTiming = pSteps->GetTimingData();
  m_iNumTapsAndHolds = AddNonNegativeIntSaturated(
      pNoteData->GetNumRowsWithTapOrHoldHead(0, MAX_NOTE_ROW, scoringTiming),
      AddNonNegativeIntSaturated(
          pNoteData->GetNumHoldNotes(0, MAX_NOTE_ROW, scoringTiming),
          pNoteData->GetNumRolls(0, MAX_NOTE_ROW, scoringTiming),
          "ScoreKeeperNormal::OnNextSong hold totals"),
      "ScoreKeeperNormal::OnNextSong tap/hold totals");

  m_iPointBonus = m_iMaxPossiblePoints;
  m_pPlayerStageStats->m_iMaxScore =
      static_cast<unsigned int>(std::max(0, m_iMaxScoreSoFar));

  /* MercifulBeginner shouldn't clamp weights in course mode, even if a beginner
   * song is in a course, since that makes PlayerStageStats::GetGrade hard. */
  m_bIsBeginner =
      pSteps->GetDifficulty() == Difficulty_Beginner && !isCourseMode;

  if (m_iPointBonus < 0) {
    LOG->Warn(
        "SRC_AUDIT_FIX: ScoreKeeperNormal clamped negative point bonus %i.",
        m_iPointBonus);
    m_iPointBonus = 0;
  }

  m_iTapNotesHit = 0;
}

static int GetScore(int p, int Z, int64_t S, int n) {
  if (S <= 0 || n <= 0 || Z <= 0 || p <= 0) {
    return 0;
  }
  /* There's a problem with the scoring system described below. Z/S is truncated
   * to an int. However, in some cases we can end up with very small base
   * scores. Each song in a 50-song nonstop course will be worth 2mil, which is
   * a base of 200k; Z/S will end up being zero.
   *
   * If we rearrange the equation to (p*Z*n) / S, this problem goes away.
   * (To do that, we need to either use 64-bit ints or rearrange it a little
   * more and use floats, since p*Z*n won't fit a 32-bit int.)  However, this
   * changes the scoring rules slightly.
   */

#if 0
	// This is the actual method described below.
	return p * (Z / S) * n;
#elif 1
  // This doesn't round down Z/S.
  return ClampInt64ToInt(int64_t(p) * n * Z / S, "ScoreKeeperNormal::GetScore");
#else
  // This also doesn't round down Z/S. Use this if you don't have 64-bit ints.
  return int(p * n * (float(Z) / S));
#endif
}

void ScoreKeeperNormal::AddTapScore(TapNoteScore tns) {}

void ScoreKeeperNormal::AddHoldScore(HoldNoteScore hns) {
  if (hns == HNS_Held) {
    AddScoreInternal(TNS_W1);
  } else if (hns == HNS_LetGo) {
    AddScoreInternal(
        TNS_W4);  // required for subtractive score display to work properly.
  }
}

void ScoreKeeperNormal::AddTapRowScore(
    TapNoteScore score, const NoteData& nd, int iRow) {
  AddScoreInternal(score);
}

extern ThemeMetric<bool> PENALIZE_TAP_SCORE_NONE;
extern ThemeMetric<bool> TICK_HOLDS;
void ScoreKeeperNormal::HandleTapScoreNone() {
  if (!HasScoringState("ScoreKeeperNormal::HandleTapScoreNone")) {
    return;
  }
  if (PENALIZE_TAP_SCORE_NONE) {
    m_pPlayerStageStats->m_iCurCombo = 0;

    if (IsValidPlayerNumber(m_pPlayerState->m_PlayerNumber)) {
      BroadcastScoreKeeperMessage(
          enum_add2(
              Message_CurrentComboChangedP1, m_pPlayerState->m_PlayerNumber),
          "ScoreKeeperNormal::HandleTapScoreNone");
    }
  }

  // TODO: networking code
}

void ScoreKeeperNormal::AddScoreInternal(TapNoteScore score) {
  if (!HasScoringState("ScoreKeeperNormal::AddScoreInternal")) {
    return;
  }
  if (m_UseInternalScoring) {
    if (!IsRegularTapNoteScore(score)) {
      LOG->Warn(
          "SRC_AUDIT_FIX: ScoreKeeperNormal ignored non-regular tap score %i "
          "in "
          "internal scoring.",
          score);
      return;
    }
    if (m_iNumTapsAndHolds <= 0) {
      LOG->Warn(
          "SRC_AUDIT_FIX: ScoreKeeperNormal skipped internal scoring because "
          "there are no scorable taps or holds.");
      return;
    }
    if (m_iTapNotesHit >= m_iNumTapsAndHolds) {
      LOG->Warn(
          "SRC_AUDIT_FIX: ScoreKeeperNormal ignored excess internal scoring "
          "callback %i/%i.",
          m_iTapNotesHit + 1, m_iNumTapsAndHolds);
      return;
    }

    unsigned int& iScore = m_pPlayerStageStats->m_iScore;
    unsigned int& iCurMaxScore = m_pPlayerStageStats->m_iCurMaxScore;

    // See Aaron In Japan for more details about the scoring formulas.
    // Note: this assumes no custom scoring systems are in use.
    int p = 0;  // score multiplier

    switch (score) {
      case TNS_W1:
        p = 10;
        break;
      case TNS_W2:
        p = ShouldShowW1() ? 9 : 10;
        break;
      case TNS_W3:
        p = 5;
        break;
      default:
        p = 0;
        break;
    }

    m_iTapNotesHit = AddNonNegativeIntSaturated(
        m_iTapNotesHit, 1, "ScoreKeeperNormal::AddScoreInternal tap count");

    const int64_t N = uint64_t(m_iNumTapsAndHolds);
    const int64_t sum = (N * (N + 1)) / 2;
    const int Z = m_iMaxPossiblePoints / 10;

    // Don't use a multiplier if the player has failed
    if (m_pPlayerStageStats->m_bFailed) {
      iScore = AddUnsignedDeltaSaturated(
          iScore, p, "ScoreKeeperNormal::AddScoreInternal failed score");
      // make score evenly divisible by 5
      // only update this on the next step, to make it less *obvious*
      /* Round to the nearest 5, instead of always rounding down, so a base
       * score of 9 will round to 10, not 5. */
      if (p > 0) {
        const uint64_t rounded =
            ((static_cast<uint64_t>(iScore) + 2U) / 5U) * 5U;
        iScore = static_cast<unsigned int>(std::min<uint64_t>(
            rounded, std::numeric_limits<unsigned int>::max()));
      }
    } else {
      iScore = AddUnsignedDeltaSaturated(
          iScore, GetScore(p, Z, sum, m_iTapNotesHit),
          "ScoreKeeperNormal::AddScoreInternal tap score");
      const unsigned int iCurrentCombo = m_pPlayerStageStats->m_iCurCombo;
      iScore = AddUnsignedDeltaSaturated(
          iScore,
          static_cast<int64_t>(m_ComboBonusFactor[score]) * iCurrentCombo,
          "ScoreKeeperNormal::AddScoreInternal combo bonus");
    }

    // Subtract the maximum this step could have been worth from the bonus.
    m_iPointBonus = AddIntSaturated(
        m_iPointBonus, -GetScore(10, Z, sum, m_iTapNotesHit),
        "ScoreKeeperNormal::AddScoreInternal point bonus");
    // And add the maximum this step could have been worth to the max score up
    // to now.
    iCurMaxScore = AddUnsignedDeltaSaturated(
        iCurMaxScore, GetScore(10, Z, sum, m_iTapNotesHit),
        "ScoreKeeperNormal::AddScoreInternal current max score");

    if (m_iTapNotesHit == m_iNumTapsAndHolds && score >= TNS_W2) {
      if (!m_pPlayerStageStats->m_bFailed) {
        iScore = AddUnsignedDeltaSaturated(
            iScore, m_iPointBonus,
            "ScoreKeeperNormal::AddScoreInternal final point bonus");
      }
      if (m_bIsLastSongInCourse) {
        const int finalCourseBonus = std::max(
            0, AddIntSaturated(
                   100000000, -m_iMaxScoreSoFar,
                   "ScoreKeeperNormal::AddScoreInternal course bonus"));
        iScore = AddUnsignedDeltaSaturated(
            iScore, finalCourseBonus,
            "ScoreKeeperNormal::AddScoreInternal final course score");
        iCurMaxScore = AddUnsignedDeltaSaturated(
            iCurMaxScore, finalCourseBonus,
            "ScoreKeeperNormal::AddScoreInternal final course max score");

        /* If we're in Endless mode, we'll come around here again, so reset
         * the bonus counter. */
        m_iMaxScoreSoFar = 0;
      }
      iCurMaxScore = AddUnsignedDeltaSaturated(
          iCurMaxScore, m_iPointBonus,
          "ScoreKeeperNormal::AddScoreInternal final current max bonus");
    }

    // Undo rounding from the last tap, and re-round.
    iScore = AddUnsignedDeltaSaturated(
        iScore, m_iScoreRemainder,
        "ScoreKeeperNormal::AddScoreInternal score remainder");
    if (m_iRoundTo <= 0) {
      LOG->Warn(
          "SRC_AUDIT_FIX: ScoreKeeperNormal reset invalid round-to value %i "
          "to 1.",
          m_iRoundTo);
      m_iRoundTo = 1;
    }
    m_iScoreRemainder = (iScore % m_iRoundTo);
    iScore = AddUnsignedDeltaSaturated(
        iScore, -m_iScoreRemainder,
        "ScoreKeeperNormal::AddScoreInternal score rounding");

    // LOG->Trace( "score: %i", iScore );
  }
}

int ScoreKeeperNormal::CalcNextToastyAt(int level) {
  if (!HasScoringState("ScoreKeeperNormal::CalcNextToastyAt")) {
    return 250;
  }
  const int default_amount = 250;
  if (level < 0) {
    LOG->Warn(
        "SRC_AUDIT_FIX: ScoreKeeperNormal::CalcNextToastyAt normalized "
        "negative level %i to 0.",
        level);
    level = 0;
  }
  if (LUA == nullptr) {
    LOG->Warn(
        "SRC_AUDIT_FIX SRC-2054: ScoreKeeperNormal used default Toasty "
        "threshold without Lua.");
    return AddNonNegativeIntSaturated(
        m_next_toasty_at, default_amount,
        "ScoreKeeperNormal::CalcNextToastyAt default");
  }
  Lua* L = LUA->Get();
  m_toasty_trigger.PushSelf(L);
  int amount = default_amount;
  bool erred = false;
  switch (lua_type(L, 1)) {
    case LUA_TNUMBER: {
      const double value = lua_tonumber(L, 1);
      if (!std::isfinite(value) || value <= 0.0 ||
          value >= static_cast<double>(std::numeric_limits<int>::max())) {
        erred = true;
      } else {
        amount = static_cast<int>(value);
      }
    } break;
    case LUA_TFUNCTION: {
      std::string err = "Error running ToastyTriggersAt: ";
      LuaHelpers::Push(L, m_pPlayerState->m_PlayerNumber);
      lua_pushnumber(L, level);
      if (LuaHelpers::RunScriptOnStack(L, err, 2, 1, true)) {
        if (lua_isnumber(L, -1)) {
          const double value = lua_tonumber(L, -1);
          if (!std::isfinite(value) || value <= 0.0 ||
              value >= static_cast<double>(std::numeric_limits<int>::max())) {
            erred = true;
          } else {
            amount = static_cast<int>(value);
          }
        } else {
          LuaHelpers::ReportScriptError(
              "Gameplay::ToastyTriggersAt "
              "function must return a number greater than 0.");
          erred = true;
        }
      } else {
        erred = true;
      }
    } break;
    default:
      LuaHelpers::ReportScriptError(
          "Gameplay::ToastyTriggersAt metric has "
          "a nonsensical type, it must be a number or a function.");
      erred = true;
      break;
  }
  if (erred) {
    LOG->Warn(
        "SRC_AUDIT_FIX: ScoreKeeperNormal::CalcNextToastyAt used default "
        "threshold %i after an invalid metric result.",
        default_amount);
    amount = default_amount;
  }
  if (amount <= 0) {
    if (!erred) {
      LuaHelpers::ReportScriptError(
          "The ToastyTriggersAt value cannot be "
          "less than or equal to 0 because that would be silly.");
    }
    amount = default_amount;
  }
  lua_settop(L, 0);
  LUA->Release(L);
  return AddNonNegativeIntSaturated(
      m_next_toasty_at, amount, "ScoreKeeperNormal::CalcNextToastyAt");
}

void ScoreKeeperNormal::HandleTapScore(const TapNote& tn) {
  if (!HasScoringState("ScoreKeeperNormal::HandleTapScore")) {
    return;
  }
  TapNoteScore tns = tn.result.tns;

  if (tn.type == TapNoteType_Mine) {
    if (!IsValidTapNoteScore(tns)) {
      LOG->Warn(
          "SRC_AUDIT_FIX: ScoreKeeperNormal ignored mine with invalid tap "
          "score %i.",
          tns);
      return;
    }
    if (tns == TNS_HitMine) {
      if (!m_pPlayerStageStats->m_bFailed) {
        m_pPlayerStageStats->m_iActualDancePoints =
            AddDancePointsClampedNonNegative(
                m_pPlayerStageStats->m_iActualDancePoints,
                TapNoteScoreToDancePoints(TNS_HitMine),
                "ScoreKeeperNormal::HandleTapScore actual dance points");
      }
      m_pPlayerStageStats->m_iTapNoteScores[TNS_HitMine] =
          AddNonNegativeIntSaturated(
              m_pPlayerStageStats->m_iTapNoteScores[TNS_HitMine], 1,
              "ScoreKeeperNormal::HandleTapScore mine tap count");
      if (m_MineHitIncrementsMissCombo) {
        HandleComboInternal(0, 0, 1);
      }
    }

    if (tns == TNS_AvoidMine && m_AvoidMineIncrementsCombo) {
      HandleComboInternal(1, 0, 0);
    }

    Message msg("ScoreChanged");
    msg.SetParam("PlayerNumber", m_pPlayerState->m_PlayerNumber);
    msg.SetParam("MultiPlayer", m_pPlayerState->m_mp);
    BroadcastScoreKeeperMessage(msg, "ScoreKeeperNormal::HandleTapScore");
  }

  AddTapScore(tns);
}

void ScoreKeeperNormal::HandleHoldCheckpointScore(
    const NoteData& nd, int iRow, int iNumHoldsHeldThisRow,
    int iNumHoldsMissedThisRow) {
  if (!HasScoringState("ScoreKeeperNormal::HandleHoldCheckpointScore")) {
    return;
  }
  if (!IsValidScoreRow(iRow)) {
    LOG->Warn(
        "SRC_AUDIT_FIX SRC-2057: ScoreKeeperNormal ignored checkpoint score "
        "for invalid row %i.",
        iRow);
    return;
  }
  if (iNumHoldsHeldThisRow < 0 || iNumHoldsMissedThisRow < 0) {
    LOG->Warn(
        "SRC_AUDIT_FIX: ScoreKeeperNormal::HandleHoldCheckpointScore rejected "
        "negative counts held=%i missed=%i.",
        iNumHoldsHeldThisRow, iNumHoldsMissedThisRow);
    return;
  }
  HandleTapNoteScoreInternal(
      iNumHoldsMissedThisRow == 0 ? TNS_CheckpointHit : TNS_CheckpointMiss,
      TNS_CheckpointHit, iRow);
  HandleComboInternal(iNumHoldsHeldThisRow, 0, iNumHoldsMissedThisRow, iRow);
}

void ScoreKeeperNormal::HandleTapNoteScoreInternal(
    TapNoteScore tns, TapNoteScore maximum, int row) {
  if (!HasScoringState("ScoreKeeperNormal::HandleTapNoteScoreInternal")) {
    return;
  }
  if (!IsRowTapNoteScore(tns) || !IsRowTapNoteScore(maximum)) {
    LOG->Warn(
        "SRC_AUDIT_FIX: ScoreKeeperNormal ignored invalid tap score %i "
        "maximum %i.",
        tns, maximum);
    return;
  }

  // Update dance points.
  if (!m_pPlayerStageStats->m_bFailed) {
    m_pPlayerStageStats
        ->m_iActualDancePoints = AddDancePointsClampedNonNegative(
        m_pPlayerStageStats->m_iActualDancePoints,
        TapNoteScoreToDancePoints(tns),
        "ScoreKeeperNormal::HandleTapNoteScoreInternal actual dance points");
  }

  // update judged row totals. Respect Combo segments here.
  TimingData* pTiming =
      GetCurrentTimingDataForPlayer(m_pPlayerState->m_PlayerNumber);
  const TapNoteScore minContinue = ClampTapMetric(
      m_MinScoreToContinueCombo, TNS_W3,
      "ScoreKeeperNormal::HandleTapNoteScoreInternal continue threshold");
  const TapNoteScore minMaintain = ClampTapMetric(
      m_MinScoreToMaintainCombo, TNS_W4,
      "ScoreKeeperNormal::HandleTapNoteScoreInternal maintain threshold");
  if (tns == TNS_CheckpointHit || tns >= minContinue) {
    m_pPlayerStageStats->m_iTapNoteScores[tns] = AddNonNegativeIntSaturated(
        m_pPlayerStageStats->m_iTapNoteScores[tns],
        GetComboMultiplier(pTiming, row, false),
        "ScoreKeeperNormal::HandleTapNoteScoreInternal tap count");
  } else if (tns == TNS_CheckpointMiss || tns < minMaintain) {
    m_pPlayerStageStats->m_iTapNoteScores[tns] = AddNonNegativeIntSaturated(
        m_pPlayerStageStats->m_iTapNoteScores[tns],
        GetComboMultiplier(pTiming, row, true),
        "ScoreKeeperNormal::HandleTapNoteScoreInternal tap count");
  } else {
    m_pPlayerStageStats->m_iTapNoteScores[tns] = AddNonNegativeIntSaturated(
        m_pPlayerStageStats->m_iTapNoteScores[tns], 1,
        "ScoreKeeperNormal::HandleTapNoteScoreInternal tap count");
  }

  // increment the current total possible dance score
  m_pPlayerStageStats->m_iCurPossibleDancePoints = AddNonNegativeIntSaturated(
      m_pPlayerStageStats->m_iCurPossibleDancePoints,
      std::max(0, TapNoteScoreToDancePoints(maximum)),
      "ScoreKeeperNormal::HandleTapNoteScoreInternal current possible DP");
}

void ScoreKeeperNormal::HandleComboInternal(
    int iNumHitContinueCombo, int iNumHitMaintainCombo, int iNumBreakCombo,
    int iRow) {
  if (!HasScoringState("ScoreKeeperNormal::HandleComboInternal")) {
    return;
  }
  iNumHitContinueCombo = ClampComboInput(
      iNumHitContinueCombo,
      "ScoreKeeperNormal::HandleComboInternal continue count");
  iNumHitMaintainCombo = ClampComboInput(
      iNumHitMaintainCombo,
      "ScoreKeeperNormal::HandleComboInternal maintain count");
  iNumBreakCombo = ClampComboInput(
      iNumBreakCombo, "ScoreKeeperNormal::HandleComboInternal break count");

  // Regular combo
  if (m_ComboIsPerRow) {
    iNumHitContinueCombo = std::min(iNumHitContinueCombo, 1);
    iNumHitMaintainCombo = std::min(iNumHitMaintainCombo, 1);
    iNumBreakCombo = std::min(iNumBreakCombo, 1);
  }

  if (iNumHitContinueCombo > 0 || iNumHitMaintainCombo > 0) {
    m_pPlayerStageStats->m_iCurMissCombo = 0;
  }
  TimingData* pTiming =
      GetCurrentTimingDataForPlayer(m_pPlayerState->m_PlayerNumber);
  if (iNumBreakCombo == 0) {
    int multiplier = GetComboMultiplier(pTiming, iRow, false);
    m_pPlayerStageStats->m_iCurCombo = AddUnsignedDeltaSaturated(
        m_pPlayerStageStats->m_iCurCombo,
        MulIntSaturated(
            iNumHitContinueCombo, multiplier,
            "ScoreKeeperNormal::HandleComboInternal continue combo"),
        "ScoreKeeperNormal::HandleComboInternal current combo");
  } else {
    m_pPlayerStageStats->m_iCurCombo = 0;
    int multiplier = GetComboMultiplier(pTiming, iRow, true);
    m_pPlayerStageStats->m_iCurMissCombo = AddUnsignedDeltaSaturated(
        m_pPlayerStageStats->m_iCurMissCombo,
        MulIntSaturated(
            m_MissComboIsPerRow ? 1 : iNumBreakCombo, multiplier,
            "ScoreKeeperNormal::HandleComboInternal miss combo"),
        "ScoreKeeperNormal::HandleComboInternal current miss combo");
  }
}

void ScoreKeeperNormal::HandleRowComboInternal(
    TapNoteScore tns, int iNumTapsInRow, int iRow) {
  if (!HasScoringState("ScoreKeeperNormal::HandleRowComboInternal")) {
    return;
  }
  if (!IsRowTapNoteScore(tns)) {
    LOG->Warn(
        "SRC_AUDIT_FIX: ScoreKeeperNormal::HandleRowComboInternal ignored "
        "invalid tap score %i.",
        tns);
    return;
  }
  iNumTapsInRow = ClampComboInput(
      iNumTapsInRow, "ScoreKeeperNormal::HandleRowComboInternal row taps");
  if (m_ComboIsPerRow) {
    iNumTapsInRow = std::min(iNumTapsInRow, 1);
  }
  TimingData* pTiming =
      GetCurrentTimingDataForPlayer(m_pPlayerState->m_PlayerNumber);
  const TapNoteScore minContinue = ClampTapMetric(
      m_MinScoreToContinueCombo, TNS_W3,
      "ScoreKeeperNormal::HandleRowComboInternal continue threshold");
  const TapNoteScore minMaintain = ClampTapMetric(
      m_MinScoreToMaintainCombo, TNS_W4,
      "ScoreKeeperNormal::HandleRowComboInternal maintain threshold");
  const TapNoteScore maxMiss = ClampTapMetric(
      m_MaxScoreToIncrementMissCombo, TNS_Miss,
      "ScoreKeeperNormal::HandleRowComboInternal miss threshold");
  if (tns >= minContinue) {
    m_pPlayerStageStats->m_iCurMissCombo = 0;
    int multiplier = GetComboMultiplier(pTiming, iRow, false);
    m_pPlayerStageStats->m_iCurCombo = AddUnsignedDeltaSaturated(
        m_pPlayerStageStats->m_iCurCombo,
        MulIntSaturated(
            iNumTapsInRow, multiplier,
            "ScoreKeeperNormal::HandleRowComboInternal continue combo"),
        "ScoreKeeperNormal::HandleRowComboInternal current combo");
  } else if (tns < minMaintain) {
    m_pPlayerStageStats->m_iCurCombo = 0;

    if (tns <= maxMiss) {
      int multiplier = GetComboMultiplier(pTiming, iRow, true);
      m_pPlayerStageStats->m_iCurMissCombo = AddUnsignedDeltaSaturated(
          m_pPlayerStageStats->m_iCurMissCombo,
          MulIntSaturated(
              m_MissComboIsPerRow ? 1 : iNumTapsInRow, multiplier,
              "ScoreKeeperNormal::HandleRowComboInternal miss combo"),
          "ScoreKeeperNormal::HandleRowComboInternal current miss combo");
    }
  }
}

void ScoreKeeperNormal::GetRowCounts(
    const NoteData& nd, int iRow, int& iNumHitContinueCombo,
    int& iNumHitMaintainCombo, int& iNumBreakCombo) {
  iNumHitContinueCombo = iNumHitMaintainCombo = iNumBreakCombo = 0;
  if (iRow < 0 || iRow > MAX_NOTE_ROW) {
    LOG->Warn(
        "SRC_AUDIT_FIX: ScoreKeeperNormal::GetRowCounts ignored invalid row "
        "%i.",
        iRow);
    return;
  }
  const TapNoteScore minContinue = ClampTapMetric(
      m_MinScoreToContinueCombo, TNS_W3,
      "ScoreKeeperNormal::GetRowCounts continue threshold");
  const TapNoteScore minMaintain = ClampTapMetric(
      m_MinScoreToMaintainCombo, TNS_W4,
      "ScoreKeeperNormal::GetRowCounts maintain threshold");
  for (int track = 0; track < nd.GetNumTracks(); ++track) {
    const TapNote& tn = nd.GetTapNote(track, iRow);

    if (tn.type != TapNoteType_Tap && tn.type != TapNoteType_HoldHead &&
        tn.type != TapNoteType_Lift && tn.type != TapNoteType_Attack) {
      continue;
    }
    TapNoteScore tns = tn.result.tns;
    if (!IsRowTapNoteScore(tns)) {
      LOG->Warn(
          "SRC_AUDIT_FIX: ScoreKeeperNormal ignored invalid row tap score %i "
          "at row %i.",
          tns, iRow);
      iNumHitContinueCombo = iNumHitMaintainCombo = iNumBreakCombo = 0;
      return;
    }
    if (tns >= minContinue) {
      ++iNumHitContinueCombo;
    } else if (tns >= minMaintain) {
      ++iNumHitMaintainCombo;
    } else {
      ++iNumBreakCombo;
    }
  }
}

void ScoreKeeperNormal::HandleTapRowScore(const NoteData& nd, int iRow) {
  if (!HasScoringState("ScoreKeeperNormal::HandleTapRowScore")) {
    return;
  }
  if (iRow < 0 || iRow > MAX_NOTE_ROW) {
    LOG->Warn(
        "SRC_AUDIT_FIX: ScoreKeeperNormal::HandleTapRowScore ignored invalid "
        "row %i.",
        iRow);
    return;
  }
  int iNumHitContinueCombo, iNumHitMaintainCombo, iNumBreakCombo;
  GetRowCounts(
      nd, iRow, iNumHitContinueCombo, iNumHitMaintainCombo, iNumBreakCombo);

  int iNumTapsInRow = AddNonNegativeIntSaturated(
      iNumHitContinueCombo,
      AddNonNegativeIntSaturated(
          iNumHitMaintainCombo, iNumBreakCombo,
          "ScoreKeeperNormal::HandleTapRowScore row hit totals"),
      "ScoreKeeperNormal::HandleTapRowScore row tap totals");
  if (iNumTapsInRow <= 0) {
    return;
  }

  m_iNumNotesHitThisRow = iNumTapsInRow;

  TapNoteScore scoreOfLastTap =
      NoteDataWithScoring::LastTapNoteWithResult(nd, iRow).result.tns;
  if (!IsRowTapNoteScore(scoreOfLastTap)) {
    LOG->Warn(
        "SRC_AUDIT_FIX: ScoreKeeperNormal::HandleTapRowScore ignored invalid "
        "last tap score %i at row %i.",
        scoreOfLastTap, iRow);
    return;
  }
  HandleTapNoteScoreInternal(scoreOfLastTap, TNS_W1, iRow);

  const Game* pGame =
      GAMESTATE == nullptr ? nullptr : GAMESTATE->GetCurrentGame();
  if (pGame != nullptr && pGame->m_bCountNotesSeparately) {
    HandleComboInternal(
        iNumHitContinueCombo, iNumHitMaintainCombo, iNumBreakCombo, iRow);
  } else {
    HandleRowComboInternal(
        scoreOfLastTap, iNumTapsInRow, iRow);  // This should work?
  }

  if (IsValidPlayerNumber(m_pPlayerState->m_PlayerNumber)) {
    BroadcastScoreKeeperMessage(
        enum_add2(
            Message_CurrentComboChangedP1, m_pPlayerState->m_PlayerNumber),
        "ScoreKeeperNormal::HandleTapRowScore");
  }

  AddTapRowScore(scoreOfLastTap, nd, iRow);  // only score once per row

  // handle combo logic
#ifndef DEBUG
  if ((GamePreferences::m_AutoPlay != PC_HUMAN ||
       m_pPlayerState->m_PlayerOptions.GetCurrent().m_fPlayerAutoPlay != 0) &&
      (GAMESTATE == nullptr ||
       !GAMESTATE->m_bDemonstrationOrJukebox))  // cheaters always prosper >:D
                                                // -aj comment edit
  {
    m_cur_toasty_combo = 0;
    return;
  }
#endif  // DEBUG

  // Toasty combo
  const TapNoteScore toastyMin = ClampTapMetric(
      m_toasty_min_tns, TNS_W2,
      "ScoreKeeperNormal::HandleTapRowScore toasty threshold");
  if (scoreOfLastTap >= toastyMin) {
    m_cur_toasty_combo = AddNonNegativeIntSaturated(
        m_cur_toasty_combo, iNumTapsInRow,
        "ScoreKeeperNormal::HandleTapRowScore toasty combo");
    if (m_cur_toasty_combo > m_next_toasty_at &&
        (GAMESTATE == nullptr || !GAMESTATE->m_bDemonstrationOrJukebox)) {
      m_cur_toasty_level = AddNonNegativeIntSaturated(
          m_cur_toasty_level, 1,
          "ScoreKeeperNormal::HandleTapRowScore toasty level");
      // Broadcast the message before posting the screen message so that the
      // transition layer can catch the message to know the level and respond
      // accordingly. -Kyz
      Message msg("ToastyAchieved");
      msg.SetParam("PlayerNumber", m_pPlayerState->m_PlayerNumber);
      msg.SetParam("ToastyCombo", m_cur_toasty_combo);
      msg.SetParam("Level", m_cur_toasty_level);
      BroadcastScoreKeeperMessage(
          msg, "ScoreKeeperNormal::HandleTapRowScore toasty achieved");
      if (SCREENMAN != nullptr) {
        SCREENMAN->PostMessageToTopScreen(SM_PlayToasty, 0);
      }
      PlayerNumber pn = m_pPlayerState->m_PlayerNumber;
      if (IsValidPlayerNumber(pn) && PROFILEMAN != nullptr) {
        // TODO: keep a pointer to the Profile.
        // TODO: Make the profile count the level and combo of the toasty. -Kyz
        PROFILEMAN->IncrementToastiesCount(pn);
      } else {
        LOG->Warn(
            "SRC_AUDIT_FIX: ScoreKeeperNormal skipped Toasty profile update "
            "for player %i with PROFILEMAN=%p.",
            pn, static_cast<void*>(PROFILEMAN));
      }
      m_next_toasty_at = CalcNextToastyAt(m_cur_toasty_level);
    }
  } else {
    m_cur_toasty_combo = 0;
    m_cur_toasty_level = 0;
    m_next_toasty_at = 0;
    m_next_toasty_at = CalcNextToastyAt(m_cur_toasty_level);
    Message msg("ToastyDropped");
    msg.SetParam("PlayerNumber", m_pPlayerState->m_PlayerNumber);
    BroadcastScoreKeeperMessage(
        msg, "ScoreKeeperNormal::HandleTapRowScore toasty dropped");
  }

  Message msg("ScoreChanged");
  msg.SetParam("PlayerNumber", m_pPlayerState->m_PlayerNumber);
  msg.SetParam("MultiPlayer", m_pPlayerState->m_mp);
  msg.SetParam("ToastyCombo", m_cur_toasty_combo);
  BroadcastScoreKeeperMessage(msg, "ScoreKeeperNormal::HandleTapRowScore");
}

void ScoreKeeperNormal::HandleHoldScore(const TapNote& tn) {
  if (!HasScoringState("ScoreKeeperNormal::HandleHoldScore")) {
    return;
  }
  HoldNoteScore holdScore = tn.HoldResult.hns;
  if (!IsValidHoldNoteScore(holdScore) || holdScore == HNS_None) {
    LOG->Warn(
        "SRC_AUDIT_FIX: ScoreKeeperNormal ignored invalid hold score %i.",
        holdScore);
    return;
  }

  // update dance points totals
  if (!m_pPlayerStageStats->m_bFailed) {
    m_pPlayerStageStats->m_iActualDancePoints =
        AddDancePointsClampedNonNegative(
            m_pPlayerStageStats->m_iActualDancePoints,
            HoldNoteScoreToDancePoints(holdScore),
            "ScoreKeeperNormal::HandleHoldScore actual dance points");
  }
  // increment the current total possible dance score
  m_pPlayerStageStats->m_iCurPossibleDancePoints = AddNonNegativeIntSaturated(
      m_pPlayerStageStats->m_iCurPossibleDancePoints,
      std::max(0, HoldNoteScoreToDancePoints(HNS_Held)),
      "ScoreKeeperNormal::HandleHoldScore current possible DP");
  m_pPlayerStageStats->m_iHoldNoteScores[holdScore] =
      AddNonNegativeIntSaturated(
          m_pPlayerStageStats->m_iHoldNoteScores[holdScore], 1,
          "ScoreKeeperNormal::HandleHoldScore hold count");

  AddHoldScore(holdScore);

  Message msg("ScoreChanged");
  msg.SetParam("PlayerNumber", m_pPlayerState->m_PlayerNumber);
  msg.SetParam("MultiPlayer", m_pPlayerState->m_mp);
  BroadcastScoreKeeperMessage(msg, "ScoreKeeperNormal::HandleHoldScore");
}

int ScoreKeeperNormal::GetPossibleDancePoints(
    NoteData* nd, const TimingData* td, float fSongSeconds) {
  if (nd == nullptr) {
    LOG->Warn(
        "SRC_AUDIT_FIX: ScoreKeeperNormal::GetPossibleDancePoints received "
        "null NoteData.");
    return 0;
  }
  if (td == nullptr) {
    LOG->Warn(
        "SRC_AUDIT_FIX SRC-2059: ScoreKeeperNormal::GetPossibleDancePoints "
        "received null timing data.");
    return 0;
  }
  if (!std::isfinite(fSongSeconds) || fSongSeconds < 0.0f) {
    LOG->Warn(
        "SRC_AUDIT_FIX: ScoreKeeperNormal::GetPossibleDancePoints normalized "
        "invalid song seconds %f.",
        fSongSeconds);
    fSongSeconds = 0.0f;
  }

  /* Note: If W1 timing is disabled or not active (not course mode),
   * W2 will be used instead. */
  // XXX: That's not actually implemented!
  RadarValues radars;
  NoteDataUtil::CalculateRadarValues(*nd, fSongSeconds, td, radars);

  int ret = 0;

  ret = AddIntSaturated(
      ret,
      MulIntSaturated(
          RadarValueToNonNegativeInt(
              radars[RadarCategory_TapsAndHolds],
              "ScoreKeeperNormal::GetPossibleDancePoints taps and holds"),
          TapNoteScoreToDancePoints(TNS_W1, false),
          "ScoreKeeperNormal::GetPossibleDancePoints tap DP"),
      "ScoreKeeperNormal::GetPossibleDancePoints total");
  if (TICK_HOLDS) {
    ret = AddIntSaturated(
        ret,
        MulIntSaturated(
            UnsignedToIntSaturated(
                NoteDataUtil::GetTotalHoldTicks(nd, td),
                "ScoreKeeperNormal::GetPossibleDancePoints hold ticks"),
            ClampScoreWeight(
                g_iPercentScoreWeight.GetValue(SE_CheckpointHit),
                "ScoreKeeperNormal::GetPossibleDancePoints checkpoint DP"),
            "ScoreKeeperNormal::GetPossibleDancePoints hold tick DP"),
        "ScoreKeeperNormal::GetPossibleDancePoints total");
  }
  ret = AddIntSaturated(
      ret,
      MulIntSaturated(
          RadarValueToNonNegativeInt(
              radars[RadarCategory_Holds],
              "ScoreKeeperNormal::GetPossibleDancePoints holds"),
          HoldNoteScoreToDancePoints(HNS_Held, false),
          "ScoreKeeperNormal::GetPossibleDancePoints hold DP"),
      "ScoreKeeperNormal::GetPossibleDancePoints total");
  ret = AddIntSaturated(
      ret,
      MulIntSaturated(
          RadarValueToNonNegativeInt(
              radars[RadarCategory_Rolls],
              "ScoreKeeperNormal::GetPossibleDancePoints rolls"),
          HoldNoteScoreToDancePoints(HNS_Held, false),
          "ScoreKeeperNormal::GetPossibleDancePoints roll DP"),
      "ScoreKeeperNormal::GetPossibleDancePoints total");

  return std::max(0, ret);
}

int ScoreKeeperNormal::GetPossibleDancePoints(
    NoteData* ndPre, NoteData* ndPost, const TimingData* td,
    float fSongSeconds) {
  /* The logic here is that if you use a modifier that adds notes, you should
   * have to hit the new notes to get a high grade. However, if you use one
   * that removes notes, they should simply be counted as misses. */
  return std::max(
      GetPossibleDancePoints(ndPre, td, fSongSeconds),
      GetPossibleDancePoints(ndPost, td, fSongSeconds));
}

int ScoreKeeperNormal::GetPossibleGradePoints(
    NoteData* nd, const TimingData* td, float fSongSeconds) {
  if (nd == nullptr) {
    LOG->Warn(
        "SRC_AUDIT_FIX: ScoreKeeperNormal::GetPossibleGradePoints received "
        "null NoteData.");
    return 0;
  }
  if (td == nullptr) {
    LOG->Warn(
        "SRC_AUDIT_FIX SRC-2059: ScoreKeeperNormal::GetPossibleGradePoints "
        "received null timing data.");
    return 0;
  }
  if (!std::isfinite(fSongSeconds) || fSongSeconds < 0.0f) {
    LOG->Warn(
        "SRC_AUDIT_FIX: ScoreKeeperNormal::GetPossibleGradePoints normalized "
        "invalid song seconds %f.",
        fSongSeconds);
    fSongSeconds = 0.0f;
  }

  /* Note: if W1 timing is disabled or not active (not course mode),
   * W2 will be used instead. */
  // XXX: That's not actually implemented!
  RadarValues radars;
  NoteDataUtil::CalculateRadarValues(*nd, fSongSeconds, td, radars);

  int ret = 0;

  ret = AddIntSaturated(
      ret,
      MulIntSaturated(
          RadarValueToNonNegativeInt(
              radars[RadarCategory_TapsAndHolds],
              "ScoreKeeperNormal::GetPossibleGradePoints taps and holds"),
          TapNoteScoreToGradePoints(TNS_W1, false),
          "ScoreKeeperNormal::GetPossibleGradePoints tap grade"),
      "ScoreKeeperNormal::GetPossibleGradePoints total");
  if (TICK_HOLDS) {
    ret = AddIntSaturated(
        ret,
        MulIntSaturated(
            UnsignedToIntSaturated(
                NoteDataUtil::GetTotalHoldTicks(nd, td),
                "ScoreKeeperNormal::GetPossibleGradePoints hold ticks"),
            ClampScoreWeight(
                g_iGradeWeight.GetValue(SE_CheckpointHit),
                "ScoreKeeperNormal::GetPossibleGradePoints checkpoint grade"),
            "ScoreKeeperNormal::GetPossibleGradePoints hold tick grade"),
        "ScoreKeeperNormal::GetPossibleGradePoints total");
  }
  ret = AddIntSaturated(
      ret,
      MulIntSaturated(
          RadarValueToNonNegativeInt(
              radars[RadarCategory_Holds],
              "ScoreKeeperNormal::GetPossibleGradePoints holds"),
          HoldNoteScoreToGradePoints(HNS_Held, false),
          "ScoreKeeperNormal::GetPossibleGradePoints hold grade"),
      "ScoreKeeperNormal::GetPossibleGradePoints total");
  ret = AddIntSaturated(
      ret,
      MulIntSaturated(
          RadarValueToNonNegativeInt(
              radars[RadarCategory_Rolls],
              "ScoreKeeperNormal::GetPossibleGradePoints rolls"),
          HoldNoteScoreToGradePoints(HNS_Held, false),
          "ScoreKeeperNormal::GetPossibleGradePoints roll grade"),
      "ScoreKeeperNormal::GetPossibleGradePoints total");

  return std::max(0, ret);
}

int ScoreKeeperNormal::GetPossibleGradePoints(
    NoteData* ndPre, NoteData* ndPost, const TimingData* td,
    float fSongSeconds) {
  /* The logic here is that if you use a modifier that adds notes, you should
   * have to hit the new notes to get a high grade. However, if you use one
   * that removes notes, they should simply be counted as misses. */
  return std::max(
      GetPossibleGradePoints(ndPre, td, fSongSeconds),
      GetPossibleGradePoints(ndPost, td, fSongSeconds));
}

int ScoreKeeperNormal::TapNoteScoreToDancePoints(TapNoteScore tns) const {
  return TapNoteScoreToDancePoints(tns, m_bIsBeginner);
}

int ScoreKeeperNormal::HoldNoteScoreToDancePoints(HoldNoteScore hns) const {
  return HoldNoteScoreToDancePoints(hns, m_bIsBeginner);
}

int ScoreKeeperNormal::TapNoteScoreToGradePoints(TapNoteScore tns) const {
  return TapNoteScoreToGradePoints(tns, m_bIsBeginner);
}
int ScoreKeeperNormal::HoldNoteScoreToGradePoints(HoldNoteScore hns) const {
  return HoldNoteScoreToGradePoints(hns, m_bIsBeginner);
}

int ScoreKeeperNormal::TapNoteScoreToDancePoints(
    TapNoteScore tns, bool bBeginner) {
  if (!IsValidTapNoteScore(tns)) {
    LOG->Warn(
        "SRC_AUDIT_FIX: ScoreKeeperNormal mapped invalid tap score %i to 0 "
        "dance points.",
        tns);
    return 0;
  }
  if (!ShouldShowW1() && tns == TNS_W1) {
    tns = TNS_W2;
  }

  /* This is used for Oni percentage displays. Grading values are currently in
   * StageStats::GetGrade. */
  int iWeight = 0;
  switch (tns) {
    case TNS_None:
    case TNS_AvoidMine:
      iWeight = 0;
      break;
    case TNS_HitMine:
      iWeight = ClampScoreWeight(
          g_iPercentScoreWeight.GetValue(SE_HitMine),
          "ScoreKeeperNormal::TapNoteScoreToDancePoints HitMine");
      break;
    case TNS_Miss:
      iWeight = ClampScoreWeight(
          g_iPercentScoreWeight.GetValue(SE_Miss),
          "ScoreKeeperNormal::TapNoteScoreToDancePoints Miss");
      break;
    case TNS_W5:
      iWeight = ClampScoreWeight(
          g_iPercentScoreWeight.GetValue(SE_W5),
          "ScoreKeeperNormal::TapNoteScoreToDancePoints W5");
      break;
    case TNS_W4:
      iWeight = ClampScoreWeight(
          g_iPercentScoreWeight.GetValue(SE_W4),
          "ScoreKeeperNormal::TapNoteScoreToDancePoints W4");
      break;
    case TNS_W3:
      iWeight = ClampScoreWeight(
          g_iPercentScoreWeight.GetValue(SE_W3),
          "ScoreKeeperNormal::TapNoteScoreToDancePoints W3");
      break;
    case TNS_W2:
      iWeight = ClampScoreWeight(
          g_iPercentScoreWeight.GetValue(SE_W2),
          "ScoreKeeperNormal::TapNoteScoreToDancePoints W2");
      break;
    case TNS_W1:
      iWeight = ClampScoreWeight(
          g_iPercentScoreWeight.GetValue(SE_W1),
          "ScoreKeeperNormal::TapNoteScoreToDancePoints W1");
      break;
    case TNS_CheckpointHit:
      iWeight = ClampScoreWeight(
          g_iPercentScoreWeight.GetValue(SE_CheckpointHit),
          "ScoreKeeperNormal::TapNoteScoreToDancePoints CheckpointHit");
      break;
    case TNS_CheckpointMiss:
      iWeight = ClampScoreWeight(
          g_iPercentScoreWeight.GetValue(SE_CheckpointMiss),
          "ScoreKeeperNormal::TapNoteScoreToDancePoints CheckpointMiss");
      break;
    default:
      LOG->Warn(
          "SRC_AUDIT_FIX: ScoreKeeperNormal mapped unexpected tap score %i "
          "to 0 dance points.",
          tns);
      iWeight = 0;
      break;
  }
  if (bBeginner && PREFSMAN != nullptr && PREFSMAN->m_bMercifulBeginner) {
    iWeight = std::max(0, iWeight);
  }
  return iWeight;
}

int ScoreKeeperNormal::HoldNoteScoreToDancePoints(
    HoldNoteScore hns, bool bBeginner) {
  if (!IsValidHoldNoteScore(hns)) {
    LOG->Warn(
        "SRC_AUDIT_FIX: ScoreKeeperNormal mapped invalid hold score %i to 0 "
        "dance points.",
        hns);
    return 0;
  }

  int iWeight = 0;
  switch (hns) {
    case HNS_None:
      iWeight = 0;
      break;
    case HNS_LetGo:
      iWeight = ClampScoreWeight(
          g_iPercentScoreWeight.GetValue(SE_LetGo),
          "ScoreKeeperNormal::HoldNoteScoreToDancePoints LetGo");
      break;
    case HNS_Held:
      iWeight = ClampScoreWeight(
          g_iPercentScoreWeight.GetValue(SE_Held),
          "ScoreKeeperNormal::HoldNoteScoreToDancePoints Held");
      break;
    case HNS_Missed:
      iWeight = ClampScoreWeight(
          g_iPercentScoreWeight.GetValue(SE_Missed),
          "ScoreKeeperNormal::HoldNoteScoreToDancePoints Missed");
      break;
    default:
      LOG->Warn(
          "SRC_AUDIT_FIX: ScoreKeeperNormal mapped unexpected hold score %i "
          "to 0 dance points.",
          hns);
      iWeight = 0;
      break;
  }
  if (bBeginner && PREFSMAN != nullptr && PREFSMAN->m_bMercifulBeginner) {
    iWeight = std::max(0, iWeight);
  }
  return iWeight;
}

int ScoreKeeperNormal::TapNoteScoreToGradePoints(
    TapNoteScore tns, bool bBeginner) {
  if (!IsValidTapNoteScore(tns)) {
    LOG->Warn(
        "SRC_AUDIT_FIX: ScoreKeeperNormal mapped invalid tap score %i to 0 "
        "grade points.",
        tns);
    return 0;
  }
  if (!ShouldShowW1() && tns == TNS_W1) {
    tns = TNS_W2;
  }

  /* This is used for Oni percentage displays. Grading values are currently in
   * StageStats::GetGrade. */
  int iWeight = 0;
  switch (tns) {
    case TNS_None:
      iWeight = 0;
      break;
    case TNS_AvoidMine:
      iWeight = 0;
      break;
    case TNS_HitMine:
      iWeight = ClampScoreWeight(
          g_iGradeWeight.GetValue(SE_HitMine),
          "ScoreKeeperNormal::TapNoteScoreToGradePoints HitMine");
      break;
    case TNS_Miss:
      iWeight = ClampScoreWeight(
          g_iGradeWeight.GetValue(SE_Miss),
          "ScoreKeeperNormal::TapNoteScoreToGradePoints Miss");
      break;
    case TNS_W5:
      iWeight = ClampScoreWeight(
          g_iGradeWeight.GetValue(SE_W5),
          "ScoreKeeperNormal::TapNoteScoreToGradePoints W5");
      break;
    case TNS_W4:
      iWeight = ClampScoreWeight(
          g_iGradeWeight.GetValue(SE_W4),
          "ScoreKeeperNormal::TapNoteScoreToGradePoints W4");
      break;
    case TNS_W3:
      iWeight = ClampScoreWeight(
          g_iGradeWeight.GetValue(SE_W3),
          "ScoreKeeperNormal::TapNoteScoreToGradePoints W3");
      break;
    case TNS_W2:
      iWeight = ClampScoreWeight(
          g_iGradeWeight.GetValue(SE_W2),
          "ScoreKeeperNormal::TapNoteScoreToGradePoints W2");
      break;
    case TNS_W1:
      iWeight = ClampScoreWeight(
          g_iGradeWeight.GetValue(SE_W1),
          "ScoreKeeperNormal::TapNoteScoreToGradePoints W1");
      break;
    case TNS_CheckpointHit:
      iWeight = ClampScoreWeight(
          g_iGradeWeight.GetValue(SE_CheckpointHit),
          "ScoreKeeperNormal::TapNoteScoreToGradePoints CheckpointHit");
      break;
    case TNS_CheckpointMiss:
      iWeight = ClampScoreWeight(
          g_iGradeWeight.GetValue(SE_CheckpointMiss),
          "ScoreKeeperNormal::TapNoteScoreToGradePoints CheckpointMiss");
      break;
    default:
      LOG->Warn(
          "SRC_AUDIT_FIX: ScoreKeeperNormal mapped unexpected tap score %i "
          "to 0 grade points.",
          tns);
      iWeight = 0;
      break;
  }
  if (bBeginner && PREFSMAN != nullptr && PREFSMAN->m_bMercifulBeginner) {
    iWeight = std::max(0, iWeight);
  }
  return iWeight;
}

int ScoreKeeperNormal::HoldNoteScoreToGradePoints(
    HoldNoteScore hns, bool bBeginner) {
  if (!IsValidHoldNoteScore(hns)) {
    LOG->Warn(
        "SRC_AUDIT_FIX: ScoreKeeperNormal mapped invalid hold score %i to 0 "
        "grade points.",
        hns);
    return 0;
  }

  int iWeight = 0;
  switch (hns) {
    case HNS_None:
      iWeight = 0;
      break;
    case HNS_LetGo:
      iWeight = ClampScoreWeight(
          g_iGradeWeight.GetValue(SE_LetGo),
          "ScoreKeeperNormal::HoldNoteScoreToGradePoints LetGo");
      break;
    case HNS_Held:
      iWeight = ClampScoreWeight(
          g_iGradeWeight.GetValue(SE_Held),
          "ScoreKeeperNormal::HoldNoteScoreToGradePoints Held");
      break;
    case HNS_Missed:
      iWeight = ClampScoreWeight(
          g_iGradeWeight.GetValue(SE_Missed),
          "ScoreKeeperNormal::HoldNoteScoreToGradePoints Missed");
      break;
    default:
      LOG->Warn(
          "SRC_AUDIT_FIX: ScoreKeeperNormal mapped unexpected hold score %i "
          "to 0 grade points.",
          hns);
      iWeight = 0;
      break;
  }
  if (bBeginner && PREFSMAN != nullptr && PREFSMAN->m_bMercifulBeginner) {
    iWeight = std::max(0, iWeight);
  }
  return iWeight;
}

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
