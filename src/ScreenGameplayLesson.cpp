#include "ScreenGameplayLesson.h"

#include <memory>
#include <string>
#include <utility>
#include <vector>

#include "Actor.h"
#include "ActorUtil.h"
#include "AutoActor.h"
#include "EnumHelper.h"
#include "GameConstantsAndTypes.h"
#include "GamePreferences.h"
#include "GameState.h"
#include "InputEventPlus.h"
#include "LuaManager.h"
#include "LuaReference.h"
#include "MessageManager.h"
#include "PlayerNumber.h"
#include "PlayerStageStats.h"
#include "RageLog.h"
#include "RageSound.h"
#include "RageUtil.h"
#include "Screen.h"
#include "ScreenGameplay.h"
#include "ScreenGameplayNormal.h"
#include "ScreenMessage.h"
#include "Song.h"
#include "StatsManager.h"
#include "global.h"

REGISTER_SCREEN_CLASS(ScreenGameplayLesson);

namespace {
constexpr float kLessonRestartMinTimeToNotes = 2.0f;
constexpr float kLessonRestartStartSecond = 0.0f;

bool IsLessonPlayerValid(const PlayerNumber pn) {
  return pn >= PLAYER_1 && pn < NUM_PLAYERS;
}
}  // namespace

ScreenGameplayLesson::ScreenGameplayLesson() {
  m_iCurrentPageIndex = -1;
  m_Try = Try_1;
}

void ScreenGameplayLesson::Init() {
  m_iCurrentPageIndex = -1;
  m_Try = Try_1;
  m_vPages.clear();

  if (GAMESTATE == nullptr) {
    LOG->Warn("ScreenGameplayLesson::Init called without GAMESTATE.");
    PostScreenMessage(SM_GoToPrevScreen, 0);
    return;
  }

  const PlayerNumber master = GAMESTATE->GetMasterPlayerNumber();
  const void* styleForLog =
      IsLessonPlayerValid(master)
          ? static_cast<const void*>(GAMESTATE->GetCurrentStyle(master))
          : nullptr;
  if (!IsLessonPlayerValid(master) || styleForLog == nullptr ||
      GAMESTATE->m_pCurSong == nullptr) {
    LOG->Warn("ScreenGameplayLesson::Init missing lesson prerequisites "
              "(master=%d, style=%p, song=%p).",
              master,
              styleForLog,
              static_cast<const void*>(GAMESTATE->m_pCurSong));
    PostScreenMessage(SM_GoToPrevScreen, 0);
    return;
  }

  /* Now that we've set up, init the base class. */
  ScreenGameplayNormal::Init();

  if (GAMESTATE == nullptr || GAMESTATE->m_pCurSong == nullptr) {
    LOG->Warn("ScreenGameplayLesson::Init aborted after base init because the "
              "current song was cleared.");
    PostScreenMessage(SM_GoToPrevScreen, 0);
    return;
  }

  ClearMessageQueue();  // remove all of the messages set in ScreenGameplay that
                        // animate "ready", "here we go", etc.

  GAMESTATE->m_bGameplayLeadIn.Set(false);

  m_DancingState = STATE_DANCING;

  if (LoadLessonPages(GAMESTATE->m_pCurSong)) {
    m_iCurrentPageIndex = 0;
    int i = 0;
    for (AutoActor& aa : m_vPages) {
      const bool bIsFirst = (i++ == 0);
      aa->PlayCommand(bIsFirst ? "Show" : "Hide");
      aa->PlayCommand("On");
    }

    // Autoplay during demonstration.
    SetLessonAutoplayControllers();
  } else {
    LOG->Warn("ScreenGameplayLesson found no valid lesson pages for '%s'; "
              "starting the playable lesson immediately.",
              GAMESTATE->m_pCurSong->GetTranslitMainTitle().c_str());
    EnterLessonPlay(true);
  }

  // Reset stage number (not relevant in lessons)
  GAMESTATE->m_iCurrentStageIndex = 0;
  FOREACH_ENUM(PlayerNumber, p) {
    GAMESTATE->m_iPlayerStageTokens[p] = 1;
  }
}

bool ScreenGameplayLesson::Input(const InputEventPlus& input) {
  // LOG->Trace( "ScreenGameplayLesson::Input()" );

  if (m_iCurrentPageIndex != -1) {
    if (!IsCurrentPageIndexValid()) {
      LOG->Warn("ScreenGameplayLesson ignored invalid page index %d during "
                "input.",
                m_iCurrentPageIndex);
      HideCurrentPageIfValid();
      EnterLessonPlay(true);
      return true;
    }

    // show a lesson page
    return Screen::Input(input);
  } else {
    // in the "your turn" section"
    return ScreenGameplay::Input(input);
  }
}

void ScreenGameplayLesson::HandleScreenMessage(const ScreenMessage SM) {
  if (SM == SM_NotesEnded) {
    const bool bShowingAPage = m_iCurrentPageIndex != -1;

    // While showing a page, loop the music.
    if (bShowingAPage) {
      if (!IsCurrentPageIndexValid()) {
        LOG->Warn("ScreenGameplayLesson recovered from invalid page index %d "
                  "when notes ended.",
                  m_iCurrentPageIndex);
        HideCurrentPageIfValid();
        EnterLessonPlay(true);
        return;
      }
      ResetAndRestartCurrentSong();
    } else {
      PlayerStageStats* pss = GetLessonStageStats();
      if (pss == nullptr) {
        LOG->Warn("ScreenGameplayLesson cannot evaluate lesson score because "
                  "stage stats are unavailable.");
        ScreenGameplay::HandleScreenMessage(SM);
        return;
      }

      int iActual = pss->GetLessonScoreActual();
      int iNeeded = pss->GetLessonScoreNeeded();
      bool bCleared = iActual >= iNeeded;
      bool bAnyTriesLeft = m_Try + 1 < NUM_Try;

      if (bCleared) {
        BroadcastLessonMessage(Message_LessonCleared);
        this->HandleScreenMessage(SM_LeaveGameplay);

        // Commit scores here since we don't go through an eval screen.
        // Only commit if we've cleared.  Don't commit if we've failed all 3
        // tries.
        if (STATSMAN != nullptr) {
          STATSMAN->m_CurStageStats.FinalizeScores(false);
        }
      } else if (bAnyTriesLeft) {
        ResetAndRestartCurrentSong();

        m_Try = (Try)(m_Try + 1);
        BroadcastLessonMessage(
            (MessageID)(Message_LessonTry1 + Enum::to_integral(m_Try)));
      } else {
        this->HandleScreenMessage(SM_BeginFailed);
        BroadcastLessonMessage(Message_LessonFailed);
      }
    }
    return;  // handled
  }

  ScreenGameplay::HandleScreenMessage(SM);
}

bool ScreenGameplayLesson::MenuStart(const InputEventPlus& input) {
  if (input.type == IET_REPEAT || m_iCurrentPageIndex == -1) {
    return false;
  }
  if (!IsCurrentPageIndexValid()) {
    LOG->Warn("ScreenGameplayLesson ignored Start on invalid page index %d.",
              m_iCurrentPageIndex);
    HideCurrentPageIfValid();
    EnterLessonPlay(true);
    return true;
  }
  ChangeLessonPage(+1);
  return true;
}

bool ScreenGameplayLesson::MenuBack(const InputEventPlus& input) {
  if (input.type == IET_REPEAT) {
    return false;
  }
  if (m_iCurrentPageIndex == 0) {
    RestoreLessonControllers();
    BeginBackingOutFromGameplay();
    return true;
  }
  if (m_iCurrentPageIndex == -1) {
    return false;
  }
  if (!IsCurrentPageIndexValid()) {
    LOG->Warn("ScreenGameplayLesson ignored Back on invalid page index %d.",
              m_iCurrentPageIndex);
    HideCurrentPageIfValid();
    EnterLessonPlay(true);
    return true;
  }
  ChangeLessonPage(-1);
  return true;
}

void ScreenGameplayLesson::ChangeLessonPage(int iDir) {
  if (!IsCurrentPageIndexValid()) {
    LOG->Warn("ScreenGameplayLesson cannot change from invalid page index %d.",
              m_iCurrentPageIndex);
    HideCurrentPageIfValid();
    EnterLessonPlay(true);
    return;
  }

  const int iNextPageIndex = m_iCurrentPageIndex + iDir;
  if (iNextPageIndex < 0) {
    // don't change
    return;
  }

  if (iNextPageIndex >= static_cast<int>(m_vPages.size())) {
    HideCurrentPageIfValid();
    EnterLessonPlay(true);
    return;
  }

  HideCurrentPageIfValid();
  m_iCurrentPageIndex = iNextPageIndex;
  m_vPages[static_cast<size_t>(m_iCurrentPageIndex)]->PlayCommand("Show");
}

void ScreenGameplayLesson::ResetAndRestartCurrentSong() {
  PlayerStageStats* pss = GetLessonStageStats();
  if (pss != nullptr) {
    pss->ResetScoreForLesson();
  }

  if (m_pSoundMusic != nullptr) {
    m_pSoundMusic->Stop();
  } else {
    LOG->Warn("ScreenGameplayLesson restarting without an active music sound.");
  }

  ReloadCurrentSong();
  StartPlayingSong(kLessonRestartMinTimeToNotes, kLessonRestartStartSecond);
}

bool ScreenGameplayLesson::LoadLessonPages(Song* pSong) {
  m_vPages.clear();

  if (pSong == nullptr) {
    return false;
  }
  if (LUA == nullptr) {
    LOG->Warn("ScreenGameplayLesson cannot load lesson pages without Lua.");
    return false;
  }

  std::vector<std::string> vs;
  GetDirListing(pSong->GetSongDir() + "Page*", vs, true, true);
  if (vs.empty()) {
    return false;
  }

  m_vPages.resize(vs.size());
  size_t loadedPages = 0;
  for (size_t i = 0; i < vs.size(); ++i) {
    AutoActor& aa = m_vPages[loadedPages];
    LuaThreadVariable iIndex(
        "PageIndex", LuaReference::Create(static_cast<int>(loadedPages)));
    LuaThreadVariable iPages(
        "NumPages", LuaReference::Create(static_cast<int>(vs.size())));
    std::unique_ptr<Actor> page(ActorUtil::MakeActor(vs[i]));
    if (page == nullptr) {
      LOG->Warn("ScreenGameplayLesson failed to load lesson page '%s'.",
                vs[i].c_str());
      continue;
    }
    aa.Adopt(std::move(page));

    aa->SetDrawOrder(DRAW_ORDER_OVERLAY + 1);
    this->AddChild(aa);
    ++loadedPages;
  }

  m_vPages.resize(loadedPages);
  return !m_vPages.empty();
}

bool ScreenGameplayLesson::IsCurrentPageIndexValid() const {
  return m_iCurrentPageIndex >= 0 &&
         m_iCurrentPageIndex < static_cast<int>(m_vPages.size()) &&
         m_vPages[static_cast<size_t>(m_iCurrentPageIndex)].IsLoaded();
}

PlayerNumber ScreenGameplayLesson::GetLessonScorePlayer() const {
  if (GAMESTATE != nullptr) {
    const PlayerNumber master = GAMESTATE->GetMasterPlayerNumber();
    if (IsLessonPlayerValid(master)) {
      return master;
    }
  }
  return PLAYER_1;
}

PlayerStageStats* ScreenGameplayLesson::GetLessonStageStats() {
  if (STATSMAN == nullptr) {
    return nullptr;
  }

  return &STATSMAN->m_CurStageStats.m_player[GetLessonScorePlayer()];
}

void ScreenGameplayLesson::BroadcastLessonMessage(MessageID message) const {
  if (MESSAGEMAN == nullptr) {
    LOG->Warn("ScreenGameplayLesson dropped lesson message %d because "
              "MESSAGEMAN is unavailable.",
              message);
    return;
  }
  MESSAGEMAN->Broadcast(message);
}

void ScreenGameplayLesson::HideCurrentPageIfValid() {
  if (!IsCurrentPageIndexValid()) {
    return;
  }
  m_vPages[static_cast<size_t>(m_iCurrentPageIndex)]->PlayCommand("Hide");
}

void ScreenGameplayLesson::EnterLessonPlay(bool restartSong) {
  m_iCurrentPageIndex = -1;
  if (restartSong) {
    ResetAndRestartCurrentSong();
  }
  BroadcastLessonMessage(
      (MessageID)(Message_LessonTry1 + Enum::to_integral(m_Try)));
  RestoreLessonControllers();
}

void ScreenGameplayLesson::SetLessonAutoplayControllers() {
  FOREACH_EnabledPlayerInfo(m_vPlayerInfo, pi) {
    PlayerState* playerState = pi->GetPlayerState();
    if (playerState == nullptr) {
      LOG->Warn("ScreenGameplayLesson cannot force autoplay for an enabled "
                "player without PlayerState.");
      continue;
    }
    playerState->m_PlayerController = PC_AUTOPLAY;
  }
}

void ScreenGameplayLesson::RestoreLessonControllers() {
  // Change back to the current autoplay setting (in most cases, human
  // controlled).
  FOREACH_EnabledPlayerInfo(m_vPlayerInfo, pi) {
    PlayerState* playerState = pi->GetPlayerState();
    if (playerState == nullptr) {
      LOG->Warn("ScreenGameplayLesson cannot restore controller for an enabled "
                "player without PlayerState.");
      continue;
    }

    /* Mike: I'm not sure if you can actually have the player options enabled
     * in this mode, but I'm putting the check here anyways to play it safe.
     * If it's unnecessary, then it should be removed. */
    if (playerState->m_PlayerOptions.GetCurrent().m_fPlayerAutoPlay != 0) {
      playerState->m_PlayerController = PC_AUTOPLAY;
    } else {
      playerState->m_PlayerController = GamePreferences::m_AutoPlay;
    }
  }
}

/*
 * (c) 2003-2004 Chris Danford
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
