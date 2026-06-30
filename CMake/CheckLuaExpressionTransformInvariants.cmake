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
read_source("src/ActorScroller.cpp" actor_scroller_cpp)
read_source("src/ScreenOptions.cpp" screen_options_cpp)
read_source("src/StreamDisplay.cpp" stream_display_cpp)
read_source("src/WheelBase.cpp" wheel_base_cpp)
read_source("src/MusicWheel.cpp" music_wheel_cpp)

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
  "${lua_expression_transform_h}"
  "int iNumItems;"
  "cache key includes item count")
require_contains(
  "${lua_expression_transform_h}"
  "return iNumItems < other.iNumItems;"
  "cache key orders item count")
require_contains(
  "${lua_expression_transform_h}"
  "float NormalizeOffsetForCache(float fPositionOffsetFromCenter) const;"
  "public cached offsets are normalized before lookup")

require_contains(
  "${lua_expression_transform_cpp}"
  "bool SanitizeTransformArgs("
  "transform arguments are sanitized before use")
require_contains(
  "${lua_expression_transform_cpp}"
  "NormalizeOffsetForCache(fPositionOffsetFromCenter)"
  "public cache lookup normalizes offsets")
require_contains(
  "${lua_expression_transform_cpp}"
  "std::clamp(m_iNumSubdivisions, 1, 1024)"
  "cache normalization bounds subdivisions")
require_contains(
  "${lua_expression_transform_cpp}"
  "return Quantize(fPositionOffsetFromCenter, fInterval);"
  "cache normalization quantizes offsets")
require_contains(
  "${lua_expression_transform_cpp}"
  "SRC_AUDIT_FIX SRC-2668"
  "SetFromReference guards non-nil references without LUA")
require_contains(
  "${lua_expression_transform_cpp}"
  "m_exprTransformFunction.SetFromNil();"
  "invalid Lua references are cleared")
require_contains(
  "${lua_expression_transform_cpp}"
  "const bool bSuccess = LuaHelpers::RunScriptOnStack"
  "Lua execution success is captured")
require_contains(
  "${lua_expression_transform_cpp}"
  "a.DestTweenState() = originalTweenState;"
  "failed direct transforms restore tween state")
require_contains(
  "${lua_expression_transform_cpp}"
  "a.SetVisible(bOriginalVisible);"
  "failed direct transforms restore visibility")
require_contains(
  "${lua_expression_transform_cpp}"
  "SRC_AUDIT_FIX SRC-2669"
  "failed direct transform restoration is logged")
require_contains(
  "${lua_expression_transform_cpp}"
  "SRC_AUDIT_FIX SRC-2665"
  "failed cache entries are skipped")
require_not_contains(
  "${lua_expression_transform_cpp}"
  "return m_mapPositionToTweenStateCache[key] = a.DestTweenState();"
  "failed transforms must not be cached as valid")

require_contains(
  "${wheel_base_cpp}"
  "m_exprItemTransformFunction.ClearCache();"
  "WheelBase clears transform cache when rebuilding wheel items")
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
  "${wheel_base_cpp}"
  "bool WheelBase::SettleSelectionOnFocusedItem()"
  "WheelBase centralizes visual focus settling before selection")
require_contains(
  "${wheel_base_cpp}"
  "std::lround(m_fPositionOffsetFromSelection)"
  "WheelBase selects the item closest to visual focus")
require_contains(
  "${wheel_base_cpp}"
  "SettleSelectionOnFocusedItem();"
  "WheelBase settles visual focus before accepting selection")
require_contains(
  "${wheel_base_cpp}"
  "m_fPositionOffsetFromSelection = 0.0f;"
  "WheelBase clears visual offset before selection")
require_contains(
  "${music_wheel_cpp}"
  "int MusicWheel::GetVisualFocusIndex() const"
  "MusicWheel centralizes visual focus selection reads")
require_contains(
  "${music_wheel_cpp}"
  "std::lround(m_fPositionOffsetFromSelection)"
  "MusicWheel reads the item closest to visual focus")
require_contains(
  "${music_wheel_cpp}"
  "const MusicWheelItemData* selected = GetVisualFocusItemData();"
  "MusicWheel selected song follows visual focus")
require_contains(
  "${music_wheel_cpp}"
  "const MusicWheelItemData* item = GetVisualFocusItemData();"
  "MusicWheel selected metadata follows visual focus")
require_contains(
  "${screen_options_cpp}"
  "const bool bTransformOk ="
  "ScreenOptions captures transform cache failure")
require_contains(
  "${screen_options_cpp}"
  "if (!bTransformOk) {"
  "ScreenOptions branches on transform failure")
require_contains(
  "${stream_display_cpp}"
  "if (!m_transformPill.TransformItemDirect("
  "StreamDisplay handles direct transform failure")
require_contains(
  "${actor_scroller_cpp}"
  "const bool bTopMaskTransformOk ="
  "ActorScroller handles top mask transform failure")
require_contains(
  "${actor_scroller_cpp}"
  "const bool bBottomMaskTransformOk ="
  "ActorScroller handles bottom mask transform failure")
require_contains(
  "${actor_scroller_cpp}"
  "const bool bTransformOk = m_exprTransformFunction.TransformItemCached("
  "ActorScroller handles child transform failure")
