cmake_minimum_required(VERSION 3.20)

project(StepMania)

include(CTest)

include(StepmaniaCore.cmake)

# The external libraries need to be included.
add_subdirectory(extern)

# The internal libraries and eventual executable to be used.
add_subdirectory(src)

if(BUILD_TESTING)
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
    NAME step_parity_invariants
    COMMAND ${CMAKE_COMMAND}
            -DITGMANIA_SOURCE_DIR=${CMAKE_SOURCE_DIR}
            -P ${CMAKE_SOURCE_DIR}/CMake/CheckStepParityInvariants.cmake)
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
