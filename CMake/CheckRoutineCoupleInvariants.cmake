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
require_source_text("src/StageStats.cpp"
  "m_RoutinePlayer.m_HighScore.Unset()")
require_source_text("src/StatsManager.cpp"
  "ssreturn.m_RoutinePlayer.m_radarPossible[r] /= routineStepsPlayed")
require_source_text("src/ScreenGameplay.cpp"
  "&STATSMAN->m_CurStageStats.m_RoutinePlayer")
require_source_text("src/ScreenGameplay.cpp"
  "m_RoutinePlayer.CalcAwards")
require_source_text("src/ScreenGameplayShared.cpp"
  "component=gameplay_shared event=player_info_loaded")
reject_source_text("src/ScreenGameplayShared.cpp"
  "vPlayerInfoOut[other].Load")
require_source_text("src/GameState.cpp"
  "component=game_state event=options_synchronized")
require_source_text("src/GameSoundManager.cpp"
  "StyleType_TwoPlayersSharedSides")
require_source_text("src/EditModePlayerManager.h"
  "bool center_ = false")
require_source_text("src/EditModePlayerManager.cpp"
  "players_.find(master)")
require_source_text("src/ScreenEdit.cpp"
  "Routine mirror preserved occupied destination")
require_source_text("src/Player.cpp" "InputPlayerNumber")
require_source_text("src/Player.cpp"
  "STATSMAN->m_CurStageStats.m_player[physicalPlayer]")
require_source_text("src/Player.cpp"
  "GameI[i].controller")
require_source_text("src/NoteDataUtil.cpp"
  "Composite chart rejected: note has invalid player")
require_source_text("src/NoteDataUtil.cpp"
  "bool NoteDataUtil::CombineCompositeNoteData")
require_source_text("src/NoteDataUtil.cpp"
  "note.pn = owner")
require_source_text("src/NoteDataUtil.cpp"
  "transformed parts could not be recombined safely")
require_source_text("src/NoteDataUtil.cpp"
  "Routine transform skipped ambiguous inserted tap")
require_source_text("src/NoteDataUtil.cpp"
  "Couple chart statistics rejected: odd track count")
reject_source_text("src/NoteDataUtil.cpp" "routine_flat_split")
reject_source_text("src/NoteDataUtil.cpp" "assigned invalid player")
require_source_text("src/ScreenSelectMusic.cpp"
  "component=select_music event=timer_sync mode=routine")
require_source_text("src/PerfDiagnostics.cpp"
  "ROUTINE_COUPLE_TRACE %s")
require_source_text("Themes/Simply Love/Scripts/SL-Helpers.lua"
  "ROUTINE_COUPLE_TRACE component=theme")
require_source_text("src/GameManager.cpp"
  "{\"pump-routine\", 10, false, StepsTypeCategory_Routine}")
require_source_text(
  "Themes/Simply Love/BGAnimations/ScreenSelectMusic overlay/SortMenu/default.lua"
  "stepsType:find(\"routine\", 1, true)")
require_source_text(
  "Themes/Simply Love/BGAnimations/ScreenEvaluation common/Shared/AutoSubmitScore.lua"
  "reason=routine_shared_score_unsupported")
require_source_text(
  "Themes/Simply Love/BGAnimations/ScreenGameplay overlay/JudgmentOffsetTracking.lua"
  "if routine_shared and player ~= source_player then return end")
require_source_text(
  "Themes/Simply Love/BGAnimations/ScreenGameplay overlay/PerColumnJudgmentTracking.lua"
  "SL[target].Stages.Stats[stage_index].column_judgments = judgments")
require_source_text(
  "Themes/Simply Love/BGAnimations/ScreenSelectMusic overlay/PerPlayer/DensityGraph.lua"
  "if p1 == nil or p2 == nil or p1 < 0 or p2 < 0 then return -1 end")
require_source_text(
  "Themes/Simply Love/BGAnimations/ScreenGameplay underlay/PerPlayer/LifeMeter/Standard.lua"
  "local source_player = is_shared_sides and GAMESTATE:GetMasterPlayerNumber() or player")
require_source_text(
  "Themes/Simply Love/BGAnimations/ScreenGameplay underlay/PerPlayer/LifeMeter/Surround.lua"
  "if params.Player == source_player then")
require_source_text(
  "Themes/Simply Love/BGAnimations/ScreenGameplay underlay/PerPlayer/LifeMeter/Vertical.lua"
  "local songposition = GAMESTATE:GetPlayerState(source_player):GetSongPosition()")
require_source_text(
  "Themes/Simply Love/BGAnimations/ScreenEvaluation common/Panes/default.lua"
  "MakeLazyPane(i, mpn, PLAYER_2, ComputedData)")
require_source_text(
  "Themes/Simply Love/BGAnimations/ScreenEvaluation common/InputHandler.lua"
  "if #players==1 or routine_shared then")
require_source_text(
  "Themes/Simply Love/BGAnimations/ScreenEvaluation common/InputHandler.lua"
  "if style == \"OnePlayerTwoSides\" or routine_shared then")
require_source_text("Themes/Simply Love/metrics.ini"
  "((IsRoutine and IsRoutine()) or #GAMESTATE:GetHumanPlayers()==1) and 610 or 300")
require_source_text(
  "Themes/Simply Love/BGAnimations/ScreenEvaluation common/Panes/Pane5/default.lua"
  "THEME:GetString(\"ScreenEvaluation\", \"Early\")")
require_source_text(
  "Themes/Simply Love/BGAnimations/ScreenEvaluation common/Panes/Pane5/default.lua"
  "THEME:GetString(\"ScreenEvaluation\", \"MeanTimingError\")")
require_source_text(
  "Themes/Simply Love/BGAnimations/ScreenEvaluation common/Panes/Pane5/default.lua"
  "THEME:GetString(\"ScreenEvaluation\", \"MeanOffset\")")
require_source_text(
  "Themes/Simply Love/BGAnimations/ScreenEvaluation common/Panes/Pane5/default.lua"
  "THEME:GetString(\"ScreenEvaluation\", \"StdDev\")")
require_source_text(
  "Themes/Simply Love/BGAnimations/ScreenEvaluation common/Panes/Pane5/default.lua"
  "THEME:GetString(\"ScreenEvaluation\", \"MaxError\")")
reject_source_text(
  "Themes/Simply Love/BGAnimations/ScreenEvaluation common/Panes/Pane5/default.lua"
  "ScreenString(")
require_source_text(
  "Themes/Simply Love/BGAnimations/ScreenEvaluation common/PerPlayer/Upper/RecordTexts.lua"
  "THEME:GetString(\"ScreenEvaluation\", \"MachineRecord\")")
require_source_text(
  "Themes/Simply Love/BGAnimations/ScreenEvaluation common/PerPlayer/Upper/RecordTexts.lua"
  "THEME:GetString(\"ScreenEvaluation\", \"PersonalRecord\")")
reject_source_text(
  "Themes/Simply Love/BGAnimations/ScreenEvaluation common/PerPlayer/Upper/RecordTexts.lua"
  "ScreenString(")
require_source_text(
  "Themes/Simply Love/BGAnimations/ScreenGameplay underlay/PerPlayer/NoteField/DisplayMods.lua"
  "GetPlayerOptionsString(sourcePlayer, \"ModsLevel_Current\")")
require_source_text("Themes/Simply Love/Scripts/SL-Helpers.lua"
  "safe_method(\"PlayerOptions.Mini\", playerOptionsObject, \"Mini\")")
require_source_text("src/NoteDataUtil.cpp"
  "static int CountTapNotesWithoutTiming(const NoteData& noteData)")
require_source_text("src/NoteDataUtil.cpp"
  "CountTapNotesWithoutTiming(out[PLAYER_1])")
reject_source_text("src/NoteDataUtil.cpp"
  "out[PLAYER_1].GetNumTapNotes()")
require_source_text("src/Steps.cpp"
  "vParts[pn].GetNumTapNotes(0, MAX_NOTE_ROW, timing)")
reject_source_text("src/Steps.cpp"
  "vParts[pn].GetNumTapNotes()")

message(STATUS "Routine/Couple source invariants verified")
