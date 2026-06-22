#include "WheelItemBase.h"

#include <cmath>
#include <string>

#include "Actor.h"
#include "ActorFrame.h"
#include "EnumHelper.h"
#include "LuaManager.h"
#include "RageLog.h"
#include "RageTypes.h"
#include "global.h"

static const char* WheelItemDataTypeNames[] = {
    "Generic", "Section", "Song", "Roulette", "Random",
    "Portal",  "Course",  "Sort", "Custom",
};
XToString(WheelItemDataType);
StringToX(WheelItemDataType);
LuaXType(WheelItemDataType);

namespace {
bool IsFiniteColor(const RageColor& color) {
  return std::isfinite(color.r) && std::isfinite(color.g) &&
         std::isfinite(color.b) && std::isfinite(color.a);
}

void WarnWheelItemBase(const char* message) {
  if (LOG != nullptr) {
    LOG->Warn("%s", message);
  }
}
}  // namespace

WheelItemBaseData::WheelItemBaseData(
    WheelItemDataType type, std::string sText, RageColor color) {
  m_Type = type;
  m_sText = sText;
  m_color = color;
}

// begin WheelItemBase
WheelItemBase::WheelItemBase(const WheelItemBase& cpy)
    : ActorFrame(cpy),
      m_colorLocked(cpy.m_colorLocked),
      m_pData(cpy.m_pData),
      m_bExpanded(cpy.m_bExpanded),
      m_pGrayBar(nullptr) {}

WheelItemBase::WheelItemBase(std::string sType) {
  SetName(sType);
  m_pData = nullptr;
  m_bExpanded = false;
  m_pGrayBar = nullptr;
  Load(sType);
}

void WheelItemBase::Load(std::string sType) {
  (void)sType;
  m_colorLocked = RageColor(0, 0, 0, 0.25f);
  m_pData = nullptr;
  m_pGrayBar = nullptr;
}

void WheelItemBase::LoadFromWheelItemData(
    const WheelItemBaseData* pWID, int iIndex, bool bHasFocus, int iDrawIndex) {
  (void)iIndex;
  (void)bHasFocus;
  (void)iDrawIndex;
  if (pWID == nullptr) {
    WarnWheelItemBase(
        "SRC_AUDIT_FIX SRC-1268: WheelItemBase ignored null wheel item data.");
    m_pData = nullptr;
    m_pGrayBar = nullptr;
    return;
  }
  m_pData = pWID;
}

void WheelItemBase::DrawGrayBar(Actor& bar) {
  if (m_colorLocked.a == 0 || !IsFiniteColor(m_colorLocked)) {
    return;
  }

  RageColor glow = bar.GetGlow();
  RageColor diffuse = bar.GetDiffuse();

  bar.SetGlow(m_colorLocked);
  bar.SetDiffuse(RageColor(0, 0, 0, 0));

  bar.Draw();

  bar.SetGlow(glow);
  bar.SetDiffuse(diffuse);
}

void WheelItemBase::DrawPrimitives() {
  ActorFrame::DrawPrimitives();

  if (m_pGrayBar != nullptr) {
    DrawGrayBar(*m_pGrayBar);
  }
}

const std::string WheelItemBase::GetText() const {
  if (m_pData == nullptr) {
    return "";
  }
  return m_pData->m_sText;
}

const RageColor WheelItemBase::GetColor() const {
  if (m_pData == nullptr) {
    return RageColor(1, 1, 1, 1);
  }
  return m_pData->m_color;
}

WheelItemDataType WheelItemBase::GetType() const {
  if (m_pData == nullptr) {
    return WheelItemDataType_Invalid;
  }
  return m_pData->m_Type;
}

// lua start
#include "LuaBinding.h"

/** @brief Allow Lua to have access to the WheelItemBase. */
class LunaWheelItemBase : public Luna<WheelItemBase> {
 public:
#define IS_LOADED_CHECK                                                       \
  if (!p->IsLoaded()) {                                                       \
    luaL_error(                                                               \
        L,                                                                    \
        "Wheel item is not loaded yet.  Use WheelItem:IsLoaded() to check."); \
  }

  static int GetColor(T* p, lua_State* L) {
    IS_LOADED_CHECK;
    LuaHelpers::Push(L, p->GetColor());
    return 1;
  }

  static int GetText(T* p, lua_State* L) {
    IS_LOADED_CHECK;
    LuaHelpers::Push(L, p->GetText());
    return 1;
  }

  static int GetType(T* p, lua_State* L) {
    IS_LOADED_CHECK;
    lua_pushnumber(L, p->GetType());
    return 1;
  }

  static int IsLoaded(T* p, lua_State* L) {
    lua_pushboolean(L, p->IsLoaded());
    return 1;
  }

  LunaWheelItemBase() {
    ADD_METHOD(GetColor);
    ADD_METHOD(GetText);
    ADD_METHOD(GetType);
    ADD_METHOD(IsLoaded);
  }
};
LUA_REGISTER_DERIVED_CLASS(WheelItemBase, ActorFrame)
// lua end

/*
 * (c) 2001-2004 Chris Danford, Chris Gomez, Glenn Maynard, Josh Allen
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
