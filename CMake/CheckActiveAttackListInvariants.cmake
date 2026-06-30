if(NOT DEFINED ITGMANIA_SOURCE_DIR)
  message(FATAL_ERROR "ITGMANIA_SOURCE_DIR is required")
endif()

function(read_source relative_path output_var)
  set(path "${ITGMANIA_SOURCE_DIR}/${relative_path}")
  if(NOT EXISTS "${path}")
    message(FATAL_ERROR "Missing source file: ${path}")
  endif()
  file(READ "${path}" contents)
  set("${output_var}" "${contents}" PARENT_SCOPE)
endfunction()

function(require_contains haystack needle label)
  string(FIND "${haystack}" "${needle}" found_at)
  if(found_at EQUAL -1)
    message(FATAL_ERROR "Missing invariant: ${label}")
  endif()
endfunction()

function(require_not_contains haystack needle label)
  string(FIND "${haystack}" "${needle}" found_at)
  if(NOT found_at EQUAL -1)
    message(FATAL_ERROR "Forbidden pattern: ${label}")
  endif()
endfunction()

read_source("src/ActiveAttackList.cpp" active_attack_list_cpp)
read_source("src/ActiveAttackList.h" active_attack_list_h)
read_source("src/CommonMetrics.cpp" common_metrics_cpp)
read_source("src/PlayerOptions.cpp" player_options_cpp)
read_source("src/PlayerState.cpp" player_state_cpp)
read_source("src/ThemeManager.cpp" theme_manager_cpp)

require_contains(
  "${common_metrics_cpp}"
  "THEME == nullptr || !THEME->IsThemeLoaded()"
  "option localization returns raw tokens when the theme manager is unavailable")
require_contains(
  "${player_options_cpp}"
  "only an approach token."
  "localized player options skip approach-only tokens before using back()")
require_contains(
  "${theme_manager_cpp}"
  "THEME = nullptr;"
  "ThemeManager teardown clears the global manager pointer")
require_contains(
  "${active_attack_list_h}"
  "ActiveAttackList(const ActiveAttackList& cpy);"
  "ActiveAttackList owns an explicit copy constructor")
require_contains(
  "${active_attack_list_cpp}"
  "m_pPlayerState(nullptr)"
  "ActiveAttackList copies do not inherit the source PlayerState pointer")
require_contains(
  "${active_attack_list_cpp}"
  "MAX_ATTACK_LIST_PARSE_ITEMS"
  "ActiveAttackList bounds active attack modifier parsing")
require_contains(
  "${active_attack_list_cpp}"
  "for (size_t i = 0; i < attacks.size(); i++)"
  "ActiveAttackList iterates attack arrays with size_t")
require_contains(
  "${active_attack_list_cpp}"
  "GetThemeMetricGenerationForAttackList"
  "ActiveAttackList refreshes when theme metrics are reloaded")
require_not_contains(
  "${active_attack_list_cpp}"
  "#include \"GameState.h\""
  "ActiveAttackList must not keep obsolete GameState include")
require_not_contains(
  "${active_attack_list_cpp}"
  "#include \"Inventory.h\""
  "ActiveAttackList must not keep obsolete Inventory include")
require_contains(
  "${player_state_cpp}"
  "MAX_ACTIVE_ATTACKS_PER_PLAYER"
  "PlayerState bounds active attack queue growth")
require_contains(
  "${player_state_cpp}"
  "m_iActiveAttackListRevision"
  "PlayerState exposes an attack-list revision for HUD refresh invalidation")
