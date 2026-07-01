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
require_not_contains(
  "${wheel_base_cpp}"
  "bool WheelBase::SettleSelectionOnFocusedItem()"
  "WheelBase restored source selection behavior without visual focus settling")
require_not_contains(
  "${wheel_base_cpp}"
  "wheelbase_move_settle_before_accept"
  "WheelBase restored source move acceptance behavior")
require_not_contains(
  "${wheel_base_cpp}"
  "focus_state_update"
  "WheelBase restored source rebuild-only focus state")
require_not_contains(
  "${wheel_base_cpp}"
  "FOCUS_BLEED_OCCLUSION_RADIUS"
  "WheelBase restored source visibility behavior without focus-band occlusion")
require_not_contains(
  "${music_wheel_cpp}"
  "post_sm_song_changed_deferred"
  "MusicWheel restored immediate source song-change notification behavior")
require_not_contains(
  "${screen_select_music_cpp}"
  "screen_song_changed_deferred"
  "ScreenSelectMusic restored immediate source song-change handling")
require_contains(
  "${wheel_base_cpp}"
  "m_fPositionOffsetFromSelection = 0;"
  "WheelBase initializes visual offset before first positioning")
require_contains(
  "${wheel_base_cpp}"
  "m_WheelState = STATE_SELECTING;"
  "WheelBase initializes wheel state before initial positioning")
require_contains(
  "${wheel_base_cpp}"
  "const char* WheelStateToTraceString(WheelState state)"
  "WheelBase traces wheel state without assertive enum conversion")
require_not_contains(
  "${wheel_base_cpp}"
  "WheelStateToString(m_WheelState)"
  "WheelBase traces must not crash on an invalid or not-yet-initialized wheel state")
require_contains(
  "${wheel_base_cpp}"
  "RebuildWheelItems(iDist);\n\n  m_fPositionOffsetFromSelection += iDist;"
  "WheelBase restores source order by rebuilding before applying visual offset")
require_contains(
  "${music_wheel_cpp}"
  "int MusicWheel::GetVisualFocusIndex() const"
  "MusicWheel keeps a compatibility alias for focus traces")
require_contains(
  "${wheel_base_cpp}"
  "int WheelBase::GetVisualFocusIndex() const"
  "WheelBase keeps a compatibility alias for focus traces")
require_not_contains(
  "${wheel_base_cpp}"
  "int WheelBase::GetVisualFocusDrawIndex(int itemCount) const"
  "WheelBase restored source static draw-slot behavior")
require_not_contains(
  "${wheel_base_cpp}"
  "void WheelBase::ApplyWheelItemDrawOrder(int itemCount)"
  "WheelBase restored source child draw order")
require_not_contains(
  "${wheel_base_cpp}"
  "ApplyWheelItemDrawOrder(displayCount);"
  "WheelBase restored source positioning without dynamic draw order")
require_not_contains(
  "${wheel_base_cpp}"
  "set_positions_focus_window slot=%d"
  "WheelBase removed focus-window instrumentation tied to the reverted occlusion model")
require_contains(
  "${music_wheel_cpp}"
  "return WheelBase::GetVisualFocusIndex();"
  "MusicWheel delegates compatibility focus traces to WheelBase")
require_contains(
  "${music_wheel_cpp}"
  "RebuildWheelItems(iDist);\n\n  m_fPositionOffsetFromSelection += iDist;"
  "MusicWheel restores source order by rebuilding before applying visual offset")
require_not_contains(
  "${music_wheel_cpp}"
  "GetVisualFocusItemData()"
  "MusicWheel selected metadata follows the source logical selection")
require_not_contains(
  "${music_wheel_cpp}"
  "void MusicWheel::PostSongChangedIfVisualFocusChanged()"
  "MusicWheel restored source notification behavior without visual-focus polling")
require_not_contains(
  "${music_wheel_cpp}"
  "PostSongChangedIfVisualFocusChanged();"
  "MusicWheel update no longer emits visual-focus notifications")
require_contains(
  "${music_wheel_cpp}"
  "SRC-2693 MusicWheelTrace change_music"
  "MusicWheel logs selection and focus transitions")
require_contains(
  "${music_wheel_cpp}"
  "SCREENMAN->PostMessageToTopScreen(SM_SongChanged, 0);"
  "MusicWheel restored source immediate song-change notification")
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
  "const bool hasFocus = m_iSelection == iIndex;"
  "WheelBase restored source logical selection focus during rebuild")
require_contains(
  "${wheel_base_cpp}"
  "pDisplay->LoadFromWheelItemData(pData, iIndex, hasFocus, i);"
  "WheelBase passes logical selection focus into rebuilt wheel items")
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
