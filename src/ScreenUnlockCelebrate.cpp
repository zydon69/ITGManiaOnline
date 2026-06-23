#include "ScreenUnlockCelebrate.h"

#include "Course.h"
#include "GameState.h"
#include "InputEventPlus.h"
#include "LuaManager.h"
#include "Profile.h"
#include "ProfileManager.h"
#include "RageLog.h"
#include "Screen.h"
#include "ScreenUnlockBrowse.h"
#include "Song.h"
#include "SongManager.h"
#include "UnlockManager.h"
#include "global.h"

REGISTER_SCREEN_CLASS(ScreenUnlockCelebrate);

static int g_iUnlockEntryIndexToCelebrate = -1;

LuaFunction(GetUnlockEntryIndexToCelebrate, g_iUnlockEntryIndexToCelebrate);

namespace {
void WarnScreenUnlockCelebrate(const std::string& message) {
  if (LOG != nullptr) {
    LOG->Warn("ScreenUnlockCelebrate: %s", message.c_str());
  }
}

bool CanReadUnlocksToCelebrate() {
  return UNLOCKMAN != nullptr && PROFILEMAN != nullptr &&
         PROFILEMAN->GetMachineProfile() != nullptr;
}

bool IsValidUnlockEntryIndex(int index) {
  return UNLOCKMAN != nullptr && index >= 0 &&
         index < static_cast<int>(UNLOCKMAN->m_UnlockEntries.size());
}

const UnlockEntry* GetCelebrationUnlockEntry(int index) {
  if (!IsValidUnlockEntryIndex(index)) {
    return nullptr;
  }

  return &UNLOCKMAN->m_UnlockEntries[index];
}

int GetSafeUnlockEntryIndexToCelebrate() {
  if (!CanReadUnlocksToCelebrate()) {
    WarnScreenUnlockCelebrate(
        "Cannot find unlock to celebrate because unlock/profile managers are "
        "not available.");
    return -1;
  }

  const int index = UNLOCKMAN->GetUnlockEntryIndexToCelebrate();
  if (!IsValidUnlockEntryIndex(index)) {
    if (index != -1) {
      WarnScreenUnlockCelebrate(
          ssprintf("Ignoring invalid unlock celebration index %d.", index));
    }
    return -1;
  }

  const UnlockEntry& entry = UNLOCKMAN->m_UnlockEntries[index];
  if (!entry.IsValid()) {
    WarnScreenUnlockCelebrate(
        ssprintf("Ignoring invalid unlock entry at index %d.", index));
    return -1;
  }

  if (entry.GetUnlockEntryStatus() != UnlockEntryStatus_RequirementsMet) {
    WarnScreenUnlockCelebrate(
        ssprintf("Unlock entry at index %d is not ready to celebrate.", index));
    return -1;
  }

  return index;
}

void SetCelebrationGameContext(const UnlockEntry& entry) {
  if (GAMESTATE == nullptr) {
    WarnScreenUnlockCelebrate(
        "Cannot set celebration song/course context without GAMESTATE.");
    return;
  }
  if (SONGMAN == nullptr) {
    WarnScreenUnlockCelebrate(
        "Cannot set celebration song/course context without SONGMAN.");
    return;
  }

  Song* pSong = entry.m_Song.ToSong();
  Course* pCourse = entry.m_Course.ToCourse();

  if (pSong != nullptr) {
    GAMESTATE->m_pCurSong.Set(pSong);
    GAMESTATE->m_pPreferredSong = pSong;
    GAMESTATE->m_pCurCourse.Set(nullptr);
    GAMESTATE->m_pPreferredCourse = nullptr;
  } else if (pCourse != nullptr) {
    GAMESTATE->m_pCurCourse.Set(pCourse);
    GAMESTATE->m_pPreferredCourse = pCourse;
    GAMESTATE->m_pCurSong.Set(nullptr);
    GAMESTATE->m_pPreferredSong = nullptr;
  }
}

bool MarkUnlockEntryCelebrated(const UnlockEntry& entry) {
  if (PROFILEMAN == nullptr || PROFILEMAN->GetMachineProfile() == nullptr) {
    WarnScreenUnlockCelebrate(
        "Cannot mark unlock celebrated without a machine profile.");
    return false;
  }
  if (entry.m_sEntryID.empty()) {
    WarnScreenUnlockCelebrate(
        "Cannot mark unlock celebrated because the entry id is empty.");
    return false;
  }

  PROFILEMAN->GetMachineProfile()->m_UnlockedEntryIDs.insert(entry.m_sEntryID);
  if (SONGMAN != nullptr) {
    SONGMAN->InvalidateCachedTrails();
  }
  return true;
}
}  // namespace

void ScreenUnlockCelebrate::Init() {
  g_iUnlockEntryIndexToCelebrate = -1;

  const int unlockIndex = GetSafeUnlockEntryIndexToCelebrate();
  const UnlockEntry* entry = GetCelebrationUnlockEntry(unlockIndex);
  if (entry != nullptr) {
    g_iUnlockEntryIndexToCelebrate = unlockIndex;
    SetCelebrationGameContext(*entry);
  }

  ScreenUnlockBrowse::Init();

  if (entry != nullptr && !MarkUnlockEntryCelebrated(*entry)) {
    g_iUnlockEntryIndexToCelebrate = -1;
  }
}

bool ScreenUnlockCelebrate::MenuBack(const InputEventPlus& input) {
  if (input.type != IET_FIRST_PRESS) {
    return false;
  }
  return MenuStart(input);
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
