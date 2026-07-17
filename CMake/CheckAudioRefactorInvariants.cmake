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
read_source("src/RageSoundPosMap.h" rage_sound_pos_map_h)
read_source("src/RageSoundPosMap.cpp" rage_sound_pos_map_cpp)
read_source("src/arch/Sound/RageSoundDriver.h" rage_sound_driver_h)
read_source("src/arch/Sound/RageSoundDriver_Generic_Software.cpp" rage_sound_driver_generic_cpp)
read_source("src/GameSoundManager.h" game_sound_manager_h)
read_source("src/GameSoundManager.cpp" game_sound_manager_cpp)
read_source("src/AutoKeysounds.cpp" auto_keysounds_cpp)
read_source("src/PrefsManager.cpp" prefs_manager_cpp)
read_source("src/arch/Sound/RageSoundDriver_AU.mm" audio_unit_cpp)
read_source("src/RageSoundManager.h" rage_sound_manager_h)
read_source("src/RageSoundManager.cpp" rage_sound_manager_cpp)
read_source("src/RageSoundReader.h" rage_sound_reader_h)
read_source("src/RageSoundReader.cpp" rage_sound_reader_cpp)
read_source("src/RageSoundReader_Extend.h" rage_sound_reader_extend_h)
read_source("src/RageSoundReader_Extend.cpp" rage_sound_reader_extend_cpp)
read_source("src/RageSoundReader_Filter.h" rage_sound_reader_filter_h)
read_source(
  "src/RageSoundReader_PostBuffering.h" rage_sound_reader_post_buffering_h)
read_source(
  "src/RageSoundReader_PostBuffering.cpp" rage_sound_reader_post_buffering_cpp)
read_source("src/RageSoundReader_FileReader.h" rage_sound_reader_file_reader_h)
read_source("src/RageSoundReader_FileReader.cpp" rage_sound_reader_file_reader_cpp)
read_source("src/RageSoundReader_Preload.h" rage_sound_reader_preload_h)
read_source("src/RageSoundReader_Preload.cpp" rage_sound_reader_preload_cpp)
read_source("src/RageSoundReader_Pan.h" rage_sound_reader_pan_h)
read_source("src/RageSoundReader_Pan.cpp" rage_sound_reader_pan_cpp)
read_source(
  "src/RageSoundReader_PitchChange.h" rage_sound_reader_pitch_change_h)
read_source(
  "src/RageSoundReader_PitchChange.cpp" rage_sound_reader_pitch_change_cpp)
read_source(
  "src/RageSoundReader_SpeedChange.h" rage_sound_reader_speed_change_h)
read_source(
  "src/RageSoundReader_SpeedChange.cpp" rage_sound_reader_speed_change_cpp)
read_source(
  "src/RageSoundReader_ThreadedBuffer.h" rage_sound_reader_threaded_buffer_h)
read_source(
  "src/RageSoundReader_ThreadedBuffer.cpp" rage_sound_reader_threaded_buffer_cpp)
read_source(
  "src/RageSoundReader_Resample_Good.h" rage_sound_reader_resample_good_h)
read_source(
  "src/RageSoundReader_Resample_Good.cpp" rage_sound_reader_resample_good_cpp)
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
read_source("src/RageSoundUtil.h" rage_sound_util_h)
read_source("src/RageSoundUtil.cpp" rage_sound_util_cpp)
read_source("src/RageSoundReader_Chain.h" rage_sound_reader_chain_h)
read_source("src/RageSoundReader_Chain.cpp" rage_sound_reader_chain_cpp)
read_source("src/RageSoundReader_Merge.h" rage_sound_reader_merge_h)
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
  "${prefs_manager_cpp}"
  "m_iSoundWriteAhead(\"SoundWriteAhead\", 0)"
  "Sound write-ahead defaults to backend-controlled low-latency sizing")
require_contains(
  "${stepmania_cpp}"
  "kLegacyForcedSoundWriteAheadFrames"
  "legacy high-latency write-ahead values are migrated")
require_not_contains(
  "${stepmania_cpp}"
  "kForcedSoundWriteAheadFrames"
  "startup must not force a high-latency sound write-ahead")
require_contains(
  "${audio_unit_cpp}"
  "constexpr int decodeBufferFrames = 4096;"
  "AudioUnit uses the decoder scheduler's effective lead size")
require_contains(
  "${audio_unit_cpp}"
  "AudioObjectHasProperty(OutputDevice, &LatencyAddr)"
  "AudioUnit checks optional latency properties before reading them")
require_not_contains(
  "${audio_unit_cpp}"
  "Couldn't get device latency"
  "unsupported optional AudioUnit latency properties must not emit warnings")
require_contains(
  "${rage_sound_cpp}"
  "LogPlayOnceDiagnosticsEnabled() || LogContentLoadDiagnosticsEnabled()"
  "per-sound load traces follow the targeted diagnostic switches")
require_not_contains(
  "${audio_unit_cpp}"
  "std::max(decodeBufferFrames, PREFSMAN->m_iSoundWriteAhead.Get())"
  "AudioUnit must not inflate every short-sound slot from SoundWriteAhead")
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
  "${rage_sound_pos_map_h}"
  "std::unique_ptr<pos_map_impl> m_pImpl;"
  "RageSoundPosMap owns its implementation with RAII")
require_contains(
  "${rage_sound_pos_map_h}"
  "bool Insert("
  "RageSoundPosMap insertion reports rejected mappings")
require_contains(
  "${rage_sound_pos_map_h}"
  "pos_map_search_result SearchResult("
  "RageSoundPosMap exposes exact/approximate lookup status")
require_contains(
  "${rage_sound_pos_map_h}"
  "std::string GetError() const;"
  "RageSoundPosMap exposes local diagnostics")
require_contains(
  "${rage_sound_pos_map_cpp}"
  "mutable std::mutex m_Mutex;"
  "RageSoundPosMap protects instance-owned drift state")
require_contains(
  "${rage_sound_pos_map_cpp}"
  "SRC_AUDIT_FIX SRC-2916"
  "RageSoundPosMap invalid inserts are review-traced")
require_contains(
  "${rage_sound_pos_map_cpp}"
  "SRC_AUDIT_FIX SRC-2917"
  "RageSoundPosMap allocation failures are review-traced")
require_contains(
  "${rage_sound_pos_map_cpp}"
  "SRC_AUDIT_FIX SRC-2921"
  "RageSoundPosMap corrupt search entries are review-traced")
require_contains(
  "${rage_sound_pos_map_cpp}"
  "kMaxPosMapEntries"
  "RageSoundPosMap bounds fragmented history by entry count")
require_contains(
  "${rage_sound_pos_map_cpp}"
  "RatiosEquivalent"
  "RageSoundPosMap merges near-identical playback ratios")
require_not_contains(
  "${rage_sound_pos_map_cpp}"
  "static RageTimer lastMinor"
  "RageSoundPosMap drift timers must be instance-owned")
require_contains(
  "${rage_sound_h}"
  "int64_t GetSourceFrameFromHardwareFrame"
  "RageSound preserves 64-bit source-frame position map results")
require_contains(
  "${rage_sound_cpp}"
  "m_HardwareToStreamMap.SearchResult"
  "RageSound consumes structured hardware-to-stream lookup status")
require_contains(
  "${rage_sound_cpp}"
  "m_StreamToSourceMap.SearchResult"
  "RageSound consumes structured stream-to-source lookup status")
require_contains(
  "${rage_sound_driver_h}"
  "int64_t iHardwareFrame;"
  "Generic sound position map queue names hardware frame explicitly")
require_contains(
  "${rage_sound_driver_generic_cpp}"
  "pos.iHardwareFrame = iFrameNumber + iGotFrames;"
  "Generic sound driver records hardware frame in the hardware field")
require_contains(
  "${rage_sound_driver_generic_cpp}"
  "pSound->CommitPlayingPosition("
  "Generic sound driver drains queued position maps into RageSound")

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
  "${rage_sound_cpp}"
  "int64_t iSourceFrame = 0;"
  "RageSound consumes 64-bit source-frame metadata from RetriedRead")
require_contains(
  "${rage_sound_cpp}"
  "source->GetBaseError()"
  "RageSound preserves base-reader retry diagnostics when derived errors are empty")
require_contains(
  "${rage_sound_cpp}"
  "TrySetProperty("
  "RageSound uses the property wrapper that reports failure status")

require_contains(
  "${rage_sound_reader_h}"
  "enum class PropertySetStatus"
  "RageSoundReader property failures expose an explicit status")
require_contains(
  "${rage_sound_reader_h}"
  "PropertySetResult TrySetProperty"
  "RageSoundReader exposes a non-breaking property result wrapper")
require_contains(
  "${rage_sound_reader_h}"
  "std::int64_t GetNextSourceFrame64() const"
  "RageSoundReader exposes additive 64-bit source-frame metadata")
require_contains(
  "${rage_sound_reader_h}"
  "static int ClampSourceFrameToInt"
  "RageSoundReader centralizes public int source-frame clamping")
require_contains(
  "${rage_sound_reader_h}"
  "std::string GetBaseError() const"
  "RageSoundReader exposes shared base diagnostics")
require_contains(
  "${rage_sound_reader_cpp}"
  "RageSoundReader::CopyReader"
  "RageSoundReader copy traits go through the guarded base helper")
require_contains(
  "${rage_sound_reader_cpp}"
  "SRC_AUDIT_FIX SRC-2905"
  "RageSoundReader copy failures are review-traced")
require_contains(
  "${rage_sound_reader_cpp}"
  "SRC_AUDIT_FIX SRC-2901"
  "RageSoundReader invalid RetriedRead calls are diagnosable")
require_contains(
  "${rage_sound_reader_cpp}"
  "SRC_AUDIT_FIX SRC-2899 SRC-2900"
  "RageSoundReader retry exhaustion is diagnosable")
require_contains(
  "${rage_sound_reader_cpp}"
  "SRC_AUDIT_FIX SRC-2902"
  "RageSoundReader source-frame clamping is diagnosable")
require_contains(
  "${rage_sound_reader_cpp}"
  "return RageSoundReader::WOULD_BLOCK;"
  "RageSoundReader retry exhaustion reports temporary backpressure")
require_contains(
  "${rage_sound_reader_h}"
  "m_bRetriedReadStallReported"
  "RageSoundReader throttles repeated retry-stall diagnostics")
require_not_contains(
  "${rage_sound_reader_cpp}"
  "Pretend we got EOF"
  "RageSoundReader must not mask retry exhaustion as EOF")

require_contains(
  "${rage_sound_reader_threaded_buffer_cpp}"
  "while (m_StreamPosition.size() > 1 &&"
  "ThreadedBuffer collapses consumed mapping runs in one retry transition")
require_contains(
  "${rage_sound_reader_threaded_buffer_cpp}"
  "SRC_AUDIT_FIX SRC-2933"
  "ThreadedBuffer mapping compaction is review-traced")
require_not_contains(
  "${rage_sound_reader_resample_good_cpp}"
  "if (iFramesNeeded == 0) {\n    return 0;"
  "Resample_Good must drain internally buffered output without source input")
require_contains(
  "${rage_sound_reader_resample_good_cpp}"
  "SRC_AUDIT_FIX SRC-2934"
  "Resample_Good internal-buffer draining is review-traced")

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
  "${rage_sound_reader_extend_h}"
  "RageSoundReader_Extend* Copy() const override;"
  "RageSoundReader_Extend copy contract is explicit and out-of-line")
require_contains(
  "${rage_sound_reader_extend_h}"
  "std::int64_t m_iPositionFrames"
  "RageSoundReader_Extend stores playback frame position in 64-bit")
require_contains(
  "${rage_sound_reader_extend_h}"
  "std::int64_t GetNextSourceFrame64() const override;"
  "RageSoundReader_Extend exposes its 64-bit source frame without clamping")
require_contains(
  "${rage_sound_reader_extend_h}"
  "std::string GetError() const override;"
  "RageSoundReader_Extend exposes local diagnostics")
require_contains(
  "${rage_sound_reader_extend_cpp}"
  "SRC_AUDIT_FIX SRC-2890"
  "RageSoundReader_Extend copy failures are diagnosable")
require_contains(
  "${rage_sound_reader_extend_cpp}"
  "SRC_AUDIT_FIX SRC-2891"
  "RageSoundReader_Extend seek failures are diagnosable")
require_contains(
  "${rage_sound_reader_extend_cpp}"
  "SRC_AUDIT_FIX SRC-2892"
  "RageSoundReader_Extend loop restart failures are diagnosable")
require_contains(
  "${rage_sound_reader_extend_cpp}"
  "SRC_AUDIT_FIX SRC-2893"
  "RageSoundReader_Extend frame arithmetic is guarded")
require_contains(
  "${rage_sound_reader_extend_cpp}"
  "SRC_AUDIT_FIX SRC-2894"
  "RageSoundReader_Extend internal failures are diagnosable")
require_contains(
  "${rage_sound_reader_extend_cpp}"
  "SRC_AUDIT_FIX SRC-2896"
  "RageSoundReader_Extend length reporting failures are diagnosable")
require_contains(
  "${rage_sound_reader_extend_cpp}"
  "SRC_AUDIT_FIX SRC-2897"
  "RageSoundReader_Extend source-frame tracking is guarded")
require_contains(
  "${rage_sound_reader_extend_cpp}"
  "AdvanceFrameByRatio"
  "RageSoundReader_Extend accounts for stream-to-source ratios")
require_not_contains(
  "${rage_sound_reader_extend_cpp}"
  "pSource->GetNextSourceFrame();"
  "RageSoundReader_Extend must not truncate upstream 64-bit positions")
require_not_contains(
  "${rage_sound_reader_extend_cpp}"
  "SaturatingAddFrames"
  "RageSoundReader_Extend must not silently saturate frame arithmetic")
require_contains(
  "${rage_sound_reader_filter_h}"
  "int Read(float* pBuf, int iFrames) override"
  "RageSoundReader_Filter base forwarding contract is explicit")
require_contains(
  "${rage_sound_reader_filter_h}"
  "std::int64_t GetNextSourceFrame64() const override"
  "RageSoundReader_Filter forwards 64-bit source-frame metadata")
require_contains(
  "${rage_sound_reader_filter_h}"
  "std::string GetError() const override"
  "RageSoundReader_Filter error forwarding contract is explicit")
require_contains(
  "${rage_sound_reader_post_buffering_h}"
  "RageSoundReader_PostBuffering* Copy() const override;"
  "PostBuffering copy contract is explicit and out-of-line")
require_contains(
  "${rage_sound_reader_post_buffering_h}"
  "std::atomic<float> m_fVolume{1.0f};"
  "PostBuffering instance volume is atomic for audio-thread reads")
require_contains(
  "${rage_sound_reader_post_buffering_cpp}"
  "std::atomic<float> g_fMasterVolume{1.0f};"
  "PostBuffering master volume is atomic for audio-thread reads")
require_contains(
  "${rage_sound_reader_post_buffering_cpp}"
  "RageSoundReader_PostBuffering::Copy() const"
  "PostBuffering copy is implemented out-of-line")
require_contains(
  "${rage_sound_reader_post_buffering_cpp}"
  "catch (const std::bad_alloc&)"
  "PostBuffering converts copy allocation failures into nullptr")
require_contains(
  "${rage_sound_reader_post_buffering_cpp}"
  "SRC_AUDIT_FIX SRC-2821"
  "PostBuffering diagnoses sample-count overflow before int attenuation")
require_contains(
  "${rage_sound_reader_post_buffering_cpp}"
  "RageSoundReader_PostBuffering::GetError() const"
  "PostBuffering exposes filter-owned diagnostics")
require_not_contains(
  "${rage_sound_reader_post_buffering_cpp}"
  "RageMutex g_Mutex(\"PostBuffering\")"
  "PostBuffering must not serialize all audio reads on one global mutex")
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
  "${rage_sound_reader_preload_h}"
  "std::int64_t GetNextSourceFrame64() const override;"
  "RageSoundReader_Preload exposes 64-bit source-frame metadata")
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
  "${rage_sound_reader_vorbis_cpp}"
  "SRC_AUDIT_FIX SRC-3320"
  "RageSoundReader_Vorbisfile refuses copies that cannot rewind")
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
  "${rage_sound_reader_pitch_change_h}"
  "RageSoundReader_PitchChange* Copy() const override;"
  "PitchChange copy contract is explicit and out-of-line")
require_contains(
  "${rage_sound_reader_pitch_change_h}"
  "std::string GetError() const override;"
  "PitchChange exposes filter-owned diagnostics")
require_contains(
  "${rage_sound_reader_pitch_change_h}"
  "mutable std::mutex m_StateMutex;"
  "PitchChange serializes ratio updates across gameplay and audio threads")
require_contains(
  "${rage_sound_reader_pitch_change_cpp}"
  "std::unique_ptr<RageSoundReader> pOwnedSource(pSource);"
  "PitchChange uses temporary ownership while building its filter chain")
require_contains(
  "${rage_sound_reader_pitch_change_cpp}"
  "catch (const std::bad_alloc&)"
  "PitchChange converts allocation failure into reader errors or nullptr")
require_contains(
  "${rage_sound_reader_pitch_change_cpp}"
  "m_bPreservePitch(g_bRateModPreservesPitch.Get())"
  "PitchChange snapshots RateModPreservesPitch at construction")
require_contains(
  "${rage_sound_reader_pitch_change_cpp}"
  "SRC_AUDIT_FIX SRC-2827"
  "PitchChange records internal read failures locally")
require_contains(
  "${rage_sound_reader_pitch_change_cpp}"
  "SRC_AUDIT_FIX SRC-2830"
  "PitchChange rejects unsafe speed and pitch ratios before resampling")
require_contains(
  "${rage_sound_reader_pitch_change_cpp}"
  "SRC_AUDIT_FIX SRC-3321"
  "PitchChange propagates transactional resampler rate failures")
require_contains(
  "${rage_sound_cpp}"
  "const std::string setupError ="
  "RageSound::Load surfaces filter-chain setup errors immediately")
require_contains(
  "${rage_sound_reader_speed_change_h}"
  "RageSoundReader_SpeedChange* Copy() const override;"
  "SpeedChange copy contract is explicit and out-of-line")
require_contains(
  "${rage_sound_reader_speed_change_h}"
  "std::string GetError() const override;"
  "SpeedChange exposes filter-owned diagnostics")
require_contains(
  "${rage_sound_reader_speed_change_h}"
  "std::int64_t GetNextSourceFrame64() const override;"
  "SpeedChange exposes 64-bit source-frame metadata")
require_contains(
  "${rage_sound_reader_speed_change_h}"
  "mutable std::mutex m_StateMutex;"
  "SpeedChange serializes ratio and buffer state")
require_contains(
  "${rage_sound_reader_speed_change_h}"
  "const RageSoundReader_SpeedChange& rhs) = delete;"
  "SpeedChange forbids unsafe implicit assignment")
require_contains(
  "${rage_sound_reader_speed_change_cpp}"
  "MAX_SPEED_CHANGE_CHANNELS"
  "SpeedChange enforces an explicit channel ceiling")
require_contains(
  "${rage_sound_reader_speed_change_cpp}"
  "MAX_REASONABLE_SPEED_RATIO"
  "SpeedChange rejects unbounded speed ratios")
require_contains(
  "${rage_sound_reader_speed_change_cpp}"
  "catch (const std::bad_alloc&)"
  "SpeedChange converts allocation failures into reader errors or nullptr")
require_contains(
  "${rage_sound_reader_speed_change_cpp}"
  "SRC_AUDIT_FIX SRC-2848"
  "SpeedChange records internal read/setup failures locally")
require_contains(
  "${rage_sound_reader_speed_change_cpp}"
  "ClampInt64ToInt"
  "SpeedChange clamps 64-bit position arithmetic before public int returns")
require_contains(
  "${rage_sound_reader_speed_change_cpp}"
  "RageSoundReader_Filter::GetNextSourceFrame64()"
  "SpeedChange preserves 64-bit source-frame metadata")
require_not_contains(
  "${rage_sound_reader_speed_change_h}"
  "return new RageSoundReader_SpeedChange(*this);"
  "SpeedChange must not return to inline throwing Copy")
require_contains(
  "${rage_sound_reader_threaded_buffer_h}"
  "RageSoundReader_ThreadedBuffer* Copy() const override;"
  "ThreadedBuffer copy contract is explicit and out-of-line")
require_contains(
  "${rage_sound_reader_threaded_buffer_h}"
  "std::string GetError() const override;"
  "ThreadedBuffer exposes filter-owned diagnostics")
require_contains(
  "${rage_sound_reader_threaded_buffer_h}"
  "std::int64_t GetNextSourceFrame64() const override;"
  "ThreadedBuffer exposes 64-bit source-frame metadata")
require_contains(
  "${rage_sound_reader_threaded_buffer_h}"
  "std::int64_t iPositionOfFirstFrame;"
  "ThreadedBuffer mapping positions use 64-bit arithmetic")
require_contains(
  "${rage_sound_reader_threaded_buffer_cpp}"
  "std::int64_t iNextSourceFrame = 0;"
  "ThreadedBuffer reads 64-bit source-frame metadata")
require_not_contains(
  "${rage_sound_reader_threaded_buffer_cpp}"
  "pSource->GetNextSourceFrame();"
  "ThreadedBuffer must not truncate its initial source frame")
require_contains(
  "${rage_sound_reader_threaded_buffer_cpp}"
  "SRC_AUDIT_FIX SRC-3323"
  "ThreadedBuffer guards 64-bit source-frame accumulation")
require_contains(
  "${rage_sound_reader_threaded_buffer_cpp}"
  "MAX_THREADED_BUFFER_CHANNELS"
  "ThreadedBuffer enforces an explicit channel ceiling")
require_contains(
  "${rage_sound_reader_threaded_buffer_cpp}"
  "m_DataBuffer.reserve(static_cast<unsigned>(iSampleCapacity), m_iChannels);"
  "ThreadedBuffer reserves float samples, not byte counts")
require_contains(
  "${rage_sound_reader_threaded_buffer_cpp}"
  "DisableBufferingForSourceAccess"
  "ThreadedBuffer waits for source ownership before direct source access")
require_contains(
  "${rage_sound_reader_threaded_buffer_cpp}"
  "RestoreThreadedBufferState"
  "ThreadedBuffer restores original buffering state during copy failures")
require_contains(
  "${rage_sound_reader_threaded_buffer_cpp}"
  "SRC_AUDIT_FIX SRC-2858"
  "ThreadedBuffer records internal failures locally")
require_not_contains(
  "${rage_sound_reader_threaded_buffer_h}"
  "return new RageSoundReader_ThreadedBuffer(*this);"
  "ThreadedBuffer must not return to inline throwing Copy")
require_not_contains(
  "${rage_sound_reader_threaded_buffer_cpp}"
  "void RageSoundReader_ThreadedBuffer::WaitUntilFrames"
  "ThreadedBuffer must not keep unused wait helpers")
require_contains(
  "${rage_sound_reader_resample_good_h}"
  "bool SetRate(float fRatio);"
  "Resample_Good reports whether rate changes were applied")
require_contains(
  "${rage_sound_reader_resample_good_h}"
  "std::string GetError() const override;"
  "Resample_Good exposes filter-owned diagnostics")
require_contains(
  "${rage_sound_reader_resample_good_h}"
  "std::int64_t GetNextSourceFrame64() const override;"
  "Resample_Good exposes 64-bit source-frame metadata")
require_contains(
  "${rage_sound_reader_resample_good_h}"
  "mutable std::mutex m_StateMutex;"
  "Resample_Good serializes topology/rate changes with audio reads")
require_contains(
  "${rage_sound_reader_resample_good_h}"
  "const RageSoundReader_Resample_Good& rhs) = delete;"
  "Resample_Good forbids unsafe pointer-owning assignment")
require_contains(
  "${rage_sound_reader_resample_good_cpp}"
  "LockMutex lock(PolyphaseFiltersLock);"
  "Resample_Good cache locking is RAII based")
require_contains(
  "${rage_sound_reader_resample_good_cpp}"
  "std::unique_ptr<PolyphaseFilter>"
  "Resample_Good cache builds filters with temporary ownership")
require_contains(
  "${rage_sound_reader_resample_good_cpp}"
  "std::vector<std::unique_ptr<RageSoundResampler_Polyphase>> apNewResamplers"
  "Resample_Good rebuilds channel topology in temporary owners before swap")
require_contains(
  "${rage_sound_reader_resample_good_cpp}"
  "SRC_AUDIT_FIX SRC-2835"
  "Resample_Good diagnoses failed rate changes")
require_contains(
  "${rage_sound_reader_resample_good_cpp}"
  "SRC_AUDIT_FIX SRC-2837"
  "Resample_Good records internal read/setup failures locally")
require_contains(
  "${rage_sound_reader_resample_good_cpp}"
  "MAX_RESAMPLE_CHANNELS"
  "Resample_Good enforces an explicit channel ceiling")
require_contains(
  "${rage_sound_reader_resample_good_cpp}"
  "m_pSource->GetNextSourceFrame64()"
  "Resample_Good preserves 64-bit source-frame metadata")
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
  "${rage_sound_reader_chain_h}"
  "std::vector<std::unique_ptr<RageSoundReader>> m_apLoadedSounds;"
  "RageSoundReader_Chain owns loaded sounds with unique_ptr")
require_contains(
  "${rage_sound_reader_chain_h}"
  "std::int64_t m_iCurrentFrame;"
  "RageSoundReader_Chain stores internal frame position in 64-bit")
require_contains(
  "${rage_sound_reader_chain_h}"
  "std::int64_t GetNextSourceFrame64() const override;"
  "RageSoundReader_Chain exposes 64-bit source-frame metadata")
require_contains(
  "${rage_sound_reader_chain_h}"
  "std::string GetError() const override;"
  "RageSoundReader_Chain exposes local diagnostics")
require_contains(
  "${rage_sound_reader_chain_cpp}"
  "SRC_AUDIT_FIX SRC-2865"
  "RageSoundReader_Chain copy failures are diagnosable")
require_contains(
  "${rage_sound_reader_chain_cpp}"
  "SRC_AUDIT_FIX SRC-2866"
  "RageSoundReader_Chain load ownership failures are diagnosable")
require_contains(
  "${rage_sound_reader_chain_cpp}"
  "SRC_AUDIT_FIX SRC-2870"
  "RageSoundReader_Chain rejects invalid source topology")
require_contains(
  "${rage_sound_reader_chain_cpp}"
  "SRC_AUDIT_FIX SRC-2873"
  "RageSoundReader_Chain guards frame arithmetic")
require_contains(
  "${rage_sound_reader_chain_cpp}"
  "ReplaceNamedSoundPointer"
  "RageSoundReader_Chain keeps named cache aligned with wrapped readers")
require_contains(
  "${rage_sound_reader_chain_cpp}"
  "m_aPendingProperties"
  "RageSoundReader_Chain applies properties to future active sounds")
require_not_contains(
  "${rage_sound_reader_chain_cpp}"
  "MakeLower(sPath)"
  "RageSoundReader_Chain must not lowercase real file paths before opening")
require_contains(
  "${rage_sound_reader_merge_h}"
  "std::vector<std::unique_ptr<RageSoundReader>> m_aSounds;"
  "RageSoundReader_Merge owns sources with unique_ptr")
require_contains(
  "${rage_sound_reader_merge_h}"
  "RageSoundReader_Merge& operator=(const RageSoundReader_Merge& cpy) = delete;"
  "RageSoundReader_Merge forbids implicit shallow assignment")
require_contains(
  "${rage_sound_reader_merge_h}"
  "RageSoundReader_Merge* Copy() const override;"
  "RageSoundReader_Merge copy is implemented out-of-line")
require_contains(
  "${rage_sound_reader_merge_h}"
  "std::int64_t m_iNextSourceFrame"
  "RageSoundReader_Merge stores internal source frame in 64-bit")
require_contains(
  "${rage_sound_reader_merge_h}"
  "std::int64_t GetNextSourceFrame64() const override;"
  "RageSoundReader_Merge exposes 64-bit source-frame metadata")
require_contains(
  "${rage_sound_reader_merge_h}"
  "std::string GetError() const override;"
  "RageSoundReader_Merge exposes local diagnostics")
require_contains(
  "${rage_sound_reader_merge_cpp}"
  "SRC_AUDIT_FIX SRC-2876"
  "RageSoundReader_Merge copy failures are diagnosable")
require_contains(
  "${rage_sound_reader_merge_cpp}"
  "SRC_AUDIT_FIX SRC-2877"
  "RageSoundReader_Merge AddSound/Finish misuse is diagnosable")
require_contains(
  "${rage_sound_reader_merge_cpp}"
  "SRC_AUDIT_FIX SRC-2878"
  "RageSoundReader_Merge wrapper publication failures are diagnosable")
require_contains(
  "${rage_sound_reader_merge_cpp}"
  "SRC_AUDIT_FIX SRC-2879"
  "RageSoundReader_Merge validates source topology")
require_contains(
  "${rage_sound_reader_merge_cpp}"
  "RageSoundReader_Merge: mix buffer write failed"
  "RageSoundReader_Merge handles mix write failures")
require_contains(
  "${rage_sound_reader_merge_cpp}"
  "SRC_AUDIT_FIX SRC-2880"
  "RageSoundReader_Merge checks channel mismatch in release builds")
require_contains(
  "${rage_sound_reader_merge_cpp}"
  "SRC_AUDIT_FIX SRC-2881"
  "RageSoundReader_Merge guards mix offset arithmetic")
require_contains(
  "${rage_sound_reader_merge_cpp}"
  "SRC_AUDIT_FIX SRC-2882"
  "RageSoundReader_Merge seek failures are diagnosable")
require_contains(
  "${rage_sound_reader_merge_cpp}"
  "SRC_AUDIT_FIX SRC-2883"
  "RageSoundReader_Merge property mismatches are diagnosable")
require_contains(
  "${rage_sound_reader_merge_cpp}"
  "SRC_AUDIT_FIX SRC-2884"
  "RageSoundReader_Merge read failures are diagnosable")
require_contains(
  "${rage_sound_reader_merge_cpp}"
  "SRC_AUDIT_FIX SRC-2885"
  "RageSoundReader_Merge read allocations are guarded")
require_contains(
  "${rage_sound_reader_merge_cpp}"
  "SRC_AUDIT_FIX SRC-2886"
  "RageSoundReader_Merge resync arithmetic is guarded")
require_contains(
  "${rage_sound_reader_merge_cpp}"
  "SRC_AUDIT_FIX SRC-2887"
  "RageSoundReader_Merge frame arithmetic is guarded")
require_contains(
  "${rage_sound_driver_generic_cpp}"
  "RageSoundDriver::MixIntoBuffer: mix buffer write failed"
  "Software sound driver handles mix write failures")
require_contains(
  "${rage_sound_util_h}"
  "bool Attenuate(float* pBuf, size_t iSamples, float fVolume);"
  "RageSoundUtil attenuation exposes an explicit operation status")
require_contains(
  "${rage_sound_util_h}"
  "bool Pan(float* pBuffer, size_t iFrames, unsigned iChannels, float fPos);"
  "RageSoundUtil pan contract requires explicit channels")
require_contains(
  "${rage_sound_util_h}"
  "bool ConvertMonoToStereoInPlace("
  "RageSoundUtil mono to stereo conversion exposes an operation status")
require_contains(
  "${rage_sound_util_h}"
  "size_t iOutputSamplesCapacity"
  "RageSoundUtil mono to stereo conversion requires output capacity")
require_contains(
  "${rage_sound_util_cpp}"
  "SRC_AUDIT_FIX %s RageSoundUtil::%s refused invalid input"
  "RageSoundUtil invalid inputs are review-traced")
require_contains(
  "${rage_sound_util_cpp}"
  "sanitized %zu non-finite samples"
  "RageSoundUtil sample sanitation is review-traced")
require_contains(
  "${rage_sound_util_cpp}"
  "sample <= -1.0f ? -32768L"
  "RageSoundUtil PCM16 conversion preserves the full negative range")
require_contains(
  "${rage_sound_util_cpp}"
  "static_cast<float>(iFrames - 1)"
  "RageSoundUtil fades reach the requested end volume on the last frame")
require_not_contains(
  "${rage_sound_util_h}"
  "void Attenuate("
  "RageSoundUtil helpers must not silently discard operation status")
require_not_contains(
  "${rage_sound_util_h}"
  "};  // namespace RageSoundUtil"
  "RageSoundUtil namespace terminator uses normal namespace style")

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
  "${rage_sound_reader_threaded_buffer_cpp}"
  "iRet < 0 && iRet != RageSoundReader::WOULD_BLOCK"
  "Threaded audio buffering preserves transient decoder backpressure")
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
