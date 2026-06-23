#include "ScreenSplash.h"

#include "LuaManager.h"
#include "RageLog.h"
#include "RageUtil.h"
#include "Screen.h"
#include "ScreenManager.h"
#include "ScreenMessage.h"
#include "ScreenWithMenuElements.h"
#include "ThemeManager.h"

#include <algorithm>
#include <cmath>

REGISTER_SCREEN_CLASS(ScreenSplash);

namespace {
AutoScreenMessage(SM_PrepareNextScreen);

const char* ALLOW_START_TO_SKIP_METRIC = "AllowStartToSkip";
const char* MINIMUM_SCREEN_PREPARE_DELAY_METRIC =
    "MinimumScreenPrepareDelaySeconds";
const char* PREPARE_SCREEN_METRIC = "PrepareScreen";

bool CanReadThemeMetrics() {
  return THEME != nullptr && THEME->IsThemeLoaded() && LUA != nullptr;
}

bool HasMetric(const std::string& group, const char* metric) {
  return CanReadThemeMetrics() && THEME->HasMetric(group, metric);
}

std::string GetMetricStringOrDefault(
    const std::string& group, const char* metric,
    const std::string& default_value = "") {
  if (!HasMetric(group, metric)) {
    return default_value;
  }
  return THEME->GetMetric(group, metric);
}

bool GetMetricBoolOrDefault(
    const std::string& group, const char* metric, bool default_value) {
  if (!HasMetric(group, metric)) {
    return default_value;
  }
  return THEME->GetMetricB(group, metric);
}

float GetMetricFloatOrDefault(
    const std::string& group, const char* metric, float default_value) {
  if (!HasMetric(group, metric)) {
    return default_value;
  }
  return THEME->GetMetricF(group, metric);
}

std::string Trimmed(std::string value) {
  Trim(value);
  return value;
}

bool EqualsMetricBoolLiteral(const std::string& value, bool expected) {
  const std::string trimmed = Trimmed(value);
  if (expected) {
    return EqualsNoCase(trimmed, "true") || trimmed == "1" ||
           EqualsNoCase(trimmed, "yes");
  }
  return trimmed.empty() || EqualsNoCase(trimmed, "false") || trimmed == "0" ||
         EqualsNoCase(trimmed, "no");
}
}  // namespace

void ScreenSplash::Init() {
  LoadSplashMetrics();

  ScreenWithMenuElements::Init();
}

void ScreenSplash::BeginScreen() {
  m_bPrepareScreenQueued = false;
  ScreenWithMenuElements::BeginScreen();
}

void ScreenSplash::HandleScreenMessage(const ScreenMessage SM) {
  if (SM == SM_DoneFadingIn) {
    QueuePrepareScreen();
  } else if (SM == SM_MenuTimer) {
    if (!IsTransitioning()) {
      StartTransitioningScreen(SM_GoToNextScreen);
    }
    return;
  } else if (SM == SM_PrepareNextScreen) {
    PrepareConfiguredScreen();
    return;
  }

  ScreenWithMenuElements::HandleScreenMessage(SM);
}

bool ScreenSplash::MenuBack(const InputEventPlus& input) {
  if (IsTransitioning() || m_fLockInputSecs > 0) {
    return false;
  }
  Cancel(SM_GoToPrevScreen);
  return true;
}

bool ScreenSplash::MenuStart(const InputEventPlus& input) {
  if (IsTransitioning() || m_fLockInputSecs > 0) {
    return false;
  }
  if (!m_bAllowStartToSkip) {
    return false;
  }
  StartTransitioningScreen(SM_GoToNextScreen);
  return true;
}

void ScreenSplash::LoadSplashMetrics() {
  m_bAllowStartToSkip =
      GetMetricBoolOrDefault(m_sName, ALLOW_START_TO_SKIP_METRIC, false);

  std::string prepare_screen =
      Trimmed(GetMetricStringOrDefault(m_sName, PREPARE_SCREEN_METRIC));
  m_bPrepareNextScreen = EqualsMetricBoolLiteral(prepare_screen, true);
  if (m_bPrepareNextScreen || EqualsMetricBoolLiteral(prepare_screen, false)) {
    m_sPrepareScreenName.clear();
  } else {
    m_sPrepareScreenName = prepare_screen;
  }

  m_fMinimumScreenPrepareDelaySeconds = std::max(
      0.0f, GetMetricFloatOrDefault(
                m_sName, MINIMUM_SCREEN_PREPARE_DELAY_METRIC, 0.0f));
  if (!std::isfinite(m_fMinimumScreenPrepareDelaySeconds)) {
    m_fMinimumScreenPrepareDelaySeconds = 0.0f;
  }
}

void ScreenSplash::QueuePrepareScreen() {
  if (m_bPrepareScreenQueued) {
    return;
  }

  if (GetConfiguredPrepareScreenName().empty()) {
    return;
  }

  m_bPrepareScreenQueued = true;
  if (m_fMinimumScreenPrepareDelaySeconds > 0) {
    PostScreenMessage(
        SM_PrepareNextScreen, m_fMinimumScreenPrepareDelaySeconds);
    return;
  }

  PrepareConfiguredScreen();
}

void ScreenSplash::PrepareConfiguredScreen() {
  const std::string prepare_screen = GetConfiguredPrepareScreenName();
  if (prepare_screen.empty()) {
    return;
  }

  if (SCREENMAN == nullptr) {
    if (LOG != nullptr) {
      LOG->Warn(
          "ScreenSplash %s cannot prepare screen %s because SCREENMAN is not "
          "available.",
          m_sName.c_str(), prepare_screen.c_str());
    }
    return;
  }

  if (!CanReadThemeMetrics() || !SCREENMAN->IsScreenNameValid(prepare_screen)) {
    if (LOG != nullptr) {
      LOG->Warn(
          "ScreenSplash %s ignored invalid PrepareScreen target %s.",
          m_sName.c_str(), prepare_screen.c_str());
    }
    return;
  }

  SCREENMAN->PrepareScreen(prepare_screen);
}

std::string ScreenSplash::GetConfiguredPrepareScreenName() const {
  if (!m_sPrepareScreenName.empty()) {
    return m_sPrepareScreenName;
  }
  if (!m_bPrepareNextScreen || !CanReadThemeMetrics()) {
    return "";
  }
  return GetNextScreenName();
}

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
