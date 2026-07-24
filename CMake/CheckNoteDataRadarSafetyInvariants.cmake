set(note_h "${ITGMANIA_SOURCE_DIR}/src/NoteData.h")
set(note_cpp "${ITGMANIA_SOURCE_DIR}/src/NoteData.cpp")
set(radar_cpp "${ITGMANIA_SOURCE_DIR}/src/RadarValues.cpp")

foreach(path IN ITEMS "${note_h}" "${note_cpp}" "${radar_cpp}")
  if(NOT EXISTS "${path}")
    message(FATAL_ERROR "Missing NoteData/Radar source: ${path}")
  endif()
endforeach()

file(READ "${note_h}" note_header)
file(READ "${note_cpp}" note_source)
file(READ "${radar_cpp}" radar_source)

function(require_contains content needle label)
  string(FIND "${content}" "${needle}" position)
  if(position EQUAL -1)
    message(FATAL_ERROR "NoteData/Radar invariant failed: ${label}")
  endif()
endfunction()

function(require_not_contains content needle label)
  string(FIND "${content}" "${needle}" position)
  if(NOT position EQUAL -1)
    message(FATAL_ERROR "NoteData/Radar invariant failed: ${label}")
  endif()
endfunction()

require_contains(
  "${note_header}"
  "NoteData(const NoteData& other);"
  "NoteData declares ownership-aware copy semantics")
require_contains(
  "${note_source}"
  "m_atis(),"
  "NoteData copies do not inherit active iterator registries")
require_contains(
  "${note_source}"
  "RevalidateATIs(changedTracks, true)"
  "track growth revalidates all-track iterators")
require_contains(
  "${note_source}"
  "iEndRow > MAX_NOTE_ROW"
  "holds cannot extend beyond the supported note range")
require_contains(
  "${note_source}"
  "iOtherRow > MAX_NOTE_ROW - tnOther.iDuration"
  "overlapping hold arithmetic cannot overflow")
require_contains(
  "${note_source}"
  "iNewNumTracks < 1 || iNewNumTracks > MAX_NOTE_TRACKS ||\n      iOriginalTrackToTakeFrom == nullptr"
  "transformed NoteData rejects null mappings")
require_contains(
  "${note_source}"
  "m_PrevCurrentRows.resize(m_pNoteData->GetNumTracks(), 0)"
  "iterator state is resized after copies and track-count changes")
require_not_contains(
  "${note_header}"
  "TransferATIs(NoteData& to)"
  "undefined iterator-transfer API is removed")
require_not_contains(
  "${note_header}"
  "swap<NoteData>(NoteData& nd1, NoteData& nd2) noexcept"
  "NoteData swap does not promise noexcept while safety may allocate")
require_contains(
  "${radar_source}"
  "MakeUnknown();\n\n  FOREACH_ENUM(RadarCategory, rc)"
  "partial radar XML keeps absent categories unknown")
require_contains(
  "${radar_source}"
  "StringToFloat(rawValue, value)"
  "radar XML values use strict finite full-string parsing")

message(STATUS "NoteData and Radar safety invariants passed")
