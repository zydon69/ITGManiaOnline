#include "ScreenTitleMenu.h"

#include <string>
#include <vector>

#include "AnnouncerManager.h"
#include "CharacterManager.h"
#include "CodeDetector.h"
#include "CommonMetrics.h"
#include "GameLoop.h"
#include "GamePreferences.h"
#include "GameSoundManager.h"
#include "GameState.h"
#include "MemoryCardManager.h"
#include "InputEventPlus.h"
#include "InputFilter.h"
#include "LocalizedString.h"
#include "MessageManager.h"
#include "NoteSkinManager.h"
#include "PrefsManager.h"
#include "RageLog.h"
#include "RageUtil.h"
#include "Screen.h"
#include "ScreenManager.h"
#include "ScreenSelectMaster.h"
#include "SongManager.h"
#include "StatsManager.h"
#include "ThemeManager.h"

namespace {
bool g_bSkipNextTitleMenuReset = false;

void WarnTitleMenu(const std::string& message) {
  if (LOG != nullptr) {
    LOG->Warn("ScreenTitleMenu: %s", message.c_str());
  }
}

bool CanSafelyResetGameState() {
  return GAMESTATE != nullptr && THEME != nullptr && MEMCARDMAN != nullptr &&
         NOTESKIN != nullptr && SONGMAN != nullptr && STATSMAN != nullptr &&
         PREFSMAN != nullptr && CHARMAN != nullptr;
}

void ResetTitleMenuGameState() {
  if (g_bSkipNextTitleMenuReset) {
    g_bSkipNextTitleMenuReset = false;
    return;
  }

  if (!CanSafelyResetGameState()) {
    WarnTitleMenu(
        "Skipping title menu game-state reset because a required manager is "
        "not initialized.");
    return;
  }

  GAMESTATE->Reset();
}

bool IsValidTitleMenuController(GameController controller) {
  return controller >= GameController_1 && controller < NUM_GameController;
}

bool IsScreenUsable(const std::string& screenName) {
  return SCREENMAN != nullptr && THEME != nullptr && !screenName.empty() &&
         SCREENMAN->IsScreenNameValid(screenName);
}

bool SetNewScreenIfUsable(const std::string& screenName, const char* context) {
  if (!IsScreenUsable(screenName)) {
    WarnTitleMenu(
        std::string("Ignoring invalid ") + context + " screen '" +
        screenName + "'.");
    return false;
  }

  SCREENMAN->SetNewScreen(screenName);
  return true;
}

bool ReloadTitleMenuIfUsable(const std::string& screenName, const char* context) {
  if (!IsScreenUsable(screenName)) {
    WarnTitleMenu(
        std::string("Ignoring invalid ") + context + " reload screen '" +
        screenName + "'.");
    return false;
  }

  g_bSkipNextTitleMenuReset = true;
  SCREENMAN->SetNewScreen(screenName);
  return true;
}

bool GetNextSelectableThemeName(std::string& themeNameOut) {
  if (THEME == nullptr) {
    WarnTitleMenu("Cannot change theme because THEME is not initialized.");
    return false;
  }

  std::vector<std::string> themeNames;
  THEME->GetSelectableThemeNames(themeNames);
  if (themeNames.empty()) {
    WarnTitleMenu("Cannot change theme because no selectable theme exists.");
    return false;
  }

  const std::string currentTheme = THEME->GetCurThemeName();
  for (unsigned i = 0; i < themeNames.size(); ++i) {
    if (CompareNoCase(themeNames[i], currentTheme) == 0) {
      themeNameOut = themeNames[(i + 1) % themeNames.size()];
      return true;
    }
  }

  themeNameOut = themeNames.front();
  return true;
}

std::string GetCoinModeChangeScreen(const std::string& screenName) {
  if (THEME == nullptr || !THEME->IsThemeLoaded() ||
      !THEME->HasMetric(screenName, "CoinModeChangeScreen")) {
    return std::string();
  }

  return THEME->GetMetric(screenName, "CoinModeChangeScreen");
}
}  // namespace

REGISTER_SCREEN_CLASS(ScreenTitleMenu);
ScreenTitleMenu::ScreenTitleMenu() {
  /* XXX We really need two common calls:
   * 1) something run when exiting from gameplay (to do this reset),
   * and 2) something run when entering gameplay, to apply default options.
   * Having special cases in attract screens and the title menu to reset
   * things stinks ...
   * [aj] Well... Can't #2 be done in Lua nowadays? and #1 as well? (hi shake)
   */
  ResetTitleMenuGameState();

  const std::string coinModeChangedMessage =
      GamePreferences::m_CoinMode.GetName() + "Changed";
  if (MESSAGEMAN != nullptr && !coinModeChangedMessage.empty()) {
    this->SubscribeToMessage(coinModeChangedMessage);
  } else {
    WarnTitleMenu("Cannot subscribe to coin-mode changes.");
  }
}

void ScreenTitleMenu::Init() {
  ScreenSelectMaster::Init();

  if (SOUND != nullptr) {
    SOUND->PlayOnceFromAnnouncer("title menu game name");
  } else {
    WarnTitleMenu("Cannot play title announcer because SOUND is not initialized.");
  }
}

static LocalizedString ANNOUNCER_("ScreenTitleMenu", "Announcer");
bool ScreenTitleMenu::Input(const InputEventPlus& input) {
#if defined(DEBUG)
  if (LOG != nullptr) {
    LOG->Trace(
        "ScreenTitleMenu::Input( %d-%d )", input.DeviceI.device,
        input.DeviceI.button);  // debugging gameport joystick problem
  }
#endif

  if (IsTransitioning()) {
    return false;
  }

  if (input.type == IET_FIRST_PRESS &&
      IsValidTitleMenuController(input.GameI.controller)) {
    // detect codes
    if (CodeDetector::EnteredCode(input.GameI.controller, CODE_OPERATOR_MENU)) {
      SetNewScreenIfUsable(
          CommonMetrics::OPERATOR_MENU_SCREEN.GetValue(), "operator menu");
      return true;
    }
    // Theme changing pad codes are marked as deprecated in _fallback's
    // metrics.ini, remove them after SM5? -Kyz
    if (CodeDetector::EnteredCode(input.GameI.controller, CODE_NEXT_THEME) ||
        CodeDetector::EnteredCode(input.GameI.controller, CODE_NEXT_THEME2)) {
      std::string nextTheme;
      if (GetNextSelectableThemeName(nextTheme)) {
        GameLoop::ChangeTheme(nextTheme);
      }
      return true;
    }
    if (CodeDetector::EnteredCode(
            input.GameI.controller, CODE_NEXT_ANNOUNCER) ||
        CodeDetector::EnteredCode(
            input.GameI.controller, CODE_NEXT_ANNOUNCER2)) {
      if (ANNOUNCER == nullptr) {
        WarnTitleMenu(
            "Cannot change announcer because ANNOUNCER is not initialized.");
        return true;
      }

      ANNOUNCER->NextAnnouncer();
      std::string sName = ANNOUNCER->GetCurAnnouncerName();
      if (sName == "") {
        sName = "(none)";
      }
      if (SCREENMAN != nullptr && MESSAGEMAN != nullptr) {
        SCREENMAN->SystemMessage(ANNOUNCER_.GetValue() + ": " + sName);
      }
      ReloadTitleMenuIfUsable(m_sName, "announcer");
      return true;
    }
  }

  return ScreenSelectMaster::Input(input);
}

void ScreenTitleMenu::HandleMessage(const Message& msg) {
  if (msg == GamePreferences::m_CoinMode.GetName() + "Changed") {
    /* If the CoinMode was changed, we need to reload this screen
     * so that the right m_aGameCommands will show */
    const std::string coinModeChangeScreen = GetCoinModeChangeScreen(m_sName);
    ReloadTitleMenuIfUsable(coinModeChangeScreen, "coin-mode change");
    return;
  }

  ScreenSelectMaster::HandleMessage(msg);
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
