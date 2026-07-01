#include "LuaExpressionTransform.h"

#include <cmath>
#include <map>
#include <string>

#include "Actor.h"
#include "LuaManager.h"
#include "RageLog.h"
#include "RageUtil.h"
#include "global.h"

namespace {
void WarnLuaExpressionTransformAuditFix(const char* message) {
  if (LOG != nullptr) {
    LOG->Warn("%s", message);
  }
}

bool SanitizeTransformArgs(
    float& fPositionOffsetFromCenter, int& iItemIndex, int& iNumItems) {
  bool bValid = true;
  (void)iItemIndex;
  if (!std::isfinite(fPositionOffsetFromCenter)) {
    fPositionOffsetFromCenter = 0.0f;
    bValid = false;
  }
  if (iNumItems < 0) {
    iNumItems = 0;
    bValid = false;
  }
  return bValid;
}
}  // namespace

LuaExpressionTransform::LuaExpressionTransform() { m_iNumSubdivisions = 1; }

LuaExpressionTransform::~LuaExpressionTransform() {}

void LuaExpressionTransform::SetFromReference(const LuaReference& ref) {
  m_exprTransformFunction = ref;
  ClearCache();
}

bool LuaExpressionTransform::TransformItemDirect(
    Actor& a, float fPositionOffsetFromCenter, int iItemIndex,
    int iNumItems) const {
  if (!m_exprTransformFunction.IsSet() || m_exprTransformFunction.IsNil()) {
    return true;
  }
  if (LUA == nullptr) {
    WarnLuaExpressionTransformAuditFix(
        "SRC_AUDIT_FIX SRC-784: LuaExpressionTransform skipped invalid "
        "function.");
    return false;
  }
  SanitizeTransformArgs(fPositionOffsetFromCenter, iItemIndex, iNumItems);
  Lua* L = LUA->Get();
  m_exprTransformFunction.PushSelf(L);
  if (!lua_isfunction(L, -1)) {
    lua_pop(L, 1);
    LUA->Release(L);
    WarnLuaExpressionTransformAuditFix(
        "SRC_AUDIT_FIX SRC-784: LuaExpressionTransform skipped non-function.");
    return false;
  }
  a.PushSelf(L);
  LuaHelpers::Push(L, fPositionOffsetFromCenter);
  LuaHelpers::Push(L, iItemIndex);
  LuaHelpers::Push(L, iNumItems);
  std::string error = "Lua error in Transform function: ";
  const bool bSuccess = LuaHelpers::RunScriptOnStack(L, error, 4, 0, true);
  LUA->Release(L);
  return bSuccess;
}

bool LuaExpressionTransform::GetTransformCached(
    float fPositionOffsetFromCenter, int iItemIndex, int iNumItems,
    Actor::TweenState& tweenStateOut) const {
  SanitizeTransformArgs(fPositionOffsetFromCenter, iItemIndex, iNumItems);
  fPositionOffsetFromCenter =
      NormalizeOffsetForCache(fPositionOffsetFromCenter);
  PositionOffsetAndItemIndex key = {
      fPositionOffsetFromCenter, iItemIndex, iNumItems};

  std::map<PositionOffsetAndItemIndex, Actor::TweenState>::const_iterator iter =
      m_mapPositionToTweenStateCache.find(key);
  if (iter != m_mapPositionToTweenStateCache.end()) {
    tweenStateOut = iter->second;
    return true;
  }

  Actor a;
  if (!TransformItemDirect(
          a, fPositionOffsetFromCenter, iItemIndex, iNumItems)) {
    WarnLuaExpressionTransformAuditFix(
        "SRC_AUDIT_FIX SRC-2665: LuaExpressionTransform skipped failed cache "
        "entry.");
    return false;
  }
  tweenStateOut = a.DestTweenState();
  m_mapPositionToTweenStateCache[key] = tweenStateOut;
  return true;
}

bool LuaExpressionTransform::TransformItemCached(
    Actor& a, float fPositionOffsetFromCenter, int iItemIndex, int iNumItems) {
  SanitizeTransformArgs(fPositionOffsetFromCenter, iItemIndex, iNumItems);
  if (m_iNumSubdivisions <= 0) {
    m_iNumSubdivisions = 1;
  }
  float fInterval = 1.0f / m_iNumSubdivisions;
  float fFloor = QuantizeDown(fPositionOffsetFromCenter, fInterval);
  float fCeil = QuantizeUp(fPositionOffsetFromCenter, fInterval);

  if (fFloor == fCeil) {
    Actor::TweenState ts;
    if (!GetTransformCached(fCeil, iItemIndex, iNumItems, ts)) {
      return false;
    }
    a.DestTweenState() = ts;
  } else {
    Actor::TweenState tsFloor;
    Actor::TweenState tsCeil;
    if (!GetTransformCached(fFloor, iItemIndex, iNumItems, tsFloor) ||
        !GetTransformCached(fCeil, iItemIndex, iNumItems, tsCeil)) {
      return false;
    }

    float fPercentTowardCeil =
        SCALE(fPositionOffsetFromCenter, fFloor, fCeil, 0.0f, 1.0f);
    if (!std::isfinite(fPercentTowardCeil)) {
      fPercentTowardCeil = 0.0f;
    }
    Actor::TweenState::MakeWeightedAverage(
        a.DestTweenState(), tsFloor, tsCeil, fPercentTowardCeil);
  }
  return true;
}

float LuaExpressionTransform::NormalizeOffsetForCache(
    float fPositionOffsetFromCenter) const {
  if (!std::isfinite(fPositionOffsetFromCenter)) {
    return 0.0f;
  }
  int subdivisions = std::clamp(m_iNumSubdivisions, 1, 1024);
  float fInterval = 1.0f / subdivisions;
  return Quantize(fPositionOffsetFromCenter, fInterval);
}

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
