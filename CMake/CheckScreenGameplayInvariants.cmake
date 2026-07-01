if(NOT DEFINED ITGMANIA_SOURCE_DIR)
  message(FATAL_ERROR "ITGMANIA_SOURCE_DIR is required")
endif()

set(SCREEN_GAMEPLAY_SOURCE
    "${ITGMANIA_SOURCE_DIR}/src/ScreenGameplay.cpp")
file(READ "${SCREEN_GAMEPLAY_SOURCE}" SCREEN_GAMEPLAY_TEXT)

set(ONLINE_HELPERS_SOURCE
    "${ITGMANIA_SOURCE_DIR}/Themes/Simply Love/Scripts/SL-OnlineHelpers.lua")
file(READ "${ONLINE_HELPERS_SOURCE}" ONLINE_HELPERS_TEXT)

set(RAGE_SOUND_HEADER "${ITGMANIA_SOURCE_DIR}/src/RageSound.h")
set(RAGE_SOUND_SOURCE "${ITGMANIA_SOURCE_DIR}/src/RageSound.cpp")
file(READ "${RAGE_SOUND_HEADER}" RAGE_SOUND_HEADER_TEXT)
file(READ "${RAGE_SOUND_SOURCE}" RAGE_SOUND_SOURCE_TEXT)

foreach(REQUIRED_SNIPPET
    "GetGameplayStartLeadInSeconds"
    "const float startLeadInSeconds = GetGameplayStartLeadInSeconds"
    "p.m_StartSecond = -startLeadInSeconds;"
    "p.m_StartSecond = -onlineSecondsUntilStart;"
    "AlignMusicForOnlineStart"
    "SetPositionSeconds(musicSeconds, true)"
    "lead-in %.3fs startSecond=%.3f.")
  string(FIND "${SCREEN_GAMEPLAY_TEXT}" "${REQUIRED_SNIPPET}" SNIPPET_OFFSET)
  if(SNIPPET_OFFSET EQUAL -1)
    message(
        FATAL_ERROR
        "ScreenGameplay invariant failed: missing '${REQUIRED_SNIPPET}'")
  endif()
endforeach()

foreach(REQUIRED_SNIPPET
    "SetPositionSeconds(float seconds, bool allowNegative = false)"
    "if (!allowNegative)"
    "frameDouble < INT_MIN")
  string(FIND
      "${RAGE_SOUND_HEADER_TEXT}\n${RAGE_SOUND_SOURCE_TEXT}"
      "${REQUIRED_SNIPPET}"
      SNIPPET_OFFSET)
  if(SNIPPET_OFFSET EQUAL -1)
    message(
        FATAL_ERROR
        "ScreenGameplay sound positioning invariant failed: missing '${REQUIRED_SNIPPET}'")
  endif()
endforeach()

foreach(REQUIRED_SNIPPET
    "align pending online gameplay"
    "screen:AlignMusicForOnlineStart(seconds)"
    "align online gameplay"
    "alignedToSchedule")
  string(FIND "${ONLINE_HELPERS_TEXT}" "${REQUIRED_SNIPPET}" SNIPPET_OFFSET)
  if(SNIPPET_OFFSET EQUAL -1)
    message(
        FATAL_ERROR
        "ScreenGameplay online helper invariant failed: missing '${REQUIRED_SNIPPET}'")
  endif()
endforeach()

string(REGEX MATCH
    "if \\(GetITGOnlineShouldHoldGameplayForStart\\(\\)\\)[^{]*\\{[^}]*p\\.m_StartSecond[ \t]*=[ \t]*0\\.0f"
    HOLD_STARTS_AT_ZERO
    "${SCREEN_GAMEPLAY_TEXT}")
if(NOT HOLD_STARTS_AT_ZERO STREQUAL "")
  message(
      FATAL_ERROR
      "ScreenGameplay invariant failed: online start hold must keep the local lead-in instead of starting at 0.0")
endif()
