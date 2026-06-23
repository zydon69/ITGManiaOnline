#include "ScreenAttract.h"

#include <algorithm>
#include <cmath>
#include <string>

#include "CharacterManager.h"
#include "GameInput.h"
#include "GameSoundManager.h"
#include "GameState.h"
#include "InputEventPlus.h"
#include "MemoryCardManager.h"
#include "NoteSkinManager.h"
#include "Preference.h"
#include "PrefsManager.h"
#include "RageLog.h"
#include "RageSoundManager.h"
#include "ScreenManager.h"
#include "ScreenMessage.h"
#include "ScreenWithMenuElements.h"
#include "SongManager.h"
#include "StatsManager.h"
#include "ThemeManager.h"
#include "ThemeMetric.h"

AutoScreenMessage(SM_GoToStartScreen);
ThemeMetric<bool> BACK_GOES_TO_START_SCREEN(
    "ScreenAttract", "BackGoesToStartScreen");
Preference<float> g_fSoundVolumeAttract("SoundVolumeAttract", 1.0f);

namespace {
void WarnAttract(const std::string& message) {
  if (LOG != nullptr) {
    LOG->Warn("ScreenAttract: %s", message.c_str());
  }
}

bool CanReadThemeMetrics() {
  return THEME != nullptr && THEME->IsThemeLoaded() && LUA != nullptr;
}

bool CanSafelyResetGameState() {
  return GAMESTATE != nullptr && THEME != nullptr && MEMCARDMAN != nullptr &&
         NOTESKIN != nullptr && SONGMAN != nullptr && STATSMAN != nullptr &&
         PREFSMAN != nullptr && CHARMAN != nullptr;
}

bool GetLoadedBoolMetric(const ThemeMetric<bool>& metric, bool fallback) {
  return metric.IsLoaded() ? metric.GetValue() : fallback;
}

void LoadBoolMetricIfPossible(
    ThemeMetric<bool>& metric, const std::string& screenName,
    const std::string& metricName) {
  if (!CanReadThemeMetrics() || screenName.empty()) {
    WarnAttract(
        "Skipping metric load for '" + metricName +
        "' because the theme runtime is not ready.");
    return;
  }

  metric.Load(screenName, metricName);
}

float GetAttractSoundVolume() {
  const float volume = g_fSoundVolumeAttract.Get();
  if (!std::isfinite(volume)) {
    WarnAttract("Ignoring non-finite SoundVolumeAttract preference.");
    return 1.0f;
  }

  return std::max(0.0f, std::min(volume, 16.0f));
}

bool IsScreenUsable(const std::string& screenName) {
  return SCREENMAN != nullptr && THEME != nullptr && THEME->IsThemeLoaded() &&
         !screenName.empty() && SCREENMAN->IsScreenNameValid(screenName);
}

std::string GetStartScreenName(const std::string& screenName) {
  if (!CanReadThemeMetrics() || screenName.empty()) {
    WarnAttract(
        "Cannot resolve start screen because theme metrics are unavailable.");
    return "";
  }

  return THEME->GetMetric(screenName, "StartScreen");
}

bool ShouldAllowAttractSound() {
  if (GAMESTATE == nullptr || PREFSMAN == nullptr) {
    WarnAttract(
        "Keeping attract sound enabled because game state or preferences are "
        "not initialized.");
    return true;
  }

  return GAMESTATE->IsTimeToPlayAttractSounds();
}

bool IsReadyForAttractInput(ScreenWithMenuElements* pScreen) {
  return pScreen != nullptr && !pScreen->IsTransitioning() &&
         !pScreen->IsInputLocked();
}
}  // namespace

REGISTER_SCREEN_CLASS(ScreenAttract);
void ScreenAttract::Init() {
  LoadBoolMetricIfPossible(RESET_GAME_STATE, m_sName, "ResetGameState");
  LoadBoolMetricIfPossible(ATTRACT_VOLUME, m_sName, "AttractVolume");
  ScreenWithMenuElements::Init();
}

void ScreenAttract::BeginScreen() {
  if (GetLoadedBoolMetric(RESET_GAME_STATE, false)) {
    if (!CanSafelyResetGameState()) {
      WarnAttract(
          "Skipping attract game-state reset because a required manager is "
          "not initialized.");
    } else {
      GAMESTATE->Reset();
    }
  }

  if (GAMESTATE != nullptr) {
    GAMESTATE->VisitAttractScreen(m_sName);
  } else {
    WarnAttract("Skipping attract visit because GAMESTATE is not initialized.");
  }

  ScreenAttract::SetAttractVolume(GetLoadedBoolMetric(ATTRACT_VOLUME, false));

  ScreenWithMenuElements::BeginScreen();
}

bool ScreenAttract::Input(const InputEventPlus& input) {
  if (ScreenWithMenuElements::Input(input)) {
    return true;
  }

  return AttractInput(input, this);
}

void ScreenAttract::SetAttractVolume(bool bInAttract) {
  if (SOUNDMAN == nullptr) {
    WarnAttract(
        "Cannot change attract volume because SOUNDMAN is not initialized.");
    return;
  }

  if (bInAttract) {
    if (ShouldAllowAttractSound()) {
      SOUNDMAN->SetVolumeOfNonCriticalSounds(GetAttractSoundVolume());
    } else {
      SOUNDMAN->SetVolumeOfNonCriticalSounds(0.0f);
    }
  } else {
    SOUNDMAN->SetVolumeOfNonCriticalSounds(1.0f);
  }
}

void ScreenAttract::Cancel(ScreenMessage smSendWhenDone) {
  if (LOG != nullptr) {
    LOG->Trace("ScreenAttract::AttractInput: begin fading to start screen");
  }

  SetAttractVolume(false);
  ScreenWithMenuElements::Cancel(smSendWhenDone);
}

bool ScreenAttract::AttractInput(
    const InputEventPlus& input, ScreenWithMenuElements* pScreen) {
  if (pScreen == nullptr) {
    return false;
  }

  if (input.type != IET_FIRST_PRESS) {
    return false;  // don't care
  }

  if (pScreen->IsInputLocked()) {
    return false;
  }

  switch (input.MenuI) {
    case GAME_BUTTON_BACK:
      if (!GetLoadedBoolMetric(BACK_GOES_TO_START_SCREEN, false)) {
        break;
      }
      [[fallthrough]];
    case GAME_BUTTON_START:
    case GAME_BUTTON_COIN:
      // If we're not in a game and there aren't enough credits to start,
      // eat the input and do nothing.
      if (GAMESTATE != nullptr && PREFSMAN != nullptr &&
          GAMESTATE->GetCoinMode() == CoinMode_Pay &&
          GAMESTATE->m_iCoins <
              std::max(1, PREFSMAN->m_iCoinsPerCredit.Get()) &&
          GAMESTATE->GetNumSidesJoined() == 0) {
        return true;
      }
      if (!IsReadyForAttractInput(pScreen)) {
        return false;
      }

      // HandleGlobalInputs() already played the coin sound. Don't play it
      // again.
      if (input.MenuI != GAME_BUTTON_COIN && SCREENMAN != nullptr) {
        SCREENMAN->PlayStartSound();
      }

      pScreen->Cancel(SM_GoToStartScreen);
      return true;
    default:
      break;
  }

  if (!IsReadyForAttractInput(pScreen)) {
    return false;
  }

  switch (input.MenuI) {
    case GAME_BUTTON_LEFT:
    case GAME_BUTTON_RIGHT:
      pScreen->PostScreenMessage(SM_BeginFadingOut, 0);
      return true;
    default:
      return false;
  }
}

void ScreenAttract::HandleScreenMessage(const ScreenMessage SM) {
  if (SM == SM_MenuTimer || SM == SM_BeginFadingOut) {
    if (!IsTransitioning()) {
      StartTransitioningScreen(SM_GoToNextScreen);
    }
  } else if (SM == SM_GoToStartScreen) {
    GoToStartScreen(m_sName);
    return;
  } else if (SM == SM_GoToNextScreen) {
    /* Look at the def of the screen we're going to; if it has a music theme
     * element and it's the same as the one we're playing now, don't stop.
     * However, if we're going to interrupt it when we fade in, stop the old
     * music before we fade out. */
    bool bMusicChanging = false;
    const std::string nextScreenName = GetNextScreenName();
    if (GetLoadedBoolMetric(PLAY_MUSIC, false) && CanReadThemeMetrics() &&
        IsScreenUsable(nextScreenName)) {
      bMusicChanging =
          THEME->GetPathS(m_sName, "music", true) !=
          THEME->GetPathS(nextScreenName, "music", true);
    }

    if (bMusicChanging && SOUND != nullptr) {
      SOUND->StopMusic();
    }
  } else if (SM == SM_LoseFocus) {
    ScreenAttract::SetAttractVolume(false);
  }

  ScreenWithMenuElements::HandleScreenMessage(SM);
}

void ScreenAttract::GoToStartScreen(const std::string& sScreenName) {
  const std::string startScreenName = GetStartScreenName(sScreenName);
  if (!IsScreenUsable(startScreenName)) {
    WarnAttract("Ignoring invalid start screen '" + startScreenName + "'.");
    return;
  }

  SCREENMAN->SetNewScreen(startScreenName);
}

// lua start
#include "LuaBinding.h"

/** @brief Allow Lua to have access to the ScreenAttract. */
class LunaScreenAttract : public Luna<ScreenAttract> {
 public:
  LunaScreenAttract() {}
};

LUA_REGISTER_DERIVED_CLASS(ScreenAttract, ScreenWithMenuElements)
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
