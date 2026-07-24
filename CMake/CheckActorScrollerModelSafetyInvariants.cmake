if(NOT DEFINED ITGMANIA_SOURCE_DIR)
  message(FATAL_ERROR "ITGMANIA_SOURCE_DIR is required")
endif()

file(READ "${ITGMANIA_SOURCE_DIR}/src/ActorScroller.cpp" scroller_source)
file(READ "${ITGMANIA_SOURCE_DIR}/src/DynamicActorScroller.cpp" dynamic_source)
file(READ "${ITGMANIA_SOURCE_DIR}/src/LuaExpressionTransform.cpp" transform_source)
file(READ "${ITGMANIA_SOURCE_DIR}/src/Model.cpp" model_source)
file(READ "${ITGMANIA_SOURCE_DIR}/src/Model.h" model_header)

function(require_contains content needle label)
  string(FIND "${content}" "${needle}" position)
  if(position EQUAL -1)
    message(FATAL_ERROR
      "Actor scroller/model safety invariant failed: ${label}")
  endif()
endfunction()

require_contains(
  "${scroller_source}"
  "m_iFirstSubActorIndex = 0;"
  "scroller reload resets traversal state")
require_contains(
  "${scroller_source}"
  "if (!transformed || mutationVersion != m_iChildMutationVersion"
  "failed transforms cannot publish stale child state")
require_contains(
  "${dynamic_source}"
  "numItems = std::min(numItems, 1000000.0f);"
  "Lua item count is bounded before integer conversion")
require_contains(
  "${dynamic_source}"
  "const std::vector<Actor*> children = m_SubActors;"
  "dynamic reconfiguration uses a stable child snapshot")
require_contains(
  "${transform_source}"
  "kMaxTransformCacheEntries"
  "Lua transform cache is bounded")
require_contains(
  "${model_header}"
  "Model(const Model& cpy);"
  "Model owns an explicit deep-copy contract")
require_contains(
  "${model_source}"
  "Model staged;"
  "model pieces load transactionally")
require_contains(
  "${model_source}"
  "m_vSourceMeshes = m_pGeometry->m_Meshes;"
  "animated geometry has a private bind-pose copy")
require_contains(
  "${model_source}"
  "pThisPositionKey == nullptr && pLastPositionKey != nullptr"
  "empty position key streams are null safe")
require_contains(
  "${model_source}"
  "SetCullMode(originalCullMode);"
  "cel-shaded rendering restores actor draw state")

message(STATUS "Actor scroller/model safety invariants passed")
