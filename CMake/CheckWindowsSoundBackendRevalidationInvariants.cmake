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
  "src/arch/Sound/RageSoundDriver_WaveOut.h"
  "std::atomic<int64_t> wo_last_hardware_position_"
  "WaveOut hardware position extension must be synchronized")
require_not_contains(
  "src/arch/Sound/RageSoundDriver_WaveOut.h"
  "wo_init_success_"
  "Dead WaveOut initialization state must not return")
require_contains(
  "src/arch/Sound/RageSoundDriver_DSound_Software.h"
  "int m_iWriteaheadFrames"
  "DirectSound write-ahead must belong to each driver instance")
require_not_contains(
  "src/arch/Sound/RageSoundDriver_DSound_Software.cpp"
  "static int g_iMaxWriteahead"
  "DirectSound instances must not share mutable write-ahead state")
require_contains(
  "src/arch/Sound/RageSoundDriver_WASAPI.cpp"
  "padding > m_iBufferSizeFrames"
  "WASAPI must reject impossible endpoint padding")
require_contains(
  "src/arch/Sound/RageSoundDriver_WASAPI.cpp"
  "static_cast<long double>(position)"
  "WASAPI clock conversion must avoid integer multiplication overflow")
require_contains(
  "src/arch/Sound/RageSoundDriver_WDMKS.cpp"
  "GetOverlappedResult("
  "WDMKS overlapped requests must collect their final result")
require_contains(
  "src/arch/Sound/RageSoundDriver_WDMKS.cpp"
  "Timed out waiting for WDMKS DeviceIoControl"
  "WDMKS control requests must have a finite deadline")
require_contains(
  "src/arch/Sound/RageSoundDriver_WDMKS.cpp"
  "identifierCapacity"
  "WDMKS identifier counts must be bounded by returned storage")
require_contains(
  "src/arch/Sound/RageSoundDriver_WDMKS.cpp"
  "nextDataRange"
  "WDMKS data-range iteration must advance on rejected entries")
require_contains(
  "src/arch/Sound/RageSoundDriver_WDMKS.cpp"
  "pDataRange->FormatSize < sizeof(KSDATARANGE_AUDIO)"
  "WDMKS audio ranges must contain the complete audio structure")
require_contains(
  "src/arch/Sound/RageSoundDriver_WDMKS.h"
  "RAGE_SOUND_WDMKS_H"
  "WDMKS must have an independent include guard")
require_not_contains(
  "src/arch/Sound/RageSoundDriver_WDMKS.cpp"
  "memset(this, 0, sizeof(*this))"
  "WDMKS stream construction must initialize fields without erasing the object")
require_contains(
  "src/arch/Sound/RageSoundDriver_WDMKS.cpp"
  "ResetEvent(signal.hEvent)"
  "Reusable WDMKS overlapped packets must reset their event and state")
require_contains(
  "src/arch/Sound/RageSoundDriver_WDMKS.h"
  "std::atomic<int64_t> m_iLastCursorPos"
  "WDMKS position fallback crosses threads and must remain synchronized")

message(STATUS "Windows sound backend revalidation invariants passed")
