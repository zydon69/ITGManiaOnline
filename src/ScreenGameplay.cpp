#include "ScreenGameplay.h"

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <string>
#include <vector>

#include "ActiveAttackList.h"
#include "Actor.h"
#include "ActorUtil.h"
#include "AdjustSync.h"
#include "ArrowEffects.h"
#include "Attack.h"
#include "Background.h"
#include "BitmapText.h"
#include "CombinedLifeMeterTug.h"
#include "CommonMetrics.h"
#include "Course.h"
#include "DancingCharacters.h"
#include "Difficulty.h"
#include "EnumHelper.h"
#include "Foreground.h"
#include "Game.h"
#include "GameConstantsAndTypes.h"
#include "GameInput.h"
#include "GameManager.h"
#include "GamePreferences.h"
#include "GameSoundManager.h"
#include "GameState.h"
#include "GameplayHelpers.h"
#include "InputFilter.h"
#include "InputMapper.h"
#include "Inventory.h"
#include "LifeMeter.h"
#include "LifeMeterBar.h"
#include "LightsManager.h"
#include "LuaManager.h"
#include "LyricsLoader.h"
#include "MemoryCardManager.h"
#include "MessageManager.h"
#include "ModsGroup.h"
#include "NoteData.h"
#include "NoteDataUtil.h"
#include "NoteDataWithScoring.h"
#include "NoteTypes.h"
#include "Player.h"
#include "PlayerAI.h"  // for NUM_SKILL_LEVELS
#include "PlayerNumber.h"
#include "PlayerOptions.h"
#include "PlayerState.h"
#include "PerfDiagnostics.h"
#include "Preference.h"
#include "PrefsManager.h"
#include "Profile.h"  // for replay data stuff
#include "ProfileManager.h"
#include "RageDisplay.h"
#include "RageInputDevice.h"
#include "RageLog.h"
#include "RageSoundManager.h"
#include "RageSoundReader.h"
#include "RageThreads.h"
#include "RageTimer.h"
#include "RageTypes.h"
#include "RageUtil.h"
#include "RageUtil/Regex.h"
#include "ScoreDisplayLifeTime.h"
#include "ScoreDisplayNormal.h"
#include "ScoreDisplayOni.h"
#include "ScoreDisplayPercentage.h"
#include "ScoreDisplayRave.h"
#include "ScoreKeeperNormal.h"
#include "ScoreKeeperRave.h"
#include "ScreenDimensions.h"
#include "ScreenManager.h"
#include "ScreenMessage.h"
#include "ScreenSaveSync.h"
#include "ScreenWithMenuElements.h"
#include "Song.h"
#include "SongManager.h"
#include "SongOptions.h"
#include "SongUtil.h"
#include "StatsManager.h"
#include "StdString.h"
#include "Steps.h"
#include "StepsDisplay.h"
#include "StepsUtil.h"
#include "Style.h"
#include "ThemeManager.h"
#include "ThemeMetric.h"
#include "Trail.h"
#include "UnlockManager.h"
#include "XmlFile.h"
#include "XmlFileUtil.h"
#include "global.h"

// Defines
#define SHOW_LIFE_METER_FOR_DISABLED_PLAYERS \
  THEME->GetMetricB(m_sName, "ShowLifeMeterForDisabledPlayers")
#define SHOW_SCORE_IN_RAVE THEME->GetMetricB(m_sName, "ShowScoreInRave")
#define SONG_POSITION_METER_WIDTH \
  THEME->GetMetricF(m_sName, "SongPositionMeterWidth")
#define STOP_COURSE_EARLY \
  THEME->GetMetricB(      \
      m_sName, "StopCourseEarly")  // evaluate this every time it's used

static ThemeMetric<float> INITIAL_BACKGROUND_BRIGHTNESS(
    "ScreenGameplay", "InitialBackgroundBrightness");
static ThemeMetric<float> SECONDS_BETWEEN_COMMENTS(
    "ScreenGameplay", "SecondsBetweenComments");
static ThemeMetric<std::string> SCORE_KEEPER_CLASS(
    "ScreenGameplay", "ScoreKeeperClass");
static ThemeMetric<bool> FORCE_IMMEDIATE_FAIL_FOR_BATTERY(
    "ScreenGameplay", "ForceImmediateFailForBattery");

AutoScreenMessage(SM_PlayGo);

static constexpr float ITGONLINE_EVALUATION_HOLD_MAX_SECONDS = 30.0f;
static constexpr float ITGONLINE_FAILED_HOLD_MAX_SECONDS = 30.0f;

static bool HasActiveITGOnlineRoom() {
  if (LUA == nullptr) {
    return false;
  }

  Lua* L = LUA->Get();
  const bool ran = LuaHelpers::RunExpression(
      L, "ITGOnline ~= nil and ITGOnline.currentRoomId ~= nil",
      "ScreenGameplay::HasActiveITGOnlineRoom");
  const bool active = ran && lua_toboolean(L, -1);
  lua_pop(L, 1);
  LUA->Release(L);

  return active;
}

static void DisableAutoplayForITGOnline(PlayerState* playerState) {
  if (playerState == nullptr) {
    return;
  }

  auto& options = playerState->m_PlayerOptions;
  PO_GROUP_ASSIGN(options, ModsLevel_Preferred, m_fPlayerAutoPlay, 0.0f);
  PO_GROUP_ASSIGN(options, ModsLevel_Stage, m_fPlayerAutoPlay, 0.0f);
  PO_GROUP_ASSIGN(options, ModsLevel_Song, m_fPlayerAutoPlay, 0.0f);
  playerState->m_PlayerController = PC_HUMAN;
}

struct GameplayVisualPerfSnapshot {
  bool valid;
  float draw_ms;
  float song_background_ms;
  float notefield_board_ms;
  float clear_zbuffer_ms;
  float screen_elements_ms;
  float max_notefield_board_ms;
  std::string max_notefield_board_player;
  std::string max_visible_notes_player;
  int visible_taps;
  int visible_holds;
  int visible_mines;
  int visible_lifts;
  int visible_fakes;
  int visible_attacks;
  int visible_autokeysounds;
  int visible_total;
  int max_player_visible_total;
  int active_receptors;
  int active_ghosts;
  int active_tap_judgments;
  int active_hold_judgments;
  int active_combo;
  int tap_judgments_since_last_snapshot;
  int hold_judgments_since_last_snapshot;
  int mine_judgments_since_last_snapshot;
  int danger_players;
  int failing_players;
  float min_life;

  GameplayVisualPerfSnapshot()
      : valid(false),
        draw_ms(0.0f),
        song_background_ms(0.0f),
        notefield_board_ms(0.0f),
        clear_zbuffer_ms(0.0f),
        screen_elements_ms(0.0f),
        max_notefield_board_ms(0.0f),
        max_notefield_board_player("none"),
        max_visible_notes_player("none"),
        visible_taps(0),
        visible_holds(0),
        visible_mines(0),
        visible_lifts(0),
        visible_fakes(0),
        visible_attacks(0),
        visible_autokeysounds(0),
        visible_total(0),
        max_player_visible_total(0),
        active_receptors(0),
        active_ghosts(0),
        active_tap_judgments(0),
        active_hold_judgments(0),
        active_combo(0),
        tap_judgments_since_last_snapshot(0),
        hold_judgments_since_last_snapshot(0),
        mine_judgments_since_last_snapshot(0),
        danger_players(0),
        failing_players(0),
        min_life(-1.0f) {}
};

static GameplayVisualPerfSnapshot g_LastGameplayVisualPerf;

static const char* HealthStateName(HealthState hs) {
  switch (hs) {
    case HealthState_Hot:
      return "Hot";
    case HealthState_Alive:
      return "Alive";
    case HealthState_Danger:
      return "Danger";
    case HealthState_Dead:
      return "Dead";
    default:
      return "Invalid";
  }
}

static bool IsValidGameplayPlayer(PlayerNumber pn) {
  return pn >= PLAYER_1 && pn < NUM_PLAYERS;
}

static bool IsValidGameplayMultiPlayer(MultiPlayer mp) {
  return mp >= MultiPlayer_P1 && mp < NUM_MultiPlayer;
}

static bool IsFiniteNonNegative(float value) {
  return std::isfinite(value) && value >= 0.0f;
}

static float FiniteNonNegativeOr(float value, float fallback) {
  return IsFiniteNonNegative(value) ? value : fallback;
}

static bool HasCoreGameplayManagers(const char* context) {
  if (GAMESTATE != nullptr && PREFSMAN != nullptr && STATSMAN != nullptr) {
    return true;
  }

  LOG->Warn(
      "SRC_AUDIT_FIX: %s missing core managers (GAMESTATE=%p PREFSMAN=%p "
      "STATSMAN=%p).",
      context, static_cast<void*>(GAMESTATE), static_cast<void*>(PREFSMAN),
      static_cast<void*>(STATSMAN));
  return false;
}

static bool HasRenderableGameplayManagers(const char* context) {
  if (HasCoreGameplayManagers(context) && THEME != nullptr &&
      SCREENMAN != nullptr && MESSAGEMAN != nullptr) {
    return true;
  }

  LOG->Warn(
      "SRC_AUDIT_FIX: %s missing render managers (THEME=%p SCREENMAN=%p "
      "MESSAGEMAN=%p).",
      context, static_cast<void*>(THEME), static_cast<void*>(SCREENMAN),
      static_cast<void*>(MESSAGEMAN));
  return false;
}

static bool IsValidGameInputIndex(const GameInput& input) {
  return input.controller >= GameController_1 &&
         input.controller < NUM_GameController && input.button >= GAME_BUTTON_MENULEFT &&
         input.button < NUM_GameButton;
}

static bool GetITGOnlineSecondsUntilScheduledStart(float& secondsUntilStart) {
  if (LUA == nullptr) {
    return false;
  }

  Lua* L = LUA->Get();
  const bool ran = LuaHelpers::RunExpression(
      L,
      "ITGOnline ~= nil and ITGOnline.SecondsUntilScheduledStart ~= nil and "
      "ITGOnline:SecondsUntilScheduledStart() or nil",
      "ScreenGameplay::GetITGOnlineSecondsUntilScheduledStart");

  const bool hasNumber = ran && lua_isnumber(L, -1);
  if (hasNumber) {
    secondsUntilStart = static_cast<float>(lua_tonumber(L, -1));
  }

  lua_pop(L, 1);
  LUA->Release(L);

  return hasNumber && secondsUntilStart > -30.0f && secondsUntilStart < 120.0f;
}

static bool GetITGOnlineIsActive() {
  if (LUA == nullptr) {
    return false;
  }

  Lua* L = LUA->Get();
  const bool ran = LuaHelpers::RunExpression(
      L,
      "ITGOnline ~= nil and ITGOnline.currentRoomId ~= nil",
      "ScreenGameplay::GetITGOnlineIsActive");

  const bool isActive = ran && lua_toboolean(L, -1);
  lua_pop(L, 1);
  LUA->Release(L);

  return isActive;
}

static bool GetITGOnlineShouldHoldGameplayForStart() {
  if (LUA == nullptr) {
    return false;
  }

  Lua* L = LUA->Get();
  const bool ran = LuaHelpers::RunExpression(
      L,
      "ITGOnline ~= nil and ITGOnline.ShouldHoldGameplayForOnlineStart ~= nil "
      "and ITGOnline:ShouldHoldGameplayForOnlineStart() or false",
      "ScreenGameplay::GetITGOnlineShouldHoldGameplayForStart");

  const bool shouldHold = ran && lua_toboolean(L, -1);
  lua_pop(L, 1);
  LUA->Release(L);

  if (!ran) {
    const bool isOnlineActive = GetITGOnlineIsActive();
    LOG->Warn(
        "ITG Online: start hold gate failed; %s",
        isOnlineActive ? "holding gameplay closed" : "local gameplay unaffected");
    return isOnlineActive;
  }

  return shouldHold;
}

static bool MarkITGOnlineFailedEarly() {
  if (LUA == nullptr) {
    return false;
  }

  Lua* L = LUA->Get();
  const bool ran = LuaHelpers::RunExpression(
      L,
      "ITGOnline ~= nil and ITGOnline.MarkPlayFailedEarly ~= nil "
      "and ITGOnline:MarkPlayFailedEarly('engine_begin_failed') or false",
      "ScreenGameplay::MarkITGOnlineFailedEarly");

  const bool marked = ran && lua_toboolean(L, -1);
  lua_pop(L, 1);
  LUA->Release(L);

  if (!ran) {
    LOG->Warn("ITG Online: failed-state notification failed.");
  }
  return marked;
}

// received while STATE_DANCING
AutoScreenMessage(SM_LoadNextSong);
AutoScreenMessage(SM_StartLoadingNextSong);

// received while STATE_OUTRO
AutoScreenMessage(SM_DoPrevScreen);
AutoScreenMessage(SM_DoNextScreen);

// received while STATE_INTRO
AutoScreenMessage(SM_StartHereWeGo);
AutoScreenMessage(SM_StopHereWeGo);

AutoScreenMessage(SM_BattleTrickLevel1);
AutoScreenMessage(SM_BattleTrickLevel2);
AutoScreenMessage(SM_BattleTrickLevel3);

static Preference<bool> g_bCenter1Player("Center1Player", false);
static Preference<bool> g_bShowLyrics("ShowLyrics", true);
static Preference<bool> g_bEasterEggs("EasterEggs", true);
static Preference<float> g_fPerfTraceSlowGameplayDrawMs(
    "PerfTraceSlowGameplayDrawMs", 4.0f);
static Preference<float> g_fPerfTraceSlowGameplayActorDrawMs(
    "PerfTraceSlowGameplayActorDrawMs", 2.0f);

PlayerInfo::PlayerInfo()
    : m_pn(PLAYER_INVALID),
      m_mp(MultiPlayer_Invalid),
      m_bIsDummy(false),
      m_iDummyIndex(0),
      m_iAddToDifficulty(0),
      m_bPlayerEnabled(false),
      m_PlayerStateDummy(),
      m_PlayerStageStatsDummy(),
      m_SoundEffectControl(),
      m_vpStepsQueue(),
      m_asModifiersQueue(),
      m_pLifeMeter(nullptr),
      m_ptextCourseSongNumber(nullptr),
      m_ptextStepsDescription(nullptr),
      m_pPrimaryScoreDisplay(nullptr),
      m_pSecondaryScoreDisplay(nullptr),
      m_pPrimaryScoreKeeper(nullptr),
      m_pSecondaryScoreKeeper(nullptr),
      m_ptextPlayerOptions(nullptr),
      m_pActiveAttackList(nullptr),
      m_NoteData(),
      m_pPlayer(nullptr),
      m_pInventory(nullptr),
      m_pStepsDisplay(nullptr),
      m_sprOniGameOver() {}

void PlayerInfo::Load(
    PlayerNumber pn, MultiPlayer mp, bool bShowNoteField,
    int iAddToDifficulty) {
  m_pn = pn;
  m_mp = mp;
  m_bPlayerEnabled = IsEnabled();
  m_bIsDummy = false;
  m_iAddToDifficulty = iAddToDifficulty;
  m_pLifeMeter = nullptr;
  m_ptextCourseSongNumber = nullptr;
  m_ptextStepsDescription = nullptr;

  if (!IsMultiPlayer() && !IsValidGameplayPlayer(pn)) {
    LOG->Warn(
        "SRC_AUDIT_FIX: PlayerInfo::Load ignored invalid player %i.",
        static_cast<int>(pn));
    m_bPlayerEnabled = false;
    return;
  }
  if (IsMultiPlayer() && !IsValidGameplayMultiPlayer(mp)) {
    LOG->Warn(
        "SRC_AUDIT_FIX: PlayerInfo::Load ignored invalid multiplayer %i.",
        static_cast<int>(mp));
    m_bPlayerEnabled = false;
    return;
  }

  PlayerState* const pPlayerState = GetPlayerState();
  PlayerStageStats* const pPlayerStageStats = GetPlayerStageStats();
  if (pPlayerState == nullptr || pPlayerStageStats == nullptr) {
    LOG->Warn(
        "SRC_AUDIT_FIX: PlayerInfo::Load ignored player with missing state: "
        "pn=%i mp=%i.",
        static_cast<int>(pn), static_cast<int>(mp));
    m_bPlayerEnabled = false;
    return;
  }

  if (!IsMultiPlayer()) {
    PlayMode mode = GAMESTATE->m_PlayMode;
    switch (mode) {
      case PLAY_MODE_REGULAR:
      case PLAY_MODE_NONSTOP:
      case PLAY_MODE_BATTLE:
      case PLAY_MODE_RAVE:
        if (PREFSMAN != nullptr && PREFSMAN->m_bPercentageScoring) {
          m_pPrimaryScoreDisplay = new ScoreDisplayPercentage;
        } else {
          m_pPrimaryScoreDisplay = new ScoreDisplayNormal;
        }
        break;
      case PLAY_MODE_ONI:
      case PLAY_MODE_ENDLESS:
        if (pPlayerState->m_PlayerOptions.GetStage().m_LifeType ==
            LifeType_Time) {
          m_pPrimaryScoreDisplay = new ScoreDisplayLifeTime;
        } else {
          m_pPrimaryScoreDisplay = new ScoreDisplayOni;
        }
        break;
      default:
        LOG->Warn(
            "SRC_AUDIT_FIX: PlayerInfo::Load ignored invalid PlayMode %i.",
            static_cast<int>(mode));
        m_bPlayerEnabled = false;
        return;
    }
  }

  if (m_pPrimaryScoreDisplay) {
    m_pPrimaryScoreDisplay->Init(pPlayerState, pPlayerStageStats);
  }

  switch (GAMESTATE->m_PlayMode) {
    case PLAY_MODE_RAVE:
      m_pSecondaryScoreDisplay = new ScoreDisplayRave;
      m_pSecondaryScoreDisplay->SetName("ScoreDisplayRave");
    default:
      break;
  }

  if (m_pSecondaryScoreDisplay) {
    m_pSecondaryScoreDisplay->Init(pPlayerState, pPlayerStageStats);
  }

  m_pPrimaryScoreKeeper = ScoreKeeper::MakeScoreKeeper(
      SCORE_KEEPER_CLASS, pPlayerState, pPlayerStageStats);

  switch (GAMESTATE->m_PlayMode) {
    case PLAY_MODE_RAVE:
      m_pSecondaryScoreKeeper =
          new ScoreKeeperRave(pPlayerState, pPlayerStageStats);
    default:
      break;
  }

  m_ptextPlayerOptions = nullptr;
  m_pActiveAttackList = nullptr;
  m_pPlayer = new Player(m_NoteData, bShowNoteField);
  m_pInventory = nullptr;
  m_pStepsDisplay = nullptr;

  if (IsMultiPlayer()) {
    if (GAMESTATE && GAMESTATE->m_pPlayerState[PLAYER_1]) {
      pPlayerState->m_PlayerOptions =
          GAMESTATE->m_pPlayerState[PLAYER_1]->m_PlayerOptions;
    }
  }
}

void PlayerInfo::LoadDummyP1(int iDummyIndex, int iAddToDifficulty) {
  m_pn = PLAYER_1;
  m_bPlayerEnabled = IsEnabled();
  m_bIsDummy = true;
  m_iDummyIndex = iDummyIndex;
  m_iAddToDifficulty = iAddToDifficulty;

  // don't init any of the scoring objects
  m_pPlayer = new Player(m_NoteData, true);

  // PlayerOptions needs to be set now so that we load the correct NoteSkin.
  if (GAMESTATE && GAMESTATE->m_pPlayerState[PLAYER_1]) {
    m_PlayerStateDummy = *GAMESTATE->m_pPlayerState[PLAYER_1];
  } else {
    LOG->Warn("SRC_AUDIT_FIX: Dummy PlayerInfo missing PLAYER_1 state.");
    m_bPlayerEnabled = false;
  }
}

PlayerInfo::~PlayerInfo() {
  RageUtil::SafeDelete(m_pLifeMeter);
  RageUtil::SafeDelete(m_ptextCourseSongNumber);
  RageUtil::SafeDelete(m_ptextStepsDescription);
  RageUtil::SafeDelete(m_pPrimaryScoreDisplay);
  RageUtil::SafeDelete(m_pSecondaryScoreDisplay);
  RageUtil::SafeDelete(m_pPrimaryScoreKeeper);
  RageUtil::SafeDelete(m_pSecondaryScoreKeeper);
  RageUtil::SafeDelete(m_ptextPlayerOptions);
  RageUtil::SafeDelete(m_pActiveAttackList);
  RageUtil::SafeDelete(m_pPlayer);
  RageUtil::SafeDelete(m_pInventory);
  RageUtil::SafeDelete(m_pStepsDisplay);
}

void PlayerInfo::ShowOniGameOver() {
  if (!m_sprOniGameOver.IsLoaded()) {
    LOG->Warn("SRC_AUDIT_FIX: Oni gameover actor is not loaded for %s.",
              GetName().c_str());
    return;
  }
  m_sprOniGameOver->PlayCommand("Die");
}

PlayerState* PlayerInfo::GetPlayerState() {
  if (m_bIsDummy) {
    return &m_PlayerStateDummy;
  }
  if (GAMESTATE == nullptr) {
    return nullptr;
  }
  if (IsMultiPlayer()) {
    if (!IsValidGameplayMultiPlayer(m_mp)) {
      return nullptr;
    }
    return GAMESTATE->m_pMultiPlayerState[m_mp];
  }
  if (!IsValidGameplayPlayer(m_pn)) {
    return nullptr;
  }
  return GAMESTATE->m_pPlayerState[m_pn];
}

PlayerStageStats* PlayerInfo::GetPlayerStageStats() {
  // multiplayer chooses the PlayerStageStats with the highest score on
  // StageFinalized
  if (m_bIsDummy || IsMultiPlayer()) {
    return &m_PlayerStageStatsDummy;
  }
  if (STATSMAN == nullptr || !IsValidGameplayPlayer(m_pn)) {
    return nullptr;
  }
  return &STATSMAN->m_CurStageStats.m_player[m_pn];
}

bool PlayerInfo::IsEnabled() {
  if (GAMESTATE == nullptr) {
    return false;
  }
  if (m_pn != PLAYER_INVALID) {
    if (!IsValidGameplayPlayer(m_pn)) {
      return false;
    }
    return GAMESTATE->IsPlayerEnabled(m_pn);
  }
  if (m_mp != MultiPlayer_Invalid) {
    if (!IsValidGameplayMultiPlayer(m_mp)) {
      return false;
    }
    return GAMESTATE->IsMultiPlayerEnabled(m_mp);
  }
  if (m_bIsDummy) {
    return true;
  }
  LOG->Warn("SRC_AUDIT_FIX: PlayerInfo::IsEnabled rejected invalid player.");
  return false;
}

std::vector<PlayerInfo>::iterator GetNextEnabledPlayerInfo(
    std::vector<PlayerInfo>::iterator iter, std::vector<PlayerInfo>& v) {
  for (; iter != v.end(); ++iter) {
    if (!iter->m_bPlayerEnabled) {
      continue;
    }
    return iter;
  }
  return iter;
}

std::vector<PlayerInfo>::iterator GetNextEnabledPlayerInfoNotDummy(
    std::vector<PlayerInfo>::iterator iter, std::vector<PlayerInfo>& v) {
  for (; iter != v.end(); iter++) {
    if (iter->m_bIsDummy) {
      continue;
    }
    if (!iter->m_bPlayerEnabled) {
      continue;
    }
    return iter;
  }
  return iter;
}

std::vector<PlayerInfo>::iterator GetNextEnabledPlayerNumberInfo(
    std::vector<PlayerInfo>::iterator iter, std::vector<PlayerInfo>& v) {
  for (; iter != v.end(); ++iter) {
    if (iter->m_bIsDummy) {
      continue;
    }
    if (!iter->m_bPlayerEnabled) {
      continue;
    }
    if (iter->m_mp != MultiPlayer_Invalid) {
      continue;
    }
    return iter;
  }
  return iter;
}

std::vector<PlayerInfo>::iterator GetNextPlayerNumberInfo(
    std::vector<PlayerInfo>::iterator iter, std::vector<PlayerInfo>& v) {
  for (; iter != v.end(); ++iter) {
    if (iter->m_bIsDummy) {
      continue;
    }
    if (iter->m_pn == PLAYER_INVALID) {
      continue;
    }
    return iter;
  }
  return iter;
}

std::vector<PlayerInfo>::iterator GetNextVisiblePlayerInfo(
    std::vector<PlayerInfo>::iterator iter, std::vector<PlayerInfo>& v) {
  for (; iter != v.end(); ++iter) {
    if (iter->m_pPlayer == nullptr || !iter->m_pPlayer->HasVisibleParts()) {
      continue;
    }
    return iter;
  }
  return iter;
}

static PlayerState* GetPlayerStateOrWarn(
    PlayerInfo& pi, const char* context) {
  PlayerState* playerState = pi.GetPlayerState();
  if (playerState == nullptr) {
    LOG->Warn(
        "SRC_AUDIT_FIX: %s skipped %s because PlayerState is missing.",
        context, pi.GetName().c_str());
  }
  return playerState;
}

static PlayerStageStats* GetPlayerStageStatsOrWarn(
    PlayerInfo& pi, const char* context) {
  PlayerStageStats* stageStats = pi.GetPlayerStageStats();
  if (stageStats == nullptr) {
    LOG->Warn(
        "SRC_AUDIT_FIX: %s skipped %s because PlayerStageStats is missing.",
        context, pi.GetName().c_str());
  }
  return stageStats;
}

static bool IsUsableStepsAndTrailIndex(PlayerInfo& pi, const char* context) {
  const PlayerNumber pn = pi.GetStepsAndTrailIndex();
  if (!IsValidGameplayPlayer(pn)) {
    LOG->Warn(
        "SRC_AUDIT_FIX: %s skipped %s because steps/trail index %i is invalid.",
        context, pi.GetName().c_str(), static_cast<int>(pn));
    return false;
  }
  return true;
}

static void BroadcastGameplayMessage(const MessageID message) {
  if (MESSAGEMAN == nullptr) {
    LOG->Warn(
        "SRC_AUDIT_FIX: dropped gameplay message id %d because MESSAGEMAN is "
        "missing.",
        static_cast<int>(message));
    return;
  }
  MESSAGEMAN->Broadcast(message);
}

static void BroadcastGameplayMessage(const std::string& message) {
  if (MESSAGEMAN == nullptr) {
    LOG->Warn(
        "SRC_AUDIT_FIX: dropped gameplay message '%s' because MESSAGEMAN is "
        "missing.",
        message.c_str());
    return;
  }
  MESSAGEMAN->Broadcast(message);
}

static void BroadcastGameplayMessage(Message& message) {
  if (MESSAGEMAN == nullptr) {
    LOG->Warn("SRC_AUDIT_FIX: dropped gameplay Message because MESSAGEMAN is "
              "missing.");
    return;
  }
  MESSAGEMAN->Broadcast(message);
}

static void StopMusicIfLoaded(RageSound* sound) {
  if (sound != nullptr) {
    sound->StopPlaying();
  }
}

struct RepeatTrailSnapshot {
  PlayerNumber pn;
  StepsType stepsType;
  CourseDifficulty difficulty;
};

static bool ValidateGameplayQueues(
    const std::vector<Song*>& songs,
    std::vector<PlayerInfo>& playerInfos,
    const char* context) {
  if (songs.empty()) {
    LOG->Warn("SRC_AUDIT_FIX: %s rejected empty song queue.", context);
    return false;
  }

  for (size_t i = 0; i < songs.size(); ++i) {
    if (songs[i] == nullptr) {
      LOG->Warn(
          "SRC_AUDIT_FIX: %s rejected null song at queue index %zu.",
          context, i);
      return false;
    }
  }

  bool valid = true;
  FOREACH_EnabledPlayerInfo(playerInfos, pi) {
    if (pi->m_vpStepsQueue.size() != songs.size() ||
        pi->m_asModifiersQueue.size() != pi->m_vpStepsQueue.size()) {
      LOG->Warn(
          "SRC_AUDIT_FIX: %s rejected queue mismatch for %s: songs=%zu "
          "steps=%zu modifiers=%zu.",
          context, pi->GetName().c_str(), songs.size(),
          pi->m_vpStepsQueue.size(), pi->m_asModifiersQueue.size());
      valid = false;
      continue;
    }

    for (size_t i = 0; i < pi->m_vpStepsQueue.size(); ++i) {
      if (pi->m_vpStepsQueue[i] == nullptr) {
        LOG->Warn(
            "SRC_AUDIT_FIX: %s rejected null steps for %s at queue index %zu.",
            context, pi->GetName().c_str(), i);
        valid = false;
      }
    }
  }

  return valid;
}

////////////////////////////////////////////////////////////////////////////////

ScreenGameplay::ScreenGameplay() {
  m_pSongBackground = nullptr;
  m_pSongForeground = nullptr;
  m_pCombinedLifeMeter = nullptr;
  m_pSoundMusic = nullptr;
  m_bPaused = false;
  m_PauseController = GameController_Invalid;
  m_gave_up = false;
  m_skipped_song = false;
  m_bPausedMemoryCardMounting = false;
  m_bZeroDeltaOnNextUpdate = false;
  m_DancingState = STATE_INTRO;
  m_fTimeSinceLastDancingComment = 0.0f;
  m_fCurrHasteRate = 1.0f;
  m_fHasteTimeBetweenUpdates = 4.0f;
  m_fHasteLifeSwitchPoint = 0.5f;
  m_delaying_ready_announce = false;
  m_bOnlineEvaluationHoldMessagePending = false;
  m_bOnlineEvaluationHoldStarted = false;
  m_bOnlineFailedHoldStarted = false;
  m_bLoggedStageEndState = false;
  m_bLoggedOnlineEvaluationHold = false;
  m_bLoggedOnlineNotesEndedDuringHold = false;
  m_bMarkedOnlineFailedEarly = false;
  m_bLoggedOnlineLocalFailKeepAlive = false;
  m_fLastSeenEnemyHealth = 1.0f;
  m_iLightsRowLastCrossed = 0;
  m_iBeatRowLastCrossed = 0;
  ZERO(m_iNoteRowLastCrossed);
  if (GAMESTATE != nullptr) {
    GAMESTATE->m_AdjustTokensBySongCostForFinalStageCheck = false;
  }
}

void ScreenGameplay::Init() {
  if (!HasRenderableGameplayManagers("ScreenGameplay::Init")) {
    return;
  }

  SubscribeToMessage("Judgment");

  PLAYER_TYPE.Load(m_sName, "PlayerType");
  PLAYER_INIT_COMMAND.Load(m_sName, "PlayerInitCommand");
  GIVE_UP_START_TEXT.Load(m_sName, "GiveUpStartText");
  GIVE_UP_BACK_TEXT.Load(m_sName, "GiveUpBackText");
  GIVE_UP_ABORTED_TEXT.Load(m_sName, "GiveUpAbortedText");
  SKIP_SONG_TEXT.Load(m_sName, "SkipSongText");
  GIVE_UP_SECONDS.Load(m_sName, "GiveUpSeconds");
  MUSIC_FADE_OUT_SECONDS.Load(m_sName, "MusicFadeOutSeconds");
  OUT_TRANSITION_LENGTH.Load(m_sName, "OutTransitionLength");
  COURSE_TRANSITION_LENGTH.Load(m_sName, "CourseTransitionLength");
  BEGIN_FAILED_DELAY.Load(m_sName, "BeginFailedDelay");
  MIN_SECONDS_TO_STEP.Load(m_sName, "MinSecondsToStep");
  MIN_SECONDS_TO_MUSIC.Load(m_sName, "MinSecondsToMusic");
  MIN_SECONDS_TO_STEP_NEXT_SONG.Load(m_sName, "MinSecondsToStepNextSong");
  START_GIVES_UP.Load(m_sName, "StartGivesUp");
  BACK_GIVES_UP.Load(m_sName, "BackGivesUp");
  SELECT_SKIPS_SONG.Load(m_sName, "SelectSkipsSong");
  GIVING_UP_GOES_TO_PREV_SCREEN.Load(m_sName, "GivingUpGoesToPrevScreen");
  FAIL_ON_MISS_COMBO.Load(m_sName, "FailOnMissCombo");
  ALLOW_CENTER_1_PLAYER.Load(m_sName, "AllowCenter1Player");
  // configurable:
  UNPAUSE_WITH_START.Load(m_sName, "UnpauseWithStart");
  SURVIVAL_MOD_OVERRIDE.Load(m_sName, "SurvivalModOverride");

  // Default values.  The theme can set its own through the Lua interface.
  m_HasteTurningPoints.clear();
  m_HasteTurningPoints.push_back(-1);
  m_HasteTurningPoints.push_back(0);
  m_HasteTurningPoints.push_back(0.3f);
  m_HasteTurningPoints.push_back(1);
  m_HasteAddAmounts.clear();
  m_HasteAddAmounts.push_back(-0.5f);
  m_HasteAddAmounts.push_back(0);
  m_HasteAddAmounts.push_back(0.2f);
  m_HasteAddAmounts.push_back(0.5f);
  m_fHasteTimeBetweenUpdates = 4;
  m_fHasteLifeSwitchPoint = 0.5f;
  m_fCurrHasteRate = 1;  // Should this be in BeginSong?  Not sure whether it
                         // should carry over between songs.

  if (UseSongBackgroundAndForeground()) {
    m_pSongBackground = new Background;
    m_pSongForeground = new Foreground;
  }

  ScreenWithMenuElements::Init();

  this->FillPlayerInfo(m_vPlayerInfo);

  {
    int iNumEnabledPlayers = 0;
    FOREACH_EnabledPlayerInfo(m_vPlayerInfo, pi)++ iNumEnabledPlayers;

    if (m_vPlayerInfo.empty() || iNumEnabledPlayers <= 0) {
      LOG->Warn(
          "SRC_AUDIT_FIX: ScreenGameplay::Init aborted with %zu player infos "
          "and %d enabled players.",
          m_vPlayerInfo.size(), iNumEnabledPlayers);
      PostScreenMessage(SM_GoToPrevScreen, 0);
      return;
    }
  }

  /* Pause MEMCARDMAN.  If a memory card is removed, we don't want to interrupt
   * the player by making a noise until the game finishes. */
  if (!GAMESTATE->m_bDemonstrationOrJukebox && MEMCARDMAN != nullptr) {
    MEMCARDMAN->PauseMountingThread();
    m_bPausedMemoryCardMounting = true;
  }

  m_pSoundMusic = nullptr;
  set_paused_internal(false);

  m_pCombinedLifeMeter = nullptr;

  if (GAMESTATE->m_pCurSong == nullptr && GAMESTATE->m_pCurCourse == nullptr) {
    return;  // ScreenDemonstration will move us to the next screen.  We just
             // need to survive for one update without crashing.
  }

  /* Save settings to the profile now.  Don't do this on extra stages, since the
   * user doesn't have full control; saving would force profiles to
   * Difficulty_Hard and save over their default modifiers every time someone
   * got an extra stage. Do this before course modifiers are set up. */
  if (!GAMESTATE->IsAnExtraStage()) {
    FOREACH_HumanPlayer(pn) {
      GAMESTATE->SaveCurrentSettingsToProfile(pn);
    }
  }

  /* Called once per stage (single song or single course). */
  GAMESTATE->BeginStage();

  // fill in m_apSongsQueue, m_vpStepsQueue, m_asModifiersQueue
  InitSongQueues();
  if (!ValidateGameplayQueues(
          m_apSongsQueue, m_vPlayerInfo, "ScreenGameplay::Init")) {
    LOG->Warn("SRC_AUDIT_FIX: ScreenGameplay has no complete queues to play.");
    PostScreenMessage(SM_GoToPrevScreen, 0);
    return;
  }

  int player = 1;
  FOREACH_EnabledPlayerInfo(m_vPlayerInfo, pi) {
    unsigned int count = pi->m_vpStepsQueue.size();

    for (unsigned int i = 0; i < count; i++) {
      Steps* curSteps = pi->m_vpStepsQueue[i];
      if (curSteps == nullptr) {
        LOG->Warn(
            "SRC_AUDIT_FIX: Missing queued steps for gameplay player %d.",
            player);
        continue;
      }
      if (curSteps->IsNoteDataEmpty()) {
        if (curSteps->GetNoteDataFromSimfile()) {
          LOG->Trace("Notes should be loaded for player %d", player);
        } else {
          LOG->Trace("Error loading notes for player %d", player);
        }
      }
    }
    player++;
  }

  if (!GAMESTATE->IsCourseMode() && !GAMESTATE->m_bDemonstrationOrJukebox) {
    // fill in difficulty of CPU players with that of the first human player
    // this should not need to worry about step content.
    FOREACH_PotentialCpuPlayer(p) {
      PlayerNumber human_pn = GAMESTATE->GetFirstHumanPlayer();
      if (!IsValidGameplayPlayer(human_pn) ||
          GAMESTATE->m_pCurSteps[human_pn] == nullptr ||
          GAMESTATE->GetCurrentGame() == nullptr) {
        LOG->Warn("SRC_AUDIT_FIX: CPU step/style sync skipped because the "
                  "human player or current game is unavailable.");
        continue;
      }
      GAMESTATE->m_pCurSteps[p].Set(GAMESTATE->m_pCurSteps[human_pn]);
      if (GAMESTATE->GetCurrentGame()->m_PlayersHaveSeparateStyles) {
        GAMESTATE->SetCurrentStyle(GAMESTATE->GetCurrentStyle(human_pn), p);
      }
    }

    FOREACH_EnabledPlayer(p) {
      if (GAMESTATE->m_pCurSteps[p].Get() == nullptr) {
        LOG->Warn(
            "SRC_AUDIT_FIX: Enabled player %i has no current steps.",
            static_cast<int>(p));
      }
    }
  }

  /* Increment the course play count. */
  if (GAMESTATE->IsCourseMode() && !GAMESTATE->m_bDemonstrationOrJukebox &&
      PROFILEMAN != nullptr) {
    FOREACH_EnabledPlayer(p) {
      PROFILEMAN->IncrementCoursePlayCount(
          GAMESTATE->m_pCurCourse, GAMESTATE->m_pCurTrail[p], p);
    }
  }

  STATSMAN->m_CurStageStats.m_Stage = GAMESTATE->GetCurrentStage();
  STATSMAN->m_CurStageStats.m_iStageIndex = GAMESTATE->m_iCurrentStageIndex;
  STATSMAN->m_CurStageStats.m_playMode = GAMESTATE->m_PlayMode;
  FOREACH_PlayerNumber(pn) {
    STATSMAN->m_CurStageStats.m_player[pn].m_pStyle =
        GAMESTATE->GetCurrentStyle(pn);
  }
  FOREACH_MultiPlayer(pn) {
    STATSMAN->m_CurStageStats.m_multiPlayer[pn].m_pStyle =
        GAMESTATE->GetCurrentStyle(PLAYER_INVALID);
  }

  /* Record combo rollover. */
  FOREACH_EnabledPlayerInfoNotDummy(m_vPlayerInfo, pi) {
    PlayerStageStats* pss =
        GetPlayerStageStatsOrWarn(*pi, "ScreenGameplay::Init combo rollover");
    if (pss != nullptr) {
      pss->UpdateComboList(0, true);
    }
  }

  m_DancingState = STATE_INTRO;

  // Set this in LoadNextSong()
  // m_fTimeLeftBeforeDancingComment = SECONDS_BETWEEN_COMMENTS;

  m_bZeroDeltaOnNextUpdate = false;

  if (m_pSongBackground) {
    m_pSongBackground->SetName("SongBackground");
    m_pSongBackground->SetDrawOrder(DRAW_ORDER_BEFORE_EVERYTHING);
    ActorUtil::LoadAllCommands(*m_pSongBackground, m_sName);
    this->AddChild(m_pSongBackground);
  }

  if (m_pSongForeground) {
    m_pSongForeground->SetName("SongForeground");
    m_pSongForeground->SetDrawOrder(
        DRAW_ORDER_OVERLAY +
        1);  // on top of the overlay, but under transitions
    ActorUtil::LoadAllCommands(*m_pSongForeground, m_sName);
    this->AddChild(m_pSongForeground);
  }

  if (PREFSMAN->m_bShowBeginnerHelper) {
    m_BeginnerHelper.SetDrawOrder(DRAW_ORDER_BEFORE_EVERYTHING);
    m_BeginnerHelper.SetXY(SCREEN_CENTER_X, SCREEN_CENTER_Y);
    this->AddChild(&m_BeginnerHelper);
  }

  if (!GAMESTATE
           ->m_bDemonstrationOrJukebox)  // only load if we're going to use it
  {
    m_Toasty.Load(THEME->GetPathB(m_sName, "toasty"));
    this->AddChild(&m_Toasty);
  }

  std::vector<NotefieldMargins> margins = GetNotefieldMargins();

  float left_edge[NUM_PLAYERS] = {0.0f, SCREEN_WIDTH / 2.0f};
  FOREACH_EnabledPlayerInfo(m_vPlayerInfo, pi) {
    PlayerNumber layoutPn = pi->GetStepsAndTrailIndex();
    PlayerState* playerState = pi->GetPlayerState();
    if (!IsValidGameplayPlayer(layoutPn) || pi->m_pPlayer == nullptr ||
        playerState == nullptr) {
      LOG->Warn(
          "SRC_AUDIT_FIX: Skipping notefield positioning for invalid %s.",
          pi->GetName().c_str());
      continue;
    }
    std::string sName = ssprintf("Player%s", pi->GetName().c_str());
    pi->m_pPlayer->SetName(sName);

    const Style* style = GAMESTATE->GetCurrentStyle(layoutPn);
    if (style == nullptr || style->GetWidth(layoutPn) <= 0.0f) {
      LOG->Warn(
          "SRC_AUDIT_FIX: Skipping notefield positioning for %s with missing "
          "style.",
          pi->GetName().c_str());
      continue;
    }
    float style_width = style->GetWidth(layoutPn);
    float edge = left_edge[layoutPn];
    float screen_space;
    float field_space;
    float left_marge;
    float right_marge;
#define CENTER_PLAYER_BLOCK                                \
  {                                                        \
    edge = 0.0f;                                           \
    screen_space = SCREEN_WIDTH;                           \
    left_marge = margins[PLAYER_1].left;                   \
    right_marge = margins[PLAYER_2].right;                 \
    field_space = screen_space - left_marge - right_marge; \
  }
    // If pi->m_pn is set, then the player will be visible.  If not, then it's
    // not visible and don't bother setting its position.
    if (GAMESTATE->m_bMultiplayer && !pi->m_bIsDummy) {
      CENTER_PLAYER_BLOCK
    } else {
      screen_space = SCREEN_WIDTH / 2.0f;
      left_marge = margins[layoutPn].left;
      right_marge = margins[layoutPn].right;
      field_space = screen_space - left_marge - right_marge;
      if (Center1Player() ||
          style->m_StyleType == StyleType_TwoPlayersSharedSides ||
          (style_width > field_space &&
           GAMESTATE->GetNumPlayersEnabled() == 1 &&
           (bool)ALLOW_CENTER_1_PLAYER)) {
        CENTER_PLAYER_BLOCK
      }
    }
#undef CENTER_PLAYER_BLOCK
    float player_x = edge + left_marge + (field_space / 2.0f);
    float field_zoom = field_space / style_width;
    /*
    LuaHelpers::ReportScriptErrorFmt("Positioning player %d at %.0f:  "
            "screen_space %.0f, left_edge %.0f, field_space %.0f, left_marge
    %.0f," " right_marge %.0f, style_width %.0f, field_zoom %.2f.", pi->m_pn+1,
    player_x, screen_space, left_edge[pi->m_pn], field_space, left_marge,
    right_marge, style_width, field_zoom);
    */
    playerState->m_NotefieldZoom = std::min(1.0f, field_zoom);

    pi->m_pPlayer->SetX(player_x);
    pi->m_pPlayer->RunCommands(PLAYER_INIT_COMMAND);
    // ActorUtil::LoadAllCommands(pi->m_pPlayer, m_sName);
    this->AddChild(pi->m_pPlayer);
    pi->m_pPlayer->PlayCommand("On");
  }

  FOREACH_EnabledPlayerInfoNotDummy(m_vPlayerInfo, pi) {
    if (pi->m_pPlayer != nullptr && pi->m_pPlayer->HasVisibleParts()) {
      pi->m_sprOniGameOver.Load(THEME->GetPathG(m_sName, "oni gameover"));
      if (pi->m_sprOniGameOver.IsLoaded()) {
        pi->m_sprOniGameOver->SetName(
            ssprintf("OniGameOver%s", pi->GetName().c_str()));
        LOAD_ALL_COMMANDS_AND_SET_XY(pi->m_sprOniGameOver);
        this->AddChild(pi->m_sprOniGameOver);
      }
    }
  }

  m_NextSong.Load(THEME->GetPathB(m_sName, "next course song"));
  m_NextSong.SetDrawOrder(DRAW_ORDER_TRANSITIONS - 1);
  this->AddChild(&m_NextSong);

  // Add combined life meter
  switch (GAMESTATE->m_PlayMode) {
    case PLAY_MODE_BATTLE:
    case PLAY_MODE_RAVE:
      m_pCombinedLifeMeter = new CombinedLifeMeterTug;
      m_pCombinedLifeMeter->SetName("CombinedLife");
      LOAD_ALL_COMMANDS_AND_SET_XY(*m_pCombinedLifeMeter);
      this->AddChild(m_pCombinedLifeMeter);
    default:
      break;
  }

  // Add individual life meter
  switch (GAMESTATE->m_PlayMode) {
    case PLAY_MODE_REGULAR:
    case PLAY_MODE_ONI:
    case PLAY_MODE_NONSTOP:
    case PLAY_MODE_ENDLESS:
      FOREACH_PlayerNumberInfo(m_vPlayerInfo, pi) {
        if (!GAMESTATE->IsPlayerEnabled(pi->m_pn) &&
            !SHOW_LIFE_METER_FOR_DISABLED_PLAYERS) {
          continue;  // skip
        }

        PlayerState* playerState =
            GetPlayerStateOrWarn(*pi, "ScreenGameplay::Init life meter");
        PlayerStageStats* stageStats =
            GetPlayerStageStatsOrWarn(*pi, "ScreenGameplay::Init life meter");
        if (playerState == nullptr || stageStats == nullptr) {
          continue;
        }

        pi->m_pLifeMeter = LifeMeter::MakeLifeMeter(
            playerState->m_PlayerOptions.GetStage().m_LifeType);
        if (pi->m_pLifeMeter == nullptr) {
          LOG->Warn("SRC_AUDIT_FIX: LifeMeter creation failed for %s.",
                    pi->GetName().c_str());
          continue;
        }
        pi->m_pLifeMeter->Load(playerState, stageStats);
        pi->m_pLifeMeter->SetName(ssprintf("Life%s", pi->GetName().c_str()));
        LOAD_ALL_COMMANDS_AND_SET_XY(pi->m_pLifeMeter);
        this->AddChild(pi->m_pLifeMeter);

        // HACK: When SHOW_LIFE_METER_FOR_DISABLED_PLAYERS is enabled,
        // we don't want to have any life in the disabled player's life
        // meter. I think this only happens with LifeMeterBars, but I'm
        // not 100% sure of that. -freem
        if (!GAMESTATE->IsPlayerEnabled(pi->m_pn) &&
            SHOW_LIFE_METER_FOR_DISABLED_PLAYERS) {
          if (playerState->m_PlayerOptions.GetStage().m_LifeType ==
              LifeType_Bar) {
            static_cast<LifeMeterBar*>(pi->m_pLifeMeter)->ChangeLife(-1.0f);
          }
        }
      }
      break;
    case PLAY_MODE_BATTLE:
    case PLAY_MODE_RAVE:
    default:
      break;
  }

  FOREACH_EnabledPlayerInfo(m_vPlayerInfo, pi) {
    // primary score display
    if (pi->m_pPrimaryScoreDisplay) {
      pi->m_pPrimaryScoreDisplay->SetName(
          ssprintf("Score%s", pi->GetName().c_str()));
      LOAD_ALL_COMMANDS_AND_SET_XY(pi->m_pPrimaryScoreDisplay);
      if (GAMESTATE->m_PlayMode != PLAY_MODE_RAVE ||
          SHOW_SCORE_IN_RAVE) { /* XXX: ugly */
        this->AddChild(pi->m_pPrimaryScoreDisplay);
      }
    }

    // secondary score display
    if (pi->m_pSecondaryScoreDisplay) {
      pi->m_pSecondaryScoreDisplay->SetName(
          ssprintf("SecondaryScore%s", pi->GetName().c_str()));
      LOAD_ALL_COMMANDS_AND_SET_XY(pi->m_pSecondaryScoreDisplay);
      this->AddChild(pi->m_pSecondaryScoreDisplay);
    }
  }

  // Add stage / SongNumber
  FOREACH_EnabledPlayerNumberInfo(m_vPlayerInfo, pi) {
    if (GAMESTATE->IsCourseMode()) {
      ASSERT(pi->m_ptextCourseSongNumber == nullptr);
      SONG_NUMBER_FORMAT.Load(m_sName, "SongNumberFormat");
      pi->m_ptextCourseSongNumber = new BitmapText;
      pi->m_ptextCourseSongNumber->LoadFromFont(
          THEME->GetPathF(m_sName, "SongNum"));
      pi->m_ptextCourseSongNumber->SetName(
          ssprintf("SongNumber%s", pi->GetName().c_str()));
      LOAD_ALL_COMMANDS_AND_SET_XY(pi->m_ptextCourseSongNumber);
      pi->m_ptextCourseSongNumber->SetText("");
      // pi->m_ptextCourseSongNumber->SetDiffuse( RageColor(0,0.5f,1,1) );
      // // light blue
      this->AddChild(pi->m_ptextCourseSongNumber);
    }

    ASSERT(pi->m_ptextStepsDescription == nullptr);
    pi->m_ptextStepsDescription = new BitmapText;
    pi->m_ptextStepsDescription->LoadFromFont(
        THEME->GetPathF(m_sName, "StepsDescription"));
    pi->m_ptextStepsDescription->SetName(
        ssprintf("StepsDescription%s", pi->GetName().c_str()));
    LOAD_ALL_COMMANDS_AND_SET_XY(pi->m_ptextStepsDescription);
    this->AddChild(pi->m_ptextStepsDescription);

    // Player/Song options
    ASSERT(pi->m_ptextPlayerOptions == nullptr);
    pi->m_ptextPlayerOptions = new BitmapText;
    pi->m_ptextPlayerOptions->LoadFromFont(
        THEME->GetPathF(m_sName, "player options"));
    pi->m_ptextPlayerOptions->SetName(
        ssprintf("PlayerOptions%s", pi->GetName().c_str()));
    LOAD_ALL_COMMANDS_AND_SET_XY(pi->m_ptextPlayerOptions);
    this->AddChild(pi->m_ptextPlayerOptions);

    // Difficulty icon and meter
    ASSERT(pi->m_pStepsDisplay == nullptr);
    pi->m_pStepsDisplay = new StepsDisplay;
    PlayerState* playerState =
        GetPlayerStateOrWarn(*pi, "ScreenGameplay::Init steps display");
    if (playerState == nullptr) {
      continue;
    }
    pi->m_pStepsDisplay->Load("StepsDisplayGameplay", playerState);
    pi->m_pStepsDisplay->SetName(
        ssprintf("StepsDisplay%s", pi->GetName().c_str()));
    PlayerNumber pn = pi->GetStepsAndTrailIndex();
    if (pn != PlayerNumber_Invalid) {
      pi->m_pStepsDisplay->PlayCommand("Set" + pi->GetName());
    }
    LOAD_ALL_COMMANDS_AND_SET_XY(pi->m_pStepsDisplay);
    this->AddChild(pi->m_pStepsDisplay);

    /*
                    switch( GAMESTATE->m_PlayMode )
                    {
                    case PLAY_MODE_BATTLE:
                            pi->m_pInventory = new Inventory;
                            pi->m_pInventory->Load( p );
                            this->AddChild( pi->m_pInventory );
                            break;
                    }
    */
  }

  m_textSongOptions.LoadFromFont(THEME->GetPathF(m_sName, "song options"));
  m_textSongOptions.SetShadowLength(0);
  m_textSongOptions.SetName("SongOptions");
  LOAD_ALL_COMMANDS_AND_SET_XY(m_textSongOptions);
  m_textSongOptions.SetText(
      GAMESTATE->m_SongOptions.GetStage().GetLocalizedString());
  this->AddChild(&m_textSongOptions);

  FOREACH_VisiblePlayerInfo(m_vPlayerInfo, pi) {
    ASSERT(pi->m_pActiveAttackList == nullptr);
    PlayerState* playerState =
        GetPlayerStateOrWarn(*pi, "ScreenGameplay::Init active attacks");
    if (playerState == nullptr) {
      continue;
    }
    pi->m_pActiveAttackList = new ActiveAttackList;
    pi->m_pActiveAttackList->LoadFromFont(
        THEME->GetPathF(m_sName, "ActiveAttackList"));
    pi->m_pActiveAttackList->Init(playerState);
    pi->m_pActiveAttackList->SetName(
        ssprintf("ActiveAttackList%s", pi->GetName().c_str()));
    LOAD_ALL_COMMANDS_AND_SET_XY(pi->m_pActiveAttackList);
    this->AddChild(pi->m_pActiveAttackList);
  }

  if (g_bShowLyrics) {
    m_LyricDisplay.SetName("LyricDisplay");
    LOAD_ALL_COMMANDS(m_LyricDisplay);
    this->AddChild(&m_LyricDisplay);
  }

  if (!GAMESTATE
           ->m_bDemonstrationOrJukebox)  // only load if we're going to use it
  {
    m_Ready.Load(THEME->GetPathB(m_sName, "ready"));
    this->AddChild(&m_Ready);

    m_Go.Load(THEME->GetPathB(m_sName, "go"));
    this->AddChild(&m_Go);

    m_Failed.Load(THEME->GetPathB(m_sName, "failed"));
    m_Failed.SetDrawOrder(
        DRAW_ORDER_TRANSITIONS - 1);  // on top of everything else
    this->AddChild(&m_Failed);

    m_textDebug.LoadFromFont(THEME->GetPathF(m_sName, "debug"));
    m_textDebug.SetName("Debug");
    LOAD_ALL_COMMANDS_AND_SET_XY(m_textDebug);
    m_textDebug.SetDrawOrder(
        DRAW_ORDER_TRANSITIONS -
        1);  // just under transitions, over the foreground
    this->AddChild(&m_textDebug);

    m_GameplayAssist.Init();

    if (GAMESTATE->IsAnExtraStage())  // only load if we're going to use it
    {
      m_textSurviveTime.LoadFromFont(THEME->GetPathF(m_sName, "survive time"));
      m_textSurviveTime.SetShadowLength(0);
      m_textSurviveTime.SetName("SurviveTime");
      LOAD_ALL_COMMANDS_AND_SET_XY(m_textSurviveTime);
      m_textSurviveTime.SetDrawOrder(DRAW_ORDER_TRANSITIONS - 1);
      m_textSurviveTime.SetDiffuse(RageColor(1, 1, 1, 0));
      this->AddChild(&m_textSurviveTime);
    }

    switch (GAMESTATE->m_PlayMode) {
      case PLAY_MODE_BATTLE:
        m_soundBattleTrickLevel1.Load(
            THEME->GetPathS(m_sName, "battle trick level1"), true);
        m_soundBattleTrickLevel2.Load(
            THEME->GetPathS(m_sName, "battle trick level2"), true);
        m_soundBattleTrickLevel3.Load(
            THEME->GetPathS(m_sName, "battle trick level3"), true);
      default:
        break;
    }
  }

  if (m_pSongBackground) {
    m_pSongBackground->Init();
  }

  FOREACH_EnabledPlayerInfo(m_vPlayerInfo, pi) {
    PlayerState* playerState =
        GetPlayerStateOrWarn(*pi, "ScreenGameplay::Init player");
    PlayerStageStats* stageStats =
        GetPlayerStageStatsOrWarn(*pi, "ScreenGameplay::Init player");
    if (pi->m_pPlayer == nullptr || playerState == nullptr ||
        stageStats == nullptr) {
      continue;
    }
    std::string sType = PLAYER_TYPE;
    if (pi->m_bIsDummy) {
      sType += "Dummy";
    }
    pi->m_pPlayer->Init(
        sType, playerState, stageStats, pi->m_pLifeMeter, m_pCombinedLifeMeter,
        pi->m_pPrimaryScoreDisplay,
        pi->m_pSecondaryScoreDisplay, pi->m_pInventory,
        pi->m_pPrimaryScoreKeeper, pi->m_pSecondaryScoreKeeper);
  }

  // Fill StageStats
  STATSMAN->m_CurStageStats.m_vpPossibleSongs = m_apSongsQueue;
  for (PlayerInfo& pi : m_vPlayerInfo) {
    if (pi.GetPlayerStageStats()) {
      pi.GetPlayerStageStats()->m_vpPossibleSteps = pi.m_vpStepsQueue;
    }
  }

  FOREACH_EnabledPlayerInfo(m_vPlayerInfo, pi) {
    if (pi->m_vpStepsQueue.empty()) {
      LOG->Warn("SRC_AUDIT_FIX: ScoreKeeper load skipped for %s with empty "
                "steps queue.",
                pi->GetName().c_str());
      continue;
    }
    if (pi->GetPlayerStageStats()) {
      pi->GetPlayerStageStats()->m_bJoined = true;
    }
    if (pi->m_pPrimaryScoreKeeper) {
      pi->m_pPrimaryScoreKeeper->Load(
          m_apSongsQueue, pi->m_vpStepsQueue, pi->m_asModifiersQueue);
    }
    if (pi->m_pSecondaryScoreKeeper) {
      pi->m_pSecondaryScoreKeeper->Load(
          m_apSongsQueue, pi->m_vpStepsQueue, pi->m_asModifiersQueue);
    }
  }

  GAMESTATE->m_bGameplayLeadIn.Set(true);

  /* LoadNextSong first, since that positions some elements which need to be
   * positioned before we TweenOnScreen. */
  LoadNextSong();

  m_GiveUpTimer.SetZero();
  m_SkipSongTimer.SetZero();
  m_gave_up = false;
  m_skipped_song = false;
}

bool ScreenGameplay::Center1Player() const {
  if (GAMESTATE == nullptr) {
    return false;
  }
  /* Perhaps this should be handled better by defining a new
   * StyleType for ONE_PLAYER_ONE_CREDIT_AND_ONE_COMPUTER,
   * but for now just ignore Center1Player when it's Battle or Rave
   * Mode. This doesn't begin to address two-player solo (6 arrows)
   *
   * If this check is modified, also modify the center check in
   * ScreenEdit::Init().
   */
  const Style* style = GAMESTATE->GetCurrentStyle(PLAYER_INVALID);
  return style != nullptr && g_bCenter1Player && (bool)ALLOW_CENTER_1_PLAYER &&
         GAMESTATE->m_PlayMode != PLAY_MODE_BATTLE &&
         GAMESTATE->m_PlayMode != PLAY_MODE_RAVE &&
         style->m_StyleType == StyleType_OnePlayerOneSide;
}

bool ScreenGameplay::MenuRestart(const InputEventPlus& input) {
  if (IsTransitioning()) {
    return false;
  }

  if (SCREENMAN != nullptr && SCREENMAN->GetTopScreen() != nullptr) {
    SCREENMAN->GetTopScreen()->SetPrevScreenName("ScreenGameplay");
  }
  BeginBackingOutFromGameplay();
  return true;
}

// fill in m_apSongsQueue, m_vpStepsQueue, m_asModifiersQueue
void ScreenGameplay::InitSongQueues() {
  m_apSongsQueue.clear();
  for (PlayerInfo& pi : m_vPlayerInfo) {
    pi.m_vpStepsQueue.clear();
    pi.m_asModifiersQueue.clear();
  }

  if (GAMESTATE->IsCourseMode()) {
    Course* pCourse = GAMESTATE->m_pCurCourse;
    if (pCourse == nullptr) {
      LOG->Warn("SRC_AUDIT_FIX: Course gameplay has no current course.");
      return;
    }

    PlayerNumber pnMaster = GAMESTATE->GetMasterPlayerNumber();
    if (!IsValidGameplayPlayer(pnMaster)) {
      LOG->Warn(
          "SRC_AUDIT_FIX: Course gameplay has invalid master player %i.",
          static_cast<int>(pnMaster));
      return;
    }
    Trail* pTrail = GAMESTATE->m_pCurTrail[pnMaster];
    if (pTrail == nullptr) {
      LOG->Warn("SRC_AUDIT_FIX: Course gameplay has no master trail.");
      return;
    }
    for (const TrailEntry& e : pTrail->m_vEntries) {
      if (e.pSong != nullptr) {
        m_apSongsQueue.push_back(e.pSong);
      } else {
        LOG->Warn("SRC_AUDIT_FIX: Ignoring null song in master trail.");
      }
    }

    FOREACH_EnabledPlayerInfo(m_vPlayerInfo, pi) {
      Trail* lTrail = GAMESTATE->m_pCurTrail[pi->GetStepsAndTrailIndex()];
      if (lTrail == nullptr) {
        LOG->Warn(
            "SRC_AUDIT_FIX: Course gameplay missing trail for %s.",
            pi->GetName().c_str());
        continue;
      }

      for (const TrailEntry& e : lTrail->m_vEntries) {
        if (e.pSteps == nullptr) {
          LOG->Warn(
              "SRC_AUDIT_FIX: Ignoring null steps in trail for %s.",
              pi->GetName().c_str());
          continue;
        }
        pi->m_vpStepsQueue.push_back(e.pSteps);
        AttackArray a;
        e.GetAttackArray(a);
        pi->m_asModifiersQueue.push_back(a);
      }
      if (pi->m_vpStepsQueue.size() != m_apSongsQueue.size()) {
        LOG->Warn(
            "SRC_AUDIT_FIX: Course queue size mismatch for %s: songs=%zu "
            "steps=%zu.",
            pi->GetName().c_str(), m_apSongsQueue.size(),
            pi->m_vpStepsQueue.size());
      }

      // In a survival course, override stored mods
      if (pCourse->GetCourseType() == COURSE_TYPE_SURVIVAL &&
          SURVIVAL_MOD_OVERRIDE) {
        PlayerState* playerState = GetPlayerStateOrWarn(
            *pi, "ScreenGameplay::InitSongQueues survival override");
        if (playerState == nullptr) {
          continue;
        }
        playerState->m_PlayerOptions.FromString(
            ModsLevel_Stage,
            "clearall," + CommonMetrics::DEFAULT_NOTESKIN_NAME.GetValue() +
                "," + CommonMetrics::DEFAULT_MODIFIERS.GetValue());
        playerState->RebuildPlayerOptionsFromActiveAttacks();
      }
    }
  } else {
    if (GAMESTATE->m_pCurSong == nullptr) {
      LOG->Warn("SRC_AUDIT_FIX: Song gameplay has no current song.");
      return;
    }
    m_apSongsQueue.push_back(GAMESTATE->m_pCurSong);
    FOREACH_EnabledPlayerInfo(m_vPlayerInfo, pi) {
      Steps* pSteps = GAMESTATE->m_pCurSteps[pi->GetStepsAndTrailIndex()];
      if (pSteps == nullptr) {
        LOG->Warn(
            "SRC_AUDIT_FIX: Song gameplay missing steps for %s.",
            pi->GetName().c_str());
        continue;
      }
      pi->m_vpStepsQueue.push_back(pSteps);
      PlayerState* playerState =
          GetPlayerStateOrWarn(*pi, "ScreenGameplay::InitSongQueues song");
      if (playerState == nullptr) {
        AttackArray aa;
        pi->m_asModifiersQueue.push_back(aa);
        continue;
      }
      const PlayerOptions& p =
          playerState->m_PlayerOptions.GetCurrent();

      if (p.m_fNoAttack == 0 && p.m_fRandAttack == 0 &&
          pSteps->m_Attacks.size() > 0) {
        pi->m_asModifiersQueue.push_back(pSteps->m_Attacks);
      } else {
        AttackArray aa;
        pi->m_asModifiersQueue.push_back(aa);
      }
    }
  }

  if (GAMESTATE->m_bMultiplayer) {
    for (int i = 0; i < (int)m_apSongsQueue.size(); i++) {
      Song* pSong = m_apSongsQueue[i];

      FOREACH_EnabledPlayerInfo(m_vPlayerInfo, pi) {
        if (i >= static_cast<int>(pi->m_vpStepsQueue.size())) {
          LOG->Warn(
              "SRC_AUDIT_FIX: Multiplayer queue too short for %s at song %i.",
              pi->GetName().c_str(), i);
          continue;
        }
        Steps* pOldSteps = pi->m_vpStepsQueue[i];
        if (pSong == nullptr || pOldSteps == nullptr) {
          continue;
        }

        std::vector<Steps*> vpSteps;
        SongUtil::GetSteps(pSong, vpSteps, pOldSteps->m_StepsType);
        if (vpSteps.empty()) {
          LOG->Warn(
              "SRC_AUDIT_FIX: No multiplayer steps for %s in %s.",
              pi->GetName().c_str(), pSong->GetTranslitFullTitle().c_str());
          continue;
        }
        StepsUtil::SortNotesArrayByDifficulty(vpSteps);
        std::vector<Steps*>::iterator iter =
            find(vpSteps.begin(), vpSteps.end(), pOldSteps);
        int iIndexBase = 0;
        if (iter != vpSteps.end()) {
          iIndexBase = iter - vpSteps.begin();
          rage_clamp(
              iIndexBase, 0,
              static_cast<int>(vpSteps.size()) -
                  GAMESTATE->m_iNumMultiplayerNoteFields);
        }

        int iIndexToUse = iIndexBase + pi->m_iAddToDifficulty;
        rage_clamp(iIndexToUse, 0, static_cast<int>(vpSteps.size()) - 1);

        Steps* pSteps = vpSteps[iIndexToUse];
        pi->m_vpStepsQueue[i] = pSteps;
      }
    }
  }
}

ScreenGameplay::~ScreenGameplay() {
  if (GAMESTATE != nullptr) {
    GAMESTATE->m_AdjustTokensBySongCostForFinalStageCheck = true;
  }
  if (GAMESTATE != nullptr && this->IsFirstUpdate()) {
    /* We never received any updates. That means we were deleted without being
     * used, and never actually played. (This can happen when backing out of
     * ScreenStage.) Cancel the stage. */
    GAMESTATE->CancelStage();
  }

  LOG->Trace("ScreenGameplay::~ScreenGameplay()");

  RageUtil::SafeDelete(m_pSongBackground);
  RageUtil::SafeDelete(m_pSongForeground);

  if (m_bPausedMemoryCardMounting && MEMCARDMAN != nullptr) {
    MEMCARDMAN->UnPauseMountingThread();
    m_bPausedMemoryCardMounting = false;
  }

  RageUtil::SafeDelete(m_pCombinedLifeMeter);
  if (m_pSoundMusic) {
    m_pSoundMusic->StopPlaying();
  }

  m_GameplayAssist.StopPlaying();
}

bool ScreenGameplay::IsLastSong() {
  if (GAMESTATE == nullptr) {
    return true;
  }
  if (GAMESTATE->m_pCurCourse) {
    if (GAMESTATE->m_pCurCourse->m_fGoalSeconds > 0 &&
        GAMESTATE->m_bWorkoutGoalComplete) {
      return true;
    }
  }
  if (GAMESTATE->m_pCurCourse && GAMESTATE->m_pCurCourse->m_bRepeat) {
    return false;
  }
  return GAMESTATE->GetCourseSongIndex() >=
         (int)m_apSongsQueue.size() - 1;  // GetCourseSongIndex() is 0-based
}

bool ScreenGameplay::SetupSong(int iSongIndex) {
  if (iSongIndex < 0 ||
      iSongIndex >= static_cast<int>(m_apSongsQueue.size())) {
    LOG->Warn(
        "SRC_AUDIT_FIX: SetupSong rejected invalid song index %i/%zu.",
        iSongIndex, m_apSongsQueue.size());
    return false;
  }
  bool complete = true;
  FOREACH_EnabledPlayerInfo(m_vPlayerInfo, pi) {
    PlayerState* playerState =
        GetPlayerStateOrWarn(*pi, "ScreenGameplay::SetupSong");
    if (playerState == nullptr || pi->m_pPlayer == nullptr ||
        !IsUsableStepsAndTrailIndex(*pi, "ScreenGameplay::SetupSong")) {
      complete = false;
      continue;
    }

    /* This is the first beat that can be changed without it being visible.
     * Until we draw for the first time, any beat can be changed. */
    playerState->m_fLastDrawnBeat = -100;

    if (iSongIndex >= static_cast<int>(pi->m_vpStepsQueue.size()) ||
        iSongIndex >= static_cast<int>(pi->m_asModifiersQueue.size())) {
      LOG->Warn(
          "SRC_AUDIT_FIX: SetupSong missing queued data for %s at %i.",
          pi->GetName().c_str(), iSongIndex);
      complete = false;
      continue;
    }
    Steps* pSteps = pi->m_vpStepsQueue[iSongIndex];
    if (pSteps == nullptr) {
      LOG->Warn(
          "SRC_AUDIT_FIX: SetupSong skipped null steps for %s.",
          pi->GetName().c_str());
      complete = false;
      continue;
    }
    const PlayerNumber stepsPn = pi->GetStepsAndTrailIndex();
    GAMESTATE->m_pCurSteps[stepsPn].Set(pSteps);

    /* Load new NoteData into Player. Do this before
     * RebuildPlayerOptionsFromActiveAttacks or else transform mods will get
     * propagated to GAMESTATE->m_pPlayerOptions too early and be double-applied
     * to the NoteData:
     * once in Player::Load, then again in Player::ApplyActiveAttacks.
     * This is very bad for transforms like AddMines.
     */
    NoteData originalNoteData;
    pSteps->GetNoteData(originalNoteData);

    const PlayerNumber stylePn =
        pi->IsMultiPlayer() ? PLAYER_INVALID : stepsPn;
    const Style* pStyle = GAMESTATE->GetCurrentStyle(stylePn);
    if (pStyle == nullptr) {
      LOG->Warn(
          "SRC_AUDIT_FIX: SetupSong skipped %s because style is missing.",
          pi->GetName().c_str());
      complete = false;
      continue;
    }
    NoteData ndTransformed;
    pStyle->GetTransformedNoteDataForStyle(
        stepsPn, originalNoteData, ndTransformed);

    // HACK: Apply NoteSkins from global course options. Do this before
    // Player::Load, since it needs to know which note skin to load.
    playerState->m_ModsToApply.clear();
    for (unsigned i = 0; i < pi->m_asModifiersQueue[iSongIndex].size(); ++i) {
      Attack a = pi->m_asModifiersQueue[iSongIndex][i];
      if (a.fStartSecond != 0) {
        continue;
      }
      a.fStartSecond = ATTACK_STARTS_NOW;  // now

      PlayerOptions po;
      po.FromString(a.sModifiers);
      if (po.m_sNoteSkin.empty()) {
        continue;
      }
      a.sModifiers = po.m_sNoteSkin;

      playerState->LaunchAttack(a);
    }

    /* Update attack bOn flags, and rebuild Current-level options
     * from Song-level options. The current NoteSkin could have changed
     * because of an attack ending. */
    playerState->Update(0);

    // load player
    {
      pi->m_NoteData = ndTransformed;
      NoteDataUtil::RemoveAllTapsOfType(
          pi->m_NoteData, TapNoteType_AutoKeysound);
      pi->m_pPlayer->Load();
    }

    // load auto keysounds
    {
      NoteData nd = ndTransformed;
      NoteDataUtil::RemoveAllTapsExceptForType(nd, TapNoteType_AutoKeysound);
      m_AutoKeysounds.Load(stepsPn, nd);
    }

    {
      std::string sType;
      switch (GAMESTATE->m_SongOptions.GetCurrent().m_SoundEffectType) {
        case SoundEffectType_Off:
          sType = "SoundEffectControl_Off";
          break;
        case SoundEffectType_Speed:
          sType = "SoundEffectControl_Speed";
          break;
        case SoundEffectType_Pitch:
          sType = "SoundEffectControl_Pitch";
          break;
        default:
          break;
      }

      pi->m_SoundEffectControl.Load(
          sType, playerState, &pi->m_NoteData);
    }

    // Put course options into effect.  Do this after Player::Load so
    // that mods aren't double-applied.
    playerState->m_ModsToApply.clear();
    for (unsigned i = 0; i < pi->m_asModifiersQueue[iSongIndex].size(); ++i) {
      Attack a = pi->m_asModifiersQueue[iSongIndex][i];
      if (a.fStartSecond == 0) {
        a.fStartSecond = ATTACK_STARTS_NOW;  // now
      }

      playerState->LaunchAttack(a);
      GAMESTATE->m_SongOptions.FromString(ModsLevel_Song, a.sModifiers);
    }

    // Update attack bOn flags.
    playerState->Update(0);

    // Hack: Course modifiers that are set to start immediately shouldn't tween
    // on.
    playerState->m_PlayerOptions.SetCurrentToLevel(ModsLevel_Stage);
  }
  return complete;
}

void ScreenGameplay::ReloadCurrentSong() {
  FOREACH_EnabledPlayerInfoNotDummy(m_vPlayerInfo, pi) {
    PlayerStageStats* pss =
        GetPlayerStageStatsOrWarn(*pi, "ScreenGameplay::ReloadCurrentSong");
    if (pss != nullptr && pss->m_iSongsPlayed > 0) {
      pss->m_iSongsPlayed--;
    }
  }

  LoadNextSong();
}

void ScreenGameplay::LoadNextSong() {
  if (!HasCoreGameplayManagers("ScreenGameplay::LoadNextSong")) {
    return;
  }
  GAMESTATE->ResetMusicStatistics();
  if (!ValidateGameplayQueues(
          m_apSongsQueue, m_vPlayerInfo, "ScreenGameplay::LoadNextSong")) {
    return;
  }

  FOREACH_EnabledPlayerInfo(m_vPlayerInfo, pi) {
    PlayerStageStats* pss = pi->GetPlayerStageStats();
    if (pss == nullptr) {
      continue;
    }
    pss->m_iSongsPlayed++;
    if (pi->m_ptextCourseSongNumber) {
      pi->m_ptextCourseSongNumber->SetText(ssprintf(
          SONG_NUMBER_FORMAT.GetValue().c_str(),
          pss->m_iSongsPassed + 1));
    }
  }

  if (GAMESTATE->m_bMultiplayer) {
    FOREACH_ENUM(MultiPlayer, mp)
    this->UpdateStageStats(mp);
  }

  int iPlaySongIndex = GAMESTATE->GetCourseSongIndex();
  iPlaySongIndex %= static_cast<int>(m_apSongsQueue.size());
  if (iPlaySongIndex < 0) {
    iPlaySongIndex = 0;
  }
  GAMESTATE->m_pCurSong.Set(m_apSongsQueue[iPlaySongIndex]);
  if (GAMESTATE->m_pCurSong == nullptr) {
    LOG->Warn("SRC_AUDIT_FIX: LoadNextSong selected a null song.");
    return;
  }
  STATSMAN->m_CurStageStats.m_vpPlayedSongs.push_back(GAMESTATE->m_pCurSong);
  m_iLightsRowLastCrossed = 0;
  m_iBeatRowLastCrossed = 0;
  ZERO(m_iNoteRowLastCrossed);

  // No need to do this here.  We do it in SongFinished().
  // GAMESTATE->RemoveAllActiveAttacks();

  // Force immediate fail behavior changed to theme metric by Kyz.
  if (FORCE_IMMEDIATE_FAIL_FOR_BATTERY) {
    FOREACH_EnabledPlayerInfo(m_vPlayerInfo, pi) {
      PlayerState* playerState = GetPlayerStateOrWarn(
          *pi, "ScreenGameplay::LoadNextSong force immediate fail");
      if (playerState == nullptr) {
        continue;
      }
      if (playerState->m_PlayerOptions.GetStage().m_LifeType ==
          LifeType_Battery) {
        PO_GROUP_ASSIGN(
            playerState->m_PlayerOptions, ModsLevel_Song, m_FailType,
            FailType_Immediate);
      }
    }
  }

  m_textSongOptions.SetText(GAMESTATE->m_SongOptions.GetCurrent().GetString());

  if (!SetupSong(iPlaySongIndex)) {
    LOG->Warn("SRC_AUDIT_FIX: LoadNextSong aborted after incomplete song setup.");
    return;
  }

  Song* pSong = GAMESTATE->m_pCurSong;
  FOREACH_EnabledPlayerInfo(m_vPlayerInfo, pi) {
    if (!IsUsableStepsAndTrailIndex(*pi, "ScreenGameplay::LoadNextSong")) {
      continue;
    }
    const PlayerNumber stepsPn = pi->GetStepsAndTrailIndex();
    Steps* pSteps = GAMESTATE->m_pCurSteps[stepsPn];
    PlayerStageStats* pss = pi->GetPlayerStageStats();
    PlayerState* playerState =
        GetPlayerStateOrWarn(*pi, "ScreenGameplay::LoadNextSong");
    if (pss == nullptr || pSteps == nullptr || playerState == nullptr ||
        pi->m_pPlayer == nullptr) {
      LOG->Warn(
          "SRC_AUDIT_FIX: LoadNextSong skipped incomplete player %s.",
          pi->GetName().c_str());
      continue;
    }
    ++pss->m_iStepsPlayed;

    if (pi->m_ptextStepsDescription) {
      pi->m_ptextStepsDescription->SetText(pSteps->GetDescription());
    }

    /* Increment the play count even if the player fails.  (It's still popular,
     * even if the people playing it aren't good at it.) */
    if (!GAMESTATE->m_bDemonstrationOrJukebox && PROFILEMAN != nullptr) {
      if (pi->m_pn != PLAYER_INVALID) {
        PROFILEMAN->IncrementStepsPlayCount(pSong, pSteps, pi->m_pn);
      }
    }

    if (pi->m_ptextPlayerOptions) {
      pi->m_ptextPlayerOptions->SetText(
          playerState->m_PlayerOptions.GetCurrent().GetString());
    }
    if (pi->m_pActiveAttackList) {
      pi->m_pActiveAttackList->Refresh();
    }

    // reset oni game over graphic
    SET_XY_AND_ON_COMMAND(pi->m_sprOniGameOver);

    if (playerState->m_PlayerOptions.GetStage().m_LifeType ==
            LifeType_Battery &&
        pss->m_bFailed) {  // already failed
      pi->ShowOniGameOver();
    }

    if (playerState->m_PlayerOptions.GetStage().m_LifeType ==
            LifeType_Bar &&
        pi->m_pLifeMeter) {
      pi->m_pLifeMeter->UpdateNonstopLifebar();
    }

    if (pi->m_pStepsDisplay) {
      pi->m_pStepsDisplay->SetFromSteps(pSteps);
    }

    /* The actual note data for scoring is the base class of Player.  This
     * includes transforms, like Wide.  Otherwise, the scoring will operate on
     * the wrong data. */
    if (pi->m_pPrimaryScoreKeeper) {
      pi->m_pPrimaryScoreKeeper->OnNextSong(
          GAMESTATE->GetCourseSongIndex(), pSteps,
          &pi->m_pPlayer->GetNoteData());
    }
    if (pi->m_pSecondaryScoreKeeper) {
      pi->m_pSecondaryScoreKeeper->OnNextSong(
          GAMESTATE->GetCourseSongIndex(), pSteps,
          &pi->m_pPlayer->GetNoteData());
    }

    const bool bDisableAutoplayForITGOnline = HasActiveITGOnlineRoom();

    // Don't mess with the PlayerController of the Dummy player
    if (!pi->m_bIsDummy) {
      if (bDisableAutoplayForITGOnline) {
        DisableAutoplayForITGOnline(playerState);
        LOG->Trace("ITG Online: disabled autoplay for gameplay player=%s",
                   PlayerNumberToString(playerState->m_PlayerNumber)
                       .c_str());
      } else if (GAMESTATE->m_bDemonstrationOrJukebox) {
        playerState->m_PlayerController = PC_CPU;
        playerState->m_iCpuSkill = 5;
      } else if (GAMESTATE->IsCpuPlayer(pi->GetStepsAndTrailIndex())) {
        playerState->m_PlayerController = PC_CPU;
        int iMeter = pSteps->GetMeter();
        int iNewSkill =
            SCALE(iMeter, MIN_METER, MAX_METER, 0, NUM_SKILL_LEVELS - 1);
        /* Watch out: songs aren't actually bound by MAX_METER. */
        iNewSkill = std::clamp(iNewSkill, 0, NUM_SKILL_LEVELS - 1);
        playerState->m_iCpuSkill = iNewSkill;
      } else {
        if (playerState->m_PlayerOptions.GetCurrent().m_fPlayerAutoPlay != 0) {
          playerState->m_PlayerController = PC_AUTOPLAY;
        } else {
          playerState->m_PlayerController = GamePreferences::m_AutoPlay;
        }
      }
    }
  }

  bool bAllReverse = true;
  bool bAtLeastOneReverse = false;
  FOREACH_EnabledPlayerInfo(m_vPlayerInfo, pi) {
    PlayerState* playerState =
        GetPlayerStateOrWarn(*pi, "ScreenGameplay::LoadNextSong reverse");
    if (playerState != nullptr &&
        playerState->m_PlayerOptions.GetCurrent()
                .m_fScrolls[PlayerOptions::SCROLL_REVERSE] == 1) {
      bAtLeastOneReverse = true;
    } else {
      bAllReverse = false;
    }
  }

  FOREACH_EnabledPlayerInfo(m_vPlayerInfo, pi) {
    PlayerState* playerState =
        GetPlayerStateOrWarn(*pi, "ScreenGameplay::LoadNextSong reverse UI");
    bool bReverse =
        playerState != nullptr &&
        playerState->m_PlayerOptions.GetCurrent()
                .m_fScrolls[PlayerOptions::SCROLL_REVERSE] == 1;

    if (pi->m_pStepsDisplay) {
      pi->m_pStepsDisplay->PlayCommand(
          bReverse ? "SetReverse" : "SetNoReverse");
    }
  }

  m_LyricDisplay.PlayCommand(
      bAllReverse          ? "SetReverse"
      : bAtLeastOneReverse ? "SetOneReverse"
                           : "SetNoReverse");

  // Load lyrics
  // XXX: don't load this here (who and why? -aj)
  LyricsLoader LL;
  if (GAMESTATE->m_pCurSong->HasLyrics()) {
    LL.LoadFromLRCFile(
        GAMESTATE->m_pCurSong->GetLyricsPath(), *GAMESTATE->m_pCurSong);
  }

  // Set up song-specific graphics.

  // Check to see if any players are in beginner mode.
  // Note: steps can be different if turn modifiers are used.
  if (PREFSMAN->m_bShowBeginnerHelper) {
    FOREACH_EnabledPlayerNumberInfo(m_vPlayerInfo, pi) {
      PlayerNumber pn = pi->GetStepsAndTrailIndex();
      if (GAMESTATE->IsHumanPlayer(pn) &&
          GAMESTATE->m_pCurSteps[pn] != nullptr &&
          GAMESTATE->m_pCurSteps[pn]->GetDifficulty() == Difficulty_Beginner) {
        if (pi->m_pPlayer != nullptr) {
          m_BeginnerHelper.AddPlayer(pn, pi->m_pPlayer->GetNoteData());
        }
      }
    }
  }

  if (m_pSongBackground) {
    m_pSongBackground->Unload();
  }

  if (m_pSongForeground) {
    m_pSongForeground->Unload();
  }

  if (!PREFSMAN->m_bShowBeginnerHelper || !m_BeginnerHelper.Init(2)) {
    m_BeginnerHelper.SetVisible(false);

    // BeginnerHelper disabled, or failed to load.
    if (m_pSongBackground) {
      m_pSongBackground->LoadFromSong(GAMESTATE->m_pCurSong);
    }

    if (!GAMESTATE->m_bDemonstrationOrJukebox) {
      /* This will fade from a preset brightness to the actual brightness
       * (based on prefs and "cover"). The preset brightness may be 0 (to
       * fade from black), or it might be 1, if the stage screen has the
       * song BG and we're coming from it (like Pump). This used to be done
       * in SM_PlayReady, but that means it's impossible to snap to the
       * new brightness immediately. */
      if (m_pSongBackground) {
        m_pSongBackground->SetBrightness(INITIAL_BACKGROUND_BRIGHTNESS);
        m_pSongBackground->FadeToActualBrightness();
      }
    }
  } else {
    m_BeginnerHelper.SetVisible(true);
  }

  FOREACH_EnabledPlayerInfo(m_vPlayerInfo, pi) {
    PlayerStageStats* pss =
        GetPlayerStageStatsOrWarn(*pi, "ScreenGameplay::LoadNextSong OnLoadSong");
    if (pss != nullptr && !pss->m_bFailed) {
      // give a little life back between stages
      if (pi->m_pLifeMeter) {
        pi->m_pLifeMeter->OnLoadSong();
      }
      if (pi->m_pPrimaryScoreDisplay) {
        pi->m_pPrimaryScoreDisplay->OnLoadSong();
      }
      if (pi->m_pSecondaryScoreDisplay) {
        pi->m_pSecondaryScoreDisplay->OnLoadSong();
      }
    }
  }
  if (m_pCombinedLifeMeter) {
    m_pCombinedLifeMeter->OnLoadSong();
  }

  if (m_pSongForeground) {
    m_pSongForeground->LoadFromSong(GAMESTATE->m_pCurSong);
  }

  m_fTimeSinceLastDancingComment = 0;

  /* m_soundMusic and m_pSongBackground take a very long time to load,
   * so cap fDelta at 0 so m_NextSong will show up on screen.
   * -Chris */
  m_bZeroDeltaOnNextUpdate = true;
  if (SCREENMAN != nullptr) {
    SCREENMAN->ZeroNextUpdate();
  }

  // Load cabinet lights data
  LoadLights();

  /* Load the music last, since it may start streaming and we don't want the
   * music to compete with other loading. */
  m_AutoKeysounds.FinishLoading();
  m_pSoundMusic = m_AutoKeysounds.GetSound();

  /* Give SoundEffectControls the new RageSoundReaders. */
  FOREACH_EnabledPlayerInfo(m_vPlayerInfo, pi) {
    RageSoundReader* pPlayerSound = m_AutoKeysounds.GetPlayerSound(pi->m_pn);
    if (pPlayerSound == nullptr &&
        pi->m_pn == GAMESTATE->GetMasterPlayerNumber()) {
      pPlayerSound = m_AutoKeysounds.GetSharedSound();
    }
    pi->m_SoundEffectControl.SetSoundReader(pPlayerSound);
  }

  BroadcastGameplayMessage("DoneLoadingNextSong");
}

void ScreenGameplay::LoadLights() {
  if (LIGHTSMAN == nullptr || GAMESTATE == nullptr ||
      GAMESTATE->m_pCurSong == nullptr) {
    return;
  }
  if (!LIGHTSMAN->IsEnabled()) {
    return;
  }

  // First, check if the song has explicit lights
  m_CabinetLightsNoteData.Init();

  const Steps* pSteps = SongUtil::GetClosestNotes(
      GAMESTATE->m_pCurSong, StepsType_lights_cabinet, Difficulty_Medium);
  if (pSteps != nullptr) {
    pSteps->GetNoteData(m_CabinetLightsNoteData);
    return;
  }

  // No explicit lights.  Create autogen lights.
  std::string sDifficulty =
      PREFSMAN != nullptr ? std::string(PREFSMAN->m_sLightsStepsDifficulty)
                          : "";
  std::vector<std::string> asDifficulties;
  split(sDifficulty, ",", asDifficulties);

  // Always use the steps from the primary steps type so that lights are
  // consistent over single and double styles.
  if (GAMEMAN == nullptr || GAMESTATE->m_pCurGame == nullptr) {
    LOG->Warn("SRC_AUDIT_FIX: LoadLights skipped autogen lights without game "
              "manager/current game.");
    return;
  }
  const Style* lightsStyle = GAMEMAN->GetHowToPlayStyleForGame(
      GAMESTATE->m_pCurGame);
  if (lightsStyle == nullptr) {
    LOG->Warn("SRC_AUDIT_FIX: LoadLights skipped autogen lights without a "
              "how-to-play style.");
    return;
  }
  StepsType st = lightsStyle->m_StepsType;

  Difficulty d1 = Difficulty_Invalid;
  if (asDifficulties.size() > 0) {
    if (CompareNoCase(asDifficulties[0], "selected") == 0) {
      // Base lights off current difficulty of active player
      // Can be either P1 or P2 if they're individual or P1 if both are active
      FOREACH_EnabledPlayerNumberInfo(m_vPlayerInfo, pi) {
        PlayerNumber pn = pi->GetStepsAndTrailIndex();

        if (IsValidGameplayPlayer(pn) && GAMESTATE->IsPlayerEnabled(pn) &&
            GAMESTATE->m_pCurSteps[pn] != nullptr) {
          d1 = GAMESTATE->m_pCurSteps[pn]->GetDifficulty();
          break;
        }
      }
    } else {
      d1 = StringToDifficulty(asDifficulties[0]);
    }
  }

  pSteps = SongUtil::GetClosestNotes(GAMESTATE->m_pCurSong, st, d1);

  // If we can't find anything at all, stop.
  if (pSteps == nullptr) {
    return;
  }

  NoteData TapNoteData1;
  pSteps->GetNoteData(TapNoteData1);

  // taken from oitg, restores arrow -> marquee/bass light mapping.
  // if the user has a pref for more than one difficulty to make the lighting
  // chart...
  if (asDifficulties.size() > 1) {
    Difficulty d2 = StringToDifficulty(asDifficulties[1]);

    Steps* pSteps2;

    pSteps2 = SongUtil::GetClosestNotes(GAMESTATE->m_pCurSong, st, d2);

    // if the difficulities are actually different
    // then we can use them to generate a lighting chart.
    // as the user defined.
    if (pSteps2 != nullptr && pSteps != pSteps2) {
      NoteData TapNoteData2;
      pSteps2->GetNoteData(TapNoteData2);

      NoteDataUtil::LoadTransformedLightsFromTwo(
          TapNoteData1, TapNoteData2, m_CabinetLightsNoteData);
      return;
    }

    // fall through
  }

  NoteDataUtil::LoadTransformedLights(
      TapNoteData1, m_CabinetLightsNoteData,
      GAMEMAN->GetStepsTypeInfo(StepsType_lights_cabinet).iNumTracks);
}

void ScreenGameplay::StartPlayingSong(
    float fMinTimeToNotes, float fMinTimeToMusic) {
  if (GAMESTATE == nullptr || m_pSoundMusic == nullptr ||
      GAMESTATE->m_pCurSong == nullptr) {
    LOG->Warn("SRC_AUDIT_FIX: StartPlayingSong missing sound or song.");
    return;
  }
  if (!IsFiniteNonNegative(fMinTimeToNotes)) {
    fMinTimeToNotes = 0.0f;
  }
  if (!IsFiniteNonNegative(fMinTimeToMusic)) {
    fMinTimeToMusic = 0.0f;
  }

  m_pSoundMusic->SetProperty("AccurateSync", true);

  RageSoundParams p;
  p.m_fSpeed = GAMESTATE->m_SongOptions.GetCurrent().m_fMusicRate;
  if (!std::isfinite(p.m_fSpeed) || p.m_fSpeed < 0.0f) {
    LOG->Warn(
        "SRC_AUDIT_FIX: Invalid music rate %.3f; using 1.0.",
        p.m_fSpeed);
    p.m_fSpeed = 1.0f;
  }
  p.StopMode = RageSoundParams::M_CONTINUE;

  {
    float onlineSecondsUntilStart = 0.0f;
    if (GetITGOnlineShouldHoldGameplayForStart()) {
      p.m_StartSecond = 0.0f;
      set_paused_internal(true);
    } else if (GetITGOnlineSecondsUntilScheduledStart(onlineSecondsUntilStart)) {
      p.m_StartSecond = -onlineSecondsUntilStart;
    } else {
      const float fFirstSecond = GAMESTATE->m_pCurSong->GetFirstSecond();
      float fStartDelay = fMinTimeToNotes - fFirstSecond;
      fStartDelay = std::max(fStartDelay, fMinTimeToMusic);
      p.m_StartSecond = -fStartDelay;
    }
  }

  ASSERT(!m_pSoundMusic->IsPlaying());
  {
    float fSecondsToStartFadingOutMusic, fSecondsToStartTransitioningOut;
    GetMusicEndTiming(
        fSecondsToStartFadingOutMusic, fSecondsToStartTransitioningOut);

    if (IsFiniteNonNegative(fSecondsToStartFadingOutMusic) &&
        fSecondsToStartFadingOutMusic <
        GAMESTATE->m_pCurSong->m_fMusicLengthSeconds) {
      p.m_fFadeOutSeconds = FiniteNonNegativeOr(MUSIC_FADE_OUT_SECONDS, 0.0f);
      p.m_LengthSeconds = fSecondsToStartFadingOutMusic +
                          p.m_fFadeOutSeconds - p.m_StartSecond;
      if (!IsFiniteNonNegative(p.m_LengthSeconds)) {
        p.m_LengthSeconds = 0.0f;
      }
    }
  }
  if (!std::isfinite(p.m_StartSecond)) {
    p.m_StartSecond = 0.0f;
  }
  if (m_pSoundMusic->IsPlaying()) {
    m_pSoundMusic->StopPlaying();
  }
  m_pSoundMusic->Play(false, &p);
  if (m_bPaused) {
    m_pSoundMusic->Pause(true);
  }

  /* Make sure GAMESTATE->m_fMusicSeconds is set up. */
  GAMESTATE->m_Position.m_fMusicSeconds = -5000;
  UpdateSongPosition(0);

  ASSERT(
      GAMESTATE->m_Position.m_fMusicSeconds >
      -4000); /* make sure the "fake timer" code doesn't trigger */
  FOREACH_EnabledPlayer(pn) {
    if (GAMESTATE->m_pCurSteps[pn]) {
      GAMESTATE->m_pCurSteps[pn]->GetTimingData()->PrepareLookup();
    }
  }
}

void ScreenGameplay::set_paused_internal(bool p) {
  m_bPaused = p;
  if (GAMESTATE != nullptr) {
    GAMESTATE->SetPaused(p);
  }
}

bool ScreenGameplay::SeekMusicSeconds(float seconds) {
  if (m_pSoundMusic == nullptr || !m_pSoundMusic->IsLoaded()) {
    return false;
  }

  seconds = FiniteNonNegativeOr(seconds, 0.0f);
  const bool seeked = m_pSoundMusic->SetPositionSeconds(seconds);
  if (seeked && GAMESTATE != nullptr) {
    GAMESTATE->m_Position.m_fMusicSeconds = seconds;
  }

  return seeked;
}

void ScreenGameplay::PauseGame(bool bPause, GameController gc) {
  if (m_bPaused == bPause) {
    LOG->Trace(
        "ScreenGameplay::PauseGame(%i) received, but already in that state; "
        "ignored",
        bPause);
    return;
  }

  // Don't pause if we're already tweening out.
  if (bPause && m_DancingState == STATE_OUTRO) {
    return;
  }

  ResetGiveUpTimers(false);

  set_paused_internal(bPause);
  m_PauseController = gc;

  if (m_pSoundMusic) {
    m_pSoundMusic->Pause(bPause);
  }
  if (bPause) {
    this->PlayCommand("Pause");
  } else {
    this->PlayCommand("Unpause");
  }

  FOREACH_EnabledPlayerInfo(m_vPlayerInfo, pi) {
    if (pi->m_pPlayer != nullptr) {
      pi->m_pPlayer->SetPaused(m_bPaused);
    }
  }
}

// play assist ticks
void ScreenGameplay::PlayTicks() {
  /* TODO: Allow all players to have ticks. Not as simple as it looks.
   * If a loop takes place, it could make one player's ticks come later
   * than intended. Any help here would be appreciated. -Wolfman2000 */
  const PlayerNumber master = GAMESTATE->GetMasterPlayerNumber();
  if (!IsValidGameplayPlayer(master) ||
      master >= static_cast<PlayerNumber>(m_vPlayerInfo.size()) ||
      m_vPlayerInfo[master].m_pPlayer == nullptr) {
    return;
  }
  Player& player = *m_vPlayerInfo[master].m_pPlayer;
  const NoteData& nd = player.GetNoteData();
  m_GameplayAssist.PlayTicks(nd, player.GetPlayerState());
}

/* Play announcer "type" if it's been at least fSeconds since the last
 * announcer. */
void ScreenGameplay::PlayAnnouncer(
    const std::string& type, float fSeconds, float* fDeltaSeconds) {
  if (GAMESTATE == nullptr || SOUND == nullptr || fDeltaSeconds == nullptr) {
    return;
  }
  if (GAMESTATE->m_fOpponentHealthPercent == 0) {
    return;  // Shut the announcer up
  }

  /* Don't play in demonstration. */
  if (GAMESTATE->m_bDemonstrationOrJukebox) {
    return;
  }

  /* Don't play before the first beat, or after we're finished. */
  if (m_DancingState != STATE_DANCING) {
    return;
  }
  if (GAMESTATE->m_pCurSong ==
          nullptr ||  // this will be true on ScreenDemonstration sometimes
      GAMESTATE->m_Position.m_fSongBeat <
          GAMESTATE->m_pCurSong->GetFirstBeat()) {
    return;
  }

  if (*fDeltaSeconds < fSeconds) {
    return;
  }
  *fDeltaSeconds = 0;

  SOUND->PlayOnceFromAnnouncer(type);
}

void ScreenGameplay::UpdateSongPosition(float fDeltaTime) {
  if (SOUND == nullptr || GAMESTATE == nullptr || m_pSoundMusic == nullptr ||
      GAMESTATE->m_pCurSong == nullptr) {
    return;
  }
  if (!m_pSoundMusic->IsPlaying()) {
    return;
  }

  RageTimer tm;
  const float fSeconds = m_pSoundMusic->GetPositionSeconds(&tm);
  const float fAdjust = SOUND->GetFrameTimingAdjustment(fDeltaTime);
  GAMESTATE->UpdateSongPosition(
      fSeconds + fAdjust, GAMESTATE->m_pCurSong->m_SongTiming, tm + fAdjust);
}

void ScreenGameplay::BeginScreen() {
  if (GAMESTATE == nullptr || GAMESTATE->m_pCurSong == nullptr) {
    return;
  }

  ScreenWithMenuElements::BeginScreen();

  if (SOUND != nullptr) {
    SOUND->PlayOnceFromAnnouncer("gameplay intro");  // crowd cheer
  }

  StartPlayingSong(MIN_SECONDS_TO_STEP, MIN_SECONDS_TO_MUSIC);
}

bool ScreenGameplay::AllAreFailing() {
  FOREACH_EnabledPlayerInfo(m_vPlayerInfo, pi) {
    if (pi->m_pLifeMeter && !pi->m_pLifeMeter->IsFailing()) {
      return false;
    }
  }
  return true;
}

void ScreenGameplay::GetMusicEndTiming(
    float& fSecondsToStartFadingOutMusic,
    float& fSecondsToStartTransitioningOut) {
  if (GAMESTATE == nullptr || GAMESTATE->m_pCurSong == nullptr) {
    fSecondsToStartFadingOutMusic = 0.0f;
    fSecondsToStartTransitioningOut = 0.0f;
    return;
  }

  float fLastStepSeconds =
      FiniteNonNegativeOr(GAMESTATE->m_pCurSong->GetLastSecond(), 0.0f);
  fLastStepSeconds += Player::GetMaxStepDistanceSeconds();

  float fTransitionLength;
  if (!GAMESTATE->IsCourseMode() || IsLastSong()) {
    fTransitionLength = FiniteNonNegativeOr(OUT_TRANSITION_LENGTH, 0.0f);
  } else {
    fTransitionLength = FiniteNonNegativeOr(COURSE_TRANSITION_LENGTH, 0.0f);
  }
  const float musicFadeOutSeconds =
      FiniteNonNegativeOr(MUSIC_FADE_OUT_SECONDS, 0.0f);

  fSecondsToStartTransitioningOut = fLastStepSeconds;

  // Align the end of the music fade to the end of the transition.
  float fSecondsToFinishFadingOutMusic =
      fSecondsToStartTransitioningOut + fTransitionLength;
  if (fSecondsToFinishFadingOutMusic <
      GAMESTATE->m_pCurSong->m_fMusicLengthSeconds) {
    fSecondsToStartFadingOutMusic =
        fSecondsToFinishFadingOutMusic - musicFadeOutSeconds;
  } else {
    fSecondsToStartFadingOutMusic =
        GAMESTATE->m_pCurSong->m_fMusicLengthSeconds;  // don't fade
  }

  /* Make sure we keep going long enough to register a miss for the last note,
   * and never start fading before the last note. */
  fSecondsToStartFadingOutMusic =
      std::max(fSecondsToStartFadingOutMusic, fLastStepSeconds);
  fSecondsToStartTransitioningOut =
      std::max(fSecondsToStartTransitioningOut, fLastStepSeconds);

  /* Make sure the fade finishes before the transition finishes. */
  fSecondsToStartTransitioningOut = std::max(
      fSecondsToStartTransitioningOut, fSecondsToStartFadingOutMusic +
                                           musicFadeOutSeconds -
                                           fTransitionLength);
}

void ScreenGameplay::Update(float fDeltaTime) {
  if (!IsFiniteNonNegative(fDeltaTime)) {
    LOG->Warn(
        "SRC_AUDIT_FIX: ScreenGameplay ignored invalid delta %.6f.",
        fDeltaTime);
    fDeltaTime = 0.0f;
  }
  if (GAMESTATE == nullptr) {
    Screen::Update(fDeltaTime);
    return;
  }
  if (GAMESTATE->m_pCurSong == nullptr) {
    /* ScreenDemonstration will move us to the next screen.  We just need to
     * survive for one update without crashing.  We need to call Screen::Update
     * to make sure we receive the next-screen message. */
    Screen::Update(fDeltaTime);
    return;
  }

  if (fDeltaTime >= 0.025f) {
    static uint64_t sLastGameplayHitchLogUsec = 0;
    const uint64_t nowUsec = RageTimer::GetTimeSinceStartMicroseconds();
    if (sLastGameplayHitchLogUsec == 0 ||
        nowUsec - sLastGameplayHitchLogUsec >= 250000) {
      sLastGameplayHitchLogUsec = nowUsec;
      const GameplayVisualPerfSnapshot& perf = g_LastGameplayVisualPerf;
      LOG->Trace(
          "GAMEPLAY_FRAME_HITCH: delta=%.6f music=%.6f beat=%.6f fps=%d "
          "perf_valid=%d last_draw_ms=%.3f song_background_ms=%.3f "
          "notefield_board_ms=%.3f clear_zbuffer_ms=%.3f "
          "screen_elements_ms=%.3f max_notefield_player=%s "
          "max_notefield_ms=%.3f visible_notes=%d visible_taps=%d "
          "visible_holds=%d visible_mines=%d visible_lifts=%d "
          "visible_fakes=%d visible_attacks=%d visible_autokeysounds=%d "
          "max_visible_player=%s max_visible_notes=%d active_receptors=%d "
          "active_ghosts=%d active_tap_judgments=%d "
          "active_hold_judgments=%d active_combo=%d "
          "tap_judgments_since_snapshot=%d hold_judgments_since_snapshot=%d "
          "mine_judgments_since_snapshot=%d danger_players=%d "
          "failing_players=%d min_life=%.3f",
          fDeltaTime, GAMESTATE->m_Position.m_fMusicSeconds,
          GAMESTATE->m_Position.m_fSongBeat,
          DISPLAY != nullptr ? DISPLAY->GetFPS() : 0,
          perf.valid ? 1 : 0, perf.draw_ms, perf.song_background_ms,
          perf.notefield_board_ms, perf.clear_zbuffer_ms,
          perf.screen_elements_ms, perf.max_notefield_board_player.c_str(),
          perf.max_notefield_board_ms, perf.visible_total, perf.visible_taps,
          perf.visible_holds, perf.visible_mines, perf.visible_lifts,
          perf.visible_fakes, perf.visible_attacks,
          perf.visible_autokeysounds, perf.max_visible_notes_player.c_str(),
          perf.max_player_visible_total, perf.active_receptors,
          perf.active_ghosts, perf.active_tap_judgments,
          perf.active_hold_judgments, perf.active_combo,
          perf.tap_judgments_since_last_snapshot,
          perf.hold_judgments_since_last_snapshot,
          perf.mine_judgments_since_last_snapshot, perf.danger_players,
          perf.failing_players, perf.min_life);
    }
  }

  UpdateSongPosition(fDeltaTime);

  if (m_bZeroDeltaOnNextUpdate) {
    Screen::Update(0);
    m_bZeroDeltaOnNextUpdate = false;
  } else {
    const float fRate = PREFSMAN->m_bRateModsAffectTweens
                            ? GAMESTATE->m_SongOptions.GetCurrent().m_fMusicRate
                            : 1.0f;
    Screen::Update(fDeltaTime * (std::isfinite(fRate) ? fRate : 1.0f));
  }

  /* This happens if ScreenDemonstration::HandleScreenMessage sets a new screen
   * when PREFSMAN->m_bDelayedScreenLoad. */
  if (GAMESTATE->m_pCurSong == nullptr) {
    return;
  }
  /* This can happen if ScreenDemonstration::HandleScreenMessage sets a new
   * screen when !PREFSMAN->m_bDelayedScreenLoad.  (The new screen was loaded
   * when we called Screen::Update, and the ctor might set a new
   * GAMESTATE->m_pCurSong, so the above check can fail.) */
  if (SCREENMAN != nullptr && SCREENMAN->GetTopScreen() != this) {
    return;
  }

  /* Update actors when paused, but never move on to another state. */
  if (m_bPaused) {
    return;
  }

  // LOG->Trace( "m_fOffsetInBeats = %f, m_fBeatsPerSecond = %f,
  // m_Music.GetPositionSeconds = %f", m_fOffsetInBeats, m_fBeatsPerSecond,
  // m_Music.GetPositionSeconds() );

  m_AutoKeysounds.Update(fDeltaTime);

  // update GameState HealthState
  FOREACH_EnabledPlayerInfo(m_vPlayerInfo, pi) {
    PlayerState* playerState =
        GetPlayerStateOrWarn(*pi, "ScreenGameplay::Update health");
    if (playerState == nullptr) {
      continue;
    }
    HealthState& hs = playerState->m_HealthState;
    HealthState OldHealthState = hs;
    if (GAMESTATE->GetPlayerFailType(playerState) != FailType_Off &&
        pi->m_pLifeMeter && pi->m_pLifeMeter->IsFailing()) {
      hs = HealthState_Dead;
    } else if (pi->m_pLifeMeter && pi->m_pLifeMeter->IsHot()) {
      hs = HealthState_Hot;
    } else if (
        GAMESTATE->GetPlayerFailType(playerState) != FailType_Off &&
        pi->m_pLifeMeter && pi->m_pLifeMeter->IsInDanger()) {
      hs = HealthState_Danger;
    } else {
      hs = HealthState_Alive;
    }

    if (hs != OldHealthState) {
      LOG->Trace(
          "LIFE_TRACE: player=%s old=%s new=%s life=%.3f in_danger=%d "
          "failing=%d music=%.6f beat=%.6f",
          pi->GetName().c_str(), HealthStateName(OldHealthState),
          HealthStateName(hs),
          pi->m_pLifeMeter ? pi->m_pLifeMeter->GetLife() : -1.0f,
          pi->m_pLifeMeter && pi->m_pLifeMeter->IsInDanger() ? 1 : 0,
          pi->m_pLifeMeter && pi->m_pLifeMeter->IsFailing() ? 1 : 0,
          GAMESTATE->m_Position.m_fMusicSeconds,
          GAMESTATE->m_Position.m_fSongBeat);
      Message msg("HealthStateChanged");
      msg.SetParam("PlayerNumber", pi->m_pn);
      msg.SetParam("HealthState", hs);
      msg.SetParam("OldHealthState", OldHealthState);
      BroadcastGameplayMessage(msg);
    }

    pi->m_SoundEffectControl.Update(fDeltaTime);
  }

  {
    float fSpeed = GAMESTATE->m_SongOptions.GetCurrent().m_fMusicRate;
    if (!std::isfinite(fSpeed) || fSpeed < 0.0f) {
      fSpeed = 1.0f;
    }
    if (GAMESTATE->m_SongOptions.GetCurrent().m_fHaste != 0.0f) {
      fSpeed *= GetHasteRate();
    }

    RageSoundParams p = m_pSoundMusic ? m_pSoundMusic->GetParams()
                                      : RageSoundParams();
    if (m_pSoundMusic && std::abs(p.m_fSpeed - fSpeed) > 0.01f &&
        fSpeed >= 0.0f && std::isfinite(fSpeed)) {
      p.m_fSpeed = fSpeed;
      m_pSoundMusic->SetParams(p);
    }
  }

  switch (m_DancingState) {
    case STATE_DANCING: {
      /* Set STATSMAN->m_CurStageStats.bFailed for failed players.  In,
       * FAIL_IMMEDIATE, send SM_BeginFailed if all players failed, and kill
       * dead Oni players. */
      FOREACH_EnabledPlayerInfo(m_vPlayerInfo, pi) {
        PlayerNumber pn = pi->GetStepsAndTrailIndex();
        PlayerState* playerState =
            GetPlayerStateOrWarn(*pi, "ScreenGameplay::Update fail check");
        PlayerStageStats* pss =
            GetPlayerStageStatsOrWarn(*pi, "ScreenGameplay::Update fail check");
        if (playerState == nullptr || pss == nullptr) {
          continue;
        }

        FailType ft = GAMESTATE->GetPlayerFailType(playerState);
        LifeType lt = playerState->m_PlayerOptions.GetStage().m_LifeType;
        if (ft == FailType_Off || ft == FailType_EndOfSong) {
          continue;
        }

        // check for individual fail
        if (pi->m_pLifeMeter == nullptr || !pi->m_pLifeMeter->IsFailing()) {
          continue; /* isn't failing */
        }
        if (pss->m_bFailed) {
          continue; /* failed and is already dead */
        }

        LOG->Trace("Player %d failed", (int)pn);
        if (GetITGOnlineIsActive() && !m_bMarkedOnlineFailedEarly) {
          const bool marked = MarkITGOnlineFailedEarly();
          if (marked) {
            m_bMarkedOnlineFailedEarly = true;
          }
          LOG->Trace(
              "ITG Online: individual fail triggered early failed finalization "
              "marked=%d player=%d.",
              marked ? 1 : 0, (int)pn);
        }
        pss->m_bFailed = true;  // fail

        {
          Message msg("PlayerFailed");
          msg.SetParam("PlayerNumber", pi->m_pn);
          BroadcastGameplayMessage(msg);
        }

        // Check for and do Oni die.
        bool bAllowOniDie = false;
        switch (lt) {
          case LifeType_Battery:
            bAllowOniDie = true;
          default:
            break;
        }
        if (bAllowOniDie && ft == FailType_Immediate) {
          if (!STATSMAN->m_CurStageStats
                   .AllFailed())  // if not the last one to fail
          {
            // kill them!
            FailFadeRemovePlayer(&*pi);
          }
        }
      }

      bool bAllFailed = true;
      FOREACH_EnabledPlayerInfo(m_vPlayerInfo, pi) {
        PlayerState* playerState =
            GetPlayerStateOrWarn(*pi, "ScreenGameplay::Update all failed");
        if (playerState == nullptr) {
          bAllFailed = false;
          continue;
        }
        FailType ft = GAMESTATE->GetPlayerFailType(playerState);
        switch (ft) {
          case FailType_Immediate:
            if (pi->m_pLifeMeter == nullptr ||
                (pi->m_pLifeMeter && !pi->m_pLifeMeter->IsFailing())) {
              bAllFailed = false;
            }
            break;
          case FailType_ImmediateContinue:
          case FailType_EndOfSong:
            bAllFailed = false;  // wait until the end of the song to fail.
            break;
          case FailType_Off:
            bAllFailed = false;  // never fail.
            break;
          default:
            LOG->Warn("SRC_AUDIT_FIX: invalid fail type %d for %s.",
                      static_cast<int>(ft), pi->GetName().c_str());
            bAllFailed = false;
            break;
        }
      }

      if (bAllFailed && OnlineShouldKeepGameplayAliveAfterLocalFail()) {
        if (!m_bLoggedOnlineLocalFailKeepAlive) {
          LOG->Trace(
              "ITG Online: local players failed, keeping ScreenGameplay running "
              "until remote players finish.");
          m_bLoggedOnlineLocalFailKeepAlive = true;
        }
      } else if (bAllFailed) {
        StopMusicIfLoaded(m_pSoundMusic);
        PostScreenMessage(SM_NotesEnded, 0);
        m_LyricDisplay.Stop();
      }

      // Update living players' alive time
      // HACK: Don't scale alive time when using tab/tilde.  Instead of
      // accumulating time from a timer, this time should instead be tied to the
      // music position.
      float fUnscaledDeltaTime =
          FiniteNonNegativeOr(m_timerGameplaySeconds.GetDeltaTime(), 0.0f);
      float musicRate = GAMESTATE->m_SongOptions.GetCurrent().m_fMusicRate;
      if (!std::isfinite(musicRate) || musicRate < 0.0f) {
        musicRate = 1.0f;
      }

      FOREACH_EnabledPlayerInfo(m_vPlayerInfo, pi) {
        PlayerStageStats* pss =
            GetPlayerStageStatsOrWarn(*pi, "ScreenGameplay::Update alive time");
        if (pss != nullptr && !pss->m_bFailed) {
          pss->m_fAliveSeconds += fUnscaledDeltaTime * musicRate;
        }
      }

      // update fGameplaySeconds
      STATSMAN->m_CurStageStats.m_fGameplaySeconds += fUnscaledDeltaTime;
      float curBeat = GAMESTATE->m_Position.m_fSongBeat;
      Song& s = *GAMESTATE->m_pCurSong;

      if (curBeat >= s.GetFirstBeat() && curBeat < s.GetLastBeat()) {
        STATSMAN->m_CurStageStats.m_fStepsSeconds += fUnscaledDeltaTime;

        UpdateHasteRate();

        if (GAMESTATE->m_SongOptions.GetCurrent().m_fHaste != 0.0f) {
          float fHasteRate = GetHasteRate();
          // For negative haste, accumulate seconds while the song is slowed
          // down.
          if (GAMESTATE->m_SongOptions.GetCurrent().m_fHaste < 0) {
            GAMESTATE->m_fAccumulatedHasteSeconds -=
                (fUnscaledDeltaTime * fHasteRate) - fUnscaledDeltaTime;
          }
          // For positive haste, accumulate seconds while the song is sped up.
          else {
            GAMESTATE->m_fAccumulatedHasteSeconds +=
                (fUnscaledDeltaTime * fHasteRate) - fUnscaledDeltaTime;
          }
        }
      }

      // Check for end of song
      {
        float fSecondsToStartFadingOutMusic, fSecondsToStartTransitioningOut;
        GetMusicEndTiming(
            fSecondsToStartFadingOutMusic, fSecondsToStartTransitioningOut);

        bool bAllReallyFailed = STATSMAN->m_CurStageStats.AllFailed();
        if (bAllReallyFailed) {
          fSecondsToStartTransitioningOut += BEGIN_FAILED_DELAY;
        }

        if (GAMESTATE->m_Position.m_fMusicSeconds >=
                fSecondsToStartTransitioningOut &&
            !m_NextSong.IsTransitioning()) {
          this->PostScreenMessage(SM_NotesEnded, 0);
        }
      }

      // update 2d dancing characters
      FOREACH_EnabledPlayerNumberInfo(m_vPlayerInfo, pi) {
        DancingCharacters* pCharacter = nullptr;
        if (m_pSongBackground) {
          pCharacter = m_pSongBackground->GetDancingCharacters();
        }
        if (pCharacter != nullptr) {
          if (pi->m_pPlayer == nullptr) {
            continue;
          }
          TapNoteScore tns = pi->m_pPlayer->GetLastTapNoteScore();

          ANIM_STATES_2D state = AS2D_MISS;

          switch (tns) {
            case TNS_W4:
            case TNS_W3:
              state = AS2D_GOOD;
              break;
            case TNS_W2:
            case TNS_W1:
              state = AS2D_GREAT;
              break;
            default:
              state = AS2D_MISS;
              break;
          }

          PlayerState* playerState = GetPlayerStateOrWarn(
              *pi, "ScreenGameplay::Update dancing characters");
          if (state == AS2D_GREAT && playerState != nullptr &&
              playerState->m_HealthState == HealthState_Hot) {
            state = AS2D_FEVER;
          }

          pCharacter->Change2DAnimState(pi->m_pn, state);
        }
      }

      // Check for enemy death in enemy battle
      if (m_fLastSeenEnemyHealth != GAMESTATE->m_fOpponentHealthPercent) {
        m_fLastSeenEnemyHealth = GAMESTATE->m_fOpponentHealthPercent;

        if (GAMESTATE->m_fOpponentHealthPercent == 0) {
          // HACK:  Load incorrect directory on purpose for now.
          PlayAnnouncer("gameplay battle damage level3", 0);

          GAMESTATE->RemoveAllActiveAttacks();

          FOREACH_EnabledPlayerNumberInfo(m_vPlayerInfo, pi) {
            if (!GAMESTATE->IsCpuPlayer(pi->m_pn)) {
              continue;
            }

            FailFadeRemovePlayer(&*pi);
          }
        }
      }

      // update give up
      bool bGiveUpTimerFired = false;
      bGiveUpTimerFired =
          !m_GiveUpTimer.IsZero() && m_GiveUpTimer.Ago() > GIVE_UP_SECONDS;
      m_gave_up = bGiveUpTimerFired;
      m_skipped_song =
          !m_SkipSongTimer.IsZero() && m_SkipSongTimer.Ago() > GIVE_UP_SECONDS;

      bool bAllHumanHaveBigMissCombo = true;
      FOREACH_EnabledPlayerNumberInfo(m_vPlayerInfo, pi) {
        PlayerState* playerState =
            GetPlayerStateOrWarn(*pi, "ScreenGameplay::Update miss combo");
        if (playerState == nullptr ||
            playerState->m_PlayerOptions.GetCurrent().m_FailType ==
                FailType_Off ||
            playerState->m_HealthState < HealthState_Dead) {
          bAllHumanHaveBigMissCombo = false;
          break;
        }
      }
      if (bAllHumanHaveBigMissCombo)  // possible to get in here.
      {
        bAllHumanHaveBigMissCombo =
            FAIL_ON_MISS_COMBO.GetValue() != -1 &&
            STATSMAN->m_CurStageStats.GetMinimumMissCombo() >=
                (unsigned int)FAIL_ON_MISS_COMBO;
      }
      if (bGiveUpTimerFired || bAllHumanHaveBigMissCombo || m_skipped_song) {
        STATSMAN->m_CurStageStats.m_bGaveUp = true;
        FOREACH_EnabledPlayerNumberInfo(m_vPlayerInfo, pi) {
          PlayerStageStats* pss =
              GetPlayerStageStatsOrWarn(*pi, "ScreenGameplay::Update give up");
          if (pss != nullptr) {
            pss->m_bFailed |= bAllHumanHaveBigMissCombo;
            pss->m_bDisqualified |=
                bGiveUpTimerFired;  // Don't disqualify if failing for miss combo.
                                    // The player should still be eligable for a
                                    // high score on courses.
          }
        }
        ResetGiveUpTimers(false);
        if (GIVING_UP_GOES_TO_PREV_SCREEN && !m_skipped_song) {
          BeginBackingOutFromGameplay();
        } else {
          StopMusicIfLoaded(m_pSoundMusic);
          this->PostScreenMessage(SM_NotesEnded, 0);
        }
        return;
      }

      // Check to see if it's time to play a ScreenGameplay comment
      m_fTimeSinceLastDancingComment += fDeltaTime;

      PlayMode mode = GAMESTATE->m_PlayMode;
      switch (mode) {
        case PLAY_MODE_REGULAR:
        case PLAY_MODE_BATTLE:
        case PLAY_MODE_RAVE:
          if (GAMESTATE->OneIsHot()) {
            PlayAnnouncer("gameplay comment hot", SECONDS_BETWEEN_COMMENTS);
          } else if (GAMESTATE->AllAreInDangerOrWorse()) {
            PlayAnnouncer("gameplay comment danger", SECONDS_BETWEEN_COMMENTS);
          } else {
            PlayAnnouncer("gameplay comment good", SECONDS_BETWEEN_COMMENTS);
          }
          break;
        case PLAY_MODE_NONSTOP:
        case PLAY_MODE_ONI:
        case PLAY_MODE_ENDLESS:
          PlayAnnouncer("gameplay comment oni", SECONDS_BETWEEN_COMMENTS);
          break;
        default:
          LOG->Warn(
              "SRC_AUDIT_FIX: invalid PlayMode %i during gameplay comments.",
              static_cast<int>(mode));
          break;
      }
    }
    default:
      break;
  }

  PlayTicks();
  UpdateLights();
  SendCrossedMessages();

  // ArrowEffects::Update call moved because having it happen once per
  // NoteField (which means twice in two player) seemed wasteful. -Kyz
  ArrowEffects::Update();
}

void ScreenGameplay::DrawPrimitives() {
  // ScreenGameplay::DrawPrimitives exists so that the notefield board can be
  // above the song background and underneath everything else.  This way, a
  // theme can put a screen filter in the notefield board and not have it
  // obscure custom elements on the screen.  Putting the screen filter in the
  // notefield board simplifies placement because it ensures that the filter
  // is in the same place as the notefield, instead of forcing the filter to
  // check conditions and metrics that affect the position of the notefield.
  // This also solves the problem of the ComboUnderField metric putting the
  // combo underneath the opaque notefield board.
  // -Kyz
  RageTimer totalTimer;
  RageTimer phaseTimer;
  float songBackgroundMs = 0.0f;
  float noteFieldBoardMs = 0.0f;
  float maxNoteFieldBoardMs = 0.0f;
  std::string maxNoteFieldBoardPlayer = "none";
  float clearZBufferMs = 0.0f;
  float screenElementsMs = 0.0f;

  if (m_pSongBackground) {
    m_pSongBackground->m_disable_draw = false;
    m_pSongBackground->Draw();
    m_pSongBackground->m_disable_draw = true;
  }
  songBackgroundMs = phaseTimer.GetDeltaTime() * 1000.0f;

  FOREACH_EnabledPlayerNumberInfo(m_vPlayerInfo, pi) {
    if (pi->m_pPlayer == nullptr) {
      continue;
    }
    RageTimer playerTimer;
    pi->m_pPlayer->DrawNoteFieldBoard();
    const float onePlayerMs = playerTimer.GetDeltaTime() * 1000.0f;
    noteFieldBoardMs += onePlayerMs;
    if (onePlayerMs > maxNoteFieldBoardMs) {
      maxNoteFieldBoardMs = onePlayerMs;
      maxNoteFieldBoardPlayer = pi->GetName();
    }
  }

  // Clear the z buffer so 3D notes aren't hidden by anything in the underlay
  // using masking. -Kyz
  if (DISPLAY != nullptr) {
    DISPLAY->ClearZBuffer();
  }
  clearZBufferMs = phaseTimer.GetDeltaTime() * 1000.0f;

  ActorFrame::PushDrawPerfTraceScope(
      "ScreenGameplayElements",
      PerfDiagnosticsEnabled()
          ? std::max(0.0f, g_fPerfTraceSlowGameplayActorDrawMs.Get())
          : 0.0f);
  ScreenWithMenuElements::DrawPrimitives();
  ActorFrame::PopDrawPerfTraceScope();
  screenElementsMs = phaseTimer.GetDeltaTime() * 1000.0f;

  const float totalMs = totalTimer.GetDeltaTime() * 1000.0f;
  GameplayVisualPerfSnapshot perf;
  perf.valid = true;
  perf.draw_ms = totalMs;
  perf.song_background_ms = songBackgroundMs;
  perf.notefield_board_ms = noteFieldBoardMs;
  perf.clear_zbuffer_ms = clearZBufferMs;
  perf.screen_elements_ms = screenElementsMs;
  perf.max_notefield_board_ms = maxNoteFieldBoardMs;
  perf.max_notefield_board_player = maxNoteFieldBoardPlayer;

  FOREACH_EnabledPlayerNumberInfo(m_vPlayerInfo, pi) {
    if (pi->m_pPlayer == nullptr) {
      continue;
    }
    Player::GameplayPerfStats playerStats =
        pi->m_pPlayer->GetGameplayPerfStats();
    perf.visible_taps += playerStats.visible_taps;
    perf.visible_holds += playerStats.visible_holds;
    perf.visible_mines += playerStats.visible_mines;
    perf.visible_lifts += playerStats.visible_lifts;
    perf.visible_fakes += playerStats.visible_fakes;
    perf.visible_attacks += playerStats.visible_attacks;
    perf.visible_autokeysounds += playerStats.visible_autokeysounds;
    perf.visible_total += playerStats.visible_total;
    perf.active_receptors += playerStats.active_receptors;
    perf.active_ghosts += playerStats.active_ghosts;
    perf.active_tap_judgments += playerStats.active_tap_judgments;
    perf.active_hold_judgments += playerStats.active_hold_judgments;
    perf.active_combo += playerStats.active_combo;
    perf.tap_judgments_since_last_snapshot +=
        playerStats.tap_judgments_since_last_snapshot;
    perf.hold_judgments_since_last_snapshot +=
        playerStats.hold_judgments_since_last_snapshot;
    perf.mine_judgments_since_last_snapshot +=
        playerStats.mine_judgments_since_last_snapshot;
    if (playerStats.visible_total > perf.max_player_visible_total) {
      perf.max_player_visible_total = playerStats.visible_total;
      perf.max_visible_notes_player = pi->GetName();
    }
    if (playerStats.in_danger) {
      ++perf.danger_players;
    }
    if (playerStats.failing) {
      ++perf.failing_players;
    }
    if (playerStats.life >= 0.0f &&
        (perf.min_life < 0.0f || playerStats.life < perf.min_life)) {
      perf.min_life = playerStats.life;
    }
    pi->m_pPlayer->ResetGameplayPerfCounters();
  }

  g_LastGameplayVisualPerf = perf;

  const float traceThresholdMs =
      std::max(0.0f, g_fPerfTraceSlowGameplayDrawMs.Get());
  if (PerfDiagnosticsEnabled() && traceThresholdMs > 0.0f &&
      totalMs >= traceThresholdMs) {
    LOG->Trace(
        "PERF_TRACE: gameplay_draw total_ms=%.3f song_background_ms=%.3f "
        "notefield_board_ms=%.3f clear_zbuffer_ms=%.3f "
        "screen_elements_ms=%.3f max_notefield_player=%s "
        "max_notefield_ms=%.3f visible_notes=%d visible_taps=%d "
        "visible_holds=%d visible_mines=%d visible_lifts=%d "
        "visible_fakes=%d visible_attacks=%d visible_autokeysounds=%d "
        "max_visible_player=%s max_visible_notes=%d active_receptors=%d "
        "active_ghosts=%d active_tap_judgments=%d active_hold_judgments=%d "
        "active_combo=%d tap_judgments_since_snapshot=%d "
        "hold_judgments_since_snapshot=%d mine_judgments_since_snapshot=%d "
        "danger_players=%d failing_players=%d min_life=%.3f",
        totalMs, songBackgroundMs, noteFieldBoardMs, clearZBufferMs,
        screenElementsMs, maxNoteFieldBoardPlayer.c_str(),
        maxNoteFieldBoardMs, perf.visible_total, perf.visible_taps,
        perf.visible_holds, perf.visible_mines, perf.visible_lifts,
        perf.visible_fakes, perf.visible_attacks, perf.visible_autokeysounds,
        perf.max_visible_notes_player.c_str(), perf.max_player_visible_total,
        perf.active_receptors, perf.active_ghosts,
        perf.active_tap_judgments, perf.active_hold_judgments,
        perf.active_combo, perf.tap_judgments_since_last_snapshot,
        perf.hold_judgments_since_last_snapshot,
        perf.mine_judgments_since_last_snapshot, perf.danger_players,
        perf.failing_players, perf.min_life);
  }
}

void ScreenGameplay::FailFadeRemovePlayer(PlayerInfo* pi) {
  if (pi == nullptr || pi->m_pPlayer == nullptr) {
    LOG->Warn("SRC_AUDIT_FIX: FailFadeRemovePlayer ignored incomplete player.");
    return;
  }
  if (SOUND != nullptr && THEME != nullptr) {
    SOUND->PlayOnceFromDir(THEME->GetPathS(m_sName, "oni die"));
  }
  pi->ShowOniGameOver();
  int tracks = pi->m_NoteData.GetNumTracks();
  pi->m_NoteData.Init();                // remove all notes and scoring
  pi->m_NoteData.SetNumTracks(tracks);  // reset the number of tracks.
  pi->m_pPlayer->FadeToFail();          // tell the NoteField to fade to white
}

void ScreenGameplay::FailFadeRemovePlayer(PlayerNumber pn) {
  PlayerInfo* pi = GetPlayerInfo(pn);
  if (pi == nullptr) {
    LOG->Warn(
        "SRC_AUDIT_FIX: FailFadeRemovePlayer ignored invalid player %i.",
        static_cast<int>(pn));
    return;
  }
  FailFadeRemovePlayer(pi);
}

float ScreenGameplay::GetHasteRate() { return m_fCurrHasteRate; }

void ScreenGameplay::UpdateHasteRate() {
  if (GAMESTATE == nullptr) {
    m_fCurrHasteRate = 1.0f;
    return;
  }
  if (!std::isfinite(m_fHasteTimeBetweenUpdates) ||
      m_fHasteTimeBetweenUpdates <= 0.0f) {
    m_fHasteTimeBetweenUpdates = 4.0f;
  }
  if (!std::isfinite(m_fHasteLifeSwitchPoint) ||
      m_fHasteLifeSwitchPoint < 0.0f) {
    m_fHasteLifeSwitchPoint = 0.5f;
  }
  if (GAMESTATE->m_Position.m_fMusicSeconds <
          GAMESTATE->m_fLastHasteUpdateMusicSeconds ||  // new song
      GAMESTATE->m_Position.m_fMusicSeconds >
          GAMESTATE->m_fLastHasteUpdateMusicSeconds +
              m_fHasteTimeBetweenUpdates) {
    bool bAnyPlayerHitAllNotes = false;
    FOREACH_EnabledPlayerInfo(m_vPlayerInfo, pi) {
      if (!GAMESTATE->IsHumanPlayer(pi->m_pn)) {
        continue;
      }

      PlayerState* pPS = pi->GetPlayerState();
      if (pPS == nullptr) {
        continue;
      }
      if (pPS->m_iTapsHitSinceLastHasteUpdate > 0 &&
          pPS->m_iTapsMissedSinceLastHasteUpdate == 0) {
        bAnyPlayerHitAllNotes = true;
      }

      pPS->m_iTapsHitSinceLastHasteUpdate = 0;
      pPS->m_iTapsMissedSinceLastHasteUpdate = 0;
    }

    if (bAnyPlayerHitAllNotes) {
      GAMESTATE->m_fHasteRate += 0.1f;
    }
    rage_clamp(GAMESTATE->m_fHasteRate, -1.0f, +1.0f);

    GAMESTATE->m_fLastHasteUpdateMusicSeconds =
        GAMESTATE->m_Position.m_fMusicSeconds;
  }

  /* If the life meter is less than half full, push the haste rate down to let
   * the player use his accumulated haste time. */
  float fMaxLife = 0;
  FOREACH_EnabledPlayerInfo(m_vPlayerInfo, pi) {
    if (!GAMESTATE->IsHumanPlayer(pi->m_pn)) {
      continue;
    }
    // In Battle/Rave mode, the players don't have life meters.
    if (pi->m_pLifeMeter) {
      fMaxLife = std::max(fMaxLife, pi->m_pLifeMeter->GetLife());
    } else {
      fMaxLife = 1;
    }
  }
  if (m_fHasteLifeSwitchPoint > 0.0f &&
      fMaxLife <= m_fHasteLifeSwitchPoint) {
    GAMESTATE->m_fHasteRate =
        SCALE(fMaxLife, 0.0f, m_fHasteLifeSwitchPoint, -1.0f, 0.0f);
  }
  rage_clamp(GAMESTATE->m_fHasteRate, -1.0f, +1.0f);

  float fSpeed = 1.0f;
  // If there are no turning points or no add amounts, the bad themer probably
  // thinks that's a way to disable haste. Since we're outside a lua function,
  // crashing (asserting) won't point back to the source of the problem.
  if (m_HasteTurningPoints.size() < 2 || m_HasteAddAmounts.size() < 2 ||
      m_HasteTurningPoints.size() != m_HasteAddAmounts.size()) {
    m_fCurrHasteRate = fSpeed;
    return;
  }
  float options_haste = GAMESTATE->m_SongOptions.GetCurrent().m_fHaste;
  if (!std::isfinite(options_haste)) {
    m_fCurrHasteRate = 1.0f;
    return;
  }
  float scale_from_low = -1;
  float scale_from_high = 1;
  float scale_to_low = 0;
  float scale_to_high = 0;
  for (size_t turning_point = 0; turning_point < m_HasteTurningPoints.size();
       ++turning_point) {
    float curr_turning_point = m_HasteTurningPoints[turning_point];
    if (!std::isfinite(curr_turning_point) ||
        !std::isfinite(m_HasteAddAmounts[turning_point])) {
      m_fCurrHasteRate = 1.0f;
      return;
    }
    scale_from_high = curr_turning_point;
    scale_to_high = m_HasteAddAmounts[turning_point];
    if (GAMESTATE->m_fHasteRate < curr_turning_point) {
      break;
    }
    scale_from_low = curr_turning_point;
    scale_to_low = m_HasteAddAmounts[turning_point];
  }
  // If negative haste is being used, the game instead slows down when the
  // player does well.
  float speed_add = SCALE(
                        GAMESTATE->m_fHasteRate, scale_from_low,
                        scale_from_high, scale_to_low, scale_to_high) *
                    options_haste;
  if (scale_from_low == scale_from_high) {
    speed_add = scale_to_high * options_haste;
  }
  rage_clamp(speed_add, -1.0f, 1.0f);

  // Only adjust speed_add by AccumulatedHasteSeconds when the player is losing
  // seconds.  Otherwise, gaining the first second is interfered with.
  bool losing_seconds = false;
  if (options_haste > 0) {
    losing_seconds = speed_add < 0;
  } else {
    losing_seconds = speed_add > 0;
  }
  if (losing_seconds && GAMESTATE->m_fAccumulatedHasteSeconds <= 1) {
    /* Only allow slowing down the song while the players have accumulated
     * haste. This prevents dragging on the song by keeping the life meter
     * nearly empty. */
    /* In positive haste mode, the player accumulates seconds while the song
     * is sped up, and loses them while the song is slowed down.  "<= 1"
     * means that the player is only eligible to slow the song down when
     * they are down to their last accumulated second. -Kyz */
    // 1 second left is full speed_add, 0 seconds left is no speed_add.
    float clamp_secs = std::max(0.0f, GAMESTATE->m_fAccumulatedHasteSeconds);
    speed_add = speed_add * clamp_secs;
  }
  fSpeed += speed_add;
  m_fCurrHasteRate = fSpeed;
}

void ScreenGameplay::UpdateLights() {
  if (LIGHTSMAN == nullptr || GAMESTATE == nullptr ||
      GAMESTATE->m_pCurSong == nullptr) {
    return;
  }
  if (!LIGHTSMAN->IsEnabled()) {
    return;
  }
  if (m_CabinetLightsNoteData.GetNumTracks() ==
      0) {  // light data wasn't loaded
    return;
  }

  bool bBlinkCabinetLight[NUM_CabinetLight];
  bool bBlinkGameButton[NUM_GameController][NUM_GameButton];
  ZERO(bBlinkCabinetLight);
  ZERO(bBlinkGameButton);
  {
    const float fSongBeat = GAMESTATE->m_Position.m_fLightSongBeat;
    const int iSongRow = BeatToNoteRowNotRounded(fSongBeat);

    FOREACH_CabinetLight(cl) {
      // for each index we crossed since the last update:
      FOREACH_NONEMPTY_ROW_IN_TRACK_RANGE(
          m_CabinetLightsNoteData, cl, r, m_iLightsRowLastCrossed + 1,
          iSongRow + 1) {
        if (m_CabinetLightsNoteData.GetTapNote(cl, r).type !=
            TapNoteType_Empty) {
          bBlinkCabinetLight[cl] = true;
        }
      }

      if (m_CabinetLightsNoteData.IsHoldNoteAtRow(cl, iSongRow)) {
        bBlinkCabinetLight[cl] = true;
      }
    }

    FOREACH_EnabledPlayerNumberInfo(m_vPlayerInfo, pi) {
      const Style* pStyle = GAMESTATE->GetCurrentStyle(pi->m_pn);
      if (pStyle == nullptr || pi->m_pPlayer == nullptr) {
        continue;
      }
      const NoteData& nd = pi->m_pPlayer->GetNoteData();
      for (int t = 0; t < nd.GetNumTracks(); t++) {
        bool bBlink = false;

        // for each index we crossed since the last update:
        FOREACH_NONEMPTY_ROW_IN_TRACK_RANGE(
            nd, t, r, m_iLightsRowLastCrossed + 1, iSongRow + 1) {
          const TapNote& tn = nd.GetTapNote(t, r);
          if (tn.type != TapNoteType_Mine) {
            bBlink = true;
          }
        }

        // check if a hold should be active
        if (nd.IsHoldNoteAtRow(t, iSongRow)) {
          bBlink = true;
        }

        if (bBlink) {
          std::vector<GameInput> gi;
          pStyle->StyleInputToGameInput(t, pi->m_pn, gi);
          for (size_t i = 0; i < gi.size(); ++i) {
            if (IsValidGameInputIndex(gi[i])) {
              bBlinkGameButton[gi[i].controller][gi[i].button] = true;
            }
          }
        }
      }
    }

    m_iLightsRowLastCrossed = iSongRow;
  }

  // Before the first beat of the song, all cabinet lights solid on (except for
  // menu buttons).
  Song& s = *GAMESTATE->m_pCurSong;
  bool bOverrideCabinetBlink =
      (GAMESTATE->m_Position.m_fSongBeat < s.GetFirstBeat());
  FOREACH_CabinetLight(cl) bBlinkCabinetLight[cl] |= bOverrideCabinetBlink;

  // Send blink data.
  FOREACH_CabinetLight(cl) {
    if (bBlinkCabinetLight[cl]) {
      LIGHTSMAN->BlinkCabinetLight(cl);
    }
  }

  FOREACH_ENUM(GameController, gc) {
    FOREACH_ENUM(GameButton, gb) {
      if (bBlinkGameButton[gc][gb]) {
        LIGHTSMAN->BlinkGameButton(GameInput(gc, gb));
      }
    }
  }
}

void ScreenGameplay::SendCrossedMessages() {
  if (GAMESTATE == nullptr || MESSAGEMAN == nullptr ||
      GAMESTATE->m_pCurSong == nullptr) {
    return;
  }
  {
    float fPositionSeconds = GAMESTATE->m_Position.m_fMusicSeconds;
    float fSongBeat =
        GAMESTATE->m_pCurSong->m_SongTiming.GetBeatFromElapsedTime(
            fPositionSeconds);

    int iRowNow = BeatToNoteRowNotRounded(fSongBeat);
    iRowNow = std::max(0, iRowNow);

    for (int r = m_iBeatRowLastCrossed + 1; r <= iRowNow; r++) {
      if (GetNoteType(r) == NOTE_TYPE_4TH) {
        BroadcastGameplayMessage(Message_BeatCrossed);
      }
    }

    m_iBeatRowLastCrossed = iRowNow;
  }

  {
    const int NUM_MESSAGES_TO_SEND = 4;
    const float MESSAGE_SPACING_SECONDS = 0.4f;

    PlayerNumber pn = PLAYER_INVALID;
    FOREACH_EnabledPlayerNumberInfo(m_vPlayerInfo, pi) {
      if (!IsValidGameplayPlayer(pi->m_pn) ||
          GAMESTATE->m_pCurSteps[pi->m_pn] == nullptr) {
        continue;
      }
      if (GAMESTATE->m_pCurSteps[pi->m_pn]->GetDifficulty() ==
          Difficulty_Beginner) {
        pn = pi->m_pn;
        break;
      }
    }
    if (pn == PLAYER_INVALID) {
      return;
    }

    if (!IsValidGameplayPlayer(pn) ||
        pn >= static_cast<PlayerNumber>(m_vPlayerInfo.size()) ||
        m_vPlayerInfo[pn].m_pPlayer == nullptr) {
      return;
    }
    const NoteData& nd = m_vPlayerInfo[pn].m_pPlayer->GetNoteData();

    for (int i = 0; i < NUM_MESSAGES_TO_SEND; i++) {
      float fNoteWillCrossInSeconds = MESSAGE_SPACING_SECONDS * i;

      float fPositionSeconds =
          GAMESTATE->m_Position.m_fMusicSeconds + fNoteWillCrossInSeconds;
      float fSongBeat =
          GAMESTATE->m_pCurSong->m_SongTiming.GetBeatFromElapsedTime(
              fPositionSeconds);

      int iRowNow = BeatToNoteRowNotRounded(fSongBeat);
      iRowNow = std::max(0, iRowNow);
      int& iRowLastCrossed = m_iNoteRowLastCrossed[i];

      FOREACH_NONEMPTY_ROW_ALL_TRACKS_RANGE(
          nd, r, iRowLastCrossed + 1, iRowNow + 1) {
        int iNumTracksWithTapOrHoldHead = 0;
        for (int t = 0; t < nd.GetNumTracks(); t++) {
          if (nd.GetTapNote(t, r).type == TapNoteType_Empty) {
            continue;
          }

          iNumTracksWithTapOrHoldHead++;

          // send crossed message
          const Game* currentGame = GAMESTATE->GetCurrentGame();
          if (currentGame != nullptr &&
              currentGame->m_PlayersHaveSeparateStyles) {
            FOREACH_EnabledPlayerNumberInfo(m_vPlayerInfo, pi) {
              const Style* pStyle = GAMESTATE->GetCurrentStyle(pi->m_pn);
              if (pStyle == nullptr) {
                continue;
              }
              std::string sButton = pStyle->ColToButtonName(t);
              Message msg(i == 0 ? "NoteCrossed" : "NoteWillCross");
              msg.SetParam("ButtonName", sButton);
              msg.SetParam("NumMessagesFromCrossed", i);
              msg.SetParam("PlayerNumber", pi->m_pn);
              BroadcastGameplayMessage(msg);
            }
          } else {
            const Style* pStyle = GAMESTATE->GetCurrentStyle(PLAYER_INVALID);
            if (pStyle == nullptr) {
              continue;
            }
            std::string sButton = pStyle->ColToButtonName(t);
            Message msg(i == 0 ? "NoteCrossed" : "NoteWillCross");
            msg.SetParam("ButtonName", sButton);
            msg.SetParam("NumMessagesFromCrossed", i);
            BroadcastGameplayMessage(msg);
          }
        }

        if (iNumTracksWithTapOrHoldHead > 0) {
          BroadcastGameplayMessage((MessageID)(Message_NoteCrossed + i));
        }
        if (i == 0 && iNumTracksWithTapOrHoldHead >= 2) {
          std::string sMessageName = "NoteCrossedJump";
          BroadcastGameplayMessage(sMessageName);
        }
      }

      iRowLastCrossed = iRowNow;
    }
  }
}

void ScreenGameplay::BeginBackingOutFromGameplay() {
  m_DancingState = STATE_OUTRO;
  ResetGiveUpTimers(false);

  if (m_pSoundMusic) {
    m_pSoundMusic->StopPlaying();
  }
  m_GameplayAssist.StopPlaying();  // Stop any queued assist ticks.

  this->ClearMessageQueue();

  if (GAMESTATE == nullptr) {
    m_Cancel.StartTransitioning(SM_DoPrevScreen);
    return;
  }

  // If this is the final stage, don't allow extra stage
  if (GAMESTATE->GetSmallestNumStagesLeftForAnyHumanPlayer() == 0) {
    GAMESTATE->m_bBackedOutOfFinalStage = true;
  }
  // Disallow backing out of extra stage
  if (GAMESTATE->IsAnExtraStage()) {
    PostScreenMessage(SM_BeginFailed, 0);
  } else {
    m_Cancel.StartTransitioning(SM_DoPrevScreen);
  }
}

void ScreenGameplay::AbortGiveUpText(bool show_abort_text) {
  m_textDebug.StopTweening();
  if (show_abort_text) {
    m_textDebug.SetText(GIVE_UP_ABORTED_TEXT);
  }
  // otherwise tween out the text that's there

  m_textDebug.BeginTweening(1 / 2.f);
  m_textDebug.SetDiffuse(RageColor(1, 1, 1, 0));
}

void ScreenGameplay::AbortSkipSong(bool show_text) {
  if (m_SkipSongTimer.IsZero()) {
    return;
  }
  AbortGiveUpText(show_text);
  m_SkipSongTimer.SetZero();
}

void ScreenGameplay::AbortGiveUp(bool bShowText) {
  if (m_GiveUpTimer.IsZero()) {
    return;
  }
  AbortGiveUpText(bShowText);
  m_GiveUpTimer.SetZero();
}

void ScreenGameplay::ResetGiveUpTimers(bool show_text) {
  AbortSkipSong(show_text);
  AbortGiveUp(show_text);
}

bool ScreenGameplay::Input(const InputEventPlus& input) {
  // LOG->Trace( "ScreenGameplay::Input()" );

  if (GAMESTATE == nullptr || PREFSMAN == nullptr) {
    return false;
  }

  switch (input.type) {
    case IET_FIRST_PRESS:
    case IET_RELEASE:
    case IET_REPEAT:
      break;
    default:
      return false;
  }

  Message msg("");
  if (input.type == IET_FIRST_PRESS && m_Codes.InputMessage(input, msg)) {
    this->HandleMessage(msg);
  }

  if (m_bPaused) {
    /* If we're paused, only accept GAME_BUTTON_START to unpause. */
    if (GAMESTATE->IsHumanPlayer(input.pn) &&
        input.MenuI == GAME_BUTTON_START && input.type == IET_FIRST_PRESS) {
      if (m_PauseController == GameController_Invalid ||
          m_PauseController == input.GameI.controller) {
        // IMO, it's better to have this configurable. -DaisuMaster
        if (UNPAUSE_WITH_START) {
          this->PauseGame(false);
          return true;
        }
      }
    }
    return false;
  }

  if (input.MenuI == GAME_BUTTON_RESTART && input.type == IET_FIRST_PRESS &&
      GAMESTATE->IsEventMode() && !GAMESTATE->IsCourseMode()) {
    return MenuRestart(input);
  }

  if (m_DancingState != STATE_OUTRO && GAMESTATE->IsHumanPlayer(input.pn) &&
      !m_Cancel.IsTransitioning()) {
    /* Allow bailing out by holding any START button.
     * This gives a way to "give up" when a back button isn't available.
     * If this is also a style button, don't do this; pump center is start.
     */
    bool bHoldingGiveUp = false;
    const Style* styleGiveUp = GAMESTATE->GetCurrentStyle(input.pn);
    if (styleGiveUp == nullptr) {
      return false;
    }
    const bool giveUpInputIsStyleColumn =
        input.GameI.IsValid() &&
        styleGiveUp->GameInputToColumn(input.GameI) != Column_Invalid;
    if (!giveUpInputIsStyleColumn) {
      bHoldingGiveUp |= (START_GIVES_UP && input.MenuI == GAME_BUTTON_START);
      bHoldingGiveUp |= (BACK_GIVES_UP && input.MenuI == GAME_BUTTON_BACK);
    }
    // Allow holding SELECT to skip the current song in course mode. -Kyz
    if (GAMESTATE->IsCourseMode() && SELECT_SKIPS_SONG &&
        input.MenuI == GAME_BUTTON_SELECT) {
      if (input.type == IET_RELEASE) {
        AbortSkipSong(true);
      } else if (input.type == IET_FIRST_PRESS && m_SkipSongTimer.IsZero()) {
        m_textDebug.SetText(SKIP_SONG_TEXT);
        m_textDebug.PlayCommand("StartOn");
        m_SkipSongTimer.Touch();
      }
      return true;
    }

    if (bHoldingGiveUp) {
      // No PREFSMAN->m_bDelayedEscape; always delayed.
      if (input.type == IET_RELEASE) {
        AbortGiveUp(true);
      } else if (input.type == IET_FIRST_PRESS && m_GiveUpTimer.IsZero()) {
        m_textDebug.SetText(GIVE_UP_START_TEXT);
        m_textDebug.PlayCommand("StartOn");
        m_GiveUpTimer.Touch();  // start the timer
      }

      return true;
    }

    /* Only handle GAME_BUTTON_BACK as a regular BACK button if BACK_GIVES_UP is
     * disabled. */
    bool bHoldingBack = false;
    const Style* styleBack = GAMESTATE->GetCurrentStyle(input.pn);
    if (styleBack == nullptr) {
      return false;
    }
    const bool backInputIsStyleColumn =
        input.GameI.IsValid() &&
        styleBack->GameInputToColumn(input.GameI) != Column_Invalid;
    if (!backInputIsStyleColumn) {
      bHoldingBack |= input.MenuI == GAME_BUTTON_BACK && !BACK_GIVES_UP;
    }

    if (bHoldingBack) {
      if (((!PREFSMAN->m_bDelayedBack && input.type == IET_FIRST_PRESS) ||
           (input.DeviceI.device == DEVICE_KEYBOARD &&
            input.type == IET_REPEAT) ||
           (input.DeviceI.device != DEVICE_KEYBOARD && INPUTFILTER != nullptr &&
            INPUTFILTER->GetSecsHeld(input.DeviceI) >= 1.0f))) {
        LOG->Trace("Player %i went back", input.pn + 1);
        BeginBackingOutFromGameplay();
      } else if (PREFSMAN->m_bDelayedBack && input.type == IET_FIRST_PRESS) {
        m_textDebug.SetText(GIVE_UP_BACK_TEXT);
        m_textDebug.PlayCommand("BackOn");
      } else if (PREFSMAN->m_bDelayedBack && input.type == IET_RELEASE) {
        m_textDebug.PlayCommand("TweenOff");
      }

      return true;
    }
  }

  bool bRelease = input.type == IET_RELEASE;
  if (!input.GameI.IsValid()) {
    return false;
  }

  const PlayerNumber stylePn =
      GAMESTATE->m_bMultiplayer || !IsValidGameplayPlayer(input.pn)
          ? PLAYER_INVALID
          : input.pn;
  const Style* inputStyle = GAMESTATE->GetCurrentStyle(stylePn);
  if (inputStyle == nullptr) {
    return false;
  }
  int iCol = inputStyle->GameInputToColumn(input.GameI);

  // Don't pass on any inputs to Player that aren't a press or a release.
  switch (input.type) {
    case IET_FIRST_PRESS:
    case IET_RELEASE:
      break;
    default:
      return false;
  }

  if (GAMESTATE->m_bMultiplayer) {
    if (input.mp != MultiPlayer_Invalid &&
        GAMESTATE->IsMultiPlayerEnabled(input.mp) && iCol != -1) {
      for (const PlayerInfo& pi : m_vPlayerInfo) {
        if (input.mp == pi.m_mp && pi.m_pPlayer != nullptr) {
          pi.m_pPlayer->Step(iCol, -1, input.DeviceI.ts, false, bRelease);
        }
      }
      return true;
    }
  } else {
    // handle a step or battle item activate
    if (GAMESTATE->IsHumanPlayer(input.pn)) {
      ResetGiveUpTimers(true);

      if (GamePreferences::m_AutoPlay == PC_HUMAN &&
          IsValidGameplayPlayer(input.pn) &&
          GAMESTATE->m_pPlayerState[input.pn] != nullptr &&
          GAMESTATE->m_pCurGame != nullptr &&
          GAMESTATE->m_pPlayerState[input.pn]
                  ->m_PlayerOptions.GetCurrent()
                  .m_fPlayerAutoPlay == 0) {
        PlayerInfo* pi = GetPlayerInfoForInput(input);
        if (pi == nullptr || pi->m_pPlayer == nullptr) {
          return false;
        }

        ASSERT(input.GameI.IsValid());

        const Game::PerButtonInfo* perButtonInfo =
            GAMESTATE->m_pCurGame->GetPerButtonInfo(input.GameI.button);
        if (perButtonInfo == nullptr) {
          return false;
        }
        GameButtonType gbt = perButtonInfo->m_gbt;
        switch (gbt) {
          case GameButtonType_Menu:
            return false;
          case GameButtonType_Step:
            if (iCol != -1) {
              pi->m_pPlayer->Step(iCol, -1, input.DeviceI.ts, false, bRelease);
            }
            return true;
        }
      }
    }
  }
  return false;
}

/* Saving StageStats that are affected by the note pattern is a little tricky:
 *
 * Stats are cumulative for course play.
 *
 * For regular songs, it doesn't matter how we do it; the pattern doesn't change
 * during play.
 *
 * The pattern changes during play in battle and course mode. We want to include
 * these changes, so run stats for a song after the song finishes.
 *
 * If we fail, be sure to include the current song in stats,
 * with the current modifier set. So:
 * 1. At the end of a song in any mode, pass or fail, add stats for that song
 *    (from m_pPlayer).
 * 2. At the end of gameplay in course mode, add stats for any songs that
 * weren't played, applying the modifiers the song would have been played with.
 *    This doesn't include songs that were played but failed; that was done in
 * #1.
 */
void ScreenGameplay::SaveStats() {
  if (!HasCoreGameplayManagers("ScreenGameplay::SaveStats")) {
    return;
  }
  if (GAMESTATE->m_pCurSong == nullptr) {
    return;
  }
  float fMusicLen = GAMESTATE->m_pCurSong->m_fMusicLengthSeconds;

  FOREACH_EnabledPlayerInfo(m_vPlayerInfo, pi) {
    /* Note that adding stats is only meaningful for the counters (eg.
     * RadarCategory_Jumps), not for the percentages (RadarCategory_Air). */
    RadarValues rv;
    PlayerNumber pn = pi->GetStepsAndTrailIndex();
    PlayerStageStats* pss = pi->GetPlayerStageStats();
    if (!IsValidGameplayPlayer(pn) || GAMESTATE->m_pCurSteps[pn] == nullptr ||
        pss == nullptr || pi->m_pPlayer == nullptr) {
      LOG->Warn(
          "SRC_AUDIT_FIX: SaveStats skipped incomplete player %s.",
          pi->GetName().c_str());
      continue;
    }
    const NoteData& nd = pi->m_pPlayer->GetNoteData();
    const TimingData* timing = GAMESTATE->m_pCurSteps[pn]->GetTimingData();

    NoteDataUtil::CalculateRadarValues(nd, fMusicLen, timing, rv);
    pss->m_radarPossible += rv;
    NoteDataWithScoring::GetActualRadarValues(nd, *pss, timing, fMusicLen, rv);
    pss->m_radarActual += rv;
  }
}

void ScreenGameplay::SongFinished() {
  if (GAMESTATE == nullptr) {
    return;
  }
  const bool isOnlineActive = GetITGOnlineIsActive();
  if (isOnlineActive) {
    LOG->Trace("ITG Online: ScreenGameplay::SongFinished begin.");
  }
  FOREACH_EnabledPlayer(pn) {
    if (GAMESTATE->m_pCurSteps[pn]) {
      GAMESTATE->m_pCurSteps[pn]->GetTimingData()->ReleaseLookup();
    }
  }
  AdjustSync::HandleSongEnd();
  SaveStats();  // Let subclasses save the stats.
  /* Extremely important: if we don't remove attacks before moving on to the
   * next screen, they'll still be turned on eventually. */
  GAMESTATE->RemoveAllActiveAttacks();
  FOREACH_VisiblePlayerInfo(m_vPlayerInfo, pi) {
    if (pi->m_pActiveAttackList != nullptr) {
      pi->m_pActiveAttackList->Refresh();
    }
  }
  if (isOnlineActive) {
    LOG->Trace("ITG Online: ScreenGameplay::SongFinished complete.");
  }
}

bool ScreenGameplay::OnlineShouldHoldBeforeEvaluation() {
  if (LUA == nullptr) {
    return false;
  }
  Lua* L = LUA->Get();
  bool shouldHold = false;
  const bool ok = LuaHelpers::RunExpression(
      L,
      "ITGOnlineShouldHoldGameplayForEvaluation ~= nil "
      "and ITGOnlineShouldHoldGameplayForEvaluation()",
      "ScreenGameplay online evaluation hold gate");
  if (ok) {
    LuaHelpers::Pop(L, shouldHold);
  }
  LUA->Release(L);
  if (shouldHold && !m_bLoggedOnlineEvaluationHold) {
    LOG->Trace("ITG Online: holding ScreenGameplay before evaluation");
    m_bLoggedOnlineEvaluationHold = true;
  } else if (!shouldHold && m_bLoggedOnlineEvaluationHold) {
    LOG->Trace("ITG Online: released ScreenGameplay for evaluation");
    m_bLoggedOnlineEvaluationHold = false;
  }
  if (!ok) {
    const bool isOnlineActive = GetITGOnlineIsActive();
    LOG->Warn(
        "ITG Online: evaluation hold gate failed; %s",
        isOnlineActive ? "holding gameplay closed" : "local gameplay unaffected");
    return isOnlineActive;
  }
  return shouldHold;
}

bool ScreenGameplay::OnlineShouldKeepGameplayAliveAfterLocalFail() {
  if (LUA == nullptr) {
    return false;
  }
  Lua* L = LUA->Get();
  bool keepAlive = false;
  const bool ok = LuaHelpers::RunExpression(
      L,
      "ITGOnlineShouldKeepGameplayAliveAfterLocalFail ~= nil "
      "and ITGOnlineShouldKeepGameplayAliveAfterLocalFail()",
      "ScreenGameplay online keep-alive after local fail gate");
  if (ok) {
    LuaHelpers::Pop(L, keepAlive);
  }
  LUA->Release(L);

  if (!ok) {
    const bool isOnlineActive = GetITGOnlineIsActive();
    LOG->Warn(
        "ITG Online: local fail keep-alive gate failed; %s",
        isOnlineActive ? "keeping gameplay alive" : "local gameplay unaffected");
    return isOnlineActive;
  }

  return keepAlive;
}

void ScreenGameplay::StageFinished(bool bBackedOut) {
  if (!HasCoreGameplayManagers("ScreenGameplay::StageFinished")) {
    return;
  }
  const bool isOnlineActive = GetITGOnlineIsActive();
  if (isOnlineActive) {
    LOG->Trace(
        "ITG Online: StageFinished begin backedOut=%d allFailed=%d gaveUp=%d "
        "usedAutoplay=%d playMode=%d",
        bBackedOut ? 1 : 0,
        STATSMAN->m_CurStageStats.AllFailed() ? 1 : 0,
        STATSMAN->m_CurStageStats.m_bGaveUp ? 1 : 0,
        STATSMAN->m_CurStageStats.m_bUsedAutoplay ? 1 : 0,
        static_cast<int>(GAMESTATE->m_PlayMode));
  }
  if (GAMESTATE->IsCourseMode() && GAMESTATE->m_PlayMode != PLAY_MODE_ENDLESS) {
    LOG->Trace(
        "Stage finished at index %i/%i", GAMESTATE->GetCourseSongIndex(),
        (int)m_apSongsQueue.size());
    // +1 to skip the current song; that song has already passed.
    for (unsigned i = GAMESTATE->GetCourseSongIndex() + 1;
         i < m_apSongsQueue.size(); ++i) {
      LOG->Trace("Running stats for %i", i);
      if (!SetupSong(i)) {
        LOG->Warn(
            "SRC_AUDIT_FIX: StageFinished skipped unplayed song stats for "
            "incomplete setup at %u.",
            i);
        continue;
      }
      FOREACH_EnabledPlayerInfo(m_vPlayerInfo, pi) {
        if (pi->m_pPlayer != nullptr) {
          pi->m_pPlayer->ApplyWaitingTransforms();
        }
      }
      SongFinished();
    }
  }

  if (bBackedOut) {
    if (isOnlineActive) {
      LOG->Trace("ITG Online: StageFinished cancelling stage after backed out.");
    }
    GAMESTATE->CancelStage();
    return;
  }

  // If all players failed, kill.
  if (STATSMAN->m_CurStageStats.AllFailed()) {
    FOREACH_HumanPlayer(p) GAMESTATE->m_iPlayerStageTokens[p] = 0;
  }

  FOREACH_HumanPlayer(pn) STATSMAN->m_CurStageStats.m_player[pn].CalcAwards(
      pn, STATSMAN->m_CurStageStats.m_bGaveUp,
      STATSMAN->m_CurStageStats.m_bUsedAutoplay);
  STATSMAN->m_CurStageStats.FinalizeScores(false);

  GAMESTATE->CommitStageStats();

  // save current stage stats
  STATSMAN->m_vPlayedStageStats.push_back(STATSMAN->m_CurStageStats);

  STATSMAN->CalcAccumPlayedStageStats();
  GAMESTATE->FinishStage();
  if (isOnlineActive) {
    LOG->Trace("ITG Online: StageFinished complete.");
  }
}

void ScreenGameplay::HandleScreenMessage(const ScreenMessage SM) {
  CHECKPOINT_M(ssprintf(
      "HandleScreenMessage(%s)",
      ScreenMessageHelpers::ScreenMessageToString(SM).c_str()));
  if (GAMESTATE == nullptr &&
      SM != SM_GainFocus && SM != SM_LoseFocus) {
    LOG->Warn(
        "SRC_AUDIT_FIX: ScreenGameplay ignored message %s without GAMESTATE.",
        ScreenMessageHelpers::ScreenMessageToString(SM).c_str());
    ScreenWithMenuElements::HandleScreenMessage(SM);
    return;
  }
  const bool requiresCoreManagers =
      SM == SM_NotesEnded || SM == SM_LeaveGameplay ||
      SM == SM_StartLoadingNextSong || SM == SM_LoadNextSong ||
      SM == SM_DoPrevScreen || SM == SM_DoNextScreen ||
      SM == SM_BeginFailed;
  if (requiresCoreManagers &&
      !HasCoreGameplayManagers("ScreenGameplay::HandleScreenMessage")) {
    ScreenWithMenuElements::HandleScreenMessage(SM);
    return;
  }
  if (SM == SM_DoneFadingIn) {
    // If the ready animation is zero length, then playing the sound will
    // make it overlap with the go sound.
    // If the Ready animation is zero length, and the Go animation is not,
    // only play the Go sound.
    // If they're both zero length, only play the Ready sound.
    // Otherwise, play both sounds.
    // -Kyz
    m_Ready.StartTransitioning(SM_PlayGo);
    if (m_Ready.GetTweenTimeLeft() <= .0f) {
      m_delaying_ready_announce = true;
    } else {
      m_delaying_ready_announce = false;
      if (SOUND != nullptr) {
        SOUND->PlayOnceFromAnnouncer("gameplay ready");
      }
    }
  } else if (SM == SM_PlayGo) {
    m_Go.StartTransitioning(SM_None);
    bool should_play_go = true;
    if (m_delaying_ready_announce) {
      if (m_Go.GetTweenTimeLeft() <= .0f) {
        if (SOUND != nullptr) {
          SOUND->PlayOnceFromAnnouncer("gameplay ready");
        }
        should_play_go = false;
      } else {
        should_play_go = true;
      }
    }
    if (should_play_go && SOUND != nullptr) {
      if (GAMESTATE->IsAnExtraStage()) {
        SOUND->PlayOnceFromAnnouncer("gameplay here we go extra");
      } else if (GAMESTATE->GetSmallestNumStagesLeftForAnyHumanPlayer() == 0) {
        SOUND->PlayOnceFromAnnouncer("gameplay here we go final");
      } else {
        SOUND->PlayOnceFromAnnouncer("gameplay here we go normal");
      }
    }

    GAMESTATE->m_DanceStartTime.Touch();

    GAMESTATE->m_bGameplayLeadIn.Set(false);
    m_DancingState =
        STATE_DANCING;  // STATE CHANGE!  Now the user is allowed to press Back
  } else if (SM == SM_NotesEnded)  // received while STATE_DANCING
  {
    if (GetITGOnlineIsActive() &&
        (m_bOnlineEvaluationHoldStarted ||
         m_bOnlineEvaluationHoldMessagePending)) {
      if (!m_bLoggedOnlineNotesEndedDuringHold) {
        LOG->Trace(
            "ITG Online: SM_NotesEnded ignored while evaluation hold is "
            "active.");
        m_bLoggedOnlineNotesEndedDuringHold = true;
      }
      return;
    }

    ResetGiveUpTimers(
        false);  // don't allow giveup while the next song is loading

    /* Do this in LoadNextSong, so we don't tween off old attacks until
     * m_NextSong finishes. */
    // GAMESTATE->RemoveAllActiveAttacks();

    FOREACH_EnabledPlayerInfo(m_vPlayerInfo, pi) {
      PlayerState* playerState =
          GetPlayerStateOrWarn(*pi, "ScreenGameplay::SM_NotesEnded");
      PlayerStageStats* pss =
          GetPlayerStageStatsOrWarn(*pi, "ScreenGameplay::SM_NotesEnded");
      if (playerState == nullptr || pss == nullptr) {
        continue;
      }
      // Mark failure.
      if (GAMESTATE->GetPlayerFailType(playerState) != FailType_Off &&
          (pi->m_pLifeMeter && pi->m_pLifeMeter->IsFailing())) {
        pss->m_bFailed = true;
      }

      if (!pss->m_bFailed) {
        pss->m_iSongsPassed++;
      }

      // set a life record at the point of failure
      if (pss->m_bFailed) {
        pss->SetLifeRecordAt(
            0, STATSMAN->m_CurStageStats.m_fGameplaySeconds);
      }
    }

    /* If all players have *really* failed (bFailed, not the life meter or
     * bFailedEarlier): */
    const bool bAllReallyFailed = STATSMAN->m_CurStageStats.AllFailed();
    const bool bStopCourseEarly = STOP_COURSE_EARLY;
    const bool bIsLastSong = IsLastSong();

    if (!m_bLoggedStageEndState) {
      LOG->Trace(
          "bAllReallyFailed = %d, bStopCourseEarly = %d, "
          "bIsLastSong = %d, m_gave_up = %d, m_skipped_song = %d",
          bAllReallyFailed, bStopCourseEarly, bIsLastSong, m_gave_up,
          m_skipped_song);
      m_bLoggedStageEndState = true;
    }

    if (!bIsLastSong && m_skipped_song) {
      // Load the next song in the course.
      HandleScreenMessage(SM_StartLoadingNextSong);
      return;
    }
    if (bStopCourseEarly || bAllReallyFailed || bIsLastSong || m_gave_up) {
      // Time to leave from ScreenGameplay
      HandleScreenMessage(SM_LeaveGameplay);
    } else {
      // Load the next song in the course.
      HandleScreenMessage(SM_StartLoadingNextSong);
      return;
    }
  } else if (SM == SM_LeaveGameplay) {
    if (m_bOnlineEvaluationHoldMessagePending &&
        m_timerOnlineEvaluationHoldMessage.Ago() < 0.20f) {
      LOG->Trace(
          "ITG Online: SM_LeaveGameplay ignored while evaluation hold message "
          "is pending.");
      return;
    }
    m_bOnlineEvaluationHoldMessagePending = false;

    if (OnlineShouldHoldBeforeEvaluation()) {
      if (!m_bOnlineEvaluationHoldStarted) {
        LOG->Trace("ITG Online: SM_LeaveGameplay starting evaluation hold.");
        m_bOnlineEvaluationHoldStarted = true;
        m_bLoggedOnlineNotesEndedDuringHold = false;
        m_timerOnlineEvaluationHoldStarted.Touch();
        m_bOnlineEvaluationHoldMessagePending = true;
        m_timerOnlineEvaluationHoldMessage.Touch();
        this->PostScreenMessage(SM_LeaveGameplay, 0.25f);
        return;
      } else if (m_timerOnlineEvaluationHoldStarted.Ago() >=
                 ITGONLINE_EVALUATION_HOLD_MAX_SECONDS) {
        LOG->Warn(
            "ITG Online: evaluation hold timed out after %.2fs; continuing to "
            "evaluation",
            m_timerOnlineEvaluationHoldStarted.Ago());
        m_bOnlineEvaluationHoldStarted = false;
      } else {
        LOG->Trace(
            "ITG Online: SM_LeaveGameplay continuing evaluation hold for %.2fs.",
            m_timerOnlineEvaluationHoldStarted.Ago());
        m_bOnlineEvaluationHoldMessagePending = true;
        m_timerOnlineEvaluationHoldMessage.Touch();
        this->PostScreenMessage(SM_LeaveGameplay, 0.25f);
        return;
      }
    } else {
      if (m_bOnlineEvaluationHoldStarted) {
        LOG->Trace("ITG Online: SM_LeaveGameplay evaluation hold released.");
      }
      m_bOnlineEvaluationHoldStarted = false;
    }

    m_bOnlineEvaluationHoldMessagePending = false;
    m_bLoggedOnlineNotesEndedDuringHold = false;
    if (GetITGOnlineIsActive()) {
      LOG->Trace("ITG Online: SM_LeaveGameplay advancing to evaluation.");
    }

    GAMESTATE->m_DanceDuration = GAMESTATE->m_DanceStartTime.Ago();
    // update dancing characters for win / lose
    DancingCharacters* pDancers = nullptr;
    if (m_pSongBackground) {
      pDancers = m_pSongBackground->GetDancingCharacters();
    }
    if (pDancers) {
      FOREACH_EnabledPlayerNumberInfo(m_vPlayerInfo, pi) {
        PlayerState* playerState =
            GetPlayerStateOrWarn(*pi, "ScreenGameplay::SM_LeaveGameplay");
        PlayerStageStats* pss =
            GetPlayerStageStatsOrWarn(*pi, "ScreenGameplay::SM_LeaveGameplay");
        if (playerState == nullptr || pss == nullptr) {
          continue;
        }
        // XXX: In battle modes, switch( GAMESTATE->GetStageResult(p) ).
        if (pss->m_bFailed) {
          pDancers->Change2DAnimState(pi->m_pn, AS2D_FAIL);  // fail anim
        } else if (
            pi->m_pLifeMeter &&
            playerState->m_HealthState == HealthState_Hot) {
          pDancers->Change2DAnimState(
              pi->m_pn, AS2D_WINFEVER);  // full life pass anim
        } else {
          pDancers->Change2DAnimState(pi->m_pn, AS2D_WIN);  // pass anim
        }
      }
    }

    // End round.
    if (m_DancingState == STATE_OUTRO) {  // ScreenGameplay already ended
      return;                             // ignore
    }
    m_DancingState = STATE_OUTRO;
    ResetGiveUpTimers(false);

    GAMESTATE->RemoveAllActiveAttacks();
    FOREACH_EnabledPlayerInfo(m_vPlayerInfo, pi) {
      if (pi->m_pActiveAttackList) {
        pi->m_pActiveAttackList->Refresh();
      }
    }

    if (LIGHTSMAN != nullptr) {
      LIGHTSMAN->SetLightsMode(LIGHTSMODE_ALL_CLEARED);
    }

    bool bAllReallyFailed = STATSMAN->m_CurStageStats.AllFailed();

    if (bAllReallyFailed) {
      this->PostScreenMessage(SM_BeginFailed, 0);
      return;
    }

    // todo: add GameplayCleared, StartTransitioningCleared commands -aj
    TweenOffScreen();

    m_Out.StartTransitioning(SM_DoNextScreen);

    // do they deserve an extra stage?
    if (SOUND != nullptr) {
      if (GAMESTATE->HasEarnedExtraStage()) {
        SOUND->PlayOnceFromAnnouncer("gameplay extra");
      } else {
        SOUND->PlayOnceFromAnnouncer("gameplay cleared");
      }
    }
  } else if (SM == SM_StartLoadingNextSong) {
    // Next song.
    // give a little life back between stages
    FOREACH_EnabledPlayerInfo(m_vPlayerInfo, pi) {
      if (pi->m_pLifeMeter) {
        pi->m_pLifeMeter->OnSongEnded();
      }
    }

    // If this is a repeating course, and we're at the end of it, repick and
    // add new songs to the players' step and song queues.
    if (GAMESTATE->IsCourseMode() && GAMESTATE->m_pCurCourse &&
        GAMESTATE->m_pCurCourse->m_bRepeat &&
        GAMESTATE->GetCourseSongIndex() >= (int)m_apSongsQueue.size() - 1) {
      Course* course = GAMESTATE->m_pCurCourse;
      // Need to store these so they can be used to refetch the players'
      // trails after they're invalidated.
      std::vector<RepeatTrailSnapshot> trailSnapshots;
      FOREACH_EnabledPlayerInfo(m_vPlayerInfo, pi) {
        if (!IsUsableStepsAndTrailIndex(
                *pi, "ScreenGameplay::repeat course old trail")) {
          continue;
        }
        const PlayerNumber stepsPn = pi->GetStepsAndTrailIndex();
        Trail* trail = GAMESTATE->m_pCurTrail[stepsPn];
        if (trail == nullptr) {
          LOG->Warn(
              "SRC_AUDIT_FIX: Repeat course missing old trail for %s.",
              pi->GetName().c_str());
          continue;
        }
        trailSnapshots.push_back(
            { stepsPn, trail->m_StepsType, trail->m_CourseDifficulty });
      }
      // Set a new stage seed so the order will be different.
      GAMESTATE->SetNewStageSeed();
      course->InvalidateTrailCache();
      course->RegenerateNonFixedTrails();
      for (const RepeatTrailSnapshot& snapshot : trailSnapshots) {
        Trail* trail = course->GetTrail(snapshot.stepsType, snapshot.difficulty);
        if (trail == nullptr) {
          LOG->Warn(
              "SRC_AUDIT_FIX: Repeat course failed to regenerate trail for "
              "player index %i.",
              static_cast<int>(snapshot.pn));
          continue;
        }
        GAMESTATE->m_pCurTrail[snapshot.pn].Set(trail);
      }
      PlayerNumber master_pn = GAMESTATE->GetMasterPlayerNumber();
      if (!IsValidGameplayPlayer(master_pn)) {
        LOG->Warn("SRC_AUDIT_FIX: Repeat course invalid master player.");
        return;
      }
      Trail* master_trail = GAMESTATE->m_pCurTrail[master_pn];
      if (master_trail == nullptr) {
        LOG->Warn("SRC_AUDIT_FIX: Repeat course missing master trail.");
        return;
      }
      for (const TrailEntry& entry : master_trail->m_vEntries) {
        if (entry.pSong == nullptr) {
          continue;
        }
        m_apSongsQueue.push_back(entry.pSong);
        STATSMAN->m_CurStageStats.m_vpPossibleSongs.push_back(entry.pSong);
      }
      FOREACH_EnabledPlayerInfo(m_vPlayerInfo, pi) {
        if (!IsUsableStepsAndTrailIndex(
                *pi, "ScreenGameplay::repeat course new trail")) {
          continue;
        }
        Trail* trail = GAMESTATE->m_pCurTrail[pi->GetStepsAndTrailIndex()];
        if (trail == nullptr) {
          continue;
        }
        for (const TrailEntry& entry : trail->m_vEntries) {
          if (entry.pSteps == nullptr) {
            continue;
          }
          pi->m_vpStepsQueue.push_back(entry.pSteps);
          AttackArray a;
          entry.GetAttackArray(a);
          pi->m_asModifiersQueue.push_back(a);
          if (pi->GetPlayerStageStats()) {
            pi->GetPlayerStageStats()->m_vpPossibleSteps.push_back(entry.pSteps);
          }
        }
        // In a survival course, override stored mods
        if (course->GetCourseType() == COURSE_TYPE_SURVIVAL &&
            SURVIVAL_MOD_OVERRIDE) {
          PlayerState* playerState = GetPlayerStateOrWarn(
              *pi, "ScreenGameplay::repeat course survival override");
          if (playerState == nullptr) {
            continue;
          }
          playerState->m_PlayerOptions.FromString(
              ModsLevel_Stage,
              "clearall," + CommonMetrics::DEFAULT_NOTESKIN_NAME.GetValue() +
                  "," + CommonMetrics::DEFAULT_MODIFIERS.GetValue());
          playerState->RebuildPlayerOptionsFromActiveAttacks();
        }
      }
      if (!ValidateGameplayQueues(
              m_apSongsQueue, m_vPlayerInfo,
              "ScreenGameplay::repeat course")) {
        LOG->Warn(
            "SRC_AUDIT_FIX: Repeat course produced invalid queues; leaving "
            "gameplay.");
        HandleScreenMessage(SM_LeaveGameplay);
        return;
      }
    }

    GAMESTATE->m_bLoadingNextSong = true;
    BroadcastGameplayMessage("BeforeLoadingNextCourseSong");
    m_NextSong.Reset();
    m_NextSong.PlayCommand("Start");
    m_NextSong.StartTransitioning(SM_LoadNextSong);
    BroadcastGameplayMessage("ChangeCourseSongIn");
  } else if (SM == SM_LoadNextSong) {
    if (m_pSoundMusic) {
      m_pSoundMusic->Stop();
    }
    SongFinished();

    BroadcastGameplayMessage("ChangeCourseSongOut");

    GAMESTATE->m_bLoadingNextSong = false;
    LoadNextSong();

    m_NextSong.Reset();
    m_NextSong.PlayCommand("Finish");
    m_NextSong.StartTransitioning(SM_None);

    StartPlayingSong(MIN_SECONDS_TO_STEP_NEXT_SONG, 0);
  } else if (SM == SM_PlayToasty) {
    if (g_bEasterEggs && PREFSMAN != nullptr) {
      if (PREFSMAN->m_AllowMultipleToasties || m_Toasty.IsWaiting()) {
        m_Toasty.Reset();
        m_Toasty.StartTransitioning();
      }
    }
  } else if (
      ScreenMessageHelpers::ScreenMessageToString(SM).find("0Combo") !=
      std::string::npos) {
    int iCombo = 0;
    std::string sCropped =
        ScreenMessageHelpers::ScreenMessageToString(SM).substr(3);
    if (sscanf(sCropped.c_str(), "%d%*s", &iCombo) == 1 && iCombo > 0) {
      PlayAnnouncer(ssprintf("gameplay %d combo", iCombo), 2);
    }
  } else if (SM == SM_ComboStopped) {
    PlayAnnouncer("gameplay combo stopped", 2);
  } else if (SM == SM_ComboContinuing) {
    PlayAnnouncer("gameplay combo overflow", 2);
  } else if (SM >= SM_BattleTrickLevel1 && SM <= SM_BattleTrickLevel3) {
    int iTrickLevel = 1;
    if (SM == SM_BattleTrickLevel2) {
      iTrickLevel = 2;
    } else if (SM == SM_BattleTrickLevel3) {
      iTrickLevel = 3;
    }
    PlayAnnouncer(ssprintf("gameplay battle trick level%d", iTrickLevel), 3);
    if (SM == SM_BattleTrickLevel1) {
      m_soundBattleTrickLevel1.Play(false);
    } else if (SM == SM_BattleTrickLevel2) {
      m_soundBattleTrickLevel2.Play(false);
    } else if (SM == SM_BattleTrickLevel3) {
      m_soundBattleTrickLevel3.Play(false);
    }
  } else if (SM >= SM_BattleDamageLevel1 && SM <= SM_BattleDamageLevel3) {
    int iDamageLevel = 1;
    if (SM == SM_BattleDamageLevel2) {
      iDamageLevel = 2;
    } else if (SM == SM_BattleDamageLevel3) {
      iDamageLevel = 3;
    }
    PlayAnnouncer(ssprintf("gameplay battle damage level%d", iDamageLevel), 3);
  } else if (SM == SM_DoPrevScreen) {
    SongFinished();
    this->StageFinished(true);

    m_sNextScreen = GetPrevScreen();

    if (AdjustSync::IsSyncDataChanged()) {
      ScreenSaveSync::PromptSaveSync(SM_GoToPrevScreen);
    } else {
      HandleScreenMessage(SM_GoToPrevScreen);
    }
  } else if (SM == SM_DoNextScreen) {
    SongFinished();
    this->StageFinished(false);
    // only save replays if the player chose to
    if (GAMESTATE->m_SongOptions.GetCurrent().m_bSaveReplay) {
      SaveReplay();
    }

    if (AdjustSync::IsSyncDataChanged()) {
      ScreenSaveSync::PromptSaveSync(SM_GoToNextScreen);
    } else {
      HandleScreenMessage(SM_GoToNextScreen);
    }
  } else if (SM == SM_GainFocus) {
    // We do this ourself.
    if (SOUND != nullptr) {
      SOUND->HandleSongTimer(false);
    }
  } else if (SM == SM_LoseFocus) {
    // We might have turned the song timer off. Be sure to turn it back on.
    if (SOUND != nullptr) {
      SOUND->HandleSongTimer(true);
    }
  } else if (SM == SM_BeginFailed) {
    if (GetITGOnlineIsActive()) {
      if (!m_bMarkedOnlineFailedEarly) {
        m_bMarkedOnlineFailedEarly = true;
        MarkITGOnlineFailedEarly();
        LOG->Trace(
            "ITG Online: player failed but ScreenGameplay is kept active.");
      }

      if (OnlineShouldHoldBeforeEvaluation()) {
        if (!m_bOnlineFailedHoldStarted) {
          LOG->Trace("ITG Online: SM_BeginFailed starting failed-player hold.");
          m_bOnlineFailedHoldStarted = true;
          m_timerOnlineFailedHoldStarted.Touch();
        } else if (m_timerOnlineFailedHoldStarted.Ago() >=
                   ITGONLINE_FAILED_HOLD_MAX_SECONDS) {
          LOG->Warn(
              "ITG Online: failed-player hold timed out after %.2fs; "
              "continuing to evaluation.",
              m_timerOnlineFailedHoldStarted.Ago());
          m_bOnlineFailedHoldStarted = false;
        } else {
          LOG->Trace(
              "ITG Online: SM_BeginFailed continuing failed-player hold for "
              "%.2fs.",
              m_timerOnlineFailedHoldStarted.Ago());
          ResetGiveUpTimers(false);
          this->PostScreenMessage(SM_BeginFailed, 0.25f);
          return;
        }

        if (m_bOnlineFailedHoldStarted) {
          LOG->Trace("ITG Online: SM_BeginFailed reposting failed-player hold.");
          ResetGiveUpTimers(false);
          this->PostScreenMessage(SM_BeginFailed, 0.25f);
          return;
        }
      } else {
        if (m_bOnlineFailedHoldStarted) {
          LOG->Trace("ITG Online: SM_BeginFailed failed-player hold released.");
        }
        m_bOnlineFailedHoldStarted = false;
      }

      LOG->Trace(
          "ITG Online: failed player released from ScreenGameplay to "
          "evaluation.");
    }

    m_DancingState = STATE_OUTRO;
    ResetGiveUpTimers(false);
    m_GameplayAssist.StopPlaying();  // Stop any queued assist ticks.
    TweenOffScreen();
    m_Failed.StartTransitioning(SM_DoNextScreen);

    // show the survive time if extra stage
    if (STATSMAN != nullptr && GAMESTATE->IsAnExtraStage()) {
      float fMaxAliveSeconds = 0;
      FOREACH_EnabledPlayer(p) fMaxAliveSeconds = std::max(
          fMaxAliveSeconds,
          STATSMAN->m_CurStageStats.m_player[p].m_fAliveSeconds);
      m_textSurviveTime.SetText("TIME: " + SecondsToMMSSMsMs(fMaxAliveSeconds));
      ON_COMMAND(m_textSurviveTime);
    }

    if (GAMESTATE->IsCourseMode()) {
      if (SOUND != nullptr &&
          GAMESTATE->GetCourseSongIndex() >= int(m_apSongsQueue.size() / 2)) {
        SOUND->PlayOnceFromAnnouncer("gameplay oni failed halfway");
      } else if (SOUND != nullptr) {
        SOUND->PlayOnceFromAnnouncer("gameplay oni failed");
      }
    } else if (SOUND != nullptr) {
      SOUND->PlayOnceFromAnnouncer("gameplay failed");
    }
  } else if (SM == SM_Pause) {
    // Ignore SM_Pause when in demonstration.
    if (GAMESTATE->m_bDemonstrationOrJukebox) {
      return;
    }

    if (!m_bPaused) {
      PauseGame(true);
    }
  }

  ScreenWithMenuElements::HandleScreenMessage(SM);
}

void ScreenGameplay::HandleMessage(const Message& msg) {
  if (msg == "Judgment") {
    if (LUA == nullptr) {
      ScreenWithMenuElements::HandleMessage(msg);
      return;
    }
    PlayerNumber pn = PLAYER_INVALID;
    if (!msg.GetParam("Player", pn) || !IsValidGameplayPlayer(pn)) {
      LOG->Warn(
          "SRC_AUDIT_FIX: Ignoring Judgment message without valid Player.");
      ScreenWithMenuElements::HandleMessage(msg);
      return;
    }

    FOREACH_EnabledPlayerNumberInfo(m_vPlayerInfo, pi) {
      if (pi->m_pn != pn) {
        continue;
      }
      PlayerState* playerState =
          GetPlayerStateOrWarn(*pi, "ScreenGameplay::HandleMessage Judgment");
      if (playerState == nullptr ||
          !playerState->m_PlayerOptions.GetCurrent().m_bMuteOnError) {
        continue;
      }

      RageSoundReader* pSoundReader = m_AutoKeysounds.GetPlayerSound(pn);
      if (pSoundReader == nullptr) {
        pSoundReader = m_AutoKeysounds.GetSharedSound();
      }

      HoldNoteScore hns = HoldNoteScore_Invalid;
      const bool hasHoldScore = msg.GetParam("HoldNoteScore", hns);
      TapNoteScore tns = TapNoteScore_Invalid;
      const bool hasTapScore = msg.GetParam("TapNoteScore", tns);
      if (!hasHoldScore && !hasTapScore) {
        LOG->Warn(
            "SRC_AUDIT_FIX: Ignoring Judgment message without a score.");
        continue;
      }

      bool bOn = false;
      if (hns != HoldNoteScore_Invalid) {
        bOn = hns != HNS_LetGo;
      } else if (tns != TapNoteScore_Invalid) {
        bOn = tns != TNS_Miss;
      } else {
        LOG->Warn(
            "SRC_AUDIT_FIX: Ignoring Judgment message with invalid scores.");
        continue;
      }

      if (pSoundReader) {
        pSoundReader->SetProperty("Volume", bOn ? 1.0f : 0.0f);
      }
    }
  }

  ScreenWithMenuElements::HandleMessage(msg);
}

void ScreenGameplay::Cancel(ScreenMessage smSendWhenDone) {
  if (m_pSoundMusic) {
    m_pSoundMusic->Stop();
  }

  ScreenWithMenuElements::Cancel(smSendWhenDone);
}

Song* ScreenGameplay::GetNextCourseSong() const {
  if (GAMESTATE == nullptr || !GAMESTATE->IsCourseMode() ||
      m_apSongsQueue.empty()) {
    return nullptr;
  }

  int iPlaySongIndex = GAMESTATE->GetCourseSongIndex() + 1;
  iPlaySongIndex %= static_cast<int>(m_apSongsQueue.size());
  if (iPlaySongIndex < 0) {
    iPlaySongIndex = 0;
  }

  return m_apSongsQueue[iPlaySongIndex];
}

LifeMeter* ScreenGameplay::GetLifeMeter(PlayerNumber pn) {
  PlayerInfo* pi = GetPlayerInfo(pn);
  if (pi == nullptr) {
    return nullptr;
  }
  return pi->m_pLifeMeter;
}

PlayerInfo* ScreenGameplay::GetPlayerInfo(PlayerNumber pn) {
  FOREACH_EnabledPlayerNumberInfo(m_vPlayerInfo, pi) {
    if (pi->m_pn == pn) {
      return &*pi;
    }
  }
  return nullptr;
}

PlayerInfo* ScreenGameplay::GetDummyPlayerInfo(int iDummyIndex) {
  FOREACH_EnabledPlayerInfo(m_vPlayerInfo, pi) {
    if (pi->m_bIsDummy && pi->m_iDummyIndex == iDummyIndex) {
      return &*pi;
    }
  }
  return nullptr;
}

void ScreenGameplay::SaveReplay() {
  /* Replay data TODO:
   * Add more player information (?)
   * Add AutoGen flag if steps were autogen?
   * Add proper steps hash?
   * Add modifiers used
   * Add date played, machine played on, etc.
   * Hash of some stuff to validate data (see Profile)
   */
  if (GAMESTATE == nullptr || PROFILEMAN == nullptr) {
    LOG->Warn("SRC_AUDIT_FIX: SaveReplay skipped without required managers.");
    return;
  }
  FOREACH_HumanPlayer(pn) {
    if (!IsValidGameplayPlayer(pn) || GAMESTATE->m_pCurSong == nullptr ||
        GAMESTATE->m_pCurSteps[pn] == nullptr) {
      continue;
    }
    Profile* pTempProfile = PROFILEMAN->GetProfile(pn);
    if (pTempProfile == nullptr) {
      LOG->Warn(
          "SRC_AUDIT_FIX: SaveReplay skipped player %i without profile.",
          static_cast<int>(pn));
      continue;
    }
    bool savedForPlayer = false;
    FOREACH_EnabledPlayerInfo(m_vPlayerInfo, pi) {
      if (pi->GetStepsAndTrailIndex() != pn || pi->m_pPlayer == nullptr) {
        continue;
      }

      XNode* p = new XNode("ReplayData");
      // append version number (in case the format changes)
      p->AppendAttr("Version", 0);

      // song information node
      SongID songID;
      songID.FromSong(GAMESTATE->m_pCurSong);
      XNode* pSongInfoNode = songID.CreateNode();
      pSongInfoNode->AppendChild(
          "Title", GAMESTATE->m_pCurSong->GetDisplayFullTitle());
      pSongInfoNode->AppendChild(
          "Artist", GAMESTATE->m_pCurSong->GetDisplayArtist());
      p->AppendChild(pSongInfoNode);

      // steps information
      StepsID stepsID;
      stepsID.FromSteps(GAMESTATE->m_pCurSteps[pn]);
      XNode* pStepsInfoNode = stepsID.CreateNode();
      // hashing = argh
      // pStepsInfoNode->AppendChild("StepsHash",
      // stepsID.ToSteps(GAMESTATE->m_pCurSong,false)->GetHash());
      p->AppendChild(pStepsInfoNode);

      // player information node (rival data sup)
      XNode* pPlayerInfoNode = new XNode("Player");
      pPlayerInfoNode->AppendChild("DisplayName", pTempProfile->m_sDisplayName);
      pPlayerInfoNode->AppendChild("Guid", pTempProfile->m_sGuid);
      p->AppendChild(pPlayerInfoNode);

      // the timings.
      p->AppendChild(pi->m_pPlayer->GetNoteData().CreateNode());

      // Find a file name for the replay
      std::vector<std::string> files;
      GetDirListing("Save/Replays/replay*", files, false, false);
      sort(files.begin(), files.end());

      // Files should be of the form "replay#####.xml".
      int iIndex = 0;

      for (int i = static_cast<int>(files.size()) - 1; i >= 0; --i) {
        static Regex re("^replay([0-9]{5})\\....$");
        std::vector<std::string> matches;
        if (!re.Compare(files[i], matches)) {
          continue;
        }

        ASSERT(matches.size() == 1);
        iIndex = StringToInt(matches[0]) + 1;
        break;
      }

      std::string sFileName = ssprintf("replay%05d.xml", iIndex);

      XmlFileUtil::SaveToFile(p, "Save/Replays/" + sFileName);
      RageUtil::SafeDelete(p);
      savedForPlayer = true;
      break;
    }
    if (!savedForPlayer) {
      LOG->Warn(
          "SRC_AUDIT_FIX: SaveReplay found no loaded Player for player %i.",
          static_cast<int>(pn));
    }
  }
}

/*
bool ScreenGameplay::LoadReplay()
{
        // Load replay which was selected via options
}
*/

// lua start
#include "LuaBinding.h"
#include "OptionsBinding.h"

/** @brief Allow Lua to have access to the ScreenGameplay. */
class LunaScreenGameplay : public Luna<ScreenGameplay> {
 public:
  static int GetNextCourseSong(T* p, lua_State* L) {
    Song* song = p->GetNextCourseSong();
    if (song == nullptr) {
      return 0;
    }
    song->PushSelf(L);
    return 1;
  }
  static int Center1Player(T* p, lua_State* L) {
    lua_pushboolean(L, p->Center1Player());
    return 1;
  }
  static int GetLifeMeter(T* p, lua_State* L) {
    PlayerNumber pn = Enum::Check<PlayerNumber>(L, 1);

    LifeMeter* pLM = p->GetLifeMeter(pn);
    if (pLM == nullptr) {
      return 0;
    }

    pLM->PushSelf(L);
    return 1;
  }
  static int GetPlayerInfo(T* p, lua_State* L) {
    PlayerNumber pn = Enum::Check<PlayerNumber>(L, 1);

    PlayerInfo* pi = p->GetPlayerInfo(pn);
    if (pi == nullptr) {
      return 0;
    }

    pi->PushSelf(L);
    return 1;
  }
  static int GetDummyPlayerInfo(T* p, lua_State* L) {
    int iDummyIndex = IArg(1);
    PlayerInfo* pi = p->GetDummyPlayerInfo(iDummyIndex);
    if (pi == nullptr) {
      return 0;
    }
    pi->PushSelf(L);
    return 1;
  }
  static int PauseGame(T* p, lua_State* L) {
    p->Pause(BArg(1));
    return 0;
  }
  static int SeekMusicSeconds(T* p, lua_State* L) {
    lua_pushboolean(L, p->SeekMusicSeconds(FArg(1)));
    return 1;
  }
  static int IsPaused(T* p, lua_State* L) {
    lua_pushboolean(L, p->IsPaused());
    return 1;
  }
  static int GetHasteRate(T* p, lua_State* L) {
    lua_pushnumber(L, p->GetHasteRate());
    return 1;
  }
  static bool TurningPointsValid(lua_State* L, int index) {
    size_t size = lua_objlen(L, index);
    if (size < 2) {
      luaL_error(L, "Invalid number of entries %zu", size);
    }
    float prev_turning = -1;
    for (size_t n = 1; n <= size; ++n) {
      lua_rawgeti(L, index, n);
      float v = FArg(-1);
      if (!std::isfinite(v) || v < -1 || v < prev_turning || v > 1) {
        luaL_error(L, "Invalid value %f", v);
      }
      prev_turning = v;
      lua_pop(L, 1);
    }
    return true;
  }
  static bool AddAmountsValid(lua_State* L, int index) {
    return TurningPointsValid(L, index);
  }
  FLOAT_TABLE_INTERFACE(
      HasteTurningPoints, HasteTurningPoints, TurningPointsValid);
  FLOAT_TABLE_INTERFACE(HasteAddAmounts, HasteAddAmounts, AddAmountsValid);
  FLOAT_NO_SPEED_INTERFACE(
      HasteTimeBetweenUpdates, HasteTimeBetweenUpdates, (v > 0));
  FLOAT_NO_SPEED_INTERFACE(
      HasteLifeSwitchPoint, HasteLifeSwitchPoint, (v >= 0 && v <= 1));
  static int begin_backing_out(T* p, lua_State* L) {
    p->BeginBackingOutFromGameplay();
    COMMON_RETURN_SELF;
  }
  static int GetTrueBPS(T* p, lua_State* L) {
    PlayerNumber pn = Enum::Check<PlayerNumber>(L, 1);
    if (!IsValidGameplayPlayer(pn) || GAMESTATE == nullptr ||
        GAMESTATE->m_pPlayerState[pn] == nullptr) {
      lua_pushnumber(L, 0);
      return 1;
    }
    float haste = p->GetHasteRate();
    float rate = GAMESTATE->m_SongOptions.GetCurrent().m_fMusicRate;
    float bps = GAMESTATE->m_pPlayerState[pn]->m_Position.m_fCurBPS;
    float true_bps = haste * rate * bps;
    if (!std::isfinite(true_bps)) {
      true_bps = 0.0f;
    }
    lua_pushnumber(L, true_bps);
    return 1;
  }

  LunaScreenGameplay() {
    ADD_METHOD(GetNextCourseSong);
    ADD_METHOD(Center1Player);
    ADD_METHOD(GetLifeMeter);
    ADD_METHOD(GetPlayerInfo);
    ADD_METHOD(GetDummyPlayerInfo);
    // sm-ssc additions:
    ADD_METHOD(PauseGame);
    ADD_METHOD(SeekMusicSeconds);
    ADD_METHOD(IsPaused);
    ADD_METHOD(GetHasteRate);
    ADD_METHOD(HasteTurningPoints);
    ADD_METHOD(HasteAddAmounts);
    ADD_METHOD(HasteTimeBetweenUpdates);
    ADD_METHOD(HasteLifeSwitchPoint);
    ADD_METHOD(begin_backing_out);
    ADD_METHOD(GetTrueBPS);
  }
};

LUA_REGISTER_DERIVED_CLASS(ScreenGameplay, ScreenWithMenuElements)

/** @brief Allow Lua to have access to the PlayerInfo. */
class LunaPlayerInfo : public Luna<PlayerInfo> {
 public:
  static int GetLifeMeter(T* p, lua_State* L) {
    if (p->m_pLifeMeter) {
      p->m_pLifeMeter->PushSelf(L);
      return 1;
    }
    return 0;
  }

  static int GetStepsQueueWrapped(T* p, lua_State* L) {
    int iIndex = IArg(1);
    if (p->m_vpStepsQueue.empty()) {
      return 0;
    }
    iIndex %= static_cast<int>(p->m_vpStepsQueue.size());
    if (iIndex < 0) {
      iIndex += static_cast<int>(p->m_vpStepsQueue.size());
    }
    Steps* pSteps = p->m_vpStepsQueue[iIndex];
    if (pSteps == nullptr) {
      return 0;
    }
    pSteps->PushSelf(L);
    return 1;
  }

  LunaPlayerInfo() {
    ADD_METHOD(GetLifeMeter);
    ADD_METHOD(GetStepsQueueWrapped);
  }
};

LUA_REGISTER_CLASS(PlayerInfo)
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
