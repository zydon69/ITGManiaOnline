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
read_source("src/PerfDiagnostics.cpp" perf_diagnostics_cpp)
read_source("src/PerfDiagnostics.h" perf_diagnostics_h)
read_source("src/RageSoundPosMap.cpp" rage_sound_pos_map_cpp)
read_source("src/arch/Sound/RageSoundDriver.h" rage_sound_driver_h)
read_source("src/arch/Sound/RageSoundDriver_Generic_Software.cpp" rage_sound_driver_generic_cpp)
read_source("src/GameSoundManager.h" game_sound_manager_h)
read_source("src/GameSoundManager.cpp" game_sound_manager_cpp)
read_source("src/StepMania.cpp" stepmania_cpp)
read_source("src/RageDisplay.cpp" rage_display_cpp)
read_source("src/arch/LowLevelWindow/LowLevelWindow_MacOSX.mm" macos_window_cpp)
read_source("src/CMakeLists.txt" src_cmake_lists)
read_source("src/CMakeData-rage.cmake" cmake_data_rage)

require_contains("${rage_sound_h}" "#include <atomic>" "RageSound uses atomics")
require_contains(
  "${perf_diagnostics_h}"
  "bool PerfDiagnosticsEnabled();"
  "Perf diagnostics exposes a single master switch helper")
require_contains(
  "${perf_diagnostics_cpp}"
  "Preference<bool> g_bPerfDiagnostics(\"PerfDiagnostics\", false)"
  "Perf diagnostics are disabled by default and enabled by one preference")
require_contains(
  "${cmake_data_rage}"
  "PerfDiagnostics.cpp"
  "Perf diagnostics implementation is compiled into the game")
require_not_contains(
  "${perf_diagnostics_h}"
  "PerfDiagnosticsTraceThreshold"
  "Perf diagnostics exposes only the shared master switch")
require_contains(
  "${rage_sound_driver_generic_cpp}"
  "PerfDiagnosticsEnabled()"
  "Audio underrun tracing follows the shared perf diagnostics switch")
require_contains(
  "${macos_window_cpp}"
  "PerfDiagnosticsEnabled()"
  "macOS present tracing follows the shared perf diagnostics switch")
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
  "${rage_sound_driver_h}"
  "#include <atomic>"
  "Generic software sound driver state uses atomics")
require_contains(
  "${rage_sound_driver_h}"
  "std::atomic<State> m_State;"
  "Generic software sound slot state is atomic")
require_contains(
  "${rage_sound_driver_h}"
  "m_State.load(order)"
  "Generic software sound state reads use explicit memory ordering")
require_contains(
  "${rage_sound_driver_h}"
  "m_State.store(state, order)"
  "Generic software sound state writes use explicit memory ordering")
require_not_matches(
  "${rage_sound_driver_generic_cpp}"
  "m_State[ \t]*(==|!=|=)"
  "Generic software sound state must use GetState/SetState")
require_contains(
  "${rage_sound_pos_map_cpp}"
  "kMinorPositionDriftToleranceMs"
  "Audio position drift tolerance is expressed in milliseconds")
require_contains(
  "${rage_sound_pos_map_cpp}"
  "MinorPositionDriftFramesForRate"
  "Audio position drift tolerance is converted using the active frame rate")
require_not_contains(
  "${rage_sound_pos_map_cpp}"
  "kMinorPositionDriftFrames"
  "Audio position drift tolerance must not be a fixed frame count")

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
  "${stepmania_cpp}"
  "#if defined(__APPLE__)"
  "Forced audio runtime defaults are restricted to macOS")
require_contains(
  "${macos_window_cpp}"
  "static bool MacOSOpenGLHardwareVsyncForcedEnabled()"
  "macOS hardware-vsync policy is an internal disabled helper")
require_contains(
  "${macos_window_cpp}"
  "return false;"
  "macOS hardware-vsync forcing is disabled in final baseline")
require_contains(
  "${macos_window_cpp}"
  "static GLint DesiredMacOSMPSwapsInFlight()"
  "macOS OpenGL MPS swaps policy is explicit")
require_contains(
  "${macos_window_cpp}"
  "return 1;"
  "macOS OpenGL final baseline keeps one MP swap in flight")
require_contains(
  "${macos_window_cpp}"
  "MacOSOpenGLFencePacingWaitMs"
  "macOS OpenGL fence wait is a pacing feature, not a diagnostics flag")
require_not_contains(
  "${macos_window_cpp}"
  "Preference<bool> g_bMacOSOpenGLFenceTrace"
  "macOS OpenGL fence trace must use the shared PerfDiagnostics switch")
require_not_contains(
  "${macos_window_cpp}"
  "MacOSOpenGLFenceDiagnostics"
  "macOS OpenGL fence pacing must not be gated by diagnostics naming")
require_not_contains(
  "${macos_window_cpp}"
  "Preference<bool> g_bMacOSOpenGLHardwareVsyncTest"
  "Rejected hardware-vsync test must not be exposed as a saved preference")
require_not_contains(
  "${macos_window_cpp}"
  "Preference<int> g_iMacOSOpenGLMPSwapsInFlight"
  "Rejected MPS swaps test must not be exposed as a saved preference")
require_not_contains(
  "${macos_window_cpp}"
  "Preference<bool> g_bMacOSFramePacingUseDisplayLink"
  "Final DisplayLink pacing enablement must not be exposed as a saved preference")
require_not_contains(
  "${macos_window_cpp}"
  "Preference<int> g_iMacOSFramePacingOutputAlignedPresentMode"
  "Final output-aligned present mode must not be exposed as a saved preference")
require_not_contains(
  "${macos_window_cpp}"
  "Preference<int> g_iMacOSOpenGLOffscreenPresentMode"
  "Final offscreen present policy must not be exposed as a saved preference")
require_not_contains(
  "${macos_window_cpp}"
  "Preference<int> g_iMacOSOpenGLOffscreenPresentMinRate"
  "Final offscreen present min rate must not be exposed as a saved preference")
require_not_contains(
  "${rage_display_cpp}"
  "Preference<bool> g_bFramePacingMacOSAdaptiveLead"
  "Rejected macOS adaptive lead must not be exposed as a saved preference")
require_not_contains(
  "${game_sound_manager_cpp}"
  "Preference<bool> g_bOpenGLPreFramePacingSync"
  "OpenGL pre-frame pacing must not be exposed from the wrong module")
read_source("src/RageDisplay_OGL.cpp" rage_display_ogl_cpp)
require_not_contains(
  "${rage_display_ogl_cpp}"
  "Preference<bool> g_bOpenGLPreFramePacingSync"
  "Final OpenGL pre-frame pacing sync must not be exposed as a saved preference")
require_not_contains(
  "${rage_display_ogl_cpp}"
  "Preference<bool> g_bOpenGLPreFramePacingFinishOnBackpressure"
  "Final OpenGL backpressure finish policy must not be exposed as a saved preference")
require_not_contains(
  "${rage_display_ogl_cpp}"
  "Preference<bool> g_bOpenGLPreFramePacingProactiveFinish"
  "Final OpenGL proactive finish policy must not be exposed as a saved preference")
require_not_contains(
  "${rage_display_ogl_cpp}"
  "Preference<bool> g_bOpenGLPreFramePacingContinuousFinish"
  "Rejected continuous OpenGL finish must not be exposed as a saved preference")
require_contains(
  "${src_cmake_lists}"
  "audio_playonce_runtime_smoke"
  "CTest runs a real PlayOnce runtime smoke test")
