if(NOT DEFINED ITGMANIA_EXE OR NOT DEFINED ITGMANIA_USER_DATA_DIR)
  message(FATAL_ERROR "RunPlayOnceSmokeTest.cmake requires ITGMANIA_EXE and ITGMANIA_USER_DATA_DIR")
endif()

set(smoke_log "${ITGMANIA_USER_DATA_DIR}/Logs/info.txt")
file(REMOVE_RECURSE "${ITGMANIA_USER_DATA_DIR}/Logs")
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

if(DEFINED ITGMANIA_APP_BUNDLE)
  if(NOT ITGMANIA_APP_BUNDLE MATCHES "\\.app$" OR
     NOT EXISTS "${ITGMANIA_APP_BUNDLE}/Contents/MacOS")
    message(FATAL_ERROR "Invalid macOS app bundle: ${ITGMANIA_APP_BUNDLE}")
  endif()

  # AppKit applications must be registered through LaunchServices.  Executing
  # Contents/MacOS/ITGmania directly can abort in HIServices on modern macOS.
  execute_process(
    COMMAND /usr/bin/open -W -n -g
            --env "ITGMANIA_USER_DATA_DIR=${ITGMANIA_USER_DATA_DIR}"
            "${ITGMANIA_APP_BUNDLE}"
            --args "--theme=Simply Love" "--playonce-smoke-test=8"
    RESULT_VARIABLE smoke_result)
else()
  execute_process(
    COMMAND "${CMAKE_COMMAND}" -E env
            "ITGMANIA_USER_DATA_DIR=${ITGMANIA_USER_DATA_DIR}"
            "${ITGMANIA_EXE}" "--theme=Simply Love" "--playonce-smoke-test=8"
    RESULT_VARIABLE smoke_result)
endif()

if(NOT smoke_result EQUAL 0)
  message(FATAL_ERROR "audio_playonce_runtime_smoke failed with exit code ${smoke_result}")
endif()

if(NOT EXISTS "${smoke_log}")
  message(FATAL_ERROR "audio_playonce_runtime_smoke did not create ${smoke_log}")
endif()
file(READ "${smoke_log}" smoke_log_contents)
if(NOT smoke_log_contents MATCHES "PlayOnce runtime smoke PASS:")
  message(FATAL_ERROR "audio_playonce_runtime_smoke exited without its PASS marker")
endif()
