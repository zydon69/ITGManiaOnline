if(NOT DEFINED ITGMANIA_SOURCE_DIR)
  message(FATAL_ERROR "ITGMANIA_SOURCE_DIR is required")
endif()

function(read_source relative_path output_var)
  set(path "${ITGMANIA_SOURCE_DIR}/${relative_path}")
  if(NOT EXISTS "${path}")
    message(FATAL_ERROR "Missing source file: ${path}")
  endif()
  file(READ "${path}" contents)
  set("${output_var}" "${contents}" PARENT_SCOPE)
endfunction()

function(require_contains haystack needle label)
  string(FIND "${haystack}" "${needle}" found_at)
  if(found_at EQUAL -1)
    message(FATAL_ERROR "Missing invariant: ${label}")
  endif()
endfunction()

function(require_not_contains haystack needle label)
  string(FIND "${haystack}" "${needle}" found_at)
  if(NOT found_at EQUAL -1)
    message(FATAL_ERROR "Forbidden pattern present: ${label}")
  endif()
endfunction()

function(require_not_matches haystack pattern label)
  string(REGEX MATCH "${pattern}" match "${haystack}")
  if(NOT match STREQUAL "")
    message(FATAL_ERROR "Forbidden pattern present: ${label}")
  endif()
endfunction()

read_source("src/RageSound.h" rage_sound_h)
read_source("src/RageSound.cpp" rage_sound_cpp)
read_source("src/GameSoundManager.h" game_sound_manager_h)
read_source("src/GameSoundManager.cpp" game_sound_manager_cpp)
read_source("src/StepMania.cpp" stepmania_cpp)
read_source("src/CMakeLists.txt" src_cmake_lists)

require_contains("${rage_sound_h}" "#include <atomic>" "RageSound uses atomics")
require_contains(
  "${rage_sound_h}"
  "std::atomic_bool m_bPlaying;"
  "RageSound playing state is atomic")
require_contains(
  "${rage_sound_h}"
  "m_bPlaying.load(std::memory_order_acquire)"
  "RageSound IsPlaying uses atomic acquire load")
require_not_matches(
  "${rage_sound_h}"
  "(^|\n)[ \t]*bool[ \t]+m_bPlaying;"
  "RageSound must not use a raw bool playing state")

require_contains(
  "${rage_sound_cpp}"
  "m_bPlaying.store(true, std::memory_order_release)"
  "RageSound StartPlaying publishes playing state atomically")
require_contains(
  "${rage_sound_cpp}"
  "m_bPlaying.store(false, std::memory_order_release)"
  "RageSound clears playing state atomically")
require_contains(
  "${rage_sound_cpp}"
  "bool bPrebuffer = false;"
  "RageSound initializes bPrebuffer before OpenFile")
require_contains(
  "${rage_sound_cpp}"
  "m_sError = \"\";"
  "RageSound clears load error before each load")
require_contains(
  "${rage_sound_cpp}"
  "return m_sError.empty();"
  "RageSound Load reports failed opens to callers")
require_contains(
  "${rage_sound_cpp}"
  "RageSound::Load: error preloading sound"
  "RageSound Load reports preload decode errors to callers")

require_contains(
  "${game_sound_manager_cpp}"
  "DeleteUnregisteredSoundPool"
  "PlayOnce separates unregistered pool deletion")
require_contains(
  "${game_sound_manager_cpp}"
  "DeleteRegisteredSoundPool"
  "PlayOnce separates registered pool deletion")
require_contains(
  "${game_sound_manager_cpp}"
  "IsKnownSilentPlaceholderSound"
  "PlayOnce allows explicit silent placeholders")
require_contains(
  "${game_sound_manager_cpp}"
  "PlayOnce sound rejected because it has no playable audio"
  "PlayOnce rejects non-placeholder zero-length cached sounds")
require_contains(
  "${game_sound_manager_cpp}"
  "Music load failed; continuing with silent fallback"
  "Critical music loads log explicit Load failures")
require_contains(
  "${game_sound_manager_cpp}"
  "PlayOnce invariant violation: empty registered pool"
  "PlayOnce detects empty registered pools")
require_contains(
  "${game_sound_manager_cpp}"
  "empty_pools=%zu"
  "PlayOnce diagnostics include empty pool count")
require_not_contains(
  "${game_sound_manager_cpp}"
  "g_DirSoundOrder.erase"
  "PlayOnce eviction must not mutate directory playback order")
require_contains(
  "${game_sound_manager_h}"
  "RunPlayOnceRuntimeSmokeTest"
  "PlayOnce exposes a runtime smoke test entrypoint")
require_contains(
  "${stepmania_cpp}"
  "playonce-smoke-test"
  "StepMania exposes the PlayOnce runtime smoke test")
require_contains(
  "${stepmania_cpp}"
  "PlayOnce runtime smoke forcing SoundDrivers=Null"
  "PlayOnce runtime smoke uses the Null sound driver")
require_contains(
  "${src_cmake_lists}"
  "audio_playonce_runtime_smoke"
  "CTest runs a real PlayOnce runtime smoke test")
