cmake_minimum_required(VERSION 3.20)

project(StepMania)

if(POLICY CMP0177)
  cmake_policy(SET CMP0177 NEW)
endif()

include(CTest)

include(StepmaniaCore.cmake)

# The external libraries need to be included.
add_subdirectory(extern)

# The internal libraries and eventual executable to be used.
add_subdirectory(src)

if(BUILD_TESTING)
  add_executable(
    display_link_pacing_policy_tests
    Tests/display_link_pacing_policy_test.cpp
    src/arch/LowLevelWindow/DisplayLinkPacingPolicy.cpp)
  target_include_directories(
    display_link_pacing_policy_tests PRIVATE "${CMAKE_SOURCE_DIR}/src")
  set_property(
    TARGET display_link_pacing_policy_tests PROPERTY CXX_STANDARD 17)
  set_property(
    TARGET display_link_pacing_policy_tests PROPERTY CXX_STANDARD_REQUIRED ON)
  add_test(
    NAME display_link_pacing_policy
    COMMAND display_link_pacing_policy_tests)

  add_executable(
    macos_metal_presentation_policy_tests
    Tests/macos_metal_presentation_policy_test.cpp
    src/arch/LowLevelWindow/MacOSMetalPresentationPolicy.cpp)
  target_include_directories(
    macos_metal_presentation_policy_tests PRIVATE "${CMAKE_SOURCE_DIR}/src")
  set_property(
    TARGET macos_metal_presentation_policy_tests PROPERTY CXX_STANDARD 17)
  set_property(
    TARGET macos_metal_presentation_policy_tests
    PROPERTY CXX_STANDARD_REQUIRED ON)
  add_test(
    NAME macos_metal_presentation_policy
    COMMAND macos_metal_presentation_policy_tests)

  find_program(ITGMANIA_LUA_EXECUTABLE NAMES lua5.1 lua)
  if(ITGMANIA_LUA_EXECUTABLE)
    add_test(
      NAME online_protocol_behavior
      COMMAND ${ITGMANIA_LUA_EXECUTABLE}
              ${CMAKE_SOURCE_DIR}/Tests/online_protocol_spec.lua
              ${CMAKE_SOURCE_DIR})
    add_test(
      NAME online_local_party_behavior
      COMMAND ${ITGMANIA_LUA_EXECUTABLE}
              ${CMAKE_SOURCE_DIR}/Tests/online_local_party_spec.lua
              ${CMAKE_SOURCE_DIR})
    add_test(
      NAME profile_io_cache_behavior
      COMMAND ${ITGMANIA_LUA_EXECUTABLE}
              ${CMAKE_SOURCE_DIR}/Tests/profile_io_cache_spec.lua
              ${CMAKE_SOURCE_DIR})
    add_test(
      NAME gameplay_presets_behavior
      COMMAND ${ITGMANIA_LUA_EXECUTABLE}
              ${CMAKE_SOURCE_DIR}/Tests/gameplay_presets_spec.lua
              ${CMAKE_SOURCE_DIR})
  endif()
  add_test(
    NAME audio_refactor_source_invariants
    COMMAND ${CMAKE_COMMAND}
            -DITGMANIA_SOURCE_DIR=${CMAKE_SOURCE_DIR}
            -P ${CMAKE_SOURCE_DIR}/CMake/CheckAudioRefactorInvariants.cmake)
  add_test(
    NAME noteskin_runtime_cache_invariants
    COMMAND ${CMAKE_COMMAND}
            -DITGMANIA_SOURCE_DIR=${CMAKE_SOURCE_DIR}
            -P ${CMAKE_SOURCE_DIR}/CMake/CheckNoteSkinRuntimeCacheInvariants.cmake)
  add_test(
    NAME metal_renderer_invariants
    COMMAND ${CMAKE_COMMAND}
            -DITGMANIA_SOURCE_DIR=${CMAKE_SOURCE_DIR}
            -P ${CMAKE_SOURCE_DIR}/CMake/CheckMetalRendererInvariants.cmake)
  add_test(
    NAME step_parity_invariants
    COMMAND ${CMAKE_COMMAND}
            -DITGMANIA_SOURCE_DIR=${CMAKE_SOURCE_DIR}
            -P ${CMAKE_SOURCE_DIR}/CMake/CheckStepParityInvariants.cmake)
  add_test(
    NAME source_safety_invariants
    COMMAND ${CMAKE_COMMAND}
            -DITGMANIA_SOURCE_DIR=${CMAKE_SOURCE_DIR}
            -P ${CMAKE_SOURCE_DIR}/CMake/CheckSourceSafetyInvariants.cmake)
  add_test(
    NAME writer_safety_invariants
    COMMAND ${CMAKE_COMMAND}
            -DITGMANIA_SOURCE_DIR=${CMAKE_SOURCE_DIR}
            -P ${CMAKE_SOURCE_DIR}/CMake/CheckWriterSafetyInvariants.cmake)
  add_test(
    NAME sm_ssc_safety_invariants
    COMMAND ${CMAKE_COMMAND}
            -DITGMANIA_SOURCE_DIR=${CMAKE_SOURCE_DIR}
            -P ${CMAKE_SOURCE_DIR}/CMake/CheckSMSSCSafetyInvariants.cmake)
  add_test(
    NAME song_steps_safety_invariants
    COMMAND ${CMAKE_COMMAND}
            -DITGMANIA_SOURCE_DIR=${CMAKE_SOURCE_DIR}
            -P ${CMAKE_SOURCE_DIR}/CMake/CheckSongStepsSafetyInvariants.cmake)
  add_test(
    NAME song_manager_safety_invariants
    COMMAND ${CMAKE_COMMAND}
            -DITGMANIA_SOURCE_DIR=${CMAKE_SOURCE_DIR}
            -P ${CMAKE_SOURCE_DIR}/CMake/CheckSongManagerSafetyInvariants.cmake)
  add_test(
    NAME course_safety_invariants
    COMMAND ${CMAKE_COMMAND}
            -DITGMANIA_SOURCE_DIR=${CMAKE_SOURCE_DIR}
            -P ${CMAKE_SOURCE_DIR}/CMake/CheckCourseSafetyInvariants.cmake)
  add_test(
    NAME song_course_util_safety_invariants
    COMMAND ${CMAKE_COMMAND}
            -DITGMANIA_SOURCE_DIR=${CMAKE_SOURCE_DIR}
            -P ${CMAKE_SOURCE_DIR}/CMake/CheckSongCourseUtilSafetyInvariants.cmake)
  add_test(
    NAME background_safety_invariants
    COMMAND ${CMAKE_COMMAND}
            -DITGMANIA_SOURCE_DIR=${CMAKE_SOURCE_DIR}
            -P ${CMAKE_SOURCE_DIR}/CMake/CheckBackgroundSafetyInvariants.cmake)
  add_test(
    NAME bg_animation_safety_invariants
    COMMAND ${CMAKE_COMMAND}
            -DITGMANIA_SOURCE_DIR=${CMAKE_SOURCE_DIR}
            -P ${CMAKE_SOURCE_DIR}/CMake/CheckBGAnimationSafetyInvariants.cmake)
  add_test(
    NAME visual_asset_safety_invariants
    COMMAND ${CMAKE_COMMAND}
            -DITGMANIA_SOURCE_DIR=${CMAKE_SOURCE_DIR}
            -P ${CMAKE_SOURCE_DIR}/CMake/CheckVisualAssetSafetyInvariants.cmake)
  add_test(
    NAME text_actor_safety_invariants
    COMMAND ${CMAKE_COMMAND}
            -DITGMANIA_SOURCE_DIR=${CMAKE_SOURCE_DIR}
            -P ${CMAKE_SOURCE_DIR}/CMake/CheckTextActorSafetyInvariants.cmake)
  add_test(
    NAME actor_core_safety_invariants
    COMMAND ${CMAKE_COMMAND}
            -DITGMANIA_SOURCE_DIR=${CMAKE_SOURCE_DIR}
            -P ${CMAKE_SOURCE_DIR}/CMake/CheckActorCoreSafetyInvariants.cmake)
  add_test(
    NAME actor_scroller_model_safety_invariants
    COMMAND ${CMAKE_COMMAND}
            -DITGMANIA_SOURCE_DIR=${CMAKE_SOURCE_DIR}
            -P ${CMAKE_SOURCE_DIR}/CMake/CheckActorScrollerModelSafetyInvariants.cmake)
  add_test(
    NAME model_font_safety_invariants
    COMMAND ${CMAKE_COMMAND}
            -DITGMANIA_SOURCE_DIR=${CMAKE_SOURCE_DIR}
            -P ${CMAKE_SOURCE_DIR}/CMake/CheckModelFontSafetyInvariants.cmake)
  add_test(
    NAME texture_movie_safety_invariants
    COMMAND ${CMAKE_COMMAND}
            -DITGMANIA_SOURCE_DIR=${CMAKE_SOURCE_DIR}
            -P ${CMAKE_SOURCE_DIR}/CMake/CheckTextureMovieSafetyInvariants.cmake)
  add_test(
    NAME ffmpeg_safety_invariants
    COMMAND ${CMAKE_COMMAND}
            -DITGMANIA_SOURCE_DIR=${CMAKE_SOURCE_DIR}
            -P ${CMAKE_SOURCE_DIR}/CMake/CheckFFMpegSafetyInvariants.cmake)
  add_test(
    NAME sound_manager_safety_invariants
    COMMAND ${CMAKE_COMMAND}
            -DITGMANIA_SOURCE_DIR=${CMAKE_SOURCE_DIR}
            -P ${CMAKE_SOURCE_DIR}/CMake/CheckSoundManagerSafetyInvariants.cmake)
  add_test(
    NAME sound_readers_safety_invariants
    COMMAND ${CMAKE_COMMAND}
            -DITGMANIA_SOURCE_DIR=${CMAKE_SOURCE_DIR}
            -P ${CMAKE_SOURCE_DIR}/CMake/CheckSoundReadersSafetyInvariants.cmake)
  add_test(
    NAME sound_decoder_safety_invariants
    COMMAND ${CMAKE_COMMAND}
            -DITGMANIA_SOURCE_DIR=${CMAKE_SOURCE_DIR}
            -P ${CMAKE_SOURCE_DIR}/CMake/CheckSoundDecoderSafetyInvariants.cmake)
  add_test(
    NAME sound_composition_safety_invariants
    COMMAND ${CMAKE_COMMAND}
            -DITGMANIA_SOURCE_DIR=${CMAKE_SOURCE_DIR}
            -P ${CMAKE_SOURCE_DIR}/CMake/CheckSoundCompositionSafetyInvariants.cmake)
  add_test(
    NAME sound_driver_safety_invariants
    COMMAND ${CMAKE_COMMAND}
            -DITGMANIA_SOURCE_DIR=${CMAKE_SOURCE_DIR}
            -P ${CMAKE_SOURCE_DIR}/CMake/CheckSoundDriverSafetyInvariants.cmake)
  add_test(
    NAME sound_backend_safety_invariants
    COMMAND ${CMAKE_COMMAND}
            -DITGMANIA_SOURCE_DIR=${CMAKE_SOURCE_DIR}
            -P ${CMAKE_SOURCE_DIR}/CMake/CheckSoundBackendSafetyInvariants.cmake)
  add_test(
    NAME windows_sound_backend_safety_invariants
    COMMAND ${CMAKE_COMMAND}
            -DITGMANIA_SOURCE_DIR=${CMAKE_SOURCE_DIR}
            -P ${CMAKE_SOURCE_DIR}/CMake/CheckWindowsSoundBackendSafetyInvariants.cmake)
  add_test(
    NAME screen_options_safety_invariants
    COMMAND ${CMAKE_COMMAND}
            -DITGMANIA_SOURCE_DIR=${CMAKE_SOURCE_DIR}
            -P ${CMAKE_SOURCE_DIR}/CMake/CheckScreenOptionsSafetyInvariants.cmake)
  add_test(
    NAME splash_stats_safety_invariants
    COMMAND ${CMAKE_COMMAND}
            -DITGMANIA_SOURCE_DIR=${CMAKE_SOURCE_DIR}
            -P ${CMAKE_SOURCE_DIR}/CMake/CheckSplashStatsSafetyInvariants.cmake)
  add_test(
    NAME sync_overlay_safety_invariants
    COMMAND ${CMAKE_COMMAND}
            -DITGMANIA_SOURCE_DIR=${CMAKE_SOURCE_DIR}
            -P ${CMAKE_SOURCE_DIR}/CMake/CheckSyncOverlaySafetyInvariants.cmake)
  add_test(
    NAME system_layer_safety_invariants
    COMMAND ${CMAKE_COMMAND}
            -DITGMANIA_SOURCE_DIR=${CMAKE_SOURCE_DIR}
            -P ${CMAKE_SOURCE_DIR}/CMake/CheckSystemLayerSafetyInvariants.cmake)
  add_test(
    NAME debug_overlay_safety_invariants
    COMMAND ${CMAKE_COMMAND}
            -DITGMANIA_SOURCE_DIR=${CMAKE_SOURCE_DIR}
            -P ${CMAKE_SOURCE_DIR}/CMake/CheckDebugOverlaySafetyInvariants.cmake)
  add_test(
    NAME test_screens_safety_invariants
    COMMAND ${CMAKE_COMMAND}
            -DITGMANIA_SOURCE_DIR=${CMAKE_SOURCE_DIR}
            -P ${CMAKE_SOURCE_DIR}/CMake/CheckTestScreensSafetyInvariants.cmake)
  add_test(
    NAME text_entry_safety_invariants
    COMMAND ${CMAKE_COMMAND}
            -DITGMANIA_SOURCE_DIR=${CMAKE_SOURCE_DIR}
            -P ${CMAKE_SOURCE_DIR}/CMake/CheckTextEntrySafetyInvariants.cmake)
  add_test(
    NAME screen_core_safety_invariants
    COMMAND ${CMAKE_COMMAND}
            -DITGMANIA_SOURCE_DIR=${CMAKE_SOURCE_DIR}
            -P ${CMAKE_SOURCE_DIR}/CMake/CheckScreenCoreSafetyInvariants.cmake)
  add_test(
    NAME bookkeeping_safety_invariants
    COMMAND ${CMAKE_COMMAND}
            -DITGMANIA_SOURCE_DIR=${CMAKE_SOURCE_DIR}
            -P ${CMAKE_SOURCE_DIR}/CMake/CheckBookkeepingSafetyInvariants.cmake)
  add_test(
    NAME jukebox_safety_invariants
    COMMAND ${CMAKE_COMMAND}
            -DITGMANIA_SOURCE_DIR=${CMAKE_SOURCE_DIR}
            -P ${CMAKE_SOURCE_DIR}/CMake/CheckJukeboxSafetyInvariants.cmake)
  add_test(
    NAME ending_lesson_safety_invariants
    COMMAND ${CMAKE_COMMAND}
            -DITGMANIA_SOURCE_DIR=${CMAKE_SOURCE_DIR}
            -P ${CMAKE_SOURCE_DIR}/CMake/CheckEndingLessonSafetyInvariants.cmake)
  add_test(
    NAME timing_core_safety_invariants
    COMMAND ${CMAKE_COMMAND}
            -DITGMANIA_SOURCE_DIR=${CMAKE_SOURCE_DIR}
            -P ${CMAKE_SOURCE_DIR}/CMake/CheckTimingCoreSafetyInvariants.cmake)
  add_test(
    NAME note_data_radar_safety_invariants
    COMMAND ${CMAKE_COMMAND}
            -DITGMANIA_SOURCE_DIR=${CMAKE_SOURCE_DIR}
            -P ${CMAKE_SOURCE_DIR}/CMake/CheckNoteDataRadarSafetyInvariants.cmake)
  add_test(
    NAME note_data_util_safety_invariants
    COMMAND ${CMAKE_COMMAND}
            -DITGMANIA_SOURCE_DIR=${CMAKE_SOURCE_DIR}
            -P ${CMAKE_SOURCE_DIR}/CMake/CheckNoteDataUtilSafetyInvariants.cmake)
  add_test(
    NAME scoring_safety_invariants
    COMMAND ${CMAKE_COMMAND}
            -DITGMANIA_SOURCE_DIR=${CMAKE_SOURCE_DIR}
            -P ${CMAKE_SOURCE_DIR}/CMake/CheckScoringSafetyInvariants.cmake)
  add_test(
    NAME stage_stats_grade_safety_invariants
    COMMAND ${CMAKE_COMMAND}
            -DITGMANIA_SOURCE_DIR=${CMAKE_SOURCE_DIR}
            -P ${CMAKE_SOURCE_DIR}/CMake/CheckStageStatsGradeSafetyInvariants.cmake)
  add_test(
    NAME high_score_safety_invariants
    COMMAND ${CMAKE_COMMAND}
            -DITGMANIA_SOURCE_DIR=${CMAKE_SOURCE_DIR}
            -P ${CMAKE_SOURCE_DIR}/CMake/CheckHighScoreSafetyInvariants.cmake)
  add_test(
    NAME profile_safety_invariants
    COMMAND ${CMAKE_COMMAND}
            -DITGMANIA_SOURCE_DIR=${CMAKE_SOURCE_DIR}
            -P ${CMAKE_SOURCE_DIR}/CMake/CheckProfileSafetyInvariants.cmake)
  add_test(
    NAME life_meter_score_display_safety_invariants
    COMMAND ${CMAKE_COMMAND}
            -DITGMANIA_SOURCE_DIR=${CMAKE_SOURCE_DIR}
            -P ${CMAKE_SOURCE_DIR}/CMake/CheckLifeMeterScoreDisplaySafetyInvariants.cmake)
  add_test(
    NAME evaluation_widgets_safety_invariants
    COMMAND ${CMAKE_COMMAND}
            -DITGMANIA_SOURCE_DIR=${CMAKE_SOURCE_DIR}
            -P ${CMAKE_SOURCE_DIR}/CMake/CheckEvaluationWidgetsSafetyInvariants.cmake)
  add_test(
    NAME game_state_safety_invariants
    COMMAND ${CMAKE_COMMAND}
            -DITGMANIA_SOURCE_DIR=${CMAKE_SOURCE_DIR}
            -P ${CMAKE_SOURCE_DIR}/CMake/CheckGameStateSafetyInvariants.cmake)
  add_test(
    NAME active_attack_list_invariants
    COMMAND ${CMAKE_COMMAND}
            -DITGMANIA_SOURCE_DIR=${CMAKE_SOURCE_DIR}
            -P ${CMAKE_SOURCE_DIR}/CMake/CheckActiveAttackListInvariants.cmake)
  add_test(
    NAME player_options_safety_invariants
    COMMAND ${CMAKE_COMMAND}
            -DITGMANIA_SOURCE_DIR=${CMAKE_SOURCE_DIR}
            -P ${CMAKE_SOURCE_DIR}/CMake/CheckPlayerOptionsSafetyInvariants.cmake)
  add_test(
    NAME player_safety_invariants
    COMMAND ${CMAKE_COMMAND}
            -DITGMANIA_SOURCE_DIR=${CMAKE_SOURCE_DIR}
            -P ${CMAKE_SOURCE_DIR}/CMake/CheckPlayerSafetyInvariants.cmake)
  add_test(
    NAME announcer_manager_invariants
    COMMAND ${CMAKE_COMMAND}
            -DITGMANIA_SOURCE_DIR=${CMAKE_SOURCE_DIR}
            -P ${CMAKE_SOURCE_DIR}/CMake/CheckAnnouncerManagerInvariants.cmake)
  add_test(
    NAME attack_invariants
    COMMAND ${CMAKE_COMMAND}
            -DITGMANIA_SOURCE_DIR=${CMAKE_SOURCE_DIR}
            -P ${CMAKE_SOURCE_DIR}/CMake/CheckAttackInvariants.cmake)
  add_test(
    NAME attack_display_invariants
    COMMAND ${CMAKE_COMMAND}
            -DITGMANIA_SOURCE_DIR=${CMAKE_SOURCE_DIR}
            -P ${CMAKE_SOURCE_DIR}/CMake/CheckAttackDisplayInvariants.cmake)
  add_test(
    NAME inventory_invariants
    COMMAND ${CMAKE_COMMAND}
            -DITGMANIA_SOURCE_DIR=${CMAKE_SOURCE_DIR}
            -P ${CMAKE_SOURCE_DIR}/CMake/CheckInventoryInvariants.cmake)
  add_test(
    NAME game_loop_safety_invariants
    COMMAND ${CMAKE_COMMAND}
            -DITGMANIA_SOURCE_DIR=${CMAKE_SOURCE_DIR}
            -P ${CMAKE_SOURCE_DIR}/CMake/CheckGameLoopSafetyInvariants.cmake)
  add_test(
    NAME memory_card_safety_invariants
    COMMAND ${CMAKE_COMMAND}
            -DITGMANIA_SOURCE_DIR=${CMAKE_SOURCE_DIR}
            -P ${CMAKE_SOURCE_DIR}/CMake/CheckMemoryCardSafetyInvariants.cmake)
  add_test(
    NAME profile_ui_safety_invariants
    COMMAND ${CMAKE_COMMAND}
            -DITGMANIA_SOURCE_DIR=${CMAKE_SOURCE_DIR}
            -P ${CMAKE_SOURCE_DIR}/CMake/CheckProfileUiSafetyInvariants.cmake)
  add_test(
    NAME auto_actor_invariants
    COMMAND ${CMAKE_COMMAND}
            -DITGMANIA_SOURCE_DIR=${CMAKE_SOURCE_DIR}
            -P ${CMAKE_SOURCE_DIR}/CMake/CheckAutoActorInvariants.cmake)
  add_test(
    NAME actor_proxy_invariants
    COMMAND ${CMAKE_COMMAND}
            -DITGMANIA_SOURCE_DIR=${CMAKE_SOURCE_DIR}
            -P ${CMAKE_SOURCE_DIR}/CMake/CheckActorProxyInvariants.cmake)
  add_test(
    NAME actor_scroller_invariants
    COMMAND ${CMAKE_COMMAND}
            -DITGMANIA_SOURCE_DIR=${CMAKE_SOURCE_DIR}
            -P ${CMAKE_SOURCE_DIR}/CMake/CheckActorScrollerInvariants.cmake)
  add_test(
    NAME actor_sound_invariants
    COMMAND ${CMAKE_COMMAND}
            -DITGMANIA_SOURCE_DIR=${CMAKE_SOURCE_DIR}
            -P ${CMAKE_SOURCE_DIR}/CMake/CheckActorSoundInvariants.cmake)
  add_test(
    NAME lua_expression_transform_invariants
    COMMAND ${CMAKE_COMMAND}
            -DITGMANIA_SOURCE_DIR=${CMAKE_SOURCE_DIR}
            -P ${CMAKE_SOURCE_DIR}/CMake/CheckLuaExpressionTransformInvariants.cmake)
  add_test(
    NAME network_manager_invariants
    COMMAND ${CMAKE_COMMAND}
            -DITGMANIA_SOURCE_DIR=${CMAKE_SOURCE_DIR}
            -P ${CMAKE_SOURCE_DIR}/CMake/CheckNetworkManagerInvariants.cmake)
  add_test(
    NAME screen_gameplay_invariants
    COMMAND ${CMAKE_COMMAND}
            -DITGMANIA_SOURCE_DIR=${CMAKE_SOURCE_DIR}
            -P ${CMAKE_SOURCE_DIR}/CMake/CheckScreenGameplayInvariants.cmake)
  add_test(
    NAME routine_couple_invariants
    COMMAND ${CMAKE_COMMAND}
            -DITGMANIA_SOURCE_DIR=${CMAKE_SOURCE_DIR}
            -P ${CMAKE_SOURCE_DIR}/CMake/CheckRoutineCoupleInvariants.cmake)
  add_test(
    NAME online_pack_sync_invariants
    COMMAND ${CMAKE_COMMAND}
            -DITGMANIA_SOURCE_DIR=${CMAKE_SOURCE_DIR}
            -P ${CMAKE_SOURCE_DIR}/CMake/CheckOnlinePackSyncInvariants.cmake)
  add_test(
    NAME win32_graphics_invariants
    COMMAND ${CMAKE_COMMAND}
            -DITGMANIA_SOURCE_DIR=${CMAKE_SOURCE_DIR}
            -P ${CMAKE_SOURCE_DIR}/CMake/CheckWin32GraphicsInvariants.cmake)
  add_test(
    NAME timing_loader_invariants
    COMMAND ${CMAKE_COMMAND}
            -DITGMANIA_SOURCE_DIR=${CMAKE_SOURCE_DIR}
            -P ${CMAKE_SOURCE_DIR}/CMake/CheckTimingLoaderInvariants.cmake)
  add_test(
    NAME bms_loader_invariants
    COMMAND ${CMAKE_COMMAND}
            -DITGMANIA_SOURCE_DIR=${CMAKE_SOURCE_DIR}
            -P ${CMAKE_SOURCE_DIR}/CMake/CheckBMSLoaderInvariants.cmake)
  add_test(
    NAME json_loader_invariants
    COMMAND ${CMAKE_COMMAND}
            -DITGMANIA_SOURCE_DIR=${CMAKE_SOURCE_DIR}
            -P ${CMAKE_SOURCE_DIR}/CMake/CheckJsonLoaderInvariants.cmake)
  add_test(
    NAME legacy_loader_invariants
    COMMAND ${CMAKE_COMMAND}
            -DITGMANIA_SOURCE_DIR=${CMAKE_SOURCE_DIR}
            -P ${CMAKE_SOURCE_DIR}/CMake/CheckLegacyLoaderInvariants.cmake)
  add_test(
    NAME log_hygiene_invariants
    COMMAND ${CMAKE_COMMAND}
            -DITGMANIA_SOURCE_DIR=${CMAKE_SOURCE_DIR}
            -P ${CMAKE_SOURCE_DIR}/CMake/CheckLogHygieneInvariants.cmake)
  add_test(
    NAME rage_file_invariants
    COMMAND ${CMAKE_COMMAND}
            -DITGMANIA_SOURCE_DIR=${CMAKE_SOURCE_DIR}
            -P ${CMAKE_SOURCE_DIR}/CMake/CheckRageFileInvariants.cmake)
  add_test(
    NAME steps_reload_invariants
    COMMAND ${CMAKE_COMMAND}
            -DITGMANIA_SOURCE_DIR=${CMAKE_SOURCE_DIR}
            -P ${CMAKE_SOURCE_DIR}/CMake/CheckStepsReloadInvariants.cmake)
  add_test(
    NAME macos_debug_info_invariants
    COMMAND ${CMAKE_COMMAND}
            -DITGMANIA_SOURCE_DIR=${CMAKE_SOURCE_DIR}
            -P ${CMAKE_SOURCE_DIR}/CMake/CheckMacOSDebugInfoInvariants.cmake)
  add_test(
    NAME teejusb_fsr_invariants
    COMMAND ${CMAKE_COMMAND}
            -DITGMANIA_SOURCE_DIR=${CMAKE_SOURCE_DIR}
            -P ${CMAKE_SOURCE_DIR}/CMake/CheckTeejusbFsrInvariants.cmake)
  add_test(
    NAME rage_file_wrapper_invariants
    COMMAND ${CMAKE_COMMAND}
            -DITGMANIA_SOURCE_DIR=${CMAKE_SOURCE_DIR}
            -P ${CMAKE_SOURCE_DIR}/CMake/CheckRageFileWrapperInvariants.cmake)
  add_test(
    NAME external_content_safety_invariants
    COMMAND ${CMAKE_COMMAND}
            -DITGMANIA_SOURCE_DIR=${CMAKE_SOURCE_DIR}
            -P ${CMAKE_SOURCE_DIR}/CMake/CheckExternalContentSafetyInvariants.cmake)
endif()
