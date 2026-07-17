file(READ
  "${ITGMANIA_SOURCE_DIR}/src/arch/ArchHooks/ArchHooks_MacOSX.mm"
  ARCH_HOOKS_MACOS)

if(NOT ARCH_HOOKS_MACOS MATCHES "uint64_t iFreq = 0;")
  message(FATAL_ERROR "macOS CPU frequency storage must be initialized")
endif()

if(NOT ARCH_HOOKS_MACOS MATCHES
   "GET_PARAM\\(\"hw.cpufrequency\", iFreq\\) == 0 && iFreq > 0")
  message(FATAL_ERROR "macOS CPU frequency must only be used after sysctl success")
endif()

if(NOT ARCH_HOOKS_MACOS MATCHES "Clock speed unavailable")
  message(FATAL_ERROR "macOS debug info needs an explicit unavailable fallback")
endif()
