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
  find_program(ITGMANIA_LUA_EXECUTABLE NAMES lua5.1 lua)
  if(ITGMANIA_LUA_EXECUTABLE)
    add_test(
      NAME online_protocol_behavior
      COMMAND ${ITGMANIA_LUA_EXECUTABLE}
              ${CMAKE_SOURCE_DIR}/Tests/online_protocol_spec.lua
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
    NAME src_revalidation_batch_001_invariants
    COMMAND ${CMAKE_COMMAND}
            -DITGMANIA_SOURCE_DIR=${CMAKE_SOURCE_DIR}
            -P ${CMAKE_SOURCE_DIR}/CMake/CheckSrcRevalidationBatch001Invariants.cmake)
  add_test(
    NAME src_review_tracker_invariants
    COMMAND ${CMAKE_COMMAND}
            -DITGMANIA_SOURCE_DIR=${CMAKE_SOURCE_DIR}
            -P ${CMAKE_SOURCE_DIR}/CMake/CheckSrcReviewTrackerInvariants.cmake)
  add_test(
    NAME writer_revalidation_invariants
    COMMAND ${CMAKE_COMMAND}
            -DITGMANIA_SOURCE_DIR=${CMAKE_SOURCE_DIR}
            -P ${CMAKE_SOURCE_DIR}/CMake/CheckWriterRevalidationInvariants.cmake)
  add_test(
    NAME sm_ssc_revalidation_invariants
    COMMAND ${CMAKE_COMMAND}
            -DITGMANIA_SOURCE_DIR=${CMAKE_SOURCE_DIR}
            -P ${CMAKE_SOURCE_DIR}/CMake/CheckSMSSCRevalidationInvariants.cmake)
  add_test(
    NAME song_steps_revalidation_invariants
    COMMAND ${CMAKE_COMMAND}
            -DITGMANIA_SOURCE_DIR=${CMAKE_SOURCE_DIR}
            -P ${CMAKE_SOURCE_DIR}/CMake/CheckSongStepsRevalidationInvariants.cmake)
  add_test(
    NAME song_manager_revalidation_invariants
    COMMAND ${CMAKE_COMMAND}
            -DITGMANIA_SOURCE_DIR=${CMAKE_SOURCE_DIR}
            -P ${CMAKE_SOURCE_DIR}/CMake/CheckSongManagerRevalidationInvariants.cmake)
  add_test(
    NAME course_revalidation_invariants
    COMMAND ${CMAKE_COMMAND}
            -DITGMANIA_SOURCE_DIR=${CMAKE_SOURCE_DIR}
            -P ${CMAKE_SOURCE_DIR}/CMake/CheckCourseRevalidationInvariants.cmake)
  add_test(
    NAME song_course_util_revalidation_invariants
    COMMAND ${CMAKE_COMMAND}
            -DITGMANIA_SOURCE_DIR=${CMAKE_SOURCE_DIR}
            -P ${CMAKE_SOURCE_DIR}/CMake/CheckSongCourseUtilRevalidationInvariants.cmake)
  add_test(
    NAME background_revalidation_invariants
    COMMAND ${CMAKE_COMMAND}
            -DITGMANIA_SOURCE_DIR=${CMAKE_SOURCE_DIR}
            -P ${CMAKE_SOURCE_DIR}/CMake/CheckBackgroundRevalidationInvariants.cmake)
  add_test(
    NAME bg_animation_revalidation_invariants
    COMMAND ${CMAKE_COMMAND}
            -DITGMANIA_SOURCE_DIR=${CMAKE_SOURCE_DIR}
            -P ${CMAKE_SOURCE_DIR}/CMake/CheckBGAnimationRevalidationInvariants.cmake)
  add_test(
    NAME visual_asset_revalidation_invariants
    COMMAND ${CMAKE_COMMAND}
            -DITGMANIA_SOURCE_DIR=${CMAKE_SOURCE_DIR}
            -P ${CMAKE_SOURCE_DIR}/CMake/CheckVisualAssetRevalidationInvariants.cmake)
  add_test(
    NAME text_actor_revalidation_invariants
    COMMAND ${CMAKE_COMMAND}
            -DITGMANIA_SOURCE_DIR=${CMAKE_SOURCE_DIR}
            -P ${CMAKE_SOURCE_DIR}/CMake/CheckTextActorRevalidationInvariants.cmake)
  add_test(
    NAME actor_core_revalidation_invariants
    COMMAND ${CMAKE_COMMAND}
            -DITGMANIA_SOURCE_DIR=${CMAKE_SOURCE_DIR}
            -P ${CMAKE_SOURCE_DIR}/CMake/CheckActorCoreRevalidationInvariants.cmake)
  add_test(
    NAME actor_scroller_model_revalidation_invariants
    COMMAND ${CMAKE_COMMAND}
            -DITGMANIA_SOURCE_DIR=${CMAKE_SOURCE_DIR}
            -P ${CMAKE_SOURCE_DIR}/CMake/CheckActorScrollerModelRevalidationInvariants.cmake)
  add_test(
    NAME model_font_revalidation_invariants
    COMMAND ${CMAKE_COMMAND}
            -DITGMANIA_SOURCE_DIR=${CMAKE_SOURCE_DIR}
            -P ${CMAKE_SOURCE_DIR}/CMake/CheckModelFontRevalidationInvariants.cmake)
  add_test(
    NAME texture_movie_revalidation_invariants
    COMMAND ${CMAKE_COMMAND}
            -DITGMANIA_SOURCE_DIR=${CMAKE_SOURCE_DIR}
            -P ${CMAKE_SOURCE_DIR}/CMake/CheckTextureMovieRevalidationInvariants.cmake)
  add_test(
    NAME ffmpeg_revalidation_invariants
    COMMAND ${CMAKE_COMMAND}
            -DITGMANIA_SOURCE_DIR=${CMAKE_SOURCE_DIR}
            -P ${CMAKE_SOURCE_DIR}/CMake/CheckFFMpegRevalidationInvariants.cmake)
  add_test(
    NAME sound_manager_revalidation_invariants
    COMMAND ${CMAKE_COMMAND}
            -DITGMANIA_SOURCE_DIR=${CMAKE_SOURCE_DIR}
            -P ${CMAKE_SOURCE_DIR}/CMake/CheckSoundManagerRevalidationInvariants.cmake)
  add_test(
    NAME sound_readers_revalidation_invariants
    COMMAND ${CMAKE_COMMAND}
            -DITGMANIA_SOURCE_DIR=${CMAKE_SOURCE_DIR}
            -P ${CMAKE_SOURCE_DIR}/CMake/CheckSoundReadersRevalidationInvariants.cmake)
  add_test(
    NAME sound_decoder_revalidation_invariants
    COMMAND ${CMAKE_COMMAND}
            -DITGMANIA_SOURCE_DIR=${CMAKE_SOURCE_DIR}
            -P ${CMAKE_SOURCE_DIR}/CMake/CheckSoundDecoderRevalidationInvariants.cmake)
  add_test(
    NAME sound_composition_revalidation_invariants
    COMMAND ${CMAKE_COMMAND}
            -DITGMANIA_SOURCE_DIR=${CMAKE_SOURCE_DIR}
            -P ${CMAKE_SOURCE_DIR}/CMake/CheckSoundCompositionRevalidationInvariants.cmake)
  add_test(
    NAME sound_driver_revalidation_invariants
    COMMAND ${CMAKE_COMMAND}
            -DITGMANIA_SOURCE_DIR=${CMAKE_SOURCE_DIR}
            -P ${CMAKE_SOURCE_DIR}/CMake/CheckSoundDriverRevalidationInvariants.cmake)
  add_test(
    NAME sound_backend_revalidation_invariants
    COMMAND ${CMAKE_COMMAND}
            -DITGMANIA_SOURCE_DIR=${CMAKE_SOURCE_DIR}
            -P ${CMAKE_SOURCE_DIR}/CMake/CheckSoundBackendRevalidationInvariants.cmake)
  add_test(
    NAME windows_sound_backend_revalidation_invariants
    COMMAND ${CMAKE_COMMAND}
            -DITGMANIA_SOURCE_DIR=${CMAKE_SOURCE_DIR}
            -P ${CMAKE_SOURCE_DIR}/CMake/CheckWindowsSoundBackendRevalidationInvariants.cmake)
  add_test(
    NAME screen_options_revalidation_invariants
    COMMAND ${CMAKE_COMMAND}
            -DITGMANIA_SOURCE_DIR=${CMAKE_SOURCE_DIR}
            -P ${CMAKE_SOURCE_DIR}/CMake/CheckScreenOptionsRevalidationInvariants.cmake)
  add_test(
    NAME splash_stats_revalidation_invariants
    COMMAND ${CMAKE_COMMAND}
            -DITGMANIA_SOURCE_DIR=${CMAKE_SOURCE_DIR}
            -P ${CMAKE_SOURCE_DIR}/CMake/CheckSplashStatsRevalidationInvariants.cmake)
  add_test(
    NAME sync_overlay_revalidation_invariants
    COMMAND ${CMAKE_COMMAND}
            -DITGMANIA_SOURCE_DIR=${CMAKE_SOURCE_DIR}
            -P ${CMAKE_SOURCE_DIR}/CMake/CheckSyncOverlayRevalidationInvariants.cmake)
  add_test(
    NAME system_layer_revalidation_invariants
    COMMAND ${CMAKE_COMMAND}
            -DITGMANIA_SOURCE_DIR=${CMAKE_SOURCE_DIR}
            -P ${CMAKE_SOURCE_DIR}/CMake/CheckSystemLayerRevalidationInvariants.cmake)
  add_test(
    NAME debug_overlay_revalidation_invariants
    COMMAND ${CMAKE_COMMAND}
            -DITGMANIA_SOURCE_DIR=${CMAKE_SOURCE_DIR}
            -P ${CMAKE_SOURCE_DIR}/CMake/CheckDebugOverlayRevalidationInvariants.cmake)
  add_test(
    NAME test_screens_revalidation_invariants
    COMMAND ${CMAKE_COMMAND}
            -DITGMANIA_SOURCE_DIR=${CMAKE_SOURCE_DIR}
            -P ${CMAKE_SOURCE_DIR}/CMake/CheckTestScreensRevalidationInvariants.cmake)
  add_test(
    NAME text_entry_revalidation_invariants
    COMMAND ${CMAKE_COMMAND}
            -DITGMANIA_SOURCE_DIR=${CMAKE_SOURCE_DIR}
            -P ${CMAKE_SOURCE_DIR}/CMake/CheckTextEntryRevalidationInvariants.cmake)
  add_test(
    NAME screen_core_revalidation_invariants
    COMMAND ${CMAKE_COMMAND}
            -DITGMANIA_SOURCE_DIR=${CMAKE_SOURCE_DIR}
            -P ${CMAKE_SOURCE_DIR}/CMake/CheckScreenCoreRevalidationInvariants.cmake)
  add_test(
    NAME bookkeeping_revalidation_invariants
    COMMAND ${CMAKE_COMMAND}
            -DITGMANIA_SOURCE_DIR=${CMAKE_SOURCE_DIR}
            -P ${CMAKE_SOURCE_DIR}/CMake/CheckBookkeepingRevalidationInvariants.cmake)
  add_test(
    NAME jukebox_revalidation_invariants
    COMMAND ${CMAKE_COMMAND}
            -DITGMANIA_SOURCE_DIR=${CMAKE_SOURCE_DIR}
            -P ${CMAKE_SOURCE_DIR}/CMake/CheckJukeboxRevalidationInvariants.cmake)
  add_test(
    NAME timing_core_revalidation_invariants
    COMMAND ${CMAKE_COMMAND}
            -DITGMANIA_SOURCE_DIR=${CMAKE_SOURCE_DIR}
            -P ${CMAKE_SOURCE_DIR}/CMake/CheckTimingCoreRevalidationInvariants.cmake)
  add_test(
    NAME note_data_radar_revalidation_invariants
    COMMAND ${CMAKE_COMMAND}
            -DITGMANIA_SOURCE_DIR=${CMAKE_SOURCE_DIR}
            -P ${CMAKE_SOURCE_DIR}/CMake/CheckNoteDataRadarRevalidationInvariants.cmake)
  add_test(
    NAME note_data_util_revalidation_invariants
    COMMAND ${CMAKE_COMMAND}
            -DITGMANIA_SOURCE_DIR=${CMAKE_SOURCE_DIR}
            -P ${CMAKE_SOURCE_DIR}/CMake/CheckNoteDataUtilRevalidationInvariants.cmake)
  add_test(
    NAME scoring_revalidation_invariants
    COMMAND ${CMAKE_COMMAND}
            -DITGMANIA_SOURCE_DIR=${CMAKE_SOURCE_DIR}
            -P ${CMAKE_SOURCE_DIR}/CMake/CheckScoringRevalidationInvariants.cmake)
  add_test(
    NAME stage_stats_grade_revalidation_invariants
    COMMAND ${CMAKE_COMMAND}
            -DITGMANIA_SOURCE_DIR=${CMAKE_SOURCE_DIR}
            -P ${CMAKE_SOURCE_DIR}/CMake/CheckStageStatsGradeRevalidationInvariants.cmake)
  add_test(
    NAME life_meter_score_display_revalidation_invariants
    COMMAND ${CMAKE_COMMAND}
            -DITGMANIA_SOURCE_DIR=${CMAKE_SOURCE_DIR}
            -P ${CMAKE_SOURCE_DIR}/CMake/CheckLifeMeterScoreDisplayRevalidationInvariants.cmake)
  add_test(
    NAME evaluation_widgets_revalidation_invariants
    COMMAND ${CMAKE_COMMAND}
            -DITGMANIA_SOURCE_DIR=${CMAKE_SOURCE_DIR}
            -P ${CMAKE_SOURCE_DIR}/CMake/CheckEvaluationWidgetsRevalidationInvariants.cmake)
  add_test(
    NAME game_state_revalidation_invariants
    COMMAND ${CMAKE_COMMAND}
            -DITGMANIA_SOURCE_DIR=${CMAKE_SOURCE_DIR}
            -P ${CMAKE_SOURCE_DIR}/CMake/CheckGameStateRevalidationInvariants.cmake)
  add_test(
    NAME active_attack_list_invariants
    COMMAND ${CMAKE_COMMAND}
            -DITGMANIA_SOURCE_DIR=${CMAKE_SOURCE_DIR}
            -P ${CMAKE_SOURCE_DIR}/CMake/CheckActiveAttackListInvariants.cmake)
  add_test(
    NAME player_options_revalidation_invariants
    COMMAND ${CMAKE_COMMAND}
            -DITGMANIA_SOURCE_DIR=${CMAKE_SOURCE_DIR}
            -P ${CMAKE_SOURCE_DIR}/CMake/CheckPlayerOptionsRevalidationInvariants.cmake)
  add_test(
    NAME player_revalidation_invariants
    COMMAND ${CMAKE_COMMAND}
            -DITGMANIA_SOURCE_DIR=${CMAKE_SOURCE_DIR}
            -P ${CMAKE_SOURCE_DIR}/CMake/CheckPlayerRevalidationInvariants.cmake)
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
    NAME game_loop_revalidation_invariants
    COMMAND ${CMAKE_COMMAND}
            -DITGMANIA_SOURCE_DIR=${CMAKE_SOURCE_DIR}
            -P ${CMAKE_SOURCE_DIR}/CMake/CheckGameLoopRevalidationInvariants.cmake)
  add_test(
    NAME memory_card_revalidation_invariants
    COMMAND ${CMAKE_COMMAND}
            -DITGMANIA_SOURCE_DIR=${CMAKE_SOURCE_DIR}
            -P ${CMAKE_SOURCE_DIR}/CMake/CheckMemoryCardRevalidationInvariants.cmake)
  add_test(
    NAME profile_ui_revalidation_invariants
    COMMAND ${CMAKE_COMMAND}
            -DITGMANIA_SOURCE_DIR=${CMAKE_SOURCE_DIR}
            -P ${CMAKE_SOURCE_DIR}/CMake/CheckProfileUiRevalidationInvariants.cmake)
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
endif()
