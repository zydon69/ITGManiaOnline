#ifndef AttackDisplay_H
#define AttackDisplay_H

#include <map>
#include <set>
#include <string>

#include "ActorFrame.h"
#include "RageTexturePreloader.h"
#include "Sprite.h"

class PlayerState;
/** @brief A graphical display for attacks. */
class AttackDisplay : public ActorFrame {
 public:
  AttackDisplay();
  AttackDisplay(const AttackDisplay& cpy);

  void Init(const PlayerState* pPlayerState);
  void SetAttack(const std::string& mod);

  void Update(float fDelta) override;
  AttackDisplay* Copy() const override;

 protected:
  void HideAttack();
  void ResetPreloadedAttacks();

  const PlayerState* m_pPlayerState;

  Sprite m_sprAttack;

  RageTexturePreloader m_TexturePreload;
  std::map<std::string, std::string> m_PreloadedAttackPathsByModifier;
  std::string m_sDisplayedAttack;
  bool m_bAttackVisible;
};

#endif

/**
 * @file
 * @author Chris Danford (c) 2003
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
