if(NOT DEFINED ITGMANIA_SOURCE_DIR)
  message(FATAL_ERROR "ITGMANIA_SOURCE_DIR is required")
endif()

set(SCREEN_GAMEPLAY_SOURCE
    "${ITGMANIA_SOURCE_DIR}/src/ScreenGameplay.cpp")
file(READ "${SCREEN_GAMEPLAY_SOURCE}" SCREEN_GAMEPLAY_TEXT)

set(ONLINE_HELPERS_SOURCE
    "${ITGMANIA_SOURCE_DIR}/Themes/Simply Love/Scripts/SL-OnlineHelpers.lua")
file(READ "${ONLINE_HELPERS_SOURCE}" ONLINE_HELPERS_TEXT)

set(ONLINE_CLIENT_SOURCE
    "${ITGMANIA_SOURCE_DIR}/Themes/Simply Love/Scripts/SL-ITGOnlineClient.lua")
file(READ "${ONLINE_CLIENT_SOURCE}" ONLINE_CLIENT_TEXT)

foreach(REQUIRED_SNIPPET
    "GetGameplayStartLeadInSeconds"
    "const float startLeadInSeconds = GetGameplayStartLeadInSeconds"
    "p.m_StartSecond = -startLeadInSeconds;"
    "p.m_StartSecond = -onlineSecondsUntilStart;"
    "lead-in %.3fs startSecond=%.3f.")
  string(FIND "${SCREEN_GAMEPLAY_TEXT}" "${REQUIRED_SNIPPET}" SNIPPET_OFFSET)
  if(SNIPPET_OFFSET EQUAL -1)
    message(
        FATAL_ERROR
        "ScreenGameplay invariant failed: missing '${REQUIRED_SNIPPET}'")
  endif()
endforeach()

foreach(REQUIRED_SNIPPET
    "lateBy > 0.03"
    "screen:SeekMusicSeconds(lateBy)"
    "release_online_gameplay_now reason=start_time_reached")
  string(FIND "${ONLINE_HELPERS_TEXT}" "${REQUIRED_SNIPPET}" SNIPPET_OFFSET)
  if(SNIPPET_OFFSET EQUAL -1)
    message(
        FATAL_ERROR
        "ScreenGameplay online helper invariant failed: missing '${REQUIRED_SNIPPET}'")
  endif()
endforeach()

string(FIND "${ONLINE_CLIENT_TEXT}" "and self:SecondsUntilScheduledStart() == nil" NIL_SCHEDULE_HOLD_OFFSET)
if(NOT NIL_SCHEDULE_HOLD_OFFSET EQUAL -1)
  message(
      FATAL_ERROR
      "ScreenGameplay invariant failed: online starting phase must hold gameplay even when a scheduled start is known")
endif()

string(REGEX MATCH
    "if \\(GetITGOnlineShouldHoldGameplayForStart\\(\\)\\)[^{]*\\{[^}]*p\\.m_StartSecond[ \t]*=[ \t]*0\\.0f"
    HOLD_STARTS_AT_ZERO
    "${SCREEN_GAMEPLAY_TEXT}")
if(NOT HOLD_STARTS_AT_ZERO STREQUAL "")
  message(
      FATAL_ERROR
      "ScreenGameplay invariant failed: online start hold must keep the local lead-in instead of starting at 0.0")
endif()
