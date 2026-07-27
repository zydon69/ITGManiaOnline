if(NOT DEFINED ITGMANIA_SOURCE_DIR)
  message(FATAL_ERROR "ITGMANIA_SOURCE_DIR is required")
endif()

function(require_source_text source_file expected description)
  file(READ "${ITGMANIA_SOURCE_DIR}/${source_file}" source)
  string(FIND "${source}" "${expected}" offset)
  if(offset EQUAL -1)
    message(FATAL_ERROR
      "Failed score freeze invariant missing (${description}) in ${source_file}")
  endif()
endfunction()

foreach(callback
    AddScoreInternal
    HandleTapScoreNone
    HandleTapScore
    HandleHoldCheckpointScore
    HandleTapNoteScoreInternal
    HandleComboInternal
    HandleRowComboInternal
    HandleTapRowScore
    HandleHoldScore)
  require_source_text(
    "src/ScoreKeeperNormal.cpp"
    "CanMutateScore(\"ScoreKeeperNormal::${callback}\")"
    "normal scorekeeper callback ${callback} must stop after fail")
endforeach()

foreach(callback
    HandleTapScore
    HandleTapRowScore
    HandleHoldScore
    HandleTapScoreNone
    AddSuperMeterDelta)
  require_source_text(
    "src/ScoreKeeperRave.cpp"
    "CanMutateScore(\"ScoreKeeperRave::${callback}\")"
    "rave scorekeeper callback ${callback} must stop after fail")
endforeach()

require_source_text(
  "src/Player.cpp"
  "if (m_pPlayerStageStats != nullptr && m_pPlayerStageStats->m_bFailed) {"
  "player callbacks must stop mutating result state after fail")
require_source_text(
  "src/Player.cpp"
  "void Player::IncrementComboOrMissCombo(bool bComboOrMissCombo) {\n  if (m_pPlayerStageStats != nullptr && m_pPlayerStageStats->m_bFailed) {"
  "roll and immediate hold combo paths must stop after fail")
require_source_text(
  "src/ScreenGameplay.cpp"
  "pss->m_bFailed = true;\n        if (bSharedSidesLifeMeter) {\n          PropagateSharedSidesFailure"
  "individual and shared scoring states must fail before publication")
require_source_text(
  "src/ScreenGameplay.cpp"
  "PropagateSharedSidesFailure(pn, \"ScreenGameplay::Update fail check\");\n        }\n        if (GetITGOnlineIsActive()"
  "shared failure propagation must precede online final publication")
require_source_text(
  "Themes/Simply Love/Scripts/SL-ITGOnlineClient.lua"
  "snapshot.frozen == true or snapshot.Frozen == true"
  "online transport must recognize immutable failed snapshots")
require_source_text(
  "Themes/Simply Love/Scripts/SL-ITGOnlineClient.lua"
  "judgments = self:CopyServerJudgments(snapshot.judgments or snapshot.Judgments)"
  "online transport must use the frozen judgment table")
require_source_text(
  "Themes/Simply Love/Scripts/02 SL-ITGOnlineScoreJudgments.lua"
  "function Judgments.freeze_once(current, frozen)"
  "online judgments must expose one-shot freezing")
require_source_text(
  "Themes/Simply Love/BGAnimations/ScreenGameplay overlay/TrackExScoreJudgments.lua"
  "return stats and not stats:GetFailed()"
  "EX and HardEX counters must freeze in songs and courses")
require_source_text(
  "Themes/Simply Love/BGAnimations/ScreenGameplay overlay/TrackExScoreJudgments.lua"
  "storage.ex_counts.W0_total = storage.ex_counts.W0_total + 1"
  "FA+ W0 totals must use the failed-player guard")
require_source_text(
  "Themes/Simply Love/BGAnimations/ScreenGameplay overlay/TrackExScoreJudgments.lua"
  "storage.ex_counts.W010_total = storage.ex_counts.W010_total + 1"
  "HardEX W010 totals must use the failed-player guard")
require_source_text(
  "Themes/Simply Love/BGAnimations/ScreenGameplay overlay/PerColumnJudgmentTracking.lua"
  "if stats and not stats:GetFailed() then"
  "per-column evaluation judgments must freeze after fail")
require_source_text(
  "Themes/Simply Love/BGAnimations/ScreenGameplay overlay/JudgmentOffsetTracking.lua"
  "if not stats or stats:GetFailed() then return end"
  "evaluation offsets and misses must freeze after fail")
