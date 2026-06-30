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

read_source("src/AttackDisplay.cpp" attack_display_cpp)
read_source("src/AttackDisplay.h" attack_display_h)

require_contains(
  "${attack_display_cpp}"
  "this->AddChild(&m_sprAttack);"
  "AttackDisplay always attaches its owned sprite child")
require_not_contains(
  "${attack_display_cpp}"
  "AttackDisplay::AttackDisplay() : m_pPlayerState(nullptr) {\n  if (GAMESTATE"
  "AttackDisplay constructor must not gate child composition on PlayMode")
require_contains(
  "${attack_display_cpp}"
  "ResetPreloadedAttacks();"
  "AttackDisplay resets preload state on Init")
require_contains(
  "${attack_display_cpp}"
  "m_TexturePreload.UnloadAll();"
  "AttackDisplay releases stale preloaded textures")
require_contains(
  "${attack_display_cpp}"
  "m_PreloadedAttackPathsByModifier.clear();"
  "AttackDisplay clears stale preloaded attack allowlist")
require_contains(
  "${attack_display_cpp}"
  "AttackDisplayThemeIsReady"
  "AttackDisplay guards theme lifecycle")
require_contains(
  "${attack_display_cpp}"
  "THEME != nullptr && THEME->IsThemeLoaded()"
  "AttackDisplay requires loaded theme before theme reads")
require_contains(
  "${attack_display_cpp}"
  "LUA != nullptr"
  "AttackDisplay guards Lua before command metric compilation")
require_contains(
  "${attack_display_cpp}"
  "THEME->HasMetric(\"AttackDisplay\", commandName)"
  "AttackDisplay treats attack commands as optional metrics")
require_contains(
  "${attack_display_cpp}"
  "m_PreloadedAttackPathsByModifier.find(sText)"
  "AttackDisplay authorizes display by exact preloaded modifier")
require_not_contains(
  "${attack_display_cpp}"
  "m_PreloadedAttackPaths.find(path)"
  "AttackDisplay must not authorize display by colliding resolved path")
require_contains(
  "${attack_display_cpp}"
  "ambiguousAttacks.insert"
  "AttackDisplay rejects colliding sanitized attack tokens")
require_contains(
  "${attack_display_cpp}"
  "m_sprAttack.StopTweening();"
  "AttackDisplay stops stale tweens before visibility changes")
require_contains(
  "${attack_display_cpp}"
  "if (activeAttack.empty())"
  "AttackDisplay hides when no active attack remains")
require_contains(
  "${attack_display_cpp}"
  "AttackDisplay* AttackDisplay::Copy() const"
  "AttackDisplay has an explicit polymorphic copy")
require_contains(
  "${attack_display_h}"
  "AttackDisplay(const AttackDisplay& cpy)"
  "AttackDisplay declares a safe copy constructor")
require_contains(
  "${attack_display_h}"
  "AttackDisplay* Copy() const override"
  "AttackDisplay declares Copy override")
require_not_contains(
  "${attack_display_h}"
  "GetAttackPieceName"
  "AttackDisplay asset naming helper must stay private to the implementation")
