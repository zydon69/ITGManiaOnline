if(NOT DEFINED ITGMANIA_EXE OR NOT DEFINED ITGMANIA_USER_DATA_DIR)
  message(
    FATAL_ERROR
    "RunGlobalOffsetProfileRuntimeTest.cmake requires ITGMANIA_EXE and ITGMANIA_USER_DATA_DIR")
endif()

set(preferences_path "${ITGMANIA_USER_DATA_DIR}/Save/Preferences.ini")
set(profile_storage_path
    "${ITGMANIA_USER_DATA_DIR}/Save/GlobalOffsetProfiles.ini")
set(profile_backup_path
    "${ITGMANIA_USER_DATA_DIR}/Save/GlobalOffsetProfiles.backup.ini")

function(write_base_preferences)
  file(WRITE "${preferences_path}"
"[Options]
CurrentGame=dance
DefaultTheme=Simply Love
FutureBuildPreference=keep-me
Language=en
SoundDrivers=Null
Theme=Simply Love
")
endfunction()

function(run_itgmania phase)
  if(DEFINED ITGMANIA_APP_BUNDLE)
    execute_process(
      COMMAND /usr/bin/open -W -n -g
              --env "ITGMANIA_USER_DATA_DIR=${ITGMANIA_USER_DATA_DIR}"
              "${ITGMANIA_APP_BUNDLE}"
              --args "--theme=Simply Love" "--playonce-smoke-test=1"
      RESULT_VARIABLE runtime_result)
  else()
    execute_process(
      COMMAND "${CMAKE_COMMAND}" -E env
              "ITGMANIA_USER_DATA_DIR=${ITGMANIA_USER_DATA_DIR}"
              "${ITGMANIA_EXE}" "--theme=Simply Love"
              "--playonce-smoke-test=1"
      RESULT_VARIABLE runtime_result)
  endif()

  if(NOT runtime_result EQUAL 0)
    message(
      FATAL_ERROR
      "global_offset_profile_runtime failed during ${phase} with exit code ${runtime_result}")
  endif()
endfunction()

function(require_file_contains path needle label)
  if(NOT EXISTS "${path}")
    message(FATAL_ERROR "${label}: missing ${path}")
  endif()
  file(READ "${path}" contents)
  string(FIND "${contents}" "${needle}" position)
  if(position EQUAL -1)
    message(FATAL_ERROR "${label}: '${needle}' missing from ${path}")
  endif()
endfunction()

file(REMOVE_RECURSE "${ITGMANIA_USER_DATA_DIR}")
file(MAKE_DIRECTORY
  "${ITGMANIA_USER_DATA_DIR}/Logs"
  "${ITGMANIA_USER_DATA_DIR}/Save")

# Phase 1: migrate an existing six-slot Preferences.ini into the independent
# profile store.
file(WRITE "${preferences_path}"
"[Options]
CurrentGame=dance
DefaultTheme=Simply Love
GlobalOffsetProfile1Name=Default
GlobalOffsetProfile1Seconds=-0.008000
GlobalOffsetProfile2Name=Headphones
GlobalOffsetProfile2Seconds=-0.042000
GlobalOffsetProfile3Name=Television
GlobalOffsetProfile3Seconds=0.087000
GlobalOffsetProfile4Name=Projector
GlobalOffsetProfile4Seconds=0.125000
GlobalOffsetProfile5Name=Arcade
GlobalOffsetProfile5Seconds=-0.019000
GlobalOffsetProfile6Name=Capture
GlobalOffsetProfile6Seconds=0.033000
GlobalOffsetProfileSelected=3
GlobalOffsetProfilesInitialized=1
GlobalOffsetSeconds=0.125000
Language=en
SoundDrivers=Null
Theme=Simply Love
")
run_itgmania("initial migration")
require_file_contains(
  "${profile_storage_path}" "Profile4Name=Projector"
  "initial profile storage")
require_file_contains(
  "${profile_storage_path}" "Profile4Seconds=0.125000"
  "initial profile value")
require_file_contains(
  "${profile_backup_path}" "Profile2Name=Headphones"
  "initial profile backup")

# Phase 2: simulate an older build rewriting Preferences.ini without knowing
# any multi-offset keys. The dedicated file must restore every slot.
write_base_preferences()
run_itgmania("older-build preference rewrite recovery")
require_file_contains(
  "${preferences_path}" "GlobalOffsetProfile2Name=Headphones"
  "restored Preferences.ini profile")
require_file_contains(
  "${preferences_path}" "GlobalOffsetProfile6Seconds=0.033000"
  "restored Preferences.ini value")
require_file_contains(
  "${preferences_path}" "GlobalOffsetProfileSelected=3"
  "restored selected profile")
require_file_contains(
  "${preferences_path}" "FutureBuildPreference=keep-me"
  "preserved newer-build preference")

# Phase 3: corrupt the primary store and remove the profile keys again. The
# backup must restore the data and regenerate a healthy primary store.
file(WRITE "${profile_storage_path}"
"[GlobalOffsetProfiles]
Version=999
")
write_base_preferences()
run_itgmania("backup recovery")
require_file_contains(
  "${profile_storage_path}" "Version=1"
  "regenerated primary storage")
require_file_contains(
  "${profile_storage_path}" "Profile3Name=Television"
  "backup-restored profile")
require_file_contains(
  "${preferences_path}" "GlobalOffsetProfile5Seconds=-0.019000"
  "backup-restored Preferences.ini value")

message(STATUS "Global offset profile runtime recovery passed")
