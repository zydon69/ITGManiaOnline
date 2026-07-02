#include "WheelBase.h"

#include <algorithm>
#include <climits>
#include <cmath>
#include <string>
#include <vector>

#include "ActorFrame.h"
#include "ActorUtil.h"
#include "EnumHelper.h"
#include "GameState.h"
#include "LuaManager.h"
#include "PerfDiagnostics.h"
#include "PrefsManager.h"
#include "RageLog.h"
#include "RageTypes.h"
#include "RageUtil.h"
#include "ScreenManager.h"  // for sending SM_PlayMusicSample
#include "ScreenMessage.h"
#include "ThemeManager.h"
#include "ThemeMetric.h"
#include "WheelItemBase.h"
#include "global.h"

const int MAX_WHEEL_SOUND_SPEED = 15;
namespace {
constexpr int MIN_WHEEL_ITEM_COUNT = 1;
constexpr int MAX_WHEEL_ITEM_COUNT = 256;
constexpr float MIN_SWITCH_SECONDS = 0.001f;
constexpr float MAX_LOCKED_INITIAL_VELOCITY = 1000.0f;
constexpr int MIN_SCROLL_BAR_HEIGHT = 1;
constexpr int MAX_SCROLL_BAR_HEIGHT = 100000;
constexpr float SETTLED_POSITION_EPSILON = 0.0001f;

void WarnWheelBase(const std::string& message) {
  if (LOG != nullptr) {
    LOG->Warn("WheelBase: %s", message.c_str());
  }
}

const char* WheelItemDataTypeTraceName(WheelItemDataType type) {
  switch (type) {
    case WheelItemDataType_Generic:
      return "Generic";
    case WheelItemDataType_Section:
      return "Section";
    case WheelItemDataType_Song:
      return "Song";
    case WheelItemDataType_Roulette:
      return "Roulette";
    case WheelItemDataType_Random:
      return "Random";
    case WheelItemDataType_Portal:
      return "Portal";
    case WheelItemDataType_Course:
      return "Course";
    case WheelItemDataType_Sort:
      return "Sort";
    case WheelItemDataType_Custom:
      return "Custom";
    case WheelItemDataType_ParentSection:
      return "ParentSection";
    default:
      return "Invalid";
  }
}

void TraceWheelReintro(const char* event, const std::string& details) {
  if (LOG != nullptr && LogMusicWheelDiagnosticsEnabled()) {
    LOG->Trace(
        "SRC_AUDIT_FIX SRC-2710 WheelReintroTrace %s %s", event,
        details.c_str());
  }
}
}  // namespace

AutoScreenMessage(
    SM_SongChanged);  // TODO: Replace this with a Message and MESSAGEMAN

static const char* WheelStateNames[] = {
    "Selecting",        "FlyingOffBeforeNextSort", "FlyingOnAfterNextSort",
    "RouletteSpinning", "RouletteSlowingDown",     "Locked"};
XToString(WheelState);
StringToX(WheelState);
LuaXType(WheelState);

WheelBase::~WheelBase() {
  ClearWheelItems();
}

void WheelBase::Load(std::string sType) {
  if (LOG != nullptr) {
    LOG->Trace("WheelBase::Load('%s')", sType.c_str());
  }

  if (this->GetNumChildren() != 0 || !m_WheelBaseItems.empty()) {
    WarnWheelBase(ssprintf(
        "Load('%s') called more than once; clearing previous wheel actors",
        sType.c_str()));
    ClearWheelItems();
  }

  m_bEmpty = false;
  m_LastSelection = nullptr;
  m_iSelection = 0;
  m_fTimeLeftInState = 0;
  m_fPositionOffsetFromSelection = 0;
  m_fLockedWheelVelocity = 0;
  m_iSwitchesLeftInSpinDown = 0;
  m_Moving = 0;

  if (THEME == nullptr) {
    WarnWheelBase(ssprintf("cannot load '%s' before THEME is initialized",
                           sType.c_str()));
    m_bEmpty = true;
    return;
  }

  SWITCH_SECONDS.Load(sType, "SwitchSeconds");
  LOCKED_INITIAL_VELOCITY.Load(sType, "LockedInitialVelocity");
  SCROLL_BAR_HEIGHT.Load(sType, "ScrollBarHeight");
  m_exprItemTransformFunction.SetFromReference(
      THEME->GetMetricR(sType, "ItemTransformFunction"));
  NUM_WHEEL_ITEMS_TO_DRAW.Load(sType, "NumWheelItems");
  WHEEL_ITEM_LOCKED_COLOR.Load(sType, "WheelItemLockedColor");

  m_soundChangeMusic.Load(THEME->GetPathS(sType, "change"), true);
  m_soundLocked.Load(THEME->GetPathS(sType, "locked"), true);

  WheelItemBase* pTempl = MakeItem();
  if (pTempl == nullptr) {
    WarnWheelBase(ssprintf("MakeItem returned null while loading '%s'",
                           sType.c_str()));
    m_bEmpty = true;
    return;
  }

  ActorUtil::LoadAllCommands(*pTempl, m_sName);
  pTempl->PlayCommand("Init");
  const int wheelItemCount = GetWheelItemCount();
  for (int i = 0; i < wheelItemCount; i++) {
    WheelItemBase* pItem = pTempl->Copy();
    if (pItem == nullptr) {
      WarnWheelBase(ssprintf("failed to copy wheel item %i for '%s'", i,
                             sType.c_str()));
      continue;
    }
    m_WheelBaseItems.push_back(pItem);
  }
  RageUtil::SafeDelete(pTempl);

  if (m_WheelBaseItems.empty()) {
    WarnWheelBase(ssprintf("no wheel items were created for '%s'",
                           sType.c_str()));
    m_bEmpty = true;
    return;
  }

  // draw outside->inside
  const int displayCount = static_cast<int>(m_WheelBaseItems.size());
  for (int i = 0; i < displayCount / 2; i++) {
    this->AddChild(m_WheelBaseItems[i]);
  }
  for (int i = displayCount - 1; i >= displayCount / 2; i--) {
    this->AddChild(m_WheelBaseItems[i]);
  }

  m_sprHighlight.Load(THEME->GetPathG(sType, "highlight"));
  if (m_sprHighlight.IsLoaded()) {
    m_sprHighlight->SetName("Highlight");
    this->AddChild(m_sprHighlight);
    ActorUtil::LoadAllCommands(*m_sprHighlight, m_sName);
  } else {
    WarnWheelBase(ssprintf("highlight actor failed to load for '%s'",
                           sType.c_str()));
  }

  m_ScrollBar.SetName("ScrollBar");
  const int scrollBarHeight = std::clamp(
      SCROLL_BAR_HEIGHT.GetValue(), MIN_SCROLL_BAR_HEIGHT,
      MAX_SCROLL_BAR_HEIGHT);
  m_ScrollBar.SetBarHeight(scrollBarHeight);
  this->AddChild(&m_ScrollBar);
  ActorUtil::LoadAllCommands(m_ScrollBar, m_sName);

  SetPositions();
}

void WheelBase::BeginScreen() { m_WheelState = STATE_SELECTING; }

void WheelBase::SetItemPosition(
    Actor& item, int item_index, float offset_from_middle) {
  Actor::TweenState ts;
  if (!m_exprItemTransformFunction.GetTransformCached(
          offset_from_middle, item_index, GetWheelItemCount(), ts)) {
    item.SetVisible(false);
    return;
  }
  item.SetVisible(true);
  item.DestTweenState() = ts;
}

void WheelBase::GetItemPosition(
    float fPosOffsetsFromMiddle, float& fX_out, float& fY_out, float& fZ_out,
    float& fRotationX_out) {
  Actor::TweenState ts;
  if (!m_exprItemTransformFunction.GetTransformCached(
          fPosOffsetsFromMiddle, 0, GetWheelItemCount(), ts)) {
    fX_out = 0.0f;
    fY_out = 0.0f;
    fZ_out = 0.0f;
    fRotationX_out = 0.0f;
    return;
  }
  fX_out = ts.pos.x;
  fY_out = ts.pos.y;
  fZ_out = ts.pos.z;
  fRotationX_out = ts.rotation.x;
}

void WheelBase::UpdateScrollbar() {
  const int iTotalNumItems = static_cast<int>(m_CurWheelItemData.size());
  if (iTotalNumItems <= 0) {
    m_ScrollBar.SetPercentage(0.0f, 1.0f);
    return;
  }

  float fItemAt = m_iSelection - m_fPositionOffsetFromSelection;

  {
    float fSize = float(GetWheelItemCount()) / iTotalNumItems;
    float fCenter = fItemAt / iTotalNumItems;
    fSize *= 0.5f;

    m_ScrollBar.SetPercentage(fCenter, fSize);
  }
}

bool WheelBase::IsSettled() const {
  if (m_Moving) {
    return false;
  }
  if (m_WheelState != STATE_SELECTING && m_WheelState != STATE_LOCKED) {
    return false;
  }
  if (!std::isfinite(m_fPositionOffsetFromSelection) ||
      std::abs(m_fPositionOffsetFromSelection) > SETTLED_POSITION_EPSILON) {
    return false;
  }

  return true;
}

void WheelBase::SetPositions() {
  const int wheelItemCount = GetWheelItemCount();
  const int displayCount =
      std::min(wheelItemCount, static_cast<int>(m_WheelBaseItems.size()));
  const float visibleWheelItems = GetNumWheelItemsToDraw();
  for (int i = 0; i < displayCount; i++) {
    WheelItemBase* pDisplay = m_WheelBaseItems[i];
    if (pDisplay == nullptr) {
      continue;
    }
    const float fOffsetFromSelection =
        i - wheelItemCount / 2 + m_fPositionOffsetFromSelection;
    if (std::abs(fOffsetFromSelection) > visibleWheelItems / 2) {
      pDisplay->SetVisible(false);
    } else {
      pDisplay->SetVisible(true);
    }

    SetItemPosition(*pDisplay, i, fOffsetFromSelection);
  }
}

void WheelBase::Update(float fDeltaTime) {
  if (!std::isfinite(fDeltaTime) || fDeltaTime < 0.0f) {
    fDeltaTime = 0.0f;
  }

  ActorFrame::Update(fDeltaTime);

  // If tweens aren't controlling the position of the wheel, set positions.
  if (!GetTweenTimeLeft()) {
    SetPositions();
  }

  const int wheelItemCount = GetWheelItemCount();
  const int displayCount =
      std::min(wheelItemCount, static_cast<int>(m_WheelBaseItems.size()));
  const RageColor lockedColor = WHEEL_ITEM_LOCKED_COLOR.GetValue();
  for (int i = 0; i < displayCount; i++) {
    WheelItemBase* pDisplay = m_WheelBaseItems[i];
    if (pDisplay == nullptr) {
      continue;
    }
    if (m_WheelState == STATE_LOCKED && i != wheelItemCount / 2) {
      pDisplay->m_colorLocked = lockedColor;
    } else {
      pDisplay->m_colorLocked = RageColor(0, 0, 0, 0);
    }
  }

  // Moved to CommonUpdateProcedure, seems to work fine. Revert if it happens
  // to break something.
  UpdateScrollbar();

  if (m_Moving) {
    m_TimeBeforeMovingBegins -= fDeltaTime;
    m_TimeBeforeMovingBegins = std::max(m_TimeBeforeMovingBegins, 0.0f);
  }

  // update wheel state
  m_fTimeLeftInState -= fDeltaTime;
  if (m_fTimeLeftInState <= 0) {  // time to go to a new state
    UpdateSwitch();
  }

  if (m_WheelState == STATE_LOCKED) {
    /* Do this in at most .1 sec chunks, so we don't get weird if we stop
     * for some reason (and so it behaves the same when being single stepped).
     */
    float fTime = fDeltaTime;
    while (fTime > 0) {
      float t = std::min(fTime, 0.1f);
      fTime -= t;

      m_fPositionOffsetFromSelection =
          std::clamp(m_fPositionOffsetFromSelection, -0.3f, +0.3f);

      float fSpringForce =
          -m_fPositionOffsetFromSelection * GetSafeLockedInitialVelocity();
      m_fLockedWheelVelocity += fSpringForce;

      float fDrag = -m_fLockedWheelVelocity * t * 4;
      m_fLockedWheelVelocity += fDrag;

      m_fPositionOffsetFromSelection += m_fLockedWheelVelocity * t;

      if (std::abs(m_fPositionOffsetFromSelection) < 0.01f &&
          std::abs(m_fLockedWheelVelocity) < 0.01f) {
        m_fPositionOffsetFromSelection = 0;
        m_fLockedWheelVelocity = 0;
      }
    }
  }

  if (IsMoving()) {
    // We're automatically moving. Move linearly, and don't clamp to the
    // selection.
    float fSpinSpeed = m_SpinSpeed * m_Moving;
    m_fPositionOffsetFromSelection -= fSpinSpeed * fDeltaTime;

    /* Make sure that we don't go further than 1 away, in case the speed is
     * very high or we miss a lot of frames. */
    m_fPositionOffsetFromSelection =
        std::clamp(m_fPositionOffsetFromSelection, -1.0f, 1.0f);

    // If it passed the selection, move again.
    if ((m_Moving == -1 && m_fPositionOffsetFromSelection >= 0) ||
        (m_Moving == 1 && m_fPositionOffsetFromSelection <= 0)) {
      ChangeMusic(m_Moving);

      if (PREFSMAN != nullptr &&
          PREFSMAN->m_iMusicWheelSwitchSpeed < MAX_WHEEL_SOUND_SPEED) {
        PlaySoundIfLoaded(m_soundChangeMusic, true);
      }
    }

    if (PREFSMAN != nullptr &&
        PREFSMAN->m_iMusicWheelSwitchSpeed >= MAX_WHEEL_SOUND_SPEED &&
        m_MovingSoundTimer.Ago() >= 1.0f / MAX_WHEEL_SOUND_SPEED) {
      m_MovingSoundTimer.GetDeltaTime();
      PlaySoundIfLoaded(m_soundChangeMusic, true);
    }
  } else {
    // "rotate" wheel toward selected song
    float fSpinSpeed =
        0.2f + std::abs(m_fPositionOffsetFromSelection) /
                   GetSafeSwitchSeconds();

    if (m_fPositionOffsetFromSelection > 0) {
      m_fPositionOffsetFromSelection -= fSpinSpeed * fDeltaTime;
      if (m_fPositionOffsetFromSelection < 0) {
        m_fPositionOffsetFromSelection = 0;
      }
    } else if (m_fPositionOffsetFromSelection < 0) {
      m_fPositionOffsetFromSelection += fSpinSpeed * fDeltaTime;
      if (m_fPositionOffsetFromSelection > 0) {
        m_fPositionOffsetFromSelection = 0;
      }
    }
  }
}

void WheelBase::UpdateSwitch() {
  switch (m_WheelState) {
    case STATE_SELECTING:
      m_fTimeLeftInState = 0;
      break;
    case STATE_LOCKED:
      break;
    case STATE_FLYING_OFF_BEFORE_NEXT_SORT:
    case STATE_FLYING_ON_AFTER_NEXT_SORT:
    case STATE_ROULETTE_SPINNING:
    case STATE_ROULETTE_SLOWING_DOWN:
      WarnWheelBase(ssprintf("unexpected wheel state timeout: %i",
                             m_WheelState));
      m_WheelState = STATE_SELECTING;
      m_fTimeLeftInState = 0;
      break;
    default:
      WarnWheelBase(ssprintf("invalid wheel state: %i", m_WheelState));
      m_WheelState = STATE_SELECTING;
      m_fTimeLeftInState = 0;
  }
}

bool WheelBase::Select()  // return true if this selection can end the screen
{
  if (LOG != nullptr) {
    LOG->Trace("WheelBase::Select()");
  }

  m_Moving = 0;

  if (m_bEmpty || !HasValidSelection()) {
    return false;
  }

  WheelItemBaseData* selected = m_CurWheelItemData[m_iSelection];
  switch (selected->m_Type) {
    case WheelItemDataType_Generic:
      m_LastSelection = selected;
      return true;
    case WheelItemDataType_Section: {
      std::string sThisItemSectionName = selected->m_sText;
      // Keep track of the open section so that we can restore it
      // when navigating back to ScreenSelectMusic.
      if (GAMESTATE != nullptr) {
        GAMESTATE->sLastOpenSection = sThisItemSectionName;
      }
      if (m_sExpandedSectionName == sThisItemSectionName)  // already expanded
      {
        SetOpenSection("");  // collapse it
        PlaySoundIfLoaded(m_soundCollapse, true);
      } else  // already collapsed
      {
        SetOpenSection(sThisItemSectionName);  // expand it
        PlaySoundIfLoaded(m_soundExpand, true);
      }
    }
      // Opening/closing sections cannot end the screen
      return false;
    default:
      return true;
  }
}

WheelItemBaseData* WheelBase::GetItem(unsigned int iIndex) {
  if (!m_bEmpty && iIndex < m_CurWheelItemData.size()) {
    return m_CurWheelItemData[iIndex];
  }

  return nullptr;
}

int WheelBase::IsMoving() const {
  return m_Moving && m_TimeBeforeMovingBegins == 0;
}

void WheelBase::TweenOnScreenForSort() {
  m_fPositionOffsetFromSelection = 0;

  /* Before we send SortOn, position items back to their destinations, so
   * commands can use this as a reference point. */
  SetPositions();

  m_WheelState = STATE_FLYING_ON_AFTER_NEXT_SORT;

  this->PlayCommand("SortOn");

  m_fTimeLeftInState = GetTweenTimeLeft();
}

void WheelBase::TweenOffScreenForSort() {
  m_WheelState = STATE_FLYING_OFF_BEFORE_NEXT_SORT;

  this->PlayCommand("SortOff");

  m_fTimeLeftInState = GetTweenTimeLeft();
}

void WheelBase::ChangeMusicUnlessLocked(int n) {
  n = NormalizeMoveDistance(n);
  if (m_WheelState == STATE_LOCKED) {
    if (n) {
      m_fLockedWheelVelocity = n * GetSafeLockedInitialVelocity();
      PlaySoundIfLoaded(m_soundLocked, true);
    }
    return;
  }

  ChangeMusic(n);
}

void WheelBase::Move(int n) {
  n = NormalizeMoveDistance(n);
  TraceWheelReintro(
      "move_request",
      ssprintf(
          "requested=%d currentMoving=%d selection=%d offset=%.4f "
          "state=%d settled=%d dataCount=%zu",
          n, m_Moving, m_iSelection, m_fPositionOffsetFromSelection,
          static_cast<int>(m_WheelState), IsSettled() ? 1 : 0,
          m_CurWheelItemData.size()));
  if (n == m_Moving) {
    return;
  }

  if (m_WheelState == STATE_LOCKED) {
    if (n) {
      m_fLockedWheelVelocity = n * GetSafeLockedInitialVelocity();
      PlaySoundIfLoaded(m_soundLocked, true);
    }
    return;
  }

  if (!MoveSpecific(n)) {
    return;
  }

  m_TimeBeforeMovingBegins = 1 / 4.0f;
  m_SpinSpeed =
      PREFSMAN != nullptr ? float(PREFSMAN->m_iMusicWheelSwitchSpeed) : 0.0f;
  m_Moving = n;

  if (m_Moving) {
    ChangeMusic(m_Moving);
  }
}

bool WheelBase::MoveSpecific(int n) {
  n = NormalizeMoveDistance(n);
  /* If we're not selecting, discard this.  We won't ignore it; we'll
   * get called again every time the key is repeated. */
  /* Still process Move(0) so we sometimes continue moving immediate
   * after the sort change finished and before the repeat event causes a
   * Move(0). -Chris */
  switch (m_WheelState) {
    case STATE_SELECTING:
      break;
    case STATE_FLYING_OFF_BEFORE_NEXT_SORT:
    case STATE_FLYING_ON_AFTER_NEXT_SORT:
      if (n != 0) {
        return false;
      }
      break;
    default:
      return false;  // don't continue
  }

  if (m_Moving != 0 && n == 0 && m_TimeBeforeMovingBegins == 0) {
    /* We were moving, and now we're stopping.  If we're really close to
     * the selection, move to the next one, so we have a chance to spin down
     * smoothly. */
    if (std::abs(m_fPositionOffsetFromSelection) < 0.25f) {
      ChangeMusic(m_Moving);
    }

    /* Make sure the user always gets an SM_SongChanged when
     * Moving() is 0, so the final banner, etc. always gets set. */
    if (SCREENMAN != nullptr) {
      SCREENMAN->PostMessageToTopScreen(SM_SongChanged, 0);
    }
  }

  return true;
}

void WheelBase::ChangeMusic(int iDist) {
  if (m_CurWheelItemData.empty()) {
    m_bEmpty = true;
    m_Moving = 0;
    return;
  }

  iDist = NormalizeMoveDistance(iDist);
  if (iDist == 0) {
    return;
  }

  const int previousSelection = m_iSelection;
  const float previousOffset = m_fPositionOffsetFromSelection;
  m_iSelection += iDist;
  wrap(m_iSelection, m_CurWheelItemData.size());
  TraceWheelReintro(
      "change_music",
      ssprintf(
          "dist=%d prevSelection=%d newSelection=%d prevOffset=%.4f "
          "dataCount=%zu moving=%d",
          iDist, previousSelection, m_iSelection, previousOffset,
          m_CurWheelItemData.size(), m_Moving));

  RebuildWheelItems(iDist);

  m_fPositionOffsetFromSelection += iDist;
  TraceWheelReintro(
      "change_music_offset",
      ssprintf(
          "dist=%d selection=%d newOffset=%.4f moving=%d settled=%d",
          iDist, m_iSelection, m_fPositionOffsetFromSelection, m_Moving,
          IsSettled() ? 1 : 0));

  //	SCREENMAN->PostMessageToTopScreen( SM_SongChanged, 0 );

  /* If we're moving automatically, don't play this; it'll be called in Update.
   */
  if (!IsMoving()) {
    PlaySoundIfLoaded(m_soundChangeMusic, true);
  }
}

void WheelBase::RebuildWheelItems(int iDist) {
  m_exprItemTransformFunction.ClearCache();

  const std::vector<WheelItemBaseData*>& data = m_CurWheelItemData;
  std::vector<WheelItemBase*>& items = m_WheelBaseItems;
  if (data.empty() || items.empty()) {
    m_bEmpty = true;
    m_LastSelection = nullptr;
    return;
  }

  // rewind to first index that will be displayed;
  int iFirstVisibleIndex = m_iSelection;
  if (m_iSelection < 0 || m_iSelection > int(data.size() - 1)) {
    m_iSelection = 0;
  }

  if (m_LastSelection != nullptr &&
      std::find(data.begin(), data.end(), m_LastSelection) == data.end()) {
    m_LastSelection = nullptr;
  }

  // find the first wheel item shown
  const int wheelItemCount = GetWheelItemCount();
  const int itemCount = std::min(wheelItemCount, static_cast<int>(items.size()));
  iFirstVisibleIndex -= wheelItemCount / 2;

  wrap(iFirstVisibleIndex, data.size());
  TraceWheelReintro(
      "rebuild_begin",
      ssprintf(
          "dist=%d selection=%d firstVisible=%d dataCount=%zu "
          "wheelItemCount=%d actorCount=%zu offset=%.4f moving=%d",
          iDist, m_iSelection, iFirstVisibleIndex, data.size(), wheelItemCount,
          items.size(), m_fPositionOffsetFromSelection, m_Moving));

  // iIndex is now the index of the lowest WheelItem to draw

  int iFirst = 0;
  int iLast = itemCount - 1;
  if (iLast < 0) {
    return;
  }

  if (iDist != INT_MAX) {
    iDist = NormalizeMoveDistance(iDist);
    // Shift items and refresh only those that have changed.
    CircularShift(items, iDist);
    if (iDist > 0) {
      iFirst = std::max(0, itemCount - iDist);
    } else if (iDist < 0) {
      iLast = std::min(itemCount - 1, -iDist - 1);
    }
  }

  for (int i = iFirst; i <= iLast; i++) {
    int iIndex = iFirstVisibleIndex + i;
    wrap(iIndex, data.size());

    const WheelItemBaseData* pData = data[iIndex];
    WheelItemBase* pDisplay = items[i];
    if (pData == nullptr || pDisplay == nullptr) {
      continue;
    }

    pDisplay->SetExpanded(
        pData->m_Type == WheelItemDataType_Section &&
        pData->m_sText == m_sExpandedSectionName);
  }

  for (int i = 0; i < (int)items.size(); i++) {
    int iIndex = iFirstVisibleIndex + i;
    wrap(iIndex, data.size());
    const WheelItemBaseData* pData = data[iIndex];
    WheelItemBase* pDisplay = items[i];
    if (pData == nullptr || pDisplay == nullptr) {
      continue;
    }
    TraceWheelReintro(
        "rebuild_load_slot",
        ssprintf(
            "slot=%d dataIndex=%d hasFocus=%d drawIndex=%d type=%s text='%s'",
            i, iIndex, m_iSelection == iIndex ? 1 : 0, i,
            WheelItemDataTypeTraceName(pData->m_Type),
            pData->m_sText.c_str()));
    pDisplay->LoadFromWheelItemData(pData, iIndex, m_iSelection == iIndex, i);
  }
}

WheelItemBaseData* WheelBase::LastSelected() {
  if (m_bEmpty) {
    return nullptr;
  } else {
    return m_LastSelection;
  }
}

int WheelBase::FirstVisibleIndex() {
  if (m_CurWheelItemData.empty()) {
    return 0;
  }

  // rewind to first index that will be displayed;
  int iFirstVisibleIndex = m_iSelection;
  if (m_iSelection < 0 || m_iSelection >= int(m_CurWheelItemData.size())) {
    m_iSelection = 0;
  }

  // find the first wheel item shown
  iFirstVisibleIndex -= GetWheelItemCount() / 2;

  wrap(iFirstVisibleIndex, m_CurWheelItemData.size());
  return iFirstVisibleIndex;
}

WheelItemDataType WheelBase::GetSelectedType() {
  if (!HasValidSelection()) {
    return WheelItemDataType_Invalid;
  }

  return m_CurWheelItemData[m_iSelection]->m_Type;
}

int WheelBase::GetWheelItemCount() const {
  float numToDraw = NUM_WHEEL_ITEMS_TO_DRAW.GetValue();
  if (!std::isfinite(numToDraw)) {
    numToDraw = 0.0f;
  }

  const float requested = std::ceil(std::max(0.0f, numToDraw) + 2.0f);
  if (requested > float(MAX_WHEEL_ITEM_COUNT)) {
    return MAX_WHEEL_ITEM_COUNT;
  }

  return std::clamp(
      static_cast<int>(requested), MIN_WHEEL_ITEM_COUNT,
      MAX_WHEEL_ITEM_COUNT);
}

float WheelBase::GetNumWheelItemsToDraw() const {
  const float numToDraw = NUM_WHEEL_ITEMS_TO_DRAW.GetValue();
  if (!std::isfinite(numToDraw) || numToDraw < 0.0f) {
    return 0.0f;
  }
  return std::min(numToDraw, float(MAX_WHEEL_ITEM_COUNT));
}

float WheelBase::GetSafeSwitchSeconds() const {
  const float seconds = SWITCH_SECONDS.GetValue();
  if (!std::isfinite(seconds) || seconds < MIN_SWITCH_SECONDS) {
    return MIN_SWITCH_SECONDS;
  }
  return seconds;
}

float WheelBase::GetSafeLockedInitialVelocity() const {
  const float velocity = LOCKED_INITIAL_VELOCITY.GetValue();
  if (!std::isfinite(velocity)) {
    return 0.0f;
  }
  return std::clamp(
      velocity, -MAX_LOCKED_INITIAL_VELOCITY, MAX_LOCKED_INITIAL_VELOCITY);
}

int WheelBase::NormalizeMoveDistance(int n) const {
  if (n > 0) {
    return 1;
  }
  if (n < 0) {
    return -1;
  }
  return 0;
}

bool WheelBase::HasValidSelection() const {
  if (m_bEmpty || m_iSelection < 0 ||
      m_iSelection >= static_cast<int>(m_CurWheelItemData.size())) {
    return false;
  }

  return m_CurWheelItemData[m_iSelection] != nullptr;
}

void WheelBase::ClearWheelItems() {
  RemoveAllChildren();
  m_sprHighlight.Unload();
  for (WheelItemBase* i : m_WheelBaseItems) {
    RageUtil::SafeDelete(i);
  }
  m_WheelBaseItems.clear();
  m_LastSelection = nullptr;
}

void WheelBase::PlaySoundIfLoaded(RageSound& sound, bool isAction) {
  if (sound.IsLoaded()) {
    sound.Play(isAction);
  }
}

// lua start
#include "LuaBinding.h"

/** @brief Allow Lua to have access to the WheelBase. */
class LunaWheelBase : public Luna<WheelBase> {
 public:
  static int Move(T* p, lua_State* L) {
    p->Move(IArg(1));
    COMMON_RETURN_SELF;
  }
  static int GetWheelItem(T* p, lua_State* L) {
    int iItem = IArg(1);

    WheelItemBase* pItem = p->GetWheelItem(iItem);
    if (pItem == nullptr) {
      luaL_error(L, "%i out of bounds", iItem);
    }
    pItem->PushSelf(L);

    return 1;
  }
  static int IsSettled(T* p, lua_State* L) {
    lua_pushboolean(L, p->IsSettled());
    return 1;
  }
  static int SetOpenSection(T* p, lua_State* L) {
    p->SetOpenSection(SArg(1));
    COMMON_RETURN_SELF;
  }
  static int GetCurrentIndex(T* p, lua_State* L) {
    lua_pushnumber(L, p->GetCurrentIndex());
    return 1;
  }
  static int GetNumItems(T* p, lua_State* L) {
    lua_pushnumber(L, p->GetNumItems());
    return 1;
  }
  // evil shit
  // static int ChangeMusic( T* p, lua_State *L ){ p->ChangeMusicUnlessLocked(
  // IArg(1) ); return 0; }

  DEFINE_METHOD(GetSelectedType, GetSelectedType())
  DEFINE_METHOD(GetWheelState, GetWheelState())

  // deprecated; use GetWheelState instead:
  static int IsLocked(T* p, lua_State* L) {
    lua_pushboolean(L, p->WheelIsLocked());
    return 1;
  }

  LunaWheelBase() {
    ADD_METHOD(Move);
    ADD_METHOD(GetWheelItem);
    ADD_METHOD(IsSettled);
    ADD_METHOD(IsLocked);
    ADD_METHOD(SetOpenSection);
    ADD_METHOD(GetCurrentIndex);
    ADD_METHOD(GetNumItems);
    ADD_METHOD(GetSelectedType);
    // evil shit
    // ADD_METHOD( Move );
    // ADD_METHOD( ChangeMusic );
  }
};

LUA_REGISTER_DERIVED_CLASS(WheelBase, ActorFrame)
// lua end

/*
 * (c) 2001-2004 Chris Danford, Chris Gomez, Glenn Maynard, Josh Allen
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
