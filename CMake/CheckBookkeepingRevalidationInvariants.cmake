if(NOT DEFINED ITGMANIA_SOURCE_DIR)
  message(FATAL_ERROR "ITGMANIA_SOURCE_DIR is required")
endif()

function(require_contains file needle description)
  file(READ "${ITGMANIA_SOURCE_DIR}/${file}" contents)
  string(FIND "${contents}" "${needle}" position)
  if(position EQUAL -1)
    message(FATAL_ERROR "${description}: '${needle}' missing from ${file}")
  endif()
endfunction()

require_contains(
  "src/ScreenBookkeeping.cpp"
  "m_vBookkeepingViews.clear();"
  "Repeated bookkeeping initialization must rebuild the enabled view list")
require_contains(
  "src/ScreenBookkeeping.cpp"
  "m_bDataLoaded.fill(false);"
  "Repeated bookkeeping initialization must clear stale actor readiness")
require_contains(
  "src/ScreenBookkeeping.cpp"
  "static std::unordered_set<std::string> emittedWarnings;"
  "Recoverable bookkeeping warnings must be deduplicated")
require_contains(
  "src/ScreenBookkeeping.cpp"
  "SaturatingAdd("
  "Bookkeeping totals must not overflow signed integers")
require_contains(
  "src/ScreenBookkeeping.cpp"
  "if (m_vBookkeepingViews.empty())"
  "Bookkeeping must support a theme with no enabled views")
require_contains(
  "src/ScreenAttract.cpp"
  "GetLoadedBoolMetric(ATTRACT_VOLUME, false)"
  "Attract volume must tolerate an unloaded theme metric")
require_contains(
  "src/ScreenAttract.cpp"
  "pScreen->PostScreenMessage(SM_BeginFadingOut, 0);"
  "Attract navigation must target the supplied screen")

message(STATUS "Bookkeeping revalidation invariants passed")
