#include "ScreenSaveSync.h"

#include <cstddef>
#include <list>
#include <string>
#include <vector>

#include "AdjustSync.h"
#include "GameState.h"
#include "LocalizedString.h"
#include "PrefsManager.h"
#include "RageLog.h"
#include "RageUtil.h"
#include "ScreenMessage.h"
#include "ScreenManager.h"
#include "ScreenPrompt.h"
#include "Song.h"
#include "ThemeManager.h"

static LocalizedString CHANGED_TIMING_OF(
    "ScreenSaveSync", "You have changed the timing of");
static LocalizedString WOULD_YOU_LIKE_TO_SAVE(
    "ScreenSaveSync", "Would you like to save these changes?");
static LocalizedString CHOOSING_NO_WILL_DISCARD(
    "ScreenSaveSync", "Choosing NO will discard your changes.");
static LocalizedString UNKNOWN_SONG("ScreenSaveSync", "Unknown song");

namespace {
struct SyncPromptContext {
  SyncPromptContext()
      : song(nullptr),
        hasSongChanges(false),
        timingSnapshotCount(0),
        stepCount(0) {}

  const Song* song;
  bool hasSongChanges;
  std::size_t timingSnapshotCount;
  std::size_t stepCount;
  std::string songTitle;
};

std::list<SyncPromptContext> g_PromptContexts;

void WarnSaveSync(const std::string& message) {
  if (LOG != nullptr) {
    LOG->Warn("SRC_AUDIT_FIX ScreenSaveSync: %s", message.c_str());
  }
}

void RemovePromptContext(const SyncPromptContext* context) {
  for (std::list<SyncPromptContext>::iterator it = g_PromptContexts.begin();
       it != g_PromptContexts.end(); ++it) {
    if (&*it == context) {
      g_PromptContexts.erase(it);
      return;
    }
  }
}

bool IsPromptScreenUsable() {
  if (SCREENMAN == nullptr) {
    WarnSaveSync("prompt refused without SCREENMAN.");
    return false;
  }
  if (THEME == nullptr || !THEME->IsThemeLoaded()) {
    WarnSaveSync("prompt refused without a loaded theme.");
    return false;
  }
  if (!SCREENMAN->IsScreenNameValid("ScreenPrompt")) {
    WarnSaveSync("prompt refused because ScreenPrompt is not usable.");
    return false;
  }
  return true;
}

bool IsSyncRuntimeUsable() {
  if (GAMESTATE == nullptr) {
    WarnSaveSync("sync prompt refused without GAMESTATE.");
    return false;
  }
  if (PREFSMAN == nullptr) {
    WarnSaveSync("sync prompt refused without PREFSMAN.");
    return false;
  }
  if (GAMESTATE->IsCourseMode()) {
    WarnSaveSync("sync prompt refused during course mode.");
    return false;
  }
  return true;
}

std::string GetSafeSongTitle(const Song* song) {
  if (song == nullptr) {
    return UNKNOWN_SONG.GetValue();
  }

  const std::string title = song->GetDisplayFullTitle();
  if (!title.empty()) {
    return title;
  }
  return UNKNOWN_SONG.GetValue();
}

bool BuildPromptText(SyncPromptContext& context, std::string& text) {
  text.clear();
  if (!IsSyncRuntimeUsable()) {
    return false;
  }

  std::vector<std::string> globalChanges;
  AdjustSync::GetSyncChangeTextGlobal(globalChanges);

  std::vector<std::string> songChanges;
  Song* song = GAMESTATE->m_pCurSong.Get();
  if (song != nullptr) {
    if (AdjustSync::s_vpTimingDataOriginal.empty()) {
      WarnSaveSync(
          "song sync changes skipped because original timing data is empty.");
    } else {
      AdjustSync::GetSyncChangeTextSong(songChanges);
    }
  }

  if (globalChanges.empty() && songChanges.empty()) {
    WarnSaveSync("sync prompt refused because there are no pending changes.");
    return false;
  }

  context.song = song;
  context.hasSongChanges = !songChanges.empty();
  context.timingSnapshotCount = AdjustSync::s_vpTimingDataOriginal.size();
  context.stepCount = song != nullptr ? song->GetAllSteps().size() : 0;
  context.songTitle = GetSafeSongTitle(song);

  if (!globalChanges.empty()) {
    text += join("\n", globalChanges) + "\n\n";
  }

  if (!songChanges.empty()) {
    text += CHANGED_TIMING_OF.GetValue() + "\n" + context.songTitle +
            ":\n\n";
    text += join("\n", songChanges) + "\n\n";
  }

  text += WOULD_YOU_LIKE_TO_SAVE.GetValue() + "\n" +
          CHOOSING_NO_WILL_DISCARD.GetValue();
  return true;
}

bool IsPromptContextStillCurrent(const SyncPromptContext& context) {
  if (!IsSyncRuntimeUsable()) {
    return false;
  }

  Song* currentSong = GAMESTATE->m_pCurSong.Get();
  if (context.song != nullptr && currentSong != context.song) {
    WarnSaveSync(
        "sync prompt ignored because the current song changed before answer.");
    return false;
  }

  if (currentSong != nullptr) {
    const std::size_t currentStepCount = currentSong->GetAllSteps().size();
    if (context.song != nullptr && currentStepCount != context.stepCount) {
      WarnSaveSync(
          "sync prompt ignored because the song steps changed before answer.");
      return false;
    }

    const std::size_t requiredSnapshots = currentStepCount + 1;
    if (AdjustSync::s_vpTimingDataOriginal.size() < requiredSnapshots) {
      WarnSaveSync(
          "sync prompt ignored because original timing snapshots are stale.");
      return false;
    }
    if (context.timingSnapshotCount != 0 &&
        AdjustSync::s_vpTimingDataOriginal.size() !=
            context.timingSnapshotCount) {
      WarnSaveSync(
          "sync prompt ignored because the timing snapshot count changed.");
      return false;
    }
  }

  SyncPromptContext currentContext;
  std::string currentText;
  if (!BuildPromptText(currentContext, currentText)) {
    WarnSaveSync("sync prompt ignored because changes are no longer pending.");
    return false;
  }

  if (context.hasSongChanges && currentContext.song != context.song) {
    WarnSaveSync(
        "sync prompt ignored because song changes no longer match context.");
    return false;
  }

  return true;
}

void SaveSyncChanges(void* callbackData) {
  const SyncPromptContext* context =
      static_cast<const SyncPromptContext*>(callbackData);
  if (context != nullptr && IsPromptContextStillCurrent(*context)) {
    AdjustSync::SaveSyncChanges();
  }
  RemovePromptContext(context);
}

void RevertSyncChanges(void* callbackData) {
  const SyncPromptContext* context =
      static_cast<const SyncPromptContext*>(callbackData);
  if (context != nullptr && IsPromptContextStillCurrent(*context)) {
    AdjustSync::RevertSyncChanges();
  }
  RemovePromptContext(context);
}
}  // namespace

void ScreenSaveSync::PromptSaveSync(ScreenMessage sm) {
  if (!IsPromptScreenUsable()) {
    return;
  }

  SyncPromptContext context;
  std::string promptText;
  if (!BuildPromptText(context, promptText)) {
    return;
  }

  g_PromptContexts.push_back(context);
  SyncPromptContext* storedContext = &g_PromptContexts.back();
  ScreenPrompt::Prompt(
      sm, promptText, PROMPT_YES_NO, ANSWER_YES, SaveSyncChanges,
      RevertSyncChanges, storedContext);
}

/*
 * (c) 2001-2005 Chris Danford
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
