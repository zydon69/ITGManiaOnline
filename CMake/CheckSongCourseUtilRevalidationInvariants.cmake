if(NOT DEFINED ITGMANIA_SOURCE_DIR)
  message(FATAL_ERROR "ITGMANIA_SOURCE_DIR is required")
endif()

file(READ "${ITGMANIA_SOURCE_DIR}/src/SongUtil.cpp" song_util_source)
file(READ "${ITGMANIA_SOURCE_DIR}/src/CourseUtil.cpp" course_util_source)

function(require_contains content needle label)
  string(FIND "${content}" "${needle}" position)
  if(position EQUAL -1)
    message(FATAL_ERROR "Song/Course util invariant failed: ${label}")
  endif()
endfunction()

function(require_not_contains content needle label)
  string(FIND "${content}" "${needle}" position)
  if(NOT position EQUAL -1)
    message(FATAL_ERROR "Song/Course util invariant failed: ${label}")
  endif()
endfunction()

require_not_contains(
  "${song_util_source}"
  "DEFAULT_FAIL(m_Selectable)"
  "invalid selectable criteria are non-fatal")
require_not_contains(
  "${song_util_source}"
  "DEFAULT_FAIL(m_Tutorial)"
  "invalid tutorial criteria are non-fatal")
require_not_contains(
  "${song_util_source}"
  "DEFAULT_FAIL(m_Locked)"
  "invalid lock criteria are non-fatal")
require_contains(
  "${song_util_source}"
  "static thread_local std::map<const Song*, std::string>"
  "song sort cache is isolated per thread")
require_contains(
  "${song_util_source}"
  "const auto value = g_mapSongSortVal.find(pSong);"
  "song sort comparisons do not insert missing entries")
require_not_contains(
  "${song_util_source}"
  "ASSERT(pProfile != nullptr)"
  "song profile sorts reject missing profiles")
require_contains(
  "${song_util_source}"
  "UNLOCKMAN == nullptr || !UNLOCKMAN->StepsIsLocked"
  "meter sections tolerate a missing unlock manager")
require_contains(
  "${song_util_source}"
  "GAMESTATE->m_pCurGame == nullptr"
  "playability rejects a missing current game")

require_contains(
  "${course_util_source}"
  "static thread_local std::map<const Course*, std::string>"
  "course sort cache is isolated per thread")
require_contains(
  "${course_util_source}"
  "requested without GAMESTATE; falling back"
  "course stats sorts reject missing game state")
require_contains(
  "${course_util_source}"
  "if (pCourse != nullptr)"
  "course profile sorts skip null entries")
require_contains(
  "${course_util_source}"
  "out = Course();"
  "course autogeneration clears stale output state")
require_contains(
  "${course_util_source}"
  "hasUnsafeFileCharacter || !utf8_is_valid(sNewName)"
  "course filenames are validated at the persistence boundary")
require_contains(
  "${course_util_source}"
  "refusing to delete foreign course"
  "course deletion validates manager ownership before removing files")
require_contains(
  "${course_util_source}"
  "!std::isfinite(pCourse->m_fGoalSeconds)"
  "edit course goal duration is finite before integer conversion")

message(STATUS "Song/Course util revalidation invariants passed")
