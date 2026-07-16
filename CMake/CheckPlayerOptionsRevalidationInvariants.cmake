if(NOT DEFINED ITGMANIA_SOURCE_DIR)
  message(FATAL_ERROR "ITGMANIA_SOURCE_DIR is required")
endif()

function(read_source relative_path output_var)
  set(path "${ITGMANIA_SOURCE_DIR}/${relative_path}")
  if(NOT EXISTS "${path}")
    message(FATAL_ERROR "Missing source file: ${path}")
  endif()
  file(READ "${path}" contents)
  set("${output_var}" "${contents}" PARENT_SCOPE)
endfunction()

function(require_contains haystack needle label)
  string(FIND "${haystack}" "${needle}" found_at)
  if(found_at EQUAL -1)
    message(FATAL_ERROR "Missing invariant: ${label}")
  endif()
endfunction()

function(require_not_contains haystack needle label)
  string(FIND "${haystack}" "${needle}" found_at)
  if(NOT found_at EQUAL -1)
    message(FATAL_ERROR "Forbidden pattern: ${label}")
  endif()
endfunction()

read_source("src/PlayerOptions.h" player_options_h)
read_source("src/PlayerOptions.cpp" player_options_cpp)
read_source("src/PlayerState.cpp" player_state_cpp)

require_contains(
  "${player_options_h}"
  "m_pn(PLAYER_INVALID)"
  "standalone PlayerOptions instances start with an invalid player identity")
require_contains(
  "${player_options_cpp}"
  "m_FailType = FailType_Immediate;"
  "Init resets fail behavior with the rest of the transient options")
require_contains(
  "${player_options_cpp}"
  "PlayerOptions::Approach scroll BPM"
  "CMod tween speed is finite and nonnegative before use")
require_contains(
  "${player_options_cpp}"
  "HasNumericModPrefix"
  "CMod and MMod tokens use exact numeric parsing without stealing named mods")
require_contains(
  "${player_options_cpp}"
  "ParsePositiveXMod(s, parsedXMod)"
  "valid XMod tokens bypass percentage parsing before final dispatch")
require_contains(
  "${player_options_cpp}"
  "ParsePositiveXMod(sBit, level)"
  "XMod dispatch uses the same strict positive parser as token classification")
require_contains(
  "${player_options_cpp}"
  "invalid approach speed"
  "malformed approach speed tokens are rejected")
require_contains(
  "${player_options_cpp}"
  "NOTESKIN ? NOTESKIN->GetDefaultNoteSkinName()"
  "clearall has a default noteskin fallback outside the noteskin manager lifetime")
require_contains(
  "${player_options_cpp}"
  "cannot resolve faildefault without GameState"
  "faildefault rejects missing global state instead of dereferencing it")
require_contains(
  "${player_options_cpp}"
  "std::isfinite(m_fVisualDelay)"
  "visual delay serialization rejects non-finite state")
require_contains(
  "${player_state_cpp}"
  "m_PlayerOptions.Assign(ModsLevel_Preferred,"
  "preferred options explicitly propagate through ModsGroup Assign")
require_not_contains(
  "${player_options_cpp}"
  "sscanf(sBit.c_str(), \"c%f\""
  "CMod parser must not accept trailing garbage")
require_not_contains(
  "${player_options_cpp}"
  "sscanf(sBit.c_str(), \"m%f\""
  "MMod parser must not accept trailing garbage")
