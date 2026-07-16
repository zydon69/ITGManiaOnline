#include "ScreenTestLights.h"

#include <string>

#include "ActorUtil.h"
#include "GameInput.h"
#include "InputEventPlus.h"
#include "InputFilter.h"
#include "InputMapper.h"
#include "LightsManager.h"
#include "LocalizedString.h"
#include "PlayerNumber.h"
#include "RageUtil.h"
#include "Screen.h"
#include "ScreenManager.h"
#include "ScreenMessage.h"
#include "ScreenWithMenuElements.h"
#include "ThemeManager.h"

REGISTER_SCREEN_CLASS(ScreenTestLights);

namespace {
bool HasLoadedTheme() { return THEME != nullptr && THEME->IsThemeLoaded(); }

bool IsValidGameButton(GameButton button) {
  return button >= GAME_BUTTON_MENULEFT && button < NUM_GameButton;
}

bool IsValidController(GameController controller) {
  return controller >= GameController_1 && controller < NUM_GameController;
}

bool IsValidTestPlayer(PlayerNumber player) {
  return player >= PLAYER_1 && player < NUM_PLAYERS;
}

bool IsValidCabinetLight(CabinetLight light) {
  return light >= 0 && light < NUM_CabinetLight;
}

bool IsCycleInputType(InputEventType type) {
  return type == IET_FIRST_PRESS || type == IET_REPEAT;
}

std::string SafeGameButtonString(const InputScheme* scheme, GameButton button) {
  if (scheme == nullptr || !IsValidGameButton(button)) {
    return "Invalid";
  }
  if (HasLoadedTheme()) {
    return GameButtonToLocalizedString(scheme, button);
  }
  return GameButtonToString(scheme, button);
}
}  // namespace

void ScreenTestLights::Init() {
  ScreenWithMenuElements::Init();

  m_bTextReady = false;
  m_textInputs.SetName("Text");
  if (HasLoadedTheme() &&
      m_textInputs.LoadFromFont(THEME->GetPathF("Common", "normal", true))) {
    m_bTextReady = true;
    m_textInputs.SetText("");
    LOAD_ALL_COMMANDS_AND_SET_XY(m_textInputs);
    this->AddChild(&m_textInputs);
  }
}

void ScreenTestLights::BeginScreen() {
  if (LIGHTSMAN != nullptr) {
    LIGHTSMAN->SetLightsMode(LIGHTSMODE_TEST_AUTO_CYCLE);
  }
  ScreenWithMenuElements::BeginScreen();
}

void ScreenTestLights::EndScreen() {
  if (LIGHTSMAN != nullptr) {
    LIGHTSMAN->SetLightsMode(LIGHTSMODE_MENU_START_AND_DIRECTIONS);
  }
  ScreenWithMenuElements::EndScreen();
}

static LocalizedString AUTO_CYCLE("ScreenTestLights", "Auto Cycle");
static LocalizedString MANUAL_CYCLE("ScreenTestLights", "Manual Cycle");
static LocalizedString CABINET_LIGHT("ScreenTestLights", "cabinet light");
static LocalizedString CONTROLLER_LIGHT("ScreenTestLights", "controller light");
void ScreenTestLights::Update(float fDeltaTime) {
  ScreenWithMenuElements::Update(fDeltaTime);

  if (LIGHTSMAN == nullptr) {
    if (m_bTextReady) {
      m_textInputs.SetText("");
    }
    return;
  }

  if (m_timerBackToAutoCycle.Ago() > 20) {
    m_timerBackToAutoCycle.Touch();
    LIGHTSMAN->SetLightsMode(LIGHTSMODE_TEST_AUTO_CYCLE);
  }

  CabinetLight cl = LIGHTSMAN->GetFirstLitCabinetLight();
  GameInput gi = LIGHTSMAN->GetFirstLitGameButtonLight();

  std::string s;

  switch (LIGHTSMAN->GetLightsMode()) {
    case LIGHTSMODE_TEST_AUTO_CYCLE:
      s += AUTO_CYCLE.GetValue() + "\n";
      break;
    case LIGHTSMODE_TEST_MANUAL_CYCLE:
      s += MANUAL_CYCLE.GetValue() + "\n";
      break;
    default:
      break;
  }

  if (!IsValidCabinetLight(cl)) {
    s += CABINET_LIGHT.GetValue() + ": -----\n";
  } else {
    s += ssprintf(
        "%s: %d %s\n", CABINET_LIGHT.GetValue().c_str(), cl,
        CabinetLightToString(cl).c_str());
  }

  if (!gi.IsValid() || !IsValidController(gi.controller) ||
      !IsValidGameButton(gi.button)) {
    s += CONTROLLER_LIGHT.GetValue() + ": -----\n";
  } else {
    const InputScheme* scheme =
        INPUTMAPPER != nullptr ? INPUTMAPPER->GetInputScheme() : nullptr;
    std::string sGameButton = SafeGameButtonString(scheme, gi.button);
    PlayerNumber pn = (PlayerNumber)(gi.controller);
    s += ssprintf(
        "%s: %s %d %s\n", CONTROLLER_LIGHT.GetValue().c_str(),
        PlayerNumberToString(pn).c_str(), gi.button, sGameButton.c_str());
  }

  if (m_bTextReady) {
    m_textInputs.SetText(s);
  }
}

bool ScreenTestLights::Input(const InputEventPlus& input) {
  if (input.type != IET_FIRST_PRESS && input.type != IET_REPEAT) {
    return ScreenWithMenuElements::Input(input);
  }

  return ScreenWithMenuElements::Input(input);  // default handler
}

bool ScreenTestLights::MenuLeft(const InputEventPlus& input) {
  if (LIGHTSMAN == nullptr || IsTransitioning() || m_fLockInputSecs > 0 ||
      !IsCycleInputType(input.type) || !IsValidTestPlayer(input.pn)) {
    return false;
  }
  if (LIGHTSMAN->GetLightsMode() != LIGHTSMODE_TEST_MANUAL_CYCLE) {
    LIGHTSMAN->SetLightsMode(LIGHTSMODE_TEST_MANUAL_CYCLE);
  }
  if (input.pn == PLAYER_1) {
    LIGHTSMAN->PrevTestCabinetLight();
  } else {
    LIGHTSMAN->PrevTestGameButtonLight();
  }
  m_timerBackToAutoCycle.Touch();
  return true;
}

bool ScreenTestLights::MenuRight(const InputEventPlus& input) {
  if (LIGHTSMAN == nullptr || IsTransitioning() || m_fLockInputSecs > 0 ||
      !IsCycleInputType(input.type) || !IsValidTestPlayer(input.pn)) {
    return false;
  }
  if (LIGHTSMAN->GetLightsMode() != LIGHTSMODE_TEST_MANUAL_CYCLE) {
    LIGHTSMAN->SetLightsMode(LIGHTSMODE_TEST_MANUAL_CYCLE);
  }
  if (input.pn == PLAYER_1) {
    LIGHTSMAN->NextTestCabinetLight();
  } else {
    LIGHTSMAN->NextTestGameButtonLight();
  }
  m_timerBackToAutoCycle.Touch();
  return true;
}

bool ScreenTestLights::MenuStart(const InputEventPlus& input) {
  return MenuBack(input);
}

bool ScreenTestLights::MenuBack(const InputEventPlus& input) {
  if (input.type != IET_FIRST_PRESS) {
    return false;
  }
  if (IsTransitioning() || m_fLockInputSecs > 0) {
    return false;
  }
  if (!HasLoadedTheme()) {
    return false;
  }
  if (SCREENMAN != nullptr) {
    SCREENMAN->PlayStartSound();
  }
  Cancel(SM_GoToPrevScreen);
  return true;
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
