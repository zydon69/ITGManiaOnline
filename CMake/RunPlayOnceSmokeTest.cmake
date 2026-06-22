if(NOT DEFINED ITGMANIA_EXE OR NOT DEFINED ITGMANIA_USER_DATA_DIR)
  message(FATAL_ERROR "RunPlayOnceSmokeTest.cmake requires ITGMANIA_EXE and ITGMANIA_USER_DATA_DIR")
endif()

file(MAKE_DIRECTORY
  "${ITGMANIA_USER_DATA_DIR}/Logs"
  "${ITGMANIA_USER_DATA_DIR}/Save")

file(WRITE "${ITGMANIA_USER_DATA_DIR}/Save/Preferences.ini"
"[Options]
CurrentGame=dance
DefaultTheme=Simply Love
Language=en
SoundDrivers=Null
Theme=Simply Love
")

execute_process(
  COMMAND "${CMAKE_COMMAND}" -E env
          "ITGMANIA_USER_DATA_DIR=${ITGMANIA_USER_DATA_DIR}"
          "${ITGMANIA_EXE}" "--theme=Simply Love" "--playonce-smoke-test=8"
  RESULT_VARIABLE smoke_result)

if(NOT smoke_result EQUAL 0)
  message(FATAL_ERROR "audio_playonce_runtime_smoke failed with exit code ${smoke_result}")
endif()
