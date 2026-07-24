if(NOT DEFINED ITGMANIA_SOURCE_DIR)
  message(FATAL_ERROR "ITGMANIA_SOURCE_DIR is required")
endif()

set(player_stats "${ITGMANIA_SOURCE_DIR}/src/PlayerStageStats.cpp")
set(stage_stats "${ITGMANIA_SOURCE_DIR}/src/StageStats.cpp")
set(rave "${ITGMANIA_SOURCE_DIR}/src/ScoreDisplayRave.cpp")
set(alive "${ITGMANIA_SOURCE_DIR}/src/ScoreDisplayAliveTime.cpp")
set(life_meter "${ITGMANIA_SOURCE_DIR}/src/LifeMeter.cpp")
set(life_bar "${ITGMANIA_SOURCE_DIR}/src/LifeMeterBar.cpp")
set(life_battery "${ITGMANIA_SOURCE_DIR}/src/LifeMeterBattery.cpp")

foreach(path IN ITEMS
    "${player_stats}" "${stage_stats}" "${rave}" "${alive}"
    "${life_meter}" "${life_bar}" "${life_battery}")
  if(NOT EXISTS "${path}")
    message(FATAL_ERROR "Missing life/score-display source: ${path}")
  endif()
endforeach()

foreach(name IN ITEMS
    player_stats stage_stats rave alive life_meter life_bar life_battery)
  file(READ "${${name}}" ${name}_source)
endforeach()

function(require_contains content needle label)
  string(FIND "${content}" "${needle}" position)
  if(position EQUAL -1)
    message(FATAL_ERROR "Life/score-display invariant failed: ${label}")
  endif()
endfunction()

function(require_not_contains content needle label)
  string(FIND "${content}" "${needle}" position)
  if(NOT position EQUAL -1)
    message(FATAL_ERROR "Life/score-display invariant failed: ${label}")
  endif()
endfunction()

require_contains(
  "${player_stats_source}"
  "if (!IsValidPlayerNumber(p))"
  "award calculation validates player slots")
require_contains(
  "${stage_stats_source}"
  "std::numeric_limits<unsigned int>::max()"
  "minimum miss combo uses an unsigned sentinel")
require_contains(
  "${rave_source}"
  "rage_clamp(fLevel, 0.0f, (float)NUM_ATTACK_LEVELS - 0.0001f)"
  "Rave meter level is finite and index-bounded")
require_contains(
  "${alive_source}"
  "if (b == b2)"
  "alive-time display requires exactly one player context")
require_not_contains(
  "${life_meter_source}"
  "FAIL_M(\"Invalid LifeType"
  "invalid life types do not terminate the game")
require_contains(
  "${life_bar_source}"
  "static_cast<int64_t>(iProgressiveLifebarDifficulty) * iCleared"
  "progressive life arithmetic widens before multiplication")
require_contains(
  "${life_bar_source}"
  "MESSAGEMAN == nullptr"
  "bar life broadcasts tolerate unavailable message state")
require_contains(
  "${life_battery_source}"
  "const int64_t magnitude = -static_cast<int64_t>(iLifeDiff)"
  "battery life handles INT_MIN safely")
require_contains(
  "${life_battery_source}"
  "bool IsSafeLivesFormat(const std::string& format)"
  "battery text validates theme printf formats")
require_contains(
  "${life_battery_source}"
  "void LifeMeterBattery::ResetLoadedActors()"
  "battery reload detaches owned actors")
require_contains(
  "${life_battery_source}"
  "Refresh();\n  BroadcastLifeChanged(lost);"
  "direct battery SetLife refreshes its display")

message(STATUS "Life-meter/score-display safety invariants passed")
