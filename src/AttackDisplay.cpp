#include "AttackDisplay.h"

#include <cctype>
#include <map>
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

bool AttackDisplayThemeIsReady() {
  return THEME != nullptr && THEME->IsThemeLoaded();
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

std::string GetAttackPieceName(const std::string& sAttack) {
  const std::string token = GetSafeAttackToken(sAttack);
  if (token.empty()) {
    return std::string();
  }
  std::string ret = ssprintf("attack %s", token.c_str());

  /* 1.5x -> 1_5x.  If we pass a period to THEME->GetPathTo, it'll think
   * we're looking for a specific file and not search. */
  Replace(ret, ".", "_");

  return ret;
}

std::string GetAttackCommandName(const std::string& sAttack, PlayerNumber pn) {
  const std::string token = GetSafeAttackToken(sAttack);
  if (token.empty() || !IsValidAttackDisplayPlayer(pn)) {
    return std::string();
  }
  return ssprintf("%sP%iOnCommand", token.c_str(), pn + 1);
}

bool CanRunAttackDisplayCommand(const std::string& commandName) {
  return !commandName.empty() && AttackDisplayThemeIsReady() && LUA != nullptr &&
         THEME->HasMetric("AttackDisplay", commandName);
}
}  // namespace

AttackDisplay::AttackDisplay()
    : m_pPlayerState(nullptr), m_bAttackVisible(false) {
  m_sprAttack.SetDiffuseAlpha(0);  // invisible
  this->AddChild(&m_sprAttack);
}

AttackDisplay::AttackDisplay(const AttackDisplay& cpy)
    : ActorFrame(cpy),
      m_pPlayerState(nullptr),
      m_sprAttack(cpy.m_sprAttack),
      m_bAttackVisible(false) {
  m_sprAttack.StopTweening();
  m_sprAttack.SetDiffuseAlpha(0);
  this->AddChild(&m_sprAttack);
}

void AttackDisplay::Init(const PlayerState* pPlayerState) {
  m_pPlayerState = pPlayerState;
  ResetPreloadedAttacks();
  HideAttack();
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
  if (!AttackDisplayThemeIsReady()) {
    WarnAttackDisplay(
        "SRC_AUDIT_FIX SRC-1237: AttackDisplay skipped preload without loaded "
        "theme manager.");
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

  std::map<std::string, std::string> pieceNameOwners;
  std::set<std::string> ambiguousAttacks;
  for (const std::string& attack : attacks) {
    const std::string pieceName = GetAttackPieceName(attack);
    if (pieceName.empty()) {
      WarnAttackDisplay(
          "SRC_AUDIT_FIX: AttackDisplay skipped attack with empty display "
          "token.");
      continue;
    }
    auto inserted = pieceNameOwners.insert(std::make_pair(pieceName, attack));
    if (!inserted.second && inserted.first->second != attack) {
      ambiguousAttacks.insert(inserted.first->second);
      ambiguousAttacks.insert(attack);
    }
  }

  for (const std::string& attack : attacks) {
    if (ambiguousAttacks.find(attack) != ambiguousAttacks.end()) {
      WarnAttackDisplay(
          "SRC_AUDIT_FIX: AttackDisplay skipped ambiguous attack asset token.");
      continue;
    }

    const std::string pieceName = GetAttackPieceName(attack);
    if (pieceName.empty()) {
      continue;
    }
    const std::string path = THEME->GetPathG("AttackDisplay", pieceName, true);
    if (path == "") {
      TraceAttackDisplayMissingAsset(pieceName);
      continue;
    }

    m_TexturePreload.Load(path);
    m_PreloadedAttackPathsByModifier[attack] = path;
  }
}

void AttackDisplay::Update(float fDelta) {
  ActorFrame::Update(fDelta);

  if (GAMESTATE == nullptr || m_pPlayerState == nullptr ||
      (GAMESTATE->m_PlayMode != PLAY_MODE_BATTLE &&
       GAMESTATE->m_PlayMode != PLAY_MODE_RAVE)) {
    return;
  }

  if (!m_pPlayerState->m_bAttackBeganThisUpdate && !m_bAttackVisible) {
    return;
  }

  std::string activeAttack;
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

    activeAttack = attack.sModifiers;
    break;
  }
  if (activeAttack.empty()) {
    HideAttack();
    return;
  }
  if (m_pPlayerState->m_bAttackBeganThisUpdate ||
      activeAttack != m_sDisplayedAttack) {
    SetAttack(activeAttack);
  }
}

void AttackDisplay::SetAttack(const std::string& sText) {
  if (sText.empty() || m_pPlayerState == nullptr) {
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

  const auto preloaded = m_PreloadedAttackPathsByModifier.find(sText);
  if (preloaded == m_PreloadedAttackPathsByModifier.end()) {
    WarnAttackDisplay(
        "SRC_AUDIT_FIX SRC-1242: AttackDisplay skipped non-preloaded dynamic "
        "attack asset.");
    HideAttack();
    return;
  }

  m_sprAttack.StopTweening();
  const std::string& path = preloaded->second;
  m_sprAttack.SetDiffuseAlpha(1);
  if (m_sprAttack.GetTexturePath() != path) {
    m_sprAttack.Load(path);
  }
  m_sDisplayedAttack = sText;
  m_bAttackVisible = true;

  const std::string commandName = GetAttackCommandName(sText, pn);
  if (CanRunAttackDisplayCommand(commandName)) {
    m_sprAttack.RunCommands(THEME->GetMetricA("AttackDisplay", commandName));
  }
}

void AttackDisplay::HideAttack() {
  m_sprAttack.StopTweening();
  m_sprAttack.SetDiffuseAlpha(0);
  m_sDisplayedAttack.clear();
  m_bAttackVisible = false;
}

void AttackDisplay::ResetPreloadedAttacks() {
  m_TexturePreload.UnloadAll();
  m_PreloadedAttackPathsByModifier.clear();
}

AttackDisplay* AttackDisplay::Copy() const { return new AttackDisplay(*this); }

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
