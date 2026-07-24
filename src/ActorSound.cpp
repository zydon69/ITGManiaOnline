#include "ActorSound.h"

#include <string>

#include "Actor.h"
#include "ActorUtil.h"
#include "LuaManager.h"
#include "RageLog.h"
#include "RageSound.h"
#include "XmlFile.h"

REGISTER_ACTOR_CLASS_WITH_NAME(ActorSound, Sound);

namespace {
void WarnActorSoundSafety(const std::string& message) {
  if (LOG != nullptr) {
    LOG->Warn("%s", message.c_str());
  }
}

int AbsoluteLuaIndex(lua_State* L, int index) {
  return index < 0 ? lua_gettop(L) + index + 1 : index;
}

void ReadOptionalBoolField(
    lua_State* L, int tableIndex, const char* fieldName, bool& valueOut) {
  tableIndex = AbsoluteLuaIndex(L, tableIndex);
  lua_getfield(L, tableIndex, fieldName);
  if (!lua_isnil(L, -1)) {
    valueOut = lua_toboolean(L, -1) != 0;
  }
  lua_pop(L, 1);
}
}  // namespace

ActorSound::ActorSound()
    : m_bIsAction(false), m_bSoundLoaded(false), m_bPrecache(true) {}

void ActorSound::ResetLoadedSound() {
  m_Sound.Unload();
  m_bSoundLoaded = false;
}

bool ActorSound::LoadResolvedPath(
    const std::string& sResolvedPath, const RageSoundLoadParams& params,
    bool bPrecache) {
  RageSound nextSound;
  if (!nextSound.Load(sResolvedPath, bPrecache, &params)) {
    WarnActorSoundSafety(
        "ActorSound rejected failed sound load '" +
        sResolvedPath + "': " + nextSound.GetError());
    ResetLoadedSound();
    return false;
  }

  m_Sound = nextSound;
  m_bSoundLoaded = true;
  return true;
}

bool ActorSound::Load(const std::string& sPath) {
  return Load(sPath, m_LoadParams, m_bPrecache);
}

bool ActorSound::Load(
    const std::string& sPath, const RageSoundLoadParams& params,
    bool bPrecache) {
  m_LoadParams = params;
  m_bPrecache = bPrecache;

  std::string resolvedPath = sPath;
  if (!ActorUtil::ResolvePath(resolvedPath, "ActorSound:load", true)) {
    WarnActorSoundSafety(
        "ActorSound cleared unresolved sound path.");
    ResetLoadedSound();
    return false;
  }
  return LoadResolvedPath(resolvedPath, params, bPrecache);
}

void ActorSound::Play() {
  if (!m_bSoundLoaded) {
    WarnActorSoundSafety(
        "ActorSound ignored play before load.");
    return;
  }
  m_Sound.Play(m_bIsAction);
}

void ActorSound::Pause(bool bPause) {
  if (!m_bSoundLoaded) {
    WarnActorSoundSafety(
        "ActorSound ignored pause before load.");
    return;
  }
  m_Sound.Pause(bPause);
}

void ActorSound::Stop() {
  if (!m_bSoundLoaded) {
    return;
  }
  m_Sound.Stop();
}

void ActorSound::LoadFromNode(const XNode* pNode) {
  if (pNode == nullptr) {
    WarnActorSoundSafety(
        "ActorSound cleared null XML node.");
    ResetLoadedSound();
    return;
  }
  RageSoundLoadParams params;
  pNode->GetAttrValue("SupportPan", params.m_bSupportPan);
  pNode->GetAttrValue("SupportRateChanging", params.m_bSupportRateChanging);
  bool bIsAction = false;
  pNode->GetAttrValue("IsAction", bIsAction);

  bool bPrecache = true;
  pNode->GetAttrValue("Precache", bPrecache);

  m_LoadParams = params;
  m_bPrecache = bPrecache;
  SetIsAction(bIsAction);

  std::string sFile;
  if (ActorUtil::GetAttrPath(pNode, "File", sFile)) {
    LoadResolvedPath(sFile, params, bPrecache);
  } else {
    WarnActorSoundSafety(
        "ActorSound cleared XML node without File.");
    ResetLoadedSound();
  }

  Actor::LoadFromNode(pNode);
}

// lua start
#include "LuaBinding.h"

/** @brief Allow Lua to have access to the ActorSound. */
class LunaActorSound : public Luna<ActorSound> {
 public:
  static int load(T* p, lua_State* L) {
    RageSoundLoadParams params = p->GetSoundLoadParams();
    bool bPrecache = p->GetPrecache();
    bool bIsAction = p->GetIsAction();
    if (lua_istable(L, 2)) {
      ReadOptionalBoolField(L, 2, "SupportPan", params.m_bSupportPan);
      ReadOptionalBoolField(
          L, 2, "SupportRateChanging", params.m_bSupportRateChanging);
      ReadOptionalBoolField(L, 2, "Precache", bPrecache);
      ReadOptionalBoolField(L, 2, "IsAction", bIsAction);
    }
    p->SetIsAction(bIsAction);
    p->Load(SArg(1), params, bPrecache);
    COMMON_RETURN_SELF;
  }
  static int play(T* p, lua_State* L) {
    p->Play();
    COMMON_RETURN_SELF;
  }
  static int pause(T* p, lua_State* L) {
    p->Pause(BArg(1));
    COMMON_RETURN_SELF;
  }
  static int stop(T* p, lua_State* L) {
    p->Stop();
    COMMON_RETURN_SELF;
  }
  static int get(T* p, lua_State* L) {
    p->PushSound(L);
    return 1;
  }
  static int set_is_action(T* p, lua_State* L) {
    p->SetIsAction(BArg(1));
    COMMON_RETURN_SELF;
  }
  DEFINE_METHOD(get_is_action, GetIsAction());

  LunaActorSound() {
    ADD_METHOD(load);
    ADD_METHOD(play);
    ADD_METHOD(pause);
    ADD_METHOD(stop);
    ADD_METHOD(get);
    ADD_GET_SET_METHODS(is_action);
  }
};

LUA_REGISTER_DERIVED_CLASS(ActorSound, Actor)
// lua end

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
