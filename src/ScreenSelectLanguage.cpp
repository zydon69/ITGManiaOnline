#include "ScreenSelectLanguage.h"

#include <algorithm>
#include <string>
#include <vector>

#include "GameCommand.h"
#include "InputEventPlus.h"
#include "PrefsManager.h"
#include "RageLog.h"
#include "RageUtil.h"
#include "RageUtil/LanguageInfo.h"
#include "Screen.h"
#include "ScreenMessage.h"
#include "ScreenSelectMaster.h"
#include "SpecialFiles.h"
#include "ThemeManager.h"
#include "arch/ArchHooks/ArchHooks.h"

REGISTER_SCREEN_CLASS(ScreenSelectLanguage);

namespace {
void WarnScreenSelectLanguage(const std::string& message) {
  if (LOG != nullptr) {
    LOG->Warn("ScreenSelectLanguage: %s", message.c_str());
  }
}

std::vector<std::string> GetAvailableLanguages() {
  std::vector<std::string> languages;
  if (THEME == nullptr) {
    WarnScreenSelectLanguage("Cannot read languages without THEME.");
    return languages;
  }

  THEME->GetLanguages(languages);
  SortRStringArray(languages, true);
  languages.erase(
      std::remove_if(
          languages.begin(), languages.end(),
          [](const std::string& language) { return language.empty(); }),
      languages.end());
  return languages;
}

std::string FindLanguage(
    const std::vector<std::string>& languages, const std::string& requested) {
  if (requested.empty()) {
    return "";
  }

  const std::vector<std::string>::const_iterator match =
      std::find_if(languages.begin(), languages.end(), [&](const std::string& s) {
        return CompareNoCase(s, requested) == 0;
      });
  return match == languages.end() ? "" : *match;
}

std::string GetLanguageDisplayText(const std::string& language) {
  const LanguageInfo* pLI = GetLanguageInfo(language);
  if (pLI == nullptr) {
    return language;
  }

  std::string text;
  if (THEME != nullptr) {
    text = THEME->GetString("NativeLanguageNames", pLI->szEnglishName);
  }
  if (text.empty()) {
    text = pLI->szEnglishName;
  }
  if (text.empty()) {
    text = language;
  }
  return text;
}

std::string GetBestLanguageChoice(const std::vector<std::string>& languages) {
  if (languages.empty()) {
    return "";
  }

  std::vector<std::string> candidates;
  if (THEME != nullptr) {
    candidates.push_back(THEME->GetCurLanguage());
  }
  if (PREFSMAN != nullptr) {
    candidates.push_back(PREFSMAN->m_sLanguage);
  }
  if (HOOKS != nullptr) {
    candidates.push_back(HOOKS->GetPreferredLanguage());
  }
  candidates.push_back(SpecialFiles::BASE_LANGUAGE);

  for (const std::string& candidate : candidates) {
    const std::string match = FindLanguage(languages, candidate);
    if (!match.empty()) {
      return match;
    }
  }

  return languages.front();
}
}  // namespace

void ScreenSelectLanguage::Init() {
  // fill m_aGameCommands before calling Init()
  m_aGameCommands.clear();
  const std::vector<std::string> languages = GetAvailableLanguages();
  if (languages.empty()) {
    WarnScreenSelectLanguage("No selectable languages were found.");
  }

  int index = 0;
  for (const std::string& s : languages) {
    GameCommand gc;
    gc.m_iIndex = index++;
    gc.m_sName = s;
    gc.m_bInvalid = false;
    gc.m_sText = GetLanguageDisplayText(s);

    m_aGameCommands.push_back(gc);
  }

  ScreenSelectMaster::Init();
}

std::string ScreenSelectLanguage::GetDefaultChoice() {
  return GetBestLanguageChoice(GetAvailableLanguages());
}

void ScreenSelectLanguage::BeginScreen() { ScreenSelectMaster::BeginScreen(); }

bool ScreenSelectLanguage::MenuStart(const InputEventPlus& input) {
  if (IsTransitioning() || m_fLockInputSecs > 0.0f) {
    return false;
  }
  if (input.type != IET_FIRST_PRESS) {
    return false;
  }
  if (!IsValidPlayer(input.pn) || !AnyOptionsArePlayable()) {
    return false;
  }
  if (PREFSMAN == nullptr || THEME == nullptr) {
    WarnScreenSelectLanguage("Cannot apply language without PREFSMAN and THEME.");
    return false;
  }

  const int iIndex = this->GetSelectionIndex(input.pn);
  if (!IsValidChoice(iIndex) || !m_aGameCommands[iIndex].IsPlayable()) {
    WarnScreenSelectLanguage("Ignoring start on an invalid language choice.");
    return false;
  }

  const std::string sLangCode =
      FindLanguage(GetAvailableLanguages(), m_aGameCommands[iIndex].m_sName);
  if (sLangCode.empty()) {
    WarnScreenSelectLanguage(
        "Ignoring start on a language that is no longer available.");
    return false;
  }

  if (THEME->GetCurLanguage() != sLangCode) {
    THEME->SwitchThemeAndLanguage(
        THEME->GetCurThemeName(), sLangCode, PREFSMAN->m_bPseudoLocalize);
  }
  PREFSMAN->m_sLanguage.Set(sLangCode);
  if (!PREFSMAN->SavePrefsToDisk()) {
    WarnScreenSelectLanguage("Failed to save language preference to disk.");
    return false;
  }

  if (m_soundStart.IsLoaded()) {
    m_soundStart.Play(true);
  }
  this->PostScreenMessage(SM_BeginFadingOut, 0);
  return true;
}

bool ScreenSelectLanguage::MenuBack(const InputEventPlus& input) {
  if (IsTransitioning() || m_fLockInputSecs > 0.0f) {
    return false;
  }
  return ScreenSelect::MenuBack(input);
}

/*
 * (c) 2006 Chris Danford
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
