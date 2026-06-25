#include "ScreenOptionsMaster.h"

#include <string>
#include <vector>

#include "Command.h"
#include "GameLoop.h"
#include "GameState.h"
#include "LuaManager.h"
#include "OptionRowHandler.h"
#include "PerfDiagnostics.h"
#include "PlayerNumber.h"
#include "PrefsManager.h"
#include "ProfileManager.h"
#include "RageLog.h"
#include "RageSoundManager.h"
#include "RageThreads.h"
#include "RageUtil.h"
#include "Screen.h"
#include "ScreenManager.h"
#include "ScreenMessage.h"
#include "ScreenOptions.h"
#include "ScreenOptionsMasterPrefs.h"
#include "SongManager.h"
#include "ThemeManager.h"
#include "global.h"

REGISTER_SCREEN_CLASS(ScreenOptionsMaster);

namespace {
bool HasOptionsMasterTheme() {
  return THEME != nullptr && THEME->IsThemeLoaded();
}

bool IsScreenOptionsMasterPlayerValid(PlayerNumber pn) {
  return pn >= PLAYER_1 && pn < NUM_PLAYERS;
}

bool IsScreenOptionsMasterHumanPlayer(PlayerNumber pn) {
  return GAMESTATE != nullptr && IsScreenOptionsMasterPlayerValid(pn) &&
         GAMESTATE->IsHumanPlayer(pn) &&
         GAMESTATE->m_pPlayerState[pn] != nullptr;
}

void WarnScreenOptionsMaster(const std::string& message) {
  if (LOG != nullptr) {
    LOG->Warn("%s", message.c_str());
  }
}

std::string GetOptionsMasterMetric(
    const std::string& screenName, const std::string& metricName) {
  if (!HasOptionsMasterTheme() || !THEME->HasMetric(screenName, metricName)) {
    return std::string();
  }
  return THEME->GetMetric(screenName, metricName);
}

bool GetOptionsMasterMetricB(
    const std::string& screenName, const std::string& metricName) {
  if (!HasOptionsMasterTheme() || !THEME->HasMetric(screenName, metricName)) {
    return false;
  }
  return THEME->GetMetricB(screenName, metricName);
}

void ApplyOptionsMasterEffects(
    int changeMask, const std::string& screenName) {
  if (changeMask & OPT_APPLY_PROFILES) {
    if (PROFILEMAN != nullptr) {
      PROFILEMAN->RefreshLocalProfilesFromDisk();
    } else {
      WarnScreenOptionsMaster(
          ssprintf("%s: cannot refresh profiles without ProfileManager",
                   screenName.c_str()));
    }
  }

  if (changeMask & OPT_APPLY_ASPECT_RATIO) {
    if (HasOptionsMasterTheme() && SCREENMAN != nullptr) {
      THEME->UpdateLuaGlobals();   // This needs to be done before resetting the
                                   // projection matrix below
      THEME->ReloadSubscribers();  // SCREEN_* has changed, so re-read all
                                   // subscribing ThemeMetrics
      SCREENMAN->ThemeChanged();   // recreate ScreenSystemLayer and SharedBGA
    } else {
      WarnScreenOptionsMaster(
          ssprintf("%s: cannot apply aspect ratio without theme/screen manager",
                   screenName.c_str()));
    }
  }

  /* If the theme changes, we need to reset RageDisplay to apply the new
   * window title and icon. If the aspect ratio changes, we need to reset
   * RageDisplay so that the projection matrix is re-created using the new
   * screen dimensions. */
  if ((changeMask & OPT_APPLY_THEME) || (changeMask & OPT_APPLY_GRAPHICS) ||
      (changeMask & OPT_APPLY_ASPECT_RATIO)) {
    if (PREFSMAN != nullptr) {
      /* If the resolution or aspect ratio changes, always reload the theme.
       * Otherwise, only reload it if it changed. */
      std::string sNewTheme = PREFSMAN->m_sTheme.Get();
      GameLoop::ChangeTheme(sNewTheme);
    } else {
      WarnScreenOptionsMaster(
          ssprintf("%s: cannot change theme/game graphics without PrefsManager",
                   screenName.c_str()));
    }
  }

  if (changeMask & OPT_SAVE_PREFERENCES) {
    if (LOG != nullptr) {
      LOG->Trace("ROW_CONFIG used; saving ...");
    }
    if (PREFSMAN != nullptr) {
      PREFSMAN->SavePrefsToDisk();
    } else {
      WarnScreenOptionsMaster(
          ssprintf("%s: cannot save preferences without PrefsManager",
                   screenName.c_str()));
    }
  }

  if (changeMask & OPT_APPLY_LOGGING) {
    RefreshPerfDiagnosticsPreferenceCache();
    if (PREFSMAN != nullptr && LOG != nullptr) {
      LOG->SetShowLogOutput(PREFSMAN->m_bShowLogOutput);
      LOG->SetLogToDisk(PREFSMAN->m_bLogToDisk);
      LOG->SetInfoToDisk(PREFSMAN->m_bLogToDisk);
      LOG->SetUserLogToDisk(PREFSMAN->m_bLogToDisk);
      LOG->SetFlushing(PREFSMAN->m_bForceLogFlush);
      Checkpoints::LogCheckpoints(PREFSMAN->m_bLogCheckpoints);
    } else {
      WarnScreenOptionsMaster(
          ssprintf("%s: cannot apply logging without PrefsManager/log",
                   screenName.c_str()));
    }
  }

  if (changeMask & OPT_CHANGE_GAME) {
    if (PREFSMAN != nullptr) {
      GameLoop::ChangeGame(PREFSMAN->GetCurrentGame());
    } else {
      WarnScreenOptionsMaster(
          ssprintf("%s: cannot change game without PrefsManager",
                   screenName.c_str()));
    }
  }

  if (changeMask & OPT_APPLY_SOUND) {
    if (SOUNDMAN != nullptr) {
      SOUNDMAN->SetMixVolume();
    } else {
      WarnScreenOptionsMaster(
          ssprintf("%s: cannot apply sound without SoundManager",
                   screenName.c_str()));
    }
  }

  if (changeMask & OPT_APPLY_SONG) {
    if (SONGMAN != nullptr) {
      SONGMAN->SetPreferences();
    } else {
      WarnScreenOptionsMaster(
          ssprintf("%s: cannot apply song preferences without SongManager",
                   screenName.c_str()));
    }
  }
}
}  // namespace

ScreenOptionsMaster::ScreenOptionsMaster() : m_iChangeMask(0) {}

void ScreenOptionsMaster::Init() {
  std::vector<std::string> asLineNames;
  split(GetOptionsMasterMetric(m_sName, "LineNames"), ",", asLineNames);
  if (asLineNames.empty()) {
    LuaHelpers::ReportScriptErrorFmt(
        "\"%s:LineNames\" is empty.", m_sName.c_str());
  }

  if (GetOptionsMasterMetricB(m_sName, "ForceAllPlayers")) {
    if (GAMESTATE != nullptr) {
      FOREACH_PlayerNumber(pn) GAMESTATE->JoinPlayer(pn);
    } else {
      WarnScreenOptionsMaster(
          ssprintf("%s: cannot force players without GameState",
                   m_sName.c_str()));
    }
  }

  const std::string navigationMode =
      GetOptionsMasterMetric(m_sName, "NavigationMode");
  if (navigationMode == "toggle") {
    SetNavigation(
        PREFSMAN != nullptr && PREFSMAN->m_iArcadeOptionsNavigation
            ? NAV_TOGGLE_THREE_KEY
            : NAV_TOGGLE_FIVE_KEY);
  } else if (navigationMode == "menu") {
    SetNavigation(NAV_THREE_KEY_MENU);
  }

  const InputMode inputMode =
      StringToInputMode(GetOptionsMasterMetric(m_sName, "InputMode"));
  SetInputMode(
      inputMode == InputMode_Invalid ? INPUTMODE_SHARE_CURSOR : inputMode);

  // Call this after enabling players, if any.
  ScreenOptions::Init();

  std::vector<OptionRowHandler*> OptionRowHandlers;
  for (unsigned i = 0; i < asLineNames.size(); ++i) {
    std::string sLineName = asLineNames[i];
    std::string sMetricName = ssprintf("Line%s", sLineName.c_str());
    std::string sRowCommands = GetOptionsMasterMetric(m_sName, sMetricName);
    if (sRowCommands.empty()) {
      LuaHelpers::ReportScriptErrorFmt(
          "Missing OptionRow metric \"%s:%s\".", m_sName.c_str(),
          sMetricName.c_str());
      continue;
    }

    Commands cmds;
    ParseCommands(sRowCommands, cmds, false);

    OptionRowHandler* pHand = OptionRowHandlerUtil::Make(cmds);
    if (pHand == nullptr) {
      LuaHelpers::ReportScriptErrorFmt(
          "Invalid OptionRowHandler \"%s\" in \"%s:Line:%s\".",
          cmds.GetOriginalCommandString().c_str(), m_sName.c_str(),
          sLineName.c_str());
    } else {
      OptionRowHandlers.push_back(pHand);
    }
  }
  InitMenu(OptionRowHandlers);
}

void ScreenOptionsMaster::ImportOptions(
    int r, const std::vector<PlayerNumber>& vpns) {
  OptionRow* row = GetRow(r);
  if (row == nullptr) {
    WarnScreenOptionsMaster(
        ssprintf("ScreenOptionsMaster::ImportOptions(%s): invalid row %d",
                 m_sName.c_str(), r));
    return;
  }

  std::vector<PlayerNumber> validPlayers;
  for (const PlayerNumber& pn : vpns) {
    if (IsScreenOptionsMasterHumanPlayer(pn)) {
      validPlayers.push_back(pn);
    }
  }
  if (validPlayers.empty()) {
    return;
  }
  row->ImportOptions(validPlayers);
}

bool ScreenOptionsMaster::ExportOptionsInternal(
    int r, const std::vector<PlayerNumber>& vpns, bool accumulateChangeMask,
    int* changeMaskOut) {
  if (changeMaskOut != nullptr) {
    *changeMaskOut = 0;
  }

  CHECKPOINT_M(ssprintf("%i/%i", r, int(m_pRows.size())));

  OptionRow* row = GetRow(r);
  if (row == nullptr) {
    WarnScreenOptionsMaster(
        ssprintf("ScreenOptionsMaster::ExportOptions(%s): invalid row %d",
                 m_sName.c_str(), r));
    return false;
  }

  bool bRowHasFocus[NUM_PLAYERS];
  ZERO(bRowHasFocus);
  std::vector<PlayerNumber> validPlayers;
  for (const PlayerNumber& p : vpns) {
    if (!IsScreenOptionsMasterHumanPlayer(p)) {
      continue;
    }
    int iCurRow = m_iCurrentRow[p];
    bRowHasFocus[p] = iCurRow == r;
    validPlayers.push_back(p);
  }
  if (validPlayers.empty()) {
    return false;
  }

  const int changeMask = row->ExportOptions(validPlayers, bRowHasFocus);
  if (changeMaskOut != nullptr) {
    *changeMaskOut = changeMask;
  }
  if (accumulateChangeMask) {
    m_iChangeMask |= changeMask;
  }
  return true;
}

void ScreenOptionsMaster::ExportOptions(
    int r, const std::vector<PlayerNumber>& vpns) {
  ExportOptionsInternal(r, vpns, true, nullptr);
}

bool ScreenOptionsMaster::ExportOptionsAndGetChangeMask(
    int r, const std::vector<PlayerNumber>& vpns, int* changeMaskOut) {
  return ExportOptionsInternal(r, vpns, true, changeMaskOut);
}

int ScreenOptionsMaster::ExportOptionsForPreview(
    int r, const std::vector<PlayerNumber>& vpns) {
  const int savedChangeMask = m_iChangeMask;
  int changeMask = 0;
  ExportOptionsInternal(r, vpns, false, &changeMask);
  m_iChangeMask = savedChangeMask;
  return changeMask;
}

void ScreenOptionsMaster::HandleScreenMessage(const ScreenMessage SM) {
  if (SM == SM_ExportOptions) {
    // Override ScreenOptions's calling of ExportOptions
    m_iChangeMask = 0;

    CHECKPOINT_M("Starting the export handling.");

    std::vector<PlayerNumber> vpns;
    FOREACH_OptionsPlayer(p) vpns.push_back(p);
    for (unsigned r = 0; r < m_pRows.size(); r++) {  // foreach row
      ExportOptions(r, vpns);
    }

    ApplyOptionsMasterEffects(m_iChangeMask, m_sName);

    if (m_iChangeMask & OPT_RELOAD_SONGS) {
      if (SCREENMAN != nullptr && SCREENMAN->GetTopScreen() != nullptr) {
        SCREENMAN->GetTopScreen()->SetNextScreenName("ScreenReloadSongs");
        StartTransitioningScreen(SM_GoToNextScreen);
      } else {
        WarnScreenOptionsMaster(
            ssprintf("%s: cannot reload songs without a top screen",
                     m_sName.c_str()));
      }
    }

    CHECKPOINT_M("Transferring to the next screen now.");
    this->HandleScreenMessage(SM_GoToNextScreen);
    return;
  } else {
    ScreenOptions::HandleScreenMessage(SM);
  }
}

/*
 * (c) 2003-2004 Glenn Maynard
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
