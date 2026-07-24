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
  "src/ScreenDemonstration.cpp"
  "LUA == nullptr"
  "Demonstration metrics must require the Lua runtime")
require_contains(
  "src/ScreenJukebox.cpp"
  "bool HasThemeRuntime()"
  "Jukebox metrics must share a complete theme-runtime guard")
require_contains(
  "src/ScreenJukebox.cpp"
  "GAMESTATE->m_pCurSong.Set(nullptr);"
  "Jukebox song lookup must not reuse a stale selection")
require_contains(
  "src/ScreenJukebox.cpp"
  "if (IsInputLocked() || IsTransitioning())"
  "Jukebox skip input must respect screen state")
require_contains(
  "src/ScreenJukebox.cpp"
  "for (size_t i = m_apSongsQueue.size(); i-- > 0;)"
  "Jukebox queue pruning must avoid signed narrowing and empty underflow")

message(STATUS "Jukebox safety invariants passed")
