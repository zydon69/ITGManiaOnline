#include "ScreenTextEntry.h"

#include <algorithm>
#include <cerrno>
#include <climits>
#include <cmath>
#include <cstdlib>
#include <string>

#include "ActorUtil.h"
#include "BitmapText.h"
#include "FontCharAliases.h"
#include "InputEventPlus.h"
#include "InputFilter.h"
#include "LocalizedString.h"
#include "LuaBinding.h"
#include "LuaManager.h"
#include "RageInput.h"
#include "RageInputDevice.h"
#include "RageLog.h"
#include "RageUtil.h"
#include "RageUtil/ConvertValue.h"
#include "Screen.h"
#include "ScreenManager.h"
#include "ScreenMessage.h"
#include "ScreenPrompt.h"
#include "ScreenWithMenuElements.h"
#include "ThemeManager.h"
#include "arch/ArchHooks/ArchHooks.h"  // HOOKS->GetClipboard()

namespace {
constexpr int MAX_TEXT_ENTRY_INPUT_LENGTH = 4096;

bool HasLoadedTheme() { return THEME != nullptr && THEME->IsThemeLoaded(); }

int ClampInputLength(int length) {
  return std::clamp(length, 0, MAX_TEXT_ENTRY_INPUT_LENGTH);
}

std::wstring TruncateAnswerToLimit(const std::wstring& answer, int limit) {
  if (limit < 0) {
    limit = 0;
  }
  if (static_cast<int>(answer.size()) <= limit) {
    return answer;
  }
  return answer.substr(0, static_cast<size_t>(limit));
}

std::string ClipAppendToAvailableRoom(
    const std::wstring& current, const std::string& append, int limit) {
  if (limit <= static_cast<int>(current.size())) {
    return "";
  }

  std::wstring wide = RStringToWstring(append);
  const int room = limit - static_cast<int>(current.size());
  if (static_cast<int>(wide.size()) > room) {
    wide = wide.substr(0, static_cast<size_t>(room));
  }
  return WStringToRString(wide);
}

bool IsValidKeyboardRow(KeyboardRow row) {
  return row >= R1 && row < NUM_KeyboardRow;
}

bool HasUsableLua() { return LUA != nullptr; }

void WarnTextEntry(const std::string& message) {
  if (LOG != nullptr) {
    LOG->Warn("ScreenTextEntry: %s", message.c_str());
  }
}
}  // namespace

static const char* g_szKeys[NUM_KeyboardRow][KEYS_PER_ROW] = {
    {"A", "B", "C", "D", "E", "F", "G", "H", "I", "J", "K", "L", "M"},
    {"N", "O", "P", "Q", "R", "S", "T", "U", "V", "W", "X", "Y", "Z"},
    {"a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l", "m"},
    {"n", "o", "p", "q", "r", "s", "t", "u", "v", "w", "x", "y", "z"},
    {"0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "", "", ""},
    {"!", "@", "#", "$", "%", "^", "&", "(", ")", "[", "]", "{", "}"},
    {"+", "-", "=", "_", ",", ".", "'", "\"", ":", "", "", "", ""},
    {"", "", "Space", "", "", "Backspace", "", "", "Cancel", "", "", "Done",
     ""},
};

std::string ScreenTextEntry::s_sLastAnswer = "";

// Settings:
namespace {
ScreenTextEntry::RuntimeSettings g_PendingSettings;
bool g_bPendingSettingsValid = false;
};  // namespace

ScreenTextEntry::RuntimeSettings::RuntimeSettings()
    : sQuestion(""),
      sInitialAnswer(""),
      iMaxInputLength(255),
      bPassword(false),
      Validate(nullptr),
      OnOK(nullptr),
      OnCancel(nullptr),
      ValidateAppend(nullptr),
      FormatAnswerForDisplay(nullptr),
      ValidateLua(),
      OnOKLua(),
      OnCancelLua(),
      ValidateAppendLua(),
      FormatAnswerForDisplayLua() {}

void ScreenTextEntry::SetTextEntrySettings(
    std::string sQuestion, std::string sInitialAnswer, int iMaxInputLength,
    bool (*Validate)(const std::string& sAnswer, std::string& sErrorOut),
    void (*OnOK)(const std::string& sAnswer), void (*OnCancel)(),
    bool bPassword,
    bool (*ValidateAppend)(
        const std::string& sAnswerBeforeChar, std::string& sAppend),
    std::string (*FormatAnswerForDisplay)(const std::string& sAnswer)) {
  RuntimeSettings settings;
  settings.sQuestion = sQuestion;
  settings.sInitialAnswer = sInitialAnswer;
  settings.iMaxInputLength = ClampInputLength(iMaxInputLength);
  settings.bPassword = bPassword;
  settings.Validate = Validate;
  settings.OnOK = OnOK;
  settings.OnCancel = OnCancel;
  settings.ValidateAppend = ValidateAppend;
  settings.FormatAnswerForDisplay = FormatAnswerForDisplay;
  g_PendingSettings = settings;
  g_bPendingSettingsValid = true;
}

void ScreenTextEntry::TextEntry(
    ScreenMessage smSendOnPop, std::string sQuestion,
    std::string sInitialAnswer, int iMaxInputLength,
    bool (*Validate)(const std::string& sAnswer, std::string& sErrorOut),
    void (*OnOK)(const std::string& sAnswer), void (*OnCancel)(),
    bool bPassword,
    bool (*ValidateAppend)(
        const std::string& sAnswerBeforeChar, std::string& sAppend),
    std::string (*FormatAnswerForDisplay)(const std::string& sAnswer)) {
  SetTextEntrySettings(
      sQuestion, sInitialAnswer, iMaxInputLength, Validate, OnOK, OnCancel,
      bPassword, ValidateAppend, FormatAnswerForDisplay);

  if (SCREENMAN == nullptr) {
    WarnTextEntry("cannot open text entry without SCREENMAN");
    return;
  }
  SCREENMAN->AddNewScreenToTop("ScreenTextEntry", smSendOnPop);
}

static LocalizedString INVALID_FLOAT(
    "ScreenTextEntry", "\"%s\" is an invalid floating point value.");
bool ScreenTextEntry::FloatValidate(
    const std::string& sAnswer, std::string& sErrorOut) {
  float f;
  if (StringToFloat(sAnswer, f)) {
    return true;
  }
  sErrorOut = ssprintf(INVALID_FLOAT.GetValue().c_str(), sAnswer.c_str());
  return false;
}

static LocalizedString INVALID_INT(
    "ScreenTextEntry", "\"%s\" is an invalid integer value.");
bool ScreenTextEntry::IntValidate(
    const std::string& sAnswer, std::string& sErrorOut) {
  char* end = nullptr;
  errno = 0;
  const long parsed = std::strtol(sAnswer.c_str(), &end, 10);
  if (!sAnswer.empty() && end != nullptr && *end == '\0' && errno == 0 &&
      parsed >= INT_MIN && parsed <= INT_MAX) {
    return true;
  }
  sErrorOut = ssprintf(INVALID_INT.GetValue().c_str(), sAnswer.c_str());
  return false;
}

bool ScreenTextEntry::s_bCancelledLast = false;

/* Handle UTF-8. Right now, we need to at least be able to backspace a whole
 * UTF-8 character. Better would be to operate in wchar_t.
 *
 * XXX: Don't allow internal-use codepoints (above 0xFFFF); those are subject to
 * change and shouldn't be written to disk. */
REGISTER_SCREEN_CLASS(ScreenTextEntry);
REGISTER_SCREEN_CLASS(ScreenTextEntryVisual);

void ScreenTextEntry::ApplySettings(const RuntimeSettings& settings) {
  m_Settings = settings;
  m_Settings.iMaxInputLength = ClampInputLength(m_Settings.iMaxInputLength);
  m_bLCtrl = false;
  m_bRCtrl = false;
  RefreshFromSettings();
}

void ScreenTextEntry::RefreshFromSettings() {
  m_sAnswer =
      TruncateAnswerToLimit(RStringToWstring(m_Settings.sInitialAnswer),
                            m_Settings.iMaxInputLength);
  if (m_bQuestionReady) {
    m_textQuestion.SetText(m_Settings.sQuestion);
    SET_XY(m_textQuestion);
  }
  if (m_bAnswerReady) {
    SET_XY(m_textAnswer);
  }
  UpdateAnswerText();
}

void ScreenTextEntry::Init() {
  ScreenWithMenuElements::Init();

  if (g_bPendingSettingsValid) {
    ApplySettings(g_PendingSettings);
    g_bPendingSettingsValid = false;
  } else {
    ApplySettings(RuntimeSettings());
  }

  m_textQuestion.SetName("Question");
  if (HasLoadedTheme() &&
      m_textQuestion.LoadFromFont(THEME->GetPathF(m_sName, "question", true))) {
    m_bQuestionReady = true;
    LOAD_ALL_COMMANDS(m_textQuestion);
    this->AddChild(&m_textQuestion);
  }

  m_textAnswer.SetName("Answer");
  if (HasLoadedTheme() &&
      m_textAnswer.LoadFromFont(THEME->GetPathF(m_sName, "answer", true))) {
    m_bAnswerReady = true;
    LOAD_ALL_COMMANDS(m_textAnswer);
    this->AddChild(&m_textAnswer);
  }

  m_bShowAnswerCaret = false;
  // m_iCaretLocation = 0;

  if (HasLoadedTheme()) {
    m_sndType.Load(THEME->GetPathS(m_sName, "type", true), true);
    m_sndBackspace.Load(THEME->GetPathS(m_sName, "backspace", true), true);
  }
}

void ScreenTextEntry::BeginScreen() {
  ScreenWithMenuElements::BeginScreen();

  m_bLCtrl = false;
  m_bRCtrl = false;
  m_bEnding = false;
  RefreshFromSettings();
}

static LocalizedString ANSWER_CARET("ScreenTextEntry", "AnswerCaret");
static LocalizedString ANSWER_BLANK("ScreenTextEntry", "AnswerBlank");
void ScreenTextEntry::UpdateAnswerText() {
  if (!m_bAnswerReady) {
    return;
  }

  std::string s;
  if (m_Settings.bPassword) {
    s = std::string(m_sAnswer.size(), '*');
  } else {
    s = WStringToRString(m_sAnswer);
  }

  const bool bAnswerFull =
      static_cast<int>(m_sAnswer.size()) >= m_Settings.iMaxInputLength;

  s = FormatAnswerForDisplay(s);

  // Handle caret drawing
  // m_iCaretLocation = s.length()
  if (m_bShowAnswerCaret && !bAnswerFull) {
    s += ANSWER_CARET;  // was '_'
  } else {
    s += ANSWER_BLANK;  // was "  "
  }

  FontCharAliases::ReplaceMarkers(s);
  m_textAnswer.SetText(s);
}

void ScreenTextEntry::Update(float fDelta) {
  ScreenWithMenuElements::Update(fDelta);

  if (m_timerToggleCursor.Ago() > 0.25f) {
    m_timerToggleCursor.Touch();
    m_bShowAnswerCaret = !m_bShowAnswerCaret;
    UpdateAnswerText();
  }
}

bool ScreenTextEntry::Input(const InputEventPlus& input) {
  if (IsTransitioning() || m_fLockInputSecs > 0 || m_bEnding) {
    return false;
  }

  // bLCtrl and bRCtl are whether their respective Ctrl keys are held
  // We update them here.
  if (input.DeviceI == DeviceInput(DEVICE_KEYBOARD, KEY_LCTRL)) {
    switch (input.type) {
      case IET_FIRST_PRESS:
        m_bLCtrl = true;
        break;
      case IET_RELEASE:
        m_bLCtrl = false;
        break;
      default:
        break;
    }
  }

  if (input.DeviceI == DeviceInput(DEVICE_KEYBOARD, KEY_RCTRL)) {
    switch (input.type) {
      case IET_FIRST_PRESS:
        m_bRCtrl = true;
        break;
      case IET_RELEASE:
        m_bRCtrl = false;
        break;
      default:
        break;
    }
  }

  bool bHandled = false;
  if (input.DeviceI == DeviceInput(DEVICE_KEYBOARD, KEY_BACK)) {
    switch (input.type) {
      case IET_FIRST_PRESS:
      case IET_REPEAT:
        BackspaceInAnswer();
        bHandled = true;
      default:
        break;
    }
  } else if (input.type == IET_FIRST_PRESS) {
    if (INPUTMAN == nullptr) {
      return ScreenWithMenuElements::Input(input);
    }

    wchar_t c = INPUTMAN->DeviceInputToChar(input.DeviceI, true);
    // Detect Ctrl+V
    if ((c == L'v' || c == L'V') && (m_bLCtrl || m_bRCtrl)) {
      if (HOOKS != nullptr) {
        TryAppendToAnswer(HOOKS->GetClipboard());
      }

      TextEnteredDirectly();  // XXX: This doesn't seem appropriate but there's
                              // no TextPasted()
      bHandled = true;
    } else if (c >= L' ') {
      // todo: handle caps lock -aj
      TryAppendToAnswer(WStringToRString(std::wstring() + c));

      TextEnteredDirectly();
      bHandled = true;
    }
  }

  if (bHandled) {
    return true;
  }
  return ScreenWithMenuElements::Input(input);
}

void ScreenTextEntry::TryAppendToAnswer(std::string s) {
  if (!CanEditText()) {
    PlayInvalidSound();
    return;
  }

  s = ClipAppendToAvailableRoom(m_sAnswer, s, m_Settings.iMaxInputLength);
  if (s.empty()) {
    PlayInvalidSound();
    return;
  }

  if (!ValidateAppend(s)) {
    PlayInvalidSound();
    return;
  }

  s = ClipAppendToAvailableRoom(m_sAnswer, s, m_Settings.iMaxInputLength);
  if (s.empty()) {
    PlayInvalidSound();
    return;
  }

  std::wstring sNewAnswer = m_sAnswer + RStringToWstring(s);
  if (static_cast<int>(sNewAnswer.size()) > m_Settings.iMaxInputLength) {
    PlayInvalidSound();
    return;
  }
  m_sAnswer = sNewAnswer;
  m_sndType.Play(true);
  UpdateAnswerText();
}

void ScreenTextEntry::BackspaceInAnswer() {
  if (m_sAnswer.empty()) {
    PlayInvalidSound();
    return;
  }
  m_sAnswer.erase(m_sAnswer.end() - 1);
  m_sndBackspace.Play(true);
  UpdateAnswerText();
}

bool ScreenTextEntry::MenuStart(const InputEventPlus& input) {
  if (input.type != IET_FIRST_PRESS) {
    return false;
  }
  if (IsTransitioning() || m_fLockInputSecs > 0 || m_bEnding) {
    return false;
  }
  if (input.DeviceI == DeviceInput(DEVICE_KEYBOARD, KEY_ENTER) ||
      input.MenuI == GAME_BUTTON_START) {
    End(false);
    return true;
  }
  return false;
}

bool ScreenTextEntry::CanEditText() const {
  return m_Settings.iMaxInputLength > 0 &&
         static_cast<int>(m_sAnswer.size()) < m_Settings.iMaxInputLength;
}

void ScreenTextEntry::PlayInvalidSound() const {
  if (SCREENMAN != nullptr) {
    SCREENMAN->PlayInvalidSound();
  }
}

bool ScreenTextEntry::ValidateAnswer(std::string& sErrorOut) {
  const std::string answer = WStringToRString(m_sAnswer);
  if (m_Settings.Validate != nullptr &&
      !m_Settings.Validate(answer, sErrorOut)) {
    return false;
  }

  if (m_Settings.ValidateLua.IsNil() || !m_Settings.ValidateLua.IsSet()) {
    return true;
  }
  if (!HasUsableLua()) {
    sErrorOut = "Lua is not available.";
    return false;
  }

  Lua* L = LUA->Get();
  m_Settings.ValidateLua.PushSelf(L);
  lua_pushstring(L, answer.c_str());
  lua_pushstring(L, sErrorOut.c_str());

  bool valid = false;
  std::string error = "Lua error in ScreenTextEntry Validate: ";
  if (LuaHelpers::RunScriptOnStack(L, error, 2, 2, true)) {
    if (!lua_isstring(L, -1) || !lua_isboolean(L, -2)) {
      LuaHelpers::ReportScriptError(
          "Lua error: ScreenTextEntry Validate did not return 'bool, string'.");
      sErrorOut = "Invalid answer.";
    } else {
      std::string ErrorFromLua;
      LuaHelpers::Pop(L, ErrorFromLua);
      if (!ErrorFromLua.empty()) {
        sErrorOut = ErrorFromLua;
      }
      LuaHelpers::Pop(L, valid);
    }
  } else if (sErrorOut.empty()) {
    sErrorOut = "Invalid answer.";
  }
  lua_settop(L, 0);
  LUA->Release(L);
  return valid;
}

bool ScreenTextEntry::ValidateAppend(std::string& sAppend) {
  if (m_Settings.ValidateAppend != nullptr &&
      !m_Settings.ValidateAppend(WStringToRString(m_sAnswer), sAppend)) {
    return false;
  }

  if (m_Settings.ValidateAppendLua.IsNil() ||
      !m_Settings.ValidateAppendLua.IsSet()) {
    return true;
  }
  if (!HasUsableLua()) {
    return false;
  }

  Lua* L = LUA->Get();
  m_Settings.ValidateAppendLua.PushSelf(L);
  lua_pushstring(L, WStringToRString(m_sAnswer).c_str());
  lua_pushstring(L, sAppend.c_str());

  bool append = false;
  std::string error = "Lua error in ScreenTextEntry ValidateAppend: ";
  if (LuaHelpers::RunScriptOnStack(L, error, 2, 1, true)) {
    if (!lua_isboolean(L, -1)) {
      LuaHelpers::ReportScriptError(
          "\"ValidateAppend\" did not return a boolean.");
    } else {
      LuaHelpers::Pop(L, append);
    }
  }
  lua_settop(L, 0);
  LUA->Release(L);
  return append;
}

std::string ScreenTextEntry::FormatAnswerForDisplay(const std::string& sAnswer) {
  std::string answer = sAnswer;
  if (m_Settings.FormatAnswerForDisplay != nullptr) {
    answer = m_Settings.FormatAnswerForDisplay(answer);
  }

  if (!m_Settings.FormatAnswerForDisplayLua.IsNil() &&
      m_Settings.FormatAnswerForDisplayLua.IsSet()) {
    if (!HasUsableLua()) {
      return answer;
    }
    Lua* L = LUA->Get();
    m_Settings.FormatAnswerForDisplayLua.PushSelf(L);
    lua_pushstring(L, answer.c_str());

    std::string fromLua;
    std::string error = "Lua error in ScreenTextEntry FormatAnswerForDisplay: ";
    if (LuaHelpers::RunScriptOnStack(L, error, 1, 1, true)) {
      if (!lua_isstring(L, -1)) {
        LuaHelpers::ReportScriptError(
            "\"FormatAnswerForDisplay\" did not return a string.");
      } else {
        LuaHelpers::Pop(L, fromLua);
        answer = fromLua;
      }
    }
    lua_settop(L, 0);
    LUA->Release(L);
  }

  if (static_cast<int>(RStringToWstring(answer).size()) >
      MAX_TEXT_ENTRY_INPUT_LENGTH) {
    answer = WStringToRString(TruncateAnswerToLimit(
        RStringToWstring(answer), MAX_TEXT_ENTRY_INPUT_LENGTH));
  }
  return answer;
}

void ScreenTextEntry::RunOnOK(const std::string& sAnswer) {
  if (m_Settings.OnOK != nullptr) {
    m_Settings.OnOK(sAnswer);
  }

  if (m_Settings.OnOKLua.IsNil() || !m_Settings.OnOKLua.IsSet() ||
      !HasUsableLua()) {
    return;
  }
  Lua* L = LUA->Get();
  m_Settings.OnOKLua.PushSelf(L);
  lua_pushstring(L, sAnswer.c_str());
  std::string error = "Lua error in ScreenTextEntry OnOK: ";
  LuaHelpers::RunScriptOnStack(L, error, 1, 0, true);
  lua_settop(L, 0);
  LUA->Release(L);
}

void ScreenTextEntry::RunOnCancel() {
  if (m_Settings.OnCancel != nullptr) {
    m_Settings.OnCancel();
  }

  if (m_Settings.OnCancelLua.IsNil() || !m_Settings.OnCancelLua.IsSet() ||
      !HasUsableLua()) {
    return;
  }
  Lua* L = LUA->Get();
  m_Settings.OnCancelLua.PushSelf(L);
  std::string error = "Lua error in ScreenTextEntry OnCancel: ";
  LuaHelpers::RunScriptOnStack(L, error, 0, 0, true);
  lua_settop(L, 0);
  LUA->Release(L);
}

void ScreenTextEntry::End(bool bCancelled) {
  if (m_bEnding || IsTransitioning()) {
    return;
  }

  std::string sAnswer = WStringToRString(m_sAnswer);
  std::string callbackAnswer = sAnswer;
  if (!bCancelled) {
    std::string sError;
    if (!ValidateAnswer(sError)) {
      m_bEnding = false;
      if (sError.empty()) {
        sError = "Invalid answer.";
      }
      if (SCREENMAN != nullptr) {
        ScreenPrompt::Prompt(SM_None, sError);
      } else {
        WarnTextEntry("validation failed without SCREENMAN available");
      }
      return;  // don't end this screen.
    }
    callbackAnswer = sAnswer;
    FontCharAliases::ReplaceMarkers(callbackAnswer);
  }

  m_bEnding = true;
  s_bCancelledLast = bCancelled;
  s_sLastAnswer = bCancelled ? std::string("") : sAnswer;

  if (bCancelled) {
    Cancel(SM_GoToNextScreen);
    RunOnCancel();
  } else {
    StartTransitioningScreen(SM_GoToNextScreen);
    if (SCREENMAN != nullptr) {
      SCREENMAN->PlayStartSound();
    }
    RunOnOK(callbackAnswer);
  }
}

bool ScreenTextEntry::MenuBack(const InputEventPlus& input) {
  if (input.type != IET_FIRST_PRESS) {
    return false;
  }
  if (IsTransitioning() || m_fLockInputSecs > 0 || m_bEnding) {
    return false;
  }
  End(true);
  return true;
}

void ScreenTextEntry::TextEntrySettings::FromStack(lua_State* L) {
  if (lua_type(L, 1) != LUA_TTABLE) {
    if (LOG != nullptr) {
      LOG->Trace("not a table");
    }
    return;
  }

  lua_pushvalue(L, 1);
  const int iTab = lua_gettop(L);

  // Get ScreenMessage
  lua_getfield(L, iTab, "SendOnPop");
  const char* pStr = lua_tostring(L, -1);
  if (pStr == nullptr) {
    smSendOnPop = SM_None;
  } else {
    smSendOnPop = ScreenMessageHelpers::ToScreenMessage(pStr);
  }
  lua_settop(L, iTab);

  // Get Question
  lua_getfield(L, iTab, "Question");
  pStr = lua_tostring(L, -1);
  if (pStr == nullptr) {
    LuaHelpers::ReportScriptError(
        "ScreenTextEntry \"Question\" entry is not a string.");
    pStr = "";
  }
  sQuestion = pStr;
  lua_settop(L, iTab);

  // Get Initial Answer
  lua_getfield(L, iTab, "InitialAnswer");
  pStr = lua_tostring(L, -1);
  if (pStr == nullptr) {
    pStr = "";
  }
  sInitialAnswer = pStr;
  lua_settop(L, iTab);

  // Get Max Input Length
  lua_getfield(L, iTab, "MaxInputLength");
  if (lua_isnumber(L, -1)) {
    iMaxInputLength = ClampInputLength(static_cast<int>(lua_tointeger(L, -1)));
  } else if (!lua_isnil(L, -1)) {
    LuaHelpers::ReportScriptError(
        "ScreenTextEntry \"MaxInputLength\" entry is not a number.");
    iMaxInputLength = ClampInputLength(iMaxInputLength);
  } else {
    iMaxInputLength = ClampInputLength(iMaxInputLength);
  }
  lua_settop(L, iTab);

  // Get Password
  lua_getfield(L, iTab, "Password");
  bPassword = !!lua_toboolean(L, -1);
  lua_settop(L, iTab);

#define SET_FUNCTION_MEMBER(memname)                            \
  lua_getfield(L, iTab, #memname);                              \
  if (lua_isfunction(L, -1)) {                                  \
    memname.SetFromStack(L);                                    \
  } else if (!lua_isnil(L, -1)) {                               \
    LuaHelpers::ReportScriptError(                              \
        "ScreenTextEntry \"" #memname "\" is not a function."); \
  }                                                             \
  lua_settop(L, iTab);

  SET_FUNCTION_MEMBER(Validate);
  SET_FUNCTION_MEMBER(OnOK);
  SET_FUNCTION_MEMBER(OnCancel);
  SET_FUNCTION_MEMBER(ValidateAppend);
  SET_FUNCTION_MEMBER(FormatAnswerForDisplay);
#undef SET_FUNCTION_MEMBER
}

void ScreenTextEntry::LoadFromTextEntrySettings(
    const TextEntrySettings& settings) {
  RuntimeSettings runtime;
  runtime.sQuestion = settings.sQuestion;
  runtime.sInitialAnswer = settings.sInitialAnswer;
  runtime.iMaxInputLength = ClampInputLength(settings.iMaxInputLength);
  runtime.bPassword = settings.bPassword;
  runtime.ValidateLua = settings.Validate;
  runtime.OnOKLua = settings.OnOK;
  runtime.OnCancelLua = settings.OnCancel;
  runtime.ValidateAppendLua = settings.ValidateAppend;
  runtime.FormatAnswerForDisplayLua = settings.FormatAnswerForDisplay;

  ApplySettings(runtime);
}

/** @brief Allow Lua to have access to the ScreenTextEntry. */
class LunaScreenTextEntry : public Luna<ScreenTextEntry> {
 public:
  static int Load(T* p, lua_State* L) {
    ScreenTextEntry::TextEntrySettings settings;
    settings.FromStack(L);
    p->LoadFromTextEntrySettings(settings);
    return 0;
  }

  LunaScreenTextEntry() { ADD_METHOD(Load); }
};
LUA_REGISTER_DERIVED_CLASS(ScreenTextEntry, ScreenWithMenuElements)
// lua end

// begin ScreenTextEntryVisual
ScreenTextEntryVisual::ScreenTextEntryVisual() : m_ptextKeys{} {}

void ScreenTextEntryVisual::Init() {
  if (HasLoadedTheme()) {
    ROW_START_X.Load(m_sName, "RowStartX");
    ROW_START_Y.Load(m_sName, "RowStartY");
    ROW_END_X.Load(m_sName, "RowEndX");
    ROW_END_Y.Load(m_sName, "RowEndY");
  }

  ScreenTextEntry::Init();

  if (HasLoadedTheme()) {
    m_sprCursor.Load(THEME->GetPathG(m_sName, "cursor", true));
    if (m_sprCursor.IsLoaded()) {
      m_sprCursor->SetName("Cursor");
      LOAD_ALL_COMMANDS(m_sprCursor);
      this->AddChild(m_sprCursor);
    }
  }

  // Init keyboard
  {
    BitmapText text;
    if (!HasLoadedTheme() ||
        !text.LoadFromFont(THEME->GetPathF(m_sName, "keyboard", true))) {
      return;
    }
    text.SetName("Keys");
    ActorUtil::LoadAllCommands(text, m_sName);
    text.PlayCommand("Init");
    m_bKeyboardReady = true;

    FOREACH_KeyboardRow(r) {
      for (int x = 0; x < KEYS_PER_ROW; ++x) {
        BitmapText*& pbt = m_ptextKeys[r][x];
        pbt = text.Copy();
        if (pbt == nullptr) {
          m_bKeyboardReady = false;
          continue;
        }
        this->AddChild(pbt);

        std::string s = g_szKeys[r][x];
        if (!s.empty() && r == KEYBOARD_ROW_SPECIAL && HasLoadedTheme()) {
          s = THEME->GetString(m_sName, s);
        }
        pbt->SetText(s);
      }
    }
  }

  if (HasLoadedTheme()) {
    m_sndChange.Load(THEME->GetPathS(m_sName, "change", true), true);
  }
}

ScreenTextEntryVisual::~ScreenTextEntryVisual() {
  FOREACH_KeyboardRow(r) for (int x = 0; x < KEYS_PER_ROW; ++x)
      RageUtil::SafeDelete(m_ptextKeys[r][x]);
}

void ScreenTextEntryVisual::BeginScreen() {
  ScreenTextEntry::BeginScreen();

  m_iFocusX = 0;
  m_iFocusY = (KeyboardRow)0;

  if (!m_bKeyboardReady) {
    return;
  }

  FOREACH_KeyboardRow(r) {
    for (int x = 0; x < KEYS_PER_ROW; ++x) {
      BitmapText* bt = m_ptextKeys[r][x];
      if (bt == nullptr) {
        continue;
      }
      float fX =
          std::round(SCALE(x, 0, KEYS_PER_ROW - 1, ROW_START_X, ROW_END_X));
      float fY =
          std::round(SCALE(r, 0, NUM_KeyboardRow - 1, ROW_START_Y, ROW_END_Y));
      bt->SetXY(fX, fY);
    }
  }

  PositionCursor();
}

void ScreenTextEntryVisual::PositionCursor() {
  if (!m_bKeyboardReady || !m_sprCursor.IsLoaded() ||
      !IsValidKeyboardRow(m_iFocusY) || m_iFocusX < 0 ||
      m_iFocusX >= KEYS_PER_ROW) {
    return;
  }
  BitmapText* bt = m_ptextKeys[m_iFocusY][m_iFocusX];
  if (bt == nullptr) {
    return;
  }
  m_sprCursor->SetXY(bt->GetX(), bt->GetY());
  m_sprCursor->PlayCommand(
      m_iFocusY == KEYBOARD_ROW_SPECIAL ? "SpecialKey" : "RegularKey");
}

void ScreenTextEntryVisual::TextEnteredDirectly() {
  if (!m_bKeyboardReady) {
    return;
  }
  // If the user enters text with a keyboard, jump to DONE, so enter ends the
  // screen.
  m_iFocusY = KEYBOARD_ROW_SPECIAL;
  m_iFocusX = DONE;

  PositionCursor();
}

void ScreenTextEntryVisual::MoveX(int iDir) {
  if (!m_bKeyboardReady || !IsValidKeyboardRow(m_iFocusY)) {
    return;
  }
  std::string sKey;
  for (int attempts = 0; attempts < KEYS_PER_ROW; ++attempts) {
    m_iFocusX += iDir;
    wrap(m_iFocusX, KEYS_PER_ROW);

    sKey = g_szKeys[m_iFocusY][m_iFocusX];
    if (!sKey.empty()) {
      m_sndChange.Play(true);
      PositionCursor();
      return;
    }
  }

  PlayInvalidSound();
}

void ScreenTextEntryVisual::MoveY(int iDir) {
  if (!m_bKeyboardReady) {
    return;
  }
  std::string sKey;
  for (int attempts = 0; attempts < NUM_KeyboardRow * KEYS_PER_ROW; ++attempts) {
    m_iFocusY = enum_add2(m_iFocusY, +iDir);
    wrap(*ConvertValue<int>(&m_iFocusY), NUM_KeyboardRow);

    // HACK: Round to nearest option so that we always stop
    // on KEYBOARD_ROW_SPECIAL.
    if (m_iFocusY == KEYBOARD_ROW_SPECIAL) {
      for (int i = 0; i < KEYS_PER_ROW; i++) {
        sKey = g_szKeys[m_iFocusY][m_iFocusX];
        if (!sKey.empty()) {
          break;
        }

        // UGLY: Probe one space to the left before looking to the right
        m_iFocusX += (i == 0) ? -1 : +1;
        wrap(m_iFocusX, KEYS_PER_ROW);
      }
    }

    sKey = g_szKeys[m_iFocusY][m_iFocusX];
    if (!sKey.empty()) {
      m_sndChange.Play(true);
      PositionCursor();
      return;
    }
  }

  PlayInvalidSound();
}

bool ScreenTextEntryVisual::MenuLeft(const InputEventPlus& input) {
  if (input.type != IET_FIRST_PRESS || IsTransitioning() ||
      m_fLockInputSecs > 0) {
    return false;
  }
  MoveX(-1);
  return true;
}
bool ScreenTextEntryVisual::MenuRight(const InputEventPlus& input) {
  if (input.type != IET_FIRST_PRESS || IsTransitioning() ||
      m_fLockInputSecs > 0) {
    return false;
  }
  MoveX(+1);
  return true;
}
bool ScreenTextEntryVisual::MenuUp(const InputEventPlus& input) {
  if (input.type != IET_FIRST_PRESS || IsTransitioning() ||
      m_fLockInputSecs > 0) {
    return false;
  }
  MoveY(-1);
  return true;
}
bool ScreenTextEntryVisual::MenuDown(const InputEventPlus& input) {
  if (input.type != IET_FIRST_PRESS || IsTransitioning() ||
      m_fLockInputSecs > 0) {
    return false;
  }
  MoveY(+1);
  return true;
}

bool ScreenTextEntryVisual::MenuStart(const InputEventPlus& input) {
  if (input.type != IET_FIRST_PRESS || IsTransitioning() ||
      m_fLockInputSecs > 0 || !m_bKeyboardReady ||
      !IsValidKeyboardRow(m_iFocusY) || m_iFocusX < 0 ||
      m_iFocusX >= KEYS_PER_ROW) {
    return false;
  }
  if (m_iFocusY == KEYBOARD_ROW_SPECIAL) {
    switch (m_iFocusX) {
      case SPACEBAR:
        TryAppendToAnswer(" ");
        break;
      case BACKSPACE:
        BackspaceInAnswer();
        break;
      case CANCEL:
        End(true);
        break;
      case DONE:
        End(false);
        break;
      default:
        return false;
    }
  } else {
    TryAppendToAnswer(g_szKeys[m_iFocusY][m_iFocusX]);
  }
  return true;
}

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
