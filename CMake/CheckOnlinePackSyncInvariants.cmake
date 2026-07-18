if(NOT DEFINED ITGMANIA_SOURCE_DIR)
  message(FATAL_ERROR "ITGMANIA_SOURCE_DIR is required")
endif()

file(
  READ
  "${ITGMANIA_SOURCE_DIR}/Themes/Simply Love/Scripts/SL-OnlinePackSync.lua"
  ONLINE_PACK_SYNC_TEXT)
file(
  READ
  "${ITGMANIA_SOURCE_DIR}/Themes/Simply Love/Scripts/SL-ITGOnlineClient.lua"
  ONLINE_CLIENT_TEXT)
file(
  READ
  "${ITGMANIA_SOURCE_DIR}/Themes/Simply Love/BGAnimations/ScreenOnlineLobbies overlay/default.lua"
  ONLINE_LOBBY_OVERLAY_TEXT)
file(
  READ
  "${ITGMANIA_SOURCE_DIR}/Themes/Simply Love/BGAnimations/ScreenPlayerOptions common.lua"
  ONLINE_PLAYER_OPTIONS_TEXT)
file(
  READ
  "${ITGMANIA_SOURCE_DIR}/Themes/Simply Love/metrics.ini"
  SIMPLY_LOVE_METRICS_TEXT)
file(
  READ
  "${ITGMANIA_SOURCE_DIR}/src/NetworkManager.cpp"
  NETWORK_MANAGER_TEXT)
file(
  READ
  "${ITGMANIA_SOURCE_DIR}/src/RageFileManager.cpp"
  RAGE_FILE_MANAGER_TEXT)

foreach(REQUIRED_SNIPPET
    "statusPostPendingIntent"
    "statusPostActiveRequestToken"
    "client_local_scan_status"
    "reused successful local chart scan"
    "lastTerminalApplyKey"
    "lastTerminalApplyStatus"
    "Room snapshots can repeat without changing either the selected chart"
    "Transport, parser, and SONGMAN availability failures are transient"
    "ignored stale pack status response"
    "lastMarkLobbyReadyCompletedKey"
    "MarkLobbyReady skipped reason=already_acknowledged"
    "downloadAttemptFailed"
    "maxDownloadBytes = maxDownloadBytes"
    "AwaitingPackChoice"
    "catalog resolved a single candidate; starting transfer"
    "SMO parallel lookup resolved"
    "NETWORK:ProcessPackArchive"
    "errorCode == \"hash_mismatch\""
    "download_archive_verified"
    "local expectedArchiveHash = \"\""
    "download_callback_exception"
    "download_reload_requested"
    "self.activeBrowseOnlyDownload == true"
    "SRC_REVIEW_TRACE [OnlinePackSync]")
  string(FIND "${ONLINE_PACK_SYNC_TEXT}" "${REQUIRED_SNIPPET}" SNIPPET_OFFSET)
  if(SNIPPET_OFFSET EQUAL -1)
    message(
      FATAL_ERROR
      "Online pack-sync invariant failed: missing '${REQUIRED_SNIPPET}'")
  endif()
endforeach()

foreach(REQUIRED_SNIPPET
    "maxArchiveUncompressedBytes = 5 * 1024 * 1024 * 1024"
    "static_cast<mz_uint64>(5) * 1024 * 1024 * 1024"
    "Unknown = \"unknown\"")
  string(FIND "${ONLINE_PACK_SYNC_TEXT}${RAGE_FILE_MANAGER_TEXT}" "${REQUIRED_SNIPPET}" SNIPPET_OFFSET)
  if(SNIPPET_OFFSET EQUAL -1)
    message(FATAL_ERROR "Online pack bounds invariant failed: missing '${REQUIRED_SNIPPET}'")
  endif()
endforeach()

foreach(FORBIDDEN_SNIPPET
    "local function copy_directory_recursive"
    "Idle = \"idle\""
    "Unknown = \"idle\"")
  string(FIND "${ONLINE_PACK_SYNC_TEXT}" "${FORBIDDEN_SNIPPET}" SNIPPET_OFFSET)
  if(NOT SNIPPET_OFFSET EQUAL -1)
    message(FATAL_ERROR "Online pack invariant failed: forbidden '${FORBIDDEN_SNIPPET}'")
  endif()
endforeach()

foreach(REQUIRED_SNIPPET
    "NormalizeOnlineArchivePaths"
    "CryptManager::GetSHA256ForFile(archivePath, shouldCancel)"
    "FILEMAN->Unzip("
    "requestArgs->cancel.load()"
    "FILEMAN->DeleteRecursive(targetPath)")
  string(FIND "${NETWORK_MANAGER_TEXT}" "${REQUIRED_SNIPPET}" SNIPPET_OFFSET)
  if(SNIPPET_OFFSET EQUAL -1)
    message(
      FATAL_ERROR
      "Online pack archive worker invariant failed: missing '${REQUIRED_SNIPPET}'")
  endif()
endforeach()

foreach(REQUIRED_SNIPPET
    "heartbeat_room_not_available"
    "presence_open_room_required"
    "ignored stale heartbeat response"
    "heartbeat_status_normalized"
    "config_ready_song_context_mismatch"
    "config_ready_options_payload_error"
    "room_selected_song_chart_match"
    "pendingOnlineOptionSelectionKey"
    "config_ready_terminal_context_mismatch"
    "new_song_while_evaluation_song_unavailable"
    "mark_failed_early_round_resolved"
    "song_availability_enforce_screen"
    "ValidateSongForOnlineSelection"
    "unsupported_audio_format"
    "room_snapshot_screen_enforcement"
    "navigate_retargeted_in_flight_transition"
    "evaluation_options_redirect_via_lobby"
    "evaluation_room_navigation_direct"
    "lobby_enter_navigation_direct"
    "EstimatedServerTimeMilliseconds"
    "profile-guid:v2:"
    "stored_token_binding_user_mismatch"
    "stored token ignored reason=profile_binding_missing_or_invalid"
    "SRC_REVIEW_TRACE [ITGOnline]")
  string(FIND "${ONLINE_CLIENT_TEXT}" "${REQUIRED_SNIPPET}" SNIPPET_OFFSET)
  if(SNIPPET_OFFSET EQUAL -1)
    message(
      FATAL_ERROR
      "Online heartbeat invariant failed: missing '${REQUIRED_SNIPPET}'")
  endif()
endforeach()

string(FIND "${ONLINE_CLIENT_TEXT}" "lower(chartHash)" INVALID_GLOBAL_LOWER_OFFSET)
if(NOT INVALID_GLOBAL_LOWER_OFFSET EQUAL -1)
  message(FATAL_ERROR "Online ready invariant failed: undefined global lower() used for chart hash")
endif()

foreach(REQUIRED_SNIPPET
    "online_options_timer_update_scheduled"
    "if actor and not online_options_timer_update_scheduled"
    "self:sleep(0.25):queuecommand(\"UpdateOptionsReadyTimer\")")
  string(FIND "${ONLINE_PLAYER_OPTIONS_TEXT}" "${REQUIRED_SNIPPET}" SNIPPET_OFFSET)
  if(SNIPPET_OFFSET EQUAL -1)
    message(FATAL_ERROR "Online options timer invariant failed: missing '${REQUIRED_SNIPPET}'")
  endif()
endforeach()

string(FIND "${ONLINE_LOBBY_OVERLAY_TEXT}" "refresh_then_server_authoritative_join" JOIN_PREFLIGHT_OFFSET)
if(JOIN_PREFLIGHT_OFFSET EQUAL -1)
  message(FATAL_ERROR "Online join preflight invariant failed")
endif()

foreach(REQUIRED_SNIPPET
    "terminal_download_status_is_not_preview_state"
    "browse_reload_status_not_acknowledged"
    "Release the download guard before availability is"
    "FinalizeDownloadedSelectedSongAvailability"
    "Selected availability retry scheduled")
  string(FIND "${ONLINE_PACK_SYNC_TEXT}" "${REQUIRED_SNIPPET}" SNIPPET_OFFSET)
  if(SNIPPET_OFFSET EQUAL -1)
    message(FATAL_ERROR "Online pack completion invariant failed: missing '${REQUIRED_SNIPPET}'")
  endif()
endforeach()

foreach(REQUIRED_SNIPPET
    "join_room_prefetch_rejected reason=room_no_longer_accepting"
    "preflightRejected = true")
  string(FIND "${ONLINE_CLIENT_TEXT}" "${REQUIRED_SNIPPET}" SNIPPET_OFFSET)
  if(SNIPPET_OFFSET EQUAL -1)
    message(FATAL_ERROR "Online join preflight rejection invariant failed: missing '${REQUIRED_SNIPPET}'")
  endif()
endforeach()

foreach(REQUIRED_SNIPPET
    "Retrying \" .. (browseOnly and \"browse-only\" or \"selected-song\")"
    "PostReload completion acknowledgement failed; retaining transfer identity"
    "Stale-selection completion acknowledgement failed; retaining transfer identity")
  string(FIND "${ONLINE_PACK_SYNC_TEXT}" "${REQUIRED_SNIPPET}" SNIPPET_OFFSET)
  if(SNIPPET_OFFSET EQUAL -1)
    message(FATAL_ERROR "Online pack completion retry invariant failed: missing '${REQUIRED_SNIPPET}'")
  endif()
endforeach()

foreach(REQUIRED_SNIPPET
    "review_src,ResetLogs"
    "Linereview_src=\"conf,review_src\"")
  string(FIND "${SIMPLY_LOVE_METRICS_TEXT}" "${REQUIRED_SNIPPET}" SNIPPET_OFFSET)
  if(SNIPPET_OFFSET EQUAL -1)
    message(
      FATAL_ERROR
      "Simply Love review-src option invariant failed: missing '${REQUIRED_SNIPPET}'")
  endif()
endforeach()
