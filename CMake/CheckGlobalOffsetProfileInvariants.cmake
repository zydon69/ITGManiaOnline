if(NOT DEFINED ITGMANIA_SOURCE_DIR)
  message(FATAL_ERROR "ITGMANIA_SOURCE_DIR is required")
endif()

function(read_source relative_path output_var)
  set(path "${ITGMANIA_SOURCE_DIR}/${relative_path}")
  if(NOT EXISTS "${path}")
    message(FATAL_ERROR "Global offset invariant missing ${relative_path}")
  endif()
  file(READ "${path}" contents)
  set("${output_var}" "${contents}" PARENT_SCOPE)
endfunction()

function(require_contains contents needle label)
  string(FIND "${contents}" "${needle}" position)
  if(position EQUAL -1)
    message(FATAL_ERROR "Global offset invariant failed: ${label}")
  endif()
endfunction()

function(require_ordered contents first second label)
  string(FIND "${contents}" "${first}" first_position)
  string(FIND "${contents}" "${second}" second_position)
  if(first_position EQUAL -1 OR
     second_position EQUAL -1 OR
     NOT first_position LESS second_position)
    message(FATAL_ERROR "Global offset invariant failed: ${label}")
  endif()
endfunction()

read_source("src/SpecialFiles.cpp" special_files)
read_source("src/PrefsManager.cpp" prefs_manager)
read_source(
  "CMake/RunGlobalOffsetProfileRuntimeTest.cmake"
  runtime_test)
read_source(
  "Tests/global_offset_options_spec.lua"
  options_test)
read_source(
  "Themes/Simply Love/Scripts/SL-OperatorMenuOptions.lua"
  operator_options)

require_contains(
  "${special_files}"
  "Save/GlobalOffsetProfiles.ini"
  "named offsets need storage independent from Preferences.ini")
require_contains(
  "${special_files}"
  "Save/GlobalOffsetProfiles.backup.ini"
  "named offsets need a recovery copy")
require_contains(
  "${prefs_manager}"
  "LoadGlobalOffsetProfilesFromDisk("
  "startup must restore dedicated profile storage")
require_contains(
  "${prefs_manager}"
  "ReadGlobalOffsetProfilesFromFile(\n          SpecialFiles::GLOBAL_OFFSET_PROFILES_BACKUP_INI_PATH)"
  "startup must recover from the backup when the primary is unavailable")
require_contains(
  "${prefs_manager}"
  "SaveGlobalOffsetProfilesToDisk();"
  "normal preference saves must persist the dedicated profile storage")
require_contains(
  "${prefs_manager}"
  "ini.ReadFile(SpecialFiles::PREFERENCES_INI_PATH)"
  "preference saves must retain keys owned by newer builds")
require_contains(
  "${prefs_manager}"
  "GetMutableGlobalOffsetProfileSeconds(selected).Set(seconds);\n  m_fGlobalOffsetSeconds.Set(seconds);"
  "offset profile state must be coherent before the runtime change message")
require_contains(
  "${operator_options}"
  "ExportOnChange = pref == \"GlobalOffsetSeconds\""
  "offset edits must reach the active named slot before profile switches")
require_contains(
  "${operator_options}"
  "\"GlobalOffsetProfile1SecondsChanged\""
  "profile labels must refresh after active offset edits")
require_contains(
  "${options_test}"
  "profile selection must not re-enter its own row reload"
  "profile selection must avoid reentrant row mutation")
require_contains(
  "${operator_options}"
  "PREFSMAN:SetGlobalOffsetProfileSelected(selected)\n\t\t\t\t\t\t-- Persist the profile being left as well as the new\n\t\t\t\t\t\t-- selection before reloading either option row.\n\t\t\t\t\t\tPREFSMAN:SavePreferences()\n\t\t\t\t\t\tMESSAGEMAN:Broadcast(\"GlobalOffsetProfileChanged\")"
  "profile switches must persist before broadcasting option-row reload")
require_contains(
  "${runtime_test}"
  "older-build preference rewrite recovery"
  "runtime coverage must reproduce cross-build preference loss")
require_contains(
  "${runtime_test}"
  "backup recovery"
  "runtime coverage must verify corrupted-primary recovery")
require_contains(
  "${options_test}"
  "switching profiles must not discard the outgoing profile edit"
  "option-row coverage must protect edits across profile switches")

message(STATUS "Global offset profile invariants passed")
