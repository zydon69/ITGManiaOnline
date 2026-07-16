if(NOT DEFINED ITGMANIA_SOURCE_DIR)
  message(FATAL_ERROR "ITGMANIA_SOURCE_DIR is required")
endif()

file(READ "${ITGMANIA_SOURCE_DIR}/src/BGAnimation.cpp" animation_source)
file(READ "${ITGMANIA_SOURCE_DIR}/src/BGAnimationLayer.cpp" layer_source)
file(READ "${ITGMANIA_SOURCE_DIR}/src/BGAnimationLayer.h" layer_header)

function(require_contains content needle label)
  string(FIND "${content}" "${needle}" position)
  if(position EQUAL -1)
    message(FATAL_ERROR "BGAnimation revalidation invariant failed: ${label}")
  endif()
endfunction()

function(require_not_contains content needle label)
  string(FIND "${content}" "${needle}" position)
  if(NOT position EQUAL -1)
    message(FATAL_ERROR "BGAnimation revalidation invariant failed: ${label}")
  endif()
endfunction()

require_contains(
  "${animation_source}"
  "MAX_BG_ANIMATION_IMPORT_DEPTH"
  "animation imports have a depth ceiling")
require_contains(
  "${animation_source}"
  "ParseLayerNumber"
  "layer names use strict numeric parsing")
require_contains(
  "${animation_source}"
  "BGAnimation skipped empty layer"
  "failed or conditional layers are not published")
require_contains(
  "${layer_source}"
  "void BGAnimationLayer::ResetLayerState()"
  "layer reloads clear prior state")
require_contains(
  "${layer_source}"
  "SafeGridCount"
  "tile counts are bounded before integer conversion")
require_contains(
  "${layer_source}"
  "tile grid after actor %u of %u failed to load"
  "partial tile grids are rejected atomically")
require_contains(
  "${layer_source}"
  "spriteArea > static_cast<double>(std::numeric_limits<int>::max())"
  "particle area conversion is bounded")
require_not_contains(
  "${layer_header}"
  "GetMaxTweenTimeLeft"
  "dead undefined tween declaration is removed")
require_contains(
  "${layer_source}"
  "dynamic_cast<Sprite*>"
  "sprite-only texture scrolling validates actor type")
require_contains(
  "${layer_source}"
  "i >= m_vParticleVelocity.size()"
  "particle updates validate velocity alignment")
require_contains(
  "${layer_source}"
  "expectedTiles"
  "tile updates validate actor cardinality")
require_not_contains(
  "${layer_source}"
  "FAIL_M(\"Invalid BGA"
  "invalid animation enums do not terminate the game")

message(STATUS "BGAnimation revalidation invariants passed")
