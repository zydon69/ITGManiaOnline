#include "ControllerStateDisplay.h"

#include <memory>
#include <string>

#include "ActorFrame.h"
#include "ActorUtil.h"
#include "EnumHelper.h"
#include "GameInput.h"
#include "GameState.h"
#include "InputMapper.h"
#include "LuaBinding.h"
#include "LuaManager.h"
#include "PlayerNumber.h"
#include "RageLog.h"
#include "RageInput.h"
#include "RageInputDevice.h"
#include "Style.h"
#include "ThemeManager.h"
#include "global.h"

static const char* ControllerStateButtonNames[] = {
    "UpLeft", "UpRight", "Center", "DownLeft", "DownRight",
};
XToString(ControllerStateButton);

static const GameButton ControllerStateButtonToGameButton[] = {
    PUMP_BUTTON_UPLEFT,   PUMP_BUTTON_UPRIGHT,   PUMP_BUTTON_CENTER,
    PUMP_BUTTON_DOWNLEFT, PUMP_BUTTON_DOWNRIGHT,
};
static_assert(
    sizeof(ControllerStateButtonToGameButton) /
            sizeof(ControllerStateButtonToGameButton[0]) ==
        NUM_ControllerStateButton,
    "ControllerStateButtonToGameButton must match ControllerStateButton.");

namespace {
void WarnControllerStateDisplay(const char* message) {
  if (LOG != nullptr) {
    LOG->Warn("%s", message);
  }
}

bool IsValidControllerStateMultiPlayer(MultiPlayer mp) {
  return mp >= MultiPlayer_P1 && mp < NUM_MultiPlayer;
}

bool IsValidControllerStateGameController(GameController gc) {
  return gc >= GameController_1 && gc < NUM_GameController;
}

bool StyleMapsGameButton(
    const Style* style, GameController gc, GameButton button) {
  if (style == nullptr || !IsValidControllerStateGameController(gc) ||
      button < 0 || button >= NUM_GameButton) {
    return true;
  }

  const int column = style->m_iInputColumn[gc][button];
  return column != Style::NO_MAPPING && column != Style::END_MAPPING;
}

GameButton ResolveControllerStateButton(
    ControllerStateButton button, GameController gc) {
  if (button < 0 || button >= NUM_ControllerStateButton) {
    return GameButton_Invalid;
  }

  const GameButton candidate = ControllerStateButtonToGameButton[button];
  const Style* style =
      GAMESTATE == nullptr ? nullptr : GAMESTATE->GetCurrentStyle(PLAYER_INVALID);
  if (!StyleMapsGameButton(style, gc, candidate)) {
    return GameButton_Invalid;
  }
  return candidate;
}
}  // namespace

REGISTER_ACTOR_CLASS(ControllerStateDisplay);

ControllerStateDisplay::ControllerStateDisplay() {
  m_bIsLoaded = false;
  m_mp = MultiPlayer_Invalid;
  m_gc = GameController_Invalid;
  m_idsLast = InputDeviceState_Invalid;
}

ControllerStateDisplay::ControllerStateDisplay(
    const ControllerStateDisplay& cpy)
    : ActorFrame(cpy) {
  m_mp = cpy.m_mp;
  m_gc = cpy.m_gc;
  m_bIsLoaded = cpy.m_bIsLoaded;
  m_sprFrame = cpy.m_sprFrame;
  for (int i = 0; i < NUM_ControllerStateButton; ++i) {
    m_Buttons[i] = cpy.m_Buttons[i];
  }
  m_idsLast = cpy.m_idsLast;
  AttachLoadedActors();
}

void ControllerStateDisplay::LoadMultiPlayer(
    std::string sType, MultiPlayer mp) {
  LoadInternal(sType, mp, GameController_1);
}

void ControllerStateDisplay::LoadGameController(
    std::string sType, GameController gc) {
  LoadInternal(sType, MultiPlayer_Invalid, gc);
}

void ControllerStateDisplay::LoadInternal(
    std::string sType, MultiPlayer mp, GameController gc) {
  ClearLoadedActors();
  if (sType.empty() || THEME == nullptr) {
    WarnControllerStateDisplay(
        "ControllerStateDisplay skipped load without "
        "theme or type.");
    return;
  }
  if (mp != MultiPlayer_Invalid && !IsValidControllerStateMultiPlayer(mp)) {
    WarnControllerStateDisplay(
        "ControllerStateDisplay ignored invalid "
        "multiplayer.");
    return;
  }
  if (!IsValidControllerStateGameController(gc)) {
    WarnControllerStateDisplay(
        "ControllerStateDisplay ignored invalid game "
        "controller.");
    return;
  }

  m_bIsLoaded = true;
  m_mp = mp;
  m_gc = gc;
  m_idsLast = InputDeviceState_Invalid;

  std::unique_ptr<LuaThreadVariable> varElement;
  if (LUA != nullptr) {
    varElement.reset(
        new LuaThreadVariable("MultiPlayer", LuaReference::Create(m_mp)));
  }

  const std::string sFramePath = THEME->GetPathG(sType, "frame");
  if (!sFramePath.empty()) {
    m_sprFrame.Load(sFramePath);
  }

  FOREACH_ENUM(ControllerStateButton, b) {
    Button& button = m_Buttons[b];

    std::string sPath =
        THEME->GetPathG(sType, ControllerStateButtonToString(b));
    if (!sPath.empty()) {
      button.spr.Load(sPath);
    }

    const GameButton gb = ResolveControllerStateButton(b, gc);
    if (gb == GameButton_Invalid) {
      button.gi.MakeInvalid();
    } else {
      button.gi = GameInput(gc, gb);
    }
  }

  AttachLoadedActors();
}

void ControllerStateDisplay::ClearLoadedActors() {
  RemoveAllChildren();
  m_sprFrame.Unload();
  FOREACH_ENUM(ControllerStateButton, b) {
    m_Buttons[b].spr.Unload();
    m_Buttons[b].gi.MakeInvalid();
  }
  m_bIsLoaded = false;
  m_mp = MultiPlayer_Invalid;
  m_gc = GameController_Invalid;
  m_idsLast = InputDeviceState_Invalid;
}

void ControllerStateDisplay::AttachLoadedActors() {
  RemoveAllChildren();
  if (m_sprFrame.IsLoaded()) {
    this->AddChild(m_sprFrame);
  }
  FOREACH_ENUM(ControllerStateButton, b) {
    if (m_Buttons[b].spr.IsLoaded()) {
      this->AddChild(m_Buttons[b].spr);
    }
  }
}

void ControllerStateDisplay::Update(float fDelta) {
  ActorFrame::Update(fDelta);

  if (!m_bIsLoaded) {
    return;
  }

  if (m_mp != MultiPlayer_Invalid && IsValidControllerStateMultiPlayer(m_mp) &&
      INPUTMAN != nullptr) {
    InputDevice id = InputMapper::MultiPlayerToInputDevice(m_mp);
    InputDeviceState ids = INPUTMAN->GetInputDeviceState(id);
    if (ids != m_idsLast) {
      PlayCommand(InputDeviceStateToString(ids));
    }
    m_idsLast = ids;
  }

  FOREACH_ENUM(ControllerStateButton, b) {
    Button& button = m_Buttons[b];
    if (!button.spr.IsLoaded()) {
      continue;
    }
    if (!button.gi.IsValid() || INPUTMAPPER == nullptr) {
      button.spr->SetVisible(false);
      continue;
    }

    bool bVisible = INPUTMAPPER->IsBeingPressed(button.gi, m_mp);

    button.spr->SetVisible(bVisible);
  }
}

/** @brief Allow Lua to have access to the ControllerStateDisplay. */
class LunaControllerStateDisplay : public Luna<ControllerStateDisplay> {
 public:
  static int LoadGameController(T* p, lua_State* L) {
    p->LoadGameController(SArg(1), Enum::Check<GameController>(L, 2));
    COMMON_RETURN_SELF;
  }
  static int LoadMultiPlayer(T* p, lua_State* L) {
    p->LoadMultiPlayer(SArg(1), Enum::Check<MultiPlayer>(L, 2));
    COMMON_RETURN_SELF;
  }

  LunaControllerStateDisplay() {
    ADD_METHOD(LoadGameController);
    ADD_METHOD(LoadMultiPlayer);
  }
};

LUA_REGISTER_DERIVED_CLASS(ControllerStateDisplay, ActorFrame)

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
