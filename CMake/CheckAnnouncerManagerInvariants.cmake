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

read_source("src/AnnouncerManager.cpp" announcer_manager_cpp)
read_source("src/AnnouncerManager.h" announcer_manager_h)

require_contains(
  "${announcer_manager_cpp}"
  "return FILEMAN != nullptr;"
  "AnnouncerManager guards filesystem access through FILEMAN")
require_contains(
  "${announcer_manager_cpp}"
  "if (LUA == nullptr)"
  "AnnouncerManager constructor tolerates missing Lua")
require_contains(
  "${announcer_manager_cpp}"
  "if (LUA != nullptr)"
  "AnnouncerManager destructor tolerates missing Lua")
require_contains(
  "${announcer_manager_cpp}"
  "AnnouncerFolderHasPlayableSounds"
  "AnnouncerManager resolves folders by playable audio files")
require_contains(
  "${announcer_manager_cpp}"
  "GetDirListing(normalizedPath + \"*.mp3\""
  "AnnouncerManager scans mp3 announcer sounds")
require_contains(
  "${announcer_manager_cpp}"
  "GetDirListing(normalizedPath + \"*.wav\""
  "AnnouncerManager scans wav announcer sounds")
require_contains(
  "${announcer_manager_cpp}"
  "GetDirListing(normalizedPath + \"*.ogg\""
  "AnnouncerManager scans ogg announcer sounds")
require_contains(
  "${announcer_manager_cpp}"
  "GetDirListing(normalizedPath + \"*.oga\""
  "AnnouncerManager scans oga announcer sounds")
require_contains(
  "${announcer_manager_cpp}"
  "for (size_t i = AddTo.size(); i > 0; --i)"
  "AnnouncerManager reverse erase uses size_t")
require_contains(
  "${announcer_manager_cpp}"
  "if (i == as.size())"
  "AnnouncerManager handles stale current announcer names")
require_contains(
  "${announcer_manager_cpp}"
  "p->SwitchAnnouncer(s);"
  "AnnouncerManager Lua setter avoids duplicate existence scans")
require_not_contains(
  "${announcer_manager_cpp}"
  "DirectoryIsEmpty("
  "AnnouncerManager must not use non-audio directory emptiness as sound proof")
require_contains(
  "${announcer_manager_h}"
  "struct lua_State;"
  "AnnouncerManager header forward declares lua_State")
require_not_contains(
  "${announcer_manager_h}"
  "#include \"LuaManager.h\""
  "AnnouncerManager header must not include LuaManager")
