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

read_source("src/NotesLoaderSM.cpp" sm_loader)
read_source("src/NotesLoaderSSC.cpp" ssc_loader)
read_source("src/NotesWriterSSC.cpp" ssc_writer)

require_contains(
  "${sm_loader}"
  "!attackValid || !hasTime || !hasDuration"
  "SM/SSC attacks require complete explicit timing")
require_contains(
  "${sm_loader}"
  "join(\"=\", sBits.begin() + 1, sBits.end())"
  "attack modifiers preserve embedded equals signs")
require_contains(
  "${sm_loader}"
  "PREFSMAN == nullptr || !PREFSMAN->m_bQuirksMode"
  "BGChanges are safe before preference manager initialization")
require_contains(
  "${sm_loader}"
  "if (fTickcountBeat < 0)"
  "SM tickcounts reject negative beats")
require_contains(
  "${sm_loader}"
  "if (fBeat < 0)"
  "SM timing segments reject negative beats")
require_contains(
  "${ssc_loader}"
  "has an invalid #WARPS beat"
  "SSC warps reject negative beats")
require_contains(
  "${ssc_loader}"
  "if (fRatio <= 0.0f)"
  "SSC scrolls reject non-positive ratios")
require_contains(
  "${ssc_writer}"
  "PROFILEMAN == nullptr ||\n      FILEMAN == nullptr"
  "SSC edit writer validates both managers")
