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

read_source("src/NotesLoaderSM.cpp" notes_loader_sm_cpp)

require_not_contains(
  "${notes_loader_sm_cpp}"
  "ibpm++;\n      bpm = ibpm->second;"
  "ProcessBPMsAndStops must not advance ibpm before reading the first future BPM")
require_contains(
  "${notes_loader_sm_cpp}"
  "const float nextBpmBeat = ibpm->first;\n      bpm = ibpm->second;\n      ++ibpm;"
  "ProcessBPMsAndStops reads then consumes the first future normal BPM")
require_contains(
  "${notes_loader_sm_cpp}"
  "does not establish a normal BPM before beat 0.  Defaulting to 60"
  "ProcessBPMsAndStops logs fallback when the first future BPM is not normal")
