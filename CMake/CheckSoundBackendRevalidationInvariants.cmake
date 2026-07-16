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
  "src/arch/Sound/RageSoundDriver_ALSA9_Software.h"
  "unsigned m_iWriteaheadFrames"
  "ALSA write-ahead and latency state must belong to each driver")
require_not_contains(
  "src/arch/Sound/RageSoundDriver_ALSA9_Software.cpp"
  "static unsigned g_iMaxWriteahead"
  "ALSA instances must not share mutable write-ahead state")
require_contains(
  "src/arch/Sound/RageSoundDriver_PulseAudio.cpp"
  "pa_threaded_mainloop_stop(m_PulseMainLoop)"
  "PulseAudio callbacks must stop before their handles are released")
require_contains(
  "src/arch/Sound/RageSoundDriver_PulseAudio.h"
  "mutable std::mutex m_StateMutex"
  "PulseAudio initialization errors cross threads and require synchronization")
require_contains(
  "src/arch/Sound/RageSoundDriver_JACK.h"
  "std::atomic<jack_client_t*> client"
  "JACK shutdown and realtime callbacks must synchronize client ownership")
require_contains(
  "src/arch/Sound/RageSoundDriver_JACK.cpp"
  "last_frame.load(std::memory_order_acquire)"
  "JACK position queries need a safe fallback after server shutdown")
require_contains(
  "src/arch/Sound/RageSoundDriver_AU.mm"
  "AudioOutputUnitStop(m_OutputUnit)"
  "AudioUnit destruction must stop output outside the realtime callback")
require_contains(
  "src/arch/Sound/RageSoundDriver_AU.mm"
  "buf.mDataByteSize"
  "AudioUnit rendering must validate the capacity supplied by CoreAudio")
require_not_contains(
  "src/arch/Sound/RageSoundDriver_AU.mm"
  "new RageThreadRegister"
  "The AudioUnit realtime callback must not allocate thread metadata")
require_contains(
  "src/arch/Sound/RageSoundDriver_OSS.h"
  "std::atomic<int64_t> last_cursor_pos"
  "OSS write and playback cursors cross threads and must be atomic")

message(STATUS "Sound backend revalidation invariants passed")
