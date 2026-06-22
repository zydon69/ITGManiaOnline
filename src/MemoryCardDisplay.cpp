#include "MemoryCardDisplay.h"

#include <string>

#include "ActorFrame.h"
#include "ActorUtil.h"
#include "GameConstantsAndTypes.h"
#include "LuaManager.h"
#include "MemoryCardManager.h"
#include "PlayerNumber.h"
#include "RageLog.h"
#include "RageUtil.h"
#include "ThemeManager.h"
#include "XmlFile.h"

REGISTER_ACTOR_CLASS(MemoryCardDisplay);

static bool IsValidMemoryCardDisplayPlayer(PlayerNumber pn) {
  return pn >= 0 && pn < NUM_PLAYERS;
}

static bool IsVisibleMemoryCardState(MemoryCardState state) {
  return state >= 0 && state < NUM_MemoryCardState;
}

static void WarnMemoryCardDisplay(const char* message) {
  if (LOG != nullptr) {
    LOG->Warn("%s", message);
  }
}

MemoryCardDisplay::MemoryCardDisplay() {
  m_PlayerNumber = PLAYER_INVALID;
  m_LastSeenState = MemoryCardState_Invalid;
}

MemoryCardDisplay::MemoryCardDisplay(const MemoryCardDisplay& cpy)
    : ActorFrame(cpy),
      m_PlayerNumber(cpy.m_PlayerNumber),
      m_LastSeenState(cpy.m_LastSeenState) {
  RemoveAllChildren();
  for (int i = 0; i < NUM_MemoryCardState; ++i) {
    m_spr[i] = cpy.m_spr[i];
    AddChild(&m_spr[i]);
  }
}

void MemoryCardDisplay::DetachSprites() {
  for (int i = 0; i < NUM_MemoryCardState; ++i) {
    RemoveChild(&m_spr[i]);
  }
}

void MemoryCardDisplay::Load(PlayerNumber pn) {
  DetachSprites();
  m_LastSeenState = MemoryCardState_Invalid;

  if (!IsValidMemoryCardDisplayPlayer(pn)) {
    WarnMemoryCardDisplay(
        "SRC_AUDIT_FIX SRC-1207: MemoryCardDisplay ignored invalid player.");
    m_PlayerNumber = PLAYER_INVALID;
    return;
  }

  m_PlayerNumber = pn;

  for (int i = 0; i < NUM_MemoryCardState; i++) {
    MemoryCardState mcs = (MemoryCardState)i;
    std::string sState = MemoryCardStateToString(mcs);
    if (THEME != nullptr) {
      m_spr[i].Load(THEME->GetPathG(
          "MemoryCardDisplay", ssprintf("%s p%d", sState.c_str(), pn + 1)));
    } else {
      WarnMemoryCardDisplay(
          "SRC_AUDIT_FIX SRC-1208: MemoryCardDisplay loaded without THEME.");
    }
    m_spr[i].SetVisible(false);
    this->AddChild(&m_spr[i]);
  }
}

void MemoryCardDisplay::LoadFromNode(const XNode* pNode) {
  if (pNode == nullptr) {
    WarnMemoryCardDisplay(
        "SRC_AUDIT_FIX SRC-1207: MemoryCardDisplay ignored null XML node.");
    return;
  }
  if (LUA == nullptr) {
    WarnMemoryCardDisplay(
        "SRC_AUDIT_FIX SRC-1209: MemoryCardDisplay ignored XML without LUA.");
    return;
  }

  Lua* L = LUA->Get();
  pNode->PushAttrValue(L, "PlayerNumber");
  PlayerNumber pn;
  LuaHelpers::Pop(L, pn);
  LUA->Release(L);

  Load(pn);

  ActorFrame::LoadFromNode(pNode);
}

void MemoryCardDisplay::Update(float fDelta) {
  if (!IsValidMemoryCardDisplayPlayer(m_PlayerNumber) || MEMCARDMAN == nullptr) {
    ActorFrame::Update(fDelta);
    return;
  }
  MemoryCardState newMcs = MEMCARDMAN->GetCardState(m_PlayerNumber);
  if (m_LastSeenState != newMcs) {
    if (IsVisibleMemoryCardState(m_LastSeenState)) {
      m_spr[m_LastSeenState].SetVisible(false);
    }
    m_LastSeenState = newMcs;
    if (IsVisibleMemoryCardState(m_LastSeenState)) {
      m_spr[m_LastSeenState].SetVisible(true);
    }
  }

  ActorFrame::Update(fDelta);
}

/*
 * (c) 2003 Chris Danford
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
