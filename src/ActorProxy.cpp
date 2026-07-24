#include "ActorProxy.h"

#include <map>
#include <memory>
#include <set>
#include <vector>

#include "Actor.h"
#include "ActorUtil.h"
#include "RageLog.h"

namespace {
struct ActorLifetimeToken {
  bool alive = true;
};

std::set<ActorProxy*>& ActorProxyRegistry() {
  static std::set<ActorProxy*>* registry = new std::set<ActorProxy*>;
  return *registry;
}

std::map<const Actor*, std::weak_ptr<ActorLifetimeToken>>&
ActorLifetimeRegistry() {
  static std::map<const Actor*, std::weak_ptr<ActorLifetimeToken>>* registry =
      new std::map<const Actor*, std::weak_ptr<ActorLifetimeToken>>;
  return *registry;
}

void WarnActorProxySafety(const char* message) {
  if (LOG != nullptr) {
    LOG->Warn("%s", message);
  }
}

std::shared_ptr<ActorLifetimeToken> WatchActorLifetime(const Actor* actor) {
  std::map<const Actor*, std::weak_ptr<ActorLifetimeToken>>& registry =
      ActorLifetimeRegistry();
  std::shared_ptr<ActorLifetimeToken> token = registry[actor].lock();
  if (token == nullptr) {
    token = std::make_shared<ActorLifetimeToken>();
    registry[actor] = token;
  }
  return token;
}

void MarkActorDestroyed(const Actor* actor) {
  std::map<const Actor*, std::weak_ptr<ActorLifetimeToken>>& registry =
      ActorLifetimeRegistry();
  std::map<const Actor*, std::weak_ptr<ActorLifetimeToken>>::iterator iter =
      registry.find(actor);
  if (iter == registry.end()) {
    return;
  }

  std::shared_ptr<ActorLifetimeToken> token = iter->second.lock();
  if (token != nullptr) {
    token->alive = false;
  }
  registry.erase(iter);
}

class TargetVisibilityGuard {
 public:
  explicit TargetVisibilityGuard(Actor* target)
      : m_pTarget(target),
        m_bOriginalVisible(target->GetVisible()),
        m_pTargetToken(WatchActorLifetime(target)) {
    m_pTarget->SetVisible(true);
  }

  ~TargetVisibilityGuard() {
    if (m_pTargetToken != nullptr && m_pTargetToken->alive) {
      m_pTarget->SetVisible(m_bOriginalVisible);
    }
  }

 private:
  Actor* m_pTarget;
  bool m_bOriginalVisible;
  std::shared_ptr<ActorLifetimeToken> m_pTargetToken;
};

struct RegisterActorProxy {
  RegisterActorProxy() {
    ActorUtil::Register("ActorProxy", CreateActor<ActorProxy>);
  }
};

static RegisterActorProxy registerActorProxy;

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
  m_pLifetimeToken = std::make_shared<LifetimeToken>();
  ActorProxyRegistry().insert(this);
}

ActorProxy::ActorProxy(const ActorProxy& cpy) : Actor(cpy) {
  m_pActorTarget = nullptr;
  m_bDrawingTarget = false;
  m_pLifetimeToken = std::make_shared<LifetimeToken>();
  ActorProxyRegistry().insert(this);
  if (cpy.m_pActorTarget != nullptr) {
    WarnActorProxySafety(
        "ActorProxy copy intentionally dropped target.");
  }
}

ActorProxy::~ActorProxy() {
  if (m_pLifetimeToken != nullptr) {
    m_pLifetimeToken->alive = false;
  }
  ActorProxyRegistry().erase(this);
}

ActorProxy* ActorProxy::Copy() const { return new ActorProxy(*this); }

bool ActorProxy::EarlyAbortDraw() const {
  return m_pActorTarget == nullptr || Actor::EarlyAbortDraw();
}

void ActorProxy::DrawPrimitives() {
  if (m_pActorTarget == nullptr || m_bDrawingTarget) {
    return;
  }

  Actor* target = m_pActorTarget;
  std::shared_ptr<LifetimeToken> proxyToken = m_pLifetimeToken;
  class DrawingTargetGuard {
   public:
    DrawingTargetGuard(ActorProxy* proxy, std::shared_ptr<LifetimeToken> token)
        : m_pProxy(proxy), m_pProxyToken(token) {}

    ~DrawingTargetGuard() {
      if (m_pProxyToken != nullptr && m_pProxyToken->alive) {
        m_pProxy->m_bDrawingTarget = false;
      }
    }

   private:
    ActorProxy* m_pProxy;
    std::shared_ptr<LifetimeToken> m_pProxyToken;
  };

  m_bDrawingTarget = true;
  DrawingTargetGuard drawingTargetGuard(this, proxyToken);
  TargetVisibilityGuard targetVisibilityGuard(target);
  target->Draw();
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
    WarnActorProxySafety(
        "ActorProxy rejected cyclic target.");
    m_pActorTarget = nullptr;
    return;
  }
  m_pActorTarget = pTarget;
}

void ActorProxy::DetachTargetFromAll(const Actor* pTarget) {
  if (pTarget == nullptr) {
    return;
  }
  MarkActorDestroyed(pTarget);

  std::vector<ActorProxy*> proxies(
      ActorProxyRegistry().begin(), ActorProxyRegistry().end());
  for (ActorProxy* proxy : proxies) {
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
    if (!LuaBinding::CheckLuaObjectType(
            L, 1, Luna<Actor>::m_sClassName.c_str())) {
      LuaHelpers::TypeError(L, 1, Luna<Actor>::m_sClassName.c_str());
    }
    void* rawTarget = nullptr;
    if (!LuaBinding::TryGetPointerFromStack(
            L, Luna<Actor>::m_sClassName, 1, rawTarget)) {
      WarnActorProxySafety(
          "ActorProxy cleared stale Lua target.");
      p->SetTarget(nullptr);
      COMMON_RETURN_SELF;
    }
    Actor* pTarget = static_cast<Actor*>(rawTarget);
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
