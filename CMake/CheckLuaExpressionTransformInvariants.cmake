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
read_source("src/MusicWheelItem.cpp" music_wheel_item_cpp)
read_source("src/ScreenSelectMusic.cpp" screen_select_music_cpp)
read_source("src/Banner.cpp" banner_cpp)
read_source("src/FadingBanner.cpp" fading_banner_cpp)
read_source("src/TextBanner.cpp" text_banner_cpp)

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
  "${wheel_base_cpp}"
  "m_fPositionOffsetFromSelection += iDist;\n\n  RebuildWheelItems(iDist);"
  "WheelBase applies visual offset before rebuilding focused items")
require_contains(
  "${music_wheel_cpp}"
  "int MusicWheel::GetVisualFocusIndex() const"
  "MusicWheel centralizes visual focus selection reads")
require_contains(
  "${wheel_base_cpp}"
  "int WheelBase::GetVisualFocusIndex() const"
  "WheelBase centralizes visual focus selection reads")
require_contains(
  "${wheel_base_cpp}"
  "int WheelBase::GetVisualFocusDrawIndex(int itemCount) const"
  "WheelBase centralizes rendered focus slot calculation")
require_contains(
  "${wheel_base_cpp}"
  "std::lround(centerDrawIndex - offsetFromSelection)"
  "WheelBase rendered focus follows the actor closest to the visual center")
require_contains(
  "${wheel_base_cpp}"
  "void WheelBase::ApplyWheelItemDrawOrder(int itemCount)"
  "WheelBase centralizes rendered wheel draw order")
require_contains(
  "${wheel_base_cpp}"
  "const int drawOrder = -std::abs(i - focusDrawIndex);"
  "WheelBase draws items closest to visual focus above recycled neighbors")
require_contains(
  "${wheel_base_cpp}"
  "ApplyWheelItemDrawOrder(displayCount);"
  "WheelBase refreshes draw order after positioning wheel items")
require_contains(
  "${music_wheel_cpp}"
  "return WheelBase::GetVisualFocusIndex();"
  "MusicWheel delegates visual focus calculation to WheelBase")
require_contains(
  "${music_wheel_cpp}"
  "m_fPositionOffsetFromSelection += iDist;\n\n  if (REMIND_WHEEL_POSITIONS"
  "MusicWheel applies visual offset before rebuilding focused items")
require_contains(
  "${music_wheel_cpp}"
  "const MusicWheelItemData* selected = GetVisualFocusItemData();"
  "MusicWheel selected song follows visual focus")
require_contains(
  "${music_wheel_cpp}"
  "const MusicWheelItemData* item = GetVisualFocusItemData();"
  "MusicWheel selected metadata follows visual focus")
require_contains(
  "${music_wheel_cpp}"
  "void MusicWheel::PostSongChangedIfVisualFocusChanged()"
  "MusicWheel emits song changed when animated visual focus changes")
require_contains(
  "${music_wheel_cpp}"
  "m_iLastPostedVisualFocusIndex = focusedIndex;"
  "MusicWheel records the last announced visual focus")
require_contains(
  "${music_wheel_cpp}"
  "PostSongChangedIfVisualFocusChanged();"
  "MusicWheel checks visual focus changes during update")
require_contains(
  "${music_wheel_cpp}"
  "SRC-2693 MusicWheelTrace change_music"
  "MusicWheel logs selection and focus transitions")
require_contains(
  "${music_wheel_cpp}"
  "SRC-2693 MusicWheelTrace change_music_focus_unchanged"
  "MusicWheel does not notify when only logical selection changed")
require_not_contains(
  "${music_wheel_cpp}"
  "reason=change_music focus="
  "MusicWheel must not post song changed before visual focus changes")
require_contains(
  "${wheel_base_cpp}"
  "SRC-2693 MusicWheelTrace wheelbase_move_accept"
  "WheelBase logs accepted wheel movement")
require_contains(
  "${music_wheel_item_cpp}"
  "SRC-2693 MusicWheelTrace item_load"
  "MusicWheelItem logs rendered wheel item data")
require_contains(
  "${screen_select_music_cpp}"
  "SRC-2693 MusicWheelTrace after_music_change_end"
  "ScreenSelectMusic logs applied banner and sample state")
require_contains(
  "${screen_select_music_cpp}"
  "SRC-2693 MusicWheelTrace input_event"
  "ScreenSelectMusic logs raw select-music input state")
require_contains(
  "${screen_select_music_cpp}"
  "SRC-2693 MusicWheelTrace handle_screen_message_begin"
  "ScreenSelectMusic logs screen-message entry state")
require_contains(
  "${wheel_base_cpp}"
  "SRC-2693 MusicWheelTrace rebuild_load_slot"
  "WheelBase logs rebuilt visual wheel slots")
require_contains(
  "${wheel_base_cpp}"
  "const bool hasVisualFocus = i == visualFocusDrawIndex;"
  "WheelBase marks only one rendered actor as focused during rebuild")
require_contains(
  "${wheel_base_cpp}"
  "pDisplay->LoadFromWheelItemData(pData, iIndex, hasVisualFocus, i);"
  "WheelBase passes rendered focus into rebuilt wheel items")
require_contains(
  "${banner_cpp}"
  "SRC-2693 MusicWheelTrace banner_cached_begin"
  "Banner logs cached visual asset resolution")
require_contains(
  "${fading_banner_cpp}"
  "SRC-2693 MusicWheelTrace fading_banner_cached_begin"
  "FadingBanner logs cached visual asset resolution")
require_contains(
  "${text_banner_cpp}"
  "SRC-2693 MusicWheelTrace text_banner_set_song"
  "TextBanner logs rendered song text")
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
