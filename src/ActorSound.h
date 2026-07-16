#ifndef ACTOR_SOUND_H
#define ACTOR_SOUND_H

#include <string>

#include "Actor.h"
#include "RageSound.h"
/** @brief RageSound Actor interface. */
class ActorSound : public Actor {
 public:
  ActorSound();
  ~ActorSound() override = default;
  ActorSound* Copy() const override;

  bool Load(const std::string& sPath);
  bool Load(
      const std::string& sPath, const RageSoundLoadParams& params,
      bool bPrecache);
  void Play();
  void Pause(bool bPause);
  void Stop();
  void LoadFromNode(const XNode* pNode) override;
  bool IsSoundLoaded() const { return m_bSoundLoaded; }
  void PushSound(lua_State* L) { m_Sound.PushSelf(L); }
  void SetIsAction(bool bIsAction) { m_bIsAction = bIsAction; }
  bool GetIsAction() const { return m_bIsAction; }
  RageSoundLoadParams GetSoundLoadParams() const { return m_LoadParams; }
  bool GetPrecache() const { return m_bPrecache; }

  //
  // Lua
  //
  void PushSelf(lua_State* L) override;

 private:
  void ResetLoadedSound();
  bool LoadResolvedPath(
      const std::string& sResolvedPath, const RageSoundLoadParams& params,
      bool bPrecache);

  bool m_bIsAction;
  bool m_bSoundLoaded;
  bool m_bPrecache;
  RageSoundLoadParams m_LoadParams;
  RageSound m_Sound;
};

#endif

/**
 * @file
 * @author Glenn Maynard (c) 2005
 * @section LICENSE
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
