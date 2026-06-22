#include "PrefsManager.h"

#include <algorithm>
#include <cmath>
#include <map>
#include <string>

#include "EnumHelper.h"
#include "GameConstantsAndTypes.h"
#include "IniFile.h"
#include "LuaManager.h"
#include "PerfDiagnostics.h"
#include "Preference.h"
#include "ProductInfo.h"
#include "RageDisplay.h"
#include "RageLog.h"
#include "RageUtil.h"
#include "SpecialFiles.h"
#include "StdString.h"
#include "XmlFile.h"
#include "global.h"

// DEFAULTS_INI_PATH	= "Data/Defaults.ini";		// these can be
// overridden PREFERENCES_INI_PATH	// overlay on Defaults.ini, contains the
// user's choices STATIC_INI_PATH	= "Data/Static.ini";		//
// overlay on the 2 above, can't be overridden TYPE_TXT_FILE	=
// "Data/Type.txt";

PrefsManager* PREFSMAN =
    nullptr;  // global and accessible from anywhere in our program

static const float MIN_GLOBAL_OFFSET_SECONDS = -10.0f;
static const float MAX_GLOBAL_OFFSET_SECONDS = 10.0f;
static const float DEFAULT_GLOBAL_OFFSET_SECONDS = -0.008f;

static const char* MusicWheelUsesSectionsNames[] = {
    "Never",
    "Always",
    "ABCOnly",
};
XToString(MusicWheelUsesSections);
StringToX(MusicWheelUsesSections);
LuaXType(MusicWheelUsesSections);

static const char* AllowW1Names[] = {
    "Never",
    "CoursesOnly",
    "Everywhere",
};
XToString(AllowW1);
StringToX(AllowW1);
LuaXType(AllowW1);

static const char* MaybeNames[] = {
    "Ask",
    "No",
    "Yes",
};
XToString(Maybe);
StringToX(Maybe);
LuaXType(Maybe);

static const char* GetRankingNameNames[] = {
    "Off",
    "On",
    "List",
};
XToString(GetRankingName);
StringToX(GetRankingName);
LuaXType(GetRankingName);

static const char* RandomBackgroundModeNames[] = {
    "Off",
    "Animations",
    "RandomMovies",
};
XToString(RandomBackgroundMode);
StringToX(RandomBackgroundMode);
LuaXType(RandomBackgroundMode);

static const char* ShowDancingCharactersNames[] = {
    "Off",
    "Random",
    "Select",
};
XToString(ShowDancingCharacters);
StringToX(ShowDancingCharacters);
LuaXType(ShowDancingCharacters);

static const char* ImageCacheModeNames[] = {
    "Off", "LowResPreload", "LowResLoadOnDemand", "Full"};
XToString(ImageCacheMode);
StringToX(ImageCacheMode);
LuaXType(ImageCacheMode);

static const char* HighResolutionTexturesNames[] = {
    "Auto",
    "ForceOff",
    "ForceOn",
};
XToString(HighResolutionTextures);
StringToX(HighResolutionTextures);
LuaXType(HighResolutionTextures);

static const char* AttractSoundFrequencyNames[] = {
    "Never",       "EveryTime",   "Every2Times",
    "Every3Times", "Every4Times", "Every5Times",
};
XToString(AttractSoundFrequency);
StringToX(AttractSoundFrequency);
LuaXType(AttractSoundFrequency);

static const char* CourseSortOrdersNames[] = {
    "Preferred", "Songs", "Meter", "MeterSum", "MeterRank",
};
XToString(CourseSortOrders);
StringToX(CourseSortOrders);
LuaXType(CourseSortOrders);

static const char* BackgroundFitModeNames[] = {
    "CoverDistort",         "CoverPreserve",        "FitInside",
    "FitInsideAvoidLetter", "FitInsideAvoidPillar",
};
XToString(BackgroundFitMode);
StringToX(BackgroundFitMode);
LuaXType(BackgroundFitMode);

static const char* ProfileSortOrderNames[] = {
    "Priority", "Recent", "Alphabetical"};
XToString(ProfileSortOrder);
StringToX(ProfileSortOrder);
LuaXType(ProfileSortOrder);

static const char* SyncOffsetNames[] = {"NULL", "ITG"};
XToString(SyncOffset);
StringToX(SyncOffset);
LuaXType(SyncOffset);

bool g_bAutoRestart = false;
#ifdef DEBUG
#define TRUE_IF_DEBUG true
#else
#define TRUE_IF_DEBUG false
#endif

void ValidateDisplayAspectRatio(float& val) {
  if (val < 0) {
    val = 16 / 9.f;
  }
}

void ValidateSongsPerPlay(int& val) { rage_clamp(val, 0, MAX_SONGS_PER_PLAY); }

PrefsManager::PrefsManager()
    : m_sCurrentGame("CurrentGame", ""),

      m_sAnnouncer("Announcer", ""),
      m_sTheme("Theme", "Simply Love"),
      m_sDefaultModifiers("DefaultModifiers", ""),

      m_bWindowed("Windowed", true),
      m_sDisplayId("DisplayId", ""),
      m_iDisplayWidth("DisplayWidth", 1280),
      m_iDisplayHeight("DisplayHeight", 720),
      m_fDisplayAspectRatio(
          "DisplayAspectRatio", 16 / 9.f, ValidateDisplayAspectRatio),
      m_iDisplayColorDepth("DisplayColorDepth", 32),
      m_iTextureColorDepth("TextureColorDepth", 32),
      m_iMovieColorDepth("MovieColorDepth", 32),
      m_bStretchBackgrounds("StretchBackgrounds", false),
      m_BGFitMode("BackgroundFitMode", BFM_CoverPreserve),
      m_HighResolutionTextures(
          "HighResolutionTextures", HighResolutionTextures_ForceOn),
      m_iMaxTextureResolution("MaxTextureResolution", 2048),
      m_iRefreshRate("RefreshRate", REFRESH_DEFAULT),
      m_bAllowMultitexture("AllowMultitexture", true),
      m_bFullscreenIsBorderlessWindow("FullscreenIsBorderlessWindow", true),
      m_bShowStats("ShowStats", TRUE_IF_DEBUG),
      m_bShowBanners("ShowBanners", true),
      m_bShowMouseCursor("ShowMouseCursor", false),

      m_bHiddenSongs("HiddenSongs", false),
#if defined(__APPLE__)
      m_bVsync("Vsync", false),
#else
      m_bVsync("Vsync", true),
#endif
      m_FastNoteRendering("FastNoteRendering", false),
      m_bInterlaced("Interlaced", false),
      m_bPAL("PAL", false),
      m_bDelayedTextureDelete("DelayedTextureDelete", true),
      m_bDelayedModelDelete("DelayedModelDelete", false),
      m_ImageCache("ImageCache", IMGCACHE_LOW_RES_PRELOAD),
      m_bFastLoad("FastLoad", true),
      m_NeverCacheList("NeverCacheList", ""),

      m_bOnlyDedicatedMenuButtons("OnlyDedicatedMenuButtons", false),
      m_bMenuTimer("MenuTimer", false),

      m_fLifeDifficultyScale("LifeDifficultyScale", 1.0f),

      m_bRateModsAffectTweens("RateModsAffectFGChanges", false),

      m_iRegenComboAfterMiss("RegenComboAfterMiss", 5),
      m_iMaxRegenComboAfterMiss(
          "MaxRegenComboAfterMiss",
          5),  // this was 10 by default in SM3.95 -dguzek
      m_bMercifulDrain(
          "MercifulDrain", false),  // negative life deltas are scaled by the
                                    // players life percentage
      m_HarshHotLifePenalty("HarshHotLifePenalty", true),
      m_bMinimum1FullSongInCourses(
          "Minimum1FullSongInCourses",
          false),  // FEoS for 1st song, FailImmediate thereafter
      m_bFailOffInBeginner("FailOffInBeginner", false),
      m_bFailOffForFirstStageEasy("FailOffForFirstStageEasy", false),
      m_bMercifulBeginner("MercifulBeginner", false),
      m_bMercifulSuperMeter("MercifulSuperMeter", true),
      m_bDelayedBack("DelayedBack", true),
      m_AllowHoldForOptions("AllowHoldForOptions", true),
      m_bShowInstructions("ShowInstructions", true),
      m_bShowCaution("ShowCaution", true),
      m_bShowNativeLanguage("ShowNativeLanguage", true),
      m_iArcadeOptionsNavigation("ArcadeOptionsNavigation", 0),
      m_ThreeKeyNavigation("ThreeKeyNavigation", false),
      m_MusicWheelUsesSections(
          "MusicWheelUsesSections", MusicWheelUsesSections_ALWAYS),
      m_iMusicWheelSwitchSpeed("MusicWheelSwitchSpeed", 15),
      m_bRandomPrioritizeDifficulty("RandomPrioritizeDifficulty", false),
      m_AllowW1("AllowW1", ALLOW_W1_EVERYWHERE),
      m_bEventMode("EventMode", true),
      m_iCoinsPerCredit("CoinsPerCredit", 1),
      m_iMaxNumCredits("MaxNumCredits", 20),
      m_iSongsPerPlay("SongsPerPlay", 3, ValidateSongsPerPlay),
      m_bDelayedCreditsReconcile("DelayedCreditsReconcile", false),
      m_bComboContinuesBetweenSongs("ComboContinuesBetweenSongs", false),
      m_AllowMultipleToasties("AllowMultipleToasties", true),
      m_MinTNSToHideNotes("MinTNSToHideNotes", TNS_W3),
      m_ShowSongOptions("ShowSongOptions", Maybe_NO),
      m_bPercentageScoring("PercentageScoring", true),
      // Wow, these preference names are *seriously* long -Colby
      m_fMinPercentageForMachineSongHighScore(
          "MinPercentageForMachineSongHighScore",
          0.0001f),  // This is for home, who cares how bad you do?
      m_fMinPercentageForMachineCourseHighScore(
          "MinPercentageForMachineCourseHighScore",
          0.0001f),  // don't save course scores with 0 percentage
      m_bDisqualification("Disqualification", false),
      m_bAutogenSteps("AutogenSteps", false),
      m_bAutogenGroupCourses("AutogenGroupCourses", true),
      m_bOnlyPreferredDifficulties("OnlyPreferredDifficulties", false),
      m_bBreakComboToGetItem("BreakComboToGetItem", false),
      m_bLockCourseDifficulties("LockCourseDifficulties", false),
      m_ShowDancingCharacters("ShowDancingCharacters", SDC_Random),
      m_bUseUnlockSystem("UseUnlockSystem", false),
      m_fGlobalOffsetSeconds("GlobalOffsetSeconds", -0.008f),
      m_iGlobalOffsetProfileSelected("GlobalOffsetProfileSelected", 0),
      m_bGlobalOffsetProfilesInitialized(
          "GlobalOffsetProfilesInitialized", false),
      m_sGlobalOffsetProfile1Name("GlobalOffsetProfile1Name", ""),
      m_sGlobalOffsetProfile2Name("GlobalOffsetProfile2Name", ""),
      m_sGlobalOffsetProfile3Name("GlobalOffsetProfile3Name", ""),
      m_sGlobalOffsetProfile4Name("GlobalOffsetProfile4Name", ""),
      m_sGlobalOffsetProfile5Name("GlobalOffsetProfile5Name", ""),
      m_sGlobalOffsetProfile6Name("GlobalOffsetProfile6Name", ""),
      m_fGlobalOffsetProfile1Seconds("GlobalOffsetProfile1Seconds", 0.0f),
      m_fGlobalOffsetProfile2Seconds("GlobalOffsetProfile2Seconds", 0.0f),
      m_fGlobalOffsetProfile3Seconds("GlobalOffsetProfile3Seconds", 0.0f),
      m_fGlobalOffsetProfile4Seconds("GlobalOffsetProfile4Seconds", 0.0f),
      m_fGlobalOffsetProfile5Seconds("GlobalOffsetProfile5Seconds", 0.0f),
      m_fGlobalOffsetProfile6Seconds("GlobalOffsetProfile6Seconds", 0.0f),
      m_DefaultSyncOffset("DefaultSyncOffset", SyncOffset_ITG),
      m_iProgressiveLifebar("ProgressiveLifebar", 0),
      m_iProgressiveStageLifebar("ProgressiveStageLifebar", 0),
      m_iProgressiveNonstopLifebar("ProgressiveNonstopLifebar", 0),
      m_bShowBeginnerHelper("ShowBeginnerHelper", false),
      m_bDisableScreenSaver("DisableScreenSaver", true),
      m_sLanguage(
          "Language", ""),  // ThemeManager will deal with this invalid language
      m_sMemoryCardProfileSubdir("MemoryCardProfileSubdir", PRODUCT_ID),
      m_iProductID("ProductID", 1),
      m_iCenterImageTranslateX("CenterImageTranslateX", 0),
      m_iCenterImageTranslateY("CenterImageTranslateY", 0),
      m_fCenterImageAddWidth("CenterImageAddWidth", 0),
      m_fCenterImageAddHeight("CenterImageAddHeight", 0),
      m_AttractSoundFrequency("AttractSoundFrequency", ASF_EVERY_TIME),
      m_bAllowExtraStage("AllowExtraStage", false),
      m_iMaxHighScoresPerListForMachine("MaxHighScoresPerListForMachine", 10),
      m_iMaxHighScoresPerListForPlayer("MaxHighScoresPerListForPlayer", 3),
      m_bAllowMultipleHighScoreWithSameName(
          "AllowMultipleHighScoreWithSameName", true),
      m_DisableUploadDir("DisableUploadDir", true),
      m_bCelShadeModels(
          "CelShadeModels", false),  // Work-In-Progress.. disable by default.
      m_bPreferredSortUsesGroups("PreferredSortUsesGroups", true),
      m_fDebounceCoinInputTime("DebounceCoinInputTime", 0),
      m_bResetCoinsAtStartup("ResetCoinsAtStartup", false),

      m_fPadStickSeconds("PadStickSeconds", 0),
      m_EditRecordModeLeadIn("EditRecordModeLeadIn", 1.0f),
      m_EditClearPromptThreshold("EditClearPromptThreshold", 50),
      m_bForceMipMaps("ForceMipMaps", false),
      m_bTrilinearFiltering("TrilinearFiltering", false),
      m_bAnisotropicFiltering("AnisotropicFiltering", false),

      m_bSignProfileData("SignProfileData", false),
      m_ProfileSortOrder("ProfileSortOrder", ProfileSortOrder_Priority),
      m_bProfileSortOrderAscending("ProfileSortOrderAscending", true),
      m_CourseSortOrder("CourseSortOrder", COURSE_SORT_SONGS),
      m_bSubSortByNumSteps("SubSortByNumSteps", false),
      m_GetRankingName("GetRankingName", RANKING_ON),
      m_sAdditionalSongFoldersReadOnly(
          "AdditionalSongFoldersReadOnly", "", nullptr,
          PreferenceType::Immutable),
      m_sAdditionalSongFoldersWritable(
          "AdditionalSongFoldersWritable", "", nullptr,
          PreferenceType::Immutable),
      m_sAdditionalCourseFoldersReadOnly(
          "AdditionalCourseFoldersReadOnly", "", nullptr,
          PreferenceType::Immutable),
      m_sAdditionalCourseFoldersWritable(
          "AdditionalCourseFoldersWritable", "", nullptr,
          PreferenceType::Immutable),
      m_sAdditionalFoldersReadOnly(
          "AdditionalFoldersReadOnly", "", nullptr, PreferenceType::Immutable),
      m_sAdditionalFoldersWritable(
          "AdditionalFoldersWritable", "", nullptr, PreferenceType::Immutable),
      m_sDefaultTheme("DefaultTheme", "Simply Love"),
      m_sLastSeenVideoDriver("LastSeenVideoDriver", ""),
      m_sVideoRenderers(
          "VideoRenderers", ""),  // StepMania.cpp sets these on first run:
      m_bSmoothLines("SmoothLines", true),
      // Stability-first default for online/perf testing:
      // large write-ahead greatly reduces mixing underruns at the cost of latency.
      m_iSoundWriteAhead("SoundWriteAhead", 32768),
      m_iSoundDevice("SoundDevice", ""),
      m_iSoundPreferredSampleRate("SoundPreferredSampleRate", 0),
      m_sLightsStepsDifficulty("LightsStepsDifficulty", "hard,medium"),
      m_bLightsSimplifyBass("LightsSimplifyBass", false),
      m_bLightsBassParallel("LightsBassParallel", false),
      m_bAllowUnacceleratedRenderer("AllowUnacceleratedRenderer", false),
      m_bThreadedInput("ThreadedInput", true),
      m_bThreadedMovieDecode("ThreadedMovieDecode", true),
      m_sTestInitialScreen("TestInitialScreen", ""),
      m_bDebugLights("DebugLights", false),
      m_bMonkeyInput("MonkeyInput", false),
      m_sMachineName("MachineName", ""),
      m_sCoursesToShowRanking("CoursesToShowRanking", ""),
      m_MuteActions("MuteActions", false),
      m_bAllowSongDeletion("AllowSongDeletion", false),

      m_bQuirksMode("QuirksMode", false),

      m_custom_songs_enable("CustomSongsEnable", false),
      m_custom_songs_max_count(
          "CustomSongsMaxCount", 1000),  // No limit. -- 2 Unlimited
      m_custom_songs_load_timeout("CustomSongsLoadTimeout", 5.f),
      m_custom_songs_max_seconds("CustomSongsMaxSeconds", 120.f),
      m_custom_songs_max_megabytes("CustomSongsMaxMegabytes", 5.f),

      /* Debug: */
      m_bDebugMenuEnabled(
          "DebugMenuEnabled", true, nullptr, PreferenceType::Immutable),
      m_bLogToDisk("LogToDisk", true),
#if defined(DEBUG)
      m_bForceLogFlush("ForceLogFlush", true),
      m_bShowLogOutput("ShowLogOutput", true),
#else
      m_bForceLogFlush("ForceLogFlush", true),
      m_bShowLogOutput("ShowLogOutput", true),
#endif
      m_bShowPopups("ShowPopups", false),
      m_bLogSkips("LogSkips", true),
      m_bLogCheckpoints("LogCheckpoints", true),
      m_bShowLoadingWindow("ShowLoadingWindow", true),
      m_bPseudoLocalize("PseudoLocalize", false),
      m_show_theme_errors("ShowThemeErrors", false),
      m_sAdditionalSongFolders(
          "AdditionalSongFolders", "", nullptr, PreferenceType::Deprecated),
      m_sAdditionalCourseFolders(
          "AdditionalCourseFolders", "", nullptr, PreferenceType::Deprecated),
      m_sAdditionalFolders(
          "AdditionalFolders", "", nullptr, PreferenceType::Deprecated) {
  Init();
  InitializeGlobalOffsetProfileStorage();
  ReadPrefsFromDisk();

  // Register with Lua.
  {
    Lua* L = LUA->Get();
    lua_pushstring(L, "PREFSMAN");
    this->PushSelf(L);
    lua_settable(L, LUA_GLOBALSINDEX);
    LUA->Release(L);
  }
}
#undef TRUE_IF_DEBUG

void PrefsManager::Init() {
  IPreference::LoadAllDefaults();

  m_mapGameNameToGamePrefs.clear();
}

PrefsManager::~PrefsManager() {
  if (LOG) {
    LOG->Trace("PrefsManager::~PrefsManager begin");
  }
  // Unregister with Lua.
  LUA->UnsetGlobal("PREFSMAN");
  if (LOG) {
    LOG->Trace("PrefsManager::~PrefsManager end");
  }
}

void PrefsManager::SetCurrentGame(const std::string& sGame) {
  if (m_sCurrentGame.Get() == sGame) {
    return;  // redundant
  }

  if (!m_sCurrentGame.Get().empty()) {
    StoreGamePrefs();
  }

  m_sCurrentGame.Set(sGame);

  RestoreGamePrefs();
}

void PrefsManager::StoreGamePrefs() {
  ASSERT(!m_sCurrentGame.Get().empty());

  // save off old values
  GamePrefs& gp = m_mapGameNameToGamePrefs[m_sCurrentGame.Get()];
  gp.m_sAnnouncer = m_sAnnouncer;
  gp.m_sTheme = m_sTheme;
  gp.m_sDefaultModifiers = m_sDefaultModifiers;
}

void PrefsManager::RestoreGamePrefs() {
  ASSERT(!m_sCurrentGame.Get().empty());

  // load prefs
  GamePrefs gp;
  std::map<std::string, GamePrefs>::const_iterator iter =
      m_mapGameNameToGamePrefs.find(m_sCurrentGame);
  if (iter != m_mapGameNameToGamePrefs.end()) {
    gp = iter->second;
  }

  m_sAnnouncer.Set(gp.m_sAnnouncer);
  m_sTheme.Set(gp.m_sTheme);
  m_sDefaultModifiers.Set(gp.m_sDefaultModifiers);

  // give Static.ini a chance to clobber the saved game prefs
  ReadPrefsFromFile(
      SpecialFiles::STATIC_INI_PATH, GetPreferencesSection(), true);
}

PrefsManager::GamePrefs::GamePrefs()
    : m_sAnnouncer(""),
      m_sTheme(SpecialFiles::BASE_THEME_NAME),
      m_sDefaultModifiers("") {}

int PrefsManager::GetGlobalOffsetProfileCount() const {
  return NUM_GLOBAL_OFFSET_PROFILES;
}

void PrefsManager::InitializeGlobalOffsetProfileStorage() {
  m_pGlobalOffsetProfileNames[0] = &m_sGlobalOffsetProfile1Name;
  m_pGlobalOffsetProfileNames[1] = &m_sGlobalOffsetProfile2Name;
  m_pGlobalOffsetProfileNames[2] = &m_sGlobalOffsetProfile3Name;
  m_pGlobalOffsetProfileNames[3] = &m_sGlobalOffsetProfile4Name;
  m_pGlobalOffsetProfileNames[4] = &m_sGlobalOffsetProfile5Name;
  m_pGlobalOffsetProfileNames[5] = &m_sGlobalOffsetProfile6Name;

  m_pGlobalOffsetProfileSeconds[0] = &m_fGlobalOffsetProfile1Seconds;
  m_pGlobalOffsetProfileSeconds[1] = &m_fGlobalOffsetProfile2Seconds;
  m_pGlobalOffsetProfileSeconds[2] = &m_fGlobalOffsetProfile3Seconds;
  m_pGlobalOffsetProfileSeconds[3] = &m_fGlobalOffsetProfile4Seconds;
  m_pGlobalOffsetProfileSeconds[4] = &m_fGlobalOffsetProfile5Seconds;
  m_pGlobalOffsetProfileSeconds[5] = &m_fGlobalOffsetProfile6Seconds;
}

int PrefsManager::ClampGlobalOffsetProfileIndex(int index) const {
  return std::max(0, std::min(index, NUM_GLOBAL_OFFSET_PROFILES - 1));
}

float PrefsManager::SanitizeGlobalOffsetSeconds(
    float seconds, const char* source) const {
  if (!std::isfinite(seconds)) {
    const float fallback_seconds = std::isfinite(m_fGlobalOffsetSeconds.Get())
                                       ? m_fGlobalOffsetSeconds.Get()
                                       : DEFAULT_GLOBAL_OFFSET_SECONDS;
    if (LOG != nullptr) {
      LOG->Warn(
          "GLOBAL_OFFSET_TRACE: rejected non-finite offset source='%s' value=%.6f "
          "fallback_runtime_seconds=%.6f",
          source == nullptr ? "unknown" : source, seconds, fallback_seconds);
    }
    return fallback_seconds;
  }

  const float clamped =
      std::max(MIN_GLOBAL_OFFSET_SECONDS,
               std::min(seconds, MAX_GLOBAL_OFFSET_SECONDS));
  if (clamped != seconds && LOG != nullptr) {
    LOG->Warn(
        "GLOBAL_OFFSET_TRACE: clamped offset source='%s' requested_seconds=%.6f "
        "clamped_seconds=%.6f min_seconds=%.6f max_seconds=%.6f",
        source == nullptr ? "unknown" : source, seconds, clamped,
        MIN_GLOBAL_OFFSET_SECONDS, MAX_GLOBAL_OFFSET_SECONDS);
  }
  return clamped;
}

void PrefsManager::LogGlobalOffsetDiagnostics(
    const std::string& reason) const {
  if (!LogGlobalOffsetDiagnosticsEnabled() || LOG == nullptr) {
    return;
  }

  const int selected = GetGlobalOffsetProfileSelected();
  LOG->Trace(
      "GLOBAL_OFFSET_TRACE: reason='%s' selected=%d runtime_seconds=%.6f "
      "initialized=%d raw_selected=%d profile_count=%d",
      reason.c_str(), selected, m_fGlobalOffsetSeconds.Get(),
      m_bGlobalOffsetProfilesInitialized.Get() ? 1 : 0,
      m_iGlobalOffsetProfileSelected.Get(), NUM_GLOBAL_OFFSET_PROFILES);

  for (int i = 0; i < NUM_GLOBAL_OFFSET_PROFILES; ++i) {
    LOG->Trace(
        "GLOBAL_OFFSET_TRACE: reason='%s' slot=%d active=%d name='%s' "
        "seconds=%.6f ms=%d",
        reason.c_str(), i, i == selected ? 1 : 0,
        GetGlobalOffsetProfileName(i).c_str(), GetGlobalOffsetProfileSeconds(i),
        static_cast<int>(std::round(GetGlobalOffsetProfileSeconds(i) * 1000.0f)));
  }
}

int PrefsManager::GetGlobalOffsetProfileSelected() const {
  int index = m_iGlobalOffsetProfileSelected;
  return ClampGlobalOffsetProfileIndex(index);
}

Preference<std::string>& PrefsManager::GetMutableGlobalOffsetProfileName(
    int index) {
  return *m_pGlobalOffsetProfileNames[ClampGlobalOffsetProfileIndex(index)];
}

const Preference<std::string>&
PrefsManager::GetGlobalOffsetProfileNamePreference(int index) const {
  return *m_pGlobalOffsetProfileNames[ClampGlobalOffsetProfileIndex(index)];
}

Preference<float>& PrefsManager::GetMutableGlobalOffsetProfileSeconds(
    int index) {
  return *m_pGlobalOffsetProfileSeconds[ClampGlobalOffsetProfileIndex(index)];
}

const Preference<float>& PrefsManager::GetGlobalOffsetProfileSecondsPreference(
    int index) const {
  return *m_pGlobalOffsetProfileSeconds[ClampGlobalOffsetProfileIndex(index)];
}

std::string PrefsManager::GetGlobalOffsetProfileName(int index) const {
  return GetGlobalOffsetProfileNamePreference(index).Get();
}

void PrefsManager::SetGlobalOffsetProfileName(
    int index, const std::string& name) {
  const int requested_index = index;
  index = ClampGlobalOffsetProfileIndex(index);
  const std::string old_name = GetGlobalOffsetProfileName(index);
  std::string trimmed = name;
  Trim(trimmed);
  if (trimmed.empty()) {
    trimmed = index == 0 ? "Default" : ssprintf("Offset %d", index + 1);
  }
  GetMutableGlobalOffsetProfileName(index).Set(trimmed);
  if (LogGlobalOffsetDiagnosticsEnabled() && LOG != nullptr) {
    LOG->Trace(
        "GLOBAL_OFFSET_TRACE: profile_name_set requested_index=%d index=%d "
        "old='%s' new='%s'",
        requested_index, index, old_name.c_str(), trimmed.c_str());
  }
  LogGlobalOffsetDiagnostics("profile_name_set");
}

float PrefsManager::GetGlobalOffsetProfileSeconds(int index) const {
  return GetGlobalOffsetProfileSecondsPreference(index).Get();
}

void PrefsManager::SetGlobalOffsetProfileSeconds(int index, float seconds) {
  const int requested_index = index;
  index = ClampGlobalOffsetProfileIndex(index);
  seconds = SanitizeGlobalOffsetSeconds(seconds, "profile_seconds_set");
  const float old_profile_seconds = GetGlobalOffsetProfileSeconds(index);
  const float old_runtime_seconds = m_fGlobalOffsetSeconds.Get();
  GetMutableGlobalOffsetProfileSeconds(index).Set(seconds);
  if (GetGlobalOffsetProfileSelected() == index) {
    m_fGlobalOffsetSeconds.Set(seconds);
  }
  if (LogGlobalOffsetDiagnosticsEnabled() && LOG != nullptr) {
    LOG->Trace(
        "GLOBAL_OFFSET_TRACE: profile_seconds_set requested_index=%d index=%d "
        "old_profile_seconds=%.6f new_profile_seconds=%.6f "
        "old_runtime_seconds=%.6f new_runtime_seconds=%.6f active=%d",
        requested_index, index, old_profile_seconds, seconds, old_runtime_seconds,
        m_fGlobalOffsetSeconds.Get(),
        GetGlobalOffsetProfileSelected() == index ? 1 : 0);
  }
  LogGlobalOffsetDiagnostics("profile_seconds_set");
}

void PrefsManager::SetGlobalOffsetSeconds(float seconds) {
  seconds = SanitizeGlobalOffsetSeconds(seconds, "runtime_seconds_set");
  const float old_runtime_seconds = m_fGlobalOffsetSeconds.Get();
  const int selected = GetGlobalOffsetProfileSelected();
  const float old_profile_seconds = GetGlobalOffsetProfileSeconds(selected);
  m_fGlobalOffsetSeconds.Set(seconds);
  SyncActiveGlobalOffsetProfileFromCurrentOffset();
  if (LogGlobalOffsetDiagnosticsEnabled() && LOG != nullptr) {
    LOG->Trace(
        "GLOBAL_OFFSET_TRACE: runtime_seconds_set selected=%d "
        "old_runtime_seconds=%.6f new_runtime_seconds=%.6f "
        "old_profile_seconds=%.6f new_profile_seconds=%.6f",
        selected, old_runtime_seconds, m_fGlobalOffsetSeconds.Get(),
        old_profile_seconds, GetGlobalOffsetProfileSeconds(selected));
  }
  LogGlobalOffsetDiagnostics("runtime_seconds_set");
}

void PrefsManager::SyncActiveGlobalOffsetProfileFromCurrentOffset() {
  const int selected = GetGlobalOffsetProfileSelected();
  const float old_profile_seconds = GetGlobalOffsetProfileSeconds(selected);
  GetMutableGlobalOffsetProfileSeconds(GetGlobalOffsetProfileSelected())
      .Set(m_fGlobalOffsetSeconds.Get());
  if (LogGlobalOffsetDiagnosticsEnabled() && LOG != nullptr) {
    LOG->Trace(
        "GLOBAL_OFFSET_TRACE: active_profile_sync selected=%d "
        "old_profile_seconds=%.6f runtime_seconds=%.6f",
        selected, old_profile_seconds, m_fGlobalOffsetSeconds.Get());
  }
}

void PrefsManager::SetGlobalOffsetProfileSelected(int index) {
  const int requested_index = index;
  const int old_selected = GetGlobalOffsetProfileSelected();
  const float old_runtime_seconds = m_fGlobalOffsetSeconds.Get();
  index = ClampGlobalOffsetProfileIndex(index);
  m_iGlobalOffsetProfileSelected.Set(index);
  m_fGlobalOffsetSeconds.Set(GetGlobalOffsetProfileSeconds(index));
  if (LogGlobalOffsetDiagnosticsEnabled() && LOG != nullptr) {
    LOG->Trace(
        "GLOBAL_OFFSET_TRACE: profile_selected requested_index=%d "
        "old_selected=%d new_selected=%d old_runtime_seconds=%.6f "
        "new_runtime_seconds=%.6f name='%s'",
        requested_index, old_selected, index, old_runtime_seconds,
        m_fGlobalOffsetSeconds.Get(), GetGlobalOffsetProfileName(index).c_str());
  }
  LogGlobalOffsetDiagnostics("profile_selected");
}

void PrefsManager::InitializeGlobalOffsetProfiles() {
  const bool first_profile_migration = !m_bGlobalOffsetProfilesInitialized.Get();
  if (LogGlobalOffsetDiagnosticsEnabled() && LOG != nullptr) {
    LOG->Trace(
        "GLOBAL_OFFSET_TRACE: initialize_begin first_migration=%d "
        "runtime_seconds=%.6f raw_selected=%d",
        first_profile_migration ? 1 : 0, m_fGlobalOffsetSeconds.Get(),
        m_iGlobalOffsetProfileSelected.Get());
  }

  for (int i = 0; i < NUM_GLOBAL_OFFSET_PROFILES; ++i) {
    std::string name = GetGlobalOffsetProfileName(i);
    Trim(name);
    if (name.empty()) {
      SetGlobalOffsetProfileName(
          i, i == 0 ? "Default" : ssprintf("Offset %d", i + 1));
    }

    const std::string source = ssprintf("initialize_profile_%d", i + 1);
    const float sanitized_seconds = SanitizeGlobalOffsetSeconds(
        GetGlobalOffsetProfileSeconds(i), source.c_str());
    if (sanitized_seconds != GetGlobalOffsetProfileSeconds(i)) {
      GetMutableGlobalOffsetProfileSeconds(i).Set(sanitized_seconds);
    }
  }

  int selected = GetGlobalOffsetProfileSelected();
  if (m_iGlobalOffsetProfileSelected.Get() != selected) {
    m_iGlobalOffsetProfileSelected.Set(selected);
  }

  if (first_profile_migration) {
    m_fGlobalOffsetProfile1Seconds.Set(
        SanitizeGlobalOffsetSeconds(
            m_fGlobalOffsetSeconds.Get(), "legacy_profile_migration"));
    m_bGlobalOffsetProfilesInitialized.Set(true);
    if (LogGlobalOffsetDiagnosticsEnabled() && LOG != nullptr) {
      LOG->Trace(
          "GLOBAL_OFFSET_TRACE: migrate_legacy_runtime_to_slot1 "
          "seconds=%.6f",
          m_fGlobalOffsetSeconds.Get());
    }
  }

  m_fGlobalOffsetSeconds.Set(
      SanitizeGlobalOffsetSeconds(
          GetGlobalOffsetProfileSeconds(selected), "initialize_active_profile"));
  LogGlobalOffsetDiagnostics("initialize_end");
}

void PrefsManager::ReadPrefsFromDisk() {
  if (LogGlobalOffsetDiagnosticsEnabled() && LOG != nullptr) {
    LOG->Trace("GLOBAL_OFFSET_TRACE: read_prefs_from_disk_begin");
  }
  ReadDefaultsFromFile(
      SpecialFiles::DEFAULTS_INI_PATH, GetPreferencesSection());
  IPreference::LoadAllDefaults();

  ReadPrefsFromFile(SpecialFiles::PREFERENCES_INI_PATH, "Options", false);
  ReadGamePrefsFromIni(SpecialFiles::PREFERENCES_INI_PATH);
  ReadPrefsFromFile(
      SpecialFiles::STATIC_INI_PATH, GetPreferencesSection(), true);

  TranslateDeprecatedFlags();

  if (!m_sCurrentGame.Get().empty()) {
    RestoreGamePrefs();
  }

  RefreshPerfDiagnosticsPreferenceCache();
  InitializeGlobalOffsetProfiles();
  LogGlobalOffsetDiagnostics("read_prefs_from_disk_end");
}

void PrefsManager::ResetToFactoryDefaults() {
  // clobber the users prefs by initing then applying defaults
  Init();
  IPreference::LoadAllDefaults();
  ReadPrefsFromFile(
      SpecialFiles::STATIC_INI_PATH, GetPreferencesSection(), true);

  TranslateDeprecatedFlags();
  InitializeGlobalOffsetProfiles();
  LogGlobalOffsetDiagnostics("reset_to_factory_defaults_before_save");

  SavePrefsToDisk();
}

void PrefsManager::ReadPrefsFromFile(
    const std::string& sIni, const std::string& sSection, bool bIsStatic) {
  if (!DoesFileExist(sIni)) {
    return;
  }

  IniFile ini;
  if (!ini.ReadFile(sIni)) {
    return;
  }

  ReadPrefsFromIni(ini, sSection, bIsStatic);
}

static const std::string GAME_SECTION_PREFIX = "Game-";

void PrefsManager::ReadPrefsFromIni(
    const IniFile& ini, const std::string& sSection, bool bIsStatic) {
  // Apply our fallback recursively (if any) before applying ourself.
  static int s_iDepth = 0;
  s_iDepth++;
  ASSERT(s_iDepth < 100);
  std::string sFallback;
  if (ini.GetValue(sSection, "Fallback", sFallback)) {
    ReadPrefsFromIni(ini, sFallback, bIsStatic);
  }
  s_iDepth--;

  /*
  IPreference *pPref = PREFSMAN->GetPreferenceByName( *sName );
  if( pPref == nullptr )
  {
          LOG->Warn( "Unknown preference in [%s]: %s", sClassName.c_str(),
  sName->c_str() ); continue;
  }
  pPref->FromString( sVal );
  */

  const XNode* pChild = ini.GetChild(sSection);
  if (pChild) {
    IPreference::ReadAllPrefsFromNode(pChild, bIsStatic);
  }
}

void PrefsManager::ReadGamePrefsFromIni(const std::string& sIni) {
  IniFile ini;
  if (!ini.ReadFile(sIni)) {
    return;
  }

  FOREACH_CONST_Child(&ini, section) {
    std::string section_name = section->GetName();
    if (!BeginsWith(section_name, GAME_SECTION_PREFIX)) {
      continue;
    }

    std::string sGame = Right(
        section_name, section_name.length() - GAME_SECTION_PREFIX.length());
    GamePrefs& gp = m_mapGameNameToGamePrefs[sGame];

    // todo: read more prefs here? -aj
    ini.GetValue(section_name, "Announcer", gp.m_sAnnouncer);
    ini.GetValue(section_name, "Theme", gp.m_sTheme);
    ini.GetValue(section_name, "DefaultModifiers", gp.m_sDefaultModifiers);
  }
}

void PrefsManager::ReadDefaultsFromFile(
    const std::string& sIni, const std::string& sSection) {
  if (!DoesFileExist(sIni)) {
    return;
  }

  IniFile ini;
  if (!ini.ReadFile(sIni)) {
    return;
  }

  ReadDefaultsFromIni(ini, sSection);
}

void PrefsManager::ReadDefaultsFromIni(
    const IniFile& ini, const std::string& sSection) {
  // Apply our fallback recursively (if any) before applying ourself.
  // TODO: detect circular?
  std::string sFallback;
  if (ini.GetValue(sSection, "Fallback", sFallback)) {
    ReadDefaultsFromIni(ini, sFallback);
  }

  IPreference::ReadAllDefaultsFromNode(ini.GetChild(sSection));
}

void PrefsManager::TranslateDeprecatedFlags() {
  if (!m_sAdditionalFolders.Get().empty()) {
    m_sAdditionalFoldersWritable.Set(m_sAdditionalFolders.Get());
  }
  if (!m_sAdditionalSongFolders.Get().empty()) {
    m_sAdditionalSongFoldersWritable.Set(m_sAdditionalSongFolders.Get());
  }
  if (!m_sAdditionalCourseFolders.Get().empty()) {
    m_sAdditionalCourseFoldersWritable.Set(m_sAdditionalCourseFolders.Get());
  }
}

bool PrefsManager::SavePrefsToDisk() {
  LogGlobalOffsetDiagnostics("save_prefs_to_disk_begin");
  IniFile ini;
  SavePrefsToIni(ini);
  const bool bSaved = ini.WriteFile(SpecialFiles::PREFERENCES_INI_PATH);
  if (!bSaved && LOG != nullptr) {
    LOG->Warn(
        "PrefsManager: failed to write %s.",
        SpecialFiles::PREFERENCES_INI_PATH.c_str());
  }
  LogGlobalOffsetDiagnostics("save_prefs_to_disk_end");
  return bSaved;
}

void PrefsManager::SavePrefsToIni(IniFile& ini) {
  if (!m_sCurrentGame.Get().empty()) {
    StoreGamePrefs();
  }

  XNode* pNode = ini.GetChild("Options");
  if (pNode == nullptr) {
    pNode = ini.AppendChild("Options");
  }
  IPreference::SavePrefsToNode(pNode);

  for (const auto& iter : m_mapGameNameToGamePrefs) {
    std::string sSection = "Game-" + std::string(iter.first);

    // todo: write more values here? -aj
    ini.SetValue(sSection, "Announcer", iter.second.m_sAnnouncer);
    ini.SetValue(sSection, "Theme", iter.second.m_sTheme);
    ini.SetValue(sSection, "DefaultModifiers", iter.second.m_sDefaultModifiers);
  }
}

std::string PrefsManager::GetPreferencesSection() const {
  std::string sSection = "Options";

  // OK if this fails
  GetFileContents(SpecialFiles::TYPE_TXT_FILE, sSection, true);

  // OK if this fails
  GetCommandlineArgument("Type", &sSection);

  return sSection;
}

// lua start
#include "LuaBinding.h"

/** @brief Allow Lua to have access to the PrefsManager. */
class LunaPrefsManager : public Luna<PrefsManager> {
 public:
  static int GetPreference(T* p, lua_State* L) {
    std::string sName = SArg(1);
    IPreference* pPref = IPreference::GetPreferenceByName(sName);
    if (pPref == nullptr) {
      LuaHelpers::ReportScriptErrorFmt(
          "GetPreference: unknown preference \"%s\"", sName.c_str());
      lua_pushnil(L);
      return 1;
    }

    pPref->PushValue(L);
    return 1;
  }
  static int SetPreference(T* p, lua_State* L) {
    std::string sName = SArg(1);

    IPreference* pPref = IPreference::GetPreferenceByName(sName);
    if (pPref == nullptr) {
      LuaHelpers::ReportScriptErrorFmt(
          "SetPreference: unknown preference \"%s\"", sName.c_str());
      COMMON_RETURN_SELF;
    } else if (pPref->IsImmutable()) {
      LuaHelpers::ReportScriptErrorFmt(
          "SetPreference: preference \"%s\" is immutable", sName.c_str());
      COMMON_RETURN_SELF;
    }

    if (CompareNoCase(sName, "GlobalOffsetSeconds") == 0) {
      p->SetGlobalOffsetSeconds(FArg(2));
    } else {
      lua_pushvalue(L, 2);
      pPref->SetFromStack(L);
    }
    COMMON_RETURN_SELF;
  }
  static int SetPreferenceToDefault(T* p, lua_State* L) {
    std::string sName = SArg(1);

    IPreference* pPref = IPreference::GetPreferenceByName(sName);
    if (pPref == nullptr) {
      LuaHelpers::ReportScriptErrorFmt(
          "SetPreferenceToDefault: unknown preference \"%s\"", sName.c_str());
      COMMON_RETURN_SELF;
    } else if (pPref->IsImmutable()) {
      LuaHelpers::ReportScriptErrorFmt(
          "SetPreference: preference \"%s\" is immutable", sName.c_str());
      COMMON_RETURN_SELF;
    }

    pPref->LoadDefault();
    if (CompareNoCase(sName, "GlobalOffsetSeconds") == 0) {
      p->SyncActiveGlobalOffsetProfileFromCurrentOffset();
    }
    LOG->Trace(
        "Restored preference \"%s\" to default \"%s\"", sName.c_str(),
        pPref->ToString().c_str());
    COMMON_RETURN_SELF;
  }
  static int PreferenceExists(T* p, lua_State* L) {
    std::string sName = SArg(1);

    IPreference* pPref = IPreference::GetPreferenceByName(sName);
    if (pPref == nullptr) {
      lua_pushboolean(L, false);
      return 1;
    }
    lua_pushboolean(L, true);
    return 1;
  }

  static int SavePreferences(T* p, lua_State* L) {
    p->SavePrefsToDisk();
    COMMON_RETURN_SELF;
  }

  static int GetGlobalOffsetProfileCount(T* p, lua_State* L) {
    lua_pushnumber(L, p->GetGlobalOffsetProfileCount());
    return 1;
  }

  static int GetGlobalOffsetProfileSelected(T* p, lua_State* L) {
    lua_pushnumber(L, p->GetGlobalOffsetProfileSelected());
    return 1;
  }

  static int SetGlobalOffsetProfileSelected(T* p, lua_State* L) {
    p->SetGlobalOffsetProfileSelected(IArg(1));
    COMMON_RETURN_SELF;
  }

  static int GetGlobalOffsetProfileName(T* p, lua_State* L) {
    lua_pushstring(L, p->GetGlobalOffsetProfileName(IArg(1)).c_str());
    return 1;
  }

  static int SetGlobalOffsetProfileName(T* p, lua_State* L) {
    p->SetGlobalOffsetProfileName(IArg(1), SArg(2));
    COMMON_RETURN_SELF;
  }

  static int GetGlobalOffsetProfileSeconds(T* p, lua_State* L) {
    lua_pushnumber(L, p->GetGlobalOffsetProfileSeconds(IArg(1)));
    return 1;
  }

  static int SetGlobalOffsetProfileSeconds(T* p, lua_State* L) {
    p->SetGlobalOffsetProfileSeconds(IArg(1), FArg(2));
    COMMON_RETURN_SELF;
  }

  static int SetGlobalOffsetSeconds(T* p, lua_State* L) {
    p->SetGlobalOffsetSeconds(FArg(1));
    COMMON_RETURN_SELF;
  }
  static int LogGlobalOffsetDiagnostics(T* p, lua_State* L) {
    p->LogGlobalOffsetDiagnostics(SArg(1));
    COMMON_RETURN_SELF;
  }

  LunaPrefsManager() {
    ADD_METHOD(GetPreference);
    ADD_METHOD(SetPreference);
    ADD_METHOD(SetPreferenceToDefault);
    ADD_METHOD(PreferenceExists);
    ADD_METHOD(SavePreferences);
    ADD_METHOD(GetGlobalOffsetProfileCount);
    ADD_METHOD(GetGlobalOffsetProfileSelected);
    ADD_METHOD(SetGlobalOffsetProfileSelected);
    ADD_METHOD(GetGlobalOffsetProfileName);
    ADD_METHOD(SetGlobalOffsetProfileName);
    ADD_METHOD(GetGlobalOffsetProfileSeconds);
    ADD_METHOD(SetGlobalOffsetProfileSeconds);
    ADD_METHOD(SetGlobalOffsetSeconds);
    ADD_METHOD(LogGlobalOffsetDiagnostics);
  }
};

LUA_REGISTER_CLASS(PrefsManager)
// lua end

/*
 * (c) 2001-2004 Chris Danford, Chris Gomez
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
