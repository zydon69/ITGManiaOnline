#include "StatsManager.h"

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <climits>
#include <limits>
#include <memory>
#include <set>
#include <string>
#include <vector>

#include "CourseUtil.h"
#include "CryptManager.h"
#include "EnumHelper.h"
#include "GameConstantsAndTypes.h"
#include "GameState.h"
#include "Grade.h"
#include "LuaManager.h"
#include "ModsGroup.h"
#include "NotesWriterSM.h"
#include "Player.h"
#include "PlayerNumber.h"
#include "PlayerOptions.h"
#include "PlayerState.h"
#include "Preference.h"
#include "PrefsManager.h"
#include "Profile.h"
#include "ProfileManager.h"
#include "RageFileDriverMemory.h"
#include "RageLog.h"
#include "Song.h"
#include "SongUtil.h"
#include "StdString.h"
#include "Steps.h"
#include "StyleUtil.h"
#include "TrailUtil.h"
#include "XmlFile.h"
#include "XmlFileUtil.h"
#include "global.h"

StatsManager* STATSMAN =
    nullptr;  // global object accessible from anywhere in the program

namespace {
bool IsValidPlayerNumber(PlayerNumber pn) {
  return pn >= PLAYER_1 && pn < NUM_PLAYERS;
}

bool IsValidMultiPlayer(MultiPlayer mp) {
  return mp >= MultiPlayer_P1 && mp < NUM_MultiPlayer;
}

bool IsValidPlayMode(PlayMode pm) {
  return pm >= PLAY_MODE_REGULAR && pm < NUM_PlayMode;
}

bool IsValidDifficulty(Difficulty dc) {
  return dc >= Difficulty_Beginner && dc < NUM_Difficulty;
}

bool IsValidGrade(Grade grade) {
  return grade >= Grade_Tier01 && grade < NUM_Grade;
}

bool IsCoursePlayMode(PlayMode pm) {
  return pm == PLAY_MODE_ONI || pm == PLAY_MODE_NONSTOP ||
         pm == PLAY_MODE_ENDLESS;
}

int SafeNonNegativeInt(float value, const char* context) {
  if (!std::isfinite(value) || value <= 0.0f) {
    if (!std::isfinite(value)) {
      LOG->Warn("SRC_AUDIT_FIX: %s ignored non-finite value %f.", context,
                value);
    }
    return 0;
  }
  if (value > static_cast<float>(INT_MAX)) {
    LOG->Warn("SRC_AUDIT_FIX: %s clamped oversized value %f.", context, value);
    return INT_MAX;
  }
  return static_cast<int>(value);
}

float SafeFiniteFloat(float value, const char* context) {
  if (!std::isfinite(value)) {
    LOG->Warn("SRC_AUDIT_FIX: %s replaced non-finite value %f.", context,
              value);
    return 0.0f;
  }
  return value;
}

int SafeNonNegativeSize(size_t value, const char* context) {
  if (value > static_cast<size_t>(INT_MAX)) {
    LOG->Warn("SRC_AUDIT_FIX: %s clamped oversized size %zu.", context, value);
    return INT_MAX;
  }
  return static_cast<int>(value);
}

void SafeAddInt(int& target, int amount, const char* context) {
  if (amount <= 0) {
    if (amount < 0) {
      LOG->Warn("SRC_AUDIT_FIX: %s ignored negative increment %d.", context,
                amount);
    }
    return;
  }
  if (target > INT_MAX - amount) {
    LOG->Warn("SRC_AUDIT_FIX: %s saturated at INT_MAX.", context);
    target = INT_MAX;
    return;
  }
  target += amount;
}

void SafeIncrementInt(int& target, const char* context) {
  SafeAddInt(target, 1, context);
}

bool HasAnyJoinedPlayer(const StageStats& ss) {
  FOREACH_PlayerNumber(pn) {
    if (ss.m_player[pn].m_bJoined) {
      return true;
    }
  }
  FOREACH_MultiPlayer(mp) {
    if (ss.m_multiPlayer[mp].m_bJoined) {
      return true;
    }
  }
  return false;
}

void AddStepsInUseFromStageStats(
    const StageStats& ss, std::set<Steps*>& apInUseOut) {
  FOREACH_PlayerNumber(pn) {
    const PlayerStageStats& pss = ss.m_player[pn];
    for (Steps* steps : pss.m_vpPossibleSteps) {
      if (steps != nullptr) {
        apInUseOut.insert(steps);
      }
    }
  }

  FOREACH_MultiPlayer(mp) {
    const PlayerStageStats& pss = ss.m_multiPlayer[mp];
    for (Steps* steps : pss.m_vpPossibleSteps) {
      if (steps != nullptr) {
        apInUseOut.insert(steps);
      }
    }
  }
}

bool HasSongRecentScoreContext(
    const StageStats& ss, const PlayerStageStats& pss, const char* context) {
  if (ss.m_vpPossibleSongs.empty() || ss.m_vpPossibleSongs[0] == nullptr ||
      pss.m_vpPossibleSteps.empty() || pss.m_vpPossibleSteps[0] == nullptr) {
    LOG->Warn(
        "SRC_AUDIT_FIX: %s skipped incomplete song score context: songs=%zu "
        "steps=%zu.",
        context, ss.m_vpPossibleSongs.size(), pss.m_vpPossibleSteps.size());
    return false;
  }
  return true;
}
}  // namespace

void AddPlayerStatsToProfile(
    Profile* pProfile, const StageStats& ss, PlayerNumber pn);
std::unique_ptr<XNode> MakeRecentScoreNode(
    const StageStats& ss, Course* pCourse, Trail* pTrail,
    const PlayerStageStats& pss, MultiPlayer mp, const std::string& stageGuid);
Preference<bool> g_PadmissEnabled("MemoryCardPadmissEnabled", false);

StatsManager::StatsManager() {
  // Register with Lua.
  if (LUA != nullptr) {
    Lua* L = LUA->Get();
    lua_pushstring(L, "STATSMAN");
    this->PushSelf(L);
    lua_settable(L, LUA_GLOBALSINDEX);
    LUA->Release(L);
  } else {
    LOG->Warn(
        "SRC_AUDIT_FIX: StatsManager constructed without LUA; global binding "
        "skipped.");
  }
}

StatsManager::~StatsManager() {
  // Unregister with Lua.
  if (LUA != nullptr) {
    LUA->UnsetGlobal("STATSMAN");
  }
}

void StatsManager::Reset() {
  m_CurStageStats.Init();
  m_vPlayedStageStats.clear();
  m_AccumPlayedStageStats.Init();

  CalcAccumPlayedStageStats();
}

static StageStats AccumPlayedStageStats(const std::vector<StageStats>& vss) {
  StageStats ssreturn;

  if (!vss.empty()) {
    ssreturn.m_playMode = vss[0].m_playMode;
  }

  for (const StageStats& ss : vss) {
    ssreturn.AddStats(ss);
  }

  const unsigned uNumSongs =
      static_cast<unsigned>(std::min<size_t>(
          ssreturn.m_vpPlayedSongs.size(),
          static_cast<size_t>(std::numeric_limits<unsigned>::max())));

  if (uNumSongs == 0) {
    return ssreturn;  // don't divide by 0 below
  }

  /* Scale radar percentages back down to roughly 0..1.  Don't scale
   * RadarCategory_TapsAndHolds and the rest, which are counters. */
  // FIXME: Weight each song by the number of stages it took to account for
  // long, marathon.
  FOREACH_PlayerNumber(p) {
    for (int r = 0; r < RadarCategory_TapsAndHolds; r++) {
      ssreturn.m_player[p].m_radarPossible[r] /= uNumSongs;
      ssreturn.m_player[p].m_radarActual[r] /= uNumSongs;
    }
  }
  FOREACH_MultiPlayer(p) {
    for (int r = 0; r < RadarCategory_TapsAndHolds; r++) {
      ssreturn.m_multiPlayer[p].m_radarPossible[r] /= uNumSongs;
      ssreturn.m_multiPlayer[p].m_radarActual[r] /= uNumSongs;
    }
  }
  return ssreturn;
}

void StatsManager::GetFinalEvalStageStats(StageStats& statsOut) const {
  statsOut.Init();
  statsOut = AccumPlayedStageStats(m_vPlayedStageStats);
}

void StatsManager::CalcAccumPlayedStageStats() {
  m_AccumPlayedStageStats = AccumPlayedStageStats(m_vPlayedStageStats);
}

/* This data is added to each player profile, and to the machine profile
 * per-player. */
void AddPlayerStatsToProfile(
    Profile* pProfile, const StageStats& ss, PlayerNumber pn) {
  if (pProfile == nullptr) {
    LOG->Warn(
        "SRC_AUDIT_FIX: AddPlayerStatsToProfile skipped null profile for "
        "player %d.",
        pn);
    return;
  }
  if (!IsValidPlayerNumber(pn)) {
    LOG->Warn(
        "SRC_AUDIT_FIX: AddPlayerStatsToProfile skipped invalid player %d.",
        pn);
    return;
  }
  if (!IsValidPlayMode(ss.m_playMode)) {
    LOG->Warn(
        "SRC_AUDIT_FIX: AddPlayerStatsToProfile skipped invalid play mode %d.",
        ss.m_playMode);
    return;
  }
  const PlayerStageStats& pss = ss.m_player[pn];
  if (!pss.m_bJoined) {
    return;
  }
  if (pss.m_pStyle == nullptr) {
    LOG->Warn(
        "SRC_AUDIT_FIX: AddPlayerStatsToProfile skipped player %d without "
        "style.",
        pn);
    return;
  }
  if (pss.m_iStepsPlayed < 0 ||
      pss.m_vpPossibleSteps.size() < static_cast<size_t>(pss.m_iStepsPlayed)) {
    LOG->Warn(
        "SRC_AUDIT_FIX: AddPlayerStatsToProfile skipped player %d with "
        "invalid steps count %d/%zu.",
        pn, pss.m_iStepsPlayed, pss.m_vpPossibleSteps.size());
    return;
  }

  StyleID sID;
  sID.FromStyle(pss.m_pStyle);

  const int iStepsToCount = std::min(
      pss.m_iStepsPlayed, static_cast<int>(pss.m_vpPossibleSteps.size()));
  for (int i = 0; i < iStepsToCount; i++) {
    Steps* pSteps = pss.m_vpPossibleSteps[i];
    if (pSteps == nullptr) {
      LOG->Warn(
          "SRC_AUDIT_FIX: AddPlayerStatsToProfile skipped null steps at %d "
          "for player %d.",
          i, pn);
      continue;
    }
    Difficulty dc = pSteps->GetDifficulty();
    if (!IsValidDifficulty(dc)) {
      LOG->Warn(
          "SRC_AUDIT_FIX: AddPlayerStatsToProfile skipped invalid difficulty "
          "%d for player %d.",
          dc, pn);
      continue;
    }

    SafeIncrementInt(
        pProfile->m_iNumSongsPlayedByPlayMode[ss.m_playMode],
        "AddPlayerStatsToProfile songs by play mode");
    SafeIncrementInt(
        pProfile->m_iNumSongsPlayedByStyle[sID],
        "AddPlayerStatsToProfile songs by style");
    SafeIncrementInt(
        pProfile->m_iNumSongsPlayedByDifficulty[dc],
        "AddPlayerStatsToProfile songs by difficulty");

    int iMeter = std::clamp(pSteps->GetMeter(), 0, MAX_METER);
    SafeIncrementInt(
        pProfile->m_iNumSongsPlayedByMeter[iMeter],
        "AddPlayerStatsToProfile songs by meter");
  }

  SafeAddInt(
      pProfile->m_iTotalDancePoints,
      std::max(0, pss.m_iActualDancePoints),
      "AddPlayerStatsToProfile total dance points");

  if (ss.m_Stage == Stage_Extra1 || ss.m_Stage == Stage_Extra2) {
    if (pss.m_bFailed) {
      SafeIncrementInt(
          pProfile->m_iNumExtraStagesFailed,
          "AddPlayerStatsToProfile extra stages failed");
    } else {
      SafeIncrementInt(
          pProfile->m_iNumExtraStagesPassed,
          "AddPlayerStatsToProfile extra stages passed");
    }
  }

  // If you fail in a course, you passed all but the final song.
  // FIXME: Not true.  If playing with 2 players, one player could have failed
  // earlier.
  if (!pss.m_bFailed) {
    SafeIncrementInt(
        pProfile->m_iNumStagesPassedByPlayMode[ss.m_playMode],
        "AddPlayerStatsToProfile stages passed by play mode");
    Grade grade = pss.GetGrade();
    if (IsValidGrade(grade)) {
      SafeIncrementInt(
          pProfile->m_iNumStagesPassedByGrade[grade],
          "AddPlayerStatsToProfile stages passed by grade");
    } else {
      LOG->Warn(
          "SRC_AUDIT_FIX: AddPlayerStatsToProfile skipped invalid grade %d "
          "for player %d.",
          grade, pn);
    }
  }
}

std::unique_ptr<XNode> MakeRecentScoreNode(
    const StageStats& ss, Course* pCourse, Trail* pTrail,
    const PlayerStageStats& pss, MultiPlayer mp, const std::string& stageGuid) {
  std::unique_ptr<XNode> pNode;
  if (IsCoursePlayMode(ss.m_playMode)) {
    if (pCourse == nullptr || pTrail == nullptr) {
      LOG->Warn(
          "SRC_AUDIT_FIX: MakeRecentScoreNode skipped course score because "
          "course=%p trail=%p.",
          static_cast<void*>(pCourse), static_cast<void*>(pTrail));
      return nullptr;
    }
    pNode.reset(new XNode("HighScoreForACourseAndTrail"));

    CourseID courseID;
    courseID.FromCourse(pCourse);
    pNode->AppendChild(courseID.CreateNode());

    TrailID trailID;
    trailID.FromTrail(pTrail);
    pNode->AppendChild(trailID.CreateNode());

  } else {
    if (!HasSongRecentScoreContext(ss, pss, "MakeRecentScoreNode")) {
      return nullptr;
    }
    pNode.reset(new XNode("HighScoreForASongAndSteps"));

    SongID songID;
    songID.FromSong(ss.m_vpPossibleSongs[0]);
    pNode->AppendChild(songID.CreateNode());

    StepsID stepsID;
    stepsID.FromSteps(pss.m_vpPossibleSteps[0]);
    pNode->AppendChild(stepsID.CreateNode());
  }

  XNode* pHighScore = pss.m_HighScore.CreateNode();
  pHighScore->AppendChild("Pad", mp);
  pHighScore->AppendChild("StageGuid", stageGuid);
  pHighScore->AppendChild("Guid", CryptManager::GenerateRandomUUID());

  pNode->AppendChild(pHighScore);

  return pNode;
}

void StatsManager::CommitStatsToProfiles(const StageStats* pSS) {
  if (pSS == nullptr) {
    LOG->Warn("SRC_AUDIT_FIX: CommitStatsToProfiles skipped null StageStats.");
    return;
  }
  if (PROFILEMAN == nullptr) {
    LOG->Warn("SRC_AUDIT_FIX: CommitStatsToProfiles skipped without PROFILEMAN.");
    return;
  }
  Profile* pMachineProfile = PROFILEMAN->GetMachineProfile();
  if (pMachineProfile == nullptr) {
    LOG->Warn(
        "SRC_AUDIT_FIX: CommitStatsToProfiles continuing without machine "
        "profile.");
  }

  // Add step totals.  Use radarActual, since the player might have failed part
  // way through the song, in which case we don't want to give credit for the
  // rest of the song.
  FOREACH_HumanPlayer(pn) {
    int iNumTapsAndHolds = SafeNonNegativeInt(
        pSS->m_player[pn].m_radarActual[RadarCategory_TapsAndHolds],
        "CommitStatsToProfiles taps");
    int iNumJumps = SafeNonNegativeInt(
        pSS->m_player[pn].m_radarActual[RadarCategory_Jumps],
        "CommitStatsToProfiles jumps");
    int iNumHolds = SafeNonNegativeInt(
        pSS->m_player[pn].m_radarActual[RadarCategory_Holds],
        "CommitStatsToProfiles holds");
    int iNumRolls = SafeNonNegativeInt(
        pSS->m_player[pn].m_radarActual[RadarCategory_Rolls],
        "CommitStatsToProfiles rolls");
    int iNumMines = SafeNonNegativeInt(
        pSS->m_player[pn].m_radarActual[RadarCategory_Mines],
        "CommitStatsToProfiles mines");
    int iNumHands = SafeNonNegativeInt(
        pSS->m_player[pn].m_radarActual[RadarCategory_Hands],
        "CommitStatsToProfiles hands");
    int iNumLifts = SafeNonNegativeInt(
        pSS->m_player[pn].m_radarActual[RadarCategory_Lifts],
        "CommitStatsToProfiles lifts");
    float fCaloriesBurned = SafeFiniteFloat(
        pSS->m_player[pn].m_fCaloriesBurned,
        "CommitStatsToProfiles calories");
    Profile* pPlayerProfile = PROFILEMAN->GetProfile(pn);
    if (pPlayerProfile != nullptr && PROFILEMAN->IsPersistentProfile(pn)) {
      pPlayerProfile->AddStepTotals(
          iNumTapsAndHolds, iNumJumps, iNumHolds, iNumRolls, iNumMines,
          iNumHands, iNumLifts, fCaloriesBurned);
    }
    if (pMachineProfile != nullptr) {
      pMachineProfile->AddStepTotals(
          iNumTapsAndHolds, iNumJumps, iNumHolds, iNumRolls, iNumMines,
          iNumHands, iNumLifts, fCaloriesBurned);
    }
  }

  int iGameplaySeconds = SafeNonNegativeInt(
      pSS->m_fGameplaySeconds, "CommitStatsToProfiles gameplay seconds");

  const int songsPlayed =
      SafeNonNegativeSize(pSS->m_vpPlayedSongs.size(),
                          "CommitStatsToProfiles songs played");

  if (pMachineProfile != nullptr) {
    SafeAddInt(
        pMachineProfile->m_iTotalGameplaySeconds, iGameplaySeconds,
        "CommitStatsToProfiles machine gameplay seconds");
    SafeAddInt(
        pMachineProfile->m_iNumTotalSongsPlayed, songsPlayed,
        "CommitStatsToProfiles machine total songs");
  }

  const bool bMultiplayer = GAMESTATE != nullptr && GAMESTATE->m_bMultiplayer;
  if (!bMultiplayer)  // FIXME
  {
    FOREACH_HumanPlayer(pn) {
      Profile* pPlayerProfile = PROFILEMAN->GetProfile(pn);
      if (pPlayerProfile) {
        const int playerGameplaySeconds = SafeNonNegativeInt(
            pSS->m_player[pn].m_fAliveSeconds > 0.0f
                ? pSS->m_player[pn].m_fAliveSeconds
                : pSS->m_fGameplaySeconds,
            "CommitStatsToProfiles player gameplay seconds");
        SafeAddInt(
            pPlayerProfile->m_iTotalGameplaySeconds, playerGameplaySeconds,
            "CommitStatsToProfiles player gameplay seconds total");
        SafeAddInt(
            pPlayerProfile->m_iNumTotalSongsPlayed, songsPlayed,
            "CommitStatsToProfiles player total songs");
      }

      if (pMachineProfile != nullptr) {
        LOG->Trace("Adding stats to machine profile...");
        AddPlayerStatsToProfile(pMachineProfile, *pSS, pn);
      }

      if (pPlayerProfile) {
        LOG->Trace("Adding stats to player profile...");
        AddPlayerStatsToProfile(pPlayerProfile, *pSS, pn);
      }

      // No marathons etc for now...
      if (g_PadmissEnabled.Get() && pSS->m_playMode == PLAY_MODE_REGULAR) {
        SavePadmissScore(pSS, pn);
      }
    }
  }

  // Not sure what the Save/Upload folder was originally for, but the files
  // in it just accumulate uselessly, wasting several seconds when finishing
  // a song.  So this pref disables it. -Kyz
  if (PREFSMAN != nullptr && !PREFSMAN->m_DisableUploadDir) {
    SaveUploadFile(pSS);
  } else if (PREFSMAN == nullptr) {
    LOG->Warn("SRC_AUDIT_FIX: CommitStatsToProfiles skipped upload without PREFSMAN.");
  }

  // FileCopy( "Data/TempTestGroups.xml", "Save/Upload/data.xml" );
}

void StatsManager::SaveUploadFile(const StageStats* pSS) {
  if (pSS == nullptr) {
    LOG->Warn("SRC_AUDIT_FIX: SaveUploadFile skipped null StageStats.");
    return;
  }
  if (PROFILEMAN == nullptr) {
    LOG->Warn("SRC_AUDIT_FIX: SaveUploadFile skipped without PROFILEMAN.");
    return;
  }
  Profile* pMachineProfile = PROFILEMAN->GetMachineProfile();
  if (pMachineProfile == nullptr) {
    LOG->Warn("SRC_AUDIT_FIX: SaveUploadFile skipped without machine profile.");
    return;
  }

  // Save recent scores
  std::unique_ptr<XNode> xml(new XNode("Stats"));
  xml->AppendChild("MachineGuid", pMachineProfile->m_sGuid);

  XNode* recent = nullptr;
  const bool isCourseMode = IsCoursePlayMode(pSS->m_playMode);
  Course* currentCourse =
      isCourseMode && GAMESTATE != nullptr ? GAMESTATE->m_pCurCourse.Get()
                                           : nullptr;
  const std::string stageGuid =
      GAMESTATE != nullptr && !GAMESTATE->m_sStageGUID.empty()
          ? GAMESTATE->m_sStageGUID
          : CryptManager::GenerateRandomUUID();
  if (isCourseMode) {
    recent = xml->AppendChild(new XNode("RecentCourseScores"));
  } else {
    recent = xml->AppendChild(new XNode("RecentSongScores"));
  }

  int recentScoreCount = 0;
  const bool bMultiplayer = GAMESTATE != nullptr && GAMESTATE->m_bMultiplayer;
  if (!bMultiplayer) {
    FOREACH_HumanPlayer(p) {
      if (pSS->m_player[p].m_HighScore.IsEmpty()) {
        continue;
      }
      Trail* trail = GAMESTATE != nullptr ? GAMESTATE->m_pCurTrail[p].Get()
                                          : nullptr;
      std::unique_ptr<XNode> scoreNode = MakeRecentScoreNode(
          *pSS, currentCourse, trail, pSS->m_player[p], MultiPlayer_Invalid,
          stageGuid);
      if (scoreNode) {
        recent->AppendChild(scoreNode.release());
        ++recentScoreCount;
      }
    }
  } else {
    FOREACH_EnabledMultiPlayer(mp) {
      if (pSS->m_multiPlayer[mp].m_HighScore.IsEmpty()) {
        continue;
      }
      PlayerNumber master =
          GAMESTATE != nullptr ? GAMESTATE->GetMasterPlayerNumber()
                               : PLAYER_INVALID;
      Trail* pTrail =
          IsValidPlayerNumber(master) ? GAMESTATE->m_pCurTrail[master].Get()
                                      : nullptr;
      std::unique_ptr<XNode> scoreNode =
          MakeRecentScoreNode(
              *pSS, currentCourse, pTrail, pSS->m_multiPlayer[mp], mp,
              stageGuid);
      if (scoreNode) {
        recent->AppendChild(scoreNode.release());
        ++recentScoreCount;
      }
    }
  }

  if (recentScoreCount == 0) {
    LOG->Warn("SRC_AUDIT_FIX: SaveUploadFile skipped empty recent score file.");
    return;
  }

  std::string sDate = DateTime::GetNowDate().GetString();
  Replace(sDate, ":", "-");

  const std::string UPLOAD_DIR = "/Save/Upload/";
  std::string sFileNameNoExtension =
      Profile::MakeUniqueFileNameNoExtension(UPLOAD_DIR, sDate + " ");
  std::string fn = UPLOAD_DIR + sFileNameNoExtension + ".xml";

  bool bSaved = XmlFileUtil::SaveToFile(xml.get(), fn, "", false);

  if (bSaved) {
    std::string sStatsXmlSigFile = fn + SIGNATURE_APPEND;
    if (!CryptManager::SignFileToFile(fn, sStatsXmlSigFile)) {
      LOG->Warn(
          "SRC_AUDIT_FIX: SaveUploadFile failed to sign %s.",
          fn.c_str());
    }
  } else {
    LOG->Warn("SRC_AUDIT_FIX: SaveUploadFile failed to write %s.",
              fn.c_str());
  }
}

void StatsManager::SavePadmissScore(const StageStats* pSS, PlayerNumber pn) {
  if (pSS == nullptr || !IsValidPlayerNumber(pn)) {
    LOG->Warn(
        "SRC_AUDIT_FIX: SavePadmissScore skipped invalid input stats=%p "
        "player=%d.",
        static_cast<const void*>(pSS), pn);
    return;
  }
  if (GAMESTATE == nullptr || PROFILEMAN == nullptr) {
    LOG->Warn(
        "SRC_AUDIT_FIX: SavePadmissScore skipped without GAMESTATE/PROFILEMAN.");
    return;
  }
  if (GAMESTATE->m_pPlayerState[pn] == nullptr) {
    LOG->Warn(
        "SRC_AUDIT_FIX: SavePadmissScore skipped player %d without "
        "PlayerState.",
        pn);
    return;
  }
  const PlayerStageStats* playerStats = &pSS->m_player[pn];
  if (!IsValidPlayerNumber(playerStats->m_player_number) ||
      playerStats->m_player_number != pn) {
    LOG->Warn(
        "SRC_AUDIT_FIX: SavePadmissScore skipped mismatched player stat index "
        "%d for player %d.",
        playerStats->m_player_number, pn);
    return;
  }
  Profile* pp = PROFILEMAN->GetProfile(playerStats->m_player_number);
  if (pp == nullptr) {
    LOG->Warn(
        "SRC_AUDIT_FIX: SavePadmissScore skipped player %d without profile.",
        pn);
    return;
  }
  if (playerStats->m_vpPossibleSteps.empty() ||
      playerStats->m_vpPossibleSteps[0] == nullptr) {
    LOG->Warn(
        "SRC_AUDIT_FIX: SavePadmissScore skipped player %d without steps.",
        pn);
    return;
  }
  Steps* steps = playerStats->m_vpPossibleSteps[0];  // XXX Courses and such
  Song* song = steps->m_pSong;
  if (song == nullptr) {
    LOG->Warn(
        "SRC_AUDIT_FIX: SavePadmissScore skipped player %d because steps have "
        "no song.",
        pn);
    return;
  }

  std::unique_ptr<XNode> xml(new XNode("SongScore"));

  std::string sDate = DateTime::GetNowDate().GetString();
  Replace(sDate, ":", "-");

  XNode* taps = xml->AppendChild("TapNoteScores");
  FOREACH_ENUM(TapNoteScore, tns)
  if (tns != TNS_None) {
    taps->AppendChild(
        TapNoteScoreToString(tns), playerStats->m_iTapNoteScores[tns]);
  }

  XNode* radar_actual = xml->AppendChild("RadarActual");
  radar_actual->AppendChild(playerStats->m_radarActual.CreateNode(true, false));

  XNode* radar_possible = xml->AppendChild("RadarPossible");
  radar_possible->AppendChild(
      playerStats->m_radarPossible.CreateNode(true, false));

  xml->AppendChild(
      "ScoreValue",
      SafeFiniteFloat(
          playerStats->GetPercentDancePoints(), "Padmiss percent score"));
  xml->AppendChild("PlayerNumber", playerStats->m_player_number);
  xml->AppendChild("PlayerName", pp->m_sDisplayName);
  xml->AppendChild("PlayerGuid", pp->m_sGuid);

  const bool wasNoteDataFilled = steps->IsNoteDataFilled();
  steps->Decompress();  // Hashing won't work unless the steps are decompressed
  XNode* stepdata = xml->AppendChild("Steps");
  stepdata->AppendChild("Hash", steps->GetHash());
  stepdata->AppendChild("Meter", steps->GetMeter());
  stepdata->AppendChild("StepArtist", steps->GetCredit());
  stepdata->AppendChild("StepsType", steps->m_StepsTypeStr);
  RageFileObjMem f;
  std::vector<Steps*> stepv;
  stepv.push_back(steps);
  NotesWriterSM::Write(f, *song, stepv);
  if (!wasNoteDataFilled) {
    steps->Compress();
  }
  stepdata->AppendChild("StepData", f.GetString());

  XNode* songdata = xml->AppendChild("SongData");
  songdata->AppendChild("Title", song->m_sMainTitle);
  songdata->AppendChild("TitleTranslit", song->m_sMainTitleTranslit);
  songdata->AppendChild("SubTitle", song->m_sSubTitle);
  songdata->AppendChild("SubTitleTranslit", song->m_sSubTitleTranslit);
  songdata->AppendChild("Artist", song->m_sArtist);
  songdata->AppendChild("ArtistTranslit", song->m_sArtistTranslit);
  songdata->AppendChild(
      "Duration",
      SafeFiniteFloat(song->m_fMusicLengthSeconds, "Padmiss song duration"));

  const PlayerOptions& opts =
      GAMESTATE->m_pPlayerState[pn]->m_PlayerOptions.Get(ModsLevel_Preferred);
  XNode* mods = xml->AppendChild("Mods");
  mods->AppendChild(
      "MusicRate", SafeFiniteFloat(pSS->m_fMusicRate, "Padmiss music rate"));
#define ADD_BOOLEAN_OPTION(parent, name, opts)     \
  do {                                             \
    if (opts[PlayerOptions::name]) {               \
      parent->AppendChild(#name);                  \
    }                                              \
  } while (0)

  XNode* turns = mods->AppendChild("Turns");
  ADD_BOOLEAN_OPTION(turns, TURN_MIRROR, opts.m_bTurns);
  ADD_BOOLEAN_OPTION(turns, TURN_LRMIRROR, opts.m_bTurns);
  ADD_BOOLEAN_OPTION(turns, TURN_UDMIRROR, opts.m_bTurns);
  ADD_BOOLEAN_OPTION(turns, TURN_BACKWARDS, opts.m_bTurns);
  ADD_BOOLEAN_OPTION(turns, TURN_LEFT, opts.m_bTurns);
  ADD_BOOLEAN_OPTION(turns, TURN_RIGHT, opts.m_bTurns);
  ADD_BOOLEAN_OPTION(turns, TURN_SHUFFLE, opts.m_bTurns);
  ADD_BOOLEAN_OPTION(turns, TURN_SOFT_SHUFFLE, opts.m_bTurns);
  ADD_BOOLEAN_OPTION(turns, TURN_SUPER_SHUFFLE, opts.m_bTurns);

  XNode* transforms = mods->AppendChild("Transforms");
  ADD_BOOLEAN_OPTION(transforms, TRANSFORM_NOHOLDS, opts.m_bTransforms);
  ADD_BOOLEAN_OPTION(transforms, TRANSFORM_NOROLLS, opts.m_bTransforms);
  ADD_BOOLEAN_OPTION(transforms, TRANSFORM_NOMINES, opts.m_bTransforms);
  ADD_BOOLEAN_OPTION(transforms, TRANSFORM_LITTLE, opts.m_bTransforms);
  ADD_BOOLEAN_OPTION(transforms, TRANSFORM_WIDE, opts.m_bTransforms);
  ADD_BOOLEAN_OPTION(transforms, TRANSFORM_BIG, opts.m_bTransforms);
  ADD_BOOLEAN_OPTION(transforms, TRANSFORM_QUICK, opts.m_bTransforms);
  ADD_BOOLEAN_OPTION(transforms, TRANSFORM_BMRIZE, opts.m_bTransforms);
  ADD_BOOLEAN_OPTION(transforms, TRANSFORM_SKIPPY, opts.m_bTransforms);
  ADD_BOOLEAN_OPTION(transforms, TRANSFORM_MINES, opts.m_bTransforms);
  ADD_BOOLEAN_OPTION(transforms, TRANSFORM_ATTACKMINES, opts.m_bTransforms);
  ADD_BOOLEAN_OPTION(transforms, TRANSFORM_ECHO, opts.m_bTransforms);
  ADD_BOOLEAN_OPTION(transforms, TRANSFORM_STOMP, opts.m_bTransforms);
  ADD_BOOLEAN_OPTION(transforms, TRANSFORM_PLANTED, opts.m_bTransforms);
  ADD_BOOLEAN_OPTION(transforms, TRANSFORM_FLOORED, opts.m_bTransforms);
  ADD_BOOLEAN_OPTION(transforms, TRANSFORM_TWISTER, opts.m_bTransforms);
  ADD_BOOLEAN_OPTION(transforms, TRANSFORM_HOLDROLLS, opts.m_bTransforms);
  ADD_BOOLEAN_OPTION(transforms, TRANSFORM_NOJUMPS, opts.m_bTransforms);
  ADD_BOOLEAN_OPTION(transforms, TRANSFORM_NOHANDS, opts.m_bTransforms);
  ADD_BOOLEAN_OPTION(transforms, TRANSFORM_NOLIFTS, opts.m_bTransforms);
  ADD_BOOLEAN_OPTION(transforms, TRANSFORM_NOFAKES, opts.m_bTransforms);
  ADD_BOOLEAN_OPTION(transforms, TRANSFORM_NOQUADS, opts.m_bTransforms);
  ADD_BOOLEAN_OPTION(transforms, TRANSFORM_NOSTRETCH, opts.m_bTransforms);

#define ADD_FLOAT_OPTION(parent, name, opts)          \
  do {                                                \
    float val = SafeFiniteFloat(                      \
        opts[PlayerOptions::name], "Padmiss " #name); \
    if (val != 0.0f) parent->AppendChild(#name, val); \
  } while (0)

  XNode* accels = mods->AppendChild("Accels");
  ADD_FLOAT_OPTION(accels, ACCEL_BOOST, opts.m_fAccels);
  ADD_FLOAT_OPTION(accels, ACCEL_BRAKE, opts.m_fAccels);
  ADD_FLOAT_OPTION(accels, ACCEL_WAVE, opts.m_fAccels);
  ADD_FLOAT_OPTION(accels, ACCEL_EXPAND, opts.m_fAccels);
  ADD_FLOAT_OPTION(accels, ACCEL_BOOMERANG, opts.m_fAccels);

  XNode* effects = mods->AppendChild("Effects");
  ADD_FLOAT_OPTION(effects, EFFECT_DRUNK, opts.m_fEffects);
  ADD_FLOAT_OPTION(effects, EFFECT_DIZZY, opts.m_fEffects);
  ADD_FLOAT_OPTION(effects, EFFECT_CONFUSION, opts.m_fEffects);
  ADD_FLOAT_OPTION(effects, EFFECT_MINI, opts.m_fEffects);
  ADD_FLOAT_OPTION(effects, EFFECT_TINY, opts.m_fEffects);
  ADD_FLOAT_OPTION(effects, EFFECT_FLIP, opts.m_fEffects);
  ADD_FLOAT_OPTION(effects, EFFECT_INVERT, opts.m_fEffects);
  ADD_FLOAT_OPTION(effects, EFFECT_TORNADO, opts.m_fEffects);
  ADD_FLOAT_OPTION(effects, EFFECT_TIPSY, opts.m_fEffects);
  ADD_FLOAT_OPTION(effects, EFFECT_BUMPY, opts.m_fEffects);
  ADD_FLOAT_OPTION(effects, EFFECT_BEAT, opts.m_fEffects);
  ADD_FLOAT_OPTION(effects, EFFECT_XMODE, opts.m_fEffects);
  ADD_FLOAT_OPTION(effects, EFFECT_TWIRL, opts.m_fEffects);
  ADD_FLOAT_OPTION(effects, EFFECT_ROLL, opts.m_fEffects);

  XNode* appearances = mods->AppendChild("Appearances");
  ADD_FLOAT_OPTION(appearances, APPEARANCE_HIDDEN, opts.m_fAppearances);
  ADD_FLOAT_OPTION(appearances, APPEARANCE_HIDDEN_OFFSET, opts.m_fAppearances);
  ADD_FLOAT_OPTION(appearances, APPEARANCE_SUDDEN, opts.m_fAppearances);
  ADD_FLOAT_OPTION(appearances, APPEARANCE_SUDDEN_OFFSET, opts.m_fAppearances);
  ADD_FLOAT_OPTION(appearances, APPEARANCE_STEALTH, opts.m_fAppearances);
  ADD_FLOAT_OPTION(appearances, APPEARANCE_BLINK, opts.m_fAppearances);
  ADD_FLOAT_OPTION(appearances, APPEARANCE_RANDOMVANISH, opts.m_fAppearances);

  XNode* scrolls = mods->AppendChild("Scrolls");
  ADD_FLOAT_OPTION(scrolls, SCROLL_REVERSE, opts.m_fScrolls);
  ADD_FLOAT_OPTION(scrolls, SCROLL_SPLIT, opts.m_fScrolls);
  ADD_FLOAT_OPTION(scrolls, SCROLL_ALTERNATE, opts.m_fScrolls);
  ADD_FLOAT_OPTION(scrolls, SCROLL_CROSS, opts.m_fScrolls);
  ADD_FLOAT_OPTION(scrolls, SCROLL_CENTERED, opts.m_fScrolls);

  mods->AppendChild("NoteSkin", opts.m_sNoteSkin);

  XNode* perspectives = mods->AppendChild("Perspectives");
  perspectives->AppendChild(
      "Tilt", SafeFiniteFloat(opts.m_fPerspectiveTilt, "Padmiss Tilt"));
  perspectives->AppendChild(
      "Skew", SafeFiniteFloat(opts.m_fSkew, "Padmiss Skew"));

  std::string speedModType;
  float speedModValue;
  if (opts.m_fTimeSpacing) {
    speedModType = "ConstantBPM";
    speedModValue =
        SafeFiniteFloat(opts.m_fScrollBPM, "Padmiss ConstantBPM");
  } else if (opts.m_fMaxScrollBPM) {
    speedModType = "MaxBPM";
    speedModValue = SafeFiniteFloat(opts.m_fMaxScrollBPM, "Padmiss MaxBPM");
  } else {
    speedModType = "Multiplier";
    speedModValue =
        SafeFiniteFloat(opts.m_fScrollSpeed, "Padmiss ScrollSpeed");
  }
  mods->AppendChild("ScrollSpeed", speedModValue)
      ->AppendAttr("Type", speedModType);

  XNode* timingWindows = xml->AppendChild("TimingWindows");
  FOREACH_ENUM(TimingWindow, tw)
  timingWindows->AppendChild(
      TimingWindowToString(tw),
      SafeFiniteFloat(Player::GetWindowSeconds(tw), "Padmiss timing window"));

#undef ADD_FLOAT_OPTION
#undef ADD_BOOLEAN_OPTION

  std::string dir = "/Save/Padmiss/";
  std::string fn =
      dir + Profile::MakeUniqueFileNameNoExtension(dir, sDate + " ") + ".xml";
  if (!XmlFileUtil::SaveToFile(xml.get(), fn, "", true)) {
    LOG->Warn("SRC_AUDIT_FIX: SavePadmissScore failed to write %s.",
              fn.c_str());
  }
}

void StatsManager::UnjoinPlayer(PlayerNumber pn) {
  if (!IsValidPlayerNumber(pn)) {
    LOG->Warn(
        "SRC_AUDIT_FIX: StatsManager::UnjoinPlayer ignored invalid player "
        "%d.",
        pn);
    return;
  }

  /* A player has been unjoined.  Clear his data from m_vPlayedStageStats, and
   * purge any m_vPlayedStageStats that no longer have any player data because
   * all of the players that were playing at the time have been unjoined. */
  m_CurStageStats.m_player[pn] = PlayerStageStats();
  for (StageStats& ss : m_vPlayedStageStats) {
    ss.m_player[pn] = PlayerStageStats();
  }

  for (int i = 0; i < (int)m_vPlayedStageStats.size(); ++i) {
    StageStats& ss = m_vPlayedStageStats[i];
    bool bIsActive = false;
    FOREACH_PlayerNumber(p) if (ss.m_player[p].m_bJoined) bIsActive = true;
    FOREACH_MultiPlayer(mp) if (ss.m_multiPlayer[mp].m_bJoined) bIsActive =
        true;
    if (bIsActive) {
      continue;
    }

    m_vPlayedStageStats.erase(m_vPlayedStageStats.begin() + i);
    --i;
  }
  CalcAccumPlayedStageStats();
}

void StatsManager::GetStepsInUse(std::set<Steps*>& apInUseOut) const {
  if (HasAnyJoinedPlayer(m_CurStageStats)) {
    AddStepsInUseFromStageStats(m_CurStageStats, apInUseOut);
  }
  for (int i = 0; i < (int)m_vPlayedStageStats.size(); ++i) {
    AddStepsInUseFromStageStats(m_vPlayedStageStats[i], apInUseOut);
  }
}

// lua start
#include "LuaBinding.h"

/** @brief Allow Lua to have access to the StatsManager. */
class LunaStatsManager : public Luna<StatsManager> {
 public:
  static int GetCurStageStats(T* p, lua_State* L) {
    p->m_CurStageStats.PushSelf(L);
    return 1;
  }
  static int GetPlayedStageStats(T* p, lua_State* L) {
    int iAgo = IArg(1);
    if (iAgo <= 0) {
      lua_pushnil(L);
      return 1;
    }
    if (p->m_vPlayedStageStats.size() >
        static_cast<size_t>(std::numeric_limits<int>::max())) {
      LOG->Warn(
          "SRC_AUDIT_FIX: GetPlayedStageStats has too many stage stats: %zu.",
          p->m_vPlayedStageStats.size());
      lua_pushnil(L);
      return 1;
    }
    int iIndex = static_cast<int>(p->m_vPlayedStageStats.size()) - iAgo;
    if (iIndex < 0 || iIndex >= (int)p->m_vPlayedStageStats.size()) {
      lua_pushnil(L);
      return 1;
    }

    p->m_vPlayedStageStats[iIndex].PushSelf(L);
    return 1;
  }
  static int Reset(T* p, lua_State* L) {
    p->Reset();
    return 0;
  }
  static int GetAccumPlayedStageStats(T* p, lua_State* L) {
    p->GetAccumPlayedStageStats().PushSelf(L);
    return 1;
  }
  static int GetFinalEvalStageStats(T* p, lua_State* L) {
    StageStats stats;
    p->GetFinalEvalStageStats(stats);
    stats.PushSelf(L);
    return 1;
  }
  static int GetFinalGrade(T* p, lua_State* L) {
    PlayerNumber pn = Enum::Check<PlayerNumber>(L, 1);

    if (!IsValidPlayerNumber(pn) || GAMESTATE == nullptr ||
        !GAMESTATE->IsHumanPlayer(pn)) {
      lua_pushnumber(L, Grade_NoData);
    } else {
      StageStats stats;
      p->GetFinalEvalStageStats(stats);
      lua_pushnumber(L, stats.m_player[pn].GetGrade());
    }
    return 1;
  }
  static int GetStagesPlayed(T* p, lua_State* L) {
    lua_pushnumber(L, p->m_vPlayedStageStats.size());
    return 1;
  }

  static int GetBestGrade(T* p, lua_State* L) {
    Grade g = NUM_Grade;
    bool found = false;
    FOREACH_EnabledPlayer(pn) {
      g = std::min(g, p->m_CurStageStats.m_player[pn].GetGrade());
      found = true;
    }
    if (!found) {
      g = Grade_NoData;
    }
    lua_pushnumber(L, g);
    return 1;
  }

  static int GetWorstGrade(T* p, lua_State* L) {
    Grade g = Grade_Tier01;
    bool found = false;
    FOREACH_EnabledPlayer(pn) {
      g = std::max(g, p->m_CurStageStats.m_player[pn].GetGrade());
      found = true;
    }
    if (!found) {
      g = Grade_NoData;
    }
    lua_pushnumber(L, g);
    return 1;
  }

  static int GetBestFinalGrade(T* t, lua_State* L) {
    Grade top_grade = Grade_Failed;
    bool foundHuman = false;
    StageStats stats;
    t->GetFinalEvalStageStats(stats);
    FOREACH_HumanPlayer(p) {
      foundHuman = true;
      // If this player failed any stage, then their final grade is an F.
      if (std::any_of(
              t->m_vPlayedStageStats.begin(),
              t->m_vPlayedStageStats.end(),
              [&](const StageStats& ss) { return ss.m_player[p].m_bFailed; })) {
        continue;
      }

      top_grade = std::min(top_grade, stats.m_player[p].GetGrade());
    }

    Enum::Push(L, foundHuman ? top_grade : Grade_NoData);
    return 1;
  }

  LunaStatsManager() {
    ADD_METHOD(GetCurStageStats);
    ADD_METHOD(GetPlayedStageStats);
    ADD_METHOD(GetAccumPlayedStageStats);
    ADD_METHOD(GetFinalEvalStageStats);
    ADD_METHOD(Reset);
    ADD_METHOD(GetFinalGrade);
    ADD_METHOD(GetStagesPlayed);
    ADD_METHOD(GetBestGrade);
    ADD_METHOD(GetWorstGrade);
    ADD_METHOD(GetBestFinalGrade);
  }
};

LUA_REGISTER_CLASS(StatsManager)
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
