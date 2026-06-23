#include "ScreenTestInput.h"

#include <string>
#include <vector>

#include "ActorUtil.h"
#include "BitmapText.h"
#include "GameInput.h"
#include "InputEventPlus.h"
#include "InputFilter.h"
#include "InputMapper.h"
#include "LocalizedString.h"
#include "MessageManager.h"
#include "PrefsManager.h"
#include "RageInput.h"
#include "RageInputDevice.h"
#include "RageUtil.h"
#include "Screen.h"
#include "ScreenManager.h"
#include "ScreenMessage.h"
#include "ThemeManager.h"

namespace {
bool IsValidGameController(GameController controller) {
  return controller >= GameController_1 && controller < NUM_GameController;
}

bool IsValidGameButton(GameButton button) {
  return button >= GAME_BUTTON_MENULEFT && button < NUM_GameButton;
}

std::string SanitizeInputMessageName(const std::string& raw) {
  std::string out;
  out.reserve(raw.size());
  for (char c : raw) {
    const bool ok = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
                    (c >= '0' && c <= '9') || c == '_';
    out += ok ? c : '_';
  }
  return out.empty() ? "UnknownInput" : out;
}

std::string SafeDeviceInputString(const DeviceInput& di) {
  return INPUTMAN != nullptr ? INPUTMAN->GetDeviceSpecificInputString(di)
                             : di.ToString();
}

std::string SafeGameButtonString(const InputScheme* scheme, GameButton button) {
  if (scheme == nullptr || !IsValidGameButton(button)) {
    return "Invalid";
  }
  if (THEME != nullptr && THEME->IsThemeLoaded()) {
    return GameButtonToLocalizedString(scheme, button);
  }
  return GameButtonToString(scheme, button);
}
}  // namespace

class DeviceList : public BitmapText {
 public:
  void Update(float fDeltaTime) override {
    // Update devices text
    this->SetText(
        INPUTMAN != nullptr ? INPUTMAN->GetDisplayDevicesString() : "");

    BitmapText::Update(fDeltaTime);
  }

  DeviceList* Copy() const override;
};

REGISTER_ACTOR_CLASS(DeviceList);

static LocalizedString CONTROLLER("ScreenTestInput", "Controller");
static LocalizedString SECONDARY("ScreenTestInput", "secondary");
static LocalizedString NOT_MAPPED("ScreenTestInput", "not mapped");
class InputList : public BitmapText {
  InputList* Copy() const override;

  void Update(float fDeltaTime) override {
    // Update input texts
    std::vector<std::string> asInputs;

    std::vector<DeviceInput> DeviceInputs;
    if (INPUTFILTER == nullptr) {
      this->SetText("");
      BitmapText::Update(fDeltaTime);
      return;
    }

    INPUTFILTER->GetPressedButtons(DeviceInputs);
    const InputScheme* scheme =
        INPUTMAPPER != nullptr ? INPUTMAPPER->GetInputScheme() : nullptr;
    for (const DeviceInput& di : DeviceInputs) {
      if (!di.bDown && di.level == 0.0f) {
        continue;
      }

      std::string sTemp;
      sTemp += SafeDeviceInputString(di);
      if (di.level == 1.0f) {
        sTemp += ssprintf(" - 1 ");
      } else {
        sTemp += ssprintf(" - %.3f ", di.level);
      }

      GameInput gi;
      if (INPUTMAPPER != nullptr && scheme != nullptr &&
          INPUTMAPPER->DeviceToGame(di, gi) &&
          IsValidGameController(gi.controller) && IsValidGameButton(gi.button)) {
        std::string sName = SafeGameButtonString(scheme, gi.button);
        sTemp += ssprintf(
            " - %s %d %s", CONTROLLER.GetValue().c_str(), gi.controller + 1,
            sName.c_str());

        if (PREFSMAN != nullptr && !PREFSMAN->m_bOnlyDedicatedMenuButtons) {
          GameButton mb = scheme->GameButtonToMenuButton(gi.button);
          if (mb != GameButton_Invalid && mb != gi.button) {
            std::string sGameButtonString = SafeGameButtonString(scheme, mb);
            sTemp += ssprintf(
                " - (%s %s)", sGameButtonString.c_str(),
                SECONDARY.GetValue().c_str());
          }
        }
      } else {
        sTemp += " - " + NOT_MAPPED.GetValue();
      }

      std::string sComment = INPUTFILTER->GetButtonComment(di);
      if (sComment != "") {
        sTemp += " - " + sComment;
      }

      asInputs.push_back(sTemp);
    }

    this->SetText(join("\n", asInputs));

    BitmapText::Update(fDeltaTime);
  }
};

REGISTER_ACTOR_CLASS(InputList);

REGISTER_SCREEN_CLASS(ScreenTestInput);

bool ScreenTestInput::Input(const InputEventPlus& input) {
  const bool bParentHandled = Screen::Input(input);
  if (bParentHandled) {
    return true;
  }

  std::string sMessage = SanitizeInputMessageName(input.DeviceI.ToString());
  bool bHandled = false;
  switch (input.type) {
    case IET_FIRST_PRESS:
    case IET_RELEASE: {
      switch (input.type) {
        case IET_FIRST_PRESS:
          sMessage += "Pressed";
          break;
        case IET_RELEASE:
          sMessage += "Released";
          break;
        default:
          break;
      }
      if (MESSAGEMAN != nullptr) {
        MESSAGEMAN->Broadcast(sMessage);
        bHandled = true;
      }
      break;
    }
    default:
      break;
  }

  return bHandled;
}

bool ScreenTestInput::MenuStart(const InputEventPlus& input) {
  return MenuBack(input);
}

bool ScreenTestInput::MenuBack(const InputEventPlus& input) {
  if (input.type != IET_FIRST_PRESS) {
    return false;  // ignore
  }

  if (IsTransitioning() || m_fLockInputSecs > 0) {
    return false;
  }
  if (THEME == nullptr || !THEME->IsThemeLoaded()) {
    return false;
  }
  if (SCREENMAN != nullptr) {
    SCREENMAN->PlayStartSound();
  }
  Cancel(SM_GoToPrevScreen);
  return true;
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
