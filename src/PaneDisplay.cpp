#include "PaneDisplay.h"

#include <cmath>
#include <cctype>
#include <string>

#include "ActorFrame.h"
#include "ActorUtil.h"
#include "Course.h"
#include "EnumHelper.h"
#include "GameConstantsAndTypes.h"
#include "GameState.h"
#include "HighScore.h"
#include "LuaManager.h"
#include "PlayerNumber.h"
#include "PlayerStageStats.h"
#include "Profile.h"
#include "ProfileManager.h"
#include "RadarValues.h"
#include "RageThreads.h"
#include "RageLog.h"
#include "RageUtil.h"
#include "Song.h"
#include "Steps.h"
#include "ThemeManager.h"
#include "XmlFile.h"

#define SHIFT_X(pc) \
  THEME->GetMetricF(sMetricsGroup, ssprintf("ShiftP%iX", pc + 1))
#define SHIFT_Y(pc) \
  THEME->GetMetricF(sMetricsGroup, ssprintf("ShiftP%iY", pc + 1))

static const char* PaneCategoryNames[] = {
    "NumSteps",
    "Jumps",
    "Holds",
    "Rolls",
    "Mines",
    "Hands",
    "Lifts",
    "Fakes",
    "MachineHighScore",
    "MachineHighName",
    "ProfileHighScore",
};
XToString(PaneCategory);
LuaXType(PaneCategory);

enum { NEED_NOTES = 1, NEED_PROFILE = 2 };
struct Content_t {
  int req;
  std::string sFontType;
};

static const Content_t g_Contents[NUM_PaneCategory] = {
    {NEED_NOTES, "count"},                 // NumSteps
    {NEED_NOTES, "count"},                 // Jumps
    {NEED_NOTES, "count"},                 // Holds
    {NEED_NOTES, "count"},                 // Rolls
    {NEED_NOTES, "count"},                 // Mines
    {NEED_NOTES, "count"},                 // Hands
    {NEED_NOTES, "count"},                 // Lifts
    {NEED_NOTES, "count"},                 // Fakes
    {NEED_NOTES, "score"},                 // MachineHighScore
    {NEED_NOTES, "name"},                  // MachineHighName
    {NEED_NOTES | NEED_PROFILE, "score"},  // ProfileHighScore
};

namespace {
bool IsValidPlayerNumber(PlayerNumber pn) {
  return pn >= PLAYER_1 && pn < NUM_PLAYERS;
}

bool IsSafeCountFormat(const std::string& format) {
  if (format.empty() || format.size() > 64) {
    return false;
  }
  for (size_t i = 0; i < format.size(); ++i) {
    if (format[i] != '%' || (i + 1 < format.size() && format[i + 1] == '%')) {
      if (format[i] == '%') {
        ++i;
      }
      continue;
    }
    size_t j = i + 1;
    while (j < format.size() && !std::isalpha(format[j])) {
      if (std::isdigit(format[j]) && format[j] > '9') {
        return false;
      }
      ++j;
    }
    if (j >= format.size()) {
      return false;
    }
    if (format[j] == 's' || format[j] == 'n' || format[j] == 'p') {
      return false;
    }
  }
  return true;
}

std::string FormatPaneCount(const std::string& format, float value) {
  if (!std::isfinite(value)) {
    LOG->Trace(
        "SRC_AUDIT_FIX SRC-269: PaneDisplay corrected non-finite pane count.");
    value = 0.0f;
  }
  if (!IsSafeCountFormat(format)) {
    LOG->Warn(
        "SRC_AUDIT_FIX SRC-269: PaneDisplay ignored unsafe count format '%s'.",
        format.c_str());
    return ssprintf("%.0f", value);
  }
  return ssprintf(format.c_str(), value);
}
}  // namespace

REGISTER_ACTOR_CLASS(PaneDisplay);

void PaneDisplay::Load(const std::string& sMetricsGroup, PlayerNumber pn) {
  if (!IsValidPlayerNumber(pn)) {
    LOG->Warn(
        "SRC_AUDIT_FIX SRC-267: PaneDisplay loaded with invalid player %i; "
        "using PLAYER_1 for layout.",
        pn);
    pn = PLAYER_1;
  }
  m_PlayerNumber = pn;

  EMPTY_MACHINE_HIGH_SCORE_NAME.Load(
      sMetricsGroup, "EmptyMachineHighScoreName");
  NOT_AVAILABLE.Load(sMetricsGroup, "NotAvailable");
  COUNT_FORMAT.Load(sMetricsGroup, "CountFormat");
  NULL_COUNT_STRING.Load(sMetricsGroup, "NullCountString");

  FOREACH_ENUM(PaneCategory, pc) {
    LuaThreadVariable var("PaneCategory", LuaReference::Create(pc));

    std::string sFontType = g_Contents[pc].sFontType;

    m_textContents[pc].LoadFromFont(THEME->GetPathF(sMetricsGroup, sFontType));
    m_textContents[pc].SetName(PaneCategoryToString(pc) + "Text");
    ActorUtil::LoadAllCommands(m_textContents[pc], sMetricsGroup);
    ActorUtil::SetXY(m_textContents[pc], sMetricsGroup);
    m_ContentsFrame.AddChild(&m_textContents[pc]);

    m_Labels[pc].Load(
        THEME->GetPathG(sMetricsGroup, "label " + PaneCategoryToString(pc)));
    m_Labels[pc]->SetName(PaneCategoryToString(pc) + "Label");
    ActorUtil::LoadAllCommands(*m_Labels[pc], sMetricsGroup);
    ActorUtil::SetXY(m_Labels[pc], sMetricsGroup);
    m_ContentsFrame.AddChild(m_Labels[pc]);

    ActorUtil::LoadAllCommandsFromName(
        m_textContents[pc], sMetricsGroup, PaneCategoryToString(pc));
  }

  m_ContentsFrame.SetXY(SHIFT_X(m_PlayerNumber), SHIFT_Y(m_PlayerNumber));
  this->AddChild(&m_ContentsFrame);
}

void PaneDisplay::LoadFromNode(const XNode* pNode) {
  bool b;

  std::string sMetricsGroup;
  b = pNode->GetAttrValue("MetricsGroup", sMetricsGroup);
  if (!b) {
    sMetricsGroup = "PaneDisplay";
    LuaHelpers::ReportScriptError(
        "PaneDisplay must have a MetricsGroup specified.");
  }

  Lua* L = LUA->Get();
  b = pNode->PushAttrValue(L, "PlayerNumber");
  PlayerNumber pn;
  if (!b) {
    lua_pop(L, 1);
    pn = GAMESTATE->GetMasterPlayerNumber();
    LuaHelpers::ReportScriptError(
        "PaneDisplay must have a PlayerNumber specified.");
  } else {
    LuaHelpers::Pop(L, pn);
    if (!IsValidPlayerNumber(pn)) {
      LOG->Warn(
          "SRC_AUDIT_FIX SRC-267: PaneDisplay ignored invalid PlayerNumber "
          "%i from XML.",
          pn);
      pn = GAMESTATE->GetMasterPlayerNumber();
    }
  }
  LUA->Release(L);

  Load(sMetricsGroup, pn);

  ActorFrame::LoadFromNode(pNode);
}

void PaneDisplay::GetPaneTextAndLevel(
    PaneCategory c, std::string& sTextOut, float& fLevelOut) {
  if (c < PaneCategory_NumSteps || c >= NUM_PaneCategory) {
    LOG->Warn(
        "SRC_AUDIT_FIX SRC-267: PaneDisplay ignored invalid category %i.", c);
    sTextOut = NOT_AVAILABLE;
    fLevelOut = 0;
    return;
  }
  if (!IsValidPlayerNumber(m_PlayerNumber)) {
    LOG->Warn(
        "SRC_AUDIT_FIX SRC-267: PaneDisplay ignored invalid player %i.",
        m_PlayerNumber);
    sTextOut = NOT_AVAILABLE;
    fLevelOut = 0;
    return;
  }

  const Song* pSong = GAMESTATE->m_pCurSong;
  const Steps* pSteps = GAMESTATE->m_pCurSteps[m_PlayerNumber];
  const Course* pCourse = GAMESTATE->m_pCurCourse;
  const Trail* pTrail = GAMESTATE->m_pCurTrail[m_PlayerNumber];
  const Profile* pProfile = PROFILEMAN->IsPersistentProfile(m_PlayerNumber)
                                ? PROFILEMAN->GetProfile(m_PlayerNumber)
                                : nullptr;
  bool bIsPlayerEdit = pSteps && pSteps->IsAPlayerEdit();

  // Defaults, will be filled in later
  sTextOut = NULL_COUNT_STRING;
  fLevelOut = 0;

  if (GAMESTATE->IsCourseMode() && !pTrail) {
    if ((g_Contents[c].req & NEED_PROFILE)) {
      sTextOut = NOT_AVAILABLE;
    }

    {
      switch (c) {
        case PaneCategory_MachineHighName:
          sTextOut = EMPTY_MACHINE_HIGH_SCORE_NAME;
          break;
        case PaneCategory_MachineHighScore:
        case PaneCategory_ProfileHighScore:
          sTextOut = NOT_AVAILABLE;
          break;
        default:
          break;
      }
    }

    return;
  } else if (!GAMESTATE->IsCourseMode() && !pSong) {
    if ((g_Contents[c].req & NEED_PROFILE)) {
      sTextOut = NOT_AVAILABLE;
    }

    {
      switch (c) {
        case PaneCategory_MachineHighName:
          sTextOut = EMPTY_MACHINE_HIGH_SCORE_NAME;
          break;
        case PaneCategory_MachineHighScore:
        case PaneCategory_ProfileHighScore:
          sTextOut = NOT_AVAILABLE;
          break;
        default:
          break;
      }
    }

    return;
  }

  if ((g_Contents[c].req & NEED_NOTES) && !pSteps && !pTrail) {
    return;
  }
  if ((g_Contents[c].req & NEED_PROFILE) && !pProfile) {
    sTextOut = NOT_AVAILABLE;
    return;
  }

  {
    RadarValues rv;
    HighScoreList* pHSL = nullptr;
    ProfileSlot slot = ProfileSlot_Machine;
    switch (c) {
      case PaneCategory_ProfileHighScore:
        slot = (ProfileSlot)m_PlayerNumber;
      default:
        break;
    }

    if (pSteps) {
      rv = pSteps->GetRadarValues(m_PlayerNumber);
      Profile* pProfileForScores = PROFILEMAN->GetProfile(slot);
      if (pProfileForScores == nullptr) {
        LOG->Warn(
            "SRC_AUDIT_FIX SRC-268: PaneDisplay missing profile slot %i.",
            slot);
        sTextOut = NOT_AVAILABLE;
        return;
      }
      pHSL = &pProfileForScores->GetStepsHighScoreList(pSong, pSteps);
    } else if (pTrail) {
      rv = pTrail->GetRadarValues();
      Profile* pProfileForScores = PROFILEMAN->GetProfile(slot);
      if (pProfileForScores == nullptr) {
        LOG->Warn(
            "SRC_AUDIT_FIX SRC-268: PaneDisplay missing profile slot %i.",
            slot);
        sTextOut = NOT_AVAILABLE;
        return;
      }
      pHSL = &pProfileForScores->GetCourseHighScoreList(pCourse, pTrail);
    }

    switch (c) {
      case PaneCategory_NumSteps: {
        fLevelOut = rv[RadarCategory_TapsAndHolds];
        break;
      }
      case PaneCategory_Jumps: {
        fLevelOut = rv[RadarCategory_Jumps];
        break;
      }
      case PaneCategory_Holds: {
        fLevelOut = rv[RadarCategory_Holds];
        break;
      }
      case PaneCategory_Rolls: {
        fLevelOut = rv[RadarCategory_Rolls];
        break;
      }
      case PaneCategory_Mines: {
        fLevelOut = rv[RadarCategory_Mines];
        break;
      }
      case PaneCategory_Hands: {
        fLevelOut = rv[RadarCategory_Hands];
        break;
      }
      case PaneCategory_Lifts: {
        fLevelOut = rv[RadarCategory_Lifts];
        break;
      }
      case PaneCategory_Fakes: {
        fLevelOut = rv[RadarCategory_Fakes];
        break;
      }
      case PaneCategory_ProfileHighScore:
      case PaneCategory_MachineHighName:  // set fLevelOut for color
      case PaneCategory_MachineHighScore: {
        CHECKPOINT_M(
            "Getting data from a high score instead of a radar value.");
        if (pHSL == nullptr) {
          sTextOut = NOT_AVAILABLE;
          return;
        }
        fLevelOut = pHSL->GetTopScore().GetPercentDP();
        break;
      }
      default:
        break;
    };

    if (fLevelOut != RADAR_VAL_UNKNOWN) {
      switch (c) {
        case PaneCategory_MachineHighName:
          if (pHSL->vHighScores.empty()) {
            sTextOut = EMPTY_MACHINE_HIGH_SCORE_NAME;
          } else {
            sTextOut = pHSL->GetTopScore().GetName();
            if (sTextOut.empty()) {
              sTextOut = "????";
            }
          }
          break;
        case PaneCategory_MachineHighScore:
        case PaneCategory_ProfileHighScore:
          // Don't show or save machine high scores for edits loaded from a
          // player profile.
          if (bIsPlayerEdit) {
            sTextOut = NOT_AVAILABLE;
          } else {
            sTextOut = PlayerStageStats::FormatPercentScore(fLevelOut);
          }
          break;
        case PaneCategory_NumSteps:
        case PaneCategory_Jumps:
        case PaneCategory_Holds:
        case PaneCategory_Rolls:
        case PaneCategory_Mines:
        case PaneCategory_Hands:
        case PaneCategory_Lifts:
        case PaneCategory_Fakes:
          sTextOut = FormatPaneCount(COUNT_FORMAT.GetValue(), fLevelOut);
          break;
        default:
          break;
      }
    }
  }
}

void PaneDisplay::SetContent(PaneCategory c) {
  // these get filled in later:
  std::string str;
  float val;

  GetPaneTextAndLevel(c, str, val);
  m_textContents[c].SetText(str);

  Lua* L = LUA->Get();

  m_textContents[c].PushSelf(L);
  lua_pushstring(L, "PaneLevel");
  lua_pushnumber(L, val);
  lua_settable(L, -3);
  lua_pop(L, 1);

  m_textContents[c].PlayCommand("Level");

  LUA->Release(L);
}

void PaneDisplay::SetFromGameState() {
  // Don't update text that doesn't apply to the current mode. It's still
  // tweening off.
  FOREACH_ENUM(PaneCategory, i)
  SetContent(i);
}

// lua start
#include "LuaBinding.h"

/** @brief Allow Lua to have access to the PaneDisplay. */
class LunaPaneDisplay : public Luna<PaneDisplay> {
 public:
  static int SetFromGameState(T* p, lua_State* L) {
    p->SetFromGameState();
    COMMON_RETURN_SELF;
  }

  LunaPaneDisplay() { ADD_METHOD(SetFromGameState); }
};

LUA_REGISTER_DERIVED_CLASS(PaneDisplay, ActorFrame)
// lua end

/*
 * (c) 2003 Glenn Maynard
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
