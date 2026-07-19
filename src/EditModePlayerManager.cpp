#include "EditModePlayerManager.h"

#include <memory>

#include "ActorFrame.h"
#include "GameConstantsAndTypes.h"
#include "GamePreferences.h"
#include "GameState.h"
#include "GameplayAssist.h"
#include "InputEventPlus.h"
#include "InputFilter.h"
#include "Player.h"
#include "PlayerNumber.h"
#include "PlayerState.h"
#include "RageLog.h"
#include "RageUtil.h"
#include "ScreenDimensions.h"
#include "Style.h"
#include "ThemeManager.h"

void EditModePlayerManager::AddPlayers(const NoteData& note_data) {
  if (GAMESTATE == nullptr) {
    return;
  }
  const PlayerNumber master = GAMESTATE->GetMasterPlayerNumber();
  const Style* masterStyle =
      master >= PLAYER_1 && master < NUM_PlayerNumber
          ? GAMESTATE->GetCurrentStyle(master)
          : nullptr;
  if (masterStyle == nullptr) {
    LOG->Warn("EditModePlayerManager cannot add players without a style.");
    return;
  }
  FOREACH_EnabledPlayer(pn) {
    // Routine has one shared Player actor even though both sides are enabled.
    if (masterStyle->m_StyleType == StyleType_TwoPlayersSharedSides &&
        pn != master) {
      continue;
    }
    PlayerState* playerState = GAMESTATE->m_pPlayerState[pn];
    if (playerState == nullptr) {
      LOG->Warn(
          "EditModePlayerManager skipped player %i without PlayerState.", pn);
      continue;
    }
    players_[pn] = std::make_shared<PlayerPlus>();

    PlayerPlus& player = *players_[pn];
    player->Init(
        "Player", playerState, nullptr, nullptr, nullptr, nullptr, nullptr,
        nullptr, nullptr, nullptr);
    player.Load(note_data);

    // We set the actor alias here instead of the name to maintain
    // backward compatability with scripted stepcharts that expect
    // the Player's actor frame to be unnamed.
    player->SetAlias("Player" + PlayerNumberToString(pn));

    player->CacheAllUsedNoteSkins();
    playerState->m_PlayerController = PC_HUMAN;
    player->SetY(SCREEN_CENTER_Y);
    player->SetZoom(SCREEN_HEIGHT / 480);
    const Style* playerStyle = GAMESTATE->GetCurrentStyle(pn);
    StyleType style_type =
        playerStyle != nullptr ? playerStyle->m_StyleType
                               : masterStyle->m_StyleType;
    if (center_) {
      // Use the doubles style positioning for centering.
      style_type = StyleType_OnePlayerTwoSides;
    }
    player->SetX(THEME->GetMetricF(
        "ScreenGameplay",
        ssprintf(
            "PlayerP%d%sX", pn + 1, StyleTypeToString(style_type).c_str())));

    // Initial state is to hide the notefield.
    player->SetVisible(false);
  }
}

void EditModePlayerManager::AddPlayersToActorFrame(ActorFrame& frame) {
  for (auto& player : players_) {
    frame.AddChild(*player.second);
  }
}

void EditModePlayerManager::ReloadNoteData(const NoteData& note_data) {
  for (auto& player : players_) {
    player.second->Load(note_data);
  }
}

void EditModePlayerManager::SetVisible(bool visible) {
  if (GAMESTATE == nullptr) {
    return;
  }
  const PlayerNumber master = GAMESTATE->GetMasterPlayerNumber();
  const Style* style =
      master >= PLAYER_1 && master < NUM_PlayerNumber
          ? GAMESTATE->GetCurrentStyle(master)
          : nullptr;
  const auto masterPlayer = players_.find(master);
  if (style != nullptr &&
      style->m_StyleType == StyleType::StyleType_TwoPlayersSharedSides) {
    if (masterPlayer != players_.end() && masterPlayer->second != nullptr) {
      (*masterPlayer->second)->SetVisible(visible);
    }
    return;
  }

  for (auto& player : players_) {
    (*player.second)->SetVisible(visible);
  }
}

bool EditModePlayerManager::HandleGameplayInput(
    const InputEventPlus& input, const GameButtonType& gbt) {
  PlayerNumber pn = input.pn;
  if (GAMESTATE == nullptr) {
    return false;
  }
  const PlayerNumber master = GAMESTATE->GetMasterPlayerNumber();
  const Style* masterStyle =
      master >= PLAYER_1 && master < NUM_PlayerNumber
          ? GAMESTATE->GetCurrentStyle(master)
          : nullptr;

  // Redirect Player2's inputs to P1's notefield in case of Routine charts.
  if (masterStyle != nullptr &&
      masterStyle->m_StyleType == StyleType_TwoPlayersSharedSides) {
    pn = master;
  }
  const auto player = players_.find(pn);
  PlayerState* playerState =
      pn >= PLAYER_1 && pn < NUM_PlayerNumber
          ? GAMESTATE->m_pPlayerState[pn]
          : nullptr;
  const Style* style =
      pn >= PLAYER_1 && pn < NUM_PlayerNumber
          ? GAMESTATE->GetCurrentStyle(pn)
          : nullptr;
  if (gbt == GameButtonType_Step && pn >= PLAYER_1 &&
      pn < NUM_PlayerNumber && GAMESTATE->IsPlayerEnabled(pn) &&
      player != players_.end() && player->second != nullptr &&
      playerState != nullptr && style != nullptr) {
    if (playerState->m_PlayerController == PC_AUTOPLAY) {
      return false;
    }
    const int iCol = style->GameInputToColumn(input.GameI);
    if (iCol != -1) {
      Player* playerActor = *player->second;
      playerActor->Step(
          iCol, -1, input.DeviceI.ts, false, input.type == IET_RELEASE);
    }
    return true;
  }
  return false;
}

void EditModePlayerManager::SetupAutoplay() {
  if (GAMESTATE == nullptr) {
    return;
  }
  for (auto& player : players_) {
    PlayerState* playerState = GAMESTATE->m_pPlayerState[player.first];
    if (playerState == nullptr) {
      continue;
    }
    if (playerState->m_PlayerOptions.GetCurrent().m_fPlayerAutoPlay != 0) {
      playerState->m_PlayerController = PC_AUTOPLAY;
    } else {
      playerState->m_PlayerController = GamePreferences::m_AutoPlay;
    }
  }
}

void EditModePlayerManager::CacheAllUsedNoteSkins() {
  for (auto& player : players_) {
    (*player.second)->CacheAllUsedNoteSkins();
  }
}

void EditModePlayerManager::PlayTicks(GameplayAssist& gameplay_assist) {
  for (auto& player : players_) {
    // Edit mode does not support 2p practicing different steps, so
    // enabling one set of ticks is fine.
    gameplay_assist.PlayTicks(
        (*player.second)->GetNoteData(), (*player.second)->GetPlayerState());
    return;
  }
}
