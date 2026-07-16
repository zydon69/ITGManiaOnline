#include "PaneDisplay.h"

#include <algorithm>
#include <cctype>
#include <cmath>
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
#include "RageLog.h"
#include "RageThreads.h"
#include "RageUtil.h"
#include "Song.h"
#include "Steps.h"
#include "ThemeManager.h"
#include "XmlFile.h"

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
void WarnPaneDisplayAuditFix(const char* message) {
  if (LOG != nullptr) {
    LOG->Warn("%s", message);
  }
}

void TracePaneDisplayAuditFix(const char* message) {
  if (LOG != nullptr) {
    LOG->Trace("%s", message);
  }
}

bool IsValidPlayerNumber(PlayerNumber pn) {
  return pn >= PLAYER_1 && pn < NUM_PLAYERS;
}

bool IsSafeCountFormat(const std::string& format) {
  if (format.empty() || format.size() > 64) {
    return false;
  }
  int conversions = 0;
  for (size_t i = 0; i < format.size(); ++i) {
    if (format[i] != '%') {
      continue;
    }
    if (i + 1 < format.size() && format[i + 1] == '%') {
      ++i;
      continue;
    }
    ++conversions;
    if (conversions > 1) {
      return false;
    }
    size_t j = i + 1;
    while (j < format.size() &&
           std::string("-+ #0").find(format[j]) != std::string::npos) {
      ++j;
    }
    int width = 0;
    while (j < format.size() &&
           std::isdigit(static_cast<unsigned char>(format[j]))) {
      width = width * 10 + (format[j] - '0');
      if (width > 12) {
        return false;
      }
      ++j;
    }
    if (j < format.size() && format[j] == '.') {
      ++j;
      int precision = 0;
      while (j < format.size() &&
             std::isdigit(static_cast<unsigned char>(format[j]))) {
        precision = precision * 10 + (format[j] - '0');
        if (precision > 6) {
          return false;
        }
        ++j;
      }
    }
    if (j >= format.size()) {
      return false;
    }
    if (std::string("fFeEgG").find(format[j]) == std::string::npos) {
      return false;
    }
  }
  return conversions == 1;
}

float GetPaneMetricF(
    const std::string& sMetricsGroup, const std::string& metric) {
  if (THEME == nullptr) {
    return 0.0f;
  }
  const float value = THEME->GetMetricF(sMetricsGroup, metric);
  if (!std::isfinite(value)) {
    WarnPaneDisplayAuditFix(
        "SRC_AUDIT_FIX SRC-1081: PaneDisplay used zero for non-finite layout "
        "metric.");
    return 0.0f;
  }
  return value;
}

PlayerNumber SafeMasterPlayerNumber() {
  if (GAMESTATE == nullptr) {
    return PLAYER_1;
  }
  const PlayerNumber pn = GAMESTATE->GetMasterPlayerNumber();
  return IsValidPlayerNumber(pn) ? pn : PLAYER_1;
}

void ReleasePaneDisplayLua(Lua* L) {
  if (LUA != nullptr && L != nullptr) {
    LUA->Release(L);
  }
}

bool GetPaneDisplayLuaAttr(
    const XNode* pNode, const std::string& attr, PlayerNumber& pnOut) {
  if (LUA == nullptr || pNode == nullptr) {
    return false;
  }
  Lua* L = LUA->Get();
  if (L == nullptr) {
    return false;
  }
  const bool pushed = pNode->PushAttrValue(L, attr);
  if (!pushed) {
    lua_pop(L, 1);
    ReleasePaneDisplayLua(L);
    return false;
  }
  LuaHelpers::Pop(L, pnOut);
  ReleasePaneDisplayLua(L);
  return true;
}

bool IsValidProfileSlotForPane(ProfileSlot slot) {
  switch (slot) {
    case ProfileSlot_Player1:
    case ProfileSlot_Player2:
    case ProfileSlot_Machine:
      return true;
    default:
      return false;
  }
}

std::string FormatPaneCount(const std::string& format, float value) {
  if (!std::isfinite(value)) {
    TracePaneDisplayAuditFix(
        "SRC_AUDIT_FIX SRC-269: PaneDisplay corrected non-finite pane count.");
    value = 0.0f;
  }
  if (!IsSafeCountFormat(format)) {
    WarnPaneDisplayAuditFix(
        "SRC_AUDIT_FIX SRC-269: PaneDisplay ignored unsafe count format.");
    return ssprintf("%.0f", value);
  }
  return ssprintf(format.c_str(), value);
}
}  // namespace

REGISTER_ACTOR_CLASS(PaneDisplay);

PaneDisplay::PaneDisplay() {
  m_PlayerNumber = PLAYER_1;
  m_bLoaded = false;
}

PaneDisplay::PaneDisplay(const PaneDisplay& cpy)
    : ActorFrame(cpy),
      m_textContents(cpy.m_textContents),
      m_Labels(cpy.m_Labels),
      m_ContentsFrame(cpy.m_ContentsFrame),
      m_PlayerNumber(cpy.m_PlayerNumber),
      m_bLoaded(cpy.m_bLoaded),
      EMPTY_MACHINE_HIGH_SCORE_NAME(cpy.EMPTY_MACHINE_HIGH_SCORE_NAME),
      NOT_AVAILABLE(cpy.NOT_AVAILABLE),
      COUNT_FORMAT(cpy.COUNT_FORMAT),
      NULL_COUNT_STRING(cpy.NULL_COUNT_STRING) {
  m_ContentsFrame.RemoveAllChildren();
  if (!m_bLoaded) {
    return;
  }
  FOREACH_ENUM(PaneCategory, pc) {
    m_ContentsFrame.AddChild(&m_textContents[pc]);
    if (m_Labels[pc].IsLoaded()) {
      m_ContentsFrame.AddChild(m_Labels[pc]);
    }
  }
  AddChild(&m_ContentsFrame);
}

void PaneDisplay::ResetLoadedActors() {
  RemoveChild(&m_ContentsFrame);
  FOREACH_ENUM(PaneCategory, pc) {
    m_ContentsFrame.RemoveChild(&m_textContents[pc]);
    if (m_Labels[pc].IsLoaded()) {
      m_ContentsFrame.RemoveChild(m_Labels[pc]);
      m_Labels[pc].Unload();
    }
  }
  m_ContentsFrame.RemoveAllChildren();
  m_bLoaded = false;
}

void PaneDisplay::Load(const std::string& sMetricsGroup, PlayerNumber pn) {
  ResetLoadedActors();

  std::string sResolvedMetricsGroup = sMetricsGroup;
  if (sResolvedMetricsGroup.empty()) {
    WarnPaneDisplayAuditFix(
        "SRC_AUDIT_FIX SRC-1081: PaneDisplay fell back from empty metrics "
        "group.");
    sResolvedMetricsGroup = "PaneDisplay";
  }
  if (THEME == nullptr) {
    WarnPaneDisplayAuditFix(
        "SRC_AUDIT_FIX SRC-1081: PaneDisplay refused load without THEME.");
    return;
  }

  if (!IsValidPlayerNumber(pn)) {
    WarnPaneDisplayAuditFix(
        "SRC_AUDIT_FIX SRC-267: PaneDisplay loaded with invalid player; using "
        "PLAYER_1 for layout.");
    pn = PLAYER_1;
  }
  m_PlayerNumber = pn;

  EMPTY_MACHINE_HIGH_SCORE_NAME.Load(
      sResolvedMetricsGroup, "EmptyMachineHighScoreName");
  NOT_AVAILABLE.Load(sResolvedMetricsGroup, "NotAvailable");
  COUNT_FORMAT.Load(sResolvedMetricsGroup, "CountFormat");
  NULL_COUNT_STRING.Load(sResolvedMetricsGroup, "NullCountString");

  FOREACH_ENUM(PaneCategory, pc) {
    LuaThreadVariable var("PaneCategory", LuaReference::Create(pc));

    std::string sFontType = g_Contents[pc].sFontType;

    m_textContents[pc].LoadFromFont(
        THEME->GetPathF(sResolvedMetricsGroup, sFontType));
    m_textContents[pc].SetName(PaneCategoryToString(pc) + "Text");
    ActorUtil::LoadAllCommands(m_textContents[pc], sResolvedMetricsGroup);
    ActorUtil::SetXY(m_textContents[pc], sResolvedMetricsGroup);
    m_ContentsFrame.AddChild(&m_textContents[pc]);

    m_Labels[pc].Load(THEME->GetPathG(
        sResolvedMetricsGroup, "label " + PaneCategoryToString(pc)));
    if (m_Labels[pc].IsLoaded()) {
      m_Labels[pc]->SetName(PaneCategoryToString(pc) + "Label");
      ActorUtil::LoadAllCommands(*m_Labels[pc], sResolvedMetricsGroup);
      ActorUtil::SetXY(m_Labels[pc], sResolvedMetricsGroup);
      m_ContentsFrame.AddChild(m_Labels[pc]);
    } else {
      WarnPaneDisplayAuditFix(
          "SRC_AUDIT_FIX SRC-2976: PaneDisplay loaded without a label actor.");
    }

    ActorUtil::LoadAllCommandsFromName(
        m_textContents[pc], sResolvedMetricsGroup, PaneCategoryToString(pc));
  }

  m_ContentsFrame.SetXY(
      GetPaneMetricF(
          sResolvedMetricsGroup, ssprintf("ShiftP%iX", m_PlayerNumber + 1)),
      GetPaneMetricF(
          sResolvedMetricsGroup, ssprintf("ShiftP%iY", m_PlayerNumber + 1)));
  this->AddChild(&m_ContentsFrame);
  m_bLoaded = true;
}

void PaneDisplay::LoadFromNode(const XNode* pNode) {
  if (pNode == nullptr) {
    WarnPaneDisplayAuditFix(
        "SRC_AUDIT_FIX SRC-1080: PaneDisplay ignored null XML node.");
    return;
  }
  bool b;

  std::string sMetricsGroup;
  b = pNode->GetAttrValue("MetricsGroup", sMetricsGroup);
  if (!b) {
    sMetricsGroup = "PaneDisplay";
    LuaHelpers::ReportScriptError(
        "PaneDisplay must have a MetricsGroup specified.");
  }

  PlayerNumber pn = SafeMasterPlayerNumber();
  b = GetPaneDisplayLuaAttr(pNode, "PlayerNumber", pn);
  if (!b) {
    LuaHelpers::ReportScriptError(
        "PaneDisplay must have a PlayerNumber specified.");
  } else {
    if (!IsValidPlayerNumber(pn)) {
      WarnPaneDisplayAuditFix(
          "SRC_AUDIT_FIX SRC-267: PaneDisplay ignored invalid PlayerNumber "
          "from XML.");
      pn = SafeMasterPlayerNumber();
    }
  }

  Load(sMetricsGroup, pn);

  ActorFrame::LoadFromNode(pNode);
}

void PaneDisplay::GetPaneTextAndLevel(
    PaneCategory c, std::string& sTextOut, float& fLevelOut) {
  if (c < PaneCategory_NumSteps || c >= NUM_PaneCategory) {
    if (LOG != nullptr) {
      LOG->Warn(
          "SRC_AUDIT_FIX SRC-267: PaneDisplay ignored invalid category %i.", c);
    }
    sTextOut = NOT_AVAILABLE;
    fLevelOut = 0;
    return;
  }
  if (!IsValidPlayerNumber(m_PlayerNumber)) {
    WarnPaneDisplayAuditFix(
        "SRC_AUDIT_FIX SRC-267: PaneDisplay ignored invalid player.");
    sTextOut = NOT_AVAILABLE;
    fLevelOut = 0;
    return;
  }
  if (GAMESTATE == nullptr || PROFILEMAN == nullptr) {
    WarnPaneDisplayAuditFix(
        "SRC_AUDIT_FIX SRC-1082: PaneDisplay skipped update without game or "
        "profile manager.");
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
      if (pSong == nullptr) {
        sTextOut = NOT_AVAILABLE;
        return;
      }
      if (!IsValidProfileSlotForPane(slot)) {
        sTextOut = NOT_AVAILABLE;
        return;
      }
      Profile* pProfileForScores = PROFILEMAN->GetProfile(slot);
      if (pProfileForScores == nullptr) {
        WarnPaneDisplayAuditFix(
            "SRC_AUDIT_FIX SRC-268: PaneDisplay missing profile slot.");
        sTextOut = NOT_AVAILABLE;
        return;
      }
      pHSL = &pProfileForScores->GetStepsHighScoreList(pSong, pSteps);
    } else if (pTrail) {
      rv = pTrail->GetRadarValues();
      if (pCourse == nullptr) {
        sTextOut = NOT_AVAILABLE;
        return;
      }
      if (!IsValidProfileSlotForPane(slot)) {
        sTextOut = NOT_AVAILABLE;
        return;
      }
      Profile* pProfileForScores = PROFILEMAN->GetProfile(slot);
      if (pProfileForScores == nullptr) {
        WarnPaneDisplayAuditFix(
            "SRC_AUDIT_FIX SRC-268: PaneDisplay missing profile slot.");
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
  if (c < PaneCategory_NumSteps || c >= NUM_PaneCategory) {
    WarnPaneDisplayAuditFix(
        "SRC_AUDIT_FIX SRC-1083: PaneDisplay ignored invalid SetContent "
        "category.");
    return;
  }
  // these get filled in later:
  std::string str;
  float val;

  GetPaneTextAndLevel(c, str, val);
  if (!std::isfinite(val)) {
    val = 0.0f;
  }
  m_textContents[c].SetText(str);

  if (LUA == nullptr) {
    m_textContents[c].PlayCommand("Level");
    return;
  }

  Lua* L = LUA->Get();
  if (L == nullptr) {
    m_textContents[c].PlayCommand("Level");
    return;
  }

  m_textContents[c].PushSelf(L);
  lua_pushstring(L, "PaneLevel");
  lua_pushnumber(L, val);
  lua_settable(L, -3);
  lua_pop(L, 1);

  m_textContents[c].PlayCommand("Level");

  LUA->Release(L);
}

void PaneDisplay::SetFromGameState() {
  if (!m_bLoaded) {
    TracePaneDisplayAuditFix(
        "SRC_AUDIT_FIX SRC-1081: PaneDisplay skipped update before load.");
    return;
  }
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
