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
read_source("src/AutoKeysounds.cpp" auto_keysounds_cpp)
read_source("src/RageSoundManager.h" rage_sound_manager_h)
read_source("src/RageSoundManager.cpp" rage_sound_manager_cpp)
read_source("src/RageSoundReader_Extend.cpp" rage_sound_reader_extend_cpp)
read_source("src/RageSoundReader_FileReader.h" rage_sound_reader_file_reader_h)
read_source("src/RageSoundReader_FileReader.cpp" rage_sound_reader_file_reader_cpp)
read_source("src/RageSoundReader_Preload.h" rage_sound_reader_preload_h)
read_source("src/RageSoundReader_Preload.cpp" rage_sound_reader_preload_cpp)
read_source("src/RageSoundReader_Pan.h" rage_sound_reader_pan_h)
read_source("src/RageSoundReader_Pan.cpp" rage_sound_reader_pan_cpp)
read_source("src/RageSoundReader_WAV.h" rage_sound_reader_wav_h)
read_source("src/RageSoundReader_WAV.cpp" rage_sound_reader_wav_cpp)
read_source("src/RageSoundReader_Vorbisfile.h" rage_sound_reader_vorbis_h)
read_source("src/RageSoundReader_Vorbisfile.cpp" rage_sound_reader_vorbis_cpp)
read_source("src/RageSoundReader_MP3.h" rage_sound_reader_mp3_h)
read_source("src/RageSoundReader_MP3.cpp" rage_sound_reader_mp3_cpp)
read_source("src/RageSoundReader_ChannelSplit.h" rage_sound_reader_channel_split_h)
read_source("src/RageSoundReader_ChannelSplit.cpp" rage_sound_reader_channel_split_cpp)
read_source("src/RageSoundMixBuffer.h" rage_sound_mix_buffer_h)
read_source("src/RageSoundMixBuffer.cpp" rage_sound_mix_buffer_cpp)
read_source("src/RageSoundReader_Chain.cpp" rage_sound_reader_chain_cpp)
read_source("src/RageSoundReader_Merge.cpp" rage_sound_reader_merge_cpp)
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
  "LogAudioUnderrunDiagnosticsEnabled()"
  "Audio underrun tracing follows the dedicated audio diagnostics switch")
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
  "${rage_sound_h}"
  "bool m_bLoadSucceeded;"
  "RageSound stores logical load success separately from fallback readers")
require_contains(
  "${rage_sound_h}"
  "RageSoundParams GetParams() const;"
  "RageSound params are returned by value")
require_not_contains(
  "${rage_sound_h}"
  "const RageSoundParams& GetParams() const"
  "RageSound must not expose params by reference")
require_contains(
  "${rage_sound_cpp}"
  "return LoadSucceeded();"
  "RageSound IsLoaded reports logical load success")
require_contains(
  "${rage_sound_cpp}"
  "if (this == &cpy)"
  "RageSound copy assignment handles self-assignment")
require_contains(
  "${rage_sound_cpp}"
  "std::unique_ptr<RageSoundReader> sourceCopy;"
  "RageSound copy assignment prepares a reader before mutating destination")
require_contains(
  "${rage_sound_cpp}"
  "LockMut(m_Mutex);"
  "RageSound reader access is protected by its mutex")
require_contains(
  "${rage_sound_h}"
  "GetDataToPlay("
  "RageSound exposes the driver callback")
require_contains(
  "${rage_sound_h}"
  "int& iBytesRead) override;"
  "RageSound marks driver data callback override")
require_contains(
  "${rage_sound_h}"
  "void CommitPlayingPosition("
  "RageSound exposes driver position callback")
require_contains(
  "${rage_sound_h}"
  "int iGotFrames) override;"
  "RageSound marks driver position callback override")
require_contains(
  "${rage_sound_cpp}"
  "RageSound::SetParam: unknown parameter"
  "RageSound Lua SetParam diagnoses unknown parameter names")
require_contains(
  "${rage_sound_cpp}"
  "lua_pushboolean(L, false);"
  "RageSound Lua SetParam returns failure for unknown parameter names")
require_contains(
  "${rage_sound_cpp}"
  "RageSound::ApplyParams: one or more properties failed"
  "RageSound reports parameter application failures")
require_contains(
  "${rage_sound_cpp}"
  "return m_bLoadSucceeded;"
  "RageSound Load reports logical load success to callers")
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
  "Music load failed; refusing to start silent fallback"
  "Critical music loads refuse silent fallback playback")
require_not_contains(
  "${game_sound_manager_cpp}"
  "continuing with silent fallback"
  "Critical music loads must not promote failed loads to silent music")
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
  "${auto_keysounds_cpp}"
  "AutoKeysounds::AutoKeysounds()"
  "AutoKeysounds initializes owned reader pointers")
require_contains(
  "${auto_keysounds_cpp}"
  "GAMESTATE == nullptr || SOUNDMAN == nullptr"
  "AutoKeysounds FinishLoading guards gameplay audio singletons")
require_contains(
  "${auto_keysounds_cpp}"
  "no playable keysounds were loaded"
  "AutoKeysounds refuses empty sound chains without assert")
require_not_contains(
  "${auto_keysounds_cpp}"
  "ASSERT_M(\n      m_pSharedSound != nullptr"
  "AutoKeysounds must not assert on songs without playable keysounds")
require_contains(
  "${rage_sound_reader_extend_cpp}"
  "SRC_AUDIT_FIX SRC-2751"
  "RageSoundReader_Extend logs null source readers without crashing")
require_not_contains(
  "${rage_sound_reader_extend_cpp}"
  "ASSERT_M(\n      pSource != nullptr"
  "RageSoundReader_Extend must not assert on null source readers")
require_contains(
  "${rage_sound_reader_file_reader_h}"
  "std::string GetError() const override"
  "RageSoundReader_FileReader exposes base reader diagnostics with override")
require_contains(
  "${rage_sound_reader_file_reader_h}"
  "OPEN_FATAL_ERROR."
  "RageSoundReader_FileReader open contract references a real enum")
require_contains(
  "${rage_sound_reader_file_reader_cpp}"
  "SRC_AUDIT_FIX SRC-2794"
  "RageSoundReader_FileReader converts allocation failures into open errors")
require_contains(
  "${rage_sound_reader_file_reader_cpp}"
  "*pPrebuffer = false;"
  "RageSoundReader_FileReader initializes prebuffer state for callers")
require_contains(
  "${rage_sound_reader_preload_h}"
  "std::string GetError() const override"
  "RageSoundReader_Preload exposes local preload diagnostics")
require_contains(
  "${rage_sound_reader_preload_h}"
  "size_t GetFrameSizeBytes() const;"
  "RageSoundReader_Preload keeps byte arithmetic in size_t helpers")
require_contains(
  "${rage_sound_reader_preload_cpp}"
  "SRC_AUDIT_FIX SRC-2790"
  "RageSoundReader_Preload diagnoses preload open and allocation failures")
require_contains(
  "${rage_sound_reader_preload_cpp}"
  "SRC_AUDIT_FIX SRC-2791"
  "RageSoundReader_Preload diagnoses seek/read range failures")
require_contains(
  "${rage_sound_reader_preload_cpp}"
  "catch (const std::bad_alloc&)"
  "RageSoundReader_Preload converts allocation failures into preload errors")
require_not_contains(
  "${rage_sound_reader_preload_cpp}"
  "#define framesize"
  "RageSoundReader_Preload must not hide frame byte arithmetic in a macro")
require_contains(
  "${rage_sound_reader_wav_h}"
  "RageSoundReader_WAV(const RageSoundReader_WAV&) = delete;"
  "RageSoundReader_WAV forbids unsafe implicit copying")
require_contains(
  "${rage_sound_reader_wav_h}"
  "RageSoundReader_WAV* Copy() const override;"
  "RageSoundReader_WAV copy contract is explicit")
require_contains(
  "${rage_sound_reader_wav_cpp}"
  "SRC_AUDIT_FIX SRC-2797"
  "RageSoundReader_WAV converts allocation failures into decoder errors")
require_contains(
  "${rage_sound_reader_wav_cpp}"
  "void RageSoundReader_WAV::Close()"
  "RageSoundReader_WAV has a real close/reset implementation")
require_contains(
  "${rage_sound_reader_wav_cpp}"
  "iBufferRemainingSamples / m_WavData.m_iChannels"
  "ADPCM source-frame mapping treats buffer counters as samples")
require_contains(
  "${rage_sound_reader_vorbis_h}"
  "RageSoundReader_Vorbisfile(const RageSoundReader_Vorbisfile&) = delete;"
  "RageSoundReader_Vorbisfile forbids unsafe implicit copying")
require_contains(
  "${rage_sound_reader_vorbis_h}"
  "RageSoundReader_Vorbisfile* Copy() const override;"
  "RageSoundReader_Vorbisfile copy contract is explicit")
require_contains(
  "${rage_sound_reader_vorbis_cpp}"
  "void RageSoundReader_Vorbisfile::Close()"
  "RageSoundReader_Vorbisfile has a real close/reset implementation")
require_contains(
  "${rage_sound_reader_vorbis_cpp}"
  "SRC_AUDIT_FIX SRC-2802"
  "RageSoundReader_Vorbisfile converts allocation failures into decoder errors")
require_contains(
  "${rage_sound_reader_vorbis_cpp}"
  "const ogg_int64_t curofs = ov_pcm_tell(vf);"
  "RageSoundReader_Vorbisfile keeps Vorbis read positions in 64-bit form")
require_contains(
  "${rage_sound_reader_vorbis_cpp}"
  "std::isfinite(lenSeconds)"
  "RageSoundReader_Vorbisfile bounds non-integer Vorbis length conversion")
require_contains(
  "${rage_sound_reader_vorbis_cpp}"
  "static_cast<int>(elementsToRead)"
  "RageSoundReader_Vorbisfile bounds libvorbis read callback counts")
require_contains(
  "${rage_sound_reader_vorbis_cpp}"
  "GetSourcePath().c_str()"
  "RageSoundReader_Vorbisfile reports source paths in decoder diagnostics")
require_contains(
  "${rage_sound_reader_mp3_h}"
  "RageSoundReader_MP3(const RageSoundReader_MP3&) = delete;"
  "RageSoundReader_MP3 forbids unsafe implicit copying")
require_contains(
  "${rage_sound_reader_mp3_h}"
  "RageSoundReader_MP3* Copy() const override;"
  "RageSoundReader_MP3 copy contract is explicit")
require_contains(
  "${rage_sound_reader_mp3_cpp}"
  "void RageSoundReader_MP3::Close()"
  "RageSoundReader_MP3 has a real close/reset implementation")
require_contains(
  "${rage_sound_reader_mp3_cpp}"
  "RageSoundReader_FileReader::OpenResult RageSoundReader_MP3::FailOpen"
  "RageSoundReader_MP3 cleans up partially-open decoders on failure")
require_contains(
  "${rage_sound_reader_mp3_cpp}"
  "ret->Open(pFile) != OPEN_OK"
  "RageSoundReader_MP3 Copy reparses copied files instead of cloning stale partial metadata")
require_contains(
  "${rage_sound_reader_mp3_cpp}"
  "if (m_pFile->Seek(0) == -1)"
  "RageSoundReader_MP3 verifies file rewind before resetting decoder state")
require_contains(
  "${rage_sound_reader_mp3_cpp}"
  "SRC_AUDIT_FIX SRC-2810"
  "RageSoundReader_MP3 diagnoses invalid MAD stream buffer pointers")
require_contains(
  "${rage_sound_reader_mp3_cpp}"
  "bytes_read = std::max(0, bytes_read - tagsize);"
  "RageSoundReader_MP3 keeps ID3 skip accounting non-negative")
require_contains(
  "${rage_sound_reader_mp3_cpp}"
  "std::int64_t inbuf_filepos;"
  "RageSoundReader_MP3 keeps file buffer positions in 64-bit form")
require_contains(
  "${rage_sound_reader_mp3_cpp}"
  "clamp_milliseconds_to_int"
  "RageSoundReader_MP3 clamps internal MP3 duration arithmetic before public int returns")
require_contains(
  "${rage_sound_reader_mp3_cpp}"
  "SRC_AUDIT_FIX SRC-2812"
  "RageSoundReader_MP3 diagnoses seek estimate overflow")
require_contains(
  "${rage_sound_reader_mp3_cpp}"
  "SRC_AUDIT_FIX SRC-2815"
  "RageSoundReader_MP3 bounds fixed synth output buffer writes")
require_contains(
  "${rage_sound_reader_mp3_cpp}"
  "SRC_AUDIT_FIX SRC-2816"
  "RageSoundReader_MP3 avoids stale errno diagnostics for seek failures")
require_contains(
  "${rage_sound_reader_pan_h}"
  "RageSoundReader_Pan* Copy() const override"
  "RageSoundReader_Pan copy contract is explicitly overriding")
require_contains(
  "${rage_sound_reader_pan_h}"
  "std::string GetError() const override;"
  "RageSoundReader_Pan exposes filter-owned diagnostics")
require_contains(
  "${rage_sound_reader_pan_cpp}"
  "SRC_AUDIT_FIX SRC-2754"
  "RageSoundReader_Pan records internal filter failures locally")
require_contains(
  "${rage_sound_reader_pan_cpp}"
  "RageSoundReader_Pan::Read called with a null output buffer"
  "RageSoundReader_Pan diagnoses invalid output buffers")
require_contains(
  "${rage_sound_reader_channel_split_h}"
  "std::shared_ptr<RageSoundSplitterImpl> m_pImpl;"
  "ChannelSplit shares implementation lifetime with shared_ptr")
require_contains(
  "${rage_sound_reader_channel_split_h}"
  "RageSoundReader_Split(const RageSoundReader_Split&) = delete;"
  "ChannelSplit split readers forbid unsafe copying")
require_contains(
  "${rage_sound_reader_channel_split_h}"
  "RageSoundSplitter(const RageSoundSplitter&) = delete;"
  "ChannelSplit splitters forbid unsafe copying")
require_contains(
  "${rage_sound_reader_channel_split_cpp}"
  "std::unique_ptr<RageSoundReader> m_pSource;"
  "ChannelSplit owns its source reader with unique_ptr")
require_contains(
  "${rage_sound_reader_channel_split_cpp}"
  "mutable std::mutex m_Mutex;"
  "ChannelSplit serializes shared source and buffer state")
require_contains(
  "${rage_sound_reader_channel_split_cpp}"
  "WarnAuditFix(\"SRC-2755\""
  "ChannelSplit diagnoses null source and impl paths")
require_contains(
  "${rage_sound_reader_channel_split_cpp}"
  "WarnAuditFix(\"SRC-2756\""
  "ChannelSplit diagnoses invalid read buffers")
require_contains(
  "${rage_sound_reader_channel_split_cpp}"
  "WarnAuditFix(\"SRC-2757\""
  "ChannelSplit validates channel maps")
require_contains(
  "${rage_sound_reader_channel_split_cpp}"
  "WarnAuditFix(\"SRC-2758\""
  "ChannelSplit guards frame and sample arithmetic")
require_contains(
  "${rage_sound_reader_channel_split_cpp}"
  "RageSoundReader_Split cannot be copied safely"
  "ChannelSplit refuses unsafe Copy")
require_not_contains(
  "${rage_sound_reader_channel_split_cpp}"
  "m_iRefCount"
  "ChannelSplit must not return to manual refcounting")
require_not_contains(
  "${rage_sound_reader_channel_split_cpp}"
  "&m_sBuffer[0]"
  "ChannelSplit must not take vector element zero before proving non-empty")
require_contains(
  "${rage_sound_mix_buffer_h}"
  "bool SetWriteOffset(int iOffset);"
  "RageSoundMixBuffer reports invalid write offsets")
require_contains(
  "${rage_sound_mix_buffer_h}"
  "bool Extend(size_t iSamples);"
  "RageSoundMixBuffer reports resize failures")
require_contains(
  "${rage_sound_mix_buffer_h}"
  "bool write("
  "RageSoundMixBuffer write reports failures")
require_contains(
  "${rage_sound_mix_buffer_h}"
  "bool read_deinterlace(float** pBufs, int channels);"
  "RageSoundMixBuffer deinterlace reports failures")
require_contains(
  "${rage_sound_mix_buffer_h}"
  "size_t m_iOffset;"
  "RageSoundMixBuffer stores offsets in size_t")
require_contains(
  "${rage_sound_mix_buffer_cpp}"
  "SRC_AUDIT_FIX SRC-2761"
  "RageSoundMixBuffer rejects negative write offsets")
require_contains(
  "${rage_sound_mix_buffer_cpp}"
  "SRC_AUDIT_FIX SRC-2762"
  "RageSoundMixBuffer rejects invalid strides and span overflow")
require_contains(
  "${rage_sound_mix_buffer_cpp}"
  "SRC_AUDIT_FIX SRC-2763"
  "RageSoundMixBuffer guards resize arithmetic and allocation")
require_contains(
  "${rage_sound_mix_buffer_cpp}"
  "SRC_AUDIT_FIX SRC-2764"
  "RageSoundMixBuffer rejects null interleaved buffers")
require_contains(
  "${rage_sound_mix_buffer_cpp}"
  "SRC_AUDIT_FIX SRC-2765"
  "RageSoundMixBuffer validates deinterlace arguments")
require_contains(
  "${rage_sound_reader_chain_cpp}"
  "RageSoundReader_Chain: mix buffer write failed"
  "RageSoundReader_Chain handles mix write failures")
require_contains(
  "${rage_sound_reader_merge_cpp}"
  "RageSoundReader_Merge: mix buffer write failed"
  "RageSoundReader_Merge handles mix write failures")
require_contains(
  "${rage_sound_driver_generic_cpp}"
  "RageSoundDriver::MixIntoBuffer: mix buffer write failed"
  "Software sound driver handles mix write failures")

require_contains(
  "${rage_sound_manager_h}"
  "float GetVolumeOfNonCriticalSounds() const;"
  "RageSoundManager non-critical volume getter is out-of-line")
require_contains(
  "${rage_sound_manager_cpp}"
  "float RageSoundManager::GetVolumeOfNonCriticalSounds() const"
  "RageSoundManager defines synchronized non-critical volume getter")
require_contains(
  "${rage_sound_manager_cpp}"
  "LockMut(g_SoundManMutex);"
  "RageSoundManager volume getter uses sound manager mutex")
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
