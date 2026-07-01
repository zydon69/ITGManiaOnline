#include "ActorProxy.h"

#include <set>

#include "Actor.h"
#include "ActorUtil.h"
#include "RageLog.h"

REGISTER_ACTOR_CLASS(ActorProxy);

namespace {
std::set<ActorProxy*> g_ActorProxies;

void WarnActorProxyAuditFix(const char* message) {
  if (LOG != nullptr) {
    LOG->Warn("%s", message);
  }
}

bool WouldCreateProxyCycle(const ActorProxy* proxy, const Actor* target) {
  const Actor* current = target;
  for (int depth = 0; current != nullptr && depth < 64; ++depth) {
    if (current == proxy) {
      return true;
    }
    const ActorProxy* targetProxy = dynamic_cast<const ActorProxy*>(current);
    if (targetProxy == nullptr) {
      return false;
    }
    current = targetProxy->GetTarget();
  }
  return current != nullptr;
}
}  // namespace

ActorProxy::ActorProxy() {
  m_pActorTarget = nullptr;
  m_bDrawingTarget = false;
  g_ActorProxies.insert(this);
}

ActorProxy::ActorProxy(const ActorProxy& cpy) : Actor(cpy) {
  m_pActorTarget = nullptr;
  m_bDrawingTarget = false;
  g_ActorProxies.insert(this);
}

ActorProxy::~ActorProxy() {
  g_ActorProxies.erase(this);
}

bool ActorProxy::EarlyAbortDraw() const {
  return m_pActorTarget == nullptr || Actor::EarlyAbortDraw();
}

void ActorProxy::DrawPrimitives() {
  if (m_pActorTarget == nullptr || m_bDrawingTarget) {
    return;
  }

  Actor* target = m_pActorTarget;
  const bool bVisible = target->GetVisible();
  m_bDrawingTarget = true;
  target->SetVisible(true);
  target->Draw();
  m_bDrawingTarget = false;
  if (m_pActorTarget == target) {
    target->SetVisible(bVisible);
  }
}

void ActorProxy::LoadFromNode(const XNode* pNode) {
  Actor::LoadFromNode(pNode);
}

void ActorProxy::SetTarget(Actor* pTarget) {
  if (pTarget == nullptr) {
    m_pActorTarget = nullptr;
    return;
  }
  if (WouldCreateProxyCycle(this, pTarget)) {
    WarnActorProxyAuditFix(
        "SRC_AUDIT_FIX SRC-773: ActorProxy rejected cyclic target.");
    m_pActorTarget = nullptr;
    return;
  }
  m_pActorTarget = pTarget;
}

void ActorProxy::DetachTargetFromAll(const Actor* pTarget) {
  if (pTarget == nullptr) {
    return;
  }
  for (ActorProxy* proxy : g_ActorProxies) {
    if (proxy != nullptr && proxy->m_pActorTarget == pTarget) {
      proxy->m_pActorTarget = nullptr;
    }
  }
}

// lua start
#include "LuaBinding.h"

/** @brief Allow Lua to have access to the ActorProxy. */
class LunaActorProxy : public Luna<ActorProxy> {
 public:
  static int SetTarget(T* p, lua_State* L) {
    if (lua_isnoneornil(L, 1)) {
      p->SetTarget(nullptr);
      COMMON_RETURN_SELF;
    }
    Actor* pTarget = Luna<Actor>::check(L, 1);
    p->SetTarget(pTarget);
    COMMON_RETURN_SELF;
  }

  static int GetTarget(T* p, lua_State* L) {
    Actor* pTarget = p->GetTarget();
    if (pTarget != nullptr) {
      pTarget->PushSelf(L);
    } else {
      lua_pushnil(L);
    }
    return 1;
  }

  LunaActorProxy() {
    ADD_METHOD(SetTarget);
    ADD_METHOD(GetTarget);
  }
};

LUA_REGISTER_DERIVED_CLASS(ActorProxy, Actor)
// lua end

/*
 * (c) 2006 Glenn Maynard
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
