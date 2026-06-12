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

read_source("src/NotesLoaderJson.cpp" notes_loader_json_cpp)

require_not_contains(
  "${notes_loader_json_cpp}"
  "o.type = (TapNoteType)root[\"Type\"].asInt();"
  "JSON note type must not be read from an integer root as an object member")
require_not_contains(
  "${notes_loader_json_cpp}"
  "int iTracks = nd.GetNumTracks();"
  "JSON NoteData must initialize track count from StepsType, not a fresh NoteData")
require_contains(
  "${notes_loader_json_cpp}"
  "o.type = root.isMember(\"Type\") ? (TapNoteType)root[\"Type\"].asInt()"
  "JSON object notes read their explicit TapNoteType")
require_contains(
  "${notes_loader_json_cpp}"
  ": TapNoteType_Tap;"
  "JSON object notes without Type default to normal taps written by NotesWriterJson")
require_contains(
  "${notes_loader_json_cpp}"
  "const int iTracks = GAMEMAN->GetStepsTypeInfo(st).iNumTracks;"
  "JSON NoteData derives track count from the chart StepsType")
require_contains(
  "${notes_loader_json_cpp}"
  "if (iTrack < 0 || iTrack >= iTracks)"
  "JSON NoteData rejects notes outside the chart track range")
require_contains(
  "${notes_loader_json_cpp}"
  "RageUtil::SafeDelete(step);"
  "JSON loader deletes chart objects rejected during deserialization")
require_contains(
  "${notes_loader_json_cpp}"
  "DisplayBPMToString(DISPLAY_BPM_RANDOM)"
  "JSON loader recognizes enum display BPM strings written by NotesWriterJson")
require_contains(
  "${notes_loader_json_cpp}"
  "DeserializeTimingSegmentArray<DelaySegment>"
  "JSON loader reads delay timing segments")
require_contains(
  "${notes_loader_json_cpp}"
  "DeserializeTimingSegmentArray<TimeSignatureSegment>"
  "JSON loader reads time signature timing segments")
require_contains(
  "${notes_loader_json_cpp}"
  "DeserializeTimingSegmentArray<WarpSegment>"
  "JSON loader reads warp timing segments")
require_contains(
  "${notes_loader_json_cpp}"
  "DeserializeTimingSegmentArray<TickcountSegment>"
  "JSON loader reads tickcount timing segments")
require_contains(
  "${notes_loader_json_cpp}"
  "DeserializeTimingSegmentArray<ComboSegment>"
  "JSON loader reads combo timing segments")
require_contains(
  "${notes_loader_json_cpp}"
  "DeserializeTimingSegmentArray<SpeedSegment>"
  "JSON loader reads speed timing segments")
require_contains(
  "${notes_loader_json_cpp}"
  "DeserializeTimingSegmentArray<ScrollSegment>"
  "JSON loader reads scroll timing segments")
require_contains(
  "${notes_loader_json_cpp}"
  "DeserializeTimingSegmentArray<FakeSegment>"
  "JSON loader reads fake timing segments")

read_source("src/NotesWriterJson.cpp" notes_writer_json_cpp)

require_contains(
  "${notes_writer_json_cpp}"
  "root[\"DelaySegments\"]"
  "JSON writer writes delay timing segments")
require_contains(
  "${notes_writer_json_cpp}"
  "root[\"TimeSignatureSegments\"]"
  "JSON writer writes time signature timing segments")
require_contains(
  "${notes_writer_json_cpp}"
  "root[\"WarpSegments\"]"
  "JSON writer writes warp timing segments")
require_contains(
  "${notes_writer_json_cpp}"
  "root[\"TickcountSegments\"]"
  "JSON writer writes tickcount timing segments")
require_contains(
  "${notes_writer_json_cpp}"
  "root[\"ComboSegments\"]"
  "JSON writer writes combo timing segments")
require_contains(
  "${notes_writer_json_cpp}"
  "root[\"SpeedSegments\"]"
  "JSON writer writes speed timing segments")
require_contains(
  "${notes_writer_json_cpp}"
  "root[\"ScrollSegments\"]"
  "JSON writer writes scroll timing segments")
require_contains(
  "${notes_writer_json_cpp}"
  "root[\"FakeSegments\"]"
  "JSON writer writes fake timing segments")
