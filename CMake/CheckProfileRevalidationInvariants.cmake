if(NOT DEFINED ITGMANIA_SOURCE_DIR)
  message(FATAL_ERROR "ITGMANIA_SOURCE_DIR is required")
endif()

set(profile_source "${ITGMANIA_SOURCE_DIR}/src/Profile.cpp")
set(profile_manager_source "${ITGMANIA_SOURCE_DIR}/src/ProfileManager.cpp")
foreach(path IN ITEMS "${profile_source}" "${profile_manager_source}")
  if(NOT EXISTS "${path}")
    message(FATAL_ERROR "Missing profile source: ${path}")
  endif()
endforeach()
file(READ "${profile_source}" profile)
file(READ "${profile_manager_source}" profile_manager)

function(require_contains content needle label)
  string(FIND "${content}" "${needle}" position)
  if(position EQUAL -1)
    message(FATAL_ERROR "Profile revalidation invariant failed: ${label}")
  endif()
endfunction()

function(require_not_contains content needle label)
  string(FIND "${content}" "${needle}" position)
  if(NOT position EQUAL -1)
    message(FATAL_ERROR "Profile revalidation invariant failed: ${label}")
  endif()
endfunction()

require_contains("${profile}" "if (GAMESTATE != nullptr && curr_song == gamestate_curr_song)"
  "song cleanup tolerates absent GameState")
require_contains("${profile}" "if (m_group != nullptr)"
  "group cleanup is independent from the song vector")
require_contains("${profile}" "iCount = AddProfileIntSaturated("
  "nested play-count aggregation saturates")
require_contains("${profile}" "for (Steps* pSteps : pSong->GetAllSteps()) {\n      if (pSteps == nullptr)"
  "completion scans skip null charts")
require_contains("${profile}" "iTotalNumTimesPlayed = AddProfileIntSaturated("
  "public song play-count aggregation saturates")
require_not_contains("${profile}" "iTotalNumTimesPlayed += hsSteps.hsl.GetNumTimesPlayed();"
  "song play totals never use overflowing raw addition")
require_contains("${profile}" "return possible > 0.0f ? GetSongsActual(st, dc) / possible : 0.0f;"
  "empty song sets return finite completion")
require_contains("${profile}" "const HighScoreList* hsl = GetStepsHighScoreListIfPresent(pSong, pSteps);"
  "const score lookups do not insert map entries")
require_contains("${profile}" "if (pGameType == nullptr)"
  "default modifier APIs reject a missing game")
require_contains("${profile}" "if (iter == m_SongHighScores.end() || iter->second.m_StepsHighScores.empty())"
  "last-played lookup handles an unseen song")
require_contains("${profile}" "if (++stepScoreEntries > MAX_PROFILE_SCORE_ROOT_ENTRIES)"
  "song score imports bound nested chart entries")
require_contains("${profile}" "if (++trailScoreEntries > MAX_PROFILE_SCORE_ROOT_ENTRIES)"
  "course score imports bound nested trail entries")
require_contains("${profile_manager}" "m_sProfileDir[pn].clear();\n    m_bWasLoadedFromMemoryCard[pn] = false;"
  "failed profile loads cannot leave a persistent active slot")
require_contains("${profile_manager}" "return m_bLastLoadWasTamperedOrCorrupt[pn];"
  "failed-load diagnostics survive transactional slot cleanup")
require_contains("${profile_manager}" "if (LUA != nullptr)"
  "ProfileManager Lua registration tolerates unavailable Lua runtime")
require_contains("${profile_manager}" "pProfile->m_sDisplayName = oldName;\n    return false;"
  "failed profile renames roll back in-memory state")
require_contains("${profile_manager}" "GetProfileSortOrder() == ProfileSortOrder_Alphabetical"
  "successful profile renames maintain alphabetical ordering")
require_contains("${profile}" "const Profile backup = *this;"
  "stats-prefix reloads retain a transactional profile snapshot")
require_contains("${profile}" "*this = backup;\n      return false;"
  "failed stats-prefix reloads restore the previous profile")
require_contains("${profile_manager}" "m_stats_prefix = previousPrefix;"
  "partial stats-prefix changes roll back the global prefix")
require_contains("${profile_manager}" "hs.GetGrade() != Grade_Failed"
  "failed course scores cannot enter machine rankings")

message(STATUS "Profile revalidation invariants passed")
