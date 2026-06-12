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

read_source("src/NotesLoaderDWI.cpp" notes_loader_dwi_cpp)

require_contains(
  "${notes_loader_dwi_cpp}"
  "MakeUpper(normalizedMode);"
  "DWI chart modes are normalized before StepsType lookup")
require_not_contains(
  "${notes_loader_dwi_cpp}"
  "Unrecognized DWI notes format"
  "DWI unknown modes must be rejected without ASSERT_M")
require_not_contains(
  "${notes_loader_dwi_cpp}"
  "mapDanceNoteToNoteDataColumn.at"
  "DWI note column lookup must not throw on incompatible note characters")
require_contains(
  "${notes_loader_dwi_cpp}"
  "truncated DWI jump marker"
  "DWI truncated jump markers are logged and ignored")
require_contains(
  "${notes_loader_dwi_cpp}"
  "truncated DWI hold marker"
  "DWI truncated hold markers are logged and ignored")
require_contains(
  "${notes_loader_dwi_cpp}"
  "found no applicable DWI simfile for direct LoadFromDir"
  "DWI direct LoadFromDir handles missing files without ASSERT")
require_contains(
  "${notes_loader_dwi_cpp}"
  "fFreezeSeconds <= 0.0f"
  "DWI FREEZE segments reject non-positive durations")

read_source("src/NotesLoaderKSF.cpp" notes_loader_ksf_cpp)

require_contains(
  "${notes_loader_ksf_cpp}"
  "static bool IsValidPositiveBPM"
  "KSF BPM values are validated through a shared helper")
require_contains(
  "${notes_loader_ksf_cpp}"
  "std::min(rawTicks, ROWS_PER_BEAT)"
  "KSF tick counts are clamped to ROWS_PER_BEAT")
require_contains(
  "${notes_loader_ksf_cpp}"
  "ExtractDirectMoveValue"
  "KSF DirectMove commands are checked before value parsing")
require_contains(
  "${notes_loader_ksf_cpp}"
  "has no KSF STEP data"
  "KSF charts without STEP data are rejected")
require_contains(
  "${notes_loader_ksf_cpp}"
  "sRowString.size()) < notedata.GetNumTracks()"
  "KSF short note rows are rejected before indexed access")
require_contains(
  "${notes_loader_ksf_cpp}"
  "bKIUCompliant = true;"
  "KSF KIU markers are recorded during parsing")
require_contains(
  "${notes_loader_ksf_cpp}"
  "AddValidatedBunki"
  "KSF BUNKI changes validate previous and current BPMs")
require_contains(
  "${notes_loader_ksf_cpp}"
  "found no applicable KSF simfile for direct LoadFromDir"
  "KSF direct LoadFromDir handles missing files without ASSERT")
require_not_contains(
  "${notes_loader_ksf_cpp}"
  "substr(2, sRowString.size() - 3)"
  "KSF DirectMove value extraction must not underflow")
require_not_contains(
  "${notes_loader_ksf_cpp}"
  "ASSERT(arrayKSFFileNames.size() != 0)"
  "KSF direct LoadFromDir must not ASSERT on missing files")
require_not_contains(
  "${notes_loader_ksf_cpp}"
  "ASSERT(asBits.size() > 1)"
  "KSF title inference must not ASSERT on malformed paths")
