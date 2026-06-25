#include "ScreenOptions.h"

#include <algorithm>
#include <cmath>
#include <string>
#include <vector>

#include "Actor.h"
#include "ActorUtil.h"
#include "BitmapText.h"
#include "EnumHelper.h"
#include "GameCommand.h"
#include "GameInput.h"
#include "GameState.h"
#include "InputEventPlus.h"
#include "InputFilter.h"
#include "InputMapper.h"
#include "LuaBinding.h"
#include "LuaManager.h"
#include "MessageManager.h"
#include "OptionRowHandler.h"
#include "OptionsCursor.h"
#include "PerfDiagnostics.h"
#include "PlayerNumber.h"
#include "PrefsManager.h"
#include "RageInputDevice.h"
#include "RageLog.h"
#include "RageThreads.h"
#include "RageUtil.h"
#include "ScreenManager.h"
#include "ScreenMessage.h"
#include "ScreenWithMenuElements.h"
#include "ThemeManager.h"
#include "global.h"

/*
 * These navigation types are provided:
 *
 * All modes:
 *  left, right -> change option
 *  up, down -> change row
 *   (in toggle modes, focus on nearest item to old focus)
 *
 * NAV_THREE_KEY:
 *  start -> move to next row
 *  left+right+start -> move to prev row
 *  (next screen via "exit" entry)
 * This is the minimal navigation, for using menus with only three buttons.
 *
 * NAV_THREE_KEY_ALT:
 *  left, right -> next, prev row
 *  start -> change option
 *
 * NAV_FIVE_KEY:
 *  start -> next screen
 * This is a much more convenient navigation, requiring five keys.
 *
 * NAV_TOGGLE_THREE_KEY:
 *  start -> on first choice, move to next row; otherewise toggle option and
 * move to first choice left+right+start -> move to prev row
 *
 * NAV_TOGGLE_FIVE_KEY:
 *  start -> toggle option
 *
 * Regular modes and toggle modes must be enabled by the theme.  We could simply
 * automatically switch to toggle mode for multiselect rows, but that would be
 * strange for non-multiselect rows (eg. scroll speed).
 *
 * THREE_KEY modes are navigatable with only MenuLeft, MenuRight and MenuStart,
 * and are used when PREFSMAN->m_iArcadeOptionsNavigation is enabled.  However,
 * they can still use MenuUp and MenuDown for nonessential behavior.
 *
 * NAV_THREE_KEY_MENU:
 *  left, right -> change row
 *  up, down -> change row
 *  start -> next screen
 * This is a specialized navigation for ScreenOptionsService.  It must be
 * enabled to allow screens that use rows to select other screens to work with
 * only three buttons.  (It's also used when in five-key mode.)
 *
 * We don't want to simply allow left/right to move up and down on single-entry
 * rows when in NAV_THREE_KEY, becasue left and right shouldn't exit the "exit"
 * row in player options menus, but it should in the options menu.
 */

static bool IsValidOptionsPlayer(PlayerNumber pn) {
  return pn >= PLAYER_1 && pn < NUM_PLAYERS;
}

static void ScreenOptionsLogTrace(const std::string& message) {
  if (LOG == nullptr) {
    return;
  }
  LOG->Trace("%s", message.c_str());
}

static void ScreenOptionsLogWarn(const std::string& message) {
  if (LOG == nullptr) {
    return;
  }
  LOG->Warn("%s", message.c_str());
}

static bool HasTheme() {
  return THEME != nullptr && THEME->IsThemeLoaded();
}

static bool IsHumanOptionsPlayer(PlayerNumber pn) {
  return IsValidOptionsPlayer(pn) && GAMESTATE != nullptr &&
         GAMESTATE->IsHumanPlayer(pn);
}

static bool IsUsableScreenTarget(const std::string& screenName) {
  if (screenName.empty()) {
    return false;
  }
  if (SCREENMAN != nullptr && HasTheme()) {
    return SCREENMAN->IsScreenNameValid(screenName);
  }
  return true;
}

static bool IsRowIndexValid(const std::vector<OptionRow*>& rows, int row) {
  return row >= 0 && row < static_cast<int>(rows.size()) && rows[row] != nullptr;
}

static int ClampRowsShown(int rowsShown) {
  return std::max(rowsShown, 1);
}

static void BroadcastIfAvailable(Message& msg) {
  if (MESSAGEMAN != nullptr) {
    MESSAGEMAN->Broadcast(msg);
  }
}

static void BroadcastIfAvailable(MessageID message) {
  if (MESSAGEMAN != nullptr) {
    MESSAGEMAN->Broadcast(message);
  }
}

static bool LuaReadOptionsPlayer(
    lua_State* L, int index, PlayerNumber& playerOut) {
  if (L == nullptr || !lua_isnumber(L, index)) {
    playerOut = PLAYER_INVALID;
    return false;
  }
  playerOut = static_cast<PlayerNumber>(lua_tointeger(L, index));
  return IsValidOptionsPlayer(playerOut);
}

static bool LuaReadInt(lua_State* L, int index, int& valueOut) {
  if (L == nullptr || !lua_isnumber(L, index)) {
    valueOut = -1;
    return false;
  }
  valueOut = static_cast<int>(lua_tointeger(L, index));
  return true;
}

static std::string OPTION_EXPLANATION(std::string s) {
  if (!HasTheme()) {
    return std::string();
  }
  return THEME->GetString("OptionExplanations", s);
}

static bool IsOnlinePlayerOptionsScreen(const std::string& screenName) {
  return screenName == "ScreenPlayerOptions" ||
         screenName == "ScreenPlayerOptions2" ||
         screenName == "ScreenPlayerOptions3";
}

static bool OnlinePlayerOptionsRequireReadyOnly(const std::string& screenName) {
  if (!IsOnlinePlayerOptionsScreen(screenName) || LUA == nullptr) {
    return false;
  }

  Lua* L = LUA->Get();
  if (L == nullptr) {
    return false;
  }
  const int top = lua_gettop(L);
  const bool ran = LuaHelpers::RunExpression(
      L,
      "ITGOnline ~= nil "
      "and ITGOnline.currentRoomId ~= nil "
      "and ITGOnline.currentRoom ~= nil "
      "and ITGOnline.currentRoom.id == ITGOnline.currentRoomId "
      "and ITGOnline.currentRoom.selected_song ~= nil "
      "and ITGOnline.NormalizeRoomPhase ~= nil "
      "and ITGOnline:NormalizeRoomPhase(ITGOnline.currentRoom.phase) == "
      "'config'",
      "ScreenOptions::OnlinePlayerOptionsRequireReadyOnly");
  const bool locked = ran && lua_gettop(L) > top && lua_toboolean(L, -1);
  lua_settop(L, top);
  LUA->Release(L);

  return locked;
}

static const char* InputModeNames[] = {"Individual", "Together"};
StringToX(InputMode);

// REGISTER_SCREEN_CLASS( ScreenOptions );	// can't be instantiated
ScreenOptions::ScreenOptions()
    : m_OptionsNavigation(NAV_FIVE_KEY),
      m_InputMode(INPUTMODE_SHARE_CURSOR) {
  FOREACH_PlayerNumber(p) {
    m_iCurrentRow[p] = -1;
    m_iFocusX[p] = -1;
    m_bWasOnExit[p] = false;
    m_bGotAtLeastOneStartPressed[p] = false;
  }

  // These can be overridden in a derived Init().
  const int arcadeNavigation =
      PREFSMAN != nullptr ? PREFSMAN->m_iArcadeOptionsNavigation.Get() : 0;
  switch (arcadeNavigation) {
    case 0:
      SetNavigation(NAV_FIVE_KEY);
      break;
    case 1:
      SetNavigation(NAV_THREE_KEY);
      break;
    case 2:
      SetNavigation(NAV_THREE_KEY_ALT);
      break;
    default:
      ScreenOptionsLogWarn(
          ssprintf(
              "ScreenOptions: invalid ArcadeOptionsNavigation=%d, using five-key",
              arcadeNavigation));
      SetNavigation(NAV_FIVE_KEY);
      break;
  }
}

void ScreenOptions::Init() {
  NUM_ROWS_SHOWN.Load(m_sName, "NumRowsShown");
  ROW_INIT_COMMAND.Load(m_sName, "RowInitCommand");
  ROW_ON_COMMAND.Load(m_sName, "RowOnCommand");
  ROW_OFF_COMMAND.Load(m_sName, "RowOffCommand");
  SHOW_SCROLL_BAR.Load(m_sName, "ShowScrollBar");
  SCROLL_BAR_HEIGHT.Load(m_sName, "ScrollBarHeight");
  SCROLL_BAR_TIME.Load(m_sName, "ScrollBarTime");
  LINE_HIGHLIGHT_X.Load(m_sName, "LineHighlightX");
  SHOW_EXIT_ROW.Load(m_sName, "ShowExitRow");
  SEPARATE_EXIT_ROW.Load(m_sName, "SeparateExitRow");
  SEPARATE_EXIT_ROW_Y.Load(m_sName, "SeparateExitRowY");
  SHOW_EXPLANATIONS.Load(m_sName, "ShowExplanations");
  ALLOW_REPEATING_CHANGE_VALUE_INPUT.Load(
      m_sName, "AllowRepeatingChangeValueInput");
  CURSOR_TWEEN_SECONDS.Load(m_sName, "CursorTweenSeconds");
  WRAP_VALUE_IN_ROW.Load(m_sName, "WrapValueInRow");
  OPTION_ROW_NORMAL_METRICS_GROUP.Load(m_sName, "OptionRowNormalMetricsGroup");
  OPTION_ROW_EXIT_METRICS_GROUP.Load(m_sName, "OptionRowExitMetricsGroup");

  m_exprRowPositionTransformFunction.ClearCache();
  if (HasTheme()) {
    m_exprRowPositionTransformFunction.SetFromReference(
        THEME->GetMetricR(m_sName, "RowPositionTransformFunction"));
  } else {
    ScreenOptionsLogWarn(
        ssprintf("ScreenOptions::Init(%s): theme unavailable", m_sName.c_str()));
  }

  ScreenWithMenuElements::Init();

  if (HasTheme()) {
    m_SoundChangeCol.Load(THEME->GetPathS(m_sName, "change"), true);
    m_SoundNextRow.Load(THEME->GetPathS(m_sName, "next"), true);
    m_SoundPrevRow.Load(THEME->GetPathS(m_sName, "prev"), true);
    m_SoundToggleOn.Load(THEME->GetPathS(m_sName, "toggle on"), true);
    m_SoundToggleOff.Load(THEME->GetPathS(m_sName, "toggle off"), true);
    m_SoundStart.Load(THEME->GetPathS(m_sName, "start"), true);
  }

  // add everything to m_frameContainer so we can animate everything at once
  m_frameContainer.SetName("Container");
  LOAD_ALL_COMMANDS(m_frameContainer);
  this->AddChild(&m_frameContainer);

  m_sprPage.Load(HasTheme() ? THEME->GetPathG(m_sName, "page") : "");
  m_sprPage->SetName("Page");
  LOAD_ALL_COMMANDS_AND_SET_XY(m_sprPage);
  m_frameContainer.AddChild(m_sprPage);

  // init line highlights
  FOREACH_PlayerNumber(p) {
    m_sprLineHighlight[p].Load(
        HasTheme() ? THEME->GetPathG(m_sName, ssprintf("LineHighlight P%d", p + 1))
                   : "");
    m_sprLineHighlight[p]->SetName(ssprintf("LineHighlightP%d", p + 1));
    m_sprLineHighlight[p]->SetX(LINE_HIGHLIGHT_X);
    LOAD_ALL_COMMANDS(m_sprLineHighlight[p]);
    m_frameContainer.AddChild(m_sprLineHighlight[p]);
  }

  // init cursors
  FOREACH_PlayerNumber(p) {
    m_Cursor[p].Load("OptionsCursor" + PlayerNumberToString(p), true);
    m_Cursor[p].SetName("Cursor");
    LOAD_ALL_COMMANDS(m_Cursor[p]);
    m_frameContainer.AddChild(&m_Cursor[p]);
  }

  switch (m_InputMode) {
    case INPUTMODE_INDIVIDUAL:
      FOREACH_PlayerNumber(p) {
        m_textExplanation[p].LoadFromFont(
            HasTheme() ? THEME->GetPathF(m_sName, "explanation") : "");
        m_textExplanation[p].SetDrawOrder(2);
        m_textExplanation[p].SetName("Explanation" + PlayerNumberToString(p));
        LOAD_ALL_COMMANDS_AND_SET_XY(m_textExplanation[p]);
        m_frameContainer.AddChild(&m_textExplanation[p]);
      }
      break;
    case INPUTMODE_SHARE_CURSOR:
      m_textExplanationTogether.LoadFromFont(
          HasTheme() ? THEME->GetPathF(m_sName, "explanation") : "");
      m_textExplanationTogether.SetDrawOrder(2);
      m_textExplanationTogether.SetName("ExplanationTogether");
      LOAD_ALL_COMMANDS_AND_SET_XY(m_textExplanationTogether);
      m_frameContainer.AddChild(&m_textExplanationTogether);
      break;
    default:
      ScreenOptionsLogWarn(
          ssprintf("ScreenOptions::Init(%s): invalid InputMode=%d, using shared",
                   m_sName.c_str(), m_InputMode));
      m_InputMode = INPUTMODE_SHARE_CURSOR;
      m_textExplanationTogether.LoadFromFont(
          HasTheme() ? THEME->GetPathF(m_sName, "explanation") : "");
      m_textExplanationTogether.SetDrawOrder(2);
      m_textExplanationTogether.SetName("ExplanationTogether");
      LOAD_ALL_COMMANDS_AND_SET_XY(m_textExplanationTogether);
      m_frameContainer.AddChild(&m_textExplanationTogether);
      break;
  }

  if (SHOW_SCROLL_BAR) {
    m_ScrollBar.SetName("ScrollBar");
    m_ScrollBar.SetBarHeight(SCROLL_BAR_HEIGHT);
    m_ScrollBar.SetBarTime(SCROLL_BAR_TIME);
    m_ScrollBar.Load("DualScrollBar");
    FOREACH_PlayerNumber(p) m_ScrollBar.EnablePlayer(p, IsHumanOptionsPlayer(p));
    LOAD_ALL_COMMANDS_AND_SET_XY(m_ScrollBar);
    m_ScrollBar.SetDrawOrder(2);
    m_frameContainer.AddChild(&m_ScrollBar);
  }

  m_sprMore.Load(HasTheme() ? THEME->GetPathG(m_sName, "more") : "");
  m_sprMore->SetName("More");
  LOAD_ALL_COMMANDS_AND_SET_XY(m_sprMore);
  m_sprMore->SetDrawOrder(2);
  m_sprMore->PlayCommand("LoseFocus");
  m_frameContainer.AddChild(m_sprMore);

  m_OptionRowTypeNormal.Load(OPTION_ROW_NORMAL_METRICS_GROUP, this);
  m_OptionRowTypeExit.Load(OPTION_ROW_EXIT_METRICS_GROUP, this);
}

void ScreenOptions::InitMenu(const std::vector<OptionRowHandler*>& vHands) {
  ScreenOptionsLogTrace("ScreenOptions::InitMenu()");

  for (unsigned i = 0; i < m_pRows.size(); i++) {
    m_frameContainer.RemoveChild(m_pRows[i]);
    RageUtil::SafeDelete(m_pRows[i]);
  }
  m_pRows.clear();

  for (unsigned r = 0; r < vHands.size(); r++)  // foreach row
  {
    if (vHands[r] == nullptr) {
      ScreenOptionsLogWarn(
          ssprintf("ScreenOptions::InitMenu(%s): skipped null row handler %u",
                   m_sName.c_str(), r));
      continue;
    }
    m_pRows.push_back(new OptionRow(&m_OptionRowTypeNormal));
    OptionRow& row = *m_pRows.back();
    row.SetDrawOrder(1);
    m_frameContainer.AddChild(&row);

    bool bFirstRowGoesDown = m_OptionsNavigation == NAV_TOGGLE_THREE_KEY;

    row.LoadNormal(vHands[r], bFirstRowGoesDown);
  }

  if (SHOW_EXIT_ROW) {
    m_pRows.push_back(new OptionRow(&m_OptionRowTypeExit));
    OptionRow& row = *m_pRows.back();
    row.LoadExit();
    row.SetDrawOrder(1);
    m_frameContainer.AddChild(&row);
  }

  m_frameContainer.SortByDrawOrder();

  int iIndex = 0;
  for (OptionRow* p : m_pRows) {
    if (p == nullptr) {
      continue;
    }
    if (LUA != nullptr && !p->m_pLuaInstance.isNull()) {
      Lua* L = LUA->Get();
      if (L != nullptr) {
        LuaHelpers::Push(L, iIndex);
        p->m_pLuaInstance->Set(L, "iIndex");
        LUA->Release(L);
      }
    }
    iIndex++;

    p->RunCommands(ROW_INIT_COMMAND);
  }

  // poke once at all the explanation metrics so that we catch missing ones
  // early
  for (int r = 0; r < (int)m_pRows.size(); r++)  // foreach row
  {
    GetExplanationText(r);
  }
}

/* Call when option rows have been re-initialized. */
void ScreenOptions::RestartOptions() {
  m_exprRowPositionTransformFunction.ClearCache();
  std::vector<PlayerNumber> vpns;
  FOREACH_HumanPlayer(p) vpns.push_back(p);

  for (unsigned r = 0; r < m_pRows.size(); r++)  // foreach row
  {
    OptionRow* pRow = m_pRows[r];
    if (pRow == nullptr) {
      ScreenOptionsLogWarn(
          ssprintf("ScreenOptions::RestartOptions(%s): null row %u",
                   m_sName.c_str(), r));
      continue;
    }
    pRow->Reload();

    this->ImportOptions(r, vpns);

    // HACK: Process disabled players, too, to hide inactive underlines.
    FOREACH_PlayerNumber(p) pRow->AfterImportOptions(p);
  }

  FOREACH_PlayerNumber(p) {
    m_iCurrentRow[p] = -1;
    m_iFocusX[p] = -1;
    m_bWasOnExit[p] = false;

    // put focus on the first enabled row
    for (unsigned r = 0; r < m_pRows.size(); r++) {
      if (m_pRows[r] == nullptr) {
        continue;
      }
      const OptionRow& row = *m_pRows[r];
      if (row.GetRowDef().IsEnabledForPlayer(p)) {
        m_iCurrentRow[p] = r;
        break;
      }
    }

    // Hide the highlight if no rows are enabled.
    if (m_sprLineHighlight[p].IsLoaded()) {
      m_sprLineHighlight[p]->SetVisible(
          m_iCurrentRow[p] != -1 && IsHumanOptionsPlayer(p));
    }
  }

  CHECKPOINT_M("About to get the rows positioned right.");

  PositionRows(false);
  FOREACH_HumanPlayer(pn) {
    for (unsigned r = 0; r < m_pRows.size(); ++r) {
      this->RefreshIcons(r, pn);
    }
    PositionCursor(pn);
  }

  FOREACH_PlayerNumber(p) { AfterChangeRow(p); }
  CHECKPOINT_M("Rows positioned.");
}

void ScreenOptions::BeginScreen() {
  ScreenWithMenuElements::BeginScreen();

  RestartOptions();

  FOREACH_PlayerNumber(p) m_bGotAtLeastOneStartPressed[p] = false;

  ON_COMMAND(m_frameContainer);

  FOREACH_PlayerNumber(p) {
    m_Cursor[p].SetVisible(IsHumanOptionsPlayer(p));
    ON_COMMAND(m_Cursor[p]);
  }

  this->SortByDrawOrder();
}

void ScreenOptions::TweenOnScreen() {
  ScreenWithMenuElements::TweenOnScreen();

  for (OptionRow* p : m_pRows) {
    if (p != nullptr) {
      p->RunCommands(ROW_ON_COMMAND);
    }
  }

  m_frameContainer.SortByDrawOrder();
}

void ScreenOptions::TweenOffScreen() {
  ScreenWithMenuElements::TweenOffScreen();

  for (OptionRow* p : m_pRows) {
    if (p != nullptr) {
      p->RunCommands(ROW_OFF_COMMAND);
    }
  }
}

ScreenOptions::~ScreenOptions() {
  ScreenOptionsLogTrace("ScreenOptions::~ScreenOptions()");
  for (unsigned i = 0; i < m_pRows.size(); i++) {
    RageUtil::SafeDelete(m_pRows[i]);
  }
}

std::string ScreenOptions::GetExplanationText(int iRow) const {
  if (!IsRowIndexValid(m_pRows, iRow)) {
    return std::string();
  }
  const OptionRow& row = *m_pRows[iRow];

  bool bAllowExplanation = row.GetRowDef().m_bAllowExplanation;
  bool bShowExplanations = bAllowExplanation && SHOW_EXPLANATIONS.GetValue();
  if (!bShowExplanations) {
    return std::string();
  }

  std::string sExplanationName = row.GetRowDef().m_sExplanationName;
  if (sExplanationName.empty()) {
    sExplanationName = row.GetRowDef().m_sName;
  }
  if (sExplanationName.empty()) {
    return std::string();
  }

  return OPTION_EXPLANATION(sExplanationName);
}

void ScreenOptions::GetWidthXY(
    PlayerNumber pn, int iRow, int iChoiceOnRow, int& iWidthOut, int& iXOut,
    int& iYOut) const {
  iWidthOut = 0;
  iXOut = 0;
  iYOut = 0;
  if (!IsValidOptionsPlayer(pn) || !IsRowIndexValid(m_pRows, iRow) ||
      iChoiceOnRow < 0) {
    return;
  }
  const OptionRow& row = *m_pRows[iRow];
  row.GetWidthXY(pn, iChoiceOnRow, iWidthOut, iXOut, iYOut);
}

void ScreenOptions::RefreshIcons(int iRow, PlayerNumber pn) {
  if (!IsValidOptionsPlayer(pn) || !IsRowIndexValid(m_pRows, iRow)) {
    return;
  }
  OptionRow& row = *m_pRows[iRow];

  const OptionRowDefinition& def = row.GetRowDef();

  // find first selection and whether multiple are selected
  int iFirstSelection = row.GetOneSelection(pn, true);

  // set icon name and bullet
  std::string sIcon;
  GameCommand gc;

  if (iFirstSelection == -1) {
    sIcon = "Multi";
  } else if (iFirstSelection != -1) {
    const OptionRowHandler* pHand = row.GetHandler();
    if (pHand) {
      int iSelection = iFirstSelection +
                       (m_OptionsNavigation == NAV_TOGGLE_THREE_KEY ? -1 : 0);
      if (iSelection >= 0 &&
          iSelection < static_cast<int>(def.m_vsChoices.size())) {
        pHand->GetIconTextAndGameCommand(iSelection, sIcon, gc);
      }
    }
  }

  // XXX: hack to not display text in the song options menu
  if (def.m_bOneChoiceForAllPlayers) {
    sIcon = "";
  }

  m_pRows[iRow]->SetModIcon(pn, sIcon, gc);
}

void ScreenOptions::PositionCursor(PlayerNumber pn) {
  if (!IsValidOptionsPlayer(pn)) {
    return;
  }
  // Set the position of the cursor showing the current option the user is
  // changing.
  const int iRow = m_iCurrentRow[pn];
  if (iRow == -1) {
    return;
  }

  if (!IsRowIndexValid(m_pRows, iRow)) {
    return;
  }
  const OptionRow& row = *m_pRows[iRow];

  const int iChoiceWithFocus = row.GetChoiceInRowWithFocus(pn);
  if (iChoiceWithFocus == -1) {
    return;
  }

  int iWidth, iX, iY;
  GetWidthXY(pn, iRow, iChoiceWithFocus, iWidth, iX, iY);

  OptionsCursor& cursor = m_Cursor[pn];
  cursor.SetBarWidth(iWidth);
  cursor.SetXY((float)iX, (float)iY);
  bool bCanGoLeft = iChoiceWithFocus > 0;
  bool bCanGoRight =
      iChoiceWithFocus >= 0 &&
      iChoiceWithFocus < (int)row.GetRowDef().m_vsChoices.size() - 1;
  cursor.SetCanGo(bCanGoLeft, bCanGoRight);
}

void ScreenOptions::TweenCursor(PlayerNumber pn) {
  if (!IsValidOptionsPlayer(pn)) {
    return;
  }
  // Set the position of the cursor showing the current option the user is
  // changing.
  const int iRow = m_iCurrentRow[pn];
  if (!IsRowIndexValid(m_pRows, iRow)) {
    return;
  }

  const OptionRow& row = *m_pRows[iRow];
  const int iChoiceWithFocus = row.GetChoiceInRowWithFocus(pn);
  if (iChoiceWithFocus < 0) {
    return;
  }

  int iWidth, iX, iY;
  GetWidthXY(pn, iRow, iChoiceWithFocus, iWidth, iX, iY);

  OptionsCursor& cursor = m_Cursor[pn];
  if (cursor.GetDestX() != (float)iX || cursor.GetDestY() != (float)iY ||
      cursor.GetBarWidth() != iWidth) {
    cursor.StopTweening();
    cursor.BeginTweening(CURSOR_TWEEN_SECONDS);
    cursor.SetXY((float)iX, (float)iY);
    cursor.SetBarWidth(iWidth);
  }

  bool bCanGoLeft = false;
  bool bCanGoRight = false;
  switch (row.GetRowDef().m_layoutType) {
    case LAYOUT_SHOW_ONE_IN_ROW:
      bCanGoLeft = iChoiceWithFocus > 0;
      bCanGoRight =
          iChoiceWithFocus >= 0 &&
          iChoiceWithFocus < (int)row.GetRowDef().m_vsChoices.size() - 1;
      break;
    case LAYOUT_SHOW_ALL_IN_ROW:
      break;
    default:
      break;
  }
  cursor.SetCanGo(bCanGoLeft, bCanGoRight);

  if (IsHumanOptionsPlayer(pn) && m_sprLineHighlight[pn].IsLoaded()) {
    COMMAND(m_sprLineHighlight[pn], "Change");
    if (row.GetRowType() == OptionRow::RowType_Exit) {
      COMMAND(m_sprLineHighlight[pn], "ChangeToExit");
    }

    m_sprLineHighlight[pn]->SetY((float)iY);
  }
}

void ScreenOptions::Update(float fDeltaTime) {
  // LOG->Trace( "ScreenOptions::Update(%f)", fDeltaTime );

  ScreenWithMenuElements::Update(fDeltaTime);
}

bool ScreenOptions::Input(const InputEventPlus& input) {
  // HACK: This screen eats mouse inputs if we don't check for them first.
  bool mouse_evt = false;
  for (int i = MOUSE_LEFT; i <= MOUSE_WHEELDOWN; i++) {
    if (input.DeviceI == DeviceInput(DEVICE_MOUSE, (DeviceButton)i)) {
      mouse_evt = true;
    }
  }
  if (mouse_evt) {
    return ScreenWithMenuElements::Input(input);
  }

  /* Allow input when transitioning in (m_In.IsTransitioning()), but ignore it
   * when we're transitioning out. */
  if (m_Cancel.IsTransitioning() || m_Out.IsTransitioning() ||
      m_fLockInputSecs > 0) {
    return false;
  }

  if (!IsHumanOptionsPlayer(input.pn)) {
    return false;
  }

  if (input.type == IET_RELEASE) {
    switch (input.MenuI) {
      case GAME_BUTTON_START:
      case GAME_BUTTON_SELECT:
      case GAME_BUTTON_MENURIGHT:
      case GAME_BUTTON_MENULEFT:
        if (INPUTMAPPER != nullptr) {
          INPUTMAPPER->ResetKeyRepeat(GAME_BUTTON_START, input.pn);
          INPUTMAPPER->ResetKeyRepeat(GAME_BUTTON_RIGHT, input.pn);
          INPUTMAPPER->ResetKeyRepeat(GAME_BUTTON_LEFT, input.pn);
        }
      default:
        break;
    }
  }

  // default input handler
  return Screen::Input(input);
}

void ScreenOptions::HandleScreenMessage(const ScreenMessage SM) {
  if (SM == SM_MenuTimer) {
    if (OnlinePlayerOptionsRequireReadyOnly(m_sName)) {
      ScreenOptionsLogTrace(
          ssprintf("ITG Online: blocked player options menu timer during "
                   "selected song configuration screen=%s",
                   m_sName.c_str()));
      return;
    }
    this->BeginFadingOut();
  } else if (SM == SM_BeginFadingOut) {
    if (IsTransitioning()) {
      return;  // already transitioning
    }

    // If the selected option sets a screen, honor it.
    const PlayerNumber master =
        GAMESTATE != nullptr ? GAMESTATE->GetMasterPlayerNumber()
                             : PLAYER_INVALID;
    std::string sThisScreen = GetNextScreenForFocusedItem(master);
    if (IsUsableScreenTarget(sThisScreen)) {
      m_sNextScreen = sThisScreen;
    } else if (!sThisScreen.empty()) {
      LuaHelpers::ReportScriptErrorFmt(
          "%s::HandleScreenMessage: rejected invalid focused next screen '%s'",
          m_sName.c_str(), sThisScreen.c_str());
    }

    // If options set a NextScreen or one is specified in metrics, then fade out
    if (GetNextScreenName() == "") {
      LuaHelpers::ReportScriptErrorFmt(
          "%s::HandleScreenMessage: Tried to fade out, but we have no next "
          "screen",
          m_sName.c_str());
      return;
    }

    StartTransitioningScreen(SM_ExportOptions);
  } else if (SM == SM_ExportOptions) {
    std::vector<PlayerNumber> vpns;
    FOREACH_HumanPlayer(p) vpns.push_back(p);
    if (LogGlobalOffsetDiagnosticsEnabled()) {
      if (PREFSMAN != nullptr) {
        PREFSMAN->LogGlobalOffsetDiagnostics(
            ssprintf("screen_options_export_begin:%s", m_sName.c_str()));
      }
    }
    for (unsigned r = 0; r < m_pRows.size(); r++)  // foreach row
    {
      OptionRow* row = m_pRows[r];
      if (row == nullptr || row->GetRowType() == OptionRow::RowType_Exit) {
        continue;
      }
      if (LogGlobalOffsetDiagnosticsEnabled() && LOG != nullptr) {
        const OptionRowHandler* handler = row->GetHandler();
        LOG->Trace(
            "GLOBAL_OFFSET_TRACE: screen_options_export_row screen='%s' "
            "row=%u title='%s' handler='%s'",
            m_sName.c_str(), r, row->GetRowTitle().c_str(),
            handler != nullptr ? handler->m_Def.m_sName.c_str() : "");
      }
      this->ExportOptions(r, vpns);
    }
    if (LogGlobalOffsetDiagnosticsEnabled()) {
      if (PREFSMAN != nullptr) {
        PREFSMAN->LogGlobalOffsetDiagnostics(
            ssprintf("screen_options_export_end:%s", m_sName.c_str()));
      }
    }

    this->HandleScreenMessage(SM_GoToNextScreen);
  }

  ScreenWithMenuElements::HandleScreenMessage(SM);
}

void ScreenOptions::PositionRows(bool bTween) {
  const int total = ClampRowsShown(NUM_ROWS_SHOWN);
  const int halfsize = total / 2;

  int first_start, first_end, second_start, second_end;

  // Choices for each player. If only one player is active, it's the same for
  // both.
  int P1Choice = IsHumanOptionsPlayer(PLAYER_1) ? m_iCurrentRow[PLAYER_1]
                                                : m_iCurrentRow[PLAYER_2];
  int P1VisibleChoice = 0;
  int P2Choice = IsHumanOptionsPlayer(PLAYER_2) ? m_iCurrentRow[PLAYER_2]
                                                : m_iCurrentRow[PLAYER_1];
  int P2VisibleChoice = 0;
  std::vector<OptionRow*> Rows;
  Rows.reserve(m_pRows.size());
  for (OptionRow* row : m_pRows) {
    if (row != nullptr) {
      Rows.push_back(row);
    }
  }
  OptionRow* pSeparateExitRow = nullptr;

  if (Rows.empty()) {
    return;
  }

  if ((bool)SEPARATE_EXIT_ROW && !Rows.empty() &&
      Rows.back()->GetRowType() == OptionRow::RowType_Exit) {
    pSeparateExitRow = Rows.back();

    // Remove the exit row for purposes of positioning everything else.
    if (P1Choice == (int)Rows.size() - 1) {
      --P1Choice;
    }
    if (P2Choice == (int)Rows.size() - 1) {
      --P2Choice;
    }

    Rows.pop_back();
  }

  std::vector<int> visibleRows;

  for (int i = 0; i < (int)Rows.size(); i++) {
    const OptionRowDefinition& def = Rows[i]->GetRowDef();
    // We only hide rows if HideOnDisable is true, and the row is not enabled
    // for any player. If HideOnDisable is false, we show all rows, even if
    // they are not enabled for any player. Disabled rows show up faded out if
    // they are not enabled
    if (!def.m_vEnabledForPlayers.empty() ||
        !Rows[i]->GetRowDef().m_bHideOnDisable) {
      visibleRows.push_back(i);
    }
  }

  const bool bTreatAllRowsVisible = visibleRows.empty();
  if (bTreatAllRowsVisible) {
    // If no rows have enabled players, treat all rows as
    // visible for layout. The EditMode help screen relies on this behavior
    // to render a view-only menu.
    // TODO: Provide a better way to specify view-only menus, and remove this
    // fallback.
    for (int i = 0; i < (int)Rows.size(); i++) {
      visibleRows.push_back(i);
    }
  }

  bool bFoundP1 = false;
  bool bFoundP2 = false;
  for (int vi = 0; vi < (int)visibleRows.size(); vi++) {
    if (visibleRows[vi] == P1Choice) {
      P1VisibleChoice = vi;
      bFoundP1 = true;
    }
    if (visibleRows[vi] == P2Choice) {
      P2VisibleChoice = vi;
      bFoundP2 = true;
    }
  }

  if (!visibleRows.empty()) {
    if (!bFoundP1) {
      if (P1Choice <= visibleRows.front()) {
        P1VisibleChoice = 0;
      } else {
        P1VisibleChoice = (int)visibleRows.size() - 1;
      }
    }
    if (!bFoundP2) {
      if (P2Choice <= visibleRows.front()) {
        P2VisibleChoice = 0;
      } else {
        P2VisibleChoice = (int)visibleRows.size() - 1;
      }
    }
  }

  const int visibleCount = (int)visibleRows.size();

  const bool BothPlayersActivated =
      IsHumanOptionsPlayer(PLAYER_1) && IsHumanOptionsPlayer(PLAYER_2);
  if (m_InputMode == INPUTMODE_SHARE_CURSOR || !BothPlayersActivated) {
    // Simply center the cursor.
    first_start = std::max(P1VisibleChoice - halfsize, 0);
    first_end = first_start + total;
    second_start = second_end = first_end;
  } else {
    // First half:
    const int earliest = std::min(P1VisibleChoice, P2VisibleChoice);
    first_start = std::max(earliest - halfsize / 2, 0);
    first_end = first_start + halfsize;

    // Second half:
    const int latest = std::max(P1VisibleChoice, P2VisibleChoice);

    second_start = std::max(latest - halfsize / 2, 0);

    // Don't overlap.
    second_start = std::max(second_start, first_end);

    second_end = second_start + halfsize;
  }

  first_end = std::min(first_end, visibleCount);
  second_end = std::min(second_end, visibleCount);

  /* If less than total (and Rows.size()) are displayed, fill in the empty
   * space intelligently. */
  for (;;) {
    const int sum = (first_end - first_start) + (second_end - second_start);
    if (sum >= visibleCount || sum >= total) {
      break;  // nothing more to display, or no room
    }
    /* First priority: expand the top of the second half until it meets
     * the first half. */
    if (second_start > first_end) {
      second_start--;
    }
    // Otherwise, expand either end.
    else if (first_start > 0) {
      first_start--;
    } else if (second_end < visibleCount) {
      second_end++;
    } else {
      ScreenOptionsLogWarn(
          ssprintf("ScreenOptions::PositionRows(%s): could not expand row "
                   "windows total=%d visible=%d",
                   m_sName.c_str(), total, visibleCount));
      break;
    }
  }

  int pos = 0;
  int visibleIndex = 0;
  for (int i = 0; i < (int)Rows.size(); i++)  // foreach row
  {
    OptionRow& row = *Rows[i];
    const OptionRowDefinition& def = row.GetRowDef();

    const bool bRowEnabled = !def.m_vEnabledForPlayers.empty();
    const bool bHideDisabled = def.m_bHideOnDisable;
    const bool bRowVisible =
        bRowEnabled || !bHideDisabled || bTreatAllRowsVisible;
    int thisVisibleIndex = -1;
    if (bRowVisible) {
      thisVisibleIndex = visibleIndex;
      visibleIndex++;
    }

    float fPos = (float)pos;

    if (bRowVisible && thisVisibleIndex < first_start) {
      fPos = -0.5f;
    } else if (
        bRowVisible && thisVisibleIndex >= first_end &&
        thisVisibleIndex < second_start) {
      fPos = total / 2 - 0.5f;
    } else if (bRowVisible && thisVisibleIndex >= second_end) {
      fPos = total - 0.5f;
    }

    Actor::TweenState tsDestination =
        m_exprRowPositionTransformFunction.GetTransformCached(
            fPos, i, std::min((int)Rows.size(), total));

    bool bHidden = !bRowVisible;
    if (bRowVisible) {
      bHidden =
          thisVisibleIndex < first_start ||
          (thisVisibleIndex >= first_end && thisVisibleIndex < second_start) ||
          thisVisibleIndex >= second_end;
    }
    if (!bRowEnabled && bHideDisabled) {
      bHidden = true;
      row.SetVisible(false);
    } else {
      row.SetVisible(true);
    }
    for (int j = 0; j < NUM_DIFFUSE_COLORS; j++) {
      tsDestination.diffuse[j].a = bHidden ? 0.0f : 1.0f;
    }
    if (!bHidden) {
      pos++;
    }
    row.SetDestination(tsDestination, bTween);
  }

  if (pSeparateExitRow) {
    Actor::TweenState tsDestination;
    tsDestination.Init();
    tsDestination.pos.y = SEPARATE_EXIT_ROW_Y;

    for (int j = 0; j < NUM_DIFFUSE_COLORS; j++) {
      tsDestination.diffuse[j].a = 1.0f;
    }
    pSeparateExitRow->SetDestination(tsDestination, bTween);
  }
}

void ScreenOptions::AfterChangeValueOrRow(PlayerNumber pn) {
  if (!IsHumanOptionsPlayer(pn)) {
    return;
  }

  const int iCurRow = m_iCurrentRow[pn];

  if (!IsRowIndexValid(m_pRows, iCurRow)) {
    return;
  }
  OptionRow& currentRow = *m_pRows[iCurRow];

  // Update m_fY and m_bHidden[].
  PositionRows(true);

  // Do positioning.
  RefreshIcons(iCurRow, pn);
  for (unsigned r = 0; r < m_pRows.size(); r++) {
    if (m_pRows[r] == nullptr) {
      continue;
    }
    /* After changing a value, position underlines. Do this for both players,
     * since underlines for both players will change with
     * m_bOneChoiceForAllPlayers. */
    FOREACH_HumanPlayer(p) m_pRows[r]->PositionUnderlines(p);
    m_pRows[r]->PositionIcons(pn);
    m_pRows[r]->SetRowHasFocus(
        pn, IsHumanOptionsPlayer(pn) && iCurRow == (int)r);
    m_pRows[r]->UpdateEnabledDisabled();
  }

  if (SHOW_SCROLL_BAR) {
    float fPercent = 0;
    if (m_pRows.size() > 1) {
      fPercent = iCurRow / float(m_pRows.size() - 1);
    }
    m_ScrollBar.SetPercentage(pn, fPercent);
  }

  // Update all players, since changing one player can move both cursors.
  FOREACH_HumanPlayer(p) TweenCursor(p);

  FOREACH_PlayerNumber(p) {
    const bool bExitSelected =
        currentRow.GetRowType() == OptionRow::RowType_Exit;
    const int humanPlayers =
        GAMESTATE != nullptr ? GAMESTATE->GetNumHumanPlayers() : 0;
    if (humanPlayers != 1 && p != pn) {
      continue;
    }
    if (m_bWasOnExit[p] != bExitSelected) {
      m_bWasOnExit[p] = bExitSelected;
      if (m_sprMore.IsLoaded()) {
        COMMAND(
            m_sprMore,
            ssprintf(
                "Exit%sP%i", bExitSelected ? "Selected" : "Unselected", p + 1));
        m_sprMore->PlayCommand(bExitSelected ? "GainFocus" : "LoseFocus");
      }
    }
  }

  const std::string text = GetExplanationText(iCurRow);
  BitmapText* pText = nullptr;
  switch (m_InputMode) {
    case INPUTMODE_INDIVIDUAL:
      pText = &m_textExplanation[pn];
      break;
    case INPUTMODE_SHARE_CURSOR:
      pText = &m_textExplanationTogether;
      break;
    default:
      break;
  }
  if (pText != nullptr && pText->GetText() != text) {
    pText->FinishTweening();
    ON_COMMAND(pText);
    pText->SetText(text);
  }
}

bool ScreenOptions::MenuBack(const InputEventPlus&) {
  if (OnlinePlayerOptionsRequireReadyOnly(m_sName)) {
    ScreenOptionsLogTrace(
        ssprintf("ITG Online: blocked player options back during selected song "
                 "configuration screen=%s",
                 m_sName.c_str()));
    return true;
  }

  if (m_Cancel.IsTransitioning() || m_Out.IsTransitioning()) {
    return true;
  }
  Cancel(SM_GoToPrevScreen);
  return true;
}

void ScreenOptions::Cancel(ScreenMessage smSendWhenDone) {
  if (OnlinePlayerOptionsRequireReadyOnly(m_sName)) {
    ScreenOptionsLogTrace(
        ssprintf("ITG Online: blocked player options cancel during selected "
                 "song configuration screen=%s message=%s",
                 m_sName.c_str(),
                 ScreenMessageHelpers::ScreenMessageToString(smSendWhenDone)
                     .c_str()));
    return;
  }

  ScreenWithMenuElements::Cancel(smSendWhenDone);
}

bool ScreenOptions::AllAreOnLastRow() const {
  if (m_pRows.empty()) {
    return false;
  }
  FOREACH_HumanPlayer(p) {
    if (m_iCurrentRow[p] != (int)(m_pRows.size() - 1)) {
      return false;
    }
  }
  return true;
}

bool ScreenOptions::MenuStart(const InputEventPlus& input) {
  PlayerNumber pn = input.pn;
  if (!IsHumanOptionsPlayer(pn)) {
    return false;
  }
  switch (input.type) {
    case IET_FIRST_PRESS:
      m_bGotAtLeastOneStartPressed[pn] = true;
      break;
    case IET_RELEASE:
      return false;  // ignore
    default:         // repeat type
      if (!m_bGotAtLeastOneStartPressed[pn]) {
        return false;  // don't allow repeat
      }
      break;
  }

  /* If we are in a three-button mode, check to see if GAME_BUTTON_LEFT and
   * GAME_BUTTON_RIGHT are being held. */
  switch (m_OptionsNavigation) {
    case NAV_THREE_KEY:
    case NAV_TOGGLE_THREE_KEY: {
      bool bHoldingLeftAndRight =
          INPUTMAPPER != nullptr &&
          INPUTMAPPER->IsBeingPressed(GAME_BUTTON_RIGHT, pn) &&
          INPUTMAPPER->IsBeingPressed(GAME_BUTTON_LEFT, pn);
      if (bHoldingLeftAndRight) {
        if (MoveRowRelative(pn, -1, input.type != IET_FIRST_PRESS)) {
          m_SoundPrevRow.Play(true);
        }
        return true;
      }
    }
    default:
      break;
  }

  this->ProcessMenuStart(input);
  return true;
}

void ScreenOptions::ProcessMenuStart(const InputEventPlus& input) {
  PlayerNumber pn = input.pn;
  if (!IsHumanOptionsPlayer(pn)) {
    return;
  }

  int iCurRow = m_iCurrentRow[pn];
  if (LogInputDiagnosticsEnabled() && LOG != nullptr) {
    LOG->Trace(
        "ITG Debug: ScreenOptions::ProcessMenuStart screen=%s pn=%d row=%d rows=%zu transitioning=%d",
        this->GetName().c_str(), (int)pn, iCurRow, m_pRows.size(),
        IsTransitioning() ? 1 : 0);
  }

  if (!IsRowIndexValid(m_pRows, iCurRow)) {
    // this shouldn't be happening, but it is, so we need to bail out. -aj
    m_SoundStart.PlayCopy(true);
    this->BeginFadingOut();
    return;
  }

  OptionRow& row = *m_pRows[iCurRow];
  if (LogInputDiagnosticsEnabled() && LOG != nullptr) {
    LOG->Trace(
        "ITG Debug: ScreenOptions::ProcessMenuStart row_title=\"%s\" row_type=%d choice=%d",
        row.GetRowTitle().c_str(), (int)row.GetRowType(),
        row.GetChoiceInRowWithFocus(pn));
  }

  if (m_OptionsNavigation == NAV_THREE_KEY_MENU &&
      row.GetRowType() != OptionRow::RowType_Exit) {
    /* In NAV_THREE_KEY_MENU mode, if a row doesn't set a screen, it does
     * something.  Apply it now, and don't go to the next screen. */
    if (!FocusedItemEndsScreen(input.pn)) {
      std::vector<PlayerNumber> vpns;
      vpns.push_back(input.pn);
      ExportOptions(iCurRow, vpns);
      return;
    }
  }

  // Check whether Start ends this screen.
  {
    bool bEndThisScreen = false;

    // If we didn't apply and return above in NAV_THREE_KEY_MENU, then the
    // selection sets a screen.
    if (m_OptionsNavigation == NAV_THREE_KEY_MENU) {
      bEndThisScreen = true;
    }

    // If there's no exit row, then pressing Start on any row ends the screen.
    if (!SHOW_EXIT_ROW) {
      bEndThisScreen = true;
    }

    // If all players are on "Exit"
    if (AllAreOnLastRow()) {
      bEndThisScreen = true;
    }

    // Don't accept START to go to the next screen if we're still transitioning
    // in.
    if (bEndThisScreen &&
        (input.type != IET_FIRST_PRESS || IsTransitioning())) {
      return;
    }

    if (bEndThisScreen) {
      m_SoundStart.PlayCopy(true);
      this->BeginFadingOut();
      return;
    }
  }

  if (row.GetFirstItemGoesDown()) {
    int iChoiceInRow = row.GetChoiceInRowWithFocus(pn);
    if (iChoiceInRow == 0) {
      MenuDown(input);
      return;
    }
  }

  if (row.GetRowDef().m_selectType == SELECT_MULTIPLE) {
    int iChoiceInRow = row.GetChoiceInRowWithFocus(pn);
    if (iChoiceInRow < 0 ||
        iChoiceInRow >= static_cast<int>(row.GetRowDef().m_vsChoices.size())) {
      ScreenOptionsLogWarn(
          ssprintf("ScreenOptions::ProcessMenuStart(%s): invalid choice %d "
                   "for row %d",
                   m_sName.c_str(), iChoiceInRow, iCurRow));
      return;
    }
    bool bSelected = !row.GetSelected(pn, iChoiceInRow);
    bool changed = row.SetSelected(pn, iChoiceInRow, bSelected);
    if (changed) {
      AfterChangeValueOrRow(pn);
    }

    if (bSelected) {
      m_SoundToggleOn.Play(true);
    } else {
      m_SoundToggleOff.Play(true);
    }

    m_pRows[iCurRow]->PositionUnderlines(pn);
    RefreshIcons(iCurRow, pn);

    Message msg("SelectMultiple");
    msg.SetParam("PlayerNumber", pn);
    msg.SetParam("RowIndex", iCurRow);
    msg.SetParam("ChoiceInRow", iChoiceInRow);
    msg.SetParam("Selected", bSelected);
    BroadcastIfAvailable(msg);

    if (row.GetFirstItemGoesDown() && row.GoToFirstOnStart()) {
      // move to the first choice in the row
      ChangeValueInRowRelative(
          m_iCurrentRow[pn], pn, -row.GetChoiceInRowWithFocus(pn),
          input.type != IET_FIRST_PRESS);
    }
  } else  // data.selectType != SELECT_MULTIPLE
  {
    switch (m_OptionsNavigation) {
      case NAV_THREE_KEY:
        // don't wrap
        if (iCurRow == (int)m_pRows.size() - 1) {
          return;
        }
        MenuDown(input);
        break;
      case NAV_THREE_KEY_ALT:
        ChangeValueInRowRelative(
            m_iCurrentRow[input.pn], input.pn, +1,
            input.type != IET_FIRST_PRESS);
        break;

      case NAV_TOGGLE_THREE_KEY:
      case NAV_TOGGLE_FIVE_KEY: {
        int iChoiceInRow = row.GetChoiceInRowWithFocus(pn);
        if (iChoiceInRow < 0 ||
            iChoiceInRow >=
                static_cast<int>(row.GetRowDef().m_vsChoices.size())) {
          return;
        }
        if (row.GetRowDef().m_bOneChoiceForAllPlayers) {
          row.SetOneSharedSelection(iChoiceInRow);
        } else {
          row.SetOneSelection(pn, iChoiceInRow);
        }

        if (row.GetFirstItemGoesDown()) {
          ChangeValueInRowRelative(
              m_iCurrentRow[pn], pn, -row.GetChoiceInRowWithFocus(pn),
              input.type != IET_FIRST_PRESS);  // move to the first choice
        } else {
          ChangeValueInRowRelative(
              m_iCurrentRow[pn], pn, 0, input.type != IET_FIRST_PRESS);
        }
        break;
      }
      case NAV_THREE_KEY_MENU:
        ScreenOptionsLogWarn(
            "ScreenOptions::ProcessMenuStart: NAV_THREE_KEY_MENU reached "
            "non-ending branch");
        return;
      case NAV_FIVE_KEY:
        /* Jump to the exit row.  (If everyone's already on the exit row, then
         * we'll have already gone to the next screen above.) */
        if (MoveRowAbsolute(pn, m_pRows.size() - 1)) {
          m_SoundNextRow.Play(true);
        }

        break;
    }
  }
}

void ScreenOptions::StoreFocus(PlayerNumber pn) {
  if (!IsValidOptionsPlayer(pn)) {
    return;
  }
  // Long rows always put us in the center, so don't update the focus.
  int iCurrentRow = m_iCurrentRow[pn];
  if (!IsRowIndexValid(m_pRows, iCurrentRow)) {
    return;
  }
  const OptionRow& row = *m_pRows[iCurrentRow];
  if (row.GetRowDef().m_layoutType == LAYOUT_SHOW_ONE_IN_ROW) {
    return;
  }

  int iWidth, iY;
  GetWidthXY(
      pn, m_iCurrentRow[pn], row.GetChoiceInRowWithFocus(pn), iWidth,
      m_iFocusX[pn], iY);
  ScreenOptionsLogTrace(
      ssprintf("cur selection %ix%i @ %i", m_iCurrentRow[pn],
               row.GetChoiceInRowWithFocus(pn), m_iFocusX[pn]));
}

bool ScreenOptions::FocusedItemEndsScreen(PlayerNumber pn) const {
  std::string sScreen = GetNextScreenForFocusedItem(pn);
  ScreenOptionsLogTrace(
      ssprintf("ITG Debug: ScreenOptions::FocusedItemEndsScreen screen=%s "
               "pn=%d next=\"%s\"",
               this->GetName().c_str(), (int)pn, sScreen.c_str()));
  return !sScreen.empty();
}

std::string ScreenOptions::GetNextScreenForFocusedItem(PlayerNumber pn) const {
  if (!IsValidOptionsPlayer(pn)) {
    return std::string();
  }
  int iCurRow = this->GetCurrentRow(pn);

  if (iCurRow == -1) {
    return std::string();
  }

  if (!IsRowIndexValid(m_pRows, iCurRow)) {
    return std::string();
  }
  const OptionRow* pRow = m_pRows[iCurRow];

  int iChoice = pRow->GetChoiceInRowWithFocus(pn);
  if (pRow->GetFirstItemGoesDown()) {
    iChoice--;
  }

  // not the "goes down" item
  if (iChoice < 0 ||
      iChoice >= static_cast<int>(pRow->GetRowDef().m_vsChoices.size())) {
    return std::string();
  }

  const OptionRowHandler* pHand = pRow->GetHandler();
  if (pHand == nullptr) {
    ScreenOptionsLogTrace(
        ssprintf("ITG Debug: ScreenOptions::GetNextScreenForFocusedItem "
                 "handler=null screen=%s pn=%d row=%d",
                 this->GetName().c_str(), (int)pn, iCurRow));
    return std::string();
  }
  std::string next = pHand->GetScreen(iChoice);
  if (!IsUsableScreenTarget(next)) {
    return std::string();
  }
  ScreenOptionsLogTrace(
      ssprintf("ITG Debug: ScreenOptions::GetNextScreenForFocusedItem "
               "screen=%s pn=%d row=%d choice=%d next=\"%s\"",
               this->GetName().c_str(), (int)pn, iCurRow, iChoice,
               next.c_str()));
  return next;
}

void ScreenOptions::BeginFadingOut() {
  this->PostScreenMessage(SM_BeginFadingOut, 0);
}

// Left/right
void ScreenOptions::ChangeValueInRowAbsolute(
    int iRow, PlayerNumber pn, int iChoiceIndex, bool bRepeat) {
  if (iRow == -1) {  // no row selected
    return;          // don't allow a move
  }
  if (!IsValidOptionsPlayer(pn) || !IsRowIndexValid(m_pRows, iRow)) {
    return;
  }

  OptionRow& row = *m_pRows[iRow];

  const int iNumChoices = row.GetRowDef().m_vsChoices.size();
  if (iChoiceIndex < 0 || iChoiceIndex >= iNumChoices) {
    return;
  }

  int iCurrentChoiceWithFocus = row.GetChoiceInRowWithFocus(pn);
  int iDelta = iChoiceIndex - iCurrentChoiceWithFocus;

  Message msg("ChangeValue");
  msg.SetParam("PlayerNumber", pn);
  msg.SetParam("RowIndex", iRow);
  BroadcastIfAvailable(msg);

  ChangeValueInRowRelative(iRow, pn, iDelta, bRepeat);
}

void ScreenOptions::ChangeValueInRowRelative(
    int iRow, PlayerNumber pn, int iDelta, bool bRepeat) {
  if (iRow == -1) {  // no row selected
    return;          // don't allow a move
  }
  if (!IsValidOptionsPlayer(pn) || !IsRowIndexValid(m_pRows, iRow)) {
    return;
  }

  OptionRow& row = *m_pRows[iRow];

  const int iNumChoices = row.GetRowDef().m_vsChoices.size();

  if (m_OptionsNavigation == NAV_THREE_KEY_MENU && iNumChoices <= 1)  // 1 or 0
  {
    /* There are no other options on the row; move up or down instead of
     * left and right. This allows navigating the options menu with
     * left/right/start.
     * XXX: Only allow repeats if the opposite key isn't pressed; otherwise,
     * holding both directions will repeat in place continuously, which is
     * weird. */
    if (MoveRowRelative(pn, iDelta, bRepeat)) {
      if (iDelta < 0) {
        m_SoundPrevRow.Play(true);
      } else {
        m_SoundNextRow.Play(true);
      }
    }
    return;
  }

  if (iNumChoices <= 1) {  // nowhere to move
    return;
  }

  if (bRepeat && !ALLOW_REPEATING_CHANGE_VALUE_INPUT) {
    return;
  }

  bool bOneChanged = false;

  int iCurrentChoiceWithFocus = row.GetChoiceInRowWithFocus(pn);
  if (iCurrentChoiceWithFocus < 0 ||
      iCurrentChoiceWithFocus >= iNumChoices) {
    iCurrentChoiceWithFocus = 0;
  }
  int iNewChoiceWithFocus = iCurrentChoiceWithFocus + iDelta;
  if (!bRepeat && WRAP_VALUE_IN_ROW.GetValue()) {
    wrap(iNewChoiceWithFocus, iNumChoices);
  } else {
    rage_clamp(iNewChoiceWithFocus, 0, iNumChoices - 1);
  }

  if (iCurrentChoiceWithFocus != iNewChoiceWithFocus) {
    bOneChanged = true;
  }

  row.SetChoiceInRowWithFocus(pn, iNewChoiceWithFocus);
  StoreFocus(pn);

  if (row.GetRowDef().m_bOneChoiceForAllPlayers) {
    /* If this row is bOneChoiceForAllPlayers, then lock the cursors together
     * for this row. Don't do this in toggle modes, since the current selection
     * and the current focus are detached. */
    bool bForceFocusedChoiceTogether = false;
    if (m_OptionsNavigation != NAV_TOGGLE_THREE_KEY &&
        m_OptionsNavigation != NAV_TOGGLE_FIVE_KEY &&
        row.GetRowDef().m_bOneChoiceForAllPlayers) {
      bForceFocusedChoiceTogether = true;
    }

    // Also lock focus if the screen is explicitly set to share cursors.
    if (m_InputMode == INPUTMODE_SHARE_CURSOR) {
      bForceFocusedChoiceTogether = true;
    }

    if (bForceFocusedChoiceTogether) {
      // lock focus together
      FOREACH_HumanPlayer(p) {
        row.SetChoiceInRowWithFocus(p, iNewChoiceWithFocus);
        StoreFocus(p);
      }
    }
  }

  FOREACH_PlayerNumber(p) {
    if (!row.GetRowDef().m_bOneChoiceForAllPlayers && p != pn) {
      continue;
    }

    if (row.GetRowDef().m_selectType == SELECT_ONE &&
        m_OptionsNavigation != NAV_TOGGLE_THREE_KEY) {
      row.SetOneSelection(p, iNewChoiceWithFocus);
    }
  }

  if (bOneChanged) {
    m_SoundChangeCol.Play(true);
  }

  if (row.GetRowDef().m_bExportOnChange) {
    std::vector<PlayerNumber> vpns;
    FOREACH_HumanPlayer(p) vpns.push_back(p);
    ExportOptions(iRow, vpns);
  }

  this->AfterChangeValueInRow(iRow, pn);
}

void ScreenOptions::AfterChangeValueInRow(int iRow, PlayerNumber pn) {
  AfterChangeValueOrRow(pn);
}

// Move up/down. Returns true if we actually moved.
bool ScreenOptions::MoveRowRelative(PlayerNumber pn, int iDir, bool bRepeat) {
  // LOG->Trace( "MoveRowRelative(pn %i, dir %i, rep %i)", pn, iDir, bRepeat );
  if (!IsValidOptionsPlayer(pn) || (iDir != -1 && iDir != 1) ||
      m_pRows.empty()) {
    return false;
  }

  int iDest = -1;
  if (!IsRowIndexValid(m_pRows, m_iCurrentRow[pn])) {
    m_iCurrentRow[pn] = 0;
  }
  for (int r = 1; r < (int)m_pRows.size(); r++) {
    int iDelta = r * iDir;
    iDest = m_iCurrentRow[pn] + iDelta;
    wrap(iDest, m_pRows.size());

    if (!IsRowIndexValid(m_pRows, iDest)) {
      iDest = -1;
      continue;
    }
    OptionRow& row = *m_pRows[iDest];
    if (row.GetRowDef().IsEnabledForPlayer(pn)) {
      break;
    }

    iDest = -1;
  }

  if (iDest == -1) {
    return false;
  }
  if (bRepeat) {
    // Don't wrap on repeating inputs.
    if (iDir > 0 && iDest < m_iCurrentRow[pn]) {
      return false;
    }
    if (iDir < 0 && iDest > m_iCurrentRow[pn]) {
      return false;
    }
  }

  return MoveRowAbsolute(pn, iDest);
}

void ScreenOptions::AfterChangeRow(PlayerNumber pn) {
  if (!IsValidOptionsPlayer(pn)) {
    return;
  }
  const int iRow = m_iCurrentRow[pn];
  if (IsRowIndexValid(m_pRows, iRow)) {
    OptionRow& row = *m_pRows[iRow];
    if (m_OptionsNavigation == NAV_TOGGLE_FIVE_KEY) {
      if (row.GetRowDef().m_selectType == SELECT_ONE) {
        // For SELECT_ONE, keep focus on selected choice.
        int iSelection = row.GetOneSelection(pn, true);
        if (iSelection != -1) {
          row.SetChoiceInRowWithFocus(pn, iSelection);
        }
      } else if (row.GetRowDef().m_layoutType != LAYOUT_SHOW_ONE_IN_ROW) {
        // Else keep the selection in the row near the focus.
        int iSelectionDist = -1;
        for (unsigned i = 0; i < row.GetTextItemsSize(); ++i) {
          int iWidth, iX, iY;
          GetWidthXY(pn, m_iCurrentRow[pn], i, iWidth, iX, iY);
          const int iDist = std::abs(iX - m_iFocusX[pn]);
          if (iSelectionDist == -1 || iDist < iSelectionDist) {
            iSelectionDist = iDist;
            row.SetChoiceInRowWithFocus(pn, i);
          }
        }
      }
    }

    if (row.GetFirstItemGoesDown()) {
      // If moving to a bFirstChoiceGoesDown row, put focus back on
      // the first choice.
      row.SetChoiceInRowWithFocus(pn, 0);
    }
  }

  AfterChangeValueOrRow(pn);
}

bool ScreenOptions::MoveRowAbsolute(PlayerNumber pn, int iRow) {
  if (!IsValidOptionsPlayer(pn) || !IsRowIndexValid(m_pRows, iRow)) {
    return false;
  }
  bool bChanged = false;
  FOREACH_PlayerNumber(p) {
    if (m_InputMode == INPUTMODE_INDIVIDUAL && p != pn) {
      continue;  // skip
    }

    if (m_iCurrentRow[p] == iRow) {
      continue;
    }

    m_iCurrentRow[p] = iRow;

    AfterChangeRow(p);
    bChanged = true;

    const OptionRow& row = *m_pRows[iRow];
    Message msg("ChangeRow");
    msg.SetParam("PlayerNumber", p);
    msg.SetParam("RowIndex", GetCurrentRow(p));
    msg.SetParam("ChangedToExit", row.GetRowType() == OptionRow::RowType_Exit);
    BroadcastIfAvailable(msg);
  }

  return bChanged;
}

bool ScreenOptions::MenuLeft(const InputEventPlus& input) {
  if (!IsHumanOptionsPlayer(input.pn)) {
    return false;
  }
  if (m_OptionsNavigation == NAV_THREE_KEY_ALT) {
    MenuUpDown(input, -1);
  } else {
    ChangeValueInRowRelative(
        m_iCurrentRow[input.pn], input.pn, -1, input.type != IET_FIRST_PRESS);
  }

  PlayerNumber pn = input.pn;
  BroadcastIfAvailable((MessageID)(Message_MenuLeftP1 + Enum::to_integral(pn)));
  return true;
}

bool ScreenOptions::MenuRight(const InputEventPlus& input) {
  if (!IsHumanOptionsPlayer(input.pn)) {
    return false;
  }
  if (m_OptionsNavigation == NAV_THREE_KEY_ALT) {
    MenuUpDown(input, +1);
  } else {
    ChangeValueInRowRelative(
        m_iCurrentRow[input.pn], input.pn, +1, input.type != IET_FIRST_PRESS);
  }

  PlayerNumber pn = input.pn;
  BroadcastIfAvailable(
      (MessageID)(Message_MenuRightP1 + Enum::to_integral(pn)));
  return true;
}

bool ScreenOptions::MenuUp(const InputEventPlus& input) {
  if (!IsHumanOptionsPlayer(input.pn)) {
    return false;
  }
  MenuUpDown(input, -1);
  PlayerNumber pn = input.pn;
  BroadcastIfAvailable((MessageID)(Message_MenuUpP1 + Enum::to_integral(pn)));
  return true;
}

bool ScreenOptions::MenuDown(const InputEventPlus& input) {
  if (!IsHumanOptionsPlayer(input.pn)) {
    return false;
  }
  MenuUpDown(input, +1);
  PlayerNumber pn = input.pn;
  BroadcastIfAvailable(
      (MessageID)(Message_MenuDownP1 + Enum::to_integral(pn)));
  return true;
}

bool ScreenOptions::MenuSelect(const InputEventPlus& input) {
  if (!IsHumanOptionsPlayer(input.pn)) {
    return false;
  }
  MenuUpDown(input, -1);
  return true;
}

void ScreenOptions::MenuUpDown(const InputEventPlus& input, int iDir) {
  if (iDir != -1 && iDir != +1) {
    return;
  }
  PlayerNumber pn = input.pn;
  if (!IsHumanOptionsPlayer(pn)) {
    return;
  }

  if (input.type == IET_REPEAT) {
    /* If down is pressed, don't allow up to repeat, and vice versa. This
     * prevents holding both up and down from toggling repeatedly in-place. */
    if (iDir == +1) {
      if (INPUTMAPPER != nullptr &&
          (INPUTMAPPER->IsBeingPressed(GAME_BUTTON_MENUUP, pn) ||
           INPUTMAPPER->IsBeingPressed(GAME_BUTTON_SELECT, pn))) {
        return;
      }
    } else {
      if (INPUTMAPPER != nullptr &&
          (INPUTMAPPER->IsBeingPressed(GAME_BUTTON_MENUDOWN, pn) ||
           INPUTMAPPER->IsBeingPressed(GAME_BUTTON_START, pn))) {
        return;
      }
    }
  }

  if (MoveRowRelative(pn, iDir, input.type != IET_FIRST_PRESS)) {
    if (iDir < 0) {
      m_SoundPrevRow.Play(true);
    } else {
      m_SoundNextRow.Play(true);
    }
  }
}
void ScreenOptions::RedrawOptions() {
  // Save current row indices before redraw
  int saved_row[NUM_PLAYERS];
  FOREACH_PlayerNumber(pn) saved_row[pn] = m_iCurrentRow[pn];

  // RestartOptions();

  // Restore current row indices if they're still valid
  FOREACH_PlayerNumber(pn) {
    if (saved_row[pn] >= 0 && saved_row[pn] < GetNumRows()) {
      const OptionRow* row = GetRow(saved_row[pn]);
      if (row != nullptr && row->GetRowDef().IsEnabledForPlayer(pn)) {
        m_iCurrentRow[pn] = saved_row[pn];
      }
    }
  }

  // Update positioning and cursors for restored indices
  PositionRows(true);
  FOREACH_HumanPlayer(pn) { PositionCursor(pn); }
  FOREACH_PlayerNumber(pn) { AfterChangeRow(pn); }

  Message msg("OptionsRedrawn");
  BroadcastIfAvailable(msg);
}

void ScreenOptions::SetOptionRowVisible(
    int row_index, bool visible, bool bRedraw) {
  if (row_index < 0 || row_index >= (int)m_pRows.size()) {
    LuaHelpers::ReportScriptErrorFmt(
        "SetOptionRowVisible: Row index %d is out of bounds", row_index);
    return;
  }

  OptionRow* pOptRow = m_pRows[row_index];
  if (pOptRow == nullptr) {
    LuaHelpers::ReportScriptErrorFmt(
        "SetOptionRowVisible: Row index %d is invalid", row_index);
    return;
  }

  pOptRow->SetVisible(visible);

  OptionRowDefinition& def = pOptRow->GetRowDef();
  if (visible) {
    def.m_bHideOnDisable = false;
    if (def.m_vEnabledForPlayers.empty()) {
      FOREACH_PlayerNumber(pn) def.m_vEnabledForPlayers.insert(pn);
    }
  } else {
    def.m_bHideOnDisable = true;
    def.m_vEnabledForPlayers.clear();
  }

  if (bRedraw) {
    RedrawOptions();
  }

  Message msg("OptionRowVisibilityChanged");
  msg.SetParam("RowIndex", row_index);
  msg.SetParam("Visible", visible);
  BroadcastIfAvailable(msg);
}

// lua start
#include "LuaBinding.h"

/** @brief Allow Lua to have access to ScreenOptions. */
class LunaScreenOptions : public Luna<ScreenOptions> {
 public:
  static int AllAreOnLastRow(T* p, lua_State* L) {
    lua_pushboolean(L, p->AllAreOnLastRow());
    return 1;
  }
  static int FocusedItemEndsScreen(T* p, lua_State* L) {
    PlayerNumber pn = PLAYER_INVALID;
    lua_pushboolean(
        L, LuaReadOptionsPlayer(L, 1, pn) && p->FocusedItemEndsScreen(pn));
    return 1;
  }
  static int GetCurrentRowIndex(T* p, lua_State* L) {
    PlayerNumber pn = PLAYER_INVALID;
    if (!LuaReadOptionsPlayer(L, 1, pn)) {
      lua_pushnumber(L, -1);
      return 1;
    }
    lua_pushnumber(L, p->GetCurrentRow(pn));
    return 1;
  }
  static int GetOptionRow(T* p, lua_State* L) {
    int row_index = -1;
    if (!LuaReadInt(L, 1, row_index)) {
      lua_pushnil(L);
      return 1;
    }
    if (row_index < 0 || row_index >= p->GetNumRows()) {
      lua_pushnil(L);
      return 1;
    }
    OptionRow* pOptRow = p->GetRow(row_index);
    if (pOptRow) {
      pOptRow->PushSelf(L);
    } else {
      lua_pushnil(L);
    }
    return 1;
  }
  static int SetOptionRowVisible(T* p, lua_State* L) {
    int row_index = -1;
    if (!LuaReadInt(L, 1, row_index)) {
      COMMON_RETURN_SELF;
    }
    bool visible = lua_toboolean(L, 2);
    bool redraw = lua_isnone(L, 3) ? true : lua_toboolean(L, 3);

    p->SetOptionRowVisible(row_index, visible, redraw);
    COMMON_RETURN_SELF;
  }
  static int RedrawOptions(T* p, lua_State* L) {
    p->RedrawOptions();
    COMMON_RETURN_SELF;
  }

  DEFINE_METHOD(GetNumRows, GetNumRows());

  static int SetOptionRowIndex(T* p, lua_State* L) {
    PlayerNumber pn = PLAYER_INVALID;
    int row_index = -1;
    if (!LuaReadOptionsPlayer(L, 1, pn) || !LuaReadInt(L, 2, row_index)) {
      COMMON_RETURN_SELF;
    }
    if (row_index < 0 || row_index >= p->GetNumRows()) {
      COMMON_RETURN_SELF;
    }
    p->MoveRowAbsolute(pn, row_index);
    COMMON_RETURN_SELF;
  }

  LunaScreenOptions() {
    ADD_METHOD(AllAreOnLastRow);
    ADD_METHOD(FocusedItemEndsScreen);
    ADD_METHOD(GetCurrentRowIndex);
    ADD_METHOD(GetOptionRow);
    ADD_METHOD(GetNumRows);
    ADD_METHOD(SetOptionRowVisible);
    ADD_METHOD(RedrawOptions);
    ADD_METHOD(SetOptionRowIndex);
  }
};

LUA_REGISTER_DERIVED_CLASS(ScreenOptions, ScreenWithMenuElements)
// lua end

/*
 * (c) 2001-2004 Chris Danford, Glenn Maynard
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
