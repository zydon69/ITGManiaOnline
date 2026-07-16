set(timing_cpp "${ITGMANIA_SOURCE_DIR}/src/TimingData.cpp")
set(segments_h "${ITGMANIA_SOURCE_DIR}/src/TimingSegments.h")

foreach(path IN ITEMS "${timing_cpp}" "${segments_h}")
  if(NOT EXISTS "${path}")
    message(FATAL_ERROR "Missing timing source: ${path}")
  endif()
endforeach()

file(READ "${timing_cpp}" timing_source)
file(READ "${segments_h}" segment_source)

function(require_contains content needle label)
  string(FIND "${content}" "${needle}" position)
  if(position EQUAL -1)
    message(FATAL_ERROR "Timing core invariant failed: ${label}")
  endif()
endfunction()

function(require_not_contains content needle label)
  string(FIND "${content}" "${needle}" position)
  if(NOT position EQUAL -1)
    message(FATAL_ERROR "Timing core invariant failed: ${label}")
  endif()
endfunction()

require_contains(
  "${timing_source}"
  "if (event_type == NOT_FOUND)"
  "elapsed-time conversion terminates when no event remains")
require_contains(
  "${timing_source}"
  "iEndSegment == INVALID_INDEX ? nullptr : segs[iEndSegment]"
  "row deletion mutates only owned timing segments")
require_contains(
  "${timing_source}"
  "iRowsToDelete > MAX_NOTE_ROW - iStartRow"
  "row deletion rejects overflowing ranges")
require_contains(
  "${timing_source}"
  "scaledLength > MAX_NOTE_ROW - iStartIndex"
  "region scaling rejects overflowing output ranges")
require_contains(
  "${timing_source}"
  "using 4/4 fallback for measure conversion"
  "empty timing data has a non-fatal measure fallback")
require_not_contains(
  "${timing_source}"
  "FAIL_M(\"Failed to get measure and beat for note row\")"
  "measure conversion no longer aborts the process")
require_contains(
  "${segment_source}"
  "std::clamp<int64_t>(rows, 1, std::numeric_limits<int>::max())"
  "time-signature row arithmetic is widened and bounded")

message(STATUS "Timing core revalidation invariants passed")
