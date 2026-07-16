if(NOT DEFINED ITGMANIA_SOURCE_DIR)
  message(FATAL_ERROR "ITGMANIA_SOURCE_DIR is required")
endif()

set(note_util "${ITGMANIA_SOURCE_DIR}/src/NoteDataUtil.cpp")
set(note_types_h "${ITGMANIA_SOURCE_DIR}/src/NoteTypes.h")
set(note_types_cpp "${ITGMANIA_SOURCE_DIR}/src/NoteTypes.cpp")

foreach(path IN ITEMS "${note_util}" "${note_types_h}" "${note_types_cpp}")
  if(NOT EXISTS "${path}")
    message(FATAL_ERROR "Missing NoteData utility source: ${path}")
  endif()
endforeach()

file(READ "${note_util}" note_util_source)
file(READ "${note_types_h}" note_types_header)
file(READ "${note_types_cpp}" note_types_source)

function(require_contains content needle label)
  string(FIND "${content}" "${needle}" position)
  if(position EQUAL -1)
    message(FATAL_ERROR "NoteData utility invariant failed: ${label}")
  endif()
endfunction()

function(require_not_contains content needle label)
  string(FIND "${content}" "${needle}" position)
  if(NOT position EQUAL -1)
    message(FATAL_ERROR "NoteData utility invariant failed: ${label}")
  endif()
endfunction()

require_contains(
  "${note_util_source}"
  "static bool CheckedHoldEndRow("
  "hold-end arithmetic is centralized and checked")
require_contains(
  "${note_util_source}"
  "sSMNoteData_.size() > size_t(std::numeric_limits<int>::max())"
  "the legacy SM parser refuses impossible int-sized slices")
require_contains(
  "${note_util_source}"
  "SM serialization replaced invalid tap type"
  "malformed notes cannot terminate SM serialization")
require_contains(
  "${note_util_source}"
  "GetTrackMapping kept identity for invalid mapping"
  "invalid transform mappings retain a safe identity mapping")
require_contains(
  "${note_util_source}"
  "int64_t end = std::min<int64_t>("
  "hold-tick iteration cannot overflow its exclusive end row")
require_contains(
  "${note_util_source}"
  "static bool GetScaledRow("
  "regional scaling reports overflow instead of returning a wrapped row")
require_not_contains(
  "${note_util_source}"
  "FAIL_M(ssprintf(\"Invalid tap note subtype:"
  "SM serialization has no fatal malformed-subtype path")
require_contains(
  "${note_types_header}"
  "*this = TapNote();"
  "TapNote Init resets results and all payload fields")
require_not_contains(
  "${note_types_source}"
  "FAIL_M(ssprintf(\"Unrecognized note type:"
  "invalid NoteType conversion is non-fatal")

message(STATUS "NoteData utility revalidation invariants passed")
