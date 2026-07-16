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
  "src/ScreenDebugOverlay.cpp"
  "static std::unordered_set<std::string> warned_messages"
  "Recoverable debug warnings must be deduplicated")
require_contains(
  "src/ScreenDebugOverlay.cpp"
  "THEME->IsThemeLoaded() && LUA != nullptr"
  "Theme actors and metrics require the Lua runtime")
require_contains(
  "src/ScreenDebugOverlay.cpp"
  "bool AreDebugLayoutMetricsLoaded()"
  "Required debug layout metrics must be checked before use")
require_contains(
  "src/ScreenDebugOverlay.cpp"
  "if (!IsFinite(fDeltaTime) || fDeltaTime < 0.0f)"
  "Image scaling must reject invalid frame deltas")
require_contains(
  "src/ScreenDebugOverlay.cpp"
  "if (input.type != IET_FIRST_PRESS)"
  "Debug toggles must distinguish first presses")
require_contains(
  "src/ScreenDebugOverlay.cpp"
  "GameLoop::SetUpdateRate(1.0f);"
  "A disabled overlay must restore the normal update rate")
require_contains(
  "src/ScreenDebugOverlay.cpp"
  "ignored non-finite sound volume delta"
  "Sound volume adjustments must reject non-finite input")
require_contains(
  "src/ScreenDebugOverlay.cpp"
  "ignored non-finite visual delay delta"
  "Visual-delay adjustments must reject non-finite input")
require_not_contains(
  "src/ScreenDebugOverlay.cpp"
  "FAIL_M("
  "Debug overlay corruption must not terminate the process")

message(STATUS "Debug overlay revalidation invariants passed")
