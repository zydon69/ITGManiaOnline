#include "AutoActor.h"

#include <memory>
#include <string>
#include <utility>

#include "Actor.h"
#include "ActorFrame.h"
#include "ActorUtil.h"
#include "LuaManager.h"
#include "RageLog.h"
#include "ThemeManager.h"
#include "global.h"

namespace {
void WarnAutoActorAuditFix(const char* message) {
  if (LOG != nullptr) {
    LOG->Warn("%s", message);
  }
}

std::unique_ptr<Actor> MakeFallbackActor() {
  return std::unique_ptr<Actor>(new Actor);
}

std::unique_ptr<Actor> CloneActorOrFallback(const Actor* actor) {
  if (actor == nullptr) {
    return nullptr;
  }

  std::unique_ptr<Actor> copy(actor->Copy());
  if (copy == nullptr) {
    WarnAutoActorAuditFix(
        "SRC_AUDIT_FIX SRC-769: AutoActor copy produced null actor.");
    return MakeFallbackActor();
  }
  return copy;
}

void DetachFromParent(Actor* actor) {
  if (actor == nullptr || actor->GetParent() == nullptr) {
    return;
  }

  Actor* parent = actor->GetParent();
  ActorFrame* parentFrame = dynamic_cast<ActorFrame*>(parent);
  if (parentFrame != nullptr) {
    parentFrame->RemoveChild(actor);
    return;
  }

  WarnAutoActorAuditFix(
      "SRC_AUDIT_FIX SRC-2645: AutoActor detached actor from non-frame parent.");
  actor->SetParent(nullptr);
}
}  // namespace

AutoActor::~AutoActor() {
  Unload();
}

void AutoActor::Unload() {
  if (m_pActor != nullptr) {
    DetachFromParent(m_pActor.get());
  }
  m_pActor.reset();
}

AutoActor::AutoActor(const AutoActor& cpy)
    : m_pActor(CloneActorOrFallback(cpy.m_pActor.get())) {}

AutoActor& AutoActor::operator=(const AutoActor& cpy) {
  if (this == &cpy) {
    return *this;
  }

  AutoActor tmp(cpy);
  std::swap(m_pActor, tmp.m_pActor);
  return *this;
}

AutoActor::AutoActor(AutoActor&& cpy) noexcept
    : m_pActor(std::move(cpy.m_pActor)) {}

AutoActor& AutoActor::operator=(AutoActor&& cpy) noexcept {
  if (this == &cpy) {
    return *this;
  }

  Unload();
  m_pActor = std::move(cpy.m_pActor);
  return *this;
}

void AutoActor::Load(Actor* pActor) {
  if (pActor == m_pActor.get()) {
    return;
  }
  Load(std::unique_ptr<Actor>(pActor));
}

void AutoActor::Load(std::unique_ptr<Actor> pActor) {
  Adopt(std::move(pActor));
}

void AutoActor::Adopt(std::unique_ptr<Actor> pActor) {
  if (pActor == nullptr) {
    WarnAutoActorAuditFix(
        "SRC_AUDIT_FIX SRC-2647: AutoActor replaced null adopted actor.");
    pActor = MakeFallbackActor();
  }

  DetachFromParent(pActor.get());
  Unload();
  m_pActor = std::move(pActor);
}

void AutoActor::LoadFallback() {
  Adopt(MakeFallbackActor());
}

void AutoActor::Load(const std::string& sPath) {
  std::unique_ptr<Actor> actor(ActorUtil::MakeActor(sPath));

  // If a Condition is false, MakeActor will return nullptr.
  if (actor == nullptr) {
    actor = MakeFallbackActor();
  }
  Adopt(std::move(actor));
}

void AutoActor::LoadB(
    const std::string& sMetricsGroup, const std::string& sElement) {
  if (THEME == nullptr || !THEME->IsThemeLoaded()) {
    WarnAutoActorAuditFix(
        "SRC_AUDIT_FIX SRC-2644: AutoActor refused LoadB without loaded THEME.");
    LoadFallback();
    return;
  }
  ThemeManager::PathInfo pi;
  bool b =
      THEME->GetPathInfo(pi, EC_BGANIMATIONS, sMetricsGroup, sElement, true);
  if (!b) {
    WarnAutoActorAuditFix(
        "SRC_AUDIT_FIX SRC-2644: AutoActor replaced missing theme actor.");
    LoadFallback();
    return;
  }
  if (LUA == nullptr) {
    WarnAutoActorAuditFix(
        "SRC_AUDIT_FIX SRC-770: AutoActor loaded theme actor without Lua "
        "thread variables.");
    Load(pi.sResolvedPath);
    return;
  }
  LuaThreadVariable var1("MatchingMetricsGroup", pi.sMatchingMetricsGroup);
  LuaThreadVariable var2("MatchingElement", pi.sMatchingElement);
  Load(pi.sResolvedPath);
}

void AutoActor::LoadActorFromNode(const XNode* pNode, Actor* pParent) {
  std::unique_ptr<Actor> actor(ActorUtil::LoadFromNode(pNode, pParent));
  if (actor == nullptr) {
    WarnAutoActorAuditFix(
        "SRC_AUDIT_FIX SRC-771: AutoActor replaced null node actor.");
    actor = MakeFallbackActor();
  }
  Adopt(std::move(actor));
}

void AutoActor::LoadAndSetName(
    const std::string& sScreenName, const std::string& sActorName) {
  if (THEME == nullptr || !THEME->IsThemeLoaded()) {
    WarnAutoActorAuditFix(
        "SRC_AUDIT_FIX SRC-2644: AutoActor refused named load without loaded THEME.");
    LoadFallback();
  } else {
    std::string path = THEME->GetPathG(sScreenName, sActorName, true);
    if (path.empty()) {
      WarnAutoActorAuditFix(
          "SRC_AUDIT_FIX SRC-2644: AutoActor replaced missing named actor.");
      LoadFallback();
    } else {
      Load(path);
    }
  }
  if (m_pActor == nullptr) {
    WarnAutoActorAuditFix(
        "SRC_AUDIT_FIX SRC-770: AutoActor replaced null named actor.");
    m_pActor = MakeFallbackActor();
  }
  m_pActor->SetName(sActorName);
  if (THEME != nullptr && THEME->IsThemeLoaded()) {
    ActorUtil::LoadAllCommands(*m_pActor, sScreenName);
  }
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
