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
