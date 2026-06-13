#include "Attack.h"

#include <algorithm>
#include <cmath>
#include <string>
#include <vector>

#include "GameConstantsAndTypes.h"
#include "GameState.h"
#include "PlayerOptions.h"
#include "PlayerState.h"
#include "RageLog.h"
#include "RageUtil.h"
#include "Song.h"
#include "global.h"

static bool IsValidAttackLevel(AttackLevel level) {
  return level >= ATTACK_LEVEL_1 && level < NUM_ATTACK_LEVELS;
}

static float SanitizeAttackSeconds(float value, const char* context) {
  if (!std::isfinite(value) || value < 0.0f) {
    LOG->Warn(
        "SRC_AUDIT_FIX: Invalid attack seconds %f in %s; using 0.", value,
        context);
    return 0.0f;
  }
  return value;
}

void Attack::GetAttackBeats(
    const Song* pSong, float& fStartBeat, float& fEndBeat) const {
  fStartBeat = 0.0f;
  fEndBeat = 0.0f;
  if (pSong == nullptr) {
    LOG->Warn("SRC_AUDIT_FIX: Attack::GetAttackBeats called without song.");
    return;
  }
  const float startSecond =
      SanitizeAttackSeconds(fStartSecond, "Attack::GetAttackBeats start");
  const float secondsRemaining = SanitizeAttackSeconds(
      fSecsRemaining, "Attack::GetAttackBeats duration");

  const TimingData& timing = pSong->m_SongTiming;
  fStartBeat = timing.GetBeatFromElapsedTime(startSecond);
  fEndBeat = timing.GetBeatFromElapsedTime(startSecond + secondsRemaining);
  if (!std::isfinite(fStartBeat) || !std::isfinite(fEndBeat) ||
      fEndBeat < fStartBeat) {
    LOG->Warn(
        "SRC_AUDIT_FIX: Invalid attack beat range %f-%f; clamping to start.",
        fStartBeat, fEndBeat);
    fStartBeat = std::isfinite(fStartBeat) ? fStartBeat : 0.0f;
    fEndBeat = fStartBeat;
  }
}

/* Get the range for an attack that's being applied in realtime, eg. during
 * battle mode.  We need a PlayerState for this, so we can push the region
 * off-screen to prevent popping when the attack has note modifers. */
void Attack::GetRealtimeAttackBeats(
    const Song* pSong, const PlayerState* pPlayerState, float& fStartBeat,
    float& fEndBeat) const {
  fStartBeat = 0.0f;
  fEndBeat = 0.0f;
  if (pSong == nullptr) {
    LOG->Warn(
        "SRC_AUDIT_FIX: Attack::GetRealtimeAttackBeats called without song.");
    return;
  }

  if (fStartSecond >= 0) {
    GetAttackBeats(pSong, fStartBeat, fEndBeat);
    return;
  }

  if (pPlayerState == nullptr || GAMESTATE == nullptr) {
    LOG->Warn(
        "SRC_AUDIT_FIX: Realtime attack missing player state or GAMESTATE.");
    return;
  }

  /* If reasonable, push the attack forward 8 beats so that notes on screen
   * don't change suddenly. */
  fStartBeat = std::min(
      GAMESTATE->m_Position.m_fSongBeat + 8, pPlayerState->m_fLastDrawnBeat);
  if (!std::isfinite(fStartBeat)) {
    LOG->Warn("SRC_AUDIT_FIX: Realtime attack start beat was non-finite.");
    fStartBeat = 0.0f;
  }
  fStartBeat = std::trunc(fStartBeat) + 1;

  const TimingData& timing = pSong->m_SongTiming;
  const float lStartSecond = timing.GetElapsedTimeFromBeat(fStartBeat);
  const float fEndSecond = lStartSecond + SanitizeAttackSeconds(
                                             fSecsRemaining,
                                             "Attack::GetRealtimeAttackBeats");
  fEndBeat = timing.GetBeatFromElapsedTime(fEndSecond);
  fEndBeat = std::trunc(fEndBeat) + 1;

  if (!std::isfinite(fEndBeat) || fEndBeat < fStartBeat) {
    LOG->Warn(
        "SRC_AUDIT_FIX: Invalid realtime attack beat range %f-%f; clamping.",
        fStartBeat, fEndBeat);
    fEndBeat = fStartBeat;
  }
}

bool Attack::operator==(const Attack& rhs) const {
#define EQUAL(a) (a == rhs.a)
  return EQUAL(level) && EQUAL(fStartSecond) && EQUAL(fSecsRemaining) &&
         EQUAL(sModifiers) && EQUAL(bOn) && EQUAL(bGlobal) &&
         EQUAL(bShowInAttackList);
}

bool Attack::ContainsTransformOrTurn() const {
  PlayerOptions po;
  po.FromString(sModifiers);
  return po.ContainsTransformOrTurn();
}

Attack Attack::FromGlobalCourseModifier(const std::string& sModifiers) {
  Attack a;
  a.fStartSecond = 0;
  a.fSecsRemaining = 10000; /* whole song */
  a.level = ATTACK_LEVEL_1;
  a.sModifiers = sModifiers;
  a.bGlobal = true;
  return a;
}

std::string Attack::GetTextDescription() const {
  std::string s = sModifiers + " " + ssprintf("(%.2f seconds)", fSecsRemaining);
  return s;
}

int Attack::GetNumAttacks() const {
  std::vector<std::string> tmp;
  split(this->sModifiers, ",", tmp);
  return tmp.size();
}

bool AttackArray::ContainsTransformOrTurn() const {
  return std::any_of((*this).begin(), (*this).end(), [](const Attack& a) {
    return a.ContainsTransformOrTurn();
  });
}

std::vector<std::string> AttackArray::ToVectorString() const {
  std::vector<std::string> ret;
  for (const Attack& a : *this) {
    if (!std::isfinite(a.fStartSecond) || !std::isfinite(a.fSecsRemaining)) {
      LOG->Warn(
          "SRC_AUDIT_FIX: Skipping attack with invalid times %f/%f during "
          "serialization.",
          a.fStartSecond, a.fSecsRemaining);
      continue;
    }
    if (!IsValidAttackLevel(a.level)) {
      LOG->Warn(
          "SRC_AUDIT_FIX: Serializing attack with invalid level %i.",
          a.level);
    }
    ret.push_back(ssprintf(
        "TIME=%f:LEN=%f:MODS=%s", a.fStartSecond, a.fSecsRemaining,
        a.sModifiers.c_str()));
  }
  return ret;
}

void AttackArray::UpdateStartTimes(float delta) {
  if (!std::isfinite(delta)) {
    LOG->Warn("SRC_AUDIT_FIX: Ignoring invalid attack time delta %f.", delta);
    return;
  }
  for (Attack& a : *this) {
    a.fStartSecond += delta;
    if (!std::isfinite(a.fStartSecond)) {
      LOG->Warn("SRC_AUDIT_FIX: Attack start time overflowed; clamping to 0.");
      a.fStartSecond = 0.0f;
    }
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
