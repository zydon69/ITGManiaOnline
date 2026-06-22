#include "AttackDisplay.h"

#include <cctype>
#include <set>
#include <string>

#include "ActorFrame.h"
#include "Attack.h"
#include "Character.h"
#include "GameConstantsAndTypes.h"
#include "GameState.h"
#include "PlayerNumber.h"
#include "PlayerState.h"
#include "RageLog.h"
#include "RageUtil.h"
#include "StdString.h"
#include "ThemeManager.h"
#include "global.h"

namespace {
bool IsValidAttackDisplayPlayer(PlayerNumber pn) {
  return pn >= PLAYER_1 && pn < NUM_PLAYERS;
}

void WarnAttackDisplay(const char* message) {
  if (LOG != nullptr) {
    LOG->Warn("%s", message);
  }
}

void WarnAttackDisplay(const char* message, int value) {
  if (LOG != nullptr) {
    LOG->Warn(message, value);
  }
}

void TraceAttackDisplayMissingAsset(const std::string& pieceName) {
  if (LOG != nullptr) {
    LOG->Trace("Couldn't find \"%s\"", pieceName.c_str());
  }
}

std::string GetSafeAttackToken(const std::string& attack) {
  std::string ret;
  ret.reserve(attack.size());
  bool lastWasUnderscore = false;
  for (unsigned char c : attack) {
    const bool allowed =
        std::isalnum(c) != 0 || c == ' ' || c == '_' || c == '-';
    const char out = allowed ? static_cast<char>(c) : '_';
    if (out == '_' && lastWasUnderscore) {
      continue;
    }
    ret += out;
    lastWasUnderscore = out == '_';
  }
  while (!ret.empty() && (ret.front() == ' ' || ret.front() == '_')) {
    ret.erase(ret.begin());
  }
  while (!ret.empty() && (ret.back() == ' ' || ret.back() == '_')) {
    ret.pop_back();
  }
  return ret;
}
}  // namespace

std::string GetAttackPieceName(const std::string& sAttack) {
  std::string ret = ssprintf("attack %s", GetSafeAttackToken(sAttack).c_str());

  /* 1.5x -> 1_5x.  If we pass a period to THEME->GetPathTo, it'll think
   * we're looking for a specific file and not search. */
  Replace(ret, ".", "_");

  return ret;
}

AttackDisplay::AttackDisplay() : m_pPlayerState(nullptr) {
  if (GAMESTATE == nullptr ||
      (GAMESTATE->m_PlayMode != PLAY_MODE_BATTLE &&
       GAMESTATE->m_PlayMode != PLAY_MODE_RAVE)) {
    return;
  }

  m_sprAttack.SetDiffuseAlpha(0);  // invisible
  this->AddChild(&m_sprAttack);
}

void AttackDisplay::Init(const PlayerState* pPlayerState) {
  m_pPlayerState = pPlayerState;
  if (m_pPlayerState == nullptr || GAMESTATE == nullptr) {
    WarnAttackDisplay(
        "SRC_AUDIT_FIX SRC-1236: AttackDisplay::Init missing gameplay "
        "context.");
    HideAttack();
    return;
  }

  // TODO: Remove use of PlayerNumber.
  PlayerNumber pn = m_pPlayerState->m_PlayerNumber;
  if (!IsValidAttackDisplayPlayer(pn)) {
    WarnAttackDisplay(
        "SRC_AUDIT_FIX SRC-1236: AttackDisplay::Init invalid player %i.", pn);
    HideAttack();
    return;
  }
  m_sprAttack.SetName(ssprintf("TextP%d", pn + 1));

  if (GAMESTATE->m_PlayMode != PLAY_MODE_BATTLE &&
      GAMESTATE->m_PlayMode != PLAY_MODE_RAVE) {
    return;
  }

  std::set<std::string> attacks;
  for (int al = 0; al < NUM_ATTACK_LEVELS; al++) {
    const Character* ch = GAMESTATE->m_pCurCharacters[pn];
    if (ch == nullptr) {
      WarnAttackDisplay(
          "SRC_AUDIT_FIX SRC-1236: AttackDisplay missing character for player "
          "%i.",
          pn);
      return;
    }
    const std::string* asAttacks = ch->m_sAttacks[al];
    for (int att = 0; att < NUM_ATTACKS_PER_LEVEL; ++att) {
      if (!asAttacks[att].empty()) {
        attacks.insert(asAttacks[att]);
      }
    }
  }

  for (std::set<std::string>::const_iterator it = attacks.begin();
       it != attacks.end(); ++it) {
    if (THEME == nullptr) {
      WarnAttackDisplay(
          "SRC_AUDIT_FIX SRC-1237: AttackDisplay skipped preload without "
          "theme manager.");
      return;
    }

    const std::string pieceName = GetAttackPieceName(*it);
    const std::string path =
        THEME->GetPathG("AttackDisplay", pieceName, true);
    if (path == "") {
      TraceAttackDisplayMissingAsset(pieceName);
      continue;
    }

    m_TexturePreload.Load(path);
    m_PreloadedAttackPaths.insert(path);
  }
}

void AttackDisplay::Update(float fDelta) {
  ActorFrame::Update(fDelta);

  if (GAMESTATE == nullptr || m_pPlayerState == nullptr ||
      (GAMESTATE->m_PlayMode != PLAY_MODE_BATTLE &&
       GAMESTATE->m_PlayMode != PLAY_MODE_RAVE)) {
    return;
  }

  if (!m_pPlayerState->m_bAttackBeganThisUpdate) {
    return;
  }
  // don't handle this again

  for (unsigned s = 0; s < m_pPlayerState->m_ActiveAttacks.size(); s++) {
    const Attack& attack = m_pPlayerState->m_ActiveAttacks[s];

    if (!std::isfinite(attack.fStartSecond) ||
        !std::isfinite(attack.fSecsRemaining)) {
      WarnAttackDisplay(
          "SRC_AUDIT_FIX SRC-1236: Ignoring non-finite displayed attack.");
      continue;
    }

    if (attack.fStartSecond >= 0) {
      continue; /* hasn't started yet */
    }

    if (attack.fSecsRemaining <= 0) {
      continue; /* ended already */
    }

    if (attack.IsBlank()) {
      continue;
    }

    SetAttack(attack.sModifiers);
    break;
  }
}

void AttackDisplay::SetAttack(const std::string& sText) {
  if (sText.empty() || THEME == nullptr || m_pPlayerState == nullptr) {
    HideAttack();
    return;
  }

  // TODO: Remove use of PlayerNumber.
  PlayerNumber pn = m_pPlayerState->m_PlayerNumber;
  if (!IsValidAttackDisplayPlayer(pn)) {
    WarnAttackDisplay(
        "SRC_AUDIT_FIX SRC-1239: AttackDisplay::SetAttack invalid player %i.",
        pn);
    HideAttack();
    return;
  }

  const std::string pieceName = GetAttackPieceName(sText);
  const std::string path = THEME->GetPathG("AttackDisplay", pieceName, true);
  if (path == "") {
    TraceAttackDisplayMissingAsset(pieceName);
    HideAttack();
    return;
  }

  if (m_PreloadedAttackPaths.find(path) == m_PreloadedAttackPaths.end()) {
    WarnAttackDisplay(
        "SRC_AUDIT_FIX SRC-1242: AttackDisplay skipped non-preloaded dynamic "
        "attack asset.");
    HideAttack();
    return;
  }

  m_sprAttack.SetDiffuseAlpha(1);
  if (m_sprAttack.GetTexturePath() != path) {
    m_sprAttack.Load(path);
  }

  const std::string sName =
      ssprintf("%sP%i", GetSafeAttackToken(sText).c_str(), pn + 1);
  m_sprAttack.RunCommands(
      THEME->GetMetricA("AttackDisplay", sName + "OnCommand"));
}

void AttackDisplay::HideAttack() { m_sprAttack.SetDiffuseAlpha(0); }

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
