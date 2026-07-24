if(NOT DEFINED ITGMANIA_SOURCE_DIR)
  message(FATAL_ERROR "ITGMANIA_SOURCE_DIR is required")
endif()

file(READ "${ITGMANIA_SOURCE_DIR}/src/GameLoop.cpp" game_loop_cpp)

function(require_contains needle label)
  string(FIND "${game_loop_cpp}" "${needle}" found_at)
  if(found_at EQUAL -1)
    message(FATAL_ERROR "Missing GameLoop invariant: ${label}")
  endif()
endfunction()

require_contains(
  "if (DISPLAY == nullptr || !std::isfinite(fDeltaTime))"
  "timer-skip diagnostics guard display lifecycle and delta")
require_contains(
  "if (HOOKS == nullptr || INPUTFILTER == nullptr)"
  "focus checks guard hook and input lifecycle")
require_contains(
  "GameLoop update skipped with incomplete managers"
  "main update rejects an incomplete manager graph")
require_contains(
  "GameLoop reset invalid scaled delta"
  "scaled update deltas are revalidated after multiplication")
require_contains(
  "if (!std::isfinite(minIntervalSeconds)"
  "performance trace intervals reject non-finite preferences")
