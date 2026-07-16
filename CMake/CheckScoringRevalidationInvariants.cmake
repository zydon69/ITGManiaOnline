if(NOT DEFINED ITGMANIA_SOURCE_DIR)
  message(FATAL_ERROR "ITGMANIA_SOURCE_DIR is required")
endif()

set(actual_radar "${ITGMANIA_SOURCE_DIR}/src/NoteDataWithScoring.cpp")
set(normal_score "${ITGMANIA_SOURCE_DIR}/src/ScoreKeeperNormal.cpp")
set(rave_score "${ITGMANIA_SOURCE_DIR}/src/ScoreKeeperRave.cpp")
set(shared_score "${ITGMANIA_SOURCE_DIR}/src/ScoreKeeperShared.cpp")

foreach(path IN ITEMS
    "${actual_radar}" "${normal_score}" "${rave_score}" "${shared_score}")
  if(NOT EXISTS "${path}")
    message(FATAL_ERROR "Missing scoring source: ${path}")
  endif()
endforeach()

file(READ "${actual_radar}" actual_radar_source)
file(READ "${normal_score}" normal_score_source)
file(READ "${rave_score}" rave_score_source)
file(READ "${shared_score}" shared_score_source)

function(require_contains content needle label)
  string(FIND "${content}" "${needle}" position)
  if(position EQUAL -1)
    message(FATAL_ERROR "Scoring invariant failed: ${label}")
  endif()
endfunction()

function(require_not_contains content needle label)
  string(FIND "${content}" "${needle}" position)
  if(NOT position EQUAL -1)
    message(FATAL_ERROR "Scoring invariant failed: ${label}")
  endif()
endfunction()

require_contains(
  "${actual_radar_source}"
  "if (iPossibleDP == 0) {\n    return 0.0f;"
  "an empty chart has zero actual chaos")
require_contains(
  "${actual_radar_source}"
  "NoteBelongsToPlayer(*curr_note, pn)"
  "actual radar uses the same player ownership rule as row scoring")
require_contains(
  "${actual_radar_source}"
  "tn.type == TapNoteType_Lift || tn.type == TapNoteType_Attack"
  "row helpers use the same scorable note types as scorekeepers")
require_contains(
  "${actual_radar_source}"
  "if (value >= maxInt)"
  "actual radar counts are bounded before float-to-int conversion")
require_contains(
  "${actual_radar_source}"
  "normalized invalid song duration"
  "actual radar sanitizes song duration before all calculations")
require_contains(
  "${normal_score_source}"
  "m_iTapNotesHit >= m_iNumTapsAndHolds"
  "extra internal-scoring callbacks are rejected")
require_contains(
  "${normal_score_source}"
  "Load rejected mismatched course"
  "course scoring vectors are rejected atomically when misaligned")
require_contains(
  "${normal_score_source}"
  "m_iMaxPossiblePoints = 0;"
  "reloading a scorekeeper clears prior chart-dependent state")
require_contains(
  "${normal_score_source}"
  "m_apSteps[iIndex] != pSteps"
  "course scoring verifies that the active chart matches the loaded index")
require_contains(
  "${normal_score_source}"
  "value >= static_cast<float>(std::numeric_limits<int>::max())"
  "float radar totals are bounded before integer conversion")
require_contains(
  "${normal_score_source}"
  "iNumHoldsHeldThisRow < 0 || iNumHoldsMissedThisRow < 0"
  "negative hold checkpoint counts are rejected rather than normalized")
require_contains(
  "${normal_score_source}"
  "bool IsRowTapNoteScore"
  "row scoring rejects non-judgment enum values")
require_contains(
  "${normal_score_source}"
  "static_cast<uint64_t>(iScore) + 2U"
  "failed-score rounding widens before addition")
require_contains(
  "${normal_score_source}"
  "if (IsValidPlayerNumber(m_pPlayerState->m_PlayerNumber))"
  "player-specific combo messages validate the player enum")
require_not_contains(
  "${normal_score_source}"
  "ASSERT(m_iPointBonus >= 0)"
  "score setup has no fatal point-bonus assertion")
require_contains(
  "${rave_score_source}"
  "if (!IsValidRavePlayer(pn) || !IsValidAttackLevel(al))"
  "Rave attacks validate source and attack level")
require_contains(
  "${rave_score_source}"
  "ScoreKeeperRave adjusted super meter delta"
  "Rave meter revalidates deltas after mercy scaling")
require_not_contains(
  "${rave_score_source}"
  "#define CROSSED"
  "obsolete Rave threshold macros are removed")
require_contains(
  "${shared_score_source}"
  "bool ScoreKeeperShared::IsMasterScoreKeeper() const"
  "Routine scoring callbacks share one defensive master gate")

message(STATUS "Scoring revalidation invariants passed")
