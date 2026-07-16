#include "ScreenStatsOverlay.h"

#include <cmath>
#include <string>

#include "ActorUtil.h"
#include "LuaManager.h"
#include "MessageManager.h"
#include "PrefsManager.h"
#include "RageDisplay.h"
#include "RageLog.h"
#include "RageTimer.h"
#include "RageTypes.h"
#include "RageUtil.h"
#include "Screen.h"
#include "ThemeManager.h"

REGISTER_SCREEN_CLASS(ScreenStatsOverlay);

namespace {
const char* SHOW_SKIPS_METRIC = "ShowSkips";
const char* SKIP_X_METRIC = "SkipX";
const char* SKIP_Y_METRIC = "SkipY";
const char* SKIP_SPACING_Y_METRIC = "SkipSpacingY";
const char* SKIP_WIDTH_METRIC = "SkipWidth";
const char* SHOW_STATS_CHANGED_COMMAND = "ShowStatsChangedCommand";

bool CanReadThemeMetrics() {
  return THEME != nullptr && THEME->IsThemeLoaded() && LUA != nullptr;
}

bool HasLoadedTheme() { return THEME != nullptr && THEME->IsThemeLoaded(); }

bool HasThemeMetric(const std::string& group, const char* metric) {
  return HasLoadedTheme() && THEME->HasMetric(group, metric);
}

bool GetThemeMetricBoolOrDefault(
    const std::string& group, const char* metric, bool default_value) {
  if (!CanReadThemeMetrics() || !THEME->HasMetric(group, metric)) {
    return default_value;
  }
  return THEME->GetMetricB(group, metric);
}

float GetThemeMetricFloatOrDefault(
    const std::string& group, const char* metric, float default_value) {
  if (!CanReadThemeMetrics() || !THEME->HasMetric(group, metric)) {
    return default_value;
  }
  return THEME->GetMetricF(group, metric);
}

std::string GetOptionalFontPath(
    const std::string& group, const std::string& element) {
  if (!HasLoadedTheme()) {
    return "";
  }
  return THEME->GetPathF(group, element, true);
}

bool LoadFontWithFallback(
    BitmapText& text, const std::string& group, const std::string& element) {
  std::string font = GetOptionalFontPath(group, element);
  if (font.empty()) {
    font = GetOptionalFontPath("Common", "normal");
  }
  if (font.empty()) {
    if (LOG != nullptr) {
      LOG->Warn(
          "ScreenStatsOverlay could not resolve font %s/%s or fallback "
          "Common/normal.",
          group.c_str(), element.c_str());
    }
    return false;
  }

  if (!text.LoadFromFont(font)) {
    if (LOG != nullptr) {
      LOG->Warn(
          "ScreenStatsOverlay failed to load font '%s' for %s/%s.",
          font.c_str(), group.c_str(), element.c_str());
    }
    return false;
  }

  return true;
}

bool IsFinite(float value) { return std::isfinite(value); }

bool IsPositiveFinite(float value) {
  return std::isfinite(value) && value > 0.0f;
}
}  // namespace

void ScreenStatsOverlay::Init() {
  Screen::Init();

  LoadStatsText();

  /* "Was that a skip?"  This displays a message when an update takes
   * abnormally long, to quantify skips more precisely, verify them
   * when they're subtle, and show the time it happened, so you can pinpoint
   * the time in the log. */
  m_LastSkip = 0;

  LoadSkipOverlay();

  // Optional hook for themes that define a ShowStatsChangedCommand.
  if (MESSAGEMAN != nullptr &&
      HasThemeMetric(m_sName, SHOW_STATS_CHANGED_COMMAND)) {
    this->SubscribeToMessage("ShowStatsChanged");
  }
}

void ScreenStatsOverlay::Update(float fDeltaTime) {
  Screen::Update(fDeltaTime);

  if (PREFSMAN == nullptr) {
    m_bShowStatsWasOn = false;
    this->SetVisible(false);
    return;
  }

  const bool show_stats = PREFSMAN->m_bShowStats.Get();
  if (show_stats && !m_bShowStatsWasOn) {
    // Reset skip timer when we toggle Stats on so we don't show a large skip
    // from the span when stats were turned off.
    m_timerSkip.Touch();
  }
  m_bShowStatsWasOn = show_stats;

  this->SetVisible(show_stats);
  if (show_stats && DISPLAY != nullptr) {
    if (m_bStatsTextLoaded) {
      m_textStats.SetText(DISPLAY->GetStats());
    }
    if (m_bShowSkips) {
      UpdateSkips();
    }
  }
}

void ScreenStatsOverlay::LoadStatsText() {
  m_textStats.SetName("Stats");
  m_bStatsTextLoaded = LoadFontWithFallback(m_textStats, m_sName, "stats");
  if (!m_bStatsTextLoaded) {
    return;
  }

  if (HasLoadedTheme()) {
    LOAD_ALL_COMMANDS_AND_SET_XY_AND_ON_COMMAND(m_textStats);
  }
  this->AddChild(&m_textStats);
}

void ScreenStatsOverlay::LoadSkipOverlay() {
  m_bShowSkips =
      GetThemeMetricBoolOrDefault(m_sName, SHOW_SKIPS_METRIC, false);
  if (!m_bShowSkips) {
    return;
  }

  m_fSkipX = GetThemeMetricFloatOrDefault(m_sName, SKIP_X_METRIC, 0.0f);
  m_fSkipY = GetThemeMetricFloatOrDefault(m_sName, SKIP_Y_METRIC, 0.0f);
  m_fSkipSpacingY =
      GetThemeMetricFloatOrDefault(m_sName, SKIP_SPACING_Y_METRIC, 0.0f);
  m_fSkipWidth =
      GetThemeMetricFloatOrDefault(m_sName, SKIP_WIDTH_METRIC, 0.0f);

  if (!IsFinite(m_fSkipX) || !IsFinite(m_fSkipY) ||
      !IsPositiveFinite(m_fSkipSpacingY) || !IsPositiveFinite(m_fSkipWidth)) {
    if (LOG != nullptr) {
      LOG->Warn(
          "ScreenStatsOverlay disabled skip overlay due to invalid metrics "
          "x=%.3f y=%.3f spacing=%.3f width=%.3f.",
          m_fSkipX, m_fSkipY, m_fSkipSpacingY, m_fSkipWidth);
    }
    m_bShowSkips = false;
    return;
  }

  const RectF rectSkips = RectF(
      m_fSkipX - m_fSkipWidth / 2,
      m_fSkipY - (m_fSkipSpacingY * NUM_SKIPS_TO_SHOW) / 2 - 10,
      m_fSkipX + m_fSkipWidth / 2,
      m_fSkipY + (m_fSkipSpacingY * NUM_SKIPS_TO_SHOW) / 2 + 10);

  for (int i = 0; i < NUM_SKIPS_TO_SHOW; i++) {
    /* This is somewhat big.  Let's put it on the right side, where it'll
     * obscure the 2P side during gameplay; there's nowhere to put it that
     * doesn't obscure something, and it's just a diagnostic. */
    if (!LoadFontWithFallback(m_textSkips[i], "Common", "normal")) {
      m_bShowSkips = false;
      return;
    }
    m_textSkips[i].SetX(m_fSkipX);
    m_textSkips[i].SetY(SCALE(
        i, 0, NUM_SKIPS_TO_SHOW - 1, rectSkips.top + 10,
        rectSkips.bottom - 10));
    m_textSkips[i].SetDiffuse(RageColor(1, 1, 1, 0));
    m_textSkips[i].SetShadowLength(0);
  }

  m_quadSkipBackground.StretchTo(rectSkips);
  m_quadSkipBackground.SetDiffuse(RageColor(0, 0, 0, 0.4f));
  this->AddChild(&m_quadSkipBackground);

  for (int i = 0; i < NUM_SKIPS_TO_SHOW; i++) {
    this->AddChild(&m_textSkips[i]);
  }
}

void ScreenStatsOverlay::AddTimestampLine(
    const std::string& txt, const RageColor& color) {
  m_textSkips[m_LastSkip].SetText(txt);
  m_textSkips[m_LastSkip].StopTweening();
  m_textSkips[m_LastSkip].SetDiffuse(RageColor(1, 1, 1, 1));
  m_textSkips[m_LastSkip].BeginTweening(0.2f);
  m_textSkips[m_LastSkip].SetDiffuse(color);
  m_textSkips[m_LastSkip].BeginTweening(3.0f);
  m_textSkips[m_LastSkip].BeginTweening(0.2f);
  m_textSkips[m_LastSkip].SetDiffuse(RageColor(1, 1, 1, 0));

  m_LastSkip++;
  m_LastSkip %= NUM_SKIPS_TO_SHOW;
}

void ScreenStatsOverlay::UpdateSkips() {
  /* Use our own timer, so we ignore `/tab. */
  const float UpdateTime = m_timerSkip.GetDeltaTime();
  if (!std::isfinite(UpdateTime) || DISPLAY == nullptr) {
    return;
  }

  /* FPS is 0 for a little while after we load a screen; don't report
   * during this time. Do clear the timer, though, so we don't report
   * a big "skip" after this period passes. */
  const int fps = DISPLAY->GetFPS();
  if (fps <= 0) {
    return;
  }

  /* We want to display skips.  We expect to get updates of about 1.0/FPS ms. */
  const float ExpectedUpdate = 1.0f / fps;
  if (!std::isfinite(ExpectedUpdate) || ExpectedUpdate <= 0.0f) {
    return;
  }

  /* These are thresholds for severity of skips.  The smallest
   * is slightly above expected, to tolerate normal jitter. */
  int skip = 0;
  if (UpdateTime > ExpectedUpdate * 2.0f) {
    skip = 1;
  }
  if (UpdateTime > ExpectedUpdate * 4.0f) {
    skip = 2;
  }
  if (UpdateTime > 0.1f) {
    skip = 3;
  }

  if (skip) {
    std::string sTime(
        MicrosecondsToMMSSMsMs(RageTimer::GetTimeSinceStartMicroseconds()));

    static const RageColor colors[] = {
        RageColor(0, 0, 0, 0),          /* unused */
        RageColor(1.0f, 1.0f, 1.0f, 1), /* white*/
        RageColor(1.0f, 1.0f, 0.0f, 1), /* yellow */
        RageColor(1.0f, 0.4f, 0.4f, 1)  /* light red */
    };

    AddTimestampLine(
        ssprintf(
            "%s: %.0fms (%.0f)", sTime.c_str(), 1000 * UpdateTime,
            UpdateTime / ExpectedUpdate),
        colors[skip]);

    if (PREFSMAN != nullptr && PREFSMAN->m_bLogSkips && LOG != nullptr) {
      LOG->Trace(
          "Frame skip: %.0fms (%.0f)", 1000 * UpdateTime,
          UpdateTime / ExpectedUpdate);
    }
  }
}

/*
 * (c) 2001-2005 Chris Danford, Glenn Maynard
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
