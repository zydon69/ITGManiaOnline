#include "ScreenPlayerOptions.h"

#include <algorithm>
#include <vector>

#include "ActorUtil.h"
#include "AnnouncerManager.h"
#include "CodeDetector.h"
#include "GameSoundManager.h"
#include "GameState.h"
#include "InputEventPlus.h"
#include "InputFilter.h"
#include "MessageManager.h"
#include "ModsGroup.h"
#include "LuaManager.h"
#include "OptionRow.h"
#include "OptionRowHandler.h"
#include "PlayerNumber.h"
#include "PlayerState.h"
#include "PrefsManager.h"
#include "RageUtil.h"
#include "Screen.h"
#include "ScreenManager.h"
#include "ScreenMessage.h"
#include "ScreenOptions.h"
#include "ScreenOptionsMaster.h"
#include "SongOptions.h"
#include "ThemeManager.h"
#include "global.h"

REGISTER_SCREEN_CLASS(ScreenPlayerOptions);

namespace {
bool HasPlayerOptionsTheme() {
  return THEME != nullptr && THEME->IsThemeLoaded();
}

std::string GetPlayerOptionsExitText() {
  if (!HasPlayerOptionsTheme()) {
    return "Exit";
  }
  return THEME->GetString("OptionNames", "Exit");
}

std::string GetPlayerOptionsReadyText() {
  if (!HasPlayerOptionsTheme()) {
    return "Ready";
  }
  return THEME->GetString("OptionNames", "Ready");
}
}  // namespace

static bool HasActiveITGOnlineRoom() {
  if (LUA == nullptr) {
    return false;
  }

  Lua* L = LUA->Get();
  if (L == nullptr) {
    return false;
  }
  const int top = lua_gettop(L);
  const bool ran = LuaHelpers::RunExpression(
      L,
      "ITGOnline ~= nil and ITGOnline.HasActiveRoom ~= nil "
      "and ITGOnline:HasActiveRoom()",
      "ScreenPlayerOptions::HasActiveITGOnlineRoom");
  const bool active = ran && lua_gettop(L) > top && lua_toboolean(L, -1);
  lua_settop(L, top);
  LUA->Release(L);

  return active;
}

void ScreenPlayerOptions::Init() {
  ScreenOptionsMaster::Init();

  FOREACH_PlayerNumber(p) {
    m_sprDisqualify[p].Load(
        HasPlayerOptionsTheme() ? THEME->GetPathG(m_sName, "disqualify") : "");
    m_sprDisqualify[p]->SetName(ssprintf("DisqualifyP%i", p + 1));
    LOAD_ALL_COMMANDS_AND_SET_XY(m_sprDisqualify[p]);
    m_sprDisqualify[p]->SetVisible(
        false);  // unhide later if handicapping options are discovered
    m_sprDisqualify[p]->SetDrawOrder(2);
    m_frameContainer.AddChild(m_sprDisqualify[p]);
  }

  const Maybe showSongOptions =
      PREFSMAN != nullptr ? PREFSMAN->m_ShowSongOptions.Get() : Maybe_NO;
  m_bAskOptionsMessage =
      GAMESTATE != nullptr && !GAMESTATE->IsEditing() &&
      showSongOptions == Maybe_ASK;

  m_bAcceptedChoices = false;
  m_bGoToOptions = showSongOptions == Maybe_YES;

  if (SOUND != nullptr && ANNOUNCER != nullptr) {
    SOUND->PlayOnceFromDir(ANNOUNCER->GetPathTo("player options intro"));
  }

  ResizeDisqualificationCache();
}

void ScreenPlayerOptions::BeginScreen() {
  FOREACH_PlayerNumber(p) {
    if (m_sprDisqualify[p].IsLoaded()) {
      ON_COMMAND(m_sprDisqualify[p]);
    }
  }

  ScreenOptionsMaster::BeginScreen();

  ResizeDisqualificationCache();

  const std::string exitText =
      HasActiveITGOnlineRoom() ? GetPlayerOptionsReadyText()
                               : GetPlayerOptionsExitText();
  for (OptionRow* row : m_pRows) {
    if (row != nullptr && row->GetRowType() == OptionRow::RowType_Exit) {
      row->SetExitText(exitText);
    }
  }

  FOREACH_HumanPlayer(p) {
    for (unsigned r = 0; r < m_pRows.size(); r++) {
      if (IsDisqualificationRow(static_cast<int>(r))) {
        UpdateDisqualified(r, p);
      }
    }
  }
}

bool ScreenPlayerOptions::IsUsablePlayer(PlayerNumber pn) const {
  return pn >= PLAYER_1 && pn < NUM_PLAYERS && GAMESTATE != nullptr &&
         GAMESTATE->IsHumanPlayer(pn) &&
         GAMESTATE->m_pPlayerState[pn] != nullptr;
}

bool ScreenPlayerOptions::IsDisqualificationRow(int row) const {
  OptionRow* optionRow = GetRow(row);
  return optionRow != nullptr &&
         optionRow->GetRowType() != OptionRow::RowType_Exit;
}

void ScreenPlayerOptions::ResizeDisqualificationCache() {
  FOREACH_PlayerNumber(p) {
    if (m_bRowCausesDisqualified[p].size() != m_pRows.size()) {
      m_bRowCausesDisqualified[p].assign(m_pRows.size(), false);
    }
  }
}

bool ScreenPlayerOptions::Input(const InputEventPlus& input) {
  bool bHandled = false;
  PlayerNumber pn = input.pn;
  const bool usablePlayer = IsUsablePlayer(pn);

  if (m_bAskOptionsMessage && input.type == IET_FIRST_PRESS &&
      !m_In.IsTransitioning() && input.MenuI == GAME_BUTTON_START &&
      usablePlayer) {
    if (m_bAcceptedChoices && !m_bGoToOptions) {
      m_bGoToOptions = true;
      this->PlayCommand("GoToOptions");
      if (SCREENMAN != nullptr) {
        SCREENMAN->PlayStartSound();
      }
      bHandled = true;
    }
  }

  if (usablePlayer &&
      CodeDetector::EnteredCode(
          input.GameI.controller, CODE_CANCEL_ALL_PLAYER_OPTIONS)) {
    // apply the game default mods, but not the Profile saved mods
    GAMESTATE->m_pPlayerState[pn]->ResetToDefaultPlayerOptions(
        ModsLevel_Preferred);

    if (MESSAGEMAN != nullptr) {
      MESSAGEMAN->Broadcast(ssprintf("CancelAllP%i", pn + 1));
    }

    for (unsigned r = 0; r < m_pRows.size(); r++) {
      OptionRow* row = GetRow(r);
      if (row == nullptr) {
        continue;
      }
      std::vector<PlayerNumber> v;
      v.push_back(pn);
      int iOldFocus = row->GetChoiceInRowWithFocus(pn);
      this->ImportOptions(r, v);
      row->AfterImportOptions(pn);
      if (IsDisqualificationRow(r)) {
        this->UpdateDisqualified(r, pn);
      }
      if (iOldFocus >= 0 &&
          iOldFocus < static_cast<int>(row->GetRowDef().m_vsChoices.size())) {
        row->SetChoiceInRowWithFocus(pn, iOldFocus);
      }
    }
    bHandled = true;
  }

  bHandled = ScreenOptionsMaster::Input(input) || bHandled;

  // UGLY: Update m_Disqualified whenever Start is pressed
  if (IsUsablePlayer(pn) && input.MenuI == GAME_BUTTON_START) {
    int row = m_iCurrentRow[pn];
    if (IsDisqualificationRow(row)) {
      UpdateDisqualified(row, pn);
    }
  }
  return bHandled;
}

void ScreenPlayerOptions::HandleScreenMessage(const ScreenMessage SM) {
  if (SM == SM_BeginFadingOut &&
      m_bAskOptionsMessage && !m_bAcceptedChoices &&
      !m_Cancel.IsTransitioning())  // user accepts the page of options
  {
    m_bAcceptedChoices = true;

    // show "hold START for options"
    this->PlayCommand("AskForGoToOptions");
  }

  ScreenOptionsMaster::HandleScreenMessage(SM);
}

void ScreenPlayerOptions::UpdateDisqualified(int row, PlayerNumber pn) {
  if (!IsUsablePlayer(pn) || !IsDisqualificationRow(row)) {
    return;
  }

  ResizeDisqualificationCache();

  if (row < 0 ||
      row >= static_cast<int>(m_bRowCausesDisqualified[pn].size())) {
    return;
  }

  OptionRow* optionRow = GetRow(row);
  if (optionRow == nullptr) {
    return;
  }

  if (!optionRow->GetRowDef().IsEnabledForPlayer(pn)) {
    m_bRowCausesDisqualified[pn][row] = false;
    const bool disqualified = std::any_of(
        m_bRowCausesDisqualified[pn].begin(),
        m_bRowCausesDisqualified[pn].end(), [](const bool& b) { return b; });
    if (m_sprDisqualify[pn].IsLoaded()) {
      m_sprDisqualify[pn]->SetVisible(disqualified);
    }
    return;
  }

  // save original player options
  PlayerOptions poOrig =
      GAMESTATE->m_pPlayerState[pn]->m_PlayerOptions.GetPreferred();
  SongOptions soOrig = GAMESTATE->m_SongOptions.GetPreferred();

  // Find out if the current row when exported causes disqualification.
  // Exporting the row will fill GAMESTATE->m_PlayerOptions.
  PO_GROUP_CALL(
      GAMESTATE->m_pPlayerState[pn]->m_PlayerOptions, ModsLevel_Preferred,
      Init);
  std::vector<PlayerNumber> v;
  v.push_back(pn);
  LuaThreadVariable previewExport("ScreenOptionsPreviewExport", "1");
  ExportOptionsForPreview(row, v);
  bool bRowCausesDisqualified = GAMESTATE->CurrentOptionsDisqualifyPlayer(pn);

  // restore previous player/song options before updating UI state
  GAMESTATE->m_pPlayerState[pn]->m_PlayerOptions.Assign(
      ModsLevel_Preferred, poOrig);
  GAMESTATE->m_SongOptions.Assign(ModsLevel_Preferred, soOrig);

  m_bRowCausesDisqualified[pn][row] = bRowCausesDisqualified;

  // Update disqualified graphic
  bool disqualified = std::any_of(
      m_bRowCausesDisqualified[pn].begin(), m_bRowCausesDisqualified[pn].end(),
      [](const bool& b) { return b; });

  if (m_sprDisqualify[pn].IsLoaded()) {
    m_sprDisqualify[pn]->SetVisible(disqualified);
  }
}

// lua start
#include "LuaBinding.h"

/** @brief Allow Lua to have access to the ScreenPlayerOptions. */
class LunaScreenPlayerOptions : public Luna<ScreenPlayerOptions> {
 public:
  static int GetGoToOptions(T* p, lua_State* L) {
    lua_pushboolean(L, p->GetGoToOptions());
    return 1;
  }

  LunaScreenPlayerOptions() { ADD_METHOD(GetGoToOptions); }
};

LUA_REGISTER_DERIVED_CLASS(ScreenPlayerOptions, ScreenOptions)
// lua end

/*
 * (c) 2001-2004 Chris Danford
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
