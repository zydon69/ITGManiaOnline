if(NOT DEFINED ITGMANIA_SOURCE_DIR)
  message(FATAL_ERROR "ITGMANIA_SOURCE_DIR is required")
endif()
file(READ "${ITGMANIA_SOURCE_DIR}/src/SongManager.cpp" source)
file(READ "${ITGMANIA_SOURCE_DIR}/src/SongManager.h" header)

function(require_contains haystack needle label)
  string(FIND "${haystack}" "${needle}" found_at)
  if(found_at EQUAL -1)
    message(FATAL_ERROR "Missing invariant: ${label}")
  endif()
endfunction()

require_contains("${source}" "m_sSongGroupBannerPaths.clear();" "group banners share song lifecycle")
require_contains("${source}" "i >= m_sSongGroupBannerPaths.size()" "group banner lookup is bounded")
require_contains("${source}" "refused to unlist foreign song" "UnlistSong rejects foreign ownership")
require_contains("${source}" "m_pDeletedSongs.push_back(song);" "owned unlisted songs use deferred deletion")
require_contains("${source}" "if (iNumParams < 2)" "random attacks validate arity before access")
require_contains("${source}" "if (!CourseLoaderCRS::LoadFromCRSFile" "course loading checks parser result")
require_contains("${source}" "pTrail == nullptr || pTrail->m_vEntries.empty()" "extra course trail is validated")
require_contains("${source}" "pSongOut = nullptr;" "extra stage outputs start null")
require_contains("${source}" "LOCKED_LOCK | LOCKED_SELECTABLE | LOCKED_DISABLED" "selectable unlocked counter excludes all lock flags")
require_contains("${source}" "COURSE_GROUP_COLOR.GetValue" "course groups use course palette")
require_contains("${source}" "const std::string sectionName = iter->sName;" "preferred section name is saved before erase")
require_contains("${source}" "p->SetPreferredCourses(sPreferredCourses" "Lua preferred courses binding targets courses")
require_contains("${header}" "index >= m_sSongGroupNames.size()" "song group index API is bounded")
require_contains("${source}" "refused to delete steps whose parent song" "DeleteSteps validates parent ownership")
require_contains("${source}" "refused to delete course" "DeleteCourse rejects invalid ownership")
require_contains("${source}" "if (!apToDelete.empty()) {" "empty profile cleanup skips global course cache rebuilds")
require_contains("${source}" "MakeLower(audio_ext);" "song folder sanity check is case independent")
require_contains("${source}" "MAX_EDIT_COURSES_PER_PROFILE - iNumCourseEditsLoaded" "profile course limit includes loaded edits")
require_contains(
  "${source}"
  "reused canonical song"
  "song includes reuse canonical objects while preserving group membership")
require_contains(
  "${source}"
  "std::vector<Song*> SongManager::GetSongsOfCurrentGame"
  "current-game song filtering returns owned result values")
require_contains(
  "${source}"
  "SongManager::Reload refused with an incomplete"
  "song reload validates manager lifecycle")
require_contains(
  "${source}"
  "preferred song table ignored without UnlockManager"
  "preferred sort APIs reject missing unlock manager without assertions")
