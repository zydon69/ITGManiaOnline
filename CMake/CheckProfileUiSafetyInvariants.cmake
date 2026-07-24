if(NOT DEFINED ITGMANIA_SOURCE_DIR)
  message(FATAL_ERROR "ITGMANIA_SOURCE_DIR is required")
endif()

file(READ
  "${ITGMANIA_SOURCE_DIR}/src/ScreenOptionsManageProfiles.cpp"
  profile_ui_cpp)

foreach(required
    "invalid master player on exit"
    "invalid current row on exit"
    "empty profile name returned"
    "clearing stale edited profile ID"
    "if (!PROFILEMAN->RenameLocalProfile"
    "if (!PROFILEMAN->DeleteLocalProfile"
    "clear target profile is missing")
  string(FIND "${profile_ui_cpp}" "${required}" found_at)
  if(found_at EQUAL -1)
    message(FATAL_ERROR "Missing profile UI invariant: ${required}")
  endif()
endforeach()

file(READ
  "${ITGMANIA_SOURCE_DIR}/Themes/Simply Love/BGAnimations/ScreenProfileSaveSummary decorations.lua"
  profile_save_summary_lua)

string(FIND "${profile_save_summary_lua}" "PROFILEMAN:SaveMachineProfile()"
  machine_save_at)
if(machine_save_at EQUAL -1)
  message(FATAL_ERROR "Profile save summary must persist the machine profile")
endif()

string(FIND "${profile_save_summary_lua}" ":Continue()" duplicate_continue_at)
if(NOT duplicate_continue_at EQUAL -1)
  message(FATAL_ERROR
    "Profile save summary must rely on its loaded base actor for the single player-profile save")
endif()
