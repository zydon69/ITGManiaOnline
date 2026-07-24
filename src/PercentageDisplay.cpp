#include "PercentageDisplay.h"

#include <algorithm>
#include <cctype>
#include <cmath>
#include <string>

#include "ActorFrame.h"
#include "ActorUtil.h"
#include "Course.h"
#include "GameState.h"
#include "LuaManager.h"
#include "PlayerNumber.h"
#include "PlayerStageStats.h"
#include "PlayerState.h"
#include "RageLog.h"
#include "RageUtil.h"
#include "StdString.h"
#include "ThemeManager.h"
#include "XmlFile.h"
#include "global.h"

REGISTER_ACTOR_CLASS(PercentageDisplay);

namespace {
void WarnPercentageDisplaySafety(const char* message) {
  if (LOG != nullptr) {
    LOG->Warn("%s", message);
  }
}

void TracePercentageDisplaySafety(const char* message) {
  if (LOG != nullptr) {
    LOG->Trace("%s", message);
  }
}

int ClampDancePointDigits(int digits, const char* context) {
  if (digits < 0 || digits > 12) {
    if (LOG != nullptr) {
      LOG->Warn(
          "%s clamped DancePointsDigits %i.", context,
          digits);
    }
    return std::max(0, std::min(12, digits));
  }
  return digits;
}

bool IsSafeIntegerFormat(const std::string& format) {
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
    if (std::string("di").find(format[j]) == std::string::npos) {
      return false;
    }
  }
  return conversions == 1;
}

std::string FormatIntSafely(
    const std::string& format, int value, const char* context) {
  if (!IsSafeIntegerFormat(format)) {
    if (LOG != nullptr) {
      LOG->Warn(
          "%s: ignored unsafe integer format '%s'.", context,
          format.c_str());
    }
    return ssprintf("%d", value);
  }
  return ssprintf(format.c_str(), value);
}

void ReleasePercentageDisplayLua(Lua* L) {
  if (LUA != nullptr && L != nullptr) {
    LUA->Release(L);
  }
}
}  // namespace

PercentageDisplay::PercentageDisplay() {
  m_pPlayerState = nullptr;
  m_pPlayerStageStats = nullptr;

  m_Last = -1;
  m_LastMax = -1;
  m_iDancePointsDigits = 0;
  m_bUseRemainder = false;
  m_bAutoRefresh = false;
  m_FormatPercentScore.SetFromExpression("FormatPercentScore");
}

PercentageDisplay::PercentageDisplay(const PercentageDisplay& cpy)
    : ActorFrame(cpy),
      m_iDancePointsDigits(cpy.m_iDancePointsDigits),
      m_bUseRemainder(cpy.m_bUseRemainder),
      m_pPlayerState(cpy.m_pPlayerState),
      m_pPlayerStageStats(cpy.m_pPlayerStageStats),
      m_bAutoRefresh(cpy.m_bAutoRefresh),
      m_Last(cpy.m_Last),
      m_LastMax(cpy.m_LastMax),
      m_textPercent(cpy.m_textPercent),
      m_textPercentRemainder(cpy.m_textPercentRemainder),
      m_sPercentFormat(cpy.m_sPercentFormat),
      m_sRemainderFormat(cpy.m_sRemainderFormat),
      m_FormatPercentScore(cpy.m_FormatPercentScore) {
  const std::vector<Actor*> children = cpy.GetChildren();
  if (std::find(children.begin(), children.end(), &cpy.m_textPercent) !=
      children.end()) {
    AddChild(&m_textPercent);
  }
  if (std::find(
          children.begin(), children.end(), &cpy.m_textPercentRemainder) !=
      children.end()) {
    AddChild(&m_textPercentRemainder);
  }
}

void PercentageDisplay::ResetLoadedActors() {
  RemoveChild(&m_textPercent);
  RemoveChild(&m_textPercentRemainder);
  m_Last = -1;
  m_LastMax = -1;
  m_bUseRemainder = false;
  m_sPercentFormat.clear();
  m_sRemainderFormat.clear();
  m_FormatPercentScore.SetFromExpression("FormatPercentScore");
}

void PercentageDisplay::LoadFromNode(const XNode* pNode) {
  ResetLoadedActors();

  if (pNode == nullptr) {
    WarnPercentageDisplaySafety(
        "PercentageDisplay ignored null XML node.");
    return;
  }
  pNode->GetAttrValue("DancePointsDigits", m_iDancePointsDigits);
  m_iDancePointsDigits =
      ClampDancePointDigits(m_iDancePointsDigits, "PercentageDisplay XML");
  pNode->GetAttrValue("AutoRefresh", m_bAutoRefresh);
  if (LUA != nullptr) {
    Lua* L = LUA->Get();
    if (L != nullptr && pNode->PushAttrValue(L, "FormatPercentScore")) {
      m_FormatPercentScore.SetFromStack(L);
      if (m_FormatPercentScore.GetLuaType() != LUA_TFUNCTION) {
        // Not reported as an error because _fallback and default provided bad
        // examples in their [LifeMeterBattery Percent]:Format metric and nobody
        // realized it was supposed to be set to a function. -Kyz
        TracePercentageDisplaySafety(
            "Format attribute for PercentageDisplay named '%s' is not a "
            "function. Defaulting to 'FormatPercentScore'.");
        m_FormatPercentScore.SetFromExpression("FormatPercentScore");
      }
    } else if (L != nullptr) {
      lua_pop(L, 1);
    }
    ReleasePercentageDisplayLua(L);
  }

  const XNode* pChild = pNode->GetChild("Percent");
  if (pChild == nullptr) {
    LuaHelpers::ReportScriptError(
        ActorUtil::GetWhere(pNode) +
        ": PercentageDisplay: missing the node \"Percent\"");
    // Make a BitmapText just so we don't crash.
    if (THEME != nullptr) {
      m_textPercent.LoadFromFont(THEME->GetPathF("", "Common Normal"));
    } else {
      WarnPercentageDisplaySafety(
          "PercentageDisplay could not load fallback "
          "font without THEME.");
    }
  } else {
    m_textPercent.LoadFromNode(pChild);
  }
  this->AddChild(&m_textPercent);

  pChild = pNode->GetChild("PercentRemainder");
  if (!ShowDancePointsNotPercentage() && pChild != nullptr) {
    m_bUseRemainder = true;
    if (m_sPercentFormat.empty()) {
      m_sPercentFormat = "%d";
    }
    if (m_sRemainderFormat.empty()) {
      m_sRemainderFormat = "%d";
    }
    m_textPercentRemainder.LoadFromNode(pChild);
    this->AddChild(&m_textPercentRemainder);
  }

  // only run the Init command after we load Fonts.
  ActorFrame::LoadFromNode(pNode);
}

void PercentageDisplay::Load(
    const PlayerState* pPlayerState,
    const PlayerStageStats* pPlayerStageStats) {
  m_pPlayerState = pPlayerState;
  m_pPlayerStageStats = pPlayerStageStats;
  if (m_pPlayerState == nullptr || m_pPlayerStageStats == nullptr) {
    WarnPercentageDisplaySafety(
        "PercentageDisplay loaded without complete "
        "player stats.");
    return;
  }

  Refresh();
}

void PercentageDisplay::Load(
    const PlayerState* pPlayerState, const PlayerStageStats* pPlayerStageStats,
    const std::string& sMetricsGroup, bool bAutoRefresh) {
  ResetLoadedActors();
  m_pPlayerState = pPlayerState;
  m_pPlayerStageStats = pPlayerStageStats;
  m_bAutoRefresh = bAutoRefresh;

  if (THEME == nullptr) {
    WarnPercentageDisplaySafety(
        "PercentageDisplay refused metric load "
        "without THEME.");
    return;
  }

  m_iDancePointsDigits = THEME->GetMetricI(sMetricsGroup, "DancePointsDigits");
  m_iDancePointsDigits =
      ClampDancePointDigits(m_iDancePointsDigits, sMetricsGroup.c_str());
  m_bUseRemainder = THEME->GetMetricB(sMetricsGroup, "PercentUseRemainder");
  m_FormatPercentScore = THEME->GetMetricR(sMetricsGroup, "Format");

  m_sPercentFormat = THEME->GetMetric(sMetricsGroup, "PercentFormat");
  m_sRemainderFormat = THEME->GetMetric(sMetricsGroup, "RemainderFormat");
  if (m_sPercentFormat.empty()) {
    m_sPercentFormat = "%d";
  }
  if (m_sRemainderFormat.empty()) {
    m_sRemainderFormat = "%d";
  }

  if (m_FormatPercentScore.GetLuaType() != LUA_TFUNCTION) {
    // Not reported as an error because _fallback and default provided bad
    // examples in their [LifeMeterBattery Percent]:Format metric and nobody
    // realized it was supposed to be set to a function. -Kyz
    TracePercentageDisplaySafety(
        "Format metric is not a function in [%s]. Defaulting to "
        "'FormatPercentScore'.");
    m_FormatPercentScore.SetFromExpression("FormatPercentScore");
  }

  const bool validPlayer = m_pPlayerState != nullptr &&
                           m_pPlayerState->m_PlayerNumber >= PLAYER_1 &&
                           m_pPlayerState->m_PlayerNumber < NUM_PLAYERS;
  if (m_pPlayerState != nullptr && !validPlayer) {
    WarnPercentageDisplaySafety(
        "PercentageDisplay rejected invalid player "
        "number.");
  }

  if (ShowDancePointsNotPercentage()) {
    m_textPercent.SetName(
        !validPlayer ? "DancePointsInvalid"
                     : "DancePoints" + PlayerNumberToString(
                                           m_pPlayerState->m_PlayerNumber));
  } else {
    m_textPercent.SetName(
        !validPlayer
            ? "PercentInvalid"
            : "Percent" + PlayerNumberToString(m_pPlayerState->m_PlayerNumber));
  }

  m_textPercent.LoadFromFont(THEME->GetPathF(sMetricsGroup, "text"));
  ActorUtil::SetXY(m_textPercent, sMetricsGroup);
  ActorUtil::LoadAllCommands(m_textPercent, sMetricsGroup);
  this->AddChild(&m_textPercent);

  if (!ShowDancePointsNotPercentage() && m_bUseRemainder) {
    m_textPercentRemainder.SetName(
        !validPlayer
            ? "PercentRemainderInvalid"
            : "PercentRemainder" +
                  PlayerNumberToString(m_pPlayerState->m_PlayerNumber));
    m_textPercentRemainder.LoadFromFont(
        THEME->GetPathF(sMetricsGroup, "remainder"));
    ActorUtil::SetXY(m_textPercentRemainder, sMetricsGroup);
    ActorUtil::LoadAllCommands(m_textPercentRemainder, sMetricsGroup);
    if (!m_textPercentRemainder.HasCommand("Off") && LOG != nullptr) {
      LOG->Warn(
          "PercentageDisplay remainder in [%s] has no "
          "Off command.",
          sMetricsGroup.c_str());
    }
    m_textPercentRemainder.SetText("456");
    this->AddChild(&m_textPercentRemainder);
  }

  if (!validPlayer || m_pPlayerStageStats == nullptr) {
    WarnPercentageDisplaySafety(
        "PercentageDisplay metric load missing or "
        "invalid player stats.");
    return;
  }
  Refresh();
}

void PercentageDisplay::Update(float fDeltaTime) {
  if (!std::isfinite(fDeltaTime) || fDeltaTime < 0.0f) {
    WarnPercentageDisplaySafety(
        "PercentageDisplay ignored non-finite update "
        "delta.");
    return;
  }
  ActorFrame::Update(fDeltaTime);

  if (m_bAutoRefresh) {
    Refresh();
  }
}

void PercentageDisplay::Refresh() {
  if (m_pPlayerStageStats == nullptr) {
    TracePercentageDisplaySafety(
        "PercentageDisplay skipped refresh without "
        "PlayerStageStats.");
    return;
  }
  const int iActualDancePoints = m_pPlayerStageStats->m_iActualDancePoints;
  const int iCurPossibleDancePoints =
      m_pPlayerStageStats->m_iCurPossibleDancePoints;

  if (iActualDancePoints == m_Last && iCurPossibleDancePoints == m_LastMax) {
    return;
  }

  m_Last = iActualDancePoints;
  m_LastMax = iCurPossibleDancePoints;

  std::string sNumToDisplay;

  if (ShowDancePointsNotPercentage()) {
    sNumToDisplay =
        ssprintf("%*d", m_iDancePointsDigits, std::max(0, iActualDancePoints));
  } else {
    float fPercentDancePoints = m_pPlayerStageStats->GetPercentDancePoints();
    if (!std::isfinite(fPercentDancePoints)) {
      WarnPercentageDisplaySafety(
          "PercentageDisplay corrected non-finite "
          "percent.");
      fPercentDancePoints = 0.0f;
    }

    // clamp percentage - feedback is that negative numbers look weird here.
    rage_clamp(fPercentDancePoints, 0.f, 1.f);

    if (m_bUseRemainder) {
      int iPercentWhole = int(fPercentDancePoints * 100);
      int iPercentRemainder = int(
          (fPercentDancePoints * 100 - int(fPercentDancePoints * 100)) * 10);
      sNumToDisplay = FormatIntSafely(
          m_sPercentFormat, iPercentWhole, "PercentageDisplay");
      m_textPercentRemainder.SetText(FormatIntSafely(
          m_sRemainderFormat, iPercentRemainder, "PercentageDisplay"));
    } else {
      if (m_FormatPercentScore.GetLuaType() == LUA_TFUNCTION) {
        if (LUA != nullptr) {
          Lua* L = LUA->Get();
          if (L != nullptr) {
            m_FormatPercentScore.PushSelf(L);
            LuaHelpers::Push(L, fPercentDancePoints);
            std::string Error = "Error running FormatPercentScore: ";
            LuaHelpers::RunScriptOnStack(
                L, Error, 1, 1, true);  // 1 arg, 1 result
            LuaHelpers::Pop(L, sNumToDisplay);
            ReleasePercentageDisplayLua(L);
          }
        }
      }
      if (sNumToDisplay.empty()) {
        sNumToDisplay =
            PlayerStageStats::FormatPercentScore(fPercentDancePoints);
      }

      // HACK: Use the last frame in the numbers texture as '-'
      Replace(sNumToDisplay, '-', 'x');
    }
  }

  m_textPercent.SetText(sNumToDisplay);
}

bool PercentageDisplay::ShowDancePointsNotPercentage() const {
  // Use straight dance points in workout because the percentage denominator
  // isn't accurate - we don't know when the players are going to stop.

  if (GAMESTATE != nullptr && GAMESTATE->m_pCurCourse != nullptr) {
    if (std::isfinite(GAMESTATE->m_pCurCourse->m_fGoalSeconds) &&
        GAMESTATE->m_pCurCourse->m_fGoalSeconds > 0) {
      return true;
    }
  }

  return false;
}

#include "LuaBinding.h"

/** @brief Allow Lua to have access to the PercentageDisplay. */
class LunaPercentageDisplay : public Luna<PercentageDisplay> {
 public:
  static int LoadFromStats(T* p, lua_State* L) {
    const PlayerState* pStageStats =
        lua_isnil(L, 1) ? nullptr : Luna<PlayerState>::check(L, 1);
    const PlayerStageStats* pPlayerStageStats =
        lua_isnil(L, 2) ? nullptr : Luna<PlayerStageStats>::check(L, 2);
    p->Load(pStageStats, pPlayerStageStats);
    COMMON_RETURN_SELF;
  }

  LunaPercentageDisplay() { ADD_METHOD(LoadFromStats); }
};

LUA_REGISTER_DERIVED_CLASS(PercentageDisplay, ActorFrame)
// lua end

/*
 * (c) 2001-2003 Chris Danford
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
