#include "WorkoutGraph.h"

#include <algorithm>
#include <cmath>
#include <vector>

#include "Actor.h"
#include "ActorFrame.h"
#include "ActorUtil.h"
#include "GameConstantsAndTypes.h"
#include "GameState.h"
#include "LuaManager.h"
#include "PlayerNumber.h"
#include "RageLog.h"
#include "RageTypes.h"
#include "RageUtil.h"
#include "Sprite.h"
#include "Steps.h"
#include "ThemeManager.h"
#include "Trail.h"
#include "global.h"

const int MAX_METERS_TO_SHOW = 50;

REGISTER_ACTOR_CLASS(WorkoutGraph);

namespace {
void WarnWorkoutGraph(const char* message) {
  if (LOG != nullptr) {
    LOG->Warn("%s", message);
  }
}

bool IsValidWorkoutGraphPlayer(PlayerNumber pn) {
  return pn >= PLAYER_1 && pn < NUM_PLAYERS;
}

PlayerNumber GetWorkoutGraphPlayer() {
  if (GAMESTATE == nullptr) {
    return PlayerNumber_Invalid;
  }

  const PlayerNumber master = GAMESTATE->GetMasterPlayerNumber();
  if (IsValidWorkoutGraphPlayer(master)) {
    return master;
  }

  FOREACH_PlayerNumber(pn) {
    if (GAMESTATE->m_pCurTrail[pn] != nullptr) {
      return pn;
    }
  }
  return PLAYER_1;
}

int SanitizeWorkoutMeter(int meter) {
  return std::clamp(meter, 0, MAX_METER);
}
}  // namespace

WorkoutGraph::WorkoutGraph() { m_iSongsChoppedOffAtBeginning = 0; }

WorkoutGraph::WorkoutGraph(const WorkoutGraph& cpy)
    : ActorFrame(cpy),
      m_sprEmpty(cpy.m_sprEmpty),
      m_iSongsChoppedOffAtBeginning(cpy.m_iSongsChoppedOffAtBeginning) {
  AddChild(&m_sprEmpty);
  for (Sprite* s : cpy.m_vpBars) {
    if (s == nullptr) {
      continue;
    }
    Sprite* copied = new Sprite(*s);
    m_vpBars.push_back(copied);
    AddChild(copied);
  }
}

WorkoutGraph::~WorkoutGraph() { ClearBars(); }

void WorkoutGraph::ClearBars() {
  for (Sprite* s : m_vpBars) {
    this->RemoveChild(s);
    delete s;
  }
  m_vpBars.clear();
}

void WorkoutGraph::Load() {
  RemoveChild(&m_sprEmpty);
  if (THEME != nullptr) {
    m_sprEmpty.Load(THEME->GetPathG("WorkoutGraph", "empty"));
  } else {
    WarnWorkoutGraph("WorkoutGraph loaded without THEME.");
  }
  this->AddChild(&m_sprEmpty);
}

void WorkoutGraph::LoadFromNode(const XNode* pNode) {
  ActorFrame::LoadFromNode(pNode);
  if (pNode == nullptr) {
    WarnWorkoutGraph("WorkoutGraph ignored null XML node.");
    return;
  }

  Load();
}

void WorkoutGraph::SetFromCurrentWorkout() { SetInternal(0); }

void WorkoutGraph::SetInternal(int iMinSongsPlayed) {
  ClearBars();
  m_iSongsChoppedOffAtBeginning = 0;

  if (GAMESTATE == nullptr) {
    WarnWorkoutGraph(
        "WorkoutGraph ignored update without GAMESTATE.");
    return;
  }

  const PlayerNumber pn = GetWorkoutGraphPlayer();
  if (!IsValidWorkoutGraphPlayer(pn)) {
    return;
  }

  Trail* pTrail = GAMESTATE->m_pCurTrail[pn];
  if (pTrail == nullptr) {
    return;
  }

  std::vector<int> viMetersAll;
  for (const TrailEntry& e : pTrail->m_vEntries) {
    if (e.pSteps == nullptr) {
      WarnWorkoutGraph(
          "WorkoutGraph skipped trail entry without steps.");
      continue;
    }
    viMetersAll.push_back(SanitizeWorkoutMeter(e.pSteps->GetMeter()));
  }

  if (viMetersAll.empty()) {
    return;
  }

  const int totalMeters = static_cast<int>(viMetersAll.size());
  const int maxMetersToShow = std::max(1, MAX_METERS_TO_SHOW);
  if (totalMeters > maxMetersToShow) {
    const int minSongsPlayed = std::max(0, iMinSongsPlayed);
    const int preferredStart = std::max(0, minSongsPlayed - maxMetersToShow);
    m_iSongsChoppedOffAtBeginning =
        std::min(preferredStart, totalMeters - maxMetersToShow);
  }

  const int metersToCopy =
      std::min(maxMetersToShow, totalMeters - m_iSongsChoppedOffAtBeginning);
  std::vector<int> viMeters;
  viMeters.reserve(metersToCopy);
  for (int i = 0; i < metersToCopy; ++i) {
    viMeters.push_back(viMetersAll[m_iSongsChoppedOffAtBeginning + i]);
  }

  int iBlocksWide = static_cast<int>(viMeters.size());
  int iBlocksHigh = MAX_METER;
  if (iBlocksWide <= 0 || iBlocksHigh <= 0) {
    return;
  }

  const float fMaxWidth = 300;
  float fTotalWidth = SCALE(iBlocksWide, 1.0f, 10.0f, 50.0f, fMaxWidth);
  rage_clamp(fTotalWidth, 50, fMaxWidth);

  const float fMaxHeight = 130;
  float fTotalHeight = SCALE(iBlocksHigh, 1.0f, 10.0f, 50.0f, fMaxHeight);
  rage_clamp(fTotalHeight, 50, fMaxHeight);

  float fBlockSize =
      std::min(fTotalWidth / iBlocksWide, fTotalHeight / iBlocksHigh);
  if (!std::isfinite(fBlockSize) || fBlockSize <= 0.0f) {
    return;
  }

  m_sprEmpty.SetVertAlign(align_bottom);
  m_sprEmpty.SetCustomImageRect(
      RectF(0, 0, (float)iBlocksWide, (float)iBlocksHigh));
  m_sprEmpty.ZoomToWidth(iBlocksWide * fBlockSize);
  m_sprEmpty.ZoomToHeight(iBlocksHigh * fBlockSize);

  int index = 0;
  for (const int& meter : viMeters) {
    float fOffsetFromCenter = (index++) - (iBlocksWide - 1) / 2.0f;
    Sprite* p = new Sprite;
    if (THEME != nullptr) {
      p->Load(THEME->GetPathG("WorkoutGraph", "bar"));
    } else {
      WarnWorkoutGraph(
          "WorkoutGraph skipped bar texture without THEME.");
    }
    p->SetVertAlign(align_bottom);
    p->ZoomToWidth(fBlockSize);
    int iMetersToCover = (MAX_METER - meter);
    p->SetCustomImageRect(
        RectF(0, (float)iMetersToCover / (float)iBlocksHigh, 1, 1));
    p->ZoomToHeight(meter * fBlockSize);
    p->SetX(fOffsetFromCenter * fBlockSize);
    m_vpBars.push_back(p);
    this->AddChild(p);
  }
}

void WorkoutGraph::SetFromGameStateAndHighlightSong(int iSongIndex) {
  SetInternal(iSongIndex + 1);

  for (Sprite* s : m_vpBars) {
    s->StopEffect();
  }

  int iBarIndex = iSongIndex - m_iSongsChoppedOffAtBeginning;

  if (iBarIndex >= 0 && iBarIndex < (int)m_vpBars.size()) {
    m_vpBars[iBarIndex]->SetEffectGlowBlink(
        0.3f, RageColor(1, 1, 1, 0.2f), RageColor(1, 1, 1, 0.8f));
  }
}

// lua start
#include "LuaBinding.h"

/** @brief Allow Lua to have access to the WorkoutGraph. */
class LunaWorkoutGraph : public Luna<WorkoutGraph> {
 public:
  static int SetFromCurrentWorkout(T* p, lua_State* L) {
    p->SetFromCurrentWorkout();
    COMMON_RETURN_SELF;
  }
  static int SetFromGameStateAndHighlightSong(T* p, lua_State* L) {
    p->SetFromGameStateAndHighlightSong(IArg(1));
    COMMON_RETURN_SELF;
  }

  LunaWorkoutGraph() {
    ADD_METHOD(SetFromCurrentWorkout);
    ADD_METHOD(SetFromGameStateAndHighlightSong);
  }
};

LUA_REGISTER_DERIVED_CLASS(WorkoutGraph, ActorFrame)
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
