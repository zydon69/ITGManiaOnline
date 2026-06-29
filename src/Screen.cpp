#include "Screen.h"

#include <algorithm>
#include <cmath>
#include <ctime>
#include <map>
#include <set>
#include <string>
#include <vector>

#include "ActorFrame.h"
#include "ActorUtil.h"
#include "EnumHelper.h"
#include "GameInput.h"
#include "IniFile.h"
#include "InputEventPlus.h"
#include "InputFilter.h"
#include "InputMapper.h"
#include "LightsManager.h"
#include "LuaManager.h"
#include "MessageManager.h"
#include "PrefsManager.h"
#include "RageInputDevice.h"
#include "RageLog.h"
#include "RageThreads.h"
#include "RageUtil.h"
#include "ScreenManager.h"
#include "ScreenMessage.h"
#include "ThemeManager.h"
#include "global.h"

namespace {
bool HasThemeRuntime() {
  return THEME != nullptr && THEME->IsThemeLoaded() && LUA != nullptr;
}

void WarnScreen(const std::string& screenName, const std::string& message) {
  if (LOG != nullptr) {
    LOG->Warn("Screen[%s]: %s", screenName.c_str(), message.c_str());
  }
}

std::string GetThemeMetricString(
    const std::string& screenName, const std::string& metric) {
  if (!HasThemeRuntime() || screenName.empty()) {
    return "";
  }
  return THEME->GetMetric(screenName, metric);
}

float SanitizeNonNegativeSeconds(float seconds) {
  return std::isfinite(seconds) && seconds > 0.0f ? seconds : 0.0f;
}

bool IsUsableScreenTarget(const std::string& screenName) {
  return !screenName.empty() && SCREENMAN != nullptr && THEME != nullptr &&
         THEME->IsThemeLoaded() && SCREENMAN->IsScreenNameValid(screenName);
}

bool GetLoadedBoolMetric(const ThemeMetric<bool>& metric, bool fallback) {
  return metric.IsLoaded() ? metric.GetValue() : fallback;
}

float GetLoadedFloatMetric(const ThemeMetric<float>& metric, float fallback) {
  if (!metric.IsLoaded()) {
    return fallback;
  }
  const float value = metric.GetValue();
  return std::isfinite(value) ? value : fallback;
}

bool OnlineVerboseLogsEnabledFromThemePrefs() {
  static time_t lastRead = 0;
  static bool cached = false;

  const time_t now = time(nullptr);
  if (now == lastRead) {
    return cached;
  }

  lastRead = now;
  cached = false;

  if (PREFSMAN == nullptr) {
    return false;
  }

  IniFile ini;
  if (!ini.ReadFile("Save/ThemePrefs.ini")) {
    return false;
  }

  bool enabled = false;
  if (!ini.GetValue(
          PREFSMAN->m_sTheme,
          "ITGOnlineGameplayLayoutLogs",
          enabled)) {
    return false;
  }

  cached = enabled;
  return cached;
}

void TraceOnlineScreenMessage(
    const std::string& event, const std::string& screenName, ScreenMessage SM,
    bool running, size_t queued) {
  if (LOG == nullptr || !OnlineVerboseLogsEnabledFromThemePrefs()) {
    return;
  }
  LOG->Trace(
      "ITG Online ScreenTrace: %s screen=%s message=%s running=%d queued=%zu",
      event.c_str(),
      screenName.c_str(),
      ScreenMessageHelpers::ScreenMessageToString(SM).c_str(),
      running ? 1 : 0,
      queued);
  LOG->Flush();
}

void TraceOnlineScreenTransition(
    const std::string& event, const std::string& fromScreen,
    const std::string& toScreen, ScreenMessage SM) {
  if (LOG == nullptr || !OnlineVerboseLogsEnabledFromThemePrefs()) {
    return;
  }
  LOG->Trace(
      "ITG Online ScreenTrace: %s from=%s to=%s message=%s",
      event.c_str(),
      fromScreen.c_str(),
      toScreen.c_str(),
      ScreenMessageHelpers::ScreenMessageToString(SM).c_str());
  LOG->Flush();
}

void TraceOnlineScreenPop(
    const std::string& screenName, ScreenMessage SM) {
  if (LOG == nullptr || !OnlineVerboseLogsEnabledFromThemePrefs()) {
    return;
  }
  LOG->Trace(
      "ITG Online ScreenTrace: handle_screen_message_pop_stacked screen=%s "
      "message=%s",
      screenName.c_str(),
      ScreenMessageHelpers::ScreenMessageToString(SM).c_str());
  LOG->Flush();
}

void BroadcastMouseMessage(MessageID message) {
  if (MESSAGEMAN != nullptr) {
    MESSAGEMAN->Broadcast(message);
  }
}
}  // namespace

static const char* ScreenTypeNames[] = {
    "Attract",
    "GameMenu",
    "Gameplay",
    "SystemMenu",
};
XToString(ScreenType);
LuaXType(ScreenType);

static bool ShouldTraceOnlineScreen(const std::string& screenName) {
  if (!OnlineVerboseLogsEnabledFromThemePrefs()) {
    return false;
  }
  return screenName.find("Online") != std::string::npos ||
         screenName == "ScreenSelectMusic" ||
         screenName == "ScreenPlayerOptions" ||
         screenName == "ScreenEvaluation" ||
         screenName == "ScreenEvaluationStage" ||
         screenName == "ScreenGameplay";
}

void Screen::InitScreen(Screen* pScreen) {
  if (pScreen == nullptr) {
    WarnScreen("", "InitScreen called with a null screen.");
    return;
  }
  pScreen->Init();
}

Screen::~Screen() {}

bool Screen::SortMessagesByDelayRemaining(
    const Screen::QueuedScreenMessage& m1,
    const Screen::QueuedScreenMessage& m2) {
  return m1.fDelayRemaining < m2.fDelayRemaining;
}

void Screen::Init() {
  if (HasThemeRuntime() && !m_sName.empty()) {
    ALLOW_OPERATOR_MENU_BUTTON.Load(m_sName, "AllowOperatorMenuButton");
    HANDLE_BACK_BUTTON.Load(m_sName, "HandleBackButton");
    REPEAT_RATE.Load(m_sName, "RepeatRate");
    REPEAT_DELAY.Load(m_sName, "RepeatDelay");
    LIGHTS_MODE.Load(m_sName, "LightsMode");
    m_Codes.Load(m_sName);
  } else {
    WarnScreen(m_sName, "initializing without a loaded theme/Lua runtime.");
  }

  SetFOV(0);

  m_smSendOnPop = SM_None;
  m_bRunning = false;

  m_CallingInputCallbacks = false;
  m_iInputCallbacksHandleBeforeScreenLocks = 0;

  if (HasThemeRuntime() && !m_sName.empty()) {
    ActorUtil::LoadAllCommandsFromName(*this, m_sName, "Screen");
  }

  PlayCommandNoRecurse(Message("Init"));

  if (SCREENMAN == nullptr) {
    WarnScreen(m_sName, "cannot prepare/group/persist screens without SCREENMAN.");
    return;
  }

  auto applyScreenList = [this](
                             const std::string& metric,
                             void (ScreenManager::*action)(
                                 const std::string&)) {
    std::vector<std::string> asList;
    split(GetThemeMetricString(m_sName, metric), ",", asList);
    std::set<std::string> seen;
    for (std::string screenName : asList) {
      Trim(screenName);
      if (screenName.empty() || seen.find(screenName) != seen.end()) {
        continue;
      }
      seen.insert(screenName);
      if (!IsUsableScreenTarget(screenName)) {
        WarnScreen(
            m_sName,
            "ignoring invalid " + metric + " target: " + screenName);
        continue;
      }
      if (metric == "PrepareScreens" && LOG != nullptr) {
        LOG->Trace(
            "Screen \"%s\" preparing \"%s\"",
            m_sName.c_str(),
            screenName.c_str());
      }
      (SCREENMAN->*action)(screenName);
    }
  };

  applyScreenList("PrepareScreens", &ScreenManager::PrepareScreen);
  applyScreenList("GroupedScreens", &ScreenManager::GroupScreen);
  applyScreenList("PersistScreens", &ScreenManager::PersistantScreen);
}

void Screen::BeginScreen() {
  m_bRunning = true;
  m_bFirstUpdate = true;

  /* Screens set these when they determine their next screen dynamically. Reset
   * them here, so a reused screen doesn't inherit these from the last time it
   * was used. */
  m_sNextScreen = std::string();

  m_fLockInputSecs = 0;

  if (HasThemeRuntime() && !m_sName.empty()) {
    this->RunCommands(THEME->GetMetricA(m_sName, "ScreenOnCommand"));
  }

  if (!std::isfinite(m_fLockInputSecs) || m_fLockInputSecs <= 0.0f) {
    m_fLockInputSecs =
        0.0001f;  // always lock for a tiny amount of time so that we throw away
                  // any queued inputs during the load.
  }

  this->PlayCommand("Begin");
}

void Screen::EndScreen() {
  this->PlayCommand("End");
  m_bRunning = false;

  m_InputCallbacks.clear();
  m_DelayedCallbackRemovals.clear();
  m_iInputCallbacksHandleBeforeScreenLocks = 0;
}

void Screen::Update(float fDeltaTime) {
  fDeltaTime = SanitizeNonNegativeSeconds(fDeltaTime);
  ActorFrame::Update(fDeltaTime);

  m_fLockInputSecs =
      SanitizeNonNegativeSeconds(m_fLockInputSecs - fDeltaTime);

  for (QueuedScreenMessage& message : m_QueuedMessages) {
    message.fDelayRemaining =
        SanitizeNonNegativeSeconds(message.fDelayRemaining);
  }

  /* We need to ensure two things:
   * 1. Messages must be sent in the order of delay. If two messages are sent
   *    simultaneously, one with a .001 delay and another with a .002 delay,
   *    the .001 delay message must be sent first.
   * 2. Messages to be delivered simultaneously must be sent in the order
   * queued.
   *
   * Sort by time to ensure #1; use a stable sort to ensure #2. */
  stable_sort(
      m_QueuedMessages.begin(), m_QueuedMessages.end(),
      SortMessagesByDelayRemaining);

  // Update the times of queued ScreenMessages.
  for (size_t i = 0; i < m_QueuedMessages.size(); i++) {
    /* Hack:
     * If we simply subtract time and then send messages, we have a problem.
     * Messages are queued to arrive at specific times, and those times line
     * up with things like tweens finishing. If we send the message at the
     * exact time given, then it'll be on the same cycle that would be rendering
     * the last frame of a tween (such as an object going off the screen).
     * However, when we send the message, we're likely to set up a new screen,
     * which causes everything to stop in place; this results in actors
     * occasionally not quite finishing their tweens.
     * Let's delay all messages that have a non-zero time an extra frame. */
    if (m_QueuedMessages[i].fDelayRemaining > 0.0001f) {
      m_QueuedMessages[i].fDelayRemaining -= fDeltaTime;
      m_QueuedMessages[i].fDelayRemaining =
          std::max(m_QueuedMessages[i].fDelayRemaining, 0.0001f);
    } else {
      m_QueuedMessages[i].fDelayRemaining -= fDeltaTime;
    }
  }

  /* Now dispatch messages. If the number of messages on the queue changes
   * within HandleScreenMessage, someone cleared messages on the queue. This
   * means we have no idea where 'i' is, so start over. Since we applied time
   * already, this won't cause messages to be mistimed. */
  for (size_t i = 0; i < m_QueuedMessages.size();) {
    if (m_QueuedMessages[i].fDelayRemaining > 0.0f) {
      ++i;
      continue; /* not yet */
    }

    // Remove the message from the list.
    const ScreenMessage SM = m_QueuedMessages[i].SM;
    m_QueuedMessages.erase(m_QueuedMessages.begin() + i);

    const size_t iSize = m_QueuedMessages.size();

    // send this sucker!
    CHECKPOINT_M(ssprintf(
        "ScreenMessage(%s)",
        ScreenMessageHelpers::ScreenMessageToString(SM).c_str()));
    this->HandleScreenMessage(SM);

    // If the size changed, start over.
    if (iSize != m_QueuedMessages.size()) {
      i = 0;
    } else {
      // Erase already moved the next message into index i.
    }
  }
}

/* Returns true if the input was handled, or false if not handled.  For
 * overlays, this determines whether the event will be propagated to lower
 * screens (i.e. it propagates from an overlay only when this returns false). */
bool Screen::Input(const InputEventPlus& input) {
  if (m_fLockInputSecs > 0.0f) {
    return false;
  }

  // Don't send release messages with the default handler.
  switch (input.type) {
    case IET_FIRST_PRESS:
    case IET_REPEAT:
      break;  // OK
    default:
      return false;  // don't care
  }

  Message msg("");
  if (m_Codes.InputMessage(input, msg)) {
    this->HandleMessage(msg);
    return true;
  }

  // Always broadcast mouse input so themers can grab it. -aj
  if (input.DeviceI == DeviceInput(DEVICE_MOUSE, MOUSE_LEFT)) {
    BroadcastMouseMessage(Message_LeftClick);
  }
  if (input.DeviceI == DeviceInput(DEVICE_MOUSE, MOUSE_RIGHT)) {
    BroadcastMouseMessage(Message_RightClick);
  }
  if (input.DeviceI == DeviceInput(DEVICE_MOUSE, MOUSE_MIDDLE)) {
    BroadcastMouseMessage(Message_MiddleClick);
  }
  // Can't do MouseWheelUp and MouseWheelDown at the same time. -aj
  if (input.DeviceI == DeviceInput(DEVICE_MOUSE, MOUSE_WHEELUP)) {
    BroadcastMouseMessage(Message_MouseWheelUp);
  } else if (input.DeviceI == DeviceInput(DEVICE_MOUSE, MOUSE_WHEELDOWN)) {
    BroadcastMouseMessage(Message_MouseWheelDown);
  }

  // default input handler used by most menus
  switch (input.MenuI) {
    case GAME_BUTTON_MENUUP:
      return this->MenuUp(input);
    case GAME_BUTTON_MENUDOWN:
      return this->MenuDown(input);
    case GAME_BUTTON_MENULEFT:
      return this->MenuLeft(input);
    case GAME_BUTTON_MENURIGHT:
      return this->MenuRight(input);
    case GAME_BUTTON_BACK:
      // Only go back on first press.  If somebody is backing out of the
      // options screen, they might still be holding it when select music
      // appears, and accidentally back out of that too. -Kyz
      if (input.type == IET_FIRST_PRESS) {
        if (GetLoadedBoolMetric(HANDLE_BACK_BUTTON, false)) {
          return this->MenuBack(input);
        }
      }
      return false;
    case GAME_BUTTON_START:
      return this->MenuStart(input);
    case GAME_BUTTON_SELECT:
      return this->MenuSelect(input);
    case GAME_BUTTON_RESTART:
      return this->MenuRestart(input);
    case GAME_BUTTON_COIN:
      return this->MenuCoin(input);
    default:
      return false;
  }
}

void Screen::HandleScreenMessage(const ScreenMessage SM) {
  const bool traceOnlineScreen = ShouldTraceOnlineScreen(m_sName);
  if (traceOnlineScreen) {
    TraceOnlineScreenMessage(
        "handle_screen_message_begin", m_sName, SM, m_bRunning,
        m_QueuedMessages.size());
  }
  if (SM == SM_GoToNextScreen || SM == SM_GoToPrevScreen) {
    if (SCREENMAN == nullptr) {
      WarnScreen(m_sName, "cannot change screens without SCREENMAN.");
      return;
    }
    if (SCREENMAN->IsStackedScreen(this)) {
      if (traceOnlineScreen) {
        TraceOnlineScreenPop(m_sName, SM);
      }
      SCREENMAN->PopTopScreen(m_smSendOnPop);
    } else {
      std::string ToScreen =
          (SM == SM_GoToNextScreen ? GetNextScreenName() : GetPrevScreen());
      if (ToScreen == "") {
        LuaHelpers::ReportScriptError("Error:  Tried to go to empty screen.");
      } else if (!IsUsableScreenTarget(ToScreen)) {
        WarnScreen(m_sName, "refusing invalid target screen: " + ToScreen);
      } else {
        if (traceOnlineScreen || ShouldTraceOnlineScreen(ToScreen)) {
          TraceOnlineScreenTransition(
              "handle_screen_message_set_new_screen", m_sName, ToScreen, SM);
        }
        SCREENMAN->SetNewScreen(ToScreen);
      }
    }
  } else if (SM == SM_GainFocus) {
    const float repeatRate = GetLoadedFloatMetric(REPEAT_RATE, -1.0f);
    const float repeatDelay = GetLoadedFloatMetric(REPEAT_DELAY, -1.0f);
    if (INPUTFILTER != nullptr && repeatRate != -1.0f) {
      INPUTFILTER->SetRepeatRate(repeatRate);
    }
    if (INPUTFILTER != nullptr && repeatDelay != -1.0f) {
      INPUTFILTER->SetRepeatDelay(repeatDelay);
    }

    if (LIGHTSMAN != nullptr && LIGHTS_MODE.IsLoaded()) {
      LIGHTSMAN->SetLightsMode(LIGHTS_MODE.GetValue());
    }
  } else if (SM == SM_LoseFocus) {
    if (INPUTFILTER != nullptr) {
      INPUTFILTER->ResetRepeatRate();
    }
  }
  if (traceOnlineScreen) {
    TraceOnlineScreenMessage(
        "handle_screen_message_end", m_sName, SM, m_bRunning,
        m_QueuedMessages.size());
  }
}

std::string Screen::GetNextScreenName() const {
  if (!m_sNextScreen.empty()) {
    return m_sNextScreen;
  }
  return GetThemeMetricString(m_sName, "NextScreen");
}

void Screen::SetNextScreenName(const std::string& name) {
  m_sNextScreen = name;
}

void Screen::SetPrevScreenName(const std::string& name) {
  m_sPrevScreen = name;
}

std::string Screen::GetPrevScreen() const {
  if (!m_sPrevScreen.empty()) {
    return m_sPrevScreen;
  }
  return GetThemeMetricString(m_sName, "PrevScreen");
}

void Screen::PostScreenMessage(const ScreenMessage SM, float fDelay) {
  if (SM == SM_Invalid) {
    WarnScreen(m_sName, "ignored invalid empty ScreenMessage.");
    return;
  }

  fDelay = SanitizeNonNegativeSeconds(fDelay);

  if (ShouldTraceOnlineScreen(m_sName) && LOG != nullptr) {
    LOG->Trace(
        "ITG Online ScreenTrace: post_screen_message screen=%s message=%s "
        "delay=%.3f queued_before=%zu",
        m_sName.c_str(),
        ScreenMessageHelpers::ScreenMessageToString(SM).c_str(),
        fDelay,
        m_QueuedMessages.size());
    LOG->Flush();
  }

  QueuedScreenMessage QSM;
  QSM.SM = SM;
  QSM.fDelayRemaining = fDelay;
  m_QueuedMessages.push_back(QSM);
}

void Screen::ClearMessageQueue() { m_QueuedMessages.clear(); }

void Screen::ClearMessageQueue(const ScreenMessage SM) {
  m_QueuedMessages.erase(
      std::remove_if(
          m_QueuedMessages.begin(),
          m_QueuedMessages.end(),
          [&](const QueuedScreenMessage& message) { return message.SM == SM; }),
      m_QueuedMessages.end());
}

bool Screen::PassInputToLua(const InputEventPlus& input) {
  if (m_InputCallbacks.empty() || m_fLockInputSecs > 0.0f ||
      !AllowCallbackInput()) {
    return false;
  }
  if (LUA == nullptr || INPUTMAPPER == nullptr) {
    WarnScreen(m_sName, "cannot run input callbacks without Lua/input mapper.");
    return false;
  }
  m_CallingInputCallbacks = true;
  bool handled = false;
  Lua* L = LUA->Get();

  // Construct the table once, and reuse it.
  lua_createtable(L, 0, 7);
  {  // This block is meant to improve clarity.  A subtable is created for
    // storing the DeviceInput member.
    lua_createtable(L, 0, 8);
    Enum::Push(L, input.DeviceI.device);
    lua_setfield(L, -2, "device");
    Enum::Push(L, input.DeviceI.button);
    lua_setfield(L, -2, "button");
    lua_pushnumber(L, input.DeviceI.level);
    lua_setfield(L, -2, "level");
    lua_pushinteger(L, input.DeviceI.z);
    lua_setfield(L, -2, "z");
    lua_pushboolean(L, input.DeviceI.bDown);
    lua_setfield(L, -2, "down");
    lua_pushnumber(L, input.DeviceI.ts.Ago());
    lua_setfield(L, -2, "ago");
    lua_pushboolean(L, input.DeviceI.IsJoystick());
    lua_setfield(L, -2, "is_joystick");
    lua_pushboolean(L, input.DeviceI.IsMouse());
    lua_setfield(L, -2, "is_mouse");
  }
  lua_setfield(L, -2, "DeviceInput");
  Enum::Push(L, input.GameI.controller);
  lua_setfield(L, -2, "controller");
  LuaHelpers::Push(
      L, GameButtonToString(INPUTMAPPER->GetInputScheme(), input.GameI.button));
  lua_setfield(L, -2, "button");
  Enum::Push(L, input.type);
  lua_setfield(L, -2, "type");
  LuaHelpers::Push(
      L, GameButtonToString(INPUTMAPPER->GetInputScheme(), input.MenuI));
  lua_setfield(L, -2, "GameButton");
  Enum::Push(L, input.pn);
  lua_setfield(L, -2, "PlayerNumber");
  Enum::Push(L, input.mp);
  lua_setfield(L, -2, "MultiPlayer");
  const int inputTableIndex = lua_gettop(L);
  for (std::map<callback_key_t, LuaReference>::iterator callback =
           m_InputCallbacks.begin();
       callback != m_InputCallbacks.end() && !handled; ++callback) {
    callback->second.PushSelf(L);
    lua_pushvalue(L, -2);
    std::string error = "Error running input callback: ";
    if (LuaHelpers::RunScriptOnStack(L, error, 1, 1, true)) {
      if (lua_isboolean(L, -1)) {
        handled = lua_toboolean(L, -1);
      } else if (!lua_isnil(L, -1)) {
        LuaHelpers::ReportScriptError(
            "Input callback did not return a boolean.");
      }
    }
    lua_settop(L, inputTableIndex);
  }
  lua_pop(L, 1);
  LUA->Release(L);
  m_CallingInputCallbacks = false;
  if (!m_DelayedCallbackRemovals.empty()) {
    for (std::vector<callback_key_t>::iterator key =
             m_DelayedCallbackRemovals.begin();
         key != m_DelayedCallbackRemovals.end(); ++key) {
      InternalRemoveCallback(*key);
    }
    m_DelayedCallbackRemovals.clear();
  }
  return handled;
}

void Screen::AddInputCallbackFromStack(lua_State* L) {
  if (L == nullptr || !lua_isfunction(L, 1)) {
    WarnScreen(m_sName, "ignored invalid input callback registration.");
    return;
  }
  callback_key_t key = lua_topointer(L, 1);
  if (key == nullptr) {
    WarnScreen(m_sName, "ignored input callback with null key.");
    return;
  }
  m_InputCallbacks[key] = LuaReference(L);
}

void Screen::RemoveInputCallback(lua_State* L) {
  if (L == nullptr || !lua_isfunction(L, 1)) {
    WarnScreen(m_sName, "ignored invalid input callback removal.");
    return;
  }
  callback_key_t key = lua_topointer(L, 1);
  if (key == nullptr) {
    return;
  }
  if (m_CallingInputCallbacks) {
    if (std::find(m_DelayedCallbackRemovals.begin(),
                  m_DelayedCallbackRemovals.end(),
                  key) == m_DelayedCallbackRemovals.end()) {
      m_DelayedCallbackRemovals.push_back(key);
    }
  } else {
    InternalRemoveCallback(key);
  }
}

void Screen::ClearInputCallbacks() {
  if (m_CallingInputCallbacks) {
    for (std::map<callback_key_t, LuaReference>::const_iterator callback =
             m_InputCallbacks.begin();
         callback != m_InputCallbacks.end(); ++callback) {
      if (std::find(m_DelayedCallbackRemovals.begin(),
                    m_DelayedCallbackRemovals.end(),
                    callback->first) == m_DelayedCallbackRemovals.end()) {
        m_DelayedCallbackRemovals.push_back(callback->first);
      }
    }
  } else {
    m_InputCallbacks.clear();
    m_DelayedCallbackRemovals.clear();
  }
}

void Screen::SetInputCallbacksHandleBeforeScreen(bool enabled) {
  m_iInputCallbacksHandleBeforeScreenLocks = enabled ? 1 : 0;
}

bool Screen::InputCallbacksHandleBeforeScreen() const {
  return m_iInputCallbacksHandleBeforeScreenLocks > 0;
}

void Screen::InternalRemoveCallback(callback_key_t key) {
  std::map<callback_key_t, LuaReference>::iterator iter =
      m_InputCallbacks.find(key);
  if (iter != m_InputCallbacks.end()) {
    m_InputCallbacks.erase(iter);
  }
}

void Screen::SetLockInputSecs(float f) {
  m_fLockInputSecs = SanitizeNonNegativeSeconds(f);
}

ScreenType Screen::GetScreenType() const {
  return AllowOperatorMenuButton() ? game_menu : system_menu;
}

bool Screen::AllowOperatorMenuButton() const {
  return GetLoadedBoolMetric(ALLOW_OPERATOR_MENU_BUTTON, false);
}

// lua start
#include "LuaBinding.h"

/** @brief Allow Lua to have access to the Screen. */
class LunaScreen : public Luna<Screen> {
 public:
  static int GetNextScreenName(T* p, lua_State* L) {
    lua_pushstring(L, p->GetNextScreenName().c_str());
    return 1;
  }
  static int SetNextScreenName(T* p, lua_State* L) {
    p->SetNextScreenName(SArg(1));
    COMMON_RETURN_SELF;
  }
  static int GetPrevScreenName(T* p, lua_State* L) {
    lua_pushstring(L, p->GetPrevScreen().c_str());
    return 1;
  }
  static int SetPrevScreenName(T* p, lua_State* L) {
    p->SetPrevScreenName(SArg(1));
    COMMON_RETURN_SELF;
  }
  static int lockinput(T* p, lua_State* L) {
    p->SetLockInputSecs(FArg(1));
    COMMON_RETURN_SELF;
  }
  DEFINE_METHOD(GetScreenType, GetScreenType())

  static int PostScreenMessage(T* p, lua_State* L) {
    std::string sMessage = SArg(1);
    if (sMessage.empty()) {
      luaL_error(L, "ScreenMessage must not be empty.");
    }
    ScreenMessage SM = ScreenMessageHelpers::ToScreenMessage(sMessage);
    p->PostScreenMessage(SM, FArg(2));
    COMMON_RETURN_SELF;
  }

  static int AddInputCallback(T* p, lua_State* L) {
    if (!lua_isfunction(L, 1)) {
      luaL_error(L, "Input callback must be a function.");
    }
    p->AddInputCallbackFromStack(L);
    COMMON_RETURN_SELF;
  }

  static int RemoveInputCallback(T* p, lua_State* L) {
    if (!lua_isfunction(L, 1)) {
      luaL_error(L, "Input callback must be a function.");
    }
    p->RemoveInputCallback(L);
    COMMON_RETURN_SELF;
  }

  static int ClearInputCallbacks(T* p, lua_State* L) {
    p->ClearInputCallbacks();
    COMMON_RETURN_SELF;
  }

  static int SetInputCallbacksHandleBeforeScreen(T* p, lua_State* L) {
    p->SetInputCallbacksHandleBeforeScreen(BArg(1));
    COMMON_RETURN_SELF;
  }

  LunaScreen() {
    ADD_METHOD(GetNextScreenName);
    ADD_METHOD(SetNextScreenName);
    ADD_METHOD(GetPrevScreenName);
    ADD_METHOD(SetPrevScreenName);
    ADD_METHOD(PostScreenMessage);
    ADD_METHOD(lockinput);
    ADD_METHOD(GetScreenType);
    ADD_METHOD(AddInputCallback);
    ADD_METHOD(RemoveInputCallback);
    ADD_METHOD(ClearInputCallbacks);
    ADD_METHOD(SetInputCallbacksHandleBeforeScreen);
  }
};

LUA_REGISTER_DERIVED_CLASS(Screen, ActorFrame)
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
