#include "DynamicActorScroller.h"

#include <algorithm>
#include <climits>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <memory>
#include <string>
#include <vector>

#include "Actor.h"
#include "ActorScroller.h"
#include "ActorUtil.h"
#include "LuaBinding.h"
#include "LuaManager.h"
#include "RageLog.h"
#include "RageUtil.h"
#include "XmlFile.h"
#include "global.h"

namespace {
void WarnDynamicActorScrollerSafety(const char* message) {
  if (LOG != nullptr) {
    LOG->Warn("%s", message);
  }
}
}  // namespace

DynamicActorScroller* DynamicActorScroller::Copy() const {
  return new DynamicActorScroller(*this);
}

void DynamicActorScroller::LoadFromNode(const XNode* pNode) {
  if (pNode == nullptr) {
    WarnDynamicActorScrollerSafety(
        "DynamicActorScroller ignored null XML node.");
    return;
  }
  ActorScroller::LoadFromNode(pNode);

  /* All of our children are identical, since they must be interchangeable.
   * The <children> node loads only one; we copy the rest.
   *
   * Make one extra copy if masking is enabled. */
  if (m_SubActors.size() != 1) {
    LuaHelpers::ReportScriptErrorFmt(
        "%s: DynamicActorScroller: loaded %i nodes; require exactly one",
        ActorUtil::GetWhere(pNode).c_str(), (int)m_SubActors.size());
    // Remove all but one.
    while (m_SubActors.size() > 1) {
      Actor* extra = m_SubActors.back();
      RemoveChild(extra);
      delete extra;
    }
    if (m_SubActors.empty()) {
      WarnDynamicActorScrollerSafety(
          "DynamicActorScroller created fallback "
          "template child.");
      AddChild(new Actor);
    }
  }

  if (LUA != nullptr) {
    Lua* L = LUA->Get();
    pNode->PushAttrValue(L, "LoadFunction");
    m_LoadFunction.SetFromStack(L);
    LUA->Release(L);
  } else {
    WarnDynamicActorScrollerSafety(
        "DynamicActorScroller skipped LoadFunction "
        "without LUA.");
    m_iNumItems = 0;
    return;
  }

  if (!m_LoadFunction.IsSet() || m_LoadFunction.IsNil()) {
    WarnDynamicActorScrollerSafety(
        "DynamicActorScroller missing LoadFunction.");
    m_iNumItems = 0;
    return;
  }

  // Call the expression with line = nil to find out the number of lines.
  {
    Lua* L = LUA->Get();
    m_LoadFunction.PushSelf(L);
    if (!lua_isfunction(L, -1)) {
      lua_pop(L, 1);
      LUA->Release(L);
      WarnDynamicActorScrollerSafety(
          "DynamicActorScroller LoadFunction is not a "
          "function.");
      m_iNumItems = 0;
      return;
    }
    lua_pushnil(L);
    lua_pushnil(L);

    std::string Error = "Error running LoadFunction: ";
    const bool ok =
        LuaHelpers::RunScriptOnStack(L, Error, 2, 1, true);  // 2 args, 1 result

    float numItems =
        ok && lua_isnumber(L, -1) ? (float)lua_tonumber(L, -1) : 0.0f;
    if (!std::isfinite(numItems) || numItems < 0.0f) {
      WarnDynamicActorScrollerSafety(
          "DynamicActorScroller replaced invalid item "
          "count.");
      numItems = 0.0f;
    }
    numItems = std::min(numItems, 1000000.0f);
    m_iNumItems = static_cast<int>(numItems);
    lua_pop(L, 1);
    LUA->Release(L);
  }

  int iNumCopies =
      std::clamp((int)std::ceil(std::max(1.0f, m_fNumItemsToDraw)), 1, 1024);
  if (m_quadMask.GetVisible()) {
    iNumCopies += 1;
  }
  std::vector<std::unique_ptr<Actor>> copies;
  copies.reserve(static_cast<size_t>(iNumCopies - 1));
  for (int i = 1; i < iNumCopies; ++i) {
    std::unique_ptr<Actor> copy(m_SubActors[0]->Copy());
    if (copy == nullptr) {
      WarnDynamicActorScrollerSafety(
          "DynamicActorScroller replaced null copy.");
      copy.reset(new Actor);
    }
    copies.push_back(std::move(copy));
  }
  for (std::unique_ptr<Actor>& copy : copies) {
    AddChild(copy.get());
    copy.release();
  }

  /* Reconfigure all items, so the loaded actors actually correspond with
   * m_iFirstSubActorIndex. */
  ShiftSubActors(INT_MAX);
}

/* Shift m_SubActors forward by iDist, and then fill in the new entries.
 *
 * Important: under normal scrolling, with or without m_bLoop, at most one
 * object is created per update, and this normally only happens when an
 * object comes on screen.  Extra actor updates are avoided for efficiency. */
void DynamicActorScroller::ShiftSubActors(int iDist) {
  const bool bReconfigureAll = iDist == INT_MAX;
  ActorScroller::ShiftSubActors(iDist);

  if (iDist == 0 || m_SubActors.empty() || m_iNumItems <= 0) {
    return;
  }

  if (m_bLoop && !bReconfigureAll) {
    /* Optimization: in a loop of 10, when we loop around from 9 to 0,
     * iDist will be -9.  Moving -9 is equivalent to moving +1, and
     * reconfigures much fewer actors. */
    int iWrapped = iDist;
    wrap(iWrapped, m_iNumItems);
    if (std::abs(static_cast<int64_t>(iWrapped)) <
        std::abs(static_cast<int64_t>(iDist))) {
      iDist = iWrapped;
    }
  }

  const std::vector<Actor*> children = m_SubActors;
  int iFirstToReconfigure = 0;
  int iLastToReconfigure = static_cast<int>(children.size());
  if (!bReconfigureAll && iDist > 0 &&
      iDist < static_cast<int>(children.size())) {
    iFirstToReconfigure = static_cast<int>(children.size()) - iDist;
  } else if (
      !bReconfigureAll && iDist < 0 &&
      -static_cast<int64_t>(iDist) < static_cast<int64_t>(children.size())) {
    iLastToReconfigure = -iDist;
  }

  for (int i = iFirstToReconfigure; i < iLastToReconfigure; i++) {
    int iIndex = i;  // index into m_SubActors
    int iItem = i + m_iFirstSubActorIndex;
    if (m_bLoop) {
      wrap(iIndex, children.size());
      wrap(iItem, m_iNumItems);
    } else if (
        iIndex < 0 || iIndex >= static_cast<int>(children.size()) || iItem < 0 ||
        iItem >= m_iNumItems) {
      continue;
    }

    Actor* actor = children[iIndex];
    if (actor == nullptr || !ContainsChild(actor)) {
      continue;
    }
    {
      if (LUA == nullptr) {
        WarnDynamicActorScrollerSafety(
            "DynamicActorScroller skipped item index "
            "without LUA.");
        continue;
      }
      Lua* L = LUA->Get();
      lua_pushnumber(L, iItem);
      actor->m_pLuaInstance->Set(L, "ItemIndex");
      LUA->Release(L);
    }

    ConfigureActor(actor, iItem);
  }
}

void DynamicActorScroller::ConfigureActor(Actor* pActor, int iItem) {
  if (LUA == nullptr || pActor == nullptr || !m_LoadFunction.IsSet() ||
      m_LoadFunction.IsNil()) {
    if (pActor != nullptr) {
      pActor->SetVisible(false);
    }
    WarnDynamicActorScrollerSafety(
        "DynamicActorScroller skipped invalid "
        "ConfigureActor.");
    return;
  }
  Lua* L = LUA->Get();
  m_LoadFunction.PushSelf(L);
  if (!lua_isfunction(L, -1)) {
    lua_pop(L, 1);
    LUA->Release(L);
    pActor->SetVisible(false);
    WarnDynamicActorScrollerSafety(
        "DynamicActorScroller skipped non-function "
        "ConfigureActor.");
    return;
  }
  pActor->SetVisible(true);
  pActor->PushSelf(L);
  LuaHelpers::Push(L, iItem);

  std::string Error = "Error running LoadFunction: ";
  const bool ok =
      LuaHelpers::RunScriptOnStack(L, Error, 2, 0, true);  // 2 args, 0 results

  LUA->Release(L);
  if (!ok && ContainsChild(pActor)) {
    pActor->SetVisible(false);
    WarnDynamicActorScrollerSafety(
        "DynamicActorScroller hid failed item.");
  }
}

REGISTER_ACTOR_CLASS_WITH_NAME(
    DynamicActorScrollerAutoDeleteChildren, DynamicActorScroller);

/*
 * (c) 2005 Glenn Maynard
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
