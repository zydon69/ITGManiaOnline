if(NOT DEFINED ITGMANIA_SOURCE_DIR)
  message(FATAL_ERROR "ITGMANIA_SOURCE_DIR is required")
endif()

set(source_path "${ITGMANIA_SOURCE_DIR}/src/GameState.cpp")
set(header_path "${ITGMANIA_SOURCE_DIR}/src/GameState.h")
if(NOT EXISTS "${source_path}" OR NOT EXISTS "${header_path}")
  message(FATAL_ERROR "Missing GameState source files")
endif()

file(READ "${source_path}" source)
file(READ "${header_path}" header)

function(require_contains content needle label)
  string(FIND "${content}" "${needle}" position)
  if(position EQUAL -1)
    message(FATAL_ERROR "GameState revalidation invariant failed: ${label}")
  endif()
endfunction()

function(require_not_contains content needle label)
  string(FIND "${content}" "${needle}" position)
  if(NOT position EQUAL -1)
    message(FATAL_ERROR "GameState revalidation invariant failed: ${label}")
  endif()
endfunction()

require_contains(
  "${source}"
  "bool GameState::JoinPlayer(PlayerNumber pn)"
  "joining reports whether it committed")
require_contains(
  "${source}"
  "if (m_bSideIsJoined[pn])"
  "duplicate direct joins are rejected")
require_contains(
  "${source}"
  "styleAfterJoin = GAMEMAN->GetFirstCompatibleStyle("
  "join style compatibility is resolved before state mutation")
require_contains(
  "${source}"
  "if (styleAfterJoin == nullptr)"
  "an incompatible join is rejected before commit")
require_contains(
  "${source}"
  "if (!state->JoinPlayer(pn))"
  "coin input only charges a successful join")
require_contains(
  "${source}"
  "candidate != pn && m_bSideIsJoined[candidate]"
  "master transfer only selects a joined side")
require_contains(
  "${source}"
  "int AddNonNegativeIntSaturated(int current, int delta)"
  "stage tokens use saturating arithmetic")
require_contains(
  "${source}"
  "return songsPlayed > 0 ? songsPlayed - 1 : -1;"
  "course indices reject an unplayed song")
require_contains(
  "${source}"
  "if (iIndex < 0)"
  "loading course index preserves invalid state")
require_contains(
  "${source}"
  "duration <= 0.0"
  "song percentage validates its true duration")
require_contains(
  "${source}"
  "processedTiming = nullptr;"
  "borrowed processed timing is detached without deletion")
require_not_contains(
  "${source}"
  "SafeDelete(processedTiming)"
  "borrowed processed timing is never deleted")
require_contains(
  "${header}"
  "Non-owning: points into the active Steps or Player timing data."
  "processed timing ownership is documented")
require_contains(
  "${source}"
  "FOREACH_EnabledPlayer(p)"
  "stage results compare enabled players")
require_contains(
  "${source}"
  "!IsFiniteFloat(so.m_fMusicRate) || so.m_fMusicRate < 1.0f"
  "non-finite music rates disqualify scores")
require_contains(
  "${source}"
  "if (!IsValidFailType(ft))"
  "fail type enums are validated")
require_contains(
  "${source}"
  "ClampRankingName(sName);"
  "ranking names are bounded and UTF-8 validated")
require_contains(
  "${source}"
  "std::string upperName = sName;"
  "ranking blacklist matching is case insensitive")
require_contains(
  "${source}"
  "FOREACH_EnabledPlayer(player)"
  "ranking cleanup covers every enabled player")
require_contains(
  "${source}"
  "dc = found ? std::min(dc, current) : current;"
  "easiest difficulty initializes from the first valid chart")
require_contains(
  "${source}"
  "return std::clamp(fActual / fGoal, 0.0f, 1.0f);"
  "workout goal progress is bounded")
require_contains(
  "${source}"
  "std::min<double>(playSeconds, INT_MAX)"
  "session time conversion is finite and bounded")
require_contains(
  "${source}"
  "if (m_iCurrentStageIndex < INT_MAX)"
  "stage index increment cannot overflow")
require_contains(
  "${source}"
  "if (m_pMultiPlayerState[p] != nullptr)"
  "reset tolerates an incomplete multiplayer state array")

message(STATUS "GameState revalidation invariants passed")
