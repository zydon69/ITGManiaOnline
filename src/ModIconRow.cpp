#include "ModIconRow.h"

#include <algorithm>
#include <cctype>
#include <string>
#include <vector>

#include "ActorFrame.h"
#include "ActorUtil.h"
#include "EnumHelper.h"
#include "GameState.h"
#include "LuaManager.h"
#include "MessageManager.h"
#include "ModIcon.h"
#include "PlayerNumber.h"
#include "PlayerOptions.h"
#include "PlayerState.h"
#include "RageLog.h"
#include "RageUtil.h"
#include "global.h"

int OptionToPreferredColumn(std::string sOptionText);

REGISTER_ACTOR_CLASS(ModIconRow);

namespace {
const int MAX_MOD_ICONS = 64;

bool IsValidModIconRowPlayer(PlayerNumber pn) {
  return pn >= PLAYER_1 && pn < NUM_PLAYERS;
}

void WarnModIconRow(const char* message) {
  if (LOG != nullptr) {
    LOG->Warn("%s", message);
  }
}

float SanitizeModIconSpacing(float value) {
  if (!std::isfinite(value)) {
    return 0.0f;
  }
  return std::clamp(value, -10000.0f, 10000.0f);
}

int SanitizeNumModIcons(int value) {
  return std::clamp(value, 0, MAX_MOD_ICONS);
}
}  // namespace

ModIconRow::ModIconRow() {
  m_pn = PlayerNumber_Invalid;

  this->SubscribeToMessage("PlayerOptionsChanged");
}

ModIconRow::ModIconRow(const ModIconRow& cpy)
    : ActorFrame(cpy),
      m_sMetricsGroup(cpy.m_sMetricsGroup),
      m_pn(cpy.m_pn),
      SPACING_X(cpy.SPACING_X),
      SPACING_Y(cpy.SPACING_Y),
      NUM_OPTION_ICONS(cpy.NUM_OPTION_ICONS),
      OPTION_ICON_METRICS_GROUP(cpy.OPTION_ICON_METRICS_GROUP) {
  RemoveAllChildren();
  for (ModIcon* icon : cpy.m_vpModIcon) {
    if (icon == nullptr) {
      continue;
    }
    ModIcon* copy = new ModIcon(*icon);
    m_vpModIcon.push_back(copy);
    AddChild(copy);
  }
}

ModIconRow::~ModIconRow() { ClearIcons(); }

void ModIconRow::ClearIcons() {
  for (ModIcon* p : m_vpModIcon) {
    RemoveChild(p);
    RageUtil::SafeDelete(p);
  }
  m_vpModIcon.clear();
  this->RemoveAllChildren();
}

void ModIconRow::Load(const std::string& sMetricsGroup, PlayerNumber pn) {
  ClearIcons();

  m_sMetricsGroup = sMetricsGroup;
  m_pn = IsValidModIconRowPlayer(pn) ? pn : PlayerNumber_Invalid;
  if (m_pn == PlayerNumber_Invalid) {
    WarnModIconRow("SRC_AUDIT_FIX SRC-1199: ModIconRow ignored invalid player.");
  }

  float spacingX = 0.0f;
  float spacingY = 0.0f;
  int numOptionIcons = 0;
  std::string optionIconMetricsGroup;

  if (THEME != nullptr && !sMetricsGroup.empty()) {
    SPACING_X.Load(sMetricsGroup, "SpacingX");
    SPACING_Y.Load(sMetricsGroup, "SpacingY");
    NUM_OPTION_ICONS.Load(sMetricsGroup, "NumModIcons");
    OPTION_ICON_METRICS_GROUP.Load(sMetricsGroup, "ModIconMetricsGroup");
    spacingX = SanitizeModIconSpacing(SPACING_X.GetValue());
    spacingY = SanitizeModIconSpacing(SPACING_Y.GetValue());
    numOptionIcons = SanitizeNumModIcons(NUM_OPTION_ICONS.GetValue());
    optionIconMetricsGroup = OPTION_ICON_METRICS_GROUP.GetValue();
  } else {
    WarnModIconRow("SRC_AUDIT_FIX SRC-1200: ModIconRow loaded without THEME.");
  }

  for (int i = 0; i < numOptionIcons; i++) {
    ModIcon* p = new ModIcon;
    p->SetName("ModIcon");
    float fOffset =
        numOptionIcons == 1
            ? 0.0f
            : SCALE(
                  i, 0, numOptionIcons - 1, -(numOptionIcons - 1) / 2.0f,
                  (float)(numOptionIcons - 1) / 2.0f);
    p->SetXY(fOffset * spacingX, fOffset * spacingY);
    p->Load(optionIconMetricsGroup);
    if (THEME != nullptr && !sMetricsGroup.empty()) {
      ActorUtil::LoadAllCommands(p, sMetricsGroup);
    }
    m_vpModIcon.push_back(p);
    this->AddChild(p);
  }

  SetFromGameState();
}

void ModIconRow::HandleMessage(const Message& msg) {
  if (msg.GetName() == "PlayerOptionsChanged") {
    SetFromGameState();
  }

  ActorFrame::HandleMessage(msg);
}

struct OptionColumnEntry {
  const char* szString;
  int iSlotIndex;

  // void FromStack( lua_State *L, int iPos );
};

// todo: metric these? -aj
static const OptionColumnEntry g_OptionColumnEntries[] = {
    {"Boost", 0},
    {"Brake", 0},
    {"Wave", 0},
    {"Expand", 0},
    {"Boomerang", 0},
    //--------------------//
    {"Drunk", 1},
    {"Dizzy", 1},
    {"Mini", 1},
    {"Flip", 1},
    {"Tornado", 1},
    //--------------------//
    {"Hidden", 2},
    {"Sudden", 2},
    {"Stealth", 2},
    {"Blink", 2},
    {"RandomVanish", 2},
    //--------------------//
    {"Mirror", 3},
    {"LRMirror", 3},
    {"UDMirror", 3},
    {"Left", 3},
    {"Right", 3},
    {"Shuffle", 3},
    {"SuperShuffle", 3},
    //--------------------//
    {"Little", 4},
    {"NoHolds", 4},
    {"Dark", 4},
    {"Blind", 4},
    //--------------------//
    {"Reverse", 5},
    {"Split", 5},
    {"Alternate", 5},
    {"Cross", 5},
    {"Centered", 5},
    //--------------------//
    {"Incoming", 6},
    {"Space", 6},
    {"Hallway", 6},
    {"Distant", 6},
};

int OptionToPreferredColumn(std::string sOptionText) {
  // Speedups always go in column 0. digit ... x
  if (sOptionText.size() > 1 &&
      isdigit(static_cast<unsigned char>(sOptionText[0])) &&
      tolower(static_cast<unsigned char>(sOptionText[sOptionText.size() - 1])) ==
          'x') {
    return 0;
  }

  for (unsigned i = 0; i < ARRAYLEN(g_OptionColumnEntries); i++) {
    if (g_OptionColumnEntries[i].szString == sOptionText) {
      return g_OptionColumnEntries[i].iSlotIndex;
    }
  }

  // This warns about C1234 and noteskins.
  //	LOG->Warn("Unknown option: '%s'", sOptionText.c_str() );
  return 0;
}

void ModIconRow::SetFromGameState() {
  PlayerNumber pn = m_pn;
  if (!IsValidModIconRowPlayer(pn) || GAMESTATE == nullptr ||
      GAMESTATE->m_pPlayerState[pn] == nullptr) {
    for (ModIcon* icon : m_vpModIcon) {
      if (icon != nullptr) {
        icon->Set("");
      }
    }
    return;
  }
  if (m_vpModIcon.empty()) {
    return;
  }

  std::string sOptions =
      GAMESTATE->m_pPlayerState[pn]->m_PlayerOptions.GetStage().GetString();
  std::vector<std::string> vsOptions;
  split(sOptions, ", ", vsOptions, true);

  std::vector<std::string>
      vsText;  // fill these with what will be displayed on the tabs
  vsText.resize(m_vpModIcon.size());

  // for each option, look for the best column to place it in
  for (unsigned i = 0; i < vsOptions.size(); i++) {
    std::string sOption = vsOptions[i];
    int iPreferredCol = OptionToPreferredColumn(sOption);
    iPreferredCol = std::clamp(iPreferredCol, 0, (int)m_vpModIcon.size() - 1);

    // search for a vacant spot
    for (int j = iPreferredCol; j < (int)m_vpModIcon.size(); j++) {
      if (vsText[j] != "") {
        continue;
      } else {
        vsText[j] = sOption;
        break;
      }
    }
  }

  for (unsigned i = 0; i < m_vpModIcon.size(); i++) {
    if (m_vpModIcon[i] != nullptr) {
      m_vpModIcon[i]->Set(vsText[i]);
    }
  }
}

// lua start
#include "LuaBinding.h"

/** @brief Allow Lua to have access to the ModIconRow. */
class LunaModIconRow : public Luna<ModIconRow> {
 public:
  static int Load(T* p, lua_State* L) {
    p->Load(SArg(1), Enum::Check<PlayerNumber>(L, 2));
    COMMON_RETURN_SELF;
  }

  LunaModIconRow() { ADD_METHOD(Load); }
};

LUA_REGISTER_DERIVED_CLASS(ModIconRow, ActorFrame)

// lua end

/*
 * (c) 2002-2004 Chris Danford
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
