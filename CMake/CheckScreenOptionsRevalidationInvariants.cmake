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
require_contains(
  "src/ScreenOptions.cpp"
  "if (m_sprPage.IsLoaded())"
  "ScreenOptions must not dereference a missing page actor")
require_contains(
  "src/ScreenOptions.cpp"
  "if (m_sprLineHighlight[p].IsLoaded())"
  "ScreenOptions must not dereference a missing line highlight")
require_contains(
  "src/ScreenOptions.cpp"
  "if (m_sprMore.IsLoaded())"
  "ScreenOptions must not dereference a missing more actor")
require_contains(
  "src/ScreenOptions.cpp"
  "std::isfinite(configuredTweenSeconds)"
  "ScreenOptions cursor tween duration must be finite")
require_contains(
  "src/ScreenOptions.cpp"
  "focusedChoice >= static_cast<int>(row.GetRowDef().m_vsChoices.size())"
  "ScreenOptions must preserve stored focus when no valid choice exists")
require_contains(
  "src/ScreenOptions.cpp"
  "iCurrentChoiceWithFocus >= iNumChoices"
  "ScreenOptions absolute changes must normalize stale focus")
require_contains(
  "src/ScreenPlayerOptions.cpp"
  "if (m_sprDisqualify[p].IsLoaded())"
  "ScreenPlayerOptions must not dereference a missing disqualification actor")
require_contains(
  "src/OptionRowHandler.h"
  "ExportOptionForPreview"
  "Option row handlers must expose an explicitly side-effect-free preview path")
require_contains(
  "src/OptionRowHandler.cpp"
  "GAMESTATE->ApplyPreferredModifiers("
  "Option row previews must apply only the preferred modifiers needed for disqualification")
require_contains(
  "src/OptionRow.cpp"
  "ExportOptionsInternal(vpns, bRowHasFocus, true)"
  "Option rows must route previews separately from real exports")
require_contains(
  "src/ScreenOptionsMaster.cpp"
  "row->ExportOptionsForPreview(validPlayers, bRowHasFocus)"
  "Screen option previews must use the preview export path")
require_not_contains(
  "src/ScreenPlayerOptions.cpp"
  "ScreenOptionsPreviewExport"
  "ScreenPlayerOptions must not rely on an unread Lua thread variable for preview isolation")

message(STATUS "Screen options revalidation invariants passed")
