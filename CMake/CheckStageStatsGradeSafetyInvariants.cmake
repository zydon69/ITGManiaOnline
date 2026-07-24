if(NOT DEFINED ITGMANIA_SOURCE_DIR)
  message(FATAL_ERROR "ITGMANIA_SOURCE_DIR is required")
endif()

set(grade_header "${ITGMANIA_SOURCE_DIR}/src/Grade.h")
set(grade_source "${ITGMANIA_SOURCE_DIR}/src/Grade.cpp")
set(stage_stats "${ITGMANIA_SOURCE_DIR}/src/StageStats.cpp")
set(player_stats "${ITGMANIA_SOURCE_DIR}/src/PlayerStageStats.cpp")
set(stats_manager "${ITGMANIA_SOURCE_DIR}/src/StatsManager.cpp")
set(screen_gameplay "${ITGMANIA_SOURCE_DIR}/src/ScreenGameplay.cpp")
set(screen_evaluation "${ITGMANIA_SOURCE_DIR}/src/ScreenEvaluation.cpp")

foreach(path IN ITEMS
    "${grade_header}" "${grade_source}" "${stage_stats}" "${player_stats}"
    "${stats_manager}" "${screen_gameplay}" "${screen_evaluation}")
  if(NOT EXISTS "${path}")
    message(FATAL_ERROR "Missing stage-stat source: ${path}")
  endif()
endforeach()

file(READ "${grade_header}" grade_header_source)
file(READ "${grade_source}" grade_source_source)
file(READ "${stage_stats}" stage_stats_source)
file(READ "${player_stats}" player_stats_source)
file(READ "${stats_manager}" stats_manager_source)
file(READ "${screen_gameplay}" screen_gameplay_source)
file(READ "${screen_evaluation}" screen_evaluation_source)

function(require_contains content needle label)
  string(FIND "${content}" "${needle}" position)
  if(position EQUAL -1)
    message(FATAL_ERROR "StageStats/Grade invariant failed: ${label}")
  endif()
endfunction()

function(require_not_contains content needle label)
  string(FIND "${content}" "${needle}" position)
  if(NOT position EQUAL -1)
    message(FATAL_ERROR "StageStats/Grade invariant failed: ${label}")
  endif()
endfunction()

require_not_contains(
  "${grade_header_source}"
  "ASSERT_M(\n      (g >= 0 && g < NUM_Grade)"
  "GradeToString does not terminate on public invalid input")
require_contains(
  "${grade_header_source}"
  "if (g < Grade_Tier01 || g >= Grade_Failed)"
  "GradeToString maps invalid tiers to NoData")
require_contains(
  "${grade_source_source}"
  "s.size() == 6 && s.compare(0, 4, \"TIER\") == 0"
  "grade parsing validates the normalized exact-width prefix")
require_contains(
  "${grade_source_source}"
  "s[4] >= '0' &&"
  "grade parsing accepts digits only")
require_contains(
  "${grade_source_source}"
  "if (THEME == nullptr)"
  "grade localization tolerates unavailable theme state")
require_contains(
  "${stage_stats_source}"
  "const size_t iScoresToInspect ="
  "high-score inspection remains size_t-safe")
require_contains(
  "${stage_stats_source}"
  "std::numeric_limits<unsigned int>::max()"
  "minimum miss combo uses the full unsigned range")
require_contains(
  "${player_stats_source}"
  "return MakePercentScore(m_iCurPossibleDancePoints, m_iPossibleDancePoints);"
  "current maximum percent reuses the sanitized percentage path")
require_contains(
  "${player_stats_source}"
  "m_fLifeRecord.clear();"
  "PlayerStageStats initialization clears stale life history")
require_contains(
  "${player_stats_source}"
  "m_ComboList.clear();"
  "PlayerStageStats initialization clears stale combo history")
require_contains(
  "${player_stats_source}"
  "other.m_iStepsPlayed < 0"
  "PlayerStageStats accumulation validates step cardinality before mutation")
require_contains(
  "${player_stats_source}"
  "!std::isfinite(timelineOffset)"
  "PlayerStageStats accumulation validates timeline before mutation")
require_contains(
  "${player_stats_source}"
  "void CompactLifeRecord"
  "life history is bounded outside endless courses")
require_contains(
  "${player_stats_source}"
  "double score = 0.0;"
  "lesson score accumulation uses a wide finite intermediate")
require_contains(
  "${stage_stats_source}"
  "m_pPlayedCourse = other.m_pPlayedCourse;"
  "course context is accumulated from recorded stats")
require_contains(
  "${stage_stats_source}"
  "rejected null song pointers to"
  "corrupt stages cannot desynchronize song and steps arrays")
require_contains(
  "${stage_stats_source}"
  "const Course* pCourse = m_pPlayedCourse;"
  "high-score lookup uses recorded course context")
require_contains(
  "${stage_stats_source}"
  "const Trail* pTrail = m_pPlayedTrails[p];"
  "summary ranking uses the recorded trail meter")
require_contains(
  "${stage_stats_source}"
  "const PlayerNumber master = m_RoutinePlayer.m_player_number;"
  "routine high-score paths use the recorded master")
require_contains(
  "${player_stats_source}"
  "void PlayerStageStats::SetLifeRecordAt(float fLife, float fStepsSecond) {\n  if (!std::isfinite(fLife)"
  "life history never depends on a live unrelated course")
require_not_contains(
  "${player_stats_source}"
  "CurrentCourseIsEndless"
  "bounded life and combo histories do not depend on live course state")
require_contains(
  "${player_stats_source}"
  "m_StageAward = StageAward_Invalid;\n  m_PeakComboAward = PeakComboAward_Invalid;"
  "award recalculation clears both local awards first")
require_contains(
  "${stats_manager_source}"
  "Course* currentCourse = isCourseMode ? pSS->m_pPlayedCourse : nullptr;"
  "recent score export uses recorded course context")
require_contains(
  "${stats_manager_source}"
  "const bool bMultiplayer = HasRecordedMultiPlayerStats(*pSS);"
  "profile commit and export derive multiplayer state from recorded stats")
require_contains(
  "${stats_manager_source}"
  "const std::string stageGuid = !pSS->m_sStageGuid.empty()"
  "recent score export uses the recorded stage GUID")
require_contains(
  "${stats_manager_source}"
  "std::max(0, pSS->m_player[pn].m_iStepsPlayed)"
  "player song totals use the player's recorded cardinality")
require_contains(
  "${stats_manager_source}"
  "ssreturn.m_player[p].m_radarActual[r] /= stepsPlayed;"
  "radar averages use per-player song counts")
require_contains(
  "${stats_manager_source}"
  "return HasRecordedPlayerStats(ss.m_RoutinePlayer);"
  "routine stats retain their referenced steps")
require_contains(
  "${stats_manager_source}"
  "m_CurStageStats.m_player[pn].Init(pn);"
  "unjoining preserves each PlayerStageStats slot identity")
require_contains(
  "${stats_manager_source}"
  "if (!NotesWriterSM::Write(f, *song, stepv))"
  "Padmiss export observes note serialization failures")
require_contains(
  "${stats_manager_source}"
  "if (!HasRecordedPlayerStats(p->m_CurStageStats.m_player[pn]))"
  "grade aggregation reads recorded players instead of live GameState state")
require_contains(
  "${stats_manager_source}"
  "opts.FromString(playerStats->m_HighScore.GetModifiers());"
  "Padmiss exports the recorded modifiers instead of live player options")
require_contains(
  "${stats_manager_source}"
  "if (!HasRecordedPlayerStats(stats.m_player[p]))"
  "final grade aggregation iterates recorded players")
require_contains(
  "${stage_stats_source}"
  "bool IsRoutineSharedStyleActive(const StageStats& stats)"
  "routine pass/fail uses the recorded style snapshot")
require_contains(
  "${screen_gameplay_source}"
  "m_CurStageStats.m_pPlayedCourse = GAMESTATE->m_pCurCourse;"
  "gameplay snapshots course context when stats are created")
require_contains(
  "${stage_stats_source}"
  "m_sStageGuid.clear();"
  "stage statistics own an initialized stage GUID snapshot")
require_contains(
  "${screen_evaluation_source}"
  "m_bPreviousTokenAdjustment"
  "evaluation restores the previous token-adjustment state")
require_contains(
  "${screen_evaluation_source}"
  "m_FinalEvalStageStats = STATSMAN->m_vPlayedStageStats.back();"
  "evaluation owns a stable copy of the displayed stage")
require_contains(
  "${screen_evaluation_source}"
  "m_LargeBanner.LoadFromCourse(m_pStageStats->m_pPlayedCourse);"
  "course banner uses recorded stage context")
require_not_contains(
  "${screen_evaluation_source}"
  "courseEntries = GAMESTATE->m_pCurCourse->m_vEntries.size();"
  "bonus divider never falls back to a live course")

message(STATUS "StageStats/Grade safety invariants passed")
