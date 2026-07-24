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
require_contains(
  "${notes_loader_bms_cpp}"
  "static bool IsValidPositiveBMSValue"
  "BMS timing values are validated through a shared positive finite helper")
require_contains(
  "${notes_loader_bms_cpp}"
  "initialBPM = 60.0f;"
  "BMS charts default missing initial BPM to 60")
require_contains(
  "${notes_loader_bms_cpp}"
  "std::gcd(bestNum, bestDen)"
  "BMS measure fraction conversion is bounded and reduced")
require_contains(
  "${notes_loader_bms_cpp}"
  "ignored invalid BMS measure size"
  "BMS invalid measure sizes are logged and ignored")
require_contains(
  "${notes_loader_bms_cpp}"
  "ignored invalid BMS stop"
  "BMS invalid stops are logged and ignored")
require_contains(
  "${notes_loader_bms_cpp}"
  "std::vector<int> transform(tracks, -1)"
  "BMS parser uses RAII containers for lane transforms")
require_not_contains(
  "${notes_loader_bms_cpp}"
  "new int[tracks]"
  "BMS parser must not allocate track arrays manually")
require_not_contains(
  "${notes_loader_bms_cpp}"
  "delete[] transform"
  "BMS parser must not manually delete track arrays")
require_contains(
  "${notes_loader_bms_cpp}"
  "Tree.doStatement(line);"
  "BMS referenced lanes are calculated after conditional evaluation")
require_contains(
  "${notes_loader_bms_cpp}"
  "found no applicable BMS simfile for direct LoadFromDir"
  "BMS direct LoadFromDir handles missing files without ASSERT")
require_contains(
  "${notes_loader_bms_cpp}"
  "found no loadable BMS charts in directory"
  "BMS LoadFromDir rejects directories with no loadable charts")
require_contains(
  "${notes_loader_bms_cpp}"
  "EndsWith(it->second, \".lua\")"
  "BMS background Lua detection is safe for short filenames")
require_contains(
  "${notes_loader_bms_cpp}"
  "out->SetMeter(std::max(StringToInt(it->second), 1));"
  "BMS #PLAYLEVEL clamps meter to at least 1")
require_contains(
  "${notes_loader_bms_cpp}"
  "ignored trailing half-object in BMS channel"
  "BMS odd-length channel data is logged")
require_not_contains(
  "${notes_loader_bms_cpp}"
  "ASSERT(arrayBMSFileNames.size() != 0)"
  "BMS direct LoadFromDir must not ASSERT on missing files")
require_not_contains(
  "${notes_loader_bms_cpp}"
  "ASSERT(out.m_vsKeysoundFile.empty())"
  "BMS direct LoadFromDir must not ASSERT on pre-existing keysounds")
