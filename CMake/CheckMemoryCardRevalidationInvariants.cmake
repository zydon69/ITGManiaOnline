if(NOT DEFINED ITGMANIA_SOURCE_DIR)
  message(FATAL_ERROR "ITGMANIA_SOURCE_DIR is required")
endif()

file(READ "${ITGMANIA_SOURCE_DIR}/src/MemoryCardManager.cpp" manager_cpp)
file(READ
  "${ITGMANIA_SOURCE_DIR}/src/arch/MemoryCard/MemoryCardDriverThreaded_Folder.cpp"
  folder_driver_cpp)

function(require_contains source needle label)
  string(FIND "${source}" "${needle}" found_at)
  if(found_at EQUAL -1)
    message(FATAL_ERROR "Missing memory-card invariant: ${label}")
  endif()
endfunction()

require_contains(
  "${manager_cpp}"
  "if (LUA != nullptr)"
  "Lua registration and teardown guard lifecycle")
require_contains(
  "${manager_cpp}"
  "if (THEME != nullptr && THEME->IsThemeLoaded())"
  "memory-card sounds require a loaded theme")
require_contains(
  "${manager_cpp}"
  "if (FILEMAN != nullptr)"
  "filesystem mounting and teardown guard lifecycle")
require_contains(
  "${manager_cpp}"
  "if (g_pWorker == nullptr)"
  "manager updates guard worker lifetime")
require_contains(
  "${folder_driver_cpp}"
  "pDevice == nullptr || pDevice->sOsMountDir.empty() || FILEMAN == nullptr"
  "folder write test validates device and filesystem context")
