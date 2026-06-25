#include "ScreenSelectMusic.h"

#include <algorithm>
#include <cmath>
#include <string>
#include <vector>

#include "ActorUtil.h"
#include "Banner.h"
#include "CodeDetector.h"
#include "CommonMetrics.h"
#include "Course.h"
#include "Difficulty.h"
#include "EnumHelper.h"
#include "Game.h"
#include "GameConstantsAndTypes.h"
#include "GameInput.h"
#include "GameManager.h"
#include "GameSoundManager.h"
#include "GameState.h"
#include "ImageCache.h"
#include "InputEventPlus.h"
#include "InputFilter.h"
#include "InputMapper.h"
#include "LocalizedString.h"
#include "LuaManager.h"
#include "MenuTimer.h"
#include "MessageManager.h"
#include "ModsGroup.h"
#include "MusicWheelItem.h"
#include "OptionsList.h"
#include "PlayerNumber.h"
#include "PlayerOptions.h"
#include "PlayerState.h"
#include "PrefsManager.h"
#include "Profile.h"
#include "ProfileManager.h"
#include "RageFileManager.h"
#include "RageInput.h"
#include "RageInputDevice.h"
#include "RageLog.h"
#include "RageSound.h"
#include "RageTextureManager.h"
#include "RageTimer.h"
#include "RageUtil.h"
#include "Screen.h"
#include "ScreenManager.h"
#include "ScreenMessage.h"
#include "ScreenPrompt.h"
#include "ScreenWithMenuElements.h"
#include "Song.h"
#include "SongManager.h"
#include "SongUtil.h"
#include "Sprite.h"
#include "StatsManager.h"
#include "Steps.h"
#include "StepsUtil.h"
#include "Style.h"
#include "ThemeManager.h"
#include "ThemeMetric.h"
#include "WheelItemBase.h"
#include "global.h"

static const char* SelectionStateNames[] = {
    "SelectingSong", "SelectingSteps", "Finalized"};
XToString(SelectionState);

/** @brief The maximum number of digits for the ScoreDisplay. */
const int NUM_SCORE_DIGITS = 9;

static const ThemeMetric<int> HARD_COMMENT_METER(
    "ScreenSelectMusic", "HardCommentMeter");

AutoScreenMessage(SM_AllowOptionsMenuRepeat);
AutoScreenMessage(SM_SongChanged);
AutoScreenMessage(SM_SortOrderChanging);
AutoScreenMessage(SM_SortOrderChanged);
AutoScreenMessage(SM_BackFromPlayerOptions);
AutoScreenMessage(SM_ConfirmDeleteSong);
AutoScreenMessage(SM_ConfirmExit);

static LocalizedString PERMANENTLY_DELETE(
    "ScreenSelectMusic", "PermanentlyDelete");
static LocalizedString PROMPT_BEFORE_EXITING(
    "ScreenSelectMusic", "PromptBeforeExiting");

REGISTER_SCREEN_CLASS(ScreenSelectMusic);

namespace {
bool IsValidPlayer(PlayerNumber pn) {
  return pn >= PLAYER_1 && pn < NUM_PLAYERS;
}

bool IsValidButton(GameButton button) {
  return button >= 0 && button < NUM_GameButton;
}

bool HasLoadedSelectMusicTheme() {
  return THEME != nullptr && THEME->IsThemeLoaded();
}

void WarnSelectMusic(const char* fmt, ...) {
  if (LOG == nullptr) {
    return;
  }

  va_list va;
  va_start(va, fmt);
  LOG->Warn("%s", vssprintf(fmt, va).c_str());
  va_end(va);
}

float SanitizeMetricSeconds(float seconds, float fallback = 0.0f) {
  if (!std::isfinite(seconds)) {
    return fallback;
  }
  return std::max(0.0f, seconds);
}

float SanitizeSampleLength(float seconds) {
  if (!std::isfinite(seconds)) {
    return -1.0f;
  }
  return seconds < 0.0f ? -1.0f : seconds;
}

int ClampSelectionIndex(int selection, size_t size) {
  if (size == 0) {
    return -1;
  }
  return std::max(0, std::min(selection, static_cast<int>(size) - 1));
}

Steps* GetSelectedSteps(const std::vector<Steps*>& steps, int selection) {
  const int index = ClampSelectionIndex(selection, steps.size());
  return index < 0 ? nullptr : steps[index];
}

Trail* GetSelectedTrail(const std::vector<Trail*>& trails, int selection) {
  const int index = ClampSelectionIndex(selection, trails.size());
  return index < 0 ? nullptr : trails[index];
}

void BroadcastSelectMusic(const std::string& message) {
  if (MESSAGEMAN != nullptr) {
    MESSAGEMAN->Broadcast(message);
  }
}

void BroadcastSelectMusic(Message& message) {
  if (MESSAGEMAN != nullptr) {
    MESSAGEMAN->Broadcast(message);
  }
}

std::string GetThemeMetricString(
    const std::string& group, const std::string& metric) {
  return !HasLoadedSelectMusicTheme() || !THEME->HasMetric(group, metric)
             ? std::string()
             : THEME->GetMetric(group, metric);
}

std::string GetThemePathS(const std::string& group, const std::string& metric) {
  return !HasLoadedSelectMusicTheme() || !THEME->HasMetric(group, metric)
             ? std::string()
             : THEME->GetPathS(group, metric);
}

std::string GetThemePathG(const std::string& group, const std::string& metric) {
  return !HasLoadedSelectMusicTheme() || !THEME->HasMetric(group, metric)
             ? std::string()
             : THEME->GetPathG(group, metric);
}

std::string GetThemePathF(const std::string& group, const std::string& metric) {
  return !HasLoadedSelectMusicTheme() || !THEME->HasMetric(group, metric)
             ? std::string()
             : THEME->GetPathF(group, metric);
}

float GetThemeMetricSeconds(
    const std::string& group, const std::string& metric,
    float fallback = 0.0f) {
  return !HasLoadedSelectMusicTheme() || !THEME->HasMetric(group, metric)
             ? fallback
             : SanitizeMetricSeconds(THEME->GetMetricF(group, metric), fallback);
}

GameButton ButtonFromMetric(
    const std::string& group, const std::string& metric) {
  if (INPUTMAPPER == nullptr || INPUTMAPPER->GetInputScheme() == nullptr) {
    return GameButton_Invalid;
  }

  const std::string button_name = GetThemeMetricString(group, metric);
  if (button_name.empty()) {
    return GameButton_Invalid;
  }
  return INPUTMAPPER->GetInputScheme()->ButtonNameToIndex(button_name);
}

void PlaySoundIfLoaded(RageSound& sound, bool copy = false) {
  if (!sound.IsLoaded()) {
    return;
  }

  if (copy) {
    sound.PlayCopy(true);
  } else {
    sound.Play(true);
  }
}

bool LoadSoundIfPathPresent(
    RageSound& sound,
    const std::string& path,
    bool preload = false,
    RageSoundLoadParams* params = nullptr) {
  if (path.empty()) {
    return false;
  }

  return sound.Load(path, preload, params);
}

const Profile* GetSafeProfile(PlayerNumber pn) {
  if (PROFILEMAN == nullptr || !IsValidPlayer(pn)) {
    return nullptr;
  }
  return PROFILEMAN->IsPersistentProfile(pn) ? PROFILEMAN->GetProfile(pn)
                                             : PROFILEMAN->GetMachineProfile();
}

bool HasUsableTimer(MenuTimer* timer) { return timer != nullptr; }

bool PathStartsWith(const std::string& path, const std::string& prefix) {
  return path.compare(0, prefix.size(), prefix) == 0;
}

std::string NormalizeVirtualDirectory(std::string path) {
  Replace(path, '\\', '/');
  CollapsePath(path, true);
  if (!path.empty() && path[path.size() - 1] != '/') {
    path += "/";
  }
  return path;
}

bool IsSafeSongDeletionDirectory(const std::string& songDir) {
  const std::string normalized = NormalizeVirtualDirectory(songDir);
  if (!PathStartsWith(normalized, "Songs/") ||
      PathStartsWith(normalized, "Songs/../") ||
      normalized.find("/../") != std::string::npos) {
    return false;
  }

  std::vector<std::string> pathParts;
  split(normalized, "/", pathParts, true);
  // Require Songs/<group>/<song>/ and refuse deleting the root or a whole group.
  return pathParts.size() >= 3 && pathParts[0] == "Songs" &&
         !pathParts[1].empty() && !pathParts[2].empty();
}
}  // namespace

static bool HasActiveITGOnlineRoom() {
  if (LUA == nullptr) {
    return false;
  }

  Lua* L = LUA->Get();
  const int top = lua_gettop(L);
  const bool ran = LuaHelpers::RunExpression(
      L,
      "ITGOnline ~= nil "
      "and ITGOnline.currentRoom ~= nil "
      "and ITGOnline.currentRoomId ~= nil "
      "and ITGOnline.currentRoom.id == ITGOnline.currentRoomId "
      "and ITGOnline.user ~= nil",
      "HasActiveITGOnlineRoom");
  const bool active = ran && lua_gettop(L) > top && lua_toboolean(L, -1);
  lua_settop(L, top);
  LUA->Release(L);

  return active;
}

ScreenSelectMusic::ScreenSelectMusic()
    : m_SelectionState(SelectionState_SelectingSong),
      m_bGoToOptions(false),
      m_pSampleMusicTimingData(nullptr),
      m_fSampleStartSeconds(0.0f),
      m_fSampleLengthSeconds(-1.0f),
      m_bAllowOptionsMenu(false),
      m_bAllowOptionsMenuRepeat(false),
      m_bPreviewSuspendedForPrompt(false),
      m_bPreviewDisabled(false),
      m_bWantFallbackCdTitle(false),
      m_bCDTitleWaiting(false),
      m_bBannerWaiting(false),
      m_bSampleMusicWaiting(false) {
  ZERO(m_iSelection);
  ZERO(m_bStepsChosen);
  ZERO(m_bSelectIsDown);
  ZERO(m_bAcceptSelectRelease);

  m_GameButtonPreviousSong = GameButton_Invalid;
  m_GameButtonNextSong = GameButton_Invalid;
  m_GameButtonPreviousDifficulty = GameButton_Invalid;
  m_GameButtonNextDifficulty = GameButton_Invalid;
  m_GameButtonPreviousGroup = GameButton_Invalid;
  m_GameButtonNextGroup = GameButton_Invalid;
  m_GameButtonCancelTwoPart1 = GameButton_Invalid;
  m_GameButtonCancelTwoPart2 = GameButton_Invalid;
}

void ScreenSelectMusic::Init() {
  m_ScreenStartedLoadingAt.Touch();
  if (PREFSMAN != nullptr && GAMESTATE != nullptr && GAMEMAN != nullptr &&
      PREFSMAN->m_sTestInitialScreen.Get() == m_sName) {
    GAMESTATE->m_PlayMode.Set(PLAY_MODE_REGULAR);
    const Game* default_game = GAMEMAN->GetDefaultGame();
    const Style* versus_style =
        default_game == nullptr
            ? nullptr
            : GAMEMAN->GameAndStringToStyle(default_game, "versus");
    if (versus_style != nullptr) {
      GAMESTATE->SetCurrentStyle(versus_style, PLAYER_INVALID);
    } else {
      WarnSelectMusic(
          "Unable to set test initial style for %s.", m_sName.c_str());
    }
    GAMESTATE->JoinPlayer(PLAYER_1);
    GAMESTATE->SetMasterPlayerNumber(PLAYER_1);
  }

  IDLE_COMMENT_SECONDS.Load(m_sName, "IdleCommentSeconds");
  SAMPLE_MUSIC_DELAY_INIT.Load(m_sName, "SampleMusicDelayInit");
  SAMPLE_MUSIC_DELAY.Load(m_sName, "SampleMusicDelay");
  SAMPLE_MUSIC_LOOPS.Load(m_sName, "SampleMusicLoops");
  SAMPLE_MUSIC_STARTS_IMMEDIATELY.Load(m_sName, "SampleMusicStartsImmediately");
  SAMPLE_MUSIC_PREVIEW_MODE.Load(m_sName, "SampleMusicPreviewMode");
  SAMPLE_MUSIC_FALLBACK_FADE_IN_SECONDS.Load(
      m_sName, "SampleMusicFallbackFadeInSeconds");
  SAMPLE_MUSIC_FADE_OUT_SECONDS.Load(m_sName, "SampleMusicFadeOutSeconds");
  DO_ROULETTE_ON_MENU_TIMER.Load(m_sName, "DoRouletteOnMenuTimer");
  ROULETTE_TIMER_SECONDS.Load(m_sName, "RouletteTimerSeconds");
  ALIGN_MUSIC_BEATS.Load(m_sName, "AlignMusicBeat");
  CODES.Load(m_sName, "Codes");
  MUSIC_WHEEL_TYPE.Load(m_sName, "MusicWheelType");
  SELECT_MENU_AVAILABLE.Load(m_sName, "SelectMenuAvailable");
  MODE_MENU_AVAILABLE.Load(m_sName, "ModeMenuAvailable");
  USE_OPTIONS_LIST.Load(m_sName, "UseOptionsList");
  USE_PLAYER_SELECT_MENU.Load(m_sName, "UsePlayerSelectMenu");
  SELECT_MENU_NAME.Load(m_sName, "SelectMenuScreenName");
  OPTIONS_LIST_TIMEOUT.Load(m_sName, "OptionsListTimeout");
  SELECT_MENU_CHANGES_DIFFICULTY.Load(m_sName, "SelectMenuChangesDifficulty");
  TWO_PART_SELECTION.Load(m_sName, "TwoPartSelection");
  TWO_PART_CONFIRMS_ONLY.Load(m_sName, "TwoPartConfirmsOnly");
  TWO_PART_TIMER_SECONDS.Load(m_sName, "TwoPartTimerSeconds");
  WRAP_CHANGE_STEPS.Load(m_sName, "WrapChangeSteps");
  NULL_SCORE_STRING.Load(m_sName, "NullScoreString");
  PLAY_SOUND_ON_ENTERING_OPTIONS_MENU.Load(
      m_sName, "PlaySoundOnEnteringOptionsMenu");
  // To allow changing steps with gamebuttons -DaisuMaster
  CHANGE_STEPS_WITH_GAME_BUTTONS.Load(m_sName, "ChangeStepsWithGameButtons");
  CHANGE_GROUPS_WITH_GAME_BUTTONS.Load(m_sName, "ChangeGroupsWithGameButtons");
  CONFIRM_EXIT.Load(m_sName, "ConfirmExit");

  m_bPreviewDisabled = !SAMPLE_MUSIC_STARTS_IMMEDIATELY;

  m_GameButtonPreviousSong = ButtonFromMetric(m_sName, "PreviousSongButton");
  m_GameButtonNextSong = ButtonFromMetric(m_sName, "NextSongButton");

  // Ask for those only if changing steps with gamebuttons is allowed
  // -DaisuMaster Use for TwoPartSelection too.
  if (CHANGE_STEPS_WITH_GAME_BUTTONS || TWO_PART_SELECTION) {
    m_GameButtonPreviousDifficulty =
        ButtonFromMetric(m_sName, "PreviousDifficultyButton");
    m_GameButtonNextDifficulty =
        ButtonFromMetric(m_sName, "NextDifficultyButton");
  }
  if (TWO_PART_SELECTION) {
    m_GameButtonCancelTwoPart1 =
        ButtonFromMetric(m_sName, "CancelTwoPartSelectButton1");
    m_GameButtonCancelTwoPart2 =
        ButtonFromMetric(m_sName, "CancelTwoPartSelectButton2");
  }
  // same here but for groups -DaisuMaster
  if (CHANGE_GROUPS_WITH_GAME_BUTTONS) {
    m_GameButtonPreviousGroup =
        ButtonFromMetric(m_sName, "PreviousGroupButton");
    m_GameButtonNextGroup = ButtonFromMetric(m_sName, "NextGroupButton");
  }

  FOREACH_ENUM(PlayerNumber, p) {
    m_bSelectIsDown[p] = false;  // used by UpdateSelectButton
    m_bAcceptSelectRelease[p] = false;
  }
  m_bPreviewSuspendedForPrompt = false;

  ScreenWithMenuElements::Init();

  this->SubscribeToMessage(Message_PlayerJoined);
  this->SubscribeToMessage(Message_PlayerProfileSet);

  // Cache these values
  // Marking for change -- Midiman (why? -aj)
  m_sSectionMusicPath = GetThemePathS(m_sName, "section music");
  m_sSortMusicPath = GetThemePathS(m_sName, "sort music");
  m_sRouletteMusicPath = GetThemePathS(m_sName, "roulette music");
  m_sRandomMusicPath = GetThemePathS(m_sName, "random music");
  m_sCourseMusicPath = GetThemePathS(m_sName, "course music");
  m_sLoopMusicPath = GetThemePathS(m_sName, "loop music");
  m_sFallbackCDTitlePath = GetThemePathG(m_sName, "fallback cdtitle");

  if (!m_sFallbackCDTitlePath.empty()) {
    m_TexturePreload.Load(m_sFallbackCDTitlePath);
  }

  // load banners
  if (PREFSMAN != nullptr && PREFSMAN->m_ImageCache != IMGCACHE_OFF) {
    m_TexturePreload.Load(
        Banner::SongBannerTexture(GetThemePathG("Banner", "all music")));
    m_TexturePreload.Load(
        Banner::SongBannerTexture(GetThemePathG("Common", "fallback banner")));
    m_TexturePreload.Load(
        Banner::SongBannerTexture(GetThemePathG("Banner", "roulette")));
    m_TexturePreload.Load(
        Banner::SongBannerTexture(GetThemePathG("Banner", "random")));
    m_TexturePreload.Load(
        Banner::SongBannerTexture(GetThemePathG("Banner", "mode")));
  }

  // Load low-res banners and backgrounds if needed.
  if (IMAGECACHE != nullptr) {
    IMAGECACHE->Demand("Banner");
  }

  m_MusicWheel.SetName("MusicWheel");
  m_MusicWheel.Load(MUSIC_WHEEL_TYPE);
  LOAD_ALL_COMMANDS_AND_SET_XY(m_MusicWheel);
  this->AddChild(&m_MusicWheel);

  if (USE_OPTIONS_LIST) {
    FOREACH_PlayerNumber(p) {
      m_OptionsList[p].SetName("OptionsList" + PlayerNumberToString(p));
      m_OptionsList[p].Load("OptionsList", p);
      m_OptionsList[p].SetDrawOrder(100);
      ActorUtil::LoadAllCommands(m_OptionsList[p], m_sName);
      this->AddChild(&m_OptionsList[p]);
    }
    m_OptionsList[PLAYER_1].Link(&m_OptionsList[PLAYER_2]);
    m_OptionsList[PLAYER_2].Link(&m_OptionsList[PLAYER_1]);
  }

  // this is loaded SetSong and TweenToSong
  m_Banner.SetName("Banner");
  LOAD_ALL_COMMANDS_AND_SET_XY(m_Banner);
  this->AddChild(&m_Banner);

  m_sprCDTitleFront.SetName("CDTitle");
  {
    const std::string fallbackCDTitlePath =
        GetThemePathG(m_sName, "fallback cdtitle");
    if (!fallbackCDTitlePath.empty()) {
      m_sprCDTitleFront.Load(fallbackCDTitlePath);
    }
  }
  LOAD_ALL_COMMANDS_AND_SET_XY(m_sprCDTitleFront);
  COMMAND(m_sprCDTitleFront, "Front");
  this->AddChild(&m_sprCDTitleFront);

  m_sprCDTitleBack.SetName("CDTitle");
  {
    const std::string fallbackCDTitlePath =
        GetThemePathG(m_sName, "fallback cdtitle");
    if (!fallbackCDTitlePath.empty()) {
      m_sprCDTitleBack.Load(fallbackCDTitlePath);
    }
  }
  LOAD_ALL_COMMANDS_AND_SET_XY(m_sprCDTitleBack);
  COMMAND(m_sprCDTitleBack, "Back");
  this->AddChild(&m_sprCDTitleBack);

  FOREACH_ENUM(PlayerNumber, p) {
    const std::string scoreFramePath =
        GetThemePathG(m_sName, ssprintf("ScoreFrame P%d", p + 1));
    if (!scoreFramePath.empty()) {
      m_sprHighScoreFrame[p].Load(scoreFramePath);
    }
    if (m_sprHighScoreFrame[p].IsLoaded()) {
      m_sprHighScoreFrame[p]->SetName(ssprintf("ScoreFrameP%d", p + 1));
      LOAD_ALL_COMMANDS_AND_SET_XY(m_sprHighScoreFrame[p]);
      this->AddChild(m_sprHighScoreFrame[p]);
    }

    m_textHighScore[p].SetName(ssprintf("ScoreP%d", p + 1));
    m_textHighScore[p].LoadFromFont(GetThemePathF(m_sName, "score"));
    LOAD_ALL_COMMANDS_AND_SET_XY(m_textHighScore[p]);
    this->AddChild(&m_textHighScore[p]);
  }

  RageSoundLoadParams SoundParams;
  SoundParams.m_bSupportPan = true;

  LoadSoundIfPathPresent(m_soundStart, GetThemePathS(m_sName, "start"));
  LoadSoundIfPathPresent(
      m_soundDifficultyEasier,
      GetThemePathS(m_sName, "difficulty easier"),
      false,
      &SoundParams);
  LoadSoundIfPathPresent(
      m_soundDifficultyHarder,
      GetThemePathS(m_sName, "difficulty harder"),
      false,
      &SoundParams);
  LoadSoundIfPathPresent(
      m_soundOptionsChange, GetThemePathS(m_sName, "options"));
  LoadSoundIfPathPresent(m_soundLocked, GetThemePathS(m_sName, "locked"));

  this->SortByDrawOrder();
}

void ScreenSelectMusic::BeginScreen() {
  m_ScreenStartedLoadingAt.Touch();
  m_timerIdleComment.GetDeltaTime();
  ResetAssetRequestState();
  m_sSongAwaitingDeletionDir.clear();
  m_sSongAwaitingDeletionTitle.clear();

  if (GAMESTATE == nullptr) {
    WarnSelectMusic("ScreenSelectMusic opened without GAMESTATE.");
    return;
  }

  if (CommonMetrics::AUTO_SET_STYLE) {
    GAMESTATE->SetCompatibleStylesForPlayers();
  }

  if (GAMESTATE->GetCurrentStyle(PLAYER_INVALID) == nullptr) {
    LuaHelpers::ReportScriptError(
        "The Style has not been set.  A theme must set the Style before "
        "loading ScreenSelectMusic.");
    // Instead of crashing, set the first compatible style.
    std::vector<StepsType> vst;
    if (GAMEMAN != nullptr && GAMESTATE->m_pCurGame != nullptr) {
      GAMEMAN->GetStepsTypesForGame(GAMESTATE->m_pCurGame, vst);
    }
    const Style* pStyle =
        (GAMEMAN == nullptr || GAMESTATE->m_pCurGame == nullptr || vst.empty())
            ? nullptr
            : GAMEMAN->GetFirstCompatibleStyle(
                  GAMESTATE->m_pCurGame, GAMESTATE->GetNumSidesJoined(),
                  vst[0]);
    if (pStyle == nullptr) {
      WarnSelectMusic(
          "No compatible style found for ScreenSelectMusic; continuing without "
          "changing style.");
    } else {
      GAMESTATE->SetCurrentStyle(pStyle, PLAYER_INVALID);
    }
  }

  if (GAMESTATE->m_PlayMode == PlayMode_Invalid) {
    // Instead of crashing here, let's just set the PlayMode to regular
    GAMESTATE->m_PlayMode.Set(PLAY_MODE_REGULAR);
    if (LOG != nullptr) {
      LOG->Trace("PlayMode not set, setting as regular.");
    }
  }
  FOREACH_ENUM(PlayerNumber, pn) {
    if (GAMESTATE->IsHumanPlayer(pn)) {
      continue;
    }
    if (m_sprHighScoreFrame[pn].IsLoaded()) {
      m_sprHighScoreFrame[pn]->SetVisible(false);
    }
    m_textHighScore[pn].SetVisible(false);
  }

  OPTIONS_MENU_AVAILABLE.Load(m_sName, "OptionsMenuAvailable");
  PlayCommand("Mods");
  m_MusicWheel.BeginScreen();

  m_SelectionState = SelectionState_SelectingSong;
  ZERO(m_bStepsChosen);
  m_bGoToOptions = false;
  m_bAllowOptionsMenu = m_bAllowOptionsMenuRepeat = false;
  ZERO(m_iSelection);
  FOREACH_PlayerNumber(pn) {
    m_CanOpenOptionsList[pn].Touch();
  }

  if (USE_OPTIONS_LIST) {
    FOREACH_PlayerNumber(pn) m_OptionsList[pn].Reset();
  }

  AfterMusicChange();

  if (SOUND != nullptr) {
    SOUND->PlayOnceFromAnnouncer("select music intro");
  }

  ScreenWithMenuElements::BeginScreen();
}

ScreenSelectMusic::~ScreenSelectMusic() {
  if (LOG != nullptr) {
    LOG->Trace("ScreenSelectMusic::~ScreenSelectMusic()");
  }
  m_BackgroundLoader.Abort();
  m_sprCDTitleFront.UnloadTexture();
  m_sprCDTitleBack.UnloadTexture();
  m_TexturePreload.UnloadAll();
  if (IMAGECACHE != nullptr) {
    IMAGECACHE->Undemand("Banner");
  }
  ResetAssetRequestState();
}

void ScreenSelectMusic::ResetAssetRequestState() {
  m_bCDTitleWaiting = false;
  m_bBannerWaiting = false;
  m_bSampleMusicWaiting = false;
  m_sCDTitlePath.clear();
  m_sBannerPath.clear();
  m_bWantFallbackCdTitle = false;
}

void ScreenSelectMusic::SuspendPreviewForPrompt() {
  m_bPreviewSuspendedForPrompt = true;
  ResetAssetRequestState();
  m_BackgroundLoader.Abort();
  if (SOUND != nullptr) {
    SOUND->StopMusic();
  }
  m_MusicWheel.Move(0);
}

// If bForce is true, the next request will be started even if it might cause a
// skip.
void ScreenSelectMusic::CheckBackgroundRequests(bool bForce) {
  if (m_bPreviewSuspendedForPrompt) {
    return;
  }

  if (m_bCDTitleWaiting) {
    // The CDTitle is normally very small, so we don't bother waiting to display
    // it.
    std::string sPath;
    if (!m_BackgroundLoader.IsCacheFileFinished(m_sCDTitlePath, sPath)) {
      return;
    }

    m_bCDTitleWaiting = false;

    std::string sCDTitlePath = sPath;

    if (sCDTitlePath.empty() || !IsAFile(sCDTitlePath)) {
      sCDTitlePath =
          m_bWantFallbackCdTitle ? m_sFallbackCDTitlePath : std::string("");
    }

    if (!sCDTitlePath.empty()) {
      if (TEXTUREMAN != nullptr) {
        TEXTUREMAN->DisableOddDimensionWarning();
      }
      m_sprCDTitleFront.Load(sCDTitlePath);
      m_sprCDTitleBack.Load(sCDTitlePath);
      if (TEXTUREMAN != nullptr) {
        TEXTUREMAN->EnableOddDimensionWarning();
      }
    }

    m_BackgroundLoader.FinishedWithCachedFile(m_sCDTitlePath);
  }

  /* Loading the rest can cause small skips, so don't do it until the wheel
   * settles. Do load if we're transitioning out, though, so we don't miss
   * starting the music for the options screen if a song is selected quickly.
   * Also, don't do this if the wheel is locked, since we're just bouncing
   * around after selecting TYPE_RANDOM, and it'll take a while before the wheel
   * will settle. */
  if (!m_MusicWheel.IsSettled() && !m_MusicWheel.WheelIsLocked() && !bForce) {
    return;
  }

  if (m_bBannerWaiting) {
    if (m_Banner.GetTweenTimeLeft() > 0) {
      return;
    }

    std::string sPath;
    bool bFreeCache = false;
    if (TEXTUREMAN != nullptr &&
        TEXTUREMAN->IsTextureRegistered(
            Sprite::SongBannerTexture(m_sBannerPath))) {
      /* If the file is already loaded into a texture, it's finished,
       * and we only do this to honor the HighQualTime value. */
      sPath = m_sBannerPath;
    } else {
      if (!m_BackgroundLoader.IsCacheFileFinished(m_sBannerPath, sPath)) {
        return;
      }
      bFreeCache = true;
    }

    m_bBannerWaiting = false;
    m_Banner.Load(sPath, true);

    if (bFreeCache) {
      m_BackgroundLoader.FinishedWithCachedFile(m_sBannerPath);
    }
  }

  // Nothing else is going.  Start the music, if we haven't yet.
  if (m_bSampleMusicWaiting) {
    if (m_ScreenStartedLoadingAt.Ago() <
        SanitizeMetricSeconds(SAMPLE_MUSIC_DELAY_INIT.GetValue())) {
      return;
    }

    if (m_bPreviewDisabled) {
      m_bPreviewDisabled = false;
      m_bSampleMusicWaiting = false;
      return;
    }

    // Don't start the music sample when moving fast.
    if (m_StartedLoadingAt.Ago() <
            SanitizeMetricSeconds(SAMPLE_MUSIC_DELAY.GetValue()) &&
        !bForce) {
      return;
    }

    m_bSampleMusicWaiting = false;
    StartSampleMusicPreviewNow();
  }
}

void ScreenSelectMusic::StartSampleMusicPreviewNow() {
  if (SOUND == nullptr || m_sSampleMusicToPlay.empty()) {
    return;
  }

  GameSoundManager::PlayMusicParams PlayParams;
  PlayParams.sFile = HandleLuaMusicFile(m_sSampleMusicToPlay);
  PlayParams.pTiming = m_pSampleMusicTimingData;
  PlayParams.bForceLoop = SAMPLE_MUSIC_LOOPS;
  PlayParams.fStartSecond = SanitizeMetricSeconds(m_fSampleStartSeconds);
  PlayParams.fLengthSeconds = SanitizeSampleLength(m_fSampleLengthSeconds);
  PlayParams.fFadeOutLengthSeconds =
      SanitizeMetricSeconds(SAMPLE_MUSIC_FADE_OUT_SECONDS.GetValue());
  PlayParams.bAlignBeat = ALIGN_MUSIC_BEATS;
  PlayParams.bApplyMusicRate = true;

  GameSoundManager::PlayMusicParams FallbackMusic;
  FallbackMusic.sFile = m_sLoopMusicPath;
  FallbackMusic.fFadeInLengthSeconds =
      SanitizeMetricSeconds(SAMPLE_MUSIC_FALLBACK_FADE_IN_SECONDS.GetValue());
  FallbackMusic.bAlignBeat = ALIGN_MUSIC_BEATS;

  SOUND->PlayMusic(PlayParams, FallbackMusic);
}

void ScreenSelectMusic::Update(float fDeltaTime) {
  if (!IsTransitioning()) {
    const float idle_seconds =
        SanitizeMetricSeconds(IDLE_COMMENT_SECONDS.GetValue(), -1.0f);
    if (idle_seconds > 0 && m_timerIdleComment.Ago() >= idle_seconds) {
      if (SOUND != nullptr) {
        SOUND->PlayOnceFromAnnouncer(m_sName + " IdleComment");
      }
      m_timerIdleComment.GetDeltaTime();
    }
  }

  ScreenWithMenuElements::Update(fDeltaTime);

  CheckBackgroundRequests(false);
}

bool ScreenSelectMusic::Input(const InputEventPlus& input) {
  // HACK: This screen eats mouse inputs if we don't check for them first.
  bool mouse_evt = false;
  for (int i = MOUSE_LEFT; i <= MOUSE_WHEELDOWN; i++) {
    if (input.DeviceI == DeviceInput(DEVICE_MOUSE, (DeviceButton)i)) {
      mouse_evt = true;
    }
  }
  if (mouse_evt && !(m_SelectionState == SelectionState_Finalized &&
                     input.MenuI == GAME_BUTTON_START)) {
    return ScreenWithMenuElements::Input(input);
  }
  //	LOG->Trace( "ScreenSelectMusic::Input()" );

  // reset announcer timer
  m_timerIdleComment.GetDeltaTime();

  // debugging?
  // I just like being able to see untransliterated titles occasionally.
  if (input.DeviceI.device == DEVICE_KEYBOARD &&
      input.DeviceI.button == KEY_F9) {
    if (input.type != IET_FIRST_PRESS) {
      return false;
    }
    if (PREFSMAN == nullptr) {
      return false;
    }
    PREFSMAN->m_bShowNativeLanguage.Set(!PREFSMAN->m_bShowNativeLanguage);
    BroadcastSelectMusic("DisplayLanguageChanged");
    m_MusicWheel.RebuildWheelItems();
    return true;
  }

  if (!IsTransitioning() && m_SelectionState != SelectionState_Finalized) {
    bool bHoldingCtrl =
        INPUTFILTER != nullptr &&
        (INPUTFILTER->IsBeingPressed(DeviceInput(DEVICE_KEYBOARD, KEY_LCTRL)) ||
         INPUTFILTER->IsBeingPressed(DeviceInput(DEVICE_KEYBOARD, KEY_RCTRL)));

    bool holding_shift =
        INPUTFILTER != nullptr &&
        (INPUTFILTER->IsBeingPressed(
             DeviceInput(DEVICE_KEYBOARD, KEY_LSHIFT)) ||
         INPUTFILTER->IsBeingPressed(DeviceInput(DEVICE_KEYBOARD, KEY_RSHIFT)));

    wchar_t c = INPUTMAN == nullptr
                    ? 0
                    : INPUTMAN->DeviceInputToChar(input.DeviceI, false);
    MakeUpper(&c, 1);

    if (holding_shift && bHoldingCtrl && c == 'R' && m_MusicWheel.IsSettled()) {
      // Reload the currently selected song. -Kyz
      Song* to_reload = m_MusicWheel.GetSelectedSong();
      if (to_reload) {
        if (to_reload->ReloadFromSongDir()) {
          // Refresh wheel item on success so that users can see the updates
          // immediately without needing to move the wheel.
          m_MusicWheel.ReloadSongList();
        }
        return true;
      }
    } else if (bHoldingCtrl && (c >= 'A') && (c <= 'Z')) {
      // Only allow changing the sort order if the wheel is not locked
      // and we're not in course mode. -aj
      if (GAMESTATE != nullptr && !m_MusicWheel.WheelIsLocked() &&
          !GAMESTATE->IsCourseMode()) {
        SortOrder so = GAMESTATE->m_SortOrder;
        // When in Artist sort, this means first letter of the artist.
        // Otherwise, if not in Title sort already, switch to Title sort.
        if (so != SORT_ARTIST) {
          so = SORT_TITLE;
        }

        GAMESTATE->m_PreferredSortOrder = so;
        GAMESTATE->m_SortOrder.Set(so);
        // Odd, changing the sort order requires us to call SetOpenSection more
        // than once
        m_MusicWheel.ChangeSort(so);
        m_MusicWheel.SetOpenSection(ssprintf("%c", c));

        m_MusicWheel.SelectSection(ssprintf("%c", c));
        m_MusicWheel.ChangeSort(so);
        m_MusicWheel.SetOpenSection(ssprintf("%c", c));
        AfterMusicChange();
        return true;
      }
    } else if (
        input.DeviceI.device == DEVICE_KEYBOARD && bHoldingCtrl &&
        input.DeviceI.button == KEY_BACK && input.type == IET_FIRST_PRESS &&
        m_MusicWheel.IsSettled()) {
      // Keyboard shortcut to delete a song from disk (ctrl + backspace)
      Song* songToDelete = m_MusicWheel.GetSelectedSong();
      if (songToDelete && PREFSMAN != nullptr &&
          PREFSMAN->m_bAllowSongDeletion.Get()) {
        const std::string deleteDir = songToDelete->GetSongDir();
        if (!IsSafeSongDeletionDirectory(deleteDir)) {
          WarnSelectMusic(
              "Refused to prompt deletion for unsafe song directory '%s'.",
              deleteDir.c_str());
          return true;
        }
        SuspendPreviewForPrompt();
        m_sSongAwaitingDeletionDir = NormalizeVirtualDirectory(deleteDir);
        m_sSongAwaitingDeletionTitle = songToDelete->m_sMainTitle;
        ScreenPrompt::Prompt(
            SM_ConfirmDeleteSong,
            ssprintf(
                PERMANENTLY_DELETE.GetValue().c_str(),
                m_sSongAwaitingDeletionTitle.c_str(),
                m_sSongAwaitingDeletionDir.c_str()),
            PROMPT_YES_NO);
        return true;
      }
    }
  }

  if (!input.GameI.IsValid()) {
    return false;  // don't care
  }

  const bool valid_player = IsValidPlayer(input.pn);
  if (GAMESTATE == nullptr) {
    return false;
  }

  // Handle late joining
  // If the other player is allowed to join on the extra stage, then the
  // summary screen will crash on invalid stage stats. -Kyz
  if (m_SelectionState != SelectionState_Finalized &&
      input.MenuI == GAME_BUTTON_START && input.type == IET_FIRST_PRESS &&
      !GAMESTATE->IsAnExtraStage() && valid_player &&
      GAMESTATE->JoinInput(input.pn)) {
    return true;  // don't handle this press again below
  }

  if (!valid_player || !GAMESTATE->IsHumanPlayer(input.pn)) {
    return false;
  }

  // Check for "Press START again for options" button press
  if (m_SelectionState == SelectionState_Finalized &&
      input.MenuI == GAME_BUTTON_START && input.type != IET_RELEASE &&
      OPTIONS_MENU_AVAILABLE.GetValue()) {
    if (m_bGoToOptions) {
      return false;  // got it already
    }
    if (!m_bAllowOptionsMenu) {
      return false;  // not allowed
    }

    if (!m_bAllowOptionsMenuRepeat && input.type == IET_REPEAT) {
      return false;  // not allowed yet
    }

    m_bGoToOptions = true;
    if (PLAY_SOUND_ON_ENTERING_OPTIONS_MENU) {
      PlaySoundIfLoaded(m_soundStart);
    }
    this->PlayCommand("ShowEnteringOptions");

    // Re-queue SM_BeginFadingOut, since ShowEnteringOptions may have
    // short-circuited animations.
    this->ClearMessageQueue(SM_BeginFadingOut);
    this->PostScreenMessage(SM_BeginFadingOut, this->GetTweenTimeLeft());

    return true;
  }

  if (IsTransitioning()) {
    return false;  // ignore
  }

  // Handle unselect steps
  // xxx: select button could conflict with OptionsList here -aj
  if (m_SelectionState == SelectionState_SelectingSteps &&
      m_bStepsChosen[input.pn] && input.MenuI == GAME_BUTTON_SELECT &&
      input.type == IET_FIRST_PRESS) {
    Message msg("StepsUnchosen");
    msg.SetParam("Player", input.pn);
    BroadcastSelectMusic(msg);
    m_bStepsChosen[input.pn] = false;
    return true;
  }

  if (m_SelectionState == SelectionState_Finalized ||
      m_bStepsChosen[input.pn]) {
    return false;  // ignore
  }

  if (USE_PLAYER_SELECT_MENU) {
    if (input.type == IET_RELEASE && input.MenuI == GAME_BUTTON_SELECT &&
        SCREENMAN != nullptr && !SELECT_MENU_NAME.GetValue().empty()) {
      SCREENMAN->AddNewScreenToTop(SELECT_MENU_NAME, SM_BackFromPlayerOptions);
    }
  }

  // handle OptionsList input
  if (USE_OPTIONS_LIST) {
    PlayerNumber pn = input.pn;
    if (IsValidPlayer(pn)) {
      if (m_OptionsList[pn].IsOpened()) {
        return m_OptionsList[pn].Input(input);
      } else {
        if (input.type == IET_RELEASE && input.MenuI == GAME_BUTTON_SELECT &&
            m_bAcceptSelectRelease[pn]) {
          m_OptionsList[pn].Open();
        }
      }
    }
  }

  if (input.MenuI == GAME_BUTTON_SELECT && input.type != IET_REPEAT) {
    m_bAcceptSelectRelease[input.pn] = (input.type == IET_FIRST_PRESS);
  }

  if (SELECT_MENU_AVAILABLE && input.MenuI == GAME_BUTTON_SELECT &&
      input.type != IET_REPEAT) {
    UpdateSelectButton(input.pn, input.type == IET_FIRST_PRESS);
  }

  if (SELECT_MENU_AVAILABLE && m_bSelectIsDown[input.pn]) {
    if (input.type == IET_FIRST_PRESS && SELECT_MENU_CHANGES_DIFFICULTY) {
      switch (input.MenuI) {
        case GAME_BUTTON_LEFT:
          ChangeSteps(input.pn, -1);
          m_bAcceptSelectRelease[input.pn] = false;
          break;
        case GAME_BUTTON_RIGHT:
          ChangeSteps(input.pn, +1);
          m_bAcceptSelectRelease[input.pn] = false;
          break;
        case GAME_BUTTON_START:
          m_bAcceptSelectRelease[input.pn] = false;
          if (MODE_MENU_AVAILABLE) {
            m_MusicWheel.NextSort();
          } else {
            PlaySoundIfLoaded(m_soundLocked);
          }
          break;
        default:
          break;
      }
    }
    if (input.type == IET_FIRST_PRESS && input.MenuI != GAME_BUTTON_SELECT) {
      Message msg("SelectMenuInput");
      msg.SetParam("Player", input.pn);
      msg.SetParam(
          "Button",
          INPUTMAPPER == nullptr || INPUTMAPPER->GetInputScheme() == nullptr
              ? std::string()
              : GameButtonToString(INPUTMAPPER->GetInputScheme(), input.MenuI));
      BroadcastSelectMusic(msg);
      m_bAcceptSelectRelease[input.pn] = false;
    }
    if (input.type == IET_FIRST_PRESS) {
      m_CanOpenOptionsList[input.pn].Touch();
    }
    if (m_CanOpenOptionsList[input.pn].Ago() >
        SanitizeMetricSeconds(OPTIONS_LIST_TIMEOUT.GetValue())) {
      m_bAcceptSelectRelease[input.pn] = false;
    }
    return true;
  }

  if (m_SelectionState == SelectionState_SelectingSong &&
      (input.MenuI == m_GameButtonNextSong ||
       input.MenuI == m_GameButtonPreviousSong ||
       input.MenuI == GAME_BUTTON_SELECT)) {
    {
      // If we're rouletting, hands off.
      if (m_MusicWheel.IsRouletting()) {
        return false;
      }

      bool bLeftIsDown = false;
      bool bRightIsDown = false;

      FOREACH_HumanPlayer(p) {
        if (USE_OPTIONS_LIST && m_OptionsList[p].IsOpened()) {
          continue;
        }
        if (SELECT_MENU_AVAILABLE && INPUTMAPPER != nullptr &&
            INPUTMAPPER->IsBeingPressed(GAME_BUTTON_SELECT, p)) {
          continue;
        }

        bLeftIsDown |= INPUTMAPPER != nullptr &&
                       IsValidButton(m_GameButtonPreviousSong) &&
                       INPUTMAPPER->IsBeingPressed(m_GameButtonPreviousSong, p);
        bRightIsDown |= INPUTMAPPER != nullptr &&
                        IsValidButton(m_GameButtonNextSong) &&
                        INPUTMAPPER->IsBeingPressed(m_GameButtonNextSong, p);
      }

      bool bBothDown = bLeftIsDown && bRightIsDown;
      bool bNeitherDown = !bLeftIsDown && !bRightIsDown;

      if (bNeitherDown) {
        // Both buttons released.
        m_MusicWheel.Move(0);
      } else if (bBothDown) {
        m_MusicWheel.Move(0);
        if (input.type == IET_FIRST_PRESS) {
          if (input.MenuI == m_GameButtonPreviousSong) {
            m_MusicWheel.ChangeMusicUnlessLocked(-1);
          } else if (input.MenuI == m_GameButtonNextSong) {
            m_MusicWheel.ChangeMusicUnlessLocked(+1);
          }
        }
      } else if (bLeftIsDown) {
        if (input.type != IET_RELEASE) {
          BroadcastSelectMusic("PreviousSong");
          m_MusicWheel.Move(-1);
        }
      } else if (bRightIsDown) {
        if (input.type != IET_RELEASE) {
          BroadcastSelectMusic("NextSong");
          m_MusicWheel.Move(+1);
        }
      } else {
        WarnSelectMusic(
            "ScreenSelectMusic L/R keys reached an impossible state.");
      }

      // Reset the repeat timer when the button is released.
      // This fixes jumping when you release Left and Right after entering the
      // sort code at the same if L & R aren't released at the exact same time.
      if (input.type == IET_RELEASE) {
        if (INPUTMAPPER != nullptr) {
          if (IsValidButton(m_GameButtonPreviousSong)) {
            INPUTMAPPER->ResetKeyRepeat(m_GameButtonPreviousSong, input.pn);
          }
          if (IsValidButton(m_GameButtonNextSong)) {
            INPUTMAPPER->ResetKeyRepeat(m_GameButtonNextSong, input.pn);
          }
        }
      }
    }
  }

  // To allow changing steps with gamebuttons, NOT WITH THE GODDAMN CODEDETECTOR
  // yeah, wanted this since a while ago... -DaisuMaster
  if (CHANGE_STEPS_WITH_GAME_BUTTONS) {
    if (input.type == IET_FIRST_PRESS &&
        m_SelectionState == SelectionState_SelectingSong) {
      if (input.MenuI == m_GameButtonPreviousDifficulty) {
        if (GAMESTATE->IsAnExtraStageAndSelectionLocked()) {
          PlaySoundIfLoaded(m_soundLocked);
        } else {
          ChangeSteps(input.pn, -1);
        }
      } else if (input.MenuI == m_GameButtonNextDifficulty) {
        if (GAMESTATE->IsAnExtraStageAndSelectionLocked()) {
          PlaySoundIfLoaded(m_soundLocked);
        } else {
          ChangeSteps(input.pn, +1);
        }
      }
    }
  }

  // Actually I don't like to just copy and paste code because it may go
  // wrong if something goes overlooked -DaisuMaster
  if (CHANGE_GROUPS_WITH_GAME_BUTTONS) {
    if (input.type == IET_FIRST_PRESS &&
        m_SelectionState == SelectionState_SelectingSong) {
      if (input.MenuI == m_GameButtonPreviousGroup) {
        if (GAMESTATE->IsAnExtraStageAndSelectionLocked()) {
          PlaySoundIfLoaded(m_soundLocked);
        } else {
          std::string sNewGroup = m_MusicWheel.JumpToPrevGroup();
          m_MusicWheel.SelectSection(sNewGroup);
          m_MusicWheel.SetOpenSection(sNewGroup);
          BroadcastSelectMusic("PreviousGroup");
          AfterMusicChange();
        }
      } else if (input.MenuI == m_GameButtonNextGroup) {
        if (GAMESTATE->IsAnExtraStageAndSelectionLocked()) {
          PlaySoundIfLoaded(m_soundLocked);
        } else {
          std::string sNewGroup = m_MusicWheel.JumpToNextGroup();
          m_MusicWheel.SelectSection(sNewGroup);
          m_MusicWheel.SetOpenSection(sNewGroup);
          BroadcastSelectMusic("NextGroup");
          AfterMusicChange();
        }
      }
    }
  }

  // two part confirms only means we can actually change songs here,
  // so we need some hackery. -aj
  if (TWO_PART_CONFIRMS_ONLY) {
    if (m_SelectionState == SelectionState_SelectingSteps) {
      if (input.MenuI == m_GameButtonPreviousSong) {
        if (GAMESTATE->IsAnExtraStageAndSelectionLocked()) {
          PlaySoundIfLoaded(m_soundLocked);
        } else {
          m_SelectionState = SelectionState_SelectingSong;
          BroadcastSelectMusic("TwoPartConfirmCanceled");
          BroadcastSelectMusic("PreviousSong");
          m_MusicWheel.ChangeMusicUnlessLocked(-1);
        }
      } else if (input.MenuI == m_GameButtonNextSong) {
        if (GAMESTATE->IsAnExtraStageAndSelectionLocked()) {
          PlaySoundIfLoaded(m_soundLocked);
        } else {
          m_SelectionState = SelectionState_SelectingSong;
          BroadcastSelectMusic("TwoPartConfirmCanceled");
          BroadcastSelectMusic("NextSong");
          m_MusicWheel.ChangeMusicUnlessLocked(+1);
        }
      }
      // added an entry for difficulty change with gamebuttons -DaisuMaster
      else if (input.MenuI == m_GameButtonPreviousDifficulty) {
        if (GAMESTATE->IsAnExtraStageAndSelectionLocked()) {
          PlaySoundIfLoaded(m_soundLocked);
        } else {
          m_SelectionState = SelectionState_SelectingSong;
          BroadcastSelectMusic("TwoPartConfirmCanceled");
          ChangeSteps(input.pn, -1);
        }
      } else if (input.MenuI == m_GameButtonNextDifficulty) {
        if (GAMESTATE->IsAnExtraStageAndSelectionLocked()) {
          PlaySoundIfLoaded(m_soundLocked);
        } else {
          m_SelectionState = SelectionState_SelectingSong;
          BroadcastSelectMusic("TwoPartConfirmCanceled");
          ChangeSteps(input.pn, +1);
        }
      }
      // added also for groupchanges
      else if (input.MenuI == m_GameButtonPreviousGroup) {
        if (GAMESTATE->IsAnExtraStageAndSelectionLocked()) {
          PlaySoundIfLoaded(m_soundLocked);
        } else {
          std::string sNewGroup = m_MusicWheel.JumpToPrevGroup();
          m_MusicWheel.SelectSection(sNewGroup);
          m_MusicWheel.SetOpenSection(sNewGroup);
          BroadcastSelectMusic("TwoPartConfirmCanceled");
          BroadcastSelectMusic("PreviousGroup");
          AfterMusicChange();
        }
      } else if (input.MenuI == m_GameButtonNextGroup) {
        if (GAMESTATE->IsAnExtraStageAndSelectionLocked()) {
          PlaySoundIfLoaded(m_soundLocked);
        } else {
          std::string sNewGroup = m_MusicWheel.JumpToNextGroup();
          m_MusicWheel.SelectSection(sNewGroup);
          m_MusicWheel.SetOpenSection(sNewGroup);
          BroadcastSelectMusic("TwoPartConfirmCanceled");
          BroadcastSelectMusic("NextGroup");
          AfterMusicChange();
        }
      }
    }
  } else {
    if (m_SelectionState == SelectionState_SelectingSteps &&
        input.type == IET_FIRST_PRESS && !m_bStepsChosen[input.pn]) {
      if (input.MenuI == m_GameButtonPreviousDifficulty ||
          input.MenuI == m_GameButtonNextDifficulty) {
        if (input.MenuI == m_GameButtonPreviousDifficulty) {
          if (GAMESTATE->IsAnExtraStageAndSelectionLocked()) {
            PlaySoundIfLoaded(m_soundLocked);
          } else {
            ChangeSteps(input.pn, -1);
          }
        } else if (input.MenuI == m_GameButtonNextDifficulty) {
          if (GAMESTATE->IsAnExtraStageAndSelectionLocked()) {
            PlaySoundIfLoaded(m_soundLocked);
          } else {
            ChangeSteps(input.pn, +1);
          }
        }
      }
      // This should not be MENUP or MENUDOWN, different games use different
      // buttons to cancel.
      else if (
          input.MenuI == m_GameButtonCancelTwoPart1 ||
          input.MenuI ==
              m_GameButtonCancelTwoPart2)  // &&
                                           // TWO_PART_DESELECTS_WITH_MENUUPDOWN
      {
        if (GAMESTATE->IsAnExtraStageAndSelectionLocked()) {
          PlaySoundIfLoaded(m_soundLocked);
        } else {
          // XXX: should this be called "TwoPartCancelled"?
          float fSeconds =
              HasUsableTimer(m_MenuTimer) ? m_MenuTimer->GetSeconds() : 0.0f;
          if (fSeconds > 10) {
            Message msg("SongUnchosen");
            msg.SetParam("Player", input.pn);
            BroadcastSelectMusic(msg);
            // unset all steps
            FOREACH_ENUM(PlayerNumber, p)
            m_bStepsChosen[p] = false;
            m_SelectionState = SelectionState_SelectingSong;
          }
        }
      }
    }
  }

  if (input.type == IET_FIRST_PRESS && DetectCodes(input)) {
    return true;
  }

  return ScreenWithMenuElements::Input(input);
}

bool ScreenSelectMusic::DetectCodes(const InputEventPlus& input) {
  if (GAMESTATE == nullptr || !IsValidPlayer(input.pn)) {
    return false;
  }

  if (CodeDetector::EnteredPrevSteps(input.GameI.controller) &&
      !CHANGE_STEPS_WITH_GAME_BUTTONS) {
    if (GAMESTATE->IsAnExtraStageAndSelectionLocked()) {
      PlaySoundIfLoaded(m_soundLocked);
    } else {
      ChangeSteps(input.pn, -1);
    }
  } else if (
      CodeDetector::EnteredNextSteps(input.GameI.controller) &&
      !CHANGE_STEPS_WITH_GAME_BUTTONS) {
    if (GAMESTATE->IsAnExtraStageAndSelectionLocked()) {
      PlaySoundIfLoaded(m_soundLocked);
    } else {
      ChangeSteps(input.pn, +1);
    }
  } else if (CodeDetector::EnteredModeMenu(input.GameI.controller)) {
    if (MODE_MENU_AVAILABLE) {
      m_MusicWheel.ChangeSort(SORT_MODE_MENU);
    } else {
      PlaySoundIfLoaded(m_soundLocked);
    }
  } else if (CodeDetector::EnteredNextSort(input.GameI.controller)) {
    if (GAMESTATE->IsAnExtraStageAndSelectionLocked() ||
        m_MusicWheel.WheelIsLocked() || m_MusicWheel.IsRouletting()) {
      PlaySoundIfLoaded(m_soundLocked);
    } else if (!GAMESTATE->IsCourseMode()) {
      // Only change sorts in non-course mode
      m_MusicWheel.NextSort();
    }
  } else if (
      !GAMESTATE->IsAnExtraStageAndSelectionLocked() &&
      !m_MusicWheel.WheelIsLocked() && !m_MusicWheel.IsRouletting() &&
      CodeDetector::DetectAndAdjustMusicOptions(input.GameI.controller)) {
    PlaySoundIfLoaded(m_soundOptionsChange);

    Message msg("PlayerOptionsChanged");
    msg.SetParam("PlayerNumber", input.pn);
    BroadcastSelectMusic(msg);

    BroadcastSelectMusic("SongOptionsChanged");
  } else if (
      CodeDetector::EnteredNextGroup(input.GameI.controller) &&
      !CHANGE_GROUPS_WITH_GAME_BUTTONS) {
    if (GAMESTATE->IsAnExtraStageAndSelectionLocked() ||
        m_MusicWheel.WheelIsLocked() || m_MusicWheel.IsRouletting()) {
      PlaySoundIfLoaded(m_soundLocked);
    } else {
      std::string sNewGroup = m_MusicWheel.JumpToNextGroup();
      m_MusicWheel.SelectSection(sNewGroup);
      m_MusicWheel.SetOpenSection(sNewGroup);
      BroadcastSelectMusic("NextGroup");
      AfterMusicChange();
    }
  } else if (
      CodeDetector::EnteredPrevGroup(input.GameI.controller) &&
      !CHANGE_GROUPS_WITH_GAME_BUTTONS) {
    if (GAMESTATE->IsAnExtraStageAndSelectionLocked() ||
        m_MusicWheel.WheelIsLocked() || m_MusicWheel.IsRouletting()) {
      PlaySoundIfLoaded(m_soundLocked);
    } else {
      std::string sNewGroup = m_MusicWheel.JumpToPrevGroup();
      m_MusicWheel.SelectSection(sNewGroup);
      m_MusicWheel.SetOpenSection(sNewGroup);
      BroadcastSelectMusic("PreviousGroup");
      AfterMusicChange();
    }
  } else if (CodeDetector::EnteredCloseFolder(input.GameI.controller)) {
    if (GAMESTATE->IsAnExtraStageAndSelectionLocked() ||
        m_MusicWheel.WheelIsLocked() || m_MusicWheel.IsRouletting()) {
      PlaySoundIfLoaded(m_soundLocked);
    } else {
      std::string sCurSection = m_MusicWheel.GetSelectedSection();
      m_MusicWheel.SelectSection(sCurSection);
      m_MusicWheel.SetOpenSection("");
      AfterMusicChange();
    }
  } else {
    return false;
  }
  return true;
}

void ScreenSelectMusic::UpdateSelectButton(
    PlayerNumber pn, bool bSelectIsDown) {
  if (!SELECT_MENU_AVAILABLE || !CanChangeSong()) {
    bSelectIsDown = false;
  }

  if (!IsValidPlayer(pn)) {
    return;
  }

  if (m_bSelectIsDown[pn] != bSelectIsDown) {
    m_bSelectIsDown[pn] = bSelectIsDown;
    Message msg(bSelectIsDown ? "SelectMenuOpened" : "SelectMenuClosed");
    msg.SetParam("Player", pn);
    BroadcastSelectMusic(msg);
  }
}

void ScreenSelectMusic::ChangeSteps(PlayerNumber pn, int dir) {
  if (LOG != nullptr) {
    LOG->Trace("ScreenSelectMusic::ChangeSteps( %d, %d )", pn, dir);
  }

  if (GAMESTATE == nullptr || !IsValidPlayer(pn) ||
      !GAMESTATE->IsHumanPlayer(pn) || dir == 0) {
    return;
  }

  if (GAMESTATE->m_pCurSong) {
    if (m_vpSteps.empty()) {
      WarnSelectMusic(
          "ChangeSteps ignored because no playable steps are listed.");
      return;
    }
    m_iSelection[pn] += dir;
    if (WRAP_CHANGE_STEPS) {
      wrap(m_iSelection[pn], m_vpSteps.size());
    } else {
      if (rage_clamp(m_iSelection[pn], 0, int(m_vpSteps.size()) - 1)) {
        return;
      }
    }

    // the user explicity switched difficulties. Update the preferred Difficulty
    // and StepsType
    Steps* pSteps = m_vpSteps[m_iSelection[pn]];
    if (pSteps == nullptr) {
      WarnSelectMusic("ChangeSteps ignored a null Steps entry.");
      return;
    }
    GAMESTATE->ChangePreferredDifficultyAndStepsType(
        pn, pSteps->GetDifficulty(), pSteps->m_StepsType);
  } else if (GAMESTATE->m_pCurCourse) {
    if (m_vpTrails.empty()) {
      WarnSelectMusic(
          "ChangeSteps ignored because no playable trails are listed.");
      return;
    }
    m_iSelection[pn] += dir;
    if (WRAP_CHANGE_STEPS) {
      wrap(m_iSelection[pn], m_vpTrails.size());
    } else {
      if (rage_clamp(m_iSelection[pn], 0, int(m_vpTrails.size()) - 1)) {
        return;
      }
    }

    // the user explicity switched difficulties. Update the preferred Difficulty
    // and StepsType
    Trail* pTrail = m_vpTrails[m_iSelection[pn]];
    if (pTrail == nullptr) {
      WarnSelectMusic("ChangeSteps ignored a null Trail entry.");
      return;
    }
    GAMESTATE->ChangePreferredCourseDifficultyAndStepsType(
        pn, pTrail->m_CourseDifficulty, pTrail->m_StepsType);
  } else {
    // If we're showing multiple StepsTypes in the list, don't allow
    // changing the difficulty/StepsType when a non-Song, non-Course is
    // selected. Changing the preferred Difficulty and StepsType by
    // direction is complicated when multiple StepsTypes are being shown,
    // so we don't support it.
    if (CommonMetrics::AUTO_SET_STYLE) {
      return;
    }
    if (!GAMESTATE->ChangePreferredDifficulty(pn, dir)) {
      return;
    }
  }

  std::vector<PlayerNumber> vpns;
  FOREACH_HumanPlayer(p) {
    if (pn == p || GAMESTATE->DifficultiesLocked()) {
      m_iSelection[p] = m_iSelection[pn];
      vpns.push_back(p);
    }
  }
  AfterStepsOrTrailChange(vpns);

  float fBalance = GameSoundManager::GetPlayerBalance(pn);
  if (dir < 0) {
    m_soundDifficultyEasier.SetProperty("Pan", fBalance);
    PlaySoundIfLoaded(m_soundDifficultyEasier, true);
  } else {
    m_soundDifficultyHarder.SetProperty("Pan", fBalance);
    PlaySoundIfLoaded(m_soundDifficultyHarder, true);
  }
  GAMESTATE->ForceOtherPlayersToCompatibleSteps(pn);

  Message msg("ChangeSteps");
  msg.SetParam("Player", pn);
  msg.SetParam("Direction", dir);
  BroadcastSelectMusic(msg);
}

void ScreenSelectMusic::HandleMessage(const Message& msg) {
  if (m_bRunning && msg == Message_PlayerJoined && GAMESTATE != nullptr) {
    PlayerNumber master_pn = GAMESTATE->GetMasterPlayerNumber();
    // The current steps may no longer be playable. If one player has double
    // steps selected, they are no longer playable now that P2 has joined.

    // TODO: Invalidate the CurSteps only if they are no longer playable.
    // That way, after music change will clamp to the nearest in the
    // StepsDisplayList.
    if (IsValidPlayer(master_pn)) {
      GAMESTATE->m_pCurSteps[master_pn].SetWithoutBroadcast(nullptr);
    }
    FOREACH_ENUM(PlayerNumber, p)
    GAMESTATE->m_pCurSteps[p].SetWithoutBroadcast(nullptr);

    /* If a course is selected, it may no longer be playable.
     * Let MusicWheel know about the late join. */
    m_MusicWheel.PlayerJoined();

    AfterMusicChange();

    int iSel = 0;
    PlayerNumber pn;
    bool b = msg.GetParam("Player", pn);
    if (!b || !IsValidPlayer(pn)) {
      WarnSelectMusic("PlayerJoined message did not contain a valid player.");
      ScreenWithMenuElements::HandleMessage(msg);
      return;
    }

    // load player profiles
    if (GAMESTATE->HaveProfileToLoad()) {
      GAMESTATE->LoadProfiles(
          true);  // I guess you could always load edits here...
      if (SCREENMAN != nullptr) {
        SCREENMAN->ZeroNextUpdate();  // be kind, don't skip frames if you can
                                      // avoid it
      }
    }

    m_iSelection[pn] = iSel;
    if (GAMESTATE->IsCourseMode()) {
      Trail* pTrail = GetSelectedTrail(m_vpTrails, m_iSelection[pn]);
      GAMESTATE->m_pCurTrail[pn].Set(pTrail);
    } else {
      Steps* pSteps = GetSelectedSteps(m_vpSteps, m_iSelection[pn]);

      // handle changing rave difficulty on join
      if (GAMESTATE->m_PlayMode == PLAY_MODE_RAVE && IsValidPlayer(master_pn)) {
        pSteps = GetSelectedSteps(m_vpSteps, m_iSelection[master_pn]);
      }

      GAMESTATE->m_pCurSteps[pn].Set(pSteps);
    }
  }

  ScreenWithMenuElements::HandleMessage(msg);
}

void ScreenSelectMusic::HandleScreenMessage(const ScreenMessage SM) {
  if (SM == SM_AllowOptionsMenuRepeat) {
    m_bAllowOptionsMenuRepeat = true;
  } else if (SM == SM_MenuTimer) {
    if (m_MusicWheel.IsRouletting()) {
      MenuStart(InputEventPlus());
      if (HasUsableTimer(m_MenuTimer)) {
        m_MenuTimer->SetSeconds(
            SanitizeMetricSeconds(ROULETTE_TIMER_SECONDS.GetValue()));
        m_MenuTimer->Start();
      }
    } else if (
        DO_ROULETTE_ON_MENU_TIMER &&
        m_MusicWheel.GetSelectedSong() == nullptr &&
        m_MusicWheel.GetSelectedCourse() == nullptr) {
      m_MusicWheel.StartRoulette();
      if (HasUsableTimer(m_MenuTimer)) {
        m_MenuTimer->SetSeconds(
            SanitizeMetricSeconds(ROULETTE_TIMER_SECONDS.GetValue()));
        m_MenuTimer->Start();
      }
    } else {
      // Finish sort changing so that the wheel can respond immediately to
      // our request to choose random.
      m_MusicWheel.FinishChangingSorts();
      if (m_MusicWheel.GetSelectedSong() == nullptr &&
          m_MusicWheel.GetSelectedCourse() == nullptr) {
        m_MusicWheel.StartRandom();
      }

      MenuStart(InputEventPlus());
    }
    return;
  } else if (SM == SM_GoToPrevScreen) {
    /* We may have stray SM_SongChanged messages from the music wheel.
     * We can't handle them anymore, since the title menu (and attract
     * screens) reset the game state, so just discard them. */
    ClearMessageQueue();
  } else if (SM == SM_BeginFadingOut) {
    m_bAllowOptionsMenu = false;
    if (OPTIONS_MENU_AVAILABLE && !m_bGoToOptions) {
      this->PlayCommand("HidePressStartForOptions");
    }

    this->PostScreenMessage(SM_GoToNextScreen, this->GetTweenTimeLeft());
  } else if (SM == SM_GoToNextScreen) {
    if (!m_bGoToOptions) {
      if (SOUND != nullptr) {
        SOUND->StopMusic();
      }
    }
  } else if (SM == SM_SongChanged) {
    AfterMusicChange();
  } else if (SM == SM_SortOrderChanging)  // happens immediately
  {
    this->PlayCommand("SortChange");
  } else if (SM == SM_GainFocus) {
    CodeDetector::RefreshCacheItems(CODES);
  } else if (SM == SM_LoseFocus) {
    CodeDetector::RefreshCacheItems();  // reset for other screens
  } else if (SM == SM_ConfirmDeleteSong) {
    if (ScreenPrompt::s_LastAnswer == ANSWER_YES) {
      OnConfirmSongDeletion();
    } else {
      m_sSongAwaitingDeletionDir.clear();
      m_sSongAwaitingDeletionTitle.clear();
      m_bPreviewSuspendedForPrompt = false;
      // need to resume the song preview that was automatically paused
      m_MusicWheel.ChangeMusic(0);
    }
  } else if (SM == SM_ConfirmExit) {
    if (ScreenPrompt::s_LastAnswer == ANSWER_YES) {
      ConfirmedCancel(SM_GoToPrevScreen);
    } else {
      m_bPreviewSuspendedForPrompt = false;
      StartSampleMusicPreviewNow();
    }
  }

  ScreenWithMenuElements::HandleScreenMessage(SM);
}

bool ScreenSelectMusic::MenuStart(const InputEventPlus& input) {
  if (input.type != IET_FIRST_PRESS) {
    return false;
  }

  if (GAMESTATE == nullptr) {
    WarnSelectMusic("MenuStart ignored because GameState is unavailable.");
    return false;
  }

  const bool valid_player = IsValidPlayer(input.pn);
  const SelectionState previousSelectionState = m_SelectionState;

  /* If select is being pressed at the same time, this is probably an attempt
   * to change the sort, not to pick a song or difficulty. If it gets here,
   * the actual select press was probably hit during a tween and ignored.
   * Ignore it. */
  if (valid_player && INPUTMAPPER != nullptr &&
      INPUTMAPPER->IsBeingPressed(GAME_BUTTON_SELECT, input.pn)) {
    return false;
  }

  // Honor locked input for start presses.
  if (m_fLockInputSecs > 0) {
    return false;
  }

  switch (m_SelectionState) {
    case SelectionState_SelectingSong:
      // If false, we don't have a selection just yet.
      if (!m_MusicWheel.Select()) {
        return false;
      }

      // a song was selected
      if (m_MusicWheel.GetSelectedSong() != nullptr) {
        if (TWO_PART_CONFIRMS_ONLY &&
            SAMPLE_MUSIC_PREVIEW_MODE ==
                SampleMusicPreviewMode_StartToPreview) {
          // start playing the preview music.
          m_bSampleMusicWaiting = true;
          CheckBackgroundRequests(true);
        }

        Song* selected_song = m_MusicWheel.GetSelectedSong();
        const bool bIsNew =
            PROFILEMAN != nullptr && PROFILEMAN->IsSongNew(selected_song);
        bool bIsHard = false;
        FOREACH_HumanPlayer(p) {
          if (GAMESTATE->m_pCurSteps[p] &&
              GAMESTATE->m_pCurSteps[p]->GetMeter() >= HARD_COMMENT_METER) {
            bIsHard = true;
          }
        }

        // See if this song is a repeat.
        // If we're in event mode, only check the last five songs.
        bool bIsRepeat = false;
        int i = 0;
        if (STATSMAN != nullptr && GAMESTATE->IsEventMode()) {
          i = std::max(0, int(STATSMAN->m_vPlayedStageStats.size()) - 5);
        }
        for (; STATSMAN != nullptr &&
               i < (int)STATSMAN->m_vPlayedStageStats.size();
             ++i) {
          const auto& played_songs =
              STATSMAN->m_vPlayedStageStats[i].m_vpPlayedSongs;
          if (!played_songs.empty() && played_songs.back() == selected_song) {
            bIsRepeat = true;
          }
        }

        // Don't complain about repeats if the user didn't get to pick.
        if (GAMESTATE->IsAnExtraStageAndSelectionLocked()) {
          bIsRepeat = false;
        }

        if (SOUND != nullptr) {
          if (bIsRepeat) {
            SOUND->PlayOnceFromAnnouncer("select music comment repeat");
          } else if (bIsNew) {
            SOUND->PlayOnceFromAnnouncer("select music comment new");
          } else if (bIsHard) {
            SOUND->PlayOnceFromAnnouncer("select music comment hard");
          } else {
            SOUND->PlayOnceFromAnnouncer("select music comment general");
          }
        }

        /* If we're in event mode, we may have just played a course (putting
         * us in course mode). Make sure we're in a single song mode. */
        if (GAMESTATE->IsCourseMode()) {
          GAMESTATE->m_PlayMode.Set(PLAY_MODE_REGULAR);
        }
      } else if (m_MusicWheel.GetSelectedCourse() != nullptr) {
        if (SOUND != nullptr) {
          SOUND->PlayOnceFromAnnouncer("select course comment general");
        }

        Course* pCourse = m_MusicWheel.GetSelectedCourse();
        if (pCourse == nullptr) {
          WarnSelectMusic("Selected course disappeared during MenuStart.");
          return false;
        }
        GAMESTATE->m_PlayMode.Set(pCourse->GetPlayMode());

        // apply #LIVES
        if (pCourse->m_iLives != -1) {
          FOREACH_EnabledPlayer(pn) {
            if (GAMESTATE->m_pPlayerState[pn] == nullptr) {
              continue;
            }
            PO_GROUP_ASSIGN(
                GAMESTATE->m_pPlayerState[pn]->m_PlayerOptions, ModsLevel_Stage,
                m_LifeType, LifeType_Battery);
            PO_GROUP_ASSIGN(
                GAMESTATE->m_pPlayerState[pn]->m_PlayerOptions, ModsLevel_Stage,
                m_BatteryLives, pCourse->m_iLives);
          }
        }
        if (pCourse->GetCourseType() == COURSE_TYPE_SURVIVAL) {
          FOREACH_EnabledPlayer(pn) {
            if (GAMESTATE->m_pPlayerState[pn] == nullptr) {
              continue;
            }
            PO_GROUP_ASSIGN(
                GAMESTATE->m_pPlayerState[pn]->m_PlayerOptions, ModsLevel_Stage,
                m_LifeType, LifeType_Time);
          }
        }
      } else {
        // We haven't made a selection yet.
        return false;
      }
      // I believe this is for those who like pump pro. -aj
      BroadcastSelectMusic("SongChosen");

      break;

    case SelectionState_SelectingSteps: {
      PlayerNumber pn = input.pn;
      bool bInitiatedByMenuTimer = !valid_player;
      bool bAllOtherHumanPlayersDone = true;
      FOREACH_HumanPlayer(p) {
        if (p == pn) {
          continue;
        }
        bAllOtherHumanPlayersDone &= m_bStepsChosen[p];
      }

      bool bAllPlayersDoneSelectingSteps =
          bInitiatedByMenuTimer || bAllOtherHumanPlayersDone;
      if (TWO_PART_CONFIRMS_ONLY) {
        bAllPlayersDoneSelectingSteps = true;
      }

      /* TRICKY: if we have a Routine chart selected, we need to ensure
       * the following:
       * 1. Both players must select the same Routine steps.
       * 2. If the other player picks non-Routine steps, this player
       *    cannot pick Routine.
       * 3. If the other player picked Routine steps, and we pick
       *    non-Routine steps, the other player's steps must be unselected.
       * 4. If time runs out, and both players don't have the same Routine
       *    chart selected, we need to bump the player with a Routine
       *    chart selection to a playable chart.
       *    (Right now, we bump them to Beginner... Can we come up with
       *    something better?)
       */

      if (!GAMESTATE->IsCourseMode() && GAMESTATE->GetNumSidesJoined() == 2) {
        bool bSelectedRoutineSteps[NUM_PLAYERS], bAnySelectedRoutine = false;
        ZERO(bSelectedRoutineSteps);
        bool bSelectedSameSteps = GAMESTATE->m_pCurSteps[PLAYER_1] ==
                                  GAMESTATE->m_pCurSteps[PLAYER_2];

        FOREACH_HumanPlayer(p) {
          const Steps* pSteps = GAMESTATE->m_pCurSteps[p];
          if (pSteps == nullptr || GAMEMAN == nullptr) {
            bSelectedRoutineSteps[p] = false;
            continue;
          }
          const StepsTypeInfo& sti =
              GAMEMAN->GetStepsTypeInfo(pSteps->m_StepsType);

          bSelectedRoutineSteps[p] =
              sti.m_StepsTypeCategory == StepsTypeCategory_Routine;
          bAnySelectedRoutine |= bSelectedRoutineSteps[p];
        }

        if (bAnySelectedRoutine) {
          /* Timer ran out. If we haven't agreed on steps, move players with
           * Routine steps down to Beginner. I'll admit that's annoying,
           * but at least they won't lose more stages. */
          if (bInitiatedByMenuTimer && !bSelectedSameSteps) {
            /* Since m_vpSteps is sorted by Difficulty, the first
             * entry should be the easiest. */
            Steps* pSteps = GetSelectedSteps(m_vpSteps, 0);
            if (pSteps == nullptr) {
              WarnSelectMusic(
                  "Routine timer fallback could not find a playable chart.");
              return false;
            }

            FOREACH_PlayerNumber(p) {
              if (bSelectedRoutineSteps[p]) {
                GAMESTATE->m_pCurSteps[p].Set(pSteps);
              }
            }

            break;
          }

          // If the steps don't match up, we need to check some more
          // conditions...
          if (!bSelectedSameSteps) {
            if (!valid_player) {
              return false;
            }
            const PlayerNumber other = OPPOSITE_PLAYER[pn];

            if (m_bStepsChosen[other]) {
              /* Unready the other player if they selected Routine
               * steps, but we didn't. */
              if (bSelectedRoutineSteps[other]) {
                m_bStepsChosen[other] = false;
                bAllPlayersDoneSelectingSteps =
                    false;  // if the timer ran out, we handled it earlier

                // HACK: send an event to Input to tell it to unready.
                InputEventPlus event;
                event.MenuI = GAME_BUTTON_SELECT;
                event.pn = other;

                this->Input(event);
              } else if (bSelectedRoutineSteps[pn]) {
                /* They selected non-Routine steps, so we can't
                 * select Routine steps. */
                return false;
              }
            }
          }
        }
      }

      if (!bAllPlayersDoneSelectingSteps) {
        if (!valid_player) {
          return false;
        }
        m_bStepsChosen[pn] = true;
        PlaySoundIfLoaded(m_soundStart);

        // impldiff: Pump it Up Pro uses "StepsSelected". -aj
        Message msg("StepsChosen");
        msg.SetParam("Player", pn);
        BroadcastSelectMusic(msg);
        return true;
      }
    } break;
    case SelectionState_Finalized:
    case NUM_SelectionState:
      return false;
  }

  FOREACH_ENUM(PlayerNumber, p) {
    if (!TWO_PART_SELECTION ||
        m_SelectionState == SelectionState_SelectingSteps) {
      if (m_OptionsList[p].IsOpened()) {
        m_OptionsList[p].Close();
      }
    }
    UpdateSelectButton(p, false);
  }

  m_SelectionState = GetNextSelectionState();
  Message msg("Start" + SelectionStateToString(m_SelectionState));
  BroadcastSelectMusic(msg);

  PlaySoundIfLoaded(m_soundStart);

  // If the MenuTimer has forced us to move on && TWO_PART_CONFIRMS_ONLY,
  // set Selection State to finalized and move on.
  if (TWO_PART_CONFIRMS_ONLY) {
    if (HasUsableTimer(m_MenuTimer) && m_MenuTimer->GetSeconds() < 1) {
      m_SelectionState = SelectionState_Finalized;
    }
  }

  if (m_SelectionState == SelectionState_Finalized) {
    if (!HasPlayableSelectionForEachHumanPlayer()) {
      WarnSelectMusic(
          "Refused to finalize ScreenSelectMusic without playable steps or "
          "trails for every human player.");
      m_SelectionState = previousSelectionState;
      return false;
    }

    if (HasUsableTimer(m_MenuTimer)) {
      m_MenuTimer->Stop();
    }

    FOREACH_HumanPlayer(p) {
      if (!m_bStepsChosen[p]) {
        m_bStepsChosen[p] = true;
        // Don't play start sound. We play it again below on finalized
        // m_soundStart.Play(true);

        Message lMsg("StepsChosen");
        lMsg.SetParam("Player", p);
        BroadcastSelectMusic(lMsg);
      }
    }

    // Now that Steps have been chosen, set a Style that can play them.
    GAMESTATE->SetCompatibleStylesForPlayers();
    GAMESTATE->ForceSharedSidesMatch();
    GAMESTATE->prepare_song_for_gameplay();

    /* If we're currently waiting on song assets, abort all except the music
     * and start the music, so if we make a choice quickly before background
     * requests come through, the music will still start. */
    m_bCDTitleWaiting = m_bBannerWaiting = false;
    m_BackgroundLoader.Abort();
    CheckBackgroundRequests(true);

    if (OPTIONS_MENU_AVAILABLE) {
      // show "hold START for options"
      this->PlayCommand("ShowPressStartForOptions");

      m_bAllowOptionsMenu = true;

      /* Don't accept a held START for a little while, so it's not
       * hit accidentally.  Accept an initial START right away, though,
       * so we don't ignore deliberate fast presses (which would be
       * annoying). */
      if (PREFSMAN != nullptr && PREFSMAN->m_AllowHoldForOptions.Get()) {
        this->PostScreenMessage(SM_AllowOptionsMenuRepeat, 0.5f);
      }

      StartTransitioningScreen(SM_None);
      float fTime = std::max(
          GetThemeMetricSeconds(m_sName, "ShowOptionsMessageSeconds"),
          this->GetTweenTimeLeft());
      this->PostScreenMessage(SM_BeginFadingOut, fTime);
    } else {
      StartTransitioningScreen(SM_BeginFadingOut);
    }
  } else  // !finalized.  Set the timer for selecting difficulty and mods.
  {
    float fSeconds =
        HasUsableTimer(m_MenuTimer) ? m_MenuTimer->GetSeconds() : 0.0f;
    if (HasUsableTimer(m_MenuTimer) && fSeconds < 10) {
      m_MenuTimer->SetSeconds(SanitizeMetricSeconds(
          TWO_PART_TIMER_SECONDS.GetValue()));  // was 13 -aj
      m_MenuTimer->Start();
    }
  }
  return true;
}

void ScreenSelectMusic::ReturnToOnlineLobbyFromMusicSelect() {
  if (!HasActiveITGOnlineRoom()) {
    WarnSelectMusic(
        "Ignoring ReturnToOnlineLobbyFromMusicSelect without an active online "
        "room.");
    return;
  }
  if (IsTransitioning()) {
    WarnSelectMusic(
        "Ignoring ReturnToOnlineLobbyFromMusicSelect during an active "
        "transition.");
    return;
  }
  ClearMessageQueue(SM_BeginFadingOut);
  ClearMessageQueue(SM_GoToNextScreen);
  m_bGoToOptions = false;
  m_bAllowOptionsMenu = false;
  m_bAllowOptionsMenuRepeat = false;
  m_SelectionState = SelectionState_SelectingSong;
  ResetAssetRequestState();
  m_BackgroundLoader.Abort();
  if (SOUND != nullptr) {
    SOUND->StopMusic();
  }
  SetNextScreenName("ScreenOnlineLobbies");
  StartTransitioningScreen(SM_GoToNextScreen);
}

bool ScreenSelectMusic::MenuBack(const InputEventPlus& /* input */) {
  if (HasActiveITGOnlineRoom()) {
    ReturnToOnlineLobbyFromMusicSelect();
    return true;
  }

  // Handle unselect song (ffff)
  // todo: this isn't right at all. -aj
  /*
  if( m_SelectionState == SelectionState_SelectingSteps &&
          !m_bStepsChosen[input.pn] && input.MenuI == GAME_BUTTON_BACK &&
          input.type == IET_FIRST_PRESS )
  {
          // if a player has chosen their steps already, don't unchoose song.
          FOREACH_HumanPlayer( p )
                  if( m_bStepsChosen[p] ) return;

          // and if we get here...
          Message msg("SongUnchosen");
          msg.SetParam( "Player", input.pn );
          MESSAGEMAN->Broadcast( msg );
          m_SelectionState = SelectionState_SelectingSong;
          return true;
  }
  */

  Cancel(SM_GoToPrevScreen);
  return true;
}

void ScreenSelectMusic::Cancel(ScreenMessage smSendWhenDone) {
  if (CONFIRM_EXIT) {
    SuspendPreviewForPrompt();
    ScreenPrompt::Prompt(
        SM_ConfirmExit, PROMPT_BEFORE_EXITING.GetValue().c_str(), PROMPT_YES_NO,
        ANSWER_NO, nullptr, nullptr, nullptr, true);
  } else {
    ConfirmedCancel(smSendWhenDone);
  }
}

void ScreenSelectMusic::ConfirmedCancel(ScreenMessage smSendWhenDone) {
  m_bPreviewSuspendedForPrompt = false;
  m_BackgroundLoader.Abort();
  ScreenWithMenuElements::Cancel(smSendWhenDone);
}

void ScreenSelectMusic::AfterStepsOrTrailChange(
    const std::vector<PlayerNumber>& vpns) {
  if (TWO_PART_CONFIRMS_ONLY &&
      m_SelectionState == SelectionState_SelectingSteps) {
    // if TWO_PART_CONFIRMS_ONLY, changing difficulties unsets the song. -aj
    m_SelectionState = SelectionState_SelectingSong;
    BroadcastSelectMusic("TwoPartConfirmCanceled");
  }

  for (const PlayerNumber& pn : vpns) {
    if (GAMESTATE == nullptr || !IsValidPlayer(pn) ||
        !GAMESTATE->IsHumanPlayer(pn)) {
      continue;
    }

    if (GAMESTATE->m_pCurSong) {
      m_iSelection[pn] =
          ClampSelectionIndex(m_iSelection[pn], m_vpSteps.size());

      Song* pSong = GAMESTATE->m_pCurSong;
      Steps* pSteps = GetSelectedSteps(m_vpSteps, m_iSelection[pn]);

      GAMESTATE->m_pCurSteps[pn].Set(pSteps);
      GAMESTATE->m_pCurTrail[pn].Set(nullptr);

      int iScore = 0;
      if (pSteps) {
        const Profile* pProfile = GetSafeProfile(pn);
        if (pProfile != nullptr) {
          iScore = pProfile->GetStepsHighScoreList(pSong, pSteps)
                       .GetTopScore()
                       .GetScore();
        }
      }

      m_textHighScore[pn].SetText(ssprintf("%*i", NUM_SCORE_DIGITS, iScore));
    } else if (GAMESTATE->m_pCurCourse) {
      m_iSelection[pn] =
          ClampSelectionIndex(m_iSelection[pn], m_vpTrails.size());

      Course* pCourse = GAMESTATE->m_pCurCourse;
      Trail* pTrail = GetSelectedTrail(m_vpTrails, m_iSelection[pn]);

      GAMESTATE->m_pCurSteps[pn].Set(nullptr);
      GAMESTATE->m_pCurTrail[pn].Set(pTrail);

      int iScore = 0;
      if (pTrail) {
        const Profile* pProfile = GetSafeProfile(pn);
        if (pProfile != nullptr) {
          iScore = pProfile->GetCourseHighScoreList(pCourse, pTrail)
                       .GetTopScore()
                       .GetScore();
        }
      }

      m_textHighScore[pn].SetText(ssprintf("%*i", NUM_SCORE_DIGITS, iScore));
    } else {
      // The numbers shouldn't stay if the current selection is nullptr.
      m_textHighScore[pn].SetText(NULL_SCORE_STRING);
    }
  }
}

bool ScreenSelectMusic::HasPlayableSelectionForEachHumanPlayer() const {
  if (GAMESTATE == nullptr) {
    return false;
  }

  bool hasHumanPlayer = false;
  if (GAMESTATE->m_pCurSong) {
    if (m_vpSteps.empty()) {
      return false;
    }
    FOREACH_HumanPlayer(pn) {
      hasHumanPlayer = true;
      if (GAMESTATE->m_pCurSteps[pn] == nullptr) {
        return false;
      }
    }
    return hasHumanPlayer;
  }

  if (GAMESTATE->m_pCurCourse) {
    if (m_vpTrails.empty()) {
      return false;
    }
    FOREACH_HumanPlayer(pn) {
      hasHumanPlayer = true;
      if (GAMESTATE->m_pCurTrail[pn] == nullptr) {
        return false;
      }
    }
    return hasHumanPlayer;
  }

  return false;
}

void ScreenSelectMusic::SwitchPlayerStepDifficulty(
    PlayerNumber pn, Difficulty d) {
  if (GAMESTATE == nullptr || !IsValidPlayer(pn) || m_vpSteps.empty()) {
    return;
  }

  // Find the closest match to the given difficulty and StepsType.
  int iCurDifference = -1;
  int& iSelection = m_iSelection[pn];
  int i = 0;
  for (Steps* s : m_vpSteps) {
    if (s == nullptr) {
      i += 1;
      continue;
    }
    // If the current steps are listed, use them.
    if (GAMESTATE->m_pCurSteps[pn] == s) {
      iSelection = i;
      break;
    }

    if (d != Difficulty_Invalid) {
      int iDifficultyDifference = std::abs(s->GetDifficulty() - d);
      int iStepsTypeDifference = 0;
      if (GAMESTATE->m_PreferredStepsType != StepsType_Invalid) {
        iStepsTypeDifference =
            std::abs(s->m_StepsType - GAMESTATE->m_PreferredStepsType);
      }
      int iTotalDifference =
          iStepsTypeDifference * NUM_Difficulty + iDifficultyDifference;

      if (iCurDifference == -1 || iTotalDifference < iCurDifference) {
        iSelection = i;
        iCurDifference = iTotalDifference;
      }
    }
    i += 1;
  }

  iSelection = ClampSelectionIndex(iSelection, m_vpSteps.size());
}

void ScreenSelectMusic::SwitchPlayerCourseDifficulty(
    PlayerNumber pn, Difficulty d) {
  if (GAMESTATE == nullptr || !IsValidPlayer(pn) || m_vpTrails.empty()) {
    return;
  }

  // Find the closest match to the given difficulty.
  int iCurDifference = -1;
  int& iSelection = m_iSelection[pn];
  int i = 0;
  for (Trail* t : m_vpTrails) {
    if (t == nullptr) {
      i += 1;
      continue;
    }
    // If the current trail is listed, use it.
    if (GAMESTATE->m_pCurTrail[pn] == m_vpTrails[i]) {
      iSelection = i;
      break;
    }

    if (d != Difficulty_Invalid &&
        GAMESTATE->m_PreferredStepsType != StepsType_Invalid) {
      int iDifficultyDifference = std::abs(t->m_CourseDifficulty - d);
      int iStepsTypeDifference =
          std::abs(t->m_StepsType - GAMESTATE->m_PreferredStepsType);
      int iTotalDifference =
          iStepsTypeDifference * NUM_CourseDifficulty + iDifficultyDifference;

      if (iCurDifference == -1 || iTotalDifference < iCurDifference) {
        iSelection = i;
        iCurDifference = iTotalDifference;
      }
    }
    i += 1;
  }

  iSelection = ClampSelectionIndex(iSelection, m_vpTrails.size());
}

void ScreenSelectMusic::SwitchToDifficulty(Difficulty d) {
  if (GAMESTATE == nullptr) {
    return;
  }

  if (!GAMESTATE->m_pCurCourse) {
    FOREACH_HumanPlayer(pn) { SwitchPlayerStepDifficulty(pn, d); }
  } else {
    FOREACH_HumanPlayer(pn) { SwitchPlayerCourseDifficulty(pn, d); }
  }

  if (GAMESTATE->DifficultiesLocked()) {
    const PlayerNumber master = GAMESTATE->GetMasterPlayerNumber();
    if (IsValidPlayer(master)) {
      FOREACH_HumanPlayer(p) m_iSelection[p] = m_iSelection[master];
    }
  }
}

void ScreenSelectMusic::SwitchToPreferredDifficulty() {
  if (GAMESTATE == nullptr) {
    return;
  }

  if (!GAMESTATE->m_pCurCourse) {
    FOREACH_HumanPlayer(pn) {
      SwitchPlayerStepDifficulty(pn, GAMESTATE->m_PreferredDifficulty[pn]);
    }
  } else {
    FOREACH_HumanPlayer(pn) {
      SwitchPlayerCourseDifficulty(
          pn, GAMESTATE->m_PreferredCourseDifficulty[pn]);
    }
  }

  if (GAMESTATE->DifficultiesLocked()) {
    const PlayerNumber master = GAMESTATE->GetMasterPlayerNumber();
    if (IsValidPlayer(master)) {
      FOREACH_HumanPlayer(p) m_iSelection[p] = m_iSelection[master];
    }
  }
}

// NOTE: This could a be a bit more robust than just looking at the extension,
// but it's good enough for now.
static bool IsVideoFile(const std::string& path) {
  const std::string extension = GetExtension(path);
  return extension == "mp4" || extension == "avi" || extension == "mov" ||
         extension == "mkv" || extension == "mpg";
}

void ScreenSelectMusic::AfterMusicChange() {
  if (GAMESTATE == nullptr) {
    return;
  }

  if (!m_MusicWheel.IsRouletting() && HasUsableTimer(m_MenuTimer)) {
    m_MenuTimer->Stall();
  }

  Song* pSong = m_MusicWheel.GetSelectedSong();
  GAMESTATE->m_pCurSong.Set(pSong);
  if (pSong) {
    GAMESTATE->m_pPreferredSong = pSong;
  }

  Course* pCourse = m_MusicWheel.GetSelectedCourse();
  GAMESTATE->m_pCurCourse.Set(pCourse);
  if (pCourse) {
    GAMESTATE->m_pPreferredCourse = pCourse;
  }

  m_vpSteps.clear();
  m_vpTrails.clear();

  m_Banner.SetMovingFast(!!m_MusicWheel.IsMoving());

  std::vector<std::string> m_Artists, m_AltArtists;

  if (SAMPLE_MUSIC_PREVIEW_MODE != SampleMusicPreviewMode_LastSong) {
    m_sSampleMusicToPlay = "";
  }
  m_pSampleMusicTimingData = nullptr;
  m_sCDTitlePath = "";
  m_sBannerPath = "";
  m_bWantFallbackCdTitle = false;
  bool bWantBanner = true;

  static SortOrder s_lastSortOrder = SortOrder_Invalid;
  if (GAMESTATE->m_SortOrder != s_lastSortOrder) {
    // Reload to let Lua metrics have a chance to change the help text.
    s_lastSortOrder = GAMESTATE->m_SortOrder;
  }

  WheelItemDataType wtype = m_MusicWheel.GetSelectedType();
  SampleMusicPreviewMode pmode;
  switch (wtype) {
    case WheelItemDataType_Section:
    case WheelItemDataType_Sort:
    case WheelItemDataType_Roulette:
    case WheelItemDataType_Random:
    case WheelItemDataType_Custom:
      FOREACH_PlayerNumber(p) m_iSelection[p] = -1;

      m_sCDTitlePath = "";  // none

      if (SAMPLE_MUSIC_PREVIEW_MODE == SampleMusicPreviewMode_LastSong) {
        // HACK: Make random music work in LastSong mode. -aj
        if (m_sSampleMusicToPlay == m_sRandomMusicPath) {
          m_fSampleStartSeconds = 0;
          m_fSampleLengthSeconds = -1;
        }
      } else {
        m_fSampleStartSeconds = 0;
        m_fSampleLengthSeconds = -1;
      }

      switch (wtype) {
        case WheelItemDataType_Section:
          // reduce scope
          {
            SortOrder curSort = GAMESTATE->m_SortOrder;
            if (curSort == SORT_GROUP && SONGMAN != nullptr) {
              m_sBannerPath = SONGMAN->GetSongGroupBannerPath(
                  m_MusicWheel.GetSelectedSection());
            } else {
              bWantBanner = false;  // we load it ourself
              m_Banner.LoadFromSortOrder(curSort);
            }

            if (SAMPLE_MUSIC_PREVIEW_MODE != SampleMusicPreviewMode_LastSong) {
              m_sSampleMusicToPlay = m_sSectionMusicPath;
            }
          }
          break;
        case WheelItemDataType_Sort:
          bWantBanner = false;  // we load it ourself
          m_Banner.LoadMode();
          if (SAMPLE_MUSIC_PREVIEW_MODE != SampleMusicPreviewMode_LastSong) {
            m_sSampleMusicToPlay = m_sSortMusicPath;
          }
          break;
        case WheelItemDataType_Roulette:
          bWantBanner = false;  // we load it ourself
          m_Banner.LoadRoulette();
          if (SAMPLE_MUSIC_PREVIEW_MODE != SampleMusicPreviewMode_LastSong) {
            m_sSampleMusicToPlay = m_sRouletteMusicPath;
          }
          break;
        case WheelItemDataType_Random:
          bWantBanner = false;  // we load it ourself
          m_Banner.LoadRandom();
          // if( SAMPLE_MUSIC_PREVIEW_MODE != SampleMusicPreviewMode_LastSong )
          m_sSampleMusicToPlay = m_sRandomMusicPath;
          break;
        case WheelItemDataType_Custom: {
          bWantBanner = false;  // we load it ourself
          const MusicWheelItemData* item = GetMusicWheel()->GetCurWheelItemData(
              GetMusicWheel()->GetCurrentIndex());
          if (item != nullptr && !item->m_pAction.isNull()) {
            m_Banner.LoadCustom(item->m_pAction->m_sName.c_str());
          } else {
            WarnSelectMusic(
                "Custom wheel item had no action; using fallback banner.");
            m_Banner.LoadFallback();
          }
          if (SAMPLE_MUSIC_PREVIEW_MODE != SampleMusicPreviewMode_LastSong) {
            m_sSampleMusicToPlay = m_sSectionMusicPath;
          }
        } break;
        default:
          WarnSelectMusic("Invalid non-song wheel item type: %i", wtype);
          m_Banner.LoadFallback();
      }
      // override this if the sample music mode wants to.
      /*
      if(SAMPLE_MUSIC_PREVIEW_MODE == SampleMusicPreviewMode_LastSong)
      {
              m_sSampleMusicToPlay = pSong->GetMusicPath();
              m_pSampleMusicTimingData = &pSong->m_SongTiming;
              m_fSampleStartSeconds = pSong->m_fMusicSampleStartSeconds;
              m_fSampleLengthSeconds = pSong->m_fMusicSampleLengthSeconds;
      }
      */
      break;
    case WheelItemDataType_Song:
    case WheelItemDataType_Portal:
      if (pSong == nullptr) {
        WarnSelectMusic("Song wheel item did not provide a Song pointer.");
        m_Banner.LoadFallback();
        m_sSampleMusicToPlay.clear();
        break;
      }
      // check SampleMusicPreviewMode here.
      pmode = SAMPLE_MUSIC_PREVIEW_MODE;
      switch (pmode) {
        case SampleMusicPreviewMode_ScreenMusic:
          // play the screen music
          m_sSampleMusicToPlay = m_sLoopMusicPath;
          m_fSampleStartSeconds = 0;
          m_fSampleLengthSeconds = -1;
          break;
        case SampleMusicPreviewMode_StartToPreview:
          // we want to load the sample music, but we don't want to
          // actually play it. fall through. -aj
        case SampleMusicPreviewMode_Normal:
        case SampleMusicPreviewMode_LastSong:
          // play the sample music
          m_sSampleMusicToPlay = pSong->GetPreviewMusicPath();
          if (!m_sSampleMusicToPlay.empty() &&
              ActorUtil::GetFileType(m_sSampleMusicToPlay) != FT_Sound) {
            LuaHelpers::ReportScriptErrorFmt(
                "Music file %s for song is not a sound file, ignoring.",
                m_sSampleMusicToPlay.c_str());
            m_sSampleMusicToPlay = "";
          }
          m_pSampleMusicTimingData = &pSong->m_SongTiming;
          m_fSampleStartSeconds = pSong->GetPreviewStartSeconds();
          m_fSampleLengthSeconds = pSong->m_fMusicSampleLengthSeconds;
          break;
        default:
          WarnSelectMusic("Invalid sample music preview mode: %i", pmode);
          m_sSampleMusicToPlay.clear();
      }

      SongUtil::GetPlayableSteps(pSong, m_vpSteps);
      if (m_vpSteps.empty()) {
        WarnSelectMusic(
            "Selected song '%s' has no playable steps; clearing gameplay "
            "selection.",
            pSong->GetSongDir().c_str());
      }

      if (PREFSMAN != nullptr && PREFSMAN->m_bShowBanners) {
        m_sBannerPath = pSong->GetBannerPath();
      }

      m_sCDTitlePath = pSong->GetCDTitlePath();
      m_bWantFallbackCdTitle = true;

      if (GAMESTATE->m_SortOrder == SORT_METER && !m_vpSteps.empty()) {
        for (int i = static_cast<int>(m_vpSteps.size()) - 1; i >= 0; i--) {
          Steps* steps = m_vpSteps[i];
          if (steps != nullptr &&
              steps->GetMeter() == StringToInt(GAMESTATE->sLastOpenSection)) {
            SwitchToDifficulty(steps->GetDifficulty());
            break;
          }
        }
      } else {
        SwitchToPreferredDifficulty();
      }
      break;

    case WheelItemDataType_Course: {
      const Course* lCourse = m_MusicWheel.GetSelectedCourse();
      if (lCourse == nullptr) {
        WarnSelectMusic("Course wheel item did not provide a Course pointer.");
        m_Banner.LoadFallback();
        m_sSampleMusicToPlay = m_sCourseMusicPath;
        m_fSampleStartSeconds = 0;
        m_fSampleLengthSeconds = -1;
        break;
      }
      const Style* pStyle = nullptr;
      if (CommonMetrics::AUTO_SET_STYLE) {
        pStyle = lCourse->GetCourseStyle(
            GAMESTATE->m_pCurGame, GAMESTATE->GetNumPlayersEnabled());
        if (pStyle == nullptr) {
          lCourse->GetAllTrails(m_vpTrails);
          std::vector<Trail*>::iterator tra = m_vpTrails.begin();
          const Game* cur_game = GAMESTATE->GetCurrentGame();
          int num_players = GAMESTATE->GetNumPlayersEnabled();
          while (tra != m_vpTrails.end()) {
            if (*tra == nullptr || GAMEMAN == nullptr || cur_game == nullptr ||
                GAMEMAN->GetFirstCompatibleStyle(
                    cur_game, num_players, (*tra)->m_StepsType) == nullptr) {
              tra = m_vpTrails.erase(tra);
            } else {
              ++tra;
            }
          }
        } else {
          lCourse->GetTrails(m_vpTrails, pStyle->m_StepsType);
        }
      } else {
        pStyle = GAMESTATE->GetCurrentStyle(PLAYER_INVALID);
        if (pStyle != nullptr) {
          lCourse->GetTrails(m_vpTrails, pStyle->m_StepsType);
        } else {
          lCourse->GetAllTrails(m_vpTrails);
        }
      }

      m_sSampleMusicToPlay = m_sCourseMusicPath;
      m_fSampleStartSeconds = 0;
      m_fSampleLengthSeconds = -1;

      if (m_vpTrails.empty()) {
        WarnSelectMusic(
            "Selected course '%s' has no playable trails; clearing gameplay "
            "selection.",
            lCourse->m_sPath.c_str());
      }

      m_sBannerPath = lCourse->GetBannerPath();
      if (m_sBannerPath.empty()) {
        m_Banner.LoadFallback();
      }

      SwitchToPreferredDifficulty();
      break;
    }
    default:
      WarnSelectMusic("Invalid WheelItemDataType: %i", wtype);
      m_Banner.LoadFallback();
      m_sSampleMusicToPlay.clear();
  }

  m_sprCDTitleFront.UnloadTexture();
  m_sprCDTitleBack.UnloadTexture();

  // Cancel any previous, incomplete requests for song assets,
  // since we need new ones.
  m_BackgroundLoader.Abort();

  m_bCDTitleWaiting = false;
  if (!m_sCDTitlePath.empty() || m_bWantFallbackCdTitle) {
    if (!m_sCDTitlePath.empty()) {
      if (LOG != nullptr) {
        LOG->Trace("cache \"%s\"", m_sCDTitlePath.c_str());
      }
      m_BackgroundLoader.CacheFile(m_sCDTitlePath);
      m_bCDTitleWaiting = true;
    } else if (m_bWantFallbackCdTitle && !m_sFallbackCDTitlePath.empty()) {
      if (TEXTUREMAN != nullptr) {
        TEXTUREMAN->DisableOddDimensionWarning();
      }
      m_sprCDTitleFront.Load(m_sFallbackCDTitlePath);
      m_sprCDTitleBack.Load(m_sFallbackCDTitlePath);
      if (TEXTUREMAN != nullptr) {
        TEXTUREMAN->EnableOddDimensionWarning();
      }
    }
  }

  m_bBannerWaiting = false;
  if (bWantBanner) {
    if (LOG != nullptr) {
      LOG->Trace("LoadFromCachedBanner(%s)", m_sBannerPath.c_str());
    }
    // TODO: We should probably have some fallback banner for videos, but for
    // now we can just load the video file directly. This is to try an address
    // some issues with the video banners potentially crashing the game but
    // needs some more investigation.
    if (IsVideoFile(m_sBannerPath)) {
      // Directly load the video file.
      m_Banner.LoadFromCachedBanner(m_sBannerPath);
      m_bBannerWaiting = false;
    } else {
      if (m_Banner.LoadFromCachedBanner(m_sBannerPath)) {
        /* If the high-res banner is already loaded, just delay before
         * loading it, so the low-res one has time to fade in. */
        if (TEXTUREMAN == nullptr ||
            !TEXTUREMAN->IsTextureRegistered(
                Sprite::SongBannerTexture(m_sBannerPath))) {
          m_BackgroundLoader.CacheFile(m_sBannerPath);
        }

        m_bBannerWaiting = true;
      }
    }
  }

  // Don't stop music if it's already playing the right file.
  m_bSampleMusicWaiting = false;
  if (!m_bPreviewSuspendedForPrompt && !m_MusicWheel.IsRouletting() &&
      SOUND != nullptr && SOUND->GetMusicPath() != m_sSampleMusicToPlay) {
    SOUND->StopMusic();
    // some SampleMusicPreviewModes don't want the sample music immediately.
    if (SAMPLE_MUSIC_PREVIEW_MODE != SampleMusicPreviewMode_StartToPreview) {
      if (!m_sSampleMusicToPlay.empty()) {
        m_bSampleMusicWaiting = true;
      }
    }
  }

  m_StartedLoadingAt.Touch();

  std::vector<PlayerNumber> vpns;
  FOREACH_HumanPlayer(p) vpns.push_back(p);

  AfterStepsOrTrailChange(vpns);
}

void ScreenSelectMusic::OpenOptionsList(PlayerNumber pn) {
  if (can_open_options_list(pn)) {
    m_MusicWheel.Move(0);
    m_OptionsList[pn].Open();
  }
}

void ScreenSelectMusic::OnConfirmSongDeletion() {
  const std::string deleteDir =
      NormalizeVirtualDirectory(m_sSongAwaitingDeletionDir);
  const std::string deleteTitle = m_sSongAwaitingDeletionTitle;
  m_sSongAwaitingDeletionDir.clear();
  m_sSongAwaitingDeletionTitle.clear();

  if (deleteDir.empty()) {
    WarnSelectMusic(
        "Attempted to delete a song without a pending directory "
        "(ScreenSelectMusic::OnConfirmSongDeletion)");
    m_bPreviewSuspendedForPrompt = false;
    return;
  }
  // ensure Stepmania is configured to allow song deletion
  if (PREFSMAN == nullptr || !PREFSMAN->m_bAllowSongDeletion.Get()) {
    WarnSelectMusic(
        "Attemped to delete a song but AllowSongDeletion was set to false "
        "(ScreenSelectMusic::OnConfirmSongDeletion)");
    m_bPreviewSuspendedForPrompt = false;
    return;
  }

  if (!IsSafeSongDeletionDirectory(deleteDir)) {
    WarnSelectMusic(
        "Refused to delete unsafe song directory '%s'.", deleteDir.c_str());
    m_bPreviewSuspendedForPrompt = false;
    return;
  }
  if (FILEMAN == nullptr || SONGMAN == nullptr) {
    WarnSelectMusic(
        "Unable to delete song '%s' because file or song manager is "
        "unavailable.",
        deleteDir.c_str());
    m_bPreviewSuspendedForPrompt = false;
    return;
  }

  if (LOG != nullptr) {
    LOG->Trace(
        "Deleting song: '%s' (%s)\n", deleteTitle.c_str(), deleteDir.c_str());
  }
  // delete the song directory from disk
  if (!FILEMAN->DeleteRecursive(deleteDir)) {
    WarnSelectMusic("Failed to delete song directory '%s'.", deleteDir.c_str());
    m_bPreviewSuspendedForPrompt = false;
    return;
  }

  // flush the deleted song from any caches only after disk deletion succeeds.
  Song* deletedSong = SONGMAN->GetSongFromDir(deleteDir);
  if (deletedSong != nullptr) {
    SONGMAN->UnlistSong(deletedSong);
  }
  // refresh the song list
  m_MusicWheel.ReloadSongList();

  ResetAssetRequestState();
  m_bPreviewSuspendedForPrompt = false;
}

bool ScreenSelectMusic::can_open_options_list(PlayerNumber pn) {
  if (!USE_OPTIONS_LIST) {
    return false;
  }
  if (GAMESTATE == nullptr || !IsValidPlayer(pn) ||
      !GAMESTATE->IsHumanPlayer(pn)) {
    return false;
  }
  if (!CanChangeSong() || IsTransitioning()) {
    return false;
  }
  if (m_CanOpenOptionsList[pn].Ago() >
      SanitizeMetricSeconds(OPTIONS_LIST_TIMEOUT.GetValue())) {
    return false;
  }
  if (m_OptionsList[pn].IsOpened()) {
    return false;
  }
  return true;
}

// lua start
#include "LuaBinding.h"

/** @brief Allow Lua to have access to the ScreenSelectMusic. */
class LunaScreenSelectMusic : public Luna<ScreenSelectMusic> {
 public:
  static int GetGoToOptions(T* p, lua_State* L) {
    lua_pushboolean(L, p->GetGoToOptions());
    return 1;
  }
  static int GetMusicWheel(T* p, lua_State* L) {
    p->GetMusicWheel()->PushSelf(L);
    return 1;
  }
  static int OpenOptionsList(T* p, lua_State* L) {
    PlayerNumber pn = Enum::Check<PlayerNumber>(L, 1);
    if (p->can_open_options_list(pn)) {
      p->OpenOptionsList(pn);
    }
    COMMON_RETURN_SELF;
  }
  static int CanOpenOptionsList(T* p, lua_State* L) {
    PlayerNumber pn = Enum::Check<PlayerNumber>(L, 1);
    lua_pushboolean(L, p->can_open_options_list(pn));
    return 1;
  }
  static int ReturnToOnlineLobbyFromMusicSelect(T* p, lua_State* L) {
    p->ReturnToOnlineLobbyFromMusicSelect();
    COMMON_RETURN_SELF;
  }

  LunaScreenSelectMusic() {
    ADD_METHOD(GetGoToOptions);
    ADD_METHOD(GetMusicWheel);
    ADD_METHOD(OpenOptionsList);
    ADD_METHOD(CanOpenOptionsList);
    ADD_METHOD(ReturnToOnlineLobbyFromMusicSelect);
  }
};

LUA_REGISTER_DERIVED_CLASS(ScreenSelectMusic, ScreenWithMenuElements)
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
