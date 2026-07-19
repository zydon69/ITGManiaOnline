#include "ScoreKeeperShared.h"

#include <vector>

#include "Attack.h"
#include "GameState.h"
#include "NoteData.h"
#include "NoteTypes.h"
#include "PerfDiagnostics.h"
#include "PlayerNumber.h"
#include "PlayerStageStats.h"
#include "PlayerState.h"
#include "RageLog.h"
#include "ScoreKeeper.h"
#include "ScoreKeeperNormal.h"

namespace {
bool IsValidSharedScorePlayer(PlayerNumber pn) {
  return pn >= PLAYER_1 && pn < NUM_PLAYERS;
}
}  // namespace

/* In Routine, we have two Players, but the master one handles all of the
 * scoring.  The other one will just receive misses for everything, and
 * shouldn't do anything. */
ScoreKeeperShared::ScoreKeeperShared(
    PlayerState* pPlayerState, PlayerStageStats* pPlayerStageStats)
    : ScoreKeeperNormal(pPlayerState, pPlayerStageStats) {
  LogRoutineCoupleDiagnostics(
      "component=scorekeeper event=construct player_state_present=%d "
      "stage_stats_present=%d",
      pPlayerState != nullptr ? 1 : 0, pPlayerStageStats != nullptr ? 1 : 0);
}

bool ScoreKeeperShared::IsMasterScoreKeeper() const {
  if (m_pPlayerState == nullptr || m_pPlayerStageStats == nullptr) {
    LOG->Warn(
        "SRC_AUDIT_FIX: ScoreKeeperShared ignored callback with incomplete "
        "scoring state: PlayerState=%p PlayerStageStats=%p.",
        static_cast<void*>(m_pPlayerState),
        static_cast<void*>(m_pPlayerStageStats));
    return false;
  }
  if (GAMESTATE == nullptr) {
    LOG->Warn(
        "SRC_AUDIT_FIX: ScoreKeeperShared ignored callback because GAMESTATE "
        "is null.");
    return false;
  }
  const PlayerNumber pn = m_pPlayerState->m_PlayerNumber;
  const PlayerNumber master = GAMESTATE->GetMasterPlayerNumber();
  if (!IsValidSharedScorePlayer(pn) || !IsValidSharedScorePlayer(master)) {
    LOG->Warn(
        "SRC_AUDIT_FIX SRC-2066: ScoreKeeperShared ignored callback for "
        "player %i master %i.",
        pn, master);
    return false;
  }
  return pn == master;
}

void ScoreKeeperShared::Load(
    const std::vector<Song*>& apSongs, const std::vector<Steps*>& apSteps,
    const std::vector<AttackArray>& asModifiers) {
  if (!IsMasterScoreKeeper()) {
    return;
  }
  LogRoutineCoupleDiagnostics(
      "component=scorekeeper event=load songs=%zu steps=%zu modifiers=%zu",
      apSongs.size(), apSteps.size(), asModifiers.size());
  ScoreKeeperNormal::Load(apSongs, apSteps, asModifiers);
}

// These ScoreKeepers don't get to draw.
void ScoreKeeperShared::DrawPrimitives() {
  if (!IsMasterScoreKeeper()) {
    return;
  }
  ScoreKeeperNormal::DrawPrimitives();
}

void ScoreKeeperShared::Update(float fDelta) {
  if (!IsMasterScoreKeeper()) {
    return;
  }
  ScoreKeeperNormal::Update(fDelta);
}

void ScoreKeeperShared::OnNextSong(
    int iSongInCourseIndex, const Steps* pSteps, const NoteData* pNoteData) {
  if (!IsMasterScoreKeeper()) {
    return;
  }
  LogRoutineCoupleDiagnostics(
      "component=scorekeeper event=next_song course_index=%d "
      "steps_present=%d note_data_present=%d tracks=%d",
      iSongInCourseIndex, pSteps != nullptr ? 1 : 0,
      pNoteData != nullptr ? 1 : 0,
      pNoteData != nullptr ? pNoteData->GetNumTracks() : 0);
  ScoreKeeperNormal::OnNextSong(iSongInCourseIndex, pSteps, pNoteData);
}

void ScoreKeeperShared::HandleTapScore(const TapNote& tn) {
  if (!IsMasterScoreKeeper()) {
    return;
  }
  ScoreKeeperNormal::HandleTapScore(tn);
  LogRoutineCoupleDiagnostics(
      "component=scorekeeper event=tap judgment=%s offset_ms=%.3f "
      "score=%u actual_dp=%d possible_dp=%d combo=%u miss_combo=%u",
      TapNoteScoreToString(tn.result.tns).c_str(),
      tn.result.fTapNoteOffset * 1000.0f, m_pPlayerStageStats->m_iScore,
      m_pPlayerStageStats->m_iActualDancePoints,
      m_pPlayerStageStats->m_iCurPossibleDancePoints,
      m_pPlayerStageStats->m_iCurCombo,
      m_pPlayerStageStats->m_iCurMissCombo);
}

void ScoreKeeperShared::HandleTapRowScore(const NoteData& nd, int iRow) {
  if (!IsMasterScoreKeeper()) {
    return;
  }
  ScoreKeeperNormal::HandleTapRowScore(nd, iRow);
  LogRoutineCoupleDiagnostics(
      "component=scorekeeper event=tap_row row=%d beat=%.6f tracks=%d "
      "score=%u actual_dp=%d possible_dp=%d combo=%u miss_combo=%u",
      iRow, NoteRowToBeat(iRow), nd.GetNumTracks(),
      m_pPlayerStageStats->m_iScore,
      m_pPlayerStageStats->m_iActualDancePoints,
      m_pPlayerStageStats->m_iCurPossibleDancePoints,
      m_pPlayerStageStats->m_iCurCombo,
      m_pPlayerStageStats->m_iCurMissCombo);
}

void ScoreKeeperShared::HandleHoldScore(const TapNote& tn) {
  if (!IsMasterScoreKeeper()) {
    return;
  }
  ScoreKeeperNormal::HandleHoldScore(tn);
  LogRoutineCoupleDiagnostics(
      "component=scorekeeper event=hold judgment=%s tap=%s score=%u "
      "actual_dp=%d possible_dp=%d",
      HoldNoteScoreToString(tn.HoldResult.hns).c_str(),
      TapNoteScoreToString(tn.result.tns).c_str(),
      m_pPlayerStageStats->m_iScore,
      m_pPlayerStageStats->m_iActualDancePoints,
      m_pPlayerStageStats->m_iCurPossibleDancePoints);
}

void ScoreKeeperShared::HandleHoldActiveSeconds(float fMusicSecondsHeld) {
  if (!IsMasterScoreKeeper()) {
    return;
  }
  ScoreKeeperNormal::HandleHoldActiveSeconds(fMusicSecondsHeld);
}

void ScoreKeeperShared::HandleHoldCheckpointScore(
    const NoteData& nd, int iRow, int iNumHoldsHeldThisRow,
    int iNumHoldsMissedThisRow) {
  if (!IsMasterScoreKeeper()) {
    return;
  }
  ScoreKeeperNormal::HandleHoldCheckpointScore(
      nd, iRow, iNumHoldsHeldThisRow, iNumHoldsMissedThisRow);
  LogRoutineCoupleDiagnostics(
      "component=scorekeeper event=hold_checkpoint row=%d beat=%.6f held=%d "
      "missed=%d score=%u actual_dp=%d possible_dp=%d",
      iRow, NoteRowToBeat(iRow), iNumHoldsHeldThisRow,
      iNumHoldsMissedThisRow, m_pPlayerStageStats->m_iScore,
      m_pPlayerStageStats->m_iActualDancePoints,
      m_pPlayerStageStats->m_iCurPossibleDancePoints);
}

void ScoreKeeperShared::HandleTapScoreNone() {
  if (!IsMasterScoreKeeper()) {
    return;
  }
  ScoreKeeperNormal::HandleTapScoreNone();
  LogRoutineCoupleDiagnostics(
      "component=scorekeeper event=tap_none score=%u actual_dp=%d "
      "possible_dp=%d combo=%u miss_combo=%u",
      m_pPlayerStageStats->m_iScore,
      m_pPlayerStageStats->m_iActualDancePoints,
      m_pPlayerStageStats->m_iCurPossibleDancePoints,
      m_pPlayerStageStats->m_iCurCombo,
      m_pPlayerStageStats->m_iCurMissCombo);
}

/*
 * (c) 2006-2010 Steve Checkoway, Glenn Maynard
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
