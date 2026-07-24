if(NOT DEFINED ITGMANIA_SOURCE_DIR)
  message(FATAL_ERROR "ITGMANIA_SOURCE_DIR is required")
endif()

file(READ "${ITGMANIA_SOURCE_DIR}/src/Foreground.cpp" foreground_source)
file(READ "${ITGMANIA_SOURCE_DIR}/src/Banner.cpp" banner_source)
file(READ "${ITGMANIA_SOURCE_DIR}/src/FadingBanner.cpp" fading_source)
file(READ "${ITGMANIA_SOURCE_DIR}/src/FadingBanner.h" fading_header)
file(READ "${ITGMANIA_SOURCE_DIR}/src/BeginnerHelper.cpp" beginner_source)

function(require_contains content needle label)
  string(FIND "${content}" "${needle}" position)
  if(position EQUAL -1)
    message(FATAL_ERROR "Visual asset safety invariant failed: ${label}")
  endif()
endfunction()

function(require_not_contains content needle label)
  string(FIND "${content}" "${needle}" position)
  if(NOT position EQUAL -1)
    message(FATAL_ERROR "Visual asset safety invariant failed: ${label}")
  endif()
endfunction()

require_contains(
  "${foreground_source}"
  "RemoveAllChildren();"
  "foreground unload updates ActorFrame child bookkeeping")
require_contains(
  "${foreground_source}"
  "!std::isfinite(change.m_fStartBeat)"
  "foreground changes require finite beats")
require_contains(
  "${foreground_source}"
  "!std::isfinite(tweenTime)"
  "foreground tween timing is validated")
require_contains(
  "${banner_source}"
  "case SORT_SERIES:"
  "series sort has an explicit banner path")
require_contains(
  "${banner_source}"
  "LoadGroupFallback();"
  "group sorts replace stale banner content")
require_contains(
  "${banner_source}"
  "m_bScrolling = false;"
  "banner loads can reset scrolling state")
require_contains(
  "${fading_source}"
  "const bool validWidth"
  "fading banner clipping matches Sprite's contract")
require_contains(
  "${fading_source}"
  "if (banner.HasCommand(sBanner))"
  "custom banner commands are checked before playback")
require_not_contains(
  "${fading_header}"
  "Banner GetBanner("
  "unused unsafe banner copy API is removed")
require_contains(
  "${beginner_source}"
  "if (THEME == nullptr || !CanUse(PLAYER_INVALID))"
  "beginner helper validates theme lifecycle")

message(STATUS "Visual asset safety invariants passed")
