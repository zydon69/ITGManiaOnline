#include "ScreenSelectMaster.h"

#include <algorithm>
#include <cstddef>
#include <cmath>
#include <cstdio>
#include <map>
#include <set>
#include <string>
#include <vector>

#include "ActorScroller.h"
#include "ActorUtil.h"
#include "AnnouncerManager.h"
#include "AutoActor.h"
#include "EnumHelper.h"
#include "GameCommand.h"
#include "GameInput.h"
#include "GameSoundManager.h"
#include "GameState.h"
#include "InputEventPlus.h"
#include "InputFilter.h"
#include "LuaManager.h"
#include "MessageManager.h"
#include "PlayerNumber.h"
#include "RageTypes.h"
#include "RageUtil.h"
#include "Screen.h"
#include "ScreenManager.h"
#include "ScreenMessage.h"
#include "ScreenSelect.h"
#include "ScreenWithMenuElements.h"
#include "StdString.h"
#include "ThemeManager.h"
#include "global.h"

static const char* MenuDirNames[] = {
    "Up", "Down", "Left", "Right", "Auto",
};
XToString(MenuDir);

AutoScreenMessage(SM_PlayPostSwitchPage);

namespace {
void WarnScreenSelectMaster(const std::string& message) {
  if (LOG != nullptr) {
    LOG->Warn("ScreenSelectMaster: %s", message.c_str());
  }
}

std::string GetThemePathG(
    const std::string& group, const std::string& element) {
  if (THEME == nullptr || !THEME->IsThemeLoaded()) {
    return "";
  }
  return THEME->GetPathG(group, element);
}

std::string GetThemePathS(
    const std::string& group, const std::string& element) {
  if (THEME == nullptr || !THEME->IsThemeLoaded()) {
    return "";
  }
  return THEME->GetPathS(group, element);
}

bool IsFiniteNonNegative(float value) {
  return std::isfinite(value) && value >= 0.0f;
}
}  // namespace

static std::string CURSOR_OFFSET_X_FROM_ICON_NAME(size_t p) {
  return ssprintf("CursorP%dOffsetXFromIcon", int(p + 1));
}
static std::string CURSOR_OFFSET_Y_FROM_ICON_NAME(size_t p) {
  return ssprintf("CursorP%dOffsetYFromIcon", int(p + 1));
}
// e.g. "OptionOrderLeft=0:1,1:2,2:3,3:4"
static std::string OPTION_ORDER_NAME(size_t dir) {
  return "OptionOrder" + MenuDirToString((MenuDir)dir);
}

REGISTER_SCREEN_CLASS(ScreenSelectMaster);

ScreenSelectMaster::ScreenSelectMaster() {
  ZERO(m_iChoice);
  ZERO(m_bChosen);
  ZERO(m_bDoubleChoice);
  m_bDoubleChoiceNoSound = false;
  m_TrackingRepeatingInput = GameButton_Invalid;
}

bool ScreenSelectMaster::IsValidPlayer(PlayerNumber pn) const {
  return pn >= PLAYER_1 && pn < NUM_PLAYERS;
}

bool ScreenSelectMaster::IsValidChoice(int iChoice) const {
  return iChoice >= 0 && iChoice < static_cast<int>(m_aGameCommands.size());
}

int ScreenSelectMaster::ClampChoice(int iChoice, int fallback) const {
  if (m_aGameCommands.empty()) {
    return 0;
  }
  if (!IsValidChoice(fallback)) {
    fallback = 0;
  }
  if (!IsValidChoice(iChoice)) {
    return fallback;
  }
  return iChoice;
}

int ScreenSelectMaster::GetNumChoicesOnPage1() const {
  int value = NUM_CHOICES_ON_PAGE_1.IsLoaded()
                  ? NUM_CHOICES_ON_PAGE_1.GetValue()
                  : static_cast<int>(m_aGameCommands.size());
  return std::clamp(value, 0, static_cast<int>(m_aGameCommands.size()));
}

float ScreenSelectMaster::GetPreSwitchPageSeconds() const {
  const float value =
      PRE_SWITCH_PAGE_SECONDS.IsLoaded() ? PRE_SWITCH_PAGE_SECONDS.GetValue()
                                         : 0.0f;
  return IsFiniteNonNegative(value) ? value : 0.0f;
}

float ScreenSelectMaster::GetPostSwitchPageSeconds() const {
  const float value =
      POST_SWITCH_PAGE_SECONDS.IsLoaded() ? POST_SWITCH_PAGE_SECONDS.GetValue()
                                          : 0.0f;
  return IsFiniteNonNegative(value) ? value : 0.0f;
}

float ScreenSelectMaster::GetScrollerSecondsPerItem() const {
  const float value =
      SCROLLER_SECONDS_PER_ITEM.IsLoaded() ? SCROLLER_SECONDS_PER_ITEM.GetValue()
                                           : 0.0f;
  return IsFiniteNonNegative(value) ? value : 0.0f;
}

float ScreenSelectMaster::GetScrollerNumItemsToDraw() const {
  const float value = SCROLLER_NUM_ITEMS_TO_DRAW.IsLoaded()
                          ? SCROLLER_NUM_ITEMS_TO_DRAW.GetValue()
                          : 0.0f;
  if (!IsFiniteNonNegative(value)) {
    return 0.0f;
  }
  return std::min(value, static_cast<float>(std::max<size_t>(
                             1, m_aGameCommands.size())));
}

int ScreenSelectMaster::GetScrollerSubdivisions() const {
  const int value = SCROLLER_SUBDIVISIONS.IsLoaded()
                        ? SCROLLER_SUBDIVISIONS.GetValue()
                        : 1;
  return std::clamp(value, 1, 128);
}

bool ScreenSelectMaster::ShowIcon() const {
  return SHOW_ICON.IsLoaded() && SHOW_ICON.GetValue();
}

bool ScreenSelectMaster::ShowScroller() const {
  return SHOW_SCROLLER.IsLoaded() && SHOW_SCROLLER.GetValue();
}

bool ScreenSelectMaster::ShowCursor() const {
  return SHOW_CURSOR.IsLoaded() && SHOW_CURSOR.GetValue();
}

bool ScreenSelectMaster::IsSharedSelection() const {
  return SHARED_SELECTION.IsLoaded() && SHARED_SELECTION.GetValue();
}

bool ScreenSelectMaster::DoublePressToSelect() const {
  return DOUBLE_PRESS_TO_SELECT.IsLoaded() && DOUBLE_PRESS_TO_SELECT.GetValue();
}

bool ScreenSelectMaster::AllowRepeatingInput() const {
  return ALLOW_REPEATING_INPUT.IsLoaded() && ALLOW_REPEATING_INPUT.GetValue();
}

bool ScreenSelectMaster::WrapCursor() const {
  return WRAP_CURSOR.IsLoaded() && WRAP_CURSOR.GetValue();
}

bool ScreenSelectMaster::WrapScroller() const {
  return WRAP_SCROLLER.IsLoaded() && WRAP_SCROLLER.GetValue();
}

bool ScreenSelectMaster::DoSwitchAnyways() const {
  return DO_SWITCH_ANYWAYS.IsLoaded() && DO_SWITCH_ANYWAYS.GetValue();
}

void ScreenSelectMaster::GetActiveElementPlayerNumbers(
    std::vector<PlayerNumber>& vpns) const {
  vpns.clear();
  if (IsSharedSelection()) {
    vpns.push_back(PLAYER_1);
    return;
  }
  if (GAMESTATE == nullptr) {
    return;
  }
  FOREACH_HumanPlayer(p) {
    if (IsValidPlayer(p)) {
      vpns.push_back(p);
    }
  }
}

void ScreenSelectMaster::Init() {
  SHOW_ICON.Load(m_sName, "ShowIcon");
  SHOW_SCROLLER.Load(m_sName, "ShowScroller");
  SHOW_CURSOR.Load(m_sName, "ShowCursor");
  SHARED_SELECTION.Load(m_sName, "SharedSelection");
  USE_ICON_METRICS.Load(m_sName, "UseIconMetrics");
  NUM_CHOICES_ON_PAGE_1.Load(m_sName, "NumChoicesOnPage1");
  CURSOR_OFFSET_X_FROM_ICON.Load(
      m_sName, CURSOR_OFFSET_X_FROM_ICON_NAME, NUM_PLAYERS);
  CURSOR_OFFSET_Y_FROM_ICON.Load(
      m_sName, CURSOR_OFFSET_Y_FROM_ICON_NAME, NUM_PLAYERS);
  PER_CHOICE_ICON_ELEMENT.Load(m_sName, "PerChoiceIconElement");
  PRE_SWITCH_PAGE_SECONDS.Load(m_sName, "PreSwitchPageSeconds");
  POST_SWITCH_PAGE_SECONDS.Load(m_sName, "PostSwitchPageSeconds");
  OPTION_ORDER.Load(m_sName, OPTION_ORDER_NAME, NUM_MenuDir);
  DO_SWITCH_ANYWAYS.Load(m_sName, "DoSwitchAnyways");

  WRAP_CURSOR.Load(m_sName, "WrapCursor");
  WRAP_SCROLLER.Load(m_sName, "WrapScroller");
  LOOP_SCROLLER.Load(m_sName, "LoopScroller");
  PER_CHOICE_SCROLL_ELEMENT.Load(m_sName, "PerChoiceScrollElement");
  ALLOW_REPEATING_INPUT.Load(m_sName, "AllowRepeatingInput");
  SCROLLER_SECONDS_PER_ITEM.Load(m_sName, "ScrollerSecondsPerItem");
  SCROLLER_NUM_ITEMS_TO_DRAW.Load(m_sName, "ScrollerNumItemsToDraw");
  SCROLLER_TRANSFORM.Load(m_sName, "ScrollerTransform");
  // SCROLLER_TWEEN.Load( m_sName, "ScrollerTween" );
  SCROLLER_SUBDIVISIONS.Load(m_sName, "ScrollerSubdivisions");
  DEFAULT_CHOICE.Load(m_sName, "DefaultChoice");
  DOUBLE_PRESS_TO_SELECT.Load(m_sName, "DoublePressToSelect");

  ScreenSelect::Init();

  m_TrackingRepeatingInput = GameButton_Invalid;

  std::vector<PlayerNumber> vpns;
  GetActiveElementPlayerNumbers(vpns);

#define PLAYER_APPEND_NO_SPACE(p) \
  (IsSharedSelection() ? std::string() : ssprintf("P%d", (p) + 1))
  this->SubscribeToMessage(SM_MenuTimer);

  // init cursor
  if (ShowCursor()) {
    for (const PlayerNumber& p : vpns) {
      std::string sElement = "Cursor" + PLAYER_APPEND_NO_SPACE(p);
      m_sprCursor[p].Load(GetThemePathG(m_sName, sElement));
      if (!m_sprCursor[p].IsLoaded()) {
        WarnScreenSelectMaster(m_sName + " missing cursor actor " + sElement);
        continue;
      }
      Replace(sElement, " ", "");
      m_sprCursor[p]->SetName(sElement);
      this->AddChild(m_sprCursor[p]);
      LOAD_ALL_COMMANDS(m_sprCursor[p]);
    }
  }

  // Resize vectors depending on how many choices there are
  m_vsprIcon.resize(m_aGameCommands.size());
  FOREACH_PlayerNumber(p) {
    m_vsprScroll[p].resize(m_aGameCommands.size());
  }

  std::vector<RageVector3> positions;
  bool positions_set_by_lua = false;
  if (THEME != nullptr && THEME->HasMetric(m_sName, "IconChoicePosFunction")) {
    positions_set_by_lua = true;
    LuaReference command = THEME->GetMetricR(m_sName, "IconChoicePosFunction");
    if (command.GetLuaType() != LUA_TFUNCTION) {
      LuaHelpers::ReportScriptError(
          m_sName + "::IconChoicePosFunction must be a function.");
      positions_set_by_lua = false;
    } else {
      if (LUA == nullptr) {
        WarnScreenSelectMaster(
            m_sName + " ignored IconChoicePosFunction without LUA.");
        positions_set_by_lua = false;
      } else {
        Lua* L = LUA->Get();
        command.PushSelf(L);
        lua_pushnumber(L, m_aGameCommands.size());
        std::string err = m_sName + "::IconChoicePosFunction: ";
        if (!LuaHelpers::RunScriptOnStack(L, err, 1, 1, true)) {
          positions_set_by_lua = false;
        } else {
          if (!lua_istable(L, -1)) {
            LuaHelpers::ReportScriptError(
                m_sName +
                "::IconChoicePosFunction did not return a table of positions.");
            positions_set_by_lua = false;
          } else {
            size_t poses = lua_objlen(L, -1);
            for (size_t p = 1; p <= poses; ++p) {
              lua_rawgeti(L, -1, p);
              RageVector3 pos(0.0f, 0.0f, 0.0f);
              if (!lua_istable(L, -1)) {
                LuaHelpers::ReportScriptErrorFmt(
                    "Position %zu is not a table.", p);
              } else {
#define SET_POS_PART(i, part)     \
  lua_rawgeti(L, -1, i);          \
  pos.part = lua_tonumber(L, -1); \
  lua_pop(L, 1);
                // If part of the position is not provided, we want it to
                // default to zero, which lua_tonumber does. -Kyz
                SET_POS_PART(1, x);
                SET_POS_PART(2, y);
                SET_POS_PART(3, z);
#undef SET_POS_PART
              }
              lua_pop(L, 1);
              positions.push_back(pos);
            }
          }
        }
        lua_settop(L, 0);
        LUA->Release(L);
      }
    }
  }

  if (positions_set_by_lua &&
      positions.size() < m_aGameCommands.size()) {
    WarnScreenSelectMaster(
        m_sName + " IconChoicePosFunction returned too few positions.");
    positions_set_by_lua = false;
  }

  for (unsigned c = 0; c < m_aGameCommands.size(); c++) {
    GameCommand& mc = m_aGameCommands[c];

    LuaThreadVariable var("GameCommand", LuaReference::Create(&mc));

    // init icon
    if (ShowIcon()) {
      std::vector<std::string> vs;
      vs.push_back("Icon");
      if (PER_CHOICE_ICON_ELEMENT) {
        vs.push_back("Choice" + mc.m_sName);
      }
      std::string sElement = join(" ", vs);
      m_vsprIcon[c].Load(GetThemePathG(m_sName, sElement));
      if (!m_vsprIcon[c].IsLoaded()) {
        WarnScreenSelectMaster(m_sName + " missing icon actor " + sElement);
        continue;
      }
      std::string sName =
          "Icon"
          "Choice" +
          mc.m_sName;
      m_vsprIcon[c]->SetName(sName);
      if (USE_ICON_METRICS) {
        if (positions_set_by_lua) {
          LOAD_ALL_COMMANDS(m_vsprIcon[c]);
          const RageVector3 pos(
              std::isfinite(positions[c].x) ? positions[c].x : 0.0f,
              std::isfinite(positions[c].y) ? positions[c].y : 0.0f,
              std::isfinite(positions[c].z) ? positions[c].z : 0.0f);
          m_vsprIcon[c]->SetXY(pos.x, pos.y);
          m_vsprIcon[c]->SetZ(pos.z);
        } else {
          LOAD_ALL_COMMANDS_AND_SET_XY(m_vsprIcon[c]);
        }
#define OPTIONAL_COMMAND(onoff)                                          \
  if (THEME != nullptr &&                                                \
      THEME->HasMetric(m_sName, "IconChoice" onoff "Command")) {         \
    m_vsprIcon[c]->AddCommand(                                           \
        onoff, THEME->GetMetricA(m_sName, "IconChoice" onoff "Command"), \
        false);                                                          \
  }
        OPTIONAL_COMMAND("On");
        OPTIONAL_COMMAND("Off");
#undef OPTIONAL_COMMAND
      }
      this->AddChild(m_vsprIcon[c]);
    }

    // init scroll
    if (ShowScroller()) {
      for (const PlayerNumber& p : vpns) {
        std::vector<std::string> vs;
        vs.push_back("Scroll");
        if (PER_CHOICE_SCROLL_ELEMENT) {
          vs.push_back("Choice" + mc.m_sName);
        }
        if (!IsSharedSelection()) {
          vs.push_back(PLAYER_APPEND_NO_SPACE(p));
        }
        std::string sElement = join(" ", vs);
        m_vsprScroll[p][c].Load(GetThemePathG(m_sName, sElement));
        if (!m_vsprScroll[p][c].IsLoaded()) {
          WarnScreenSelectMaster(m_sName + " missing scroll actor " + sElement);
          continue;
        }
        std::string sName =
            "Scroll"
            "Choice" +
            mc.m_sName;
        if (!IsSharedSelection()) {
          sName += PLAYER_APPEND_NO_SPACE(p);
        }
        m_vsprScroll[p][c]->SetName(sName);
        m_Scroller[p].AddChild(m_vsprScroll[p][c]);
      }
    }
  }

  // init scroll
  if (ShowScroller()) {
    for (const PlayerNumber& p : vpns) {
      m_Scroller[p].SetLoop(LOOP_SCROLLER);
      m_Scroller[p].SetNumItemsToDraw(GetScrollerNumItemsToDraw());
      m_Scroller[p].Load2();
      m_Scroller[p].SetTransformFromReference(SCROLLER_TRANSFORM);
      m_Scroller[p].SetSecondsPerItem(GetScrollerSecondsPerItem());
      m_Scroller[p].SetNumSubdivisions(GetScrollerSubdivisions());
      m_Scroller[p].SetName("Scroller" + PLAYER_APPEND_NO_SPACE(p));
      LOAD_ALL_COMMANDS_AND_SET_XY(m_Scroller[p]);
      this->AddChild(&m_Scroller[p]);
    }
  }

  FOREACH_ENUM(Page, page) {
    m_sprMore[page].Load(
        GetThemePathG(m_sName, ssprintf("more page%d", page + 1)));
    if (m_sprMore[page].IsLoaded()) {
      m_sprMore[page]->SetName(ssprintf("MorePage%d", page + 1));
      LOAD_ALL_COMMANDS_AND_SET_XY(m_sprMore[page]);
      this->AddChild(m_sprMore[page]);
    }

    m_sprExplanation[page].Load(
        GetThemePathG(m_sName, ssprintf("explanation page%d", page + 1)));
    if (m_sprExplanation[page].IsLoaded()) {
      m_sprExplanation[page]->SetName(
          ssprintf("ExplanationPage%d", page + 1));
      LOAD_ALL_COMMANDS_AND_SET_XY(m_sprExplanation[page]);
      this->AddChild(m_sprExplanation[page]);
    }
  }

  m_soundChange.Load(GetThemePathS(m_sName, "change"), true);
  if (ANNOUNCER != nullptr) {
    m_soundDifficult.Load(ANNOUNCER->GetPathTo("select difficulty challenge"));
  }
  m_soundStart.Load(GetThemePathS(m_sName, "start"));

  // init m_Next order info
  FOREACH_MenuDir(dir) {
    const std::string order = OPTION_ORDER.GetValue(dir);
    std::vector<std::string> parts;
    split(order, ",", parts, true);

    for (unsigned part = 0; part < parts.size(); ++part) {
      int from, to;
      if (sscanf(parts[part].c_str(), "%d:%d", &from, &to) != 2) {
        LuaHelpers::ReportScriptErrorFmt(
            "%s::OptionOrder%s parse error", m_sName.c_str(),
            MenuDirToString(dir).c_str());
        continue;
      }

      --from;
      --to;
      if (!IsValidChoice(from) || !IsValidChoice(to) || from == to) {
        WarnScreenSelectMaster(ssprintf(
            "%s ignored invalid OptionOrder%s entry '%s'.", m_sName.c_str(),
            MenuDirToString(dir).c_str(), parts[part].c_str()));
        continue;
      }

      m_mapCurrentChoiceToNextChoice[dir][from] = to;
    }

    if (m_aGameCommands.empty()) {
      continue;
    }

    // Fill missing mappings so corrupt or partial metrics don't strand the
    // cursor on an unmapped choice.
    for (unsigned c = 0; c < m_aGameCommands.size(); ++c) {
      if (m_mapCurrentChoiceToNextChoice[dir].find(c) !=
          m_mapCurrentChoiceToNextChoice[dir].end()) {
        continue;
      }
      int add;
      switch (dir) {
        case MenuDir_Up:
        case MenuDir_Left:
          add = -1;
          break;
        default:
          add = +1;
          break;
      }

      int nextChoice = static_cast<int>(c) + add;
      // Always wrap around MenuDir_Auto.
      if (dir == MenuDir_Auto || WrapCursor()) {
        wrap(nextChoice, m_aGameCommands.size());
      } else {
        nextChoice =
            std::clamp(nextChoice, 0, (int)m_aGameCommands.size() - 1);
      }
      m_mapCurrentChoiceToNextChoice[dir][c] = nextChoice;
    }
  }

  m_bDoubleChoiceNoSound = false;
}

std::string ScreenSelectMaster::GetDefaultChoice() {
  return DEFAULT_CHOICE.GetValue();
}

void ScreenSelectMaster::BeginScreen() {
  if (m_aGameCommands.empty()) {
    WarnScreenSelectMaster(m_sName + " began with no game commands.");
  }
  // TODO: Move default choice to ScreenSelect
  const std::string sDefaultChoice = GetDefaultChoice();
  int iDefaultChoice = -1;
  for (unsigned c = 0; c < m_aGameCommands.size(); c++) {
    const GameCommand& mc = m_aGameCommands[c];
    if (mc.m_sName == sDefaultChoice) {
      iDefaultChoice = c;
      break;
    }
  }

  FOREACH_PlayerNumber(p) {
    m_iChoice[p] = ClampChoice((iDefaultChoice != -1) ? iDefaultChoice : 0);
    m_bChosen[p] = false;
    m_bDoubleChoice[p] = false;
  }
  if (!IsSharedSelection()) {
    FOREACH_ENUM(PlayerNumber, pn) {
      if (GAMESTATE != nullptr && GAMESTATE->IsHumanPlayer(pn)) {
        continue;
      }
      if (ShowCursor()) {
        if (m_sprCursor[pn]) {
          m_sprCursor[pn]->SetVisible(false);
        }
      }
      if (ShowScroller()) {
        m_Scroller[pn].SetVisible(false);
      }
    }
  }

  this->UpdateSelectableChoices();

  ScreenSelect::BeginScreen();

  // Call GetTweenTimeLeft after the base BeginScreen has started the in
  // Transition.
  m_fLockInputSecs = this->GetTweenTimeLeft();
}

void ScreenSelectMaster::HandleScreenMessage(const ScreenMessage SM) {
  ScreenSelect::HandleScreenMessage(SM);

  std::vector<PlayerNumber> vpns;
  GetActiveElementPlayerNumbers(vpns);

  if (SM == SM_PlayPostSwitchPage) {
    const PlayerNumber master =
        GAMESTATE != nullptr ? GAMESTATE->GetMasterPlayerNumber() : PLAYER_1;
    if (!IsValidPlayer(master)) {
      WarnScreenSelectMaster(
          m_sName + " ignored post switch page with invalid master.");
      return;
    }
    const int iNewChoice = ClampChoice(m_iChoice[master]);
    Page newPage = GetPage(iNewChoice);

    Message msg("PostSwitchPage");
    msg.SetParam("NewPageIndex", (int)newPage);

    if (ShowCursor()) {
      for (const PlayerNumber& p : vpns) {
        if (IsValidPlayer(p) && m_sprCursor[p].IsLoaded()) {
          m_sprCursor[p]->HandleMessage(msg);
        }
      }
    }

    if (ShowScroller()) {
      for (const PlayerNumber& p : vpns) {
        const int iChoice = IsValidPlayer(p) ? ClampChoice(m_iChoice[p]) : 0;
        if (IsValidPlayer(p) && iChoice < static_cast<int>(m_vsprScroll[p].size()) &&
            m_vsprScroll[p][iChoice].IsLoaded()) {
          m_vsprScroll[p][iChoice]->HandleMessage(msg);
        }
      }
    }
    if (MESSAGEMAN != nullptr) {
      MESSAGEMAN->Broadcast(msg);
    }

    m_fLockInputSecs = GetPostSwitchPageSeconds();
  } else if (SM == SM_MenuTimer) {
    if (DoublePressToSelect()) {
      FOREACH_HumanPlayer(p) {
        if (!IsValidPlayer(p)) {
          continue;
        }
        m_bDoubleChoiceNoSound = true;
        m_bDoubleChoice[p] = true;
        InputEventPlus iep;
        iep.pn = p;
        MenuStart(iep);
      }
    }
  }
}

void ScreenSelectMaster::HandleMessage(const Message& msg) {
  if (msg == Message_PlayerJoined) {
    UpdateSelectableChoices();
  }

  ScreenSelect::HandleMessage(msg);
}

int ScreenSelectMaster::GetSelectionIndex(PlayerNumber pn) {
  if (!IsValidPlayer(pn)) {
    return -1;
  }
  return m_iChoice[pn];
}

void ScreenSelectMaster::UpdateSelectableChoices() {
  std::vector<PlayerNumber> vpns;
  GetActiveElementPlayerNumbers(vpns);
  int first_playable = -1;
  bool on_unplayable[NUM_PLAYERS];
  FOREACH_PlayerNumber(pn) { on_unplayable[pn] = false; }

  for (unsigned c = 0; c < m_aGameCommands.size(); c++) {
    std::string command = "Enabled";
    bool disabled = false;
    if (!m_aGameCommands[c].IsPlayable()) {
      command = "Disabled";
      disabled = true;
    } else if (first_playable == -1) {
      first_playable = c;
    }
    if (ShowIcon() && c < m_vsprIcon.size() && m_vsprIcon[c].IsLoaded()) {
      m_vsprIcon[c]->PlayCommand(command);
    }

    for (PlayerNumber& p : vpns) {
      if (!IsValidPlayer(p)) {
        continue;
      }
      if (disabled && m_iChoice[p] == static_cast<int>(c)) {
        on_unplayable[p] = true;
      }
      if (c < m_vsprScroll[p].size() && m_vsprScroll[p][c].IsLoaded()) {
        m_vsprScroll[p][c]->PlayCommand(command);
      }
    }
  }
  for (PlayerNumber& pn : vpns) {
    if (on_unplayable[pn] && first_playable != -1) {
      ChangeSelection(
          pn, first_playable < m_iChoice[pn] ? MenuDir_Left : MenuDir_Right,
          first_playable);
    }
  }

  /* If no options are playable at all, just wait.  Some external
   * stimulus may make options available (such as coin insertion).
   * If any options are playable, make sure one is selected. */
  FOREACH_HumanPlayer(p) {
    if (IsValidPlayer(p) && !m_aGameCommands.empty() &&
        IsValidChoice(m_iChoice[p]) &&
        !m_aGameCommands[m_iChoice[p]].IsPlayable()) {
      Move(p, MenuDir_Auto);
    }
  }
}

bool ScreenSelectMaster::AnyOptionsArePlayable() const {
  for (unsigned i = 0; i < m_aGameCommands.size(); ++i) {
    if (m_aGameCommands[i].IsPlayable()) {
      return true;
    }
  }

  return false;
}

bool ScreenSelectMaster::Move(PlayerNumber pn, MenuDir dir) {
  if (!IsValidPlayer(pn) || dir < 0 || dir >= NUM_MenuDir ||
      !AnyOptionsArePlayable() || m_aGameCommands.empty()) {
    return false;
  }

  int iSwitchToIndex = ClampChoice(m_iChoice[pn]);
  std::set<int> seen;

  do {
    std::map<int, int>::const_iterator iter =
        m_mapCurrentChoiceToNextChoice[dir].find(iSwitchToIndex);
    if (iter != m_mapCurrentChoiceToNextChoice[dir].end()) {
      iSwitchToIndex = iter->second;
    }

    if (iSwitchToIndex < 0 ||
        iSwitchToIndex >= (int)m_aGameCommands.size()) {  // out of choice range
      return false;                                       // can't go that way
    }
    if (seen.find(iSwitchToIndex) != seen.end()) {
      return false;  // went full circle and none found
    }
    seen.insert(iSwitchToIndex);
  } while (!m_aGameCommands.empty() &&
           !m_aGameCommands[iSwitchToIndex].IsPlayable() && !DoSwitchAnyways());

  return ChangeSelection(pn, dir, iSwitchToIndex);
}

bool ScreenSelectMaster::MenuLeft(const InputEventPlus& input) {
  PlayerNumber pn = input.pn;
  if (!IsValidPlayer(pn) || m_fLockInputSecs > 0 || m_bChosen[pn]) {
    return false;
  }
  if (input.type == IET_RELEASE) {
    return false;
  }
  if (input.type != IET_FIRST_PRESS) {
    if (!AllowRepeatingInput()) {
      return false;
    }
    if (m_TrackingRepeatingInput != input.MenuI) {
      return false;
    }
  }
  if (Move(pn, MenuDir_Left)) {
    m_TrackingRepeatingInput = input.MenuI;
    if (m_soundChange.IsLoaded()) {
      m_soundChange.Play(true);
    }
    if (MESSAGEMAN != nullptr) {
      MESSAGEMAN->Broadcast(
          (MessageID)(Message_MenuLeftP1 + Enum::to_integral(pn)));
      MESSAGEMAN->Broadcast((MessageID)(Message_MenuSelectionChanged));
    }

    // if they use double select
    if (DoublePressToSelect()) {
      m_bDoubleChoice[pn] = false;  // player has cancelled their selection
    }
    return true;
  }
  return false;
}

bool ScreenSelectMaster::MenuRight(const InputEventPlus& input) {
  PlayerNumber pn = input.pn;
  if (!IsValidPlayer(pn) || m_fLockInputSecs > 0 || m_bChosen[pn]) {
    return false;
  }
  if (input.type == IET_RELEASE) {
    return false;
  }
  if (input.type != IET_FIRST_PRESS) {
    if (!AllowRepeatingInput()) {
      return false;
    }
    if (m_TrackingRepeatingInput != input.MenuI) {
      return false;
    }
  }
  if (Move(pn, MenuDir_Right)) {
    m_TrackingRepeatingInput = input.MenuI;
    if (m_soundChange.IsLoaded()) {
      m_soundChange.Play(true);
    }
    if (MESSAGEMAN != nullptr) {
      MESSAGEMAN->Broadcast(
          (MessageID)(Message_MenuRightP1 + Enum::to_integral(pn)));
      MESSAGEMAN->Broadcast((MessageID)(Message_MenuSelectionChanged));
    }

    // if they use double select
    if (DoublePressToSelect()) {
      m_bDoubleChoice[pn] = false;  // player has cancelled their selection
    }
    return true;
  }
  return false;
}

bool ScreenSelectMaster::MenuUp(const InputEventPlus& input) {
  PlayerNumber pn = input.pn;
  if (!IsValidPlayer(pn) || m_fLockInputSecs > 0 || m_bChosen[pn]) {
    return false;
  }
  if (input.type == IET_RELEASE) {
    return false;
  }
  if (input.type != IET_FIRST_PRESS) {
    if (!AllowRepeatingInput()) {
      return false;
    }
    if (m_TrackingRepeatingInput != input.MenuI) {
      return false;
    }
  }
  if (Move(pn, MenuDir_Up)) {
    m_TrackingRepeatingInput = input.MenuI;
    if (m_soundChange.IsLoaded()) {
      m_soundChange.Play(true);
    }
    if (MESSAGEMAN != nullptr) {
      MESSAGEMAN->Broadcast(
          (MessageID)(Message_MenuUpP1 + Enum::to_integral(pn)));
      MESSAGEMAN->Broadcast((MessageID)(Message_MenuSelectionChanged));
    }

    // if they use double select
    if (DoublePressToSelect()) {
      m_bDoubleChoice[pn] = false;  // player has cancelled their selection
    }
    return true;
  }
  return false;
}

bool ScreenSelectMaster::MenuDown(const InputEventPlus& input) {
  PlayerNumber pn = input.pn;
  if (!IsValidPlayer(pn) || m_fLockInputSecs > 0 || m_bChosen[pn]) {
    return false;
  }
  if (input.type == IET_RELEASE) {
    return false;
  }
  if (input.type != IET_FIRST_PRESS) {
    if (!AllowRepeatingInput()) {
      return false;
    }
    if (m_TrackingRepeatingInput != input.MenuI) {
      return false;
    }
  }
  if (Move(pn, MenuDir_Down)) {
    m_TrackingRepeatingInput = input.MenuI;
    if (m_soundChange.IsLoaded()) {
      m_soundChange.Play(true);
    }
    if (MESSAGEMAN != nullptr) {
      MESSAGEMAN->Broadcast(
          (MessageID)(Message_MenuDownP1 + Enum::to_integral(pn)));
      MESSAGEMAN->Broadcast((MessageID)(Message_MenuSelectionChanged));
    }

    // if they use double select
    if (DoublePressToSelect()) {
      m_bDoubleChoice[pn] = false;  // player has cancelled their selection
    }
    return true;
  }
  return false;
}

bool ScreenSelectMaster::ChangePage(int iNewChoice) {
  if (!IsValidChoice(iNewChoice)) {
    return false;
  }
  const PlayerNumber master = GetSharedPlayer();
  if (!IsValidPlayer(master)) {
    return false;
  }

  Page oldPage = GetPage(m_iChoice[master]);
  Page newPage = GetPage(iNewChoice);

  // If anyone has already chosen, don't allow changing of pages
  FOREACH_PlayerNumber(p) {
    if (GAMESTATE != nullptr && GAMESTATE->IsHumanPlayer(p) && m_bChosen[p]) {
      return false;
    }
  }

  // change both players
  FOREACH_PlayerNumber(p) m_iChoice[p] = iNewChoice;

  const std::string sIconAndExplanationCommand =
      ssprintf("SwitchToPage%d", newPage + 1);
  if (ShowIcon()) {
    for (unsigned c = 0; c < m_aGameCommands.size(); ++c) {
      if (c < m_vsprIcon.size() && m_vsprIcon[c].IsLoaded()) {
        m_vsprIcon[c]->PlayCommand(sIconAndExplanationCommand);
      }
    }
  }

  FOREACH_ENUM(Page, page) {
    if (m_sprExplanation[page].IsLoaded()) {
      m_sprExplanation[page]->PlayCommand(sIconAndExplanationCommand);
    }
    if (m_sprMore[page].IsLoaded()) {
      m_sprMore[page]->PlayCommand(sIconAndExplanationCommand);
    }
  }

  std::vector<PlayerNumber> vpns;
  GetActiveElementPlayerNumbers(vpns);

  Message msg("PreSwitchPage");
  msg.SetParam("OldPageIndex", (int)oldPage);
  msg.SetParam("NewPageIndex", (int)newPage);
  if (MESSAGEMAN != nullptr) {
    MESSAGEMAN->Broadcast(msg);
  }

  for (const PlayerNumber& p : vpns) {
    if (IsValidPlayer(p) &&
        ((GAMESTATE != nullptr && GAMESTATE->IsHumanPlayer(p)) ||
         IsSharedSelection())) {
      if (ShowCursor() && m_sprCursor[p].IsLoaded()) {
        m_sprCursor[p]->HandleMessage(msg);
        m_sprCursor[p]->SetXY(GetCursorX(p), GetCursorY(p));
      }

      if (ShowScroller() && iNewChoice < static_cast<int>(m_vsprScroll[p].size()) &&
          m_vsprScroll[p][iNewChoice].IsLoaded()) {
        m_vsprScroll[p][m_iChoice[p]]->HandleMessage(msg);
      }
    }
  }

  if (newPage == PAGE_2) {
    // XXX: only play this once (I thought we already did that?)
    // Play it on every change to page 2.  -Chris
    // That sounds ugly if you go back and forth quickly. -g
    // Should we lock input while it's scrolling? -Chris
    m_soundDifficult.Stop();
    m_soundDifficult.PlayRandom();
  }

  m_fLockInputSecs = GetPreSwitchPageSeconds();
  const float tweenTime = this->GetTweenTimeLeft();
  this->PostScreenMessage(
      SM_PlayPostSwitchPage, IsFiniteNonNegative(tweenTime) ? tweenTime : 0.0f);
  return true;
}

bool ScreenSelectMaster::ChangeSelection(
    PlayerNumber pn, MenuDir dir, int iNewChoice) {
  if (!IsValidPlayer(pn) || !IsValidChoice(iNewChoice) ||
      dir < 0 || dir >= NUM_MenuDir) {
    return false;
  }
  m_iChoice[pn] = ClampChoice(m_iChoice[pn]);
  if (iNewChoice == m_iChoice[pn]) {
    return false;  // already there
  }

  Page page = GetPage(iNewChoice);
  if (GetPage(m_iChoice[pn]) != page) {
    return ChangePage(iNewChoice);
  }

  std::vector<PlayerNumber> vpns;
  if (IsSharedSelection() || page != PAGE_1) {
    /* Set the new m_iChoice even for disabled players, since a player might
     * join on a SHARED_SELECTION after the cursor has been moved. */
    FOREACH_ENUM(PlayerNumber, p) {
      if (IsValidPlayer(p)) {
        vpns.push_back(p);
      }
    }
  } else {
    vpns.push_back(pn);
  }

  for (const PlayerNumber& p : vpns) {
    if (!IsValidPlayer(p)) {
      continue;
    }
    const int iOldChoice = ClampChoice(m_iChoice[p]);
    m_iChoice[p] = iNewChoice;

    if (ShowIcon()) {
      /* XXX: If !SharedPreviewAndCursor, this is incorrect. (Nothing uses
       * both icon focus and !SharedPreviewAndCursor right now.)
       * What is SharedPreviewAndCursor? -- Steve */
      bool bOldStillHasFocus = false;
      bool bNewAlreadyHadFocus = false;
      FOREACH_HumanPlayer(p2) {
        if (!IsValidPlayer(p2)) {
          continue;
        }
        if (p2 == p) {
          continue;
        }
        bOldStillHasFocus |= m_iChoice[p2] == iOldChoice;
        bNewAlreadyHadFocus |= m_iChoice[p2] == iNewChoice;
      }

      AutoActor* oldIcon =
          iOldChoice < static_cast<int>(m_vsprIcon.size()) &&
                  m_vsprIcon[iOldChoice].IsLoaded()
              ? &m_vsprIcon[iOldChoice]
              : nullptr;
      AutoActor* newIcon =
          iNewChoice < static_cast<int>(m_vsprIcon.size()) &&
                  m_vsprIcon[iNewChoice].IsLoaded()
              ? &m_vsprIcon[iNewChoice]
              : nullptr;

      if (DoublePressToSelect()) {
        // this player is currently on a single press, which they are cancelling
        if (m_bDoubleChoice[pn]) {
          if (!bOldStillHasFocus && oldIcon != nullptr) {
            (*oldIcon)->PlayCommand("LostSelectedLoseFocus");
          }
          if (!bNewAlreadyHadFocus && newIcon != nullptr) {
            (*newIcon)->PlayCommand("LostSelectedGainFocus");
          }
        } else {
          if (!bOldStillHasFocus && oldIcon != nullptr) {
            (*oldIcon)->PlayCommand("LoseFocus");
          }
          if (!bNewAlreadyHadFocus && newIcon != nullptr) {
            (*newIcon)->PlayCommand("GainFocus");
          }
        }
      } else  // not using double selection
      {
        if (!bOldStillHasFocus && oldIcon != nullptr) {
          (*oldIcon)->PlayCommand("LoseFocus");
        }
        if (!bNewAlreadyHadFocus && newIcon != nullptr) {
          (*newIcon)->PlayCommand("GainFocus");
        }
      }
    }

    if (ShowCursor()) {
      if (GAMESTATE != nullptr && GAMESTATE->IsHumanPlayer(p)) {
        PlayerNumber ep = p;
        if (IsSharedSelection()) {
          ep = PLAYER_1;
        }
        if (IsValidPlayer(ep) && m_sprCursor[ep].IsLoaded()) {
          m_sprCursor[ep]->PlayCommand("Change");
          m_sprCursor[ep]->SetXY(GetCursorX(p), GetCursorY(p));
        }
      }
    }

    if (ShowScroller()) {
      const PlayerNumber scrollerPlayer =
          (IsSharedSelection() || page != PAGE_1) ? PLAYER_1 : p;
      if (!IsValidPlayer(scrollerPlayer)) {
        continue;
      }
      ActorScroller& scroller =
          m_Scroller[scrollerPlayer];
      std::vector<AutoActor>& vScroll =
          m_vsprScroll[scrollerPlayer];
      const bool hasOldScroll =
          iOldChoice < static_cast<int>(vScroll.size()) &&
          vScroll[iOldChoice].IsLoaded();
      const bool hasNewScroll =
          iNewChoice < static_cast<int>(vScroll.size()) &&
          vScroll[iNewChoice].IsLoaded();

      if (WrapScroller()) {
        // HACK: We can't tell from the option orders whether or not we wrapped.
        // For now, assume that the order is increasing left to right.
        int iPressedDir = (dir == MenuDir_Left || dir == MenuDir_Up) ? -1 : +1;
        int iActualDir = (iOldChoice < iNewChoice) ? +1 : -1;

        if (iPressedDir != iActualDir)  // wrapped
        {
          float fItem = scroller.GetCurrentItem();
          int iNumChoices = m_aGameCommands.size();
          fItem += iActualDir * iNumChoices;
          scroller.SetCurrentAndDestinationItem(fItem);
        }
      }

      scroller.SetDestinationItem((float)iNewChoice);

      // using double selections
      if (DoublePressToSelect()) {
        // this player is currently on a single press, which they are cancelling
        if (m_bDoubleChoice[pn]) {
          if (hasOldScroll) {
            vScroll[iOldChoice]->PlayCommand("LostSelectedLoseFocus");
          }
          if (hasNewScroll) {
            vScroll[iNewChoice]->PlayCommand("LostSelectedGainFocus");
          }
        } else  // the player hasn't made any selections yet
        {
          if (hasOldScroll) {
            vScroll[iOldChoice]->PlayCommand("LoseFocus");
          }
          if (hasNewScroll) {
            vScroll[iNewChoice]->PlayCommand("GainFocus");
          }
        }
      } else  // regular lose/gain focus
      {
        if (hasOldScroll) {
          vScroll[iOldChoice]->PlayCommand("LoseFocus");
        }
        if (hasNewScroll) {
          vScroll[iNewChoice]->PlayCommand("GainFocus");
        }
      }
    }
  }

  return true;
}

PlayerNumber ScreenSelectMaster::GetSharedPlayer() {
  if (GAMESTATE != nullptr) {
    const PlayerNumber master = GAMESTATE->GetMasterPlayerNumber();
    if (master >= PLAYER_1 && master < NUM_PLAYERS) {
      return master;
    }
  }

  return PLAYER_1;
}

ScreenSelectMaster::Page ScreenSelectMaster::GetPage(int iChoiceIndex) const {
  if (!IsValidChoice(iChoiceIndex)) {
    return PAGE_1;
  }
  return iChoiceIndex < GetNumChoicesOnPage1() ? PAGE_1 : PAGE_2;
}

ScreenSelectMaster::Page ScreenSelectMaster::GetCurrentPage() const {
  // Both players are guaranteed to be on the same page.
  const PlayerNumber sharedPlayer = GetSharedPlayer();
  if (!IsValidPlayer(sharedPlayer)) {
    return PAGE_1;
  }
  return GetPage(m_iChoice[sharedPlayer]);
}

float ScreenSelectMaster::DoMenuStart(PlayerNumber pn) {
  if (!IsValidPlayer(pn)) {
    return 0;
  }
  if (m_bChosen[pn]) {
    return 0;
  }

  bool bAnyChosen = false;
  FOREACH_PlayerNumber(p) bAnyChosen |= m_bChosen[p];

  m_bChosen[pn] = true;

  this->PlayCommand("MadeChoice" + PlayerNumberToString(pn));

  bool bIsFirstToChoose = !bAnyChosen;

  float fSecs = 0;

  if (bIsFirstToChoose) {
    FOREACH_ENUM(Page, page) {
      if (m_sprMore[page].IsLoaded()) {
        m_sprMore[page]->PlayCommand("Off");
        fSecs = std::max(fSecs, m_sprMore[page]->GetTweenTimeLeft());
      }
    }
  }
  if (ShowCursor()) {
    if (m_sprCursor[pn].IsLoaded()) {
      m_sprCursor[pn]->PlayCommand("Choose");
      fSecs = std::max(fSecs, m_sprCursor[pn]->GetTweenTimeLeft());
    }
  }

  return fSecs;
}

bool ScreenSelectMaster::MenuStart(const InputEventPlus& input) {
  if (input.type != IET_FIRST_PRESS) {
    return false;
  }
  PlayerNumber pn = input.pn;

  if (!IsValidPlayer(pn) || m_fLockInputSecs > 0) {
    return false;
  }
  if (IsSharedSelection() || GetCurrentPage() == PAGE_2) {
    // Return if any player has chosen
    FOREACH_EnabledPlayer(p) {
      if (IsValidPlayer(p) && m_bChosen[p]) {
        return false;
      }
    }
  } else if (m_bChosen[pn]) {
    // Return if this player has already chosen
    return false;
  }

  if (!ProcessMenuStart(pn)) {
    return false;
  }

  // double press is enabled and the player hasn't made their first press
  if (DoublePressToSelect() && !m_bDoubleChoice[pn]) {
    if (m_soundStart.IsLoaded()) {
      m_soundStart.PlayCopy(true);
    }
    m_bDoubleChoice[pn] = true;

    if (ShowScroller()) {
      const PlayerNumber scrollerPlayer = IsSharedSelection() ? PLAYER_1 : pn;
      std::vector<AutoActor>& vScroll =
          m_vsprScroll[scrollerPlayer];
      const int iChoice = ClampChoice(m_iChoice[pn]);
      if (iChoice < static_cast<int>(vScroll.size()) &&
          vScroll[iChoice].IsLoaded()) {
        vScroll[iChoice]->PlayCommand("InitialSelection");
      }
    }

    return true;
  }

  /* If no options are playable, then we're just waiting for one to become
   * available. If any options are playable, then the selection must be
   * playable. */
  if (!AnyOptionsArePlayable()) {
    return false;
  }
  const int iChoice = ClampChoice(m_iChoice[pn]);
  if (!IsValidChoice(iChoice) || !m_aGameCommands[iChoice].IsPlayable()) {
    return false;
  }
  GameCommand* mc = &(m_aGameCommands[iChoice]);

  if (SOUND != nullptr && ANNOUNCER != nullptr && !mc->m_sName.empty()) {
    SOUND->PlayOnceFromDir(ANNOUNCER->GetPathTo(
        ssprintf("%s comment %s", m_sName.c_str(), mc->m_sName.c_str())));
  }

  // Play a copy of the sound, so it'll finish playing even if we leave the
  // screen immediately.
  if (mc->m_sSoundPath.empty() && !m_bDoubleChoiceNoSound &&
      m_soundStart.IsLoaded()) {
    m_soundStart.PlayCopy(true);
  }

  if (mc->m_sScreen.empty()) {
    mc->ApplyToAllPlayers();
    // We want to be able to broadcast a Start message to the theme, in
    // case a themer wants to handle something. -aj
    Message msg(MessageIDToString(
        (MessageID)(Message_MenuStartP1 + Enum::to_integral(pn))));
    msg.SetParam("ScreenEmpty", true);
    if (MESSAGEMAN != nullptr) {
      MESSAGEMAN->Broadcast(msg);
    }
    return true;
  }

  float fSecs = 0;
  bool bAllDone = true;
  if (IsSharedSelection() || GetCurrentPage() == PAGE_2) {
    // Only one player has to pick. Choose this for all the other players, too.
    FOREACH_EnabledPlayer(p) {
      if (IsValidPlayer(p) && !m_bChosen[p]) {
        fSecs = std::max(fSecs, DoMenuStart(p));
      }
    }
  } else {
    fSecs = std::max(fSecs, DoMenuStart(pn));
    // check to see if everyone has chosen
    FOREACH_HumanPlayer(p) {
      if (IsValidPlayer(p)) {
        bAllDone &= m_bChosen[p];
      }
    }
  }

  if (bAllDone) {
    // broadcast MenuStart just like MenuLeft/Right/etc.
    if (MESSAGEMAN != nullptr) {
      MESSAGEMAN->Broadcast(
          (MessageID)(Message_MenuStartP1 + Enum::to_integral(pn)));
    }
    this->PostScreenMessage(
        SM_BeginFadingOut,
        IsFiniteNonNegative(fSecs) ? fSecs
                                   : 0.0f);  // tell our owner it's time to move on
  }
  return true;
}

/* We want all items to always run OnCommand and either GainFocus or LoseFocus
 * on tween-in. If we only run OnCommand, then it has to contain a copy of
 * either GainFocus or LoseFocus, which implies that the default setting is
 * hard-coded in the theme. Always run both.
 * However, the actual tween-in is OnCommand; we don't always want to actually
 * run through the Gain/LoseFocus tweens during initial tween-in. So, we run
 * the focus command first, do a FinishTweening to pop it in place, and then
 * run OnCommand. This means that the focus command should be position neutral;
 * eg. only use "addx", not "x". */
void ScreenSelectMaster::TweenOnScreen() {
  std::vector<PlayerNumber> vpns;
  GetActiveElementPlayerNumbers(vpns);

  if (ShowIcon()) {
    const PlayerNumber sharedPlayer = GetSharedPlayer();
    const int activeChoice =
        IsValidPlayer(sharedPlayer) ? ClampChoice(m_iChoice[sharedPlayer]) : 0;
    for (unsigned c = 0; c < m_aGameCommands.size(); c++) {
      if (c < m_vsprIcon.size() && m_vsprIcon[c].IsLoaded()) {
        m_vsprIcon[c]->PlayCommand(
            (int(c) == activeChoice) ? "GainFocus" : "LoseFocus");
        m_vsprIcon[c]->FinishTweening();
      }
    }
  }

  if (ShowScroller()) {
    for (const PlayerNumber& p : vpns) {
      if (!IsValidPlayer(p)) {
        continue;
      }
      const int iChoice = ClampChoice(m_iChoice[p]);
      // Play Gain/LoseFocus before playing the on command.
      // Gain/Lose will often stop tweening, which ruins the OnCommand.
      for (unsigned c = 0; c < m_aGameCommands.size(); c++) {
        if (c < m_vsprScroll[p].size() && m_vsprScroll[p][c].IsLoaded()) {
          m_vsprScroll[p][c]->PlayCommand(
              int(c) == iChoice ? "GainFocus" : "LoseFocus");
          m_vsprScroll[p][c]->FinishTweening();
        }
      }

      m_Scroller[p].SetCurrentAndDestinationItem((float)iChoice);
    }
  }

  // Need to SetXY of Cursor after Icons since it depends on the Icons'
  // positions.
  if (ShowCursor()) {
    for (const PlayerNumber& p : vpns) {
      if (IsValidPlayer(p) && m_sprCursor[p].IsLoaded() &&
          ((GAMESTATE != nullptr && GAMESTATE->IsHumanPlayer(p)) ||
           IsSharedSelection())) {
        m_sprCursor[p]->SetXY(GetCursorX(p), GetCursorY(p));
      }
    }
  }

  ScreenSelect::TweenOnScreen();
}

void ScreenSelectMaster::TweenOffScreen() {
  ScreenSelect::TweenOffScreen();

  std::vector<PlayerNumber> vpns;
  GetActiveElementPlayerNumbers(vpns);

  for (unsigned c = 0; c < m_aGameCommands.size(); c++) {
    if (GetPage(c) != GetCurrentPage()) {
      continue;  // skip
    }

    bool bSelectedByEitherPlayer =
        std::any_of(vpns.begin(), vpns.end(), [&](const PlayerNumber& p) {
          return IsValidPlayer(p) && ClampChoice(m_iChoice[p]) == static_cast<int>(c);
        });

    if (ShowIcon() && c < m_vsprIcon.size() && m_vsprIcon[c].IsLoaded()) {
      m_vsprIcon[c]->PlayCommand(
          bSelectedByEitherPlayer ? "OffFocused" : "OffUnfocused");
    }

    if (ShowScroller()) {
      for (const PlayerNumber& p : vpns) {
        if (IsValidPlayer(p) && c < m_vsprScroll[p].size() &&
            m_vsprScroll[p][c].IsLoaded()) {
          m_vsprScroll[p][c]->PlayCommand(
              bSelectedByEitherPlayer ? "OffFocused" : "OffUnfocused");
        }
      }
    }
  }
}

// Use DestX and DestY so that the cursor can move to where the icon will be
// rather than where it is.
float ScreenSelectMaster::GetCursorX(PlayerNumber pn) {
  if (!IsValidPlayer(pn)) {
    return 0.0f;
  }
  const float offset = CURSOR_OFFSET_X_FROM_ICON.GetValue(pn);
  const int iChoice = ClampChoice(m_iChoice[pn]);
  if (iChoice >= static_cast<int>(m_vsprIcon.size()) ||
      !m_vsprIcon[iChoice].IsLoaded()) {
    return offset;
  }
  AutoActor& spr = m_vsprIcon[iChoice];
  return spr->GetDestX() + offset;
}

float ScreenSelectMaster::GetCursorY(PlayerNumber pn) {
  if (!IsValidPlayer(pn)) {
    return 0.0f;
  }
  const float offset = CURSOR_OFFSET_Y_FROM_ICON.GetValue(pn);
  const int iChoice = ClampChoice(m_iChoice[pn]);
  if (iChoice >= static_cast<int>(m_vsprIcon.size()) ||
      !m_vsprIcon[iChoice].IsLoaded()) {
    return offset;
  }
  AutoActor& spr = m_vsprIcon[iChoice];
  return spr->GetDestY() + offset;
}

// lua start
#include "LuaBinding.h"

/** @brief Allow Lua to have access to the ScreenSelectMaster. */
class LunaScreenSelectMaster : public Luna<ScreenSelectMaster> {
 public:
  static int GetSelectionIndex(T* p, lua_State* L) {
    lua_pushnumber(
        L, p->GetPlayerSelectionIndex(Enum::Check<PlayerNumber>(L, 1)));
    return 1;
  }
  // should I even bother adding this? -aj
  // would have to make a public function to get this in ssmaster.h:
  // m_aGameCommands[i].m_sName
  // static int SelectionIndexToChoiceName( T* p, lua_State *L ){  return 1; }

  LunaScreenSelectMaster() { ADD_METHOD(GetSelectionIndex); }
};

LUA_REGISTER_DERIVED_CLASS(ScreenSelectMaster, ScreenWithMenuElements)
// lua end

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
