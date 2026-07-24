if(NOT DEFINED ITGMANIA_SOURCE_DIR)
  message(FATAL_ERROR "ITGMANIA_SOURCE_DIR is required")
endif()

set(life_time "${ITGMANIA_SOURCE_DIR}/src/LifeMeterTime.cpp")
set(graph "${ITGMANIA_SOURCE_DIR}/src/GraphDisplay.cpp")
set(graph_header "${ITGMANIA_SOURCE_DIR}/src/GraphDisplay.h")
set(combo "${ITGMANIA_SOURCE_DIR}/src/ComboGraph.cpp")
set(combo_header "${ITGMANIA_SOURCE_DIR}/src/ComboGraph.h")
set(pane "${ITGMANIA_SOURCE_DIR}/src/PaneDisplay.cpp")
set(percentage "${ITGMANIA_SOURCE_DIR}/src/PercentageDisplay.cpp")

foreach(path IN ITEMS
    "${life_time}" "${graph}" "${graph_header}" "${combo}"
    "${combo_header}" "${pane}" "${percentage}")
  if(NOT EXISTS "${path}")
    message(FATAL_ERROR "Missing evaluation widget source: ${path}")
  endif()
endforeach()

foreach(name IN ITEMS
    life_time graph graph_header combo combo_header pane percentage)
  file(READ "${${name}}" ${name}_source)
endforeach()

function(require_contains content needle label)
  string(FIND "${content}" "${needle}" position)
  if(position EQUAL -1)
    message(FATAL_ERROR "Evaluation-widget invariant failed: ${label}")
  endif()
endfunction()

function(require_not_contains content needle label)
  string(FIND "${content}" "${needle}" position)
  if(NOT position EQUAL -1)
    message(FATAL_ERROR "Evaluation-widget invariant failed: ${label}")
  endif()
endfunction()

require_contains(
  "${life_time_source}"
  "void LifeMeterTime::ResetLoadedActors()"
  "time meter reload releases its owned actors")
require_contains(
  "${life_time_source}"
  "AddSecondsSaturated("
  "time meter accumulates seconds without float overflow")
require_contains(
  "${life_time_source}"
  "MESSAGEMAN == nullptr"
  "time meter broadcasts tolerate unavailable message state")
require_contains(
  "${graph_source}"
  "GraphDisplay::GraphDisplay(const GraphDisplay& cpy)"
  "graph display performs an explicit deep copy")
require_contains(
  "${graph_source}"
  "TEXTUREMAN->CopyTexture(cpy.m_pTexture)"
  "graph-body copies retain their texture")
require_contains(
  "${graph_source}"
  "if (p == nullptr)"
  "song-boundary copies are checked")
require_contains(
  "${graph_header_source}"
  "GraphDisplay& operator=(const GraphDisplay&) = delete;"
  "graph display cannot shallow-assign owned actors")
require_contains(
  "${combo_source}"
  "bool GetClampedComboRange("
  "combo timing is computed once with widened arithmetic")
require_contains(
  "${combo_header_source}"
  "ComboGraph& operator=(const ComboGraph&) = delete;"
  "combo graph cannot shallow-assign owned actors")
require_contains(
  "${pane_source}"
  "PaneDisplay::PaneDisplay(const PaneDisplay& cpy)"
  "pane display reattaches copied embedded actors")
require_contains(
  "${percentage_source}"
  "PercentageDisplay::PercentageDisplay(const PercentageDisplay& cpy)"
  "percentage display reattaches copied embedded actors")
require_contains(
  "${percentage_source}"
  "m_FormatPercentScore.SetFromExpression(\"FormatPercentScore\");"
  "percentage reload resets its formatter")
require_not_contains(
  "${percentage_source}"
  "std::string(\"diu\")"
  "integer formatter does not pass signed int to percent-u")

message(STATUS "Evaluation-widget safety invariants passed")
