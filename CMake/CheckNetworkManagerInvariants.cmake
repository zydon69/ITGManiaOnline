if(NOT DEFINED ITGMANIA_SOURCE_DIR)
  message(FATAL_ERROR "ITGMANIA_SOURCE_DIR is required")
endif()

set(NETWORK_MANAGER_SOURCE
    "${ITGMANIA_SOURCE_DIR}/src/NetworkManager.cpp")
file(READ "${NETWORK_MANAGER_SOURCE}" NETWORK_MANAGER_TEXT)
file(
  READ
  "${ITGMANIA_SOURCE_DIR}/Themes/Simply Love/Scripts/SL-ITGOnlineClient.lua"
  ONLINE_CLIENT_TEXT)
file(
  READ
  "${ITGMANIA_SOURCE_DIR}/Themes/Simply Love/BGAnimations/ScreenITGOnlineLogin underlay/default.lua"
  ONLINE_LOGIN_SCREEN_TEXT)
file(READ "${ITGMANIA_SOURCE_DIR}/src/Profile.cpp" PROFILE_SOURCE_TEXT)
file(READ "${ITGMANIA_SOURCE_DIR}/src/ProfileManager.cpp" PROFILE_MANAGER_SOURCE_TEXT)

foreach(REQUIRED_SNIPPET
    "IsExpectedInactiveWebSocketTerminalMessage"
    "type == ix::WebSocketMessageType::Close"
    "type == ix::WebSocketMessageType::Error"
    "lua_websocket_inactive_terminal_drop"
    "if (IsExpectedInactiveWebSocketTerminalMessage(msg.type))"
    "url=%s reason=inactive type=%s"
    "queuedTasks > kBacklogAdaptiveThreshold * 4"
    "queuedTasks >= kBacklogAdaptiveThreshold"
    "void ClearQueuedTasks("
    "void RunQueuedWorker("
    "this->shutdownWorkers, this->httpWorkerMutex, this->httpWorkerCv"
    "this->shutdownWorkers, this->downloadWorkerMutex, this->downloadWorkerCv"
    "this->shutdownWorkers, this->webSocketWorkerMutex"
    "effectiveMaxDownloadBytes"
    "kMaxDownloadBytes = 5LL * 1024LL * 1024LL * 1024LL"
    "std::atomic<int64_t> latestProgressCurrent"
    "LEGACY_GROOVESTATS_QR_LOGIN_HOST"
    "protocol == \"ws\" && host == LEGACY_GROOVESTATS_QR_LOGIN_HOST"
    "HttpDenyHosts remains authoritative above"
    "ITGMANIA_HTTP_PUBLIC_KEY_PINS_ROTATION_DEFAULT"
    "35833860b4386ecf9297b08d9d0f7398cda72253224bd88b7f7f894f5d46f50d"
    "std::string configuredPins = BUILT_IN_HTTP_PUBLIC_KEY_PINS")
  string(FIND "${NETWORK_MANAGER_TEXT}" "${REQUIRED_SNIPPET}" SNIPPET_OFFSET)
  if(SNIPPET_OFFSET EQUAL -1)
    message(
        FATAL_ERROR
        "NetworkManager invariant failed: missing '${REQUIRED_SNIPPET}'")
  endif()
endforeach()

foreach(REQUIRED_SNIPPET
    "authentication_was_rejected"
    "SecureConnectionFailed"
    "ProfileTokenMismatch"
    "P2 = new_player_state(PLAYER_2)"
    "all_required_players_connected"
    "ApplyAccessTokenForPlayer"
    "local function panel_width()")
  string(FIND "${ONLINE_LOGIN_SCREEN_TEXT}" "${REQUIRED_SNIPPET}" SNIPPET_OFFSET)
  if(SNIPPET_OFFSET EQUAL -1)
    message(FATAL_ERROR "Online login invariant failed: missing '${REQUIRED_SNIPPET}'")
  endif()
endforeach()

string(FIND
    "${NETWORK_MANAGER_TEXT}"
    "NormalizePublicKeyPins(this->httpPublicKeyPins.Get())"
    STALE_PIN_PREFERENCE_OFFSET)
if(NOT STALE_PIN_PREFERENCE_OFFSET EQUAL -1)
  message(FATAL_ERROR "NetworkManager must not activate TLS trust roots from Preferences.ini")
endif()

foreach(REQUIRED_SNIPPET
    "ClearQueuedTasks(this->downloadWorkerMutex, this->downloadWorkerQueue);"
    "this->downloadWorkerQueue.size() >= kMaxDownloadWorkerQueue")
  string(FIND "${NETWORK_MANAGER_TEXT}" "${REQUIRED_SNIPPET}" SNIPPET_OFFSET)
  if(SNIPPET_OFFSET EQUAL -1)
    message(FATAL_ERROR "NetworkManager worker invariant failed: missing '${REQUIRED_SNIPPET}'")
  endif()
endforeach()

if(NOT NETWORK_MANAGER_TEXT MATCHES
   "useDownloadClient[ \t\r\n]*\\?[ \t\r\n]*effectiveMaxDownloadBytes")
  message(
    FATAL_ERROR
    "NetworkManager invariant failed: download requests must use the dedicated download size cap")
endif()

foreach(REQUIRED_SNIPPET
    "local sessionAccessToken = nil"
    "function ITGOnline:ApplyStoredAccessToken(callback)"
    "profile-guid:v2:"
    "GetITGOnlineAuth"
    "SaveProfileEditable")
  string(
    FIND
    "${ONLINE_CLIENT_TEXT}${PROFILE_SOURCE_TEXT}${PROFILE_MANAGER_SOURCE_TEXT}"
    "${REQUIRED_SNIPPET}"
    SNIPPET_OFFSET)
  if(SNIPPET_OFFSET EQUAL -1)
    message(FATAL_ERROR "Secure credential invariant failed: missing '${REQUIRED_SNIPPET}'")
  endif()
endforeach()

foreach(REQUIRED_SNIPPET
    "ini.SetValue(\"ITGOnline\", \"AccessToken\""
    "ini.GetValue(\"ITGOnline\", \"AccessToken\""
    "MAX_ITG_ONLINE_ACCESS_TOKEN_BYTES = 4096"
    "ClearITGOnlineAuth();"
    "SaveProfileEditable(PlayerNumber pn) const")
  string(
    FIND
    "${PROFILE_SOURCE_TEXT}${PROFILE_MANAGER_SOURCE_TEXT}"
    "${REQUIRED_SNIPPET}"
    SNIPPET_OFFSET)
  if(SNIPPET_OFFSET EQUAL -1)
    message(FATAL_ERROR "Profile credential invariant failed: missing '${REQUIRED_SNIPPET}'")
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
    "NETWORK:SecureCredentialGet"
    "NETWORK:SecureCredentialSet"
    "NETWORK:SecureCredentialDelete"
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
