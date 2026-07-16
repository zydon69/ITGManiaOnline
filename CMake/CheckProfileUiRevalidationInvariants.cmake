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
