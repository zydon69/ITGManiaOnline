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
  "src/Screen.cpp"
  "const InputScheme* inputScheme = INPUTMAPPER->GetInputScheme();"
  "Lua input dispatch must snapshot and validate the active input scheme")
require_contains(
  "src/Screen.cpp"
  "std::vector<LuaReference> callbacks;"
  "Lua input dispatch must snapshot callbacks before invoking them")
require_contains(
  "src/Screen.cpp"
  "fDelay = SanitizeNonNegativeSeconds(fDelay);"
  "Posted screen-message delays must be finite and non-negative")
require_contains(
  "src/ScreenAttract.cpp"
  "IsReadyForAttractInput(pScreen)"
  "Attract input must respect transition and input-lock state")
require_contains(
  "src/ScreenAttract.cpp"
  "IsScreenUsable(startScreenName)"
  "Attract start-screen transitions must validate their target")
require_contains(
  "src/ScreenManager.cpp"
  "pNewScreen->SetMessageDeliveryEnabled(false);"
  "Prepared screens must not receive global messages before activation")
require_contains(
  "src/ScreenManager.cpp"
  "ls.m_pScreen->SetMessageDeliveryEnabled(true);"
  "Prepared screens must resume global messages when activated")
require_contains(
  "src/MessageManager.cpp"
  "if (!subscriber->IsMessageDeliveryEnabled())"
  "Message dispatch must skip inactive prepared-screen subscribers")
require_contains(
  "src/MessageManager.h"
  "std::atomic<bool> m_bMessageDeliveryEnabled;"
  "Prepared-screen message gating must be race-free during concurrent loading")

message(STATUS "Screen core safety invariants passed")
