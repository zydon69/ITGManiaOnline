#include "ScreenPrompt.h"

#include <algorithm>
#include <deque>
#include <string>

#include "Actor.h"
#include "ActorUtil.h"
#include "BitmapText.h"
#include "EnumHelper.h"
#include "GameSoundManager.h"
#include "InputEventPlus.h"
#include "InputFilter.h"
#include "RageLog.h"
#include "RageInputDevice.h"
#include "RageUtil.h"
#include "Screen.h"
#include "ScreenManager.h"
#include "ScreenMessage.h"
#include "ScreenWithMenuElements.h"
#include "ThemeManager.h"
#include "global.h"

PromptAnswer ScreenPrompt::s_LastAnswer = ANSWER_YES;
bool ScreenPrompt::s_bCancelledLast = false;

static const char* PromptAnswerNames[] = {
    "Yes",
    "No",
    "Cancel",
};
XToString(PromptAnswer);

// Settings:
namespace {
struct PromptSettings {
  PromptSettings()
      : text(),
        type(PROMPT_OK),
        defaultAnswer(ANSWER_YES),
        onYes(nullptr),
        onNo(nullptr),
        callbackData(nullptr),
        reverseYesNoOrder(false) {}

  std::string text;
  PromptType type;
  PromptAnswer defaultAnswer;
  void (*onYes)(void*);
  void (*onNo)(void*);
  void* callbackData;
  bool reverseYesNoOrder;
};

PromptSettings g_PromptSettings;
std::deque<PromptSettings> g_PendingPromptSettings;

void WarnScreenPrompt(const char* message) {
  if (LOG != nullptr) {
    LOG->Warn("SRC_AUDIT_FIX ScreenPrompt: %s", message);
  }
}

bool IsPromptTypeValid(PromptType type) {
  return type >= PROMPT_OK && type <= PROMPT_YES_NO_CANCEL;
}

bool IsPromptAnswerValid(PromptAnswer answer) {
  return answer >= ANSWER_YES && answer < NUM_PromptAnswer;
}

PromptType SanitizePromptType(PromptType type) {
  if (!IsPromptTypeValid(type)) {
    WarnScreenPrompt(
        ssprintf("invalid PromptType %d; using PROMPT_OK.", type).c_str());
    return PROMPT_OK;
  }
  return type;
}

int GetPromptAnswerCount(PromptType type) {
  switch (SanitizePromptType(type)) {
    case PROMPT_OK:
      return 1;
    case PROMPT_YES_NO:
      return 2;
    case PROMPT_YES_NO_CANCEL:
      return 3;
    default:
      return 1;
  }
}

PromptAnswer SanitizePromptAnswer(PromptAnswer answer, PromptType type) {
  if (!IsPromptAnswerValid(answer)) {
    WarnScreenPrompt(
        ssprintf("invalid PromptAnswer %d; using first answer.", answer)
            .c_str());
    return ANSWER_YES;
  }

  const int maxAnswer = GetPromptAnswerCount(type) - 1;
  if (answer > maxAnswer) {
    return static_cast<PromptAnswer>(maxAnswer);
  }
  return answer;
}

PromptSettings MakePromptSettings(
    const std::string& text, PromptType type, PromptAnswer defaultAnswer,
    void (*onYes)(void*), void (*onNo)(void*), void* callbackData,
    bool reverseYesNoOrder) {
  PromptSettings settings;
  settings.text = text;
  settings.type = SanitizePromptType(type);
  settings.defaultAnswer =
      SanitizePromptAnswer(defaultAnswer, settings.type);
  settings.onYes = onYes;
  settings.onNo = onNo;
  settings.callbackData = callbackData;
  settings.reverseYesNoOrder =
      settings.type == PROMPT_YES_NO && reverseYesNoOrder;
  return settings;
}

std::string GetThemeFontPath(
    const std::string& group, const std::string& element) {
  if (THEME == nullptr || !THEME->IsThemeLoaded()) {
    return "";
  }
  return THEME->GetPathF(group, element, true);
}

std::string GetThemeGraphicPath(
    const std::string& group, const std::string& element) {
  if (THEME == nullptr || !THEME->IsThemeLoaded()) {
    return "";
  }
  return THEME->GetPathG(group, element, true);
}

std::string GetThemeSoundPath(
    const std::string& group, const std::string& element) {
  if (THEME == nullptr || !THEME->IsThemeLoaded()) {
    return "";
  }
  return THEME->GetPathS(group, element, true);
}

bool LoadFontWithFallback(
    BitmapText& text, const std::string& group, const std::string& element) {
  const std::string requestedFont = GetThemeFontPath(group, element);
  if (!requestedFont.empty() && text.LoadFromFont(requestedFont)) {
    return true;
  }

  const std::string fallbackFont = GetThemeFontPath("Common", "normal");
  if (!fallbackFont.empty() && text.LoadFromFont(fallbackFont)) {
    return true;
  }

  WarnScreenPrompt(
      ssprintf("failed to load font %s/%s.", group.c_str(), element.c_str())
          .c_str());
  return false;
}
};  // namespace

void ScreenPrompt::SetPromptSettings(
    const std::string& sText, PromptType type, PromptAnswer defaultAnswer,
    void (*OnYes)(void*), void (*OnNo)(void*), void* pCallbackData,
    bool reverseYesNoOrder) {
  g_PromptSettings = MakePromptSettings(
      sText, type, defaultAnswer, OnYes, OnNo, pCallbackData,
      reverseYesNoOrder);
}

void ScreenPrompt::Prompt(
    ScreenMessage smSendOnPop, const std::string& sText, PromptType type,
    PromptAnswer defaultAnswer, void (*OnYes)(void*), void (*OnNo)(void*),
    void* pCallbackData, bool reverseYesNoOrder) {
  PromptSettings settings = MakePromptSettings(
      sText, type, defaultAnswer, OnYes, OnNo, pCallbackData,
      reverseYesNoOrder);
  g_PromptSettings = settings;

  if (SCREENMAN == nullptr) {
    WarnScreenPrompt("Prompt refused without SCREENMAN.");
    return;
  }
  if (THEME == nullptr || !THEME->IsThemeLoaded() ||
      !SCREENMAN->IsScreenNameValid("ScreenPrompt")) {
    WarnScreenPrompt("Prompt refused because ScreenPrompt is not usable.");
    return;
  }

  g_PendingPromptSettings.push_back(settings);
  SCREENMAN->AddNewScreenToTop("ScreenPrompt", smSendOnPop);
}

REGISTER_SCREEN_CLASS(ScreenPrompt);

ScreenPrompt::ScreenPrompt()
    : m_textQuestion(),
      m_sprCursor(),
      m_textAnswer(),
      m_Answer(ANSWER_YES),
      m_PromptType(PROMPT_OK),
      m_bReverseYesNoOrder(false),
      m_bPromptActorsLoaded(false),
      m_sPromptText(),
      m_pOnYes(nullptr),
      m_pOnNo(nullptr),
      m_pCallbackData(nullptr),
      m_sndChange() {}

void ScreenPrompt::Init() {
  if (THEME == nullptr || !THEME->IsThemeLoaded()) {
    WarnScreenPrompt("Init skipped without loaded THEME.");
    return;
  }

  ScreenWithMenuElements::Init();

  if (m_bPromptActorsLoaded) {
    return;
  }
  m_bPromptActorsLoaded = true;

  LoadFontWithFallback(m_textQuestion, m_sName, "question");
  m_textQuestion.SetName("Question");
  LOAD_ALL_COMMANDS(m_textQuestion);
  this->AddChild(&m_textQuestion);

  const std::string cursorPath = GetThemeGraphicPath(m_sName, "cursor");
  if (!cursorPath.empty()) {
    m_sprCursor.Load(cursorPath);
  } else {
    WarnScreenPrompt("using blank cursor actor.");
    m_sprCursor.LoadFallback();
  }
  m_sprCursor->SetName("Cursor");
  LOAD_ALL_COMMANDS(m_sprCursor);
  this->AddChild(m_sprCursor);

  for (int i = 0; i < NUM_PromptAnswer; i++) {
    LoadFontWithFallback(m_textAnswer[i], m_sName, "answer");
    // The name of the actor isn't set because it is not known at this point
    // how many answers there will be, and the name depends on the number of
    // answers as a clumsy way of letting the themer set different positions
    // for different answer groups.  The name is set in BeginScreen, and
    // then the commands are loaded. -Kyz (At least, that seems like the
    // explanation to me, reading the code years after the author left)
    this->AddChild(&m_textAnswer[i]);
  }

  const std::string changeSound = GetThemeSoundPath(m_sName, "change");
  if (!changeSound.empty()) {
    m_sndChange.Load(changeSound, true);
  }
}

void ScreenPrompt::BeginScreen() {
  ScreenWithMenuElements::BeginScreen();

  PromptSettings settings = g_PromptSettings;
  if (!g_PendingPromptSettings.empty()) {
    settings = g_PendingPromptSettings.front();
    g_PendingPromptSettings.pop_front();
  }

  m_sPromptText = settings.text;
  m_PromptType = SanitizePromptType(settings.type);
  m_bReverseYesNoOrder =
      m_PromptType == PROMPT_YES_NO && settings.reverseYesNoOrder;
  m_pOnYes = settings.onYes;
  m_pOnNo = settings.onNo;
  m_pCallbackData = settings.callbackData;
  m_Answer = SanitizePromptAnswer(settings.defaultAnswer, m_PromptType);

  m_textQuestion.SetText(m_sPromptText);
  SET_XY(m_textQuestion);
  m_textQuestion.PlayCommand("On");

  if (m_sprCursor.IsLoaded()) {
    m_sprCursor->PlayCommand("On");
  }

  const int numAnswers = GetNumAnswers();
  for (int i = 0; i < numAnswers; i++) {
    int displayIndex = i + 1;
    if (IsYesNoOrderReversed()) {
      displayIndex = i == ANSWER_YES ? 2 : 1;
    }

    std::string sElem =
        ssprintf("Answer%dOf%d", displayIndex, numAnswers);
    m_textAnswer[i].SetName(sElem);
    m_textAnswer[i].SetVisible(true);
    LOAD_ALL_COMMANDS(m_textAnswer[i]);
    // Side note:  Because LOAD_ALL_COMMANDS occurs here, InitCommand will
    // not be run for the actors.  People can just use OnCommand instead.
    std::string sAnswer = PromptAnswerToString((PromptAnswer)i);
    // FRAGILE
    if (m_PromptType == PROMPT_OK) {
      sAnswer = "OK";
    }

    m_textAnswer[i].SetText(GetAnswerText(sAnswer));
    m_textAnswer[i].PlayCommand("On");
    SET_XY(m_textAnswer[i]);
  }

  for (int i = numAnswers; i < NUM_PromptAnswer; i++) {
    m_textAnswer[i].StopTweening();
    m_textAnswer[i].StopEffect();
    m_textAnswer[i].SetName(ssprintf("UnusedAnswer%d", i + 1));
    m_textAnswer[i].SetText("");
    m_textAnswer[i].SetVisible(false);
  }

  PositionCursor();
}

bool ScreenPrompt::Input(const InputEventPlus& input) {
  if (IsTransitioning()) {
    return true;
  }

  if (input.type == IET_RELEASE) {
    return false;
  }

  if (input.DeviceI.device == DEVICE_KEYBOARD) {
    switch (input.DeviceI.button) {
      case KEY_LEFT:
        return this->MenuLeft(input);
      case KEY_RIGHT:
        return this->MenuRight(input);
      default:
        break;
    }
  }

  return ScreenWithMenuElements::Input(input);
}

bool ScreenPrompt::CanGoLeft() const {
  return IsPromptAnswerValid(m_Answer) && m_Answer > ANSWER_YES &&
         m_Answer < GetNumAnswers();
}

bool ScreenPrompt::CanGoRight() {
  if (!IsPromptAnswerValid(m_Answer)) {
    WarnScreenPrompt(
        ssprintf("invalid current answer %d while moving right.", m_Answer)
            .c_str());
    m_Answer = SanitizePromptAnswer(m_Answer, m_PromptType);
  }

  if (IsYesNoOrderReversed()) {
    return m_Answer == ANSWER_NO;
  }

  return m_Answer < GetNumAnswers() - 1;
}

bool ScreenPrompt::IsYesNoOrderReversed() const {
  return m_PromptType == PROMPT_YES_NO && m_bReverseYesNoOrder;
}

int ScreenPrompt::GetNumAnswers() const {
  return GetPromptAnswerCount(m_PromptType);
}

std::string ScreenPrompt::GetAnswerText(const std::string& sAnswer) const {
  if (THEME == nullptr || !THEME->IsThemeLoaded() || m_sName.empty() ||
      sAnswer.empty()) {
    return sAnswer;
  }

  if (!THEME->HasString(m_sName, sAnswer)) {
    WarnScreenPrompt(
        ssprintf(
            "missing localized string %s/%s; using key as fallback.",
            m_sName.c_str(), sAnswer.c_str())
            .c_str());
    return sAnswer;
  }

  const std::string localizedAnswer = THEME->GetString(m_sName, sAnswer);
  if (localizedAnswer.empty()) {
    WarnScreenPrompt(
        ssprintf(
            "empty localized string %s/%s; using key as fallback.",
            m_sName.c_str(), sAnswer.c_str())
            .c_str());
    return sAnswer;
  }
  return localizedAnswer;
}

void ScreenPrompt::Change(int dir) {
  m_Answer = SanitizePromptAnswer(m_Answer, m_PromptType);
  m_textAnswer[m_Answer].StopEffect();

  if (IsYesNoOrderReversed()) {
    m_Answer = dir < 0 ? ANSWER_NO : ANSWER_YES;
  } else {
    const int newAnswer = std::max(
        static_cast<int>(ANSWER_YES),
        std::min(GetNumAnswers() - 1, static_cast<int>(m_Answer) + dir));
    m_Answer = static_cast<PromptAnswer>(newAnswer);
  }

  PositionCursor();

  m_sndChange.Play(true);
}

bool ScreenPrompt::MenuLeft(const InputEventPlus& input) {
  if ((IsYesNoOrderReversed() && m_Answer == ANSWER_YES) ||
      (!IsYesNoOrderReversed() && CanGoLeft())) {
    Change(-1);
    return true;
  }
  return false;
}

bool ScreenPrompt::MenuRight(const InputEventPlus& input) {
  if (CanGoRight()) {
    Change(+1);
    return true;
  }
  return false;
}

bool ScreenPrompt::MenuStart(const InputEventPlus& input) {
  if (IsTransitioning()) {
    return false;
  }

  End(false);
  return true;
}

bool ScreenPrompt::MenuBack(const InputEventPlus& input) {
  if (IsTransitioning()) {
    return false;
  }

  switch (m_PromptType) {
    case PROMPT_OK:
    case PROMPT_YES_NO:
      // don't allow cancel
      break;
    case PROMPT_YES_NO_CANCEL:
      m_Answer = ANSWER_CANCEL;
      End(true);
      return true;
    default:
      WarnScreenPrompt(
          ssprintf("invalid PromptType %d while cancelling.", m_PromptType)
              .c_str());
      break;
  }
  return false;
}

void ScreenPrompt::End(bool bCancelled) {
  const PromptAnswer finalAnswer = bCancelled
                                       ? ANSWER_CANCEL
                                       : SanitizePromptAnswer(m_Answer,
                                                              m_PromptType);
  m_Answer = finalAnswer;

  switch (finalAnswer) {
    case ANSWER_YES:
      m_smSendOnPop = SM_Success;
      break;
    case ANSWER_NO:
      m_smSendOnPop = SM_Failure;
      break;
    case ANSWER_CANCEL:
      m_smSendOnPop = SM_None;
      break;
    default:
      m_smSendOnPop = SM_None;
      break;
  }

  s_LastAnswer = finalAnswer;
  s_bCancelledLast = bCancelled;

  void (*onYes)(void*) = m_pOnYes;
  void (*onNo)(void*) = m_pOnNo;
  void* callbackData = m_pCallbackData;
  m_pOnYes = nullptr;
  m_pOnNo = nullptr;
  m_pCallbackData = nullptr;

  if (bCancelled) {
    Cancel(SM_GoToNextScreen);
  } else {
    if (SCREENMAN != nullptr) {
      SCREENMAN->PlayStartSound();
    } else {
      WarnScreenPrompt("validated prompt without SCREENMAN.");
    }
    StartTransitioningScreen(SM_GoToNextScreen);
  }

  if (bCancelled) {
    return;
  }

  switch (finalAnswer) {
    case ANSWER_YES:
      if (onYes != nullptr) {
        onYes(callbackData);
      }
      break;
    case ANSWER_NO:
      if (onNo != nullptr) {
        onNo(callbackData);
      }
      break;
    default:
      break;
  }
}

void ScreenPrompt::PositionCursor() {
  m_Answer = SanitizePromptAnswer(m_Answer, m_PromptType);
  if (m_Answer >= GetNumAnswers()) {
    m_Answer = static_cast<PromptAnswer>(GetNumAnswers() - 1);
  }
  if (!m_sprCursor.IsLoaded()) {
    return;
  }

  BitmapText& bt = m_textAnswer[m_Answer];
  m_sprCursor->SetXY(bt.GetX(), bt.GetY());
}

void ScreenPrompt::TweenOffScreen() {
  m_textQuestion.PlayCommand("Off");
  if (m_sprCursor.IsLoaded()) {
    m_sprCursor->PlayCommand("Off");
  }
  for (int i = 0; i < NUM_PromptAnswer; i++) {
    m_textAnswer[i].PlayCommand("Off");
  }

  ScreenWithMenuElements::TweenOffScreen();
}

// lua start
/*
#include "LuaBinding.h"

 // use proper doxygen when lua is enabled.
 @brief Allow Lua to have access to the ScreenPrompt.
class LunaScreenPrompt: public Luna<ScreenPrompt>
{
public:

        LunaScreenPrompt()
        {

        }
};
LUA_REGISTER_DERIVED_CLASS( ScreenPrompt, ScreenWithMenuElements )
*/
// lua end

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
