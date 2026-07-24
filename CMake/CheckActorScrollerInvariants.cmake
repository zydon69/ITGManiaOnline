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

read_source("src/ActorScroller.cpp" actor_scroller_cpp)
read_source("src/ActorScroller.h" actor_scroller_h)
read_source("src/DynamicActorScroller.cpp" dynamic_scroller_cpp)
read_source("src/DynamicActorScroller.h" dynamic_scroller_h)

require_contains(
  "${actor_scroller_h}"
  "void UpdateInternal(float fDelta) override;"
  "ActorScroller update contract declares override")
require_contains(
  "${actor_scroller_h}"
  "void DrawPrimitives() override;"
  "ActorScroller draw contract declares override")
require_contains(
  "${actor_scroller_h}"
  "void LoadFromNode(const XNode* pNode) override;"
  "ActorScroller load contract declares override")
require_contains(
  "${actor_scroller_h}"
  "ActorScroller* Copy() const override;"
  "ActorScroller copy contract declares override")
require_contains(
  "${actor_scroller_h}"
  "void AddChild(Actor* pActor) override;"
  "ActorScroller child add keeps item count synchronized")
require_contains(
  "${actor_scroller_h}"
  "void RemoveChild(Actor* pActor) override;"
  "ActorScroller child remove keeps item count synchronized")
require_contains(
  "${actor_scroller_h}"
  "void PushSelf(lua_State* L) override;"
  "ActorScroller Lua binding contract declares override")

require_contains(
  "${actor_scroller_cpp}"
  "float ActorScroller::ClampItemIndex(float fItemIndex) const"
  "ActorScroller clamps public item indexes")
require_contains(
  "${actor_scroller_cpp}"
  "m_fDestinationItem = ClampItemIndex(fItemIndex);"
  "ActorScroller clamps destination item")
require_contains(
  "${actor_scroller_cpp}"
  "m_fCurrentItem = m_fDestinationItem = ClampItemIndex(fItemIndex);"
  "ActorScroller clamps current and destination item together")
require_contains(
  "${actor_scroller_cpp}"
  "int SafeCeilToInt(float value, int fallback)"
  "ActorScroller converts draw bounds to int safely")
require_contains(
  "${actor_scroller_cpp}"
  "int iFirstItemToDraw = SafeCeilToInt(fFirstItemToDraw, 0);"
  "ActorScroller uses safe first draw index conversion")
require_contains(
  "${actor_scroller_cpp}"
  "int iLastItemToDraw = SafeCeilToInt(fLastItemToDraw, iFirstItemToDraw);"
  "ActorScroller uses safe last draw index conversion")
require_contains(
  "${actor_scroller_cpp}"
  "int ActorScroller::NormalizeShiftDistance(int iDist) const"
  "ActorScroller normalizes shift distance")
require_contains(
  "${actor_scroller_cpp}"
  "const int normalized = NormalizeShiftDistance(iDist);"
  "ActorScroller shifts through normalized distance")
require_contains(
  "${actor_scroller_cpp}"
  "std::rotate("
  "ActorScroller uses bounded rotate instead of repeated erase/insert")
require_not_contains(
  "${actor_scroller_cpp}"
  "CircularShift(m_SubActors, iDist);"
  "ActorScroller must not call unbounded CircularShift directly")

require_contains(
  "${actor_scroller_cpp}"
  "void ActorScroller::ResetScrollerLoadState()"
  "ActorScroller resets optional load state before reload")
require_contains(
  "${actor_scroller_cpp}"
  "ResetScrollerLoadState();"
  "ActorScroller reset runs during XML load")
require_contains(
  "${actor_scroller_cpp}"
  "DisableMask();"
  "ActorScroller clears stale mask state")
require_contains(
  "${actor_scroller_cpp}"
  "SetTransformFromReference(nilReference);"
  "ActorScroller clears stale transform function")
require_contains(
  "${actor_scroller_cpp}"
  "SetLoop(bLoop);"
  "ActorScroller XML loop goes through exclusive setter")
require_contains(
  "${actor_scroller_cpp}"
  "SetWrap(bWrap);"
  "ActorScroller XML wrap goes through exclusive setter")
require_contains(
  "${actor_scroller_cpp}"
  "m_bWrap = false;"
  "ActorScroller loop disables wrap")
require_contains(
  "${actor_scroller_cpp}"
  "m_bLoop = false;"
  "ActorScroller wrap disables loop")

require_contains(
  "${actor_scroller_cpp}"
  "m_bFunctionDependsOnPositionOffset = true;"
  "ActorScroller assumes transform depends on position")
require_contains(
  "${actor_scroller_cpp}"
  "m_bFunctionDependsOnItemIndex = true;"
  "ActorScroller assumes transform depends on item index")
require_not_contains(
  "${actor_scroller_cpp}"
  "#define GP"
  "ActorScroller transform dependency detection must not use local macro")
require_not_contains(
  "${actor_scroller_cpp}"
  "PositiveFiniteOrScroller"
  "ActorScroller must not retain dead helper")

require_contains(
  "${dynamic_scroller_h}"
  "DynamicActorScroller* Copy() const override;"
  "DynamicActorScroller copy contract declares override")
require_contains(
  "${dynamic_scroller_h}"
  "void LoadFromNode(const XNode* pNode) override;"
  "DynamicActorScroller load contract declares override")
require_contains(
  "${dynamic_scroller_h}"
  "void ShiftSubActors(int iDist) override;"
  "DynamicActorScroller shift contract declares override")
require_contains(
  "${dynamic_scroller_h}"
  "bool SyncItemCountWithChildren() const override { return false; }"
  "DynamicActorScroller opts out of child-count synchronization")
require_contains(
  "${dynamic_scroller_h}"
  "bool AutoLoadChildren() const override { return true; }"
  "DynamicActorScroller auto-load contract declares override")

require_contains(
  "${dynamic_scroller_cpp}"
  "m_LoadFunction.SetFromStack(L);"
  "DynamicActorScroller reads LoadFunction before copy creation")
string(FIND "${dynamic_scroller_cpp}" "m_LoadFunction.SetFromStack(L);" load_fn_at)
string(FIND "${dynamic_scroller_cpp}" "int iNumCopies =" copy_count_at)
if(load_fn_at EQUAL -1 OR copy_count_at EQUAL -1 OR NOT load_fn_at LESS copy_count_at)
  message(FATAL_ERROR "Missing invariant: DynamicActorScroller validates LoadFunction before allocating visible copies")
endif()
require_contains(
  "${dynamic_scroller_cpp}"
  "const bool bReconfigureAll = iDist == INT_MAX;"
  "DynamicActorScroller reconfigures every visible actor on forced refresh")
require_contains(
  "${dynamic_scroller_cpp}"
  "lua_pushnumber(L, iItem);"
  "DynamicActorScroller publishes logical item index")
require_not_contains(
  "${dynamic_scroller_cpp}"
  "lua_pushnumber(L, i);"
  "DynamicActorScroller must not publish visible slot as ItemIndex")
require_contains(
  "${dynamic_scroller_cpp}"
  "const bool ok ="
  "DynamicActorScroller records LoadFunction execution result")
require_contains(
  "${dynamic_scroller_cpp}"
  "pActor->SetVisible(false);"
  "DynamicActorScroller hides stale content on configure failure")
