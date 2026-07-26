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
  "src/ScreenSplash.cpp"
  "ClearMessageQueue(SM_PrepareNextScreen)"
  "Splash screens must discard stale delayed preparation messages")
require_contains(
  "src/ScreenSplash.cpp"
  "IsScreenNameValid(prepare_screen)"
  "Splash preparation targets must remain validated")
require_contains(
  "src/ScreenStatsOverlay.cpp"
  "if (UpdateTime > 0.1f)"
  "Stats skip severity must evaluate the absolute severe threshold")
require_contains(
  "src/ScreenStatsOverlay.cpp"
  "Presentation drop: new="
  "Stats must expose renderer presentation drops even when engine updates stay fast")
require_not_contains(
  "src/ScreenStatsOverlay.cpp"
  "while (Thresholds[skip]"
  "Skip severity must not depend on FPS-sensitive threshold ordering")

message(STATUS "Splash and stats safety invariants passed")
