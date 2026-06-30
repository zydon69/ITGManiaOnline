#include "Inventory.h"

#include <algorithm>
#include <cmath>

#include <algorithm>
#include <cmath>
#include <string>
#include <vector>

#include "Attack.h"
#include "GameConstantsAndTypes.h"
#include "GameState.h"
#include "PlayerNumber.h"
#include "PlayerOptions.h"
#include "PlayerState.h"
#include "PrefsManager.h"
#include "RageLog.h"
#include "RageSound.h"
#include "RageUtil.h"
#include "RageUtil/RandomNumbers.h"
#include "ScreenManager.h"
#include "Song.h"
#include "SongOptions.h"
#include "StatsManager.h"
#include "ThemeManager.h"
#include "global.h"

void ReloadItems();

struct Item {
  AttackLevel level;
  unsigned int iCombo;
  std::string sModifier;
};
static std::vector<Item> g_Items;

static bool IsValidInventoryPlayer(PlayerNumber pn) {
  return pn >= PLAYER_1 && pn < NUM_PLAYERS;
}

static bool IsValidInventoryAttackLevel(AttackLevel level) {
  return level >= ATTACK_LEVEL_1 && level < NUM_ATTACK_LEVELS;
}

static void WarnInventory(const std::string& message) {
  if (LOG != nullptr) {
    LOG->Warn("%s", message.c_str());
  }
}

static void ClearUseItemSounds(std::vector<RageSound*>& sounds) {
  for (RageSound* sound : sounds) {
    delete sound;
  }
  sounds.clear();
}

static bool InventoryThemeIsReady() {
  return THEME != nullptr && THEME->IsThemeLoaded();
}

static int GetInventoryMetricI(const std::string& metric) {
  if (!InventoryThemeIsReady()) {
    return 0;
  }
  return THEME->GetMetricI("Inventory", metric);
}

static float GetInventoryMetricF(const std::string& metric) {
  if (!InventoryThemeIsReady()) {
    return 0.0f;
  }
  return THEME->GetMetricF("Inventory", metric);
}

static std::string GetInventoryMetric(const std::string& metric) {
  if (!InventoryThemeIsReady()) {
    return std::string();
  }
  return THEME->GetMetric("Inventory", metric);
}

static bool IsValidInventoryModifier(const std::string& modifiers) {
  std::vector<std::string> fragments;
  split(modifiers, ",", fragments, true);
  if (fragments.empty()) {
    return false;
  }

  PlayerOptions playerOptions;
  SongOptions songOptions;
  for (std::string fragment : fragments) {
    Trim(fragment);
    if (fragment.empty()) {
      return false;
    }

    bool valid = false;
    std::string errorDetail;
    valid |= playerOptions.FromOneModString(fragment, errorDetail);
    valid |= songOptions.FromOneModString(fragment, errorDetail);
    if (!valid) {
      return false;
    }
  }
  return true;
}

static int GetSafeNumItemTypes() {
  if (!InventoryThemeIsReady()) {
    WarnInventory("SRC_AUDIT_FIX: Inventory has no loaded theme manager.");
    return 0;
  }
  const float value = GetInventoryMetricF("NumItemTypes");
  if (!std::isfinite(value) || value < 0.0f) {
    WarnInventory(ssprintf(
        "SRC_AUDIT_FIX: Invalid Inventory NumItemTypes %f; using 0.", value));
    return 0;
  }
  return std::clamp(static_cast<int>(std::floor(value)), 0, 128);
}

static float GetSafeItemDurationSeconds(int itemIndex) {
  const float value = GetInventoryMetricF("ItemDurationSeconds");
  if (!std::isfinite(value) || value <= 0.0f) {
    WarnInventory(ssprintf(
        "SRC_AUDIT_FIX: Ignoring inventory item %i with invalid duration %f.",
        itemIndex, value));
    return 0.0f;
  }
  return value;
}

static float GetSafeItemUseRateSeconds() {
  const float value = GetInventoryMetricF("ItemUseRateSeconds");
  return std::isfinite(value) && value > 0.0f ? value : 0.0f;
}

static bool IsMatchingInventoryItem(const Item& item, const Attack& attack) {
  return item.level == attack.level && item.sModifier == attack.sModifiers;
}

void ReloadItems() {
  g_Items.clear();
  for (int i = 0; i < GetSafeNumItemTypes(); i++) {
    Item item;
    item.level =
        static_cast<AttackLevel>(GetInventoryMetricI(ssprintf("Item%dLevel", i + 1)) - 1);
    if (!IsValidInventoryAttackLevel(item.level)) {
      WarnInventory(ssprintf(
          "SRC_AUDIT_FIX: Ignoring inventory item %i with invalid level %i.",
          i, item.level));
      continue;
    }
    const int combo = GetInventoryMetricI(ssprintf("Item%dCombo", i + 1));
    if (combo <= 0) {
      WarnInventory(ssprintf(
          "SRC_AUDIT_FIX: Ignoring inventory item %i with invalid combo %i.", i,
          combo));
      continue;
    }
    item.iCombo = static_cast<unsigned int>(combo);
    item.sModifier = GetInventoryMetric(ssprintf("Item%dEffect", i + 1));
    Trim(item.sModifier);
    if (!IsValidInventoryModifier(item.sModifier)) {
      WarnInventory(ssprintf(
          "SRC_AUDIT_FIX: Ignoring inventory item %i with invalid effect.", i));
      continue;
    }
    g_Items.push_back(item);
  }
}

Inventory::Inventory()
    : m_pPlayerState(nullptr),
      m_iLastSeenCombo(0),
      m_fSecondsUntilCpuUseCheck(0.0f) {
  m_iInventoryItemIndex.fill(-1);
}

Inventory::~Inventory() {
  ClearUseItemSounds(m_vpSoundUseItem);
}

void Inventory::Load(PlayerState* pPlayerState) {
  ClearUseItemSounds(m_vpSoundUseItem);
  m_iInventoryItemIndex.fill(-1);

  m_pPlayerState = pPlayerState;
  m_iLastSeenCombo = 0;
  m_fSecondsUntilCpuUseCheck = 0.0f;
  if (m_pPlayerState == nullptr || GAMESTATE == nullptr ||
      !InventoryThemeIsReady()) {
    WarnInventory("SRC_AUDIT_FIX: Inventory::Load missing required context.");
    return;
  }

  ReloadItems();

  // don't load battle sounds if they're not going to be used
  switch (GAMESTATE->m_PlayMode) {
    case PLAY_MODE_BATTLE: {
      m_soundAcquireItem.Load(THEME->GetPathS("Inventory", "aquire item"));
      for (unsigned i = 0; i < g_Items.size(); i++) {
        RageSound* pSound = new RageSound;
        pSound->Load(
            THEME->GetPathS("Inventory", ssprintf("use item %u", i + 1)));
        m_vpSoundUseItem.push_back(pSound);
      }
      m_soundItemEnding.Load(THEME->GetPathS("Inventory", "item ending"));
      break;
    }
    default:
      break;
  }
}

void Inventory::Update(float fDelta) {
  if (m_pPlayerState == nullptr || GAMESTATE == nullptr || STATSMAN == nullptr ||
      PREFSMAN == nullptr) {
    WarnInventory("SRC_AUDIT_FIX: Inventory::Update missing gameplay context.");
    return;
  }
  PlayerNumber pn = m_pPlayerState->m_PlayerNumber;
  if (!IsValidInventoryPlayer(pn)) {
    WarnInventory(
        ssprintf("SRC_AUDIT_FIX: Inventory::Update invalid player %i.", pn));
    return;
  }
  if (m_pPlayerState->m_bAttackEndedThisUpdate) {
    m_soundItemEnding.Play(false);
  }

  // check to see if they deserve a new item
  if (STATSMAN->m_CurStageStats.m_player[pn].m_iCurCombo != m_iLastSeenCombo) {
    unsigned int iOldCombo = m_iLastSeenCombo;
    m_iLastSeenCombo = STATSMAN->m_CurStageStats.m_player[pn].m_iCurCombo;
    unsigned int iNewCombo = m_iLastSeenCombo;

    for (unsigned i = 0; i < g_Items.size(); i++) {
      bool bEarnedThisItem = false;
      if (PREFSMAN->m_bBreakComboToGetItem) {
        bEarnedThisItem =
            iNewCombo < iOldCombo && iOldCombo >= g_Items[i].iCombo;
      } else {
        bEarnedThisItem =
            iOldCombo < g_Items[i].iCombo && iNewCombo >= g_Items[i].iCombo;
      }

      if (bEarnedThisItem) {
        AwardItem(i);
        break;
      }
    }
  }

  Song* song = GAMESTATE->m_pCurSong;
  if (song == nullptr) {
    WarnInventory("SRC_AUDIT_FIX: Inventory::Update missing current song.");
    return;
  }
  // use items if this player is CPU-controlled
  if (m_pPlayerState->m_PlayerController == PC_CPU &&
      GAMESTATE->m_Position.m_fSongBeat < song->GetLastBeat()) {
    // every 1 seconds, try to use an item
    if (!std::isfinite(fDelta) || fDelta < 0.0f) {
      WarnInventory(
          ssprintf("SRC_AUDIT_FIX: Inventory::Update invalid delta %f.", fDelta));
      return;
    }
    m_fSecondsUntilCpuUseCheck += fDelta;
    if (m_fSecondsUntilCpuUseCheck < 1.0f) {
      return;
    }
    m_fSecondsUntilCpuUseCheck = std::fmod(m_fSecondsUntilCpuUseCheck, 1.0f);

    const float useRate = GetSafeItemUseRateSeconds();
    const float useProbability =
        std::isfinite(useRate) && useRate > 0.0f ? 1.0f / useRate : 0.0f;
    for (int s = 0; s < NUM_INVENTORY_SLOTS; s++) {
      if (!m_pPlayerState->m_Inventory[s].IsBlank()) {
        if (randomf(0, 1) < useProbability) {
          UseItem(s);
        }
      }
    }
  }
}

void Inventory::AwardItem(int iItemIndex) {
  if (m_pPlayerState == nullptr || iItemIndex < 0 ||
      iItemIndex >= static_cast<int>(g_Items.size())) {
    WarnInventory(
        ssprintf("SRC_AUDIT_FIX: Invalid inventory item index %i.", iItemIndex));
    return;
  }
  /* Non-human players are vanity only. They should not affect
   * gameplay by acquiring/launching attacks. */
  if (m_pPlayerState->m_PlayerController != PC_HUMAN) {
    return;
  }

  // search for the first open slot
  int iOpenSlot = -1;

  Attack* pInventory = m_pPlayerState->m_Inventory;  //[NUM_INVENTORY_SLOTS]

  if (pInventory[NUM_INVENTORY_SLOTS / 2].IsBlank()) {
    iOpenSlot = NUM_INVENTORY_SLOTS / 2;
  } else {
    for (int s = 0; s < NUM_INVENTORY_SLOTS; s++) {
      if (pInventory[s].IsBlank()) {
        iOpenSlot = s;
        break;
      }
    }
  }

  if (iOpenSlot != -1) {
    Attack a;
    a.sModifiers = g_Items[iItemIndex].sModifier;
    a.fSecsRemaining = GetSafeItemDurationSeconds(iItemIndex);
    if (a.fSecsRemaining <= 0.0f) {
      return;
    }
    a.level = g_Items[iItemIndex].level;
    pInventory[iOpenSlot] = a;
    m_iInventoryItemIndex[iOpenSlot] = iItemIndex;
    m_soundAcquireItem.Play(false);
  }
  // else not enough room to insert item
}

void Inventory::UseItem(int iSlot) {
  if (m_pPlayerState == nullptr || GAMESTATE == nullptr || iSlot < 0 ||
      iSlot >= NUM_INVENTORY_SLOTS) {
    WarnInventory(ssprintf("SRC_AUDIT_FIX: Invalid inventory slot %i.", iSlot));
    return;
  }
  Attack* pInventory = m_pPlayerState->m_Inventory;  //[NUM_INVENTORY_SLOTS]

  if (pInventory[iSlot].IsBlank()) {
    m_iInventoryItemIndex[iSlot] = -1;
    return;
  }

  PlayerNumber pn = m_pPlayerState->m_PlayerNumber;
  Attack a = pInventory[iSlot];
  if (!IsValidInventoryPlayer(pn) || !IsValidInventoryAttackLevel(a.level)) {
    WarnInventory(ssprintf(
        "SRC_AUDIT_FIX: Inventory item has invalid player/level %i/%i.", pn,
        a.level));
    return;
  }

  PlayerNumber pnToAttack = OPPOSITE_PLAYER[pn];
  if (!IsValidInventoryPlayer(pnToAttack) ||
      GAMESTATE->m_pPlayerState[pnToAttack] == nullptr) {
    WarnInventory(
        ssprintf("SRC_AUDIT_FIX: Inventory item has invalid target %i.",
                 pnToAttack));
    return;
  }

  float fPercentHealthToDrain = (a.level + 1) / 10.f;
  if (!std::isfinite(fPercentHealthToDrain) || fPercentHealthToDrain <= 0.0f) {
    WarnInventory(ssprintf(
        "SRC_AUDIT_FIX: Invalid inventory health drain %f.",
        fPercentHealthToDrain));
    return;
  }

  int itemIndex = m_iInventoryItemIndex[iSlot];
  if (itemIndex < 0 || itemIndex >= static_cast<int>(g_Items.size()) ||
      !IsMatchingInventoryItem(g_Items[itemIndex], a)) {
    itemIndex = -1;
    for (size_t i = 0; i < g_Items.size(); ++i) {
      if (IsMatchingInventoryItem(g_Items[i], a)) {
        itemIndex = static_cast<int>(i);
        break;
      }
    }
  }

  // remove the item only after validating the full target/effect path
  pInventory[iSlot].MakeBlank();
  m_iInventoryItemIndex[iSlot] = -1;
  if (itemIndex >= 0 && itemIndex < static_cast<int>(m_vpSoundUseItem.size()) &&
      m_vpSoundUseItem[itemIndex] != nullptr) {
    m_vpSoundUseItem[itemIndex]->Play(false);
  }

  PlayerState* pPlayerStateToAttack = GAMESTATE->m_pPlayerState[pnToAttack];
  pPlayerStateToAttack->LaunchAttack(a);

  if (!std::isfinite(GAMESTATE->m_fOpponentHealthPercent)) {
    WarnInventory("SRC_AUDIT_FIX: Opponent health was non-finite; resetting.");
    GAMESTATE->m_fOpponentHealthPercent = 1.0f;
  }
  GAMESTATE->m_fOpponentHealthPercent -= fPercentHealthToDrain;
  rage_clamp(GAMESTATE->m_fOpponentHealthPercent, 0.f, 1.f);

  // play announcer sound
  if (SCREENMAN != nullptr) {
    SCREENMAN->SendMessageToTopScreen(
        ssprintf("SM_BattleDamageLevel%d", a.level + 1));
  }
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
