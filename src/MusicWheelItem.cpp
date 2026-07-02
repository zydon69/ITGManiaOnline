#include "MusicWheelItem.h"

#include <algorithm>
#include <string>

#include "ActorUtil.h"
#include "BitmapText.h"
#include "Course.h"
#include "Difficulty.h"
#include "EnumHelper.h"
#include "GameConstantsAndTypes.h"
#include "GameManager.h"
#include "GameState.h"
#include "Group.h"
#include "HighScore.h"
#include "MessageManager.h"
#include "PerfDiagnostics.h"
#include "PlayerNumber.h"
#include "Profile.h"
#include "ProfileManager.h"
#include "RageLog.h"
#include "RageTypes.h"
#include "RageUtil.h"
#include "ScreenManager.h"
#include "Song.h"
#include "SongManager.h"
#include "SongUtil.h"
#include "Steps.h"
#include "Style.h"
#include "ThemeManager.h"
#include "ThemeMetric.h"
#include "WheelItemBase.h"
#include "WheelNotifyIcon.h"
#include "global.h"

static const char* MusicWheelItemTypeNames[] = {
    "Song", "SectionExpanded", "SectionCollapsed", "Roulette", "Course", "Sort",
    "Mode", "Random",          "Portal",           "Custom",
    "ParentExpanded", "ParentCollapsed",
};
XToString(MusicWheelItemType);

namespace {
const int MAX_SECTION_COUNT_DISPLAY = 99999;

void WarnMusicWheelItem(const char* message) {
  if (LOG != nullptr) {
    LOG->Warn("%s", message);
  }
}

void TraceMusicWheelItemReintro(const char* event, const std::string& details) {
  if (LOG != nullptr && LogMusicWheelDiagnosticsEnabled()) {
    LOG->Trace(
        "SRC_AUDIT_FIX SRC-2710 WheelReintroTrace %s %s", event,
        details.c_str());
  }
}

bool IsValidMusicWheelItemType(MusicWheelItemType type) {
  return type >= MusicWheelItemType_Song && type < NUM_MusicWheelItemType;
}

bool IsValidWheelItemDataType(WheelItemDataType type) {
  return type >= WheelItemDataType_Generic && type < NUM_WheelItemDataType;
}

int SanitizeSectionCount(int count) {
  return std::clamp(count, 0, MAX_SECTION_COUNT_DISPLAY);
}

std::string GetThemeStringOrFallback(
    const std::string& group, const std::string& key,
    const std::string& fallback) {
  if (THEME == nullptr) {
    return fallback;
  }
  return THEME->GetString(group, key);
}

void AddLoadedAutoActor(ActorFrame* frame, AutoActor& actor) {
  if (frame != nullptr && actor.IsLoaded()) {
    frame->AddChild(actor);
  }
}

bool LoadNamedAutoActor(
    AutoActor& actor, const std::string& path, const std::string& name) {
  if (path.empty()) {
    return false;
  }
  actor.Load(path);
  if (!actor.IsLoaded()) {
    return false;
  }
  actor->SetName(name);
  ActorUtil::LoadAllCommands(actor, "MusicWheelItem");
  return true;
}

void SetAutoActorVisible(AutoActor& actor, bool visible) {
  if (actor.IsLoaded()) {
    actor->SetVisible(visible);
  }
}

bool GetGradesShowMachine(const ThemeMetric<bool>& metric) {
  if (THEME == nullptr) {
    return false;
  }
  return metric.GetValue();
}

StepsType GetFallbackStepsType() {
  if (GAMESTATE == nullptr) {
    return StepsType_Invalid;
  }
  const Style* style = GAMESTATE->GetCurrentStyle(PLAYER_INVALID);
  if (style == nullptr) {
    return StepsType_Invalid;
  }
  return style->m_StepsType;
}
}  // namespace

MusicWheelItemData::MusicWheelItemData(
    WheelItemDataType type, Song* pSong, std::string sSectionName,
    Course* pCourse, Group* pGroup, RageColor color, int iSectionCount,
    std::string sParentSection)
    : WheelItemBaseData(type, sSectionName, color),
      m_pCourse(pCourse),
      m_pSong(pSong),
      m_pGroup(pGroup),
      m_Flags(WheelNotifyIcon::Flags()),
      m_iSectionCount(iSectionCount),
      m_sParentSection(sParentSection),
      m_sLabel(""),
      m_pAction() {}

MusicWheelItem::MusicWheelItem(std::string sType)
    : WheelItemBase(sType), m_pTextSectionCount(nullptr) {
  FOREACH_ENUM(MusicWheelItemType, i) { m_pText[i] = nullptr; }

  GRADES_SHOW_MACHINE.Load(sType, "GradesShowMachine");
  if (THEME == nullptr) {
    WarnMusicWheelItem(
        "SRC_AUDIT_FIX SRC-1280: MusicWheelItem loaded without theme "
        "manager.");
    return;
  }

  FOREACH_ENUM(MusicWheelItemType, i) {
    if (LoadNamedAutoActor(
            m_sprColorPart[i],
            THEME->GetPathG(
                sType, MusicWheelItemTypeToString(i) + " ColorPart"),
            MusicWheelItemTypeToString(i) + "ColorPart")) {
      AddLoadedAutoActor(this, m_sprColorPart[i]);
    }

    if (LoadNamedAutoActor(
            m_sprNormalPart[i],
            THEME->GetPathG(
                sType, MusicWheelItemTypeToString(i) + " NormalPart"),
            MusicWheelItemTypeToString(i) + "NormalPart")) {
      AddLoadedAutoActor(this, m_sprNormalPart[i]);
    }
  }

  m_TextBanner.SetName("SongName");
  ActorUtil::LoadAllCommands(m_TextBanner, "MusicWheelItem");
  m_TextBanner.Load("TextBanner");
  ActorUtil::SetXY(m_TextBanner, "MusicWheelItem");
  m_TextBanner.PlayCommand("On");
  this->AddChild(&m_TextBanner);

  FOREACH_ENUM(MusicWheelItemType, i) {
    if (LoadNamedAutoActor(
            m_sprOverPart[i],
            THEME->GetPathG(
                sType, MusicWheelItemTypeToString(i) + " OverPart"),
            MusicWheelItemTypeToString(i) + "OverPart")) {
      AddLoadedAutoActor(this, m_sprOverPart[i]);
    }
  }

  FOREACH_ENUM(MusicWheelItemType, i) {
    // Don't init text for Type_Song. It uses a TextBanner.
    if (i == MusicWheelItemType_Song) {
      continue;
    }

    m_pText[i] = new BitmapText;
    m_pText[i]->SetName(MusicWheelItemTypeToString(i));
    ActorUtil::LoadAllCommands(m_pText[i], "MusicWheelItem");
    if (!m_pText[i]->LoadFromFont(
            THEME->GetPathF(sType, MusicWheelItemTypeToString(i)))) {
      WarnMusicWheelItem(
          "SRC_AUDIT_FIX SRC-1282: MusicWheelItem failed to load item text "
          "font.");
    }
    ActorUtil::SetXY(m_pText[i], "MusicWheelItem");
    m_pText[i]->PlayCommand("On");
    this->AddChild(m_pText[i]);
  }

  m_pTextSectionCount = new BitmapText;
  m_pTextSectionCount->SetName("SectionCount");
  ActorUtil::LoadAllCommands(m_pTextSectionCount, "MusicWheelItem");
  if (!m_pTextSectionCount->LoadFromFont(THEME->GetPathF(sType, "SectionCount"))) {
    WarnMusicWheelItem(
        "SRC_AUDIT_FIX SRC-1282: MusicWheelItem failed to load section count "
        "font.");
  }
  ActorUtil::SetXY(m_pTextSectionCount, "MusicWheelItem");
  m_pTextSectionCount->PlayCommand("On");
  this->AddChild(m_pTextSectionCount);

  m_WheelNotifyIcon.SetName("WheelNotifyIcon");
  ActorUtil::LoadAllCommands(m_WheelNotifyIcon, "MusicWheelItem");
  ActorUtil::SetXY(m_WheelNotifyIcon, "MusicWheelItem");
  m_WheelNotifyIcon.PlayCommand("On");
  this->AddChild(&m_WheelNotifyIcon);

  FOREACH_PlayerNumber(p) {
    m_pGradeDisplay[p].Load(THEME->GetPathG(sType, "grades"));
    if (!m_pGradeDisplay[p].IsLoaded()) {
      continue;
    }
    m_pGradeDisplay[p]->SetName(ssprintf("GradeP%d", int(p + 1)));
    this->AddChild(m_pGradeDisplay[p]);
    LOAD_ALL_COMMANDS_AND_SET_XY(m_pGradeDisplay[p]);
  }

  this->SubscribeToMessage(Message_CurrentStepsP1Changed);
  this->SubscribeToMessage(Message_CurrentStepsP2Changed);
  this->SubscribeToMessage(Message_CurrentTrailP1Changed);
  this->SubscribeToMessage(Message_CurrentTrailP2Changed);
  this->SubscribeToMessage(Message_PreferredDifficultyP1Changed);
  this->SubscribeToMessage(Message_PreferredDifficultyP2Changed);
  this->SubscribeToMessage(Message_PlayerProfileSet);
}

MusicWheelItem::MusicWheelItem(const MusicWheelItem& cpy)
    : WheelItemBase(cpy),
      GRADES_SHOW_MACHINE(cpy.GRADES_SHOW_MACHINE),
      m_TextBanner(cpy.m_TextBanner),
      m_WheelNotifyIcon(cpy.m_WheelNotifyIcon) {
  FOREACH_ENUM(MusicWheelItemType, i) {
    m_sprColorPart[i] = cpy.m_sprColorPart[i];
    AddLoadedAutoActor(this, m_sprColorPart[i]);

    m_sprNormalPart[i] = cpy.m_sprNormalPart[i];
    AddLoadedAutoActor(this, m_sprNormalPart[i]);
  }

  this->AddChild(&m_TextBanner);

  FOREACH_ENUM(MusicWheelItemType, i) {
    m_sprOverPart[i] = cpy.m_sprOverPart[i];
    AddLoadedAutoActor(this, m_sprOverPart[i]);
  }

  FOREACH_ENUM(MusicWheelItemType, i) {
    if (cpy.m_pText[i] == nullptr) {
      m_pText[i] = nullptr;
    } else {
      m_pText[i] = new BitmapText(*cpy.m_pText[i]);
      this->AddChild(m_pText[i]);
    }
  }

  if (cpy.m_pTextSectionCount == nullptr) {
    m_pTextSectionCount = nullptr;
  } else {
    m_pTextSectionCount = new BitmapText(*cpy.m_pTextSectionCount);
    this->AddChild(m_pTextSectionCount);
  }

  this->AddChild(&m_WheelNotifyIcon);

  FOREACH_PlayerNumber(p) {
    m_pGradeDisplay[p] = cpy.m_pGradeDisplay[p];
    AddLoadedAutoActor(this, m_pGradeDisplay[p]);
  }
}

MusicWheelItem::~MusicWheelItem() {
  FOREACH_ENUM(MusicWheelItemType, i) { RageUtil::SafeDelete(m_pText[i]); }
  delete m_pTextSectionCount;
}

void MusicWheelItem::LoadFromWheelItemData(
    const WheelItemBaseData* pData, int iIndex, bool bHasFocus,
    int iDrawIndex) {
  WheelItemBase::LoadFromWheelItemData(pData, iIndex, bHasFocus, iDrawIndex);

  const MusicWheelItemData* pWID =
      dynamic_cast<const MusicWheelItemData*>(pData);
  if (pWID == nullptr) {
    WarnMusicWheelItem(
        "SRC_AUDIT_FIX SRC-1286: MusicWheelItem ignored non-music wheel item "
        "data.");
    return;
  }

  std::string traceTitle = pWID->m_sText;
  if (pWID->m_pSong != nullptr) {
    traceTitle = pWID->m_pSong->GetDisplayFullTitle();
  } else if (pWID->m_pCourse != nullptr) {
    traceTitle = pWID->m_pCourse->GetDisplayFullTitle();
  } else if (pWID->m_pGroup != nullptr) {
    traceTitle = pWID->m_pGroup->GetDisplayTitle();
  } else if (!pWID->m_sLabel.empty()) {
    traceTitle = pWID->m_sLabel;
  }
  TraceMusicWheelItemReintro(
      "item_load",
      ssprintf(
          "dataIndex=%d drawIndex=%d hasFocus=%d dataType=%d text='%s' "
          "parent='%s'",
          iIndex, iDrawIndex, bHasFocus ? 1 : 0,
          static_cast<int>(pWID->m_Type), traceTitle.c_str(),
          pWID->m_sParentSection.c_str()));

  // hide all
  FOREACH_ENUM(MusicWheelItemType, i) {
    SetAutoActorVisible(m_sprColorPart[i], false);
    SetAutoActorVisible(m_sprNormalPart[i], false);
    SetAutoActorVisible(m_sprOverPart[i], false);
  }
  m_TextBanner.SetVisible(false);
  FOREACH_ENUM(MusicWheelItemType, i)
  if (m_pText[i]) {
    m_pText[i]->SetVisible(false);
  }
  if (m_pTextSectionCount != nullptr) {
    m_pTextSectionCount->SetVisible(false);
  }
  m_WheelNotifyIcon.SetVisible(false);
  FOREACH_PlayerNumber(p) { SetAutoActorVisible(m_pGradeDisplay[p], false); }

  // Fill these in below
  std::string sDisplayName, sTranslitName;
  MusicWheelItemType type = MusicWheelItemType_Invalid;
  const bool isChildSection = pWID->m_Type == WheelItemDataType_Section &&
                              !pWID->m_sParentSection.empty();

  if (!IsValidWheelItemDataType(pWID->m_Type)) {
    WarnMusicWheelItem(
        "SRC_AUDIT_FIX SRC-1288: MusicWheelItem ignored invalid wheel item "
        "type.");
    return;
  }

  switch (pWID->m_Type) {
    case WheelItemDataType_Song:
      type = MusicWheelItemType_Song;

      if (pWID->m_pSong == nullptr) {
        m_TextBanner.SetFromString(pWID->m_sText, "", "", "", "", "");
      } else {
        m_TextBanner.SetFromSong(pWID->m_pSong);
      }
      // We can do this manually if we wanted... maybe have a metric for
      // overrides? -aj
      m_TextBanner.SetDiffuse(pWID->m_color);
      m_TextBanner.SetVisible(true);

      m_WheelNotifyIcon.SetFlags(pWID->m_Flags);
      m_WheelNotifyIcon.SetVisible(true);
      RefreshGrades();
      break;
    case WheelItemDataType_ParentSection: {
      const std::string label =
          pWID->m_sLabel.empty() ? pWID->m_sText : pWID->m_sLabel;
      sDisplayName =
          SONGMAN == nullptr ? label : SONGMAN->ShortenSeriesName(label);
      sTranslitName = sDisplayName;
      if (GAMESTATE != nullptr &&
          GAMESTATE->sExpandedParentSectionName == pWID->m_sText) {
        type = MusicWheelItemType_ParentExpanded;
      } else {
        type = MusicWheelItemType_ParentCollapsed;
      }
      if (m_pTextSectionCount != nullptr) {
        m_pTextSectionCount->SetText(
            ssprintf("%d", SanitizeSectionCount(pWID->m_iSectionCount)));
        m_pTextSectionCount->SetVisible(true);
      }
    } break;
    case WheelItemDataType_Section: {
      if (pWID->m_pGroup == nullptr) {
        sDisplayName = SONGMAN == nullptr
                           ? pWID->m_sText
                           : SONGMAN->ShortenGroupName(pWID->m_sText);
      } else {
        if (pWID->m_pGroup->GetSeries().empty()) {
          sDisplayName = SONGMAN == nullptr
                             ? pWID->m_pGroup->GetDisplayTitle()
                             : SONGMAN->ShortenGroupName(
                                   pWID->m_pGroup->GetDisplayTitle());
          sTranslitName = SONGMAN == nullptr
                              ? pWID->m_pGroup->GetTranslitTitle()
                              : SONGMAN->ShortenGroupName(
                                    pWID->m_pGroup->GetTranslitTitle());
        } else {
          // This will eventually do something different when we eventually
          // implement nested folders for now, use the same behavior.
          sDisplayName = SONGMAN == nullptr
                             ? pWID->m_pGroup->GetDisplayTitle()
                             : SONGMAN->ShortenGroupName(
                                   pWID->m_pGroup->GetDisplayTitle());
          sTranslitName = SONGMAN == nullptr
                              ? pWID->m_pGroup->GetTranslitTitle()
                              : SONGMAN->ShortenGroupName(
                                    pWID->m_pGroup->GetTranslitTitle());
        }
      }
      if (GAMESTATE != nullptr &&
          GAMESTATE->sExpandedSectionName == pWID->m_sText) {
        type = MusicWheelItemType_SectionExpanded;
      } else {
        type = MusicWheelItemType_SectionCollapsed;
      }

      if (m_pTextSectionCount != nullptr) {
        m_pTextSectionCount->SetText(
            ssprintf("%d", SanitizeSectionCount(pWID->m_iSectionCount)));
        m_pTextSectionCount->SetVisible(true);
      }
    } break;
    case WheelItemDataType_Course:
      if (pWID->m_pCourse == nullptr) {
        sDisplayName = pWID->m_sText;
        sTranslitName = "";
      } else {
        sDisplayName = pWID->m_pCourse->GetDisplayFullTitle();
        sTranslitName = pWID->m_pCourse->GetTranslitFullTitle();
      }
      type = MusicWheelItemType_Course;
      m_WheelNotifyIcon.SetFlags(pWID->m_Flags);
      m_WheelNotifyIcon.SetVisible(true);
      break;
    case WheelItemDataType_Sort:
      sDisplayName = pWID->m_sLabel;
      // hack to get mode items working. -freem
      if (!pWID->m_pAction.isNull() &&
          pWID->m_pAction->m_pm != PlayMode_Invalid) {
        type = MusicWheelItemType_Mode;
      } else {
        type = MusicWheelItemType_Sort;
      }
      break;
    case WheelItemDataType_Roulette:
      sDisplayName =
          GetThemeStringOrFallback("MusicWheel", "Roulette", "Roulette");
      type = MusicWheelItemType_Roulette;
      break;
    case WheelItemDataType_Random:
      sDisplayName = GetThemeStringOrFallback("MusicWheel", "Random", "Random");
      type = MusicWheelItemType_Random;
      break;
    case WheelItemDataType_Portal:
      sDisplayName = GetThemeStringOrFallback("MusicWheel", "Portal", "Portal");
      type = MusicWheelItemType_Portal;
      break;
    case WheelItemDataType_Custom:
      sDisplayName = pWID->m_sLabel;
      type = MusicWheelItemType_Custom;
      break;
    case WheelItemDataType_Generic:
      sDisplayName = pWID->m_sText;
      type = MusicWheelItemType_Custom;
      break;
    default:
      return;
  }

  if (!IsValidMusicWheelItemType(type)) {
    WarnMusicWheelItem(
        "SRC_AUDIT_FIX SRC-1294: MusicWheelItem skipped invalid visual type.");
    return;
  }

  if (m_sprColorPart[type].IsLoaded()) {
    m_sprColorPart[type]->SetVisible(true);
    m_sprColorPart[type]->SetDiffuse(pWID->m_color);
  }
  SetAutoActorVisible(m_sprNormalPart[type], true);
  SetAutoActorVisible(m_sprOverPart[type], true);
  BitmapText* bt = m_pText[type];
  if (bt) {
    bt->SetText(sDisplayName, sTranslitName);
    bt->SetDiffuse(pWID->m_color);
    bt->SetVisible(true);
    if (isChildSection && THEME != nullptr) {
      bt->SetX(THEME->GetMetricF("MusicWheelItem", "ChildSectionX"));
      bt->SetY(THEME->GetMetricF("MusicWheelItem", "ChildSectionY"));
    } else {
      ActorUtil::SetXY(*bt, "MusicWheelItem");
    }
  }

  if (m_pTextSectionCount != nullptr) {
    if (isChildSection && THEME != nullptr) {
      m_pTextSectionCount->SetX(
          THEME->GetMetricF("MusicWheelItem", "ChildSectionCountX"));
      m_pTextSectionCount->SetY(
          THEME->GetMetricF("MusicWheelItem", "ChildSectionCountY"));
    } else {
      ActorUtil::SetXY(m_pTextSectionCount, "MusicWheelItem");
    }
  }

  FOREACH_ENUM(MusicWheelItemType, i) {
    if (m_sprColorPart[i].IsLoaded() && m_sprColorPart[i]->GetVisible()) {
      SetGrayBar(m_sprColorPart[i]);
      break;
    }
  }

  // Call "Set" so that elements like TextBanner react to the change in song.
  {
    Message msg("Set");
    msg.SetParam("Song", pWID->m_pSong);
    msg.SetParam("Course", pWID->m_pCourse);
    msg.SetParam("Index", iIndex);
    msg.SetParam("HasFocus", bHasFocus);
    msg.SetParam("Text", pWID->m_sText);
    msg.SetParam("DrawIndex", iDrawIndex);
    msg.SetParam("Type", MusicWheelItemTypeToString(type));
    msg.SetParam("Color", pWID->m_color);
    msg.SetParam("Label", pWID->m_sLabel);
    msg.SetParam("ParentSection", pWID->m_sParentSection);
    msg.SetParam(
        "IsParentSection", pWID->m_Type == WheelItemDataType_ParentSection);

    WheelItemBase::HandleMessage(msg);
  }
}

void MusicWheelItem::RefreshGrades() {
  if (!IsLoaded()) {
    return;
  }
  const MusicWheelItemData* pWID =
      dynamic_cast<const MusicWheelItemData*>(m_pData);

  if (pWID == nullptr || GAMESTATE == nullptr || PROFILEMAN == nullptr) {
    return;  // LoadFromWheelItemData() hasn't been called yet.
  }
  FOREACH_HumanPlayer(p) {
    SetAutoActorVisible(m_pGradeDisplay[p], false);
    if (!m_pGradeDisplay[p].IsLoaded()) {
      continue;
    }

    if (pWID->m_pSong == nullptr && pWID->m_pCourse == nullptr) {
      continue;
    }

    Difficulty dc;
    if (GAMESTATE->m_pCurSteps[p]) {
      dc = GAMESTATE->m_pCurSteps[p]->GetDifficulty();
    } else if (GAMESTATE->m_pCurTrail[p]) {
      dc = GAMESTATE->m_pCurTrail[p]->m_CourseDifficulty;
    } else {
      dc = GAMESTATE->m_PreferredDifficulty[p];
    }

    ProfileSlot ps;
    if (PROFILEMAN->IsPersistentProfile(p)) {
      ps = (ProfileSlot)p;
    } else if (GetGradesShowMachine(GRADES_SHOW_MACHINE)) {
      ps = ProfileSlot_Machine;
    } else {
      continue;
    }

    StepsType st;
    if (GAMESTATE->m_pCurSteps[p]) {
      st = GAMESTATE->m_pCurSteps[p]->m_StepsType;
    } else if (GAMESTATE->m_pCurTrail[p]) {
      st = GAMESTATE->m_pCurTrail[p]->m_StepsType;
    } else {
      st = GetFallbackStepsType();
      if (st == StepsType_Invalid) {
        continue;
      }
    }

    m_pGradeDisplay[p]->SetVisible(true);

    Profile* pProfile = PROFILEMAN->GetProfile(ps);
    if (pProfile == nullptr || dc == Difficulty_Invalid ||
        st == StepsType_Invalid) {
      Message msg("SetGrade");
      msg.SetParam("PlayerNumber", p);
      m_pGradeDisplay[p]->HandleMessage(msg);
      continue;
    }

    HighScoreList* pHSL = nullptr;
    if (PROFILEMAN->IsPersistentProfile(ps)) {
      if (pWID->m_pSong) {
        const Steps* pSteps =
            SongUtil::GetStepsByDifficulty(pWID->m_pSong, st, dc);
        if (pSteps != nullptr) {
          pHSL = &pProfile->GetStepsHighScoreList(pWID->m_pSong, pSteps);
        }
      } else if (pWID->m_pCourse) {
        const Trail* pTrail = pWID->m_pCourse->GetTrail(st, dc);
        if (pTrail != nullptr) {
          pHSL = &pProfile->GetCourseHighScoreList(pWID->m_pCourse, pTrail);
        }
      }
    }

    Message msg("SetGrade");
    msg.SetParam("PlayerNumber", p);
    if (pHSL) {
      msg.SetParam("Grade", pHSL->HighGrade);
      msg.SetParam("NumTimesPlayed", pHSL->GetNumTimesPlayed());

      // Until we get a Grade for quints (need W0 support), send back the entire
      // HighScoreList so we can determine if a player has a quint or not.
      // TODO: Remove this once we have W0 support.
      msg.SetParam("HighScoreList", pHSL);
    }
    m_pGradeDisplay[p]->HandleMessage(msg);
  }
}

void MusicWheelItem::HandleMessage(const Message& msg) {
  if (!IsLoaded()) {
    return;
  }
  if (msg == Message_CurrentStepsP1Changed ||
      msg == Message_CurrentStepsP2Changed ||
      msg == Message_CurrentTrailP1Changed ||
      msg == Message_CurrentTrailP2Changed ||
      msg == Message_PreferredDifficultyP1Changed ||
      msg == Message_PreferredDifficultyP2Changed ||
      msg == Message_PlayerProfileSet) {
    const MusicWheelItemData* pWID =
        dynamic_cast<const MusicWheelItemData*>(m_pData);
    if (pWID == nullptr || !IsValidWheelItemDataType(pWID->m_Type)) {
      return;
    }
    MusicWheelItemType type = MusicWheelItemType_Invalid;

    switch (pWID->m_Type) {
      case WheelItemDataType_Song:
        type = MusicWheelItemType_Song;
        break;
      case WheelItemDataType_Section:
        if (GAMESTATE != nullptr &&
            GAMESTATE->sExpandedSectionName == pWID->m_sText) {
          type = MusicWheelItemType_SectionExpanded;
        } else {
          type = MusicWheelItemType_SectionCollapsed;
        }
        break;
      case WheelItemDataType_ParentSection:
        if (GAMESTATE != nullptr &&
            GAMESTATE->sExpandedParentSectionName == pWID->m_sText) {
          type = MusicWheelItemType_ParentExpanded;
        } else {
          type = MusicWheelItemType_ParentCollapsed;
        }
        break;
      case WheelItemDataType_Course:
        type = MusicWheelItemType_Course;
        break;
      case WheelItemDataType_Sort:
        if (!pWID->m_pAction.isNull() &&
            pWID->m_pAction->m_pm != PlayMode_Invalid) {
          type = MusicWheelItemType_Mode;
        } else {
          type = MusicWheelItemType_Sort;
        }
        break;
      case WheelItemDataType_Roulette:
        type = MusicWheelItemType_Roulette;
        break;
      case WheelItemDataType_Random:
        type = MusicWheelItemType_Random;
        break;
      case WheelItemDataType_Portal:
        type = MusicWheelItemType_Portal;
        break;
      case WheelItemDataType_Custom:
        type = MusicWheelItemType_Custom;
        break;
      case WheelItemDataType_Generic:
        type = MusicWheelItemType_Custom;
        break;
      default:
        return;
    }
    if (!IsValidMusicWheelItemType(type)) {
      return;
    }

    Message setMsg("Set");
    setMsg.SetParam("Song", pWID->m_pSong);
    setMsg.SetParam("Course", pWID->m_pCourse);
    setMsg.SetParam("Text", pWID->m_sText);
    setMsg.SetParam("Type", MusicWheelItemTypeToString(type));
    setMsg.SetParam("Color", pWID->m_color);
    setMsg.SetParam("Label", pWID->m_sLabel);
    setMsg.SetParam("ParentSection", pWID->m_sParentSection);
    setMsg.SetParam(
        "IsParentSection", pWID->m_Type == WheelItemDataType_ParentSection);
    WheelItemBase::HandleMessage(setMsg);

    RefreshGrades();
  }

  WheelItemBase::HandleMessage(msg);
}

/*
 * (c) 2001-2004 Chris Danford, Chris Gomez, Glenn Maynard
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
