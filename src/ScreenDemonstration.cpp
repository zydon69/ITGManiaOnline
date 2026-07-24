#include "ScreenDemonstration.h"

#include <algorithm>
#include <cmath>
#include <string>
#include <vector>

#include "GameConstantsAndTypes.h"
#include "GameManager.h"
#include "GameState.h"
#include "PlayerNumber.h"
#include "RageLog.h"
#include "RageUtil.h"
#include "RageUtil/RandomNumbers.h"
#include "Screen.h"
#include "ScreenAttract.h"
#include "ScreenGameplay.h"
#include "ScreenJukebox.h"
#include "ScreenMessage.h"
#include "SongManager.h"
#include "Style.h"
#include "ThemeManager.h"
#include "global.h"

namespace {

float GetSecondsToShow(const std::string& screenName) {
  constexpr float kFallbackSeconds = 25.0f;
  if (THEME == nullptr || !THEME->IsThemeLoaded() || LUA == nullptr ||
      !THEME->HasMetric(screenName, "SecondsToShow")) {
    return kFallbackSeconds;
  }

  float seconds = THEME->GetMetricF(screenName, "SecondsToShow");
  if (!std::isfinite(seconds) || seconds < 0.0f) {
    LOG->Warn(
        "%s SecondsToShow is invalid; using %.1f.",
        screenName.c_str(), kFallbackSeconds);
    return kFallbackSeconds;
  }
  return seconds;
}

std::vector<StyleType> GetAllowedStyleTypes(const std::string& screenName) {
  std::vector<StyleType> styleTypes;
  if (THEME == nullptr || !THEME->IsThemeLoaded() || LUA == nullptr ||
      !THEME->HasMetric(screenName, "AllowStyleTypes")) {
    return styleTypes;
  }

  std::vector<std::string> rawStyleTypes;
  split(THEME->GetMetric(screenName, "AllowStyleTypes"), ",", rawStyleTypes);
  for (std::string styleTypeName : rawStyleTypes) {
    Trim(styleTypeName);
    if (styleTypeName.empty()) {
      continue;
    }

    StyleType styleType = StringToStyleType(styleTypeName);
    if (styleType == StyleType_Invalid) {
      LOG->Warn(
          "ignoring invalid demonstration style type "
          "'%s'.",
          styleTypeName.c_str());
      continue;
    }
    styleTypes.push_back(styleType);
  }
  return styleTypes;
}

void AbortDemonstration(ScreenDemonstration* screen, ScreenMessage message) {
  screen->ClearMessageQueue();
  screen->PostScreenMessage(message, 0);
}

}  // namespace

REGISTER_SCREEN_CLASS(ScreenDemonstration);
ScreenDemonstration::ScreenDemonstration() { m_bDemonstration = true; }

void ScreenDemonstration::Init() {
  if (GAMESTATE == nullptr || GAMEMAN == nullptr) {
    LOG->Warn(
        "ScreenDemonstration cannot init without game "
        "state and game manager.");
    AbortDemonstration(this, SM_GoToNextScreen);
    return;
  }

  GAMESTATE->Reset();
  GAMESTATE->VisitAttractScreen(m_sName);
  ScreenAttract::SetAttractVolume(true);

  // Choose a Style
  {
    std::vector<StyleType> vStyleTypeAllow = GetAllowedStyleTypes(m_sName);

    std::vector<const Style*> vStylePossible;
    GAMEMAN->GetDemonstrationStylesForGame(
        GAMESTATE->m_pCurGame, vStylePossible);
    for (int i = static_cast<int>(vStylePossible.size()) - 1; i >= 0; i--) {
      const Style* style = vStylePossible[i];
      if (style == nullptr) {
        vStylePossible.erase(vStylePossible.begin() + i);
        continue;
      }

      bool bAllowThis = vStyleTypeAllow.empty() ||
                        find(
                            vStyleTypeAllow.begin(), vStyleTypeAllow.end(),
                            style->m_StyleType) != vStyleTypeAllow.end();
      if (!bAllowThis) {
        vStylePossible.erase(vStylePossible.begin() + i);
      }
    }

    if (vStylePossible.empty()) {
      LOG->Warn(
          "ScreenDemonstration has no valid style to "
          "use.");
      AbortDemonstration(this, SM_GoToNextScreen);
      return;
    }
    const Style* pStyle = vStylePossible[RandomInt(vStylePossible.size())];
    GAMESTATE->SetCurrentStyle(pStyle, PLAYER_INVALID);
  }

  GAMESTATE->m_PlayMode.Set(PLAY_MODE_REGULAR);

  ScreenJukebox::Init();

  if (GAMESTATE->m_pCurSong == nullptr)  // we didn't find a song.
  {
    AbortDemonstration(this, SM_GoToNextScreen);
    return;
  }

  ClearMessageQueue();  // remove all of the messages set in ScreenGameplay that
                        // drive "ready", "go", etc.

  GAMESTATE->m_bGameplayLeadIn.Set(false);

  m_DancingState = STATE_DANCING;
  this->PostScreenMessage(
      SM_BeginFadingOut,
      GetSecondsToShow(m_sName));  // TODO: Use MenuTimer instead?
}

void ScreenDemonstration::HandleScreenMessage(const ScreenMessage SM) {
  if (SM == SM_NotesEnded || SM == SM_BeginFadingOut) {
    if (!m_Out.IsTransitioning()) {
      m_Out.StartTransitioning(SM_GoToNextScreen);
    }
    return;
  } else if (SM == SM_LoseFocus) {
    ScreenAttract::SetAttractVolume(false);
  }
  ScreenJukebox::HandleScreenMessage(SM);
}

void ScreenDemonstration::Cancel(ScreenMessage smSendWhenDone) {
  ScreenAttract::SetAttractVolume(false);  // unmute attract sounds
  ScreenJukebox::Cancel(smSendWhenDone);
}

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
