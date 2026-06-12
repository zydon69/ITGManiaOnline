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

read_source("src/StepParityGenerator.cpp" step_parity_generator_cpp)
read_source("src/Steps.cpp" steps_cpp)

require_contains(
  "${step_parity_generator_cpp}"
  "if (note.warped) {\n      continue;\n    }"
  "StepParity ignores warped-over notes before building rows")
require_contains(
  "${steps_cpp}"
  "case StepsType_dance_solo:"
  "TechCounts has a stage layout for dance-solo")
require_contains(
  "${steps_cpp}"
  "case StepsType_dance_threepanel:"
  "TechCounts has a stage layout for dance-threepanel")
require_contains(
  "${steps_cpp}"
  "StepsType_dance_threepanel"
  "dance-threepanel layout remains explicit")
