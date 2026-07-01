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

read_source("src/LuaExpressionTransform.h" lua_expression_transform_h)
read_source("src/LuaExpressionTransform.cpp" lua_expression_transform_cpp)
read_source("src/ScreenOptions.cpp" screen_options_cpp)
read_source("src/StreamDisplay.cpp" stream_display_cpp)
read_source("src/WheelBase.cpp" wheel_base_cpp)

require_contains(
  "${lua_expression_transform_h}"
  "bool TransformItemCached("
  "cached transforms report failure to callers")
require_contains(
  "${lua_expression_transform_h}"
  "bool TransformItemDirect("
  "direct transforms report Lua execution failure")
require_contains(
  "${lua_expression_transform_h}"
  "Actor::TweenState& tweenStateOut) const;"
  "cached transform state is returned only after success")

require_contains(
  "${lua_expression_transform_cpp}"
  "const bool bSuccess = LuaHelpers::RunScriptOnStack"
  "Lua execution success is captured")
require_contains(
  "${lua_expression_transform_cpp}"
  "SRC_AUDIT_FIX SRC-2665"
  "failed cache entries are skipped")
require_not_contains(
  "${lua_expression_transform_cpp}"
  "return m_mapPositionToTweenStateCache[key] = a.DestTweenState();"
  "failed transforms must not be cached as valid")
require_not_contains(
  "${lua_expression_transform_cpp}"
  "NormalizeOffsetForCache(fPositionOffsetFromCenter)"
  "SRC-2667 remains excluded from this one-entry reintroduction")
require_contains(
  "${lua_expression_transform_cpp}"
  "SRC_AUDIT_FIX SRC-2668"
  "non-nil Lua references are rejected when the Lua manager is unavailable")
require_contains(
  "${lua_expression_transform_cpp}"
  "m_exprTransformFunction.SetFromNil();"
  "LuaExpressionTransform falls back to nil after rejecting an unsafe reference")
require_contains(
  "${lua_expression_transform_h}"
  "int iNumItems;"
  "SRC-2666 includes item count in cache key")
require_contains(
  "${lua_expression_transform_h}"
  "return iNumItems < other.iNumItems;"
  "SRC-2666 orders item count in cache key")
require_contains(
  "${wheel_base_cpp}"
  "if (!m_exprItemTransformFunction.GetTransformCached("
  "WheelBase handles cached transform failure")
require_contains(
  "${wheel_base_cpp}"
  "item.SetVisible(false);"
  "WheelBase hides items when transform cache fails")
require_contains(
  "${wheel_base_cpp}"
  "item.SetVisible(true);"
  "WheelBase restores item visibility after transform cache success")
require_contains(
  "${screen_options_cpp}"
  "const bool bTransformOk ="
  "ScreenOptions handles cached transform failure")
require_contains(
  "${stream_display_cpp}"
  "if (!m_transformPill.TransformItemDirect("
  "StreamDisplay handles direct transform failure")
