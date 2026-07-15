if(NOT DEFINED ITGMANIA_SOURCE_DIR)
  message(FATAL_ERROR "ITGMANIA_SOURCE_DIR is required")
endif()

set(NETWORK_MANAGER_SOURCE
    "${ITGMANIA_SOURCE_DIR}/src/NetworkManager.cpp")
file(READ "${NETWORK_MANAGER_SOURCE}" NETWORK_MANAGER_TEXT)
file(
  READ
  "${ITGMANIA_SOURCE_DIR}/src/SecureCredentialStore.cpp"
  SECURE_CREDENTIAL_STORE_TEXT)
file(
  READ
  "${ITGMANIA_SOURCE_DIR}/Themes/Simply Love/Scripts/SL-ITGOnlineClient.lua"
  ONLINE_CLIENT_TEXT)

foreach(REQUIRED_SNIPPET
    "IsExpectedInactiveWebSocketTerminalMessage"
    "type == ix::WebSocketMessageType::Close"
    "type == ix::WebSocketMessageType::Error"
    "lua_websocket_inactive_terminal_drop"
    "if (IsExpectedInactiveWebSocketTerminalMessage(msg.type))"
    "url=%s reason=inactive type=%s"
    "queuedTasks > kBacklogAdaptiveThreshold * 4"
    "queuedTasks >= kBacklogAdaptiveThreshold"
    "effectiveMaxDownloadBytes"
    "kMaxDownloadBytes = 5LL * 1024LL * 1024LL * 1024LL"
    "std::atomic<int64_t> latestProgressCurrent"
    "LEGACY_GROOVESTATS_QR_LOGIN_HOST"
    "protocol == \"ws\" && host == LEGACY_GROOVESTATS_QR_LOGIN_HOST"
    "HttpDenyHosts remains authoritative above")
  string(FIND "${NETWORK_MANAGER_TEXT}" "${REQUIRED_SNIPPET}" SNIPPET_OFFSET)
  if(SNIPPET_OFFSET EQUAL -1)
    message(
        FATAL_ERROR
        "NetworkManager invariant failed: missing '${REQUIRED_SNIPPET}'")
  endif()
endforeach()

if(NOT NETWORK_MANAGER_TEXT MATCHES
   "useDownloadClient[ \t\r\n]*\\?[ \t\r\n]*effectiveMaxDownloadBytes")
  message(
    FATAL_ERROR
    "NetworkManager invariant failed: download requests must use the dedicated download size cap")
endif()

foreach(REQUIRED_SNIPPET
    "#if defined(__APPLE__)"
    "kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly"
    "local sessionAccessToken = nil"
    "function ITGOnline:ApplyStoredAccessToken(callback)"
    "Secure access token persistence refused: native credential store unavailable"
    "write_profile_access_token_binding")
  string(FIND "${SECURE_CREDENTIAL_STORE_TEXT}${ONLINE_CLIENT_TEXT}" "${REQUIRED_SNIPPET}" SNIPPET_OFFSET)
  if(SNIPPET_OFFSET EQUAL -1)
    message(FATAL_ERROR "Secure credential invariant failed: missing '${REQUIRED_SNIPPET}'")
  endif()
endforeach()

foreach(FORBIDDEN_SNIPPET
    "ITGOnline.token ="
    "ITGOnline.pendingAccessToken ="
    "config.accessToken ="
    "connectionConfig.accessToken ="
    "Config().accessToken"
    "config.password ="
    "nextConfig.password ="
    "self.transientPassword ="
    "profile token fallback saved"
    "using profile token fallback")
  string(FIND "${ONLINE_CLIENT_TEXT}" "${FORBIDDEN_SNIPPET}" SNIPPET_OFFSET)
  if(NOT SNIPPET_OFFSET EQUAL -1)
    message(FATAL_ERROR "Secure credential invariant failed: forbidden '${FORBIDDEN_SNIPPET}'")
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
