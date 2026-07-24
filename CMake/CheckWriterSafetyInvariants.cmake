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

read_source("src/NotesWriterDWI.cpp" dwi)
require_contains("${dwi}" "if (bpms.empty())" "DWI rejects missing BPM")
require_contains("${dwi}" "#DISPLAYBPM:*;" "DWI random display BPM is terminated")
require_contains("${dwi}" "return FinishWrite(f, sPath);" "DWI flush result is checked")
require_not_contains("${dwi}" "ASSERT" "DWI export does not assert on content")
require_not_contains("${dwi}" "FAIL_M" "DWI export does not fail fatally on content")

read_source("src/NotesWriterSM.cpp" sm)
read_source("src/NotesWriterSSC.cpp" ssc)
foreach(writer IN ITEMS sm ssc)
  require_contains("${${writer}}" "class CheckedFileWriter" "${writer} tracks write failures")
  require_contains("${${writer}}" "if (writer.Flush() == -1)" "${writer} checks final flush")
  require_contains("${${writer}}" "SmEscape(sDir)" "${writer} escapes edit song paths")
  require_contains("${${writer}}" "DoesFileExist(pSteps->GetFilename())" "${writer} verifies stale edit removal")
endforeach()
require_contains("${sm}" "Invalid SM selection display" "SM invalid selection display has fallback")
require_contains("${sm}" "fBPM <= 0.0f" "SM validates BPM before warp conversion")
require_contains("${sm}" "iRow = 1;" "SM row-zero delay avoids negative serialized beat")
require_contains("${sm}" "fallback BPM" "SM required BPM tag has fallback")
require_contains(
  "${sm}"
  "PROFILEMAN == nullptr ||\n      FILEMAN == nullptr"
  "SM edit writer validates both managers")

require_contains("${ssc}" "Invalid SSC selection display" "SSC invalid selection display has fallback")
require_contains("${ssc}" "if (!bIsSong)" "SSC chart-only fakes remain scoped to charts")
require_contains("${ssc}" "GetTimingVectorForWrite(timing, SEGMENT_STOP, 6)" "SSC stops use validated serialization")
require_contains("${ssc}" "GetTimingVectorForWrite(timing, SEGMENT_DELAY, 6)" "SSC delays use validated serialization")
require_contains("${ssc}" "GetTimingVectorForWrite(timing, SEGMENT_WARP, 6)" "SSC warps use validated serialization")
require_contains("${ssc}" "GetTimingVectorForWrite(timing, SEGMENT_FAKE, 6)" "SSC fakes use validated serialization")
require_contains("${ssc}" "SanitizeSSCLabelForWrite" "SSC labels are delimiter-safe")
require_contains("${ssc}" "const std::vector<std::vector<int>>& allNotesPerMeasures" "SSC measure stats avoid copies")

read_source("src/Song.cpp" song)
require_contains(
  "${song}"
  "if (SONGMAN == nullptr || SONGINDEX == nullptr)"
  "song cache save validates global managers")
require_contains(
  "${song}"
  "Refusing to save SSC for '%s' with null Steps"
  "song save rejects corrupt null Steps collections")
require_contains(
  "${song}"
  "Refusing to save SM for '%s' without a simfile path"
  "SM save rejects missing destination path")
