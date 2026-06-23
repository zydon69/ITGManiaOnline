#include "ScreenBookkeeping.h"

#include <algorithm>
#include <string>
#include <vector>

#include "ActorUtil.h"
#include "Bookkeeper.h"
#include "DateTime.h"
#include "EnumHelper.h"
#include "InputEventPlus.h"
#include "LocalizedString.h"
#include "Profile.h"
#include "ProfileManager.h"
#include "RageLog.h"
#include "RageUtil.h"
#include "ScreenDimensions.h"
#include "ScreenManager.h"
#include "ScreenMessage.h"
#include "ScreenWithMenuElements.h"
#include "Song.h"
#include "SongManager.h"
#include "SongUtil.h"
#include "StdString.h"
#include "ThemeManager.h"
#include "UnlockManager.h"
#include "global.h"

static const char* BookkeepingViewNames[] = {
    "SongPlays", "LastDays", "LastWeeks", "DayOfWeek", "HourOfDay",
};
XToString(BookkeepingView);

namespace {
void WarnBookkeeping(const std::string& message) {
  if (LOG != nullptr) {
    LOG->Warn("ScreenBookkeeping: %s", message.c_str());
  }
}

bool HasThemeRuntime() {
  return THEME != nullptr && THEME->IsThemeLoaded() && LUA != nullptr;
}

bool IsUsableScreenTarget(const std::string& screenName) {
  return SCREENMAN != nullptr && THEME != nullptr && THEME->IsThemeLoaded() &&
         !screenName.empty() && SCREENMAN->IsScreenNameValid(screenName);
}

bool GetThemeBool(
    const std::string& group, const std::string& metric, bool fallback) {
  if (!HasThemeRuntime()) {
    WarnBookkeeping(
        "Using fallback for metric '" + metric +
        "' because the theme runtime is not ready.");
    return fallback;
  }

  if (!THEME->HasMetric(group, metric)) {
    WarnBookkeeping(
        "Using fallback for missing metric '" + group + "::" + metric + "'.");
    return fallback;
  }

  return THEME->GetMetricB(group, metric);
}

std::string GetFontPath(
    const std::string& group, const std::string& element) {
  if (THEME == nullptr || !THEME->IsThemeLoaded()) {
    return "";
  }
  return THEME->GetPathF(group, element, true);
}

bool LoadFontWithFallback(
    BitmapText& text, const std::string& group, const std::string& element) {
  const std::string requestedFont = GetFontPath(group, element);
  if (!requestedFont.empty() && text.LoadFromFont(requestedFont)) {
    return true;
  }

  const std::string fallbackFont = GetFontPath("Common", "normal");
  if (!fallbackFont.empty() && text.LoadFromFont(fallbackFont)) {
    return true;
  }

  WarnBookkeeping("Failed to load font for '" + group + "::" + element + "'.");
  return false;
}

void LoadCommandsIfPossible(Actor& actor, const std::string& screenName) {
  if (!HasThemeRuntime()) {
    WarnBookkeeping(
        "Skipping actor commands because the theme runtime is not ready.");
    return;
  }
  ActorUtil::LoadAllCommandsAndSetXY(actor, screenName);
}

std::string TruncateUTF8ForSongLine(const std::string& text) {
  constexpr size_t maxCharsBeforeTruncation = 22;
  constexpr size_t charsBeforeEllipsis = 20;
  const std::wstring wideText = RStringToWstring(text);
  if (wideText.size() <= maxCharsBeforeTruncation) {
    return text;
  }
  return WStringToRString(wideText.substr(0, charsBeforeEllipsis)) + "...";
}

void FillCoinsLastDays(int coins[NUM_LAST_DAYS]) {
  std::fill(coins, coins + NUM_LAST_DAYS, 0);
  if (BOOKKEEPER == nullptr) {
    WarnBookkeeping("Cannot read last-days coins because BOOKKEEPER is missing.");
    return;
  }
  BOOKKEEPER->GetCoinsLastDays(coins);
}

void FillCoinsLastWeeks(int coins[NUM_LAST_WEEKS]) {
  std::fill(coins, coins + NUM_LAST_WEEKS, 0);
  if (BOOKKEEPER == nullptr) {
    WarnBookkeeping(
        "Cannot read last-weeks coins because BOOKKEEPER is missing.");
    return;
  }
  BOOKKEEPER->GetCoinsLastWeeks(coins);
}

void FillCoinsByDayOfWeek(int coins[DAYS_IN_WEEK]) {
  std::fill(coins, coins + DAYS_IN_WEEK, 0);
  if (BOOKKEEPER == nullptr) {
    WarnBookkeeping(
        "Cannot read day-of-week coins because BOOKKEEPER is missing.");
    return;
  }
  BOOKKEEPER->GetCoinsByDayOfWeek(coins);
}

void FillCoinsByHour(int coins[HOURS_IN_DAY]) {
  std::fill(coins, coins + HOURS_IN_DAY, 0);
  if (BOOKKEEPER == nullptr) {
    WarnBookkeeping("Cannot read hourly coins because BOOKKEEPER is missing.");
    return;
  }
  BOOKKEEPER->GetCoinsByHour(coins);
}
}  // namespace

REGISTER_SCREEN_CLASS(ScreenBookkeeping);

void ScreenBookkeeping::Init() {
  ScreenWithMenuElements::Init();

  m_textAllTime.SetName("AllTime");
  m_bAllTimeLoaded = LoadFontWithFallback(m_textAllTime, m_sName, "AllTime");
  if (m_bAllTimeLoaded) {
    LoadCommandsIfPossible(m_textAllTime, m_sName);
    this->AddChild(&m_textAllTime);
  }

  m_textTitle.SetName("Title");
  m_bTitleLoaded = LoadFontWithFallback(m_textTitle, m_sName, "title");
  if (m_bTitleLoaded) {
    LoadCommandsIfPossible(m_textTitle, m_sName);
    this->AddChild(&m_textTitle);
  }

  for (size_t i = 0; i < m_textData.size(); i++) {
    m_textData[i].SetName("Data");
    m_bDataLoaded[i] = LoadFontWithFallback(m_textData[i], m_sName, "data");
    if (!m_bDataLoaded[i]) {
      continue;
    }
    LoadCommandsIfPossible(m_textData[i], m_sName);
    float fX = SCALE(
        i, 0.f, NUM_BOOKKEEPING_COLS - 1, SCREEN_LEFT + 50, SCREEN_RIGHT - 160);
    m_textData[i].SetX(fX);
    this->AddChild(&m_textData[i]);
  }

  FOREACH_ENUM(BookkeepingView, i) {
    if (GetThemeBool(m_sName, "Show" + BookkeepingViewToString(i), true)) {
      m_vBookkeepingViews.push_back(i);
    }
  }

  ClampViewIndex();
  UpdateView();
}

bool ScreenBookkeeping::MenuLeft(const InputEventPlus& input) {
  if (!CanNavigateViews(input)) {
    return false;
  }

  m_iViewIndex--;
  ClampViewIndex();

  UpdateView();
  return true;
}

bool ScreenBookkeeping::MenuRight(const InputEventPlus& input) {
  if (!CanNavigateViews(input)) {
    return false;
  }

  m_iViewIndex++;
  ClampViewIndex();

  UpdateView();
  return true;
}

bool ScreenBookkeeping::MenuStart(const InputEventPlus& input) {
  if (!CanLeaveScreen(input)) {
    return false;
  }

  return StartValidatedTransition(
      SM_GoToNextScreen, GetNextScreenName(), "next");
}

bool ScreenBookkeeping::MenuBack(const InputEventPlus& input) {
  if (!CanLeaveScreen(input)) {
    return false;
  }

  return StartValidatedTransition(SM_GoToPrevScreen, GetPrevScreen(), "prev");
}

bool ScreenBookkeeping::MenuCoin(const InputEventPlus& input) {
  if (input.type != IET_FIRST_PRESS || IsInputLocked()) {
    return false;
  }

  const bool handled = Screen::MenuCoin(input);
  UpdateView();

  return handled;
}

static LocalizedString ALL_TIME("ScreenBookkeeping", "All-time Coin Total:");
static LocalizedString SONG_PLAYS("ScreenBookkeeping", "Total Song Plays: %d");
static LocalizedString LAST_DAYS(
    "ScreenBookkeeping", "Coin Data of Last %d Days");
static LocalizedString LAST_WEEKS(
    "ScreenBookkeeping", "Coin Data of Last %d Weeks");
static LocalizedString DAY_OF_WEEK(
    "ScreenBookkeeping", "Coin Data by Day of Week, All-Time");
static LocalizedString HOUR_OF_DAY(
    "ScreenBookkeeping", "Coin Data by Hour of Day, All-Time");
static LocalizedString NO_VIEWS(
    "ScreenBookkeeping", "No bookkeeping views enabled.");

void ScreenBookkeeping::ClampViewIndex() {
  if (m_vBookkeepingViews.empty()) {
    m_iViewIndex = 0;
    return;
  }

  rage_clamp(m_iViewIndex, 0, static_cast<int>(m_vBookkeepingViews.size()) - 1);
}

bool ScreenBookkeeping::CanNavigateViews(const InputEventPlus& input) {
  if (input.type != IET_FIRST_PRESS && input.type != IET_REPEAT) {
    return false;
  }
  return !m_vBookkeepingViews.empty() && !IsTransitioning() && !IsInputLocked();
}

bool ScreenBookkeeping::CanLeaveScreen(const InputEventPlus& input) {
  return input.type == IET_FIRST_PRESS && !IsTransitioning() && !IsInputLocked();
}

bool ScreenBookkeeping::StartValidatedTransition(
    ScreenMessage smSendWhenDone, const std::string& targetScreen,
    const char* context) {
  if (!IsUsableScreenTarget(targetScreen)) {
    WarnBookkeeping(
        "Ignoring invalid " + std::string(context) + " screen '" +
        targetScreen + "'.");
    return false;
  }

  if (SCREENMAN != nullptr) {
    SCREENMAN->PlayStartSound();
  }
  StartTransitioningScreen(smSendWhenDone);
  return true;
}

void ScreenBookkeeping::ClearDataText() {
  for (size_t i = 0; i < m_textData.size(); ++i) {
    SetDataText(i, "", align_left);
  }
}

void ScreenBookkeeping::SetDataText(
    size_t col, const std::string& text, float align) {
  if (col >= m_textData.size() || !m_bDataLoaded[col]) {
    return;
  }
  m_textData[col].SetHorizAlign(align);
  m_textData[col].SetText(text);
}

void ScreenBookkeeping::SetTitleText(const std::string& text) {
  if (m_bTitleLoaded) {
    m_textTitle.SetText(text);
  }
}

void ScreenBookkeeping::SetAllTimeText(const std::string& text) {
  if (m_bAllTimeLoaded) {
    m_textAllTime.SetText(text);
  }
}

void ScreenBookkeeping::UpdateView() {
  ClampViewIndex();
  if (m_vBookkeepingViews.empty()) {
    SetTitleText(NO_VIEWS.GetValue());
    SetAllTimeText("");
    ClearDataText();
    return;
  }

  BookkeepingView view = m_vBookkeepingViews[m_iViewIndex];

  {
    std::string s;
    s += ALL_TIME.GetValue();
    s += ssprintf(
        " %i\n", BOOKKEEPER != nullptr ? BOOKKEEPER->GetCoinsTotal() : 0);
    if (BOOKKEEPER == nullptr) {
      WarnBookkeeping("Cannot read total coins because BOOKKEEPER is missing.");
    }
    SetAllTimeText(s);
  }

  ClearDataText();

  switch (view) {
    case BookkeepingView_SongPlays: {
      Profile* pProfile =
          PROFILEMAN != nullptr ? PROFILEMAN->GetMachineProfile() : nullptr;
      if (pProfile == nullptr || SONGMAN == nullptr) {
        WarnBookkeeping(
            "Cannot show song plays because profile or song manager is "
            "missing.");
        SetTitleText(ssprintf(SONG_PLAYS.GetValue().c_str(), 0));
        break;
      }

      std::vector<Song*> vpSongs;
      int iCount = 0;
      for (Song* pSong : SONGMAN->GetAllSongs()) {
        if (pSong == nullptr) {
          continue;
        }
        if (UNLOCKMAN != nullptr &&
            (UNLOCKMAN->SongIsLocked(pSong) & ~LOCKED_DISABLED)) {
          continue;
        }
        iCount += pProfile->GetSongNumTimesPlayed(pSong);
        vpSongs.push_back(pSong);
      }
      SetTitleText(ssprintf(SONG_PLAYS.GetValue().c_str(), iCount));
      SongUtil::SortSongPointerArrayByNumPlays(vpSongs, pProfile, true);

      const int iSongPerCol = 15;

      int iSongIndex = 0;
      for (int i = 0; i < NUM_BOOKKEEPING_COLS; i++) {
        std::string s;
        for (int j = 0; j < iSongPerCol; j++) {
          if (iSongIndex < (int)vpSongs.size()) {
            Song* pSong = vpSongs[iSongIndex];
            iCount = pProfile->GetSongNumTimesPlayed(pSong);
            std::string sTitle =
                ssprintf("%4d", iCount) + " " + pSong->GetDisplayFullTitle();
            sTitle = TruncateUTF8ForSongLine(sTitle);
            s += sTitle + "\n";
            iSongIndex++;
          }
        }
        SetDataText(i, s, align_left);
      }
    } break;
    case BookkeepingView_LastDays: {
      SetTitleText(ssprintf(LAST_DAYS.GetValue().c_str(), NUM_LAST_DAYS));

      int coins[NUM_LAST_DAYS];
      FillCoinsLastDays(coins);
      int iTotalLast = 0;

      std::string sTitle, sData;
      for (int i = 0; i < NUM_LAST_DAYS; i++) {
        sTitle += LastDayToLocalizedString(i) + "\n";
        sData += ssprintf("%d", coins[i]) + "\n";
        iTotalLast += coins[i];
      }

      sTitle += ALL_TIME.GetValue() + "\n";
      sData += ssprintf("%i\n", iTotalLast);

      SetDataText(1, sTitle, align_left);
      SetDataText(3, sData, align_right);
    } break;
    case BookkeepingView_LastWeeks: {
      SetTitleText(ssprintf(LAST_WEEKS.GetValue().c_str(), NUM_LAST_WEEKS));

      int coins[NUM_LAST_WEEKS];
      FillCoinsLastWeeks(coins);

      const int rowsPerCol =
          (NUM_LAST_WEEKS + NUM_BOOKKEEPING_COLS - 1) / NUM_BOOKKEEPING_COLS;
      for (int col = 0; col < NUM_BOOKKEEPING_COLS; col++) {
        std::string sTemp;
        for (int row = 0; row < rowsPerCol; row++) {
          int week = row * NUM_BOOKKEEPING_COLS + col;
          if (week >= NUM_LAST_WEEKS) {
            continue;
          }
          sTemp += LastWeekToLocalizedString(week) +
                   ssprintf(": %d", coins[week]) + "\n";
        }

        SetDataText(col, sTemp, align_left);
      }
    } break;
    case BookkeepingView_DayOfWeek: {
      SetTitleText(DAY_OF_WEEK.GetValue());

      int coins[DAYS_IN_WEEK];
      FillCoinsByDayOfWeek(coins);

      std::string sTitle, sData;
      for (int i = 0; i < DAYS_IN_WEEK; i++) {
        sTitle += DayOfWeekToLocalizedString(i) + "\n";
        sData += ssprintf("%d", coins[i]) + "\n";
      }

      SetDataText(1, sTitle, align_left);
      SetDataText(3, sData, align_right);
    } break;
    case BookkeepingView_HourOfDay: {
      SetTitleText(HOUR_OF_DAY.GetValue());

      int coins[HOURS_IN_DAY];
      FillCoinsByHour(coins);

      std::string sTitle1, sData1;
      for (int i = 0; i < HOURS_IN_DAY / 2; i++) {
        sTitle1 += HourInDayToLocalizedString(i) + "\n";
        sData1 += ssprintf("%d", coins[i]) + "\n";
      }

      std::string sTitle2, sData2;
      for (int i = (HOURS_IN_DAY / 2); i < HOURS_IN_DAY; i++) {
        sTitle2 += HourInDayToLocalizedString(i) + "\n";
        sData2 += ssprintf("%d", coins[i]) + "\n";
      }

      SetDataText(0, sTitle1, align_left);
      SetDataText(1, sData1, align_right);
      SetDataText(2, sTitle2, align_left);
      SetDataText(3, sData2, align_right);
    } break;
    default:
      WarnBookkeeping(ssprintf("Ignoring invalid BookkeepingView: %i", view));
      SetTitleText(NO_VIEWS.GetValue());
      ClearDataText();
  }
}

/*
 * (c) 2003-2004 Chris Danford
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
