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
  "src/RageSoundReader_Merge.cpp"
  "GetNextSourceFrame64()"
  "Merge readers must preserve 64-bit source positions")
require_contains(
  "src/RageSoundReader_Merge.cpp"
  "merge seek and rollback failed"
  "Merge seeks must diagnose failed per-source rollback")
require_contains(
  "src/arch/Sound/RageSoundDriver.h"
  "std::atomic<bool> m_bPaused"
  "Pause state shared with realtime threads must be atomic")
require_contains(
  "src/arch/Sound/RageSoundDriver.h"
  "std::atomic<int> m_iUnderruns"
  "Underrun accounting shared across threads must be atomic and per driver")
require_contains(
  "src/arch/Sound/RageSoundDriver.h"
  "std::atomic<int64_t> m_iMaxHardwareFrame"
  "The monotonic hardware cursor must be synchronized")
require_contains(
  "src/arch/Sound/RageSoundDriver_Generic_Software.cpp"
  "char activeSlotSummary[1024]"
  "Realtime underrun diagnostics must use bounded stack storage")
require_contains(
  "src/arch/Sound/RageSoundDriver_Generic_Software.cpp"
  "GetOutputBufferBytes"
  "Backend output buffer byte arithmetic must be checked")
require_contains(
  "src/arch/Sound/RageSoundDriver.cpp"
  "EqualsNoCase(candidate, driversToTry[to_try])"
  "Configured sound driver names must be canonicalized case-insensitively")
require_not_contains(
  "src/arch/Sound/RageSoundDriver_Generic_Software.cpp"
  "static int frames_to_buffer"
  "Decode buffer configuration must not be shared by driver instances")

message(STATUS "Sound driver safety invariants passed")
