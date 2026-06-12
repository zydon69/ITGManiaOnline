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

read_source("src/NotesLoaderBMS.cpp" notes_loader_bms_cpp)

require_not_contains(
  "${notes_loader_bms_cpp}"
  "rand() % StringToInt(value)"
  "BMS #RANDOM must validate the parsed maximum before modulo")
require_contains(
  "${notes_loader_bms_cpp}"
  "const int randomMax = StringToInt(value);"
  "BMS #RANDOM stores parsed maximum before validation")
require_contains(
  "${notes_loader_bms_cpp}"
  "if (randomMax <= 0)"
  "BMS #RANDOM rejects zero, negative, and non-numeric values")
require_contains(
  "${notes_loader_bms_cpp}"
  "randomStack[currentNode->branchHeight] = 0;"
  "BMS invalid #RANDOM leaves dependent branches false")
