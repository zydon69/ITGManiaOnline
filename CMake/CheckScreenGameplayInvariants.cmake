if(NOT DEFINED ITGMANIA_SOURCE_DIR)
  message(FATAL_ERROR "ITGMANIA_SOURCE_DIR is required")
endif()

set(SCREEN_GAMEPLAY_SOURCE
    "${ITGMANIA_SOURCE_DIR}/src/ScreenGameplay.cpp")
file(READ "${SCREEN_GAMEPLAY_SOURCE}" SCREEN_GAMEPLAY_TEXT)

set(GAMEPLAY_ASSIST_SOURCE
    "${ITGMANIA_SOURCE_DIR}/src/GameplayAssist.cpp")
file(READ "${GAMEPLAY_ASSIST_SOURCE}" GAMEPLAY_ASSIST_TEXT)

set(ONLINE_HELPERS_SOURCE
    "${ITGMANIA_SOURCE_DIR}/Themes/Simply Love/Scripts/SL-OnlineHelpers.lua")
file(READ "${ONLINE_HELPERS_SOURCE}" ONLINE_HELPERS_TEXT)

set(ONLINE_CLIENT_SOURCE
    "${ITGMANIA_SOURCE_DIR}/Themes/Simply Love/Scripts/SL-ITGOnlineClient.lua")
file(READ "${ONLINE_CLIENT_SOURCE}" ONLINE_CLIENT_TEXT)

set(ONLINE_LIVE_LEADERBOARD_SOURCE
    "${ITGMANIA_SOURCE_DIR}/Themes/Simply Love/BGAnimations/ScreenGameplay overlay/OnlineLiveLeaderboard.lua")
file(READ "${ONLINE_LIVE_LEADERBOARD_SOURCE}" ONLINE_LIVE_LEADERBOARD_TEXT)

set(TRACK_ONLINE_SCORE_PUSH_SOURCE
    "${ITGMANIA_SOURCE_DIR}/Themes/Simply Love/BGAnimations/ScreenGameplay overlay/TrackOnlineScorePush.lua")
file(READ "${TRACK_ONLINE_SCORE_PUSH_SOURCE}" TRACK_ONLINE_SCORE_PUSH_TEXT)

foreach(REQUIRED_SNIPPET
    "GetGameplayStartLeadInSeconds"
    "const float startLeadInSeconds = GetGameplayStartLeadInSeconds"
    "p.m_StartSecond = -startLeadInSeconds;"
    "p.m_StartSecond = -onlineSecondsUntilStart;"
    "lead-in %.3fs startSecond=%.3f.")
  string(FIND "${SCREEN_GAMEPLAY_TEXT}" "${REQUIRED_SNIPPET}" SNIPPET_OFFSET)
  if(SNIPPET_OFFSET EQUAL -1)
    message(
        FATAL_ERROR
        "ScreenGameplay invariant failed: missing '${REQUIRED_SNIPPET}'")
  endif()
endforeach()

foreach(REQUIRED_SNIPPET
    "lateBy > 0.03"
    "screen:SeekMusicSeconds(lateBy)"
    "release_online_gameplay_now reason=start_time_reached")
  string(FIND "${ONLINE_HELPERS_TEXT}" "${REQUIRED_SNIPPET}" SNIPPET_OFFSET)
  if(SNIPPET_OFFSET EQUAL -1)
    message(
        FATAL_ERROR
        "ScreenGameplay online helper invariant failed: missing '${REQUIRED_SNIPPET}'")
  endif()
endforeach()

foreach(REQUIRED_SNIPPET
    "snapshotScorePercent == nil or final == true"
    "snapshotExScore == nil or final == true"
    "live_score_flush_skipped reason=zero_progress_already_sent"
    "live_score_flush_skipped reason=final_score_already_accepted"
    "IsLiveScoreFinalizedForRound"
    "IsLiveScoreFinalizedForCurrentRound"
    "lastAcceptedZeroLiveScoreRoundKey"
    "ready_request_skipped reason=stale_lobby_ready_before_post"
    "ready_request_phase_race_accepted"
    "terminal_skipped_failed_final_score_accepted"
    "mark_failed_early_confirmed_without_terminal_post"
    "final_failed_snapshot_selected reason=prefer_terminal_candidate"
    "if scoreMode == \"itg\" then"
    "itgScorePercent = outgoingPercent")
  string(FIND "${ONLINE_CLIENT_TEXT}" "${REQUIRED_SNIPPET}" SNIPPET_OFFSET)
  if(SNIPPET_OFFSET EQUAL -1)
    message(
        FATAL_ERROR
        "Online score payload invariant failed: missing '${REQUIRED_SNIPPET}'")
  endif()
endforeach()

foreach(REQUIRED_SNIPPET
    "live_score_finalized_for_runtime"
    "not live_score_finalized_for_runtime()")
  string(FIND "${ONLINE_HELPERS_TEXT}" "${REQUIRED_SNIPPET}" SNIPPET_OFFSET)
  if(SNIPPET_OFFSET EQUAL -1)
    message(
        FATAL_ERROR
        "Online live score runtime invariant failed: missing '${REQUIRED_SNIPPET}'")
  endif()
endforeach()

foreach(REQUIRED_SNIPPET
    "IsLiveScoreFinalizedForCurrentRound(\"track_online_score_push\")"
    "tracker_stop reason=final_score_already_accepted")
  string(FIND "${TRACK_ONLINE_SCORE_PUSH_TEXT}" "${REQUIRED_SNIPPET}" SNIPPET_OFFSET)
  if(SNIPPET_OFFSET EQUAL -1)
    message(
        FATAL_ERROR
        "Online score tracker invariant failed: missing '${REQUIRED_SNIPPET}'")
  endif()
endforeach()

string(FIND "${ONLINE_CLIENT_TEXT}" "and self:SecondsUntilScheduledStart() == nil" NIL_SCHEDULE_HOLD_OFFSET)
if(NOT NIL_SCHEDULE_HOLD_OFFSET EQUAL -1)
  message(
      FATAL_ERROR
      "ScreenGameplay invariant failed: online starting phase must hold gameplay even when a scheduled start is known")
endif()

string(REGEX MATCH
    "if \\(GetITGOnlineShouldHoldGameplayForStart\\(\\)\\)[^{]*\\{[^}]*p\\.m_StartSecond[ \t]*=[ \t]*0\\.0f"
    HOLD_STARTS_AT_ZERO
    "${SCREEN_GAMEPLAY_TEXT}")
if(NOT HOLD_STARTS_AT_ZERO STREQUAL "")
  message(
      FATAL_ERROR
      "ScreenGameplay invariant failed: online start hold must keep the local lead-in instead of starting at 0.0")
endif()

foreach(REQUIRED_SNIPPET
    "is_session_placeholder = true"
    "last_non_empty_score_row_for_user"
    "session_placeholder_preserved_score"
    "CanonicalGameplayRoundKey(\"live_leaderboard\")"
    "score_cache_preserved reason=results_context_shift")
  string(FIND "${ONLINE_LIVE_LEADERBOARD_TEXT}" "${REQUIRED_SNIPPET}" SNIPPET_OFFSET)
  if(SNIPPET_OFFSET EQUAL -1)
    message(
        FATAL_ERROR
        "Online live leaderboard invariant failed: missing '${REQUIRED_SNIPPET}'")
  endif()
endforeach()

foreach(REQUIRED_SNIPPET
    "sound != nullptr && sound->IsPlaying()"
    "m_bNotesEndedQueued"
    "!m_NextSong.IsTransitioning() && !m_bNotesEndedQueued")
  string(FIND "${SCREEN_GAMEPLAY_TEXT}" "${REQUIRED_SNIPPET}" SNIPPET_OFFSET)
  if(SNIPPET_OFFSET EQUAL -1)
    message(
        FATAL_ERROR
        "ScreenGameplay notes-ended invariant failed: missing '${REQUIRED_SNIPPET}'")
  endif()
endforeach()

foreach(REQUIRED_SNIPPET
    "static void StopIfPlaying(RageSound& sound)"
    "if (sound.IsPlaying())"
    "StopIfPlaying(m_soundAssistClap)"
    "StopIfPlaying(m_soundAssistMetronomeMeasure)"
    "StopIfPlaying(m_soundAssistMetronomeBeat)")
  string(FIND "${GAMEPLAY_ASSIST_TEXT}" "${REQUIRED_SNIPPET}" SNIPPET_OFFSET)
  if(SNIPPET_OFFSET EQUAL -1)
    message(
        FATAL_ERROR
        "GameplayAssist invariant failed: missing '${REQUIRED_SNIPPET}'")
  endif()
endforeach()
