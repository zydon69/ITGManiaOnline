#include "ScreenDebugOverlay.h"

#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <cstddef>
#include <map>
#include <set>
#include <string>
#include <vector>

#include "Actor.h"
#include "ActorUtil.h"
#include "BitmapText.h"
#include "CodeDetector.h"
#include "DateTime.h"
#include "EnumHelper.h"
#include "GameCommand.h"
#include "GameConstantsAndTypes.h"
#include "GameLoop.h"
#include "GamePreferences.h"
#include "GameSoundManager.h"
#include "GameState.h"
#include "Grade.h"
#include "InputEventPlus.h"
#include "InputFilter.h"
#include "InputMapper.h"
#include "LocalizedString.h"
#include "MessageManager.h"
#include "ModsGroup.h"
#include "NoteSkinManager.h"
#include "PlayerNumber.h"
#include "PlayerState.h"
#include "Preference.h"
#include "PrefsManager.h"
#include "Profile.h"
#include "ProfileManager.h"
#include "RadarValues.h"
#include "RageDisplay.h"
#include "RageInput.h"
#include "RageInputDevice.h"
#include "RageLog.h"
#include "RageSoundManager.h"
#include "RageTextureManager.h"
#include "RageTimer.h"
#include "RageTypes.h"
#include "RageUtil.h"
#include "RageUtil/RandomNumbers.h"
#include "Screen.h"
#include "ScreenDimensions.h"
#include "ScreenGameplay.h"
#include "ScreenManager.h"
#include "Song.h"
#include "SongManager.h"
#include "SongOptions.h"
#include "StepMania.h"
#include "ThemeManager.h"
#include "ThemeMetric.h"
#include "XmlToLua.h"
#include "global.h"

static bool g_bIsDisplayed = false;
static bool g_bIsSlow = false;
static bool g_bIsHalt = false;
static RageTimer g_HaltTimer(RageZeroTimer);
static float g_fImageScaleCurrent = 1;
static float g_fImageScaleDestination = 1;

// This will disable the debug menu ENTIRELY - including F6 for autosync, F8 for
// autoplay, etc
static bool g_bEnableDebugMenu = true;

namespace {
constexpr int MAX_DEBUG_PAGES = 4;

bool IsFinite(float value) {
  return std::isfinite(value);
}

bool IsValidDebugPlayer(PlayerNumber pn) {
  return pn >= PLAYER_1 && pn < NUM_PLAYERS;
}

bool IsValidDebugProfileSlot(ProfileSlot slot) {
  return slot == ProfileSlot_Player1 || slot == ProfileSlot_Player2 ||
         slot == ProfileSlot_Machine;
}

bool IsValidPlayerControllerValue(PlayerController pc) {
  return pc == PC_HUMAN || pc == PC_AUTOPLAY || pc == PC_CPU;
}

bool IsValidAutosyncTypeValue(AutosyncType type) {
  return type == AutosyncType_Off || type == AutosyncType_Song ||
         type == AutosyncType_Machine || type == AutosyncType_Tempo;
}

void WarnDebugOverlay(const std::string& message) {
  if (LOG != nullptr) {
    LOG->Warn("ScreenDebugOverlay: %s", message.c_str());
  }
}

bool IsThemeReadyForDebugOverlay() {
  return THEME != nullptr && THEME->IsThemeLoaded();
}

template <typename T>
Preference<T>* GetDebugPreference(const std::string& name) {
  Preference<T>* pref = Preference<T>::GetPreferenceByName(name);
  if (pref == nullptr) {
    static std::set<std::string> s_warnedMissingPrefs;
    if (s_warnedMissingPrefs.insert(name).second) {
      WarnDebugOverlay("missing preference '" + name + "'.");
    }
  }
  return pref;
}

Screen* GetTopScreenSafe() {
  return SCREENMAN != nullptr ? SCREENMAN->GetTopScreen() : nullptr;
}

PlayerNumber PlayerNumberFromProfileSlot(ProfileSlot slot) {
  if (slot == ProfileSlot_Player1 || slot == ProfileSlot_Player2) {
    return static_cast<PlayerNumber>(slot);
  }
  return PLAYER_INVALID;
}

std::string GetProfileSlotDisplayName(ProfileSlot slot) {
  switch (slot) {
    case ProfileSlot_Machine:
      return "Machine";
    case ProfileSlot_Player1:
      return "Player 1";
    case ProfileSlot_Player2:
      return "Player 2";
    default:
      return "Invalid";
  }
}

bool IsGameplay() {
  Screen* top = GetTopScreenSafe();
  return top != nullptr && top->GetScreenType() == gameplay;
}
}  // namespace

// DebugLine theming
static const ThemeMetric<RageColor> BACKGROUND_COLOR(
    "ScreenDebugOverlay", "BackgroundColor");
static const ThemeMetric<RageColor> LINE_ON_COLOR(
    "ScreenDebugOverlay", "LineOnColor");
static const ThemeMetric<RageColor> LINE_OFF_COLOR(
    "ScreenDebugOverlay", "LineOffColor");
static const ThemeMetric<float> LINE_START_Y(
    "ScreenDebugOverlay", "LineStartY");
static const ThemeMetric<float> LINE_SPACING(
    "ScreenDebugOverlay", "LineSpacing");
static const ThemeMetric<float> LINE_BUTTON_X(
    "ScreenDebugOverlay", "LineButtonX");
static const ThemeMetric<float> LINE_FUNCTION_X(
    "ScreenDebugOverlay", "LineFunctionX");
static const ThemeMetric<float> PAGE_START_X(
    "ScreenDebugOverlay", "PageStartX");
static const ThemeMetric<float> PAGE_SPACING_X(
    "ScreenDebugOverlay", "PageSpacingX");

// self-registering debug lines
// We don't use SubscriptionManager, because we want to keep the line order.
static LocalizedString ON("ScreenDebugOverlay", "on");
static LocalizedString OFF("ScreenDebugOverlay", "off");
static LocalizedString MUTE_ACTIONS_ON("ScreenDebugOverlay", "Mute actions on");
static LocalizedString MUTE_ACTIONS_OFF(
    "ScreenDebugOverlay", "Mute actions off");

class IDebugLine;
static std::vector<IDebugLine*>* g_pvpSubscribers = nullptr;
class IDebugLine {
 public:
  IDebugLine() {
    if (g_pvpSubscribers == nullptr) {
      g_pvpSubscribers = new std::vector<IDebugLine*>;
    }
    g_pvpSubscribers->push_back(this);
  }
  virtual ~IDebugLine() {}
  enum Type { all_screens, gameplay_only };
  virtual Type GetType() const { return all_screens; }
  virtual std::string GetDisplayTitle() = 0;
  virtual std::string GetDisplayValue() {
    return IsEnabled() ? ON.GetValue() : OFF.GetValue();
  }
  virtual std::string GetPageName() const { return "Main"; }
  virtual bool ForceOffAfterUse() const { return false; }
  virtual bool RefreshAfterUse() const { return true; }
  virtual bool IsEnabled() = 0;
  virtual void DoAndLog(std::string& sMessageOut) {
    std::string s1 = GetDisplayTitle();
    std::string s2 = GetDisplayValue();
    if (!s2.empty()) {
      s1 += " - ";
    }
    sMessageOut = s1 + s2;
  };

  DeviceInput m_Button;
};

REGISTER_SCREEN_CLASS(ScreenDebugOverlay);

ScreenDebugOverlay::~ScreenDebugOverlay() {
  this->RemoveAllChildren();

  for (BitmapText* p : m_vptextPages) {
    RageUtil::SafeDelete(p);
  }
  for (BitmapText* p : m_vptextButton) {
    RageUtil::SafeDelete(p);
  }
  m_vptextButton.clear();
  for (BitmapText* p : m_vptextFunction) {
    RageUtil::SafeDelete(p);
  }
  m_vptextFunction.clear();
}

std::string ScreenDebugOverlay::GetCurrentPageName() const {
  if (m_asPages.empty()) {
    return std::string();
  }

  int page = m_iCurrentPage;
  rage_clamp(page, 0, static_cast<int>(m_asPages.size()) - 1);
  return m_asPages[page];
}

bool ScreenDebugOverlay::HasTextForLine(std::size_t index) const {
  return index < m_vptextButton.size() && index < m_vptextFunction.size() &&
         m_vptextButton[index] != nullptr &&
         m_vptextFunction[index] != nullptr;
}

const int MAX_DEBUG_LINES = 30;
struct MapDebugToDI {
  DeviceInput holdForDebug1;
  DeviceInput holdForDebug2;
  DeviceInput holdForSlow;
  DeviceInput holdForFast;
  DeviceInput toggleMute;
  DeviceInput debugButton[MAX_DEBUG_LINES];
  DeviceInput gameplayButton[MAX_DEBUG_LINES];
  std::map<DeviceInput, int> pageButton;
  void Clear() {
    holdForDebug1.MakeInvalid();
    holdForDebug2.MakeInvalid();
    holdForSlow.MakeInvalid();
    holdForFast.MakeInvalid();
    toggleMute.MakeInvalid();
    for (int i = 0; i < MAX_DEBUG_LINES; i++) {
      debugButton[i].MakeInvalid();
      gameplayButton[i].MakeInvalid();
    }
  }
};
static MapDebugToDI g_Mappings;

static LocalizedString IN_GAMEPLAY("ScreenDebugOverlay", "%s in gameplay");
static LocalizedString OR("ScreenDebugOverlay", "or");
static std::string GetDebugButtonName(const IDebugLine* pLine) {
  if (pLine == nullptr || INPUTMAN == nullptr || !pLine->m_Button.IsValid()) {
    return std::string();
  }
  std::string s = INPUTMAN->GetDeviceSpecificInputString(pLine->m_Button);
  IDebugLine::Type type = pLine->GetType();
  switch (type) {
    case IDebugLine::all_screens:
      return s;
    case IDebugLine::gameplay_only:
      return ssprintf(IN_GAMEPLAY.GetValue().c_str(), s.c_str());
    default:
      WarnDebugOverlay(ssprintf("ignored invalid debug line type %i.", type));
      return std::string();
  }
}

template <typename U, typename V>
static bool GetKeyFromMap(const std::map<U, V>& m, const V& val, U& key) {
  for (typename std::map<U, V>::const_iterator iter = m.begin();
       iter != m.end(); ++iter) {
    if (iter->second == val) {
      key = iter->first;
      return true;
    }
  }
  return false;
}

static LocalizedString DEBUG_MENU("ScreenDebugOverlay", "Debug Menu");
void ScreenDebugOverlay::Init() {
  g_bEnableDebugMenu =
      PREFSMAN != nullptr && PREFSMAN->m_bDebugMenuEnabled.Get();

  Screen::Init();
  this->SetVisible(false);

  if (!g_bEnableDebugMenu) {
    return;
  }

  if (!IsThemeReadyForDebugOverlay() || g_pvpSubscribers == nullptr) {
    WarnDebugOverlay("disabled because theme or debug line registry is missing.");
    g_bEnableDebugMenu = false;
    return;
  }

  // Init debug mappings
  // TODO: Arch-specific?
  {
    g_Mappings.Clear();

    g_Mappings.holdForDebug1 = DeviceInput(DEVICE_KEYBOARD, KEY_F3);
    g_Mappings.holdForDebug2.MakeInvalid();
    g_Mappings.holdForSlow = DeviceInput(DEVICE_KEYBOARD, KEY_ACCENT);
    g_Mappings.holdForFast = DeviceInput(DEVICE_KEYBOARD, KEY_TAB);
    g_Mappings.toggleMute = DeviceInput(DEVICE_KEYBOARD, KEY_PAUSE);

    /* TODO: Find a better way of indicating which option is which here.
     * Maybe we should take a page from ScreenEdit's menus and make
     * RowDefs()? */

    int i = 0;
    g_Mappings.gameplayButton[i++] = DeviceInput(DEVICE_KEYBOARD, KEY_F8);
    g_Mappings.gameplayButton[i++] = DeviceInput(DEVICE_KEYBOARD, KEY_F7);
    g_Mappings.gameplayButton[i++] = DeviceInput(DEVICE_KEYBOARD, KEY_F6);
    i = 0;
    g_Mappings.debugButton[i++] = DeviceInput(DEVICE_KEYBOARD, KEY_C1);
    g_Mappings.debugButton[i++] = DeviceInput(DEVICE_KEYBOARD, KEY_C2);
    g_Mappings.debugButton[i++] = DeviceInput(DEVICE_KEYBOARD, KEY_C3);
    g_Mappings.debugButton[i++] = DeviceInput(DEVICE_KEYBOARD, KEY_C4);
    g_Mappings.debugButton[i++] = DeviceInput(DEVICE_KEYBOARD, KEY_C5);
    g_Mappings.debugButton[i++] = DeviceInput(DEVICE_KEYBOARD, KEY_C6);
    g_Mappings.debugButton[i++] = DeviceInput(DEVICE_KEYBOARD, KEY_C7);
    g_Mappings.debugButton[i++] = DeviceInput(DEVICE_KEYBOARD, KEY_C8);
    g_Mappings.debugButton[i++] = DeviceInput(DEVICE_KEYBOARD, KEY_C9);
    g_Mappings.debugButton[i++] = DeviceInput(DEVICE_KEYBOARD, KEY_C0);
    g_Mappings.debugButton[i++] = DeviceInput(DEVICE_KEYBOARD, KEY_Cq);
    g_Mappings.debugButton[i++] = DeviceInput(DEVICE_KEYBOARD, KEY_Cw);
    g_Mappings.debugButton[i++] = DeviceInput(DEVICE_KEYBOARD, KEY_Ce);
    g_Mappings.debugButton[i++] = DeviceInput(DEVICE_KEYBOARD, KEY_Cr);
    g_Mappings.debugButton[i++] = DeviceInput(DEVICE_KEYBOARD, KEY_Ct);
    g_Mappings.debugButton[i++] = DeviceInput(DEVICE_KEYBOARD, KEY_Cy);
    g_Mappings.debugButton[i++] = DeviceInput(DEVICE_KEYBOARD, KEY_Cu);
    g_Mappings.debugButton[i++] = DeviceInput(DEVICE_KEYBOARD, KEY_Ci);
    g_Mappings.debugButton[i++] = DeviceInput(DEVICE_KEYBOARD, KEY_Co);
    g_Mappings.debugButton[i++] = DeviceInput(DEVICE_KEYBOARD, KEY_Cp);
    g_Mappings.debugButton[i++] = DeviceInput(DEVICE_KEYBOARD, KEY_Ca);
    g_Mappings.debugButton[i++] = DeviceInput(DEVICE_KEYBOARD, KEY_Cs);
    g_Mappings.debugButton[i++] = DeviceInput(DEVICE_KEYBOARD, KEY_Cd);
    g_Mappings.pageButton[DeviceInput(DEVICE_KEYBOARD, KEY_F5)] = 0;
    g_Mappings.pageButton[DeviceInput(DEVICE_KEYBOARD, KEY_F6)] = 1;
    g_Mappings.pageButton[DeviceInput(DEVICE_KEYBOARD, KEY_F7)] = 2;
    g_Mappings.pageButton[DeviceInput(DEVICE_KEYBOARD, KEY_F8)] = 3;
  }

  std::map<std::string, int> iNextDebugButton;
  int iNextGameplayButton = 0;
  for (IDebugLine* p : *g_pvpSubscribers) {
    if (p == nullptr) {
      continue;
    }
    std::string sPageName = p->GetPageName();
    if (sPageName.empty()) {
      sPageName = "Main";
    }

    DeviceInput di;
    switch (p->GetType()) {
      case IDebugLine::all_screens:
        if (iNextDebugButton[sPageName] >= MAX_DEBUG_LINES) {
          WarnDebugOverlay(
              "too many debug lines for page '" + sPageName + "'.");
          di.MakeInvalid();
        } else {
          di = g_Mappings.debugButton[iNextDebugButton[sPageName]++];
        }
        break;
      case IDebugLine::gameplay_only:
        if (iNextGameplayButton >= MAX_DEBUG_LINES) {
          WarnDebugOverlay("too many gameplay-only debug lines.");
          di.MakeInvalid();
        } else {
          di = g_Mappings.gameplayButton[iNextGameplayButton++];
        }
        break;
      default:
        WarnDebugOverlay(
            ssprintf("ignored invalid debug line type %i.", p->GetType()));
        di.MakeInvalid();
        break;
    }
    p->m_Button = di;

    if (find(m_asPages.begin(), m_asPages.end(), sPageName) ==
        m_asPages.end()) {
      if ((int)m_asPages.size() >= MAX_DEBUG_PAGES) {
        WarnDebugOverlay("debug page '" + sPageName + "' has no page key.");
      }
      m_asPages.push_back(sPageName);
    }
  }

  m_iCurrentPage = 0;
  m_bForcedHidden = false;

  m_Quad.StretchTo(RectF(0, 0, SCREEN_WIDTH, SCREEN_HEIGHT));
  if (BACKGROUND_COLOR.IsLoaded()) {
    m_Quad.SetDiffuse(BACKGROUND_COLOR);
  }
  this->AddChild(&m_Quad);

  // if you're going to add user commands, make sure to have the overrides
  // set after parsing the metrics. -aj
  m_textHeader.SetName("HeaderText");
  m_textHeader.LoadFromFont(THEME->GetPathF("ScreenDebugOverlay", "header"));
  LOAD_ALL_COMMANDS_AND_SET_XY_AND_ON_COMMAND(m_textHeader);
  m_textHeader.SetText(DEBUG_MENU);
  this->AddChild(&m_textHeader);

  auto start = m_asPages.begin();
  for (std::vector<std::string>::const_iterator s = m_asPages.begin();
       s != m_asPages.end(); ++s) {
    int iPage = s - start;

    DeviceInput di;
    bool b = GetKeyFromMap(g_Mappings.pageButton, iPage, di);
    if (!b) {
      di.MakeInvalid();
    }

    std::string sButton =
        INPUTMAN != nullptr && di.IsValid()
            ? INPUTMAN->GetDeviceSpecificInputString(di)
            : std::string();

    BitmapText* p = new BitmapText;
    p->SetName("PageText");
    p->LoadFromFont(THEME->GetPathF("ScreenDebugOverlay", "page"));
    LOAD_ALL_COMMANDS_AND_ON_COMMAND(p);
    // todo: Y value is still hardcoded. -aj
    p->SetXY(PAGE_START_X + iPage * PAGE_SPACING_X, SCREEN_TOP + 20);
    p->SetText(*s + " (" + sButton + ")");
    m_vptextPages.push_back(p);
    this->AddChild(p);
  }

  for (auto p = g_pvpSubscribers->begin(); p != g_pvpSubscribers->end(); ++p) {
    {
      BitmapText* bt = new BitmapText;
      bt->SetName("ButtonText");
      bt->LoadFromFont(THEME->GetPathF("ScreenDebugOverlay", "line"));
      bt->SetHorizAlign(align_right);
      bt->SetText("blah");
      LOAD_ALL_COMMANDS_AND_ON_COMMAND(*bt);
      m_vptextButton.push_back(bt);
      this->AddChild(bt);
    }
    {
      BitmapText* bt = new BitmapText;
      bt->SetName("FunctionText");
      bt->LoadFromFont(THEME->GetPathF("ScreenDebugOverlay", "line"));
      bt->SetHorizAlign(align_left);
      bt->SetText("blah");
      LOAD_ALL_COMMANDS_AND_ON_COMMAND(*bt);
      m_vptextFunction.push_back(bt);
      this->AddChild(bt);
    }
  }
}

void ScreenDebugOverlay::Update(float fDeltaTime) {
  if (!g_bEnableDebugMenu) {
    Screen::Update(fDeltaTime);
    this->SetVisible(false);
    return;
  }

  if (INPUTFILTER != nullptr) {
    float fRate = 1;
    if (INPUTFILTER->IsBeingPressed(g_Mappings.holdForFast)) {
      if (INPUTFILTER->IsBeingPressed(g_Mappings.holdForSlow)) {
        fRate = 0;  // both; stop time
      } else {
        fRate *= 4;
      }
    } else if (INPUTFILTER->IsBeingPressed(g_Mappings.holdForSlow)) {
      fRate /= 4;
    }

    if (g_bIsHalt) {
      fRate = 0;
    } else if (g_bIsSlow) {
      fRate /= 4;
    }

    GameLoop::SetUpdateRate(fRate);
  }

  if (!IsFinite(g_fImageScaleCurrent)) {
    WarnDebugOverlay("reset non-finite current image scale.");
    g_fImageScaleCurrent = 1.0f;
  }
  if (!IsFinite(g_fImageScaleDestination)) {
    WarnDebugOverlay("reset non-finite destination image scale.");
    g_fImageScaleDestination = 1.0f;
  }
  rage_clamp(g_fImageScaleDestination, 0.25f, 4.0f);

  bool bCenteringNeedsUpdate = g_fImageScaleCurrent != g_fImageScaleDestination;
  fapproach(g_fImageScaleCurrent, g_fImageScaleDestination, fDeltaTime);
  if (bCenteringNeedsUpdate && DISPLAY != nullptr && PREFSMAN != nullptr) {
    DISPLAY->ChangeCentering(
        PREFSMAN->m_iCenterImageTranslateX, PREFSMAN->m_iCenterImageTranslateY,
        PREFSMAN->m_fCenterImageAddWidth - (int)SCREEN_WIDTH +
            (int)(g_fImageScaleCurrent * SCREEN_WIDTH),
        PREFSMAN->m_fCenterImageAddHeight - (int)SCREEN_HEIGHT +
            (int)(g_fImageScaleCurrent * SCREEN_HEIGHT));
  } else if (bCenteringNeedsUpdate) {
    WarnDebugOverlay("skipped display centering update because runtime is incomplete.");
  }

  Screen::Update(fDeltaTime);

  this->SetVisible(g_bIsDisplayed && !m_bForcedHidden);
  if (!g_bIsDisplayed) {
    return;
  }

  UpdateText();
}

void ScreenDebugOverlay::UpdateText() {
  if (m_asPages.empty() || g_pvpSubscribers == nullptr) {
    return;
  }

  rage_clamp(m_iCurrentPage, 0, static_cast<int>(m_asPages.size()) - 1);

  auto start = m_asPages.begin();
  for (std::vector<std::string>::const_iterator s = m_asPages.begin();
       s != m_asPages.end(); ++s) {
    int iPage = s - start;
    if (iPage >= 0 && static_cast<std::size_t>(iPage) < m_vptextPages.size() &&
        m_vptextPages[iPage] != nullptr) {
      m_vptextPages[iPage]->PlayCommand(
          (iPage == m_iCurrentPage) ? "GainFocus" : "LoseFocus");
    }
  }

  // todo: allow changing of various spacing/location things -aj
  int iOffset = 0;
  auto subStart = g_pvpSubscribers->begin();
  for (std::vector<IDebugLine*>::const_iterator p = subStart;
       p != g_pvpSubscribers->end(); ++p) {
    if (*p == nullptr) {
      continue;
    }

    std::string sPageName = (*p)->GetPageName();
    if (sPageName.empty()) {
      sPageName = "Main";
    }

    const std::size_t i = p - subStart;
    if (!HasTextForLine(i)) {
      continue;
    }

    float fY = LINE_START_Y.GetValue() + iOffset * LINE_SPACING.GetValue();

    BitmapText& txt1 = *m_vptextButton[i];
    BitmapText& txt2 = *m_vptextFunction[i];
    if (sPageName != GetCurrentPageName()) {
      txt1.SetVisible(false);
      txt2.SetVisible(false);
      continue;
    }
    txt1.SetVisible(true);
    txt2.SetVisible(true);
    ++iOffset;

    txt1.SetX(LINE_BUTTON_X);
    txt1.SetY(fY);

    txt2.SetX(LINE_FUNCTION_X);
    txt2.SetY(fY);

    std::string s1 = (*p)->GetDisplayTitle();
    std::string s2 = (*p)->GetDisplayValue();

    bool bOn = (*p)->IsEnabled();

    if (LINE_ON_COLOR.IsLoaded() && LINE_OFF_COLOR.IsLoaded()) {
      txt1.SetDiffuse(bOn ? LINE_ON_COLOR.GetValue()
                          : LINE_OFF_COLOR.GetValue());
      txt2.SetDiffuse(bOn ? LINE_ON_COLOR.GetValue()
                          : LINE_OFF_COLOR.GetValue());
    }

    std::string sButton = GetDebugButtonName(*p);
    if (!sButton.empty()) {
      sButton += ": ";
    }
    txt1.SetText(sButton);
    if (!s2.empty()) {
      s1 += " - ";
    }
    txt2.SetText(s1 + s2);
  }

  if (g_bIsHalt) {
    /* More than once I've paused the game accidentally and wasted time
     * figuring out why, so warn. */
    if (g_HaltTimer.Ago() >= 5.0f) {
      g_HaltTimer.Touch();
      if (LOG != nullptr) {
        LOG->Warn("Game halted");
      }
    }
  }
}

template <typename U, typename V>
static bool GetValueFromMap(const std::map<U, V>& m, const U& key, V& val) {
  typename std::map<U, V>::const_iterator it = m.find(key);
  if (it == m.end()) {
    return false;
  }
  val = it->second;
  return true;
}

bool ScreenDebugOverlay::Input(const InputEventPlus& input) {
  if (!g_bEnableDebugMenu || g_pvpSubscribers == nullptr) {
    return Screen::Input(input);
  }

  if (input.DeviceI == g_Mappings.holdForDebug1 ||
      input.DeviceI == g_Mappings.holdForDebug2) {
    if (INPUTFILTER == nullptr) {
      return Screen::Input(input);
    }
    bool bHoldingNeither =
        (!g_Mappings.holdForDebug1.IsValid() ||
         !INPUTFILTER->IsBeingPressed(g_Mappings.holdForDebug1)) &&
        (!g_Mappings.holdForDebug2.IsValid() ||
         !INPUTFILTER->IsBeingPressed(g_Mappings.holdForDebug2));
    bool bHoldingBoth =
        (!g_Mappings.holdForDebug1.IsValid() ||
         INPUTFILTER->IsBeingPressed(g_Mappings.holdForDebug1)) &&
        (!g_Mappings.holdForDebug2.IsValid() ||
         INPUTFILTER->IsBeingPressed(g_Mappings.holdForDebug2));
    if (bHoldingNeither) {
      m_bForcedHidden = false;
    }

    if (bHoldingBoth) {
      g_bIsDisplayed = true;
    } else {
      g_bIsDisplayed = false;
    }
  }
  if (input.DeviceI == g_Mappings.toggleMute && PREFSMAN != nullptr) {
    PREFSMAN->m_MuteActions.Set(!PREFSMAN->m_MuteActions);
    if (SCREENMAN != nullptr) {
      SCREENMAN->SystemMessage(
          PREFSMAN->m_MuteActions ? MUTE_ACTIONS_ON.GetValue()
                                  : MUTE_ACTIONS_OFF.GetValue());
    }
  }

  int iPage = 0;
  if (g_bIsDisplayed &&
      GetValueFromMap(g_Mappings.pageButton, input.DeviceI, iPage)) {
    if (input.type != IET_FIRST_PRESS) {
      return true;  // eat the input but do nothing
    }
    if (!m_asPages.empty()) {
      m_iCurrentPage = iPage;
      rage_clamp(m_iCurrentPage, 0, (int)m_asPages.size() - 1);
    }
    return true;
  }

  auto start = g_pvpSubscribers->begin();
  for (std::vector<IDebugLine*>::const_iterator p = start;
       p != g_pvpSubscribers->end(); ++p) {
    if (*p == nullptr) {
      continue;
    }
    std::string sPageName = (*p)->GetPageName();
    if (sPageName.empty()) {
      sPageName = "Main";
    }

    const std::size_t i = p - start;

    // Gameplay buttons are available only in gameplay. Non-gameplay buttons
    // are only available when the screen is displayed.
    IDebugLine::Type type = (*p)->GetType();
    switch (type) {
      case IDebugLine::all_screens:
        if (!g_bIsDisplayed) {
          continue;
        }
        if (sPageName != GetCurrentPageName()) {
          continue;
        }
        break;
      case IDebugLine::gameplay_only:
        if (!IsGameplay()) {
          continue;
        }
        break;
      default:
        WarnDebugOverlay(ssprintf("ignored invalid debug line type %i.", type));
        continue;
    }

    if ((*p)->m_Button.IsValid() && input.DeviceI == (*p)->m_Button) {
      if (input.type != IET_FIRST_PRESS) {
        return true;  // eat the input but do nothing
      }

      // do the action
      std::string sMessage;
      const bool bRefreshAfterUse = (*p)->RefreshAfterUse();
      const bool bForceOffAfterUse = (*p)->ForceOffAfterUse();
      (*p)->DoAndLog(sMessage);
      if (!sMessage.empty() && LOG != nullptr) {
        LOG->Trace("DEBUG: %s", sMessage.c_str());
      }
      if (bForceOffAfterUse) {
        m_bForcedHidden = true;
      }

      if (!bRefreshAfterUse) {
        return true;
      }

      // update text to show the effect of what changed above
      UpdateText();

      // show what changed
      if (HasTextForLine(i)) {
        BitmapText& bt = *m_vptextButton[i];
        bt.FinishTweening();
        bt.PlayCommand("Toggled");
      }

      return true;
    }
  }

  return Screen::Input(input);
}

// DebugLine helpers
static void SetSpeed() {
  // PauseMusic( g_bIsHalt );
}

void ChangeVolume(float fDelta) {
  Preference<float>* pRet = GetDebugPreference<float>("SoundVolume");
  if (pRet == nullptr) {
    return;
  }
  float fVol = pRet->Get();
  fVol += fDelta;
  rage_clamp(fVol, 0.0f, 1.0f);
  pRet->Set(fVol);
  if (SOUNDMAN != nullptr) {
    SOUNDMAN->SetMixVolume();
  }
}

void ChangeVisualDelay(float fDelta) {
  Preference<float>* pRet = GetDebugPreference<float>("VisualDelaySeconds");
  if (pRet == nullptr) {
    return;
  }
  float fSecs = pRet->Get();
  fSecs += fDelta;
  rage_clamp(fSecs, -1.0f, 1.0f);
  pRet->Set(fSecs);
}

// DebugLines
static LocalizedString AUTO_PLAY("ScreenDebugOverlay", "AutoPlay");
static LocalizedString ASSIST("ScreenDebugOverlay", "Assist");
static LocalizedString AUTOSYNC("ScreenDebugOverlay", "Autosync");
static LocalizedString COIN_MODE("ScreenDebugOverlay", "CoinMode");
static LocalizedString HALT("ScreenDebugOverlay", "Halt");
static LocalizedString LIGHTS_DEBUG("ScreenDebugOverlay", "Lights Debug");
static LocalizedString MONKEY_INPUT("ScreenDebugOverlay", "Monkey Input");
static LocalizedString RENDERING_STATS("ScreenDebugOverlay", "Rendering Stats");
static LocalizedString VSYNC("ScreenDebugOverlay", "Vsync");
static LocalizedString MULTITEXTURE("ScreenDebugOverlay", "Multitexture");
static LocalizedString SCREEN_TEST_MODE(
    "ScreenDebugOverlay", "Screen Test Mode");
static LocalizedString SCREEN_SHOW_MASKS("ScreenDebugOverlay", "Show Masks");
static LocalizedString PROFILE("ScreenDebugOverlay", "Profile");
static LocalizedString CLEAR_PROFILE_STATS(
    "ScreenDebugOverlay", "Clear Profile Stats");
static LocalizedString FILL_PROFILE_STATS(
    "ScreenDebugOverlay", "Fill Profile Stats");
static LocalizedString SEND_NOTES_ENDED(
    "ScreenDebugOverlay", "Send Notes Ended");
static LocalizedString RESET_KEY_MAP(
    "ScreenDebugOverlay", "Reset key mapping to default");
static LocalizedString MUTE_ACTIONS("ScreenDebugOverlay", "Mute actions");
static LocalizedString RELOAD("ScreenDebugOverlay", "Reload");
static LocalizedString RESTART("ScreenDebugOverlay", "Restart");
static LocalizedString SCREEN_ON("ScreenDebugOverlay", "Send On To Screen");
static LocalizedString SCREEN_OFF("ScreenDebugOverlay", "Send Off To Screen");
static LocalizedString RELOAD_OVERLAY_SCREENS(
    "ScreenDebugOverlay", "Reload Overlay Screens");
static LocalizedString TOGGLE_ERRORS("ScreenDebugOverlay", "Toggle Errors");
static LocalizedString SHOW_RECENT_ERRORS(
    "ScreenDebugOverlay", "Show Recent Errors");
static LocalizedString CLEAR_ERRORS("ScreenDebugOverlay", "Clear Errors");
static LocalizedString CONVERT_XML("ScreenDebugOverlay", "Convert XML");
static LocalizedString RELOAD_PREFS("ScreenDebugOverlay", "Reload Prefs");
static LocalizedString RELOAD_THEME_AND_TEXTURES(
    "ScreenDebugOverlay", "Reload Theme and Textures");
static LocalizedString WRITE_PROFILES("ScreenDebugOverlay", "Write Profiles");
static LocalizedString WRITE_PREFERENCES(
    "ScreenDebugOverlay", "Write Preferences");
static LocalizedString MENU_TIMER("ScreenDebugOverlay", "Menu Timer");
static LocalizedString FLUSH_LOG("ScreenDebugOverlay", "Flush Log");
static LocalizedString PULL_BACK_CAMERA(
    "ScreenDebugOverlay", "Pull Back Camera");
static LocalizedString VISUAL_DELAY_UP("ScreenDebugOverlay", "Visual Delay Up");
static LocalizedString VISUAL_DELAY_DOWN(
    "ScreenDebugOverlay", "Visual Delay Down");
static LocalizedString VOLUME_UP("ScreenDebugOverlay", "Volume Up");
static LocalizedString VOLUME_DOWN("ScreenDebugOverlay", "Volume Down");
static LocalizedString UPTIME("ScreenDebugOverlay", "Uptime");
static LocalizedString FORCE_CRASH("ScreenDebugOverlay", "Force Crash");
static LocalizedString SLOW("ScreenDebugOverlay", "Slow");
static LocalizedString CPU("ScreenDebugOverlay", "CPU");
static LocalizedString SONG("ScreenDebugOverlay", "Song");
static LocalizedString MACHINE("ScreenDebugOverlay", "Machine");
static LocalizedString SYNC_TEMPO("ScreenDebugOverlay", "Tempo");

class DebugLineAutoplay : public IDebugLine {
  virtual std::string GetDisplayTitle() {
    return AUTO_PLAY.GetValue() + " (+Shift = AI)";
  }
  virtual std::string GetDisplayValue() {
    PlayerController pc = GamePreferences::m_AutoPlay.Get();
    switch (pc) {
      case PC_HUMAN:
        return OFF.GetValue();
        break;
      case PC_AUTOPLAY:
        return ON.GetValue();
        break;
      case PC_CPU:
        return CPU.GetValue();
        break;
      default:
        WarnDebugOverlay(ssprintf(
            "invalid autoplay PlayerController %i; displaying off.", pc));
        return OFF.GetValue();
    }
  }
  virtual Type GetType() const { return IDebugLine::gameplay_only; }
  virtual bool IsEnabled() {
    PlayerController pc = GamePreferences::m_AutoPlay.Get();
    return IsValidPlayerControllerValue(pc) && pc != PC_HUMAN;
  }
  virtual void DoAndLog(std::string& sMessageOut) {
    if (GAMESTATE == nullptr) {
      WarnDebugOverlay("ignored autoplay toggle without GAMESTATE.");
      return;
    }

    PlayerNumber master = GAMESTATE->GetMasterPlayerNumber();
    if (!IsValidDebugPlayer(master) ||
        GAMESTATE->m_pPlayerState[master] == nullptr) {
      WarnDebugOverlay("ignored autoplay toggle without a valid master player.");
      return;
    }

    PlayerController pc = GAMESTATE->m_pPlayerState[master]->m_PlayerController;
    if (!IsValidPlayerControllerValue(pc)) {
      WarnDebugOverlay(ssprintf(
          "reset invalid player controller %i before autoplay toggle.", pc));
      pc = PC_HUMAN;
    }

    bool bHoldingShift =
        INPUTFILTER != nullptr &&
        (INPUTFILTER->IsBeingPressed(DeviceInput(DEVICE_KEYBOARD, KEY_LSHIFT)) ||
         INPUTFILTER->IsBeingPressed(DeviceInput(DEVICE_KEYBOARD, KEY_RSHIFT)));
    if (bHoldingShift) {
      pc = (pc == PC_CPU) ? PC_HUMAN : PC_CPU;
    } else {
      pc = (pc == PC_AUTOPLAY) ? PC_HUMAN : PC_AUTOPLAY;
    }
    GamePreferences::m_AutoPlay.Set(pc);
    FOREACH_HumanPlayer(p) {
      if (GAMESTATE->m_pPlayerState[p] != nullptr) {
        GAMESTATE->m_pPlayerState[p]->m_PlayerController =
            GamePreferences::m_AutoPlay;
      }
    }
    FOREACH_MultiPlayer(p) {
      if (GAMESTATE->m_pMultiPlayerState[p] != nullptr) {
        GAMESTATE->m_pMultiPlayerState[p]->m_PlayerController =
            GamePreferences::m_AutoPlay;
      }
    }

    IDebugLine::DoAndLog(sMessageOut);
  }
};

class DebugLineAssist : public IDebugLine {
  virtual std::string GetDisplayTitle() { return ASSIST.GetValue(); }
  virtual Type GetType() const { return gameplay_only; }
  virtual std::string GetDisplayValue() {
    if (GAMESTATE == nullptr) {
      return OFF.GetValue();
    }
    SongOptions so;
    so.m_bAssistClap = GAMESTATE->m_SongOptions.GetSong().m_bAssistClap;
    so.m_bAssistMetronome =
        GAMESTATE->m_SongOptions.GetSong().m_bAssistMetronome;
    if (so.m_bAssistClap || so.m_bAssistMetronome) {
      return so.GetLocalizedString();
    } else {
      return OFF.GetValue();
    }
  }
  virtual bool IsEnabled() {
    return GAMESTATE != nullptr &&
           (GAMESTATE->m_SongOptions.GetSong().m_bAssistClap ||
            GAMESTATE->m_SongOptions.GetSong().m_bAssistMetronome);
  }
  virtual void DoAndLog(std::string& sMessageOut) {
    if (GAMESTATE == nullptr) {
      WarnDebugOverlay("ignored assist toggle without GAMESTATE.");
      return;
    }
    bool bHoldingShift =
        INPUTFILTER != nullptr &&
        INPUTFILTER->IsBeingPressed(DeviceInput(DEVICE_KEYBOARD, KEY_LSHIFT));
    bool b;
    if (bHoldingShift) {
      b = !GAMESTATE->m_SongOptions.GetSong().m_bAssistMetronome;
    } else {
      b = !GAMESTATE->m_SongOptions.GetSong().m_bAssistClap;
    }
    if (bHoldingShift) {
      SO_GROUP_ASSIGN(
          GAMESTATE->m_SongOptions, ModsLevel_Preferred, m_bAssistMetronome, b);
    } else {
      SO_GROUP_ASSIGN(
          GAMESTATE->m_SongOptions, ModsLevel_Preferred, m_bAssistClap, b);
    }

    IDebugLine::DoAndLog(sMessageOut);
  }
};

class DebugLineAutosync : public IDebugLine {
  virtual std::string GetDisplayTitle() { return AUTOSYNC.GetValue(); }
  virtual std::string GetDisplayValue() {
    if (GAMESTATE == nullptr) {
      return OFF.GetValue();
    }
    AutosyncType type = GAMESTATE->m_SongOptions.GetSong().m_AutosyncType;
    switch (type) {
      case AutosyncType_Off:
        return OFF.GetValue();
        break;
      case AutosyncType_Song:
        return SONG.GetValue();
        break;
      case AutosyncType_Machine:
        return MACHINE.GetValue();
        break;
      case AutosyncType_Tempo:
        return SYNC_TEMPO.GetValue();
        break;
      default:
        WarnDebugOverlay(
            ssprintf("invalid autosync type %i; displaying off.", type));
        return OFF.GetValue();
    }
  }
  virtual Type GetType() const { return IDebugLine::gameplay_only; }
  virtual bool IsEnabled() {
    if (GAMESTATE == nullptr) {
      return false;
    }
    AutosyncType type = GAMESTATE->m_SongOptions.GetSong().m_AutosyncType;
    return IsValidAutosyncTypeValue(type) && type != AutosyncType_Off;
  }
  virtual void DoAndLog(std::string& sMessageOut) {
    if (GAMESTATE == nullptr) {
      WarnDebugOverlay("ignored autosync toggle without GAMESTATE.");
      return;
    }
    AutosyncType current = GAMESTATE->m_SongOptions.GetSong().m_AutosyncType;
    if (!IsValidAutosyncTypeValue(current)) {
      WarnDebugOverlay(ssprintf("reset invalid autosync type %i.", current));
      current = AutosyncType_Off;
    }
    int as = current + 1;
    bool bAllowSongAutosync = !GAMESTATE->IsCourseMode();
    if (!bAllowSongAutosync &&
        (as == AutosyncType_Song || as == AutosyncType_Tempo)) {
      as = AutosyncType_Machine;
    }
    wrap(as, NUM_AutosyncType);
    SO_GROUP_ASSIGN(
        GAMESTATE->m_SongOptions, ModsLevel_Song, m_AutosyncType,
        AutosyncType(as));
    if (MESSAGEMAN != nullptr) {
      MESSAGEMAN->Broadcast(Message_AutosyncChanged);
    }
    IDebugLine::DoAndLog(sMessageOut);
  }
};

class DebugLineCoinMode : public IDebugLine {
  virtual std::string GetDisplayTitle() { return COIN_MODE.GetValue(); }
  virtual std::string GetDisplayValue() {
    if (GAMESTATE == nullptr) {
      return std::string();
    }
    return CoinModeToString(GAMESTATE->GetCoinMode());
  }
  virtual bool IsEnabled() { return GAMESTATE != nullptr; }
  virtual void DoAndLog(std::string& sMessageOut) {
    if (GAMESTATE == nullptr) {
      WarnDebugOverlay("ignored coin mode toggle without GAMESTATE.");
      return;
    }
    if (GAMESTATE->GetCoinMode() == CoinMode_Home) {
      GamePreferences::m_CoinMode.Set(CoinMode_Free);
    } else if (
        GAMESTATE->GetCoinMode() == CoinMode_Free &&
        !GAMESTATE->IsEventMode()) {
      GamePreferences::m_CoinMode.Set(CoinMode_Pay);
    } else {
      GamePreferences::m_CoinMode.Set(CoinMode_Home);
    }
    if (SCREENMAN != nullptr) {
      SCREENMAN->RefreshCreditsMessages();
    }
    IDebugLine::DoAndLog(sMessageOut);
  }
};

class DebugLineSlow : public IDebugLine {
  virtual std::string GetDisplayTitle() { return SLOW.GetValue(); }
  virtual bool IsEnabled() { return g_bIsSlow; }
  virtual void DoAndLog(std::string& sMessageOut) {
    g_bIsSlow = !g_bIsSlow;
    SetSpeed();
    IDebugLine::DoAndLog(sMessageOut);
  }
};

class DebugLineHalt : public IDebugLine {
  virtual std::string GetDisplayTitle() { return HALT.GetValue(); }
  virtual bool IsEnabled() { return g_bIsHalt; }
  virtual void DoAndLog(std::string& sMessageOut) {
    g_bIsHalt = !g_bIsHalt;
    g_HaltTimer.Touch();
    SetSpeed();
    IDebugLine::DoAndLog(sMessageOut);
  }
};

class DebugLineLightsDebug : public IDebugLine {
  virtual std::string GetDisplayTitle() { return LIGHTS_DEBUG.GetValue(); }
  virtual bool IsEnabled() {
    return PREFSMAN != nullptr && PREFSMAN->m_bDebugLights.Get();
  }
  virtual void DoAndLog(std::string& sMessageOut) {
    if (PREFSMAN == nullptr) {
      WarnDebugOverlay("ignored lights debug toggle without PREFSMAN.");
      return;
    }
    PREFSMAN->m_bDebugLights.Set(!PREFSMAN->m_bDebugLights);
    IDebugLine::DoAndLog(sMessageOut);
  }
};

class DebugLineMonkeyInput : public IDebugLine {
  virtual std::string GetDisplayTitle() { return MONKEY_INPUT.GetValue(); }
  virtual bool IsEnabled() {
    return PREFSMAN != nullptr && PREFSMAN->m_bMonkeyInput.Get();
  }
  virtual void DoAndLog(std::string& sMessageOut) {
    if (PREFSMAN == nullptr) {
      WarnDebugOverlay("ignored monkey input toggle without PREFSMAN.");
      return;
    }
    PREFSMAN->m_bMonkeyInput.Set(!PREFSMAN->m_bMonkeyInput);
    IDebugLine::DoAndLog(sMessageOut);
  }
};

class DebugLineStats : public IDebugLine {
  virtual std::string GetDisplayTitle() { return RENDERING_STATS.GetValue(); }
  virtual bool IsEnabled() {
    return PREFSMAN != nullptr && PREFSMAN->m_bShowStats.Get();
  }
  virtual void DoAndLog(std::string& sMessageOut) {
    if (PREFSMAN == nullptr) {
      WarnDebugOverlay("ignored rendering stats toggle without PREFSMAN.");
      return;
    }
    PREFSMAN->m_bShowStats.Set(!PREFSMAN->m_bShowStats);
    IDebugLine::DoAndLog(sMessageOut);
  }
};

class DebugLineVsync : public IDebugLine {
  virtual std::string GetDisplayTitle() { return VSYNC.GetValue(); }
  virtual bool IsEnabled() {
    return PREFSMAN != nullptr && PREFSMAN->m_bVsync.Get();
  }
  virtual void DoAndLog(std::string& sMessageOut) {
    if (PREFSMAN == nullptr) {
      WarnDebugOverlay("ignored vsync toggle without PREFSMAN.");
      return;
    }
    PREFSMAN->m_bVsync.Set(!PREFSMAN->m_bVsync);
    StepMania::ApplyGraphicOptions();
    IDebugLine::DoAndLog(sMessageOut);
  }
};

class DebugLineAllowMultitexture : public IDebugLine {
  virtual std::string GetDisplayTitle() { return MULTITEXTURE.GetValue(); }
  virtual bool IsEnabled() {
    return PREFSMAN != nullptr && PREFSMAN->m_bAllowMultitexture.Get();
  }
  virtual void DoAndLog(std::string& sMessageOut) {
    if (PREFSMAN == nullptr) {
      WarnDebugOverlay("ignored multitexture toggle without PREFSMAN.");
      return;
    }
    PREFSMAN->m_bAllowMultitexture.Set(!PREFSMAN->m_bAllowMultitexture);
    IDebugLine::DoAndLog(sMessageOut);
  }
};

class DebugLineShowMasks : public IDebugLine {
  virtual std::string GetDisplayTitle() { return SCREEN_SHOW_MASKS.GetValue(); }
  virtual bool IsEnabled() {
    Preference<bool>* pref = GetPref();
    return pref != nullptr && pref->Get();
  }
  virtual std::string GetPageName() const { return "Theme"; }
  virtual void DoAndLog(std::string& sMessageOut) {
    Preference<bool>* pref = GetPref();
    if (pref == nullptr) {
      return;
    }
    pref->Set(!pref->Get());
    IDebugLine::DoAndLog(sMessageOut);
  }

  Preference<bool>* GetPref() {
    return GetDebugPreference<bool>("ShowMasks");
  }
};

static ProfileSlot g_ProfileSlot = ProfileSlot_Machine;
static bool IsSelectProfilePersistent() {
  if (PROFILEMAN == nullptr || !IsValidDebugProfileSlot(g_ProfileSlot)) {
    return false;
  }
  if (g_ProfileSlot == ProfileSlot_Machine) {
    return PROFILEMAN->GetMachineProfile() != nullptr;
  }
  PlayerNumber pn = PlayerNumberFromProfileSlot(g_ProfileSlot);
  return IsValidDebugPlayer(pn) && PROFILEMAN->IsPersistentProfile(pn);
}

class DebugLineProfileSlot : public IDebugLine {
  virtual std::string GetDisplayTitle() { return PROFILE.GetValue(); }
  virtual std::string GetDisplayValue() {
    return GetProfileSlotDisplayName(g_ProfileSlot);
  }
  virtual bool IsEnabled() { return IsSelectProfilePersistent(); }
  virtual std::string GetPageName() const { return "Profiles"; }
  virtual void DoAndLog(std::string& sMessageOut) {
    enum_add(g_ProfileSlot, +1);
    if (g_ProfileSlot == NUM_ProfileSlot) {
      g_ProfileSlot = ProfileSlot_Player1;
    }

    IDebugLine::DoAndLog(sMessageOut);
  }
};

class DebugLineClearProfileStats : public IDebugLine {
  virtual std::string GetDisplayTitle() {
    return CLEAR_PROFILE_STATS.GetValue();
  }
  virtual std::string GetDisplayValue() { return std::string(); }
  virtual bool IsEnabled() { return IsSelectProfilePersistent(); }
  virtual std::string GetPageName() const { return "Profiles"; }
  virtual void DoAndLog(std::string& sMessageOut) {
    if (PROFILEMAN == nullptr || !IsValidDebugProfileSlot(g_ProfileSlot)) {
      WarnDebugOverlay("ignored clear profile stats with invalid profile state.");
      return;
    }
    Profile* pProfile = PROFILEMAN->GetProfile(g_ProfileSlot);
    if (pProfile == nullptr) {
      WarnDebugOverlay("ignored clear profile stats for a missing profile.");
      return;
    }
    pProfile->ClearStats();
    IDebugLine::DoAndLog(sMessageOut);
  }
};

static HighScore MakeRandomHighScore(float fPercentDP) {
  HighScore hs;
  hs.SetName("FAKE");
  Grade g = (Grade)SCALE(RandomInt(6), 0, 4, Grade_Tier01, Grade_Tier06);
  if (g == Grade_Tier06) {
    g = Grade_Failed;
  }
  hs.SetGrade(g);
  hs.SetScore(RandomInt(100 * 1000));
  hs.SetPercentDP(fPercentDP);
  hs.SetAliveSeconds(randomf(30.0f, 100.0f));
  PlayerOptions po;
  po.ChooseRandomModifiers();
  hs.SetModifiers(po.GetString());
  hs.SetDateTime(DateTime::GetNowDateTime());
  hs.SetPlayerGuid(Profile::MakeGuid());
  hs.SetMachineGuid(Profile::MakeGuid());
  hs.SetProductID(RandomInt(10));
  FOREACH_ENUM(TapNoteScore, tns)
  hs.SetTapNoteScore(tns, RandomInt(100));
  FOREACH_ENUM(HoldNoteScore, hns)
  hs.SetHoldNoteScore(hns, RandomInt(100));
  RadarValues rv;
  FOREACH_ENUM(RadarCategory, rc) { rv[rc] = randomf(0, 1); }
  hs.SetRadarValues(rv);

  return hs;
}

static void FillProfileStats(Profile* pProfile) {
  if (pProfile == nullptr || PREFSMAN == nullptr || SONGMAN == nullptr) {
    WarnDebugOverlay("ignored fill profile stats because runtime is incomplete.");
    return;
  }

  pProfile->InitSongScores();
  pProfile->InitCourseScores();

  static int s_iCount = 0;
  // Choose a percent for all scores. This is useful for testing unlocks
  // where some elements are unlocked at a certain percent complete.
  float fPercentDP = s_iCount ? randomf(0.6f, 1.0f) : 1.0f;
  s_iCount = (s_iCount + 1) % 2;

  int iCount = pProfile->IsMachine()
                   ? PREFSMAN->m_iMaxHighScoresPerListForMachine.Get()
                   : PREFSMAN->m_iMaxHighScoresPerListForPlayer.Get();

  std::vector<Song*> vpAllSongs = SONGMAN->GetAllSongs();
  for (const Song* pSong : vpAllSongs) {
    if (pSong == nullptr) {
      continue;
    }
    std::vector<Steps*> vpAllSteps = pSong->GetAllSteps();
    for (const Steps* pSteps : vpAllSteps) {
      if (pSteps == nullptr) {
        continue;
      }
      if (rand() % 5) {
        pProfile->IncrementStepsPlayCount(pSong, pSteps);
      }
      for (int i = 0; i < iCount; i++) {
        int iIndex = 0;
        pProfile->AddStepsHighScore(
            pSong, pSteps, MakeRandomHighScore(fPercentDP), iIndex);
      }
    }
  }

  std::vector<Course*> vpAllCourses;
  SONGMAN->GetAllCourses(vpAllCourses, true);
  for (const Course* pCourse : vpAllCourses) {
    if (pCourse == nullptr) {
      continue;
    }
    std::vector<Trail*> vpAllTrails;
    pCourse->GetAllTrails(vpAllTrails);
    for (const Trail* pTrail : vpAllTrails) {
      if (pTrail == nullptr) {
        continue;
      }
      if (rand() % 5) {
        pProfile->IncrementCoursePlayCount(pCourse, pTrail);
      }
      for (int i = 0; i < iCount; i++) {
        int iIndex = 0;
        pProfile->AddCourseHighScore(
            pCourse, pTrail, MakeRandomHighScore(fPercentDP), iIndex);
      }
    }
  }

  if (SCREENMAN != nullptr) {
    SCREENMAN->ZeroNextUpdate();
  }
}

class DebugLineFillProfileStats : public IDebugLine {
  virtual std::string GetDisplayTitle() {
    return FILL_PROFILE_STATS.GetValue();
  }
  virtual std::string GetDisplayValue() { return std::string(); }
  virtual bool IsEnabled() { return IsSelectProfilePersistent(); }
  virtual std::string GetPageName() const { return "Profiles"; }
  virtual void DoAndLog(std::string& sMessageOut) {
    if (PROFILEMAN == nullptr || !IsValidDebugProfileSlot(g_ProfileSlot)) {
      WarnDebugOverlay("ignored fill profile stats with invalid profile state.");
      return;
    }
    Profile* pProfile = PROFILEMAN->GetProfile(g_ProfileSlot);
    if (pProfile == nullptr) {
      WarnDebugOverlay("ignored fill profile stats for a missing profile.");
      return;
    }
    FillProfileStats(pProfile);
    IDebugLine::DoAndLog(sMessageOut);
  }
};

class DebugLineSendNotesEnded : public IDebugLine {
  virtual std::string GetDisplayTitle() { return SEND_NOTES_ENDED.GetValue(); }
  virtual std::string GetDisplayValue() { return std::string(); }
  virtual bool IsEnabled() { return true; }
  virtual void DoAndLog(std::string& sMessageOut) {
    if (SCREENMAN == nullptr) {
      WarnDebugOverlay("ignored send notes ended without SCREENMAN.");
      return;
    }
    SCREENMAN->PostMessageToTopScreen(SM_NotesEnded, 0);
    IDebugLine::DoAndLog(sMessageOut);
  }
};

class DebugLineResetKeyMapping : public IDebugLine {
  virtual std::string GetDisplayTitle() { return RESET_KEY_MAP.GetValue(); }
  virtual std::string GetDisplayValue() { return std::string(); }
  virtual bool IsEnabled() { return INPUTMAPPER != nullptr; }
  virtual void DoAndLog(std::string& sMessageOut) {
    if (INPUTMAPPER == nullptr) {
      WarnDebugOverlay("ignored key mapping reset without INPUTMAPPER.");
      return;
    }
    INPUTMAPPER->ResetMappingsToDefault();
    INPUTMAPPER->SaveMappingsToDisk();
    IDebugLine::DoAndLog(sMessageOut);
  }
};

class DebugLineMuteActions : public IDebugLine {
  virtual std::string GetDisplayTitle() { return MUTE_ACTIONS.GetValue(); }
  virtual std::string GetDisplayValue() { return std::string(); }
  virtual bool IsEnabled() {
    return PREFSMAN != nullptr && PREFSMAN->m_MuteActions;
  }
  virtual void DoAndLog(std::string& sMessageOut) {
    if (PREFSMAN == nullptr) {
      WarnDebugOverlay("ignored mute actions toggle without PREFSMAN.");
      return;
    }
    PREFSMAN->m_MuteActions.Set(!PREFSMAN->m_MuteActions);
    if (SCREENMAN != nullptr) {
      SCREENMAN->SystemMessage(
          PREFSMAN->m_MuteActions ? MUTE_ACTIONS_ON.GetValue()
                                  : MUTE_ACTIONS_OFF.GetValue());
    }
    IDebugLine::DoAndLog(sMessageOut);
  }
};

class DebugLineReloadCurrentScreen : public IDebugLine {
  virtual std::string GetDisplayTitle() { return RELOAD.GetValue(); }
  virtual std::string GetDisplayValue() {
    Screen* top = GetTopScreenSafe();
    return top != nullptr ? top->GetName() : std::string();
  }
  virtual bool IsEnabled() { return true; }
  virtual std::string GetPageName() const { return "Theme"; }
  virtual void DoAndLog(std::string& sMessageOut) {
    Screen* root = SCREENMAN != nullptr ? SCREENMAN->GetScreen(0) : nullptr;
    if (root == nullptr) {
      WarnDebugOverlay("ignored current screen reload without a root screen.");
      return;
    }
    std::string sScreenName = root->GetName();
    SCREENMAN->PopAllScreens();

    if (SOUND != nullptr) {
      SOUND->StopMusic();
    }
    // StepMania::ResetGame();

    SCREENMAN->SetNewScreen(sScreenName);
    IDebugLine::DoAndLog(sMessageOut);
    sMessageOut = "";
  }
};

class DebugLineRestartCurrentScreen : public IDebugLine {
  virtual std::string GetDisplayTitle() { return RESTART.GetValue(); }
  virtual std::string GetDisplayValue() {
    Screen* top = GetTopScreenSafe();
    return top != nullptr ? top->GetName() : std::string();
  }
  virtual bool IsEnabled() { return true; }
  virtual bool ForceOffAfterUse() const { return true; }
  virtual std::string GetPageName() const { return "Theme"; }
  virtual void DoAndLog(std::string& sMessageOut) {
    Screen* top = GetTopScreenSafe();
    if (top == nullptr) {
      WarnDebugOverlay("ignored current screen restart without a top screen.");
      return;
    }
    top->BeginScreen();
    IDebugLine::DoAndLog(sMessageOut);
    sMessageOut = "";
  }
};

class DebugLineCurrentScreenOn : public IDebugLine {
  virtual std::string GetDisplayTitle() { return SCREEN_ON.GetValue(); }
  virtual std::string GetDisplayValue() {
    Screen* top = GetTopScreenSafe();
    return top != nullptr ? top->GetName() : std::string();
  }
  virtual bool IsEnabled() { return true; }
  virtual bool ForceOffAfterUse() const { return true; }
  virtual std::string GetPageName() const { return "Theme"; }
  virtual void DoAndLog(std::string& sMessageOut) {
    Screen* top = GetTopScreenSafe();
    if (top == nullptr) {
      WarnDebugOverlay("ignored current screen On command without a top screen.");
      return;
    }
    top->PlayCommand("On");
    IDebugLine::DoAndLog(sMessageOut);
    sMessageOut = "";
  }
};

class DebugLineCurrentScreenOff : public IDebugLine {
  virtual std::string GetDisplayTitle() { return SCREEN_OFF.GetValue(); }
  virtual std::string GetDisplayValue() {
    Screen* top = GetTopScreenSafe();
    return top != nullptr ? top->GetName() : std::string();
  }
  virtual bool IsEnabled() { return true; }
  virtual bool ForceOffAfterUse() const { return true; }
  virtual std::string GetPageName() const { return "Theme"; }
  virtual void DoAndLog(std::string& sMessageOut) {
    Screen* top = GetTopScreenSafe();
    if (top == nullptr) {
      WarnDebugOverlay("ignored current screen Off command without a top screen.");
      return;
    }
    top->PlayCommand("Off");
    IDebugLine::DoAndLog(sMessageOut);
    sMessageOut = "";
  }
};

class DebugLineReloadTheme : public IDebugLine {
  virtual std::string GetDisplayTitle() {
    return RELOAD_THEME_AND_TEXTURES.GetValue();
  }
  virtual std::string GetDisplayValue() { return std::string(); }
  virtual bool IsEnabled() { return true; }
  virtual bool RefreshAfterUse() const { return false; }
  virtual std::string GetPageName() const { return "Theme"; }
  virtual void DoAndLog(std::string& sMessageOut) {
    if (THEME != nullptr) {
      THEME->ReloadMetrics();
    }
    if (TEXTUREMAN != nullptr) {
      TEXTUREMAN->ReloadAll();
    }
    if (NOTESKIN != nullptr && GAMESTATE != nullptr) {
      NOTESKIN->RefreshNoteSkinData(GAMESTATE->m_pCurGame, true);
    }
    CodeDetector::RefreshCacheItems();
    // HACK: Don't update text below. Return immediately because this screen
    // was just destroyed as part of the theme reload.
    IDebugLine::DoAndLog(sMessageOut);
  }
};

class DebugLineReloadOverlayScreens : public IDebugLine {
  virtual std::string GetDisplayTitle() {
    return RELOAD_OVERLAY_SCREENS.GetValue();
  }
  virtual std::string GetDisplayValue() { return std::string(); }
  virtual bool IsEnabled() { return true; }
  virtual bool RefreshAfterUse() const { return false; }
  virtual std::string GetPageName() const { return "Theme"; }
  virtual void DoAndLog(std::string& sMessageOut) {
    if (SCREENMAN == nullptr) {
      WarnDebugOverlay("ignored overlay screen reload without SCREENMAN.");
      return;
    }
    SCREENMAN->ReloadOverlayScreensAfterInputFinishes();
    IDebugLine::DoAndLog(sMessageOut);
  }
};

class DebugLineToggleErrors : public IDebugLine {
  virtual std::string GetDisplayTitle() { return TOGGLE_ERRORS.GetValue(); }
  virtual std::string GetDisplayValue() { return std::string(); }
  virtual bool IsEnabled() {
    return PREFSMAN != nullptr && PREFSMAN->m_show_theme_errors;
  }
  virtual std::string GetPageName() const { return "Theme"; }
  virtual void DoAndLog(std::string& sMessageOut) {
    if (PREFSMAN == nullptr) {
      WarnDebugOverlay("ignored theme error toggle without PREFSMAN.");
      return;
    }
    PREFSMAN->m_show_theme_errors.Set(!PREFSMAN->m_show_theme_errors);
    IDebugLine::DoAndLog(sMessageOut);
  }
};

class DebugLineShowRecentErrors : public IDebugLine {
  virtual std::string GetDisplayTitle() {
    return SHOW_RECENT_ERRORS.GetValue();
  }
  virtual std::string GetDisplayValue() { return std::string(); }
  virtual bool IsEnabled() { return MESSAGEMAN != nullptr; }
  virtual std::string GetPageName() const { return "Theme"; }
  virtual void DoAndLog(std::string& sMessageOut) {
    if (MESSAGEMAN == nullptr) {
      WarnDebugOverlay("ignored recent errors toggle without MESSAGEMAN.");
      return;
    }
    Message msg("ToggleScriptError");
    MESSAGEMAN->Broadcast(msg);
    IDebugLine::DoAndLog(sMessageOut);
  }
};

class DebugLineClearErrors : public IDebugLine {
  virtual std::string GetDisplayTitle() { return CLEAR_ERRORS.GetValue(); }
  virtual std::string GetDisplayValue() { return std::string(); }
  virtual bool IsEnabled() { return MESSAGEMAN != nullptr; }
  virtual std::string GetPageName() const { return "Theme"; }
  virtual void DoAndLog(std::string& sMessageOut) {
    if (MESSAGEMAN == nullptr) {
      WarnDebugOverlay("ignored clear errors without MESSAGEMAN.");
      return;
    }
    Message msg("ClearScriptError");
    MESSAGEMAN->Broadcast(msg);
    IDebugLine::DoAndLog(sMessageOut);
  }
};

class DebugLineConvertXML : public IDebugLine {
  virtual std::string GetDisplayTitle() { return CONVERT_XML.GetValue(); }
  virtual std::string GetDisplayValue() { return std::string(); }
  virtual bool IsEnabled() {
    return GAMESTATE != nullptr && GAMESTATE->m_pCurSong != nullptr;
  }
  virtual std::string GetPageName() const { return "Theme"; }
  virtual void DoAndLog(std::string& sMessageOut) {
    if (GAMESTATE == nullptr) {
      WarnDebugOverlay("ignored XML conversion without GAMESTATE.");
      return;
    }
    Song* cur_song = GAMESTATE->m_pCurSong;
    if (cur_song) {
      convert_xmls_in_dir(cur_song->GetSongDir() + "/");
      IDebugLine::DoAndLog(sMessageOut);
    }
  }
};

class DebugLineWriteProfiles : public IDebugLine {
  virtual std::string GetDisplayTitle() { return WRITE_PROFILES.GetValue(); }
  virtual std::string GetDisplayValue() { return std::string(); }
  virtual bool IsEnabled() { return IsSelectProfilePersistent(); }
  virtual std::string GetPageName() const { return "Profiles"; }
  virtual void DoAndLog(std::string& sMessageOut) {
    if (GAMESTATE == nullptr || PROFILEMAN == nullptr ||
        !IsValidDebugProfileSlot(g_ProfileSlot)) {
      WarnDebugOverlay("ignored profile write because runtime is incomplete.");
      return;
    }
    // Also save bookkeeping and profile info for debugging
    // so we don't have to play through a whole song to get new output.
    if (g_ProfileSlot == ProfileSlot_Machine) {
      GAMESTATE->SaveLocalData();
    } else {
      PlayerNumber pn = PlayerNumberFromProfileSlot(g_ProfileSlot);
      if (!IsValidDebugPlayer(pn) ||
          !PROFILEMAN->IsPersistentProfile(pn)) {
        WarnDebugOverlay("ignored profile write for an invalid player profile.");
        return;
      }
      GAMESTATE->SaveCurrentSettingsToProfile(pn);
      GAMESTATE->SavePlayerProfile(pn);
    }
    IDebugLine::DoAndLog(sMessageOut);
  }
};

class DebugLineWritePreferences : public IDebugLine {
  virtual std::string GetDisplayTitle() { return WRITE_PREFERENCES.GetValue(); }
  virtual std::string GetDisplayValue() { return std::string(); }
  virtual bool IsEnabled() { return PREFSMAN != nullptr; }
  virtual void DoAndLog(std::string& sMessageOut) {
    if (PREFSMAN == nullptr) {
      WarnDebugOverlay("ignored preference write without PREFSMAN.");
      return;
    }
    PREFSMAN->SavePrefsToDisk();
    IDebugLine::DoAndLog(sMessageOut);
  }
};

class DebugLineReloadPreferences : public IDebugLine {
  virtual std::string GetDisplayTitle() { return RELOAD_PREFS.GetValue(); }
  virtual std::string GetDisplayValue() { return std::string(); }
  virtual bool IsEnabled() { return PREFSMAN != nullptr; }
  virtual std::string GetPageName() const { return "Profiles"; }
  virtual void DoAndLog(std::string& sMessageOut) {
    if (PREFSMAN == nullptr) {
      WarnDebugOverlay("ignored preference reload without PREFSMAN.");
      return;
    }
    PREFSMAN->ReadPrefsFromDisk();
    IDebugLine::DoAndLog(sMessageOut);
  }
};

class DebugLineMenuTimer : public IDebugLine {
  virtual std::string GetDisplayTitle() { return MENU_TIMER.GetValue(); }
  virtual std::string GetDisplayValue() { return std::string(); }
  virtual bool IsEnabled() {
    return PREFSMAN != nullptr && PREFSMAN->m_bMenuTimer.Get();
  }
  virtual void DoAndLog(std::string& sMessageOut) {
    if (PREFSMAN == nullptr) {
      WarnDebugOverlay("ignored menu timer toggle without PREFSMAN.");
      return;
    }
    PREFSMAN->m_bMenuTimer.Set(!PREFSMAN->m_bMenuTimer);
    IDebugLine::DoAndLog(sMessageOut);
  }
};

class DebugLineFlushLog : public IDebugLine {
  virtual std::string GetDisplayTitle() { return FLUSH_LOG.GetValue(); }
  virtual std::string GetDisplayValue() { return std::string(); }
  virtual bool IsEnabled() { return LOG != nullptr; }
  virtual void DoAndLog(std::string& sMessageOut) {
    if (LOG == nullptr) {
      return;
    }
    LOG->Flush();
    IDebugLine::DoAndLog(sMessageOut);
  }
};

class DebugLinePullBackCamera : public IDebugLine {
  virtual std::string GetDisplayTitle() { return PULL_BACK_CAMERA.GetValue(); }
  virtual std::string GetDisplayValue() { return std::string(); }
  virtual bool IsEnabled() {
    return IsFinite(g_fImageScaleDestination) &&
           g_fImageScaleDestination != 1.0f;
  }
  virtual void DoAndLog(std::string& sMessageOut) {
    if (!IsFinite(g_fImageScaleDestination)) {
      g_fImageScaleDestination = 1.0f;
    }
    if (g_fImageScaleDestination == 1) {
      g_fImageScaleDestination = 0.5f;
    } else {
      g_fImageScaleDestination = 1;
    }
    IDebugLine::DoAndLog(sMessageOut);
  }
};

class DebugLineVolumeUp : public IDebugLine {
  virtual std::string GetDisplayTitle() { return VOLUME_UP.GetValue(); }
  virtual std::string GetDisplayValue() {
    Preference<float>* pref = GetPref();
    return pref != nullptr ? ssprintf("%.0f%%", pref->Get() * 100)
                           : std::string();
  }
  virtual bool IsEnabled() { return GetPref() != nullptr; }
  virtual void DoAndLog(std::string& sMessageOut) {
    ChangeVolume(+0.1f);
    IDebugLine::DoAndLog(sMessageOut);
  }
  Preference<float>* GetPref() {
    return GetDebugPreference<float>("SoundVolume");
  }
};

class DebugLineVolumeDown : public IDebugLine {
  virtual std::string GetDisplayTitle() { return VOLUME_DOWN.GetValue(); }
  virtual std::string GetDisplayValue() { return std::string(); }
  virtual bool IsEnabled() { return GetPref() != nullptr; }
  virtual void DoAndLog(std::string& sMessageOut) {
    ChangeVolume(-0.1f);
    IDebugLine::DoAndLog(sMessageOut);
    Preference<float>* pref = GetPref();
    if (pref != nullptr) {
      sMessageOut += " - " + ssprintf("%.0f%%", pref->Get() * 100);
    }
  }
  Preference<float>* GetPref() {
    return GetDebugPreference<float>("SoundVolume");
  }
};

class DebugLineVisualDelayUp : public IDebugLine {
  virtual std::string GetDisplayTitle() { return VISUAL_DELAY_UP.GetValue(); }
  virtual std::string GetDisplayValue() {
    Preference<float>* pref = GetPref();
    return pref != nullptr ? ssprintf("%.03f", pref->Get()) : std::string();
  }
  virtual bool IsEnabled() { return GetPref() != nullptr; }
  virtual void DoAndLog(std::string& sMessageOut) {
    ChangeVisualDelay(+0.001f);
    IDebugLine::DoAndLog(sMessageOut);
  }
  Preference<float>* GetPref() {
    return GetDebugPreference<float>("VisualDelaySeconds");
  }
};

class DebugLineVisualDelayDown : public IDebugLine {
  virtual std::string GetDisplayTitle() { return VISUAL_DELAY_DOWN.GetValue(); }
  virtual std::string GetDisplayValue() { return std::string(); }
  virtual bool IsEnabled() { return GetPref() != nullptr; }
  virtual void DoAndLog(std::string& sMessageOut) {
    ChangeVisualDelay(-0.001f);
    IDebugLine::DoAndLog(sMessageOut);
    Preference<float>* pref = GetPref();
    if (pref != nullptr) {
      sMessageOut += " - " + ssprintf("%.03f", pref->Get());
    }
  }
  Preference<float>* GetPref() {
    return GetDebugPreference<float>("VisualDelaySeconds");
  }
};

class DebugLineForceCrash : public IDebugLine {
  virtual std::string GetDisplayTitle() { return FORCE_CRASH.GetValue(); }
  virtual std::string GetDisplayValue() { return std::string(); }
  virtual bool IsEnabled() { return false; }
  virtual void DoAndLog(std::string& sMessageOut) {
    WarnDebugOverlay("ignored disabled force crash debug line.");
    IDebugLine::DoAndLog(sMessageOut);
  }
};

class DebugLineUptime : public IDebugLine {
  virtual std::string GetDisplayTitle() { return UPTIME.GetValue(); }
  virtual std::string GetDisplayValue() {
    return MicrosecondsToMMSSMsMsMs(RageTimer::GetTimeSinceStartMicroseconds());
  }
  virtual bool IsEnabled() { return false; }
  virtual void DoAndLog(std::string& sMessageOut) {}
};

/* If you comment out a DECLARE_ONE at the end of the file, it will remove that
 * debug menu line, but it will also change the arrangement of keys to debug
 * menu options. We need a way to generate fake classes in order to preserve the
 * Debug Menu key mappings, so we can instead swap in one of these fake classes
 * for the class we want to remove. DEFINE_FAKE_CLASS1 handles menu options
 * which need to return a page title, and DEFINE_FAKE_CLASS2 handles the normal
 * (F5) menu options. */
#define DEFINE_FAKE_CLASS1(className, pageName)                    \
  class className : public IDebugLine {                            \
   public:                                                         \
    virtual std::string GetDisplayTitle() { return "(disabled)"; } \
    virtual std::string GetDisplayValue() { return "(disabled)"; } \
    virtual bool IsEnabled() { return false; }                     \
    virtual std::string GetPageName() const { return pageName; }   \
    virtual void DoAndLog(std::string& sMessageOut) {              \
      sMessageOut = "(disabled)";                                  \
    }                                                              \
  };

#define DEFINE_FAKE_CLASS2(className)                              \
  class className : public IDebugLine {                            \
   public:                                                         \
    virtual std::string GetDisplayTitle() { return "(disabled)"; } \
    virtual bool IsEnabled() { return false; }                     \
    virtual void DoAndLog(std::string& sMessageOut) {              \
      sMessageOut = "(disabled)";                                  \
    }                                                              \
  };

DEFINE_FAKE_CLASS1(FakeClearProfileStats, "Profiles")
DEFINE_FAKE_CLASS1(FakeFillProfileStats, "Profiles")
DEFINE_FAKE_CLASS2(FakeDebugLine1)
DEFINE_FAKE_CLASS2(FakeDebugLine2)

#define DECLARE_ONE(x) static x g_##x
DECLARE_ONE(DebugLineAutoplay);
DECLARE_ONE(DebugLineAssist);
DECLARE_ONE(DebugLineAutosync);
DECLARE_ONE(DebugLineCoinMode);
DECLARE_ONE(DebugLineSlow);
DECLARE_ONE(DebugLineHalt);
DECLARE_ONE(DebugLineLightsDebug);
// DECLARE_ONE( DebugLineMonkeyInput );
DECLARE_ONE(FakeDebugLine1);  // monkey input
DECLARE_ONE(DebugLineStats);
DECLARE_ONE(DebugLineVsync);
DECLARE_ONE(DebugLineAllowMultitexture);
DECLARE_ONE(DebugLineShowMasks);
DECLARE_ONE(DebugLineProfileSlot);
// DECLARE_ONE( DebugLineClearProfileStats );
DECLARE_ONE(FakeClearProfileStats);  // clear profile stats
// DECLARE_ONE( DebugLineFillProfileStats );
DECLARE_ONE(FakeFillProfileStats);  // fill profile stats
DECLARE_ONE(DebugLineSendNotesEnded);
DECLARE_ONE(DebugLineReloadCurrentScreen);
DECLARE_ONE(DebugLineRestartCurrentScreen);
DECLARE_ONE(DebugLineCurrentScreenOn);
DECLARE_ONE(DebugLineCurrentScreenOff);
DECLARE_ONE(DebugLineReloadTheme);
DECLARE_ONE(DebugLineReloadOverlayScreens);
DECLARE_ONE(DebugLineToggleErrors);
DECLARE_ONE(DebugLineShowRecentErrors);
DECLARE_ONE(DebugLineClearErrors);
DECLARE_ONE(DebugLineConvertXML);
DECLARE_ONE(DebugLineWriteProfiles);
DECLARE_ONE(DebugLineWritePreferences);
DECLARE_ONE(DebugLineReloadPreferences);
DECLARE_ONE(DebugLineMenuTimer);
DECLARE_ONE(DebugLineFlushLog);
DECLARE_ONE(DebugLinePullBackCamera);
DECLARE_ONE(DebugLineVolumeDown);
DECLARE_ONE(DebugLineVolumeUp);
DECLARE_ONE(DebugLineVisualDelayDown);
DECLARE_ONE(DebugLineVisualDelayUp);
// DECLARE_ONE( DebugLineForceCrash );
DECLARE_ONE(FakeDebugLine2);  // force crash
DECLARE_ONE(DebugLineUptime);
DECLARE_ONE(DebugLineResetKeyMapping);
DECLARE_ONE(DebugLineMuteActions);

/*
 * (c) 2001-2005 Chris Danford, Glenn Maynard
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
