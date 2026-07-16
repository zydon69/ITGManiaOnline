if(NOT DEFINED ITGMANIA_SOURCE_DIR)
  message(FATAL_ERROR "ITGMANIA_SOURCE_DIR is required")
endif()

function(require_contains file needle description)
  file(READ "${ITGMANIA_SOURCE_DIR}/${file}" contents)
  string(FIND "${contents}" "${needle}" position)
  if(position EQUAL -1)
    message(FATAL_ERROR "${description}: '${needle}' missing from ${file}")
  endif()
endfunction()

function(require_not_contains file needle description)
  file(READ "${ITGMANIA_SOURCE_DIR}/${file}" contents)
  string(FIND "${contents}" "${needle}" position)
  if(NOT position EQUAL -1)
    message(FATAL_ERROR "${description}: forbidden '${needle}' remains in ${file}")
  endif()
endfunction()

require_contains(
  "src/ScreenSyncOverlay.cpp"
  "THEME->IsThemeLoaded() && LUA != nullptr"
  "Sync overlay actor loading requires both theme and Lua runtime")
require_contains(
  "src/ScreenSyncOverlay.cpp"
  "std::vector<PendingBPSUpdate> updates"
  "BPM mutations must be prepared before publication")
require_contains(
  "src/ScreenSyncOverlay.cpp"
  "std::vector<std::pair<TimingData*, float>> updates"
  "Song offset mutations must be prepared before publication")
require_not_contains(
  "src/ScreenSyncOverlay.cpp"
  "ApplyBPSDeltaToTiming"
  "Sync BPM validation must not mutate each timing incrementally")

message(STATUS "Sync overlay revalidation invariants passed")
