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
    message(FATAL_ERROR "Forbidden regression: ${label}")
  endif()
endfunction()

read_source("src/SongCacheIndex.cpp" song_cache_index_cpp)
read_source("src/ScreenEdit.cpp" screen_edit_cpp)
read_source("src/TechCounts.cpp" tech_counts_cpp)
read_source("src/NotesLoaderSSC.cpp" notes_loader_ssc_cpp)
read_source("src/NotesWriterSM.cpp" notes_writer_sm_cpp)
read_source("src/NotesWriterSSC.cpp" notes_writer_ssc_cpp)
read_source("src/SongManager.cpp" song_manager_cpp)
read_source("src/Steps.cpp" steps_cpp)
read_source("CMake/SMDefs.cmake" version_definitions_cmake)
read_source("CMake/GenerateVerstub.cmake" version_generator_cmake)

require_contains(
  "${song_cache_index_cpp}"
  "BinaryToHex(CryptManager::GetSHA1ForString(s))"
  "cache filenames use a stable path digest")
require_contains(
  "${song_cache_index_cpp}"
  "m_bDelaySaveCache(false)"
  "delayed cache writes have a deterministic initial state")
require_contains(
  "${song_cache_index_cpp}"
  "GetSHA1ForString(NormalizeCacheKeyPath(Name))"
  "cache-index keys preserve path identity")

require_contains(
  "${screen_edit_cpp}"
  "IsGameplayColumnInputPressed(EditState state) const"
  "release guard is state-aware")
require_contains(
  "${screen_edit_cpp}"
  "FOREACH_EnabledPlayer(pn) players.push_back(pn);"
  "practice playback watches every enabled player")

require_contains(
  "${tech_counts_cpp}"
  "std::min(saValues.size(), static_cast<size_t>(NUM_TechCountsCategory))"
  "TechCounts parsing is bounded by TechCountsCategory")
require_contains(
  "${notes_loader_ssc_cpp}"
  "values.size() != expected_values"
  "malformed TECHCOUNTS caches are rejected")
require_contains(
  "${notes_loader_ssc_cpp}"
  "cats_per_player > NUM_RadarCategory"
  "malformed RADARVALUES caches are bounded")
require_contains(
  "${notes_loader_ssc_cpp}"
  "RageUtil::SafeDelete(pNewNotes);"
  "temporary Steps ownership is released on rejection")

require_contains(
  "${notes_writer_sm_cpp}"
  "while (j < lines.size() && lines[j].empty())"
  "SM writer skips leading blank lines")
require_contains(
  "${notes_writer_ssc_cpp}"
  "while (j < lines.size() && lines[j].empty())"
  "SSC writer skips leading blank lines")

require_contains(
  "${song_manager_cpp}"
  "GetDirListing(sDir + \"*.edit\", vsFiles, false, true);"
  "legacy profile edits are listed before applying limits")
require_contains(
  "${steps_cpp}"
  "SplitCompositeOrStackedNoteData(\n          tempNoteData, vParts, m_StepsType)"
  "measure statistics use per-player composite/couple data")
require_contains(
  "${song_manager_cpp}"
  "++sanity_index;"
  "group sanity-check progress advances")
require_not_contains(
  "${version_definitions_cmake}"
  "-BETA"
  "default build version labels must not contain BETA")
require_not_contains(
  "${version_generator_cmake}"
  "-BETA"
  "generated executable version labels must not contain BETA")
require_contains(
  "${version_definitions_cmake}"
  "\${SM_VERSION_MAJOR}.\${SM_VERSION_MINOR}.\${SM_VERSION_PATCH}-git-\${SM_VERSION_GIT_HASH}"
  "default build version labels retain the source revision")
require_contains(
  "${version_generator_cmake}"
  "\${SM_VERSION_TRADITIONAL}-git-\${generated_git_hash}"
  "generated executable version labels retain the source revision")

file(GLOB language_files "${ITGMANIA_SOURCE_DIR}/Themes/Simply Love/Languages/*.ini")
foreach(language_file IN LISTS language_files)
  file(READ "${language_file}" language_contents)
  require_not_contains(
    "${language_contents}"
    "Start at -9ms"
    "obsolete Global Offset recommendation in ${language_file}")
  require_not_contains(
    "${language_contents}"
    "Comienza en -9ms"
    "obsolete Global Offset recommendation in ${language_file}")
endforeach()
