#include "MusicWheel.h"

#include <algorithm>
#include <cstddef>
#include <cmath>
#include <map>
#include <set>
#include <string>
#include <vector>

#include "Command.h"
#include "CommonMetrics.h"
#include "Course.h"
#include "CourseUtil.h"
#include "Difficulty.h"
#include "EnumHelper.h"
#include "GameCommand.h"
#include "GameConstantsAndTypes.h"
#include "GameManager.h"
#include "GameState.h"
#include "Group.h"
#include "LocalizedString.h"
#include "LuaManager.h"
#include "MessageManager.h"
#include "MusicWheelItem.h"
#include "PlayerNumber.h"
#include "Preference.h"
#include "PrefsManager.h"
#include "ProfileManager.h"
#include "RageLog.h"
#include "RageTimer.h"
#include "RageTypes.h"
#include "RageUtil.h"
#include "RageUtil/RandomNumbers.h"
#include "RageUtil_AutoPtr.h"
#include "ScreenManager.h"
#include "ScreenMessage.h"
#include "Song.h"
#include "SongManager.h"
#include "SongUtil.h"
#include "Steps.h"
#include "Style.h"
#include "ThemeManager.h"
#include "UnlockManager.h"
#include "WheelBase.h"
#include "WheelItemBase.h"
#include "global.h"

static Preference<bool> g_bMoveRandomToEnd("MoveRandomToEnd", false);
static Preference<bool> g_bPrecacheAllSorts("PreCacheAllWheelSorts", false);

namespace {
constexpr int MAX_SECTION_COLORS = 256;
constexpr int MAX_VISIBLE_RECENT_OR_POPULAR = 1000;
constexpr int MAX_ROULETTE_SLOWDOWN_SWITCHES = 5;
constexpr float MIN_ROULETTE_SWITCH_SECONDS = 0.001f;

void WarnMusicWheel(const std::string& message) {
  if (LOG != nullptr) {
    LOG->Warn("MusicWheel: %s", message.c_str());
  }
}

bool IsValidSortOrderValue(SortOrder so) {
  return so >= SORT_PREFERRED && so < NUM_SortOrder;
}

int ClampListLimit(int value, int size) {
  if (value < 0) {
    return 0;
  }
  return std::min(value, std::min(size, MAX_VISIBLE_RECENT_OR_POPULAR));
}

void TrimSongList(std::vector<Song*>& songs, int requestedLimit) {
  const int limit = ClampListLimit(requestedLimit, static_cast<int>(songs.size()));
  if (limit < static_cast<int>(songs.size())) {
    songs.erase(songs.begin() + limit, songs.end());
  }
}

std::string GetWheelText(const std::string& s) {
  if (THEME == nullptr) {
    return s;
  }
  return THEME->GetString("MusicWheel", ssprintf("%sText", s.c_str()));
}

std::string GetCustomWheelText(const std::string& s) {
  if (THEME == nullptr) {
    return s;
  }
  return THEME->GetString("MusicWheel", ssprintf("CustomItem%sText", s.c_str()));
}

void SplitNonEmpty(const std::string& value, std::vector<std::string>& out) {
  std::vector<std::string> splitValues;
  split(value, ",", splitValues);
  for (std::string& item : splitValues) {
    Trim(item);
    if (!item.empty()) {
      out.push_back(item);
    }
  }
}
}  // namespace

static std::string SECTION_COLORS_NAME(size_t i) {
  return ssprintf("SectionColor%d", int(i + 1));
}
static std::string CHOICE_NAME(std::string s) {
  return ssprintf("Choice%s", s.c_str());
}
static std::string CUSTOM_WHEEL_ITEM_NAME(std::string s) {
  return ssprintf("CustomWheelItem%s", s.c_str());
}
static std::string CUSTOM_WHEEL_ITEM_COLOR(std::string s) {
  return ssprintf("%sColor", s.c_str());
}

static LocalizedString EMPTY_STRING("MusicWheel", "Empty");

AutoScreenMessage(
    SM_SongChanged);  // TODO: Replace this with a Message and MESSAGEMAN
AutoScreenMessage(SM_SortOrderChanging);
AutoScreenMessage(SM_SortOrderChanged);

static SortOrder ForceAppropriateSort(PlayMode pm, SortOrder so) {
  switch (pm) {
    // in course modes, force a particular sort
    case PLAY_MODE_ONI:
      return SORT_ONI_COURSES;
    case PLAY_MODE_NONSTOP:
      return SORT_NONSTOP_COURSES;
    case PLAY_MODE_ENDLESS:
      return SORT_ENDLESS_COURSES;
    default:
      break;
  }

  // If we're not in a course mode, don't start in a course sort.
  switch (so) {
    case SORT_ONI_COURSES:
    case SORT_NONSTOP_COURSES:
    case SORT_ENDLESS_COURSES:
      so = SortOrder_Invalid;
      break;
    default:
      break;
  }

  return so;
}

MusicWheelItem* MusicWheel::MakeItem() { return new MusicWheelItem; }

const MusicWheelItemData* MusicWheel::GetCurWheelItemData(int i) const {
  if (i < 0 || i >= static_cast<int>(m_CurWheelItemData.size())) {
    return nullptr;
  }
  return dynamic_cast<const MusicWheelItemData*>(m_CurWheelItemData[i]);
}

MusicWheelItemData* MusicWheel::GetCurWheelItemData(int i) {
  if (i < 0 || i >= static_cast<int>(m_CurWheelItemData.size())) {
    return nullptr;
  }
  return dynamic_cast<MusicWheelItemData*>(m_CurWheelItemData[i]);
}

void MusicWheel::Update(float fDeltaTime) {
  WheelBase::Update(fDeltaTime);
  PostSongChangedIfVisualFocusChanged();
}

int MusicWheel::GetVisualFocusIndex() const {
  if (m_CurWheelItemData.empty()) {
    return -1;
  }

  int focusedIndex = std::clamp(
      m_iSelection, 0, static_cast<int>(m_CurWheelItemData.size()) - 1);
  if (std::isfinite(m_fPositionOffsetFromSelection)) {
    focusedIndex -=
        static_cast<int>(std::lround(m_fPositionOffsetFromSelection));
    wrap(focusedIndex, m_CurWheelItemData.size());
  }

  return focusedIndex;
}

const MusicWheelItemData* MusicWheel::GetVisualFocusItemData() const {
  return GetCurWheelItemData(GetVisualFocusIndex());
}

void MusicWheel::PostSongChangedIfVisualFocusChanged() {
  const int focusedIndex = GetVisualFocusIndex();
  if (focusedIndex == m_iLastPostedVisualFocusIndex) {
    return;
  }

  m_iLastPostedVisualFocusIndex = focusedIndex;
  if (SCREENMAN != nullptr) {
    SCREENMAN->PostMessageToTopScreen(SM_SongChanged, 0);
  }
}

WheelItemDataType MusicWheel::GetSelectedType() {
  const MusicWheelItemData* item = GetVisualFocusItemData();
  return item != nullptr ? item->m_Type : WheelItemDataType_Invalid;
}

Course* MusicWheel::GetSelectedCourse() {
  const MusicWheelItemData* item = GetVisualFocusItemData();
  return item != nullptr ? item->m_pCourse : nullptr;
}

std::string MusicWheel::GetSelectedSection() {
  const MusicWheelItemData* item = GetVisualFocusItemData();
  return item != nullptr ? item->m_sText : "";
}

SortOrder MusicWheel::GetSortOrder() const {
  return GetCurrentSortOrderOrDefault();
}

bool MusicWheel::WheelItemIsVisible(int n) const {
  return GetCurWheelItemData(n) != nullptr;
}

const Style* MusicWheel::GetCurrentWheelStyle(PlayerNumber pn) const {
  if (GAMESTATE == nullptr) {
    return nullptr;
  }
  return GAMESTATE->GetCurrentStyle(pn);
}

StepsType MusicWheel::GetCurrentWheelStepsType(PlayerNumber pn) const {
  const Style* style = GetCurrentWheelStyle(pn);
  return style != nullptr ? style->m_StepsType : StepsType_Invalid;
}

bool MusicWheel::IsValidSortOrderForWheel(SortOrder so) const {
  return IsValidSortOrderValue(so);
}

SortOrder MusicWheel::GetCurrentSortOrderOrDefault() const {
  if (GAMESTATE != nullptr && IsValidSortOrderForWheel(GAMESTATE->m_SortOrder)) {
    return GAMESTATE->m_SortOrder;
  }
  if (GAMESTATE != nullptr &&
      IsValidSortOrderForWheel(GAMESTATE->m_PreferredSortOrder)) {
    return GAMESTATE->m_PreferredSortOrder;
  }
  return SORT_GROUP;
}

void MusicWheel::DeleteWheelItemDatas(std::vector<MusicWheelItemData*>& items) {
  for (MusicWheelItemData* item : items) {
    delete item;
  }
  items.clear();
}

void MusicWheel::ClearWheelItemDataCache() {
  FOREACH_ENUM(SortOrder, so) {
    DeleteWheelItemDatas(m__UnFilteredWheelItemDatas[so]);
    m__WheelItemDatas[so].clear();
    m_WheelItemDatasStatus[so] = INVALID;
  }
  m_EmptyWheelItems.clear();
  m_CurWheelItemData.clear();
  m_LastSelection = nullptr;
}

RageColor MusicWheel::GetSectionColor(int& index, RageColor fallback) const {
  int colorCount = NUM_SECTION_COLORS.GetValue();
  if (colorCount <= 0) {
    return fallback;
  }
  colorCount = std::min(colorCount, MAX_SECTION_COLORS);
  index = std::clamp(index, 0, colorCount - 1);
  RageColor color = SECTION_COLORS.GetValue(index);
  index = (index + 1) % colorCount;
  return color;
}

void MusicWheel::MarkAllWheelItemDatasInvalid() {
  FOREACH_ENUM(SortOrder, so) { m_WheelItemDatasStatus[so] = INVALID; }
}

void MusicWheel::Load(std::string sType) {
  if (THEME == nullptr) {
    WarnMusicWheel("SRC_AUDIT_FIX SRC-1334: Load called without THEME.");
    WheelBase::Load(sType);
    return;
  }

  ROULETTE_SWITCH_SECONDS.Load(sType, "RouletteSwitchSeconds");
  ROULETTE_SLOW_DOWN_SWITCHES.Load(sType, "RouletteSlowDownSwitches");
  NUM_SECTION_COLORS.Load(sType, "NumSectionColors");
  SONG_REAL_EXTRA_COLOR.Load(sType, "SongRealExtraColor");
  SORT_MENU_COLOR.Load(sType, "SortMenuColor");
  SHOW_ROULETTE.Load(sType, "ShowRoulette");
  SHOW_RANDOM.Load(sType, "ShowRandom");
  SHOW_PORTAL.Load(sType, "ShowPortal");
  RANDOM_PICKS_LOCKED_SONGS.Load(sType, "RandomPicksLockedSongs");
  MOST_PLAYED_SONGS_TO_SHOW.Load(sType, "MostPlayedSongsToShow");
  RECENT_SONGS_TO_SHOW.Load(sType, "RecentSongsToShow");
  MODE_MENU_CHOICE_NAMES.Load(sType, "ModeMenuChoiceNames");
  SORT_ORDERS.Load(sType, "SortOrders");
  SHOW_EASY_FLAG.Load(sType, "UseEasyMarkerFlag");
  USE_SECTIONS_WITH_PREFERRED_GROUP.Load(
      sType, "UseSectionsWithPreferredGroup");
  HIDE_INACTIVE_SECTIONS.Load(sType, "OnlyShowActiveSection");
  HIDE_ACTIVE_SECTION_TITLE.Load(sType, "HideActiveSectionTitle");
  REMIND_WHEEL_POSITIONS.Load(sType, "RemindWheelPositions");
  std::vector<std::string> vsModeChoiceNames;
  SplitNonEmpty(MODE_MENU_CHOICE_NAMES, vsModeChoiceNames);
  CHOICE.Load(sType, CHOICE_NAME, vsModeChoiceNames);
  const int sectionColorCount =
      std::clamp(NUM_SECTION_COLORS.GetValue(), 0, MAX_SECTION_COLORS);
  SECTION_COLORS.Load(sType, SECTION_COLORS_NAME, sectionColorCount);

  CUSTOM_WHEEL_ITEM_NAMES.Load(sType, "CustomWheelItemNames");
  std::vector<std::string> vsCustomItemNames;
  SplitNonEmpty(CUSTOM_WHEEL_ITEM_NAMES, vsCustomItemNames);
  CUSTOM_CHOICES.Load(sType, CUSTOM_WHEEL_ITEM_NAME, vsCustomItemNames);
  CUSTOM_CHOICE_COLORS.Load(sType, CUSTOM_WHEEL_ITEM_COLOR, vsCustomItemNames);

  ROULETTE_COLOR.Load(sType, "RouletteColor");
  RANDOM_COLOR.Load(sType, "RandomColor");
  PORTAL_COLOR.Load(sType, "PortalColor");
  EMPTY_COLOR.Load(sType, "EmptyColor");

  WheelBase::Load(sType);

  if (SONGMAN == nullptr) {
    WarnMusicWheel("SRC_AUDIT_FIX SRC-1334: Load called without SONGMAN.");
    MarkAllWheelItemDatasInvalid();
    return;
  }

  SONGMAN->UpdateRankingCourses();

  m_soundChangeSort.Load(THEME->GetPathS(sType, "sort"));
  m_soundExpand.Load(THEME->GetPathS(sType, "expand"), true);
  m_soundCollapse.Load(THEME->GetPathS(sType, "collapse"), true);

  // Update for SORT_MOST_PLAYED.
  SONGMAN->UpdatePopular();

  /* Sort SONGMAN's songs by CompareSongPointersByTitle, so we can do other
   * sorts (with stable_sort) from its output, and title will be the secondary
   * sort, without having to re-sort by title each time. */
  SONGMAN->SortSongs();

  MarkAllWheelItemDatasInvalid();
}

void MusicWheel::BeginScreen() {
  if (GAMESTATE == nullptr || SONGMAN == nullptr) {
    WarnMusicWheel(
        "SRC_AUDIT_FIX SRC-1338: BeginScreen called before managers exist.");
    WheelBase::BeginScreen();
    SetOpenSection("");
    return;
  }

  RageTimer timer;
  std::string times;
  FOREACH_ENUM(SortOrder, so) {
    if (m_WheelItemDatasStatus[so] != INVALID) {
      m_WheelItemDatasStatus[so] = NEEDREFILTER;
    }

    if (g_bPrecacheAllSorts) {
      readyWheelItemsData(so);
      times += ssprintf("%i:%.3f ", so, timer.GetDeltaTime());
    }
  }
  if (g_bPrecacheAllSorts) {
    if (LOG != nullptr) {
      LOG->Trace("MusicWheel sorting took: %s", times.c_str());
    }
  }

  // Set m_LastModeMenuItem to the first item that matches the current mode. (Do
  // this after building wheel item data.)
  {
    const std::vector<MusicWheelItemData*>& from =
        getWheelItemsData(SORT_MODE_MENU);
    for (unsigned i = 0; i < from.size(); i++) {
      if (from[i] == nullptr || from[i]->m_pAction.isNull()) {
        continue;
      }
      if (from[i]->m_pAction->DescribesCurrentModeForAllPlayers()) {
        m_sLastModeMenuItem = from[i]->m_pAction->m_sName;
        break;
      }
    }
  }

  WheelBase::BeginScreen();

  if (GAMESTATE->IsAnExtraStageAndSelectionLocked()) {
    m_WheelState = STATE_LOCKED;
    if (SCREENMAN != nullptr) {
      SCREENMAN->PlayStartSound();
    }
    m_fLockedWheelVelocity = 0;
  }

  if (IsValidSortOrderForWheel(GAMESTATE->m_PreferredSortOrder)) {
    GAMESTATE->m_SortOrder.Set(GAMESTATE->m_PreferredSortOrder);
  } else {
    GAMESTATE->m_SortOrder.Set(SORT_GROUP);
  }

  // Never start in the mode menu; some elements may not initialize correctly.
  if (GAMESTATE->m_SortOrder == SORT_MODE_MENU) {
    GAMESTATE->m_SortOrder.Set(SortOrder_Invalid);
  }

  GAMESTATE->m_SortOrder.Set(
      ForceAppropriateSort(GAMESTATE->m_PlayMode, GAMESTATE->m_SortOrder));
  if (!IsValidSortOrderForWheel(GAMESTATE->m_SortOrder)) {
    GAMESTATE->m_SortOrder.Set(SORT_GROUP);
  }

  /* Only save the sort order if the player didn't already have one.
   * If he did, don't overwrite it. */
  if (GAMESTATE->m_PreferredSortOrder == SortOrder_Invalid) {
    GAMESTATE->m_PreferredSortOrder = GAMESTATE->m_SortOrder;
  }

  if (GAMESTATE->m_sPreferredSongGroup != GROUP_ALL) {
    // If a preferred song group is set, open the group and select the
    // first song in the group. -aj
    if (!GAMESTATE->IsCourseMode()) {
      std::vector<Song*> vTemp =
          SONGMAN->GetSongs(GAMESTATE->m_sPreferredSongGroup);
      if (!vTemp.empty() && vTemp[0] != nullptr) {
        GAMESTATE->m_pCurSong.Set(vTemp[0]);
      } else {
        WarnMusicWheel(
            ssprintf("SRC_AUDIT_FIX SRC-1339: preferred group '%s' has no "
                     "selectable songs.",
                     GAMESTATE->m_sPreferredSongGroup.Get().c_str()));
      }
    };
    SetOpenSection(GAMESTATE->m_sPreferredSongGroup);
    SelectSongOrCourse();
  } else if (!SelectSongOrCourse()) {
    // Select the the previously selected song (if any)
    SetOpenSection("");
  }

  if (REMIND_WHEEL_POSITIONS && HIDE_INACTIVE_SECTIONS) {
    // store the group song index, run this also here because it forgets the
    // current position when not changing the song if you came back from
    // gameplay or your last round song (profiles) is not the first one in the
    // group.
    for (unsigned idx = 0; idx < m_viWheelPositions.size(); idx++) {
      if (m_sExpandedSectionName == SONGMAN->GetSongGroupByIndex(idx)) {
        m_viWheelPositions[idx] = m_iSelection;
      }
    }
  }

  // rebuild the WheelItems that appear on screen
  RebuildWheelItems();

  /* Invalidate current Song if it can't be played
   * because there are not enough stages remaining. */
  if (GAMESTATE->m_pCurSong != nullptr &&
      GameState::GetNumStagesMultiplierForSong(GAMESTATE->m_pCurSong) >
          GAMESTATE->GetSmallestNumStagesLeftForAnyHumanPlayer()) {
    GAMESTATE->m_pCurSong.Set(nullptr);
  }

  /* Invalidate current Steps if it can't be played
   * because there are not enough stages remaining. */
  FOREACH_ENUM(PlayerNumber, p) {
    if (GAMESTATE->m_pCurSteps[p] != nullptr) {
      std::vector<Steps*> vpPossibleSteps;
      if (GAMESTATE->m_pCurSong != nullptr) {
        SongUtil::GetPlayableSteps(GAMESTATE->m_pCurSong, vpPossibleSteps);
      }
      bool bStepsIsPossible =
          find(
              vpPossibleSteps.begin(), vpPossibleSteps.end(),
              GAMESTATE->m_pCurSteps[p]) != vpPossibleSteps.end();
      if (!bStepsIsPossible) {
        GAMESTATE->m_pCurSteps[p].Set(nullptr);
      }
    }
  }
}

MusicWheel::~MusicWheel() {
  ClearWheelItemDataCache();
}

void MusicWheel::ReloadSongList() {
  const MusicWheelItemData* previousSelection =
      m_CurWheelItemData.empty() ? nullptr : GetCurWheelItemData(m_iSelection);
  const WheelItemDataType previousType =
      previousSelection != nullptr ? previousSelection->m_Type
                                   : WheelItemDataType_Invalid;
  const Song* songToPreserve =
      previousType == WheelItemDataType_Song ? previousSelection->m_pSong
                                             : nullptr;
  const Course* courseToPreserve =
      previousType == WheelItemDataType_Course ? previousSelection->m_pCourse
                                               : nullptr;
  const std::string sectionToPreserve =
      previousSelection != nullptr ? previousSelection->m_sText : "";
  const std::string expandedSectionToPreserve = m_sExpandedSectionName;
  const int fallbackIndexToPreserve = m_iSelection;

  // Remove the song from any sorting caches:
  MarkAllWheelItemDatasInvalid();
  // rebuild the info associated with this sort order
  readyWheelItemsData(GetCurrentSortOrderOrDefault());

  bool restoredSelection = false;
  if (songToPreserve != nullptr) {
    restoredSelection = SelectSong(songToPreserve);
  } else if (courseToPreserve != nullptr) {
    restoredSelection = SelectCourse(courseToPreserve);
  }

  if (!restoredSelection) {
    // Re-open the section to refresh song counts, etc.  Preserve the selected
    // item by identity where possible; preserving only the index can desync the
    // visible row from the banner when a pack is added in-session.
    SetOpenSection(expandedSectionToPreserve);
    if (previousType == WheelItemDataType_Section &&
        !sectionToPreserve.empty()) {
      restoredSelection = SelectSection(sectionToPreserve);
    }
  }

  if (!restoredSelection && !m_CurWheelItemData.empty()) {
    const int lastIndex = static_cast<int>(m_CurWheelItemData.size()) - 1;
    m_iSelection = std::max(0, std::min(fallbackIndexToPreserve, lastIndex));
  }

  RebuildWheelItems();
  // refresh the song preview
  if (SCREENMAN != nullptr) {
    SCREENMAN->PostMessageToTopScreen(SM_SongChanged, 0);
  }
}

/* If a song or course is set in GAMESTATE and available, select it.  Otherwise,
 * choose the first available song or course.  Return true if an item was set,
 * false if no items are available. */
bool MusicWheel::SelectSongOrCourse() {
  if (GAMESTATE == nullptr) {
    return false;
  }
  if (GAMESTATE->m_pPreferredSong && SelectSong(GAMESTATE->m_pPreferredSong)) {
    return true;
  }
  if (GAMESTATE->m_pCurSong && SelectSong(GAMESTATE->m_pCurSong)) {
    return true;
  }
  if (GAMESTATE->m_pPreferredCourse &&
      SelectCourse(GAMESTATE->m_pPreferredCourse)) {
    return true;
  }
  if (GAMESTATE->m_pCurCourse && SelectCourse(GAMESTATE->m_pCurCourse)) {
    return true;
  }

  // Select the first selectable song based on the sort order...
  std::vector<MusicWheelItemData*>& wiWheelItems =
      getWheelItemsData(GetCurrentSortOrderOrDefault());
  for (unsigned i = 0; i < wiWheelItems.size(); i++) {
    if (wiWheelItems[i] == nullptr) {
      continue;
    }
    if (wiWheelItems[i]->m_pSong) {
      return SelectSong(wiWheelItems[i]->m_pSong);
    } else if (wiWheelItems[i]->m_pCourse) {
      return SelectCourse(wiWheelItems[i]->m_pCourse);
    }
  }

  if (LOG != nullptr) {
    LOG->Trace(
        "MusicWheel::MusicWheel() - No selectable songs or courses found in "
        "WheelData");
  }
  return false;
}

bool MusicWheel::SelectSection(const std::string& SectionName) {
  for (unsigned int i = 0; i < m_CurWheelItemData.size(); ++i) {
    const MusicWheelItemData* item = GetCurWheelItemData(i);
    if (item != nullptr && item->m_sText == SectionName) {
      m_iSelection = i;  // select it
      return true;
    }
  }

  return false;
}

bool MusicWheel::SelectSong(const Song* p) {
  if (p == nullptr) {
    return false;
  }

  unsigned i;
  std::vector<MusicWheelItemData*>& from =
      getWheelItemsData(GetCurrentSortOrderOrDefault());
  const SortOrder currentSort = GetCurrentSortOrderOrDefault();
  if (GAMESTATE != nullptr && GAMESTATE->sLastOpenSection != "" &&
      (currentSort == SORT_PREFERRED || currentSort == SORT_METER)) {
    // Return to the last open section if it is defined and exists in the
    // current sort
    for (i = 0; i < from.size(); i++) {
      if (from[i] != nullptr &&
          from[i]->m_sText == GAMESTATE->sLastOpenSection) {
        // make its group the currently expanded group
        SetOpenSection(from[i]->m_sText);
        break;
      }
    }
  } else {
    for (i = 0; i < from.size(); i++) {
      if (from[i] != nullptr && from[i]->m_pSong == p) {
        // make its group the currently expanded group
        SetOpenSection(from[i]->m_sText);
        break;
      }
    }
  }
  if (i == from.size()) {
    return false;
  }

  bool foundCurrent = false;
  for (i = 0; i < m_CurWheelItemData.size(); i++) {
    const MusicWheelItemData* item = GetCurWheelItemData(i);
    if (item != nullptr && item->m_pSong == p) {
      m_iSelection = i;  // select it
      foundCurrent = true;
      break;
    }
  }
  return foundCurrent;
}

bool MusicWheel::SelectCourse(const Course* p) {
  if (p == nullptr) {
    return false;
  }

  unsigned i;
  std::vector<MusicWheelItemData*>& from =
      getWheelItemsData(GetCurrentSortOrderOrDefault());
  for (i = 0; i < from.size(); i++) {
    if (from[i] != nullptr && from[i]->m_pCourse == p) {
      // make its group the currently expanded group
      SetOpenSection(from[i]->m_sText);
      break;
    }
  }

  if (i == from.size()) {
    return false;
  }

  bool foundCurrent = false;
  for (i = 0; i < m_CurWheelItemData.size(); i++) {
    const MusicWheelItemData* item = GetCurWheelItemData(i);
    if (item != nullptr && item->m_pCourse == p) {
      m_iSelection = i;  // select it
      foundCurrent = true;
      break;
    }
  }

  return foundCurrent;
}

bool MusicWheel::SelectModeMenuItem() {
  // Select the last-chosen option.
  if (GAMESTATE == nullptr || GAMESTATE->m_SortOrder != SORT_MODE_MENU) {
    return false;
  }
  const std::vector<MusicWheelItemData*>& from =
      getWheelItemsData(SORT_MODE_MENU);
  unsigned i;
  for (i = 0; i < from.size(); i++) {
    if (from[i] == nullptr || from[i]->m_pAction.isNull()) {
      continue;
    }
    const GameCommand& gc = *from[i]->m_pAction;
    if (gc.m_sName == m_sLastModeMenuItem) {
      break;
    }
  }
  if (i == from.size()) {
    return false;
  }

  // make its group the currently expanded group
  SetOpenSection(from[i]->m_sText);

  for (i = 0; i < m_CurWheelItemData.size(); i++) {
    const MusicWheelItemData* item = GetCurWheelItemData(i);
    if (item == nullptr || item->m_pAction.isNull() ||
        item->m_pAction->m_sName != m_sLastModeMenuItem) {
      continue;
    }
    m_iSelection = i;  // select it
    break;
  }

  return true;
}

// bool MusicWheel::SelectCustomItem()

void MusicWheel::GetSongList(std::vector<Song*>& arraySongs, SortOrder so) {
  if (SONGMAN == nullptr || GAMESTATE == nullptr) {
    return;
  }

  std::vector<Song*> apAllSongs;
  switch (so) {
    case SORT_PREFERRED:
      SONGMAN->GetPreferredSortSongs(apAllSongs);
      break;
    case SORT_POPULARITY:
      apAllSongs = SONGMAN->GetPopularSongs();
      break;
    case SORT_GROUP:
      // if we're not using sections with a preferred song group, and there
      // is a group to load, only load those songs. -aj
      if (GAMESTATE->m_sPreferredSongGroup != GROUP_ALL &&
          !USE_SECTIONS_WITH_PREFERRED_GROUP) {
        apAllSongs = SONGMAN->GetSongs(GAMESTATE->m_sPreferredSongGroup);
        break;
      }
      [[fallthrough]];
    default:
      apAllSongs = SONGMAN->GetAllSongs();
      break;
  }

  FOREACH_PlayerNumber(pn) {
    if (GAMESTATE->IsPlayerEnabled(pn) && PROFILEMAN != nullptr) {
      Profile* prof = PROFILEMAN->GetProfile(pn);
      if (prof == nullptr) {
        continue;
      }
      for (size_t i = 0; i < prof->m_songs.size(); ++i) {
        if (prof->m_songs[i] != nullptr) {
          apAllSongs.push_back(prof->m_songs[i]);
        }
      }
    }
  }

  // filter songs that we don't have enough stages to play
  {
    std::vector<Song*> vTempSongs;
    SongCriteria sc;
    sc.m_iMaxStagesForSong =
        GAMESTATE->GetSmallestNumStagesLeftForAnyHumanPlayer();
    SongUtil::FilterSongs(sc, apAllSongs, vTempSongs);
    apAllSongs = vTempSongs;
  }

  // copy only songs that have at least one Steps for the current GameMode
  for (unsigned i = 0; i < apAllSongs.size(); i++) {
    Song* pSong = apAllSongs[i];
    if (pSong == nullptr) {
      continue;
    }

    int iLocked = UNLOCKMAN != nullptr ? UNLOCKMAN->SongIsLocked(pSong) : 0;
    if (iLocked & LOCKED_DISABLED) {
      continue;
    }

    // If we're on an extra stage, and this song is selected, ignore
    // #SELECTABLE.
    if (pSong != GAMESTATE->m_pCurSong || !GAMESTATE->IsAnExtraStage()) {
      // Hide songs that asked to be hidden via #SELECTABLE.
      if (iLocked & LOCKED_SELECTABLE) {
        continue;
      }
      if (so != SORT_ROULETTE && iLocked & LOCKED_ROULETTE) {
        continue;
      }
    }

    /* Hide locked songs. If RANDOM_PICKS_LOCKED_SONGS, hide in Roulette
     * and Random, too. */
    if ((so != SORT_ROULETTE || !RANDOM_PICKS_LOCKED_SONGS) && iLocked) {
      continue;
    }

    const Style* currentStyle = GetCurrentWheelStyle(PLAYER_INVALID);
    const StepsType currentStepsType =
        currentStyle != nullptr ? currentStyle->m_StepsType : StepsType_Invalid;
    if (PREFSMAN != nullptr && PREFSMAN->m_bOnlyPreferredDifficulties &&
        currentStepsType != StepsType_Invalid &&
        GAMESTATE->GetFirstHumanPlayer() != PLAYER_INVALID) {
      // if the song has steps that fit the preferred difficulty of the default
      // player
      if (pSong->HasStepsTypeAndDifficulty(
              currentStepsType,
              GAMESTATE
                  ->m_PreferredDifficulty[GAMESTATE->GetFirstHumanPlayer()])) {
        arraySongs.push_back(pSong);
      }
    } else if (
        CommonMetrics::AUTO_SET_STYLE ||
        currentStyle == nullptr) {
      if (SongUtil::IsSongPlayable(pSong)) {
        arraySongs.push_back(pSong);
      }

    } else {
      // If the song has at least one steps, add it.
      if (currentStepsType != StepsType_Invalid &&
          pSong->HasStepsType(currentStepsType)) {
        arraySongs.push_back(pSong);
      }
    }
  }

  /* Hack: Add extra stage item if it was eliminated for any reason
   * (eg. it's a long song). */
  if (GAMESTATE->IsAnExtraStage()) {
    Song* pSong = nullptr;
    Steps* pSteps = nullptr;
    SONGMAN->GetExtraStageInfo(
        GAMESTATE->IsExtraStage2(), GetCurrentWheelStyle(PLAYER_INVALID), pSong,
        pSteps);

    if (pSong != nullptr &&
        find(arraySongs.begin(), arraySongs.end(), pSong) == arraySongs.end()) {
      arraySongs.push_back(pSong);
    }
  }
}

void MusicWheel::BuildWheelItemDatas(
    std::vector<MusicWheelItemData*>& arrayWheelItemDatas, SortOrder so) {
  arrayWheelItemDatas.clear();
  if (!IsValidSortOrderForWheel(so)) {
    WarnMusicWheel(
        ssprintf("SRC_AUDIT_FIX SRC-1361: invalid sort order %i ignored.", so));
    return;
  }

  switch (so) {
    case SORT_MODE_MENU: {
      std::vector<std::string> vsNames;
      SplitNonEmpty(MODE_MENU_CHOICE_NAMES, vsNames);
      for (unsigned i = 0; i < vsNames.size(); ++i) {
        MusicWheelItemData wid(
            WheelItemDataType_Sort, nullptr, "", nullptr, nullptr,
            SORT_MENU_COLOR, 0);
        wid.m_pAction = HiddenPtr<GameCommand>(new GameCommand);
        if (wid.m_pAction.isNull()) {
          continue;
        }
        wid.m_pAction->m_sName = vsNames[i];
        wid.m_pAction->Load(i, ParseCommands(CHOICE.GetValue(vsNames[i])));
        wid.m_sLabel = GetWheelText(vsNames[i]);

        if (!wid.m_pAction->IsPlayable()) {
          continue;
        }

        arrayWheelItemDatas.push_back(new MusicWheelItemData(wid));
      }
      break;
    }
    case SORT_METER:
    case SORT_PREFERRED:
    case SORT_ROULETTE:
    case SORT_GROUP:
    case SORT_TITLE:
    case SORT_BPM:
    case SORT_POPULARITY:
    case SORT_POPULARITY_P1:
    case SORT_POPULARITY_P2:
    case SORT_TOP_GRADES:
    case SORT_TOP_GRADES_P1:
    case SORT_TOP_GRADES_P2:
    case SORT_ARTIST:
    case SORT_GENRE:
    case SORT_BEGINNER_METER:
    case SORT_EASY_METER:
    case SORT_MEDIUM_METER:
    case SORT_HARD_METER:
    case SORT_CHALLENGE_METER:
    case SORT_DOUBLE_EASY_METER:
    case SORT_DOUBLE_MEDIUM_METER:
    case SORT_DOUBLE_HARD_METER:
    case SORT_DOUBLE_CHALLENGE_METER:
    case SORT_LENGTH:
    case SORT_RECENT:
    case SORT_RECENT_P1:
    case SORT_RECENT_P2: {
      // Make an array of Song*, then sort them
      std::vector<Song*> arraySongs;
      GetSongList(arraySongs, so);

      bool bUseSections = true;

      // sort the songs
      switch (so) {
        case SORT_METER:
          SONGMAN->UpdateMeterSort(arraySongs);
          break;
        case SORT_PREFERRED:
          // obey order specified by the preferred sort list
          break;
        case SORT_ROULETTE: {
          StepsType st;
          Difficulty dc;
          SongUtil::GetStepsTypeAndDifficultyFromSortOrder(
              SORT_EASY_METER, st, dc);
          SongUtil::SortSongPointerArrayByStepsTypeAndMeter(arraySongs, st, dc);
          if (PREFSMAN != nullptr && (bool)PREFSMAN->m_bPreferredSortUsesGroups) {
            stable_sort(
                arraySongs.begin(), arraySongs.end(),
                SongUtil::CompareSongPointersByGroup);
          }
          bUseSections = false;
          break;
        }
        case SORT_GROUP:
          SongUtil::SortSongPointerArrayByGroupAndTitle(arraySongs);
          if (USE_SECTIONS_WITH_PREFERRED_GROUP) {
            bUseSections = true;
          } else {
            bUseSections = GAMESTATE->m_sPreferredSongGroup == GROUP_ALL;
          }
          break;
        case SORT_TITLE:
          SongUtil::SortSongPointerArrayByTitle(arraySongs);
          break;
        case SORT_BPM:
          SongUtil::SortSongPointerArrayByBPM(arraySongs);
          break;
        case SORT_POPULARITY:
          TrimSongList(arraySongs, MOST_PLAYED_SONGS_TO_SHOW.GetValue());
          bUseSections = true;
          break;
        case SORT_POPULARITY_P1:
          if (PROFILEMAN != nullptr && PROFILEMAN->IsPersistentProfile(PLAYER_1)) {
            SongUtil::SortSongPointerArrayByNumPlays(
                arraySongs, ProfileSlot_Player1, true);
          }
          TrimSongList(arraySongs, MOST_PLAYED_SONGS_TO_SHOW.GetValue());
          bUseSections = true;
          break;
        case SORT_POPULARITY_P2:
          if (PROFILEMAN != nullptr && PROFILEMAN->IsPersistentProfile(PLAYER_2)) {
            SongUtil::SortSongPointerArrayByNumPlays(
                arraySongs, ProfileSlot_Player2, true);
          }
          TrimSongList(arraySongs, MOST_PLAYED_SONGS_TO_SHOW.GetValue());
          bUseSections = true;
          break;
        case SORT_TOP_GRADES:
          SongUtil::SortSongPointerArrayByGrades(arraySongs, true);
          break;
        case SORT_TOP_GRADES_P1:
          // Check if player profile is persistent
          if (PROFILEMAN != nullptr && PROFILEMAN->IsPersistentProfile(PLAYER_1)) {
            SongUtil::SortSongPointerArrayByProfileGrades(
                arraySongs, true, PLAYER_1);
          }
          break;
        case SORT_TOP_GRADES_P2:
          if (PROFILEMAN != nullptr && PROFILEMAN->IsPersistentProfile(PLAYER_2)) {
            SongUtil::SortSongPointerArrayByProfileGrades(
                arraySongs, true, PLAYER_2);
          }
          break;
        case SORT_ARTIST:
          SongUtil::SortSongPointerArrayByArtist(arraySongs);
          break;
        case SORT_GENRE:
          SongUtil::SortSongPointerArrayByGenre(arraySongs);
          break;
        case SORT_LENGTH:
          SongUtil::SortSongPointerArrayByLength(arraySongs);
          break;
        case SORT_RECENT:
          SongUtil::SortByMostRecentlyPlayedForMachine(arraySongs);
          TrimSongList(arraySongs, RECENT_SONGS_TO_SHOW.GetValue());
          bUseSections = true;
          break;
        case SORT_RECENT_P1:
          if (PROFILEMAN != nullptr && PROFILEMAN->IsPersistentProfile(PLAYER_1)) {
            SongUtil::SortByMostRecentlyPlayedForProfile(arraySongs, PLAYER_1);
          }
          TrimSongList(arraySongs, RECENT_SONGS_TO_SHOW.GetValue());
          bUseSections = true;
          break;
        case SORT_RECENT_P2:
          if (PROFILEMAN != nullptr && PROFILEMAN->IsPersistentProfile(PLAYER_2)) {
            SongUtil::SortByMostRecentlyPlayedForProfile(arraySongs, PLAYER_2);
          }
          TrimSongList(arraySongs, RECENT_SONGS_TO_SHOW.GetValue());
          bUseSections = true;
          break;
        case SORT_BEGINNER_METER:
        case SORT_EASY_METER:
        case SORT_MEDIUM_METER:
        case SORT_HARD_METER:
        case SORT_CHALLENGE_METER:
        case SORT_DOUBLE_EASY_METER:
        case SORT_DOUBLE_MEDIUM_METER:
        case SORT_DOUBLE_HARD_METER:
        case SORT_DOUBLE_CHALLENGE_METER:
          StepsType st;
          Difficulty dc;
          SongUtil::GetStepsTypeAndDifficultyFromSortOrder(so, st, dc);
          SongUtil::SortSongPointerArrayByStepsTypeAndMeter(arraySongs, st, dc);
          break;
        default:
          WarnMusicWheel(
              ssprintf("SRC_AUDIT_FIX SRC-1354: unhandled song sort %i.", so));
          return;
      }

      // Build an array of WheelItemDatas from the sorted list of Song*'s
      arrayWheelItemDatas.reserve(arraySongs.size());

      const MusicWheelUsesSections useSections =
          PREFSMAN != nullptr ? PREFSMAN->m_MusicWheelUsesSections
                              : MusicWheelUsesSections_ALWAYS;
      switch (useSections) {
        case MusicWheelUsesSections_NEVER:
          bUseSections = false;
          break;
        case MusicWheelUsesSections_ABC_ONLY:
          if (so != SORT_TITLE && so != SORT_GROUP) {
            bUseSections = false;
          }
          break;
        default:
          break;
      }

      if (bUseSections) {
        // Sorting twice isn't necessary. Instead, modify the compatator
        // functions in Song.cpp to have the desired effect. -Chris
        /* Keeping groups together with the sorts is tricky and brittle; we
         * keep getting OTHER split up without this. However, it puts the
         * Grade and BPM sorts in the wrong order, and they're already correct,
         * so don't re-sort for them. */
        /* We're using sections, so use the section name as the top-level sort.
         */
        switch (so) {
          case SORT_GROUP:
            SongUtil::SortSongPointerArrayByGroup(arraySongs);
            break;
          case SORT_METER:
          case SORT_PREFERRED:
          case SORT_TOP_GRADES:
          case SORT_TOP_GRADES_P1:
          case SORT_TOP_GRADES_P2:
          case SORT_BPM:
          case SORT_LENGTH:
            break;  // don't sort by section
          default:
            SongUtil::SortSongPointerArrayBySectionName(arraySongs, so);
            break;
        }
      }
      // make WheelItemDatas with sections
      std::string sLastSection = "";
      int iSectionColorIndex = 0;
      switch (so) {
        case SORT_PREFERRED:
          // If the sort order is Preferred handle it differently because we
          // already know the sections
          if (bUseSections) {
            // Get mapping of section names to songs.
            const std::map<std::string, std::vector<Song*>> preferredSortSongsMap =
                SONGMAN != nullptr ? SONGMAN->GetPreferredSortSongsMap()
                                   : std::map<std::string, std::vector<Song*>>();
            for (const auto& [sectionName, songs] : preferredSortSongsMap) {
              // todo: preferred sort section color handling? -aj
              RageColor colorSection =
                  GetSectionColor(iSectionColorIndex, EMPTY_COLOR);
              // Add the section item
              arrayWheelItemDatas.push_back(new MusicWheelItemData(
                  WheelItemDataType_Section, nullptr, sectionName, nullptr,
                  nullptr, colorSection, songs.size()));
              // Add all the songs in this section
              for (const auto& song : songs) {
                if (song == nullptr) {
                  continue;
                }
                arrayWheelItemDatas.push_back(new MusicWheelItemData(
                    WheelItemDataType_Song, song, sectionName, nullptr, nullptr,
                    SONGMAN != nullptr ? SONGMAN->GetSongColor(song)
                                       : EMPTY_COLOR,
                    0));
              }
            }
          }
          break;
        case SORT_METER:
          if (bUseSections) {
            int iSectionCount = 0;
            const auto meterToSongsMap =
                SONGMAN != nullptr ? SONGMAN->GetMeterToSongsMap()
                                   : decltype(SONGMAN->GetMeterToSongsMap())();
            for (const auto& [sectionName, songs] : meterToSongsMap) {
              RageColor colorSection =
                  GetSectionColor(iSectionColorIndex, EMPTY_COLOR);
              // Add the section item
              arrayWheelItemDatas.push_back(new MusicWheelItemData(
                  WheelItemDataType_Section, nullptr,
                  ssprintf("%d", sectionName), nullptr, nullptr, colorSection,
                  songs.size()));
              // Add all the songs in this section
              for (const auto& song : songs) {
                if (song == nullptr) {
                  continue;
                }
                arrayWheelItemDatas.push_back(new MusicWheelItemData(
                    WheelItemDataType_Song, song, ssprintf("%d", sectionName),
                    nullptr, nullptr,
                    SONGMAN != nullptr ? SONGMAN->GetSongColor(song)
                                       : EMPTY_COLOR,
                    0));
              }
            }
          }
          break;
        case SORT_GROUP:
          for (unsigned i = 0; i < arraySongs.size(); i++) {
            Song* pSong = arraySongs[i];
            if (pSong == nullptr) {
              continue;
            }
            Group* pGroup = SONGMAN != nullptr ? SONGMAN->GetGroup(pSong) : nullptr;
            if (bUseSections) {
              std::string sThisSection =
                  pGroup != nullptr ? pGroup->GetGroupName() : pSong->m_sGroupName;
              if (sThisSection.empty()) {
                sThisSection = GROUP_ALL;
              }

              if (sThisSection != sLastSection) {
                int iSectionCount = 0;
                // Count songs in this section
                unsigned j;
                for (j = i; j < arraySongs.size(); j++) {
                  if (arraySongs[j] == nullptr) {
                    continue;
                  }
                  Group* nextGroup =
                      SONGMAN != nullptr ? SONGMAN->GetGroup(arraySongs[j])
                                         : nullptr;
                  if (nextGroup == nullptr) {
                    if (LOG != nullptr) {
                      LOG->Warn(
                          "Song %s has no group!",
                          arraySongs[j]->GetSongDir().c_str());
                    }
                    continue;
                  } else if (nextGroup->GetGroupName() != sThisSection) {
                    break;
                  }
                }
                iSectionCount = j - i;

                // new section, make a section item
                // todo: preferred sort section color handling? -aj
                RageColor colorSection =
                    so == SORT_GROUP && SONGMAN != nullptr
                        ? SONGMAN->GetSongGroupColor(sThisSection)
                        : GetSectionColor(iSectionColorIndex, EMPTY_COLOR);
                arrayWheelItemDatas.push_back(new MusicWheelItemData(
                    WheelItemDataType_Section, nullptr, sThisSection, nullptr,
                    pGroup, colorSection, iSectionCount));
                sLastSection = sThisSection;
              }
            }
            arrayWheelItemDatas.push_back(new MusicWheelItemData(
                WheelItemDataType_Song, pSong, sLastSection, nullptr, pGroup,
                SONGMAN != nullptr ? SONGMAN->GetSongColor(pSong) : EMPTY_COLOR,
                0));
          }
          break;

        default:
          for (unsigned i = 0; i < arraySongs.size(); i++) {
            Song* pSong = arraySongs[i];
            if (pSong == nullptr) {
              continue;
            }
            if (bUseSections) {
              std::string sThisSection =
                  SongUtil::GetSectionNameFromSongAndSort(pSong, so);

              if (sThisSection != sLastSection) {
                int iSectionCount = 0;
                // Count songs in this section
                unsigned j;
                for (j = i; j < arraySongs.size(); j++) {
                  if (SongUtil::GetSectionNameFromSongAndSort(
                          arraySongs[j], so) != sThisSection) {
                    break;
                  }
                }
                iSectionCount = j - i;

                // new section, make a section item
                // todo: preferred sort section color handling? -aj
                RageColor colorSection =
                    so == SORT_GROUP && SONGMAN != nullptr
                        ? SONGMAN->GetSongGroupColor(sThisSection)
                        : GetSectionColor(iSectionColorIndex, EMPTY_COLOR);
                arrayWheelItemDatas.push_back(new MusicWheelItemData(
                    WheelItemDataType_Section, nullptr, sThisSection, nullptr,
                    nullptr, colorSection, iSectionCount));
                sLastSection = sThisSection;
              }
            }
            arrayWheelItemDatas.push_back(new MusicWheelItemData(
                WheelItemDataType_Song, pSong, sLastSection, nullptr, nullptr,
                SONGMAN != nullptr ? SONGMAN->GetSongColor(pSong) : EMPTY_COLOR,
                0));
          }
          break;
      }

      if (so != SORT_ROULETTE) {
        // todo: allow themers to change the order of the items. -aj
        if (SHOW_ROULETTE) {
          arrayWheelItemDatas.push_back(new MusicWheelItemData(
              WheelItemDataType_Roulette, nullptr, "", nullptr, nullptr,
              ROULETTE_COLOR, 0));
        }

        // Only add WheelItemDataType_Random and WheelItemDataType_Portal if
        // there's at least one song on the list.
        bool bFoundAnySong = false;
        for (unsigned i = 0; !bFoundAnySong && i < arrayWheelItemDatas.size();
             i++) {
          if (arrayWheelItemDatas[i]->m_Type == WheelItemDataType_Song) {
            bFoundAnySong = true;
          }
        }

        if (SHOW_RANDOM && bFoundAnySong) {
          arrayWheelItemDatas.push_back(new MusicWheelItemData(
              WheelItemDataType_Random, nullptr, "", nullptr, nullptr,
              RANDOM_COLOR, 0));
        }

        if (SHOW_PORTAL && bFoundAnySong) {
          arrayWheelItemDatas.push_back(new MusicWheelItemData(
              WheelItemDataType_Portal, nullptr, "", nullptr, nullptr,
              PORTAL_COLOR, 0));
        }

        // add custom wheel items
        std::vector<std::string> vsNames;
        SplitNonEmpty(CUSTOM_WHEEL_ITEM_NAMES, vsNames);
        for (unsigned i = 0; i < vsNames.size(); ++i) {
          MusicWheelItemData wid(
              WheelItemDataType_Custom, nullptr, "", nullptr, nullptr,
              CUSTOM_CHOICE_COLORS.GetValue(vsNames[i]), 0);
          wid.m_pAction = HiddenPtr<GameCommand>(new GameCommand);
          if (wid.m_pAction.isNull()) {
            continue;
          }
          wid.m_pAction->m_sName = vsNames[i];
          wid.m_pAction->Load(
              i, ParseCommands(CUSTOM_CHOICES.GetValue(vsNames[i])));
          wid.m_sLabel = GetCustomWheelText(vsNames[i]);

          if (!wid.m_pAction->IsPlayable()) {
            continue;
          }

          arrayWheelItemDatas.push_back(new MusicWheelItemData(wid));
        }
      }

      if (GAMESTATE->IsAnExtraStageAndSelectionLocked()) {
        Song* pSong = nullptr;
        Steps* pSteps = nullptr;
        SONGMAN->GetExtraStageInfo(
            GAMESTATE->IsExtraStage2(),
            GetCurrentWheelStyle(PLAYER_INVALID), pSong, pSteps);

        for (unsigned i = 0; i < arrayWheelItemDatas.size(); i++) {
          if (arrayWheelItemDatas[i]->m_pSong == pSong) {
            // Change the song color.
            arrayWheelItemDatas[i]->m_color = SONG_REAL_EXTRA_COLOR;
            break;
          }
        }
      }
      break;
    }
    case SORT_ALL_COURSES:
    case SORT_NONSTOP_COURSES:
    case SORT_ONI_COURSES:
    case SORT_ENDLESS_COURSES: {
      bool bOnlyPreferred =
          PREFSMAN != nullptr &&
          PREFSMAN->m_CourseSortOrder == COURSE_SORT_PREFERRED;

      std::vector<CourseType> vct;
      switch (so) {
        case SORT_NONSTOP_COURSES:
          vct.push_back(COURSE_TYPE_NONSTOP);
          break;
        case SORT_ONI_COURSES:
          vct.push_back(COURSE_TYPE_ONI);
          vct.push_back(COURSE_TYPE_SURVIVAL);
          break;
        case SORT_ENDLESS_COURSES:
          vct.push_back(COURSE_TYPE_ENDLESS);
          break;
        case SORT_ALL_COURSES:
          FOREACH_ENUM(CourseType, i)
          vct.push_back(i);
          break;
        default:
          WarnMusicWheel(
              ssprintf("SRC_AUDIT_FIX SRC-1354: wrong course sort %i.", so));
          return;
      }

      std::vector<Course*> apCourses;
      for (const CourseType& ct : vct) {
        if (bOnlyPreferred) {
          SONGMAN->GetPreferredSortCourses(
              ct, apCourses,
              PREFSMAN != nullptr && PREFSMAN->m_bAutogenGroupCourses);
        } else {
          SONGMAN->GetCourses(
              ct, apCourses,
              PREFSMAN != nullptr && PREFSMAN->m_bAutogenGroupCourses);
        }
      }

      const CourseSortOrders courseSortOrder =
          PREFSMAN != nullptr ? PREFSMAN->m_CourseSortOrder
                              : COURSE_SORT_SONGS;
      switch (courseSortOrder) {
        case COURSE_SORT_SONGS:
          CourseUtil::SortCoursePointerArrayByDifficulty(apCourses);
          break;
        case COURSE_SORT_PREFERRED:
          break;
        case COURSE_SORT_METER:
          CourseUtil::SortCoursePointerArrayByAvgDifficulty(apCourses);
          break;
        case COURSE_SORT_METER_SUM:
          CourseUtil::SortCoursePointerArrayByTotalDifficulty(apCourses);
          break;
        case COURSE_SORT_RANK:
          CourseUtil::SortCoursePointerArrayByRanking(apCourses);
          break;
        default:
          WarnMusicWheel("SRC_AUDIT_FIX SRC-1354: invalid course sort order.");
          return;
      }

      // since we can't agree, make it an option
      if (courseSortOrder != COURSE_SORT_SONGS && g_bMoveRandomToEnd) {
        CourseUtil::MoveRandomToEnd(apCourses);
      }

      if (so == SORT_ALL_COURSES) {
        CourseUtil::SortCoursePointerArrayByType(apCourses);
      }

      arrayWheelItemDatas.clear();  // clear out the previous wheel items

      std::string sLastSection = "";
      int iSectionColorIndex = 0;
      for (unsigned i = 0; i < apCourses.size(); i++)  // foreach course
      {
        Course* pCourse = apCourses[i];
        if (pCourse == nullptr) {
          continue;
        }

        // if unlocks are on, make sure it is unlocked
        if (UNLOCKMAN != nullptr && UNLOCKMAN->CourseIsLocked(pCourse)) {
          continue;
        }

        std::string sThisSection = "";
        if (so == SORT_ALL_COURSES) {
          switch (pCourse->GetPlayMode()) {
            case PLAY_MODE_ONI:
              sThisSection = "Oni";
              break;
            case PLAY_MODE_NONSTOP:
              sThisSection = "Nonstop";
              break;
            case PLAY_MODE_ENDLESS:
              sThisSection = "Endless";
              break;
            default:
              break;
          }
        }

        // check that this course has at least one song playable in the current
        // style
        const StepsType currentStepsType =
            GetCurrentWheelStepsType(PLAYER_INVALID);
        if (currentStepsType == StepsType_Invalid ||
            !pCourse->IsPlayableIn(currentStepsType)) {
          continue;
        }

        if (sThisSection != sLastSection)  // new section, make a section item
        {
          RageColor c = GetSectionColor(iSectionColorIndex, EMPTY_COLOR);
          arrayWheelItemDatas.push_back(new MusicWheelItemData(
              WheelItemDataType_Section, nullptr, sThisSection, nullptr,
              nullptr, c, 0));
          sLastSection = sThisSection;
        }

        RageColor c = (pCourse->m_sGroupName.size() == 0)
                          ? pCourse->GetColor()
                          : SONGMAN != nullptr ? SONGMAN->GetCourseColor(pCourse)
                                               : pCourse->GetColor();
        arrayWheelItemDatas.push_back(new MusicWheelItemData(
            WheelItemDataType_Course, nullptr, sThisSection, pCourse, nullptr,
            c, 0));
      }
      break;
    }
    default:
      break;
  }

  // init music status icons
  for (MusicWheelItemData* WID : arrayWheelItemDatas) {
    if (WID == nullptr) {
      continue;
    }
    if (WID->m_pSong != nullptr) {
      const StepsType currentStepsType =
          GetCurrentWheelStepsType(PLAYER_INVALID);
      WID->m_Flags.bHasBeginnerOr1Meter =
          currentStepsType != StepsType_Invalid &&
          WID->m_pSong->IsEasy(
              currentStepsType) &&
          SHOW_EASY_FLAG;
      WID->m_Flags.bEdits = false;
      std::set<StepsType> vStepsType;
      SongUtil::GetPlayableStepsTypes(WID->m_pSong, vStepsType);
      for (const StepsType& type : vStepsType) {
        WID->m_Flags.bEdits |= WID->m_pSong->HasEdits(type);
      }
      WID->m_Flags.iStagesForSong =
          GameState::GetNumStagesMultiplierForSong(WID->m_pSong);
    } else if (WID->m_pCourse != nullptr) {
      WID->m_Flags.bHasBeginnerOr1Meter = false;
      WID->m_Flags.bEdits = WID->m_pCourse->IsAnEdit();
      WID->m_Flags.iStagesForSong = 1;
    }
  }
}

std::vector<MusicWheelItemData*>& MusicWheel::getWheelItemsData(SortOrder so) {
  if (!IsValidSortOrderForWheel(so)) {
    WarnMusicWheel(ssprintf(
        "SRC_AUDIT_FIX SRC-1361: getWheelItemsData rejected sort %i.", so));
    m_EmptyWheelItems.clear();
    return m_EmptyWheelItems;
  }
  // Update the popularity and init icons.
  readyWheelItemsData(so);
  return m__WheelItemDatas[so];
}

void MusicWheel::readyWheelItemsData(SortOrder so) {
  if (!IsValidSortOrderForWheel(so)) {
    return;
  }

  if (m_WheelItemDatasStatus[so] == VALID && so != SORT_PREFERRED) {
    return;
  }

  std::vector<MusicWheelItemData*>& aUnFilteredDatas =
      m__UnFilteredWheelItemDatas[so];

  if (m_WheelItemDatasStatus[so] == INVALID) {
    DeleteWheelItemDatas(aUnFilteredDatas);
    m__WheelItemDatas[so].clear();
    BuildWheelItemDatas(aUnFilteredDatas, so);
  }
  FilterWheelItemDatas(aUnFilteredDatas, m__WheelItemDatas[so], so);
  // The preferred sort's songs are subject to change during a session
  // (particularly if two players have different preferred songs) thus it's
  // status should remain invalid so the wheel items are rebuilt each time in
  // case of change.
  if (so != SORT_PREFERRED) {
    m_WheelItemDatasStatus[so] = VALID;
  }
}

void MusicWheel::FilterWheelItemDatas(
    std::vector<MusicWheelItemData*>& aUnFilteredDatas,
    std::vector<MusicWheelItemData*>& aFilteredData, SortOrder so) {
  aFilteredData.clear();

  unsigned unfilteredSize = aUnFilteredDatas.size();

  /* Only add WheelItemDataType_Portal if there's at least one song on the list.
   */
  bool bFoundAnySong = false;
  for (unsigned i = 0; i < unfilteredSize; i++) {
    if (aUnFilteredDatas[i] != nullptr &&
        aUnFilteredDatas[i]->m_Type == WheelItemDataType_Song) {
      bFoundAnySong = true;
      break;
    }
  }

  std::vector<bool> aiRemove;
  aiRemove.insert(aiRemove.begin(), unfilteredSize, false);

  const int iMaxStagesForSong =
      GAMESTATE != nullptr ? GAMESTATE->GetSmallestNumStagesLeftForAnyHumanPlayer()
                           : 0;

  Song* pExtraStageSong = nullptr;
  if (GAMESTATE != nullptr && SONGMAN != nullptr && GAMESTATE->IsAnExtraStage()) {
    Steps* pSteps = nullptr;
    SONGMAN->GetExtraStageInfo(
        GAMESTATE->IsExtraStage2(), GetCurrentWheelStyle(PLAYER_INVALID),
        pExtraStageSong, pSteps);
  }

  /* Mark any songs that aren't playable in aiRemove. */

  for (unsigned i = 0; i < unfilteredSize; i++) {
    if (aUnFilteredDatas[i] == nullptr) {
      aiRemove[i] = true;
      continue;
    }
    MusicWheelItemData& WID = *aUnFilteredDatas[i];

    /* If we have no songs, remove Random and Portal. */
    if (WID.m_Type == WheelItemDataType_Random ||
        WID.m_Type == WheelItemDataType_Portal ||
        WID.m_Type == WheelItemDataType_Roulette) {
      if (!bFoundAnySong) {
        aiRemove[i] = true;
      }
      if (STATE_ROULETTE_SPINNING == m_WheelState) {
        aiRemove[i] = true;
      }
      continue;
    }

    if (WID.m_Type == WheelItemDataType_Section &&
        STATE_ROULETTE_SPINNING == m_WheelState) {
      aiRemove[i] = true;
    }

    /* Filter songs that we don't have enough stages to play. */
    if (WID.m_Type == WheelItemDataType_Song) {
      Song* pSong = WID.m_pSong;
      if (pSong == nullptr) {
        aiRemove[i] = true;
        continue;
      }

      /* Never remove the extra stage song. */
      if (pExtraStageSong && WID.m_pSong == pExtraStageSong) {
        continue;
      }

      /* Check that we have enough stages to play this song. */
      if (GAMESTATE != nullptr &&
          GAMESTATE->GetNumStagesMultiplierForSong(WID.m_pSong) >
          iMaxStagesForSong) {
        aiRemove[i] = true;
        continue;
      }

      int iLocked = UNLOCKMAN != nullptr ? UNLOCKMAN->SongIsLocked(pSong) : 0;
      if (iLocked & LOCKED_DISABLED) {
        aiRemove[i] = true;
        continue;
      }

      /* If we're on an extra stage, and this song is selected, ignore
       * #SELECTABLE. */
      if (GAMESTATE == nullptr || pSong != GAMESTATE->m_pCurSong ||
          !GAMESTATE->IsAnExtraStage()) {
        /* Hide songs that asked to be hidden via #SELECTABLE. */
        if (iLocked & LOCKED_SELECTABLE) {
          aiRemove[i] = true;
          continue;
        }
        if (so != SORT_ROULETTE && iLocked & LOCKED_ROULETTE) {
          aiRemove[i] = true;
          continue;
        }
      }

      /* Hide locked songs.  If RANDOM_PICKS_LOCKED_SONGS, hide in Roulette and
       * Random, too. */
      if ((so != SORT_ROULETTE || !RANDOM_PICKS_LOCKED_SONGS) && iLocked) {
        aiRemove[i] = true;
        continue;
      }

      /* If the song has no steps for the current style, remove it. */
      if (!CommonMetrics::AUTO_SET_STYLE &&
          (GetCurrentWheelStepsType(PLAYER_INVALID) == StepsType_Invalid ||
           !pSong->HasStepsType(GetCurrentWheelStepsType(PLAYER_INVALID)))) {
        aiRemove[i] = true;
        continue;
      }

      // if AutoSetStyle, make sure the song is playable in the end.
      if (!SongUtil::IsSongPlayable(pSong)) {
        aiRemove[i] = true;
        continue;
      }
    }

    if (WID.m_Type == WheelItemDataType_Course) {
      if (WID.m_pCourse == nullptr ||
          GetCurrentWheelStepsType(PLAYER_INVALID) == StepsType_Invalid ||
          !WID.m_pCourse->IsPlayableIn(
              GetCurrentWheelStepsType(PLAYER_INVALID))) {
        aiRemove[i] = true;
      }
    }
  }

  /* Filter out the songs we're removing. */

  aFilteredData.reserve(unfilteredSize);
  for (unsigned i = 0; i < unfilteredSize; i++) {
    if (aiRemove[i]) {
      continue;
    }
    aFilteredData.push_back(aUnFilteredDatas[i]);
  }

  // Update the song count in each section header.
  unsigned filteredSize = aFilteredData.size();
  for (unsigned i = 0; i < filteredSize;) {
    if (aFilteredData[i] == nullptr) {
      ++i;
      continue;
    }
    MusicWheelItemData& WID = *aFilteredData[i];
    ++i;
    if (WID.m_Type != WheelItemDataType_Section) {
      continue;
    }

    // Count songs in this section
    WID.m_iSectionCount = 0;
    for (;
         i < filteredSize && aFilteredData[i] != nullptr &&
         aFilteredData[i]->m_sText == WID.m_sText;
         ++i) {
      ++WID.m_iSectionCount;
    }
  }

  // If we have any section headers with no songs, then we filtered all of the
  // songs in that group, so remove it.  This isn't optimized like the above
  // since this is a rare case.
  for (unsigned i = 0; i < filteredSize; ++i) {
    if (aFilteredData[i] == nullptr) {
      aFilteredData.erase(
          aFilteredData.begin() + i, aFilteredData.begin() + i + 1);
      --i;
      --filteredSize;
      continue;
    }
    MusicWheelItemData& WID = *aFilteredData[i];
    if (WID.m_Type != WheelItemDataType_Section) {
      continue;
    }
    if (WID.m_iSectionCount > 0) {
      continue;
    }
    aFilteredData.erase(
        aFilteredData.begin() + i, aFilteredData.begin() + i + 1);
    --i;
    --filteredSize;
  }

  /* Update the popularity.  This is affected by filtering. */
  if (so == SORT_POPULARITY || so == SORT_POPULARITY_P1 ||
      so == SORT_POPULARITY_P2)

  {
    for (unsigned i = 0; i < std::min<unsigned int>(3u, aFilteredData.size());
         i++) {
      if (aFilteredData[i] == nullptr) {
        continue;
      }
      MusicWheelItemData& WID = *aFilteredData[i];
      WID.m_Flags.iPlayersBestNumber = i + 1;
    }
  }

  // If we've filtered all items, insert a dummy.
  if (aFilteredData.empty()) {
    m_EmptyWheelItemData = MusicWheelItemData(
        WheelItemDataType_Section, nullptr, EMPTY_STRING, nullptr, nullptr,
        EMPTY_COLOR, 0);
    aFilteredData.push_back(&m_EmptyWheelItemData);
  }
}

void MusicWheel::UpdateSwitch() {
  switch (m_WheelState) {
    case STATE_FLYING_OFF_BEFORE_NEXT_SORT: {
      if (GAMESTATE == nullptr) {
        m_WheelState = STATE_SELECTING;
        m_fTimeLeftInState = 0;
        return;
      }
      const Song* pPrevSelectedSong =
          GetSelectedSong();

      if (SCREENMAN != nullptr) {
        SCREENMAN->PostMessageToTopScreen(SM_SortOrderChanged, 0);
      }

      SetOpenSection(
          SongUtil::GetSectionNameFromSongAndSort(
              pPrevSelectedSong, GAMESTATE->m_SortOrder));

      m_iSelection = 0;

      // Select the previously selected item
      switch (GAMESTATE->m_SortOrder) {
        default:
          // Look for the last selected song or course
          SelectSongOrCourse();
          break;
        case SORT_MODE_MENU:
          SelectModeMenuItem();
          break;
      }

      // Change difficulty for sorts by meter
      // XXX: do this with GameCommand?
      StepsType st;
      Difficulty dc;
      if (SongUtil::GetStepsTypeAndDifficultyFromSortOrder(
              GAMESTATE->m_SortOrder, st, dc)) {
        if (dc != Difficulty_Invalid) {
          FOREACH_PlayerNumber(p) if (GAMESTATE->IsPlayerEnabled(p))
            GAMESTATE->m_PreferredDifficulty[p]
                .Set(dc);
        }
      }

      if (SCREENMAN != nullptr) {
        SCREENMAN->PostMessageToTopScreen(SM_SongChanged, 0);
      }
      RebuildWheelItems();
      TweenOnScreenForSort();
    } break;

    case STATE_FLYING_ON_AFTER_NEXT_SORT:
      m_WheelState = STATE_SELECTING;  // now, wait for input
      break;

    case STATE_SELECTING:
      m_fTimeLeftInState = 0;
      break;
    case STATE_ROULETTE_SPINNING:
      break;
    case STATE_LOCKED:
      break;
    case STATE_ROULETTE_SLOWING_DOWN:
      if (m_iSwitchesLeftInSpinDown == 0) {
        m_WheelState = STATE_LOCKED;
        m_fTimeLeftInState = 0;
        if (SCREENMAN != nullptr) {
          SCREENMAN->PlayStartSound();
        }
        m_fLockedWheelVelocity = 0;

        // Send this again so the screen starts sample music.
        if (SCREENMAN != nullptr) {
          SCREENMAN->PostMessageToTopScreen(SM_SongChanged, 0);
        }
        if (MESSAGEMAN != nullptr) {
          MESSAGEMAN->Broadcast("RouletteStopped");
        }
      } else {
        --m_iSwitchesLeftInSpinDown;
        const float SwitchTimes[] = {0.5f, 1.3f, 0.8f, 0.4f, 0.2f};
        m_iSwitchesLeftInSpinDown =
            std::clamp(m_iSwitchesLeftInSpinDown, 0, 4);
        m_fTimeLeftInState = SwitchTimes[m_iSwitchesLeftInSpinDown];
        m_Moving = 0;

        if (LOG != nullptr) {
          LOG->Trace(
              "m_iSwitchesLeftInSpinDown id %d, m_fTimeLeftInState is %f",
              m_iSwitchesLeftInSpinDown, m_fTimeLeftInState);
        }

        if (m_iSwitchesLeftInSpinDown == 0) {
          ChangeMusic(randomf(0, 1) >= 0.5f ? 1 : -1);
        } else {
          ChangeMusic(1);
        }
      }
      break;
    default:
      WarnMusicWheel(
          ssprintf("SRC_AUDIT_FIX SRC-1367: invalid wheel state %i.",
                   m_WheelState));
      m_WheelState = STATE_SELECTING;
      m_fTimeLeftInState = 0;
  }
}

void MusicWheel::ChangeMusic(int iDist) {
  if (m_CurWheelItemData.empty()) {
    m_bEmpty = true;
    m_Moving = 0;
    return;
  }

  iDist = NormalizeMoveDistance(iDist);
  if (iDist == 0) {
    return;
  }

  m_iSelection += iDist;
  wrap(m_iSelection, m_CurWheelItemData.size());

  if (REMIND_WHEEL_POSITIONS && HIDE_INACTIVE_SECTIONS && SONGMAN != nullptr) {
    // store the group song index
    for (unsigned idx = 0; idx < m_viWheelPositions.size(); idx++) {
      if (m_sExpandedSectionName == SONGMAN->GetSongGroupByIndex(idx)) {
        m_viWheelPositions[idx] = m_iSelection;
      }
    }
  }

  RebuildWheelItems(iDist);

  m_fPositionOffsetFromSelection += iDist;

  if (SCREENMAN != nullptr) {
    SCREENMAN->PostMessageToTopScreen(SM_SongChanged, 0);
  }

  // If we're moving automatically, don't play this; it'll be called in Update.
  if (!IsMoving()) {
    PlaySoundIfLoaded(m_soundChangeMusic, true);
  }
}

bool MusicWheel::ChangeSort(
    SortOrder new_so, bool allowSameSort)  // return true if change successful
{
  if (!IsValidSortOrderForWheel(new_so) || GAMESTATE == nullptr) {
    WarnMusicWheel(
        ssprintf("SRC_AUDIT_FIX SRC-1369: rejected sort %i.", new_so));
    return false;
  }
  // Reset LastOpenSection as sections differ between sorts
  GAMESTATE->sLastOpenSection = "";
  // NOTE(crashcringle): Ignore allowSameSort if we're using SORT_PREFERRED.
  // Each player has their own preferred songs which sorts the songs differently
  if (GAMESTATE->m_SortOrder == new_so &&
      (!allowSameSort && new_so != SORT_PREFERRED)) {
    return false;
  }

  // Don't change to SORT_MODE_MENU if it doesn't have at least two choices.
  if (new_so == SORT_MODE_MENU && getWheelItemsData(new_so).size() < 2) {
    return false;
  }

  switch (m_WheelState) {
    case STATE_SELECTING:
    case STATE_FLYING_ON_AFTER_NEXT_SORT:
      break;  // fall through
    default:
      return false;  // don't continue
  }

  if (SCREENMAN != nullptr) {
    SCREENMAN->PostMessageToTopScreen(SM_SortOrderChanging, 0);
  }

  PlaySoundIfLoaded(m_soundChangeSort, true);

  TweenOffScreenForSort();

  // Save the new preference.
  if (IsSongSort(new_so)) {
    GAMESTATE->m_PreferredSortOrder = new_so;
  }
  GAMESTATE->m_SortOrder.Set(new_so);

  return true;
}

bool MusicWheel::NextSort()  // return true if change successful
{
  if (GAMESTATE == nullptr || LUA == nullptr) {
    return false;
  }
  // don't allow NextSort when on the mode menu
  if (GAMESTATE->m_SortOrder == SORT_MODE_MENU) {
    return false;
  }

  std::vector<SortOrder> aSortOrders;
  {
    Lua* L = LUA->Get();
    SORT_ORDERS.PushSelf(L);
    FOREACH_LUATABLEI(L, -1, i) {
      SortOrder so = Enum::Check<SortOrder>(L, -1, true);
      if (IsValidSortOrderForWheel(so)) {
        aSortOrders.push_back(so);
      }
    }
    lua_pop(L, 1);
    LUA->Release(L);
  }

  if (aSortOrders.empty()) {
    return false;
  }

  // find the index of the current sort
  int cur = 0;
  while (cur < int(aSortOrders.size()) &&
         aSortOrders[cur] != GAMESTATE->m_SortOrder) {
    ++cur;
  }

  // move to the next sort with wrapping
  ++cur;
  wrap(cur, aSortOrders.size());

  // apply new sort
  SortOrder soNew = aSortOrders[cur];
  return ChangeSort(soNew);
}

bool MusicWheel::Select()  // return true if this selection ends the screen
{
  if (LOG != nullptr) {
    LOG->Trace("MusicWheel::Select()");
  }

  switch (m_WheelState) {
    case STATE_FLYING_OFF_BEFORE_NEXT_SORT:
    case STATE_ROULETTE_SLOWING_DOWN:
      return false;
    case STATE_ROULETTE_SPINNING:
      m_WheelState = STATE_ROULETTE_SLOWING_DOWN;
      {
        const int slowDownSwitches = std::clamp(
            ROULETTE_SLOW_DOWN_SWITCHES.GetValue(), 1,
            MAX_ROULETTE_SLOWDOWN_SWITCHES);
        const int randomBound = std::max(1, slowDownSwitches / 2);
        m_iSwitchesLeftInSpinDown = std::clamp(
            slowDownSwitches / 2 + 1 + RandomInt(randomBound), 1,
            MAX_ROULETTE_SLOWDOWN_SWITCHES);
      }
      m_fTimeLeftInState = 0.1f;
      return false;
    default:
      break;
  }

  if (!WheelBase::Select()) {
    return false;
  }

  MusicWheelItemData* selected = GetCurWheelItemData(m_iSelection);
  if (selected == nullptr) {
    return false;
  }

  switch (selected->m_Type) {
    case WheelItemDataType_Roulette:
      StartRoulette();
      return false;
    case WheelItemDataType_Random:
      StartRandom();
      return false;
    case WheelItemDataType_Sort:
      if (selected->m_pAction.isNull()) {
        return false;
      }
      selected->m_pAction->ApplyToAllPlayers();
      ChangeSort(
          GAMESTATE != nullptr ? GAMESTATE->m_PreferredSortOrder : SORT_GROUP);
      m_sLastModeMenuItem = selected->m_pAction->m_sName;
      return false;
    case WheelItemDataType_Custom:
      if (selected->m_pAction.isNull()) {
        return false;
      }
      selected->m_pAction->ApplyToAllPlayers();
      if (selected->m_pAction->m_sScreen != "") {
        return true;
      } else {
        return false;
      }
    default:
      return true;
  }
}

void MusicWheel::StartRoulette() {
  if (MESSAGEMAN != nullptr) {
    MESSAGEMAN->Broadcast("StartRoulette");
  }
  m_WheelState = STATE_ROULETTE_SPINNING;
  m_Moving = 1;
  m_TimeBeforeMovingBegins = 0;
  const float rouletteSeconds = ROULETTE_SWITCH_SECONDS.GetValue();
  m_SpinSpeed =
      1.0f / (std::isfinite(rouletteSeconds) && rouletteSeconds > 0.0f
                  ? rouletteSeconds
                  : MIN_ROULETTE_SWITCH_SECONDS);
  if (GAMESTATE != nullptr && m_sExpandedSectionName == "") {
    GAMESTATE->m_SortOrder.Set(SORT_ROULETTE);
  }

  const SortOrder currentSort = GetCurrentSortOrderOrDefault();
  if (IsValidSortOrderForWheel(currentSort)) {
    m_WheelItemDatasStatus[currentSort] = INVALID;  // force rebuild
  }
  SetOpenSection(m_sExpandedSectionName);
  readyWheelItemsData(currentSort);
}

void MusicWheel::StartRandom() {
  if (GAMESTATE == nullptr) {
    return;
  }

  if (MESSAGEMAN != nullptr) {
    MESSAGEMAN->Broadcast("StartRandom");
  }
  /* If RANDOM_PICKS_LOCKED_SONGS is disabled, pick a song from the active sort
   * and section.  If enabled, picking from the section makes it too easy to
   * trick the game into picking a locked song, so pick from SORT_ROULETTE. */
  if (RANDOM_PICKS_LOCKED_SONGS) {
    // Shuffle and use the roulette wheel.
    auto& rouletteItems = getWheelItemsData(SORT_ROULETTE);
    std::shuffle(
        rouletteItems.begin(), rouletteItems.end(), g_RandomNumberGenerator);
    GAMESTATE->m_SortOrder.Set(SORT_ROULETTE);
  } else {
    GAMESTATE->m_SortOrder.Set(GAMESTATE->m_PreferredSortOrder);
  }

  Song* selection = GetPreferredSelectionForRandomOrPortal();
  if (selection == nullptr || !SelectSong(selection)) {
    WarnMusicWheel("SRC_AUDIT_FIX SRC-1376: random found no selectable song.");
    m_WheelState = STATE_SELECTING;
    return;
  }

  RebuildWheelItems();
  if (SCREENMAN != nullptr) {
    SCREENMAN->PostMessageToTopScreen(SM_SongChanged, 0);
  }
  TweenOnScreenForSort();
  m_WheelState = STATE_LOCKED;
}

void MusicWheel::SetOpenSection(std::string group) {
  // LOG->Trace( "SetOpenSection %s", group.c_str() );
  m_sExpandedSectionName = group;
  if (GAMESTATE != nullptr) {
    GAMESTATE->sExpandedSectionName = group;
  }

  // wheel positions = num song groups
  if (REMIND_WHEEL_POSITIONS && HIDE_INACTIVE_SECTIONS && SONGMAN != nullptr) {
    m_viWheelPositions.resize(SONGMAN->GetNumSongGroups());
  }

  const WheelItemBaseData* old = nullptr;
  if (!m_CurWheelItemData.empty()) {
    old = GetCurWheelItemData(m_iSelection);
  }

  std::vector<const Style*> vpPossibleStyles;
  if (CommonMetrics::AUTO_SET_STYLE && GAMEMAN != nullptr &&
      GAMESTATE != nullptr) {
    GAMEMAN->GetCompatibleStyles(
        GAMESTATE->m_pCurGame, GAMESTATE->GetNumPlayersEnabled(),
        vpPossibleStyles);
  }

  m_CurWheelItemData.clear();
  std::vector<MusicWheelItemData*>& from =
      getWheelItemsData(GetCurrentSortOrderOrDefault());
  m_CurWheelItemData.reserve(from.size());
  for (unsigned i = 0; i < from.size(); ++i) {
    if (from[i] == nullptr) {
      continue;
    }
    MusicWheelItemData& d = *from[i];

    // Hide songs/courses which are not in the active section
    if ((d.m_Type == WheelItemDataType_Song ||
         d.m_Type == WheelItemDataType_Course) &&
        !d.m_sText.empty() && d.m_sText != group) {
      continue;
    }

    // In certain situations (e.g. simulating Pump it Up or IIDX),
    // themes may want to hide inactive section headings as well.
    if (HIDE_INACTIVE_SECTIONS && d.m_Type == WheelItemDataType_Section &&
        group != "") {
      // Based on the HideActiveSectionTitle metric, we either
      // hide all section titles, or only those which are not
      // currently open.
      if (HIDE_ACTIVE_SECTION_TITLE || d.m_sText != group) {
        continue;
      }
    }

    // If AUTO_SET_STYLE, hide courses that prefer a style that isn't available.
    if (d.m_Type == WheelItemDataType_Course && CommonMetrics::AUTO_SET_STYLE) {
      if (d.m_pCourse == nullptr || GAMESTATE == nullptr) {
        continue;
      }
      const Style* pStyle = d.m_pCourse->GetCourseStyle(
          GAMESTATE->m_pCurGame, GAMESTATE->GetNumSidesJoined());
      if (pStyle) {
        if (find(vpPossibleStyles.begin(), vpPossibleStyles.end(), pStyle) ==
            vpPossibleStyles.end()) {
          continue;
        }
      }
    }

    // Only show tutorial songs in arcade
    if (GAMESTATE != nullptr && GAMESTATE->m_PlayMode != PLAY_MODE_REGULAR &&
        d.m_pSong &&
        d.m_pSong->IsTutorial()) {
      continue;
    }

    m_CurWheelItemData.push_back(&d);
  }

  // restore the past group song index
  if (REMIND_WHEEL_POSITIONS && HIDE_INACTIVE_SECTIONS && SONGMAN != nullptr) {
    for (unsigned idx = 0; idx < m_viWheelPositions.size(); idx++) {
      if (m_sExpandedSectionName == SONGMAN->GetSongGroupByIndex(idx)) {
        m_iSelection = m_viWheelPositions[idx];
      }
    }
  } else {
    // Try to select the item that was selected before changing groups
    m_iSelection = 0;

    for (unsigned i = 0; i < m_CurWheelItemData.size(); i++) {
      if (GAMESTATE != nullptr && GAMESTATE->m_SortOrder == SORT_PREFERRED &&
          !GAMESTATE->sLastOpenSection.empty()) {
        // old doesn't always have data, use LastOpenSection instead
        if (m_CurWheelItemData[i]->m_sText == GAMESTATE->sLastOpenSection) {
          m_iSelection = i;
          break;
        }
      } else if (m_CurWheelItemData[i] == old) {
        m_iSelection = i;
        break;
      }
    }
  }

  if (m_CurWheelItemData.empty()) {
    m_iSelection = 0;
  } else {
    m_iSelection = std::clamp(
        m_iSelection, 0, static_cast<int>(m_CurWheelItemData.size()) - 1);
  }
  RebuildWheelItems();
}

void MusicWheel::GetCurrentSections(std::vector<std::string>& sections) {
  std::vector<MusicWheelItemData*>& wiWheelItems =
      getWheelItemsData(GetCurrentSortOrderOrDefault());
  for (unsigned i = 0; i < wiWheelItems.size(); i++) {
    if (wiWheelItems[i] != nullptr &&
        wiWheelItems[i]->m_Type == WheelItemDataType_Section &&
        !wiWheelItems[i]->m_sText.empty()) {
      sections.push_back(wiWheelItems[i]->m_sText);
    }
  }
}

// sm-ssc additions: jump to group
std::string MusicWheel::JumpToNextGroup() {
  // Thanks to Juanelote for this logic:
  if (HIDE_INACTIVE_SECTIONS) {
    // todo: make it work with other sort types
    if (SONGMAN == nullptr) {
      return "";
    }
    unsigned iNumGroups = SONGMAN->GetNumSongGroups();
    if (iNumGroups == 0) {
      return "";
    }

    for (unsigned i = 0; i < iNumGroups; i++) {
      if (m_sExpandedSectionName == SONGMAN->GetSongGroupByIndex(i)) {
        if (i < iNumGroups - 1) {
          return SONGMAN->GetSongGroupByIndex(i + 1);
        } else {
          // i = 0;
          return SONGMAN->GetSongGroupByIndex(0);
        }
      }
    }
  } else {
    if (m_CurWheelItemData.empty()) {
      return "";
    }
    const int selection =
        std::clamp(m_iSelection, 0, static_cast<int>(m_CurWheelItemData.size()) - 1);
    unsigned int iLastSelection = selection;
    for (unsigned int i = selection; i < m_CurWheelItemData.size(); ++i) {
      const MusicWheelItemData* item = GetCurWheelItemData(i);
      if (item != nullptr && item->m_Type == WheelItemDataType_Section &&
          i != static_cast<unsigned int>(selection)) {
        m_iSelection = i;
        return item->m_sText;
      }
    }
    // it should not get down here, but it might happen... only search up to
    // the previous selection.
    for (unsigned int i = 0; i < iLastSelection; ++i) {
      const MusicWheelItemData* item = GetCurWheelItemData(i);
      if (item != nullptr && item->m_Type == WheelItemDataType_Section &&
          i != static_cast<unsigned int>(selection)) {
        m_iSelection = i;
        return item->m_sText;
      }
    }
  }
  // it shouldn't get here, but just in case...
  return "";
}

std::string MusicWheel::JumpToPrevGroup() {
  if (HIDE_INACTIVE_SECTIONS) {
    if (SONGMAN == nullptr) {
      return "";
    }
    unsigned iNumGroups = SONGMAN->GetNumSongGroups();
    if (iNumGroups == 0) {
      return "";
    }

    for (unsigned i = 0; i < iNumGroups; i++) {
      if (m_sExpandedSectionName == SONGMAN->GetSongGroupByIndex(i)) {
        if (i > 0) {
          return SONGMAN->GetSongGroupByIndex(i - 1);
        } else {
          // i = iNumGroups - 1;
          return SONGMAN->GetSongGroupByIndex(iNumGroups - 1);
        }
      }
    }
  } else {
    if (m_CurWheelItemData.empty()) {
      return "";
    }
    const int selection =
        std::clamp(m_iSelection, 0, static_cast<int>(m_CurWheelItemData.size()) - 1);
    for (unsigned int i = selection; i > 0; --i) {
      const MusicWheelItemData* item = GetCurWheelItemData(i);
      if (item != nullptr && item->m_Type == WheelItemDataType_Section &&
          i != static_cast<unsigned int>(selection)) {
        m_iSelection = i;
        return item->m_sText;
      }
    }
    // in case it wasn't found above:
    for (unsigned int i = m_CurWheelItemData.size() - 1; i > 0; --i) {
      const MusicWheelItemData* item = GetCurWheelItemData(i);
      if (LOG != nullptr) {
        LOG->Trace("JumpToPrevGroup iteration 2 | i = %u", i);
      }
      if (item != nullptr && item->m_Type == WheelItemDataType_Section) {
        m_iSelection = i;
        if (LOG != nullptr) {
          LOG->Trace(
              "finding it in #2 | i = %u | text = %s", i,
              item->m_sText.c_str());
        }
        return item->m_sText;
      }
    }
  }
  // it shouldn't get here, but just in case...
  return "";
}

// Called on late join. Selectable courses may have changed; reopen the section.
void MusicWheel::PlayerJoined() {
  // If someone joins, there may be songs on the wheel that should not be
  // selectable, or there may be songs that have become selectable.
  // Set the status of all the wheel item data vectors to invalid so that
  // readyWheelItemsData will rebuild all the data next time
  // getWheelItemsData is called for that SortOrder.  SetOpenSection calls
  // readyWheelItemsData to get the items, and RebuildWheelItems when its
  // done, so invalidating and calling SetOpenSection is all we need to do.
  // -Kyz
  // Also removed the weird checks for course mode and autogen because
  // it seems weird that courses wouldn't also be affected by a player
  // joining, and not doing it in autogen causes other weird problems. -Kyz
  MarkAllWheelItemDatasInvalid();
  SetOpenSection(m_sExpandedSectionName);
}

bool MusicWheel::IsRouletting() const {
  return m_WheelState == STATE_ROULETTE_SPINNING ||
         m_WheelState == STATE_ROULETTE_SLOWING_DOWN;
}

Song* MusicWheel::GetSelectedSong() {
  const MusicWheelItemData* selected = GetVisualFocusItemData();
  if (selected == nullptr) {
    return nullptr;
  }
  switch (selected->m_Type) {
    case WheelItemDataType_Portal:
      return GetPreferredSelectionForRandomOrPortal();
    default:
      return selected->m_pSong;
  }
}

/* Find a random song.  If possible, find one that has the preferred
 * difficulties of each player.  Prefer songs in the active group, if any.
 *
 * Note that if this is called, we *must* find a song.  We will only be called
 * if the active sort has at least one song, but there may be no open group.
 * This means that any filters and preferences applied here must be optional. */
Song* MusicWheel::GetPreferredSelectionForRandomOrPortal() {
  if (GAMESTATE == nullptr) {
    return nullptr;
  }

  // probe to find a song that has the preferred
  // difficulties of each player
  std::vector<Difficulty> vDifficultiesToRequire;
  FOREACH_HumanPlayer(p) {
    if (GAMESTATE->m_PreferredDifficulty[p] == Difficulty_Invalid) {
      continue;  // skip
    }

    // TRICKY: Don't require that edits be present if perferred
    // difficulty is Difficulty_Edit.  Otherwise, players could use this
    // to set up a 100% chance of getting a particular locked song by
    // having a single edit for a locked song.
    if (GAMESTATE->m_PreferredDifficulty[p] == Difficulty_Edit) {
      continue;  // skip
    }

    vDifficultiesToRequire.push_back(GAMESTATE->m_PreferredDifficulty[p]);
  }

  std::vector<MusicWheelItemData*>& wid =
      getWheelItemsData(GetCurrentSortOrderOrDefault());
  const StepsType st = GetCurrentWheelStepsType(GAMESTATE->GetMasterPlayerNumber());
  if (st == StepsType_Invalid) {
    return nullptr;
  }
  std::vector<MusicWheelItemData*> randomSongs;

  // If we have an open section, only pick from songs in that section.
  if (!m_sExpandedSectionName.empty()) {
    for (unsigned i = 0; i < m_CurWheelItemData.size(); i++) {
      MusicWheelItemData* selection =
          GetCurWheelItemData(i);
      if (selection == nullptr) {
        continue;
      }
      // Filter out non-songs
      if (selection->m_Type != WheelItemDataType_Song) {
        continue;
      }
      // Only add songs in the open section
      if (selection->m_sText == m_sExpandedSectionName) {
        randomSongs.push_back(selection);
      }
    }
  } else {
    // Otherwise, pick from all songs in the current sort.
    for (MusicWheelItemData* item : wid) {
      if (item != nullptr && item->m_Type == WheelItemDataType_Song &&
          item->m_pSong != nullptr) {
        randomSongs.push_back(item);
      }
    }
  }
  if (randomSongs.empty()) {
    return nullptr;
  }
  std::shuffle(randomSongs.begin(), randomSongs.end(), g_RandomNumberGenerator);

#define NUM_PROBES 1000
  for (int i = 0; i < NUM_PROBES; i++) {
    bool isValid = true;
    int iSelection = 0;
    Song* pSong = nullptr;
    iSelection = RandomInt(randomSongs.size());
    MusicWheelItemData* selection =
        randomSongs[iSelection];
    if (selection == nullptr) {
      continue;
    }
    pSong = selection->m_pSong;

    if (pSong == nullptr) {
      continue;
    }

    // There's an off possibility that somebody might have only one song with
    // only beginner steps.
    if (i < 900 && pSong->IsTutorial()) {
      continue;
    }

    // We need to check for difficulty size because when you first enter the
    // music wheel You may not have a preferred difficulty set yet and this
    // would result in every song even songs in other game types, being valid.

    if (i == NUM_PROBES / 2 ||
        PREFSMAN == nullptr || !PREFSMAN->m_bRandomPrioritizeDifficulty) {
      vDifficultiesToRequire.clear();
    }
    if (vDifficultiesToRequire.size() != 0) {
      isValid = std::none_of(
          vDifficultiesToRequire.begin(), vDifficultiesToRequire.end(),
          [&](const Difficulty& d) {
            return !pSong->HasStepsTypeAndDifficulty(st, d);
          });
    } else {
      isValid = pSong->HasStepsType(st);
    }

    Song* song = pSong;
    if (isValid && SongUtil::IsSongPlayable(song)) {
      return pSong;
    }
  }
  LuaHelpers::ReportScriptError("Couldn't find any songs");
  for (MusicWheelItemData* item : randomSongs) {
    if (item != nullptr && item->m_pSong != nullptr) {
      return item->m_pSong;
    }
  }
  return nullptr;
}

void MusicWheel::FinishChangingSorts() {
  FinishTweening();
  m_WheelState = STATE_SELECTING;
  m_fTimeLeftInState = 0;
}

// lua start
#include "LuaBinding.h"

class LunaMusicWheel : public Luna<MusicWheel> {
 public:
  static int ChangeSort(T* p, lua_State* L) {
    if (lua_isnil(L, 1)) {
      lua_pushboolean(L, false);
    } else {
      SortOrder so = Enum::Check<SortOrder>(L, 1);
      lua_pushboolean(L, p->ChangeSort(so));
    }
    return 1;
  }
  DEFINE_METHOD(GetSelectedSection, GetSelectedSection());
  static int GetCurrentSections(T* p, lua_State* L) {
    std::vector<std::string> v;
    p->GetCurrentSections(v);
    LuaHelpers::CreateTableFromArray<std::string>(v, L);
    return 1;
  }
  static int IsRouletting(T* p, lua_State* L) {
    lua_pushboolean(L, p->IsRouletting());
    return 1;
  }
  static int IsLocked(T* p, lua_State* L) {
    lua_pushboolean(L, p->WheelIsLocked());
    return 1;
  }
  static int SelectSong(T* p, lua_State* L) {
    if (lua_isnil(L, 1)) {
      lua_pushboolean(L, false);
    } else {
      Song* pS = Luna<Song>::check(L, 1, true);
      lua_pushboolean(L, p->SelectSong(pS));
    }
    return 1;
  }
  static int SelectCourse(T* p, lua_State* L) {
    if (lua_isnil(L, 1)) {
      lua_pushboolean(L, false);
    } else {
      Course* pC = Luna<Course>::check(L, 1, true);
      lua_pushboolean(L, p->SelectCourse(pC));
    }
    return 1;
  }

  static int Move(T* p, lua_State* L) {
    if (lua_isnil(L, 1)) {
      p->Move(0);
    } else {
      p->Move(IArg(1));
    }
    COMMON_RETURN_SELF;
  }

  LunaMusicWheel() {
    ADD_METHOD(ChangeSort);
    ADD_METHOD(GetSelectedSection);
    ADD_METHOD(IsRouletting);
    ADD_METHOD(IsLocked);
    ADD_METHOD(SelectSong);
    ADD_METHOD(SelectCourse);
    ADD_METHOD(Move);
    ADD_METHOD(GetCurrentSections);
  }
};

LUA_REGISTER_DERIVED_CLASS(MusicWheel, WheelBase)
// lua end

/*
 * (c) 2001-2004 Chris Danford, Chris Gomez, Glenn Maynard
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
