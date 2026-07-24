#include "ScreenSetTime.h"

#include <array>
#include <cmath>
#include <ctime>
#include <limits>
#include <string>

#include "BitmapText.h"
#include "DateTime.h"
#include "EnumHelper.h"
#include "GameInput.h"
#include "InputEventPlus.h"
#include "InputFilter.h"
#include "InputMapper.h"
#include "LocalizedString.h"
#include "PlayerNumber.h"
#include "RageLog.h"
#include "RageTypes.h"
#include "RageUtil.h"
#include "Screen.h"
#include "ScreenManager.h"
#include "ScreenMessage.h"
#include "ScreenWithMenuElements.h"
#include "ThemeManager.h"
#include "Tween.h"
#include "arch/ArchHooks/ArchHooks.h"
#include "global.h"

static const char* SetTimeSelectionNames[] = {
    "Year", "Month", "Day", "Hour", "Minute", "Second",
};
XToString(SetTimeSelection);
XToLocalizedString(SetTimeSelection);
/** @brief A foreach iterator through the time selections. */
#define FOREACH_SetTimeSelection(s) FOREACH_ENUM(SetTimeSelection, s)

namespace {
const std::array<float, NUM_SetTimeSelection> FALLBACK_TITLE_X = {
    240.0f, 240.0f, 240.0f, 240.0f, 240.0f, 240.0f};
const std::array<float, NUM_SetTimeSelection> FALLBACK_VALUE_X = {
    400.0f, 400.0f, 400.0f, 400.0f, 400.0f, 400.0f};
const std::array<float, NUM_SetTimeSelection> FALLBACK_Y = {
    140.0f, 180.0f, 220.0f, 260.0f, 300.0f, 340.0f};

static LocalizedString AM("ScreenSetTime", "am");
static LocalizedString PM("ScreenSetTime", "pm");
static LocalizedString TIME_SET_FAILED(
    "ScreenSetTime", "Could not set the system time.");

bool HasLoadedTheme() { return THEME != nullptr && THEME->IsThemeLoaded(); }

bool IsValidSelection(SetTimeSelection selection) {
  return selection >= year && selection < NUM_SetTimeSelection;
}

SetTimeSelection SanitizeSelection(SetTimeSelection selection) {
  if (IsValidSelection(selection)) {
    return selection;
  }

  if (LOG != nullptr) {
    LOG->Warn(
        "ScreenSetTime reset invalid selection %d.",
        static_cast<int>(selection));
  }
  return year;
}

std::string MetricName(const std::string& prefix, SetTimeSelection selection) {
  return prefix + SetTimeSelectionToString(selection);
}

float GetMetricFOr(
    const std::string& metric, float fallback, const char* context) {
  if (!HasLoadedTheme() || !THEME->HasMetric("ScreenSetTime", metric)) {
    return fallback;
  }

  const float value = THEME->GetMetricF("ScreenSetTime", metric);
  if (!std::isfinite(value)) {
    if (LOG != nullptr) {
      LOG->Warn(
          "ScreenSetTime ignored non-finite %s %.6f "
          "for %s.",
          metric.c_str(), value, context);
    }
    return fallback;
  }
  return value;
}

float GetTitleX(SetTimeSelection selection) {
  const int index = static_cast<int>(selection);
  return GetMetricFOr(
      MetricName("TitleX", selection), FALLBACK_TITLE_X[index], "title x");
}

float GetTitleY(SetTimeSelection selection) {
  const int index = static_cast<int>(selection);
  return GetMetricFOr(MetricName("Y", selection), FALLBACK_Y[index], "title y");
}

float GetValueX(SetTimeSelection selection) {
  const int index = static_cast<int>(selection);
  return GetMetricFOr(
      MetricName("ValueX", selection), FALLBACK_VALUE_X[index], "value x");
}

float GetValueY(SetTimeSelection selection) {
  const int index = static_cast<int>(selection);
  return GetMetricFOr(MetricName("Y", selection), FALLBACK_Y[index], "value y");
}

std::string GetThemePathFOptional(
    const std::string& group, const std::string& element) {
  if (!HasLoadedTheme()) {
    return "";
  }
  return THEME->GetPathF(group, element, true);
}

bool LoadFontWithFallback(
    BitmapText& text, const std::string& element,
    const std::string& fallbackElement) {
  const std::string requested = GetThemePathFOptional("ScreenSetTime", element);
  if (!requested.empty() && text.LoadFromFont(requested)) {
    return true;
  }

  const std::string fallback = GetThemePathFOptional("Common", fallbackElement);
  if (!fallback.empty() && text.LoadFromFont(fallback)) {
    return true;
  }

  if (LOG != nullptr) {
    LOG->Warn(
        "ScreenSetTime could not load font for %s.",
        element.c_str());
  }
  return false;
}

void LoadSoundOptional(RageSound& sound, const std::string& element) {
  if (!HasLoadedTheme()) {
    return;
  }

  const std::string path = THEME->GetPathS("ScreenSetTime", element, true);
  if (!path.empty()) {
    sound.Load(path);
  }
}

bool SafeAddTime(time_t base, time_t offset, time_t& out) {
  if (offset > 0 && base > std::numeric_limits<time_t>::max() - offset) {
    return false;
  }
  if (offset < 0 && base < std::numeric_limits<time_t>::min() - offset) {
    return false;
  }
  out = base + offset;
  return true;
}

bool SafeSubtractTime(time_t lhs, time_t rhs, time_t& out) {
  if (rhs > 0 && lhs < std::numeric_limits<time_t>::min() + rhs) {
    return false;
  }
  if (rhs < 0 && lhs > std::numeric_limits<time_t>::max() + rhs) {
    return false;
  }
  out = lhs - rhs;
  return true;
}

bool SafeNow(time_t& now) {
  now = time(nullptr);
  return now != static_cast<time_t>(-1);
}

bool SafeLocalTime(time_t value, tm& out) {
  ZERO(out);
  return localtime_r(&value, &out) != nullptr;
}

std::string FormatHour(const tm& time) {
  int prettyHour = time.tm_hour % 12;
  if (prettyHour == 0) {
    prettyHour = 12;
  }
  return ssprintf(
      "%d %s", prettyHour, time.tm_hour >= 12 ? PM.GetValue().c_str()
                                              : AM.GetValue().c_str());
}

std::string FormatMonth(const tm& time) {
  if (time.tm_mon < 0 || time.tm_mon >= NUM_Month) {
    if (LOG != nullptr) {
      LOG->Warn(
          "ScreenSetTime clamped invalid month %d.",
          time.tm_mon);
    }
    return "?";
  }
  return MonthToLocalizedString(static_cast<Month>(time.tm_mon));
}

bool IsPlayerInput(PlayerNumber pn) { return pn >= PLAYER_1 && pn < NUM_PLAYERS; }
}  // namespace

REGISTER_SCREEN_CLASS(ScreenSetTime);

void ScreenSetTime::Init() {
  ScreenWithMenuElements::Init();

  m_TimeOffset = 0;
  m_Selection = hour;

  FOREACH_SetTimeSelection(s) {
    BitmapText& title = m_textTitle[s];
    BitmapText& value = m_textValue[s];

    LoadFontWithFallback(title, "Title", "title");
    title.SetDiffuse(RageColor(1, 1, 1, 1));
    title.SetText(SetTimeSelectionToLocalizedString(s));
    title.SetXY(GetTitleX(s), GetTitleY(s));
    this->AddChild(&title);

    title.SetDiffuse(RageColor(1, 1, 1, 0));
    title.BeginTweening(0.3f, TWEEN_LINEAR);
    title.SetDiffuse(RageColor(1, 1, 1, 1));

    LoadFontWithFallback(value, "Value", "normal");
    value.SetDiffuse(RageColor(1, 1, 1, 1));
    value.SetXY(GetValueX(s), GetValueY(s));
    this->AddChild(&value);

    value.SetDiffuse(RageColor(1, 1, 1, 0));
    value.BeginTweening(0.3f, TWEEN_LINEAR);
    value.SetDiffuse(RageColor(1, 1, 1, 1));
  }

  LoadSoundOptional(m_soundChangeSelection, "ChangeSelection");
  LoadSoundOptional(m_soundChangeValue, "ChangeValue");

  ChangeSelection(0);
  RefreshDisplayedTime();
}

void ScreenSetTime::Update(float fDelta) {
  Screen::Update(fDelta);
  RefreshDisplayedTime();
}

bool ScreenSetTime::GetAdjustedLocalTime(tm& adjusted) const {
  time_t now;
  if (!SafeNow(now)) {
    if (LOG != nullptr) {
      LOG->Warn("ScreenSetTime could not read time().");
    }
    return false;
  }

  time_t adjustedTime;
  if (!SafeAddTime(now, m_TimeOffset, adjustedTime)) {
    if (LOG != nullptr) {
      LOG->Warn(
          "ScreenSetTime refused overflowing time "
          "offset.");
    }
    return false;
  }

  if (!SafeLocalTime(adjustedTime, adjusted)) {
    if (LOG != nullptr) {
      LOG->Warn(
          "ScreenSetTime could not convert adjusted "
          "time.");
    }
    return false;
  }

  return true;
}

bool ScreenSetTime::SetAdjustedTime(const tm& adjusted) {
  time_t now;
  if (!SafeNow(now)) {
    return false;
  }

  tm normalized = adjusted;
  normalized.tm_isdst = -1;
  const time_t adjustedTime = mktime(&normalized);
  if (adjustedTime == static_cast<time_t>(-1)) {
    if (LOG != nullptr) {
      LOG->Warn(
          "ScreenSetTime mktime() rejected adjusted "
          "time.");
    }
    return false;
  }

  time_t newOffset;
  if (!SafeSubtractTime(adjustedTime, now, newOffset)) {
    if (LOG != nullptr) {
      LOG->Warn(
          "ScreenSetTime refused overflowing time "
          "offset subtraction.");
    }
    return false;
  }
  m_TimeOffset = newOffset;
  return true;
}

void ScreenSetTime::RefreshDisplayedTime() {
  tm now;
  if (!GetAdjustedLocalTime(now)) {
    return;
  }

  m_textValue[hour].SetText(FormatHour(now));
  m_textValue[minute].SetText(ssprintf("%02d", now.tm_min));
  m_textValue[second].SetText(ssprintf("%02d", now.tm_sec));
  m_textValue[year].SetText(ssprintf("%04d", now.tm_year + 1900));
  m_textValue[month].SetText(FormatMonth(now));
  m_textValue[day].SetText(ssprintf("%02d", now.tm_mday));
}

bool ScreenSetTime::Input(const InputEventPlus& input) {
  if (input.type != IET_FIRST_PRESS && input.type != IET_REPEAT) {
    return false;  // ignore
  }

  if (IsTransitioning()) {
    return false;
  }
  if (m_fLockInputSecs > 0) {
    return false;
  }

  return Screen::Input(input);  // default handler
}

void ScreenSetTime::ChangeValue(int iDirection) {
  tm adjusted;
  if (!GetAdjustedLocalTime(adjusted)) {
    if (SCREENMAN != nullptr) {
      SCREENMAN->PlayInvalidSound();
    }
    return;
  }

  // tm now = GetLocalTime();
  m_Selection = SanitizeSelection(m_Selection);
  switch (m_Selection) {
    case hour:
      adjusted.tm_hour += iDirection;
      break;
    case minute:
      adjusted.tm_min += iDirection;
      break;
    case second:
      adjusted.tm_sec += iDirection;
      break;
    case year:
      adjusted.tm_year += iDirection;
      break;
    case month:
      adjusted.tm_mon += iDirection;
      break;
    case day:
      adjusted.tm_mday += iDirection;
      break;
    default:
      if (SCREENMAN != nullptr) {
        SCREENMAN->PlayInvalidSound();
      }
      return;
  }

  if (!SetAdjustedTime(adjusted)) {
    if (SCREENMAN != nullptr) {
      SCREENMAN->PlayInvalidSound();
    }
    return;
  }

  RefreshDisplayedTime();
  if (m_soundChangeValue.IsLoaded()) {
    m_soundChangeValue.Play(true);
  }
}

void ScreenSetTime::ChangeSelection(int iDirection) {
  // set new value of m_Selection
  m_Selection = SanitizeSelection(m_Selection);
  SetTimeSelection OldSelection = m_Selection;
  enum_add<SetTimeSelection>(m_Selection, iDirection);

  enum_clamp(
      m_Selection, SetTimeSelection(0),
      SetTimeSelection(NUM_SetTimeSelection - 1));
  if (iDirection != 0 && m_Selection == OldSelection) {
    return;  // can't move any more
  }

  m_textValue[OldSelection].StopEffect();
  m_textValue[m_Selection].SetEffectDiffuseShift(
      1.f, RageColor(0.3f, 0.3f, 0.3f, 1), RageColor(1, 1, 1, 1));

  if (iDirection != 0) {
    if (m_soundChangeSelection.IsLoaded()) {
      m_soundChangeSelection.Play(true);
    }
  }
}

bool ScreenSetTime::MenuUp(const InputEventPlus& input) {
  ChangeSelection(-1);
  return true;
}

bool ScreenSetTime::MenuDown(const InputEventPlus& input) {
  ChangeSelection(+1);
  return true;
}

bool ScreenSetTime::MenuLeft(const InputEventPlus& input) {
  ChangeValue(-1);
  return true;
}

bool ScreenSetTime::MenuRight(const InputEventPlus& input) {
  ChangeValue(+1);
  return true;
}

bool ScreenSetTime::MenuStart(const InputEventPlus& input) {
  const bool bCanCheckHeldButtons =
      INPUTMAPPER != nullptr && IsPlayerInput(input.pn);
  bool bHoldingLeftAndRight =
      bCanCheckHeldButtons &&
      INPUTMAPPER->IsBeingPressed(GAME_BUTTON_RIGHT, input.pn) &&
      INPUTMAPPER->IsBeingPressed(GAME_BUTTON_LEFT, input.pn);

  if (bHoldingLeftAndRight) {
    ChangeSelection(-1);
  } else if (m_Selection == NUM_SetTimeSelection - 1)  // last row
  {
    if (!CommitAdjustedTime()) {
      return true;
    }

    /* We're going to draw a little more while we transition out.  We've already
     * set the new time; don't over-adjust visually. */
    m_TimeOffset = 0;

    TweenTimeRowsOff();

    if (SCREENMAN != nullptr) {
      SCREENMAN->PlayStartSound();
    }
    StartTransitioningScreen(SM_GoToNextScreen);
  } else {
    ChangeSelection(+1);
  }
  return true;
}

bool ScreenSetTime::MenuSelect(const InputEventPlus& input) {
  ChangeSelection(-1);
  return true;
}

bool ScreenSetTime::MenuBack(const InputEventPlus& input) {
  Cancel(SM_GoToPrevScreen);
  return true;
}

bool ScreenSetTime::CommitAdjustedTime() {
  tm adjusted;
  if (!GetAdjustedLocalTime(adjusted)) {
    if (SCREENMAN != nullptr) {
      SCREENMAN->PlayInvalidSound();
    }
    return false;
  }

  if (HOOKS == nullptr || !HOOKS->SetTime(adjusted)) {
    if (LOG != nullptr) {
      LOG->Warn(
          "ScreenSetTime could not set the system "
          "time.");
    }
    SetHelpText(TIME_SET_FAILED.GetValue());
    if (SCREENMAN != nullptr) {
      SCREENMAN->PlayInvalidSound();
    }
    return false;
  }

  return true;
}

void ScreenSetTime::TweenTimeRowsOff() {
  FOREACH_SetTimeSelection(s) {
    BitmapText& title = m_textTitle[s];
    title.BeginTweening(0.3f, TWEEN_LINEAR);
    title.SetDiffuse(RageColor(1, 1, 1, 0));

    BitmapText& value = m_textValue[s];
    value.BeginTweening(0.3f, TWEEN_LINEAR);
    value.SetDiffuse(RageColor(1, 1, 1, 0));
  }
}

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
