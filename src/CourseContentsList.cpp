#include "CourseContentsList.h"

#include <algorithm>
#include <string>

#include "Actor.h"
#include "ActorScroller.h"
#include "ActorUtil.h"
#include "Course.h"
#include "Difficulty.h"
#include "GameState.h"
#include "LuaManager.h"
#include "MessageManager.h"
#include "PlayerNumber.h"
#include "RageLog.h"
#include "RageUtil.h"
#include "Steps.h"
#include "Trail.h"
#include "XmlFile.h"

REGISTER_ACTOR_CLASS(CourseContentsList);

namespace {
const int MAX_COURSE_CONTENTS_DISPLAYS = 1000;

void WarnCourseContentsList(const char* message) {
  if (LOG != nullptr) {
    LOG->Warn("%s", message);
  }
}

bool IsValidCourseContentsPlayer(PlayerNumber pn) {
  return pn >= PLAYER_1 && pn < NUM_PLAYERS;
}
}  // namespace

CourseContentsList::CourseContentsList() {}

CourseContentsList::CourseContentsList(const CourseContentsList& cpy)
    : ActorScroller(cpy) {
  RemoveAllChildren();
  for (Actor* display : cpy.m_vpDisplay) {
    if (display == nullptr) {
      continue;
    }
    Actor* copiedDisplay = display->Copy();
    if (copiedDisplay == nullptr) {
      continue;
    }
    m_vpDisplay.push_back(copiedDisplay);
  }
}

CourseContentsList::~CourseContentsList() { ClearDisplays(); }

void CourseContentsList::ClearDisplays() {
  RemoveAllChildren();
  for (Actor* d : m_vpDisplay) {
    delete d;
  }
  m_vpDisplay.clear();
}

void CourseContentsList::LoadFromNode(const XNode* pNode) {
  ClearDisplays();
  if (pNode == nullptr) {
    WarnCourseContentsList(
        "CourseContentsList ignored null XML node.");
    return;
  }

  int iMaxSongs = 5;
  pNode->GetAttrValue("MaxSongs", iMaxSongs);
  iMaxSongs = std::clamp(iMaxSongs, 0, MAX_COURSE_CONTENTS_DISPLAYS);

  const XNode* pDisplayNode = pNode->GetChild("Display");
  if (pDisplayNode == nullptr) {
    LuaHelpers::ReportScriptErrorFmt(
        "%s: CourseContentsList: missing the Display child",
        ActorUtil::GetWhere(pNode).c_str());
    return;
  }

  for (int i = 0; i < iMaxSongs; i++) {
    Actor* pDisplay = ActorUtil::LoadFromNode(pDisplayNode, this);
    if (pDisplay == nullptr) {
      WarnCourseContentsList(
          "CourseContentsList skipped null display.");
      continue;
    }
    pDisplay->SetUseZBuffer(true);
    m_vpDisplay.push_back(pDisplay);
  }

  ActorScroller::LoadFromNode(pNode);
}

void CourseContentsList::SetFromGameState() {
  RemoveAllChildren();

  if (GAMESTATE == nullptr) {
    return;
  }
  const PlayerNumber master = GAMESTATE->GetMasterPlayerNumber();
  if (!IsValidCourseContentsPlayer(master)) {
    return;
  }
  const Trail* pMasterTrail = GAMESTATE->m_pCurTrail[master];
  if (pMasterTrail == nullptr) {
    return;
  }
  const size_t uNumEntriesToShow =
      std::min(pMasterTrail->m_vEntries.size(), m_vpDisplay.size());
  if (uNumEntriesToShow == 0) {
    SetLoop(false);
    return;
  }

  for (size_t i = 0; i < uNumEntriesToShow; i++) {
    Actor* pDisplay = m_vpDisplay[i];
    if (pDisplay == nullptr) {
      continue;
    }
    SetItemFromGameState(pDisplay, i);
    this->AddChild(pDisplay);
  }

  bool bLoop = pMasterTrail->m_vEntries.size() > uNumEntriesToShow;

  this->SetLoop(bLoop);
  this->Load2();
  Actor* firstDisplay = m_vpDisplay[0];
  if (firstDisplay != nullptr) {
    this->SetTransformFromHeight(firstDisplay->GetUnzoomedHeight());
    this->EnableMask(
        firstDisplay->GetUnzoomedWidth(), firstDisplay->GetUnzoomedHeight());
  }

  if (bLoop) {
    SetPauseCountdownSeconds(1.5f);
    this->SetDestinationItem((float)m_vpDisplay.size() + 1);  // loop forever
  }
}

void CourseContentsList::SetItemFromGameState(
    Actor* pActor, int iCourseEntryIndex) {
  if (pActor == nullptr || GAMESTATE == nullptr || iCourseEntryIndex < 0) {
    return;
  }
  const Course* pCourse = GAMESTATE->m_pCurCourse;
  if (pCourse == nullptr) {
    ResetItem(pActor);
    return;
  }

  bool sentMessage = false;
  FOREACH_HumanPlayer(pn) {
    const Trail* pTrail = GAMESTATE->m_pCurTrail[pn];
    if (pTrail == nullptr ||
        iCourseEntryIndex >= (int)pTrail->m_vEntries.size() ||
        iCourseEntryIndex >= (int)pCourse->m_vEntries.size()) {
      continue;
    }

    const TrailEntry* te = &pTrail->m_vEntries[iCourseEntryIndex];
    const CourseEntry* ce = &pCourse->m_vEntries[iCourseEntryIndex];
    if (te == nullptr) {
      continue;
    }

    std::string s;
    Difficulty dc;
    if (te->bSecret) {
      if (ce == nullptr) {
        continue;
      }

      int iLow = ce->stepsCriteria.m_iLowMeter;
      int iHigh = ce->stepsCriteria.m_iHighMeter;

      bool bLowIsSet = iLow != -1;
      bool bHighIsSet = iHigh != -1;

      if (!bLowIsSet && !bHighIsSet) {
        s = "?";
      }
      if (!bLowIsSet && bHighIsSet) {
        s = ssprintf(">=%d", iHigh);
      } else if (bLowIsSet && !bHighIsSet) {
        s = ssprintf("<=%d", iLow);
      } else if (bLowIsSet && bHighIsSet) {
        if (iLow == iHigh) {
          s = ssprintf("%d", iLow);
        } else {
          s = ssprintf("%d-%d", iLow, iHigh);
        }
      }

      dc = te->dc;
      if (dc == Difficulty_Invalid) {
        dc = Difficulty_Edit;
      }
    } else {
      if (te->pSteps == nullptr) {
        s = "?";
        dc = Difficulty_Invalid;
      } else {
        s = ssprintf("%d", te->pSteps->GetMeter());
        dc = te->pSteps->GetDifficulty();
      }
    }

    Message msg("SetSong");
    msg.SetParam("PlayerNumber", pn);
    msg.SetParam("Song", te->pSong);
    msg.SetParam("Steps", te->pSteps);
    msg.SetParam("Difficulty", dc);
    msg.SetParam("Meter", s);
    msg.SetParam("Number", iCourseEntryIndex + 1);
    msg.SetParam("Modifiers", te->Modifiers);
    msg.SetParam("Secret", te->bSecret);
    pActor->HandleMessage(msg);
    sentMessage = true;
  }

  if (!sentMessage) {
    ResetItem(pActor);
  }
}

void CourseContentsList::ResetItem(Actor* pActor) {
  if (pActor == nullptr) {
    return;
  }
  FOREACH_PlayerNumber(pn) {
    Message msg("SetSong");
    msg.SetParam("PlayerNumber", pn);
    msg.SetParam("Song", static_cast<Song*>(nullptr));
    msg.SetParam("Steps", static_cast<Steps*>(nullptr));
    msg.SetParam("Difficulty", Difficulty_Invalid);
    msg.SetParam("Meter", std::string("?"));
    msg.SetParam("Number", 0);
    msg.SetParam("Modifiers", std::string());
    msg.SetParam("Secret", true);
    pActor->HandleMessage(msg);
  }
}

// lua start
#include "LuaBinding.h"

/** @brief Allow Lua to have access to the CourseContentsList. */
class LunaCourseContentsList : public Luna<CourseContentsList> {
 public:
  static int SetFromGameState(T* p, lua_State* L) {
    p->SetFromGameState();
    COMMON_RETURN_SELF;
  }

  LunaCourseContentsList() { ADD_METHOD(SetFromGameState); }
};

LUA_REGISTER_DERIVED_CLASS(CourseContentsList, ActorScroller)
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
