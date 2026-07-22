#include "ScreenEvaluation.h"

#include <algorithm>
#include <cctype>
#include <climits>
#include <cmath>
#include <cstddef>
#include <cstdarg>
#include <cstdio>
#include <cstdlib>
#include <ctime>
#include <limits>
#include <string>
#include <vector>

#include "ActorUtil.h"
#include "AnnouncerManager.h"
#include "CodeDetector.h"
#include "Course.h"
#include "CryptManager.h"
#include "EnumHelper.h"
#include "GameConstantsAndTypes.h"
#include "GameInput.h"
#include "GameManager.h"
#include "GameSoundManager.h"
#include "GameState.h"
#include "Grade.h"
#include "HighScore.h"
#include "InputEventPlus.h"
#include "InputFilter.h"
#include "InputMapper.h"
#include "IniFile.h"
#include "LuaManager.h"
#include "MemoryCardManager.h"
#include "ModsGroup.h"
#include "OnlineSessionGuard.h"
#include "PlayerNumber.h"
#include "PlayerState.h"
#include "PrefsManager.h"
#include "Profile.h"
#include "ProfileManager.h"
#include "RageLog.h"
#include "RageUtil.h"
#include "RageUtil/RandomNumbers.h"
#include "ScoreKeeperNormal.h"
#include "Screen.h"
#include "ScreenManager.h"
#include "ScreenMessage.h"
#include "ScreenWithMenuElements.h"
#include "Song.h"
#include "SongManager.h"
#include "StatsManager.h"
#include "StepMania.h"
#include "Steps.h"
#include "ThemeManager.h"
#include "ThemeMetric.h"
#include "global.h"

static const char* JudgmentLineNames[] = {"W1", "W2",   "W3",   "W4",
                                          "W5", "Miss", "Held", "MaxCombo"};
XToString(JudgmentLine);
LuaXType(JudgmentLine);
XToLocalizedString(JudgmentLine);
LuaFunction(
    JudgmentLineToLocalizedString,
    JudgmentLineToLocalizedString(Enum::Check<JudgmentLine>(L, 1)));

static const char* DetailLineNames[NUM_DetailLine] = {
    "NumSteps", "Jumps", "Holds", "Mines", "Hands", "Rolls", "Lifts", "Fakes"};
XToString(DetailLine);

static ThemeMetric<TapNoteScore> g_MinScoreToMaintainCombo(
    "Gameplay", "MinScoreToMaintainCombo");
static const int NUM_SHOWN_RADAR_CATEGORIES = 5;

AutoScreenMessage(SM_PlayCheer);

REGISTER_SCREEN_CLASS(ScreenEvaluation);

namespace {
bool OnlineVerboseLogsEnabledFromThemePrefs() {
  static time_t lastRead = 0;
  static bool cached = false;

  const time_t now = time(nullptr);
  if (now == lastRead) {
    return cached;
  }

  lastRead = now;
  cached = false;

  if (PREFSMAN == nullptr) {
    return false;
  }

  IniFile ini;
  if (!ini.ReadFile("Save/ThemePrefs.ini")) {
    return false;
  }

  bool enabled = false;
  if (!ini.GetValue(
          PREFSMAN->m_sTheme,
          "ITGOnlineNetworkLogs",
          enabled)) {
    return false;
  }

  cached = enabled;
  return cached;
}

void OnlineTrace(const char* fmt, ...) {
  if (LOG == nullptr || !OnlineVerboseLogsEnabledFromThemePrefs()) {
    return;
  }

  va_list args;
  va_start(args, fmt);
  char buffer[2048];
  vsnprintf(buffer, sizeof(buffer), fmt, args);
  va_end(args);
  LOG->Trace("%s", buffer);
}

bool IsValidEvaluationPlayer(PlayerNumber pn) {
  return pn >= PLAYER_1 && pn < NUM_PLAYERS;
}

bool IsThemeRuntimeAvailable(const char* context) {
  if (THEME == nullptr || !THEME->IsThemeLoaded() || LUA == nullptr) {
    LOG->Warn(
        "SRC_AUDIT_FIX: %s used fallback because theme runtime is "
        "unavailable.",
        context);
    return false;
  }
  return true;
}

float GetEvaluationMetricF(
    const std::string& screenName, const std::string& metric, float fallback,
    bool requireNonNegative = false) {
  if (!IsThemeRuntimeAvailable("ScreenEvaluation metric float") ||
      screenName.empty()) {
    return fallback;
  }
  if (!THEME->HasMetric(screenName, metric)) {
    LOG->Warn(
        "SRC_AUDIT_FIX: ScreenEvaluation used fallback for missing theme "
        "metric %s::%s.",
        screenName.c_str(), metric.c_str());
    return fallback;
  }

  const float value = THEME->GetMetricF(screenName, metric);
  if (!std::isfinite(value) || (requireNonNegative && value < 0.0f)) {
    LOG->Warn(
        "SRC_AUDIT_FIX: ScreenEvaluation clamped invalid theme metric %s::%s "
        "value %f to %f.",
        screenName.c_str(), metric.c_str(), value, fallback);
    return fallback;
  }
  return value;
}

bool GetEvaluationMetricB(
    const std::string& screenName, const std::string& metric, bool fallback) {
  if (!IsThemeRuntimeAvailable("ScreenEvaluation metric bool") ||
      screenName.empty()) {
    return fallback;
  }
  if (!THEME->HasMetric(screenName, metric)) {
    LOG->Warn(
        "SRC_AUDIT_FIX: ScreenEvaluation used fallback for missing theme "
        "metric %s::%s.",
        screenName.c_str(), metric.c_str());
    return fallback;
  }
  return THEME->GetMetricB(screenName, metric);
}

std::string GetEvaluationMetricString(
    const std::string& screenName, const std::string& metric,
    const std::string& fallback) {
  if (!IsThemeRuntimeAvailable("ScreenEvaluation metric string") ||
      screenName.empty()) {
    return fallback;
  }
  if (!THEME->HasMetric(screenName, metric)) {
    LOG->Warn(
        "SRC_AUDIT_FIX: ScreenEvaluation used fallback for missing theme "
        "metric %s::%s.",
        screenName.c_str(), metric.c_str());
    return fallback;
  }

  std::string value = THEME->GetMetric(screenName, metric);
  return value.empty() ? fallback : value;
}

apActorCommands GetEvaluationMetricCommands(
    const std::string& screenName, const std::string& metric) {
  if (!IsThemeRuntimeAvailable("ScreenEvaluation metric command") ||
      screenName.empty()) {
    return apActorCommands();
  }
  if (!THEME->HasMetric(screenName, metric)) {
    return apActorCommands();
  }
  return THEME->GetMetricA(screenName, metric);
}

float ClampFiniteNonNegativeEvaluationFloat(
    float value, const char* field, float fallback = 0.0f) {
  if (!std::isfinite(value) || value < 0.0f) {
    LOG->Warn(
        "SRC_AUDIT_FIX: ScreenEvaluation normalized invalid %s value %f to "
        "%f.",
        field, value, fallback);
    return fallback;
  }
  return value;
}

int ClampNonNegativeEvaluationInt(int value, const char* field) {
  if (value < 0) {
    LOG->Warn(
        "SRC_AUDIT_FIX: ScreenEvaluation clamped negative %s value %i to 0.",
        field, value);
    return 0;
  }
  return value;
}

int AddNonNegativeEvaluationIntSaturated(
    int current, int add, const char* field) {
  current = ClampNonNegativeEvaluationInt(current, field);
  add = ClampNonNegativeEvaluationInt(add, field);
  if (add > std::numeric_limits<int>::max() - current) {
    LOG->Warn(
        "SRC_AUDIT_FIX: ScreenEvaluation saturated %s integer sum %i + %i.",
        field, current, add);
    return std::numeric_limits<int>::max();
  }
  return current + add;
}

int RoundNonNegativeRadarValue(float value, const char* field) {
  value = ClampFiniteNonNegativeEvaluationFloat(value, field);
  if (value > static_cast<float>(std::numeric_limits<int>::max())) {
    LOG->Warn(
        "SRC_AUDIT_FIX: ScreenEvaluation saturated %s radar value %f.",
        field, value);
    return std::numeric_limits<int>::max();
  }
  return static_cast<int>(std::lrint(value));
}

bool IsSupportedIntegerConversion(char c) {
  return c == 'd' || c == 'i';
}

bool DetailLineFormatAcceptsTwoIntegers(const std::string& format) {
  int conversions = 0;
  for (size_t i = 0; i < format.size(); ++i) {
    if (format[i] != '%') {
      continue;
    }
    if (i + 1 < format.size() && format[i + 1] == '%') {
      ++i;
      continue;
    }

    ++i;
    while (i < format.size() &&
           (format[i] == '-' || format[i] == '+' || format[i] == ' ' ||
            format[i] == '#' || format[i] == '0')) {
      ++i;
    }
    while (i < format.size() &&
           std::isdigit(static_cast<unsigned char>(format[i]))) {
      ++i;
    }
    if (i < format.size() && format[i] == '.') {
      ++i;
      while (i < format.size() &&
             std::isdigit(static_cast<unsigned char>(format[i]))) {
        ++i;
      }
    }
    if (i < format.size() &&
        (format[i] == 'h' || format[i] == 'l' || format[i] == 'j' ||
         format[i] == 'z' || format[i] == 't')) {
      return false;
    }
    if (i >= format.size() || !IsSupportedIntegerConversion(format[i])) {
      return false;
    }
    ++conversions;
  }
  return conversions == 2;
}

std::string FormatDetailLine(
    const std::string& format, int actual, int possible) {
  if (!DetailLineFormatAcceptsTwoIntegers(format)) {
    LOG->Warn(
        "SRC_AUDIT_FIX: ScreenEvaluation used fallback for invalid "
        "DetailLineFormat '%s'.",
        format.c_str());
    return ssprintf("%3d/%3d", actual, possible);
  }
  return ssprintf(format.c_str(), actual, possible);
}

void PlayEvaluationSoundPath(const std::string& path, const char* context) {
  if (SOUND == nullptr || path.empty()) {
    if (LOG != nullptr && SOUND == nullptr) {
      LOG->Trace(
          "ScreenEvaluation skipped %s sound because sound manager is "
          "unavailable.",
          context);
    }
    return;
  }
  SOUND->PlayOnceFromDir(path);
}

std::string GetEvaluationAnnouncerPath(const std::string& sound) {
  if (ANNOUNCER == nullptr) {
    return "";
  }
  return ANNOUNCER->GetPathTo(sound);
}

bool PlayerHasEvaluationStats(const StageStats* stageStats, PlayerNumber pn) {
  if (stageStats == nullptr || !IsValidEvaluationPlayer(pn)) {
    return false;
  }

  const PlayerStageStats& pss = stageStats->m_player[pn];
  return pss.m_bJoined || pss.m_iStepsPlayed > 0 ||
         !pss.m_vpPossibleSteps.empty();
}

std::vector<PlayerNumber> GetEvaluationPlayers(const StageStats* stageStats) {
  std::vector<PlayerNumber> players;
  FOREACH_PlayerNumber(p) {
    if (PlayerHasEvaluationStats(stageStats, p)) {
      players.push_back(p);
    }
  }

  if (players.empty() && GAMESTATE != nullptr) {
    FOREACH_PlayerNumber(p) {
      if (GAMESTATE->IsPlayerEnabled(p)) {
        players.push_back(p);
      }
    }
  }

  return players;
}

Song* GetPrimaryPlayedSong(StageStats* stageStats) {
  if (stageStats == nullptr) {
    return nullptr;
  }
  if (!stageStats->m_vpPlayedSongs.empty() &&
      stageStats->m_vpPlayedSongs[0] != nullptr) {
    return stageStats->m_vpPlayedSongs[0];
  }
  if (!stageStats->m_vpPossibleSongs.empty() &&
      stageStats->m_vpPossibleSongs[0] != nullptr) {
    return stageStats->m_vpPossibleSongs[0];
  }
  return nullptr;
}

bool IsEvaluationCourseMode(const StageStats* stageStats) {
  if (stageStats == nullptr) {
    return false;
  }
  switch (stageStats->m_playMode) {
    case PLAY_MODE_NONSTOP:
    case PLAY_MODE_ONI:
    case PLAY_MODE_ENDLESS:
      return true;
    case PLAY_MODE_REGULAR:
    case PLAY_MODE_BATTLE:
    case PLAY_MODE_RAVE:
      return false;
    default:
      LOG->Warn(
          "SRC_AUDIT_FIX: ScreenEvaluation treated invalid recorded play "
          "mode %i as non-course.",
          stageStats->m_playMode);
      return false;
  }
}

float GetBannerMetric(
    const std::string& screenName, const std::string& metric, float fallback) {
  const float value = GetEvaluationMetricF(screenName, metric, fallback, true);
  return value > 0.0f ? value : fallback;
}

bool ShouldIgnoreOnlineEvaluationNextScreen() {
  if (LUA == nullptr) {
    return ITGOnlineSessionGuard::IsObservedActive();
  }

  Lua* L = LUA->Get();
  if (L == nullptr) {
    return ITGOnlineSessionGuard::IsObservedActive();
  }

  const int stackTop = lua_gettop(L);
  bool onlineActive = false;
  bool hasActiveAnswer = false;
  const bool activeOk = LuaHelpers::RunExpression(
      L,
      "ITGOnline ~= nil and ITGOnline.HasOnlineSession ~= nil and ITGOnline:HasOnlineSession()",
      "ScreenEvaluation online active-session guard");
  if (activeOk && lua_isboolean(L, -1)) {
    onlineActive = lua_toboolean(L, -1);
    hasActiveAnswer = true;
  }
  lua_settop(L, stackTop);

  if (!hasActiveAnswer) {
    LUA->Release(L);
    OnlineTrace(
        "ITG Online: evaluation active-session gate failed; using observed "
        "state=%d.",
        ITGOnlineSessionGuard::IsObservedActive() ? 1 : 0);
    return ITGOnlineSessionGuard::IsObservedActive();
  }

  ITGOnlineSessionGuard::Observe(onlineActive);
  if (!onlineActive) {
    LUA->Release(L);
    return false;
  }

  bool exitRequested = false;
  const bool exitOk = LuaHelpers::RunExpression(
      L,
      "ITGOnline ~= nil and ITGOnline.onlineEvaluationExitRequested == true",
      "ScreenEvaluation online explicit-exit guard");
  if (exitOk && lua_isboolean(L, -1)) {
    exitRequested = lua_toboolean(L, -1);
  }
  lua_settop(L, stackTop);
  LUA->Release(L);

  if (!exitOk) {
    OnlineTrace(
        "ITG Online: evaluation exit-state gate failed; holding evaluation "
        "closed.");
    return true;
  }
  return !exitRequested;
}

bool TryHandleOnlineEvaluationNativeExit(const std::string& inputName) {
  if (LUA == nullptr) {
    return ITGOnlineSessionGuard::IsObservedActive();
  }

  Lua* L = LUA->Get();
  if (L == nullptr) {
    return ITGOnlineSessionGuard::IsObservedActive();
  }

  const int stackTop = lua_gettop(L);
  bool onlineActive = false;
  bool hasActiveAnswer = false;
  bool handled = false;
  bool shouldConsume = false;
  const bool activeOk = LuaHelpers::RunExpression(
      L,
      "ITGOnline ~= nil and ITGOnline.HasOnlineSession ~= nil and ITGOnline:HasOnlineSession()",
      "ScreenEvaluation online native exit active check");
  if (activeOk) {
    if (lua_isboolean(L, -1)) {
      LuaHelpers::Pop(L, onlineActive);
      hasActiveAnswer = true;
    } else {
      lua_pop(L, 1);
    }
  }

  if (hasActiveAnswer) {
    ITGOnlineSessionGuard::Observe(onlineActive);
  }

  if (!hasActiveAnswer) {
    shouldConsume = ITGOnlineSessionGuard::IsObservedActive();
    if (shouldConsume) {
      OnlineTrace(
          "ITG Online: native evaluation exit active-session gate failed; "
          "holding input closed.");
    }
  }

  if (onlineActive) {
    const bool handlerOk = LuaHelpers::RunExpression(
        L,
        "ITGOnlineReturnToLobbyFromEvaluation ~= nil "
        "and ITGOnlineReturnToLobbyFromEvaluation('screen_evaluation_native_"
        "input') == true",
        "ScreenEvaluation online native exit handler");
    if (handlerOk) {
      if (lua_isboolean(L, -1)) {
        LuaHelpers::Pop(L, handled);
      } else {
        lua_pop(L, 1);
      }
    }
    shouldConsume = handlerOk && handled;
    if (!handlerOk) {
      shouldConsume = true;
      OnlineTrace(
          "ITG Online: native evaluation exit handler failed; holding input "
          "closed.");
    }
    OnlineTrace("ITG Online: ScreenEvaluation consumed native %s input online "
        "handled=%i.",
        inputName.c_str(), handled ? 1 : 0);
  }

  lua_settop(L, stackTop);
  LUA->Release(L);
  return shouldConsume;
}
}  // namespace

ScreenEvaluation::ScreenEvaluation() {
  if (GAMESTATE != nullptr) {
    m_pTokenAdjustmentGameState = GAMESTATE;
    m_bPreviousTokenAdjustment =
        GAMESTATE->m_AdjustTokensBySongCostForFinalStageCheck;
    GAMESTATE->m_AdjustTokensBySongCostForFinalStageCheck = false;
  }
}

ScreenEvaluation::~ScreenEvaluation() {
  if (GAMESTATE != nullptr && GAMESTATE == m_pTokenAdjustmentGameState) {
    GAMESTATE->m_AdjustTokensBySongCostForFinalStageCheck =
        m_bPreviousTokenAdjustment;
  }
}

void ScreenEvaluation::Init() {
  LOG->Trace("ScreenEvaluation::Init()");

  // debugging
  // Only fill StageStats with fake info if we're the InitialScreen
  // (i.e. StageStats not already filled)
  if (PREFSMAN != nullptr && PREFSMAN->m_sTestInitialScreen.Get() == m_sName) {
    if (PROFILEMAN == nullptr || STATSMAN == nullptr || GAMESTATE == nullptr ||
        GAMEMAN == nullptr || SONGMAN == nullptr) {
      LOG->Warn(
          "SRC_AUDIT_FIX: ScreenEvaluation skipped fake stats because a "
          "required manager is unavailable.");
    } else if (Song* debugSong = SONGMAN->GetRandomSong()) {
      const std::vector<Steps*>& debugSteps = debugSong->GetAllSteps();
      if (debugSteps.empty() || debugSteps[0] == nullptr) {
        LOG->Warn(
            "SRC_AUDIT_FIX: ScreenEvaluation skipped fake stats for song with "
            "no usable steps.");
      } else {
        PROFILEMAN->LoadFirstAvailableProfile(PLAYER_1);
        PROFILEMAN->LoadFirstAvailableProfile(PLAYER_2);

        STATSMAN->m_vPlayedStageStats.clear();
        STATSMAN->m_vPlayedStageStats.push_back(StageStats());
        StageStats& ss = STATSMAN->m_vPlayedStageStats.back();

        GAMESTATE->m_PlayMode.Set(PLAY_MODE_REGULAR);
        GAMESTATE->SetCurrentStyle(
            GAMEMAN->GameAndStringToStyle(GAMEMAN->GetDefaultGame(), "versus"),
            PLAYER_INVALID);
        ss.m_playMode = GAMESTATE->m_PlayMode;
        ss.m_Stage = Stage_1st;
        enum_add(ss.m_Stage, rand() % 3);
        ss.m_EarnedExtraStage =
            (EarnedExtraStage)(rand() % NUM_EarnedExtraStage);
        GAMESTATE->SetMasterPlayerNumber(PLAYER_1);
        GAMESTATE->m_pCurSong.Set(debugSong);
        ss.m_vpPlayedSongs.push_back(debugSong);
        ss.m_vpPossibleSongs.push_back(debugSong);
        GAMESTATE->m_pCurCourse.Set(SONGMAN->GetRandomCourse());
        GAMESTATE->m_iCurrentStageIndex = 0;
        FOREACH_ENUM(PlayerNumber, p)
        GAMESTATE->m_iPlayerStageTokens[p] = 1;

        FOREACH_PlayerNumber(p) {
          ss.m_player[p].m_pStyle = GAMESTATE->GetCurrentStyle(p);
          if (GAMESTATE->m_pPlayerState[p] != nullptr && RandomInt(2)) {
            PO_GROUP_ASSIGN_N(
                GAMESTATE->m_pPlayerState[p]->m_PlayerOptions,
                ModsLevel_Stage, m_bTransforms, PlayerOptions::TRANSFORM_ECHO,
                true);  // show "disqualified"
          }
          SO_GROUP_ASSIGN(
              GAMESTATE->m_SongOptions, ModsLevel_Stage, m_fMusicRate, 1.1f);

          GAMESTATE->JoinPlayer(p);
          GAMESTATE->m_pCurSteps[p].Set(debugSteps[0]);
          if (GAMESTATE->m_pCurCourse) {
            std::vector<Trail*> apTrails;
            GAMESTATE->m_pCurCourse->GetAllTrails(apTrails);
            if (!apTrails.empty()) {
              GAMESTATE->m_pCurTrail[p].Set(apTrails[0]);
            }
          }
          ss.m_player[p].m_vpPossibleSteps.push_back(
              GAMESTATE->m_pCurSteps[p]);
          ss.m_player[p].m_iStepsPlayed = 1;

          if (GAMESTATE->m_pPlayerState[p] != nullptr) {
            PO_GROUP_ASSIGN(
                GAMESTATE->m_pPlayerState[p]->m_PlayerOptions,
                ModsLevel_Stage, m_fScrollSpeed, 2.0f);
            PO_GROUP_CALL(
                GAMESTATE->m_pPlayerState[p]->m_PlayerOptions,
                ModsLevel_Stage, ChooseRandomModifiers);
          }
        }

        for (float f = 0; f < 100.0f; f += 1.0f) {
          float fP1 = std::fmod(f / 100 * 4 + .3f, 1);
          ss.m_player[PLAYER_1].SetLifeRecordAt(fP1, f);
          ss.m_player[PLAYER_2].SetLifeRecordAt(1 - fP1, f);
        }

        FOREACH_PlayerNumber(p) {
          float fSeconds = debugSong->GetStepsSeconds();
          fSeconds = ClampFiniteNonNegativeEvaluationFloat(
              fSeconds, "debug steps seconds");
          ss.m_player[p].m_iActualDancePoints = RandomInt(3);
          ss.m_player[p].m_iPossibleDancePoints = 2;
          if (RandomInt(2)) {
            ss.m_player[p].m_iCurCombo = RandomInt(15000);
          } else {
            ss.m_player[p].m_iCurCombo = 0;
          }
          ss.m_player[p].UpdateComboList(0, true);

          ss.m_player[p].m_iCurCombo += 50;
          ss.m_player[p].UpdateComboList(0.10f * fSeconds, false);

          ss.m_player[p].m_iCurCombo = 0;
          ss.m_player[p].UpdateComboList(0.15f * fSeconds, false);
          ss.m_player[p].m_iCurCombo = 1;
          ss.m_player[p].UpdateComboList(0.25f * fSeconds, false);
          ss.m_player[p].m_iCurCombo = 50;
          ss.m_player[p].UpdateComboList(0.35f * fSeconds, false);
          ss.m_player[p].m_iCurCombo = 0;
          ss.m_player[p].UpdateComboList(0.45f * fSeconds, false);
          ss.m_player[p].m_iCurCombo = 1;
          ss.m_player[p].UpdateComboList(0.50f * fSeconds, false);
          ss.m_player[p].m_iCurCombo = 100;
          ss.m_player[p].UpdateComboList(1.00f * fSeconds, false);
          if (RandomInt(5) == 0) {
            ss.m_player[p].m_bFailed = true;
          }
          ss.m_player[p].m_iTapNoteScores[TNS_W1] = RandomInt(3);
          ss.m_player[p].m_iTapNoteScores[TNS_W2] = RandomInt(3);
          ss.m_player[p].m_iTapNoteScores[TNS_W3] = RandomInt(3);
          ss.m_player[p].m_iPossibleGradePoints =
              4 * ScoreKeeperNormal::TapNoteScoreToGradePoints(TNS_W1, false);
          ss.m_player[p].m_fLifeRemainingSeconds = randomf(90, 580);
          ss.m_player[p].m_iScore = rand() % (900 * 1000 * 1000);
          ss.m_player[p].m_iPersonalHighScoreIndex = (rand() % 3) - 1;
          ss.m_player[p].m_iMachineHighScoreIndex = (rand() % 3) - 1;
          ss.m_player[p].m_PeakComboAward =
              (PeakComboAward)(rand() % NUM_PeakComboAward);
          ss.m_player[p].m_StageAward = (StageAward)(rand() % NUM_StageAward);

          FOREACH_ENUM(RadarCategory, rc) {
            switch (rc) {
              case RadarCategory_Stream:
              case RadarCategory_Voltage:
              case RadarCategory_Air:
              case RadarCategory_Freeze:
              case RadarCategory_Chaos:
                ss.m_player[p].m_radarPossible[rc] = randomf(0, 1);
                ss.m_player[p].m_radarActual[rc] =
                    randomf(0, ss.m_player[p].m_radarPossible[rc]);
                break;
              case RadarCategory_TapsAndHolds:
              case RadarCategory_Jumps:
              case RadarCategory_Holds:
              case RadarCategory_Mines:
              case RadarCategory_Hands:
              case RadarCategory_Rolls:
              case RadarCategory_Lifts:
              case RadarCategory_Fakes:
                ss.m_player[p].m_radarPossible[rc] =
                    float(1 + (rand() % 200));
                ss.m_player[p].m_radarActual[rc] = float(
                    rand() % (int)(ss.m_player[p].m_radarPossible[rc]));
                break;
              default:
                break;
            }

            ;  // filled in by ScreenGameplay on start of notes
          }
        }
      }
    } else {
      LOG->Warn(
          "SRC_AUDIT_FIX: ScreenEvaluation skipped fake stats because no "
          "debug song was available.");
    }
  }

  if (STATSMAN == nullptr) {
    LOG->Warn(
        "SRC_AUDIT_FIX: ScreenEvaluation cannot initialize without "
        "STATSMAN.");
    ScreenWithMenuElements::Init();
    return;
  }

  if (STATSMAN->m_vPlayedStageStats.empty()) {
    LuaHelpers::ReportScriptError(
        "PlayerStageStats is empty!  Do not use SM_GoToNextScreen on "
        "ScreenGameplay, use SM_DoNextScreen instead so that ScreenGameplay "
        "can clean up properly.");
    STATSMAN->m_vPlayedStageStats.push_back(STATSMAN->m_CurStageStats);
  }
  m_FinalEvalStageStats = STATSMAN->m_vPlayedStageStats.back();
  m_pStageStats = &m_FinalEvalStageStats;

  ZERO(m_bSavedScreenshot);

  // Figure out which statistics and songs we're going to display
  SUMMARY.Load(m_sName, "Summary");
  const bool isSummary = SUMMARY.IsLoaded() && SUMMARY.GetValue();
  m_bSummary = isSummary;
  if (isSummary) {
    STATSMAN->GetFinalEvalStageStats(m_FinalEvalStageStats);
    m_pStageStats = &m_FinalEvalStageStats;
  }

  // update persistent statistics
  if (isSummary && m_pStageStats != nullptr) {
    m_pStageStats->FinalizeScores(true);
  }

  // Run this here, so STATSMAN->m_CurStageStats is available to overlays.
  ScreenWithMenuElements::Init();

  // Calculate grades
  Grade grade[NUM_PLAYERS];
  FOREACH_PlayerNumber(p) { grade[p] = Grade_NoData; }
  const std::vector<PlayerNumber> evaluationPlayers =
      GetEvaluationPlayers(m_pStageStats);

  for (const PlayerNumber& p : evaluationPlayers) {
    if (PlayerHasEvaluationStats(m_pStageStats, p)) {
      grade[p] = m_pStageStats->m_player[p].GetGrade();
    }
  }

  const float bannerWidth = GetBannerMetric(m_sName, "BannerWidth", 256.0f);
  const float bannerHeight = GetBannerMetric(m_sName, "BannerHeight", 80.0f);
  const bool showBannerArea =
      GetEvaluationMetricB(m_sName, "ShowBannerArea", true);
  const bool showGradeArea =
      GetEvaluationMetricB(m_sName, "ShowGradeArea", false);
  const bool showPointsArea =
      GetEvaluationMetricB(m_sName, "ShowPointsArea", false);
  const bool showBonusArea =
      GetEvaluationMetricB(m_sName, "ShowBonusArea", false);
  const bool showSurvivedArea =
      GetEvaluationMetricB(m_sName, "ShowSurvivedArea", false);
  const bool showWinArea = GetEvaluationMetricB(m_sName, "ShowWinArea", false);
  const bool showSharedJudgmentLineLabels =
      GetEvaluationMetricB(m_sName, "ShowSharedJudgmentLineLabels", false);
  const bool showDetailArea =
      GetEvaluationMetricB(m_sName, "ShowDetailArea", false);
  const bool showScoreArea =
      GetEvaluationMetricB(m_sName, "ShowScoreArea", false);
  const bool showTimeArea =
      GetEvaluationMetricB(m_sName, "ShowTimeArea", false);
  const bool hidePlayerOptionsFailType =
      GetEvaluationMetricB(m_sName, "PlayerOptionsHideFailType", false);
  const bool checkpointsWithJudgments =
      GetEvaluationMetricB(m_sName, "CheckpointsWithJudgments", false);
  const std::string playerOptionsSeparator =
      GetEvaluationMetricString(m_sName, "PlayerOptionsSeparator", ",");
  const std::string detailLineFormat =
      GetEvaluationMetricString(m_sName, "DetailLineFormat", "%3d/%3d");
  apActorCommands barActualMaxCommand =
      GetEvaluationMetricCommands(m_sName, "BarActualMaxCommand");
  const bool showW1 = GAMESTATE != nullptr && GAMESTATE->ShowW1();
  const bool isCourseMode = IsEvaluationCourseMode(m_pStageStats);

  // load sounds
  if (IsThemeRuntimeAvailable("ScreenEvaluation start sound")) {
    m_soundStart.Load(THEME->GetPathS(m_sName, "start"));
  }

  // init banner area
  if (showBannerArea) {
    if (isSummary) {
      for (size_t i = 0;
           i < m_pStageStats->m_vpPlayedSongs.size() && i < MAX_SONGS_TO_SHOW;
           i++) {
        Song* pSong = m_pStageStats->m_vpPlayedSongs[i];
        if (pSong == nullptr) {
          LOG->Warn(
              "SRC_AUDIT_FIX: ScreenEvaluation skipped null summary song at "
              "index %zu.",
              i);
          continue;
        }

        m_SmallBanner[i].LoadFromSong(pSong);
        m_SmallBanner[i].ScaleToClipped(bannerWidth, bannerHeight);
        m_SmallBanner[i].SetName(ssprintf("SmallBanner%u", (unsigned)i + 1));
        ActorUtil::LoadAllCommands(m_SmallBanner[i], m_sName);
        SET_XY(m_SmallBanner[i]);
        this->AddChild(&m_SmallBanner[i]);

        m_sprSmallBannerFrame[i].Load(THEME->GetPathG(m_sName, "BannerFrame"));
        m_sprSmallBannerFrame[i]->SetName(
            ssprintf("SmallBanner%u", (unsigned)i + 1));
        ActorUtil::LoadAllCommands(*m_sprSmallBannerFrame[i], m_sName);
        SET_XY(m_sprSmallBannerFrame[i]);
        this->AddChild(m_sprSmallBannerFrame[i]);
      }
    } else {
      if (isCourseMode && m_pStageStats->m_pPlayedCourse != nullptr) {
        m_LargeBanner.LoadFromCourse(m_pStageStats->m_pPlayedCourse);
      } else {
        Song* pSong = GetPrimaryPlayedSong(m_pStageStats);
        if (pSong != nullptr) {
          m_LargeBanner.LoadFromSong(pSong);
        } else {
          LOG->Warn(
              "SRC_AUDIT_FIX: ScreenEvaluation has no song/course for large "
              "banner.");
        }
      }
      m_LargeBanner.ScaleToClipped(bannerWidth, bannerHeight);
      m_LargeBanner.SetName("LargeBanner");
      ActorUtil::LoadAllCommands(m_LargeBanner, m_sName);
      SET_XY(m_LargeBanner);
      this->AddChild(&m_LargeBanner);

      m_sprLargeBannerFrame.Load(THEME->GetPathG(m_sName, "BannerFrame"));
      m_sprLargeBannerFrame->SetName("LargeBannerFrame");
      ActorUtil::LoadAllCommands(*m_sprLargeBannerFrame, m_sName);
      SET_XY(m_sprLargeBannerFrame);
      this->AddChild(m_sprLargeBannerFrame);
    }
  }

  {
    if (!isSummary) {
      for (const PlayerNumber& p : evaluationPlayers) {
        if (GAMESTATE == nullptr || GAMESTATE->m_pPlayerState[p] == nullptr) {
          LOG->Warn(
              "SRC_AUDIT_FIX: ScreenEvaluation skipped player options for "
              "player %i because PlayerState is unavailable.",
              p);
          continue;
        }
        m_textPlayerOptions[p].LoadFromFont(
            THEME->GetPathF(m_sName, "PlayerOptions"));
        m_textPlayerOptions[p].SetName(ssprintf("PlayerOptionsP%d", p + 1));
        ActorUtil::LoadAllCommands(m_textPlayerOptions[p], m_sName);
        SET_XY(m_textPlayerOptions[p]);
        std::vector<std::string> v;
        PlayerOptions po =
            GAMESTATE->m_pPlayerState[p]->m_PlayerOptions.GetPreferred();
        if (hidePlayerOptionsFailType) {
          po.m_FailType = (FailType)0;  // blank out the fail type so that it
                                        // won't show in the mods list
        }
        po.GetLocalizedMods(v);
        std::string sPO = join(playerOptionsSeparator, v);
        m_textPlayerOptions[p].SetText(sPO);
        this->AddChild(&m_textPlayerOptions[p]);
      }

      {
        m_textSongOptions.LoadFromFont(THEME->GetPathF(m_sName, "SongOptions"));
        m_textSongOptions.SetName("SongOptions");
        ActorUtil::LoadAllCommands(m_textSongOptions, m_sName);
        SET_XY(m_textSongOptions);
        m_textSongOptions.SetText(
            GAMESTATE != nullptr
                ? GAMESTATE->m_SongOptions.GetStage().GetLocalizedString()
                : "");
        this->AddChild(&m_textSongOptions);
      }
    }

    // Dairy Queen'd (disqualified)
    for (const PlayerNumber& p : evaluationPlayers) {
      m_sprDisqualified[p].Load(THEME->GetPathG(m_sName, "Disqualified"));
      m_sprDisqualified[p]->SetName(ssprintf("DisqualifiedP%d", p + 1));
      LOAD_ALL_COMMANDS_AND_SET_XY(m_sprDisqualified[p]);
      m_sprDisqualified[p]->SetVisible(
          m_pStageStats->m_player[p].m_bDisqualified);
      this->AddChild(m_sprDisqualified[p]);
    }
  }

  // init grade area
  if (showGradeArea) {
    for (const PlayerNumber& p : evaluationPlayers) {
      m_sprGradeFrame[p].Load(
          THEME->GetPathG(m_sName, ssprintf("GradeFrame p%d", p + 1)));
      m_sprGradeFrame[p]->SetName(ssprintf("GradeFrameP%d", p + 1));
      ActorUtil::LoadAllCommands(*m_sprGradeFrame[p], m_sName);
      SET_XY(m_sprGradeFrame[p]);
      this->AddChild(m_sprGradeFrame[p]);

      // TODO: Re-add scrolling grade functionality
      m_Grades[p].Load("GradeDisplayEval");
      m_Grades[p].SetGrade(grade[p]);
      m_Grades[p].SetName(ssprintf("GradeP%d", p + 1));
      ActorUtil::LoadAllCommands(m_Grades[p], m_sName);
      SET_XY(m_Grades[p]);
      this->AddChild(&m_Grades[p]);
    }
  }

  // init points area
  if (showPointsArea) {
    for (const PlayerNumber& p : evaluationPlayers) {
      if (GAMESTATE == nullptr || GAMESTATE->m_pPlayerState[p] == nullptr) {
        LOG->Warn(
            "SRC_AUDIT_FIX: ScreenEvaluation skipped percent display for "
            "player %i because PlayerState is unavailable.",
            p);
        continue;
      }
      m_sprPercentFrame[p].Load(
          THEME->GetPathG(m_sName, ssprintf("PercentFrame p%d", p + 1)));
      m_sprPercentFrame[p]->SetName(ssprintf("PercentFrameP%d", p + 1));
      ActorUtil::LoadAllCommands(*m_sprPercentFrame[p], m_sName);
      SET_XY(m_sprPercentFrame[p]);
      this->AddChild(m_sprPercentFrame[p]);

      /* Use "ScreenEvaluation Percent" in the [metrics], but position and
       * tween it with "PercentP1X", etc. */
      m_Percent[p].SetName(ssprintf("PercentP%d", p + 1));
      m_Percent[p].Load(
          GAMESTATE->m_pPlayerState[p], &m_pStageStats->m_player[p],
          "ScreenEvaluation Percent", true);
      ActorUtil::LoadAllCommands(m_Percent[p], m_sName);
      SET_XY(m_Percent[p]);
      this->AddChild(&m_Percent[p]);
    }
  }

  // init bonus area
  if (showBonusArea) {
    // In course mode, we need to make sure the bar doesn't overflow. -aj
    float fDivider = 1.0f;
    if (isCourseMode) {
      size_t courseEntries = m_pStageStats != nullptr
                                 ? m_pStageStats->m_vpPlayedSongs.size()
                                 : 0;
      if (courseEntries > 0) {
        fDivider = 1.0f / static_cast<float>(courseEntries);
      } else {
        LOG->Warn(
            "SRC_AUDIT_FIX: ScreenEvaluation used bonus divider fallback for "
            "empty course stats.");
      }
    }

    for (const PlayerNumber& p : evaluationPlayers) {
      m_sprBonusFrame[p].Load(
          THEME->GetPathG(m_sName, ssprintf("BonusFrame p%d", p + 1)));
      m_sprBonusFrame[p]->SetName(ssprintf("BonusFrameP%d", p + 1));
      ActorUtil::LoadAllCommands(*m_sprBonusFrame[p], m_sName);
      SET_XY(m_sprBonusFrame[p]);
      this->AddChild(m_sprBonusFrame[p]);

      // todo: convert this to use category names instead of numbers? -aj
      for (int r = 0; r < NUM_SHOWN_RADAR_CATEGORIES; r++)  // foreach line
      {
        float possible = ClampFiniteNonNegativeEvaluationFloat(
            m_pStageStats->m_player[p].m_radarPossible[r], "radar possible");
        float actual = ClampFiniteNonNegativeEvaluationFloat(
            m_pStageStats->m_player[p].m_radarActual[r], "radar actual");
        if (possible > 1.0f) {
          actual = possible > 0.0f ? actual / possible : 0.0f;
          possible = 1.0f;
        }
        if (actual > possible) {
          LOG->Warn(
              "SRC_AUDIT_FIX: ScreenEvaluation clamped radar actual %f to "
              "possible %f.",
              actual, possible);
          actual = possible;
        }
        m_sprPossibleBar[p][r].Load(
            THEME->GetPathG(m_sName, ssprintf("BarPossible p%d", p + 1)));
        m_sprPossibleBar[p][r].SetWidth(
            m_sprPossibleBar[p][r].GetUnzoomedWidth() * possible * fDivider);
        m_sprPossibleBar[p][r].SetName(
            ssprintf("BarPossible%dP%d", r + 1, p + 1));
        ActorUtil::LoadAllCommands(m_sprPossibleBar[p][r], m_sName);
        SET_XY(m_sprPossibleBar[p][r]);
        this->AddChild(&m_sprPossibleBar[p][r]);

        m_sprActualBar[p][r].Load(
            THEME->GetPathG(m_sName, ssprintf("BarActual p%d", p + 1)));
        // should be out of the possible bar, not actual (whatever value that is
        // at)
        m_sprActualBar[p][r].SetWidth(
            m_sprPossibleBar[p][r].GetUnzoomedWidth() * actual * fDivider);

        float value = possible > 0.0f ? 100.0f * actual / possible : 0.0f;
        LOG->Trace("Radar bar %d of 5 - %f percent", r, value);

        m_sprActualBar[p][r].SetName(ssprintf("BarActual%dP%d", r + 1, p + 1));
        ActorUtil::LoadAllCommands(m_sprActualBar[p][r], m_sName);
        SET_XY(m_sprActualBar[p][r]);

        // .99999 is fairly close to 1.00, so we use that.
        // todo: allow extra commands for AAA/AAAA? -aj
        if (actual > 0.99999f && barActualMaxCommand.Get() != nullptr) {
          m_sprActualBar[p][r].RunCommands(barActualMaxCommand);
        }
        this->AddChild(&m_sprActualBar[p][r]);
      }
    }
  }

  // init survived area
  if (showSurvivedArea) {
    for (const PlayerNumber& p : evaluationPlayers) {
      m_sprSurvivedFrame[p].Load(
          THEME->GetPathG(m_sName, ssprintf("SurvivedFrame p%d", p + 1)));
      m_sprSurvivedFrame[p]->SetName(ssprintf("SurvivedFrameP%d", p + 1));
      ActorUtil::LoadAllCommands(*m_sprSurvivedFrame[p], m_sName);
      SET_XY(m_sprSurvivedFrame[p]);
      this->AddChild(m_sprSurvivedFrame[p]);

      m_textSurvivedNumber[p].LoadFromFont(
          THEME->GetPathF(m_sName, "SurvivedNumber"));
      // curewater: edited the "# stages cleared" text so it deducts one if you
      // failed. Should be accurate, but I'm not sure if its "standard" that
      // (bool)true = 1.  (assumption)
      m_textSurvivedNumber[p].SetText(ssprintf(
          "%02d",
          ClampNonNegativeEvaluationInt(
              m_pStageStats->m_player[p].m_iSongsPassed, "songs passed")));
      m_textSurvivedNumber[p].SetName(ssprintf("SurvivedNumberP%d", p + 1));
      ActorUtil::LoadAllCommands(m_textSurvivedNumber[p], m_sName);
      SET_XY(m_textSurvivedNumber[p]);
      this->AddChild(&m_textSurvivedNumber[p]);
    }
  }

  // init win area
  if (showWinArea) {
    for (const PlayerNumber& p : evaluationPlayers) {
      m_sprWinFrame[p].Load(
          THEME->GetPathG(m_sName, ssprintf("win frame p%d", p + 1)));
      m_sprWinFrame[p]->SetName(ssprintf("WinFrameP%d", p + 1));
      ActorUtil::LoadAllCommands(*m_sprWinFrame[p], m_sName);
      SET_XY(m_sprWinFrame[p]);
      this->AddChild(m_sprWinFrame[p]);

      m_sprWin[p].Load(
          THEME->GetPathG(m_sName, ssprintf("win p%d 1x3", p + 1)));
      m_sprWin[p].StopAnimating();
      int iFrame = GAMESTATE != nullptr ? GAMESTATE->GetStageResult(p) : 0;
      const int numStates = m_sprWin[p].GetNumStates();
      if (numStates > 0 && (iFrame < 0 || iFrame >= numStates)) {
        LOG->Warn(
            "SRC_AUDIT_FIX: ScreenEvaluation clamped win frame %i to range "
            "0..%i.",
            iFrame, numStates - 1);
        rage_clamp(iFrame, 0, numStates - 1);
      }
      m_sprWin[p].SetState(iFrame);
      m_sprWin[p].SetName(ssprintf("WinP%d", p + 1));
      ActorUtil::LoadAllCommands(m_sprWin[p], m_sName);
      SET_XY(m_sprWin[p]);
      this->AddChild(&m_sprWin[p]);
    }
  }

  // init judgment area
  ROLLING_NUMBERS_CLASS.Load(m_sName, "RollingNumbersClass");
  ROLLING_NUMBERS_MAX_COMBO_CLASS.Load(m_sName, "RollingNumbersMaxComboClass");
  FOREACH_ENUM(JudgmentLine, l) {
    if (l == JudgmentLine_W1 && !showW1) {
      continue;  // skip
    }

    if (GetEvaluationMetricB(
            m_sName, "ShowJudgmentLine" + JudgmentLineToString(l), false)) {
      if (showSharedJudgmentLineLabels) {
        LuaThreadVariable var2("JudgmentLine", LuaReference::Create(l));
        m_sprSharedJudgmentLineLabels[l].Load(THEME->GetPathG(
            m_sName, "JudgmentLabel " + JudgmentLineToString(l)));
        m_sprSharedJudgmentLineLabels[l]->SetName(
            JudgmentLineToString(l) + "Label");
        ActorUtil::LoadAllCommands(m_sprSharedJudgmentLineLabels[l], m_sName);
        SET_XY(m_sprSharedJudgmentLineLabels[l]);
        this->AddChild(m_sprSharedJudgmentLineLabels[l]);
      }

      for (const PlayerNumber& p : evaluationPlayers) {
        m_textJudgmentLineNumber[l][p].LoadFromFont(
            THEME->GetPathF(m_sName, "JudgmentLineNumber"));
        m_textJudgmentLineNumber[l][p].SetName(
            JudgmentLineToString(l) + ssprintf("NumberP%d", p + 1));
        if (JudgmentLineToString(l) == "MaxCombo") {
          m_textJudgmentLineNumber[l][p].Load(ROLLING_NUMBERS_MAX_COMBO_CLASS);
        } else {
          m_textJudgmentLineNumber[l][p].Load(ROLLING_NUMBERS_CLASS);
        }
        ActorUtil::LoadAllCommands(m_textJudgmentLineNumber[l][p], m_sName);
        SET_XY(m_textJudgmentLineNumber[l][p]);
        this->AddChild(&m_textJudgmentLineNumber[l][p]);

        int iValue = 0;
        switch (l) {
          /* xxx: This doesn't seem to handle checkpoints correctly.
           * Something about checkpoints needing to be tied into
           * the correct judgments instead of just W1/W2. Misses are ok. */
          case JudgmentLine_W1:
            iValue = ClampNonNegativeEvaluationInt(
                m_pStageStats->m_player[p].m_iTapNoteScores[TNS_W1],
                "judgment W1");
            if (checkpointsWithJudgments && showW1) {
              iValue = AddNonNegativeEvaluationIntSaturated(
                  iValue,
                  m_pStageStats->m_player[p]
                      .m_iTapNoteScores[TNS_CheckpointHit],
                  "judgment checkpoint hit");
            }
            break;
          case JudgmentLine_W2:
            iValue = ClampNonNegativeEvaluationInt(
                m_pStageStats->m_player[p].m_iTapNoteScores[TNS_W2],
                "judgment W2");
            if (checkpointsWithJudgments && !showW1) {
              iValue = AddNonNegativeEvaluationIntSaturated(
                  iValue,
                  m_pStageStats->m_player[p]
                      .m_iTapNoteScores[TNS_CheckpointHit],
                  "judgment checkpoint hit");
            }
            break;
          case JudgmentLine_W3:
            iValue = ClampNonNegativeEvaluationInt(
                m_pStageStats->m_player[p].m_iTapNoteScores[TNS_W3],
                "judgment W3");
            break;
          case JudgmentLine_W4:
            iValue = ClampNonNegativeEvaluationInt(
                m_pStageStats->m_player[p].m_iTapNoteScores[TNS_W4],
                "judgment W4");
            break;
          case JudgmentLine_W5:
            iValue = ClampNonNegativeEvaluationInt(
                m_pStageStats->m_player[p].m_iTapNoteScores[TNS_W5],
                "judgment W5");
            break;
          case JudgmentLine_Miss:
            iValue = ClampNonNegativeEvaluationInt(
                m_pStageStats->m_player[p].m_iTapNoteScores[TNS_Miss],
                "judgment miss");
            if (checkpointsWithJudgments) {
              iValue = AddNonNegativeEvaluationIntSaturated(
                  iValue,
                  m_pStageStats->m_player[p]
                      .m_iTapNoteScores[TNS_CheckpointMiss],
                  "judgment checkpoint miss");
            }
            break;
          case JudgmentLine_Held:
            iValue = ClampNonNegativeEvaluationInt(
                m_pStageStats->m_player[p].m_iHoldNoteScores[HNS_Held],
                "judgment held");
            break;
          case JudgmentLine_MaxCombo:
            iValue = ClampNonNegativeEvaluationInt(
                m_pStageStats->m_player[p].GetMaxCombo().m_cnt, "max combo");
            break;
          default:
            LOG->Warn(
                "SRC_AUDIT_FIX: ScreenEvaluation ignored invalid judgment "
                "line %i.",
                l);
            break;
        }

        m_textJudgmentLineNumber[l][p].SetTargetNumber(float(iValue));
      }
    }
  }

  // init detail area
  if (showDetailArea) {
    for (const PlayerNumber& p : evaluationPlayers) {
      m_sprDetailFrame[p].Load(
          THEME->GetPathG(m_sName, ssprintf("DetailFrame p%d", p + 1)));
      m_sprDetailFrame[p]->SetName(ssprintf("DetailFrameP%d", p + 1));
      ActorUtil::LoadAllCommands(*m_sprDetailFrame[p], m_sName);
      SET_XY(m_sprDetailFrame[p]);
      this->AddChild(m_sprDetailFrame[p]);
    }

    FOREACH_ENUM(DetailLine, l) {
      for (const PlayerNumber& p : evaluationPlayers) {
        m_textDetailText[l][p].LoadFromFont(
            THEME->GetPathF(m_sName, "DetailLineNumber"));
        m_textDetailText[l][p].SetName(
            DetailLineToString(l) + ssprintf("NumberP%d", p + 1));
        ActorUtil::LoadAllCommands(m_textDetailText[l][p], m_sName);
        SET_XY(m_textDetailText[l][p]);
        this->AddChild(&m_textDetailText[l][p]);

        static const int indices[NUM_DetailLine] = {
            RadarCategory_TapsAndHolds, RadarCategory_Jumps,
            RadarCategory_Holds,        RadarCategory_Mines,
            RadarCategory_Hands,        RadarCategory_Rolls,
            RadarCategory_Lifts,        RadarCategory_Fakes};
        const int ind = indices[l];
        const int iActual =
            RoundNonNegativeRadarValue(
                m_pStageStats->m_player[p].m_radarActual[ind],
                "detail actual");
        const int iPossible =
            RoundNonNegativeRadarValue(
                m_pStageStats->m_player[p].m_radarPossible[ind],
                "detail possible");

        m_textDetailText[l][p].SetText(
            FormatDetailLine(detailLineFormat, iActual, iPossible));
      }
    }
  }

  // init score area
  if (showScoreArea) {
    m_sprScoreLabel.Load(THEME->GetPathG(m_sName, "ScoreLabel"));
    m_sprScoreLabel->SetName("ScoreLabel");
    ActorUtil::LoadAllCommands(*m_sprScoreLabel, m_sName);
    SET_XY(m_sprScoreLabel);
    this->AddChild(m_sprScoreLabel);

    for (const PlayerNumber& p : evaluationPlayers) {
      m_textScore[p].LoadFromFont(THEME->GetPathF(m_sName, "ScoreNumber"));
      m_textScore[p].SetName(ssprintf("ScoreNumberP%d", p + 1));
      m_textScore[p].Load("RollingNumbersEvaluation");
      ActorUtil::LoadAllCommands(m_textScore[p], m_sName);
      SET_XY(m_textScore[p]);
      m_textScore[p].SetTargetNumber(
          float(m_pStageStats->m_player[p].m_iScore));
      this->AddChild(&m_textScore[p]);
    }
  }

  // init time area
  if (showTimeArea) {
    m_sprTimeLabel.Load(THEME->GetPathG(m_sName, "TimeLabel"));
    m_sprTimeLabel->SetName("TimeLabel");
    ActorUtil::LoadAllCommands(*m_sprTimeLabel, m_sName);
    SET_XY(m_sprTimeLabel);
    this->AddChild(m_sprTimeLabel);

    for (const PlayerNumber& p : evaluationPlayers) {
      m_textTime[p].LoadFromFont(THEME->GetPathF(m_sName, "time"));
      m_textTime[p].SetShadowLength(0);
      m_textTime[p].SetName(ssprintf("TimeNumberP%d", p + 1));
      ActorUtil::LoadAllCommands(m_textTime[p], m_sName);
      SET_XY(m_textTime[p]);
      m_textTime[p].SetText(SecondsToMMSSMsMs(
          ClampFiniteNonNegativeEvaluationFloat(
              m_pStageStats->m_player[p].m_fAliveSeconds, "alive seconds")));
      this->AddChild(&m_textTime[p]);
    }
  }

  // init records area
  bool bOneHasNewTopRecord = false;
  bool bOneHasFullW1Combo = false;
  bool bOneHasFullW2Combo = false;
  bool bOneHasFullW3Combo = false;
  bool bOneHasFullW4Combo = false;

  for (const PlayerNumber& p : evaluationPlayers) {
    if ((m_pStageStats->m_player[p].m_iMachineHighScoreIndex == 0 ||
         m_pStageStats->m_player[p].m_iPersonalHighScoreIndex == 0)) {
      bOneHasNewTopRecord = true;
    }

    if (m_pStageStats->m_player[p].FullComboOfScore(TNS_W4)) {
      bOneHasFullW4Combo = true;
    }

    if (m_pStageStats->m_player[p].FullComboOfScore(TNS_W3)) {
      bOneHasFullW3Combo = true;
    }

    if (m_pStageStats->m_player[p].FullComboOfScore(TNS_W2)) {
      bOneHasFullW2Combo = true;
    }

    if (m_pStageStats->m_player[p].FullComboOfScore(TNS_W1)) {
      bOneHasFullW1Combo = true;
    }
  }

  Grade best_grade = Grade_NoData;
  for (const PlayerNumber& p : evaluationPlayers) {
    if (grade[p] != Grade_NoData) {
      best_grade =
          best_grade == Grade_NoData ? grade[p] : std::min(best_grade, grade[p]);
    }
  }

  if (m_pStageStats->m_EarnedExtraStage != EarnedExtraStage_No) {
    if (SOUND != nullptr && IsThemeRuntimeAvailable("ScreenEvaluation extra")) {
      SOUND->PlayOnce(THEME->GetPathS(
          m_sName,
          "try " +
              EarnedExtraStageToString(m_pStageStats->m_EarnedExtraStage)));
    }
  } else if (bOneHasNewTopRecord && ANNOUNCER != nullptr &&
             ANNOUNCER->HasSoundsFor("evaluation new record")) {
    PlayEvaluationSoundPath(
        ANNOUNCER->GetPathTo("evaluation new record"), "new record");
  } else if (bOneHasFullW4Combo && g_MinScoreToMaintainCombo.IsLoaded() &&
             g_MinScoreToMaintainCombo.GetValue() == TNS_W4) {
    PlayEvaluationSoundPath(
        GetEvaluationAnnouncerPath("evaluation full combo W4"), "full combo W4");
  } else if ((bOneHasFullW1Combo || bOneHasFullW2Combo || bOneHasFullW3Combo)) {
    std::string sComboType =
        bOneHasFullW1Combo ? "W1" : (bOneHasFullW2Combo ? "W2" : "W3");
    PlayEvaluationSoundPath(
        GetEvaluationAnnouncerPath("evaluation full combo " + sComboType),
        "full combo");
  } else {
    const std::string oldGrade =
        best_grade == Grade_NoData ? "N" : GradeToOldString(best_grade);
    if (isSummary || isCourseMode || GAMESTATE == nullptr) {
      PlayEvaluationSoundPath(
          GetEvaluationAnnouncerPath("evaluation final " + oldGrade),
          "final grade");
    } else if (GAMESTATE != nullptr) {
      switch (GAMESTATE->m_PlayMode) {
        case PLAY_MODE_BATTLE: {
          const PlayerNumber master = GAMESTATE->GetMasterPlayerNumber();
          bool bWon = IsValidEvaluationPlayer(master) &&
                      GAMESTATE->GetStageResult(master) == RESULT_WIN;
          std::string sResult = bWon ? "win" : "lose";
          PlayEvaluationSoundPath(
              GetEvaluationAnnouncerPath("evaluation " + sResult),
              "battle result");
        } break;
        default:
          PlayEvaluationSoundPath(
              GetEvaluationAnnouncerPath("evaluation " + oldGrade),
              "stage grade");
          break;
      }
    }
  }

  if (best_grade != Grade_NoData) {
    switch (GradeToOldGrade(best_grade)) {
      case Grade_Tier01:
      case Grade_Tier02:
      case Grade_Tier03:
        this->PostScreenMessage(
            SM_PlayCheer,
            GetEvaluationMetricF(
                m_sName, "CheerDelaySeconds", 2.5f, true));
      default:
        break;
    }
  }
}

bool ScreenEvaluation::Input(const InputEventPlus& input) {
  if (IsTransitioning()) {
    return false;
  }

  if (input.MenuI == GAME_BUTTON_RESTART && input.type == IET_FIRST_PRESS &&
      GAMESTATE != nullptr && GAMESTATE->IsEventMode() &&
      !GAMESTATE->IsCourseMode()) {
    return MenuRestart(input);
  }

  if (input.GameI.IsValid()) {
    if (CodeDetector::EnteredCode(
            input.GameI.controller, CODE_SAVE_SCREENSHOT1) ||
        CodeDetector::EnteredCode(
            input.GameI.controller, CODE_SAVE_SCREENSHOT2)) {
      PlayerNumber pn = input.pn;
      if (!IsValidEvaluationPlayer(pn)) {
        LOG->Warn(
            "SRC_AUDIT_FIX: ScreenEvaluation ignored screenshot for invalid "
            "player %i.",
            pn);
        return true;
      }
      if (!m_bSavedScreenshot[pn] && PROFILEMAN != nullptr &&
          PROFILEMAN->IsPersistentProfile(pn)) {
        const bool fromMemoryCard =
            PROFILEMAN->ProfileWasLoadedFromMemoryCard(pn);
        bool mountedMemoryCard = false;
        if (fromMemoryCard) {
          if (MEMCARDMAN == nullptr) {
            LOG->Warn(
                "SRC_AUDIT_FIX: ScreenEvaluation skipped screenshot because "
                "MEMCARDMAN is unavailable.");
            return true;
          }
          mountedMemoryCard = MEMCARDMAN->MountCard(pn);
          if (!mountedMemoryCard) {
            LOG->Warn(
                "SRC_AUDIT_FIX: ScreenEvaluation skipped screenshot because "
                "memory card mount failed for player %i.",
                pn);
            return true;
          }
        }

        Profile* pProfile = PROFILEMAN->GetProfile(pn);
        if (pProfile == nullptr) {
          LOG->Warn(
              "SRC_AUDIT_FIX: ScreenEvaluation skipped screenshot because "
              "profile is unavailable for player %i.",
              pn);
          if (mountedMemoryCard) {
            MEMCARDMAN->UnmountCard(pn);
          }
          return true;
        }

        std::string sDir =
            PROFILEMAN->GetProfileDir((ProfileSlot)pn) + "Screenshots/";
        std::string sFileName =
            StepMania::SaveScreenshot(sDir, true, true, "", "");

        if (!sFileName.empty()) {
          std::string sPath = sDir + sFileName;

          const HighScore hs =
              m_pStageStats != nullptr
                  ? m_pStageStats->m_player[pn].m_HighScore
                  : HighScore();
          Screenshot screenshot;
          screenshot.sFileName = sFileName;
          screenshot.sMD5 =
              CRYPTMAN != nullptr ? BinaryToHex(CRYPTMAN->GetMD5ForFile(sPath))
                                  : "";
          screenshot.highScore = hs;
          pProfile->AddScreenshot(screenshot);
        }

        if (mountedMemoryCard) {
          MEMCARDMAN->UnmountCard(pn);
        }

        m_bSavedScreenshot[pn] = true;
        return true;  // handled
      }
    }
  }

  return ScreenWithMenuElements::Input(input);
}

void ScreenEvaluation::HandleScreenMessage(const ScreenMessage SM) {
  if (SM == SM_GoToNextScreen && ShouldIgnoreOnlineEvaluationNextScreen()) {
    OnlineTrace("ITG Online: ScreenEvaluation ignored SM_GoToNextScreen without "
        "explicit online evaluation exit request.");
    return;
  }

  if (SM == SM_PlayCheer) {
    PlayEvaluationSoundPath(
        GetEvaluationAnnouncerPath("evaluation cheer"), "cheer");
  }

  ScreenWithMenuElements::HandleScreenMessage(SM);
}

bool ScreenEvaluation::MenuBack(const InputEventPlus& input) {
  return MenuStart(input);
}

bool ScreenEvaluation::MenuStart(const InputEventPlus& input) {
  if (IsTransitioning()) {
    return false;
  }

  const std::string inputName =
      INPUTMAPPER != nullptr
          ? GameButtonToString(INPUTMAPPER->GetInputScheme(), input.MenuI)
          : ssprintf("GameButton%d", input.MenuI);

  if (TryHandleOnlineEvaluationNativeExit(inputName)) {
    return true;
  }

  if (OnlineEvaluationAutoAdvanceBlocked()) {
    OnlineTrace("ITG Online: evaluation auto advance blocked screen=%s input=%s",
        m_sName.c_str(), inputName.c_str());
    return true;
  }

  m_soundStart.Play(true);

  HandleMenuStart();
  return true;
}

bool ScreenEvaluation::MenuRestart(const InputEventPlus& input) {
  if (IsTransitioning()) {
    return false;
  }

  if (SCREENMAN == nullptr || THEME == nullptr || !THEME->IsThemeLoaded() ||
      !SCREENMAN->IsScreenNameValid("ScreenGameplay")) {
    LOG->Warn(
        "SRC_AUDIT_FIX: ScreenEvaluation refused restart because "
        "ScreenGameplay is unavailable.");
    return false;
  }

  Screen* topScreen = SCREENMAN->GetTopScreen();
  if (topScreen == nullptr) {
    LOG->Warn(
        "SRC_AUDIT_FIX: ScreenEvaluation refused restart because top screen "
        "is unavailable.");
    return false;
  }

  topScreen->SetNextScreenName("ScreenGameplay");
  StartTransitioningScreen(SM_GoToNextScreen);
  return true;
}

void ScreenEvaluation::HandleMenuStart() {
  StartTransitioningScreen(SM_GoToNextScreen);
}

bool ScreenEvaluation::OnlineEvaluationAutoAdvanceBlocked() const {
  if (LUA == nullptr) {
    return ITGOnlineSessionGuard::IsObservedActive();
  }

  Lua* L = LUA->Get();
  if (L == nullptr) {
    return ITGOnlineSessionGuard::IsObservedActive();
  }

  const int stackTop = lua_gettop(L);
  bool onlineActive = false;
  bool hasActiveAnswer = false;
  const bool activeOk = LuaHelpers::RunExpression(
      L,
      "ITGOnline ~= nil and ITGOnline.HasOnlineSession ~= nil and ITGOnline:HasOnlineSession()",
      "ScreenEvaluation online auto-advance active-session gate");
  if (activeOk && lua_isboolean(L, -1)) {
    onlineActive = lua_toboolean(L, -1);
    hasActiveAnswer = true;
  }
  lua_settop(L, stackTop);

  if (!hasActiveAnswer) {
    LUA->Release(L);
    return ITGOnlineSessionGuard::IsObservedActive();
  }
  ITGOnlineSessionGuard::Observe(onlineActive);
  if (!onlineActive) {
    LUA->Release(L);
    return false;
  }

  bool blocked = false;
  const bool ok = LuaHelpers::RunExpression(
      L,
      "ITGOnline ~= nil and ITGOnline.ShouldBlockEvaluationAutoAdvance ~= nil "
      "and ITGOnline:ShouldBlockEvaluationAutoAdvance()",
      "ScreenEvaluation online auto advance gate");
  if (ok) {
    if (lua_isboolean(L, -1)) {
      LuaHelpers::Pop(L, blocked);
    } else {
      LOG->Warn(
          "SRC_AUDIT_FIX: ScreenEvaluation online auto advance gate returned "
          "a non-boolean value.");
      lua_pop(L, 1);
    }
  }
  lua_settop(L, stackTop);
  LUA->Release(L);
  if (!ok) {
    OnlineTrace(
        "ITG Online: evaluation auto-advance gate failed; holding evaluation "
        "closed.");
    return true;
  }
  return blocked;
}

// lua start
#include "LuaBinding.h"

/** @brief Allow Lua to have access to the ScreenEvaluation. */
class LunaScreenEvaluation : public Luna<ScreenEvaluation> {
 public:
  static int GetStageStats(T* p, lua_State* L) {
    if (p == nullptr || p->GetStageStats() == nullptr) {
      lua_pushnil(L);
      return 1;
    }
    LuaHelpers::Push(L, p->GetStageStats());
    return 1;
  }
  LunaScreenEvaluation() { ADD_METHOD(GetStageStats); }
};

LUA_REGISTER_DERIVED_CLASS(ScreenEvaluation, ScreenWithMenuElements)

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
