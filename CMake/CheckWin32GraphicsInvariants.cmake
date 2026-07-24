if(NOT DEFINED ITGMANIA_SOURCE_DIR)
  message(FATAL_ERROR "ITGMANIA_SOURCE_DIR is required")
endif()

file(
  READ
  "${ITGMANIA_SOURCE_DIR}/src/archutils/Win32/GraphicsWindow.cpp"
  WIN32_GRAPHICS_TEXT)

foreach(REQUIRED_SNIPPET
    "DisplayNameForWin32"
    "return displayId.empty() ? nullptr : displayId.c_str();"
    "EnumDisplaySettings(displayName, ENUM_CURRENT_SETTINGS, &dm)")
  string(FIND "${WIN32_GRAPHICS_TEXT}" "${REQUIRED_SNIPPET}" SNIPPET_OFFSET)
  if(SNIPPET_OFFSET EQUAL -1)
    message(
      FATAL_ERROR
      "Win32 graphics invariant failed: missing '${REQUIRED_SNIPPET}'")
  endif()
endforeach()

string(REGEX MATCH
  "(EnumDisplaySettings|ChangeDisplaySettingsEx)\\([^\\n]*sDisplayId\\.c_str\\(\\)"
  DIRECT_EMPTY_DISPLAY_ID_CALL
  "${WIN32_GRAPHICS_TEXT}")
if(NOT DIRECT_EMPTY_DISPLAY_ID_CALL STREQUAL "")
  message(
    FATAL_ERROR
    "Win32 graphics invariant failed: display APIs must map an empty id to nullptr")
endif()
