if(NOT DEFINED ITGMANIA_SOURCE_DIR)
  message(FATAL_ERROR "ITGMANIA_SOURCE_DIR is required")
endif()

file(READ "${ITGMANIA_SOURCE_DIR}/src/TeejusbFsrManager.cpp" manager_cpp)
file(READ "${ITGMANIA_SOURCE_DIR}/src/TeejusbFsrManager.h" manager_h)
file(READ
  "${ITGMANIA_SOURCE_DIR}/Themes/Simply Love/BGAnimations/ScreenTeejusbFsr overlay/default.lua"
  screen_lua)
file(READ
  "${ITGMANIA_SOURCE_DIR}/Themes/Simply Love/BGAnimations/ScreenGameplay underlay/PerPlayer/StepStatistics/TeejusbFsrBars.lua"
  gameplay_lua)

foreach(required
    "ParseTeejusbFsrSerialLine"
    "kMaxReadBufferBytes"
    "kMaxReadBytesPerPoll"
    "kSerialWriteTimeout"
    "device.protocolVerified"
    "parsed != device.pendingEepromThresholds"
    "IsOperationPending(*device)"
    "IsPortAssigned(device.port)")
  string(FIND "${manager_cpp}" "${required}" found_at)
  if(found_at EQUAL -1)
    message(FATAL_ERROR "Missing teejusb-fsr manager invariant: ${required}")
  endif()
endforeach()

if(manager_cpp MATCHES "AddWindowsResponsiveTeejusbPorts")
  message(FATAL_ERROR
    "FSR discovery must not synchronously probe and seize arbitrary Windows COM ports")
endif()

if(manager_cpp MATCHES "device\\.fd < 0 && !OpenDevice\\(device\\)")
  message(FATAL_ERROR
    "FSR commands must not implicitly open a port and overlap its handshake")
endif()

if(manager_cpp MATCHES "parsed\[i\] = StringToInt")
  message(FATAL_ERROR "FSR protocol values require strict bounded parsing")
endif()

foreach(required
    "TeejusbFsrManager(const TeejusbFsrManager&) = delete"
    "protocolVerified = false"
    "m_LastDeviceScan")
  string(FIND "${manager_h}" "${required}" found_at)
  if(found_at EQUAL -1)
    message(FATAL_ERROR "Missing teejusb-fsr ownership invariant: ${required}")
  endif()
endforeach()

foreach(lua_source screen_lua gameplay_lua)
  string(FIND "${${lua_source}}" "next_refresh_at" found_at)
  if(found_at EQUAL -1)
    message(FATAL_ERROR "FSR Lua polling must be rate limited: ${lua_source}")
  endif()
endforeach()

string(FIND "${screen_lua}" "if selected_focus == 3 and event.GameButton == \"MenuUp\""
  focused_threshold_at)
if(focused_threshold_at EQUAL -1)
  message(FATAL_ERROR "FSR threshold controls must respect the selected UI focus")
endif()
