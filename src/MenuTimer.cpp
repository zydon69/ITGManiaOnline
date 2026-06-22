#include "MenuTimer.h"

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <string>

#include "Actor.h"
#include "ActorFrame.h"
#include "ActorUtil.h"
#include "GameSoundManager.h"
#include "LuaManager.h"
#include "RageLog.h"
#include "RageUtil.h"
#include "ScreenManager.h"
#include "ScreenMessage.h"
#include "ThemeManager.h"
#include "ThemeMetric.h"
#include "global.h"

std::string WARNING_COMMAND_NAME(size_t i) {
  return ssprintf("Warning%dCommand", int(i));
}

static const float TIMER_PAUSE_SECONDS = 99.99f;

namespace {
void WarnMenuTimer(const char* message) {
  if (LOG != nullptr) {
    LOG->Warn("%s", message);
  }
}

float SanitizeTimerSeconds(float seconds, float fallback = 0.0f) {
  if (!std::isfinite(seconds)) {
    return fallback;
  }
  return std::max(0.0f, seconds);
}

int SanitizeWarningBoundary(int value, int fallback) {
  if (value < 0) {
    return fallback;
  }
  return std::min(value, 999);
}

float SanitizeTimerMetric(float value, float fallback) {
  if (!std::isfinite(value) || value < 0.0f) {
    return fallback;
  }
  return value;
}

std::string FormatTimerFallback(float seconds, int textIndex) {
  if (textIndex > 0) {
    return "";
  }
  const float safeSeconds = SanitizeTimerSeconds(seconds);
  const int displaySeconds =
      std::min(999, static_cast<int>(std::ceil(safeSeconds)));
  return ssprintf("%d", displaySeconds);
}
}  // namespace

MenuTimer::MenuTimer() {
  m_fSecondsLeft = TIMER_PAUSE_SECONDS;
  m_fStallSeconds = 0;
  m_fStallSecondsLeft = 0;
  m_bPaused = false;
  m_bSilent = false;
  WARNING_COMMAND = nullptr;
  m_iWarningStart = 10;
  m_iWarningBeepStart = 8;
  m_fMaxStallSeconds = 0.0f;
  m_fHurryUpTransition = 5.5f;
}

MenuTimer::MenuTimer(const MenuTimer& cpy)
    : ActorFrame(cpy),
      m_fSecondsLeft(cpy.m_fSecondsLeft),
      m_fStallSeconds(cpy.m_fStallSeconds),
      m_fStallSecondsLeft(cpy.m_fStallSecondsLeft),
      m_bPaused(cpy.m_bPaused),
      m_bSilent(cpy.m_bSilent),
      m_sprFrame(cpy.m_sprFrame),
      m_soundBeep(cpy.m_soundBeep),
      WARNING_COMMAND(nullptr),
      m_iWarningStart(cpy.m_iWarningStart),
      m_iWarningBeepStart(cpy.m_iWarningBeepStart),
      m_fMaxStallSeconds(cpy.m_fMaxStallSeconds),
      m_fHurryUpTransition(cpy.m_fHurryUpTransition) {
  if (m_sprFrame.IsLoaded()) {
    AddChild(m_sprFrame);
  }
  for (int i = 0; i < NUM_MENU_TIMER_TEXTS; i++) {
    m_text[i] = cpy.m_text[i];
    m_exprFormatText[i] = cpy.m_exprFormatText[i];
    AddChild(&m_text[i]);
  }
}

MenuTimer::~MenuTimer() { delete WARNING_COMMAND; }

void MenuTimer::Load(std::string sMetricsGroup) {
  RemoveChild(m_sprFrame);
  for (int i = 0; i < NUM_MENU_TIMER_TEXTS; i++) {
    RemoveChild(&m_text[i]);
  }

  if (THEME != nullptr && !sMetricsGroup.empty()) {
    m_sprFrame.Load(THEME->GetPathG(sMetricsGroup, "Frame"));
  } else {
    WarnMenuTimer("SRC_AUDIT_FIX SRC-1176: MenuTimer loaded without THEME.");
    m_sprFrame.Load(new Actor);
  }
  if (m_sprFrame.IsLoaded()) {
    m_sprFrame->SetName("Frame");
    if (THEME != nullptr && !sMetricsGroup.empty()) {
      ActorUtil::LoadAllCommandsAndSetXY(m_sprFrame, sMetricsGroup);
    }
    this->AddChild(m_sprFrame);
  }

  for (int i = 0; i < NUM_MENU_TIMER_TEXTS; i++) {
    if (THEME != nullptr && !sMetricsGroup.empty()) {
      m_text[i].LoadFromFont(THEME->GetPathF(sMetricsGroup, "numbers"));
    }
    m_text[i].SetName(ssprintf("Text%d", i + 1));
    if (THEME != nullptr && !sMetricsGroup.empty()) {
      ActorUtil::LoadAllCommandsAndOnCommand(m_text[i], sMetricsGroup);
    }
    this->AddChild(&m_text[i]);
  }

  if (THEME != nullptr && !sMetricsGroup.empty()) {
    m_exprFormatText[0] = THEME->GetMetricR(sMetricsGroup, "Text1FormatFunction");
    m_exprFormatText[1] = THEME->GetMetricR(sMetricsGroup, "Text2FormatFunction");
  } else {
    m_exprFormatText[0].Unset();
    m_exprFormatText[1].Unset();
  }

  SetSeconds(TIMER_PAUSE_SECONDS);

  if (THEME != nullptr && !sMetricsGroup.empty()) {
    m_soundBeep.Load(THEME->GetPathS(sMetricsGroup, "tick"));

    WARNING_START.Load(sMetricsGroup, "WarningStart");
    WARNING_BEEP_START.Load(sMetricsGroup, "WarningBeepStart");
    MAX_STALL_SECONDS.Load(sMetricsGroup, "MaxStallSeconds");
    HURRY_UP_TRANSITION.Load(sMetricsGroup, "HurryUpTransition");

    m_iWarningStart = SanitizeWarningBoundary(WARNING_START.GetValue(), 10);
    m_iWarningBeepStart =
        SanitizeWarningBoundary(WARNING_BEEP_START.GetValue(), 8);
    m_fMaxStallSeconds =
        SanitizeTimerMetric(MAX_STALL_SECONDS.GetValue(), 0.0f);
    m_fHurryUpTransition =
        SanitizeTimerMetric(HURRY_UP_TRANSITION.GetValue(), 5.5f);
  } else {
    m_iWarningStart = 10;
    m_iWarningBeepStart = 8;
    m_fMaxStallSeconds = 0.0f;
    m_fHurryUpTransition = 5.5f;
  }

  // clear warning commands out if they already exist. -aj
  if (WARNING_COMMAND) {
    delete WARNING_COMMAND;
    WARNING_COMMAND = nullptr;
  }

  if (THEME != nullptr && !sMetricsGroup.empty()) {
    WARNING_COMMAND = new ThemeMetric1D<apActorCommands>(
        sMetricsGroup, WARNING_COMMAND_NAME, m_iWarningStart + 1);
  }

  m_fStallSeconds = 0.0f;
  m_fStallSecondsLeft = m_fMaxStallSeconds;
}

void MenuTimer::EnableStealth(bool bStealth) {
  EnableSilent(bStealth);

  for (int i = 0; i < NUM_MENU_TIMER_TEXTS; i++) {
    m_text[i].SetVisible(!bStealth);
  }
  if (m_sprFrame.IsLoaded()) {
    m_sprFrame->SetVisible(!bStealth);
  }
}

void MenuTimer::Update(float fDeltaTime) {
  if (!std::isfinite(fDeltaTime) || fDeltaTime < 0.0f) {
    fDeltaTime = 0.0f;
  }
  ActorFrame::Update(fDeltaTime);

  if (m_bPaused) {
    return;
  }

  // run down the stall time if any
  if (m_fStallSeconds > 0) {
    m_fStallSeconds = std::max(m_fStallSeconds - fDeltaTime, 0.0f);
  }
  if (m_fStallSeconds > 0) {
    return;
  }

  const float fOldSecondsLeft = m_fSecondsLeft;
  m_fSecondsLeft -= fDeltaTime;
  m_fSecondsLeft = std::max(0.0f, m_fSecondsLeft);
  const float fNewSecondsLeft = m_fSecondsLeft;

  SetText(fNewSecondsLeft);

  if (fOldSecondsLeft == fNewSecondsLeft) {
    return;
  }

  if (fOldSecondsLeft > m_fHurryUpTransition &&
      fNewSecondsLeft < m_fHurryUpTransition && SOUND != nullptr) {
    SOUND->PlayOnceFromAnnouncer("hurry up");
  }

  int iCrossed = std::floor(fOldSecondsLeft);
  if (fOldSecondsLeft > iCrossed && fNewSecondsLeft < iCrossed)  // crossed
  {
    if (iCrossed >= 0 && iCrossed <= m_iWarningStart &&
        WARNING_COMMAND != nullptr) {
      for (int i = 0; i < NUM_MENU_TIMER_TEXTS; i++) {
        m_text[i].RunCommands(WARNING_COMMAND->GetValue(iCrossed));
      }
    }

    if (iCrossed >= 0 && iCrossed <= m_iWarningBeepStart &&
        m_soundBeep.IsLoaded() &&
        !m_bSilent) {
      m_soundBeep.Play(false);
    }
  }

  if (fNewSecondsLeft == 0) {
    Stop();
    if (SCREENMAN != nullptr) {
      SCREENMAN->PostMessageToTopScreen(SM_MenuTimer, 0);
    }
    for (int i = 0; i < NUM_MENU_TIMER_TEXTS; i++) {
      m_text[i].StopEffect();
    }
  }
}

void MenuTimer::Pause() { m_bPaused = true; }

void MenuTimer::Stop() {
  /* Don't call SetSeconds if we're already at 0: let the existing tweens
   * finish. */
  if (m_fSecondsLeft >= 1) {
    SetSeconds(0);
  }
  Pause();
}

void MenuTimer::Disable() {
  SetSeconds(TIMER_PAUSE_SECONDS);
  Pause();
}

void MenuTimer::Stall() {
  // Max amount of stall time we'll use:
  m_fStallSeconds = SanitizeTimerSeconds(m_fStallSeconds);
  m_fStallSecondsLeft = SanitizeTimerSeconds(m_fStallSecondsLeft);
  const float Amt = std::min(0.5f, m_fStallSecondsLeft);

  // Amount of stall time to add:
  const float ToAdd = Amt - m_fStallSeconds;

  m_fStallSeconds += ToAdd;
  m_fStallSecondsLeft -= ToAdd;
}

void MenuTimer::SetSeconds(float fSeconds) {
  m_fSecondsLeft = SanitizeTimerSeconds(fSeconds, TIMER_PAUSE_SECONDS);

  for (int i = 0; i < NUM_MENU_TIMER_TEXTS; i++) {
    m_text[i].PlayCommand("On");
  }

  SetText(m_fSecondsLeft);
}

void MenuTimer::Start() { m_bPaused = false; }

void MenuTimer::SetText(float fSeconds) {
  fSeconds = SanitizeTimerSeconds(fSeconds);
  if (LUA == nullptr) {
    for (int i = 0; i < NUM_MENU_TIMER_TEXTS; i++) {
      m_text[i].SetText(FormatTimerFallback(fSeconds, i));
    }
    return;
  }

  Lua* L = LUA->Get();

  for (int i = 0; i < NUM_MENU_TIMER_TEXTS; i++) {
    std::string sText = FormatTimerFallback(fSeconds, i);
    if (!m_exprFormatText[i].IsSet() || m_exprFormatText[i].IsNil()) {
      m_text[i].SetText(sText);
      continue;
    }

    // function
    m_exprFormatText[i].PushSelf(L);
    if (lua_isnil(L, -1) || !lua_isfunction(L, -1)) {
      lua_pop(L, 1);
      m_text[i].SetText(sText);
      continue;
    }

    // 1st parameter
    LuaHelpers::Push(L, fSeconds);

    // call function with 1 argument and 1 result
    std::string errorMessage =
        ssprintf("Error running Text%dFormatFunction: ", i + 1);
    const bool success =
        LuaHelpers::RunScriptOnStack(L, errorMessage, 1, 1, true);

    if (success && lua_isstring(L, -1)) {
      LuaHelpers::Pop(L, sText);
    } else {
      lua_pop(L, 1);
    }

    m_text[i].SetText(sText);
  }

  LUA->Release(L);
}

// lua start
#include "LuaBinding.h"

/** @brief Allow Lua to have access to the MenuTimer. */
class LunaMenuTimer : public Luna<MenuTimer> {
 public:
  static int SetSeconds(T* p, lua_State* L) {
    p->SetSeconds(FArg(1));
    COMMON_RETURN_SELF;
  }
  static int GetSeconds(T* p, lua_State* L) {
    lua_pushnumber(L, p->GetSeconds());
    return 1;
  }
  static int start(T* p, lua_State* L) {
    p->Start();
    COMMON_RETURN_SELF;
  }
  static int pause(T* p, lua_State* L) {
    p->Pause();
    COMMON_RETURN_SELF;
  }
  static int stop(T* p, lua_State* L) {
    p->Stop();
    COMMON_RETURN_SELF;
  }
  static int disable(T* p, lua_State* L) {
    p->Disable();
    COMMON_RETURN_SELF;
  }
  static int silent(T* p, lua_State* L) {
    p->EnableSilent(BArg(1));
    COMMON_RETURN_SELF;
  }
  static int stealth(T* p, lua_State* L) {
    p->EnableStealth(BArg(1));
    COMMON_RETURN_SELF;
  }

  LunaMenuTimer() {
    ADD_METHOD(SetSeconds);
    ADD_METHOD(GetSeconds);
    ADD_METHOD(start);
    ADD_METHOD(pause);
    ADD_METHOD(stop);
    ADD_METHOD(disable);
    ADD_METHOD(silent);
    ADD_METHOD(stealth);
  }
};

LUA_REGISTER_DERIVED_CLASS(MenuTimer, ActorFrame)
// lua end

/*
 * (c) 2002-2004 Chris Danford
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
