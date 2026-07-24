if(NOT DEFINED ITGMANIA_SOURCE_DIR)
  message(FATAL_ERROR "ITGMANIA_SOURCE_DIR is required")
endif()

file(READ "${ITGMANIA_SOURCE_DIR}/src/BackgroundUtil.cpp" util_source)
file(READ "${ITGMANIA_SOURCE_DIR}/src/Background.cpp" background_source)

function(require_contains content needle label)
  string(FIND "${content}" "${needle}" position)
  if(position EQUAL -1)
    message(FATAL_ERROR "Background safety invariant failed: ${label}")
  endif()
endfunction()

function(require_not_contains content needle label)
  string(FIND "${content}" "${needle}" position)
  if(NOT position EQUAL -1)
    message(FATAL_ERROR "Background safety invariant failed: ${label}")
  endif()
endfunction()

require_contains(
  "${util_source}"
  "removed %zu BGChange(s) with non-finite start"
  "non-finite background changes are removed before sorting")
require_contains(
  "${util_source}"
  "rejected BGChange with non-finite start beat"
  "non-finite background changes are rejected on insertion")
require_contains(
  "${util_source}"
  "static bool HasBackgroundFileManager"
  "background asset listings validate the file manager")
require_contains(
  "${background_source}"
  "m_fLastMusicSeconds = -9999.0f;"
  "background time state is initialized")
require_not_contains(
  "${background_source}"
  "pActor = new Actor;"
  "failed effect actors are not published as successful blank backgrounds")
require_contains(
  "${background_source}"
  "const int requestedCount = std::max(0"
  "negative random background counts are clamped")
require_contains(
  "${background_source}"
  "rawStepRows > static_cast<double>(std::numeric_limits<int>::max())"
  "random background row conversion is bounded before rounding")
require_contains(
  "${background_source}"
  "const int64_t rowDelta"
  "background BPM row subtraction cannot overflow signed int")
require_contains(
  "${background_source}"
  "std::remove_if("
  "empty background changes are removed without unsigned index underflow")

message(STATUS "Background safety invariants passed")
