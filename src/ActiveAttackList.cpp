#include "ActiveAttackList.h"

#include <cstddef>
#include <string>
#include <vector>

#include "Attack.h"
#include "BitmapText.h"
#include "PlayerOptions.h"
#include "PlayerState.h"
#include "RageLog.h"
#include "RageUtil.h"
#include "ThemeManager.h"
#include "global.h"

namespace {
const size_t MAX_ATTACK_LIST_MODIFIER_CHARS = 2048;
const size_t MAX_ATTACK_LIST_PARSE_ITEMS = 256;
const size_t MAX_ATTACK_LIST_DISPLAY_CHARS = 2048;
const size_t MAX_ATTACK_LIST_DISPLAY_ITEMS = 64;

void WarnActiveAttackList(const char* message) {
  if (LOG != nullptr) {
    LOG->Warn("%s", message);
  }
}

void AppendBoundedAttackMods(
    std::vector<std::string>& dest, const std::vector<std::string>& source) {
  for (const std::string& mod : source) {
    if (dest.size() >= MAX_ATTACK_LIST_DISPLAY_ITEMS) {
      return;
    }
    dest.push_back(mod.substr(0, MAX_ATTACK_LIST_DISPLAY_CHARS));
  }
}

std::string JoinBoundedAttackMods(const std::vector<std::string>& mods) {
  std::string joined;
  for (const std::string& mod : mods) {
    const size_t separatorChars = joined.empty() ? 0 : 1;
    if (joined.size() + separatorChars >= MAX_ATTACK_LIST_DISPLAY_CHARS) {
      break;
    }
    if (!joined.empty()) {
      joined += "\n";
    }
    const size_t remaining = MAX_ATTACK_LIST_DISPLAY_CHARS - joined.size();
    joined += mod.substr(0, remaining);
  }
  return joined;
}

unsigned int GetThemeMetricGenerationForAttackList() {
  return THEME == nullptr ? 0 : THEME->GetMetricGeneration();
}
}  // namespace

ActiveAttackList::ActiveAttackList()
    : m_iLastRenderedAttackRevision(0),
      m_iLastRenderedThemeMetricGeneration(0),
      m_pPlayerState(nullptr) {}

ActiveAttackList::ActiveAttackList(const ActiveAttackList& cpy)
    : BitmapText(cpy),
      m_iLastRenderedAttackRevision(0),
      m_iLastRenderedThemeMetricGeneration(0),
      m_pPlayerState(nullptr) {
  ClearRenderedAttackText();
}

void ActiveAttackList::Init(const PlayerState* pPlayerState) {
  m_pPlayerState = pPlayerState;
  if (m_pPlayerState == nullptr) {
    WarnActiveAttackList(
        "SRC_AUDIT_FIX SRC-1231: ActiveAttackList initialized without player "
        "state.");
    ClearRenderedAttackText();
  }
}

void ActiveAttackList::Update(float fDelta) {
  if (m_pPlayerState == nullptr) {
    BitmapText::Update(fDelta);
    if (IsFirstUpdate()) {
      ClearRenderedAttackText();
    }
    return;
  }

  const unsigned int attackRevision =
      m_pPlayerState->GetActiveAttackListRevision();
  const unsigned int themeMetricGeneration =
      GetThemeMetricGenerationForAttackList();
  bool bTimeToRefresh =
      IsFirstUpdate() ||  // check this before running Actor::Update()
      m_pPlayerState->m_bAttackBeganThisUpdate ||
      m_pPlayerState->m_bAttackEndedThisUpdate ||
      attackRevision != m_iLastRenderedAttackRevision ||
      themeMetricGeneration != m_iLastRenderedThemeMetricGeneration;

  BitmapText::Update(fDelta);

  if (bTimeToRefresh) {
    Refresh();
  }
}

void ActiveAttackList::Refresh() {
  if (m_pPlayerState == nullptr) {
    m_iLastRenderedAttackRevision = 0;
    m_iLastRenderedThemeMetricGeneration =
        GetThemeMetricGenerationForAttackList();
    ClearRenderedAttackText();
    return;
  }

  const AttackArray& attacks = m_pPlayerState->m_ActiveAttacks;

  std::vector<std::string> vsThemedMods;
  size_t parsedAttackItems = 0;
  for (size_t i = 0; i < attacks.size(); i++) {
    const Attack& attack = attacks[i];

    if (!attack.bOn) {
      continue;  // hasn't started yet
    }
    if (!attack.bShowInAttackList) {
      continue;
    }
    if (parsedAttackItems >= MAX_ATTACK_LIST_PARSE_ITEMS) {
      WarnActiveAttackList(
          "SRC_AUDIT_FIX SRC-2605: ActiveAttackList truncated attack modifier "
          "parsing.");
      break;
    }
    ++parsedAttackItems;

    PlayerOptions po;
    if (attack.sModifiers.size() > MAX_ATTACK_LIST_MODIFIER_CHARS) {
      WarnActiveAttackList(
          "SRC_AUDIT_FIX SRC-1234: ActiveAttackList skipped oversized attack "
          "modifiers.");
      continue;
    }

    std::vector<std::string> attackMods;
    po.FromString(attack.sModifiers);
    po.GetLocalizedMods(attackMods);
    AppendBoundedAttackMods(vsThemedMods, attackMods);
    if (vsThemedMods.size() >= MAX_ATTACK_LIST_DISPLAY_ITEMS) {
      WarnActiveAttackList(
          "SRC_AUDIT_FIX SRC-1234: ActiveAttackList truncated displayed "
          "attack modifiers.");
      break;
    }
  }

  std::string s = JoinBoundedAttackMods(vsThemedMods);

  this->SetText(s);  // BitmapText will not rebuild vertices if these strings
                     // are the same.
  m_iLastRenderedAttackRevision =
      m_pPlayerState->GetActiveAttackListRevision();
  m_iLastRenderedThemeMetricGeneration =
      GetThemeMetricGenerationForAttackList();
}

ActiveAttackList* ActiveAttackList::Copy() const {
  return new ActiveAttackList(*this);
}

void ActiveAttackList::ClearRenderedAttackText() {
  if (m_pFont != nullptr) {
    SetText("");
    return;
  }

  m_sText.clear();
  m_wTextLines.clear();
  m_iLineWidths.clear();
  m_aVertices.clear();
  m_vpFontPageTextures.clear();
  ClearAttributes();
  SetWidth(0.0f);
  SetHeight(0.0f);
}

/*
 * (c) 2004 Chris Danford
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
