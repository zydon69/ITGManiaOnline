if(NOT DEFINED ITGMANIA_SOURCE_DIR)
  message(FATAL_ERROR "ITGMANIA_SOURCE_DIR is required")
endif()

function(require_contains file needle description)
  file(READ "${ITGMANIA_SOURCE_DIR}/${file}" contents)
  string(FIND "${contents}" "${needle}" position)
  if(position EQUAL -1)
    message(FATAL_ERROR "${description}: '${needle}' missing from ${file}")
  endif()
endfunction()

function(require_not_contains file needle description)
  file(READ "${ITGMANIA_SOURCE_DIR}/${file}" contents)
  string(FIND "${contents}" "${needle}" position)
  if(NOT position EQUAL -1)
    message(FATAL_ERROR "${description}: forbidden '${needle}' remains in ${file}")
  endif()
endfunction()

require_contains(
  "src/ScreenSetTime.cpp"
  "SafeSubtractTime(adjustedTime, now, newOffset)"
  "ScreenSetTime offset subtraction must be checked")
require_contains(
  "src/ScreenSetTime.cpp"
  "HOOKS == nullptr || !HOOKS->SetTime(adjusted)"
  "ScreenSetTime must preserve OS set-time failures")
require_contains(
  "src/ScreenSetTime.cpp"
  "Cancel(SM_GoToPrevScreen)"
  "ScreenSetTime back navigation must use the menu cancellation lifecycle")
require_contains(
  "src/ScreenSongOptions.cpp"
  "ExportOptionsAndGetChangeMask("
  "Song option export must observe whether the parent actually exported")
require_contains(
  "src/ScreenSongOptions.cpp"
  "before.current != options.GetCurrent().m_FailType"
  "Explicit fail detection must cover every option level")
require_not_contains(
  "src/ScreenSongOptions.cpp"
  "m_In.StartTransitioning()"
  "Song option initialization must not start its transition early")

message(STATUS "Screen options revalidation invariants passed")
