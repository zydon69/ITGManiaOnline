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
  "src/ScreenSystemLayer.cpp"
  "static std::unordered_set<std::string> warned_messages"
  "Recoverable system-layer warnings must be deduplicated")
require_contains(
  "src/ScreenSystemLayer.cpp"
  "if (coins_per_credit <= 0)"
  "Coins-per-credit must be validated before division")
require_contains(
  "src/ScreenSystemLayer.cpp"
  "case MemoryCardState_Invalid:"
  "Invalid memory-card states must be handled explicitly")
require_contains(
  "src/ScreenSystemLayer.h"
  "void Init() override;"
  "System-layer overrides must be compile-time checked")
require_not_contains(
  "src/ScreenSystemLayer.cpp"
  "DEFAULT_FAIL(mcs)"
  "Memory-card corruption must not terminate the process")

message(STATUS "System layer revalidation invariants passed")
