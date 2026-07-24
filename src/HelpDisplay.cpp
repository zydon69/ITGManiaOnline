#include "HelpDisplay.h"

#include <algorithm>
#include <cmath>
#include <string>
#include <vector>

#include "ActorUtil.h"
#include "BitmapText.h"
#include "LuaManager.h"
#include "RageLog.h"
#include "RageUtil.h"
#include "ThemeManager.h"
#include "global.h"

REGISTER_ACTOR_CLASS(HelpDisplay);

namespace {
void WarnHelpDisplay(const char* message) {
  if (LOG != nullptr) {
    LOG->Warn("%s", message);
  }
}

float SanitizeHelpSwitchSeconds(float seconds, float fallback) {
  if (!std::isfinite(seconds) || seconds <= 0.0f) {
    return fallback;
  }
  return seconds;
}
}  // namespace

HelpDisplay::HelpDisplay() {
  m_iCurTipIndex = 0;
  m_fSecsUntilSwitch = 0;
  m_fSecsBetweenSwitches = 1;
}

void HelpDisplay::Load(const std::string& sType) {
  if (THEME == nullptr || sType.empty()) {
    WarnHelpDisplay("HelpDisplay loaded without THEME.");
    return;
  }

  RunCommands(THEME->GetMetricA(sType, "TipOnCommand"));
  m_fSecsUntilSwitch =
      SanitizeHelpSwitchSeconds(THEME->GetMetricF(sType, "TipShowTime"), 1.0f);
  m_fSecsBetweenSwitches =
      SanitizeHelpSwitchSeconds(THEME->GetMetricF(sType, "TipSwitchTime"), 1.0f);
}

void HelpDisplay::SetTips(
    const std::vector<std::string>& arrayTips,
    const std::vector<std::string>& arrayTipsAlt) {
  std::vector<std::string> normalizedTipsAlt = arrayTipsAlt;
  if (normalizedTipsAlt.size() != arrayTips.size()) {
    WarnHelpDisplay(
        "HelpDisplay normalized mismatched alt tips.");
    normalizedTipsAlt.resize(arrayTips.size());
    for (size_t i = 0; i < arrayTips.size(); ++i) {
      if (normalizedTipsAlt[i].empty()) {
        normalizedTipsAlt[i] = arrayTips[i];
      }
    }
  }

  if (arrayTips == m_arrayTips && normalizedTipsAlt == m_arrayTipsAlt) {
    return;
  }

  SetText("");

  m_arrayTips = arrayTips;
  m_arrayTipsAlt = normalizedTipsAlt;

  m_iCurTipIndex = 0;
  m_fSecsUntilSwitch = 0;
  Update(0);
}

void HelpDisplay::SetSecsBetweenSwitches(float fSeconds) {
  m_fSecsBetweenSwitches = m_fSecsUntilSwitch =
      SanitizeHelpSwitchSeconds(fSeconds, 1.0f);
}

void HelpDisplay::Update(float fDeltaTime) {
  if (!std::isfinite(fDeltaTime) || fDeltaTime < 0.0f) {
    fDeltaTime = 0.0f;
  }
  float fHibernate =
      std::isfinite(m_fHibernateSecondsLeft) ? m_fHibernateSecondsLeft : 0.0f;

  BitmapText::Update(fDeltaTime);

  if (m_arrayTips.empty()) {
    return;
  }
  if (m_iCurTipIndex < 0 ||
      m_iCurTipIndex >= static_cast<int>(m_arrayTips.size())) {
    m_iCurTipIndex = 0;
  }
  if (m_arrayTipsAlt.size() != m_arrayTips.size()) {
    m_arrayTipsAlt = m_arrayTips;
  }

  m_fSecsUntilSwitch -= std::max(fDeltaTime - fHibernate, 0.0f);
  if (m_fSecsUntilSwitch > 0) {
    return;
  }

  // time to switch states
  m_fSecsBetweenSwitches =
      SanitizeHelpSwitchSeconds(m_fSecsBetweenSwitches, 1.0f);
  m_fSecsUntilSwitch = m_fSecsBetweenSwitches;
  SetText(m_arrayTips[m_iCurTipIndex], m_arrayTipsAlt[m_iCurTipIndex]);
  m_iCurTipIndex++;
  m_iCurTipIndex = m_iCurTipIndex % m_arrayTips.size();
}

#include "FontCharAliases.h"
#include "LuaBinding.h"

/** @brief Allow Lua to have access to the HelpDisplay. */
class LunaHelpDisplay : public Luna<HelpDisplay> {
 public:
  static int settips(T* p, lua_State* L) {
    luaL_checktype(L, 1, LUA_TTABLE);
    lua_pushvalue(L, 1);
    std::vector<std::string> arrayTips;
    LuaHelpers::ReadArrayFromTable(arrayTips, L);
    lua_pop(L, 1);
    for (unsigned i = 0; i < arrayTips.size(); ++i) {
      FontCharAliases::ReplaceMarkers(arrayTips[i]);
    }
    if (lua_gettop(L) > 1 && !lua_isnil(L, 2)) {
      std::vector<std::string> arrayTipsAlt;
      luaL_checktype(L, 2, LUA_TTABLE);
      lua_pushvalue(L, 2);
      LuaHelpers::ReadArrayFromTable(arrayTipsAlt, L);
      lua_pop(L, 1);
      for (unsigned i = 0; i < arrayTipsAlt.size(); ++i) {
        FontCharAliases::ReplaceMarkers(arrayTipsAlt[i]);
      }

      p->SetTips(arrayTips, arrayTipsAlt);
    } else {
      p->SetTips(arrayTips);
    }

    COMMON_RETURN_SELF;
  }
  static int SetTipsColonSeparated(T* p, lua_State* L) {
    std::vector<std::string> vs;
    split(SArg(1), "::", vs);
    p->SetTips(vs);
    COMMON_RETURN_SELF;
  }

  static int gettips(T* p, lua_State* L) {
    std::vector<std::string> arrayTips, arrayTipsAlt;
    p->GetTips(arrayTips, arrayTipsAlt);

    LuaHelpers::CreateTableFromArray(arrayTips, L);
    LuaHelpers::CreateTableFromArray(arrayTipsAlt, L);

    return 2;
  }
  static int SetSecsBetweenSwitches(T* p, lua_State* L) {
    p->SetSecsBetweenSwitches(FArg(1));
    COMMON_RETURN_SELF;
  }

  LunaHelpDisplay() {
    ADD_METHOD(settips);
    ADD_METHOD(SetTipsColonSeparated);
    ADD_METHOD(gettips);
    ADD_METHOD(SetSecsBetweenSwitches);
  }
};

LUA_REGISTER_DERIVED_CLASS(HelpDisplay, BitmapText)

/*
 * (c) 2001-2003 Chris Danford, Glenn Maynard
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
