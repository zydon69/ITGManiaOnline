#include "ActorScroller.h"

#include <algorithm>
#include <climits>
#include <cmath>
#include <limits>
#include <string>
#include <vector>

#include "Actor.h"
#include "ActorFrame.h"
#include "ActorUtil.h"
#include "LuaBinding.h"
#include "LuaManager.h"
#include "RageLog.h"
#include "RageTypes.h"
#include "RageUtil.h"
#include "XmlFile.h"

namespace {
constexpr float kMaxScrollerItemPadding = 1024.0f;
constexpr float kMaxScrollerLogicalItems = 1000000.0f;

float FiniteOrScroller(float value, float fallback) {
  return std::isfinite(value) ? value : fallback;
}

float NonNegativeFiniteOrScroller(float value, float fallback) {
  return std::isfinite(value) && value >= 0.0f ? value : fallback;
}

void WarnActorScrollerAuditFix(const char* message) {
  if (LOG != nullptr) {
    LOG->Warn("%s", message);
  }
}

int SafeCeilToInt(float value, int fallback) {
  if (!std::isfinite(value)) {
    return fallback;
  }
  const float lower = (float)std::numeric_limits<int>::min() / 4.0f;
  const float upper = (float)std::numeric_limits<int>::max() / 4.0f;
  value = std::clamp(value, lower, upper);
  return (int)std::ceil(value);
}
}  // namespace

/* Tricky: We need ActorFrames created in Lua to auto delete their children.
 * We don't want classes that derive from ActorFrame to auto delete their
 * children. The name "ActorFrame" is widely used in Lua, so we'll have
 * that string instead create an ActorFrameAutoDeleteChildren object. */
// REGISTER_ACTOR_CLASS( ActorScroller );
REGISTER_ACTOR_CLASS_WITH_NAME(ActorScrollerAutoDeleteChildren, ActorScroller);
ActorScroller* ActorScroller::Copy() const { return new ActorScroller(*this); }

ActorScroller::ActorScroller() {
  m_iNumItems = 0;
  m_fCurrentItem = 0;
  m_fDestinationItem = 0;
  m_fSecondsPerItem = 1;
  m_fSecondsPauseBetweenItems = 0;
  m_fNumItemsToDraw = 7;
  m_iFirstSubActorIndex = 0;
  m_bLoop = false;
  m_bWrap = false;
  m_bFastCatchup = false;
  m_bFunctionDependsOnPositionOffset = true;
  m_bFunctionDependsOnItemIndex = true;
  m_fPauseCountdownSeconds = 0;
  m_fQuantizePixels = 0;

  m_quadMask.SetBlendMode(BLEND_NO_EFFECT);  // don't change color values
  m_quadMask.SetUseZBuffer(true);            // we want to write to the Zbuffer
  m_fMaskWidth = 0;
  m_fMaskHeight = 0;
  DisableMask();
}

float ActorScroller::ClampItemIndex(float fItemIndex) const {
  if (!std::isfinite(fItemIndex)) {
    WarnActorScrollerAuditFix(
        "SRC_AUDIT_FIX SRC-2655: ActorScroller replaced invalid item index.");
    return 0.0f;
  }

  const float logicalItems =
      std::clamp((float)std::max(m_iNumItems, 0), 0.0f, kMaxScrollerLogicalItems);
  const float drawWindow =
      NonNegativeFiniteOrScroller(m_fNumItemsToDraw, 0.0f);
  const float limit = std::clamp(
      logicalItems + drawWindow + kMaxScrollerItemPadding,
      kMaxScrollerItemPadding,
      kMaxScrollerLogicalItems + kMaxScrollerItemPadding);
  const float clamped = std::clamp(fItemIndex, -limit, limit);
  if (clamped != fItemIndex) {
    WarnActorScrollerAuditFix(
        "SRC_AUDIT_FIX SRC-2655: ActorScroller clamped oversized item index.");
  }
  return clamped;
}

int ActorScroller::NormalizeShiftDistance(int iDist) const {
  if (iDist == INT_MAX || m_SubActors.empty()) {
    return 0;
  }
  const int size = (int)m_SubActors.size();
  if (size <= 0) {
    return 0;
  }
  int normalized = iDist % size;
  if (normalized > size / 2) {
    normalized -= size;
  } else if (normalized < -size / 2) {
    normalized += size;
  }
  return normalized;
}

void ActorScroller::ResetScrollerLoadState() {
  m_fSecondsPerItem = 1.0f;
  m_fSecondsPauseBetweenItems = 0.0f;
  m_fNumItemsToDraw = 7.0f;
  m_bLoop = false;
  m_bWrap = false;
  m_fPauseCountdownSeconds = 0.0f;
  m_fQuantizePixels = 0.0f;
  m_fMaskWidth = 0.0f;
  m_fMaskHeight = 0.0f;
  DisableMask();

  LuaReference nilReference;
  nilReference.SetFromNil();
  SetTransformFromReference(nilReference);
  SetNumSubdivisions(1);
}

void ActorScroller::SyncNumItemsToChildren() {
  if (SyncItemCountWithChildren()) {
    m_iNumItems = (int)std::min<size_t>(
        m_SubActors.size(), (size_t)kMaxScrollerLogicalItems);
  }
}

void ActorScroller::AddChild(Actor* pActor) {
  ActorFrame::AddChild(pActor);
  SyncNumItemsToChildren();
}

void ActorScroller::RemoveChild(Actor* pActor) {
  ActorFrame::RemoveChild(pActor);
  SyncNumItemsToChildren();
  m_fCurrentItem = ClampItemIndex(m_fCurrentItem);
  m_fDestinationItem = ClampItemIndex(m_fDestinationItem);
}

void ActorScroller::SetDestinationItem(float fItemIndex) {
  m_fDestinationItem = ClampItemIndex(fItemIndex);
  if (m_fSecondsPerItem <= 0.0f) {
    m_fCurrentItem = m_fDestinationItem;
  }
}

void ActorScroller::SetCurrentAndDestinationItem(float fItemIndex) {
  m_fCurrentItem = m_fDestinationItem = ClampItemIndex(fItemIndex);
}

void ActorScroller::Load2() {
  m_iNumItems = m_SubActors.size();

  if (LUA == nullptr) {
    WarnActorScrollerAuditFix(
        "SRC_AUDIT_FIX SRC-774: ActorScroller skipped Load2 without LUA.");
    return;
  }
  Lua* L = LUA->Get();
  for (unsigned i = 0; i < m_SubActors.size(); ++i) {
    if (m_SubActors[i] == nullptr) {
      continue;
    }
    lua_pushnumber(L, i);
    this->m_SubActors[i]->m_pLuaInstance->Set(L, "ItemIndex");
  }
  LUA->Release(L);
}

void ActorScroller::SetTransformFromReference(const LuaReference& ref) {
  m_exprTransformFunction.SetFromReference(ref);
  m_bFunctionDependsOnPositionOffset = true;
  m_bFunctionDependsOnItemIndex = true;
  if (LUA == nullptr || !ref.IsSet() || ref.IsNil()) {
    m_exprTransformFunction.ClearCache();
    return;
  }

  // Theme transform functions can be non-linear or stateful.  Assume both
  // parameters are used so caching never feeds zeroed arguments to Lua.
  m_exprTransformFunction.ClearCache();
}

void ActorScroller::SetTransformFromExpression(
    const std::string& sTransformFunction) {
  LuaReference ref;
  ref.SetFromExpression(sTransformFunction);
  SetTransformFromReference(ref);
}

void ActorScroller::SetTransformFromWidth(float fItemWidth) {
  fItemWidth = FiniteOrScroller(fItemWidth, 0.0f);
  SetTransformFromExpression(ssprintf(
      "function(self,offset,itemIndex,numItems) self:x(%f*offset) end",
      fItemWidth));
}

void ActorScroller::SetTransformFromHeight(float fItemHeight) {
  fItemHeight = FiniteOrScroller(fItemHeight, 0.0f);
  SetTransformFromExpression(ssprintf(
      "function(self,offset,itemIndex,numItems) self:y(%f*offset) end",
      fItemHeight));
}

void ActorScroller::EnableMask(float fWidth, float fHeight) {
  fWidth = NonNegativeFiniteOrScroller(fWidth, 0.0f);
  fHeight = NonNegativeFiniteOrScroller(fHeight, 0.0f);
  m_quadMask.SetVisible(fWidth != 0 && fHeight != 0);
  m_quadMask.SetWidth(fWidth);
  m_fMaskWidth = fWidth;
  m_quadMask.SetHeight(fHeight);
  m_fMaskHeight = fHeight;
}

void ActorScroller::DisableMask() { m_quadMask.SetVisible(false); }

void ActorScroller::ScrollThroughAllItems() {
  const float start = (m_bLoop || m_bWrap) ? +m_fNumItemsToDraw / 2.0f
                                           : -(m_fNumItemsToDraw / 2.0f) - 1;
  const float destination =
      (float)(m_iNumItems + m_fNumItemsToDraw / 2.0f + 1);
  m_fCurrentItem = ClampItemIndex(start);
  m_fDestinationItem = ClampItemIndex(destination);
}

void ActorScroller::ScrollWithPadding(
    float fItemPaddingStart, float fItemPaddingEnd) {
  fItemPaddingStart = std::min(
      NonNegativeFiniteOrScroller(fItemPaddingStart, 0.0f),
      kMaxScrollerItemPadding);
  fItemPaddingEnd = std::min(
      NonNegativeFiniteOrScroller(fItemPaddingEnd, 0.0f),
      kMaxScrollerItemPadding);
  m_fCurrentItem = ClampItemIndex(-fItemPaddingStart);
  m_fDestinationItem = ClampItemIndex(m_iNumItems - 1 + fItemPaddingEnd);
}

float ActorScroller::GetSecondsForCompleteScrollThrough() const {
  float fTotalItems = m_fNumItemsToDraw + m_iNumItems;
  return FiniteOrScroller(
      fTotalItems * (m_fSecondsPerItem + m_fSecondsPauseBetweenItems), 0.0f);
}

float ActorScroller::GetSecondsToDestination() const {
  float fTotalItemsToMove = std::abs(m_fCurrentItem - m_fDestinationItem);
  return FiniteOrScroller(fTotalItemsToMove * m_fSecondsPerItem, 0.0f);
}

void ActorScroller::LoadFromNode(const XNode* pNode) {
  if (pNode == nullptr) {
    WarnActorScrollerAuditFix(
        "SRC_AUDIT_FIX SRC-774: ActorScroller ignored null XML node.");
    return;
  }
  ResetScrollerLoadState();
  ActorFrame::LoadFromNode(pNode);

  Load2();

  float fNumItemsToDraw = 0;
  if (pNode->GetAttrValue("NumItemsToDraw", fNumItemsToDraw)) {
    SetNumItemsToDraw(fNumItemsToDraw);
  }

  float fSecondsPerItem = 0;
  if (pNode->GetAttrValue("SecondsPerItem", fSecondsPerItem)) {
    ActorScroller::SetSecondsPerItem(fSecondsPerItem);
  }

  if (LUA != nullptr) {
    Lua* L = LUA->Get();
    pNode->PushAttrValue(L, "TransformFunction");
    {
      LuaReference ref;
      ref.SetFromStack(L);
      if (!ref.IsNil()) {
        SetTransformFromReference(ref);
      }
    }
    LUA->Release(L);
  } else {
    WarnActorScrollerAuditFix(
        "SRC_AUDIT_FIX SRC-774: ActorScroller skipped transform without LUA.");
  }

  int iSubdivisions = 1;
  if (pNode->GetAttrValue("Subdivisions", iSubdivisions)) {
    ActorScroller::SetNumSubdivisions(iSubdivisions);
  }

  bool bUseMask = false;
  pNode->GetAttrValue("UseMask", bUseMask);

  if (bUseMask) {
    pNode->GetAttrValue("MaskWidth", m_fMaskWidth);
    pNode->GetAttrValue("MaskHeight", m_fMaskHeight);
    EnableMask(m_fMaskWidth, m_fMaskHeight);
  }

  pNode->GetAttrValue("QuantizePixels", m_fQuantizePixels);
  m_fQuantizePixels = NonNegativeFiniteOrScroller(m_fQuantizePixels, 0.0f);
  pNode->GetAttrValue("LoopScroller", m_bLoop);
  pNode->GetAttrValue("WrapScroller", m_bWrap);
}

void ActorScroller::UpdateInternal(float fDeltaTime) {
  if (!std::isfinite(fDeltaTime) || fDeltaTime < 0.0f) {
    WarnActorScrollerAuditFix(
        "SRC_AUDIT_FIX SRC-775: ActorScroller ignored invalid delta.");
    return;
  }
  ActorFrame::UpdateInternal(fDeltaTime);

  // If we have no children, the code below will busy loop.
  if (m_SubActors.empty() || m_iNumItems <= 0) {
    return;
  }

  // handle pause
  if (fDeltaTime > m_fPauseCountdownSeconds) {
    fDeltaTime -= m_fPauseCountdownSeconds;
    m_fPauseCountdownSeconds = 0;
  } else {
    m_fPauseCountdownSeconds -= fDeltaTime;
    fDeltaTime = 0;
    return;
  }

  if (m_fCurrentItem == m_fDestinationItem) {
    return;  // done scrolling
  }

  float fOldItemAtTop = m_fCurrentItem;
  if (m_fSecondsPerItem > 0) {
    const float fDistanceToMove =
        std::abs(m_fCurrentItem - m_fDestinationItem);
    float fApproachSpeed = fDeltaTime / m_fSecondsPerItem;
    if (m_bFastCatchup) {
      if (fDistanceToMove > 1) {
        fApproachSpeed *= fDistanceToMove * fDistanceToMove;
      }
    }
    fApproachSpeed = FiniteOrScroller(fApproachSpeed, fDistanceToMove);

    fapproach(m_fCurrentItem, m_fDestinationItem, fApproachSpeed);
  }

  // if items changed, then pause
  if ((int)fOldItemAtTop != (int)m_fCurrentItem) {
    m_fPauseCountdownSeconds = m_fSecondsPauseBetweenItems;
  }

  if (m_bWrap) {
    float Delta = m_fDestinationItem - m_fCurrentItem;
    m_fCurrentItem = std::fmod(m_fCurrentItem, (float)m_iNumItems);
    m_fDestinationItem = m_fCurrentItem + Delta;
  }

  if (m_bLoop) {
    m_fCurrentItem = std::fmod(m_fCurrentItem, (float)m_iNumItems);
  }
}

void ActorScroller::DrawPrimitives() { PositionItemsAndDrawPrimitives(true); }

void ActorScroller::PositionItems() { PositionItemsAndDrawPrimitives(false); }

/* Shift m_SubActors forward by iDist. This will place item
 * m_iFirstSubActorIndex in m_SubActors[0]. */
void ActorScroller::ShiftSubActors(int iDist) {
  const int normalized = NormalizeShiftDistance(iDist);
  if (normalized > 0) {
    std::rotate(
        m_SubActors.begin(),
        m_SubActors.begin() + normalized,
        m_SubActors.end());
  } else if (normalized < 0) {
    std::rotate(
        m_SubActors.begin(),
        m_SubActors.end() + normalized,
        m_SubActors.end());
  }
}

void ActorScroller::PositionItemsAndDrawPrimitives(bool bDrawPrimitives) {
  if (m_SubActors.empty()) {
    return;
  }

  if (!std::isfinite(m_fCurrentItem) || !std::isfinite(m_fDestinationItem) ||
      !std::isfinite(m_fNumItemsToDraw)) {
    WarnActorScrollerAuditFix(
        "SRC_AUDIT_FIX SRC-775: ActorScroller skipped invalid positioning.");
    return;
  }

  float fNumItemsToDraw = NonNegativeFiniteOrScroller(m_fNumItemsToDraw, 0.0f);
  if (m_quadMask.GetVisible()) {
    // write to z buffer so that top and bottom are clipped
    // Draw an extra item; this is the one that will be masked.
    fNumItemsToDraw++;
    float fPositionFullyOffScreenTop = -(fNumItemsToDraw) / 2.f;
    float fPositionFullyOffScreenBottom = (fNumItemsToDraw) / 2.f;

    m_exprTransformFunction.TransformItemCached(
        m_quadMask, fPositionFullyOffScreenTop, -1, m_iNumItems);
    if (bDrawPrimitives) {
      m_quadMask.Draw();
    }

    m_exprTransformFunction.TransformItemCached(
        m_quadMask, fPositionFullyOffScreenBottom, m_iNumItems, m_iNumItems);
    if (bDrawPrimitives) {
      m_quadMask.Draw();
    }
  }

  float fFirstItemToDraw = m_fCurrentItem - fNumItemsToDraw / 2.f;
  float fLastItemToDraw = m_fCurrentItem + fNumItemsToDraw / 2.f;
  int iFirstItemToDraw = SafeCeilToInt(fFirstItemToDraw, 0);
  int iLastItemToDraw = SafeCeilToInt(fLastItemToDraw, iFirstItemToDraw);
  if (!m_bLoop && !m_bWrap) {
    iFirstItemToDraw = std::clamp(iFirstItemToDraw, 0, m_iNumItems);
    iLastItemToDraw = std::clamp(iLastItemToDraw, 0, m_iNumItems);
  }

  std::vector<Actor*> subs;

  {
    // Shift m_SubActors so iFirstItemToDraw is at the beginning.
    int iNewFirstIndex = iFirstItemToDraw;
    int iDist = iNewFirstIndex - m_iFirstSubActorIndex;
    m_iFirstSubActorIndex = iNewFirstIndex;
    ShiftSubActors(iDist);
  }

  int iNumToDraw = iLastItemToDraw - iFirstItemToDraw;
  for (int i = 0; i < iNumToDraw; ++i) {
    int iItem = i + iFirstItemToDraw;
    float fPosition = iItem - m_fCurrentItem;
    int iIndex = i;  // index into m_SubActors
    if (m_bLoop || m_bWrap) {
      if (m_SubActors.empty()) {
        break;
      }
      wrap(iIndex, m_SubActors.size());
    } else if (iIndex < 0 || iIndex >= (int)m_SubActors.size()) {
      continue;
    }
    Actor* child = m_SubActors[iIndex];
    if (child == nullptr || !ContainsChild(child)) {
      continue;
    }

    // Optimization: Zero out unused parameters so that they don't create new,
    // unnecessary  entries in the position cache. On scrollers with lots of
    // items, especially with Subdivisions > 1, m_exprTransformFunction uses
    // too much memory.
    if (!m_bFunctionDependsOnPositionOffset) {
      fPosition = 0;
    }
    if (!m_bFunctionDependsOnItemIndex) {
      iItem = 0;
    }

    const unsigned mutationVersion = m_iChildMutationVersion;
    m_exprTransformFunction.TransformItemCached(
        *child, fPosition, iItem, m_iNumItems);
    if (mutationVersion != m_iChildMutationVersion || !ContainsChild(child)) {
      continue;
    }
    if (m_fQuantizePixels > 0.0f) {
      Actor::TweenState& state = child->DestTweenState();
      state.pos.x =
          std::round(state.pos.x / m_fQuantizePixels) * m_fQuantizePixels;
      state.pos.y =
          std::round(state.pos.y / m_fQuantizePixels) * m_fQuantizePixels;
      state.pos.z =
          std::round(state.pos.z / m_fQuantizePixels) * m_fQuantizePixels;
    }
    if (bDrawPrimitives) {
      if (m_bDrawByZPosition) {
        subs.push_back(child);
      } else {
        child->Draw();
      }
    }
  }

  if (m_bDrawByZPosition) {
    ActorUtil::SortByZPosition(subs);
    for (Actor* a : subs) {
      if (a != nullptr && ContainsChild(a)) {
        a->Draw();
      }
    }
  }
}

// lua start
#include "LuaBinding.h"

/** @brief Allow Lua to have access to the ActorScroller. */
class LunaActorScroller : public Luna<ActorScroller> {
 public:
  static int PositionItems(T* p, lua_State* L) {
    p->PositionItems();
    COMMON_RETURN_SELF;
  }
  static int SetTransformFromFunction(T* p, lua_State* L) {
    LuaReference ref;
    LuaHelpers::FromStack(L, ref, 1);
    p->SetTransformFromReference(ref);
    COMMON_RETURN_SELF;
  }
  static int SetTransformFromHeight(T* p, lua_State* L) {
    p->SetTransformFromHeight(FArg(1));
    COMMON_RETURN_SELF;
  }
  static int SetTransformFromWidth(T* p, lua_State* L) {
    p->SetTransformFromWidth(FArg(1));
    COMMON_RETURN_SELF;
  }
  static int SetCurrentAndDestinationItem(T* p, lua_State* L) {
    p->SetCurrentAndDestinationItem(FArg(1));
    COMMON_RETURN_SELF;
  }
  static int SetDestinationItem(T* p, lua_State* L) {
    p->SetDestinationItem(FArg(1));
    COMMON_RETURN_SELF;
  }
  static int GetSecondsToDestination(T* p, lua_State* L) {
    lua_pushnumber(L, p->GetSecondsToDestination());
    return 1;
  }
  static int SetSecondsPerItem(T* p, lua_State* L) {
    p->SetSecondsPerItem(FArg(1));
    COMMON_RETURN_SELF;
  }
  static int GetSecondsPauseBetweenItems(T* p, lua_State* L) {
    lua_pushnumber(L, p->GetSecondsPauseBetweenItems());
    return 1;
  }
  static int SetSecondsPauseBetweenItems(T* p, lua_State* L) {
    p->SetSecondsPauseBetweenItems(FArg(1));
    COMMON_RETURN_SELF;
  }
  static int SetPauseCountdownSeconds(T* p, lua_State* L) {
    p->SetPauseCountdownSeconds(FArg(1));
    COMMON_RETURN_SELF;
  }
  static int SetNumSubdivisions(T* p, lua_State* L) {
    p->SetNumSubdivisions(IArg(1));
    COMMON_RETURN_SELF;
  }
  static int ScrollThroughAllItems(T* p, lua_State* L) {
    p->ScrollThroughAllItems();
    COMMON_RETURN_SELF;
  }
  static int ScrollWithPadding(T* p, lua_State* L) {
    p->ScrollWithPadding(FArg(1), FArg(2));
    COMMON_RETURN_SELF;
  }
  static int SetFastCatchup(T* p, lua_State* L) {
    p->SetFastCatchup(BArg(1));
    COMMON_RETURN_SELF;
  }
  static int SetLoop(T* p, lua_State* L) {
    p->SetLoop(BArg(1));
    COMMON_RETURN_SELF;
  }
  static int SetWrap(T* p, lua_State* L) {
    p->SetWrap(BArg(1));
    COMMON_RETURN_SELF;
  }
  static int SetMask(T* p, lua_State* L) {
    p->EnableMask(FArg(1), FArg(2));
    COMMON_RETURN_SELF;
  }

  static int SetNumItemsToDraw(T* p, lua_State* L) {
    p->SetNumItemsToDraw(FArg(1));
    COMMON_RETURN_SELF;
  }
  static int GetFullScrollLengthSeconds(T* p, lua_State* L) {
    lua_pushnumber(L, p->GetSecondsForCompleteScrollThrough());
    return 1;
  }
  static int GetCurrentItem(T* p, lua_State* L) {
    lua_pushnumber(L, p->GetCurrentItem());
    return 1;
  }
  static int GetDestinationItem(T* p, lua_State* L) {
    lua_pushnumber(L, p->GetDestinationItem());
    return 1;
  }
  static int GetNumItems(T* p, lua_State* L) {
    lua_pushnumber(L, p->GetNumItems());
    return 1;
  }

  LunaActorScroller() {
    ADD_METHOD(PositionItems);
    ADD_METHOD(SetTransformFromFunction);
    ADD_METHOD(SetTransformFromHeight);
    ADD_METHOD(SetTransformFromWidth);
    ADD_METHOD(SetCurrentAndDestinationItem);
    ADD_METHOD(SetDestinationItem);
    ADD_METHOD(GetSecondsToDestination);
    ADD_METHOD(SetSecondsPerItem);
    ADD_METHOD(SetSecondsPauseBetweenItems);
    ADD_METHOD(GetSecondsPauseBetweenItems);
    ADD_METHOD(SetPauseCountdownSeconds);
    ADD_METHOD(SetNumSubdivisions);
    ADD_METHOD(ScrollThroughAllItems);
    ADD_METHOD(ScrollWithPadding);
    ADD_METHOD(SetFastCatchup);
    ADD_METHOD(SetLoop);
    ADD_METHOD(SetWrap);
    ADD_METHOD(SetMask);
    ADD_METHOD(SetNumItemsToDraw);
    ADD_METHOD(GetFullScrollLengthSeconds);
    ADD_METHOD(GetCurrentItem);
    ADD_METHOD(GetDestinationItem);
    ADD_METHOD(GetNumItems);
  }
};

LUA_REGISTER_DERIVED_CLASS(ActorScroller, ActorFrame)
// lua end

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
