#include "StepsDisplay.h"

#include <algorithm>
#include <cctype>
#include <string>

#include "ActorFrame.h"
#include "ActorUtil.h"
#include "Difficulty.h"
#include "EnumHelper.h"
#include "GameConstantsAndTypes.h"
#include "GameState.h"
#include "LuaBinding.h"
#include "LuaManager.h"
#include "MessageManager.h"
#include "PlayerNumber.h"
#include "PlayerState.h"
#include "RageLog.h"
#include "RageUtil.h"
#include "SongManager.h"
#include "Steps.h"
#include "ThemeManager.h"
#include "global.h"

REGISTER_ACTOR_CLASS(StepsDisplay);

namespace {
constexpr int kMaxDisplayTicks = 64;
constexpr int kMaxDisplayedMeter = 999;

void WarnStepsDisplaySafety(const char* message) {
  if (LOG != nullptr) {
    LOG->Warn("%s", message);
  }
}

bool IsValidStepsDisplayPlayer(PlayerNumber pn) {
  return pn >= PLAYER_1 && pn < NUM_PLAYERS;
}

bool IsValidStepsTypeForDisplay(StepsType st) {
  return st == StepsType_Invalid || (st >= 0 && st < NUM_StepsType);
}

bool IsValidDifficultyForDisplay(Difficulty dc) {
  return dc == Difficulty_Invalid || (dc >= 0 && dc < NUM_Difficulty);
}

bool IsValidCourseTypeForDisplay(CourseType ct) {
  return ct == CourseType_Invalid || (ct >= 0 && ct < NUM_CourseType);
}

int SanitizeMeterForDisplay(int meter) {
  if (meter < 0) {
    WarnStepsDisplaySafety(
        "StepsDisplay reset negative meter.");
    return 0;
  }
  if (meter > kMaxDisplayedMeter) {
    WarnStepsDisplaySafety(
        "StepsDisplay clamped oversized meter.");
    return kMaxDisplayedMeter;
  }
  return meter;
}

int SanitizeTickCount(int value, const char* context) {
  if (value < 0) {
    WarnStepsDisplaySafety(context);
    return 0;
  }
  if (value > kMaxDisplayTicks) {
    WarnStepsDisplaySafety(context);
    return kMaxDisplayTicks;
  }
  return value;
}

bool IsSafeMeterFormat(const std::string& format) {
  if (format.empty() || format.size() > 64) {
    return false;
  }
  int conversions = 0;
  for (size_t i = 0; i < format.size(); ++i) {
    if (format[i] != '%') {
      continue;
    }
    if (i + 1 < format.size() && format[i + 1] == '%') {
      ++i;
      continue;
    }
    ++conversions;
    if (conversions > 1) {
      return false;
    }
    size_t j = i + 1;
    while (j < format.size() &&
           std::string("-+ #0").find(format[j]) != std::string::npos) {
      ++j;
    }
    int width = 0;
    while (j < format.size() &&
           std::isdigit(static_cast<unsigned char>(format[j]))) {
      width = width * 10 + (format[j] - '0');
      if (width > 12) {
        return false;
      }
      ++j;
    }
    if (j < format.size() && format[j] == '.') {
      ++j;
      int precision = 0;
      while (j < format.size() &&
             std::isdigit(static_cast<unsigned char>(format[j]))) {
        precision = precision * 10 + (format[j] - '0');
        if (precision > 6) {
          return false;
        }
        ++j;
      }
    }
    if (j >= format.size()) {
      return false;
    }
    if (std::string("diu").find(format[j]) == std::string::npos) {
      return false;
    }
  }
  return conversions == 1;
}

std::string FormatMeterText(const std::string& format, int meter) {
  if (!IsSafeMeterFormat(format)) {
    WarnStepsDisplaySafety(
        "StepsDisplay ignored unsafe MeterFormatString.");
    return ssprintf("%d", meter);
  }
  return ssprintf(format.c_str(), meter);
}
}  // namespace

StepsDisplay::StepsDisplay() {}

StepsDisplay::StepsDisplay(const StepsDisplay& cpy)
    : ActorFrame(cpy),
      m_sMetricsGroup(cpy.m_sMetricsGroup),
      m_sprFrame(cpy.m_sprFrame),
      m_textTicks(cpy.m_textTicks),
      m_textMeter(cpy.m_textMeter),
      m_textDescription(cpy.m_textDescription),
      m_textAuthor(cpy.m_textAuthor),
      m_sprAutogen(cpy.m_sprAutogen),
      m_sprStepsType(cpy.m_sprStepsType),
      m_iNumTicks(cpy.m_iNumTicks),
      m_iMaxTicks(cpy.m_iMaxTicks),
      m_bShowTicks(cpy.m_bShowTicks),
      m_bShowMeter(cpy.m_bShowMeter),
      m_bShowDescription(cpy.m_bShowDescription),
      m_bShowCredit(cpy.m_bShowCredit),
      m_bShowAutogen(cpy.m_bShowAutogen),
      m_bShowStepsType(cpy.m_bShowStepsType),
      m_sZeroMeterString(cpy.m_sZeroMeterString),
      m_sMeterFormatString(cpy.m_sMeterFormatString) {
  DeleteAllChildren();
  DeleteChildrenWhenDone(false);
  if (m_sprFrame.IsLoaded()) {
    AddChild(m_sprFrame);
  }
  if (m_bShowTicks) {
    AddChild(&m_textTicks);
  }
  if (m_bShowMeter) {
    AddChild(&m_textMeter);
  }
  if (m_bShowDescription) {
    AddChild(&m_textDescription);
  }
  if (m_bShowCredit) {
    AddChild(&m_textAuthor);
  }
  if (m_sprAutogen.IsLoaded()) {
    AddChild(m_sprAutogen);
  }
  if (m_sprStepsType.IsLoaded()) {
    AddChild(m_sprStepsType);
  }
}

void StepsDisplay::ResetLoadedActors() {
  RemoveChild(&m_textTicks);
  RemoveChild(&m_textMeter);
  RemoveChild(&m_textDescription);
  RemoveChild(&m_textAuthor);
  if (m_sprFrame.IsLoaded()) {
    RemoveChild(m_sprFrame);
    m_sprFrame.Unload();
  }
  if (m_sprAutogen.IsLoaded()) {
    RemoveChild(m_sprAutogen);
    m_sprAutogen.Unload();
  }
  if (m_sprStepsType.IsLoaded()) {
    RemoveChild(m_sprStepsType);
    m_sprStepsType.Unload();
  }
}

/* sID experiment:
 *
 * Names of an actor, "Foo":
 * [Foo]
 * Metric=abc
 *
 * [ScreenSomething]
 * FooP1X=20
 * FooP2Y=30
 *
 * Graphics\Foo under p1
 *
 * We want to call it different things in different contexts: we may only want
 * one set of internal metrics for a given use, but separate metrics for each
 * player at the screen level, and we may or may not want separate names at the
 * asset level.
 *
 * As is, we tend to end up having to either duplicate [Foo] to [FooP1] and
 * [FooP2] or not use m_sName for [Foo], which limits its use.  Let's try using
 * a separate name for internal metrics.  I'm not sure if this will cause more
 * confusion than good, so I'm trying it first in only this object.
 */

void StepsDisplay::Load(
    const std::string& sMetricsGroup, const PlayerState* pPlayerState) {
  ResetLoadedActors();
  m_sMetricsGroup = sMetricsGroup.empty() ? "StepsDisplay" : sMetricsGroup;
  if (sMetricsGroup.empty()) {
    WarnStepsDisplaySafety(
        "StepsDisplay fell back from empty metrics "
        "group.");
  }
  if (THEME == nullptr) {
    WarnStepsDisplaySafety(
        "StepsDisplay refused load without THEME.");
    return;
  }

  /* We can't use global ThemeMetric<std::string>s, because we can have multiple
   * StepsDisplays on screen at once, with different names. */
  m_iNumTicks.Load(m_sMetricsGroup, "NumTicks");
  m_iMaxTicks.Load(m_sMetricsGroup, "MaxTicks");
  m_bShowTicks.Load(m_sMetricsGroup, "ShowTicks");
  m_bShowMeter.Load(m_sMetricsGroup, "ShowMeter");
  m_bShowDescription.Load(m_sMetricsGroup, "ShowDescription");
  m_bShowCredit.Load(m_sMetricsGroup, "ShowCredit");
  m_bShowAutogen.Load(m_sMetricsGroup, "ShowAutogen");
  m_bShowStepsType.Load(m_sMetricsGroup, "ShowStepsType");
  m_sZeroMeterString.Load(m_sMetricsGroup, "ZeroMeterString");
  m_sMeterFormatString.Load(m_sMetricsGroup, "MeterFormatString");

  m_sprFrame.Load(THEME->GetPathG(m_sMetricsGroup, "frame"));
  if (m_sprFrame.IsLoaded()) {
    m_sprFrame->SetName("Frame");
    ActorUtil::LoadAllCommandsAndSetXYAndOnCommand(m_sprFrame, m_sMetricsGroup);
    this->AddChild(m_sprFrame);
  }

  if (m_bShowTicks) {
    std::string sChars = "10";  // on, off (todo: make this metricable -aj)
    m_textTicks.SetName("Ticks");
    m_textTicks.LoadFromTextureAndChars(
        THEME->GetPathF(m_sMetricsGroup, "ticks"), sChars);
    ActorUtil::LoadAllCommandsAndSetXYAndOnCommand(
        m_textTicks, m_sMetricsGroup);
    this->AddChild(&m_textTicks);
  }

  if (m_bShowMeter) {
    m_textMeter.SetName("Meter");
    m_textMeter.LoadFromFont(THEME->GetPathF(m_sMetricsGroup, "meter"));
    ActorUtil::LoadAllCommandsAndSetXYAndOnCommand(
        m_textMeter, m_sMetricsGroup);
    this->AddChild(&m_textMeter);

    if (!m_textMeter.HasCommand("Set")) {
      WarnStepsDisplaySafety(
          "StepsDisplay meter actor has no Set command.");
    }
  }

  if (m_bShowDescription) {
    m_textDescription.SetName("Description");
    m_textDescription.LoadFromFont(
        THEME->GetPathF(m_sMetricsGroup, "Description"));
    ActorUtil::LoadAllCommandsAndSetXYAndOnCommand(
        m_textDescription, m_sMetricsGroup);
    this->AddChild(&m_textDescription);
  }
  if (m_bShowCredit) {
    m_textAuthor.SetName("Step Author");
    m_textAuthor.LoadFromFont(THEME->GetPathF(m_sMetricsGroup, "Credit"));
    ActorUtil::LoadAllCommandsAndSetXYAndOnCommand(
        m_textAuthor, m_sMetricsGroup);
    this->AddChild(&m_textAuthor);
  }

  if (m_bShowAutogen) {
    m_sprAutogen.Load(THEME->GetPathG(m_sMetricsGroup, "Autogen"));
    m_sprAutogen->SetName("Autogen");
    ActorUtil::LoadAllCommandsAndSetXYAndOnCommand(
        m_sprAutogen, m_sMetricsGroup);
    this->AddChild(m_sprAutogen);
  }

  if (m_bShowStepsType) {
    m_sprStepsType.Load(THEME->GetPathG(m_sMetricsGroup, "StepsType"));
    m_sprStepsType->SetName("StepsType");
    ActorUtil::LoadAllCommandsAndSetXYAndOnCommand(
        m_sprStepsType, m_sMetricsGroup);
    this->AddChild(m_sprStepsType);
  }

  // Play Load Command
  PlayerState* pPlayerState_ = const_cast<PlayerState*>(pPlayerState);
  Message msg("Load");
  if (pPlayerState_ != nullptr && LUA != nullptr) {
    msg.SetParam("PlayerState", LuaReference::CreateFromPush(*pPlayerState_));
  }
  this->HandleMessage(msg);

  Unset();
}

void StepsDisplay::SetFromGameState(PlayerNumber pn) {
  if (GAMESTATE == nullptr || !IsValidStepsDisplayPlayer(pn)) {
    WarnStepsDisplaySafety(
        "StepsDisplay ignored invalid game/player "
        "state.");
    SetFromStepsTypeAndMeterAndDifficultyAndCourseType(
        StepsType_Invalid, 0, Difficulty_Invalid, CourseType_Invalid);
    return;
  }
  if (GAMESTATE->IsCourseMode()) {
    // figure out what course type is selected somehow.
    const Trail* pTrail = GAMESTATE->m_pCurTrail[pn];
    if (pTrail) {
      SetFromTrail(pTrail);
    } else {
      SetFromStepsTypeAndMeterAndDifficultyAndCourseType(
          StepsType_Invalid, 0, GAMESTATE->m_PreferredCourseDifficulty[pn],
          CourseType_Invalid);
    }
  } else {
    const Steps* pSteps = GAMESTATE->m_pCurSteps[pn];
    if (pSteps) {
      SetFromSteps(pSteps);
    } else {
      SetFromStepsTypeAndMeterAndDifficultyAndCourseType(
          StepsType_Invalid, 0, GAMESTATE->m_PreferredDifficulty[pn],
          CourseType_Invalid);
    }
  }
}

void StepsDisplay::SetFromSteps(const Steps* pSteps) {
  if (pSteps == nullptr) {
    Unset();
    return;
  }

  SetParams params = {
      pSteps,
      nullptr,
      pSteps->GetMeter(),
      pSteps->m_StepsType,
      pSteps->GetDifficulty(),
      CourseType_Invalid};
  SetInternal(params);
}

void StepsDisplay::SetFromTrail(const Trail* pTrail) {
  if (pTrail == nullptr) {
    Unset();
    return;
  }

  SetParams params = {
      nullptr,
      pTrail,
      pTrail->GetMeter(),
      pTrail->m_StepsType,
      pTrail->m_CourseDifficulty,
      pTrail->m_CourseType};
  SetInternal(params);
}

void StepsDisplay::Unset() { this->SetVisible(false); }

void StepsDisplay::SetFromStepsTypeAndMeterAndDifficultyAndCourseType(
    StepsType st, int iMeter, Difficulty dc, CourseType ct) {
  if (!IsValidStepsTypeForDisplay(st)) {
    WarnStepsDisplaySafety(
        "StepsDisplay reset invalid StepsType.");
    st = StepsType_Invalid;
  }
  if (!IsValidDifficultyForDisplay(dc)) {
    WarnStepsDisplaySafety(
        "StepsDisplay reset invalid Difficulty.");
    dc = Difficulty_Invalid;
  }
  if (!IsValidCourseTypeForDisplay(ct)) {
    WarnStepsDisplaySafety(
        "StepsDisplay reset invalid CourseType.");
    ct = CourseType_Invalid;
  }
  iMeter = SanitizeMeterForDisplay(iMeter);
  SetParams params = {nullptr, nullptr, iMeter, st, dc, ct};
  SetInternal(params);
}

void StepsDisplay::SetInternal(const SetParams& params) {
  this->SetVisible(true);
  Message msg("Set");
  SetParams safeParams = params;
  safeParams.iMeter = SanitizeMeterForDisplay(safeParams.iMeter);
  if (!IsValidStepsTypeForDisplay(safeParams.st)) {
    safeParams.st = StepsType_Invalid;
  }
  if (!IsValidDifficultyForDisplay(safeParams.dc)) {
    safeParams.dc = Difficulty_Invalid;
  }
  if (!IsValidCourseTypeForDisplay(safeParams.ct)) {
    safeParams.ct = CourseType_Invalid;
  }

  std::string sCustomDifficulty;
  if (safeParams.pSteps) {
    sCustomDifficulty = StepsToCustomDifficulty(safeParams.pSteps);
  } else if (safeParams.pTrail) {
    sCustomDifficulty = TrailToCustomDifficulty(safeParams.pTrail);
  } else {
    sCustomDifficulty =
        GetCustomDifficulty(safeParams.st, safeParams.dc, safeParams.ct);
  }
  msg.SetParam("CustomDifficulty", sCustomDifficulty);

  std::string sDisplayDescription;
  if (safeParams.pSteps && safeParams.pSteps->IsAnEdit()) {
    sDisplayDescription = safeParams.pSteps->GetDescription();
  } else if (sCustomDifficulty.empty()) {
    sDisplayDescription = std::string();
  } else {
    sDisplayDescription = CustomDifficultyToLocalizedString(sCustomDifficulty);
  }
  msg.SetParam("DisplayDescription", sDisplayDescription);

  std::string sDisplayCredit;
  if (safeParams.pSteps) {
    sDisplayCredit = safeParams.pSteps->GetCredit();
  }

  if (safeParams.pSteps && LUA != nullptr) {
    msg.SetParam(
        "Steps", LuaReference::CreateFromPush(*(Steps*)safeParams.pSteps));
  }
  if (safeParams.pTrail && LUA != nullptr) {
    msg.SetParam(
        "Trail", LuaReference::CreateFromPush(*(Trail*)safeParams.pTrail));
  }
  msg.SetParam("Meter", safeParams.iMeter);
  msg.SetParam("StepsType", safeParams.st);

  if (m_sprFrame.IsLoaded()) {
    m_sprFrame->HandleMessage(msg);
  }

  if (m_bShowTicks) {
    // todo: let themers handle the logic of tick text. -aj
    char on = char('1');
    char off = '0';

    std::string sNewText;
    const int maxTicks = SanitizeTickCount(
        m_iMaxTicks,
        "StepsDisplay clamped invalid MaxTicks.");
    const int numTicks = SanitizeTickCount(
        m_iNumTicks,
        "StepsDisplay clamped invalid NumTicks.");
    int iNumOn = std::min(maxTicks, safeParams.iMeter);
    sNewText.insert(sNewText.end(), iNumOn, on);
    int iNumOff = std::max(0, numTicks - iNumOn);
    sNewText.insert(sNewText.end(), iNumOff, off);
    m_textTicks.SetText(sNewText);
    m_textTicks.HandleMessage(msg);
  }

  if (m_bShowMeter) {
    if (safeParams.iMeter == 0)  // Unset calls with this
    {
      m_textMeter.SetText(m_sZeroMeterString);
    } else {
      const std::string sMeter =
          FormatMeterText(m_sMeterFormatString.GetValue(), safeParams.iMeter);
      m_textMeter.SetText(sMeter);
      m_textMeter.HandleMessage(msg);
    }
  }

  if (m_bShowDescription) {
    m_textDescription.SetText(sDisplayDescription);
    m_textDescription.HandleMessage(msg);
  }
  if (m_bShowCredit) {
    m_textAuthor.SetText(sDisplayCredit);
    m_textAuthor.HandleMessage(msg);
  }

  if (m_bShowAutogen) {
    bool b = safeParams.pSteps && safeParams.pSteps->IsAutogen();
    if (m_sprAutogen.IsLoaded()) {
      m_sprAutogen->HandleMessage(msg);
      m_sprAutogen->SetVisible(b);
    }
  }

  if (m_bShowStepsType) {
    if (safeParams.st != StepsType_Invalid && m_sprStepsType.IsLoaded()) {
      /*
      std::string sStepsType = GAMEMAN->GetStepsTypeInfo(params.st).szName;
      m_sprStepsType.Load( THEME->GetPathG(m_sMetricsGroup,"StepsType
      "+sStepsType) );
      */
      m_sprStepsType->HandleMessage(msg);
    }
  }

  this->HandleMessage(msg);
}

// lua start
#include "LuaBinding.h"

/** @brief Allow Lua to have access to the StepsDisplay. */
class LunaStepsDisplay : public Luna<StepsDisplay> {
 public:
  static int Load(T* p, lua_State* L) {
    std::string metricsGroup = SArg(1);
    if (metricsGroup.empty()) {
      WarnStepsDisplaySafety(
          "StepsDisplay Lua Load used fallback metrics "
          "group.");
    }
    p->Load(metricsGroup, nullptr);
    COMMON_RETURN_SELF;
  }
  static int SetFromSteps(T* p, lua_State* L) {
    if (lua_isnil(L, 1)) {
      p->SetFromSteps(nullptr);
    } else {
      Steps* pS = Luna<Steps>::check(L, 1);
      p->SetFromSteps(pS);
    }
    COMMON_RETURN_SELF;
  }
  static int SetFromTrail(T* p, lua_State* L) {
    if (lua_isnil(L, 1)) {
      p->SetFromTrail(nullptr);
    } else {
      Trail* pT = Luna<Trail>::check(L, 1);
      p->SetFromTrail(pT);
    }
    COMMON_RETURN_SELF;
  }
  static int SetFromGameState(T* p, lua_State* L) {
    PlayerNumber pn = Enum::Check<PlayerNumber>(L, 1);
    p->SetFromGameState(pn);
    COMMON_RETURN_SELF;
  }

  LunaStepsDisplay() {
    ADD_METHOD(Load);
    ADD_METHOD(SetFromSteps);
    ADD_METHOD(SetFromTrail);
    ADD_METHOD(SetFromGameState);
  }
};

LUA_REGISTER_DERIVED_CLASS(StepsDisplay, ActorFrame)
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
