#include "ScreenUnlockBrowse.h"

#include <set>
#include <string>

#include "ActorUtil.h"
#include "GameCommand.h"
#include "GameState.h"
#include "InputEventPlus.h"
#include "MessageManager.h"
#include "PlayerNumber.h"
#include "ProfileManager.h"
#include "RageLog.h"
#include "RageUtil.h"
#include "Screen.h"
#include "ScreenMessage.h"
#include "ScreenSelectMaster.h"
#include "UnlockManager.h"
#include "global.h"

REGISTER_SCREEN_CLASS(ScreenUnlockBrowse);

namespace {
void WarnScreenUnlockBrowse(const std::string& message) {
  if (LOG != nullptr) {
    LOG->Warn("ScreenUnlockBrowse: %s", message.c_str());
  }
}

bool CanReadUnlockEntryStatuses() {
  return UNLOCKMAN != nullptr && PROFILEMAN != nullptr &&
         PROFILEMAN->GetMachineProfile() != nullptr;
}

UnlockEntryStatus SanitizeUnlockEntryStatus(UnlockEntryStatus status) {
  switch (status) {
    case UnlockEntryStatus_RequrementsNotMet:
    case UnlockEntryStatus_RequirementsMet:
    case UnlockEntryStatus_Unlocked:
      return status;
    default:
      WarnScreenUnlockBrowse(
          ssprintf("Ignoring invalid UnlockEntryStatus: %i", status));
      return UnlockEntryStatus_RequrementsNotMet;
  }
}

UnlockEntryStatus GetUnlockEntryStatusOrLocked(
    const UnlockEntry& entry, bool canReadStatuses) {
  if (!canReadStatuses) {
    return UnlockEntryStatus_RequrementsNotMet;
  }

  return SanitizeUnlockEntryStatus(entry.GetUnlockEntryStatus());
}

std::string MakeUnlockChoiceName(
    const UnlockEntry& entry, int index, std::set<std::string>& usedNames) {
  std::string choiceName =
      entry.m_sEntryID.empty() ? ssprintf("Unlock%d", index) : entry.m_sEntryID;
  MakeValidFilename(choiceName);

  if (choiceName.empty()) {
    choiceName = ssprintf("Unlock%d", index);
  }

  const std::string baseName = choiceName;
  int suffix = 2;
  while (usedNames.find(choiceName) != usedNames.end()) {
    choiceName = ssprintf("%s_%d", baseName.c_str(), suffix++);
  }

  usedNames.insert(choiceName);
  return choiceName;
}

bool IsUnlockedOrReady(UnlockEntryStatus status) {
  return status == UnlockEntryStatus_RequirementsMet ||
         status == UnlockEntryStatus_Unlocked;
}
}  // namespace

void ScreenUnlockBrowse::Init() {
  m_aGameCommands.clear();
  m_vUnlockEntryStatus.clear();

  if (UNLOCKMAN == nullptr) {
    WarnScreenUnlockBrowse("Cannot build unlock list without UNLOCKMAN.");
  }

  // fill m_aGameCommands before calling Init()
  const std::vector<UnlockEntry>* unlockEntries =
      UNLOCKMAN != nullptr ? &UNLOCKMAN->m_UnlockEntries : nullptr;
  const bool canReadStatuses = CanReadUnlockEntryStatuses();
  if (unlockEntries != nullptr && !canReadStatuses) {
    WarnScreenUnlockBrowse(
        "Cannot read unlock status because unlock/profile managers are not "
        "available.");
  }

  int index = 0;
  std::set<std::string> usedChoiceNames;
  if (unlockEntries != nullptr) {
    m_vUnlockEntryStatus.reserve(unlockEntries->size());
    for (const UnlockEntry& ue : *unlockEntries) {
      GameCommand gc;
      const UnlockEntryStatus status =
          GetUnlockEntryStatusOrLocked(ue, canReadStatuses);
      if (IsUnlockedOrReady(status)) {
        gc.m_bInvalid = false;
      }
      gc.m_iIndex = index++;
      gc.m_sName = MakeUnlockChoiceName(ue, gc.m_iIndex, usedChoiceNames);

      m_aGameCommands.push_back(gc);
      m_vUnlockEntryStatus.push_back(status);
    }
  }

  ScreenSelectMaster::Init();

  m_banner.SetName("Banner");
  LOAD_ALL_COMMANDS_AND_SET_XY(m_banner);
  this->AddChild(&m_banner);

  if (MESSAGEMAN != nullptr) {
    this->SubscribeToMessage(Message_MenuSelectionChanged);
  } else {
    WarnScreenUnlockBrowse("Cannot subscribe to menu selection changes.");
  }
}

void ScreenUnlockBrowse::BeginScreen() {
  ScreenSelectMaster::BeginScreen();

  UpdateBannerForCurrentSelection();
}

bool ScreenUnlockBrowse::MenuStart(const InputEventPlus& input) {
  if (input.type != IET_FIRST_PRESS || IsTransitioning()) {
    return false;
  }

  const PlayerNumber pn = GetSelectionPlayer(input.pn);
  if (!IsValidPlayer(pn) || m_bChosen[pn] || !AnyOptionsArePlayable()) {
    return false;
  }

  const int selection = GetSelectionIndex(pn);
  if (!IsPlayableUnlockSelection(selection)) {
    return false;
  }

  FOREACH_PlayerNumber(p) {
    if (IsValidPlayer(p)) {
      m_bChosen[p] = true;
    }
  }

  if (m_soundStart.IsLoaded()) {
    m_soundStart.PlayCopy(true);
  }
  this->PostScreenMessage(SM_BeginFadingOut, 0);
  return true;
}

void ScreenUnlockBrowse::HandleMessage(const Message& msg) {
  ScreenSelectMaster::HandleMessage(msg);

  if (msg == Message_MenuSelectionChanged) {
    UpdateBannerForCurrentSelection();
  }
}

PlayerNumber ScreenUnlockBrowse::GetSelectionPlayer(PlayerNumber fallback) const {
  if (IsValidPlayer(fallback)) {
    return fallback;
  }

  if (GAMESTATE != nullptr) {
    const PlayerNumber master = GAMESTATE->GetMasterPlayerNumber();
    if (IsValidPlayer(master)) {
      return master;
    }

    FOREACH_HumanPlayer(pn) {
      if (IsValidPlayer(pn)) {
        return pn;
      }
    }
  }

  return PLAYER_1;
}

const UnlockEntry* ScreenUnlockBrowse::GetUnlockEntryForSelection(
    int selection) const {
  if (UNLOCKMAN == nullptr || selection < 0 ||
      selection >= static_cast<int>(UNLOCKMAN->m_UnlockEntries.size())) {
    return nullptr;
  }

  return &UNLOCKMAN->m_UnlockEntries[selection];
}

bool ScreenUnlockBrowse::IsPlayableUnlockSelection(int selection) const {
  if (!IsValidChoice(selection) ||
      selection >= static_cast<int>(m_vUnlockEntryStatus.size())) {
    return false;
  }

  const UnlockEntryStatus status =
      SanitizeUnlockEntryStatus(
          static_cast<UnlockEntryStatus>(m_vUnlockEntryStatus[selection]));
  return m_aGameCommands[selection].IsPlayable() && IsUnlockedOrReady(status);
}

void ScreenUnlockBrowse::UpdateBannerForCurrentSelection() {
  const PlayerNumber selectionPlayer = GetSelectionPlayer(PLAYER_INVALID);
  const int selection = GetSelectionIndex(selectionPlayer);
  const UnlockEntry* entry = GetUnlockEntryForSelection(selection);
  if (entry == nullptr || selection < 0 ||
      selection >= static_cast<int>(m_vUnlockEntryStatus.size())) {
    m_banner.LoadFallback();
    return;
  }

  const UnlockEntryStatus status =
      SanitizeUnlockEntryStatus(
          static_cast<UnlockEntryStatus>(m_vUnlockEntryStatus[selection]));
  if (!IsUnlockedOrReady(status) || !entry->IsValid()) {
    m_banner.LoadFallback();
    return;
  }

  m_banner.LoadBannerFromUnlockEntry(entry);
}

/*
 * (c) 2006 Chris Danford
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
