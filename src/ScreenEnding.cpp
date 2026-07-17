#include "ScreenEnding.h"

#include <cmath>
#include <vector>

#include "ActorUtil.h"
#include "AnnouncerManager.h"
#include "EnumHelper.h"
#include "GameConstantsAndTypes.h"
#include "GameManager.h"
#include "GameSoundManager.h"
#include "GameState.h"
#include "InputEventPlus.h"
#include "MemoryCardManager.h"
#include "ModsGroup.h"
#include "PlayerNumber.h"
#include "PlayerState.h"
#include "PrefsManager.h"
#include "Profile.h"
#include "ProfileManager.h"
#include "RageLog.h"
#include "RageUtil.h"
#include "RageUtil/RandomNumbers.h"
#include "Screen.h"
#include "ScreenAttract.h"
#include "ScreenMessage.h"
#include "Song.h"
#include "SongManager.h"
#include "StatsManager.h"
#include "Style.h"
#include "ThemeManager.h"

namespace {

void WarnScreenEnding(const std::string& message) {
  if (LOG != nullptr) {
    LOG->Warn("SRC_AUDIT_FIX ScreenEnding: %s", message.c_str());
  }
}

bool IsTestInitialScreenRequested() {
  return PREFSMAN != nullptr && !PREFSMAN->m_sTestInitialScreen.Get().empty();
}

Steps* GetFirstPlayableSteps(Song* song, const Style* style) {
  if (song == nullptr || style == nullptr) {
    return nullptr;
  }

  const std::vector<Steps*>& steps =
      song->GetStepsByStepsType(style->m_StepsType);
  for (Steps* candidate : steps) {
    if (candidate != nullptr) {
      return candidate;
    }
  }
  return nullptr;
}

bool CanSetupEndingTestState() {
  if (PROFILEMAN == nullptr || GAMESTATE == nullptr || GAMEMAN == nullptr ||
      SONGMAN == nullptr || STATSMAN == nullptr) {
    WarnScreenEnding(
        "test ending setup skipped because a required manager is missing.");
    return false;
  }
  if (GAMESTATE->m_pPlayerState[PLAYER_1] == nullptr ||
      GAMESTATE->m_pPlayerState[PLAYER_2] == nullptr) {
    WarnScreenEnding(
        "test ending setup skipped because a player state is missing.");
    return false;
  }
  return true;
}

bool ShouldShowRemoveCardPrompt(PlayerNumber p) {
  if (MEMCARDMAN == nullptr) {
    WarnScreenEnding("remove-card prompt skipped without MEMCARDMAN.");
    return false;
  }
  return MEMCARDMAN->GetCardState(p) == MemoryCardState_Ready;
}

}  // namespace

REGISTER_SCREEN_CLASS(ScreenEnding);

void ScreenEnding::Init() {
  SetupTestInitialScreen();
  ScreenAttract::Init();

  if (GAMESTATE == nullptr || PROFILEMAN == nullptr) {
    WarnScreenEnding(
        "remove-card prompts skipped because game/profile state is missing.");
    PlayEndingAnnouncer();
    return;
  }

  FOREACH_HumanPlayer(p) {
    if (!PROFILEMAN->IsPersistentProfile(p)) {
      continue;
    }

    LoadRemoveCardPrompt(p);
  }

  PlayEndingAnnouncer();

  // Now that we've read the data from the profile, it's ok to Reset()
  if (GAMESTATE != nullptr) {
    GAMESTATE->Reset();
  } else {
    WarnScreenEnding("skipped ending game-state reset without GAMESTATE.");
  }
}

bool ScreenEnding::Input(const InputEventPlus& input) {
  if (IsTransitioning()) {
    return true;
  }

  if (input.type == IET_FIRST_PRESS && input.MenuI == GAME_BUTTON_START) {
    PostScreenMessage(SM_BeginFadingOut, 0);
    return true;
  }

  return ScreenAttract::Input(input);
}

void ScreenEnding::SetupTestInitialScreen() {
  if (!IsTestInitialScreenRequested()) {
    return;
  }
  if (!CanSetupEndingTestState()) {
    return;
  }

  const Game* defaultGame = GAMEMAN->GetDefaultGame();
  const Style* style =
      defaultGame != nullptr
          ? GAMEMAN->GameAndStringToStyle(defaultGame, "versus")
          : nullptr;
  Song* song = SONGMAN->GetRandomSong();
  Steps* steps = GetFirstPlayableSteps(song, style);
  if (style == nullptr || song == nullptr || steps == nullptr) {
    WarnScreenEnding(
        "test ending setup skipped because style, song, or steps are missing.");
    return;
  }

  PROFILEMAN->LoadFirstAvailableProfile(PLAYER_1);
  PROFILEMAN->LoadFirstAvailableProfile(PLAYER_2);

  GAMESTATE->m_PlayMode.Set(PLAY_MODE_REGULAR);
  GAMESTATE->SetCurrentStyle(style, PLAYER_INVALID);
  GAMESTATE->JoinPlayer(PLAYER_1);
  GAMESTATE->JoinPlayer(PLAYER_2);
  GAMESTATE->m_pCurSong.Set(song);
  GAMESTATE->m_pCurCourse.Set(SONGMAN->GetRandomCourse());
  GAMESTATE->m_pCurSteps[PLAYER_1].Set(steps);
  GAMESTATE->m_pCurSteps[PLAYER_2].Set(steps);
  STATSMAN->m_CurStageStats.m_player[PLAYER_1].m_vpPossibleSteps.push_back(
      steps);
  STATSMAN->m_CurStageStats.m_player[PLAYER_2].m_vpPossibleSteps.push_back(
      steps);
  STATSMAN->m_CurStageStats.m_player[PLAYER_1].m_iStepsPlayed = 1;
  STATSMAN->m_CurStageStats.m_player[PLAYER_2].m_iStepsPlayed = 1;
  PO_GROUP_ASSIGN(
      GAMESTATE->m_pPlayerState[PLAYER_1]->m_PlayerOptions, ModsLevel_Stage,
      m_fScrollSpeed, 2.0f);
  PO_GROUP_ASSIGN(
      GAMESTATE->m_pPlayerState[PLAYER_2]->m_PlayerOptions, ModsLevel_Stage,
      m_fScrollSpeed, 2.0f);
  GAMESTATE->m_iCurrentStageIndex = 0;
  FOREACH_ENUM(PlayerNumber, p) {
    GAMESTATE->m_iPlayerStageTokens[p] = 1;
  }
  PO_GROUP_CALL(
      GAMESTATE->m_pPlayerState[PLAYER_1]->m_PlayerOptions, ModsLevel_Stage,
      ChooseRandomModifiers);
  PO_GROUP_CALL(
      GAMESTATE->m_pPlayerState[PLAYER_2]->m_PlayerOptions, ModsLevel_Stage,
      ChooseRandomModifiers);

  for (float f = 0; f < 100.0f; f += 1.0f) {
    float fP1 = std::fmod(f / 100 * 4 + .3f, 1);
    STATSMAN->m_CurStageStats.m_player[PLAYER_1].SetLifeRecordAt(fP1, f);
    STATSMAN->m_CurStageStats.m_player[PLAYER_2].SetLifeRecordAt(1 - fP1, f);
  }

  STATSMAN->m_CurStageStats.m_player[PLAYER_1].m_iActualDancePoints =
      RandomInt(3);
  STATSMAN->m_CurStageStats.m_player[PLAYER_1].m_iPossibleDancePoints = 2;
  STATSMAN->m_CurStageStats.m_player[PLAYER_2].m_iActualDancePoints =
      RandomInt(2);
  STATSMAN->m_CurStageStats.m_player[PLAYER_2].m_iPossibleDancePoints = 1;
  STATSMAN->m_CurStageStats.m_player[PLAYER_1].m_iCurCombo = 0;
  STATSMAN->m_CurStageStats.m_player[PLAYER_1].UpdateComboList(0, false);
  STATSMAN->m_CurStageStats.m_player[PLAYER_1].m_iCurCombo = 1;
  STATSMAN->m_CurStageStats.m_player[PLAYER_1].UpdateComboList(1, false);
  STATSMAN->m_CurStageStats.m_player[PLAYER_1].m_iCurCombo = 50;
  STATSMAN->m_CurStageStats.m_player[PLAYER_1].UpdateComboList(25, false);
  STATSMAN->m_CurStageStats.m_player[PLAYER_1].m_iCurCombo = 250;
  STATSMAN->m_CurStageStats.m_player[PLAYER_1].UpdateComboList(100, false);

  STATSMAN->m_CurStageStats.m_player[PLAYER_1].m_iTapNoteScores[TNS_W1] =
      RandomInt(2);
  STATSMAN->m_CurStageStats.m_player[PLAYER_1].m_iTapNoteScores[TNS_W2] =
      RandomInt(2);
  STATSMAN->m_CurStageStats.m_player[PLAYER_1].m_iTapNoteScores[TNS_W3] =
      RandomInt(2);
  STATSMAN->m_CurStageStats.m_player[PLAYER_2].m_iTapNoteScores[TNS_W1] =
      RandomInt(2);
  STATSMAN->m_CurStageStats.m_player[PLAYER_2].m_iTapNoteScores[TNS_W2] =
      RandomInt(2);
  STATSMAN->m_CurStageStats.m_player[PLAYER_2].m_iTapNoteScores[TNS_W3] =
      RandomInt(2);

  STATSMAN->m_vPlayedStageStats.clear();
}

void ScreenEnding::LoadRemoveCardPrompt(PlayerNumber p) {
  if (THEME == nullptr || !THEME->IsThemeLoaded()) {
    WarnScreenEnding("remove-card prompt skipped without loaded theme.");
    return;
  }

  Sprite& prompt = m_sprRemoveMemoryCard[p];
  prompt.SetName(ssprintf("RemoveCardP%d", p + 1));
  const std::string path =
      THEME->GetPathG("ScreenEnding", ssprintf("remove card P%d", p + 1), true);
  if (path.empty()) {
    WarnScreenEnding("remove-card prompt asset is missing.");
    return;
  }

  prompt.Load(path);
  prompt.SetVisible(ShouldShowRemoveCardPrompt(p));
  ActorUtil::LoadAllCommands(prompt, m_sName);
  ActorUtil::SetXY(prompt, m_sName);
  if (prompt.HasCommand("On")) {
    prompt.PlayCommand("On");
  }
  this->AddChild(&prompt);
}

void ScreenEnding::PlayEndingAnnouncer() {
  if (SOUND == nullptr || ANNOUNCER == nullptr) {
    WarnScreenEnding("ending announcer skipped without SOUND or ANNOUNCER.");
    return;
  }

  const std::string announcerPath = ANNOUNCER->GetPathTo("music scroll");
  if (!announcerPath.empty()) {
    SOUND->PlayOnceFromDir(announcerPath);
  }
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
