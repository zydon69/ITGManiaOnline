if(NOT DEFINED ITGMANIA_SOURCE_DIR)
  message(FATAL_ERROR "ITGMANIA_SOURCE_DIR is required")
endif()

set(NETWORK_MANAGER_SOURCE
    "${ITGMANIA_SOURCE_DIR}/src/NetworkManager.cpp")
file(READ "${NETWORK_MANAGER_SOURCE}" NETWORK_MANAGER_TEXT)

foreach(REQUIRED_SNIPPET
    "IsExpectedInactiveWebSocketTerminalMessage"
    "type == ix::WebSocketMessageType::Close"
    "type == ix::WebSocketMessageType::Error"
    "lua_websocket_inactive_terminal_drop"
    "if (IsExpectedInactiveWebSocketTerminalMessage(msg.type))"
    "url=%s reason=inactive type=%s"
    "queuedTasks > kBacklogAdaptiveThreshold * 4"
    "queuedTasks >= kBacklogAdaptiveThreshold"
    "useDownloadClient ? effectiveMaxDownloadBytes"
    "kMaxDownloadBytes = 5LL * 1024LL * 1024LL * 1024LL"
    "std::atomic<int64_t> latestProgressCurrent")
  string(FIND "${NETWORK_MANAGER_TEXT}" "${REQUIRED_SNIPPET}" SNIPPET_OFFSET)
  if(SNIPPET_OFFSET EQUAL -1)
    message(
        FATAL_ERROR
        "NetworkManager invariant failed: missing '${REQUIRED_SNIPPET}'")
  endif()
endforeach()

string(FIND
    "${NETWORK_MANAGER_TEXT}"
    "if (IsExpectedInactiveWebSocketTerminalMessage(msg.type))"
    TERMINAL_GUARD_OFFSET)
string(FIND
    "${NETWORK_MANAGER_TEXT}"
    "url=%s reason=inactive type=%s"
    INACTIVE_TYPE_TRACE_OFFSET)

if(TERMINAL_GUARD_OFFSET GREATER INACTIVE_TYPE_TRACE_OFFSET)
  message(
      FATAL_ERROR
      "NetworkManager inactive websocket terminal filter must run before the type-bearing inactive drop trace")
endif()
