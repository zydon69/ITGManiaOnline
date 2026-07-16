if(NOT DEFINED ITGMANIA_SOURCE_DIR)
  message(FATAL_ERROR "ITGMANIA_SOURCE_DIR is required")
endif()

function(require_source_text relative_path expected)
  file(READ "${ITGMANIA_SOURCE_DIR}/${relative_path}" contents)
  string(FIND "${contents}" "${expected}" position)
  if(position EQUAL -1)
    message(FATAL_ERROR
      "Routine/Couple invariant missing in ${relative_path}: ${expected}")
  endif()
endfunction()

function(reject_source_text relative_path forbidden)
  file(READ "${ITGMANIA_SOURCE_DIR}/${relative_path}" contents)
  string(FIND "${contents}" "${forbidden}" position)
  if(NOT position EQUAL -1)
    message(FATAL_ERROR
      "Routine/Couple legacy behavior remains in ${relative_path}: ${forbidden}")
  endif()
endfunction()

require_source_text("src/StageStats.cpp"
  "m_RoutinePlayer.AddStats(other.m_RoutinePlayer)")
require_source_text("src/StageStats.cpp"
  "void StageStats::SynchronizeRoutineScoreToPlayers()")
require_source_text("src/StatsManager.cpp"
  "ssreturn.m_RoutinePlayer.m_radarPossible[r] /= routineStepsPlayed")
require_source_text("src/ScreenGameplay.cpp"
  "&STATSMAN->m_CurStageStats.m_RoutinePlayer")
require_source_text("src/ScreenGameplay.cpp"
  "m_RoutinePlayer.CalcAwards")
require_source_text("src/Player.cpp" "InputPlayerNumber")
require_source_text("src/Player.cpp"
  "STATSMAN->m_CurStageStats.m_player[physicalPlayer]")
require_source_text("src/NoteDataUtil.cpp"
  "Composite chart rejected: note has invalid player")
require_source_text("src/NoteDataUtil.cpp"
  "Couple chart statistics rejected: odd track count")
reject_source_text("src/NoteDataUtil.cpp" "routine_flat_split")
reject_source_text("src/NoteDataUtil.cpp" "assigned invalid player")
require_source_text("src/ScreenSelectMusic.cpp"
  "Routine timer fallback synchronized both players")
require_source_text("src/GameManager.cpp"
  "{\"pump-routine\", 10, false, StepsTypeCategory_Routine}")
require_source_text(
  "Themes/Simply Love/BGAnimations/ScreenSelectMusic overlay/SortMenu/default.lua"
  "stepsType:find(\"routine\", 1, true)")
require_source_text(
  "Themes/Simply Love/BGAnimations/ScreenEvaluation common/Shared/AutoSubmitScore.lua"
  "reason=routine_shared_score_unsupported")
require_source_text(
  "Themes/Simply Love/BGAnimations/ScreenSelectMusic overlay/PerPlayer/DensityGraph.lua"
  "if p1 == nil or p2 == nil or p1 < 0 or p2 < 0 then return -1 end")

message(STATUS "Routine/Couple source invariants verified")
