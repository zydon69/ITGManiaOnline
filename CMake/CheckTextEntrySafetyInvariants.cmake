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

require_contains(
  "src/ScreenTestSound.h"
  "MAX_SIMULTANEOUS_COPIES = 64"
  "The sound test must bound simultaneous copied sounds")
require_contains(
  "src/ScreenTestSound.cpp"
  "!m_sounds[m_selected].s.LoadSucceeded()"
  "The sound test must not play a failed load")
require_contains(
  "src/ScreenTestSound.cpp"
  "m_textReady.fill(false);"
  "Repeated sound-test initialization must clear stale font readiness")
require_contains(
  "src/ScreenTextEntry.cpp"
  "g_PendingSettings = RuntimeSettings();"
  "Failed text-entry opens must clear pending settings")
require_contains(
  "src/ScreenTextEntry.cpp"
  "m_bQuestionReady = false;"
  "Repeated text-entry initialization must clear stale actor readiness")
require_contains(
  "src/ScreenTextEntry.cpp"
  "if (!type_path.empty())"
  "Optional text-entry sounds must not load empty paths")
require_contains(
  "src/ScreenTextEntry.cpp"
  "m_bEnding = true;"
  "Text-entry completion must be locked before validation callbacks")
require_contains(
  "src/ScreenTextEntry.cpp"
  "MaxInputLength\\\" must be finite"
  "Lua text limits must reject non-finite values before integer conversion")
require_contains(
  "src/ScreenTextEntry.cpp"
  "RStringToWstring(sError), MAX_TEXT_ENTRY_INPUT_LENGTH"
  "Validation errors must be bounded before display")
require_contains(
  "src/ScreenTextEntry.cpp"
  "THEME->IsThemeLoaded() && LUA != nullptr"
  "Text-entry theme assets require the Lua runtime")
require_contains(
  "src/ScreenTextEntry.cpp"
  "visual keyboard disabled because layout metrics are missing"
  "Visual keyboard layout metrics must be checked before use")
require_contains(
  "src/ScreenTextEntry.cpp"
  "RemoveChild(key);"
  "Repeated visual-keyboard initialization must detach old key actors")
require_contains(
  "src/Screen.h"
  "if (LUA != nullptr)"
  "Screen factories must guard Lua thread variables")

message(STATUS "Text entry safety invariants passed")
