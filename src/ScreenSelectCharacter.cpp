#include "ScreenSelectCharacter.h"

#include <algorithm>
#include <cmath>
#include <string>
#include <vector>

#include "AnnouncerManager.h"
#include "Banner.h"
#include "Character.h"
#include "CharacterManager.h"
#include "GameConstantsAndTypes.h"
#include "GameSoundManager.h"
#include "GameState.h"
#include "InputEventPlus.h"
#include "PlayerNumber.h"
#include "PrefsManager.h"
#include "RageLog.h"
#include "RageTypes.h"
#include "RageUtil.h"
#include "Screen.h"
#include "ScreenManager.h"
#include "ScreenMessage.h"
#include "ScreenWithMenuElements.h"
#include "ThemeManager.h"
#include "global.h"

const PlayerNumber CPU_PLAYER[NUM_PLAYERS] = {PLAYER_2, PLAYER_1};

REGISTER_SCREEN_CLASS(ScreenSelectCharacter);

namespace {
const std::string SCREEN_SELECT_CHARACTER = "ScreenSelectCharacter";

bool IsValidPlayer(PlayerNumber pn) {
  return pn >= PLAYER_1 && pn < NUM_PLAYERS;
}

bool IsValidSelectionRow(ScreenSelectCharacter::SelectionRow row) {
  return row == ScreenSelectCharacter::CHOOSING_HUMAN_CHARACTER ||
         row == ScreenSelectCharacter::CHOOSING_CPU_CHARACTER ||
         row == ScreenSelectCharacter::FINISHED_CHOOSING;
}

void WarnSelectCharacter(const char* fmt, ...) {
  if (LOG == nullptr) {
    return;
  }

  va_list va;
  va_start(va, fmt);
  LOG->Warn("%s", vssprintf(fmt, va).c_str());
  va_end(va);
}

bool IsBattleOrRaveMode() {
  return GAMESTATE != nullptr && (GAMESTATE->m_PlayMode == PLAY_MODE_BATTLE ||
                                  GAMESTATE->m_PlayMode == PLAY_MODE_RAVE);
}

std::string ThemePathG(const std::string& element) {
  return THEME == nullptr ? std::string()
                          : THEME->GetPathG(SCREEN_SELECT_CHARACTER, element);
}

std::string ThemePathS(const std::string& element) {
  return THEME == nullptr ? std::string()
                          : THEME->GetPathS(SCREEN_SELECT_CHARACTER, element);
}

float ThemeMetricF(const std::string& metric, float fallback = 0.0f) {
  if (THEME == nullptr || !THEME->HasMetric(SCREEN_SELECT_CHARACTER, metric)) {
    return fallback;
  }

  const float value = THEME->GetMetricF(SCREEN_SELECT_CHARACTER, metric);
  return std::isfinite(value) ? value : fallback;
}

float NonNegativeThemeMetricF(
    const std::string& metric, float fallback = 0.0f) {
  return std::max(0.0f, ThemeMetricF(metric, fallback));
}

void RunThemeCommand(Actor& actor, const std::string& metric) {
  if (THEME == nullptr || !THEME->HasMetric(SCREEN_SELECT_CHARACTER, metric)) {
    return;
  }
  actor.RunCommands(THEME->GetMetricA(SCREEN_SELECT_CHARACTER, metric));
}

std::string PlayerMetric(const std::string& prefix, PlayerNumber pn) {
  return ssprintf("%sP%d%s", prefix.c_str(), pn + 1, "Command");
}

std::string PlayerMetric(
    const std::string& prefix, PlayerNumber pn, const std::string& suffix) {
  return ssprintf("%sP%d%s", prefix.c_str(), pn + 1, suffix.c_str());
}

void GetSelectableCharacters(std::vector<Character*>& characters) {
  characters.clear();
  if (CHARMAN == nullptr) {
    return;
  }

  CHARMAN->GetCharacters(characters);
  characters.erase(
      std::remove(characters.begin(), characters.end(), nullptr),
      characters.end());
}

Character* GetFallbackCharacter() {
  return CHARMAN == nullptr ? nullptr : CHARMAN->GetDefaultCharacter();
}

Character* GetCharacterAtSelection(
    const std::vector<Character*>& characters, int selection) {
  if (characters.empty()) {
    return GetFallbackCharacter();
  }

  const int index =
      std::max(0, std::min(selection, static_cast<int>(characters.size()) - 1));
  return characters[index] != nullptr ? characters[index]
                                      : GetFallbackCharacter();
}

PlayerNumber GetTimerPlayer() {
  if (GAMESTATE == nullptr) {
    return PLAYER_INVALID;
  }

  const PlayerNumber master = GAMESTATE->GetMasterPlayerNumber();
  if (IsValidPlayer(master) && GAMESTATE->IsHumanPlayer(master)) {
    return master;
  }

  FOREACH_HumanPlayer(pn) { return pn; }
  return PLAYER_INVALID;
}
}  // namespace

ScreenSelectCharacter::ScreenSelectCharacter() : m_bExplanationAdded(false) {
  FOREACH_PlayerNumber(pn) {
    m_iSelectedCharacter[pn] = 0;
    m_SelectionRow[pn] = FINISHED_CHOOSING;
    m_bPlayerActorsAdded[pn] = false;
  }
}

void ScreenSelectCharacter::Init() {
  ScreenWithMenuElements::Init();

  std::vector<Character*> apCharacters;
  GetSelectableCharacters(apCharacters);
  if (apCharacters.empty()) {
    WarnSelectCharacter(
        "ScreenSelectCharacter has no selectable characters; skipping screen.");
    this->PostScreenMessage(SM_GoToNextScreen, 0);
    return;
  }

  if (GAMESTATE == nullptr) {
    WarnSelectCharacter("ScreenSelectCharacter opened without GAMESTATE.");
    this->PostScreenMessage(SM_GoToNextScreen, 0);
    return;
  }

  switch (GAMESTATE->m_PlayMode) {
    // For Rave/Battle mode, we force the players to select characters
    // (by not returning in this switch)
    case PLAY_MODE_BATTLE:
    case PLAY_MODE_RAVE:
      break;

    default:
      /* Non Rave/Battle mode, just skip this screen if disabled. */
      if (PREFSMAN == nullptr ||
          PREFSMAN->m_ShowDancingCharacters != SDC_Select) {
        this->PostScreenMessage(SM_GoToNextScreen, 0);
        return;
      }
  }

  FOREACH_PlayerNumber(p) {
    m_iSelectedCharacter[p] = 0;
    m_SelectionRow[p] = GAMESTATE->IsHumanPlayer(p) ? CHOOSING_HUMAN_CHARACTER
                                                    : FINISHED_CHOOSING;
    m_bPlayerActorsAdded[p] = false;
  }

  FOREACH_EnabledPlayer(p) {
    m_sprTitle[p].Load(ThemePathG("title 2x2"));
    m_sprTitle[p].SetState(GAMESTATE->IsHumanPlayer(p) ? p : 2 + p);
    m_sprTitle[p].StopAnimating();
    RunThemeCommand(m_sprTitle[p], PlayerMetric("Title", p, "OnCommand"));

    this->AddChild(&m_sprTitle[p]);

    RunThemeCommand(m_sprCard[p], PlayerMetric("Card", p, "OnCommand"));
    this->AddChild(&m_sprCard[p]);

    m_sprCardArrows[p].Load(ThemePathG("card arrows"));
    RunThemeCommand(
        m_sprCardArrows[p], PlayerMetric("CardArrows", p, "OnCommand"));
    this->AddChild(&m_sprCardArrows[p]);

    for (unsigned i = 0; i < MAX_CHAR_ICONS_TO_SHOW; i++) {
      m_sprIcons[p][i].ScaleToClipped(
          NonNegativeThemeMetricF("IconWidth", 40.0f),
          NonNegativeThemeMetricF("IconHeight", 40.0f));
      this->AddChild(&m_sprIcons[p][i]);
    }

    if (IsBattleOrRaveMode()) {
      m_sprAttackFrame[p].Load(ThemePathG("attack frame 1x2"));
      m_sprAttackFrame[p].StopAnimating();
      m_sprAttackFrame[p].SetState(p);
      RunThemeCommand(
          m_sprAttackFrame[p], PlayerMetric("AttackFrame", p, "OnCommand"));
      this->AddChild(&m_sprAttackFrame[p]);

      for (int i = 0; i < NUM_ATTACK_LEVELS; i++) {
        for (int j = 0; j < NUM_ATTACKS_PER_LEVEL; j++) {
          float fX =
              ThemeMetricF(ssprintf("AttackIconsP%dStartX", p + 1), 0.0f) +
              ThemeMetricF("AttackIconsSpacingX", 0.0f) * j;
          float fY =
              ThemeMetricF(ssprintf("AttackIconsP%dStartY", p + 1), 0.0f) +
              ThemeMetricF("AttackIconsSpacingY", 0.0f) * i;
          m_AttackIcons[p][i][j].Load(SCREEN_SELECT_CHARACTER);
          m_AttackIcons[p][i][j].SetXY(fX, fY);
          RunThemeCommand(
              m_AttackIcons[p][i][j],
              PlayerMetric("AttackIcons", p, "OnCommand"));
          this->AddChild(&m_AttackIcons[p][i][j]);
        }
      }
    }
    m_bPlayerActorsAdded[p] = true;
  }

  m_sprExplanation.Load(ThemePathG("explanation"));
  RunThemeCommand(m_sprExplanation, "ExplanationOnCommand");
  this->AddChild(&m_sprExplanation);
  m_bExplanationAdded = true;

  m_soundChange.Load(ThemePathS("change"), true);

  if (SOUND != nullptr && ANNOUNCER != nullptr) {
    SOUND->PlayOnceFromDir(ANNOUNCER->GetPathTo("select group intro"));
  }

  FOREACH_PlayerNumber(p) {
    if (GAMESTATE->IsHumanPlayer(p)) {
      AfterRowChange(p);
      AfterValueChange(p);
    }

    if (m_bPlayerActorsAdded[p]) {
      for (unsigned i = 0; i < MAX_CHAR_ICONS_TO_SHOW; i++) {
        RunThemeCommand(
            m_sprIcons[p][i], PlayerMetric("Icons", p, "OnCommand"));
      }
    }
  }
}

ScreenSelectCharacter::~ScreenSelectCharacter() {
  if (LOG != nullptr) {
    LOG->Trace("ScreenSelectCharacter::~ScreenSelectCharacter()");
  }
}

bool ScreenSelectCharacter::Input(const InputEventPlus& input) {
  if (IsTransitioning()) {
    return false;
  }

  return ScreenWithMenuElements::Input(input);  // default input handler
}

void ScreenSelectCharacter::HandleScreenMessage(const ScreenMessage SM) {
  if (SM == SM_BeginFadingOut) {
    StartTransitioningScreen(SM_GoToNextScreen);
  } else if (SM == SM_MenuTimer) {
    const PlayerNumber timer_player = GetTimerPlayer();
    if (timer_player == PLAYER_INVALID) {
      WarnSelectCharacter("Menu timer fired without an active human player.");
      this->PostScreenMessage(SM_GoToNextScreen, 0);
      return;
    }
    MakeSelection(timer_player);
    if (!AllAreFinishedChoosing()) {
      ResetTimer();
    }
  } else {
    ScreenWithMenuElements::HandleScreenMessage(SM);
  }
}

PlayerNumber ScreenSelectCharacter::GetAffectedPlayerNumber(PlayerNumber pn) {
  if (!IsValidPlayer(pn) || !IsValidSelectionRow(m_SelectionRow[pn])) {
    WarnSelectCharacter(
        "Invalid player or selection row in ScreenSelectCharacter.");
    return PLAYER_INVALID;
  }

  switch (m_SelectionRow[pn]) {
    case CHOOSING_HUMAN_CHARACTER:
      return pn;
    case CHOOSING_CPU_CHARACTER:
      return CPU_PLAYER[pn];
    case FINISHED_CHOOSING:
      return pn;
    default:
      return PLAYER_INVALID;
  }
}

void ScreenSelectCharacter::BeforeRowChange(PlayerNumber pn) {
  PlayerNumber pnAffected = GetAffectedPlayerNumber(pn);
  if (!IsValidPlayer(pnAffected)) {
    return;
  }
  switch (m_SelectionRow[pn]) {
    case CHOOSING_CPU_CHARACTER:
    case CHOOSING_HUMAN_CHARACTER:
      m_sprCardArrows[pnAffected].StopEffect();
      break;
    default:
      break;
  }
}

void ScreenSelectCharacter::AfterRowChange(PlayerNumber pn) {
  PlayerNumber pnAffected = GetAffectedPlayerNumber(pn);
  if (!IsValidPlayer(pnAffected)) {
    return;
  }
  switch (m_SelectionRow[pn]) {
    case CHOOSING_CPU_CHARACTER:
    case CHOOSING_HUMAN_CHARACTER:
      m_sprCardArrows[pnAffected].SetEffectGlowShift(
          1.0f, RageColor(1, 1, 1, 0.2f), RageColor(1, 1, 1, 0.8f));
      break;
    default:
      break;
  }
}

void ScreenSelectCharacter::AfterValueChange(PlayerNumber pn) {
  PlayerNumber pnAffected = GetAffectedPlayerNumber(pn);
  if (!IsValidPlayer(pnAffected) || !m_bPlayerActorsAdded[pnAffected]) {
    return;
  }

  switch (m_SelectionRow[pn]) {
    case CHOOSING_CPU_CHARACTER:
    case CHOOSING_HUMAN_CHARACTER: {
      std::vector<Character*> apCharacters;
      GetSelectableCharacters(apCharacters);
      if (apCharacters.empty() && GetFallbackCharacter() == nullptr) {
        WarnSelectCharacter(
            "No character available for ScreenSelectCharacter.");
        return;
      }

      if (!apCharacters.empty()) {
        m_iSelectedCharacter[pnAffected] = std::max(
            0, std::min(
                   m_iSelectedCharacter[pnAffected],
                   static_cast<int>(apCharacters.size()) - 1));
      }

      Character* pChar = GetCharacterAtSelection(
          apCharacters, m_iSelectedCharacter[pnAffected]);
      m_sprCard[pnAffected].UnloadTexture();
      m_sprCard[pnAffected].LoadCardFromCharacter(pChar);

      if (IsBattleOrRaveMode() && pChar != nullptr) {
        for (int i = 0; i < NUM_ATTACK_LEVELS; i++) {
          for (int j = 0; j < NUM_ATTACKS_PER_LEVEL; j++) {
            const std::string& attack = pChar->m_sAttacks[i][j];
            m_AttackIcons[pnAffected][i][j].Set(attack);
          }
        }
      }

      int c = m_iSelectedCharacter[pnAffected] - MAX_CHAR_ICONS_TO_SHOW / 2;
      if (!apCharacters.empty()) {
        wrap(c, apCharacters.size());
      }

      for (unsigned i = 0; i < MAX_CHAR_ICONS_TO_SHOW; i++) {
        Character* pCharacter = nullptr;
        if (!apCharacters.empty()) {
          c++;
          wrap(c, apCharacters.size());
          pCharacter = apCharacters[c];
        }
        Banner& banner = m_sprIcons[pnAffected][i];
        banner.LoadIconFromCharacter(pCharacter);
        float fX = (pnAffected == PLAYER_1)
                       ? 320 - NonNegativeThemeMetricF("IconWidth", 40.0f)
                       : 320 + NonNegativeThemeMetricF("IconWidth", 40.0f);
        float fY = SCALE(
            i, 0.f, MAX_CHAR_ICONS_TO_SHOW - 1.f,
            240 - (MAX_CHAR_ICONS_TO_SHOW / 2 *
                   NonNegativeThemeMetricF("IconHeight", 40.0f)),
            240 + (MAX_CHAR_ICONS_TO_SHOW / 2 *
                   NonNegativeThemeMetricF("IconHeight", 40.0f)));
        banner.SetXY(fX, fY);
      }
    } break;
    case FINISHED_CHOOSING:;  // do nothing
      break;
    default:
      WarnSelectCharacter(
          "Invalid character selection state: %i", m_SelectionRow[pn]);
  }
}

bool ScreenSelectCharacter::MenuLeft(const InputEventPlus& input) {
  return MenuUp(input);
}

bool ScreenSelectCharacter::MenuRight(const InputEventPlus& input) {
  return MenuDown(input);
}

bool ScreenSelectCharacter::MenuUp(const InputEventPlus& input) {
  if (input.type != IET_FIRST_PRESS || !IsValidPlayer(input.pn)) {
    return false;
  }
  Move(input.pn, -1);
  return true;
}

bool ScreenSelectCharacter::MenuDown(const InputEventPlus& input) {
  if (input.type != IET_FIRST_PRESS || !IsValidPlayer(input.pn)) {
    return false;
  }
  Move(input.pn, +1);
  return true;
}

void ScreenSelectCharacter::Move(PlayerNumber pn, int deltaValue) {
  PlayerNumber pnAffected = GetAffectedPlayerNumber(pn);
  if (!IsValidPlayer(pnAffected)) {
    return;
  }

  switch (m_SelectionRow[pn]) {
    case CHOOSING_CPU_CHARACTER:
    case CHOOSING_HUMAN_CHARACTER: {
      std::vector<Character*> apCharacters;
      GetSelectableCharacters(apCharacters);
      if (apCharacters.empty()) {
        WarnSelectCharacter(
            "Move ignored because no characters are available.");
        return;
      }
      m_iSelectedCharacter[pnAffected] += deltaValue;
      wrap(m_iSelectedCharacter[pnAffected], apCharacters.size());
      AfterValueChange(pn);
      if (m_soundChange.IsLoaded()) {
        m_soundChange.Play(true);
      }
      break;
    }
    default:
      break;
  }
}

bool ScreenSelectCharacter::AllAreFinishedChoosing() const {
  bool has_human_player = false;
  FOREACH_HumanPlayer(p) {
    has_human_player = true;
    if (!IsValidSelectionRow(m_SelectionRow[p]) ||
        m_SelectionRow[p] != FINISHED_CHOOSING) {
      return false;
    }
  }
  if (!has_human_player) {
    return false;
  }
  return true;
}

bool ScreenSelectCharacter::MenuStart(const InputEventPlus& input) {
  if (input.type != IET_FIRST_PRESS || !IsValidPlayer(input.pn)) {
    return false;
  }
  MakeSelection(input.pn);
  return true;
}

void ScreenSelectCharacter::MakeSelection(PlayerNumber pn) {
  if (!IsValidPlayer(pn) || !IsValidSelectionRow(m_SelectionRow[pn])) {
    WarnSelectCharacter("Ignoring invalid character selection request.");
    return;
  }

  if (m_SelectionRow[pn] == FINISHED_CHOOSING) {
    return;
  }

  // change row
  BeforeRowChange(pn);
  switch (m_SelectionRow[pn]) {
    case CHOOSING_HUMAN_CHARACTER:
      m_SelectionRow[pn] = GAMESTATE != nullptr && GAMESTATE->AnyPlayersAreCpu()
                               ? CHOOSING_CPU_CHARACTER
                               : FINISHED_CHOOSING;
      break;
    case CHOOSING_CPU_CHARACTER:
      m_SelectionRow[pn] = FINISHED_CHOOSING;
      break;
    default:
      break;
  }
  AfterRowChange(pn);
  AfterValueChange(pn);
  if (SCREENMAN != nullptr) {
    SCREENMAN->PlayStartSound();
  }

  if (AllAreFinishedChoosing()) {
    std::vector<Character*> apCharacters;
    GetSelectableCharacters(apCharacters);
    if (apCharacters.empty() && GetFallbackCharacter() == nullptr) {
      WarnSelectCharacter(
          "Cannot finalize character selection without characters.");
      return;
    }

    FOREACH_PlayerNumber(p) {
      if (GAMESTATE == nullptr || !GAMESTATE->IsPlayerEnabled(p)) {
        continue;
      }
      Character* pChar =
          GetCharacterAtSelection(apCharacters, m_iSelectedCharacter[p]);
      if (pChar == nullptr) {
        WarnSelectCharacter("Skipping null character assignment.");
        continue;
      }
      GAMESTATE->m_pCurCharacters[p] = pChar;
    }

    StopTimer();
    this->PostScreenMessage(SM_BeginFadingOut, 0);
  }
}

bool ScreenSelectCharacter::MenuBack(const InputEventPlus& input) {
  if (IsTransitioning() || input.type != IET_FIRST_PRESS) {
    return false;
  }
  Cancel(SM_GoToPrevScreen);
  return true;
}

void ScreenSelectCharacter::TweenOffScreen() {
  ScreenWithMenuElements::TweenOffScreen();

  FOREACH_PlayerNumber(p) {
    if (!m_bPlayerActorsAdded[p]) {
      continue;
    }

    RunThemeCommand(m_sprCard[p], PlayerMetric("Card", p, "OffCommand"));
    RunThemeCommand(m_sprTitle[p], PlayerMetric("Title", p, "OffCommand"));
    RunThemeCommand(
        m_sprCardArrows[p], PlayerMetric("CardArrows", p, "OffCommand"));
    if (IsBattleOrRaveMode()) {
      RunThemeCommand(
          m_sprAttackFrame[p], PlayerMetric("AttackFrame", p, "OffCommand"));
      for (int i = 0; i < NUM_ATTACK_LEVELS; i++) {
        for (int j = 0; j < NUM_ATTACKS_PER_LEVEL; j++) {
          RunThemeCommand(
              m_AttackIcons[p][i][j],
              PlayerMetric("AttackIcons", p, "OffCommand"));
        }
      }
    }
    for (unsigned i = 0; i < MAX_CHAR_ICONS_TO_SHOW; i++) {
      RunThemeCommand(m_sprIcons[p][i], PlayerMetric("Icons", p, "OffCommand"));
    }
  }
  if (m_bExplanationAdded) {
    RunThemeCommand(m_sprExplanation, "ExplanationOffCommand");
  }
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
