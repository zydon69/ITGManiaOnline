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
  "${ITGMANIA_SOURCE_DIR}/Themes/Simply Love/metrics.ini"
  SIMPLY_LOVE_METRICS_TEXT)

foreach(REQUIRED_SNIPPET
    "statusPostPendingIntent"
    "statusPostActiveRequestToken"
    "client_local_scan_status"
    "reused successful local chart scan"
    "ignored stale pack status response"
    "SRC_REVIEW_TRACE [OnlinePackSync]")
  string(FIND "${ONLINE_PACK_SYNC_TEXT}" "${REQUIRED_SNIPPET}" SNIPPET_OFFSET)
  if(SNIPPET_OFFSET EQUAL -1)
    message(
      FATAL_ERROR
      "Online pack-sync invariant failed: missing '${REQUIRED_SNIPPET}'")
  endif()
endforeach()

foreach(REQUIRED_SNIPPET
    "heartbeat_room_not_available"
    "presence_open_room_required"
    "ignored stale heartbeat response"
    "SRC_REVIEW_TRACE [ITGOnline]")
  string(FIND "${ONLINE_CLIENT_TEXT}" "${REQUIRED_SNIPPET}" SNIPPET_OFFSET)
  if(SNIPPET_OFFSET EQUAL -1)
    message(
      FATAL_ERROR
      "Online heartbeat invariant failed: missing '${REQUIRED_SNIPPET}'")
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
