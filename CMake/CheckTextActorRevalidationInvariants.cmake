if(NOT DEFINED ITGMANIA_SOURCE_DIR)
  message(FATAL_ERROR "ITGMANIA_SOURCE_DIR is required")
endif()

file(READ "${ITGMANIA_SOURCE_DIR}/src/BeginnerHelper.cpp" beginner_source)
file(READ "${ITGMANIA_SOURCE_DIR}/src/BitmapText.cpp" bitmap_source)
file(READ "${ITGMANIA_SOURCE_DIR}/src/BitmapText.h" bitmap_header)
file(READ "${ITGMANIA_SOURCE_DIR}/src/Actor.cpp" actor_source)
file(READ "${ITGMANIA_SOURCE_DIR}/src/Actor.h" actor_header)

function(require_contains content needle label)
  string(FIND "${content}" "${needle}" position)
  if(position EQUAL -1)
    message(FATAL_ERROR "Text/actor revalidation invariant failed: ${label}")
  endif()
endfunction()

function(require_not_contains content needle label)
  string(FIND "${content}" "${needle}" position)
  if(NOT position EQUAL -1)
    message(FATAL_ERROR "Text/actor revalidation invariant failed: ${label}")
  endif()
endfunction()

require_contains(
  "${beginner_source}"
  "const bool animationsLoaded ="
  "beginner helper requires every dancer animation")
require_contains(
  "${beginner_source}"
  "const float secondsPerBeat = 1.0f / bps;"
  "beginner helper converts BPS to seconds per beat")
require_not_contains(
  "${beginner_source}"
  "m_sStepCircle[scu][scue].Update(beat);"
  "step circles are not updated twice")
require_contains(
  "${bitmap_header}"
  "std::string m_sSourceText;"
  "bitmap text preserves its untransformed source")
require_contains(
  "${bitmap_source}"
  "SetText(m_sSourceText, m_sAlternateText, m_iWrapWidthPixels);"
  "uppercase toggles rebuild from source text")
require_contains(
  "${bitmap_source}"
  "m_vpFontPageTextures.clear();"
  "bitmap copies rebuild font-owned page pointers")
require_contains(
  "${bitmap_source}"
  "luaLength > std::numeric_limits<int>::max()"
  "Lua attribute lengths are narrowed safely")
require_contains(
  "${actor_header}"
  "SetRotationX(GetRotationX() + rot);"
  "additive rotations sanitize the resulting value")
require_contains(
  "${actor_source}"
  "timeLeft > std::numeric_limits<float>::max()"
  "tween hurry multiplication rejects overflow")
require_contains(
  "${actor_source}"
  "static_cast<double>(m_fSecsIntoEffect) + delta_time"
  "effect timer wraps without float addition overflow")

message(STATUS "Text/actor revalidation invariants passed")
