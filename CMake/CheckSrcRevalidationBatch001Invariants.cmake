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

require_contains(
  "${song_cache_index_cpp}"
  "BinaryToHex(CryptManager::GetSHA1ForString(s))"
  "SRC-001 cache filenames use a stable path digest")
require_contains(
  "${song_cache_index_cpp}"
  "m_bDelaySaveCache(false)"
  "SRC-014 delayed cache writes have a deterministic initial state")
require_contains(
  "${song_cache_index_cpp}"
  "GetSHA1ForString(NormalizeCacheKeyPath(Name))"
  "SRC-015 cache-index keys preserve path identity")

require_contains(
  "${screen_edit_cpp}"
  "IsGameplayColumnInputPressed(EditState state) const"
  "SRC-002 release guard is state-aware")
require_contains(
  "${screen_edit_cpp}"
  "FOREACH_EnabledPlayer(pn) players.push_back(pn);"
  "SRC-002 practice playback watches every enabled player")

require_contains(
  "${tech_counts_cpp}"
  "std::min(saValues.size(), static_cast<size_t>(NUM_TechCountsCategory))"
  "SRC-004 TechCounts parsing is bounded by TechCountsCategory")
require_contains(
  "${notes_loader_ssc_cpp}"
  "values.size() != expected_values"
  "SRC-005 malformed TECHCOUNTS caches are rejected")
require_contains(
  "${notes_loader_ssc_cpp}"
  "cats_per_player > NUM_RadarCategory"
  "SRC-006 malformed RADARVALUES caches are bounded")
require_contains(
  "${notes_loader_ssc_cpp}"
  "RageUtil::SafeDelete(pNewNotes);"
  "SRC-007/SRC-008 temporary Steps ownership is released on rejection")

require_contains(
  "${notes_writer_sm_cpp}"
  "while (j < lines.size() && lines[j].empty())"
  "SRC-009 SM writer skips leading blank lines")
require_contains(
  "${notes_writer_ssc_cpp}"
  "while (j < lines.size() && lines[j].empty())"
  "SRC-009 SSC writer skips leading blank lines")

require_contains(
  "${song_manager_cpp}"
  "GetDirListing(sDir + \"*.edit\", vsFiles, false, true);"
  "SRC-011 legacy profile edits are listed before applying limits")
require_contains(
  "${steps_cpp}"
  "SplitCompositeOrStackedNoteData(\n          tempNoteData, vParts, m_StepsType)"
  "SRC-012 measure statistics use per-player composite/couple data")
require_contains(
  "${song_manager_cpp}"
  "++sanity_index;"
  "SRC-013 group sanity-check progress advances")

file(GLOB language_files "${ITGMANIA_SOURCE_DIR}/Themes/Simply Love/Languages/*.ini")
foreach(language_file IN LISTS language_files)
  file(READ "${language_file}" language_contents)
  require_not_contains(
    "${language_contents}"
    "Start at -9ms"
    "SRC-003 obsolete Global Offset recommendation in ${language_file}")
  require_not_contains(
    "${language_contents}"
    "Comienza en -9ms"
    "SRC-003 obsolete Global Offset recommendation in ${language_file}")
endforeach()
