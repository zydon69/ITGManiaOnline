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

require_contains(
  "src/ScreenTestInput.cpp"
  "SanitizeInputMessageName"
  "Dynamic test-input message names must be sanitized")
require_contains(
  "src/ScreenTestInput.cpp"
  "const bool bParentHandled = Screen::Input(input)"
  "The parent screen must receive input before diagnostic broadcasts")
require_contains(
  "src/ScreenTestLights.cpp"
  "bool IsValidTestPlayer(PlayerNumber player)"
  "Light-test player dispatch must validate the complete enum range")
require_contains(
  "src/ScreenTestLights.cpp"
  "bool IsValidCabinetLight(CabinetLight light)"
  "Cabinet-light display must reject invalid enum values")
require_contains(
  "src/ScreenTestLights.cpp"
  "bool IsCycleInputType(InputEventType type)"
  "Manual light cycling must accept only discrete navigation events")
require_contains(
  "src/ScreenTestLights.cpp"
  "m_bTextReady = false;"
  "Repeated light-test initialization must clear stale font readiness")

message(STATUS "Test screen safety invariants passed")
