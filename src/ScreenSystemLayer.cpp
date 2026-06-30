#include "ScreenSystemLayer.h"

#include <algorithm>
#include <string>

#include "Actor.h"
#include "EnumHelper.h"
#include "GameConstantsAndTypes.h"
#include "GameManager.h"
#include "GameState.h"
#include "LocalizedString.h"
#include "LuaManager.h"
#include "MemoryCardManager.h"
#include "PlayerNumber.h"
#include "PrefsManager.h"
#include "Profile.h"
#include "ProfileManager.h"
#include "RageLog.h"
#include "RageUtil.h"
#include "Screen.h"
#include "ScreenManager.h"
#include "ThemeManager.h"
#include "ThemeMetric.h"
#include "global.h"

namespace {
LocalizedString CREDITS_PRESS_START("ScreenSystemLayer", "CreditsPressStart");
LocalizedString CREDITS_INSERT_CARD("ScreenSystemLayer", "CreditsInsertCard");
LocalizedString CREDITS_CARD_TOO_LATE(
    "ScreenSystemLayer", "CreditsCardTooLate");
LocalizedString CREDITS_CARD_NO_NAME("ScreenSystemLayer", "CreditsCardNoName");
LocalizedString CREDITS_CARD_READY("ScreenSystemLayer", "CreditsCardReady");
LocalizedString CREDITS_CARD_CHECKING(
    "ScreenSystemLayer", "CreditsCardChecking");
LocalizedString CREDITS_CARD_ERROR("ScreenSystemLayer", "CreditsCardError");
LocalizedString CREDITS_CARD_REMOVED("ScreenSystemLayer", "CreditsCardRemoved");
LocalizedString CREDITS_FREE_PLAY("ScreenSystemLayer", "CreditsFreePlay");
LocalizedString CREDITS_CREDITS("ScreenSystemLayer", "CreditsCredits");
LocalizedString CREDITS_MAX("ScreenSystemLayer", "CreditsMax");
LocalizedString CREDITS_NOT_PRESENT("ScreenSystemLayer", "CreditsNotPresent");
LocalizedString CREDITS_PLEASE_WAIT("ScreenSystemLayer", "CreditsPleaseWait");
LocalizedString CREDITS_LOAD_FAILED("ScreenSystemLayer", "CreditsLoadFailed");
LocalizedString CREDITS_LOADED_FROM_LAST_GOOD_APPEND(
    "ScreenSystemLayer", "CreditsLoadedFromLastGoodAppend");

ThemeMetric<bool> CREDITS_JOIN_ONLY("ScreenSystemLayer", "CreditsJoinOnly");

bool IsValidCreditPlayer(PlayerNumber pn) {
  return pn >= PLAYER_1 && pn < NUM_PLAYERS;
}

void WarnSystemLayer(const std::string& message) {
  if (LOG != nullptr) {
    LOG->Warn("ScreenSystemLayer: %s", message.c_str());
  }
}

bool HasCreditRuntime() {
  return GAMESTATE != nullptr && MEMCARDMAN != nullptr &&
         PROFILEMAN != nullptr && PREFSMAN != nullptr;
}

bool PlayersCanJoinForCredits() {
  if (GAMESTATE == nullptr) {
    return false;
  }
  if (GAMESTATE->GetNumSidesJoined() == 0) {
    return true;
  }
  if (SCREENMAN == nullptr || GAMEMAN == nullptr) {
    return false;
  }
  return GAMESTATE->PlayersCanJoin();
}

std::string GetProfileDisplayName(const Profile* profile) {
  if (profile == nullptr) {
    return CREDITS_CARD_NO_NAME.GetValue();
  }

  std::string name = profile->GetDisplayNameOrHighScoreName();
  return name.empty() ? CREDITS_CARD_NO_NAME.GetValue() : name;
}

std::string GetCardErrorMessage(PlayerNumber pn) {
  const std::string card_error =
      MEMCARDMAN != nullptr ? MEMCARDMAN->GetCardError(pn) : std::string();
  if (!card_error.empty() && THEME != nullptr && THEME->IsThemeLoaded()) {
    const std::string key = "CreditsCard" + card_error;
    if (THEME->HasString("ScreenSystemLayer", key)) {
      return THEME->GetString("ScreenSystemLayer", key);
    }
    WarnSystemLayer("missing localized card error string '" + key + "'.");
  }
  return CREDITS_CARD_ERROR.GetValue();
}

std::string GetPayCreditsMessage() {
  int coins_per_credit = PREFSMAN->m_iCoinsPerCredit.Get();
  if (coins_per_credit <= 0) {
    WarnSystemLayer("invalid CoinsPerCredit; displaying credits with fallback 1.");
    coins_per_credit = 1;
  }

  const int max_credits = std::max(PREFSMAN->m_iMaxNumCredits.Get(), 1);
  const int coins = std::max(GAMESTATE->m_iCoins.Get(), 0);
  const int raw_credits = coins / coins_per_credit;
  const int iCredits = std::min(raw_credits, max_credits);
  const int iCoins = coins % coins_per_credit;

  std::string sCredits = CREDITS_CREDITS.GetValue();
  if (iCredits > 0 || coins_per_credit == 1) {
    sCredits += ssprintf("  %d", iCredits);
  }
  if (coins_per_credit > 1) {
    sCredits += ssprintf("  %d/%d", iCoins, coins_per_credit);
  }
  if (raw_credits >= max_credits) {
    sCredits += "  " + CREDITS_MAX.GetValue();
  }
  return sCredits;
}

std::string GetCreditsMessage(PlayerNumber pn) {
  if (!IsValidCreditPlayer(pn)) {
    WarnSystemLayer(ssprintf("ignored invalid player %d.", pn));
    return std::string();
  }

  if (!HasCreditRuntime()) {
    WarnSystemLayer("ignored credits message without complete runtime state.");
    return std::string();
  }

  const bool players_can_join = PlayersCanJoinForCredits();
  if (CREDITS_JOIN_ONLY.IsLoaded() && CREDITS_JOIN_ONLY.GetValue() &&
      !players_can_join) {
    return std::string();
  }

  bool bShowCreditsMessage;
  Screen* top_screen = SCREENMAN != nullptr ? SCREENMAN->GetTopScreen() : nullptr;
  if (top_screen != nullptr && top_screen->GetScreenType() == system_menu) {
    bShowCreditsMessage = true;
  } else if (MEMCARDMAN->GetCardLocked(pn)) {
    bShowCreditsMessage = !GAMESTATE->IsPlayerEnabled(pn);
  } else {
    bShowCreditsMessage = !GAMESTATE->m_bSideIsJoined[pn];
  }

  if (!bShowCreditsMessage) {
    MemoryCardState mcs = MEMCARDMAN->GetCardState(pn);
    const Profile* pProfile = PROFILEMAN->GetProfile(pn);
    switch (mcs) {
      case MemoryCardState_NoCard:
        // this is a local machine profile
        if (PROFILEMAN->LastLoadWasFromLastGood(pn)) {
          return GetProfileDisplayName(pProfile) +
                 CREDITS_LOADED_FROM_LAST_GOOD_APPEND.GetValue();
        } else if (PROFILEMAN->LastLoadWasTamperedOrCorrupt(pn)) {
          return CREDITS_LOAD_FAILED.GetValue();
        }
        // Prefer the name of the profile over the name of the card.
        else if (PROFILEMAN->IsPersistentProfile(pn)) {
          return GetProfileDisplayName(pProfile);
        } else if (players_can_join) {
          return CREDITS_INSERT_CARD.GetValue();
        } else {
          return std::string();
        }

      case MemoryCardState_Error:
        return GetCardErrorMessage(pn);
      case MemoryCardState_TooLate:
        return CREDITS_CARD_TOO_LATE.GetValue();
      case MemoryCardState_Checking:
        return CREDITS_CARD_CHECKING.GetValue();
      case MemoryCardState_Removed:
        return CREDITS_CARD_REMOVED.GetValue();
      case MemoryCardState_Ready: {
        // If the profile failed to load and there was no usable backup...
        if (PROFILEMAN->LastLoadWasTamperedOrCorrupt(pn) &&
            !PROFILEMAN->LastLoadWasFromLastGood(pn)) {
          return CREDITS_LOAD_FAILED.GetValue();
        }

        // If there is a local profile loaded, prefer it over the name of the
        // memory card.
        if (PROFILEMAN->IsPersistentProfile(pn)) {
          std::string s = GetProfileDisplayName(pProfile);
          if (PROFILEMAN->LastLoadWasFromLastGood(pn)) {
            s += CREDITS_LOADED_FROM_LAST_GOOD_APPEND.GetValue();
          }
          return s;
        } else if (!MEMCARDMAN->IsNameAvailable(pn)) {
          return CREDITS_CARD_READY.GetValue();
        } else if (!MEMCARDMAN->GetName(pn).empty()) {
          return MEMCARDMAN->GetName(pn);
        } else {
          return CREDITS_CARD_NO_NAME.GetValue();
        }
      }
      case NUM_MemoryCardState:
      case MemoryCardState_Invalid:
      default:
        WarnSystemLayer(ssprintf("ignored invalid memory card state %d.", mcs));
        return std::string();
    }
  } else  // bShowCreditsMessage
  {
    switch (GAMESTATE->GetCoinMode()) {
      case CoinMode_Home:
        if (players_can_join) {
          return CREDITS_PRESS_START.GetValue();
        } else {
          return CREDITS_NOT_PRESENT.GetValue();
        }

      case CoinMode_Pay:
        return GetPayCreditsMessage();
      case CoinMode_Free:
        if (players_can_join) {
          return CREDITS_FREE_PLAY.GetValue();
        }
        return CREDITS_PLEASE_WAIT.GetValue();
      default:
        WarnSystemLayer(
            ssprintf("ignored invalid coin mode %d.", GAMESTATE->GetCoinMode()));
    }
  }
  return std::string();
}

};  // namespace

// lua start
#include "LuaBinding.h"

namespace {
int GetCreditsMessage(lua_State* L) {
  PlayerNumber pn = Enum::Check<PlayerNumber>(L, 1);
  std::string sText = GetCreditsMessage(pn);
  LuaHelpers::Push(L, sText);
  return 1;
}

const luaL_Reg ScreenSystemLayerHelpersTable[] = {
    LIST_METHOD(GetCreditsMessage), {nullptr, nullptr}};
}  // namespace

LUA_REGISTER_NAMESPACE(ScreenSystemLayerHelpers)

REGISTER_SCREEN_CLASS(ScreenSystemLayer);
void ScreenSystemLayer::Init() {
  Screen::Init();

  if (THEME != nullptr && THEME->IsThemeLoaded()) {
    m_sprOverlay.LoadB(m_sName, "overlay");
  } else {
    WarnSystemLayer("using empty overlay actor because no theme is loaded.");
    m_sprOverlay.LoadFallback();
  }
  this->AddChild(m_sprOverlay);

  if (THEME != nullptr && THEME->IsThemeLoaded()) {
    m_errLayer.LoadB(m_sName, "error");
  } else {
    WarnSystemLayer("using empty error actor because no theme is loaded.");
    m_errLayer.LoadFallback();
  }
  this->AddChild(m_errLayer);
}

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
