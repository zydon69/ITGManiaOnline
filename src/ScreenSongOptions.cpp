#include "ScreenSongOptions.h"

#include <array>
#include <string>
#include <vector>

#include "GameState.h"
#include "PlayerState.h"
#include "PrefsManager.h"
#include "RageLog.h"
#include "ScreenOptionsMaster.h"
#include "ThemeManager.h"

namespace {
const char* OPTION_IN = "option in";

bool HasLoadedTheme() { return THEME != nullptr && THEME->IsThemeLoaded(); }

bool IsValidPlayerNumberForSongOptions(PlayerNumber pn) {
  return pn >= PLAYER_1 && pn < NUM_PLAYERS;
}

bool ContainsPlayer(const std::vector<PlayerNumber>& players, PlayerNumber pn) {
  for (const PlayerNumber player : players) {
    if (player == pn) {
      return true;
    }
  }
  return false;
}

bool AddExportPlayer(
    std::vector<PlayerNumber>& players, PlayerNumber pn, bool logFailure) {
  if (!IsValidPlayerNumberForSongOptions(pn) || GAMESTATE == nullptr ||
      GAMESTATE->m_pPlayerState[pn] == nullptr || !GAMESTATE->IsHumanPlayer(pn)) {
    if (logFailure && LOG != nullptr) {
      LOG->Warn(
          "ScreenSongOptions ignored non-exportable "
          "player %d while exporting options.",
          static_cast<int>(pn));
    }
    return false;
  }

  if (!ContainsPlayer(players, pn)) {
    players.push_back(pn);
  }
  return true;
}

struct FailTypeSnapshot {
  bool valid = false;
  FailType preferred = FailType_Invalid;
  FailType stage = FailType_Invalid;
  FailType song = FailType_Invalid;
  FailType current = FailType_Invalid;
};

FailTypeSnapshot CaptureFailTypes(PlayerNumber pn) {
  FailTypeSnapshot snapshot;
  if (!IsValidPlayerNumberForSongOptions(pn) || GAMESTATE == nullptr ||
      GAMESTATE->m_pPlayerState[pn] == nullptr) {
    return snapshot;
  }

  const auto& options = GAMESTATE->m_pPlayerState[pn]->m_PlayerOptions;
  snapshot.valid = true;
  snapshot.preferred = options.GetPreferred().m_FailType;
  snapshot.stage = options.GetStage().m_FailType;
  snapshot.song = options.GetSong().m_FailType;
  snapshot.current = options.GetCurrent().m_FailType;
  return snapshot;
}

bool FailTypeChanged(PlayerNumber pn, const FailTypeSnapshot& before) {
  if (!before.valid || !IsValidPlayerNumberForSongOptions(pn) ||
      GAMESTATE == nullptr || GAMESTATE->m_pPlayerState[pn] == nullptr) {
    return false;
  }

  const auto& options = GAMESTATE->m_pPlayerState[pn]->m_PlayerOptions;
  return before.preferred != options.GetPreferred().m_FailType ||
         before.stage != options.GetStage().m_FailType ||
         before.song != options.GetSong().m_FailType ||
         before.current != options.GetCurrent().m_FailType;
}
}  // namespace

REGISTER_SCREEN_CLASS(ScreenSongOptions);

void ScreenSongOptions::Init() {
  const Maybe showSongOptions =
      PREFSMAN != nullptr ? PREFSMAN->m_ShowSongOptions.Get() : Maybe_NO;

  ScreenOptionsMaster::Init();

  if (PREFSMAN == nullptr) {
    if (LOG != nullptr) {
      LOG->Warn(
          "ScreenSongOptions has no PrefsManager; "
          "using the parent transition.");
    }
    return;
  }

  if (showSongOptions != Maybe_ASK) {
    return;
  }

  if (!HasLoadedTheme()) {
    if (LOG != nullptr) {
      LOG->Warn(
          "ScreenSongOptions has no loaded theme; "
          "using the parent transition.");
    }
    return;
  }

  // This fade is optional and should never replace the normal screen
  // transition unless the active theme explicitly provides it.
  if (!THEME->HasMetric(m_sName, OPTION_IN)) {
    return;
  }

  const std::string optionInPath = THEME->GetPathB(m_sName, OPTION_IN, true);
  if (optionInPath.empty()) {
    if (LOG != nullptr) {
      LOG->Warn(
          "ScreenSongOptions option-in transition is "
          "declared but missing; using the parent transition.");
    }
    return;
  }

  m_In.Load(optionInPath);
}

void ScreenSongOptions::ExportOptions(
    int iRow, const std::vector<PlayerNumber>& vpns) {
  if (GAMESTATE == nullptr) {
    if (LOG != nullptr) {
      LOG->Warn(
          "ScreenSongOptions cannot export without "
          "GameState.");
    }
    return;
  }

  if (iRow < 0 || iRow >= GetNumRows() || GetRow(iRow) == nullptr) {
    if (LOG != nullptr) {
      LOG->Warn(
          "ScreenSongOptions ignored invalid row %d "
          "while exporting options.",
          iRow);
    }
    return;
  }

  std::vector<PlayerNumber> exportPlayers;
  for (const PlayerNumber pn : vpns) {
    AddExportPlayer(exportPlayers, pn, false);
  }

  const PlayerNumber masterPlayer = GAMESTATE->GetMasterPlayerNumber();
  if (exportPlayers.empty() &&
      !AddExportPlayer(exportPlayers, masterPlayer, true)) {
    return;
  }

  std::array<FailTypeSnapshot, NUM_PLAYERS> before;
  for (const PlayerNumber pn : exportPlayers) {
    before[pn] = CaptureFailTypes(pn);
  }
  if (IsValidPlayerNumberForSongOptions(masterPlayer) &&
      !ContainsPlayer(exportPlayers, masterPlayer)) {
    before[masterPlayer] = CaptureFailTypes(masterPlayer);
  }

  if (!ScreenOptionsMaster::ExportOptionsAndGetChangeMask(
          iRow, exportPlayers, nullptr)) {
    if (LOG != nullptr) {
      LOG->Warn(
          "ScreenSongOptions row %d produced no "
          "export.",
          iRow);
    }
    return;
  }

  if (GAMESTATE == nullptr) {
    return;
  }

  for (PlayerNumber pn = PLAYER_1; pn < NUM_PLAYERS; enum_add(pn, 1)) {
    if (FailTypeChanged(pn, before[pn])) {
      GAMESTATE->m_bFailTypeWasExplicitlySet = true;
      break;
    }
  }
}

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
