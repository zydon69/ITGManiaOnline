if(NOT DEFINED ITGMANIA_SOURCE_DIR)
  message(FATAL_ERROR "ITGMANIA_SOURCE_DIR is required")
endif()

set(SCREEN_GAMEPLAY_SOURCE
    "${ITGMANIA_SOURCE_DIR}/src/ScreenGameplay.cpp")
file(READ "${SCREEN_GAMEPLAY_SOURCE}" SCREEN_GAMEPLAY_TEXT)

string(FIND
    "${SCREEN_GAMEPLAY_TEXT}"
    "pi->m_vpStepsQueue[i]->m_pSong != songs[i]"
    COURSE_QUEUE_ASSOCIATION_OFFSET)
if(COURSE_QUEUE_ASSOCIATION_OFFSET EQUAL -1)
  message(
      FATAL_ERROR
      "ScreenGameplay invariant failed: steps queues must remain associated with their songs")
endif()

set(GAMEPLAY_ASSIST_SOURCE
    "${ITGMANIA_SOURCE_DIR}/src/GameplayAssist.cpp")
file(READ "${GAMEPLAY_ASSIST_SOURCE}" GAMEPLAY_ASSIST_TEXT)

set(ONLINE_HELPERS_SOURCE
    "${ITGMANIA_SOURCE_DIR}/Themes/Simply Love/Scripts/SL-OnlineHelpers.lua")
file(READ "${ONLINE_HELPERS_SOURCE}" ONLINE_HELPERS_TEXT)

set(ONLINE_CLIENT_SOURCE
    "${ITGMANIA_SOURCE_DIR}/Themes/Simply Love/Scripts/SL-ITGOnlineClient.lua")
file(READ "${ONLINE_CLIENT_SOURCE}" ONLINE_CLIENT_TEXT)

set(SCREEN_GAMEPLAY_HEADER
    "${ITGMANIA_SOURCE_DIR}/src/ScreenGameplay.h")
file(READ "${SCREEN_GAMEPLAY_HEADER}" SCREEN_GAMEPLAY_HEADER_TEXT)

set(TRACK_FAIL_TIME_SOURCE
    "${ITGMANIA_SOURCE_DIR}/Themes/Simply Love/BGAnimations/ScreenGameplay overlay/TrackFailTime.lua")
file(READ "${TRACK_FAIL_TIME_SOURCE}" TRACK_FAIL_TIME_TEXT)

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
    "MarkITGOnlineFailedEarly(PlayerNumber pn)"
    "pn == PLAYER_2 ? \"PLAYER_2\" : \"PLAYER_1\""
    "MarkLocalPlayerFailedEarly(%s"
    "m_bMarkedOnlineFailedEarly[pn]")
  string(FIND "${SCREEN_GAMEPLAY_TEXT}" "${REQUIRED_SNIPPET}" SNIPPET_OFFSET)
  if(SNIPPET_OFFSET EQUAL -1)
    message(
        FATAL_ERROR
        "ScreenGameplay online failure identity invariant failed: missing '${REQUIRED_SNIPPET}'")
  endif()
endforeach()

string(FIND
    "${SCREEN_GAMEPLAY_HEADER_TEXT}"
    "bool m_bMarkedOnlineFailedEarly[NUM_PLAYERS];"
    PER_PLAYER_FAILED_GUARD_OFFSET)
if(PER_PLAYER_FAILED_GUARD_OFFSET EQUAL -1)
  message(
      FATAL_ERROR
      "ScreenGameplay online failure identity invariant failed: the early-failure guard must be per-player")
endif()

string(FIND "${TRACK_FAIL_TIME_TEXT}" "MarkPlayFailedEarly" THEME_FAILED_EVENT_OFFSET)
if(NOT THEME_FAILED_EVENT_OFFSET EQUAL -1)
  message(
      FATAL_ERROR
      "ScreenGameplay online failure identity invariant failed: TrackFailTime must not duplicate the engine event")
endif()

string(FIND
    "${SCREEN_GAMEPLAY_TEXT}"
    "if (m_bPaused) {\n    /* If we're paused"
    PAUSE_GATE_OFFSET)
string(FIND "${SCREEN_GAMEPLAY_TEXT}" "Message msg(\"\");" CODE_INPUT_OFFSET)
if(PAUSE_GATE_OFFSET EQUAL -1 OR CODE_INPUT_OFFSET EQUAL -1 OR
   CODE_INPUT_OFFSET LESS PAUSE_GATE_OFFSET)
  message(
      FATAL_ERROR
      "ScreenGameplay input invariant failed: gameplay codes must run after the pause gate")
endif()

foreach(REQUIRED_SNIPPET
    "p.m_fSpeed <= 0.0f"
    "UpdateSongPosition rejected audio position/adjustment"
    "static_cast<double>(fSeconds) + static_cast<double>(fAdjust)"
    "scale_from_low == scale_from_high"
    "Reset non-finite gameplay haste adjustment")
  string(FIND "${SCREEN_GAMEPLAY_TEXT}" "${REQUIRED_SNIPPET}" SNIPPET_OFFSET)
  if(SNIPPET_OFFSET EQUAL -1)
    message(
        FATAL_ERROR
        "ScreenGameplay numeric invariant failed: missing '${REQUIRED_SNIPPET}'")
  endif()
endforeach()

foreach(REQUIRED_SNIPPET
    "THEME->IsThemeLoaded() && LUA != nullptr"
    "IncrementGameplayCount"
    "AccumulateGameplaySeconds"
    "AccumulateSignedGameplaySeconds"
    "ScreenGameplay::SetupSong preflight"
    "const double lengthSeconds ="
    "const double lastStepWithJudgment ="
    "const float musicLength = FiniteNonNegativeOr"
    "const double transitionForFade =")
  string(FIND "${SCREEN_GAMEPLAY_TEXT}" "${REQUIRED_SNIPPET}" SNIPPET_OFFSET)
  if(SNIPPET_OFFSET EQUAL -1)
    message(
        FATAL_ERROR
        "ScreenGameplay hardening invariant failed: missing '${REQUIRED_SNIPPET}'")
  endif()
endforeach()

string(FIND
    "${SCREEN_GAMEPLAY_TEXT}"
    "ASSERT(!m_pSoundMusic->IsPlaying())"
    PLAYING_SOUND_ASSERT_OFFSET)
if(NOT PLAYING_SOUND_ASSERT_OFFSET EQUAL -1)
  message(
      FATAL_ERROR
      "ScreenGameplay hardening invariant failed: playing sounds must be recovered at runtime")
endif()

foreach(REQUIRED_SNIPPET
    "HasCoreGameplayManagers(\"ScreenGameplay::Update\")"
    "GetPathS(m_sName, \"oni die\", true)"
    "constexpr int kMaxCrossedRowsPerUpdate"
    "t >= pStyle->m_iColsPerPlayer"
    "Song* const playedSong = GAMESTATE->m_pCurSong"
    "GAMESTATE->m_pCurSong.Set(playedSong)"
    "GAMESTATE->m_pCurTrail[snapshot.pn].Set(nullptr)")
  string(FIND "${SCREEN_GAMEPLAY_TEXT}" "${REQUIRED_SNIPPET}" SNIPPET_OFFSET)
  if(SNIPPET_OFFSET EQUAL -1)
    message(
        FATAL_ERROR
        "ScreenGameplay lifecycle invariant failed: missing '${REQUIRED_SNIPPET}'")
  endif()
endforeach()

foreach(REQUIRED_SNIPPET
    "std::vector<RepeatPlayerQueue> repeatedPlayerQueues"
    "entry.pSong != repeatedSongs[entryIndex]"
    "leaving gameplay before appending them"
    "Profile::MakeUniqueFileNameNoExtension(replayDirectory, \"replay\")"
    "const bool saved =")
  string(FIND "${SCREEN_GAMEPLAY_TEXT}" "${REQUIRED_SNIPPET}" SNIPPET_OFFSET)
  if(SNIPPET_OFFSET EQUAL -1)
    message(
        FATAL_ERROR
        "ScreenGameplay repeat/replay invariant failed: missing '${REQUIRED_SNIPPET}'")
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
    "ready_request_phase_race_fetch_result"
    "terminal_skipped_failed_final_score_accepted"
    "mark_failed_early_confirmed_without_terminal_post"
    "those indexes are positions, never user identifiers"
    "resultUserId ~= \"\" and resultUserId == userId"
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

string(FIND
    "${ONLINE_CLIENT_TEXT}"
    "tostring(key or \"\") == userId"
    FINAL_RESULT_INDEX_AS_USER_ID_OFFSET)
if(NOT FINAL_RESULT_INDEX_AS_USER_ID_OFFSET EQUAL -1)
  message(
      FATAL_ERROR
      "Online score identity invariant failed: final result list indexes must not be treated as user IDs")
endif()

foreach(REQUIRED_SNIPPET
    "ITGOnlineRealtimeReconnectScheduledMessageCommand"
    "realtime_reconnect_handler_armed")
  string(FIND "${ONLINE_HELPERS_TEXT}" "${REQUIRED_SNIPPET}" SNIPPET_OFFSET)
  if(SNIPPET_OFFSET EQUAL -1)
    message(
        FATAL_ERROR
        "Online live score runtime invariant failed: missing '${REQUIRED_SNIPPET}'")
  endif()
endforeach()

string(FIND
    "${ONLINE_HELPERS_TEXT}"
    "ITGOnline:FlushLiveScore"
    DUPLICATE_LIVE_SCORE_FLUSH_OFFSET)
if(NOT DUPLICATE_LIVE_SCORE_FLUSH_OFFSET EQUAL -1)
  message(
      FATAL_ERROR
      "Online live score ownership invariant failed: global room timers must not duplicate gameplay score transport")
endif()

foreach(REQUIRED_SNIPPET
    "IsLiveScoreFinalizedForCurrentRound(\"track_online_score_push\")"
    "tracker_stop reason=final_score_already_accepted"
    "_skipped reason=inactive_online_context"
    "CaptureOnlineScoreCommand"
    "self.scoreCaptureQueued"
    "ITGOnline:FlushLiveScore()"
    "HoldJudgmentMessageCommand"
    "ExCountsChangedMessageCommand")
  string(FIND "${TRACK_ONLINE_SCORE_PUSH_TEXT}" "${REQUIRED_SNIPPET}" SNIPPET_OFFSET)
  if(SNIPPET_OFFSET EQUAL -1)
    message(
        FATAL_ERROR
        "Online score tracker invariant failed: missing '${REQUIRED_SNIPPET}'")
  endif()
endforeach()

string(FIND "${ONLINE_HELPERS_TEXT}" "OnlineScoreSnapshot" LEGACY_SCORE_HELPER_OFFSET)
string(FIND "${TRACK_ONLINE_SCORE_PUSH_TEXT}" "CaptureOnlineScoreCommand" SCORE_CAPTURE_OFFSET)
if(NOT LEGACY_SCORE_HELPER_OFFSET EQUAL -1 OR SCORE_CAPTURE_OFFSET EQUAL -1)
  message(
      FATAL_ERROR
      "Online score ownership invariant failed: transport must have one capture owner and no legacy helper receiver")
endif()

string(FIND
    "${TRACK_ONLINE_SCORE_PUSH_TEXT}"
    "judgment_skipped reason=missing_context"
    LOCAL_JUDGMENT_NOISE_OFFSET)
if(NOT LOCAL_JUDGMENT_NOISE_OFFSET EQUAL -1)
  message(
      FATAL_ERROR
      "Online score tracker invariant failed: local judgments must not emit online missing-context traces")
endif()

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
    "score_cache_preserved reason=results_context_shift"
    "score_cache_reset reason=playing_context_changed")
  string(FIND "${ONLINE_LIVE_LEADERBOARD_TEXT}" "${REQUIRED_SNIPPET}" SNIPPET_OFFSET)
  if(SNIPPET_OFFSET EQUAL -1)
    message(
        FATAL_ERROR
        "Online live leaderboard invariant failed: missing '${REQUIRED_SNIPPET}'")
  endif()
endforeach()

foreach(REQUIRED_SNIPPET
    "ready_request_phase_race_fetch_stale_context"
    "selectionKeyMatches="
    "callbackReadySelectionKey == readySelectionKey"
    "room_deleted_before_coalesce"
    "terminal_round_not_resolved"
    "starting_terminal_round_pending_resolution")
  string(FIND "${ONLINE_CLIENT_TEXT}" "${REQUIRED_SNIPPET}" SNIPPET_OFFSET)
  if(SNIPPET_OFFSET EQUAL -1)
    message(
        FATAL_ERROR
        "Online client race invariant failed: missing '${REQUIRED_SNIPPET}'")
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
